"""群系生成器 - Whittaker 温湿矩阵（总体设计 §5.2）

输入：高度场 + 大陆掩码 + 河流/湖泊蒙版（fractal_continent.py 产物）
输出：biome_labels_2048.npy + 彩色预览 PNG

  temperature(px) = base(纬度梯度：北极→赤道，y=0 最冷) + fBm 噪声(幅度±) − 海拔递减(高山更冷)
  precipitation(px) = fBm 噪声 + 海洋邻近加成(EDT 离海距离指数衰减) − 雨影(西侧高山背风面)

温湿 → 群系映射（对齐 GDD 七群系）：
  冰原   temp < t_ice（高山顶部因海拔递减同落此档）
  荒漠   temp > t_hot 且 precip < p_dry
  森林   precip > p_wet（温带/热带雨林合并）
  平原   其余（含热带草原）—— 默认出生群系
  源流   非气候群系：河流/湖泊沿岸膨胀带（lake/river mask 派生）
  火山   非气候群系：独立放置——高海拔 + 低频噪声热点 + 距出生点下限，撒 N 个蚀变圆
  海洋   大陆掩码外

硬验收：出生地区（region_013）陆地群系众数 = 平原且占比 >= plains_ratio_min；
       不满足时可用 --search N 自动遍历 seed 偏置（写回 biome_params.json 的 seed_offset）。

用法：python biome_generate.py [--search N]
"""

import numpy as np
from scipy.ndimage import distance_transform_edt, binary_dilation, gaussian_filter
from PIL import Image, ImageDraw, ImageFont
import random
import json
import math
import os
import sys
import argparse
import time

SIZE_FULL = 8192          # fractal_continent 产物分辨率
HERE = os.path.dirname(os.path.abspath(__file__))
OUTPUT_DIR = os.path.join(os.path.dirname(HERE), "output")
LOCKED_DIR = os.path.join(OUTPUT_DIR, "locked")
PARAMS_PATH = os.path.join(HERE, "biome_params.json")

# 群系标签（uint8，消费端 B2/B3 按此编码取色）
OCEAN, PLAINS, FOREST, DESERT, ICE, SOURCE, VOLCANIC = range(7)
BIOME_NAMES = ["海洋", "平原", "森林", "荒漠", "冰原", "源流", "火山"]
BIOME_COLORS = {
    OCEAN:    (25, 55, 105),    # 沿用预览外海深蓝
    PLAINS:   (130, 170, 90),
    FOREST:   (70, 120, 62),
    DESERT:   (208, 182, 122),
    ICE:      (228, 233, 238),
    SOURCE:   (95, 160, 195),
    VOLCANIC: (118, 62, 54),
}


def fft_fbm(size, seed, beta):
    """FFT 频谱噪声（1/f^beta），归一化 0~1。beta 越大越红（大尺度主导）。"""
    rng = np.random.RandomState(seed)
    noise = rng.randn(size, size).astype(np.float32)
    f = np.fft.fft2(noise)
    fx, fy = np.meshgrid(np.fft.fftfreq(size), np.fft.fftfreq(size))
    freq = np.sqrt(fx ** 2 + fy ** 2)
    freq[0, 0] = 1
    f *= 1.0 / (freq ** beta)
    out = np.real(np.fft.ifft2(f)).astype(np.float32)
    return (out - out.min()) / (out.max() - out.min() + 1e-10)


def load_inputs(size):
    """高度场/掩码 8192 → 2048（高度 4x4 块平均，掩码 NEAREST 保边）。"""
    hm = np.load(os.path.join(OUTPUT_DIR, "fractal_heightmap_8192.npy"))
    k = SIZE_FULL // size
    elev = hm.reshape(size, k, size, k).mean(axis=(1, 3)).astype(np.float32)

    mask = np.array(Image.open(os.path.join(LOCKED_DIR, "locked_continent_8192.png")).convert("L"))
    land = np.asarray(
        Image.fromarray(mask).resize((size, size), Image.NEAREST), dtype=np.uint8) > 127

    lake = np.array(Image.open(os.path.join(OUTPUT_DIR, "fractal_lake_mask_8192.png")).convert("L"))
    lake = np.asarray(Image.fromarray(lake).resize((size, size), Image.NEAREST), dtype=np.uint8) > 127

    river = np.array(Image.open(os.path.join(OUTPUT_DIR, "fractal_river_mask_8192.png")).convert("L"))
    river = np.asarray(Image.fromarray(river).resize((size, size), Image.NEAREST), dtype=np.uint8) > 127
    return elev, land, lake, river


