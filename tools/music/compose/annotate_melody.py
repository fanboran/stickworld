# -*- coding: utf-8 -*-
"""谱面注释同步 —— 按旋律声明的和声骨架，重写每条音尾注里的"和弦功能"。

为什么需要它：谱面里的注释写着"这个音是 III 的五音"这类**结论**，一旦和声骨架
被换掉（比如从卡农换成小室进行），这些结论就变成了谎话——而谎话的注释比没有注释
更坏：下一个改谱的人会照着错的注释判断。所以和声一改，就跑一遍本工具。

只改**括号里的和弦功能**（`# A5（V 根音）`），括号之后的描述原样保留
（`← 高点`、`长音`、`句尾停五音` 这些是人写的音乐意图，工具不该动）。

    python tools/music/compose/annotate_melody.py            # 只打印将要改的行
    python tools/music/compose/annotate_melody.py --write    # 原地改写 themes.py
    python tools/music/compose/annotate_melody.py --id night --write
"""
from __future__ import annotations

import argparse
import io
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from compose import themes as TH                         # noqa: E402
from musiclib import theory as T                         # noqa: E402

# 事件行 + 注释：只有带"（…）"的注释会被改写
LINE_RE = re.compile(
    r'^(\s*\(\d+,\s*[\d.]+,\s*[\d.]+,\s*(?:None|\d+),\s*\d+,\s*\d+\),\s*#\s*)'
    r'([A-G][#b]?\d)（([^）]*)）(.*)$')
EVENT_RE = re.compile(r'\(\s*(\d+),\s*([\d.]+),\s*([\d.]+),\s*(None|\d+),\s*(\d+),\s*(\d+)\s*\)')

# 相对根音的半音数 → 和弦音角色
_CHORD_ROLE = {0: "根音", 3: "三音", 4: "三音", 7: "五音", 10: "七音", 11: "七音"}
# 相对根音的半音数 → 外音名（非和弦音，但仍在调内）
_TENSION = {1: "♭9", 2: "9", 3: "♭3", 4: "3", 5: "11", 6: "♯11",
            8: "♭13", 9: "13", 10: "♭7", 11: "7"}


def label(pitch: int, roman: str, key: str, scale: str) -> str:
    """给一个音配上"在和弦里是什么"的短语，如 'V 根音' / 'ii 上 9'。"""
    ch = T.roman_chord(key, scale, roman)
    root = T.name_to_midi(ch.root + "0") % 12
    off = (pitch - root) % 12
    pcs = set(ch.pitch_classes())
    if (pitch % 12) in pcs:
        role = _CHORD_ROLE.get(off)
        if role is None:                      # 六音/九音类和弦（69/maj9/min9）里的彩色音
            role = _TENSION.get(off, "和弦音")
        return "%s %s" % (roman, role)
    return "%s 上 %s" % (roman, _TENSION.get(off, "外音 %d" % off))


def rewrite(text: str, only: set, write: bool) -> tuple:
    out, changes = [], 0
    for line in text.split("\n"):
        m = LINE_RE.match(line)
        if not m:
            out.append(line)
            continue
        prefix, _name, old_label, tail = m.groups()
        # 找回这条音属于哪条旋律/乐句：靠缩进与"最近的 Melody(id=…)"上下文判断
        melody = _current_id(out)
        if not melody or (only and melody not in only):
            out.append(line)
            continue
        ev = EVENT_RE.search(line)
        bar, beat, dur, deg, octs, vel = ev.groups()
        if deg == "None":
            out.append(line)
            continue
        mel = TH.MELODIES[melody]
        roman = mel.harmony[int(bar) % len(mel.harmony)]
        pitch = T.degree(mel.key, mel.scale, int(deg), int(octs))
        new_label = label(pitch, roman, mel.key, mel.scale)
        if new_label == old_label:
            out.append(line)
            continue
        changes += 1
        newline = "%s%s（%s）%s" % (prefix, _name, new_label, tail)
        if not write:
            print("  %-46s →  %s" % (line.strip()[:46], newline.strip()[:60]))
        out.append(newline)
    return "\n".join(out), changes


def _current_id(lines) -> str | None:
    """从已写出的行里找最近一个 `XXX = Melody(` 的旋律 id。

    变量名（`MENU`）与旋律 id（`menu`）不一定同名，所以按变量取出对象再问它的 id。
    """
    for line in reversed(lines[-400:]):
        m = re.match(r'^([A-Z_][A-Z0-9_]*) = Melody\(', line)
        if m:
            obj = getattr(TH, m.group(1), None)
            return getattr(obj, "id", None)
    return None


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser(description="按和声骨架同步谱面注释")
    ap.add_argument("--id", action="append", default=None,
                    help="只处理某条旋律（可重复）")
    ap.add_argument("--write", action="store_true", help="原地改写（默认只预览）")
    args = ap.parse_args()
    path = Path(__file__).resolve().parent / "themes.py"
    text = io.open(path, encoding="utf-8").read()
    only = set(args.id or [])
    new, n = rewrite(text, only, args.write)
    if write_ok := args.write:
        io.open(path, "w", encoding="utf-8", newline="").write(new)
    print("%s %d 行注释" % ("已改写" if write_ok else "将改写", n))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
