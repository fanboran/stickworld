"""
方案D：融合方案——结合方案A的噪声结构和方案B的颜色分布。

核心策略：
1. 使用方向性噪声生成高度图（方案A的优势）
2. 从参考图提取颜色分布做精确映射（方案B的优势）
3. 添加边缘细节和纤维纹理（提升边缘密度）
4. 精确匹配参考图的垂直剖面
"""
import cv2
import numpy as np
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BUILDING_GEN = os.path.normpath(os.path.join(SCRIPT_DIR, "..", ".."))
REF_DIR = os.path.join(BUILDING_GEN, "reference")
REF_PATH = os.path.join(REF_DIR, "thatch_ref.png")
OUTPUT_PATH = os.path.join(REF_DIR, "preview_thatch_D.png")

TARGET_W = 512
TARGET_H = 512


def random_permutation(seed):
    np.random.seed(seed)
    arr = np.arange(256, dtype=np.int32)
    np.random.shuffle(arr)
    return arr


def noise2d(x, y, perm):
    X = (x.astype(np.int32)) & 255
    Y = (y.astype(np.int32)) & 255
    xf = x - x.astype(np.int32)
    yf = y - y.astype(np.int32)
    
    u = xf * xf * (3.0 - 2.0 * xf)
    v = yf * yf * (3.0 - 2.0 * yf)
    
    n00 = perm[(perm[X] + Y) & 255]
    n01 = perm[(perm[X] + Y + 1) & 255]
    n10 = perm[(perm[(X + 1) & 255] + Y) & 255]
    n11 = perm[(perm[(X + 1) & 255] + Y + 1) & 255]
    
    return (n00 * (1.0 - u) + n10 * u) * (1.0 - v) + (n01 * (1.0 - u) + n11 * u) * v


def fbm(x, y, octaves=6, persistence=0.5, lacunarity=2.0, seed=42):
    perm = random_permutation(seed)
    total = np.zeros_like(x, dtype=np.float64)
    amplitude = 1.0
    frequency = 1.0
    max_val = 0.0
    
    for _ in range(octaves):
        total += noise2d(x * frequency, y * frequency, perm).astype(np.float64) * amplitude
        max_val += amplitude
        amplitude *= persistence
        frequency *= lacunarity
    
    return total / max_val


def directional_noise(x, y, angle_deg=210, seed=123):
    angle_rad = np.radians(angle_deg)
    cos_a = np.cos(angle_rad)
    sin_a = np.sin(angle_rad)
    
    px = x * cos_a - y * sin_a
    py = x * sin_a + y * cos_a
    
    py_stretched = py * 4.0
    return fbm(px * 0.015, py_stretched * 0.015, octaves=6, persistence=0.55, seed=seed)


def generate_height_map(w, h):
    y, x = np.mgrid[0:h, 0:w].astype(np.float64)
    
    noise_base = directional_noise(x, y, angle_deg=210, seed=42)
    
    noise_fine = directional_noise(x, y, angle_deg=210, seed=89) * 0.4
    noise_fine += directional_noise(x, y, angle_deg=210+45, seed=156) * 0.2
    
    noise_horizontal = fbm(x * 0.01, y * 0.003, octaves=5, persistence=0.5, seed=234) * 0.3
    
    height = noise_base + noise_fine + noise_horizontal
    height = (height - height.min()) / (height.max() - height.min())
    
    return height


def extract_ref_colors(ref_img):
    """从参考图提取有效颜色样本"""
    pixels = ref_img.reshape(-1, 3)
    valid = pixels[np.sum(pixels, axis=1) > 10]
    return valid


def match_reference_profile(img, ref_img):
    """匹配参考图的垂直剖面"""
    ref_gray = cv2.cvtColor(ref_img, cv2.COLOR_BGR2GRAY)
    img_gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    
    ref_profile = ref_gray.mean(axis=1)
    img_profile = img_gray.mean(axis=1)
    
    ref_h = len(ref_profile)
    img_h = len(img_profile)
    
    ref_profile_resized = cv2.resize(ref_profile.reshape(1, ref_h), (img_h, 1)).flatten()
    
    h = img.shape[0]
    for y in range(h):
        scale = ref_profile_resized[y] / max(img_profile[y], 1)
        img[y, :] = np.clip(img[y, :].astype(np.float64) * scale, 0, 255).astype(np.uint8)
    
    return img


def add_strand_edges(img, w, h):
    """添加纤维边缘细节——大幅提升边缘密度"""
    y, x = np.mgrid[0:h, 0:w].astype(np.float64)
    
    for _ in range(8):
        angle = 210.0 + np.random.uniform(-25, 25)
        angle_rad = np.radians(angle)
        
        px = x * np.cos(angle_rad) - y * np.sin(angle_rad)
        py = x * np.sin(angle_rad) + y * np.cos(angle_rad)
        
        edge = np.sin(px * 0.12) * np.sin(py * 0.2) * 25
        edge = np.clip(edge, -20, 20)
        
        img = np.clip(img.astype(np.float64) + edge[:, :, np.newaxis], 0, 255).astype(np.uint8)
    
    return img


