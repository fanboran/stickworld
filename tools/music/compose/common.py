# -*- coding: utf-8 -*-
"""共用素材与编曲助手 —— 一部作品集的"音乐基因"。

设计核心：**一个主主题，多处变奏**。

整部配乐只用一条 8 小节主题（「原野主题」），它在不同场景里以不同调式、
不同织体、不同编制复现：白天是 D 大调的明朗、夜里是 B 小调的幽暗、小镇是
G 大调 6/8 的摇曳、室内是 F 大调的独白、战场是 D 小调的急促。

为什么这么做（而不是每首先写一条新旋律）：
  1. **可辨识**——玩家听几次就能哼出来，主题才成为"这段旅程的声音"；
  2. **风格统一**——同一素材保证整部配乐是一个世界，而不是风格拼盘；
  3. **省成本**——变奏的写作成本远低于从零写 8 首，且质量更可控。
这是日本动画/游戏配乐（久石让、Key 社、动森）最普遍的做法，也是本项目的
自觉选择：与其写 8 首平庸的曲子，不如把一条旋律写到足够好，再把它讲 8 遍。

主题以**音阶级数**而非绝对音高记录，因此可以原样搬到任何调式上——
"夜晚版"就是把同一串级数放进 B 自然小调，这是"同一主题、不同心情"最省力
也最自然的实现方式。
"""
from __future__ import annotations

from musiclib import theory as T

# ─────────────────────────────── 主题 ────────────────────────────────

# 「原野主题」A 段：8 小节（4/4），和声走卡农进行。
# 元组 = (小节, 小节内起始拍, 时值拍, 音阶级数 或 None=休止, 八度偏移, 力度)
#
# 写作规则（来自日系静谧配乐的技法归纳，见 docs/设计/音乐/作曲技法参考.md）：
#   - 音域一个八度（D4~D5），级进为主，只在第 6 小节用一次上行到顶点
#   - 休止占约 25%，句尾长音留白，让踏板与混响有呼吸的空间
#   - 乐句停在 3 音或 5 音（不落主音），保持"话没说完"的开放感
THEME_A = [
    (0, 0.0, 1.5, 5, 0, 70),      # 起于五音，避免"从头就唱主音"的儿歌感
    (0, 1.5, 0.5, 6, 0, 74),
    (0, 2.0, 2.0, 3, 0, 68),      # 长音落在三音
    (1, 0.0, 1.0, None, 0, 0),    # 休止
    (1, 1.0, 0.5, 2, 0, 64),
    (1, 1.5, 0.5, 3, 0, 66),
    (1, 2.0, 2.0, 5, 0, 72),      # 停五音
    (2, 0.0, 1.5, 3, 0, 70),
    (2, 1.5, 0.5, 1, 0, 66),
    (2, 2.0, 2.0, 3, 0, 72),
    (3, 0.0, 0.5, None, 0, 0),
    (3, 0.5, 0.5, 2, 0, 64),
    (3, 1.0, 1.0, 7, 0, 68),      # 导音
    (3, 2.0, 2.0, 3, 0, 70),
    (4, 0.0, 2.0, 1, 0, 68),      # 落在主音（半句的临时落点）
    (4, 2.0, 2.0, 4, 0, 70),
    (5, 0.0, 1.0, 5, 0, 72),
    (5, 1.0, 1.0, 3, 0, 68),
    (5, 2.0, 2.0, 1, 1, 80),      # 全曲最高点（高八度主音），只出现一次
    (6, 0.0, 1.0, None, 0, 0),    # 高点之后立刻留白，回落才不突兀
    (6, 1.0, 0.5, 6, 0, 70),
    (6, 1.5, 0.5, 5, 0, 68),
    (6, 2.0, 2.0, 4, 0, 66),
    (7, 0.0, 1.0, None, 0, 0),
    (7, 1.0, 1.0, 3, 0, 66),
    (7, 2.0, 2.0, 5, 0, 70),      # 句尾停在五音，与开头呼应，循环处开放
]

