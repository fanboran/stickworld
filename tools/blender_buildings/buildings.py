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
#: 相机固定俯角 20°（§0.3 视角硬约束：纯正面 + 俯角 20°）。檐口出檐会遮住墙顶
#: `出檐 × tan20°` 高的一条墙面 —— 檐下 AO 条带必须压在**这条遮挡线之下**才看得见，
#: 否则整条带都被自家屋檐挡掉（旧实现在墙顶贴 shadow_near，实测完全不可见）。
AO_TILT_TAN = math.tan(math.radians(20.0))
#: 茅草檐缘卷截面压扁比（**深 Y : 高 Z = 1 : 0.60**，落在 0.55~0.65 带内）——
#: 圆管截面改束状扁圆，正面读作"厚草檐唇"而不是一根圆棒（屋顶二轮微调 ②）。
STRAW_ROLL_SQUASH = 0.60
#: §8.2 带门建筑最小宽度（4 格档只做小物件）
MIN_DOOR_CELLS = 6
U_WIDTHS = (4, 8, 12, 16)   # 小物件以外，房屋类宽度取 4 的整数倍（4 格仅限小物件）


def eave_over(grid_w):
    """§8.2 出檐（每侧）= 建筑宽 × 20.5%，稳落 18~23% 带内。"""
    return round(grid_w * 0.205)


def bays_of(width_cells):
    """开间数：每开间最多 1 窗（§8.2 减窗口径）用得着的唯一开间定义。"""
    return max(2, int(round(width_cells / 4.0)))


# ---------------------------------------------------------------- §0.5 窗规格表
#
# 立面窗参数的**唯一真相源**（§8.7 米制：1px ≈ 1.31cm、1 格 = 32px ≈ 0.42m）：
#   窗台 69 = 0.90m；临街一层 76 = 1.00m；窗高 92~100 = 1.20~1.31m。
# 各装配器一律 `win_rect()` / `bay_openings()` 取窗，**禁止再写死 ow/oh/窗台**。
# 纪律：① 同一立面同窗型 ≤2 档（各装配器的 WIN_* 常量声明）；② 上下层必须差异化
# （下层 `street` 矮宽 → 上层 `hall` 瘦高 / 顶层加窗板 shutters）。
#
# 字段：
#   sill   窗台高（**相对所在楼层地面**；山墙/阁楼档由调用方传 floor_z=eave）
#   h      窗洞净高（92~100 取档）
#   frac   窗宽 / 开间宽（**按开间比例收窄**）；实际宽 = clamp(frac×开间, min_w, cap)
#   min_w / cap   窗宽下限 / 上限（墙垛不许被吃掉）
#   w      固定窗宽（非居室开口用，不走开间比例）
#   muntins 窗棂数 / shutters 窗板 / bars 铁栅 / mat 玻璃材质
WINDOW_SPEC = {
    # ---- 民居（走开间比例；开间 = 4 格 = 128，故 frac×128 要落在 0.80~1.00m 窗宽带内）
    "street":  dict(sill=76.0, h=96.0, frac=0.55, min_w=62.0, cap=76.0, muntins=1),
    "hall":    dict(sill=69.0, h=100.0, frac=0.50, min_w=54.0, cap=72.0, muntins=1),
    "chamber": dict(sill=69.0, h=92.0, frac=0.46, min_w=46.0, cap=62.0, muntins=1,
                    shutters=True),
    "pitch":   dict(sill=69.0, h=94.0, frac=0.52, min_w=54.0, cap=70.0, muntins=1),
    "side":    dict(sill=69.0, h=92.0, frac=0.42, min_w=46.0, cap=62.0, muntins=1),
    "garret":  dict(sill=14.0, h=30.0, frac=0.30, min_w=24.0, cap=34.0, muntins=0),
    # ---- 非居室开口（固定宽）
    "vent":    dict(sill=40.0, h=48.0, w=24.0, muntins=0, bars=True,
                    trim_sill=False),                                  # 谷仓通风窄缝
    "squint":  dict(sill=0.0, h=52.0, w=14.0, muntins=0, bars=True),    # 箭窗
    "peephole": dict(sill=0.0, h=34.0, w=26.0, muntins=0),              # 塔身小窗
    "lancet":  dict(sill=69.0, h=96.0, w=61.0, muntins=0),              # 尖拱长窗
    "belfry":  dict(sill=0.0, h=112.0, w=0.0, muntins=0),               # 钟楼开口（宽随塔宽）
}


def win_rect(kind, bay_w=None, floor_z=0.0, w_scale=1.0, h_scale=1.0, **over):
    """按窗规格表解出一扇窗：返回 dict(ow, oh, z0, z1, kind, muntins, ...)。

    bay_w 给定时窗宽 = clamp(frac × 开间宽, min_w, cap)（**按开间比例收窄**；
    上下层/逐层差异化可用 w_scale/h_scale 微调同一档，不新增窗型）；未给 bay_w 的
    档（vent/squint/peephole/lancet）用表里的固定宽 w。floor_z = 该层地面（窗台 =
    floor_z + sill）。**同一立面只许取 ≤2 档**（§9.2 立面修正纪律）。
    """
    s = dict(WINDOW_SPEC[kind])
    s.update(over)
    if "w" in s:
        ow = s["w"] * w_scale
    else:
        ow = s["frac"] * (bay_w if bay_w else s["cap"])
        ow = max(s["min_w"], min(s["cap"], ow)) * w_scale
    oh = s["h"] * h_scale
    z0 = floor_z + s["sill"]
    return {"kind": kind, "ow": round(ow, 1), "oh": round(oh, 1), "z0": z0,
            "z1": z0 + oh, "muntins": s.get("muntins", 1),
            "shutters": bool(s.get("shutters")), "bars": bool(s.get("bars")),
            "trim_sill": bool(s.get("trim_sill", True)),
            "mat": s.get("mat", "glass"), "head": s.get("head", 0.0)}


def win_holes(wins):
    """窗 dict 列表 → wall_panel/arch_wall 的洞口元组 [(cx, ow, z0, z1), ...]。"""
    return [(w["cx"], w["ow"], w["z0"], w["z1"]) for w in wins]


def put_window(b, w, u, face, axis="X", face_dir=-1.0, frame_mat="timber"):
    """按窗 dict 落一扇窗（窗参数全部来自 WINDOW_SPEC；u = 沿墙位置、face = 墙面）。"""
    kw = dict(ow=w["ow"], oh=w["oh"], z=w["z0"], mat=w["mat"], frame_mat=frame_mat,
              muntins=w["muntins"], bars=w["bars"], axis=axis, face_dir=face_dir,
              sill=w.get("trim_sill", True))
    if w.get("shutters"):
        kw.update(shutters=True, shutter_mat="wood_dark")
    if axis == "X":
        return window(b, x=u, y=face, **kw)
    return window(b, x=face, y=u, **kw)


def gable_roof_z(eave, rise, half, y, y_ridge=0.0):
    """双坡顶在给定 y 处的屋面高度（理想面；烟囱泛水/贴面定位用）。"""
    t = 1.0 - min(1.0, abs(y - y_ridge) / max(1e-6, half))
    return eave + rise * max(0.0, t)


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
    "silhouette":  ((0.22, 0.235, 0.27), 0.85, 0.0),
    "wood_door":   ((0.17, 0.11, 0.07), 0.80, 0.0),
    "wood_roof":   ((0.30, 0.19, 0.11), 0.80, 0.0),
    "ember":       ((0.50, 0.13, 0.03), 0.90, 0.0),
    # 接地阴影三级（§8.2 接地要求；纯色 PBR，不参与 materials.py 的材质家族）
    # 值必须明显深于地面（0.80/0.76/0.68），否则读成"铺在地上的浅灰板"
    "shadow_far":  ((0.44, 0.415, 0.370), 1.0, 0.0),
    "shadow_mid":  ((0.30, 0.280, 0.250), 1.0, 0.0),
    "shadow_near": ((0.20, 0.185, 0.165), 1.0, 0.0),
    # 檐下 AO 暗带（屋顶结构二轮新增）：**低对比**——对抹灰墙的压暗量 0.23
    # ≈ 既有 shadow_near 压暗量 (0.78-0.20=0.58) 的一半；比早先那版 shadow_near
    # 明显轻，不会读成"檐下贴了条黑胶带"。实测：值 ≥0.60 时在抹灰墙上反而**比墙亮**、
    # 不成暗带，故取 0.545（仍在"低对比/半暗度"口径内）。
    # 名字含 "shadow_" → shape_points() 会把它排除出剪影测量（与接地阴影同规）。
    # 深色墙（木板/砖）上的檐下暗带改用既有 shadow_mid（与墙对比更小，见 roof_gable ao_mat）。
    "shadow_ao":   ((0.545, 0.530, 0.505), 1.0, 0.0),
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

    def ellipse_prism(self, center, ry, rz, length, mat, segments=10, axis="X",
                      jitter=0.0, seed=0):
        """椭圆截面棱柱（茅草檐缘卷专用：**压扁的束状截面，不再读作圆管**）。

        ry / rz = 截面两个半轴（沿 axis 之外的另两轴）；jitter = 逐段半径抖动
        （0~0.2 → 草束的参差感；确定性 `_jit`，不用 random，跨进程逐位一致）。
        """
        c = Vector(center)
        if axis == "X":
            ax = (Vector((0.0, 1.0, 0.0)), Vector((0.0, 0.0, 1.0)), Vector((1.0, 0.0, 0.0)))
        elif axis == "Y":
            ax = (Vector((0.0, 0.0, 1.0)), Vector((1.0, 0.0, 0.0)), Vector((0.0, 1.0, 0.0)))
        else:
            ax = (Vector((1.0, 0.0, 0.0)), Vector((0.0, 1.0, 0.0)), Vector((0.0, 0.0, 1.0)))
        h = length / 2.0
        ring0, ring1 = [], []
        for i in range(segments):
            th = 2.0 * math.pi * i / segments
            k = 1.0 + jitter * _jit(i, 101 + seed)
            u, v = math.cos(th) * k, math.sin(th) * k
            ring0.append(c + ax[0] * (ry * u) + ax[1] * (rz * v) - ax[2] * h)
            ring1.append(c + ax[0] * (ry * u) + ax[1] * (rz * v) + ax[2] * h)
        for i in range(segments):
            j = (i + 1) % segments
            mid = (ring0[i] + ring0[j] + ring1[j] + ring1[i]) / 4.0
            self.poly([ring0[i], ring0[j], ring1[j], ring1[i]], mat, outward=(mid - c))
        self.poly(list(reversed(ring0)), mat, outward=(-ax[2]))
        self.poly(list(ring1), mat, outward=ax[2])

    def profile_x(self, cx, thickness, prof, mat):
        """沿 X 拉伸的多边形板：prof = YZ 平面多边形 [(y, z), ...]（逆时针，闭合）。

        用于需要**真洞口**的山墙三角（三角面按"洞口下梯形 + 左右梯形 + 上三角"
        分解，斜边仍是整条斜线，不做阶梯近似）。
        """
        x0, x1 = cx - thickness / 2.0, cx + thickness / 2.0
        n = len(prof)
        self.poly([(x0, p[0], p[1]) for p in prof], mat, outward=(-1.0, 0.0, 0.0))
        self.poly([(x1, p[0], p[1]) for p in prof], mat, outward=(1.0, 0.0, 0.0))
        for i in range(n):
            p0, p1 = prof[i], prof[(i + 1) % n]
            dy, dz = p1[0] - p0[0], p1[1] - p0[1]
            ln = math.hypot(dy, dz)
            if ln < 1e-9:
                continue
            self.poly([(x0, p0[0], p0[1]), (x0, p1[0], p1[1]),
                       (x1, p1[0], p1[1]), (x1, p0[0], p0[1])], mat,
                      outward=(0.0, dz / ln, -dy / ln))

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
    # **必须重排去重**：append 会打乱有序性 + 产生重复 → 旧实现按错乱顺序取相邻对，
    # 会出现"跨层"条带（如下一条带横跨整层高），窗口位置被切成长条通洞（二层可见
    # 天空 / 半木桁架间格透空）。见交接档 §三 第 2 项。
    zs = sorted(set(zs))
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


def _jit(i, salt=0):
    """确定性抖动 ∈ [-1,1)。**不用 random**：跨进程/跨图逐位一致（管线纪律）。"""
    v = (int(i) * 1103515245 + int(salt) * 2654435761 + 0x9E3779B9) & 0x7FFFFFFF
    return ((v >> 8) & 0xFFFF) / 32767.5 - 1.0


def _roof_family(mat):
    """屋面材质 → 结构族：檐口断面/草束做法的分档依据（材质名不变，只换几何手法）。"""
    if mat in ("thatch", "thatch_old", "reed", "straw"):
        return "thatch"
    if mat in ("tile", "slate", "shingle"):
        return "tile"
    return "wood"


