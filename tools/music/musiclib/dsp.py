# -*- coding: utf-8 -*-
"""基础 DSP 原语 —— 滤波器、包络、动态、饱和、立体声处理。

都是"混音台上一颗旋钮"级别的操作，全部作用于 (n,) 或 (n, 2) 的 float32/64
数组。刻意不引第三方音频库：管线要能在只有 numpy/scipy 的机器上跑通。
"""
from __future__ import annotations

import numpy as np
from scipy import signal


def to_2d(x: np.ndarray) -> np.ndarray:
    return x if x.ndim == 2 else x[:, None]


def to_mono(x: np.ndarray) -> np.ndarray:
    return x if x.ndim == 1 else x.mean(axis=1)


# ─────────────────────────────── 滤波 ────────────────────────────────

def _sos(kind: str, fs: int, freq: float, q: float = 0.707, gain_db: float = 0.0):
    if kind == "lowpass":
        return signal.butter(2, freq / (fs / 2), btype="low", output="sos")
    if kind == "highpass":
        return signal.butter(2, freq / (fs / 2), btype="high", output="sos")
    if kind == "lowshelf":
        return signal.butter(2, freq / (fs / 2), btype="low", output="sos"), gain_db
    if kind == "highshelf":
        return signal.butter(2, freq / (fs / 2), btype="high", output="sos"), gain_db
    raise ValueError(kind)


def highpass(x: np.ndarray, fs: int, freq: float, order: int = 2) -> np.ndarray:
    sos = signal.butter(order, freq / (fs / 2), btype="high", output="sos")
    return signal.sosfilt(sos, x, axis=0)


def lowpass(x: np.ndarray, fs: int, freq: float, order: int = 2) -> np.ndarray:
    sos = signal.butter(order, freq / (fs / 2), btype="low", output="sos")
    return signal.sosfilt(sos, x, axis=0)


def shelf(x: np.ndarray, fs: int, freq: float, gain_db: float,
          kind: str = "high", slope: float = 0.7) -> np.ndarray:
    """搁架 EQ。kind='high' 控制高频（负增益=收敛亮度，本项目防刺耳的主力），
    kind='low' 控制低频（正增益=加温暖）。"""
    if abs(gain_db) < 1e-6:
        return x
    A = 10.0 ** (gain_db / 40.0)
    w0 = 2.0 * np.pi * freq / fs
    alpha = np.sin(w0) / 2.0 * np.sqrt((A + 1 / A) * (1 / slope - 1) + 2)
    cosw = np.cos(w0)
    if kind == "high":
        b = np.array([A * ((A + 1) + (A - 1) * cosw + 2 * np.sqrt(A) * alpha),
                      -2 * A * ((A - 1) + (A + 1) * cosw),
                      A * ((A + 1) + (A - 1) * cosw - 2 * np.sqrt(A) * alpha)])
        a = np.array([(A + 1) - (A - 1) * cosw + 2 * np.sqrt(A) * alpha,
                      2 * ((A - 1) - (A + 1) * cosw),
                      (A + 1) - (A - 1) * cosw - 2 * np.sqrt(A) * alpha])
    else:
        b = np.array([A * ((A + 1) - (A - 1) * cosw + 2 * np.sqrt(A) * alpha),
                      2 * A * ((A - 1) - (A + 1) * cosw),
                      A * ((A + 1) - (A - 1) * cosw - 2 * np.sqrt(A) * alpha)])
        a = np.array([(A + 1) + (A - 1) * cosw + 2 * np.sqrt(A) * alpha,
                      -2 * ((A - 1) + (A + 1) * cosw),
                      (A + 1) + (A - 1) * cosw - 2 * np.sqrt(A) * alpha])
    b, a = b / a[0], a / a[0]
    return signal.lfilter(b, a, x, axis=0)


def peak(x: np.ndarray, fs: int, freq: float, gain_db: float,
         q: float = 1.0) -> np.ndarray:
    """峰值 EQ（陷波/微凸），用于处理具体的共鸣点。"""
    if abs(gain_db) < 1e-6:
        return x
    A = 10.0 ** (gain_db / 40.0)
    w0 = 2.0 * np.pi * freq / fs
    alpha = np.sin(w0) / (2 * q)
    cosw = np.cos(w0)
    b = np.array([1 + alpha * A, -2 * cosw, 1 - alpha * A])
    a = np.array([1 + alpha / A, -2 * cosw, 1 - alpha / A])
    return signal.lfilter(b / a[0], a / a[0], x, axis=0)


