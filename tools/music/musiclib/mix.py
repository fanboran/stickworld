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
    # 胶合压缩：把各曲目之间的响度差收窄。
    # 为什么需要它——钢琴是衰减型素材，峰值比平均响度高 13~16dB；
    # 在真峰值上限固定（-1 dBTP）的前提下，**动态越大就越响不起来**。
    # 实测部分曲子（如《灯下》）靠归一只能到 -16.5 LUFS，比目标低 1.5dB。
    # 这里用很轻的总线压缩（ratio 1.7）先收 1dB 左右的峰均比，
    # 再让限制器只做"最后 1dB"的事——比把限制器推狠要干净得多。
    # 想更响就调这个；代价是动态（"柔和"）会被牺牲一点，两者不可兼得。
    "glue": dict(threshold_db=-20.0, ratio=1.7, attack_ms=40.0,
                 release_ms=380.0, makeup_db=0.5),
    "tilt_low_db": 0.6,
    "tilt_high_db": -1.2,
    "tilt_pivot": 900.0,
    "soft": dict(drive=1.12, mix=0.22),
    # 交付响度按"流媒体标准"而不是"游戏总线留白"来定：文件响度是**素材属性**，
    # 把它放到游戏混音里的正确位置是音量滑条的职责（BGM 通道默认 0.8 ≈ -1.9dB）。
    # 早先按 -17 LUFS 交付，等于把"留 headroom"这件事烘焙进了素材，
    # 结果在播放器里比商业音乐明显小声（用户反馈"略小"），在游戏里又被滑条再压一次。
    "target_lufs": -15.0,
    "tp_ceiling_db": -1.0,
    # 限制器把**采样峰值**压到真峰值上限之下这么多，给采样间过冲留空间。
    # 少了这一步，限制器"压了但真峰值还是超"，只能靠整体降增益收场——
    # 结果是高动态的曲子（钢琴独奏最明显）永远到不了目标响度，白白丢掉 1~2dB。
    # 0.8dB 是常见的过冲余量（4× 过采样下 ABA 重建的过冲一般 <1dB）。
    "limiter_headroom_db": 0.8,
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
               target_lufs: float | None = None) -> tuple:
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

    # 目标与"逐样点增益包络"一起维护。包络的意义：母带链上除了**软饱和**
    # 之外全是"逐样点乘一个增益"（压缩器、限制器）或线性滤波（倾斜 EQ），
    # 这些都能**分解到每一层**（乘法可分配、线性滤波可加）。交付分层时把这
    # 条包络施加到每一层，"叠加"就严格复现母带——这是让游戏里听到的东西
    # 等于验收过的母带的关键（见 deliver_layers）。
    G = np.ones(len(y), dtype=np.float64)

    # ① 前置增益：抬到比目标高 3dB（给母带链留出被压缩的量）
    total_gain = 0.0
    cur = loudness.integrated_lufs(y, fs)
    if np.isfinite(cur):
        pre = float(np.clip((tgt + 3.0) - cur, -36.0, b["pre_gain_max_db"]))
        y = dsp.apply_gain_db(y, pre)
        G *= float(10.0 ** (pre / 20.0))
        total_gain += pre

    # ② 处理链（压缩器交出它自己的逐样点增益；倾斜 EQ 是线性滤波，逐层再做一遍）
    y, glue_gain = dsp.compressor(y, fs, return_gain=True, **b["glue"])
    G *= glue_gain
    y = dsp.tilt(y, fs, b["tilt_low_db"], b["tilt_high_db"], b["tilt_pivot"])
    y = dsp.soft_clip(y, **b["soft"])

    # ③ 精修到目标响度（此时电平已接近，修正量应很小）
    cur = loudness.integrated_lufs(y, fs)
    if np.isfinite(cur):
        fine = float(np.clip(tgt - cur, -12.0, 12.0))
        y = dsp.apply_gain_db(y, fine)
        G *= float(10.0 ** (fine / 20.0))
        total_gain += fine

    y, lim_gain = dsp.limiter(
        y, fs, ceiling_db=b["tp_ceiling_db"] - b["limiter_headroom_db"],
        return_gain=True)
    G *= lim_gain
    gr_db = 20.0 * float(np.log10(float(np.min(lim_gain)) + 1e-12))

    # ④ 真峰值兜底：限制器管的是**采样峰值**，采样间过冲仍可能越线。
    # 用一次静态增益修正把真峰值压回上限之下（静态增益不影响动态结构，
    # 比再加一级限制器更干净）。
    tp = loudness.true_peak_dbfs(y, fs)
    if np.isfinite(tp) and tp > b["tp_ceiling_db"]:
        corr = b["tp_ceiling_db"] - tp
        y = dsp.apply_gain_db(y, corr)
        G *= float(10.0 ** (corr / 20.0))
        total_gain += corr
    return y.astype(np.float32), gr_db, total_gain, G


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



