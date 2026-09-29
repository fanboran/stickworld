# -*- coding: utf-8 -*-
"""MusicXML 导出 —— 把谱面落成**能被 MuseScore 打开、能打印**的乐谱。

为什么要有它：谱面现在只活在 `themes.py` / `cues.py` 的代码里——那是最精确的
"演奏数据"，但不是能交给人看的形式；而且一旦哪天渲染工具链跑不动了（引擎版本、
采样库许可、操作系统），代码之外就什么都没有了。乐谱是音乐里最耐久的载体，
所以交付件里除了 OGG，还应该有一份**独立的谱**。

导出规则（写清楚，避免下一任把它当"权威演奏版"）：

  - **音高、和声、曲式**与代码逐音对应（这是谱的全部价值所在）；
  - **时值量化到十六分音符**：代码里的时值带人性化抖动（±0.02 拍）与"留气口"
    的偏移（如 7.7 拍），谱上按最近的标准音符值记；跨小节的音用**连音线**拆开，
    同时起音的音写成一个**和弦**；
  - **同一声部内不允许重叠**：钢琴的低音长音与右手分解、竖琴琶音的余音都是重叠的，
    谱上按标准做法分**声部**（voice）写，每个声部的时值各自填满小节；
  - 力度写进 `<sound dynamics>`；谱上不写强弱记号（那是演奏提示，由渲染脚本的
    力度曲线负责）；
  - 循环曲目在第 1 小节与末小节标出**反复记号**（`|:` `:|`）；
  - 一个层 = 一个声部（part）；钢琴写成大谱表（高音 + 低音，按音高分谱表）。
"""
from __future__ import annotations

import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape

from musiclib import theory as T

DIVISIONS = 480          # 每四分音符的 division 数（与 MIDI 导出的 tpq 一致）
QUANT = 0.125            # 记谱量化：32 分音符（= 可记谱的最短时值，保证分解无余数）
MIN_DUR = 0.125          # 最短时值（谱上不出现比 32 分更短的）
EPS = 1e-6

# 标准音符值（拍）→ MusicXML type
_TYPES = [
    (4.0, "whole"), (3.0, "half", "dot"), (2.0, "half"),
    (1.5, "quarter", "dot"), (1.0, "quarter"),
    (0.75, "eighth", "dot"), (0.5, "eighth"),
    (0.375, "16th", "dot"), (0.25, "16th"), (0.125, "32nd"),
]
_FIFTHS_MAJOR = {"C": 0, "G": 1, "D": 2, "A": 3, "E": 4, "B": 5, "F#": 6,
                 "F": -1, "Bb": -2, "Eb": -3, "Ab": -4, "Db": -5}
_FIFTHS_MINOR = {"A": 0, "E": 1, "B": 2, "F#": 3, "C#": 4, "G#": 5,
                 "D": -1, "G": -2, "C": -3, "F": -4, "Bb": -5}

# 层名 → 谱上写的乐器名
PART_NAMES = {
    "piano": "钢琴", "strings": "弦乐", "pad": "合成垫", "harp": "竖琴",
    "bells": "色彩打击", "vibraphone": "颤音琴", "marimba": "马林巴",
    "guitar": "尼龙吉他", "winds": "独奏木管", "perc": "定音鼓",
}


def _fifths(key: str, scale: str) -> int:
    table = _FIFTHS_MINOR if scale.startswith("minor") else _FIFTHS_MAJOR
    return table.get(key, 0)


def _spelling(pitch: int, fifths: int) -> tuple:
    """MIDI → (step, alter, octave)，按调号的升降号方向拼写。"""
    names = T.NOTE_NAMES if fifths >= 0 else T.FLAT_NAMES
    name = names[pitch % 12]
    step = name[0]
    alter = -1 if name.endswith("b") else (1 if name.endswith("#") else 0)
    return step, alter, pitch // 12 - 1


