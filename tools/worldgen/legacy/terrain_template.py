"""Azgaar 模板法地形生成（忠实移植 Fantasy-Map-Generator heightmap-generator.ts）。

核心设计：
  1. 在低分辨率 cell 网格（GRID_N×GRID_N）上做所有 Azgaar 操作
     - 对应 Azgaar 的 Voronoi cell 图（~40000 cells）
     - blobPower/linePower 按 Azgaar 的 cells→power 映射表取值
  2. BFS 传播 + 幂衰减（而非高斯衰减），忠实还原 addHill/addPit
  3. 图上贪心寻路 + BFS 扩散，忠实还原 addRange/addTrough
  4. 椭圆距离 Mask：distance = (1-nx²)(1-ny²)，乘法混合
  5. 最后双线性插值放大到目标尺寸，叠加 landmask

参考源码：
  external/Fantasy-Map-Generator/src/generators/heightmap-generator.ts
  external/Fantasy-Map-Generator/public/config/heightmap-templates.js
"""
import gc
import numpy as np
from collections import deque
from noise_util import fbm_sample, pixel_coords

# ─────────────────────────── 常量 ───────────────────────────
WATER_LEVEL = 20.0

# 低分辨率 cell 网格尺寸（对应 Azgaar ~10000 cells）
# GRID_N 越小 → blobPower 越低 → 衰减越快 → 地形内聚性越强
GRID_N = 100

# Azgaar blobPower/linePower 映射表（cellsDesired → power）
# 10000 cells → blobPower=0.98, linePower=0.81（均为 Azgaar 推荐值）
BLOB_POWER = 0.98
LINE_POWER = 0.81

# 渲染色板（高度分级）
TIER_COLORS = {
    "deep_ocean":  (35,  70, 130),
    "ocean":       (50,  100, 160),
    "shallow":     (75,  130, 180),
    "coast":       (210, 200, 150),
    "plains":      (130, 175, 85),
    "hills":       (95,  145, 65),
    "mountain":    (125, 105, 75),
    "plateau":     (170, 160, 155),  # 合并原 snow，用浅灰表示高地
}

# 高度分级阈值（值域 0-100，与 Azgaar 一致：<20=水）
# 原始阈值：配合从 1024 高度场超分到 8192 的方案，保持小岛屿地形层次
TIER_THRESHOLDS = {
    "deep_ocean":  (-1e9, 8.0),
    "ocean":       (8.0, 14.0),
    "shallow":     (14.0, 19.0),
    "coast":       (19.0, 26.0),
    "plains":      (26.0, 55.0),
    "hills":       (55.0, 65.0),
    "mountain":    (65.0, 78.0),
    "plateau":     (78.0, 1e9),
}


# ─────────────────────────── Azgaar 真实模板 ───────────────────────────
# 直接从 heightmap-templates.js 复制，格式完全一致：
# 每行一个操作，参数用空格分隔：Tool count height rangeX rangeY
# count/height/rangeX/rangeY 可以是 "1" 或 "5-6" 范围

_TPL_VOLCANO = """Hill 1 90-100 44-56 40-60
Multiply 0.8 50-100 0 0
Range 1.5 30-55 45-55 40-60
Smooth 3 0 0 0
Hill 1.5 35-45 25-30 20-75
Hill 1 35-55 75-80 25-75
Hill 0.5 20-25 10-15 20-25
Mask 3 0 0 0"""

_TPL_CONTINENTS = """Hill 1 80-85 60-80 40-60
Hill 1 80-85 20-30 40-60
Hill 6-7 15-30 25-75 15-85
Multiply 0.6 land 0 0
Hill 8-10 5-10 15-85 20-80
Range 1-2 30-60 5-15 25-75
Range 1-2 30-60 80-95 25-75
Range 0-3 30-60 80-90 20-80
Strait 2 vertical 0 0
Strait 1 vertical 0 0
Smooth 3 0 0 0
Trough 3-4 15-20 15-85 20-80
Trough 3-4 5-10 45-55 45-55
Pit 3-4 10-20 15-85 20-80
Mask 4 0 0 0"""

