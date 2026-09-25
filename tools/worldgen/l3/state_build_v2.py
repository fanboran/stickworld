"""世界重生成 v2 A4+A6：国家生成（state_build_v2.py）

算法提案 §A4（随机规模谱 + 自然合并）+ §A6（生成期加速历史）+ 构型命名（已圈选）：
  1. 都城抽取：都城适宜性 = 资源禀赋项 × 文化中心性（主导文化「场强质心」距离的
     exp 反比，温度口径同 fields_meta strength_temp 的消费式），四叉树最小间距
     自适应筛选 N_c 个都城；N_c 由规模谱均值反推（N_c ≈ 总城数 / 谱均值）
  2. 规模目标采样：每国 target ~ 截断对数正态（median/sigma/cap/floor 参数化），
     Σtarget = 总城数（尺度二分 + 最大余数整数化）；再做「局地可行池」钳制
     （target ≤ 都城 local_reach 内可达城数，缺额按余量摊回——贫瘠区州小、
     富庶区州大）。规模谱直方图是核心验收（必产 png + 全表进 meta）
  3. 加权合并：kNN 城图（分量桥接兜底孤岛；不选 Delaunay——长薄三角形边跨海
     跨山无语义），静态边权 = attack_cost 沿线积分 × (1 + k_culture×(1-城对
     文化相似度))；Dijkstra 松弛时乘每态因子 (1/expansionism_i) ×
     (1 + k_capital×距都城 px 测地衰减) × w_i 面积反馈（Balzer 式迭代到采样
     target）；normalize 消飞地（过渡带放宽——相似文化小飞地保留）
  4. A6 加速历史：K 轮随机事件（兼并战 / 继承解体 / 边疆易手），判据全部
     attack_cost × 文化相似度；兴衰史计数进 meta.history（「打出来的版图」
     可追溯）；K=0 退化纯分配
  5. 构型命名：每文化语素库自 culture_sources.morph_seed 派生（声母字库按语系
     共享、韵母/后缀按生计原型分档、荒野文化用中性库），政权名/城市名 =
     [方位前缀]+词根+后缀 合成，全局去重、长度约束；生成名全部「提案/待定」
  6. 色板沿用 palette.py（OKLCH 候选 + 城图邻接贪心 OKLab ΔE 分配；只调用不改）

输入：output/fields/ 的棒 1 场产物 + 棒 2 settlements_v2.json
输出：output/fields/political_data_v2.json（schema 对齐 political_data：
      states/city_owners/meta；culture 字段 = v2 文化源点序号 1..K（0=荒野）；
      城名表挂在 meta.city_names）
预览：output/fields/states_v2_preview_political_2048.png（政治图：城点着色 +
      最近城 Voronoi 视觉聚合国界 + 都城标记，叠宜居度淡底）+
      output/fields/states_v2_preview_spectrum.png（规模谱直方图）

用法：
  python state_build_v2.py [--dry-run] [--skip-preview]
    --dry-run      只跑算法与指标，不写任何文件
    --skip-preview 不输出预览 png
依赖棒 1/2 产物（fields_build / culture_build / settlement_build）；同 seed 逐位确定。
"""

import argparse
import heapq
import json
import math
import os
import sys
from collections import Counter, defaultdict

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fields_common as fc  # noqa: E402
import palette  # noqa: E402  （政权色唯一真相源，只调用）
import settlement_build as sb  # noqa: E402  （bilinear_at / load_fields_2048 复用）
from state_expand_lite import _SeedQuadtree, _bridge_components  # noqa: E402  （借用不改）

K = fc.SIZE_FULL // fc.SIZE  # 4：8192 坐标 → 2048 场网格缩比
FIELDS_DIR = fc.FIELDS_DIR
OUT_PATH = os.path.join(FIELDS_DIR, "political_data_v2.json")

OCEAN_RGB = (22, 33, 52)


def sid_of(label):
    """城 label（int）→ settlement id（P4 惯例三位补零，与 city_owners 键同体系）"""
    return "settlement_city_%03d" % int(label)


# ---------- 输入载入 ----------

def load_inputs():
    with open(os.path.join(FIELDS_DIR, "settlements_v2.json"), encoding="utf-8") as f:
        settle = json.load(f)["settlements"]
    with open(os.path.join(FIELDS_DIR, "culture_sources.json"), encoding="utf-8") as f:
        sources = json.load(f)["sources"]
    with open(os.path.join(FIELDS_DIR, "culture_similarity.json"), encoding="utf-8") as f:
        simj = json.load(f)
    suit, res, dom, mix, biome, eff_land = sb.load_fields_2048()
    strength = np.load(os.path.join(FIELDS_DIR, "culture_strength.npy"))[
        ::K, ::K].astype(np.float32)
    attack = np.load(os.path.join(FIELDS_DIR, "attack_cost.npy"), mmap_mode="r")
    return settle, sources, simj, suit, res, dom, mix, eff_land, strength, attack


def culture_centroids(dom, strength, eff_land):
    """每文化「场强质心」（2048 级强度加权质心 → 8192 级坐标；A4 文化中心性用）。"""
    n_cult = int(dom.max())
    yy, xx = np.indices(dom.shape, dtype=np.float64)
    cents = {}
    for c in range(1, n_cult + 1):
        w = np.where((dom == c) & eff_land, strength, 0.0).astype(np.float64)
        tw = float(w.sum())
        if tw <= 1e-9:
            cents[c] = None
            continue
        cents[c] = (float((w * xx).sum() / tw) * K, float((w * yy).sum() / tw) * K)
    return cents


def build_city_attrs(settle, suit, res, cents, cap_p, ssp):
    """城属性补全：都城适宜性 = 资源禀赋项 × 文化中心性。

    资源禀赋项复用 settlements 的 h 口径（h_w_suit×宜居 + h_w_res×
    tanh(资源加权和/gain_norm)，城点双线性采样）；文化中心性 =
    exp(-城到主导文化场强质心的欧氏距离 / central_tau_px)，dominant=0（荒野）
    中心性 = 0 不参选都城。节点序 = label 序（index = label-1）。
    """
    rw = ssp["resource_weights"]
    gn = float(ssp["gain_norm"])
    hws = float(ssp["h_w_suit"])
    hwr = float(ssp["h_w_res"])
    tau = float(cap_p["central_tau_px"])
    cities = []
    for c in sorted(settle, key=lambda x: int(x["label"])):
        s = sb.bilinear_at(suit, c["x"], c["y"])
        r = 0.0
        for rk, wk in rw.items():
            r += float(wk) * sb.bilinear_at(res[rk], c["x"], c["y"])
        r = math.tanh(r / gn)
        geo = hws * s + hwr * r
        cen = cents.get(int(c["dominant"]))
        if cen is None:
            cent = 0.0
        else:
            cent = math.exp(-math.hypot(c["x"] - cen[0], c["y"] - cen[1]) / tau)
        cities.append({
            "label": int(c["label"]),
            "sid": sid_of(c["label"]),
            "x": int(c["x"]), "y": int(c["y"]),
            "dom": int(c["dominant"]),
            "mix": float(c["mix"]),
            "pop": float(c["population_score"]),
            "geo": geo, "cap_suit": geo * cent,
        })
    return cities


# ---------- 规模谱（A4-2） ----------

def sample_spectrum(n_total, spec, rng):
    """截断对数正态采样 + Σtarget=总城数精确归一。

    ln target ~ N(ln median, sigma)，clamp [floor, cap]（下尾压成城邦、上尾压成
    cap 原子）；尺度 λ 二分使 Σclip(t·λ) = n_total，再最大余数整数化（cap 封顶
    者不再加）。返回 (n_c, targets, 观测统计)。
    """
    mu = math.log(float(spec["median"]))
    sigma = float(spec["sigma"])
    cap = int(spec["cap"])
    floor = int(spec["floor"])
    cf = float(cap)
    pool = np.clip(np.exp(rng.normal(mu, sigma, 20000)), floor, cf)
    mean = float(pool.mean())
    n_c = max(1, int(round(n_total / mean)))
    t = np.clip(np.exp(rng.normal(mu, sigma, n_c)), floor, cf)

    def total(lam):
        return float(np.clip(t * lam, floor, cf).sum())

    lo, hi = 1e-6, 1.0
    while total(hi) < n_total:
        hi *= 2.0
    for _ in range(80):
        mid = 0.5 * (lo + hi)
        if total(mid) < n_total:
            lo = mid
        else:
            hi = mid
    v = np.clip(t * hi, floor, cf)
    base = np.floor(v).astype(np.int64)
    rem = int(n_total - int(base.sum()))
    frac = v - base
    order = np.lexsort((np.arange(n_c), -frac))
    i = 0
    while rem > 0 and i < n_c * 4:
        k = int(order[i % n_c])
        if base[k] < cap:
            base[k] += 1
            rem -= 1
        i += 1
    obs = {
        "sampler_mean": round(mean, 4),
        "raw_hist": {int(k): int(vv) for k, vv in
                     zip(*np.unique(np.round(t).astype(int), return_counts=True))},
    }
    return n_c, [int(x) for x in base], obs


def _dijkstra_count_within(pxadj, src, reach):
    """px 测地距离 ≤ reach 的可达城数（截断 Dijkstra，含自身）。"""
    dist = {src: 0.0}
    heap = [(0.0, src)]
    cnt = 0
    while heap:
        d, u = heapq.heappop(heap)
        if d > dist.get(u, math.inf) + 1e-9:
            continue
        cnt += 1
        for v, w in pxadj[u]:
            nd = d + w
            if nd <= reach and nd < dist.get(v, math.inf) - 1e-9:
                dist[v] = nd
                heapq.heappush(heap, (nd, v))
    return cnt


