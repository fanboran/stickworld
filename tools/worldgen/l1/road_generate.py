"""L1 路网生成 —— 聚落间道路 polyline + tier 分级（总体设计 §5.9 / Phase E1，Flash-F4）。

三部分边集（同城市对去重，tier 高者胜）：
  1. L1 内骨架 = 各 L1 视图包现有 roads 的 MST 连接对（MST=土路 DIRT；
     两端均 T3+ 的升级官道 PAVED）
  2. 跨 L1 主路 = 相邻老 L1（legacy 标签图邻接检测）的最近聚落对
  3. 重镇补边 = 全部 T3+ 城的 K 近邻（t3_knn，PAVED）

路径搜索：A* on 高度场网格（8192 降采样至 grid_res=1024），
cost = 步长 × (1 + k_slope×|∇h| + k_river(河) + k_lake(湖))，海洋不可通行；
山口豁免 = 沿两城连线剖面找鞍点（两侧窗内峰比凹点高 ≥ pass_depth），
山口邻近格坡度惩罚减免——「经山口穿山不在山顶硬穿」。
后处理：Chaikin ×chaikin_passes 平滑 + DP(dp_tolerance) 简化；
每条路 {from, to, tier(DIRT/PAVED), length_px, polyline[]}。

产出（覆盖写回，json 保持 indent=1 与原字段序）：
  - config/strategic_map/l1_world.json + l1_packs/*/l1_world.json：
    roads 扩展为完整结构，polyline 为该包 context 本地坐标 [x,y]
    （向后兼容：运行时 l1_world_data 只读 from/to 画直线，polyline 暂不消费）
  - config/strategic_map/roads_global.json：全大陆路网（8192 全局坐标，
    含 L1 内边 + 跨 L1 边，Phase E3 旅行连通性 / E4 道路场景数据源）
  - output/roads_preview_2048.png：全大陆路网预览（密度参数交创始人验收）

用法：
  python road_generate.py [--no-write]   # --no-write 只出预览不回写
  Python 须用完整路径（PATH 首位 python 无 scipy/numpy 完整版）
"""
import argparse
import heapq
import json
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # tools/worldgen
OUT_DIR = os.path.join(HERE, "output")
GAME_DIR = os.path.normpath(os.path.join(
    HERE, "..", "..", "stick-world", "config", "strategic_map"))
PARAMS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "road_params.json")

RES = 8192


def jsonable(o):
    """递归把 numpy 标量转回 Python 原生类型。"""
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


def load_params():
    with open(PARAMS_PATH, encoding="utf-8") as f:
        raw = json.load(f)
    return {k: v for k, v in raw.items() if not k.startswith("_")}


def block_reduce(arr, res, grid, fn):
    """res 方阵按 block=res//grid 聚合成 grid 方阵。"""
    b = res // grid
    return arr[:grid * b, :grid * b].reshape(grid, b, grid, b).mean(axis=(1, 3)) \
        if fn == "mean" else \
        arr[:grid * b, :grid * b].reshape(grid, b, grid, b).max(axis=(1, 3))


# ---------------------------------------------------------------- cost 场

def build_cost_grid(p):
    """8192 输入 → grid_res 权重场 w(cell)：海洋=inf，其余 ≥1。"""
    grid = p["grid_res"]
    hm = np.load(os.path.join(OUT_DIR, "fractal_heightmap_8192.npy")).astype(np.float32)
    h = block_reduce(hm, RES, grid, "mean")
    del hm
    cont = np.array(Image.open(os.path.join(
        OUT_DIR, "locked", "locked_continent_8192.png")).convert("L"))
    land = block_reduce(cont, RES, grid, "mean") >= 127.5
    del cont
    river = block_reduce(np.array(Image.open(os.path.join(
        OUT_DIR, "fractal_river_mask_8192.png")).convert("L")), RES, grid, "max") > 127
    lake = block_reduce(np.array(Image.open(os.path.join(
        OUT_DIR, "fractal_lake_mask_8192.png")).convert("L")), RES, grid, "max") > 127
    gy, gx = np.gradient(h)
    grad = np.hypot(gy, gx).astype(np.float32)
    w = (1.0 + p["k_slope"] * grad).astype(np.float32)
    w[river] += p["k_river"]
    w[lake] += p["k_lake"]
    w[~land] = np.inf
    return w, h, grad, land, river


