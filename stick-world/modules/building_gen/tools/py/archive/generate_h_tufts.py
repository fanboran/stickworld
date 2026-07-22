"""
方案H：草束形状生成法
核心改进：画"一绺一绺的草束"，不是细线条或噪波

真实茅草屋的视觉特征：
1. 一绺一绺的草束，每束有明显的形状轮廓
2. 从上往下铺，每层草束从房梁向下垂挂
3. 底部参差不齐（草尖长短不一）
4. 层层叠加，上层覆盖下层根部
5. 草束内部有方向性纤维
"""

import cv2
import numpy as np
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BUILDING_GEN = os.path.normpath(os.path.join(SCRIPT_DIR, "..", ".."))
REF_DIR = os.path.join(BUILDING_GEN, "reference")

REF_PATH = os.path.join(REF_DIR, "thatch_ref.png")
OUTPUT_PATH = os.path.join(REF_DIR, "preview_thatch_H.png")

TARGET_W, TARGET_H = 512, 512


def draw_tuft(img, root_x, root_y, length, base_width, color, alpha=1.0, rng=None):
    """
    画一绺草束——水滴形/扫帚形区域
    root_x, root_y: 草束根部位置（顶部）
    length: 草束长度
    base_width: 草束根部宽度
    color: 草束颜色 (BGR)
    alpha: 混合透明度
    """
    h, w = img.shape[:2]
    
    # 草束底部参差不齐——每个草尖长度不同
    num_strands = max(5, int(base_width * 1.5))
    strand_offsets = np.linspace(-base_width/2, base_width/2, num_strands)
    
    for s_idx, offset in enumerate(strand_offsets):
        # 每根草尖的长度变化（参差效果）
        if rng is not None:
            strand_len = length * (0.6 + rng.uniform(0, 0.4))
            strand_w = 1 + (rng.integers(0, 2) if rng else 1)
        else:
            strand_len = length * 0.8
            strand_w = 2
        
        # 草尖位置（从根部向下垂挂，稍微散开）
        tip_x = root_x + offset * 1.5  # 底部更宽
        tip_y = root_y + strand_len
        
        # 沿草尖方向画线
        steps = max(3, int(strand_len))
        for i in range(steps + 1):
            t = float(i) / steps
            px = int(root_x + offset * (1.0 - t * 0.3) + (tip_x - root_x - offset * 0.7) * t)
            py = int(root_y + (tip_y - root_y) * t)
            
            # 宽度：根部粗、尖部细
            sw = max(1, int(strand_w * (1.0 - t * 0.7)))
            
            # 颜色：根部暗、中部亮、尖部暗
            if t < 0.2:
                shade = 0.7 + t * 1.5  # 0.7→1.0
            elif t < 0.6:
                shade = 1.0 + (1.0 - abs(t - 0.4) / 0.2) * 0.15  # 中部高光
            else:
                shade = 1.0 - (t - 0.6) * 0.8  # 尖部变暗
            
            strand_color = np.clip(color * shade, 0, 255).astype(np.uint8)
            
            for dx in range(-sw, sw + 1):
                for dy in range(-sw, sw + 1):
                    nx, ny = px + dx, py + dy
                    if 0 <= nx < w and 0 <= ny < h:
                        dist = np.sqrt(dx*dx + dy*dy)
                        if dist <= sw:
                            fi = 1.0 - dist / max(sw, 1)
                            for c in range(3):
                                img[ny, nx, c] = int(
                                    img[ny, nx, c] * (1 - alpha * fi) +
                                    strand_color[c] * alpha * fi
                                )


def draw_tuft_edge(img, root_x, root_y, length, base_width, edge_color, alpha=0.5, rng=None):
    """画草束的暗色轮廓边缘，增强形状感"""
    h, w = img.shape[:2]
    
    # 左边缘和右边缘
    for side in [-1, 1]:
        steps = max(3, int(length))
        for i in range(steps + 1):
            t = float(i) / steps
            # 边缘从根部到尖部，向外扩展
            offset_x = side * base_width/2 * (0.5 + t * 0.5)
            px = int(root_x + offset_x)
            py = int(root_y + t * length)
            
            if 0 <= px < w and 0 <= py < h:
                for dx in range(-1, 2):
                    for dy in range(-1, 2):
                        nx, ny = px + dx, py + dy
                        if 0 <= nx < w and 0 <= ny < h:
                            dist = np.sqrt(dx*dx + dy*dy)
                            if dist <= 1.5:
                                fi = (1.0 - dist/1.5) * alpha
                                for c in range(3):
                                    img[ny, nx, c] = int(
                                        img[ny, nx, c] * (1 - fi) +
                                        edge_color[c] * fi
                                    )


