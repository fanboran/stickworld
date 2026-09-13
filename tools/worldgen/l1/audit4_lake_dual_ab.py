# -*- coding: utf-8 -*-
"""审计#4 裁决材料：湖双几何（地形模式=旧湖 mask vs 政治模式=细化湖）模式切换跳动的
A/B 对比图。产出三块证据 + 一张 2×2 合成图：

  A. 现状 l1_terrain.png 裁切（地形模式，旧湖岸）
  B. A + 跳变差集叠加（红=政治模式是湖地形不是 / 蓝=地形是湖政治模式不是）
  C. 「terrain 按 refined 湖重烘」mock（方案 A 预览；scratch 目录，不动游戏文件）
  D. C + 同款差集叠加（应近乎空 → 与政治模式对齐证明）

差集 = 旧湖 mask XOR refined 湖光栅（mesh 同口径，reexport_political_id.build_lake_raster）。
窗口取全大陆差异最密的 1024² 处（预扫描落档 output/audit4_refined_lake_8192.npy）。

用法：python tools/worldgen/l1/audit4_lake_dual_ab.py
"""
import json
import os
import shutil
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "l3"))

import terrain_render as tr            # noqa: E402
import l1_terrain_bake as bake         # noqa: E402

OUTPUT_DIR = tr.OUTPUT_DIR
GAME_DIR = os.path.normpath(os.path.join(HERE, "..", "..", "..",
                                         "stick-world", "config", "strategic_map"))
WIN = 1024
WX, WY = 3072, 2048                    # 默认窗（海湾分歧案；可用 argv 覆盖）
PACK_JSON = os.path.join(GAME_DIR, "l1_packs", "l1_005", "l1_world.json")
OUT_NAME = "audit4_lake_dual_ab.png"
SCRATCH = os.path.join(OUTPUT_DIR, "audit4_scratch")

# 用法：audit4_lake_dual_ab.py [WX WY WIN pack_dir out_name]
if len(sys.argv) == 6:
    WX, WY, WIN = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
    PACK_JSON = os.path.join(GAME_DIR, "l1_packs", os.path.basename(sys.argv[4]), "l1_world.json") \
        if sys.argv[4] != "spawn" else os.path.join(GAME_DIR, "l1_world.json")
    OUT_NAME = sys.argv[5]
    SCRATCH = os.path.join(OUTPUT_DIR, "audit4_scratch_" + os.path.basename(OUT_NAME))


def load_font(size):
    for fp in (r"C:\Windows\Fonts\msyh.ttc", r"C:\Windows\Fonts\simhei.ttf"):
        if os.path.exists(fp):
            return ImageFont.truetype(fp, size)
    return ImageFont.load_default()


def crop_local(img_arr):
    """per-pack 局部贴图：世界窗转包内局部坐标裁切"""
    return img_arr[WY - bake_y0:WY - bake_y0 + WIN, WX - bake_x0:WX - bake_x0 + WIN]


def crop_world_arr(mask):
    """世界系数组：窗口直裁"""
    return mask[WY:WY + WIN, WX:WX + WIN]


