"""世界重生成 v2 场层自检（fields_check.py）

对 fields_build.py / culture_build.py 的产物做断言（算法提案 A1/A2 验收口径）：
  1. 宜居度：贫瘠群系（荒漠/冰原）中位数显著低于富庶群系（平原）
  2. 资源场空间自相关：相邻像素相关系数 > 阈值（成带成片，非白噪声）
  3. 文化相似度矩阵：无孤立全零行 + 对称 + 对角 1 + [0,1]
  4. attack_cost：有限值无 NaN；陆地 ≥ 1（[1,∞) 量纲）；水体 = k_water_cost 恒值
  5. 各场值域 [0,1]（attack_cost 除外）与 NaN 检查；文化场陆地覆盖率
  6. 产物齐全性：meta / 源点表 / 相似度 / 城采样 json 可解析、城数对表

用法：python fields_check.py
全部通过打印 PASS（退出码 0）；任一失败打印 FAIL 明细（退出码 1）。
"""

import json
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fields_common as fc  # noqa: E402

# 阈值（自检口径；与 fields_v2 参数解耦的验收常数）
BARREN_MARGIN = 0.15      # 贫瘠群系中位数须低于平原至少此值
AUTOCORR_MIN = 0.45       # 资源场相邻像素相关系数下限（>0.45 = 成片非白噪）
CULTURE_COVER_MIN = 0.5   # 陆地文化覆盖率下限
SIM_ROW_MIN = 0.05        # 相似度矩阵逐行非对角最大值下限（无孤立全零行）


def check_fail(fails, name, msg):
    fails.append("%s: %s" % (name, msg))
    print("  [FAIL] %s: %s" % (name, msg))


def check_ok(name, msg=""):
    print("  [ok] %s%s" % (name, (" — " + msg) if msg else ""))


def load_land_masks():
    biome8 = np.repeat(np.repeat(
        np.load(os.path.join(fc.OUTPUT_DIR, "biome_labels_2048.npy")), 4, 0), 4, 1)
    lake8 = np.asarray(Image.open(
        os.path.join(fc.OUTPUT_DIR, "fractal_lake_mask_8192.png")).convert("L")) > 0
    eff_land = (biome8 > 0) & (~lake8)
    return biome8, lake8, eff_land


def load_f16(name):
    return np.load(os.path.join(fc.FIELDS_DIR, name + ".npy")).astype(np.float32)


