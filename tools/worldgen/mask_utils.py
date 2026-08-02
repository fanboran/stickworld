"""mask 图像处理工具 —— 从 generate.py 拆分。

职责：mask PNG 读写、双线性采样、掩码放大（域扭曲）、种子派生、正方形 padding。
"""
import gc

import numpy as np
from PIL import Image

from noise_util import make_grid, _sample


def load_mask_png(path: str) -> np.ndarray:
    """从 PNG 读取大陆掩码，返回 uint8 (H,W)，1=陆 0=洋。"""
    img = Image.open(path).convert("L")
    arr = np.array(img, dtype=np.uint8)
    return (arr > 127).astype(np.uint8)


def save_mask_png(mask: np.ndarray, path: str) -> None:
    img = Image.fromarray(mask * 255, "L")
    img.save(path)


def derive_seed(base: int, index: int) -> int:
    """派生子种子（确定性）。"""
    h = (base * 1000003 + index * 9176 + 12345) & 0x7FFFFFFF
    return h


def bilinear_sample_u8(arr: np.ndarray, SX: np.ndarray, SY: np.ndarray) -> np.ndarray:
    """在分数坐标处对 uint8 2D 数组做双线性采样，返回 float32（值域 0-255）。

    逐个从 uint8 数组取值并转 float32，避免全局 float32 数组。
    """
    h, w = arr.shape
    SX = np.clip(SX, np.float32(0.0), np.float32(w - 1.001)).astype(np.float32, copy=False)
    SY = np.clip(SY, np.float32(0.0), np.float32(h - 1.001)).astype(np.float32, copy=False)
    x0 = np.floor(SX).astype(np.int32)
    y0 = np.floor(SY).astype(np.int32)
    fx = (SX - x0).astype(np.float32, copy=False)
    fy = (SY - y0).astype(np.float32, copy=False)
    del SX, SY
    _3 = np.float32(3.0)
    _2 = np.float32(2.0)
    u = fx * fx * (_3 - _2 * fx)
    v = fy * fy * (_3 - _2 * fy)
    del fx, fy
    v00 = arr[y0, x0].astype(np.float32)
    v10 = arr[y0, x0 + 1].astype(np.float32)
    a = v00 + (v10 - v00) * u
    del v00, v10
    v01 = arr[y0 + 1, x0].astype(np.float32)
    v11 = arr[y0 + 1, x0 + 1].astype(np.float32)
    b = v01 + (v11 - v01) * u
    del v01, v11
    return a + (b - a) * v


def resize_mask(mask: np.ndarray, size: int, seed: int = 0) -> np.ndarray:
    """放大掩码 + 多倍频域扭曲边缘。

    用 LANCZOS 放大到连续值，然后对采样坐标做多倍频域扭曲
    （fBm 偏移），再二值化。域扭曲产生有机的海岸线（海湾、半岛、
    碎岛），比加性噪声更自然——它扭曲边界几何而非简单移动阈值。

    连续场存为 uint8（16MB @ 4096）而非 float32（64MB），
    采样时按 slab 转 float32，峰值内存恒定。

    3 层噪声：
      低频(24格)：大海湾/半岛
      中频(80格)：海岸曲折
      高频(256格)：精细锯齿
    """
    img = Image.fromarray(mask * 255, "L")
    img = img.resize((size, size), Image.LANCZOS)
    cont = np.array(img)  # uint8, 16MB
    del img
    gc.collect()

    result = np.zeros((size, size), dtype=np.uint8)
    slab_h = 64
    # 域扭曲幅度：约图像宽度的 1%，产生明显但不破坏大陆形状的边缘扭曲
    warp_amp = np.float32(size * 0.01)
    _2 = np.float32(2.0)
    _1 = np.float32(1.0)
    _thresh = np.float32(127.5)
    _size = np.float32(size)

    # 预生成 3 层噪声网格（x/y 各一组，避免坐标偏移被裁剪）
    g1x = make_grid(24, 24, seed + 1001)
    g1y = make_grid(24, 24, seed + 1002)
    g2x = make_grid(80, 80, seed + 2002)
    g2y = make_grid(80, 80, seed + 2003)
    g3x = make_grid(256, 256, seed + 3003)
    g3y = make_grid(256, 256, seed + 3004)

    n_slabs = (size + slab_h - 1) // slab_h
    _24 = np.float32(24)
    _80 = np.float32(80)
    _256 = np.float32(256)
    _04 = np.float32(0.4)
    _015 = np.float32(0.15)
    for i, y0 in enumerate(range(0, size, slab_h)):
        y1 = min(y0 + slab_h, size)
        xs = np.arange(size, dtype=np.float32)
        ys = np.arange(y0, y1, dtype=np.float32)
        PX, PY = np.meshgrid(xs, ys)
        fx = PX / _size
        fy = PY / _size

        # 3 层域扭曲
        wx1 = (_sample(g1x, fx * _24, fy * _24) * _2 - _1) * warp_amp
        wy1 = (_sample(g1y, fx * _24, fy * _24) * _2 - _1) * warp_amp
        wx2 = (_sample(g2x, fx * _80, fy * _80) * _2 - _1) * warp_amp * _04
        wy2 = (_sample(g2y, fx * _80, fy * _80) * _2 - _1) * warp_amp * _04
        wx3 = (_sample(g3x, fx * _256, fy * _256) * _2 - _1) * warp_amp * _015
        wy3 = (_sample(g3y, fx * _256, fy * _256) * _2 - _1) * warp_amp * _015
        wx = wx1 + wx2 + wx3
        wy = wy1 + wy2 + wy3
        del wx1, wy1, wx2, wy2, wx3, wy3, fx, fy

        # 在扭曲坐标处采样连续场
        SX = np.clip(PX + wx, np.float32(0.0), np.float32(size - 1.001))
        SY = np.clip(PY + wy, np.float32(0.0), np.float32(size - 1.001))
        del PX, PY, wx, wy
        sampled = bilinear_sample_u8(cont, SX, SY)
        del SX, SY

        result[y0:y1] = (sampled > _thresh).astype(np.uint8)
        del sampled
        gc.collect()
        if i % 2 == 0:
            print(f"  resize {i}/{n_slabs} (y={y0})", flush=True)

    del cont, g1x, g1y, g2x, g2y, g3x, g3y
    gc.collect()
    return result


def pad_square_float(arr: np.ndarray, fill: np.float32) -> np.ndarray:
    """居中 pad float32 2D 数组到正方形。"""
    h, w = arr.shape
    m = max(h, w)
    pad_top = (m - h) // 2
    pad_bottom = m - h - pad_top
    pad_left = (m - w) // 2
    pad_right = m - w - pad_left
    return np.pad(arr, ((pad_top, pad_bottom), (pad_left, pad_right)),
                  mode="constant", constant_values=fill)


def pad_square_uint8(arr: np.ndarray, fill: int) -> np.ndarray:
    """居中 pad uint8 2D 数组到正方形。"""
    h, w = arr.shape
    m = max(h, w)
    pad_top = (m - h) // 2
    pad_bottom = m - h - pad_top
    pad_left = (m - w) // 2
    pad_right = m - w - pad_left
    return np.pad(arr, ((pad_top, pad_bottom), (pad_left, pad_right)),
                  mode="constant", constant_values=fill)
