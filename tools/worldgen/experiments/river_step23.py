"""河流生成 - 步骤2+3：降雨噪声 + 流量累积

流程：
  步骤2: fBm 噪声生成降雨量场 [0,1] + 灰度预览图
  步骤3: C 加速器加权流量累积（每格初始流量=降雨量，沿D8流向Kahn拓扑排序累加）
         + 对数灰度预览图

输入：
  output/locked/river_flow_dir.npy  : int8 D8 流向（步骤1产物）
  output/locked/locked_continent_8192.png.npy : uint8 大陆掩码

产物：
  output/locked/river_rainfall.npy  : float32 降雨量场
  output/locked/river_accum.npy     : float32 流量累积场
  output/preview_rainfall.png       : 降雨预览图
  output/preview_accum.png          : 流量累积预览图（对数灰度）
"""
import os
import sys
import subprocess
import gc
import time

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OUTPUT_DIR = os.path.join(HERE, "output")
LOCKED_DIR = os.path.join(OUTPUT_DIR, "locked")
TMP_DIR = os.path.abspath(os.path.join(HERE, "..", ".tmp"))
sys.path.insert(0, HERE)

from noise_util import fbm_sample, pixel_coords

SIZE = 8192
SEED = 4242424248


def main():
    os.makedirs(TMP_DIR, exist_ok=True)

    # ============ 步骤2：降雨噪声 ============
    print("=== 步骤2：降雨噪声 ===", flush=True)
    rainfall_path = os.path.join(LOCKED_DIR, "river_rainfall.npy")
    mask = np.load(os.path.join(LOCKED_DIR, "locked_continent_8192.png.npy"))

    # 分块生成 fBm 降雨场（低频让降雨区域大块，4 octaves）
    print("  生成 fBm 降雨场 (periods=8, octaves=4)...", flush=True)
    rainfall = np.zeros((SIZE, SIZE), dtype=np.float32)
    slab_h = 256
    for y0 in range(0, SIZE, slab_h):
        y1 = min(y0 + slab_h, SIZE)
        xs = np.arange(SIZE, dtype=np.float32)
        ys = np.arange(y0, y1, dtype=np.float32)
        PX, PY = np.meshgrid(xs, ys)
        # fBm: periods=8 (大块降雨区域), octaves=4, gain=0.5
        r = fbm_sample(PX, PY, SIZE, 8, 4, SEED + 801)
        rainfall[y0:y1] = r
        del PX, PY, r
        gc.collect()
        if y0 % 1024 == 0:
            print(f"    rainfall {y0}/{SIZE}", flush=True)

    # 降雨量映射到 [0.1, 1.0]（避免完全无雨的区域）
    rainfall = np.clip(rainfall, 0.0, 1.0)
    rainfall = 0.1 + 0.9 * rainfall  # [0.1, 1.0]
    # 海洋降雨设为 0
    rainfall[mask == 0] = 0.0

    print(f"  降雨场: min={rainfall[mask==1].min():.3f}, max={rainfall.max():.3f}, "
          f"mean={rainfall[mask==1].mean():.3f}", flush=True)
    np.save(rainfall_path, rainfall)
    print(f"  -> {rainfall_path}", flush=True)

    # 降雨预览图（灰度）
    preview_rain = os.path.join(OUTPUT_DIR, "preview_rainfall.png")
    img = (rainfall * 255).astype(np.uint8)
    Image.fromarray(img, "L").save(preview_rain)
    print(f"  降雨预览 -> {preview_rain}", flush=True)

    del mask
    gc.collect()

    # ============ 步骤3：流量累积 ============
    print("\n=== 步骤3：流量累积 ===", flush=True)
    flow_dir = np.load(os.path.join(LOCKED_DIR, "river_flow_dir.npy"))
    print(f"  flow_dir: shape={flow_dir.shape}, range=[{flow_dir.min()}, {flow_dir.max()}]", flush=True)

    # 写 .bin 给 C 加速器
    flow_bin = os.path.join(TMP_DIR, "flow_dir.bin")
    rain_bin = os.path.join(TMP_DIR, "rainfall.bin")
    mask_bin = os.path.join(TMP_DIR, "mask.bin")
    accum_bin = os.path.join(TMP_DIR, "accum.bin")

    flow_dir.tofile(flow_bin)
    rainfall.tofile(rain_bin)
    mask2 = np.load(os.path.join(LOCKED_DIR, "locked_continent_8192.png.npy"))
    mask2.tofile(mask_bin)
    del mask2
    gc.collect()

    # 编译 C 加速器
    c_src = os.path.join(HERE, "river_accum.c")
    exe = os.path.join(HERE, "river_accum.exe")
    if not os.path.exists(exe) or os.path.getmtime(c_src) > os.path.getmtime(exe):
        print("  编译 C 加速器...", flush=True)
        ret = subprocess.call(["gcc", "-O3", "-ffast-math", "-march=native", "-o", exe, c_src, "-lm"])
        if ret != 0:
            print("  编译失败!", flush=True)
            sys.exit(1)
        print("  编译完成", flush=True)

    # 运行
    print("  运行流量累积 C 加速器...", flush=True)
    t0 = time.time()
    ret = subprocess.call([exe, flow_bin, rain_bin, mask_bin, accum_bin])
    t1 = time.time()
    print(f"  C 加速器完成, 耗时 {t1-t0:.1f}s, ret={ret}", flush=True)
    if ret != 0:
        print("  C 加速器运行失败!", flush=True)
        sys.exit(1)

    # 读取结果
    accum = np.fromfile(accum_bin, dtype=np.float32).reshape(SIZE, SIZE)
    np.save(os.path.join(LOCKED_DIR, "river_accum.npy"), accum)
    print(f"  -> {os.path.join(LOCKED_DIR, 'river_accum.npy')}", flush=True)

    # 流量累积预览图（对数灰度）
    mask = np.load(os.path.join(LOCKED_DIR, "locked_continent_8192.png.npy"))
    land_accum = accum[mask == 1]
    print(f"  陆地流量累积: min={land_accum.min():.1f}, max={land_accum.max():.1f}, "
          f"median={np.median(land_accum):.1f}", flush=True)

    preview_accum = os.path.join(OUTPUT_DIR, "preview_accum.png")
    # 对数映射：log(1+accum) / log(1+max)
    log_accum = np.zeros_like(accum)
    valid = accum > 0
    log_accum[valid] = np.log1p(accum[valid])
    max_log = log_accum[valid].max() if valid.any() else 1.0
    log_accum[valid] /= max_log
    img = (log_accum * 255).astype(np.uint8)
    Image.fromarray(img, "L").save(preview_accum)
    print(f"  流量累积预览 -> {preview_accum}", flush=True)

    print("\n=== 步骤2+3完成 ===", flush=True)
    print(f"降雨场: {rainfall_path}", flush=True)
    print(f"流量累积场: {os.path.join(LOCKED_DIR, 'river_accum.npy')}", flush=True)
    print("请检查预览图。", flush=True)


if __name__ == "__main__":
    main()
