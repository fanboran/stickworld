"""世界重生成 v2 A2：文化场 v2——文化相似度连续化（culture_build.py）

把「文化圈硬边界」改为「文化连续场 + 文化间相似度」（算法提案 §A2，已圈选）：
  1. 文化源点：K≈15-25 个，泊松盘间距撒在宜居度较高陆地（fields_build 产物），
     每源点带属性——语系 id（贪心空间聚簇）、生计模式（农耕/游牧/渔猎/商贸，
     由源点周边窗口环境派生）、地形偏好向量（窗口群系占比归一）
  2. 文化扩散场：多源测地 flood，cost 骨架与 state_expand_lite.culture_flood
     完全同构（fields_common.build_flood_cost，2048 级计算保证 k_slope/k_river/
     k_desert/k_ice 语义逐位同构；k_cross_region = 跨出源点所在 region 的软罚）。
     每 tile 取累计代价 top2 → 主导文化（argmin）+ 混合度（c1/(c1+c2)，
     尺度无关，中线=0.5「半亲」；过渡带模糊边界）+ 场强（exp(-cum/T)）
  3. 文化相似度矩阵：源点两两 = 同语系 + 生计相近表 + 地形偏好余弦，[0,1]
     （tile 级相似度 = 各自主导文化相似度 × (1−各自混合度)，A4 消费口径，
     公式记入 culture_similarity.json meta）

产物（tools/worldgen/output/fields/，gitignored 不入库）：
  culture_field.npy（int16 8192²，0=无主/水体，i=第 i 个源点）
  culture_mix.npy（float16，次文化混合度 0..1）
  culture_strength.npy（float16，主导文化场强 exp(-cum/T)）
  culture_sources.json（源点表；语素库后续挂 morph_seed，本任务只留 seed 占位）
  culture_similarity.json（K×K 矩阵）
  city_culture.json（1036 聚落采样：主导/次文化 + 混合度）
预览：culture_preview_2048.png（源点 + 场强边界 + 过渡带 + 相似度矩阵热图）

用法：
  python culture_build.py [--skip-preview]
依赖 fields_build.py 先行产出 suitability.npy；同 seed 逐位确定。
"""

import argparse
import colorsys
import json
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import distance_transform_edt
from skimage.graph import MCP_Geometric

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fields_common as fc  # noqa: E402


# ---------- 输入 ----------

def load_inputs():
    """2048 级底图（与 state_expand_lite 同构）+ fields_build 的宜居度。"""
    elev = fc.load_elev_2048()
    river = fc.load_river_2048()
    biome = np.load(os.path.join(fc.OUTPUT_DIR, "biome_labels_2048.npy"))
    region = np.load(os.path.join(fc.OUTPUT_DIR, "regions", "region_labels.npy"))
    lake = np.asarray(Image.open(
        os.path.join(fc.OUTPUT_DIR, "fractal_lake_mask_8192.png")).convert("L"))
    lake = np.asarray(Image.fromarray(lake).resize(
        (fc.SIZE, fc.SIZE), Image.NEAREST)) > 0
    suit_path = os.path.join(fc.FIELDS_DIR, "suitability.npy")
    if not os.path.exists(suit_path):
        raise SystemExit("缺 %s——先跑 fields_build.py" % suit_path)
    suit = fc.downsample_mean(
        np.load(suit_path).astype(np.float32), fc.SIZE)
    return elev, river, biome, region, lake, suit


# ---------- 源点布点与属性 ----------

def place_sources(suit, eff_land, cp, rng):
    """泊松盘撒源点：宜居度 ≥ 分位阈值打分位，不足逐轮放宽（pick_seeds 同思路）。"""
    sep = int(cp["min_sep_px"]) // (fc.SIZE_FULL // fc.SIZE)  # → 2048 级
    want = int(cp["k_sources"])
    q = float(cp["suit_quantile"])
    accepted = []
    for relax in range(5):
        thr = float(np.quantile(suit[eff_land], max(q - 0.08 * relax, 0.0)))
        cand = np.argwhere(eff_land & (suit >= thr))
        order = rng.permutation(cand.shape[0])
        for k in order:
            y, x = int(cand[k, 0]), int(cand[k, 1])
            if all((y - b) ** 2 + (x - a) ** 2 >= sep * sep for _, a, b in accepted):
                accepted.append((k, x, y))
                if len(accepted) >= want:
                    return [(x, y) for _, x, y in accepted]
    print("  [warn] 泊松盘只撒到 %d/%d 源点（宜居候选不足，sep=%d）"
          % (len(accepted), want, sep))
    return [(x, y) for _, x, y in accepted]


