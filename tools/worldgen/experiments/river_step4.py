"""河流生成 - 步骤4：河流渲染（从C加速器输出的paths.bin读取路径）

流程：
  1. 读取 paths.bin（C加速器追踪的河流路径）
  2. Catmull-Rom 样条平滑路径
  3. 栅格化：宽度 = sqrt(accum) * k，颜色深浅 = accum
  4. 叠加到底图上

输入：
  .tmp/paths.bin    : C加速器输出的路径数据
  output/locked/river_accum.npy : float32 流量累积场（宽度/颜色用）
  output/locked/locked_heightmap_8192.npy : 高度场（底图）
  output/locked/locked_continent_8192.png.npy : 掩码

产物：
  output/preview_rivers.png : 河流最终预览图
"""
import os
import sys
import gc
import json
import math
import time
import struct

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUTPUT_DIR = os.path.join(HERE, "output")
LOCKED_DIR = os.path.join(OUTPUT_DIR, "locked")
TMP_DIR = os.path.abspath(os.path.join(HERE, "..", ".tmp"))
SIZE = 8192
SEED = 4242424248


def main():
    print("=== 步骤4：河流渲染 ===", flush=True)

    # --- 1. 读取路径 ---
    print("读取 paths.bin...", flush=True)
    paths = read_paths_bin(os.path.join(TMP_DIR, "paths.bin"))
    print(f"  路径数: {len(paths)}", flush=True)
    lengths = [len(p) for p in paths]
    if lengths:
        print(f"  路径长度: min={min(lengths)}, max={max(lengths)}, "
              f"mean={np.mean(lengths):.1f}, median={np.median(lengths):.1f}", flush=True)

    # --- 2. 加载流量累积场（宽度/颜色用） ---
    print("加载流量累积场...", flush=True)
    accum = np.load(os.path.join(LOCKED_DIR, "river_accum.npy"))
    print(f"  max={accum.max():.1f}", flush=True)

    # --- 3. Meandering + Catmull-Rom 平滑 ---
    print("Meandering + Catmull-Rom 平滑...", flush=True)
    t0 = time.time()
    import random
    rng = random.Random(SEED)
    smoothed_paths = []
    for path in paths:
        if len(path) < 3:
            smoothed_paths.append(path)
            continue
        # 1. Meandering：在每对相邻点间插入垂直偏移中点
        meandered = add_meandering(path, rng, scale=0.4)
        # 2. Catmull-Rom 样条插值
        sp = catmull_rom_smooth(meandered, subdivisions=4)
        smoothed_paths.append(sp)
    print(f"  平滑完成, 耗时 {time.time()-t0:.1f}s", flush=True)

    # --- 4. 栅格化渲染 ---
    print("栅格化渲染...", flush=True)
    t0 = time.time()

    # 生成底图
    print("  生成底图...", flush=True)
    heightmap = np.load(os.path.join(LOCKED_DIR, "locked_heightmap_8192.npy"))
    mask = np.load(os.path.join(LOCKED_DIR, "locked_continent_8192.png.npy"))
    bg_img = render_background(heightmap, mask)
    del heightmap
    gc.collect()

    # 画河流
    print("  绘制河流...", flush=True)
    draw = ImageDraw.Draw(bg_img)

    width_k = 0.03
    min_width = 1
    max_width = 12
    river_light = (120, 180, 230)
    river_dark = (30, 80, 180)
    max_accum = float(accum.max())
    log_max = math.log1p(max_accum)

    for spath in smoothed_paths:
        if len(spath) < 2:
            continue

        # 取路径中点的 accum 作为宽度依据
        mid_idx = len(spath) // 2
        mx, my = int(spath[mid_idx][0]), int(spath[mid_idx][1])
        if 0 <= mx < SIZE and 0 <= my < SIZE:
            a = float(accum[my, mx])
        else:
            a = 300.0

        # 宽度 = sqrt(accum) * k
        width = max(min_width, min(max_width, int(math.sqrt(a) * width_k)))
        # 颜色深浅
        t = min(1.0, math.log1p(a) / log_max)
        r = int(river_light[0] * (1 - t) + river_dark[0] * t)
        g = int(river_light[1] * (1 - t) + river_dark[1] * t)
        b = int(river_light[2] * (1 - t) + river_dark[2] * t)
        color = (r, g, b)

        points = [(float(p[0]), float(p[1])) for p in spath]
        draw.line(points, fill=color, width=width, joint="curve")

    del draw
    print(f"  绘制完成, 耗时 {time.time()-t0:.1f}s", flush=True)

    # 保存
    out_path = os.path.join(OUTPUT_DIR, "preview_rivers.png")
    bg_img.save(out_path)
    print(f"  -> {out_path}", flush=True)

    # 保存路径数据（JSON，限制数量）
    paths_path = os.path.join(LOCKED_DIR, "river_paths.json")
    save_paths = smoothed_paths[:5000]
    with open(paths_path, "w") as f:
        json.dump(save_paths, f)
    print(f"  -> {paths_path} ({len(save_paths)} paths)", flush=True)

    print("\n=== 步骤4完成 ===", flush=True)
    print(f"河流路径数: {len(paths)}", flush=True)
    print(f"宽度系数: {width_k} (min={min_width}, max={max_width})", flush=True)
    print("请检查预览图。", flush=True)


