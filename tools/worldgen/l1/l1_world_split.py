"""全大陆 L1 地块划分 —— 在 L3 层直接把世界划分为若干 L1 地块（蒙版生产者）。

开发期一次性工具（Python）。输入 L2 地区蒙版（region_labels.npy，2048 级），输出
**全大陆 L1 蒙版**：每个像素 = 一个 L1 地块 label（0 = 海洋），同一 L2 地区内的 L1
使用相似颜色（色相同源、明度阶梯），供游戏内战略图查看/后续 L2 下钻使用。

算法（对应需求）：
  1. 城市点 = 网格平铺 + 细微扰动（jittered grid），筛选落在陆地上的点
     —— "城市是均匀分布带细微扰动的在整个地图上的点"。
  2. 岛屿保证：每个陆地连通分量（岛屿）至少保留 1 个城市点（取离海岸最远的内点）。
  3. L1 划分 = 受限 Voronoi（细胞算法）：全图最近种子直线平分（植物细胞直线边界）；
     像素若被"跨 L2 地区"的种子抢走，改归本地区内最近种子 —— L1 细胞的对外边界
     从此贴住 L2 地区边界（"正好在 L2 地块边界处采用 L2 地块的边界"），
     且 L1 ⊂ L2 层级细分一致（子层并集 = 父层多边形，与 08-程序化世界生成.md §八一致）。
  4. 蒙版配色：每个 L2 地区一个基色（黄金角色相），区内 L1 按面积排名取明度阶梯
     —— "同一个 L2 地块的 L1 使用相似的颜色"。

产出（输出到 output/l1/ 并复制到 stick-world/config/strategic_map/）：
  - l1_labels_2048.npy       全局 L1 蒙版（int32，0=海洋，1..N=L1）
  - l1_partition_2048.png    label 直编索引图（P 社 provinces.bmp 机制，运行时 hover 查询）
  - l1_preview_2048.png      蒙版预览图（同 L2 相似色，人眼查看）
  - l1_cities_2048.png       城市点分布图（检查均匀性）
  - l1_data.json             L1 地块元数据（城市点/质心/面积/多边形/邻接/蒙版色，2048 级）

用法：
  python tools/worldgen/l1/l1_world_split.py [--spacing 70] [--jitter 0.4] [--seed N]
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
from scipy.spatial import cKDTree

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # tools/worldgen
REGIONS_DIR = os.path.join(HERE, "output", "regions")
OUT_DIR = os.path.join(HERE, "output", "l1")
GAME_DIR = os.path.normpath(os.path.join(HERE, "..", "..", "stick-world", "config", "strategic_map"))
# 复用 L2 管线的共享顶点网格提取（多边形/洞/简化/平滑，与 l2_export 同源）
sys.path.insert(0, os.path.join(HERE, "l2_export"))
import mesh_extract  # noqa: E402

OCEAN_COLOR = (30, 55, 95)


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
    comp, n_comp = ndi.label(land)
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


def assign_l1_labels(land, region, cities):
    """受限 Voronoi：最近种子直线划分 + 跨 L2 修正。

    返回 labels (int32)：0=海洋，1..N=L1（按城市点顺序）。
    """
    size = land.shape[0]
    labels = np.zeros((size, size), dtype=np.int32)
    ys, xs = np.where(land)
    pixels = np.stack([xs.astype(np.float64), ys.astype(np.float64)], axis=1)

    tree_all = cKDTree(cities)
    _, nearest = tree_all.query(pixels, k=1)
    city_region = region[cities[:, 1].astype(np.int64), cities[:, 0].astype(np.int64)]

    # 先按全局最近种子分配
    labels[land] = (nearest + 1).astype(np.int32)

    # 跨地区修正：像素所属 L2 地区 != 最近种子所属地区 -> 改归本地区内最近种子
    px_region = region[ys, xs]
    mism = px_region != city_region[nearest]
    if mism.any():
        pm_y, pm_x = ys[mism], xs[mism]
        pm_px = np.stack([pm_x.astype(np.float64), pm_y.astype(np.float64)], axis=1)
        fixed = np.zeros(pm_px.shape[0], dtype=np.int64)
        for r in range(1, int(region.max()) + 1):
            sel = px_region[mism] == r
            if not sel.any():
                continue
            sub = cities[city_region == r]
            if len(sub) == 0:
                continue
            tree_r = cKDTree(sub)
            _, sub_nearest = tree_r.query(pm_px[sel], k=1)
            # sub 索引 -> 全局城市索引
            fixed[sel] = np.nonzero(city_region == r)[0][sub_nearest]
        labels[pm_y, pm_x] = (fixed + 1).astype(np.int32)
    return labels


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
    ap = argparse.ArgumentParser(description="全大陆 L1 地块划分（L3 级蒙版）")
    ap.add_argument("--spacing", type=int, default=70, help="城市点网格间距（2048 级像素）")
    ap.add_argument("--jitter", type=float, default=0.4, help="扰动幅度（spacing 的比例）")
    ap.add_argument("--seed", type=int, default=20260817, help="城市点随机种子")
    args = ap.parse_args()

    print("[1/6] 加载 L2 地区蒙版（2048, 13 地区）...")
    region = np.load(os.path.join(REGIONS_DIR, "region_labels.npy"))
    size = region.shape[0]
    land = region > 0
    print("  陆地 %.1f%%" % (land.mean() * 100))

    print("[2/6] 城市点撒点（jittered grid, spacing=%d, jitter=%.2f）..." % (args.spacing, args.jitter))
    rng = np.random.default_rng(args.seed)
    cities = pick_city_points(land, region, rng, args.spacing, args.jitter)
    n_comp = ndi.label(land)[1]
    print("  城市点 %d 个（岛屿 %d 个，每岛至少 1 点）" % (len(cities), n_comp))

    print("[3/6] 受限 Voronoi 划分 L1 ...")
    labels = assign_l1_labels(land, region, cities)
    n_l1 = int(labels.max())
    # 清掉空细胞（极小概率：种子被挤出陆地边缘后无像素）：重编号
    uniq, counts = np.unique(labels[labels > 0], return_counts=True)
    if len(uniq) != n_l1:
        remap = np.zeros(n_l1 + 1, dtype=np.int32)
        for new_lab, old_lab in enumerate(uniq, start=1):
            remap[old_lab] = new_lab
        labels = remap[labels]
        n_l1 = int(labels.max())
    per_region_labels = []
    for r in range(1, int(region.max()) + 1):
        labs = np.unique(labels[(region == r) & (labels > 0)])
        per_region_labels.append(int(labs.size))
    print("  L1 地块 %d 个；各地区 L1 数: %s" % (n_l1, ", ".join(str(v) for v in per_region_labels)))

    print("[4/6] 提取多边形 + 邻接 ...")
    mesh = mesh_extract.simplify_mesh(mesh_extract.extract_mesh(labels))
    # 邻接（陆地 4 邻域）
    padded = np.pad(labels, 1, mode="constant")
    adj = {lab: set() for lab in range(1, n_l1 + 1)}
    yy, xx = np.where(padded[1:-1, 1:-1] > 0)
    for y, x in zip(yy, xx):
        v = padded[y + 1, x + 1]
        for dy, dx in ((1, 0), (0, 1)):
            w = padded[y + 1 + dy, x + 1 + dx]
            if w > 0 and w != v:
                adj[int(v)].add(int(w))
                adj[int(w)].add(int(v))  # 对称化（只扫右/下，反向补上）

    print("[5/6] 配色（同 L2 相似色）+ 写文件 ...")
    palette = tile_palette(labels, region, n_l1)
    os.makedirs(OUT_DIR, exist_ok=True)

    # 蒙版预览图（相似色）+ label 直编索引图 + 城市点分布图
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
    for (cx, cy) in cities:
        x0, y0 = int(cx) - 2, int(cy) - 2
        city_img[max(0, y0):y0 + 5, max(0, x0):x0 + 5, 0] = 200
        city_img[max(0, y0):y0 + 5, max(0, x0):x0 + 5, 1] = 40
        city_img[max(0, y0):y0 + 5, max(0, x0):x0 + 5, 2] = 40
    Image.fromarray(city_img).save(os.path.join(OUT_DIR, "l1_cities_2048.png"))

    np.save(os.path.join(OUT_DIR, "l1_labels_2048.npy"), labels)

    # JSON：坐标统一 (x, y) 列先行后，2048 级；多边形为像素角点（mesh_extract，已简化+平滑）
    # 一个 L1 细胞可能由多个连通外环组成（C 形地区/跨海湾），全部存下；环内点抽稀（DP 1px）
    def _decimate(loop):
        xy = [(float(p[1]), float(p[0])) for p in loop]  # (y,x) -> 内部 DP 用 xy 亦可
        pts = mesh_extract._dp_simplify(xy, 1.0)
        return [[p[0], p[1]] for p in pts]

    tiles = []
    for lab in range(1, n_l1 + 1):
        m = labels == lab
        ys, xs = np.where(m)
        city_xy = [float(cities[lab - 1][0]), float(cities[lab - 1][1])]
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
        })
    data = {
        "name": "全大陆 L1 地块（L3 级蒙版）",
        "size": size,
        "coord": "xy",
        "spacing": args.spacing,
        "jitter": args.jitter,
        "seed": args.seed,
        "n_regions": int(region.max()),
        "n_l1": n_l1,
        "tiles": tiles,
    }
    with open(os.path.join(OUT_DIR, "l1_data.json"), "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    print("  输出: %s" % OUT_DIR)

    print("[6/6] 复制到游戏 config/strategic_map/ ...")
    os.makedirs(GAME_DIR, exist_ok=True)
    import shutil
    for fn in ("l1_data.json", "l1_preview_2048.png", "l1_partition_2048.png"):
        shutil.copy(os.path.join(OUT_DIR, fn), os.path.join(GAME_DIR, fn))
        print("  -> %s" % os.path.join(GAME_DIR, fn))

    # 简要统计
    min_area = int(np.bincount(labels.ravel())[1:].min())
    max_area = int(np.bincount(labels.ravel())[1:].max())
    print("完成。L1=%d, 最小地块 %dpx, 最大地块 %dpx, 平均 %.0fpx" % (
        n_l1, min_area, max_area, float(land.sum()) / n_l1))


if __name__ == "__main__":
    main()