def ensure_biome_seats(pts, suit, biome, eff_land, cp):
    """环境保底席位（创始人定向：冰原火柴人等种族要有家园）——冰原/火山群系
    若无源点落位，在其宜居度最高的候选点按最小间距补席，保证对应种族
    （雪地/火山）有文化源点=有国家。确定性（排序无随机）。"""
    sep = int(cp["min_sep_px"]) // (fc.SIZE_FULL // fc.SIZE)
    seats = cp.get("biome_seats", {})
    for name, spec in seats.items():
        if name == "comment":
            continue
        bi = fc.BI_NAMES.index(name)
        have = 0
        for x, y in pts:
            y0, y1 = max(0, y - 8), min(fc.SIZE, y + 9)
            x0, x1 = max(0, x - 8), min(fc.SIZE, x + 9)
            if (biome[y0:y1, x0:x1] == bi).mean() > float(spec["frac"]):
                have += 1
        need = int(spec["min_sources"]) - have
        if need <= 0:
            continue
        mask = eff_land & (biome == bi)
        if not mask.any():
            print("  [warn] %s 群系无有效陆地，跳过保底" % name)
            continue
        cand = np.argwhere(mask)
        order = np.argsort(-suit[cand[:, 0], cand[:, 1]])  # 宜居度降序（确定性）
        added = 0
        for k in order:
            y, x = int(cand[k, 0]), int(cand[k, 1])
            if all((y - b) ** 2 + (x - a) ** 2 >= sep * sep for a, b in pts):
                pts.append((x, y))
                added += 1
                print("  [seat] %s 保底源点 @(%d,%d)" % (name, x, y))
                if added >= need:
                    break
        if added < need:
            print("  [warn] %s 保底只补到 %d/%d（间距约束）" % (name, added, need))


def window_fracs(biome, lake, gradmag, coast_dist, x, y, radius, mount_thr,
                 coast_dist_px):
    """源点周边方形窗口的群系/地形占比：plain/forest/mountain/desert/ice/water/coast。"""
    y0, y1 = max(0, y - radius), min(fc.SIZE, y + radius + 1)
    x0, x1 = max(0, x - radius), min(fc.SIZE, x + radius + 1)
    b = biome[y0:y1, x0:x1]
    n = float(b.size)
    f = {
        "plain": float((b == fc.BI_PLAIN).sum()) / n,
        "forest": float((b == fc.BI_FOREST).sum()) / n,
        "mountain": float((gradmag[y0:y1, x0:x1] > mount_thr).sum()) / n,
        "desert": float((b == fc.BI_DESERT).sum()) / n,
        "ice": float((b == fc.BI_ICE).sum()) / n,
        "volcanic": float((b == fc.BI_VOLCANIC).sum()) / n,
        "source": float((b == fc.BI_SOURCE).sum()) / n,
        "water": float(((b == fc.BI_OCEAN) | lake[y0:y1, x0:x1]).sum()) / n,
        "coast": float((coast_dist[y0:y1, x0:x1] < coast_dist_px).sum()) / n,
    }
    return f


