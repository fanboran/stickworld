# -*- coding: utf-8 -*-
"""出生点所在 L2 地区特写：region 窗口地形 + 各城 ps 档剪影 + 出生城高亮。

用法：python tools/worldgen/l1/spawn_l2_closeup.py   # 地区由 output/_spawn_region.json 指定
"""
import json
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw
from shapely.geometry import Polygon

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.argv = [sys.argv[0]]
import blob_v2_generate as g   # 场叠加管线同源（ps 档 = 每城自身规模）

OUTPUT_DIR = os.path.join(os.path.dirname(HERE), "output")

def main():
    reg = json.load(open(os.path.join(OUTPUT_DIR, "_spawn_region.json"), encoding="utf-8"))
    bb = reg["bbox"]
    sx, sy = reg["spawn"]
    x0, y0, x1, y1 = float(bb["x0"]), float(bb["y0"]), float(bb["x1"]), float(bb["y1"])

    p = json.load(open(g.PARAMS_PATH, encoding="utf-8"))
    grad, water, land = g.load_inputs()
    cities, _ = g.load_cities()
    ctx = {"world": {"grad": grad, "water": water, "land": land}, "terrain_img": None}
    old = json.load(open(os.path.join(g.GAME_DIR, "blob_params.json"), encoding="utf-8"))
    lv_bands = {int(k): (float(v["base"]), float(v["g_max"])) for k, v in old["levels"].items()}

    # 地区窗口内的城
    in_reg = [c for c in cities.values() if x0 - 150 <= c["wx"] < x1 + 150 and y0 - 150 <= c["wy"] < y1 + 150]
    print("[closeup] %s：窗口 %dx%d，城 %d 座" % (reg["region"], x1 - x0, y1 - y0, len(in_reg)))

    # 画布：窗口 → 2048 宽
    W = 2048
    k = W / float(x1 - x0)
    H = int((y1 - y0) * k)
    terr = Image.open(os.path.join(OUTPUT_DIR, "l3_terrain.png")).convert("RGB")
    ts = terr.size[0] / 8192.0
    crop = terr.crop((int(x0 * ts), int(y0 * ts), math.ceil(x1 * ts), math.ceil(y1 * ts)))
    img = crop.resize((W, H), Image.LANCZOS)
    dr = ImageDraw.Draw(img, "RGBA")

    # 各城 ps 档剪影
    n_blob = 0
    for c in sorted(in_reg, key=lambda c: c["ps"], reverse=True):
        fbm_cache = {}
        mask, info, (ox, oy) = g.city_field_mask(c, float(c["ps"]), 9, ctx, p, lv_bands, fbm_cache, None)
        if not mask.any():
            continue
        polys = g.mask_to_polys(mask, c["sid"], ox, oy, p, info.get("scale", 1.0))
        polys, _cut = g.clip_polys_to_tile(polys, c, p["contour"])
        is_spawn = c["sid"] == "settlement_city_427"
        for outer, holes in polys:
            pts = [((px - x0) * k, (py - y0) * k) for px, py in outer]
            if is_spawn:
                dr.polygon(pts, fill=(255, 120, 90, 200), outline=(120, 20, 10, 255))
            else:
                dr.polygon(pts, fill=(198, 188, 170, 200), outline=(70, 62, 50, 255))
            for h in holes:
                hp = [((px - x0) * k, (py - y0) * k) for px, py in h]
                dr.polygon(hp, fill=(0, 0, 0, 0))
        if polys:
            n_blob += 1
    print("  剪影 %d 座" % n_blob)

    # L2 窗口框 + 出生城标记
    dr.rectangle([1, 1, W - 2, H - 2], outline=(255, 255, 255, 120), width=2)
    mx, my = (sx - x0) * k, (sy - y0) * k
    for r, col in ((26, (255, 80, 60, 90)), (7, (255, 80, 60, 200))):
        dr.ellipse([mx - r, my - r, mx + r, my + r], outline=col, width=3)
    dr.text((mx + 32, my - 10), "关洋湾（出生点·lv2·ps0.29）", fill=(255, 235, 220, 255))

    dst = os.path.join(OUTPUT_DIR, "spawn_l2_closeup.png")
    img.save(dst)
    print("  →", dst)

if __name__ == "__main__":
    main()
