"""出生 L1 视图上下文导出 —— Tab 战略图显示"出生老 L1 地块特写（彩色城市） + 海洋 + 湖泊 + 紧邻灰色地块边"。

结构对齐 L2 地区视图：彩色城市块（当前 L1 内部城市）+ 灰色邻居老 L1 块 + 海洋背景
+ 湖泊（浅蓝）+ 出生 L1 权威轮廓（l1_polygon，强描边）。渲染端（map_renderer.gd）据此矢量绘制，
与 L2MapRenderer 分层一致；本脚本只产出几何数据，不做三角剖分烘焙（地块少，运行时直接 draw）。

出生 L1 = 老 L1 全局 label 69（= region_013 的 3 号地块，经旧分区 player_start=219 质心验证）；
context = 出生 L1 贴近裁剪正方形（默认边距 45，地块近距离特写、居中、四周留一点空隙）。

城市/邻居/湖泊全部经 mesh_extract 从"上下文统一网格"提取（共享角点、无缝铺满）：
  - 城市层 = city_labels_2048（parent_l1=69，实测与 legacy label 69 像素级完全一致）
  - 邻居/出生轮廓 = legacy_l1_labels_2048（老 L1 全局蒙版）
  - 湖泊 = fractal_lake_mask_8192 缩到 2048

输入（output/l1_v2/，2048 级）：city_data.json / city_labels_2048.npy / legacy_l1_labels_2048.npy

产出（覆盖 stick-world/config/strategic_map/ Tab 数据源）：
  l1_world.json（新增 context_size/neighbors/lakes/focus_center；城市/聚落/轮廓坐标整体平移到上下文）
  l1_base.png（海洋+灰色邻居+彩色城市，上下文尺寸；is_initialized 兜底，渲染走矢量）
  l1_mask.png（城市索引图，rank 直编 1..N，0=海洋/邻居）

用法：
  python tools/worldgen/l1/export_l1_view_context.py [--start-l1 69] [--margin 45]
"""
import argparse
import json
import math
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


def _area_xy(poly):
    """鞋带公式面积（(x,y) 环）。"""
    s = 0.0
    n = len(poly)
    for i in range(n):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % n]
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


def _edge_key(a, b):
    """无向边 key（端点取整排序，保证两条环各自追踪的共享边匹配）。"""
    pa = (round(a[0], 1), round(a[1], 1))
    pb = (round(b[0], 1), round(b[1], 1))
    return tuple(sorted((pa, pb)))


def _round_corner(p0, pc, p1, radius):
    """固定半径圆弧替换尖角，返回弧上采样点（闭合多边形顶点序列的一部分）。

    弧半径受两侧边长限制（r <= min(l1,l2)/2），保证不越过相邻顶点。
    """
    v1 = (p0[0] - pc[0], p0[1] - pc[1])
    v2 = (p1[0] - pc[0], p1[1] - pc[1])
    l1 = math.hypot(*v1)
    l2 = math.hypot(*v2)
    r = min(radius, l1 * 0.5, l2 * 0.5)
    if r < 0.05 or l1 < 1e-9 or l2 < 1e-9:
        return [pc]
    u1 = (v1[0] / l1, v1[1] / l1)
    u2 = (v2[0] / l2, v2[1] / l2)
    bx = u1[0] + u2[0]
    by = u1[1] + u2[1]
    nb = math.hypot(bx, by)
    if nb < 1e-9:
        return [pc]
    bx /= nb
    by /= nb
    cos = max(-1.0, min(1.0, u1[0] * u2[0] + u1[1] * u2[1]))
    theta = math.acos(cos)
    if theta < math.radians(10):
        return [pc]
    d = r / math.sin(theta / 2.0)
    cx = pc[0] + bx * d
    cy = pc[1] + by * d
    t1 = (pc[0] + u1[0] * r, pc[1] + u1[1] * r)
    t2 = (pc[0] + u2[0] * r, pc[1] + u2[1] * r)
    a1 = math.atan2(t1[1] - cy, t1[0] - cx)
    a2 = math.atan2(t2[1] - cy, t2[0] - cx)
    da = a2 - a1
    while da > math.pi:
        da -= 2 * math.pi
    while da < -math.pi:
        da += 2 * math.pi
    steps = max(1, int(abs(da) / math.radians(60)))
    return [(cx + r * math.cos(a1 + da * s / steps), cy + r * math.sin(a1 + da * s / steps))
            for s in range(steps + 1)]