def nearest_land_cell(cell, land, max_r=6):
    """城市质心落海/越界时螺旋找最近陆地格。"""
    x, y = cell
    if 0 <= x < land.shape[1] and 0 <= y < land.shape[0] and land[y, x]:
        return cell
    for r in range(1, max_r + 1):
        for dy in range(-r, r + 1):
            for dx in range(-r, r + 1):
                if max(abs(dx), abs(dy)) != r:
                    continue
                nx, ny = x + dx, y + dy
                if 0 <= nx < land.shape[1] and 0 <= ny < land.shape[0] and land[ny, nx]:
                    return (nx, ny)
    return None


# ---------------------------------------------------------------- 山口豁免

def pass_discount_cells(h, a, b, p):
    """沿 a→b 剖面找鞍点，返回 {flat_idx: slope_factor}（山口邻近坡度惩罚减免）。"""
    ax, ay = a
    bx, by = b
    n = int(math.hypot(bx - ax, by - ay)) + 1
    xs = np.round(np.linspace(ax, bx, n)).astype(int)
    ys = np.round(np.linspace(ay, by, n)).astype(int)
    prof = h[ys, xs]
    win = p["pass_window"]
    depth = p["pass_depth"]
    disc, factor, r = p["pass_discount"], 1.0 - p["pass_discount"], p["pass_radius"]
    grid = h.shape[0]
    out = {}
    for i in range(win, n - win):
        if prof[i] >= prof[i - win:i].max() or prof[i] >= prof[i + 1:i + win + 1].max():
            continue
        # 两侧窗内均有峰高出凹点 ≥ depth = 山脊上的局部低点（鞍点/山口）
        if prof[i - win:i].max() - prof[i] < depth or \
           prof[i + 1:i + win + 1].max() - prof[i] < depth:
            continue
        cx, cy = int(xs[i]), int(ys[i])
        for dy in range(-r, r + 1):
            for dx in range(-r, r + 1):
                nx, ny = cx + dx, cy + dy
                if 0 <= nx < grid and 0 <= ny < grid:
                    out[ny * grid + nx] = factor
    return out


# ---------------------------------------------------------------- A*