def derive_livelihood(f, rng, rules):
    """生计模式：环境规则按序匹配 + 种子随机（确定性）。

    冰原→渔猎；荒漠→游牧/商贸；紧岸→商贸/渔猎；森林→渔猎/商贸；
    高山→游牧；其余内陆平原/河谷→农耕/商贸。阈值与概率见
    fields_v2.culture.livelihood_rules（紧岸阈值刻意小：宜居度海岸加成会吸
    源点，宽岸带会让商贸一家独大）。
    """
    if f["ice"] > float(rules["ice"]):
        return "渔猎"
    if f["desert"] > float(rules["desert"]):
        return "游牧" if rng.random() < float(rules["desert_nomad_p"]) else "商贸"
    if f["coast"] > float(rules["coast"]):
        return "商贸" if rng.random() < float(rules["coast_trade_p"]) else "渔猎"
    if f["forest"] > float(rules["forest"]):
        return "渔猎" if rng.random() < float(rules["forest_fisher_p"]) else "商贸"
    if f["mountain"] > float(rules["mountain"]):
        return "游牧"
    return "农耕" if rng.random() < float(rules["inland_farm_p"]) else "商贸"


def derive_race(f, rules):
    """种族映射（创始人定向：冰原火柴人等八种族与文化圈对应）：环境特征按序匹配。

    火山圈→火山；冰原→雪地；荒漠→半人马（游牧）；高山两档→巨人/矮人；
    森林→羽翼；源流→术师人；其余（平原/河谷）→平原族。阈值见
    fields_v2.culture.race_rules（确定性无随机）。
    """
    r = rules
    if f["volcanic"] > float(r["volcanic"]):
        return "火山"
    if f["ice"] > float(r["ice"]):
        return "雪地"
    if f["desert"] > float(r["desert"]):
        return "半人马"
    if f["mountain"] > float(r["mountain_high"]):
        return "巨人"
    if f["mountain"] > float(r["mountain_mid"]):
        return "矮人"
    if f["forest"] > float(r["forest"]):
        return "羽翼"
    if f["source"] > float(r["source"]):
        return "术师人"
    return "平原"


def balance_livelihoods(sources, min_each):
    """生计覆盖均衡：每种生计至少 min_each 个源点（防 seed 漂移出 0/N 极端分布）。

    派生后补足：缺额生计按 LIVELIHOODS 序处理，用源点地形偏好（terrain_pref =
    窗口群系占比）给缺额生计打「环境适配分」，从富余生计（改派后仍 ≥ min_each）
    里挑适配最高者改派——荒漠/高山源点改游牧、森林/冰原/临水源点改渔猎、
    平原/紧岸源点改农耕/商贸，环境语义不破坏。无随机数，确定性；并列取序号小者。
    """
    pref_of = {
        "农耕": lambda v: v["plain"] + 0.5 * v["forest"] - v["desert"] - v["ice"],
        "游牧": lambda v: v["desert"] + v["mountain"],
        "渔猎": lambda v: v["forest"] + v["ice"] + v["coast"],
        "商贸": lambda v: v["coast"] + 0.5 * v["plain"],
    }
    for lv in fc.LIVELIHOODS:
        while sum(1 for s in sources if s["livelihood"] == lv) < min_each:
            cnt = {}
            for s in sources:
                cnt[s["livelihood"]] = cnt.get(s["livelihood"], 0) + 1
            cand = [(pref_of[lv](s["terrain_pref"]), -i, i)
                    for i, s in enumerate(sources)
                    if s["livelihood"] != lv and cnt[s["livelihood"]] > min_each]
            if not cand:
                print("  [warn] 生计均衡：%s 无法补足 %d 个源点（富余不足）"
                      % (lv, min_each))
                return
            _, _, i = max(cand)
            sources[i]["livelihood"] = lv


