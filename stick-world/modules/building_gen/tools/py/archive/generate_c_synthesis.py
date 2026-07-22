"""
方案C：基于直方图匹配和纹理合成的方法。

从参考图中提取纹理基元，通过直方图匹配和块匹配算法重组生成新纹理。
"""
import cv2
import numpy as np
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BUILDING_GEN = os.path.normpath(os.path.join(SCRIPT_DIR, "..", ".."))
REF_DIR = os.path.join(BUILDING_GEN, "reference")
REF_PATH = os.path.join(REF_DIR, "thatch_ref.png")
OUTPUT_PATH = os.path.join(REF_DIR, "preview_thatch_C.png")

TARGET_W = 512
TARGET_H = 512


def histogram_matching(source, template):
    """直方图匹配——将源图像的直方图调整为目标图像的直方图"""
    src_hist = cv2.calcHist([source], [0, 1, 2], None, [8, 8, 8], [0, 256, 0, 256, 0, 256])
    tpl_hist = cv2.calcHist([template], [0, 1, 2], None, [8, 8, 8], [0, 256, 0, 256, 0, 256])
    
    src_hist = src_hist / src_hist.sum()
    tpl_hist = tpl_hist / tpl_hist.sum()
    
    src_cdf = np.cumsum(src_hist.flatten())
    tpl_cdf = np.cumsum(tpl_hist.flatten())
    
    mapping = np.zeros(512, dtype=np.uint8)
    j = 0
    for i in range(512):
        while j < 511 and tpl_cdf[j] < src_cdf[i]:
            j += 1
        mapping[i] = j
    
    result = np.zeros_like(source)
    for y in range(source.shape[0]):
        for x in range(source.shape[1]):
            idx = source[y, x, 0] // 32 * 64 + source[y, x, 1] // 32 * 8 + source[y, x, 2] // 32
            new_idx = mapping[idx]
            result[y, x, 0] = (new_idx // 64) * 32 + 16
            result[y, x, 1] = ((new_idx // 8) % 8) * 32 + 16
            result[y, x, 2] = (new_idx % 8) * 32 + 16
    
    return result


def extract_texture_blocks(ref_img, block_size=32):
    """从参考图中提取纹理块"""
    h, w = ref_img.shape[:2]
    blocks = []
    
    for by in range(0, h - block_size, block_size // 2):
        for bx in range(0, w - block_size, block_size // 2):
            block = ref_img[by:by+block_size, bx:bx+block_size]
            blocks.append(block)
    
    return blocks


def find_best_block(blocks, target_block, metric='mse'):
    """找到最匹配的纹理块"""
    best_score = float('inf')
    best_block = None
    
    target_h, target_w = target_block.shape[:2]
    
    for block in blocks:
        block_h, block_w = block.shape[:2]
        if block_h < target_h or block_w < target_w:
            continue
        
        crop_block = block[:target_h, :target_w]
        
        if metric == 'mse':
            score = np.mean((crop_block.astype(np.float64) - target_block.astype(np.float64)) ** 2)
        else:
            score = -np.sum(crop_block * target_block)
        
        if score < best_score:
            best_score = score
            best_block = crop_block
    
    return best_block if best_block is not None else blocks[0][:target_h, :target_w]


def generate_synthesis(ref_img, w, h):
    """基于纹理合成生成茅草纹理"""
    block_size = 32
    overlap = 8
    
    blocks = extract_texture_blocks(ref_img, block_size)
    if not blocks:
        print("[WARN] 未提取到纹理块")
        return np.zeros((h, w, 3), dtype=np.uint8)
    
    result = np.zeros((h, w, 3), dtype=np.uint8)
    
    for by in range(0, h, block_size - overlap):
        for bx in range(0, w, block_size - overlap):
            block_h = min(block_size, h - by)
            block_w = min(block_size, w - bx)
            
            if by == 0 and bx == 0:
                idx = np.random.randint(0, len(blocks))
                result[by:by+block_h, bx:bx+block_w] = blocks[idx][:block_h, :block_w]
            else:
                target_region = result[by:by+block_h, bx:bx+block_w]
                best_block = find_best_block(blocks, target_region)
                result[by:by+block_h, bx:bx+block_w] = best_block[:block_h, :block_w]
    
    return result


def add_color_variation(img, ref_img):
    """添加颜色变化——从参考图提取颜色分布"""
    ref_colors = ref_img.reshape(-1, 3)
    ref_colors = ref_colors[np.sum(ref_colors, axis=1) > 0]
    
    rng = np.random.default_rng(42)
    
    h, w = img.shape[:2]
    for y in range(h):
        for x in range(w):
            if rng.random() < 0.3:
                color_idx = rng.integers(0, len(ref_colors))
                img[y, x] = ref_colors[color_idx]
    
    return img


def match_histograms_channel(img, ref_img):
    """单通道直方图匹配"""
    for ch in range(3):
        src_hist, _ = np.histogram(img[:, :, ch], bins=256, range=(0, 256))
        ref_hist, _ = np.histogram(ref_img[:, :, ch], bins=256, range=(0, 256))
        
        src_cdf = np.cumsum(src_hist) / src_hist.sum()
        ref_cdf = np.cumsum(ref_hist) / ref_hist.sum()
        
        mapping = np.zeros(256, dtype=np.uint8)
        j = 0
        for i in range(256):
            while j < 255 and ref_cdf[j] < src_cdf[i]:
                j += 1
            mapping[i] = j
        
        img[:, :, ch] = mapping[img[:, :, ch]]
    
    return img


def create_seamless_pattern(ref_img, w, h):
    """创建无缝平铺图案"""
    ref_h, ref_w = ref_img.shape[:2]
    
    result = np.zeros((h, w, 3), dtype=np.uint8)
    
    for y in range(h):
        for x in range(w):
            ref_y = y % ref_h
            ref_x = x % ref_w
            result[y, x] = ref_img[ref_y, ref_x]
    
    return result


def main():
    print("方案C：基于直方图匹配和纹理合成生成茅草纹理...")
    
    ref_img = cv2.imread(REF_PATH, cv2.IMREAD_COLOR)
    if ref_img is None:
        print(f"[ERROR] 无法读取参考图: {REF_PATH}")
        return
    
    base_pattern = create_seamless_pattern(ref_img, TARGET_W, TARGET_H)
    
    synthesized = generate_synthesis(ref_img, TARGET_W, TARGET_H)
    
    result = cv2.addWeighted(base_pattern, 0.6, synthesized, 0.4, 0)
    
    result = match_histograms_channel(result, ref_img)
    
    result = add_color_variation(result, ref_img)
    
    cv2.imwrite(OUTPUT_PATH, result)
    print(f"[OK] 已生成: {OUTPUT_PATH}")


if __name__ == "__main__":
    main()
