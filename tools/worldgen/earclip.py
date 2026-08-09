"""纯 Python ear-clipping 三角剖分（单环）—— 素材阶段烘焙用。

支持任意简单多边形（凸/凹，无自交）的单环三角剖分。
洞不在此处理：渲染端用"洞网格覆盖"实现（见 l2_map_renderer 的 _holes_mesh），
因此仅需单环剖分即可正确填充。

与 Godot Geometry2D.triangulate_polygon 语义等价，素材阶段一次性烘焙，运行时零剖分。
坐标 (x, y) 任意顺序，返回三角形顶点坐标。
"""
EPSILON = 1e-9


def _area2(a, b, c):
    """三角形面积 x2（带符号）。"""
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


def _point_in_tri(p, a, b, c):
    """p 是否在三角形 abc 内（含边，方向由 a-b-c 决定）。"""
    d1 = _area2(a, b, p)
    d2 = _area2(b, c, p)
    d3 = _area2(c, a, p)
    has_neg = d1 < 0 or d2 < 0 or d3 < 0
    has_pos = d1 > 0 or d2 > 0 or d3 > 0
    return not (has_neg and has_pos)


def _is_ear(pts, indices, i):
    """判断 indices[i] 是否可作为耳朵。"""
    n = len(indices)
    a = pts[indices[(i - 1) % n]]
    b = pts[indices[i]]
    c = pts[indices[(i + 1) % n]]
    area = _area2(a, b, c)
    if abs(area) < EPSILON:
        return False  # 共线
    if area < 0:
        return False  # 凹点（对 CCW 环）
    # 三角形内不含其他剩余顶点
    for j in indices:
        if j == indices[(i - 1) % n] or j == indices[i] or j == indices[(i + 1) % n]:
            continue
        if _point_in_tri(pts[j], a, b, c):
            return False
    return True


def triangulate_polygon(pts):
    """对单环多边形做耳切三角剖分。

    Args:
        pts: 顶点列表 [(x,y), ...]（任意方向，自动规范化 CCW）

    Returns:
        三角形列表 [[(x,y), (x,y), (x,y)], ...]（顶点坐标）。
        退化（<3 顶点 / 无法剖分）返回 []。
    """
    if len(pts) < 3:
        return []
    # 规范化 CCW（面积>0）
    s = 0.0
    n = len(pts)
    for i in range(n):
        x1, y1 = pts[i]
        x2, y2 = pts[(i + 1) % n]
        s += x1 * y2 - x2 * y1
    ring = list(pts)
    if s < 0:
        ring = list(reversed(ring))
    indices = list(range(len(ring)))
    tris = []
    guard = 0
    max_guard = len(indices) * len(indices) * 2 + 10
    while len(indices) > 3:
        if guard > max_guard:
            break  # 防死循环（数据异常）
        guard += 1
        found = False
        m = len(indices)
        for i in range(m):
            if _is_ear(ring, indices, i):
                tris.append([ring[indices[(i - 1) % m]],
                             ring[indices[i]],
                             ring[indices[(i + 1) % m]]])
                del indices[i]
                found = True
                break
        if not found:
            break
    if len(indices) == 3:
        tris.append([ring[indices[0]], ring[indices[1]], ring[indices[2]]])
    return tris
