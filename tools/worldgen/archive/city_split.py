"""城市细分 —— 在 L1 地块之下继续细分出"城市"（L1 → 城市层蒙版生产者）。

开发期一次性工具（Python）。输入 L1 蒙版（l1_labels_2048.npy + l1_data.json，
2048 级），输出 **全大陆城市蒙版**：每个像素 = 一个城市 label（0 = 海洋/无），
同一个 L1 地块内的城市使用相似颜色（父 L1 色相 + 明度阶梯）。

与 L1 层同规（层级细分一致性，08-程序化世界生成.md §八）：
  1. 城市点 = jittered grid（--spacing 默认 36px，比 L1 密一级）+ 细微扰动；
     落在哪个 L1 就归属哪个 L1。
  2. 每个 L1 地块至少保留 1 个城市点（无点时用该 L1 的城市点兜底）。
  3. 城市划分 = 按 L1 分组的多源同步膨胀（flat watershed）：城市在 L1 陆地内
     生长、被 L1 边界/海阻挡 → 城市不跨 L1、不跨海、不跨湾、一个 L1 的两个
     半岛不共城市。
  4. 城市面积下限（--min-city-area 默认 90px²）：低于并入同 L1 内最大相邻城市；
     无同 L1 相邻城市可并的豁免（small_exempt，例：极小 L1 的唯一城市）。
  5. 蒙版配色：父 L1 蒙版色转 HSV，色相不变、明度按城市面积排名细分
     —— 同一个 L1 的城市色系相似、可辨，跨 L1 之际仍能看出父级关系。

产出（output/l1/）：
  - city_labels_2048.npy   全大陆城市蒙版（int32，0=海洋/无，1..M=城市）
  - city_preview_2048.png  城市蒙版预览（同 L1 相似色 + 城市点标记）
  - city_partition_2048.png label 直编索引图（P 社机制，hover/查询备用）
  - city_cities_2048.png   城市点分布图
  - city_data.json         城市元数据（id/父 L1/城市点/质心/面积/多边形/邻接/蒙版色）

用法：
  python tools/worldgen/l1/city_split.py [--spacing 36] [--jitter 0.4]
      [--min-city-area 90] [--seed N]
"""
import argparse
import colorsys
import json
import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage as ndi
from scipy.ndimage import distance_transform_edt
from skimage.segmentation import watershed

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # tools/worldgen
L1_DIR = os.path.join(HERE, "output", "l1")
OUT_DIR = L1_DIR
sys.path.insert(0, os.path.join(HERE, "l2_export"))
import mesh_extract  # noqa: E402

OCEAN_COLOR = (30, 55, 95)
STRUCT8 = np.ones((3, 3), dtype=bool)


def pick_city_points(land, parent_labels, rng, spacing, jitter_fraction):
    """jittered grid 撒城市点（仅陆地），返回 (N, 2) float64 + (N,) 父 L1。

    落在哪个 L1 细胞就归属哪个 L1；对无点的 L1 由外部用其 L1 城市点兜底。
    """
    size = land.shape[0]
    ys, xs = np.where(land)
    y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()
    gy = np.arange(y0, y1 + spacing, spacing, dtype=np.float64) + spacing * 0.5
    gx = np.arange(x0, x1 + spacing, spacing, dtype=np.float64) + spacing * 0.5
    gyy, gxx = np.meshgrid(gy, gx, indexing="ij")
    j = spacing * jitter_fraction
    pts = np.stack([gxx.ravel(), gyy.ravel()], axis=1) + \
        (rng.random((gxx.size, 2)) * 2.0 - 1.0) * j
    ok = (pts[:, 0] >= 0) & (pts[:, 0] < size) & (pts[:, 1] >= 0) & (pts[:, 1] < size)
    pts = pts[ok]
    pi = pts.astype(np.int64)
    on_land = land[pi[:, 1], pi[:, 0]]
    pts = pts[on_land]
    pi = pi[on_land]
    parent = parent_labels[pi[:, 1], pi[:, 0]]
    return pts, parent


