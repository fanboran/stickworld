"""L2 地区几何烘焙 —— 把运行时三角剖分/描边过滤提前到素材阶段。

产出 l2_geom.bin（little-endian 二进制），运行时零几何计算，直接组装 ArrayMesh。

关键设计原则（2026-08 修复描边补丁感）：
  · 形状金标准：JSON.polygons 中的多边形，由 mesh_extract.simplify_mesh(smooth_passes=2,
    corner_min_len=3.0) 生成。这份多边形已经做到「真实地形尖角保留（相邻两边≥3px
    的顶点不切角）+ 像素台阶平滑（1-2px 短边做 Chaikin 插值）」。
  · 填充三角剖分 与 描边线段 必须来自同一份多边形，保证渲染严丝合缝、无补丁感。
  · 禁止在 l2_bake 中对多边形再做额外的 DP/Chaikin——那会造成填充和描边不同源。

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


def _angle_merge_light(pts, closed=True, angle_thresh_deg=5.0, max_dev=0.3):
    """极轻量角度合并：仅移除浮点噪声（<5° 转角 + 偏离<0.3px 的冗余点）。

    用途：mesh_extract 的 Chaikin 插值是浮点运算，偶尔产生 <5° 的微抖动冗余点。
    本函数 NOT 用于平滑——平滑是 mesh_extract.smooth_passes=2 的职责。
    本函数仅做「去浮点噪点」，阈值极保守，不改变任何可见形状。
    """
    result = list(pts)
    if len(result) < 3:
        return result
    thresh_rad = math.radians(angle_thresh_deg)
    changed = True
    guard = 0
    while changed and guard < 20:
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
                skip_next = True
                changed = True
                new_out.append(a)
                continue
            cross = v1x * v2y - v1y * v2x
            dot = v1x * v2x + v1y * v2y
            ang = math.atan2(abs(cross), dot)
            # 垂直偏离
            acx, acy = c[0] - a[0], c[1] - a[1]
            lac = math.hypot(acx, acy)
            dev = 0.0
            if lac > 1e-6:
                t = ((b[0] - a[0]) * acx + (b[1] - a[1]) * acy) / (lac * lac)
                t = max(0.0, min(1.0, t))
                px = a[0] + t * acx
                py = a[1] + t * acy
                dev = math.hypot(b[0] - px, b[1] - py)
            # 极保守判据：<5° 且偏离 <0.3px（亚像素级，肉眼完全不可见）
            if ang < thresh_rad and dev < max_dev:
                skip_next = True
                changed = True
                new_out.append(a)
                continue
            new_out.append(a)
        result = new_out
    if closed and len(result) > 2:
        if abs(result[0][0] - result[-1][0]) < 1e-6 and abs(result[0][1] - result[-1][1]) < 1e-6:
            result.pop()
    return result


def _triangulate_ring(ring):
    """对单环三角剖分。

    ⚠️ 直接使用 JSON 中的多边形（mesh_extract 已做 smooth_passes=2 + corner_min_len=3 的
    聪明 Chaikin 平滑），这里**绝对不要再加 DP 简化或 Chaikin**——否则填充形状会
    和描边不同源，渲染时出现补丁感/描边浮起。
    """
    pts = [_pt_to_xy(p) for p in ring]
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
    LAKE = (72, 116, 158)   # 对齐 B2 底图湖色（terrain_params.json colors.lake）
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
    LAKE = (72, 116, 158)   # 对齐 B2 底图湖色（terrain_params.json colors.lake）
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


# ---------- 描边：与填充共用同一份多边形（同源严丝合缝） ----------

def _ring_to_border_segs(poly_pts_render, ctx_w, ctx_h):
    """把一条边界环（渲染坐标 x,y）转为描边线段列表。

    ⚠️ 设计：零额外形状处理！
       输入多边形是 **共用金标准形状**（经 mesh_extract → simplify_mesh:
       Chaikin×3 像素台阶平滑 + DP(tol=0.2) 亚像素精度降顶点）。
       填充三角剖分 _triangulate_ring 也直接使用这份多边形。
       任何额外 DP / 角度合并都会改变形状（如 max_dev>DP_tol 会误删关键点）。
       唯一过滤：跳过整条都在 context 边缘的线段（贴边的 tile 无描边价值）。
    """
    pts = list(poly_pts_render)
    n = len(pts)
    if n < 2:
        return []
    segs = []
    for i in range(n):
        a = pts[i]
        b = pts[(i + 1) % n]
        if _on_edge(a, ctx_w, ctx_h) and _on_edge(b, ctx_w, ctx_h):
            continue
        segs.append([a, b])
    return segs


def _collect_tile_border_segs(world, ctx_w, ctx_h):
    """收集地块描边段（与填充三角剖分 100% 同源，严丝合缝无补丁感）。"""
    segs = []
    for t in world["tiles"]:
        for poly in t.get("polygons", []):
            pts = [_pt_to_xy(p) for p in poly]
            segs.extend(_ring_to_border_segs(pts, ctx_w, ctx_h))
    return segs


def _collect_neighbor_border_segs(world, ctx_w, ctx_h):
    """收集邻居分界线段（与填充三角剖分 100% 同源）。"""
    segs = []
    for nb in world["neighbors"]:
        for poly in nb.get("polygons", []):
            pts = [_pt_to_xy(p) for p in poly]
            segs.extend(_ring_to_border_segs(pts, ctx_w, ctx_h))
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
