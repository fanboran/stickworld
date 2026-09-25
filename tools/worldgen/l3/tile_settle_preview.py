# -*- coding: utf-8 -*-
"""地块版聚落分布图（V2-属性层）——既有 1048 地块网格上，逐地块显示聚落规模：
  规模 0（无聚落=荒芜）= 灰；村/镇/城 = 绿/黄/红（原分布图同色系）。
  地块边界描细线（网格可见），底 = 宜居度淡色。
用法：python tile_settle_preview.py
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
GAME = fc.GAME_CFG
S = 2048
GRAY = (128, 118, 100)
BORDER = (70, 62, 52)


def main():
    font = fc.fit_font(20)
    font_s = fc.fit_font(15)
    meta = json.load(open(os.path.join(FIELDS, "tile_meta.json"), encoding="utf-8"))
    settle = {s["label"]: s for s in
              json.load(open(os.path.join(FIELDS, "settlements_v2.json"),
                             encoding="utf-8"))["settlements"]}
    suit = np.load(os.path.join(FIELDS, "suitability.npy")).astype(np.float32)[::4, ::4]
    K = S / fc.SIZE_FULL
    base = fc.colormap(np.clip(suit, 0, 1), fc.HEAT_STOPS)
    base = (base.astype(np.float32) * 0.35 + 12).astype(np.uint8)
    img = Image.fromarray(base, "RGB")
    dr = ImageDraw.Draw(img)
    lv_color = {1: (120, 205, 120), 2: (240, 190, 85), 3: (240, 95, 70)}
    packs = {}
    n_dead = 0
    n_live = 0
    for m in meta:
        pk = m["pack"]
        if pk not in packs:
            pp = os.path.join(GAME, "l1_world.json" if pk == "spawn"
                              else "l1_packs/%s/l1_world.json" % pk)
            packs[pk] = json.load(open(pp, encoding="utf-8"))
        d = packs[pk]
        wo = d["world_origin"]
        t = d["tiles"][m["idx"]]
        poly = t.get("polygon") or (t.get("polygons") or [[]])[0]
        if not poly:
            continue
        pts = [((float(p[0]) + wo[0]) * K, (float(p[1]) + wo[1]) * K) for p in poly]
        s = settle.get(m.get("live_label", 0))
        if s is None:
            fill = GRAY
            n_dead += 1
        else:
            fill = tuple(int(v * 0.42 + 30) for v in lv_color[s["level"]])
            n_live += 1
        dr.polygon(pts, fill=fill, outline=BORDER)
        # 大小不一的圆点（原分布图同式 r = 2.0 + 7.5×population_score）
        x, y = m["x"] * K, m["y"] * K
        if s is not None:
            r = 2.0 + 7.5 * s["population_score"]
            dr.ellipse([x - r, y - r, x + r, y + r],
                       fill=lv_color[s["level"]],
                       outline=(255, 255, 255) if s["level"] == 3 else (18, 20, 26),
                       width=1)
        else:
            dr.ellipse([x - 1, y - 1, x + 1, y + 1], fill=(96, 90, 78))
    print("地块填色：有聚落 %d / 无聚落（灰）%d" % (n_live, n_dead))

    canvas = Image.new("RGB", (S + 400, S), (14, 16, 22))
    canvas.paste(img, (0, 0))
    d2 = ImageDraw.Draw(canvas)
    d2.text((S + 16, 14), "V2 聚落分布（既有 1048 地块网格）", font=font, fill=(235, 235, 235))
    rows = [
        ("灰 = 无聚落（规模 0，荒芜/无主）", GRAY),
        ("绿 = 村（1）", lv_color[1]),
        ("黄 = 镇（2）", lv_color[2]),
        ("红 = 城（3）", lv_color[3]),
    ]
    y = 52
    for txt, c in rows:
        d2.rectangle([S + 16, y, S + 16 + 18, y + 12], fill=c)
        d2.text((S + 42, y - 2), txt, font=font_s, fill=(222, 222, 222))
        y += 20
    d2.text((S + 16, y + 10), "点大小 = population_score（村/镇/城 绿/黄/红）；地块填色为同档淡色；灰=无聚落",
            font=font_s, fill=(180, 180, 180))
    # 输出到原文件名（创始人定稿：重做即覆盖 settlements_preview_locations_2048.png；
    # 撒点版备份为同目录 *_backup_points.png）
    dst = os.path.join(FIELDS, "settlements_preview_locations_2048.png")
    canvas.save(dst)
    print("→", dst)


if __name__ == "__main__":
    main()
