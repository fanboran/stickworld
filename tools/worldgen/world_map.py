"""世界地图生成：在锁定大陆掩码上派生 高程/山脉、生物群落、河流。

群系按行分块计算（内存恒定）；河流在低分辨率高程上追踪再放大。
对应 docs/设计/系统/程序化世界生成.md §5.2-5.4。
"""
import gc

import numpy as np

from noise_util import fbm_sample, pixel_coords, smoothstep
from landmask import generate_landmask

# 生物群落 ID
BIOME_OCEAN_DEEP = 0
BIOME_OCEAN_SHALLOW = 1
BIOME_BEACH = 2
BIOME_PLAINS = 3
BIOME_FOREST = 4
BIOME_DESERT = 5
BIOME_TUNDRA = 6
BIOME_MOUNTAIN = 7
BIOME_SNOW_PEAK = 8
BIOME_JUNGLE = 9

BIOME_COLORS = np.array([
    [0.05, 0.10, 0.25], [0.10, 0.28, 0.48], [0.84, 0.79, 0.55],
    [0.46, 0.66, 0.31], [0.20, 0.45, 0.20], [0.86, 0.71, 0.40],
    [0.72, 0.76, 0.73], [0.46, 0.41, 0.36], [0.95, 0.95, 0.96],
    [0.15, 0.42, 0.16],
], dtype=np.float32)

BIOME_NAMES = ["深海", "浅海", "海岸", "平原", "森林", "荒漠", "冻原", "山地", "雪峰", "丛林"]

_DX = [-1, 0, 1, -1, 1, -1, 0, 1]
_DY = [-1, -1, -1, 0, 0, 1, 1, 1]


class WorldMap:
    def __init__(self, size: int, seed: int, landmask: np.ndarray):
        self.size = size
        self.seed = seed
        self.landmask = landmask
        self.biome = np.zeros((size, size), dtype=np.uint8)
        self.is_river = np.zeros((size, size), dtype=np.uint8)


def generate_world_map(size: int, seed: int, landmask: np.ndarray, slab_h: int = 64,
                       heightmap: np.ndarray = None) -> WorldMap:
    """在给定大陆掩码上生成群系/河流。

    Args:
        heightmap: 可选外部高度场 (size,size) float32，值域 0-100（<20=水）。
                   如果提供，群系和河流都基于它（跳过内部 fbm 高程计算）。
                   对应 terrain_template.py 的 Azgaar 模板法高度场。
    """
    wm = WorldMap(size, seed, landmask)
    use_external_h = heightmap is not None
    if use_external_h:
        print("  使用外部高度场（Azgaar 模板法）", flush=True)

    # 0. 预计算海岸距离场（低分辨率，用于高程调制：越靠海越低，越内陆越高）
    #    外部高度场模式下不需要（高度场已包含内陆信息）
    coast_dist = None
    cd_res = 0
    if not use_external_h:
        cd_res = min(size, 1024)
        print("  coast distance...", flush=True)
        coast_dist = _compute_coast_distance(landmask, cd_res)
        print("  coast distance done", flush=True)

    # 1. 群系（分块计算）
    n_slabs = (size + slab_h - 1) // slab_h
    for i, y0 in enumerate(range(0, size, slab_h)):
        y1 = min(y0 + slab_h, size)
        wm.biome[y0:y1] = _slab_biome(size, seed, landmask, y0, y1, coast_dist, cd_res,
                                       heightmap=heightmap)
        gc.collect()
        if i % 2 == 0:
            print(f"  biome {i}/{n_slabs}", flush=True)

    # 2. 河流（复用 coast_dist 保证高程一致性；外部高度场模式下用外部高度场）
    print("  rivers...", flush=True)
    river_res = min(size, 1024)
    river_mask = _rivers_lowres(size, seed, river_res, landmask, coast_dist, cd_res,
                                heightmap=heightmap)
    wm.is_river = _upscale_rivers(river_mask, size, landmask)
    del coast_dist
    gc.collect()
    print("  rivers done", flush=True)
    return wm


