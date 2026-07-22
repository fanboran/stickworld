"""方案K3：简单快速的茅草帘原型"""
import cv2
import numpy as np
import os

DIR = r"f:\VSCode\game-2\stick-world\modules\building_gen\reference"
OUT = os.path.join(DIR, "preview_thatch_K3.png")
W, H = 512, 512

PAL = {
    'h': np.array([233, 185, 126], dtype=np.float64),  # RGB
    'b': np.array([212, 156, 93], dtype=np.float64),
    'm': np.array([191, 125, 63], dtype=np.float64),
    'd': np.array([114, 65, 35], dtype=np.float64),
    's': np.array([50, 28, 15], dtype=np.float64),
}

rng = np.random.default_rng(42)
img = np.full((H, W, 3), 25, dtype=np.uint8)

def lerp(a, b, k):
    return a * (1-k) + b * k

def draw_strand(x0, y0, angle_deg, length, width, c0, c1):
    a = np.radians(angle_deg)
    ux, uy = np.cos(a), np.sin(a)
    for t in range(length):
        k = t / max(length-1, 1)
        px = int(x0 + ux * t)
        py = int(y0 + uy * t)
        if not (0 <= px < W and 0 <= py < H):
            continue
        c = lerp(c0, c1, k * 0.85)
        c += rng.uniform(-8, 8, 3)
        c = np.clip(c, 0, 255).astype(np.uint8)
        for dw in range(-width//2, width//2+1):
            qx = (px + dw) % W
            img[py, qx] = c

num_layers = 4
lh = H // num_layers
for li in range(num_layers-1, -1, -1):
    top = li * lh
    bot = (li+1) * lh
    ty = top / H
    if ty < 0.25:
        cr, ct, cb = PAL['h'], PAL['m'], PAL['b']
    elif ty < 0.5:
        cr, ct, cb = PAL['b'], PAL['d'], PAL['m']
    elif ty < 0.75:
        cr, ct, cb = PAL['m'], PAL['s'], PAL['d']
    else:
        cr, ct, cb = PAL['d'], PAL['s'], PAL['d']

    # 底色
    for y in range(top, min(bot+2, H)):
        t = (y - top) / max(lh, 1)
        c = lerp(cb, ct, t * 0.3)
        c += rng.uniform(-4, 4, 3)
        c = np.clip(c, 0, 255).astype(np.uint8)
        img[y, :] = c

    # 大量草丝从层顶垂下
    for i in range(W * 3):
        x = rng.integers(0, W)
        y = top + rng.integers(0, max(lh//6, 1))
        ang = rng.uniform(100, 140) if rng.random() < 0.5 else rng.uniform(40, 80)
        length = int(lh * rng.uniform(0.6, 1.0))
        width = rng.integers(1, 2)
        draw_strand(x, y, ang, length, width, cr, ct)

    # 草束
    for i in range(W // 25):
        x = (i * 25 + rng.integers(-8, 9)) % W
        y = top + rng.integers(0, max(lh//6, 1))
        ang = rng.uniform(110, 130) if rng.random() < 0.5 else rng.uniform(50, 70)
        length = int(lh * rng.uniform(0.8, 1.2))
        for b in range(rng.integers(4, 10)):
            bx = x + rng.integers(-5, 6)
            by = y + rng.integers(-2, 3)
            ba = ang + rng.uniform(-10, 10)
            bl = int(length * rng.uniform(0.8, 1.1))
            draw_strand(bx, by, ba, bl, rng.integers(1, 3), cr, ct)

    # 参差底部
    jd = lh * (0.5 if li == num_layers-1 else 0.25)
    for x in range(W):
        if rng.random() < 0.55:
            d = rng.uniform(0.1, 1.0) * jd
            for y in range(bot, min(int(bot+d)+1, H)):
                c = ct * 0.85 + rng.uniform(-5, 3, 3)
                c = np.clip(c, 0, 255).astype(np.uint8)
                img[y, x] = c

# OpenCV 保存需要 BGR
img_bgr = cv2.cvtColor(img.astype(np.uint8), cv2.COLOR_RGB2BGR)
cv2.imwrite(OUT, img_bgr)
print(f"OK: {OUT}")
