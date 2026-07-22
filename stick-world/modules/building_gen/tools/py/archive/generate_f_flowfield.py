import cv2
import numpy as np
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REF_DIR = os.path.normpath(os.path.join(SCRIPT_DIR, "../../reference"))
REF_PATH = os.path.join(REF_DIR, "thatch_ref.png").replace("\\", "/")
OUTPUT_PATH = os.path.join(REF_DIR, "preview_thatch_F.png").replace("\\", "/")
TARGET_W = 512
TARGET_H = 512


def lerp(a, b, t):
    return a + (b - a) * t


def clamp(value, min_val, max_val):
    return max(min_val, min(max_val, value))


def draw_straw_strand(img, start_x, start_y, length, angle, width, color, alpha=0.8):
    h, w = img.shape[:2]
    
    for i in range(length):
        px = int(start_x + i * np.cos(angle))
        py = int(start_y + i * np.sin(angle))
        
        if px < 0 or px >= w or py < 0 or py >= h:
            break
        
        for dw in range(-width, width + 1):
            pw = py + dw
            if pw < 0 or pw >= h:
                continue
            
            dist = abs(dw) / width if width > 0 else 0
            local_alpha = alpha * (1 - dist * 0.6)
            
            for c in range(3):
                img[pw, px, c] = int(img[pw, px, c] * (1 - local_alpha) + color[c] * local_alpha)