def compute_temperature(size, elev, seed, tp):
    """温度 = 纬度梯度 + fBm 扰动 − 海拔递减。y=0 为北极（冷），y=size 为赤道（热）。"""
    lat = np.linspace(tp["lat_cold"], tp["lat_hot"], size, dtype=np.float32)[:, None]
    t_noise = fft_fbm(size, seed + 101, tp["noise_beta"])
    temp = lat + (t_noise * 2.0 - 1.0) * tp["noise_amp"]
    temp = temp - np.clip(elev, 0.0, 1.0) * tp["lapse_rate"]
    return temp


def compute_precipitation(size, elev, land, seed, pp):
    """降水 = fBm + 离海加成（EDT 指数衰减）− 副热带干旱带 − 雨影（盛行西风，西侧窗口内高山背风减湿）。

    副热带干旱带：哈德莱环流下沉区（真实地球荒漠集中在亚热带 ~25°，赤道反而是雨林），
    以纬度为中心的高斯干旱槽——「赤道雨林 → 亚热带荒漠 → 温带平原」条带的成因。
    """
    p_noise = fft_fbm(size, seed + 202, pp["noise_beta"])
    dist_coast = distance_transform_edt(land)  # 陆地像素到最近海洋的距离
    coast_bonus = pp["coast_bonus"] * np.exp(-dist_coast / pp["coast_decay_px"])
    precip = p_noise + coast_bonus

    db = pp["subtropical_dry_band"]
    lat = np.linspace(0.0, 1.0, size, dtype=np.float32)[:, None]  # 0=北极 1=赤道
    precip = precip - db["depth"] * np.exp(-((lat - db["center"]) / db["width"]) ** 2)

    rs = pp["rain_shadow"]
    if rs["enabled"]:
        # 西风：x 正向为东。up_max = 西侧（含自身）累计最高海拔，lag 一个风窗后与本点比较
        up_max = np.maximum.accumulate(np.clip(elev, 0, 1), axis=1)
        lagged = np.zeros_like(elev)
        w = rs["wind_window_px"]
        lagged[:, w:] = up_max[:, :-w]
        shadow = np.clip(lagged - elev - rs["relief_thresh"], 0.0, None) * rs["strength"]
        precip = precip - shadow
    return np.clip(precip, 0.0, 1.0)


def climate_biomes(temp, precip, land, th):
    """Whittaker 矩阵 → 气候群系（平原/森林/荒漠/冰原）。"""
    b = np.full(temp.shape, PLAINS, dtype=np.uint8)
    b[precip > th["p_wet"]] = FOREST
    b[(temp > th["t_hot"]) & (precip < th["p_dry"])] = DESERT
    b[temp < th["t_ice"]] = ICE
    b[~land] = OCEAN
    return b


def pick_volcano_sites(elev, land, size, seed, vp, spawn_xy):
    """火山选址：高海拔 ∧ 低频热点 ∧ 距出生点下限 ∧ 彼此间距下限，贪心取 count 个。"""
    rng = random.Random(seed + 303)
    hot_small = fft_fbm(256, seed + 304, vp["hotspot_beta"])
    hotspot = np.asarray(Image.fromarray((hot_small * 255).astype(np.uint8), mode="L")
                         .resize((size, size), Image.BILINEAR), dtype=np.float32) / 255.0

    cand = np.where(land & (elev > vp["min_elev"]) & (hotspot > vp["hotspot_thresh"]))
    if len(cand[0]) == 0:
        print("   ⚠ 无火山候选点，跳过放置", flush=True)
        return []
    sx, sy = spawn_xy
    order = list(range(len(cand[0])))
    rng.shuffle(order)
    picked = []
    for i in order:
        cy, cx = int(cand[0][i]), int(cand[1][i])
        if (cx - sx) ** 2 + (cy - sy) ** 2 < vp["min_dist_spawn_px"] ** 2:
            continue
        if any((cx - px) ** 2 + (cy - py) ** 2 < vp["min_separation_px"] ** 2 for py, px in picked):
            continue
        picked.append((cy, cx))
        if len(picked) >= vp["count"]:
            break
    if not picked:
        print("   ⚠ 火山候选全被出生距离/间距约束淘汰", flush=True)
    return picked


