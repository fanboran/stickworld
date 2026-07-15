"""分形大陆生成器 - 从剪影生成分形山脉和河流

参考：
  Prusinkiewicz & Hammel 1993 "A Fractal Model of Mountains with Rivers"
  Amit Patel (Red Blob Games) - Polygon Map Generation
  rlguy/FantasyMapGenerator

核心原则：
  - 地形数据存储在三角网格顶点上，不在像素网格上
  - fBm 噪声和海岸距离用小网格(512-1024)采样到顶点
  - 河流在三角网格上追踪（连续空间，无 D8）
  - Squig curve 在连续空间分形弯曲
  - 只有最终渲染才映射到像素
"""

import numpy as np
from scipy.spatial import Delaunay, cKDTree
from scipy.ndimage import distance_transform_edt, binary_erosion, gaussian_filter, label
from PIL import Image, ImageDraw
import random
import math
import os
import time

SIZE = 8192
SEED = 4242424248
N_POINTS = 100000      # 三角剖分点数
N_MOUTHS = 200          # 主干河数量
BRANCH_DEPTH = 6        # 分支递归深度
SQUIG_LEVELS = 3        # squig curve 细分层级（减少以适应大量河流）

HERE = os.path.dirname(os.path.abspath(__file__))
OUTPUT_DIR = os.path.join(HERE, "output")
LOCKED_DIR = os.path.join(OUTPUT_DIR, "locked")


def main():
    rng = random.Random(SEED)
    np_rng = np.random.RandomState(SEED)
    t_start = time.time()

    print("=== 分形大陆生成（三角网格，无像素网格）===", flush=True)

    # 1. 读取掩码 + 连通分量分析（分离外海和内部水域）
    print("1. 读取掩码 + 分离外海/内部水域...", flush=True)
    # 从 png 读取并二值化（画图软件可能产生灰色抗锯齿像素）
    mask_path = os.path.join(LOCKED_DIR, "locked_continent_8192.png")
    mask_img = np.array(Image.open(mask_path).convert('L'))
    gray_cnt = int(((mask_img > 0) & (mask_img < 255)).sum())
    if gray_cnt > 0:
        print(f"   检测到 {gray_cnt} 个灰色像素，已二值化", flush=True)
    mask = (mask_img > 127).astype(np.uint8)  # >127 为陆地，<=127 为水域
    # mask=1 陆地, mask=0 水域；区分外海（连通地图边缘）和内部水域（天池）
    ocean_mask, interior_water_mask, land_for_terrain = separate_ocean(mask)
    print(f"   陆地像素: {int((mask > 0).sum())}, 外海像素: {int(ocean_mask.sum())}, 内部水域像素: {int(interior_water_mask.sum())}", flush=True)

    # 在 land_for_terrain（陆地+内部水域）上采样点，让内部水域也有顶点继承周围地形海拔
    points = sample_points(land_for_terrain, N_POINTS)
    print(f"   点数: {len(points)}", flush=True)

    # 2. Delaunay 三角剖分
    print("2. Delaunay 三角剖分...", flush=True)
    tri = Delaunay(points)
    print(f"   三角形: {len(tri.simplices)}", flush=True)

    # 3. 顶点高度（两阶段：先算初始高度，再算内池 H，最后合成）
    print("3. 顶点高度计算（两阶段）...", flush=True)
    # 3a. 生成地形场（dist_ocean/dist_interior/noise，只生成一次，两阶段复用）
    fields = generate_terrain_fields(ocean_mask, interior_water_mask, np_rng)
    # 3b. 阶段1：仅外海贡献，得到初始高度场
    elevations_init, _ = compute_elevations(points, fields, lake_H_field=None)
    print(f"   阶段1 初始高度: {elevations_init.min():.3f}~{elevations_init.max():.3f}, 均值: {elevations_init.mean():.3f}", flush=True)
    # 3c. 计算每个内池的 H（边缘外扩1像素陆地平均海拔）
    print("   计算内池 H...", flush=True)
    lake_H_field = compute_lake_levels(interior_water_mask, fields, elevations_init, points, tri)
    # 3d. 阶段2：外海+内池合成
    elevations_s2, raw_elevations = compute_elevations(points, fields, lake_H_field=lake_H_field)
    print(f"   阶段2 合成高度: {elevations_s2.min():.3f}~{elevations_s2.max():.3f}, 均值: {elevations_s2.mean():.3f}", flush=True)

    # 3e. 生成两种合成高度：平均、最低（阶段1 vs 阶段2）
    #     注意 elevations_init 和 elevations_s2 都已各自归一化到 [0,1]
    elevations_avg = (elevations_init + elevations_s2) * 0.5
    elevations_min = np.minimum(elevations_init, elevations_s2)
    print(f"   合成(平均): {elevations_avg.min():.3f}~{elevations_avg.max():.3f}, 均值: {elevations_avg.mean():.3f}", flush=True)
    print(f"   合成(最低): {elevations_min.min():.3f}~{elevations_min.max():.3f}, 均值: {elevations_min.mean():.3f}", flush=True)

    # 4. 邻接表（只过滤跨外海的边，内部水域的边保留，使河流可穿过内部水域）
    print("4. 邻接表...", flush=True)
    adj = build_adjacency(len(points), tri, points, ocean_mask)

    # 5. 河流追踪（用 elevations_min 作为地形，更保守避免河流穿海）
    print("5. 河流追踪...", flush=True)
    t0 = time.time()
    rivers = trace_all_rivers(points, adj, elevations_min, land_for_terrain, ocean_mask, N_MOUTHS, rng)
    total = sum(len(r['paths']) for r in rivers)
    print(f"   {time.time()-t0:.1f}s, 主干: {len(rivers)}, 路径: {total}", flush=True)

    # 6. 流量计算（在 squig curve 之前，因为需要顶点索引）
    print("6. 流量计算...", flush=True)
    rain_func = make_rain_sampler(np_rng)
    compute_flows(rivers, rain_func)

    # 7. Squig curve 分形弯曲（连续空间，采样三角网高度；用平均版本作为高度参考）
    print("7. Squig curve...", flush=True)
    elev_func_avg = make_tri_interpolator(points, tri, elevations_avg)
    water_mask = ocean_mask | interior_water_mask
    t0 = time.time()
    for river in rivers:
        for i, path in enumerate(river['paths']):
            coords = [(points[v, 0], points[v, 1]) for v in path]
            flows = river['flows'][i] if i < len(river.get('flows', [])) else None
            new_coords, new_flows = squig_curve(coords, SQUIG_LEVELS, rng, elev_func_avg,
                                                 flows, water_mask)
            river['paths'][i] = new_coords
            if new_flows is not None:
                river['flows'][i] = new_flows
    print(f"   {time.time()-t0:.1f}s", flush=True)

    # 8. 渲染（平均合成版本）
    print("8. 渲染...", flush=True)
    t0 = time.time()
    render(points, tri, elevations_avg, rivers, mask, ocean_mask, interior_water_mask,
           out_name="preview_fractal.png", hm_name="fractal_heightmap_8192.npy")
    print(f"   {time.time()-t0:.1f}s", flush=True)

    print(f"\n总耗时 {time.time()-t_start:.1f}s", flush=True)
    print("完成！请检查 output/preview_fractal.png", flush=True)


