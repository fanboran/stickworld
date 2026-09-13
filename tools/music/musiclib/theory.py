# -*- coding: utf-8 -*-
"""乐理层 —— 音高 / 音阶 / 和弦 / 级数 / 声部连接 / 音型。

这一层只做"符号运算"：不碰音频，不碰 MIDI 文件。所有作曲脚本用它的词汇
写谱面，`score.py` 把结果组织成可渲染的 Part，`midi_writer.py` 落盘。

设计取向（决定"日系静谧"听感的语法，见 docs/设计/音乐/音乐设计文档.md）：
  - 和弦以**七和弦及以上**为默认单位，三和弦是特例；九和弦/六九和弦常用。
  - 级数以罗马数字表达，支持借调（bVII / bVI / #IV）与副属（V/x）。
  - 声部连接按"最小移动"求解，保证内声部平滑（听感"高级"的主要来源之一）。
"""
from __future__ import annotations

from dataclasses import dataclass

NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
FLAT_NAMES = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
FLAT_TO_SHARP = {
    "Db": "C#", "Eb": "D#", "Gb": "F#", "Ab": "G#", "Bb": "A#",
    "Cb": "B", "Fb": "E",
}
_TRIADS = {"maj": (0, 4, 7), "min": (0, 3, 7), "dim": (0, 3, 6), "aug": (0, 4, 8)}
# 大小写与和弦性质的"家族"归属：dim/半减归入小写一侧
_LOWER_FAMILY = {"min", "dim", "min7", "min7b5", "dim7", "minMaj7", "min6",
                 "min9", "madd9"}


# ─────────────────────────────── 音高 ────────────────────────────────

def midi_to_name(pitch: int, with_octave: bool = True) -> str:
    name = NOTE_NAMES[pitch % 12]
    if not with_octave:
        return name
    return "%s%d" % (name, pitch // 12 - 1)


def name_to_midi(name: str) -> int:
    """'C4' -> 60，'F#3' -> 54，'Bb2' -> 46。中央 C = C4 = 60。"""
    name = name.strip()
    letter = name[0].upper()
    rest = name[1:]
    acc = 0
    while rest and rest[0] in "#b":
        acc += 1 if rest[0] == "#" else -1
        rest = rest[1:]
    octave = int(rest)
    base = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}[letter]
    return (octave + 1) * 12 + base + acc


def pitch_class(pitch) -> int:
    return pitch % 12


SCALES = {
    "major":          [0, 2, 4, 5, 7, 9, 11],
    "minor":          [0, 2, 3, 5, 7, 8, 10],   # 自然小调 / 伊奥利亚
    "harmonic_minor": [0, 2, 3, 5, 7, 8, 11],
    "melodic_minor":  [0, 2, 3, 5, 7, 9, 11],
    "dorian":         [0, 2, 3, 5, 7, 9, 10],
    "phrygian":       [0, 1, 3, 5, 7, 8, 10],
    "lydian":         [0, 2, 4, 6, 7, 9, 11],
    "mixolydian":     [0, 2, 4, 5, 7, 9, 10],
    "locrian":        [0, 1, 3, 5, 6, 8, 10],
    "pentatonic_major": [0, 2, 4, 7, 9],
    "pentatonic_minor": [0, 3, 5, 7, 10],
    # 日系色彩音阶：都节 / 琉球 / 平调子 —— 用于风景、怀旧段落点缀
    "miyako_bushi":   [0, 1, 5, 7, 8],
    "ryukyu":         [0, 4, 5, 7, 11],
    "hirajoshi":      [0, 2, 3, 7, 8],
}


def scale_pitches(root: str, scale: str = "major",
                  lo: int = 36, hi: int = 96) -> list:
    """返回 [lo, hi] 区间内落在该音阶上的全部 MIDI 音高（升序）。"""
    r = name_to_midi(root + "0") % 12
    steps = SCALES[scale]
    out = []
    for p in range(lo, hi + 1):
        if (p - r) % 12 in steps:
            out.append(p)
    return out


