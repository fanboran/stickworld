# -*- coding: utf-8 -*-
"""程序化混响 —— 用噪声合成脉冲响应（IR），再做卷积。

为什么不用引擎自带的混响插件：离线管线里，卷积混响的音质上限高得多，
而且 **IR 是可复现的工件**（同 seed 同结果，能进版本库、能 A/B 对比）。
真·录音采样 IR 有版权问题，合成 IR 没有。

合成方法（音乐厅常用近似）：
  1. 把白噪声按频段切开，每个频段给一条**自己的指数衰减**——
     真实空间里高频被空气与材料吸收，衰减比低频快，这是"自然"的核心；
  2. 叠加**早期反射**（稀疏点阵），决定"房间多大、多近"；
  3. 给整体加一个 **build-up**（指数起振），避免"啪"地一下全响；
  4. 左右声道用不同噪声（去相关），才有立体声宽度而不是居中一团。

三种预设对应三种用途（见 docs/设计/音乐/混音与母带规范）：
  hall  —— 主空间，钢琴与整体
  plate —— 色彩打击（钟琴/八音盒），密而亮
  room  —— 室内场景，短而近
"""
from __future__ import annotations

import numpy as np
from scipy import signal

RT60_DB = -60.0
_LN1000 = 6.907755278982137      # ln(1000)，即 -60dB


def _band(x: np.ndarray, fs: int, lo: float, hi: float) -> np.ndarray:
    nyq = fs / 2.0
    lo = max(lo, 1.0)
    hi = min(hi, nyq * 0.99)
    if lo >= hi:
        return np.zeros_like(x)
    if lo <= 1.0:
        sos = signal.butter(2, hi / nyq, btype="low", output="sos")
    elif hi >= nyq * 0.98:
        sos = signal.butter(2, lo / nyq, btype="high", output="sos")
    else:
        sos = signal.butter(2, [lo / nyq, hi / nyq], btype="band", output="sos")
    return signal.sosfilt(sos, x, axis=0)


# 预设：各频段的 RT60 倍率、build-up 时间、早期反射强度、频谱倾斜
#
# tilt_db_per_oct 是把 IR 的频谱从"白噪"拉向"粉噪"的倾斜量。
# 这一点很关键：如果各频段用等方差噪声合成，IR 的频谱是白的——高频能量
# 远大于真实房间，混响会发"嘶"、发亮，正是"刺耳"的元凶之一。
# 真实空间的余响接近粉噪（每倍频程 -3dB），这里取 -2.5dB 作为略偏亮的折中。
PRESETS = {
    "hall": dict(rt_low=1.25, rt_mid=1.0, rt_high=0.55, buildup_ms=22.0,
                 early_level=0.55, early_spread_ms=85.0, tilt_db_per_oct=-2.5,
                 hf_shelf_hz=3200.0, density=1.0),
    "plate": dict(rt_low=0.75, rt_mid=1.0, rt_high=0.85, buildup_ms=6.0,
                  early_level=0.18, early_spread_ms=22.0, tilt_db_per_oct=-1.6,
                  hf_shelf_hz=5000.0, density=1.35),
    "room": dict(rt_low=1.1, rt_mid=1.0, rt_high=0.7, buildup_ms=9.0,
                 early_level=0.7, early_spread_ms=38.0, tilt_db_per_oct=-2.2,
                 hf_shelf_hz=4000.0, density=0.9),
}


