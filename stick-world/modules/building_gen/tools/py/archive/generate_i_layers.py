"""
方案I：水平分层 + 参差底部的茅草生成法

核心改进（基于参考图分析）：
- 参考图霍夫变换：1024条水平线 vs 13条垂直线 → 纹理以水平为主
- 画"一绺绺铺在房梁上的茅草"：水平分层 + 参差底部
- 每层结构：顶部阴影(被遮挡) → 中部高光(露出) → 底部参差草尖
- 大块色彩，拒绝高频噪波（风格化原则）
"""

import cv2
import numpy as np
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BUILDING_GEN = os.path.normpath(os.path.join(SCRIPT_DIR, "..", ".."))
REF_DIR = os.path.join(BUILDING_GEN, "reference")

REF_PATH = os.path.join(REF_DIR, "thatch_ref.png")
OUTPUT_PATH = os.path.join(REF_DIR, "preview_thatch_I.png")

TARGET_W, TARGET_H = 512, 512

# 从参考图提取的色板（BGR）
PALETTE = {
    'highlight': np.array([122, 182, 231], dtype=np.float64),  # 高光（阳光漂白）
    'bright':    np.array([93, 156, 212], dtype=np.float64),   # 亮区
    'main':      np.array([66, 127, 192], dtype=np.float64),   # 主色
    'dark':      np.array([48, 99, 165], dtype=np.float64),    # 暗区
    'shadow':    np.array([35, 65, 114], dtype=np.float64),    # 阴影
    'gap':       np.array([15, 28, 50], dtype=np.float64),     # 层间缝隙
}


