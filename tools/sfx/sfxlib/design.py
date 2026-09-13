# -*- coding: utf-8 -*-
"""音效设计配方 —— **每个音效一份显式配方**：这是什么声音、由哪几个成分构成、
为什么这么设计。

配方不做"参数微调"，只做**这个音效从哪来**的物理/语义决策。参数留给
`post.master()`（响度与峰值）与 `qa_sfx.py`（客观判定）去兜底，
于是"设计"与"校准"两件事可以分别改、分别验。

## 一、为什么"三音禁忌"是本项目音效设计的硬约束

游戏里音效与音乐是**同时响**的。音乐有明确的调（见 `music_manifest.json`）：

    menu_title D 大调   field_day D 大调   field_night B 小调
    village    G 大调   interior  F 大调   strategic   C 大调
    battle     D 小调   sting_victory D 大调   sting_defeat B 小调

一个**偶发**音效（生命周期、UI）可能在任意一首曲子下触发。若它带明确的大/小
三音，就会和当时的和声打架。做法：

  * **调心取 D**：六首曲子里三首以 D 为中心，B 小调是 D 大调的平行小调，
    剩下 G/F/C 大调里 D 与 A 也都是调内音。
  * **偶发音效只取 1 度与 5 度（D 与 A），不含三音**。纯五度/八度在
    D 大调、D 小调、G 大调、B 小调、F 大调、C 大调上**全部协和**——这是
    "在不知道当时播哪首曲子"的前提下唯一站得住的选择。
  * **三音只出现在"场景确定"的战斗 sting 里**：胜利时接着响的 BGM 是
    D 大调（用 F#），出征/失败是 D 小调（用 F）。战场语义确定，才敢用三音。

## 二、变体不是"同一个音换音量"

同一事件的多个变体如果只是音量/音高微差，密集触发时会听成"机关枪"——这正是
本项目采集音三变体要解决的问题。所以每个变体的**谱质心与时长**都被刻意拉开
（门槛是 `post.DISTINCT_FEATURES` 与 `post.variant_diff()`，`qa_sfx.py --check`
会逐对计算并判定），且差异来自
"材质/动作的真实变化"（不同的模态比例、不同的共振峰、不同的动作时长），
不是随机抖动。

## 三、时长规则（**所有衰减统一用 exp**）

交付件会被 `post.trim_to_event()` 裁到"衰减到 -60dB（相对峰值）"为止。所以
设计时长 T 与衰减时间常数 τ 是同一件事：

    τ = T / 6.908          （`tau_for()`；6.908 = 60/20·ln10）

**不要**用"往缓冲里填静音"实现时长：那会让事件响度被静音稀释（见 `post.py`
模块头 §一）。也**不要**换用 `synth.decay_env(curve="power")`：那条曲线的
-60dB 出现在 30.62τ，同样一个 τ 会得到 4.4 倍的时长（踩过，见 decay_env 的注释）。

每个 build 里的 `T_*` 常量就是该成分"响到 -60dB"的秒数；最慢的那个成分决定
最终裁剪长度，也决定 `dur_ms` 质检窗口。
"""
from __future__ import annotations

import math
import zlib
from dataclasses import dataclass
from typing import Callable

import numpy as np

from . import synth as SYN

_LN10 = math.log(10.0)


# ─────────────────────────────── 基础工具 ──────────────────────────────

def tau_for(dur_ms: float, db: float = 60.0) -> float:
    """按"衰减到 -db（相对峰值）所需时长"反推 exp 时间常数 τ。见模块头 §三。"""
    return (dur_ms / 1000.0) / (db / 20.0 * _LN10)


def seed_of(name: str, index: int = 0) -> int:
    """确定性 seed：同 (文件, 变体号) → 同结果（`gen_sfx.py` 幂等的基础）。

    用 CRC32 而不是 Python 的 `hash()`：后者对 str 加了每进程随机盐，
    跨进程不稳定，会让"同 seed 同结果"这条承诺在两次运行间失效。
    """
    return zlib.crc32(("%s#%d" % (name, index)).encode("utf-8")) & 0x7FFFFFFF


# ─────────────────────────── 响度分层（核心设计）──────────────────────────

## 分层：类别 → 事件响度 L_evt 目标（dB）。理由写在同一行，是设计决策不是调参。
LOUDNESS_LAYERS = {
    # ① UI 反馈 —— 最轻。它是"最高频"的反馈（鼠标扫过一排按钮会连响十几次），
    #    任何一次响都不该打断玩家；同时它离耳朵最近（界面音无距离感），
    #    所以数值上要比"场景里的声音"低一档。
    "ui":            -25.0,
    # ② 采集反馈 —— 中等。玩家主动触发、需要即时确认，但同样高频
    #    （按住采集会连响），且和音乐的中频区重叠，所以压在音乐（-15）之下 5dB。
    "harvest":       -20.0,
    # ③ 战斗 sting —— 最响。它必须盖过音乐才是"宣告"；代价是**时长短**
    #    （0.5~2 秒），且只在战斗这一瞬间出现，不会长期占着听觉。
    "battle":        -15.0,
    # ④ 战斗单位拟音（受击/挥击/倒地/格挡）—— 比 sting 低 3dB：它们**密集**
    #    （一场战斗几百次），必须给"整体不糊"留余量。
    "combat_fx":     -18.0,
    # ⑤ 生命周期 —— 低频但重要。它们**与音乐同时响**，所以不压过音乐：
    #    目标是"听得清仪式感、但音乐仍是主角"。
    "lifecycle":     -20.0,
    # ⑥ 环境/装饰音 —— 最轻，且常被引擎按距离/强度再缩放。
    "ambient":       -24.0,
}


def layer_of(category: str) -> float:
    return LOUDNESS_LAYERS[category]


# ─────────────────────────────── 配方结构 ──────────────────────────────

@dataclass(frozen=True)
class Recipe:
    event: str                 # AudioManager.SFX_EVENTS 的 key（或动画事件名）
    files: tuple               # 输出文件名（不含 .wav），长度 = 变体数
    category: str              # 见 LOUDNESS_LAYERS
    what: str                  # 这是什么声音（人话）
    components: tuple          # 由哪几个成分构成
    why: str                   # 为什么这么设计
    dur_ms: tuple              # 质检时长窗口（裁剪后）
    band_center: float         # 频段重心（设计意图，用于人工核对）
    key: str                   # 与音乐调式的关系
    overlap: str               # 重叠策略（可否与自身/音乐重叠）
    build: Callable[[int, int], np.ndarray]
    tone: tuple = ()           # 音色整形（post.apply_tone 的算子表）
    rev: tuple = None          # (mix, style, rt60)
    width: float = 0.0         # 立体声宽度 0=双单声道
    clip: tuple = None         # (drive, mix) 软削峰，用于收敛峰均比
    tp: float = -1.2           # 真峰值上限（≥ 交付要求 -1.0，留 0.2dB 工程余量）
    node: str = "audio_manager"  # 接线归属：audio_manager / weapon_mount
    max_s: float = None        # 渲染缓冲上限（默认按设计时长 ×1.7）


# ────────────────────────────────────────────────────────────────────────
#  ① UI 三件套 —— 最高频，最影响手感
# ────────────────────────────────────────────────────────────────────────

def _b_ui_hover(fs: int, seed: int) -> np.ndarray:
    """成分：① 6ms 带通噪声瞬态（触碰点）② 1.5k/2.25k 两个极短模态（"粒"感）
    ③ 4.5–9.5kHz 一丝气声。T≈58ms。"""
    buf = SYN.buffer(0.075, fs)
    SYN.place(buf, SYN.tick(0.010, fs, seed, lo=2400, hi=6500, tau=0.0040,
                            rms=0.55), 0.0, fs)
    SYN.place(buf, SYN.modal([1500.0, 2250.0], [tau_for(58.0), tau_for(40.0)],
                             [1.0, 0.40], 0.070, fs, seed), 0.0, fs, gain=0.40)
    SYN.place(buf, SYN.tick(0.014, fs, seed + 3, lo=4500, hi=9500, tau=0.0045,
                            rms=0.10), 0.0, fs)
    return SYN.fade_edges(buf, fs, 0.4, 2.5)


def _b_ui_click(fs: int, seed: int) -> np.ndarray:
    """成分：① 5ms 高通瞬态（"咔"）② D5 带 3% 下滑音 + 上方纯五度分音
    ③ D4 短垫（"实在感"）。T≈95ms。"""
    buf = SYN.buffer(0.14, fs)
    SYN.place(buf, SYN.tick(0.007, fs, seed, lo=1500, hi=9000, tau=0.0032,
                            rms=1.00), 0.0, fs)
    SYN.place(buf, SYN.glide_tone(587.33, 566.0, 0.11, fs,
                                  tau=tau_for(95.0), glide=0.18,
                                  partials=((1.0, 1.0, 1.0), (1.5, 0.42, 0.62),
                                            (2.0, 0.18, 0.45))),
              0.0, fs, gain=0.72)
    SYN.place(buf, SYN.glide_tone(293.66, 285.0, 0.07, fs, tau=tau_for(70.0),
                                  glide=0.18),
              0.0, fs, gain=0.16)
    return SYN.fade_edges(buf, fs, 0.4, 3.0)


def _b_ui_confirm(fs: int, seed: int) -> np.ndarray:
    """成分：① FM 铃 D5 ② 70ms 后 FM 铃 A5 ③ 低声部 D4 轻垫 ④ 起音气声。
    D→A 是**纯五度上行**，不含三音（见模块头 §一）。T≈300ms。"""
    buf = SYN.buffer(0.36, fs)
    SYN.place(buf, SYN.fm_bell(587.33, 0.32, fs, ratio=3.5, index=2.2,
                               tau=tau_for(230.0), tau_mod=0.045), 0.0, fs)
    SYN.place(buf, SYN.fm_bell(880.00, 0.30, fs, ratio=3.2, index=1.7,
                               tau=tau_for(230.0), tau_mod=0.040), 0.070, fs,
              gain=0.75)
    SYN.place(buf, SYN.glide_tone(293.66, 293.66, 0.20, fs, tau=tau_for(150.0),
                                  glide=1.0), 0.0, fs, gain=0.22)
    SYN.place(buf, SYN.tick(0.010, fs, seed, lo=3200, hi=9000, tau=0.0035,
                            rms=0.22), 0.0, fs)
    return SYN.fade_edges(buf, fs, 0.6, 4.0)


