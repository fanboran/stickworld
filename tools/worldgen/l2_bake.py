"""L2 地区几何烘焙 —— 把运行时三角剖分/描边过滤提前到素材阶段。

产出 l2_geom.bin（little-endian 二进制），运行时零几何计算，直接组装 ArrayMesh。

格式：
  magic  "L2GB" (4B)
  ver    u16 = 1
  ---- mesh section（4 个）----
  每个 mesh 段：
    tri_count u32
    每三角形：v0.x v0.y v1.x v1.y v2.x v2.y (6 × f32)，+ r g b a (4B 颜色)
  section 顺序：tiles, holes, lakes, neighbors
  ---- border section（2 个）----
  每个 border 段：
    seg_count u32
    每段：a.x a.y b.x b.y (4 × f32)
  section 顺序：tile_border, neighbor_border
"""
import struct
import math
from earclip import triangulate_polygon

MAGIC = b"L2GB"
VER = 1


def _pt_to_xy(p):
    """多边形点 (y,x) -> 渲染坐标 (x,y)。"""
    return (float(p[1]), float(p[0]))


def _dp_dist(p, a, b):
    """点 p 到线段 ab 的垂直距离（平方）。"""
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    if dx == 0 and dy == 0:
        return (p[0] - ax) ** 2 + (p[1] - ay) ** 2
    t = ((p[0] - ax) * dx + (p[1] - ay) * dy) / (dx * dx + dy * dy)
    t = max(0.0, min(1.0, t))
    cx, cy = ax + t * dx, ay + t * dy
    return (p[0] - cx) ** 2 + (p[1] - cy) ** 2


def _douglas_peucker_closed(pts, tol=1.0):
    """对闭合环做 Douglas-Peucker 简化，保留形状，大幅降顶点。

    tol: 容差（像素），默认 1.0（小到形状无感，足够消除 O(n^2) 耳切性能瓶颈）。
    """
    n = len(pts)
    if n <= 3:
        return list(pts)
    tol2 = tol * tol
    best = 0
    best_d = -1.0
    for i in range(1, n):
        d = (pts[i][0] - pts[0][0]) ** 2 + (pts[i][1] - pts[0][1]) ** 2
        if d > best_d:
            best_d = d
            best = i

    def _dp_open(indices):
        if len(indices) <= 2:
            return set(indices)
        start, end = indices[0], indices[-1]
        a, b = pts[start], pts[end]
        max_d = -1.0
        max_i = -1
        for idx in indices[1:-1]:
            d = _dp_dist(pts[idx], a, b)
            if d > max_d:
                max_d = d
                max_i = idx
        if max_i >= 0 and max_d > tol2:
            mi = indices.index(max_i)
            left = _dp_open(indices[:mi + 1])
            right = _dp_open(indices[mi:])
            return left | right
        return {start, end}

    keep = set()
    keep |= _dp_open(list(range(0, best + 1)))
    keep |= _dp_open(list(range(best, n)) + [0])
    keep.add(0)
    return [pts[i] for i in range(n) if i in keep]


def _triangulate_ring(ring):
    """对单环三角剖分，返回坐标三角形列表（顶点为渲染 (x,y)）。
    大环先 Douglas-Peucker 简化（容差 1px，形状无感），消除 O(n^2) 耳切性能瓶颈。"""
    pts = [_pt_to_xy(p) for p in ring]
    if len(pts) < 3:
        return []
    if len(pts) > 500:
        pts = _douglas_peucker_closed(pts, tol=1.0)
    if len(pts) < 3:
        return []
    return triangulate_polygon(pts)


def _build_mesh_section(triangles_with_color):
    """把 [(tri, color)] 序列化为 mesh section bytes。
    tri: [(x,y), (x,y), (x,y)]；color: (r,g,b) 0-255
    """
    parts = []
    n = len(triangles_with_color)
    parts.append(struct.pack("<I", n))
    for tri, color in triangles_with_color:
        for v in tri:
            parts.append(struct.pack("<ff", v[0], v[1]))
        parts.append(struct.pack("<BBBB", int(color[0]), int(color[1]), int(color[2]), 255))
    return b"".join(parts)