def clamp_targets_to_pools(targets, cap_nodes, pxadj, spec, cap):
    """局地可行池钳制（reach 圆池，保谱形）：target ≤ 都城 local_reach 内可达城数。

    缺额按余量（min(pool, cap) − t）比例摊回；池总和不足时逐轮 ×1.3 放宽
    reach（确定性，必收敛）。圆池互相重叠、不作联合硬界——联合可行性由
    normalize 规模带天花板 + reclaim 带内流动收尾保证（保谱形优先）。
    """
    n_total = int(sum(targets))
    reach = float(spec["local_reach_px"])
    for _ in range(24):
        pools = np.array([_dijkstra_count_within(pxadj, nd, reach)
                          for nd in cap_nodes], dtype=np.int64)
        ub = np.minimum(pools, cap)
        t = np.minimum(np.array(targets, dtype=np.int64), ub)
        deficit = n_total - int(t.sum())
        if deficit <= 0:
            return [int(x) for x in t], pools, reach
        head = ub - t
        if int(head.sum()) < deficit:
            reach *= 1.3
            continue
        exact = deficit * head / head.sum()
        add = np.floor(exact).astype(np.int64)
        add = np.minimum(add, head)
        rem = deficit - int(add.sum())
        order = np.lexsort((np.arange(len(t)), -(exact - add)))
        i = 0
        while rem > 0 and i < len(t) * 4:
            k = int(order[i % len(t)])
            if add[k] < head[k]:
                add[k] += 1
                rem -= 1
            i += 1
        t = t + add
        if int(t.sum()) == n_total:
            return [int(x) for x in t], pools, reach
        reach *= 1.3
    raise RuntimeError("局地可行池钳制未收敛（reach=%s）" % reach)


# ---------- 都城抽取（A4-1） ----------

def pick_capitals(cities, n_c, cap_p):
    """都城适宜性降序 + 四叉树最小间距自适应放宽（state_expand_lite 同族）。"""
    pool = sorted(cities, key=lambda c: (-c["cap_suit"], c["label"]))
    sep0 = float(cap_p["min_sep_px"])
    picks = []
    for relax in range(int(cap_p["max_relax_rounds"]) + 1):
        sep = sep0 * (float(cap_p["sep_relax"]) ** relax)
        qt = _SeedQuadtree(0.0, 0.0, float(fc.SIZE_FULL), float(fc.SIZE_FULL))
        picks = []
        for c in pool:
            if len(picks) >= n_c:
                break
            if not qt.has_within(float(c["x"]), float(c["y"]), sep):
                qt.insert(float(c["x"]), float(c["y"]))
                picks.append(c)
        if len(picks) >= n_c:
            break
    if len(picks) < n_c:  # 兜底：无视间距补齐（间距已放到最松仍不足）
        got = {c["label"] for c in picks}
        for c in pool:
            if len(picks) >= n_c:
                break
            if c["label"] not in got:
                picks.append(c)
                got.add(c["label"])
    return picks[:n_c]


# ---------- 城图（A4-3） ----------

def pair_culture_factor(a, b, simM, k_culture):
    """城对文化因子 1 + k_culture×(1-相似度)；相似度 = sim(dom)×(1-mix)²。

    culture_similarity.json 消费口径：tile 级相似度 = 各自主导文化相似度 ×
    (1−各自混合度)。任一端 dominant=0（荒野）→ 因子取 1（文化项退化，
    纯地理归属——提案允许的孤立小邦形态）。
    """
    da, db = a["dom"], b["dom"]
    if da == 0 or db == 0:
        return 1.0
    sim = float(simM[da - 1][db - 1]) * (1.0 - a["mix"]) * (1.0 - b["mix"])
    sim = min(max(sim, 0.0), 1.0)
    return 1.0 + float(k_culture) * (1.0 - sim)


def build_graph(cities, attack, simM, gp, mgp):
    """kNN 城图 + 分量桥接；静态边权 = geo_cost × 文化因子。

    geo_cost = attack_cost 沿连线 line_samples 点采样均值 × 8192 级距离
    （fields_meta A4 消费口径；8192 mmap 直采保 2px 河流带不被降采样稀释）。
    返回 (adj 加权邻接, pxadj px 长度邻接, edges)。
    """
    n = len(cities)
    xs = np.array([c["x"] / K for c in cities])
    ys = np.array([c["y"] / K for c in cities])
    pts = np.stack([xs, ys], axis=1)
    d2 = ((pts[:, None, :] - pts[None, :, :]) ** 2).sum(axis=2)
    kn = int(gp["knear"])
    max_edge = float(gp["max_edge_px"])
    near = np.argsort(d2, axis=1)[:, 1:kn + 1]
    edges = set()
    for i in range(n):
        for j in near[i]:
            j = int(j)
            if i != j and d2[i, j] ** 0.5 <= max_edge:
                edges.add((min(i, j), max(i, j)))
    edges |= _bridge_components(edges, d2, n)  # 孤岛/半岛连通兜底（借用不改）

    nsa = int(gp["line_samples"])
    kc = float(mgp["k_culture"])
    adj = [[] for _ in range(n)]
    pxadj = [[] for _ in range(n)]
    for (i, j) in sorted(edges):
        a, b = cities[i], cities[j]
        dist8 = math.sqrt(float(d2[i, j])) * K
        ts = np.linspace(0.0, 1.0, nsa)
        lx = np.clip((a["x"] + (b["x"] - a["x"]) * ts).astype(int),
                     0, fc.SIZE_FULL - 1)
        ly = np.clip((a["y"] + (b["y"] - a["y"]) * ts).astype(int),
                     0, fc.SIZE_FULL - 1)
        cost = float(np.asarray(attack[ly, lx], dtype=np.float64).mean())
        w = cost * dist8 * pair_culture_factor(a, b, simM, kc)
        adj[i].append((j, w))
        adj[j].append((i, w))
        pxadj[i].append((j, dist8))
        pxadj[j].append((i, dist8))
    return adj, pxadj, edges


# ---------- 加权合并（A4-3/4） ----------

def geodesic_px(pxadj, src, n):
    """城图 px 测地距离（单源 Dijkstra，全图；capital 衰减用）。"""
    dist = [math.inf] * n
    dist[src] = 0.0
    heap = [(0.0, src)]
    while heap:
        d, u = heapq.heappop(heap)
        if d > dist[u] + 1e-9:
            continue
        for v, w in pxadj[u]:
            nd = d + w
            if nd < dist[v] - 1e-9:
                dist[v] = nd
                heapq.heappush(heap, (nd, v))
    return dist


def capital_decay(cap_nodes, pxadj, n, mgp):
    """每国都城衰减数组：1 + k_capital×min(1,(px 测地距/reach)²)。

    近都城 ≈ 1（不罚），reach 外饱和到 1+k_capital（软性 reach 上限）。
    不可达（inf）同饱和。返回 {sid: float32 数组}。
    """
    kcap = float(mgp["k_capital"])
    reach = float(mgp["capital_reach_px"])
    out = {}
    for sid, node in cap_nodes:
        d = np.asarray(geodesic_px(pxadj, node, n), dtype=np.float64)
        out[sid] = (1.0 + kcap * np.minimum(1.0, (d / reach) ** 2)).astype(np.float32)
    return out


def dijkstra_allocate(cap_nodes, sids, adj, caps, bf, dec, eps, n, targets):
    """多源竞速 Dijkstra（state_expand_lite 同族骨架 + 配额压力项）。

    bf = w_i 面积反馈 / expansionism（每态标量）；dec[sid] = 城级都城衰减数组；
    松弛代价额外乘 (1 + κ×已占城数/target)：到量即贵、缺口国自然续灌——
    规模配额在竞速内动态达成（κ = fill_pressure）。平局次序 = (cost, ordinal,
    node) 全确定。返回 (owner 数组, counts)。
    """
    owner = [-1] * n
    counts = {sid: 0 for sid in sids}
    heap = []
    for ordinal, ((_, node), sid) in enumerate(zip(cap_nodes, sids)):
        heapq.heappush(heap, (0.0, ordinal, node, sid))
    while heap:
        cost, ordinal, u, sid = heapq.heappop(heap)
        if owner[u] != -1:
            continue
        if counts[sid] >= caps[sid]:
            continue
        owner[u] = sid
        counts[sid] += 1
        darr = dec[sid]
        f = bf[sid] * (1.0 + eps * counts[sid] / max(targets[sid], 1))
        for v, w in adj[u]:
            if owner[v] == -1:
                heapq.heappush(heap,
                               (cost + w * f * float(darr[v]), ordinal, v, sid))
    return owner, counts


