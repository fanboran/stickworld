"""
方案B：基于瓦片块的层叠方法生成茅草纹理。

模拟真实茅草屋的施工逻辑：一层层铺茅草束，上层覆盖下层。
每块茅草束有不规则形状、颜色渐变和遮挡关系。
"""
import cv2
import numpy as np
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BUILDING_GEN = os.path.normpath(os.path.join(SCRIPT_DIR, "..", ".."))
REF_DIR = os.path.join(BUILDING_GEN, "reference")
OUTPUT_PATH = os.path.join(REF_DIR, "preview_thatch_B.png")

TARGET_W = 512
TARGET_H = 512


class ThatchStrand:
    """一根茅草束"""
    def __init__(self, x, y, length, width, angle, color):
        self.x = x
        self.y = y
        self.length = length
        self.width = width
        self.angle = angle
        self.color = color


def generate_strands_for_layer(layer_y, layer_h, w, rng):
    """为一层生成茅草束"""
    strands = []
    density = 0.85
    
    colors = [
        (34, 63, 111),
        (47, 97, 163),
        (65, 126, 191),
        (93, 155, 212),
        (122, 182, 231),
    ]
    
    x = rng.uniform(0, 50)
    while x < w + 50:
        strand_y = layer_y + rng.uniform(-layer_h * 0.3, layer_h * 0.3)
        strand_length = 60 + rng.uniform(-20, 30)
        strand_width = 4 + rng.uniform(-1, 2)
        angle = np.radians(210) + rng.uniform(-0.15, 0.15)
        
        color_idx = rng.integers(0, len(colors))
        base_color = colors[color_idx]
        color_variation = rng.uniform(-5, 5)
        color = tuple(np.clip(c + color_variation, 0, 255) for c in base_color)
        
        strands.append(ThatchStrand(x, strand_y, strand_length, strand_width, angle, color))
        
        x += strand_width * density * (1 + rng.uniform(-0.1, 0.3))
    
    return strands


def draw_strand(img, strand, w, h):
    """绘制一根茅草束"""
    dx = np.cos(strand.angle)
    dy = np.sin(strand.angle)
    
    for i in range(int(strand.length)):
        t = i / strand.length
        cx = strand.x + t * strand.length * dx
        cy = strand.y + t * strand.length * dy
        
        width = strand.width
        if t < 0.15:
            width = strand.width * (t / 0.15)
        elif t > 0.85:
            width = strand.width * ((1.0 - t) / 0.15)
        
        half_w = int(width * 0.5)
        
        for dw in range(-half_w, half_w + 1):
            px = int(cx + dw * np.sin(strand.angle))
            py = int(cy - dw * np.cos(strand.angle))
            
            if px < 0:
                px = w + px
            if px >= w:
                px = px - w
            if py < 0 or py >= h:
                continue
            
            dist = abs(dw) / max(half_w, 1)
            shade = 1.0 - dist * dist * 0.3
            
            if t < 0.4:
                shade *= 1.0 + (t / 0.4) * 0.15
            else:
                shade *= 1.15 - ((t - 0.4) / 0.6) * 0.25
            
            color = tuple(min(255, int(c * shade)) for c in strand.color)
            img[py, px] = color


def generate_thatch_tiles(w, h):
    """生成层叠瓦片式茅草纹理"""
    img = np.zeros((h, w, 3), dtype=np.uint8)
    
    rng = np.random.default_rng(42)
    
    num_layers = 8
    layer_h = h / num_layers
    
    for layer_idx in range(num_layers):
        layer_y = layer_idx * layer_h
        
        if layer_idx < 2:
            color_range = [2, 4]
        elif layer_idx < 5:
            color_range = [1, 3]
        else:
            color_range = [0, 2]
        
        strands = generate_strands_for_layer(layer_y, layer_h, w, rng)
        
        for strand in strands:
            draw_strand(img, strand, w, h)
    
    return img


def add_bottom_gradient(img, h):
    """添加底部压暗梯度"""
    for y in range(h):
        t_y = y / h
        if t_y > 0.5:
            darken = 1.0 - (t_y - 0.5) / 0.5 * 0.6
            img[y, :] = np.clip(img[y, :] * darken, 0, 255).astype(np.uint8)
    return img


def add_roughness(img, w, h):
    """添加粗糙度——模拟手绘感"""
    rng = np.random.default_rng(89)
    
    for y in range(h):
        for x in range(w):
            if rng.random() < 0.15:
                noise = rng.uniform(-8, 8)
                img[y, x] = np.clip(img[y, x] + noise, 0, 255).astype(np.uint8)
    
    return img


def add_edge_highlight(img, w, h):
    """添加边缘高光——模拟茅草纤维的立体感"""
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    sobelx = cv2.Sobel(gray, cv2.CV_64F, 1, 0, ksize=3)
    sobely = cv2.Sobel(gray, cv2.CV_64F, 0, 1, ksize=3)
    
    edges = np.sqrt(sobelx**2 + sobely**2)
    edges = (edges / edges.max()) * 20
    
    for y in range(h):
        for x in range(w):
            edge_val = edges[y, x]
            if edge_val > 5:
                img[y, x] = np.clip(img[y, x] + edge_val, 0, 255).astype(np.uint8)
    
    return img


def main():
    print("方案B：基于层叠瓦片生成茅草纹理...")
    
    img = generate_thatch_tiles(TARGET_W, TARGET_H)
    
    img = add_bottom_gradient(img, TARGET_H)
    
    img = add_roughness(img, TARGET_W, TARGET_H)
    
    img = add_edge_highlight(img, TARGET_W, TARGET_H)
    
    cv2.imwrite(OUTPUT_PATH, img)
    print(f"[OK] 已生成: {OUTPUT_PATH}")


if __name__ == "__main__":
    main()