def grow_cities(land, parent_labels, cities, city_parent):
    """按 L1 分组多源膨胀生长城市。

    城市不跨 L1：mask = 单个 L1 细胞（再拆连通分量防护）。
    返回 (labels, seed_of_label)。
    """
    size = land.shape[0]
    labels = np.zeros((size, size), dtype=np.int32)
    seeds = [list(p) for p in cities]
    parent_of_seed = list(city_parent)
    # L1 label -> 种子索引（按城市点归属）
    seeds_by_parent = {}
    for i in range(len(seeds)):
        seeds_by_parent.setdefault(int(parent_of_seed[i]), []).append(i)

    next_id = 1
    seed_of_label = {}
    for plab in np.unique(parent_labels[parent_labels > 0]):
        pmask = parent_labels == plab
        # L1 细胞理应是单个连通组件（膨胀生成），拆分量防护（防 8 连通角落粘连）
        pcomp, npc = ndi.label(pmask, structure=STRUCT8)
        for k in range(1, npc + 1):
            cmask = pcomp == k
            cy, cx = np.nonzero(cmask)
            idxs = [i for i in seeds_by_parent.get(int(plab), [])
                    if cmask[int(seeds[i][1]), int(seeds[i][0])]]
            if not idxs:
                # 该 L1（或其碎块）无城市点：补一个最内侧点
                gd = distance_transform_edt(cmask)
                pk = int(np.argmax(gd[cy, cx]))
                seeds.append([float(cx.ravel()[pk]), float(cy.ravel()[pk])])
                parent_of_seed.append(int(plab))
                idxs = [len(seeds) - 1]
            markers = np.zeros((size, size), dtype=np.int32)
            for gi, sidx in enumerate(idxs):
                px, py = int(seeds[sidx][0]), int(seeds[sidx][1])
                markers[py, px] = next_id + gi
            seg = watershed(np.zeros((size, size), dtype=np.uint8), markers,
                            mask=cmask, connectivity=2)
            for gi, sidx in enumerate(idxs):
                lab = next_id + gi
                labels[seg == lab] = lab
                seed_of_label[lab] = sidx
            next_id += len(idxs)
    return labels, np.array(seeds, dtype=np.float64), seed_of_label


def merge_small_cities(labels, parent_labels, min_area):
    """城市面积下限：< min_area 并入（同 L1）面积最大相邻城市；无同 L1 邻居可并豁免。

    返回 (labels2, exempt, remap)。
    """
    n = int(labels.max())
    while True:
        counts = np.bincount(labels.ravel(), minlength=n + 1)
        padded = np.pad(labels, 1)
        adj = {i: set() for i in range(1, n + 1)}
        yy, xx = np.where(padded[1:-1, 1:-1] > 0)
        for y, x in zip(yy, xx):
            v = padded[y + 1, x + 1]
            for dy, dx in ((1, 0), (0, 1)):
                w = padded[y + 1 + dy, x + 1 + dx]
                if w > 0 and w != v:
                    adj[int(v)].add(int(w))
                    adj[int(w)].add(int(v))
        cell_group = {}
        for lab in range(1, n + 1):
            if counts[lab] == 0:
                continue
            mm = labels == lab
            cell_group[lab] = int(parent_labels[mm][0])
        changed = False
        for lab in range(1, n + 1):
            if counts[lab] == 0 or counts[lab] >= min_area:
                continue
            g = cell_group[lab]
            cands = [nb for nb in adj[lab]
                     if counts[nb] > 0 and cell_group.get(nb, -1) == g]
            if not cands:
                continue
            best = max(cands, key=lambda nb: counts[nb])
            labels[labels == lab] = best
            counts[best] += counts[lab]
            counts[lab] = 0
            changed = True
        if not changed:
            break
    # 最终豁免：仍 < min_area 且无同 L1 相邻存活城市
    counts = np.bincount(labels.ravel(), minlength=n + 1)
    padded = np.pad(labels, 1)
    adj = {i: set() for i in range(1, n + 1)}
    yy, xx = np.where(padded[1:-1, 1:-1] > 0)
    for y, x in zip(yy, xx):
        v = padded[y + 1, x + 1]
        for dy, dx in ((1, 0), (0, 1)):
            w = padded[y + 1 + dy, x + 1 + dx]
            if w > 0 and w != v:
                adj[int(v)].add(int(w))
                adj[int(w)].add(int(v))
    cell_group = {}
    for lab in range(1, n + 1):
        if counts[lab] == 0:
            continue
        mm = labels == lab
        cell_group[lab] = int(parent_labels[mm][0])
    exempt = set()
    for lab in range(1, n + 1):
        if counts[lab] == 0 or counts[lab] >= min_area:
            continue
        g = cell_group.get(lab)
        if not any(counts[nb] > 0 and cell_group.get(nb, None) == g for nb in adj[lab]):
            exempt.add(lab)
    uniq = np.unique(labels[labels > 0])
    remap = {int(old): new for new, old in enumerate(uniq, start=1)}
    labels2 = np.zeros_like(labels)
    for old, new in remap.items():
        labels2[labels == old] = new
    return labels2, {remap[l] for l in exempt if int(l) in remap}, remap