_TPL_ARCHIPELAGO = """Add 11 all 0 0
Range 2-3 40-60 20-80 20-80
Hill 5 15-20 10-90 30-70
Hill 2 10-15 10-30 20-80
Hill 2 10-15 60-90 20-80
Smooth 3 0 0 0
Trough 10 20-30 5-95 5-95
Strait 2 vertical 0 0
Strait 2 horizontal 0 0"""

_TPL_OLD_WORLD = """Range 3 70 15-85 20-80
Hill 2-3 50-70 15-45 20-80
Hill 2-3 50-70 65-85 20-80
Hill 4-6 20-25 15-85 20-80
Multiply 0.5 land 0 0
Smooth 2 0 0 0
Range 3-4 20-50 15-35 20-45
Range 2-4 20-50 65-85 45-80
Strait 3-7 vertical 0 0
Trough 6-8 20-50 15-85 45-65
Pit 5-6 20-30 10-90 10-90"""

_TPL_PANGEA = """Hill 1-2 25-40 15-50 0-10
Hill 1-2 5-40 50-85 0-10
Hill 1-2 25-40 50-85 90-100
Hill 1-2 5-40 15-50 90-100
Hill 8-12 20-40 20-80 48-52
Smooth 2 0 0 0
Multiply 0.7 land 0 0
Trough 3-4 25-35 5-95 10-20
Trough 3-4 25-35 5-95 80-90
Range 5-6 30-40 10-90 35-65"""

TEMPLATES = {
    "continents": _TPL_CONTINENTS,
    "archipelago": _TPL_ARCHIPELAGO,
    "oldWorld": _TPL_OLD_WORLD,
    "pangea": _TPL_PANGEA,
    "volcano": _TPL_VOLCANO,
}


# ─────────────────────────── 主生成函数 ───────────────────────────
def generate_template_heightmap(size, seed, landmask, template_name="continents"):
    """在 landmask 上用 Azgaar 模板法生成高度场。

    Args:
        size: 目标图像尺寸（像素）
        seed: 随机种子
        landmask: uint8 (size,size)，1=陆地 0=海洋
        template_name: TEMPLATES 中的模板名

    Returns:
        float32 (size,size)，值域 0-100，<20=水
    """
    rng = np.random.default_rng(seed)
    template_str = TEMPLATES.get(template_name, TEMPLATES["continents"])

    # 1. 将 landmask 缩放到低分辨率 cell 网格
    from PIL import Image
    img = Image.fromarray(landmask * 255, "L")
    img = img.resize((GRID_N, GRID_N), Image.LANCZOS)
    cell_land = (np.array(img) > 127).astype(np.uint8)
    del img

    # 2. 在 cell 网格上初始化高度场（陆地=20, 海洋=0）
    #    Azgaar 初始 heights 全 0，模板操作添加高度
    h = np.where(cell_land, np.float32(WATER_LEVEL), np.float32(0.0)).astype(np.float32)

    # 3. 解析并执行模板操作
    steps = [s.strip() for s in template_str.strip().split("\n") if s.strip()]
    for step in steps:
        parts = step.split()
        tool = parts[0]
        args = parts[1:]
        _execute_step(h, cell_land, rng, GRID_N, tool, args)

    # 4. 钳制到 [0, 100]
    np.clip(h, 0, 100, out=h)

    # 5. 双线性插值放大到目标尺寸
    img = Image.fromarray(h.astype(np.float32), "F")
    img = img.resize((size, size), Image.BILINEAR)
    h_full = np.array(img).astype(np.float32)
    del img

    # 6. 用原始 landmask 修正：海洋强制 <20，陆地强制 ≥20
    land_full = landmask.astype(bool)
    # 海洋：保持放大后的值（应该 <20），但确保 <19
    h_full[~land_full] = np.minimum(h_full[~land_full], np.float32(19.0))
    # 陆地：确保 ≥20
    h_full[land_full] = np.maximum(h_full[land_full], np.float32(20.0))

    # 7. 海洋深度分层
    _add_ocean_layers(h_full, land_full, rng)

    return h_full


