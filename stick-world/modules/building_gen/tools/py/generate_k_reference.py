"""
方案K：基于参考图观察的真实茅草算法（Python 原型）

参考图特征：
- 屋顶由 3-4 层水平铺设的草帘组成
- 每层内部是大量斜向下的草丝
- 草丝方向与屋顶斜面一致（左坡向左下，右坡向右下）
- 层底边缘参差不齐
- 整体顶部亮、底部暗

输出：reference/preview_thatch_K.png
"""

import cv2
import numpy as np
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BUILDING_GEN = os.path.normpath(os.path.join(SCRIPT_DIR, "..", ".."))
REF_DIR = os.path.join(BUILDING_GEN, "reference")
OUTPUT_PATH = os.path.join(REF_DIR, "preview_thatch_K.png")

W, H = 512, 512

# 色板（BGR 0-255，因为 OpenCV 用 BGR）
PALETTE = {
    'highlight': np.array([126, 185, 233], dtype=np.float64),
    'bright':    np.array([93, 156, 212], dtype=np.float64),
    'main':      np.array([63, 125, 191], dtype=np.float64),
    'mid':       np.array([48, 99, 165], dtype=np.float64),
    'dark':      np.array([35, 65, 114], dtype=np.float64),
    'shadow':    np.array([15, 28, 50], dtype=np.float64),
}


def draw_bundle(img, rng, x0, y0, angle_deg, length, width, color_root, color_tip):
    """画一捆草：多条从 (x0,y0) 出发、方向 angle_deg、长度 length 的草丝"""
    angle = np.radians(angle_deg)
    ux, uy = np.cos(angle), np.sin(angle)
    # 垂直方向
    vx, vy = -uy, ux

    # 一捆里有 n 根草丝
    n_blades = rng.integers(8, 20)
    for b in range(n_blades):
        # 每根草丝在根部有偏移
        offset = rng.uniform(-width/2, width/2)
        bx0 = x0 + vx * offset
        by0 = y0 + vy * offset
        # 长度和方向有变化
        blen = int(length * rng.uniform(0.7, 1.1))
        bang = angle + rng.uniform(-0.15, 0.15)
        bux, buy = np.cos(bang), np.sin(bang)
        # 每根草丝的宽度
        bwidth = rng.integers(1, 3)
        for t in range(blen):
            k = t / max(blen - 1, 1)
            px = int(bx0 + bux * t)
            py = int(by0 + buy * t)
            if py < 0 or py >= H or px < 0 or px >= W:
                continue
            c = color_root * (1 - k * 0.8) + color_tip * (k * 0.8)
            c += rng.uniform(-8, 8, 3)
            c = np.clip(c, 0, 255).astype(np.uint8)
            for dw in range(-bwidth//2, bwidth//2 + 1):
                qx = (px + int(-buy * dw)) % W
                qy = py + int(bux * dw)
                if 0 <= qy < H:
                    img[qy, qx] = c


def draw_layer(img, rng, top_y, bot_y, color_root, color_tip, color_bg, is_bottom=False):
    """画一层茅草帘"""
    layer_h = bot_y - top_y

    # 1. 填充底色（本层区域）
    for y in range(top_y, min(bot_y + 3, H)):
        t = (y - top_y) / max(layer_h, 1)
        c = color_bg * (1 - t * 0.2)
        c += rng.uniform(-5, 5, 3)
        c = np.clip(c, 0, 255).astype(np.uint8)
        img[y, :] = c

    # 2. 画这层的草束
    # 草束从层顶部附近开始，向下延伸
    n_bundles = W // 35
    for i in range(n_bundles):
        x = (i * 35 + rng.integers(-12, 13)) % W
        y = top_y + rng.integers(0, int(layer_h * 0.3))
        # 方向：向下倾斜，与屋顶斜面一致
        # 左坡方向约 110°（从右上向左下），这里混合 95-145°（更斜）
        angle = rng.uniform(95, 145)
        length = int(layer_h * rng.uniform(0.9, 1.4))
        width = rng.integers(14, 26)
        draw_bundle(img, rng, x, y, angle, length, width, color_root, color_tip)

    # 3. 层底参差不齐（草尖垂挂）
    jagged_depth = layer_h * (0.6 if is_bottom else 0.35)
    for x in range(W):
        if rng.random() < 0.7:
            depth = rng.uniform(0.2, 1.0) * jagged_depth
            y_end = int(bot_y + depth)
            for y in range(bot_y, min(y_end + 1, H)):
                c = color_tip * 0.8 + rng.uniform(-6, 4, 3)
                c = np.clip(c, 0, 255).astype(np.uint8)
                img[y, x] = c


def generate():
    img = np.full((H, W, 3), 30, dtype=np.uint8)
    rng = np.random.default_rng(42)

    num_layers = 4
    layer_h = H / num_layers

    for layer_idx in range(num_layers - 1, -1, -1):
        top_y = int(layer_idx * layer_h)
        bot_y = int((layer_idx + 1) * layer_h)
        ty = top_y / H

        if ty < 0.25:
            color_root = PALETTE['highlight']
            color_tip = PALETTE['bright']
            color_bg = PALETTE['bright']
        elif ty < 0.5:
            color_root = PALETTE['bright']
            color_tip = PALETTE['main']
            color_bg = PALETTE['main']
        elif ty < 0.75:
            color_root = PALETTE['main']
            color_tip = PALETTE['mid']
            color_bg = PALETTE['mid']
        else:
            color_root = PALETTE['mid']
            color_tip = PALETTE['dark']
            color_bg = PALETTE['dark']

        is_bottom = (layer_idx == num_layers - 1)
        draw_layer(img, rng, top_y, bot_y, color_root, color_tip, color_bg, is_bottom)

    cv2.imwrite(OUTPUT_PATH, img)
    print(f"OK: {OUTPUT_PATH}")


if __name__ == "__main__":
    generate()
