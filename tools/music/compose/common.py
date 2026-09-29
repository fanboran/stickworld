# -*- coding: utf-8 -*-
"""共用素材与编曲助手 —— 一部作品集的"音乐基因"。

**旋律素材在 `compose/themes.py`**：每个场景一条自己的旋律（口径见该文件的说明）。
本文件提供两样东西：

  1. **写作常量**（音区、力度），每条都写明"为什么是这个数"；
  2. **编曲助手**：和声骨架、级数→音高的换算、各类织体的自动写作
     （钢琴伴奏 / 弦乐垫 / 竖琴分解 / 点状色彩 / 低音声部）。

三条纪律贯穿全部助手——"能听"来自它们，不来自混音：
  - **主旋律比伴奏响**：伴奏力度一律压到旋律的 60~70%；
  - **一层一件事**：同一件乐器要么唱旋律、要么伴奏，不兼任；
  - **点状音只做"光"**：每小节 1~2 个、落在弱拍、音区比旋律高一个八度。

每首曲子自带**旋律与和声骨架**（见 `themes.py`），本文件不假设任何"全库统一"：
它提供的助手只保证"写出来的东西密度合适、配器有纪律"，风格由调用点决定。
"""

from compose import themes as TH
from musiclib import theory as T

# ───────────────────── 和声骨架条目库（可选，非强制）─────────────────────
# **每首曲子的和声骨架由它自己在 themes.py 里声明**（`Melody.harmony`，
# 与旋律一起写、一起改）；这里是可选的定番套路条目库——写新曲时直接取用，
# 也可以另起一条。每条都只取**级数骨架**：和声进行本身不受版权保护，
# 也都在公有领域的经典之列（见音乐设计文档 §和声语汇）。
SKELETONS = {
    "カノン進行": ["I", "V", "vi", "iii", "IV", "I", "IV", "V"],
    "王道進行": ["IV", "V", "iii", "vi", "ii", "V", "I", "V"],
    "丸サ進行": ["IVmaj7", "V7", "iii7", "vi7", "IV", "V", "I", "V"],
    "小室進行": ["vi", "IV", "V", "I", "vi", "IV", "V", "I"],
    "ポップパンク": ["I", "V", "vi", "IV", "I", "V", "vi", "IV"],
    "ドゥーワップ": ["I", "vi", "IV", "V", "I", "vi", "IV", "V"],
    "三度下行链": ["I", "vi", "IV", "ii", "V", "I", "IV", "V"],
    "自然小調循環": ["i", "VI", "III", "VII", "i", "VI", "III", "VII"],
    "自然小調カノン": ["i", "v", "VI", "III", "iv", "i", "iv", "v"],
    "アンダルシア": ["i", "VII", "VI", "V", "i", "VII", "VI", "V"],
    "エモ進行": ["i", "VII", "VI", "VII", "i", "VII", "VI", "VII"],
    "田园骨架": ["I", "iii", "IV", "V", "I", "vi", "IV", "V"],
    "出征骨架": ["i", "VI", "III", "VII"],
    "标点骨架": ["I", "vi", "IV", "V", "I", "vi", "IV", "I"],
}

# 兼容旧引用（历史上按名字散着定义过这几个）
CANON = SKELETONS["カノン進行"]
CANON_MINOR = SKELETONS["自然小調カノン"]
VILLAGE = SKELETONS["田园骨架"]
MARCH = SKELETONS["出征骨架"]


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
# 常量必然让某些乐器跑到音域之外。所以这里只定义"参考八度"，
# 具体值由 themes.py 在**每条乐句**上声明（`Phrase.transpose` + `register`）。
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
    """把级数形式的一串音（一条乐句）写进某个 stem。"""
    for (bar, beat, dur, deg, oct_shift, vel) in events:
        if deg is None:
            continue
        pitch = T.degree(key, scale, deg, oct_shift) + transpose
        stem.add(cue.bar(bar + bar_offset) + beat, dur, pitch,
                 max(1, min(127, int(round(vel * vel_scale * VELOCITY_TRIM)))))


def render_phrase(cue, stem, melody, phrase: str, bar_offset: int = 0,
                  vel_scale: float = 1.0, transpose: int | None = None) -> None:
    """把某条旋律的一条 8 小节乐句写进 stem。

    移调默认取**乐句自己的推荐八度**（`Phrase.transpose`）：同一个级数在钢琴、
    长笛、双簧管上的舒适音区不同，D 大调又比 G 大调低 5 个半音——所以八度写在
    乐句上，而不是写成全局常量（那必然让某些声部跑出乐器音域）。
    """
    ph = melody.phrase(phrase)
    tr = ph.transpose if transpose is None else transpose
    render_theme(cue, stem, ph.events, melody.key, melody.scale,
                 bar_offset=bar_offset, vel_scale=vel_scale, transpose=tr)


def render_melody(cue, stem, melody, vel_scale: float = 1.0,
                  transpose: int | None = None, form=None, skip=(),
                  phrase_bars: int = 8) -> None:
    """按旋律自己的曲式整段写进 stem（默认 32 小节 = 4 条 8 小节乐句）。

    - `form` 覆盖曲式（如只陈述两遍：`("A", "A", "B", "A")`）；
    - `skip` 把某些乐句**留空**——交接乐句时让主奏闭嘴，让另一件乐器接过去，
      是最好的配器手法之一（"留白优于铺满"）。
    """
    for i, name in enumerate(form or melody.form):
        if name is None or i in skip:
            continue
        render_phrase(cue, stem, melody, name, bar_offset=i * phrase_bars,
                      vel_scale=vel_scale, transpose=transpose)


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
