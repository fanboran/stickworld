# -*- coding: utf-8 -*-
"""数 Python 各层真实落笔数（stamp 过 mask 中点判定的数目）——与 GD 的 got 同口径。"""
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "stick-world", "tools", "ai")))

import gen_trees  # noqa: E402
from generator import StrokeGenerator  # noqa: E402


class CountGen(StrokeGenerator):
    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        self.stamp_count = 0

    def stamp_canvas(self, x0, y0, x1, y1, w, col, alpha):
        mx = min(self.W - 1, max(0, int((x0 + x1) / 2)))
        my = min(self.H - 1, max(0, int((y0 + y1) / 2)))
        if self.stroke_mask[my, mx] >= 0.5:
            self.stamp_count += 1
        return super().stamp_canvas(x0, y0, x1, y1, w, col, alpha)


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
        gen = CountGen(img, total, layers=layers, spirals=spirals, mask=mask)
        parts = []
        for lay in gen.layers:
            before = gen.stamp_count
            strokes, _ = gen.gen_layer(lay, [])
            parts.append(f"{lay['name']} {gen.stamp_count - before}/{len(strokes)}")
        print(f"[count] tree{i} {kind}: " + " ".join(parts))
