"""
方案J Python 原型：验证"一绺绺斜向草束"算法
直接生成贴图查看效果，调试正确后再移植到 Godot
"""
import cv2
import numpy as np
import os

OUTPUT_PATH = r"f:/VSCode/game-2/stick-world/modules/building_gen/reference/preview_thatch_py.png"

W, H = 512, 512

# 色板（BGR，从亮到暗）
PALETTE = {
    'highlight': np.array([126, 185, 233], dtype=np.float64),  # 高光（亮金黄）
    'bright':    np.array([103, 165, 219], dtype=np.float64),  # 亮区
    'light':     np.array([84, 146, 207], dtype=np.float64),   # 中亮
    'main':      np.array([63, 125, 191], dtype=np.float64),   # 主色
    'mid':       np.array([48, 102, 170], dtype=np.float64),   # 中间
    'dark':      np.array([38, 79, 140], dtype=np.float64),    # 暗区
    'shadow':    np.array([21, 47, 97], dtype=np.float64),     # 阴影
    'gap':       np.array([15, 28, 50], dtype=np.float64),     # 层间缝隙
}


def draw_strand(img, x0, y0, dx, dy, length, width, base_color, tip_color, rng):
    """画一条带渐变的斜向草束"""
    h, w = img.shape[:2]
    d_len = np.sqrt(dx*dx + dy*dy)
    if d_len < 0.001:
        return
    ux, uy = dx / d_len, dy / d_len
    for t in range(length):
        px = int(x0 + ux * t)
        py = int(y0 + uy * t)
        if py < 0 or py >= h:
            continue
        # 沿长度的渐变（0=根部，1=尖端）—— 只暗化到 40%
        k = t / max(length - 1, 1)
        c = base_color * (1 - k * 0.4) + tip_color * (k * 0.4)
        # 像素抖动
        jitter = rng.uniform(-6, 6, 3)
        c = np.clip(c + jitter, 0, 255)
        # 画 width 像素宽，x 方向 wrap
        for dw in range(-width // 2, width // 2 + 1):
            qx = int(px - uy * dw) % w
            qy = int(py + ux * dw)
            if qy < 0 or qy >= h:
                continue
            img[qy, qx] = c


def gen_jagged_bottom(x_start, x_end, base_y, max_depth, rng, segment_w):
    """生成参差不齐的底部折线"""
    points = [(x_start, base_y)]
    x = x_start
    while x < x_end:
        depth = rng.uniform(0.3, 1.0) * max_depth
        tip_y = base_y + depth
        points.append((x + segment_w // 2, tip_y))
        x += segment_w
        points.append((x, base_y + rng.uniform(0, 0.3) * max_depth))
    points.append((x_end, base_y))
    return points


def draw_thatch_layer(img, top_y, bot_y, color_root, color_tip, color_bg, rng, is_bottom_layer=False):
    """画一层茅草：底色 + 斜向草束 + 参差底部"""
    h, w = img.shape[:2]
    layer_h = bot_y - top_y

    # === 阶段1：填充底色（顶部稍暗） ===
    fill_end = min(bot_y + int(layer_h * 0.3) + 2, h)  # 只覆盖下层 30%（不要覆盖太多）
    for y in range(top_y, fill_end):
        if y < 0 or y >= h:
            continue
        t = (y - top_y) / max(layer_h, 1)
        c = color_bg.copy()
        if t < 0.1:  # 顶部 10% 暗化（层间缝隙）
            c = c * (1 - (0.1 - t) / 0.1 * 0.6) + PALETTE['gap'] * ((0.1 - t) / 0.1 * 0.6)
        jitter = rng.uniform(-5, 5, 3)
        c = np.clip(c + jitter, 0, 255)
        img[y, :] = c

    # === 阶段2：画一排斜向草束 ===
    # 草束根部从层底向上分布（覆盖整个层高）
    strand_count = w // 4
    strand_length = int(layer_h * rng.uniform(1.0, 1.4))  # 草束比层高更长，跨入上层
    for i in range(strand_count):
        root_x = (i * 4 + rng.integers(-1, 2)) % w
        # 草束根部从层底到层中分布
        root_y = bot_y - rng.integers(0, max(layer_h // 2, 1))
        # 草束方向：斜向上，角度 -75° 到 -25°（有些更陡，有些更斜）
        angle = rng.uniform(-np.pi * 75 / 180, -np.pi * 25 / 180)
        dx = np.cos(angle)
        dy = np.sin(angle)
        length = strand_length + rng.integers(-15, 15)
        width = rng.integers(2, 4)  # 草束更粗 2-3px
        # 草束颜色：根部亮，尖端暗
        root_jitter = rng.uniform(-10, 10, 3)
        root_c = np.clip(color_root + root_jitter, 0, 255)
        tip_jitter = rng.uniform(-8, 8, 3)
        tip_c = np.clip(color_tip + tip_jitter, 0, 255)
        draw_strand(img, root_x, root_y, dx, dy, length, width, root_c, tip_c, rng)

    # === 阶段3：参差底部（草尖垂挂） ===
    jagged_depth = layer_h * 0.35
    if is_bottom_layer:
        jagged_depth = layer_h * 0.55
    bottom_pts = gen_jagged_bottom(0, w, bot_y, jagged_depth, rng, rng.integers(4, 10))
    for i in range(len(bottom_pts) - 1):
        x1, y1 = bottom_pts[i]
        x2, y2 = bottom_pts[i + 1]
        y_lo = int(min(y1, y2))
        y_hi = int(max(y1, y2)) + 2
        for y in range(y_lo, y_hi):
            if y < 0 or y >= h:
                continue
            tip_jitter = rng.uniform(-8, 4, 3)
            tip_color = np.clip(color_tip * 0.7 + tip_jitter, 0, 255)
            x_min = int(min(x1, x2))
            x_max = int(max(x1, x2)) + 1
            x_min = max(x_min, 0)
            x_max = min(x_max, w)
            img[y, x_min:x_max] = tip_color


def main():
    rng = np.random.default_rng(42)

    img = np.full((H, W, 3), 15, dtype=np.uint8)  # 深色底色

    num_layers = 5
    layer_height = H / num_layers

    for layer_idx in range(num_layers - 1, -1, -1):
        top_y = int(layer_idx * layer_height)
        bot_y = int((layer_idx + 1) * layer_height)
        ty = top_y / H

        if ty < 0.25:
            color_root = PALETTE['highlight']
            color_tip = PALETTE['bright']
            color_bg = PALETTE['bright']
        elif ty < 0.55:
            color_root = PALETTE['bright']
            color_tip = PALETTE['main']
            color_bg = PALETTE['light']
        elif ty < 0.8:
            color_root = PALETTE['light']
            color_tip = PALETTE['mid']
            color_bg = PALETTE['main']
        else:
            color_root = PALETTE['main']
            color_tip = PALETTE['dark']
            color_bg = PALETTE['mid']

        is_bottom = (layer_idx == num_layers - 1)
        draw_thatch_layer(img, top_y, bot_y, color_root, color_tip, color_bg, rng, is_bottom)

    cv2.imwrite(OUTPUT_PATH, img)
    print(f"[OK] Python 原型已生成: {OUTPUT_PATH}")
    print(f"  色板:")
    pixels = np.float32(img.reshape(-1, 3))
    criteria = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 0.5)
    _, labels, centers = cv2.kmeans(pixels, 6, None, criteria, 5, cv2.KMEANS_PP_CENTERS)
    centers = np.uint8(centers)
    label_counts = np.bincount(labels.flatten())
    sorted_idx = np.argsort(-label_counts)
    for rank, idx in enumerate(sorted_idx):
        bgr = centers[idx]
        rgb = bgr[::-1]
        pct = label_counts[idx] / len(labels) * 100
        print(f"    {rank+1}. BGR={bgr.tolist()} RGB={rgb.tolist()} {pct:.2f}%")


if __name__ == "__main__":
    main()
