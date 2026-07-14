"""板块构造地形生成（文档 §5.2）。

流程：
  1. Voronoi 板块划分（多源距离场，BFS 生长）
  2. 板块运动方向 → 边界分类（汇聚/离散/转换）
  3. 地形抬升：汇聚边界→山脉脊状抬高；离散→裂谷
  4. 全局高度场 = base + plate_uplift + 细节噪声
  5. 阈值化分级：深海/浅海/海岸/平原/丘陵/山地/高原/雪峰

参考：World-Synth BFS 板块生长 + Benedetti 碰撞高斯位移。
"""
import gc

import numpy as np

from noise_util import fbm_sample, smoothstep, pixel_coords


def generate_tectonic_heightmap(size: int, seed: int, landmask: np.ndarray,
                                 n_plates: int = None) -> np.ndarray:
    """在大陆 mask 上用板块构造生成高度场，返回 float32 (size, size)。"""
    rng = np.random.default_rng(seed)
    land = landmask.astype(bool)

    if n_plates is None:
        n_plates = 8 + int(seed) % 5  # 8-12 个板块

    # 1. 撒板块种子（只在陆地上，均匀散布）
    land_coords = np.argwhere(land)  # (N, 2) = (y, x)
    if len(land_coords) < n_plates * 10:
        n_plates = max(3, len(land_coords) // 20)
    n_plates = min(n_plates, 16)
    seed_idx = rng.choice(len(land_coords), n_plates, replace=False)
    seeds = land_coords[seed_idx]  # (n_plates, 2), 每行 [y, x]
    print(f"  板块数: {n_plates}", flush=True)

    # 2. Voronoi 分配（分块计算距离场，取 argmin）
    print("  Voronoi 分配...", flush=True)
    plate_id = _voronoi_assign(size, seeds, land)
    gc.collect()

    # 3. 板块运动方向（单位向量）
    angles = rng.uniform(0, 2 * np.pi, n_plates).astype(np.float32)
    plate_dirs = np.column_stack([np.cos(angles), np.sin(angles)]).astype(np.float32)

    # 4. 边界抬升
    print("  边界抬升...", flush=True)
    uplift = _compute_uplift(plate_id, plate_dirs, land, n_plates)
    gc.collect()

    # 5. 全局高度场 = base + uplift + 细节噪声
    print("  合成高度场...", flush=True)
    PX, PY = pixel_coords(size)
    # 基础高度：陆地 0.25，海洋 -0.15
    base = np.where(land, np.float32(0.25), np.float32(-0.15))
    # 细节噪声（低频，不喧宾夺主）
    detail = (fbm_sample(PX, PY, size, 15, 4, seed + 999) * np.float32(2.0) - np.float32(1.0)) * np.float32(0.08)
    detail *= land.astype(np.float32)
    del PX, PY
    gc.collect()

    heightmap = (base + uplift + detail).astype(np.float32)
    # 海洋不抬升
    heightmap[~land] = np.minimum(heightmap[~land], np.float32(-0.05))
    return heightmap


def _voronoi_assign(size: int, seeds: np.ndarray, land: np.ndarray) -> np.ndarray:
    """多源距离场分配板块 ID。分块计算控制内存。

    seeds: (n, 2), 每行 [y, x]
    返回 int32 (size, size)，海洋为 -1。
    """
    n = len(seeds)
    sy = seeds[:, 0].astype(np.float32)  # (n,)
    sx = seeds[:, 1].astype(np.float32)

    plate_id = np.full((size, size), -1, dtype=np.int32)
    slab_h = 64
    for y0 in range(0, size, slab_h):
        y1 = min(y0 + slab_h, size)
        h = y1 - y0
        ys = np.arange(y0, y1, dtype=np.float32)[:, None]  # (h, 1)
        xs = np.arange(size, dtype=np.float32)[None, :]    # (1, w)
        # 距离 (n, h, w) — 逐板块计算避免 (n,h,w) 同时在内存
        best_dist = np.full((h, size), np.float32(1e30), dtype=np.float32)
        best_id = np.zeros((h, size), dtype=np.int32)
        for i in range(n):
            dy = ys - sy[i]  # (h, 1)
            dx = xs - sx[i]  # (1, w)
            dist = dy * dy + dx * dx  # (h, w) 广播
            mask = dist < best_dist
            best_dist = np.where(mask, dist, best_dist)
            best_id = np.where(mask, i, best_id)
        plate_id[y0:y1] = best_id
    plate_id[~land] = -1
    return plate_id


def _compute_uplift(plate_id: np.ndarray, plate_dirs: np.ndarray,
                     land: np.ndarray, n_plates: int) -> np.ndarray:
    """计算板块边界抬升量。

    汇聚边界（陆-陆）→ 山脉（脊状抬高）
    离散边界 → 裂谷（轻微下降）
    转换边界 → 不抬升
    """
    size = plate_id.shape[0]
    uplift = np.zeros((size, size), dtype=np.float32)

    # 板块间汇聚度矩阵：负点积 = 汇聚（正值），正点积 = 离散（负值）
    # convergence[i,j] = -dot(dirs[i], dirs[j])
    # >0 = 汇聚, <0 = 离散, ≈0 = 转换
    convergence = np.zeros((n_plates, n_plates), dtype=np.float32)
    for i in range(n_plates):
        for j in range(n_plates):
            if i != j:
                convergence[i, j] = -float(np.dot(plate_dirs[i], plate_dirs[j]))

    # 对每对板块，找边界并施加抬升
    for i in range(n_plates):
        mask_i = (plate_id == i)
        if not mask_i.any():
            continue
        for j in range(i + 1, n_plates):
            conv = convergence[i, j]
            if abs(conv) < 0.15:
                continue  # 转换边界，跳过
            mask_j = (plate_id == j)
            if not mask_j.any():
                continue
            # i 中邻接 j 的像素 + j 中邻接 i 的像素
            boundary = _adjacent_mask(mask_i, mask_j) | _adjacent_mask(mask_j, mask_i)
            if not boundary.any():
                continue
            if conv > 0:
                # 汇聚 → 山脉抬升（汇聚越强，山越高）
                uplift[boundary] += np.float32(conv * 0.5)
            else:
                # 离散 → 裂谷（轻微下降）
                uplift[boundary] += np.float32(conv * 0.15)
        # 每处理几个板块释放一次
        if i % 4 == 3:
            gc.collect()

    # 高斯模糊让山脉从边界向两侧自然过渡
    print("  模糊抬升场...", flush=True)
    uplift = _blur(uplift, land, passes=4)
    return uplift


def _adjacent_mask(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    """a 中邻接 b 的像素（4 邻域）。"""
    result = np.zeros_like(a)
    result[1:, :] |= a[1:, :] & b[:-1, :]
    result[:-1, :] |= a[:-1, :] & b[1:, :]
    result[:, 1:] |= a[:, 1:] & b[:, :-1]
    result[:, :-1] |= a[:, :-1] & b[:, 1:]
    return result


def _blur(arr: np.ndarray, land: np.ndarray, passes: int = 4) -> np.ndarray:
    """多次 box blur 近似高斯模糊，只在陆地内扩散。"""
    result = arr.copy()
    land_f = land.astype(np.float32)
    for _ in range(passes):
        # 3x3 box blur
        acc = result.copy()
        cnt = np.ones_like(result)
        # 4 邻域
        acc[1:, :] += result[:-1, :]; cnt[1:, :] += 1
        acc[:-1, :] += result[1:, :]; cnt[:-1, :] += 1
        acc[:, 1:] += result[:, :-1]; cnt[:, 1:] += 1
        acc[:, :-1] += result[:, 1:]; cnt[:, :-1] += 1
        # 对角
        acc[1:, 1:] += result[:-1, :-1]; cnt[1:, 1:] += 1
        acc[1:, :-1] += result[:-1, 1:]; cnt[1:, :-1] += 1
        acc[:-1, 1:] += result[1:, :-1]; cnt[:-1, 1:] += 1
        acc[:-1, :-1] += result[1:, 1:]; cnt[:-1, :-1] += 1
        result = acc / cnt
        # 海洋不扩散抬升
        result[~land] = np.float32(0.0)
    return result


def render_heightmap(heightmap: np.ndarray, landmask: np.ndarray, path: str) -> None:
    """渲染高度场为彩色地形图（高度分级着色，无群系无河流）。"""
    from PIL import Image

    land = landmask.astype(bool)
    h = heightmap

    # 陆地高度归一化到 [0, 1]
    land_h = h.copy()
    if land.any():
        lh = land_h[land]
        lo, hi = float(lh.min()), float(lh.max())
        if hi > lo:
            land_h[land] = (lh - lo) / (hi - lo)
        land_h[~land] = np.float32(0)

    rgb = np.zeros((h.shape[0], h.shape[1], 3), dtype=np.uint8)

    # 海洋：按深度渐变深蓝→浅蓝
    ocean = ~land
    if ocean.any():
        oh = h[ocean]
        lo, hi = float(oh.min()), float(oh.max())
        if hi > lo:
            od = (oh - lo) / (hi - lo)  # 0=浅, 1=深
        else:
            od = np.zeros_like(oh)
        # 浅海 rgb(40,90,140) → 深海 rgb(10,25,60)
        rgb[ocean, 0] = (40 - od * 30).astype(np.uint8)
        rgb[ocean, 1] = (90 - od * 65).astype(np.uint8)
        rgb[ocean, 2] = (140 - od * 80).astype(np.uint8)

    # 陆地按高度分级（泾渭分明）
    # 海岸 < 0.12: 沙色
    coast = land & (land_h < np.float32(0.12))
    rgb[coast] = [210, 200, 150]
    # 平原 0.12~0.35: 浅绿
    plains = land & (land_h >= np.float32(0.12)) & (land_h < np.float32(0.35))
    rgb[plains] = [130, 175, 85]
    # 丘陵 0.35~0.55: 深绿
    hills = land & (land_h >= np.float32(0.35)) & (land_h < np.float32(0.55))
    rgb[hills] = [95, 145, 65]
    # 山地 0.55~0.75: 棕色
    mtn = land & (land_h >= np.float32(0.55)) & (land_h < np.float32(0.75))
    rgb[mtn] = [125, 105, 75]
    # 高原 0.75~0.88: 深棕
    plateau = land & (land_h >= np.float32(0.75)) & (land_h < np.float32(0.88))
    rgb[plateau] = [100, 85, 70]
    # 雪峰 >= 0.88: 白
    snow = land & (land_h >= np.float32(0.88))
    rgb[snow] = [245, 245, 250]

    img = Image.fromarray(rgb, "RGB")
    img.save(path)


def heightmap_stats(heightmap: np.ndarray, landmask: np.ndarray) -> dict:
    """统计各级地形占比。"""
    land = landmask.astype(bool)
    total = landmask.size
    land_h = heightmap.copy()
    if land.any():
        lh = land_h[land]
        lo, hi = float(lh.min()), float(lh.max())
        if hi > lo:
            land_h[land] = (lh - lo) / (hi - lo)

    stats = {}
    stats["深海"] = float(np.sum(~land & (heightmap < np.float32(-0.1)))) / total
    stats["浅海"] = float(np.sum(~land & (heightmap >= np.float32(-0.1)))) / total
    stats["海岸"] = float(np.sum(land & (land_h < np.float32(0.12)))) / total
    stats["平原"] = float(np.sum(land & (land_h >= np.float32(0.12)) & (land_h < np.float32(0.35)))) / total
    stats["丘陵"] = float(np.sum(land & (land_h >= np.float32(0.35)) & (land_h < np.float32(0.55)))) / total
    stats["山地"] = float(np.sum(land & (land_h >= np.float32(0.55)) & (land_h < np.float32(0.75)))) / total
    stats["高原"] = float(np.sum(land & (land_h >= np.float32(0.75)) & (land_h < np.float32(0.88)))) / total
    stats["雪峰"] = float(np.sum(land & (land_h >= np.float32(0.88)))) / total
    return stats
