# -*- coding: utf-8 -*-
"""环境音层（ambience）生成管线 —— 6+2 条可无缝循环的场景氛围底噪。

为什么单独一条管线，不塞进 compose/：
  BGM 是"有结构、有调性、有拍"的音乐，走 MIDI → 采样渲染 → 混音；
  环境层是**无调性的连续噪声场**，没有拍、没有小节，只有频谱、包络与统计分布。
  两者的工具链完全不同（这里一行 MIDI 都不需要），混在一起的唯一后果是两套
  抽象互相将就。所以环境层自成一条：**直接合成波形**，源材料是两条路线——

  A. 网络采集：Wikimedia Commons / OpenGameArt 上的 **CC0 / PD / CC-BY** 自然
     录音（逐个核对许可，登记在 docs/ambience_sources.md）；
  B. 程序化合成：numpy/scipy 的谱合成 + 包络 + 卷积混响。

  两条路线**融合**：录音提供"真"的质感与随机性，合成提供可控的频谱、
  密度与包络；哪一层用哪条、各占多少，写死在 LAYERS 的配方里。

无缝循环的两种做法（本管线都用到）：
  1. **谱合成 = 天生周期**。`spec_noise()` 用 IFFT 造噪声，得到的信号严格以 n
     为周期；任何由它（及其周期包络）线性组合出来的东西都严格周期性，
     接缝在数学上不存在。风/溪/雨的底噪都走这条路。
  2. **循环折叠 + 等功率交叉淡化**。真实录音不周期，用 `crossfade_loop()`：
     取 n+xf 段，把 [n, n+xf) 以 cos 淡回 [0, xf)，于是 out[0] 恰好等于 x[n]
     （自然延续），最后一点接第一点在波形上连续；离散事件（鸟/虫/浪）用
     `circ_add()` 落到**环形缓冲**上，跨过末尾的事件自动缠到开头。

响度：环境层是垫在音乐下面的底噪，归一到 -30 ~ -26 LUFS（默认 -28），
真峰值留到 -2 dBTP，绝不削波。质量指标（LUFS / 真峰值 / 循环接缝 / 2-5kHz 占比）
由 `--verify` 打印成表，构成回归基线。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy import signal

sys.path.insert(0, str(Path(__file__).resolve().parent))   # tools/music
from musiclib import dsp, reverb                                   # noqa: E402
from musiclib.loudness import (integrated_lufs, true_peak_dbfs,    # noqa: E402
                               loop_seam_report, spectral_report,
                               mono_compat_report, count_silence_holes)
from musiclib.render import load_stem, write_wav                   # noqa: E402

FS = 48000
ROOT = Path(__file__).resolve().parents[2]
SRC_DIR = ROOT / "temp" / "ambience" / "sources"
TMP_DIR = ROOT / "temp" / "ambience"
OUT_DIR = ROOT / "stick-world" / "assets" / "audio" / "ambience"

TARGET_LUFS = -28.0
TP_CEILING = -2.0


# ═══════════════════════════ 源材料清单（路线 A）═══════════════════════════
# 每条都是逐个核对过的 CC0 / Public Domain / CC-BY（不含 SA / NC / ND）。
# fetch_sources() 按此表下载到 temp/ambience/sources/（gitignored，可重下）。

COMMONS_SOURCES = {
    "forest_ambience": dict(
        file="c85709773.wav",
        url="https://upload.wikimedia.org/wikipedia/commons/b/be/"
            "Forest_ambience_%28Gravity_Sound%29.wav",
        lic="CC BY 4.0", author="Gravity Sound"),
    "birds_reveil": dict(
        file="c14936910.ogg",
        url="https://upload.wikimedia.org/wikipedia/commons/3/33/"
            "R%C3%A9veil_des_oiseaux.ogg",
        lic="CC0", author="Joseph Sardin"),
    "cicada_cn": dict(
        file="c70888723.ogg",
        url="https://upload.wikimedia.org/wikipedia/commons/9/90/"
            "%E8%9D%89%E9%B8%A3.ogg",
        lic="CC0", author="Ngguls"),
    "cicada_nz": dict(
        file="c578100.ogg",
        url="https://upload.wikimedia.org/wikipedia/commons/b/b0/"
            "New_Zealand_cicada_song.ogg",
        lic="Public domain", author="（作者自释入 PD）"),
    "cicada_florida": dict(
        file="c7429845.ogg",
        url="https://upload.wikimedia.org/wikipedia/commons/c/c3/"
            "Florida_Cicada_Song.ogg",
        lic="CC BY 3.0", author="Gatorguy76"),
    "cricket_jer": dict(
        file="c3083569.ogg",
        url="https://upload.wikimedia.org/wikipedia/commons/a/a2/Jer-Cricket.ogg",
        lic="Public domain", author="Man vyi"),
    "stream_swale": dict(
        file="c14465956.ogg",
        url="https://upload.wikimedia.org/wikipedia/commons/8/84/Swale.ogg",
        lic="CC0", author="Ksd5"),
    # 注：Rain (1).ogg / Shallow small river / 两个 rooster 是 **OggPCM**（未压缩
    # PCM in Ogg），libsndfile 1.2 不认，故不采用（见 docs 的"试听淘汰"一节）。
    "rain_field": dict(
        file="c50086751.wav",
        url="https://upload.wikimedia.org/wikipedia/commons/b/b6/"
            "Light_Rain_Distant_Thunder_July_5th_2016.wav",
        lic="CC0", author="kvgarlic (via Freesound)"),
    "sheep": dict(
        file="c29369468.ogg",
        url="https://upload.wikimedia.org/wikipedia/commons/1/13/"
            "Sheep_bleating.ogg",
        lic="Public domain", author="earthcalling"),
    "wind_willows_02": dict(
        file="c3476433.ogg",
        url="https://upload.wikimedia.org/wikipedia/commons/3/39/"
            "Wind_willows_02_grahame_ap.ogg",
        lic="Public Domain", author="Kenneth Grahame"),
    "wind_willows_05": dict(
        file="c3476403.ogg",
        url="https://upload.wikimedia.org/wikipedia/commons/0/02/"
            "Wind_willows_05_grahame_ap.ogg",
        lic="Public Domain", author="Kenneth Grahame"),
    "wind_willows_09": dict(
        file="c3476398.ogg",
        url="https://upload.wikimedia.org/wikipedia/commons/9/90/"
            "Wind_willows_09_grahame_ap.ogg",
        lic="Public Domain", author="Kenneth Grahame"),
}

# OpenGameArt「CC0 Sounds Library」里两条海浪包（jasinski / transitking 录，CC0）
OGA_SOURCES = {
    "wave_beach_1": dict(
        file="wave_01_cc0-18363__jasinski__alkaibeach.flac",
        url="https://opengameart.org/sites/default/files/"
            "wave_01_cc0-18363__jasinski__alkaibeach.flac",
        lic="CC0", author="jasinski",
        page="https://opengameart.org/content/beach-ocean-waves"),
    "wave_beach_2": dict(
        file="wave_02_cc0-18363__jasinski__alkaibeach.flac",
        url="https://opengameart.org/sites/default/files/"
            "wave_02_cc0-18363__jasinski__alkaibeach.flac",
        lic="CC0", author="jasinski",
        page="https://opengameart.org/content/beach-ocean-waves"),
    "wave_beach_3": dict(
        file="wave_03_cc0-18363__jasinski__alkaibeach.flac",
        url="https://opengameart.org/sites/default/files/"
            "wave_03_cc0-18363__jasinski__alkaibeach.flac",
        lic="CC0", author="jasinski",
        page="https://opengameart.org/content/beach-ocean-waves"),
    "wave_beach_4": dict(
        file="wave_04_cc0-18363__jasinski__alkaibeach.flac",
        url="https://opengameart.org/sites/default/files/"
            "wave_04_cc0-18363__jasinski__alkaibeach.flac",
        lic="CC0", author="jasinski",
        page="https://opengameart.org/content/beach-ocean-waves"),
    "wave_water_1": dict(
        file="wave_01_cc0-11505__transitking__wavesound.flac",
        url="https://opengameart.org/sites/default/files/"
            "wave_01_cc0-11505__transitking__wavesound.flac",
        lic="CC0", author="transitking",
        page="https://opengameart.org/content/water-waves"),
    "wave_water_2": dict(
        file="wave_02_cc0-11505__transitking__wavesound.flac",
        url="https://opengameart.org/sites/default/files/"
            "wave_02_cc0-11505__transitking__wavesound.flac",
        lic="CC0", author="transitking",
        page="https://opengameart.org/content/water-waves"),
    "wave_water_3": dict(
        file="wave_03_cc0-11505__transitking__wavesound.flac",
        url="https://opengameart.org/sites/default/files/"
            "wave_03_cc0-11505__transitking__wavesound.flac",
        lic="CC0", author="transitking",
        page="https://opengameart.org/content/water-waves"),
    "wave_water_4": dict(
        file="wave_04_cc0-11505__transitking__wavesound.flac",
        url="https://opengameart.org/sites/default/files/"
            "wave_04_cc0-11505__transitking__wavesound.flac",
        lic="CC0", author="transitking",
        page="https://opengameart.org/content/water-waves"),
    "village_fowl": dict(
        file="oga_chicken.ogg",
        url="https://opengameart.org/sites/default/files/chicken_sound_effect.zip",
        lic="CC BY 3.0", author="imadeit (OpenGameArt submitter)",
        page="https://opengameart.org/content/chicken-sound-effect",
        zip_member="Chicken Sound Effect.ogg"),
}

SOURCES = {**COMMONS_SOURCES, **OGA_SOURCES}


# ═══════════════════════════ 基础设施 ═══════════════════════════

def rng_for(name: str, salt: str = "") -> np.random.Generator:
    """确定性 RNG：同名字永远同结果（幂等，便于回归）。"""
    h = hashlib.sha256(("ambience/%s/%s" % (name, salt)).encode()).digest()
    return np.random.default_rng(int.from_bytes(h[:8], "little"))


def spec_noise(n: int, fs: int, shape, rng: np.random.Generator) -> np.ndarray:
    """谱合成噪声：**严格以 n 为周期**（IFFT 造的信号天生首尾相接），
    返回单位 RMS。shape(f) 给幅度谱包络。"""
    f = np.fft.rfftfreq(n, 1.0 / fs)
    f = np.maximum(f, 1e-6)
    mag = np.asarray(shape(f), dtype=np.float64)
    ph = rng.uniform(0.0, 2.0 * np.pi, f.size)
    X = mag * np.exp(1j * ph)
    X[0] = 0.0
    if n % 2 == 0:
        X[-1] = abs(X[-1])
    x = np.fft.irfft(X, n)
    r = float(np.sqrt(np.mean(x * x))) + 1e-12
    return x / r


def lp_shape(f, fc, order=2):
    return 1.0 / np.sqrt(1.0 + (f / fc) ** (2 * order))


def hp_shape(f, fc, order=2):
    return 1.0 / np.sqrt(1.0 + (fc / f) ** (2 * order))


def bp_shape(f, lo, hi, order=2):
    return hp_shape(f, lo, order) * lp_shape(f, hi, order)


def band_noise(n, fs, lo, hi, rng, order=2) -> np.ndarray:
    return spec_noise(n, fs, lambda f: bp_shape(f, lo, hi, order), rng)


def rand_env(n, fs, lo, hi, rng, kink=1.0, order=2) -> np.ndarray:
    """慢速随机包络（周期化），映射到 (0,1)。lo/hi 是包络的速率带（Hz）。"""
    x = band_noise(n, fs, lo, hi, rng, order)
    s = float(x.std()) + 1e-12
    return 0.5 + 0.5 * np.tanh(kink * x / s)


def lfo(n, fs, rate, phase) -> np.ndarray:
    """相位锁定到整周期的正弦 LFO —— 循环内整数个周期，接缝无相位跳变。"""
    k = max(1, round(rate * n / fs))
    r = k * fs / n
    return 0.5 + 0.5 * np.sin(2.0 * np.pi * r * np.arange(n) / fs + phase)


def crossfade_loop(x: np.ndarray, n: int, xf: int) -> np.ndarray:
    """把长度 >= n+xf 的信号折成 n 点无缝循环。

    out[i] (i<xf) = x[i]*sin + x[n+i]*cos；其余 out[i]=x[i]。
    于是 out[0] = x[n]（自然延续），最后一点 x[n-1] 接 out[0] 在波形上连续。
    """
    if len(x) < n + xf:
        raise ValueError("crossfade_loop 需要 len(x) >= n+xf")
    out = np.array(x[:n], copy=True, dtype=np.float64)
    t = np.linspace(0.0, 1.0, xf, endpoint=False)
    win = np.sin(t * np.pi / 2.0)
    wout = np.cos(t * np.pi / 2.0)
    if out.ndim == 2:
        win = win[:, None]
        wout = wout[:, None]
    out[:xf] = out[:xf] * win + x[n:n + xf] * wout
    return out


def circ_add(buf: np.ndarray, ev: np.ndarray, onset: int,
             gl: float, gr: float) -> None:
    """把单声道事件 ev 按等功率 pan 加到**环形**立体声缓冲 buf 上
    （越过末尾自动缠回开头 → 无缝）。"""
    n = len(buf)
    i0 = int(round(onset)) % n
    idx = (i0 + np.arange(len(ev))) % n
    buf[idx, 0] += ev * gl
    buf[idx, 1] += ev * gr


def pan_gains(pan: float):
    ang = (float(np.clip(pan, -1.0, 1.0)) + 1.0) * np.pi / 4.0
    return float(np.cos(ang)), float(np.sin(ang))


def circ_reverb(x: np.ndarray, fs: int, rt60: float, pre_ms: float,
                seed: int, style: str, mix: float,
                brightness_db: float = 0.0) -> np.ndarray:
    """环形卷积混响：因为缓冲本身是周期的，混响尾巴自然绕回开头，
    不会在接缝处"空间感塌陷"。"""
    n = len(x)
    ir = reverb.get_ir(fs, rt60, pre_ms, seed, style, brightness_db)
    H = np.fft.rfft(ir, n, axis=0)
    X = np.fft.rfft(x, n, axis=0)
    wet = np.fft.irfft(X * H, n, axis=0)
    rd = float(np.sqrt(np.mean(x * x))) + 1e-12
    rw = float(np.sqrt(np.mean(wet * wet))) + 1e-12
    wet *= rd / rw
    return (1.0 - mix) * x + mix * wet


def circ_apply(x: np.ndarray, fn, *a, **kw) -> np.ndarray:
    """以"周期信号"的方式施加任意 LTI 滤波：把 [x;x] 跑一遍取后半。

    为什么必须这样：`scipy.signal.lfilter/sosfilt` 的初始状态是 0，会在**第一个样本**
    处产生启动瞬态。对一个要被循环的缓冲，这个瞬态正好落在接缝上——听感就是每圈
    一次"啪"。跑两遍取后半 = 用信号自己的尾巴当初始状态，稳态输出严格周期，
    接缝处不再有台阶。这是整条管线"无缝"的关键一手。
    """
    xx = np.concatenate([x, x], axis=0)
    y = fn(xx, *a, **kw)
    return np.array(y[len(x):], copy=True)


def c_lowpass(x, fs, freq, order=2):
    return circ_apply(x, dsp.lowpass, fs, freq, order)


def c_highpass(x, fs, freq, order=2):
    return circ_apply(x, dsp.highpass, fs, freq, order)


def c_shelf(x, fs, freq, gain_db, kind="high"):
    return circ_apply(x, dsp.shelf, fs, freq, gain_db, kind)


def _norm(x: np.ndarray, target_rms: float = 1.0) -> np.ndarray:
    r = float(np.sqrt(np.mean(x * x))) + 1e-12
    return x * (target_rms / r)


def pick_region(mono: np.ndarray, n: int, xf: int, fs: int) -> int:
    """在一段录音里挑能量最平稳的 n+xf 段（环境底噪要"平"，不能有起伏）。"""
    need = n + xf
    L = len(mono)
    if L <= need:
        return 0
    win = max(1, int(0.5 * fs))
    step = max(1, int(0.5 * fs))
    starts = np.arange(0, L - win + 1, step)
    fe = np.array([np.mean(mono[s:s + win] ** 2) for s in starts]) + 1e-12
    fe = 10.0 * np.log10(fe)
    k = int(np.ceil(need / step)) + 1
    best, bs = None, 0
    for i in range(0, max(1, len(fe) - k)):
        v = float(np.std(fe[i:i + k]))
        if best is None or v < best:
            best, bs = v, int(starts[i])
    return int(min(bs, L - need))


def loudest_region(mono: np.ndarray, dur_s: float, fs: int) -> np.ndarray:
    """取录音里最响的 dur_s 秒（用于从短素材里抠一个"叫声"事件）。"""
    m = int(dur_s * fs)
    if len(mono) <= m:
        x = np.zeros(m)
        x[:len(mono)] = mono
        return x
    win = m
    e = np.array([np.mean(mono[i:i + win] ** 2)
                  for i in range(0, len(mono) - win + 1, max(1, fs // 10))])
    s = int(np.argmax(e)) * max(1, fs // 10)
    return mono[s:s + win]


_SRC_CACHE: dict = {}
MAX_SRC_SECONDS = 100.0     # 只截取源录音的一段（有的录音有 30 分钟，全读会爆内存）
SKIP_SRC_SECONDS = 12.0     # 跳开头（现场录音开头常有操作/风噪）


def load_src(key: str):
    """读一条源录音为 (n,2) float64 @48kHz；缺文件返回 None（走纯合成兜底）。

    长录音只按需读一段（MAX_SRC_SECONDS），避免把 31 分钟的风声整个读进内存。
    """
    if key in _SRC_CACHE:
        return _SRC_CACHE[key]
    meta = SOURCES.get(key)
    if meta is None:
        _SRC_CACHE[key] = None
        return None
    p = SRC_DIR / meta["file"]
    if not p.exists():
        _SRC_CACHE[key] = None
        return None
    try:
        info = sf.info(str(p))
        cap = int(MAX_SRC_SECONDS * info.samplerate)
        start = int(min(SKIP_SRC_SECONDS * info.samplerate,
                        max(0, info.frames - cap)))
        n = int(min(cap, info.frames - start))
        x, rsr = sf.read(str(p), start=start, frames=n,
                         always_2d=True, dtype="float32")
        if rsr != FS:
            g = np.gcd(int(rsr), FS)
            x = signal.resample_poly(x, FS // g, int(rsr) // g, axis=0)
        x = x.astype(np.float64)
        if x.shape[1] == 1:              # 单声道 → 复制成两声道（去相关在 src_bed 里做）
            x = np.repeat(x, 2, axis=1)
        elif x.shape[1] > 2:             # 偶见 4 声道素材，折叠成单声道立体声
            m = x.mean(axis=1, keepdims=True)
            x = np.repeat(m, 2, axis=1)
    except Exception:
        _SRC_CACHE[key] = None
        return None
    _SRC_CACHE[key] = x
    return x


def src_bed(key, n, xf, fs, *, lp=None, hp=None, shelf_hi=None,
            delay_r_ms=9.0, gain=1.0):
    """把一条录音用成 n 点无缝循环底噪；返回 (n,2) 或 None。

    delay_r_ms：单声道素材靠右耳微延迟去相关（真录音保留其本身的立体声时不动）。
    """
    x = load_src(key)
    if x is None or len(x) < n + xf:
        return None
    st = pick_region(x.mean(axis=1), n, xf, fs)
    seg = x[st:st + n + xf]
    if hp:
        seg = dsp.highpass(seg, fs, hp, 2)
    if lp:
        seg = dsp.lowpass(seg, fs, lp, 2)
    if shelf_hi:
        seg = dsp.shelf(seg, fs, shelf_hi[0], shelf_hi[1], kind="high")
    out = crossfade_loop(seg, n, xf)
    if rec_is_mono(x) and delay_r_ms:
        d = int(delay_r_ms * fs / 1000.0)
        out = np.stack([out[:, 0], np.roll(out[:, 1], d)], axis=1)
    return _norm(out, 1.0) * gain


def rec_is_mono(x) -> bool:
    """原始素材左右几乎相同 = 单声道录制（需要用微延迟去相关）。"""
    return x.ndim == 1 or x.shape[1] == 1 or \
        (x.shape[1] == 2 and float(np.corrcoef(x[:, 0], x[:, 1])[0, 1]) > 0.9999)

# ═══════════════════════════ 事件合成原语 ═══════════════════════════

def bird_phrase(notes, fs, rng) -> np.ndarray:
    """一段鸟叫：notes = [(dur, f0, f1, kind)]，kind ∈ up/down/bend/flat。"""
    parts = []
    for dur, f0, f1, kind in notes:
        m = max(8, int(dur * fs))
        t = np.arange(m) / fs
        u = t / max(dur, 1e-6)
        if kind == "up":
            f = f0 + (f1 - f0) * u ** 0.65
        elif kind == "down":
            f = f0 + (f1 - f0) * u ** 1.25
        elif kind == "bend":
            f = f0 + (f1 - f0) * (0.5 - 0.5 * np.cos(np.pi * u))
        else:
            f = np.full(m, f0)
        vib = 1.0 + 0.018 * np.sin(2.0 * np.pi * 36.0 * t)
        ph = 2.0 * np.pi * np.cumsum(f * vib) / fs
        tone = np.sin(ph) + 0.34 * np.sin(2 * ph) + 0.09 * np.sin(3 * ph)
        tone = tone + 0.05 * rng.standard_normal(m)
        env = (1.0 - np.exp(-t / 0.006)) * np.exp(-t / max(dur * 0.55, 1e-4))
        parts.append(tone * env)
        parts.append(np.zeros(int(rng.uniform(0.02, 0.09) * fs)))
    return np.concatenate(parts)


BIRD_CALLS = {
    "chirp2":   [(0.07, 2700, 3600, "up"), (0.06, 2900, 3800, "up")],
    "trill":    [(0.022, 3400 + 90 * i, 3800 + 90 * i, "up") for i in range(10)],
    "whistle":  [(0.30, 3700, 2350, "down")],
    "peewee":   [(0.16, 3800, 3150, "down"), (0.20, 3150, 4000, "up")],
    "chatter":  [(0.035, 2600, 2900, "up"), (0.03, 3200, 3000, "down"),
                 (0.045, 3600, 4200, "bend"), (0.03, 3000, 3300, "up"),
                 (0.05, 4200, 3400, "down"), (0.03, 2800, 3100, "flat")],
    "bend_up":  [(0.12, 2200, 4200, "bend")],
}


def distantize(ev, fs, rng, dist):
    """距离塑造：越远越低通、越暗、越轻（"有远近感"就靠这个）。"""
    dist = float(np.clip(dist, 0.0, 1.0))
    lp = 9500.0 - 6200.0 * dist
    y = dsp.lowpass(ev, fs, lp, 2)
    y = dsp.shelf(y, fs, 3200.0, -9.0 * dist, kind="high")
    return y * (10.0 ** (-24.0 * dist / 20.0))


def cricket_chirp(fs, rng, f_c, pulses, pulse_rate, pulse_ms, jitter=0.18):
    """蟋蟀/铃虫的一"声"：若干短促窄带脉冲串。"""
    total = pulses / pulse_rate + pulse_ms / 1000.0 + 0.05
    m = int(total * fs)
    out = np.zeros(m)
    pl = max(8, int(pulse_ms / 1000.0 * fs))
    t = np.arange(pl) / fs
    tone = np.sin(2 * np.pi * f_c * t) + 0.28 * np.sin(2 * np.pi * 2 * f_c * t)
    env = (1.0 - np.exp(-t / 0.0014)) * np.exp(-t / (pulse_ms / 1000.0 * 0.42))
    seg = tone * env
    for k in range(pulses):
        on = int((k / pulse_rate) * fs + rng.uniform(-jitter, jitter) * 0.006 * fs)
        if on < 0 or on >= m:
            continue
        end = min(m, on + pl)
        out[on:end] += seg[:end - on]
    return out


def suzumushi_trill(fs, rng, f_c, dur_s, pulse_rate):
    """铃虫的长颤音（"riiiin"）：一长串脉冲。"""
    m = int(dur_s * fs)
    out = np.zeros(m)
    pl = max(8, int((0.62 / pulse_rate) * fs))
    t = np.arange(pl) / fs
    tone = np.sin(2 * np.pi * f_c * t) + 0.30 * np.sin(2 * np.pi * 2 * f_c * t)
    env = (1.0 - np.exp(-t / 0.0016)) * np.exp(-t / (pl / fs * 0.5))
    seg = tone * env
    step = 1.0 / pulse_rate
    k = 0
    while True:
        on = int(k * step * fs + rng.uniform(-0.15, 0.15) * 0.004 * fs)
        if on + pl > m:
            break
        if on >= 0:
            out[on:on + pl] += seg
        k += 1
    # 整体起落包络（虫不会突然开始/结束）
    u = np.linspace(0, 1, m)
    fade = np.clip(u / 0.06, 0, 1) * np.clip((1 - u) / 0.10, 0, 1)
    return out * fade


def damped_knock(fs, rng, f0, dur_ms, click=0.18):
    """木工敲击：带阻尼的共振 + 一点起振噪声（click 别大，否则成"咔嗒"）。"""
    m = max(8, int(dur_ms / 1000.0 * fs))
    t = np.arange(m) / fs
    body = (np.sin(2 * np.pi * f0 * t) + 0.5 * np.sin(2 * np.pi * 1.6 * f0 * t)
            + 0.25 * np.sin(2 * np.pi * 2.7 * f0 * t))
    body *= np.exp(-t / (dur_ms / 1000.0 * 0.28))
    att = np.exp(-t / 0.002)
    return body * att + click * rng.standard_normal(m) * np.exp(-t / 0.0012)


def water_drop(fs, rng, f0, dur_ms):
    """水滴：短促高频点 + 轻微下坠。"""
    m = max(8, int(dur_ms / 1000.0 * fs))
    t = np.arange(m) / fs
    f = f0 * (1.0 + 0.25 * np.exp(-t / 0.004))
    ph = 2 * np.pi * np.cumsum(f) / fs
    return np.sin(ph) * np.exp(-t / (dur_ms / 1000.0 * 0.22))


# ═══════════════════════════ 八条环境层 ═══════════════════════════

def _wind_synth(n, fs, rng_noise, gust, cros):
    b1 = band_noise(n, fs, 150, 700, rng_noise, 2)
    b2 = band_noise(n, fs, 450, 1400, rng_noise, 2)
    rum = band_noise(n, fs, 25, 110, rng_noise, 2)
    s = (b1 * (0.30 + 0.70 * gust) * (1.0 - 0.45 * cros)
         + 0.62 * b2 * (0.22 + 0.78 * gust) * (0.35 + 0.65 * cros)
         + 0.62 * rum * (0.18 + 0.82 * gust))
    return c_lowpass(s, fs, 2000, 2)


def build_wind_calm(n, fs):
    """平原轻风：录音（柳风，PD）提供真实起伏 + 合成提供低频厚度与阵风。"""
    xf = 2 * fs
    rngs = rng_for("wind_calm", "shared")
    gust = rand_env(n, fs, 0.055, 0.20, rngs, kink=1.45)
    cros = rand_env(n, fs, 0.05, 0.16, rngs, kink=1.15)

    L = _wind_synth(n, fs, rng_for("wind_calm", "noiseL"), gust, cros)
    R = _wind_synth(n, fs, rng_for("wind_calm", "noiseR"), gust, cros)
    synth = np.stack([L, R], axis=1)
    synth = _norm(synth, 1.0)

    base = _blend_src_beds(("wind_willows_02", "wind_willows_05",
                            "wind_willows_09"), n, xf, fs,
                           lp=1500, hp=45, shelf_hi=(2600.0, -5.0),
                           delay_r_ms=11.0)          # 三段柳风叠起来更不像"一段录音"
    mix = 0.62 * synth + (0.68 * base if isinstance(base, np.ndarray) else 0.0)
    mix = c_shelf(mix, fs, 3000.0, -2.5)
    return mix


def _blend_src_beds(keys, n, xf, fs, **kw):
    """把若干条录音各折成一个循环底噪再平均（互相去相关 → 不单调）。"""
    got = []
    for k in keys:
        b = src_bed(k, n, xf, fs, **kw)
        if isinstance(b, np.ndarray):
            got.append(b)
    if not got:
        return None
    return _norm(np.sum(got, axis=0), 1.0)


def build_birds_day(n, fs):
    """白天远处鸟鸣：稀疏合成叫 + 破晓鸟鸣录音（CC0）极低电平当远处底。"""
    xf = 2 * fs
    # Réveil des oiseaux（CC0）：真实晨鸣，压到 3kHz 以下 + 极低电平 = 远处的鸟群絮语
    bed = src_bed("birds_reveil", n, xf, fs, lp=3000, hp=250,
                  shelf_hi=(2600.0, -10.0), gain=0.16)
    if bed is None:
        bed = src_bed("forest_ambience", n, xf, fs, lp=2400, hp=120,
                      shelf_hi=(2200.0, -12.0), gain=0.13)
    if bed is None:
        bed = np.zeros((n, 2))
    bed = circ_reverb(bed, fs, rt60=1.1, pre_ms=18.0, seed=5,
                      style="room", mix=0.25)
    # 极轻的风底，避免叫与叫之间死寂
    g = rand_env(n, fs, 0.06, 0.22, rng_for("birds_day", "gust"), kink=1.3)
    wl = _wind_synth(n, fs, rng_for("birds_day", "wl"), g, g * 0.5 + 0.25)
    wr = _wind_synth(n, fs, rng_for("birds_day", "wr"), g, g * 0.5 + 0.25)
    wind = _norm(np.stack([wl, wr], axis=1), 1.0) * 0.22

    ev_bus = np.zeros((n, 2))
    rng = rng_for("birds_day", "events")
    kinds = list(BIRD_CALLS.keys())
    t = 0.4
    while t < n / fs - 0.5:
        kind = kinds[int(rng.integers(0, len(kinds)))]
        phrase = bird_phrase(BIRD_CALLS[kind], fs, rng)
        dist = float(np.clip(rng.beta(1.6, 1.4), 0.05, 1.0))   # 偏近但两端都有
        ev = distantize(phrase, fs, rng, dist)
        pan = float(np.clip(rng.normal(0.0, 0.55), -0.9, 0.9))
        gl, gr = pan_gains(pan)
        circ_add(ev_bus, ev, int(t * fs), gl, gr)
        t += float(rng.uniform(0.55, 2.1)) * (0.8 + 0.6 * dist)  # 远的更稀疏
    ev_bus = circ_reverb(ev_bus, fs, rt60=1.05, pre_ms=16.0, seed=7,
                         style="room", mix=0.34)
    out = bed + wind + _norm(ev_bus, 0.9)
    return c_shelf(out, fs, 5200.0, -3.0)          # 远处鸟不亮，收一点高频


def _cicada_voice(n, fs, rng, center, bw, trem_hz, depth, env, order=3):
    carrier = spec_noise(n, fs, lambda f: bp_shape(f, center - bw / 2,
                                                   center + bw / 2, order), rng)
    k = max(1, round(trem_hz * n / fs))
    r = k * fs / n
    ph = rng.uniform(0, 2 * np.pi)
    trem = (1.0 - depth) + depth * (0.5 + 0.5 * np.sin(
        2 * np.pi * r * np.arange(n) / fs + ph))
    return carrier * trem * env


def build_cicada_summer(n, fs):
    """夏日蝉鸣：远处蝉雾（真录音，CC0）+ 合成"アブラゼミ/ヒグラシ"两种蝉。"""
    xf = 2 * fs
    haze = _blend_src_beds(("cicada_cn", "cicada_nz", "cicada_florida"), n, xf, fs,
                           hp=500, lp=7000, shelf_hi=(5000.0, -7.0),
                           delay_r_ms=13.0)
    if haze is None:
        haze = np.zeros((n, 2))
    haze = _norm(haze, 1.0) * 0.55
    haze = circ_reverb(haze, fs, rt60=1.6, pre_ms=22.0, seed=11,
                       style="hall", mix=0.30)

    parts = []
    # アブラゼミ：连续、低频颤音
    e1 = rand_env(n, fs, 0.04, 0.16, rng_for("cicada_summer", "e1"), kink=0.9)
    e1 = 0.35 + 0.65 * e1
    parts.append(_cicada_voice(n, fs, rng_for("cicada_summer", "v1"),
                               4200, 2600, 46.0, 0.55, e1))
    # ミンミン系：更亮更快的颤音
    e2 = rand_env(n, fs, 0.05, 0.20, rng_for("cicada_summer", "e2"), kink=1.0)
    e2 = 0.20 + 0.80 * e2
    parts.append(0.7 * _cicada_voice(n, fs, rng_for("cicada_summer", "v2"),
                                     4700, 1700, 63.0, 0.72, e2))
    # ヒグラシ：傍晚的"kana-kana"，周期性起落
    e3 = lfo(n, fs, 0.22, 0.4) ** 2.2
    parts.append(0.65 * _cicada_voice(n, fs, rng_for("cicada_summer", "v3"),
                                      3400, 1400, 29.0, 0.85, e3))
    voices = np.zeros((n, 2))
    # 三只蝉各摆不同位置，制造层次
    for i, sig in enumerate(parts):
        pan = (-0.42, 0.30, 0.05)[i]
        gl, gr = pan_gains(pan)
        off = int((0.0, 0.31, 0.63)[i] * fs) * 0
        st = _norm(sig, 1.0)
        st = np.roll(st, int((0.17 * i) * fs))
        voices[:, 0] += st * gl
        voices[:, 1] += st * gr
    voices = _norm(voices, 1.0)
    # "远"：压高频 + 低通 + 混响
    voices = c_lowpass(voices, fs, 8200, 2)
    voices = c_shelf(voices, fs, 4800.0, -6.0)
    voices = circ_reverb(voices, fs, rt60=1.5, pre_ms=20.0, seed=23,
                         style="hall", mix=0.42)
    out = 1.0 * haze + 0.85 * voices
    return c_shelf(out, fs, 4500.0, -2.0)          # 再收一点，防"电锯"


def real_cricket_event(fs, rng, dur_s=0.22):
    """从蟋蟀录音（PD）里抠一段真实鸣声当事件。

    该录音整体低频偏重（现场底噪），直接当床不好用；但带通后能看出
    30~50Hz 的脉冲串（真蟋蟀的"颤"），截要 3.0-6.5kHz 的窄带段
    正好拿到"清脆"的真音色。
    """
    x = load_src("cricket_jer")
    if x is None:
        return None
    y = dsp.highpass(dsp.lowpass(x.mean(axis=1), fs, 6500, 2), fs, 3000, 2)
    seg = loudest_region(y, dur_s, fs)
    if float(np.sqrt(np.mean(seg ** 2))) < 1e-6:
        return None
    return _norm(seg, 0.5)


def build_night_insects(n, fs):
    """夜晚虫鸣：合成稀疏清脆的蟋蟀/铃虫 + 真实蟋蟀鸣声事件 + 极轻夜气。"""
    ev = np.zeros((n, 2))
    rng = rng_for("night_insects", "events")
    # (carrier, pulses, rate, pulse_ms, gap_lo, gap_hi, pan)
    species = [
        (4300.0, 4, 24.0, 14.0, 0.35, 0.95, -0.45),
        (5200.0, 3, 31.0, 12.0, 0.42, 1.15, 0.40),
        (3600.0, 5, 20.0, 18.0, 0.65, 1.60, -0.10),
    ]
    for (fc, pu, pr, pm, glo, ghi, pbase) in species:
        t = float(rng.uniform(0.2, 1.4))
        while t < n / fs - 0.4:
            ch = cricket_chirp(fs, rng, fc, pu, pr, pm)
            dist = float(np.clip(rng.beta(2.0, 2.0), 0.05, 0.85))
            ch = distantize(ch, fs, rng, dist)
            pan = float(np.clip(pbase + rng.normal(0, 0.28), -0.9, 0.9))
            gl, gr = pan_gains(pan)
            circ_add(ev, ch, int(t * fs), gl, gr)
            t += float(rng.uniform(glo, ghi))
    # 铃虫：偶尔一条长颤音
    t = 2.0
    while t < n / fs - 2.0:
        tr = suzumushi_trill(fs, rng, 4400.0, float(rng.uniform(0.9, 1.6)), 30.0)
        tr = distantize(tr, fs, rng, float(rng.uniform(0.35, 0.8)))
        gl, gr = pan_gains(float(rng.uniform(-0.6, 0.6)))
        circ_add(ev, tr, int(t * fs), gl, gr)
        t += float(rng.uniform(4.5, 8.0))
    # 真实蟋蟀鸣声（短素材，低电平点缀，只给真音色——别让它主导）
    real = real_cricket_event(fs, rng, 0.22)
    if real is not None:
        for tt in (2.9, 6.4, 9.8, 13.4, 16.1, 18.6):
            if tt < n / fs - 0.5:
                r = distantize(real.copy(), fs, rng, float(rng.uniform(0.4, 0.8)))
                gl, gr = pan_gains(float(rng.uniform(-0.7, 0.7)))
                circ_add(ev, r, int(tt * fs), gl, gr)
    ev = circ_reverb(ev, fs, rt60=0.85, pre_ms=13.0, seed=31,
                     style="room", mix=0.30)
    ev = c_highpass(ev, fs, 700, 2)            # 去掉嗡声，保持"清脆"
    # 极轻的夜间空气（近似无内容，只是不让声场"死"）
    air_l = band_noise(n, fs, 300, 1800, rng_for("night_insects", "aL"), 2)
    air_r = band_noise(n, fs, 300, 1800, rng_for("night_insects", "aR"), 2)
    air = _norm(np.stack([air_l, air_r], axis=1), 1.0) * 0.20
    out = air + _norm(ev, 0.95)
    return c_shelf(out, fs, 5200.0, -3.0)          # 虫鸣清脆但不扎耳


def _wave_swell(n, fs, rng, amp, lo, hi, foam_amp, crest, dur):
    """一次涌浪：慢起慢落的水体涌动 + 峰上的泡沫嘶声。"""
    m = int(dur * fs)
    t = np.arange(m) / fs
    u = t / dur
    surge = (np.clip(u / crest, 0, 1) ** 1.6
             * np.clip((1.0 - u) / (1.0 - crest), 0, 1) ** 1.25)
    low = spec_noise(m, fs, lambda f: bp_shape(f, lo, hi, 3), rng) * surge
    foam_env = np.exp(-((u - (crest + 0.07)) ** 2) / (2 * 0.13 ** 2))
    foam = spec_noise(m, fs, lambda f: bp_shape(f, 850, 4200, 2), rng) * foam_env
    return low * amp + foam * foam_amp * amp


def build_waves_shore(n, fs):
    """海浪拍岸：缓慢涌浪节奏。合成涌浪保证节奏可控，CC0 真浪补真实质感。"""
    buf = np.zeros((n, 2))
    rng = rng_for("waves_shore", "synth")
    # 低沉的持续水床（浪谷也不空）
    rum_l = band_noise(n, fs, 30, 130, rng_for("waves_shore", "rumL"), 2)
    rum_r = band_noise(n, fs, 30, 130, rng_for("waves_shore", "rumR"), 2)
    swell_env = rand_env(n, fs, 0.02, 0.09, rng_for("waves_shore", "slow"), 1.0)
    rum = np.stack([rum_l, rum_r], axis=1) * (0.35 + 0.65 * swell_env)[:, None]
    buf += _norm(rum, 1.0) * 0.42
    # 浪谷的极轻泡沫底（避免"死寂"）
    fo_l = band_noise(n, fs, 1200, 5000, rng_for("waves_shore", "foL"), 2)
    fo_r = band_noise(n, fs, 1200, 5000, rng_for("waves_shore", "foR"), 2)
    foam_bed = np.stack([fo_l, fo_r], axis=1) * (0.25 + 0.75 * swell_env)[:, None]
    buf += _norm(foam_bed, 1.0) * 0.12

    # 合成的涌浪：不同周期/幅度，避免机械感
    swells = [(5.5, 4.2, 55, 320, 0.55, 0.36), (7.4, 6.0, 65, 380, 0.75, 0.32),
              (4.6, 3.4, 48, 280, 0.45, 0.40), (8.8, 7.0, 70, 420, 0.85, 0.30)]
    for dur, amp, lo, hi, foam_amp, crest in swells:
        t = float(rng.uniform(0.0, dur))
        while t < n / fs:
            l = _wave_swell(int(dur * fs), fs, rng_for("waves_shore", "sw%d" % int(t * 100)),
                            amp, float(lo), float(hi), foam_amp, crest, dur)
            # 每次涌浪左右去相关的两套噪声
            rr = rng_for("waves_shore", "swR%d" % int(t * 100))
            r = _wave_swell(int(dur * fs), fs, rr, amp, float(lo), float(hi),
                            foam_amp, crest, dur)
            circ_add(buf, _norm(l, 1.0) * 0.5, int(t * fs), 0.82, 0.57)
            circ_add(buf, _norm(r, 1.0) * 0.5, int(t * fs), 0.57, 0.82)
            t += dur
    # CC0 真浪（OpenGameArt）：当额外的"大浪"叠加，补真实质感
    real_keys = ["wave_beach_1", "wave_beach_2", "wave_beach_3", "wave_beach_4",
                 "wave_water_1", "wave_water_2", "wave_water_3", "wave_water_4"]
    placed = 0
    for k in real_keys:
        if placed >= 5:
            break
        x = load_src(k)
        if x is None or len(x) < int(1.0 * fs):
            continue
        wav = loudest_region(x.mean(axis=1), min(len(x) / fs, 9.0), fs)
        wav = dsp.highpass(wav, fs, 40, 2)
        wav = dsp.lowpass(wav, fs, 5500, 2)
        wav = dsp.shelf(wav, fs, 4000.0, -3.0, kind="high")
        wav = _norm(wav, 1.0)
        t = float(rng.uniform(0.0, n / fs))
        g = float(rng.uniform(0.28, 0.55))
        circ_add(buf, wav, int(t * fs), g * 0.82, g * 0.57)
        placed += 1
    buf = c_highpass(buf, fs, 25, 2)
    buf = c_shelf(buf, fs, 4500.0, -2.0)
    return buf


def build_stream_water(n, fs):
    """小溪流水：多带噪声 + 快速随机起伏造"水泡颗粒"，高掉低频避免隆隆。"""
    buf = np.zeros((n, 2))
    bands = [(420, 1100, 0.55, 4, 22), (900, 2200, 0.60, 5, 26),
             (1600, 3800, 0.50, 6, 30), (2600, 6200, 0.34, 7, 34),
             (6200, 13000, 0.18, 8, 40)]
    rng = rng_for("stream_water", "synth")
    for lo, hi, g, wlo, whi in bands:
        for ch, salt in ((0, "L"), (1, "R")):
            b = band_noise(n, fs, lo, hi, rng_for("stream_water", "%d%s" % (lo, salt)), 2)
            walk = rand_env(n, fs, wlo, whi,
                            rng_for("stream_water", "w%d%s" % (lo, salt)),
                            kink=1.0, order=1)
            buf[:, ch] += b * (0.25 + 0.75 * walk) * g
    buf = _norm(buf, 1.0)
    # 咕嘟/水泡事件
    drops = np.zeros((n, 2))
    rng = rng_for("stream_water", "gurgles")
    t = 0.3
    while t < n / fs - 0.3:
        d = water_drop(fs, rng, float(rng.uniform(700, 2600)),
                       float(rng.uniform(20, 55)))
        d = _norm(d, 1.0) * float(rng.uniform(0.15, 0.5))
        gl, gr = pan_gains(float(rng.uniform(-0.7, 0.7)))
        circ_add(drops, d, int(t * fs), gl, gr)
        t += float(rng.uniform(0.18, 0.9))
    # 真实溪流录音（CC0 Swale）叠加，补真实的碎石质感
    real = src_bed("stream_swale", n, 2 * fs, fs, hp=350, lp=12000,
                   shelf_hi=(5500.0, -3.0), delay_r_ms=8.0, gain=1.0)
    out = (0.75 * buf + (0.60 * real if isinstance(real, np.ndarray) else 0.0)
           + 0.22 * drops)
    out = c_highpass(out, fs, 300, 2)
    out = c_shelf(out, fs, 5000.0, -4.0)
    return out


def build_rain_soft(n, fs):
    """柔和雨声：高频噪声 + 缓慢起伏 + 偶发水滴点；高掉低频，不要隆隆。"""
    buf = np.zeros((n, 2))
    rng = rng_for("rain_soft", "synth")
    swell = rand_env(n, fs, 0.04, 0.22, rng_for("rain_soft", "swell"), 1.1)
    for ch, salt in ((0, "L"), (1, "R")):
        hi = band_noise(n, fs, 3000, 15000, rng_for("rain_soft", "hi" + salt), 2)
        mid = band_noise(n, fs, 1200, 4000, rng_for("rain_soft", "mid" + salt), 2)
        buf[:, ch] += hi * (0.45 + 0.55 * swell) + mid * (0.22 + 0.30 * swell)
    # 偶发水滴（雨打在物体上的点）
    drops = np.zeros((n, 2))
    rng = rng_for("rain_soft", "drops")
    t = 0.2
    while t < n / fs - 0.2:
        d = water_drop(fs, rng, float(rng.uniform(1800, 5200)),
                       float(rng.uniform(8, 26)))
        d = _norm(d, 1.0) * float(rng.uniform(0.08, 0.35))
        gl, gr = pan_gains(float(rng.uniform(-0.8, 0.8)))
        circ_add(drops, d, int(t * fs), gl, gr)
        t += float(rng.uniform(0.15, 1.1))
    # 真实雨录音（CC0，露台小雨；选最平稳的段避开远雷）叠底
    real = src_bed("rain_field", n, 2 * fs, fs, hp=400, lp=14000,
                   shelf_hi=(6500.0, -3.0), delay_r_ms=9.0, gain=1.0)
    out = (_norm(buf, 1.0) * 0.80
           + (0.55 * real if isinstance(real, np.ndarray) else 0.0)
           + 0.30 * drops)
    out = c_highpass(out, fs, 400, 2)
    out = c_shelf(out, fs, 6500.0, -3.0)
    return out


def build_village_ambience(n, fs):
    """村落远景：极轻的风 + 远处木工敲击 + 偶尔鸡鸣/羊叫（真录音，远处理过）。"""
    xf = 2 * fs
    g = rand_env(n, fs, 0.05, 0.20, rng_for("village", "gust"), 1.35)
    wl = _wind_synth(n, fs, rng_for("village", "wl"), g, g * 0.5 + 0.25)
    wr = _wind_synth(n, fs, rng_for("village", "wr"), g, g * 0.5 + 0.25)
    wind = _norm(np.stack([wl, wr], axis=1), 1.0) * 0.60

    ev = np.zeros((n, 2))
    rng = rng_for("village", "events")
    # 远处木工敲击：两三下一组，注意节奏
    t = 1.2
    while t < n / fs - 1.0:
        f0 = float(rng.uniform(220, 520))
        for k in range(int(rng.integers(2, 4))):
            kn = damped_knock(fs, rng, f0 * float(rng.uniform(0.95, 1.05)),
                              float(rng.uniform(90, 170)))
            kn = distantize(kn, fs, rng, float(rng.uniform(0.55, 0.9)))
            gl, gr = pan_gains(float(np.clip(rng.normal(-0.2, 0.4), -0.8, 0.8)))
            circ_add(ev, _norm(kn, 1.0) * 0.5, int((t + k * 0.34) * fs), gl, gr)
        t += float(rng.uniform(3.0, 7.5))
    # 远处家禽（真录音）：鸡鸣（CC BY 3.0）+ 羊叫（PD），重度低通 + 混响 = 村子那头
    fowl = load_src("village_fowl")
    if fowl is not None:
        f = loudest_region(fowl.mean(axis=1), min(len(fowl) / fs, 0.5), fs)
        f = dsp.lowpass(f, fs, 3200, 2)
        f = dsp.shelf(f, fs, 2500.0, -6.0, kind="high")
        f = _norm(f, 1.0)
        for tt in (2.4, 7.1, 15.8):
            if tt < n / fs - 0.5:
                gl, gr = pan_gains(float(rng.uniform(-0.6, 0.6)))
                circ_add(ev, f * 0.26, int(tt * fs), gl, gr)
    sheep = load_src("sheep")
    if sheep is not None:
        s = loudest_region(sheep.mean(axis=1), min(len(sheep) / fs, 0.9), fs)
        s = distantize(s, fs, rng, 0.8)
        gl, gr = pan_gains(float(rng.uniform(-0.7, 0.4)))
        circ_add(ev, _norm(s, 1.0) * 0.18, int(8.4 * fs), gl, gr)
    ev = circ_reverb(ev, fs, rt60=1.3, pre_ms=24.0, seed=41,
                     style="hall", mix=0.45)
    return wind + ev


# ═══════════════════════════ 配方表 ═══════════════════════════
# seconds 全部整除采样点；target 落在 -30 ~ -26 LUFS。

LAYERS = {
    "wind_calm": dict(seconds=16.0, target=-28.0, build=build_wind_calm,
                      zh="平原/草原轻风",
                      route="两者融合：三段柳风录音（PD）叠底 + 谱合成阵风/低频"),
    "birds_day": dict(seconds=20.0, target=-28.5, build=build_birds_day,
                      zh="白天远处鸟鸣",
                      route="两者融合：破晓鸟鸣录音（CC0）当远底 + 合成稀疏叫",
                      spec_overrides={"band_2_5k_p95": 0.92}),
    "cicada_summer": dict(seconds=18.0, target=-28.0, build=build_cicada_summer,
                          zh="夏日远蝉",
                          route="两者融合：三段蝉录音（CC0/PD/CC BY 3.0）当雾底 + 合成蝉",
                          spec_overrides={"band_2_5k_p95": 0.92}),
    "night_insects": dict(seconds=20.0, target=-28.5, build=build_night_insects,
                          zh="夜晚虫鸣",
                          route="两者融合：合成稀疏清脆鸣 + 蟋蟀录音（PD）抠真实鸣声事件",
                          spec_overrides={"band_2_5k_p95": 0.92}),
    "waves_shore": dict(seconds=18.0, target=-27.5, build=build_waves_shore,
                        zh="海浪拍岸",
                        route="两者融合：合成涌浪节奏 + OpenGameArt CC0 真浪"),
    "stream_water": dict(seconds=14.0, target=-27.5, build=build_stream_water,
                         zh="小溪流水",
                         route="两者融合：合成多带颗粒 + 溪流录音（CC0 Swale）",
                         spec_overrides={"band_2_5k_p95": 0.55}),
    "rain_soft": dict(seconds=16.0, target=-28.0, build=build_rain_soft,
                      zh="柔和雨声（加分项）",
                      route="两者融合：合成高频雨 + 雨录音（CC0）叠底",
                      spec_overrides={"band_2_5k_p95": 0.60}),
    "village_ambience": dict(seconds=20.0, target=-29.0, build=build_village_ambience,
                             zh="村落远景声（加分项）",
                             route="两者融合：合成风/木工敲击 + 鸡鸣（CC BY 3.0）/羊叫（PD）远处理"),
}

ORDER = ["wind_calm", "birds_day", "cicada_summer", "night_insects",
         "waves_shore", "stream_water", "rain_soft", "village_ambience"]


# ═══════════════════════════ 收尾与质检 ═══════════════════════════

def finalize(y: np.ndarray, fs: int, target_lufs: float,
             tp_ceiling: float = TP_CEILING) -> np.ndarray:
    y = np.asarray(y, dtype=np.float64)
    y = y - y.mean(axis=0, keepdims=True)
    lufs = integrated_lufs(y, fs)
    if np.isfinite(lufs):
        y = y * (10.0 ** ((target_lufs - lufs) / 20.0))
    tp = true_peak_dbfs(y, fs)
    if np.isfinite(tp) and tp > tp_ceiling:
        y = y * (10.0 ** ((tp_ceiling - tp) / 20.0))
    return y.astype(np.float32)


def seam_stats(mono: np.ndarray) -> dict:
    """无缝性的客观检验（三把尺子）。

    1. **接缝跳变分位**（主判据）：|x[0]-x[n-1]| 在**接缝邻域 ±0.5s** 的一阶差分分布
       里排第几百分位。无缝 → 接缝那一步只是行情里的普通一步，分位 ≈ 50；硬切 →
       接缝那一步明显大于邻近所有步 → 分位冲到 ≈100。
       用局部窗口而不是全段分布，是因为"这一步是否突兀"只跟它周围有关——比如浪的
       泡沫迸发里本来就全是大幅一步，接缝落在里面也不该算异常。
    2. **绝对口径**：同一跳变 / 信号 RMS（dB），看它离"噪声天然抖动"有多远。
    3. **电平连续性**：末尾 0.5s 均值 vs 开头 0.5s 均值之差（相对 RMS），防音量台阶。
    """
    n = len(mono)
    d = np.abs(np.diff(mono))
    rms = float(np.sqrt(np.mean(mono ** 2))) + 1e-15
    jump = abs(float(mono[0] - mono[n - 1]))
    k = min(int(0.5 * FS), n // 4)
    loc = np.abs(np.diff(np.concatenate([mono[n - k:], mono[:k]])))
    lvl = abs(float(mono[:k].mean() - mono[n - k:].mean()))
    return {
        "seam_jump_pct": round(100.0 * float(np.mean(loc <= jump)), 2),
        "seam_jump_pct_global": round(100.0 * float(np.mean(d <= jump)), 2),
        "seam_jump_db": round(20.0 * np.log10((jump + 1e-15) / rms), 2),
        "seam_level_db": round(20.0 * np.log10((lvl + 1e-15) / rms), 2),
        "seam_flux_ratio": round(loop_seam_report(mono, 0, n,
                                                  fs=FS).get("seam_flux_ratio", 0.0), 3),
    }


def qc_report(x: np.ndarray, fs: int, naive: np.ndarray | None = None) -> dict:
    mono = x.mean(axis=1)
    sr = spectral_report(x, fs)
    mc = mono_compat_report(x, fs)
    rep = {
        "duration_s": round(len(mono) / fs, 3),
        "integrated_lufs": round(integrated_lufs(x, fs), 2),
        "true_peak_dbtp": round(true_peak_dbfs(x, fs), 2),
        "band_2_5k_p95": round(sr["band_2_5k_ratio_p95"], 4),
        "band_2_5k_mean": round(sr["band_2_5k_ratio_mean"], 4),
        "centroid_hz_p95": round(sr["centroid_hz_p95"], 1),
        "flatness_p95": round(sr["flatness_p95"], 5),
        "mono_corr": round(mc["correlation"], 3),
        "mono_loss_lu": round(mc["mono_loss_lu"], 3),
        "silence_holes": count_silence_holes(mono, fs),
        "clipped": int(np.sum(np.abs(x) >= 0.9995)),
    }
    rep.update(seam_stats(mono))
    if naive is not None:
        rep["naive_cut_jump_pct"] = round(100.0 * float(
            np.mean(np.abs(np.diff(naive.mean(axis=1)))
                    <= abs(float(naive[0].mean() - naive[-1].mean())))), 2)
    return rep


SPEC = {
    "integrated_lufs": {"min": -30.0, "max": -26.0},
    "true_peak_dbtp": {"max": -1.5},
    "band_2_5k_p95": {"max": 0.30},          # 宽频底噪：2-5kHz 不该占主导（防刺耳）
    "band_2_5k_mean": {"max": 0.65},         # 全程序平均占比的总闸
    "seam_jump_pct": {"max": 99.9},          # 接缝跳变不得是段内分布的离群点
    "seam_level_db": {"max": -20.0},         # 接缝处不得有电平台阶
    "seam_flux_ratio": {"max": 2.0},
    "silence_holes": {"max": 0},             # 不得有 >50ms 的静音空洞
    "clipped": {"max": 0},
}


def check(rep: dict, overrides: dict | None = None) -> list:
    spec = dict(SPEC)
    for k, v in (overrides or {}).items():
        spec[k] = v if isinstance(v, dict) else {"max": v}   # 覆写可只给上限
    fails = []
    for k, rule in spec.items():
        v = rep.get(k)
        if v is None:
            continue
        if "max" in rule and v > rule["max"]:
            fails.append("%s=%s>%s" % (k, v, rule["max"]))
        if "min" in rule and v < rule["min"]:
            fails.append("%s=%s<%s" % (k, v, rule["min"]))
    return fails


# ═══════════════════════════ 生成 / 校验 / 下载 ═══════════════════════════

def generate(name: str, write: bool = True) -> dict:
    spec = LAYERS[name]
    n = int(round(spec["seconds"] * FS))
    t0 = time.time()
    y = spec["build"](n, FS)
    if y.ndim == 1:
        y = np.repeat(y[:, None], 2, axis=1)
    if len(y) != n:
        y = y[:n] if len(y) > n else np.concatenate(
            [y, np.zeros((n - len(y), 2))], axis=0)
    y = finalize(y, FS, spec["target"])
    rep = qc_report(y, FS)
    rep["build_s"] = round(time.time() - t0, 1)
    rep["route"] = spec["route"]
    rep["zh"] = spec["zh"]
    rep["target_lufs"] = spec["target"]
    rep["fails"] = check(rep, spec.get("spec_overrides"))
    if write:
        path = OUT_DIR / ("%s.wav" % name)
        write_wav(str(path), y, FS, subtype="PCM_16")
        (TMP_DIR / "ambience").mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, TMP_DIR / "ambience" / ("%s.wav" % name))
        rep["path"] = str(path)
        rep["bytes"] = path.stat().st_size
    return rep


def run(names, write=True, verbose=True) -> dict:
    reports = {}
    for i, name in enumerate(names, 1):
        if verbose:
            print("[%d/%d] %-18s %s ..." % (i, len(names), name, LAYERS[name]["zh"]),
                  flush=True)
        reports[name] = generate(name, write)
        if verbose:
            r = reports[name]
            flag = "OK " if not r["fails"] else "FAIL"
            print("      %s  %5.2f LUFS  TP %5.2f  seamPct %5.1f%% 2-5k %.3f  (%.0fs)"
                  % (flag, r["integrated_lufs"], r["true_peak_dbtp"],
                     r["seam_jump_pct"], r["band_2_5k_p95"], r["build_s"]),
                  flush=True)
    return reports


def fetch_sources() -> None:
    """下载源材料（幂等：文件大小对得上就跳过；zip 包按 member 解出）。"""
    SRC_DIR.mkdir(parents=True, exist_ok=True)
    for key, m in SOURCES.items():
        if "url" not in m:
            continue
        dst = SRC_DIR / m["file"]
        if dst.exists() and dst.stat().st_size > 0 and (
                "size" not in m or dst.stat().st_size == m["size"]):
            print("skip  %-22s %s" % (key, m["file"]))
            continue
        print("fetch %-22s %s" % (key, m["file"]), flush=True)
        target = dst
        if m.get("zip_member"):
            target = SRC_DIR / (m["file"] + ".zip")
        subprocess.run(["curl", "-sSL", "--retry", "5", "--retry-all-errors",
                        "--retry-delay", "2", "-m", "300",
                        "-A", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)",
                        "-o", str(target), m["url"]], capture_output=True)
        if m.get("zip_member") and target.exists():
            import zipfile
            try:
                with zipfile.ZipFile(target) as z:
                    with z.open(m["zip_member"]) as fi, open(dst, "wb") as fo:
                        shutil.copyfileobj(fi, fo)
                target.unlink()
            except Exception as e:
                print("      zip 解包失败: %s" % e)


def verify(names) -> int:
    print("")
    print("=" * 120)
    print("%-18s %6s %8s %8s %8s %8s %9s %9s %9s %7s %5s"
          % ("layer", "dur", "LUFS", "truePk", "2-5kP95", "2-5kAvg",
             "seamPct", "seamJump", "seamFlux", "monoCorr", "PASS"))
    print("-" * 120)
    bad = 0
    for name in names:
        p = OUT_DIR / ("%s.wav" % name)
        if not p.exists():
            print("%-18s  (missing)" % name)
            bad += 1
            continue
        x = load_stem(str(p), FS).astype(np.float64)
        rep = qc_report(x, FS)
        fails = check(rep, LAYERS[name].get("spec_overrides"))
        if fails:
            bad += 1
        print("%-18s %6.1f %8.2f %8.2f %8.3f %8.3f %8.1f%% %+8.1f %9.3f %7.3f %5s"
              % (name, rep["duration_s"], rep["integrated_lufs"],
                 rep["true_peak_dbtp"], rep["band_2_5k_p95"],
                 rep["band_2_5k_mean"], rep["seam_jump_pct"],
                 rep["seam_jump_db"], rep["seam_flux_ratio"],
                 rep["mono_corr"], "OK" if not fails else "FAIL"))
        for f in fails:
            print("      ! %s" % f)
    print("=" * 120)
    print("阈值: LUFS∈[-30,-26]  truePk<=-1.5  2-5kP95<=0.30  "
          "seamPct<=99.9  seamLevel<=-20dB  seamFlux<=2.0  clipped=0")
    print("seamPct = 接缝跳变在段内一阶差分分布里的百分位（无缝≈50，硬切≈100）")
    return bad


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="环境音层生成管线")
    ap.add_argument("--only", help="只生成指定层（逗号分隔）")
    ap.add_argument("--list", action="store_true", help="列出所有层")
    ap.add_argument("--fetch", action="store_true", help="下载源材料")
    ap.add_argument("--verify", action="store_true", help="校验已生成的 WAV 并打表")
    ap.add_argument("--no-write", action="store_true", help="只算不写文件")
    args = ap.parse_args(argv)

    if args.list:
        for k in ORDER:
            print("%-18s %5.1fs  %s\n    %s"
                  % (k, LAYERS[k]["seconds"], LAYERS[k]["zh"], LAYERS[k]["route"]))
        return 0
    if args.fetch:
        fetch_sources()
        return 0
    if args.verify:
        names = ([s.strip() for s in args.only.split(",")] if args.only else ORDER)
        return 1 if verify(names) else 0

    names = ([s.strip() for s in args.only.split(",")] if args.only else ORDER)
    for nm in names:
        if nm not in LAYERS:
            print("未知层: %s（可选：%s）" % (nm, ", ".join(ORDER)))
            return 2
    have = sum(1 for k in SOURCES if (SRC_DIR / SOURCES[k]["file"]).exists())
    print("源材料: %d/%d 就位（缺的层自动走纯合成兜底；--fetch 可补齐）"
          % (have, len(SOURCES)))
    reports = run(names, write=not args.no_write)
    json.dump(reports, open(TMP_DIR / "ambience_report.json", "w",
                            encoding="utf-8"), ensure_ascii=False, indent=1)
    bad = sum(1 for r in reports.values() if r["fails"])
    print("\n完成 %d 层，%d 层未过阈值。报表: %s"
          % (len(reports), bad, TMP_DIR / "ambience_report.json"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    raise SystemExit(main())