def _build_border_section(segs):
    """把线段列表序列化为 border section bytes。
    seg: [(x,y), (x,y)] 或 [a, b]（点已为渲染坐标 (x,y)）
    """
    parts = [struct.pack("<I", len(segs))]
    for seg in segs:
        a, b = seg[0], seg[1]
        parts.append(struct.pack("<ffff", a[0], a[1], b[0], b[1]))
    return b"".join(parts)


def _collect_tile_tris(world):
    """收集地块 mesh 三角形（彩色）。"""
    out = []
    for t in world["tiles"]:
        color = tuple(t.get("color", [128, 128, 128]))
        for poly in t.get("polygons", []):
            for tri in _triangulate_ring(poly):
                out.append((tri, color))
    return out


def _collect_hole_tris(world):
    """收集地块洞 mesh 三角形（海洋色/湖泊色）。"""
    OCEAN = (30, 55, 95)
    LAKE = (28, 50, 82)
    out = []
    for t in world["tiles"]:
        for hole in t.get("holes", []):
            hpts = hole.get("points", hole) if isinstance(hole, dict) else hole
            c = LAKE if (isinstance(hole, dict) and hole.get("lake", False)) else OCEAN
            for tri in _triangulate_ring(hpts):
                out.append((tri, c))
    return out


def _collect_lake_tris(world):
    """收集湖泊 mesh 三角形。"""
    LAKE = (28, 50, 82)
    out = []
    for poly in world["lakes"]:
        for tri in _triangulate_ring(poly):
            out.append((tri, LAKE))
    return out


def _collect_neighbor_tris(world):
    """收集邻居 mesh 三角形（灰色）。"""
    GRAY = (115, 115, 115)
    out = []
    for nb in world["neighbors"]:
        for poly in nb.get("polygons", []):
            for tri in _triangulate_ring(poly):
                out.append((tri, GRAY))
    return out


# ---------- 描边：Chaikin 平滑 + 角度合并（消除阶梯状毛边） ----------
# （保留旧流水线函数，用于对照测试）
def _tol(t, eps=1e-3):
    return abs(t) < eps


def _merge_collinear_segments(pts, closed=True):
    """旧流水线：基于共线的三点合并。（对照用，新代码勿直接用）"""
    n = len(pts)
    if n < 3:
        return list(pts)
    out = []
    i = 0
    count = n if closed else n
    while i < count:
        cur = pts[i]
        nxt = pts[(i + 1) % n]
        nxt2 = pts[(i + 2) % n]
        v1 = (nxt[0] - cur[0], nxt[1] - cur[1])
        v2 = (nxt2[0] - nxt[0], nxt2[1] - nxt[1])
        l1 = (v1[0] ** 2 + v1[1] ** 2) ** 0.5
        l2 = (v2[0] ** 2 + v2[1] ** 2) ** 0.5
        cross = v1[0] * v2[1] - v1[1] * v2[0]
        if l1 > 1e-6 and l2 > 1e-6:
            crossn = cross / (l1 * l2)
            dot = (v1[0] * v2[0] + v1[1] * v2[1]) / (l1 * l2)
            if _tol(crossn) and dot > 0.99:
                i += 1
                continue
        out.append(cur)
        i += 1
    if closed and len(out) > 2 and out[0] == out[-1]:
        out.pop()
    return out

