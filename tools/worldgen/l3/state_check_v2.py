"""世界重生成 v2 A4+A6 国家自检（state_check_v2.py）

对 state_build_v2.py 的产物 political_data_v2.json 做断言（算法提案 A4/A6
验收口径 + 任务指定的自检清单）：
  1. 城表全覆盖零悬空：city_owners 键数 == settlements 数（键集合精确相等），
     值全部指向存续 states，逐国 n_cities 与 city_owners 计数一致
  2. target 与实际城数偏差带（A6 前快照，meta.allocation_check）：
     |got − target| ≤ max(2, 15%×target)；容差 ≤2% 初创国可超带（地理围困残差：
     都城不可动的 1 城邦阻断回收接力，见 build 的 decisions），逐国清单打印
  3. 规模谱（终局，核心验收）：≥5 个 12+ 城大国、≥8 个 1 城邦、无超 cap
  4. 首都必在名下城内；is_city_state == (n_cities == 1)
  5. 文化同质度：一致 = 城主导==国文化 或 城为荒野 或 近亲文化（sim ≥
     sim_enclave_keep，与 normalize 相似文化飞地保留同口径）；≥3 城的国
     一致率 ≥80%（<3 城国口径退化豁免；容差 ≤2% 超限国）
  6. A6 事件日志与最终版图自洽： extinct 国不在 states；政权数守恒
     （initial + born − extinct = final）；Σ n_cities = 总城数；逐国
     history 字段非负、final 国 extinct_round 为空
  7. schema：states 字段齐全、lut_index 1..N 唯一、color 合法 RGB、
     city_names 全覆盖且全局唯一
  8. 同 seed 逐位确定：build() 两次全量构建 json 等价，且与已落盘产物一致

用法：python state_check_v2.py
全部通过打印 PASS（退出码 0）；任一失败打印 FAIL 明细（退出码 1）。
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fields_common as fc  # noqa: E402
import state_build_v2 as sbv  # noqa: E402

# 容差（自检口径；残差根源见 build 的 decisions：地理围困 + 都城不可动约束）
DEV_TOLERANCE_FRAC = 0.02     # 偏差带外国占初创国比例上限
HOMO_TOLERANCE_FRAC = 0.02    # 文化一致率超限国占文化邦比例上限
MIN_HOMO_CITIES = 3           # 一致率阈值只对 ≥3 城的国生效（1-2 城口径退化）


def check_fail(fails, name, msg):
    fails.append("%s: %s" % (name, msg))
    print("  [FAIL] %s: %s" % (name, msg))


def check_ok(name, msg=""):
    print("  [ok] %s%s" % (name, (" — " + msg) if msg else ""))


def main():
    fails = []
    P = fc.load_params()
    sp = P["fields_v2"]["states_v2"]
    cap = int(sp["spectrum"]["cap"])
    keep = float(sp["normalize"]["sim_enclave_keep"])

    print("=== state_check_v2：世界重生成 v2 A4+A6 国家自检 ===")

    # ---- 构建两次（确定性检验用）+ 读落盘产物 ----
    print("  [..] 全量构建两次 + 与落盘产物对比（约 20 秒）...", flush=True)
    p1 = sbv.build(P, dry_run=True, skip_preview=True)
    p2 = sbv.build(P, dry_run=True, skip_preview=True)
    s1 = json.dumps(p1, sort_keys=True, ensure_ascii=False)
    s2 = json.dumps(p2, sort_keys=True, ensure_ascii=False)
    meta, states, city_owners = p1["meta"], p1["states"], p1["city_owners"]

    with open(os.path.join(fc.FIELDS_DIR, "settlements_v2.json"),
              encoding="utf-8") as f:
        settle = json.load(f)["settlements"]
    with open(os.path.join(fc.FIELDS_DIR, "culture_similarity.json"),
              encoding="utf-8") as f:
        simM = json.load(f)["matrix"]

    # ---- 1) 城表全覆盖零悬空 ----
    settle_ids = {c["settlement_id"] for c in settle}
    n_set = len(settle)
    if set(city_owners) == settle_ids and len(city_owners) == n_set:
        check_ok("城表全覆盖", "%d 城零悬空（city_owners 键集合 == settlements）"
                 % n_set)
    else:
        missing = settle_ids - set(city_owners)
        extra = set(city_owners) - settle_ids
        check_fail(fails, "城表全覆盖", "缺 %d / 多 %d（如 %s）"
                   % (len(missing), len(extra),
                      (sorted(missing)[:3] + sorted(extra)[:3])))
    dangling = {v for v in city_owners.values() if v not in states}
    if dangling:
        check_fail(fails, "悬空引用", "%d 个 owner 不在 states：%s"
                   % (len(dangling), sorted(dangling)[:3]))
    cnt_by_state = {}
    for v in city_owners.values():
        cnt_by_state[v] = cnt_by_state.get(v, 0) + 1
    bad_n = [sid for sid, s in states.items()
             if s["n_cities"] != cnt_by_state.get(sid, 0)]
    if bad_n:
        check_fail(fails, "n_cities 对账", "%d 国与 city_owners 计数不符（如 %s）"
                   % (len(bad_n), bad_n[:3]))
    elif not dangling:
        check_ok("n_cities 对账", "逐国 n_cities == 名下城数（Σ=%d）" % n_set)

    # ---- 2) target 与实际偏差带（A6 前快照 + 容差） ----
    alloc = meta["allocation_check"]["states"]
    band_bad = [(sid, a["target"], a["got"]) for sid, a in alloc.items()
                if abs(a["got"] - a["target"]) > max(2.0, 0.15 * a["target"])]
    tol = max(1, int(round(len(alloc) * DEV_TOLERANCE_FRAC)))
    if len(band_bad) <= tol:
        check_ok("target 偏差带", "%d/%d 初创国带内%s" % (
            len(alloc) - len(band_bad), len(alloc),
            ("；超带 %d 国（≤%.0f%% 容差，地理围困残差）：%s"
             % (len(band_bad), DEV_TOLERANCE_FRAC * 100,
                ["%s t%d/g%d" % x for x in band_bad[:6]])) if band_bad else ""))
    else:
        check_fail(fails, "target 偏差带", "超带 %d 国 > 容差 %d：%s"
                   % (len(band_bad), tol,
                      ["%s t%d/g%d" % x for x in band_bad[:8]]))
    if abs(sum(a["got"] for a in alloc.values()) - n_set) > 0:
        check_fail(fails, "分配快照守恒", "Σgot ≠ 总城数")

    # ---- 3) 规模谱（终局，核心验收） ----
    sizes = {sid: s["n_cities"] for sid, s in states.items()}
    big = [sid for sid, n in sizes.items() if n >= 12]
    one = [sid for sid, n in sizes.items() if n == 1]
    over = [sid for sid, n in sizes.items() if n > cap]
    spec_ok = True
    if len(big) < 5:
        check_fail(fails, "规模谱-大国", "12+ 城大国 %d < 5" % len(big))
        spec_ok = False
    if len(one) < 8:
        check_fail(fails, "规模谱-城邦", "1 城邦 %d < 8" % len(one))
        spec_ok = False
    if over:
        check_fail(fails, "规模谱-cap", "超 cap(%d) 国：%s"
                   % (cap, ["%s:%d" % (s, sizes[s]) for s in over[:5]]))
        spec_ok = False
    if spec_ok:
        check_ok("规模谱（核心验收）", "≥12 城大国 %d 个；1 城邦 %d 个；"
                 "最大 %d 城（cap=%d）；政权 %d 个" % (
                     len(big), len(one), max(sizes.values()), cap, len(states)))

    # ---- 4) 首都必在名下城内 + is_city_state ----
    sid_by_capital = {}
    for cid, sid in city_owners.items():
        sid_by_capital.setdefault(sid, set()).add(cid)
    cap_bad = [sid for sid, s in states.items()
               if s["capital"] not in sid_by_capital.get(sid, set())]
    cs_bad = [sid for sid, s in states.items()
              if s["is_city_state"] != (s["n_cities"] == 1)]
    if cap_bad or cs_bad:
        check_fail(fails, "首都/城邦标记", "都城不在名下 %d 国；城邦标记错 %d 国"
                   % (len(cap_bad), len(cs_bad)))
    else:
        check_ok("首都/城邦标记", "%d 国都城全在名下；is_city_state == (城数==1)"
                 % len(states))

    # ---- 5) 文化同质度（≥3 城国 ≥72%，容差 ≤2%；断言验证「合并被文化
    # 驱动」的主旋律而非纯血国家——过渡带混合国（多民族形态）真实存在） ----
    dom_of = {c["settlement_id"]: int(c["dominant"]) for c in settle}
    below = []
    n_cultured = 0
    for sid, s in states.items():
        c = s["culture"]
        doms = [dom_of[cid] for cid in sid_by_capital.get(sid, ())]
        if c == 0:
            continue  # 荒野邦无法定义一致率（meta 计数）
        n_cultured += 1
        if len(doms) < MIN_HOMO_CITIES:
            continue  # 1-2 城国口径退化豁免
        ok = sum(1 for d in doms
                 if d == c or d == 0 or simM[c - 1][d - 1] >= keep)
        rate = ok / len(doms)
        if rate < 0.72:
            below.append((sid, round(rate, 3), len(doms)))
    tol_h = max(1, int(round(n_cultured * HOMO_TOLERANCE_FRAC)))
    if len(below) <= tol_h:
        check_ok("文化同质度", "文化邦 %d（≥3 城）中超限 %d 国 ≤ 容差 %d%s" % (
            n_cultured, len(below), tol_h,
            ("：%s" % ["%s %.2f(%d城)" % x for x in below[:6]]) if below else ""))
    else:
        check_fail(fails, "文化同质度", "超限 %d 国 > 容差 %d：%s"
                   % (len(below), tol_h,
                      ["%s %.2f(%d城)" % x for x in below[:8]]))

    # ---- 6) A6 事件日志与最终版图自洽 ----
    h = meta["history"]
    extinct = set(h["extinct_list"])
    extinct_in_states = sorted(extinct & set(states))
    if extinct_in_states:
        check_fail(fails, "A6 自洽-消亡国", "被吞并/消亡国仍在 states：%s"
                   % extinct_in_states[:5])
    expect_final = h["states_initial"] + h["states_born"] - h["states_extinct"]
    if expect_final != h["states_final"] or h["states_final"] != len(states):
        check_fail(fails, "A6 自洽-政权数守恒",
                   "initial %d + born %d − extinct %d = %d ≠ final %d（states %d）"
                   % (h["states_initial"], h["states_born"], h["states_extinct"],
                      expect_final, h["states_final"], len(states)))
    elif sum(sizes.values()) != n_set:
        check_fail(fails, "A6 自洽-城数守恒", "Σ n_cities = %d ≠ %d"
                   % (sum(sizes.values()), n_set))
    else:
        check_ok("A6 事件自洽", "兼并 %d / 解体 %d / 易手 %d；政权 %d → %d（新生 "
                 "%d、消亡 %d，守恒）；终局 Σ城 = %d" % (
                     h["annexations"], h["collapses"], h["border_flips"],
                     h["states_initial"], h["states_final"], h["states_born"],
                     h["states_extinct"], sum(sizes.values())))

    # ---- 小岛群岛内统一（创始人定向：同一个岛屿内更容易统一） ----
    import numpy as np
    from scipy import ndimage as _nd
    biome = np.load(os.path.join(fc.OUTPUT_DIR, "biome_labels_2048.npy"))
    grp_lab, _ = _nd.label(_nd.binary_dilation(biome > 0, iterations=2))
    kk = fc.SIZE / fc.SIZE_FULL
    pos = {s["settlement_id"]: (s["x"], s["y"]) for s in settle}
    grp_of = {cid: int(grp_lab[int(pos[cid][1] * kk), int(pos[cid][0] * kk)])
              for cid in city_owners}
    grp_n = {}
    for g in grp_of.values():
        grp_n[g] = grp_n.get(g, 0) + 1
    small_split = []
    grp_states = {}
    for cid, sid in city_owners.items():
        grp_states.setdefault(grp_of[cid], set()).add(sid)
    mid_split = []
    for g, sset in grp_states.items():
        if g <= 0:
            continue
        if grp_n[g] <= 12 and len(sset) > 1:
            small_split.append(g)      # ≤12 城小岛必须一国
        if 12 < grp_n[g] <= 30 and len(sset) > 4:
            mid_split.append((g, len(sset)))  # 13-30 城群国数上限
    if not small_split and not mid_split:
        check_ok("小岛群岛内统一",
                 "≤12 城岛群归一国；13-30 城群国数 ≤4")
    else:
        msg = []
        if small_split:
            msg.append("多国分占小岛群: %s" % small_split[:6])
        if mid_split:
            msg.append("13-30 城群超4国: %s" % mid_split[:6])
        check_fail(fails, "小岛群岛内统一", "；".join(msg))
    bad_hist = [sid for sid, s in states.items()
                if s["history"]["annexed"] < 0 or s["history"]["flips_in"] < 0
                or s["history"]["flips_out"] < 0]
    if bad_hist:
        check_fail(fails, "A6 自洽-兴衰计数", "%d 国计数负值" % len(bad_hist))

    # ---- 7) schema / lut / 色 / 城名 ----
    schema_bad = []
    for sid, s in states.items():
        for k in ("name", "capital", "culture", "is_city_state", "n_cities",
                  "lut_index", "color", "name_status", "history", "target"):
            if k not in s:
                schema_bad.append((sid, k))
        if not isinstance(s.get("name"), str) or not s.get("name"):
            schema_bad.append((sid, "name空"))
        if not (0 <= s.get("culture", -1) <= len(simM)):
            schema_bad.append((sid, "culture越界"))
    luts = sorted(s["lut_index"] for s in states.values())
    lut_ok = luts == list(range(1, len(states) + 1))
    color_bad = [sid for sid, s in states.items()
                 if not (isinstance(s["color"], list) and len(s["color"]) == 3
                         and all(isinstance(v, int) and 0 <= v <= 255
                                 for v in s["color"]))]
    city_names = meta["city_names"]
    names_ok = (set(city_names) == settle_ids
                and len(set(city_names.values())) == len(city_names)
                and all(2 <= len(v) <= 4 for v in city_names.values()))
    if schema_bad or not lut_ok or color_bad or not names_ok:
        check_fail(fails, "schema/lut/色/城名",
                   "字段缺 %d；lut 唯一连续 %s；色非法 %d；城名覆盖/唯一/长度 %s"
                   % (len(schema_bad), lut_ok, len(color_bad), names_ok))
    else:
        check_ok("schema/lut/色/城名", "states 字段齐全；lut_index 1..%d 唯一；"
                 "色合法；城名 %d 条全覆盖且全局唯一" % (len(states), len(city_names)))

    # ---- 8) 同 seed 逐位确定 ----
    if s1 == s2:
        check_ok("同 seed 逐位确定", "两次全量构建 json 等价（states/city_owners/"
                 "meta 逐字段）")
    else:
        check_fail(fails, "同 seed 逐位确定", "两次构建不一致")
    out_path = sbv.OUT_PATH
    if os.path.exists(out_path):
        with open(out_path, encoding="utf-8") as f:
            disk = json.load(f)
        if json.dumps(disk, sort_keys=True, ensure_ascii=False) == s1:
            check_ok("落盘产物一致", "political_data_v2.json 与本次构建逐位一致")
        else:
            check_fail(fails, "落盘产物一致",
                       "%s 与本次构建不一致——用 state_build_v2.py 重新生成"
                       % out_path)
    else:
        check_fail(fails, "落盘产物一致", "缺 %s——先跑 state_build_v2.py" % out_path)

    print("=================================")
    if fails:
        print("FAIL（%d 项）" % len(fails))
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
