"""地形底图程序着色器（总体设计 §5.3 / 世界地图数据流 §5.4）

输入（fractal_continent / biome_generate 产物，均在 output/）：
  fractal_heightmap_8192.npy   高度场 float32（海洋 = -0.1）
  locked/locked_continent_8192.png   大陆掩码
  biome_labels_2048.npy        七群系标签 uint8（编码见 biome_generate.py 头部）
  biome_hot_zone_2048.png      炎热大陆 falloff 蒙版（0-255）
  fractal_lake_mask_8192.png   湖泊掩码
  fractal_river_mask_8192.png  河流掩码（宽度已按「四次根流量×6px」画好，直接继承）
  l2_packs/region_XXX/info.json    L2 裁切 bbox（8192 级）

着色管线（全程序化，零贴图素材）：
  1. 群系基色（biome_generate BIOME_COLORS 同源）
  2. 高度调制：明度曲线 + 高海拔岩石过渡 + 山顶雪线（冰原标签之外的过渡带）
  3. 山体阴影 hillshade：西北 45° 光源，multiply 0.85-1.15
  4. 水体：河流（掩码即宽度）、湖泊（EDT 微深浅）、海洋离岸渐变（终色=渲染器 OCEAN_COLOR 无缝）
  5. 海岸线：陆地侧 EDT 等值线暗化
  6. 炎热大陆暖色偏移（falloff × R+42/G+6/B-18，方向为 B1 预览验证值）

输出：
  output/l3_terrain.png                       L3 全图（默认 2048，参数 output.l3_size）
  output/l2_packs/region_XXX/l2_terrain.png   L2 每地区 context 裁切（8192 级 RGBA，虚空透明）
  --install 时另拷贝到 stick-world/config/strategic_map/ 对应位置

用法：python terrain_render.py [--install] [--only-l3] [--region region_001 ...]
"""

import numpy as np
from scipy.ndimage import distance_transform_edt, binary_erosion, gaussian_filter, laplace
from PIL import Image
import json
import os
import sys
import argparse
import shutil
import time
import math

SIZE_FULL = 8192
SIZE_BIOME = 2048
HERE = os.path.dirname(os.path.abspath(__file__))
OUTPUT_DIR = os.path.join(os.path.dirname(HERE), "output")
LOCKED_DIR = os.path.join(OUTPUT_DIR, "locked")
PARAMS_PATH = os.path.join(HERE, "terrain_params.json")
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
CONFIG_DIR = os.path.join(REPO_ROOT, "stick-world", "config", "strategic_map")

# 群系标签（与 biome_generate.py 同编码）
OCEAN, PLAINS, FOREST, DESERT, ICE, SOURCE, VOLCANIC = range(7)
BIOME_NAMES = ["海洋", "平原", "森林", "荒漠", "冰原", "源流", "火山"]
BIOME_COLORS = {
    OCEAN:    (25, 55, 105),
    PLAINS:   (130, 170, 90),
    FOREST:   (70, 120, 62),
    DESERT:   (208, 182, 122),
    ICE:      (228, 233, 238),
    SOURCE:   (95, 160, 195),
    VOLCANIC: (118, 62, 54),
}


def load_params():
    with open(PARAMS_PATH, encoding="utf-8") as f:
        return json.load(f)


