# -*- coding: utf-8 -*-
"""64px 原生尺寸验收图：成品 PNG 原样拼页（无重采样，8×8/页），附数值体检。
创始人验收纪律：直读 64px 原图（读大图会压缩看不清）。本脚本拼图不做任何缩放，
每格即成品本尊。产出 temp/accept_p{n}.png + 终端体检报告。"""
import os
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont

BASE = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "temp"))
ICON_DIR = os.path.join(BASE, "icons")
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

# 排序：旧 7 枚在前，其余按 motifs 注册表的分类顺序（生产工具→物流→…→火柴人）；
# 中文文件名按码点排序无意义，必须挂注册表
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import motifs as _M
    _ORDER = ["锻造锤", "爱心", "立方体", "正球", "圆柱", "圆锥", "圆环"] + [m["label"] for m in _M.MOTIFS]
except Exception as _e:
    print("registry unavailable, fallback alphabetical:", _e)
    _ORDER = []


def font(sz):
    for p in ("C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/simhei.ttf"):
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


names = [f[:-7] for f in os.listdir(ICON_DIR) if f.endswith("_64.png")]
names.sort(key=lambda n: (_ORDER.index(n) if n in _ORDER else 999, n))
FN = font(13)
FT = font(18)
issues = []
COLS, ROWS = 8, 8
PAGE = COLS * ROWS
pages = [names[i:i + PAGE] for i in range(0, len(names), PAGE)]
for pi, chunk in enumerate(pages):
    W, H = COLS * 68 + 20, ROWS * 92 + 50
    im = Image.new("RGB", (W, H), (30, 30, 34))
    d = ImageDraw.Draw(im)
    d.text((14, 10), f"64px 原生验收 p{pi + 1}/{len(pages)}（每格=成品本尊，无缩放）", font=FT, fill=(230, 230, 235))
    for k, name in enumerate(chunk):
        img = Image.open(os.path.join(ICON_DIR, f"{name}_64.png")).convert("RGBA")
        a = np.asarray(img)
        ys, xs = np.where(a[..., 3] > 10)
        l, r = int(xs.min()), 63 - int(xs.max())
        t, b = int(ys.min()), 63 - int(ys.max())
        w_bbox, h_bbox = int(xs.max() - xs.min() + 1), int(ys.max() - ys.min() + 1)
        tag = f"{name} L{l} R{r} T{t} B{b}"
        if w_bbox < 40 or h_bbox < 40:
            issues.append(f"{name}: 主体过小 {w_bbox}x{h_bbox}")
        if max(l, r, t, b) > 14:
            issues.append(f"{name}: 贴边/出界 边距{l},{r},{t},{b}")
        if abs(l - r) > 6 or abs(t - b) > 6:
            issues.append(f"{name}: 居中偏差 边距{l},{r},{t},{b}")
        x, y = 20 + (k % COLS) * 68, 50 + (k // COLS) * 92
        im.paste(checker((64, 64)), (x, y))
        im.paste(img, (x, y), img)
        d.text((x, y + 66), name[:14], font=FN, fill=(200, 200, 205))
    im.save(os.path.join(BASE, f"accept_p{pi + 1}.png"))

print(f"{len(names)} icons, {len(pages)} page(s)")
for s in issues:
    print("WARN", s)
if not issues:
    print("numeric check: all clean")
