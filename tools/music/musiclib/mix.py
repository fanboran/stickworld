# -*- coding: utf-8 -*-
"""混音与母带 —— 把分轨 WAV 变成一首可交付的曲子。

流程（对齐行业做法，见 docs/技术/音频/音乐制作管线.md）：

    分轨 WAV
      → 每轨处理链（高通 → EQ 塑形 → 轻压缩 → 卷积混响发送 → 宽度）
      → 总线求和
      → 胶合压缩 → 倾斜 EQ → 软饱和
      → 响度归一到目标 LUFS
      → 限制到真峰值上限
      → 循环尾巴折回开头（无缝循环的关键一步）

**为什么每条轨道的参数写死在表里而不是自动**：混音是审美决策。"钢琴亮一点、
弦乐垫必须让出 2~5kHz 给旋律"这类判断无法由算法推出，把它写成显式的配方表，
既保证了可复现，也让"为什么这么调"留在代码里可查、可改。
"""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from . import dsp, loudness, reverb
from .render import load_stem, pad_to, write_wav


# ─────────────────────────────── 配方 ────────────────────────────────

@dataclass
class RevSend:
    style: str = "hall"
    mix: float = 0.25
    rt60: float = 2.2
    pre_delay_ms: float = 26.0
    brightness_db: float = 0.0
    seed: int = 0


@dataclass
class StemRecipe:
    """单个声部的处理配方。所有频点单位 Hz，增益单位 dB。"""
    hp: float = 40.0                     # 高通，去掉无用低频腾出空间
    low_shelf: tuple | None = None       # (freq, gain_db) 加温暖
    high_shelf: tuple | None = None      # (freq, gain_db) 收敛亮度（防刺耳主力）
    peaks: list = field(default_factory=list)   # [(freq, gain_db, q)]
    comp: dict | None = None             # 压缩器参数
    rev: RevSend | None = None
    width: float = 1.0                   # M/S 展宽倍率
    pan: float = 0.0
    gain_db: float = 0.0


