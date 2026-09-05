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
    """Terraria 式平顶积云 512x200：圆簇叠出蓬松顶部 + 底边裁平，
    顶部亮/底部灰蓝的体积分明着色，仅 2px 轻模糊保持边缘可读（旧版大模糊糊成无定形团）。"""
    Wc, Hc = 512, 200
    rnd = random.Random(seed)
    base_y = Hc * 0.62  # 云底基线（裁平线）
    # alpha 蒙版：圆簇轮廓
    mask = Image.new("L", (Wc, Hc), 0)
    md = ImageDraw.Draw(mask)
    # 主轴大 puff（中央胖两端小，经典的积云剪影）
    n = 7
    for i in range(n):
        t = i / (n - 1)
        ox = (t - 0.5) * Wc * 0.72
        r = (1.0 - abs(t - 0.28) * 1.1) * rnd.uniform(46, 62) + 30
        cy = base_y - r * rnd.uniform(0.55, 0.8)
        md.ellipse((Wc * 0.5 + ox - r, cy - r, Wc * 0.5 + ox + r, cy + r), fill=255)
    # 顶部小凸起 puff（蓬松感）
    for i in range(5):
        ox = rnd.uniform(-Wc * 0.32, Wc * 0.32)
        r = rnd.uniform(14, 26)
        cy = base_y - rnd.uniform(62, 88)
        md.ellipse((Wc * 0.5 + ox - r, cy - r, Wc * 0.5 + ox + r, cy + r), fill=255)
    # 底部垫底宽椭圆（把簇底连成整体）
    md.ellipse((Wc * 0.14, base_y - 34, Wc * 0.86, base_y + 10), fill=255)
    # 底边裁平（积云标志性的平底）
    md.rectangle((0, base_y + 2, Wc, Hc), fill=0)
    mask = mask.filter(ImageFilter.GaussianBlur(2))
    # 着色：顶亮白 → 底灰蓝（体积感），沿蒙版内垂直渐变
    top_c, bot_c = (255, 253, 248), (203, 211, 222)
    yy = np.linspace(0.0, 1.0, Hc)[:, None]
    grad = np.zeros((Hc, Wc, 3), dtype=np.float32)
    for c in range(3):
        grad[:, :, c] = top_c[c] + (bot_c[c] - top_c[c]) * yy
    a = np.asarray(mask, dtype=np.float32) / 255.0
    out = np.dstack([grad, (a * 235)[:, :, None]]).astype(np.uint8)
    Image.fromarray(out, "RGBA").save(path)
    print("[sky] cloud ->", path)




def _tree_ridge(rnd, base_y, h, color, W=2048, H=320):
	"""Terraria 式茂密树线：每树双冠团（主干+侧枝团）+ 间隙起伏 + 顶部受光渐变，
	底部向基线加深（大气体积感）。平铺无缝。"""
	img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
	d = ImageDraw.Draw(img)
	c_top = tuple(min(255, int(c * 1.18)) for c in color[:3]) + (255,)
	c_mid = color
	c_base = tuple(int(c * 0.72) for c in color[:3]) + (255,)
	x = -40.0
	while x < W + 40:
		tw = rnd.uniform(24, 50)
		th = h * rnd.uniform(0.55, 1.2)
		top = base_y - th
		mid = base_y - th * 0.45
		# 主冠（三段折线）
		d.polygon([
			(x, base_y),
			(x + tw * 0.28, mid),
			(x + tw * 0.5 + rnd.uniform(-6, 6), top),
			(x + tw * 0.74, mid),
			(x + tw, base_y),
		], fill=c_mid)
		# 侧枝团（双冠层次：左或右侧叠一团小冠）
		side = -1 if rnd.random() < 0.5 else 1
		cx = x + tw * (0.5 + side * 0.42)
		cy = base_y - th * rnd.uniform(0.35, 0.62)
		cr = tw * rnd.uniform(0.22, 0.38)
		d.ellipse((cx - cr, cy - cr * rnd.uniform(0.8, 1.1),
		           cx + cr, cy + cr * rnd.uniform(0.8, 1.1)), fill=c_mid)
		# 顶部受光冠尖（亮色小三角盖顶）
		d.polygon([
			(x + tw * 0.30, top + th * 0.22),
			(x + tw * 0.5 + rnd.uniform(-5, 5), top - 2),
			(x + tw * 0.70, top + th * 0.22),
		], fill=c_top)
		x += tw * rnd.uniform(0.58, 0.88)  # 更密（重叠多一点）
	out = img.filter(ImageFilter.GaussianBlur(0.8))
	# 底部体积渐变（numpy 按深度乘暗：保留树干间隙的透气感，不做实心底带）
	arr = np.asarray(out, dtype=np.float32)
	Hh = arr.shape[0]
	yy = np.arange(Hh)[:, None, None]  # (H,1,1)：对 (H,W,3) 逐行广播
	fade_start = base_y - h * 0.35
	dark = np.clip(1.0 - 0.28 * np.clip((yy - fade_start) / max(base_y - fade_start, 1), 0, 1), 0.72, 1.0)
	arr[..., 0:3] *= dark
	return Image.fromarray(arr.astype(np.uint8), "RGBA")