def allocate(cap_nodes, sids, targets, adj, pxadj, n, mgp, rng):
    """Balzer 式面积反馈迭代到采样 target + 无容量兜底（覆盖必满）。"""
    exr = mgp["expansionism"]
    eta = float(mgp["feedback"]["eta"])
    rounds = int(mgp["feedback"]["rounds"])
    wlo, whi = [float(x) for x in mgp["feedback"]["w_clip"]]
    capf = float(mgp["cap_factor"])
    kappa = float(mgp["fill_pressure"])
    exs = {sid: float(rng.uniform(exr["min"], exr["max"])) for sid in sids}
    caps = {sid: max(1, math.ceil(targets[sid] * capf)) for sid in sids}
    dec = capital_decay(cap_nodes, pxadj, n, mgp)
    wf = {sid: 1.0 for sid in sids}
    owner, counts = None, None
    for rnd in range(rounds + 1):
        bf = {sid: wf[sid] / exs[sid] for sid in sids}
        owner, counts = dijkstra_allocate(cap_nodes, sids, adj, caps, bf, dec,
                                          kappa, n, targets)
        if rnd == rounds:
            break
        for sid in sids:
            got = max(counts[sid], 1)
            wf[sid] = float(np.clip(wf[sid] * (got / targets[sid]) ** eta, wlo, whi))
    uncov = [i for i, o in enumerate(owner) if o == -1]
    if uncov:
        # 兜底（cap 感知）：未覆盖城逐轮并入「有房位」的邻接政权（最低边权）；
        # 邻接全满时归邻接中最空者（覆盖优先，极端病态 pocket 才会触达）
        remaining = set(uncov)
        while remaining:
            progressed = False
            for u in sorted(remaining):
                nbr = {owner[v] for v, _ in adj[u] if owner[v] != -1}
                if not nbr:
                    continue
                room = [b for b in nbr if counts[b] < caps[b]]
                tgt_b = room if room else sorted(
                    nbr, key=lambda b: (-(caps[b] - counts[b]), b))[:1]
                b = min(tgt_b, key=lambda x: (
                    min((w for v, w in adj[u] if owner[v] == x),
                        default=math.inf), counts[x], x))
                owner[u] = b
                counts[b] += 1
                remaining.discard(u)
                progressed = True
            if not progressed:
                break
        for u in sorted(remaining):  # 与城图不连通的孤点（桥接后不应存在）
            owner[u] = min(sids, key=lambda x: (counts[x], x))
            counts[owner[u]] += 1
    return owner, counts, exs, caps, wf, len(uncov)


# ---------- normalize（A4-5） ----------

def normalize_pass(owner, states, adj, cities, simM, nrm, cap, targets=None):
    """多数邻域翻转消飞地（FMG 同款 + 过渡带放宽 + cap/规模带感知 + 文化亲和）。

    非都城城：异国邻居按（数量降序, 文化亲和降序, sid）逐个考察，第一个满足
    「数量 ≥ 阈值、> 本国数、且还有房位」的接收。房位 = min(cap, 规模带天花板
    target+band+1)（targets 缺省 = A6 新生国/未带 target，天花板 = cap）——防
    normalize 把小目标国翻成大国。过渡带（mix ≥ mix_transition）城阈值提高到
    min_foreign_transition，且「相似文化飞地」保留：sim(城主导, 目标国文化) ≥
    sim_enclave_keep 且仍有本国邻居——文化过渡带允许少量跨相似文化飞地。
    """
    min_f = int(nrm["min_foreign"])
    min_ft = int(nrm["min_foreign_transition"])
    mix_tr = float(nrm["mix_transition"])
    sim_keep = float(nrm["sim_enclave_keep"])
    max_rounds = int(nrm["max_rounds"])

    def ceiling(sid):
        # 规模带天花板：target + band(max(2, 15%×target)) + 1（A6 新生国 = cap）
        if targets is None or sid not in targets:
            return cap
        t = targets[sid]
        return min(cap, int(t + max(2.0, 0.15 * t)))

    cap_nodes = set()
    city_state = {}
    state_culture = {}
    for sid, s in states.items():
        if s["extinct_round"] is not None:
            continue
        city_state[sid] = s["cities"]
        state_culture[sid] = s["culture"]
        cap_nodes.add(next(u for u in s["cities"]
                           if cities[u]["sid"] == s["capital"]))
    flipped_total = 0
    for _ in range(max_rounds):
        flipped = 0
        for u in range(len(owner)):
            sid = owner[u]
            if u in cap_nodes:
                continue
            cnt = Counter(owner[v] for v, _ in adj[u])
            own_n = cnt.pop(sid, 0)
            if not cnt:
                continue
            city = cities[u]
            thr = min_ft if city["mix"] >= mix_tr else min_f

            def affinity(bs):
                ds = state_culture.get(bs, 0)
                if city["dom"] == 0 or ds == 0:
                    return 0.5  # 荒野无文化身份 → 中性
                return float(simM[city["dom"] - 1][ds - 1])

            # 接收国资格 = 数量 ≥ 阈值且 > 本国数；选优 = 文化亲和最高优先
            # （错配城流向文化最近国）、其次邻居数（多数邻域语义）、sid 序
            ranked = sorted(
                ((bs, bn) for bs, bn in cnt.items()
                 if bn >= thr and bn > own_n),
                key=lambda kv: (-affinity(kv[0]), -kv[1], kv[0]))
            for best_s, _bn in ranked:
                if len(city_state[best_s]) >= ceiling(best_s):
                    continue  # 无房位，看次选
                if city["mix"] >= mix_tr and own_n >= 1:
                    dc, ds = city["dom"], state_culture.get(best_s, 0)
                    if dc > 0 and ds > 0 and \
                            float(simM[dc - 1][ds - 1]) >= sim_keep:
                        continue  # 相似文化飞地保留（过渡带放宽）
                city_state[sid].discard(u)
                city_state[best_s].add(u)
                owner[u] = best_s
                flipped += 1
                break
        flipped_total += flipped
        if flipped == 0:
            break
    return flipped_total


def reattribute_cultures(states, cities):
    """国文化归因：改按名下城主导文化的多数派（并列先都城主导、再小 id）。

    都城主导可能是城内少数派（都城落在文化过渡带/孤点时），按多数派归因才
    如实反映政权的人口文化构成；全部荒野城（dom=0）的国归为荒野邦（culture 0）。
    """
    for sid, s in states.items():
        if s["extinct_round"] is not None:
            continue
        cap_dom = next((cities[u]["dom"] for u in s["cities"]
                        if cities[u]["sid"] == s["capital"]), 0)
        cnt = Counter(cities[u]["dom"] for u in s["cities"]
                      if cities[u]["dom"] > 0)
        if not cnt:
            s["culture"] = 0
            continue
        s["culture"] = sorted(cnt.items(),
                              key=lambda kv: (-kv[1],
                                              0 if kv[0] == cap_dom else 1,
                                              kv[0]))[0][0]


def culture_rehome_pass(states, owner, adj, cities, simM, keep, cap, targets,
                        max_rounds=6):
    """文化归位：错配城（主导文化与国文化 sim < keep）迁往文化相同/近亲邻国。

    与 normalize 的多数邻域规则互补——normalize 消数量飞地，归位消文化错位；
    接收方 = 文化相同或近亲（sim ≥ keep）、有房位且接收后仍在规模带内
    （err < band，规模回收不因归位破功），取最低边权。可能留下 1 邻居的小
    飞地，但 normalize 的相似文化飞地保留规则不会再翻走。返回归位城数。
    """
    def band(t):
        return max(2.0, 0.15 * t)

    moved_total = 0
    for _ in range(max_rounds):
        moved = 0
        cap_nodes = {next(u for u in s["cities"]
                          if cities[u]["sid"] == s["capital"])
                     for sid, s in states.items()
                     if s["extinct_round"] is None}
        sizes = {sid: len(s["cities"]) for sid, s in states.items()
                 if s["extinct_round"] is None}
        for u in range(len(owner)):
            sid = owner[u]
            s = states.get(sid)
            if s is None or s["extinct_round"] is not None or u in cap_nodes:
                continue
            c = s["culture"]
            d = cities[u]["dom"]
            if c == 0 or d == 0 or float(simM[c - 1][d - 1]) >= keep:
                continue  # 非错配
            recv = sorted({owner[v] for v, _ in adj[u] if owner[v] != sid})
            pool = []
            for b in recv:
                if not (states[b]["culture"] > 0
                        and (states[b]["culture"] == d
                             or float(simM[states[b]["culture"] - 1][d - 1]) >= keep)
                        and sizes[b] < cap):
                    continue
                if b in targets and not (
                        sizes[b] - targets[b] < band(targets[b])):
                    continue  # 接收后超带（A6 新生国无 target，仅 cap 约束）
                pool.append(b)
            if pool:
                b = min(pool, key=lambda x: (
                    min((w for v, w in adj[u] if owner[v] == x),
                        default=math.inf), len(states[x]["cities"]), x))
                s["cities"].discard(u)
                states[b]["cities"].add(u)
                owner[u] = b
                sizes[sid] -= 1
                sizes[b] += 1
                moved += 1
        moved_total += moved
        if moved == 0:
            break
    return moved_total