def main():
    fails = []
    P = fc.load_params()
    fp = P["fields_v2"]

    biome8, lake8, eff_land = load_land_masks()
    water = (biome8 == fc.BI_OCEAN) | lake8

    print("=== fields_check：世界重生成 v2 场层自检 ===")

    # ---- 产物齐全性 ----
    need = ["mineral.npy", "fertile.npy", "forest.npy", "fishsalt.npy",
            "suitability.npy", "attack_cost.npy", "fields_meta.json",
            "culture_field.npy", "culture_mix.npy", "culture_strength.npy",
            "culture_sources.json", "culture_similarity.json", "city_culture.json"]
    missing = [n for n in need if not os.path.exists(os.path.join(fc.FIELDS_DIR, n))]
    if missing:
        check_fail(fails, "产物齐全性", "缺 " + ", ".join(missing))
    else:
        check_ok("产物齐全性", "%d 个产物文件" % len(need))

    # ---- 1) 宜居度：贫瘠 vs 富庶 ----
    suit = load_f16("suitability")
    if np.isnan(suit).any():
        check_fail(fails, "suitability", "含 NaN")
    elif suit.min() < 0.0 or suit.max() > 1.0:
        check_fail(fails, "suitability", "值域越界 [0,1]：[%.3f, %.3f]"
                   % (suit.min(), suit.max()))
    elif (suit[~eff_land] != 0).any():
        check_fail(fails, "suitability", "水体未清零")
    else:
        plains = float(np.median(suit[eff_land & (biome8 == fc.BI_PLAIN)]))
        desert = float(np.median(suit[eff_land & (biome8 == fc.BI_DESERT)]))
        ice = float(np.median(suit[eff_land & (biome8 == fc.BI_ICE)]))
        if desert > plains - BARREN_MARGIN:
            check_fail(fails, "宜居度分群系", "荒漠中位 %.3f 未低于平原 %.3f − %.2f"
                       % (desert, plains, BARREN_MARGIN))
        elif ice > plains - BARREN_MARGIN:
            check_fail(fails, "宜居度分群系", "冰原中位 %.3f 未低于平原 %.3f − %.2f"
                       % (ice, plains, BARREN_MARGIN))
        else:
            check_ok("宜居度分群系", "平原 %.3f vs 荒漠 %.3f / 冰原 %.3f"
                     % (plains, desert, ice))

    # ---- 2) 资源场空间自相关（相邻像素相关，子采样加速） ----
    for name in ("mineral", "fertile", "forest", "fishsalt"):
        v = load_f16(name)
        if np.isnan(v).any() or v.min() < 0.0 or v.max() > 1.0:
            check_fail(fails, "资源场 " + name, "NaN 或值域越界 [0,1]")
            continue
        if (v[~eff_land] != 0).any():
            check_fail(fails, "资源场 " + name, "水体未清零")
            continue
        s = v[::8, ::8]
        ch = np.corrcoef(s[:, :-1].ravel(), s[:, 1:].ravel())[0, 1]
        cv = np.corrcoef(s[:-1, :].ravel(), s[1:, :].ravel())[0, 1]
        c = float(min(ch, cv))
        if c <= AUTOCORR_MIN:
            check_fail(fails, "资源场 " + name,
                       "相邻像素相关 %.3f ≤ %.2f（疑似白噪声）" % (c, AUTOCORR_MIN))
        else:
            check_ok("资源场 " + name, "相邻像素相关 %.3f（成片）" % c)

    # ---- 3) 文化相似度矩阵 ----
    with open(os.path.join(fc.FIELDS_DIR, "culture_similarity.json"),
              encoding="utf-8") as f:
        csim = json.load(f)
    m = np.asarray(csim["matrix"], dtype=np.float64)
    k = len(csim["culture_ids"])
    if m.shape != (k, k):
        check_fail(fails, "相似度矩阵", "形状 %s 与 culture_ids %d 不符"
                   % (m.shape, k))
    else:
        off = m[~np.eye(k, dtype=bool)]
        row_base = m.copy()
        np.fill_diagonal(row_base, -1.0)
        row_max = row_base.max(axis=1)
        if not np.allclose(m, m.T, atol=1e-9):
            check_fail(fails, "相似度矩阵", "不对称")
        elif m.diagonal().min() != 1.0 or m.diagonal().max() != 1.0:
            check_fail(fails, "相似度矩阵", "对角非 1")
        elif off.min() < 0.0 or off.max() > 1.0:
            check_fail(fails, "相似度矩阵", "值域越界 [0,1]")
        elif row_max.min() < SIM_ROW_MIN:
            check_fail(fails, "相似度矩阵",
                       "第 %d 行近孤立（非对角最大 %.3f < %.2f）"
                       % (int(row_max.argmin()), row_max.min(), SIM_ROW_MIN))
        else:
            check_ok("相似度矩阵", "%d×%d 对称归一；无孤立全零行"
                     "（逐行最大 min %.3f，非对角 mean %.3f）"
                     % (k, k, row_max.min(), off.mean()))

    # ---- 4) attack_cost ----
    ac = np.load(os.path.join(fc.FIELDS_DIR, "attack_cost.npy"))
    kw = float(fp["attack_cost"]["k_water_cost"])
    if not np.isfinite(ac).all():
        check_fail(fails, "attack_cost", "含 NaN/Inf")
    elif ac[eff_land].min() < 1.0 - 1e-6:
        check_fail(fails, "attack_cost", "陆地最小值 %.3f < 1（量纲破坏）"
                   % float(ac[eff_land].min()))
    elif not (ac[water] == kw).all():
        check_fail(fails, "attack_cost", "水体存在非恒值 k_water_cost 的像素")
    else:
        check_ok("attack_cost", "全有限；陆地 [%.2f, %.2f]；水体恒值 %.1f"
                 % (float(ac[eff_land].min()), float(ac[eff_land].max()), kw))

    # ---- 5) 文化场 ----
    dom = np.load(os.path.join(fc.FIELDS_DIR, "culture_field.npy"))
    mix = load_f16("culture_mix")
    if dom.shape != (fc.SIZE_FULL,) * 2 or mix.shape != (fc.SIZE_FULL,) * 2:
        check_fail(fails, "文化场", "分辨率非 8192²")
    elif mix.min() < 0.0 or mix.max() > 1.0:
        check_fail(fails, "文化场", "mix 值域越界 [0,1]")
    elif dom.min() < 0 or dom.max() > k:
        check_fail(fails, "文化场", "dominant 标签越界 0..%d" % k)
    else:
        cover = float((dom[eff_land] > 0).mean())
        if cover < CULTURE_COVER_MIN:
            check_fail(fails, "文化场", "陆地覆盖率 %.1f%% < %.0f%%"
                       % (cover * 100, CULTURE_COVER_MIN * 100))
        else:
            check_ok("文化场", "dominant 0..%d；陆地覆盖率 %.1f%%；mix 均值 %.3f"
                     % (k, cover * 100, float(mix[eff_land].mean())))

    # ---- 6) 源点表 / 城采样 ----
    with open(os.path.join(fc.FIELDS_DIR, "culture_sources.json"),
              encoding="utf-8") as f:
        src = json.load(f)
    with open(os.path.join(fc.GAME_CFG, "l3_city.json"), encoding="utf-8") as f:
        n_city = len(json.load(f)["tiles"])
    with open(os.path.join(fc.FIELDS_DIR, "city_culture.json"),
              encoding="utf-8") as f:
        cc = json.load(f)
    if len(src["sources"]) != k:
        check_fail(fails, "源点表", "源点数 %d ≠ 矩阵 %d" % (len(src["sources"]), k))
    elif len(cc["cities"]) != n_city:
        check_fail(fails, "城采样", "城数 %d ≠ l3_city tiles %d"
                   % (len(cc["cities"]), n_city))
    elif any(s.get("morph_seed") is None for s in src["sources"]):
        check_fail(fails, "源点表", "缺 morph_seed 占位")
    else:
        liv = {}
        for s in src["sources"]:
            liv[s["livelihood"]] = liv.get(s["livelihood"], 0) + 1
        check_ok("源点表/城采样", "%d 源点（语系 %d，生计 %s）；城采样 %d 对表"
                 % (k, len({s["family"] for s in src["sources"]}), liv, n_city))

    print("=================================")
    if fails:
        print("FAIL（%d 项）" % len(fails))
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
