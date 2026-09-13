# -*- coding: utf-8 -*-
"""field_dist.py —— 野外资源分布（森林簇 / 矿脉带 / 散点点缀 / 留白）

创始人明确要求（本条是重点，不是装饰）
--------------------------------------
> **严禁均匀撒点**。节奏必须是"**成组 — 过渡 — 留白**"。

程序生成感的头号来源就是等距/均匀散点。本模块把"好看"写成可复现的算法：

1. **成组（簇）**：森林不是"一片树"，是"若干簇 + 簇内的子团"。所以密度场是
   三级：`cluster`（大簇，决定林区在哪）→ `subclump`（子团，决定簇内哪几处最密）
   → 逐点接受概率 `w·(1-r)^p`（核心密、边缘疏）。子团这一级是"成组"的关键：
   只有一级衰减的簇会读成一个规整的绿饼，加了子团才有"这里的树挤在一堆、
   那边稀稀拉拉"的读法。
2. **过渡**：密度衰减带（`0.10 ≤ p ≤ 0.34`）里放**孤木**与灌木/枯树/树桩——
   林缘正是"密 → 疏 → 孤木"三段收边的地方。矿脉带同理：岩体（密）→ 散矿
   （疏）→ 碎石（更疏）→ 无。
3. **留白**：显式定义的**林间空地**（clearing）+ 低频噪声开天窗。空地上只有
   草簇和零星巨石，且刻意不放树。四分格统计里的"空格比例"就是留白的量化证据。
4. **散点点缀也要成组**：灌木/岩石不是逐点撒，而是先撒"点缀组中心"，再在组内
   放 2~4 件（`_accent_groups`）。单点均匀分布本身就已经是均匀撒点了。

确定性
------
全部随机走 `random.Random(seed)` + 整数 hash 值噪声（**不用 Python `hash()`**，
它每进程加盐 → 跨进程不可复现）。同一 `seed` 逐实例同结果。

纯 Python + numpy + PIL，**不 import nature / buildings / bpy**，可以脱离 Blender
直接跑（出俯视分布图）。单件尺寸常量在这里复写一份（`FOOT`），是为了不把
bpy 依赖拖进来；口径与 `nature.NOMINAL` 对齐。

跑法（出俯视分布图 + 非均匀性统计）::
    python field_dist.py                 # 默认 seed
    python field_dist.py 12345           # 指定 seed
"""

import math
import os
import random
import sys

import numpy as np

#: PIL 只在出俯视图时用 —— **延迟导入**：Blender 自带 Python 没有 PIL，而
#: probe_nature 需要 import 本模块读分布数据（场景图要照出，不能因缺 PIL 挂掉）。
try:
    from PIL import Image, ImageDraw, ImageFont
except Exception:                                    # pragma: no cover
    Image = ImageDraw = ImageFont = None

M = 130.0 / 1.70        # 1 米 = 76.4706 单位（与 nature.py 同锚）

#: 默认野外区域（单位）：x 214 m 宽、y 72 m 深（含地平线外的余量由探针补）
REGION = {"x": (-8200.0, 8200.0), "y": (-1400.0, 4600.0)}

#: 每类的落地半径（米）与"树冠/体量"半径（米）——排布最小间距 + 俯视图符号大小
FOOT = {
    "broadleaf": (1.1, 3.6), "broadleaf_tall": (0.9, 2.4), "conifer": (0.8, 2.2),
    "dead_tree": (0.6, 1.5), "stump": (0.5, 0.7), "bush": (0.9, 1.1),
    "grass_clump": (0.8, 0.9), "reeds": (1.2, 1.5), "mushrooms": (0.5, 0.6),
    "boulder": (1.6, 2.6), "rubble": (1.1, 1.4),
    "iron_outcrop": (1.1, 1.5), "copper_vein": (1.0, 1.3),
    "gold_vein": (0.8, 1.0), "crystal_cluster": (0.7, 0.8), "ore_band": (3.0, 5.0),
}

#: 森林群系 → 树种权重（与 nature.FOREST_MIX 同口径；核心密处不放地被）
FOREST_MIX = {
    "broadleaf": {"broadleaf": 0.52, "broadleaf_tall": 0.16, "conifer": 0.18,
                  "dead_tree": 0.05, "stump": 0.04, "bush": 0.05},
    "conifer": {"conifer": 0.64, "broadleaf": 0.16, "broadleaf_tall": 0.06,
                "dead_tree": 0.06, "stump": 0.04, "bush": 0.04},
    "mixed": {"broadleaf": 0.40, "broadleaf_tall": 0.12, "conifer": 0.32,
              "dead_tree": 0.05, "stump": 0.04, "bush": 0.07},
}

TREE_KINDS = ("broadleaf", "broadleaf_tall", "conifer", "dead_tree")