def _decompose(pos: float, length: float, bar_beats: float) -> list:
    """把 (起点, 时值) 拆成标准音符值，返回 [(dur, type, dotted), ...]。

    跨小节的音在这里按小节切开，调用方用连音线串起来——谱上不允许音跨小节线。
    """
    out = []
    guard = 0
    while length > EPS and guard < 64:
        guard += 1
        space = bar_beats - pos
        if space <= EPS:
            pos = 0.0
            continue
        want = min(length, space)
        for d, name, *dot in _TYPES:
            if d <= want + EPS:
                out.append((d, name, bool(dot)))
                break
        else:
            # 理论上到不了这里：起点与时值都已量化到 1/32 拍，分解必然整除
            raise AssertionError("时值分解有余数：pos=%.4f len=%.4f" % (pos, length))
        length -= out[-1][0]
        pos += out[-1][0]
    return out


def _notes_xml(pitches, dur: float, name: str, dotted: bool, fifths: int,
               voice: int, staff: int, tie_start: bool, tie_stop: bool,
               vel: int | None) -> list:
    """一个和弦（1 个或多个同时起音的音）→ 若干行 <note>。"""
    out = []
    for k, pitch in enumerate(sorted(pitches)):
        step, alter, octave = _spelling(pitch, fifths)
        out.append("      <note>")
        if k:
            out.append("        <chord/>")
        if tie_start:
            out.append('        <tie type="start"/>')
        if tie_stop:
            out.append('        <tie type="stop"/>')
        out.append("        <pitch>")
        out.append("          <step>%s</step>" % step)
        if alter:
            out.append("          <alter>%d</alter>" % alter)
        out.append("          <octave>%d</octave>" % octave)
        out.append("        </pitch>")
        out.append("        <duration>%d</duration>"
                   % int(round(dur * DIVISIONS)))
        if not tie_stop and vel and 0 < vel < 128:
            out.append('        <sound dynamics="%d"/>' % vel)
        out.append("        <voice>%d</voice>" % voice)
        out.append("        <type>%s</type>" % name)
        if dotted:
            out.append("        <dot/>")
        if tie_start or tie_stop:
            out.append("        <notations>")
            if tie_start:
                out.append('          <tied type="start"/>')
            if tie_stop:
                out.append('          <tied type="stop"/>')
            out.append("        </notations>")
        if staff:
            out.append("        <staff>%d</staff>" % staff)
        out.append("      </note>")
    return out


def _rest_xml(dur: float, name: str, dotted: bool, voice: int) -> list:
    out = ["      <note>", "        <rest/>",
           "        <duration>%d</duration>" % int(round(dur * DIVISIONS)),
           "        <voice>%d</voice>" % voice,
           "        <type>%s</type>" % name]
    if dotted:
        out.append("        <dot/>")
    out.append("      </note>")
    return out


def _events(stem, limit: float | None = None) -> list:
    """量化后按 (起点, 时值) 合成事件：同时同长的音 = 一个和弦。

    `limit` = 曲末（拍）：人时化抖动会把末小节的音推过曲末（混音时那些尾巴被
    折回循环开头），谱上按惯例**裁到曲末**——记谱不该出现伸到曲外的音。
    """
    grouped = {}
    for n in stem.notes:
        start = round(round(n.start / QUANT) * QUANT, 4)
        dur = max(MIN_DUR, round(round(n.dur / QUANT) * QUANT, 4))
        if limit is not None:
            if start >= limit - EPS:
                continue
            dur = min(dur, limit - start)
        grouped.setdefault((start, dur), []).append((int(n.pitch), int(n.vel)))
    evs = []
    for (start, dur), pairs in grouped.items():
        pairs.sort()
        evs.append({"start": start, "dur": dur,
                    "pitches": [p for p, _ in pairs],
                    "vel": max(v for _, v in pairs), "voice": 0})
    evs.sort(key=lambda e: (e["start"], -max(e["pitches"])))
    return evs


def _assign_voices(evs: list) -> int:
    """贪心分声部：同一声部内不重叠（谱上的硬规则）。返回声部数。"""
    ends = []
    for e in evs:
        for vi, end in enumerate(ends):
            if end <= e["start"] + EPS:
                e["voice"] = vi + 1
                ends[vi] = e["start"] + e["dur"]
                break
        else:
            e["voice"] = len(ends) + 1
            ends.append(e["start"] + e["dur"])
    return max(len(ends), 1)


