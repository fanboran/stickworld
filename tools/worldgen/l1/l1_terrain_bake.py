"""L1 地形底图烘焙 —— R9 静态层烘焙化基建（观感返工 §R9，先地形单一模式打通）

对 70 份 L1 包（出生 1 + 批量 69）各产一张 l1_terrain.png：
按包内 world_origin（8192 全局 [x,y]）+ context_size 裁窗 → B2 同管线分层合成
（群系基色 / 高度明度·岩石·雪线 / hillshade / 海洋离岸渐变 / 海岸暗线 / 河湖）
→ 8192 原生分辨率（1:1，无降采样）写入各包目录。

着色与 tools/worldgen/l3/terrain_render.py（B2 已验收）同一代码路径：
  import terrain_render 复用其 load_inputs / build_fields / render_block，
  参数经 l1_terrain_params.json 的 inherits 字段继承 terrain_params.json
  （单一真相源：B2 调参后本工具重跑即同源）。

L1 特有差异（相对 L3/L2 全图渲染）：
  1. 群系基色柔化（biome_blend_sigma）：群系标签是 2048 级 ×4 块状映射，
     8192 原生输出时边界呈 4px 台阶——仅对 LUT 基色层做小 sigma 高斯
     （hillshade/高度调制后乘，高频细节保留），等效柔和过渡。
  2. 不做超采样 AA：本批贴图 = 纯场合成（无矢量描边），逐像素运算无光栅锯齿；
     R9 方案的「4x 超采样」为批 3 矢量层（建成区/道路烘进贴图）预留，届时启用。

窗口读取方式与 export_l1_view_context.py --polys-only 同口径：
  只信包内 world_origin + context_size（规避 margin 不统一坑），不重算窗口。

输入（output/，缺失先从主工作区复制；biome 两件可用 l3/biome_generate.py 确定性重跑）：
  fractal_heightmap_8192.npy / fractal_lake_mask_8192.png / fractal_river_mask_8192.png
  biome_labels_2048.npy / biome_hot_zone_2048.png / locked/locked_continent_8192.png

用法：
  python l1_terrain_bake.py                 # 全部 70 包
  python l1_terrain_bake.py --pack l1_001   # 指定包（spawn = 出生包）
  python l1_terrain_bake.py --spawn-only    # 只跑出生包（调参快速预览）
"""
import argparse
import json
import os
import sys
import time

import numpy as np
from scipy.ndimage import gaussian_filter
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
L3_DIR = os.path.join(os.path.dirname(HERE), "l3")
sys.path.insert(0, L3_DIR)
import terrain_render as tr  # noqa: E402  B2 着色管线（单一真相源）

OUTPUT_DIR = tr.OUTPUT_DIR
REPO_ROOT = tr.REPO_ROOT
CONFIG_DIR = tr.CONFIG_DIR
PARAMS_PATH = os.path.join(HERE, "l1_terrain_params.json")

SIZE_FULL = 8192


def load_params():
    """继承 terrain_params.json（B2 同源）+ 本地 l1 覆写（浅合并顶层键）。"""
    with open(PARAMS_PATH, encoding="utf-8") as f:
        p = json.load(f)
    parent_rel = p.pop("inherits", None)
    if parent_rel:
        with open(os.path.normpath(os.path.join(HERE, parent_rel)), encoding="utf-8") as f:
            base = json.load(f)
        base.update(p)  # 本地键覆盖父值
        return base
    return p


def list_packs():
    """全部 L1 包：[(目录, 标签说明), ...]。出生包 = config 根的单份，批量 = l1_packs/l1_XXX。"""
    packs = [(os.path.join(CONFIG_DIR, "l1_world.json"), "spawn(l1_069)")]
    packs_dir = os.path.join(CONFIG_DIR, "l1_packs")
    for name in sorted(os.listdir(packs_dir)):
        jp = os.path.join(packs_dir, name, "l1_world.json")
        if os.path.isfile(jp):
            packs.append((jp, name))
    return packs


