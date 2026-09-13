# -*- coding: utf-8 -*-
"""音效质检 —— 对**交付件本身**（`stick-world/assets/audio/sfx/*.wav`）跑客观指标
并按阈值判定。

    <PY> tools/sfx/qa_sfx.py            # 打印全部实测指标表
    <PY> tools/sfx/qa_sfx.py --check    # 按阈值判定；有违规即非零退出（进 CI）
    <PY> tools/sfx/qa_sfx.py --json out/qa_report.json

与音乐侧 `tools/music/qa_audio.py` 同构：**读交付字节**（不是重渲染），所以
PCM_16 量化、块对齐、文件长度都在被检查的范围内；逐件元数据（时长窗口、变体数、
响度目标）来自 `sfxlib/design.py` 的配方表，是**唯一真相源**。

## 阈值口径（为什么是这些数）

音效不能照抄音乐阈值（见 `sfxlib/post.py` 模块头 §一：短于 400ms 的信号根本
测不出 BS.1770 积分响度）。本管线用**事件响度 L_evt**（K 加权整段均方、无门限），
它对任意长度都有定义且线性可归一。

  * `clipped_samples == 0` —— **硬门槛**。前一包（Terraria/SWL 提取件）有 4 个
    文件共 8 个削波样点（见质检报告），音效一旦削波就是"炸耳朵"，不接受。
  * `true_peak_dbtp <= -1.0` —— 交付要求。配方表的 `tp`（默认 -1.2）留 0.2dB
    工程余量；实测本包最高 -16.2 dBTP，余量极大（响度目标本身就低）。
  * `|event_lufs - 目标| <= 0.75` —— 母带链的 `normalize_to` 是线性、精确闭合的
    （误差 <0.01 LU），实测偏差只可能来自 `peak_guard` 的"保峰值而少响度"。
    把上限设 0.75 是要让这种缺口**可见**，而不是被限制器抹平。
  * 层内跨度 <=1.5 dB、层间单调 —— 见 `design.LOUDNESS_LAYERS` 的分层理由。
    **两处有意偏离**（`design.LAYER_OVERRIDE`：格挡 +2dB、受击 -1dB）单独按
    "与自身目标一致"检查，并在报告里如实列出——不把它们混进层内跨度去平均掉。
  * 2–5kHz 占用：`busy_run_ms <= 240`（最长**连续**占用）、`busy_ms <= 320`
    （累计），且**长音（>=900ms）的连续占用 <=80ms**。这一带既是人耳最刺耳的
    敏感区，也是音乐的存在感区（钢琴 2.5kHz 微凸），"被占用太久"才是刺耳，
    所以这里卡的是**时间量**而不是能量占比（见 `post.band_busy_ms`）。
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "music"))

from musiclib import loudness                          # noqa: E402
from sfxlib import design as D, post                   # noqa: E402

DELIVER = REPO / "stick-world" / "assets" / "audio" / "sfx"
OUT = HERE / "out"
REPORT = OUT / "qa_report.json"

# ─────────────────────────────── 阈值 ─────────────────────────────────

CLIP_MAX = 0                 # 削波样点数上限（硬门槛）
TP_MAX = -1.0                # 真峰值上限（dBTP）
LUFS_ERR_MAX = 0.75          # 实测 L_evt 与设计目标的偏差（dB）
LAYER_SPAN_MAX = 1.5         # 同一（基础）层内部跨度（dB）
OVERRIDE_ERR_MAX = 0.75      # 覆盖件与自身覆盖目标的偏差（dB）
HL_MEAN_DIFF_MAX = 0.5       # 采集层与生命周期层均值之差（两者同目标）
VARIANT_MIN = post.DISTINCT_MIN_SCORE   # 变体差异下限（1.0）
BUSY_RUN_MAX = 240.0         # 2–5kHz 最长连续占用（ms）
BUSY_TOTAL_MAX = 320.0       # 2–5kHz 累计占用（ms）
LONG_MS = 900.0              # "长音"门槛（ms）
LONG_BUSY_RUN_MAX = 80.0     # 长音的 2–5kHz 连续占用上限（ms）
DC_MAX = 0.005               # 直流偏移上限
LAYERS = ("ui", "harvest", "lifecycle", "combat_fx", "battle")

COLUMNS = [
    ("category", "层", "%-9s"),
    ("duration_ms", "时长ms", "%8.0f"),
    ("event_lufs", "L_evt", "%8.2f"),
    ("lufs_target", "目标", "%7.1f"),
    ("lufs_error", "偏差", "%6.2f"),
    ("true_peak_dbtp", "dBTP", "%7.2f"),
    ("crest_factor_db", "峰均", "%6.1f"),
    ("clipped_samples", "削波", "%5d"),
    ("band2_5k_busy_ms", "2-5k∑", "%7.0f"),
    ("band2_5k_busy_run_ms", "连续", "%6.0f"),
    ("centroid_hz_mean", "质心", "%7.0f"),
    ("mono_correlation", "相关", "%6.3f"),
]


# ─────────────────────────── 读取与度量 ────────────────────────────────

def collect() -> list:
    """逐件读交付 wav 并度量（指标口径见 post.measure）。"""
    reports = []
    missing = []
    for r in D.RECIPES:
        for i, name in enumerate(r.files):
            p = DELIVER / ("%s.wav" % name)
            if not p.exists():
                missing.append(name)
                continue
            x, sr = sf.read(str(p), always_2d=True, dtype="float32")
            if sr != 48000:
                missing.append("%s（采样率 %d，应为 48000）" % (name, sr))
                continue
            rep = post.measure(x, sr, name,
                               lufs_target=D.target_lufs(name),
                               dur_range_ms=r.dur_ms)
            rep["interior_dropouts"] = interior_dropouts(
                x.mean(axis=1), sr, thresh_db=-60.0, min_ms=50.0)
            rep.update({
                "file": p.relative_to(REPO).as_posix(),
                "bytes": p.stat().st_size,
                "event": r.event,
                "category": r.category,
                "variant_index": i,
                "variants_in_event": len(r.files),
                "layer_target": D.layer_of(r.category),
                "override_target": D.LAYER_OVERRIDE.get(name),
                "band_center_hz": r.band_center,
                "overlap": r.overlap,
            })
            reports.append(rep)
    return reports, missing


def collect_kept() -> list:
    """本批**不重写**的自研件（鸟鸣/雨声）——只报数，不参与本批阈值判定。"""
    out = []
    for name in sorted(D.KEPT_SELF_MADE):
        p = DELIVER / ("%s.wav" % name)
        if not p.exists():
            continue
        x, sr = sf.read(str(p), always_2d=True, dtype="float32")
        mono = x.mean(axis=1)
        out.append({
            "name": name,
            "samplerate": int(sr),
            "channels": int(x.shape[1]),
            "duration_ms": round(len(mono) / sr * 1000.0, 1),
            "true_peak_dbtp": round(loudness.true_peak_dbfs(x, sr), 2),
            "clipped_samples": int(loudness.clip_count(x)),
            "integrated_lufs": (None if len(mono) < int(0.4 * sr)
                                else round(float(loudness.integrated_lufs(x, sr)), 2)),
        })
    return out


# ─────────────────────────────── 判定 ─────────────────────────────────

def interior_dropouts(mono: np.ndarray, fs: int, thresh_db: float = -60.0,
                      min_ms: float = 50.0) -> int:
    """一次性音效版的"断音"计数：只数**中间**低于 -60dB 的段。

    音乐的 `loudness.count_silence_holes` 是为**循环体**设计的（尾部静音也算，
    用来抓漏音/断轨），拿它卡一次性打击音是用错指标：本管线对"时长"的定义就是
    "衰减到 -60dB 为止"（`design.tau_for`），所以每件打击音的尾巴最后几十毫秒
    **按定义**就在 -60dB 以下（实测 `ui_confirm` 的 251~270ms 正是这种设计内的
    拖尾）。一次性音效真正要防的是**声音中间被挖掉一段**（编码/裁剪事故会让它
    "断成两截"），所以这里要求：这个静音段之后必须**再次出现**超过阈值的帧。
    """
    win = max(1, int(fs * 0.01))
    n = len(mono) // win * win
    if n == 0:
        return 0
    rms = np.sqrt(np.mean(mono[:n].reshape(-1, win) ** 2, axis=1) + 1e-20)
    quiet = rms < 10 ** (thresh_db / 20.0)
    min_frames = max(1, int(min_ms / 10.0))
    holes, run = 0, 0
    for i, q in enumerate(quiet):
        if q:
            run += 1
            if run == min_frames and not quiet[i + 1:].all():
                holes += 1
        else:
            run = 0
    return holes


def check_reports(reports: list, missing: list) -> tuple:
    """返回 (violations, facts)；facts 里是需要打印/落档的实测汇总量。"""
    bad: list = []
    by_name = {r["name"]: r for r in reports}

    for m in missing:
        bad.append("资产缺失/异常：%s" % m)

    # ① 逐件硬指标
    for r in reports:
        if r["clipped_samples"] > CLIP_MAX:
            bad.append("%s: 削波 %d 个样点（要求 0）"
                       % (r["name"], r["clipped_samples"]))
        if r["true_peak_dbtp"] > TP_MAX:
            bad.append("%s: 真峰值 %.2f dBTP > %.1f" % (r["name"], r["true_peak_dbtp"], TP_MAX))
        if abs(r["lufs_error"]) > LUFS_ERR_MAX:
            bad.append("%s: L_evt 偏差 %.2f dB（|偏差| ≤%.2f）"
                       % (r["name"], r["lufs_error"], LUFS_ERR_MAX))
        lo, hi = r["dur_range_ms"]
        if not (lo <= r["duration_ms"] <= hi):
            bad.append("%s: 时长 %.0fms 不在配方窗口 [%.0f,%.0f]"
                       % (r["name"], r["duration_ms"], lo, hi))
        if r["clipped_samples"] == 0 and r["interior_dropouts"] > 0:
            bad.append("%s: 声音中间有 %d 处断音（>50ms 低于 -60dB 且之后还有声）"
                       % (r["name"], r["interior_dropouts"]))
        if abs(r["dc_offset"]) > DC_MAX:
            bad.append("%s: 直流偏移 %.4f" % (r["name"], r["dc_offset"]))

    # ② 层内一致性 + 覆盖件
    layer_facts = []
    for cat in LAYERS:
        items = [r for r in reports if r["category"] == cat]
        if not items:
            continue
        base = [r["event_lufs"] for r in items if r["name"] not in D.LAYER_OVERRIDE]
        ovr = [r for r in items if r["name"] in D.LAYER_OVERRIDE]
        allv = [r["event_lufs"] for r in items]
        fact = {"layer": cat, "n": len(items), "target": D.layer_of(cat),
                "span_all": round(max(allv) - min(allv), 2),
                "n_base": len(base),
                "span_base": (round(max(base) - min(base), 2) if base else None),
                "base_range": ([round(min(base), 2), round(max(base), 2)] if base else None),
                "overrides": [{"name": r["name"], "event_lufs": r["event_lufs"],
                               "target": r["override_target"]} for r in ovr],
                "mean": round(float(np.mean(allv)), 2)}
        if base:
            fact["span_base"] = round(max(base) - min(base), 2)
            if fact["span_base"] > LAYER_SPAN_MAX:
                bad.append("层 %s：基础件跨度 %.2f dB > %.1f"
                           % (cat, fact["span_base"], LAYER_SPAN_MAX))
        if ovr:
            ov = [r["event_lufs"] for r in ovr]
            fact["span_override"] = round(max(ov) - min(ov), 2)
            for r in ovr:
                if abs(r["event_lufs"] - r["override_target"]) > OVERRIDE_ERR_MAX:
                    bad.append("%s：覆盖目标 %.1f 实测 %.2f（偏差 >%.2f）"
                               % (r["name"], r["override_target"],
                                  r["event_lufs"], OVERRIDE_ERR_MAX))
            if fact["span_override"] > LAYER_SPAN_MAX:
                bad.append("层 %s：覆盖件彼此跨度 %.2f dB > %.1f"
                           % (cat, fact["span_override"], LAYER_SPAN_MAX))
        layer_facts.append(fact)

    # ③ 层间单调：UI ≤ 采集 ≈ 生命周期 < 战斗拟音 < sting
    lm = {f["layer"]: f["mean"] for f in layer_facts}
    if all(k in lm for k in LAYERS):
        mx = {k: max(r["event_lufs"] for r in reports if r["category"] == k)
              for k in LAYERS if any(r["category"] == k for r in reports)}
        mn = {k: min(r["event_lufs"] for r in reports if r["category"] == k)
              for k in LAYERS if any(r["category"] == k for r in reports)}
        if mx["ui"] > mn["harvest"]:
            bad.append("层间：UI(%0.2f) 未低于采集(%0.2f)" % (mx["ui"], mn["harvest"]))
        if abs(lm["harvest"] - lm["lifecycle"]) > HL_MEAN_DIFF_MAX:
            bad.append("层间：采集均值 %.2f 与生命周期 %.2f 相差 >%.1f"
                       % (lm["harvest"], lm["lifecycle"], HL_MEAN_DIFF_MAX))
        if mx["lifecycle"] >= mn["combat_fx"]:
            bad.append("层间：生命周期(%0.2f) 未低于战斗拟音(%0.2f)"
                       % (mx["lifecycle"], mn["combat_fx"]))
        if mx["combat_fx"] >= mn["battle"]:
            bad.append("层间：战斗拟音(%0.2f) 未低于 sting(%0.2f)"
                       % (mx["combat_fx"], mn["battle"]))

    # ④ 变体差异
    pairs = []
    for _ev, items in D.groups().items():
        if len(items) < 2:
            continue
        for i, ra in enumerate(items):
            for rb in items[i + 1:]:
                na, nb = ra.files[0], rb.files[0]
                if na not in by_name or nb not in by_name:
                    continue
                score, axis = post.variant_diff(by_name[na], by_name[nb])
                pairs.append({"a": na, "b": nb, "score": round(score, 2), "axis": axis})
                if score < VARIANT_MIN:
                    bad.append("变体差异不足：%s vs %s = %.2f < %.1f（主导轴 %s）"
                               % (na, nb, score, VARIANT_MIN, axis))
    pairs.sort(key=lambda p: p["score"])

    # ⑤ 2–5kHz 占用
    for r in reports:
        if r["band2_5k_busy_run_ms"] > BUSY_RUN_MAX:
            bad.append("%s: 2–5kHz 连续占用 %.0fms > %.0f"
                       % (r["name"], r["band2_5k_busy_run_ms"], BUSY_RUN_MAX))
        if r["band2_5k_busy_ms"] > BUSY_TOTAL_MAX:
            bad.append("%s: 2–5kHz 累计占用 %.0fms > %.0f"
                       % (r["name"], r["band2_5k_busy_ms"], BUSY_TOTAL_MAX))
        if r["duration_ms"] >= LONG_MS and r["band2_5k_busy_run_ms"] > LONG_BUSY_RUN_MAX:
            bad.append("%s: 长音（%.0fms）的 2–5kHz 连续占用 %.0fms > %.0f"
                       % (r["name"], r["duration_ms"],
                          r["band2_5k_busy_run_ms"], LONG_BUSY_RUN_MAX))

    facts = {
        "layer_facts": layer_facts,
        "worst_true_peak": max(reports, key=lambda r: r["true_peak_dbtp"])["name"]
        if reports else None,
        "max_true_peak_dbtp": max((r["true_peak_dbtp"] for r in reports), default=None),
        "total_clipped": int(sum(r["clipped_samples"] for r in reports)),
        "total_interior_dropouts": int(sum(r["interior_dropouts"] for r in reports)),
        "worst_lufs_error": max(reports, key=lambda r: abs(r["lufs_error"]))["name"]
        if reports else None,
        "max_abs_lufs_error": max((abs(r["lufs_error"]) for r in reports), default=None),
        "variant_pairs": pairs,
        "weakest_variant": pairs[0] if pairs else None,
        "max_busy_run": max(reports, key=lambda r: r["band2_5k_busy_run_ms"])["name"]
        if reports else None,
        "max_busy_run_ms": max((r["band2_5k_busy_run_ms"] for r in reports), default=None),
        "max_busy_ms": max((r["band2_5k_busy_ms"] for r in reports), default=None),
        "thresholds": {
            "clipped_samples_max": CLIP_MAX, "true_peak_dbtp_max": TP_MAX,
            "lufs_error_abs_max": LUFS_ERR_MAX, "layer_span_max": LAYER_SPAN_MAX,
            "override_err_max": OVERRIDE_ERR_MAX,
            "harvest_lifecycle_mean_diff_max": HL_MEAN_DIFF_MAX,
            "variant_diff_min": VARIANT_MIN,
            "band2_5k_busy_run_ms_max": BUSY_RUN_MAX,
            "band2_5k_busy_ms_max": BUSY_TOTAL_MAX,
            "long_ms": LONG_MS, "long_busy_run_ms_max": LONG_BUSY_RUN_MAX,
        },
    }
    return bad, facts


# ─────────────────────────────── 打印 ────────────────────────────────

def print_table(reports: list) -> None:
    header = "%-22s" % "文件" + "".join("%s" % c[1].rjust(
        max(len(c[1]), len(c[2] % 0))) for c in COLUMNS)
    print(header)
    print("-" * len(header))
    for r in reports:
        line = "%-22s" % r["name"]
        for key, _label, fmt in COLUMNS:
            v = r.get(key)
            line += fmt % v if isinstance(v, (int, float)) else ("%s" % v).rjust(9)
        print(line)


def print_facts(facts: dict, kept: list, reports: list) -> None:
    print("\n══ 汇总（实测）" + "═" * 46)
    print("%-11s %4s %8s %8s %8s  %s"
          % ("层", "件数", "目标", "跨度", "均值", "覆盖件"))
    for f in facts["layer_facts"]:
        ov = ",".join("%s=%0.2f" % (o["name"], o["event_lufs"]) for o in f["overrides"])
        span = "%0.2f" % f["span_base"] if f["span_base"] is not None else "—"
        print("%-11s %4d %8.1f %8s %8.2f  %s"
              % (f["layer"], f["n"], f["target"], span, f["mean"], ov or "—"))
    print("整体层内跨度（含覆盖件）：%s"
          % ", ".join("%s=%.2f" % (f["layer"], f["span_all"]) for f in facts["layer_facts"]))
    print("削波样点总数：%d；中间断音总数：%d"
          % (facts["total_clipped"], facts["total_interior_dropouts"]))
    print("真峰值最高：%s（%.2f dBTP，上限 %.1f）"
          % (facts["worst_true_peak"], facts["max_true_peak_dbtp"],
             facts["thresholds"]["true_peak_dbtp_max"]))
    print("L_evt 目标偏差最大：%s（%.2f dB，上限 %.2f）"
          % (facts["worst_lufs_error"], facts["max_abs_lufs_error"],
             facts["thresholds"]["lufs_error_abs_max"]))
    print("2–5kHz 连续占用最长：%s（%.0fms / 上限 %.0f）；累计最长 %.0fms"
          % (facts["max_busy_run"], facts["max_busy_run_ms"],
             facts["thresholds"]["band2_5k_busy_run_ms_max"], facts["max_busy_ms"]))
    long_items = [r for r in reports if r["duration_ms"] >= LONG_MS]
    if long_items:
        w = max(long_items, key=lambda r: r["band2_5k_busy_run_ms"])
        print("长音（≥%.0fms，%d 件）最大连续占用：%s（%.0fms / 上限 %.0f）"
              % (LONG_MS, len(long_items), w["name"],
                 w["band2_5k_busy_run_ms"], LONG_BUSY_RUN_MAX))
    if facts["weakest_variant"]:
        w = facts["weakest_variant"]
        print("变体差异最弱一对：%s vs %s = %.2f（门槛 %.1f，主导轴 %s）"
              % (w["a"], w["b"], w["score"], VARIANT_MIN, w["axis"]))
    if kept:
        print("\n── 本批不重写的自研件（鸟鸣/雨声，只报数不判阈值）──")
        for k in kept:
            print("  %-14s %dHz %dch %7.0fms  TP %6.2f dBTP  削波 %d  LUFS %s"
                  % (k["name"], k["samplerate"], k["channels"], k["duration_ms"],
                     k["true_peak_dbtp"], k["clipped_samples"],
                     ("—" if k["integrated_lufs"] is None else "%.2f" % k["integrated_lufs"])))


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)
    except Exception:  # noqa: BLE001
        pass
    ap = argparse.ArgumentParser(description="音效质检")
    ap.add_argument("--check", action="store_true", help="按阈值判定，违规即非零退出")
    ap.add_argument("--json", default=str(REPORT), help="报告输出路径")
    args = ap.parse_args()

    reports, missing = collect()
    if not reports:
        print("没有可质检的交付件；先跑：<PY> tools/sfx/gen_sfx.py", file=sys.stderr)
        return 2

    print("[质检] 交付目录：%s（%d 件）" % (DELIVER.relative_to(REPO).as_posix(), len(reports)))
    print_table(reports)
    kept = collect_kept()
    bad, facts = check_reports(reports, missing)
    print_facts(facts, kept, reports)

    Path(args.json).parent.mkdir(parents=True, exist_ok=True)
    Path(args.json).write_text(json.dumps(
        {"reports": reports, "kept_self_made": kept, "facts": facts,
         "violations": bad}, ensure_ascii=False, indent=2), encoding="utf-8")
    print("\n[报告] %s" % Path(args.json).relative_to(REPO).as_posix())

    if bad:
        print("\n违规 %d 项：" % len(bad))
        for m in bad:
            print("  - %s" % m)
        return 1 if args.check else 0
    print("\n全部指标达标。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