def cluster_families(sources, join_dist, n_families):
    """语系 = 贪心空间聚簇：逐点并入 join_dist 内最近语系，超目标数则强制并入；
    末了_singleton 并入最近语系（保证每语系 ≥2 成员 → 相似度无孤立全零行）。"""
    fam_of = [None] * len(sources)
    fams = []  # list[list[src_idx]]
    for i in range(len(sources)):
        best_f, best_d = None, float("inf")
        for fi, members in enumerate(fams):
            d = min(math.hypot(sources[i]["x"] - sources[j]["x"],
                               sources[i]["y"] - sources[j]["y"])
                    for j in members)
            if d < best_d:
                best_f, best_d = fi, d
        if best_f is not None and (best_d <= join_dist or len(fams) >= n_families):
            fams[best_f].append(i)
            fam_of[i] = best_f
        else:
            fams.append([i])
            fam_of[i] = len(fams) - 1
    # singleton 语系并入最近语系（按源点距离；保证每语系 ≥2 成员 →
    # 相似度无孤立全零行）。pop 会使其后语系索引前移，fam_of 同步重排。
    for fi in range(len(fams) - 1, -1, -1):
        if len(fams) == 1:
            break
        if len(fams[fi]) > 1:
            continue
        i = fams[fi][0]
        target = min((fj for fj in range(len(fams)) if fj != fi),
                     key=lambda fj: min(
                         math.hypot(sources[i]["x"] - sources[j]["x"],
                                    sources[i]["y"] - sources[j]["y"])
                         for j in fams[fj]))
        fams[target].append(i)
        fam_of[i] = target
        fams.pop(fi)
        fam_of = [f if f < fi else f - 1 for f in fam_of]
    # fam_id 按规模降序（并列按最小成员序）重编号 fam_1..
    order = sorted(range(len(fams)),
                   key=lambda fi: (-len(fams[fi]), min(fams[fi])))
    renum = {fi: k + 1 for k, fi in enumerate(order)}
    return {i: "fam_%d" % renum[fam_of[i]] for i in range(len(sources))}


def similarity_matrix(sources, sim_p):
    """源点两两相似度 ∈ [0,1]：同语系 + 生计相近表 + 地形偏好余弦。"""
    k = len(sources)
    pref = np.array([s["terrain_pref_vec"] for s in sources], dtype=np.float64)
    cos = (pref @ pref.T) / np.clip(
        np.linalg.norm(pref, axis=1)[:, None] * np.linalg.norm(pref, axis=1)[None, :],
        1e-9, None)
    m = np.zeros((k, k), dtype=np.float64)
    for i in range(k):
        for j in range(i + 1, k):
            key = "-".join(sorted((sources[i]["livelihood"],
                                   sources[j]["livelihood"])))
            v = (float(sim_p["w_family"])
                 * (1.0 if sources[i]["family"] == sources[j]["family"] else 0.0)
                 + float(sim_p["w_livelihood"]) * float(
                     sim_p["livelihood_sim"].get(key, 0.0))
                 + float(sim_p["w_terrain"]) * float(cos[i, j]))
            v = float(np.clip(v, 0.0, 1.0))
            m[i, j] = m[j, i] = v
    np.fill_diagonal(m, 1.0)
    return m


# ---------- 扩散场 ----------

def culture_flood_v2(sources, elev, river, biome, region, cp):
    """多源测地扩散（与 state_expand_lite.culture_flood 同构的 cost 骨架）。

    逐源 MCP 累计代价，流式维护 top-2（内存 O(HW) 不存 K 张 cum）；
    region 越界罚只对「非源点所在 region」的陆地生效（软性向心力，
    k_cross_region 可调 0 关闭）；源点 home region = 0（未划 region 的荒野）
    时无锚可依，不加跨区罚。返回 (best_i, best_cum, second_i, second_cum)。
    """
    fcp = cp["flood"]
    base, land = fc.build_flood_cost(
        elev, river, biome, fcp["k_slope"], fcp["k_river"],
        fcp["k_desert"], fcp["k_ice"])
    shape = base.shape
    best = np.full(shape, np.inf, dtype=np.float32)
    second = np.full(shape, np.inf, dtype=np.float32)
    best_i = np.full(shape, -1, dtype=np.int16)
    second_i = np.full(shape, -1, dtype=np.int16)
    for i, s in enumerate(sources):
        costs = base
        if s["region"] != 0:
            costs = costs + np.where(region == s["region"], 0.0,
                                     float(fcp["k_cross_region"])) * land
        mcp = MCP_Geometric(costs)
        cum, _ = mcp.find_costs([(s["y2k"], s["x2k"])])
        cum32 = cum.astype(np.float32)
        m1 = cum32 < best
        m2 = (~m1) & (cum32 < second)
        second = np.where(m1, best, np.where(m2, cum32, second))
        second_i = np.where(m1, best_i, np.where(m2, np.int16(i), second_i))
        best = np.where(m1, cum32, best)
        best_i = np.where(m1, np.int16(i), best_i)
    return best_i, best, second_i, second