def make_ir(fs: int = 48000, rt60: float = 2.2, pre_delay_ms: float = 26.0,
            seed: int = 0, style: str = "hall",
            brightness_db: float = 0.0) -> np.ndarray:
    """合成一条立体声 IR，返回 (n, 2) float64，已能量归一。

    rt60 指中频段衰减 60dB 所需秒数；其它频段按预设倍率缩放。
    brightness_db 用于整体调亮/调暗（正=亮）。
    """
    p = PRESETS[style]
    pre = int(pre_delay_ms * fs / 1000.0)
    # 长度必须按**衰减最慢的频段**算，否则低频尾巴会被截断——
    # 那正是"混响被硬切"的典型症状（耳朵会听到不自然的骤然中断）。
    slowest = max(p["rt_low"], p["rt_mid"], p["rt_high"])
    tail_n = int(rt60 * slowest * 1.45 * fs) + int(0.2 * fs)
    n = pre + tail_n
    rng = np.random.default_rng(1000 + seed)

    t = (np.arange(n) - pre) / fs
    t_after = np.clip(t, 0.0, None)

    out = np.zeros((n, 2), dtype=np.float64)
    bands = [
        (0.0, 220.0, p["rt_low"]),
        (220.0, 1200.0, (p["rt_low"] + p["rt_mid"]) / 2.0),
        (1200.0, 5000.0, p["rt_mid"]),
        (5000.0, fs / 2.0, p["rt_high"]),
    ]
    for ch in range(2):
        noise = rng.standard_normal(n)
        acc = np.zeros(n)
        for lo, hi, rt_ratio in bands:
            rt = max(0.08, rt60 * rt_ratio)
            b = _band(noise, fs, lo, hi)
            env = np.exp(-_LN1000 * t_after / rt)
            env[t < 0.0] = 0.0
            # 频谱倾斜：按频段中心频率相对 1kHz 计算增益，把白噪拉向粉噪
            center = max(60.0, (lo + min(hi, fs / 2.0)) / 2.0)
            gain_db = p["tilt_db_per_oct"] * np.log2(center / 1000.0)
            acc += b * env * (10.0 ** (gain_db / 20.0))
        # build-up：避免瞬时起振造成的"啪"
        build = 1.0 - np.exp(-t_after / max(p["buildup_ms"] / 1000.0, 1e-4))
        build[t < 0.0] = 0.0
        acc *= build
        out[:, ch] = acc

    # 早期反射：稀疏点阵，左右错开时间以获得宽度
    if p["early_level"] > 0:
        early = np.zeros((n, 2))
        spread = p["early_spread_ms"] / 1000.0
        n_taps = 14
        for i in range(n_taps):
            for ch in range(2):
                tt = rng.uniform(0.003, spread) * (1.0 + 0.35 * ch)
                idx = pre + int(tt * fs)
                if idx >= n:
                    continue
                amp = p["early_level"] * np.exp(-3.2 * tt / spread) * rng.uniform(0.5, 1.0)
                # 每个拍点展开成短小包络，避免单点造成的"咔"
                k = max(2, int(0.004 * fs))
                env = np.exp(-np.arange(k) / (0.0018 * fs))
                seg = amp * rng.standard_normal(k) * env
                end = min(n, idx + k)
                early[idx:end, ch] += seg[:end - idx]
        early = _band(early, fs, 320.0, fs / 2.0)
        out += early

    # 去直流 / 压缩低频尾巴（低频混响最容易让混音发浑）
    out = signal.sosfilt(signal.butter(2, 38.0 / (fs / 2), btype="high",
                                       output="sos"), out, axis=0)

    if abs(brightness_db) > 1e-6:
        A = 10.0 ** (brightness_db / 40.0)
        w0 = 2 * np.pi * p["hf_shelf_hz"] / fs
        alpha = np.sin(w0) / 2 * np.sqrt(2)
        cosw = np.cos(w0)
        b = np.array([A * ((A + 1) + (A - 1) * cosw + 2 * np.sqrt(A) * alpha),
                      -2 * A * ((A - 1) + (A + 1) * cosw),
                      A * ((A + 1) + (A - 1) * cosw - 2 * np.sqrt(A) * alpha)])
        a = np.array([(A + 1) - (A - 1) * cosw + 2 * np.sqrt(A) * alpha,
                      2 * ((A - 1) - (A + 1) * cosw),
                      (A + 1) - (A - 1) * cosw - 2 * np.sqrt(A) * alpha])
        out = signal.lfilter(b / a[0], a / a[0], out, axis=0)

    # 能量归一：让不同 RT60 的 IR 在同等 send 量下响度接近
    e = np.sqrt(np.sum(out ** 2) / out.shape[1])
    if e > 0:
        out /= e
    return out


# IR 缓存（同一 cue 的多个 stem 共用一条 IR，省去重复合成）
_IR_CACHE: dict = {}


def get_ir(fs: int, rt60: float, pre_delay_ms: float, seed: int = 0,
           style: str = "hall", brightness_db: float = 0.0) -> np.ndarray:
    key = (fs, round(rt60, 3), round(pre_delay_ms, 2), seed, style,
           round(brightness_db, 2))
    if key not in _IR_CACHE:
        _IR_CACHE[key] = make_ir(fs, rt60, pre_delay_ms, seed, style,
                                 brightness_db)
    return _IR_CACHE[key]


def convolve_reverb(x: np.ndarray, ir: np.ndarray, fs: int,
                    mix: float = 0.25, pre_delay_samples: int | None = None) -> np.ndarray:
    """把 x 与 IR 卷积，取前 len(x) 帧，按 mix 与干声混合。

    mix 是湿声比例（0=dry，1=全湿）。IR 自带 pre-delay，故默认不再额外延迟。
    """
    if x.ndim == 1:
        x = np.repeat(x[:, None], 2, axis=1)
    n = len(x)
    wet = signal.fftconvolve(x, ir, mode="full", axes=0)[:n]
    if pre_delay_samples:
        wet = np.concatenate([np.zeros((pre_delay_samples, wet.shape[1])), wet],
                             axis=0)[:n]
    return (1.0 - mix) * x + mix * wet


def tail_energy(ir: np.ndarray, fs: int, ms: float = 50.0) -> float:
    """IR 最后 ms 毫秒的能量占比 —— 检查 IR 是否被硬切（应接近 0）。"""
    k = max(1, int(ms * fs / 1000.0))
    total = float(np.sum(ir ** 2)) + 1e-20
    return float(np.sum(ir[-k:] ** 2) / total)