def _chaikin_smooth(pts, closed=True, iterations=3):
    """Chaikin 角切割平滑（二次 B 样条逼近）。

    每轮迭代对每条边取 1/4 和 3/4 分点形成新顶点，
    有效消除高频锯齿（阶梯状毛边），保留宏观形状。

    pts: [(x,y), ...] 渲染坐标
    closed: 是否闭合环
    iterations: 迭代次数（默认 3 次，足够把阶梯状毛边抹平）
    返回平滑后的点列。
    """
    result = list(pts)
    for _ in range(iterations):
        if len(result) < 2:
            break
        out = []
        n = len(result)
        if closed:
            indices = list(range(n))
        else:
            # 开折线：保留两端点
            out.append(result[0])
            indices = list(range(n - 1))
        for i in indices:
            p0 = result[i]
            p1 = result[(i + 1) % n]
            # 取 1/4 和 3/4 分点
            qx = 0.75 * p0[0] + 0.25 * p1[0]
            qy = 0.75 * p0[1] + 0.25 * p1[1]
            rx = 0.25 * p0[0] + 0.75 * p1[0]
            ry = 0.25 * p0[1] + 0.75 * p1[1]
            out.append((qx, qy))
            out.append((rx, ry))
        if not closed:
            out.append(result[-1])
        result = out
    return result


def _angle_merge(pts, closed=True, angle_thresh_deg=15.0):
    """基于角度阈值合并：移除小角度（尖角/高频波动）的中间顶点。

    原理：如果连续三个点 A->B->C 的转角 < angle_thresh_deg，且 B 点对线段 AC 的
    偏离距离 < min_seg_len * 0.5，则移除 B。反复迭代直到没有可移除点。

    这能在 Chaikin 平滑后进一步消除残留的小幅波动，避免"肉虫"状微抖动。
    """
    result = list(pts)
    if len(result) < 3:
        return result
    thresh_rad = math.radians(angle_thresh_deg)
    changed = True
    guard = 0
    while changed and guard < 50:
        changed = False
        guard += 1
        n = len(result)
        if n < 3:
            break
        new_out = []
        skip_next = False
        iter_range = range(n if closed else n - 1)
        for i in iter_range:
            if skip_next:
                skip_next = False
                continue
            a = result[i]
            b_idx = (i + 1) % n
            c_idx = (i + 2) % n
            if not closed and (b_idx >= n or c_idx >= n):
                new_out.append(a)
                continue
            b = result[b_idx]
            c = result[c_idx]
            v1x, v1y = b[0] - a[0], b[1] - a[1]
            v2x, v2y = c[0] - b[0], c[1] - b[1]
            l1 = math.hypot(v1x, v1y)
            l2 = math.hypot(v2x, v2y)
            if l1 < 1e-6 or l2 < 1e-6:
                # 重复点，跳过 b
                skip_next = True
                changed = True
                new_out.append(a)
                continue
            # 计算转角（0=直行，180=折返）
            cross = v1x * v2y - v1y * v2x
            dot = v1x * v2x + v1y * v2y
            ang = math.atan2(abs(cross), dot)  # 0 ~ pi
            # 计算 B 到线段 AC 的垂直距离
            acx, acy = c[0] - a[0], c[1] - a[1]
            lac = math.hypot(acx, acy)
            if lac > 1e-6:
                t = ((b[0] - a[0]) * acx + (b[1] - a[1]) * acy) / (lac * lac)
                t = max(0.0, min(1.0, t))
                px = a[0] + t * acx
                py = a[1] + t * acy
                dev = math.hypot(b[0] - px, b[1] - py)
            else:
                dev = 0.0
            min_seg = min(l1, l2)
            # 判据：小角度 + 偏离距离小
            if ang < thresh_rad and dev < max(0.5, min_seg * 0.5):
                # 移除中间点 b
                skip_next = True
                changed = True
                new_out.append(a)
                continue
            new_out.append(a)
        if closed and new_out and new_out[0] != new_out[-1]:
            # 闭合场景下补上最后一个点（被 range 的模运算吞掉的）
            if not (new_out and abs(new_out[0][0] - new_out[-1][0]) < 1e-6 and
                    abs(new_out[0][1] - new_out[-1][1]) < 1e-6):
                pass  # 不需要额外补，下次循环会处理
        result = new_out
    # 闭合清理
    if closed and len(result) > 2:
        if abs(result[0][0] - result[-1][0]) < 1e-6 and abs(result[0][1] - result[-1][1]) < 1e-6:
            result.pop()
    return result


