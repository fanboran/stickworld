"""political_mesh 湖区 1:1 特写渲染（验证湖面与城块洞零缝隙）。

用法：
  python render_lake_closeup.py <cx> <cy> <w> [out.png]
  从 l3_political_mesh.json 取 fill 三角形画窗口 (cx,cy) 边长 w。
"""
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MESH = os.path.normpath(os.path.join(
    HERE, "..", "..", "stick-world", "config", "strategic_map",
    "l3_political_mesh.json"))
OUT_DIR = os.path.join(HERE, "output")

# 政权色（与截图大致对应即可；湖/海固定）
LAKE = (72, 116, 158)
SEA = (30, 55, 95)
FREE = (110, 110, 110)


def state_colors():
    d = json.load(open(os.path.normpath(os.path.join(
        HERE, "..", "..", "stick-world", "config", "strategic_map",
        "l3_city.json")), encoding="utf-8"))
    lut = {}
    for sid, info in d.get("states", {}).items():
        lut[int(info.get("lut_index", 0))] = tuple(info.get("color", [200, 200, 200]))
    return lut


def main():
    cx, cy, w = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
    dst = sys.argv[4] if len(sys.argv) > 4 else os.path.join(
        OUT_DIR, "_lake_closeup.png")
    print("载入 mesh ...")
    mesh = json.load(open(MESH, encoding="utf-8"))
    fv = mesh["fill_verts"]
    fc = mesh["fill_code"]
    fi = np.array(mesh["fill_idx"], dtype=np.int64)
    lut = state_colors()
    lut[253] = FREE
    lut[254] = LAKE

    img = Image.new("RGB", (w, w), SEA)
    dr = ImageDraw.Draw(img)
    x0, y0 = cx - w // 2, cy - w // 2
    # 三角形粗裁剪：任一顶点在窗口内（含 8px 余量）
    xs = np.array([p[0] for p in fv], dtype=np.float64)
    ys = np.array([p[1] for p in fv], dtype=np.float64)
    t0, t1, t2 = fi[0::3], fi[1::3], fi[2::3]
    in_win = ((xs[t0] >= x0 - 8) & (xs[t0] < x0 + w + 8) & (ys[t0] >= y0 - 8) & (ys[t0] < y0 + w + 8)) | \
             ((xs[t1] >= x0 - 8) & (xs[t1] < x0 + w + 8) & (ys[t1] >= y0 - 8) & (ys[t1] < y0 + w + 8)) | \
             ((xs[t2] >= x0 - 8) & (xs[t2] < x0 + w + 8) & (ys[t2] >= y0 - 8) & (ys[t2] < y0 + w + 8))
    for ti in np.where(in_win)[0]:
        c = lut.get(int(fc[fi[3 * ti]]))
        if c is None:
            continue
        tri = [(xs[fi[3 * ti]] - x0, ys[fi[3 * ti]] - y0),
               (xs[fi[3 * ti + 1]] - x0, ys[fi[3 * ti + 1]] - y0),
               (xs[fi[3 * ti + 2]] - x0, ys[fi[3 * ti + 2]] - y0)]
        dr.polygon(tri, fill=c)
    img.save(dst)
    print("预览 %s（世界窗口 x[%d..%d] y[%d..%d]）" % (dst, x0, x0 + w, y0, y0 + w))


if __name__ == "__main__":
    main()