# ─────────────────── 交付分层：让"各层之和"等于母带 ────────────────────
#
# 交付给引擎的是**分层文件**，运行时把它们叠起来播。所以交付的分层必须满足：
#
#     层1 + 层2 + ... + 层N  ≈  比母带略低不到 2dB
#
# 这件事不像看起来那么自动。母带链末尾的**总线归一增益**（把很轻的分轨求和抬到
# -15 LUFS，实测 +13 ~ +28dB）原本只加在母带上；若不把它同样加到每个层上，
# 游戏里叠出来的音乐就会比验收过的母带低 8~24dB——"预览听着正常、进游戏却几乎
# 听不见"这种极难定位的问题就是这么来的。
#
# 做法上有一个必须绕开的坑：**总线链是非线性的**（胶合压缩、软饱和、限制器），
# 非线性环节没法"逐层分解"——把同一个增益分别加到每层，并不等于对和加了同样的
# 处理。所以这里：
#
#   1. 每层只做**线性**整形（循环尾巴折回 / 一次性短句裁剪淡出）；
#   2. 求和，得到与母带链**同一形状**的信号；
#   3. 用"和"的统计量算出一个**共同标量**——既抬到目标响度，又保证峰值不越线；
#   4. 把这个标量施加到每一层。
#
# 这样各层之间的平衡**严格保持**（同一标量不改变相对关系），而叠出来的东西
# 就是"未经限制器的母带"——与母带的差别只剩限制器那 ≤2dB，且方向是安全的
# （交付的版本略保守，运行时还有总线限幅兜底）。


def deliver_layers(cue, processed: dict, fs: int = 48000,
                   target_lufs: float | None = None,
                   bus: dict | None = None,
                   wrap_tail: bool = True,
                   loop_start_sample: int = 0,
                   loop_end_sample: int = 0,
                   master_gain_env: np.ndarray | None = None,
                   target_len: int | None = None,
                   fade_s: float = 0.7) -> tuple:
    """把每个层做成可直接交付的音频。返回 ({层名: 音频}, 信息字典)。

    交付分层必须满足：**各层之和 ≈ 混音母带**。否则游戏里听到的音乐会与
    验收过的母带不一致——"预览正常、进游戏偏小"这类问题就是这么来的。

    做法：母带链上除软饱和外全是可分解的操作，于是
        交付层_i = 母带增益包络 × 倾斜EQ(循环整形(处理后的层_i))
    求和后 = 母带增益包络 × 倾斜EQ(原始和) = "未经软饱和的母带"。
    软饱和是唯一不可分解的环节，但它很轻（mix 0.22，在 0dBFS 附近近似单位增益），
    残差在 0.3dB 量级——比"整体差 13~24dB"好上两个数量级。
    """
    b = dict(BUS)
    if bus:
        b.update(bus)
    tgt = b["target_lufs"] if target_lufs is None else target_lufs

    # ① 逐层线性整形 + 逐层做与母带相同的倾斜 EQ（线性滤波可加，故等价）
    #
    # 长度必须**统一到母带整形后的长度**：循环曲目的折回是确定性的（都截到
    # loop_end），但一次性短句的"裁掉尾部静音"对"和"与对"单层"会落在不同位置
    # （和的余音更长），逐层各裁各的就会出现长度不一致、叠加时报广播错误。
    # 所以：非循环项在这里**不各自裁剪**，一律对齐到 target_len 再统一加淡出
    # ——淡出曲线对每层相同，求和后的淡出与母带的淡出一致。
    shaped = {}
    for name, y in processed.items():
        z = y
        if wrap_tail and loop_end_sample > loop_start_sample:
            z = wrap_loop_tail(z, fs, loop_start_sample, loop_end_sample)
        if target_len is not None:
            z = z[:target_len]
            if len(z) < target_len:
                z = np.concatenate([z, np.zeros((target_len - len(z), z.shape[1]),
                                                dtype=z.dtype)], axis=0)
        if not wrap_tail and target_len is not None:
            k = min(len(z), int(fade_s * fs))
            if k > 1:
                t = np.linspace(0.0, 1.0, k)
                g = np.cos(t * np.pi / 2) ** 1.5
                z = z.copy()
                z[len(z) - k:] *= g[:, None]
        z = dsp.tilt(z, fs, b["tilt_low_db"], b["tilt_high_db"], b["tilt_pivot"])
        shaped[name] = z

    n = max(len(v) for v in shaped.values())
    total = np.zeros((n, 2), dtype=np.float64)
    for z in shaped.values():
        total[:len(z)] += z

    gain = master_gain_env
    if gain is None:
        # 没有母带包络时退化为"共同标量"：按和定响度、按和峰值保底。
        # （这条路径用于不方便跑母带链的场合；正常流程一定走包络。）
        loud_gain = tgt - loudness.integrated_lufs(total, fs)
        peak = float(np.max(np.abs(total))) if total.size else 0.0
        ceil_lin = 10.0 ** (b["tp_ceiling_db"] / 20.0)
        peak_gain = (20.0 * float(np.log10(ceil_lin / peak))) if peak > ceil_lin else 1e9
        g_scalar = float(np.clip(min(loud_gain, peak_gain), -36.0, 60.0))
        gain = np.full(n, 10.0 ** (g_scalar / 20.0))

    G = gain if gain.ndim == 1 else gain
    out = {}
    for name, z in shaped.items():
        m = min(len(z), len(G))
        w = np.zeros_like(z)
        w[:m] = z[:m] * G[:m, None]
        if len(z) > m:
            w[m:] = z[m:] * G[-1]
        out[name] = w.astype(np.float32)

    total_out = np.zeros((n, 2), dtype=np.float64)
    for z in out.values():
        total_out += z
    info = {
        "deliver_gain_db": round(20.0 * float(np.log10(
            float(np.median(G)) + 1e-12)), 2),
        "deliver_lufs": round(loudness.integrated_lufs(total_out, fs), 2),
        "deliver_peak_dbfs": round(20.0 * float(np.log10(
            max(1e-12, float(np.max(np.abs(total_out)))))), 2),
    }
    return out, info