def _b_ui_denied(fs: int, seed: int) -> np.ndarray:
    """成分：① 7ms 低中频瞬态（600–4.5k，"拦下"的接触点）② 165/250/391Hz
    **非谐**模态闷击（无明确音高）③ 90ms 后一次更轻、更低的第二击
    ④ 一层 400–1.8k 暗噪声给空气感。T≈90ms（第二击 T≈70ms）。

    "不行"与 `ui_click` 的"确定"必须在**音区与音高性**上分开，而不是靠更响：
    click 是 1.8kHz 质心、亮而短、有明确音高的"按下"；denied 是 500Hz 以下的
    两次下行闷击，**不含明确音高**（165/250/391 = 1/1.52/2.37 非谐比，模态堆
    不成谐波列）、也没有高频瞬态。因此两者不会被互相误认。

    为什么不用蜂鸣器（1~4kHz 方波）：那是"刺耳负反馈"的刻板印象，恰好占用
    本项目最敏感的 2–5kHz、也最容易在连续误操作时疲劳；闷击式的否决更接近
    "门被关上"，语义同样清楚而听觉负担低。响度取 UI 层（-25），与 hover/click
    同层——它是**同频次**的反馈（误操作会连点），不该比点击更响。
    """
    dur = 0.24
    buf = SYN.buffer(dur, fs)
    SYN.place(buf, SYN.tick(0.007, fs, seed, lo=600, hi=4500, tau=0.0026,
                            rms=0.70), 0.0, fs)
    SYN.place(buf, SYN.modal([165.0, 250.0, 391.0],
                             [tau_for(90.0), tau_for(62.0), tau_for(38.0)],
                             [1.0, 0.52, 0.28], 0.14, fs, seed), 0.0, fs,
              gain=0.50)
    SYN.place(buf, SYN.thud(150.0, 96.0, 0.12, fs, tau=tau_for(85.0),
                            body=0.45, seed=seed + 5), 0.0, fs, gain=0.34)
    SYN.place(buf, SYN.tick(0.008, fs, seed + 11, lo=500, hi=3600, tau=0.0030,
                            rms=0.55), 0.090, fs, gain=0.75)
    SYN.place(buf, SYN.modal([132.0, 198.0, 300.0],
                             [tau_for(70.0), tau_for(46.0), tau_for(28.0)],
                             [1.0, 0.50, 0.26], 0.10, fs, seed + 2), 0.090, fs,
              gain=0.34)
    SYN.place(buf, SYN.band_noise(0.10, fs, seed + 9, 400.0, 1800.0,
                                  color="pink")
              * SYN.perc_env(int(0.10 * fs), fs, 0.004, tau_for(70.0)),
              0.0, fs, gain=0.14)
    return SYN.fade_edges(buf, fs, 0.5, 3.0)


# ────────────────────────────────────────────────────────────────────────
#  ② 采集五件套 —— 石（三变体）/ 木 / 入账
# ────────────────────────────────────────────────────────────────────────

def _stone_hit(fs: int, seed: int, base: float, ratios, taus, amps,
               low_body: float = 0.0, micro=(), dur: float = 0.10,
               tr=(2400.0, 11000.0, 0.0020, 0.90),
               grit=(1200.0, 6000.0, 40.0, 0.16)) -> np.ndarray:
    """石材敲击：① 高频瞬态（接触点）② **非谐模态堆**（石头的"硬"）
    ③ 宽带碎屑噪声 ④ 可选低频体量 ⑤ 可选微瞬态（碎裂感）。

    非谐比例（ratios 不是 1,2,3,4）是"石头"与"木琴"的分水岭：整数倍分音 =
    有音高（木/金属有明确音高），非谐 = 噪声性音色（石头/陶器）。
    `grit` 的第三项是碎屑层的 **T（响到 -60dB 的毫秒数）**，不是 τ。
    """
    buf = SYN.buffer(dur, fs)
    SYN.place(buf, SYN.tick(0.007, fs, seed, lo=tr[0], hi=tr[1], tau=tr[2],
                            rms=tr[3]), 0.0, fs)
    SYN.place(buf, SYN.modal([base * r for r in ratios], taus, amps, dur, fs,
                             seed), 0.0, fs, gain=0.55)
    n_grit = int(grit[2] / 1000.0 * 3.0 * fs)
    SYN.place(buf, SYN.band_noise(n_grit / fs, fs, seed + 11, grit[0], grit[1])
              * SYN.perc_env(n_grit, fs, 0.0006, tau_for(grit[2])),
              0.0, fs, gain=grit[3])
    if low_body > 0:
        SYN.place(buf, SYN.thud(150.0, 120.0, 0.09, fs, tau=tau_for(45.0),
                                body=0.5, seed=seed + 5), 0.0, fs,
                  gain=low_body)
    for i, (at, g) in enumerate(micro):
        SYN.place(buf, SYN.tick(0.014, fs, seed + 31 + i, lo=1800, hi=8000,
                                tau=0.0035, rms=0.5), at, fs, gain=g)
    return SYN.fade_edges(buf, fs, 0.3, 3.0)


def _b_hit_a(fs, seed):
    """变体 a「脆片」：基频 3300Hz、非谐、最慢模态 T=62ms → 高 / 短 / 亮。
    语义 = 小石子被敲掉一角。"""
    return _stone_hit(fs, seed, base=3300.0, ratios=(1.0, 1.72, 2.41, 3.16),
                      taus=(tau_for(62.0), tau_for(42.0), tau_for(28.0),
                            tau_for(18.0)),
                      amps=(1.0, 0.62, 0.36, 0.22), dur=0.10)


def _b_hit_b(fs, seed):
    """变体 b「钝撞」：基频 1750Hz + 低频体量、最慢模态 T=100ms → 低 / 较长 /
    有体积。语义 = 锄头砸在岩壁上（有回弹的闷响，不是脆裂）。"""
    return _stone_hit(fs, seed, base=1750.0, ratios=(1.0, 1.41, 2.06, 2.83),
                      taus=(tau_for(100.0), tau_for(68.0), tau_for(44.0),
                            tau_for(27.0)),
                      amps=(1.0, 0.55, 0.30, 0.18), low_body=0.42, dur=0.16,
                      tr=(1200.0, 7000.0, 0.0026, 0.80),
                      grit=(900.0, 5000.0, 55.0, 0.20))


def _b_hit_c(fs, seed):
    """变体 c「破碎」：基频 2500Hz、模态振幅更平（宽带感）+ 3 个微瞬态
    → 颗粒感 / 碎裂感。语义 = 矿脉崩落（一次动作里有多下）。最慢模态 T=135ms。"""
    return _stone_hit(fs, seed, base=2500.0, ratios=(1.0, 1.63, 2.20, 2.94, 3.70),
                      taus=(tau_for(135.0), tau_for(92.0), tau_for(60.0),
                            tau_for(38.0), tau_for(24.0)),
                      amps=(1.0, 0.80, 0.65, 0.50, 0.35), dur=0.20,
                      tr=(2000.0, 9500.0, 0.0018, 0.75),
                      grit=(1100.0, 6500.0, 70.0, 0.18),
                      micro=((0.016, 0.45), (0.044, 0.32), (0.074, 0.22)))


def _b_harvest_wood(fs: int, seed: int) -> np.ndarray:
    """成分：① 斧刃入木的高频瞬态 ② **木体模态**（288/342/430Hz，空腔音高感）
    ③ 1.15kHz 木质敲击模态 ④ 木屑噪声 ⑤ 低频体量。T≈300ms。

    木头与石头的可听分水岭不是"频率高低"而是：木头有**成组的低中频共振**
    （中空的箱体）+ 明显更长的衰减（300ms vs 石头 62~135ms）。288~430Hz 这一组
    落在 D4 下方、与音乐调心同族，所以砍树声"进得了"音乐而不是杂音。
    """
    dur = 0.40
    buf = SYN.buffer(dur, fs)
    SYN.place(buf, SYN.tick(0.008, fs, seed, lo=800, hi=4500, tau=0.0030,
                            rms=1.0), 0.0, fs)
    SYN.place(buf, SYN.modal([288.0, 342.0, 430.0],
                             [tau_for(375.0), tau_for(260.0), tau_for(175.0)],
                             [1.0, 0.60, 0.34], dur, fs, seed), 0.0, fs,
              gain=0.42)
    SYN.place(buf, SYN.glide_tone(1150.0, 1060.0, 0.20, fs, tau=tau_for(150.0),
                                  glide=0.18,
                                  partials=((1.0, 1.0, 1.0), (2.38, 0.30, 0.5))),
              0.0, fs, gain=0.30)
    SYN.place(buf, SYN.band_noise(0.11, fs, seed + 9, 1500, 5500)
              * SYN.perc_env(int(0.11 * fs), fs, 0.0008, tau_for(45.0)),
              0.0, fs, gain=0.20)
    SYN.place(buf, SYN.thud(185.0, 150.0, 0.28, fs, tau=tau_for(140.0),
                            body=0.4, seed=seed + 13), 0.0, fs, gain=0.30)
    return SYN.fade_edges(buf, fs, 0.4, 4.0)


def _b_harvest_gain(fs: int, seed: int) -> np.ndarray:
    """成分：① 金属模态 D6+A6 ② 4.2kHz 非谐金属分音 ③ 起音高频"亮片"
    ④ D4 轻垫。T≈150ms。

    "入账"要"爽"但不能是硬币声（那是 Terraria Coin 的语义，也正是要替换掉的
    提取件）。用**两声高音金属 + 一丝亮片**做"登记入册"的通用听觉符号；
    频率落在 1.2k/1.8k 而不是 3~5kHz，把刺耳敏感区让给音乐。
    """
    dur = 0.20
    buf = SYN.buffer(dur, fs)
    SYN.place(buf, SYN.glide_tone(1174.66, 1150.0, dur, fs, tau=tau_for(150.0),
                                  glide=0.09,
                                  partials=((1.0, 1.0, 1.0), (1.5, 0.42, 0.60),
                                            (2.98, 0.16, 0.34))),
              0.0, fs)
    SYN.place(buf, SYN.glide_tone(1760.0, 1740.0, dur, fs, tau=tau_for(100.0),
                                  glide=0.09,
                                  partials=((1.0, 1.0, 1.0), (1.5, 0.30, 0.5))),
              0.012, fs, gain=0.38)
    SYN.place(buf, SYN.tick(0.007, fs, seed, lo=5000, hi=12000, tau=0.0026,
                            rms=0.28), 0.0, fs)
    SYN.place(buf, SYN.glide_tone(293.66, 293.66, 0.06, fs, tau=tau_for(45.0),
                                  glide=1.0), 0.0, fs, gain=0.14)
    return SYN.fade_edges(buf, fs, 0.4, 3.0)


# ────────────────────────────────────────────────────────────────────────
#  ③ 生命周期四件套 —— 偶尔响但重要，且**与音乐同时响**
# ────────────────────────────────────────────────────────────────────────

def _b_game_started(fs: int, seed: int) -> np.ndarray:
    """成分：① D2 低鼓（膜音下滑）② D4 铃 ③ 230ms 后 A4 铃
    ④ 慢起振的"张开"垫（D3+A3+D4，低通 1.2kHz）⑤ 一层气声。T≈1.45s。

    仪式感的三要素都编码在这里：**有起振时间**（垫 220ms 才到满）、
    **有空间**（10% room 混响）、**有音高结构**（D→A 上行五度）。
    垫只取 1/5/8 度且低通 1.2kHz —— 能量全在 1.2kHz 以下，2kHz 以上让给音乐
    （这是"不打架"的物理做法，不是靠调音量）。
    """
    dur = 1.65
    buf = SYN.buffer(dur, fs)
    SYN.place(buf, SYN.thud(96.0, 66.0, 0.55, fs, tau=tau_for(400.0), body=0.45,
                            seed=seed), 0.0, fs, gain=0.55)
    SYN.place(buf, SYN.fm_bell(293.66, 0.75, fs, ratio=2.0, index=1.3,
                               tau=tau_for(560.0), tau_mod=0.06), 0.090, fs,
              gain=0.50)
    SYN.place(buf, SYN.fm_bell(440.00, 0.90, fs, ratio=2.0, index=1.3,
                               tau=tau_for(1050.0), tau_mod=0.06), 0.230, fs,
              gain=0.46)
    n = len(buf)
    t = np.arange(n) / fs
    pad = np.zeros(n)
    for f, a in ((146.83, 1.0), (220.00, 0.62), (293.66, 0.40)):
        pad += a * np.sin(2.0 * np.pi * f * t)
    pad *= np.clip(t / 0.22, 0, 1) ** 2 * np.exp(-np.maximum(t - 0.22, 0)
                                                / tau_for(1450.0))
    pad = SYN.band_limit(pad, fs, None, 1200.0, order=2)
    buf += SYN.rms_norm(pad, 1.0) * 0.16
    SYN.place(buf, SYN.band_noise(1.2, fs, seed + 7, 400, 2500, color="pink")
              * SYN.perc_env(int(1.2 * fs), fs, 0.16, tau_for(900.0)),
              0.0, fs, gain=0.10)
    return SYN.fade_edges(buf, fs, 1.5, 8.0)


