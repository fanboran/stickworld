# -*- coding: utf-8 -*-
"""定位 Python detail 时段 err>40 像素的分布（相对冠 mask / 画布区域）。"""
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "stick-world", "tools", "ai")))

import gen_trees  # noqa: E402
from generator import StrokeGenerator  # noqa: E402

i = 1
rng = np.random.default_rng(1000 * gen_trees.KIND_OFFSET["tree"] + i)
s = gen_trees.gen_tree_struct(rng, 384, 672)
W, H = 384, 672
img = np.asarray(gen_trees.render_crown_ref(s, W, H)).astype(np.float32)
mask = np.asarray(gen_trees.render_crown_mask(s, W, H)).astype(np.float32) / 255.0
k = max(W, H) / 256.0
layers = [dict(l, w0=l["w0"] * k, w1=l["w1"] * k, ln=l["ln"] * k)
          for l in gen_trees.THIN_LAYERS]
spirals = [(b["c"][0], b["c"][1], b["r"] * 1.30, 0.55) for b in s["blobs"]]

gen = StrokeGenerator(img, 3400, layers=layers, spirals=spirals, mask=mask)
# 只跑前两层（underpainting+body），到 detail 起点时的误差分布
for lay in gen.layers[:2]:
    gen.gen_layer(lay, [])
gen._sync_canvas()
err_full = np.abs(gen.canvas - gen.img).mean(axis=2)
hi = err_full > 40
print(f"[loc] init: frac={0.0:.4f}(未测)  detail起点: frac={gen.err_frac_high:.4f}")
print(f"[loc] >40 像素总数 {int(hi.sum())} / {W * H}")
print(f"[loc] 其中冠 mask 内(>0.5): {int((hi & (mask > 0.5)).sum())}"
      f"  mask 外: {int((hi & (mask <= 0.5)).sum())}")
ys, xs = np.where(hi)
if len(ys):
    print(f"[loc] >40 像素 y 范围 [{ys.min()},{ys.max()}] 中位 {int(np.median(ys))};"
          f" x 范围 [{xs.min()},{xs.max()}] 中位 {int(np.median(xs))}")
    # 这些像素的画布色 vs 参考色差多少
    d = err_full[hi]
    print(f"[loc] >40 误差分布: 中位 {np.median(d):.0f} P90 {np.percentile(d, 90):.0f}")
    # 画布在 mask 外像素的 err（背景）
    bg = mask <= 0.5
    print(f"[loc] 背景像素 err 中位 {np.median(err_full[bg]):.1f} >40 占比 {float((err_full[bg] > 40).mean()):.4f}")
    in_m = mask > 0.5
    print(f"[loc] mask 内像素 err 中位 {np.median(err_full[in_m]):.1f} >40 占比 {float((err_full[in_m] > 40).mean()):.4f}")
