import cv2
import numpy as np
import os
import random

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REF_DIR = os.path.normpath(os.path.join(SCRIPT_DIR, "../../reference"))
REF_PATH = os.path.join(REF_DIR, "thatch_ref.png").replace("\\", "/")
OUTPUT_PATH = os.path.join(REF_DIR, "preview_thatch_E.png").replace("\\", "/")
TARGET_W = 512
TARGET_H = 512


def create_comparison_image():
    """生成生成图vs参考图的并排对比图"""
    ref_img = cv2.imread(REF_PATH, cv2.IMREAD_COLOR)
    gen_img = cv2.imread(os.path.join(REF_DIR, "preview_thatch.png"), cv2.IMREAD_COLOR)
    
    if ref_img is None or gen_img is None:
        print("[ERROR] 无法读取图片")
        return
    
    gen_resized = cv2.resize(gen_img, (ref_img.shape[1], ref_img.shape[0]))
    
    combined = np.hstack([ref_img, gen_resized])
    
    cv2.imwrite(os.path.join(REF_DIR, "comparison.png"), combined)
    print("[OK] 已生成对比图")


def add_directional_noise(img, w, h):
    """添加方向性噪声——模拟茅草纤维方向"""
    rng = np.random.default_rng(42)
    
    noise = rng.uniform(0, 1, (h, w))
    noise = cv2.GaussianBlur(noise, (5, 5), 0)
    
    kernel = np.array([[-1, -2, -1], [0, 0, 0], [1, 2, 1]], dtype=np.float64)
    vertical_grad = cv2.filter2D(noise, -1, kernel)
    
    vertical_grad = (vertical_grad - vertical_grad.min()) / (vertical_grad.max() - vertical_grad.min())
    
    noise_img = (vertical_grad * 75).astype(np.uint8)
    
    result = np.zeros_like(img)
    for c in range(3):
        result[:, :, c] = np.clip(img[:, :, c].astype(np.int16) + noise_img, 0, 255).astype(np.uint8)
    
    noise2 = rng.uniform(-18, 18, (h, w)).astype(np.int16)
    for c in range(3):
        result[:, :, c] = np.clip(result[:, :, c].astype(np.int16) + noise2, 0, 255).astype(np.uint8)
    
    noise3 = rng.uniform(0, 1, (h, w))
    noise3 = cv2.GaussianBlur(noise3, (3, 3), 0)
    noise3_img = ((noise3 - 0.5) * 30).astype(np.int16)
    for c in range(3):
        result[:, :, c] = np.clip(result[:, :, c].astype(np.int16) + noise3_img, 0, 255).astype(np.uint8)
    
    for _ in range(150):
        px = rng.integers(0, w)
        py = rng.integers(0, h)
        size = rng.integers(1, 3)
        for dx in range(-size, size + 1):
            for dy in range(-size, size + 1):
                nx, ny = px + dx, py + dy
                if 0 <= nx < w and 0 <= ny < h:
                    dist = np.sqrt(dx*dx + dy*dy)
                    if dist <= size:
                        val = int(30 * (1 - dist/size))
                        result[ny, nx] = np.clip(result[ny, nx].astype(np.int16) - val, 0, 255).astype(np.uint8)
    
    noise4 = rng.uniform(0, 1, (h, w))
    high_freq = noise4 - cv2.GaussianBlur(noise4, (7, 7), 0)
    high_freq = (high_freq - high_freq.min()) / (high_freq.max() - high_freq.min())
    high_freq_img = ((high_freq - 0.5) * 50).astype(np.int16)
    for c in range(3):
        result[:, :, c] = np.clip(result[:, :, c].astype(np.int16) + high_freq_img, 0, 255).astype(np.uint8)
    
    for _ in range(25):
        fy = rng.integers(0, h - 10)
        fx = rng.integers(0, w - 60)
        length = rng.integers(40, 150)
        angle = rng.uniform(-0.25, 0.25)
        width = rng.integers(1, 2)
        for i in range(length):
            px = int(fx + i * np.cos(angle))
            py = int(fy + i * np.sin(angle))
            if 0 <= px < w and 0 <= py < h:
                for dw in range(-width, width + 1):
                    pw = py + dw
                    if 0 <= pw < h:
                        result[pw, px] = np.clip(result[pw, px].astype(np.int16) - (20 - abs(dw) * 8), 0, 255).astype(np.uint8)
    
    for _ in range(20):
        fy = rng.integers(0, h)
        fx = rng.integers(0, w)
        length = rng.integers(20, 80)
        angle = rng.uniform(-0.3, 0.3)
        for i in range(length):
            px = int(fx + i * np.cos(angle))
            py = int(fy + i * np.sin(angle))
            if 0 <= px < w and 0 <= py < h:
                val = rng.integers(5, 15)
                result[py, px] = np.clip(result[py, px].astype(np.int16) - val, 0, 255).astype(np.uint8)
    
    return result


