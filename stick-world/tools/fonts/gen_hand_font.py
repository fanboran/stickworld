# -*- coding: utf-8 -*-
"""程序化手写字体生成器 —— 矢量字形扰动管线（自制 TTF）。

思路：以霞鹜文楷 Lite 为骨架输入，对每个字形的 Bézier 轮廓点做确定性随机扰动：
- on-curve 骨架点小幅高斯位移（字形微微歪扭 = "手写不齐"）
- off-curve 控制点位移略大（曲线弯度微活）
- 整字形微倾斜（随机正负，楷体骨架的手写斜势）
输出全新 TTF（StickHand），每个字都"定型地微微不一样"，矢量无损任意缩放。

确定性：固定全局 seed，重跑结果一致（程序化资产管线惯例）。
用法：python tools/fonts/gen_hand_font.py
产物：assets/fonts/StickHand-Regular.ttf + 对比预览 _preview_hand.png
"""

from __future__ import annotations

import math
import os
import random

from fontTools.ttLib import TTFont
from PIL import Image, ImageDraw, ImageFont

# ───────────────────────── 参数 ─────────────────────────
GLOBAL_SEED = 20260905
# 扰动幅度（占 em 千分比；em=1000 units）。
# 站酷快乐体自带手绘感，扰动取半档——保留"每个字微微不一样"，可读性优先
ON_CURVE_PCT = 1.1     # 骨架点位移 σ
OFF_CURVE_PCT = 1.6    # 控制点位移 σ（更活）
TILT_MAX = 0.012       # 整体剪切斜率上限（x += y * tilt）
# 输入骨架：站酷快乐体（开源可商用，马克笔粗壮手绘风 = 等粗笔画，
# 可读性远高于细骨架文楷；仅作扰动管线的轮廓源）
SRC = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "..",
                                    "assets", "fonts", "ZCOOLKuaiLe-Regular.ttf"))
OUT = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "..",
                                    "assets", "fonts", "StickHand-Regular.ttf"))

PREVIEW_TXT = "火柴人帝国模拟 0123 手绘风 Attack!"


def perturb_font() -> None:
    rng = random.Random(GLOBAL_SEED)
    font = TTFont(SRC)
    glyf = font["glyf"]
    upem = font["head"].unitsPerEm
    stats = {"glyphs": 0, "simple": 0, "composite": 0}

    for name in glyf.glyphs:
        glyph = glyf[name]
        g_rng = random.Random((GLOBAL_SEED * 1000003) ^ hash(name) & 0xFFFFFFFF)
        tilt = g_rng.uniform(-TILT_MAX, TILT_MAX)
        if glyph.isComposite():
            stats["composite"] += 1
            # 组合字形：扰动组件锚点（位移传导给引用的基础字形）
            for comp in glyph.components:
                if hasattr(comp, "x") and hasattr(comp, "y"):
                    dx = g_rng.gauss(0, ON_CURVE_PCT * 0.001 * upem * 0.5)
                    dy = g_rng.gauss(0, ON_CURVE_PCT * 0.001 * upem * 0.5)
                    comp.x += round(dx)
                    comp.y += round(dy)
            stats["glyphs"] += 1
            continue
        if glyph.numberOfContours == 0 or not hasattr(glyph, "coordinates"):
            continue
        coords = glyph.coordinates
        flags = glyph.flags
        # TrueType: flag bit0=1 为 on-curve
        for i in range(len(coords)):
            on = bool(flags[i] & 0x01)
            sigma = (ON_CURVE_PCT if on else OFF_CURVE_PCT) * 0.001 * upem
            dx = g_rng.gauss(0, sigma)
            dy = g_rng.gauss(0, sigma)
            # 微倾斜剪切（y 越高偏越多，随字形随机正负）
            x, y = coords[i]
            coords[i] = (x + round(dx + y * tilt), y + round(dy))
        glyph.coordinates = coords
        stats["simple"] += 1
        stats["glyphs"] += 1

    font.save(OUT)
    print(f"[gen_hand_font] {stats['glyphs']} glyphs ({stats['simple']} simple / "
          f"{stats['composite']} composite) -> {OUT}")


def render_preview() -> None:
    """并排渲染原版/扰动版，人工核对扰动可见性与可读性。"""
    size = 44
    pad = 24
    f_src = ImageFont.truetype(SRC, size)
    f_out = ImageFont.truetype(OUT, size)
    img = Image.new("RGB", (1200, 200), (16, 16, 20))
    dr = ImageDraw.Draw(img)
    dr.text((pad, pad), "SRC 原版文楷:", font=f_src, fill=(120, 120, 130))
    dr.text((pad, pad + 60), PREVIEW_TXT, font=f_src, fill=(235, 235, 240))
    dr.text((pad, pad + 120), "STICK 扰动手写:", font=f_src, fill=(120, 120, 130))
    dr.text((pad, pad + 168), PREVIEW_TXT, font=f_out, fill=(240, 200, 120))
    out_png = os.path.join(os.path.dirname(__file__), "_preview_hand.png")
    img.save(out_png)
    print(f"[gen_hand_font] preview -> {out_png}")


if __name__ == "__main__":
    perturb_font()
    render_preview()
