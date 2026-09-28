# -*- coding: utf-8 -*-
"""城块预览终图（refined 场渲染）——管线顺序 city_split_v3 → refine_city_labels
--write → 本脚本。city_split 自带预览画在未细化 labels 上（直边锯齿 + 细缝灰），
政治/消费端读的是 refined_city_labels_8192，验收图必须同源：refined 场 +
city_data.json 配色 + 聚落白点。陆地口径 = locked 海岸线真源（水陆同源 I1 唯一
海陆真相）——13 区地块蒙版比 locked 少边缘 fringe，拿它当海会把真陆地涂成海、
制造假岛分离；灰统计与跨陆块判据同按 locked。

用法：python tools/worldgen/l3/city_preview_from_refined.py
"""
import json
import os

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(HERE), "output", "l1_v2")
OUTER = os.path.join(os.path.dirname(HERE), "output")
RES = 8192
WASTELAND_COLOR = (120, 118, 112)   # 与 city_split_v3 同色（荒地中性灰）


def main():
    labels = np.load(os.path.join(OUT, "refined_city_labels_8192.npy"))
    cd = json.load(open(os.path.join(OUT, "city_data.json"), encoding="utf-8"))
    land = np.array(Image.open(
        os.path.join(OUTER, "locked", "locked_continent_8192.png")).convert("L")) > 127

    maxlab = int(labels.max())
    lut = np.zeros((maxlab + 1, 3), dtype=np.uint8)
    for c in cd["cities"]:
        lut[int(c["label"])] = c["rgb"]
    lut[0] = WASTELAND_COLOR

    flat = labels.ravel()
    preview = lut[flat].reshape(RES, RES, 3)
    preview[~land] = (30, 55, 95)   # 海洋底色（city_split 同款）

    img = Image.fromarray(preview)
    from PIL import ImageDraw
    dr = ImageDraw.Draw(img)
    for c in cd["cities"]:
        x, y = float(c["city"][0]), float(c["city"][1])
        dr.ellipse([x - 3, y - 3, x + 3, y + 3], outline=(12, 12, 12), width=1)
        dr.ellipse([x - 1, y - 1, x + 1, y + 1], fill=(250, 250, 250))
    dst = os.path.join(OUT, "city_preview_%d.png" % RES)
    img.save(dst)

    gray_land = int(((labels == 0) & land).sum())
    print("refined 陆地 0 区 %d px（%.3f%% 陆地）→ %s"
          % (gray_land, 100.0 * gray_land / max(int(land.sum()), 1), dst))


if __name__ == "__main__":
    main()
