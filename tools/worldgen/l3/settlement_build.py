"""世界重生成 v2 A3：聚落生成（settlement_build.py）

变半径泊松盘选址 + 对数正态规模谱（算法提案 §A3，已圈选定案）：
  1. 选址：变半径 Bridson 泊松盘。盘半径由局部宜居度映射（宜居 → 小半径密集，
     suit < suit_min → 直接无聚落 = 荒地，由阈值自然产生不后处理）；候选在活跃点
     annulus [r, 2r] 内生成，冲突判据 = 与既有点距离 < max(候选半径, 既有点半径)
     （变半径保守判据）。种子池大数量随机点保底孤岛/半岛连通域覆盖——池点逐个
     尝试落点（过掩膜/宜居度阈值/冲突检查），落住的点进活跃列表做 Bridson 扩张。
     坐标全程在 8192 级像素空间连续计算（标量运算，无大数组），场值自 2048 级
     采样（bilinear / 最近邻）——位置精度约 ±4px，见产物 meta。
  2. 规模：population_score = clamp(h × LogNormal(μ_b, σ_b), 0, 1)。
     h = h_w_suit×窗口宜居度 + h_w_res×tanh(窗口资源加权和/gain_norm)——窗口 =
     window_px（2048 级）方形窗的陆内均值（summed-area table O(1) 查询）；
     μ_b 按全局陆地宜居度分位分带（band_quantiles 切带，贫瘠带整体左移、
     富庶带右移）——地区内对数正态（多数小村少数大城）、地区间基线差异化。
  3. 档位：level 阈值 0.187/0.342（场景口径，与 world_contract_initializer
     的 LEVEL2/3_PS_MIN 同值，全球单一口径）；4/5 档不产生（留人口成长）。
  4. 文化：从 culture_field / culture_mix 采样主导文化 + 混合度（城级相似度
     消费口径 = 各自主导文化相似度 × (1−各自混合度)，见 culture_similarity.json，
     A4 用）。
  5. 荒地：不产聚落条目即荒地（无主地语义在 A4 政治分配生效）；meta 统计
     荒地率 = 宜居陆地中聚落「主张盘」未覆盖占比——主张半径 = min(泊松盘半径,
     claim_cap_px) × claim_scale（现行 1.3，直径 +30%）（泊松半径是「下一个聚落至少多远」的排除半径，不作主张用；
     主张封顶让贫瘠带大间距聚落之间留下成片无主荒地，富庶带小间距自然铺满）。
  6. id：label 1..N 连续（按 y,x 读序），settlement_id = settlement_city_%03d
     （沿用 political_data.city_owners 编号体系）。出生 8 城邦特殊态取消，
     全域统一规格——全新聚落集，不从旧 city_json 继承。

产物（tools/worldgen/output/fields/，gitignored 不入库）：
  settlements_v2.json（城列表 label/settlement_id/x/y/level/population_score/
  dominant/mix + meta 参数与统计）
预览（数据自检用，2048 级）：
  settlements_preview_locations_2048.png（点大小=规模、色=level，叠宜居度淡底）
  settlements_preview_density_2048.png（网格计数核密度）

用法：
  python settlement_build.py [--skip-preview]
依赖 fields_build.py / culture_build.py 先行产出；同 seed 逐位确定（确定性
自检含两次全量构建逐位对比，见 settlement_check.py）。
"""

import argparse
import json
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import gaussian_filter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fields_common as fc  # noqa: E402

K_FIELD = fc.SIZE_FULL // fc.SIZE  # 4：8192 坐标 → 2048 场网格缩比


# ---------- 场载入（2048 级工作集） ----------

def _sub4(path):
    """8192² npy → [::4,::4] 块抽取 2048²（float16 逐个加载即刻释放）。"""
    a = np.load(path)
    s = np.ascontiguousarray(a[::4, ::4])
    del a
    return s


