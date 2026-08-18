"""全大陆 L1 地块划分 —— 在 L3 层直接把世界划分为若干 L1 地块（蒙版生产者）。

开发期一次性工具（Python）。输入 L2 地区蒙版（region_labels.npy，2048 级），输出
**全大陆 L1 蒙版**：每个像素 = 一个 L1 地块 label（0 = 海洋），同一 L2 地区内的 L1
使用相似颜色（色相同源、明度阶梯），供游戏内战略图查看/后续 L2 下钻使用。

算法 v2（细胞质膨胀，对应 2026-08 需求修订）：
  1. 城市点 = 网格平铺 + 细微扰动（jittered grid），筛选落在陆地上的点
     —— "城市是均匀分布带细微扰动的在整个地图上的点"。
  2. 岛屿保证：每个陆地连通分量（岛屿，8 连通）至少保留 1 个城市点（取离海岸最远的内点）。
  3. **岛屿 = 独立计算单元**（"孤立的岛屿上的城市单独算，当成单独的 L2 地块"）：
     以 (岛屿 × L2 地区) 分组，每组的像素**只由组内城市点竞争**，互不干扰。
  4. **细胞质膨胀**：每组内做多源同步膨胀（watershed on flat，8 连通，mask=组陆地）
     —— 细胞在陆地内生长、被海阻挡：**单个细胞不跨海、不跨湾、半岛不共用地块**；
     城市点贴近陆地边缘时细胞向陆内均匀膨胀到与其他细胞相近的大小（边缘不吃亏）。
  5. **地块面积下限**：膨胀后面积 < min_tile_area 的细胞并入（同组）面积最大邻居；
     组内唯一细胞豁免（如极小岛 = 该岛最后一块，标 small_exempt）。
  6. 蒙版配色：每个 L2 地区一个基色（黄金角色相），区内 L1 按面积排名取明度阶梯。

产出（输出到 output/l1/ 并复制到 stick-world/config/strategic_map/）：
  - l1_labels_2048.npy       全局 L1 蒙版（int32，0=海洋，1..N=L1）
  - l1_partition_2048.png    label 直编索引图（P 社 provinces.bmp 机制，运行时 hover 查询）
  - l1_preview_2048.png      蒙版预览图（同 L2 相似色，人眼查看）
  - l1_cities_2048.png       城市点分布图（检查均匀性）
  - l1_data.json             L1 地块元数据（城市点/质心/面积/多边形/邻接/蒙版色，2048 级）

用法：
  python tools/worldgen/l1/l1_world_split.py [--spacing 70] [--jitter 0.4]
      [--min-tile-area 400] [--seed N]
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
REGIONS_DIR = os.path.join(HERE, "output", "regions")
OUT_DIR = os.path.join(HERE, "output", "l1")
GAME_DIR = os.path.normpath(os.path.join(HERE, "..", "..", "stick-world", "config", "strategic_map"))
# 复用 L2 管线的共享顶点网格提取（多边形/洞/简化/平滑，与 l2_export 同源）
sys.path.insert(0, os.path.join(HERE, "l2_export"))
import mesh_extract  # noqa: E402

OCEAN_COLOR = (30, 55, 95)

# 8 连通结构元（岛/生长均 8 连通：对角线接壤视为同一陆块，与膨胀一致）
STRUCT8 = np.ones((3, 3), dtype=bool)


def golden_hue(r_index):
    """与 export_l3_view.unique_colors 同源：黄金角散布色相。"""
    return (r_index * 0.618033988749895) % 1.0


def pick_city_points(land, region, rng, spacing, jitter_fraction):
    """jittered grid 撒城市点（仅陆地），返回 (N, 2) float64 坐标（2048 级，x/y）。

    - 网格 = 陆地 bbox 内按 spacing 平铺；每格点加 [-j, +j]·spacing 独立均匀扰动。
    - 落在海里的点剔除；对每个岛屿连通分量保证至少 1 个点（补在离海最远的内点）。
    """
    size = land.shape[0]
    ys, xs = np.where(land)
    y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()

    # 网格中心（含半格偏移，保证网格对称覆盖 bbox）
    gy = np.arange(y0, y1 + spacing, spacing, dtype=np.float64) + spacing * 0.5
    gx = np.arange(x0, x1 + spacing, spacing, dtype=np.float64) + spacing * 0.5
    gyy, gxx = np.meshgrid(gy, gx, indexing="ij")
    j = spacing * jitter_fraction
    pts = np.stack([gxx.ravel(), gyy.ravel()], axis=1) + \
        (rng.random((gxx.size, 2)) * 2.0 - 1.0) * j

    # 筛掉海里的点（越界像素视为海）
    ok = (pts[:, 0] >= 0) & (pts[:, 0] < size) & (pts[:, 1] >= 0) & (pts[:, 1] < size)
    pts = pts[ok]
    pi = pts.astype(np.int64)
    on_land = land[pi[:, 1], pi[:, 0]]
    pts = pts[on_land]

    # 岛屿保证：每个连通分量至少 1 个点
    comp, n_comp = ndi.label(land, structure=STRUCT8)
    has_point = np.zeros(n_comp + 1, dtype=bool)
    if len(pts) > 0:
        comp_of_pt = comp[pi[:, 1], pi[:, 0]][on_land]
        np.add.at(has_point, comp_of_pt, True)
    # 到最近海洋/地图外的距离（内点优先）
    d = distance_transform_edt(land)
    added = []
    missing = np.nonzero(~has_point[1:])[0] + 1
    for cid in missing:
        mask = comp == cid
        if not mask.any():
            continue
        idx = int(np.argmax(d[mask]))
        py, px = np.nonzero(mask)
        added.append((float(px.ravel()[idx]), float(py.ravel()[idx])))
    all_pts = pts.tolist() + added
    return np.array(all_pts, dtype=np.float64)


def grow_l1_cells(land, region, cities):
    """细胞质膨胀：以 (岛屿 × L2 地区) 为独立计算单元，组内多源同步生长。

    每组 = 岛 ∩ 某 L2 地区：像素只归组内城市点竞争 → 细胞不跨海、不跨湾
    （生长被海阻挡）、不跨 L2 边界；边缘城市点向陆内均匀膨胀。

    返回 (labels, cities, seed_of_label, comp, n_comp)：
      labels          全局 L1 label（0=海洋，1..N 连续）
      cities          城市点坐标（含组内补点后的完整列表）
      seed_of_label   {label: cities 索引}
      comp, n_comp    岛屿标签图与数量（8 连通）
    """
    size = land.shape[0]
    comp, n_comp = ndi.label(land, structure=STRUCT8)
    labels = np.zeros((size, size), dtype=np.int32)
    seeds = [list(p) for p in cities]           # 可能追加（组内补点）

    def _cell_rc(pts):
        return comp[pts[:, 1].astype(np.int64), pts[:, 0].astype(np.int64)], \
            region[pts[:, 1].astype(np.int64), pts[:, 0].astype(np.int64)]

    seeds_arr = np.array(seeds, dtype=np.float64)
    s_comp, s_reg = _cell_rc(seeds_arr)
    group_seeds = {}
    for i in range(len(seeds_arr)):
        group_seeds.setdefault((int(s_comp[i]), int(s_reg[i])), []).append(i)

    next_id = 1
    seed_of_label = {}
    for cid in range(1, n_comp + 1):
        island = comp == cid
        for r in np.unique(region[island]):
            if r == 0:
                continue
            gmask = island & (region == r)
            # (岛 ∩ L2) 可能由多个互不相连的碎块组成（人工合并后的地区跨岛/跨湾）：
            # 按连通分量逐个生长，保证全覆盖且细胞不跨碎块（不跨海/不跨湾）
            gcomp, ng = ndi.label(gmask, structure=STRUCT8)
            for k in range(1, ng + 1):
                cmask = gcomp == k
                gy, gx = np.nonzero(cmask)
                idxs = [i for i in group_seeds.get((cid, int(r)), [])
                        if cmask[int(seeds[i][1]), int(seeds[i][0])]]
                if not idxs:
                    # 该碎块无城市点：补一个碎块内最内侧点（离海/岸边最远）
                    gd = distance_transform_edt(cmask)
                    pk = int(np.argmax(gd[gy, gx]))
                    seeds.append([float(gx.ravel()[pk]), float(gy.ravel()[pk])])
                    idxs = [len(seeds) - 1]
                markers = np.zeros((size, size), dtype=np.int32)
                for gi, sidx in enumerate(idxs):
                    px, py = int(seeds[sidx][0]), int(seeds[sidx][1])
                    markers[py, px] = next_id + gi
                # flat watershed = 多源同步膨胀（等速生长、先到先得），mask 挡住海
                seg = watershed(np.zeros((size, size), dtype=np.uint8), markers,
                                mask=cmask, connectivity=2)
                for gi, sidx in enumerate(idxs):
                    lab = next_id + gi
                    labels[seg == lab] = lab
                    seed_of_label[lab] = sidx
                next_id += len(idxs)
    return labels, np.array(seeds, dtype=np.float64), seed_of_label, comp, n_comp


def merge_small_tiles(labels, region, comp, min_area):
    """地块面积下限：< min_area 的细胞并入（同岛同 L2）面积最大邻居。

    组内唯一细胞豁免（例：极小岛只有一块，不可并入其他岛/其他 L2）。
    合并采用"先并入、每轮后重算状态"：计数即时更新，豁免在全部合并结束后
    对"仍小于下限且组内唯一"的细胞统一判定（避免吸收过程中的误判）。

    返回 (labels2, exempt, remap)：labels2 重编号 1..N；exempt = 低于下限但豁免的
    label 集合（重编号后）；remap = {旧 label: 新 label}（供城市点对齐）。
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
        # 每个存活 label 的 (岛, L2) 组
        cell_group = {}
        for lab in range(1, n + 1):
            if counts[lab] == 0:
                continue
            mm = labels == lab
            cell_group[lab] = (int(comp[mm][0]), int(region[mm][0]))
        changed = False
        for lab in range(1, n + 1):
            if counts[lab] == 0 or counts[lab] >= min_area:
                continue
            g = cell_group[lab]
            cands = [nb for nb in adj[lab]
                     if counts[nb] > 0 and cell_group.get(nb, None) == g]
            if not cands:
                continue   # 组内唯一：本轮不并，最终判定豁免
            best = max(cands, key=lambda nb: counts[nb])
            labels[labels == lab] = best
            counts[best] += counts[lab]
            counts[lab] = 0
            changed = True
        if not changed:
            break

    # 最终豁免：仍 < min_area 且**无同组相邻存活细胞**（无法在不跨海/不跨 L2 的前提下
    # 并入任何细胞——例：极小岛的唯一细胞，或同组但互不相邻的两个碎块各自唯一细胞）
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
        cell_group[lab] = (int(comp[mm][0]), int(region[mm][0]))
    exempt = set()
    for lab in range(1, n + 1):
        if counts[lab] == 0 or counts[lab] >= min_area:
            continue
        g = cell_group.get(lab)
        if not any(counts[nb] > 0 and cell_group.get(nb, None) == g for nb in adj[lab]):
            exempt.add(lab)

    # 重编号 1..N
    uniq = np.unique(labels[labels > 0])
    remap = {int(old): new for new, old in enumerate(uniq, start=1)}
    labels2 = np.zeros_like(labels)
    for old, new in remap.items():
        labels2[labels == old] = new
    return labels2, {remap[l] for l in exempt if int(l) in remap}, remap


