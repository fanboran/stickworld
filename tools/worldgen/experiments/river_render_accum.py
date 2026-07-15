"""轻量脚本：读取 accum.bin + 渲染预览图 + 保存 .npy（分块，低内存）"""
import os
import sys
import gc
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OUTPUT_DIR = os.path.join(HERE, "output")
LOCKED_DIR = os.path.join(OUTPUT_DIR, "locked")
TMP_DIR = os.path.abspath(os.path.join(HERE, "..", ".tmp"))
SIZE = 8192

# 读取 accum
print("读取 accum.bin...", flush=True)
accum = np.fromfile(os.path.join(TMP_DIR, "accum.bin"), dtype=np.float32).reshape(SIZE, SIZE)
print(f"  shape={accum.shape}, max={accum.max():.1f}", flush=True)

# 保存 .npy
np.save(os.path.join(LOCKED_DIR, "river_accum.npy"), accum)
print(f"  -> river_accum.npy", flush=True)

# 分块计算对数映射并渲染
print("渲染对数灰度预览（分块）...", flush=True)
max_accum = float(accum.max())
max_log = np.log1p(max_accum)
print(f"  max_accum={max_accum:.1f}, max_log={max_log:.3f}", flush=True)

img = Image.new("L", (SIZE, SIZE))
slab_h = 512
for y0 in range(0, SIZE, slab_h):
    y1 = min(y0 + slab_h, SIZE)
    slab = accum[y0:y1]
    log_slab = np.zeros_like(slab)
    valid = slab > 0
    log_slab[valid] = np.log1p(slab[valid]) / max_log
    gray = (log_slab * 255).astype(np.uint8)
    img.paste(Image.fromarray(gray, "L"), (0, y0))
    del slab, log_slab, gray
    gc.collect()

img.save(os.path.join(OUTPUT_DIR, "preview_accum.png"))
print(f"  -> preview_accum.png", flush=True)
print("完成。", flush=True)
