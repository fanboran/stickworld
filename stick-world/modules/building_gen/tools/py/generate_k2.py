"""
方案K2：真正的茅草帘效果

每层 = 一条水平"草帘"，从层顶向下垂挂大量草丝
- 草丝从层顶边缘长出
- 方向向下倾斜（左坡向左下，右坡向右下）
- 草丝会轻微弯曲、散开
- 层顶有一条较暗的根部线（被上层遮挡）
- 层底参差不齐
"""

import cv2
import numpy as np
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BUILDING_GEN = os.path.normpath(os.path.join(SCRIPT_DIR, "..", ".."))
REF_DIR = os.path.join(BUILDING_GEN, "reference")
OUTPUT_PATH = os.path.join(REF_DIR, "preview_thatch_K2.png")

W, H = 512, 512

# 色板 BGR
PALETTE = {
    'highlight': np.array([126, 185, 233], dtype=np.float64),
    'bright':    np.array([93, 156, 212], dtype=np.float64),
    'main':      np.array([63, 125, 191], dtype=np.float64),
    'mid':       np.array([48, 99, 165], dtype=np.float64),
    'dark':      np.array([35, 65, 114], dtype=np.float64),
    'shadow':    np.array([15, 28, 50], dtype=np.float64),
}


def blend(a, b, k):
    return a * (1 - k) + b * k


def draw_curved_strand(img, rng, x0, y0, angle, length, width, color_root, color_tip):
    """画一根轻微弯曲的草丝"""
    rad = np.radians(angle)
    ux, uy = np.cos(rad), np.sin(rad)
    # 弯曲控制点：中点向垂直方向偏移
    mid_x = x0 + ux * length * 0.5
    mid_y = y0 + uy * length * 0.5
    # 垂直于方向的偏移
    vx, vy = -uy, ux
    bend = rng.uniform(-length * 0.15, length * 0.15)
    mid_x += vx * bend
    mid_y += vy * bend

    # 二次贝塞尔曲线上的点
    n_steps = int(length * 1.5)
    ts = np.linspace(0, 1, n_steps)
    p0 = np.array([x0, y0], dtype=np.float64)
    p1 = np.array([mid_x, mid_y], dtype=np.float64)
    p2 = np.array([x0 + ux * length, y0 + uy * length], dtype=np.float64)
    pts = (1 - ts)[:, None]**2 * p0 + 2 * (1 - ts)[:, None] * ts[:, None] * p1 + ts[:, None]**2 * p2
    pts = pts.astype(np.int32)

    for i, (px, py) in enumerate(pts):
        if py < 0 or py >= H or px < 0 or px >= W:
            continue
        k = ts[i]
        c = blend(color_root, color_tip, k * 0.85)
        c += rng.uniform(-6, 6, 3)
        c = np.clip(c, 0, 255).astype(np.uint8)
        for dw in range(-width // 2, width // 2 + 1):
            qx = (px + dw) % W
            img[py, qx] = c


def draw_layer(img, rng, top_y, bot_y, color_root, color_tip, color_bg, is_bottom=False):
    layer_h = bot_y - top_y

    # 1. 填充层底色
    for y in range(top_y, min(bot_y + 2, H)):
        t = (y - top_y) / max(layer_h, 1)
        c = blend(color_bg, color_tip, t * 0.3)
        c += rng.uniform(-4, 4, 3)
        c = np.clip(c, 0, 255).astype(np.uint8)
        img[y, :] = c

    # 2. 层顶根部线（较暗，被上层遮挡）
    root_h = max(3, int(layer_h * 0.08))
    for y in range(top_y, min(top_y + root_h, H)):
        k = (y - top_y) / root_h
        c = blend(PALETTE['shadow'], color_bg, k)
        c += rng.uniform(-3, 3, 3)
        c = np.clip(c, 0, 255).astype(np.uint8)
        img[y, :] = c

    # 3. 从层顶向下垂挂大量草丝
    # 方向：主要向下，混合左右两个斜向
    n_strands = W * 1
    for i in range(n_strands):
        x = rng.integers(0, W)
        y = top_y + rng.integers(0, root_h)
        # 方向：90° 是垂直向下。左坡约 120°，右坡约 60°
        if rng.random() < 0.5:
            angle = rng.uniform(105, 135)  # 左下
        else:
            angle = rng.uniform(45, 75)    # 右下
        length = int(layer_h * rng.uniform(0.7, 1.2))
        width = rng.integers(1, 2)
        draw_curved_strand(img, rng, x, y, angle, length, width, color_root, color_tip)

    # 4. 画一些粗的草束（一绺绺的感觉）
    n_bundles = W // 28
    for i in range(n_bundles):
        x = (i * 28 + rng.integers(-10, 11)) % W
        y = top_y + rng.integers(0, root_h)
        if rng.random() < 0.5:
            angle = rng.uniform(110, 130)
        else:
            angle = rng.uniform(50, 70)
        length = int(layer_h * rng.uniform(0.9, 1.3))
        width = rng.integers(3, 6)
        # 一束草里有几根
        for b in range(rng.integers(5, 12)):
            bx = x + rng.integers(-6, 7)
            by = y + rng.integers(-2, 3)
            ba = angle + rng.uniform(-8, 8)
            bl = int(length * rng.uniform(0.8, 1.1))
            bw = rng.integers(1, 3)
            draw_curved_strand(img, rng, bx, by, ba, bl, bw, color_root, color_tip)

    # 5. 层底参差不齐
    jagged_depth = layer_h * (0.5 if is_bottom else 0.25)
    for x in range(W):
        if rng.random() < 0.6:
            depth = rng.uniform(0.1, 1.0) * jagged_depth
            y_end = int(bot_y + depth)
            for y in range(bot_y, min(y_end + 1, H)):
                c = color_tip * 0.85 + rng.uniform(-5, 3, 3)
                c = np.clip(c, 0, 255).astype(np.uint8)
                img[y, x] = c


def generate():
    img = np.full((H, W, 3), 25, dtype=np.uint8)
    rng = np.random.default_rng(42)

    num_layers = 4
    layer_h = H / num_layers

    for layer_idx in range(num_layers - 1, -1, -1):
        top_y = int(layer_idx * layer_h)
        bot_y = int((layer_idx + 1) * layer_h)
        ty = top_y / H

        if ty < 0.25:
            color_root = PALETTE['highlight']
            color_tip = PALETTE['main']
            color_bg = PALETTE['bright']
        elif ty < 0.5:
            color_root = PALETTE['bright']
            color_tip = PALETTE['mid']
            color_bg = PALETTE['main']
        elif ty < 0.75:
            color_root = PALETTE['main']
            color_tip = PALETTE['dark']
            color_bg = PALETTE['mid']
        else:
            color_root = PALETTE['mid']
            color_tip = PALETTE['shadow']
            color_bg = PALETTE['dark']

        is_bottom = (layer_idx == num_layers - 1)
        draw_layer(img, rng, top_y, bot_y, color_root, color_tip, color_bg, is_bottom)

    cv2.imwrite(OUTPUT_PATH, img)
    print(f"OK: {OUTPUT_PATH}")


if __name__ == "__main__":
    generate()