def _b_game_saved(fs: int, seed: int) -> np.ndarray:
    """成分：① A4 铃 ② 90ms 后 D5 铃（上行纯四度，"记下了"）。T≈460ms。

    存档是**系统确认**而非成就，所以时长与响度都应克制：比 quest_done 低 2dB、
    短一半。上行纯四度同为"无三音"音程（模块头 §一）。
    """
    dur = 0.55
    buf = SYN.buffer(dur, fs)
    SYN.place(buf, SYN.fm_bell(440.00, 0.25, fs, ratio=3.0, index=1.5,
                               tau=tau_for(210.0), tau_mod=0.04), 0.0, fs,
              gain=0.70)
    SYN.place(buf, SYN.fm_bell(587.33, 0.45, fs, ratio=3.0, index=1.5,
                               tau=tau_for(370.0), tau_mod=0.04), 0.090, fs)
    SYN.place(buf, SYN.tick(0.008, fs, seed, lo=3000, hi=9000, tau=0.003,
                            rms=0.16), 0.0, fs)
    return SYN.fade_edges(buf, fs, 0.6, 4.0)


def _b_quest_done(fs: int, seed: int) -> np.ndarray:
    """成分：① D5→A5→D6 三音上行铃琶音（90ms 间隔）② 顶层"闪光"分音
    ③ 一丝 room 混响。T≈890ms。

    "完成"的通用听觉符号 = 上行琶音 + 铃音色；三音全部取 1/5/8 度（模块头 §一），
    因此不论当时在播哪首曲子都不会打架。上行比下行"完成感"强（音高的方向性
    是这个语义的直觉载体）。
    """
    dur = 1.05
    buf = SYN.buffer(dur, fs)
    for f, at, t_ms, g in ((587.33, 0.000, 600.0, 1.00),
                           (880.00, 0.090, 600.0, 0.82),
                           (1174.66, 0.180, 840.0, 0.70)):
        SYN.place(buf, SYN.fm_bell(f, dur - at, fs, ratio=3.2, index=1.9,
                                   tau=tau_for(t_ms), tau_mod=0.045),
                  at, fs, gain=g)
    SYN.place(buf, SYN.tick(0.010, fs, seed, lo=5000, hi=11000, tau=0.004,
                            rms=0.14), 0.0, fs)
    return SYN.fade_edges(buf, fs, 0.8, 6.0)


def _b_build_complete(fs: int, seed: int) -> np.ndarray:
    """成分：① 木+石混合的"落定"（240/360/520Hz 木体 + 1.9kHz 石质模态）
    ② 160ms 后 D5+A5 同时响的开口五度铃。T≈800ms。

    "建造完成"有两个听觉要素：**物理落定**（有东西被装上了）+ **完成肯定**
    （一个向上的收束）。分两层先后出现，比一个单点音更能表达"过程结束"——
    这是"阶段完成"与"敲了一下"的区别。第二层用**同时响**的开口五度（不是琶音），
    与 quest_done 的琶音拉开语义。
    """
    dur = 0.95
    buf = SYN.buffer(dur, fs)
    SYN.place(buf, SYN.tick(0.009, fs, seed, lo=700, hi=5000, tau=0.0032,
                            rms=0.9), 0.0, fs)
    SYN.place(buf, SYN.modal([240.0, 360.0, 520.0],
                             [tau_for(300.0), tau_for(200.0), tau_for(120.0)],
                             [1.0, 0.55, 0.32], 0.40, fs, seed), 0.0, fs,
              gain=0.40)
    SYN.place(buf, SYN.modal([1900.0, 2760.0], [tau_for(80.0), tau_for(50.0)],
                             [1.0, 0.5], 0.20, fs, seed + 4), 0.0, fs,
              gain=0.16)
    SYN.place(buf, SYN.fm_bell(587.33, dur - 0.16, fs, ratio=3.0, index=1.7,
                               tau=tau_for(660.0), tau_mod=0.05), 0.160, fs,
              gain=0.55)
    SYN.place(buf, SYN.fm_bell(880.00, dur - 0.16, fs, ratio=3.0, index=1.7,
                               tau=tau_for(740.0), tau_mod=0.05), 0.160, fs,
              gain=0.42)
    return SYN.fade_edges(buf, fs, 0.8, 5.0)


# ────────────────────────────────────────────────────────────────────────
#  ④ 战斗 sting 三件套 —— 场景确定，可以用三音
# ────────────────────────────────────────────────────────────────────────

def _b_battle_started(fs: int, seed: int) -> np.ndarray:
    """成分：① 三支号角 D3→A3→D4（锯齿谐波堆 + 亮度包络 + 颤音）
    ② D1 低鼓 ③ 战场"空气"噪声层 ④ 18% hall 混响。T≈1.45s。

    开战是"宣告"不是"完成"，所以**只取 1/5/8 度（D-A-D）不含三音**——出征曲
    是 D 小调、胜利曲是 D 大调，开口五度在两个调上都站得住；而开战的那一瞬间
    音乐往往还没切到战斗曲，这一点很重要。号角用时间变化的谐波包络
    （慢起振 45ms + 亮度先开后收 + 多支失谐）：纯正弦听起来像电子提示音，
    铜管的判别特征就是这三条。
    """
    dur = 1.60
    buf = SYN.buffer(dur, fs)
    for f, at, g in ((146.83, 0.000, 1.00), (220.00, 0.130, 0.85),
                     (293.66, 0.260, 0.78)):
        v = SYN.saw_voice(f, dur - at, fs, n_harm=24, voices=3, detune_cents=8.0,
                          bright0=900.0, bright_peak=3200.0, attack=0.045,
                          hold=0.50, tau=tau_for(700.0), vib_hz=5.2,
                          vib_cents=8.0, seed=seed + int(f))
        SYN.place(buf, v, at, fs, gain=0.30 * g)
    SYN.place(buf, SYN.thud(46.0, 36.0, 0.70, fs, tau=tau_for(420.0), body=0.5,
                            seed=seed + 3), 0.0, fs, gain=0.26)
    SYN.place(buf, SYN.band_noise(1.4, fs, seed + 21, 300, 2000, color="pink")
              * SYN.perc_env(int(1.4 * fs), fs, 0.20, tau_for(1100.0)),
              0.0, fs, gain=0.10)
    return SYN.fade_edges(buf, fs, 3.0, 10.0)


def _b_battle_win(fs: int, seed: int) -> np.ndarray:
    """成分：① 号角 D4→A4→D5 ② 峰值处叠 F#5（**D 大三和弦**，胜利性质）
    ③ 定音鼓式 D2 ④ 高频闪光 ⑤ 20% hall。T≈1.65s。

    胜利的信息主要由**三音性质**承载：大三=胜利、小三=失败。这里在最响的那一音
    上给出 F#5 —— 而"凯旋"BGM 正是 D 大调（见 music_manifest.json），
    所以 sting 与随后的音乐是同调同和弦，两者叠在一起是加强而不是打架。
    """
    dur = 1.80
    buf = SYN.buffer(dur, fs)
    for f, at, g in ((293.66, 0.000, 0.95), (440.00, 0.140, 0.90),
                     (587.33, 0.290, 1.00)):
        v = SYN.saw_voice(f, dur - at, fs, n_harm=24, voices=3, detune_cents=7.0,
                          bright0=1000.0, bright_peak=3600.0, attack=0.040,
                          hold=0.55, tau=tau_for(800.0), vib_hz=5.5, vib_cents=9.0,
                          seed=seed + int(f))
        SYN.place(buf, v, at, fs, gain=0.28 * g)
    SYN.place(buf, SYN.saw_voice(739.99, dur - 0.42, fs, n_harm=20, voices=2,
                                 detune_cents=5.0, bright0=1400.0,
                                 bright_peak=4200.0, attack=0.03, hold=0.60,
                                 tau=tau_for(620.0), vib_hz=5.5, vib_cents=6.0,
                                 seed=seed + 77), 0.42, fs, gain=0.16)
    SYN.place(buf, SYN.thud(60.0, 44.0, 0.85, fs, tau=tau_for(500.0), body=0.5,
                            seed=seed + 3), 0.0, fs, gain=0.24)
    SYN.place(buf, SYN.tick(0.012, fs, seed + 9, lo=5000, hi=13000, tau=0.005,
                            rms=0.18), 0.42, fs)
    return SYN.fade_edges(buf, fs, 3.0, 10.0)


def _b_victory_fanfare(fs: int, seed: int) -> np.ndarray:
    """成分：① D2 低鼓（膜音下滑，弱）② 铃 D4 → 0.45s A4 → 0.90s D5
    （**慢速**上行，音符间隔 450ms）③ 1.55s 处同时响的 D5+A5 开口五度长铃作收束
    ④ 低通弦垫 D3+A3+D4（0.55s 慢起振）⑤ 一层气声 ⑥ 22% hall 混响。T≈2.55s。

    与 `battle_ended_win`（战斗结算 fanfare）的区别是有意的，三条：

      1. **更庄重**：不再用铜管（`saw_voice`）——铜管的"炸响"是战场宣告的语气；
         通关礼炮改用**铃 + 低通弦垫**（本项目音乐就是 72BPM 钢琴/弦乐/钟琴的
         柔和取向，铃与垫是同一族音色）。
      2. **更完满**：上行不是 140/290ms 的密集三连，而是 450ms 间隔的**慢速**
         琶音 + 终点一次**同时响的开口五度**长铃，把"结束"落在两声一起撤的
         长衰减上（"礼炮"是收束不是冲锋）。
      3. **不与音乐打架**：全程只取 1/5/8 度（D-A-D，**不含三音**）——通关时
         正在播的曲子（可能是战略曲 C 大调或主菜单 D 大调）不确定，开口五度在
         六种调式下都协和；弦垫低通 1.5kHz、气声不取 2kHz 以上，把音乐的
         存在感区（2–5kHz）让出来。响度取 sting 层（-15），靠时长与和声密度
         而不是靠音量压过音乐。
    """
    dur = 2.85
    buf = SYN.buffer(dur, fs)
    SYN.place(buf, SYN.thud(58.0, 42.0, 0.85, fs, tau=tau_for(700.0), body=0.50,
                            seed=seed), 0.0, fs, gain=0.30)
    for f, at, g, t_ms in ((293.66, 0.000, 1.00, 900.0),
                           (440.00, 0.450, 0.88, 900.0),
                           (587.33, 0.900, 0.95, 1000.0)):
        SYN.place(buf, SYN.fm_bell(f, dur - at, fs, ratio=3.0, index=1.7,
                                   tau=tau_for(t_ms), tau_mod=0.06),
                  at, fs, gain=0.42 * g)
    # 收束：同时响的开口五度 D5+A5，长衰减（"礼炮落地"）
    for f, g in ((587.33, 0.34), (880.00, 0.26)):
        SYN.place(buf, SYN.fm_bell(f, 1.30, fs, ratio=2.6, index=1.5,
                                   tau=tau_for(1300.0), tau_mod=0.05),
                  1.55, fs, gain=g)
    # 弦垫：D3+A3+D4（1/5/8），慢起振 + 低通 1.5kHz
    n = len(buf)
    t = np.arange(n) / fs
    pad = np.zeros(n)
    for f, a in ((146.83, 1.0), (220.00, 0.60), (293.66, 0.42)):
        pad += a * np.sin(2.0 * np.pi * f * t)
    pad *= np.clip(t / 0.55, 0, 1) ** 2 \
        * np.exp(-np.maximum(t - 0.55, 0) / tau_for(1800.0))
    pad = SYN.band_limit(pad, fs, None, 1500.0, order=2)
    buf += SYN.rms_norm(pad, 1.0) * 0.15
    SYN.place(buf, SYN.band_noise(1.6, fs, seed + 7, 350, 2200, color="pink")
              * SYN.perc_env(int(1.6 * fs), fs, 0.25, tau_for(1200.0)),
              0.0, fs, gain=0.09)
    return SYN.fade_edges(buf, fs, 2.0, 10.0)