# ─────────────────────────── 模板执行器 ───────────────────────────
def _execute_step(h, land, rng, n, tool, args):
    """执行一个模板步骤（对应 Azgaar addStep）。"""
    if tool == "Hill":
        # Hill count height rangeX rangeY
        count, height, rx, ry = args[0], args[1], args[2], args[3]
        _add_hill(h, land, rng, n, count, height, rx, ry)
    elif tool == "Pit":
        # Pit count height rangeX rangeY
        count, height, rx, ry = args[0], args[1], args[2], args[3]
        _add_pit(h, land, rng, n, count, height, rx, ry)
    elif tool == "Range":
        # Range count height rangeX rangeY
        count, height, rx, ry = args[0], args[1], args[2], args[3]
        _add_range(h, land, rng, n, count, height, rx, ry, is_trough=False)
    elif tool == "Trough":
        # Trough count height rangeX rangeY
        count, height, rx, ry = args[0], args[1], args[2], args[3]
        _add_range(h, land, rng, n, count, height, rx, ry, is_trough=True)
    elif tool == "Strait":
        # Strait width direction
        width, direction = args[0], args[1]
        _add_strait(h, land, rng, n, width, direction)
    elif tool == "Mask":
        # Mask power
        power = float(args[0])
        _apply_mask(h, n, power)
    elif tool == "Add":
        # Add value range _ _
        val = float(args[0])
        rng_range = args[1]
        _modify(h, rng_range, add=val, mult=1.0)
    elif tool == "Multiply":
        # Multiply factor range _ _
        factor = float(args[0])
        rng_range = args[1]
        _modify(h, rng_range, add=0, mult=factor)
    elif tool == "Smooth":
        # Smooth fr _ _ _
        fr = float(args[0])
        _smooth(h, fr)


def _get_range_val(rng, s):
    """解析 "5-6" 或 "5" 格式的范围值。"""
    if "-" in s:
        lo, hi = s.split("-")
        return rng.uniform(float(lo), float(hi))
    return float(s)


def _get_point_in_range(rng, s, length):
    """解析百分比范围 "25-75"，返回 [0, length) 内的坐标。"""
    if "-" in s:
        lo, hi = s.split("-")
    else:
        lo = hi = s
    return rng.uniform(float(lo) / 100 * length, float(hi) / 100 * length)


# ─────────────────────────── Hill/Pit（BFS 传播 + 幂衰减） ───────────────────────────
def _add_hill(h, land, rng, n, count_s, height_s, rx, ry):
    """Azgaar addHill：BFS 传播，change[c] = change[q]^blobPower * random(0.9,1.1)。

    当 change < 1 时停止传播。
    """
    count = int(_get_range_val(rng, count_s))
    for _ in range(count):
        # 随机选起点（在指定范围内）
        cx = int(_get_point_in_range(rng, rx, n))
        cy = int(_get_point_in_range(rng, ry, n))
        cx = max(0, min(n - 1, cx))
        cy = max(0, min(n - 1, cy))
        if not land[cy, cx]:
            continue
        height = _get_range_val(rng, height_s)
        height = min(height, 100.0)
        _bfs_propagate(h, land, n, cy, cx, height, BLOB_POWER, rng, sign=1)


def _add_pit(h, land, rng, n, count_s, height_s, rx, ry):
    """Azgaar addPit：BFS 传播降低高度。"""
    count = int(_get_range_val(rng, count_s))
    for _ in range(count):
        cx = int(_get_point_in_range(rng, rx, n))
        cy = int(_get_point_in_range(rng, ry, n))
        cx = max(0, min(n - 1, cx))
        cy = max(0, min(n - 1, cy))
        # Pit 只在陆地上（h >= 20）
        if h[cy, cx] < WATER_LEVEL:
            continue
        depth = _get_range_val(rng, height_s)
        _bfs_propagate(h, land, n, cy, cx, depth, BLOB_POWER, rng, sign=-1)


