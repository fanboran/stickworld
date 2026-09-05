# -*- coding: utf-8 -*-
"""探针：复刻 stroke_paint.paint() 的冠区拟合流程，抓 detail 层真实收敛判据。
（不改基线脚本；SpyGen 仅在 pick_start 细化分支打印。）
"""
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "stick-world", "tools", "ai")))

import gen_trees  # noqa: E402
from generator import StrokeGenerator  # noqa: E402


class SpyGen(StrokeGenerator):
    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        self.spy_calls = 0

    def pick_start(self, imp, thresh=0.35, err_gain=0.0):
        if err_gain > 0:
            if self.spy_calls < 3 or self.spy_calls % 256 == 0:
                print(f"[spy#{self.spy_calls}] frac={self.err_frac_high:.4f} "
                      f"stop={getattr(self, 'err_stop', 0.02)}")
            self.spy_calls += 1
        return super().pick_start(imp, thresh, err_gain)


for i in [0, 1]:
    rng = np.random.default_rng(1000 * gen_trees.KIND_OFFSET["tree"] + i)
    s = gen_trees.gen_tree_struct(rng, 384, 672)
    W, H = 384, 672
    img = np.asarray(gen_trees.render_crown_ref(s, W, H)).astype(np.float32)
    mask = np.asarray(gen_trees.render_crown_mask(s, W, H)).astype(np.float32) / 255.0
    k = max(W, H) / 256.0
    layers = [dict(l, w0=l["w0"] * k, w1=l["w1"] * k, ln=l["ln"] * k)
              for l in gen_trees.THIN_LAYERS]
    spirals = [(b["c"][0], b["c"][1], b["r"] * 1.30, 0.55) for b in s["blobs"]]
    gen = SpyGen(img, 3400, layers=layers, spirals=spirals, mask=mask)
    blocks, got = gen.run()
    print(f"[spy] tree{i} 实际层笔数: "
          + ", ".join(f"{n}×{len(st)}" for n, st in blocks) + f" 共{got}")