# B 段：同一主题的音型换到"更高、更疏"的写法，用于第 3 个 8 小节（情绪打开）。
THEME_B = [
    (0, 0.0, 3.0, 5, 1, 72),
    (0, 3.0, 1.0, 6, 1, 74),
    (1, 0.0, 4.0, 5, 1, 76),
    (2, 0.0, 2.0, 3, 1, 72),
    (2, 2.0, 2.0, 1, 1, 70),
    (3, 0.0, 4.0, 3, 1, 72),
    (4, 0.0, 2.0, 1, 0, 68),
    (4, 2.0, 2.0, 4, 0, 70),
    (5, 0.0, 4.0, 5, 0, 74),
    (6, 0.0, 2.0, 6, 0, 72),
    (6, 2.0, 2.0, 5, 0, 70),
    (7, 0.0, 4.0, 4, 0, 68),
]

# C 段：主题的"回声"写法 —— 只剩骨架音，用在循环末尾把能量收回来。
THEME_C = [
    (0, 0.0, 4.0, 3, 0, 66),
    (1, 0.0, 4.0, 5, 0, 68),
    (2, 0.0, 4.0, 3, 0, 66),
    (3, 0.0, 4.0, 2, 0, 64),
    (4, 0.0, 4.0, 1, 0, 64),
    (5, 0.0, 4.0, 5, 0, 68),
    (6, 0.0, 4.0, 4, 0, 66),
    (7, 0.0, 4.0, 5, 0, 68),
]

# 32 小节循环 = 4 个 8 小节乐句：陈述 → 变奏 → 打开 → 收束
THEME_FORM = [THEME_A, THEME_A, THEME_B, THEME_C]

# 卡农进行（8 小节一轮）。整部作品的和声地基：它天生闭合、可无限循环，
# 也是日系抒情曲"经典但不腻"的和声来源。
CANON = ["I", "V", "vi", "iii", "IV", "I", "IV", "V"]
# 小调上的对应骨架（用于夜/战场：i - v - VI - III - iv - i - iv - v）
CANON_MINOR = ["i", "v", "VI", "III", "iv", "i", "iv", "v"]
# 村落用的摇曳骨架：更"生活化"的 I-vi-IV-V 变体
VILLAGE = ["I", "iii", "IV", "V", "I", "vi", "IV", "V"]


# ─────────────────────────── 渲染助手 ──────────────────────────────

# 旋律整体提高一个八度。
#
# 【为什么旋律需要提高八度】
# 主题以级数记录时默认落在 D4~D5（基频 293~587Hz）。这个音区写成钢琴曲会**发闷**：
# 实测成品频谱质心只有约 390Hz、2kHz 以上几乎没有能量，听起来像蒙了一层布。
# 原因是物理的——钢琴的低音区能量集中在基频与前几个泛音上，高音区（C5~C6，
# 基频 523~1046Hz）才有明显的 2~8kHz 泛音（实测同一个采样库的 C6 采样有
# 25~37% 的能量在 2~8kHz，而 C4 只有 0.3%）。
#
# 提高一个八度后：A 段 D5~D6、B 段（高潮）D6~A6、C 段回落到 F#5~A5。
# 三个乐句的音区差正好形成"中高 → 高 → 回落"的弧线，与曲式意图一致。
# 伴奏声部保持低音区不动，因此纵向音域被拉开，混音的"清澈度"来自编曲本身，
# 而不是靠 EQ 硬提亮（EQ 提亮对没有高频可提的素材是无效的）。
# 旋律八度**不用全局默认值**，而是在每个调用点显式给出。
# 原因：不同乐器的舒适音区不同（钢琴旋律常用 C5~C6，长笛/双簧管常用 C5~A5，
# 而同一个主题在不同调上落点也不同——D 大调比 G 大调低 5 个半音）。一个全局
# 常量必然让某些曲子的某个声部跑到乐器音域之外。所以这里只定义"参考八度"，
# 具体值由 cues.py 逐个声明并可被注释解释。
MELODY_OCTAVE_SHIFT = 0

