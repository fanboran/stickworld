# -*- coding: utf-8 -*-
"""试听样带 —— 把交付音效按类别拼成"能直接双击播放"的样带，供人耳验收。

为什么单独做这一步：交付给引擎的是 38 个 wav + 一张事件表（引擎要的形式），
但不是人能听的形式——没人能开 38 个播放器对齐着听。本脚本把同类的音效串成
几条样带，并在每件之间插入**低电平提示音 + 静音**，让评审者知道"下一件开始了"。

    <PY> tools/sfx/preview.py                       # 全部，输出 temp/sfx_preview
    <PY> tools/sfx/preview.py --out D:/试听
    <PY> tools/sfx/preview.py --fmt ogg

产出（`temp/sfx_preview/`，gitignored）：

  * `10_UI反馈` ~ `50_战斗sting礼炮`：五个类别各一条，**件序 = 配方表顺序**，
    每件前有提示音、后有 420ms 静音。
  * `00_全部`：按层序串起全部 34 件（一遍听完）。
  * `01_层间对比`：每层挑一件代表连续播放——**不做任何归一化**，所以听到的
    音量关系就是游戏里的层间关系（这是分层设计能不能站住的唯一判据）。
  * `manifest.json`：每件在样带里的起止时间与实测 L_evt（便于对照）。

关键：样带**逐件原样拼接、不做归一化**。一旦各件归一化到同一响度，"层内统一 /
层间递减"的设计就被抹平了，样带也就证明不了任何东西——这与
`tools/music/preview.py` 的分层对比是同一条纪律。
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "music"))

from musiclib import export, loudness                  # noqa: E402
from sfxlib import design as D, post                   # noqa: E402

DELIVER = REPO / "stick-world" / "assets" / "audio" / "sfx"
SR = 48000
LAYER_ORDER = ("ui", "harvest", "lifecycle", "combat_fx", "battle")
LAYER_NAME = {"ui": "UI反馈", "harvest": "采集劳作", "lifecycle": "生命周期",
              "combat_fx": "战斗拟音", "battle": "战斗sting礼炮"}
# 层间对比用的代表件（每层一件，取该层"最有代表性"的一个，理由写在汇总里）
REPRESENTATIVE = ("ui_confirm", "harvest_hit_b", "harvest_wood",
                  "build_complete", "unit_hurt_a", "clang_a",
                  "battle_ended_win", "victory_fanfare")

GAP_MS = 420.0        # 件间静音（要求 300~500ms）
PRE_MS = 100.0        # 提示音前静音
BLIP_MS = 50.0        # 提示音长度
POST_BLIP_MS = 120.0  # 提示音后静音


# ─────────────────────────────── 工具 ────────────────────────────────

def read(name: str) -> np.ndarray:
    x, sr = sf.read(str(DELIVER / ("%s.wav" % name)), always_2d=True,
                    dtype="float64")
    if sr != SR:
        raise SystemExit("%s 采样率 %d != %d" % (name, sr, SR))
    return x


def blip(fs: int = SR, peak_db: float = -30.0) -> np.ndarray:
    """件间提示音：50ms 的 1.5kHz 软起振小点。

    刻意做得**比所有音效都轻**（-30dBFS 峰，实测最轻的 ui_hover 峰约 -13.6dB）：
    提示音只负责"标分隔"，不该被误听成一件音效；也不给音乐性（单正弦无泛音）。
    """
    n = int(BLIP_MS / 1000.0 * fs)
    t = np.arange(n) / fs
    env = np.clip(t / 0.004, 0, 1) ** 2 * np.exp(-np.maximum(t - 0.004, 0) / 0.012)
    y = np.sin(2 * np.pi * 1500.0 * t) * env
    y *= 10.0 ** (peak_db / 20.0) / (np.max(np.abs(y)) + 1e-12)
    return np.repeat(y[:, None], 2, axis=1)


def silence(ms: float, fs: int = SR) -> np.ndarray:
    return np.zeros((int(ms / 1000.0 * fs), 2), dtype=np.float64)


def build_reel(names: list) -> tuple:
    """把若干件串成一条样带，返回 (audio, 每件的 [start_s, end_s])。

    **不做归一化、不做限幅**：逐件原样拼接（各件真峰值 ≤ -1.78 dBTP，无重叠
    所以也不会越界）。这正是"听层间关系"的前提。
    """
    parts = [silence(PRE_MS)]
    spans = []
    cursor = PRE_MS / 1000.0
    for name in names:
        parts.append(blip())
        parts.append(silence(POST_BLIP_MS))
        cursor += (BLIP_MS + POST_BLIP_MS) / 1000.0
        x = read(name)
        parts.append(x)
        spans.append({"name": name, "start_s": round(cursor, 3),
                      "end_s": round(cursor + len(x) / SR, 3)})
        cursor += len(x) / SR
        parts.append(silence(GAP_MS))
        cursor += GAP_MS / 1000.0
    return np.concatenate(parts, axis=0), spans


def encode(wav: Path, out: Path, fmt: str = "mp3", bitrate: str = "192k") -> dict:
    out.parent.mkdir(parents=True, exist_ok=True)
    codec = (["-c:a", "libmp3lame", "-b:a", bitrate] if fmt == "mp3"
             else ["-c:a", "libvorbis", "-q:a", "6"])
    cmd = [export.ffmpeg_exe(), "-y", "-loglevel", "error", "-i", str(wav),
           *codec, "-ar", str(SR), "-ac", "2", str(out)]
    proc = subprocess.run(cmd, capture_output=True, text=True,
                          encoding="utf-8", errors="replace")
    if proc.returncode != 0 or not out.exists():
        raise RuntimeError("编码失败：%s\n%s" % (proc.returncode, proc.stderr[-1500:]))
    return {"path": str(out), "mb": round(out.stat().st_size / 1e6, 2)}


# ─────────────────────────────── 主流程 ──────────────────────────────

def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)
    except Exception:  # noqa: BLE001
        pass
    ap = argparse.ArgumentParser(description="音效试听样带")
    ap.add_argument("--out", default=str(REPO / "temp" / "sfx_preview"))
    ap.add_argument("--fmt", default="mp3", choices=["mp3", "ogg"])
    ap.add_argument("--gap", type=float, default=GAP_MS, help="件间静音（ms）")
    args = ap.parse_args()
    globals()["GAP_MS"] = args.gap

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    # 件序：配方表顺序（= design.py 里"从 UI 到武器拟音"的编排顺序）
    by_layer = {c: [f for r in D.RECIPES if r.category == c for f in r.files]
                for c in LAYER_ORDER}
    reels = [("00_全部", [f for c in LAYER_ORDER for f in by_layer[c]])]
    for i, c in enumerate(LAYER_ORDER, start=1):
        reels.append(("%02d_%s" % (i * 10, LAYER_NAME[c]), by_layer[c]))
    reels.append(("01_层间对比", [n for n in REPRESENTATIVE
                                  if (DELIVER / ("%s.wav" % n)).exists()]))

    manifest = {"sample_rate": SR, "gap_ms": args.gap, "reels": []}
    print("[样带] 输出目录：%s" % out_dir)
    print("%-20s %4s %9s %9s %9s  %s"
          % ("样带", "件数", "时长s", "L_evt", "峰值dBTP", "说明"))
    print("-" * 96)
    for title, names in reels:
        names = [n for n in names if (DELIVER / ("%s.wav" % n)).exists()]
        if not names:
            continue
        audio, spans = build_reel(names)
        wav = out_dir / ("_tmp_%s.wav" % title)
        sf.write(str(wav), audio.astype(np.float32), SR, subtype="PCM_16")
        meta = encode(wav, out_dir / ("%s.%s" % (title, args.fmt)), args.fmt)
        wav.unlink(missing_ok=True)
        l_evt = post.event_lufs(audio, SR)
        tp = loudness.true_peak_dbfs(audio, SR)
        if title == "00_全部":
            note = "全部 %d 件，按层序" % len(names)
        elif title == "01_层间对比":
            note = "每层一件；未归一化，音量关系=游戏内层间关系"
        else:
            cat = next(c for c in LAYER_ORDER if LAYER_NAME[c] == title.split("_", 1)[1])
            note = "层 %s（L_evt 目标 %.0f）" % (LAYER_NAME[cat], D.layer_of(cat))
        print("%-20s %4d %9.1f %9.2f %9.2f  %s"
              % (title, len(names), len(audio) / SR, l_evt, tp, note))
        manifest["reels"].append({
            "title": title, "file": meta["path"], "mb": meta["mb"],
            "n_items": len(names), "duration_s": round(len(audio) / SR, 3),
            "event_lufs": round(l_evt, 2), "true_peak_dbtp": round(tp, 2),
            "items": spans,
        })

    (out_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    print("-" * 96)
    print("完成：%d 条样带 → %s（另见 manifest.json）"
          % (len(manifest["reels"]), out_dir))
    print("\n听什么（客观指标管不到的部分）：")
    print("  1) 同类内每件是不是『同一件事的不同版本』，而不是同一个音换音量；")
    print("  2) 01_层间对比 里 UI 明显最轻、sting 最响——这就是分层设计；")
    print("  3) 战斗拟音（unit_hurt/武器）听 30 秒，判断『密而不糊、不扎耳』；")
    print("  4) victory_fanfare 与 battle_ended_win 的庄重感差别是否成立；")
    print("  5) ui_denied 是否明确是『不行』且不刺耳（与 ui_click 对比）。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