def degree(key_root: str, scale: str, degree: int, octave: int = 0) -> int:
    """级数 → MIDI。degree 为 1-based 音阶级数，可越界（自动跨八度）。

    octave=0 指"中央 C 所在的那一组"，故 degree=1, octave=0 对 D 大调给出 D4=62。
    """
    r = name_to_midi(key_root + "0") % 12
    steps = SCALES[scale]
    n = len(steps)
    d = degree - 1
    oct_shift, idx = divmod(d, n)
    return 12 * (octave + 5 + oct_shift) + r + steps[idx]


# ─────────────────────────────── 和弦 ────────────────────────────────

CHORD_INTERVALS = {
    "5":        (0, 7),
    "maj":      (0, 4, 7),
    "min":      (0, 3, 7),
    "dim":      (0, 3, 6),
    "aug":      (0, 4, 8),
    "sus2":     (0, 2, 7),
    "sus4":     (0, 5, 7),
    "6":        (0, 4, 7, 9),
    "min6":     (0, 3, 7, 9),
    "69":       (0, 4, 7, 9, 14),
    "maj7":     (0, 4, 7, 11),
    "maj7sus4": (0, 5, 7, 11),
    "min7":     (0, 3, 7, 10),
    "min7b5":   (0, 3, 6, 10),
    "dim7":     (0, 3, 6, 9),
    "minMaj7":  (0, 3, 7, 11),
    "7":        (0, 4, 7, 10),
    "7sus4":    (0, 5, 7, 10),
    "7b5":      (0, 4, 6, 10),
    "add9":     (0, 4, 7, 14),
    "madd9":    (0, 3, 7, 14),
    "add11":    (0, 4, 7, 17),
    "maj9":     (0, 4, 7, 11, 14),
    "min9":     (0, 3, 7, 10, 14),
    "9":        (0, 4, 7, 10, 14),
    "maj9sus4": (0, 5, 7, 11, 14),
    "7b9":      (0, 4, 7, 10, 13),
    "7#11":     (0, 4, 7, 10, 18),
    "13":       (0, 4, 7, 10, 21),
}

# 和弦符号后缀 → 内部音程表键（长的写前面，解析时按长度优先匹配）
_SUFFIX_ALIASES = [
    ("maj7sus4", "maj7sus4"), ("maj9sus4", "maj9sus4"),
    ("minmaj7", "minMaj7"), ("mmaj7", "minMaj7"),
    ("min7b5", "min7b5"), ("m7b5", "min7b5"), ("ø", "min7b5"),
    ("maj7", "maj7"), ("M7", "maj7"), ("Δ7", "maj7"), ("Δ", "maj7"),
    ("maj9", "maj9"), ("M9", "maj9"), ("Δ9", "maj9"),
    ("add9", "add9"), ("add11", "add11"),
    ("min9", "min9"), ("m9", "min9"),
    ("min7", "min7"), ("m7", "min7"),
    ("min6", "min6"), ("m6", "min6"),
    ("min", "min"), ("m", "min"),
    ("69", "69"), ("6/9", "69"),
    ("7sus4", "7sus4"), ("7b9", "7b9"), ("7#11", "7#11"),
    ("sus4", "sus4"), ("sus2", "sus2"), ("sus", "sus4"),
    ("dim7", "dim7"), ("dim", "dim"), ("o", "dim"),
    ("aug", "aug"), ("+", "aug"),
    ("13", "13"), ("9", "9"), ("7", "7"),
    ("5", "5"), ("6", "6"),
]