def _bfs_propagate(h, land, n, sy, sx, height, power, rng, sign=1):
    """BFS 传播高度变化（忠实还原 Azgaar addHill 的传播逻辑）。

    Azgaar 原版：
      change[start] = h
      queue = [start]
      while queue:
          q = queue.pop(0)
          for c in neighbors(q):
              if change[c]: continue
              change[c] = change[q]^power * random(0.9, 1.1)
              if change[c] > 1: queue.push(c)
      heights += change * sign

    我们用向量化波前扩展实现，8 邻域近似圆形传播。
    """
    change = np.zeros((n, n), dtype=np.float32)
    visited = np.zeros((n, n), dtype=bool)
    visited[sy, sx] = True
    change[sy, sx] = height

    frontier = np.zeros((n, n), dtype=bool)
    frontier[sy, sx] = True

    while frontier.any():
        # 8 邻域扩展
        new_frontier = _dilate8(frontier) & ~visited & land.astype(bool)
        if not new_frontier.any():
            break

        # 获取每个 new_frontier cell 的最大邻居 change 值
        padded = np.pad(change, 1, mode="constant", constant_values=0)
        neighbors = np.stack([
            padded[:-2, 1:-1],   # up
            padded[2:, 1:-1],    # down
            padded[1:-1, :-2],   # left
            padded[1:-1, 2:],    # right
            padded[:-2, :-2],    # up-left
            padded[:-2, 2:],     # up-right
            padded[2:, :-2],     # down-left
            padded[2:, 2:],      # down-right
        ])
        neighbor_max = neighbors.max(axis=0)

        # 幂衰减 + 随机因子
        rand_factor = rng.uniform(0.9, 1.1, (n, n)).astype(np.float32)
        new_change = neighbor_max ** np.float32(power) * rand_factor

        change[new_frontier] = new_change[new_frontier]

        # 只传播 >1 的变化
        propagate = new_frontier & (change > 1.0)
        visited |= new_frontier
        frontier = propagate

    # 应用变化
    if sign > 0:
        h += change
    else:
        h -= change
    np.clip(h, 0, 100, out=h)


# ─────────────────────────── Range/Trough（图上寻路 + BFS 扩散） ───────────────────────────
def _add_range(h, land, rng, n, count_s, height_s, rx, ry, is_trough=False):
    """Azgaar addRange/addTrough：贪心寻路 + BFS 扩散。"""
    count = int(_get_range_val(rng, count_s))
    for _ in range(count):
        # 选起点
        sx = int(_get_point_in_range(rng, rx, n))
        sy = int(_get_point_in_range(rng, ry, n))
        sx = max(0, min(n - 1, sx))
        sy = max(0, min(n - 1, sy))

        if is_trough:
            # Trough 起点必须在陆地
            if h[sy, sx] < WATER_LEVEL:
                continue
        else:
            # Range 起点如果太高就跳过（Azgaar: heights[start]+h > 90）
            if h[sy, sx] > 90:
                continue

        # 选终点（Azgaar: dist 在 graphWidth/8 到 graphWidth/3 之间）
        ex = ey = 0
        for _try in range(50):
            ex = int(rng.uniform(n * 0.1, n * 0.9))
            ey = int(rng.uniform(n * 0.15, n * 0.85))
            dist = abs(ey - sy) + abs(ex - sx)
            if n / 8 <= dist <= n / 3:
                break

        height = _get_range_val(rng, height_s)

        # 贪心寻路
        path = _find_path(land, n, sy, sx, ey, ex, rng)

        if is_trough:
            _propagate_along_path(h, land, n, path, height, LINE_POWER, rng, sign=-1)
        else:
            _propagate_along_path(h, land, n, path, height, LINE_POWER, rng, sign=1)


def _find_path(land, n, sy, sx, ey, ex, rng, randomness=0.15):
    """贪心寻路：每步选离终点最近的未访问邻居（Azgaar getRange）。"""
    path = [(sy, sx)]
    visited = set()
    visited.add((sy, sx))
    cy, cx = sy, sx

    while (cy, cx) != (ey, ex):
        best = None
        best_dist = float("inf")
        for dy, dx in [(-1, 0), (1, 0), (0, -1), (0, 1),
                       (-1, -1), (-1, 1), (1, -1), (1, 1)]:
            ny, nx = cy + dy, cx + dx
            if (ny, nx) in visited:
                continue
            if ny < 0 or ny >= n or nx < 0 or nx >= n:
                continue
            if not land[ny, nx]:
                continue
            diff = (ey - ny) ** 2 + (ex - nx) ** 2
            # 随机扰动（Azgaar: if Math.random() > 1-randomness: diff /= 2）
            if rng.random() > 1 - randomness:
                diff /= 2
            if diff < best_dist:
                best_dist = diff
                best = (ny, nx)

        if best is None:
            break
        cy, cx = best
        visited.add((cy, cx))
        path.append((cy, cx))

        if len(path) > n * n:
            break

    return path


