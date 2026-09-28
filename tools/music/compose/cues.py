# -*- coding: utf-8 -*-
"""曲目定义 —— 一部作品集的全部 cue。

每首曲子都是契诃夫式的"同一主题、不同讲法"：
  menu_title  原野·序   标题画面       D 大调  66   独奏钢琴 + 极轻弦乐
  field_day   原野·昼   户外白天       D 大调  72   钢琴 + 弦乐垫 + 竖琴 + 钟琴
  field_night 原野·夜   户外夜晚       B 小调  63   钢琴 + 低音弦 + 微光铃
  village     小镇      村落/G 大调     G 大调  84   钢琴 + 尼龙吉他 + 马林巴 + 长笛
  interior    灯下      室内           F 大调  58   独奏钢琴（近场空间）
  strategic   远望      战略地图       C 大调  64   温暖 Pad + 颤音琴 + 钢琴
  battle      出征      战斗           D 小调 104   钢琴 + 弦乐 + 定音鼓 + 双簧管
  sting_victory 凯旋    战斗胜利       D 大调   72   弦乐 + 钟琴 + 钢琴（一次性）
  sting_defeat  折戟    战斗失败       B 小调   63   低音弦 + 钢琴（一次性）

编制分层（tier）是给引擎做纵向混音用的：tier 0 = 永远在场的地基，
数值越大越"热闹"，运行时按游戏强度逐层淡入。同一 cue 的全部层**等长、
同循环点**，所以任何组合都能叠加。

曲子长度统一 32 小节（4/4）：
  - 循环体恰好 32 小节，满足"循环长度必须是整数小节"的硬约束；
  - 和声每 8 小节闭合一次（卡农进行），第 32 小节正好回到主和弦，接得回开头。
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from compose import common as C                                    # noqa: E402
from musiclib import score as S                                    # noqa: E402
from musiclib import theory as T                                   # noqa: E402

BARS = 32
PHRASE = 8


def _new(cue_id: str, title: str, bpm: float, key: str, scale: str,
         bars: int = BARS, loop: bool = True) -> S.Cue:
    c = S.Cue(cue_id=cue_id, title=title, bpm=bpm, beats_per_bar=4,
              key=key, scale=scale, bars=bars,
              loop_start_bar=0.0, loop_end_bar=bars if loop else None)
    c.notes = title
    setattr(c, "loop", loop)
    return c


# ─────────────────────────── 标题画面 ────────────────────────────────

def build_menu_title() -> S.Cue:
    """最简编制：只有钢琴与一缕弦乐。用作"进入这个世界"的第一印象，
    所以刻意留白最多——玩家刚打开游戏，不需要被信息淹没。"""
    c = _new("menu_title", "原野·序", 66, "D", "major")
    p = c.stem("piano", program=S.GM["acoustic_grand"])
    # 只陈述主题 + 收束句，不进入 B 段：保持"未完成"的邀请感
    C.render_form(c, p, "D", "major", form=[C.THEME_A, C.THEME_C,
                                            C.THEME_A, C.THEME_C],
                  vel_scale=0.94, transpose=12)
    C.add_piano_accompaniment(c, p, "D", "major", C.CANON, 0, BARS,
                              bass_vel=54, arp_vel=42, pattern="up_down_inner")
    S.pedal_bars(p, c, 0, BARS, "per_bar")
    S.humanize_timing(p, 0.016, seed=101)

    st = c.stem("strings", program=S.GM["strings_slow"], gain_db=-3.0)
    C.add_pad(c, st, "D", "major", C.CANON, 4, BARS, beats_per_chord=8,
              low=55, high=76, vel=40)
    S.humanize_timing(st, 0.05, seed=102)
    return c


# ─────────────────────────── 户外 · 白天 ──────────────────────────────

def build_field_day() -> S.Cue:
    """探索/赶路的主曲。情绪弧线：钢琴独白 → 弦乐进场 → 钟琴点亮 → 打开 →
    收回，32 小节走完一个完整的呼吸。这是玩家听到最多的一首，因此
    层次最多（4 层），但任何一层单独听都成立。"""
    c = _new("field_day", "原野·昼", 72, "D", "major")
    p = c.stem("piano", program=S.GM["acoustic_grand"])
    C.render_form(c, p, "D", "major", transpose=12)
    C.add_piano_accompaniment(c, p, "D", "major", C.CANON, 0, BARS,
                              bass_vel=60, arp_vel=48)
    S.pedal_bars(p, c, 0, BARS, "per_bar")
    S.apply_velocity_arch(p, 0.9, 1.08)
    S.humanize_timing(p, 0.018, seed=201)
    S.scale_velocity(p, 1.0, pitch_tilt=0.06, tilt_pivot=74)

    st = c.stem("strings", program=S.GM["strings_ensemble"], gain_db=-2.0)
    # 弦乐从第 4 小节淡入（用力度渐强近似），第 3 乐句撤掉，把空间留给钟琴
    C.add_pad(c, st, "D", "major", C.CANON, 4, 16, beats_per_chord=8,
              low=57, high=79, vel=44)
    C.add_pad(c, st, "D", "major", C.CANON, 24, BARS, beats_per_chord=8,
              low=57, high=79, vel=42)
    S.apply_velocity_arch(st, 0.8, 1.05)
    S.humanize_timing(st, 0.06, seed=202)

    hp = c.stem("harp", program=S.GM["harp"], gain_db=-4.0)
    C.add_harp_figures(c, hp, "D", "major", C.CANON, 8, 24, vel=38)
    C.add_harp_figures(c, hp, "D", "major", C.CANON, 28, BARS, vel=36)
    S.humanize_timing(hp, 0.02, seed=203)

    bl = c.stem("bells", program=S.GM["glockenspiel"], gain_db=-6.0)
    C.add_bell_accents(c, bl, "D", "major", C.CANON, 16, 32, vel=42,
                       per_bar=1, seed=204)
    S.humanize_timing(bl, 0.02, seed=205)
    return c


# ─────────────────────────── 户外 · 夜晚 ──────────────────────────────

def build_field_night() -> S.Cue:
    """同一主题落进 B 自然小调，同一串级数、完全不同的心情。
    织体更疏（分解 6 音而非 8 音）、力度更轻、弦乐换成低音区，
    钟琴换成"微光"（更少、更深、更远）。"""
    c = _new("field_night", "原野·夜", 63, "B", "minor")
    p = c.stem("piano", program=S.GM["acoustic_grand"])
    C.render_form(c, p, "B", "minor", form=[C.THEME_A, C.THEME_C,
                                            C.THEME_A, C.THEME_C],
                  vel_scale=0.9, transpose=12)
    C.add_piano_accompaniment(c, p, "B", "minor", C.CANON_MINOR, 0, BARS,
                              bass_vel=52, arp_vel=40, pattern="up_down_inner")
    S.pedal_bars(p, c, 0, BARS, "half")     # 每两小节一踩：更朦胧
    S.humanize_timing(p, 0.024, seed=301)
    S.scale_velocity(p, 0.95, pitch_tilt=0.08, tilt_pivot=72)

    st = c.stem("strings", program=S.GM["strings_slow"], gain_db=-4.0)
    # 低音区长音（大提琴质感）：夜里的弦乐不该在高音区飘
    C.add_pad(c, st, "B", "minor", C.CANON_MINOR, 0, BARS, beats_per_chord=8,
              low=45, high=64, vel=38)
    S.humanize_timing(st, 0.07, seed=302)

    bl = c.stem("bells", program=S.GM["music_box"], gain_db=-8.0)
    C.add_bell_accents(c, bl, "B", "minor", C.CANON_MINOR, 8, BARS, vel=34,
                       per_bar=1, low=79, high=93, seed=303)
    S.humanize_timing(bl, 0.03, seed=304)
    return c


# ─────────────────────────── 小镇 ────────────────────────────────

def build_village() -> S.Cue:
    """小镇是全作最"轻快"的一首：速度最快、和声最亮（I-iii-IV-V 的田园感），
    用尼龙吉他的指弹与马林巴的木质感替代弦乐，避免"史诗感"入侵日常生活。"""
    c = _new("village", "小镇", 84, "G", "major")
    p = c.stem("piano", program=S.GM["acoustic_grand"], gain_db=-1.0)
    # G 大调比 D 大调高 5 个半音：再提高八度会顶到 E7（钢琴的薄区），
    # 因此小镇保持原八度，靠长笛与马林巴在更高的音区提供亮度
    C.render_form(c, p, "G", "major", transpose=0)
    C.add_piano_accompaniment(c, p, "G", "major", C.VILLAGE, 0, BARS,
                              bass_vel=58, arp_vel=46, pattern="up_down")
    S.pedal_bars(p, c, 0, BARS, "per_bar")
    S.humanize_timing(p, 0.02, seed=401)

    g = c.stem("guitar", program=S.GM["nylon_guitar"])
    # 吉他只做伴奏型指弹，不抢旋律；和声节奏与钢琴一致
    C.add_harp_figures(c, g, "G", "major", C.VILLAGE, 0, BARS, low=48, high=67,
                       vel=36, span=4)
    S.humanize_timing(g, 0.026, seed=402)

    m = c.stem("marimba", program=S.GM["marimba"], gain_db=-6.0)
    C.add_pad(c, m, "G", "major", C.VILLAGE, 8, BARS, beats_per_chord=8,
              low=67, high=84, vel=34)
    S.humanize_timing(m, 0.03, seed=403)

    f = c.stem("winds", program=S.GM["flute"], gain_db=-7.0)
    # 长笛只在 B 段（第 3 乐句）接过旋律一次，避免与钢琴全程打架
    # 长笛：G 大调的 B 段落点 G4~E6（长笛音域 C4~C7 内），保持原八度 ——
    # 这是长笛最有气声质感的中高音区
    C.render_theme(c, f, C.THEME_B, "G", "major", bar_offset=16,
                   vel_scale=0.95, transpose=0)
    S.humanize_timing(f, 0.03, seed=404)
    return c


# ─────────────────────────── 室内 ────────────────────────────────

def build_interior() -> S.Cue:
    """室内：独奏钢琴，近场空间。编制只有一件乐器，空间从"大厅"换成"房间"。
    低音弦与钟琴全部撤掉——室内场景的主角是"安静本身"。"""
    c = _new("interior", "灯下", 58, "F", "major")
    p = c.stem("piano", program=S.GM["acoustic_grand"])
    C.render_form(c, p, "F", "major", form=[C.THEME_A, C.THEME_C,
                                            C.THEME_A, C.THEME_C],
                  vel_scale=0.88, transpose=12)
    C.add_piano_accompaniment(c, p, "F", "major", C.CANON, 0, BARS,
                              bass_vel=48, arp_vel=38, pattern="up_down_inner",
                              rest_bars=(7, 15, 23, 31))
    S.pedal_bars(p, c, 0, BARS, "half")
    S.humanize_timing(p, 0.03, seed=501)
    S.scale_velocity(p, 0.92, pitch_tilt=0.1, tilt_pivot=70)
    return c


# ─────────────────────────── 战略图 ────────────────────────────────

def build_strategic() -> C.Cue:
    """战略图：玩家在鸟瞰整片大陆，因此音乐要"高、远、慢"。
    以温暖 Pad 为地基（不是弦乐，避免太"叙事"），颤音琴走极慢的分解，
    钢琴只留下主题的骨架音——把注意力让给玩家的决策，而不是旋律。"""
    c = _new("strategic", "远望", 64, "C", "major")
    pd = c.stem("pad", program=S.GM["pad_warm"])
    C.add_pad(c, pd, "C", "major", C.CANON, 0, BARS, beats_per_chord=8,
              low=55, high=76, vel=42)
    S.humanize_timing(pd, 0.08, seed=601)

    v = c.stem("vibraphone", program=S.GM["vibraphone"], gain_db=-4.0)
    C.add_harp_figures(c, v, "C", "major", C.CANON, 0, BARS, low=72, high=91,
                       vel=32, span=6)
    S.humanize_timing(v, 0.03, seed=602)

    p = c.stem("piano", program=S.GM["acoustic_grand"], gain_db=-3.0)
    C.render_form(c, p, "C", "major", form=[C.THEME_C, C.THEME_A,
                                            C.THEME_C, C.THEME_A],
                  vel_scale=0.9, transpose=12)
    S.pedal_bars(p, c, 0, BARS, "half")
    S.humanize_timing(p, 0.026, seed=603)

    bl = c.stem("bells", program=S.GM["celesta"], gain_db=-9.0)
    C.add_bell_accents(c, bl, "C", "major", C.CANON, 8, BARS, vel=36,
                       per_bar=1, low=81, high=93, seed=604)
    return c


# ─────────────────────────── 战斗 ────────────────────────────────

def build_battle() -> S.Cue:
    """战斗：**紧张但不吵**。

    这个游戏的战斗是自动结算的策略战，玩家是"看着"而不是"操作着"，
    因此音乐需要推进感（节奏动机）但不需要攻击性。刻意**不用铜管**——
    铜管的强奏是"刺耳"与"嘈杂"最主要的来源；改用低音弦的断奏音型
    负责推进，定音鼓只轻点强拍，主题交给双簧管（最温暖的一件木管），
    让战斗仍然有"人"的温度。

    和声：i - VI - III - VII（Dm - Bb - F - C），自然小调的循环，
    开阔而非压抑，适合"出征"而不是"厮杀"。
    """
    c = _new("battle", "出征", 104, "D", "minor")
    ROM = ["i", "VI", "III", "VII"]

    # 钢琴：右手固定 8 分音型（推进力），左手低音；主题在中段由钢琴先奏一遍
    p = c.stem("piano", program=S.GM["acoustic_grand"], gain_db=-2.0)
    C.add_piano_accompaniment(c, p, "D", "minor", ROM, 0, BARS,
                              bass_vel=66, arp_vel=50, pattern="up_down")
    C.render_theme(c, p, C.THEME_A, "D", "minor", bar_offset=8,
                   vel_scale=1.0, transpose=12)
    C.render_theme(c, p, C.THEME_A, "D", "minor", bar_offset=24,
                   vel_scale=1.02, transpose=12)
    S.pedal_bars(p, c, 0, BARS, "per_bar")
    S.humanize_timing(p, 0.012, seed=701)

    # 弦乐：低音区四分音符断奏（推进） + 中音区长音（厚度）
    st = c.stem("strings", program=S.GM["strings_ensemble"], gain_db=-1.0)
    C.add_bass_note_per_bar(c, st, "D", "minor", ROM, 0, BARS, low=38,
                            high=45, vel=68, beats_per_chord=2)
    C.add_pad(c, st, "D", "minor", ROM, 0, BARS, beats_per_chord=4,
              low=57, high=76, vel=46)
    S.humanize_timing(st, 0.02, seed=702)

    # 定音鼓：只点强拍与乐句末的推进，力度克制
    pc = c.stem("perc", program=S.GM["timpani"], gain_db=-4.0)
    for bar in range(BARS):
        chord = T.roman_chord("D", "minor", ROM[bar % len(ROM)])
        root = T.bass_note(chord, 36, 45)
        pc.add(c.bar(bar), 1.2, root, 58)
        if bar % 4 == 3:
            pc.add(c.bar(bar) + 2.5, 0.5, root, 52)
            pc.add(c.bar(bar) + 3.0, 1.0, root, 62)
    S.humanize_timing(pc, 0.01, seed=703)

    # 双簧管：第 3 乐句由它接过主题（战斗里最"人"的一刻）
    w = c.stem("winds", program=S.GM["oboe"], gain_db=-5.0)
    # 双簧管：D 小调 B 段原落点正好在 D5~B5 —— 双簧管最温暖、最有"人声感"的音区
    C.render_theme(c, w, C.THEME_B, "D", "minor", bar_offset=16,
                   vel_scale=1.0, transpose=0)
    S.humanize_timing(w, 0.025, seed=704)
    return c


# ─────────────────────────── 战斗结算 stinger ──────────────────────────

def build_sting_victory() -> S.Cue:
    """凯旋：不是号角式的炫耀，而是"松了一口气 + 一点光"。
    上行琶音 + 弦乐渐强 + 一记钟琴落在主音上，两小节结束。"""
    c = _new("sting_victory", "凯旋", 72, "D", "major", bars=2, loop=False)
    p = c.stem("piano", program=S.GM["acoustic_grand"])
    chord = T.roman_chord("D", "major", "I")
    v = T.nearest_voicing(chord, None, low=50, high=74, n_notes=4)
    seq = [50, 54, 57, 62, 66, 69, 74]
    for i, pit in enumerate(seq):
        p.add(i * 0.25, 1.5, pit, 58 + i * 4)
    p.add(1.75, 3.0, 74, 76)
    p.add(1.75, 3.0, 62, 62)
    S.pedal_bars(p, c, 0, 2, "per_bar")

    st = c.stem("strings", program=S.GM["strings_ensemble"], gain_db=-1.0)
    for pit in (50, 57, 62, 66):
        st.add(0.0, 3.0, pit, 44)
    st.add(1.5, 2.5, 69, 52)
    st.add(1.5, 2.5, 74, 50)

    bl = c.stem("bells", program=S.GM["glockenspiel"], gain_db=-6.0)
    bl.add(1.5, 3.0, 86, 52)
    bl.add(2.0, 2.5, 81, 44)
    return c


def build_sting_defeat() -> S.Cue:
    """折戟：叹息，不是惨叫。下行级进 + 悬而未决的小三和弦，
    最后停在空五度上（不解决），留下"还可以再来一次"的余地。"""
    c = _new("sting_defeat", "折戟", 63, "B", "minor", bars=2, loop=False)
    p = c.stem("piano", program=S.GM["acoustic_grand"])
    for i, pit in enumerate([69, 66, 62, 61]):
        p.add(i * 0.5, 1.2, pit, 60 - i * 3)
    p.add(2.0, 3.5, 57, 52)
    p.add(2.0, 3.5, 50, 50)
    S.pedal_bars(p, c, 0, 2, "per_bar")

    st = c.stem("strings", program=S.GM["strings_slow"], gain_db=-2.0)
    st.add(0.0, 3.0, 50, 42)
    st.add(0.0, 3.0, 57, 40)
    st.add(2.0, 3.0, 54, 38)
    st.add(2.0, 3.0, 45, 40)
    return c


# ─────────────────────── 战场荒原（非交战时的战场地图）────────────────────

def build_battlefield() -> S.Cue:
    """余烬：**战场地图、但此刻没有交战**。

    与 `battle` 的分工是"环境 vs 事件"：交战曲负责推进，这首负责"这里打过仗"。
    所以它慢（66bpm）、空、**没有打击乐**——低音弦的长音像风穿过空营，
    钢琴只留主题的骨架（每小节一个音），双簧管在第 2 个乐句远远应一句，
    那是"人还在这里"的痕迹。

    和声沿用战斗骨架 i-VI-III-VII、调性同为 D 小调：同一套和声材料，
    速度与力度一降，就从"出征"变成"凭吊"——这是变奏手法在情绪轴上的用法。
    """
    c = _new("battlefield", "余烬", 66, "D", "minor")
    ROM = ["i", "VI", "III", "VII"]

    p = c.stem("piano", program=S.GM["acoustic_grand"])
    # 骨架为主：陈述句只在第 3 个乐句出现一次，其余是收束句的回声
    C.render_form(c, p, "D", "minor", form=[C.THEME_C, C.THEME_C,
                                            C.THEME_A, C.THEME_C],
                  vel_scale=0.85, transpose=12)
    C.add_piano_accompaniment(c, p, "D", "minor", ROM, 0, BARS,
                              bass_vel=46, arp_vel=34, pattern="up_down_inner",
                              rest_bars=(7, 15, 23, 31))
    S.pedal_bars(p, c, 0, BARS, "half")
    S.humanize_timing(p, 0.028, seed=801)

    # 低音弦只做长音床（比夜里那首更低、更慢），不承担旋律
    st = c.stem("strings", program=S.GM["strings_slow"], gain_db=-3.0)
    C.add_pad(c, st, "D", "minor", ROM, 0, BARS, beats_per_chord=8,
              low=45, high=64, vel=36)
    S.humanize_timing(st, 0.08, seed=802)

    w = c.stem("winds", program=S.GM["oboe"], gain_db=-8.0)
    # transpose=12：高音区 = 远处传来的声音（近处该是中低音区）
    C.render_theme(c, w, C.THEME_C, "D", "minor", bar_offset=8,
                   vel_scale=0.8, transpose=12)
    S.humanize_timing(w, 0.03, seed=803)
    return c


# ─────────────────────── 厅堂（大建筑内部）─────────────────────────────

def build_interior_hall() -> S.Cue:
    """厅堂：大建筑内部（MEGA_INTERIOR）。

    与 `interior`（小房间、独奏钢琴）的分工是**空间**而不是情绪：编制加上弦乐与
    钢片琴、混响从 room 换成 hall 且湿度加大——同一段音乐放进更大的屋子，
    玩家一进门就听得出"这里比作坊大得多"。速度比室内曲略快（62 vs 58）：
    它不是私密独白，是有人走动的公共空间。
    """
    c = _new("interior_hall", "厅堂", 62, "F", "major")
    p = c.stem("piano", program=S.GM["acoustic_grand"])
    C.render_form(c, p, "F", "major", transpose=12, vel_scale=0.94)
    C.add_piano_accompaniment(c, p, "F", "major", C.CANON, 0, BARS,
                              bass_vel=54, arp_vel=44)
    S.pedal_bars(p, c, 0, BARS, "per_bar")
    S.humanize_timing(p, 0.02, seed=901)

    st = c.stem("strings", program=S.GM["strings_slow"], gain_db=-3.0)
    C.add_pad(c, st, "F", "major", C.CANON, 0, BARS, beats_per_chord=8,
              low=57, high=79, vel=42)
    S.humanize_timing(st, 0.06, seed=902)

    # 钢片琴（比钟琴暗一档）：点状音只在后半段出现，像窗外透进来的光
    bl = c.stem("bells", program=S.GM["celesta"], gain_db=-9.0)
    C.add_bell_accents(c, bl, "F", "major", C.CANON, 16, BARS, vel=34,
                       per_bar=1, seed=903)
    S.humanize_timing(bl, 0.02, seed=904)
    return c


# ─────────────────────── 夜镇（村落的夜）───────────────────────────────

def build_village_night() -> S.Cue:
    """夜镇：白天的小镇（84bpm、吉他+马林巴的摇曳）慢下来的样子。

    调式搬进关系小调（G 大调 → E 自然小调，与"原野·昼 → 原野·夜"同一套做法）：
    **同一条主题级数，换一套心情**。织体也从"弹唱"退成"余音"——
    吉他换成慢速低音区指弹、马林巴只剩零星落点，力度整体压到白天的七成。
    """
    c = _new("village_night", "夜镇", 72, "E", "minor")
    p = c.stem("piano", program=S.GM["acoustic_grand"])
    C.render_form(c, p, "E", "minor", form=[C.THEME_A, C.THEME_C,
                                            C.THEME_A, C.THEME_C],
                  vel_scale=0.86, transpose=12)
    C.add_piano_accompaniment(c, p, "E", "minor", C.CANON_MINOR, 0, BARS,
                              bass_vel=48, arp_vel=36, pattern="up_down_inner")
    S.pedal_bars(p, c, 0, BARS, "half")
    S.humanize_timing(p, 0.026, seed=1001)

    g = c.stem("guitar", program=S.GM["nylon_guitar"], gain_db=-2.0)
    C.add_harp_figures(c, g, "E", "minor", C.CANON_MINOR, 0, BARS, low=45,
                       high=64, vel=32, span=4)
    S.humanize_timing(g, 0.03, seed=1002)

    m = c.stem("marimba", program=S.GM["marimba"], gain_db=-10.0)
    C.add_bell_accents(c, m, "E", "minor", C.CANON_MINOR, 8, BARS, vel=28,
                       per_bar=1, low=64, high=79, seed=1003)
    S.humanize_timing(m, 0.03, seed=1004)
    return c


# ─────────────────────── 变奏 B 组（长时抗疲劳轮换）──────────────────────
#
# 为什么要有它们（游戏配乐最佳实践里的"长时抗疲劳"）：玩家会在同一张图上停留很久，
# 同一首曲子循环几十遍。行业做法是准备"同源的第二版"轮换播放——主题不变（可辨识），
# 但主奏乐器换人、织体换法（不可预测）。这里三首变奏与它们的基础曲**同调、同速、
# 同长、层名一一对应**，因此运行时可以整层替换而无缝：换的只是"谁在唱"。
#
# 与设计文档里那条"无旋律变奏交替播放"提案的关系：那条是"同曲再生成一版只有伴奏"；
# 本条是"同曲换主奏"——不额外占曲目位，也不会让玩家觉得"音乐突然少了点什么"。
# 两条可以并存，本批先落地后者。

def build_field_day_b() -> S.Cue:
    """原野·昼（变奏 B）：**把主奏从钢琴换到竖琴**，钢琴退成纯伴奏。

    竖琴唱主题时值不变、音区同钢琴版（D5~D6），但音色是"颗粒的、向上的"——
    同一段旋律从"有人在弹钢琴"变成"光落在水面上"。弦乐这一版更轻，
    钟琴只在收束句出现：编制不变，配重变了。
    """
    c = _new("field_day_b", "原野·昼·竖琴", 72, "D", "major")

    p = c.stem("piano", program=S.GM["acoustic_grand"], gain_db=-2.0)
    # 钢琴只弹伴奏：低音 + 分解和弦，不再碰旋律（"让位"在这首里是编曲手法）
    C.add_piano_accompaniment(c, p, "D", "major", C.CANON, 0, BARS,
                              bass_vel=58, arp_vel=46, pattern="up_down")
    S.pedal_bars(p, c, 0, BARS, "per_bar")
    S.humanize_timing(p, 0.02, seed=1101)

    hp = c.stem("harp", program=S.GM["harp"], gain_db=-1.0)
    # 主奏：完整曲式 + 走句；力度压住（竖琴的"亮"不需要靠响度）
    C.render_form(c, hp, "D", "major", transpose=12, vel_scale=0.9)
    C.add_harp_figures(c, hp, "D", "major", C.CANON, 0, BARS, low=57, high=84,
                       vel=32, span=6)
    S.humanize_timing(hp, 0.02, seed=1102)

    st = c.stem("strings", program=S.GM["strings_ensemble"], gain_db=-5.0)
    C.add_pad(c, st, "D", "major", C.CANON, 8, 24, beats_per_chord=8,
              low=57, high=79, vel=36)
    S.humanize_timing(st, 0.06, seed=1103)

    bl = c.stem("bells", program=S.GM["glockenspiel"], gain_db=-9.0)
    C.add_bell_accents(c, bl, "D", "major", C.CANON, 24, BARS, vel=36,
                       per_bar=1, seed=1104)
    S.humanize_timing(bl, 0.02, seed=1105)
    return c


def build_village_b() -> S.Cue:
    """小镇（变奏 B）：**把主奏换到马林巴**（木质打击唱旋律），吉他更活跃，
    长笛只在收束句换气。

    木质打击乐唱旋律在日系游戏里很常见（把"生活的手工感"写进音色），
    它让同一段主题从"钢琴的抒情"变成"木头的轻快"——小镇需要的正是后者。
    钢琴在这一版里退到低音与轻和弦。
    """
    c = _new("village_b", "小镇·木琴", 84, "G", "major")

    p = c.stem("piano", program=S.GM["acoustic_grand"], gain_db=-4.0)
    C.add_piano_accompaniment(c, p, "G", "major", C.VILLAGE, 0, BARS,
                              bass_vel=54, arp_vel=38, pattern="up_down_inner")
    S.pedal_bars(p, c, 0, BARS, "per_bar")
    S.humanize_timing(p, 0.02, seed=1201)

    m = c.stem("marimba", program=S.GM["marimba"], gain_db=-1.0)
    # 主奏版：完整曲式；收束句留给长笛——一件乐器唱完全曲会被听腻
    C.render_form(c, m, "G", "major", form=[C.THEME_A, C.THEME_C,
                                            C.THEME_A, C.THEME_C],
                  transpose=0, vel_scale=0.9)
    S.humanize_timing(m, 0.014, seed=1202)

    g = c.stem("guitar", program=S.GM["nylon_guitar"], gain_db=-1.0)
    C.add_harp_figures(c, g, "G", "major", C.VILLAGE, 0, BARS, low=48, high=67,
                       vel=38, span=6)
    S.humanize_timing(g, 0.024, seed=1203)

    f = c.stem("winds", program=S.GM["flute"], gain_db=-6.0)
    C.render_theme(c, f, C.THEME_C, "G", "major", bar_offset=24,
                   vel_scale=0.9, transpose=0)
    S.humanize_timing(f, 0.03, seed=1204)
    return c


def build_battle_b() -> C.Cue:
    """出征（变奏 B）：**把推进音型交给弦乐**，钢琴改为长音和弦与骨架主题，
    定音鼓更疏（只在乐句末点两下），双簧管提前到第 2 个乐句进场。

    基础版是"钢琴推动 + 弦乐铺底"，这一版反过来——同一场合的两种紧张方式：
    前者的紧张来自颗粒，后者的紧张来自持续的张力。
    """
    c = _new("battle_b", "出征·弦乐", 104, "D", "minor")
    ROM = ["i", "VI", "III", "VII"]

    # 弦乐：低音区八分音型（推进）+ 中音区长音（张力）
    st = c.stem("strings", program=S.GM["strings_ensemble"], gain_db=-1.0)
    for bar in range(BARS):
        chord = T.roman_chord("D", "minor", ROM[bar % len(ROM)])
        root = T.bass_note(chord, 38, 45)
        for k in range(4):
            # 每小节四个八分、弱-强交替的音头：比四分音符更有"走"的感觉
            st.add(c.bar(bar) + k * 2.0, 1.6, root, 62 if k % 2 else 54)
    C.add_pad(c, st, "D", "minor", ROM, 0, BARS, beats_per_chord=4,
              low=57, high=76, vel=42)
    S.humanize_timing(st, 0.016, seed=1301)

    p = c.stem("piano", program=S.GM["acoustic_grand"], gain_db=-3.0)
    # 钢琴不再驱动节奏：留骨架音 + 一次完整陈述
    C.render_form(c, p, "D", "minor", form=[C.THEME_C, C.THEME_A,
                                            C.THEME_C, C.THEME_C],
                  vel_scale=0.96, transpose=12)
    S.pedal_bars(p, c, 0, BARS, "half")
    S.humanize_timing(p, 0.02, seed=1302)

    # 定音鼓：只在每 8 小节的句末点两下（比基础版更克制）
    pc = c.stem("perc", program=S.GM["timpani"], gain_db=-4.0)
    for bar in range(BARS):
        if bar % 8 == 7:
            chord = T.roman_chord("D", "minor", ROM[bar % len(ROM)])
            root = T.bass_note(chord, 36, 45)
            pc.add(c.bar(bar) + 2.0, 1.0, root, 54)
            pc.add(c.bar(bar) + 3.0, 1.0, root, 60)
    S.humanize_timing(pc, 0.01, seed=1303)

    w = c.stem("winds", program=S.GM["oboe"], gain_db=-5.0)
    # 主题提前到第 2 个乐句进场，收束句再应一次。
    # transpose=0：THEME_B 自身已经升了八度（落点 D5~B5），再 +12 会顶到 B6——
    # 那是双簧管又薄又刺的极限区（实测整曲刺耳度因此从 0.08 跳到 0.24）。
    C.render_theme(c, w, C.THEME_B, "D", "minor", bar_offset=8,
                   vel_scale=1.0, transpose=0)
    C.render_theme(c, w, C.THEME_B, "D", "minor", bar_offset=24,
                   vel_scale=0.95, transpose=0)
    S.humanize_timing(w, 0.025, seed=1304)
    return c


# ─────────────────────── 结算/标点 stinger（补）──────────────────────────

def build_sting_conquest() -> S.Cue:
    """入主：占领据点 / 通关时的"落定"，比 `sting_victory` 长、也更庄重。

    为什么需要它：战斗结算的短句说的是"这一仗赢了"，占领说的是"这地方归你了"——
    后者是**领地层面**的事件，需要一个更完整的句子（8 小节 ≈ 25s）：
    低音弦渐强上来、钢琴走一次上行、钟琴把主音落在最后两小节。
    仍然不用铜管：本作的"庄重"来自和声的完整，不来自音量。
    """
    c = _new("sting_conquest", "入主", 76, "D", "major", bars=8, loop=False)
    ROM = ["I", "vi", "IV", "V", "I", "vi", "IV", "I"]

    st = c.stem("strings", program=S.GM["strings_ensemble"], gain_db=-1.0)
    for bar, roman in enumerate(ROM):
        v = T.nearest_voicing(T.roman_chord("D", "major", roman), None,
                              low=50, high=74, n_notes=4)
        vel = int(34 + bar * 3.4)          # 渐强 = "落定"的物理隐喻
        for pit in v:
            st.add(c.bar(bar), 3.6, pit, vel)

    p = c.stem("piano", program=S.GM["acoustic_grand"])
    for i, pit in enumerate([50, 54, 57, 62, 66, 69, 74]):
        p.add(i * 0.25, 2.0, pit, 56 + i * 3)      # 上行琶音
    p.add(2.0, 4.0, 62, 58)
    p.add(2.0, 4.0, 66, 54)
    for i, pit in enumerate(T.nearest_voicing(T.roman_chord("D", "major", "I"),
                                              None, low=50, high=74, n_notes=4)):
        p.add(c.bar(6), 8.0, pit, 60 - i * 3)       # 末两小节落在主和弦
    S.pedal_bars(p, c, 0, 8, "per_bar")

    bl = c.stem("bells", program=S.GM["glockenspiel"], gain_db=-6.0)
    bl.add(c.bar(6) + 2.0, 3.0, 86, 54)            # 主音（D6）
    bl.add(c.bar(7), 3.0, 81, 46)                  # 五音（A5）
    return c


def build_sting_arrival() -> S.Cue:
    """抵达：跨图走进一个新地方的音乐标点（2 小节 ≈ 4s）。

    只做"抬头看了一眼"的动作：竖琴一掠向上、钢琴点两个音，最后停在**五音**上
    不落主音——旅程还要继续，这不是目的地。
    """
    c = _new("sting_arrival", "抵达", 72, "D", "major", bars=2, loop=False)

    hp = c.stem("harp", program=S.GM["harp"], gain_db=-2.0)
    for i, pit in enumerate([62, 66, 69, 74, 78]):
        hp.add(i * 0.22, 1.4, pit, 46 + i * 4)

    p = c.stem("piano", program=S.GM["acoustic_grand"])
    p.add(0.0, 2.0, 50, 54)
    p.add(1.0, 2.0, 57, 50)
    p.add(1.5, 2.5, 69, 52)
    S.pedal_bars(p, c, 0, 2, "per_bar")

    bl = c.stem("bells", program=S.GM["glockenspiel"], gain_db=-8.0)
    bl.add(1.5, 2.0, 81, 44)
    return c


# ─────────────────────────── 曲库 ────────────────────────────────

BUILDERS = [
    ("menu_title", build_menu_title),
    ("field_day", build_field_day),
    ("field_day_b", build_field_day_b),
    ("field_night", build_field_night),
    ("village", build_village),
    ("village_b", build_village_b),
    ("village_night", build_village_night),
    ("interior", build_interior),
    ("interior_hall", build_interior_hall),
    ("strategic", build_strategic),
    ("battle", build_battle),
    ("battle_b", build_battle_b),
    ("battlefield", build_battlefield),
    ("sting_victory", build_sting_victory),
    ("sting_defeat", build_sting_defeat),
    ("sting_conquest", build_sting_conquest),
    ("sting_arrival", build_sting_arrival),
]

## 变奏族：同族成员**同调、同速、同长、层名一一对应**，运行时按访问轮换。
## 这里声明"谁能和谁互换"，而不是让运行时去猜名字后缀——单一真相源。
VARIATION_SETS = {
    "field_day": ["field_day", "field_day_b"],
    "village": ["village", "village_b"],
    "battle": ["battle", "battle_b"],
}

# 每个 cue 的混音覆盖（默认配方在 musiclib/mix.py；这里只写"这首不一样"的地方）
MIX_OVERRIDES = {
    "interior": {"piano": {"rev_style": "room", "rev_mix": 0.17}},   # 室内用近场空间
    "battle": {"piano": {"hp": 60.0}},           # 战斗低频让给低音弦与定音鼓
    "strategic": {"piano": {"rev_mix": 0.30}},
    # 大厅：更长的混响 + 更大的湿度（与小房间的 room/0.17 形成对照）
    "interior_hall": {"piano": {"rev_style": "hall", "rev_mix": 0.34},
                      "strings": {"rev_mix": 0.30}},
    # 荒原：空旷感来自"湿"而不是"响"
    "battlefield": {"piano": {"rev_mix": 0.30}, "strings": {"rev_mix": 0.32}},
    # 夜镇：夜里的院子比白天"有空间"，但没有大厅那么大
    "village_night": {"piano": {"rev_mix": 0.26}, "guitar": {"rev_mix": 0.30}},
}

## 变奏族里"主奏换人"后的层配平（覆盖 mix.LAYER_BALANCE_DB 的目标偏移）。
## 基础曲里竖琴/马林巴是点缀（-8/-9dB），变奏 B 里它们是主奏——不覆盖就会被
## 自动配平压到钢琴之下 9dB，主奏等于没有。这是"编曲意图"进混音的唯一入口。
LAYER_BALANCE_BY_CUE = {
    "field_day_b": {"harp": -1.0, "strings": -7.5, "bells": -11.0},
    "village_b": {"marimba": -1.0, "guitar": -6.5, "winds": -6.0, "piano": 0.0},
    "battle_b": {"strings": -2.5, "perc": -6.0, "winds": -3.5, "piano": 0.0},
}


def build_all() -> dict:
    return {cue_id: fn() for cue_id, fn in BUILDERS}


def build_one(cue_id: str) -> S.Cue:
    for cid, fn in BUILDERS:
        if cid == cue_id:
            return fn()
    raise KeyError("未知 cue: %s（可选：%s）"
                   % (cue_id, ", ".join(c for c, _ in BUILDERS)))


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    for cue_id, cue in build_all().items():
        stems = ", ".join("%s(%d音)" % (n, len(s.notes))
                          for n, s in cue.stems.items())
        print("%-14s %-8s %-14s %3d bpm %2d小节  %s"
              % (cue_id, cue.title, "%s %s" % (cue.key, cue.scale), cue.bpm,
                 cue.bars, stems))
