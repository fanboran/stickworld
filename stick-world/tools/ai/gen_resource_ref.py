# -*- coding: utf-8 -*-
"""程序化生成资源点参考图（石头/树）—— 供笔触拟合管线的输入。

不用 AI 生图：用低多边形形状 + 光照渐变 + 噪声纹理直接合成参考图，
再交给 stroke_paint.py 做油画笔触化。白底便于抠图。
用法：python gen_resource_ref.py [输出目录]
"""
import os
import sys
import math
import random

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

W = H = 256
BG = (250, 250, 250)


def _rock_polygon(cx, cy, rw, rh, n, seed):
    rnd = random.Random(seed)
    pts = []
    for i in range(n):
        a = 2.0 * math.pi * i / n + rnd.uniform(-0.16, 0.16)
        rr = rnd.uniform(0.76, 1.14)
        pts.append((cx + math.cos(a) * rw * rr, cy + math.sin(a) * rh * rr))
    return pts


def _apply_lighting(arr, light_pos=(0.28, 0.22), strength=0.34):
    """左上光源：距光源越近越亮，远处压暗（保持主体可辨识）。"""
    yy, xx = np.mgrid[0:H, 0:W]
    d = np.hypot((xx / W - light_pos[0]) * 1.6, (yy / H - light_pos[1]))
    light = 1.0 - strength * np.clip(d / 1.15, 0, 1)
    return np.clip(arr * light[..., None], 0, 255)


def _mask_from_shapes(polygons, ellipses=()):
    """形状白、背景黑的 alpha mask（供笔触管线精确抠图）。"""
    m = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(m)
    for pts in polygons:
        d.polygon(pts, fill=255)
    for box in ellipses:
        d.ellipse(box, fill=255)
    return m.filter(ImageFilter.GaussianBlur(1.2))


def gen_stone(path):
    img = Image.new("RGB", (W, H), BG)
    draw = ImageDraw.Draw(img)
    # 主体大石 + 两块伴石（低多边形感：少顶点 + 顶点噪声）
    draw.polygon(_rock_polygon(132, 148, 84, 60, 9, 11), fill=(136, 133, 127))
    draw.polygon(_rock_polygon(66, 196, 36, 24, 7, 23), fill=(121, 118, 113))
    draw.polygon(_rock_polygon(196, 202, 28, 20, 7, 31), fill=(128, 124, 119))
    # 裂缝折线（暗色细线）
    rnd = random.Random(5)
    for _ in range(4):
        x, y = rnd.randint(80, 180), rnd.randint(100, 170)
        pts = [(x, y)]
        for _s in range(4):
            x += rnd.randint(-16, 16)
            y += rnd.randint(6, 20)
            pts.append((x, y))
        draw.line(pts, fill=(96, 93, 89), width=3)
    arr = np.asarray(img).astype(np.float32)
    # 斑点纹理
    rng = np.random.default_rng(9)
    speck = rng.normal(0, 10, (H, W, 1))
    arr = _apply_lighting(np.clip(arr + speck, 0, 255))
    out = Image.fromarray(np.uint8(arr))
    out = out.filter(ImageFilter.GaussianBlur(0.6))
    out.save(path)
    mask = _mask_from_shapes([
        _rock_polygon(132, 148, 88, 63, 9, 11),
        _rock_polygon(66, 196, 38, 26, 7, 23),
        _rock_polygon(196, 202, 30, 22, 7, 31),
    ])
    mask.save(path.replace("_ref.png", "_mask.png"))
    print("[ref] stone ->", path)


def gen_tree(path):
    img = Image.new("RGB", (W, H), BG)
    draw = ImageDraw.Draw(img)
    # 树干（微梯形）+ 根部展宽
    draw.polygon([(118, 88), (138, 88), (146, 236), (110, 236)], fill=(122, 88, 58))
    # 树冠三团（深→浅叠压，手工感色阶）
    draw.ellipse((36, 24, 158, 140), fill=(64, 110, 62))
    draw.ellipse((98, 40, 222, 152), fill=(74, 124, 68))
    draw.ellipse((66, 66, 176, 168), fill=(88, 140, 76))
    # 高光斑（左上光源方向的亮绿团）
    draw.ellipse((56, 40, 116, 92), fill=(112, 162, 92))
    draw.ellipse((120, 56, 168, 100), fill=(104, 152, 86))
    # 树干纹理线
    for x0 in (122, 128, 134):
        draw.line([(x0, 100), (x0 + 2, 230)], fill=(100, 70, 46), width=2)
    arr = np.asarray(img).astype(np.float32)
    rng = np.random.default_rng(3)
    speck = rng.normal(0, 7, (H, W, 1))
    arr = _apply_lighting(np.clip(arr + speck, 0, 255), strength=0.28)
    Image.fromarray(np.uint8(arr)).filter(ImageFilter.GaussianBlur(0.5)).save(path)
    mask = _mask_from_shapes([], ellipses=[
        (30, 18, 164, 146), (92, 34, 228, 158), (60, 60, 182, 174),
        (112, 78, 152, 240),
    ])
    mask.save(path.replace("_ref.png", "_mask.png"))
    print("[ref] tree ->", path)


if __name__ == "__main__":
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out_dir, exist_ok=True)
    gen_stone(os.path.join(out_dir, "stone_ref.png"))
    gen_tree(os.path.join(out_dir, "tree_ref.png"))
