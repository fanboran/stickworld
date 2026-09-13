# -*- coding: utf-8 -*-
"""音效母带链 + 音效专用客观指标。

## 一、为什么音效需要一套**自己的**响度口径

音乐那边用 BS.1770 积分响度（-15 LUFS）作交付口径。音效不能照抄，原因是
**积分响度要求至少一个 400ms 分块**——`musiclib.loudness.integrated_lufs()`
对短于 400ms 的信号直接返回 `-inf`。而本项目最高频的三个音效是：

    ui_hover  ≈ 55ms      harvest_hit_a ≈ 62ms      ui_click ≈ 95ms

它们**根本测不出积分响度**。若强行给它们补 400ms 静音再测，得到的是被静音
稀释过的数（同一个音效，前面垫 0ms 还是 300ms 静音会差 6dB 以上），响度目标
变成"文件的填充长度"，这显然不是我们要控制的东西。

所以本管线定义 **事件响度 L_evt**：

    L_evt = -0.691 + 10·log10( Σ_ch (1/N)·Σ_n y_ch[n]² )
    y = K 加权（BS.1770 预滤波 + RLB 高通，直接复用 musiclib 的系数）

即"K 加权、整段、不定长、**无门限**"的均方响度。性质：

  * 对任意长度都有定义（1 个样点也行）；
  * 是**线性**的：`L_evt(x·g) = L_evt(x) + 20·log10(g)`，所以"归一化到目标"一步
    到位、精确闭合（不需要迭代）；
  * 对 ≥400ms 且能量集中的信号，它与 BS.1770 积分响度相差通常在 1 LU 内
    （质检报告里两个数都报，便于与音乐口径对齐）。

为了让 L_evt 有意义，交付件必须**裁到只剩声音本身**（见 `trim_to_event`）：
一段 2 秒的钟声里若留了 1 秒静音，L_evt 就被静音稀释 3dB，而积分响度不会。
裁剪阈值固定（-60dB rel. peak），所以结果仍可复现。

## 二、立体声与响度的关系（为什么全部交付立体声）

BS.1770 的 z 是各声道均方值**求和**。因此"同一信号灌进左右两声道的立体声文件"
比"单声道文件"在数值上高 3.01 LU，而两者在真实回放里听感**一样响**
（单声道文件播放时同样是左右两声各一份）。

也就是说：如果一半音效交单声道、一半交立体声，直接比较 LUFS 数字会误判 3dB。
本管线**一律交付 48kHz 立体声**，于是"文件 LUFS = 实际回放响度"，数字可以直接
与音乐（-15 LUFS 立体声）比较。
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np
from scipy import signal

# 复用音乐管线的成熟件（BS.1770 系数、DSP 原语、程序化 IR）。
# 只 import、不修改 `tools/music/` 下任何文件——那是另一个已验收任务的产物。
_MUSIC_TOOLS = str(Path(__file__).resolve().parents[2] / "music")
if _MUSIC_TOOLS not in sys.path:
    sys.path.insert(0, _MUSIC_TOOLS)

from musiclib import dsp, loudness, reverb      # noqa: E402

from . import synth as SYN                      # noqa: E402


# ─────────────────────────────── 事件响度 ──────────────────────────────

def k_weight(x: np.ndarray, fs: int) -> np.ndarray:
    """K 加权（复用 musiclib 的 BS.1770 系数，测 1kHz 时 1 LU 误差内对表）。"""
    x2 = x if x.ndim == 2 else x[:, None]
    sh_b, sh_a, hp_b, hp_a = loudness.k_weighting_coeffs(fs)
    y = signal.lfilter(sh_b, sh_a, x2, axis=0)
    return signal.lfilter(hp_b, hp_a, y, axis=0)


def event_lufs(x: np.ndarray, fs: int) -> float:
    """事件响度 L_evt（K 加权、整段均方、无门限）。见模块头 §一。"""
    y = k_weight(x, fs)
    z = float(np.sum(np.mean(y ** 2, axis=0)))
    if z <= 0.0:
        return -np.inf
    return float(loudness.ANCHOR + 10.0 * math.log10(z))


def integrated_lufs_safe(x: np.ndarray, fs: int) -> float | None:
    """BS.1770 积分响度；不足 400ms 时返回 None（不是拿静音垫出来的数）。"""
    mono_len = len(x) if x.ndim == 1 else len(x)
    if mono_len < int(0.4 * fs):
        return None
    return float(loudness.integrated_lufs(x, fs))


# ─────────────────────────────── 裁剪 ────────────────────────────────

def trim_to_event(x: np.ndarray, fs: int, lead_db: float = -70.0,
                  tail_rel_db: float = -50.0, tail_win_ms: float = 10.0,
                  keep_tail_ms: float = 10.0,
                  max_s: float | None = None) -> tuple:
    """裁掉首尾"非声音"部分：返回 (y, lead_removed_ms, tail_removed_ms)。

    * 头部：直到第一个超过 `lead_db`（绝对）的样点。**这一步是必需的**——
      `band_limit` 的补零滤波、`place()` 的偏移、混响的 pre-delay 都会在真正
      的起音前留下 1~20ms 的低电平；留着它，UI 点击就会"慢半拍"。
    * 尾部：阈值取"**最响的 10ms 窗口 RMS 往下 `tail_rel_db`**"，而不是
      "样点峰值往下"。这个区别很关键，也是踩出来的：撞击类音效的样点峰值
      （低频膜音的一两个过冲）往往比主体电平高十几 dB，拿样点峰值当基准的
      话，设计时长 540ms 的 `bodyfall_b` 会被裁成 354ms——**尾巴被裁在还有
      实际电平的地方**（听感上就是"声音没响完就断了"）。
      改用 10ms RMS 包络（贴近"电平感知"，且天然平滑掉单点瞬态）之后，
      "设计时长"与"实测时长"才对得上。
    """
    y = np.asarray(x, dtype=np.float64)
    mag = np.max(np.abs(y), axis=1) if y.ndim == 2 else np.abs(y)
    if mag.size == 0:
        return y, 0.0, 0.0
    # 头部
    lead_th = 10.0 ** (lead_db / 20.0)
    nz = np.flatnonzero(mag > lead_th)
    i0 = int(nz[0]) if nz.size else 0
    # 尾部：10ms 分块 RMS 包络
    win = max(2, int(tail_win_ms * fs / 1000.0))
    nb = max(1, int(math.ceil(len(mag) / float(win))))
    pad = nb * win - len(mag)
    blocks = np.concatenate([mag, np.zeros(pad)]).reshape(nb, win)
    rms = np.sqrt(np.mean(blocks ** 2, axis=1))
    ref = float(np.max(rms))
    if ref <= 0.0:
        return y, 0.0, 0.0
    tail_th = ref * (10.0 ** (tail_rel_db / 20.0))
    nz2 = np.flatnonzero(rms > tail_th)
    i1 = (int(nz2[-1]) + 1) * win if nz2.size else len(mag)
    i1 = min(len(mag), i1 + int(keep_tail_ms * fs / 1000.0))
    if max_s is not None:
        i1 = min(i1, i0 + int(max_s * fs))
    i1 = max(i1, i0 + 8)
    return y[i0:i1], i0 / fs * 1000.0, (len(mag) - i1) / fs * 1000.0


# ─────────────────────────── 立体声化与母带链 ──────────────────────────

def _env_follow(m: np.ndarray, fs: int, hold_ms: float = 10.0,
                release_ms: float = 80.0) -> np.ndarray:
    """信号包络（峰值保持 + 单极点慢落），用来把去相关噪声锁在声音包络上。

    为什么必须有它：噪声若按**整段 RMS** 缩放，就会在衰减 40~80dB 的尾音里
    裸露出一条常驻噪声底——实测 `game_started` 尾巴 5–12kHz 侧声道 −45dBFS、
    中声道 −85dBFS（侧/中 +40dB），听感就是"电流麦"。锁到包络上，噪声随声音一起消失。
    """
    from scipy.ndimage import maximum_filter1d
    a = np.abs(np.asarray(m, dtype=np.float64))
    w = max(1, int(hold_ms * fs / 1000.0))
    peak = maximum_filter1d(a, size=w, mode="nearest")
    g = float(np.exp(-1.0 / max(release_ms * fs / 1000.0, 1.0)))
    return signal.lfilter([1.0 - g], [1.0, -g], peak)


def stereoize(mono: np.ndarray, fs: int, width: float = 0.0, seed: int = 0,
              bass_mono_hz: float = 200.0) -> np.ndarray:
    """单声道 → 立体声。

    `width=0` 得到**左右完全相同**（双单声道）：最稳、折叠单声道零损失，UI 反馈
    与采集敲击都用它——这类音是被"点"出来的，加宽度只会让它在耳机里偏移。
    `width>0` 时往侧信号注入少量**包络锁定**的去相关噪声并做低频单声道化
    （复用 musiclib 的 `dsp.widen`，其低频单声道化是"直接对侧信号高通"的干净写法）。

    噪声的两条硬约束（踩过"电流麦"的坑）：
      1. **必须锁包络**（`_env_follow`）——按整段 RMS 缩放的噪声会在尾音里裸露成底噪；
      2. **频带压在中频**（300–3000Hz）——`dsp.widen` 会高通侧声道，噪声若取到 9kHz，
         高通后剩下的正好是最刺耳的"嘶嘶"段。
    """
    m = np.asarray(mono, dtype=np.float64)
    if m.ndim == 2:
        m = m.mean(axis=1)
    y = np.repeat(m[:, None], 2, axis=1)
    if width <= 0.0:
        return y
    n = len(m)
    side = SYN.band_noise(n / fs, fs, int(seed) + 991, 300.0, 3000.0,
                          order=2, color="pink", rms=1.0)[:n]
    if len(side) < n:
        side = np.pad(side, (0, n - len(side)))
    # 归一化包络（峰值 = 1）+ 按整段 RMS 定标：**最响处的噪声量与旧口径一致**
    # （那一瞬被声音掩蔽、听不出），但离开最响处就随包络一起掉下去 → 尾音无底噪。
    env = _env_follow(m, fs)
    env = env / (float(env.max()) + 1e-12)
    side = side * env * float(np.sqrt(np.mean(m ** 2)) + 1e-12) * width * 0.5
    lr = np.stack([m + side, m - side], axis=1)
    return dsp.widen(lr, amount=1.0, bass_mono_hz=bass_mono_hz, fs=fs)


def normalize_to(x: np.ndarray, fs: int, target_lufs: float) -> tuple:
    """把 L_evt 精确归到 target（线性，一步到位）。返回 (y, measured_before)。"""
    cur = event_lufs(x, fs)
    if not np.isfinite(cur):
        return x, cur
    return x * (10.0 ** ((target_lufs - cur) / 20.0)), cur


def peak_guard(x: np.ndarray, fs: int, ceiling_dbtp: float = -1.2) -> tuple:
    """真峰值守卫：返回 (y, tp_before, tp_after, shortfall_db)。

    做法是**纯降增益**，不是上限制器。理由：这些音效只有 60~200ms，一个
    release 120ms 的限制器在这么短的音上等同于"把整个音压下去"，还会在起音处
    留下泵动的痕迹；而"峰太高"在音效上的正确处理本来就是**降低设计里的峰均比**
    （见 design.py 的 `soft_clip` 配方项），不是事后硬压。

    因此这里只报告 `shortfall_db`（因为守峰值而少掉的响度），让它出现在质检
    报告里——"响度没到目标"必须是可见的，而不是被悄悄限制器抹平。
    """
    tp = loudness.true_peak_dbfs(x if x.ndim == 2 else x[:, None], fs)
    if tp <= ceiling_dbtp:
        return x, tp, tp, 0.0
    g = 10.0 ** (-(tp - ceiling_dbtp) / 20.0)
    y = x * g
    tp2 = loudness.true_peak_dbfs(y if y.ndim == 2 else y[:, None], fs)
    return y, tp, tp2, float(-(tp - ceiling_dbtp))


def apply_tone(x: np.ndarray, fs: int, ops) -> np.ndarray:
    """配方里的音色整形项：`[("highpass", 180), ("shelf", 3200, -3.0), ...]`。

    整形写在**配方表**里而不是自动，理由与音乐混音的 STEM_RECIPES 相同：
    "这一件要收敛多少高频"是审美决策，算法推不出来；写成显式配方则保证可复现、
    可查、可改。
    """
    y = x
    for op in ops or ():
        kind = op[0]
        if kind == "highpass":
            y = dsp.highpass(y, fs, float(op[1]), order=int(op[2]) if len(op) > 2 else 2)
        elif kind == "lowpass":
            y = dsp.lowpass(y, fs, float(op[1]), order=int(op[2]) if len(op) > 2 else 2)
        elif kind == "shelf":
            y = dsp.shelf(y, fs, float(op[1]), float(op[2]), kind=str(op[3]) if len(op) > 3 else "high")
        elif kind == "peak":
            y = dsp.peak(y, fs, float(op[1]), float(op[2]),
                         q=float(op[3]) if len(op) > 3 else 1.0)
        elif kind == "tilt":
            y = dsp.tilt(y, fs, float(op[1]), float(op[2]),
                         pivot=float(op[3]) if len(op) > 3 else 900.0)
        else:
            raise ValueError("未知音色整形: %s" % kind)
    return y


# ─────────────────────── 音效专用客观指标 ────────────────────────

def band_busy_ms(x: np.ndarray, fs: int, lo: float = 2000.0, hi: float = 5000.0,
                 ratio_thresh: float = 0.35, frame: int = 512,
                 hop: int = 128) -> dict:
    """2–5kHz 的**占用时长** —— 本管线对"刺耳"的核心度量。

    常规质检（音乐的 `qa_audio.py`）用"2–5kHz 相对能量的高分位"抓"刺耳"。对
    音效这个指标不够：音效本来就短促明亮，一个 40ms 的石头敲击的高分位一定很高，
    但它**不刺耳**——刺耳是"这个频段被占用得太久"（人耳的听觉疲劳按时间累积，
    2–5kHz 又是最敏感区）。而且这一带正是音乐的"存在感"区（钢琴 2.5kHz 微凸），
    音效在这里待得越久，和音乐打架越厉害。

    所以这里输出的是**时间量**：
      * `busy_ms`     —— 比值超阈的帧数 × 帧移（累计占用毫秒）
      * `busy_run_ms` —— 最长**连续**占用毫秒（"一直占着"比"断续点缀"更刺耳）
    """
    mono = x if x.ndim == 1 else x.mean(axis=1)
    if len(mono) < frame:
        mono = np.pad(mono, (0, frame - len(mono)))
    f, _t, Z = signal.stft(mono, fs=fs, nperseg=frame, noverlap=frame - hop,
                           window="hann", boundary=None, padded=False)
    mag = np.abs(Z) ** 2
    total = mag.sum(axis=0) + 1e-20
    sel = (f >= lo) & (f < hi)
    ratio = mag[sel].sum(axis=0) / total
    busy = ratio > ratio_thresh
    frame_ms = hop / fs * 1000.0
    run = best = 0
    for b in busy:                                  # 帧数少（≤ 数百），非样点循环
        run = run + 1 if b else 0
        best = max(best, run)
    return {"busy_ms": round(float(busy.sum()) * frame_ms, 1),
            "busy_run_ms": round(float(best) * frame_ms, 1),
            "ratio_mean": round(float(np.mean(ratio)), 4),
            "ratio_max": round(float(np.max(ratio)), 4)}


# ────────────────── 变体差异打分（"变体不是同一个音"的客观门槛）──────────────────
#
# 同一事件的多个变体若只是音量/音高微差，密集触发时会听成"机关枪"。设计上要求
# 变体的差异来自"材质/动作的真实变化"，这里给出可执行的判定：
# **两两之间至少要在某一条轴上超过"可察觉差异"的量**（打分 ≥ 1.0）。
#
# 容差取工程经验值（本项目的听感基线），是**相对排序工具**而非绝对物理量：
#   duration_ms        22ms   —— 短音效里 20ms 以上才听得出"动作变长了"
#   centroid_hz_*      15%    —— 谱质心的相对变化 ~15% 才算"音色不同"
#   flatness_p95       0.05   —— 噪声性/音调性的可观变化
#   band_*_ratio_mean  0.06   —— 频段能量占比 6 个百分点的迁移
DISTINCT_FEATURES = (
    ("duration_ms", 22.0, False),
    ("centroid_hz_mean", 0.15, True),
    ("centroid_hz_p95", 0.15, True),
    ("flatness_p95", 0.05, False),
    ("band_low_ratio_mean", 0.06, False),
    ("band2_5k_ratio_mean", 0.06, False),
)
DISTINCT_MIN_SCORE = 1.0


def variant_diff(rep_a: dict, rep_b: dict) -> tuple:
    """两个变体的差异打分：返回 (分数, 主导轴)。≥ DISTINCT_MIN_SCORE 视为"不同"。"""
    best = (0.0, "none")
    for key, tol, rel in DISTINCT_FEATURES:
        va, vb = rep_a.get(key), rep_b.get(key)
        if va is None or vb is None:
            continue
        denom = max(abs(float(va)), abs(float(vb)), 1e-9) if rel else 1.0
        score = abs(float(va) - float(vb)) / denom / tol
        if score > best[0]:
            best = (float(score), key)
    return best


def measure(x: np.ndarray, fs: int, name: str = "", lufs_target: float | None = None,
            lufs_target_min: float | None = None, lufs_target_max: float | None = None,
            dur_range_ms: tuple | None = None) -> dict:
    """一件音效的全部客观指标（进质检报告与 `qa_sfx.py --check`）。"""
    y = x if x.ndim == 2 else x[:, None]
    mono = y.mean(axis=1)
    mag = np.max(np.abs(y), axis=1) if y.ndim == 2 else np.abs(y)
    peak = float(np.max(mag)) if mag.size else 0.0
    rep: dict = {
        "name": name,
        "sample_rate": fs,
        "channels": int(y.shape[1]),
        "duration_ms": round(len(mono) / fs * 1000.0, 1),
        "event_lufs": round(event_lufs(y, fs), 2),
        "integrated_lufs": (None if integrated_lufs_safe(y, fs) is None
                            else round(integrated_lufs_safe(y, fs), 2)),
        "true_peak_dbtp": round(loudness.true_peak_dbfs(y, fs), 2),
        "sample_peak_dbfs": round(loudness.sample_peak_dbfs(y), 2),
        "crest_factor_db": round(loudness.crest_factor_db(y), 2),
        "dc_offset": round(loudness.dc_offset(y), 6),
        "clipped_samples": loudness.clip_count(y),
        "silence_holes": loudness.count_silence_holes(mono, fs),
    }
    if lufs_target is not None:
        rep["lufs_target"] = lufs_target
        rep["lufs_error"] = round(rep["event_lufs"] - lufs_target, 2)
    if dur_range_ms:
        rep["dur_range_ms"] = [dur_range_ms[0], dur_range_ms[1]]
    # 起音延迟：0ms 起音是 UI/采集的硬要求（垫了静音就是"手感慢半拍"）
    lead_th = peak * 10.0 ** (-50.0 / 20.0) if peak > 0 else 1.0
    nz = np.flatnonzero(mag > lead_th)
    rep["onset_ms"] = round((int(nz[0]) if nz.size else 0) / fs * 1000.0, 2)
    tail_win = mag[int(len(mag) * 0.96):] if len(mag) > 8 else mag
    rep["tail_dbfs"] = round(20.0 * math.log10(float(np.max(tail_win)) + 1e-12), 1)
    rep.update({"band2_5k_" + k: v for k, v in band_busy_ms(y, fs).items()})
    sp = loudness.spectral_report(y, fs)
    rep["centroid_hz_p95"] = round(sp["centroid_hz_p95"], 0)
    rep["centroid_hz_mean"] = round(sp["centroid_hz_mean"], 0)
    rep["band_low_ratio_mean"] = round(sp["band_low_ratio_mean"], 4)
    rep["flatness_p95"] = round(sp["flatness_p95"], 4)
    rep["harshness_score"] = round(loudness.harshness_score(sp), 4)
    rep.update({"mono_" + k: round(v, 4)
                for k, v in loudness.mono_compat_report(y, fs).items()})
    return rep


# ─────────────────────────────── 母带链 ───────────────────────────────

def master(audio: np.ndarray, fs: int, target_lufs: float,
           ceiling_dbtp: float = -1.2, tone_ops=None, rev: tuple | None = None,
           width: float = 0.0, seed: int = 0, soft_clip: tuple | None = None,
           fade_in_ms: float = 1.2, fade_out_ms: float = 6.0,
           max_s: float | None = None) -> tuple:
    """一件音效的母带链。返回 (stereo_audio, info)。

    顺序（**不能随便换**）：
      去直流 → 裁剪 → 音色整形 → 混响 → 立体声化 → 软削峰 → 归一响度 → 峰值守卫 → 淡边

    其中"归一响度"必须在所有非线性环节（`soft_clip`）与电平变化（混响、整形）之后；
    "峰值守卫"必须在归一之后（否则又被归一抬上去）。
    """
    y = np.asarray(audio, dtype=np.float64)
    if y.ndim == 2:
        y = y.mean(axis=1)
    y = dsp.highpass(y, fs, 25.0, order=2)             # 去直流/次声
    y, lead_ms, tail_ms = trim_to_event(y, fs, max_s=max_s)
    y = apply_tone(y, fs, tone_ops)
    if rev is not None:
        mix, style, rt60 = float(rev[0]), str(rev[1]), float(rev[2])
        if mix > 0:
            ir = reverb.get_ir(fs, rt60=rt60, pre_delay_ms=12.0, seed=seed,
                               style=style)
            y = reverb.convolve_reverb(y, ir, fs, mix=mix)
    y = stereoize(y, fs, width=width, seed=seed)
    sc_info = None
    if soft_clip is not None:
        drive, mix = float(soft_clip[0]), float(soft_clip[1])
        before = loudness.crest_factor_db(y)
        y = dsp.soft_clip(y, drive=drive, mix=mix)
        sc_info = {"crest_before_db": round(before, 2),
                   "crest_after_db": round(loudness.crest_factor_db(y), 2)}
    y, lufs_pre = normalize_to(y, fs, target_lufs)
    y, tp_pre, tp_post, shortfall = peak_guard(y, fs, ceiling_dbtp)
    y = dsp.fade(y, fs, fade_in_ms / 1000.0, fade_out_ms / 1000.0)
    info = {"lead_trimmed_ms": round(lead_ms, 2), "tail_trimmed_ms": round(tail_ms, 2),
            "lufs_before_norm": (None if not np.isfinite(lufs_pre) else round(lufs_pre, 2)),
            "tp_before_guard": round(tp_pre, 2), "tp_after_guard": round(tp_post, 2),
            "peak_guard_shortfall_db": round(shortfall, 2),
            "lufs_after_guard": round(event_lufs(y, fs), 2)}
    if sc_info:
        info.update(sc_info)
    return y, info