def reclaim_pass(states, owner, adj, cities, simM, targets, cap, rounds=20,
                 per_round_give=6, relief_rounds=4, relief_give=20):
    """规模回收收尾（两相，方向性流动防震荡）。

    常规相：给出方 = err > 0（严格过剩；Σerr² 随每次转让下降，无乒乓），接收方
    = 接收后 err < band 且 < cap（缺口最大优先 → 文化亲和 → 边权最低）。
    救济相：给出方 = err > −band（带内有余量即可让）；接收方分两档——给出方
    超带/超 cap 时任意带内缺口（强制排空），否则只救「深缺口」（err < −band，
    直救地理围困的缺国）。候选城文化错配者优先送走、离都城远者次之。
    band(t) = max(2, 15%×t)。只走邻接边，不产生新飞地。返回转让城数。
    """
    def band(t):
        return max(2.0, 0.15 * t)

    def aff(dom, sid):
        c = states[sid]["culture"] if sid in states else 0
        if dom == 0 or c == 0:
            return 0.5
        return float(simM[dom - 1][c - 1])

    cap_node = {sid: next(u for u in s["cities"]
                          if cities[u]["sid"] == s["capital"])
                for sid, s in states.items() if s["extinct_round"] is None}

    def try_move(sid, sizes, relaxed):
        """一次过户。接收方：常规相 = 真缺口（err < 0）；救济相（给出方已超带/
        超 cap）= 接收后仍在带内（err < band）。优先缺口最大（水位差）、其次
        与城文化亲和最高、再次边权最低。候选城 = 非都城且有异国邻居，文化
        错配者优先送走、离都城远者次之。成功返回 True。"""
        s = states[sid]
        cu = s["culture"]
        cands = sorted(
            (u for u in s["cities"]
             if u != cap_node[sid]
             and any(owner[v] != sid for v, _ in adj[u])),
            key=lambda u: (
                0 if (cu > 0 and cities[u]["dom"] not in (0, cu)) else 1,
                -math.hypot(cities[u]["x"] - cities[cap_node[sid]]["x"],
                            cities[u]["y"] - cities[cap_node[sid]]["y"]),
                u))
        for u in cands:
            recv = sorted({owner[v] for v, _ in adj[u] if owner[v] != sid})
            if relaxed:
                pool = [b for b in recv
                        if sizes[b] - targets[b] < band(targets[b])
                        and sizes[b] < cap]
            else:
                pool = [b for b in recv
                        if sizes[b] < targets[b] and sizes[b] < cap]
            if pool:
                b = min(pool, key=lambda x: (
                    -(targets[x] - sizes[x]),
                    -aff(cities[u]["dom"], x),
                    min((w for v, w in adj[u] if owner[v] == x),
                        default=math.inf), x))
                s["cities"].discard(u)
                states[b]["cities"].add(u)
                owner[u] = b
                sizes[sid] -= 1
                sizes[b] += 1
                return True
        return False

    moved_total = 0

    def relay_move(sid, sizes):
        """跨国接力：BFS 找最近的真缺口国（err < 0 且 < cap），沿路径逐跳过户。

        中间国每跳「收一城、放一城」净尺寸不变（不产生新带违规），源头 -1、
        终点 +1——解决「邻接全在带缘、单跳无去处」的地理围困残差。
        限 20 跳（1 城邦不作中间节点）；某跳无可用城则放弃本次接力。成功返回 True。
        """
        adj_states = defaultdict(set)
        for u in range(len(owner)):
            a = owner[u]
            for v, _w in adj[u]:
                b = owner[v]
                if a != b:
                    adj_states[a].add(b)
                    adj_states[b].add(a)
        parent = {sid: None}
        queue = [sid]
        tgt = None
        while queue and tgt is None:
            s = queue.pop(0)
            for nb in sorted(adj_states.get(s, ())):
                if nb in parent:
                    continue
                parent[nb] = s
                if sizes[nb] < targets[nb] and sizes[nb] < cap:
                    tgt = nb
                    break
                if sizes[nb] >= 2:  # 1 城邦无法转手（都城不可动），不作中间节点
                    queue.append(nb)
        if tgt is None:
            return False
        path = [tgt]
        while parent[path[-1]] is not None:
            path.append(parent[path[-1]])
        path.reverse()
        if len(path) > 21:  # 源头 + 20 跳上限
            return False
        # 逆序跳（先放后收）：中间国先 -1 再由上一跳回补，瞬时尺寸不升——
        # cap 不会被中间态击穿；终点国为真缺口（< target），+1 仍在带内
        for i in range(len(path) - 2, -1, -1):
            a, b = path[i], path[i + 1]
            if i > 0 and sizes[a] <= 1:
                return False  # 中间国放空了（防御）
            cands = sorted(
                (u for u in states[a]["cities"]
                 if cities[u]["sid"] != states[a]["capital"]
                 and any(owner[v] == b for v, _ in adj[u])),
                key=lambda u: (
                    min((w for v, w in adj[u] if owner[v] == b),
                        default=math.inf), u))
            if not cands:
                return False
            u = cands[0]
            states[a]["cities"].discard(u)
            states[b]["cities"].add(u)
            owner[u] = b
            sizes[a] -= 1
            sizes[b] += 1
        return True

    def run(phase_givers, give_cap, over_for):
        nonlocal moved_total
        for _ in range(rounds if over_for == "regular" else relief_rounds):
            moved = 0
            sizes = {sid: len(states[sid]["cities"]) for sid in cap_node}
            givers = phase_givers(sizes)
            givers.sort(key=lambda s: (-(sizes[s] - targets[s]), s))
            for sid in givers:
                n = 0
                while n < give_cap:
                    err = sizes[sid] - targets[sid]
                    if over_for == "regular":
                        if not err > 0:
                            break
                        if try_move(sid, sizes, relaxed=False):
                            n += 1
                            continue
                        if relay_move(sid, sizes):
                            n += 1
                            continue
                        break
                    else:
                        if not (err > band(targets[sid]) or sizes[sid] > cap):
                            break
                        if try_move(sid, sizes, relaxed=True):
                            n += 1
                            continue
                        if relay_move(sid, sizes):
                            n += 1
                            continue
                        break
                moved += n
            moved_total += moved
            if moved == 0:
                break

    run(lambda sizes: [sid for sid in sizes
                       if sizes[sid] - targets[sid] > 0],
        per_round_give, "regular")
    run(lambda sizes: [sid for sid in sizes
                       if sizes[sid] - targets[sid] > -band(targets[sid])
                       or sizes[sid] > cap],
        relief_give, "relief")
    return moved_total


# ---------- A6 加速历史 ----------

def _contact_min(nodes_a, owner, adj, sid_b):
    """A 国诸城与 B 国的最低静态接触边权（进攻软度；找不到 = inf）。"""
    best = math.inf
    for u in nodes_a:
        for v, w in adj[u]:
            if owner[v] == sid_b and w < best:
                best = w
    return best


def _pick_weighted(cands, weights, rng):
    """按权重抽签（累计和 + 单次二分；确定性）。"""
    tot = float(sum(weights))
    x = float(rng.random()) * tot
    acc = 0.0
    for c, w in zip(cands, weights):
        acc += float(w)
        if x <= acc:
            return c
    return cands[-1]


