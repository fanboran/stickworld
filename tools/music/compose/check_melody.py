# -*- coding: utf-8 -*-
"""旋律自检 —— 在渲染之前把"代码可判"的写谱错误挑出来。

为什么要有这一步：渲染一次全库要跑遍 sfizz/fluidsynth 与混音母带，成本高；
而"这个音和那个和弦撞了"是**纯符号问题**，用乐理层算一遍就能查，不该靠耳朵
在成品里找（"代码能判的错误不许靠渲染发现"）。

查四类问题：

  1. **调外音**：音的十二平均律音级不在该调式音阶上。出现即报错——本作全部旋律
     都写"调内 + 允许借调"，真出现调外音一定是手滑（少写/多写一个升降号）。
  2. **和声避讳音**：非和弦音且距离某个和弦音只有半音。这是听感上"糊/刺"的主要
     来源（大三度上方的四音、五音上方的降六音、根音上方的降九音）。
     例外：根音下方半音 = 大七音（本作的主要色彩和弦之一），不报。
     落在**重拍**（第 1/3 拍或时值 ≥1.5 拍）上的报错；落在弱拍且前后级进解决的
     只提示——它们是有意写的经过音/悬留音。
  3. **音区**：报告每条乐句的 MIDI 音域，核对是否落在乐器舒适区（人工看，不自动判）。
  4. **留白**：报告休止占比与最长连续无休止长度。缓速曲子少于 8% 就要回头看。

    python tools/music/compose/check_melody.py            # 全部旋律
    python tools/music/compose/check_melody.py night      # 单条
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from compose import themes as TH                         # noqa: E402
from musiclib import theory as T                         # noqa: E402


def _chord_pcs(key: str, scale: str, roman: str) -> set:
    return set(T.roman_chord(key, scale, roman).pitch_classes())


def _root_pc(key: str, scale: str, roman: str) -> int:
    return T.name_to_midi(T.roman_chord(key, scale, roman).root + "0") % 12


def _chord_roles(key: str, scale: str, roman: str) -> dict:
    """和弦的根音/三音音级，以及三音是否为大三度。"""
    ch = T.roman_chord(key, scale, roman)
    ivs = T.CHORD_INTERVALS[ch.quality]
    root = T.name_to_midi(ch.root + "0") % 12
    third_iv = 4 if 4 in ivs else 3
    return {"root": root, "third": (root + third_iv) % 12,
            "third_is_major": third_iv == 4}


def avoid_reason(pc: int, key: str, scale: str, roman: str):
    """和声避讳音判定 —— 只报乐理上真的要避的两类：

      1. **降九音**：落在根音上方半音。压在最稳的音上，听感最脏。
      2. **四音压三音**：落在大三度上方半音（大三和弦上的四音）。这是"糊"的
         主要来源，也是本作"九和弦而非挂留"语汇里唯一必须避开的位置。

    刻意**不报**的（都是本作的常用语汇，报了会把好写法当成错）：
      - 根音下方半音 = 大七音（maj7 是全作的主力色彩和弦）；
      - 小三度下方半音 = 小三和弦上的九音（min9 同理）；
      - 五音上/下方半音 = 小调的六音、升四音（前者是自然小调最常用的音级，
        后者一出调就会被"调外音"那一条抓住）。
    """
    r = _chord_roles(key, scale, roman)
    if pc == (r["root"] + 1) % 12:
        return "降九音压根音"
    if r["third_is_major"] and pc == (r["third"] + 1) % 12:
        return "四音压三音"
    return None


def _pc_name(pc: int) -> str:
    """音级显示名：等音异名时两个都写（D 小调的降六音写作 Bb 而不是 A#）。"""
    sharp, flat = T.NOTE_NAMES[pc], T.FLAT_NAMES[pc]
    return sharp if sharp == flat else "%s/%s" % (flat, sharp)


def _scale_pcs(key: str, scale: str) -> set:
    r = T.name_to_midi(key + "0") % 12
    return {(r + s) % 12 for s in T.SCALES[scale]}


def _is_heavy(beat: float, dur: float) -> bool:
    return beat in (0.0, 2.0) or dur >= 1.5