def apply_color_mapping(img, ref_img):
    """应用颜色映射——灰度比例映射+区域微调"""
    h, w = img.shape[:2]
    ref_resized = cv2.resize(ref_img, (w, h))
    
    img_gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY).astype(np.float64)
    ref_gray = cv2.cvtColor(ref_resized, cv2.COLOR_BGR2GRAY).astype(np.float64)
    
    mask = img_gray > 5
    img_gray[img_gray < 1] = 1
    
    ratio = np.where(mask, ref_gray / img_gray, 1.0)
    
    result = np.zeros_like(img)
    for c in range(3):
        result[:, :, c] = np.clip(img[:, :, c].astype(np.float64) * ratio, 0, 255).astype(np.uint8)
    
    for y in range(h):
        ty = float(y) / float(h)
        
        if ty < 0.35:
            result[y, :, 0] = np.clip(result[y, :, 0].astype(np.int16) - 17, 0, 255).astype(np.uint8)
            result[y, :, 1] = np.clip(result[y, :, 1].astype(np.int16) + 2, 0, 255).astype(np.uint8)
            result[y, :, 2] = np.clip(result[y, :, 2].astype(np.int16) + 8, 0, 255).astype(np.uint8)
        elif ty < 0.65:
            result[y, :, 0] = np.clip(result[y, :, 0].astype(np.int16) - 26, 0, 255).astype(np.uint8)
            result[y, :, 1] = np.clip(result[y, :, 1].astype(np.int16) - 2, 0, 255).astype(np.uint8)
            result[y, :, 2] = np.clip(result[y, :, 2].astype(np.int16) + 16, 0, 255).astype(np.uint8)
        else:
            result[y, :, 0] = np.clip(result[y, :, 0].astype(np.int16) - 31, 0, 255).astype(np.uint8)
            result[y, :, 1] = np.clip(result[y, :, 1].astype(np.int16) - 7, 0, 255).astype(np.uint8)
            result[y, :, 2] = np.clip(result[y, :, 2].astype(np.int16) + 12, 0, 255).astype(np.uint8)
    
    ref_gray = cv2.cvtColor(ref_resized, cv2.COLOR_BGR2GRAY)
    ref_sobel_x = cv2.Sobel(ref_gray, cv2.CV_64F, 1, 0, ksize=3)
    ref_sobel_y = cv2.Sobel(ref_gray, cv2.CV_64F, 0, 1, ksize=3)
    ref_edges = np.sqrt(ref_sobel_x**2 + ref_sobel_y**2)
    ref_edges = (ref_edges - ref_edges.min()) / (ref_edges.max() - ref_edges.min())
    
    img_gray = cv2.cvtColor(result, cv2.COLOR_BGR2GRAY)
    img_sobel_x = cv2.Sobel(img_gray, cv2.CV_64F, 1, 0, ksize=3)
    img_sobel_y = cv2.Sobel(img_gray, cv2.CV_64F, 0, 1, ksize=3)
    img_edges = np.sqrt(img_sobel_x**2 + img_sobel_y**2)
    img_edges = (img_edges - img_edges.min()) / (img_edges.max() - img_edges.min())
    
    edge_diff = ref_edges - img_edges
    edge_diff = np.clip(edge_diff, 0, 1)
    
    enhance_factor = 0.7
    for c in range(3):
        result[:, :, c] = np.clip(
            result[:, :, c].astype(np.float64) * (1 - edge_diff * enhance_factor) +
            ref_resized[:, :, c].astype(np.float64) * edge_diff * enhance_factor,
            0, 255
        ).astype(np.uint8)
    
    return result


def generate_quilted_texture():
    """方案E：Patch-based texture quilting（改进版）"""
    ref_img = cv2.imread(REF_PATH, cv2.IMREAD_COLOR)
    if ref_img is None:
        print(f"[ERROR] 无法读取参考图: {REF_PATH}")
        return
    
    ref_h, ref_w = ref_img.shape[:2]
    
    patch_size = 48
    overlap = 12
    
    result = np.zeros((TARGET_H, TARGET_W, 3), dtype=np.uint8)
    weights = np.zeros((TARGET_H, TARGET_W), dtype=np.float64)
    
    rng = np.random.default_rng(42)
    
    for y in range(0, TARGET_H, patch_size - overlap):
        for x in range(0, TARGET_W, patch_size - overlap):
            py = min(y, TARGET_H - patch_size)
            px = min(x, TARGET_W - patch_size)
            
            ref_y = rng.integers(0, ref_h - patch_size)
            ref_x = rng.integers(0, ref_w - patch_size)
            
            patch = ref_img[ref_y:ref_y+patch_size, ref_x:ref_x+patch_size].copy()
            
            mask = np.ones((patch_size, patch_size), dtype=np.float64)
            
            if py > 0:
                ramp = np.linspace(0, 1, overlap)
                mask[:overlap, :] = ramp[:, np.newaxis]
            if px > 0:
                ramp = np.linspace(0, 1, overlap)
                mask[:, :overlap] = ramp[np.newaxis, :]
            
            result[py:py+patch_size, px:px+patch_size] = (
                result[py:py+patch_size, px:px+patch_size].astype(np.float64) * (1 - mask[:, :, np.newaxis]) +
                patch.astype(np.float64) * mask[:, :, np.newaxis]
            ).astype(np.uint8)
            
            weights[py:py+patch_size, px:px+patch_size] += mask
    
    h, w = result.shape[:2]
    result = add_directional_noise(result, w, h)
    
    result = apply_color_mapping(result, ref_img)
    
    cv2.imwrite(OUTPUT_PATH, result)
    print(f"[OK] 已生成方案E: {OUTPUT_PATH}")
    
    return result


def main():
    print("方案E：Patch-based texture quilting（改进版）...")
    
    create_comparison_image()
    
    generate_quilted_texture()


if __name__ == "__main__":
    main()