def _propagate_along_path(h, land, n, path, height, power, rng, sign=1):
    """沿路径 BFS 扩散高度（Azgaar addRange 的扩散部分）。"""
    if not path:
        return

    visited = np.zeros((n, n), dtype=bool)
    for y, x in path:
        visited[y, x] = True

    # 路径上的点直接加高
    rand_factor = rng.uniform(0.85, 1.15, len(path)).astype(np.float32)
    for i, (y, x) in enumerate(path):
        if sign > 0:
            h[y, x] = min(100.0, h[y, x] + height * rand_factor[i])
        else:
            h[y, x] = max(0.0, h[y, x] - height * rand_factor[i])

    # BFS 扩散
    frontier = visited.copy()
    cur_h = height

    while frontier.any() and cur_h > 2:
        cur_h = cur_h ** power - 1
        if cur_h < 2:
            break

        new_frontier = _dilate8(frontier) & ~visited & land.astype(bool)
        if not new_frontier.any():
            break

        rand = rng.uniform(0.85, 1.15, (n, n)).astype(np.float32)
        delta = cur_h * rand

        if sign > 0:
            h[new_frontier] = np.minimum(100.0, h[new_frontier] + delta[new_frontier])
        else:
            h[new_frontier] = np.maximum(0.0, h[new_frontier] - delta[new_frontier])

        visited |= new_frontier
        frontier = new_frontier


