# -*- coding: utf-8 -*-
"""v1/v2 架构换代对照页：baseline_v1/ 与 icons/ 的 64px 成品逐枚并排（无缩放），
附逐枚差异度体检（改变像素占比 + 用色数变化），供创始人对比定夺与 AI 重点复读。
产出 temp/compare_v1v2_p{n}.png；终端打印差异度 TOP 榜（大=该枚观感变化大）。
用法: python compare_v1_v2.py [--size 64]"""
import os
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont

BASE = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "temp"))
V1 = os.path.join(BASE, "baseline_v1")
V2 = os.path.join(BASE, "icons")
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
SIZE = 64
if "--size" in sys.argv:
    SIZE = int(sys.argv[sys.argv.index("--size") + 1])

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import motifs as _M
    _ORDER = ["锻造锤", "爱心", "立方体", "正球", "圆柱", "圆锥", "圆环"] + [m["label"] for m in _M.MOTIFS]
except Exception:
    _ORDER = []


def font(sz, bold=False):
    for p in (("C:/Windows/Fonts/msyhbd.ttc" if bold else "C:/Windows/Fonts/msyh.ttc"),
              "C:/Windows/Fonts/simhei.ttf"):
        try:
            return ImageFont.truetype(p, sz)
        except Exception:
            pass
    return ImageFont.load_default()


def checker(size, cell=8):
    b = Image.new("RGB", size, (170, 170, 170))
    d = ImageDraw.Draw(b)
    for y in range(0, size[1], cell):
        for x in range(0, size[0], cell):
            if (x // cell + y // cell) % 2:
                d.rectangle([x, y, x + cell, y + cell], fill=(120, 120, 120))
    return b


suffix = f"_{SIZE}.png"
names = [f[:-len(suffix)] for f in os.listdir(V2) if f.endswith(suffix)
         and os.path.exists(os.path.join(V1, f))]
names.sort(key=lambda n: (_ORDER.index(n) if n in _ORDER else 999, n))

FN = font(12)
FT = font(16, True)
stats = []
for name in names:
    a1 = np.asarray(Image.open(os.path.join(V1, f"{name}_{SIZE}.png")).convert("RGBA")).astype(np.int16)
    a2 = np.asarray(Image.open(os.path.join(V2, f"{name}_{SIZE}.png")).convert("RGBA")).astype(np.int16)
    diff = (np.abs(a1 - a2).max(axis=2) > 24)
    opaque = a1[..., 3] > 10
    ratio = diff[opaque].mean() if opaque.any() else 0.0
    c1 = len(np.unique(a1[opaque][:, :3] // 24, axis=0)) if opaque.any() else 0
    c2 = len(np.unique(a2[a2[..., 3] > 10][:, :3] // 24, axis=0)) if (a2[..., 3] > 10).any() else 0
    stats.append((name, ratio, c1, c2))

stats.sort(key=lambda s: -s[1])
print("== 差异度 TOP（改变像素占比，>24/255 容差；用色数为 24 级量化粗计）==")
for name, ratio, c1, c2 in stats[:20]:
    print(f"  {ratio * 100:5.1f}%  {name}  (v1 用色~{c1} -> v2 ~{c2})")
majors = [s for s in stats if s[1] > 0.60]
print(f"== {len(majors)} 枚改变像素 >60%，{len([s for s in stats if s[1] <= 0.05])} 枚基本未动 (<=5%) ==")

# 拼页：每行 [v1 | v2] 一对，8 对/页
PER = 8
pairs = {name: (ratio, c1, c2) for name, ratio, c1, c2 in stats}
rows = [(name, *pairs[name]) for name in names]
pages = [rows[i:i + PER] for i in range(0, len(rows), PER)]
CELLW, ROWH = 2 * (SIZE + 14) + 118, SIZE + 30
for pi, chunk in enumerate(pages):
    W, H = 24 + CELLW * len(chunk), 46 + ROWH * len(chunk)
    im = Image.new("RGB", (W, H), (30, 30, 34))
    d = ImageDraw.Draw(im)
    d.text((14, 10), f"v1/v2 对比 p{pi + 1}/{len(pages)}（左=main v1 基线，右=v2 分档换代，{SIZE}px 原生）",
           font=FT, fill=(230, 230, 235))
    for k, (name, ratio, c1, c2) in enumerate(chunk):
        y = 46 + k * ROWH
        if k % 2 == 0:
            d.rectangle([0, y - 4, W, y + ROWH - 4], fill=(12, 14, 20))
        im.paste(checker((SIZE, SIZE)), (20, y))
        img1 = Image.open(os.path.join(V1, f"{name}_{SIZE}.png")).convert("RGBA")
        im.paste(img1, (20, y), img1)
        x2 = 20 + SIZE + 14
        im.paste(checker((SIZE, SIZE)), (x2, y))
        img2 = Image.open(os.path.join(V2, f"{name}_{SIZE}.png")).convert("RGBA")
        im.paste(img2, (x2, y), img2)
        d.text((x2 + SIZE + 10, y + SIZE // 2),
               f"{name[:9]}\n{ratio * 100:.0f}%{' !' if ratio > 0.6 else ''}",
               font=FN, fill=(200, 200, 205), anchor="lm")
    im.save(os.path.join(BASE, f"compare_v1v2_{SIZE}_p{pi + 1}.png"))
print(f"saved {len(pages)} compare page(s) -> temp/compare_v1v2_{SIZE}_p*.png")