def load_fields_2048():
    """A1/A2 产物 + 底图掩膜（2048 级工作集）。

    culture_field 是 2048 块复制上采样场，[::4,::4] 抽取即精确原值；连续场
    （suitability/资源/mix）在生成链内已平滑，抽样点足够。
    """
    suit = _sub4(os.path.join(fc.FIELDS_DIR, "suitability.npy")).astype(np.float32)
    res = {n: _sub4(os.path.join(fc.FIELDS_DIR, n + ".npy")).astype(np.float32)
           for n in ("mineral", "fertile", "forest", "fishsalt")}
    dom = _sub4(os.path.join(fc.FIELDS_DIR, "culture_field.npy")).astype(np.int32)
    mix = _sub4(os.path.join(fc.FIELDS_DIR, "culture_mix.npy")).astype(np.float32)
    biome = np.load(os.path.join(fc.OUTPUT_DIR, "biome_labels_2048.npy"))
    lake = np.asarray(Image.open(
        os.path.join(fc.OUTPUT_DIR, "fractal_lake_mask_8192.png")).convert("L"))
    lake = np.asarray(Image.fromarray(lake).resize(
        (fc.SIZE, fc.SIZE), Image.NEAREST)) > 0
    eff_land = (biome > 0) & (~lake)   # 底图原生掩膜（群系陆地排除湖泊），非场隐式掩膜
    return suit, res, dom, mix, biome, eff_land


# ---------- 采样工具 ----------

def bilinear_at(f, x, y):
    """2048 场在 8192 坐标 (x, y) 处的双线性采样（标量，供泊松盘热路径用）。"""
    u = min(max(x / K_FIELD - 0.5, 0.0), fc.SIZE - 1.001)
    v = min(max(y / K_FIELD - 0.5, 0.0), fc.SIZE - 1.001)
    iu, iv = int(u), int(v)
    fu, fv = u - iu, v - iv
    a = f[iv, iu] + (f[iv, iu + 1] - f[iv, iu]) * fu
    b = f[iv + 1, iu] + (f[iv + 1, iu + 1] - f[iv + 1, iu]) * fu
    return float(a + (b - a) * fv)


def build_sat(field, mask):
    """陆内均值 summed-area table：(sum, cnt) 双 SAT（float64，2048 级）。"""
    sat = np.zeros((fc.SIZE + 1, fc.SIZE + 1), dtype=np.float64)
    sat[1:, 1:] = (field * mask).astype(np.float64).cumsum(axis=0).cumsum(axis=1)
    csat = np.zeros((fc.SIZE + 1, fc.SIZE + 1), dtype=np.float64)
    csat[1:, 1:] = mask.astype(np.float64).cumsum(axis=0).cumsum(axis=1)
    return sat, csat


def sat_mean(sat, csat, cx, cy, half):
    """2048 坐标 (cx, cy) 的 (2·half+1)² 方窗陆内均值（窗口越界自动收缩）。"""
    x0, x1 = max(cx - half, 0), min(cx + half + 1, fc.SIZE)
    y0, y1 = max(cy - half, 0), min(cy + half + 1, fc.SIZE)
    s = sat[y1, x1] - sat[y0, x1] - sat[y1, x0] + sat[y0, x0]
    c = csat[y1, x1] - csat[y0, x1] - csat[y1, x0] + csat[y0, x0]
    return float(s / max(c, 1.0))


# ---------- 变半径泊松盘 ----------

def radius_at(suit_val, sp):
    """局部宜居度 → 盘半径（8192 级像素）：suit=suit_min → r_max（近荒地极稀疏），
    suit=1 → r_min（富庶密集）；suit ≤ suit_min → 无穷（无聚落=荒地）。"""
    t = (suit_val - float(sp["suit_min"])) / (1.0 - float(sp["suit_min"]))
    if t <= 0.0:
        return math.inf
    lo, hi = float(sp["r_min_px"]), float(sp["r_max_px"])
    return hi - (hi - lo) * (min(t, 1.0) ** float(sp["radius_curve"]))