def tilt(x: np.ndarray, fs: int, lo_db: float, hi_db: float,
         pivot: float = 900.0) -> np.ndarray:
    """倾斜 EQ：pivot 以下按 lo_db、以上按 hi_db 平滑过渡（一次塑形整体明暗）。"""
    y = shelf(x, fs, pivot * 0.5, lo_db, kind="low")
    y = shelf(y, fs, pivot * 2.0, hi_db, kind="high")
    return y


# ─────────────────────────────── 动态 ────────────────────────────────

def _envelope(rect: np.ndarray, fs: int, attack_ms: float,
              release_ms: float, hold_hz: float = 50.0) -> np.ndarray:
    """峰值包络：**快起慢落**，全程向量化。

    三步：
      1. **峰值保持**：最大值滤波，窗口不小于 `1/hold_hz` 秒（默认 20ms，
         对应 50Hz 的一个周期）。窗口若短于一个周期，滤波器会**严重低估**
         低频信号的幅度——实测 110Hz 正弦（实际幅度 3.0）在 2ms 窗口下
         只读到 1.88，限幅器因此漏限 3dB，直接冲上限。
      2. 快包络（attack 时间常数）与慢包络（release 时间常数）各做一次单极点平滑；
      3. 取两者较大值 —— 起音时快包络跟上（瞬时压住），回落时慢包络主导
         （平滑释放）。这就是经典的"快起慢落"跟随器，且完全向量化。

    单极点滤波的初值必须设成"当前峰值"。若从 0 起振，它要花约一到两个
    release 时长才爬到正确值，这段时间里压缩/限幅等于不存在——音频开头的
    第一个强音会原样冲出去（实测过冲到 +9.5dB）。
    """
    from scipy.ndimage import maximum_filter1d
    win = max(2, int(round(fs / max(hold_hz, 1.0))))
    peak = maximum_filter1d(rect, size=win, mode="nearest")
    z0 = [float(peak[0])]

    def _pole(ms: float) -> np.ndarray:
        a = float(np.exp(-1.0 / max(1.0, fs * max(ms, 0.05) / 1000.0)))
        return signal.lfilter([1.0 - a], [1.0, -a], peak, zi=z0)[0]

    return np.maximum(_pole(attack_ms), _pole(release_ms))


def _detector(x: np.ndarray) -> np.ndarray:
    """峰值检测信号：立体声取**声道最大值**，不是左右求和。

    这是一个容易踩、而且踩了不报错的坑：左右声道去相关之后（经过混响与 M/S
    展宽几乎必然如此），两声道之和的峰值可能远低于单个声道的峰值——限幅器
    于是"看不见"该压的峰，限幅形同虚设；峰值控制被甩给了链子后面的静态降增益，
    结果是**整个混音白白降下来 1~2dB**（实测钢琴独奏曲目就吃过这个亏，
    在真峰值上限前只能到 -16.8 LUFS 而非目标的 -15.0）。
    检测用声道最大值、增益同时施加到两个声道（联动限幅），既压得住又不破坏声像。
    """
    a = np.abs(x)
    return a if a.ndim == 1 else a.max(axis=1)


def compressor(x: np.ndarray, fs: int, threshold_db: float = -18.0,
               ratio: float = 2.0, attack_ms: float = 25.0,
               release_ms: float = 250.0, makeup_db: float = 0.0,
               soft_knee_db: float = 6.0) -> np.ndarray:
    """前馈压缩器（峰值检测 + 软拐点）。

    对 Pad/弦乐垫用很轻的档位（ratio 1.5~2）就够：目的是把长音的起伏压平一点，
    让它在钢琴下面当"床"，而不是真的去压缩动态。
    """
    env = _envelope(_detector(x), fs, attack_ms, release_ms)
    env_db = 20.0 * np.log10(env + 1e-12)
    over = env_db - threshold_db
    # 软拐点：拐点宽度内二次过渡，之外按比率压缩
    gain_db = np.zeros_like(over)
    knee_lo = -soft_knee_db / 2.0
    below = over <= knee_lo
    above = over >= soft_knee_db / 2.0
    knee = ~below & ~above
    gain_db[above] = -over[above] * (1.0 - 1.0 / ratio)
    if knee.any() and soft_knee_db > 0:
        d = over[knee] - knee_lo
        gain_db[knee] = -(1.0 - 1.0 / ratio) * (d ** 2) / (2.0 * soft_knee_db)
    gain = 10.0 ** ((gain_db + makeup_db) / 20.0)
    if x.ndim == 2:
        gain = gain[:, None]
    return x * gain.astype(x.dtype)


