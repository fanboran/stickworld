"""L3 大世界视图素材导出 —— 13 个 L2 地区分块 + 海洋归边 + 轮廓/邻接。

供 M 键战略图（L3 视图）使用。分块是"地面+海洋一起分"：
  - 陆地区域：沿用地区实际分界线（region_labels.npy）
  - 海洋区域：EDT 距离归边——每个海洋像素归入最近的地区多边形
    （两个陆地块隔海时，分界线自动形成直线延长；陆地接壤则沿用实际边界）

产出（输出到 output/l3_view/ 与 stick-world/config/strategic_map/）：
  - l3_partition_2048.png   分区索引图（每地区唯一 RGB，含海洋归边）
  - l3_base_2048.png        L3 底图（preview_fractal 降采样 2048）
  - l3_world.json           地区轮廓多边形（含海洋延长）/邻接/类型/质心
  - color_map.json          索引图颜色 -> 地区

用法：
  python tools/worldgen/l2_export/export_l3_view.py
"""
import json
import os

import numpy as np
from PIL import Image
from scipy import ndimage as ndi
from scipy.ndimage import distance_transform_edt
from skimage.measure import find_contours

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REGIONS_DIR = os.path.join(HERE, "output", "regions")
LOCKED_DIR = os.path.join(HERE, "output", "locked")
OUT_DIR = os.path.join(HERE, "output", "l3_view")
L2_PACKS_DIR = os.path.join(HERE, "output", "l2_packs")
GAME_DIR = os.path.normpath(os.path.join(HERE, "..", "..", "stick-world", "config", "strategic_map"))

OCEAN_COLOR = (30, 55, 95)


def unique_colors(n):
    colors = []
    for i in range(n):
        h = (i * 0.618033988749895) % 1.0
        s = 0.65 + 0.2 * ((i * 7) % 3) / 2.0
        l = 0.45 + 0.25 * ((i * 11) % 3) / 2.0
        c = (1 - abs(2 * l - 1)) * s
        x = c * (1 - abs((h * 6) % 2 - 1))
        m = l - c / 2
        if h < 1 / 6: r, g, b = c, x, 0
        elif h < 2 / 6: r, g, b = x, c, 0
        elif h < 3 / 6: r, g, b = 0, c, x
        elif h < 4 / 6: r, g, b = 0, x, c
        elif h < 5 / 6: r, g, b = x, 0, c
        else: r, g, b = c, 0, x
        colors.append((int((r + m) * 255), int((g + m) * 255), int((b + m) * 255)))
    return colors


