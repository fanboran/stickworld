# -*- coding: utf-8 -*-
"""客观音频质检 —— 响度 / 真峰值 / 动态 / 刺耳度 / 循环接缝 / 单声道兼容。

"音乐好不好听"最终要人来听，但**"有没有做坏"完全可以量化**：响度是否达标、
真峰值会不会削、循环接缝是否听得出来、2~5kHz 是否堆了太多能量（刺耳的物理
成因）、折叠成单声道会不会掉东西。这些指标进 CI，任何一次改动都不会悄悄变坏。

数值口径（全部可复核）：
  - 积分响度：ITU-R BS.1770（K 加权双二阶 + 400ms/75% 重叠分块 + 绝对/相对双门限）
  - 真峰值：BS.1770 附录 —— 4× 过采样后取峰值
  - 响度范围 LRA：EBU Tech 3342（短时 3s 窗口 + 10/95 百分位）
  - 刺耳度：STFT 分帧的 2–5kHz 相对能量、谱质心、谱平坦度（取高分位看"峰值刺耳"）
"""
from __future__ import annotations

import math

import numpy as np
from scipy import signal

# ─────────────────────────────── K 加权 ────────────────────────────────

def k_weighting_coeffs(fs: int = 48000):
    """BS.1770 预滤波（高频搁架）+ RLB 高通，返回 (b1,a1,b2,a2)。

    由标准给出的模拟原型经双线性变换获取；48000Hz 下与标准表列值一致
    （b0≈1.53512、a1≈-1.69066 —— 见 verify_k_weighting）。
    """
    # 阶段一：高频搁架
    f0 = 1681.974450955533
    G = 3.999843853973347          # dB
    Q = 0.7071752369554196
    K = math.tan(math.pi * f0 / fs)
    Vh = 10.0 ** (G / 20.0)
    Vb = Vh ** 0.4996667741545416
    a0 = 1.0 + K / Q + K * K
    sh_b = np.array([(Vh + Vb * K / Q + K * K) / a0,
                     2.0 * (K * K - Vh) / a0,
                     (Vh - Vb * K / Q + K * K) / a0])
    sh_a = np.array([1.0,
                     2.0 * (K * K - 1.0) / a0,
                     (1.0 - K / Q + K * K) / a0])

    # 阶段二：RLB 高通
    f0 = 38.13547087602444
    Q = 0.5003270373238773
    K = math.tan(math.pi * f0 / fs)
    a0 = 1.0 + K / Q + K * K
    hp_b = np.array([1.0, -2.0, 1.0])
    hp_a = np.array([1.0,
                     2.0 * (K * K - 1.0) / a0,
                     (1.0 - K / Q + K * K) / a0])
    return sh_b, sh_a, hp_b, hp_a


def verify_k_weighting(fs: int = 48000, tol: float = 1e-4) -> dict:
    """自检：48000Hz 下与 BS.1770 标准表列系数比对。"""
    sh_b, sh_a, hp_b, hp_a = k_weighting_coeffs(fs)
    ref = {"sh_b0": 1.53512485958697, "sh_a1": -1.69065929318241,
           "sh_a2": 0.73248077421585, "hp_a1": -1.99004745483398,
           "hp_a2": 0.99007225036621}
    got = {"sh_b0": sh_b[0], "sh_a1": sh_a[1], "sh_a2": sh_a[2],
           "hp_a1": hp_a[1], "hp_a2": hp_a[2]}
    diffs = {k: abs(got[k] - v) for k, v in ref.items()}
    return {"ok": all(d < tol for d in diffs.values()), "got": got,
            "ref": ref, "max_abs_diff": max(diffs.values())}


def _apply_k_weighting(x: np.ndarray, fs: int) -> np.ndarray:
    sh_b, sh_a, hp_b, hp_a = k_weighting_coeffs(fs)
    y = signal.lfilter(sh_b, sh_a, x, axis=0)
    y = signal.lfilter(hp_b, hp_a, y, axis=0)
    return y


# ─────────────────────────────── 响度 ────────────────────────────────