def _b_battle_lose(fs: int, seed: int) -> np.ndarray:
    """成分：① 号角 D4→A3→F3（三音作**经过音**，仅 0.13s）→D3 长音
    ② 落音再向下滑 40 音分（"气泄了"）③ D1 长衰减 ④ 500Hz 以下闷噪声
    ⑤ 暗色 hall 混响。T≈1.9s。

    失败 = 下行 + 小调三音 + 拖长的尾巴。但"折戟"BGM 是 **B 小调（含 F#）**，
    三音若长时间持续就会与它冲突——所以 F 只作 0.13s 的**经过音**，落音回到
    开口五度上的 D，两个调式下都只剩协和音程承重。整体收敛高频（3.2k -3dB）：
    "败者不该刺耳"既是语义，也把 2–5kHz 让给音乐。
    """
    dur = 2.10
    buf = SYN.buffer(dur, fs)
    for f, at, g, hold_ms, t_ms in ((293.66, 0.000, 1.00, 520.0, 1150.0),
                                    (220.00, 0.150, 0.92, 520.0, 1150.0),
                                    (174.61, 0.300, 0.75, 130.0, 190.0)):
        v = SYN.saw_voice(f, dur - at, fs, n_harm=22, voices=3, detune_cents=9.0,
                          bright0=850.0, bright_peak=2600.0, attack=0.050,
                          hold=hold_ms / 1000.0, tau=tau_for(t_ms),
                          vib_hz=4.8, vib_cents=7.0, seed=seed + int(f))
        SYN.place(buf, v, at, fs, gain=0.30 * g)
    SYN.place(buf, SYN.glide_tone(146.83, 143.5, 1.10, fs, tau=tau_for(900.0),
                                  glide=0.45, attack=0.030), 0.450, fs,
              gain=0.40)
    SYN.place(buf, SYN.thud(52.0, 40.0, 1.50, fs, tau=tau_for(950.0), body=0.55,
                            seed=seed + 3), 0.0, fs, gain=0.28)
    SYN.place(buf, SYN.band_noise(1.6, fs, seed + 21, None, 500, color="brown")
              * SYN.perc_env(int(1.6 * fs), fs, 0.25, tau_for(1000.0)),
              0.0, fs, gain=0.14)
    return SYN.fade_edges(buf, fs, 3.0, 12.0)


# ────────────────────────────────────────────────────────────────────────
#  ⑤ 受击三变体 —— 战斗中最频繁，必须"不扎耳 + 不糊"
# ────────────────────────────────────────────────────────────────────────

def _hurt(fs: int, seed: int, f0: float, f0_end: float, formants, breath: float,
          dur_ms: float, thump_gain: float, crack_gain: float) -> np.ndarray:
    """受击 = ① 3ms 撞击瞬态 ② **拟音闷哼**（`phonation`：声带脉冲串 +
    三个共振峰 + 气声）③ 一丝胸口低频。

    **最关键的一条设计决策：能量集中在 300~1.5kHz 的语音带，不在 2~5kHz。**
    一场战斗里受击音会响几百次；2~5kHz 既是人耳最刺耳敏感区，又是音乐的
    "存在感"区（钢琴 2.5kHz 微凸）。把受击音放在语音带，密集触发时它像"人声
    嘈杂"（有生命感），而不是"金属刮擦"（疲劳），音乐也仍然浮得出来。

    用 `phonation` 而不是真人采样：既零版权，又**可控**——真人痛叫的情绪强度
    很难统一，而"三变体各自共振峰不同"可以精确指定。
    """
    dur = dur_ms / 1000.0 * 1.35
    buf = SYN.buffer(dur, fs)
    SYN.place(buf, SYN.tick(0.006, fs, seed, lo=700, hi=6000, tau=0.0022,
                            rms=0.55), 0.0, fs, gain=crack_gain)
    SYN.place(buf, SYN.phonation(dur, fs, seed, f0=f0, f0_end=f0_end,
                                 formants=formants, breath=breath,
                                 attack=0.012, tau=tau_for(dur_ms),
                                 n_harm=28), 0.0, fs, gain=1.0)
    SYN.place(buf, SYN.thud(f0 * 0.55, f0 * 0.42, 0.16, fs, tau=tau_for(70.0),
                            body=0.35, seed=seed + 5), 0.0, fs, gain=thump_gain)
    return SYN.fade_edges(buf, fs, 0.6, 4.0)


def _b_hurt_a(fs, seed):
    """变体 a「呃」（中性闷哼）：基频 210→150Hz，F1 620/F2 1100/F3 2600，
    T≈190ms，气声弱。语义 = 普通步兵挨了一下的本能反应。"""
    return _hurt(fs, seed, 210.0, 150.0,
                 ((620.0, 110.0), (1100.0, 150.0), (2600.0, 240.0)),
                 breath=0.30, dur_ms=190.0, thump_gain=0.22, crack_gain=0.75)


def _b_hurt_b(fs, seed):
    """变体 b「啊」（高而尖）：基频 300→210Hz，F1 800/F2 1300/F3 2900，
    T≈150ms，气声强。语义 = 轻甲/新兵，谱质心比 a 高 300Hz 以上。"""
    return _hurt(fs, seed, 300.0, 210.0,
                 ((800.0, 130.0), (1300.0, 170.0), (2900.0, 260.0)),
                 breath=0.52, dur_ms=150.0, thump_gain=0.14, crack_gain=0.85)


def _b_hurt_c(fs, seed):
    """变体 c「哼」（低而长）：基频 160→115Hz，F1 480/F2 900/F3 2300，
    T≈260ms，气声中等 + 胸腔低频更重。语义 = 重甲/老兵，闷而沉。"""
    return _hurt(fs, seed, 160.0, 115.0,
                 ((480.0, 90.0), (900.0, 130.0), (2300.0, 220.0)),
                 breath=0.38, dur_ms=260.0, thump_gain=0.36, crack_gain=0.60)


# ────────────────────────────────────────────────────────────────────────
#  ⑥ 武器拟音（原 SWL 提取件，同一批替换）
# ────────────────────────────────────────────────────────────────────────

def _whoosh(fs: int, seed: int, f_from: float, f_mid: float, f_to: float,
            dur_ms: float, bend: float, air: float, body: float) -> np.ndarray:
    """挥击风声 = ① 扫频带通噪声（空气被划开）② 中频"布/皮"摩擦层
    ③ 一点低频位移感。T = dur_ms（扫频层自身的衰减正好在缓冲末尾到 -60dB）。

    时长与中心频率轨迹是四个变体的差异来源：**不同的武器/挥法**——短而高的
    是匕首急挥，长而低的是大剑横扫。这比"同一个风声调音量"在连续战斗中
    耐听得多。风声本身无音高，不与音乐调式冲突。
    """
    dur = dur_ms / 1000.0
    buf = SYN.buffer(dur * 1.45, fs)
    # 扫频层自身取 1.2×设计时长：10ms-RMS 包络天然比样点包络短一截，
    # 这样"设计时长"与"裁剪后实测时长"才对得上（见 post.trim_to_event）。
    sw = dur * 1.2
    SYN.place(buf, SYN.sweep_band_noise(sw, fs, seed, f_from=f_from,
                                       f_mid=f_mid, f_to=f_to, bend=bend,
                                       bands=9, bw_oct=0.8, attack=0.045,
                                       tau=tau_for(sw * 1000.0), rms=0.8),
              0.0, fs)
    n_air = int(dur * 0.85 * fs)
    SYN.place(buf, SYN.band_noise(n_air / fs, fs, seed + 17, 500.0, 2500.0,
                                  color="pink")
              * SYN.perc_env(n_air, fs, 0.06, tau_for(dur_ms * 0.9)),
              0.0, fs, gain=air)
    n_bd = int(dur * 0.8 * fs)
    SYN.place(buf, SYN.band_noise(n_bd / fs, fs, seed + 29, None, 320.0,
                                  color="brown")
              * SYN.perc_env(n_bd, fs, 0.07, tau_for(dur_ms * 1.0)),
              0.0, fs, gain=body)
    return SYN.fade_edges(buf, fs, 4.0, 8.0)


def _b_swoosh_a(fs, seed):
    """a：短而高（匕首急挥）—— 中心 2600→500→1300Hz，T≈340ms。"""
    return _whoosh(fs, seed, 2600.0, 500.0, 1300.0, 340.0, 0.38, 0.10, 0.12)


def _b_swoosh_b(fs, seed):
    """b：中速（单手剑）—— 中心 1900→380→950Hz，T≈430ms。"""
    return _whoosh(fs, seed, 1900.0, 380.0, 950.0, 430.0, 0.42, 0.12, 0.16)


def _b_swoosh_c(fs, seed):
    """c：低而长（大剑横扫）—— 中心 1300→260→700Hz，T≈540ms，低频位移感最重。"""
    return _whoosh(fs, seed, 1300.0, 260.0, 700.0, 540.0, 0.46, 0.14, 0.24)


def _b_swoosh_d(fs, seed):
    """d：极短而亮（盾击/棍棒）—— 中心 3200→700→1600Hz，T≈250ms，气声多。"""
    return _whoosh(fs, seed, 3200.0, 700.0, 1600.0, 250.0, 0.34, 0.18, 0.08)