def render_window(sl, fields, colors, blend_sigma):
    """单窗口合成（render_full 块内逻辑的窗口版 + L1 基色柔化）。返回 RGB uint8。"""
    labels8, elev, land, lake = fields["labels8"], fields["elev"], fields["land"], fields["lake"]
    shade, ocean_edt, lake_in, coast_dark, river_a = (
        fields["shade"], fields["ocean_edt"], fields["lake_in"],
        fields["coast_dark"], fields["river_a"])
    hot8 = fields["hot8"]
    p = fields["p"]

    lut = np.zeros((8, 3), dtype=np.float32)
    for i, c in tr.BIOME_COLORS.items():
        lut[i] = c
    # 1. 群系基色（L1 柔化：labels 2048 级 ×4 块状映射的 4px 台阶 → 2-3px 渐变带）
    rgb = lut[labels8[sl]]
    if blend_sigma > 0:
        rgb = gaussian_filter(rgb, sigma=(blend_sigma, blend_sigma, 0))

    # 2/3/6. 高度调制 + hillshade + 炎热偏移（B2 同函数）
    ctx = {"elev": elev, "shade": shade, "hot": hot8,
           "rock": colors["rock"], "snow": colors["snow"], "p": p}
    rgb = tr.render_block(rgb, sl, ctx)

    # 4. 水体（render_full 同式：河流软化混色 → 湖泊覆盖 → 海洋离岸渐变）
    ra = river_a[sl]
    rgb = rgb * (1.0 - ra[..., None]) + colors["river"][None, None, :] * ra[..., None]
    lm = lake[sl]
    if lm.any():
        depth = np.clip(lake_in[sl] / 30.0, 0.0, 1.0)
        lc = colors["lake"][None, None, :] * (1.0 - 0.08 * depth[..., None])
        rgb = np.where(lm[..., None], lc, rgb)
    om = ~land[sl]
    if om.any():
        d = ocean_edt[sl]
        op = p["ocean"]
        t = np.clip(d / op["shelf_px"], 0.0, 1.0) ** op["gamma"]
        oc_rgb = colors["ocean_near"][None, None, :] \
            + (colors["ocean_far"] - colors["ocean_near"])[None, None, :] * t[..., None]
        rgb = np.where(om[..., None], oc_rgb, rgb)

    # 5. 海岸暗线（陆地侧）
    cd = coast_dark[sl]
    if cd.any():
        rgb = np.where(cd[..., None], rgb * p["coast"]["darken"], rgb)

    np.clip(rgb, 0.0, 255.0, out=rgb)
    return rgb.astype(np.uint8)


def bake_pack(json_path, fields, colors, lp, texture_name):
    """单包：读 world_origin/context_size 裁窗合成 → 写 l1_terrain.png。"""
    with open(json_path, encoding="utf-8") as f:
        world = json.load(f)
    wo = world.get("world_origin")
    csz = world.get("context_size")
    if not wo or not csz:
        print("  !! 缺 world_origin/context_size，跳过: %s" % json_path, flush=True)
        return False
    x0, y0 = int(wo[0]), int(wo[1])
    side = int(csz[0])
    if x0 < 0 or y0 < 0 or x0 + side > SIZE_FULL or y0 + side > SIZE_FULL:
        print("  !! 窗口越界 (%d,%d)+%d，跳过: %s" % (x0, y0, side, json_path), flush=True)
        return False
    sl = (slice(y0, y0 + side), slice(x0, x0 + side))
    rgb = render_window(sl, fields, colors, lp["biome_blend_sigma"])
    out = os.path.join(os.path.dirname(json_path), texture_name)
    Image.fromarray(rgb).save(out)
    print("  %s: %d² @ (%d,%d) -> %.1f MB" % (
        os.path.basename(os.path.dirname(json_path)) or "spawn",
        side, x0, y0, os.path.getsize(out) / 1048576), flush=True)
    return True


def main():
    ap = argparse.ArgumentParser(description="L1 地形底图烘焙（R9，B2 同管线 per-L1 裁切）")
    ap.add_argument("--pack", nargs="*", help="只处理指定包（目录名如 l1_001；spawn = 出生包）")
    ap.add_argument("--spawn-only", action="store_true", help="只跑出生包（调参快速预览）")
    args = ap.parse_args()

    t0 = time.time()
    p = load_params()
    lp = p["l1"]
    colors = {
        "rock": np.array(p["colors"]["rock"], dtype=np.float32),
        "snow": np.array(p["colors"]["snow"], dtype=np.float32),
        "ocean_near": np.array(p["colors"]["ocean_near"], dtype=np.float32),
        "ocean_far": np.array(p["colors"]["ocean_far"], dtype=np.float32),
        "lake": np.array(p["colors"]["lake"], dtype=np.float32),
        "river": np.array(p["colors"]["river"], dtype=np.float32),
    }

    print("[1/2] 加载 B2 全局场（terrain_render 同源）...", flush=True)
    elev, land, lake, river, labels8, hot8 = tr.load_inputs()
    shade, ocean_edt, lake_in, coast_dark, river_a = tr.build_fields(
        elev, land, lake, river, p)
    # EDT 返回 float64，压成 float32 减半内存（8192² 场 ×2）
    fields = {"labels8": labels8, "elev": elev, "land": land, "lake": lake,
              "shade": shade, "ocean_edt": ocean_edt.astype(np.float32),
              "lake_in": lake_in.astype(np.float32), "coast_dark": coast_dark,
              "river_a": river_a, "hot8": hot8, "p": p}

    print("[2/2] 逐包烘焙...", flush=True)
    packs = list_packs()
    if args.pack:
        want = set(args.pack)
        packs = [(jp, name) for jp, name in packs
                 if name in want or (name.startswith("spawn") and "spawn" in want)]
    elif args.spawn_only:
        packs = packs[:1]
    ok = 0
    for jp, name in packs:
        if bake_pack(jp, fields, colors, lp, lp["texture_name"]):
            ok += 1
    print("完成 %d/%d 包，总耗时 %.1fs" % (ok, len(packs), time.time() - t0), flush=True)
    if ok < len(packs):
        sys.exit(1)


if __name__ == "__main__":
    main()