# 力度整体上移系数。
#
# MIDI 力度在这个管线里有**两个身份**：一是乐句内的相对强弱（音乐性的），
# 二是**采样层的选择器**（音色性的）。后者容易被忽略：Salamander 的 16 个
# 力度层是 16 次独立录音，v1~v4 是"琴槌几乎不发力"的极弱音，音色天然发闷、
# 泛音很少。若乐谱只用 38~60 的力度，等于全程都在用最闷的那几层——混音阶段
# 再怎么提亮也提不出来（没有高频可提）。
#
# 所以这里把力度整体抬到样本的中段，让音色有正常的泛音结构；而**响度由混音
# 阶段的总线归一决定**（-17 LUFS），与力度无关。乐句内部的相对强弱关系全部
# 保留，音乐性不受影响。
VELOCITY_TRIM = 1.32


def _trim(vel: float) -> int:
    """力度整体抬到采样中段（详见 VELOCITY_TRIM 的说明）。"""
    return max(1, min(127, int(round(vel * VELOCITY_TRIM))))


def render_theme(cue, stem, events, key: str, scale: str,
                 bar_offset: int = 0, vel_scale: float = 1.0,
                 transpose: int = MELODY_OCTAVE_SHIFT) -> None:
    """把级数形式的主题写进某个 stem。"""
    for (bar, beat, dur, deg, oct_shift, vel) in events:
        if deg is None:
            continue
        pitch = T.degree(key, scale, deg, oct_shift) + transpose
        stem.add(cue.bar(bar + bar_offset) + beat, dur, pitch,
                 max(1, min(127, int(round(vel * vel_scale * VELOCITY_TRIM)))))


def render_form(cue, stem, key: str, scale: str, form=None,
                vel_scale: float = 1.0, transpose: int = MELODY_OCTAVE_SHIFT,
                phrase_bars: int = 8) -> None:
    """按 32 小节曲式把主题的四个乐句依次写进 stem。"""
    form = form or THEME_FORM
    for i, phrase in enumerate(form):
        render_theme(cue, stem, phrase, key, scale,
                     bar_offset=i * phrase_bars, vel_scale=vel_scale,
                     transpose=transpose)


def add_piano_accompaniment(cue, stem, key: str, scale: str, romans,
                            from_bar: int, to_bar: int, beats_per_chord: int = 4,
                            bass_low: int = 36, bass_high: int = 50,
                            arp_low: int = 50, arp_high: int = 73,
                            bass_vel: int = 58, arp_vel: int = 46,
                            pattern: str = "up_down",
                            rest_bars: tuple = ()) -> None:
    """钢琴伴奏：左手低音 + 右手分解和弦。

    低音每小节一次（全音符，靠踏板连起来），右手 8 分音符分解——
    这是日系静谧钢琴最基本的织体。力度刻意压低（旋律的 60~70%），
    "主旋律比伴奏响"是"听起来像有人在弹"的第一条纪律。
    """
    bass_vel, arp_vel = _trim(bass_vel), _trim(arp_vel)
    prev = None
    bar = from_bar
    idx = 0
    while bar < to_bar:
        roman = romans[idx % len(romans)]
        chord = T.roman_chord(key, scale, roman)
        voicing = T.nearest_voicing(chord, prev, low=arp_low, high=arp_high,
                                    n_notes=4)
        prev = voicing
        if bar not in rest_bars:
            start = cue.bar(bar)
            bass = T.bass_note(chord, bass_low, bass_high)
            stem.add(start, float(beats_per_chord), bass, bass_vel)
            for (off, pitch, k) in T.arpeggio_8th(voicing, float(beats_per_chord),
                                                  pattern, span=beats_per_chord * 2):
                # 每 4 个音轻微起伏，避免机械重复
                v = arp_vel + (3 if k % 4 == 0 else 0)
                stem.add(start + off, float(beats_per_chord) / (beats_per_chord * 2),
                         pitch, v)
        bar += 1
        idx += 1


