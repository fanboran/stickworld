# -*- coding: utf-8 -*-
"""试听样带 —— 把交付件做成"能直接双击播放"的样带，供人听验收。

为什么单独做这一步：交付给引擎的是**每层一个 OGG + 一份清单**，这是引擎要的形式，
但不是人能听的形式（没人能同时打开四个播放器对齐着听）。所以需要一层"试听物化"：
把分层按不同强度叠好、编码成通用格式，让评审者能像听歌一样听。

产出四类：

  1. **全层版**：每首曲子按"最强强度"叠好（= 游戏里最热闹时会听到的样子）。
     这是"这首曲子整体是什么样"的答案。
  2. **分层对比**：同一首曲子在 tier 0 / 1 / 2 三档下的样子，**三档用同一个增益**。
     这一条很关键：若各自归一化到同一响度，"叠层"的差别就被抵消掉了，
     听起来三档一样响，反而证明不了纵向混音有效。
  3. **循环接缝验证**：把循环体连播三遍，接缝处若有一丝"咔"或"断"就能听出来。
     这是客观指标管不到的地方——它能证明"没有数值上的跳变"，但"听不听得出"
     必须人耳复核。
  4. **试听样带**：每首取一段（默认从 B 段起，即情绪打开处）串起来，便于快速过一遍。

    python tools/music/preview.py                     # 全部，输出到 temp/music_preview
    python tools/music/preview.py --out D:/试听
    python tools/music/preview.py --cue field_day     # 只做一首
    python tools/music/preview.py --tier-cues field_day,village
    python tools/music/preview.py --no-reel --no-loop-check
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))

from compose import cues as CUES                       # noqa: E402
from musiclib import dsp, export, mix as MIX           # noqa: E402
from musiclib import render as R                       # noqa: E402

OUT_ROOT = HERE / "out"
STEMS = OUT_ROOT / "stems"


# ─────────────────────────────── 编码 ────────────────────────────────

def encode(wav: Path, out: Path, fmt: str = "mp3", bitrate: str = "192k") -> dict:
    """编码成便于双击播放的格式（默认 MP3：Windows 自带播放器就能放）。

    为什么不用 soundfile 直接写 MP3：libsndfile 的 MP3 编码器不暴露码率，
    默认偏低；ffmpeg 的 libmp3lame 可以指定 192k，对钢琴弱奏细节更友好。
    """
    out.parent.mkdir(parents=True, exist_ok=True)
    if fmt == "mp3":
        codec = ["-c:a", "libmp3lame", "-b:a", bitrate]
    else:
        codec = ["-c:a", "libvorbis", "-q:a", "6"]
    cmd = [export.ffmpeg_exe(), "-y", "-loglevel", "error", "-i", str(wav),
           *codec, "-ar", "48000", "-ac", "2", str(out)]
    proc = subprocess.run(cmd, capture_output=True, text=True,
                          encoding="utf-8", errors="replace")
    if proc.returncode != 0 or not out.exists():
        raise RuntimeError("编码失败：%s\n%s" % (proc.returncode, proc.stderr[-1500:]))
    return {"path": out, "mb": round(out.stat().st_size / 1e6, 2)}


def _safe(name: str) -> str:
    """把曲名里不能做文件名的字符换掉（中文保留，去掉斜杠/冒号等）。"""
    for ch in '\\/:*?"<>|':
        name = name.replace(ch, "-")
    return name


# ─────────────────────────── 分层叠加（同增益）────────────────────────────

def _subset_sum(layers: dict, tier_of: dict, tier: int) -> np.ndarray:
    """某个强度档位下"会发声的层之和"。

    各档位**不做各自归一化**——否则三档听起来一样响，恰好把"叠层"的效果抹平。
    """
    names = [n for n in layers if int(tier_of.get(n, 0)) <= tier]
    y = np.zeros_like(layers[names[0]])
    for n in names:
        y = y + layers[n][:len(y)]
    return y


def tier_sums(cue, processed: dict, report: dict, tier_of: dict,
              tiers=(0, 1, 2)) -> dict:
    """按强度档位求和，**所有档位用同一个增益与同一个限制器**。

    这样三档之间的音量差就是"叠了几层"的真实差别；若各自归一化到同一响度，
    评审者听不出任何区别，样带就失去意义了。
    """
    fs = 48000
    gain = float(report.get("applied_gain_db", 0.0))
    ceil = float(report.get("tp_ceiling_db", -1.0))
    loop_start = int(report.get("loop_start_sample", 0))
    loop_end = int(report.get("loop_end_sample", 0))
    n = max(len(v) for v in processed.values())
    out = {}
    for t in tiers:
        y = np.zeros((n, 2), dtype=np.float32)
        for name, audio in processed.items():
            if int(tier_of.get(name, 0)) <= t:
                y += audio[:n]
        y = dsp.apply_gain_db(y, gain)
        y = dsp.limiter(y, fs, ceiling_db=ceil)
        if loop_end > loop_start:
            y = MIX.wrap_loop_tail(y, fs, loop_start, loop_end)
        out[t] = y
    return out


# ─────────────────────────── 片段与串烧 ──────────────────────────────

def take_window(x: np.ndarray, fs: int, start_s: float, dur_s: float,
                fade_s: float = 1.2) -> np.ndarray:
    a = max(0, int(start_s * fs))
    b = min(len(x), a + int(dur_s * fs))
    seg = x[a:b].copy()
    k = min(len(seg), int(fade_s * fs))
    if k > 1:
        t = np.linspace(0.0, 1.0, k)
        seg[:k] *= np.sin(t * np.pi / 2)[:, None]
        seg[len(seg) - k:] *= np.cos(t * np.pi / 2)[:, None]
    return seg


def loop_repeats(x: np.ndarray, fs: int, times: int = 3) -> np.ndarray:
    """把循环体连播多遍（不做淡变），用于人耳复核接缝。"""
    return np.tile(x, (times, 1))


# ─────────────────────────────── 主流程 ──────────────────────────────

def build(cue_id: str, out_dir: Path, fmt: str, do_tiers: bool,
          do_loop_check: bool) -> list:
    cue = CUES.build_one(cue_id)
    is_loop = getattr(cue, "loop", True)
    paths = {n: str(STEMS / cue_id / ("%s.wav" % n)) for n in cue.stems}
    missing = [p for p in paths.values() if not Path(p).exists()]
    if missing:
        print("    [跳过] %s 分轨缺失（先跑 render_all.py）" % cue_id)
        return []

    full, report, processed = MIX.mix_cue(
        cue, paths, overrides=CUES.MIX_OVERRIDES.get(cue_id, {}),
        target_lufs=None if is_loop else -14.0,
        wrap_tail=is_loop, return_stems=True)
    # 试听用的"全层版"要用**交付分层之和**，而不是母带：
    # 游戏里播的就是各层相加，两者若不取自同一来源，就会出现
    # "试听好听、进游戏不一样"这种无法对齐的差别。
    layers, dinfo = MIX.deliver_layers(
        cue, processed, target_lufs=None if is_loop else -14.0,
        wrap_tail=is_loop,
        loop_start_sample=report["loop_start_sample"],
        loop_end_sample=report["loop_end_sample"],
        master_gain_env=report.get("_master_gain_env"),
        target_len=report.get("shaped_len"))
    full = np.zeros_like(next(iter(layers.values())))
    for z in layers.values():
        full += z[:len(full)]
    tier_of = export.cue_tier_map().get(cue_id, {})
    title = _safe(cue.title)
    made = []

    def emit(audio: np.ndarray, suffix: str, note: str) -> None:
        wav = out_dir / ("_tmp_%s_%s.wav" % (cue_id, suffix))
        MIX.save_mix(audio, str(wav))
        meta = encode(wav, out_dir / ("%s_%s.%s" % (title, suffix, fmt)), fmt)
        wav.unlink(missing_ok=True)
        print("    %-42s %5.2f MB   %s" % ((out_dir / ('%s_%s.%s' % (title, suffix, fmt))).name, meta["mb"], note))
        made.append(meta)

    emit(full, "全层", "%.2f LUFS（= 游戏内叠加）" % dinfo["deliver_lufs"])

    if do_tiers and tier_of and is_loop:
        sums = {t: _subset_sum(layers, tier_of, t) for t in (0, 1, 2)}
        names = {0: "tier0_只有地基层", 1: "tier1_加常规层", 2: "tier2_全层（同增益对比）"}
        for t, s in sums.items():
            emit(s, names[t], "叠 %d 层" % sum(1 for v in tier_of.values() if v <= t))

    if do_loop_check and is_loop and report.get("loop_end_sample", 0) > 0:
        emit(loop_repeats(full, 48000, 3), "循环三遍_验接缝",
             "接缝若有一丝'咔'即可听出")
    return made


def build_reel(cue_ids: list, out_dir: Path, fmt: str, seg_s: float,
               gap_s: float) -> list:
    """试听串烧：每首取一段串联。

    取段位置默认从**第 3 个 8 小节乐句**开始（情绪打开处）——这是每首曲子
    最"有内容"的位置；从头取会听到大段前奏，串烧起来显得拖沓。
    """
    fs = 48000
    parts = []
    for cid in cue_ids:
        cue = CUES.build_one(cid)
        is_loop = getattr(cue, "loop", True)
        paths = {n: str(STEMS / cid / ("%s.wav" % n)) for n in cue.stems}
        if any(not Path(p).exists() for p in paths.values()):
            continue
        audio, _rep = MIX.mix_cue(cue, paths,
                                  overrides=CUES.MIX_OVERRIDES.get(cid, {}),
                                  target_lufs=None if is_loop else -14.0,
                                  wrap_tail=is_loop)
        if is_loop:
            start = cue.seconds(cue.bar(16))
            seg = take_window(audio, fs, start, seg_s, fade_s=1.5)
        else:
            seg = take_window(audio, fs, 0.0, min(seg_s, len(audio) / fs), fade_s=0.5)
        parts.append(seg)
        parts.append(np.zeros((int(gap_s * fs), 2), dtype=np.float32))

    if not parts:
        return []
    reel = np.concatenate(parts, axis=0)
    wav = out_dir / "_tmp_reel.wav"
    MIX.save_mix(reel, str(wav))
    meta = encode(wav, out_dir / ("00_试听串烧_每首一段.%s" % fmt), fmt)
    wav.unlink(missing_ok=True)
    print("    00_试听串烧_每首一段.%-20s %5.2f MB   共 %d 首 / %.0f 秒"
          % (fmt, meta["mb"], len(cue_ids), len(reel) / fs))
    return [meta]


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)
    except Exception:  # noqa: BLE001
        pass
    ap = argparse.ArgumentParser(description="生成试听样带")
    ap.add_argument("--out", default=str(REPO / "temp" / "music_preview"),
                    help="输出目录（默认仓库 temp/music_preview，便于找到）")
    ap.add_argument("--cue", action="append", default=None, help="只做指定 cue")
    ap.add_argument("--tier-cues", default="field_day,village",
                    help="做分层对比的 cue（逗号分隔）")
    ap.add_argument("--format", default="mp3", choices=["mp3", "ogg"])
    ap.add_argument("--seg", type=float, default=22.0, help="串烧每首段长（秒）")
    ap.add_argument("--gap", type=float, default=0.8, help="串烧段间留白（秒）")
    ap.add_argument("--no-reel", action="store_true")
    ap.add_argument("--no-loop-check", action="store_true")
    args = ap.parse_args()

    if not STEMS.exists():
        print("[错误] 找不到分轨目录 %s；先跑：python tools/music/render_all.py" % STEMS,
              file=sys.stderr)
        return 2
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    cue_ids = args.cue or [cid for cid, _ in CUES.BUILDERS]
    tier_cues = {s.strip() for s in args.tier_cues.split(",") if s.strip()}

    print("[样带] 输出目录：%s" % out_dir)
    total = []
    for cid in cue_ids:
        cue = CUES.build_one(cid)
        print("  %s %s（%s %s）" % (cid, cue.title, cue.key, cue.scale))
        total += build(cid, out_dir, args.format, cid in tier_cues,
                       not args.no_loop_check)
    if not args.no_reel:
        print("  ── 串烧 ──")
        total += build_reel(cue_ids, out_dir, args.format, args.seg, args.gap)
    print("\n[完成] %d 个文件 / %.1f MB → %s"
          % (len(total), sum(m["mb"] for m in total), out_dir))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
