# -*- coding: utf-8 -*-
"""对齐验证用：跑 Python 基线管线（不改任何基线脚本），输出重定向到 temp，
捕获 stroke_paint 的层落笔数（"[stroke] xxx: N 笔 under×a body×b ..."）。
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "stick-world", "tools", "ai")))

import gen_trees  # noqa: E402

OUT = os.path.normpath(os.path.join(HERE, "out"))
REF = os.path.normpath(os.path.join(HERE, "ref"))
os.makedirs(OUT, exist_ok=True)
os.makedirs(REF, exist_ok=True)
# 先改输出目录再跑，绝不覆盖 assets/resources 里的已验收贴图
gen_trees.OUT_DIR = OUT
gen_trees.REF_DIR = REF

import numpy as np  # noqa: E402

for i in range(4):
    rng = np.random.default_rng(1000 * gen_trees.KIND_OFFSET["tree"] + i)
    path = gen_trees.build("tree", i, rng)
    print(f"[pycheck] tree {i} -> {path}")
print("[pycheck] done")