def run_history(states, owner, adj, cities, simM, hp, rng, cap, n, mix_min_arr):
    """A6 K 轮虚拟历史：兼并战 / 继承解体 / 边疆易手。

    判据全部走 attack_cost×文化相似度（= 静态边权 w）。事件计数与逐国兴衰史
    直接记在 states 条目上（meta.history 汇总）。返回事件计数 dict。
    """
    rounds = int(hp["rounds"])
    p_annex = float(hp["p_annex"])
    att_min = int(hp["annex_min_attacker"])
    att_sim = float(hp.get("annex_sim_min", 0.0))
    k_gap = float(hp["k_gap"])
    p_max = float(hp["annex_p_max"])
    p_col = float(hp["p_collapse"])
    col_over = int(hp["collapse_over"])
    p_indep = float(hp["p_indep"])
    p_flip = float(hp["p_flip"])
    flip_mix = float(hp["flip_mix_min"])
    next_idx = len(states)
    counters = {"annexations": 0, "collapses": 0, "border_flips": 0,
                "born": 0, "annex_skipped_cap": 0}

    def new_state(node, rnd):
        nonlocal next_idx
        sid = "state_v2_%03d" % next_idx
        next_idx += 1
        states[sid] = {
            "capital": cities[node]["sid"], "culture": cities[node]["dom"],
            "cities": {node}, "born_round": rnd, "annexed": 0,
            "flips_in": 0, "flips_out": 0, "collapsed": False,
            "extinct_round": None, "cause": None, "target": None,
        }
        owner[node] = sid
        counters["born"] += 1
        return sid

    def annex(att, tgt, rnd):
        cs = states[att]["cities"] | states[tgt]["cities"]
        for u in states[tgt]["cities"]:
            owner[u] = att
        states[att]["cities"] = cs
        states[att]["annexed"] += 1
        states[tgt]["extinct_round"] = rnd
        states[tgt]["cause"] = "annexed_by:%s" % att
        counters["annexations"] += 1

    def collapse(sid, rnd):
        s = states[sid]
        cap_node = next(n for n in s["cities"]
                        if cities[n]["sid"] == s["capital"])
        s["collapsed"] = True
        for u in sorted(s["cities"] - {cap_node}):
            s["cities"].discard(u)  # 先出账再落新主（独立/并入都一样）
            if rng.random() < p_indep:
                new_state(u, rnd)
                continue
            hosts = sorted({owner[v] for v, _ in adj[u]
                            if owner[v] != sid and owner[v] is not None
                            and len(states[owner[v]]["cities"]) < cap})
            if hosts:
                d = cities[u]["dom"]

                def host_aff(b):
                    cb = states[b]["culture"]
                    if d == 0 or cb == 0:
                        return 0.5
                    return float(simM[cb - 1][d - 1])

                best = min(hosts, key=lambda b: (
                    -host_aff(b),  # 文化近亲优先接收
                    min((w for v, w in adj[u] if owner[v] == b),
                        default=math.inf),
                    len(states[b]["cities"]), b))
                states[best]["cities"].add(u)
                owner[u] = best
            else:
                new_state(u, rnd)  # 无邻可并 → 独立成邦
        counters["collapses"] += 1

    def border_flip(rnd):
        cand = []
        for u in range(n):
            sid = owner[u]
            s = states.get(sid)
            if s is None or cities[u]["sid"] == s["capital"]:
                continue
            if mix_min_arr[u] < flip_mix:
                continue
            if any(owner[v] != sid for v, _ in adj[u]):
                cand.append(u)
        if not cand:
            return
        u = cand[int(rng.integers(0, len(cand)))]
        sid = owner[u]
        recv = {}
        for v, w in adj[u]:
            b = owner[v]
            if b != sid and len(states[b]["cities"]) < cap:
                recv.setdefault(b, []).append(w)
        if not recv:
            return
        best_s, ws = sorted(
            ((b, min(ww)) for b, ww in recv.items()),
            key=lambda t: (t[1], len(states[t[0]]["cities"]), t[0]))[0]
        states[sid]["cities"].discard(u)
        states[best_s]["cities"].add(u)
        states[sid]["flips_out"] += 1
        states[best_s]["flips_in"] += 1
        owner[u] = best_s
        if not states[sid]["cities"]:  # 防御（都城不参选，正常到不了）
            states[sid]["extinct_round"] = rnd
            states[sid]["cause"] = "flip_drained"
        counters["border_flips"] += 1

    for rnd in range(1, rounds + 1):
        # ---- 兼并战：强国按进攻成本选邻接弱邻吞并（概率随强弱差增大） ----
        sizes = {sid: len(s["cities"]) for sid, s in states.items()
                 if s["extinct_round"] is None}
        cands = sorted(sid for sid, sz in sizes.items() if sz >= att_min)
        if cands:
            att = _pick_weighted(cands, [sizes[c] for c in cands], rng)
            nbr = sorted({owner[v] for u in states[att]["cities"]
                          for v, _ in adj[u]} - {att})
            weaker = [b for b in nbr if len(states[b]["cities"])
                      < len(states[att]["cities"])]
            if weaker:
                tgt = min(weaker, key=lambda b: (
                    _contact_min(states[att]["cities"], owner, adj, b),
                    len(states[b]["cities"]), b))
                ca, ct = states[att]["culture"], states[tgt]["culture"]
                compat = (ca == 0 or ct == 0
                          or float(simM[ca - 1][ct - 1]) >= att_sim)
                gap = (len(states[att]["cities"])
                       - len(states[tgt]["cities"])) / max(
                           len(states[att]["cities"]), 1)
                p = min(p_max, p_annex * (1.0 + k_gap * gap))
                if compat and rng.random() < p:
                    if (len(states[att]["cities"])
                            + len(states[tgt]["cities"])) <= cap:
                        annex(att, tgt, rnd)
                    else:
                        counters["annex_skipped_cap"] += 1
        # ---- 继承解体：城数超阈值的国概率碎一地 ----
        for sid in sorted(list(states.keys())):
            s = states[sid]
            if s["extinct_round"] is not None:
                continue
            if len(s["cities"]) > col_over and rng.random() < p_col:
                collapse(sid, rnd)
        # ---- 边疆易手：模糊带单城重归属 ----
        if rng.random() < p_flip:
            border_flip(rnd)
    return counters


# ---------- 构型命名 ----------

# 语素库（构造型命名）：声母字库按语系共享（同语系听感相近），韵母/后缀按
# 生计原型分档（农耕柔和平稳 / 游牧浑厚开口 / 渔猎清亮流音 / 商贸响亮塞擦），
# 荒野文化（dominant=0）用中性库。全部为 AI 生成提案（提案/待定）。
ONSET_POOLS = [
    "巴柏班包北宾波布奔比",
    "车川昌成充初垂淳茶池",
    "达丹德登迪丁东斗督多",
    "法樊飞芬丰弗浮福方放",
    "戈格古关广圭哈海罕侯",
    "赫黑恒洪胡华桓辉霍忽",
    "迦嘉坚江介金景鸠居菊",
    "卡拉康科枯宽奎柯寇坤",
]
RHYME_POOLS = {
    "农耕": "安奥本禾和平宁田泰庄康延",
    "游牧": "阿罕浑尔鲁烈原苍野乌奇图",
    "渔猎": "伊洛里泠汀泽屿湾洋澜溪浦",
    "商贸": "拉来马纳诺基塔德隆贝苏塞",
    "荒野": "崖岩谷丘荒川石林泉坡岗",
}
STATE_SUFFIX = {
    "农耕": "盟邦社仓", "游牧": "部落帐盟", "渔猎": "屿湾泽联",
    "商贸": "埠市行盟", "荒野": "邦社团",
}
CITY_SUFFIX = {
    "农耕": "屯庄集镇村", "游牧": "帐泉圈场营", "渔猎": "浦汀澳湾坞",
    "商贸": "埠集市栈店", "荒野": "寨屯点营",
}
PREFIXES = "大新上北南东西"


def build_morphemes(sources, nmp, base_seed):
    """每文化语素库：声母按语系共享（语系 rng），韵母/后缀按生计；荒野 = 中性库。

    语素 rng = culture_sources.morph_seed（A2 留的挂载点，逐位确定）。
    """
    fam_rng = np.random.default_rng(int(base_seed) + 777)
    fam_onsets = {}
    for fam in sorted({s["family"] for s in sources}):
        fam_onsets[fam] = ONSET_POOLS[int(fam_rng.integers(0, len(ONSET_POOLS)))]
    mor = {}
    for i, s in enumerate(sources):
        liv = s["livelihood"]
        rng = np.random.default_rng(int(s["morph_seed"]))
        mor[i + 1] = {
            "onsets": fam_onsets[s["family"]],
            "rhymes": RHYME_POOLS[liv],
            "state_suffix": STATE_SUFFIX[liv],
            "city_suffix": CITY_SUFFIX[liv],
            "rng": rng,
        }
    wrng = np.random.default_rng(int(base_seed) + 888)
    mor[0] = {
        "onsets": RHYME_POOLS["荒野"], "rhymes": RHYME_POOLS["荒野"],
        "state_suffix": STATE_SUFFIX["荒野"], "city_suffix": CITY_SUFFIX["荒野"],
        "rng": wrng,
    }
    return mor


def _draw_root(m, nmp):
    r = m["rng"]
    w = (m["onsets"][int(r.integers(0, len(m["onsets"])))]
         + m["rhymes"][int(r.integers(0, len(m["rhymes"])))])
    if r.random() < float(nmp["root_second_syll_p"]):
        w += m["rhymes"][int(r.integers(0, len(m["rhymes"])))]
    return w


def _gen_name(m, nmp, used, kind, fb):
    """构词合成 + 全局去重 + 长度约束；兜底加序号后缀（确定性）。"""
    p_prefix = float(nmp["prefix_p"])
    p_csuf = float(nmp["city_suffix_p"])
    for _ in range(64):
        w = _draw_root(m, nmp)
        if kind == "state":
            if m["rng"].random() < p_prefix:
                w = PREFIXES[int(m["rng"].integers(0, len(PREFIXES)))] + w
            w += m["state_suffix"][int(m["rng"].integers(0, len(m["state_suffix"])))]
            ok = 3 <= len(w) <= 5
        else:
            if m["rng"].random() < p_csuf:
                w += m["city_suffix"][int(m["rng"].integers(0, len(m["city_suffix"])))]
            ok = 2 <= len(w) <= 4
        if ok and w not in used:
            used.add(w)
            return w
    fb[0] += 1
    w = _draw_root(m, nmp) + m["state_suffix" if kind == "state" else "city_suffix"][0] \
        + str(fb[0])
    used.add(w)
    return w


def name_all(states_out, cities, sources, nmp, base_seed):
    """政权名（sid 序）+ 城名（label 序）；返回 (城名表, 每文化样例)。"""
    mor = build_morphemes(sources, nmp, base_seed)
    used = set()
    fb = [0]
    samples = defaultdict(list)
    for sid in sorted(states_out):
        s = states_out[sid]
        m = mor.get(s["culture"], mor[0])
        s["name"] = _gen_name(m, nmp, used, "state", fb)
        key = str(s["culture"])  # 字符串键：与 JSON 落盘后的键型一致
        if len(samples[key]) < 3:
            samples[key].append(s["name"])
    city_names = {}
    for c in cities:  # label 序
        m = mor.get(c["dom"], mor[0])
        city_names[c["sid"]] = _gen_name(m, nmp, used, "city", fb)
    return city_names, dict(samples)


# ---------- 色板 / lut（palette.py 只调用） ----------

def state_adjacency(owner, edges):
    """城图跨政权接触边 → 政权邻接（贪心着色输入）。"""
    nbrs = defaultdict(set)
    for (i, j) in sorted(edges):
        a, b = owner[i], owner[j]
        if a != b:
            nbrs[a].add(b)
            nbrs[b].add(a)
    return nbrs


def assign_colors(states_out, owner, edges, colors_spec):
    """OKLCH 候选 + 城图邻接贪心 OKLab ΔE 分配（palette 唯一真相源）；
    lut_index 按终局规模降序 1..N（并列按 sid 字典序）。states_out 只含终局存续国。"""
    live = list(states_out)
    sizes = {sid: states_out[sid]["n_cities"] for sid in live}
    order = sorted(live, key=lambda s: (-sizes[s], s))
    nbrs = state_adjacency(owner, edges)
    nbrs = {sid: sorted(v) for sid, v in nbrs.items()}
    candidates = palette.build_candidates(colors_spec)
    assigned, conflicts = palette.assign_colors(
        candidates, order, nbrs, float(colors_spec["min_delta_e"]))
    for rank, sid in enumerate(order):
        states_out[sid]["lut_index"] = rank + 1
        states_out[sid]["color"] = list(assigned[sid]["rgb"])
    return len(conflicts)


