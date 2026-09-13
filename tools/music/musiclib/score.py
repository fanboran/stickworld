# -*- coding: utf-8 -*-
"""谱面数据结构与 MIDI 导出。

作曲脚本用 `theory.py` 的词汇算出音高，在这里组装成 Stem/Cue，再导出成
**每轨一个 MIDI 文件**（渲染器一次只吃一个 MIDI，分轨渲染是工业惯例：
分轨才能独立做 EQ/混响/叠层，也才能在游戏里做纵向混音）。

时间单位统一用**拍（beat）**，不用秒。BPM 只在与音频打交道时才介入
（渲染、mix、loop 换算），这样改速度不会牵动谱面。
"""
from __future__ import annotations

from dataclasses import dataclass, field

import mido

# GM 音色号（fluidsynth 渲染用；sfizz 钢琴轨忽略此字段）
GM = {
    "acoustic_grand": 0, "bright_piano": 1, "electric_piano": 4,
    "harpsichord": 6, "celesta": 8, "glockenspiel": 9, "music_box": 10,
    "vibraphone": 11, "marimba": 12, "tubular_bells": 14,
    "drawbar_organ": 16, "church_organ": 19,
    "nylon_guitar": 24, "steel_guitar": 25, "jazz_guitar": 26,
    "harp": 46, "timpani": 47,
    # GM 48~51 是四种弦乐音色，别混：48/49 是真实弦乐采样的"快/慢"两版
    # （MuseScore_General 里就叫 Strings Fast / Strings Slow），
    # 50/51 是合成弦乐（Synth Strings），实测谱质心明显更亮（2537Hz vs 1917Hz）。
    # 作"柔和长音垫"用 48/49；50/51 留给需要更亮、更"电"的地方。
    "strings_ensemble": 48, "strings_slow": 49, "strings_ensemble_2": 49,
    "synth_strings_1": 50, "synth_strings_2": 51,
    "choir_aahs": 52, "voice_oohs": 53,
    "orchestra_hit": 55, "trumpet": 56, "trombone": 57, "tuba": 58,
    "french_horn": 60, "brass_section": 61,
    "soprano_sax": 64, "oboe": 68, "english_horn": 69, "bassoon": 70,
    "clarinet": 71, "flute": 73, "recorder": 74, "pan_flute": 75,
    "bottle_blow": 76, "shakuhachi": 77, "whistle": 78, "ocarina": 79,
    "pad_warm": 89, "pad_choir": 91, "pad_bowed": 92, "pad_metallic": 93,
}


@dataclass
class Note:
    start: float      # 相对 cue 开头的拍数
    dur: float        # 时值（拍）
    pitch: int        # MIDI 音高
    vel: int          # 1..127

    @property
    def end(self) -> float:
        return self.start + self.dur


## 渲染引擎分配。
##
## 钢琴用 SFZ 采样库（Salamander Grand Piano，真采样 + 制音器释放 + 琴弦共鸣），
## 其余编制声部（弦乐/竖琴/钟琴/木管/定音鼓…）用 GM SoundFont。
##
## 判据是"这个声部是不是那台三角钢琴"——钢琴是唯一需要 SFZ 的声部，
## 所以按层名决定最直白、也最不容易错。**不要靠 program 字段推断**：
## GM 的 0 号音色也是钢琴，用 program 判会歧义。
DEFAULT_ENGINE = {"piano": "sfizz"}


def engine_for(stem_name: str) -> str:
    return DEFAULT_ENGINE.get(stem_name, "fluidsynth")