def poisson_disk(suit, eff_land, sp, rng):
    """变半径 Bridson 泊松盘（8192 坐标空间）。返回 [(x, y, r, suit_val)]（接受序）。

    种子池 n_pool 个全域随机点逐个尝试落点（保底孤岛/半岛连通域），落住的点
    进活跃列表；活跃列表标准 Bridson 扩张：随机挑活跃点，annulus [r, 2r] 内试
    candidates_per_active 个候选，全败则出列。max_total_attempts 硬上限防病态参数。
    """
    k_try = int(sp["candidates_per_active"])
    max_attempts = int(sp["max_total_attempts"])
    attempts = 0
    px, py, pr = [], [], []          # 已接受点（8192 坐标 + 盘半径）
    active = []                      # 活跃列表（存 px 的下标）
    cpx = np.empty(0)                # 已接受点的 numpy 视角（每次接受后重建）
    cpy = np.empty(0)
    cpr = np.empty(0)

    def conflicts(x, y, r):
        if cpx.size == 0:
            return False
        d2 = (cpx - x) ** 2 + (cpy - y) ** 2
        need = np.maximum(cpr, r)
        return bool((d2 < need * need).any())

    def try_accept(x, y):
        """候选点 = 掩膜内陆地 + 宜居度阈值上 + 无冲突；通过则落点入活跃列表。"""
        nonlocal cpx, cpy, cpr, attempts
        attempts += 1
        if not (0.0 <= x < fc.SIZE_FULL and 0.0 <= y < fc.SIZE_FULL):
            return False
        if not eff_land[int(y) // K_FIELD, int(x) // K_FIELD]:
            return False
        s = bilinear_at(suit, x, y)
        r = radius_at(s, sp)
        if not math.isfinite(r) or conflicts(x, y, r):
            return False
        px.append(x)
        py.append(y)
        pr.append(r)
        active.append(len(px) - 1)
        cpx, cpy, cpr = np.array(px), np.array(py), np.array(pr)
        return True

    # 种子池：全域均匀随机点，确定性乱序逐个尝试（池点之间也互斥，同盘判据）
    xs = rng.integers(0, fc.SIZE_FULL, size=int(sp["seed_pool"]))
    ys = rng.integers(0, fc.SIZE_FULL, size=int(sp["seed_pool"]))
    for idx in rng.permutation(int(sp["seed_pool"])):
        if attempts >= max_attempts:
            break
        try_accept(float(xs[idx]), float(ys[idx]))

    # Bridson 主循环：活跃点 annulus [r, 2r] 试候选，全败出列
    while active and attempts < max_attempts:
        ai = active[int(rng.integers(0, len(active)))]
        cx, cy, cr = px[ai], py[ai], pr[ai]
        placed = False
        for _ in range(k_try):
            if attempts >= max_attempts:
                break
            ang = rng.random() * 2.0 * math.pi
            d = cr * math.sqrt(1.0 + 3.0 * rng.random())
            if try_accept(cx + d * math.cos(ang), cy + d * math.sin(ang)):
                placed = True
                break
        if not placed:
            active.remove(ai)

    return [(px[i], py[i], pr[i], bilinear_at(suit, px[i], py[i]))
            for i in range(len(px))], attempts


# ---------- 规模谱 ----------

def level_of(score, thr):
    """population_score → level（场景口径单一边界；4/5 档留人口成长不产生）。"""
    return 1 if score < float(thr[0]) else (2 if score < float(thr[1]) else 3)


def score_settlements(points, suit, res, eff_land, sp, rng):
    """窗口环境 → h → population_score（clamp [0,1]）。

    points 已按 (y, x) 排序（label 序 = rng 消费序，保证确定性口径唯一）。
    返回 [(score, h, band)]。μ 分带边界 = 全局陆地宜居度分位（band_quantiles）。
    """
    half = int(sp["window_px"]) // 2
    w_res = {k: float(v) for k, v in sp["resource_weights"].items()}
    gain = (w_res["mineral"] * res["mineral"] + w_res["fertile"] * res["fertile"]
            + w_res["forest"] * res["forest"] + w_res["fishsalt"] * res["fishsalt"])
    suit_sat, suit_cnt = build_sat(suit, eff_land)
    gain_sat, gain_cnt = build_sat(gain, eff_land)
    edges = np.quantile(suit[eff_land].astype(np.float64),
                        [float(q) for q in sp["band_quantiles"]])
    mus = [float(m) for m in sp["mu_by_band"]]
    if len(mus) != len(sp["band_quantiles"]) + 1:
        raise ValueError("mu_by_band 段数须 = band_quantiles 数 + 1")
    sigma = float(sp["sigma_b"])
    hw_s, hw_r = float(sp["h_w_suit"]), float(sp["h_w_res"])
    gain_norm = float(sp["gain_norm"])

    out = []
    for x, y, _r, _s in points:
        cx, cy = int(round(x / K_FIELD)), int(round(y / K_FIELD))
        sw = sat_mean(suit_sat, suit_cnt, cx, cy, half)
        gw = sat_mean(gain_sat, gain_cnt, cx, cy, half)
        h = min(max(hw_s * sw + hw_r * math.tanh(gw / gain_norm), 0.0), 1.0)
        band = int(np.searchsorted(edges, sw))
        score = min(h * float(rng.lognormal(mus[band], sigma)), 1.0)
        out.append((score, h, band))
    return out


# ---------- 覆盖 / 统计 ----------

def coverage_mask(points, eff_land, claim_cap_px):
    """聚落「主张盘」并集覆盖（荒地率的度量域）：主张半径 = min(泊松半径,
    claim_cap_px)——泊松半径是排除半径（下一个聚落至少多远），主张封顶后
    贫瘠带大间距聚落之间自然留出成片荒地、富庶带小间距自动铺满。"""
    cov = np.zeros((fc.SIZE, fc.SIZE), dtype=bool)
    for x, y, r, _s in points:
        cx, cy, rr = x / K_FIELD, y / K_FIELD, min(r, claim_cap_px) / K_FIELD
        x0, x1 = max(int(cx - rr), 0), min(int(cx + rr) + 1, fc.SIZE)
        y0, y1 = max(int(cy - rr), 0), min(int(cy + rr) + 1, fc.SIZE)
        if x1 <= x0 or y1 <= y0:
            continue
        yy, xx = np.ogrid[y0:y1, x0:x1]
        cov[y0:y1, x0:x1] |= (yy - cy) ** 2 + (xx - cx) ** 2 <= rr * rr
    return cov


def quantiles(v):
    q = np.quantile(np.asarray(v, dtype=np.float64), [0.1, 0.25, 0.5, 0.75, 0.9])
    return {"p10": round(float(q[0]), 4), "p25": round(float(q[1]), 4),
            "p50": round(float(q[2]), 4), "p75": round(float(q[3]), 4),
            "p90": round(float(q[4]), 4)}


# ---------- 主构建（纯函数：settlement_check 两次调用做逐位确定性对比） ----------

def build(P):
    """读场 → 泊松盘选址 → 规模/文化采样 → (settlements 列表, stats, points)。"""
    sp = P["fields_v2"]["settlements"]
    rng = np.random.default_rng(int(sp["seed"]))
    suit, res, dom, mix, biome, eff_land = load_fields_2048()

    # 1) 变半径泊松盘选址
    points, attempts = poisson_disk(suit, eff_land, sp, rng)
    # label 序 = 按 (y, x) 读序（与采样序解耦，参数微调下编号更稳）
    points.sort(key=lambda p: (p[1], p[0]))

    # 2) 规模谱（在 label 序上消费 rng，逐位确定）
    scored = score_settlements(points, suit, res, eff_land, sp, rng)
    thr = sp["level_thresholds"]
    n_cult = int(dom.max())
    settlements = []
    for i, ((x, y, r, s_local), (score, h, band)) in enumerate(zip(points, scored)):
        cx, cy = int(x) // K_FIELD, int(y) // K_FIELD
        settlements.append({
            "label": i + 1,
            "settlement_id": "settlement_city_%03d" % (i + 1),
            "x": int(round(x)),
            "y": int(round(y)),
            "level": level_of(score, thr),
            "population_score": round(score, 4),
            "dominant": int(dom[cy, cx]),
            "mix": round(float(mix[cy, cx]), 3),
        })

    # 3) 统计：level 谱 / 规模谱 / 分带表 / 分群系密度 / 荒地率 / 文化分布
    n = len(settlements)
    lv_hist = {1: 0, 2: 0, 3: 0}
    for s in settlements:
        lv_hist[s["level"]] += 1
    scores = [s["population_score"] for s in settlements]
    hs = [h for _sc, h, _b in scored]
    band_table = []
    for b, mu in enumerate([float(m) for m in sp["mu_by_band"]]):
        ss = [s["population_score"] for s, (_sc, _h, bb) in zip(settlements, scored)
              if bb == b]
        band_table.append({
            "band": b, "mu": mu, "count": len(ss),
            "score_mean": round(float(np.mean(ss)), 4) if ss else 0.0,
            "score_median": round(float(np.median(ss)), 4) if ss else 0.0,
        })

    biome_dens = []
    for b in range(1, 7):
        m = eff_land & (biome == b)
        px = int(m.sum())
        cnt = sum(1 for s in settlements if biome[int(s["y"]) // K_FIELD,
                                                   int(s["x"]) // K_FIELD] == b)
        biome_dens.append({
            "biome": b, "name": fc.BI_NAMES[b], "eff_land_px": px, "count": cnt,
            "density_per_mpx": round(cnt / (px / 1e6), 2) if px else 0.0,
        })
    barren_px = sum(d["eff_land_px"] for d in biome_dens if d["biome"] in (3, 4))
    barren_n = sum(d["count"] for d in biome_dens if d["biome"] in (3, 4))

    cov = coverage_mask(points, eff_land, float(sp["claim_cap_px"]))
    wild = 1.0 - float((cov & eff_land).sum()) / max(int(eff_land.sum()), 1)
    dom_hist = {}
    for s in settlements:
        dom_hist[str(s["dominant"])] = dom_hist.get(str(s["dominant"]), 0) + 1

    stats = {
        "n_settlements": n,
        "n_target_band": [int(v) for v in sp["n_target_band"]],
        "poisson_attempts": attempts,
        "level_hist": {str(k): v for k, v in lv_hist.items()},
        "population_score": dict(quantiles(scores), mean=round(float(np.mean(scores)), 4),
                                 max=round(float(max(scores)), 4),
                                 n_clamped_high=sum(1 for v in scores if v >= 1.0)),
        "h": dict(quantiles(hs), mean=round(float(np.mean(hs)), 4)),
        "band_table": band_table,
        "biome_density": biome_dens,
        "barren_vs_plain_density_ratio": round(
            (barren_n / max(barren_px, 1)) / max(
                biome_dens[0]["count"] / max(biome_dens[0]["eff_land_px"], 1), 1e-12), 4),
        "wilderness_rate": round(wild, 4),
        "dominant_hist": dom_hist,
    }
    return settlements, stats, points


def build_meta(P, stats):
    sp = P["fields_v2"]["settlements"]
    n = stats["n_settlements"]
    return {
        "status": "提案/待定",
        "note": "A3 聚落集 v2（算法提案 §A3 已圈选）：变半径泊松盘选址 + 对数正态"
                "规模谱。全新聚落集，不从旧 city_json 继承；出生 8 城邦特殊态按定向"
                "取消，全域统一规格。",
        "generated_by": "settlement_build.py",
        "params": "state_params.json#fields_v2.settlements",
        "seed": int(sp["seed"]),
        "coords": "x/y 为 8192 级像素（左上原点、y 向下，与 suitability/culture 场"
                  "同网格）；选址在 8192 坐标空间连续计算、场值自 2048 级采样，"
                  "位置精度约 ±4px（场网格半格）",
        "id_scheme": "label 1..%d 连续（按 y,x 读序）；settlement_id = "
                     "settlement_city_%%03d——沿用 political_data.city_owners "
                     "编号体系" % n,
        "level_rule": "level = 1/2/3 由 population_score 阈值 0.187/0.342 映射"
                      "（场景口径全球单一口径）；4/5 档留人口成长不产生",
        "culture_note": "dominant = 主导文化源点序号 1..K（0 = 文化场未覆盖的荒野），"
                        "mix ∈ [0, 0.5]；城级文化相似度（A4 消费口径）= 各自主导文化"
                        "相似度 × (1−各自混合度)，源点矩阵见 culture_similarity.json",
        "wilderness_note": "无聚落条目即荒地（无主地语义由 A4 政治分配生效）；"
                           "荒地率 = 宜居陆地中聚落主张盘未覆盖占比（主张半径 = "
                           "min(泊松半径, claim_cap_px)，A4 无主地分配宜采用同口径）",
        "params_echo": {k: v for k, v in sp.items() if not k.endswith("comment")},
    }


# ---------- 预览 ----------

def _save_titled(img, out_dir, name, title, font):
    canvas = Image.new("RGB", (img.width + 40, img.height + 70), (14, 16, 22))
    canvas.paste(img, (20, 50))
    dr = ImageDraw.Draw(canvas)
    dr.text((20, 12), title, font=font, fill=(240, 240, 245))
    canvas.save(os.path.join(out_dir, name))


def make_previews(settlements, suit, eff_land, out_dir, font):
    """两张自检预览（2048 级）：城位分布（叠宜居度淡底）/ 网格计数核密度。"""
    # 1) 城位分布：宜居度淡底 + 点大小=population_score、色=level
    base = fc.colormap(suit, fc.HEAT_STOPS)
    base[~eff_land] = (26, 32, 50)
    base = (base.astype(np.float32) * 0.5 + 14).astype(np.uint8)
    img = Image.fromarray(base)
    dr = ImageDraw.Draw(img)
    lv_color = {0: (110, 105, 95), 1: (120, 205, 120), 2: (240, 190, 85),
                3: (240, 95, 70)}
    for s in sorted(settlements, key=lambda t: (t["level"], t["population_score"])):
        rad = 2.0 + 7.5 * s["population_score"]
        x, y = s["x"] / K_FIELD, s["y"] / K_FIELD
        dr.ellipse([x - rad, y - rad, x + rad, y + rad],
                   fill=lv_color[s["level"]],
                   outline=(255, 255, 255) if s["level"] == 3 else (18, 20, 26),
                   width=1)
    _save_titled(img, out_dir, "settlements_preview_locations_2048.png",
                 "A3 聚落分布（点大小=population_score 绿=L1村 黄=L2镇 红=L3城；"
                 "底=宜居度淡色，无点区=荒地）", font)

    # 2) 密度图：128×128 网格计数 + 高斯核密度（密度应与宜居度同构）
    g = 128
    cnt = np.zeros((g, g), dtype=np.float32)
    gx = np.minimum(np.array([s["x"] for s in settlements], dtype=np.int64)
                    * g // fc.SIZE_FULL, g - 1)
    gy = np.minimum(np.array([s["y"] for s in settlements], dtype=np.int64)
                    * g // fc.SIZE_FULL, g - 1)
    np.add.at(cnt, (gy, gx), 1.0)
    dens = gaussian_filter(cnt, 2.0)
    d2048 = fc.upsample_bilinear(
        dens / max(float(np.quantile(dens, 0.98)), 1e-6), fc.SIZE)
    rgb = fc.colormap(np.clip(d2048, 0.0, 1.0), fc.HEAT_STOPS)
    rgb[~eff_land] = (20, 26, 42)
    _save_titled(Image.fromarray(rgb), out_dir,
                 "settlements_preview_density_2048.png",
                 "A3 聚落密度（128×128 网格计数+高斯核；热区应与宜居度图强相关，"
                 "贫瘠带整片低密度）", font)


# ---------- 主流程 ----------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-preview", action="store_true")
    args = ap.parse_args()

    P = fc.load_params()
    sp = P["fields_v2"]["settlements"]

    print("[1/3] 变半径泊松盘选址 + 规模/文化采样（场自 2048 级工作集采样）...",
          flush=True)
    settlements, stats, points = build(P)

    print("[2/3] 落盘 settlements_v2.json...", flush=True)
    os.makedirs(fc.FIELDS_DIR, exist_ok=True)
    with open(os.path.join(fc.FIELDS_DIR, "settlements_v2.json"), "w",
              encoding="utf-8") as f:
        json.dump({"_meta": build_meta(P, stats), "stats": stats,
                   "settlements": settlements}, f, ensure_ascii=False, indent=1)

    print("\n=== A3 聚落统计 ===")
    print("  城数 %d（目标带 %s）；泊松尝试 %d 次" % (
        stats["n_settlements"], stats["n_target_band"], stats["poisson_attempts"]))
    print("  level 谱 %s（阈值 %s）" % (stats["level_hist"],
                                       sp["level_thresholds"]))
    print("  population_score %s mean=%.4f clamped_high=%d" % (
        {k: v for k, v in stats["population_score"].items() if k != "n_clamped_high"},
        stats["population_score"]["mean"], stats["population_score"]["n_clamped_high"]))
    print("  分带（贫→富）：%s" % [(b["band"], b["count"]) for b in stats["band_table"]])
    print("  分群系密度（城/Mpx）：%s" % {
        d["name"]: d["density_per_mpx"] for d in stats["biome_density"]})
    print("  贫瘠(荒漠+冰原)/平原 密度比 %.3f；荒地率 %.1f%%" % (
        stats["barren_vs_plain_density_ratio"], stats["wilderness_rate"] * 100.0))

    if not args.skip_preview:
        print("[3/3] 预览（重载 2048 级底场）...", flush=True)
        suit, _res, _dom, _mix, _biome, eff_land = load_fields_2048()
        make_previews(settlements, suit, eff_land, fc.FIELDS_DIR, fc.fit_font(22))
        print("预览：output/fields/settlements_preview_{locations,density}_2048.png")

    print("完成。产物在 %s（gitignored）" % fc.FIELDS_DIR)


if __name__ == "__main__":
    main()