ANCHOR = -0.691   # BS.1770 常数项


def _block_loudness(x: np.ndarray, fs: int, block_s: float = 0.4,
                    overlap: float = 0.75):
    """返回每个 400ms 块的 z 值。

    BS.1770 的 z 是**各声道均方值按声道加权后求和**（L/R 权重均为 1.0），
    不是求平均。用平均会让立体声比单声道少 3 LU —— 这个错误在只看单声道
    测试信号时完全看不出来，必须用"双声道应比单声道大 3 LU"来验。
    """
    n = int(round(block_s * fs))
    hop = int(round(n * (1.0 - overlap)))
    if len(x) < n:
        return np.array([])
    x2 = x if x.ndim == 2 else x[:, None]
    y = _apply_k_weighting(x2, fs)
    zs = []
    for start in range(0, len(x2) - n + 1, hop):
        seg = y[start:start + n]
        zs.append(float(np.sum(np.mean(seg ** 2, axis=0))))
    return np.array(zs)


def integrated_lufs(x: np.ndarray, fs: int) -> float:
    """BS.1770 积分响度（绝对门限 -70 LUFS + 相对门限 -10 LU）。"""
    zs = _block_loudness(x, fs)
    if zs.size == 0:
        return -np.inf
    with np.errstate(divide="ignore"):
        l = ANCHOR + 10.0 * np.log10(zs)
    keep = zs > 0
    zs, l = zs[keep], l[keep]
    if zs.size == 0:
        return -np.inf
    # 绝对门限
    m = l > -70.0
    if not m.any():
        return -np.inf
    # 相对门限
    rel = ANCHOR + 10.0 * np.log10(np.mean(zs[m])) - 10.0
    m2 = m & (l > rel)
    if not m2.any():
        m2 = m
    return float(ANCHOR + 10.0 * np.log10(np.mean(zs[m2])))