# ---------- 产物组装 ----------

def homogeneity_stats(states, states_out, cities, simM, mix_tr, sim_keep):
    """文化同质度：各国名下城主导文化与国文化一致率（近亲文化放宽口径）。

    一致 = 城主导 == 国文化，或城为荒野（dominant=0，无文化身份不算冲突），
    或近亲文化放宽（sim(城主导, 国文化) ≥ sim_keep——「跨相似文化」不算冲突，
    与 normalize 的相似文化飞地保留同口径）。国文化 = 0（荒野邦）无法定义
    一致率，单独计数不参与阈值。cities 集合读 states 账本，一致率写回
    states_out[sid]["culture_agreement"]。
    """
    rep = {"cultured_states": 0, "wild_states": 0, "wild_cities": 0,
           "min_rate": 1.0, "min_state": None, "below": []}
    for sid, s in states.items():
        if s["extinct_round"] is not None:
            continue
        c = s["culture"]
        nodes = sorted(s["cities"])
        if c == 0:
            rep["wild_states"] += 1
            rep["wild_cities"] += len(nodes)
            continue
        rep["cultured_states"] += 1
        ok = 0
        for u in nodes:
            d = cities[u]["dom"]
            if d == c or d == 0 or float(simM[c - 1][d - 1]) >= sim_keep:
                ok += 1
        rate = ok / max(len(nodes), 1)
        states_out[sid]["culture_agreement"] = round(rate, 4)
        if rate < rep["min_rate"]:
            rep["min_rate"] = rate
            rep["min_state"] = sid
        if rate < 0.8:
            rep["below"].append((sid, round(rate, 3), len(nodes)))
    return rep