def _compute_coast_distance(landmask: np.ndarray, res: int) -> np.ndarray:
    """计算到海岸线的距离场（低分辨率）。

    返回 float32 (res, res)，陆地为归一化内陆度 [0, 1]（0=海岸线，1=内陆深处），
    海洋为 0。用多轮膨胀近似 BFS 距离。
    """
    from PIL import Image
    img = Image.fromarray(landmask * 255, "L")
    img = img.resize((res, res), Image.BILINEAR)
    lm = (np.array(img) > 127).astype(np.uint8)
    del img

    land = lm.astype(bool)
    # 海岸线 = 陆地且邻接海洋
    neighbor_ocean = np.zeros_like(land)
    neighbor_ocean[1:, :] |= ~land[:-1, :]
    neighbor_ocean[:-1, :] |= ~land[1:, :]
    neighbor_ocean[:, 1:] |= ~land[:, :-1]
    neighbor_ocean[:, :-1] |= ~land[:, 1:]
    coast_line = land & neighbor_ocean

    # BFS 距离：从海岸线向内陆扩散
    dist = np.zeros((res, res), dtype=np.float32)
    current = coast_line.copy()
    max_d = 0
    for d in range(1, 200):
        expanded = np.zeros_like(current)
        expanded[1:, :] |= current[:-1, :]
        expanded[:-1, :] |= current[1:, :]
        expanded[:, 1:] |= current[:, :-1]
        expanded[:, :-1] |= current[:, 1:]
        expanded &= land
        new = expanded & ~current
        if not new.any():
            break
        dist[new] = float(d)
        current |= expanded
        max_d = d
        if d % 20 == 0:
            print(f"    coast bfs d={d}", flush=True)

    if max_d > 0:
        dist /= float(max_d)
    return dist


def _slab_biome(size: int, seed: int, landmask: np.ndarray, y0: int, y1: int,
                coast_dist=None, cd_res: int = 0, heightmap: np.ndarray = None) -> np.ndarray:
    """计算 [y0,y1) 行的群系。"""
    xs = np.arange(size, dtype=np.float32)
    ys = np.arange(y0, y1, dtype=np.float32)
    PX, PY = np.meshgrid(xs, ys)
    land_slab = landmask[y0:y1].astype(bool)

    if heightmap is not None:
        # 外部高度场模式：elev = heightmap / 100（0-1 范围），跳过 fbm 高程计算
        # 海洋高度（<20）映射为负值，陆地高度（≥20）映射为 0.2+
        elev = (heightmap[y0:y1] / np.float32(100.0)).astype(np.float32)
    else:
        # 原始 fbm 高程模式
        # 高程（低频 ridge 让山脉集中成带，不散碎；海岸距离调制让内陆更高）
        ridge = fbm_sample(PX, PY, size, 5, 4, seed + 301) * np.float32(2.0) - np.float32(1.0)
        mountain = smoothstep(np.float32(-0.15), np.float32(0.45), ridge) * np.float32(0.78)
        depth = np.abs(fbm_sample(PX, PY, size, 10, 3, seed + 601) * np.float32(2.0) - np.float32(1.0))

        # 海岸距离调制：海岸附近 inland≈0（低地），内陆深处 inland≈1（可出高山）
        if coast_dist is not None and cd_res > 0:
            scale_cd = np.float32(cd_res) / np.float32(size)
            ys_cd = np.clip((np.arange(y0, y1, dtype=np.float32) * scale_cd).astype(np.int32), 0, cd_res - 1)
            xs_cd = np.clip((np.arange(size, dtype=np.float32) * scale_cd).astype(np.int32), 0, cd_res - 1)
            inland = coast_dist[ys_cd][:, xs_cd]
        else:
            inland = np.ones(land_slab.shape, dtype=np.float32)

        # 高程公式：海岸基础低(0.12)，内陆乘子高(0.25+0.75*inland)
        elev = np.where(land_slab,
                        np.float32(0.12) + mountain * (np.float32(0.25) + np.float32(0.75) * inland),
                        np.float32(-0.08) - depth * np.float32(0.45)).astype(np.float32, copy=False)

    # 温度（纬度主导 + 低频扰动 + 高海拔降温）
    cy = np.float32(size * 0.5)
    lat = np.abs(PY - cy) / np.float32(size * 0.5)
    temp = (np.float32(1.0) - lat) + (fbm_sample(PX, PY, size, 4, 3, seed + 401) * np.float32(2.0) - np.float32(1.0)) * np.float32(0.25)
    temp = np.where(land_slab, temp - np.maximum(np.float32(0.0), elev - np.float32(0.3)) * np.float32(0.55), temp)
    temp = np.clip(temp, np.float32(0.0), np.float32(1.0))

    # 湿度（低频让湿度区域更大块，减少迷彩感）
    moist = np.clip(fbm_sample(PX, PY, size, 4, 4, seed + 501), np.float32(0.0), np.float32(1.0))

    return _classify_biome(land_slab, elev, temp, moist, landmask, y0, y1, size, external_elev=heightmap is not None)