def soft_clip(x: np.ndarray, drive: float = 1.0, mix: float = 1.0) -> np.ndarray:
    """tanh 软饱和：给总线一点"胶"和密度，同时天然限幅。
    drive=1 & mix 小时几乎只有染色没有失真。"""
    y = np.tanh(x * drive) / np.tanh(drive)
    return (1.0 - mix) * x + mix * y


def limiter(x: np.ndarray, fs: int, ceiling_db: float = -1.0,
            release_ms: float = 120.0, return_gr: bool = False):
    """峰值限制器（前瞻 + 平滑释放）。母带最后一关，保证真峰值不越界。

    return_gr=True 时额外返回"最大增益衰减量"（dB，≤0）。这个数应该被报出来：
    提响度与保动态是一对矛盾，压了多少必须可见，否则"变响了"背后牺牲了什么
    就没人知道了。
    """
    ceil = 10.0 ** (ceiling_db / 20.0)
    env = _envelope(_detector(x), fs, 0.2, release_ms)
    gain = np.minimum(1.0, ceil / (env + 1e-12))
    gr_db = 20.0 * float(np.log10(float(np.min(gain)) + 1e-12)) if gain.size else 0.0
    g = gain[:, None] if x.ndim == 2 else gain
    y = x * g.astype(x.dtype)
    return (y, gr_db) if return_gr else y


def normalize_peak(x: np.ndarray, target_db: float = -1.0) -> np.ndarray:
    peak = float(np.max(np.abs(x))) if x.size else 0.0
    if peak <= 0:
        return x
    return x * (10.0 ** (target_db / 20.0) / peak)


def apply_gain_db(x: np.ndarray, db: float) -> np.ndarray:
    return x * (10.0 ** (db / 20.0))


# ───────────────────────── 立体声（M/S）─────────────────────────────

def mid_side(x: np.ndarray):
    m = x.mean(axis=1)
    s = (x[:, 0] - x[:, 1]) / 2.0
    return m, s


def from_mid_side(m: np.ndarray, s: np.ndarray) -> np.ndarray:
    return np.stack([m + s, m - s], axis=1)


def widen(x: np.ndarray, amount: float = 1.3, bass_mono_hz: float = 180.0,
          fs: int = 48000) -> np.ndarray:
    """M/S 展宽：只把侧信号放大，并把低频折回单声道。

    低频单声道化是让混音"不糊、不飘"的关键——耳机上宽，音箱/单声道上依然稳。

    实现要点：**直接对侧信号做高通**，而不是"低通整个信号再从原信号里减掉"。
    减法重建会因滤波器相位不匹配而残留大块低频侧信号（实测残留约 45%，
    等于没做单声道化，还把低频搞浑）；对侧信号单独高通则数学上干净：
    低频段只剩 mid，必然左右相同。高通取 6 阶，让交叉点以下的侧信号
    衰减到 -40dB 量级，避免"低频还带一点漂移"。
    """
    m, s = mid_side(x)
    if bass_mono_hz > 0:
        s = highpass(s, fs, bass_mono_hz, order=6)
    return from_mid_side(m, s * amount)


def pan_stereo(x: np.ndarray, pan: float) -> np.ndarray:
    """把单声道/立体声信号按 pan(-1..1) 摆位（等功率）。"""
    if x.ndim == 1:
        x = np.repeat(x[:, None], 2, axis=1)
    if abs(pan) < 1e-6:
        return x
    ang = (pan + 1.0) * np.pi / 4.0
    return np.stack([x[:, 0] * np.cos(ang) * np.sqrt(2) * 0.7071,
                     x[:, 1] * np.sin(ang) * np.sqrt(2) * 0.7071], axis=1)


# ─────────────────────────────── 其它 ────────────────────────────────

def fade(x: np.ndarray, fs: int, fade_in_s: float = 0.0,
         fade_out_s: float = 0.0, curve: str = "equal_power") -> np.ndarray:
    y = x.copy()
    n = len(y)
    if fade_in_s > 0:
        k = min(n, int(fade_in_s * fs))
        t = np.linspace(0, 1, k)
        g = np.sin(t * np.pi / 2) if curve == "equal_power" else t
        y[:k] *= g[:, None] if y.ndim == 2 else g
    if fade_out_s > 0:
        k = min(n, int(fade_out_s * fs))
        t = np.linspace(0, 1, k)
        g = np.cos(t * np.pi / 2) if curve == "equal_power" else 1 - t
        y[n - k:] *= g[:, None] if y.ndim == 2 else g
    return y


def db_to_lin(db: float) -> float:
    return float(10.0 ** (db / 20.0))


def lin_to_db(v: float) -> float:
    return float(20.0 * np.log10(max(v, 1e-12)))
