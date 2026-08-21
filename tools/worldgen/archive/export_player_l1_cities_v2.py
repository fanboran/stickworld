"""玩家初始 L1 城市视图导出 v2 —— Tab 战略图显示"出生老 L1 的城市划分"。

输入（output/l1_v2/，基于老 L1 划分、废弃 389 版）：
  - city_data.json + city_labels_2048.npy   城市层（parent_l1 = 老 L1 全局 label）
  - legacy_l1_labels_2048.npy               老 L1 全局蒙版（出生 L1 权威轮廓/bbox）

出生 L1 = region_012 的 3 号老 L1（全局 label 66，用户确认"12号L2的3号地块"）。

产出（覆盖 stick-world/config/strategic_map/ Tab 数据源）：
  l1_world.json / l1_base.png / l1_mask.png / player_start_l1_cities_preview.png

用法：
  python tools/worldgen/l1/export_player_l1_cities_v2.py [--start-l1 66] [--margin 60] [--scale 6]
"""
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "l2_export"))
import mesh_extract  # noqa: E402

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # tools/worldgen
V2_DIR = os.path.join(HERE, "output", "l1_v2")
GAME_DIR = os.path.normpath(os.path.join(
    HERE, "..", "..", "stick-world", "config", "strategic_map"))

OCEAN_COLOR = (30, 55, 95)


def mst(pts):
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
    ap = argparse.ArgumentParser(description="玩家初始老 L1 城市视图导出 v2（Tab 数据源）")
    ap.add_argument("--start-l1", type=int, default=66, help="出生老 L1 全局 label（region_012 的 3 号 = 66）")
    ap.add_argument("--margin", type=int, default=60, help="bbox 外扩边距（2048 级像素）")
    ap.add_argument("--scale", type=int, default=6, help="预览放大倍数")
    args = ap.parse_args()
    lab_l1 = args.start_l1

    print("[1/5] 加载 v2 数据 ...")
    citydata = json.load(open(os.path.join(V2_DIR, "city_data.json"), encoding="utf-8"))
    city_labels = np.load(os.path.join(V2_DIR, "city_labels_2048.npy"))
    l1_labels = np.load(os.path.join(V2_DIR, "legacy_l1_labels_2048.npy"))
    cities = [c for c in citydata["cities"] if c["parent_l1"] == lab_l1]
    cities.sort(key=lambda c: -c["area_px"])
    print("  出生老 L1 = 全局 label %d，内城市 %d 个" % (lab_l1, len(cities)))
    if not cities:
        print("错误：该老 L1 无城市（重跑 city_split_v2）")
        return

    print("[2/5] bbox + context 换算 ...")
    ys, xs = np.where(np.isin(city_labels, [c["label"] for c in cities]))
    y0, y1, x0, x1 = int(ys.min()), int(ys.max()), int(xs.min()), int(xs.max())
    m = args.margin
    w, h = (x1 - x0 + 1) + 2 * m, (y1 - y0 + 1) + 2 * m
    side = max(w, h)
    ox, oy = (side - w) // 2, (side - h) // 2
    cx0, cy0 = x0 - m - ox, y0 - m - oy

    tiles = []
    for rank, c in enumerate(cities, start=1):
        rings = []
        for r in c.get("polygons", []):
            ring = [[float(p[0]) - cx0, float(p[1]) - cy0] for p in r]
            if len(ring) >= 3:
                rings.append(ring)
        area = int(c["area_px"])
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
                "map_id": "",
            },
        })
    states = [{
        "state_id": t["owner_state_id"],
        "name": "城邦%d" % i,
        "capital_settlement_id": t["settlement"]["settlement_id"],
        "color": [int(v) for v in cities[i - 1]["rgb"]],
    } for i, t in enumerate(tiles, start=1)]
    city_pts = np.array([t["settlement"]["position_px"] for t in tiles], dtype=np.float64)
    sid = [t["settlement"]["settlement_id"] for t in tiles]
    roads = [{"from": sid[a], "to": sid[b]} for a, b in mst(city_pts)]

    # 出生老 L1 权威轮廓（legacy_l1 蒙版提取，城市对外边界套用它）
    l1_m = l1_labels == lab_l1
    _mesh = mesh_extract.simplify_mesh(mesh_extract.extract_mesh(l1_m.astype(np.int32)))
    _outer = _mesh.get(1, {}).get("outer", [])
    l1_polygon = [[float(p[1]) - cx0, float(p[0]) - cy0] for p in (_outer[0] if _outer else [])]

    print("[3/5] 底图 + 索引图 + 预览 ...")
    base = np.full((side, side, 3), OCEAN_COLOR, dtype=np.uint8)
    for c, t in zip(cities, tiles):
        msk = city_labels == c["label"]
        base[msk[cy0:cy0 + side, cx0:cx0 + side]] = c["rgb"]
    Image.fromarray(base).save(os.path.join(GAME_DIR, "l1_base.png"))

    idx = np.zeros((side, side, 3), dtype=np.uint8)
    for i, t in enumerate(tiles, start=1):
        msk = city_labels == cities[i - 1]["label"]
        idx[msk[cy0:cy0 + side, cx0:cx0 + side]] = ((i >> 16) & 0xFF, (i >> 8) & 0xFF, i & 0xFF)
    Image.fromarray(idx).save(os.path.join(GAME_DIR, "l1_mask.png"))

    sc = args.scale
    prev = np.array(Image.fromarray(base).resize((side * sc, side * sc), Image.NEAREST))
    dr = ImageDraw.Draw(Image.fromarray(prev))
    thin = max(1, sc // 3)
    for c, t in zip(cities, tiles):
        px = [(p[0] * sc, p[1] * sc) for p in t["polygon"]]
        if len(px) >= 3:
            dr.line(px + [px[0]], fill=(40, 40, 40), width=thin)
        cxp, cyp = float(t["settlement"]["position_px"][0]) * sc, float(t["settlement"]["position_px"][1]) * sc
        r = max(4, sc * 3 // 4)
        dr.ellipse([cxp - r, cyp - r, cxp + r, cyp + r], outline=(12, 12, 12), width=thin)
        dr.ellipse([cxp - r * 0.35, cyp - r * 0.35, cxp + r * 0.35, cyp + r * 0.35], fill=(250, 250, 250))
    if l1_polygon:
        lpx = [(p[0] * sc, p[1] * sc) for p in l1_polygon]
        if len(lpx) >= 3:
            dr.line(lpx + [lpx[0]], fill=(8, 8, 8), width=max(3, sc))
    Image.fromarray(prev).save(os.path.join(GAME_DIR, "player_start_l1_cities_preview.png"))
    Image.fromarray(prev).save(os.path.join(V2_DIR, "player_start_l1_cities_preview.png"))

    print("[4/5] 写 l1_world.json ...")
    world = {
        "map_id": "l1_player_start",
        "name": "出生 L1 地图（城市划分）",
        "size": side,
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

    print("[5/5] 完成：%d 城市 / %d 政权 / %d 道路（MST），size %d" % (
        len(tiles), len(states), len(roads), side))
    print("  -> %s" % GAME_DIR)


if __name__ == "__main__":
    main()