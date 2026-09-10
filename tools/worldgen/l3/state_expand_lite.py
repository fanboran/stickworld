"""政权生成器 R7 版（总体设计 §5.11 + 观感返工方案 §R7，扩容 80 国）

相对 P7 简化版的变化（算法族不变，仍是文化圈 MCP 测地场 + 城图多源 Dijkstra）：
  - 种子改「城市种子」：population_score top-N + 四叉树间距（FMG states-generator 同族，
    §7.4-1 最小改动路径），N = n_states_total - 出生城邦数，按文化圈城数占比配额
  - 每国随机 expansionism 系数 + Zipf 型目标面积（圈内 r^-s）+ w_i 面积反馈迭代
    → 面积幂律分布，大小悬殊自然
  - 扩张代价加高程带重罚（山脊）+ 河流径流罚 → 边界自动贴河线/山脊
  - normalize 多数邻域翻转消飞地（FMG normalize 同款）
  - 政权色从 CONTENT_PALETTE 派生（R8 层3：7 族 × 族内明度/饱和档，废除 HSL 黄金角），
    贪心图着色保证「相邻国不同族优先、同族不同档」
  - 政治色不再烘焙颜色贴图（R9 过渡态裁决）：改产政权 ID mask
    （L3 一张 8192 单通道 PNG + L2 每地区窗口裁切，像素值 = lut_index 1..80），
    运行时 LUT 查表上色——改 LUT 即全图换色，零重烘
  - 命名接口 name_source（创始人 2026-09-08 定）：占位词表 JSON（键=state_id），
    缺项生成「文化圈前缀+编号」占位名（全部「提案/待定」）；世界观会话定稿后换表重跑

文化圈锚点（§5.11.1 种族-地域表，不可破坏）：region 越界罚机制沿用 + 认领过滤——
火焰=region_008、水=region_011、极地=北部冰原带(1/2/3/9)、沙漠=南部荒漠带(10+南探)、
森林=region_004、雪山=region_007；政权必须落在对应文化圈内。

用法：
  python state_expand_lite.py [--dry-run] [--skip-preview]
    --dry-run     只跑算法与指标，不写任何 config 文件
    --skip-preview 不输出 output/ 验收预览大图
"""

import argparse
import colorsys
import heapq
import json
import math
import os
import random
from collections import Counter, defaultdict

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy.ndimage import map_coordinates
from skimage.graph import MCP_Geometric

SIZE = 2048
SIZE_FULL = 8192
HERE = os.path.dirname(os.path.abspath(__file__))
OUTPUT_DIR = os.path.join(os.path.dirname(HERE), "output")
GAME_CFG = os.path.normpath(os.path.join(
    HERE, "..", "..", "..", "stick-world", "config", "strategic_map"))
PARAMS_PATH = os.path.join(HERE, "state_params.json")

OCEAN = (30, 55, 95)
# 群系标签（biome_generate.py 同源）
BI_SOURCE, BI_VOLCANIC, BI_DESERT, BI_ICE = 5, 6, 3, 4

# L2 ID mask 保留码（非政权）：与运行时 PoliticalLut / l2_map_renderer 常量同源
CODE_LAKE = 254      # 湖泊（l2_map_renderer.LAKE_COLOR）
CODE_NEIGHBOR = 255  # 邻区灰底（l2_map_renderer.NEIGHBOR_COLOR）

# ---------- CONTENT_PALETTE（20 色内容色板，7 族） ----------
# 来源：stick-world/modules/ui_global/scripts/theme/stick_tokens.gd 的 CONTENT_PALETTE
# （派生自游戏贴图盘点，见 docs/设计/UI/01-设计语言.md §2.6；作用域含「地图点缀」）。
# 色值与 token 同源（float × 255 四舍五入），政权色由各族变体派生——保证与游戏
# 纹章/组织标签色同语言，替代体系外的 HSL 黄金角（R8 层3 裁决）。
CONTENT_PALETTE_FAMILIES = [
    # 草绿族（地面 grassland #84b43c/#6c9c3c/#54843c + 麦色）
    ("grass", [(0.78, 0.72, 0.48), (0.66, 0.76, 0.34), (0.48, 0.68, 0.32), (0.33, 0.52, 0.28)]),
    # 青碧族（背景树线/近山 #3c8484/#549cb4/#246c54）
    ("teal", [(0.30, 0.58, 0.52), (0.35, 0.62, 0.64), (0.20, 0.42, 0.38)]),
    # 天蓝族（远山/云 #6c9ccc/#cce4fc）
    ("sky", [(0.42, 0.62, 0.80), (0.35, 0.48, 0.66)]),
    # 琥珀棕族（UI 琥珀同源 + 木建筑/木盾 #845424/#6c3c0c）
    ("amber", [(0.95, 0.68, 0.25), (0.62, 0.44, 0.26), (0.45, 0.30, 0.18), (0.80, 0.68, 0.42)]),
    # 土石族（资源图标 #6c543c/#9c9c9c/#848484）
    ("earth", [(0.52, 0.42, 0.30), (0.62, 0.52, 0.40), (0.62, 0.62, 0.58), (0.44, 0.45, 0.47)]),
    # 红族（阵营/战旗补缺：语义红降饱和压暗）
    ("red", [(0.66, 0.36, 0.30), (0.52, 0.27, 0.25)]),
    # 紫族（补缺）
    ("purple", [(0.48, 0.38, 0.52)]),
]


def sid_of(label):
    """城 label（int）→ settlement id（P4 惯例：三位补零）"""
    return "settlement_city_%03d" % int(label)


def load_params():
    with open(PARAMS_PATH, encoding="utf-8") as f:
        return json.load(f)


def load_inputs():
    hm = np.load(os.path.join(OUTPUT_DIR, "fractal_heightmap_8192.npy"))
    k = SIZE_FULL // SIZE
    elev = hm.reshape(SIZE, k, SIZE, k).mean(axis=(1, 3)).astype(np.float32)
    river = np.array(Image.open(
        os.path.join(OUTPUT_DIR, "fractal_river_mask_8192.png")).convert("L"))
    river = np.asarray(
        Image.fromarray(river).resize((SIZE, SIZE), Image.NEAREST)) > 127
    biome = np.load(os.path.join(OUTPUT_DIR, "biome_labels_2048.npy"))
    region = np.load(os.path.join(OUTPUT_DIR, "regions", "region_labels.npy"))
    with open(os.path.join(GAME_CFG, "l3_city.json"), encoding="utf-8") as f:
        city_json = json.load(f)
    with open(os.path.join(GAME_CFG, "l1_world.json"), encoding="utf-8") as f:
        birth_json = json.load(f)
    return elev, river, biome, region, city_json, birth_json


# ---------- Step 1：文化圈（§5.11.1 锚点，region 越界罚沿用） ----------

