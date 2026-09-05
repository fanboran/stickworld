# -*- coding: utf-8 -*-
"""测 Python StrokeGenerator 冠区初始 err_frac_high（不修改任何基线脚本）。"""
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "stick-world", "tools", "ai")))

import gen_trees  # noqa: E402
from generator import StrokeGenerator  # noqa: E402

for i in range(4):
    rng = np.random.default_rng(1000 * gen_trees.KIND_OFFSET["tree"] + i)
    s = gen_trees.gen_tree_struct(rng, 384, 672)
    W, H = 384, 672
    crown_ref = gen_trees.render_crown_ref(s, W, H)
    img = np.asarray(crown_ref).astype(np.float32)
    mask = np.asarray(gen_trees.render_crown_mask(s, W, H)).astype(np.float32) / 255.0
    k = max(W, H) / 256.0
    layers = [dict(l, w0=l["w0"] * k, w1=l["w1"] * k, ln=l["ln"] * k)
              for l in gen_trees.THIN_LAYERS]
    spirals = [(b["c"][0], b["c"][1], b["r"] * 1.30, 0.55) for b in s["blobs"]]
    gen = StrokeGenerator(img, 3400, layers=layers, spirals=spirals, mask=mask)
    print(f"[frac] tree{i} 初始 err_frac_high = {gen.err_frac_high:.4f}")
