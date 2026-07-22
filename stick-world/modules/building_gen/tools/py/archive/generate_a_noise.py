"""
方案A：基于多层噪声(FBM+方向性噪声)生成茅草纹理。

使用多尺度噪声叠加生成高度图，再将高度映射到参考图颜色空间。
模拟茅草的有机层叠感和方向性纹理。
"""
import cv2
import numpy as np
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BUILDING_GEN = os.path.normpath(os.path.join(SCRIPT_DIR, "..", ".."))
REF_DIR = os.path.join(BUILDING_GEN, "reference")
OUTPUT_PATH = os.path.join(REF_DIR, "preview_thatch_A.png")

TARGET_W = 512
TARGET_H = 512


def random_permutation(seed):
    """生成伪随机排列"""
    np.random.seed(seed)
    arr = np.arange(256, dtype=np.int32)
    np.random.shuffle(arr)
    return arr


def noise2d(x, y, perm):
    """向量化的2D噪声函数"""
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
    """分形布朗运动（向量化）"""
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
    """方向性噪声——沿特定角度的拉伸噪声"""
    angle_rad = np.radians(angle_deg)
    cos_a = np.cos(angle_rad)
    sin_a = np.sin(angle_rad)
    
    px = x * cos_a - y * sin_a
    py = x * sin_a + y * cos_a
    
    py_stretched = py * 3.0
    return fbm(px * 0.02, py_stretched * 0.02, octaves=5, persistence=0.6, seed=seed)


def generate_thatch_noise(w, h):
    """生成茅草噪声高度图"""
    y, x = np.mgrid[0:h, 0:w].astype(np.float64)
    
    noise_base = directional_noise(x, y, angle_deg=210, seed=42)
    
    noise_fine = directional_noise(x, y, angle_deg=210, seed=89) * 0.5
    noise_fine = noise_fine * directional_noise(x, y, angle_deg=210+30, seed=156) * 0.3
    
    noise_horizontal = fbm(x * 0.015, y * 0.005, octaves=4, persistence=0.5, seed=234) * 0.2
    
    height = noise_base + noise_fine + noise_horizontal
    height = (height - height.min()) / (height.max() - height.min())
    
    return height


def color_map(height, y, h):
    """将高度映射到茅草颜色"""
    t_y = y / float(h)
    
    darken_factor = np.ones_like(t_y)
    mask = t_y > 0.55
    darken_factor[mask] = np.clip(1.0 - (t_y[mask] - 0.55) / 0.45 * 0.75, 0.25, 1.0)
    
    colors = np.array([
        [34, 63, 111],
        [47, 97, 163],
        [65, 126, 191],
        [93, 155, 212],
        [122, 182, 231],
    ], dtype=np.float64)
    
    color_idx = np.floor(height * (len(colors) - 1)).astype(np.int32)
    color_idx = np.clip(color_idx, 0, len(colors) - 2)
    
    t = (height * (len(colors) - 1)) % 1.0
    
    c0 = colors[color_idx]
    c1 = colors[color_idx + 1]
    
    result = c0 * (1.0 - t)[:, :, np.newaxis] + c1 * t[:, :, np.newaxis]
    result = result * darken_factor[:, :, np.newaxis]
    
    return result.astype(np.uint8)


def add_strand_details(img, w, h):
    """添加更细的纤维细节"""
    y, x = np.mgrid[0:h, 0:w].astype(np.float64)
    
    for _ in range(3):
        angle = 210.0 + np.random.uniform(-15, 15)
        angle_rad = np.radians(angle)
        
        px = x * np.cos(angle_rad) - y * np.sin(angle_rad)
        py = x * np.sin(angle_rad) + y * np.cos(angle_rad)
        
        strand = np.sin(px * 0.05) * np.sin(py * 0.1) * 15
        strand = np.clip(strand, -10, 10)
        
        img = np.clip(img + strand[:, :, np.newaxis], 0, 255).astype(np.uint8)
    
    return img


def add_layer_structure(img, w, h):
    """添加层叠结构——模拟茅草层的水平分布"""
    y = np.arange(h).astype(np.float64)
    
    for i in range(5):
        layer_center = 50 + i * 95
        layer_width = 80 + np.random.uniform(-10, 10)
        
        t = np.abs(y - layer_center) / layer_width
        mask = np.maximum(0, 1.0 - t * t) * 0.15
        
        darken = 1.0 - mask
        darken = np.tile(darken, (w, 1)).T
        
        img = (img * darken[:, :, np.newaxis]).astype(np.uint8)
    
    return img


def main():
    print("方案A：基于多层噪声生成茅草纹理...")
    
    height = generate_thatch_noise(TARGET_W, TARGET_H)
    
    y_coords = np.arange(TARGET_H).astype(np.float64)
    y_grid = np.tile(y_coords, (TARGET_W, 1)).T
    
    img = color_map(height, y_grid, TARGET_H)
    
    img = add_layer_structure(img, TARGET_W, TARGET_H)
    
    img = add_strand_details(img, TARGET_W, TARGET_H)
    
    cv2.imwrite(OUTPUT_PATH, img)
    print(f"[OK] 已生成: {OUTPUT_PATH}")


if __name__ == "__main__":
    main()