def build_culture_seeds(cities, region, biome, cultures):
    """锚点种子：culture 列表 → 像素种子 [(row, col, culture_idx)]。

    - regions 全部城的 anchor 质心一枚种子
    - south_seed_regions：在这些 region 的最南城 anchor 加撒种子（荒漠带跨 region 延伸）
    群岛质心常落海（MCP 海洋 cost 巨大无法扩散）→ 落海时改用离质心最近的城 anchor。
    """
    by_region = defaultdict(list)
    for c in cities:
        by_region[c["region"]].append(c)

    def snap_to_land(cy, cx, grp):
        if biome[int(cy), int(cx)] > 0:
            return int(cy), int(cx)
        best = min(grp, key=lambda g: (g["sx"] - cx) ** 2 + (g["sy"] - cy) ** 2)
        return int(best["sy"]), int(best["sx"])

    seeds = []
    for ci, cu in enumerate(cultures):
        grp = [g for r in cu["regions"] for g in by_region.get(r, [])]
        if not grp:
            print("  [warn] culture %s 无城（regions=%s），跳过" % (cu["id"], cu["regions"]))
            continue
        cy = sum(g["sy"] for g in grp) / len(grp)
        cx = sum(g["sx"] for g in grp) / len(grp)
        seeds.append(snap_to_land(cy, cx, grp) + (ci,))
        for r in cu.get("south_seed_regions", []):
            grp2 = by_region.get(r, [])
            if not grp2:
                continue
            south = max(grp2, key=lambda g: g["sy"])
            seeds.append((int(south["sy"]), int(south["sx"]), ci))
    return seeds


def culture_flood(seeds, elev, river, biome, region, cultures, fp):
    """分 culture 的测地 flood：每 culture 一张 cost 场（region 越界罚只对自己的
    合法 region 集外生效，§5.11.1 锚点语义），各自 MCP 求累计代价 → 逐像素
    argmin 归圈。返回 culture_idx+1 标签图（0 = 海/无）。
    （P7 定标：不许单 cost 场混跑——任一 culture 合法即免罚会削弱锚定；罚 30 挡游牧）
    """
    gy, gx = np.gradient(elev)
    gradmag = np.sqrt(gy * gy + gx * gx)
    land = biome > 0
    base = 1.0 + fp["k_slope"] * gradmag         + fp["k_river"] * river         + fp["k_desert"] * (biome == BI_DESERT)         + fp["k_ice"] * (biome == BI_ICE)
    base = np.where(land, base, 1e6).astype(np.float64)

    n_cu = len(cultures)
    cum_all = np.full((n_cu, region.shape[0], region.shape[1]),
                      np.inf, dtype=np.float32)
    for ci, cu in enumerate(cultures):
        starts = [(sd[0], sd[1]) for sd in seeds if sd[2] == ci]
        if not starts:
            continue
        costs = base.copy()
        legal = np.zeros(region.shape, dtype=bool)
        for r in cu["regions"]:
            legal |= (region == r)
        costs = costs + np.where(legal, 0.0, fp["k_cross_region"]) * land
        mcp = MCP_Geometric(costs)
        cum, _ = mcp.find_costs(starts)
        cum_all[ci] = cum.astype(np.float32)

    best = np.argmin(cum_all, axis=0)
    best_cost = np.take_along_axis(cum_all, best[None, ...], axis=0)[0]
    labels = np.where(best_cost > 6000.0, 0, (best + 1).astype(np.int16))
    return labels


# ---------- Step 2：城市种子（population top-N + 四叉树间距） ----------

class _SeedQuadtree:
    """点四叉树：圆域内已有种子查询（FMG 首都布点同款间距筛选，§7.4-1）。"""

    _CAP = 8

    def __init__(self, x0, y0, x1, y1):
        self.x0, self.y0, self.x1, self.y1 = x0, y0, x1, y1
        self.pts = []
        self.kids = None

    def insert(self, x, y):
        if self.kids is None:
            if len(self.pts) < self._CAP             or (self.x1 - self.x0) < 4.0:
                self.pts.append((x, y))
                return
            cxm, cym = (self.x0 + self.x1) / 2.0, (self.y0 + self.y1) / 2.0
            self.kids = [
                _SeedQuadtree(self.x0, self.y0, cxm, cym),
                _SeedQuadtree(cxm, self.y0, self.x1, cym),
                _SeedQuadtree(self.x0, cym, cxm, self.y1),
                _SeedQuadtree(cxm, cym, self.x1, self.y1),
            ]
            old, self.pts = self.pts, []
            for px, py in old:
                self.insert(px, py)
        cxm, cym = (self.x0 + self.x1) / 2.0, (self.y0 + self.y1) / 2.0
        self.kids[(0 if y < cym else 2) + (0 if x < cxm else 1)].insert(x, y)

    def has_within(self, x, y, r):
        if self.kids is None:
            return any((px - x) ** 2 + (py - y) ** 2 < r * r for px, py in self.pts)
        cxm, cym = (self.x0 + self.x1) / 2.0, (self.y0 + self.y1) / 2.0
        boxes = [(self.x0, self.y0, cxm, cym), (cxm, self.y0, self.x1, cym),
                 (self.x0, cym, cxm, self.y1), (cxm, cym, self.x1, self.y1)]
        for kid, (kx0, ky0, kx1, ky1) in zip(self.kids, boxes):
            nx = min(max(x, kx0), kx1)
            ny = min(max(y, ky0), ky1)
            if (nx - x) ** 2 + (ny - y) ** 2 <= r * r                 and kid.has_within(x, y, r):
                return True
        return False


