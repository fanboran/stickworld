"""世界重生成 v2：国家生成 · 都城自适应涌现（state_build_v2.py）

机制（创始人 2026-09-28 定向：都城不再预摆，政权与都城均由兼并涌现）：
  1. 微核起步：全部正常聚落（level>0）初始各自成一个微核政权；规模谱只用于
     反推「期望政权数」N_c（N_c ≈ 总城数 / 谱均值），不再有逐国 target
  2. 文化加权/邻接兼并（复用 A4/A6 的静态边权）：kNN 城图（分量桥接兜底孤岛）
     上静态边权 = attack_cost 沿线积分 × (1 + k_culture×(1-城对文化相似度))；
     按最廉价边优先（Kruskal 式，文化近亲 + 地理便宜先并）迭代兼并，直至存活
     政权数 == N_c。兼并只走城图邻接边、限同岛群、规模不超谱 cap
  3. 出生区约束（换表达）：L1 69/68（spectrum.spawn_cluster.l1_labels）内的政权
     规模封顶 max_cities（3）城——合并到此即停，不许长成大国；无任何间距参数
  4. 都城 = 国内 population_score 最高（并列取 label 小）的城；国文化按名下城
     主导文化多数派归因
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
from state_expand_lite import _bridge_components  # noqa: E402  （借用不改）

K = fc.SIZE_FULL // fc.SIZE  # 4：8192 坐标 → 2048 场网格缩比
FIELDS_DIR = fc.FIELDS_DIR
OUT_PATH = os.path.join(FIELDS_DIR, "political_data_v2.json")

OCEAN_RGB = (22, 33, 52)
WASTELAND_RGB = (128, 118, 100)  # 无主荒地裸色（土灰）


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


def build_city_attrs(settle):
    """城属性补全：label/sid/坐标/主导文化/混合度/人口/规模档 + 岛群与老 L1 归属。

    都城不再预选（涌现制），故不再算都城适宜度；都城由各国按 population_score
    选（见 emerge_states / finalize_capitals）。节点序 = label 序（index = label-1）。
    """
    cities = []
    for c in sorted(settle, key=lambda x: int(x["label"])):
        cities.append({
            "label": int(c["label"]),
            "sid": sid_of(c["label"]),
            "x": int(c["x"]), "y": int(c["y"]),
            "dom": int(c["dominant"]),
            "mix": float(c["mix"]),
            "pop": float(c["population_score"]),
            "level": int(c.get("level", 1)),
        })
    _tag_island_groups(cities)
    return cities


_L1_WINDOWS = None


def _load_l1_windows():
    """全部 L1 包窗口（label → (x0, y0, side, fx, fy)）——城落在哪个包窗口即
    玩家在该 L1 图上可见，作为「城的老 L1 归属」（legacy 标签场只覆盖老城块，
    v2 新城多在老城块外，不可用）。多窗重叠取距 focus_center 最近者。"""
    global _L1_WINDOWS
    if _L1_WINDOWS is not None:
        return _L1_WINDOWS
    wins = []
    base = fc.GAME_CFG
    for label in list(range(1, 70)) + [0]:
        if label == 0:
            p = os.path.join(base, "l1_world.json")
            lab = 49  # 出生根件 = 出生包（l1_049）
        else:
            p = os.path.join(base, "l1_packs", "l1_%03d" % label, "l1_world.json")
            lab = label
        if not os.path.isfile(p):
            continue
        with open(p, encoding="utf-8") as f:
            w = json.load(f)
        wo = w.get("world_origin")
        cs = w.get("context_size")
        fc_ = w.get("focus_center")
        if not wo or not cs:
            continue
        side = int(cs[0]) if isinstance(cs, list) else int(cs)
        fx = float(fc_[0]) if fc_ else wo[0] + side / 2.0
        fy = float(fc_[1]) if fc_ else wo[1] + side / 2.0
        wins.append((lab, int(wo[0]), int(wo[1]), side, fx, fy))
    _L1_WINDOWS = wins
    return wins


def _l1_of_xy(x, y, windows):
    """城 → 老 L1 归属：落在某包窗口内取值；多窗取距 focus 最近。"""
    best, best_d = 0, None
    for lab, x0, y0, side, fx, fy in windows:
        if x0 <= x < x0 + side and y0 <= y < y0 + side:
            d = math.hypot(x - fx, y - fy)
            if best_d is None or d < best_d:
                best, best_d = lab, d
    return best


def _tag_island_groups(cities, gp=None):
    """岛群标记（创始人定向：同岛/同岛群更易统一）——陆地连通分量归并岛群：
    海膨胀 dilate_px 后连通的陆块视为同一岛群（窄海峡=可渡，允许群岛国），
    城附 grp 字段；跨群边权受重罚、A6 兼并限同群。确定性。"""
    from scipy import ndimage
    biome = np.load(os.path.join(fc.OUTPUT_DIR, "biome_labels_2048.npy"))
    dil = int((gp or {}).get("island_group_dilate_px", 2))
    land_d = ndimage.binary_dilation(biome > 0, iterations=dil)
    grp_lab, _ = ndimage.label(land_d)
    l1_wins = _load_l1_windows()
    k = fc.SIZE / fc.SIZE_FULL
    legacy = None
    legacy_p = os.path.join(fc.OUTPUT_DIR, "l1_v2", "legacy_l1_labels_8192.npy")
    if os.path.isfile(legacy_p):
        legacy = np.load(legacy_p, mmap_mode="r")
    for c in cities:
        yy, xx = int(c["y"] * k), int(c["x"] * k)
        c["grp"] = int(grp_lab[yy, xx])
        c["biome"] = int(biome[yy, xx])
        c["l1"] = _l1_of_xy(int(c["x"]), int(c["y"]), l1_wins)


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


# ---------- 微核涌现合并（都城自适应） ----------

def _city_nbr_w(adj, i, j):
    """城 i 到邻城 j 的静态边权（build_graph 产物；找不到 = inf）。"""
    for v, w in adj[i]:
        if v == j:
            return w
    return math.inf


def emerge_states(cities, adj, edges, cap, spawn_labels, spawn_cap, n_target):
    """微核起步 + 最廉价边优先兼并，直到政权数 == n_target（都城自适应涌现）。

    全部 level>0 聚落初始各自成微核；静态边权（build_graph 的 attack_cost×
    culture 因子）按 (w, i, j) 升序处理，两端属不同政权、同岛群、且合并后不超
    上限时兼并（winner = 城数多者，并列比人口、再比 label 小）——文化近亲 +
    地理便宜先并，即「打出来的版图」在生成期的确定性加速版。上限 = 谱 cap；
    出生 L1（spawn_labels）政权封顶 spawn_cap（合并到此即停、不许长成大国）。
    返回 (owner, states, n_merge, n_core)；level==0 填充点暂不归属（owner=-1，
    由 assign_orphans 收尾）。
    """
    n = len(cities)
    is_core = [cities[u]["level"] > 0 for u in range(n)]
    core = [u for u in range(n) if is_core[u]]
    parent = list(range(n))
    size = [1] * n
    grp = [cities[u].get("grp", 0) for u in range(n)]
    spawn = [int(cities[u].get("l1", 0)) in spawn_labels for u in range(n)]
    maxpop = [cities[u]["pop"] for u in range(n)]
    minlab = [cities[u]["label"] for u in range(n)]
    annexed = [0] * n

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    wedges = []
    for (i, j) in sorted(edges):
        if is_core[i] and is_core[j]:
            wedges.append((_city_nbr_w(adj, i, j), i, j))
    wedges.sort()
    k = len(core)
    n_merge = 0
    for w, i, j in wedges:
        if k <= n_target:
            break
        ri, rj = find(i), find(j)
        if ri == rj or grp[ri] != grp[rj]:
            continue
        lim = spawn_cap if (spawn[ri] or spawn[rj]) else cap
        if size[ri] + size[rj] > lim:
            continue
        if (size[ri], maxpop[ri], -minlab[ri]) >= (size[rj], maxpop[rj], -minlab[rj]):
            wa, wb = ri, rj
        else:
            wa, wb = rj, ri
        parent[wb] = wa
        size[wa] += size[wb]
        if maxpop[wb] > maxpop[wa]:
            maxpop[wa] = maxpop[wb]
        if minlab[wb] < minlab[wa]:
            minlab[wa] = minlab[wb]
        spawn[wa] = spawn[wa] or spawn[wb]
        annexed[wa] += 1
        k -= 1
        n_merge += 1

    members = defaultdict(set)
    for u in core:
        members[find(u)].add(u)
    states = {}
    sid_of_root = {}
    for idx, r in enumerate(sorted(members)):
        sid = "state_em_%04d" % (idx + 1)
        sid_of_root[r] = sid
        comp = members[r]
        capu = max(comp, key=lambda u: (cities[u]["pop"], -cities[u]["label"]))
        states[sid] = {
            "capital": cities[capu]["sid"], "culture": cities[capu]["dom"],
            "cities": set(comp), "born_round": 0, "annexed": annexed[r],
            "flips_in": 0, "flips_out": 0, "collapsed": False,
            "extinct_round": None, "cause": None, "target": len(comp),
        }
    owner = [-1] * n
    for u in core:
        owner[u] = sid_of_root[find(u)]
    return owner, states, n_merge, len(core)


def assign_orphans(owner, states, cities, adj, core):
    """level==0 填充点归属：并入接触边权最低的邻接政权（无则最近微核）。"""
    for u in range(len(cities)):
        if owner[u] != -1:
            continue
        best, bw = None, None
        for v, w in adj[u]:
            if owner[v] != -1 and (bw is None or w < bw or (w == bw and v < best)):
                best, bw = v, w
        if best is None:
            best = min(core, key=lambda v: (
                math.hypot(cities[v]["x"] - cities[u]["x"],
                           cities[v]["y"] - cities[u]["y"]), v))
        owner[u] = owner[best]
        states[owner[u]]["cities"].add(u)


def finalize_capitals(states, cities):
    """都城 = 国内 population_score 最高（并列取 label 小）的城。"""
    for s in states.values():
        if s["extinct_round"] is not None:
            continue
        capu = max(s["cities"],
                   key=lambda u: (cities[u]["pop"], -cities[u]["label"]))
        s["capital"] = cities[capu]["sid"]


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
        if a.get("grp", 0) != b.get("grp", -1):
            w *= float(gp.get("k_island", 10.0))  # 跨岛群重罚：同岛更易统一
        adj[i].append((j, w))
        adj[j].append((i, w))
        pxadj[i].append((j, dist8))
        pxadj[j].append((i, dist8))
    return adj, pxadj, edges


# ---------- normalize（历史遗留：涌现制下不再调用） ----------

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


# ---------- 终态闸（岛群归一 / 超 cap 削顶） ----------

def enforce_cap(states, owner, cities, cap_hi, spawn_labels=None, spawn_cap=3):
    """超 cap 削顶（终态闸）：超 cap 国按「距首都最远」逐个把城转给邻接未满的国
    （无邻接者保留，宁超不散）。确定性。返回迁移数。"""
    moved = 0
    live = [sid for sid, st in states.items() if st["extinct_round"] is None]
    # 邻接表（按城距离近邻，简式：≤400px 视为邻接候选）
    for _ in range(50):
        big = sorted([sid for sid in live
                      if len(states[sid]["cities"]) > cap_hi],
                     key=lambda sid: -len(states[sid]["cities"]))
        if not big:
            break
        sid = big[0]
        st = states[sid]
        cap_city = next((u for u in st["cities"]
                         if cities[u]["sid"] == st["capital"]), None)
        if cap_city is None:
            break
        far = sorted(st["cities"],
                     key=lambda u: -math.hypot(
                         cities[u]["x"] - cities[cap_city]["x"],
                         cities[u]["y"] - cities[cap_city]["y"]))
        done = False
        for u in far:
            if cities[u]["sid"] == st["capital"]:
                continue
            # 邻近未满国（该城 400px 内城数最多的他国）
            cnt = {}
            ux, uy = cities[u]["x"], cities[u]["y"]
            for v in range(len(cities)):
                if owner[v] == sid:
                    continue
                if cities[v].get("grp", 0) != cities[u].get("grp", -1):
                    continue  # 削顶限同岛群（跨岛转城破坏岛内统一）
                vx, vy = cities[v]["x"], cities[v]["y"]
                if math.hypot(vx - ux, vy - uy) <= 400.0:
                    b = owner[v]
                    cnt[b] = cnt.get(b, 0) + 1
            cand = [b for b, _ in sorted(cnt.items(), key=lambda kv: (-kv[1], kv[0]))
                    if _cap_room_ok(states, cities, b, u, cap_hi,
                                    spawn_labels, spawn_cap)]
            if not cand:
                continue
            b = cand[0]
            st["cities"].discard(u)
            owner[u] = b
            states[b]["cities"].add(u)
            moved += 1
            done = True
            break
        if not done:
            break
    return moved


def _cap_room_ok(states, cities, sid, u, cap_hi, spawn_labels, spawn_cap):
    """接收方 b 收下城 u 后是否不破上限：普通国 ≤ cap_hi；含出生 L1 城的国
    （或 u 本身是出生 L1 城 → 收下后变成出生国）≤ spawn_cap。"""
    nxt = len(states[sid]["cities"]) + 1
    if spawn_labels and int(cities[u].get("l1", 0)) in spawn_labels:
        return nxt <= spawn_cap
    if spawn_labels:
        for w in states[sid]["cities"]:
            if int(cities[w].get("l1", 0)) in spawn_labels:
                return nxt <= spawn_cap
    return nxt <= cap_hi


def unify_small_islands(states, owner, cities, gp):
    """小岛群终态归一（创始人定向：同一个岛屿内更容易统一）——城数 ≤
    grp_single_max_cities 的岛群，名下城全部归群内城数最多的国；被剥空的
    国消亡（cause= island_unify）。大陆/大岛群不受影响。确定性。"""
    cap_single = int(gp.get("grp_single_max_cities", 30))
    grp_city = {}
    for u, c in enumerate(cities):
        g = c.get("grp", 0)
        if g != 0:
            grp_city.setdefault(g, []).append(u)
    moved = 0
    for g, us in grp_city.items():
        if len(us) > cap_single:
            continue
        cnt = {}
        for u in us:
            cnt[owner[u]] = cnt.get(owner[u], 0) + 1
        if len(cnt) <= 1:
            continue
        # keep 优先都城在群内的国（岛国核心），否则城数最多
        cap_in = [sid for sid in cnt
                  if any(cities[u]["sid"] == states[sid]["capital"]
                         for u in us if owner[u] == sid)]
        if cap_in:
            keep = sorted(cap_in)[0]
        else:
            keep = sorted(cnt.items(), key=lambda kv: (-kv[1], kv[0]))[0][0]
        uset = set(us)
        done_whole = set()
        for u in us:
            sid = owner[u]
            if sid == keep or sid in done_whole:
                continue
            # 跨国国首都受保护；全国皆在本群的国（含纯城邦）与 ≤3 城微国整体吸收
            whole = all(w in uset for w in states[sid]["cities"])                 or len(states[sid]["cities"]) <= 3
            if whole:
                for w in list(states[sid]["cities"]):  # 全国城（含外群）
                    states[sid]["cities"].discard(w)
                    owner[w] = keep
                    states[keep]["cities"].add(w)
                    moved += 1
                states[sid]["extinct_round"] = 0
                states[sid]["cause"] = "island_unify"
                done_whole.add(sid)
            elif cities[u]["sid"] != states[sid]["capital"]:
                states[sid]["cities"].discard(u)
                owner[u] = keep
                states[keep]["cities"].add(u)
                moved += 1
                if not states[sid]["cities"]:
                    states[sid]["extinct_round"] = 0
                    states[sid]["cause"] = "island_unify"
    # 13-30 城群超 mid 上限收敛（最弱超额国并入群内最强国，首都例外）
    mid_cap = int(gp.get("grp_mid_max_states", 4))
    for g, us in grp_city.items():
        if not (cap_single < len(us) <= 30):
            continue
        cnt = {}
        for u in us:
            cnt[owner[u]] = cnt.get(owner[u], 0) + 1
        over = sorted(cnt.items(), key=lambda kv: (kv[1], kv[0]))
        for sid, _n in over:
            if len(cnt) <= mid_cap:
                break
            if sid not in cnt:
                continue
            strongest = sorted(cnt.items(), key=lambda kv: (-kv[1], kv[0]))
            strongest = [k for k, _ in strongest if k != sid][0]
            uset = set(us)
            whole = all(w in uset for w in states[sid]["cities"])                 or len(states[sid]["cities"]) <= 3
            if whole:
                for w in list(states[sid]["cities"]):
                    states[sid]["cities"].discard(w)
                    owner[w] = strongest
                    states[strongest]["cities"].add(w)
                    moved += 1
                states[sid]["extinct_round"] = 0
                states[sid]["cause"] = "island_unify"
            else:
                for u in us:
                    if owner[u] == sid and                             cities[u]["sid"] != states[sid]["capital"]:
                        states[sid]["cities"].discard(u)
                        owner[u] = strongest
                        states[strongest]["cities"].add(u)
                        moved += 1
            if not states[sid]["cities"]:
                states[sid]["extinct_round"] = 0
                states[sid]["cause"] = "island_unify"
            cnt[strongest] = cnt.get(strongest, 0) + cnt.pop(sid, 0)
    if moved:
        print("  [island] 小岛群归一迁移 %d 城" % moved)


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
    n_hue = int(colors_spec.get("hue_count", 20))
    culture_band = {}
    for cid in range(1, 23):
        center = int(round((cid - 1) * n_hue / 22.0)) % n_hue
        culture_band[cid] = {(center - 1) % n_hue, center, (center + 1) % n_hue}
    culture_band[0] = None  # 荒野文化不限带（自然分配）
    state_culture_sid = {sid: int(states_out[sid]["culture"]) for sid in live}
    assigned, conflicts = palette.assign_colors(
        candidates, order, nbrs, float(colors_spec["min_delta_e"]),
        state_culture=state_culture_sid, culture_band=culture_band)
    for rank, sid in enumerate(order):
        states_out[sid]["lut_index"] = rank + 1
        states_out[sid]["color"] = list(assigned[sid]["rgb"])
    return len(conflicts)


# ---------- 产物组装 ----------

def homogeneity_stats(states, states_out, cities, simM, mix_tr, sim_keep,
                      rename=None):
    """文化同质度：各国名下城主导文化与国文化一致率（近亲文化放宽口径）。

    一致 = 城主导 == 国文化，或城为荒野（dominant=0，无文化身份不算冲突），
    或近亲文化放宽（sim(城主导, 国文化) ≥ sim_keep——「跨相似文化」不算冲突，
    与 normalize 的相似文化飞地保留同口径）。国文化 = 0（荒野邦）无法定义
    一致率，单独计数不参与阈值。cities 集合读 states 账本，一致率写回
    states_out[rename[sid]]["culture_agreement"]（states 为内部 id 时用 rename 映射）。
    """
    rep = {"cultured_states": 0, "wild_states": 0, "wild_cities": 0,
           "min_rate": 1.0, "min_state": None, "below": []}
    rename = rename or {}
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
        pub_sid = rename.get(sid, sid)
        states_out[pub_sid]["culture_agreement"] = round(rate, 4)
        if rate < rep["min_rate"]:
            rep["min_rate"] = rate
            rep["min_state"] = pub_sid
        if rate < 0.8:
            rep["below"].append((pub_sid, round(rate, 3), len(nodes)))
    return rep


def build(P, dry_run=False, skip_preview=False):
    """全流程：返回 product dict（meta/states/city_owners），供主函数落盘、
    供 state_check_v2.py 做同 seed 逐位对比。"""
    sp = P["fields_v2"]["states_v2"]
    rng = np.random.default_rng(int(sp["seed"]))

    print("[1/7] 读棒 1 场产物 + 棒 2 聚落集...", flush=True)
    (settle, sources, simj, suit, res, dom, mix, eff_land,
     strength, attack) = load_inputs()
    race_by_culture = {src["id"]: src.get("race") for src in sources}
    simM = simj["matrix"]
    n_total = len(settle)

    print("[2/7] 城属性（规模档 / 岛群 / 老 L1 归属）...", flush=True)
    cities = build_city_attrs(settle)

    print("[3/7] 规模谱期望政权数（截断对数正态均值反推）...", flush=True)
    n_c, _prior, spec_obs = sample_spectrum(n_total, sp["spectrum"], rng)
    print("  谱均值 %.2f → 期望政权数 N_c = %d" % (spec_obs["sampler_mean"], n_c))

    print("[4/7] 城图（kNN + 桥接 + attack_cost 沿线积分）...", flush=True)
    adj, pxadj, edges = build_graph(cities, attack, simM, sp["graph"],
                                    sp["merge"])

    cap = int(sp["spectrum"]["cap"])
    spawn_cfg = sp["spectrum"].get("spawn_cluster", {})
    spawn_labels = set(int(v) for v in spawn_cfg.get("l1_labels", []))
    spawn_cap = int(spawn_cfg.get("max_cities", 3))

    print("[5/7] 微核涌现合并（最廉价文化边优先，直至 %d 政权）..." % n_c,
          flush=True)
    core = [u for u in range(n_total) if cities[u]["level"] > 0]
    owner, states, n_merge, n_core = emerge_states(
        cities, adj, edges, cap, spawn_labels, spawn_cap, n_c)
    assign_orphans(owner, states, cities, adj, core)
    got = len(states)
    print("  微核 %d → 政权 %d（兼并 %d 次；%s）"
          % (n_core, got, n_merge,
             "达标" if got <= n_c else "边用尽未达标"))

    # 终态闸：小岛群岛内统一 + 超 cap 削顶（出生 L1 国仍封顶 spawn_cap）
    unify_small_islands(states, owner, cities, sp["graph"])
    n_cap_moved = enforce_cap(states, owner, cities, cap,
                              spawn_labels, spawn_cap)
    unify_small_islands(states, owner, cities, sp["graph"])
    reattribute_cultures(states, cities)
    finalize_capitals(states, cities)
    live_n = sum(1 for s in states.values() if s["extinct_round"] is None)
    print("  终态闸：超 cap 削顶迁移 %d 城；存活政权 %d；最大 %d 城"
          % (n_cap_moved, live_n,
             max(len(s["cities"]) for s in states.values()
                 if s["extinct_round"] is None)))

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

    print("  [diag] 涌现后文化错配城数：%d" % cultural_mismatch())

    # ---- 终局组装：存活政权重编号（规模降序 → 都城 label → 旧 id） ----
    def _cap_label(s):
        return int(s["capital"].rsplit("_", 1)[1])

    live_old = sorted((sid for sid, s in states.items()
                       if s["extinct_round"] is None),
                      key=lambda sid: (-len(states[sid]["cities"]),
                                       _cap_label(states[sid]), sid))
    rename = {old: "state_v2_%03d" % (i + 1) for i, old in enumerate(live_old)}
    states_out = {}
    for old in live_old:
        s = states[old]
        sid = rename[old]
        c = s["culture"]
        cid = ("cult_%02d" % c) if c > 0 else None
        states_out[sid] = {
            "name": "", "capital": s["capital"], "culture": int(c),
            "culture_id": cid, "race": race_by_culture.get(cid),
            "alliance": None, "is_city_state": len(s["cities"]) == 1,
            "name_status": "提案/待定", "n_cities": len(s["cities"]),
            "target": len(s["cities"]),
            "history": {
                "born_round": 0, "annexed": s["annexed"],
                "flips_in": 0, "flips_out": 0, "collapsed": False,
            },
        }
    for u in range(n_total):
        owner[u] = rename[owner[u]]

    print("[6/7] 构型命名 + 色板 + meta...", flush=True)
    city_names, name_samples = name_all(states_out, cities, sources,
                                        sp["naming"], int(sp["seed"]))

    conflicts = assign_colors(states_out, owner, edges, P["colors"])
    homo = homogeneity_stats(states, states_out, cities, simM,
                             float(sp["normalize"]["mix_transition"]),
                             float(sp["normalize"]["sim_enclave_keep"]),
                             rename=rename)

    city_owners = {cities[u]["sid"]: owner[u] for u in range(n_total)}
    sizes = {sid: states_out[sid]["n_cities"] for sid in states_out}

    # ---- 规模谱统计（先验 raw / 终局 final；target 已取消） ----
    final_hist = Counter(sizes.values())
    raw_hist = {int(k): int(v) for k, v in spec_obs["raw_hist"].items()}
    size_axis = sorted(set(final_hist) | set(raw_hist))
    spectrum_table = [[sz, int(raw_hist.get(sz, 0)),
                       int(final_hist.get(sz, 0))] for sz in size_axis]

    extinct = [sid for sid, s in states.items() if s["extinct_round"] is not None]
    # 自检口径：逐国 target = 涌现终局规模（无先验 target，偏差带恒为零）
    allocation = {rename[sid]: {"target": states_out[rename[sid]]["n_cities"],
                                "got": states_out[rename[sid]]["n_cities"]}
                  for sid in live_old}
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
                       ("median", "sigma", "cap", "floor")},
            "n_states_target": n_c,
            "sampler_mean": spec_obs["sampler_mean"],
            "n_core_microstates": n_core,
            "n_merges": n_merge,
            "spawn_cap": spawn_cap,
            "spawn_l1": sorted(spawn_labels),
            "table_comment": "列 = [城数, 谱先验采样直方(期望), 终局涌现直方]；"
                             "N_c = 谱均值反推的期望政权数，涌现合并到该数即停",
            "table": spectrum_table,
        },
        "capital_rule": "都城 = 国内 population_score 最高（并列取 label 小）的城；"
                        "都城不再预摆——全部 level>0 聚落初始各自为微核，按文化加权"
                        "邻接边最廉价优先兼并涌现出政权，都城随之确定",
        "merge_formula": "边权 = attack_cost 沿线积分 × (1+%.1f×(1-城对相似度))；"
                         "微核间按最廉价边优先（Kruskal 式）合并，同岛群才可并、"
                         "合并后 ≤ 谱 cap(%d)；出生 L1 %s 内政权封顶 %d 城"
                         % (float(sp["merge"]["k_culture"]), cap,
                            "/".join(str(x) for x in sorted(spawn_labels)),
                            spawn_cap),
        "allocation_check": {
            "note": "涌现制无先验 target：逐国 target = 终局涌现规模（偏差带恒为零）。"
                    "本表保留 schema 兼容供自检脚本消费，got 即 n_cities",
            "states": allocation,
        },
        "history": {
            "rounds": 0,
            "annexations": n_merge,
            "annex_skipped_cap": 0,
            "collapses": 0,
            "border_flips": 0,
            "states_born": 0,
            "states_extinct": n_core - len(states_out),
            "states_initial": n_core,
            "states_final": len(states_out),
            "extinct_list": sorted(extinct),
            "note": "涌现兼并：微核按最廉价文化边合并至期望政权数即停；每个兼并消融"
                    "一个微核（计入 annexations，不逐个列 extinct_list）；"
                    "extinct_list = 终态闸（岛群归一）中消亡的组建成国；"
                    "states[].history.annexed 记该国直接吞并的微核数",
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
            "荒野城（dominant=0）文化因子取 1：纯地理归属，孤立小邦形态允许",
            "都城自适应涌现（创始人 2026-09-28 定向）：删除四叉树泊松盘预摆/最小间距/"
            "出生区都城加密，改为全部 level>0 聚落各为微核、按最廉价文化加权邻接边"
            "迭代兼并至谱均值反推的期望政权数 N_c；都城 = 国内 population_score 最高"
            "（并列取 label 小）的城",
            "出生区约束换表达（原 capitalize 加密参数删除）：L1 69/68 内政权规模封顶"
            " max_cities=3 城——合并到此即停、不许长成大国；不用任何间距参数，"
            "spawn_protect_l1=[69,68] 的「出生区不被大国吞并」语义照旧",
            "兼并只走城图邻接边、限同岛群（跨海征服留给运行时海权，静态版图不产生）、"
            "合并后不超谱 cap；兼并为确定性贪心（无需随机事件层）",
            "is_city_state = 终局城数==1",
            "国文化 = 名下城主导文化的多数派归因（并列先都城主导、再小 id）",
            "旧分配机制（局地池钳制/normalize 消飞地/reclaim 规模回收/文化归位/"
            "A6 随机事件层/carve_spawn_cluster 出生圈重划分）在涌现制下全部退役；"
            "仅保留终态闸：小岛群岛内统一 + 超 cap 削顶（出生国仍封顶 3）",
            "自检脚本（state_check_v2.py）消费的 meta.allocation_check / meta.history "
            "键保留：涌现制无先验 target，逐国 target = 终局规模（偏差带恒为零）；"
            "守恒口径 = 微核数 + 0 − 兼并消融数 = 终局政权数",
        ],
        "determinism": "同 seed 逐位确定：np.random.default_rng 单流固定次序消费 + "
                       "显式排序（禁 set 迭代序依赖）+ 全整数/浮点确定性运算",
    }

    product = {"meta": meta, "states": states_out, "city_owners": city_owners}

    # ---- 控制台报告 ----
    print("\n=== 规模谱（核心验收，涌现制）===")
    print("  城数 | 谱先验采样 | 终局涌现")
    for row in spectrum_table:
        print("  %3d  | %6d   | %6d" % tuple(row))
    big = [sid for sid, n in sizes.items() if n >= 12]
    one = [sid for sid, n in sizes.items() if n == 1]
    small13 = [sid for sid, n in sizes.items() if 1 <= n <= 3]
    print("  终局：期望政权数 %d → 实际 %d；≥12 城大国 %d 个（%s）；1-3 城小国 %d；"
          "1 城邦 %d；最大 %d 城"
          % (n_c, len(sizes), len(big),
             ", ".join("%s:%d" % (s, sizes[s]) for s in big[:8]),
             len(small13), len(one), max(sizes.values())))
    spawn_id = spawn_cfg.get("spawn_settlement_id")
    if spawn_id in city_owners:
        s_sid = city_owners[spawn_id]
        so = states_out[s_sid]
        print("  出生城 %s → %s（%s，%d 城，都城 %s）"
              % (spawn_id, s_sid, so["name"], so["n_cities"], so["capital"]))
    print("=== 涌现兼并 ===")
    print("  微核 %d → 组建成国 %d（兼并 %d 次）→ 终态闸后 %d；最大政权 %d 城；"
          "超 cap 削顶迁移 %d 城"
          % (n_core, n_core - n_merge, n_merge, len(states_out),
             max(sizes.values()), n_cap_moved))
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

    # 城块归属（优先真实城块场 refined_city_labels：多边形严丝合缝，与游戏内
    # 政治渲染同形；场为上一代划分产物——聚落未变时即当前形状。缺场回退
    # 最近城 Voronoi + claim 圆裁剪（观感为圆盘，仅兜底））
    lab = None
    _refined_p = os.path.join(fc.OUTPUT_DIR, "l1_v2", "refined_city_labels_8192.npy")
    if os.path.isfile(_refined_p):
        ref = np.load(_refined_p, mmap_mode="r")
        step = ref.shape[0] // S
        lab = np.asarray(ref[::step, ::step][:S, :S]).astype(np.int64) - 1  # 0=无主 → -1
        # label（1..N）→ cities 索引（label-1）；0/无主 → -1
        lab = np.where(lab >= 0, lab, -1)
    if lab is None:
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
    lab_clip = np.clip(lab, 0, len(cities) - 1)
    rgb = lut[lab_clip + 1]
    if (lab < 0).any():
        rgb[lab < 0] = np.array(WASTELAND_RGB, dtype=np.uint8)  # 城块场 0=无主荒地
    landm = eff_land
    # 城块场直出（创始人 2026-09-28：政治图=地块图换上色，无圆盘无 Voronoi 裁剪）：
    # 块色=归属国色；lab<0 由 landm 分流——海=洋色、陆上无主=荒地灰
    rgb = lut[lab_clip + 1]
    rgb[lab < 0] = WASTELAND_RGB
    rgb[~landm] = OCEAN_RGB
    # 国界按归属国（不按块）：相邻像素归属国不同即描暗线
    sid_idx = {sid: i + 1 for i, sid in enumerate(live)}
    own_int = np.zeros(len(cities) + 1, dtype=np.int32)
    for i, c in enumerate(cities):
        own_int[i + 1] = sid_idx.get(owner[c["label"] - 1], 0)
    own_lab = own_int[lab_clip + 1]
    b_h = (own_lab[1:, :] != own_lab[:-1, :]) & landm[1:, :] & landm[:-1, :]
    b_w = (own_lab[:, 1:] != own_lab[:, :-1]) & landm[:, 1:] & landm[:, :-1]
    dark = (rgb * 0.35).astype(np.uint8)
    rgb[1:, :][b_h] = dark[1:, :][b_h]
    rgb[:, 1:][b_w] = dark[:, 1:][b_w]
    img = Image.fromarray(rgb, "RGB")

    dr = ImageDraw.Draw(img)
    for c in cities:  # 城点（极小标记；形状由城块表达，不再画圆）
        x, y = c["x"] / K, c["y"] / K
        r = 1.2 + (1.0 if c["pop"] >= 0.342 else 0.5)
        dr.ellipse([x - r, y - r, x + r, y + r], fill=(250, 250, 245))
    cap_lab = []
    for sid in live:
        cap = states_out[sid]["capital"]
        node = next(c for c in cities if c["sid"] == cap)
        x, y = node["x"] / K, node["y"] / K
        rr = 4 if states_out[sid]["n_cities"] >= 12 else 3
        dr.ellipse([x - rr, y - rr, x + rr, y + rr], outline=(255, 255, 255),
                   width=2, fill=(20, 20, 24))
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
            "（城块场直出：地块换国色，国界按归属描线）",
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
    mx = max(max(r[1], r[2]) for r in table) or 1
    x0, y0 = 70, 90
    slot = max(14, (W - 150) // max(len(table), 1))
    bw = max(3, (slot - 6) // 3)
    dh.text((24, 18), "规模谱直方图（多数小国少数大国）— 蓝=谱先验采样（期望）/ "
            "橙=终局涌现", font=font, fill=(240, 240, 245))
    for k, (sz, a, c) in enumerate(table):
        x = x0 + k * slot
        for j, (val, col) in enumerate(((a, (90, 130, 210)),
                                        (0, (90, 190, 130)),
                                        (c, (235, 150, 70)))):
            if val <= 0:
                continue
            h = int(val / mx * (H - 180))
            bx = x + j * (bw + 1)
            dh.rectangle([bx, H - 60 - h, bx + bw, H - 60], fill=col)
        dh.text((x, H - 52), str(sz), font=font_s, fill=(200, 200, 210))
    for i, (lab_, col) in enumerate((("谱先验采样", (90, 130, 210)),
                                     ("终局涌现", (235, 150, 70)))):
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