# ─────────────────────────── Strait（水道） ───────────────────────────
def _add_strait(h, land, rng, n, width_s, direction="vertical"):
    """Azgaar addStrait：沿路径强制降低高度。"""
    width = int(_get_range_val(rng, width_s))
    width = min(width, n // 3)
    if width < 1:
        return

    vert = direction == "vertical"
    if vert:
        sx = int(rng.uniform(n * 0.3, n * 0.7))
        sy = 5
        ex = int(n - sx - n * 0.1 + rng.uniform(0, n * 0.2))
        ey = n - 5
    else:
        sx = 5
        sy = int(rng.uniform(n * 0.3, n * 0.7))
        ex = n - 5
        ey = int(n - sy - n * 0.1 + rng.uniform(0, n * 0.2))

    path = _find_path(land, n, sy, sx, ey, ex, rng, randomness=0.2)

    # 沿路径扩展宽度
    used = np.zeros((n, n), dtype=bool)
    frontier_pts = path[:]
    step = 0.1 / width

    for i in range(width):
        remaining = width - i
        exp = 0.9 - step * remaining
        next_pts = []
        for y, x in frontier_pts:
            for dy, dx in [(-1, 0), (1, 0), (0, -1), (0, 1),
                           (-1, -1), (-1, 1), (1, -1), (1, 1)]:
                ny, nx = y + dy, x + dx
                if ny < 0 or ny >= n or nx < 0 or nx >= n:
                    continue
                if used[ny, nx]:
                    continue
                used[ny, nx] = True
                next_pts.append((ny, nx))
                # Azgaar: heights[e] **= exp
                h[ny, nx] = h[ny, nx] ** exp
                if h[ny, nx] > 100:
                    h[ny, nx] = 5
        frontier_pts = next_pts


# ─────────────────────────── Mask（椭圆距离 + 乘法混合） ───────────────────────────
def _apply_mask(h, n, power):
    """Azgaar mask：distance = (1-nx²)(1-ny²)，乘法混合。

    power > 0: 中心高、边缘低（标准）
    power < 0: 中心低、边缘高（反转）
    fr = abs(power) 控制混合比例：result = (h*(fr-1) + h*distance) / fr
    """
    fr = abs(power) if power != 0 else 1
    xs = np.arange(n, dtype=np.float32)
    nx = (2.0 * xs[None, :] / n) - 1.0  # [-1, 1]
    ny = (2.0 * xs[:, None] / n) - 1.0
    distance = (1.0 - nx * nx) * (1.0 - ny * ny)  # 中心1，边缘0
    if power < 0:
        distance = 1.0 - distance
    masked = h * distance
    h[:] = (h * (fr - 1) + masked) / fr
    np.clip(h, 0, 100, out=h)


# ─────────────────────────── Modify / Smooth ───────────────────────────
def _modify(h, rng_range, add=0, mult=1.0, power=None):
    """Azgaar modify：对指定高度范围应用数学运算。"""
    if rng_range == "land":
        lo, hi = 20.0, 100.0
    elif rng_range == "all":
        lo, hi = 0.0, 100.0
    else:
        parts = rng_range.split("-")
        lo, hi = float(parts[0]), float(parts[1])

    mask = (h >= lo) & (h <= hi)
    is_land = (lo == 20.0)

    if add != 0:
        if is_land:
            h[mask] = np.maximum(h[mask] + add, 20.0)
        else:
            h[mask] += add
    if mult != 1.0:
        if is_land:
            h[mask] = (h[mask] - 20.0) * mult + 20.0
        else:
            h[mask] *= mult
    if power is not None:
        if is_land:
            h[mask] = (h[mask] - 20.0) ** power + 20.0
        else:
            h[mask] = h[mask] ** power
    np.clip(h, 0, 100, out=h)


def _smooth(h, fr=2, add=0):
    """Azgaar smooth：邻域平均混合。"""
    # 4 邻域平均
    padded = np.pad(h, 1, mode="edge")
    neighbor_mean = (padded[:-2, 1:-1] + padded[2:, 1:-1] +
                     padded[1:-1, :-2] + padded[1:-1, 2:]) / 4.0
    h[:] = (h * (fr - 1) + neighbor_mean + add) / fr
    np.clip(h, 0, 100, out=h)


# ─────────────────────────── 海洋深度分层 ───────────────────────────
def _add_ocean_layers(h, land, rng):
    """参考 Azgaar OceanLayers，从海岸线向外分层生成海洋深度。"""
    ocean = ~land
    current = land.copy()

    # shallow: 距离 1-3
    for i in range(3):
        new_current = _dilate4(current)
        ring = new_current & ocean & ~current
        if not ring.any():
            break
        h[ring] = np.float32(18.0 - i * 1.5)
        current = new_current

    # ocean: 距离 4-12
    for i in range(9):
        new_current = _dilate4(current)
        ring = new_current & ocean & ~current
        if not ring.any():
            break
        h[ring] = np.float32(14.0 - i * 0.7)
        current = new_current

    # deep_ocean: 剩余
    remaining = ocean & ~current
    if remaining.any():
        deep = rng.uniform(3.0, 7.0, remaining.sum()).astype(np.float32)
        h[remaining] = deep


# ─────────────────────────── 内部工具 ───────────────────────────
def _dilate8(mask):
    """8 邻域膨胀。"""
    d = mask.copy()
    d[1:, :] |= mask[:-1, :]
    d[:-1, :] |= mask[1:, :]
    d[:, 1:] |= mask[:, :-1]
    d[:, :-1] |= mask[:, 1:]
    d[1:, 1:] |= mask[:-1, :-1]
    d[1:, :-1] |= mask[:-1, 1:]
    d[:-1, 1:] |= mask[1:, :-1]
    d[:-1, :-1] |= mask[1:, 1:]
    return d


def _dilate4(mask):
    """4 邻域膨胀。"""
    d = mask.copy()
    d[1:, :] |= mask[:-1, :]
    d[:-1, :] |= mask[1:, :]
    d[:, 1:] |= mask[:, :-1]
    d[:, :-1] |= mask[:, 1:]
    return d


# ─────────────────────────── 渲染 ───────────────────────────
def render_heightmap(heightmap, landmask, path):
    """渲染高度场为彩色地形图（高度分级着色）。"""
    from PIL import Image
    h = heightmap
    rgb = np.zeros((h.shape[0], h.shape[1], 3), dtype=np.uint8)
    for tier, (lo, hi) in TIER_THRESHOLDS.items():
        mask = (h >= lo) & (h < hi)
        if mask.any():
            rgb[mask] = TIER_COLORS[tier]
    img = Image.fromarray(rgb, "RGB")
    img.save(path)


def heightmap_stats(heightmap, landmask):
    """统计各级地形占比（同时显示陆地上的占比）。"""
    h = heightmap
    total = h.size
    land_total = int(landmask.sum())
    stats = {}
    land_stats = {}
    for tier, (lo, hi) in TIER_THRESHOLDS.items():
        mask = (h >= lo) & (h < hi)
        cnt = int(mask.sum())
        stats[tier] = cnt / total
        # 陆地地形（≥20）的陆地占比
        if lo >= 19:
            land_stats[tier] = cnt / land_total if land_total > 0 else 0
    return stats, land_stats
