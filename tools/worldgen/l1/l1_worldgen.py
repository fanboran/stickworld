"""L1 世界生成器 —— 生成玩家第一阶段世界图（L1 单层战略图数据）。

开发期一次性工具（Python），产出：
  config/strategic_map/l1_world.json   # L1 地图矢量数据（地块/聚落/道路/政权）
  config/strategic_map/l1_base.png     # 卫星图风格底图（从锁定高度场渲染地形色）
  config/strategic_map/l1_mask.png     # 边界索引图（每 L1 地块一色，NEAREST 采样）

设计约束（docs/设计/系统/08-程序化世界生成.md §0.19）：
  - 1 个 L1 地块永远只有 1 个聚落（或空聚落）
  - 8 聚落整体 = 1 中心城市 + 若干次级聚落（标准样本 1 城 + 2 镇 + 5 部落）
  - 8 政权独立、无共同首领、全部敌对
  - 聚落位置：L1 地块内相对靠近中心
  - 聚落间道路：MST 生成
  - 贫瘠 L1 地块 = 空聚落（无聚落、无建筑、不可进入）

用法：
  python tools/worldgen/l1/l1_worldgen.py --seed N [--out <目录>] [--size 1024]
"""
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image
from scipy.spatial import ConvexHull, Voronoi
from scipy.spatial.distance import cdist

LOCKED_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "output", "locked")
DEFAULT_OUT = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..",
    "stick-world", "config", "strategic_map"))

# 地形色（卫星图风格：水蓝/平原绿/丘陵黄绿/山地棕/高山白）
COLOR_DEEP_WATER = (28, 62, 96)
COLOR_SHALLOW_WATER = (42, 92, 128)
COLOR_PLAINS = (108, 148, 84)
COLOR_HILLS = (142, 138, 92)
COLOR_MOUNTAIN = (152, 128, 106)
COLOR_SNOW = (228, 226, 218)

# 聚落规模分桶（标准样本：1 城 + 2 镇 + 5 部落，其余地块空）
LEVEL_CITY = 3      # T3 城市
LEVEL_TOWN = 2      # T2 镇
LEVEL_TRIBE = 1     # T1 部落/村落

# 政权限定色板（8 政权各自独立色，用于边界线着色）
STATE_COLORS = [
    (220, 60, 60), (60, 120, 220), (60, 200, 120), (230, 170, 50),
    (170, 90, 220), (40, 190, 200), (230, 100, 170), (150, 150, 150),
]

# 聚落地图 map_id 分配：settlement_mapgen.py 生成的 8 张可玩地图（按 tile 索引排序）
# 与 settlement_mapgen.py 输出顺序一致：settlement_00->l1_settlement_00, ...
SETTLEMENT_MAP_IDS = [
    "l1_settlement_00", "l1_settlement_01", "l1_settlement_02", "l1_settlement_03",
    "l1_settlement_04", "l1_settlement_05", "l1_settlement_06", "l1_settlement_07",
]


def load_inputs():
    """加载锁定的高度场与大陆掩码（cropped 版本）。"""
    heightmap = np.load(os.path.join(LOCKED_DIR, "locked_heightmap_cropped.npy"))
    mask = np.load(os.path.join(LOCKED_DIR, "locked_continent_cropped.png.npy"))
    return heightmap, mask


def downsample(h, m, size):
    """降采样到工作分辨率（高度场 BILINEAR，掩码 NEAREST）。"""
    def _resize(arr, method):
        if arr.dtype == np.float32:
            img = Image.fromarray(arr, "F")
        else:
            img = Image.fromarray(arr * 255, "L")
        img = img.resize((size, size), method)
        out = np.array(img)
        if arr.dtype == np.float32:
            return out.astype(np.float32)
        return (out > 127).astype(np.uint8)
    h_r = _resize(h, Image.BILINEAR)
    m_r = _resize(m, Image.NEAREST)
    return h_r, m_r