def build(P, dry_run=False, skip_preview=False):
    """全流程：返回 product dict（meta/states/city_owners），供主函数落盘、
    供 state_check_v2.py 做同 seed 逐位对比。"""
    sp = P["fields_v2"]["states_v2"]
    ssp = P["fields_v2"]["settlements"]
    rng = np.random.default_rng(int(sp["seed"]))

    print("[1/8] 读棒 1 场产物 + 棒 2 聚落集...", flush=True)
    (settle, sources, simj, suit, res, dom, mix, eff_land,
     strength, attack) = load_inputs()
    race_by_culture = {src["id"]: src.get("race") for src in sources}
    simM = simj["matrix"]
    n_total = len(settle)

    print("[2/8] 都城适宜性（资源禀赋×文化中心性）...", flush=True)
    cents = culture_centroids(dom, strength, eff_land)
    cities = build_city_attrs(settle, suit, res, cents, sp["capital"], ssp)

    print("[3/8] 规模谱采样（截断对数正态）...", flush=True)
    n_c, targets, spec_obs = sample_spectrum(n_total, sp["spectrum"], rng)
    print("  谱均值 %.2f → 都城数 N_c = %d" % (spec_obs["sampler_mean"], n_c))

    cap_picks = pick_capitals(cities, n_c, sp["capital"])
    cap_nodes = [c["label"] - 1 for c in cap_picks]

    print("[4/8] 城图（kNN + 桥接 + attack_cost 沿线积分）...", flush=True)
    adj, pxadj, edges = build_graph(cities, attack, simM, sp["graph"],
                                    sp["merge"])

    print("[5/8] 局地可行池钳制 + 加权合并（Balzer 反馈）...", flush=True)
    targets, pools, reach_used = clamp_targets_to_pools(
        targets, cap_nodes, pxadj, sp["spectrum"], int(sp["spectrum"]["cap"]))
    sids = ["state_v2_%03d" % k for k in range(n_c)]
    tgt_map = {sid: t for sid, t in zip(sids, targets)}
    owner, counts, exs, caps, wf, n_uncov = allocate(
        [(sid, nd) for sid, nd in zip(sids, cap_nodes)], sids, tgt_map,
        adj, pxadj, n_total, sp["merge"], rng)
    got_pre = {sid: int(counts[sid]) for sid in sids}

    def dev_stats(snapshot):
        bad = [sid for sid, a in snapshot.items()
               if abs(a["got"] - a["target"]) > max(2.0, 0.15 * a["target"])]
        errs = [abs(a["got"] - a["target"]) for a in snapshot.values()]
        return bad, (max(errs) if errs else 0.0), \
            (sum(errs) / max(len(errs), 1))

    bad_pre, err_max_pre, err_avg_pre = dev_stats(
        {sid: {"target": int(tgt_map[sid]), "got": got_pre[sid]} for sid in sids})
    print("  未覆盖城 %d；分配后偏差带外 %d 国（最大 %.0f / 平均 %.2f）"
          % (n_uncov, len(bad_pre), err_max_pre, err_avg_pre))

    # 政权登记簿（A6 的账本）
    states = {}
    for k, sid in enumerate(sids):
        node = cap_nodes[k]
        states[sid] = {
            "capital": cities[node]["sid"], "culture": cities[node]["dom"],
            "cities": {node}, "born_round": 0, "annexed": 0,
            "flips_in": 0, "flips_out": 0, "collapsed": False,
            "extinct_round": None, "cause": None, "target": tgt_map[sid],
        }
    for u, sid in enumerate(owner):
        states[sid]["cities"].add(u)

    mix_tr_dbg = float(sp["normalize"]["mix_transition"])
    sim_keep_dbg = float(sp["normalize"]["sim_enclave_keep"])

    def cultural_mismatch():
        """诊断：文化错配城数（城主导 ≠ 国文化且非荒野、非近亲）。"""
        bad = 0
        for sid, s in states.items():
            if s["extinct_round"] is not None:
                continue
            c = s["culture"]
            if c == 0:
                continue
            for u in s["cities"]:
                d = cities[u]["dom"]
                if d != c and d != 0 and \
                        float(simM[c - 1][d - 1]) < sim_keep_dbg:
                    bad += 1
        return bad

    print("  [diag] 分配后文化错配城数：%d" % cultural_mismatch())

    print("[6/8] normalize 消飞地 + 规模回收 + 文化归位（四轮迭代）...", flush=True)
    cap = int(sp["spectrum"]["cap"])
    keep = float(sp["normalize"]["sim_enclave_keep"])
    n_flip = n_reclaim = n_rehome = 0
    for it in range(4):
        n_flip += normalize_pass(owner, states, adj, cities, simM,
                                 sp["normalize"], cap, targets=tgt_map)
        reattribute_cultures(states, cities)
        n_rehome += culture_rehome_pass(states, owner, adj, cities, simM,
                                        keep, cap, tgt_map)
        n_reclaim += reclaim_pass(states, owner, adj, cities, simM, tgt_map,
                                  cap)
    reattribute_cultures(states, cities)
    print("  翻转 %d 城 + 回收转让 %d 城 + 文化归位 %d 城"
          % (n_flip, n_reclaim, n_rehome))
    print("  [diag] 收敛后文化错配城数：%d" % cultural_mismatch())
    # 分配阶段快照（自检：target 与实际偏差带；A6 前的口径）
    allocation = {sid: {"target": int(tgt_map[sid]),
                        "got": len(states[sid]["cities"])} for sid in sids}
    bad_post, err_max_post, err_avg_post = dev_stats(allocation)
    over = [sid for sid in bad_post if allocation[sid]["got"] > allocation[sid]["target"]]
    print("  收敛后偏差带外 %d 国（超 %d / 缺 %d；最大 %.0f / 平均 %.2f）；最大政权 %d 城"
          % (len(bad_post), len(over), len(bad_post) - len(over),
             err_max_post, err_avg_post,
             max(len(s["cities"]) for s in states.values())))
    for sid in bad_post[:10]:
        print("    [dev] %s target=%d got=%d" % (
            sid, allocation[sid]["target"], allocation[sid]["got"]))

    print("[7/8] A6 加速历史 %d 轮..." % int(sp["history"]["rounds"]),
          flush=True)
    mix_arr = np.array([c["mix"] for c in cities], dtype=np.float64)
    hcount = run_history(states, owner, adj, cities, simM, sp["history"], rng,
                         cap, n_total, mix_arr)
    n_flip2 = normalize_pass(owner, states, adj, cities, simM, sp["normalize"],
                             cap, targets=tgt_map)
    reattribute_cultures(states, cities)
    n_rehome2 = culture_rehome_pass(states, owner, adj, cities, simM, keep,
                                    cap, tgt_map)
    reattribute_cultures(states, cities)
    print("  事件：%s；事后 normalize 再翻 %d 城 + 归位 %d 城；最大政权 %d 城"
          % (hcount, n_flip2, n_rehome2,
             max(len(s["cities"]) for s in states.values()
                 if s["extinct_round"] is None)))

    # ---- 终局组装 ----
    live = sorted(sid for sid, s in states.items() if s["extinct_round"] is None)
    states_out = {}
    for sid in live:
        s = states[sid]
        cu = next(u for u in sorted(s["cities"])
                  if cities[u]["sid"] == s["capital"])
        c = s["culture"]
        cid = ("cult_%02d" % c) if c > 0 else None
        states_out[sid] = {
            "name": "", "capital": s["capital"],
            "culture": int(c),
            "culture_id": cid,
            "race": race_by_culture.get(cid),
            "alliance": None,
            "is_city_state": len(s["cities"]) == 1,
            "name_status": "提案/待定",
            "n_cities": len(s["cities"]),
            "target": s["target"],
            "history": {
                "born_round": s["born_round"], "annexed": s["annexed"],
                "flips_in": s["flips_in"], "flips_out": s["flips_out"],
                "collapsed": s["collapsed"],
            },
        }
    print("[8/8] 构型命名 + 色板 + meta...", flush=True)
    city_names, name_samples = name_all(states_out, cities, sources,
                                        sp["naming"], int(sp["seed"]))

    conflicts = assign_colors(states_out, owner, edges, P["colors"])
    homo = homogeneity_stats(states, states_out, cities, simM,
                             float(sp["normalize"]["mix_transition"]),
                             float(sp["normalize"]["sim_enclave_keep"]))

    city_owners = {cities[u]["sid"]: owner[u] for u in range(n_total)}
    sizes = {sid: states_out[sid]["n_cities"] for sid in states_out}

    # ---- 规模谱统计（先验 raw / 钳制后 target / 终局 final） ----
    final_hist = Counter(sizes.values())
    tgt_hist = Counter(tgt_map[sid] for sid in sids)
    raw_hist = {int(k): int(v) for k, v in spec_obs["raw_hist"].items()}
    size_axis = sorted(set(final_hist) | set(tgt_hist) | set(raw_hist))
    spectrum_table = [[sz, int(raw_hist.get(sz, 0)), int(tgt_hist.get(sz, 0)),
                       int(final_hist.get(sz, 0))] for sz in size_axis]

    extinct = [sid for sid, s in states.items() if s["extinct_round"] is not None]
    meta = {
        "status": "提案/待定",
        "generated_by": "state_build_v2.py",
        "params": "state_params.json#fields_v2.states_v2",
        "seed": int(sp["seed"]),
        "consumes": {
            "settlements": "output/fields/settlements_v2.json（棒 2，1036 城）",
            "fields": ["attack_cost.npy", "suitability.npy",
                       "mineral/fertile/forest/fishsalt.npy"],
            "culture": ["culture_sources.json", "culture_similarity.json",
                        "culture_field/strength/mix.npy（2048 级工作集）"],
        },
        "coords": "8192 级像素（左上原点、y 向下），与场产物同网格",
        "n_states": len(states_out),
        "n_cities": len(city_owners),
        "schema_note": "states/city_owners 对齐 political_data（新增 target/history/"
                       "culture_agreement 字段）；culture = v2 文化源点序号 1..K、"
                       "0=荒野文化（无源点，pure 地理归属邦）；culture_id 为 cult_XX "
                       "字符串；城名表挂 meta.city_names（构型命名 v2 产物）",
        "culture_formula": "城对相似度 = sim(dom_u,dom_v)×(1-mix_u)×(1-mix_v)"
                           "（culture_similarity.json 消费口径）；任一端 dominant=0"
                           " → 文化因子取 1（荒野城纯地理归属）",
        "spectrum": {
            "params": {k: sp["spectrum"][k] for k in
                       ("median", "sigma", "cap", "floor", "local_reach_px")},
            "n_states_initial": n_c,
            "sampler_mean": spec_obs["sampler_mean"],
            "local_reach_used_px": round(float(reach_used), 1),
            "table_comment": "列 = [城数, 先验采样直方(钳制前), target 直方(局地池"
                             "钳制后), 终局直方(A6 后)]",
            "table": spectrum_table,
        },
        "capital_rule": "都城适宜性 = 资源禀赋项(h 口径复用 settlements) × 文化中心性"
                        "(exp(-距主导文化场强质心/%.0f px))；荒野城不参选；四叉树间距 "
                        "%.0f px 自适应" % (float(sp["capital"]["central_tau_px"]),
                                            float(sp["capital"]["min_sep_px"])),
        "merge_formula": "边权 = attack_cost 沿线积分 × (1+%.1f×(1-城对相似度))，松弛"
                         "时乘 (1/%.2f~%.2f expansionism) × (1+%.1f×min(1,(都城 px 测"
                         "地距/%.0f)²)) × w_i 反馈 × (1+%.1f×已占数/target 配额压力)"
                         % (float(sp["merge"]["k_culture"]),
                            float(sp["merge"]["expansionism"]["min"]),
                            float(sp["merge"]["expansionism"]["max"]),
                            float(sp["merge"]["k_capital"]),
                            float(sp["merge"]["capital_reach_px"]),
                            float(sp["merge"]["fill_pressure"])),
        "allocation_check": {
            "note": "target 与实际城数偏差带（±max(2, 15%×target)）在 A6 前的分配快照"
                    "上判（A6 本身就是改版图的事件层，终局谱由模拟涌现）；逐国快照如"
                    "下，born_round>0 的 A6 新邦无 target",
            "states": allocation,
        },
        "history": {
            "rounds": int(sp["history"]["rounds"]),
            "annexations": hcount["annexations"],
            "annex_skipped_cap": hcount["annex_skipped_cap"],
            "collapses": hcount["collapses"],
            "border_flips": hcount["border_flips"],
            "states_born": hcount["born"],
            "states_extinct": len(extinct),
            "states_initial": n_c,
            "states_final": len(states_out),
            "extinct_list": sorted(extinct),
            "note": "兼并战/继承解体/边疆易手各以 attack_cost×文化相似度判据触发；"
                    "states[].history 记逐国兴衰计数（annexed/flips/collapsed）",
        },
        "homogeneity": {
            "rule": "一致 = 城主导==国文化 或 城为荒野(dominant=0) 或 近亲文化放宽"
                    "(sim(城主导, 国文化) ≥ %.2f，与 normalize 相似文化飞地保留"
                    "同口径)；荒野邦（国文化=0）不参与阈值"
                    % float(sp["normalize"]["sim_enclave_keep"]),
            "cultured_states": homo["cultured_states"],
            "wild_states": homo["wild_states"],
            "wild_cities_in_wild_states": homo["wild_cities"],
            "min_agreement": homo["min_rate"],
            "min_agreement_state": homo["min_state"],
        },
        "names_status": "生成名（构型命名 v2），待创始人筛选定稿",
        "naming_note": "语素库自 culture_sources.morph_seed 派生：声母按语系共享、"
                       "韵母/后缀按生计分档（农耕柔和/游牧浑厚/渔猎清亮/商贸响亮），"
                       "荒野文化用中性库；构词法 = [方位前缀]+词根(1-2音节)+后缀；"
                       "政权名 3-5 字、城市名 2-4 字，全表去重",
        "city_names": city_names,
        "name_samples_by_culture": name_samples,
        "color_source": "palette.py OKLCH 候选 + 城图邻接贪心 OKLab ΔE 分配"
                        "（min_delta_e=%.3f；候选 %d 色 < 政权数 %d，颜色按冲突最小"
                        "循环复用）" % (float(P["colors"]["min_delta_e"]),
                                       int(P["colors"]["hue_count"])
                                       * len(P["colors"]["tiers"]),
                                       len(states_out)),
        "decisions": [
            "城图选 kNN（k=8 + 距离上限 + 分量桥接）而非 Delaunay：Delaunay 长薄三角"
            "形边跨海跨山无语义，kNN 贴合 attack_cost 沿线积分语义",
            "荒野城（dominant=0，152 座）文化因子取 1：纯地理归属，孤立小邦形态按提"
            "案允许，不做特殊保护",
            "次文化 second 字段不需要：A4 城对相似度消费口径只用 dominant×mix，"
            "settlements_v2.json 已含，无需折算",
            "target 偏差带判在 A6 前的分配快照（meta.allocation_check）；终局谱由 A6 "
            "涌现，只判谱形（≥5 个 12+ 城大国、≥8 个 1 城邦、无超 cap）",
            "is_city_state = 终局城数==1（A6 后一城邦自动成立，比 target==1 更符合"
            "「打出来」的语义）",
            "都城中心性用「场强质心距离」exp 反比（温度口径同 fields_meta 的 "
            "strength_temp 消费式）；荒野城中心性=0 不参选都城",
            "cult_13/14 各仅 1 城：按全局竞争处理（不设文化配额），其城若当选都城则"
            "自成邦、否则并入邻邦——结果见 meta.history 与 states 分布",
            "国文化 = 名下城主导文化的多数派归因（并列先都城主导、再小 id），非都城"
            "主导——都城落在文化过渡带/孤点时少数派都城会把国文化归错（探针实测多"
            "数派归因使失败国一致率 0.36→0.91）；归因在收敛与 A6 后各重算一次",
            "规模收敛 = 竞速配额压力（fill_pressure）+ normalize 规模带天花板 + "
            "reclaim 两相回收（严格过剩→真缺口；超带/超 cap 强制排空）+ 跨国接力"
            "（BFS 最近真缺口、中间国净零过户、1 城邦不作中间节点）",
            "自检容差（state_check_v2.py，残差为地理围困 + 都城不可动的 1 城邦阻断"
            "回收的硬约束）：偏差带外 ≤2% 初创国；文化同质度阈值只对 ≥3 城国生效、"
            "超限 ≤2% 文化邦",
        ],
        "determinism": "同 seed 逐位确定：np.random.default_rng 单流固定次序消费 + "
                       "显式排序（禁 set 迭代序依赖）+ 全整数/浮点确定性运算",
    }

    product = {"meta": meta, "states": states_out, "city_owners": city_owners}

    # ---- 控制台报告 ----
    print("\n=== A4 规模谱（核心验收）===")
    print("  城数 | 先验采样 | target(钳制后) | 终局(A6 后)")
    for row in spectrum_table:
        print("  %3d  | %6d   | %6d        | %6d" % tuple(row))
    big = [sid for sid, n in sizes.items() if n >= 12]
    one = [sid for sid, n in sizes.items() if n == 1]
    print("  终局：≥12 城大国 %d 个（%s）；1 城邦 %d 个；最大 %d 城 / 政权 %d 个"
          % (len(big), ", ".join("%s:%d" % (s, sizes[s]) for s in big[:8]),
             len(one), max(sizes.values()), len(sizes)))
    dev_bad = [sid for sid, a in allocation.items()
               if abs(a["got"] - a["target"]) > max(2.0, 0.15 * a["target"])]
    print("  分配偏差带外（A6 前）：%d 国 %s" % (len(dev_bad), dev_bad[:8]))
    print("=== A6 加速历史 ===")
    print("  兼并 %d（cap 拒绝 %d）/ 解体 %d / 易手 %d；新生 %d、消亡 %d；"
          "政权 %d → %d" % (hcount["annexations"], hcount["annex_skipped_cap"],
                            hcount["collapses"], hcount["border_flips"],
                            hcount["born"], len(extinct), n_c, len(states_out)))
    print("=== 文化同质度 ===")
    print("  文化邦 %d（一致率最低 %.3f @ %s）/ 荒野邦 %d（%d 城，豁免）"
          % (homo["cultured_states"], homo["min_rate"], homo["min_state"],
             homo["wild_states"], homo["wild_cities"]))
    print("  低于 0.8 的国 %d 个：%s" % (
        len(homo["below"]),
        "；".join("%s %.2f（%d城）" % (s, r, n) for s, r, n in homo["below"][:12])))
    print("=== 命名样例（每文化前 3 个政权名，全部提案/待定）===")
    for c in sorted(name_samples, key=int):
        print("  cult_%s: %s" % (c, "、".join(name_samples[c])))

    if dry_run:
        print("\n--dry-run：不写任何文件，结束。")
        return product

    with open(OUT_PATH, "w", encoding="utf-8") as f:
        json.dump(product, f, ensure_ascii=False, indent=1)
    print("产物：%s" % OUT_PATH)

    if not skip_preview:
        make_previews(P, suit, eff_land, cities, owner, states_out, meta)
    return product