# 日系静谧配乐的关键取舍：
#   - 钢琴是主角：2.8kHz 给"存在感"、5kHz 给"轮廓"、6.5kHz 以上**提亮**
#   - 弦乐垫必须"宽而不厚"：高通 145Hz、高频收敛，把明亮区让给钢琴
#   - 钟琴/八音盒的 6~9kHz 共鸣峰要窄带压掉，否则点状音会刺
#   - 低频只留一条承重梁：钢琴低音 + 弦乐垫低音都做高通，把 80~200Hz 让给低音声部
#
# ⚠ 钢琴为什么要**提**高频而不是收：Salamander Grand Piano V3 是出了名的"柔"，
# 实测原始采样（C4）频谱斜率约 -11 dB/oct，2093Hz 已在基频下方 62dB、4kHz 以上
# 几乎无能量。若还按"钢琴偏亮"的成见去做 8kHz 衰减，成品会闷成一团。
# 提亮是**补偿音源的固有暗色**，不是"加亮"。所有频段增益都应以实测为准：
# 用 tools/music/tone_check.py 量出八度带分布再定，不要凭感觉填。
STEM_RECIPES = {
    "piano": StemRecipe(
        hp=52.0, low_shelf=(190.0, 1.2),
        peaks=[(300.0, -1.0, 1.0), (2800.0, 2.2, 0.9), (5000.0, 2.0, 1.2)],
        high_shelf=(7000.0, 2.5),
        rev=RevSend("hall", 0.21, 2.2, 26.0, -0.5), width=1.06, gain_db=0.0),
    "strings": StemRecipe(
        hp=145.0, low_shelf=(300.0, -1.2), high_shelf=(6500.0, -3.0),
        peaks=[(1800.0, -1.0, 1.2)],
        comp=dict(threshold_db=-24.0, ratio=1.7, attack_ms=45.0,
                  release_ms=420.0, makeup_db=1.5),
        rev=RevSend("hall", 0.38, 2.9, 34.0, -1.0, seed=7), width=1.34,
        gain_db=0.0),
    "pad": StemRecipe(
        hp=115.0, high_shelf=(5200.0, -4.0),
        comp=dict(threshold_db=-26.0, ratio=1.6, attack_ms=60.0,
                  release_ms=500.0, makeup_db=2.0),
        rev=RevSend("hall", 0.44, 3.1, 42.0, -1.5, seed=11), width=1.22,
        gain_db=0.0),
    "bells": StemRecipe(
        hp=310.0, high_shelf=(9500.0, -2.2),
        peaks=[(6800.0, -2.4, 2.2), (9100.0, -1.8, 2.4)],
        rev=RevSend("plate", 0.46, 3.3, 44.0, -0.5, seed=3), width=1.35,
        gain_db=0.0),
    "harp": StemRecipe(
        hp=150.0, high_shelf=(8800.0, -2.2),
        rev=RevSend("hall", 0.30, 2.4, 28.0, -0.5, seed=5), width=1.12,
        gain_db=0.0),
    "winds": StemRecipe(
        hp=175.0, high_shelf=(7800.0, -2.4),
        peaks=[(2600.0, 1.2, 0.9)],
        rev=RevSend("hall", 0.33, 2.5, 30.0, 0.0, seed=13), width=0.85,
        gain_db=0.0),
    "guitar": StemRecipe(
        hp=125.0, high_shelf=(8200.0, -2.2),
        peaks=[(3200.0, -1.0, 1.6)],
        rev=RevSend("room", 0.26, 1.3, 18.0, 0.0, seed=17), width=1.15,
        gain_db=0.0),
    "music_box": StemRecipe(
        hp=380.0, high_shelf=(9000.0, -3.0),
        peaks=[(5400.0, -2.0, 2.0), (7600.0, -2.6, 2.2)],
        rev=RevSend("plate", 0.48, 3.6, 48.0, -1.0, seed=19), width=1.2,
        gain_db=0.0),
    "perc": StemRecipe(
        hp=45.0, high_shelf=(9000.0, -1.5),
        rev=RevSend("room", 0.22, 1.5, 20.0, 0.0, seed=23), width=1.1,
        gain_db=0.0),
    "marimba": StemRecipe(
        hp=120.0, low_shelf=(300.0, 0.8), high_shelf=(8000.0, -2.6),
        peaks=[(3800.0, -1.2, 1.8)],
        rev=RevSend("hall", 0.28, 1.8, 24.0, -1.0, seed=29), width=1.2,
        gain_db=0.0),
    "vibraphone": StemRecipe(
        hp=150.0, high_shelf=(9000.0, -2.4),
        peaks=[(6200.0, -1.8, 2.0)],
        rev=RevSend("hall", 0.38, 2.6, 34.0, -0.5, seed=31), width=1.10,
        gain_db=0.0),
    "cello": StemRecipe(
        hp=70.0, low_shelf=(220.0, 1.0), high_shelf=(5000.0, -3.0),
        comp=dict(threshold_db=-24.0, ratio=1.6, attack_ms=50.0,
                  release_ms=450.0, makeup_db=1.5),
        rev=RevSend("hall", 0.34, 2.6, 30.0, -1.0, seed=37), width=1.05,
        gain_db=0.0),
}

# 总线（母带）配方。目标响度按游戏惯例明显低于流媒体（见交付规范）：
# 要给音效/语音留 headroom，也要保住自适应音乐赖以生存的动态对比。
BUS = {
    "glue": dict(threshold_db=-15.0, ratio=1.55, attack_ms=35.0,
                 release_ms=320.0, makeup_db=0.0),
    "tilt_low_db": 0.6,
    "tilt_high_db": -1.2,
    "tilt_pivot": 900.0,
    "soft": dict(drive=1.12, mix=0.22),
    "target_lufs": -17.0,
    "tp_ceiling_db": -1.2,
    "pre_gain_max_db": 30.0,
}