def allocate_quotas(cultures, sub, n_new):
    """新国配额：按文化圈城数占比分 n_new 个名额（最大余数法；每圈至少 1）。"""
    circle_n = {}
    for cu in cultures:
        circle_n[cu["id"]] = sum(1 for c in sub if c["culture"] == cu["id"])
    total = sum(circle_n.values())
    raw = {cid: n_new * n / max(total, 1) for cid, n in circle_n.items()}
    quotas = {cid: max(1, int(math.floor(v))) for cid, v in raw.items()}
    rest = n_new - sum(quotas.values())
    for cid in sorted(raw, key=lambda c: (raw[c] % 1) - quotas[c] / max(n_new, 1),
                      reverse=True)[:max(rest, 0)]:
        quotas[cid] += 1
    # 防御：配额不得超过圈内城数的一半（保底每国 ≥2 城；小圈例外）
    for cid, n in circle_n.items():
        quotas[cid] = min(quotas[cid], max(1, n // 2))
    return quotas, circle_n


def pick_seeds(circle, want, min_sep, label):
    """圈内 population_score 降序 + 四叉树间距选都城种子；间距过筛不足时逐轮放宽。"""
    pool = sorted(circle, key=lambda c: (-c["pop"], c["label"]))
    for relax in range(4):
        sep = min_sep * (0.7 ** relax)
        qt = _SeedQuadtree(0.0, 0.0, float(SIZE), float(SIZE))
        picks = []
        for c in pool:
            if len(picks) >= want:
                break
            if not qt.has_within(c["sx"], c["sy"], sep / 4.0):
                qt.insert(c["sx"], c["sy"])
                picks.append(c)
        if len(picks) >= want:
            break
    for c in pool:  # 无视间距兜底补齐
        if len(picks) >= want:
            break
        if c not in picks:
            picks.append(c)
    if len(picks) < want:
        print("  [warn] culture %s 只选出 %d/%d 种子（城池不足）" % (label, len(picks), want))
    return picks


# ---------- Step 3：城图（扩张代价加山脊/河流罚） ----------

def build_graph(cities, elev, land, river, ridge_hi, xp):
    """城图：k 近邻 + 距离上限；边权 = dist × (1 + 文化摩擦 + 地形 + 贫瘠 + 跨海
    + k_ridge×山脊带占比 + k_river_cross×过河占比)。

    山脊带/河流是「边界应停驻的地方」：跨它的边更贵 → 国界自然落在脊线/河线上
    （FMG cellCost 高程带同思想，城市图版，§7.4-1）。返回 adj: idx -> [(nbr, w)]
    """
    n = len(cities)
    xs = np.array([c["ax"] for c in cities])
    ys = np.array([c["ay"] for c in cities])
    pts = np.stack([xs, ys], axis=1)
    d2 = ((pts[:, None, :] - pts[None, :, :]) ** 2).sum(axis=2)
    kn = xp["knear"]
    max_edge = xp["max_edge_px"]

    def line_stats(a, b):
        ts = np.linspace(0, 1, 24)
        lx = (a["sx"] + (b["sx"] - a["sx"]) * ts).astype(int).clip(0, SIZE - 1)
        ly = (a["sy"] + (b["sy"] - a["sy"]) * ts).astype(int).clip(0, SIZE - 1)
        h = elev[ly, lx]
        sea_ratio = 1.0 - land[ly, lx].mean()
        ridge_frac = float((h > ridge_hi).mean())
        river_frac = float(river[ly, lx].mean())
        return float(h.std()), float(sea_ratio), ridge_frac, river_frac

    adj = [[] for _ in range(n)]
    near = np.argsort(d2, axis=1)[:, 1:kn + 1]
    edges = set()
    for i in range(n):
        for j in near[i]:
            if i != j and d2[i, j] ** 0.5 <= max_edge:
                edges.add((min(i, j), max(i, j)))

    # 连通性兜底：桥接非最大连通分量（桥接边豁免距离过滤——P7 踩坑）
    bridged = _bridge_components(edges, d2, n)
    forced = bridged - edges
    edges |= bridged

    for i, j in edges:
        if i == j:
            continue
        a, b = cities[i], cities[j]
        dist = float(d2[i, j] ** 0.5)
        if dist > max_edge and (i, j) not in forced:
            continue
        terr, sea, ridge_f, river_f = line_stats(a, b)
        w = 1.0
        if a["culture"] != b["culture"]:
            w += xp["k_culture"]
        w += xp["k_terrain"] * terr
        w += xp["k_barren"] * (1.0 - (a["pop"] + b["pop"]) / 2.0)
        if sea > xp["sea_edge_ratio"]:
            w += xp["k_sea"]
        w += xp["k_ridge"] * ridge_f
        w += xp["k_river_cross"] * river_f
        w *= dist
        adj[i].append((j, w))
        adj[j].append((i, w))
    return adj


def _bridge_components(edges, d2, n):
    """迭代桥接：每个非最大分量取离其它分量最近的一对城连边，直到全连通。"""
    edges = set(edges)

    def components():
        adj = [[] for _ in range(n)]
        for i, j in edges:
            adj[i].append(j)
            adj[j].append(i)
        seen = [False] * n
        comps = []
        for i in range(n):
            if seen[i]:
                continue
            stack, comp = [i], []
            seen[i] = True
            while stack:
                u = stack.pop()
                comp.append(u)
                for v in adj[u]:
                    if not seen[v]:
                        seen[v] = True
                        stack.append(v)
            comps.append(comp)
        return comps

    for _ in range(32):
        comps = components()
        if len(comps) <= 1:
            break
        comps.sort(key=len, reverse=True)
        main = set(comps[0])
        rest = [c for c in comps[1:]]
        linked = False
        for comp in rest:
            best = None
            for i in comp:
                order = np.argsort(d2[i])
                for j in order[1:]:
                    j = int(j)
                    if j in main or any(j in c2 for c2 in rest if c2 is not comp):
                        if best is None or d2[i][j] < best[0]:
                            best = (d2[i][j], i, j)
                        break
            if best is not None:
                _, i, j = best
                edges.add((min(i, j), max(i, j)))
                linked = True
        if not linked:
            break
    return edges


# ---------- Step 4：多源 Dijkstra + expansionism + Zipf 面积反馈 ----------

def dijkstra_expand(capitals, adj, caps, n, wf, allow=None, eps=0.0):
    """多源 Dijkstra（§5.11 扩张，R7 扩展）。

    - capitals：[(sub_idx, sid, ordinal)]；ordinal 决定平局次序（确定性）
    - wf：sid -> 边权系数（= w_i 面积反馈 / expansionism，大国边际成本递增）
    - caps：每源容量硬上限（Zipf 目标 × cap_factor，防 runaway）
    - allow：城 → 可认领 state 集合（文化圈锚定：圈城只接受本圈政权）
    - eps：均衡系数 w×(1+eps×size)，链式竞速平滑（P7 踩坑：先手优势）
    返回 owner 数组（-1 未分）。
    """
    owner = [-1] * n
    counts = defaultdict(int)
    heap = []
    for sub_idx, sid, ordinal in capitals:
        heapq.heappush(heap, (0.0, ordinal, sid, sub_idx))
    while heap:
        cost, _, st, ci = heapq.heappop(heap)
        if owner[ci] != -1:
            continue
        if counts[st] >= caps[st]:
            continue
        if allow is not None and ci in allow and st not in allow[ci]:
            continue
        owner[ci] = st
        counts[st] += 1
        f = wf.get(st, 1.0)
        for nbr, w in adj[ci]:
            if owner[nbr] == -1:
                nw = cost + w * f * (1.0 + eps * counts[st])
                heapq.heappush(heap, (nw, ordinal_of(st), st, nbr))
    return owner


_ORDINAL = {}


def ordinal_of(sid):
    return _ORDINAL.get(sid, 0)


def normalize_enclaves(owner, capitals_idx, adj, city_region, sid_culture, region_legal, cfg):
    """多数邻域翻转消飞地（FMG normalize 同款）：非都城城若最大异国邻居数
    >= min_foreign 且大于本国邻居数，翻给该邻国；翻转目标须 region 合法
    （§5.11.1 锚点不可被翻转破坏）。"""
    min_foreign = cfg["min_foreign"]
    cap_set = {ci for ci, _, _ in capitals_idx}
    flipped_total = 0
    for _ in range(cfg["max_rounds"]):
        flipped = 0
        for k in range(len(owner)):
            if owner[k] == -1 or k in cap_set:
                continue
            cnt = Counter(owner[nbr] for nbr, _ in adj[k])
            own_n = cnt.pop(owner[k], 0)
            cnt.pop(-1, None)
            if not cnt:
                continue
            # 平局确定性：取 (邻居数, sid 字典序) 最大
            best_s, best_n = sorted(cnt.items(), key=lambda kv: (kv[1], kv[0]))[-1]
            if best_n < min_foreign:
                continue
            if best_n <= own_n:
                continue
            if city_region[k] not in region_legal.get(sid_culture.get(best_s, ""), set()):
                continue
            owner[k] = best_s
            flipped += 1
        flipped_total += flipped
        if flipped == 0:
            break
    return flipped_total


# ---------- Step 5：政权色（CONTENT_PALETTE 派生，R8 层3） ----------

def derive_color_pool(n_per_family):
    """7 族 × 族内明度/饱和档 → 72 个候选色。

    每个变体的色相/饱和直接取族内原型色（第 i 档用原型 i mod len），明度走全幅
    梯子 [0.30, 0.74]——同族相邻档 ΔL ≈ 0.04，配合贪心分配「同族只邻不同档」。
    """
    pool = []
    for fi, (_, proto) in enumerate(CONTENT_PALETTE_FAMILIES):
        n = n_per_family[fi] if fi < len(n_per_family) else 11
        ls = np.linspace(0.30, 0.74, n)
        for i in range(n):
            r0, g0, b0 = proto[i % len(proto)]
            h, li, si = colorsys.rgb_to_hls(r0, g0, b0)
            r, g, b = colorsys.hls_to_rgb(h, float(ls[i]), si)
            pool.append({
                "family": fi, "tier": i, "L": float(ls[i]),
                "rgb": (int(round(r * 255)), int(round(g * 255)), int(round(b * 255))),
            })
    return pool


def assign_state_colors(pool, states_by_size, state_neighbors, min_gap):
    """贪心图着色：按规模降序逐国取色；相邻国不同族优先，同族须明度档差 ≥ min_gap。

    返回 sid -> pool item；并统计冲突（同族且 ΔL < min_gap 的相邻国对数）。
    """
    assigned = {}
    fam_cycle = 0
    n_fam = len(CONTENT_PALETTE_FAMILIES)
    for ord_i, sid in enumerate(states_by_size):
        nbr_items = [assigned[s] for s in state_neighbors.get(sid, ()) if s in assigned]
        order = sorted(range(len(pool)),
                       key=lambda pi: ((pool[pi]["family"] + fam_cycle) % n_fam, pi))
        fam_cycle += 1
        best_pi, best_pen = None, None
        for pi in order:
            p = pool[pi]
            pen = 0
            for q in nbr_items:
                if q["family"] == p["family"]:
                    pen += 1 if abs(q["L"] - p["L"]) >= min_gap else 50
            if best_pen is None or pen < best_pen:
                best_pi, best_pen = pi, pen
        assigned[sid] = pool.pop(best_pi)
    conflicts = []
    for sid, nbrs in state_neighbors.items():
        for nb in nbrs:
            if nb in assigned and sid < nb:
                a, b = assigned[sid], assigned[nb]
                if a["family"] == b["family"] and abs(a["L"] - b["L"]) < min_gap:
                    conflicts.append((sid, nb))
    return assigned, conflicts


# ---------- 命名接口（name_source，创始人 2026-09-08 定） ----------

def load_or_init_name_table(path, params_path):
    table = None
    if os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as f:
                table = json.load(f)
        except (OSError, ValueError):
            table = None
    if not isinstance(table, dict) or not isinstance(table.get("names"), dict):
        table = {"_meta": {
            "status": "提案/待定",
            "note": "政权占位名表（键=state_id）。生成端缺项时按「文化圈前缀+编号」生成；"
                    "世界观会话定稿后直接改本表重跑 state_expand_lite.py 即可，不改代码。"
                    "本表全部条目为 AI 占位提案，非创始人确认设定。",
        }, "names": {}}
    return table


# ---------- 蒙版与贴图（ID mask，R9 过渡态：不再烘焙颜色贴图） ----------

def rasterize_id_mask(city_json, idx_by_label):
    """城市 polygon × 政权 lut_index → 8192 单通道 ID 蒙版（非城=0，城 holes 挖空）。

    l3_city.json 顶点为 8192 级 [y,x]（city_split_v2 产物），直接同级光栅化；
    fill+outline 同值封 1px 接缝。像素值 = state lut_index（1..80），0 = 海/无。
    """
    img = Image.new("L", (SIZE_FULL, SIZE_FULL), 0)
    dr = ImageDraw.Draw(img)
    for t in city_json["tiles"]:
        idx = idx_by_label.get(int(t["label"]), 0)
        if idx <= 0:
            continue
        for poly in t.get("polygons", []):
            if len(poly) < 3:
                continue
            dr.polygon([(p[1], p[0]) for p in poly], fill=idx, outline=idx)
        for hole in t.get("holes", []):
            if len(hole) < 3:
                continue
            dr.polygon([(p[1], p[0]) for p in hole], fill=0, outline=0)
    return img


def export_l2_id_masks(mask8, l2_packs_dir):
    """L2 政权 ID 裁切：8192 ID 蒙版按 context 窗口采样（order=0），空隙按
    邻区=CODE_NEIGHBOR / 湖泊=CODE_LAKE / 海洋=0 补底（运行时 LUT 查色）。"""
    arr = np.asarray(mask8)
    made = []
    for rid in sorted(d for d in os.listdir(l2_packs_dir) if d.startswith("region_")):
        info = json.load(open(
            os.path.join(OUTPUT_DIR, "l2_packs", rid, "info.json"), encoding="utf-8"))
        world = json.load(open(
            os.path.join(l2_packs_dir, rid, "l2_world.json"), encoding="utf-8"))
        bb = info["bbox_8192"]
        ctx_w, ctx_h = world["context_size"]
        tx, ty = world["tiles_offset"]
        gx = bb["x0"] - tx + np.arange(ctx_w)
        gy = bb["y0"] - ty + np.arange(ctx_h)
        GX, GY = np.meshgrid(gx, gy)
        sm = map_coordinates(arr, [GY, GX], order=0, mode="constant", cval=0)
        # 底层：邻区灰 + 湖泊（邻区先画、湖泊后画 = 湖泊优先；与旧管网底层等观感）
        base = Image.new("L", (ctx_w, ctx_h), 0)
        drw = ImageDraw.Draw(base)
        for nb in world.get("neighbors", []):
            for poly in nb.get("polygons", []):
                if len(poly) >= 3:
                    drw.polygon([(p[1], p[0]) for p in poly], fill=CODE_NEIGHBOR)
            for hole in nb.get("holes", []):
                if len(hole) >= 3:
                    drw.polygon([(p[1], p[0]) for p in hole], fill=0)
        for lake in world.get("lakes", []):
            if len(lake) >= 3:
                drw.polygon([(p[1], p[0]) for p in lake], fill=CODE_LAKE)
        out = np.where(sm > 0, sm, np.asarray(base))
        img = Image.fromarray(out.astype(np.uint8), "L")
        dst = os.path.join(l2_packs_dir, rid, "l2_political_id.png")
        img.save(dst)
        made.append((rid, dst, int((out > 0).sum())))
    return made


def fit_font(size):
    try:
        return ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", size)
    except OSError:
        return ImageFont.load_default()


def draw_legend(dr, entries, x0, y0, font):
    for i, (name, col) in enumerate(entries):
        y = y0 + i * 30
        dr.rectangle([x0, y + 4, x0 + 26, y + 22], fill=col + (255,),
                     outline=(20, 20, 24, 255))
        dr.text((x0 + 34, y + 2), name, font=font, fill=(235, 235, 240, 255))


# ---------- 主流程 ----------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--skip-preview", action="store_true")
    args = ap.parse_args()

    P = load_params()
    elev, river, biome, region, city_json, birth_json = load_inputs()
    cultures = P["cultures"]
    cu_by_id = {c["id"]: c for c in cultures}

    # 城数组：anchor/centroid/polygons 均为 8192 级（city_split_v2 产物）；
    # ax/ay 保留 8192（城图距离/蒙版），sx/sy = /4 后的 2048 级（栅格采样）
    cities = []
    for t in city_json["tiles"]:
        ax, ay = t["anchor"][0], t["anchor"][1]
        sx, sy = ax / 4.0, ay / 4.0
        cities.append({
            "label": int(t["label"]), "group": int(t["group"]),
            "ax": float(ax), "ay": float(ay), "sx": float(sx), "sy": float(sy),
            "level": int(t.get("level", 1)),
            "pop": float(t.get("population_score", 0.0)),
            "region": int(region[int(sy), int(sx)]),
            "culture": "",
        })
    birth_labels = set()
    birth_states = {}
    for s in birth_json["states"]:
        sid = s["state_id"]
        birth_states[sid] = {
            "name": s["name"], "capital": s["capital_settlement_id"],
            "culture": "plain", "alliance": None,
            "color": [int(c) for c in s["color"]], "is_city_state": True,
        }
    for tl in birth_json["tiles"]:
        birth_labels.add(int(tl["tile_id"].split("_")[1]))
        birth_states[tl["owner_state_id"]].setdefault("cities", []).append(
            tl["settlement"]["settlement_id"])
    n_new_target = int(P["n_states_total"]) - len(birth_states)
    print("输入：1040 城中出生 8 城邦 label=%s；目标政权 %d = %d 城邦 + %d 新国" % (
        sorted(birth_labels), P["n_states_total"], len(birth_states), n_new_target))

    # Step 1 文化圈
    seeds = build_culture_seeds(cities, region, biome, cultures)
    print("文化圈种子 %d 枚（%s）" % (len(seeds), ", ".join(
        "%s@(%d,%d)" % (cultures[s[2]]["id"], s[1], s[0]) for s in seeds)))
    cul_labels = culture_flood(seeds, elev, river, biome, region, cultures, P["culture_flood"])

    # 城文化采样 + 特殊文化覆盖（源流/火山 = 非占领文化标签）
    sp = P["special_cultures"]
    for c in cities:
        b = int(biome[int(c["sy"]), int(c["sx"])])
        if b == BI_SOURCE:
            c["culture"] = "source"
        elif b == BI_VOLCANIC:
            c["culture"] = "volcanic"
        else:
            cl = int(cul_labels[int(c["sy"]), int(c["sx"])]) - 1
            c["culture"] = cultures[cl]["id"] if cl >= 0 else ""
    region_culture = {}
    for cu in cultures:
        for r in cu["regions"]:
            region_culture.setdefault(r, cu["id"])
    # 无歧义锚点 region（只被一个 culture 的 regions 声明、且不是他圈 south_seed
    # 探入区）：城文化直接按 §5.11.1 锚点表定——种族-地域锚点不可被 flood 模糊边
    # 破坏（火焰=region_008、水=region_011、极地/霜峰/金穗/翠荫等同理）
    contested = set()
    for cu in cultures:
        contested.update(cu.get("south_seed_regions", []))
    region_unique = {}
    for r, cid in region_culture.items():
        owners = [cu["id"] for cu in cultures if r in cu["regions"]]
        if len(owners) == 1 and r not in contested:
            region_unique[r] = owners[0]
    for c in cities:
        if c["culture"] in ("source", "volcanic", ""):
            u = region_unique.get(c["region"], "")
            if u:
                c["culture"] = u
    no_cul = [c for c in cities if not c["culture"]]
    for c in no_cul:  # 兜底：优先 region 锚点表，再借最近有文化城
        c["culture"] = region_culture.get(c["region"], "")
        if not c["culture"]:
            best = min((o for o in cities if o["culture"]),
                       key=lambda o: (o["ax"] - c["ax"]) ** 2 + (o["ay"] - c["ay"]) ** 2)
            c["culture"] = best["culture"]
    stat = Counter(c["culture"] for c in cities)
    print("城文化分布：" + "  ".join("%s:%d" % kv for kv in sorted(stat.items())))

    # Step 2 城市种子：圈内配额 + population top-N + 四叉树间距
    states = {}          # state_id -> state dict
    capitals = []        # (sub_idx, sid, ordinal)
    culture_order = []   # (culture, -pop, sid) 兼容排序用途
    label_to_idx_all = {c["label"]: i for i, c in enumerate(cities)}

    expandable = [i for i, c in enumerate(cities) if c["label"] not in birth_labels]
    sub_pos = {g: k for k, g in enumerate(expandable)}
    sub = [cities[i] for i in expandable]

    quotas, circle_n = allocate_quotas(cultures, sub, n_new_target)
    print("新国配额（圈城数 → 配额）：" + "  ".join(
        "%s:%d→%d" % (cid, circle_n[cid], quotas[cid]) for cid in quotas))
    # 种子只能在「本圈 region 合法区」的城里选（fuzzy 带城不做都城——否则自己的
    # 政权认领不了自己的都城）；合法区 = regions ∪ south_seed 探入区
    region_legal = {cu["id"]: set(cu["regions"]) | set(cu.get("south_seed_regions", []))
                    for cu in cultures}
    for cu in cultures:
        cid = cu["id"]
        circle = [c for c in sub if c["culture"] == cid
                  and c["region"] in region_legal.get(cid, set())]
        if not circle or quotas.get(cid, 0) <= 0:
            print("  [warn] culture %s 无可分配城或配额为 0" % cid)
            continue
        dia = math.hypot(max(c["ax"] for c in circle) - min(c["ax"] for c in circle),
                         max(c["ay"] for c in circle) - min(c["ay"] for c in circle))
        want = quotas[cid]
        sep = max(P["capital_min_sep_px"], dia / math.sqrt(want) * 0.7)
        picks = pick_seeds(circle, want, sep, cid)
        for i, cp in enumerate(picks):
            sid = "state_r7_%s_%d" % (cid, i)
            states[sid] = {
                "name": "", "capital": sid_of(cp["label"]), "culture": cid,
                "culture_label": cu["label"], "alliance": None,
                "is_city_state": False, "name_status": "提案/待定",
            }
            culture_order.append((cid, -cp["pop"], sid))
            capitals.append((sub_pos[label_to_idx_all[cp["label"]]], sid, len(capitals)))
    # 出生 8 城邦（沿用既有 states）
    for sid, sd in birth_states.items():
        sd["n_cities"] = len(sd.pop("cities", []))
        sd["name_status"] = "确认"
        sd.setdefault("culture_label", "城邦")
        states[sid] = sd
    print("政权总数 %d（出生 %d 城邦 + 新国 %d）" % (
        len(states), len(birth_states), len(capitals)))

    # Step 3 城图（山脊/河流罚）
    land = biome > 0
    ridge_hi = float(np.quantile(elev[land], P["expansion"]["ridge_quantile"]))
    print("山脊带阈值 = %.3f（elev 陆地 p%.0f）" % (
        ridge_hi, P["expansion"]["ridge_quantile"] * 100))
    adj = build_graph(sub, elev, land, river, ridge_hi, P["expansion"])

    # Step 4 Zipf 目标 + expansionism + 面积反馈扩张
    zp = P["expansion"]["zipf"]
    exr = P["expansion"]["expansionism"]
    rng = random.Random(P["seed"] + 101)
    targets = {}
    for cu in cultures:
        cid = cu["id"]
        sids = [sid for (_, sid, _) in capitals if states[sid]["culture"] == cid]
        if not sids:
            continue
        sids.sort(key=lambda x: next(-c["pop"] for c in sub
                                     if sid_of(c["label"]) == states[x]["capital"]))
        n_c = circle_n[cid]
        raws = [(r + 1) ** (-zp["s"]) for r in range(len(sids))]
        tot = sum(raws)
        for sid, rw in zip(sids, raws):
            targets[sid] = max(3.0, n_c * rw / tot)
    caps = {sid: min(circle_n[states[sid]["culture"]],
                     max(4, math.ceil(targets[sid] * zp["cap_factor"])))
            for (_, sid, _) in capitals}
    expsm = {sid: rng.uniform(exr["min"], exr["max"]) for (_, sid, _) in capitals}
    for k, (_, sid, _) in enumerate(capitals):
        _ORDINAL[sid] = k

    # 政权必须落在对应文化圈内（§5.11.1）：越界只能来自末轮兜底（= 飞地被邻国
    # 实际控制），锚定自检单独计数
    special_or_blank = ("source", "volcanic", "")
    allow = {}
    for k, c in enumerate(sub):
        if c["culture"] in special_or_blank:
            # 无主留地：任周边新国 claim
            allow[k] = {sid for sid, sd in states.items() if not sd["is_city_state"]}
            continue
        ok = {sid for sid, sd in states.items()
              if not sd["is_city_state"] and c["region"] in region_legal.get(sd["culture"], set())}
        if ok:
            allow[k] = ok

    eps = P["expansion"]["balance_eps"]
    wf = {sid: 1.0 for (_, sid, _) in capitals}
    owner_sub = None
    for rnd in range(zp["rounds"] + 1):
        owner_sub = dijkstra_expand(capitals, adj, caps, len(sub), wf,
                                    allow=allow, eps=eps)
        if rnd == zp["rounds"]:
            break
        sizes = Counter(o for o in owner_sub if o != -1)
        for sid in wf:
            got = max(sizes.get(sid, 0), 1)
            wf[sid] = float(np.clip(wf[sid] * (got / targets[sid]) ** zp["eta"],
                                    0.3, 3.5))
    print("面积反馈 %d 轮：w_i ∈ [%.2f, %.2f]" % (
        zp["rounds"], min(wf.values()), max(wf.values())))

    # 兜底两轮：二轮无容量；三轮无过滤（圈飞地归图上最近源，语义 = 被邻国实际控制）
    if any(o == -1 for o in owner_sub):
        owner_sub = dijkstra_expand(
            capitals, adj, {sid: 1 << 30 for _, sid, _ in capitals}, len(sub),
            wf, allow=allow, eps=eps)
    if any(o == -1 for o in owner_sub):
        orphans = 0
        free = dijkstra_expand(
            capitals, adj, {sid: 1 << 30 for _, sid, _ in capitals}, len(sub),
            wf, allow=None, eps=eps)
        for k, o in enumerate(owner_sub):
            if o == -1:
                owner_sub[k] = free[k]
                orphans += 1
        print("  [info] 圈飞地兜底 %d 城（放开认领归图上最近源）" % orphans)

    # normalize：多数邻域翻转消飞地（翻转目标须 region 合法）
    sub_region = [c["region"] for c in sub]
    sid_culture = {sid: sd["culture"] for sid, sd in states.items() if not sd["is_city_state"]}
    n_flip = normalize_enclaves(owner_sub, capitals, adj, sub_region,
                                sid_culture, region_legal, P["normalize"])
    print("normalize 翻转 %d 城（消飞地）" % n_flip)

    # city_owners 全表
    city_owners = {}
    for i, c in enumerate(cities):
        if c["label"] in birth_labels:
            continue
        city_owners[sid_of(c["label"])] = owner_sub[sub_pos[i]]
    for tl in birth_json["tiles"]:
        city_owners[tl["settlement"]["settlement_id"]] = tl["owner_state_id"]

    # 文化圈锚定自检（§5.11.1 不能被破坏）
    legal_regions = {cu["id"]: set(cu["regions"]) for cu in cultures}
    anchor_bad = defaultdict(int)
    for i, c in enumerate(cities):
        if c["label"] in birth_labels:
            continue
        sid = owner_sub[sub_pos[i]]
        cu = states[sid]["culture"]
        if c["region"] not in legal_regions.get(cu, {c["region"]}):
            anchor_bad[cu] += 1
    if anchor_bad:
        print("  [warn] 文化圈 region 越界城：" + "  ".join(
            "%s:%d" % kv for kv in sorted(anchor_bad.items())))

    # Step 5 命名（name_source 接口；主名跟地盘走——圈内按城数降序）
    n_cnt_pre = Counter(city_owners.values())
    name_path = os.path.join(HERE, P["name_source"])
    name_table = load_or_init_name_table(name_path, PARAMS_PATH)
    for cu in cultures:
        cid = cu["id"]
        sids = [sid for (_, sid, _) in capitals if states[sid]["culture"] == cid]
        sids.sort(key=lambda x: -n_cnt_pre.get(x, 0))
        seed_names = list(cu.get("names", []))
        label = cu["label"]
        for i, sid in enumerate(sids):
            if sid in name_table["names"] and str(name_table["names"][sid]).strip():
                states[sid]["name"] = str(name_table["names"][sid])
            elif i < len(seed_names):
                states[sid]["name"] = seed_names[i]
                name_table["names"][sid] = seed_names[i]
            else:
                states[sid]["name"] = "%s·%02d" % (label, i + 1)
                name_table["names"][sid] = states[sid]["name"]

    # Step 6 色：CONTENT_PALETTE 派生 + 贪心图着色；出生 8 邦原色不动
    birth_colors = {sid: tuple(sd["color"]) for sid, sd in birth_states.items()}
    sizes_new = Counter(city_owners.values())
    new_states_by_size = sorted(
        [sid for (_, sid, _) in capitals], key=lambda s: (-sizes_new.get(s, 0), s))
    state_neighbors = defaultdict(set)
    for i in range(len(sub)):
        oi = owner_sub[i]
        for nbr, _w in adj[i]:
            oj = owner_sub[nbr]
            if oi != oj and oi != -1 and oj != -1:
                state_neighbors[oi].add(oj)
                state_neighbors[oj].add(oi)
    pool = derive_color_pool(P["colors"]["n_per_family"])
    if len(pool) < len(new_states_by_size):
        # 防御：n_states_total 改档超出 7 族配额时按紫族明度梯子补（正常 72 == 72）
        extra = derive_color_pool([0, 0, 0, 0, 0, 0, len(new_states_by_size) - len(pool)])
        pool += extra
    assigned, conflicts = assign_state_colors(
        pool, new_states_by_size, state_neighbors, P["colors"]["min_lightness_gap"])
    print("相邻国色冲突（同族且 ΔL<%.2f）：%d 对" % (
        P["colors"]["min_lightness_gap"], len(conflicts)))

    # lut_index：新国按规模降序 1..72，出生城邦 73..80
    for i, sid in enumerate(new_states_by_size):
        states[sid]["lut_index"] = i + 1
        states[sid]["color"] = list(assigned[sid]["rgb"])
    birth_sids = sorted(birth_states)
    for j, sid in enumerate(birth_sids):
        states[sid]["lut_index"] = len(new_states_by_size) + 1 + j
    for sid in states:
        states[sid]["n_cities"] = 0
    for sid in city_owners.values():
        states[sid]["n_cities"] += 1

    # 指标
    n_cnt = Counter(city_owners.values())
    print("\n=== 政权指标（%d 国）===" % len(states))
    for sid in sorted(states, key=lambda s: -n_cnt.get(s, 0)):
        sd = states[sid]
        print("  %-22s lut%-3d %-14s 城%3d  %s%s" % (
            sid, sd["lut_index"], sd["name"], n_cnt.get(sid, 0), sd["culture"],
            "  [城邦]" if sd["is_city_state"] else ""))
    sizes = sorted((n_cnt.get(s, 0) for s in new_states_by_size), reverse=True)
    ranks = np.arange(1, len(sizes) + 1)
    slope = float(np.polyfit(np.log(ranks), np.log(np.maximum(sizes, 1)), 1)[0])
    print("新国城数 max=%d min=%d mean=%.1f median=%d" % (
        sizes[0], sizes[-1], sum(sizes) / len(sizes),
        sorted(sizes)[len(sizes) // 2]))
    print("Zipf 检验：log(size)~log(rank) 斜率 = %.2f（目标 -%.2f，|斜率| 越大越悬殊）" % (
        slope, zp["s"]))
    print("总城=%d（应 1040）" % len(city_owners))

    if args.dry_run:
        print("\n--dry-run：不写任何文件，结束。")
        return

    # ---------- 产物 ----------
    owners_by_label = {}
    for t in city_json["tiles"]:
        sid = city_owners.get(sid_of(int(t["label"])))
        if sid:
            owners_by_label[int(t["label"])] = sid
    idx_by_label = {lb: states[sid]["lut_index"]
                    for lb, sid in owners_by_label.items()}
    # 域标签进 l3_city tiles（region 供运行时测试 §5.11.1 锚定；culture 供一致率检查）
    tile_culture = {c["label"]: c["culture"] for c in cities}
    tile_region = {c["label"]: c["region"] for c in cities}

    # political_data.json（真相源）
    pdata = {
        "meta": {
            "generated_by": "state_expand_lite.py",
            "params": "state_params.json",
            "n_states": len(states), "n_cities": len(city_owners),
            "n_states_total": P["n_states_total"],
            "color_source": "CONTENT_PALETTE 派生（stick_tokens.gd 20 色内容色板，"
                            "7 族 × 族内明度/饱和档；出生 8 城邦保留原色）",
            "names_status": "提案/待定（出生 8 城邦除外）；正式国名由世界观会话定稿后换 "
                            + P["name_source"] + " 重跑",
            "id_mask": {
                "l3": "l3_political_id_8192.png（单通道，像素值=lut_index 1..%d，0=海/无）"
                      % len(states),
                "l2": "l2_packs/*/l2_political_id.png（context 窗口裁切，同编码；"
                      "保留码 %d=湖泊 %d=邻区灰底）" % (CODE_LAKE, CODE_NEIGHBOR),
                "runtime": "PoliticalLut 查表上色（改 LUT 即全图换色，零重烘）",
            },
        },
        "states": states,
        "city_owners": city_owners,
    }
    with open(os.path.join(GAME_CFG, "political_data.json"), "w", encoding="utf-8") as f:
        json.dump(pdata, f, ensure_ascii=False, indent=1)

    # 命名词表回写（占位名全量落表，世界观会话后补正式名）
    with open(name_path, "w", encoding="utf-8") as f:
        json.dump(name_table, f, ensure_ascii=False, indent=1)

    # 注入 l3_city.json（tiles[].state_id/culture/region + 顶层 states）
    for t in city_json["tiles"]:
        lb = int(t["label"])
        t["state_id"] = owners_by_label.get(lb, "")
        t["culture"] = tile_culture.get(lb, "")
        t["region"] = tile_region.get(lb, 0)
    city_json["states"] = states
    with open(os.path.join(GAME_CFG, "l3_city.json"), "w", encoding="utf-8") as f:
        json.dump(city_json, f, ensure_ascii=False, indent=1)

    # 注入 l2 packs ×13（cities[].state_id + 顶层 states）
    l2_dir = os.path.join(GAME_CFG, "l2_packs")
    for rid in sorted(d for d in os.listdir(l2_dir) if d.startswith("region_")):
        p = os.path.join(l2_dir, rid, "l2_world.json")
        with open(p, encoding="utf-8") as f:
            w = json.load(f)
        for c in w.get("cities", []):
            c["state_id"] = city_owners.get(c["id"], "")
        w["states"] = states
        with open(p, "w", encoding="utf-8") as f:
            json.dump(w, f, ensure_ascii=False, indent=1)

    # ID mask（R9 过渡态：颜色贴图退役，只产政权 ID）
    mask8 = rasterize_id_mask(city_json, idx_by_label)
    mask8.save(os.path.join(GAME_CFG, "l3_political_id_8192.png"))
    made = export_l2_id_masks(mask8, l2_dir)
    for rid, _, npx in made:
        print("  L2 ID 裁切 %s：%d px" % (rid, npx))

    # 验收预览（political_v2_*）
    if not args.skip_preview:
        make_previews(P, city_json, states, owners_by_label, mask8, idx_by_label,
                      n_cnt, stat, cultures, ridge_hi)

    print("\n完成。json 已注入，记得：1) godot --headless --path stick-world --import"
          "（新 PNG） 2) 跑 l_world_bake.gd 刷 bin")


# ---------- 验收预览 ----------

def colorize_id(mask_l, palette_lut):
    arr = np.asarray(mask_l)
    rgb = np.asarray(palette_lut, dtype=np.uint8)[arr]
    return Image.fromarray(rgb, "RGB")


def make_previews(P, city_json, states, owners_by_label, mask8, idx_by_label,
                  n_cnt, stat, cultures, ridge_hi):
    font = fit_font(24)
    font_s = fit_font(20)
    new_states = [s for s, sd in states.items() if not sd["is_city_state"]]
    birth_states = [s for s, sd in states.items() if sd["is_city_state"]]

    # LUT：lut_index → RGB（0 = 海洋色）
    lut = [OCEAN] + [states[s]["color"] for s in sorted(
        new_states + birth_states, key=lambda s: states[s]["lut_index"])]
    while len(lut) < 256:
        lut.append((0, 0, 0))
    full = colorize_id(mask8, lut)
    l3_img = full.resize((SIZE, SIZE), Image.NEAREST)

    # 1) 全大陆 80 国总览（都城标注：前 20 国全标，其余只画点）
    prev = l3_img.copy()
    dr = ImageDraw.Draw(prev)
    cap_xy = {}
    for t in city_json["tiles"]:
        sid = t.get("state_id", "")
        if sid and states[sid]["capital"] == sid_of(int(t["label"])):
            cap_xy[sid] = (t["anchor"][0] / 4.0, t["anchor"][1] / 4.0)
    labeled = set(sorted(new_states, key=lambda s: -n_cnt.get(s, 0))[:20])
    for sid, (x, y) in cap_xy.items():
        big = states[sid]["capital"] and sid in labeled
        r = 6 if not states[sid]["is_city_state"] else 4
        dr.ellipse([x - r, y - r, x + r, y + r], fill=(255, 255, 255),
                   outline=(20, 20, 24), width=2)
        if big:
            dr.text((x + 10, y - 14), states[sid]["name"], font=font,
                    fill=(255, 255, 255), stroke_width=2, stroke_fill=(20, 20, 24))
    entries = [(("%s·%s" % (states[s].get("culture_label", ""), states[s]["name"]))
                + ("·城邦" if states[s]["is_city_state"] else "")
                + " %d城" % n_cnt.get(s, 0), tuple(states[s]["color"]))
               for s in sorted(states, key=lambda s: -n_cnt.get(s, 0))]
    canvas = Image.new("RGB", (SIZE + 460, SIZE), (14, 16, 22))
    canvas.paste(prev, (0, 0))
    dr2 = ImageDraw.Draw(canvas)
    dr2.text((SIZE + 20, 24), "政权版图（R7 80 国 · CONTENT_PALETTE 派生色）",
             font=font, fill=(240, 240, 245))
    draw_legend(dr2, entries, SIZE + 20, 70, font_s)
    canvas.save(os.path.join(OUTPUT_DIR, "political_v2_overview_2048.png"))

    # 2) 文化圈图（锚定抽查用）
    cu_colors = {}
    rng = random.Random(P["seed"] + 7)
    for cu in cultures:
        cu_colors[cu["id"]] = tuple(
            int(v * 255) for v in colorsys.hls_to_rgb(rng.random(), 0.5, 0.6))
    cu_colors["source"] = (95, 160, 195)
    cu_colors["volcanic"] = (150, 70, 60)
    cprev = Image.new("RGB", (SIZE, SIZE), OCEAN)
    drw = ImageDraw.Draw(cprev)
    for t in city_json["tiles"]:
        cu = t.get("culture", "")
        if cu not in cu_colors:
            continue
        for poly in t.get("polygons", []):
            if len(poly) >= 3:
                drw.polygon([(p[1] / 4.0, p[0] / 4.0) for p in poly], fill=cu_colors[cu])
    canvas2 = Image.new("RGB", (SIZE + 420, SIZE), (14, 16, 22))
    canvas2.paste(cprev, (0, 0))
    dr3 = ImageDraw.Draw(canvas2)
    dr3.text((SIZE + 20, 24), "文化圈（=城的 culture 字段，锚定抽查）",
             font=font, fill=(240, 240, 245))
    ent = [(cu["label"] + "（%s）" % cu["id"] + " %d城" % stat.get(cu["id"], 0),
            cu_colors[cu["id"]]) for cu in cultures]
    ent += [("清源（沿岸，非占领）", cu_colors["source"]),
            ("熔岩（蚀变区，非占领）", cu_colors["volcanic"])]
    draw_legend(dr3, ent, SIZE + 20, 70, font_s)
    canvas2.save(os.path.join(OUTPUT_DIR, "political_v2_culture.png"))

    # 3) 边界贴河/山脊特写 ×10
    make_border_closeups(P, city_json, states, mask8, lut, ridge_hi, n_cnt)

    print("预览：output/political_v2_overview_2048.png + political_v2_culture.png"
          " + political_v2_borders_10.png")


def make_border_closeups(P, city_json, states, mask8, lut, ridge_hi, n_cnt):
    """抽查 10 国边界：找「跨河/跨山脊」的国界边，出 2×5 特写拼图（贴河 5 + 贴脊 5）。"""
    import numpy as _np
    hm = _np.load(os.path.join(OUTPUT_DIR, "fractal_heightmap_8192.npy"))
    river8 = _np.asarray(Image.open(
        os.path.join(OUTPUT_DIR, "fractal_river_mask_8192.png")).convert("L")) > 127
    gy, gx = _np.gradient(hm.astype(_np.float32))
    shade = _np.clip(0.85 + (gy * 0.4 - gx * 0.4) * 1.2, 0.62, 1.18)

    arr = _np.asarray(mask8)
    # 国界样本点：ID 差分处，取两侧政权 id 均非 0 的成对点
    segs = []
    dh = arr[1:, :] != arr[:-1, :]
    ys, xs = _np.nonzero(dh)
    a, b = arr[ys, xs], arr[ys + 1, xs]
    keep = (a > 0) & (b > 0)
    segs.append((ys[keep] + 1, xs[keep], a[keep], b[keep]))
    dv = arr[:, 1:] != arr[:, :-1]
    ys, xs = _np.nonzero(dv)
    a, b = arr[ys, xs], arr[ys, xs + 1]
    keep = (a > 0) & (b > 0)
    segs.append((ys[keep], xs[keep] + 1, a[keep], b[keep]))
    bys = _np.concatenate([s[0] for s in segs])
    bxs = _np.concatenate([s[1] for s in segs])
    bas = _np.concatenate([s[2] for s in segs])
    bbs = _np.concatenate([s[3] for s in segs])
    if bys.size == 0:
        print("  [warn] 无边界像素可抽查")
        return
    river_hit = river8[bys, bxs]
    ridge_hit = (hm[bys, bxs] > ridge_hi) & (~river_hit)

    def pick_spread(hit, want, taken, min_dist=500):
        """命中点里挑 want 个：状态对不重复、互相距离 ≥ min_dist（空间散开）。"""
        idxs = _np.nonzero(hit)[0]
        if idxs.size == 0:
            return []
        # 按位置粗排序保证确定性，再贪心散开
        order = idxs[_np.lexsort((bxs[idxs], bys[idxs]))]
        step = max(1, order.size // 3000)
        out = []
        for k in order[::step]:
            y, x = int(bys[k]), int(bxs[k])
            pair = (min(int(bas[k]), int(bbs[k])), max(int(bas[k]), int(bbs[k])))
            if pair in seen_pair:
                continue
            if any((y - ty) ** 2 + (x - tx) ** 2 < min_dist * min_dist
                   for ty, tx in taken):
                continue
            taken.append((y, x))
            seen_pair.add(pair)
            out.append((y, x, int(bas[k]), int(bbs[k])))
            if len(out) >= want:
                break
        return out

    seen_pair = set()
    taken = []
    picks = [(0, y, x, a, b) for (y, x, a, b) in pick_spread(river_hit, 5, taken)]
    picks += [(1, y, x, a, b) for (y, x, a, b) in pick_spread(ridge_hit, 5, taken)]
    if len(picks) < 10:
        print("  [warn] 边界特写只选到 %d/10 个样本" % len(picks))

    full = colorize_id(mask8, lut)
    W = 512
    grid = Image.new("RGB", (W * 2, W * 5 + 40), (14, 16, 22))
    drg = ImageDraw.Draw(grid)
    drg.text((8, 8), "政权边界贴河（前 5）/ 贴山脊（后 5）特写 ×10 —— R7 验收抽查",
             font=fit_font(22), fill=(240, 240, 245))
    for i, (order, y, x, a, b) in enumerate(picks[:10]):
        x0 = max(0, min(SIZE_FULL - W, x - W // 2))
        y0 = max(0, min(SIZE_FULL - W, y - W // 2))
        crop = full.crop((x0, y0, x0 + W, y0 + W))
        ca = _np.asarray(crop).astype(_np.float32)
        ca *= shade[y0:y0 + W, x0:x0 + W, None]
        rl = river8[y0:y0 + W, x0:x0 + W]
        ca[rl] = ca[rl] * 0.45 + _np.array([50, 110, 170], dtype=_np.float32) * 0.55
        # 国界描黑（ID 差分）
        m = arr[y0:y0 + W, x0:x0 + W]
        bdfull = _np.zeros(m.shape, dtype=bool)
        bdfull[1:, :] |= m[1:, :] != m[:-1, :]
        bdfull[:, 1:] |= m[:, 1:] != m[:, :-1]
        ca[bdfull] *= 0.35
        crop = Image.fromarray(_np.clip(ca, 0, 255).astype(_np.uint8), "RGB")
        na, nb = states_by_lut(states, a), states_by_lut(states, b)
        cap = "%s × %s · %s" % (na, nb, "贴河" if order == 0 else "贴山脊")
        px, py = (i % 2) * W, 40 + (i // 2) * W
        grid.paste(crop, (px, py))
        drg.text((px + 8, py + 6), cap, font=fit_font(20), fill=(255, 255, 255),
                 stroke_width=2, stroke_fill=(10, 10, 12))
    grid.save(os.path.join(OUTPUT_DIR, "political_v2_borders_10.png"))


_LUT_TO_SID = {}


def states_by_lut(states, idx):
    for sid, sd in states.items():
        if sd["lut_index"] == idx:
            return sd["name"]
    return "?"


if __name__ == "__main__":
    main()