# ─────────────────────────────── 一首曲子 ──────────────────────────────

def mix_cue(cue, stem_paths: dict, fs: int = 48000,
            overrides: dict | None = None, bus: dict | None = None,
            target_lufs: float | None = None,
            wrap_tail: bool = True, return_stems: bool = False) -> tuple:
    """把某个 cue 的分轨混成成品。

    返回 (mix, report)；return_stems=True 时再返回第三项 processed
    （{层名: 该层处理后的完整音频，未经求和与总线处理}）。

    ⚠ report 里的 `_master_gain_env` 是**临时键**（numpy 数组，供交付分层复现
    母带增益），调用方取走后应立即 pop，否则报告无法 JSON 序列化。
    试听样带需要它来做"同一增益下的分层 A/B"——分别归一化会让各档听起来
    一样响，反而听不出叠层的差别。
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

    # ── 循环整形必须在母带链**之前** ──
    # 尾巴折回是"把循环体之后的余音加到开头"，这是一次**相加**，会让开头变响、
    # 峰值变高。若先母带（含限制器）再折回，新长出来的峰值就没人管了——
    # 限制器只对它之前的信号负责。所以顺序是：分层处理 → 求和 → 循环整形 → 母带。
    loop_start = int(round(cue.seconds(cue.loop_start_beat) * fs))
    loop_end = int(round(cue.seconds(cue.loop_end_beat) * fs))
    if wrap_tail and loop_end < len(mix):
        mix = wrap_loop_tail(mix, fs, loop_start, loop_end)
    elif not wrap_tail:
        # 一次性短句：裁尾静音 + 淡出（不是循环曲，不需要尾巴折回）
        mix = trim_and_fade(mix, fs)

    mix, gr_db, total_gain, master_G = master_bus(mix, fs, bus, target_lufs)

    report = {
        "limiter_max_gr_db": round(gr_db, 2),
        "applied_gain_db": round(total_gain, 2),
        "tp_ceiling_db": float(bus.get("tp_ceiling_db", BUS["tp_ceiling_db"])
                               if bus else BUS["tp_ceiling_db"]),
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
    report["_master_gain_env"] = master_G      # 供交付分层按同一包络施加
    report["shaped_len"] = int(len(mix))       # 交付分层要对齐到这个长度
    if return_stems:
        return mix, report, processed
    return mix, report


def save_mix(mix: np.ndarray, path: str, sr: int = 48000) -> None:
    write_wav(path, mix, sr, subtype="PCM_24")
