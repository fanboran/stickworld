"""L1 路网生成 —— 聚落间道路 polyline + tier 分级（总体设计 §5.9 / Phase E1，P3.5 贴地形重做）。

三部分边集（同城市对去重，tier 高者胜）：
  1. L1 内骨架 = 各包城市的 **Delaunay 邻接全连边**（连通度口径：一般情况下周围有几个
     城市就有几条路，除非被山脉/海切断——Delaunay 邻接即几何邻城，取代旧 MST
     n−1 条无冗余口径）。超长边按 delaunay_dist_cap_mult × 该包邻接边中位长过滤
     （防非凸/离群连出超长边）；过滤后按 MST 补回断连分量，保证无城市被孤立。
     边为土路 DIRT；两端均 T3+ 的升级官道 PAVED
  2. 跨 L1 主路 = 相邻老 L1（legacy 标签图邻接检测）的最近聚落对
  3. 重镇补边 = 全部 T3+ 城的 K 近邻（t3_knn，PAVED）

路径搜索（贴地形核心）：窗口有向 Dijkstra on 高度场网格（8192 降采样至 grid_res=4096，
1 格 = 2px，按边 bbox+pad 开窗），有向 8 邻域边权 = 步长(px) × (1 + 终点格静态加成 + 方向性坡度)：
  - 方向性坡度 = 梯度沿行进方向的分量（上坡贵 k_slope_up、下坡廉 k_slope_down）——
    沿等高线行进不付坡度账（分量≈0），穿山代价 ∫坡度 ≥ Δh 且绕峰更贵，
    路径自动经鞍点/垭口过山脊，无需显式山口豁免
  - 静态加成（终点格）：
      谷脊 TPI = h − 邻域均值（正=脊 负=谷）×k_tpi：河谷吸引、山脊回避
      河 k_river（无桥硬穿代价）/ 湖 k_lake；海洋不可通行
      群系加成 biome_cost（森林/荒漠/冰原/源流湿地/火山）
      低频噪声 ×noise_amp：平原区无地形信号时的自然蜿蜒（seed 固定可复现）
后处理：DP(dp_tolerance) 先收栅格台阶 → Chaikin ×chaikin_passes 磨圆拐角（顺序不可反）；
每条路 {from, to, tier(DIRT/PAVED), length_px, polyline[]}。

产出（覆盖写回，json 保持 indent=1 与原字段序）：
  - config/strategic_map/l1_world.json + l1_packs/*/l1_world.json：
    roads = **全量全局边中与本包 context 窗口相交的显示段**（含跨包边：from/to 可能
    是邻包聚落 ID，渲染只画折线）。polyline 裁剪到窗口内、坐标转包本地
    [x,y] = 世界 8192 − world_origin，length_px 按裁剪后折线重算。全局路网是单一
    真相，各包只内嵌落入本窗口的显示段，运行时零新增文件加载。窗口口径 = 包内
    world_origin + context_size（权威，与 river_export/blob/运行时同源；两字段缺失才
    回退按 legacy 蒙版重算）。无命中边的包保底保留原包内边（roads 不为空）。
  - output/roads_global.json：全大陆路网（8192 全局坐标，含 L1 内边 + 跨 L1 边）
    ——生成端参考产物，运行时零消费（E3 旅行 / E4 道路场景读各包 roads 字段）
  - output/roads_preview_2048.png：全大陆路网预览（密度参数交创始人验收）

用法：
  python road_generate.py                          # 全量 + 回写
  python road_generate.py --no-write               # 只出预览不回写
  python road_generate.py --skeleton mst --no-write
      # 基线口径（每包 MST n−1 条）只跑统计对比（连通度改造前后对照）
  python road_generate.py --no-write --only 69 --closeup
      # 只算端点落在指定老 L1 的边 + 从内存渲染出生 L1 特写（调参循环，不动 json）
  Python 须用完整路径（PATH 首位 python 无 scipy/numpy 完整版）
"""
import argparse
import json
import math
import os

import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import uniform_filter, zoom
from scipy.sparse import csr_matrix
from scipy.sparse.csgraph import dijkstra
from scipy.spatial import Delaunay

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # tools/worldgen
OUT_DIR = os.path.join(HERE, "output")
GAME_DIR = os.path.normpath(os.path.join(
    HERE, "..", "..", "stick-world", "config", "strategic_map"))
PARAMS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "road_params.json")

RES = 8192
MIN_MULT = 0.6   # 乘数下限（谷地折扣不至负/零）


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

