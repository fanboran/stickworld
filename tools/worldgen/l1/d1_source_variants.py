"""D1「源流带视觉去留」三版对比图 —— 待创始人看图拍板（水陆同源方案 §五 D1）。

源流（SOURCE 群系）= biome_generate.apply_source 在河湖沿岸画的浅蓝膨胀带
（(95,160,195)，band 1px@2048 → 4px@8192），视觉上与真水同色——是「色块与地图
不严丝合缝」真因之一（颜色判水把它当水）。D1 未决，本脚本在出生包窗口出三版：

  A 现状    ：labels8 原样（浅蓝带 4px@8192，与真水同色）
  B 改湿地色：SOURCE 基色换湿地绿（100,150,95）【提案色，待拍板】——「蓝=水」
              全图成立的最省改法（biome_generate 一处色值 + 重烘地形）
  C 收窄    ：带收窄到贴水 2px@8192，带外还原最近群系（EDT 回填）——保留「沿岸
              湿润感」但不再读作水

渲法与 l1_terrain_bake 同管线（复用其 fields/render_window；湖输入 = 精细湖
光栅同源），输出 output/d1_source_variants/（出生包整窗三张 + 河岸特写放大 +
横拼总览）。

用法：python tools/worldgen/l1/d1_source_variants.py
"""
import json
import os
import sys

import numpy as np
from PIL import Image
from scipy.ndimage import binary_dilation, distance_transform_edt

HERE = os.path.dirname(os.path.abspath(__file__))
L3_DIR = os.path.join(os.path.dirname(HERE), "l3")
L1_BAKE = HERE
sys.path.insert(0, L3_DIR)
sys.path.insert(0, L1_BAKE)
import terrain_render as tr  # noqa: E402
import l1_terrain_bake as ltb  # noqa: E402

OUTPUT_DIR = tr.OUTPUT_DIR
CONFIG_DIR = tr.CONFIG_DIR
OUT_DIR = os.path.join(OUTPUT_DIR, "d1_source_variants")
SOURCE = tr.SOURCE   # 5
## 变体 B 湿地绿【提案色，D1 拍板后若采纳再进 biome_generate】
WETLAND_COLOR = (100, 150, 95)
## 变体 C 带宽（8192 原生 px；现状 = 1px@2048 ×4 = 4px）
BAND_NARROW_PX = 2


def build_fields_refined():
    """l1_terrain_bake.main 同款 fields（湖 = 精细湖光栅，与包内数据同源）。"""
    p = ltb.load_params()
    lp = p["l1"]
    elev, land, lake, river, labels8, hot8 = tr.load_inputs()
    lake_path = os.path.join(OUTPUT_DIR, "refined_lake_mask_8192.npy")
    if not os.path.exists(lake_path):
        print("错误：缺 %s（先跑精细湖光栅产出）" % lake_path)
        sys.exit(1)
    lake = np.load(lake_path).astype(bool)
    print("  湖输入 = refined 湖光栅（%d px）" % int(lake.sum()), flush=True)
    shade, ocean_edt, lake_in, coast_dark, river_a = tr.build_fields(elev, land, lake, river, p)
    colors = {
        "rock": np.array(p["colors"]["rock"], dtype=np.float32),
        "snow": np.array(p["colors"]["snow"], dtype=np.float32),
        "ocean_near": np.array(p["colors"]["ocean_near"], dtype=np.float32),
        "ocean_far": np.array(p["colors"]["ocean_far"], dtype=np.float32),
        "lake": np.array(p["colors"]["lake"], dtype=np.float32),
        "river": np.array(p["colors"]["river"], dtype=np.float32),
    }
    fields = {"labels8": labels8, "elev": elev, "land": land, "lake": lake,
              "shade": shade, "ocean_edt": ocean_edt.astype(np.float32),
              "lake_in": lake_in.astype(np.float32), "coast_dark": coast_dark,
              "river_a": river_a, "hot8": hot8, "p": p}
    return fields, colors, lp