def generate_tiles(h, m, rng, min_land_ratio=0.02):
    """在地块内撒 Voronoi 种子（仅陆地），Lloyd 松弛后生成 L1 地块。

    返回 (labels, seeds)：labels 是每个像素的地块索引（-1 = 海洋），
    seeds 是地块种子点像素坐标。
    """
    size = h.shape[0]
    land_ys, land_xs = np.where(m > 0)
    n_land = land_ys.size
    # 种子数量由陆地面积决定（约每 2.5% 陆地一个地块，下限 10 上限 16）
    n_seeds = max(10, min(16, int(n_land / (size * size) * 100 / 2.5)))
    idx = rng.choice(n_land, n_seeds, replace=False)
    seeds = np.stack([land_xs[idx], land_ys[idx]], axis=1).astype(np.float64)

    # Lloyd 松弛 3 轮：每轮把种子移到地块质心
    for _ in range(3):
        labels, _ = assign_tiles(size, seeds, m)
        new_seeds = []
        for s in range(n_seeds):
            ys, xs = np.where(labels == s)
            if xs.size == 0:
                new_seeds.append(seeds[s])
            else:
                new_seeds.append([xs.mean(), ys.mean()])
        seeds = np.array(new_seeds)
    labels, _ = assign_tiles(size, seeds, m)
    return labels, seeds


def assign_tiles(size, seeds, m):
    """按最近种子分配地块（带海洋掩码）。返回 (labels, dist)。"""
    yy, xx = np.meshgrid(np.arange(size), np.arange(size), indexing="ij")
    pts = np.stack([xx.ravel(), yy.ravel()], axis=1).astype(np.float64)
    d = cdist(pts, seeds)                  # (N*N, n_seeds)
    labels = d.argmin(axis=1).reshape(size, size).astype(np.int32)
    dist = d.min(axis=1).reshape(size, size)
    labels[m == 0] = -1                      # 海洋无地块
    return labels, dist


def tile_polygon(labels, tile_idx, size):
    """提取地块多边形：Voronoi cell 是凸多边形，取边缘像素的凸包即可。

    返回像素坐标顶点列表 [[x, y], ...]（顺序 = 凸包顺序，可直接描边）。
    """
    mask = labels == tile_idx
    ys, xs = np.where(mask)
    if xs.size == 0:
        return []
    # 边缘像素 = mask 且 8 邻域并非全部是 mask（AND 后取反）
    padded = np.zeros((size + 2, size + 2), dtype=bool)
    padded[1:-1, 1:-1] = mask
    all_neigh = (
        padded[1:-1, 0:-2] & padded[1:-1, 2:] &
        padded[0:-2, 1:-1] & padded[2:, 1:-1] &
        padded[0:-2, 0:-2] & padded[0:-2, 2:] &
        padded[2:, 0:-2] & padded[2:, 2:]
    )
    edge = mask & ~all_neigh
    eys, exs = np.where(edge)
    if eys.size < 3:
        return [[int(x), int(y)] for x, y in zip(exs, eys)]
    hull = ConvexHull(np.stack([exs, eys], axis=1))
    verts = hull.points[hull.vertices]
    return [[int(x), int(y)] for x, y in verts]


def score_tiles(h, m, labels, n_tiles):
    """地块适宜度评分：面积 + 平均海拔（平原更宜居）+ 水域邻近。"""
    size = h.shape[0]
    scores = {}
    land_frac = np.zeros(n_tiles)
    for t in range(n_tiles):
        ys, xs = np.where(labels == t)
        if xs.size == 0:
            scores[t] = 0.0
            continue
        area = xs.size / (size * size)
        elev = h[ys, xs].mean()
        # 平原(0.26-0.55)最优，水域/高山惩罚
        if elev < 0.05:
            elev_score = 0.0
        elif elev < 0.26:
            elev_score = 0.5
        elif elev < 0.55:
            elev_score = 1.0
        elif elev < 0.78:
            elev_score = 0.4
        else:
            elev_score = 0.1
        land_frac[t] = area
        scores[t] = area * 5.0 + elev_score * 2.0
    return scores, land_frac


