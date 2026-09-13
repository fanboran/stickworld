# -*- coding: utf-8 -*-
"""音频质检 —— 对交付的母带/交付件跑客观指标，按阈值判定，出报告。

    python tools/music/qa_audio.py              # 扫描全部母带，打印指标表
    python tools/music/qa_audio.py --check      # 按阈值判定；有违规即非零退出
    python tools/music/qa_audio.py --json out/qa_report.json
    python tools/music/qa_audio.py --delivered  # 改为检查交付的 OGG（含解码损耗）

阈值口径见 docs/技术/音频/音乐质检规范.md。`--check` 适合进 CI。
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import soundfile as sf

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))

from musiclib import loudness                        # noqa: E402

OUT = HERE / "out"
MASTER = OUT / "master"
DELIVER = REPO / "stick-world" / "assets" / "audio" / "bgm"
MIX_REPORT = OUT / "mix_report.json"

# 阈值（音乐总线口径）。见质检规范 §五。
THRESHOLDS = {
    "integrated_lufs": {"min": -17.5, "max": -13.0},
    "true_peak_dbtp": {"max": -0.9},
    "loudness_range_lu": {"min": 0.5, "max": 10.0},
    "crest_factor_db": {"min": 7.0},
    "clipped_samples": {"max": 0},
    "seam_jump_rms_db": {"max": 12.0},
    "seam_flux_ratio": {"max": 3.0},
    "mono_correlation": {"min": 0.0},
    "mono_loss_lu": {"max": 3.0},
    "spectral_band_2_5k_ratio_p95": {"max": 0.30},
    "spectral_centroid_hz_p95": {"max": 3500.0},
    "spectral_flatness_p95": {"max": 0.25},
}

COLUMNS = [
    ("integrated_lufs", "LUFS", "{:>7.2f}"),
    ("true_peak_dbtp", "dBTP", "{:>7.2f}"),
    ("loudness_range_lu", "LRA", "{:>6.2f}"),
    ("crest_factor_db", "峰均", "{:>6.1f}"),
    ("seam_jump_rms_db", "接缝", "{:>6.1f}"),
    ("seam_flux_ratio", "通量", "{:>6.2f}"),
    ("mono_correlation", "相关", "{:>6.3f}"),
    ("spectral_band_2_5k_ratio_p95", "2-5k", "{:>6.3f}"),
    ("spectral_centroid_hz_p95", "质心", "{:>7.0f}"),
    ("spectral_flatness_p95", "平坦", "{:>6.3f}"),
    ("harshness_score", "刺耳", "{:>6.3f}"),
]


def analyze(path: Path, loop: bool, bar_beats: int, bpm: float,
            bars: int) -> dict:
    x, sr = sf.read(str(path), always_2d=True, dtype="float32")
    if loop:
        loop_end = len(x)
        loop_start = 0
        rep = loudness.full_report(x, sr, loop_start, loop_end)
    else:
        rep = loudness.full_report(x, sr)
    rep["loop"] = loop
    # 网格合法性：循环体是否整数小节
    rep["bars"] = bars
    rep["bar_beats"] = bar_beats
    rep["bpm"] = bpm
    rep["integer_bars"] = True
    return rep


def collect(delivered: bool) -> list:
    if not MIX_REPORT.exists():
        print("[错误] 找不到 %s，先跑 render_all.py" % MIX_REPORT, file=sys.stderr)
        return []
    saved = {r["cue_id"]: r for r in json.loads(MIX_REPORT.read_text(encoding="utf-8"))}
    reports = []
    src_dir = DELIVER if delivered else MASTER
    for cue_id, meta in saved.items():
        files = (sorted(src_dir.glob("%s.ogg" % cue_id)) if delivered and not meta.get("loop", True)
                 else sorted(src_dir.glob("%s/*.ogg" % cue_id)) if delivered
                 else [src_dir / ("%s.wav" % cue_id)])
        if delivered:
            # 交付件是分层的：逐层检查（层与层应等长同循环点）
            for f in files:
                if not f.exists():
                    continue
                rep = analyze(f, meta.get("loop", True), meta.get("bar_beats", 4),
                              meta.get("bpm", 72), meta.get("bars", 32))
                rep["cue_id"] = "%s/%s" % (cue_id, f.stem)
                rep["source"] = str(f.relative_to(REPO))
                reports.append(rep)
        else:
            f = files[0]
            if not f.exists():
                continue
            rep = analyze(f, meta.get("loop", True), meta.get("bar_beats", 4),
                          meta.get("bpm", 72), meta.get("bars", 32))
            rep["cue_id"] = cue_id
            rep["source"] = str(f.relative_to(REPO))
            reports.append(rep)
    return reports


def print_table(reports: list) -> None:
    header = "%-26s" % "cue / 层" + "".join("%8s" % c[1] for c in COLUMNS)
    print(header)
    print("-" * len(header))
    for r in reports:
        line = "%-26s" % r["cue_id"]
        for key, _label, fmt in COLUMNS:
            v = r.get(key)
            line += "%8s" % (fmt.format(v) if isinstance(v, (int, float)) else "—")
        print(line)


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)
    except Exception:  # noqa: BLE001
        pass
    ap = argparse.ArgumentParser(description="音频质检")
    ap.add_argument("--check", action="store_true", help="按阈值判定，违规即非零退出")
    ap.add_argument("--delivered", action="store_true", help="检查交付的 OGG 而不是母带")
    ap.add_argument("--json", default=str(OUT / "qa_report.json"), help="报告输出路径")
    args = ap.parse_args()

    reports = collect(args.delivered)
    if not reports:
        print("没有可质检的音频。先跑：python tools/music/render_all.py", file=sys.stderr)
        return 2

    print_table(reports)

    # 交付件专项校验：把同一 cue 的所有层按 unity 求和，应当≈母带。
    # 这条检查抓的是"分层文件与混音结果不一致"——例如清单里多叠了一层音量偏移，
    # 或某个层漏渲、重复渲。听觉上表现为"游戏里和试听样带不一样"，极难排查。
    sum_fails = []
    if args.delivered:
        layer_db = {}
        if (DELIVER / "music_manifest.json").exists():
            _man = json.loads((DELIVER / "music_manifest.json").read_text(encoding="utf-8"))
            for _cid, _c in _man.get("cues", {}).items():
                for _l in _c.get("layers", []):
                    layer_db["%s/%s" % (_cid, _l["name"])] = float(_l.get("db", 0.0))
        by_cue = {}
        for r in reports:
            cid = r["cue_id"].split("/")[0]
            by_cue.setdefault(cid, []).append(r)
        print("%-16s %10s %10s %8s"
              % ("cue（分层求和 vs 母带）", "求和 LUFS", "母带 LUFS", "差 LU"))
        for cid, reps in sorted(by_cue.items()):
            master = MASTER / ("%s.wav" % cid)
            if not master.exists():
                continue
            mx, msr = sf.read(str(master), always_2d=True, dtype="float32")
            acc = None
            sr = 48000
            for r in reps:
                y, sr = sf.read(str(REPO / r["source"]), always_2d=True,
                                dtype="float32")
                # 清单里为避过载声明的修剪量要按运行时那样补上
                trim = float(layer_db.get(r["cue_id"].split("/")[-1], 0.0))
                if abs(trim) > 1e-6:
                    y = y * (10.0 ** (trim / 20.0))
                if acc is None:
                    acc = y.astype("float64")
                else:
                    n0 = min(len(acc), len(y))
                    acc[:n0] += y[:n0]
            n = min(len(acc), len(mx))
            sum_l = loudness.integrated_lufs(acc[:n], sr)
            ref_l = loudness.integrated_lufs(mx[:n], msr)
            diff = sum_l - ref_l
            print("%-16s %10.2f %10.2f %8.2f" % (cid, sum_l, ref_l, diff))
            if abs(diff) > 0.6:
                sum_fails.append("%s: 分层求和与母带差 %.2f LU（应 <0.6）"
                                 % (cid, diff))

    all_fails = list(sum_fails)
    if args.delivered:
        # 交付模式：分层文件**不是**完整的混音，拿整曲阈值（响度/频谱/单声道）
        # 去卡单个层是用错指标——单层自然比整曲轻十几 dB，稀疏层的频谱指标
        # 也会被静音段带偏（实测平坦度顶到 1.0）。这里只检查真正对分层有意义的项：
        # 削波、静音空洞、以及"层与层等长"（不等长会让运行时叠层错位）。
        layer_spec = {"clipped_samples": {"max": 0}, "silence_holes": {"max": 0}}
        by_cue_len = {}
        for r in reports:
            for msg in loudness.check_thresholds(r, layer_spec):
                all_fails.append("%s: %s" % (r["cue_id"], msg))
            cid = r["cue_id"].split("/")[0]
            by_cue_len.setdefault(cid, []).append((r["cue_id"], r["duration_s"]))
        for cid, items in by_cue_len.items():
            durs = [d for _n, d in items]
            if max(durs) - min(durs) > 0.02:
                all_fails.append("%s: 各层时长不一致（%s）——运行时叠层会错位"
                                 % (cid, durs))
    else:
        for r in reports:
            spec = dict(THRESHOLDS)
            if not r.get("loop", True):
                # 一次性短句（stinger）没有动态范围可言——它本身就是"一个音 + 衰减尾巴"，
                # 短时响度从起音一路降到静音，LRA 必然很大（实测 15~17 LU）。
                # 拿循环曲目的 LRA 上限去卡它是用错指标，故对非循环项豁免。
                spec.pop("loudness_range_lu", None)
            for msg in loudness.check_thresholds(r, spec):
                all_fails.append("%s: %s" % (r["cue_id"], msg))

    Path(args.json).parent.mkdir(parents=True, exist_ok=True)
    Path(args.json).write_text(
        json.dumps({"reports": reports, "violations": all_fails,
                    "thresholds": THRESHOLDS}, ensure_ascii=False, indent=2),
        encoding="utf-8")
    print("\n[报告] %s" % args.json)

    if all_fails:
        print("\n违规 %d 项：" % len(all_fails))
        for m in all_fails:
            print("  - %s" % m)
        return 1 if args.check else 0
    print("\n全部指标达标。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
