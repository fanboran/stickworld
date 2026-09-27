# -*- coding: utf-8 -*-
"""旧 blob 管线 · V2 世界预览（验收 E 图专用）

复用现行径向容量管线的全部形状公式（blob_bake.py：16 方向地形容量 + DJB2
抖动 + levels/gamma 参数），只把数据源从游戏包（旧世界 l1_world.json）换成
V2 生成端 settlements_v2.json（1042 聚落，8192 世界坐标）——出旧管线观感的
E1/E2 验收图，不写任何游戏数据。

用法：
  python tools/worldgen/l1/blob_preview_v2world.py
"""
import json
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import blob_bake   # noqa: E402  现行管线（形状公式单一真相源）

WORLDGEN = os.path.dirname(HERE)
OUTPUT_DIR = os.path.join(WORLDGEN, "output")
SETTLE_PATH = os.path.join(OUTPUT_DIR, "fields", "settlements_v2.json")


def probe_caps(params, anchors):
    """16 方向地形容量（与 blob_bake.bake_all 同式，数据源换 anchors）。"""
    k = int(params["K"])
    slope_ref = float(params["slope_ref"])
    probe_r = int(params["probe_radius"])
    step = int(params["probe_step"])
    water_river = float(params["water_cap"]["river_lake"])
    water_sea = float(params["water_cap"]["sea"])
    jit_base = float(params["jitter"]["base"])
    jit_amp = float(params["jitter"]["amp"])

    height = np.load(os.path.join(OUTPUT_DIR, "fractal_heightmap_8192.npy")).astype(np.float32)
    hgy, hgx = np.gradient(height)
    grad_mag = np.sqrt(hgx * hgx + hgy * hgy)
    river = np.array(Image.open(os.path.join(OUTPUT_DIR, "fractal_river_mask_8192.png")).convert("L")) > 127
    lake = np.array(Image.open(os.path.join(OUTPUT_DIR, "fractal_lake_mask_8192.png")).convert("L")) > 127
    land = np.array(Image.open(os.path.join(OUTPUT_DIR, "locked", "locked_continent_8192.png")).convert("L")) > 127
    water_rl = river | lake
    size = height.shape[0]

    caps, anchors_xy = {}, {}
    for sid, a in anchors.items():
        if str(a["level"]) not in params["levels"]:
            continue   # level 0 原址点：旧管线无此级，图上按锚点小圆处理
        cx, cy = a["wx"], a["wy"]
        anchors_xy[sid] = (cx, cy)
        lv_cfg = params["levels"][str(a["level"])]
        lv_base, lv_gmax = float(lv_cfg["base"]), float(lv_cfg["g_max"])
        r_start = max(int(lv_base), 4)
        r_end = min(int(lv_base + lv_gmax) + 2, probe_r)
        out = []
        for i in range(k):
            theta = math.tau * i / k
            dx, dy = math.cos(theta), math.sin(theta)
            max_g, water = 0.0, 1.0
            for r in range(r_start, r_end, step):
                x = int(round(cx + dx * r))
                y = int(round(cy + dy * r))
                if x < 1 or y < 1 or x >= size - 1 or y >= size - 1:
                    water = water_sea
                    break
                if not land[y, x]:
                    water = water_sea
                    break
                if water_rl[y, x]:
                    water = water_river
                    break
                g = float(grad_mag[y, x])
                if g > max_g:
                    max_g = g
            slope_cap = max(0.0, min(1.0, 1.0 - max_g / slope_ref))
            jitter = jit_base + jit_amp * blob_bake.hash01("%s#%d" % (sid, i))
            out.append(round(slope_cap * water * jitter, 4))
        caps[sid] = out
    return caps, anchors_xy


def main():
    params = blob_bake.load_params()
    st = json.load(open(SETTLE_PATH, encoding="utf-8"))["settlements"]
    params = blob_bake.load_params()
    anchors = {s["settlement_id"]: {"wx": float(s["x"]), "wy": float(s["y"]),
                                    "level": int(s["level"]),
                                    "ps": float(s.get("population_score", 0.0))}
               for s in st if str(int(s["level"])) in params["levels"]}
    print("[blob-v2w] %d 聚落，探测容量 ..." % len(anchors))
    caps, anchors_xy = probe_caps(params, anchors)

    # E1 全图：地形底 + T3 城 blob（s=population_score）+ 其余锚点
    terrain = Image.open(os.path.join(OUTPUT_DIR, "l3_terrain.png")).convert("RGB")
    ts = terrain.size[0]
    scale = ts / 8192.0
    img = terrain.copy()
    dr = ImageDraw.Draw(img, "RGBA")
    n_blob = 0
    for sid, a in anchors.items():
        cx, cy = anchors_xy[sid][0] * scale, anchors_xy[sid][1] * scale
        if a["level"] >= 3 and a["ps"] > 0.0:
            outline = blob_bake.blob_outline(sid, a["level"], caps[sid], a["ps"], params)
            pts = [(cx + p[0] * scale, cy + p[1] * scale) for p in outline]
            dr.polygon(pts, fill=(120, 110, 100, 160), outline=(60, 52, 44, 255))
            n_blob += 1
        else:
            dr.ellipse([cx - 1.5, cy - 1.5, cx + 1.5, cy + 1.5], fill=(230, 225, 215, 200))
    dst = os.path.join(OUTPUT_DIR, "blob_preview_2048.png")
    img.save(dst)
    print("  %s（%d 个 T3 blob）" % (dst, n_blob))

    # E2 特写：出生城 + 容量跨度最大的三城（山城/水城代表）
    def cap_span(sid):
        c = caps[sid]
        return max(c) - min(c)

    sids = [s for s in caps if anchors[s]["level"] >= 3]
    sids.sort(key=cap_span, reverse=True)
    spawn = "settlement_city_427"
    picks = [spawn] + sids[:3]
    tiles = []
    for sid in picks:
        cx, cy = anchors_xy[sid]
        tile = Image.new("RGB", (512, 512), (10, 10, 10))
        tdr = ImageDraw.Draw(tile, "RGBA")
        lx, ly = 256.0, 256.0
        for s, col in ((0.2, (255, 220, 90, 255)), (0.5, (90, 200, 255, 255)), (0.9, (255, 120, 90, 255))):
            outline = blob_bake.blob_outline(sid, anchors[sid]["level"], caps[sid], s, params)
            pts = [(lx + p[0], ly + p[1]) for p in outline] + [(lx + outline[0][0], ly + outline[0][1])]
            tdr.line(pts, fill=col, width=2)
        for i in range(16):
            th = math.tau * i / 16
            r_in, r_out = 40, 40 + 60 * caps[sid][i]
            tdr.line([(lx + r_in * math.cos(th), ly + r_in * math.sin(th)),
                      (lx + r_out * math.cos(th), ly + r_out * math.sin(th))],
                     fill=(255, 255, 255, 180), width=2)
        tiles.append(tile)
    out = Image.new("RGB", (1024, 1024), (10, 10, 10))
    for i, tile in enumerate(tiles):
        out.paste(tile, ((i % 2) * 512, (i // 2) * 512))
    dst2 = os.path.join(OUTPUT_DIR, "blob_closeup.png")
    out.save(dst2)
    print("  %s（%s 等 4 城，黄 s=0.2 / 青 s=0.5 / 红 s=0.9）" % (dst2, spawn))


if __name__ == "__main__":
    main()
