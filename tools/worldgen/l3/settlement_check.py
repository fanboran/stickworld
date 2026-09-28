"""世界重生成 v2 A3 聚落自检（settlement_check.py）

对 settlement_build.py 的产物做断言（算法提案 A3 验收口径）：
  1. 产物齐全可解析；label 1..N 连续、settlement_id 对表（settlement_city_%03d）
  2. 数量落在 n_target_band；population_score ∈ [0,1]；level ∈ {1,2,3}（4/5 不产生）
  3. level 阈值映射逐城正确（0.187/0.342 边界，场景口径）
  4. 分群系密度：贫瘠群系（荒漠+冰原）聚落密度显著低于富庶（平原）——比值阈值
  5. 地区内 population_score 近似对数正态：按主导文化分组（≥ MIN_GROUP_N 样本），
     log(score) 正态 Q-Q 相关系数 ≥ 阈值（分位数拟合容差口径）
  6. 位置合法（底图掩膜 eff_land 内）；文化字段合法（dominant 0..K、mix 值域）
  7. 荒地率 > 0（宜居度阈值自然产生荒地，不允许全域铺满）
  8. 同 seed 逐位确定：build() 两次全量构建逐项相等（含浮点）

用法：python settlement_check.py
全部通过打印 PASS（退出码 0）；任一失败打印 FAIL 明细（退出码 1）。
"""

import json
import os
import sys

import numpy as np
from PIL import Image
from scipy.stats import probplot

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fields_common as fc  # noqa: E402
import settlement_build as sb  # noqa: E402

# 阈值（自检口径；与 fields_v2.settlements 参数解耦的验收常数）
BARREN_RICH_RATIO_MAX = 0.6   # 贫瘠(荒漠+冰原)密度 / 平原密度 上限（「显著低于」）
QQ_R_MIN = 0.96               # 组内 log(score) 正态 Q-Q 相关系数下限
MIN_GROUP_N = 30              # 对数正态检验的分组最小样本数
MIN_GROUPS = 5                # 至少要检的分组数
WILDERNESS_MIN = 0.03         # 荒地率下限（荒地必须成片存在，不允许全域铺满）
K_FIELD = sb.K_FIELD


def check_fail(fails, name, msg):
    fails.append("%s: %s" % (name, msg))
    print("  [FAIL] %s: %s" % (name, msg))


def check_ok(name, msg=""):
    print("  [ok] %s%s" % (name, (" — " + msg) if msg else ""))


def load_eff_land():
    """底图原生掩膜（群系陆地排除湖泊）——与 settlement_build 同源。"""
    biome = np.load(os.path.join(fc.OUTPUT_DIR, "biome_labels_2048.npy"))
    lake = np.asarray(Image.open(
        os.path.join(fc.OUTPUT_DIR, "fractal_lake_mask_8192.png")).convert("L"))
    lake = np.asarray(Image.fromarray(lake).resize(
        (fc.SIZE, fc.SIZE), Image.NEAREST)) > 0
    return biome, (biome > 0) & (~lake)