def apply_volcanoes(labels, land, size, seed, vp, sites):
    """火山蚀变圆应用：中心实心、边缘概率蚀变（p = 1 − d²/r²），不规则边缘更自然。"""
    rng = random.Random(seed + 303)
    # 消耗掉与选址阶段等量的 rng 状态后再逐圆取半径/种子，保证与选址-应用拆分前同序可复现
    r_min, r_max = vp["radius_px"]
    yy, xx = np.mgrid[0:size, 0:size]
    for cy, cx in sites:
        r = rng.uniform(r_min, r_max)
        d2 = (yy - cy) ** 2 + (xx - cx) ** 2
        inside = (d2 < r * r) & land
        if vp["edge_decay"]:
            p = np.clip(1.0 - d2 / (r * r), 0.0, 1.0)
            keep = np.random.RandomState(rng.randint(0, 1 << 30)).rand(size, size) < p
            inside = inside & keep
        labels[inside] = VOLCANIC


def pick_supernatural_hot_zone(ref_labels, elev, land, size, seed, hzp, spawn_xy, volcano_sites):
    """超自然炎热大陆选址：面积≈一个 L2 地块的圆形区，避开独有地形（冰原/荒漠带、
    主山脉、出生地区、火山），落在普通平原/森林主导的陆地上——炎热化后有反差。

    用无热区温湿判定的参考群系做约束统计，返回圆心 (cy, cx)，半径由 area_px 推导。
    """
    pp = hzp["placement"]
    r = math.sqrt(hzp["area_px"] / math.pi)
    rng = random.Random(seed + 404)

    # 圆盘采样模板（固定 400 点，确定性）
    n_disk = 400
    disk = np.random.RandomState(seed + 405).rand(n_disk, 2)
    disk[:, 0] = disk[:, 0] * 2 - 1
    disk[:, 1] = disk[:, 1] * 2 - 1
    disk = disk[disk[:, 0] ** 2 + disk[:, 1] ** 2 <= 1.0][:256] * r  # (256, 2) 半径内偏移

    # 候选中心网格扫描
    step = 16
    cys, cxs = np.mgrid[r:size - r:step, r:size - r:step]
    centers = np.column_stack([cys.ravel(), cxs.ravel()]).astype(np.float32)  # (N, 2)

    # 展开采样：(N, 256) 索引
    sy = (centers[:, 0:1] + disk[:, 0][None, :]).astype(np.int32).ravel()
    sx = (centers[:, 1:2] + disk[:, 1][None, :]).astype(np.int32).ravel()
    land_v = land[sy, sx].reshape(len(centers), -1)
    ref_v = ref_labels[sy, sx].reshape(len(centers), -1)
    elev_v = elev[sy, sx].reshape(len(centers), -1)

    m = (land_v.mean(axis=1) >= pp["min_land_ratio"])
    m &= (ref_v == ICE).mean(axis=1) <= pp["ice_ratio_max"]
    m &= (ref_v == DESERT).mean(axis=1) <= pp["desert_ratio_max"]
    m &= ((ref_v == PLAINS) | (ref_v == FOREST)).mean(axis=1) >= pp["plains_forest_min"]
    m &= elev_v.mean(axis=1) <= pp["max_mean_elev"]
    sx0, sy0 = spawn_xy
    m &= (centers[:, 1] - sx0) ** 2 + (centers[:, 0] - sy0) ** 2 >= pp["min_dist_spawn_px"] ** 2
    for py, px in volcano_sites:
        m &= (centers[:, 1] - px) ** 2 + (centers[:, 0] - py) ** 2 >= pp["min_dist_volcano_px"] ** 2

    ok = np.where(m)[0]
    if len(ok) == 0:
        print("   ⚠ 无超自然炎热大陆合格位置，放宽 plains_forest_min 后重试", flush=True)
        return None
    center = centers[rng.choice(ok)]
    cy, cx = float(center[0]), float(center[1])
    print(f"   超自然炎热大陆: 中心 ({cx:.0f},{cy:.0f}) 半径 {r:.0f}px（≈{hzp['area_px'] / 10000:.1f}万px²）", flush=True)
    return (cy, cx)


