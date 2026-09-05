# -*- coding: utf-8 -*-
"""笔触化贴图管线 —— 参考图 → 油画笔触拟合 → 抠背景出游戏贴图。

复用 mona-3 逆向油画算法（分层笔触 + 模拟画布叠压，作者逆向上色 demo 而来）：
    外部依赖 F:\\VSCode\\DSH\\mona-3\\generator.py（StrokeGenerator）
针对游戏小贴图（256px 档）调小笔数与笔宽；白底参考图按色距抠 alpha。

用法：
    python stroke_paint.py <参考图.png> <输出.png> [总笔数] [mask.png]
库内调用可传 size（画布尺寸，默认缩到 256 兼容旧调用）与 bg（参考图底色，
用于半透明边缘的预乘消底；白云等浅色主体须改用 mask 抠图避免误抠）。
"""
import os
import sys

import numpy as np
from PIL import Image

MONA_DIR = r"F:\VSCode\DSH\mona-3"
sys.path.insert(0, MONA_DIR)
from generator import StrokeGenerator  # noqa: E402  (外部 mona-3 逆向算法)

# 游戏贴图分层：粗底 → 主体 → 细节 → 罩染（相对原版：笔更少更宽，速度优先）
GAME_LAYERS = [
    dict(name="underpainting", ratio=0.20, w0=16.0, w1=12.0, ln=42, alpha=0.98,
         typ="Q", region="full", jit=0.24, mode="walk", p_jump=0.95, csteps=6,
         band_jit=0.28),
    dict(name="body", ratio=0.42, w0=9.0, w1=5.5, ln=20, alpha=0.97,
         typ="Q", region="full", jit=0.20, mode="band", p_end=0.01, csteps=6,
         band_jit=0.22, color_break=True),
    dict(name="detail", ratio=0.32, w0=2.6, w1=1.5, ln=9, alpha=0.90,
         typ="Z", region="full", jit=0.9, mode="scatter", csteps=5,
         refine=True, err_thresh=0.06, color_break=True),
    dict(name="glaze", ratio=0.06, w0=11.0, w1=9.0, ln=52, alpha=0.12,
         typ="Q", region="full", jit=0.5, mode="scatter", csteps=6),
]

BG_DIST_HARD = 16.0   # 与白底色距小于此 → 全透明
BG_DIST_SOFT = 34.0   # 大于此 → 不透明（之间线性羽化）


def paint(src: str, dst: str, total: int = 1600, mask_path: str = "",
          size=None, bg=(250.0, 250.0, 250.0)) -> None:
    im = Image.open(src).convert("RGB")
    if size is not None:
        im = im.resize(size, Image.LANCZOS)
    elif im.size != (256, 256):
        im = im.resize((256, 256), Image.LANCZOS)
    img = np.asarray(im).astype(np.float32)
    H, W = img.shape[:2]
    # 笔宽/笔长按画布相对 256 基准等比缩放（不同尺寸贴图的笔触颗粒度一致）
    k = max(W, H) / 256.0
    layers = GAME_LAYERS if k == 1.0 else [
        dict(l, w0=l["w0"] * k, w1=l["w1"] * k, ln=l["ln"] * k)
        for l in GAME_LAYERS
    ]
    gen = StrokeGenerator(img, total, layers=layers)
    blocks, got = gen.run()
    print(f"[stroke] {os.path.basename(src)}: {got} 笔 "
          + ", ".join(f"{n}×{len(s)}" for n, s in blocks))
    canvas = gen.canvas_img.convert("RGB")  # 模拟画布即输入尺寸

    arr = np.asarray(canvas).astype(np.float32)
    if mask_path and os.path.exists(mask_path):
        # 形状 mask 抠图（精确）：mask 已羽化，直接归一 0~1
        m = Image.open(mask_path).convert("L")
        if m.size != (W, H):
            m = m.resize((W, H), Image.LANCZOS)
        alpha = np.asarray(m).astype(np.float32) / 255.0
    else:
        # 回退：底色距羽化抠图（罩染层会污染底色，尽量提供 mask）
        dist = np.abs(arr - np.asarray(bg, np.float32)).sum(-1)
        alpha = np.clip((dist - BG_DIST_HARD) / (BG_DIST_SOFT - BG_DIST_HARD), 0.0, 1.0)
    # 预乘消底：半透明像素把底色残留按 (1-alpha) 削掉
    keep = alpha[..., None]
    bg_arr = np.asarray(bg, np.float32)[None, None, :]
    rgb = np.clip((arr - bg_arr * (1.0 - keep)) / np.maximum(keep, 1e-3), 0, 255)
    out = np.dstack([rgb, alpha * 255.0]).astype(np.uint8)
    Image.fromarray(out, "RGBA").save(dst)
    cov = float((alpha > 0.5).mean())
    print(f"[stroke] -> {dst}（不透明覆盖率 {cov:.0%}）")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    total = int(sys.argv[3]) if len(sys.argv) > 3 else 1600
    mask = sys.argv[4] if len(sys.argv) > 4 else sys.argv[1].replace("_ref.png", "_mask.png")
    paint(sys.argv[1], sys.argv[2], total, mask)