def main():
    print("[1/5] 加载 labels（2048, 13 地区）...")
    labels = np.load(os.path.join(REGIONS_DIR, "region_labels.npy"))
    size = labels.shape[0]
    n_regions = int(labels.max())
    land = labels > 0
    print("  地区数: %d, 陆地 %.1f%%" % (n_regions, land.mean() * 100))

    print("[2/5] 海洋归边（EDT 最近地区）...")
    # 每个地区做一次距离变换：海洋像素 -> 最近地区
    partition = labels.copy().astype(np.int32)
    ocean = ~land
    ocean_dist = np.full((size, size), np.inf, dtype=np.float32)
    ocean_owner = np.zeros((size, size), dtype=np.int32)
    for lab in range(1, n_regions + 1):
        m = labels == lab
        d = distance_transform_edt(~m)
        # 只更新海洋像素的最小距离
        better = d < ocean_dist
        ocean_dist[better] = d[better]
        ocean_owner[better] = lab
    partition[ocean] = ocean_owner[ocean]
    print("  海洋归边完成（分块 = 地面+海洋）")

    print("[3/5] 提取地区轮廓（陆地边界 + 海洋归边）...")
    colors = unique_colors(n_regions)

    # 8192 级共享网格：从 13 地区 mask_8192_full.png 合成 8192 级地区标签图
    # （L3 渲染边界精细，放大无马赛克；hover 查询仍用 2048 索引图）
    import mesh_extract
    labels8192 = np.zeros((8192, 8192), dtype=np.int32)
    for rid in range(1, n_regions + 1):
        m = np.array(Image.open(os.path.join(
            L2_PACKS_DIR, "region_%03d" % rid, "mask_8192_full.png"))) > 0
        labels8192[m] = rid
    mesh8192 = mesh_extract.simplify_mesh(mesh_extract.extract_mesh(labels8192))

    regions = []
    for lab in range(1, n_regions + 1):
        # 陆地实际边界（用户要求：地面按实际分界线）
        m_land = labels == lab
        # 兼容字段 land_polygon：2048 级（查询测试用，与 2048 索引图坐标一致）
        contours_land = find_contours(m_land.astype(np.uint8), 0.5)
        land_poly = None
        if contours_land:
            c = contours_land[0]
            step = max(1, len(c) // 300)
            land_poly = [[float(x), float(y)] for x, y in c[::step]]
        # 渲染字段 land_polygons/land_holes：8192 级共享网格（放大精细无马赛克）
        land_polys = []  # 外轮廓（所有岛屿，8192 级，一个都别丢）
        land_holes = []  # 洞轮廓（C 形地区内的海洋，8192 级）
        mv = mesh8192.get(lab, {"outer": [], "holes": []})
        land_polys = mv["outer"]
        land_holes = mv["holes"]
        # 海洋归边后的完整轮廓（用于 hover 高亮填充，含海洋延长）
        m_full = partition == lab
        contours_full = find_contours(m_full.astype(np.uint8), 0.5)
        full_poly = None
        if contours_full:
            c = contours_full[0]
            step = max(1, len(c) // 300)
            full_poly = [[float(x), float(y)] for x, y in c[::step]]
        ys, xs = np.where(m_land)
        regions.append({
            "label": lab,
            "color": list(colors[lab - 1]),
            "area_px": int(m_land.sum()),
            "land_ratio": float(m_land.mean()),
            "centroid": [float(xs.mean()), float(ys.mean())],
            "land_polygon": land_poly or [],
            "land_polygons": land_polys,  # 全部岛屿外轮廓（渲染用）
            "land_holes": land_holes,     # 洞轮廓（挖空用）
            "full_polygon": full_poly or [],
        })
    # 邻接（分区后 4 邻域）
    padded = np.pad(partition, 1, mode="constant")
    adj = {lab: set() for lab in range(1, n_regions + 1)}
    ys, xs = np.where(padded[1:-1, 1:-1] > 0)
    for y, x in zip(ys, xs):
        v = padded[y + 1, x + 1]
        for dy, dx in ((1, 0), (0, 1)):
            w = padded[y + 1 + dy, x + 1 + dx]
            if w != 0 and w != v:
                adj[int(v)].add(int(w))
    for r in regions:
        r["adjacent"] = sorted(adj[r["label"]])
    # 陆地实际接壤对（用于区分：接壤沿用实际边界；纯隔海画质心连线直线）
    land_adj = {}
    for lab in range(1, n_regions + 1):
        m = labels == lab
        padded_land = np.pad(m, 1)
        neigh = (padded_land[1:-1, 0:-2] | padded_land[1:-1, 2:] |
                 padded_land[0:-2, 1:-1] | padded_land[2:, 1:-1]) & (labels > 0) & ~m
        land_adj[lab] = set(int(v) for v in np.unique(labels[neigh]) if v != 0)
    # 隔海邻接对 -> 两陆地多边形最近点连线（直线延长，渲染时画）
    sea_links = []
    seen = set()
    for lab in range(1, n_regions + 1):
        for other in adj[lab]:
            if other <= lab or (other, lab) in seen:
                continue
            seen.add((lab, other))
            if other in land_adj[lab]:
                continue  # 陆地接壤，不需要直线
            # 求两陆地多边形最近点对（cdist 暴力，轮廓已采样 300 点）
            pa = np.array(regions[lab - 1]["land_polygon"], dtype=np.float64)
            pb = np.array(regions[other - 1]["land_polygon"], dtype=np.float64)
            if pa.size == 0 or pb.size == 0:
                continue
            d = np.sqrt(((pa[:, None, :] - pb[None, :, :]) ** 2).sum(axis=2))
            ia, ib = np.unravel_index(np.argmin(d), d.shape)
            sea_links.append({
                "a": lab, "b": other,
                "p1": [float(pa[ia, 0]), float(pa[ia, 1])],
                "p2": [float(pb[ib, 0]), float(pb[ib, 1])],
            })
    print("  陆地接壤对 %d 组, 隔海直线链接 %d 条" % (
        sum(len(v) for v in land_adj.values()) // 2, len(sea_links)))

    print("[4/5] 输出素材...")
    os.makedirs(OUT_DIR, exist_ok=True)
    # 分区索引图：**label 直编**（RGB 编码 label，P 社 provinces.bmp 机制，运行时解码即 label）
    # 预览用唯一色图单独存（人眼看）
    idx_img = np.zeros((size, size, 3), dtype=np.uint8)
    idx_img[partition == 0] = OCEAN_COLOR
    for lab in range(1, n_regions + 1):
        m = partition == lab
        # 编码：code = label（RGB 三通道）
        idx_img[m, 0] = (lab >> 16) & 0xFF
        idx_img[m, 1] = (lab >> 8) & 0xFF
        idx_img[m, 2] = lab & 0xFF
    Image.fromarray(idx_img).save(os.path.join(OUT_DIR, "l3_partition_2048.png"))
    # 唯一色预览（人眼看分区效果）
    colors = unique_colors(n_regions)
    prev = np.zeros((size, size, 3), dtype=np.uint8)
    prev[partition == 0] = OCEAN_COLOR
    color_map = {"ocean": "#%02x%02x%02x" % OCEAN_COLOR, "labels": {}}
    for r in regions:
        color = colors[r["label"] - 1]
        prev[partition == r["label"]] = color
        color_map["labels"][str(r["label"])] = "#%02x%02x%02x" % color
    Image.fromarray(prev).save(os.path.join(OUT_DIR, "l3_partition_preview.png"))
    with open(os.path.join(OUT_DIR, "color_map.json"), "w", encoding="utf-8") as f:
        json.dump(color_map, f, indent=1)
    # 世界数据（渲染坐标系 = 8192 级网格；索引图 2048 级仅作查询）
    # 渲染为纯矢量（色块+描边），不再需要底图/边界位图
    world = {
        "name": "L3 大世界",
        "size": 8192,
        "n_regions": n_regions,
        "mask_texture": "l3_partition_2048.png",
        "regions": regions,
        "sea_links": sea_links,
    }
    with open(os.path.join(OUT_DIR, "l3_world.json"), "w", encoding="utf-8") as f:
        json.dump(world, f, ensure_ascii=False, indent=1)

    print("[5/5] 复制到游戏 config/strategic_map/ ...")
    os.makedirs(GAME_DIR, exist_ok=True)
    for fn in ("l3_world.json", "l3_partition_2048.png", "color_map.json"):
        src = os.path.join(OUT_DIR, fn)
        dst = os.path.join(GAME_DIR, fn)
        import shutil
        shutil.copy(src, dst)
        print("  -> %s" % dst)

    print("完成。输出: %s" % OUT_DIR)
    print("  地区邻接示例: %s" % regions[0]["adjacent"])


if __name__ == "__main__":
    main()