@dataclass
class Chord:
    """一个和弦：根音（音名）+ 音程表键 + 可选转位低音。"""
    root: str
    quality: str = "maj"
    bass: str | None = None   # 斜杠和弦的低音，如 "A/C#" -> bass="C#"

    @property
    def intervals(self) -> tuple:
        return CHORD_INTERVALS[self.quality]

    def pitch_classes(self) -> list:
        r = name_to_midi(self.root + "0") % 12
        return sorted({(r + i) % 12 for i in self.intervals})

    def pitches(self, octave: int = 4, include_extension_octave: bool = True) -> list:
        """默认八度上的原位排列（用于快速试听/无前序声部时的初始解）。"""
        base = 12 * (octave + 1) + (name_to_midi(self.root + "0") % 12)
        out = []
        for i in self.intervals:
            p = base + i
            if not include_extension_octave and p > base + 12:
                continue
            out.append(p)
        return out

    def __str__(self) -> str:
        s = self.root + ("" if self.quality == "maj" else self.quality)
        if self.bass and (name_to_midi(self.bass + "0") % 12) != (name_to_midi(self.root + "0") % 12):
            s += "/" + self.bass
        return s


def parse_chord(sym: str) -> Chord:
    """解析和弦符号：'D'、'F#m7'、'Bm7b5'、'Gsus4'、'A/C#'、'Dmaj9'。"""
    sym = sym.strip()
    slash_bass = None
    if "/" in sym:
        head, tail = sym.split("/", 1)
        if tail.strip().upper() not in ("9",):   # 6/9 特殊处理
            slash_bass = tail.strip()
            sym = head.strip()
    root = sym[:2] if len(sym) > 1 and sym[1] in "#b" else sym[:1]
    rest = sym[len(root):]
    root = FLAT_TO_SHARP.get(root, root)
    quality = "maj"
    if rest:
        for alias, key in _SUFFIX_ALIASES:
            if rest.startswith(alias):
                quality = key
                break
        else:
            raise ValueError("无法解析和弦后缀: %r (和弦 %r)" % (rest, sym))
    if slash_bass:
        slash_bass = FLAT_TO_SHARP.get(slash_bass, slash_bass)
    return Chord(root, quality, slash_bass)


# ─────────────────────────────── 级数 ────────────────────────────────

_ROMAN_BASE = {"i": 0, "ii": 1, "iii": 2, "iv": 3, "v": 4, "vi": 5, "vii": 6}


def _roman_to_numeral(roman: str) -> tuple:
    """罗马数字 → (半音级偏移索引, 匹配到的数字词, 变音记号)。

    返回 (index, numeral, accidental)；index 是"在该调式音阶里取第几个音级"。
    """
    acc = 0
    while roman and roman[0] in "b#":
        acc += 1 if roman[0] == "#" else -1
        roman = roman[1:]
    if not roman:
        raise ValueError("空罗马数字")
    core = roman.lower()
    key = None
    for cand in sorted(_ROMAN_BASE, key=len, reverse=True):
        if core.startswith(cand):
            key = cand
            break
    if key is None:
        raise ValueError("无法解析罗马数字: %r" % roman)
    return _ROMAN_BASE[key], key, acc


def _roman_to_root_offset(roman: str, scale: str) -> int:
    """罗马数字 → 相对主音的半音偏移。支持 b/# 前缀（借调）。"""
    idx, _numeral, acc = _roman_to_numeral(roman)
    return SCALES[scale][idx] + acc