def make_noise_field(grid, cell, p):
    """低频 value 噪声 ∈ [0,1]（八度倍频，seed 固定）——平原蜿蜒驱动。"""
    rng = np.random.default_rng(int(p["noise_seed"]))
    out = np.zeros((grid, grid), np.float32)
    amp, total = 1.0, 0.0
    decay = float(p["noise_decay"])
    for o in range(int(p["noise_octaves"])):
        n = max(4, round(grid * cell / (float(p["noise_wavelength_px"]) / (2 ** o))))
        layer = zoom(rng.random((n, n)).astype(np.float32), grid / n, order=1, mode="reflect")
        if layer.shape[0] >= grid:
            layer = layer[:grid, :grid]
        else:   # zoom 目标尺寸取整差 1 时贴边补齐
            layer = np.pad(layer, ((0, grid - layer.shape[0]), (0, grid - layer.shape[1])),
                           mode="edge")
        out += (amp * layer).astype(np.float32)
        total += amp
        amp *= decay
    out /= total
    return np.clip(out, 0.0, 1.0, out=out)


def build_cost_grid(p, grid):
    """8192 输入 → 指定 grid_res 的场 dict：static(每格静态加成)+gx/gy(每格梯度)+land+cell。

    方向性坡度项不进 static（依赖行进方向），搜路时按边现算。
    同一套参数可产出 4096（主力）/2048（长路粗搜）两级。
    """
    cell = RES // grid
    hm = np.asarray(np.load(
        os.path.join(OUT_DIR, "fractal_heightmap_8192.npy"), mmap_mode="r"), np.float32)
    h = block_reduce(hm, RES, grid, "mean").astype(np.float32)
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
    gx = gx.astype(np.float32)
    gy = gy.astype(np.float32)

    # 谷脊 TPI（邻域奇数边长）：正=脊 负=谷
    tpi_size = max(3, int(round(p["tpi_radius_px"] / cell)) | 1)
    static = (p["k_tpi"] * (h - uniform_filter(h, size=tpi_size))).astype(np.float32)
    static[river] += p["k_river"]
    static[lake] += p["k_lake"]
    # 群系加成（2048 标签最近邻上采样到搜索网格）
    b = np.load(os.path.join(OUT_DIR, "biome_labels_2048.npy"))
    k = max(1, grid // b.shape[0])
    bl = np.repeat(np.repeat(b, k, 0), k, 1)
    for code, add in p["biome_cost"].items():
        static[bl == int(code)] += float(add)
    return {"static": static, "gx": gx, "gy": gy, "land": land, "cell": cell}


def build_cost_ctx(p):
    """两级场：fine(grid_res) 主力搜路 + coarse(grid_res/2) 长路粗搜（窗格数超限时降级）。

    噪声在 fine 上生成后均值池化给 coarse——两级看到同一片噪声洼地，降级不换路。
    """
    grid = int(p["grid_res"])
    fine = build_cost_grid(p, grid)
    noise = make_noise_field(grid, fine["cell"], p)
    fine["static"] += (p["noise_amp"] * noise).astype(np.float32)
    coarse = build_cost_grid(p, grid // 2)
    coarse["static"] += (p["noise_amp"] * block_reduce(noise, grid, grid // 2, "mean")) \
        .astype(np.float32)
    return {"fine": fine, "coarse": coarse}


def nearest_land_cell(cell, land, max_r=12):
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


# ---------------------------------------------------------------- 搜路（窗口有向 Dijkstra）

def _dijkstra_window(f, start, goal, pad, window_max, p):
    """单级窗口有向 Dijkstra。返回 grid 坐标折线（含首尾）或 None（窗内不可达/超窗）。"""
    grid = f["static"].shape[0]
    x0 = max(0, min(start[0], goal[0]) - pad)
    x1 = min(grid, max(start[0], goal[0]) + pad + 1)
    y0 = max(0, min(start[1], goal[1]) - pad)
    y1 = min(grid, max(start[1], goal[1]) + pad + 1)
    gw, gh = x1 - x0, y1 - y0
    if gw <= 0 or gh <= 0 or gw * gh > window_max:
        if os.environ.get("ROADGEN_DEBUG"):
            print("    [win-invalid] grid=%d start=%s goal=%s pad=%d win=(%d:%d,%d:%d)"
                  % (grid, start, goal, pad, x0, x1, y0, y1))
        return None
    land_w = f["land"][y0:y1, x0:x1]
    static_w = f["static"][y0:y1, x0:x1]
    gx_w = f["gx"][y0:y1, x0:x1]
    gy_w = f["gy"][y0:y1, x0:x1]
    s_idx = (start[1] - y0) * gw + (start[0] - x0)
    g_idx = (goal[1] - y0) * gw + (goal[0] - x0)
    if not (0 <= s_idx < gh * gw and 0 <= g_idx < gh * gw):
        if os.environ.get("ROADGEN_DEBUG"):
            print("    [idx-out] grid=%d start=%s goal=%s win=(%d:%d,%d:%d) s=%d g=%d"
                  % (grid, start, goal, x0, x1, y0, y1, s_idx, g_idx))
        return None
    if not (land_w.flat[s_idx] and land_w.flat[g_idx]):
        return None

    cell = f["cell"]
    k_up, k_dn = p["k_slope_up"], p["k_slope_down"]
    flat = np.arange(gh * gw, dtype=np.int32).reshape(gh, gw)
    rows, cols, data = [], [], []
    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)):
        dlen = math.hypot(dx, dy)
        xs0, xs1 = (0, gw - 1) if dx == 1 else ((1, gw) if dx == -1 else (0, gw))
        ys0, ys1 = (0, gh - 1) if dy == 1 else ((1, gh) if dy == -1 else (0, gh))
        dst_y = slice(ys0 + dy, ys1 + dy)
        dst_x = slice(xs0 + dx, xs1 + dx)
        valid = land_w[ys0:ys1, xs0:xs1] & land_w[dst_y, dst_x]
        if not valid.any():
            continue
        # 方向性坡度：终点格梯度沿行进方向分量（单位 = 每 world px 高度 ×1000）
        s_u = (gx_w[dst_y, dst_x] * dx + gy_w[dst_y, dst_x] * dy) / (dlen * cell) * 1000.0
        mult = 1.0 + k_up * np.maximum(s_u, 0.0) + k_dn * np.maximum(-s_u, 0.0) \
            + static_w[dst_y, dst_x]
        mult = np.maximum(mult, MIN_MULT)
        w = (dlen * cell) * mult
        rows.append(flat[ys0:ys1, xs0:xs1][valid])
        cols.append(flat[dst_y, dst_x][valid])
        data.append(w[valid])
    if not rows:
        return None
    m = csr_matrix(
        (np.concatenate(data), (np.concatenate(rows), np.concatenate(cols))),
        shape=(gh * gw, gh * gw))
    dist, pred = dijkstra(m, directed=True, indices=s_idx, return_predecessors=True)
    if not np.isfinite(dist[g_idx]):
        return None
    path = []
    node = g_idx
    while node != s_idx and node >= 0:
        path.append((int(node % gw + x0), int(node // gw + y0)))
        node = int(pred[node])
    if node != s_idx:
        return None
    path.append((start[0], start[1]))
    return path[::-1]


def astar(ctx, start, goal, p, pad_mult=1.0):
    """窗口有向 Dijkstra（方向性坡度边权）。返回世界坐标折线（含首尾）或 None。

    函数名沿用 astar（主流程/重试语义不变）。两级降级：fine(grid_res) 窗格数超
    window_max 时降到 coarse（半分辨率粗搜，长路专用）；无启发式的 Dijkstra 在
    窗口内必终止，窗口即搜索界。None = 不可达（海/湖阻隔），上层重试宽窗或直线回退。
    """
    pad = int(p["astar_bbox_pad"] * pad_mult)
    fine_cell = ctx["fine"]["cell"]
    # 端点坐标按目标级 cell 换算（coarse cell = fine cell ×2）
    for f in (ctx["fine"], ctx["coarse"]):
        scale = f["cell"] // fine_cell
        s = (start[0] // scale, start[1] // scale) if scale > 1 else start
        g = (goal[0] // scale, goal[1] // scale) if scale > 1 else goal
        path = _dijkstra_window(f, s, g, pad, p["astar_window_max"], p)
        if path is not None:
            return [(x * f["cell"] + f["cell"] // 2, y * f["cell"] + f["cell"] // 2)
                    for x, y in path]
    return None


# ---------------------------------------------------------------- 边集构建（连通度口径）

def mst_pairs(pts):
    """Prim MST（口径与 export_l1_view_context.mst 一致，O(n²)）。

    用途：① --skeleton mst 基线对照；② Delaunay 长边过滤后补回断连分量。
    """
    n = len(pts)
    if n <= 1:
        return []
    used = [False] * n
    dist = [1e18] * n
    parent = [-1] * n
    dist[0] = 0.0
    out = []
    for _ in range(n):
        u = min((i for i in range(n) if not used[i]), key=lambda i: dist[i])
        used[u] = True
        if parent[u] >= 0:
            out.append((parent[u], u))
        for v in range(n):
            if used[v]:
                continue
            d = math.dist(pts[u], pts[v])
            if d < dist[v]:
                dist[v], parent[v] = d, u
    return out


def _components(n, pairs):
    """并查集分量数 + 每组代表元（给 MST 补边用）。"""
    par = list(range(n))

    def find(a):
        while par[a] != a:
            par[a] = par[par[a]]
            a = par[a]
        return a

    for a, b in pairs:
        ra, rb = find(a), find(b)
        if ra != rb:
            par[ra] = rb
    groups = {}
    for i in range(n):
        groups.setdefault(find(i), []).append(i)
    return groups


def delaunay_pairs(pts, cap_mult):
    """Delaunay 邻接全连边 + 超长边过滤 + 断连兜底。

    连通度口径（创始人 2026-09-23 定）：「一般情况下周围有几个城市就有几条道路，
    除非被山脉切断」——MST 的 n−1 条无冗余边不够，取 Delaunay 三角化邻偶作为
    候选边（每个城市连其几何邻城）。

    过滤：候选边长 > cap_mult × 该包候选边中位长 者剔除（非凸领土/离群城的
    Qhull 长边）。过滤后若出现孤立分量（离群城/离岛），按 MST 补回其最短连接，
    保证「没有城市无路」——补边的成因（被山脉切断）由搜路阶段决定是否直线回退。

    返回 (pairs, stats)：pairs 为索引对列表；stats = {n_cand, n_cut, n_rescue, cap}。
    """
    n = len(pts)
    if n < 2:
        return [], {"n_cand": 0, "n_cut": 0, "n_rescue": 0, "cap": 0.0}
    if n == 2:
        return [(0, 1)], {"n_cand": 1, "n_cut": 0, "n_rescue": 0, "cap": 0.0}
    try:
        tri = Delaunay(np.asarray(pts, np.float64))
        cand = set()
        for s in tri.simplices:
            for i in range(3):
                a, b = int(s[i]), int(s[(i + 1) % 3])
                cand.add((min(a, b), max(a, b)))
        cand = sorted(cand)
    except Exception as e:   # 共线/退化点集（Qhull 失败）：全对当候选，再由上限筛
        print("    [delaunay-quhull-fail] %s → 全对候选" % e)
        cand = [(i, j) for i in range(n) for j in range(i + 1, n)]
    lens = {p: math.dist(pts[p[0]], pts[p[1]]) for p in cand}
    med = float(np.median(list(lens.values()))) if lens else 0.0
    cap = cap_mult * med if med > 0 else 0.0
    keep = [p for p in cand if cap <= 0 or lens[p] <= cap + 1e-9]
    n_cut = len(cand) - len(keep)
    n_rescue = 0
    if len(_components(n, keep)) > 1:
        for a, b in mst_pairs(pts):   # MST 边是最短连接：补回即最小代价保连通
            if len(_components(n, keep + [(a, b)])) < len(_components(n, keep)):
                keep.append((a, b))
                n_rescue += 1
    return keep, {"n_cand": len(cand), "n_cut": n_cut, "n_rescue": n_rescue, "cap": cap}


# ---------------------------------------------------------------- 折线 → 包窗口裁剪

def _liang_barsky(a, b, x0, y0, x1, y1):
    """线段 [a,b] 对矩形 [x0,x1]×[y0,y1] 的参数区间，无交返回 None。"""
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    t0, t1 = 0.0, 1.0
    for num, den in ((ax - x0, -dx), (x1 - ax, dx), (ay - y0, -dy), (y1 - ay, dy)):
        if abs(den) < 1e-12:
            if num < 0:      # 平行且在界外
                return None
            continue
        r = num / den
        if den > 0:
            t1 = min(t1, r)
        else:
            t0 = max(t0, r)
        if t0 > t1:
            return None
    return t0, t1


def clip_polyline(pts, x0, y0, x1, y1):
    """折线按矩形裁剪，返回若干连续子折线（窗口外点剔除、跨界段截断）。

    Liang–Barsky 逐段求交：完全在窗内的段原样保留（贴边段因此完整，不另加 pad），
    出窗段丢弃，跨界段按边界交点截断并接续（出窗再入窗 = 两段独立子折线）。
    """
    pieces, cur = [], []
    for i in range(len(pts) - 1):
        a, b = pts[i], pts[i + 1]
        seg = _liang_barsky(a, b, x0, y0, x1, y1)
        if seg is None:
            if len(cur) >= 2:
                pieces.append(cur)
            cur = []
            continue
        t0, t1 = seg
        p0 = (a[0] + (b[0] - a[0]) * t0, a[1] + (b[1] - a[1]) * t0)
        p1 = (a[0] + (b[0] - a[0]) * t1, a[1] + (b[1] - a[1]) * t1)
        if cur and math.hypot(cur[-1][0] - p0[0], cur[-1][1] - p0[1]) < 1e-6:
            cur.append(p1)
        else:
            if len(cur) >= 2:
                pieces.append(cur)
            cur = [p0, p1]
    if len(cur) >= 2:
        pieces.append(cur)
    return [p for p in pieces if polyline_len(p) > 1e-6]


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


def detour_stats(pts):
    """调参指标：绕行度 = 折线长/端点直线距；mean/max 偏离端点直线的垂距。"""
    ax, ay = pts[0]
    bx, by = pts[-1]
    seg = math.hypot(bx - ax, by - ay)
    if seg < 1e-6:
        return 1.0, 0.0, 0.0
    ds = [abs((by - ay) * (x - ax) - (bx - ax) * (y - ay)) / seg for x, y in pts]
    return polyline_len(pts) / seg, sum(ds) / len(ds), max(ds)


# ---------------------------------------------------------------- L1 offset 重算

def pack_offset(label, side, legacy):
    """按 legacy 蒙版重放 export_l1_view_context 的 context 裁剪公式 → (x0, y0)。

    仅作**回退**：包内 world_origin 缺失时才用（权威窗口是包内 world_origin +
    context_size，与 river_export/blob/运行时同源；重算在换代后可能漂移 ±1..140px）。
    """
    m = legacy == label
    ys, xs = np.where(m)
    bx0, bx1, by0, by1 = xs.min(), xs.max(), ys.min(), ys.max()
    cx = int(round((bx0 + bx1) / 2.0))
    cy = int(round((by0 + by1) / 2.0))
    x0 = max(0, min(cx - side // 2, RES - side))
    y0 = max(0, min(cy - side // 2, RES - side))
    return int(x0), int(y0)


def pack_window(world, legacy, warn=None):
    """包的 context 窗口 (x0, y0, side)：首选包内 world_origin + context_size（权威），
    缺失才回退 legacy 蒙版重算。返回 (x0, y0, side, src)。"""
    side = int((world.get("context_size") or [0])[0]) or int(world.get("size", 0))
    wo = world.get("world_origin")
    if wo and side > 0:
        return int(wo[0]), int(wo[1]), side, "world_origin"
    x0, y0 = pack_offset(int(world["parent_l1_label"]), int(world["size"]), legacy)
    if warn is not None:
        warn.append("包 %s 缺 world_origin/context_size，按 legacy 重算窗口 @(%d,%d)"
                    % (os.path.basename(os.path.dirname(world.get("map_id", ""))) or "?", x0, y0))
    return x0, y0, int(world["size"]), "recomputed"


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
    ap = argparse.ArgumentParser(description="L1 路网生成（§5.9 E1，P3.5）")
    ap.add_argument("--no-write", action="store_true", help="只出预览，不回写 json")
    ap.add_argument("--only", default=None,
                    help="只算端点落在指定老 L1（逗号分隔 label）的边——调参循环用")
    ap.add_argument("--closeup", action="store_true",
                    help="从内存 roads 渲染出生 L1 特写（road_closeup_spawn_new.png，免回写）")
    ap.add_argument("--skeleton", choices=("delaunay", "mst"), default=None,
                    help="L1 内骨架口径：delaunay（默认，连通度口径）/ mst（旧基线，调参对比用）")
    args = ap.parse_args()
    if args.only and not args.no_write:
        print("  ⚠ --only 是调参过滤，自动置 --no-write（避免把子集路网写进交付 json）")
        args.no_write = True
    p = load_params()
    if args.skeleton:
        p["skeleton"] = args.skeleton
    skeleton = p.get("skeleton", "delaunay")
    grid = p["grid_res"]

    print("[1/7] cost 场（fine %d² + coarse %d²：谷脊 TPI+河湖+群系+噪声，坡度按边现算）..."
          % (grid, grid // 2))
    ctx = build_cost_ctx(p)

    print("[2/7] 视图包窗口（world_origin 权威）+ 城市（端点=pack position_px，级别=l3_city 分位）...")
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
        x0, y0, side, _src = pack_window(w, legacy, warn)
        for t in w["tiles"]:
            cid = int(t["tile_id"][5:])
            s = t.get("settlement") or {}
            if not s:
                continue
            pos = (float(s["position_px"][0]) + x0, float(s["position_px"][1]) + y0)
            cell = nearest_land_cell(
                (int(pos[0] * grid // RES), int(pos[1] * grid // RES)), ctx["fine"]["land"])
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
        packs.append({"path": pp, "world": w, "label": label,
                      "offset": (x0, y0), "side": side})
    # 出生根份（parent 69，窗口与 l1_069 不同）：同一批城市、另一窗口，polyline 另行裁剪
    root_path = os.path.join(GAME_DIR, "l1_world.json")
    root = json.load(open(root_path, encoding="utf-8"))
    rx0, ry0, rside, _src = pack_window(root, legacy, warn)
    packs.append({"path": root_path, "world": root,
                  "label": int(root["parent_l1_label"]), "offset": (rx0, ry0), "side": rside})
    n_t3 = sum(1 for v in cities.values() if v["level"] >= 3)
    print("  %d 份视图包，城市 %d（T3+ %d），异常 %d 处%s"
          % (len(packs), len(cities), n_t3, len(warn),
             ("，如：" + "; ".join(warn[:5])) if warn else ""))

    print("[4/7] 边集构建（内骨架=%s + 跨 L1 邻接对 + T3+ KNN）..." % skeleton)
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

    def tier_of(ca, cb):
        return "PAVED" if cities[ca]["level"] >= 3 and cities[cb]["level"] >= 3 else "DIRT"

    # L1 内骨架：Delaunay 邻接全连边（连通度口径；--skeleton mst 走旧基线）
    cap_mult = float(p.get("delaunay_dist_cap_mult", 1.5))
    skel_stats = {"n_cand": 0, "n_cut": 0, "n_rescue": 0}
    for pk in packs:
        cids = [int(t["tile_id"][5:]) for t in pk["world"]["tiles"] if t.get("settlement")]
        cids = [c for c in cids if c in cities]
        if skeleton == "mst":
            pairs = mst_pairs([cities[c]["pos"] for c in cids])
            st = {"n_cand": len(pairs), "n_cut": 0, "n_rescue": 0}
        else:
            pairs, st = delaunay_pairs([cities[c]["pos"] for c in cids], cap_mult)
        for k in ("n_cand", "n_cut", "n_rescue"):
            skel_stats[k] += st[k]
        for a, b in pairs:
            ca, cb = cids[a], cids[b]
            add_edge(ca, cb, tier_of(ca, cb), "mst" if skeleton == "mst" else "delaunay")
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
            add_edge(best[0], best[1], tier_of(best[0], best[1]), "inter_l1")
    t3 = sorted((c for c in cities if cities[c]["level"] >= 3),
                key=lambda c: cities[c]["pos"])
    for ca in t3:
        near = sorted((cb for cb in t3 if cb != ca),
                      key=lambda cb: math.dist(cities[ca]["pos"], cities[cb]["pos"]))
        for cb in near[:p["t3_knn"]]:
            add_edge(ca, cb, "PAVED", "knn")
    if args.only:
        keep = {int(v) for v in args.only.split(",")}
        edges = {k: e for k, e in edges.items()
                 if cities[e["a"]]["l1"] in keep or cities[e["b"]]["l1"] in keep}
    n_paved = sum(1 for e in edges.values() if e["tier"] == "PAVED")
    print("  边 %d 条（PAVED %d / DIRT %d）" % (len(edges), n_paved, len(edges) - n_paved))
    if skeleton == "delaunay" and not args.only:
        print("  内骨架 Delaunay：候选邻偶 %d，超长剔除 %d（上限 %.1f×该包邻边中位长），"
              "断连兜底补回 %d（MST 最短连接）"
              % (skel_stats["n_cand"], skel_stats["n_cut"], cap_mult, skel_stats["n_rescue"]))
    e_by_origin = {}
    for e in edges.values():
        e_by_origin[e["origin"]] = e_by_origin.get(e["origin"], 0) + 1
    print("  按来源：%s" % " / ".join("%s %d" % (k, v) for k, v in sorted(e_by_origin.items())))

    print("[5/7] 窗口 Dijkstra 搜路（方向坡度+谷脊+群系+噪声）+ Chaikin/DP...")
    cell_by_sid = {cities[c]["sid"]: cities[c]["cell"] for c in cities}
    pos_by_sid = {cities[c]["sid"]: cities[c]["pos"] for c in cities}
    roads_global = []
    n_fb = 0
    n_drop = 0
    n_retry = 0
    for i, e in enumerate(sorted(edges.values(),
                                 key=lambda e: (e["origin"], e["a"], e["b"])), 1):
        sa, sb = cities[e["a"]]["sid"], cities[e["b"]]["sid"]
        ca, cb = cell_by_sid[sa], cell_by_sid[sb]
        path = astar(ctx, ca, cb, p)
        if path is None:
            path = astar(ctx, ca, cb, p, pad_mult=2.5)   # 宽窗重试（绕山/绕湖）
            if path is not None:
                n_retry += 1
        if path is None:
            # 直线甄别：沿线采样全陆地才保留直线回退；跨海死路丢边（无海路）
            xs = np.linspace(ca[0], cb[0], 9)
            ys = np.linspace(ca[1], cb[1], 9)
            if not all(ctx["fine"]["land"][int(round(y)), int(round(x))]
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
            pts = list(path)   # astar 已输出世界坐标（端点格心）
            pts[0] = pos_by_sid[sa]
            pts[-1] = pos_by_sid[sb]
            # 顺序不可反：先 DP 把 8 方向栅格台阶收成长直段，再 Chaikin 把拐角磨圆。
            # 反过来（先平滑再 DP）DP 会把刚磨出的圆角全删回直线，产出纯折线。
            pts = chaikin(dp_simplify(pts, p["dp_tolerance"]), p["chaikin_passes"])
        dt, dm, dx_ = detour_stats(pts)
        roads_global.append({
            "from": sa, "to": sb, "tier": e["tier"], "origin": e["origin"],
            "length_px": round(polyline_len(pts), 1),
            "polyline": [[round(x, 2), round(y, 2)] for x, y in pts],
            "detour": round(dt, 3), "dev_mean": round(dm, 1), "dev_max": round(dx_, 1),
            **({"fallback": True} if e.get("fallback") else {}),
        })
        if args.only:
            print("    %s→%s %s len=%.0f detour=%.2f dev=%.1f/%.1f v=%d%s"
                  % (e["a"], e["b"], e["tier"], roads_global[-1]["length_px"],
                     dt, dm, dx_, len(pts), " ⚠fallback" if e.get("fallback") else ""))
        if i % 200 == 0:
            print("  %d/%d" % (i, len(edges)))
    stats = [r["detour"] for r in roads_global if not r.get("fallback")]
    print("  完成 %d 条（直线回退 %d / 跨海丢弃 %d / 宽窗重试 %d）" % (
        len(roads_global), n_fb, n_drop, n_retry))
    if stats:
        print("  绕行度 p50/p90/max = %.2f / %.2f / %.2f" % (
            sorted(stats)[len(stats) // 2],
            sorted(stats)[int(len(stats) * 0.9)], max(stats)))

    if not args.no_write:
        print("[6/7] 回写视图包 roads（全量全局边按包窗口裁剪）+ roads_global.json ...")
        pack_roads, wb = writeback_packs(
            packs, roads_global, cities, float(p.get("clip_pad_px", 0.0)))
        for pk in packs:
            w = pk["world"]
            w["roads"] = pack_roads[pk["path"]]
            with open(pk["path"], "w", encoding="utf-8") as f:
                json.dump(jsonable(w), f, ensure_ascii=False, indent=1)
        # roads_global 只留契约字段（detour/dev_* 是调参指标，不进交付数据）
        for r in roads_global:
            r.pop("detour", None)
            r.pop("dev_mean", None)
            r.pop("dev_max", None)
        with open(os.path.join(OUT_DIR, "roads_global.json"), "w", encoding="utf-8") as f:
            json.dump(jsonable({
                "name": "全大陆 L1 路网（§5.9 E1；生成端参考产物，运行时不读）",
                "size": RES,
                "coordinate": "[x,y] 8192 全局",
                "tier_meaning": {"DIRT": "土路", "PAVED": "官道", "HIGHWAY": "预留"},
                "roads": roads_global,
            }), f, ensure_ascii=False, indent=1)
        n_cross_global = sum(
            1 for r in roads_global
            if cities[int(r["from"][16:])]["l1"] != cities[int(r["to"][16:])]["l1"])
        print("  已写 %d 份 l1_world.json（包内条目共 %d，其中跨包边条目 %d；"
              "本包窗口命中边 %d 条→%d 段，%d 条被窗口截成多片（最多 %d 片）；"
              "%d 包无命中边→保底原 roads）"
              % (len(packs), wb["n_entries"], wb["n_cross_entries"], wb["n_edges_hit"],
                 wb["n_segments"], wb["n_multi_edges"], wb["max_pieces"],
                 wb["n_fallback_packs"]))
        print("  已写 roads_global.json（全局边 %d 条，其中跨 L1 边 %d 条）"
              % (len(roads_global), n_cross_global))
        print("  ⚠ 改了 json 记得重跑：godot --headless --path stick-world "
              "-s res://tools/worldgen/l_world_bake.gd")
    else:
        print("[6/7] --no-write 跳过回写")

    print("[7/7] 预览图 output/roads_preview_2048.png ...")
    render_preview(roads_global, cities, packs, root_path)
    if args.closeup:
        root_pk = next(pk for pk in packs if pk["path"] == root_path)
        loc = writeback_packs([root_pk], roads_global, cities,
                              float(p.get("clip_pad_px", 0.0)))[0][root_path]
        render_closeup(loc, root_pk)
    print("完成")


def writeback_packs(packs, roads_global, cities, clip_pad=0.0):
    """全量全局边 → 各包窗口内的显示段（局部坐标条目）。

    单一真相是 roads_global（世界 8192）：每包按 world_origin + context_size 窗口裁剪
    全部边（L1 内边 + 跨 L1 边 + KNN 补边），窗口外点剔除、跨界段截断，坐标转包本地。
    条目结构与旧版一致 {from, to, tier, length_px, polyline}——from/to 指向全局聚落
    （可能是邻包聚落），length_px 按裁剪后折线重算（跨包边在本包内只是显示段）。
    无命中边的包保底沿用原 roads（不空；防「某包整窗无路」渲染空窗）。
    clip_pad > 0 时裁剪矩形外扩 pad px（观感调参：收边段不被窗口切齐；默认 0 = 严格
    贴窗，验收口径「标出的点均在窗口内」按 0）。polyline 点均在 [0, side] 内。
    返回 (pack_path -> roads 列表, 统计)。
    """
    out = {}
    st = {"n_entries": 0, "n_cross_entries": 0, "n_edges_hit": 0, "n_segments": 0,
          "n_multi_edges": 0, "n_fallback_packs": 0, "max_pieces": 0}
    for pk in packs:
        x0, y0 = pk["offset"]
        cx0, cy0 = x0 - clip_pad, y0 - clip_pad
        cx1 = x0 + pk["side"] + clip_pad
        cy1 = y0 + pk["side"] + clip_pad
        new_roads = []
        for g in roads_global:
            pieces = clip_polyline(g["polyline"], cx0, cy0, cx1, cy1)
            if not pieces:
                continue
            st["n_edges_hit"] += 1
            if len(pieces) > 1:
                st["n_multi_edges"] += 1
                st["max_pieces"] = max(st["max_pieces"], len(pieces))
            cross = cities[int(g["from"][16:])]["l1"] != cities[int(g["to"][16:])]["l1"]
            st["n_segments"] += len(pieces)
            for pc in pieces:
                loc = [[round(x - x0, 2), round(y - y0, 2)] for x, y in pc]
                new_roads.append({
                    "from": g["from"], "to": g["to"], "tier": g["tier"],
                    "length_px": round(polyline_len(loc), 1), "polyline": loc,
                })
                if cross:
                    st["n_cross_entries"] += 1
        if not new_roads:
            # 保底：整窗无路（窗口全海/全未连边）→ 沿用原包内边，roads 不为空
            new_roads = pk["world"]["roads"]
            st["n_fallback_packs"] += 1
        st["n_entries"] += len(new_roads)
        out[pk["path"]] = new_roads
    return out, st


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
            side = pk["side"]
            dr.rectangle([x0 * k, y0 * k, (x0 + side) * k, (y0 + side) * k],
                         outline=(120, 220, 255), width=2)
    base.save(os.path.join(OUT_DIR, "roads_preview_2048.png"))


def render_closeup(roads, root_pk, scale=2.0):
    """调参循环用：渲染出生 L1 特写（roads 已是根份窗口本地坐标条目，免回写）。"""
    ss = 4
    w = root_pk["world"]
    side = int(w["size"])
    k = scale * ss
    S = int(side * k)
    base = Image.open(os.path.join(GAME_DIR, w["base_texture"])).convert("RGB") \
        .resize((S, S), Image.NEAREST)
    dr = ImageDraw.Draw(base)
    for t in w["tiles"]:
        for ring in t.get("polygons") or [t["polygon"]]:
            if len(ring) >= 3:
                dr.polygon([(x * k, y * k) for x, y in ring],
                           outline=(20, 20, 20), width=int(ss))
    style = {"DIRT": ((196, 160, 96), 2.0), "PAVED": ((255, 186, 72), 3.5)}
    for rd in roads:
        col, wd = style.get(rd["tier"], style["DIRT"])
        if rd.get("fallback"):
            col = (255, 80, 80)
        dr.line([(x * k, y * k) for x, y in rd["polyline"]],
                fill=col, width=max(1, int(wd * ss)), joint="curve")
    for t in w["tiles"]:
        s = t.get("settlement")
        if not s:
            continue
        x, y = s["position_px"][0] * k, s["position_px"][1] * k
        r = {1: 4, 2: 6, 3: 9}.get(int(s.get("level", 1)), 4) * ss * scale / 2
        col = {1: (225, 225, 225), 2: (245, 225, 130), 3: (255, 160, 70)} \
            .get(int(s.get("level", 1)))
        dr.ellipse([x - r, y - r, x + r, y + r], fill=col, outline=(15, 15, 15), width=int(ss))
    out = base.resize((int(side * scale), int(side * scale)), Image.LANCZOS)
    path = os.path.join(OUT_DIR, "road_closeup_spawn_new.png")
    out.save(path)
    print("  特写 -> %s" % path)


if __name__ == "__main__":
    main()