def tile_palette(labels, region, n_l1):
    """同 L2 相似色：地区基色（黄金角色相）+ 区内 L1 明度阶梯。返回 {label: (r,g,b)}。"""
    n_regions = int(region.max())
    palette = {}
    for r in range(1, n_regions + 1):
        in_r = np.where((region.ravel() == r) & (labels.ravel() > 0))[0]
        if in_r.size == 0:
            continue
        labs, counts = np.unique(labels.ravel()[in_r], return_counts=True)
        order = np.argsort(-counts)  # 面积从大到小
        labs = labs[order]
        m = len(labs)
        h = golden_hue(r - 1)
        for k, lab in enumerate(labs):
            # 明度阶梯：0.38 ~ 0.93，同地区内相邻 L1 肉眼可辨但色系一致
            v = 0.38 + 0.55 * (k + 0.5) / m
            r8, g8, b8 = colorsys.hsv_to_rgb(h, 0.72, v)
            palette[int(lab)] = (int(r8 * 255), int(g8 * 255), int(b8 * 255))
    # 小概率漏网（如 label 未进入任何地区的循环）
    for lab in range(1, n_l1 + 1):
        palette.setdefault(lab, (200, 200, 200))
    return palette


def main():
    ap = argparse.ArgumentParser(description="全大陆 L1 地块划分（L3 级蒙版，细胞质膨胀）")
    ap.add_argument("--spacing", type=int, default=70, help="城市点网格间距（2048 级像素）")
    ap.add_argument("--jitter", type=float, default=0.4, help="扰动幅度（spacing 的比例）")
    ap.add_argument("--min-tile-area", type=int, default=400,
                    help="地块面积下限（px²，2024 级；低于则并入同组最大邻居，组唯一豁免）")
    ap.add_argument("--seed", type=int, default=20260817, help="城市点随机种子")
    args = ap.parse_args()

    print("[1/7] 加载 L2 地区蒙版（2048, 13 地区）...")
    region = np.load(os.path.join(REGIONS_DIR, "region_labels.npy"))
    size = region.shape[0]
    land = region > 0
    print("  陆地 %.1f%%" % (land.mean() * 100))

    print("[2/7] 城市点撒点（jittered grid, spacing=%d, jitter=%.2f）..." % (args.spacing, args.jitter))
    rng = np.random.default_rng(args.seed)
    cities = pick_city_points(land, region, rng, args.spacing, args.jitter)
    n_comp = ndi.label(land, structure=STRUCT8)[1]
    print("  城市点 %d 个（岛屿 %d 个，每岛至少 1 点）" % (len(cities), n_comp))

    print("[3/7] 细胞质膨胀（岛×L2 分组多源生长）...")
    labels, cities, seed_of_label, comp, n_comp = grow_l1_cells(land, region, cities)
    n_l1 = int(labels.max())
    print("  膨胀后 L1 地块 %d 个" % n_l1)

    print("[4/7] 面积下限合并（min=%dpx²）..." % args.min_tile_area)
    labels, exempt, remap = merge_small_tiles(labels, region, comp, args.min_tile_area)
    n_l1 = int(labels.max())
    per_region_labels = []
    for r in range(1, int(region.max()) + 1):
        labs = np.unique(labels[(region == r) & (labels > 0)])
        per_region_labels.append(int(labs.size))
    print("  合并后 L1 地块 %d 个；各地区 L1 数: %s" % (n_l1, ", ".join(str(v) for v in per_region_labels)))

    # 城市点对齐最终 label：保留存活旧 label 的种子（被并入细胞的种子丢弃）
    cities_final = np.array(
        [cities[seed_of_label[old]] for old, new in sorted(remap.items())
         if old in seed_of_label], dtype=np.float64)

    print("[5/7] 提取多边形 + 邻接 ...")
    mesh = mesh_extract.simplify_mesh(mesh_extract.extract_mesh(labels))
    padded = np.pad(labels, 1, mode="constant")
    adj = {lab: set() for lab in range(1, n_l1 + 1)}
    yy, xx = np.where(padded[1:-1, 1:-1] > 0)
    for y, x in zip(yy, xx):
        v = padded[y + 1, x + 1]
        for dy, dx in ((1, 0), (0, 1)):
            w = padded[y + 1 + dy, x + 1 + dx]
            if w > 0 and w != v:
                adj[int(v)].add(int(w))
                adj[int(w)].add(int(v))

    print("[6/7] 配色（同 L2 相似色）+ 写文件 ...")
    palette = tile_palette(labels, region, n_l1)
    os.makedirs(OUT_DIR, exist_ok=True)

    preview = np.zeros((size, size, 3), dtype=np.uint8)
    preview[~land] = OCEAN_COLOR
    for lab, rgb in palette.items():
        preview[labels == lab] = rgb
    Image.fromarray(preview).save(os.path.join(OUT_DIR, "l1_preview_2048.png"))

    idx_img = np.zeros((size, size, 3), dtype=np.uint8)
    idx_img[labels > 0, 0] = (labels[labels > 0] >> 16) & 0xFF
    idx_img[labels > 0, 1] = (labels[labels > 0] >> 8) & 0xFF
    idx_img[labels > 0, 2] = labels[labels > 0] & 0xFF
    Image.fromarray(idx_img).save(os.path.join(OUT_DIR, "l1_partition_2048.png"))

    city_img = np.full((size, size, 3), 235, dtype=np.uint8)
    city_img[land, :] = 220
    for (cx, cy) in cities_final:
        x0, y0 = int(cx) - 2, int(cy) - 2
        city_img[max(0, y0):y0 + 5, max(0, x0):x0 + 5, 0] = 200
        city_img[max(0, y0):y0 + 5, max(0, x0):x0 + 5, 1] = 40
        city_img[max(0, y0):y0 + 5, max(0, x0):x0 + 5, 2] = 40
    Image.fromarray(city_img).save(os.path.join(OUT_DIR, "l1_cities_2048.png"))

    np.save(os.path.join(OUT_DIR, "l1_labels_2048.npy"), labels)

    # JSON：坐标统一 (x, y) 列先行后，2048 级；多边形为像素角点（mesh_extract，已简化+平滑）
    def _decimate(loop):
        xy = [(float(p[1]), float(p[0])) for p in loop]
        pts = mesh_extract._dp_simplify(xy, 1.0)
        return [[p[0], p[1]] for p in pts]

    tiles = []
    for lab in range(1, n_l1 + 1):
        m = labels == lab
        ys, xs = np.where(m)
        city_xy = [float(cities_final[lab - 1][0]), float(cities_final[lab - 1][1])]
        rings = [list(list(p) for p in loop) for loop in mesh.get(lab, {}).get("outer", [])]
        polys = [_decimate(r) for r in rings if len(r) >= 3]
        poly = polys[0] if polys else []
        tiles.append({
            "label": lab,
            "region": int(region.ravel()[np.flatnonzero(m)[0]]),
            "city": [round(city_xy[0], 3), round(city_xy[1], 3)],
            "centroid": [round(float(xs.mean()), 3), round(float(ys.mean()), 3)],
            "land_area_px": int(m.sum()),
            "rgb": list(palette[lab]),
            "polygon": poly,
            "polygons": polys,
            "neighbors": sorted(adj[lab]),
            "small_exempt": lab in exempt,
        })
    data = {
        "name": "全大陆 L1 地块（L3 级蒙版）",
        "algorithm": "cells-growth（岛×L2 分组多源膨胀 + 面积下限合并）",
        "size": size,
        "coord": "xy",
        "spacing": args.spacing,
        "jitter": args.jitter,
        "min_tile_area": args.min_tile_area,
        "seed": args.seed,
        "n_regions": int(region.max()),
        "n_l1": n_l1,
        "tiles": tiles,
    }
    with open(os.path.join(OUT_DIR, "l1_data.json"), "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    print("  输出: %s" % OUT_DIR)

    print("[7/7] 复制到游戏 config/strategic_map/ ...")
    os.makedirs(GAME_DIR, exist_ok=True)
    import shutil
    for fn in ("l1_data.json", "l1_preview_2048.png", "l1_partition_2048.png"):
        shutil.copy(os.path.join(OUT_DIR, fn), os.path.join(GAME_DIR, fn))
        print("  -> %s" % os.path.join(GAME_DIR, fn))

    # 简要统计
    counts = np.bincount(labels.ravel())
    print("完成。L1=%d, 最小地块 %dpx, 最大地块 %dpx, 平均 %.0fpx, 豁免小地块 %d 个" % (
        n_l1, counts[1:].min(), counts[1:].max(), float(land.sum()) / n_l1, len(exempt)))


if __name__ == "__main__":
    main()