def smoothstep(x, a, b):
    t = np.clip((x - a) / (b - a + 1e-9), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def load_inputs():
    print("加载输入...", flush=True)
    elev = np.load(os.path.join(OUTPUT_DIR, "fractal_heightmap_8192.npy"))
    mask = np.array(Image.open(os.path.join(LOCKED_DIR, "locked_continent_8192.png")).convert("L"))
    land = mask > 127
    lake = np.array(Image.open(os.path.join(OUTPUT_DIR, "fractal_lake_mask_8192.png")).convert("L")) > 127
    river = np.array(Image.open(os.path.join(OUTPUT_DIR, "fractal_river_mask_8192.png")).convert("L")) > 127
    labels = np.load(os.path.join(OUTPUT_DIR, "biome_labels_2048.npy")).astype(np.uint8)
    hot = np.array(Image.open(os.path.join(OUTPUT_DIR, "biome_hot_zone_2048.png")).convert("L"))
    k = SIZE_FULL // SIZE_BIOME
    labels8 = np.repeat(np.repeat(labels, k, axis=0), k, axis=1)
    hot8 = np.asarray(
        Image.fromarray(hot).resize((SIZE_FULL, SIZE_FULL), Image.BILINEAR), dtype=np.float32) / 255.0
    return elev, land, lake, river, labels8, hot8


def narrow_source_band(labels8, land, water, band_px):
    """源流带收窄（D1=创始人 2026-09-22 拍板 C 版）：biome_labels 里的源流带是
    binary_dilation 1px@2048（=4px@8192）的沿岸膨胀带，与真水同色——色块/描边贴
    真水线后，带宽透出色读作「色块与地面分离」。本函数在 8192 级把带收窄到贴水
    band_px，带外源流像素按 EDT 最近非源流群系还原（2048 栅格表达不了半像素，
    故收窄在烘焙端 8192 场做，biome 中间体不动）。

    Args:
        labels8: 8192 群系场（uint8，SOURCE 会被就地修改——传副本）
        land: 8192 陆地掩膜；water: 8192 水面（湖|河，与贴图同代）
        band_px: 收窄后的贴水带宽（8192 原生 px）
    """
    src_mask = labels8 == SOURCE
    if not src_mask.any():
        return labels8
    from scipy.ndimage import binary_dilation, distance_transform_edt
    band = binary_dilation(water, iterations=band_px) & land & ~water
    outside = src_mask & ~band
    if outside.any():
        ref = labels8.copy()
        ref[src_mask] = 0   # 源流带当洞，EDT 找最近非源流群系
        _, idx = distance_transform_edt(ref == 0, return_indices=True)
        vals = labels8[idx[0], idx[1]]
        labels8[outside] = vals[outside]
    return labels8


def build_hillshade(elev, land, hp):
    """西北 45° 光源多尺度 hillshade + 谷地曲率暗化，multiply [1-strength, 1+strength]。

    图像坐标 x 向右、y 向下，西北 = (-1,-1) 方向；坡面朝西北（高度沿东南向升，
    gx,gy > 0）为受光面提亮。海洋填海平面高度避免陆海跳变产生假边缘。

    多尺度：单一细 sigma 的刻面阴影在 8192→2048 降采样时被平均掉（细 σ@8192
    折算不足 1px@2048），观感「磨平」——分 σ 档叠加（细刻面 + 中尺度 + 成图
    存活的山谷/山脊 traces），各档按自身幅值归一再加权；拉普拉斯曲率项
    （谷横剖面凹 → 二阶导 > 0 → 减光，脊反之）补上地形图式的谷地痕迹。
    scales 缺省回退单 [sigma, 1.0]（旧档兼容）。
    """
    sea_level = float(np.median(elev[land][:1000])) * 0.05 if land.any() else 0.02
    es = np.where(land, elev, np.float32(sea_level))
    az = math.radians(hp["light_az_deg"])
    lx, ly = math.cos(az), math.sin(az)
    total = np.zeros(es.shape, dtype=np.float32)
    for sigma, w in hp.get("scales") or [[hp["sigma"], 1.0]]:
        ess = gaussian_filter(es, sigma=sigma)
        gy, gx = np.gradient(ess)
        dot = gx * lx + gy * ly
        scale = np.percentile(np.abs(dot), 98.5)
        if scale < 1e-9:
            scale = 1e-9
        total += w * (dot / scale)
    cv = hp.get("curvature")
    if cv:
        c = laplace(gaussian_filter(es, sigma=cv["sigma"]))
        cscale = np.percentile(np.abs(c), 98.0)
        if cscale > 1e-9:
            total -= cv["weight"] * (c / cscale)
    scale = np.percentile(np.abs(total), 98.5)
    if scale < 1e-9:
        scale = 1e-9
    return 1.0 + hp["strength"] * np.clip(total / scale, -1.0, 1.0)


def build_fields(elev, land, lake, river, p):
    """预计算全局场：hillshade / 海洋离岸 EDT / 湖泊内部 EDT / 海岸暗线带 / 河流软 α。"""
    print("hillshade...", flush=True)
    shade = build_hillshade(elev, land, p["hillshade"])

    print("海洋 EDT...", flush=True)
    ocean = ~land
    ocean_edt = distance_transform_edt(ocean)  # 海洋像素到最近陆地距离

    print("湖泊 EDT / 海岸带 / 河流软化...", flush=True)
    # 湖泊内部深度（到湖岸距离），用于湖心微暗
    lake_in = distance_transform_edt(lake)
    cw = p["coast"]["width_px"]
    coast_dark = land & ~binary_erosion(land, structure=np.ones((cw * 2 + 1, cw * 2 + 1)))
    river_a = gaussian_filter(river.astype(np.float32), sigma=0.9)
    return shade, ocean_edt, lake_in, coast_dark, river_a


def render_block(rgb, sl, ctx):
    """单块陆地着色调制（水体之外的步骤；ocean 区稍后整体覆盖）。"""
    e = ctx["elev"][sl]
    ep = p_elev = ctx["p"]["elevation"]

    # 2. 高度调制：岩石过渡 + 雪线 + 明度曲线
    t_rock = smoothstep(e, ep["rock_start"], ep["rock_end"]) * ep["rock_blend"]
    rgb = rgb * (1.0 - t_rock[..., None]) + ctx["rock"][None, None, :] * t_rock[..., None]
    t_snow = smoothstep(e, ep["snow_start"], ep["snow_end"])
    rgb = rgb * (1.0 - t_snow[..., None]) + ctx["snow"][None, None, :] * t_snow[..., None]
    light = ep["light_low"] + (ep["light_high"] - ep["light_low"]) * smoothstep(
        e, ep["light_start"], ep["light_end"])
    rgb *= light[..., None]

    # 3. hillshade
    rgb *= ctx["shade"][sl][..., None]

    # 6. 炎热大陆暖色偏移
    hz = ctx["p"]["hot_zone"]
    f = ctx["hot"][sl]
    rgb[..., 0] += hz["r_shift"] * f
    rgb[..., 1] += hz["g_shift"] * f
    rgb[..., 2] += hz["b_shift"] * f
    return rgb


def render_full(elev, land, lake, river_a, labels8, hot8, shade, ocean_edt, lake_in, coast_dark, p):
    """全图 8192 分块合成（控峰值内存），返回 RGB uint8。"""
    print("合成着色...", flush=True)
    lut = np.zeros((8, 3), dtype=np.float32)
    for i, c in BIOME_COLORS.items():
        lut[i] = c
    oc = p["colors"]
    rock = np.array(oc["rock"], dtype=np.float32)
    snow = np.array(oc["snow"], dtype=np.float32)
    o_near = np.array(oc["ocean_near"], dtype=np.float32)
    o_far = np.array(oc["ocean_far"], dtype=np.float32)
    lake_c = np.array(oc["lake"], dtype=np.float32)
    river_c = np.array(oc["river"], dtype=np.float32)
    op = p["ocean"]
    shelf = op["shelf_px"]

    out = np.empty((SIZE_FULL, SIZE_FULL, 3), dtype=np.uint8)
    block = p["output"]["block"]
    ctx = {"elev": elev, "shade": shade, "hot": hot8, "rock": rock, "snow": snow, "p": p}
    t0 = time.time()
    for ty in range(0, SIZE_FULL, block):
        for tx in range(0, SIZE_FULL, block):
            sy = slice(ty, min(ty + block, SIZE_FULL))
            sx = slice(tx, min(tx + block, SIZE_FULL))
            sl = (sy, sx)
            rgb = lut[labels8[sl]]

            rgb = render_block(rgb, sl, ctx)

            # 4. 水体
            ra = river_a[sl]
            rgb = rgb * (1.0 - ra[..., None]) + river_c[None, None, :] * ra[..., None]
            lm = lake[sl]
            if lm.any():
                depth = np.clip(lake_in[sl] / 30.0, 0.0, 1.0)  # 湖心微暗
                lc = lake_c[None, None, :] * (1.0 - 0.08 * depth[..., None])
                rgb = np.where(lm[..., None], lc, rgb)
            om = ~land[sl]
            if om.any():
                d = ocean_edt[sl]
                t = np.clip(d / shelf, 0.0, 1.0) ** op["gamma"]
                oc_rgb = o_near[None, None, :] + (o_far - o_near)[None, None, :] * t[..., None]
                rgb = np.where(om[..., None], oc_rgb, rgb)

            # 5. 海岸暗线（陆地侧）
            cd = coast_dark[sl]
            if cd.any():
                rgb = np.where(cd[..., None], rgb * p["coast"]["darken"], rgb)

            np.clip(rgb, 0.0, 255.0, out=rgb)
            out[sl] = rgb.astype(np.uint8)
    print("  合成耗时 %.1fs" % (time.time() - t0), flush=True)
    return out


def save_l3(rgb_full, p):
    size = p["output"]["l3_size"]
    img = Image.fromarray(rgb_full).resize((size, size), Image.LANCZOS)
    path = os.path.join(OUTPUT_DIR, "l3_terrain.png")
    img.save(path)
    print("保存 %s（%d², %.1f MB）" % (path, size, os.path.getsize(path) / 1048576), flush=True)
    return path


def export_l2_crops(rgb_full, regions=None):
    """L2 每地区 context 裁切（口径 = export_l2_view_packs.py：bbox + 正方形化 + PAD_EDGE 虚空）。

    虚空区（世界边界外 pad）alpha=0，运行时透出渲染器 OCEAN_COLOR 海洋背景。
    """
    src_dir = os.path.join(OUTPUT_DIR, "l2_packs")
    rids = sorted(os.listdir(src_dir)) if regions is None else regions
    rids = [r for r in rids if r.startswith("region_")]
    full = Image.fromarray(rgb_full)  # 8192 RGB
    for rid in rids:
        info = json.load(open(os.path.join(src_dir, rid, "info.json"), encoding="utf-8"))
        b = info["bbox_8192"]
        x0, y0, x1, y1 = b["x0"], b["y0"], b["x1"], b["y1"]
        W, H = x1 - x0 + 1, y1 - y0 + 1
        side = max(W, H)
        tx, ty = (side - W) // 2, (side - H) // 2
        PAD = max(0, ty - y0, tx - x0, y1 + ty - 8191, x1 + tx - 8191)
        if PAD > 0:
            canvas = Image.new("RGB", (SIZE_FULL + PAD * 2, SIZE_FULL + PAD * 2), (30, 55, 95))
            canvas.paste(full, (PAD, PAD))
            xx0, yy0 = x0 - tx + PAD, y0 - ty + PAD
        else:
            canvas = full
            xx0, yy0 = x0 - tx, y0 - ty
        crop = canvas.crop((xx0, yy0, xx0 + side, yy0 + side)).convert("RGBA")

        # 虚空区（世界外 pad）透明：alpha 蒙版 = 世界矩形内 255
        alpha = Image.new("L", (side, side), 0)
        if PAD > 0:
            wx0, wy0 = xx0 - PAD, yy0 - PAD  # 世界原点在 crop 中的位置
            inner = Image.new("L", (side, side), 0)
            inner.paste(Image.new("L", (SIZE_FULL, SIZE_FULL), 255), (wx0, wy0))
            alpha = inner
        else:
            alpha = Image.new("L", (side, side), 255)
        crop.putalpha(alpha)

        out = os.path.join(src_dir, rid, "l2_terrain.png")
        crop.save(out)
        print("  %s: %d², %.1f MB" % (rid, side, os.path.getsize(out) / 1048576), flush=True)


def install(paths_l3, regions=None):
    """拷贝产物到 config/strategic_map/（L3 根 + l2_packs 每地区）。"""
    os.makedirs(CONFIG_DIR, exist_ok=True)
    shutil.copy2(paths_l3, os.path.join(CONFIG_DIR, "l3_terrain.png"))
    src_dir = os.path.join(OUTPUT_DIR, "l2_packs")
    rids = sorted(os.listdir(src_dir)) if regions is None else regions
    rids = [r for r in rids if r.startswith("region_")]
    for rid in rids:
        src = os.path.join(src_dir, rid, "l2_terrain.png")
        if os.path.exists(src):
            shutil.copy2(src, os.path.join(CONFIG_DIR, "l2_packs", rid, "l2_terrain.png"))
    print("已安装到 %s" % CONFIG_DIR, flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--install", action="store_true", help="另拷贝产物到 config/strategic_map/")
    ap.add_argument("--only-l3", action="store_true", help="只出 L3 全图（调试观感）")
    ap.add_argument("--region", nargs="*", help="只处理指定 region（默认全部）")
    args = ap.parse_args()

    p = load_params()
    elev, land, lake, river, labels8, hot8 = load_inputs()
    shade, ocean_edt, lake_in, coast_dark, river_a = build_fields(elev, land, lake, river, p)
    rgb_full = render_full(elev, land, lake, river_a, labels8, hot8,
                           shade, ocean_edt, lake_in, coast_dark, p)
    l3_path = save_l3(rgb_full, p)
    if not args.only_l3:
        export_l2_crops(rgb_full, args.region)
    if args.install:
        install(l3_path, args.region)
    print("完成。", flush=True)


if __name__ == "__main__":
    main()