def main():
    p = bake.load_params()
    lp = p["l1"]
    colors = {k: np.array(p["colors"][k], dtype=np.float32)
              for k in ("rock", "snow", "ocean_near", "ocean_far", "lake", "river")}

    global bake_x0, bake_y0
    w = json.load(open(PACK_JSON, encoding="utf-8"))
    bake_x0, bake_y0 = int(w["world_origin"][0]), int(w["world_origin"][1])
    print("演示包 %s origin=(%d,%d)，裁世界窗 (%d,%d)+%d"
          % (os.path.basename(os.path.dirname(PACK_JSON)), bake_x0, bake_y0, WX, WY, WIN))

    # ---- 现状地形（旧湖）裁切 ----
    terr_cur = np.array(Image.open(os.path.join(os.path.dirname(PACK_JSON),
                                                "l1_terrain.png")).convert("RGB"))
    crop_a = crop_local(terr_cur)

    # ---- 差集（世界系）----
    old_lake = np.array(Image.open(os.path.join(OUTPUT_DIR,
                          "fractal_lake_mask_8192.png")).convert("L")) > 127
    new_lake = np.load(os.path.join(OUTPUT_DIR, "audit4_refined_lake_8192.npy"))
    land = np.array(Image.open(os.path.join(tr.LOCKED_DIR,
                    "locked_continent_8192.png")).convert("L")) > 127
    # 三类分歧：陆上真跳变（水↔陆）红/蓝；海上湖/海渲染类型分歧（政治判湖 vs 地形按海画）橙
    red = new_lake & ~old_lake & land
    blue = old_lake & ~new_lake & land
    orange = new_lake & ~old_lake & ~land
    # 岸线位移量级：红像素（新湖超出旧岸）距旧湖的距离 / 蓝像素（旧湖多余）距新湖的距离
    from scipy import ndimage as ndi
    d_to_old = ndi.distance_transform_edt(~old_lake)   # 非旧湖像素 → 最近旧湖像素距离
    d_to_new = ndi.distance_transform_edt(~new_lake)
    disp = np.concatenate([d_to_old[red], d_to_new[blue]]) if (red | blue).any() else np.zeros(1)
    print("陆上真跳变 %d（红 %d / 蓝 %d）岸线位移 median %.1f / p95 %.1f；海上湖/海分歧 %d"
          % ((red | blue).sum(), red.sum(), blue.sum(),
             float(np.median(disp)), float(np.percentile(disp, 95)), int(orange.sum())))

    # ---- 方案 A mock：terrain 按 refined 湖重烘（scratch，不动游戏文件）----
    print("[mock] build_fields（refined 湖）+ bake_pack ...", flush=True)
    elev, land, _lake_old, river, labels8, hot8 = tr.load_inputs()
    shade, ocean_edt, lake_in, coast_dark, river_a = tr.build_fields(
        elev, land, new_lake, river, p)
    fields = {"labels8": labels8, "elev": elev, "land": land, "lake": new_lake,
              "shade": shade, "ocean_edt": ocean_edt.astype(np.float32),
              "lake_in": lake_in.astype(np.float32), "coast_dark": coast_dark,
              "river_a": river_a, "hot8": hot8, "p": p}
    os.makedirs(SCRATCH, exist_ok=True)
    scratch_json = os.path.join(SCRATCH, "l1_world.json")
    shutil.copy(PACK_JSON, scratch_json)
    bake.bake_pack(scratch_json, fields, colors, lp, "l1_terrain.png")
    terr_new = np.array(Image.open(os.path.join(SCRATCH, "l1_terrain.png")).convert("RGB"))
    crop_c = crop_local(terr_new)

    # ---- 合成 2×2 ----
    def overlay(base_arr):
        im = base_arr.astype(np.float32).copy()
        im[crop_world_arr(red), :] = im[crop_world_arr(red), :] * 0.55 + np.array([220, 40, 40]) * 0.45
        im[crop_world_arr(blue), :] = im[crop_world_arr(blue), :] * 0.55 + np.array([50, 80, 230]) * 0.45
        im[crop_world_arr(orange), :] = im[crop_world_arr(orange), :] * 0.5 + np.array([240, 150, 30]) * 0.5
        return im.astype(np.uint8)

    # D = 重烘实际改动（C vs A 渲染差异，绿标）：湖岸窗=重烘生效的 fringe；
    # 海湾窗=近乎空 → 证明「仅重烘 terrain 湖 mask」修不了陆/海分类分歧
    changed = np.abs(crop_c.astype(np.int16) - crop_a.astype(np.int16)).sum(axis=2) > 6
    crop_d = crop_c.copy()
    crop_d[changed] = crop_d[changed] * 0.4 + np.array([80, 220, 80]) * 0.6
    panels = [
        (crop_a, "A 现状地形（旧湖岸）"),
        (overlay(crop_a), "B 分歧叠加（红/蓝=陆上水陆跳变 橙=政治判湖地形按海）"),
        (crop_c, "C 方案A预览：terrain 按 refined 湖重烘"),
        (crop_d, "D 重烘实际改动（绿=与现状不同）"),
    ]
    S = 512   # 每格显示边长
    pad, cap = 6, 30
    W2 = S * 2 + pad * 3
    H2 = (S + cap) * 2 + pad * 3
    out = Image.new("RGB", (W2, H2), (18, 18, 18))
    dr = ImageDraw.Draw(out)
    font = load_font(17)
    for i, (arr, label) in enumerate(panels):
        im = Image.fromarray(arr).resize((S, S), Image.LANCZOS)
        px = pad + (i % 2) * (S + pad)
        py = pad + (i // 2) * (S + cap + pad)
        out.paste(im, (px, py))
        dr.text((px + 4, py + S + 6), label, fill=(235, 235, 235), font=font)
    path = os.path.join(OUTPUT_DIR, OUT_NAME)
    out.save(path)
    print("完成：%s" % path)


if __name__ == "__main__":
    main()