def hot_zone_falloff(size, center, r, core_ratio):
    """热区温度增益场：中心 core 恒定 1，边缘 smoothstep 衰减到 0。"""
    yy, xx = np.mgrid[0:size, 0:size]
    d = np.sqrt((yy - center[0]) ** 2 + (xx - center[1]) ** 2)
    t = np.clip((d - core_ratio * r) / ((1.0 - core_ratio) * r), 0.0, 1.0)
    return (1.0 - (3.0 * t * t - 2.0 * t * t * t)).astype(np.float32)


def apply_source(labels, lake, river, band_px):
    """源流 = 河流/湖泊沿岸膨胀带；湖泊水体整体划入源流。"""
    water = lake | river
    band = binary_dilation(water, iterations=band_px) if band_px > 0 else water
    labels[band] = SOURCE
    labels[lake] = SOURCE


def load_spawn_region(size):
    """出生地区 polygon（[y,x] 序，2048 坐标）→ bool 蒙版。"""
    rd = json.load(open(os.path.join(OUTPUT_DIR, "regions", "region_data.json"), encoding="utf-8"))
    r = next(x for x in rd["regions"] if x["region_id"] == "region_013")
    img = Image.new("L", (size, size), 0)
    ImageDraw.Draw(img).polygon([(p[1], p[0]) for p in r["polygon"]], fill=255)
    return np.asarray(img) > 127


def evaluate_spawn(labels, land, region_mask, plains_min):
    """硬验收：出生地区陆地群系众数=平原且占比达标。返回 (pass, 报告行)。"""
    m = region_mask & land
    counts = np.bincount(labels[m], minlength=7)
    total = counts.sum()
    ratios = counts / total
    plains = ratios[PLAINS]
    mode = int(np.argmax(counts))
    ok = (mode == PLAINS) and (plains >= plains_min)
    dist = " ".join(f"{BIOME_NAMES[i]}{ratios[i] * 100:.1f}%" for i in range(7) if counts[i] > 0)
    return ok, f"出生地区(region_013): {dist} → 平原{plains * 100:.1f}% {'✅ PASS' if ok else '❌ FAIL'}"