def labels_narrow_band(labels8, land, lake, river):
    """变体 C：SOURCE 带收窄到贴水 BAND_NARROW_PX，带外按 EDT 最近群系还原。"""
    water = lake | river
    src_mask = labels8 == SOURCE
    band = binary_dilation(water, iterations=BAND_NARROW_PX) & land & ~water
    outside = src_mask & ~band
    out = labels8.copy()
    if outside.any():
        ref = labels8.copy()
        ref[src_mask] = 0   # 源流带当洞，EDT 找最近非源流群系
        _, idx = distance_transform_edt(ref == 0, return_indices=True)
        vals = labels8[idx[0], idx[1]]
        out[outside] = vals[outside]
    print("  变体C：源流带 %d px → 收窄 %d px（还原 %d px）"
          % (int(src_mask.sum()), int((src_mask & band).sum()), int(outside.sum())))
    return out


def main():
    with open(os.path.join(CONFIG_DIR, "l1_world.json"), encoding="utf-8") as f:
        world = json.load(f)
    wo = world["world_origin"]
    side = int(world["context_size"][0])
    x0, y0 = int(wo[0]), int(wo[1])
    sl = (slice(y0, y0 + side), slice(x0, x0 + side))
    os.makedirs(OUT_DIR, exist_ok=True)

    print("[1/3] 加载全局场（精细湖同源）...", flush=True)
    fields, colors, lp = build_fields_refined()
    labels8 = fields["labels8"]

    print("[2/3] 三版渲染...", flush=True)
    imgs = {}
    # A 现状
    imgs["a_current"] = ltb.render_window(sl, fields, colors, lp["biome_blend_sigma"])
    # B 湿地色（改 LUT 基色，渲完改回）
    orig = tr.BIOME_COLORS[SOURCE]
    tr.BIOME_COLORS[SOURCE] = WETLAND_COLOR
    imgs["b_wetland"] = ltb.render_window(sl, fields, colors, lp["biome_blend_sigma"])
    tr.BIOME_COLORS[SOURCE] = orig
    # C 收窄（改 labels8，渲完还原）
    lab_saved = fields["labels8"]
    fields["labels8"] = labels_narrow_band(labels8, fields["land"], fields["lake"],
                                           fields["river_a"] > 0.05).astype(np.uint8)
    imgs["c_narrow"] = ltb.render_window(sl, fields, colors, lp["biome_blend_sigma"])
    fields["labels8"] = lab_saved

    print("[3/3] 写图...", flush=True)
    for name, arr in imgs.items():
        Image.fromarray(arr).save(os.path.join(OUT_DIR, "l1_69_source_%s.png" % name))

    # 河岸特写（找窗口内河岸边一点，裁 240² 放大 3×——源流带最宽处观察）
    river_win = (fields["river_a"][sl] > 0.05)
    src_win = labels8[sl] == SOURCE
    band2 = binary_dilation(river_win, iterations=2)
    probe = (src_win & ~band2)          # 收窄版会还原的像素（=带最厚处）
    ys, xs = np.where(probe)
    crop_side = 240
    if len(ys):
        cy, cx = int(np.median(ys)), int(np.median(xs))
        cy = max(0, min(cy - crop_side // 2, side - crop_side))
        cx = max(0, min(cx - crop_side // 2, side - crop_side))
        zooms = []
        for name, arr in imgs.items():
            z = Image.fromarray(arr[cy:cy + crop_side, cx:cx + crop_side])
            zooms.append(z.resize((crop_side * 3, crop_side * 3), Image.NEAREST))
        total = Image.new("RGB", (crop_side * 3 * 3, crop_side * 3))
        for i, z in enumerate(zooms):
            total.paste(z, (i * crop_side * 3, 0))
        total.save(os.path.join(OUT_DIR, "l1_69_source_zoom_triptych.png"))
        print("  特写 @ 窗内 (%d,%d)+%d（3× 放大，A|B|C 横拼）" % (cx, cy, crop_side))

    # 整窗横拼总览（缩到 512²/版）
    ov = Image.new("RGB", (512 * 3, 512))
    for i, (name, arr) in enumerate(imgs.items()):
        ov.paste(Image.fromarray(arr).resize((512, 512), Image.LANCZOS), (i * 512, 0))
    ov.save(os.path.join(OUT_DIR, "l1_69_source_overview_triptych.png"))
    print("完成 -> %s" % OUT_DIR)


if __name__ == "__main__":
    main()