def _corr(x: np.ndarray) -> float:
    """左右声道皮尔逊相关（单声道/静音返回 1.0）。"""
    if x.ndim == 1 or np.std(x[:, 0]) < 1e-9 or np.std(x[:, 1]) < 1e-9:
        return 1.0
    return float(np.corrcoef(x[:, 0], x[:, 1])[0, 1])


def default_recipe(name: str) -> StemRecipe:
    if name in STEM_RECIPES:
        return STEM_RECIPES[name]
    # 未登记的声部按"宽容的通用档"处理，并提示补登记
    return StemRecipe(hp=90.0, high_shelf=(8500.0, -2.0),
                      rev=RevSend("hall", 0.3, 2.4, 30.0))



# ────────────────────── 层平衡：按意图自动配平 ──────────────────────
#
# 为什么不能靠手调增益：各层的"电平"由音源决定，而不同音源差异极大
# （钢琴是衰减型、弦乐垫是持续型、钟琴是稀疏点状）。同样的增益值，
# 实测 RMS 能差十几个 dB（本管线实测：弦乐垫 RMS 比钢琴高 1dB，
# 长笛比钢琴高 2dB——都是"伴奏盖过主旋律"的写法，但听感是错的）。
#
# 所以这里改用**按意图配平**：先量出每层"发声时"的电平
# （400ms 窗口 RMS 的 90 分位，而不是全曲 RMS——后者会被稀疏层的静音段带偏），
# 再把它对齐到"相对该 cue 钢琴的固定偏移"。偏移量是审美意图，写在表里；
# 具体增益由实测算出。这样换音源、换力度都不用重新手调一遍。
LAYER_BALANCE_DB = {
    "piano": 0.0,        # 主旋律，基准
    "winds": -3.0,       # 独奏木管：接过旋律时略低于钢琴，不抢
    "cello": -5.0,
    "strings": -6.5,     # 垫子：在钢琴之下当"床"
    "pad": -8.0,         # 环境垫：更远
    "perc": -6.0,        # 定音鼓：只点强拍，克制
    "harp": -8.0,
    "guitar": -8.0,
    "marimba": -9.0,
    "vibraphone": -9.0,
    "bells": -10.0,      # 点状色彩：是"光"，不是"音符"
}
## 自动配平的上下限：超出说明层渲染有问题（近静音或被削），不该靠增益硬补
BALANCE_CLAMP_DB = 15.0