def place_settlements(labels, seeds, scores, land_frac, rng):
    """选 8 个地块放聚落（1 城 + 2 镇 + 5 部落），位置 = 地块内靠近中心。

    返回 {tile_idx: (position_px, level)}，空地块不出现在结果中。
    """
    ranked = sorted(scores.items(), key=lambda kv: kv[1], reverse=True)
    eligible = [(t, s) for t, s in ranked if land_frac[t] >= 0.008]
    if len(eligible) < 8:
        eligible = ranked[:8]
    chosen = [t for t, _ in eligible[:8]]
    # 规模分配：最高分 = 城市，其次 2 个 = 镇，其余 5 个 = 部落
    levels = {chosen[0]: LEVEL_CITY}
    for t in chosen[1:3]:
        levels[t] = LEVEL_TOWN
    for t in chosen[3:]:
        levels[t] = LEVEL_TRIBE
    placements = {}
    for t in chosen:
        seed = seeds[t]
        ys, xs = np.where(labels == t)
        # 地块内最靠近种子（质心）的陆地像素 = 聚落位置
        dist_to_seed = (xs - seed[0]) ** 2 + (ys - seed[1]) ** 2
        k = dist_to_seed.argmin()
        px, py = int(xs[k]), int(ys[k])
        placements[t] = (np.array([px, py]), levels[t])
    return placements


def build_roads(placements, size):
    """聚落间 MST 道路（欧氏距离），返回边列表 [(from_idx, to_idx)]。

    from_idx/to_idx 为 placements 的字典键（tile_idx）。
    """
    keys = list(placements.keys())
    pts = np.array([placements[k][0] for k in keys], dtype=np.float64)
    n = len(keys)
    d = cdist(pts, pts)
    in_mst = [False] * n
    in_mst[0] = True
    edges = []
    for _ in range(n - 1):
        best = None
        best_d = np.inf
        for i in range(n):
            if not in_mst[i]:
                continue
            for j in range(n):
                if in_mst[j]:
                    continue
                if d[i, j] < best_d:
                    best_d = d[i, j]
                    best = (i, j)
        if best is None:
            break
        i, j = best
        in_mst[j] = True
        edges.append((keys[i], keys[j]))
    return edges


def render_base_png(h, m, out_path):
    """卫星图风格底图：高度场 → 地形色。"""
    size = h.shape[0]
    img = np.zeros((size, size, 3), dtype=np.uint8)
    elev = h.copy()
    # 水体
    water = m == 0
    img[water] = COLOR_DEEP_WATER
    # 浅水（近岸）
    from scipy.ndimage import binary_dilation
    land = m > 0
    coast = binary_dilation(land, iterations=2) & (~land)
    img[coast] = COLOR_SHALLOW_WATER
    # 陆地按海拔分级
    land_px = np.where(land)
    img[land_px] = COLOR_PLAINS
    img[land_px[0][elev[land] >= 0.55], land_px[1][elev[land] >= 0.55]] = COLOR_HILLS
    img[land_px[0][elev[land] >= 0.65], land_px[1][elev[land] >= 0.65]] = COLOR_MOUNTAIN
    img[land_px[0][elev[land] >= 0.78], land_px[1][elev[land] >= 0.78]] = COLOR_SNOW
    Image.fromarray(img).save(out_path)
    return out_path


def render_mask_png(labels, out_path):
    """边界索引图：每 L1 地块一个唯一 RGB（编码 tile 索引+1）。"""
    size = labels.shape[0]
    img = np.zeros((size, size, 3), dtype=np.uint8)
    n = labels.max() + 1
    for t in range(n):
        if t >= 16777215:
            break
        ys, xs = np.where(labels == t)
        if xs.size == 0:
            continue
        code = t + 1  # 0 = 海洋/空
        img[ys, xs, 0] = (code >> 16) & 0xFF
        img[ys, xs, 1] = (code >> 8) & 0xFF
        img[ys, xs, 2] = code & 0xFF
    Image.fromarray(img).save(out_path)
    return out_path


