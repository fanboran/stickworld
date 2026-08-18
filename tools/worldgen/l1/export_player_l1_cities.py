"""玩家初始 L1 地块城市视图导出 —— Tab 战略图显示"出生 L1 的各个城市"。

输入：
  - output/l1/city_data.json         城市元数据（parent_l1 / city 点 / rgb / polygons，2048 全局）
  - output/l1/l1_data.json           L1 元数据（player_start 标记 / 城市点）
  - output/l1/city_labels_2048.npy  城市蒙版（求 bbox）

产出（写入 stick-world/config/strategic_map/，覆盖 Tab 战略图数据源）：
  - l1_world.json      L1WorldData 兼容格式：tiles = 出生 L1 的城市（每城市 = 1 地块 1 聚落），
                       states = 每城市独立政权（城邦模型延续），roads = 城市点 MST
  - l1_base.png        底图（城市蒙版色平涂 + 海洋深蓝，context 局部）
  - l1_mask.png        索引图（tile index 直编，P 社 provinces.bmp 机制）
  - player_start_l1_cities_preview.png  城市划分预览（放大，含城市点标记）

坐标：出生 L1 的 bbox（2048 全局）外扩 margin 后居中到正方形 context，
      城市多边形/城市点换算为 context 局部（与 L2 视图包同语义）。

用法：
  python tools/worldgen/l1/export_player_l1_cities.py [--margin 60] [--scale 6]
"""
import argparse
import json
import os
import shutil
import sys

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "l2_export"))
import mesh_extract  # noqa: E402

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # tools/worldgen
L1_DIR = os.path.join(HERE, "output", "l1")
GAME_DIR = os.path.normpath(os.path.join(
    HERE, "..", "..", "stick-world", "config", "strategic_map"))

OCEAN_COLOR = (30, 55, 95)


def mst(pts):
    """Prim 最小生成树（欧氏），返回边列表 [(i, j), ...]。"""
    n = len(pts)
    if n <= 1:
        return []
    used = [False] * n
    dist = [1e18] * n
    parent = [-1] * n
    dist[0] = 0.0
    edges = []
    for _ in range(n):
        u = min((i for i in range(n) if not used[i]), key=lambda i: dist[i])
        used[u] = True
        if parent[u] >= 0:
            edges.append((parent[u], u))
        for v in range(n):
            if not used[v]:
                d = (pts[u][0] - pts[v][0]) ** 2 + (pts[u][1] - pts[v][1]) ** 2
                if d < dist[v]:
                    dist[v] = d
                    parent[v] = u
    return edges


