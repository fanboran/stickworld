# -*- coding: utf-8 -*-
"""从 `sfxlib/design.py` 的配方表导出**文档用表格**（Markdown / TSV）。

    <PY> tools/sfx/export_design.py            # Markdown，写到 stdout
    <PY> tools/sfx/export_design.py --fmt tsv  # 制表符分隔（贴进表格工具）

为什么要有这个脚本：`docs/技术/音频/音效设计规范.md` 里的逐件表格若手工维护，
一改配方就会与 `design.py` 脱节（"文档说的"和"交付的"是两个东西）。表格一律
从**同一张配方表**导出，文档才可能永远为真。
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from sfxlib import design as D                         # noqa: E402

COLUMNS = ("事件键", "文件", "用途（这是什么声音）", "时长窗口ms", "L_evt目标",
           "真峰值上限", "频段重心Hz", "变体数", "允许重叠", "接线归属")


def rows() -> list:
    # 变体数 = 同事件的配方条目数（design.py 里每个变体是一条 Recipe，
    # 不是一条 Recipe 里的多文件），所以从 groups() 数，不能数 r.files。
    nvar = {ev: len(items) for ev, items in D.groups().items()}
    out = []
    for r in D.RECIPES:
        for i, f in enumerate(r.files):
            out.append([
                r.event if i == 0 else "",
                f,
                r.what if i == 0 else "",
                "%.0f~%.0f" % (r.dur_ms[0], r.dur_ms[1]) if i == 0 else "",
                "%.1f" % D.target_lufs(f) if i == 0 else "",
                "%.1f" % r.tp if i == 0 else "",
                "%.0f" % r.band_center if i == 0 else "",
                str(nvar[r.event]) if i == 0 else "",
                r.overlap if i == 0 else "",
                r.node if i == 0 else "",
            ])
    return out


def markdown() -> str:
    lines = ["| " + " | ".join(COLUMNS) + " |",
             "| " + " | ".join("---" for _ in COLUMNS) + " |"]
    for row in rows():
        lines.append("| " + " | ".join(c.replace("|", "\\|") for c in row) + " |")
    lines.append("")
    lines.append("共 %d 件 / %d 个事件。" % (len(D.all_files()), len(D.groups())))
    return "\n".join(lines)


def tsv() -> str:
    return "\n".join("\t".join(COLUMNS)) + "\n" + \
        "\n".join("\t".join(r) for r in rows())


REGISTER_COLUMNS = ("文件（交付件）", "事件键", "响度层", "配方函数（design.py）",
                    "合成成分", "来源", "许可")


def register() -> str:
    """资产登记表：逐件给出"它由哪个配方函数、用哪些原语合成、来源与许可"。"""
    lines = ["| " + " | ".join(REGISTER_COLUMNS) + " |",
             "| " + " | ".join("---" for _ in REGISTER_COLUMNS) + " |"]
    for r in D.RECIPES:
        for f in r.files:
            cells = [f, r.event, r.category, "`%s`" % r.build.__name__,
                     "；".join(r.components),
                     "程序化合成（`tools/sfx/sfxlib/synth.py` 原语）",
                     "本项目自研，无第三方音频样本/无许可义务"]
            lines.append("| " + " | ".join(c.replace("|", "\\|") for c in cells) + " |")
    return "\n".join(lines)


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)
    except Exception:  # noqa: BLE001
        pass
    ap = argparse.ArgumentParser(description="导出音效配方表")
    ap.add_argument("--fmt", default="md", choices=["md", "tsv", "register"])
    args = ap.parse_args()
    if args.fmt == "md":
        print(markdown())
    elif args.fmt == "tsv":
        print(tsv())
    else:
        print(register())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
