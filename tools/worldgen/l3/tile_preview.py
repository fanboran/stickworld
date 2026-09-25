# -*- coding: utf-8 -*-
"""地块版政治预览（V2-属性层）——既有 1048 地块多边形直接填色：
有主=政权色（PoliticalLut 同源 states.color）/ 无主（规模 0 荒芜）= 灰。
一块地一个颜色、拼满无孔、无任何圆形记号（创始人定稿表达）。
用法：python tile_preview.py
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
OUT = fc.OUTPUT_DIR
S = 2048
GRAY = (128, 118, 100)
SEA = (22, 33, 52)


def main():
    font = fc.fit_font(20)
    pol = json.load(open(os.path.join(FIELDS, "political_data_v2.json"), encoding="utf-8"))
    meta = json.load(open(os.path.join(FIELDS, "tile_meta.json"), encoding="utf-8"))
    owners = pol["city_owners"]
    st_col = {sid: tuple(v["color"]) for sid, v in pol["states"].items()}

    img = Image.new("RGB", (S, S), SEA)
    dr = ImageDraw.Draw(img)
    K = S / fc.SIZE_FULL
    packs = {}
    n_paint = 0
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
        lbl = m["label"]
        sid = owners.get("settlement_city_%03d" % m.get("live_label", lbl))
        col = st_col.get(sid, GRAY) if sid else GRAY
        pts = [((float(p[0]) + wo[0]) * K, (float(p[1]) + wo[1]) * K) for p in poly]
        dr.polygon(pts, fill=col)
        n_paint += 1
    print("填色地块:", n_paint)

    # 都城标记（小圈，非圆盘——只标点位）
    for sid, v in pol["states"].items():
        for m in meta:
            if m.get("live_label") and "settlement_city_%03d" % m["live_label"] == v["capital"]:
                x, y = m["x"] * K, m["y"] * K
                dr.ellipse([x - 3, y - 3, x + 3, y + 3], outline=(255, 255, 255),
                           width=2, fill=(20, 20, 24))
                break

    canvas = Image.new("RGB", (S + 380, S), (14, 16, 22))
    canvas.paste(img, (0, 0))
    d2 = ImageDraw.Draw(canvas)
    d2.text((S + 16, 14), "V2 属性层政治图（既有 1048 地块网格）", font=font, fill=(235, 235, 235))
    d2.text((S + 16, 44), "有主=政权色 · 无主=灰 · 一地块一色", font=font, fill=(200, 200, 200))
    live_sorted = sorted(pol["states"].values(), key=lambda v: -v["n_cities"])
    y = 80
    for v in live_sorted[:26]:
        c = st_col[v["name"]] if False else tuple(v["color"])
        d2.rectangle([S + 16, y, S + 16 + 18, y + 12], fill=c)
        d2.text((S + 42, y - 3), "%s·%d" % (v["name"], v["n_cities"]), font=font,
                fill=(225, 225, 225))
        y += 22
    dst = os.path.join(FIELDS, "tile_world_political_2048.png")
    canvas.save(dst)
    print("→", dst)


if __name__ == "__main__":
    main()
