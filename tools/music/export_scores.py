# -*- coding: utf-8 -*-
"""导出全部曲目的乐谱（MusicXML）——交付件里"除音频之外"的那一半。

产出一份能被 MuseScore / Sibelius / Dorico 直接打开、也能打印的谱。
谱的定位是**耐久与可读**：代码（`compose/themes.py` + `cues.py`）是演奏数据，
谱是给人看、给人改、给未来留底的版本。两者逐音对应，记谱细节见
`musiclib/sheet.py` 的文件头说明（时值量化到十六分、跨小节连音线、反复记号）。

    python tools/music/export_scores.py                  # 全部 → tools/music/scores/
    python tools/music/export_scores.py --out D:/谱子
    python tools/music/export_scores.py --cue village    # 单首
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))

from compose import cues as CUES                        # noqa: E402
from musiclib import sheet as SHEET                     # noqa: E402


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)
    except Exception:  # noqa: BLE001
        pass
    ap = argparse.ArgumentParser(description="导出全部曲目的 MusicXML 乐谱")
    ap.add_argument("--out", default=str(HERE / "scores"),
                    help="输出目录（默认 tools/music/scores，随仓库入库）")
    ap.add_argument("--cue", default=None, help="逗号分隔，只导指定 cue")
    args = ap.parse_args()

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    ids = [s.strip() for s in args.cue.split(",") if s.strip()] if args.cue \
        else [cid for cid, _ in CUES.BUILDERS]

    total = 0
    bad = 0
    print("%-14s %-10s %-12s %4s %5s %6s" % ("cue", "曲名", "调性", "声部",
                                             "小节", "音符"))
    for cid in ids:
        cue = CUES.build_one(cid)
        path = str(out_dir / ("%s.musicxml" % cid))
        info = SHEET.export_musicxml(cue, path)
        problems = SHEET.verify_musicxml(path, cue)
        code_h, score_h = SHEET.pitch_histogram(cue, path)
        if code_h != score_h:
            problems.append("音高直方图与代码不一致：代码 %d 音 / 谱 %d 音"
                            % (sum(code_h.values()), sum(score_h.values())))
        bad += len(problems)
        for msg in problems:
            print("   ! %s: %s" % (cid, msg))
        total += info["notes"]
        print("%-14s %-10s %-12s %4d %5d %6d"
              % (cid, info["title"], info["key"], info["parts"], info["bars"],
                 info["notes"]))

    size = sum(f.stat().st_size for f in out_dir.glob("*.musicxml"))
    print("")
    print("[完成] %d 份乐谱 / %d 个音符 / %.0f KB → %s"
          % (len(ids), total, size / 1024.0, out_dir))
    if bad:
        print("[x] 谱面自检发现 %d 处问题（见上）" % bad)
        return 1
    print("[ok] 谱面自检通过（小节时值完整、连音线配平）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