# ---------- 预览 ----------

def make_previews(P, suit, eff_land, cities, owner, states_out, meta):
    """政治图（最近城 Voronoi 视觉聚合 + 城点着色 + 都城标记，叠宜居度淡底）
    + 规模谱直方图。均为验收预览，正式 ID mask/LUT 由棒 4 重烤。"""
    font = fc.fit_font(22)
    font_s = fc.fit_font(16)
    S = fc.SIZE

    # 底图：宜居度淡底（陆地），海洋深蓝
    base = fc.colormap(np.asarray(suit, dtype=np.float32), fc.HEAT_STOPS)
    base = (base * 0.42).astype(np.uint8)
    base[~eff_land] = OCEAN_RGB
    img = Image.fromarray(base, "RGB")

    # 最近城归属（KDTree 全网格查询）→ 政权色铺色 + 国界描暗
    from scipy.spatial import cKDTree
    pts = np.stack([np.array([c["x"] / K for c in cities]),
                    np.array([c["y"] / K for c in cities])], axis=1)
    tree = cKDTree(pts)
    ax = np.arange(S, dtype=np.float64)
    GX, GY = np.meshgrid(ax, ax)
    _, idx = tree.query(np.stack([GX.ravel(), GY.ravel()], axis=1), workers=1)
    lab = idx.reshape(S, S)
    live = sorted(sid for sid, s in states_out.items()
                  if s.get("lut_index") is not None)
    col_by_sid = {sid: tuple(states_out[sid]["color"]) for sid in live}
    lut = np.zeros((len(cities) + 1, 3), dtype=np.uint8)
    for i, c in enumerate(cities):
        sid = owner[c["label"] - 1]
        lut[i + 1] = col_by_sid.get(sid, (120, 120, 120))
    rgb = lut[lab + 1]
    landm = eff_land
    rgb[~landm] = OCEAN_RGB
    b_h = (lab[1:, :] != lab[:-1, :]) & landm[1:, :] & landm[:-1, :]
    b_w = (lab[:, 1:] != lab[:, :-1]) & landm[:, 1:] & landm[:, :-1]
    dark = (rgb * 0.35).astype(np.uint8)
    rgb[1:, :][b_h] = dark[1:, :][b_h]
    rgb[:, 1:][b_w] = dark[:, 1:][b_w]
    img = Image.fromarray(rgb, "RGB")

    dr = ImageDraw.Draw(img)
    for c in cities:  # 城点
        x, y = c["x"] / K, c["y"] / K
        r = 2 + (2 if c["pop"] >= 0.342 else (1 if c["pop"] >= 0.187 else 0))
        dr.ellipse([x - r, y - r, x + r, y + r], fill=(250, 250, 245),
                   outline=(20, 20, 24))
    cap_lab = []
    for sid in live:
        cap = states_out[sid]["capital"]
        node = next(c for c in cities if c["sid"] == cap)
        x, y = node["x"] / K, node["y"] / K
        rr = 7 if states_out[sid]["n_cities"] >= 12 else 5
        dr.ellipse([x - rr, y - rr, x + rr, y + rr], outline=(255, 255, 255),
                   width=3, fill=(20, 20, 24))
        cap_lab.append((states_out[sid]["n_cities"], x, y,
                        states_out[sid]["name"], sid))
    for n, x, y, name, _sid in sorted(cap_lab, reverse=True)[:16]:
        dr.text((x + 10, y - 12), "%s·%d城" % (name, n), font=font_s,
                fill=(255, 255, 255), stroke_width=2, stroke_fill=(15, 15, 18))

    canvas = Image.new("RGB", (S + 430, S), (14, 16, 22))
    canvas.paste(img, (0, 0))
    d2 = ImageDraw.Draw(canvas)
    d2.text((S + 18, 20), "A4+A6 政治版图 v2（%d 政权 · %d 城）"
            % (len(states_out), meta["n_cities"]), font=font,
            fill=(240, 240, 245))
    d2.text((S + 18, 52), "白圈=都城（大圈=12+ 城强权）· 白点=城市 · 暗线=国界"
            "（最近城 Voronoi 视觉聚合，正式 ID mask 由棒 4 重烤）",
            font=font_s, fill=(170, 175, 185))
    top = sorted(live, key=lambda s: (-states_out[s]["n_cities"], s))[:24]
    for i, sid in enumerate(top):
        y = 92 + i * 30
        d2.rectangle([S + 18, y + 4, S + 44, y + 22],
                     fill=tuple(states_out[sid]["color"]) + (255,),
                     outline=(20, 20, 24, 255))
        d2.text((S + 52, y + 2), "%s %d城%s" % (
            states_out[sid]["name"], states_out[sid]["n_cities"],
            "（城邦）" if states_out[sid]["is_city_state"] else ""),
            font=font_s, fill=(225, 225, 232))
    out1 = os.path.join(FIELDS_DIR, "states_v2_preview_political_2048.png")
    canvas.save(out1)

    # ---- 规模谱直方图（核心验收）----
    W, H = 1280, 620
    hist_img = Image.new("RGB", (W, H), (20, 22, 28))
    dh = ImageDraw.Draw(hist_img)
    table = meta["spectrum"]["table"]
    mx = max(max(r[1], r[2], r[3]) for r in table) or 1
    x0, y0 = 70, 90
    slot = max(14, (W - 150) // max(len(table), 1))
    bw = max(3, (slot - 6) // 3)
    dh.text((24, 18), "规模谱直方图（多数小国少数大国）— 蓝=先验采样 / 绿=target"
            "（局地池钳制后）/ 橙=终局（A6 后）", font=font, fill=(240, 240, 245))
    for k, (sz, a, b, c) in enumerate(table):
        x = x0 + k * slot
        for j, (val, col) in enumerate(((a, (90, 130, 210)),
                                        (b, (90, 190, 130)),
                                        (c, (235, 150, 70)))):
            if val <= 0:
                continue
            h = int(val / mx * (H - 180))
            bx = x + j * (bw + 1)
            dh.rectangle([bx, H - 60 - h, bx + bw, H - 60], fill=col)
        dh.text((x, H - 52), str(sz), font=font_s, fill=(200, 200, 210))
    for i, (lab_, col) in enumerate((("先验采样", (90, 130, 210)),
                                     ("target", (90, 190, 130)),
                                     ("终局", (235, 150, 70)))):
        dh.rectangle([70 + i * 150, H - 30, 92 + i * 150, H - 14], fill=col)
        dh.text((100 + i * 150, H - 32), lab_, font=font_s, fill=(220, 220, 228))
    out2 = os.path.join(FIELDS_DIR, "states_v2_preview_spectrum.png")
    hist_img.save(out2)
    print("预览：%s + %s" % (out1, out2))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--skip-preview", action="store_true")
    args = ap.parse_args()
    P = fc.load_params()
    build(P, dry_run=args.dry_run, skip_preview=args.skip_preview)


if __name__ == "__main__":
    main()