def add_pad(cue, stem, key: str, scale: str, romans, from_bar: int,
            to_bar: int, beats_per_chord: int = 8, low: int = 57,
            high: int = 79, vel: int = 46, rest_bars: tuple = ()) -> None:
    """弦乐垫：长音和声层。和声节奏故意放慢（每 2 小节换一次），
    与钢琴的 8 分音符形成密度反差——"层次感"就是这么来的。"""
    prev = None
    bar = from_bar
    idx = 0
    while bar < to_bar:
        roman = romans[idx % len(romans)]
        chord = T.roman_chord(key, scale, roman)
        v = T.nearest_voicing(chord, prev, low=low, high=high, n_notes=4)
        prev = v
        span = min(beats_per_chord, (to_bar - bar) * cue.beats_per_bar)
        if bar not in rest_bars:
            for p in v:
                stem.add(cue.bar(bar), float(span) - 0.3, p, _trim(vel))
        bar += max(1, beats_per_chord // cue.beats_per_bar)
        idx += 1


def add_bell_accents(cue, stem, key: str, scale: str, romans, from_bar: int,
                     to_bar: int, low: int = 76, high: int = 91,
                     vel: int = 44, per_bar: int = 1, beats_per_chord: int = 4,
                     seed: int = 0) -> None:
    """钟琴/钢片琴点状色彩：每小节 1~2 个音，只落在和弦音上。

    点状音的纪律：**绝不与旋律同拍抢位置**（默认落在小节的弱拍），
    音区比旋律高一个八度，力度很轻——它是"光"，不是"音符"。
    """
    import random
    rng = random.Random(seed)
    bar = from_bar
    idx = 0
    while bar < to_bar:
        roman = romans[idx % len(romans)]
        chord = T.roman_chord(key, scale, roman)
        pool = [p for p in range(low, high + 1) if (p % 12) in chord.pitch_classes()]
        if pool and per_bar > 0:
            for k in range(per_bar):
                p = rng.choice(pool)
                # 落在第 2/3/4 拍上，避开强拍的旋律
                beat = rng.choice([1.0, 2.0, 3.0]) if cue.beats_per_bar == 4 else 2.0
                stem.add(cue.bar(bar) + beat, 1.5, p, _trim(vel) + rng.randint(-4, 4))
        bar += 1
        idx += 1


def add_harp_figures(cue, stem, key: str, scale: str, romans, from_bar: int,
                     to_bar: int, low: int = 57, high: int = 84,
                     vel: int = 40, span: int = 8, beats_per_chord: int = 4) -> None:
    """竖琴：跨八度的上行分解，音量压在钢琴之下，提供"空气感"。"""
    prev = None
    bar = from_bar
    idx = 0
    while bar < to_bar:
        roman = romans[idx % len(romans)]
        chord = T.roman_chord(key, scale, roman)
        v = T.nearest_voicing(chord, prev, low=low, high=high, n_notes=3)
        prev = v
        seq = []
        cur = v[0]
        while cur <= high:
            seq.append(cur)
            cur += 12
        if not seq:
            seq = v
        start = cue.bar(bar)
        for i, p in enumerate(seq[:span]):
            stem.add(start + i * (cue.beats_per_bar / span), 1.2, p, _trim(vel))
        bar += 1
        idx += 1


def add_wind_line(cue, stem, key: str, scale: str, events, bar_offset: int = 0,
                  vel_scale: float = 1.0) -> None:
    """独奏木管线（双簧管/长笛）：单声部、级进、长音、留白多。"""
    render_theme(cue, stem, events, key, scale, bar_offset=bar_offset,
                 vel_scale=vel_scale)


def add_bass_note_per_bar(cue, stem, key: str, scale: str, romans,
                          from_bar: int, to_bar: int, low: int = 33,
                          high: int = 45, vel: int = 62,
                          beats_per_chord: int = 4, octave_jump: bool = False) -> None:
    """低音声部（低音提琴/大提琴）：每小节根音，偶尔上八度走动。"""
    bar = from_bar
    idx = 0
    while bar < to_bar:
        chord = T.roman_chord(key, scale, romans[idx % len(romans)])
        p = T.bass_note(chord, low, high)
        if octave_jump and idx % 4 == 3:
            p += 12
        stem.add(cue.bar(bar), float(beats_per_chord), p, _trim(vel))
        bar += max(1, beats_per_chord // cue.beats_per_bar)
        idx += 1
