# -*- coding: utf-8 -*-
"""音效合成原语 —— 瞬态噪声 / 共振体 / 模态打击 / 拟音（声源-滤波）/ 金属与木质碰撞。

三条设计原则，都是本项目音频任务里实际踩出来的：

1. **全部向量化**。600 万样点的逐样点 Python 循环要跑几分钟；本模块最多只对
   "模态数 / 谐波数 / 共振峰数"（个位数到几十）做循环，样点轴一律走 numpy/FFT。
2. **噪声先归一化到固定 RMS 再当素材用**。若按峰值归一，不同 seed、不同长度的
   噪声层实际能量会差 3dB 以上，"这一层给 -12dB" 的参数就失去意义，响度设计
   不再可复现。归一 RMS 之后同参数 = 同结果（这是 `gen_sfx.py` 幂等的基础）。
3. **带限信号统一"两端补零再滤波"**。`butter + sosfilt` 的零初值会让开头/结尾
   出现一段软塌；在 30~90ms 的音效里，这段软塌就是听得到的"起音钝化 / 尾巴拖影"。

命名约定：所有 `dur` 参数单位秒，所有频率单位 Hz，返回 `(n,)` float64 单声道。
要立体声由 `post.stereoize()` 统一处理（**不在原语里各写一套**）。
"""
from __future__ import annotations

import math

import numpy as np
from scipy import signal

SR = 48000


# ─────────────────────────────── 时间轴 ────────────────────────────────

def t_axis(dur: float, fs: int = SR, start: float = 0.0) -> np.ndarray:
    return start + np.arange(max(1, int(round(dur * fs))), dtype=np.float64) / fs


def n_of(dur: float, fs: int = SR) -> int:
    return max(1, int(round(dur * fs)))


# ─────────────────────────────── 噪声源 ────────────────────────────────

def noise(n: int, seed: int = 0, color: str = "white") -> np.ndarray:
    """噪声源，已归一化到 **RMS=1**（见模块头 §2）。

    color: white / pink(-3dB/oct 功率) / brown(-6dB/oct 功率)
    """
    rng = np.random.default_rng(int(seed) & 0x7FFFFFFF)
    x = rng.standard_normal(max(2, int(n)))
    if color == "white":
        pass
    elif color in ("pink", "brown"):
        X = np.fft.rfft(x)
        f = np.fft.rfftfreq(len(x), 1.0)
        f[0] = f[1] if len(f) > 1 else 1.0
        # pink: 幅度 ∝ 1/sqrt(f)；brown: 幅度 ∝ 1/f
        X = X * (1.0 / np.sqrt(f) if color == "pink" else 1.0 / f)
        x = np.fft.irfft(X, len(x))
    else:
        raise ValueError("未知噪声色: %s" % color)
    return rms_norm(x, 1.0)


def rms_norm(x: np.ndarray, target: float = 1.0) -> np.ndarray:
    r = float(np.sqrt(np.mean(np.asarray(x, dtype=np.float64) ** 2)))
    if r <= 1e-12:
        return np.asarray(x, dtype=np.float64)
    return np.asarray(x, dtype=np.float64) * (target / r)


def tilt_spectrum(x: np.ndarray, fs: int, db_per_oct: float,
                  ref_hz: float = 1000.0, clip_db: float = 24.0) -> np.ndarray:
    """按倍频程倾斜噪声频谱（正=变亮）。

    必须先于 `band_limit` 调用：倾斜会在低频堆未定义的能量（20Hz 处可能 +17dB），
    顺序反过来等于往带外灌垃圾。`clip_db` 限制极端频点的增益，避免数值爆掉。
    """
    if abs(db_per_oct) < 1e-9:
        return x
    n = len(x)
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(n, 1.0 / fs)
    f = np.maximum(f, 10.0)
    g_db = np.clip(db_per_oct * np.log2(f / ref_hz), -clip_db, clip_db)
    return np.fft.irfft(X * (10.0 ** (g_db / 20.0)), n)


