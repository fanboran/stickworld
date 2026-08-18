"""出生 L1 视图上下文导出 —— Tab 战略图显示"出生老 L1 的城市划分 + 周围灰色邻居 L1 块 + 海洋 + 湖泊"。

结构对齐 L2 地区视图：彩色城市块（当前 L1 内部 13 城邦）+ 灰色邻居 L1 块（label 65）+ 海洋背景
+ 湖泊（浅蓝）+ 出生 L1 权威轮廓（l1_polygon，强描边）。渲染端（map_renderer.gd）据此矢量绘制，
与 L2MapRenderer 分层一致；本脚本只产出几何数据，不做三角剖分烘焙（地块少，运行时直接 draw）。

城市/邻居/湖泊全部经 mesh_extract 从"上下文统一网格"提取（共享角点、无缝铺满）：
  - 城市层 = city_labels_2048（parent_l1=66，实测与 legacy label 66 像素级完全一致）
  - 邻居/出生轮廓 = legacy_l1_labels_2048（老 L1 全局蒙版）
  - 湖泊 = fractal_lake_mask_8192 缩到 2048

输入（output/l1_v2/，2048 级）：city_data.json / city_labels_2048.npy / legacy_l1_labels_2048.npy
出生 L1 = 全局 label 66（用户确认"12号L2的3号地块"）；邻居 = 与 66 相邻的老 L1 块（实测仅 65）。

产出（覆盖 stick-world/config/strategic_map/ Tab 数据源）：
  l1_world.json（新增 context_size/neighbors/lakes；城市/聚落/轮廓坐标整体平移到上下文）
  l1_base.png（海洋+灰色邻居+彩色城市，上下文尺寸；is_initialized 兜底，渲染走矢量）
  l1_mask.png（城市索引图，rank 直编 1..13，0=海洋/邻居）

用法：
  python tools/worldgen/l1/export_l1_view_context.py [--start-l1 66] [--margin 45]
"""
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "l2_export"))
import mesh_extract  # noqa: E402

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # tools/worldgen
V2_DIR = os.path.join(HERE, "output", "l1_v2")
GAME_DIR = os.path.normpath(os.path.join(
    HERE, "..", "..", "stick-world", "config", "strategic_map"))

OCEAN_COLOR = (30, 55, 95)
NEIGHBOR_COLOR = (115, 115, 115)   # Color(0.45,0.45,0.45)
LAKE_COLOR = (28, 50, 82)


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


def to_xy(ring):
    """mesh_extract 返回 (y,x) 角点 -> 数据格式 (x,y) 浮点。"""
    return [[float(p[1]), float(p[0])] for p in ring]