def _diatonic_triad(scale: str, step_index: int) -> str:
    """音阶上第 step_index 级（0-based）**调内自然三和弦**的性质。

    这是判定大小写的依据：大调 vii 自然是减三和弦、自然小调 VII 自然是大三和弦。
    靠"取音阶上的音"反推，而不是靠"vii 就一定是减"这种会在大调/小调上翻车的硬规则。

    三和弦 = 音阶上**每隔一级取一个音**（三度叠置），即 i / i+2 / i+4 级；
    注意 i+2、i+4 会越过音阶末尾绕回，必须补八度，否则会取到错误的音
    （例如 B 小调的 VII 会算成 A-C-E 小三，实际应为 A-C#-E 大三）。
    """
    steps = SCALES[scale]
    n = len(steps)

    def rel(k: int) -> int:
        """音阶第 k 级（0-based，可越界）相对主音的半音数。"""
        return steps[k % n] + 12 * (k // n)

    p1, p2, p3 = rel(step_index), rel(step_index + 2), rel(step_index + 4)
    ivs = (0, p2 - p1, p3 - p1)
    for name, pat in _TRIADS.items():
        if ivs == pat:
            return name
    return "maj"


def roman_chord(key_root: str, scale: str, roman: str) -> Chord:
    """级数 → 和弦对象。例：("D","major","IV") -> G；("D","major","iii") -> F#m。

    无后缀时按**调内自然和弦**定性质（大调 vii=减三、自然小调 VII=大三、
    小调的 v=小三），大小写与调内性质冲突时才用大小写强制指定
    （小调写大写 V 即取和声小调的属和弦、大调写小写 iv 取下属小三）。
    带后缀时后缀说了算：'V7' 属七、'IVmaj7' 大七、'viiø7' 半减、'viio7' 减七。
    降号前缀（bVII/bVI/bIII）优先于大小写推断 —— bVII 是大三和弦，不是减。
    """
    body = roman.strip()
    acc = 0
    while acc < len(body) and body[acc] in "b#":
        acc += 1
    j = acc
    while j < len(body) and body[j] in "ivxIVX":
        j += 1
    core, suff = body[:j], body[j:]
    idx, _numeral, accidental = _roman_to_numeral(core)
    is_upper = core.lstrip("b#")[:1].isupper()

    off = SCALES[scale][idx] + accidental
    root_pc = (name_to_midi(key_root + "0") % 12 + off) % 12
    # 降号音级用降号拼写（bVI 在 D 大调是 Bb 而不是 A#），只为可读性
    root = (FLAT_NAMES if accidental < 0 else NOTE_NAMES)[root_pc]

    if suff:
        s = suff
        if s in ("7", "9", "13"):
            quality = {"7": "7", "9": "9", "13": "13"}[s] if is_upper else \
                      {"7": "min7", "9": "min9", "13": "min7"}[s]
        elif s in ("ø7", "ø"):
            quality = "min7b5"
        elif s in ("o7", "°7"):
            quality = "dim7"
        elif s in ("o", "°"):
            quality = "dim"
        elif s == "maj7":
            quality = "maj7"
        elif s == "maj9":
            quality = "maj9"
        elif s == "add9":
            quality = "add9"
        elif s == "sus4":
            quality = "sus4"
        elif s == "7sus4":
            quality = "7sus4"
        elif s == "6":
            quality = "6" if is_upper else "min6"
        else:
            quality = parse_chord(root + s).quality
    else:
        dia = _diatonic_triad(scale, idx)
        agrees = (dia not in _LOWER_FAMILY) == is_upper
        quality = dia if agrees else ("maj" if is_upper else "min")
    return Chord(root, quality)


def progression(key_root: str, scale: str, romans) -> list:
    """['I','V','vi','iii','IV','I','IV','V'] -> [Chord, ...]"""
    return [roman_chord(key_root, scale, r) for r in romans]


# ── 常用进行模板（日系静谧配乐的骨架，见音乐设计文档 §和声语汇） ──
# 名称 -> 罗马数字序列。均为公有领域的和声套路（和声进行本身不受版权保护）。
PROGRESSIONS = {
    # 帕赫贝尔卡农：最"经典又不腻"的骨架，久石让大量使用其变体
    "canon":      ["I", "V", "vi", "iii", "IV", "I", "IV", "V"],
    # 王道进行：日系流行/动画抒情曲的国民级套路
    "odo":        ["IV", "V", "iii", "vi"],
    "odo_long":   ["IV", "V", "iii", "vi", "ii", "V", "I", "I"],
    # 小室进行
    "komuro":     ["vi", "IV", "V", "I"],
    # 四度上行 + 终止：古典但不陈旧
    "circle":     ["vi", "ii", "V", "I"],
    # 三度下行链（久石让式"漂浮感"）
    "third_drop": ["I", "vi", "IV", "ii", "V", "I"],
    # 小调抒情：自然小调的 vi-IV-I-V 平移（在 minor 调式里解释为 i-VI-III-VII）
    "aeolian":    ["i", "VI", "III", "VII"],
    "aeolian_2":  ["i", "VII", "VI", "VII"],
    # 悬留与解决：静谧段落常用（sus4 挂住不急着解决）
    "sus_float":  ["Imaj9", "IVmaj7sus4", "vi7", "Vsus4"],
}


def progression_by_name(key_root: str, scale: str, name: str) -> list:
    return progression(key_root, scale, PROGRESSIONS[name])


# ─────────────────────── 声部连接 / 排列 ────────────────────────────────

def _chord_tone_pcs(chord: Chord) -> list:
    """和弦音的音级集合。九和弦保留九音、省略十一/十三（避免浑浊与撞音）。"""
    ivs = CHORD_INTERVALS[chord.quality]
    if chord.quality in ("add9", "maj9", "min9", "9", "69", "maj9sus4",
                         "7b9", "7#11", "13", "madd9", "add11"):
        ivs = ivs[:5]
    r = name_to_midi(chord.root + "0") % 12
    return sorted({(r + i) % 12 for i in ivs})


def _stack_from_bass(pcs: list, bass_pc: int, low: int, high: int,
                     n_notes: int) -> list | None:
    """从指定低音音级出发向上堆叠和弦音，得到 n_notes 个音的紧凑排列。"""
    starts = [p for p in range(low, low + 12) if p % 12 == bass_pc]
    if not starts:
        return None
    start = starts[0]
    order = sorted(pcs, key=lambda pc: ((pc - bass_pc) % 12))
    out = [start]
    for _ in range(n_notes - 1):
        pc = order[len(out) % len(order)]
        nxt = out[-1] + 1
        while nxt % 12 != pc:
            nxt += 1
        if nxt > high:
            return None
        out.append(nxt)
    return out


def _motion_cost(cand: list, prev: list) -> float:
    """两串声部之间的移动代价：逐声部绝对位移之和（长度不等时对齐比较）。"""
    if not prev or not cand:
        return 0.0
    a, b = sorted(cand), sorted(prev)
    k = min(len(a), len(b))
    # 从顶部对齐（旋律声部优先保持），再比较内声部
    cost = sum(abs(a[-1 - i] - b[-1 - i]) for i in range(k))
    cost += 6.0 * abs(len(a) - len(b))       # 声部数变化视为大跳
    return float(cost)


def nearest_voicing(chord: Chord, prev: list | None = None, low: int = 59,
                    high: int = 84, n_notes: int = 4,
                    must_include_top: int | None = None) -> list:
    """在 [low, high] 内为 chord 求一个**声部平滑**的排列（升序 MIDI 列表）。

    做法：枚举全部转位（低音落在每个和弦音上），每个转位堆一个紧凑排列，
    再用"相对前一排列的逐声部移动量"打分取最优。这是古典和声写作里
    "保持共同音、其余声部就近移动"的机械化表达，听感上表现为内声部平滑、
    不会出现整块和弦上下乱跳的业余感。

    must_include_top 用于把旋律音固定为最高声部（旋律下方的内声部仍按平滑求解）。
    """
    pcs = _chord_tone_pcs(chord)
    if must_include_top is not None:
        top = must_include_top
        top_pc = top % 12
        lower_pcs = [pc for pc in pcs if pc != top_pc] or pcs
        n_inner = max(1, n_notes - 1)
        best, best_cost = None, float("inf")
        for bass in lower_pcs:
            inner = _stack_from_bass(lower_pcs, bass, low, max(low, top - 1),
                                     n_inner)
            if inner is None:
                continue
            if inner[-1] >= top:
                continue
            cand = sorted(set(inner + [top]))
            cost = _motion_cost(cand[:-1], prev or [])
            if cost < best_cost:
                best, best_cost = cand, cost
        return best if best else sorted(set([top]))

    best, best_cost = None, float("inf")
    for bass in pcs:
        cand = _stack_from_bass(pcs, bass, low, high, n_notes)
        if cand is None:
            continue
        cost = _motion_cost(cand, prev or [])
        if prev is None:
            # 无前序时偏好"低音离中心近、整体位置适中"的排列
            cost += 0.5 * abs(cand[0] - (low + 7))
        if cost < best_cost:
            best, best_cost = cand, cost
    return best if best else chord.pitches(octave=4)


def voicings_for(key_root: str, scale: str, romans, low: int = 59,
                 high: int = 84, n_notes: int = 4) -> list:
    """给一串级数求出全串平滑的排列（按顺序逐块求解，后一块看前一块）。"""
    out, prev = [], None
    for r in romans:
        c = roman_chord(key_root, scale, r)
        v = nearest_voicing(c, prev, low=low, high=high, n_notes=n_notes)
        out.append((c, v))
        prev = v
    return out


def bass_note(chord: Chord, low: int = 36, high: int = 52) -> int:
    """低声部根音（或斜杠和弦的指定低音），落在 [low, high]。"""
    pc = name_to_midi((chord.bass or chord.root) + "0") % 12
    opts = [p for p in range(low, high + 1) if p % 12 == pc]
    return opts[0] if opts else low


# ─────────────────────────────── 音型 ────────────────────────────────

def arpeggio_8th(voicing: list, beats: float, direction: str = "up_down",
                 span: int = 8) -> list:
    """把排列展开成 8 分音符琶音。返回 [(beat_offset, pitch, degree_index), ...]。

    日系静谧钢琴最常见的织体：低音 + 上行的分解和弦，8 分音符匀速铺满，
    不抢旋律。direction: up / down / up_down / up_down_inner。
    """
    if not voicing:
        return []
    v = sorted(voicing)
    seq = []
    if direction == "up":
        for i in range(span):
            seq.append(v[i % len(v)] + 12 * (i // len(v)))
    elif direction == "down":
        for i in range(span):
            idx = len(v) - 1 - (i % len(v))
            seq.append(v[idx] - 12 * (i // len(v)))
    elif direction == "up_down":
        pat = v + v[-2:0:-1]
        for i in range(span):
            seq.append(pat[i % len(pat)])
    elif direction == "up_down_inner":
        pat = v + [v[0]]
        for i in range(span):
            seq.append(pat[i % len(pat)])
    else:
        raise ValueError(direction)
    step = beats / span
    return [(i * step, p, i) for i, p in enumerate(seq)]


def waltz_figure(voicing: list, beats: float = 3.0) -> list:
    """3/4 圆舞曲织体：低音落在第 1 拍，其余和弦音落在第 2、3 拍。"""
    v = sorted(voicing)
    if not v:
        return []
    out = [(0.0, v[0], 0)]
    upper = v[1:] or [v[0]]
    for k, b in enumerate((1.0, 2.0)):
        for p in upper:
            out.append((b, p, 1 + k))
    return out


def lilt_6_8(voicing: list, beats: float) -> list:
    """6/8 摇曳织体：低音 + 五度 + 和弦音，形成"摇篮"式摆动（村落的日常感）。"""
    v = sorted(voicing)
    if not v:
        return []
    pat = [v[0], v[min(1, len(v) - 1)], v[-1], v[min(1, len(v) - 1)]]
    span = max(6, int(beats * 2))
    step = beats / span
    return [(i * step, pat[i % len(pat)], i) for i in range(span)]