def main():
    p = argparse.ArgumentParser(description="L1 世界生成器")
    p.add_argument("--seed", type=int, default=4242424248)
    p.add_argument("--out", type=str, default=DEFAULT_OUT)
    p.add_argument("--size", type=int, default=1024)
    args = p.parse_args()

    os.makedirs(args.out, exist_ok=True)
    rng = np.random.default_rng(args.seed)

    print(f"[1/6] 加载锁定高度场/掩码...")
    h, m = load_inputs()
    h, m = downsample(h, m, args.size)
    print(f"  工作分辨率 {args.size}x{args.size}，陆地 {(m>0).mean()*100:.1f}%")

    print("[2/6] Voronoi 划分 L1 地块（Lloyd 松弛）...")
    labels, seeds = generate_tiles(h, m, rng)
    n_tiles = seeds.shape[0]
    print(f"  地块数: {n_tiles}")

    print("[3/6] 地块适宜度评分 + 8 聚落定位...")
    scores, land_frac = score_tiles(h, m, labels, n_tiles)
    placements = place_settlements(labels, seeds, scores, land_frac, rng)
    print(f"  聚落数: {len(placements)}（1 城 + 2 镇 + 5 部落）")

    print("[4/6] MST 道路...")
    roads = build_roads(placements, args.size)
    print(f"  道路边数: {len(roads)}")

    print("[5/6] 卫星图底图 + 边界索引图...")
    base_path = os.path.join(args.out, "l1_base.png")
    mask_path = os.path.join(args.out, "l1_mask.png")
    render_base_png(h, m, base_path)
    render_mask_png(labels, mask_path)

    print("[6/6] 写 l1_world.json...")
    tiles_json = []
    # 全部地块按 tile 索引顺序输出（保证 tiles[i] 对应索引图 code=i+1）
    settled_indices = sorted(placements.keys())
    map_id_by_tile = {}
    for i, t in enumerate(settled_indices):
        map_id_by_tile[t] = SETTLEMENT_MAP_IDS[i % len(SETTLEMENT_MAP_IDS)]
    for t in range(n_tiles):
        if t in placements:
            pos, level = placements[t]
            tiles_json.append({
                "tile_id": "l1_tile_%02d" % t,
                "polygon": tile_polygon(labels, t, args.size),
                "settlement": {
                    "settlement_id": "settlement_%02d" % t,
                    "name": "聚落%d" % (t + 1),
                    "level": level,
                    "position_px": [int(pos[0]), int(pos[1])],
                    "map_id": map_id_by_tile[t],
                },
            })
        else:
            tiles_json.append({
                "tile_id": "l1_tile_%02d" % t,
                "polygon": tile_polygon(labels, t, args.size),
                "settlement": None,
            })

    roads_json = [
        {"from": "settlement_%02d" % a, "to": "settlement_%02d" % b}
        for a, b in roads
    ]
    states_json = []
    for i, (t, _) in enumerate(sorted(placements.items())):
        c = STATE_COLORS[i % len(STATE_COLORS)]
        states_json.append({
            "state_id": "state_%02d" % i,
            "name": "城邦%d" % (i + 1),
            "capital_settlement_id": "settlement_%02d" % t,
            "color": [c[0], c[1], c[2]],
        })

    world = {
        "map_id": "l1_main",
        "name": "L1 起始地块",
        "size": args.size,
        "seed": args.seed,
        "base_texture": "l1_base.png",
        "mask_texture": "l1_mask.png",
        "tiles": tiles_json,
        "roads": roads_json,
        "states": states_json,
        "spawn_settlement_id": states_json[0]["capital_settlement_id"],
    }
    json_path = os.path.join(args.out, "l1_world.json")
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(world, f, ensure_ascii=False, indent=1)
    print(f"  -> {json_path}")
    print(f"  -> {base_path}")
    print(f"  -> {mask_path}")
    print("完成。")


if __name__ == "__main__":
    sys.exit(main())