#: 森林接受概率的幂次（<1 → 抬高中高密度；见 `_forest_pass`）
PA_EXP = 1.0


# ============================================================ 确定性噪声

def _hash01(ix, iy, seed):
    """整数 hash → [0,1)（uint64 环绕是良定义的，不依赖 Python hash 加盐）。"""
    ix = np.asarray(ix, dtype=np.uint64)
    iy = np.asarray(iy, dtype=np.uint64)
    n = (ix * np.uint64(374761393) + iy * np.uint64(668265263) +
         np.uint64(seed & 0xFFFFFFFF) * np.uint64(1013904223))
    n = (n ^ (n >> np.uint64(13))) * np.uint64(1274126177)
    n = n ^ (n >> np.uint64(16))
    return (n & np.uint64(0xFFFFFF)).astype(np.float64) / float(0x1000000)


def vnoise(x, y, seed):
    """双线性 + smoothstep 值噪声。"""
    x0 = np.floor(x)
    y0 = np.floor(y)
    fx = x - x0
    fy = y - y0
    sx = fx * fx * (3.0 - 2.0 * fx)
    sy = fy * fy * (3.0 - 2.0 * fy)
    xi = x0.astype(np.int64)
    yi = y0.astype(np.int64)
    v00 = _hash01(xi, yi, seed)
    v10 = _hash01(xi + 1, yi, seed)
    v01 = _hash01(xi, yi + 1, seed)
    v11 = _hash01(xi + 1, yi + 1, seed)
    a = v00 + (v10 - v00) * sx
    b = v01 + (v11 - v01) * sx
    return a + (b - a) * sy


def fbm(x, y, seed, octaves=3):
    s = np.zeros_like(np.asarray(x, dtype=np.float64))
    tot = 0.0
    amp = 1.0
    fr = 1.0
    for i in range(octaves):
        s = s + amp * vnoise(x * fr, y * fr, seed + i * 17)
        tot += amp
        amp *= 0.5
        fr *= 2.07
    return s / tot