def _smooth_border_ring(pts, closed=True):
    """对一条描边边界环执行完整的平滑流水线：
    DP 粗简化(0.5px) → Chaikin 平滑(×3) → 角度合并(15°)
    """
    if len(pts) < 3:
        return list(pts)
    # Step 1: DP 粗简化，去除极近的重复噪声点
    pts = _douglas_peucker_closed(pts, tol=0.5)
    if len(pts) < 3:
        return list(pts)
    # Step 2: Chaikin 角切割 ×3 次，抹平阶梯锯齿
    pts = _chaikin_smooth(pts, closed=closed, iterations=3)
    if len(pts) < 3:
        return list(pts)
    # Step 3: 角度合并（15° 以内的小波动移除），避免 Chaikin 后残留"肉虫"抖动
    pts = _angle_merge(pts, closed=closed, angle_thresh_deg=15.0)
    return pts


def _collect_tile_border_segs(world, ctx_w, ctx_h):
    """收集地块描边段（Chaikin×3 + 角度合并，彻底消除阶梯毛边）。"""
    segs = []
    for t in world["tiles"]:
        for poly in t.get("polygons", []):
            pts = [_pt_to_xy(p) for p in poly]
            if len(pts) < 3:
                continue
            smoothed = _smooth_border_ring(pts, closed=True)
            n = len(smoothed)
            if n < 2:
                continue
            for i in range(n):
                a = smoothed[i]
                b = smoothed[(i + 1) % n]
                # 滤除画框边缘段
                if _on_edge(a, ctx_w, ctx_h) and _on_edge(b, ctx_w, ctx_h):
                    continue
                segs.append([a, b])
    return segs


def _collect_neighbor_border_segs(world, ctx_w, ctx_h):
    """收集邻居分界线段（Chaikin×3 + 角度合并，彻底消除阶梯毛边）。"""
    segs = []
    for nb in world["neighbors"]:
        for poly in nb.get("polygons", []):
            pts = [_pt_to_xy(p) for p in poly]
            if len(pts) < 3:
                continue
            smoothed = _smooth_border_ring(pts, closed=True)
            n = len(smoothed)
            if n < 2:
                continue
            for i in range(n):
                a = smoothed[i]
                b = smoothed[(i + 1) % n]
                if _on_edge(a, ctx_w, ctx_h) and _on_edge(b, ctx_w, ctx_h):
                    continue
                segs.append([a, b])
    return segs


def _on_edge(v, cw, ch, t=0.5):
    return v[0] <= t or v[1] <= t or v[0] >= cw - t or v[1] >= ch - t


def bake(world, out_path):
    """把 L2 world 数据烘焙成 l2_geom.bin。

    world: 与 l2_world.json 同结构的 dict
    out_path: 输出 .bin 文件路径
    """
    cw = float(world.get("context_size", [0, 0])[0])
    ch = float(world.get("context_size", [0, 0])[1])

    tile_tris = _collect_tile_tris(world)
    hole_tris = _collect_hole_tris(world)
    lake_tris = _collect_lake_tris(world)
    neighbor_tris = _collect_neighbor_tris(world)

    tile_border = _collect_tile_border_segs(world, cw, ch)
    neighbor_border = _collect_neighbor_border_segs(world, cw, ch)

    header = MAGIC + struct.pack("<H", VER)
    body = b"".join([
        _build_mesh_section(tile_tris),
        _build_mesh_section(hole_tris),
        _build_mesh_section(lake_tris),
        _build_mesh_section(neighbor_tris),
        _build_border_section(tile_border),
        _build_border_section(neighbor_border),
    ])
    with open(out_path, "wb") as f:
        f.write(header + body)
    return {
        "tile_tris": len(tile_tris),
        "hole_tris": len(hole_tris),
        "lake_tris": len(lake_tris),
        "neighbor_tris": len(neighbor_tris),
        "tile_border_segs": len(tile_border),
        "neighbor_border_segs": len(neighbor_border),
    }