# ==================== 采样点 ====================

def separate_ocean(mask):
    """分离外海和内部水域。

    外海 = 连通地图边缘的水域（海拔=0，影响距离场）
    内部水域 = 不连通边缘的水域（天池，应继承周围地形海拔，不影响地形生成）

    返回:
      ocean_mask: 仅外海为 True
      interior_water_mask: 仅内部水域为 True
      land_for_terrain: 陆地 + 内部水域为 True（参与地形生成的区域）
    """
    water = (mask == 0)
    labeled, num = label(water)
    # 找出触碰地图四条边的连通分量 label
    edge_labels = set()
    edge_labels.update(labeled[0, :].tolist())       # 上边
    edge_labels.update(labeled[-1, :].tolist())      # 下边
    edge_labels.update(labeled[:, 0].tolist())       # 左边
    edge_labels.update(labeled[:, -1].tolist())      # 右边
    edge_labels.discard(0)  # 0=陆地

    is_ocean = np.isin(labeled, list(edge_labels))
    ocean_mask = is_ocean & water
    interior_water_mask = (~is_ocean) & water
    land_for_terrain = (mask > 0) | interior_water_mask  # 陆地+内部水域
    return ocean_mask, interior_water_mask, land_for_terrain


def sample_points(mask, n_points):
    """在 land_for_terrain（陆地+内部水域）上采样点 + 海岸线点。

    内部水域也会被采样到，作为继承周围地形海拔的顶点。
    """
    land_y, land_x = np.where(mask > 0)
    n_land = len(land_y)
    n_sample = min(n_points, n_land)
    indices = np.random.randint(0, n_land, n_sample)
    pts = np.column_stack([land_x[indices], land_y[indices]]).astype(np.float64)

    # 海岸线点（陆地一侧，密集采样）— 用 land_for_terrain 的边界
    eroded = binary_erosion(mask)
    coast_mask = mask & ~eroded
    coast_y, coast_x = np.where(coast_mask)
    step = max(1, len(coast_y) // 3000)
    coast_pts = np.column_stack([coast_x[::step], coast_y[::step]]).astype(np.float64)

    pts = np.vstack([pts, coast_pts])

    # 严格过滤：只保留 mask > 0 的点
    keep = mask[pts[:, 1].astype(int), pts[:, 0].astype(int)] > 0
    return pts[keep]


# ==================== 顶点高度（无 8192 网格）====================

# 地形参数
OCEAN_DIST_SCALE = 250.0       # 外海距离比例尺（1024网格像素）
LAKE_DIST_SCALE = 250.0 / 4.0  # 内池距离比例尺 = 外海的 1/4 ≈ 62px（限制影响范围）
LAKE_DELTA = 0.30              # 内池贡献向上幅度 Δ
LAKE_NOISE_COEF = 0.30         # 内池噪声系数（加大扰动避免条带变直线）
OCEAN_NOISE_COEF = 0.40        # 外海噪声系数（加大扰动）
LAKE_FALLOFF_POW = 2.5         # 内池影响权重非线性衰减指数（越大衰减越快）
LAKE_DIST_POW = 3.0            # 内池距离幂次（越大影响范围边缘收敛越快）


def generate_terrain_fields(ocean_mask, interior_water_mask, np_rng):
    """生成地形场（1024 网格）：外海距离场、内池距离场、fBm 噪声。

    只生成一次，两阶段复用，保证噪声一致。
    """
    small = 1024

    # --- 外海距离场（EDT 只用 ocean_mask；内部水域当作陆地连续穿过）---
    ocean_small = np.asarray(
        Image.fromarray(ocean_mask.astype(np.uint8) * 255, mode='L').resize((small, small), Image.NEAREST),
        dtype=np.uint8
    )
    ocean_small_bool = (ocean_small > 127)  # bool: True=外海
    # EDT: ~bool=True(陆地+内部水域) 到 False(外海) 的距离
    dist_ocean = distance_transform_edt(~ocean_small_bool).astype(np.float32)
    dist_ocean = np.clip(dist_ocean / OCEAN_DIST_SCALE, 0, 1)
    dist_ocean = gaussian_filter(dist_ocean, sigma=1.0)

    # --- 内池距离场（比例尺为外海的 1/3，限制在本岛屿内不跨海）---
    interior_small = np.asarray(
        Image.fromarray(interior_water_mask.astype(np.uint8) * 255, mode='L').resize((small, small), Image.NEAREST),
        dtype=np.uint8
    )
    interior_small_bool = (interior_small > 127)  # bool: True=内池

    # 陆地+内水的连通分量（岛屿）：每个岛屿一个 label，外海=0
    land_for_terrain_small = ~ocean_small_bool  # 陆地+内水
    land_label, n_islands = label(land_for_terrain_small)

    # EDT 计算每个像素到最近内池的距离 + 索引
    dist_interior, idx_lake = distance_transform_edt(~interior_small_bool, return_indices=True)
    # 限制：每个像素只受同岛屿内池影响，跨海的距离设为大值
    nearest_island = land_label[idx_lake[0], idx_lake[1]]  # 最近内池所在岛屿
    same_island = (land_label == nearest_island)  # 像素和最近内池在同一岛屿
    dist_interior = np.where(same_island, dist_interior, 9999.0)
    dist_interior = np.clip(dist_interior / LAKE_DIST_SCALE, 0, 1)
    dist_interior = gaussian_filter(dist_interior, sigma=1.0)

    # --- fBm 噪声（1024 网格 FFT）---
    gs = small
    noise = np_rng.randn(gs, gs).astype(np.float32)
    f = np.fft.fft2(noise)
    fx, fy = np.meshgrid(np.fft.fftfreq(gs), np.fft.fftfreq(gs))
    freq = np.sqrt(fx**2 + fy**2)
    freq[0, 0] = 1
    f *= 1.0 / (freq ** 1.0)
    noise = np.real(np.fft.ifft2(f)).astype(np.float32)
    noise = (noise - noise.min()) / (noise.max() - noise.min() + 1e-10)
    noise = gaussian_filter(noise, sigma=1.0)

    return {
        'size': small,
        'dist_ocean': dist_ocean,
        'dist_interior': dist_interior,
        'interior_small_bool': interior_small_bool,
        'land_label': land_label,
        'n_islands': n_islands,
        'noise': noise,
    }


def compute_lake_levels(interior_water_mask, fields, initial_elevations, points, tri):
    """计算每个内池的 H（[0, 边缘海拔] 之间的随机值），并生成 H 影响场。

    阶段1完成后调用：用初始高度场计算每个内池的"海岸海拔"参考值，
    然后 H 在 [0, 边缘海拔] 之间取随机值（每个湖泊独立），
    再把 H 扩展到整个影响范围（每个像素 = 最近内池的 H）。

    返回 lake_H_field（1024 网格，每个像素 = 最近内池的 H，无内池处 = 0）。
    """
    from scipy.interpolate import LinearNDInterpolator
    from scipy.ndimage import binary_dilation

    # 独立随机源（不影响主 rng 序列）
    lake_rng = random.Random(SEED + 7777)

    small = fields['size']
    interior_small_bool = fields['interior_small_bool']

    # --- 阶段1高度场插值到 1024 网格 ---
    interp = LinearNDInterpolator(points, initial_elevations)
    yy, xx = np.mgrid[0:small, 0:small]
    xx_real = xx / small * SIZE
    yy_real = yy / small * SIZE
    elev_grid = interp(xx_real.ravel(), yy_real.ravel()).reshape(small, small)
    elev_grid = np.where(np.isnan(elev_grid), 0.0, elev_grid).astype(np.float32)

    # --- 对每个内池连通分量计算 H ---
    labeled_lakes, n_lakes = label(interior_small_bool)
    # lake_H_per_pixel：先在内池区域填 H，再用 EDT 索引图扩展到全图
    lake_H_seed = np.zeros((small, small), dtype=np.float32)

    if n_lakes == 0:
        print("   无内部水域，跳过内池 H 计算", flush=True)
        return lake_H_seed

    for lake_id in range(1, n_lakes + 1):
        lake_mask = (labeled_lakes == lake_id)
        # 内池边缘外扩1像素的环，再排除其他水域（只取陆地）
        edge_ring = binary_dilation(lake_mask, iterations=1) & ~lake_mask
        edge_land = edge_ring & ~interior_small_bool
        if edge_land.sum() == 0:
            edge_max = 0.5  # 兜底
        else:
            edge_max = float(elev_grid[edge_land].max())  # 边缘外扩1px陆地的最高海拔作为上限
        # H 在 [0, 边缘最高海拔] 之间取随机值（每个湖泊独立）
        H = lake_rng.uniform(0.0, edge_max)
        # 在该内池区域写入 H（作为种子）
        lake_H_seed[lake_mask] = H

    # --- 用 EDT 索引图把 H 扩展到全图（每个像素取最近内池像素的 H）---
    # 限制：只扩展到同岛屿内（不跨海影响其他岛屿）
    land_label = fields['land_label']
    _, indices = distance_transform_edt(~interior_small_bool, return_indices=True)
    idx_y = indices[0]
    idx_x = indices[1]
    lake_H_field = lake_H_seed[idx_y, idx_x]
    # 跨海的 H 设为 0（像素和最近内池不在同一岛屿）
    nearest_island = land_label[idx_y, idx_x]
    same_island = (land_label == nearest_island)
    lake_H_field = np.where(same_island, lake_H_field, 0.0).astype(np.float32)

    # 统计
    h_values = [float(lake_H_seed[labeled_lakes == i].mean()) for i in range(1, n_lakes + 1)]
    print(f"   内池数量: {n_lakes}, H 范围: {min(h_values):.3f}~{max(h_values):.3f}, 均值: {sum(h_values)/len(h_values):.3f}", flush=True)

    return lake_H_field


def compute_elevations(points, fields, lake_H_field=None):
    """在三角网格顶点上计算高度。

    fields: generate_terrain_fields 的返回值（dist_ocean, dist_interior, noise）
    lake_H_field: None=阶段1（仅外海贡献）；非None=阶段2（外海+内池合成）

    高度公式：
      外海贡献: dist_o^1.5 * 0.60 + noise * dist_o * 0.25 （从0开始）
      内池贡献: H + dist_i^1.5 * Δ + noise * dist_i * 小系数 （从H开始）
      合成: 内池附近取 max(ocean, lake)，远处用 ocean（按 dist_i 权重过渡）
    """
    small = fields['size']

    # --- 采样到顶点 ---
    px = points[:, 0] / SIZE * small
    py = points[:, 1] / SIZE * small
    dist_o_at_pts = bilinear_sample(fields['dist_ocean'], px, py)
    noise_at_pts = bilinear_sample(fields['noise'], px, py)

    # 外海贡献（从0开始，随 dist_o 增大）
    elev_ocean = np.power(dist_o_at_pts, 1.5) * 0.60 + noise_at_pts * dist_o_at_pts * OCEAN_NOISE_COEF

    if lake_H_field is not None:
        # 内池贡献（从H开始，随 dist_i 增大；幂次加大让边缘快速收敛）
        dist_i_at_pts = bilinear_sample(fields['dist_interior'], px, py)
        H_at_pts = bilinear_sample(lake_H_field, px, py)
        elev_lake = H_at_pts + np.power(dist_i_at_pts, LAKE_DIST_POW) * LAKE_DELTA + \
                    noise_at_pts * dist_i_at_pts * LAKE_NOISE_COEF

        # 权重：内池边缘 w_lake=1，影响范围边缘 w_lake=0
        # 非线性衰减：(1-dist_i)^FALLOFF_POW，让远距离影响快速衰减
        w_lake = np.clip(1.0 - dist_i_at_pts, 0.0, 1.0) ** LAKE_FALLOFF_POW
        # 合成：内池附近取 max(ocean, lake)（低于H的被抬到H），远处用 ocean
        elevations = elev_ocean * (1.0 - w_lake) + np.maximum(elev_ocean, elev_lake) * w_lake
    else:
        elevations = elev_ocean

    # 归一化
    lo, hi = elevations.min(), elevations.max()
    if hi > lo:
        elevations = (elevations - lo) / (hi - lo)

    # 河流追踪用归一化后的高度
    raw_elevations = elevations.copy()
    return elevations, raw_elevations


def bilinear_sample(grid, x, y):
    """双线性插值采样。x, y 是浮点坐标。"""
    h, w = grid.shape
    xi = np.clip(x.astype(np.int32), 0, w - 2)
    yi = np.clip(y.astype(np.int32), 0, h - 2)
    xf = x - xi
    yf = y - yi
    xf = np.clip(xf, 0, 1)
    yf = np.clip(yf, 0, 1)
    h00 = grid[yi, xi]
    h10 = grid[yi, xi + 1]
    h01 = grid[yi + 1, xi]
    h11 = grid[yi + 1, xi + 1]
    return h00 * (1 - xf) * (1 - yf) + h10 * xf * (1 - yf) + \
           h01 * (1 - xf) * yf + h11 * xf * yf


def make_tri_interpolator(points, tri, values):
    """创建三角网重心坐标插值函数。

    返回 f(x, y) -> elevation，用 scipy 的 Delaunay 三角查找 + 重心坐标。
    """
    from scipy.interpolate import LinearNDInterpolator
    interp = LinearNDInterpolator(points, values)

    def elev_func(x, y):
        v = interp(x, y)
        if np.isnan(v):
            # 落在三角网外，找最近的顶点
            d = (points[:, 0] - x)**2 + (points[:, 1] - y)**2
            return float(values[np.argmin(d)])
        return float(v)

    return elev_func


# ==================== 邻接表 ====================

def build_adjacency(n_points, tri, points, ocean_mask):
    """构建三角网格邻接表，只过滤跨外海的边。

    内部水域的边保留（内部水域当作陆地一样可连通），使河流可穿过内部水域。
    """
    adj = [set() for _ in range(n_points)]
    for simplex in tri.simplices:
        a, b, c = simplex
        for u, v in [(a, b), (b, c), (a, c)]:
            # 检查边中点是否在外海（外海=False 时才连通）
            mx = int((points[u, 0] + points[v, 0]) / 2)
            my = int((points[u, 1] + points[v, 1]) / 2)
            if 0 <= mx < SIZE and 0 <= my < SIZE and not ocean_mask[my, mx]:
                adj[u].add(v)
                adj[v].add(u)
    return [list(s) for s in adj]


# ==================== 河流追踪（三角网流向 + 流量累积）====================

FLOW_THRESHOLD = 10  # 最小累积流量才算河流

def trace_all_rivers(points, adj, elevations, land_for_terrain, ocean_mask, n_mouths, rng):
    """在三角网上计算流向 + 流量累积，提取河流路径。

    land_for_terrain: 陆地+内部水域（都可流过）
    ocean_mask: 仅外海；邻接外海的顶点视为出口（flow_dir=-2）

    内部水域顶点当作普通陆地顶点参与流向计算（继承周围海拔，自然流向下游）。
    """
    n = len(points)
    is_land = np.array([land_for_terrain[int(points[i, 1]), int(points[i, 0])]
                        for i in range(n)], dtype=bool)

    # 海岸顶点：land_for_terrain 顶点中紧邻外海的（用外海膨胀带判断）
    from scipy.ndimage import binary_dilation
    ocean_edge = binary_dilation(ocean_mask, iterations=2)
    is_coast = np.array([ocean_edge[int(points[i, 1]), int(points[i, 0])]
                         for i in range(n)], dtype=bool) & is_land

    # --- 1. Priority-Flood 填洼 + 流向计算（消除洼地断流）---
    print("   Priority-Flood 填洼 + 流向...", flush=True)
    import heapq
    flow_dir = np.full(n, -1, dtype=np.int32)  # -1=未处理, -2=流向外海
    filled_elev = elevations.astype(np.float64).copy()
    visited = np.zeros(n, dtype=bool)

    pq = []
    # 海岸顶点作为起点（最低的先处理，水从海岸向内陆反向传播流向）
    for i in range(n):
        if is_coast[i]:
            heapq.heappush(pq, (filled_elev[i], i))

    while pq:
        h, i = heapq.heappop(pq)
        if visited[i]:
            continue
        visited[i] = True
        for j in adj[i]:
            if not is_land[j] or visited[j]:
                continue
            # 填洼：邻居不能低于当前顶点（消除洼地）
            if filled_elev[j] < h:
                filled_elev[j] = h
            # 流向：j -> i（i 是处理 j 的最低已访问顶点）
            if flow_dir[j] == -1:
                flow_dir[j] = i
            heapq.heappush(pq, (filled_elev[j], j))

    # 海岸顶点未设流向的设为 -2（出流到海洋）
    for i in range(n):
        if is_coast[i] and flow_dir[i] == -1:
            flow_dir[i] = -2

    no_flow = int(np.sum((flow_dir == -1) & is_land))
    print(f"   无流向陆地顶点: {no_flow}/{int(is_land.sum())}", flush=True)

    # --- 2. 流量累积（拓扑排序）---
    print("   流量累积...", flush=True)
    accum = np.ones(n, dtype=np.float32)
    in_degree = np.zeros(n, dtype=np.int32)
    for i in range(n):
        j = flow_dir[i]
        if j >= 0:
            in_degree[j] += 1

    from collections import deque
    queue = deque([i for i in range(n) if in_degree[i] == 0 and flow_dir[i] >= 0])
    while queue:
        i = queue.popleft()
        j = flow_dir[i]
        if j >= 0:
            accum[j] += accum[i]
            in_degree[j] -= 1
            if in_degree[j] == 0:
                queue.append(j)

    print(f"   最大累积: {accum.max():.0f}, 阈值: {FLOW_THRESHOLD}", flush=True)

    # --- 3. 提取河流路径（只从源头追踪，避免重叠）---
    print("   河流提取...", flush=True)
    # 找源头：accum >= threshold 且没有上游邻居也 >= threshold
    has_upstream_river = np.zeros(n, dtype=bool)
    for i in range(n):
        j = flow_dir[i]
        if j >= 0 and accum[i] >= FLOW_THRESHOLD and accum[j] >= FLOW_THRESHOLD:
            has_upstream_river[j] = True

    all_paths = []
    for i in range(n):
        if accum[i] < FLOW_THRESHOLD:
            continue
        if has_upstream_river[i]:
            continue  # 不是源头，跳过（它的上游会经过这里）
        if flow_dir[i] == -1:
            continue  # 无流向（洼地）
        # 从源头沿流向追踪到海岸
        path = [i]
        current = i
        while True:
            d = flow_dir[current]
            if d == -2 or d == -1:
                break  # 到达海洋或洼地
            if accum[d] < FLOW_THRESHOLD * 0.3:
                path.append(d)
                break  # 流量太小，停止
            path.append(d)
            current = d
            if len(path) > 1000:
                break  # 安全限制
        if len(path) >= 3:
            all_paths.append(path)

    print(f"   河流路径: {len(all_paths)}", flush=True)
    # 包装成 rivers 结构（单个流域包含所有路径）
    return [{'paths': all_paths, 'mouth_idx': 0, 'accum': accum}]


# ==================== Squig Curve 分形弯曲 ====================

def squig_curve(path, levels, rng, elev_func, flows=None, water_mask=None):
    """Squig curve 分形弯曲。

    递归中点位移：在每对相邻点间插入中点，
    中点沿垂直方向偏移，偏移方向偏向低地。

    flows: 每个路径点对应的流量值，递归插入中点时同步线性插值。
    water_mask: 水域蒙版，偏移后落在水域的中点回退为原始中点。
    """
    if len(path) < 2:
        return path, flows

    current = list(path)
    current_flows = list(flows) if flows is not None else None

    for level in range(levels):
        scale = 0.15 * (0.65 ** level)  # 降低偏移幅度（0.35->0.15），减少自交叉
        refined = [current[0]]
        refined_flows = [current_flows[0]] if current_flows is not None else None
        for i in range(len(current) - 1):
            x1, y1 = current[i]
            x2, y2 = current[i + 1]
            dx, dy = x2 - x1, y2 - y1
            seg_len = math.hypot(dx, dy)
            if seg_len < 0.5:
                refined.append((x2, y2))
                if current_flows is not None:
                    refined_flows.append(current_flows[i + 1])
                continue

            nx, ny = -dy / seg_len, dx / seg_len
            mx, my = (x1 + x2) / 2, (y1 + y2) / 2
            offset = seg_len * scale

            # 采样两侧地形，偏向低地
            h_pos = elev_func(mx + nx * offset, my + ny * offset)
            h_neg = elev_func(mx - nx * offset, my - ny * offset)
            bias = 1.0 if h_pos < h_neg else -1.0

            displacement = offset * (bias * 0.6 + rng.uniform(-0.4, 0.4))
            mx += nx * displacement
            my += ny * displacement

            # 水域检查：偏移后落在水域则回退为原始中点
            if water_mask is not None:
                mxi, myi = int(mx), int(my)
                if 0 <= mxi < SIZE and 0 <= myi < SIZE and water_mask[myi, mxi]:
                    mx = (x1 + x2) / 2
                    my = (y1 + y2) / 2

            refined.append((mx, my))
            if current_flows is not None:
                # 中点流量 = 两端点流量平均值（线性插值）
                mid_flow = (current_flows[i] + current_flows[i + 1]) * 0.5
                refined_flows.append(mid_flow)

            refined.append((x2, y2))
            if current_flows is not None:
                refined_flows.append(current_flows[i + 1])
        current = refined
        current_flows = refined_flows

    return current, current_flows


# ==================== 流量计算 ====================

def make_rain_sampler(np_rng):
    """创建降雨采样函数（512 网格 fBm）。"""
    gs = 512
    noise = np_rng.randn(gs, gs).astype(np.float32)
    f = np.fft.fft2(noise)
    fx, fy = np.meshgrid(np.fft.fftfreq(gs), np.fft.fftfreq(gs))
    freq = np.sqrt(fx**2 + fy**2)
    freq[0, 0] = 1
    f *= 1.0 / (freq ** 1.0)
    noise = np.real(np.fft.ifft2(f)).astype(np.float32)
    noise = (noise - noise.min()) / (noise.max() - noise.min() + 1e-10)

    def rain_func(x, y):
        nx = x / SIZE * gs
        ny = y / SIZE * gs
        xi = max(0, min(gs - 2, int(nx)))
        yi = max(0, min(gs - 2, int(ny)))
        xf = nx - xi
        yf = ny - yi
        return float(noise[yi, xi] * (1 - xf) * (1 - yf) +
                      noise[yi, xi + 1] * xf * (1 - yf) +
                      noise[yi + 1, xi] * (1 - xf) * yf +
                      noise[yi + 1, xi + 1] * xf * yf)

    return rain_func


def compute_flows(rivers, rain_func):
    """用流量累积值作为每段河流的流量。"""
    for river in rivers:
        accum = river.get('accum')
        for path_idx, path in enumerate(river['paths']):
            n = len(path)
            if n < 2:
                river.setdefault('flows', []).append([1.0] * n)
                continue

            if accum is not None:
                flows = [float(accum[v]) if v < len(accum) else 1.0 for v in path]
            else:
                flows = [1.0] * n

            river.setdefault('flows', []).append(flows)


# ==================== 渲染（唯一映射到像素的步骤）====================

def render(points, tri, elevations, rivers, mask, ocean_mask, interior_water_mask,
           out_name="preview_fractal.png", hm_name="fractal_heightmap_8192.npy"):
    """渲染：高度场插值 + 连续颜色映射 + 三类区域裁剪 + 河流线条。

    三类区域：
      - 外海 (ocean_mask): 深蓝 (25,55,105)，高度场=-0.1
      - 内部水域 (interior_water_mask): 湖泊色 (60,100,140)，高度场=周围地形海拔（保留）
      - 陆地 (mask>0): 地形色，高度场=地形海拔

    策略：2048 插值高度场，放大到 8192，用 256 级 LUT 连续颜色映射（无离散色带），
    再用原始掩码精确裁剪三类区域。
    河流绘制时检查端点+中点是否在水域，穿海线段跳过。
    """
    render_size = 2048

    # --- 高度场插值（2048 分辨率）---
    print("   高度场插值...", flush=True)
    from scipy.interpolate import LinearNDInterpolator
    interp = LinearNDInterpolator(points, elevations)
    scale = render_size / SIZE
    yy, xx = np.mgrid[0:render_size, 0:render_size]
    xx_real = xx / scale  # 映射回 8192 坐标
    yy_real = yy / scale
    hm_vals = interp(xx_real.ravel(), yy_real.ravel())
    hm_small = hm_vals.reshape(render_size, render_size).astype(np.float32)
    # 落在三角网外的点设为 -0.1
    hm_small = np.where(np.isnan(hm_small), -0.1, hm_small)

    # --- 2048 外海高度场裁剪 ---
    ocean_small = np.asarray(
        Image.fromarray(ocean_mask.astype(np.uint8) * 255, mode='L').resize((render_size, render_size), Image.NEAREST),
        dtype=np.uint8
    ) > 127
    hm_small = np.where(ocean_small, np.float32(-0.1), hm_small)

    # --- 放大高度场到 8192 ---
    print("   放大到 8192...", flush=True)
    hm_img = Image.fromarray((np.clip(hm_small, 0, 1) * 255).astype(np.uint8), mode='L')
    hm_img = hm_img.resize((SIZE, SIZE), Image.BILINEAR)
    hm_full = np.asarray(hm_img, dtype=np.float32) / 255.0
    hm_full = np.where(ocean_mask, np.float32(-0.1), hm_full)

    # --- 连续颜色映射（8192，256 级 LUT，无离散色带跳变）---
    print("   颜色映射...", flush=True)
    lut = build_color_lut()
    indices = np.clip((hm_full * 255).astype(np.int32), 0, 255)
    pixels = lut[indices]  # (SIZE, SIZE, 3)

    # --- 8192 用原始掩码精确设置三类区域 ---
    print("   蒙版裁剪...", flush=True)
    pixels[ocean_mask] = [25, 55, 105]            # 外海深蓝
    pixels[interior_water_mask] = [60, 100, 140]  # 内部水域湖泊色
    img = Image.fromarray(pixels)

    # --- 河流绘制（8192 全分辨率）---
    print("   河流绘制...", flush=True)
    draw = ImageDraw.Draw(img, 'RGBA')

    max_flow = 0.0
    for river in rivers:
        for flows in river.get('flows', []):
            if flows:
                max_flow = max(max_flow, max(flows))
    if max_flow < 0.001:
        max_flow = 1.0

    # 水域联合蒙版（外海+内水），用于裁切河流
    water_mask_full = ocean_mask | interior_water_mask

    # 河流统一颜色（不随流量变化）
    RIVER_COLOR = (40, 100, 140, 220)

    for river in rivers:
        for path_idx, path in enumerate(river['paths']):
            flows = river['flows'][path_idx] if path_idx < len(river.get('flows', [])) else []
            if len(path) < 2 or not flows:
                continue

            for i in range(len(path) - 1):
                x1, y1 = path[i]
                x2, y2 = path[i + 1]
                flow = flows[i] if i < len(flows) else flows[-1]

                # 水域裁切：只跳过两端点都在水域的线段（完全在水里）。
                # 一端在水域的线段照画（河流入海口自然延伸到海岸线）。
                ix1, iy1 = int(x1), int(y1)
                ix2, iy2 = int(x2), int(y2)
                if 0 <= iy1 < SIZE and 0 <= ix1 < SIZE and \
                   0 <= iy2 < SIZE and 0 <= ix2 < SIZE:
                    if water_mask_full[iy1, ix1] and water_mask_full[iy2, ix2]:
                        continue

                # 四次根号：大部分河流很细，只有主干粗
                ratio = flow / max_flow
                width = int(math.sqrt(math.sqrt(ratio)) * 6)
                # 只过滤 0 宽度（最细河流保留 1 像素）
                if width < 1:
                    continue

                draw.line([(x1, y1), (x2, y2)],
                          fill=RIVER_COLOR, width=width)

    # 保存图片
    out_path = os.path.join(OUTPUT_DIR, out_name)
    img.save(out_path)
    print(f"   保存 {out_path} ({os.path.getsize(out_path) / 1024 / 1024:.1f} MB)", flush=True)

    # --- 保存高度场 ---
    print("   保存高度场...", flush=True)
    hm_path = os.path.join(OUTPUT_DIR, hm_name)
    np.save(hm_path, hm_full.astype(np.float32))
    print(f"   保存 {hm_path} ({os.path.getsize(hm_path) / 1024 / 1024:.1f} MB)", flush=True)


# 颜色色带控制点（高度, R, G, B）
COLOR_STOPS = [
    (0.00, 205, 195, 145),   # 沙滩
    (0.02, 205, 195, 145),
    (0.15, 115, 165, 85),    # 低地平原
    (0.30, 85, 140, 65),     # 平原
    (0.45, 130, 130, 55),    # 丘陵
    (0.60, 150, 110, 65),    # 山地
    (0.75, 120, 95, 75),     # 高山
    (0.88, 180, 175, 170),   # 苔原
    (1.00, 240, 240, 245),   # 雪峰
]


def build_color_lut():
    """构建 256 级连续颜色 LUT（相邻色带间线性插值，无离散跳变）。

    返回 (256, 3) uint8 数组，用 lut[indices] 直接查表。
    """
    stops_t = np.array([s[0] for s in COLOR_STOPS])
    stops_c = np.array([s[1:] for s in COLOR_STOPS], dtype=np.float32)

    lut = np.zeros((256, 3), dtype=np.uint8)
    for i in range(256):
        e = i / 255.0
        idx = int(np.searchsorted(stops_t, e, side='right') - 1)
        idx = max(0, min(idx, len(stops_t) - 2))
        t0, t1 = stops_t[idx], stops_t[idx + 1]
        f = (e - t0) / (t1 - t0) if t1 > t0 else 0.0
        c = stops_c[idx] * (1 - f) + stops_c[idx + 1] * f
        lut[i] = c.astype(np.uint8)
    return lut


if __name__ == '__main__':
    main()
