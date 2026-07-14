"""噪声工具：numpy 向量化的值噪声 fBm + 域扭曲采样。

不依赖外部噪声库，纯 numpy 实现，适合大尺寸（8192）网格。
"""
import numpy as np


def make_grid(periods_x: int, periods_y: int, seed: int) -> np.ndarray:
    """生成随机值网格（periods+1 个格点，便于插值）。"""
    rng = np.random.default_rng(seed)
    return rng.random((periods_y + 1, periods_x + 1)).astype(np.float32)


def _sample(grid: np.ndarray, gx: np.ndarray, gy: np.ndarray) -> np.ndarray:
    """在分数坐标 (gx, gy) 处双线性采样网格（smoothstep 插值）。全程 float32，低内存。"""
    gh, gw = grid.shape
    gx = np.clip(gx, 0.0, gw - 1.001).astype(np.float32, copy=False)
    gy = np.clip(gy, 0.0, gh - 1.001).astype(np.float32, copy=False)
    x0 = np.floor(gx).astype(np.int32)
    y0 = np.floor(gy).astype(np.int32)
    fx = (gx - x0).astype(np.float32, copy=False)
    fy = (gy - y0).astype(np.float32, copy=False)
    del gx, gy
    _3 = np.float32(3.0)
    _2 = np.float32(2.0)
    u = fx * fx * (_3 - _2 * fx)
    v = fy * fy * (_3 - _2 * fy)
    del fx, fy
    # 分步插值，及时释放中间数组以降低峰值内存
    v00 = grid[y0, x0]
    v10 = grid[y0, x0 + 1]
    a = v00 + (v10 - v00) * u
    del v00, v10
    v01 = grid[y0 + 1, x0]
    v11 = grid[y0 + 1, x0 + 1]
    b = v01 + (v11 - v01) * u
    del v01, v11
    return a + (b - a) * v


def fbm_sample(
    px: np.ndarray,
    py: np.ndarray,
    size: int,
    periods: float,
    octaves: int,
    seed: int,
    lacunarity: float = 2.0,
    gain: float = 0.5,
) -> np.ndarray:
    """在任意像素坐标 (px, py) 处采样 fBm 值噪声，返回 [0,1]。"""
    result = np.zeros_like(px, dtype=np.float32)
    amp = 1.0
    freq = 1.0
    total = 0.0
    for o in range(octaves):
        p = max(1, int(round(periods * freq)))
        g = make_grid(p, p, seed + o * 101)
        gx = px / size * p
        gy = py / size * p
        result += amp * _sample(g, gx, gy)
        total += amp
        amp *= gain
        freq *= lacunarity
    return result / total


def smoothstep(e0: float, e1: float, x: np.ndarray) -> np.ndarray:
    t = np.clip((x - np.float32(e0)) / np.float32(e1 - e0), np.float32(0.0), np.float32(1.0))
    _3 = np.float32(3.0)
    _2 = np.float32(2.0)
    return (t * t * (_3 - _2 * t)).astype(np.float32, copy=False)


def pixel_coords(size: int):
    """返回 (size, size) 的像素坐标网格。"""
    xs = np.arange(size, dtype=np.float32)
    return np.meshgrid(xs, xs)