def _b_headbutt(fs: int, seed: int) -> np.ndarray:
    """矛兵冲撞 = ① **骨/头盔碰撞**的硬瞬态（2.2k/3.4k/5.2k 非谐模态，短）
    ② 重低频闷响（身体撞上盾/甲的位移）③ 摩擦噪声。T≈340ms。

    与 `thump`（倒地）的区别是"硬"：冲撞是**两件硬物互撞**（高瞬态 + 短的高频
    模态），倒地是**身体落地**（低频衰减长 + 无高频瞬态）。这个区分让"打到了"
    与"倒下了"在听觉上完全不同。
    """
    dur = 0.50
    buf = SYN.buffer(dur, fs)
    SYN.place(buf, SYN.tick(0.009, fs, seed, lo=1200, hi=9000, tau=0.0030,
                            rms=1.40), 0.0, fs)
    SYN.place(buf, SYN.modal([2200.0, 3400.0, 5200.0],
                             [tau_for(70.0), tau_for(45.0), tau_for(28.0)],
                             [1.0, 0.55, 0.30], 0.20, fs, seed), 0.0, fs,
              gain=0.50)
    SYN.place(buf, SYN.thud(120.0, 72.0, 0.48, fs, tau=tau_for(380.0), body=0.55,
                            seed=seed + 5), 0.0, fs, gain=0.60)
    SYN.place(buf, SYN.band_noise(0.08, fs, seed + 9, 900, 4000)
              * SYN.perc_env(int(0.08 * fs), fs, 0.001, tau_for(30.0)),
              0.0, fs, gain=0.16)
    return SYN.fade_edges(buf, fs, 0.6, 5.0)


def _b_magikill_a(fs: int, seed: int) -> np.ndarray:
    """法术 a「轰」= ① 上冲的能量扫频 ② 爆破低频 ③ 高频闪烁簇。T≈1.15s。

    法术音与物理打击音的分水岭是**没有高频瞬态**：能量是"涨上来"的
    （90ms 起振），而不是"啪一下接触"。同时用非谐的闪烁簇做"魔法"色彩，
    避免听起来像爆炸。
    """
    dur = 1.30
    buf = SYN.buffer(dur, fs)
    SYN.place(buf, SYN.sweep_band_noise(1.15, fs, seed, f_from=260.0,
                                       f_mid=2400.0, f_to=600.0, bend=0.42,
                                       bands=10, bw_oct=0.85, attack=0.090,
                                       tau=tau_for(1150.0), rms=0.75), 0.0, fs)
    SYN.place(buf, SYN.thud(88.0, 52.0, 0.85, fs, tau=tau_for(450.0), body=0.5,
                            seed=seed + 5), 0.28, fs, gain=0.70)
    SYN.place(buf, SYN.modal([3140.0, 4780.0, 6960.0, 9200.0],
                             [tau_for(160.0), tau_for(120.0), tau_for(80.0),
                              tau_for(45.0)],
                             [1.0, 0.72, 0.5, 0.34], 0.6, fs, seed + 3), 0.0,
              fs, gain=0.055)
    return SYN.fade_edges(buf, fs, 2.0, 8.0)


def _b_magikill_b(fs: int, seed: int) -> np.ndarray:
    """法术 b「吟」= ① 连续上升的亮扫频（吟唱积蓄）② 高处金属闪烁
    ③ 结束时一个短的低频落定。T≈1.45s。

    与 a 的差异是**时间方向相反**：a 是"能量冲上去然后炸开"，b 是"持续积蓄
    然后收束"。两者共享同一套原语，所以不会听起来像两个游戏。
    """
    dur = 1.65
    buf = SYN.buffer(dur, fs)
    SYN.place(buf, SYN.sweep_band_noise(1.25, fs, seed, f_from=420.0,
                                       f_mid=700.0, f_to=2400.0, bend=0.72,
                                       bands=10, bw_oct=0.7, attack=0.22,
                                       tau=tau_for(1250.0), rms=0.70), 0.0, fs)
    SYN.place(buf, SYN.modal([3000.0, 4520.0, 6580.0],
                             [tau_for(240.0), tau_for(180.0), tau_for(120.0)],
                             [1.0, 0.6, 0.38], 0.8, fs, seed + 3), 0.0, fs,
              gain=0.045)
    SYN.place(buf, SYN.thud(70.0, 52.0, 0.55, fs, tau=tau_for(300.0), body=0.5,
                            seed=seed + 5), 1.12, fs, gain=0.45)
    return SYN.fade_edges(buf, fs, 2.0, 8.0)


def _b_thump(fs: int, seed: int, f0: float, f1: float, tau_ms: float,
             body: float, cloth: float) -> np.ndarray:
    """倒地闷响 = ① 低频膜音下滑 ② 低频体（软组织的"钝"）
    ③ 一丝衣物/甲片摩擦。T = tau_ms。

    这是"身体落地"的声音：**没有高频成分**（肉/布撞击不产生高频瞬态），
    能量集中在 40~250Hz。两变体靠基频与衰减时长区分（矮个/高个、轻甲/重甲）。
    """
    dur = tau_ms / 1000.0 * 1.5
    buf = SYN.buffer(dur, fs)
    SYN.place(buf, SYN.thud(f0, f1, dur * 0.9, fs, tau=tau_for(tau_ms),
                            body=body, seed=seed), 0.0, fs, gain=0.9)
    n_cl = int(dur * 0.5 * fs)
    SYN.place(buf, SYN.band_noise(n_cl / fs, fs, seed + 9, 300, 2200,
                                  color="pink")
              * SYN.perc_env(n_cl, fs, 0.008, tau_for(60.0)), 0.0, fs,
              gain=cloth)
    return SYN.fade_edges(buf, fs, 1.0, 6.0)


def _b_thump_a(fs, seed):
    """a：更低更长（重甲落地）—— 62→40Hz，T≈400ms。"""
    return _b_thump(fs, seed, 62.0, 40.0, 400.0, body=0.55, cloth=0.10)


def _b_thump_b(fs, seed):
    """b：更高更紧（轻甲/敏捷兵）—— 84→58Hz，T≈250ms。"""
    return _b_thump(fs, seed, 84.0, 58.0, 250.0, body=0.42, cloth=0.16)


def _b_bodyfall(fs: int, seed: int, f0: float, tau_ms: float, rustle: float,
                bounce_ms: float) -> np.ndarray:
    """尸体落地 = ① 首次触地闷响 ② **一次小反弹**（第二下更轻更短）
    ③ 布/肢体摊开的摩擦声。

    与 `thump` 的差别就是**第二下**：人倒下后身体会摊开/轻微回弹，只响一下是
    "沙袋落地"，响两下才是"人倒下"。第二下的延迟（110/150/230ms）与摩擦声量
    是三个变体的差异来源——即"怎么倒的"。
    """
    dur = (tau_ms + bounce_ms + 240.0) / 1000.0
    buf = SYN.buffer(dur, fs)
    SYN.place(buf, SYN.thud(f0, f0 * 0.66, dur * 0.85, fs, tau=tau_for(tau_ms),
                            body=0.55, seed=seed), 0.0, fs, gain=0.95)
    SYN.place(buf, SYN.thud(f0 * 0.9, f0 * 0.6, 0.30, fs,
                            tau=tau_for(tau_ms * 0.5), body=0.45,
                            seed=seed + 3), bounce_ms / 1000.0, fs, gain=0.55)
    n_rs = int(dur * 0.55 * fs)
    SYN.place(buf, SYN.band_noise(n_rs / fs, fs, seed + 9, 400, 2800,
                                  color="pink")
              * SYN.perc_env(n_rs, fs, 0.020, tau_for(90.0)),
              bounce_ms / 1000.0 * 0.6, fs, gain=rustle)
    return SYN.fade_edges(buf, fs, 1.5, 6.0)


def _b_bodyfall_a(fs, seed):
    """a：一次干脆的倒下，反弹早而轻。T≈290ms。"""
    return _b_bodyfall(fs, seed, 78.0, 280.0, rustle=0.14, bounce_ms=150.0)


def _b_bodyfall_b(fs, seed):
    """b：更重更长（重甲/盾牌一起落地），反弹晚而实。T≈450ms。"""
    return _b_bodyfall(fs, seed, 62.0, 420.0, rustle=0.10, bounce_ms=230.0)


def _b_bodyfall_c(fs, seed):
    """c：轻而闷（轻甲/远处），摩擦声最多，反弹最早。T≈250ms。"""
    return _b_bodyfall(fs, seed, 96.0, 220.0, rustle=0.22, bounce_ms=110.0)


def _b_clang(fs: int, seed: int, base: float, ratios, taus, amps,
             bright: float, seed_grit: float, dur_ms: float,
             tick_rms: float = 0.95) -> np.ndarray:
    """金属格挡 = ① 高频金属瞬态 ② **非谐金属模态堆**（金属的"叮"）
    ③ 金属噪声碎屑（刃面摩擦）。

    金属与石头的分水岭是**衰减时长**（金属模态损耗极低，响半秒以上）以及
    **更高的非谐比例族**（1/1.73/2.44/3.21 = 理想棒振动比例）。两变体按
    "高亢的刃击"与"低闷的盾击"区分。
    """
    dur = dur_ms / 1000.0 * 1.6
    buf = SYN.buffer(dur, fs)
    SYN.place(buf, SYN.tick(0.008, fs, seed, lo=1500, hi=13000, tau=0.0022,
                            rms=tick_rms), 0.0, fs)
    SYN.place(buf, SYN.modal([base * r for r in ratios], taus, amps,
                             dur_ms / 1000.0 * 1.4, fs, seed), 0.0, fs,
              gain=bright)
    SYN.place(buf, SYN.band_noise(0.08, fs, seed + 11, 2500, 11000)
              * SYN.perc_env(int(0.08 * fs), fs, 0.0006, tau_for(35.0)),
              0.0, fs, gain=seed_grit)
    return SYN.fade_edges(buf, fs, 0.4, 5.0)


def _b_clang_a(fs, seed):
    """a：高亢的刃击（剑格挡）—— 基频 1850Hz，非谐比例族，最慢模态 T≈700ms。"""
    return _b_clang(fs, seed, 1850.0, (1.0, 1.73, 2.44, 3.21),
                    (tau_for(700.0), tau_for(460.0), tau_for(285.0),
                     tau_for(175.0)),
                    (1.0, 0.62, 0.40, 0.26), bright=0.26, seed_grit=0.20,
                    dur_ms=560.0, tick_rms=0.95)


def _b_clang_b(fs, seed):
    """b：低闷的盾击 —— 基频 980Hz，比例族更密，最慢模态 T≈520ms，噪声更多。"""
    return _b_clang(fs, seed, 980.0, (1.0, 1.61, 2.31, 3.05, 3.92),
                    (tau_for(520.0), tau_for(350.0), tau_for(230.0),
                     tau_for(140.0), tau_for(90.0)),
                    (1.0, 0.72, 0.5, 0.34, 0.22), bright=0.34, seed_grit=0.26,
                    dur_ms=420.0, tick_rms=0.55)


# ─────────────────────────────── 配方表 ─────────────────────────────────

def _R(**kw) -> Recipe:
    """配方构造：音色整形/接线归属等按类别给默认值，减少重复。"""
    cat = kw["category"]
    kw.setdefault("dur_ms", (40.0, 3000.0))
    kw.setdefault("band_center", 1500.0)
    kw.setdefault("key", "D 调心，1/5 度（不含三音）")
    kw.setdefault("overlap", "允许重叠（同事件重触发由 AudioManager 停旧实例）")
    kw.setdefault("max_s", max(kw["dur_ms"][1] * 1.7 / 1000.0, 0.35))
    if cat in ("ui", "harvest"):
        # UI 与采集是"耳边/手上"的动作：**干燥**（几乎无混响）比什么都重要，
        # 一点混响就会让连击糊成一片，也让"点击"听起来慢半拍。
        kw.setdefault("rev", (0.03, "room", 0.55))
    return Recipe(**kw)


