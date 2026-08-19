"""出生 L1 视图上下文导出 —— Tab 战略图显示"出生老 L1 地块特写（彩色城市） + 海洋 + 湖泊 + 紧邻灰色地块边"。

结构对齐 L2 地区视图：彩色城市块（当前 L1 内部城市）+ 灰色邻居老 L1 块 + 海洋背景
+ 湖泊（浅蓝）+ 出生 L1 权威轮廓（l1_polygon，强描边）。渲染端（map_renderer.gd）据此矢量绘制，
与 L2MapRenderer 分层一致；本脚本只产出几何数据，不做三角剖分烘焙（地块少，运行时直接 draw）。

出生 L1 = 老 L1 全局 label 69（= region_013 的 3 号地块，经旧分区 player_start=219 质心验证）；
context = 出生 L1 贴近裁剪正方形（默认边距 45，地块近距离特写、居中、四周留一点空隙）。

城市/邻居/湖泊全部经 mesh_extract 从"上下文统一网格"提取（共享角点、无缝铺满）：
  - 城市层 = city_labels_8192（parent_l1=69 的 8 城，8192 级真实精细边界）
  - 邻居/出生轮廓 = legacy_l1_labels_8192（老 L1 全局蒙版，8192 级）
  - 湖泊 = fractal_lake_mask_8192 原样（不重采样）

输入（output/l1_v2/，8192 级）：city_data.json（size 字段定坐标级）
  / city_labels_8192.npy / legacy_l1_labels_8192.npy

产出（覆盖 stick-world/config/strategic_map/ Tab 数据源）：
  l1_world.json（新增 context_size/neighbors/lakes/focus_center；城市/聚落/轮廓坐标整体平移到上下文）
  l1_base.png（海洋+灰色邻居+彩色城市，上下文尺寸；is_initialized 兜底，渲染走矢量）
  l1_mask.png（城市索引图，rank 直编 1..N，0=海洋/邻居）

用法：
  python tools/worldgen/l1/export_l1_view_context.py [--start-l1 69] [--margin 15]
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


def _area_xy(ring):
    """多边形面积（(x,y) 坐标，鞋带公式）。"""
    n = len(ring)
    s = 0.0
    for i in range(n):
        x1, y1 = ring[i]
        x2, y2 = ring[(i + 1) % n]
        s += x1 * y2 - x2 * y1
    return abs(s) / 2.0


def jsonable(o):
    """递归把 numpy 标量转回 Python 原生类型（mesh 提取的角点可能是 np 类型）。"""
    if isinstance(o, dict):
        return {k: jsonable(v) for k, v in o.items()}
    if isinstance(o, (list, tuple)):
        return [jsonable(v) for v in o]
    if isinstance(o, np.integer):
        return int(o)
    if isinstance(o, np.floating):
        return float(o)
    if isinstance(o, np.bool_):
        return bool(o)
    return o


def main():
    ap = argparse.ArgumentParser(description="出生老 L1 视图上下文导出（Tab 数据源）")
    ap.add_argument("--start-l1", type=int, default=69,
                    help="出生老 L1 全局 label（region_013 的 3 号 = 69，旧分区 player_start=219 质心验证）")
    ap.add_argument("--out-dir", default=None,
                    help="输出目录（默认 config/strategic_map 单份；L2 下钻批量用 l1_packs/l1_%03d）")
    ap.add_argument("--margin", type=int, default=45,
                    help="context 边距（出生 L1 贴近裁剪正方形四周留的空隙；地块近距离特写）")
    args = ap.parse_args()
    # L1 Tab 全链路 8192 原生精度；旧 2048 回退已移除（city_data 升 8192 后 2048 分支坐标 scale=0 损坏）
    res = 8192
    lab_l1 = args.start_l1
    # 输出目录：默认 Tab 单份（config/strategic_map）；--out-dir 批量 L2 下钻数据（每老 L1 一份）
    out_dir = os.path.abspath(args.out_dir) if args.out_dir else GAME_DIR
    os.makedirs(out_dir, exist_ok=True)

    print("[1/5] 加载 v2 数据（res=%d）..." % res)
    citydata = json.load(open(os.path.join(V2_DIR, "city_data.json"), encoding="utf-8"))
    cities = [c for c in citydata["cities"] if int(c["parent_l1"]) == lab_l1]
    cities.sort(key=lambda c: -c["area_px"])
    print("  出生老 L1 = 全局 label %d，内城市 %d 个" % (lab_l1, len(cities)))
    if not cities:
        print("错误：该老 L1 无城市（重跑 city_split_v2）")
        return
    # 城市层 8192 生成 + 老 L1 拼 8192 原图 + 湖泊 8192 原样（全链无重采样）
    legacy = np.load(os.path.join(V2_DIR, "legacy_l1_labels_8192.npy")).astype(np.int32)
    city_labels = np.load(os.path.join(V2_DIR, "city_labels_8192.npy")).astype(np.int32)
    lake = np.array(Image.open(os.path.join(HERE, "output", "fractal_lake_mask_8192.png"))) > 0

    # context：出生 L1 贴近裁剪正方形（地块特写），四周留 --margin 边距（按 res 缩放）
    l1_mask = legacy == lab_l1
    ys0, xs0 = np.where(l1_mask)
    bx0, by0 = xs0.min(), ys0.min()
    bx1, by1 = xs0.max(), ys0.max()
    # 以地块 bbox 中心居中（质心对不规则形状会偏，导致四周边距不均）
    cx = int(round((bx0 + bx1) / 2.0))
    cy = int(round((by0 + by1) / 2.0))
    margin = args.margin * res // 2048
    # 正方形边长 = 地块长边 + 2×边距；以地块 bbox 中心为中心，钳在 res 内
    side = max(bx1 - bx0 + 1, by1 - by0 + 1) + 2 * margin
    x0 = cx - side // 2
    y0 = cy - side // 2
    x0 = max(0, min(x0, res - side))
    y0 = max(0, min(y0, res - side))
    print("  context: %d x %d @ (%d,%d)，出生 L1 bbox %d x %d（边距 %d，地块特写居中）"
          % (side, side, x0, y0, bx1 - bx0 + 1, by1 - by0 + 1, margin))

    print("[2/5] 统一网格提取（城市/邻居/出生轮廓/湖泊，共享角点无缝）...")
    ctx_legacy = legacy[y0:y0 + side, x0:x0 + side].copy()
    ctx_lake = lake[y0:y0 + side, x0:x0 + side].copy()
    # 8192：直接裁剪 8192 级城市标签（城市层已在 8192 生成，真实精细边界）
    ctx_city = city_labels[y0:y0 + side, x0:x0 + side].copy()
    # 8192 原生几何已足够细（屏幕 zoom≈0.77 时像素楼梯不可见）：轻平滑去尖角即可
    smooth_city, smooth_legacy, smooth_lake = 1, 1, 1

    city_mesh = mesh_extract.simplify_mesh(mesh_extract.extract_mesh(ctx_city), smooth_passes=smooth_city)
    legacy_mesh = mesh_extract.simplify_mesh(mesh_extract.extract_mesh(ctx_legacy), smooth_passes=smooth_legacy)
    lake_mesh = mesh_extract.simplify_mesh(mesh_extract.extract_mesh(ctx_lake.astype(np.int32)), smooth_passes=smooth_lake)

    # 出生 L1 权威轮廓 + 邻居块（灰色）：context 内除出生块外的所有老 L1 块
    # 多连通（大陆 + 岛屿）时 extract 输出多个外环——只取最大环（主大陆）画 L1 轮廓粗线，
    # 岛屿不画 L1 轮廓（防多环串接成跨海乱飞线；岛屿由城市色块/描边呈现）
    l1_polygon = []
    outs = legacy_mesh.get(lab_l1, {}).get("outer", [])
    if outs:
        l1_polygon = to_xy(max(outs, key=len))
    neighbors_data = []
    nbr_labels = []
    for k, mv in legacy_mesh.items():
        if k <= 0 or k == lab_l1:
            continue
        outs = [to_xy(p) for p in mv.get("outer", [])]
        if not outs:
            continue
        nbr_labels.append(int(k))
        neighbors_data.append({"label": int(k), "polygons": outs,
                               "holes": [to_xy(p) for p in mv.get("holes", [])]})
    nbr_labels.sort()
    print("  邻居老 L1 块 (%d):" % len(nbr_labels), nbr_labels)
    # 湖泊：context 内全部湖像素（覆盖邻居/非地块区；地块内湖极少，直接作湖泊色覆盖城市块）
    lakes = []
    for k, mv in lake_mesh.items():
        if k <= 0:
            continue
        for p in mv.get("outer", []):
            lakes.append(to_xy(p))

    print("[3/5] 城市块 + 政权 + 道路 ...")
    rgb_by_label = {int(c["label"]): c["rgb"] for c in cities}
    # 城市点（city_data 坐标按其 size 字段定级）缩放对齐 res 后减去 context 偏移
    cd_size = int(citydata.get("size", 2048))
    cd_scale = res // cd_size
    city_pos = {int(c["label"]): [v * cd_scale for v in c["city"]] for c in cities}
    # 面积归一化到 2048 级判定 level（8192 级 area_px ÷16 后语义不变）
    city_area = {int(c["label"]): int(c["area_px"] * (2048 * 2048) // (cd_size * cd_size)) for c in cities}
    tiles = []
    for rank, c in enumerate(cities, start=1):
        mv = city_mesh.get(int(c["label"]), {})
        outs = [to_xy(p) for p in mv.get("outer", [])]
        if not outs:
            outs = [[[float(p[0]) - x0, float(p[1]) - y0] for p in r] for r in c.get("polygons", [])]
            outs = [r for r in outs if len(r) >= 3]
        # split_self_touch 自触分割会产生多个 outer：主体 + 1px 碎条。
        # 取面积最大者作主轮廓（渲染器用 polygon 填充），剔除 <3px² 碎条，
        # 否则 outs[0] 可能取到碎三角（如 city_1034 只剩 0.6px² → 渲染成海洋色）。
        if len(outs) > 1:
            outs = [r for r in outs if _area_xy(r) >= 3.0] or outs
            outs = sorted(outs, key=_area_xy, reverse=True)
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
                "position_px": [round(float(pos[0]) - x0, 2), round(float(pos[1]) - y0, 2)],
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
    # 出生 L1 质心在 context 局部坐标（居中聚焦点）
    focus = [float(cx - x0), float(cy - y0)]

    print("[4/5] 写索引图 + 底图 ...")
    idx = np.zeros((side, side, 3), dtype=np.uint8)
    for i, c in enumerate(cities, start=1):
        msk = ctx_city == c["label"]
        idx[msk] = ((i >> 16) & 0xFF, (i >> 8) & 0xFF, i & 0xFF)
    Image.fromarray(idx).save(os.path.join(out_dir, "l1_mask.png"))

    base = np.full((side, side, 3), OCEAN_COLOR, dtype=np.uint8)
    for c in cities:
        base[ctx_city == c["label"]] = c["rgb"]
    for nlb in nbr_labels:
        base[ctx_legacy == nlb] = NEIGHBOR_COLOR
    base[ctx_lake] = LAKE_COLOR
    Image.fromarray(base).save(os.path.join(out_dir, "l1_base.png"))

    print("[5/5] 写 l1_world.json（context 含邻居/湖泊）...")
    world = {
        "map_id": "l1_player_start",
        "name": "出生 L1 地图（城市划分）",
        "size": side,
        "context_size": [side, side],
        "focus_center": focus,
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
    with open(os.path.join(out_dir, "l1_world.json"), "w", encoding="utf-8") as f:
        json.dump(jsonable(world), f, ensure_ascii=False, indent=1)

    print("完成：%d 城市 / %d 政权 / %d 道路，context %d, 邻居 %d, 湖泊 %d, focus %s" % (
        len(tiles), len(states), len(roads), side, len(neighbors_data), len(lakes), focus))
    print("  -> %s" % out_dir)


if __name__ == "__main__":
    main()
