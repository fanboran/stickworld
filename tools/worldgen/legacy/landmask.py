"""大陆轮廓生成：分层 fBm + 域扭曲 + 径向海洋环掩码。

按行分块(slab)处理，内存峰值恒定（不随图片尺寸增长），可生成 8192+。
对应 docs/设计/系统/程序化世界生成.md §5.1。
"""
import gc

import numpy as np

from noise_util import fbm_sample, smoothstep


def generate_landmask(size: int, seed: int, slab_h: int = 128) -> np.ndarray:
    """生成大陆陆地掩码，返回 uint8 (size,size)，1=陆 0=洋。按行分块控制内存。"""
    mask = np.zeros((size, size), dtype=np.uint8)
    sea_level = np.float32(-0.03)
    n_slabs = (size + slab_h - 1) // slab_h
    for i, y0 in enumerate(range(0, size, slab_h)):
        y1 = min(y0 + slab_h, size)
        h = _slab_height(size, seed, y0, y1)
        mask[y0:y1] = (h > sea_level).astype(np.uint8)
        del h
        gc.collect()
        if i % 2 == 0:
            print(f"  landmask {i}/{n_slabs}", flush=True)
    return mask


def _slab_height(size: int, seed: int, y0: int, y1: int) -> np.ndarray:
    """计算 [y0,y1) 行的高度图（float32）。"""
    xs = np.arange(size, dtype=np.float32)
    ys = np.arange(y0, y1, dtype=np.float32)
    PX, PY = np.meshgrid(xs, ys)  # (slab_h, size)

    # 1. 域扭曲
    warp_strength = np.float32(size * 0.12)
    wx = (fbm_sample(PX, PY, size, 8, 3, seed + 101) - np.float32(0.5)) * np.float32(2.0) * warp_strength
    wy = (fbm_sample(PX, PY + size, size, 8, 3, seed + 101) - np.float32(0.5)) * np.float32(2.0) * warp_strength

    # 2. 主高度（低频 fBm）-> [-1,1]
    h = fbm_sample(PX + wx, PY + wy, size, 6, 6, seed) * np.float32(2.0) - np.float32(1.0)

    # 3. 细节叠加
    h = h * np.float32(0.82) + (fbm_sample(PX, PY, size, 30, 4, seed + 202) * np.float32(2.0) - np.float32(1.0)) * np.float32(0.22)

    # 4. 径向海洋环（半径扰动避免完美圆）
    cx = cy = np.float32(size * 0.5)
    half = np.float32(size * 0.5)
    nx = (PX - cx) / half
    ny = (PY - cy) / half
    r = np.sqrt(nx * nx + ny * ny)
    r = r + (fbm_sample(PX, PY, size, 8, 2, seed + 101) - np.float32(0.5)) * np.float32(0.26)
    radial = np.float32(1.0) - smoothstep(0.55, 0.90, r)
    h = h * radial - (np.float32(1.0) - radial) * np.float32(0.5)
    return h


def land_ratio(mask: np.ndarray) -> float:
    return float(mask.mean())