def band_limit(x: np.ndarray, fs: int, lo: float | None = None,
               hi: float | None = None, order: int = 2,
               pad_ms: float = 8.0) -> np.ndarray:
    """带限（补零滤波，见模块头 §3）。lo/hi 可只给一个。"""
    n = len(x)
    nyq = fs / 2.0
    hi_e = min(hi, nyq * 0.99) if hi else None
    lo_e = max(lo, 1.0) if lo else None
    if lo_e is not None and hi_e is not None:
        if hi_e <= lo_e * 1.02:
            hi_e = min(nyq * 0.99, lo_e * 1.05)
        sos = signal.butter(order, [lo_e / nyq, hi_e / nyq], btype="band",
                            output="sos")
    elif lo_e is not None:
        sos = signal.butter(order, lo_e / nyq, btype="high", output="sos")
    elif hi_e is not None:
        sos = signal.butter(order, hi_e / nyq, btype="low", output="sos")
    else:
        return x
    pad = int(min(max(4, pad_ms * fs / 1000.0), max(4, n // 2)))
    y = np.concatenate([np.zeros(pad), x, np.zeros(pad)])
    return signal.sosfilt(sos, y)[pad:pad + n]


def band_noise(dur: float, fs: int = SR, seed: int = 0, lo: float | None = None,
               hi: float | None = None, order: int = 2, color: str = "white",
               tilt_db_per_oct: float = 0.0, rms: float = 1.0) -> np.ndarray:
    """带限噪声床（未加包络）。顺序：噪声 → 频谱倾斜 → 带限 → RMS 归一。"""
    n = n_of(dur, fs)
    x = noise(n, seed, color)
    x = tilt_spectrum(x, fs, tilt_db_per_oct)
    x = band_limit(x, fs, lo, hi, order=order)
    return rms_norm(x, rms)


# ─────────────────────────────── 包络 ────────────────────────────────

def decay_env(n: int, fs: int, tau: float, curve: str = "exp") -> np.ndarray:
    """衰减包络（峰值 1）。

    ⚠ **两条曲线的"到 -60dB 所需时间"差 4.4 倍**，设计时长时别搞混：

        curve='exp'   → `exp(-t/τ)`：-60dB 出现在 **t = 6.908·τ**
        curve='power' → `(1+t/τ)⁻²`：-60dB 出现在 **t = 30.62·τ**

    （'power' 早期衰减快、尾部拖得长，听感是"尾巴更实"。但正因为它拖了 30 个
    τ，用它设计时长时 τ 要给得比直觉小得多——本管线**统一用 'exp'**，
    时长与 τ 的换算才有单一规则，见 `design.tau_for()`。）
    """
    t = np.arange(n, dtype=np.float64) / fs
    tau = max(float(tau), 1e-6)
    if curve == "exp":
        return np.exp(-t / tau)
    if curve == "power":
        return (1.0 + t / tau) ** -2.0
    raise ValueError("未知衰减曲线: %s" % curve)


def perc_env(n: int, fs: int, attack: float, tau: float,
             curve: str = "exp", hold: float = 0.0) -> np.ndarray:
    """打击型包络：平滑起振（smoothstep）+ 衰减，可选 `hold` 秒的保持段。

    `hold > 0` 时是"起振 → 保持 hold 秒 → 再从 hold 处开始衰减"，用于号角/
    持续段的声音。**衰减必须从 hold 处起算**：早期版本让衰减从 t=0 起算，
    结果 hold 段已经在衰减，"保持 0.42 秒的号角"实际 0.42 秒时已经掉了
    36dB（实测 `battle_started` 因此短了 30%）。

    起振用 smoothstep 而不是线性斜坡：线性斜坡在拐点处一阶导突变成"咔"，
    短音效里这个"咔"会和音效本身的瞬态混在一起，听起来像削波。
    """
    t = np.arange(n, dtype=np.float64) / fs
    a = max(float(attack), 1e-6)
    r = np.clip(t / a, 0.0, 1.0)
    onset = r * r * (3.0 - 2.0 * r)
    t_rel = np.maximum(t - max(float(hold), 0.0), 0.0)
    tau = max(float(tau), 1e-6)
    if curve == "exp":
        tail = np.exp(-t_rel / tau)
    elif curve == "power":
        tail = (1.0 + t_rel / tau) ** -2.0
    else:
        raise ValueError("未知衰减曲线: %s" % curve)
    return onset * tail


# ─────────────────────── 瞬态 / 敲击 / 共振体 ──────────────────────────

def tick(dur: float, fs: int = SR, seed: int = 0, lo: float | None = 1800.0,
         hi: float | None = 9000.0, tau: float = 0.008, attack: float = 0.0006,
         color: str = "white", order: int = 2, rms: float = 1.0,
         tilt_db_per_oct: float = 0.0) -> np.ndarray:
    """瞬态"啪"：一段带限噪声 + 极短包络。所有敲击类音效的"接触点"成分。"""
    n = n_of(dur, fs)
    x = band_noise(dur, fs, seed, lo, hi, order, color, tilt_db_per_oct, rms)
    return x * perc_env(n, fs, attack, tau)


def modal(freqs, taus, amps, dur: float, fs: int = SR, seed: int = 0,
          random_phase: bool = True) -> np.ndarray:
    """模态打击：一组**各自指数衰减**的正弦分音之和。

    这是"物体被敲响"的物理模型（DSP 里叫 modal synthesis）：每个模态 = 一个
    频率 + 一个衰减时间常数。非谐分音比例（freqs 不是整数倍）就是"这是石头/
    玻璃/木头/金属"的听感来源——整数倍 = 有音高（木琴/铃），非整数倍 = 无音高
    的噪声性音色（石头/陶器）。

    循环只跑"模态数"（4~8 个），样点轴向量化。
    """
    n = n_of(dur, fs)
    t = np.arange(n, dtype=np.float64) / fs
    rng = np.random.default_rng(int(seed) & 0x7FFFFFFF)
    out = np.zeros(n)
    for f, tau, a in zip(np.atleast_1d(freqs), np.atleast_1d(taus),
                         np.atleast_1d(amps)):
        ph = rng.uniform(0.0, 2.0 * np.pi) if random_phase else 0.0
        out += float(a) * np.sin(2.0 * np.pi * float(f) * t + ph) \
            * np.exp(-t / max(float(tau), 1e-6))
    return out


def reso_bank(x: np.ndarray, fs: int, freqs, qs, gains_db=None) -> np.ndarray:
    """共振体：把激励信号 `x` 送进一组并联的 2 极点谐振器（滤波法建模）。

    与 `modal()` 的区别：`modal` 自己产生声音（正弦之和），`reso_bank` 是
    **给已有信号染色**（例如把噪声送进箱体得到"中空"的木头声、把脉冲串送进
    三个共振峰得到"啊/呃"的口型）。Q 越大越"窄、越有音高"。
    """
    y = np.zeros(len(x), dtype=np.float64)
    freqs = np.atleast_1d(freqs)
    qs = np.atleast_1d(qs)
    gains = np.ones(len(freqs)) if gains_db is None else 10.0 ** (np.atleast_1d(gains_db) / 20.0)
    nyq = fs / 2.0
    for i in range(len(freqs)):
        w0 = min(max(float(freqs[i]), 20.0), nyq * 0.97) / nyq
        b, a = signal.iirpeak(w0, max(float(qs[i]), 0.2))
        y += float(gains[i]) * signal.lfilter(b, a, x)
    return y


def thud(f0_start: float, f0_end: float, dur: float, fs: int = SR,
         tau: float = 0.10, tau_low: float | None = None,
         body: float = 0.35, seed: int = 0, curve: str = "exp") -> np.ndarray:
    """低频"闷响"：一条**下滑**正弦（膜/箱体的音高随撞击下坠）+ 低频噪声体。

    下滑是"鼓被敲"的物理特征（张力瞬时释放导致基频下降）。纯静态正弦听起来
    像"电子音库里的 kick"，下滑才有"实物被打到"的重量感。
    """
    n = n_of(dur, fs)
    t = np.arange(n, dtype=np.float64) / fs
    k = max(1e-6, float(tau_low if tau_low is not None else tau * 1.6))
    # 音高下滑用采样点线性插值（向量化），不用逐点循环
    f_t = f0_start * (f0_end / f0_start) ** np.clip(t / k, 0.0, 1.0)
    phase = 2.0 * np.pi * np.cumsum(f_t) / fs
    tone = np.sin(phase) * decay_env(n, fs, tau, curve)
    if body > 0:
        nb = band_noise(dur, fs, seed, None, 220.0, order=2, color="brown")
        nb = nb * perc_env(n, fs, 0.0015, tau * 0.7, "exp")
        tone = tone + body * nb
    return tone


# ─────────────────────────── 有音高打击/吹奏 ───────────────────────────

def fm_bell(f0: float, dur: float, fs: int = SR, ratio: float = 3.5,
            index: float = 2.0, tau: float = 0.35, tau_mod: float = 0.12,
            attack: float = 0.002, seed: int = 0) -> np.ndarray:
    """两算子 FM 铃（Chowning 的经典钟/铃模型）。

    为什么不用"正弦 + 少量谐波"：铃的判别特征是**非谐分音**。FM 的调制指数随
    调制包络衰减，分音随之从"密集噪声性"收拢到基频，这正是"叮——"的过程。
    正弦堆做不到这个时间演变，听起来永远是"电子合成器"。

    ratio=3.5 给出非谐的钟分音堆；ratio=1.0 + 小 index 退化成"柔和的木琴"。
    """
    n = n_of(dur, fs)
    t = np.arange(n, dtype=np.float64) / fs
    mod = float(index) * np.exp(-t / max(tau_mod, 1e-6)) * np.sin(2.0 * np.pi * f0 * ratio * t)
    y = np.sin(2.0 * np.pi * f0 * t + mod) * np.exp(-t / max(tau, 1e-6))
    a = np.clip(t / max(attack, 1e-6), 0.0, 1.0)
    return y * (a * a * (3.0 - 2.0 * a))


def harmonic_hit(f0: float, dur: float, fs: int = SR, n_harm: int = 12,
                 tau: float = 0.25, hf_damp: float = 0.45, attack: float = 0.001,
                 odd_only: bool = False, rolloff: float = 1.0,
                 seed: int = 0) -> np.ndarray:
    """谐波打击（木琴/马林巴/木板/低音鼓的"有音高撞击"）。

    hf_damp 控制"高次分音衰减更快"的程度：真实木体的高次模态被内部损耗吸收得
    更快，缺了这条会得到"所有分音一起停"的合成器感。

    向量化实现：谐波轴 × 时间轴 的矩阵一次算出（n_harm ≤ 24）。
    """
    n = n_of(dur, fs)
    t = np.arange(n, dtype=np.float64) / fs
    ks = np.arange(1, n_harm + 1, dtype=np.float64)
    if odd_only:
        ks = ks[ks % 2 == 1]
    amps = 1.0 / ks ** rolloff
    taus = float(tau) * hf_damp ** (ks - 1.0)
    env = np.exp(-t[None, :] / np.maximum(taus[:, None], 1e-6))     # (K, n)
    y = (amps[:, None] * env * np.sin(2.0 * np.pi * f0 * ks[:, None] * t[None, :])).sum(axis=0)
    a = np.clip(t / max(attack, 1e-6), 0.0, 1.0)
    return y * (a * a * (3.0 - 2.0 * a))


def saw_voice(f0: float, dur: float, fs: int = SR, n_harm: int = 26,
              voices: int = 3, detune_cents: float = 7.0,
              bright0: float = 1100.0, bright_peak: float = 3400.0,
              attack: float = 0.035, hold: float = 0.45, tau: float = 0.9,
              vib_hz: float = 5.4, vib_cents: float = 7.0,
              seed: int = 0) -> np.ndarray:
    """铜管/号角式音色（**时间变化的加性合成**）。

    铜管的判别特征有三条，缺一条就不像：
      1. **慢起振**（气息建立要 30~60ms，不是 5ms）；
      2. **亮度随时间"暗→亮→暗"**（吹响→全力→收气）。这里用一条随时间变化的
         谐波包络实现：`A_k(t) = 1/k * exp(-k*f0/bright(t))`，bright(t) 是
         时间变化的"截止频率"，从 bright0 升到 bright_peak 再落回；
      3. **轻微颤音 + 多声部失谐**（一支号是一把锯波，三支号会互相干涉）。

    这三条都写在时间轴上，所以不能用"锯齿波 + 静态低通"糊出来。
    """
    n = n_of(dur, fs)
    t = np.arange(n, dtype=np.float64) / fs
    rng = np.random.default_rng(int(seed) & 0x7FFFFFFF)
    # 亮度包络：0 → peak（在 hold 处）→ 回落
    peak = max(0.05, float(hold))
    rise = np.clip(t / max(peak, 1e-6), 0.0, 1.0)
    fall = np.clip((t - peak) / max(tau, 1e-6), 0.0, 1.0)
    bright = bright0 * (bright_peak / bright0) ** rise * (0.55) ** fall
    # ⚠ hold 必须传给 perc_env：漏传的话"号角"会从 t=0 就开始衰减，
    # 一个设计 1.2 秒的宣告会变成 0.7 秒的短促音（实测踩过）。
    env = perc_env(n, fs, attack, tau, curve="exp", hold=hold)
    # 颤音：音高与亮度都跟着抖（真实铜管的颤音是"气息"层面的）
    vib = vib_cents / 1200.0 * np.sin(2.0 * np.pi * vib_hz * t + rng.uniform(0, 6.28))
    y = np.zeros(n)
    for v in range(max(1, int(voices))):
        det = (rng.uniform(-1.0, 1.0) * detune_cents + v * detune_cents * 0.5) / 1200.0
        f = f0 * (2.0 ** (det + vib))
        # 每个声部给**随机的初始相位**。若都从 0 起振，几个失谐声部会在起音处
        # 完全同相，随后相位漂开——听感是"起音很厚、然后掉 4dB 变薄"（实测：
        # 保持段从 1.04 掉到 0.59）。真实的三支号不会同相起振，随机初相才对。
        ph0 = rng.uniform(0.0, 2.0 * np.pi)
        phase = 2.0 * np.pi * np.cumsum(f) / fs + ph0
        ks = np.arange(1, n_harm + 1, dtype=np.float64)
        amp = (1.0 / ks)[:, None] * np.exp(-ks[:, None] * f0 / np.maximum(bright, 60.0)[None, :])
        y += (amp * np.sin(ks[:, None] * phase[None, :])).sum(axis=0)
    return y / max(1, int(voices)) * env


def formant_gain(f: np.ndarray, F: float, BW: float, fs: int) -> np.ndarray:
    """2 极点谐振器的幅度响应（谐振点归一到 1）—— 声道的共振峰增益。

    **不能用高斯**：高斯的两侧衰减是指数的，f0=200Hz 时相邻谐波（相隔 200Hz）
    很容易整片落在共振峰之间的"零点"上，连基频都被压到 -60dB 以下，合成结果
    听起来像"被滤波的噪声"而不是人声（实测踩过：设 f0=200Hz，测出来主频
    367Hz，基频根本不存在）。真实声道的传递函数是 2 极点谐振器，低频侧只按
    ~6dB/oct 滚降，所以基频始终在。

    数字 2 极点：H(z)=1/(1-2r·cos(w0)z⁻¹+r²z⁻²)，取 |H(w)| 并在 w0 处归一。
    """
    r = math.exp(-math.pi * max(float(BW), 10.0) / fs)
    w = 2.0 * math.pi * np.asarray(f, dtype=np.float64) / fs
    w0 = 2.0 * math.pi * float(F) / fs
    d = np.sqrt(1.0 + r * r - 2.0 * r * np.cos(w - w0))
    d0 = math.sqrt(max(1.0 + r * r - 2.0 * r, 1e-18))
    return d0 / np.maximum(d, 1e-9)


def phonation(dur: float, fs: int = SR, seed: int = 0, f0: float = 200.0,
              f0_end: float = 140.0, formants=((700.0, 90.0), (1150.0, 130.0),
                                               (2600.0, 200.0)),
              breath: float = 0.35, attack: float = 0.02, tau: float = 0.16,
              n_harm: int = 26, glide: float = 0.35) -> np.ndarray:
    """拟音：短促的人声闷哼（**声源-滤波**合成，不用任何真人采样）。

    做法：
      1. **声源**：声带脉冲列，用谐波堆近似（`sin(k·φ(t))`，k 到 4kHz）；
         基频从 f0 滑到 f0_end——受击时喉部收紧、音高下坠，这是"疼"的物理线索。
         源频谱给一条 `k^-0.6` 的温和滚降（声门脉冲本身自带 -6~-12dB/oct），
         保证基频与低次谐波有足够能量。
      2. **滤波**：每个谐波的幅度由**共振峰谐振增益**加权
         `A_k(t) = source(k) · Π_i formant_gain(k·f0(t), F_i, BW_i)`，
         F1/F2/F3 的取值决定听到的是"啊 / 呃 / 哼"（见 `formant_gain` 的注释：
         这里必须用谐振器响应，用高斯会把基频压没）。
      3. **气声**：一层带共振峰染色的噪声，跟随同一包络——纯谐波堆听起来像
         电子琴，气声才让它像"人"。

    全程向量化（谐波轴 ≤26 × 时间轴）。滑音用指数插值（听感上是线性音程），
    不用指数就会让人声"滑得太快"。
    """
    n = n_of(dur, fs)
    t = np.arange(n, dtype=np.float64) / fs
    g = np.clip(t / max(dur * glide + 1e-9, 1e-6), 0.0, 1.0)
    f_curve = f0 * (f0_end / f0) ** g
    phase = 2.0 * np.pi * np.cumsum(f_curve) / fs
    ks = np.arange(1, max(2, int(n_harm)) + 1, dtype=np.float64)
    hf = ks[:, None] * f_curve[None, :]                       # (K, n) 每个谐波的瞬时频率
    amp = ks[:, None] ** -0.6
    for (F, BW) in formants:
        amp = amp * formant_gain(hf, float(F), float(BW), fs)
    voice = (amp * np.sin(ks[:, None] * phase[None, :])).sum(axis=0)
    voice = voice / (np.max(np.abs(voice)) + 1e-12)
    env = perc_env(n, fs, attack, tau, curve="exp")
    out = voice * env
    if breath > 0:
        nb = band_noise(dur, fs, seed + 7, 120.0, 4500.0, order=2, color="pink")
        nb = reso_bank(nb, fs, [f[0] for f in formants],
                       [max(2.0, f[0] / max(f[1], 40.0)) for f in formants],
                       [0.0, -6.0, -12.0][:len(formants)])
        out = out + breath * rms_norm(nb, 1.0) * env * 0.6
    return out


def glide_tone(f0: float, f1: float, dur: float, fs: int = SR, tau: float = 0.05,
               glide: float = 0.25, partials=((1.0, 1.0, 1.0),),
               attack: float = 0.0015, curve: str = "exp") -> np.ndarray:
    """带**音高滑动**的分音组（一根音的起音可以"被压下去"）。

    `partials = (倍频, 振幅, 衰减倍率)`：UI 点击用 1.0 + 1.5（纯五度上方）两分音，
    金属用 1.0 + 1.5 + 2.98（非谐第三分音）——后者是"金属味"的来源。

    音高下滑是"物理按键被压下 / 张力瞬时释放"的听感线索；纯静态正弦的点击
    听起来像音源库里的 beep。下滑用采样点线性插值（cumsum 相位），向量化。
    """
    n = n_of(dur, fs)
    t = np.arange(n, dtype=np.float64) / fs
    g = np.clip(t / max(dur * glide, 1e-9), 0.0, 1.0)
    f_curve = f0 * (f1 / f0) ** g
    phase = 2.0 * np.pi * np.cumsum(f_curve) / fs
    out = np.zeros(n)
    for mult, amp, tmult in partials:
        out += float(amp) * np.sin(float(mult) * phase) \
            * decay_env(n, fs, max(float(tau) * float(tmult), 1e-6), curve)
    a = np.clip(t / max(attack, 1e-6), 0.0, 1.0)
    return out * (a * a * (3.0 - 2.0 * a))


def sweep_band_noise(dur: float, fs: int = SR, seed: int = 0,
                     f_from: float = 1600.0, f_mid: float = 320.0,
                     f_to: float = 900.0, bend: float = 0.45,
                     bands: int = 9, bw_oct: float = 0.75,
                     f_min: float = 120.0, f_max: float = 12000.0,
                     attack: float = 0.03, tau: float | None = None,
                     rms: float = 1.0) -> np.ndarray:
    """挥击"咻"（whoosh）——**中心频率随时间移动**的带通噪声。

    为什么不用"噪声 + 低通包络"：那只能让亮度整体明暗变化，听不出"空气被划开"
    的移动感。真实的挥击是**一条窄带从高到低再抬起来**（先排开空气、再回填）。

    实现：因为 `lfilter` 不能时变系数，这里用**滤波器组交叉淡化**——把噪声切成
    `bands` 条对数等距的带通支路，每条支路乘一条"当前中心频率落在它附近"的
    时间增益，再求和。全流程向量化（循环只跑 band 数 ≤ 9）。
    """
    n = n_of(dur, fs)
    t = np.arange(n, dtype=np.float64) / fs
    rng = np.random.default_rng(int(seed) & 0x7FFFFFFF)
    if tau is None:
        tau = dur * 0.42
    # 中心频率轨迹：起点 →（bend 处）中间点 → 终点，对数域插值
    tb = max(1e-6, float(bend))
    p1 = np.clip(t / tb, 0.0, 1.0)
    p2 = np.clip((t - tb) / max(dur - tb, 1e-6), 0.0, 1.0)
    fc = f_from * (f_mid / f_from) ** p1 * (f_to / f_mid) ** p2
    fc = np.maximum(fc, 40.0)
    centers = np.geomspace(max(f_min, 60.0), min(f_max, fs / 2 * 0.95), bands)
    out = np.zeros(n)
    for c in centers:
        # 每条支路用固定中心频率的带通，白噪按 seed 派生 → 各支路去相关
        x = band_limit(noise(n, int(seed) + int(c) % 9973, "white"), fs,
                       c / 1.6, min(c * 1.6, fs / 2 * 0.98), order=2)
        w = np.exp(-((np.log2(c) - np.log2(fc)) / max(bw_oct, 0.1)) ** 2)
        out += x * w
    out = out * perc_env(n, fs, attack, tau, curve="exp")
    return rms_norm(out, max(float(rms), 1e-9))


# ─────────────────────────────── 组合工具 ──────────────────────────────
def place(buf: np.ndarray, part: np.ndarray, at_s: float, fs: int = SR,
          gain: float = 1.0) -> np.ndarray:
    """把 `part` 加到 `buf` 的 at_s 位置（超出部分截断）。用于"多段先后"的音效。"""
    i = int(round(at_s * fs))
    if i >= len(buf) or i + len(part) <= 0:
        return buf
    a = max(0, i)
    b = min(len(buf), i + len(part))
    buf[a:b] += gain * part[a - i:b - i]
    return buf


def buffer(dur: float, fs: int = SR) -> np.ndarray:
    return np.zeros(n_of(dur, fs), dtype=np.float64)


def fade_edges(x: np.ndarray, fs: int = SR, in_ms: float = 1.5,
               out_ms: float = 4.0) -> np.ndarray:
    """两端淡入淡出（防"咔"）。给每一件交付件收尾用。"""
    y = np.asarray(x, dtype=np.float64).copy()
    n = len(y)
    ki = min(n, int(in_ms * fs / 1000.0))
    ko = min(n, int(out_ms * fs / 1000.0))
    if ki > 1:
        y[:ki] *= np.sin(np.linspace(0, np.pi / 2, ki)) ** 2
    if ko > 1:
        y[n - ko:] *= np.cos(np.linspace(0, np.pi / 2, ko)) ** 2
    return y


def env_follow(x: np.ndarray, fs: int, ms: float = 5.0) -> np.ndarray:
    """包络跟随（快起慢落），可用于给噪声层加"跟随主体的动态"。"""
    from scipy.ndimage import maximum_filter1d
    a = np.abs(x)
    win = max(2, int(ms * fs / 1000.0))
    pk = maximum_filter1d(a, size=win, mode="nearest")
    z0 = [float(pk[0])]
    ac = float(np.exp(-1.0 / max(1.0, fs * ms / 1000.0)))
    return signal.lfilter([1.0 - ac], [1.0, -ac], pk, zi=z0)[0]