def _smooth(a, b, v):
    t = np.clip((v - a) / max(1e-9, (b - a)), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


# ============================================================ 场景规划

def _plan_default(seed, region):
    """按 seed 排布大尺度骨架：几个林簇 + 空地 + 两条矿脉带。"""
    rng = random.Random(seed)
    x0, x1 = region["x"]
    y0, y1 = region["y"]
    w = x1 - x0
    d = y1 - y0

    # 空地（留白）：刻意放在两簇之间，制造"成组—留白—成组"的呼吸
    clearings = [
        dict(x=x0 + w * 0.47 + rng.uniform(-0.05, 0.05) * w,
             y=y0 + d * 0.46 + rng.uniform(-0.06, 0.06) * d,
             r=w * rng.uniform(0.085, 0.115), name="main_meadow"),
        dict(x=x0 + w * 0.80 + rng.uniform(-0.03, 0.03) * w,
             y=y0 + d * 0.70 + rng.uniform(-0.05, 0.05) * d,
             r=w * rng.uniform(0.045, 0.065), name="glade"),
    ]

    # 林簇：左大（阔叶）、中（混交）、右后（针叶）；y 偏后，让前景留出草坡
    specs = [
        (x0 + w * 0.14, y0 + d * 0.60, w * 0.185, d * 0.30, "broadleaf"),
        (x0 + w * 0.36, y0 + d * 0.74, w * 0.140, d * 0.24, "mixed"),
        (x0 + w * 0.68, y0 + d * 0.42, w * 0.160, d * 0.27, "conifer"),
        (x0 + w * 0.90, y0 + d * 0.78, w * 0.110, d * 0.20, "mixed"),
    ]
    clusters = []
    for i, (cx, cy, rx, ry, biome) in enumerate(specs):
        r = random.Random(seed * 1000 + i)
        n_sub = r.randint(6, 11)
        subs = []
        # 核心子团（1~2 个，权重高、半径大 → "核心密"）
        for k in range(r.randint(1, 2)):
            subs.append(dict(dx=r.uniform(-0.14, 0.14), dy=r.uniform(-0.12, 0.12),
                             rr=r.uniform(0.28, 0.45), w=r.uniform(1.00, 1.20)))
        for k in range(n_sub):
            a = r.uniform(0.0, 2.0 * math.pi)
            dd = r.uniform(0.10, 0.58)
            subs.append(dict(dx=math.cos(a) * dd, dy=math.sin(a) * dd,
                             rr=r.uniform(0.20, 0.42), w=r.uniform(0.45, 0.95)))
        clusters.append(dict(cx=cx, cy=cy, rx=rx, ry=ry, biome=biome, subs=subs))
    return clusters, clearings


def _plan_bands(seed, region, clusters):
    """矿脉带：走向线 + 带宽。避开林簇核心（矿在裸岩地，不长在树底下）。"""
    rng = random.Random(seed + 77)
    x0, x1 = region["x"]
    y0, y1 = region["y"]
    w = x1 - x0
    d = y1 - y0
    bands = []
    # 主带：横穿左中，轻微斜走向；副带：右后短带
    for (t0, t1, yy, wd, ore, ln_frac) in (
            (0.05, 0.46, 0.30, 0.075, "iron", 0.34),
            (0.56, 0.74, 0.20, 0.048, "copper", 0.16),
            (0.34, 0.44, 0.86, 0.032, "gold", 0.09)):
        ax = x0 + w * t0
        bx = x0 + w * t1
        ay = y0 + d * (yy + rng.uniform(-0.03, 0.03))
        by = y0 + d * (yy + rng.uniform(-0.03, 0.03))
        bands.append(dict(p0=(ax, ay), p1=(bx, by), width=d * wd, ore=ore))
    return bands


# ============================================================ 采样

def _density(px, py, clusters, clearings, seed):
    """森林密度场 ∈ [0,1]：**簇包络 × 子团调制**（核心密、边缘疏、簇内成团）。

    关键设计：子团只做**调制**（`0.30 + 0.70·sub`），不做独立点密度。子团半径
    （10~20 m）比采样格（4~5 m）大得多也只是几十个格，若把它当独立密度场，就等于
    在旷野里撒豆子 —— 大部分子团会整个落在采样格之间被漏掉（这是第一版只剩 3 棵树
    的原因）。包络负责"这片是林区"，子团负责"林区里哪几处树挤在一起"。
    """
    dens = np.zeros_like(px)
    for c in clusters:
        re = np.sqrt(((px - c["cx"]) / c["rx"]) ** 2 +
                     ((py - c["cy"]) / c["ry"]) ** 2)
        # 平顶包络：林内到边缘 26% 才开始收（现实林相就是"内部密、林缘碎"），
        # 只有"核心密、边缘疏"这一条会读成规整绿饼
        base = c.get("w", 1.0) * (1.0 - _smooth(0.26, 1.02, re))
        sub = np.zeros_like(px)
        for s in c["subs"]:
            sx = c["cx"] + s["dx"] * c["rx"]
            sy = c["cy"] + s["dy"] * c["ry"]
            rrx = max(1e-6, s["rr"] * c["rx"])
            rry = max(1e-6, s["rr"] * c["ry"])
            r = np.sqrt(((px - sx) / rrx) ** 2 + ((py - sy) / rry) ** 2)
            sub = np.maximum(sub, s["w"] * np.clip(1.0 - r, 0.0, 1.0) ** 1.20)
        dens = np.maximum(dens, base * (0.58 + 0.42 * sub))
    # 低频开天窗（林缘/林内稀处不规则，不是规整的绿饼）
    n = fbm(px / 4200.0, py / 4200.0, seed + 5, 3)
    dens = dens * (0.70 + 0.30 * _smooth(0.20, 0.72, n))
    # 中频"团中团"（~14 m）：核心区里再分出小团与空隙
    c2 = fbm(px / 1080.0, py / 1080.0, seed + 41, 2)
    dens = dens * (0.58 + 0.42 * _smooth(0.26, 0.68, c2))
    # 空地（留白）：羽化清零
    for cl in clearings:
        r = np.sqrt((px - cl["x"]) ** 2 + (py - cl["y"]) ** 2) / max(1e-6, cl["r"])
        dens = dens * (1.0 - _smooth(0.30, 1.05, 1.15 - r))
    return np.clip(dens, 0.0, 1.0)


def _pick_species(rng, biome, p):
    """按群系权重选树/地被；**边缘（p 小）偏向灌木/枯木/树桩**（过渡带）。"""
    mix = dict(FOREST_MIX[biome])
    if p < 0.34:
        for k, add in (("bush", 0.22), ("dead_tree", 0.05), ("stump", 0.05),
                       ("grass_clump", 0.10)):
            mix[k] = mix.get(k, 0.0) + add
    if p > 0.72:
        for k in ("bush", "grass_clump"):
            mix[k] = mix.get(k, 0.0) * 0.35
    keys = list(mix.keys())
    tot = sum(max(0.0, mix[k]) for k in keys)
    r = rng.uniform(0.0, tot)
    acc = 0.0
    for k in keys:
        acc += max(0.0, mix[k])
        if r <= acc:
            return k
    return keys[-1]


class _Spacer:
    """最小间距检查（带桶的网格；避免树冠互相穿插，也避免"等距"读法）。"""

    def __init__(self, cell):
        self.cell = cell
        self.b = {}

    def ok(self, x, y, r):
        cx = int(math.floor(x / self.cell))
        cy = int(math.floor(y / self.cell))
        for i in range(cx - 2, cx + 3):
            for j in range(cy - 2, cy + 3):
                for (ox, oy, orr) in self.b.get((i, j), ()):
                    if (x - ox) ** 2 + (y - oy) ** 2 < ((r + orr) * 0.75) ** 2:
                        return False
        return True

    def add(self, x, y, r):
        cx = int(math.floor(x / self.cell))
        cy = int(math.floor(y / self.cell))
        self.b.setdefault((cx, cy), []).append((x, y, r))


def _add(inst, kind, x, y, rng, role, cluster=None, biome=None, ore=None,
         scale=1.0, lod="full"):
    inst.append(dict(kind=kind, x=float(x), y=float(y), s=float(scale),
                     seed=int(rng.randrange(1, 10 ** 8)), role=role,
                     cluster=cluster, biome=biome, ore=ore, lod=lod))


def _forest_pass(rng, xs, ys, dens, clusters, region, inst, spacer):
    """主采样：抖动格 + 密度接受 + 最小间距。"""
    for i in range(len(xs)):
        p = float(dens[i])
        # `p ** PA_EXP` 把中高密度整体抬起来（>0.85 的核心真正连成林），
        # 同时严格保持"核心 > 边缘"的序 —— 直接线性接受会让核心也稀稀拉拉。
        if rng.random() > p ** PA_EXP:
            continue
        x, y = float(xs[i]), float(ys[i])
        ci = _nearest_cluster(x, y, clusters)
        biome = clusters[ci]["biome"] if ci is not None else "mixed"
        kind = _pick_species(rng, biome, p)
        foot, crown = FOOT[kind]
        if not spacer.ok(x, y, crown * M):
            continue
        spacer.add(x, y, crown * M)
        s = 1.0
        if kind in TREE_KINDS and rng.random() < 0.18:
            s = rng.uniform(0.78, 0.92)          # 被压制的下层小树
        _add(inst, kind, x, y, rng, "core" if p > 0.45 else "fringe",
             cluster=ci, biome=biome, scale=s)


def _nearest_cluster(x, y, clusters):
    best, bi = 1e18, None
    for i, c in enumerate(clusters):
        r = ((x - c["cx"]) / c["rx"]) ** 2 + ((y - c["cy"]) / c["ry"]) ** 2
        if r < best:
            best, bi = r, i
    return bi


def _transition_pass(rng, xs, ys, dens, clusters, region, inst, spacer):
    """过渡带：孤木 + 灌木组（密→疏→孤木的第三段）。"""
    for i in range(len(xs)):
        p = float(dens[i])
        if not (0.09 <= p <= 0.32):
            continue
        if rng.random() > 0.075:
            continue
        x, y = float(xs[i]), float(ys[i])
        ci = _nearest_cluster(x, y, clusters)
        if rng.random() < 0.42:
            kind = rng.choice(("broadleaf", "broadleaf_tall", "conifer"))
            foot, crown = FOOT[kind]
            if spacer.ok(x, y, crown * M * 1.2):
                spacer.add(x, y, crown * M * 1.2)
                _add(inst, kind, x, y, rng, "solitary", cluster=ci,
                     biome=(clusters[ci]["biome"] if ci is not None else "mixed"),
                     scale=rng.uniform(1.0, 1.2), lod="full")
        else:
            _accent_group(rng, x, y, inst, spacer, cluster=ci, role="fringe")


def _accent_group(rng, x, y, inst, spacer, cluster=None, role="accent",
                  kinds=None):
    """**成组的点缀**：组中心 + 2~4 件组内件（散点也要成组，禁止单点均匀撒）。"""
    kinds = kinds or (("bush", 0.42), ("grass_clump", 0.24), ("boulder", 0.14),
                      ("rubble", 0.12), ("dead_tree", 0.08))
    n = rng.randint(2, 4)
    for i in range(n):
        a = rng.uniform(0.0, 2.0 * math.pi)
        dd = rng.uniform(0.0, 1.0) * (2.2 if i else 0.6) * M
        px, py = x + math.cos(a) * dd, y + math.sin(a) * dd
        kind = _weighted(rng, kinds)
        foot, crown = FOOT[kind]
        if not spacer.ok(px, py, crown * M):
            continue
        spacer.add(px, py, crown * M)
        _add(inst, kind, px, py, rng, role, cluster=cluster)


def _weighted(rng, pairs):
    tot = sum(w for _, w in pairs)
    r = rng.uniform(0.0, tot)
    acc = 0.0
    for k, w in pairs:
        acc += w
        if r <= acc:
            return k
    return pairs[-1][0]


def _accent_scatter(rng, region, clusters, inst, spacer):
    """区域级散点点缀：先撒"点缀组中心"（低频噪声门控 → 成群），组内再放件。"""
    x0, x1 = region["x"]
    y0, y1 = region["y"]
    gx = np.arange(x0 + 300.0, x1, 1200.0)
    gy = np.arange(y0 + 260.0, y1, 1050.0)
    GX, GY = np.meshgrid(gx, gy)
    mask = fbm(GX / 7000.0, GY / 7000.0, 991, 2)
    keep = mask > 0.56
    for i in range(GX.size):
        if not keep.flat[i]:
            continue
        if rng.random() > 0.55:
            continue
        x = float(GX.flat[i]) + rng.uniform(-520, 520)
        y = float(GY.flat[i]) + rng.uniform(-460, 460)
        # 林区内部交给 _forest_pass，这里只做林外的荒地/草坡点缀
        if _density(np.array([x]), np.array([y]), clusters, [], 0)[0] > 0.30:
            continue
        _accent_group(rng, x, y, inst, spacer, role="accent",
                      kinds=(("bush", 0.34), ("grass_clump", 0.30),
                             ("boulder", 0.16), ("rubble", 0.12),
                             ("crystal_cluster", 0.05), ("mushrooms", 0.03)))


def _band_pass(rng, bands, clusters, region, inst, spacer):
    """矿脉带：岩体成簇 → 散矿 → 碎石过渡（越远越稀）。"""
    for bi, bd in enumerate(bands):
        (ax, ay), (bx, by) = bd["p0"], bd["p1"]
        ln = math.hypot(bx - ax, by - ay)
        ca, sa = (bx - ax) / ln, (by - ay) / ln
        half = bd["width"] * 0.5
        ore = bd["ore"]
        core_kind = {"iron": "iron_outcrop", "copper": "copper_vein",
                     "gold": "gold_vein"}[ore]
        n_out = max(3, int(ln / (9.0 * M)))
        anchor_pts = []
        for i in range(n_out):
            t = (i + rng.uniform(0.15, 0.85)) / n_out
            off = rng.gauss(0.0, half * 0.55)
            px = ax + ca * ln * t - sa * off
            py = ay + sa * ln * t + ca * off
            if _density(np.array([px]), np.array([py]), clusters, [], 0)[0] > 0.55:
                continue                                   # 不长在林芯里
            anchor_pts.append((px, py))
        # 岩体主锚：1~3 处成簇（"矿 1~3 处成脉"）
        for (px, py) in anchor_pts:
            if rng.random() < 0.75:
                _add(inst, core_kind, px, py, rng, "ore_core", ore=ore)
            # 伴生矿石簇（成组）
            for q in range(rng.randint(2, 5)):
                a = rng.uniform(0.0, 2.0 * math.pi)
                dd = rng.uniform(0.6, 2.6) * M
                ox, oy = px + math.cos(a) * dd, py + math.sin(a) * dd
                kind = core_kind if rng.random() < 0.35 else "rubble"
                _add(inst, kind, ox, oy, rng, "ore_cluster", ore=ore,
                     scale=rng.uniform(0.7, 1.05))
            # 碎石过渡：环绕 3~6 m，越远越稀
            for q in range(rng.randint(4, 8)):
                a = rng.uniform(0.0, 2.0 * math.pi)
                dd = rng.uniform(1.5, 7.0) * M * rng.uniform(0.5, 1.0)
                if rng.random() > max(0.08, 1.0 - dd / (6.5 * M)):
                    continue
                _add(inst, "rubble" if rng.random() < 0.7 else "boulder",
                     px + math.cos(a) * dd, py + math.sin(a) * dd, rng,
                     "ore_verge", ore=ore, scale=rng.uniform(0.5, 0.9),
                     lod="simple")
        # 带内的地表矿脉带节点（把"岩体 → 荒地"接起来）
        for i in range(max(1, n_out // 3)):
            t = (i + rng.uniform(0.1, 0.9)) / max(1, n_out // 3)
            px = ax + ca * ln * t - sa * rng.uniform(-half, half) * 0.6
            py = ay + sa * ln * t + ca * rng.uniform(-half, half) * 0.6
            _add(inst, "ore_band", px, py, rng, "ore_band", ore=ore,
                 scale=rng.uniform(0.7, 1.1))


def _landmarks(rng, clusters, clearings, region, inst):
    """视线锚：空地边缘 / 簇间的孤立大件（巨树、立石、水晶）。"""
    for cl in clearings:
        a = rng.uniform(0.0, 2.0 * math.pi)
        x = cl["x"] + math.cos(a) * cl["r"] * 1.25
        y = cl["y"] + math.sin(a) * cl["r"] * 0.75
        _add(inst, rng.choice(("boulder", "broadleaf")), x, y, rng, "landmark",
             scale=rng.uniform(1.05, 1.25))
    x0, x1 = region["x"]
    y0, y1 = region["y"]
    for i in range(2):
        _add(inst, rng.choice(("boulder", "crystal_cluster", "dead_tree")),
             rng.uniform(x0 + 0.12 * (x1 - x0), x0 + 0.88 * (x1 - x0)),
             rng.uniform(y0 + 0.10 * (y1 - y0), y0 + 0.50 * (y1 - y0)),
             rng, "landmark", scale=rng.uniform(1.0, 1.3))


def generate(seed=0, region=None, cell_m=3.8, clusters=None, clearings=None,
             bands=None, accents=True, landmarks=True):
    """生成野外分布：返回 {instances, clusters, clearings, bands, region, stats}。"""
    region = region or REGION
    x0, x1 = region["x"]
    y0, y1 = region["y"]
    rng = random.Random(seed)
    if clusters is None or clearings is None:
        clusters, clearings = _plan_default(seed, region)
    if bands is None:
        bands = _plan_bands(seed, region, clusters)

    cell = cell_m * M
    gx = np.arange(x0 + cell * 0.5, x1, cell)
    gy = np.arange(y0 + cell * 0.5, y1, cell)
    GX, GY = np.meshgrid(gx, gy)
    n = GX.size
    # 抖动格（格内随机 ±0.42 格）——格点本身规则，抖动 + 密度接受一起打破它
    jit = np.array([rng.uniform(-0.42, 0.42) * cell for _ in range(2 * n)])
    xs = (GX + jit[:n].reshape(GX.shape)).ravel()
    ys = (GY + jit[n:].reshape(GY.shape)).ravel()
    dens = _density(xs, ys, clusters, clearings, seed)

    inst = []
    spacer = _Spacer(cell)
    _forest_pass(rng, xs, ys, dens, clusters, region, inst, spacer)
    _transition_pass(rng, xs, ys, dens, clusters, region, inst, spacer)
    if accents:
        _accent_scatter(rng, region, clusters, inst, spacer)
    _band_pass(rng, bands, clusters, region, inst, spacer)
    if landmarks:
        _landmarks(rng, clusters, clearings, region, inst)

    gen = dict(instances=inst, clusters=clusters, clearings=clearings,
               bands=bands, region=region, seed=seed, density=(xs, ys, dens))
    gen["stats"] = stats(gen)
    return gen


# ============================================================ 统计 / 取窗

def stats(gen):
    """非均匀性证据：四分格离散指数 + 最近邻距离 CV + 空格比例。

    均匀撒点的四分格计数方差≈0（离散指数≈0）；成簇分布的离散指数远大于 1。
    最近邻距离的变异系数同理（均匀 → 0，成簇 → 明显大于 0）。
    """
    region = gen["region"]
    x0, x1 = region["x"]
    y0, y1 = region["y"]
    trees = [i for i in gen["instances"] if i["kind"] in TREE_KINDS]
    nx, ny = 12, 6
    counts = [0] * (nx * ny)
    for t in trees:
        ix = min(nx - 1, max(0, int((t["x"] - x0) / (x1 - x0) * nx)))
        iy = min(ny - 1, max(0, int((t["y"] - y0) / (y1 - y0) * ny)))
        counts[ix * ny + iy] += 1
    mean = sum(counts) / float(len(counts))
    var = sum((c - mean) ** 2 for c in counts) / float(len(counts))
    idx = (var / mean) if mean > 1e-9 else 0.0
    empty = sum(1 for c in counts if c == 0) / float(len(counts))

    pts = [(t["x"], t["y"]) for t in trees]
    nn = []
    for i, (ax, ay) in enumerate(pts):
        best = 1e18
        for j, (bx, by) in enumerate(pts):
            if i == j:
                continue
            d = (ax - bx) ** 2 + (ay - by) ** 2
            if d < best:
                best = d
        if best < 1e17:
            nn.append(math.sqrt(best))
    if nn:
        mnn = sum(nn) / len(nn)
        sd = math.sqrt(sum((v - mnn) ** 2 for v in nn) / len(nn))
        cv = sd / mnn if mnn > 1e-9 else 0.0
    else:
        mnn, cv = 0.0, 0.0
    by_kind = {}
    for i in gen["instances"]:
        by_kind[i["kind"]] = by_kind.get(i["kind"], 0) + 1
    return dict(n_total=len(gen["instances"]), n_trees=len(trees),
                n_kinds=len(by_kind), by_kind=by_kind,
                quadrat_index=idx, quadrat_empty=empty,
                nn_mean_m=mnn / M, nn_cv=cv)


def window(gen, x0, x1, y0=None, y1=None):
    """取窗口内的实例（探针切场景用；y 省略 = 全部）。"""
    out = []
    for i in gen["instances"]:
        if not (x0 <= i["x"] <= x1):
            continue
        if y0 is not None and not (y0 <= i["y"] <= y1):
            continue
        out.append(i)
    return out


# ============================================================ 俯视分布图

_PAL = {
    "broadleaf": (44, 92, 48), "broadleaf_tall": (58, 108, 56),
    "conifer": (26, 66, 52), "dead_tree": (104, 92, 74),
    "stump": (122, 100, 70), "bush": (96, 140, 70),
    "grass_clump": (150, 176, 104), "reeds": (128, 166, 96),
    "mushrooms": (196, 120, 108), "boulder": (132, 130, 126),
    "rubble": (154, 150, 142), "iron_outcrop": (150, 78, 54),
    "copper_vein": (74, 168, 142), "gold_vein": (206, 176, 72),
    "crystal_cluster": (120, 178, 226), "ore_band": (168, 104, 66),
}
_ORE_BAND_COLOR = {"iron": (150, 74, 52), "copper": (64, 158, 134),
                   "gold": (204, 172, 68)}


def plan_png(gen, path, px_per_unit=0.115, max_w=1900):
    """俯视分布图：密度场渐变（核心→边缘）+ 空地 + 实例符号 + 图例/统计。"""
    if Image is None:
        print("[field_dist] 无 PIL，跳过俯视图（用系统 python 跑 field_dist.py 出图）")
        return {"path": None, "res": (0, 0), "stats": gen.get("stats")}
    region = gen["region"]
    x0, x1 = region["x"]
    y0, y1 = region["y"]
    w, d = x1 - x0, y1 - y0
    sc = min(px_per_unit, max_w / float(w))
    W, H = int(round(w * sc)), int(round(d * sc))
    SX = lambda x: (x - x0) * sc
    SY = lambda y: H - (y - y0) * sc

    img = Image.new("RGB", (W, H), (196, 182, 150))
    # 地面底色微纹理
    yy, xx = np.mgrid[0:H, 0:W]
    tex = (fbm(xx / 90.0, yy / 90.0, 4321, 3) - 0.5) * 26.0
    base = np.zeros((H, W, 3), dtype=np.float64)
    base[..., 0] = 198 + tex
    base[..., 1] = 184 + tex
    base[..., 2] = 150 + tex
    img = Image.fromarray(np.clip(base, 0, 255).astype(np.uint8))

    # 森林密度场（半透明绿，核心浓边淡）——把"核心密、边缘疏"直接画出来
    gw = 560
    gh = max(64, int(round(gw * d / float(w))))
    gxx = np.linspace(x0, x1, gw)
    gyy = np.linspace(y0, y1, gh)
    GDX, GDY = np.meshgrid(gxx, gyy)
    dimg = _density(GDX.ravel(), GDY.ravel(), gen["clusters"], gen["clearings"],
                    gen["seed"]).reshape(gh, gw)[::-1]
    mask = Image.fromarray((np.clip(dimg, 0.0, 1.0) * 255).astype(np.uint8))
    ov = np.asarray(mask.resize((W, H), Image.BILINEAR)).astype(np.float64) / 255.0
    arr = np.asarray(img).astype(np.float64)
    green = np.array([58, 104, 52], dtype=np.float64)
    a = (ov * 0.58)[..., None]
    arr = arr * (1 - a) + green[None, None, :] * a
    # 空地（留白）：提亮 + 淡黄
    for cl in gen["clearings"]:
        rr = cl["r"] * sc
        cx, cy = SX(cl["x"]), SY(cl["y"])
        gx0, gx1 = max(0, int(cx - rr)), min(W, int(cx + rr) + 1)
        gy0, gy1 = max(0, int(cy - rr)), min(H, int(cy + rr) + 1)
        if gx0 >= gx1 or gy0 >= gy1:
            continue
        syy, sxx = np.mgrid[gy0:gy1, gx0:gx1]
        m = (((sxx - cx) ** 2 + (syy - cy) ** 2) <= rr ** 2).astype(np.float64)
        m = m * 0.60
        arr[gy0:gy1, gx0:gx1] = (arr[gy0:gy1, gx0:gx1] * (1 - m[..., None]) +
                                 np.array([216, 200, 138])[None, None, :] * m[..., None])
    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))
    dr = ImageDraw.Draw(img)

    # 矿脉带：底线 + 带域
    for bd in gen["bands"]:
        (ax, ay), (bx, by) = bd["p0"], bd["p1"]
        col = _ORE_BAND_COLOR[bd["ore"]]
        ln = math.hypot(bx - ax, by - ay)
        ca, sa = (bx - ax) / ln, (by - ay) / ln
        hw = bd["width"] * 0.5 * sc
        quad = [(SX(ax - sa * hw), SY(ay + ca * hw)),
                (SX(bx - sa * hw), SY(by + ca * hw)),
                (SX(bx + sa * hw), SY(by - ca * hw)),
                (SX(ax + sa * hw), SY(ay - ca * hw))]
        dr.polygon(quad, fill=tuple(int(c * 0.55 + 196 * 0.45) for c in col))
        dr.line([(SX(ax), SY(ay)), (SX(bx), SY(by))], fill=col, width=2)

    # 实例符号（先画小的，后画大的）
    order = {k: i for i, k in enumerate(
        ("grass_clump", "mushrooms", "reeds", "rubble", "bush", "stump",
         "crystal_cluster", "gold_vein", "copper_vein", "iron_outcrop",
         "ore_band", "dead_tree", "conifer", "broadleaf_tall", "broadleaf",
         "boulder"))}
    for it in sorted(gen["instances"], key=lambda z: order.get(z["kind"], 99)):
        kind = it["kind"]
        col = _PAL.get(kind, (120, 120, 120))
        foot, crown = FOOT[kind]
        r = max(1.6, crown * M * it["s"] * sc * 0.55)
        cx, cy = SX(it["x"]), SY(it["y"])
        if kind in TREE_KINDS or kind == "boulder":
            dr.ellipse([cx - r, cy - r, cx + r, cy + r], fill=col,
                       outline=(28, 40, 26))
        elif kind == "ore_band":
            dr.rectangle([cx - r, cy - r * 0.5, cx + r, cy + r * 0.5], fill=col)
        else:
            dr.ellipse([cx - r, cy - r, cx + r, cy + r], fill=col)
        if it["role"] == "landmark":
            dr.ellipse([cx - r * 2.0, cy - r * 2.0, cx + r * 2.0, cy + r * 2.0],
                       outline=(180, 40, 40), width=2)

    # 图例 / 统计
    try:
        font = ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", 15)
        fsm = ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", 13)
    except Exception:
        font = ImageFont.load_default()
        fsm = font
    st = gen["stats"]
    leg = [("森林核心（阔叶/针叶成簇）", _PAL["broadleaf"]),
           ("林缘孤木 / 过渡", _PAL["bush"]),
           ("矿脉露头（铁/铜/金）", _PAL["iron_outcrop"]),
           ("碎石过渡 / 巨石", _PAL["rubble"]),
           ("空地留白（禁放树）", (216, 200, 138)),
           ("视线锚（巨树/立石/晶簇）", (180, 40, 40))]
    bx, by = 14, 12
    dr.rectangle([bx - 6, by - 6, bx + 430, by + 24 * len(leg) + 34],
                 fill=(246, 242, 230), outline=(90, 86, 74))
    for i, (t, c) in enumerate(leg):
        yy2 = by + 22 * i
        dr.rectangle([bx, yy2 - 4, bx + 16, yy2 + 10], fill=c, outline=(60, 58, 50))
        dr.text((bx + 24, yy2 - 5), t, fill=(40, 38, 32), font=fsm)
    yy2 = by + 22 * len(leg) + 6
    dr.text((bx, yy2), "四分格离散指数 %.1f（均匀≈0，成簇≫1）  空格比例 %.0f%%  "
                      "最近邻 CV %.2f  实例 %d 件（树 %d）"
            % (st["quadrat_index"], st["quadrat_empty"] * 100,
               st["nn_cv"], st["n_total"], st["n_trees"]),
            fill=(60, 56, 46), font=fsm)
    dr.text((W - 300, H - 26), "seed=%d  俯视分布（非游戏内视角）" % gen["seed"],
            fill=(70, 66, 56), font=fsm)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)
    return {"path": path, "res": (W, H), "stats": st}


# ============================================================ 主 / 自检

if __name__ == "__main__":
    sd = int(sys.argv[1]) if len(sys.argv) > 1 else 20260913
    g = generate(seed=sd)
    st = g["stats"]
    print("field_dist seed=%d：%d 件（树 %d，%d 类）" %
          (sd, st["n_total"], st["n_trees"], st["n_kinds"]))
    print("  四分格离散指数 %.2f（均匀≈0 / 成簇≫1）  空格比例 %.0f%%  最近邻 CV %.2f"
          % (st["quadrat_index"], st["quadrat_empty"] * 100, st["nn_cv"]))
    for k in sorted(st["by_kind"]):
        print("    %-16s %3d" % (k, st["by_kind"][k]))
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "..", "stick-world", "temp",
                       "pbr_field_dist_plan.png")
    r = plan_png(g, os.path.abspath(out))
    print("-> %s  %dx%d" % (r["path"], r["res"][0], r["res"][1]))