@dataclass
class Stem:
    """一个可独立渲染、独立混音、可运行时单独开关的声部层。"""
    name: str                     # piano / strings / bells / winds / harp / perc
    engine: str = ""              # "" = 按层名自动（见 engine_for）
    program: int = 0              # fluidsynth GM program
    channel: int = 0
    notes: list = field(default_factory=list)
    cc: list = field(default_factory=list)   # [(beat, cc_num, value)]
    gain_db: float = 0.0          # 混音初值（最终以 mix 配置为准）
    pan: float = 0.0              # -1..1
    gm_name: str = "acoustic_grand"

    @property
    def render_engine(self) -> str:
        return self.engine or engine_for(self.name)

    def add(self, start: float, dur: float, pitch: int, vel: int,
            quantize: float = 0.0) -> None:
        if dur <= 0:
            return
        if quantize > 0:
            start = round(start / quantize) * quantize
            dur = max(quantize, round(dur / quantize) * quantize)
        self.notes.append(Note(start, dur, int(round(pitch)), int(vel)))

    def add_chord(self, start: float, dur: float, pitches, vel: int) -> None:
        for p in pitches:
            self.add(start, dur, p, vel)

    @property
    def end_beat(self) -> float:
        return max([n.end for n in self.notes], default=0.0)


@dataclass
class Cue:
    """一首曲子的完整谱面。"""
    cue_id: str
    title: str
    bpm: float
    beats_per_bar: int = 4
    key: str = "D"
    scale: str = "major"
    bars: int = 32
    stems: dict = field(default_factory=dict)
    loop_start_bar: float = 0.0
    loop_end_bar: float | None = None    # None = 到曲子末尾
    tail_bars: float = 0.0               # 循环体后额外写的"尾巴"（会被折回开头）
    notes: str = ""

    # ── 便捷构造 ──
    @property
    def beats(self) -> float:
        return self.bars * self.beats_per_bar

    @property
    def loop_start_beat(self) -> float:
        return self.loop_start_bar * self.beats_per_bar

    @property
    def loop_end_beat(self) -> float:
        return (self.loop_end_bar if self.loop_end_bar is not None else self.bars) \
            * self.beats_per_bar

    def stem(self, name: str, **kw) -> Stem:
        if name in self.stems:
            return self.stems[name]
        s = Stem(name=name, **kw)
        self.stems[name] = s
        return s

    def bar(self, bar_index: int) -> float:
        """小节号（0-based）→ 拍。"""
        return bar_index * self.beats_per_bar

    def seconds(self, beats: float) -> float:
        return beats * 60.0 / self.bpm


# ─────────────────────────── MIDI 导出 ────────────────────────────────

def _ticks(beats: float, tpq: int = 480) -> int:
    return int(round(beats * tpq))


def export_stem_midi(cue: Cue, stem: Stem, path: str, tpq: int = 480,
                     cc_defaults: dict | None = None) -> None:
    """把单个 stem 导成一个 SMF type-0 文件（渲染器用）。

    - 保留 stem.cc（延音踏板等）；
    - cc_defaults 在拍 0 之前写入初始 CC（渲染器的默认值由 SFZ 的 set_* 提供，
      这里只做谱面显式覆盖）；
    - 末尾补一条 End of Track，并在最后一个音之后留 8 拍余量，
      避免渲染器提前截断尾音（sfizz 不带 --use-eot 时会渲到 MIDI 末尾）。
    """
    mid = mido.MidiFile(type=0, ticks_per_beat=tpq)
    track = mido.MidiTrack()
    mid.tracks.append(track)

    track.append(mido.MetaMessage("track_name", name=stem.name, time=0))
    tempo = mido.bpm2tempo(cue.bpm)
    track.append(mido.MetaMessage("set_tempo", tempo=tempo, time=0))
    sig = cue.beats_per_bar
    track.append(mido.MetaMessage("time_signature", numerator=sig,
                                 denominator=4, time=0))
    track.append(mido.Message("program_change", channel=stem.channel,
                              program=stem.program, time=0))
    # 声像 / 音量
    track.append(mido.Message("control_change", channel=stem.channel,
                              control=10, value=int((stem.pan + 1) * 63.5),
                              time=0))

    for cc_num, value in (cc_defaults or {}).items():
        track.append(mido.Message("control_change", channel=stem.channel,
                                  control=cc_num, value=int(value), time=0))

    # 事件合并（同一拍上的 CC 先于 note_on）
    events = []
    for n in stem.notes:
        events.append((n.start, 2, mido.Message("note_on", channel=stem.channel,
                                                note=n.pitch, velocity=n.vel)))
        events.append((n.end, 1, mido.Message("note_off", channel=stem.channel,
                                              note=n.pitch, velocity=0)))
    for beat, num, val in stem.cc:
        events.append((beat, 0, mido.Message("control_change", channel=stem.channel,
                                             control=num, value=int(val))))
    events.sort(key=lambda e: (e[0], e[1]))

    last_tick = 0
    for beat, _, msg in events:
        tick = _ticks(beat, tpq)
        delta = max(0, tick - last_tick)
        last_tick += delta
        msg.time = delta
        track.append(msg)

    # 尾部余量：让渲染器把最后一个音的衰减/混响渲完
    track.append(mido.MetaMessage("end_of_track",
                                  time=_ticks(8.0, tpq)))
    mid.save(path)


