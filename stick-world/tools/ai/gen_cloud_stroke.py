# -*- coding: utf-8 -*-
"""笔触云贴图生成 —— 平顶积云形状（gen_cloud 同构）+ stroke_paint 油画管线。

云与树/石同管线出图，风格统一（用户核心诉求）。三个关键点：
  1. 云是白云，白底色距抠图会误抠 → 程序合成云形 mask，走 paint 的 mask_path 精确抠图
  2. 参考图底色用天空蓝（非白），半透明边缘的底色残留按 bg 预乘消除
  3. 参考图不能是纯平滑渐变（detail 层会 0 笔收敛 → 画出来是软渐变团而非笔触云），
     逐 puff 立体着色：每个 puff 自带顶亮→底灰，笔触按 puff 团块组织出体积
参考图 = 天空蓝底 + 逐 puff 着色云体；画天空的笔触被 mask 丢弃，
云区笔触密度由总笔数保证。

用法：python gen_cloud_stroke.py [输出目录 assets/sky]
"""
import os
import random
import sys
import tempfile

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stroke_paint  # noqa: E402

W, H = 512, 256
# 天空底（轻垂直渐变；边缘预乘消除用其中间值）
SKY_TOP = (146, 188, 224)
SKY_BOT = (170, 204, 230)
# 云体着色：亮顶白 → 底灰蓝（逐 puff 深度场在两者间插值）
CLOUD_TOP = (255, 253, 248)
CLOUD_BOT = (192, 204, 220)
TOTAL = 3600  # 笔数（面积 2× 于 256 基准，云占 ~60%，云区实际 ~2200 笔）


def cloud_puffs(seed):
    """平顶积云 puff 簇（gen_sky_decor.gen_cloud 同构）。返回 (主轴puff, 顶凸puff, base_y)。"""
    rnd = random.Random(seed)
    base_y = H * 0.66
    main, tops = [], []
    n = 7
    for i in range(n):
        t = i / (n - 1)
        ox = (t - 0.5) * W * 0.74
        r = (1.0 - abs(t - 0.28) * 1.1) * rnd.uniform(52, 68) + 34
        cy = base_y - r * rnd.uniform(0.55, 0.8)
        main.append((W * 0.5 + ox, cy, r))
    for _ in range(6):
        ox = rnd.uniform(-W * 0.34, W * 0.34)
        r = rnd.uniform(15, 30)
        cy = base_y - rnd.uniform(66, 96)
        tops.append((W * 0.5 + ox, cy, r))
    return main, tops, base_y


def cloud_mask(puffs):
    """形状蒙版（puff 并集 + 垫底椭圆 + 底边裁平），羽化 2px。"""
    main, tops, base_y = puffs
    mask = Image.new("L", (W, H), 0)
    md = ImageDraw.Draw(mask)
    for cx, cy, r in main + tops:
        md.ellipse((cx - r, cy - r, cx + r, cy + r), fill=255)
    md.ellipse((W * 0.12, base_y - 36, W * 0.88, base_y + 8), fill=255)
    md.rectangle((0, base_y + 2, W, H), fill=0)
    return mask.filter(ImageFilter.GaussianBlur(2))


def cloud_depth(puffs, mask):
    """逐 puff 深度场（0=亮顶 1=暗底）：每个 puff 自带上亮下暗，
    重叠处亮者胜（受光 dome 主导）；再叠加全局垂直渐变与云底加深。"""
    main, tops, base_y = puffs
    field = np.full((H, W), 0.92, np.float32)  # 未覆盖=最暗（占位）
    for cx, cy, r in main + tops:
        x0, x1 = max(0, int(cx - r)), min(W, int(cx + r) + 1)
        y0, y1 = max(0, int(cy - r)), min(H, int(cy + r) + 1)
        pw, ph = x1 - x0, y1 - y0
        if pw < 2 or ph < 2:
            continue
        e = Image.new("L", (pw, ph), 0)
        ImageDraw.Draw(e).ellipse((0, 0, pw - 1, ph - 1), fill=255)
        # puff 内深度 0.10(顶) → 0.86(底)，微随机错开层次
        ramp = np.tile(np.linspace(0.10, 0.86, ph)[:, None], (1, pw))
        patch = ramp * (np.asarray(e, np.float32) / 255.0) + 0.92 * (1.0 - np.asarray(e, np.float32) / 255.0)
        field[y0:y1, x0:x1] = np.minimum(field[y0:y1, x0:x1], patch)
    yy = np.linspace(0.0, 1.0, H)[:, None]
    depth = 0.40 * np.broadcast_to(yy, (H, W)) + 0.60 * field
    # 云底整圈加深（积云底最暗）
    depth += 0.14 * np.clip((np.arange(H)[:, None] - (base_y - 46.0)) / 46.0, 0, 1)
    a = np.asarray(mask, np.float32) / 255.0
    return np.clip(depth * a + 0.92 * (1.0 - a), 0, 1)


def ref_image(puffs, mask):
    """参考图：天空蓝底 + 逐 puff 着色云体（mask 羽化区自然混合）。"""
    depth = cloud_depth(puffs, mask)
    sky = np.empty((H, W, 3), np.float32)
    cloud = np.empty((H, W, 3), np.float32)
    yy = np.linspace(0.0, 1.0, H)[:, None]
    for c in range(3):
        sky[:, :, c] = SKY_TOP[c] + (SKY_BOT[c] - SKY_TOP[c]) * yy
        cloud[:, :, c] = CLOUD_TOP[c] + (CLOUD_BOT[c] - CLOUD_TOP[c]) * depth
    a = (np.asarray(mask, np.float32) / 255.0)[..., None]
    img = sky * (1.0 - a) + cloud * a
    return Image.fromarray(np.uint8(np.clip(img, 0, 255)), "RGB")


def gen_cloud_stroke(path, seed):
    puffs = cloud_puffs(seed)
    mask = cloud_mask(puffs)
    ref = ref_image(puffs, mask)
    with tempfile.TemporaryDirectory() as td:
        ref_p = os.path.join(td, "cloud_ref.png")
        mask_p = os.path.join(td, "cloud_mask.png")
        ref.save(ref_p)
        mask.save(mask_p)
        bg = tuple((SKY_TOP[i] + SKY_BOT[i]) / 2.0 for i in range(3))
        stroke_paint.paint(ref_p, path, TOTAL, mask_p, size=(W, H), bg=bg)
    print("[sky] stroke cloud ->", path)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "assets/sky"
    os.makedirs(out, exist_ok=True)
    for name, seed in (("cloud_a", 1), ("cloud_b", 7), ("cloud_c", 23)):
        gen_cloud_stroke(os.path.join(out, name + ".png"), seed)