def generate_straw_texture():
    ref_img = cv2.imread(REF_PATH, cv2.IMREAD_COLOR)
    if ref_img is None:
        print(f"[ERROR] 无法读取参考图: {REF_PATH}")
        return
    
    ref_resized = cv2.resize(ref_img, (TARGET_W, TARGET_H))
    
    ref_bgr_mean = np.mean(ref_resized, axis=(0, 1))
    ref_top_mean = np.mean(ref_resized[:int(TARGET_H*0.35)], axis=(0, 1))
    ref_mid_mean = np.mean(ref_resized[int(TARGET_H*0.35):int(TARGET_H*0.65)], axis=(0, 1))
    ref_bot_mean = np.mean(ref_resized[int(TARGET_H*0.65):], axis=(0, 1))
    
    img = np.zeros((TARGET_H, TARGET_W, 3), dtype=np.uint8)
    
    rng = np.random.default_rng(42)
    
    for y in range(TARGET_H):
        ty = float(y) / TARGET_H
        
        if ty < 0.35:
            color = ref_top_mean + rng.uniform(-8, 8, 3)
        elif ty < 0.65:
            color = ref_mid_mean + rng.uniform(-8, 8, 3)
        else:
            color = ref_bot_mean + rng.uniform(-8, 8, 3)
        
        color = np.clip(color, 0, 255).astype(np.uint8)
        img[y, :] = color
    
    noise = rng.uniform(-15, 15, (TARGET_H, TARGET_W, 3)).astype(np.int16)
    img = np.clip(img.astype(np.int16) + noise, 0, 255).astype(np.uint8)
    
    num_strands = 800
    
    for i in range(num_strands):
        start_x = rng.integers(0, TARGET_W)
        start_y = rng.integers(0, TARGET_H)
        
        length = rng.integers(80, 200)
        angle = -np.pi / 2 + rng.uniform(-0.25, 0.25)
        
        width = rng.integers(1, 2)
        
        ty = float(start_y) / TARGET_H
        
        if ty < 0.35:
            base_color = ref_top_mean
        elif ty < 0.65:
            base_color = ref_mid_mean
        else:
            base_color = ref_bot_mean
        
        if rng.random() < 0.6:
            color_variation = rng.uniform(-35, -8, 3)
        else:
            color_variation = rng.uniform(5, 30, 3)
        color = np.clip(base_color + color_variation, 0, 255).astype(np.uint8)
        
        draw_straw_strand(img, start_x, start_y, length, angle, width, color, alpha=0.7)
    
    num_bundles = 60
    
    for i in range(num_bundles):
        center_x = rng.integers(0, TARGET_W)
        center_y = rng.integers(0, TARGET_H)
        bundle_size = rng.integers(10, 25)
        strand_count = rng.integers(8, 20)
        
        ty = float(center_y) / TARGET_H
        
        if ty < 0.35:
            base_color = ref_top_mean
        elif ty < 0.65:
            base_color = ref_mid_mean
        else:
            base_color = ref_bot_mean
        
        for j in range(strand_count):
            offset_x = rng.integers(-bundle_size, bundle_size)
            offset_y = rng.integers(-bundle_size, bundle_size)
            start_x = clamp(center_x + offset_x, 0, TARGET_W - 1)
            start_y = clamp(center_y + offset_y, 0, TARGET_H - 1)
            
            length = rng.integers(60, 200)
            angle = -np.pi / 2 + rng.uniform(-0.15, 0.15)
            width = rng.integers(1, 2)
            
            color_variation = rng.uniform(-15, 15, 3)
            color = np.clip(base_color + color_variation, 0, 255).astype(np.uint8)
            
            draw_straw_strand(img, start_x, start_y, length, angle, width, color, alpha=0.25)
    
    for layer in range(6):
        layer_y = int(TARGET_H * (0.15 + layer * 0.14))
        layer_thickness = rng.integers(5, 12)
        
        for y in range(layer_y - layer_thickness, layer_y + layer_thickness):
            if y < 0 or y >= TARGET_H:
                continue
            
            intensity = 1.0 - abs(y - layer_y) / layer_thickness
            intensity *= 0.15
            
            for x in range(TARGET_W):
                ty = float(y) / TARGET_H
                if ty < 0.35:
                    line_color = ref_top_mean - 30
                elif ty < 0.65:
                    line_color = ref_mid_mean - 35
                else:
                    line_color = ref_bot_mean - 40
                
                line_color = np.clip(line_color, 0, 255).astype(np.uint8)
                
                for c in range(3):
                    img[y, x, c] = int(img[y, x, c] * (1 - intensity) + line_color[c] * intensity)
    
    img = cv2.GaussianBlur(img, (1, 1), 0)
    
    noise2 = rng.uniform(-5, 5, (TARGET_H, TARGET_W, 3)).astype(np.int16)
    img = np.clip(img.astype(np.int16) + noise2, 0, 255).astype(np.uint8)
    
    gen_bgr_mean = np.mean(img, axis=(0, 1))
    for c in range(3):
        img[:, :, c] = np.clip(img[:, :, c].astype(np.float64) * (ref_bgr_mean[c] / (gen_bgr_mean[c] + 1e-10)), 0, 255).astype(np.uint8)
    
    for y in range(TARGET_H):
        ty = float(y) / TARGET_H
        
        if ty < 0.35:
            img[y, :, 0] = np.clip(img[y, :, 0].astype(np.int16) - 3, 0, 255).astype(np.uint8)
            img[y, :, 1] = np.clip(img[y, :, 1].astype(np.int16) - 5, 0, 255).astype(np.uint8)
            img[y, :, 2] = np.clip(img[y, :, 2].astype(np.int16) - 7, 0, 255).astype(np.uint8)
        elif ty < 0.65:
            img[y, :, 0] = np.clip(img[y, :, 0].astype(np.int16) + 6, 0, 255).astype(np.uint8)
            img[y, :, 1] = np.clip(img[y, :, 1].astype(np.int16) + 11, 0, 255).astype(np.uint8)
            img[y, :, 2] = np.clip(img[y, :, 2].astype(np.int16) + 15, 0, 255).astype(np.uint8)
        else:
            img[y, :, 0] = np.clip(img[y, :, 0].astype(np.int16) - 1, 0, 255).astype(np.uint8)
            img[y, :, 1] = np.clip(img[y, :, 1].astype(np.int16) - 2, 0, 255).astype(np.uint8)
            img[y, :, 2] = np.clip(img[y, :, 2].astype(np.int16) - 4, 0, 255).astype(np.uint8)
    
    cv2.imwrite(OUTPUT_PATH, img)
    print(f"[OK] 已生成方案F: {OUTPUT_PATH}")
    
    return img


def main():
    print("方案F：流场引导的稻草纹理生成...")
    generate_straw_texture()


if __name__ == "__main__":
    main()
