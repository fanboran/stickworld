# -*- coding: utf-8 -*-
"""分轨采样渲染 —— 把每个 stem 的 MIDI 渲染成 WAV。

两个渲染引擎，各管一摊：
  - **sfizz**（SFZ 采样库）：钢琴。Salamander Grand Piano V3 有 16 力度层、
    制音器释放采样、琴弦共鸣、踏板噪声，用真采样才能有"真钢琴"的听感。
  - **fluidsynth**（SoundFont）：弦乐垫、竖琴、钢片琴、木管等编制声部。

**分轨渲染是刻意的**：每个 stem 一个 MIDI、一次渲染、一个 WAV。之后才能对
弦乐垫单独做高通、对钢琴单独做高频收敛、对各轨给不同的混响量；游戏里也才能
按强度开关某一层。合起来渲染成一遍就没这些余地了。

渲染一律**干声**（不加混响/合唱）：空间感统一由 `mix.py` 的卷积混响给，
避免"引擎混响 + 我们的混响"叠成两团。
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

REPO_ROOT = Path(__file__).resolve().parents[3]


def toolchain_root() -> Path:
    env = os.environ.get("MUSIC_TOOLCHAIN_DIR")
    return Path(env) if env else REPO_ROOT / "temp" / "music_toolchain"


def _exe(name: str) -> Path:
    """定位渲染引擎可执行文件。

    **必须挑"同目录带 DLL"的那一份**：解压后 exe 常与 DLL 分处不同子目录
    （fluidsynth 的 exe 在 `bin/`、DLL 在 `bin/bin/`；sfizz 的 exe 与 dll 在
    `bin/Release/`）。若只按固定路径取第一个存在的 exe，可能拿到一个找不到
    DLL 的副本，报错是 `3221225781`（STATUS_DLL_NOT_FOUND），很难一眼看出原因。
    所以这里按"目录里是否存在配套 DLL"打分，取最高分的那一个。
    """
    root = toolchain_root() / "bin"
    exes = {
        "sfizz_render": ("sfizz", "sfizz_render.exe", ["sfizz*.dll"]),
        "fluidsynth": ("fluidsynth", "fluidsynth.exe",
                       ["libfluidsynth*.dll", "libsndfile*.dll"]),
    }
    sub, want, keys = exes[name]
    cands = sorted((root / sub).rglob(want))
    if not cands:
        raise FileNotFoundError(
            "找不到 %s，请先运行 python tools/music/setup_toolchain.py" % want)
    scored = []
    for c in cands:
        score = sum(1 for k in keys if list(c.parent.glob(k)))
        scored.append((score, len(c.parts), c))
    scored.sort(key=lambda t: (-t[0], -t[1]))
    return scored[0][2]


def piano_sfz() -> Path:
    p = toolchain_root() / "sfz" / "SalamanderGrandPiano" / "piano.sfz"
    if not p.exists():
        raise FileNotFoundError(
            "找不到钢琴 SFZ：%s（先运行 setup_toolchain.py）" % p)
    return p


def soundfont() -> Path:
    """GM SoundFont 路径。可由 MUSIC_SOUNDFONT 覆盖；否则取工具链里的
    `soundfonts/*.sf2|sf3`（安装脚本登记的那一份）。"""
    env = os.environ.get("MUSIC_SOUNDFONT")
    if env:
        return Path(env)
    d = toolchain_root() / "soundfonts"
    for ext in ("*.sf2", "*.sf3"):
        hits = sorted(d.glob(ext))
        if hits:
            return hits[0]
    raise FileNotFoundError("找不到 GM SoundFont，请先运行 setup_toolchain.py")


# ─────────────────────────────── 渲染 ────────────────────────────────

def render_piano(midi_path: str, out_wav: str, sr: int = 48000,
                 polyphony: int = 256, quality: int = 1,
                 log: bool = False) -> dict:
    """用 sfizz 渲染钢琴 stem。

    `--use-eot` 是必须的：不加它 sfizz 会一直渲到输出低于静音阈值为止，
    而 Salamander 带琴弦共鸣与制式器释放采样，尾巴极长——实测一个 141 秒的
    分轨渲到 73MB（约 200 秒音频）仍未收尾，既慢又不可复现。
    谱面里已经在最后一个音之后留了 8 拍余量，所以按 MIDI 结尾截断是安全的，
    也让渲染长度完全由谱面决定（可复现）。
    """
    out = Path(out_wav)
    out.parent.mkdir(parents=True, exist_ok=True)
    cmd = [str(_exe("sfizz_render")),
           "--sfz", str(piano_sfz()),
           "--midi", str(midi_path),
           "--wav", str(out),
           "-s", str(sr),
           "-p", str(polyphony),
           "-q", str(quality),
           "--use-eot"]
    if log:
        cmd.append("--log")
        cmd += ["--verbose"]
    return _run(cmd, out)


def render_gm(midi_path: str, out_wav: str, sr: int = 48000,
              gain: float = 0.6, reverb: bool = False,
              chorus: bool = False) -> dict:
    """用 fluidsynth + GM SoundFont 渲染编制 stem（默认干声）。"""
    out = Path(out_wav)
    out.parent.mkdir(parents=True, exist_ok=True)
    cmd = [str(_exe("fluidsynth")), "-ni",
           "-F", str(out),
           "-r", str(sr),
           "-g", str(gain),
           "-R", "1" if reverb else "0",
           "-C", "1" if chorus else "0",
           str(soundfont()), str(midi_path)]
    return _run(cmd, out)


def _run(cmd: list, out: Path) -> dict:
    if out.exists():
        out.unlink()
    proc = subprocess.run(cmd, capture_output=True, text=True,
                          encoding="utf-8", errors="replace")
    if proc.returncode != 0 or not out.exists():
        raise RuntimeError("渲染失败 (%s)\n%s\n%s"
                           % (proc.returncode, proc.stdout[-3000:],
                              proc.stderr[-3000:]))
    info = sf.info(str(out))
    return {"wav": str(out), "frames": info.frames, "sr": info.samplerate,
            "channels": info.channels, "duration_s": round(info.duration, 3)}


def render_stem(stem_name: str, engine: str, midi_path: str, out_wav: str,
                sr: int = 48000) -> dict:
    if engine == "sfizz":
        return render_piano(midi_path, out_wav, sr=sr)
    if engine == "fluidsynth":
        return render_gm(midi_path, out_wav, sr=sr)
    raise ValueError("未知渲染引擎: %s" % engine)


def render_cue(cue, midi_map: dict, out_dir, sr: int = 48000,
               cache_manifest: Path | None = None) -> dict:
    """渲染一个 cue 的全部分轨。

    增量：若 out_dir/<stem>.wav 已存在且比对应 MIDI 新，则跳过（改一层不会
    触发全部重渲）。
    """
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    result = {}
    for name, midi in midi_map.items():
        stem = cue.stems[name]
        wav = out_dir / ("%s.wav" % name)
        midi_p = Path(midi)
        if wav.exists() and wav.stat().st_mtime >= midi_p.stat().st_mtime:
            info = sf.info(str(wav))
            result[name] = {"wav": str(wav), "frames": info.frames,
                            "sr": info.samplerate, "channels": info.channels,
                            "duration_s": round(info.duration, 3),
                            "cached": True}
            continue
        eng = stem.render_engine
        print("    [render] %-8s %-10s %s prog=%d"
              % (cue.cue_id, name, eng, stem.program))
        result[name] = render_stem(name, eng, str(midi_p), str(wav), sr=sr)
    if cache_manifest:
        cache_manifest.write_text(json.dumps(result, ensure_ascii=False, indent=2),
                                  encoding="utf-8")
    return result


# ─────────────────────────── 读回 / 对齐 ───────────────────────────────

def load_stem(path: str, target_sr: int = 48000) -> np.ndarray:
    """读 WAV 为 float32 立体声 (n, 2)，必要时重采样（本项目全程 48kHz，正常不触发）。"""
    x, sr = sf.read(path, always_2d=True, dtype="float32")
    if sr != target_sr:
        from scipy import signal
        g = np.gcd(sr, target_sr)
        x = signal.resample_poly(x, target_sr // g, sr // g, axis=0)
    if x.shape[1] == 1:
        x = np.repeat(x, 2, axis=1)
    return x.astype(np.float32)


def pad_to(x: np.ndarray, n: int) -> np.ndarray:
    if len(x) >= n:
        return x[:n]
    pad = np.zeros((n - len(x), x.shape[1]), dtype=x.dtype)
    return np.concatenate([x, pad], axis=0)


def write_wav(path: str, x: np.ndarray, sr: int = 48000,
              subtype: str = "PCM_24") -> None:
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    sf.write(path, np.clip(x, -1.0, 1.0), sr, subtype=subtype)


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    print("sfizz_render :", _exe("sfizz_render"))
    try:
        print("piano.sfz    :", piano_sfz())
    except FileNotFoundError as e:
        print("piano.sfz    :", e)
    try:
        print("soundfont    :", soundfont())
    except FileNotFoundError as e:
        print("soundfont    :", e)