RECIPES: tuple = (
    # ── ① UI 三件套 ────────────────────────────────────────────────────
    _R(event="ui_hover", files=("ui_hover",), category="ui", node="audio_manager",
       what="鼠标扫过一个可交互项时的一粒微响（触碰感，不是音）",
       components=("6ms 带通噪声瞬态（2.4–6.5k）",
                   "1.5k/2.25k 两个极短模态（'粒'感）",
                   "4.5–9.5k 一丝气声"),
       why="hover 是最高频操作（扫过一排按钮会连响十几次），所以必须'存在但"
           "不打断'：用极短噪声给触碰感，**刻意不给明确音高**（有音高就会连成"
           "旋律）。总时长 58ms、干燥无混响——UI 音在耳边，混响会让它变糊、"
           "也会让高频操作听起来慢。响度是全部音效里最低的一层。",
       dur_ms=(50.0, 72.0), band_center=2600.0,
       overlap="允许（高频触发；引擎已做同事件停旧实例）",
       build=_b_ui_hover, width=0.0, clip=(2.0, 0.45)),
    _R(event="ui_click", files=("ui_click",), category="ui", node="audio_manager",
       what="'按下去'的点击——干脆、有明确音高",
       components=("5ms 高通瞬态（'咔'）",
                   "D5 带 3% 音高下滑 + 上方纯五度分音",
                   "D4 短垫（'实在感'）"),
       why="点击要给'确定性'（我按到了）：两个简单分音比纯噪声更明确。"
           "音高下滑 3% 模拟'物理按键被压下'的惯性；D5+其上方纯五度只取 1/5 度"
           "关系（模块头 §一），在任何调上都是协和音程。总 95ms、完全干燥。",
       dur_ms=(76.0, 105.0), band_center=1800.0, build=_b_ui_click,
       clip=(2.4, 0.5)),
    _R(event="ui_confirm", files=("ui_confirm",), category="ui",
       node="audio_manager",
       what="'确认/接受'的肯定回答——极短的上扬双音铃",
       components=("FM 铃 D5", "70ms 后 FM 铃 A5", "D4 轻垫", "起音气声"),
       why="上扬的纯五度（D5→A5）是'肯定'的通用听觉符号；用 FM 铃而非正弦，"
           "因为铃的**非谐分音**让它听起来像'一个事件'而不是'一个音符'——"
           "不会和音乐旋律抢语义。总 300ms，不侵占音乐时间。",
       dur_ms=(230.0, 315.0), band_center=2000.0, build=_b_ui_confirm,
       clip=(1.8, 0.35)),
    _R(event="ui_denied", files=("ui_denied",), category="ui",
       node="audio_manager",
       what="操作被拒的负反馈——两声下行的闷击（明确'不行'）",
       components=("7ms 低中频瞬态（600–4.5k）",
                   "165/250/391Hz 非谐模态闷击（无音高）",
                   "90ms 后一次更轻更低的第二击",
                   "400–1.8k 暗噪声（空气感）"),
       why="负反馈必须**明确但不可憎**。与 `ui_click`（1.8k 质心、亮、有音高、"
           "短）的对比靠三条：音区压到 500Hz 以下、**不给明确音高**（非谐模态比 "
           "1/1.52/2.37）、以及'两下'的动作感（一下是点击，两下是否决）。刻意"
           "不用 1~4kHz 的蜂鸣器：那正是本项目最敏感、也是音乐'存在感'区的频段，"
           "连续误操作时会变成听觉疲劳源。响度与 hover/click 同层（-25）：它同为"
           "高频反馈，不该更响。",
       dur_ms=(130.0, 210.0), band_center=480.0,
       key="无明确音高（非谐模态 + 噪声），不参与调式",
       overlap="允许（SFX_POLICY 节流 150ms）；与 ui_click 分键，不互相掐断",
       build=_b_ui_denied, clip=(2.2, 0.45)),

    # ── ② 采集五件套 ───────────────────────────────────────────────────
    _R(event="harvest_hit", files=("harvest_hit_a",), category="harvest",
       node="audio_manager",
       what="石块被敲下的脆响（小石子被敲掉一角）",
       components=("高频瞬态（接触点）", "3300Hz 起的 4 个非谐模态，T 18~62ms",
                   "1.2–6k 碎屑噪声"),
       why="三变体中的『脆』。非谐比例（1/1.72/2.41/3.16）是'石头'而非'木琴'"
           "的关键——整数倍分音=有音高。变体 a 刻意做到最短（≈62ms）最亮"
           "（谱质心最高），与 b/c 拉开距离，避免连续采集听成机关枪。",
       dur_ms=(50.0, 72.0), band_center=3400.0, build=_b_hit_a,
       clip=(2.6, 0.5)),
    _R(event="harvest_hit", files=("harvest_hit_b",), category="harvest",
       node="audio_manager",
       what="锄头砸在岩壁上的钝撞（有回弹的闷响）",
       components=("高频瞬态", "1750Hz 起的 4 个非谐模态，T 27~100ms",
                   "低频体量（150→120Hz 下滑）", "0.9–5k 碎屑噪声"),
       why="三变体中的『钝』。同一个掷锄动作砸在**岩壁**（不是小块石头）上时"
           "接触面大，放出的一部分能量变成中低频体量。低频体量是变体 b 独有的"
           "成分，因此它的谱质心比 a 低 1000Hz 以上——这是'材质/部位不同'而不是"
           "'音量不同'。",
       dur_ms=(76.0, 105.0), band_center=1850.0, build=_b_hit_b,
       clip=(2.6, 0.5)),
    _R(event="harvest_hit", files=("harvest_hit_c",), category="harvest",
       node="audio_manager",
       what="矿脉崩落的碎裂（一次动作里有多下）",
       components=("第一次敲击的模态堆（2500Hz 起，振幅更平=宽带）",
                   "16/44/74ms 三个微瞬态", "碎屑噪声"),
       why="三变体中的『碎』。它的判别特征是**颗粒**：一次敲击带出三个衰减的"
           "小瞬态，时长最长（≈135ms）。这既符合'挖到矿脉'的语义，也把变体 c"
           "在时长轴上与 a/b 分开（模块头 §二：变体差异要有客观门槛）。",
       dur_ms=(102.0, 140.0), band_center=2700.0, build=_b_hit_c,
       clip=(2.6, 0.5)),
    _R(event="harvest_wood", files=("harvest_wood",), category="harvest",
       node="audio_manager",
       what="砍树——斧头扎进木头的中空'咚'",
       components=("斧刃入木瞬态（800–4.5k）",
                   "木体模态 288/342/430Hz（空腔音高感，T 140~300ms）",
                   "1.15kHz 木质敲击模态", "木屑噪声", "185→150Hz 低频体量"),
       why="木头与石头的可听分水岭不是'频率高低'而是：木头有**成组的低中频"
           "共振**（中空箱体）+ 明显更长的衰减（≈300ms vs 石头 62~135ms）。"
           "共振取 288/342/430Hz，落在 D4 下方、与音乐调心同族，砍树声因此"
           "'进得了'音乐而不是杂音。木屑噪声给'木纤维被劈开'的质感。",
       dur_ms=(245.0, 335.0), band_center=650.0, build=_b_harvest_wood,
       clip=(2.2, 0.45)),
    _R(event="harvest_gain", files=("harvest_gain",), category="harvest",
       node="audio_manager",
       what="资源入账——一枚轻亮的'叮'（登记入册）",
       components=("金属模态 D6+A6（含 2.98× 非谐分音）",
                   "5–12k 亮片瞬态", "D4 轻垫"),
       why="入账要'爽'，但不能是硬币声——硬币声是 Terraria Coin 的语义，"
           "也正是要替换掉的提取件。改用**两声高音金属**做'登记'的通用符号；"
           "频率放 1.2k/1.8k 而非 3~5kHz，把刺耳敏感区留给音乐（见质检报告的"
           "2–5kHz 占用时长）。响度比敲击低 1dB 之内：入账是**附带信息**，"
           "不该抢敲击的即时反馈。",
       dur_ms=(118.0, 162.0), band_center=1450.0, build=_b_harvest_gain,
       clip=(2.2, 0.4)),

    # ── ③ 生命周期四件套 ───────────────────────────────────────────────
    _R(event="game_started", files=("game_started",), category="lifecycle",
       node="audio_manager",
       what="进入对局——一声有仪式感的'起'（世界展开）",
       components=("D2 低鼓（膜音下滑）", "D4 铃 → 230ms 后 A4 铃",
                   "慢起振'张开'垫（D3+A3+D4，低通 1.2kHz）", "气声层",
                   "10% room 混响"),
       why="仪式感的三要素都编码在这里：**有起振时间**（垫 220ms 才到满，不是"
           "'啪'一下）、**有空间**（room 混响）、**有音高结构**（D→A 上行）。"
           "垫只取 1/5/8 度、低通 1.2kHz：全部能量在 1.2kHz 以下，2kHz 以上"
           "让给音乐——这是'与音乐不打架'的**物理做法**，不是靠调音量。"
           "响度压在 -20（比音乐低 5dB）：它是过场音，音乐才是主角。",
       dur_ms=(1200.0, 1620.0), band_center=380.0,
       key="D 调心 1/5/8 度，六种调式下全部协和",
       overlap="不与自身重叠（对局开始只发生一次）",
       build=_b_game_started, rev=(0.10, "room", 1.8),
       tone=(("shelf", 3200.0, -2.5),), width=0.35, clip=(1.6, 0.25)),
    _R(event="game_saved", files=("game_saved",), category="lifecycle",
       node="audio_manager",
       what="存档完成——轻快的'记下了'（A4→D5）",
       components=("A4 铃", "90ms 后 D5 铃", "起音气声"),
       why="存档是**系统确认**而非成就，所以时长（≈460ms）与响度（-21）都要"
           "克制：比 quest_done 低 2dB、短一半。上行纯四度同为无三音音程。",
       dur_ms=(355.0, 485.0), band_center=900.0,
       overlap="允许（玩家可能连续快速存档；引擎已停旧实例）",
       build=_b_game_saved, rev=(0.06, "room", 1.2),
       tone=(("shelf", 3500.0, -2.0),), width=0.2),
    _R(event="quest_done", files=("quest_done",), category="lifecycle",
       node="audio_manager",
       what="阶段目标完成——三音上行铃琶音 + 闪光",
       components=("D5→A5→D6 三音上行 FM 铃（90ms 间隔）", "5–11k 闪光瞬态",
                   "12% room 混响"),
       why="'完成'的通用听觉符号 = 上行琶音 + 铃音色；三音全部取 1/5/8 度，"
           "因此不论当时在播哪首曲子都不会打架（这是偶发音效唯一可行的做法，"
           "见模块头 §一）。上行而非下行：音高的方向性就是这个语义的直觉载体。",
       dur_ms=(730.0, 990.0), band_center=1000.0,
       build=_b_quest_done, rev=(0.12, "room", 2.0),
       tone=(("shelf", 3400.0, -2.2),), width=0.35, clip=(1.7, 0.3)),
    _R(event="build_complete", files=("build_complete",), category="lifecycle",
       node="audio_manager",
       what="建造完成——先一记'落定'，再一声向上的'成了'",
       components=("木+石混合落定（240/360/520Hz 木体 + 1.9k 石质模态）",
                   "160ms 后 D5+A5 同时响的开口五度铃", "10% room 混响"),
       why="'建造完成'有两个听觉要素：**物理落定**（有东西被装上了）+ **完成"
           "肯定**（一个向上的收束）。分两层先后出现，比一个单点音更能表达"
           "'过程结束'——这是'阶段完成'与'敲了一下'的区别。第二层用**同时响**"
           "的开口五度（不是琶音），与 quest_done 的琶音拉开语义。",
       dur_ms=(655.0, 885.0), band_center=520.0,
       build=_b_build_complete, rev=(0.10, "room", 1.8),
       tone=(("shelf", 3200.0, -2.2),), width=0.3, clip=(1.9, 0.35)),

    # ── ④ 战斗 sting 三件套 ────────────────────────────────────────────
    _R(event="battle_started", files=("battle_started",), category="battle",
       node="audio_manager",
       what="开战号角——D3→A3→D4 三声上行",
       components=("三支号角（锯齿谐波堆 + 亮度包络 + 颤音）",
                   "D1 低鼓", "战场空气噪声层", "18% hall 混响"),
       why="开战是'宣告'不是'完成'，所以**只取 1/5/8 度（D-A-D）不含三音**"
           "——出征曲是 D 小调、胜利曲是 D 大调，开口五度在两个调上都站得住；"
           "而开战那一瞬间音乐往往还没切到战斗曲，这一点很重要。号角用时间"
           "变化的谐波包络（慢起振 45ms + 亮度先开后收 + 多支失谐）：纯正弦"
           "听起来像电子提示音，铜管的判别特征就是这三条。",
       dur_ms=(1090.0, 1470.0), band_center=700.0,
       key="D 调心 1/5/8 度（D 小调与 D 大调双兼容）",
       overlap="不与自身重叠；响度 -15 与音乐持平，靠'金属般的瞬态与和声"
               "密度'而不是靠音量盖过音乐",
       build=_b_battle_started, rev=(0.18, "hall", 2.4),
       tone=(("shelf", 3600.0, -2.0),), width=0.5, clip=(1.5, 0.25)),
    _R(event="battle_ended_win", files=("battle_ended_win",),
       category="battle", node="audio_manager",
       what="战斗胜利——上行正格终止 + D 大三和弦（清晰的正向收束）",
       components=("号角 D4→A4→D5", "峰值处叠 F#5（**三音**）",
                   "定音鼓式 D2", "5–13k 闪光", "20% hall 混响"),
       why="胜利的信息主要由**三音性质**承载：大三=胜利。最响的那一音上给出"
           "F#5 —— 而'凯旋'BGM 正是 D 大调，所以 sting 与随后的音乐是同调"
           "同和弦（叠在一起是加强而非打架）。这是**唯一**敢用三音的场合之一："
           "场景确定（战斗结束必然接凯旋）。",
       dur_ms=(1200.0, 1620.0), band_center=900.0,
       key="D 大三（= sting_victory 的调）",
       overlap="不与自身重叠（一次战斗一次）",
       build=_b_battle_win, rev=(0.20, "hall", 2.6),
       tone=(("shelf", 3800.0, -1.8),), width=0.55, clip=(1.5, 0.25)),
    _R(event="victory_fanfare", files=("victory_fanfare",),
       category="battle", node="audio_manager",
       what="通关礼炮——慢速上行五度 + 开口五度收束（比战斗结算更庄重、更完满）",
       components=("D2 低鼓（弱）", "铃 D4→A4→D5（450ms 间隔，慢速上行）",
                   "1.55s 处同时响的 D5+A5 开口五度长铃",
                   "D3+A3+D4 低通弦垫（0.55s 慢起振）", "气声层", "22% hall 混响"),
       why="它接替的是 `battle_ended_win` 被'借用'到通关结算的位置（见 "
           "音效触发改动清单 §A4）：一个事件名只承载一种语义，2.8s 的长音共键会"
           "被去重机制互相掐断。与 `battle_ended_win` 的差别是有意的三条：**不用"
           "铜管**（改用铃 + 低通弦垫，与本项目 72BPM 钢琴/弦乐/钟琴的音乐同族，"
           "不是战场语气）、**更慢**（450ms 间隔的琶音 + 终点同时响的开口五度长"
           "衰减=收束而非冲锋）、**不含三音**（通关时在播哪首曲子不确定：战略曲 "
           "C 大调、主菜单 D 大调都可能，开口五度 D-A 在六种调式下都协和；三音只"
           "留给场景确定的战斗胜负 sting）。弦垫低通 1.5kHz、气声不上 2kHz，把"
           "音乐的存在感区（2–5kHz）让出来；响度取 sting 层（-15）与音乐持平，"
           "靠时长与和声密度而不是音量站住。",
       dur_ms=(2350.0, 2950.0), band_center=560.0,
       key="D 调心 1/5/8 度（不含三音，六种调式下均协和）",
       overlap="不与自身重叠（通关只发生一次）",
       build=_b_victory_fanfare, rev=(0.22, "hall", 2.8),
       tone=(("shelf", 3000.0, -2.5),), width=0.4, clip=(1.7, 0.3)),
    _R(event="battle_ended_lose", files=("battle_ended_lose",),
       category="battle", node="audio_manager",
       what="战斗失败——下行 + 拖长的尾巴 + 落音下滑（'气泄了'）",
       components=("号角 D4→A3→F3（三音仅 0.13s 作经过音）→ D3 长音",
                   "落音再下滑 40 音分", "D1 长衰减", "500Hz 以下闷噪声",
                   "20% 暗色 hall 混响"),
       why="失败 = 下行 + 小调三音 + 拖长的尾巴。但'折戟'BGM 是 **B 小调"
           "（含 F#）**，三音若长时间持续就会与它冲突——所以 F 只作 0.13s 的"
           "**经过音**，落音回到开口五度上的 D，两个调式下都只剩协和音程承重。"
           "整体收敛高频（3.2k -3dB）：'败者不该刺耳'既是语义，也把 2–5kHz"
           "让给音乐。",
       dur_ms=(1300.0, 1760.0), band_center=520.0,
       key="D 小调（三音仅作经过音，与 B 小调兼容）",
       overlap="不与自身重叠",
       build=_b_battle_lose, rev=(0.20, "hall", 2.8),
       tone=(("shelf", 3200.0, -3.0), ("highpass", 40.0)), width=0.5,
       clip=(1.5, 0.25)),

    # ── ⑤ 受击三变体 ───────────────────────────────────────────────────
    _R(event="unit_hurt", files=("unit_hurt_a",), category="combat_fx",
       node="audio_manager",
       what="火柴人受击的中性闷哼『呃』",
       components=("3ms 撞击瞬态", "拟音：基频 210→150Hz + 共振峰 620/1100/2600",
                   "一丝胸口低频"),
       why="**能量集中在 300~1.5kHz 的语音带，不在 2~5kHz** —— 战斗里受击音"
           "会响几百次，2~5kHz 既是人耳最刺耳敏感区、又是音乐的'存在感'区；"
           "放在语音带则密集触发时像'人声嘈杂'（有生命感），而不是'金属刮擦'"
           "（疲劳），音乐也仍浮得出来。用声源-滤波合成而非真人采样：零版权，"
           "且情绪强度可控（真人痛叫很难统一）。",
       dur_ms=(153.0, 207.0), band_center=900.0,
       key="无固定音高（共振峰语音带），不与任何调式冲突",
       overlap="**必须允许**（一场战斗几百次）；响度 -17 比 sting 低 2dB，"
               "给'几十个声音同时响'留出余量",
       build=_b_hurt_a, rev=(0.05, "room", 0.8),
       tone=(("shelf", 3000.0, -2.5), ("peak", 3000.0, -3.0, 1.2)),
       clip=(2.0, 0.4)),
    _R(event="unit_hurt", files=("unit_hurt_b",), category="combat_fx",
       node="audio_manager",
       what="受击闷哼『啊』（高而尖，轻甲/新兵）",
       components=("撞击瞬态", "拟音：基频 300→210Hz + 共振峰 800/1300/2900",
                   "较强气声"),
       why="变体 b 的**全部共振峰上移**（F1 620→800、F2 1100→1300，基频 "
           "210→300Hz），因此谱质心比 a 高 300Hz 以上——这是'不同的人'而不是"
           "'同一个音换个音量'（模块头 §二）。时长更短：高音痛叫总是更短促。",
       dur_ms=(119.0, 161.0), band_center=1250.0,
       build=_b_hurt_b, rev=(0.05, "room", 0.8),
       tone=(("shelf", 3200.0, -2.5), ("peak", 3000.0, -3.0, 1.2)),
       clip=(2.0, 0.4)),
    _R(event="unit_hurt", files=("unit_hurt_c",), category="combat_fx",
       node="audio_manager",
       what="受击闷哼『哼』（低而长，重甲/老兵）",
       components=("撞击瞬态", "拟音：基频 160→115Hz + 共振峰 480/900/2300",
                   "较重的胸腔低频"),
       why="变体 c 的共振峰与基频**整体下移一个档**（F1 620→480、基频 210→160"
           "Hz），时长最长，胸口低频更重——语义是'重甲兵挨了一下的闷响'。"
           "三个变体因此覆盖'新兵—普通—老兵'三段，在部队里混播时像**一群人"
           "而不是一个人**。",
       dur_ms=(204.0, 276.0), band_center=620.0,
       build=_b_hurt_c, rev=(0.05, "room", 0.8),
       tone=(("shelf", 2800.0, -2.5), ("peak", 3000.0, -3.0, 1.2)),
       clip=(2.0, 0.4)),

    # ── ⑥ 武器拟音（原 SWL 提取件，同一批替换）──────────────────────────
    _R(event="Swoosh", files=("swoosh_a",), category="combat_fx",
       node="weapon_mount",
       what="挥击风声 a：短而高（匕首急挥）",
       components=("扫频带通噪声 2600→500→1300Hz", "'布/皮'摩擦中频层",
                   "低频位移感"),
       why="挥击音在战斗里密集触发（每次攻击动画一次），四变体靠**时长与中心"
           "频率轨迹**区分（不同的武器/挥法），而不是靠音量：短而高=匕首，"
           "长而低=大剑横扫。风声本身无音高，不与音乐调式冲突。",
       dur_ms=(288.0, 390.0), band_center=1300.0,
       key="无音高（噪声），无调式冲突",
       overlap="允许（多个单位同时挥击；引擎按单位播放）",
       build=_b_swoosh_a, rev=(0.04, "room", 0.6),
       tone=(("highpass", 180.0), ("shelf", 3000.0, -2.0)),
       width=0.25, clip=(2.4, 0.45)),
    _R(event="Swoosh", files=("swoosh_b",), category="combat_fx",
       node="weapon_mount",
       what="挥击风声 b：中速（单手剑）",
       components=("扫频带通噪声 1900→380→950Hz", "摩擦中频层", "低频位移感"),
       why="变体 b 的中心频率整体比 a 低 600~700Hz、时长长 90ms——是'换了武器'"
           "而不是'同一个风声'。",
       dur_ms=(365.0, 494.0), band_center=950.0,
       build=_b_swoosh_b, rev=(0.04, "room", 0.6),
       tone=(("highpass", 160.0), ("shelf", 3000.0, -2.0)),
       width=0.25, clip=(2.4, 0.45)),
    _R(event="Swoosh", files=("swoosh_c",), category="combat_fx",
       node="weapon_mount",
       what="挥击风声 c：低而长（大剑横扫）",
       components=("扫频带通噪声 1300→260→700Hz", "摩擦中频层",
                   "更重的低频位移感"),
       why="最长的变体（≈540ms）且低频位移感最重：大剑扫过的空气体积最大。"
           "与 d 一起构成'从匕首到大剑'的完整梯度。",
       dur_ms=(484.0, 655.0), band_center=700.0,
       build=_b_swoosh_c, rev=(0.04, "room", 0.6),
       tone=(("highpass", 140.0), ("shelf", 3000.0, -2.0)),
       width=0.25, clip=(2.6, 0.45)),
    _R(event="Swoosh", files=("swoosh_d",), category="combat_fx",
       node="weapon_mount",
       what="挥击风声 d：极短而亮（盾击/棍棒）",
       components=("扫频带通噪声 3200→700→1600Hz", "较强气声", "少量低频位移感"),
       why="最短（≈250ms）最高（起始 3.2kHz）：钝器的挥击空气扰动更『嘶』。"
           "四变体的谱质心从 700 到 1600+Hz 拉开，连续挥击时不会听成同一个音。",
       dur_ms=(237.0, 321.0), band_center=1700.0,
       build=_b_swoosh_d, rev=(0.04, "room", 0.6),
       tone=(("highpass", 200.0), ("shelf", 3000.0, -2.5)),
       width=0.25, clip=(2.4, 0.45)),
    _R(event="headbutt1", files=("headbutt",), category="combat_fx",
       node="weapon_mount",
       what="矛兵冲撞——骨/头盔碰撞的硬闷响",
       components=("硬瞬态（1.2–9k）", "2.2k/3.4k/5.2k 非谐模态（T 28~70ms）",
                   "120→72Hz 重低频闷响", "摩擦噪声"),
       why="与 thump（倒地）的区别是'硬'：冲撞是**两件硬物互撞**，所以有高频"
           "瞬态 + 短的高频模态；倒地是**身体落地**，没有高频瞬时成分。"
           "这个区分让'打到了'和'倒下了'在听觉上完全不同。",
       dur_ms=(272.0, 368.0), band_center=420.0,
       build=_b_headbutt, rev=(0.06, "room", 0.9),
       tone=(("shelf", 3000.0, -2.0),), width=0.2, clip=(1.8, 0.4)),
    _R(event="MagikillBlast", files=("magikill_blast_a",), category="battle",
       node="weapon_mount",
       what="法术 a「轰」——能量上冲后爆破落定",
       components=("上冲扫频 260→2400→600Hz（90ms 起振）",
                   "88→52Hz 爆破低频", "3.1k/4.8k/7k/9.2k 闪烁簇"),
       why="法术音与物理打击音的分水岭是**没有高频瞬态**：能量是'涨上来'的"
           "（90ms 起振），不是'啪一下接触'。闪烁簇提供'魔法'色彩（非谐高音），"
           "避免听起来像爆炸。响度 -15（战斗 sting 层）：它稀有、需要爆发力。",
       dur_ms=(900.0, 1220.0), band_center=900.0,
       build=_b_magikill_a, rev=(0.16, "hall", 2.0),
       tone=(("shelf", 4200.0, -1.5),), width=0.4, clip=(1.6, 0.3)),
    _R(event="MagikillBlast", files=("magikill_blast_b",), category="battle",
       node="weapon_mount",
       what="法术 b「吟」——持续积蓄后收束",
       components=("上升扫频 420→700→2400Hz（220ms 起振）",
                   "3k/4.5k/6.6k 金属闪烁", "结尾 70→52Hz 短低频落定"),
       why="与 a 的差异是**时间方向相反**（a 冲上去炸开，b 持续积蓄然后收束），"
           "共享同一套原语所以不会像两个游戏。方向相反的两个变体在战斗里交替"
           "出现时，'施法'的语义比两个同类爆破音更清楚。",
       dur_ms=(1105.0, 1495.0), band_center=1200.0,
       build=_b_magikill_b, rev=(0.16, "hall", 2.0),
       tone=(("shelf", 4200.0, -1.5),), width=0.4, clip=(2.8, 0.5)),
    _R(event="Thump", files=("thump_a",), category="combat_fx",
       node="weapon_mount",
       what="倒地闷响 a（重甲落地，更低更长）",
       components=("62→40Hz 膜音下滑", "低频体（软组织）", "一丝甲片摩擦"),
       why="'身体落地'的声音**没有高频成分**（肉/布撞击不产生高频瞬态），能量"
           "集中在 40~250Hz——这是它跟 headbutt（硬撞）的物理区别。两变体靠"
           "基频与衰减时长区分（矮个/高个、轻甲/重甲）。",
       dur_ms=(289.0, 391.0), band_center=90.0,
       build=_b_thump_a, rev=(0.05, "room", 0.8), tone=(("lowpass", 1200.0),),
       width=0.15, clip=(1.7, 0.4)),
    _R(event="Thump", files=("thump_b",), category="combat_fx",
       node="weapon_mount",
       what="倒地闷响 b（轻甲/敏捷兵，更高更紧）",
       components=("84→58Hz 膜音下滑", "低频体", "更多衣物摩擦"),
       why="变体 b 基频比 a 高 22Hz、衰减短 1/3，摩擦声更多：语义是'轻装的人"
           "更快地倒下'。两者在混播时是'不同体格'而不是'同一个音'。",
       dur_ms=(187.0, 253.0), band_center=120.0,
       build=_b_thump_b, rev=(0.05, "room", 0.8), tone=(("lowpass", 1400.0),),
       width=0.15, clip=(1.7, 0.4)),
    _R(event="fall", files=("bodyfall_a",), category="combat_fx",
       node="weapon_mount",
       what="尸体落地 a（干脆的一次倒下 + 轻反弹）",
       components=("78→52Hz 首次触地", "150ms 后一次更轻的反弹",
                   "布/肢体摊开摩擦声"),
       why="与 thump 的差别就是**第二下**：人倒下后身体会摊开/轻微回弹，只响"
           "一下是'沙袋落地'，响两下才是'人倒下'。三变体的差异来自反弹延迟"
           "（110/150/230ms）与摩擦声量——即'怎么倒的'。",
       dur_ms=(221.0, 299.0), band_center=110.0,
       build=_b_bodyfall_a, rev=(0.06, "room", 0.9), tone=(("lowpass", 1600.0),),
       width=0.2, clip=(1.8, 0.4)),
    _R(event="fall", files=("bodyfall_b",), category="combat_fx",
       node="weapon_mount",
       what="尸体落地 b（重甲/盾牌一起落地，更重更长）",
       components=("62→41Hz 首次触地（更低更长）", "230ms 后反弹",
                   "较少摩擦声（甲片盖住了布声）"),
       why="最低最长的变体：重甲兵的落地动能更大、身体摊开更慢。",
       dur_ms=(323.0, 437.0), band_center=80.0,
       build=_b_bodyfall_b, rev=(0.06, "room", 0.9),
       tone=(("lowpass", 1200.0),), width=0.2, clip=(1.8, 0.4)),
    _R(event="fall", files=("bodyfall_c",), category="combat_fx",
       node="weapon_mount",
       what="尸体落地 c（轻而闷，轻甲/远处）",
       components=("96→63Hz 首次触地", "110ms 后反弹（最早）",
                   "最多摩擦声（布衣）"),
       why="最高最短、摩擦声最多的变体：轻甲兵的布衣摩擦占比更大。三变体的"
           "基频（62/78/96Hz）与时长（150/210/320ms）都拉开了客观距离。",
       dur_ms=(179.0, 242.0), band_center=140.0,
       build=_b_bodyfall_c, rev=(0.06, "room", 0.9),
       tone=(("lowpass", 1800.0),), width=0.2, clip=(1.8, 0.4)),
    _R(event="clang", files=("clang_a",), category="combat_fx",
       node="weapon_mount",
       what="格挡叮声 a（高亢的刃击，剑格挡）",
       components=("高频金属瞬态（1.5–13k）",
                   "1850Hz 起的非谐金属模态堆（比例族 1/1.73/2.44/3.21，"
                   "T 175~700ms）", "2.5–11k 金属碎屑噪声"),
       why="金属与石头的分水岭是**衰减时长**（金属模态损耗极低，响半秒以上）"
           "与**更高的非谐比例族**（理想棒振动比例）。格挡是战斗里最关键的正向"
           "反馈（'我挡住了'），所以给它 -16（见 layer 覆盖）：比单位拟音高 "
           "2dB，仅次于 sting。",
       dur_ms=(451.0, 610.0), band_center=2600.0,
       build=_b_clang_a, rev=(0.10, "plate", 1.6),
       tone=(("shelf", 5000.0, -2.5), ("peak", 3200.0, -2.0, 1.5)),
       width=0.3, clip=(3.4, 0.6)),
    _R(event="clang", files=("clang_b",), category="combat_fx",
       node="weapon_mount",
       what="格挡叮声 b（低闷的盾击）",
       components=("高频金属瞬态",
                   "980Hz 起的 5 个非谐模态（更密，T 90~520ms）",
                   "更多金属碎屑噪声"),
       why="变体 b 基频比 a 低 870Hz、衰减短 180ms、噪声更多：语义是'盾牌被"
           "砸中'（面积大、非理想弹性）而不是'刀剑相格'（窄、脆）。两者在战场上"
           "同时存在时听得出对方拿的是什么。",
       dur_ms=(323.0, 437.0), band_center=1500.0,
       build=_b_clang_b, rev=(0.10, "plate", 1.6),
       tone=(("shelf", 4000.0, -2.0), ("peak", 2600.0, -2.0, 1.5)),
       width=0.3, clip=(3.2, 0.55)),
)


