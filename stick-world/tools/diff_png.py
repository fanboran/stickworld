#!/usr/bin/env python3
"""像素级 A/B diff：比对两张截图，输出差异统计 + 热点簇 + 放大热图。

用法：python tools/diff_png.py [a.png b.png] [--tol=N] [--out=diff.png]
默认比对 stick-world/tests/dev/bar_ab_rich.png 与 bar_ab_crowd.png（bar_probe
双跑产物）。tol=0 即逐像素严格一致；热图红通道 = 差异×16 放大，绿框标出
超容差差异簇的包围盒。
"""
import sys
from collections import Counter

import numpy as np
from PIL import Image


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    tol = 0
    out = None
    for a in sys.argv[1:]:
        if a.startswith("--tol="):
            tol = int(a.split("=", 1)[1])
        elif a.startswith("--out="):
            out = a.split("=", 1)[1]
    a_path = args[0] if args else "stick-world/tests/dev/bar_ab_rich.png"
    b_path = args[1] if len(args) > 1 else "stick-world/tests/dev/bar_ab_crowd.png"
    if out is None:
        out = b_path.rsplit(".", 1)[0] + "_diff.png"

    A = np.asarray(Image.open(a_path).convert("RGB"), dtype=np.int16)
    B = np.asarray(Image.open(b_path).convert("RGB"), dtype=np.int16)
    if A.shape != B.shape:
        print(f"FAIL 尺寸不同: {A.shape} vs {B.shape}")
        return 1

    d = np.abs(A - B).max(axis=2)
    n_over = int((d > tol).sum())
    print(f"尺寸 {A.shape[1]}x{A.shape[0]}  tol={tol}")
    print(f"差异像素(>0)={int((d > 0).sum())}  (>{tol})={n_over}  max={int(d.max())}")

    heat = np.zeros((*d.shape, 3), dtype=np.uint8)
    heat[..., 0] = np.clip(d.astype(np.int32) * 16, 0, 255)

    if n_over == 0:
        Image.fromarray(heat).save(out)
        print(f"PASS 逐像素一致 ✓  热图: {out}")
        return 0

    ys, xs = np.nonzero(d > tol)
    print(f"差异范围: x {int(xs.min())}-{int(xs.max())}  y {int(ys.min())}-{int(ys.max())}")
    cells = Counter(zip((ys // 32).tolist(), (xs // 32).tolist()))
    print("热点簇(32px 格，前 12):")
    for (cy, cx), cnt in cells.most_common(12):
        m = (ys // 32 == cy) & (xs // 32 == cx)
        cell_d = d[ys[m], xs[m]]
        print(f"  cell({int(cx) * 32},{int(cy) * 32}) 像素={cnt} "
              f"max={int(cell_d.max())} y[{int(ys[m].min())}-{int(ys[m].max())}] x[{int(xs[m].min())}-{int(xs[m].max())}]")
    # 超容差簇包围盒画绿框
    heat[..., 1] = 0
    for (cy, cx) in cells:
        y0, x0 = cy * 32, cx * 32
        heat[y0:y0 + 2, x0:x0 + 32, 1] = 255
        heat[y0 + 30:y0 + 32, x0:x0 + 32, 1] = 255
        heat[y0:y0 + 32, x0:x0 + 2, 1] = 255
        heat[y0:y0 + 32, x0 + 30:x0 + 32, 1] = 255
    Image.fromarray(heat).save(out)
    print(f"FAIL 有 {n_over} 像素超容差  热图: {out}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