def activity_level(x: np.ndarray, fs: int, window_s: float = 0.1,
                   pct: float = 95.0) -> float:
    """"发声时的电平"：短窗 RMS 的高分位（dBFS）。

    为什么不用全曲 RMS：稀疏层（钟琴每小节一个音、马林巴是点状音）的全曲 RMS
    几乎等于静音电平，拿它配平会把这类层推到巨响。
    为什么窗口要短（0.1s）而不是 0.4s：点状音的能量集中在起音后的几十毫秒，
    400ms 窗会把一个马林巴音"稀释"进 400ms 的静音里，测出来仍然偏低——
    实测这会让马林巴/钟琴的配平触到 +15dB 上限（即"系统认为它太轻了"）。
    0.1s 窗 + 95 分位能抓住"这个音实际有多响"，与听感一致。
    """
    mono = dsp.to_mono(x)
    n = max(1, int(window_s * fs))
    hop = max(1, n // 2)
    if len(mono) < n:
        r = float(np.sqrt(np.mean(mono ** 2)))
        return 20.0 * float(np.log10(r + 1e-12))
    idx = np.arange(0, len(mono) - n + 1, hop)
    frames = np.lib.stride_tricks.as_strided(
        mono, shape=(len(idx), n), strides=(mono.strides[0] * hop, mono.strides[0]))
    rms = np.sqrt(np.mean(frames ** 2, axis=1))
    return 20.0 * float(np.log10(float(np.percentile(rms, pct)) + 1e-12))


# ─────────────────────────────── 单轨处理 ──────────────────────────────

def process_stem(x: np.ndarray, fs: int, r: StemRecipe,
                 overrides: dict | None = None) -> np.ndarray:
    o = overrides or {}
    y = x
    if r.hp and r.hp > 0:
        y = dsp.highpass(y, fs, float(o.get("hp", r.hp)), order=2)
    ls = o.get("low_shelf", r.low_shelf)
    if ls:
        y = dsp.shelf(y, fs, ls[0], ls[1], kind="low")
    for freq, gain, q in (o.get("peaks", r.peaks) or []):
        y = dsp.peak(y, fs, freq, gain, q)
    hs = o.get("high_shelf", r.high_shelf)
    if hs:
        y = dsp.shelf(y, fs, hs[0], hs[1], kind="high")
    comp = o.get("comp", r.comp)
    if comp:
        y = dsp.compressor(y, fs, **comp)
    y = dsp.apply_gain_db(y, float(o.get("gain_db", r.gain_db)))
    rev = o.get("rev", r.rev)
    # 允许用 rev_style / rev_mix 只改空间类型或湿度，其余参数沿用配方
    if rev is not None:
        if isinstance(rev, str):
            rev = RevSend(rev, r.rev.mix if r.rev else 0.25,
                          r.rev.rt60 if r.rev else 2.2,
                          r.rev.pre_delay_ms if r.rev else 26.0,
                          r.rev.brightness_db if r.rev else 0.0,
                          r.rev.seed if r.rev else 0)
        if "rev_style" in o or "rev_mix" in o:
            rev = RevSend(o.get("rev_style", rev.style),
                          float(o.get("rev_mix", rev.mix)),
                          rev.rt60, rev.pre_delay_ms, rev.brightness_db, rev.seed)
    if rev is not None:
        ir = reverb.get_ir(fs, rev.rt60, rev.pre_delay_ms, rev.seed,
                           rev.style, rev.brightness_db)
        y = reverb.convolve_reverb(y, ir, fs, mix=rev.mix)
    # 展宽前的信号（含混响、不含宽度）——安全阀要回到这一步重做
    x_dry = y
    width = float(o.get("width", r.width))
    if abs(width - 1.0) > 1e-6:
        # 安全阀：展宽过头会让左右相关跌到 0 旁边甚至为负——那样在单声道设备上
        # （手机外放、部分音箱）会明显抵消、变轻。宁可少一点宽度，也不要单声道塌陷。
        # 每次都**从干信号重新展宽**，避免在已展宽的信号上反复叠加。
        y = dsp.widen(x_dry, width, fs=fs)
        corr = _corr(y)
        while corr < 0.10 and width > 1.02:
            width = 1.0 + (width - 1.0) * 0.5
            y = dsp.widen(x_dry, width, fs=fs)
            corr = _corr(y)
    pan = float(o.get("pan", r.pan))
    if abs(pan) > 1e-6:
        y = dsp.pan_stereo(y, pan)
    return y.astype(np.float32)


# ─────────────────────────────── 总线 ────────────────────────────────

def master_bus(mix: np.ndarray, fs: int, bus: dict | None = None,
               target_lufs: float | None = None) -> np.ndarray:
    """总线母带：**先做增益分级，再处理**。

    为什么不能"先压再补音量"：压缩器、软饱和都是非线性环节，输入电平
    不同、结果就不同。分轨求和后的电平取决于这一首用了几个声部、多轻的
    力度，浮动很大；直接进压缩器会让"安静的小编制曲子"被压得几乎没反应、
    "大编制曲子"又被压死。所以先测一次响度、把电平抬到接近目标再进处理链，
    处理完再精修到目标——这是录音棚里"增益分级"的标准做法。
    """
    b = dict(BUS)
    if bus:
        b.update(bus)
    tgt = b["target_lufs"] if target_lufs is None else target_lufs
    y = mix

    # ① 前置增益：抬到比目标高 3dB（给母带链留出被压缩的量）
    cur = loudness.integrated_lufs(y, fs)
    if np.isfinite(cur):
        pre = float(np.clip((tgt + 3.0) - cur, -36.0, b["pre_gain_max_db"]))
        y = dsp.apply_gain_db(y, pre)

    # ② 处理链
    y = dsp.compressor(y, fs, **b["glue"])
    y = dsp.tilt(y, fs, b["tilt_low_db"], b["tilt_high_db"], b["tilt_pivot"])
    y = dsp.soft_clip(y, **b["soft"])

    # ③ 精修到目标响度（此时电平已接近，修正量应很小）
    cur = loudness.integrated_lufs(y, fs)
    if np.isfinite(cur):
        y = dsp.apply_gain_db(y, float(np.clip(tgt - cur, -12.0, 12.0)))

    y = dsp.limiter(y, fs, ceiling_db=b["tp_ceiling_db"])

    # ④ 真峰值兜底：限制器管的是**采样峰值**，采样间过冲仍可能越线。
    # 用一次静态增益修正把真峰值压回上限之下（静态增益不影响动态结构，
    # 比再加一级限制器更干净）。
    tp = loudness.true_peak_dbfs(y, fs)
    if np.isfinite(tp) and tp > b["tp_ceiling_db"]:
        y = dsp.apply_gain_db(y, b["tp_ceiling_db"] - tp)
    return y.astype(np.float32)


# ─────────────────────────── 循环尾巴折回 ────────────────────────────


def trim_and_fade(x: np.ndarray, fs: int, keep_s: float = 1.6,
                  fade_s: float = 0.7, thresh_db: float = -60.0) -> np.ndarray:
    """一次性短句（stinger）的收尾：裁掉尾部静音并加淡出。

    循环曲目**不能**这么做——它的尾巴要被折回开头（见 wrap_loop_tail）。
    但一次性短句必须裁：渲染时按约定多写了 8 拍余量，若不裁，文件末尾会拖着
    大半段静音，后果有两个，都会污染指标：
      · LRA（短时响度的分位差）被撑到十几 LU，看着像"动态巨大"，其实是静音；
      · 频谱指标被静音帧的数值噪声带偏——实测 sting 的谱平坦度直接顶到 1.0
        （纯噪声），把"这是一段安静的音乐"误报成"这是一段噪声"。
    """
    mono = np.abs(x if x.ndim == 1 else x.mean(axis=1))
    thr = 10.0 ** (thresh_db / 20.0)
    above = np.nonzero(mono > thr)[0]
    if above.size == 0:
        return x
    end = min(len(x), int(above[-1]) + int(keep_s * fs))
    y = x[:end].copy()
    k = min(len(y), int(fade_s * fs))
    if k > 1:
        t = np.linspace(0.0, 1.0, k)
        g = np.cos(t * np.pi / 2) ** 1.5      # 略快于等功率，收得干净
        y[len(y) - k:] *= g[:, None] if y.ndim == 2 else g
    return y

def wrap_loop_tail(x: np.ndarray, fs: int, loop_start_sample: int,
                   loop_end_sample: int) -> np.ndarray:
    """把循环体之后的尾巴**折回**到循环体开头。

    这是无缝循环最关键的一步，也是最容易被忽略的一步：
    渲染出来的音频在循环结束点之后还有一段"混响/琴弦余振"（尾巴）。
    如果直接截断，每次循环到结尾都会听到明显的断裂与空间感塌陷。
    正确做法是把 [loop_end, ...) 这段尾巴加到 [loop_start, ...) 上——
    于是"上一遍的余音"正好成了"下一遍开头的铺垫"，接缝在物理上就消失了。

    返回长度为 loop_end_sample 的数组（前段保持可选的 intro）。
    """
    loop_end_sample = min(loop_end_sample, len(x))
    loop_start_sample = max(0, min(loop_start_sample, loop_end_sample))
    tail = x[loop_end_sample:]
    y = x[:loop_end_sample].copy()
    if len(tail) == 0:
        return y
    room = loop_end_sample - loop_start_sample
    n = min(len(tail), room)
    y[loop_start_sample:loop_start_sample + n] += tail[:n]
    return y


# ─────────────────────────────── 一首曲子 ──────────────────────────────

def mix_cue(cue, stem_paths: dict, fs: int = 48000,
            overrides: dict | None = None, bus: dict | None = None,
            target_lufs: float | None = None,
            wrap_tail: bool = True) -> tuple:
    """把某个 cue 的分轨混成成品。

    返回 (mix, report)；mix 为 (n, 2) float32，report 含各轨电平与总线指标。
    """
    overrides = overrides or {}
    loaded = {}
    for name, path in stem_paths.items():
        loaded[name] = load_stem(path, fs)
    if not loaded:
        raise ValueError("没有可混音的分轨: %s" % cue.cue_id)

    n = max(len(v) for v in loaded.values())
    # 基准层：优先钢琴；没有钢琴的 cue（如战略图）用最响的那层当地基
    activities = {nm: activity_level(v, fs) for nm, v in loaded.items()}
    ref_name = "piano" if "piano" in activities else         max(activities, key=lambda k: activities[k])
    balance_ref = activities[ref_name]
    if "gain_db" not in overrides.get(ref_name, {}):
        overrides.setdefault(ref_name, {})["gain_db"] = (
            float(cue.stems[ref_name].gain_db) if ref_name in cue.stems else 0.0)
    processed = {}
    stem_peak = {}
    for name, x in loaded.items():
        r = default_recipe(name)
        ov = dict(overrides.get(name, {}))
        # 层的**平衡**按"意图 + 实测"自动配平：量出这一层发声时的电平，
        # 对齐到相对钢琴的目标偏移（见 LAYER_BALANCE_DB 的说明）。
        # 曲目里显式写的 gain_db 作为**额外的艺术偏移**叠加上去。
        if "gain_db" not in ov:
            cue_gain = float(cue.stems[name].gain_db) if name in cue.stems else 0.0
            auto = (balance_ref - activities[name]
                    + float(LAYER_BALANCE_DB.get(name, -6.0)))
            auto = float(np.clip(auto, -BALANCE_CLAMP_DB, BALANCE_CLAMP_DB))
            if abs(auto) >= BALANCE_CLAMP_DB - 1e-6:
                print("    [mix] 警告：%s/%s 的自动配平触到上限 %.1f dB"
                      % (cue.cue_id, name, auto))
            ov["gain_db"] = cue_gain + auto
        y = process_stem(pad_to(x, n), fs, r, ov)
        processed[name] = y
        stem_peak[name] = round(float(np.max(np.abs(y))) if y.size else 0.0, 5)

    mix = np.zeros((n, 2), dtype=np.float32)
    for y in processed.values():
        mix += y

    mix = master_bus(mix, fs, bus, target_lufs)

    loop_start = int(round(cue.seconds(cue.loop_start_beat) * fs))
    loop_end = int(round(cue.seconds(cue.loop_end_beat) * fs))
    if wrap_tail and loop_end < len(mix):
        mix = wrap_loop_tail(mix, fs, loop_start, loop_end)
    elif not wrap_tail:
        # 一次性短句：裁尾静音 + 淡出（不是循环曲，不需要尾巴折回）
        mix = trim_and_fade(mix, fs)

    report = {
        "cue_id": cue.cue_id,
        "title": cue.title,
        "bpm": cue.bpm,
        "key": "%s %s" % (cue.key, cue.scale),
        "bars": cue.bars,
        "stems": sorted(processed.keys()),
        "stem_peaks": stem_peak,
        "loop_start_sample": loop_start,
        "loop_end_sample": loop_end,
        "loop_beats": round(cue.loop_end_beat - cue.loop_start_beat, 3),
        "loop_bars": round((cue.loop_end_beat - cue.loop_start_beat)
                           / cue.beats_per_bar, 3),
    }
    report.update(loudness.full_report(mix, fs, loop_start, loop_end))
    return mix, report


def save_mix(mix: np.ndarray, path: str, sr: int = 48000) -> None:
    write_wav(path, mix, sr, subtype="PCM_24")