# 自研件（**不重写**，只在质检里报告）：鸟鸣与环境雨声是旧管线
# （`stick-world/tools/ai/gen_sfx.py` / `tools/music/ambience.py`）的产品，
# 无版权问题，本批不动它们（见 docs/技术/音频/音效资产登记与来源.md §五）。
KEPT_SELF_MADE = {
    "bird_chirp_a": dict(event="bird_chirp_a", category="ambient",
                         target_lufs=-24.0),
    "bird_chirp_b": dict(event="bird_chirp_b", category="ambient",
                         target_lufs=-24.0),
    "bird_chirp_c": dict(event="bird_chirp_c", category="ambient",
                         target_lufs=-24.0),
    "rain_loop": dict(event=None, category="ambient", target_lufs=-20.0),
}


## 分类覆盖：少数事件在分层上有意偏离同类（配方的 why 里说明理由）。
LAYER_OVERRIDE = {
    "clang_a": -16.0,     # 格挡是战斗里最关键的正向反馈，比单位拟音高 2dB
    "clang_b": -16.0,
    "unit_hurt_a": -17.0,  # 受击比其它单位拟音低 1dB：它最密集
    "unit_hurt_b": -17.0,
    "unit_hurt_c": -17.0,
}


def all_files() -> list:
    """全部由本管线生成的交付文件名（不含 .wav）。"""
    out = []
    for r in RECIPES:
        out.extend(r.files)
    return out


def target_lufs(name: str) -> float:
    """某件交付件的响度目标（含 LAYER_OVERRIDE）。"""
    r = by_file(name)
    return float(LAYER_OVERRIDE.get(name, layer_of(r.category)))


def by_file(name: str) -> Recipe:
    for r in RECIPES:
        if name in r.files:
            return r
    raise KeyError(name)


def groups() -> dict:
    """事件 → 变体配方列表（质检的变体差异检查用）。"""
    g: dict = {}
    for r in RECIPES:
        g.setdefault(r.event, []).append(r)
    return g