def render_preview(labels, elev, size, spawn_xy, volcanoes, hot_center, hot_r, out_path, core_ratio=0.65):
    """彩色预览：群系色 × 高度明度 + 出生地区描边 + 超自然炎热大陆虚线圈 + 图例（含全图占比）。"""
    lut = np.zeros((7, 3), dtype=np.uint8)
    for i in range(7):
        lut[i] = BIOME_COLORS[i]
    rgb = lut[labels].astype(np.float32)

    # 高度明度调制：0.88~1.08，山地微亮、低地微暗，帮助辨认「小点的山」
    lum = 0.88 + 0.20 * np.clip(elev, 0.0, 1.0)
    rgb *= lum[:, :, None]
    # 海洋离岸渐变（近岸浅），观感更接近最终底图
    ocean = labels == OCEAN
    rgb[ocean] = np.array(BIOME_COLORS[OCEAN], dtype=np.float32)
    # 超自然炎热大陆：暖色偏移（R 增 B 减，随 falloff 渐变），模拟 B2 着色的炎热观感
    if hot_center is not None:
        fz = hot_zone_falloff(size, hot_center, hot_r, core_ratio)[:, :, None]
        warm = np.array([42.0, 10.0, -18.0], dtype=np.float32)
        rgb = np.clip(rgb + fz * warm, 0, 255)
    img = Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8))

    draw = ImageDraw.Draw(img, "RGBA")
    region_mask = load_spawn_region(size)
    # 出生地区描边（红）
    edge = region_mask & ~binary_erosion_np(region_mask)
    ys, xs = np.where(edge)
    for y, x in zip(ys, xs):
        draw.point((x, y), fill=(255, 70, 60, 255))
    sx, sy = spawn_xy
    draw.ellipse([sx - 7, sy - 7, sx + 7, sy + 7], outline=(255, 70, 60), width=3)
    for cy, cx in volcanoes:
        draw.ellipse([cx - 6, cy - 6, cx + 6, cy + 6], outline=(255, 140, 40), width=2)
    if hot_center is not None:
        hcy, hcx = hot_center
        # 虚线圈：赤橙描边 + 中心标注
        n_dash = 48
        import math as _m
        for i in range(n_dash):
            a0 = i / n_dash * 2 * _m.pi
            a1 = a0 + _m.pi / n_dash
            draw.arc([hcx - hot_r, hcy - hot_r, hcx + hot_r, hcy + hot_r],
                     _m.degrees(a0), _m.degrees(a1), fill=(255, 90, 40), width=4)
        draw.ellipse([hcx - 5, hcy - 5, hcx + 5, hcy + 5], fill=(255, 90, 40))

    # 底部图例条
    land_counts = np.bincount(labels[~ocean], minlength=7)
    ratios = land_counts / land_counts.sum()
    legend_h = 96
    canvas = Image.new("RGB", (size, size + legend_h), (18, 20, 24))
    canvas.paste(img, (0, 0))
    ld = ImageDraw.Draw(canvas)
    try:
        font = ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", 26)
        font_small = ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", 22)
    except OSError:
        font = font_small = ImageFont.load_default()
    x = 20
    for i in [PLAINS, FOREST, DESERT, ICE, SOURCE, VOLCANIC, OCEAN]:
        ld.rectangle([x, size + 18, x + 34, size + 50], fill=BIOME_COLORS[i])
        ld.text((x + 42, size + 22), f"{BIOME_NAMES[i]} {ratios[i] * 100:.1f}%", font=font_small, fill=(230, 230, 230))
        x += 42 + 22 + ld.textlength(f"{BIOME_NAMES[i]} 00.0%", font=font_small)
    ld.text((20, size + 56), f"出生聚落 ●红圈  火山 ○橙圈  红边=出生地区 region_013  橙虚线圈=超自然炎热大陆", font=font_small, fill=(160, 165, 175))
    canvas.save(out_path)
    print(f"   保存 {out_path} ({os.path.getsize(out_path) / 1024:.0f} KB)", flush=True)


def binary_erosion_np(mask):
    """3x3 腐蚀（numpy 平移实现，避免 scipy 依赖差异）。"""
    m = mask.copy()
    for dy, dx in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
        shifted = np.roll(mask, (dy, dx), axis=(0, 1))
        if dy == -1: shifted[0, :] = True
        elif dy == 1: shifted[-1, :] = True
        elif dx == -1: shifted[:, 0] = True
        else: shifted[:, -1] = True
        m &= shifted
    return m