def add_fine_strands(img, w, h):
    """添加极细的纤维线条——大幅提升边缘密度"""
    rng = np.random.default_rng(123)
    
    num_strands = int(w * 5.5)
    for _ in range(num_strands):
        sx = rng.uniform(0, w)
        sy = rng.uniform(0, h)
        length = 25 + rng.uniform(-10, 30)
        width = 1 + rng.uniform(-0.2, 0.2)
        angle = np.radians(210) + rng.uniform(-0.5, 0.5)
        
        dx = np.cos(angle)
        dy = np.sin(angle)
        
        for i in range(int(length)):
            t = i / length
            cx = sx + t * length * dx
            cy = sy + t * length * dy
            
            w_t = width
            if t < 0.2:
                w_t = width * (t / 0.2)
            elif t > 0.8:
                w_t = width * ((1.0 - t) / 0.2)
            
            half_w = max(int(w_t * 0.5), 0)
            for dw in range(-half_w, half_w + 1):
                px = int(cx + dw * np.sin(angle))
                py = int(cy - dw * np.cos(angle))
                
                if px < 0:
                    px = w + px
                if px >= w:
                    px = px - w
                if py < 0 or py >= h:
                    continue
                
                dist = abs(dw) / max(half_w, 1)
                shade = 1.2 + dist * 1.0
                
                current = img[py, px].astype(np.float64)
                img[py, px] = np.clip(current * shade, 0, 255).astype(np.uint8)
    
    return img


def add_noise_detail(img, w, h):
    """添加噪点细节——提升边缘密度和纹理感"""
    rng = np.random.default_rng(456)
    
    noise = rng.integers(-5, 6, size=(h, w, 3), dtype=np.int16)
    img = np.clip(img.astype(np.int16) + noise, 0, 255).astype(np.uint8)
    
    return img


def add_edge_detail(img, w, h):
    """添加边缘细节——使用Sobel算子增强边缘对比度"""
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    sobelx = cv2.Sobel(gray, cv2.CV_64F, 1, 0, ksize=3)
    sobely = cv2.Sobel(gray, cv2.CV_64F, 0, 1, ksize=3)
    
    edges = np.sqrt(sobelx**2 + sobely**2)
    edges = (edges / edges.max()) * 40
    
    edges_mask = edges > 8
    for y in range(h):
        for x in range(w):
            if edges_mask[y, x]:
                edge_val = edges[y, x]
                boost = 1.0 + edge_val / 100
                img[y, x] = np.clip(img[y, x].astype(np.float64) * boost, 0, 255).astype(np.uint8)
    
    return img


def transfer_structure(img, ref_img):
    """结构转移——用参考图的边缘/梯度模式调制生成图的局部对比度"""
    h, w = img.shape[:2]
    
    ref_resized = cv2.resize(ref_img, (w, h), interpolation=cv2.INTER_AREA)
    ref_gray = cv2.cvtColor(ref_resized, cv2.COLOR_BGR2GRAY)
    img_gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    
    ref_sobel_x = cv2.Sobel(ref_gray, cv2.CV_64F, 1, 0, ksize=3)
    ref_sobel_y = cv2.Sobel(ref_gray, cv2.CV_64F, 0, 1, ksize=3)
    ref_edges = np.sqrt(ref_sobel_x**2 + ref_sobel_y**2)
    ref_edges = (ref_edges - ref_edges.min()) / (ref_edges.max() - ref_edges.min())
    
    img_sobel_x = cv2.Sobel(img_gray, cv2.CV_64F, 1, 0, ksize=3)
    img_sobel_y = cv2.Sobel(img_gray, cv2.CV_64F, 0, 1, ksize=3)
    img_edges = np.sqrt(img_sobel_x**2 + img_sobel_y**2)
    img_edges = (img_edges - img_edges.min()) / (img_edges.max() - img_edges.min())
    
    edge_diff = ref_edges - img_edges
    edge_diff = (edge_diff + 1) / 2.0
    
    contrast_factor = 0.8 + edge_diff * 0.4
    
    result = np.zeros_like(img)
    for c in range(3):
        result[:, :, c] = np.clip(img[:, :, c].astype(np.float64) * contrast_factor, 0, 255).astype(np.uint8)
    
    return result