def gen_treeline(path, seed, base_ratio, h, color):
	H = 320
	img = _tree_ridge(random.Random(seed), int(H * base_ratio), h, color, H=H)
	img.save(path)
	print("[sky] treeline ->", path)


def gen_fog(path):
	"""横向雾带（Kingdom 大气透视）：上下羽化的白带。"""
	Wf, Hf = 1024, 128
	arr = np.zeros((Hf, Wf, 4), np.uint8)
	yy = np.arange(Hf)[:, None] / Hf
	vert = np.clip(1.0 - np.abs(yy - 0.55) / 0.45, 0, 1) ** 1.6
	arr[..., 0:3] = 226
	arr[..., 3] = (vert * 150).astype(np.uint8)
	Image.fromarray(arr, "RGBA").filter(ImageFilter.GaussianBlur(6)).save(path)
	print("[sky] fog ->", path)


def gen_menu_stickman(path, frame):
	"""主菜单彩蛋：简笔火柴人剪影走路帧（2 帧循环）。"""
	S = 96
	img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
	d = ImageDraw.Draw(img)
	c = (24, 26, 32, 255)
	cx = S * 0.5
	d.ellipse((cx - 9, 10, cx + 9, 28), fill=c)
	d.line([(cx, 28), (cx, 56)], fill=c, width=5)
	swing = 10 if frame == 0 else -10
	d.line([(cx, 36), (cx - 14, 36 + swing)], fill=c, width=4)
	d.line([(cx, 36), (cx + 14, 36 - swing)], fill=c, width=4)
	d.line([(cx, 56), (cx - 12 + swing * 0.6, 84)], fill=c, width=5)
	d.line([(cx, 56), (cx + 12 - swing * 0.6, 84)], fill=c, width=5)
	img.save(path)
	print("[sky] menu stickman f%d ->" % frame, path)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "assets/sky"
    os.makedirs(out, exist_ok=True)
    gen_mountains(os.path.join(out, "mountains.png"))
    gen_cloud(os.path.join(out, "cloud_a.png"), seed=1)
    gen_cloud(os.path.join(out, "cloud_b.png"), seed=7)
    gen_cloud(os.path.join(out, "cloud_c.png"), seed=23)
    gen_treeline(os.path.join(out, "treeline_far.png"), seed=51,
                 base_ratio=0.86, h=120, color=(52, 72, 58, 235))
    gen_treeline(os.path.join(out, "treeline_near.png"), seed=77,
                 base_ratio=0.94, h=170, color=(30, 44, 38, 255))
    gen_fog(os.path.join(out, "fog_band.png"))
    gen_menu_stickman(os.path.join(out, "walker_f0.png"), frame=0)
    gen_menu_stickman(os.path.join(out, "walker_f1.png"), frame=1)
    gen_treeline(os.path.join(out, "treeline_far.png"), seed=51,
                 base_ratio=0.86, h=120, color=(52, 72, 58, 235))
    gen_treeline(os.path.join(out, "treeline_near.png"), seed=77,
                 base_ratio=0.94, h=170, color=(30, 44, 38, 255))
    gen_fog(os.path.join(out, "fog_band.png"))
    gen_menu_stickman(os.path.join(out, "walker_f0.png"), frame=0)
    gen_menu_stickman(os.path.join(out, "walker_f1.png"), frame=1)