def main():
    ap = argparse.ArgumentParser(description="出生老 L1 视图上下文导出（Tab 数据源）")
    ap.add_argument("--start-l1", type=int, default=66, help="出生老 L1 全局 label（region_012 的 3 号 = 66）")
    ap.add_argument("--margin", type=int, default=45, help="上下文外扩边距（2048 级像素）")
    args = ap.parse_args()
    lab_l1 = args.start_l1

    print("[1/5] 加载 v2 数据 ...")
    citydata = json.load(open(os.path.join(V2_DIR, "city_data.json"), encoding="utf-8"))
    city_labels = np.load(os.path.join(V2_DIR, "city_labels_2048.npy")).astype(np.int32)
    legacy = np.load(os.path.join(V2_DIR, "legacy_l1_labels_2048.npy")).astype(np.int32)
    lake8192 = np.array(Image.open(os.path.join(HERE, "output", "fractal_lake_mask_8192.png"))) > 0
    lake = np.array(Image.fromarray(lake8192.astype(np.uint8)).resize(
        (2048, 2048), Image.NEAREST)).astype(bool)

    cities = [c for c in citydata["cities"] if int(c["parent_l1"]) == lab_l1]
    cities.sort(key=lambda c: -c["area_px"])
    print("  出生老 L1 = 全局 label %d，内城市 %d 个" % (lab_l1, len(cities)))
    if not cities:
        print("错误：该老 L1 无城市（重跑 city_split_v2）")
        return

    # 邻居：与出生 L1 相邻的老 L1 块（4 邻域扩张）
    l1_mask = legacy == lab_l1
    from scipy import ndimage
    dil = ndimage.binary_dilation(l1_mask)
    nbr_labels = np.unique(legacy[dil & (legacy != lab_l1) & (legacy != 0)]).tolist()
    print("  邻居老 L1 块:", nbr_labels)

    # bbox = 出生 L1 ∪ 邻居 + 边距，正方形 context
    ys, xs = np.where(l1_mask)
    y0, y1, x0, x1 = int(ys.min()), int(ys.max()), int(xs.min()), int(xs.max())
    for nlb in nbr_labels:
        nys, nxs = np.where(legacy == nlb)
        y0, y1 = min(y0, int(nys.min())), max(y1, int(nys.max()))
        x0, x1 = min(x0, int(nxs.min())), max(x1, int(nxs.max()))
    m = args.margin
    w, h = (x1 - x0 + 1) + 2 * m, (y1 - y0 + 1) + 2 * m
    side = max(w, h)
    ox, oy = (side - w) // 2, (side - h) // 2
    cx0, cy0 = x0 - m - ox, y0 - m - oy
    # 钳到 2048 边界内（海图边界外虚空）
    if cy0 < 0 or cx0 < 0 or cy0 + side > 2048 or cx0 + side > 2048:
        pad = max(-cy0, -cx0, cy0 + side - 2048, cx0 + side - 2048)
        cy0 += pad
        cx0 += pad

    print("[2/5] 统一网格提取（城市/邻居/出生轮廓/湖泊，共享角点无缝）...")
    ctx_city = city_labels[cy0:cy0 + side, cx0:cx0 + side].copy()
    ctx_legacy = legacy[cy0:cy0 + side, cx0:cx0 + side].copy()
    ctx_lake = lake[cy0:cy0 + side, cx0:cx0 + side].copy()

    city_mesh = mesh_extract.simplify_mesh(mesh_extract.extract_mesh(ctx_city), smooth_passes=3)
    legacy_mesh = mesh_extract.simplify_mesh(mesh_extract.extract_mesh(ctx_legacy), smooth_passes=3)
    lake_mesh = mesh_extract.simplify_mesh(mesh_extract.extract_mesh(ctx_lake.astype(np.int32)), smooth_passes=2)

    # 出生 L1 权威轮廓 + 邻居块（灰色）
    l1_polygon = []
    for p in legacy_mesh.get(lab_l1, {}).get("outer", []):
        l1_polygon.extend(to_xy(p))
    neighbors_data = []
    for nlb in nbr_labels:
        mv = legacy_mesh.get(nlb, {})
        outs = [to_xy(p) for p in mv.get("outer", [])]
        if outs:
            neighbors_data.append({"label": nlb, "polygons": outs,
                                   "holes": [to_xy(p) for p in mv.get("holes", [])]})
    # 湖泊：context 内全部湖像素（覆盖邻居/非地块区；地块内湖极少，直接作湖泊色覆盖城市块）
    lakes = []
    for k, mv in lake_mesh.items():
        if k <= 0:
            continue
        for p in mv.get("outer", []):
            lakes.append(to_xy(p))

    print("[3/5] 城市块 + 政权 + 道路 ...")
    rgb_by_label = {int(c["label"]): c["rgb"] for c in cities}
    city_pos = {int(c["label"]): c["city"] for c in cities}
    city_area = {int(c["label"]): int(c["area_px"]) for c in cities}
    city_cent = {int(c["label"]): c["centroid"] for c in cities}
    tiles = []
    for rank, c in enumerate(cities, start=1):
        mv = city_mesh.get(int(c["label"]), {})
        outs = [to_xy(p) for p in mv.get("outer", [])]
        if not outs:
            outs = [[[float(p[0]) - cx0, float(p[1]) - cy0] for p in r] for r in c.get("polygons", [])]
            outs = [r for r in outs if len(r) >= 3]
        level = 3 if city_area[c["label"]] > 1500 else (2 if city_area[c["label"]] > 600 else 1)
        pos = city_pos[c["label"]]
        tiles.append({
            "tile_id": "city_%03d" % c["label"],
            "polygon": outs[0] if outs else [],
            "polygons": outs,
            "area_px": city_area[c["label"]],
            "owner_state_id": "state_%03d" % c["label"],
            "settlement": {
                "settlement_id": "settlement_city_%03d" % c["label"],
                "name": "城市%d" % rank,
                "level": level,
                "position_px": [round(float(pos[0]) - cx0, 2), round(float(pos[1]) - cy0, 2)],
                "map_id": "",
            },
        })
    states = [{
        "state_id": t["owner_state_id"],
        "name": "城邦%d" % i,
        "capital_settlement_id": t["settlement"]["settlement_id"],
        "color": [int(v) for v in rgb_by_label[int(t["tile_id"][5:])]],
    } for i, t in enumerate(tiles, start=1)]
    city_pts = np.array([t["settlement"]["position_px"] for t in tiles], dtype=np.float64)
    sid = [t["settlement"]["settlement_id"] for t in tiles]
    roads = [{"from": sid[a], "to": sid[b]} for a, b in mst(city_pts)]

    print("[4/5] 写索引图 + 底图 ...")
    idx = np.zeros((side, side, 3), dtype=np.uint8)
    for i, c in enumerate(cities, start=1):
        msk = ctx_city == c["label"]
        idx[msk] = ((i >> 16) & 0xFF, (i >> 8) & 0xFF, i & 0xFF)
    Image.fromarray(idx).save(os.path.join(GAME_DIR, "l1_mask.png"))

    base = np.full((side, side, 3), OCEAN_COLOR, dtype=np.uint8)
    for nlb in nbr_labels:
        base[ctx_legacy == nlb] = NEIGHBOR_COLOR
    for c in cities:
        base[ctx_city == c["label"]] = c["rgb"]
    base[ctx_lake] = LAKE_COLOR
    Image.fromarray(base).save(os.path.join(GAME_DIR, "l1_base.png"))

    print("[5/5] 写 l1_world.json（context 含邻居/湖泊）...")
    world = {
        "map_id": "l1_player_start",
        "name": "出生 L1 地图（城市划分）",
        "size": side,
        "context_size": [side, side],
        "base_texture": "l1_base.png",
        "mask_texture": "l1_mask.png",
        "parent_l1_label": lab_l1,
        "l1_polygon": l1_polygon,
        "spawn_settlement_id": tiles[0]["settlement"]["settlement_id"],
        "tiles": tiles,
        "states": states,
        "roads": roads,
        "neighbors": neighbors_data,
        "lakes": lakes,
    }
    with open(os.path.join(GAME_DIR, "l1_world.json"), "w", encoding="utf-8") as f:
        json.dump(world, f, ensure_ascii=False, indent=1)

    print("完成：%d 城市 / %d 政权 / %d 道路，context %d, 邻居 %d, 湖泊 %d" % (
        len(tiles), len(states), len(roads), side, len(neighbors_data), len(lakes)))
    print("  -> %s" % GAME_DIR)


if __name__ == "__main__":
    main()
