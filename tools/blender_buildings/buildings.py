# -*- coding: utf-8 -*-
"""buildings.py —— 程序化建筑装配库（管线 v3 · 写实 PBR · 单体建筑批次）

世界坐标约定
------------
* 1 单位 = 1 像素；1 格 = 32 单位（CELL）。
* 建筑底 = z 0；+Z 向上；**立面宽沿 X**，进深沿 Y；**正面朝 -Y**，相机在 -Y 侧看 +Y。
* 所有模块的 `x / y` 为水平中心、`z` 为**底面（绝对世界高度）**；带 `_center` 后缀者为例外。

比例锚（规范 §8.2 修订版，全部模块硬编码引用这几个数，禁止各处另写）
------------------------------------------------------------------------
* 火柴人身高 = 130（STICKMAN_H）
* 门净高 = 150（DOOR_H），门洞底面从 DOOR_SILL=8 起算（门槛）
* 单扇门宽 45~60（DOOR_W_RANGE）；复合门洞（谷仓双扇等）按 def 语义豁免（§8.3）
* 带门建筑最小 6 格（MIN_DOOR_CELLS），4 格档只做小物件（§8.2）
* 长宽比：网格宽 : 剪影总高 ∈ RATIO_BAND = 1 : 0.85~1.5（§8.2，单层硬约束）
* 双层单列层高 ∈ STOREY_H_BAND = 175~195（§8.2）
* 出檐（每侧）∈ EAVE_RATIO_BAND = 建筑宽 × 18~23%（§8.2）
* 相机固定 3/4 偏航：水平 12°、俯角 10°（§8.1，见 probe_buildings.YAW/TILT）

材质接口
--------
本库只声明**材质名**（"thatch"/"plaster"/...），不实现节点图。
`material(name)` 的解析顺序：
1. `set_material_resolver(fn)` 注入的解析器（materials.py 的接入点）；
2. 同目录 `materials.py` 若提供 `get()/build_material()/MATERIALS` 则自动使用；
3. 回退到本文件的纯色 PBR（SPEC_COLOR，本轮用于验证几何与比例）。
因此 materials.py 落地后**无需改动本文件**即可接管材质。

跑法（只打印规格表自检）::

    blender -b --factory-startup -P buildings.py
"""

import math
import os
import sys

import bmesh
import bpy
from mathutils import Euler, Matrix, Vector

# ---------------------------------------------------------------- §0 基准常量

CELL = 32.0                 # 1 格 = 32px（PlacementGrid.CELL_SIZE）
STICKMAN_H = 130.0          # 火柴人身高（arrow_projectile.gd BODY_HEIGHT）
DOOR_H = 150.0              # 门净高（硬性）
DOOR_W_RANGE = (45.0, 60.0)  # 单扇门宽允许区间
DOOR_SILL = 8.0             # 门槛高：门洞 z 从 8 到 158
# §8.2 长宽比硬口径：网格宽 : 剪影总高 = 1 : 0.85 ~ 1 : 1.5
RATIO_BAND = (0.85, 1.50)
#: §8.2 各宽度档的绝对剪影总高区间（用于自检打表）
GRID_H_BAND = {4: (109, 192), 6: (163, 288), 8: (218, 384),
               12: (326, 576), 16: (435, 768)}
#: §8.2 双层单列层高区间
STOREY_H_BAND = (175.0, 195.0)
#: §8.2 出檐占建筑宽的比例区间（每侧）
EAVE_RATIO_BAND = (0.18, 0.23)
#: §8.2 带门建筑最小宽度（4 格档只做小物件）
MIN_DOOR_CELLS = 6
U_WIDTHS = (4, 8, 12, 16)   # 小物件以外，房屋类宽度取 4 的整数倍（4 格仅限小物件）


def eave_over(grid_w):
    """§8.2 出檐（每侧）= 建筑宽 × 20.5%，稳落 18~23% 带内。"""
    return round(grid_w * 0.205)


def bays_of(width_cells):
    """开间数：每开间最多 1 窗（§8.2 减窗口径）用得着的唯一开间定义。"""
    return max(2, int(round(width_cells / 4.0)))


# ---------------------------------------------------------------- §1 材质

#: 本轮纯色 PBR 回退表：name -> (base_color, roughness, metallic)
SPEC_COLOR = {
    "plaster":     ((0.78, 0.73, 0.60), 0.90, 0.0),
    "plaster_old": ((0.62, 0.58, 0.49), 0.92, 0.0),
    "timber":      ((0.22, 0.12, 0.05), 0.80, 0.0),
    "wood":        ((0.36, 0.20, 0.09), 0.78, 0.0),
    "wood_light":  ((0.46, 0.27, 0.13), 0.80, 0.0),
    "wood_dark":   ((0.17, 0.09, 0.04), 0.82, 0.0),
    "thatch":      ((0.72, 0.51, 0.18), 0.92, 0.0),
    "thatch_old":  ((0.42, 0.30, 0.12), 0.95, 0.0),
    "tile":        ((0.45, 0.16, 0.08), 0.75, 0.0),
    "slate":       ((0.28, 0.30, 0.34), 0.70, 0.0),
    "stone":       ((0.62, 0.60, 0.55), 0.82, 0.0),
    "stone_dark":  ((0.38, 0.37, 0.34), 0.85, 0.0),
    "white_stone": ((0.85, 0.82, 0.74), 0.86, 0.0),
    "brick":       ((0.45, 0.16, 0.09), 0.80, 0.0),
    "iron":        ((0.08, 0.08, 0.09), 0.45, 0.9),
    "canvas":      ((0.72, 0.66, 0.52), 0.95, 0.0),
    "glass":       ((0.09, 0.11, 0.13), 0.55, 0.0),
    "ground":      ((0.80, 0.76, 0.68), 0.95, 0.0),
    "silhouette":  ((0.16, 0.16, 0.18), 0.85, 0.0),
    "wood_door":   ((0.17, 0.11, 0.07), 0.80, 0.0),
    "wood_roof":   ((0.30, 0.19, 0.11), 0.80, 0.0),
    "ember":       ((0.50, 0.13, 0.03), 0.90, 0.0),
    # 接地阴影三级（§8.2 接地要求；纯色 PBR，不参与 materials.py 的材质家族）
    "shadow_far":  ((0.55, 0.52, 0.47), 1.0, 0.0),
    "shadow_mid":  ((0.41, 0.385, 0.345), 1.0, 0.0),
    "shadow_near": ((0.28, 0.26, 0.235), 1.0, 0.0),
}
EMISSIVE = {"fire": ((1.0, 0.42, 0.10), 4.0),
            "ember": ((1.0, 0.28, 0.05), 1.4)}   # name -> (color, strength)

#: 本库材质名 → materials.py 注册名 + tune 参数（同名者直通，缺失则回退纯色 PBR）
#: 抹灰的 wear 压到 0.18/0.32 是 §8.5「禁止锈褐色斑块」的建筑层手段：剥落斑阈值
#: thr=lin(wear,0,1,0.665,0.590) 随 wear 下降而抬升，wear 越小褐色底斑越少。
MATERIAL_ALIAS = {
    "plaster":     ("plaster", dict(wear=0.10, scale=0.9)),
    "plaster_old": ("plaster", dict(tint=(0.82, 0.80, 0.74), wear=0.30, scale=0.9)),
    "timber":      ("timber", {}),
    "wood":        ("plank_wall", {}),
    "wood_light":  ("plank_wall", dict(tint=(1.12, 1.06, 0.98))),
    "wood_dark":   ("timber", dict(tint=(0.86, 0.86, 0.86))),
    # 门扇/闸门要"明显深于墙面"才读得出门（§8.3 复合门洞必须有可读的门）
    "wood_door":   ("plank_wall", dict(tint=(0.32, 0.29, 0.26), scale=1.25)),
    "wood_roof":   ("plank_wall", dict(tint=(0.80, 0.74, 0.66), scale=1.9)),
    "thatch":      ("thatch", {}),
    "thatch_old":  ("thatch_old", {}),
    "tile":        ("tile_roof", {}),
    "slate":       ("slate_roof", {}),
    "stone":       ("stone", {}),
    "stone_dark":  ("stone", dict(tint=(0.86, 0.86, 0.90))),
    "white_stone": ("white_stone", {}),
    "brick":       ("brick", {}),
    "iron":        ("iron", {}),
    "canvas":      ("canvas", {}),
}

_RESOLVER = None      # 外部注入的材质解析器（materials.py）
_CACHE = {}


def set_material_resolver(fn):
    """注入外部材质解析器 fn(name) -> bpy.types.Material | None。"""
    global _RESOLVER
    _RESOLVER = fn
    _CACHE.clear()


def _external_material(name):
    """同目录 materials.py 自动接管（存在即用，不存在静默回退）。"""
    if "materials" not in sys.modules:
        here = os.path.dirname(os.path.abspath(__file__))
        if here not in sys.path:
            sys.path.insert(0, here)
        try:
            __import__("materials")
        except Exception:
            return None
    mod = sys.modules.get("materials")
    if mod is None:
        return None
    alias = MATERIAL_ALIAS.get(name)
    if alias and hasattr(mod, "make"):
        key, kw = alias
        try:
            m = mod.make(key)
            if kw and hasattr(mod, "tune"):
                mod.tune(m, **kw)
            m.name = name
            return m
        except Exception as exc:
            print("[materials] %s -> %s 失败(%s)，回退纯色" % (name, key, exc))
    for attr in ("get", "get_material", "build_material", "material"):
        fn = getattr(mod, attr, None)
        if callable(fn):
            try:
                m = fn(name)
                if m is not None and hasattr(m, "node_tree"):
                    return m
            except Exception:
                pass
    table = getattr(mod, "MATERIALS", None)
    if isinstance(table, dict) and name in table:
        return table[name]
    return None