def clean_mesh_shared(mesh, dp_tol=1.0, corner_radius=2.0):
    """共享边安全简化 + 圆角（关键：相邻地块共享边界数据一致，不再分离）。

    整环 DP 会因各环起点不同把共享边简化成不同折线 -> 相邻地块各自描边变两条线。
    本函数把共享边界当作唯一几何：共享段只简化一次写回所有含它的环，外段各自简化。

    1. 边 -> 含它的环集合（同一段共享边界在两条环里是同一整数楼梯）
    2. 每条环按"共享环集合"分段：连续边被同一批环共享 -> 同一段
    3. 共享段 DP 一次进缓存，按方向写回；外段各自 DP
    4. 圆角：只圆"本环独有"（非共享段）的角 —— 共享段任何点绝不移动，
       保证共享边界在两边始终是同一组点 -> 描边重合为一条线
    """
    from collections import defaultdict
    edge_rings = defaultdict(set)
    ring_ids = []
    for label, v in mesh.items():
        for oi, ring in enumerate(v.get("outer", [])):
            rid = len(ring_ids)
            ring_ids.append((label, oi))
            for i in range(len(ring)):
                edge_rings[_edge_key(ring[i], ring[(i + 1) % len(ring)])].add(rid)
    shared_cache = {}
    new_rings = {}
    for rid, (label, oi) in enumerate(ring_ids):
        ring = mesh[label]["outer"][oi]
        n = len(ring)
        if n < 3:
            continue
        sets = [frozenset(edge_rings[_edge_key(ring[i], ring[(i + 1) % n])]) for i in range(n)]
        boundaries = [i for i in range(n) if sets[i] != sets[(i + 1) % n]]
        if not boundaries:
            runs = [(list(ring), sets[0])]
        else:
            s0 = boundaries[0]
            r2 = [ring[(s0 + k) % n] for k in range(n)]
            s2 = [sets[(s0 + k) % n] for k in range(n)]
            runs = []
            i = 0
            while i < n:
                j = i
                while j + 1 < n and s2[j + 1] == s2[i]:
                    j += 1
                runs.append(([r2[k % n] for k in range(i, j + 2)], s2[i]))
                i = j + 1
        out_pts = []
        out_shared = []
        for pts, sset in runs:
            sh = len(sset) > 1
            uniq = len(set((round(x, 1), round(y, 1)) for x, y in pts))
            if len(pts) >= 3 and uniq >= 3:
                if sh:
                    if sset not in shared_cache:
                        shared_cache[sset] = mesh_extract._dp_simplify(pts, dp_tol)
                    sp = shared_cache[sset]
                    if abs(sp[0][0] - pts[0][0]) > 1e-6 or abs(sp[0][1] - pts[0][1]) > 1e-6:
                        sp = list(reversed(sp))
                else:
                    sp = mesh_extract._dp_simplify(pts, dp_tol)
                for p in sp[:-1]:
                    out_pts.append(p)
                    out_shared.append(sh)
            else:
                for p in pts[:-1]:
                    out_pts.append(p)
                    out_shared.append(sh)
        if out_pts:
            new_rings[(label, oi)] = (out_pts, out_shared)
    # 圆角：只动非共享角点
    def _turn_angle(ring, k):
        a = ring[(k - 1) % len(ring)]
        b = ring[k]
        c = ring[(k + 1) % len(ring)]
        v1 = (b[0] - a[0], b[1] - a[1])
        v2 = (c[0] - b[0], c[1] - b[1])
        l1 = math.hypot(*v1)
        l2 = math.hypot(*v2)
        if l1 < 1e-6 or l2 < 1e-6:
            return 0.0
        cos = max(-1.0, min(1.0, (v1[0] * v2[0] + v1[1] * v2[1]) / (l1 * l2)))
        return 180.0 - math.degrees(math.acos(cos))
    rounded = {}
    for (label, oi), (ring, fl) in new_rings.items():
        if len(ring) < 3:
            rounded[(label, oi)] = ring
            continue
        newr = []
        n = len(ring)
        for k in range(n):
            # 共享段任何点绝不移动：顶点只要相邻任一边来自共享段（自身或前一边）就不圆角。
            # 交界顶点是共享段的端点，若被圆角会破坏两边共享边界的一致性。
            on_shared = fl[k] or fl[(k - 1) % n]
            if (not on_shared) and _turn_angle(ring, k) > 30.0:
                arc = _round_corner(ring[(k - 1) % n], ring[k], ring[(k + 1) % n], corner_radius)
                newr.extend(arc[:-1])
            else:
                newr.append(ring[k])
        rounded[(label, oi)] = newr
    result = {}
    for label, v in mesh.items():
        result[label] = {"outer": [], "holes": v.get("holes", [])}
        for oi in range(len(v.get("outer", []))):
            result[label]["outer"].append(rounded.get((label, oi), v["outer"][oi]))
    return result