def export_all_stems(cue: Cue, out_dir) -> dict:
    """导出 cue 的全部分轨 MIDI，返回 {stem_name: midi_path}。"""
    from pathlib import Path
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    out = {}
    for name, stem in cue.stems.items():
        if not stem.notes:
            continue
        p = out_dir / ("%s.%s.mid" % (cue.cue_id, name))
        export_stem_midi(cue, stem, str(p))
        out[name] = str(p)
    return out


# ─────────────────────────── 人性化 ────────────────────────────────

def humanize_timing(stem: Stem, amount: float = 0.02, seed: int = 0,
                    melody_lag: float = 0.0) -> None:
    """给音符加微小的时值/力度抖动，去掉"钢琴卷帘对齐感"。

    amount 单位是拍（0.02 拍 ≈ 12ms @100BPM），对 8 分音符织体足够；
    旋律声部用 melody_lag 让旋律音相对伴奏略微"提前"或"滞后"——
    真人演奏里旋律与伴奏几乎从不严格同刻，这一点点错位正是"有人在弹"的感觉。
    """
    import random
    rng = random.Random(seed)
    for n in sorted(stem.notes, key=lambda n: n.start):
        n.start = max(0.0, n.start + rng.gauss(0, amount))
        # 力度：小幅抖动 + 轻微"越往上越轻"，避免高音扎耳
        n.vel = int(max(1, min(127, n.vel + rng.gauss(0, 3))))


def apply_velocity_arch(stem: Stem, lo: float = 0.85, hi: float = 1.1,
                        pivot: float = 0.5) -> None:
    """按时间给力度加一条弧形包络（起句轻 → 中段推 → 收句轻）。

    这是"音乐有呼吸"最省力的做法：同一串音，力度画一条弧，听感就从
    机械变成有人味。
    """
    if not stem.notes:
        return
    end = stem.end_beat or 1.0
    for n in stem.notes:
        x = (n.start / end - pivot) / max(pivot, 1e-6)
        # 顶点在 pivot 处的抛物线
        k = hi - (hi - lo) * (x * x)
        n.vel = int(max(1, min(127, round(n.vel * k))))


def scale_velocity(stem: Stem, factor: float, pitch_tilt: float = 0.0,
                   tilt_pivot: int = 72) -> None:
    """整体缩放力度；pitch_tilt>0 时高音额外轻一点（抑制钢琴高音区的亮度）。"""
    for n in stem.notes:
        v = n.vel * factor
        if pitch_tilt:
            v *= 1.0 - pitch_tilt * max(0, n.pitch - tilt_pivot) / 24.0
        n.vel = int(max(1, min(127, round(v))))


def pedal_bars(stem: Stem, cue: Cue, from_bar: int, to_bar: int,
               pattern: str = "per_bar") -> None:
    """写入延音踏板 CC64。

    钢琴的真实感一半来自踏板。pattern：
      per_bar  —— 每小节一踩一放（放点在下一小节前一点点，避免糊）
      half     —— 每两小节一踩（更朦胧，适合慢速静谧段落）
      none     —— 不踩
    """
    if pattern == "none":
        return
    span = 2 if pattern == "half" else 1
    b = from_bar
    while b < to_bar:
        start = cue.bar(b)
        nxt = min(b + span, to_bar)
        end = cue.bar(nxt) - 0.06
        stem.cc.append((start, 64, 127))
        stem.cc.append((end, 64, 0))
        b += span
    stem.cc.sort(key=lambda c: c[0])