def _classify_biome(land_slab, elev, temp, moist, landmask, y0, y1, size, external_elev=False):
    """向量化群系分类（对 slab）。

    external_elev: True 时使用与 terrain_template TIER_THRESHOLDS 对齐的阈值
                   （elev = heightmap/100，故阈值 = TIER_THRESHOLDS/100）。
    """
    biome = np.zeros(land_slab.shape, dtype=np.uint8)
    biome[...] = BIOME_OCEAN_DEEP

    # 浅海：海洋格邻接陆地
    land_full = landmask
    neighbor_land = np.zeros_like(land_slab)
    if y0 > 0:
        neighbor_land[0, :] |= land_full[y0 - 1, :].astype(bool)
    neighbor_land[1:, :] |= land_slab[:-1, :]
    neighbor_land[:-1, :] |= land_slab[1:, :]
    if y1 < size:
        neighbor_land[-1, :] |= land_full[y1, :].astype(bool)
    neighbor_land[:, 1:] |= land_slab[:, :-1]
    neighbor_land[:, :-1] |= land_slab[:, 1:]

    ocean = ~land_slab
    biome[ocean & neighbor_land] = BIOME_OCEAN_SHALLOW

    # 海岸：陆地且邻接海洋
    neighbor_ocean = np.zeros_like(land_slab)
    if y0 > 0:
        neighbor_ocean[0, :] |= ~land_full[y0 - 1, :].astype(bool)
    neighbor_ocean[1:, :] |= ~land_slab[:-1, :]
    neighbor_ocean[:-1, :] |= ~land_slab[1:, :]
    if y1 < size:
        neighbor_ocean[-1, :] |= ~land_full[y1, :].astype(bool)
    neighbor_ocean[:, 1:] |= ~land_slab[:, :-1]
    neighbor_ocean[:, :-1] |= ~land_slab[:, 1:]

    if external_elev:
        # 外部高度场阈值（对齐 terrain_template TIER_THRESHOLDS）
        # elev = h/100，故阈值 = TIER_THRESHOLDS / 100
        beach_thr = np.float32(0.26)   # h < 26
        mtn_thr = np.float32(0.65)     # h > 65
        snow_thr = np.float32(0.78)    # h > 78
    else:
        # 原始 fbm 高程阈值
        beach_thr = np.float32(0.22)
        mtn_thr = np.float32(0.45)
        snow_thr = np.float32(0.72)

    beach = land_slab & neighbor_ocean & (elev < beach_thr)
    biome[beach] = BIOME_BEACH

    # 高程覆盖（阶梯式：海滩 < 平原/森林 < 山地 < 雪峰）
    rest = land_slab & ~beach
    snow = rest & (elev > snow_thr)
    biome[snow] = BIOME_SNOW_PEAK
    mtn = rest & (elev > mtn_thr) & ~snow
    biome[mtn] = BIOME_MOUNTAIN

    # Whittaker
    rest2 = rest & ~snow & ~mtn
    hot = rest2 & (temp > 0.65)
    biome[hot & (moist > 0.55)] = BIOME_JUNGLE
    biome[hot & (moist > 0.35) & (moist <= 0.55)] = BIOME_FOREST
    biome[hot & (moist <= 0.35)] = BIOME_DESERT
    temp_zone = rest2 & (temp > 0.35) & (temp <= 0.65)
    biome[temp_zone & (moist > 0.50)] = BIOME_FOREST
    biome[temp_zone & (moist <= 0.50)] = BIOME_PLAINS
    biome[rest2 & (temp <= 0.35)] = BIOME_TUNDRA
    return biome