def city_palette(city_labels, parent_labels, parent_rgb, n_city):
    """同 L1 相似色：父 L1 色相 + 明度按城市面积排名细分。返回 {label: (r,g,b)}。"""
    palette = {}
    for plab in np.unique(parent_labels[parent_labels > 0]):
        in_p = (parent_labels.ravel() == plab) & (city_labels.ravel() > 0)
        if not in_p.any():
            continue
        labs, counts = np.unique(city_labels.ravel()[in_p], return_counts=True)
        order = np.argsort(-counts)
        labs = labs[order]
        m = len(labs)
        base = parent_rgb.get(int(plab), (200, 200, 200))
        h, s, v = colorsys.rgb_to_hsv(base[0] / 255, base[1] / 255, base[2] / 255)
        for k, lab in enumerate(labs):
            # 明度阶梯 0.32 ~ 0.92，同 L1 内相邻城市可辨但色系一致
            vv = 0.32 + 0.60 * (k + 0.5) / m
            r8, g8, b8 = colorsys.hsv_to_rgb(h, 0.62, vv)
            palette[int(lab)] = (int(r8 * 255), int(g8 * 255), int(b8 * 255))
    for lab in range(1, n_city + 1):
        palette.setdefault(lab, (190, 190, 190))
    return palette


def main():
    ap = argparse.ArgumentParser(description="L1 地块之下细分城市（城市蒙版）")
    ap.add_argument("--spacing", type=int, default=22, help="城市点网格间距（2048 级像素）")
    ap.add_argument("--jitter", type=float, default=0.4, help="扰动幅度（spacing 的比例）")
    ap.add_argument("--min-city-area", type=int, default=90,
                    help="城市面积下限（px²，低于并入同 L1 最大邻居，无同 L1 邻居可并豁免）")
    ap.add_argument("--seed", type=int, default=20260818, help="城市点随机种子")
    args = ap.parse_args()

    print("[1/6] 加载 L1 蒙版（2048）...")
    parent = np.load(os.path.join(L1_DIR, "l1_labels_2048.npy"))
    l1data = json.load(open(os.path.join(L1_DIR, "l1_data.json"), encoding="utf-8"))
    size = parent.shape[0]
    land = parent > 0
    l1_city = {int(t["label"]): t["city"] for t in l1data["tiles"]}
    print("  陆地 %.1f%%, L1 地块 %d" % (land.mean() * 100, int(parent.max())))

    print("[2/6] 城市点撒点（jittered grid, spacing=%d, jitter=%.2f）..." % (args.spacing, args.jitter))
    rng = np.random.default_rng(args.seed)
    pts, city_parent = pick_city_points(land, parent, rng, args.spacing, args.jitter)
    # 每 L1 至少 1 个城市点：无点的 L1 用其 L1 城市点兜底
    has_pt = np.zeros(int(parent.max()) + 1, dtype=bool)
    np.add.at(has_pt, city_parent, True)
    for lab in range(1, int(parent.max()) + 1):
        if not has_pt[lab]:
            pts = np.vstack([pts, [l1_city[lab]]])
            city_parent = np.append(city_parent, lab)
    city_parent = city_parent.astype(np.int32)
    print("  城市点 %d 个（每 L1 至少 1 点，兜底 %d 个）" % (
        len(pts), int((~has_pt[1:]).sum())))

    print("[3/6] 按 L1 分组多源膨胀生长城市 ...")
    labels, cities, seed_of_label = grow_cities(land, parent, pts, city_parent)
    n_city = int(labels.max())
    print("  膨胀后城市 %d 个" % n_city)

    print("[4/6] 城市面积下限合并（min=%dpx²）..." % args.min_city_area)
    labels, exempt, remap = merge_small_cities(labels, parent, args.min_city_area)
    n_city = int(labels.max())
    per_l1 = np.bincount(parent.ravel(), weights=(labels.ravel() > 0).astype(np.int64),
                         minlength=int(parent.max()) + 1)
    cities_final = np.array(
        [cities[seed_of_label[old]] for old, new in sorted(remap.items())
         if old in seed_of_label], dtype=np.float64)
    print("  合并后城市 %d 个，平均每 L1 %.2f 个城市，平均面积 %.0fpx" % (
        n_city, float(n_city) / int(parent.max()),
        float((labels > 0).sum()) / n_city))

    print("[5/6] 提取多边形 + 邻接 + 配色 ...")
    mesh = mesh_extract.simplify_mesh(mesh_extract.extract_mesh(labels))
    padded = np.pad(labels, 1, mode="constant")
    adj = {lab: set() for lab in range(1, n_city + 1)}
    yy, xx = np.where(padded[1:-1, 1:-1] > 0)
    for y, x in zip(yy, xx):
        v = padded[y + 1, x + 1]
        for dy, dx in ((1, 0), (0, 1)):
            w = padded[y + 1 + dy, x + 1 + dx]
            if w > 0 and w != v:
                adj[int(v)].add(int(w))
                adj[int(w)].add(int(v))
    parent_rgb = {int(t["label"]): t["rgb"] for t in l1data["tiles"]}
    palette = city_palette(labels, parent, parent_rgb, n_city)

    print("[6/6] 写文件 ...")
    preview = np.zeros((size, size, 3), dtype=np.uint8)
    preview[~land] = OCEAN_COLOR
    for lab, rgb in palette.items():
        preview[labels == lab] = rgb
    prev_img = Image.fromarray(preview)
    if len(cities_final) > 0:
        from PIL import ImageDraw
        dr = ImageDraw.Draw(prev_img)
        for (cx, cy) in cities_final:
            x, y = float(cx), float(cy)
            dr.ellipse([x - 3, y - 3, x + 3, y + 3], outline=(12, 12, 12), width=1)
            dr.ellipse([x - 1, y - 1, x + 1, y + 1], fill=(250, 250, 250))
    prev_img.save(os.path.join(OUT_DIR, "city_preview_2048.png"))

    idx_img = np.zeros((size, size, 3), dtype=np.uint8)
    idx_img[labels > 0, 0] = (labels[labels > 0] >> 16) & 0xFF
    idx_img[labels > 0, 1] = (labels[labels > 0] >> 8) & 0xFF
    idx_img[labels > 0, 2] = labels[labels > 0] & 0xFF
    Image.fromarray(idx_img).save(os.path.join(OUT_DIR, "city_partition_2048.png"))

    city_img = np.full((size, size, 3), 235, dtype=np.uint8)
    city_img[land, :] = 220
    for (cx, cy) in cities_final:
        x0, y0 = int(cx) - 2, int(cy) - 2
        city_img[max(0, y0):y0 + 5, max(0, x0):x0 + 5, 0] = 200
        city_img[max(0, y0):y0 + 5, max(0, x0):x0 + 5, 1] = 40
        city_img[max(0, y0):y0 + 5, max(0, x0):x0 + 5, 2] = 40
    Image.fromarray(city_img).save(os.path.join(OUT_DIR, "city_cities_2048.png"))

    np.save(os.path.join(OUT_DIR, "city_labels_2048.npy"), labels)

    def _decimate(loop):
        xy = [(float(p[1]), float(p[0])) for p in loop]
        pts = mesh_extract._dp_simplify(xy, 0.3)
        return [[p[0], p[1]] for p in pts]

    cities_out = []
    for lab in range(1, n_city + 1):
        m = labels == lab
        ys, xs = np.where(m)
        rings = [list(list(p) for p in loop) for loop in mesh.get(lab, {}).get("outer", [])]
        polys = [_decimate(r) for r in rings if len(r) >= 3]
        cities_out.append({
            "label": lab,
            "parent_l1": int(parent.ravel()[np.flatnonzero(m)[0]]),
            "city": [round(float(cities_final[lab - 1][0]), 3), round(float(cities_final[lab - 1][1]), 3)],
            "centroid": [round(float(xs.mean()), 3), round(float(ys.mean()), 3)],
            "area_px": int(m.sum()),
            "rgb": list(palette[lab]),
            "polygon": polys[0] if polys else [],
            "polygons": polys,
            "neighbors": sorted(adj[lab]),
            "small_exempt": lab in exempt,
        })
    out = {
        "name": "全大陆城市蒙版（L1 之下细分）",
        "algorithm": "cells-growth（按 L1 分组多源膨胀 + 面积下限合并）",
        "size": size,
        "coord": "xy",
        "spacing": args.spacing,
        "jitter": args.jitter,
        "min_city_area": args.min_city_area,
        "seed": args.seed,
        "n_l1": int(parent.max()),
        "n_city": n_city,
        "cities": cities_out,
    }
    with open(os.path.join(OUT_DIR, "city_data.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)

    counts = np.bincount(labels.ravel())
    print("完成。城市=%d, 最小 %dpx, 最大 %dpx, 平均 %.0fpx, 豁免小城市 %d" % (
        n_city, counts[1:].min(), counts[1:].max(),
        float(land.sum()) / n_city, len(exempt)))
    print("  输出: %s" % OUT_DIR)


if __name__ == "__main__":
    main()