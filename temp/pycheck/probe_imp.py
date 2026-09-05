# -*- coding: utf-8 -*-
"""探针：Python imp 场统计（mask 内外均值/占比），与 GD [dbg] 输出对数。"""
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "stick-world", "tools", "ai")))

import gen_trees  # noqa: E402
import generator as genmod  # noqa: E402
from generator import StrokeGenerator  # noqa: E402

for i in [0, 1]:
    rng = np.random.default_rng(1000 * gen_trees.KIND_OFFSET["tree"] + i)
    s = gen_trees.gen_tree_struct(rng, 384, 672)
    W, H = 384, 672
    k = max(W, H) / 256.0
    for kind in ("trunk", "crown"):
        if kind == "trunk":
            img = np.asarray(gen_trees.render_trunk_ref(s, W, H)).astype(np.float32)
            mask = np.asarray(gen_trees.render_trunk_mask(s, W, H)).astype(np.float32) / 255.0
            total, spirals = 1400, None
        else:
            img = np.asarray(gen_trees.render_crown_ref(s, W, H)).astype(np.float32)
            mask = np.asarray(gen_trees.render_crown_mask(s, W, H)).astype(np.float32) / 255.0
            total = 3400
            spirals = [(b["c"][0], b["c"][1], b["r"] * 1.30, 0.55) for b in s["blobs"]]
        layers = [dict(l, w0=l["w0"] * k, w1=l["w1"] * k, ln=l["ln"] * k)
                  for l in gen_trees.THIN_LAYERS]
        gen = StrokeGenerator(img, total, layers=layers, spirals=spirals, mask=mask)
        imp = gen._downsample(np.ones((H, W), np.float32) * (1.0 + 2.0 * gen.grad_norm))
        imp = gen._smooth(imp, 1)
        cm = gen.stroke_mask.reshape(gen.gh, genmod.GRID, gen.gw,
                                     genmod.GRID).mean(axis=(1, 3)) >= 0.5
        print(f"[imp] tree{i} {kind}: mask占比 {cm.mean():.2f} "
              f"imp内均 {imp[cm].mean():.3f} imp外均 {imp[~cm].mean():.3f} "
              f"gmax {gen.grad_norm.max():.1f} bg梯度中位 "
              f"{np.median(gen.grad_norm[gen.stroke_mask < 0.5]):.3f}")
