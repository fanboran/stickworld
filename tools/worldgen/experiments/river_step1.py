"""河流生成 - 步骤1：流域分割

流程：
  1. 从 locked .npy 加载高度场和掩码
  2. 转为裸二进制 .bin（C 加速器读取）
  3. 编译并调用 C 加速器（Priority-Flood + D8 + 海岸聚类 + 反向BFS）
  4. 读取输出的 flow_dir / watershed
  5. 渲染流域预览图（每个流域不同颜色）

产物：
  .tmp/flow_dir.bin       : int8[8192*8192]  D8 流向
  .tmp/watershed.bin      : int32[8192*8192]  流域 ID
  output/locked/river_watershed.npy  : int32 流域标签场
  output/locked/river_flow_dir.npy   : int8 流向场
  output/locked/preview_watershed.png : 流域预览图
"""
import os
import sys
import subprocess
import colorsys
import time

import numpy as np
from PIL import Image

# 路径常量
HERE = os.path.dirname(os.path.abspath(__file__))
OUTPUT_DIR = os.path.join(HERE, "output")
LOCKED_DIR = os.path.join(OUTPUT_DIR, "locked")
TMP_DIR = os.path.abspath(os.path.join(HERE, "..", ".tmp"))

SIZE = 8192


def main():
    os.makedirs(TMP_DIR, exist_ok=True)
    os.makedirs(LOCKED_DIR, exist_ok=True)

    # --- 1. 加载数据 ---
    heightmap_path = os.path.join(LOCKED_DIR, "locked_heightmap_8192.npy")
    mask_path = os.path.join(LOCKED_DIR, "locked_continent_8192.png.npy")

    print("加载高度场...", flush=True)
    heightmap = np.load(heightmap_path)
    print(f"  shape={heightmap.shape}, dtype={heightmap.dtype}, "
          f"range=[{heightmap.min():.1f}, {heightmap.max():.1f}]", flush=True)

    print("加载掩码...", flush=True)
    mask = np.load(mask_path)
    print(f"  shape={mask.shape}, dtype={mask.dtype}, "
          f"land={mask.sum()/mask.size*100:.1f}%", flush=True)

    # --- 2. 转为 .bin ---
    hm_bin = os.path.join(TMP_DIR, "heightmap.bin")
    mask_bin = os.path.join(TMP_DIR, "mask.bin")
    flow_bin = os.path.join(TMP_DIR, "flow_dir.bin")
    ws_bin = os.path.join(TMP_DIR, "watershed.bin")

    print("写出 .bin...", flush=True)
    heightmap.astype(np.float32).tofile(hm_bin)
    mask.astype(np.uint8).tofile(mask_bin)
    del heightmap, mask

    # --- 3. 编译 C 加速器 ---
    c_src = os.path.join(HERE, "river_accel.c")
    exe = os.path.join(HERE, "river_accel.exe")
    if not os.path.exists(exe) or os.path.getmtime(c_src) > os.path.getmtime(exe):
        print("编译 C 加速器...", flush=True)
        cmd = ["gcc", "-O3", "-ffast-math", "-march=native", "-o", exe, c_src, "-lm"]
        ret = subprocess.call(cmd)
        if ret != 0:
            print("编译失败!", flush=True)
            sys.exit(1)
        print("编译完成", flush=True)

    # --- 4. 调用 C 加速器 ---
    print("运行 C 加速器 (Priority-Flood + D8 + 流域分割)...", flush=True)
    t0 = time.time()
    # 不捕获输出，避免管道阻塞（教训 10.5.3）
    ret = subprocess.call([exe, hm_bin, mask_bin, flow_bin, ws_bin])
    t1 = time.time()
    print(f"C 加速器完成, 耗时 {t1-t0:.1f}s, ret={ret}", flush=True)
    if ret != 0:
        print("C 加速器运行失败!", flush=True)
        sys.exit(1)

    # --- 5. 读取输出 ---
    print("读取输出...", flush=True)
    flow_dir = np.fromfile(flow_bin, dtype=np.int8).reshape(SIZE, SIZE)
    watershed = np.fromfile(ws_bin, dtype=np.int32).reshape(SIZE, SIZE)

    n_outlets = int(watershed.max()) + 1 if watershed.max() >= 0 else 0
    n_unassigned = int((watershed == -1).sum())
    print(f"  流域数: {n_outlets}", flush=True)
    print(f"  未分配格子(ws=-1): {n_unassigned}", flush=True)

    # 保存 .npy 供后续步骤使用
    np.save(os.path.join(LOCKED_DIR, "river_flow_dir.npy"), flow_dir)
    np.save(os.path.join(LOCKED_DIR, "river_watershed.npy"), watershed)
    print("  已保存 river_flow_dir.npy + river_watershed.npy", flush=True)

    # --- 6. 渲染预览图 ---
    print("渲染流域预览图...", flush=True)
    preview_path = os.path.join(OUTPUT_DIR, "preview_watershed.png")
    render_watershed_preview(watershed, preview_path)
    print(f"  -> {preview_path}", flush=True)

    print("\n=== 步骤1完成 ===", flush=True)
    print(f"流域数: {n_outlets}", flush=True)
    print("请检查预览图，确认流域分割效果。", flush=True)


def render_watershed_preview(ws: np.ndarray, path: str):
    """渲染流域预览图：每个流域不同颜色，海洋深蓝，未分配灰色。"""
    n_outlets = int(ws.max()) + 1 if ws.max() >= 0 else 0

    # 生成颜色表（HSV 均匀分布）
    colors = np.zeros((n_outlets + 2, 3), dtype=np.uint8)
    for i in range(n_outlets):
        hue = (i / max(n_outlets, 1)) % 1.0
        r, g, b = colorsys.hsv_to_rgb(hue, 0.65, 0.85)
        colors[i] = [int(r * 255), int(g * 255), int(b * 255)]
    colors[n_outlets] = [40, 40, 40]       # 未分配陆地：深灰
    colors[n_outlets + 1] = [20, 50, 100]  # 海洋：深蓝

    # 加载 mask 区分海洋(ws=-1 且 mask=0)和未分配陆地(ws=-1 且 mask=1)
    mask = np.load(os.path.join(LOCKED_DIR, "locked_continent_8192.png.npy"))

    # 构建查表索引
    ws_render = np.full_like(ws, n_outlets + 1)  # 默认海洋色
    land = mask == 1
    ws_render[land] = n_outlets  # 陆地默认未分配色
    ws_render[land & (ws >= 0)] = ws[land & (ws >= 0)]

    img = colors[ws_render]
    Image.fromarray(img, "RGB").save(path)
    del mask


if __name__ == "__main__":
    main()