def _rivers_lowres(size: int, seed: int, res: int, landmask: np.ndarray,
                   coast_dist: np.ndarray = None, cd_res: int = 0,
                   heightmap: np.ndarray = None) -> np.ndarray:
    """在低分辨率高程上追踪河流。

    关键：landmask 从全尺寸降采样（不用 generate_landmask 重新生成），
    保证河流追踪的地形和实际显示的大陆完全一致，不会在海洋上出现河流。
    如果提供 heightmap，用外部高度场（缩放到 res）替代 fbm 高程。
    """
    from PIL import Image
    img = Image.fromarray(landmask * 255, "L")
    img = img.resize((res, res), Image.LANCZOS)
    lm = (np.array(img, dtype=np.float32) / np.float32(255.0) > np.float32(0.5)).astype(np.uint8)
    del img

    PX, PY = pixel_coords(res)
    land = lm.astype(bool)

    if heightmap is not None:
        # 外部高度场模式：缩放到 res，归一化到 0-1
        img = Image.fromarray(heightmap.astype(np.float32), "F")
        img = img.resize((res, res), Image.BILINEAR)
        elev = (np.array(img, dtype=np.float32) / np.float32(100.0)).astype(np.float32)
        del img
        # 河流源头阈值：外部高度场 h > 55 (elev > 0.55，对应 hills 区间)
        source_thr = np.float32(0.55)
    else:
        # 原始 fbm 高程模式
        ridge = fbm_sample(PX, PY, res, 5, 4, seed + 301) * np.float32(2.0) - np.float32(1.0)
        mountain = smoothstep(np.float32(-0.15), np.float32(0.45), ridge) * np.float32(0.78)
        depth = np.abs(fbm_sample(PX, PY, res, 10, 3, seed + 601) * np.float32(2.0) - np.float32(1.0))
        if coast_dist is not None and cd_res > 0 and cd_res == res:
            inland = coast_dist
        else:
            inland = np.ones(land.shape, dtype=np.float32)
        elev = np.where(land,
                        np.float32(0.12) + mountain * (np.float32(0.25) + np.float32(0.75) * inland),
                        np.float32(-0.08) - depth * np.float32(0.45)).astype(np.float32, copy=False)
        source_thr = np.float32(0.45)

    river = np.zeros((res, res), dtype=np.uint8)
    rng = np.random.default_rng(seed + 707)
    sy, sx = np.where(land & (elev > source_thr))
    n_sources = 0
    if len(sx) > 0:
        # 源头比例：外部高度场用更低比例（大陆很大，减少河流数量）
        source_ratio = 0.02 if heightmap is not None else 0.08
        pick = rng.random(len(sx)) < source_ratio
        sources = list(zip(sx[pick], sy[pick]))
        n_sources = len(sources)
        print(f"    河流源头数: {n_sources} (比例 {source_ratio:.0%})", flush=True)
        for i, (rx, ry) in enumerate(sources):
            _trace_river(elev, lm, river, int(rx), int(ry))
            if (i + 1) % 200 == 0:
                print(f"    river {i+1}/{n_sources}", flush=True)
    return river


def _trace_river(elev, landmask, river, sx, sy):
    res = elev.shape[0]
    x, y = sx, sy
    steps = 0
    while steps < 800:
        if x < 0 or x >= res or y < 0 or y >= res:
            return
        if not landmask[y, x]:
            return
        river[y, x] = 1
        cur = elev[y, x]
        best = cur
        bx = by = -1
        for k in range(8):
            nx = x + _DX[k]
            ny = y + _DY[k]
            if nx < 0 or nx >= res or ny < 0 or ny >= res:
                continue
            ne = elev[ny, nx]
            if ne < best - 0.001:
                best = ne
                bx, by = nx, ny
        if bx < 0:
            return
        x, y = bx, by
        steps += 1


def _upscale_rivers(arr: np.ndarray, size: int, landmask: np.ndarray) -> np.ndarray:
    """LANCZOS 放大河流 mask，用 landmask 裁剪确保河流只在陆地。"""
    if arr.shape[0] == size:
        return arr & landmask
    from PIL import Image
    img = Image.fromarray(arr * 255, "L")
    img = img.resize((size, size), Image.LANCZOS)
    # 用 uint8 而非 float32，内存 16MB vs 64MB
    result = np.array(img, dtype=np.uint8)
    del img
    result = (result > 64).astype(np.uint8)  # 0.25 * 255 ≈ 64
    result &= landmask  # 裁剪：河流只在陆地，不会出现在海洋
    return result


def render_png(wm: WorldMap, path: str) -> None:
    """渲染彩色 PNG（群系色 + 河流蓝），分块写入。"""
    from PIL import Image
    river_color = np.array([0.25, 0.55, 0.92], dtype=np.float32)
    river_rgb = (river_color * np.float32(255.0)).astype(np.uint8)
    img = Image.new("RGB", (wm.size, wm.size))
    slab_h = 512
    _255 = np.float32(255.0)
    for y0 in range(0, wm.size, slab_h):
        y1 = min(y0 + slab_h, wm.size)
        colors = (BIOME_COLORS[wm.biome[y0:y1]] * _255).astype(np.uint8)
        colors[wm.is_river[y0:y1].astype(bool)] = river_rgb
        slab_img = Image.fromarray(colors, "RGB")
        img.paste(slab_img, (0, y0))
    img.save(path)


def biome_stats(wm: WorldMap) -> dict:
    counts = {}
    total = wm.biome.size
    for b in range(len(BIOME_NAMES)):
        n = int(np.sum(wm.biome == b))
        counts[b] = n / total
    return counts