def astar(weight, start, goal, p, disc=None, pad_mult=1.0):
    """8 邻域 A*。返回 1024 网格坐标折线（含首尾）或 None。"""
    grid = weight.shape[0]
    pad = int(p["astar_bbox_pad"] * pad_mult)
    x0 = max(0, min(start[0], goal[0]) - pad)
    x1 = min(grid, max(start[0], goal[0]) + pad + 1)
    y0 = max(0, min(start[1], goal[1]) - pad)
    y1 = min(grid, max(start[1], goal[1]) + pad + 1)
    W = weight[y0:y1, x0:x1]
    gh, gw = W.shape
    sx, sy = start[0] - x0, start[1] - y0
    gx_, gy_ = goal[0] - x0, goal[1] - y0
    s_idx, g_idx = sy * gw + sx, gy_ * gw + gx_
    disc = disc or {}

    D = np.full(gh * gw, np.inf, np.float32)
    D[s_idx] = 0.0
    par = np.full(gh * gw, -1, np.int64)
    h_diag = math.sqrt(2.0)
    step8 = [(1, 0, 1.0), (-1, 0, 1.0), (0, 1, 1.0), (0, -1, 1.0),
             (1, 1, h_diag), (1, -1, h_diag), (-1, 1, h_diag), (-1, -1, h_diag)]
    heap = [(math.hypot(gx_ - sx, gy_ - sy), 0.0, s_idx)]
    expanded = 0
    limit = p["astar_max_expand"]
    while heap:
        f, g, cur = heapq.heappop(heap)
        if g > D[cur]:
            continue
        if cur == g_idx:
            path = []
            node = cur
            while node >= 0:
                path.append((node % gw + x0, node // gw + y0))
                node = par[node]
            return path[::-1]
        expanded += 1
        if expanded > limit:
            return None
        cx, cy = cur % gw, cur // gw
        for dx, dy, sl in step8:
            nx, ny = cx + dx, cy + dy
            if nx < 0 or ny < 0 or nx >= gw or ny >= gh:
                continue
            ni = ny * gw + nx
            w = float(W[ny, nx])
            if w == np.inf:
                continue
            # disc key 是全局 flat（pass_discount_cells 按全局网格记），换算后查
            f_disc = disc.get((ny + y0) * grid + (nx + x0))
            if f_disc is not None:
                w *= f_disc
            ng = g + sl * w
            if ng < D[ni]:
                D[ni] = ng
                par[ni] = cur
                heapq.heappush(heap, (ng + math.hypot(gx_ - nx, gy_ - ny), ng, ni))
    return None


# ---------------------------------------------------------------- 折线后处理

def chaikin(pts, passes):
    """开放折线切角平滑，保留首尾点。"""
    for _ in range(passes):
        if len(pts) < 3:
            return pts
        out = [pts[0]]
        for i in range(len(pts) - 1):
            a, b = pts[i], pts[i + 1]
            out.append((0.75 * a[0] + 0.25 * b[0], 0.75 * a[1] + 0.25 * b[1]))
            out.append((0.25 * a[0] + 0.75 * b[0], 0.25 * a[1] + 0.75 * b[1]))
        out.append(pts[-1])
        pts = out
    return pts


def dp_simplify(pts, tol):
    """Ramer-Douglas-Peucker（迭代栈防深递归）。"""
    n = len(pts)
    if n < 3:
        return pts
    keep = [False] * n
    keep[0] = keep[-1] = True
    stack = [(0, n - 1)]
    while stack:
        lo, hi = stack.pop()
        if hi - lo < 2:
            continue
        ax, ay = pts[lo]
        bx, by = pts[hi]
        dx, dy = bx - ax, by - ay
        seg = math.hypot(dx, dy)
        best, bi = -1.0, -1
        for i in range(lo + 1, hi):
            px, py = pts[i]
            d = abs(dy * (px - ax) - dx * (py - ay)) / seg if seg > 1e-9 else \
                math.hypot(px - ax, py - ay)
            if d > best:
                best, bi = d, i
        if best > tol:
            keep[bi] = True
            stack.append((lo, bi))
            stack.append((bi, hi))
    return [pt for pt, k in zip(pts, keep) if k]


def polyline_len(pts):
    return sum(math.hypot(pts[i + 1][0] - pts[i][0], pts[i + 1][1] - pts[i][1])
               for i in range(len(pts) - 1))


# ---------------------------------------------------------------- L1 offset 重算

def pack_offset(label, side, legacy):
    """重放 export_l1_view_context 的 context 裁剪公式 → (x0, y0)。"""
    m = legacy == label
    ys, xs = np.where(m)
    bx0, bx1, by0, by1 = xs.min(), xs.max(), ys.min(), ys.max()
    cx = int(round((bx0 + bx1) / 2.0))
    cy = int(round((by0 + by1) / 2.0))
    x0 = max(0, min(cx - side // 2, RES - side))
    y0 = max(0, min(cy - side // 2, RES - side))
    return int(x0), int(y0)


def point_in_ring(pt, ring):
    """射线法 point-in-polygon（本地坐标校验聚落确在自己地块内）。"""
    x, y = pt
    inside = False
    n = len(ring)
    j = n - 1
    for i in range(n):
        xi, yi = ring[i]
        xj, yj = ring[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi + 1e-12) + xi:
            inside = not inside
        j = i
    return inside


# ---------------------------------------------------------------- 主流程

def main():
    ap = argparse.ArgumentParser(description="L1 路网生成（§5.9 E1）")
    ap.add_argument("--no-write", action="store_true", help="只出预览，不回写 json")
    args = ap.parse_args()
    p = load_params()
    grid = p["grid_res"]

    print("[1/7] cost 场（%d²，坡度+河湖+海洋）..." % grid)
    weight, h_grid, grad, land, _river = build_cost_grid(p)

    print("[2/7] 视图包 offset 重算 + 城市（端点=pack position_px，级别=l3_city 分位）...")
    legacy = np.load(os.path.join(OUT_DIR, "l1_v2", "legacy_l1_labels_8192.npy")).astype(np.int32)
    city = json.load(open(os.path.join(GAME_DIR, "l3_city.json"), encoding="utf-8"))
    city_meta = {int(c["label"]): c for c in city["tiles"]}
    pack_files = sorted(
        os.path.join(GAME_DIR, "l1_packs", d, "l1_world.json")
        for d in os.listdir(os.path.join(GAME_DIR, "l1_packs"))
        if d.startswith("l1_"))
    packs = []
    cities = {}
    warn = []
    for pp in pack_files:
        w = json.load(open(pp, encoding="utf-8"))
        label = int(w["parent_l1_label"])
        x0, y0 = pack_offset(label, int(w["size"]), legacy)
        for t in w["tiles"]:
            cid = int(t["tile_id"][5:])
            s = t.get("settlement") or {}
            if not s:
                continue
            pos = (float(s["position_px"][0]) + x0, float(s["position_px"][1]) + y0)
            cell = nearest_land_cell((int(pos[0] * grid // RES), int(pos[1] * grid // RES)), land)
            if cell is None:
                warn.append("city_%d 质心附近无陆地格" % cid)
                continue
            ring = t.get("polygon") or (t.get("polygons") or [[0, 0]])[0]
            if not point_in_ring((float(s["position_px"][0]), float(s["position_px"][1])), ring):
                warn.append("city_%d position 不在主环内" % cid)
            lv = int(city_meta.get(cid, {}).get("level", s.get("level", 1)))
            cities[cid] = {
                "sid": "settlement_city_%03d" % cid,
                "pos": pos,
                "level": lv,
                "l1": label,
                "cell": cell,
            }
        packs.append({"path": pp, "world": w, "label": label, "offset": (x0, y0)})
    # 出生根份（parent 69，context 与 l1_069 不同）：城市 pos 以根份为准覆盖
    root_path = os.path.join(GAME_DIR, "l1_world.json")
    root = json.load(open(root_path, encoding="utf-8"))
    rx0, ry0 = pack_offset(int(root["parent_l1_label"]), int(root["size"]), legacy)
    packs.append({"path": root_path, "world": root,
                  "label": int(root["parent_l1_label"]), "offset": (rx0, ry0)})
    n_t3 = sum(1 for v in cities.values() if v["level"] >= 3)
    print("  %d 份视图包，城市 %d（T3+ %d），异常 %d 处%s"
          % (len(packs), len(cities), n_t3, len(warn),
             ("，如：" + "; ".join(warn[:5])) if warn else ""))

    print("[4/7] 边集构建（MST 骨架 + 邻接对 + T3+ KNN）...")
    edges = {}   # frozenset(sid) -> {a, b, tier, origin}

    def add_edge(ca, cb, tier, origin):
        if ca == cb:
            return
        key = frozenset((ca, cb))
        cur = edges.get(key)
        if cur is None:
            edges[key] = {"a": ca, "b": cb, "tier": tier, "origin": origin}
        elif tier == "PAVED" and cur["tier"] != "PAVED":
            cur["tier"] = "PAVED"

    for pk in packs:
        if pk["path"] == root_path:
            continue   # 根份与 l1_069 同 MST，避免重复
        id2cid = {"settlement_city_%03d" % cid: cid for cid in cities}
        for rd in pk["world"]["roads"]:
            ca, cb = id2cid.get(rd["from"]), id2cid.get(rd["to"])
            if ca is None or cb is None:
                continue
            tier = "PAVED" if cities[ca]["level"] >= 3 and cities[cb]["level"] >= 3 \
                else "DIRT"
            add_edge(ca, cb, tier, "mst")
    # 老 L1 邻接（2048 降采样，向量化接触检测）
    lab4 = legacy[::4, ::4]
    del legacy
    adj = set()
    for a, b in ((lab4[:-1, :], lab4[1:, :]), (lab4[:, :-1], lab4[:, 1:])):
        m = (a != b) & (a > 0) & (b > 0)
        if m.any():
            adj |= {tuple(sorted((int(x), int(y)))) for x, y in zip(a[m], b[m])}
    del lab4
    print("  老 L1 邻接对 %d 个" % len(adj))
    for la, lb in sorted(adj):
        best, bd = None, 1e18
        for ca in cities:
            if cities[ca]["l1"] != la:
                continue
            for cb in cities:
                if cities[cb]["l1"] != lb:
                    continue
                d = math.dist(cities[ca]["pos"], cities[cb]["pos"])
                if d < bd:
                    bd, best = d, (ca, cb)
        if best:
            tier = "PAVED" if cities[best[0]]["level"] >= 3 and cities[best[1]]["level"] >= 3 \
                else "DIRT"
            add_edge(*best, tier, "inter_l1")
    t3 = sorted((c for c in cities if cities[c]["level"] >= 3),
                key=lambda c: cities[c]["pos"])
    for ca in t3:
        near = sorted((cb for cb in t3 if cb != ca),
                      key=lambda cb: math.dist(cities[ca]["pos"], cities[cb]["pos"]))
        for cb in near[:p["t3_knn"]]:
            add_edge(ca, cb, "PAVED", "knn")
    print("  边 %d 条（PAVED %d / DIRT %d）" % (
        len(edges),
        sum(1 for e in edges.values() if e["tier"] == "PAVED"),
        sum(1 for e in edges.values() if e["tier"] == "DIRT")))

    print("[5/7] A* 搜路（山口豁免）+ Chaikin/DP...")
    cell_by_sid = {cities[c]["sid"]: cities[c]["cell"] for c in cities}
    pos_by_sid = {cities[c]["sid"]: cities[c]["pos"] for c in cities}
    roads_global = []
    n_fb = 0
    n_drop = 0
    for i, e in enumerate(sorted(edges.values(),
                                 key=lambda e: (e["origin"], e["a"], e["b"])), 1):
        sa, sb = cities[e["a"]]["sid"], cities[e["b"]]["sid"]
        ca, cb = cell_by_sid[sa], cell_by_sid[sb]
        disc = pass_discount_cells(h_grid, ca, cb, p)
        path = astar(weight, ca, cb, p, disc)
        if path is None:
            path = astar(weight, ca, cb, p, disc, pad_mult=2.5)   # 宽 bbox 重试（绕山/绕湖）
        if path is None:
            # 直线甄别：沿线采样全陆地才保留直线回退；跨海死路丢边（无海路）
            xs = np.linspace(ca[0], cb[0], 9)
            ys = np.linspace(ca[1], cb[1], 9)
            if not all(land[int(round(y)), int(round(x))]
                       for x, y in zip(xs, ys)
                       if 0 <= int(round(x)) < grid and 0 <= int(round(y)) < grid):
                n_drop += 1
                if i % 200 == 0:
                    print("  %d/%d" % (i, len(edges)))
                continue
            n_fb += 1
            pts = [pos_by_sid[sa], pos_by_sid[sb]]
            e["fallback"] = True
        else:
            pts = [(x * (RES // grid) + (RES // grid) // 2,
                    y * (RES // grid) + (RES // grid) // 2) for x, y in path]
            pts[0] = pos_by_sid[sa]
            pts[-1] = pos_by_sid[sb]
            pts = dp_simplify(chaikin(pts, p["chaikin_passes"]), p["dp_tolerance"])
        roads_global.append({
            "from": sa, "to": sb, "tier": e["tier"], "origin": e["origin"],
            "length_px": round(polyline_len(pts), 1),
            "polyline": [[round(x, 2), round(y, 2)] for x, y in pts],
            **({"fallback": True} if e.get("fallback") else {}),
        })
        if i % 200 == 0:
            print("  %d/%d" % (i, len(edges)))
    print("  完成 %d 条（直线回退 %d / 跨海丢弃 %d）" % (len(roads_global), n_fb, n_drop))

    if not args.no_write:
        print("[6/7] 回写视图包 roads（本地坐标）+ roads_global.json ...")
        rd_by_key = {frozenset((r["from"], r["to"])): r for r in roads_global}
        n_kept = 0   # 无路网匹配保留原样的边（群岛跨海 MST 边：无陆路，渲染回退直线）
        for pk in packs:
            w = pk["world"]
            x0, y0 = pk["offset"]
            new_roads = []
            for rd in w["roads"]:
                g = rd_by_key.get(frozenset((rd["from"], rd["to"])))
                if g is None:
                    new_roads.append(rd)   # 理论不发生（MST 全覆盖），保守保留原样
                    continue
                loc = [[round(x - x0, 2), round(y - y0, 2)] for x, y in g["polyline"]]
                new_roads.append({
                    "from": g["from"], "to": g["to"], "tier": g["tier"],
                    "length_px": g["length_px"], "polyline": loc,
                })
            n_kept += sum(1 for rd in new_roads if "polyline" not in rd)
            w["roads"] = new_roads
            with open(pk["path"], "w", encoding="utf-8") as f:
                json.dump(jsonable(w), f, ensure_ascii=False, indent=1)
        with open(os.path.join(GAME_DIR, "roads_global.json"), "w", encoding="utf-8") as f:
            json.dump(jsonable({
                "name": "全大陆 L1 路网（§5.9 E1；旅行连通性/道路场景数据源）",
                "size": RES,
                "coordinate": "[x,y] 8192 全局",
                "tier_meaning": {"DIRT": "土路", "PAVED": "官道", "HIGHWAY": "预留"},
                "roads": roads_global,
            }), f, ensure_ascii=False, indent=1)
        print("  已写 %d 份 l1_world.json + roads_global.json（%d 条；保留原样直线边 %d 条——群岛无陆路）"
              % (len(packs), len(roads_global), n_kept))
        print("  ⚠ 改了 json 记得重跑：godot --headless --path stick-world "
              "-s res://tools/worldgen/l_world_bake.gd")
    else:
        print("[6/7] --no-write 跳过回写")

    print("[7/7] 预览图 output/roads_preview_2048.png ...")
    render_preview(roads_global, cities, packs, root_path)
    print("完成")


def render_preview(roads_global, cities, packs, root_path):
    """2048 预览：高度场灰底 + 海蓝；路按 tier 着色（回退红虚线示意）。"""
    S = 2048
    k = S / RES
    hm = np.load(os.path.join(OUT_DIR, "fractal_heightmap_8192.npy")).astype(np.float32)
    small = hm[::RES // S, ::RES // S][:S, :S]
    del hm
    cont = np.array(Image.open(os.path.join(
        OUT_DIR, "locked", "locked_continent_8192.png")).convert("L"))[::RES // S, ::RES // S][:S, :S]
    img = np.zeros((S, S, 3), np.uint8)
    sea = cont < 127.5   # 海陆判定与 cost 场同源（locked 大陆掩码），高度场只供明暗
    img[sea] = (24, 40, 66)
    g8 = np.clip(small[~sea] * 0.9 + 0.08, 0, 1)
    img[~sea] = np.stack([g8 * 96 + 34, g8 * 92 + 40, g8 * 82 + 30], axis=1)
    base = Image.fromarray(img)
    dr = ImageDraw.Draw(base)
    style = {"DIRT": ((176, 141, 87), 1), "PAVED": ((255, 179, 64), 2),
             "HIGHWAY": ((255, 96, 64), 3)}
    for rd in roads_global:
        col, wd = style.get(rd["tier"], style["DIRT"])
        pts = [(x * k, y * k) for x, y in rd["polyline"]]
        if rd.get("fallback"):
            dr.line(pts, fill=(255, 70, 70), width=1)
        else:
            dr.line(pts, fill=col, width=wd)
    for c in cities.values():
        x, y = c["pos"][0] * k, c["pos"][1] * k
        r = {1: 2, 2: 3, 3: 5}.get(c["level"], 2)
        col = {1: (200, 200, 200), 2: (240, 220, 120), 3: (255, 150, 60)}[c["level"]]
        dr.ellipse([x - r, y - r, x + r, y + r], fill=col, outline=(20, 20, 20))
    # 出生 L1 context 亮框（根份）
    for pk in packs:
        if pk["path"] == root_path:
            x0, y0 = pk["offset"]
            side = pk["world"]["size"]
            dr.rectangle([x0 * k, y0 * k, (x0 + side) * k, (y0 + side) * k],
                         outline=(120, 220, 255), width=2)
    base.save(os.path.join(OUT_DIR, "roads_preview_2048.png"))


if __name__ == "__main__":
    main()
