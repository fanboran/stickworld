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


# ---------- 描边：烘焙前合并共线段，减少短碎线段（消除"毛刷"） ----------

def _tol(t, eps=1e-3):
    return abs(t) < eps


def _merge_collinear_segments(pts, closed=True):
    """把多边形顶点环中相邻共线/近似共线的点合并，减少短碎描边段。

    pts: 渲染坐标 [(x,y), ...]（已含 tiles_offset 偏移，与 JSON 一致）
    closed: 是否为闭合环（邻居/地块/湖泊边界闭合）
    返回合并后的点列。
    """
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
        # 向量
        v1 = (nxt[0] - cur[0], nxt[1] - cur[1])
        v2 = (nxt2[0] - nxt[0], nxt2[1] - nxt[1])
        l1 = (v1[0] ** 2 + v1[1] ** 2) ** 0.5
        l2 = (v2[0] ** 2 + v2[1] ** 2) ** 0.5
        # 叉积与点积（归一化角度）
        cross = v1[0] * v2[1] - v1[1] * v2[0]
        if l1 > 1e-6 and l2 > 1e-6:
            crossn = cross / (l1 * l2)
            dot = (v1[0] * v2[0] + v1[1] * v2[1]) / (l1 * l2)
            # 近似共线：叉积接近 0 且方向一致（dot>0，避免 180° 折返）
            if _tol(crossn) and dot > 0.99:
                # 跳过中间点 nxt（三点共线）
                i += 1
                continue
        out.append(cur)
        i += 1
    if closed and len(out) > 2 and out[0] == out[-1]:
        out.pop()
    return out


def _collect_tile_border_segs(world, ctx_w, ctx_h):
    """收集地块描边段（渲染坐标，DP 简化 + 共线合并，消除毛刷短碎段）。"""
    segs = []
    for t in world["tiles"]:
        for poly in t.get("polygons", []):
            pts = [_pt_to_xy(p) for p in poly]
            if len(pts) < 3:
                continue
            pts = _douglas_peucker_closed(pts, tol=0.5)
            merged = _merge_collinear_segments(pts, closed=True)
            n = len(merged)
            for i in range(n):
                a = merged[i]
                b = merged[(i + 1) % n]
                # 滤除画框边缘段
                if _on_edge(a, ctx_w, ctx_h) and _on_edge(b, ctx_w, ctx_h):
                    continue
                segs.append([a, b])
    return segs


def _collect_neighbor_border_segs(world, ctx_w, ctx_h):
    """收集邻居分界线段（渲染坐标，DP 简化 + 共线合并，消除毛刷短碎段）。"""
    segs = []
    for nb in world["neighbors"]:
        for poly in nb.get("polygons", []):
            pts = [_pt_to_xy(p) for p in poly]
            if len(pts) < 3:
                continue
            pts = _douglas_peucker_closed(pts, tol=0.5)
            merged = _merge_collinear_segments(pts, closed=True)
            n = len(merged)
            for i in range(n):
                a = merged[i]
                b = merged[(i + 1) % n]
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