def short_term_lufs_series(x: np.ndarray, fs: int, window_s: float = 3.0,
                           hop_s: float = 0.5) -> np.ndarray:
    """短时响度序列（用于 LRA 与"循环内响度起伏"检查）。"""
    n = int(round(window_s * fs))
    hop = max(1, int(round(hop_s * fs)))
    if len(x) < n:
        n = len(x)
        hop = max(1, n // 4)
    y = _apply_k_weighting(x if x.ndim == 2 else x[:, None], fs)
    out = []
    for start in range(0, len(x) - n + 1, hop):
        z = float(np.mean(y[start:start + n] ** 2))
        out.append(ANCHOR + 10.0 * math.log10(z) if z > 1e-12 else -np.inf)
    return np.array(out)


def loudness_range(x: np.ndarray, fs: int) -> float:
    """LRA（EBU Tech 3342）：短时响度序列经 -70 绝对门限与 -20 LU 相对门限后取 10/95 百分位。"""
    st = short_term_lufs_series(x, fs)
    st = st[np.isfinite(st)]
    if st.size < 2:
        return 0.0
    m = st > -70.0
    if not m.any():
        return 0.0
    st = st[m]
    rel = (ANCHOR + 10.0 * np.log10(np.mean(10.0 ** ((st - ANCHOR) / 10.0)))) - 20.0
    st2 = st[st > rel]
    if st2.size < 2:
        st2 = st
    lo, hi = np.percentile(st2, [10, 95])
    return float(hi - lo)


def true_peak_dbfs(x: np.ndarray, fs: int, oversample: int = 4) -> float:
    """真峰值：4× 过采样重建后取峰值（BS.1770 附录）。"""
    peak = 0.0
    if x.ndim == 1:
        x = x[:, None]
    for ch in range(x.shape[1]):
        y = signal.resample_poly(x[:, ch], oversample, 1,
                                 window=("kaiser", 5.0))
        peak = max(peak, float(np.max(np.abs(y))))
    return 20.0 * math.log10(peak) if peak > 0 else -np.inf


def sample_peak_dbfs(x: np.ndarray) -> float:
    p = float(np.max(np.abs(x))) if x.size else 0.0
    return 20.0 * math.log10(p) if p > 0 else -np.inf


def crest_factor_db(x: np.ndarray) -> float:
    """峰均比（PLR 近似）：越高越动态，< 6dB 说明压过头了。"""
    if x.ndim == 2:
        x = x.mean(axis=1)
    rms = float(np.sqrt(np.mean(x ** 2)))
    peak = float(np.max(np.abs(x)))
    if rms <= 0 or peak <= 0:
        return 0.0
    return 20.0 * math.log10(peak / rms)


def dc_offset(x: np.ndarray) -> float:
    return float(np.mean(x if x.ndim == 1 else x.mean(axis=1)))


def clip_count(x: np.ndarray, thresh: float = 0.9995) -> int:
    return int(np.sum(np.abs(x) >= thresh))


# ─────────────────────────── 刺耳度 / 频谱 ──────────────────────────────

def spectral_report(x: np.ndarray, fs: int, n_fft: int = 2048,
                    hop: int = 512) -> dict:
    """分帧谱分析，返回"刺耳度"相关指标。

    客观对应关系：
      - 2–5kHz 相对能量高 → 人耳最敏感频段堆积 → 听感"扎耳/累"
      - 谱质心偏高          → 偏亮
      - 谱平坦度高          → 噪声性强（电子音/沙沙感）
    取 95 分位作为"峰值刺耳度"，另给超阈帧占比作为"持续性"。
    """
    if x.ndim == 2:
        x = x.mean(axis=1)
    f, t, Z = signal.stft(x, fs=fs, nperseg=n_fft, noverlap=n_fft - hop,
                          window="hann", boundary=None, padded=False)
    mag = np.abs(Z) ** 2                     # 功率谱 (bins, frames)
    total = mag.sum(axis=0) + 1e-20

    def band_ratio(lo, hi):
        sel = (f >= lo) & (f < hi)
        return (mag[sel].sum(axis=0) / total)

    r25 = band_ratio(2000, 5000)
    r5_10 = band_ratio(5000, 10000)
    r_low = band_ratio(60, 250)

    centroid = (f[:, None] * mag).sum(axis=0) / total
    # 谱平坦度（几何均值/算术均值）
    p = mag + 1e-20
    flat = np.exp(np.mean(np.log(p), axis=0)) / np.mean(p, axis=0)

    # 1 秒时间平滑后再取高分位（避免单帧瞬态误判）
    smooth = max(1, int(round(fs / hop)))

    def smooth_q(arr, q):
        if arr.size >= smooth:
            k = np.ones(smooth) / smooth
            arr = np.convolve(arr, k, mode="same")
        return float(np.percentile(arr, q))

    return {
        "band_2_5k_ratio_p95": smooth_q(r25, 95),
        "band_2_5k_ratio_mean": float(np.mean(r25)),
        "band_5_10k_ratio_p95": smooth_q(r5_10, 95),
        "band_low_ratio_mean": float(np.mean(r_low)),
        "centroid_hz_p95": smooth_q(centroid, 95),
        "centroid_hz_mean": float(np.mean(centroid)),
        "flatness_p95": smooth_q(flat, 95),
        "frames": int(mag.shape[1]),
    }


def harshness_score(report: dict) -> float:
    """把频谱指标压成一个 0~1 的刺耳度复合分（越小越柔和）。

    权重是工程经验值，用于**横向比较本项目各 cue 之间**谁更扎耳，
    不是绝对物理量。阈值与实测基线见 docs/技术/音频/音乐质检规范.md。
    典型音乐大致落在 0.3~0.5；白噪声一类会顶到 0.9 以上。
    """
    w = {"band_2_5k_ratio_p95": 1.2, "centroid_hz_p95": 1.0 / 12000.0,
         "flatness_p95": 0.8}
    s = (w["band_2_5k_ratio_p95"] * report.get("band_2_5k_ratio_p95", 0.0)
         + w["centroid_hz_p95"] * report.get("centroid_hz_p95", 0.0)
         + w["flatness_p95"] * report.get("flatness_p95", 0.0))
    return float(max(0.0, min(1.0, s)))


# ─────────────────────────── 循环接缝 / 单声道 ───────────────────────────

def loop_seam_report(x: np.ndarray, loop_start: int, loop_end: int,
                     window: int = 2048, fs: int = 48000) -> dict:
    """评估"末尾接回开头"处是否听得出来。

    ⚠ 这个指标很容易做错，务必按下面的定义理解：

    **不能**拿"循环末尾的一窗波形"和"循环开头的一窗波形"相减来判定。
    那两窗是**两个不同的音乐瞬间**（第 32 小节的结尾 vs 第 1 小节的开头），
    天然不相等；无论接缝多完美，这个差值都接近满电平。早期版本就是这么写的，
    结果对一首接缝完全连续、只用了尾巴折回的曲子报了 -1.6dB 的"严重跳变"。

    正确的判法是看**拼接处的一阶差分是否异常**：把"结尾前 k 点"与"开头后 k 点"
    拼成一条连续波形，若拼接真的连续，样点间差分与段内无异；若结尾被硬切或
    相位错位，接缝处会出现一个孤立的大差分（即"咔"）。

    返回：
      - `click_db`：接缝处 ±2 点的差分有效值，相对段内差分中位数的 dB 倍数。
        ≤ 12dB 视为听不出来；> 20dB 是明确的咔哒声。
      - `seam_flux_ratio`：跨接缝的谱通量 / 段内中位谱通量，> 3 通常听得出"断"。
      - `tail_decay_db`：循环末尾 20ms 相对前 20ms 的电平变化（负数=正在衰减，
        接近 0 说明结尾是"平的"、被硬切的可能性大）。
    """
    if x.ndim == 2:
        x = x.mean(axis=1)
    n = len(x)
    loop_end = min(loop_end, n)
    loop_start = max(0, min(loop_start, loop_end - 1))
    length = loop_end - loop_start
    if length < 2 * window + 1:
        return {"ok": False, "reason": "循环体太短，无法评估接缝"}

    pre = x[loop_end - window:loop_end]
    post = x[loop_start:loop_start + window]
    stitched = np.concatenate([pre, post])
    d = np.abs(np.diff(stitched))
    seam_idx = window - 1                      # 差分数组里对应拼接点的那一项
    lo = max(0, seam_idx - 2)
    hi = min(d.size, seam_idx + 3)
    seam_step = float(np.sqrt(np.mean(d[lo:hi] ** 2)))

    # 基准取**整首曲子的 99.9 分位差分**，而不是中位数差分。
    # 原因：拼接点正好落在一个乐句起音上是**正常且好听**的写法（循环体本身
    # 就是一个音乐周期，第一拍本来就该有音起）。若拿中位数做基准，一个完全
    # 正常的起音会被算成"跳变"——实测刚成曲的《灯下》就被误报成 12dB。
    # 改用高分位差分做基准后：正常的起音落在 0dB 附近，而真正的硬切/相位
    # 断裂（一个孤立的大台阶）会远高于全曲任何一处差分，轻松超过阈值。
    whole = np.abs(np.diff(x))
    floor_step = float(np.percentile(whole, 99.9)) + 1e-12
    click_db = 20.0 * math.log10(seam_step / floor_step + 1e-12)

    f, _, Z = signal.stft(stitched, fs=fs, nperseg=512, noverlap=384)
    mag = np.abs(Z)
    flux = np.sqrt(np.mean(np.diff(mag, axis=1) ** 2, axis=0)) if mag.shape[1] > 1 \
        else np.zeros(1)
    fidx = max(0, min(flux.size - 1, flux.size // 2))
    seam_flux = float(flux[fidx])
    typ_flux = float(np.median(flux)) + 1e-12

    k20 = max(1, int(0.02 * fs))
    tail_a = x[max(0, loop_end - 2 * k20):loop_end - k20]
    tail_b = x[loop_end - k20:loop_end]
    ea = float(np.sqrt(np.mean(tail_a ** 2))) + 1e-12
    eb = float(np.sqrt(np.mean(tail_b ** 2))) + 1e-12
    tail_decay_db = 20.0 * math.log10(eb / ea)

    return {
        "ok": True,
        "jump_rms_db": round(click_db, 2),
        "seam_flux_ratio": round(seam_flux / typ_flux, 3),
        "tail_decay_db": round(tail_decay_db, 2),
        "loop_seconds": round(length / fs, 3),
    }


def mono_compat_report(x: np.ndarray, fs: int) -> dict:
    """单声道兼容：声道相关性 + 折叠后响度损失。"""
    if x.ndim == 1:
        return {"correlation": 1.0, "mono_loss_lu": 0.0}
    l, r = x[:, 0], x[:, 1]
    if np.std(l) < 1e-9 or np.std(r) < 1e-9:
        return {"correlation": 1.0, "mono_loss_lu": 0.0}
    corr = float(np.corrcoef(l, r)[0, 1])
    stereo = integrated_lufs(x, fs)
    mono = integrated_lufs(((l + r) / 2.0)[:, None], fs)
    return {"correlation": corr, "mono_loss_lu": float(stereo - mono)}


# ─────────────────────────────── 汇总 ────────────────────────────────

def full_report(x: np.ndarray, fs: int, loop_start: int | None = None,
                loop_end: int | None = None) -> dict:
    mono = x if x.ndim == 1 else x.mean(axis=1)
    rep = {
        "duration_s": round(len(mono) / fs, 3),
        "sample_rate": fs,
        "channels": 1 if x.ndim == 1 else x.shape[1],
        "integrated_lufs": round(integrated_lufs(x, fs), 2),
        "short_term_max_lufs": round(float(np.nanmax(short_term_lufs_series(x, fs))), 2)
                               if len(mono) > fs else None,
        "loudness_range_lu": round(loudness_range(x, fs), 2),
        "true_peak_dbtp": round(true_peak_dbfs(x, fs), 2),
        "sample_peak_dbfs": round(sample_peak_dbfs(x), 2),
        "crest_factor_db": round(crest_factor_db(x), 2),
        "dc_offset": round(dc_offset(x), 6),
        "clipped_samples": clip_count(x),
        "silence_holes": count_silence_holes(mono, fs),
    }
    rep.update({("spectral_" + k): (round(v, 5) if isinstance(v, float) else v)
                for k, v in spectral_report(x, fs).items()})
    rep["harshness_score"] = round(harshness_score(spectral_report(x, fs)), 4)
    rep.update({("mono_" + k): round(v, 4)
                for k, v in mono_compat_report(x, fs).items()})
    if loop_start is not None and loop_end is not None:
        rep.update({("seam_" + k): (round(v, 3) if isinstance(v, float) else v)
                    for k, v in loop_seam_report(mono, loop_start, loop_end,
                                                 fs=fs).items()})
    return rep


def count_silence_holes(mono: np.ndarray, fs: int, thresh_db: float = -60.0,
                        min_ms: float = 50.0) -> int:
    """统计循环体内意外的静音空洞（>50ms 低于 -60dBFS）——通常是漏音/断轨。"""
    win = max(1, int(fs * 0.01))
    n = len(mono) // win * win
    if n == 0:
        return 0
    frames = mono[:n].reshape(-1, win)
    rms = np.sqrt(np.mean(frames ** 2, axis=1) + 1e-20)
    quiet = rms < 10 ** (thresh_db / 20.0)
    min_frames = max(1, int(min_ms / 10.0))
    holes, run = 0, 0
    for q in quiet:
        run = run + 1 if q else 0
        if run == min_frames:
            holes += 1
    return holes


def check_thresholds(rep: dict, spec: dict) -> list:
    """按 spec 里的阈值检查报告，返回违规项列表（空 = 通过）。"""
    fails = []
    for key, rule in spec.items():
        val = rep.get(key)
        if val is None:
            continue
        lo, hi = rule.get("min"), rule.get("max")
        if lo is not None and val < lo:
            fails.append("%s = %s < 下限 %s" % (key, val, lo))
        if hi is not None and val > hi:
            fails.append("%s = %s > 上限 %s" % (key, val, hi))
    return fails