def main():
    ap = argparse.ArgumentParser(description="玩家初始 L1 城市视图导出（Tab 战略图数据源）")
    ap.add_argument("--margin", type=int, default=60, help="出生 L1 bbox 外扩边距（2048 级像素）")
    ap.add_argument("--scale", type=int, default=6, help="预览图放大倍数")
    args = ap.parse_args()

    print("[1/5] 加载城市/L1 数据，定位出生 L1 ...")
    l1data = json.load(open(os.path.join(L1_DIR, "l1_data.json"), encoding="utf-8"))
    citydata = json.load(open(os.path.join(L1_DIR, "city_data.json"), encoding="utf-8"))
    city_labels = np.load(os.path.join(L1_DIR, "city_labels_2048.npy"))
    l1_labels = np.load(os.path.join(L1_DIR, "l1_labels_2048.npy"))

    start_tiles = [t for t in l1data["tiles"] if t.get("player_start", False)]
    if not start_tiles:
        print("错误：l1_data.json 无 player_start 标记（重跑 l1_world_split.py --player-start-label）")
        return
    start_l1 = start_tiles[0]
    lab_l1 = int(start_l1["label"])
    print("  出生 L1 = label %d（region %d，城市点 %s）" % (
        lab_l1, start_l1["region"], start_l1["city"]))

    cities = [c for c in citydata["cities"] if c["parent_l1"] == lab_l1]
    if not cities:
        print("错误：出生 L1 无城市（重跑 city_split.py）")
        return
    cities.sort(key=lambda c: -c["area_px"])
    print("  出生 L1 内城市 %d 个" % len(cities))

    print("[2/5] bbox + context 换算 ...")
    ys, xs = np.where(np.isin(city_labels, [c["label"] for c in cities]))
    y0, y1, x0, x1 = int(ys.min()), int(ys.max()), int(xs.min()), int(xs.max())
    m = args.margin
    w, h = (x1 - x0 + 1) + 2 * m, (y1 - y0 + 1) + 2 * m
    side = max(w, h)
    ox, oy = (side - w) // 2, (side - h) // 2   # bbox 在正方形中的位置
    # context 坐标 = (全局 2048 - (x0 - ox - m, y0 - oy - m))
    cx0, cy0 = x0 - m - ox, y0 - m - oy

    tiles = []
    for rank, c in enumerate(cities, start=1):
        rings = []
        for r in c.get("polygons", []):
            ring = [[float(p[0]) - cx0, float(p[1]) - cy0] for p in r]
            if len(ring) >= 3:
                rings.append(ring)
        area = int(c["area_px"])
        # 级别分档：城市层均视为城市级聚落，按面积细分图标大小
        level = 3 if area > 1500 else (2 if area > 600 else 1)
        tiles.append({
            "tile_id": "city_%03d" % int(c["label"]),
            "polygon": rings[0] if rings else [],
            "polygons": rings,
            "area_px": area,
            "owner_state_id": "state_%03d" % int(c["label"]),
            "settlement": {
                "settlement_id": "settlement_city_%03d" % int(c["label"]),
                "name": "城市%d" % rank,
                "level": level,
                "position_px": [round(float(c["city"][0]) - cx0, 2),
                                round(float(c["city"][1]) - cy0, 2)],
                "map_id": "",   # 暂无可玩地图：点击不可进入（enter_settlement 空 map_id 保护）
            },
        })

    # 政权：每城市一个独立城邦（8 城邦模型延续）
    states = [{
        "state_id": t["owner_state_id"],
        "name": "城邦%d" % i,
        "capital_settlement_id": t["settlement"]["settlement_id"],
        "color": [int(v) for v in cities[i - 1]["rgb"]],
    } for i, t in enumerate(tiles, start=1)]

    # 道路：城市点 MST
    city_pts = np.array([t["settlement"]["position_px"] for t in tiles], dtype=np.float64)
    sid = [t["settlement"]["settlement_id"] for t in tiles]
    roads = [{"from": sid[a], "to": sid[b]} for a, b in mst(city_pts)]

    # 出生 L1 权威轮廓（l1_labels 蒙版提取，同源）：Tab 视图用粗线标出 L1 边界，
    # 让"贴 L1 边缘的城市套用 L1 边界"肉眼可见
    l1_m = l1_labels == lab_l1
    if l1_m.any() and cy0 >= 0 and cx0 >= 0:
        _mesh = mesh_extract.simplify_mesh(
            mesh_extract.extract_mesh(l1_m.astype(np.int32)))
        _outer = _mesh.get(1, {}).get("outer", [])
        l1_polygon = [[float(p[1]) - cx0, float(p[0]) - cy0] for p in (_outer[0] if _outer else [])]
    else:
        l1_polygon = []

    print("[3/5] 底图 + 索引图 + 预览 ...")
    base = np.full((side, side, 3), OCEAN_COLOR, dtype=np.uint8)
    for c, t in zip(cities, tiles):
        msk = city_labels == c["label"]
        # 城市蒙版（2048 全局）-> context
        sub = msk[cy0:cy0 + side, cx0:cx0 + side] if cy0 >= 0 and cx0 >= 0 else None
        # 裁剪到范围（城市可能贴 bbox 边；margin 保证都在范围内）
        base[sub] = c["rgb"]
    Image.fromarray(base).save(os.path.join(GAME_DIR, "l1_base.png"))

    idx = np.zeros((side, side, 3), dtype=np.uint8)
    for i, t in enumerate(tiles, start=1):
        msk = city_labels == cities[i - 1]["label"]
        idx[msk[cy0:cy0 + side, cx0:cx0 + side]] = (
            (i >> 16) & 0xFF, (i >> 8) & 0xFF, i & 0xFF)
    Image.fromarray(idx).save(os.path.join(GAME_DIR, "l1_mask.png"))

    # 预览图（放大；城市色块 + 城市间细线 + L1 外边界粗线，城市贴 L1 边界一目了然）
    sc = args.scale
    prev = np.array(Image.fromarray(base).resize((side * sc, side * sc), Image.NEAREST))
    dr = ImageDraw.Draw(Image.fromarray(prev))
    thin = max(1, sc // 3)
    # 城市边界（细）+ 城市点
    for c, t in zip(cities, tiles):
        px = [(p[0] * sc, p[1] * sc) for p in t["polygon"]]
        if len(px) >= 3:
            dr.line(px + [px[0]], fill=(40, 40, 40), width=thin)
        cxp, cyp = float(t["settlement"]["position_px"][0]) * sc, float(t["settlement"]["position_px"][1]) * sc
        r = max(4, sc * 3 // 4)
        dr.ellipse([cxp - r, cyp - r, cxp + r, cyp + r], outline=(12, 12, 12), width=thin)
        dr.ellipse([cxp - r * 0.35, cyp - r * 0.35, cxp + r * 0.35, cyp + r * 0.35], fill=(250, 250, 250))
    # L1 外边界（粗，压过城市细线 → 城市对外边界 = L1 边界）
    if l1_polygon:
        lpx = [(p[0] * sc, p[1] * sc) for p in l1_polygon]
        if len(lpx) >= 3:
            dr.line(lpx + [lpx[0]], fill=(8, 8, 8), width=max(3, sc))
    Image.fromarray(prev).save(os.path.join(GAME_DIR, "player_start_l1_cities_preview.png"))
    shutil.copy(os.path.join(GAME_DIR, "player_start_l1_cities_preview.png"),
                os.path.join(L1_DIR, "player_start_l1_cities_preview.png"))

    print("[4/5] 写 l1_world.json ...")
    world = {
        "map_id": "l1_player_start",
        "name": "出生 L1 地图（城市划分）",
        "size": side,
        "seed": int(l1data["seed"]),
        "base_texture": "l1_base.png",
        "mask_texture": "l1_mask.png",
        "parent_l1_label": lab_l1,
        "l1_polygon": l1_polygon,
        "spawn_settlement_id": tiles[0]["settlement"]["settlement_id"],
        "tiles": tiles,
        "states": states,
        "roads": roads,
    }
    with open(os.path.join(GAME_DIR, "l1_world.json"), "w", encoding="utf-8") as f:
        json.dump(world, f, ensure_ascii=False, indent=1)

    print("[5/5] 完成。")
    print("  出生 L1 label %d：%d 个城市 / %d 个政权 / %d 条道路（MST）" % (
        lab_l1, len(tiles), len(states), len(roads)))
    print("  -> %s（l1_world.json / l1_base.png / l1_mask.png / 预览 PNG）" % GAME_DIR)


if __name__ == "__main__":
    main()