def generate_thatch_texture():
    ref_img = cv2.imread(REF_PATH, cv2.IMREAD_COLOR)
    if ref_img is None:
        print(f"[ERROR] 无法读取参考图: {REF_PATH}")
        return
    
    ref_resized = cv2.resize(ref_img, (TARGET_W, TARGET_H))
    
    # 参考图区域颜色
    ref_top_mean = np.mean(ref_resized[:int(TARGET_H*0.35)], axis=(0, 1))
    ref_mid_mean = np.mean(ref_resized[int(TARGET_H*0.35):int(TARGET_H*0.65)], axis=(0, 1))
    ref_bot_mean = np.mean(ref_resized[int(TARGET_H*0.65):], axis=(0, 1))
    ref_bgr_mean = np.mean(ref_resized, axis=(0, 1))
    
    # 深色底色（层间缝隙）
    img = np.full((TARGET_H, TARGET_W, 3), 30, dtype=np.uint8)
    
    rng = np.random.default_rng(42)
    
    # ===== 从下往上分层绘制草束 =====
    num_layers = 7
    layer_height = TARGET_H / num_layers
    
    for layer_idx in range(num_layers - 1, -1, -1):
        # 当前层的 Y 位置（顶部=根部位置）
        layer_y = int(layer_idx * layer_height)
        
        # 当前层的颜色
        ty = float(layer_y) / TARGET_H
        if ty < 0.35:
            base_color = ref_top_mean
            edge_color = ref_top_mean * 0.5
        elif ty < 0.65:
            base_color = ref_mid_mean
            edge_color = ref_mid_mean * 0.5
        else:
            base_color = ref_bot_mean
            edge_color = ref_bot_mean * 0.5
        
        edge_color = np.clip(edge_color, 0, 255).astype(np.uint8)
        
        # 草束长度：越往下层越长（垂挂效果）
        if layer_idx == num_layers - 1:
            tuft_length = layer_height * 1.8  # 最底层最长
        else:
            tuft_length = layer_height * 1.5
        
        # 在这一层水平排列草束
        tuft_spacing = rng.uniform(12, 25)
        x_pos = -20.0
        while x_pos < TARGET_W + 20:
            root_x = x_pos + rng.uniform(-3, 3)
            root_y = layer_y + rng.uniform(-5, 5)
            
            length = tuft_length * rng.uniform(0.7, 1.1)
            base_width = rng.uniform(8, 18)
            
            # 草束颜色变化
            color_var = rng.uniform(-25, 15, 3)
            tuft_color = np.clip(base_color + color_var, 0, 255).astype(np.uint8)
            
            # 画草束
            draw_tuft(img, root_x, root_y, length, base_width, tuft_color, alpha=0.9, rng=rng)
            
            # 画草束边缘轮廓
            edge_alpha = rng.uniform(0.3, 0.5)
            draw_tuft_edge(img, root_x, root_y, length, base_width, edge_color, alpha=edge_alpha, rng=rng)
            
            x_pos += tuft_spacing * rng.uniform(0.7, 1.3)
    
    # ===== 底部垂挂效果：额外的长草束 =====
    for i in range(40):
        root_x = rng.uniform(0, TARGET_W)
        root_y = TARGET_H * 0.55 + rng.uniform(0, TARGET_H * 0.3)
        
        length = rng.uniform(60, 150)
        base_width = rng.uniform(5, 12)
        
        tuft_color = np.clip(ref_bot_mean + rng.uniform(-20, 10, 3), 0, 255).astype(np.uint8)
        edge_color = np.clip(ref_bot_mean * 0.4, 0, 255).astype(np.uint8)
        
        draw_tuft(img, root_x, root_y, length, base_width, tuft_color, alpha=0.8, rng=rng)
        draw_tuft_edge(img, root_x, root_y, length, base_width, edge_color, alpha=0.4, rng=rng)
    
    # ===== 顶部最亮层：增加高光草束 =====
    for i in range(30):
        root_x = rng.uniform(0, TARGET_W)
        root_y = rng.uniform(0, TARGET_H * 0.15)
        
        length = rng.uniform(40, 80)
        base_width = rng.uniform(6, 12)
        
        tuft_color = np.clip(ref_top_mean + rng.uniform(10, 30, 3), 0, 255).astype(np.uint8)
        draw_tuft(img, root_x, root_y, length, base_width, tuft_color, alpha=0.6, rng=rng)
    
    # ===== 颜色校准 =====
    gen_bgr_mean = np.mean(img, axis=(0, 1))
    for c in range(3):
        img[:, :, c] = np.clip(
            img[:, :, c].astype(np.float64) * (ref_bgr_mean[c] / (gen_bgr_mean[c] + 1e-10)),
            0, 255
        ).astype(np.uint8)
    
    # 区域颜色微调
    for y in range(TARGET_H):
        ty = float(y) / TARGET_H
        if ty < 0.35:
            adj = np.array([-3, -5, -8])
        elif ty < 0.65:
            adj = np.array([6, 11, 15])
        else:
            adj = np.array([-1, -2, -4])
        for c in range(3):
            img[y, :, c] = np.clip(img[y, :, c].astype(np.int16) + adj[c], 0, 255).astype(np.uint8)
    
    cv2.imwrite(OUTPUT_PATH, img)
    print(f"[OK] 已生成方案H: {OUTPUT_PATH}")
    return img


if __name__ == "__main__":
    generate_thatch_texture()
