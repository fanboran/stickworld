"""城市细分 v2 —— 在【老 L1 划分】之下细分"城市"（替代废弃的 389 细胞 + 城市层）。

背景（2026-08 用户纠偏）：真实分层 = L3 大世界(老 13 地区) → L2 下老 L1 划分(保持老的，
即 export_l2_maps 产出的 tiles，全大陆 69 块) → 城市(在老 L1 之下细分)。此前按"细分 L2"
误解生成的 389 L1 细胞蒙版 + 基于它的城市层整体废弃。

实现（与城市层同规，父级换成老 L1）：
  1. 全局老 L1 蒙版：13 地区 tiles_8192.npy 按 bbox_8192 拼回全局 8192 → NEAREST 降采样 2048
     （跨地区 label 用 region 累积 shift 分配，0=非地块/海洋）；陆地缺口(0.01%)用 EDT 最近老 L1 修复。
  2. 城市点 = jittered grid（--spacing 默认 40）+ 细微扰动，落在哪个老 L1 归属哪个；
     每个老 L1 至少 1 个城市点（无点用老 L1 质心兜底）。
  3. 城市划分 = 按老 L1 分组的多源同步膨胀（flat watershed）：城市在老 L1 陆地内生长、
     被老 L1 边界/海阻挡 → 城市不跨老 L1、不跨海、不跨湾。
  4. 城市面积下限（--min-city-area 90）：低于并入同老 L1 最大相邻城市；无同老 L1 邻居可并豁免。
  5. 蒙版配色：父老 L1 的 tile 色（l2_world.json color）转 HSV，色相不变 + 明度按城市面积排名细分
     —— 同一个老 L1 的城市相似色，跨老 L1 见父级关系。

产出（output/l1_v2/）：
  - legacy_l1_labels_2048.npy   老 L1 全局蒙版（1..69）
  - legacy_l1_data.json         每老 L1（全局 label/region/centroid/bbox/城市数）
  - city_labels_2048.npy        城市蒙版（0=海洋/无，1..N）
  - city_preview_2048.png       城市蒙版预览（同老 L1 相似色 + 城市点）
  - city_partition_2048.png     label 直编索引图
  - city_cities_2048.png        城市点分布图
  - city_data.json              城市元数据（id/父老 L1/城市点/质心/面积/多边形/邻接/蒙版色）

用法：
  python tools/worldgen/l1/city_split_v2.py [--spacing 40] [--jitter 0.4]
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
L2_PACKS = os.path.join(HERE, "output", "l2_packs")
REGIONS_DIR = os.path.join(HERE, "output", "regions")
OUT_DIR = os.path.join(HERE, "output", "l1_v2")
sys.path.insert(0, os.path.join(HERE, "l2_export"))
import mesh_extract  # noqa: E402

OCEAN_COLOR = (30, 55, 95)
STRUCT8 = np.ones((3, 3), dtype=bool)


def build_legacy_l1_mask(size=2048):
    """拼 13 地区老 L1 → 全局 8192 → 降采样 size；修复陆地缺口（EDT 最近老 L1）。

    返回 (l1_2048, meta)：l1_2048 为 (size,size) int32（0=非地块/海洋），
    meta = {全局 label: {region, local_label, centroid_2048}}。
    """
    glob8192 = np.zeros((8192, 8192), dtype=np.int32)
    shift = 0
    for i in range(1, 14):
        rid = "region_%03d" % i
        info = json.load(open(os.path.join(L2_PACKS, rid, "info.json"), encoding="utf-8"))
        bbox = info["bbox_8192"]
        x0, y0 = int(bbox["x0"]), int(bbox["y0"])
        seg = np.load(os.path.join(L2_PACKS, rid, "tiles_8192.npy")).astype(np.int32)
        m = seg > 0
        yy, xx = np.where(m)
        glob8192[y0 + yy, x0 + xx] = seg[yy, xx] + shift
        shift += int(seg.max())
    l1_8192 = glob8192
    l1 = np.array(Image.fromarray(l1_8192.astype(np.uint32), "I").resize(
        (size, size), Image.NEAREST)).astype(np.int32)

    # 陆地缺口修复：最近老 L1
    region = np.load(os.path.join(REGIONS_DIR, "region_labels.npy"))
    land = region > 0
    miss = land & (l1 == 0)
    if miss.any():
        _, inds = distance_transform_edt(l1 > 0, return_indices=True)
        l1[miss] = l1[inds[0][miss], inds[1][miss]]
    np.save(os.path.join(OUT_DIR, "legacy_l1_labels_2048.npy"), l1)
    return l1


def pick_city_points(land, parent, rng, spacing, jitter_fraction):
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
    pts, pi = pts[on_land], pi[on_land]
    parent_pt = parent[pi[:, 1], pi[:, 0]]
    return pts, parent_pt


def grow_cities(land, parent, cities, city_parent):
    size = land.shape[0]
    labels = np.zeros((size, size), dtype=np.int32)
    seeds = [list(p) for p in cities]
    seeds_by_parent = {}
    for i in range(len(seeds)):
        seeds_by_parent.setdefault(int(city_parent[i]), []).append(i)
    next_id = 1
    seed_of_label = {}
    for plab in np.unique(parent[parent > 0]):
        pmask = parent == plab
        pcomp, npc = ndi.label(pmask, structure=STRUCT8)
        for k in range(1, npc + 1):
            cmask = pcomp == k
            cy, cx = np.nonzero(cmask)
            idxs = [i for i in seeds_by_parent.get(int(plab), [])
                    if cmask[int(seeds[i][1]), int(seeds[i][0])]]
            if not idxs:
                gd = distance_transform_edt(cmask)
                pk = int(np.argmax(gd[cy, cx]))
                seeds.append([float(cx.ravel()[pk]), float(cy.ravel()[pk])])
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


def merge_small_cities(labels, parent, min_area):
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
            cell_group[lab] = int(parent[mm][0])
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
        cell_group[lab] = int(parent[mm][0])
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


def load_legacy_parent_colors():
    """老 L1 的父色：13 地区 l2_world.json 的 tile color -> 全局 label。"""
    pc = {}
    shift = 0
    for i in range(1, 14):
        rid = "region_%03d" % i
        view = json.load(open(os.path.join(
            HERE, "output", "l2_view_packs", rid, "l2_world.json"), encoding="utf-8"))
        for t in view["tiles"]:
            pc[shift + int(t["label"])] = list(t["color"])
        shift += max(int(t["label"]) for t in view["tiles"])
    return pc


def city_palette(city_labels, parent, parent_color, n_city):
    palette = {}
    for plab in np.unique(parent[parent > 0]):
        in_p = (parent.ravel() == plab) & (city_labels.ravel() > 0)
        if not in_p.any():
            continue
        labs, counts = np.unique(city_labels.ravel()[in_p], return_counts=True)
        order = np.argsort(-counts)
        labs = labs[order]
        m = len(labs)
        base = parent_color.get(int(plab), (170, 170, 170))
        h, s, v = colorsys.rgb_to_hsv(base[0] / 255, base[1] / 255, base[2] / 255)
        for k, lab in enumerate(labs):
            vv = 0.32 + 0.60 * (k + 0.5) / m
            r8, g8, b8 = colorsys.hsv_to_rgb(h, 0.62, vv)
            palette[int(lab)] = (int(r8 * 255), int(g8 * 255), int(b8 * 255))
    for lab in range(1, n_city + 1):
        palette.setdefault(lab, (190, 190, 190))
    return palette


def main():
    ap = argparse.ArgumentParser(description="老 L1 之下细分城市（v2，替代废弃 389 版）")
    ap.add_argument("--spacing", type=int, default=40, help="城市点网格间距（2048 级像素）")
    ap.add_argument("--jitter", type=float, default=0.4, help="扰动幅度")
    ap.add_argument("--min-city-area", type=int, default=90, help="城市面积下限（px²）")
    ap.add_argument("--seed", type=int, default=20260819, help="随机种子")
    args = ap.parse_args()
    os.makedirs(OUT_DIR, exist_ok=True)

    print("[1/6] 构建全局老 L1 蒙版（13 地区 tiles 拼接，2048）...")
    parent = build_legacy_l1_mask(2048)
    n_l1 = int(parent.max())
    land = parent > 0
    print("  老 L1 地块 %d 个，陆地 %.1f%%" % (n_l1, land.mean() * 100))

    print("[2/6] 城市点撒点（jittered grid, spacing=%d）..." % args.spacing)
    rng = np.random.default_rng(args.seed)
    pts, city_parent = pick_city_points(land, parent, rng, args.spacing, args.jitter)
    has_pt = np.zeros(n_l1 + 1, dtype=bool)
    np.add.at(has_pt, city_parent, True)
    # 每老 L1 ≥1 点：无点用老 L1 质心兜底
    for lab in range(1, n_l1 + 1):
        if not has_pt[lab]:
            ys, xs = np.where(parent == lab)
            pts = np.vstack([pts, [float(xs.mean()), float(ys.mean())]])
            city_parent = np.append(city_parent, lab)
    city_parent = city_parent.astype(np.int32)
    print("  城市点 %d 个（每老 L1 ≥1，兜底 %d）" % (len(pts), int((~has_pt[1:]).sum())))

    print("[3/6] 按老 L1 分组多源膨胀生长城市 ...")
    labels, cities, seed_of_label = grow_cities(land, parent, pts, city_parent)
    print("  膨胀后城市 %d 个" % int(labels.max()))

    print("[4/6] 城市面积下限合并 ...")
    labels, exempt, remap = merge_small_cities(labels, parent, args.min_city_area)
    n_city = int(labels.max())
    cities_final = np.array(
        [cities[seed_of_label[old]] for old, new in sorted(remap.items())
         if old in seed_of_label], dtype=np.float64)
    print("  合并后城市 %d 个，平均每老 L1 %.1f 个" % (n_city, float(n_city) / n_l1))

    print("[5/6] 多边形 + 邻接 + 配色 ...")
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
    parent_color = load_legacy_parent_colors()
    palette = city_palette(labels, parent, parent_color, n_city)

    print("[6/6] 写文件 ...")
    preview = np.zeros((2048, 2048, 3), dtype=np.uint8)
    preview[~land] = OCEAN_COLOR
    for lab, rgb in palette.items():
        preview[labels == lab] = rgb
    prev_img = Image.fromarray(preview)
    dr = ImageDraw = None
    from PIL import ImageDraw as _ID
    dr = _ID.Draw(prev_img)
    for (cx, cy) in cities_final:
        x, y = float(cx), float(cy)
        dr.ellipse([x - 3, y - 3, x + 3, y + 3], outline=(12, 12, 12), width=1)
        dr.ellipse([x - 1, y - 1, x + 1, y + 1], fill=(250, 250, 250))
    prev_img.save(os.path.join(OUT_DIR, "city_preview_2048.png"))

    idx_img = np.zeros((2048, 2048, 3), dtype=np.uint8)
    idx_img[labels > 0, 0] = (labels[labels > 0] >> 16) & 0xFF
    idx_img[labels > 0, 1] = (labels[labels > 0] >> 8) & 0xFF
    idx_img[labels > 0, 2] = labels[labels > 0] & 0xFF
    Image.fromarray(idx_img).save(os.path.join(OUT_DIR, "city_partition_2048.png"))

    city_img = np.full((2048, 2048, 3), 235, dtype=np.uint8)
    city_img[land, :] = 220
    for (cx, cy) in cities_final:
        x0c, y0c = int(cx) - 2, int(cy) - 2
        city_img[max(0, y0c):y0c + 5, max(0, x0c):x0c + 5, 0] = 200
        city_img[max(0, y0c):y0c + 5, max(0, x0c):x0c + 5, 1] = 40
        city_img[max(0, y0c):y0c + 5, max(0, x0c):x0c + 5, 2] = 40
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
        "name": "全大陆城市蒙版 v2（老 L1 之下细分）",
        "algorithm": "cells-growth（按老 L1 分组多源膨胀 + 面积下限合并）",
        "size": 2048,
        "coord": "xy",
        "spacing": args.spacing,
        "jitter": args.jitter,
        "min_city_area": args.min_city_area,
        "seed": args.seed,
        "n_legacy_l1": n_l1,
        "n_city": n_city,
        "cities": cities_out,
    }
    with open(os.path.join(OUT_DIR, "city_data.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)

    counts = np.bincount(labels.ravel())
    print("完成。城市=%d 最小%d 最大%d 平均%.0fpx 豁免%d" % (
        n_city, counts[1:].min(), counts[1:].max(),
        float(land.sum()) / n_city, len(exempt)))


if __name__ == "__main__":
    main()