def add_meandering(points, rng, scale=0.4):
    """在每对相邻路径点间插入垂直偏移中点，模拟河流自然弯曲。

    仿 Azgaar addMeandering：在 (p[i], p[i+1]) 之间插入中点，
    中点沿流向的垂直方向偏移，偏移量 = 段长 × scale × 随机系数。

    scale 越大弯曲越剧烈，0.3-0.5 比较自然。
    """
    n = len(points)
    if n < 2:
        return points

    result = [points[0]]
    for i in range(n - 1):
        x1, y1 = float(points[i][0]), float(points[i][1])
        x2, y2 = float(points[i + 1][0]), float(points[i + 1][1])

        # 段向量和长度
        dx, dy = x2 - x1, y2 - y1
        seg_len = math.hypot(dx, dy)
        if seg_len < 0.001:
            result.append(points[i + 1])
            continue

        # 垂直方向（左侧法向量）
        nx, ny = -dy / seg_len, dx / seg_len

        # 偏移量：段长 × scale × [-1, 1] 随机
        # 用 sin 波让相邻段偏移方向交替，避免锯齿
        offset_mag = seg_len * scale * (rng.uniform(-1.0, 1.0))

        mx = (x1 + x2) / 2 + nx * offset_mag
        my = (y1 + y2) / 2 + ny * offset_mag

        result.append((mx, my))
        result.append(points[i + 1])

    return result


def read_paths_bin(path):
    """读取C加速器输出的路径二进制文件。

    格式: [n_paths:int32]
          对每条路径: [path_len:int32] [x0,y0,x1,y1,... int16*path_len]
    """
    with open(path, "rb") as f:
        data = f.read()

    offset = 0
    n_paths = struct.unpack_from("i", data, offset)[0]
    offset += 4

    paths = []
    for _ in range(n_paths):
        path_len = struct.unpack_from("i", data, offset)[0]
        offset += 4
        path = []
        for _ in range(path_len):
            x, y = struct.unpack_from("hh", data, offset)
            offset += 4
            path.append((x, y))
        if len(path) >= 2:
            paths.append(path)

    return paths


def catmull_rom_smooth(points, subdivisions=4):
    """Catmull-Rom 样条平滑。"""
    n = len(points)
    if n < 3:
        return points

    result = []
    for i in range(n):
        p0 = points[max(0, i - 1)]
        p1 = points[i]
        p2 = points[min(n - 1, i + 1)]
        p3 = points[min(n - 1, i + 2)]

        for t in range(subdivisions):
            s = t / subdivisions
            s2 = s * s
            s3 = s2 * s
            x = 0.5 * ((2 * p1[0]) + (-p0[0] + p2[0]) * s +
                       (2 * p0[0] - 5 * p1[0] + 4 * p2[0] - p3[0]) * s2 +
                       (-p0[0] + 3 * p1[0] - 3 * p2[0] + p3[0]) * s3)
            y = 0.5 * ((2 * p1[1]) + (-p0[1] + p2[1]) * s +
                       (2 * p0[1] - 5 * p1[1] + 4 * p2[1] - p3[1]) * s2 +
                       (-p0[1] + 3 * p1[1] - 3 * p2[1] + p3[1]) * s3)
            result.append((x, y))

    result.append(points[-1])
    return result


def render_background(heightmap, mask):
    """从高度场生成底图（8色分级着色）。"""
    h = heightmap.copy()
    h[mask == 0] = 0

    colors = np.array([
        [20, 50, 100], [35, 70, 130], [200, 190, 140], [110, 160, 80],
        [80, 130, 60], [100, 90, 70], [140, 130, 120], [240, 240, 245],
    ], dtype=np.uint8)

    tiers = np.zeros_like(h, dtype=np.uint8)
    ocean = mask == 0
    tiers[ocean & (h < 8)] = 0
    tiers[ocean & (h >= 8)] = 1
    land = mask == 1
    tiers[land & (h < 26)] = 2
    tiers[land & (h >= 26) & (h < 40)] = 3
    tiers[land & (h >= 40) & (h < 55)] = 4
    tiers[land & (h >= 55) & (h < 65)] = 5
    tiers[land & (h >= 65) & (h < 78)] = 6
    tiers[land & (h >= 78)] = 7

    img_arr = colors[tiers]
    return Image.fromarray(img_arr, "RGB")


if __name__ == "__main__":
    main()
