# -*- coding: utf-8 -*-
"""聚落分布图（撒点版 + 缝隙灰点，创始人编定稿式）——
底 = 宜居度淡色（陆地深灰蓝）；点 = 大小不一圆点（r = 2.0 + 7.5×ps）：
  正常聚落：绿=村 / 黄=镇 / 红=城（城白描边）
  缝隙填充点（level 0，灰色系）：灰小点（把地图填满的地块占位聚落）
输出覆盖 settlements_preview_locations_2048.png。
用法：python settle_preview_v2.py
"""
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fields_common as fc  # noqa: E402

FIELDS = fc.FIELDS_DIR
S = 2048
K_FIELD = fc.SIZE / fc.SIZE_FULL


def main():
    font = fc.fit_font(20)
    pts = json.load(open(os.path.join(FIELDS, "settlements_v2.json"),
                         encoding="utf-8"))["settlements"]
    suit = np.load(os.path.join(FIELDS, "suitability.npy")).astype(np.float32)[::4, ::4]
    biome = np.load(os.path.join(fc.OUTPUT_DIR, "biome_labels_2048.npy"))
    eff_land = biome > 0
    base = fc.colormap(np.clip(suit, 0, 1), fc.HEAT_STOPS)
    base[~eff_land] = (26, 32, 50)
    base = (base.astype(np.float32) * 0.5 + 14).astype(np.uint8)
    img = Image.fromarray(base, "RGB")
    dr = ImageDraw.Draw(img)
    lv_color = {0: (120, 114, 100), 1: (120, 205, 120), 2: (240, 190, 85),
                3: (240, 95, 70)}
    n0 = 0
    for s in sorted(pts, key=lambda t: (t["level"], t["population_score"])):
        # settlements_v2 坐标为 8192 级，×K_FIELD（0.25）降到 2048 画布
        x, y = s["x"] * K_FIELD, s["y"] * K_FIELD
        if int(s["level"]) == 0:
            r = 1.0
            dr.ellipse([x - r, y - r, x + r, y + r], fill=lv_color[0],
                       outline=(60, 56, 48))
            n0 += 1
            continue
        r = 2.0 + 7.5 * s["population_score"]
        dr.ellipse([x - r, y - r, x + r, y + r],
                   fill=lv_color[s["level"]],
                   outline=(255, 255, 255) if s["level"] == 3 else (18, 20, 26),
                   width=1)
    print("正常点 %d + 灰点 %d" % (len(pts) - n0, n0))

    canvas = Image.new("RGB", (S + 380, S), (14, 16, 22))
    canvas.paste(img, (0, 0))
    d2 = ImageDraw.Draw(canvas)
    d2.text((S + 16, 14), "聚落分布（撒点版 + 缝隙灰点）", font=font, fill=(235, 235, 235))
    rows = [("绿 = 村（1）", lv_color[1]), ("黄 = 镇（2）", lv_color[2]),
            ("红 = 城（3）", lv_color[3]),
            ("灰点 = 缝隙填充（规模 0，铺满地块用）", lv_color[0])]
    y = 52
    for txt, c in rows:
        d2.rectangle([S + 16, y, S + 16 + 16, y + 11], fill=c)
        d2.text((S + 40, y - 2), txt, font=fc.fit_font(15), fill=(222, 222, 222))
        y += 20
    dst = os.path.join(FIELDS, "settlements_preview_locations_2048.png")
    canvas.save(dst)
    print("→", dst)


if __name__ == "__main__":
    main()