def adjust_final_colors(img, w, h):
    """后期颜色调整——微调各区域通道"""
    y_coords = np.arange(h).astype(np.float64)
    t_y = y_coords / float(h)
    
    for y in range(h):
        ty = t_y[y]
        
        if ty < 0.35:
            img[y, :, 0] = np.clip(img[y, :, 0].astype(np.int16) + 1, 0, 255).astype(np.uint8)
            img[y, :, 1] = np.clip(img[y, :, 1].astype(np.int16) + 2, 0, 255).astype(np.uint8)
            img[y, :, 2] = np.clip(img[y, :, 2].astype(np.int16) + 4, 0, 255).astype(np.uint8)
        elif ty < 0.65:
            img[y, :, 0] = np.clip(img[y, :, 0].astype(np.int16) + 2, 0, 255).astype(np.uint8)
            img[y, :, 1] = np.clip(img[y, :, 1].astype(np.int16) + 2, 0, 255).astype(np.uint8)
            img[y, :, 2] = np.clip(img[y, :, 2].astype(np.int16) + 2, 0, 255).astype(np.uint8)
        else:
            img[y, :, 0] = np.clip(img[y, :, 0].astype(np.int16) + 1, 0, 255).astype(np.uint8)
            img[y, :, 1] = np.clip(img[y, :, 1].astype(np.int16) + 1, 0, 255).astype(np.uint8)
            img[y, :, 2] = np.clip(img[y, :, 2].astype(np.int16) + 3, 0, 255).astype(np.uint8)
    
    return img


def add_layering(img, w, h):
    """添加层叠结构——模拟真实茅草层叠"""
    rng = np.random.default_rng(789)
    
    for layer in range(8):
        base_y = int(h * (layer + 1) / 9)
        
        for y_offset in range(-8, 9):
            y = base_y + y_offset
            if y < 0 or y >= h:
                continue
            
            t = abs(y_offset) / 8.0
            darken = 1.0 - (1.0 - t) * 0.12
            
            for x in range(w):
                if rng.random() < 0.3:
                    darken *= (0.95 + rng.random() * 0.1)
            
            img[y, :] = np.clip(img[y, :].astype(np.float64) * darken, 0, 255).astype(np.uint8)
    
    return img


def apply_color_mapping(height, ref_colors, w, h):
    """基于高度的颜色映射"""
    y_coords = np.arange(h).astype(np.float64)
    y_grid = np.tile(y_coords, (w, 1)).T
    t_y = y_grid / float(h)
    
    darken_factor = np.ones_like(t_y)
    
    top_mask = t_y < 0.35
    darken_factor[top_mask] = 1.25
    
    mid_mask = (t_y >= 0.35) & (t_y <= 0.55)
    darken_factor[mid_mask] = 1.08
    
    bottom_mask = t_y > 0.55
    darken_factor[bottom_mask] = np.clip(1.0 - (t_y[bottom_mask] - 0.55) / 0.45 * 0.72, 0.22, 1.0)
    
    ref_colors_sorted = ref_colors[np.argsort(ref_colors.mean(axis=1))]
    
    num_colors = len(ref_colors_sorted)
    color_idx = np.floor(height * (num_colors - 1)).astype(np.int32)
    color_idx = np.clip(color_idx, 0, num_colors - 2)
    
    t = (height * (num_colors - 1)) % 1.0
    
    result = np.zeros((h, w, 3), dtype=np.uint8)
    for y in range(h):
        for x in range(w):
            idx = color_idx[y, x]
            t_val = t[y, x]
            darken = darken_factor[y, x]
            
            c0 = ref_colors_sorted[idx]
            c1 = ref_colors_sorted[idx + 1]
            
            blended = c0 * (1.0 - t_val) + c1 * t_val
            
            if t_y[y, x] < 0.35:
                blended[0] = blended[0] * 1.18
                blended[1] = blended[1] * 1.03
                blended[2] = blended[2] * 2.60
            elif t_y[y, x] < 0.65:
                blended[0] = blended[0] * 1.05
                blended[2] = blended[2] * 1.03
            else:
                blended[0] = blended[0] * 1.00
                blended[1] = blended[1] * 1.07
                blended[2] = blended[2] * 1.15
            
            blended = np.clip(blended * darken, 0, 255).astype(np.uint8)
            result[y, x] = blended
    
    return result


def main():
    print("方案D：融合方案生成茅草纹理...")
    
    ref_img = cv2.imread(REF_PATH, cv2.IMREAD_COLOR)
    if ref_img is None:
        print(f"[ERROR] 无法读取参考图: {REF_PATH}")
        return
    
    ref_colors = extract_ref_colors(ref_img)
    print(f"提取到 {len(ref_colors)} 个有效颜色样本")
    
    height = generate_height_map(TARGET_W, TARGET_H)
    
    img = apply_color_mapping(height, ref_colors, TARGET_W, TARGET_H)
    
    img = add_layering(img, TARGET_W, TARGET_H)
    
    img = add_strand_edges(img, TARGET_W, TARGET_H)
    
    img = add_fine_strands(img, TARGET_W, TARGET_H)
    
    img = add_noise_detail(img, TARGET_W, TARGET_H)
    
    img = add_edge_detail(img, TARGET_W, TARGET_H)
    
    img = match_reference_profile(img, ref_img)
    
    img = adjust_final_colors(img, TARGET_W, TARGET_H)
    
    img = transfer_structure(img, ref_img)
    
    img = cv2.GaussianBlur(img, (3, 3), 0.15)
    
    cv2.imwrite(OUTPUT_PATH, img)
    print(f"[OK] 已生成: {OUTPUT_PATH}")


if __name__ == "__main__":
    main()