def roof_gable(b, w, span, rise, overhang, mat, x=0.0, y=0.0, z=0.0,
               thickness=9.0, mat_under=None, gable_overhang=None, ridge_cap=True,
               cap_mat=None, cap_size=(0, 0), eave_board=True, board_mat=None,
               board_h=0.0, slope_uv=True, uv_swap=False, eave_ao=True,
               rafter_ends=3, eave_section=True, straw_eave=True, straw_ridge=True,
               ao_faces=None, ao_mat=None, ao_h=0.0, purlin_ext=(6.0, 14.0)):
    """双坡屋顶（屋脊沿 X，正面朝 -Y，相机侧看到整片前坡）。

    w        = 屋脊方向覆盖的建筑宽度（X，不含出檐）
    span     = 坡面跨越的建筑进深（Y，不含出檐）
    rise     = 屋脊相对檐口高度（越大坡越陡、正面可见屋面越大）
    overhang = 出檐（§8.2：每侧 = 建筑宽 × 18~23%）
    z        = 檐口高度（= 墙顶）
    返回 dict：檐口/屋脊高、坡长、坡度角。

    屋顶结构二轮（全部为**纯几何**，默认开启、参数可关；不引贴图、不碰材质库既有条目）：
    ① `eave_section` 檐口可见厚度断面——草顶做**压扁的束状草檐卷**（椭圆截面，
       深:高 = 1 : 0.60，不再是圆管）；瓦/木顶做 6~10 高**封檐板** + 一排**瓦口/瓦条
       断面（凸出板 4~6，长短抖动）。
    ② `eave_ao` 檐下 AO 暗带——贴墙窄几何条带（高 10~16、凸出墙 4.5），低对比；
       `ao_faces` 给出两面墙的实际外皮 y（有悬挑楼层的房子必须显式传，否则条带浮空）；
       `ao_mat` 可换材质（深色木墙用 shadow_mid，浅灰墙用 shadow_ao）。
    ③ `rafter_ends` 山墙檩条端头——每端左右坡各一排（2~4 根），出挑 6~14 + 长度抖动，
       贴檐口布置、顶面贴屋面下皮、底端下探到出檐遮挡线以下 → **正面 20° 俯视可见**
       （旧实现埋在 f 0.22~0.72 处，被自家出檐整条挡死）；草顶出挑收敛到 60%。
    ④ `straw_eave`/`straw_ridge` 茅草檐口草束（沿两道檐缘悬垂、微下垂梳齿感，straw 材质）
       + 屋脊草穗（仅在 ridge_cap 时）；瓦/木顶不做此项。
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
    fam = _roof_family(mat)
    fmat = board_mat or mat_under or "wood_dark"
    roll_r = min(9.0, max(6.0, thickness * 0.35))    # 草檐卷半径（板厚的圆角唇，不喧宾夺主）
    cap_h = (cap_size[1] if cap_size and cap_size[1] else max(8.0, thickness * 0.55))
    if ridge_cap:
        cw = (cap_size[0] if cap_size and cap_size[0] else 26.0)
        # 正脊压顶条：默认取深色（瓦/石顶用石脊、草/木顶用木脊）→ 正脊可读，不抬剪影
        b.box_bottom((ridge_len + 2.0, cw, cap_h), (x, y), z + rise - cap_h * 0.35,
                     cap_mat or ("stone_dark" if fam == "tile" else "wood_dark"))
    # ---- ① 檐口可见厚度断面 ------------------------------------------------
    if eave_section:
        if fam == "thatch":
            # 檐缘卷：**压扁的束状截面**（深:高 = 1 : STRAW_ROLL_SQUASH），不再读作圆管；
            # 逐段半径微抖 → 草束的参差感（确定性 _jit，不引 random）。下缘与旧圆管齐平。
            for sign in (-1.0, 1.0):
                b.ellipse_prism((x, y + sign * (half + 1.0), z - roll_r * 0.70),
                                roll_r, roll_r * STRAW_ROLL_SQUASH, ridge_len - 4.0,
                                mat, segments=9, axis="X", jitter=0.10,
                                seed=int(sign < 0.0))
        else:
            bh = min(10.0, max(6.0, board_h if board_h else 8.5))
            for sign in (-1.0, 1.0):
                ey = y + sign * half
                # 封檐板：竖直板条（6~10 高），坡度角下读到"檐口有厚度"
                b.box_bottom((ridge_len - 1.0, 9.0, bh), (x, ey + sign * 1.0),
                             z - bh * 0.62, fmat)
                # 瓦口/瓦条断面：一排瓦端（凸出封檐板 4~6、长短与高度抖动）
                n = max(6, min(44, int(round(ridge_len / 15.0))))
                for i in range(n):
                    u = -ridge_len / 2.0 + ridge_len * (i + 0.5) / n
                    sa_ = int(sign)
                    bw_ = 12.5 + 2.5 * _jit(i, 41 + sa_)
                    dp_ = 15.0 + 3.5 * _jit(i, 73 + sa_)
                    hh_ = 7.0 + 1.6 * _jit(i, 97 + sa_)
                    b.box_bottom((bw_, dp_, hh_), (x + u, ey + sign * 2.5),
                                 z - 1.0 + 1.3 * _jit(i, 131 + sa_),
                                 mat if fam == "tile" else fmat)
    elif eave_board:                                # 旧行为退路（eave_section=False）
        bh = board_h if board_h else max(7.0, thickness * 0.42)
        for sign in (-1.0, 1.0):
            b.box_bottom((ridge_len + 1.0, 9.0, bh), (x, y + sign * (half - 2.0)),
                         z - bh * 0.55, fmat)
    # ---- ② 檐下 AO 暗带（贴墙窄条带；几何实现，非贴图） ---------------------
    # 位置：顶面压到"出檐遮挡线"之下（z - 出檐×tan20° - 2），高度 10~14；
    # 凸出墙面仅 3（小于木骨 4）→ 木骨会遮住它，暗带读作"木骨后的阴影"而不是贴条。
    if eave_ao:
        ah = ao_h if ao_h > 0.0 else max(10.0, min(14.0, 7.0 + rise * 0.06))
        fys = ao_faces or (y - span / 2.0, y + span / 2.0)
        top = z - overhang * AO_TILT_TAN - 2.0
        for k, fy in enumerate(fys):
            if fy is None:
                continue
            sign = -1.0 if k == 0 else 1.0            # 0 = 正面（-Y 外皮），1 = 背面
            # 宽度收到建筑宽（不越墙角），暗带只在墙面正下方
            b.box_bottom((min(ridge_len, w + 2.0), 9.0, ah), (x, fy - sign * 1.5),
                         top - ah, ao_mat or "shadow_ao")
    # ---- ①b 山墙封山板（盖住屋面板在山墙端的"切面"，同时加一道顺坡厚度线） ----
    if eave_section:
        for sx in (-1.0, 1.0):
            for sign in (-1.0, 1.0):
                rotx = -sign * ang
                u_ax = Vector((0.0, math.cos(rotx), math.sin(rotx)))
                n_ax = Vector((0.0, -math.sin(rotx), math.cos(rotx)))
                b.box_oriented(Vector((x + sx * (ridge_len / 2.0 - 7.0),
                                       y + sign * half / 2.0,
                                       z + rise / 2.0)),
                               (Vector((1.0, 0.0, 0.0)), u_ax, n_ax),
                               (6.5, slope / 2.0 - 2.0, thickness / 2.0 + 1.5),
                               mat if fam == "thatch" else fmat)
    # ---- ③ 山墙檩条端头（每端左右坡各一排；出挑 6~14 + 长度抖动） -----------
    #  屋顶二轮微调 ①：旧实现把檩端埋在屋面下（f 0.22~0.72），正面 20° 俯视被自家
    #  出檐整个挡死。改为**贴檐口一小段**（f 0.05~0.14）+ 顶面贴屋面下皮、底端下探到
    #  "出檐遮挡线"（檐口下 tan20°×Δ）以下 ≥12 → 正面俯视一定露得出来。
    if rafter_ends:
        n_r = max(1, min(4, int(rafter_ends)))
        lo, hi = purlin_ext
        for sx in (-1.0, 1.0):
            for sign in (-1.0, 1.0):
                sal = int(sx * 3 + sign * 7)
                for i in range(n_r):
                    f = 0.05 + 0.09 * (i / float(max(1, n_r - 1)))
                    ext = lo + (hi - lo) * (0.5 + 0.5 * _jit(i, 11 + sal))
                    if fam == "thatch":             # 草檐半掩：出挑收敛
                        ext *= 0.6
                    ln = 12.0 + ext
                    yc = y + sign * (half * (1.0 - f))
                    ztop = z + rise * f - ca * thickness * 0.5 + 1.0      # 贴屋面下皮
                    zocc = z - AO_TILT_TAN * (half * f) - ca * thickness * 0.5
                    zbot = min(zocc - 12.0, ztop - 10.0)                  # 露在遮挡线下
                    xc = x + sx * (w / 2.0 + ext - ln / 2.0)
                    b.box_bottom((ln, 10.0, ztop - zbot), (xc, yc), zbot, fmat)
    # ---- ④ 茅草檐口草束 + 脊部草穗（仅草顶；瓦/木顶不做） --------------------
    if straw_eave and fam == "thatch":
        n_b = max(8, min(40, int(round(ridge_len / 12.0))))
        ax0 = Vector((1.0, 0.0, 0.0))
        for sign in (-1.0, 1.0):
            ey = y + sign * half
            for i in range(n_b):
                u = -ridge_len / 2.0 + ridge_len * (i + 0.5) / n_b
                j0, j1, j2 = _jit(i, 5), _jit(i, 17), _jit(i, 29)
                bw_ = 5.5 + 1.5 * j0                 # 草束宽 4~7
                ln_ = 14.0 + 6.0 * j1                # 长度抖动
                bt_ = 4.5 + 1.2 * j2
                tilt = 0.20 + 0.16 * (0.5 + 0.5 * j0)   # 微下垂外倾（梳齿感）
                d = Vector((0.0, sign * math.sin(tilt), -math.cos(tilt)))
                # 束根挂在草檐卷的外侧（inside 会被卷体吞掉 → 草束读不出来）
                c = (Vector((x + u, ey + sign * (roll_r * 0.55), z + 1.0))
                     + d * (ln_ * 0.5))
                b.box_oriented(c, (ax0, d, ax0.cross(d).normalized()),
                               (bw_ / 2.0, ln_ / 2.0, bt_ / 2.0), "straw")
    if straw_ridge and ridge_cap and fam == "thatch":
        n_s = max(6, min(26, int(round(ridge_len / 18.0))))
        top_z = z + rise - cap_h * 0.35 + cap_h
        cap_half = (cap_size[0] if cap_size and cap_size[0] else 26.0) * 0.5
        ax0 = Vector((1.0, 0.0, 0.0))
        for sgn in (-1.0, 1.0):
            for i in range(n_s):
                u = -ridge_len / 2.0 + ridge_len * (i + 0.5) / n_s
                j0, j1 = _jit(i, 61), _jit(i, 83)
                ln_ = 13.0 + 6.0 * j0
                tilt = 0.55 + 0.20 * (0.5 + 0.5 * j1)
                d = Vector((0.0, sgn * math.sin(tilt), -math.cos(tilt)))
                # 束根落在压顶条**外肩**上（±0.62·半宽）→ 草穗披在脊两侧、正面可见
                c = (Vector((x + u, y + sgn * cap_half * 0.62, top_z - 1.0))
                     + d * (ln_ * 0.5))
                b.box_oriented(c, (ax0, d, ax0.cross(d).normalized()),
                               (4.2, ln_ / 2.0, 3.4), "straw")
    return {"ridge_len": ridge_len, "half_span": half, "slope_len": slope,
            "angle_deg": math.degrees(ang), "eave_z": z, "ridge_z": z + rise}


def gable_infill(b, w, span, rise, mat, z=0.0, thickness=12.0, y=0.0, hole=None):
    """两端山墙三角填充（屋脊沿 X 时，山墙在左右两侧）。

    hole=(u, ow, z0, z1)：可选**真窗洞**（u = 窗心绝对 y、ow = 窗宽、z 绝对高度）。
    有洞时三角面按"洞口下梯形 + 洞口左右梯形 + 洞口上三角"分解，斜边仍是整条直线
    （不做阶梯近似），窗洞是真洞、能看见窗框凹进 —— 上层补墙后按窗表开的小窗走这里。
    """
    yh = span / 2.0
    for sx in (-1.0, 1.0):
        cx = sx * (w / 2.0 - thickness / 2.0)
        if hole is None:
            b.profile_x(cx, thickness, [(y - yh, z), (y + yh, z), (y, z + rise)], mat)
            continue

        def hw(zz):
            return max(0.0, yh * (1.0 - (zz - z) / rise))

        u, ow, z0, z1 = hole
        h0, h1 = u - ow / 2.0, u + ow / 2.0
        z0 = min(max(z0, z + 1.0), z + rise - 1.0)
        z1 = min(max(z1, z0 + 1.0), z + rise - 1.0)
        w0, w1 = hw(z0), hw(z1)
        # 洞口下梯形
        b.profile_x(cx, thickness,
                    [(y - yh, z), (y + yh, z), (y + w0, z0), (y - w0, z0)], mat)
        # 洞口两侧（贴洞口边的竖直边 + 三角斜边）
        if h0 > y - w1:
            b.profile_x(cx, thickness,
                        [(y - w0, z0), (h0, z0), (h0, z1), (y - w1, z1)], mat)
        if h1 < y + w1:
            b.profile_x(cx, thickness,
                        [(h1, z0), (y + w0, z0), (y + w1, z1), (h1, z1)], mat)
        # 洞口上三角
        b.profile_x(cx, thickness,
                    [(y - w1, z1), (y + w1, z1), (y, z + rise)], mat)
    return {"rise": rise, "thickness": thickness, "hole": hole}


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


def _roof_flash(b, x, y, w, d, roof_z, up=15.0, out=13.0, mat="slate"):
    """穿屋面**泛水裙**：上口贴柱身、下口外扩并**顺坡下探落到屋面**（全几何不贴图）。

    上口收到 `roof_z + up`（铅皮上返高度），下口外扩 `out`、落到 `roof_z - out*0.55`
    → 裙边不悬空、烟囱与屋面的接缝被盖住；下口再压一道深色灰泥搭接台（stone_dark），
    不读成"白托盘"。
    """
    hw, hd = w / 2.0, d / 2.0

    def ring(o, zz):
        return [(x - hw - o, y - hd - o, zz), (x + hw + o, y - hd - o, zz),
                (x + hw + o, y + hd + o, zz), (x - hw - o, y + hd + o, zz)]

    zb = roof_z - out * 0.55
    rings = [ring(2.0, roof_z + up), ring(2.0 + out, zb)]
    outs = ((0.0, -1.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (-1.0, 0.0, 0.0))
    for k in range(len(rings) - 1):
        for i in range(4):
            j = (i + 1) % 4
            n = outs[i]
            b.poly([rings[k][i], rings[k][j], rings[k + 1][j], rings[k + 1][i]], mat,
                   outward=(n[0], n[1], 0.35))
    # 灰泥搭接台（铅皮下口的找平层，深色、比铅皮外扩 3）
    b.box_bottom((w + 2.0 * (out + 3.0), d + 2.0 * (out + 3.0), 6.0), (x, y),
                 zb - 6.0, "stone_dark")
    b.box_bottom((w + 4.0, d + 4.0, 5.0), (x, y), roof_z + up - 1.0, mat)
    return {"zb": zb, "zt": roof_z + up}


def chimney(b, w=26.0, d=26.0, top=60.0, mat="stone_dark", x=0.0, y=0.0, foot=0.0,
            cap_mat=None, cap=10.0, flue=False, roof=None, flash_up=18.0,
            flash_out=0.0, flash_mat="slate", skirt_h=22.0, skirt_lip=9.0):
    """烟囱：**落地**柱身（`foot` 起砌）+ 基座石裙 + 压顶 + 穿屋面泛水裙。

    与旧口径的差别（不许再"悬空起始于屋面"）：
    * 柱身从 `foot`（默认 0 = 地面）连续砌到 `top`（柱身顶，压顶另算），中途不中断；
    * `foot` 处两阶**基座石裙**（外扩 `skirt_lip`，烟囱根部的防水台）；
    * `roof` 给定（= 该处屋面高，用 `gable_roof_z()` 算）时在穿屋面处加**泛水裙**
      （见 `_roof_flash`）；屋脊以下、檐口以上都能穿。
    """
    h = max(1.0, top - foot)
    b.box_bottom((w, d, h), (x, y), foot, mat)
    # 基座石裙（两阶：下阶更宽更矮，上阶收窄）——烟囱根部落到地面/勒脚上
    b.box_bottom((w + 2.0 * skirt_lip, d + 2.0 * skirt_lip, skirt_h), (x, y), foot,
                 "stone")
    b.box_bottom((w + 1.1 * skirt_lip, d + 1.1 * skirt_lip, skirt_h * 0.55), (x, y),
                 foot + skirt_h, "stone_dark")
    if roof is not None:
        _roof_flash(b, x, y, w, d, roof, up=flash_up,
                    out=flash_out if flash_out > 0.0 else max(12.0, w * 0.44),
                    mat=flash_mat)
    cap_mat = cap_mat or mat
    b.box_bottom((w + 12.0, d + 12.0, cap), (x, y), top, cap_mat)
    if flue:
        b.cylinder((x, y, top + cap + 6.0), min(w, d) * 0.36, 12.0, "iron", segments=12)
    return {"h": h, "w": w, "top": top + cap, "foot": foot, "roof": roof}


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
    # 最外圈外扩 ≤ 建筑宽的 12%（再大就读成"铺在地上的灰毯"而不是接触阴影）
    cap = min(0.12 * max(w, d), spread * 1.4)
    for i in range(steps):
        k = float(i) / float(max(1, steps - 1))
        sp = 0.28 * cap + 0.72 * cap * k
        h = max(0.9, 2.2 - 0.65 * i)                 # 越外圈越薄 → 读作阴影而非台阶
        b.box_bottom((w + 2.0 * sp, d + 2.0 * sp, h), (x, y), 0.0,
                     mats[i] if i < len(mats) else "shadow_far")
    return {"spread": spread, "cap": cap}


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


def bay_openings(W, bays, kind="street", door_w=None, door_bay=0, door_x=None,
                 floor_z=0.0, w_scale=1.0, h_scale=1.0, skip=(), **over):
    """按开间布窗（§8.2「每开间最多 1 窗」）——**窗参数一律取自 WINDOW_SPEC**。

    带门时门占 door_bay 一个开间，其余开间各排 1 扇窗（`skip` 里的开间号跳过，用于
    "顶层只开 0/2 开间"这类逐层差异化）。返回 (门中心 x | None, [窗 dict, ...])，
    窗 dict 由 win_rect 给出并带上 "cx"（可配合 win_holes()/put_window() 直接落几何）。
    """
    cs = bay_centers(W, bays)
    bw = W / float(bays)
    wins = []
    for i, cx in enumerate(cs):
        if door_w is not None and i == door_bay:
            continue
        if i in skip:
            continue
        w = win_rect(kind, bay_w=bw, floor_z=floor_z, w_scale=w_scale,
                     h_scale=h_scale, **over)
        w["cx"] = cx
        wins.append(w)
    if door_w is None:
        return None, wins
    dx = cs[door_bay] if door_x is None else door_x
    return dx, wins


#: def × 宽度档的最终定尺（§8.2 长宽比口径倒推，全部数字集中在此，方便复核）
#: 剪影总高 = 檐口 + rise + 屋面厚度余弦增量 + 接地细节；6 格档受"门 150 + 楣梁"
#: 与"剪影 ≤1.5×宽"双向挤压，屋面只能给到 ~76，见报告里的算术说明。
HOUSE_TIERS = {
    8:  dict(D=150.0, plinth=14.0, wall=205.0, rise=112.0, door_w=52.0, wt=18.0),
    12: dict(D=200.0, plinth=18.0, wall=208.0, rise=115.0, door_w=56.0, wt=20.0),
    16: dict(D=240.0, plinth=20.0, wall=210.0, rise=118.0, door_w=58.0, wt=22.0),
}
TOWNHOUSE_TIERS = {
    12: dict(D=208.0, plinth=18.0, storey=205.0, rise=140.0, door_w=56.0,
             wt=20.0, jetty=10.0),
    16: dict(D=240.0, plinth=20.0, storey=205.0, rise=150.0, door_w=58.0,
             wt=20.0, jetty=10.0),
}
BARN_TIERS = {
    8:  dict(D=170.0, plinth=12.0, wall=200.0, rise=118.0, wt=20.0, leaf=58.0),
    12: dict(D=200.0, plinth=14.0, wall=205.0, rise=124.0, wt=22.0, leaf=62.0),
    16: dict(D=224.0, plinth=16.0, wall=210.0, rise=128.0, wt=22.0, leaf=62.0),
}
SMITHY1_TIERS = {
    6: dict(D=144.0, post_h=200.0, rise=110.0, post=16.0, roof_t=18.0),
    8: dict(D=176.0, post_h=205.0, rise=115.0, post=16.0, roof_t=20.0),
}

#: 各装配器声明的窗型（**同一立面同窗型 ≤2 种**，§9.2 立面修正纪律）。
#: 单层民居：正面 1 档 + 侧墙 1 档 + 山墙阁楼窗 1 档（分属三个立面，各自只有 1 档）。
WIN_FRONT = "pitch"      # house 正面（单层民居档）
WIN_SIDE = "side"        # house/侧墙（+ 窗板差异）
WIN_GABLE = "garret"     # 山墙阁楼小窗（真洞，走 gable_infill hole）
#: 街屋/联排：**下层矮宽（street）+ 上层瘦高（hall）**，逐层只用这 2 档
WIN_LOW = "street"       # 临街一层（窗台 76 / 窗高 96 / 宽 0.46 开间）
WIN_UP = "hall"          # 上层（窗台 69 / 窗高 100 / 宽 0.40 开间）
WIN_TOP = "hall"         # 顶层：同一档收窄 + 加窗板（不新增窗型）


def assemble_house(width_cells=8):
    """民居：单层，抹灰 + 木骨墙 / 茅草顶。

    §8.2 口径：带门建筑最小 6 格（4 格档取消）；开间 = 格数/4（6→2、8→2、12→3），
    每开间最多 1 个洞口（门占 1 个开间），侧墙最多 1 窗；出檐 = 宽 × 20.5%。
    窗一律走窗规格表：正面 `WIN_FRONT`（单层民居档，窗台 69 / 窗高 94）、侧墙
    `WIN_SIDE`（同立面只有 1 档）、山墙 `WIN_GABLE`（阁楼小窗，真洞）。
    """
    t = HOUSE_TIERS[width_cells]
    W = width_cells * CELL
    D = t["D"]
    plinth_h, wall_h, rise, wt, door_w = t["plinth"], t["wall"], t["rise"], t["wt"], t["door_w"]
    over = eave_over(W)
    eave = plinth_h + wall_h
    yf = -D / 2.0
    bays = bays_of(width_cells)
    dx, wins = bay_openings(W, bays, WIN_FRONT, door_w=door_w, door_bay=0,
                            floor_z=plinth_h)
    side_w = win_rect(WIN_SIDE, bay_w=D, floor_z=plinth_h, shutters=True)
    side_w["u"] = -D * 0.20
    gable_w = win_rect(WIN_GABLE, bay_w=D * 0.5, floor_z=eave)
    gable_w["u"] = -D * 0.14

    b = Builder("house_w%d" % width_cells)
    contact_shadow(b, W, D, spread=26.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(dx - door_w / 2.0 - 6.0, dx + door_w / 2.0 + 6.0))
    room_shell(b, W, D, plinth_h, wall_h, wt, "plaster",
               front_openings=[(dx, door_w, DOOR_SILL, DOOR_SILL + DOOR_H)] + win_holes(wins),
               side_openings=[(side_w["u"], side_w["ow"], side_w["z0"], side_w["z1"])])
    timber_frame(b, W, wall_h, "timber", (0.0, yf), plinth_h, depth=7.0,
                 post=13.0, top_band=18.0, bays=bays, braces=True,
                 openings=[(dx, door_w)] + [(w["cx"], w["ow"]) for w in wins])
    door(b, h=DOOR_H, w=door_w, mat="wood_dark", x=dx, y=yf, z=DOOR_SILL,
         frame_mat="timber", planks=3)
    step_stone(b, w=door_w + 30.0, depth=24.0, h=9.0, x=dx, y=yf - 17.0, z=0.0)
    for w in wins:
        put_window(b, w, w["cx"], yf, frame_mat="timber")
    put_window(b, side_w, side_w["u"], W / 2.0, axis="Y", face_dir=1.0,
               frame_mat="timber")
    roof_gable(b, W, D, rise, over, "thatch", z=eave, thickness=18.0,
               mat_under="wood_dark", cap_size=(34.0, 14.0), board_h=10.0)
    gable_infill(b, W, D, rise, "plaster", z=eave, thickness=14.0,
                 hole=(gable_w["u"], gable_w["ow"], gable_w["z0"], gable_w["z1"]))
    for sx in (-1.0, 1.0):                       # 山墙木骨（两端，落在三角面内）
        gable_timber(b, D, rise, "timber", (sx * (W / 2.0), 0.0), eave,
                     axis="Y", face_dir=sx, thick=11.0)
        put_window(b, gable_w, gable_w["u"], sx * (W / 2.0), axis="Y", face_dir=sx,
                   frame_mat="timber")
    # 烟囱：落地（foot=0）+ 穿前坡屋面处泛水裙；柱顶压到屋脊下（不抬剪影）
    ch_y = -D * 0.30
    ch_top = eave + rise - 12.0
    chimney(b, 26.0, 26.0, ch_top, "stone_dark", -W * 0.26, ch_y, foot=0.0,
            cap_mat="white_stone", cap=10.0,
            roof=gable_roof_z(eave, rise, D / 2.0 + over, ch_y))

    ob = b.to_object()
    spec = _mk("house", width_cells, {
        "depth": D, "plinth_h": plinth_h, "wall_h": wall_h, "eave_h": eave,
        "rise": rise, "total_h": eave + rise, "overhang": over, "roof_t": 18.0,
        "storey_h": [wall_h], "door": (door_w, DOOR_H), "door_x": dx,
        "bays": bays, "side_windows": 1, "window": (wins[0]["ow"], wins[0]["oh"],
                                                    wins[0]["z0"] - plinth_h),
        "gable_window": (gable_w["ow"], gable_w["oh"], gable_w["u"],
                          gable_w["z0"]),
        "chimneys": [{"x": -W * 0.26, "y": ch_y,
                      "roof": gable_roof_z(eave, rise, D / 2.0 + over, ch_y),
                      "top": ch_top + 10.0, "foot": 0.0, "w": 26.0, "d": 26.0}],
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
    # 立面窗：一层 WIN_LOW（矮宽）→ 二层 WIN_UP（瘦高）——同立面 2 档，上下差异化
    # （二层不加窗板：正立面要留出烟囱腔位，且窗板会把半木立面读成"整片深木"）
    dx, wins1 = bay_openings(W, bays, WIN_LOW, door_w=door_w, door_bay=0,
                             floor_z=plinth_h)
    cs = bay_centers(W, bays)
    bw = W / float(bays)
    _dz, wins2 = bay_openings(W, bays, WIN_UP, floor_z=z2)
    side_w = win_rect(WIN_SIDE, bay_w=D, floor_z=plinth_h, shutters=True)
    side_w["u"] = -D * 0.20

    b = Builder("townhouse_w%d" % width_cells)
    contact_shadow(b, W, D + jetty, spread=30.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(dx - door_w / 2.0 - 6.0, dx + door_w / 2.0 + 6.0))
    # ---- 一层
    room_shell(b, W, D, plinth_h, sh, wt, "plaster",
               front_openings=[(dx, door_w, DOOR_SILL, DOOR_SILL + DOOR_H)] + win_holes(wins1),
               side_openings=[(side_w["u"], side_w["ow"], side_w["z0"], side_w["z1"])])
    timber_frame(b, W, sh, "timber", (0.0, yf1), plinth_h, depth=7.0, post=14.0,
                 top_band=18.0, bays=bays, braces=True,
                 openings=[(dx, door_w)] + [(w["cx"], w["ow"]) for w in wins1])
    door(b, w=door_w, mat="wood_door", x=dx, y=yf1, z=DOOR_SILL, planks=4)
    step_stone(b, w=door_w + 34.0, depth=26.0, h=10.0, x=dx, y=yf1 - 18.0)
    for w in wins1:
        put_window(b, w, w["cx"], yf1)
    put_window(b, side_w, side_w["u"], W / 2.0, axis="Y", face_dir=1.0)
    # ---- 二层（前墙外挑 jetty；侧墙仍与一层齐平，不越 4 格模数）
    wall_panel(b, W, sh, D + jetty, "plaster", 0.0, yc2, z2,
               openings=win_holes(wins2))
    for i in range(5):                               # 悬挑托梁
        px = -W / 2.0 + 14.0 + (W - 28.0) * i / 4.0
        b.box_bottom((14.0, 18.0, 14.0), (px, yf2 + 9.0), z2 - 14.0, "timber")
    b.box_bottom((W + 6.0, 8.0, 16.0), (0.0, yf2), z2 - 16.0, "timber")
    timber_frame(b, W, sh, "timber", (0.0, yf2), z2, depth=7.0, post=14.0,
                 top_band=14.0, bays=bays, braces=True,
                 openings=[(w["cx"], w["ow"]) for w in wins2])
    for w in wins2:                                  # 二层按开间数排窗（瘦高 + 窗板）
        put_window(b, w, w["cx"], yf2)
    # ---- 屋顶（檐下 AO 条带必须贴到"二层前墙外皮 yf2 / 后墙外皮 yb"，
    #      屋面以 y=0 为中心、墙体因悬挑偏前，不显式给面就会浮空）
    roof_gable(b, W, D + jetty, rise, over, "tile", z=eave, thickness=14.0,
               mat_under="wood_dark", cap_size=(28.0, 16.0), board_h=9.0,
               ao_faces=(yf2, yb))
    gable_w = win_rect(WIN_GABLE, bay_w=(D + jetty) * 0.5, floor_z=eave)
    gable_w["u"] = -D * 0.14
    gable_infill(b, W, D + jetty, rise, "plaster", z=eave, thickness=14.0,
                 hole=(gable_w["u"], gable_w["ow"], gable_w["z0"], gable_w["z1"]))
    for sx in (-1.0, 1.0):
        gable_timber(b, D + jetty, rise, "timber", (sx * (W / 2.0), yc2),
                     eave, axis="Y", face_dir=sx, thick=11.0)
        put_window(b, gable_w, gable_w["u"], sx * (W / 2.0), axis="Y", face_dir=sx)
    # 烟囱：**正立面落地烟囱**（贴二层前墙外皮，从地面砌到屋脊下）——
    # 游戏内正面视角唯一能一路看到根部的地方（山墙/屋脊后的烟囱会被自家墙体挡死）。
    # x 取"门所在开间与下一开间的分界" → 正好落在门与首窗之间的墙垛上，不压门洞/窗洞。
    ch_x = cs[0] + bw / 2.0
    ch_y = yf2 - 13.0
    ch_top = eave + rise - 2.0          # 压顶顶面正好落到屋脊高（沿用旧口径，不抬剪影）
    chimney(b, 30.0, 26.0, ch_top, "brick", ch_x, ch_y, foot=0.0,
            cap_mat="stone_dark", cap=12.0,
            roof=gable_roof_z(eave, rise, (D + jetty) / 2.0 + over, ch_y))

    ob = b.to_object()
    spec = _mk("townhouse", width_cells, {
        "depth": D + jetty, "plinth_h": plinth_h, "wall_h": sh * 2.0, "eave_h": eave,
        "rise": rise, "total_h": eave + rise, "overhang": over, "roof_t": 14.0,
        "storey_h": [sh, sh], "door": (door_w, DOOR_H), "door_x": dx, "jetty": jetty,
        "bays": bays, "double_storey": True,
        "window": (wins1[0]["ow"], wins1[0]["oh"], wins1[0]["z0"] - plinth_h),
        "window_up": (wins2[0]["ow"], wins2[0]["oh"], wins2[0]["z0"] - z2),
        "gable_window": (gable_w["ow"], gable_w["oh"], gable_w["u"],
                          gable_w["z0"]),
        "chimneys": [{"x": ch_x, "y": ch_y,
                      "roof": gable_roof_z(eave, rise, (D + jetty) / 2.0 + over, ch_y),
                      "top": ch_top + 12.0, "foot": 0.0,
                      "w": 30.0, "d": 26.0}],
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
    vent = win_rect("vent", floor_z=plinth_h)
    vents = [dict(vent, cx=-W * 0.36), dict(vent, cx=W * 0.36)]

    b = Builder("barn_w%d" % width_cells)
    contact_shadow(b, W, D, spread=28.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(-opening_w / 2.0 - 6.0, opening_w / 2.0 + 6.0))
    room_shell(b, W, D, plinth_h, wall_h, wt, "wood",
               front_openings=[(0.0, opening_w, DOOR_SILL, DOOR_SILL + DOOR_H)]
                              + win_holes(vents))
    # 双扇大门（各 1 扇，落在 45~60 内；合宽为复合洞口）
    for i, sx in enumerate((-1.0, 1.0)):
        door(b, h=DOOR_H, w=leaf_w, mat="wood_door",
             x=sx * (leaf_w / 2.0 + gap / 2.0), y=yf, z=DOOR_SILL,
             frame_mat="wood_dark", frame=8.0, planks=3, iron=True)
    b.box_bottom((10.0, 10.0, DOOR_H), (0.0, yf), DOOR_SILL, "wood_dark")   # 中缝压条
    b.box_bottom((opening_w + 40.0, 14.0, 16.0), (0.0, yf), DOOR_SILL + DOOR_H + 8.0,
                 "wood_dark")
    step_stone(b, w=opening_w + 40.0, depth=30.0, h=10.0, x=0.0, y=yf - 20.0)
    for w in vents:                                   # 通风窄缝（铁栅，不做窗棂）
        put_window(b, w, w["cx"], yf, frame_mat="wood_dark")
    for sx in (-1.0, 1.0):                            # 角部斜撑（只在上半墙）
        strut(b, (sx * (W / 2.0 - 10.0), yf, eave - 78.0),
              (sx * (W / 2.0 - 64.0), yf, eave - 10.0), 11.0, "wood_dark")
    roof_gable(b, W, D, rise, over, "wood_roof", z=eave, thickness=16.0,
               mat_under="wood_dark", cap_size=(32.0, 14.0), cap_mat="wood_dark",
               board_h=12.0, uv_swap=True, ao_mat="shadow_mid")   # 深色木板墙：AO 取更深档
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
               board_mat="wood_dark", board_h=9.0, eave_ao=False)   # 开放棚：无墙可挂 AO
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
              ("barn", 12), ("smithy1", 8)]  # 新特殊单体由此 agent 在末尾追加


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
    sb = spec.get("storey_band") or STOREY_H_BAND   # 新 def 可按 def 覆盖层高带
    rband = spec.get("ratio_band") or RATIO_BAND    # 新 def 可自声明分层口径（§8.7）
    rep = {
        "grid_w": grid_w, "total_h": total_h, "sil_h": sil_h,
        "sil_w": sil["w"] if sil else grid_w,
        "ratio": ratio, "ratio_band": rband,
        "ratio_ok": rband[0] <= ratio <= rband[1],
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
        "storey_ok": (not double) or all(sb[0] <= s <= sb[1] for s in st),
        "double_storey": double,
        "note": ("双层（§8.2 层高 175~195 约束，长宽比仅报数）" if double else ""),
    }
    # ---- 特殊单体（塔/城防/锥顶）的类型化豁免：只认 spec 里的显式字段
    exempt = []
    if spec.get("ratio_exempt"):
        rep["ratio_ok"] = rep["grid_band_ok"] = True
        exempt.append("ratio")
    elif spec.get("ratio_band"):
        rep["grid_band_ok"] = True         # 自声明分层口径（§8.7）取代旧档位表
    if spec.get("eave_exempt"):
        rep["eave_ok"] = True
        exempt.append("eave")
    if spec.get("width_exempt"):
        rep["min_width_ok"] = True
        exempt.append("min_width")
    rep["exempt"] = exempt
    rep["reason"] = spec.get("reason", "")
    if exempt:
        print("[exempt] %s w%s: %s（豁免 %s）"
              % (spec.get("def"), spec.get("width_cells"), rep["reason"] or "-",
                 "+".join(exempt)))
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


# ================================================================ §6 特殊单体（本轮新增）
#
# 新增 6 个 def：三层联排 / 风车磨坊 / 大教堂 / 瞭望塔 / 城门楼 / 灯塔。
# 口径（§8.7 米制）：1px ≈ 1.31cm、1 格(32px) ≈ 0.42m、1m ≈ 76.5px
#   * 门 150（保持）÷ 层高 205 = 73%（门不贴天花板）；单层檐高 200~207
#   * 两层檐高 ≈ 410；三层檐高 ≈ 615；屋顶 rise ≈ 层高 × 0.5 ≈ 100~120（压扁）
#   * 窗台 69（临街一层 76）、窗高 92~100（≈层高 45%）、窗宽 61~76
#   * 长宽比：单层 1:0.6~1.15、多层 1:1.2~1.6；竖向体量/塔类显式豁免并写明理由
# 既有 HOUSE/TOWNHOUSE/BARN/SMITHY1 参数表与 PROBE_LIST 既有条目一律不改（主会话在役）。

PX_PER_M = STICKMAN_H / 1.70          # 130px ↔ 1.70m → 76.47px/m
# 窗台两个口径**只是别名**，真值在 §0.5 的 WINDOW_SPEC（唯一真相源，禁止在此另写数字）
SILL_PX = WINDOW_SPEC[WIN_UP]["sill"]                 # 窗台 0.90m
SILL_STREET_PX = WINDOW_SPEC[WIN_LOW]["sill"]         # 临街一层 1.00m
FLOOR_H_SPEC = 205.0                  # 带门层净层高（门 150 ÷ 0.72）

#: 追加材质（纯追加，不改既有表）：灯室自发光 + 洞口内腔近全黑 + 水/草料/绳
SPEC_COLOR["cavity"] = ((0.032, 0.030, 0.028), 1.0, 0.0)   # 门洞/箭窗/拱洞内腔（近全黑）
SPEC_COLOR["lamp"] = ((1.00, 0.88, 0.58), 0.40, 0.0)
EMISSIVE["lamp"] = ((1.00, 0.82, 0.42), 2.6)
SPEC_COLOR["water"] = ((0.085, 0.155, 0.175), 0.12, 0.0)
SPEC_COLOR["straw"] = ((0.62, 0.50, 0.22), 0.95, 0.0)
SPEC_COLOR["rope"] = ((0.50, 0.42, 0.26), 0.92, 0.0)

_Y_AXIS = Vector((0.0, 1.0, 0.0))


# ---------------------------------------------------------------- 6.1 通用新模块

def cone_roof(b, x, y, z, r, h, mat, segments=16, r_top=0.0, uv_slope=True,
              eave_ring=True):
    """攒尖/锥形顶：底半径 r、顶半径 r_top、高 h（底在 z）。UV 顺坡（瓦垄不被压平）。

    eave_ring：锥顶檐口也做"可见厚度断面"——底缘一圈挑出的瓦檐唇 + 一道深色檐线
    （塔类锥顶没有山墙/檐板，只能靠这一圈读厚度；塔/风车/灯塔均已显式豁免剪影比）。
    """
    base, top = [], []
    for i in range(segments):
        th = 2.0 * math.pi * i / segments
        dx, dy = math.cos(th), math.sin(th)
        base.append(Vector((x + r * dx, y + r * dy, z)))
        top.append(Vector((x + r_top * dx, y + r_top * dy, z + h)))
    ctr = Vector((x, y, z + h * 0.5))
    for i in range(segments):
        j = (i + 1) % segments
        p0, p1 = base[i], base[j]
        tng = Vector((-(p1.y - p0.y), (p1.x - p0.x), 0.0))
        if tng.length < 1e-9:
            tng = Vector((1.0, 0.0, 0.0))
        tng.normalize()
        sl = top[i] - base[i]
        slope = sl.normalized() if sl.length > 1e-9 else Vector((0.0, 0.0, 1.0))
        uv = (tng, slope) if uv_slope else None
        if r_top <= 1e-6:
            b.poly([p0, p1, Vector((x, y, z + h))], mat,
                   outward=((p0 + p1) * 0.5 - ctr), uv_axes=uv)
        else:
            p2, p3 = top[j], top[i]
            b.poly([p0, p1, p2, p3], mat, outward=((p0 + p1 + p2 + p3) * 0.25 - ctr),
                   uv_axes=uv)
    if r_top > 1e-6:
        cap = [Vector((x + r_top * math.cos(2.0 * math.pi * i / segments),
                       y + r_top * math.sin(2.0 * math.pi * i / segments), z + h))
               for i in range(segments)]
        b.poly(cap, mat, outward=(0.0, 0.0, 1.0))
    if eave_ring and h > 12.0:
        b.cylinder((x, y, z + 2.0), r * 1.055, 9.0, mat, segments=segments)
        b.cylinder((x, y, z - 2.5), r * 1.045, 5.0, "wood_dark", segments=segments)


def ring_stone(b, cx, y, cz, r, mat, blocks=8, depth=10.0, thick=16.0,
               a0=0.0, a1=math.pi):
    """XZ 平面内沿半径 r 排一圈料石（拱券 / 玫瑰窗石环 / 装饰环）。"""
    span = a1 - a0
    for k in range(blocks):
        th = a0 + span * (k + 0.5) / float(blocks)
        ca, sa = math.cos(th), math.sin(th)
        c = Vector((cx + r * ca, y, cz + r * sa))
        axes = (Vector((ca, 0.0, sa)), _Y_AXIS, Vector((-sa, 0.0, ca)))
        arc = abs(span) * r / float(blocks) * 1.12
        b.box_oriented(c, axes, (thick / 2.0, depth / 2.0, max(7.0, arc / 2.0)), mat)


def arch_head_face(b, x, y, z0, r, head, mat, profile="round", steps=12):
    """拱头面（一片凸多边形）：半圆 / 尖拱。"""
    def hw(t):
        if profile == "point":
            return r * (1.0 - t) ** 0.62
        return r * math.sqrt(max(0.0, 1.0 - t * t))

    pts = [(x - r, y, z0)]
    for k in range(1, steps):
        t = k / float(steps)
        pts.append((x - hw(t), y, z0 + head * t))
    pts.append((x, y, z0 + head))
    for k in range(steps - 1, 0, -1):
        t = k / float(steps)
        pts.append((x + hw(t), y, z0 + head * t))
    pts.append((x + r, y, z0))
    b.poly(pts, mat, outward=(0.0, -1.0, 0.0))


def arch_wall1(b, w, h, d, mat, x=0.0, y=0.0, z=0.0, ow=0.0, z0=0.0, z1=0.0,
               head=0.0, profile="round", steps=16):
    """单拱洞墙板：**平滑拱腹 + 拱肩凸多边形**（不做竖条近似，正面看不出阶梯）。

    w×h×d 墙板（y 为墙心）；洞口净宽 ow、矩形段 z0..z1（绝对高）、head = 拱高。
    """
    half, wh = ow / 2.0, w / 2.0
    side = wh - half
    if z0 > z + 0.5:                                   # 洞口以下
        b.box_bottom((w, d, z0 - z), (x, y), z, mat)
    if side > 0.5:
        for sx in (-1.0, 1.0):                         # 洞口矩形段两侧
            if z1 - z0 > 0.5:
                b.box_bottom((side, d, z1 - z0), (x + sx * (half + side / 2.0), y),
                             z0, mat)
    ztop = z1 + head
    if head > 0.5:
        if side > 0.5:                                 # 拱头段两侧
            for sx in (-1.0, 1.0):
                b.box_bottom((side, d, head), (x + sx * (half + side / 2.0), y),
                             z1, mat)

        def curve(k):
            th = math.pi * k / float(steps)
            u = half * math.cos(th)
            c = (head * math.sin(th) if profile == "round"
                 else head * (1.0 - abs(u) / half) ** 0.62)
            return u, z1 + c

        for (yy, out) in ((y - d / 2.0, (0.0, -1.0, 0.0)),
                          (y + d / 2.0, (0.0, 1.0, 0.0))):
            poly = [(x + curve(0)[0], yy, curve(0)[1])]
            for k in range(1, steps):
                u, zz = curve(k)
                poly.append((x + u, yy, zz))
            poly += [(x - half, yy, z1), (x - half, yy, ztop), (x + half, yy, ztop)]
            b.poly(poly, mat, outward=out)
        prev = curve(0)
        for k in range(1, steps + 1):
            u, zz = curve(k)
            pu, pz = prev
            n = Vector((-0.5 * (u + pu), 0.0, -(0.5 * (zz + pz) - z1)))
            n = n.normalized() if n.length > 1e-6 else Vector((0.0, 0.0, 1.0))
            b.poly([(x + pu, y - d / 2.0, pz), (x + u, y - d / 2.0, zz),
                    (x + u, y + d / 2.0, zz), (x + pu, y + d / 2.0, pz)],
                   mat, outward=(n.x, 0.0, n.z))
            prev = (u, zz)
    if z + h - ztop > 0.5:                             # 拱顶以上
        b.box_bottom((w, d, z + h - ztop), (x, y), ztop, mat)
    return {"ow": ow, "head": head, "z1": z1, "ztop": ztop}


def arch_wall(b, w, h, d, mat, x=0.0, y=0.0, z=0.0, openings=(), head_steps=10):
    """正面墙板，洞口支持半圆拱/尖拱头（**真洞**：门、城门通道）。

    openings = [(cx, ow, z0, z1, head, profile), ...]
      cx 相对墙心、z 绝对、head 拱高（0=矩形）、profile "round"/"point"。
    单个拱洞走 arch_wall1（平滑拱腹）；多洞或纯矩形洞走逐层一维补集（竖条法）。
    """
    ops = [list(o) for o in openings]
    if len(ops) == 1 and len(ops[0]) >= 5 and ops[0][4] > 0.0:
        o = ops[0]
        return arch_wall1(b, w, h, d, mat, x, y, z, ow=o[1], z0=o[2], z1=o[3],
                          head=o[4], profile=(o[5] if len(o) > 5 else "round"),
                          steps=max(10, head_steps + 6))
    zs = {z, z + h}
    for o in ops:
        zs.add(o[2])
        head = o[4] if len(o) > 4 else 0.0
        if head <= 0.0:
            zs.add(o[3])
        else:
            for k in range(head_steps + 1):
                zs.add(o[3] + head * k / float(head_steps))
    zs = sorted(zz for zz in zs if z - 1e-6 <= zz <= z + h + 1e-6)
    for i in range(len(zs) - 1):
        za, zb = zs[i], zs[i + 1]
        if zb - za < 1e-6:
            continue
        zc = (za + zb) * 0.5
        holes = []
        for o in ops:
            cx, ow, z0, z1 = o[0], o[1], o[2], o[3]
            head = o[4] if len(o) > 4 else 0.0
            prof = o[5] if len(o) > 5 else "round"
            if zc < z0 or zc > z1 + head:
                continue
            half = ow * 0.5
            if head > 0.0 and zc > z1:
                t = min(1.0, max(0.0, (zc - z1) / head))
                if prof == "point":
                    half = ow * 0.5 * (1.0 - t) ** 0.62
                else:
                    half = ow * 0.5 * math.sqrt(max(0.0, 1.0 - t * t))
            holes.append((x + cx - half, x + cx + half))
        for (sx0, sx1) in _solid_segments((x - w / 2.0, x + w / 2.0), holes):
            if sx1 - sx0 < 1e-6:
                continue
            b.box_bottom((sx1 - sx0, d, zb - za), ((sx0 + sx1) / 2.0, y), za, mat)


def blind_arch(b, x, y, z, w, h, head=0.0, mat="cavity", ring="white_stone",
               profile="round", blocks=7, depth=10.0, ring_thick=14.0,
               sill=False, jamb=True):
    """盲拱/塔身小窗：凹进暗腔 + 拱头暗面 + 外圈料石（**不做真洞**）。

    塔类都是实心体量，做真洞会看穿内腔或地面，故用凹腔 + 石圈表达。
    """
    half = w / 2.0
    b.box((w, depth, h), (x, y + depth * 0.5, z + h * 0.5), mat)
    if head > 0.0:
        arch_head_face(b, x, y + 1.0, z + h, half, head, mat, profile=profile)
        ring_stone(b, x, y, z + h, half + 4.0, ring, blocks=blocks,
                   depth=depth + 6.0, thick=ring_thick, a0=0.0, a1=math.pi)
    if jamb:
        for sx in (-1.0, 1.0):
            b.box_bottom((9.0, depth + 6.0, h), (x + sx * (half + 4.5), y), z, ring)
    if sill:
        b.box_bottom((w + 22.0, depth + 8.0, 9.0), (x, y), z - 9.0, "white_stone")


def lancet_window(b, x, y, z, w, h, head=0.0, profile="point", glass="glass",
                  ring="white_stone", depth=10.0, blocks=7, sill=True):
    """尖拱窗（教堂/钟楼）：凹玻璃 + 拱头 + 外圈料石 + 窗台。"""
    half = w / 2.0
    b.box((w, depth, h), (x, y + depth * 0.5 - 1.0, z + h * 0.5), glass)
    if head > 0.0:
        arch_head_face(b, x, y - 1.0, z + h, half, head, glass, profile=profile)
        ring_stone(b, x, y, z + h, half + 4.5, ring, blocks=blocks,
                   depth=depth + 6.0, thick=13.0, a0=0.0, a1=math.pi)
    for sx in (-1.0, 1.0):
        b.box_bottom((9.0, depth + 6.0, h), (x + sx * (half + 5.0), y), z, ring)
    if sill:
        b.box_bottom((w + 24.0, depth + 8.0, 9.0), (x, y), z - 9.0, ring)


def rose_window(b, x, y, z, r, glass="glass", tracery="white_stone", spokes=8,
                depth=10.0, rings=(0.52, 0.80), hub=0.18):
    """玫瑰窗：暗玻璃圆盘 + 放射窗棂 + 同心石环 + 外圈料石。z = 圆心高。"""
    b.cylinder((x, y + depth * 0.5 - 2.0, z), r * 0.98, depth, glass,
               segments=24, axis="Y")
    for rr in rings:
        ring_stone(b, x, y, z, r * rr, tracery, blocks=16, depth=depth + 4.0,
                   thick=7.0, a0=0.0, a1=2.0 * math.pi)
    for k in range(spokes):
        th = 2.0 * math.pi * k / spokes
        strut(b, (x, y - 3.0, z),
              (x + r * 0.96 * math.cos(th), y - 3.0, z + r * 0.96 * math.sin(th)),
              7.0, tracery)
    b.cylinder((x, y - 3.0, z), r * hub, depth + 8.0, tracery, segments=14, axis="Y")
    ring_stone(b, x, y, z, r + 5.0, tracery, blocks=18, depth=depth + 10.0,
               thick=16.0, a0=0.0, a1=2.0 * math.pi)


def arrow_slit(b, x, y, z, w=15.0, h=52.0, mat="cavity", frame="stone_dark",
               depth=9.0, crosslet=True):
    """箭窗：窄缝暗腔 + 石框（带十字劈缝）。"""
    b.box((w, depth, h), (x, y + depth * 0.5, z + h * 0.5), mat)
    for sx in (-1.0, 1.0):
        b.box_bottom((7.0, depth + 5.0, h + 12.0), (x + sx * (w / 2.0 + 3.5), y),
                     z - 6.0, frame)
    b.box_bottom((w + 14.0, depth + 5.0, 8.0), (x, y), z + h, frame)
    if crosslet:
        b.box_bottom((w + 6.0, depth + 4.0, 9.0), (x, y), z + h * 0.52, frame)


def crenellation(b, w, d, z, mat, x=0.0, y=0.0, merlon=34.0, gap=20.0, h=34.0,
                 band=16.0, band_lip=8.0):
    """垛口：外挑压顶走道 + 前后沿/侧沿交替垛子。z = 压顶底。"""
    b.box_bottom((w + 2.0 * band_lip, d + 2.0 * band_lip, band), (x, y), z, mat)
    nx = max(2, int(round(w / (merlon + gap))))
    stepx = w / float(nx)
    mw = max(18.0, stepx * 0.62)
    for i in range(nx):
        px = x - w / 2.0 + stepx * (i + 0.5)
        for sy in (-1.0, 1.0):
            b.box_bottom((mw, 18.0, h), (px, y + sy * (d / 2.0 - 9.0)), z + band, mat)
    ny = max(1, int(round(d / (merlon + gap))))
    stepy = d / float(ny)
    md = max(18.0, stepy * 0.62)
    for i in range(ny):
        py = y - d / 2.0 + stepy * (i + 0.5)
        for sx in (-1.0, 1.0):
            b.box_bottom((18.0, md, h), (x + sx * (w / 2.0 - 9.0), py), z + band, mat)


def quoins(b, w, d, h, mat="white_stone", x=0.0, y=0.0, z=0.0, size=24.0,
           step=40.0, front=True, sides=True):
    """角部隅石：竖边依次交替的凸出料石（塔/石宅边角读法）。"""
    n = max(1, int(h / step))
    for i in range(n):
        zz = z + i * step
        hh = min(step * 0.58, z + h - zz)
        if hh < 6.0:
            break
        for sx in (-1.0, 1.0):
            if front:
                b.box_bottom((size, 14.0, hh), (x + sx * (w / 2.0 - size * 0.24),
                                                y - d / 2.0 + 3.0), zz, mat)
            if sides:
                b.box_bottom((14.0, size, hh), (x + sx * (w / 2.0 - 3.0),
                                                y - d / 2.0 + d * 0.18), zz, mat)


def buttress(b, x, y, z, w, h, depth=20.0, mat="stone", cap_h=24.0,
             cap_mat="white_stone"):
    """扶壁：竖向墩 + 斜顶帽。y 为墩心（凸出正立面）。"""
    b.box_bottom((w, depth, h - cap_h), (x, y), z, mat)
    b.box_bottom((w + 6.0, depth + 6.0, 8.0), (x, y), z + h - 4.0, cap_mat)


def tri_prism_y(b, x, y, half_w, rise, z_base, depth, mat):
    """山墙三角（**面朝 -Y 的正立面**）：底边 2*half_w(X)、高 rise、沿 Y 拉伸 depth。"""
    y0, y1 = y - depth / 2.0, y + depth / 2.0
    a0, b0 = (x - half_w, y0, z_base), (x + half_w, y0, z_base)
    c0 = (x, y0, z_base + rise)
    a1, b1 = (x - half_w, y1, z_base), (x + half_w, y1, z_base)
    c1 = (x, y1, z_base + rise)
    b.poly([a0, b0, c0], mat, outward=(0.0, -1.0, 0.0))
    b.poly([a1, b1, c1], mat, outward=(0.0, 1.0, 0.0))
    b.poly([a0, a1, b1, b0], mat, outward=(0.0, 0.0, -1.0))
    b.poly([a0, a1, c1, c0], mat, outward=(-1.0, 0.0, 0.0))
    b.poly([b0, b1, c1, c0], mat, outward=(1.0, 0.0, 0.0))


def roof_gable_y(b, w, span, rise, over_x, mat, x=0.0, y=0.0, z=0.0, thickness=14.0,
                 over_y=18.0, mat_under=None, ridge_cap=True, cap_size=(30.0, 15.0),
                 cap_mat=None, eave_board=True, board_mat=None, board_h=0.0):
    """屋脊沿 Y 的双坡顶：**正面看到山墙三角**（教堂/门楼的正立面读法）。

    w = 跨脊方向宽度（X，不含出檐）；span = 屋脊长度（Y）；over_x = 檐口出檐（每侧 X）；
    over_y 给负值可让屋面退到山墙面之后（山墙由 tri_prism_y 收口）。
    """
    half = w / 2.0 + over_x
    slope = math.hypot(half, rise)
    ang = math.atan2(rise, half)
    ca, sa = math.cos(ang), math.sin(ang)
    span_y = span + 2.0 * over_y
    for sign in (-1.0, 1.0):
        c = Vector((x + sign * half / 2.0, y, z + rise / 2.0))
        a0 = Vector((sign * ca, 0.0, -sa))          # 顺坡向下（脊 -> 檐）
        a1 = Vector((0.0, sign, 0.0))
        a2 = Vector((sign * sa, 0.0, ca))           # 外法线
        b.box_oriented(c, (a0, a1, a2), (slope / 2.0, span_y / 2.0, thickness / 2.0),
                       mat, uv_axes=(_Y_AXIS, a0))
        if mat_under:
            b.box_oriented(c - a2 * (thickness / 2.0 + 1.0), (a0, a1, a2),
                           (slope / 2.0 - 2.0, span_y / 2.0, 1.0), mat_under,
                           uv_axes=(_Y_AXIS, a0))
    if eave_board:
        bh = board_h if board_h else max(7.0, thickness * 0.42)
        for sign in (-1.0, 1.0):
            b.box_bottom((10.0, span_y + 1.0, bh), (x + sign * (half - 2.0), y),
                         z - bh * 0.55, board_mat or mat_under or "wood_dark")
    if ridge_cap:
        b.box_bottom((cap_size[0], span_y + 2.0, cap_size[1]), (x, y),
                     z + rise - cap_size[1] * 0.35, cap_mat or mat)
    return {"ridge_z": z + rise, "half": half, "angle_deg": math.degrees(ang)}


def mill_sails(b, hx, hy, hz, length, mat="wood", spar=13.0, blade_w=0.0,
               rungs=7, thick=9.0, rail=9.0):
    """四片格栅风车叶（斜 45° 十字，有厚度）：主梁 + 外轨 + 横档（梯格）。"""
    bw = blade_w if blade_w > 0.0 else length * 0.24
    hub = Vector((hx, hy, hz))
    for k in range(4):
        a = math.radians(45.0 + 90.0 * k)
        d = Vector((math.cos(a), 0.0, math.sin(a)))
        perp = Vector((-d.z, 0.0, d.x))
        b.box_oriented(hub + d * (length * 0.5), (d, _Y_AXIS, perp),
                       (length / 2.0, thick / 2.0, spar / 2.0), mat)
        b.box_oriented(hub + d * (length * 0.52) + perp * bw, (d, _Y_AXIS, perp),
                       (length * 0.52 - rail, thick * 0.30, rail / 2.0), mat)
        for i in range(rungs):
            f = (i + 0.5) / float(rungs) * 0.92
            b.box_oriented(hub + d * (length * f) + perp * (bw * 0.5),
                           (d, _Y_AXIS, perp), (rail * 0.6, thick * 0.28, bw / 2.0), mat)
    b.cylinder((hx, hy, hz), spar * 1.5, thick * 2.8, "iron", segments=14, axis="Y")


def lantern_room(b, x, y, z, r, h, glass="lamp", frame="iron", roof_mat="slate",
                 roof_h=0.0, posts=8):
    """灯塔灯室：自发光玻璃柱 + 铁竖棂 + 顶盖 + 顶尖（lamp 为追加的自发光材质）。"""
    b.cylinder((x, y, z + h / 2.0), r, h, glass, segments=12)
    for k in range(posts):
        th = 2.0 * math.pi * k / posts
        b.box_bottom((9.0, 9.0, h + 8.0),
                     (x + math.cos(th) * r * 1.03, y + math.sin(th) * r * 1.03),
                     z - 4.0, frame)
    b.cylinder((x, y, z + h + 5.0), r * 1.16, 10.0, frame, segments=12)
    if roof_h > 0.0:
        cone_roof(b, x, y, z + h + 10.0, r * 1.24, roof_h, roof_mat, segments=12)
        b.cylinder((x, y, z + h + 10.0 + roof_h + 6.0), 6.0, 16.0, frame, segments=8)
        b.cylinder((x, y, z + h + 10.0 + roof_h + 15.0), 11.0, 13.0, frame, segments=10)


def arched_doorway(b, x, y_front, depth, w, h=DOOR_H, head=0.0, mat="stone",
                   profile="round", door_mat="wood", leaves=1, frame=9.0,
                   porch_w=None, sill=True, step=True):
    """凸出门廊：拱洞（真洞，前板 depth 厚）+ 洞内暗腔 + 门扇 + 拱券 + 台阶。

    y_front = 门廊外表面（-Y 一侧）；leaves=1/2 决定单扇/双扇（§8.3 复合门洞）。
    """
    pw = porch_w or (w + 44.0)
    total = DOOR_SILL + h + head
    arch_wall(b, pw, total + 12.0, depth, mat, x, y_front + depth / 2.0, 0.0,
              openings=[(0.0, w, DOOR_SILL, DOOR_SILL + h, head, profile)])
    b.box((w - 2.0, depth + 18.0, DOOR_SILL + h + head),
          (x, y_front + 2.0 + (depth + 18.0) / 2.0, (DOOR_SILL + h + head) / 2.0),
          "cavity")
    leaf_w = min(60.0, max(DOOR_W_RANGE[0] + 1.0, (w - 8.0) / float(leaves)))
    for k in range(leaves):
        ox = (k - (leaves - 1) / 2.0) * (leaf_w + 4.0)
        door(b, h=h, w=leaf_w, mat=door_mat, x=x + ox, y=y_front + 2.0, z=DOOR_SILL,
             frame_mat="stone_dark" if mat != "wood" else "timber", frame=frame,
             planks=3, iron=True)
    if head > 0.0:
        ring_stone(b, x, y_front + 3.0, DOOR_SILL + h, w / 2.0 + 6.0, "white_stone",
                   blocks=9, depth=depth * 0.6, thick=16.0, a0=0.0, a1=math.pi)
    if sill:
        b.box_bottom((w + 26.0, depth * 0.5, DOOR_SILL), (x, y_front + depth * 0.25),
                     -DOOR_SILL, "stone")


def _side_slit(b, x, u, z, w, h):
    """侧墙箭窗（贴 ±X 墙面）。"""
    fd = 1.0 if x > 0 else -1.0
    b.box((9.0, w, h), (x + fd * 3.0, u, z + h * 0.5), "cavity")
    for sy in (-1.0, 1.0):
        b.box_bottom((14.0, 7.0, h + 12.0), (x, u + sy * (w / 2.0 + 3.5)), z - 6.0,
                     "stone_dark")
    b.box_bottom((14.0, w + 14.0, 8.0), (x, u), z + h, "stone_dark")


# ---------------------------------------------------------------- 6.2 参数表（新 def 专用）

#: 三层联排：层高 205/200/200（门占 73%）、檐高 ≈ 621（§8.7 三层 600~620）、rise ≈ 层高/2
ROWHOUSE_TIERS = {
    12: dict(D=196.0, plinth=16.0, storeys=(205.0, 200.0, 200.0), rise=102.0,
             wt=20.0, door_w=56.0, jetty=9.0),
    16: dict(D=212.0, plinth=16.0, storeys=(205.0, 200.0, 200.0), rise=104.0,
             wt=22.0, door_w=58.0, jetty=10.0),
}
#: 风车磨坊：石砌收分塔身 + 锥顶 + 四片格栅叶（叶长 = 塔宽 × 1.35）
WINDMILL_TIERS = {
    4: dict(R=56.0, plinth=14.0, tower_h=252.0, taper=0.66, cone_h=84.0, door_w=46.0),
    6: dict(R=84.0, plinth=16.0, tower_h=288.0, taper=0.68, cone_h=94.0, door_w=52.0),
    8: dict(R=112.0, plinth=18.0, tower_h=320.0, taper=0.70, cone_h=104.0, door_w=56.0),
}
#: 大教堂：中殿两层（檐高 400~413）+ 山墙正立面（玫瑰窗/尖拱门廊）+ 双塔或单钟楼 + 尖顶
CATHEDRAL_TIERS = {
    12: dict(D=200.0, plinth=18.0, nave_h=400.0, rise=136.0, wt=22.0, twin=False,
             tower_w=124.0, tower_h=560.0, spire_h=118.0, portal_w=88.0,
             leaf=42.0, rose_r=54.0, rose_z=298.0),
    16: dict(D=232.0, plinth=20.0, nave_h=410.0, rise=150.0, wt=24.0, twin=True,
             tower_w=106.0, tower_h=578.0, spire_h=150.0, portal_w=106.0,
             leaf=50.0, rose_r=64.0, rose_z=334.0),
}
#: 瞭望塔：石塔（三段退台 + 垛口）+ 3 层箭窗 + 底部拱门
TOWER_TIERS = {
    4: dict(D=112.0, plinth=16.0, body_h=380.0, door_w=50.0, merlon=30.0),
    6: dict(D=152.0, plinth=18.0, body_h=420.0, door_w=56.0, merlon=34.0),
}
#: 城门楼：两侧塔 + 中央大拱门洞（可过火柴人）+ 垛口 + 门道阴影
GATEHOUSE_TIERS = {
    6: dict(D=152.0, plinth=16.0, body_h=240.0, tower_h=312.0, gate_w=96.0, wt=18.0),
    8: dict(D=180.0, plinth=18.0, body_h=264.0, tower_h=340.0, gate_w=112.0, wt=20.0),
    12: dict(D=212.0, plinth=20.0, body_h=300.0, tower_h=382.0, gate_w=140.0, wt=22.0),
}
#: 灯塔：收分塔身 + 环形石檐带 + 灯室（自发光）+ 门 + 小窗
LIGHTHOUSE_TIERS = {
    4: dict(R=52.0, plinth=18.0, tower_h=292.0, taper=0.78, gallery=16.0,
            lantern_h=62.0, cone_h=44.0, door_w=46.0),
    6: dict(R=78.0, plinth=20.0, tower_h=336.0, taper=0.80, gallery=18.0,
            lantern_h=70.0, cone_h=50.0, door_w=52.0),
}


# ---------------------------------------------------------------- 6.3 装配器

def assemble_rowhouse(width_cells=12):
    """三层联排：一层砖砌（门 + 窗）/ 二三层抹灰木骨（高窗 / 小窗），层间腰线出挑，陶瓦顶。

    §8.7：带门层 205（门占 73%）、檐高 3×205 ≈ 621、rise ≈ 层高/2；窗台 76（临街）/
    69（上层）、窗高 92~100、窗宽按开间比例收窄；**逐层只走 2 档窗型**
    （WIN_LOW 下层矮宽 / WIN_UP 上层瘦高，顶层同档收窄 + 加窗板 → 同立面 2 种）。
    12 格档三层剪影比 ≈1.9（超多层 1.2~1.6 上界）→ 显式豁免，理由见 spec。
    """
    t = ROWHOUSE_TIERS[width_cells]
    W = width_cells * CELL
    D, plinth_h = t["D"], t["plinth"]
    gf_h, f2_h, f3_h = t["storeys"]
    rise, wt, door_w, jetty = t["rise"], t["wt"], t["door_w"], t["jetty"]
    over = eave_over(W)
    eave = plinth_h + gf_h + f2_h + f3_h
    bays = bays_of(width_cells)
    yf0 = -D / 2.0
    yf1, yf2 = yf0 - jetty, yf0 - 2.0 * jetty
    yc1 = (yf1 + D / 2.0) / 2.0
    yc2 = (yf2 + D / 2.0) / 2.0
    z1 = plinth_h + gf_h
    z2 = z1 + f2_h
    dx, gfw = bay_openings(W, bays, WIN_LOW, door_w=door_w, door_bay=0,
                           floor_z=plinth_h)
    _d2, f2w = bay_openings(W, bays, WIN_UP, floor_z=z1)
    # 顶层（小窗）：只在 0/2 开间开窗 + 同档收窄 + 窗板 → 与二层明显分层（不新增窗型）
    _d3, f3w = bay_openings(W, bays, WIN_TOP, floor_z=z2, skip=(1, 3),
                            w_scale=0.82, shutters=True)

    b = Builder("rowhouse_w%d" % width_cells)
    contact_shadow(b, W, D + 2.0 * jetty, spread=30.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(dx - door_w / 2.0 - 6.0, dx + door_w / 2.0 + 6.0))
    # ---- 一层（砖）：门 + 窗（WIN_LOW 矮宽）
    room_shell(b, W, D, plinth_h, gf_h, wt, "brick",
               front_openings=[(dx, door_w, DOOR_SILL, DOOR_SILL + DOOR_H)] + win_holes(gfw))
    door(b, w=door_w, mat="wood_door", x=dx, y=yf0, z=DOOR_SILL,
         frame_mat="timber", planks=4)
    step_stone(b, w=door_w + 34.0, depth=26.0, h=10.0, x=dx, y=yf0 - 18.0)
    for w in gfw:
        put_window(b, w, w["cx"], yf0)
    # ---- 二/三层（抹灰 + 木骨）：前墙逐层外挑，窗型逐层差异化
    wall_panel(b, W, f2_h, D + jetty, "plaster", 0.0, yc1, z1,
               openings=win_holes(f2w))
    timber_frame(b, W, f2_h, "timber", (0.0, yf1), z1, depth=7.0, post=14.0,
                 top_band=16.0, bays=bays, braces=True,
                 openings=[(w["cx"], w["ow"]) for w in f2w])
    for w in f2w:
        put_window(b, w, w["cx"], yf1)
    wall_panel(b, W, f3_h, D + 2.0 * jetty, "plaster", 0.0, yc2, z2,
               openings=win_holes(f3w))
    timber_frame(b, W, f3_h, "timber", (0.0, yf2), z2, depth=7.0, post=14.0,
                 top_band=16.0, bays=bays, braces=True,
                 openings=[(w["cx"], w["ow"]) for w in f3w])
    for w in f3w:
        put_window(b, w, w["cx"], yf2)
    # ---- 层间腰线（白石）+ 出挑托木 → 立面分层可读
    for (zc, yb, nbr) in ((z1, yf0, 5), (z2, yf1, 5)):
        b.box_bottom((W + 12.0, 28.0, 16.0), (0.0, yb + 6.0), zc - 16.0, "white_stone")
        for i in range(nbr):
            px = -W / 2.0 + 16.0 + (W - 32.0) * i / float(nbr - 1)
            b.box_bottom((14.0, 20.0, 14.0), (px, yb + 10.0), zc - 14.0, "timber")
    # ---- 陶瓦顶（rise ≈ 层高/2）
    roof_gable(b, W, D + 2.0 * jetty, rise, over, "tile", z=eave, thickness=15.0,
               mat_under="wood_dark", cap_size=(30.0, 16.0), board_h=9.0, y=yc2)
    gable_w = win_rect(WIN_GABLE, bay_w=(D + 2.0 * jetty) * 0.5, floor_z=eave)
    gable_w["u"] = yc2 - D * 0.14
    gable_infill(b, W, D + 2.0 * jetty, rise, "plaster", z=eave, thickness=14.0,
                 y=yc2, hole=(gable_w["u"], gable_w["ow"], gable_w["z0"],
                              gable_w["z1"]))
    for sx in (-1.0, 1.0):
        gable_timber(b, D + 2.0 * jetty, rise, "timber", (sx * (W / 2.0), yc2), eave,
                     axis="Y", face_dir=sx, thick=11.0)
        put_window(b, gable_w, gable_w["u"], sx * (W / 2.0), axis="Y", face_dir=sx)
    ch_list = []
    for sx in (-1.0, 1.0):                       # 双烟囱：落地 + 穿顶泛水
        ch_x, ch_y = sx * W * 0.27, yc2 - 8.0
        # 柱身顶沿用旧口径（双烟囱是这栋的天际线顶点 → 高度一个像素都不许动）
        ch_top = (eave + rise - 70.0) + (rise + 26.0 - 12.0)
        ch_list.append({"x": ch_x, "y": ch_y,
                        "roof": gable_roof_z(eave, rise,
                                             (D + 2.0 * jetty) / 2.0 + over, ch_y,
                                             y_ridge=yc2),
                        "top": ch_top + 12.0, "foot": 0.0, "w": 30.0, "d": 26.0})
        chimney(b, 30.0, 26.0, ch_top, "brick", ch_x, ch_y, foot=0.0,
                cap_mat="stone_dark", cap=12.0, roof=ch_list[-1]["roof"])

    ob = b.to_object()
    spec = _mk("rowhouse", width_cells, {
        "depth": D + 2.0 * jetty, "plinth_h": plinth_h, "wall_h": gf_h + f2_h + f3_h,
        "eave_h": eave, "rise": rise, "total_h": eave + rise + 12.0, "overhang": over,
        "roof_t": 15.0, "storey_h": [gf_h, f2_h, f3_h], "storey_band": (200.0, 212.0),
        "double_storey": True, "door": (door_w, DOOR_H), "door_x": dx,
        "floor_h": gf_h, "window": (gfw[0]["ow"], gfw[0]["oh"], gfw[0]["z0"] - plinth_h),
        "window_up": (f2w[0]["ow"], f2w[0]["oh"], f2w[0]["z0"] - z1),
        "gable_window": (gable_w["ow"], gable_w["oh"], gable_w["u"],
                          gable_w["z0"]),
        "bays": bays, "three_storey": True, "chimneys": ch_list,
        "ratio_band": (1.20, 1.60),
        "ratio_exempt": (width_cells == 12),
        "reason": "三层联排：384px 宽下 3 层（205×3 + rise）剪影算术下限 ≈1.9，"
                  "属沿街成排体量（16 格档 1.5 合规）",
        "material": "砖 + 抹灰木骨 / 陶瓦"})
    return ob, spec


def assemble_windmill(width_cells=6):
    """风车磨坊：石砌收分塔身（3 段退台 + 石檐带）+ 锥形顶 + 四片格栅风车叶 + 底部拱门。

    塔类竖向体量（剪影比 2~2.6）显式豁免；锥顶出檐按塔半径比例（非民居坡檐口径）。
    """
    t = WINDMILL_TIERS[width_cells]
    W = width_cells * CELL
    R, plinth_h = t["R"], t["plinth"]
    tower_h, taper, cone_h, door_w = t["tower_h"], t["taper"], t["cone_h"], t["door_w"]
    D = 2.0 * R
    top_r = R * taper
    yf = -R - 10.0

    b = Builder("windmill_w%d" % width_cells)
    contact_shadow(b, D, D, spread=26.0)
    b.cylinder((0.0, 0.0, plinth_h * 0.6), R * 1.10, plinth_h * 1.2, "stone_dark",
               segments=20)
    sec = tower_h / 3.0
    r_prev = R
    for k in range(3):
        r_next = R * (taper ** ((k + 1) / 3.0))
        b.cylinder((0.0, 0.0, plinth_h + sec * (k + 0.5)), r_prev, sec, "stone",
                   segments=20, taper=r_next / r_prev)
        if k:
            b.cylinder((0.0, 0.0, plinth_h + sec * k), r_prev * 1.09, 13.0,
                       "white_stone", segments=20)
        r_prev = r_next
    z_top = plinth_h + tower_h
    b.cylinder((0.0, 0.0, z_top + 7.0), top_r * 1.14, 14.0, "white_stone", segments=20)
    cone_roof(b, 0.0, 0.0, z_top + 14.0, top_r * 1.20, cone_h, "tile", segments=16)
    b.cylinder((0.0, 0.0, z_top + 14.0 + cone_h + 5.0), 7.0, 18.0, "iron", segments=8)
    # ---- 底部拱门（门廊 + 门扇 + 圆券）+ 塔身小窗（走窗规格表 peephole 档）
    arched_doorway(b, 0.0, yf, 34.0, door_w, head=door_w * 0.5, mat="stone",
                   porch_w=door_w + 50.0)
    for zf in (0.40, 0.60):
        zz = plinth_h + tower_h * zf
        rr = R * (1.0 - (zz - plinth_h) / tower_h * (1.0 - taper))
        tw_win = win_rect("peephole", floor_z=zz)
        wy = -math.sqrt(max(4.0, rr * rr - (tw_win["ow"] * 0.5) ** 2)) + 1.0
        put_window(b, tw_win, 0.0, wy, frame_mat="stone_dark")
    # ---- 四片格栅风车叶（轮毂在塔身上部；叶长 = 塔宽 × 1.35）
    hub_z = plinth_h + tower_h * 0.78
    hub_r = R * (1.0 - (hub_z - plinth_h) / tower_h * (1.0 - taper))
    hub_y = -hub_r - 22.0
    b.cylinder((0.0, (hub_y - 0.0) / 2.0 - 0.0, hub_z), 9.0, abs(hub_y) + top_r * 0.2,
               "wood_dark", segments=10, axis="Y")
    sail_len = R * 2.0 * 1.22
    mill_sails(b, 0.0, hub_y, hub_z, sail_len, mat="wood", spar=13.0,
               blade_w=sail_len * 0.22, rungs=6, thick=9.0)

    ob = b.to_object()
    spec = _mk("windmill", width_cells, {
        "depth": D, "plinth_h": plinth_h, "wall_h": tower_h,
        "eave_h": plinth_h + tower_h, "rise": cone_h,
        "total_h": plinth_h + tower_h + cone_h + 23.0, "overhang": top_r * 0.14,
        "roof_t": 14.0, "storey_h": [tower_h], "door": (door_w, DOOR_H), "door_x": 0.0,
        "floor_h": FLOOR_H_SPEC, "window": None, "round_tower": True,
        "sail_len": sail_len, "hub_z": hub_z,
        "ratio_exempt": True, "eave_exempt": True,
        "width_exempt": (width_cells < MIN_DOOR_CELLS),
        "reason": "风车塔：竖向体量（塔身 + 锥顶 + 四叶跨度）；锥顶出檐按塔半径比例"
                  "（非民居坡檐 18~23% 口径）",
        "material": "石砌 / 陶瓦锥顶 + 木格栅叶"})
    return ob, spec


def assemble_cathedral(width_cells=16):
    """大教堂：中殿（两层高墙）+ 山墙正立面坡顶 + 玫瑰窗 + 尖拱门廊 + 双塔/单钟楼 + 尖顶。

    正立面沿 Y 跨脊 → 正对观众看到**山墙三角**（教堂正面读法），屋面只贡献轮廓线。
    16 格双塔（剪影比 ≈1.5，合规）；12 格中央单钟楼（要保住"天际线最高点"→ 豁免）。
    """
    t = CATHEDRAL_TIERS[width_cells]
    W = width_cells * CELL
    D, plinth_h, nave_h = t["D"], t["plinth"], t["nave_h"]
    rise, wt = t["rise"], t["wt"]
    tw, th, sh = t["tower_w"], t["tower_h"], t["spire_h"]
    pw, leaf, rose_r, rose_z = t["portal_w"], t["leaf"], t["rose_r"], t["rose_z"]
    twin = t["twin"]
    over_x = 10.0                                 # 教堂无民居式坡檐：只报山墙压顶出挑
    eave = plinth_h + nave_h
    ridge = eave + rise
    yf = -D / 2.0
    heads = pw * 0.85

    b = Builder("cathedral_w%d" % width_cells)
    contact_shadow(b, W, D, spread=34.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0, lip=12.0)
    # ---- 中殿四面墙（正面不开洞：门廊是独立凸出体量）+ 扶壁
    room_shell(b, W, D, plinth_h, nave_h, wt, "stone")
    for sx in (-1.0, 1.0):
        buttress(b, sx * (W / 2.0 - 22.0), yf + 4.0, plinth_h, 32.0, nave_h * 0.70,
                 depth=30.0)
        for k in range(2):
            buttress(b, sx * (W / 2.0 - 12.0), yf + D * (0.20 + 0.30 * k),
                     plinth_h, 26.0, nave_h * 0.56, depth=24.0, cap_h=22.0,
                     cap_mat="stone")
    # ---- 凸出门廊（尖拱真洞 + 双扇门 + 两道拱券 + 门柱）
    arched_doorway(b, 0.0, yf - 50.0, 50.0, pw, head=heads, mat="stone",
                   profile="point", leaves=2, porch_w=pw + 60.0, sill=False,
                   step=False)
    for (rr, thk, dep) in ((pw / 2.0 + 8.0, 16.0, 22.0), (pw / 2.0 + 26.0, 18.0, 14.0)):
        ring_stone(b, 0.0, yf - 46.0, DOOR_SILL + DOOR_H, rr, "white_stone",
                   blocks=11, depth=dep, thick=thk, a0=0.0, a1=math.pi)
    for sx in (-1.0, 1.0):
        b.box_bottom((18.0, 24.0, DOOR_H + 8.0),
                     (sx * (pw / 2.0 + 34.0), yf - 38.0), DOOR_SILL, "white_stone")
    step_stone(b, w=pw + 96.0, depth=36.0, h=12.0, x=0.0, y=yf - 84.0)
    # ---- 玫瑰窗 + 门廊两侧尖拱长窗（窗台/窗高按窗规格表 lancet 档）
    # 单钟楼档（12 格）：中央塔身凸在正立面之前 → 玫瑰窗改开在**塔身上**（否则被塔挡住）
    lanc = win_rect("lancet", floor_z=plinth_h)
    if twin:
        rose_window(b, 0.0, yf - 6.0, rose_z, rose_r, spokes=10)
    else:
        rose_window(b, 0.0, yf - 12.0 - tw - 4.0, plinth_h + nave_h * 0.72, rose_r,
                    spokes=10)
    inner = pw / 2.0 if twin else tw / 2.0
    outer = (W / 2.0 - tw) if twin else W / 2.0
    ox = (inner + outer) / 2.0
    if ox + 36.0 < outer - 16.0:
        for sx in (-1.0, 1.0):
            lancet_window(b, sx * ox, yf - 4.0, plinth_h + 130.0, lanc["ow"],
                          lanc["oh"], head=lanc["ow"] * 0.52)
    # ---- 山墙正立面（三角 + 石压顶 + 顶尖十字）
    tri_prism_y(b, 0.0, yf + 14.0, W / 2.0, rise, eave, 28.0, "stone")
    cope = (W / 2.0 - tw) if twin else W / 2.0
    for sx in (-1.0, 1.0):
        strut(b, (sx * (cope - 10.0), yf - 1.0, ridge - rise * (cope - 10.0) / (W / 2.0)
                  + 4.0), (0.0, yf - 1.0, ridge - 2.0), 20.0, "white_stone")
    b.box_bottom((28.0, 30.0, 28.0), (0.0, yf + 2.0), ridge - 4.0, "white_stone")
    b.box_bottom((11.0, 11.0, 44.0), (0.0, yf + 2.0), ridge + 20.0, "iron")
    b.box_bottom((26.0, 10.0, 10.0), (0.0, yf + 2.0), ridge + 48.0, "iron")
    # ---- 中殿坡顶（屋脊沿 Y；屋面退到山墙三角之后，正面只见山墙轮廓）
    roof_gable_y(b, W, D, rise, 0.0, "slate", z=eave, thickness=15.0, over_y=-28.0,
                 mat_under="wood_dark", cap_size=(28.0, 14.0), cap_mat="stone_dark",
                 eave_board=False)
    # ---- 钟楼（16 格：双塔 / 12 格：中央单钟楼）+ 尖顶
    tx = ((W - tw) / 2.0) if twin else 0.0
    for cx in ((-tx, tx) if twin else (0.0,)):
        ty = yf - 10.0 + tw / 2.0
        b.box_bottom((tw, tw, th - plinth_h), (cx, ty), plinth_h, "stone")
        quoins(b, tw, tw, (th - plinth_h) * 0.92, "white_stone", cx, ty, plinth_h,
               size=22.0, step=44.0, sides=False)
        b.box_bottom((tw + 16.0, tw + 16.0, 16.0), (cx, ty), plinth_h + (th - plinth_h),
                     "white_stone")
        cone_roof(b, cx, ty, plinth_h + th - plinth_h + 16.0, tw / 2.0 * 1.02, sh,
                  "slate", segments=8)
        b.cylinder((cx, ty, plinth_h + th - plinth_h + 16.0 + sh + 8.0), 7.0, 18.0,
                   "iron", segments=8)
        # 钟楼开口（双联尖拱盲窗）+ 下部尖拱长窗（高度取窗规格表，宽度随塔宽 tw）
        belf = win_rect("belfry")
        for sx in (-1.0, 1.0):
            blind_arch(b, cx + sx * tw * 0.23, ty - tw / 2.0 - 1.0,
                       th - 186.0, tw * 0.26, belf["oh"], tw * 0.18, mat="cavity",
                       ring="white_stone", blocks=6, depth=10.0, profile="point")
        lancet_window(b, cx, ty - tw / 2.0 - 2.0, plinth_h + nave_h * 0.50, tw * 0.30,
                      lanc["oh"], head=lanc["ow"] * 0.52) if twin else None
        # （单塔档塔身留给玫瑰窗）
    ob = b.to_object()
    spec = _mk("cathedral", width_cells, {
        "depth": D + 50.0, "plinth_h": plinth_h, "wall_h": nave_h, "eave_h": eave,
        "rise": rise, "total_h": th + 16.0 + sh + 26.0, "overhang": over_x,
        "roof_t": 15.0, "storey_h": [FLOOR_H_SPEC, nave_h - FLOOR_H_SPEC],
        "door": (pw, DOOR_H), "composite_door": True, "door_x": 0.0,
        "floor_h": FLOOR_H_SPEC,
        "window": (lanc["ow"], lanc["oh"], lanc["z0"] - plinth_h),
        "twin_towers": twin, "rose_r": rose_r, "spire_h": sh, "tower_h": th,
        "ratio_band": (1.20, 1.60),
        "eave_exempt": True, "ratio_exempt": (not twin),
        "reason": "教堂：正立面山墙坡顶无民居式出檐（檐口 = 30 线脚）；"
                  "12 格单钟楼档要保住'天际线最高点'，剪影比 ≈1.8 超多层上界",
        "material": "石砌 / 石板瓦 + 白石饰"})
    return ob, spec


def assemble_tower(width_cells=6):
    """瞭望塔：石塔（三段退台收分 + 隅石）+ 顶部垛口 + 3 层箭窗 + 底部拱门。"""
    t = TOWER_TIERS[width_cells]
    W = width_cells * CELL
    D, plinth_h, body_h = t["D"], t["plinth"], t["body_h"]
    door_w, merlon = t["door_w"], t["merlon"]
    yf = -D / 2.0

    b = Builder("tower_w%d" % width_cells)
    contact_shadow(b, W, D, spread=26.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(-door_w / 2.0 - 8.0, door_w / 2.0 + 8.0), lip=10.0)
    seg_h = body_h / 3.0
    widths = [W, W - 9.0, W - 18.0]
    for k in range(3):
        wk, dk = widths[k], D - 4.0 * k
        zz = plinth_h + seg_h * k
        b.box_bottom((wk, dk, seg_h), (0.0, yf + 2.0 * k + dk / 2.0), zz, "stone")
        if k:
            b.box_bottom((wk + 14.0, dk + 8.0, 12.0), (0.0, yf + 2.0 * k + dk / 2.0),
                         zz, "white_stone")
        quoins(b, wk, dk, seg_h * 0.9, "stone", 0.0, yf + 2.0 * k + dk / 2.0,
               zz + 6.0, size=min(22.0, wk * 0.20), step=48.0, sides=(k == 2))
    z_top = plinth_h + body_h
    # 底部拱门（**前凸门廊** + 门扇 + 圆券 + 门道暗腔：贴墙做会被塔身埋掉）
    arched_doorway(b, 0.0, yf - 26.0, 30.0, door_w, head=door_w * 0.5, mat="stone",
                   porch_w=door_w + 48.0)
    # 3 层箭窗（正面 + 两侧），逐层错位（尺寸一律取窗规格表 squint 档）
    slit = win_rect("squint")
    for k, zf in enumerate((0.40, 0.60, 0.80)):
        zz = plinth_h + body_h * zf
        seg = min(2, int(zf * 3))
        wk = widths[seg]
        off = (-1.0 if k % 2 else 1.0) * wk * 0.16
        arrow_slit(b, off, yf + 2.0 * seg - 1.0, zz, slit["ow"], slit["oh"])
        for sx in (-1.0, 1.0):
            _side_slit(b, sx * (wk / 2.0 - 1.0), off * 0.5, zz, slit["ow"],
                       slit["oh"])
    crenellation(b, widths[2], D - 8.0, z_top, "stone", 0.0, yf + 4.0 + (D - 8.0) / 2.0
                 - (D - 8.0) / 2.0 + (D - 8.0) / 2.0, merlon=merlon, gap=20.0, h=34.0,
                 band=16.0)

    ob = b.to_object()
    spec = _mk("tower", width_cells, {
        "depth": D, "plinth_h": plinth_h, "wall_h": body_h, "eave_h": z_top,
        "rise": 50.0, "total_h": z_top + 50.0, "overhang": 8.0, "roof_t": 0.0,
        "storey_h": [body_h], "door": (door_w, DOOR_H), "door_x": 0.0,
        "floor_h": FLOOR_H_SPEC, "window": None, "arrow_rows": 3,
        "ratio_exempt": True, "eave_exempt": True,
        "width_exempt": (width_cells < MIN_DOOR_CELLS),
        "reason": "瞭望塔：竖向城防体量（垛口压顶出挑 8，无民居坡檐）",
        "material": "石砌 + 白石隅石"})
    return ob, spec


def assemble_gatehouse(width_cells=8):
    """城门楼：两侧塔（前挑 + 加高 + 垛口）+ 中央大拱门洞（可过火柴人）+ 门道阴影。

    中央拱洞按 §8.3 复合门洞语义处理（无门扇 → spec["door"]=None，另记 gate 净空）；
    通道 = 一块 arch_wall（洞口宽 = 墙宽，两侧洞壁由塔身充当，拱肩自动填出）。
    """
    t = GATEHOUSE_TIERS[width_cells]
    W = width_cells * CELL
    D, plinth_h, body_h = t["D"], t["plinth"], t["body_h"]
    tower_h, gate_w = t["tower_h"], t["gate_w"]
    tw = (W - gate_w) / 2.0
    head = gate_w * 0.5
    rect_h = {6: 134.0, 8: 136.0, 12: 132.0}[width_cells]
    clear = rect_h + head
    yf = -D / 2.0
    ctr_y = yf + D / 2.0
    fwd = 18.0

    b = Builder("gatehouse_w%d" % width_cells)
    contact_shadow(b, W, D + fwd, spread=30.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(-gate_w / 2.0 - 6.0, gate_w / 2.0 + 6.0), lip=12.0)
    # ---- 两侧塔：前挑 fwd、加高到 tower_h、加垛口
    slit = win_rect("squint")
    for sx in (-1.0, 1.0):
        cx = sx * (gate_w / 2.0 + tw / 2.0)
        ty = yf - fwd / 2.0 + (D + fwd) / 2.0
        b.box_bottom((tw, D + fwd, tower_h - plinth_h), (cx, ty), plinth_h, "stone")
        for zf in (0.42, 0.66):
            arrow_slit(b, cx + sx * tw * 0.18, yf - fwd - 1.0 + 4.0,
                       plinth_h + (tower_h - plinth_h) * zf, slit["ow"], slit["oh"])
        quoins(b, tw, D + fwd, (tower_h - plinth_h) * 0.88, "stone", cx, ty,
               plinth_h + 24.0, size=min(20.0, tw * 0.18), step=56.0,
               front=False, sides=True)
        crenellation(b, tw - 6.0, D + fwd - 8.0, tower_h, "stone", cx, ty,
                     merlon=34.0, gap=18.0, h=32.0, band=15.0)
    # ---- 中央通道：arch_wall（拱洞穿深 = 一块带洞的 D 厚墙）
    arch_wall(b, gate_w, body_h, D, "stone", 0.0, ctr_y, plinth_h,
              openings=[(0.0, gate_w, plinth_h + 4.0, plinth_h + 4.0 + rect_h, head,
                         "round")])
    # 门道：后口封板（读作洞里的黑）+ 近口上方暗带 + 洞壁石基
    b.box((gate_w - 2.0, 26.0, clear), (0.0, yf + D - 20.0, plinth_h + 4.0 + clear / 2.0),
          "cavity")
    b.box((gate_w - 2.0, 34.0, clear * 0.5), (0.0, yf + 44.0,
                                              plinth_h + 4.0 + clear * 0.75), "cavity")
    for sx in (-1.0, 1.0):
        b.box_bottom((14.0, D, clear + 16.0), (sx * (gate_w / 2.0 - 7.0), ctr_y),
                     plinth_h + 4.0, "stone_dark")
    ring_stone(b, 0.0, yf - 2.0, plinth_h + 4.0 + rect_h, gate_w / 2.0 + 7.0,
               "white_stone", blocks=11, depth=22.0, thick=18.0, a0=0.0, a1=math.pi)
    for k in range(5):                            # 半落闸门（铁栅）
        px = -gate_w * 0.32 + gate_w * 0.64 * k / 4.0
        b.box_bottom((9.0, 9.0, clear * 0.42), (px, yf + 16.0),
                     plinth_h + 4.0 + clear * 0.56, "iron")
    b.box_bottom((gate_w * 0.72, 9.0, 9.0), (0.0, yf + 16.0),
                 plinth_h + 4.0 + clear * 0.96, "iron")
    # ---- 门道上方：突堞（machicolation：一道外挑牛腿带；不再做一排小牛腿 → 少噪点）
    b.box_bottom((gate_w + 16.0, 30.0, 15.0), (0.0, yf + 5.0),
                 plinth_h + 4.0 + clear + 14.0, "stone_dark")
    crenellation(b, gate_w - 6.0, D - 8.0, body_h, "stone", 0.0, ctr_y,
                 merlon=26.0, gap=15.0, h=32.0, band=15.0)

    ob = b.to_object()
    spec = _mk("gatehouse", width_cells, {
        "depth": D + fwd, "plinth_h": plinth_h, "wall_h": body_h, "eave_h": body_h,
        "rise": 47.0, "total_h": tower_h + 47.0, "overhang": 8.0, "roof_t": 0.0,
        "storey_h": [body_h], "door": None, "door_x": 0.0, "floor_h": None,
        "window": None, "gate": (gate_w, clear), "gate_clear": clear,
        "tower_h": tower_h, "ratio_band": (1.00, 1.60),
        "ratio_exempt": (width_cells < 12), "eave_exempt": True,
        "reason": "城门楼：城防体量（中央拱洞净高决定体量），6/8 格档剪影比超单层上界；"
                  "垛口压顶出挑 8（非民居坡檐）",
        "material": "石砌 + 白石隅石"})
    return ob, spec


def assemble_lighthouse(width_cells=6):
    """灯塔：收分塔身 + 环形石檐带 + 顶部灯室（自发光 lamp 材质）+ 门 + 小窗。"""
    t = LIGHTHOUSE_TIERS[width_cells]
    W = width_cells * CELL
    R, plinth_h = t["R"], t["plinth"]
    tower_h, taper = t["tower_h"], t["taper"]
    gal, lh, ch = t["gallery"], t["lantern_h"], t["cone_h"]
    door_w = t["door_w"]
    D = 2.0 * R
    top_r = R * taper
    yf = -R - 12.0

    b = Builder("lighthouse_w%d" % width_cells)
    contact_shadow(b, D, D, spread=28.0)
    b.cylinder((0.0, 0.0, plinth_h * 0.6), R * 1.16, plinth_h * 1.2, "stone_dark",
               segments=20)
    sec = tower_h / 3.0
    r_prev = R
    for k in range(3):
        r_next = R * (taper ** ((k + 1) / 3.0))
        b.cylinder((0.0, 0.0, plinth_h + sec * (k + 0.5)), r_prev, sec, "white_stone",
                   segments=20, taper=r_next / r_prev)
        if k:
            b.cylinder((0.0, 0.0, plinth_h + sec * k), r_prev * 1.10, 14.0, "stone",
                       segments=20)
        r_prev = r_next
    for zf in (0.30, 0.58):                       # 环形石檐带
        zz = plinth_h + tower_h * zf
        rr = R * (1.0 - (zz - plinth_h) / tower_h * (1.0 - taper))
        b.cylinder((0.0, 0.0, zz), rr * 1.09, 12.0, "stone", segments=20)
    z_top = plinth_h + tower_h
    # ---- 门（门廊真洞 + 门扇 + 圆券）+ 塔身小窗
    arched_doorway(b, 0.0, yf, 32.0, door_w, head=door_w * 0.5, mat="white_stone",
                   porch_w=door_w + 46.0)
    for zf in (0.44, 0.70):
        zz = plinth_h + tower_h * zf
        rr = R * (1.0 - (zz - plinth_h) / tower_h * (1.0 - taper))
        lw = win_rect("peephole", floor_z=zz, w_scale=0.84, h_scale=0.82)
        wy = -math.sqrt(max(4.0, rr * rr - (lw["ow"] * 0.5) ** 2)) + 1.0
        put_window(b, lw, 0.0, wy, frame_mat="stone_dark")
    # ---- 挑檐平台 + 栏杆 + 灯室（自发光）+ 顶盖
    b.cylinder((0.0, 0.0, z_top + gal * 0.5), top_r * 1.38, gal, "white_stone",
               segments=20)
    for k in range(14):
        th = 2.0 * math.pi * k / 14.0
        b.box_bottom((8.0, 8.0, 46.0), (math.cos(th) * top_r * 1.28,
                                        math.sin(th) * top_r * 1.28), z_top + gal, "iron")
    b.cylinder((0.0, 0.0, z_top + gal + 52.0), top_r * 1.38, 9.0, "iron", segments=20)
    lantern_room(b, 0.0, 0.0, z_top + gal + 14.0, top_r * 0.74, lh, roof_h=ch, posts=8)

    ob = b.to_object()
    spec = _mk("lighthouse", width_cells, {
        "depth": D, "plinth_h": plinth_h, "wall_h": tower_h, "eave_h": z_top,
        "rise": gal + lh + ch + 30.0,
        "total_h": z_top + gal + 14.0 + lh + 10.0 + ch + 30.0,
        "overhang": top_r * 0.22, "roof_t": 0.0, "storey_h": [tower_h],
        "door": (door_w, DOOR_H), "door_x": 0.0, "floor_h": FLOOR_H_SPEC,
        "window": None, "lamp": True, "round_tower": True,
        "ratio_exempt": True, "eave_exempt": True,
        "width_exempt": (width_cells < MIN_DOOR_CELLS),
        "reason": "灯塔：竖向塔体（塔身 + 灯室 + 锥顶）；灯室用自发光材质 lamp，"
                  "石檐带按塔半径比例（非民居坡檐口径）",
        "material": "白石砌 / 铅灰顶 + 自发光灯室"})
    return ob, spec


ASSEMBLERS["rowhouse"] = assemble_rowhouse
ASSEMBLERS["windmill"] = assemble_windmill
ASSEMBLERS["cathedral"] = assemble_cathedral
ASSEMBLERS["tower"] = assemble_tower
ASSEMBLERS["gatehouse"] = assemble_gatehouse
ASSEMBLERS["lighthouse"] = assemble_lighthouse

#: 本轮新增探针条目（追加在既有条目之后，不动既有）
PROBE_LIST += [("rowhouse", 12), ("windmill", 6), ("cathedral", 16),
               ("tower", 6), ("gatehouse", 8), ("lighthouse", 4)]


def print_ratio_metrics():
    """§8.7 米制自检：门/层高 ≈73%、窗高/层高 ≈45%、窗台 ≈0.90m + 现实米数标注。"""
    print("\n=== §8.7 米制自检（1px ≈ 1.31cm；1 格 = 32px ≈ 0.42m）===")
    print("%-10s %2s %8s %8s %8s %9s %8s %8s %8s"
          % ("def", "格", "现实宽m", "檐高m", "门/层高", "窗高/层高", "窗台m",
             "窗高m", "窗宽m"))
    for (name, wc) in PROBE_LIST:
        ob, spec = ASSEMBLERS[name](wc)
        fh, d, wn = spec.get("floor_h"), spec.get("door"), spec.get("window")
        dr = ("%.0f%%" % (d[1] / fh * 100.0)) if (d and fh) else "-"
        wr = ("%.0f%%" % (wn[1] / fh * 100.0)) if (wn and fh) else "-"
        print("%-10s %2d %8.2f %8.2f %8s %9s %8s %8s %8s"
              % (name, wc, wc * CELL / PX_PER_M, spec["eave_h"] / PX_PER_M, dr, wr,
                 ("%.2f" % (wn[2] / PX_PER_M)) if wn else "-",
                 ("%.2f" % (wn[1] / PX_PER_M)) if wn else "-",
                 ("%.2f" % (wn[0] / PX_PER_M)) if wn else "-"))
        bpy.data.objects.remove(ob, do_unlink=True)
    print("目标：门/层高 73%（门 150 / 层高 205）、窗高/层高 ≈45%、窗台 0.90m、"
          "窗宽 0.80~1.00m；单层檐高 2.6~2.7m、两层 5.2~5.4m、三层 7.8~8.1m")


if __name__ == "__main__":
    bpy.ops.wm.read_factory_settings(use_empty=True)
    print_specs()
    print_ratio_metrics()