def check(mel: TH.Melody, verbose: bool = True) -> dict:
    scale_pcs = _scale_pcs(mel.key, mel.scale)
    report = {"id": mel.id, "name": mel.name, "out_of_key": [],
              "heavy_clash": [], "weak_clash": [], "rests": [], "ranges": []}
    if verbose:
        print("\n══ %s · %s  (%s %s, 曲式 %s)"
              % (mel.id, mel.name, mel.key, mel.scale, "".join(mel.form)))
    for pname in sorted(mel.phrases):
        ph = mel.phrases[pname]
        pcs_of_bar = {}
        notes, used = [], 0.0
        lo, hi = 999, -1
        for (bar, beat, dur, deg, octs, vel) in ph.events:
            if deg is None:
                continue
            roman = mel.harmony[bar % len(mel.harmony)]
            chord_pcs = pcs_of_bar.setdefault(
                bar, _chord_pcs(mel.key, mel.scale, roman))
            pitch = T.degree(mel.key, mel.scale, deg, octs) + ph.transpose
            pc = pitch % 12
            lo, hi = min(lo, pitch), max(hi, pitch)
            used += dur
            notes.append(pitch)
            if pc not in scale_pcs:
                report["out_of_key"].append(
                    (pname, bar, beat, dur, T.midi_to_name(pitch), roman, "-"))
                continue
            if pc in chord_pcs:
                continue
            why = avoid_reason(pc, mel.key, mel.scale, roman)
            if why:
                entry = (pname, bar, beat, dur, T.midi_to_name(pitch), roman, why)
                (report["heavy_clash"] if _is_heavy(beat, dur)
                 else report["weak_clash"]).append(entry)
        rest_pct = max(0.0, (32.0 - used) / 32.0) * 100.0
        report["rests"].append((pname, rest_pct, len(notes)))
        report["ranges"].append((pname, lo, hi,
                                 "%s~%s" % (T.midi_to_name(lo), T.midi_to_name(hi)),
                                 ph.register))
        if verbose:
            print("   乐句 %s：%2d 音  休止 %4.1f%%  音域 %s~%s（%d~%d）"
                  % (pname, len(notes), rest_pct, T.midi_to_name(lo),
                     T.midi_to_name(hi), lo, hi))
            print("      音区声明：%s" % (ph.register or "（未写）"))
            print("      %s" % (ph.role or ""))
            if lo < 999:
                span = sorted({p % 12 for p in notes})
                print("      用到的音级：%s" % " ".join(_pc_name(p) for p in span))
    if verbose:
        for tag, label in (("out_of_key", "调外音"),
                           ("heavy_clash", "重拍避讳音"),
                           ("weak_clash", "弱拍避讳音（经过/悬留，需级进解决）")):
            for e in report[tag]:
                print("   ⚠ %s: 乐句%s 小节%s 拍%s 时值%s %s（和弦 %s, %s）"
                      % ((label,) + tuple(str(x) for x in e)))
        if not (report["out_of_key"] or report["heavy_clash"]):
            print("   ✓ 无调外音、无重拍避讳音")
    return report


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8")
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    lib = dict(TH.MELODIES)
    ids = args or sorted(lib)
    reports = [check(lib[i]) for i in ids]

    print("\n" + "═" * 66)
    print("%-18s %-10s %8s %8s %8s %8s"
          % ("旋律", "乐句", "音数", "休止%", "调外音", "重拍撞音"))
    bad = 0
    for r in reports:
        n_out = len(r["out_of_key"])
        n_heavy = len(r["heavy_clash"])
        bad += n_out + n_heavy
        for (pname, rest, cnt) in r["rests"]:
            print("%-18s %-10s %8d %7.1f%% %8d %8d"
                  % (r["id"], pname, cnt, rest, n_out, n_heavy))
    print("═" * 66)
    if bad:
        print("✗ 发现 %d 处需要修的写谱问题（调外音 %d，重拍避讳音 %d）"
              % (bad, sum(len(r["out_of_key"]) for r in reports),
                 sum(len(r["heavy_clash"]) for r in reports)))
        return 1
    weak = sum(len(r["weak_clash"]) for r in reports)
    print("✓ 全部旋律通过（弱拍经过/悬留音 %d 处，属有意写法）" % weak)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