def _flat_pbr(name):
    key = name if name in SPEC_COLOR else "plaster"
    color, rough, metal = SPEC_COLOR[key]
    m = bpy.data.materials.new("flat_" + name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes.get("Principled BSDF")
    if bsdf is None:
        for n in m.node_tree.nodes:
            if n.type == "BSDF_PRINCIPLED":
                bsdf = n
    if bsdf is not None:
        bsdf.inputs["Base Color"].default_value = (color[0], color[1], color[2], 1.0)
        bsdf.inputs["Roughness"].default_value = rough
        try:
            bsdf.inputs["Metallic"].default_value = metal
        except Exception:
            pass
        try:
            bsdf.inputs["Specular IOR Level"].default_value = (
                0.08 if name == "glass" else 0.25)
        except Exception:
            pass
        if name in EMISSIVE:
            ecol, estr = EMISSIVE[name]
            for slot in ("Emission Color", "Emission"):
                if slot in bsdf.inputs:
                    bsdf.inputs[slot].default_value = (ecol[0], ecol[1], ecol[2], 1.0)
                    break
            if "Emission Strength" in bsdf.inputs:
                bsdf.inputs["Emission Strength"].default_value = estr
    m.diffuse_color = (color[0], color[1], color[2], 1.0)
    return m


def material(name):
    """材质解析（带缓存）。materials.py 在场即由它接管。"""
    if name in _CACHE:
        return _CACHE[name]
    m = None
    if _RESOLVER is not None:
        try:
            m = _RESOLVER(name)
        except Exception:
            m = None
    if m is None or not hasattr(m, "node_tree"):
        m = _external_material(name)
    if m is None:
        m = _flat_pbr(name)
    _CACHE[name] = m
    return m


# ---------------------------------------------------------------- §2 Builder

def _face_normal(pts):
    """Newell 法线（不依赖 bmesh 缓存，创建面后立刻可用）。"""
    nx = ny = nz = 0.0
    n = len(pts)
    for i in range(n):
        ax, ay, az = pts[i]
        bx, by, bz = pts[(i + 1) % n]
        nx += (ay - by) * (az + bz)
        ny += (az - bz) * (ax + bx)
        nz += (ax - bx) * (ay + by)
    v = Vector((nx, ny, nz))
    return v.normalized() if v.length > 1e-9 else None


def _solid_segments(span, holes):
    """一维补集：span=(a,b) 减去 holes=[(a,b),...] → 实体段列表（按 x 升序）。"""
    a, b = span
    cuts = []
    for h0, h1 in holes:
        h0, h1 = max(a, min(h0, b)), max(a, min(h1, b))
        if h1 > h0:
            cuts.append((h0, h1))
    if not cuts:
        return [(a, b)]
    cuts.sort()
    out, cur = [], a
    for h0, h1 in cuts:
        if h0 > cur:
            out.append((cur, h0))
        cur = max(cur, h1)
    if cur < b:
        out.append((cur, b))
    return out


class Builder(object):
    """把模块积木累积进一个 bmesh，最终吐出一个多材质槽对象（确定性）。"""

    def __init__(self, name, tile=CELL):
        self.name = name
        self.tile = tile           # UV 世界尺度：每 tile 单位重复一次（1 格 = 32px）
        self.bm = bmesh.new()
        self.uv = self.bm.loops.layers.uv.new("UVMap")
        self.mat_names = []

    # -- 低层 ---------------------------------------------------------
    def _slot(self, mat):
        if mat not in self.mat_names:
            self.mat_names.append(mat)
        return self.mat_names.index(mat)

    def poly(self, pts, mat, outward=None, uv_axes=None):
        """加一个多边形；outward 给定期望外法线方向时自动翻正绕序。

        uv_axes=(u_axis, v_axis)：给出两个世界方向作为 UV 轴（用于坡屋面——
        材质库约定 U=水平轴、V=顺坡轴，默认按主导轴投影会把陡坡压缩成平板）。
        """
        bm = self.bm
        pts = [tuple(float(c) for c in p) for p in pts]
        n = _face_normal(pts)
        if outward is not None and n is not None:
            ov = Vector(outward)
            if ov.length > 1e-9 and n.dot(ov) < 0.0:
                pts.reverse()
                n = -n
        vs = [bm.verts.new(p) for p in pts]
        try:
            f = bm.faces.new(vs)
        except ValueError:
            return None
        f.material_index = self._slot(mat)
        if n is None:
            n = Vector((0.0, 0.0, 1.0))
        ax = max(range(3), key=lambda i: abs(n[i]))
        t = self.tile
        for loop in f.loops:
            c = loop.vert.co
            if uv_axes is not None:
                ua, va = uv_axes
                loop[self.uv].uv = (c.dot(ua) / t, c.dot(va) / t)
                continue
            if ax == 0:
                uv = (c.y / t, c.z / t)
            elif ax == 1:
                uv = (c.x / t, c.z / t)
            else:
                uv = (c.x / t, c.y / t)
            loop[self.uv].uv = uv
        return f

    def box_oriented(self, center, axes, half, mat, uv_axes=None):
        """任意朝向长方体：center + (-1/1)*half[i]*axes[i]。axes 需右手系。"""
        c = Vector(center)
        a0, a1, a2 = (Vector(a) for a in axes)
        h0, h1, h2 = half

        def v(i, j, k):
            return c + a0 * ((2 * i - 1) * h0) + a1 * ((2 * j - 1) * h1) + a2 * ((2 * k - 1) * h2)

        quads = (
            ((1, 0, 0), (1, 1, 0), (1, 1, 1), (1, 0, 1)),   # +a0
            ((0, 0, 0), (0, 0, 1), (0, 1, 1), (0, 1, 0)),   # -a0
            ((0, 1, 0), (0, 1, 1), (1, 1, 1), (1, 1, 0)),   # +a1
            ((0, 0, 0), (1, 0, 0), (1, 0, 1), (0, 0, 1)),   # -a1
            ((0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1)),   # +a2
            ((0, 0, 0), (0, 1, 0), (1, 1, 0), (1, 0, 0)),   # -a2
        )
        for q in quads:
            self.poly([v(*i) for i in q], mat, uv_axes=uv_axes)

    def box(self, size, center, mat, rot=None, uv_axes=None):
        """轴对齐（或给 rot=Euler 弧度三元组）长方体。size=(sx,sy,sz)，center=盒心。"""
        if rot is None:
            axes = (Vector((1, 0, 0)), Vector((0, 1, 0)), Vector((0, 0, 1)))
        else:
            m = Euler(rot, "XYZ").to_matrix()
            axes = (m.col[0], m.col[1], m.col[2])
        self.box_oriented(center, axes, (size[0] / 2.0, size[1] / 2.0, size[2] / 2.0),
                          mat, uv_axes=uv_axes)

    def box_bottom(self, size, xy, z_bottom, mat, rot=None):
        """底面对齐版 box：xy=(x,y) 水平中心，z_bottom=底面高度。"""
        self.box(size, (xy[0], xy[1], z_bottom + size[2] / 2.0), mat, rot)

    def cylinder(self, center, radius, height, mat, segments=16, axis="Z", taper=1.0):
        """手写棱柱（规避 bmesh.ops API 漂移）。center=柱心，height=全长。"""
        c = Vector(center)
        if axis == "Z":
            ax = (Vector((1, 0, 0)), Vector((0, 1, 0)), Vector((0, 0, 1)))
        elif axis == "X":
            ax = (Vector((0, 0, 1)), Vector((0, 1, 0)), Vector((1, 0, 0)))
        else:
            ax = (Vector((1, 0, 0)), Vector((0, 0, 1)), Vector((0, 1, 0)))
        r2 = radius * taper
        h = height / 2.0
        ring0, ring1 = [], []
        for i in range(segments):
            th = 2.0 * math.pi * i / segments
            u, v = math.cos(th), math.sin(th)
            ring0.append(c + ax[0] * (radius * u) + ax[1] * (radius * v) - ax[2] * h)
            ring1.append(c + ax[0] * (r2 * u) + ax[1] * (r2 * v) + ax[2] * h)
        for i in range(segments):
            j = (i + 1) % segments
            mid = (ring0[i] + ring0[j] + ring1[j] + ring1[i]) / 4.0
            self.poly([ring0[i], ring0[j], ring1[j], ring1[i]], mat, outward=(mid - c))
        self.poly(list(reversed(ring0)), mat, outward=(-ax[2]))
        self.poly(list(ring1), mat, outward=ax[2])

    def tri_prism(self, cx, thickness, y_half, rise, z_base, mat, y=0.0):
        """沿 X 拉伸的三棱柱（山墙填充）：底边宽 2*y_half（Y 向），高 rise。"""
        x0, x1 = cx - thickness / 2.0, cx + thickness / 2.0
        a0 = (x0, y - y_half, z_base)
        b0 = (x0, y + y_half, z_base)
        c0 = (x0, y, z_base + rise)
        a1 = (x1, y - y_half, z_base)
        b1 = (x1, y + y_half, z_base)
        c1 = (x1, y, z_base + rise)
        self.poly([a0, b0, c0], mat, outward=(-1, 0, 0))
        self.poly([a1, b1, c1], mat, outward=(1, 0, 0))
        self.poly([a0, a1, b1, b0], mat, outward=(0, 0, -1))      # 底
        self.poly([a0, b0, b1, a1], mat, outward=(0, -1, 0))      # 前坡面（-Y）
        self.poly([b0, c0, c1, b1], mat, outward=(0, 1, 0))       # 后坡面（+Y）

    def to_object(self):
        self.bm.normal_update()
        me = bpy.data.meshes.new(self.name + "_mesh")
        self.bm.to_mesh(me)
        self.bm.free()
        for n in self.mat_names:
            me.materials.append(material(n))
        ob = bpy.data.objects.new(self.name, me)
        bpy.context.scene.collection.objects.link(ob)
        return ob


# ---------------------------------------------------------------- §3 模块库

def wall_block(b, w, h, d, mat, x=0.0, y=0.0, z=0.0):
    """实心墙块：宽 w(X) × 高 h(Z) × 深 d(Y)，(x,y)=水平中心，z=墙底。"""
    b.box_bottom((w, d, h), (x, y), z, mat)
    return {"w": w, "h": h, "d": d}


def wall_panel(b, w, h, d, mat, x=0.0, y=0.0, z=0.0, openings=(), eps=0.0, axis="X"):
    """带洞墙体：真正挖出门/窗洞（可做凹进、见洞口侧壁与投影）。

    openings = [(cu, ow, z0, z1), ...]（**绝对世界坐标**，非相对量；cu 沿 axis）。
    axis="X"：w 沿 X、厚度 d 沿 Y（正面墙）；axis="Y"：w 沿 Y、厚度 d 沿 X（侧墙）。
    实现：按洞口的 z 边界切水平条带，条带内再按 u 求补集。
    """
    cu0 = x if axis == "X" else y
    zs = sorted({z, z + h})
    for (_cx, _ow, z0, z1) in openings:
        for zz in (z0, z1):
            if z + eps < zz < z + h - eps:
                zs.append(zz)
    for i in range(len(zs) - 1):
        za, zb = zs[i], zs[i + 1]
        if zb - za < 1e-6:
            continue
        zc = (za + zb) / 2.0
        holes = []
        for (cx, ow, z0, z1) in openings:
            if z0 <= zc <= z1:
                holes.append((cu0 + cx - ow / 2.0, cu0 + cx + ow / 2.0))
        for (sx0, sx1) in _solid_segments((cu0 - w / 2.0, cu0 + w / 2.0), holes):
            if sx1 - sx0 < 1e-6:
                continue
            if axis == "X":
                # box_bottom(size=(sx,sy,sz))：必须 (宽, 厚, 高)，不可写成 (宽, 高, 厚)
                b.box_bottom((sx1 - sx0, d, zb - za), ((sx0 + sx1) / 2.0, y), za, mat)
            else:
                b.box_bottom((d, sx1 - sx0, zb - za), (x, (sx0 + sx1) / 2.0), za, mat)
    return {"w": w, "h": h, "openings": list(openings), "axis": axis}


def roof_gable(b, w, span, rise, overhang, mat, x=0.0, y=0.0, z=0.0,
               thickness=9.0, mat_under=None, gable_overhang=None, ridge_cap=True,
               cap_mat=None, cap_size=(0, 0), eave_board=True, board_mat=None,
               board_h=0.0, slope_uv=True, uv_swap=False):
    """双坡屋顶（屋脊沿 X，正面朝 -Y，相机侧看到整片前坡）。

    w        = 屋脊方向覆盖的建筑宽度（X，不含出檐）
    span     = 坡面跨越的建筑进深（Y，不含出檐）
    rise     = 屋脊相对檐口高度（越大坡越陡、正面可见屋面越大）
    overhang = 出檐（§8.2：每侧 = 建筑宽 × 18~23%）
    z        = 檐口高度（= 墙顶）
    返回 dict：檐口/屋脊高、坡长、坡度角。
    """
    ov_x = overhang if gable_overhang is None else gable_overhang
    ridge_len = w + 2.0 * ov_x
    half = span / 2.0 + overhang                    # 屋脊到檐口的水平投影
    slope = math.hypot(half, rise)
    ang = math.atan2(rise, half)                    # 坡面倾角
    ca, sa = math.cos(ang), math.sin(ang)
    for sign in (-1.0, 1.0):                        # -1 = 前坡（朝 -Y）
        if sign < 0:
            cy = y - half / 2.0
            cz = z + rise / 2.0
            rotx = ang
            nrm = Vector((0.0, -rise, half)).normalized()
            smooth = Vector((0.0, -ca, -sa))        # 顺坡向下（檐口方向）
        else:
            cy = y + half / 2.0
            cz = z + rise / 2.0
            rotx = -ang
            nrm = Vector((0.0, rise, half)).normalized()
            smooth = Vector((0.0, ca, -sa))
        # 顺坡 UV：U = 屋脊方向，V = 顺坡向下 —— 瓦垄/草束才不会被压成平板
        # uv_swap=True：木板顶用（板条顺坡铺，与参考图 barn 一致），U/V 互换
        if not slope_uv:
            uvx = None
        elif uv_swap:
            uvx = (smooth, Vector((1, 0, 0)))
        else:
            uvx = (Vector((1, 0, 0)), smooth)
        # 屋面板以"理想屋面"为中面：脊顶只比檐口+rise 高 t·cosα/2（不虚高）
        c = Vector((x, cy, cz))
        axes = (Vector((1, 0, 0)),
                Vector((0, math.cos(rotx), math.sin(rotx))),
                Vector((0, -math.sin(rotx), math.cos(rotx))))
        half_sz = (ridge_len / 2.0, slope / 2.0, thickness / 2.0)
        b.box_oriented(c, axes, half_sz, mat, uv_axes=uvx)
        if mat_under:                               # 檐底/望板（可选）
            c2 = Vector((x, cy, cz)) - nrm * (thickness / 2.0 + 1.0)
            b.box_oriented(c2, axes, (ridge_len / 2.0 - 2.0, slope / 2.0, 1.0),
                           mat_under, uv_axes=uvx)
    if eave_board:                              # 檐口封檐板：勾出檐线
        bh = board_h if board_h else max(7.0, thickness * 0.42)
        for sign in (-1.0, 1.0):
            b.box_bottom((ridge_len + 1.0, 9.0, bh), (x, y + sign * (half - 2.0)),
                         z - bh * 0.55, board_mat or mat_under or "wood_dark")
    if ridge_cap:
        cw = (cap_size[0] if cap_size[0] else 26.0)
        ch = (cap_size[1] if cap_size[1] else max(8.0, thickness * 0.55))
        b.box_bottom((ridge_len + 2.0, cw, ch), (x, y), z + rise - ch * 0.35,
                     cap_mat or mat)
    return {"ridge_len": ridge_len, "half_span": half, "slope_len": slope,
            "angle_deg": math.degrees(ang), "eave_z": z, "ridge_z": z + rise}


def gable_infill(b, w, span, rise, mat, z=0.0, thickness=12.0, y=0.0):
    """两端山墙三角填充（屋脊沿 X 时，山墙在左右两侧）。"""
    for sx in (-1.0, 1.0):
        b.tri_prism(sx * (w / 2.0 - thickness / 2.0), thickness, span / 2.0, rise, z, mat, y=y)
    return {"rise": rise, "thickness": thickness}


def door(b, h=DOOR_H, w=50.0, mat="wood_dark", x=0.0, y=0.0, z=DOOR_SILL,
         frame_mat="timber", frame=8.0, depth=6.0, leaf_depth=5.0, iron=True,
         planks=3, sill=True):
    """门：净高 h（默认 150）× 净宽 w 的门洞 + 门框 + 门扇（凹进 depth）。

    约定：门洞底面 z（默认 DOOR_SILL=8，门槛），洞口净高 h 即从 z 到 z+h。
    """
    if not (DOOR_W_RANGE[0] <= w <= DOOR_W_RANGE[1]):
        print("[warn] door width %.1f 超出规范 %s" % (w, DOOR_W_RANGE))
    zc = z + h / 2.0
    # 门框：两侧立柱 + 上楣（在洞口外扩 frame）—— box_bottom 尺寸序为 (X, Y, Z)
    b.box_bottom((frame, depth, h + frame), (x - w / 2.0 - frame / 2.0, y), z, frame_mat)
    b.box_bottom((frame, depth, h + frame), (x + w / 2.0 + frame / 2.0, y), z, frame_mat)
    b.box_bottom((w + 2 * frame, depth, frame), (x, y), z + h, frame_mat)
    # 门扇（凹进墙面 7px：有真实门洞进深才有阴影，齐平会读成一块贴板）
    yl = y + 7.0 - depth * 0.5
    b.box((w - 2.0, leaf_depth, h - 2.0), (x, yl, zc), mat)
    if planks:                                       # 门板竖缝（细凸条）
        for i in range(1, planks):
            px = -w / 2.0 + w * i / float(planks)
            b.box((2.5, leaf_depth * 0.5, h - 4.0), (x + px, yl - leaf_depth * 0.35, zc), "timber")
    if iron:                                         # 铁铰链 + 门环
        for zz in (z + h * 0.22, z + h * 0.78):
            b.box((w - 8.0, 3.0, 5.0), (x, yl - leaf_depth * 0.55, zz), "iron")
        b.cylinder((x + w * 0.24, yl - leaf_depth * 0.55, z + h * 0.5), 4.5, 3.0,
                   "iron", segments=10, axis="Y")
    if sill:
        b.box_bottom((w + 2 * frame, 8.0, DOOR_SILL), (x, y), z - DOOR_SILL, "stone")
    return {"clear_w": w, "clear_h": h, "z0": z, "z1": z + h, "frame": frame}


def window(b, ow=52.0, oh=58.0, x=0.0, y=0.0, z=0.0, mat="glass",
           frame_mat="timber", frame=6.0, depth=5.0, sill=True, shutters=False,
           shutter_mat="wood", muntins=1, bars=False, axis="X", face_dir=-1.0):
    """窗：洞口净尺寸 ow×oh（z 为窗台高），带木框、凹进玻璃、窗台石、百叶/格栅。

    axis="X"：(x, y) = (窗中心 x, 墙面 y)，贴正面/背面墙；
    axis="Y"：(x, y) = (墙面 x, 窗中心 y)，贴 ±X 侧墙（face_dir=+1 → 朝 +X）。
    """
    if axis == "X":
        origin, u0 = (0.0, y), x
    else:
        origin, u0 = (x, 0.0), y

    def seg(a0, a1, o0, o1, z0, z1, m):
        _seg(b, axis, origin, face_dir, a0, a1, o0, o1, z0, z1, m)

    ao, ai = depth / 2.0, -depth / 2.0
    # 木框：左右立柱 + 上楣 + 下槛（都比洞口外扩 frame）
    seg(u0 - ow / 2.0 - frame, u0 - ow / 2.0, ai, ao, z - frame, z + oh + frame, frame_mat)
    seg(u0 + ow / 2.0, u0 + ow / 2.0 + frame, ai, ao, z - frame, z + oh + frame, frame_mat)
    seg(u0 - ow / 2.0 - frame, u0 + ow / 2.0 + frame, ai, ao, z + oh, z + oh + frame, frame_mat)
    seg(u0 - ow / 2.0, u0 + ow / 2.0, ai, ao, z - frame, z, frame_mat)
    # 玻璃（凹进墙面 depth/2 之后）
    g0, g1 = -depth / 2.0 + 1.0, -depth / 2.0 + 5.0
    seg(u0 - ow / 2.0, u0 + ow / 2.0, g0, g1, z, z + oh, mat)
    if muntins:                                      # 窗棂（十字）
        seg(u0 - ow / 2.0, u0 + ow / 2.0, g0 - 1.5, g1 - 1.5, z + oh / 2.0 - 2.0,
            z + oh / 2.0 + 2.0, frame_mat)
        seg(u0 - 2.0, u0 + 2.0, g0 - 1.5, g1 - 1.5, z, z + oh, frame_mat)
    if bars:
        for i in range(1, 4):
            uu = u0 - ow / 2.0 + ow * i / 4.0
            seg(uu - 1.25, uu + 1.25, g0 - 3.0, g0, z, z + oh, "iron")
    if sill:
        seg(u0 - ow / 2.0 - frame - 3.0, u0 + ow / 2.0 + frame + 3.0, ai, ao + 1.0,
            z - frame - 6.0, z - frame, "stone")
    if shutters:
        for sx in (-1.0, 1.0):
            uu = u0 + sx * (ow / 2.0 + frame + ow * 0.22)
            seg(uu - ow * 0.20, uu + ow * 0.20, ao - 3.0, ao + 1.0, z - 2.0,
                z + oh + 2.0, shutter_mat)
    return {"ow": ow, "oh": oh, "z0": z, "z1": z + oh, "u": u0, "axis": axis}


def chimney(b, w=26.0, d=26.0, h=60.0, mat="stone_dark", x=0.0, y=0.0, z=0.0,
            cap_mat=None, cap=10.0, flue=False):
    """烟囱：柱身 + 压顶（比柱身宽）。z = 柱底，h = 柱身净高。"""
    b.box_bottom((w, d, h), (x, y), z, mat)
    cap_mat = cap_mat or mat
    b.box_bottom((w + 12.0, d + 12.0, cap), (x, y), z + h, cap_mat)
    if flue:
        b.cylinder((x, y, z + h + cap + 6.0), min(w, d) * 0.36, 12.0, "iron", segments=12)
    return {"h": h, "w": w, "top": z + h + cap}


def plinth(b, w, d, h, mat="stone_dark", x=0.0, y=0.0, z=0.0, gap=None, lip=8.0):
    """勒脚/台基：比墙体外扩 lip。gap=(x0,x1) 时为门洞留缺口（另加门槛石）。"""
    if gap is None:
        b.box_bottom((w + 2 * lip, d + 2 * lip, h), (x, y), z, mat)
    else:
        for (sx0, sx1) in _solid_segments((x - w / 2.0 - lip, x + w / 2.0 + lip),
                                          [(x + gap[0], x + gap[1])]):
            b.box_bottom((sx1 - sx0, d + 2 * lip, h), ((sx0 + sx1) / 2.0, y), z, mat)
    return {"h": h, "lip": lip}


def step_stone(b, w=76.0, depth=26.0, h=10.0, x=0.0, y=0.0, z=0.0, mat="stone"):
    """门前台阶石。y 应传墙面前方（-Y 方向）。"""
    b.box_bottom((w, depth, h), (x, y), z, mat)


def post(b, size=16.0, h=190.0, mat="wood", x=0.0, y=0.0, z=0.0, d=None):
    """立柱（方截面 size×size，可另给 d 作 Y 向深度）。"""
    b.box_bottom((size, d or size, h), (x, y), z, mat)
    return {"size": size, "h": h}


def beam(b, length, size=14.0, depth=None, mat="wood", x=0.0, y=0.0, z=0.0, axis="X"):
    """横梁（默认沿 X）。z = 梁底。"""
    d = depth or size
    size_v = (length, d, size) if axis == "X" else (d, length, size)
    b.box_bottom(size_v, (x, y), z, mat)


def strut(b, p1, p2, size=10.0, mat="wood"):
    """两点间斜撑/斜梁（任意朝向方料）。"""
    a, c = Vector(p1), Vector(p2)
    v = c - a
    L = v.length
    if L < 1e-6:
        return
    d = v / L
    helper = Vector((0, 0, 1)) if abs(d.z) < 0.9 else Vector((1, 0, 0))
    u = helper.cross(d).normalized()
    w = d.cross(u).normalized()
    b.box_oriented((a + c) / 2.0, (d, u, w), (L / 2.0, size / 2.0, size / 2.0), mat)


def _pt(axis, origin, fdir, u, o, z):
    """局部墙面坐标 → 世界坐标。

    u = 沿墙方向（相对墙心）；o = 垂直墙面的偏移（>=0 朝凸出面）；z = 绝对高度。
    axis="X"：origin=(墙心 x, 墙面 y)，凸出方向 = fdir*Y
    axis="Y"：origin=(墙面 x, 墙心 y)，凸出方向 = fdir*X
    """
    if axis == "X":
        return (origin[0] + u, origin[1] + fdir * o, z)
    return (origin[0] + fdir * o, origin[1] + u, z)


def _seg(b, axis, origin, fdir, u0, u1, o0, o1, z0, z1, mat):
    """局部墙面坐标里的一个长方体段。"""
    c = _pt(axis, origin, fdir, (u0 + u1) / 2.0, (o0 + o1) / 2.0, (z0 + z1) / 2.0)
    if axis == "X":
        size = (abs(u1 - u0), abs(o1 - o0), abs(z1 - z0))
    else:
        size = (abs(o1 - o0), abs(u1 - u0), abs(z1 - z0))
    b.box(size, c, mat)


def timber_frame(b, w, h, mat="timber", origin=(0.0, 0.0), z=0.0, depth=7.0,
                 post=12.0, top_band=16.0, mid_band=None, bays=3, braces=True,
                 openings=(), axis="X", face_dir=-1.0, embed=3.0):
    """木骨架（半露木/木骨墙）：上下横带 + 竖柱 + 斜撑，贴墙面凸出。

    origin / axis / face_dir 见 `_pt`。openings=[(u, ow), ...] 为洞口（u 相对墙心），
    竖柱与斜撑自动避让洞口，避免木骨横穿门窗。
    """
    half = w / 2.0
    o_in, o_out = -embed, depth - embed

    def seg(u0, u1, z0, z1, m=None):
        _seg(b, axis, origin, face_dir, u0, u1, o_in, o_out, z0, z1, m or mat)

    def pt(u, zz):
        return _pt(axis, origin, face_dir, u, (o_in + o_out) / 2.0, zz)

    seg(-half, half, z + h - top_band, z + h)
    seg(-half, half, z, z + top_band * 0.8)
    if mid_band:
        seg(-half, half, z + h - top_band - mid_band, z + h - top_band)
    n = max(2, int(bays) + 1)
    xs = [-half + post / 2.0 + (w - post) * i / float(n - 1) for i in range(n)]
    holes = [(u - ow / 2.0 - post * 0.7, u + ow / 2.0 + post * 0.7) for (u, ow) in openings]
    xs = [u for u in xs
          if not any(h0 < u + post / 2.0 and u - post / 2.0 < h1 for (h0, h1) in holes)]
    bay_h = h - top_band * 1.8
    for u in xs:
        seg(u - post / 2.0, u + post / 2.0, z + top_band * 0.8, z + top_band * 0.8 + bay_h)
    if braces:
        for i in range(len(xs) - 1):
            u0, u1 = xs[i] + post / 2.0, xs[i + 1] - post / 2.0
            if u1 - u0 < 40.0:
                continue
            if any(h0 < u1 and h1 > u0 for (h0, h1) in holes):
                continue
            zb = z + top_band * 0.8
            zt = zb + bay_h * 0.42
            strut(b, pt(u0 + 3.0, zb), pt(u1 - 3.0, zt), post * 0.7, mat)
            strut(b, pt(u1 - 3.0, zb), pt(u0 + 3.0, zt), post * 0.7, mat)


def gable_timber(b, span, rise, mat="timber", origin=(0.0, 0.0), z=0.0,
                 axis="X", face_dir=-1.0, depth=7.0, embed=3.0, thick=11.0,
                 tie=True, king=True, collar=0.42):
    """山墙三角面的木骨（戗檐斜梁 + 中柱 + 系梁），全部落在三角形内部。"""
    half = span / 2.0

    def seg(u0, u1, z0, z1):
        _seg(b, axis, origin, face_dir, u0, u1, -embed, depth - embed, z0, z1, mat)

    def pt(u, zz):
        return _pt(axis, origin, face_dir, u, (depth - 2 * embed) / 2.0, zz)

    if tie:
        seg(-half + thick, half - thick, z, z + thick * 0.8)
    for sx in (-1.0, 1.0):                       # 戗檐斜梁：沿三角形两腰
        strut(b, pt(sx * (half - thick * 0.6), z + 2.0), pt(0.0, z + rise - 4.0),
              thick, mat)
    if king:
        seg(-thick / 2.0, thick / 2.0, z, z + rise - 6.0)
    if collar:
        zc = z + rise * collar
        hu = half * (1.0 - collar) * 0.92
        seg(-hu, hu, zc, zc + thick * 0.7)


def plank_siding(b, w, h, mat="wood", origin=(0.0, 0.0), z=0.0, plank_w=20.0,
                 gap=2.0, depth=5.0, openings=(), jitter=2.0, seed=1,
                 axis="X", face_dir=-1.0, gable_rise=0.0, embed=3.2, top_jitter=4.0):
    """竖向木板饰面（谷仓/木屋/山墙）：一排竖板贴墙面，按洞口裁切。

    gable_rise > 0 时板顶按三角形轮廓收（用于山墙满铺竖板）。
    openings = [(u, ow, z0, z1), ...]（u 相对墙心，z 为绝对高度）。
    """
    half = w / 2.0
    n = max(1, int(round(w / plank_w)))
    pw = w / float(n)
    holes = [(u - ow / 2.0, u + ow / 2.0) for (u, ow, _z0, _z1) in openings]
    st = seed * 1103515245 + 12345
    for i in range(n):
        u0, u1 = -half + pw * i, -half + pw * (i + 1)
        zholes = [(z0, z1) for (u, ow, z0, z1) in openings
                  if (u - ow / 2.0) < u1 and (u + ow / 2.0) > u0]
        top = z + h
        if gable_rise > 0.0:
            up = max(abs(u0), abs(u1))
            top = min(top, z + max(10.0, gable_rise * (1.0 - up / half) - 2.0))
        st = (st * 1103515245 + 12345) & 0x7fffffff
        jt = (st % 1000) / 1000.0 * jitter
        st = (st * 1103515245 + 12345) & 0x7fffffff
        if i > 0:                              # 板端高差错开（避免一排亮点）
            top -= (st % 1000) / 1000.0 * top_jitter
        for (za, zb) in _solid_segments((z, top), zholes):
            if zb - za < 6.0:
                continue
            _seg(b, axis, origin, face_dir, u0 + gap / 2.0, u1 - gap / 2.0,
                 -embed, depth - embed + jt, za, zb, mat)


def railing(b, w, x=0.0, y=0.0, z=0.0, mat="wood", h=60.0, posts=4, size=9.0):
    """栏杆/矮栏（棚屋前沿、二层挑台）。z = 栏底。"""
    b.box_bottom((w, size, 8.0), (x, y), z + h - size, mat)
    for i in range(max(2, posts)):
        px = x - w / 2.0 + size / 2.0 + (w - size) * i / float(max(2, posts) - 1)
        b.box_bottom((size, size, h), (px, y), z, mat)


def barrel(b, x=0.0, y=0.0, z=0.0, r=15.0, h=40.0, mat="wood", band_mat="iron",
           segments=12, lid=False):
    """木桶（带两道铁箍）。"""
    b.cylinder((x, y, z + h / 2.0), r, h, mat, segments=segments)
    for t in (0.18, 0.82):
        b.cylinder((x, y, z + h * t), r * 1.06, 5.0, band_mat, segments=segments)
    if lid:
        b.cylinder((x, y, z + h + 1.0), r * 0.94, 3.0, "wood_dark", segments=segments)


def anvil(b, x=0.0, y=0.0, z=0.0, mat="iron", stump=True):
    """铁砧（含可选木墩）：总高约 60。"""
    if stump:
        b.cylinder((x, y, z + 20.0), 17.0, 40.0, "wood_dark", segments=12)
        base_z = z + 40.0
    else:
        base_z = z
    b.box_bottom((34.0, 20.0, 7.0), (x, y), base_z, mat)                 # 底座
    b.box_bottom((18.0, 15.0, 15.0), (x, y), base_z + 7.0, mat)          # 腰
    b.box_bottom((45.0, 19.0, 10.0), (x, y), base_z + 22.0, mat)         # 砧面
    b.cylinder((x + 28.0, y, base_z + 27.0), 6.5, 22.0, mat, segments=10, axis="X", taper=0.35)


def forge(b, x=0.0, y=0.0, z=0.0, w=54.0, d=46.0, body_h=64.0, mat="iron",
          masonry="stone_dark", flue_h=196.0, wall=11.0, flue_r=9.0):
    """铁炉：砖石基座 + 炉体（**前面留真炉口**，内见火光）+ 炉罩 + 烟管。

    炉体由左右/后/顶/底五块板拼成，前方开口 -> 炉膛与火焰真实可见。
    """
    b.box_bottom((w + 14.0, d + 12.0, 16.0), (x, y), z, masonry)          # 砖石基座
    z0 = z + 16.0
    top_h = 12.0
    b.box_bottom((wall, d, body_h), (x - w / 2.0 + wall / 2.0, y), z0, mat)      # 左板
    b.box_bottom((wall, d, body_h), (x + w / 2.0 - wall / 2.0, y), z0, mat)      # 右板
    b.box_bottom((w - 2 * wall, wall, body_h), (x, y + d / 2.0 - wall / 2.0), z0, mat)
    b.box_bottom((w, d, top_h), (x, y), z0 + body_h - top_h, mat)         # 炉顶
    b.box_bottom((w - 2 * wall, d - wall, 12.0), (x, y + wall * 0.5), z0, mat)   # 炉底
    fw = w - 2 * wall - 4.0
    b.box_bottom((fw, 6.0, body_h - top_h - 16.0), (x, y + d / 2.0 - wall - 5.0),
                 z0 + 14.0, "wood_dark")                                  # 炉膛暗腔
    # 火光必须落在**炉口内**（y 靠前），否则被炉体挡住整块看不见
    b.box_bottom((fw - 6.0, 5.0, 34.0), (x, y - d / 2.0 + wall + 6.0),
                 z0 + 16.0, "fire")
    b.box_bottom((fw - 6.0, 20.0, 6.0), (x, y - d / 2.0 + wall + 12.0),
                 z0 + 16.0, "ember")                                      # 炉口炭层
    b.box_bottom((w * 0.74, d * 0.74, 12.0), (x, y), z0 + body_h, mat)    # 炉台
    b.box_bottom((24.0, 24.0, 14.0), (x, y), z0 + body_h + 12.0, mat)     # 炉罩
    top = z0 + body_h + 26.0
    b.cylinder((x, y, top + flue_h / 2.0), flue_r, flue_h, mat, segments=12)
    b.cylinder((x, y, top + flue_h + 5.0), flue_r * 1.25, 7.0, mat, segments=12)
    return {"top": top + flue_h, "fire_z": z0 + 18.0}



def bench(b, x=0.0, y=0.0, z=0.0, w=64.0, d=30.0, h=48.0, mat="wood"):
    """工作台/长凳。"""
    b.box_bottom((w, d, 7.0), (x, y), z + h - 7.0, mat)
    for sx in (-1.0, 1.0):
        for sy in (-1.0, 1.0):
            b.box_bottom((8.0, 8.0, h - 7.0),
                         (x + sx * (w / 2.0 - 8.0), y + sy * (d / 2.0 - 8.0)), z, mat)


def stool(b, x=0.0, y=0.0, z=0.0, r=13.0, h=30.0, mat="wood"):
    """圆凳。"""
    b.cylinder((x, y, z + h - 4.0), r, 8.0, mat, segments=10)
    for i in range(3):
        th = 2 * math.pi * i / 3.0
        b.box_bottom((6.0, 6.0, h - 8.0),
                     (x + math.cos(th) * r * 0.55, y + math.sin(th) * r * 0.55), z, mat)


def contact_shadow(b, w, d, x=0.0, y=0.0, spread=26.0, steps=3):
    """接地阴影（§8.2 接地要求）：贴着地面的三级踏板，由内向外逐级变浅。

    太阳（§8.4）在前左上方，投影落在建筑后方被自身遮住，地面看不到太阳影子，
    所以接地感必须由几何自带的接触暗带提供 —— 3/4 俯视角下呈"建筑坐在自己的
    暗影里"的读法，缩到游戏尺寸也不会飘。
    """
    mats = ("shadow_near", "shadow_mid", "shadow_far")
    for i in range(steps):
        k = float(i)
        sp = spread * (1.0 + 0.55 * k)
        h = max(0.9, 2.4 - 0.7 * k)                  # 越外圈越薄 → 读作阴影而非台阶
        b.box_bottom((w + 2.0 * sp, d + 2.0 * sp, h), (x, y), 0.0,
                     mats[i] if i < len(mats) else "shadow_far")
    return {"spread": spread}


def stickman(b, x=0.0, y=0.0, z=0.0, w=30.0, d=14.0, h=STICKMAN_H, mat="silhouette"):
    """比例校验用的人形剪影：总高恰好 130（腿 + 躯干 + 双臂 + 头）。

    有腿缝与横伸双臂，才能和"人 vs 房"一眼对读；纯方块会被读成柱子。
    """
    leg_h = h * 0.36
    torso_h = h * 0.42
    head_h = h - leg_h - torso_h
    leg_w = w * 0.34
    for sx in (-1.0, 1.0):                                   # 双腿（中间留缝）
        b.box_bottom((leg_w, d, leg_h), (x + sx * w * 0.30, y), z, mat)
    b.box_bottom((w, d, torso_h), (x, y), z + leg_h, mat)     # 躯干
    b.box_bottom((w * 1.45, d * 0.8, h * 0.055),              # 双臂（横杆）
                 (x, y), z + leg_h + torso_h - h * 0.16, mat)
    b.box_bottom((w * 0.62, d, head_h), (x, y), z + leg_h + torso_h, mat)   # 头
    return {"h": h}


def hay_door(b, w, h, x=0.0, y=0.0, z=0.0, mat="wood_dark", frame_mat="timber",
             frame=8.0, depth=6.0, brace=True):
    """干草门/上翻门板（谷仓上层洞口；复合门洞豁免 §8.3，不受单扇 45~60 限制）。"""
    b.box_bottom((frame, depth, h + frame), (x - w / 2.0 - frame / 2.0, y), z, frame_mat)
    b.box_bottom((frame, depth, h + frame), (x + w / 2.0 + frame / 2.0, y), z, frame_mat)
    b.box_bottom((w + 2 * frame, depth, frame), (x, y), z + h, frame_mat)
    yl = y + depth * 0.5 - 4.0
    b.box((w - 2.0, 5.0, h - 2.0), (x, yl, z + h / 2.0), mat)
    if brace:                                   # 门板上的 Z 形压条
        strut(b, (x - w / 2.0 + 4.0, yl, z + 6.0), (x + w / 2.0 - 4.0, yl, z + h - 6.0),
              5.0, frame_mat)
        b.box((w - 4.0, 3.0, 6.0), (x, yl, z + h * 0.5), frame_mat)
    return {"w": w, "h": h, "z0": z, "z1": z + h}


# ---------------------------------------------------------------- §4 装配

def _mk(name, width_cells, spec):
    spec = dict(spec)
    spec["def"] = name
    spec["width_cells"] = width_cells
    spec["grid_w"] = width_cells * CELL
    return spec


def room_shell(b, W, D, z, h, wt, front_mat, side_mat=None, back_mat=None,
               front_openings=(), side_openings=(), back_openings=()):
    """四面墙板围合（而不是一块实心体量）：正面/背面沿 X，左右侧沿 Y，厚 wt。

    只有这样侧墙才开得出真洞（侧窗/侧门），正面墙板收进 2×wt 让角部由侧墙
    占据，避免两块板的端面共面打架。
    """
    side_mat = side_mat or front_mat
    back_mat = back_mat or front_mat
    wall_panel(b, W - 2.0 * wt, h, wt, front_mat, 0.0, -D / 2.0 + wt / 2.0, z,
               openings=front_openings)
    wall_panel(b, W - 2.0 * wt, h, wt, back_mat, 0.0, D / 2.0 - wt / 2.0, z,
               openings=back_openings)
    for sx in (-1.0, 1.0):
        wall_panel(b, D, h, wt, side_mat, sx * (W / 2.0 - wt / 2.0), 0.0, z,
                   openings=side_openings, axis="Y")
    return {"wt": wt}


def bay_centers(W, bays):
    """开间中心（相对建筑中心，升序）。"""
    bw = W / float(bays)
    return [-W / 2.0 + bw * (i + 0.5) for i in range(bays)]


def bay_openings(W, bays, door_w=None, door_bay=0, win_w=52.0, win_h=60.0,
                 win_z=70.0, door_x=None):
    """按开间布洞口（§8.2「每开间最多 1 窗」）：

    带门时门占 door_bay 一个开间，其余开间各排 1 扇窗；二层按开间数排窗
    （同一个函数再调一次即可）。返回 (门中心 x | None, [(窗x, 窗宽, z0, z1), ...])。
    """
    cs = bay_centers(W, bays)
    bw = W / float(bays)
    ww = min(win_w, bw - 30.0)
    wins = []
    for i, cx in enumerate(cs):
        if door_w is not None and i == door_bay:
            continue
        wins.append((cx, ww, win_z, win_z + win_h))
    if door_w is None:
        return None, wins
    dx = cs[door_bay] if door_x is None else door_x
    return dx, wins


#: def × 宽度档的最终定尺（§8.2 长宽比口径倒推，全部数字集中在此，方便复核）
#: 剪影总高 = 檐口 + rise + 屋面厚度余弦增量 + 接地细节；6 格档受"门 150 + 楣梁"
#: 与"剪影 ≤1.5×宽"双向挤压，屋面只能给到 ~76，见报告里的算术说明。
HOUSE_TIERS = {
    6:  dict(D=112.0, plinth=12.0, wall=170.0, rise=80.0, door_w=50.0, wt=16.0),
    8:  dict(D=160.0, plinth=16.0, wall=176.0, rise=90.0, door_w=54.0, wt=18.0),
    12: dict(D=200.0, plinth=18.0, wall=206.0, rise=105.0, door_w=56.0, wt=20.0),
    16: dict(D=232.0, plinth=20.0, wall=220.0, rise=112.0, door_w=58.0, wt=22.0),
}
TOWNHOUSE_TIERS = {
    12: dict(D=208.0, plinth=18.0, storey=178.0, rise=150.0, door_w=56.0,
             wt=20.0, jetty=10.0),
    16: dict(D=240.0, plinth=20.0, storey=178.0, rise=168.0, door_w=58.0,
             wt=20.0, jetty=10.0),
}
BARN_TIERS = {
    8:  dict(D=176.0, plinth=12.0, wall=190.0, rise=95.0, wt=20.0, leaf=58.0),
    12: dict(D=200.0, plinth=14.0, wall=200.0, rise=102.0, wt=22.0, leaf=62.0),
    16: dict(D=224.0, plinth=16.0, wall=210.0, rise=108.0, wt=22.0, leaf=62.0),
}
SMITHY1_TIERS = {
    6: dict(D=144.0, post_h=168.0, rise=80.0, post=16.0, roof_t=18.0),
    8: dict(D=176.0, post_h=190.0, rise=96.0, post=16.0, roof_t=20.0),
}


def assemble_house(width_cells=8):
    """民居：单层，抹灰 + 木骨墙 / 茅草顶。

    §8.2 口径：带门建筑最小 6 格（4 格档取消）；开间 = 格数/4（6→2、8→2、12→3），
    每开间最多 1 个洞口（门占 1 个开间），侧墙最多 1 窗；出檐 = 宽 × 20.5%。
    """
    t = HOUSE_TIERS[width_cells]
    W = width_cells * CELL
    D = t["D"]
    plinth_h, wall_h, rise, wt, door_w = t["plinth"], t["wall"], t["rise"], t["wt"], t["door_w"]
    over = eave_over(W)
    eave = plinth_h + wall_h
    yf = -D / 2.0
    bays = bays_of(width_cells)
    dx, wins = bay_openings(W, bays, door_w=door_w, door_bay=0,
                            win_w=52.0, win_h=60.0, win_z=plinth_h + 52.0)
    side_win = [(-D * 0.20, 46.0, plinth_h + 50.0, plinth_h + 104.0)]

    b = Builder("house_w%d" % width_cells)
    contact_shadow(b, W, D, spread=26.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(dx - door_w / 2.0 - 6.0, dx + door_w / 2.0 + 6.0))
    room_shell(b, W, D, plinth_h, wall_h, wt, "plaster",
               front_openings=[(dx, door_w, DOOR_SILL, DOOR_SILL + DOOR_H)] + wins,
               side_openings=side_win)
    timber_frame(b, W, wall_h, "timber", (0.0, yf), plinth_h, depth=7.0,
                 post=13.0, top_band=18.0, bays=bays, braces=True,
                 openings=[(dx, door_w)] + [(wx, ww) for (wx, ww, _a, _b) in wins])
    door(b, h=DOOR_H, w=door_w, mat="wood_dark", x=dx, y=yf, z=DOOR_SILL,
         frame_mat="timber", planks=3)
    step_stone(b, w=door_w + 30.0, depth=24.0, h=9.0, x=dx, y=yf - 17.0, z=0.0)
    for (wx, ww, z0, z1) in wins:
        window(b, ow=ww, oh=z1 - z0, x=wx, y=yf, z=z0, frame_mat="timber", muntins=1)
    for (wy, ww, z0, z1) in side_win:                # 侧墙唯一 1 窗（+X 面）
        window(b, ow=ww, oh=z1 - z0, x=W / 2.0, y=wy, z=z0, frame_mat="timber",
               shutters=True, shutter_mat="wood_dark", muntins=1,
               axis="Y", face_dir=1.0)
    roof_gable(b, W, D, rise, over, "thatch", z=eave, thickness=16.0,
               mat_under="wood_dark", cap_size=(34.0, 14.0), board_h=10.0)
    gable_infill(b, W, D, rise, "plaster", z=eave, thickness=14.0)
    for sx in (-1.0, 1.0):                       # 山墙木骨（两端，落在三角面内）
        gable_timber(b, D, rise, "timber", (sx * (W / 2.0), 0.0), eave,
                     axis="Y", face_dir=sx, thick=11.0)
    chimney(b, 26.0, 26.0, rise + 30.0 - 10.0, "stone_dark",
            -W * 0.26, -D * 0.12, plinth_h, cap_mat="white_stone", cap=10.0)

    ob = b.to_object()
    spec = _mk("house", width_cells, {
        "depth": D, "plinth_h": plinth_h, "wall_h": wall_h, "eave_h": eave,
        "rise": rise, "total_h": eave + rise, "overhang": over, "roof_t": 16.0,
        "storey_h": [wall_h], "door": (door_w, DOOR_H), "door_x": dx,
        "bays": bays, "side_windows": len(side_win),
        "material": "抹灰+木骨 / 茅草顶"})
    return ob, spec


def assemble_townhouse(width_cells=12):
    """木骨街屋：两层，抹灰 + 木骨 / 陶瓦，二层前檐悬挑 10。

    §8.2：双层单列层高 175~195（本档 178）；双层不受单层长宽比约束，但仍按
    同一口径报数 —— 8 格宽在算术上装不下（2×175 + rise 远超 1.5×256），
    故双层档从 12 格起（8 格档取消）。
    """
    t = TOWNHOUSE_TIERS[width_cells]
    W = width_cells * CELL
    D, plinth_h, sh = t["D"], t["plinth"], t["storey"]
    rise, wt, door_w, jetty = t["rise"], t["wt"], t["door_w"], t["jetty"]
    over = eave_over(W)
    eave = plinth_h + sh * 2.0
    yf1 = -D / 2.0
    yf2 = -D / 2.0 - jetty
    yb = D / 2.0
    yc2 = (yf2 + yb) / 2.0
    z2 = plinth_h + sh
    bays = bays_of(width_cells)
    dx, wins1 = bay_openings(W, bays, door_w=door_w, door_bay=0,
                             win_w=50.0, win_h=58.0, win_z=plinth_h + 40.0)
    _dz, wins2 = bay_openings(W, bays, door_w=None, win_w=50.0, win_h=54.0,
                              win_z=z2 + 46.0)
    side_win = [(-D * 0.20, 46.0, plinth_h + 40.0, plinth_h + 94.0)]

    b = Builder("townhouse_w%d" % width_cells)
    contact_shadow(b, W, D + jetty, spread=30.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(dx - door_w / 2.0 - 6.0, dx + door_w / 2.0 + 6.0))
    # ---- 一层
    room_shell(b, W, D, plinth_h, sh, wt, "plaster",
               front_openings=[(dx, door_w, DOOR_SILL, DOOR_SILL + DOOR_H)] + wins1,
               side_openings=side_win)
    timber_frame(b, W, sh, "timber", (0.0, yf1), plinth_h, depth=7.0, post=14.0,
                 top_band=18.0, bays=bays, braces=True,
                 openings=[(dx, door_w)] + [(wx, ww) for (wx, ww, _a, _b) in wins1])
    door(b, w=door_w, mat="wood_dark", x=dx, y=yf1, z=DOOR_SILL, planks=4)
    step_stone(b, w=door_w + 34.0, depth=26.0, h=10.0, x=dx, y=yf1 - 18.0)
    for (wx, ww, z0, z1) in wins1:
        window(b, ow=ww, oh=z1 - z0, x=wx, y=yf1, z=z0, muntins=1)
    for (wy, ww, z0, z1) in side_win:
        window(b, ow=ww, oh=z1 - z0, x=W / 2.0, y=wy, z=z0, shutters=True,
               shutter_mat="wood_dark", muntins=1, axis="Y", face_dir=1.0)
    # ---- 二层（前墙外挑 jetty；侧墙仍与一层齐平，不越 4 格模数）
    wall_panel(b, W, sh, D + jetty, "plaster", 0.0, yc2, z2,
               openings=wins2)
    for i in range(5):                               # 悬挑托梁
        px = -W / 2.0 + 14.0 + (W - 28.0) * i / 4.0
        b.box_bottom((14.0, 18.0, 14.0), (px, yf2 + 9.0), z2 - 14.0, "timber")
    b.box_bottom((W + 6.0, 8.0, 16.0), (0.0, yf2), z2 - 16.0, "timber")
    timber_frame(b, W, sh, "timber", (0.0, yf2), z2, depth=7.0, post=14.0,
                 top_band=14.0, bays=bays, braces=True,
                 openings=[(wx, ww) for (wx, ww, _a, _b) in wins2])
    for (wx, ww, z0, z1) in wins2:                   # 二层按开间数排窗
        window(b, ow=ww, oh=z1 - z0, x=wx, y=yf2, z=z0, shutters=True,
               shutter_mat="wood_dark", muntins=1)
    # ---- 屋顶
    roof_gable(b, W, D + jetty, rise, over, "tile", z=eave, thickness=14.0,
               mat_under="wood_dark", cap_size=(28.0, 16.0), board_h=9.0)
    gable_infill(b, W, D + jetty, rise, "plaster", z=eave, thickness=14.0)
    for sx in (-1.0, 1.0):
        gable_timber(b, D + jetty, rise, "timber", (sx * (W / 2.0), yc2),
                     eave, axis="Y", face_dir=sx, thick=11.0)
    # 烟囱压顶高度 = 屋脊高（不越脊就不会把剪影总高抬上去），位置挪到前坡上才看得见
    chimney(b, 30.0, 26.0, rise + 30.0 - 12.0, "brick", -W * 0.26, -D * 0.12,
            eave - 30.0, cap_mat="stone_dark", cap=12.0)

    ob = b.to_object()
    spec = _mk("townhouse", width_cells, {
        "depth": D + jetty, "plinth_h": plinth_h, "wall_h": sh * 2.0, "eave_h": eave,
        "rise": rise, "total_h": eave + rise, "overhang": over, "roof_t": 14.0,
        "storey_h": [sh, sh], "door": (door_w, DOOR_H), "door_x": dx, "jetty": jetty,
        "bays": bays, "double_storey": True,
        "material": "抹灰+木骨 / 陶瓦"})
    return ob, spec


def assemble_barn(width_cells=8):
    """谷仓：单层高墙 + 陡坡木板顶 + 双扇大门（复合门洞豁免 §8.3）+ 侧通风窄缝。

    复合门洞：双扇合宽 ≤140（8 格 = 2×58+6 = 122），不受单扇 45~60 限制；
    正面开洞按"每开间最多 1 个"控制：大门居中（复合件，占中缝），
    左右各 1 条窄通风缝（每开间恰好 1 条），不再做"一排窗"。
    """
    t = BARN_TIERS[width_cells]
    W = width_cells * CELL
    D, plinth_h, wall_h = t["D"], t["plinth"], t["wall"]
    rise, wt, leaf_w = t["rise"], t["wt"], t["leaf"]
    over = eave_over(W)
    eave = plinth_h + wall_h
    yf, yb = -D / 2.0, D / 2.0
    gap = 6.0
    opening_w = leaf_w * 2.0 + gap                    # ≤140（§8.3）
    # 通风窄缝置于**上半墙角撑之下**（角撑从 eave-78 起，窗口压在它下面才不会被劈成两半）
    vent_z = plinth_h + 40.0
    vents = [(-W * 0.36, 24.0, vent_z, vent_z + 48.0),
             (W * 0.36, 24.0, vent_z, vent_z + 48.0)]

    b = Builder("barn_w%d" % width_cells)
    contact_shadow(b, W, D, spread=28.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(-opening_w / 2.0 - 6.0, opening_w / 2.0 + 6.0))
    room_shell(b, W, D, plinth_h, wall_h, wt, "wood",
               front_openings=[(0.0, opening_w, DOOR_SILL, DOOR_SILL + DOOR_H)] + vents)
    # 双扇大门（各 1 扇，落在 45~60 内；合宽为复合洞口）
    for i, sx in enumerate((-1.0, 1.0)):
        door(b, h=DOOR_H, w=leaf_w, mat="wood_door",
             x=sx * (leaf_w / 2.0 + gap / 2.0), y=yf, z=DOOR_SILL,
             frame_mat="wood_dark", frame=8.0, planks=3, iron=True)
    b.box_bottom((10.0, 10.0, DOOR_H), (0.0, yf), DOOR_SILL, "wood_dark")   # 中缝压条
    b.box_bottom((opening_w + 40.0, 14.0, 16.0), (0.0, yf), DOOR_SILL + DOOR_H + 8.0,
                 "wood_dark")
    step_stone(b, w=opening_w + 40.0, depth=30.0, h=10.0, x=0.0, y=yf - 20.0)
    for (wx, ww, z0, z1) in vents:                    # 通风窄缝（铁栅，不做窗棂）
        window(b, ow=ww, oh=z1 - z0, x=wx, y=yf, z=z0, mat="glass",
               frame_mat="wood_dark", muntins=0, bars=True, sill=False)
    for sx in (-1.0, 1.0):                            # 角部斜撑（只在上半墙）
        strut(b, (sx * (W / 2.0 - 10.0), yf, eave - 78.0),
              (sx * (W / 2.0 - 64.0), yf, eave - 10.0), 11.0, "wood_dark")
    roof_gable(b, W, D, rise, over, "wood_roof", z=eave, thickness=16.0,
               mat_under="wood_dark", cap_size=(32.0, 14.0), cap_mat="wood_dark",
               board_h=12.0, uv_swap=True)
    gable_infill(b, W, D, rise, "wood", z=eave, thickness=14.0)
    for sx in (-1.0, 1.0):
        plank_siding(b, D, rise, "wood_light", (sx * (W / 2.0), 0.0), eave,
                     plank_w=24.0, gap=2.5, depth=6.0, seed=5, axis="Y",
                     face_dir=sx, gable_rise=rise)
        gable_timber(b, D, rise, "timber", (sx * (W / 2.0), 0.0), eave,
                     axis="Y", face_dir=sx, thick=12.0)

    ob = b.to_object()
    spec = _mk("barn", width_cells, {
        "depth": D, "plinth_h": plinth_h, "wall_h": wall_h, "eave_h": eave,
        "rise": rise, "total_h": eave + rise, "overhang": over, "roof_t": 16.0,
        "storey_h": [wall_h], "door": (opening_w, DOOR_H), "door_x": 0.0,
        "door_leaf": (leaf_w, DOOR_H), "composite_door": True,
        "material": "木板 / 木板顶"})
    return ob, spec


def assemble_smithy1(width_cells=8):
    """茅草棚工坊：柱撑开放棚 + 铁炉/铁砧/桶/凳（§8.3 开放棚无门 → 不受 6 格限制）。

    棚子没有"墙高"这个量，剪影 = 柱高 + 屋顶 rise，长宽比同样按 §8.2 口径收。
    """
    t = SMITHY1_TIERS[width_cells]
    W = width_cells * CELL
    D, post_h, rise, post_s = t["D"], t["post_h"], t["rise"], t["post"]
    roof_t = t["roof_t"]
    over = eave_over(W)
    yf = -D / 2.0 + post_s / 2.0
    yb = D / 2.0 - post_s / 2.0
    side_len = D * 0.55                              # 侧墙只做后半段（前方开放）

    b = Builder("smithy1_w%d" % width_cells)
    contact_shadow(b, W, D * 1.15, spread=26.0)
    # 后墙 + 侧墙后半段（木板）
    wall_panel(b, W, post_h, 14.0, "wood", 0.0, D / 2.0 - 7.0, 0.0)
    for sx in (-1.0, 1.0):
        wall_panel(b, side_len, post_h, 14.0, "wood",
                   sx * (W / 2.0 - 7.0), D / 2.0 - side_len / 2.0, 0.0, axis="Y")
    # 柱：四角 + 前檐中柱
    for sx in (-1.0, 1.0):
        for yy in (yb, yf):
            post(b, post_s, post_h, "wood_dark", sx * (W / 2.0 - post_s / 2.0), yy)
    posts_x = [0.0] if width_cells <= 6 else [-W / 4.0, W / 4.0]
    for px in posts_x:
        post(b, post_s, post_h, "wood_dark", px, yf)
    # 檐檩 + 前后横梁 + 斜撑
    beam(b, W, 18.0, 16.0, "wood_dark", 0.0, yf, post_h - 16.0)
    beam(b, W, 18.0, 16.0, "wood_dark", 0.0, yb, post_h - 16.0)
    for sx in (-1.0, 1.0):
        beam(b, D - post_s, 16.0, 16.0, "wood_dark", sx * (W / 2.0 - post_s / 2.0),
             0.0, post_h - 16.0, axis="Y")
    for sx in (-1.0, 1.0):
        strut(b, (sx * (W / 2.0 - post_s - 2.0), yf, post_h - 40.0),
              (sx * (W / 2.0 - 78.0), yf, post_h - 4.0), 11.0, "wood_dark")
    strut(b, (0.0, yf, post_h - 4.0), (0.0, yb + 10.0, post_h - 4.0), 12.0, "wood_dark")
    # 茅草顶（出檐 = 宽 × 20.5%）
    roof_gable(b, W, D, rise, over, "thatch_old", z=post_h, thickness=roof_t,
               mat_under="wood", cap_size=(36.0, 18.0), cap_mat="thatch_old",
               board_mat="wood_dark", board_h=9.0)
    gable_infill(b, W, D, rise, "wood", z=post_h, thickness=14.0)
    for sx in (-1.0, 1.0):                           # 山墙满铺竖板 + 木骨
        plank_siding(b, D, rise, "wood_light", (sx * (W / 2.0), 0.0), post_h,
                     plank_w=22.0, gap=2.0, depth=6.0, seed=5, axis="Y",
                     face_dir=sx, gable_rise=rise)
        gable_timber(b, D, rise, "timber", (sx * (W / 2.0), 0.0), post_h,
                     axis="Y", face_dir=sx, thick=12.0)
    # 铁炉（靠后墙）+ 家什
    forge(b, -W * 0.12, D / 2.0 - 48.0, 0.0, w=58.0, d=46.0, body_h=64.0,
          flue_h=max(40.0, post_h + rise - 60.0 - 152.0))
    anvil(b, x=-W * 0.30, y=-D * 0.16, z=0.0)
    barrel(b, x=-W * 0.40, y=D * 0.12, z=0.0, r=15.0, h=42.0, lid=True)
    barrel(b, x=-W * 0.26, y=D * 0.24, z=0.0, r=13.0, h=36.0)
    bench(b, x=W * 0.26, y=D * 0.10, z=0.0, w=68.0, d=32.0, h=50.0)
    stool(b, x=W * 0.34, y=-D * 0.16, z=0.0)
    b.box_bottom((12.0, 12.0, 46.0), (W * 0.40, D * 0.26), 0.0, "wood_dark")  # 水桶桩

    ob = b.to_object()
    spec = _mk("smithy1", width_cells, {
        "depth": D, "plinth_h": 0.0, "wall_h": post_h, "eave_h": post_h,
        "rise": rise, "total_h": post_h + rise, "overhang": over, "roof_t": roof_t,
        "storey_h": [post_h], "door": None, "open_shed": True,
        "material": "木柱 / 茅草顶"})
    return ob, spec


ASSEMBLERS = {
    "house": assemble_house,
    "townhouse": assemble_townhouse,
    "barn": assemble_barn,
    "smithy1": assemble_smithy1,
}

#: 本轮对比图要出的 def × 宽度档（4 格档已按 §8.2 取消带门建筑）
PROBE_LIST = [("house", 8), ("house", 12), ("house", 16),
              ("townhouse", 12), ("townhouse", 16),
              ("barn", 12), ("smithy1", 8)]


# ---------------------------------------------------------------- §5 自检

def measure(ob):
    """对象世界空间包围盒（含 object 变换，供布局/取景/比例实测用）。"""
    mw = ob.matrix_world
    pts = [mw @ v.co for v in ob.data.vertices]
    xs = [p.x for p in pts]
    ys = [p.y for p in pts]
    zs = [p.z for p in pts]
    return {"x": (min(xs), max(xs)), "y": (min(ys), max(ys)), "z": (min(zs), max(zs))}


def shape_points(ob, skip_ground=True):
    """建筑本体顶点（默认剔除接地阴影踏板：那是贴地贴片，不是建筑剪影）。"""
    mw = ob.matrix_world
    me = ob.data
    ground_slots = set()
    if skip_ground:
        for i, mat in enumerate(me.materials):
            if mat is not None and "shadow_" in mat.name:
                ground_slots.add(i)
    if not ground_slots:
        return [mw @ v.co for v in me.vertices]
    ids = set()
    for p in me.polygons:
        if p.material_index in ground_slots:
            continue
        ids.update(p.vertices)
    return [mw @ me.vertices[i].co for i in ids]


def shape_bbox(ob, skip_ground=True):
    pts = shape_points(ob, skip_ground)
    xs = [p.x for p in pts]
    ys = [p.y for p in pts]
    zs = [p.z for p in pts]
    return {"x": (min(xs), max(xs)), "y": (min(ys), max(ys)), "z": (min(zs), max(zs))}


def cam_axes(yaw_deg=12.0, tilt_deg=10.0):
    """§8.1 固定 3/4 视角的屏幕基向量（right=屏幕右, up=屏幕上）。"""
    y, t = math.radians(yaw_deg), math.radians(tilt_deg)
    right = Vector((math.cos(y), math.sin(y), 0.0))
    up = Vector((-math.sin(y) * math.sin(t), math.cos(y) * math.sin(t), math.cos(t)))
    return right, up


def silhouette(ob, yaw_deg=12.0, tilt_deg=10.0):
    """3/4 偏航视角下的屏幕剪影（§8.2 长宽比就用这里的 h 量）。

    必须逐顶点投影 —— 用 AABB 八角点会把"屋面的 y"和"地面的 z"组合成
    并不存在的点，虚报高度（实测每次虚高 30~50px）。
    """
    right, up = cam_axes(yaw_deg, tilt_deg)
    pts = shape_points(ob)
    us = [p.dot(right) for p in pts]
    vs = [p.dot(up) for p in pts]
    return {"w": max(us) - min(us), "h": max(vs) - min(vs)}


def check_spec(spec, ob=None):
    """按 §8.2 自检，返回报告 dict（含 PASS/FAIL 与依据）。"""
    m = shape_bbox(ob) if ob is not None else None
    sil = silhouette(ob) if ob is not None else None
    grid_w = spec["grid_w"]
    total_h = (m["z"][1] - m["z"][0]) if m else spec["total_h"]
    sil_h = sil["h"] if sil else total_h
    ratio = sil_h / grid_w                              # §8.2 网格宽 : 剪影总高
    band = GRID_H_BAND.get(spec["width_cells"])
    door = spec.get("door")
    double = bool(spec.get("double_storey"))
    st = spec.get("storey_h") or []
    rep = {
        "grid_w": grid_w, "total_h": total_h, "sil_h": sil_h,
        "sil_w": sil["w"] if sil else grid_w,
        "ratio": ratio, "ratio_band": RATIO_BAND,
        "ratio_ok": RATIO_BAND[0] <= ratio <= RATIO_BAND[1],
        "grid_band": band,
        "grid_band_ok": (band is None) or (band[0] <= sil_h <= band[1]),
        "eave_px": spec["overhang"],
        "eave_ratio": spec["overhang"] / grid_w,
        "eave_ok": EAVE_RATIO_BAND[0] <= spec["overhang"] / grid_w <= EAVE_RATIO_BAND[1],
        "door_ok": (door is None) or (abs(door[1] - DOOR_H) < 0.5 and
                                      (spec.get("composite_door") or
                                       DOOR_W_RANGE[0] <= door[0] <= DOOR_W_RANGE[1])),
        "door_size_ok": (door is None) or (not spec.get("composite_door")) or
                        (door[0] <= 140.0),
        "min_width_ok": (door is None) or (spec["width_cells"] >= MIN_DOOR_CELLS),
        "storey_ok": (not double) or all(
            STOREY_H_BAND[0] <= s <= STOREY_H_BAND[1] for s in st),
        "double_storey": double,
        "note": ("双层（§8.2 层高 175~195 约束，长宽比仅报数）" if double else ""),
    }
    rep["pass"] = all(rep[k] for k in
                      ("ratio_ok", "grid_band_ok", "eave_ok", "door_ok",
                       "door_size_ok", "min_width_ok", "storey_ok"))
    return rep


def print_specs(objs=None):
    """打规格表（终端自检用）。"""
    head = ("def", "格", "网格宽", "剪影宽", "剪影总高", "檐口", "层高", "门(净)",
            "出檐px", "出檐%", "长宽比", "§8.2区间", "判定")
    print("\n" + " | ".join(head))
    print("-" * 150)
    rows = []
    for (name, wc) in PROBE_LIST:
        ob, spec = ASSEMBLERS[name](wc)
        rep = check_spec(spec, ob)
        rows.append((name, wc, spec, rep))
        d = spec.get("door")
        door_s = "-" if not d else "%.0fx%.0f%s" % (d[0], d[1], "*" if spec.get("composite_door") else "")
        st = "+".join("%.0f" % s for s in spec["storey_h"])
        print(" | ".join([
            "%s" % name, "%d" % wc, "%.0f" % rep["grid_w"],
            "%.0f" % rep["sil_w"], "%.0f" % rep["sil_h"],
            "%.0f" % spec["eave_h"], st, door_s,
            "%.0f" % rep["eave_px"], "%.1f%%" % (rep["eave_ratio"] * 100.0),
            "%.2f" % rep["ratio"],
            "%d~%d" % rep["grid_band"], "PASS" if rep["pass"] else "FAIL",
        ]))
        bpy.data.objects.remove(ob, do_unlink=True)
    print("(* = 复合门洞豁免，§8.3)")
    return rows


if __name__ == "__main__":
    bpy.ops.wm.read_factory_settings(use_empty=True)
    print_specs()