def generate_jagged_bottom(x_start, x_end, base_y, max_depth, rng, segment_w=8):
    """
    生成参差不齐的底部折线——模拟草尖垂挂
    返回折线点列表 [(x, y), ...]
    """
    points = [(x_start, base_y)]
    x = x_start
    while x < x_end:
        # 每段草尖的垂挂深度随机
        depth = rng.uniform(0.3, 1.0) * max_depth
        tip_y = base_y + depth
        points.append((x + segment_w // 2, tip_y))
        x += segment_w
        points.append((x, base_y + rng.uniform(0, 0.3) * max_depth))
    points.append((x_end, base_y))
    return points


def draw_thatch_layer(img, top_y, bot_y, color_top, color_mid, color_bot, rng, is_bottom_layer=False):
    """
    画一层茅草——水平带 + 参差底部 + 水平纹理条纹
    """
    h, w = img.shape[:2]
    layer_h = bot_y - top_y

    # 生成参差底部
    jagged_depth = layer_h * 0.35 if not is_bottom_layer else layer_h * 0.6
    bottom_points = generate_jagged_bottom(0, w, bot_y, jagged_depth, rng, segment_w=rng.integers(4, 10))

    # 用渐变填充层区域（逐行，向量化）
    for y in range(top_y, min(bot_y + int(jagged_depth) + 2, h)):
        if y < 0 or y >= h:
            continue
        t = (y - top_y) / max(layer_h, 1)

        if t < 0.12:
            color = color_top
        elif t < 0.35:
            k = (t - 0.12) / 0.23
            color = color_top * (1 - k) + color_mid * k
        elif t < 0.6:
            color = color_mid
        elif t < 0.85:
            k = (t - 0.6) / 0.25
            color = color_mid * (1 - k) + color_bot * k
        else:
            color = color_bot

        # 水平纹理条纹——每隔几行画一条暗线（模拟草束层叠）
        stripe_y = y - top_y
        stripe_period = rng.integers(3, 7)
        if stripe_y % stripe_period < 2:
            color = color * 0.75  # 条纹暗线

        color = color + rng.uniform(-6, 6, 3)
        color = np.clip(color, 0, 255)
        img[y, :] = color.astype(np.uint8)

    # 参差底部——画草尖
    for i in range(len(bottom_points) - 1):
        x1, y1 = bottom_points[i]
        x2, y2 = bottom_points[i + 1]
        for y in range(int(min(y1, y2)), int(max(y1, y2)) + 2):
            if y < 0 or y >= h:
                continue
            tip_color = color_bot * 0.6 + rng.uniform(-8, 4, 3)
            tip_color = np.clip(tip_color, 0, 255)
            x_min = int(min(x1, x2))
            x_max = int(max(x1, x2)) + 1
            if x_min < 0: x_min = 0
            if x_max > w: x_max = w
            img[y, x_min:x_max] = tip_color.astype(np.uint8)

    # 层顶部阴影线（层间缝隙）
    shadow_h = max(3, int(layer_h * 0.1))
    for y in range(top_y, min(top_y + shadow_h, h)):
        if y < 0 or y >= h:
            continue
        t = (y - top_y) / shadow_h
        intensity = (1 - t) * 0.7
        gap_color = PALETTE['gap']
        orig = img[y, :].astype(np.float64)
        img[y, :] = np.clip(orig * (1 - intensity) + gap_color * intensity, 0, 255).astype(np.uint8)


def add_vertical_strands(img, rng, count=80):
    """
    添加少量垂直短线条作为草束细节（辅助，不是主体）
    """
    h, w = img.shape[:2]
    for _ in range(count):
        x = rng.integers(0, w)
        y = rng.integers(0, h - 30)
        length = rng.integers(15, 50)
        # 从当前位置向下画短线
        for dy in range(length):
            ny = y + dy
            if ny >= h:
                break
            # 轻微变暗
            orig = img[ny, x].astype(np.int16)
            img[ny, x] = np.clip(orig - rng.integers(5, 20), 0, 255).astype(np.uint8)


def generate_thatch_texture():
    ref_img = cv2.imread(REF_PATH, cv2.IMREAD_COLOR)
    if ref_img is None:
        print(f"[ERROR] 无法读取参考图: {REF_PATH}")
        return

    ref_resized = cv2.resize(ref_img, (TARGET_W, TARGET_H))
    ref_bgr_mean = np.mean(ref_resized, axis=(0, 1))

    img = np.full((TARGET_H, TARGET_W, 3), 15, dtype=np.uint8)  # 深色底色

    rng = np.random.default_rng(42)

    # ===== 从下往上分层绘制 =====
    num_layers = 7
    layer_height = TARGET_H / num_layers

    for layer_idx in range(num_layers - 1, -1, -1):
        top_y = int(layer_idx * layer_height)
        bot_y = int((layer_idx + 1) * layer_height)

        # 根据层位置选择颜色（顶部亮、底部暗）
        ty = float(top_y) / TARGET_H
        if ty < 0.2:
            # 顶部高光区
            color_top = PALETTE['dark']
            color_mid = PALETTE['highlight']
            color_bot = PALETTE['bright']
        elif ty < 0.5:
            # 中部主色区
            color_top = PALETTE['shadow']
            color_mid = PALETTE['bright']
            color_bot = PALETTE['main']
        else:
            # 底部暗区
            color_top = PALETTE['gap']
            color_mid = PALETTE['dark']
            color_bot = PALETTE['shadow'] * 0.7

        is_bottom = (layer_idx == num_layers - 1)
        draw_thatch_layer(img, top_y, bot_y, color_top, color_mid, color_bot, rng, is_bottom)

    # ===== 添加少量垂直草束细节 =====
    add_vertical_strands(img, rng, count=60)

    # ===== 颜色校准 =====
    gen_bgr_mean = np.mean(img, axis=(0, 1))
    for c in range(3):
        img[:, :, c] = np.clip(
            img[:, :, c].astype(np.float64) * (ref_bgr_mean[c] / (gen_bgr_mean[c] + 1e-10)),
            0, 255
        ).astype(np.uint8)

    # 区域颜色校准
    ref_top_mean = np.mean(ref_resized[:int(TARGET_H*0.35)], axis=(0, 1))
    ref_mid_mean = np.mean(ref_resized[int(TARGET_H*0.35):int(TARGET_H*0.65)], axis=(0, 1))
    ref_bot_mean = np.mean(ref_resized[int(TARGET_H*0.65):], axis=(0, 1))
    for y in range(TARGET_H):
        ty = float(y) / TARGET_H
        if ty < 0.35:
            gen_mean = np.mean(img[:int(TARGET_H*0.35)], axis=(0, 1))
            adj = ref_top_mean - gen_mean
        elif ty < 0.65:
            gen_mean = np.mean(img[int(TARGET_H*0.35):int(TARGET_H*0.65)], axis=(0, 1))
            adj = ref_mid_mean - gen_mean
        else:
            gen_mean = np.mean(img[int(TARGET_H*0.65):], axis=(0, 1))
            adj = ref_bot_mean - gen_mean
        for c in range(3):
            img[y, :, c] = np.clip(img[y, :, c].astype(np.int16) + adj[c], 0, 255).astype(np.uint8)

    cv2.imwrite(OUTPUT_PATH, img)
    print(f"[OK] 已生成方案I: {OUTPUT_PATH}")
    return img


if __name__ == "__main__":
    generate_thatch_texture()