# ---------- 主流程 ----------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-preview", action="store_true")
    args = ap.parse_args()

    P = fc.load_params()
    cp = P["fields_v2"]["culture"]
    rng = np.random.default_rng(int(cp["seed"]))

    print("[1/6] 读底图 + A1 宜居度...", flush=True)
    elev, river, biome, region, lake, suit = load_inputs()
    eff_land = (biome > 0) & (~lake)

    print("[2/6] 撒源点（泊松盘，K=%d）..." % int(cp["k_sources"]), flush=True)
    pts = place_sources(suit, eff_land, cp, rng)
    ensure_biome_seats(pts, suit, biome, eff_land, cp)

    gy, gx = np.gradient(elev)
    gradmag = np.sqrt(gy * gy + gx * gx)
    del gy, gx
    mount_thr = float(np.quantile(gradmag[eff_land], 0.85))
    coast_dist = distance_transform_edt(biome > 0).astype(np.float32)

    # 属性：生计/地形偏好（窗口环境派生）+ home region + morph_seed 占位
    radius = int(cp["window_px"]) // 2
    rules = cp["livelihood_rules"]
    sources = []
    for i, (x, y) in enumerate(pts):
        f = window_fracs(biome, lake, gradmag, coast_dist, x, y, radius,
                         mount_thr, float(rules["coast_dist_px"]))
        pref = {k: max(f.get(k, 0.0), 0.02) for k in fc.TERRAIN_KEYS}
        tot = sum(pref.values())
        vec = [pref[k] / tot for k in fc.TERRAIN_KEYS]
        sources.append({
            "id": "cult_%02d" % (i + 1),
            "x2k": x, "y2k": y,                     # 2048 级（内部计算用）
            "x": x * (fc.SIZE_FULL // fc.SIZE),     # 8192 级 [x, y]（产物输出用）
            "y": y * (fc.SIZE_FULL // fc.SIZE),
            "region": int(region[y, x]),
            "livelihood": derive_livelihood(f, rng, rules),
            "race": derive_race(f, cp["race_rules"]),
            "terrain_pref_vec": vec,
            "terrain_pref": {k: round(v, 3) for k, v in zip(fc.TERRAIN_KEYS, vec)},
            "morph_seed": int(rng.integers(0, 1 << 30)),  # 语素库 seed 占位（A2 后续）
        })
    balance_livelihoods(sources, int(cp.get("livelihood_min_each", 2)))
    join_dist = float(cp["family_join_frac"]) * (
        int(cp["min_sep_px"]) / (fc.SIZE_FULL // fc.SIZE))
    fam = cluster_families(sources, join_dist, int(cp["n_families"]))
    for i, s in enumerate(sources):
        s["family"] = fam[i]
    print("源点：%s" % "  ".join(
        "%s(%s,%s,r%d)" % (s["id"], s["livelihood"], s["family"], s["region"])
        for s in sources))

    print("[3/6] 相似度矩阵...", flush=True)
    sim = similarity_matrix(sources, cp["similarity"])

    print("[4/6] 多源测地扩散（%d 源 × MCP 2048²）..." % len(sources), flush=True)
    best_i, best_cum, second_i, second_cum = culture_flood_v2(
        sources, elev, river, biome, region, cp)

    temp = float(cp["strength_temp"])
    cap = float(cp["reach_cap_cum"])
    s1 = np.exp(-best_cum / temp)
    dom = np.where(best_cum <= cap, best_i + 1, 0).astype(np.int16)
    # 混合度（尺度无关）：mix = c1/(c1+c2)，c1/c2 = top2 累计代价。
    # 两源中线 c1≈c2 → 0.5（「半亲」：过渡带城对任一侧保持一半亲缘，A4 合并
    # 不至于两边都够不着）；文化核心 c1≪c2 → 0。exp 温度只用于场强
    # （A4 文化中心性），不进混合度——exp 差距仅依赖 Δc/T，单一全局 T
    # 会让过渡带吞掉大半陆地（实测 81%）。
    second_safe = np.minimum(second_cum, 1e12)  # inf（无第二源在射程）→ mix≈0
    mix_raw = best_cum / np.maximum(best_cum + second_safe, 1e-12)
    strength = np.where(best_cum <= cap, s1, 0.0).astype(np.float32)
    mix = np.where(dom > 0, mix_raw, 0.0).astype(np.float32)

    print("[5/6] 上采样 8192 + 城采样 + 落盘...", flush=True)
    os.makedirs(fc.FIELDS_DIR, exist_ok=True)
    k = fc.SIZE_FULL // fc.SIZE
    np.save(os.path.join(fc.FIELDS_DIR, "culture_field.npy"),
            np.repeat(np.repeat(dom, k, axis=0), k, axis=1))
    np.save(os.path.join(fc.FIELDS_DIR, "culture_mix.npy"),
            fc.upsample_bilinear(mix, fc.SIZE_FULL).astype(np.float16))
    np.save(os.path.join(fc.FIELDS_DIR, "culture_strength.npy"),
            fc.upsample_bilinear(strength, fc.SIZE_FULL).astype(np.float16))

    # 城采样（anchor = 8192 级 [x, y]；次文化只在过渡带 mix ≥ 0.15 时报告）
    with open(os.path.join(fc.GAME_CFG, "l3_city.json"), encoding="utf-8") as f:
        city_json = json.load(f)
    cities = []
    for t in city_json["tiles"]:
        cx = min(max(int(round(t["anchor"][0])), 0), fc.SIZE_FULL - 1)
        cy = min(max(int(round(t["anchor"][1])), 0), fc.SIZE_FULL - 1)
        d = int(dom[cy // k, cx // k])
        mx = float(mix[cy // k, cx // k])
        sc = int(second_i[cy // k, cx // k]) + 1 if mx >= 0.15 else -1
        cities.append({"settlement_id": "settlement_city_%03d" % int(t["label"]),
                       "dominant": d, "second": sc, "mix": round(mx, 3)})
    cov = float((dom[eff_land] > 0).mean())
    print("城采样 %d 城；陆地文化覆盖率 %.1f%%；mix 陆地均值 %.3f" % (
        len(cities), cov * 100.0, float(mix[eff_land].mean())))

    with open(os.path.join(fc.FIELDS_DIR, "culture_sources.json"), "w",
              encoding="utf-8") as f:
        json.dump({
            "_meta": {
                "status": "提案/待定",
                "note": "A2 文化源点表（v2 文化连续场）。id/坐标(8192级[x,y])/"
                        "region/语系/生计/地形偏好为算法派生属性；morph_seed 为"
                        "构型命名语素库的挂载点（本任务只留 seed 占位，语素库后补）。",
                "params": "state_params.json#fields_v2.culture",
                "seed": int(cp["seed"]),
            },
            "sources": [{k: v for k, v in s.items()
                         if k not in ("terrain_pref_vec", "x2k", "y2k")}
                        for s in sources],
        }, f, ensure_ascii=False, indent=1)
    with open(os.path.join(fc.FIELDS_DIR, "culture_similarity.json"), "w",
              encoding="utf-8") as f:
        json.dump({
            "_meta": {
                "status": "提案/待定",
                "note": "源点两两相似度 [0,1]（对角=1）。tile 级相似度（A4 消费口径）"
                        "= 各自主导文化相似度 × (1−各自混合度)——过渡带上的城与两侧"
                        "都「半亲」。",
                "formula": "w_family×同语系 + w_livelihood×生计相近表 + "
                           "w_terrain×地形偏好余弦",
            },
            "culture_ids": [s["id"] for s in sources],
            "matrix": [[round(float(v), 4) for v in row] for row in sim],
        }, f, ensure_ascii=False, indent=1)
    with open(os.path.join(fc.FIELDS_DIR, "city_culture.json"), "w",
              encoding="utf-8") as f:
        json.dump({
            "_meta": {
                "status": "提案/待定",
                "note": "1036 聚落文化采样（来自 culture_field/mix 场，anchor 8192 级）。",
                "dominant": "源点序号 1..K（0=无主荒野/水体）",
                "second": "次文化源点序号（仅过渡带 mix≥0.15 报告，否则 -1）",
            },
            "cities": cities,
        }, f, ensure_ascii=False, indent=1)

    print("\n=== A2 文化场摘要 ===")
    print("  源点 %d（语系 %d 个）；生计分布 %s" % (
        len(sources), len({s["family"] for s in sources}),
        {lv: sum(1 for s in sources if s["livelihood"] == lv)
         for lv in fc.LIVELIHOODS}))
    off = sim[~np.eye(len(sources), dtype=bool)]
    print("  相似度（非对角）：min %.3f max %.3f mean %.3f；逐行最大值 min %.3f"
          % (off.min(), off.max(), off.mean(),
             off.reshape(len(sources), -1).max(axis=1).min()))
    band = eff_land & (mix >= 0.4) & (mix <= 0.5)  # 接近中线 = 强过渡带
    print("  强过渡带（mix 0.4..0.5）占陆地 %.1f%%；mix 陆地均值 %.3f（值域 0..0.5）"
          % (float(band.mean() / eff_land.mean()) * 100.0,
             float(mix[eff_land].mean())))

    if not args.skip_preview:
        make_preview(sources, dom, mix, sim, fc.fit_font(20))
        print("预览：output/fields/culture_preview_2048.png")

    print("完成。产物在 %s（gitignored）" % fc.FIELDS_DIR)


# ---------- 预览 ----------

def make_preview(sources, dom, mix, sim, font):
    """文化分布图（源点+主导色+过渡带）+ 相似度矩阵热图。"""
    size = 2048
    rng = np.random.default_rng(int(fc.load_params()["fields_v2"]["culture"]["seed"]) + 7)
    colors = []
    for s in sources:
        h = rng.random()
        colors.append(tuple(int(v * 255) for v in
                            colorsys.hls_to_rgb(h, 0.52, 0.58)))
    lut = np.array([(70, 74, 88)] + colors, dtype=np.uint8)
    rgb = lut[dom.astype(np.int32)]  # 2048 级 dom
    band = mix >= 0.35  # 临近中线（mix≤0.5）的过渡带
    rgb[band] = (rgb[band] * 0.62 + 150).astype(np.uint8)  # 过渡带提灰
    img = Image.fromarray(rgb)
    dr = ImageDraw.Draw(img)
    for i, s in enumerate(sources):
        x, y = s["x2k"], s["y2k"]
        dr.ellipse([x - 7, y - 7, x + 7, y + 7], fill=(255, 255, 255),
                   outline=(20, 20, 24), width=2)
        dr.text((x + 10, y - 12), "%s %s" % (s["id"], s["livelihood"]),
                font=font, fill=(255, 255, 255), stroke_width=2,
                stroke_fill=(20, 20, 24))
    # 右侧相似度矩阵热图（K×K，单元 26px）
    kk = len(sources)
    cell = 26
    mat = (np.clip(sim, 0, 1) * 255).astype(np.uint8)
    mat_img = Image.fromarray(mat).resize((kk * cell, kk * cell), Image.NEAREST)
    mat_rgb = fc.colormap(np.asarray(mat_img) / 255.0, fc.HEAT_STOPS)
    canvas = Image.new("RGB", (size + kk * cell + 60, size), (14, 16, 22))
    canvas.paste(img, (0, 0))
    canvas.paste(Image.fromarray(mat_rgb), (size + 30, 60))
    dr2 = ImageDraw.Draw(canvas)
    dr2.text((size + 30, 24), "文化相似度矩阵（cult_01..%02d）" % kk, font=font,
             fill=(240, 240, 245))
    dr2.text((12, 8), "A2 文化场 v2（灰带=过渡带 mix≥0.35，白点=源点）", font=font,
             fill=(240, 240, 245))
    canvas.save(os.path.join(fc.FIELDS_DIR, "culture_preview_2048.png"))


if __name__ == "__main__":
    main()
