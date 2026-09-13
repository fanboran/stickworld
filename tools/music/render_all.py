# -*- coding: utf-8 -*-
"""一键跑完整条音乐管线：谱面 → MIDI → 分轨渲染 → 混音母带 → 交付 OGG。

    python tools/music/render_all.py                  # 全部
    python tools/music/render_all.py --only field_day # 单首
    python tools/music/render_all.py --list           # 列出 cue
    python tools/music/render_all.py --skip-render    # 只重混音（改混音参数后用）

中间产物全部落在 `tools/music/out/`（gitignored），交付件落在
`stick-world/assets/audio/bgm/`（进版本库，游戏直接加载）。
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))

from compose import cues as CUES                      # noqa: E402
from musiclib import export as EX                     # noqa: E402
from musiclib import mix as MIX                       # noqa: E402
from musiclib import render as R                      # noqa: E402
from musiclib import score as S                       # noqa: E402

OUT = HERE / "out"
DELIVER = REPO / "stick-world" / "assets" / "audio" / "bgm"
QA_JSON = OUT / "qa_report.json"
MIX_REPORT = OUT / "mix_report.json"


def process_cue(cue, skip_render: bool = False, skip_ogg: bool = False,
                ogg_quality: int = 6) -> dict:
    t0 = time.time()
    cid = cue.cue_id
    is_loop = getattr(cue, "loop", True)
    print("\n=== %s  %s  (%s %s, %s bpm, %d 小节%s)"
          % (cid, cue.title, cue.key, cue.scale, cue.bpm, cue.bars,
             "" if is_loop else ", 一次性"))

    midi_dir = OUT / "midi" / cid
    midi_map = S.export_all_stems(cue, midi_dir)

    stems_dir = OUT / "stems" / cid
    if skip_render:
        render_info = {}
        for name in midi_map:
            w = stems_dir / ("%s.wav" % name)
            if not w.exists():
                raise FileNotFoundError("缺少已渲染的分轨：%s（去掉 --skip-render 重跑）" % w)
            render_info[name] = {"wav": str(w), "cached": True}
    else:
        render_info = R.render_cue(cue, midi_map, stems_dir)

    overrides = CUES.MIX_OVERRIDES.get(cid, {})
    # 一次性 sting 比循环曲目高 1dB（-14 vs -15）：事件强调靠的是瞬态与不被掩蔽，
    # 不靠绝对响度，所以不把它做成"比音乐响很多"的号角。
    target = None if is_loop else -14.0
    audio, report = MIX.mix_cue(cue, {n: i["wav"] for n, i in render_info.items()},
                                overrides=overrides, target_lufs=target,
                                wrap_tail=is_loop)
    report["loop"] = is_loop
    report["bar_beats"] = cue.beats_per_bar
    report["render_seconds"] = round(time.time() - t0, 1)

    master = OUT / "master" / ("%s.wav" % cid)
    MIX.save_mix(audio, str(master))

    # 交付：每个 cue 一个目录，各层一个 OGG
    if not skip_ogg:
        ddir = DELIVER / cid
        ddir.mkdir(parents=True, exist_ok=True)
        report["delivered"] = []
        for name, info in render_info.items():
            ogg = ddir / ("%s.ogg" % name)
            meta = EX.ogg_encode(info["wav"], str(ogg), quality=ogg_quality)
            report["delivered"].append({"stem": name, **meta})
            print("    [ogg] %-10s %s  (%.2f MB, %.0f kbps)"
                  % (name, ogg.name, meta["bytes"] / 1e6, meta["kbps"]))
        # 引擎清单需要的字段
        report["stems"] = sorted(render_info.keys())
        report["loop_beats"] = (cue.loop_end_beat - cue.loop_start_beat)

    print("    响度 %.2f LUFS | 真峰值 %.2f dBTP | LRA %.2f LU | 刺耳度 %.3f | "
          "循环接缝 %s | 用时 %.0fs"
          % (report["integrated_lufs"], report["true_peak_dbtp"],
             report["loudness_range_lu"], report["harshness_score"],
             ("%.1f dB" % report["seam_jump_rms_db"]) if "seam_jump_rms_db" in report else "—",
             report["render_seconds"]))
    return report


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)
    except Exception:  # noqa: BLE001
        pass
    ap = argparse.ArgumentParser(description="音乐管线总编排")
    ap.add_argument("--only", action="append", default=None,
                    help="只处理指定 cue（可重复）")
    ap.add_argument("--list", action="store_true", help="列出全部 cue")
    ap.add_argument("--skip-render", action="store_true",
                    help="跳过采样渲染，复用 out/stems 里已有的 WAV")
    ap.add_argument("--skip-ogg", action="store_true", help="不编码 OGG")
    ap.add_argument("--ogg-quality", type=int, default=7)
    ap.add_argument("--no-clean", action="store_true",
                    help="不清理交付目录里的陈旧文件")
    args = ap.parse_args()

    if args.list:
        for cid, fn in CUES.BUILDERS:
            cue = fn()
            print("%-14s %-8s %s %s  %s bpm  %d 小节  %s"
                  % (cid, cue.title, cue.key, cue.scale, cue.bpm, cue.bars,
                     "循环" if getattr(cue, "loop", True) else "一次性"))
        return 0

    OUT.mkdir(parents=True, exist_ok=True)
    selected = args.only or [cid for cid, _ in CUES.BUILDERS]

    # 渲染引擎可用性预检，早失败早报错
    if not args.skip_render:
        try:
            R.piano_sfz()
        except FileNotFoundError as e:
            print("[错误] %s" % e, file=sys.stderr)
            print("       先运行：python tools/music/setup_toolchain.py", file=sys.stderr)
            return 2
        try:
            R.soundfont()
        except FileNotFoundError as e:
            print("[错误] %s" % e, file=sys.stderr)
            print("       需要一份 GM SoundFont（.sf2/.sf3）放到工具链的 soundfonts/ 目录",
                  file=sys.stderr)
            return 2

    reports = []
    for cid in selected:
        cue = CUES.build_one(cid)
        reports.append(process_cue(cue, skip_render=args.skip_render,
                                   skip_ogg=args.skip_ogg,
                                   ogg_quality=args.ogg_quality))

    # 汇总：混音报告 + QA 报告 + 引擎清单
    MIX_REPORT.write_text(json.dumps(reports, ensure_ascii=False, indent=2),
                          encoding="utf-8")
    if not args.skip_ogg:
        manifest = EX.build_manifest(reports)
        EX.write_manifest(manifest, str(DELIVER / "music_manifest.json"))
        print("\n[交付] %d 个 cue 写入 %s" % (len(reports), DELIVER))
        print("[清单] %s（%d 个 cue / %d 个层）"
              % (DELIVER / "music_manifest.json", manifest["cue_count"],
                 sum(len(c["layers"]) for c in manifest["cues"].values())))
    print("\n[中间件] %s" % OUT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
