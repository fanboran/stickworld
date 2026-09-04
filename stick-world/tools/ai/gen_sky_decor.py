# -*- coding: utf-8 -*-
"""程序化天空装饰贴图 —— 远山剪影 ×2 层 + 软云团（供 sky_decor.gd 挂载）。

风格：低多边形山脊 + 大气透视（远山蓝灰、近山绿灰），云为模糊椭圆簇。
用法：python gen_sky_decor.py [输出目录 assets/sky]
"""
import math
import os
import random
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

W = 2048


def _ridge(rnd, base_y, amp, n_peaks):
    """低多边形山脊线：n 个尖峰折线，首尾同高保证平铺无缝。"""
    pts = [(0, base_y)]
    x = 0.0
    step = W / n_peaks
    for i in range(n_peaks):
        peak_x = x + step * random.uniform(0.3, 0.7)
        peak_y = base_y - amp * random.uniform(0.55, 1.0)
        pts.append((peak_x, peak_y))
        x += step
        valley_y = base_y - amp * random.uniform(0.0, 0.25)
        pts.append((x, valley_y))
    pts[0] = (0, pts[-1][1])  # 平铺无缝
    return pts


def _vgrad_band(img, pts, color_top, color_bottom, y_bottom):
    """山体多边形 + 垂直渐变填充（逐行插值色）。"""
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    poly = pts + [(W, y_bottom), (0, y_bottom)]
    d.polygon(poly, fill=color_top)
    # 垂直渐变：按行合成
    arr = np.asarray(overlay).astype(np.float32)
    yy, _xx = np.mgrid[0:img.size[1], 0:W]
    top_y = min(p[1] for p in pts)
    t = np.clip((yy - top_y) / max(1.0, y_bottom - top_y), 0, 1)[..., None]
    c0 = np.array(color_top[:3], np.float32)
    c1 = np.array(color_bottom[:3], np.float32)
    arr[..., :3] = c0[None, None, :] * (1.0 - t) + c1[None, None, :] * t
    arr[..., 3] *= (np.asarray(overlay)[..., 3] > 0)
    return Image.alpha_composite(img, Image.fromarray(np.uint8(arr), "RGBA"))


def gen_mountains(path):
    H, y_base = 380, 330
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    rnd = random.Random(41)
    # 远层（蓝灰，大气透视）
    far = _ridge(rnd, y_base - 90, 170, 7)
    img = _vgrad_band(img, far, (128, 143, 160, 255), (150, 162, 175, 255), H)
    # 近层（绿灰，更深）
    near = _ridge(rnd, y_base - 20, 220, 5)
    img = _vgrad_band(img, near, (86, 104, 96, 255), (104, 120, 108, 255), H)
    img.save(path)
    print("[sky] mountains ->", path)


def gen_cloud(path, seed=1):
    """软云团 512x180：多椭圆白簇 → 大模糊 → 轻顶部亮/底部暗。"""
    Wc, Hc = 512, 180
    img = Image.new("RGBA", (Wc, Hc), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    rnd = random.Random(seed)
    cx = Wc * 0.5
    for i in range(9):
        ox = rnd.uniform(-140, 140)
        oy = rnd.uniform(-30, 24)
        rw = rnd.uniform(70, 150)
        rh = rw * rnd.uniform(0.30, 0.42)
        a = int(rnd.uniform(120, 175))
        d.ellipse((cx + ox - rw, Hc * 0.52 + oy - rh, cx + ox + rw, Hc * 0.52 + oy + rh),
                  fill=(252, 250, 246, a))
    img = img.filter(ImageFilter.GaussianBlur(14))
    img.save(path)
    print("[sky] cloud ->", path)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "assets/sky"
    os.makedirs(out, exist_ok=True)
    gen_mountains(os.path.join(out, "mountains.png"))
    gen_cloud(os.path.join(out, "cloud_a.png"), seed=1)
    gen_cloud(os.path.join(out, "cloud_b.png"), seed=7)