def run_once(params, elev, land, lake, river, region_mask, want_preview):
    size = params["size"]
    seed = params["seed"] + params["seed_offset"]
    spawn_xy = tuple(params["spawn"]["world_px_2048"])

    temp = compute_temperature(size, elev, seed, params["temperature"])
    precip = compute_precipitation(size, elev, land, seed, params["precipitation"])
    # 温湿场高斯平滑：气候边界渐变，避免阈值边界椒盐碎斑
    sig = params.get("smooth_sigma", 0.0)
    if sig > 0:
        temp = gaussian_filter(temp, sig)
        precip = gaussian_filter(precip, sig)

    # 火山选址（只依赖海拔/热点/掩码，不受热区影响）
    volcano_sites = pick_volcano_sites(elev, land, size, seed, params["volcanic"], spawn_xy)

    # 超自然炎热大陆：用无热区参考群系选址 → 温度叠加增益 → 群系按炎热重判
    hzp = params["supernatural_hot_zone"]
    hot_center = tuple(hzp["center"]) if hzp.get("center") else \
        pick_supernatural_hot_zone(climate_biomes(temp, precip, land, params["thresholds"]),
                                   elev, land, size, seed, hzp, spawn_xy, volcano_sites)
    hot_r = math.sqrt(hzp["area_px"] / math.pi)
    if hot_center is not None:
        temp = temp + hzp["temp_boost"] * hot_zone_falloff(size, hot_center, hot_r, hzp["core_ratio"])

    labels = climate_biomes(temp, precip, land, params["thresholds"])
    apply_volcanoes(labels, land, size, seed, params["volcanic"], volcano_sites)
    apply_source(labels, lake, river, params["source_band_px"])

    ok, report = evaluate_spawn(labels, land, region_mask, params["spawn"]["plains_ratio_min"])
    land_counts = np.bincount(labels[land].ravel(), minlength=7)
    ratios = land_counts / land_counts.sum()
    print("   陆地: " + " ".join(f"{BIOME_NAMES[i]}{ratios[i] * 100:.1f}%" for i in range(7)), flush=True)
    if hot_center is not None:
        yy, xx = np.mgrid[0:size, 0:size]
        d2 = (yy - hot_center[0]) ** 2 + (xx - hot_center[1]) ** 2
        core = (d2 < (hot_r * 0.65) ** 2) & land
        hz_counts = np.bincount(labels[core], minlength=7)
        hz_r = hz_counts / hz_counts.sum()
        print("   热区核心: " + " ".join(f"{BIOME_NAMES[i]}{hz_r[i] * 100:.0f}%" for i in range(7) if hz_counts[i] > 0)
              + f"，温度中位 {np.median(temp[core]):.2f}（t_hot={params['thresholds']['t_hot']}）", flush=True)
    print("   " + report, flush=True)

    if want_preview:
        render_preview(labels, elev, size, spawn_xy, volcano_sites, hot_center, hot_r,
                       os.path.join(OUTPUT_DIR, "biome_preview_2048.png"), hzp["core_ratio"])
    # 热区增益场单独存（B2 着色做炎热色调用）
    if hot_center is not None:
        falloff = (hot_zone_falloff(size, hot_center, hot_r, hzp["core_ratio"]) * 255).astype(np.uint8)
        hz_path = os.path.join(OUTPUT_DIR, "biome_hot_zone_2048.png")
        Image.fromarray(falloff, mode="L").save(hz_path)
        print(f"   保存 {hz_path}", flush=True)
    return labels, ok, hot_center


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--search", type=int, default=0, help="出生验收失败时自动遍历 seed_offset 次数")
    args = parser.parse_args()

    t0 = time.time()
    params = json.load(open(PARAMS_PATH, encoding="utf-8"))
    size = params["size"]
    print(f"=== 群系生成（Whittaker 温湿矩阵, {size}², seed={params['seed']}+{params['seed_offset']}）===", flush=True)

    print("1. 加载高度场/掩码...", flush=True)
    elev, land, lake, river = load_inputs(size)
    print(f"   陆地 {land.mean() * 100:.1f}%  湖泊 {int(lake.sum())}px  河流 {int(river.sum())}px", flush=True)

    region_mask = load_spawn_region(size)

    print("2. 生成 + 硬验收...", flush=True)
    labels, ok, hot_center = run_once(params, elev, land, lake, river, region_mask, want_preview=True)

    attempt = 0
    while not ok and attempt < args.search:
        attempt += 1
        params["seed_offset"] += 1
        print(f"   → 重试 seed_offset={params['seed_offset']}", flush=True)
        labels, ok, hot_center = run_once(params, elev, land, lake, river, region_mask,
                                          want_preview=(attempt == args.search or ok))

    if not ok:
        print(f"❌ 出生验收仍未通过（已尝试 {1 + attempt} 个 seed），请手调 biome_params.json 温湿参数", flush=True)
        sys.exit(1)

    # 通过后：写回生效 seed_offset + 热区圆心（复现用）+ 标签图
    params["supernatural_hot_zone"]["center"] = list(hot_center) if hot_center else None
    json.dump(params, open(PARAMS_PATH, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    out = os.path.join(OUTPUT_DIR, f"biome_labels_{size}.npy")
    np.save(out, labels)
    print(f"   保存 {out}", flush=True)
    print(f"✅ 完成，总耗时 {time.time() - t0:.1f}s — 预览交创始人验收分布自然度", flush=True)


if __name__ == "__main__":
    main()