def main():
    ap = argparse.ArgumentParser(description="出生老 L1 视图上下文导出（Tab 数据源）")
    ap.add_argument("--start-l1", type=int, default=69,
                    help="出生老 L1 全局 label（region_013 的 3 号 = 69，旧分区 player_start=219 质心验证）")
    ap.add_argument("--margin", type=int, default=15,
                    help="context 边距（出生 L1 贴近裁剪正方形四周留的空隙；地块近距离特写）")
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

    # context：出生 L1 贴近裁剪正方形（地块特写），四周留 --margin 边距
    l1_mask = legacy == lab_l1
    ys0, xs0 = np.where(l1_mask)
    bx0, by0 = xs0.min(), ys0.min()
    bx1, by1 = xs0.max(), ys0.max()
    # 以地块 bbox 中心居中（质心对不规则形状会偏，导致四周边距不均）
    cx = int(round((bx0 + bx1) / 2.0))
    cy = int(round((by0 + by1) / 2.0))
    margin = args.margin
    # 正方形边长 = 地块长边 + 2×边距；以地块 bbox 中心为中心，钳在 2048 内
    side = max(bx1 - bx0 + 1, by1 - by0 + 1) + 2 * margin
    x0 = cx - side // 2
    y0 = cy - side // 2
    x0 = max(0, min(x0, 2048 - side))
    y0 = max(0, min(y0, 2048 - side))
    print("  context: %d x %d @ (%d,%d)，出生 L1 bbox %d x %d（边距 %d，地块特写居中）"
          % (side, side, x0, y0, bx1 - bx0 + 1, by1 - by0 + 1, margin))

    print("[2/5] 统一网格提取（城市/邻居/出生轮廓/湖泊，共享角点无缝）...")
    ctx_city = city_labels[y0:y0 + side, x0:x0 + side].copy()
    ctx_legacy = legacy[y0:y0 + side, x0:x0 + side].copy()
    ctx_lake = lake[y0:y0 + side, x0:x0 + side].copy()

    # 关键：共享边安全简化 + 圆角（clean_mesh_shared）。
    # 像素蒙版轮廓的 45° 斜边是一格一格 1px 台阶，特写下 ~4.6px/格成锯齿；
    # 整环 DP 会把相邻地块共享边简化成不同折线 -> 各画一条变"分离"。
    # 方案：共享段只简化一次写回两边（共享边界数据一致 -> 描边重合为一条线），
    # 外段各自简化；随后只圆本环独有的角（共享段任何点不动，圆角不破坏共享边）。
    def _prep(raw_mesh):
        for v in raw_mesh.values():
            outer = []
            for o in v.get("outer", []):
                outer.extend(mesh_extract.split_self_touch(o))
            v["outer"] = [mesh_extract.simplify_collinear(o) for o in outer]
        return raw_mesh

    city_mesh = clean_mesh_shared(_prep(mesh_extract.extract_mesh(ctx_city)))
    legacy_mesh = clean_mesh_shared(_prep(mesh_extract.extract_mesh(ctx_legacy)))
    lake_mesh = mesh_extract.simplify_mesh(mesh_extract.extract_mesh(ctx_lake.astype(np.int32)), smooth_passes=2)

    # 出生 L1 权威轮廓 + 邻居块（灰色）：context 内除出生块外的所有老 L1 块
    l1_polygon = []
    for p in legacy_mesh.get(lab_l1, {}).get("outer", []):
        l1_polygon.extend(to_xy(p))
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
    city_pos = {int(c["label"]): c["city"] for c in cities}
    city_area = {int(c["label"]): int(c["area_px"]) for c in cities}
    tiles = []
    for rank, c in enumerate(cities, start=1):
        mv = city_mesh.get(int(c["label"]), {})
        outs = [to_xy(p) for p in mv.get("outer", [])]
        if not outs:
            outs = [[[float(p[0]) - x0, float(p[1]) - y0] for p in r] for r in c.get("polygons", [])]
            outs = [r for r in outs if len(r) >= 3]
        # split_self_touch 自触分割会产生多个 outer：主体 + 1px 碎条。
        # 按面积降序取面积最大者作主轮廓，剔除 <3px² 的自触碎条（特写下会渲染成小三角）。
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
    Image.fromarray(idx).save(os.path.join(GAME_DIR, "l1_mask.png"))

    base = np.full((side, side, 3), OCEAN_COLOR, dtype=np.uint8)
    for c in cities:
        base[ctx_city == c["label"]] = c["rgb"]
    for nlb in nbr_labels:
        base[ctx_legacy == nlb] = NEIGHBOR_COLOR
    base[ctx_lake] = LAKE_COLOR
    Image.fromarray(base).save(os.path.join(GAME_DIR, "l1_base.png"))

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
    with open(os.path.join(GAME_DIR, "l1_world.json"), "w", encoding="utf-8") as f:
        json.dump(jsonable(world), f, ensure_ascii=False, indent=1)

    print("完成：%d 城市 / %d 政权 / %d 道路，context %d, 邻居 %d, 湖泊 %d, focus %s" % (
        len(tiles), len(states), len(roads), side, len(neighbors_data), len(lakes), focus))
    print("  -> %s" % GAME_DIR)


if __name__ == "__main__":
    main()
