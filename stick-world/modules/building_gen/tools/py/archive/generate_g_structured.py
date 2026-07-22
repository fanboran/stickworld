"""
方案G：结构化稻草屋顶生成器
核心改进：
1. 粗纤维 + 高对比度，让每根稻草清晰可见
2. 模拟真实茅草编织结构（交叉编织层）
3. 明显的水平分层线
4. 底部垂挂的稻草束
"""

import cv2
import numpy as np
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BUILDING_GEN = os.path.normpath(os.path.join(SCRIPT_DIR, "..", ".."))
REF_DIR = os.path.join(BUILDING_GEN, "reference")

REF_PATH = os.path.join(REF_DIR, "thatch_ref.png")
OUTPUT_PATH = os.path.join(REF_DIR, "preview_thatch_G.png")

TARGET_W, TARGET_H = 512, 512


def draw_thick_strand(img, start_x, start_y, length, angle, width, color, alpha=1.0):
    """绘制一根粗稻草纤维"""
    h, w = img.shape[:2]
    for i in range(length):
        px = int(start_x + i * np.cos(angle))
        py = int(start_y + i * np.sin(angle))
        
        if px < 0 or px >= w or py < 0 or py >= h:
            continue
        
        for dx in range(-width, width + 1):
            for dy in range(-width // 2, width // 2 + 1):
                nx, ny = px + dx, py + dy
                if 0 <= nx < w and 0 <= ny < h:
                    dist = np.sqrt(dx * dx + dy * dy)
                    if dist <= width:
                        intensity = 1.0 - dist / width
                        for c in range(3):
                            img[ny, nx, c] = int(
                                img[ny, nx, c] * (1 - alpha * intensity) + 
                                color[c] * alpha * intensity
                            )


def generate_thatch_texture():
    ref_img = cv2.imread(REF_PATH, cv2.IMREAD_COLOR)
    if ref_img is None:
        print(f"[ERROR] 无法读取参考图: {REF_PATH}")
        return
    
    ref_resized = cv2.resize(ref_img, (TARGET_W, TARGET_H))
    
    ref_top_mean = np.mean(ref_resized[:int(TARGET_H*0.35)], axis=(0, 1))
    ref_mid_mean = np.mean(ref_resized[int(TARGET_H*0.35):int(TARGET_H*0.65)], axis=(0, 1))
    ref_bot_mean = np.mean(ref_resized[int(TARGET_H*0.65):], axis=(0, 1))
    
    img = np.zeros((TARGET_H, TARGET_W, 3), dtype=np.uint8)
    
    rng = np.random.default_rng(42)
    
    for y in range(TARGET_H):
        ty = float(y) / TARGET_H
        
        if ty < 0.35:
            color = ref_top_mean + rng.uniform(-5, 5, 3)
        elif ty < 0.65:
            color = ref_mid_mean + rng.uniform(-5, 5, 3)
        else:
            color = ref_bot_mean + rng.uniform(-5, 5, 3)
        
        color = np.clip(color, 0, 255).astype(np.uint8)
        img[y, :] = color
    
    # ===== 阶段1：绘制粗稻草纤维（核心视觉特征） =====
    num_strands = 400
    for i in range(num_strands):
        start_x = rng.integers(0, TARGET_W)
        start_y = rng.integers(0, TARGET_H)
        
        length = rng.integers(100, 250)
        angle = -np.pi / 2 + rng.uniform(-0.35, 0.35)
        
        width = rng.integers(2, 4)
        
        ty = float(start_y) / TARGET_H
        
        if ty < 0.35:
            base_color = ref_top_mean
        elif ty < 0.65:
            base_color = ref_mid_mean
        else:
            base_color = ref_bot_mean
        
        if rng.random() < 0.5:
            color_variation = rng.uniform(-40, -15, 3)
        else:
            color_variation = rng.uniform(5, 25, 3)
        color = np.clip(base_color + color_variation, 0, 255).astype(np.uint8)
        
        draw_thick_strand(img, start_x, start_y, length, angle, width, color, alpha=0.8)
    
    # ===== 阶段2：绘制倾斜编织层（模拟真实茅草交叉编织） =====
    num_layers = 8
    for layer_idx in range(num_layers):
        layer_y = int(TARGET_H * (0.1 + layer_idx * 0.11))
        layer_strands = 40
        
        for i in range(layer_strands):
            start_x = rng.integers(-50, TARGET_W + 50)
            start_y = layer_y + rng.integers(-20, 20)
            
            length = rng.integers(200, 400)
            if layer_idx % 2 == 0:
                angle = -np.pi / 3 + rng.uniform(-0.2, 0.2)
            else:
                angle = -2 * np.pi / 3 + rng.uniform(-0.2, 0.2)
            
            width = rng.integers(1, 3)
            
            ty = float(start_y) / TARGET_H
            if ty < 0.35:
                base_color = ref_top_mean
            elif ty < 0.65:
                base_color = ref_mid_mean
            else:
                base_color = ref_bot_mean
            
            color_variation = rng.uniform(-25, 15, 3)
            color = np.clip(base_color + color_variation, 0, 255).astype(np.uint8)
            
            draw_thick_strand(img, start_x, start_y, length, angle, width, color, alpha=0.3)
    
    # ===== 阶段3：绘制密集的细纤维（填充空隙） =====
    num_fine_strands = 1200
    for i in range(num_fine_strands):
        start_x = rng.integers(0, TARGET_W)
        start_y = rng.integers(0, TARGET_H)
        
        length = rng.integers(30, 100)
        angle = -np.pi / 2 + rng.uniform(-0.4, 0.4)
        width = 1
        
        ty = float(start_y) / TARGET_H
        if ty < 0.35:
            base_color = ref_top_mean
        elif ty < 0.65:
            base_color = ref_mid_mean
        else:
            base_color = ref_bot_mean
        
        color_variation = rng.uniform(-30, 10, 3)
        color = np.clip(base_color + color_variation, 0, 255).astype(np.uint8)
        
        draw_thick_strand(img, start_x, start_y, length, angle, width, color, alpha=0.4)
    
    # ===== 阶段4：添加水平分层线 =====
    for layer in range(5):
        layer_y = int(TARGET_H * (0.18 + layer * 0.16))
        
        for y in range(layer_y - 3, layer_y + 4):
            if y < 0 or y >= TARGET_H:
                continue
            
            ty = float(y) / TARGET_H
            if ty < 0.35:
                line_color = ref_top_mean - 40
            elif ty < 0.65:
                line_color = ref_mid_mean - 45
            else:
                line_color = ref_bot_mean - 30
            
            line_color = np.clip(line_color, 0, 255).astype(np.uint8)
            
            intensity = 1.0 - abs(y - layer_y) / 3.0
            intensity = max(0, intensity) * 0.4
            
            for x in range(TARGET_W):
                for c in range(3):
                    img[y, x, c] = int(
                        img[y, x, c] * (1 - intensity) + 
                        line_color[c] * intensity
                    )
    
    # ===== 阶段5：底部垂挂效果 =====
    for i in range(80):
        start_x = rng.integers(0, TARGET_W)
        start_y = int(TARGET_H * 0.6) + rng.integers(0, int(TARGET_H * 0.3))
        
        length = rng.integers(40, 120)
        angle = -np.pi / 2 + rng.uniform(-0.2, 0.2)
        width = rng.integers(2, 4)
        
        base_color = ref_bot_mean
        color_variation = rng.uniform(-20, 10, 3)
        color = np.clip(base_color + color_variation, 0, 255).astype(np.uint8)
        
        draw_thick_strand(img, start_x, start_y, length, angle, width, color, alpha=0.7)
    
    # ===== 阶段6：添加明暗噪点增加真实感 =====
    noise = rng.uniform(-8, 8, (TARGET_H, TARGET_W, 3)).astype(np.int16)
    img = np.clip(img.astype(np.int16) + noise, 0, 255).astype(np.uint8)
    
    # ===== 阶段7：颜色校准 =====
    gen_bgr_mean = np.mean(img, axis=(0, 1))
    ref_bgr_mean = np.mean(ref_resized, axis=(0, 1))
    for c in range(3):
        img[:, :, c] = np.clip(
            img[:, :, c].astype(np.float64) * (ref_bgr_mean[c] / (gen_bgr_mean[c] + 1e-10)), 
            0, 255
        ).astype(np.uint8)
    
    # ===== 阶段8：区域颜色微调 =====
    for y in range(TARGET_H):
        ty = float(y) / TARGET_H
        
        if ty < 0.35:
            img[y, :, 0] = np.clip(img[y, :, 0].astype(np.int16) - 4, 0, 255).astype(np.uint8)
            img[y, :, 1] = np.clip(img[y, :, 1].astype(np.int16) - 8, 0, 255).astype(np.uint8)
            img[y, :, 2] = np.clip(img[y, :, 2].astype(np.int16) - 12, 0, 255).astype(np.uint8)
        elif ty < 0.65:
            img[y, :, 0] = np.clip(img[y, :, 0].astype(np.int16) + 10, 0, 255).astype(np.uint8)
            img[y, :, 1] = np.clip(img[y, :, 1].astype(np.int16) + 17, 0, 255).astype(np.uint8)
            img[y, :, 2] = np.clip(img[y, :, 2].astype(np.int16) + 24, 0, 255).astype(np.uint8)
        else:
            img[y, :, 0] = np.clip(img[y, :, 0].astype(np.int16) - 3, 0, 255).astype(np.uint8)
            img[y, :, 1] = np.clip(img[y, :, 1].astype(np.int16) - 5, 0, 255).astype(np.uint8)
            img[y, :, 2] = np.clip(img[y, :, 2].astype(np.int16) - 7, 0, 255).astype(np.uint8)
    
    cv2.imwrite(OUTPUT_PATH, img)
    print(f"[OK] 已生成方案G: {OUTPUT_PATH}")
    
    return img


if __name__ == "__main__":
    generate_thatch_texture()