def main():
    fails = []
    P = fc.load_params()
    sp = P["fields_v2"]["settlements"]
    path = os.path.join(fc.FIELDS_DIR, "settlements_v2.json")

    print("=== settlement_check：世界重生成 v2 A3 聚落自检 ===")

    # ---- 1) 产物齐全 + id 对表 ----
    if not os.path.exists(path):
        check_fail(fails, "产物齐全性", "缺 %s——先跑 settlement_build.py" % path)
        print("=================================")
        print("FAIL（%d 项）" % len(fails))
        return 1
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    cities = data["settlements"]
    n = len(cities)
    ok_ids = all(c["settlement_id"] == "settlement_city_%03d" % c["label"]
                 for c in cities)
    ok_seq = [c["label"] for c in cities] == list(range(1, n + 1))
    if ok_ids and ok_seq:
        check_ok("产物齐全性/id", "%d 城，label 1..%d 连续，settlement_id 对表"
                 % (n, n))
    else:
        check_fail(fails, "产物齐全性/id", "label 不连续或 settlement_id 不对表")

    # ---- 2) 数量带 + 值域 ----
    lo, hi = [int(v) for v in sp["n_target_band"]]
    scores = [c["population_score"] for c in cities]
    levels = {c["level"] for c in cities}
    if not (lo <= n <= hi):
        check_fail(fails, "数量目标带", "%d 不在 [%d, %d]" % (n, lo, hi))
    elif min(scores) < 0.0 or max(scores) > 1.0:
        check_fail(fails, "population_score 值域",
                   "越界 [0,1]：[%.4f, %.4f]" % (min(scores), max(scores)))
    elif not levels <= {1, 2, 3}:
        check_fail(fails, "level 档位", "出现 4/5 档或非法档位：%s" % sorted(levels))
    else:
        check_ok("数量/值域/档位", "城数 %d 落 [%d, %d]；score ∈ [%.4f, %.4f]；"
                 "level ⊆ {1,2,3}" % (n, lo, hi, min(scores), max(scores)))

    # ---- 3) level 阈值映射逐城正确 ----
    thr = [float(t) for t in sp["level_thresholds"]]
    bad = [c["label"] for c in cities
           if c["level"] != sb.level_of(c["population_score"], thr)]
    if bad:
        check_fail(fails, "level 映射", "%d 城与阈值 %s 不符（如 label %s）"
                   % (len(bad), thr, bad[:5]))
    else:
        lv = {k: sum(1 for c in cities if c["level"] == k) for k in (1, 2, 3)}
        check_ok("level 映射", "逐城与阈值 %s 一致；谱 %s" % (thr, lv))

    # ---- 4) 分群系密度：贫瘠显著低于富庶 ----
    biome, eff_land = load_eff_land()
    px_plain = int((eff_land & (biome == fc.BI_PLAIN)).sum())
    px_barren = int((eff_land & ((biome == fc.BI_DESERT)
                                 | (biome == fc.BI_ICE))).sum())
    n_plain = sum(1 for c in cities
                  if biome[c["y"] // K_FIELD, c["x"] // K_FIELD] == fc.BI_PLAIN)
    n_barren = sum(1 for c in cities
                   if biome[c["y"] // K_FIELD, c["x"] // K_FIELD]
                   in (fc.BI_DESERT, fc.BI_ICE))
    dens_plain = n_plain / max(px_plain, 1)
    dens_barren = n_barren / max(px_barren, 1)
    ratio = dens_barren / max(dens_plain, 1e-12)
    if ratio > BARREN_RICH_RATIO_MAX:
        check_fail(fails, "分群系密度", "贫瘠/平原密度比 %.3f > %.2f"
                   % (ratio, BARREN_RICH_RATIO_MAX))
    else:
        check_ok("分群系密度", "平原 %.2f vs 贫瘠 %.2f 城/Mpx，比值 %.3f ≤ %.2f"
                 % (dens_plain * 1e6, dens_barren * 1e6, ratio,
                    BARREN_RICH_RATIO_MAX))

    # ---- 5) 地区内 population_score 近似对数正态（按主导文化分组） ----
    groups = {}
    for c in cities:
        groups.setdefault(c["dominant"], []).append(c["population_score"])
    tested, qq_min = 0, 1.0
    for g, ss in sorted(groups.items()):
        ss = [s for s in ss if s > 0.0]      # log 定义域（score=0 仅在 h=0 病态时）
        if len(ss) < MIN_GROUP_N:
            continue
        (_osm, _osr), (_slope, _inter, r) = probplot(np.log(ss), dist="norm",
                                                     fit=True)
        tested += 1
        qq_min = min(qq_min, r)
    big_groups = sum(1 for ss in groups.values()
                     if sum(1 for s in ss if s > 0.0) >= MIN_GROUP_N)
    if tested < MIN_GROUPS:
        check_fail(fails, "对数正态（分文化区）", "可检分组仅 %d < %d（样本过散）"
                   % (tested, MIN_GROUPS))
    elif qq_min < QQ_R_MIN:
        check_fail(fails, "对数正态（分文化区）", "%d 组中最差 Q-Q r=%.4f < %.2f"
                   % (tested, qq_min, QQ_R_MIN))
    else:
        check_ok("对数正态（分文化区）", "%d/%d 组可检（≥%d 样本），最差 Q-Q r=%.4f"
                 " ≥ %.2f" % (tested, big_groups, MIN_GROUP_N, qq_min, QQ_R_MIN))

    # ---- 6) 位置/文化字段合法 ----
    n_cult = 0
    dom_path = os.path.join(fc.FIELDS_DIR, "culture_sources.json")
    if os.path.exists(dom_path):
        with open(dom_path, encoding="utf-8") as f:
            n_cult = len(json.load(f)["sources"])
    bad_pos = [c["label"] for c in cities
               if not eff_land[c["y"] // K_FIELD, c["x"] // K_FIELD]]
    bad_cult = [c["label"] for c in cities
                if not (0 <= c["dominant"] <= n_cult) or not (0.0 <= c["mix"] <= 0.5 + 1e-3)]
    if bad_pos:
        check_fail(fails, "位置合法", "%d 城落在水体/湖外（如 label %s）"
                   % (len(bad_pos), bad_pos[:5]))
    elif bad_cult:
        check_fail(fails, "文化字段", "%d 城 dominant/mix 越界（如 label %s）"
                   % (len(bad_cult), bad_cult[:5]))
    else:
        wild_cult = sum(1 for c in cities if c["dominant"] == 0)
        check_ok("位置/文化字段", "全部在宜居陆地内；dominant 0..%d（荒野无文化 %d 城）、"
                 "mix ∈ [0, 0.5]" % (n_cult, wild_cult))

    # ---- 7) 荒地率 ----
    wild = float(data["stats"]["wilderness_rate"])
    if wild < WILDERNESS_MIN:
        check_fail(fails, "荒地率", "%.1f%% < %.0f%%（宜居度阈值未产生成片荒地）"
                   % (wild * 100, WILDERNESS_MIN * 100))
    else:
        check_ok("荒地率", "宜居陆地中聚落盘未覆盖 %.1f%% ≥ %.0f%%"
                 % (wild * 100, WILDERNESS_MIN * 100))

    # ---- 8) 同 seed 逐位确定（build 两次全量对比） ----
    print("  [..] 同 seed 逐位确定：全量构建两次（约 1-2 分钟）...", flush=True)
    s1, st1, _p1 = sb.build(P)
    s2, st2, _p2 = sb.build(P)
    if s1 == s2 and st1 == st2:
        check_ok("同 seed 逐位确定", "%d 城全字段两次构建逐项相等（stats 亦等）" % len(s1))
    else:
        diff = [a["label"] for a, b in zip(s1, s2) if a != b][:5]
        check_fail(fails, "同 seed 逐位确定", "两次构建不一致（如 label %s）" % diff)

    print("=================================")
    if fails:
        print("FAIL（%d 项）" % len(fails))
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