def export_musicxml(cue, path: str, part_filter=None) -> dict:
    """把一首 cue 写成一个 MusicXML 文件（一个层 = 一个声部）。

    返回统计信息（层数 / 小节数 / 音符数 / 最多记谱声部数），供导出脚本汇总。
    """
    bar_beats = float(cue.beats_per_bar)
    fifths = _fifths(cue.key, cue.scale)
    stems = [s for s in cue.stems.values()
             if not part_filter or s.name in part_filter]

    lines = ['<?xml version="1.0" encoding="UTF-8"?>',
             '<!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 3.1 '
             'Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">',
             '<score-partwise version="3.1">',
             "  <work><work-title>%s</work-title></work>" % escape(cue.title),
             "  <identification>",
             "    <encoding><software>stick-world tools/music/export_scores.py"
             "</software></encoding>",
             "  </identification>",
             "  <part-list>"]
    for i, stem in enumerate(stems, 1):
        lines.append('    <score-part id="P%d">' % i)
        lines.append("      <part-name>%s</part-name>"
                     % escape(PART_NAMES.get(stem.name, stem.name)))
        lines.append("    </score-part>")
    lines.append("  </part-list>")

    note_count = 0
    voice_max = 1
    for i, stem in enumerate(stems, 1):
        grand = stem.name == "piano"          # 钢琴写大谱表
        evs = _events(stem, cue.bars * bar_beats)
        n_voices = _assign_voices(evs)
        voice_max = max(voice_max, n_voices)
        pitches = [p for e in evs for p in e["pitches"]] or [60]
        med = sorted(pitches)[len(pitches) // 2]
        clef = "G" if med >= 60 else "F"
        by_voice = {}
        for e in evs:
            by_voice.setdefault(e["voice"], []).append(e)
        lines.append('  <part id="P%d">' % i)
        for bar in range(cue.bars):
            lo, hi = bar * bar_beats, (bar + 1) * bar_beats
            lines.append('    <measure number="%d">' % (bar + 1))
            if bar == 0:
                lines.append("      <attributes>")
                lines.append("        <divisions>%d</divisions>" % DIVISIONS)
                lines.append("        <key><fifths>%d</fifths></key>" % fifths)
                lines.append("        <time><beats>%d</beats><beat-type>4"
                             "</beat-type></time>" % int(bar_beats))
                if grand:
                    lines.append("        <staves>2</staves>")
                    lines.append('        <clef number="1"><sign>G</sign>'
                                 "<line>2</line></clef>")
                    lines.append('        <clef number="2"><sign>F</sign>'
                                 "<line>4</line></clef>")
                else:
                    lines.append("        <clef><sign>%s</sign><line>%d</line>"
                                 "</clef>" % (clef, 2 if clef == "G" else 4))
                lines.append("      </attributes>")
                if i == 1:
                    lines.append('      <direction placement="above">')
                    lines.append("        <direction-type><metronome>")
                    lines.append("          <beat-unit>quarter</beat-unit>")
                    lines.append("          <per-minute>%g</per-minute>"
                                 % cue.bpm)
                    lines.append("        </metronome></direction-type>")
                    lines.append('        <sound tempo="%g"/>' % cue.bpm)
                    lines.append("      </direction>")
                if getattr(cue, "loop", True):
                    lines.append('      <barline location="left">')
                    lines.append("        <bar-style>heavy-light</bar-style>")
                    lines.append('        <repeat direction="forward"/>')
                    lines.append("      </barline>")
            for voice in range(1, n_voices + 1):
                pos = 0.0
                for e in by_voice.get(voice, []):
                    if e["start"] + e["dur"] <= lo + EPS or e["start"] >= hi:
                        continue
                    head = max(e["start"], lo)
                    tail = min(e["start"] + e["dur"], hi)
                    off = head - lo
                    if off > pos + EPS:
                        for (d, name, dot) in _decompose(pos, off - pos,
                                                         bar_beats):
                            lines += _rest_xml(d, name, dot, voice)
                            pos += d
                    tie_in = e["start"] < lo - EPS
                    tie_out = e["start"] + e["dur"] > hi + EPS
                    staff = (2 if max(e["pitches"]) < 60 else 1) if grand else 0
                    pieces = _decompose(off, tail - head, bar_beats)
                    acc = off
                    for k, (d, name, dot) in enumerate(pieces):
                        lines += _notes_xml(
                            e["pitches"], d, name, dot, fifths, voice, staff,
                            tie_start=(k < len(pieces) - 1) or tie_out,
                            tie_stop=tie_in or k > 0,
                            vel=e["vel"] if k == 0 and not tie_in else None)
                        acc += d
                        note_count += len(e["pitches"])
                    pos = acc
                if pos < bar_beats - EPS:      # 补满小节：记谱规范要求
                    for (d, name, dot) in _decompose(pos, bar_beats - pos,
                                                     bar_beats):
                        lines += _rest_xml(d, name, dot, voice)
                        pos += d
            if bar == cue.bars - 1 and getattr(cue, "loop", True):
                lines.append('      <barline location="right">')
                lines.append('        <repeat direction="backward"/>')
                lines.append("      </barline>")
            lines.append("    </measure>")
        lines.append("  </part>")
    lines.append("</score-partwise>")
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")
    return {"cue_id": cue.cue_id, "title": cue.title, "parts": len(stems),
            "bars": cue.bars, "notes": note_count, "voices": voice_max,
            "key": "%s %s" % (cue.key, cue.scale), "bpm": cue.bpm}


def verify_musicxml(path: str, cue) -> list:
    """导出后自检：小节数、**每个声部**每小节的时值总和、连音线配平。

    谱是给人看的交付件，错了不会像音频那样"跑一遍就听得出来"——所以在这里用代码
    把它量一遍（和写谱自检同一个道理）。
    """
    problems = []
    root = ET.parse(path).getroot()
    bar_beats = float(cue.beats_per_bar)
    want = bar_beats * DIVISIONS
    for part in root.findall("part"):
        measures = part.findall("measure")
        if len(measures) != cue.bars:
            problems.append("%s: 小节数 %d ≠ %d"
                            % (part.get("id"), len(measures), cue.bars))
        open_ties = set()
        for mi, meas in enumerate(measures, 1):
            per_voice = {}
            for note in meas.findall("note"):
                dur = int(note.findtext("duration", "0"))
                voice = int(note.findtext("voice", "1"))
                if note.find("chord") is None:      # 和弦的其余成员不重复计时值
                    per_voice[voice] = per_voice.get(voice, 0) + dur
                step = note.findtext("pitch/step")
                key = "%s%s" % (step or "rest",
                                note.findtext("pitch/octave") or "0")
                slot = (voice, key)
                if note.find("tie[@type='stop']") is not None:
                    if slot not in open_ties:
                        problems.append("小节 %d 声部 %d：%s 的连音线没有起点"
                                        % (mi, voice, key))
                    else:
                        open_ties.discard(slot)
                if note.find("tie[@type='start']") is not None:
                    open_ties.add(slot)
            for voice, total in per_voice.items():
                if total != want:
                    problems.append("小节 %d 声部 %d：时值总和 %.2f 拍 ≠ %.2f 拍"
                                    % (mi, voice, total / DIVISIONS,
                                       bar_beats))
        if open_ties:
            problems.append("有 %d 条连音线没有收尾" % len(open_ties))
    return problems


def pitch_histogram(cue, path: str) -> tuple:
    """代码里的音高直方图 vs 谱里的音高直方图。

    谱的价值全在"与代码逐音对应"，所以这一条是硬检查：两边的音高计数必须相等
    （时值可以因记谱量化而不同，音高一个都不能多、不能少）。
    """
    code = {}
    for stem in cue.stems.values():
        limit = cue.bars * float(cue.beats_per_bar)
        for n in stem.notes:
            if round(round(n.start / QUANT) * QUANT, 4) >= limit - EPS:
                continue
            code[int(n.pitch)] = code.get(int(n.pitch), 0) + 1
    root = ET.parse(path).getroot()
    score = {}
    for note in root.iter("note"):
        if note.find("rest") is not None:
            continue
        if note.find("tie[@type='stop']") is not None:
            continue          # 连音线的续写片不是新音，只算起音
        step = note.findtext("pitch/step")
        octave = int(note.findtext("pitch/octave", "4"))
        alter = int(note.findtext("pitch/alter", "0"))
        base = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}[step]
        pitch = (octave + 1) * 12 + base + alter
        score[pitch] = score.get(pitch, 0) + 1
    return code, score
