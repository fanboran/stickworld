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
* 出檐（每侧）= **绝对长度封顶 60**（EAVE_ABS_MAX，创始人 2026-09-16 定值；小建筑 ≤w6 维持 20.5% 现状=39）。旧「宽×20.5%」百分比口径在大建筑上绝对檐长过大（w16 达 105）
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
DOOR_H = 150.0              # 门净高（硬性）。人体锚链：火柴人 130（=1.70m）→ 门 150=1.15×人 → 层高带 196~212=1.5~1.63×人（门/挑高恒随人体锚，不随建筑宽变）
DOOR_W_RANGE = (45.0, 60.0)  # 单扇门宽允许区间
DOOR_SILL = 8.0             # 门槛高：门洞 z 从 8 到 158
# §8.2 长宽比硬口径：网格宽 : 剪影总高 = 1 : 0.85 ~ 1 : 1.5
RATIO_BAND = (0.85, 1.50)
#: §8.2 各宽度档的绝对剪影总高区间（用于自检打表）
GRID_H_BAND = {4: (109, 192), 6: (163, 288), 8: (218, 384),
               12: (326, 576), 16: (435, 768)}
#: §8.7 米制口径下的双层单列层高区间（200~207px = 2.62~2.71m；**取代 §8.2 的 175~195**：
#: 那一档对应"门占层高 85%"，正是创始人点名的病根，§8.7 已改判 2.6~2.7m）。
STOREY_H_BAND = (196.0, 212.0)
#: §8.2 出檐占建筑宽的比例区间（每侧）
EAVE_ABS_MAX = 60.0         # 出檐绝对封顶（2026-09-16 创始人定 60；39 过紧）
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

#: ---------------------------------------------------------------- 真倒角半径档
#: 见 `docs/技术/架构/美术品控-硬边与材质边缘.md` §2.1。半径是**几何硬口径**：
#: 全 12 棱 chamfer 后，每个面的角点沿两个面内轴各内缩 r，故投影剪影变化
#: ≈ r·sin(俯角)·(上端 + 下端)。game 0°/20° 下 = 2r·sin20° = 0.685r；check_spec
#: 12°/10° 下 = 0.342r。倒角面另写 `edge=1` 供材质混磨白层。
BEV_BIG = 2.0       # 建筑大件：梁 / 柱 / 檐口 / 窗台板 / 勒脚 / 台阶 / 垛口 / 隅石
BEV_MID = 1.5       # 木骨与家具板边 / 门框 / 封檐板
BEV_SMALL = 0.8     # 小件：瓦条、檩端、铁活、箍
BEV_SEG = 1         # 倒角段数：1 = 真 chamfer（本管线默认；2 只给需要圆角的柱头）
#: 实测口径（58 个 def×宽度档 A/B：倒角 ON vs OFF）：
#:   * check_spec 12°/10° 剪影 —— 最差 0.83 px，超 1px 条目 **0**；check_spec 判定翻转 0；
#:   * game 0°/20° 剪影 —— 宽 0.00（檐口外沿落在 y_out，不动宽度），高最差 1.37 px，
#:     全部来自"正脊压顶顶面 / 勒脚底面"这对极值端点被 r 内缩（2r·sin20°=1.37）；
#:     BEV_BIG 曾取 2.6 → 12/10 剪影 1.07 px（>1 打回），取 2.0 后守住 check_spec 口径。
#: 结论：**宽度（宽度纪律的约束量）零变化**；高度变化 ≤1.4px（≈栋高 0.3%，不可辨）。


def eave_over(grid_w):
    """出檐（每侧）= min(建筑宽 × 20.5%, 60 绝对封顶)：≤w6 小建筑维持现状观感（39），
    大建筑一律封到 60 绝对长度（旧百分比口径 w16 檐达 105，悬殊感来源）。"""
    return min(round(grid_w * 0.205), int(EAVE_ABS_MAX))


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
    # ---- D3b 追加：图书馆/学院的竖向长铅条窗（**固定宽**，不走开间比例，故不参与
    # 居室窗高带 lint）；h=124 是"大跨高窗"的显式自声明档，靠两扇成组读竖向。
    "tall_lead": dict(sill=69.0, h=124.0, w=44.0, muntins=0),           # 铅条高窗（成组）
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
    """把模块积木累积进一个 bmesh，最终吐出一个多材质槽对象（确定性）。

    真倒角（§2.1 硬边品控）
    ----------------------
    `box*` / `cylinder` 原语带 `bevel=<半径>` 即对该件做**真 chamfer**，倒角面写
    几何属性 `edge=1`，由 materials.py 读出来混"磨白层"（EEVEE 可用的边缘磨损）。
    不用 Blender `Bevel` modifier：本管线每个 `poly()` 都新建顶点 → 盒体是 6 张
    **互不焊接的散面**，modifier 会把所有边界边当棱切出错误几何；原语级倒角
    先按面组局部焊接再倒角，才切得到真正的可见棱。
    """

    def __init__(self, name, tile=CELL):
        self.name = name
        self.tile = tile           # UV 世界尺度：每 tile 单位重复一次（1 格 = 32px）
        self.bm = bmesh.new()
        self.uv = self.bm.loops.layers.uv.new("UVMap")
        #: 倒角面标记（FACE/FLOAT）：1 = 该面是磨出来的倒角带，材质读它做磨白
        self.edge_lay = self.bm.faces.layers.float.new("edge")
        self.bevel_stats = {"calls": 0, "faces": 0, "r_max": 0.0}
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

    def _project_uv(self, faces, uv_axes=None):
        """对倒角新面重做盒式投影 UV（与 `poly()` 同一规则）。

        bevel 会把相邻面的 UV 插值到倒角带上；直接投影比插值更准，而且与邻面
        在共享边上完全对齐（投影是世界空间的，跨面天然连续）。
        """
        t = self.tile
        for f in faces:
            if not f.is_valid:
                continue
            n = f.normal
            if n.length < 1e-9:
                continue
            ax = max(range(3), key=lambda i: abs(n[i]))
            for loop in f.loops:
                c = loop.vert.co
                if uv_axes is not None:
                    ua, va = uv_axes
                    loop[self.uv].uv = (c.dot(ua) / t, c.dot(va) / t)
                elif ax == 0:
                    loop[self.uv].uv = (c.y / t, c.z / t)
                elif ax == 1:
                    loop[self.uv].uv = (c.x / t, c.z / t)
                else:
                    loop[self.uv].uv = (c.x / t, c.y / t)

    def bevel_faces(self, faces, radius, segments=1, threshold=30.0, uv_axes=None):
        """对给定面组（一个原语）的**可见外棱**做真倒角，倒角面写 `edge=1`。

        * 先按面组局部焊接（见类注释：不焊接就没有"棱"）；
        * 只倒两面夹角 ≥ `threshold`（默认 30°）的边 —— 共面拼接缝不倒，
          所以 `wall_panel` 那种"多块箱体拼一面墙"不会切出假缝；
        * `segments`=1 真倒角 / 2 圆角过渡；`clamp_overlap` 防薄板倒角炸开；
        * `material=-1` → 倒角面继承相邻面材质（多材质槽对象不会被刷成槽 0）；
        * **半径纪律**：全棱 chamfer 后每个面的角点沿两个面内轴各内缩 r，故剪影变化
          随 r 线性增长（game 0/20 ≈ 0.685r px、check_spec 12/10 ≈ 0.342r px；实测见
          `BEV_BIG` 上方注释）。调用点一律用 BEV_BIG/BEV_MID/BEV_SMALL 三档，别写裸数字。
        """
        bm = self.bm
        fs = [f for f in faces if f.is_valid]
        if not fs or radius <= 0.0:
            return []
        vs = list({v for f in fs for v in f.verts})
        if len(vs) > 4:
            bmesh.ops.remove_doubles(bm, verts=vs, dist=1e-4)
        fs = [f for f in fs if f.is_valid]
        seen, geom = set(), []
        for f in fs:
            if not f.is_valid:
                continue
            for e in f.edges:
                if e in seen:
                    continue
                seen.add(e)
                if len(e.link_faces) != 2:      # 开口/非流形边：不是棱，跳过
                    continue
                try:
                    ang = math.degrees(e.calc_face_angle(0.0))
                except Exception:
                    ang = 0.0
                if ang >= threshold:
                    geom.append(e)
        if not geom:
            return []
        try:
            res = bmesh.ops.bevel(bm, geom=geom, offset=float(radius),
                                  offset_type='OFFSET', segments=int(segments),
                                  profile=0.5, affect='EDGES', clamp_overlap=True,
                                  loop_slide=True, material=-1)
        except Exception as exc:                 # 退化几何（零厚箱体等）：放弃倒角不报错
            print("[bevel] %s 放弃（%s）" % (self.name, exc))
            return []
        new = [f for f in res.get('faces', []) if f.is_valid]
        for f in new:
            f[self.edge_lay] = 1.0
        self._project_uv(new, uv_axes)
        self.bevel_stats["calls"] += 1
        self.bevel_stats["faces"] += len(new)
        self.bevel_stats["r_max"] = max(self.bevel_stats["r_max"], float(radius))
        return new

    def box_oriented(self, center, axes, half, mat, uv_axes=None, bevel=None,
                     bevel_segments=1, bevel_threshold=30.0, ends=None):
        """任意朝向长方体：center + (-1/1)*half[i]*axes[i]。axes 需右手系。

        bevel = 真倒角半径（None/0 = 不倒）；ends = (轴向量, 材质名)：把该件沿
        该轴两端的端面换成另一材质（木梁端面年轮、砖砌/板材端头收边）。
        """
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
        fs = []
        for q in quads:
            f = self.poly([v(*i) for i in q], mat, uv_axes=uv_axes)
            if f is not None:
                fs.append(f)
        if ends is not None and fs and ends[1]:
            ex, em = Vector(ends[0]), ends[1]
            if ex.length > 1e-9:
                ex = ex.normalized()
                si = self._slot(em)
                for f in fs:
                    n = _face_normal([vt.co for vt in f.verts])
                    if n is not None and abs(n.dot(ex)) > 0.9:
                        f.material_index = si
        if bevel:
            self.bevel_faces(fs, bevel, bevel_segments, bevel_threshold, uv_axes=uv_axes)
        return fs

    def box(self, size, center, mat, rot=None, uv_axes=None, bevel=None,
            bevel_segments=1, ends=None):
        """轴对齐（或给 rot=Euler 弧度三元组）长方体。size=(sx,sy,sz)，center=盒心。"""
        if rot is None:
            axes = (Vector((1, 0, 0)), Vector((0, 1, 0)), Vector((0, 0, 1)))
        else:
            m = Euler(rot, "XYZ").to_matrix()
            axes = (m.col[0], m.col[1], m.col[2])
        return self.box_oriented(center, axes, (size[0] / 2.0, size[1] / 2.0, size[2] / 2.0),
                                 mat, uv_axes=uv_axes, bevel=bevel,
                                 bevel_segments=bevel_segments, ends=ends)

    def box_bottom(self, size, xy, z_bottom, mat, rot=None, bevel=None,
                   bevel_segments=1, ends=None):
        """底面对齐版 box：xy=(x,y) 水平中心，z_bottom=底面高度。"""
        return self.box(size, (xy[0], xy[1], z_bottom + size[2] / 2.0), mat, rot,
                        bevel=bevel, bevel_segments=bevel_segments, ends=ends)

    def cylinder(self, center, radius, height, mat, segments=16, axis="Z", taper=1.0,
                 bevel=None, bevel_segments=1, bevel_threshold=30.0):
        """手写棱柱（规避 bmesh.ops API 漂移）。center=柱心，height=全长。

        bevel = 只倒**两端环棱**（相邻侧面夹角 = 360/segments < 30° 被阈值滤掉）。
        """
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
        fs = []
        for i in range(segments):
            j = (i + 1) % segments
            mid = (ring0[i] + ring0[j] + ring1[j] + ring1[i]) / 4.0
            f = self.poly([ring0[i], ring0[j], ring1[j], ring1[i]], mat, outward=(mid - c))
            if f is not None:
                fs.append(f)
        for f in (self.poly(list(reversed(ring0)), mat, outward=(-ax[2])),
                  self.poly(list(ring1), mat, outward=ax[2])):
            if f is not None:
                fs.append(f)
        if bevel and taper > 0.05:
            self.bevel_faces(fs, bevel, bevel_segments, bevel_threshold)

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


#: 木料族（端头封端用 wood_end = 端面年轮）
WOOD_MATS = ("wood", "wood_light", "wood_dark", "wood_roof", "wood_door",
             "timber", "plank_wall", "log_wall", "shingle", "bark")


def end_grain_mat(m):
    """给定构件材质 → 端头封端材质（木料 → 年轮；石材 → 细料石；其余不换）。"""
    if m in WOOD_MATS:
        return "wood_end"
    if m in ("stone", "stone_dark", "brick", "white_stone", "plaster"):
        return "white_stone"
    return None


def roof_gable(b, w, span, rise, overhang, mat, x=0.0, y=0.0, z=0.0,
               thickness=9.0, mat_under=None, gable_overhang=None, ridge_cap=True,
               cap_mat=None, cap_size=(0, 0), eave_board=True, board_mat=None,
               board_h=0.0, slope_uv=True, uv_swap=False, eave_ao=True,
               rafter_ends=3, eave_section=True, straw_eave=True, straw_ridge=True,
               ao_faces=None, ao_mat=None, ao_h=0.0, purlin_ext=(6.0, 14.0),
               tile_ends=True):
    """双坡屋顶（屋脊沿 X，正面朝 -Y，相机侧看到整片前坡）。

    w        = 屋脊方向覆盖的建筑宽度（X，不含出檐）
    span     = 坡面跨越的建筑进深（Y，不含出檐）
    rise     = 屋脊相对檐口高度（越大坡越陡、正面可见屋面越大）
    overhang = 出檐（§8.2：每侧 = 建筑宽 × 9~13%）
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
    ⑤ `tile_ends` 屋面板端头瓦当（仅瓦/石板顶）：每块瓦端加一个低段数圆盘封端
       （§2.2 端头封端）；压顶/封檐板/檩端另做真倒角 + 端面年轮（§2.1）。
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
        cm = cap_mat or ("stone_dark" if fam == "tile" else "wood_dark")
        cem = end_grain_mat(cm)
        b.box_bottom((ridge_len + 2.0, cw, cap_h), (x, y), z + rise - cap_h * 0.35,
                     cm, bevel=BEV_BIG, ends=((1, 0, 0), cem) if cem else None)
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
            fem = end_grain_mat(fmat)
            for sign in (-1.0, 1.0):
                ey = y + sign * half
                # 封檐板：竖直板条（6~10 高），坡度角下读到"檐口有厚度"
                # 顶棱是 20° 俯视下 **整栋最长的连续高光线** → BEV_MID 真倒角
                b.box_bottom((ridge_len - 1.0, 9.0, bh), (x, ey + sign * 1.0),
                             z - bh * 0.62, fmat, bevel=BEV_MID,
                             ends=((1, 0, 0), fem) if fem else None)
                # 瓦口/瓦条断面：一排瓦端（凸出封檐板 4~6、长短与高度抖动）
                n = max(6, min(44, int(round(ridge_len / 15.0))))
                for i in range(n):
                    u = -ridge_len / 2.0 + ridge_len * (i + 0.5) / n
                    sa_ = int(sign)
                    bw_ = 12.5 + 2.5 * _jit(i, 41 + sa_)
                    dp_ = 15.0 + 3.5 * _jit(i, 73 + sa_)
                    hh_ = 7.0 + 1.6 * _jit(i, 97 + sa_)
                    zt_ = z - 1.0 + 1.3 * _jit(i, 131 + sa_)
                    y_out = ey + sign * (2.5 + dp_ * 0.5)      # 原瓦条外端面 = 檐口外沿
                    if fam == "tile" and tile_ends:
                        # 瓦口瓦条**收短 2.6**、里端面不动，把最外一段让给瓦当圆盘：
                        # 檐口的几何外沿仍落在 y_out（剪影/包围盒零变化）。
                        dp2 = dp_ - 2.6
                        b.box_bottom((bw_, dp2, hh_),
                                     (x + u, y_out - sign * (dp2 * 0.5 + 2.6)), zt_, mat)
                        # 端头瓦当：圆盘外沿正好压在 y_out，半径收在瓦条高度之内。
                        # （这段不读"圆棒"——segment=6 + 只见端面，是瓦当的圆唇。）
                        b.cylinder((x + u, y_out - sign * 1.6, zt_ + hh_ * 0.5),
                                   hh_ * 0.46, 3.2, mat, segments=6, axis="Y",
                                   bevel=BEV_SMALL, bevel_threshold=70.0)
                    else:
                        b.box_bottom((bw_, dp_, hh_), (x + u, ey + sign * 2.5), zt_,
                                     fmat)
    elif eave_board:                                # 旧行为退路（eave_section=False）
        bh = board_h if board_h else max(7.0, thickness * 0.42)
        for sign in (-1.0, 1.0):
            b.box_bottom((ridge_len + 1.0, 9.0, bh), (x, y + sign * (half - 2.0)),
                         z - bh * 0.55, fmat, bevel=BEV_MID)
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
                    fem = end_grain_mat(fmat)
                    # 檩端：端面年轮是主要读法（§2.2），0.8 的倒角在 10 宽的端头上
                    # 只有 1.6 px 宽 → 不倒角，省 16×20 面。
                    b.box_bottom((ln, 10.0, ztop - zbot), (xc, yc), zbot, fmat,
                                 ends=((1, 0, 0), fem) if fem else None)
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
    # 门框是"梁/柱"族的立面主构件 → 真倒角（20° 俯视下门楣顶棱给一道高光线）
    b.box_bottom((frame, depth, h + frame), (x - w / 2.0 - frame / 2.0, y), z, frame_mat,
                 bevel=BEV_MID)
    b.box_bottom((frame, depth, h + frame), (x + w / 2.0 + frame / 2.0, y), z, frame_mat,
                 bevel=BEV_MID)
    b.box_bottom((w + 2 * frame, depth, frame), (x, y), z + h, frame_mat,
                 bevel=BEV_MID, ends=((1, 0, 0), "wood_end"))
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
        b.box_bottom((w + 2 * frame, 8.0, DOOR_SILL), (x, y), z - DOOR_SILL, "stone",
                     bevel=BEV_MID)
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

    def seg(a0, a1, o0, o1, z0, z1, m, bevel=None, ends=None):
        _seg(b, axis, origin, face_dir, a0, a1, o0, o1, z0, z1, m, bevel=bevel,
             ends=ends)

    ao, ai = depth / 2.0, -depth / 2.0
    # 木框：左右立柱 + 上楣 + 下槛（都比洞口外扩 frame）
    seg(u0 - ow / 2.0 - frame, u0 - ow / 2.0, ai, ao, z - frame, z + oh + frame,
        frame_mat, bevel=BEV_MID)
    seg(u0 + ow / 2.0, u0 + ow / 2.0 + frame, ai, ao, z - frame, z + oh + frame,
        frame_mat, bevel=BEV_MID)
    seg(u0 - ow / 2.0 - frame, u0 + ow / 2.0 + frame, ai, ao, z + oh, z + oh + frame,
        frame_mat, bevel=BEV_MID)
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
        # 窗台板 = §2.1 点名的高光带来源 → 真倒角 + 两端收边（端面换细料石）
        seg(u0 - ow / 2.0 - frame - 3.0, u0 + ow / 2.0 + frame + 3.0, ai, ao + 1.0,
            z - frame - 6.0, z - frame, "stone", bevel=BEV_MID,
            ends=("u", "white_stone"))
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
    b.box_bottom((w, d, h), (x, y), foot, mat, bevel=BEV_MID)
    # 基座石裙（两阶：下阶更宽更矮，上阶收窄）——烟囱根部落到地面/勒脚上
    b.box_bottom((w + 2.0 * skirt_lip, d + 2.0 * skirt_lip, skirt_h), (x, y), foot,
                 "stone", bevel=BEV_BIG)
    b.box_bottom((w + 1.1 * skirt_lip, d + 1.1 * skirt_lip, skirt_h * 0.55), (x, y),
                 foot + skirt_h, "stone_dark", bevel=BEV_MID)
    if roof is not None:
        _roof_flash(b, x, y, w, d, roof, up=flash_up,
                    out=flash_out if flash_out > 0.0 else max(12.0, w * 0.44),
                    mat=flash_mat)
    cap_mat = cap_mat or mat
    b.box_bottom((w + 12.0, d + 12.0, cap), (x, y), top, cap_mat, bevel=BEV_BIG,
                 ends=((1, 0, 0), "white_stone"))
    if flue:
        b.cylinder((x, y, top + cap + 6.0), min(w, d) * 0.36, 12.0, "iron", segments=12)
    return {"h": h, "w": w, "top": top + cap, "foot": foot, "roof": roof}


#: 台基/勒脚总开关：HD-2D 卡片烘焙侧置 False（创始人 2026-09-15：地面灰白台基
#: 别烘进卡，引擎侧 base_cut 裁剪随之退役）；2D bake_export 管线不置此值，
#: 默认 True 照常生成，不受影响。
PLINTH_ENABLED = True


def plinth(b, w, d, h, mat="stone_dark", x=0.0, y=0.0, z=0.0, gap=None, lip=8.0,
           bevel=BEV_BIG):
    """勒脚/台基：比墙体外扩 lip。gap=(x0,x1) 时为门洞留缺口（另加门槛石）。

    顶面↔立面的转折是 20° 俯视下最主要的高光带来源 → 默认真倒角（可 bevel=0 关）。
    """
    if not PLINTH_ENABLED:
        return None
    if gap is None:
        b.box_bottom((w + 2 * lip, d + 2 * lip, h), (x, y), z, mat, bevel=bevel)
    else:
        for (sx0, sx1) in _solid_segments((x - w / 2.0 - lip, x + w / 2.0 + lip),
                                          [(x + gap[0], x + gap[1])]):
            b.box_bottom((sx1 - sx0, d + 2 * lip, h), ((sx0 + sx1) / 2.0, y), z, mat,
                         bevel=bevel)
    return {"h": h, "lip": lip}


def step_stone(b, w=76.0, depth=26.0, h=10.0, x=0.0, y=0.0, z=0.0, mat="stone",
               bevel=BEV_BIG):
    """门前台阶石。y 应传墙面前方（-Y 方向）。"""
    b.box_bottom((w, depth, h), (x, y), z, mat, bevel=bevel)


def post(b, size=16.0, h=190.0, mat="wood", x=0.0, y=0.0, z=0.0, d=None,
         bevel=BEV_BIG):
    """立柱（方截面 size×size，可另给 d 作 Y 向深度）。"""
    b.box_bottom((size, d or size, h), (x, y), z, mat, bevel=bevel)
    return {"size": size, "h": h}


def beam(b, length, size=14.0, depth=None, mat="wood", x=0.0, y=0.0, z=0.0, axis="X",
         bevel=BEV_BIG, end_mat="wood_end"):
    """横梁（默认沿 X）。z = 梁底。

    端头封端：两端端面换 `wood_end`（端面年轮）—— 长条木料的端面在 20° 俯视下
    正对镜头，不封端就是"贴图硬切在棱上"的典型病灶。
    """
    d = depth or size
    size_v = (length, d, size) if axis == "X" else (d, length, size)
    ends = None
    if end_mat:
        ends = ((1, 0, 0) if axis == "X" else (0, 1, 0), end_mat)
    b.box_bottom(size_v, (x, y), z, mat, bevel=bevel, ends=ends)


def strut(b, p1, p2, size=10.0, mat="wood", bevel=BEV_MID):
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
    b.box_oriented((a + c) / 2.0, (d, u, w), (L / 2.0, size / 2.0, size / 2.0), mat,
                   bevel=bevel)


def _pt(axis, origin, fdir, u, o, z):
    """局部墙面坐标 → 世界坐标。

    u = 沿墙方向（相对墙心）；o = 垂直墙面的偏移（>=0 朝凸出面）；z = 绝对高度。
    axis="X"：origin=(墙心 x, 墙面 y)，凸出方向 = fdir*Y
    axis="Y"：origin=(墙面 x, 墙心 y)，凸出方向 = fdir*X
    """
    if axis == "X":
        return (origin[0] + u, origin[1] + fdir * o, z)
    return (origin[0] + fdir * o, origin[1] + u, z)


def _seg(b, axis, origin, fdir, u0, u1, o0, o1, z0, z1, mat, bevel=None, ends=None):
    """局部墙面坐标里的一个长方体段。

    bevel = 真倒角半径；ends = ("u"|"z"|None, 材质)：把该段沿该局部轴的一端端面
    换材质（木板端头年轮 / 砖石收边）。
    """
    c = _pt(axis, origin, fdir, (u0 + u1) / 2.0, (o0 + o1) / 2.0, (z0 + z1) / 2.0)
    if axis == "X":
        size = (abs(u1 - u0), abs(o1 - o0), abs(z1 - z0))
    else:
        size = (abs(o1 - o0), abs(u1 - u0), abs(z1 - z0))
    ev = None
    if ends is not None:
        which, emat = ends
        if which == "u":
            ev = ((1.0, 0.0, 0.0) if axis == "X" else (0.0, 1.0, 0.0), emat)
        elif which == "z":
            ev = ((0.0, 0.0, 1.0), emat)
    b.box(size, c, mat, bevel=bevel, ends=ev)


def timber_frame(b, w, h, mat="timber", origin=(0.0, 0.0), z=0.0, depth=7.0,
                 post=12.0, top_band=16.0, mid_band=None, bays=3, braces=True,
                 openings=(), axis="X", face_dir=-1.0, embed=3.0, bevel=BEV_MID):
    """木骨架（半露木/木骨墙）：上下横带 + 竖柱 + 斜撑，贴墙面凸出。

    origin / axis / face_dir 见 `_pt`。openings=[(u, ow), ...] 为洞口（u 相对墙心），
    竖柱与斜撑自动避让洞口，避免木骨横穿门窗。
    木骨是"梁"族 → 默认真倒角（20° 俯视下横带的顶棱就是立面高光线）。
    """
    half = w / 2.0
    o_in, o_out = -embed, depth - embed

    def seg(u0, u1, z0, z1, m=None):
        _seg(b, axis, origin, face_dir, u0, u1, o_in, o_out, z0, z1, m or mat,
             bevel=bevel)

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
            strut(b, pt(u0 + 3.0, zb), pt(u1 - 3.0, zt), post * 0.7, mat, bevel=bevel)
            strut(b, pt(u1 - 3.0, zb), pt(u0 + 3.0, zt), post * 0.7, mat, bevel=bevel)


def gable_timber(b, span, rise, mat="timber", origin=(0.0, 0.0), z=0.0,
                 axis="X", face_dir=-1.0, depth=7.0, embed=3.0, thick=11.0,
                 tie=True, king=True, collar=0.42, bevel=BEV_MID):
    """山墙三角面的木骨（戗檐斜梁 + 中柱 + 系梁），全部落在三角形内部。"""
    half = span / 2.0

    def seg(u0, u1, z0, z1):
        _seg(b, axis, origin, face_dir, u0, u1, -embed, depth - embed, z0, z1, mat,
             bevel=bevel)

    def pt(u, zz):
        return _pt(axis, origin, face_dir, u, (depth - 2 * embed) / 2.0, zz)

    if tie:
        seg(-half + thick, half - thick, z, z + thick * 0.8)
    for sx in (-1.0, 1.0):                       # 戗檐斜梁：沿三角形两腰
        strut(b, pt(sx * (half - thick * 0.6), z + 2.0), pt(0.0, z + rise - 4.0),
              thick, mat, bevel=bevel)
    if king:
        seg(-thick / 2.0, thick / 2.0, z, z + rise - 6.0)
    if collar:
        zc = z + rise * collar
        hu = half * (1.0 - collar) * 0.92
        seg(-hu, hu, zc, zc + thick * 0.7)


def plank_siding(b, w, h, mat="wood", origin=(0.0, 0.0), z=0.0, plank_w=20.0,
                 gap=2.0, depth=5.0, openings=(), jitter=2.0, seed=1,
                 axis="X", face_dir=-1.0, gable_rise=0.0, embed=3.2, top_jitter=4.0,
                 bevel=BEV_MID, end_mat="wood_end"):
    """竖向木板饰面（谷仓/木屋/山墙）：一排竖板贴墙面，按洞口裁切。

    gable_rise > 0 时板顶按三角形轮廓收（用于山墙满铺竖板）。
    openings = [(u, ow, z0, z1), ...]（u 相对墙心，z 为绝对高度）。
    板端封端：上下端面换 `wood_end`（端面年轮）——竖板端头正对 20° 俯视镜头，
    不封端就是一排"贴图被切断"的竖条。
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
                 -embed, depth - embed + jt, za, zb, mat, bevel=bevel,
                 ends=("z", end_mat) if end_mat else None)


def railing(b, w, x=0.0, y=0.0, z=0.0, mat="wood", h=60.0, posts=4, size=9.0):
    """栏杆/矮栏（棚屋前沿、二层挑台）。z = 栏底。"""
    b.box_bottom((w, size, 8.0), (x, y), z + h - size, mat, bevel=BEV_SMALL)
    for i in range(max(2, posts)):
        px = x - w / 2.0 + size / 2.0 + (w - size) * i / float(max(2, posts) - 1)
        b.box_bottom((size, size, h), (px, y), z, mat, bevel=BEV_SMALL)


def barrel(b, x=0.0, y=0.0, z=0.0, r=15.0, h=40.0, mat="wood", band_mat="iron",
           segments=12, lid=False):
    """木桶（带两道铁箍）。"""
    b.cylinder((x, y, z + h / 2.0), r, h, mat, segments=segments, bevel=BEV_SMALL)
    for t in (0.18, 0.82):
        b.cylinder((x, y, z + h * t), r * 1.06, 5.0, band_mat, segments=segments,
                   bevel=BEV_SMALL)
    if lid:
        b.cylinder((x, y, z + h + 1.0), r * 0.94, 3.0, "wood_dark", segments=segments)


def anvil(b, x=0.0, y=0.0, z=0.0, mat="iron", stump=True):
    """铁砧（含可选木墩）：总高约 60。"""
    if stump:
        b.cylinder((x, y, z + 20.0), 17.0, 40.0, "wood_dark", segments=12, bevel=BEV_SMALL)
        base_z = z + 40.0
    else:
        base_z = z
    b.box_bottom((34.0, 20.0, 7.0), (x, y), base_z, mat, bevel=BEV_SMALL)        # 底座
    b.box_bottom((18.0, 15.0, 15.0), (x, y), base_z + 7.0, mat, bevel=BEV_SMALL)  # 腰
    b.box_bottom((45.0, 19.0, 10.0), (x, y), base_z + 22.0, mat, bevel=BEV_SMALL)  # 砧面
    b.cylinder((x + 28.0, y, base_z + 27.0), 6.5, 22.0, mat, segments=10, axis="X",
               taper=0.35)


def forge(b, x=0.0, y=0.0, z=0.0, w=54.0, d=46.0, body_h=64.0, mat="iron",
          masonry="stone_dark", flue_h=196.0, wall=11.0, flue_r=9.0):
    """铁炉：砖石基座 + 炉体（**前面留真炉口**，内见火光）+ 炉罩 + 烟管。

    炉体由左右/后/顶/底五块板拼成，前方开口 -> 炉膛与火焰真实可见。
    """
    b.box_bottom((w + 14.0, d + 12.0, 16.0), (x, y), z, masonry, bevel=BEV_MID)   # 砖石基座
    z0 = z + 16.0
    top_h = 12.0
    b.box_bottom((wall, d, body_h), (x - w / 2.0 + wall / 2.0, y), z0, mat, bevel=BEV_SMALL)   # 左板
    b.box_bottom((wall, d, body_h), (x + w / 2.0 - wall / 2.0, y), z0, mat, bevel=BEV_SMALL)   # 右板
    b.box_bottom((w - 2 * wall, wall, body_h), (x, y + d / 2.0 - wall / 2.0), z0, mat,
                 bevel=BEV_SMALL)
    b.box_bottom((w, d, top_h), (x, y), z0 + body_h - top_h, mat, bevel=BEV_SMALL)  # 炉顶
    b.box_bottom((w - 2 * wall, d - wall, 12.0), (x, y + wall * 0.5), z0, mat)   # 炉底
    fw = w - 2 * wall - 4.0
    b.box_bottom((fw, 6.0, body_h - top_h - 16.0), (x, y + d / 2.0 - wall - 5.0),
                 z0 + 14.0, "wood_dark")                                  # 炉膛暗腔
    # 火光必须落在**炉口内**（y 靠前），否则被炉体挡住整块看不见
    b.box_bottom((fw - 6.0, 5.0, 34.0), (x, y - d / 2.0 + wall + 6.0),
                 z0 + 16.0, "fire")
    b.box_bottom((fw - 6.0, 20.0, 6.0), (x, y - d / 2.0 + wall + 12.0),
                 z0 + 16.0, "ember")                                      # 炉口炭层
    b.box_bottom((w * 0.74, d * 0.74, 12.0), (x, y), z0 + body_h, mat,
                 bevel=BEV_SMALL)                                         # 炉台
    b.box_bottom((24.0, 24.0, 14.0), (x, y), z0 + body_h + 12.0, mat,
                 bevel=BEV_SMALL)                                         # 炉罩
    top = z0 + body_h + 26.0
    b.cylinder((x, y, top + flue_h / 2.0), flue_r, flue_h, mat, segments=12)
    b.cylinder((x, y, top + flue_h + 5.0), flue_r * 1.25, 7.0, mat, segments=12)
    return {"top": top + flue_h, "fire_z": z0 + 18.0}



def bench(b, x=0.0, y=0.0, z=0.0, w=64.0, d=30.0, h=48.0, mat="wood"):
    """工作台/长凳。"""
    b.box_bottom((w, d, 7.0), (x, y), z + h - 7.0, mat, bevel=BEV_MID,
                 ends=((1, 0, 0), "wood_end"))
    for sx in (-1.0, 1.0):
        for sy in (-1.0, 1.0):
            b.box_bottom((8.0, 8.0, h - 7.0),
                         (x + sx * (w / 2.0 - 8.0), y + sy * (d / 2.0 - 8.0)), z, mat,
                         bevel=BEV_SMALL)


def stool(b, x=0.0, y=0.0, z=0.0, r=13.0, h=30.0, mat="wood"):
    """圆凳。"""
    b.cylinder((x, y, z + h - 4.0), r, 8.0, mat, segments=10, bevel=BEV_SMALL)
    for i in range(3):
        th = 2 * math.pi * i / 3.0
        b.box_bottom((6.0, 6.0, h - 8.0),
                     (x + math.cos(th) * r * 0.55, y + math.sin(th) * r * 0.55), z, mat,
                     bevel=BEV_SMALL)


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
    8:  dict(D=170.0, plinth=12.0, wall=275, rise=118.0, wt=20.0, leaf=58.0),
    12: dict(D=200.0, plinth=14.0, wall=275, rise=124.0, wt=22.0, leaf=62.0),
    16: dict(D=224.0, plinth=16.0, wall=275, rise=128.0, wt=22.0, leaf=62.0),
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
        "eave_ok": spec.get("eave_exempt") or (spec["overhang"] <= EAVE_ABS_MAX + 0.5),
        # 坡度下限（2026-09-16）：26° 俯角下 rise < (进深/2+出檐)×tan26° 会露出背面坡
        "pitch_ok": spec.get("eave_exempt") or spec.get("open_shed") or
                    (spec.get("rise", 0.0) <= 0.0) or
                    (spec["rise"] >= (spec["depth"] / 2.0 + spec["overhang"]) * math.tan(math.radians(26.0))),
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
                 band=16.0, band_lip=8.0, bevel=BEV_BIG):
    """垛口：外挑压顶走道 + 前后沿/侧沿交替垛子。z = 压顶底。

    垛子顶面在 20° 俯视下是城墙上唯一的高光点（§2.1 点名必倒角）。
    """
    b.box_bottom((w + 2.0 * band_lip, d + 2.0 * band_lip, band), (x, y), z, mat,
                 bevel=BEV_MID)
    nx = max(2, int(round(w / (merlon + gap))))
    stepx = w / float(nx)
    mw = max(18.0, stepx * 0.62)
    for i in range(nx):
        px = x - w / 2.0 + stepx * (i + 0.5)
        for sy in (-1.0, 1.0):
            b.box_bottom((mw, 18.0, h), (px, y + sy * (d / 2.0 - 9.0)), z + band, mat,
                         bevel=bevel)
    ny = max(1, int(round(d / (merlon + gap))))
    stepy = d / float(ny)
    md = max(18.0, stepy * 0.62)
    for i in range(ny):
        py = y - d / 2.0 + stepy * (i + 0.5)
        for sx in (-1.0, 1.0):
            b.box_bottom((18.0, md, h), (x + sx * (w / 2.0 - 9.0), py), z + band, mat,
                         bevel=bevel)


def quoins(b, w, d, h, mat="white_stone", x=0.0, y=0.0, z=0.0, size=24.0,
           step=40.0, front=True, sides=True, bevel=BEV_BIG):
    """角部隅石：竖边依次交替的凸出料石（塔/石宅边角读法）。

    隅石本身就是石墙转角处的"收边石"（§2.2 第 5 条）→ 每块都倒角。
    """
    n = max(1, int(h / step))
    for i in range(n):
        zz = z + i * step
        hh = min(step * 0.58, z + h - zz)
        if hh < 6.0:
            break
        for sx in (-1.0, 1.0):
            if front:
                b.box_bottom((size, 14.0, hh), (x + sx * (w / 2.0 - size * 0.24),
                                                y - d / 2.0 + 3.0), zz, mat, bevel=bevel)
            if sides:
                b.box_bottom((14.0, size, hh), (x + sx * (w / 2.0 - 3.0),
                                                y - d / 2.0 + d * 0.18), zz, mat,
                             bevel=bevel)


def buttress(b, x, y, z, w, h, depth=20.0, mat="stone", cap_h=24.0,
             cap_mat="white_stone", bevel=BEV_BIG):
    """扶壁：竖向墩 + 斜顶帽。y 为墩心（凸出正立面）。"""
    b.box_bottom((w, depth, h - cap_h), (x, y), z, mat, bevel=bevel)
    b.box_bottom((w + 6.0, depth + 6.0, 8.0), (x, y), z + h - 4.0, cap_mat, bevel=bevel)


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
#: 8 格档 = **小礼拜堂**（单钟楼、中殿压到一层半）：村档的核心 landmark 就是它，
#: 塔顶仍要压过村内一切建筑；剪影比走"单钟楼档"豁免（见 assemble_cathedral 的 reason）。
CATHEDRAL_TIERS = {
    8:  dict(D=176.0, plinth=16.0, nave_h=345.0, rise=104.0, wt=18.0, twin=False,
             tower_w=92.0, tower_h=372.0, spire_h=88.0, portal_w=70.0,
             leaf=32.0, rose_r=38.0, rose_z=196.0),
    12: dict(D=200.0, plinth=18.0, nave_h=535.0, rise=136.0, wt=22.0, twin=False,
             tower_w=124.0, tower_h=560.0, spire_h=118.0, portal_w=88.0,
             leaf=42.0, rose_r=54.0, rose_z=298.0),
    16: dict(D=232.0, plinth=20.0, nave_h=535.0, rise=150.0, wt=24.0, twin=True,
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
                  "（非民居坡檐口径，eave_exempt）",
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
        rose_window(b, 0.0, yf - 6.0, rose_z, rose_r, spokes=10,
                    glass=magic_key(GLASS_STAINED))
    else:
        rose_window(b, 0.0, yf - 12.0 - tw - 4.0, plinth_h + nave_h * 0.72, rose_r,
                    spokes=10, glass=magic_key(GLASS_STAINED))
    inner = pw / 2.0 if twin else tw / 2.0
    outer = (W / 2.0 - tw) if twin else W / 2.0
    ox = (inner + outer) / 2.0
    if ox + 36.0 < outer - 16.0:
        for sx in (-1.0, 1.0):
            lancet_window(b, sx * ox, yf - 4.0, plinth_h + 130.0, lanc["ow"],
                          lanc["oh"], head=lanc["ow"] * 0.52,
                          glass=magic_key(GLASS_LEAD))
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
                      lanc["oh"], head=lanc["ow"] * 0.52,
                      glass=magic_key(GLASS_LEAD)) if twin else None
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
        "storey_h": [body_h], "tower_sections": 3,
        "door": (door_w, DOOR_H), "door_x": 0.0,
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
# ---------------------------------------------------------------- 7.x 大修道院 abbey

ABBEY_TIERS = {
    # 24 格超宽连体：石塔**左端顶格**（塔左面=建筑左端，创始人 2026-09-16：塔顶格、
    # 塔面与翼楼同一面墙）+ 向右一整条厚重石砌翼楼；塔占位段无屋顶——坡顶只在塔右侧
    # 一整条（rise=100：下限=(进深/2+出檐)×tan26°≈90，再浅露背面坡——创始人实测发现；100 仍比旧 128 矮 22%）。塔身总高 ≈ 922 远超屋脊（548），
    # "左塔右殿"天际线 landmark。翼楼两层等高（檐口 448），上层仅一排 4 个小盲窗
    # （禁域：极少开窗、大面积光秃石墙），主入口开在塔底，翼楼无门。
    24: dict(D=250.0, plinth=24.0, tw=150.0, th=770.0, spire_h=112.0,
             wing_h=424.0, rise=100.0, wt=26.0, portal_w=56.0,
             proj=2.0),
}


def assemble_abbey(width_cells=24):
    """大修道院：左侧高耸石塔（大幅前凸冲街，全高可见）+ 向右延伸的巨型厚重石砌翼楼。

    塔身：底层真拱主入口 + 四层细缝窗 + 角扶壁 + 白石腰线 + 钟楼双联盲拱 + 矮锥顶；
    翼楼外墙无门无真窗，仅上层一排小盲窗，大面积光秃石墙；扶壁均布贴脚；
    石板瓦长坡顶（脊沿 X，正面见坡面）。
    """
    t = ABBEY_TIERS[width_cells]
    W = width_cells * CELL
    D, plinth_h = t["D"], t["plinth"]
    tw, th, sh = t["tw"], t["th"], t["spire_h"]
    wing_h, rise, wt = t["wing_h"], t["rise"], t["wt"]
    pw = t["portal_w"]
    tx = -W / 2.0 + tw / 2.0                    # 塔左端顶格（塔左面=建筑左端）
    proj = t["proj"]                            # 塔面嵌缝余量（≈0：与翼楼墙面共面一体）
    eave = plinth_h + wing_h
    ridge = eave + rise
    yf = -D / 2.0
    ty = yf - proj + tw / 2.0                   # 塔面与翼楼前墙共面（proj=嵌缝 2）
    ty_face = ty - tw / 2.0                     # 塔正立面 y

    b = Builder("abbey_w%d" % width_cells)
    contact_shadow(b, W, D, spread=34.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0, lip=12.0)

    # ---- 翼楼（整条厚重石墙，无门，上层仅一排小盲窗）+ 扶壁均布
    room_shell(b, W, D, plinth_h, wing_h, wt, "stone_dark")
    win_n = 4
    x0 = tx + tw / 2.0                            # 窗带从塔右缘起算（不浪费在塔后）
    for i in range(win_n):
        cx = x0 + (W / 2.0 - x0) * (i + 0.5) / float(win_n)
        blind_arch(b, cx, yf - wt / 2.0 - 1.0, eave - 112.0, 14.0, 38.0,
                   mat="cavity", ring="white_stone", blocks=4, depth=8.0)
    nb = max(3, int(round(W / 190.0)))
    for i in range(nb):
        bx = -W / 2.0 + W * (i + 0.5) / float(nb)
        if abs(bx - tx) < tw / 2.0 + 30.0:
            continue                              # 塔身占位段不放扶壁
        buttress(b, bx, yf + 4.0, plinth_h, 28.0, wing_h * 0.58, depth=28.0,
                 cap_h=20.0, mat="stone")

    # ---- 翼楼长坡顶：单段，自塔右面起到右端（塔占位段无屋顶——创始人口径）
    over = eave_over(W)
    sw = W / 2.0 - (tx + tw / 2.0)
    scx = tx + tw / 2.0 + sw / 2.0
    roof_gable(b, sw, D, rise, over, "slate", x=scx, z=eave, thickness=16.0,
               mat_under="wood_dark", cap_size=(26.0, 13.0), cap_mat="stone_dark",
               eave_board=False, gable_overhang=0.0)   # 山墙出檐归零：左端终止于塔面（不穿模塔）
    # 山墙填充：右端为外露山墙；左端三角落在塔右侧体内（同材质深色，接缝不可见）
    gable_infill(b, sw, D, rise, "stone_dark", z=eave, thickness=14.0)
    # ---- 屋面终止于塔身的收头：檐板端面用石砌肩块盖住（前檐交角）
    b.box_bottom((10.0, 26.0, 54.0), (tx + tw / 2.0 + 3.0, yf - over + 8.0),
                 eave - 14.0, "stone_dark")

    # ---- 左侧高耸石塔（大幅前凸，冲出翼楼屋脊）----
    b.box_bottom((tw, tw, th - plinth_h), (tx, ty), plinth_h, "stone")
    # 角扶壁：正面两角竖向墩（哥特塔角读法），暗色与亮塔身对比才读得出墩条
    for sx in (-1.0, 1.0):
        buttress(b, tx + sx * (tw / 2.0 - 15.0), ty_face + 16.0, plinth_h,
                 36.0, th * 0.52, depth=34.0, cap_h=24.0, mat="stone_dark")
    # 底层主入口（修道院门开在塔底，圆拱头真拱洞 + 白石拱券 + 单扇木门）
    arched_doorway(b, tx, ty_face - 6.0, 30.0, pw, DOOR_H, head=22.0, mat="stone",
                   profile="round", leaves=1, porch_w=pw + 36.0,
                   sill=False, step=True)
    step_stone(b, w=pw + 60.0, depth=26.0, h=10.0, x=tx, y=ty_face - 40.0)
    # 细缝窗四层：中段三层（门上起、逐层升高）+ 高段一层（腰线之上）
    for k in range(3):
        blind_arch(b, tx, ty_face - 1.0, plinth_h + 166.0 + k * 130.0,
                   13.0, 42.0, mat="cavity", depth=8.0)
    # 白石腰线：钟楼段与塔身的分界（钟楼段读法）
    b.box_bottom((tw + 14.0, tw + 14.0, 14.0), (tx, ty), th - 200.0, "white_stone")
    blind_arch(b, tx, ty_face - 1.0, th - 160.0, 13.0, 42.0, mat="cavity", depth=8.0)
    # 钟楼双联盲拱（加大加宽）+ 矮锥顶
    belf = win_rect("belfry")
    for sx in (-1.0, 1.0):
        blind_arch(b, tx + sx * tw * 0.25, ty_face - 1.0, th - 104.0,
                   tw * 0.28, belf["oh"], tw * 0.20, mat="cavity",
                   ring="white_stone", blocks=6, depth=10.0)
    b.box_bottom((tw + 16.0, tw + 16.0, 16.0), (tx, ty),
                 plinth_h + (th - plinth_h), "white_stone")
    cone_roof(b, tx, ty, plinth_h + (th - plinth_h) + 16.0, tw / 2.0 * 1.16, sh,
              "slate", segments=8)
    b.cylinder((tx, ty, plinth_h + (th - plinth_h) + 16.0 + sh + 8.0), 7.0, 18.0,
               "iron", segments=8)

    ob = b.to_object()
    spec = _mk("abbey", width_cells, {
        "depth": D, "plinth_h": plinth_h, "wall_h": wing_h, "eave_h": eave,
        "rise": rise, "total_h": plinth_h + th + sh + 16.0, "overhang": over,
        "roof_t": 16.0, "storey_h": [wing_h * 0.5, wing_h * 0.5],
        "door": (pw, DOOR_H), "door_x": tx,
        "roof_mat": "slate",
        "window": (14.0, 38.0, eave - 112.0 - plinth_h),
        "ratio_band": None,
        "reason": "超宽连体天际线件：塔+翼楼一体（塔超出翼楼屋脊属竖向 landmark，豁免）",
        "material": "厚石墙 / 石板瓦长坡顶（修女院禁域翼楼）"})
    return ob, spec


ASSEMBLERS["cathedral"] = assemble_cathedral
ASSEMBLERS["abbey"] = assemble_abbey
ASSEMBLERS["tower"] = assemble_tower
ASSEMBLERS["gatehouse"] = assemble_gatehouse
ASSEMBLERS["lighthouse"] = assemble_lighthouse

#: 本轮新增探针条目（追加在既有条目之后，不动既有）
PROBE_LIST += [("rowhouse", 12), ("windmill", 6), ("cathedral", 16),
               ("tower", 6), ("gatehouse", 8), ("lighthouse", 4)]


# ================================================================ §7 民用装配器（批次 D3a）
#
# 9 个新 def：cottage / tavern / bakery / shop / guildhall / hayloft / smithy2~4。
# 纪律：**只新增函数与常量**——既有模块（roof_gable / chimney / wall_panel / …）与既有
# 参数表一律不动，既有 10 栋的剪影必须逐像素不变；窗一律走 §0.5 窗规格表
# （`win_rect` / `bay_openings` / `put_window`），屋顶一律走 `roof_gable`（二轮结构：
# 檐口断面 / 檐下 AO / 檩条端头 / 草檐草束），烟囱一律走 `chimney`（落地 + 泛水裙）。
# 每个 def 与最接近的既有栋至少 2 项肉眼可辨差异（剪影 / 材质 / 开窗 / 屋顶结构）。


def roof_dormer(b, x, y, roof_z, w=76.0, h=60.0, depth=46.0, rise=22.0,
                mat="tile", wall_mat="plaster", frame_mat="timber", over=8.0,
                embed=30.0, sill=24.0, win_h=30.0, win_w=38.0):
    """前坡老虎窗（天窗）：屋面局部凸起的小山墙体量 + 正面小窗。

    `y` = 窗体中心（负值，落在前坡上）；`roof_z` = **该 y 处的屋面高**（调用方用
    `gable_roof_z()` 算）。体量向下埋 `embed`、向上露 `h` —— 埋深必须大于"前脸
    处屋面比窗体中心低"的差值，否则前脸下缘悬在坡上（读作浮盒）。
    窗走窗表 `garret` 档（阁楼小窗、真洞，`w=win_w` 覆写固定宽）。
    """
    z_base = roof_z - embed
    yf = y - depth / 2.0
    b.box_bottom((w, depth, h), (x, y), z_base, wall_mat)
    roof_gable_y(b, w, depth, rise, over, mat, x, y, z=z_base + h, thickness=11.0,
                 over_y=over, cap_size=(22.0, 10.0), cap_mat="wood_dark",
                 board_mat="wood_dark", board_h=7.0)
    wh = win_rect("garret", over=dict(w=win_w, h=win_h))
    wh["cx"] = x
    wh["z0"] = z_base + sill
    wh["z1"] = wh["z0"] + wh["oh"]
    put_window(b, wh, x, yf, frame_mat=frame_mat)
    return {"z_base": z_base, "zt": z_base + h + rise, "yf": yf}


def door_pentice(b, x, y_wall, z, w=104.0, depth=46.0, drop=28.0, mat="wood_roof",
                 board_mat="wood_dark", brace_mat="timber", seat_mat="timber",
                 braces=True):
    """门前披檐（单坡小木棚，**不落地**）：贴墙侧高、外缘低，两根斜撑托住。

    与道具层 `awning` 的分工：那个是布篷（市集/店铺），这个是木石小披檐（村舍/工坊）。
    `z` = 贴墙侧檐口高（应在门楣之上 20~40）；`depth` = 前伸量；外缘低 `drop`。
    """
    ln = math.hypot(depth, drop)
    ang = math.atan2(drop, depth)
    b.box((w, ln, 8.0), (x, y_wall - depth / 2.0, z - drop / 2.0), mat,
          rot=(ang, 0.0, 0.0))
    b.box_bottom((w, 7.0, 10.0), (x, y_wall - depth), z - drop - 4.0, board_mat)
    for sx in (-1.0, 1.0):
        b.box_bottom((9.0, 7.0, 12.0), (x + sx * (w / 2.0 - 4.5), y_wall - 3.0),
                     z + 4.0, seat_mat)
        if braces:
            strut(b, (x + sx * (w / 2.0 - 9.0), y_wall - 2.0, z - 24.0),
                  (x + sx * (w / 2.0 - 9.0), y_wall - depth + 7.0, z - drop + 5.0),
                  8.0, brace_mat)
    return {"front_y": y_wall - depth, "z": z - drop}


def hang_sign_iron(b, x, y_wall, z_top, reach=58.0, w=52.0, h=40.0,
                   mat="wood_dark", iron="iron", emblem="cloth_red"):
    """铁艺挂招牌（**建筑自带**，不依赖道具层）：墙面铁座 + 上翘挑臂 + 双吊环 + 木牌。

    `z_top` = 牌顶高（牌体占 z_top-h ~ z_top）。
    为什么自带：道具层 `hanging_sign` 在 townhouse 配方里排第 9 位，窄立面
    （12 格 + 1.45 倍道具）会被 `pack_sides()` 从尾部丢掉 —— 招牌是酒馆的识别符号，
    不能靠概率。
    """
    yb = y_wall - reach * 0.88
    b.box_bottom((10.0, 7.0, h * 1.6), (x, y_wall - 3.0), z_top - h * 1.2, iron)
    strut(b, (x, y_wall - 4.0, z_top + h * 0.34), (x, y_wall - reach, z_top + h * 0.18),
          6.0, iron)
    strut(b, (x, y_wall - 4.0, z_top - h * 1.05), (x, y_wall - reach * 0.62,
                                                   z_top - h * 0.34), 5.0, iron)
    for sx in (-1.0, 1.0):
        b.box_bottom((3.4, 3.4, 12.0), (x + sx * (w * 0.28), yb), z_top - 4.0, iron)
    b.box((w, 4.5, h), (x, yb, z_top - h / 2.0), mat)
    b.box((w * 0.58, 3.0, h * 0.52), (x, yb - 3.2, z_top - h / 2.0), emblem)
    b.box((w + 5.0, 6.0, 4.5), (x, yb, z_top + h * 0.02), iron)
    b.box((w + 5.0, 6.0, 4.5), (x, yb, z_top - h * 0.98), iron)
    return {"x": x, "z0": z_top - h}


def awning_rail(b, w, y_wall, z, x=0.0, mat="iron", hooks=5, drop=9.0):
    """雨篷挂点：一道铁横杆 + 一排吊环（道具层 `awning` 挂在这条高度上）。

    位置纪律：横杆压在**上层悬挑之下、一层窗楣之上** —— 布篷才读作"从二楼伸出来的"。
    """
    b.box_bottom((w, 8.0, 8.0), (x, y_wall - 4.0), z, mat)
    for i in range(max(2, int(hooks))):
        px = x - w / 2.0 + w * (i + 0.5) / hooks
        b.box_bottom((4.0, 4.0, drop), (px, y_wall - 6.0), z - drop, mat)
        b.cylinder((px, y_wall - 6.0, z - drop - 5.0), 5.0, 3.0, mat, segments=8,
                   axis="Y")
    return {"z": z}


def shop_window(b, x, w, y_wall, z_sill, h, pier=11.0, lights=3,
                frame_mat="timber", counter_mat="wood_light", fascia=True):
    """橱窗（大玻璃开间）：木框 + 竖向分格 + 外挑柜台板 + 上檐封板。

    洞口由调用方在墙板上开出（本件只做框/玻璃/柜台/封檐），玻璃凹进墙面 3。
    `z_sill` = 台面高（玻璃底），`h` = 玻璃高。
    """
    b.box_bottom((w + 2.0 * pier + 8.0, 18.0, 12.0), (x, y_wall - 10.0),
                 z_sill - 12.0, counter_mat)                      # 外挑柜台板
    b.box((w, 5.0, h), (x, y_wall + 3.0, z_sill + h / 2.0), "glass")
    for k in range(1, max(2, int(lights))):
        px = x - w / 2.0 + w * k / float(lights)
        b.box_bottom((7.0, 8.0, h), (px, y_wall + 1.0), z_sill, frame_mat)
    for sx in (-1.0, 1.0):
        b.box_bottom((pier, 9.0, h + 12.0),
                     (x + sx * (w / 2.0 + pier / 2.0), y_wall + 1.0),
                     z_sill - 12.0, frame_mat)
    b.box_bottom((w + 2.0 * pier, 11.0, 15.0), (x, y_wall + 1.0), z_sill + h,
                 frame_mat)
    if fascia:
        b.box_bottom((w + 2.0 * pier + 16.0, 8.0, 13.0), (x, y_wall - 3.0),
                     z_sill + h + 15.0, "wood_dark")
    return {"z0": z_sill, "z1": z_sill + h}


def iron_rack(b, w, x=0.0, y_wall=0.0, z=0.0, mat="iron", pieces=3, hook=True):
    """晾铁架（横杆 + 吊钩 + 挂着的铁件）：铁匠工坊"还在干活"的识别件。

    贴 4 面的版本（`axis` 由调用方决定前/侧墙）；`z` = 下横杆高。
    """
    y0 = y_wall - 6.0
    b.box_bottom((w, 7.0, 7.0), (x, y0), z, mat)
    b.box_bottom((w, 7.0, 7.0), (x, y0), z + 58.0, mat)
    for sx in (-1.0, 1.0):
        b.box_bottom((7.0, 12.0, 64.0), (x + sx * (w / 2.0 - 4.0), y0 - 2.0), z, mat)
    n = max(1, int(pieces))
    for i in range(n):
        px = x - w / 2.0 + w * (i + 0.5) / n
        j0, j1 = _jit(i, 211), _jit(i, 223)
        if hook:
            b.box_bottom((3.4, 3.4, 10.0), (px, y0), z + 56.0, mat)
        b.box_bottom((9.0 + 5.0 * abs(j0), 3.0, 26.0 + 16.0 * (0.5 + 0.5 * j1)),
                     (px, y0 - 3.0), z + 24.0, "iron")
    return {"z": z}


def iron_rack_side(b, x_wall, y_c, z, length=64.0, mat="iron", pieces=3,
                   hook=True):
    """侧墙晾铁架（沿 Y 贴在 ±X 外皮上）：横杆 + 吊钩 + 挂着的铁件。

    与 `iron_rack()` 的分工：那个贴正面（游戏中可读），这个贴侧墙（**"侧挂位"**，
    正面视角看不见，属工坊院落的侧面装备位）。
    """
    fd = 1.0 if x_wall > 0 else -1.0
    x0 = x_wall + fd * 6.0
    b.box_bottom((7.0, length, 7.0), (x0, y_c), z, mat)
    b.box_bottom((7.0, length, 7.0), (x0, y_c), z + 58.0, mat)
    for sy in (-1.0, 1.0):
        b.box_bottom((12.0, 7.0, 64.0),
                     (x0 - fd * 2.0, y_c + sy * (length / 2.0 - 4.0)), z, mat)
    n = max(1, int(pieces))
    for i in range(n):
        py = y_c - length / 2.0 + length * (i + 0.5) / n
        j0, j1 = _jit(i, 227), _jit(i, 229)
        if hook:
            b.box_bottom((3.4, 3.4, 10.0), (x0, py), z + 56.0, mat)
        b.box_bottom((3.0, 9.0 + 5.0 * abs(j0), 24.0 + 12.0 * (0.5 + 0.5 * j1)),
                     (x0 - fd * 3.0, py), z + 26.0, "iron")
    return {"z": z}


def baker_peel(b, x, y_wall, z, ln=112.0, mat="wood_light", iron="iron",
               blade=46.0):
    """面包铲挂墙（长柄 + 铲头 + 铁挂座）：面包房的识别件。"""
    b.box_bottom((7.0, 7.0, ln), (x, y_wall - 5.0), z, mat)
    b.box_bottom((blade, 4.0, blade * 0.78), (x, y_wall - 6.0), z + ln - blade * 0.74,
                 mat)
    b.box_bottom((blade * 0.66, 3.0, 5.0), (x, y_wall - 7.6), z + ln - 11.0,
                 "wood_dark")
    b.box_bottom((18.0, 5.0, 9.0), (x, y_wall - 3.0), z + ln - 56.0, iron)
    return {"top": z + ln}


def hay_heap(b, x=0.0, y=0.0, z=0.0, w=112.0, d=52.0, h=44.0, rows=2, seed=0):
    """草垛（干草棚开口里的干草捆）：**方形草捆**垒两层 + 草绳捆扎 + 前沿散草。

    为什么不做圆顶草堆：圆顶在"微俯视 + 棚内暗部光照"下会被读成**金属碗**
    （实测两轮都是灰绿反光的碗形）——方捆的体积感与"一堆草"的读法在任何光线下
    都稳，且前沿散草负责"草垛外露"的碎边。
    """
    bw = w / 2.35
    for r in range(max(1, int(rows))):
        n = 2 if r == 0 else 1
        for i in range(n):
            j0, j1 = _jit(i * 3 + r, 601 + seed), _jit(i * 5 + r, 617 + seed)
            cx = x + (i - (n - 1) / 2.0) * (bw + 7.0) + 5.0 * j0
            cz = z + r * h * 0.60
            b.box_bottom((bw * (1.0 + 0.05 * j1),
                          d * (0.86 + 0.12 * (0.5 + 0.5 * j0)), h * 0.70),
                         (cx, y + 4.0 * j1), cz, "straw")
            for k in (-1.0, 1.0):                       # 草绳两道
                b.box_bottom((4.5, d * 0.92, h * 0.76), (cx + k * bw * 0.27, y),
                             cz, "rope")
    n = max(4, int(round(w / 22.0)))
    for i in range(n):                                  # 前沿散草（碎边，吃光）
        j0, j1, j2 = _jit(i, 401 + seed), _jit(i, 419 + seed), _jit(i, 433 + seed)
        px = x - w * 0.5 + w * (i + 0.5) / n
        b.box_bottom((6.0 + 3.0 * abs(j0), 30.0 + 9.0 * abs(j1), 10.0 + 4.0 * j2),
                     (px, y - d * 0.52 + j2 * 3.0), z + h * 0.42, "straw")
    return {"h": h}


def water_wheel(b, x, y, z, r=62.0, mat="wood_dark", iron="iron", spokes=8,
                segs=18, width=26.0, paddles=14):
    """水轮（**轮面在 XZ 平面、面向观众** —— 与 `windmill` 的帆同一约定）。

    轮圈用切向分段（**不是实心圆盘**：实心会读作圆牌），外侧一圈斗板，
    轴心一根铁轴。挂在 2D 侧视游戏里，只有"朝观众"的轮才读得出是能转的轮。
    """
    for sy in (-1.0, 1.0):
        yy = y + sy * width * 0.5
        for k in range(segs):
            a = 2.0 * math.pi * (k + 0.5) / segs
            ca, sa = math.cos(a), math.sin(a)
            axes = (Vector((ca, 0.0, sa)), _Y_AXIS, Vector((-sa, 0.0, ca)))
            b.box_oriented((x + ca * r, yy, z + sa * r), axes,
                           (7.0, 5.0, math.pi * r / segs * 1.15), mat)
    for k in range(spokes):
        a = 2.0 * math.pi * (k + 0.5) / spokes
        strut(b, (x, y, z), (x + math.cos(a) * r * 0.97, y,
                             z + math.sin(a) * r * 0.97), 10.0, mat)
    for k in range(max(6, int(paddles))):
        a = 2.0 * math.pi * (k + 0.5) / max(6, int(paddles))
        ca, sa = math.cos(a), math.sin(a)
        axes = (Vector((ca, 0.0, sa)), _Y_AXIS, Vector((-sa, 0.0, ca)))
        b.box_oriented((x + ca * r * 0.90, y, z + sa * r * 0.90), axes,
                       (r * 0.14, width * 0.44 + 4.0, 4.0), mat)
    b.cylinder((x, y, z), r * 0.16, width + 22.0, iron, segments=14, axis="Y")
    return {"r": r}


# ---------------------------------------------------------------- 7.1 村舍 cottage

COTTAGE_TIERS = {
    # 6 格 = 小屋（§8.7 允许 183px=2.4m 层高）；8 格带门层抬到 200px=2.62m（门占 75%）
    6: dict(D=120.0, plinth=14.0, wall=182.0, rise=76.0, wt=16.0, door_w=48.0,
            ch_w=28.0, ch_up=18.0, ratio_band=(0.85, 1.70)),
    8: dict(D=152.0, plinth=14.0, wall=200.0, rise=94.0, wt=18.0, door_w=52.0,
            ch_w=30.0, ch_up=30.0, ratio_band=None),
}


def assemble_cottage(width_cells=8):
    """茅草村舍：单层矮墙 + 陡茅草顶 + 阁楼小窗 + **正立面落地烟囱（冲出屋脊）** + 门头披檐。

    与 `house` 的差异（≥2 项肉眼可辨）：
    ① 材质：做旧抹灰 `plaster_old` + 带窗板的 `chamber` 档窗 —— house 是干净抹灰 + `pitch`；
    ② 剪影：烟囱落在**门与首窗之间的墙垛**上、贴墙面落地、顶冲出屋脊 20~30
       （house 的烟囱压在屋脊之下，屋檐线上看不到）；
    ③ 门头披檐（斜撑式小雨棚，不落地）—— house 没有；
    ④ 6 格档单层：门（150）+ 楣梁 的下限令檐高 ≥195、进深 3.75 格 ⇒ 剪影/宽算术必超
       1.5（沿用既有豁免机制，见 spec.ratio_band 与 reason）。
    """
    t = COTTAGE_TIERS[width_cells]
    W = width_cells * CELL
    D, plinth_h, wall_h, rise = t["D"], t["plinth"], t["wall"], t["rise"]
    wt, door_w = t["wt"], t["door_w"]
    over = eave_over(W)
    eave = plinth_h + wall_h
    yf = -D / 2.0
    bays = bays_of(width_cells)
    dx, wins = bay_openings(W, bays, "chamber", door_w=door_w, door_bay=0,
                            floor_z=plinth_h, w_scale=0.88)
    side_w = win_rect("side", bay_w=D, floor_z=plinth_h)
    side_w["u"] = -D * 0.18
    gable_w = win_rect("garret", bay_w=D * 0.5, floor_z=eave)
    gable_w["u"] = -D * 0.12

    b = Builder("cottage_w%d" % width_cells)
    contact_shadow(b, W, D, spread=24.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(dx - door_w / 2.0 - 6.0, dx + door_w / 2.0 + 6.0), lip=9.0)
    room_shell(b, W, D, plinth_h, wall_h, wt, "plaster_old",
               front_openings=[(dx, door_w, DOOR_SILL, DOOR_SILL + DOOR_H)]
                              + win_holes(wins),
               side_openings=[(side_w["u"], side_w["ow"], side_w["z0"],
                               side_w["z1"])])
    timber_frame(b, W, wall_h, "timber", (0.0, yf), plinth_h, depth=6.0, post=12.0,
                 top_band=15.0, bays=bays, braces=True,
                 openings=[(dx, door_w)] + [(w["cx"], w["ow"]) for w in wins])
    door(b, h=DOOR_H, w=door_w, mat="wood_door", x=dx, y=yf, z=DOOR_SILL,
         frame_mat="timber", frame=7.0, planks=3)
    step_stone(b, w=door_w + 28.0, depth=22.0, h=9.0, x=dx, y=yf - 15.0)
    for w in wins:
        put_window(b, w, w["cx"], yf, frame_mat="timber")
    put_window(b, side_w, side_w["u"], W / 2.0, axis="Y", face_dir=1.0,
               frame_mat="timber")
    door_pentice(b, dx, yf, plinth_h + DOOR_SILL + DOOR_H + 24.0, w=door_w + 54.0,
                 depth=44.0, drop=26.0)
    roof_gable(b, W, D, rise, over, "thatch", z=eave, thickness=19.0,
               mat_under="wood_dark", cap_size=(32.0, 15.0), board_h=10.0,
               rafter_ends=3, purlin_ext=(6.0, 13.0))
    gable_infill(b, W, D, rise, "plaster_old", z=eave, thickness=14.0,
                 hole=(gable_w["u"], gable_w["ow"], gable_w["z0"],
                       gable_w["z1"]))
    for sx in (-1.0, 1.0):
        gable_timber(b, D, rise, "timber", (sx * (W / 2.0), 0.0), eave,
                     axis="Y", face_dir=sx, thick=10.0)
        put_window(b, gable_w, gable_w["u"], sx * (W / 2.0), axis="Y",
                   face_dir=sx, frame_mat="timber")
    # 烟囱：落点 = 门右缘与首窗左缘的中点（**不压门洞/窗洞**），贴墙面落地、冲出屋脊
    ch_w = t["ch_w"]
    w0 = wins[0]
    ch_x = ((dx + door_w / 2.0) + (w0["cx"] - w0["ow"] / 2.0)) / 2.0
    ch_y = yf + 11.0
    ch_top = eave + rise + t["ch_up"]
    ch_roof = gable_roof_z(eave, rise, D / 2.0 + over, ch_y)
    chimney(b, ch_w, 26.0, ch_top, "stone_dark", ch_x, ch_y, foot=0.0,
            cap_mat="white_stone", cap=11.0, roof=ch_roof, skirt_h=18.0,
            skirt_lip=7.0)

    ob = b.to_object()
    spec = _mk("cottage", width_cells, {
        "depth": D, "plinth_h": plinth_h, "wall_h": wall_h, "eave_h": eave,
        "rise": rise, "total_h": ch_top + 11.0, "overhang": over, "roof_t": 19.0,
        "storey_h": [wall_h], "door": (door_w, DOOR_H), "door_x": dx, "bays": bays,
        "side_windows": 1, "roof_mat": "thatch",
        "window": (w0["ow"], w0["oh"], w0["z0"] - plinth_h),
        "gable_window": (gable_w["ow"], gable_w["oh"], gable_w["u"],
                          gable_w["z0"]),
        "chimneys": [{"x": ch_x, "y": ch_y, "roof": ch_roof, "top": ch_top + 11.0,
                      "foot": 0.0, "w": ch_w, "d": 26.0}],
        "ratio_band": t["ratio_band"],
        "reason": ("6 格档单层带门：檐高下限 195（门 150 + 楣梁）+ 进深 3.75 格 + "
                   "屋脊烟囱 ⇒ 剪影/宽算术必超 1.5（窄面村舍体量）"
                   if t["ratio_band"] else ""),
        "material": "做旧抹灰+木骨 / 茅草顶 + 石砌烟囱"})
    return ob, spec


# ---------------------------------------------------------------- 7.2 酒馆 tavern

TAVERN_TIERS = {
    # 带门层 200px = 2.62m（门占 75%，§8.7 点名"门占层高 74% 才自然"）
    12: dict(D=208.0, plinth=18.0, storey=229, rise=104.0, wt=20.0, door_w=58.0,
             jetty=10.0, ch_w=30.0, dorm_x=(0.26, -0.26), dorm_f=0.60, dorm_h=60.0),
    16: dict(D=232.0, plinth=20.0, storey=229, rise=120.0, wt=22.0, door_w=58.0,
             jetty=11.0, ch_w=34.0, dorm_x=(0.28, -0.28), dorm_f=0.62, dorm_h=62.0),
}


def assemble_tavern(width_cells=12):
    """酒馆：石砌公共层（隅石）+ 抹灰木骨上层（前挑 jetty）+ **前坡双老虎窗** + 铁艺挂招牌。

    与 `townhouse` 的差异（≥2 项肉眼可辨）：
    ① 材质：一层 `stone`（+ 转角隅石 `quoins`）、上层抹灰木骨 —— townhouse 一层也是抹灰；
    ② 屋顶结构：前坡两个**老虎窗**（老虎窗自带人字顶 + 阁楼小窗）—— townhouse 是光坡；
    ③ 开窗：一层大窗（`street` 档放大 1.12 倍，酒馆的"公共间"玻璃）+ 上层 `hall`，
       一层门窗上下不对位；
    ④ 立面自带**铁艺挂招牌**（挑臂 + 吊环 + 木牌，挂在门侧上层窗间）。
    """
    t = TAVERN_TIERS[width_cells]
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
    half = (D + jetty) / 2.0 + over
    bays = bays_of(width_cells)
    cs = bay_centers(W, bays)
    bw = W / float(bays)
    dx, wins1 = bay_openings(W, bays, WIN_LOW, door_w=door_w, door_bay=0,
                             floor_z=plinth_h, w_scale=1.12, h_scale=1.06)
    _d2, wins2 = bay_openings(W, bays, WIN_UP, floor_z=z2)
    side_w = win_rect(WIN_SIDE, bay_w=D, floor_z=plinth_h, shutters=True)
    side_w["u"] = -D * 0.16

    b = Builder("tavern_w%d" % width_cells)
    contact_shadow(b, W, D + jetty, spread=30.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(dx - door_w / 2.0 - 6.0, dx + door_w / 2.0 + 6.0), lip=10.0)
    # ---- 一层：石砌公共间（墙角隅石 + 大窗 + 大门）
    room_shell(b, W, D, plinth_h, sh, wt, "stone",
               front_openings=[(dx, door_w, DOOR_SILL, DOOR_SILL + DOOR_H)]
                              + win_holes(wins1),
               side_openings=[(side_w["u"], side_w["ow"], side_w["z0"],
                               side_w["z1"])])
    quoins(b, W - 2.0 * wt, D, sh * 0.96, "white_stone", 0.0, yf1 + wt / 2.0,
           plinth_h + 4.0, size=22.0, step=42.0, front=False, sides=True)
    door(b, w=door_w, mat="wood_door", x=dx, y=yf1, z=DOOR_SILL, planks=4,
         frame_mat="timber")
    step_stone(b, w=door_w + 34.0, depth=26.0, h=10.0, x=dx, y=yf1 - 18.0)
    for w in wins1:
        put_window(b, w, w["cx"], yf1)
    put_window(b, side_w, side_w["u"], W / 2.0, axis="Y", face_dir=1.0)
    # ---- 二层：抹灰 + 木骨（前挑 jetty）
    wall_panel(b, W, sh, D + jetty, "plaster", 0.0, yc2, z2,
               openings=win_holes(wins2))
    for i in range(5):
        px = -W / 2.0 + 14.0 + (W - 28.0) * i / 4.0
        b.box_bottom((14.0, 18.0, 14.0), (px, yf2 + 9.0), z2 - 14.0, "timber")
    b.box_bottom((W + 6.0, 9.0, 16.0), (0.0, yf2), z2 - 16.0, "timber")
    timber_frame(b, W, sh, "timber", (0.0, yf2), z2, depth=7.0, post=14.0,
                 top_band=14.0, bays=bays, braces=True,
                 openings=[(w["cx"], w["ow"]) for w in wins2])
    for w in wins2:
        put_window(b, w, w["cx"], yf2)
    # ---- 屋顶（二轮结构全开）+ 前坡双老虎窗
    roof_gable(b, W, D + jetty, rise, over, "tile", z=eave, thickness=15.0,
               mat_under="wood_dark", cap_size=(30.0, 16.0), board_h=9.0,
               ao_faces=(yf2, yb), y=yc2)
    for fx in t["dorm_x"]:
        yd = yc2 - (D + jetty) * 0.5 * t["dorm_f"] - over * t["dorm_f"]
        roof_dormer(b, fx * W, yd, gable_roof_z(eave, rise, half, yd, y_ridge=yc2),
                    w=max(62.0, W * 0.17), h=t["dorm_h"], depth=46.0, rise=22.0,
                    mat="tile", wall_mat="plaster", embed=30.0)
    gable_w = win_rect(WIN_GABLE, bay_w=(D + jetty) * 0.5, floor_z=eave)
    gable_w["u"] = -D * 0.14
    gable_infill(b, W, D + jetty, rise, "plaster", z=eave, thickness=14.0, y=yc2,
                 hole=(gable_w["u"], gable_w["ow"], gable_w["z0"], gable_w["z1"]))
    for sx in (-1.0, 1.0):
        gable_timber(b, D + jetty, rise, "timber", (sx * (W / 2.0), yc2), eave,
                     axis="Y", face_dir=sx, thick=11.0)
        put_window(b, gable_w, gable_w["u"], sx * (W / 2.0), axis="Y", face_dir=sx)
    # ---- 铁艺挂招牌：挂在**上层两窗之间的墙垛**上（挂在窗间才不挡窗）
    sg_x = cs[1] + bw / 2.0
    hang_sign_iron(b, sg_x, yf2, z2 + sh * 0.82, w=54.0, h=40.0)
    # ---- 烟囱：落地（贴二层前墙外皮），柱顶压在屋脊之下（不抬剪影）
    ch_x = cs[0] + bw / 2.0
    ch_y = yf2 - 13.0
    ch_top = eave + rise - 16.0
    ch_roof = gable_roof_z(eave, rise, half, ch_y, y_ridge=yc2)
    chimney(b, t["ch_w"], 26.0, ch_top, "brick", ch_x, ch_y, foot=0.0,
            cap_mat="stone_dark", cap=12.0, roof=ch_roof)

    ob = b.to_object()
    spec = _mk("tavern", width_cells, {
        "depth": D + jetty, "plinth_h": plinth_h, "wall_h": sh * 2.0, "eave_h": eave,
        "rise": rise, "total_h": eave + rise, "overhang": over, "roof_t": 15.0,
        "storey_h": [sh, sh], "double_storey": True, "door": (door_w, DOOR_H),
        "door_x": dx, "jetty": jetty, "bays": bays, "dormers": 2,
        "window": (wins1[0]["ow"], wins1[0]["oh"], wins1[0]["z0"] - plinth_h),
        "window_up": (wins2[0]["ow"], wins2[0]["oh"], wins2[0]["z0"] - z2),
        "gable_window": (gable_w["ow"], gable_w["oh"], gable_w["u"],
                          gable_w["z0"]),
        "chimneys": [{"x": ch_x, "y": ch_y, "roof": ch_roof, "top": ch_top + 12.0,
                      "foot": 0.0, "w": t["ch_w"], "d": 26.0}],
        "sign_x": sg_x, "material": "石砌+白石膏线 / 抹灰木骨 / 陶瓦 + 老虎窗"})
    return ob, spec


def free_gap(w_half, blocks, pad=6.0):
    """在立面 [-w_half+pad, +w_half-pad] 上找一个**最宽的空档**：(宽, 中心 x)。

    `blocks` = 已占用的绝对 x 区间（门/窗含框外扩）。烟囱、晾铁架这类必须落在
    "不压门洞/窗洞的墙垛"上的构件用它定位 —— 逐 def 手写偏移量一换宽度档就失效。
    """
    segs = _solid_segments((-w_half + pad, w_half - pad), blocks)
    if not segs:
        return 0.0, 0.0
    w, (x0, x1) = max((s1 - s0, (s0, s1)) for (s0, s1) in segs)
    return w, (x0 + x1) / 2.0


def wall_blocks(dx, door_w, wins, frame=8.0, extra=()):
    """门 + 窗（含框外扩）+ 额外占用 → `free_gap()` 的占用区间表。"""
    out = []
    if door_w:
        out.append((dx - door_w / 2.0 - frame, dx + door_w / 2.0 + frame))
    out += [(w["cx"] - w["ow"] / 2.0 - frame, w["cx"] + w["ow"] / 2.0 + frame)
            for w in wins]
    out += list(extra)
    return out


# ---------------------------------------------------------------- 7.3 面包房 bakery

BAKERY_TIERS = {
    # 带门层 200px = 2.62m（门占 75%）
    8: dict(D=160.0, plinth=16.0, wall=221, rise=96.0, wt=18.0, door_w=52.0,
            ch_w=34.0, ch_d=30.0, ch_up=22.0, win_scale=1.25),
    12: dict(D=196.0, plinth=18.0, wall=221, rise=104.0, wt=20.0, door_w=56.0,
             ch_w=34.0, ch_d=30.0, ch_up=30.0, win_scale=1.25),
}


def assemble_bakery(width_cells=8):
    """面包房：砖砌单层 + **超大橱窗式窗**（`street` 档放 1.25 倍）+ **穿出屋脊的粗烟囱** + 挂墙面包铲。

    与 `house` 的差异（≥2 项肉眼可辨）：
    ① 材质：砖墙 + 白石窗楣/门楣线脚 —— house 是抹灰木骨；
    ② 开窗：临街大窗（临街档 1.25 倍宽、1.08 倍高，0.80→1.15m 宽的"看货窗"）；
    ③ 剪影：烟囱比屋脊高 20~30（house 压在屋脊之下）；
    ④ 门侧挂**面包铲**（长柄 + 铲头）—— 面包房的识别件。
    """
    t = BAKERY_TIERS[width_cells]
    W = width_cells * CELL
    D, plinth_h, wall_h, rise = t["D"], t["plinth"], t["wall"], t["rise"]
    wt, door_w = t["wt"], t["door_w"]
    over = eave_over(W)
    eave = plinth_h + wall_h
    yf = -D / 2.0
    bays = bays_of(width_cells)
    door_bay = bays - 1                       # 门居中偏右：两侧留"看货窗"
    dx, wins = bay_openings(W, bays, WIN_LOW, door_w=door_w, door_bay=door_bay,
                            floor_z=plinth_h, w_scale=t["win_scale"], h_scale=1.08)
    side_w = win_rect(WIN_SIDE, bay_w=D, floor_z=plinth_h)
    side_w["u"] = -D * 0.20

    b = Builder("bakery_w%d" % width_cells)
    contact_shadow(b, W, D, spread=28.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(dx - door_w / 2.0 - 6.0, dx + door_w / 2.0 + 6.0), lip=10.0)
    room_shell(b, W, D, plinth_h, wall_h, wt, "brick",
               front_openings=[(dx, door_w, DOOR_SILL, DOOR_SILL + DOOR_H)]
                              + win_holes(wins),
               side_openings=[(side_w["u"], side_w["ow"], side_w["z0"],
                               side_w["z1"])])
    quoins(b, W - 2.0 * wt, D, wall_h * 0.94, "white_stone", 0.0, yf + wt / 2.0,
           plinth_h + 4.0, size=20.0, step=44.0, front=False, sides=True)
    door(b, h=DOOR_H, w=door_w, mat="wood_door", x=dx, y=yf, z=DOOR_SILL,
         frame_mat="timber", frame=8.0, planks=3)
    b.box_bottom((door_w + 26.0, 12.0, 13.0), (dx, yf - 4.0),
                 plinth_h + DOOR_SILL + DOOR_H + 10.0, "white_stone")   # 白石门楣
    step_stone(b, w=door_w + 34.0, depth=26.0, h=10.0, x=dx, y=yf - 18.0)
    for w in wins:
        put_window(b, w, w["cx"], yf)                 # 临街大窗（白石窗楣）
        b.box_bottom((w["ow"] + 22.0, 12.0, 12.0), (w["cx"], yf - 4.0),
                     w["z1"] + 10.0, "white_stone")
    put_window(b, side_w, side_w["u"], W / 2.0, axis="Y", face_dir=1.0)
    roof_gable(b, W, D, rise, over, "tile", z=eave, thickness=15.0,
               mat_under="wood_dark", cap_size=(28.0, 16.0), board_h=9.0)
    gable_infill(b, W, D, rise, "brick", z=eave, thickness=14.0)
    # ---- 高烟囱：落在门与邻窗之间的墙垛（不压洞），落地 + 穿屋面泛水 + 冲出屋脊
    gap_w, ch_x = free_gap(W / 2.0, wall_blocks(dx, door_w, wins))
    ch_y = yf + 12.0
    ch_top = eave + rise + t["ch_up"]
    ch_roof = gable_roof_z(eave, rise, D / 2.0 + over, ch_y)
    chimney(b, t["ch_w"], t["ch_d"], ch_top, "brick", ch_x, ch_y, foot=0.0,
            cap_mat="white_stone", cap=13.0, roof=ch_roof, skirt_h=22.0,
            skirt_lip=9.0, flue=True)
    # ---- 面包铲：挂在**除烟囱/门窗之外最宽的墙垛**上（先按墙垛宽定铲头宽，别越出墙角）
    peel_gap, peel_x = free_gap(
        W / 2.0, wall_blocks(dx, door_w, wins,
                             extra=((ch_x - t["ch_w"] / 2.0 - 4.0,
                                     ch_x + t["ch_w"] / 2.0 + 4.0),)),
        pad=10.0)
    baker_peel(b, peel_x, yf, plinth_h + 46.0, ln=112.0,
               blade=max(20.0, min(46.0, peel_gap - 6.0)))

    ob = b.to_object()
    spec = _mk("bakery", width_cells, {
        "depth": D, "plinth_h": plinth_h, "wall_h": wall_h, "eave_h": eave,
        "rise": rise, "total_h": ch_top + 13.0, "overhang": over, "roof_t": 15.0,
        "storey_h": [wall_h], "door": (door_w, DOOR_H), "door_x": dx, "bays": bays,
        "window": (wins[0]["ow"], wins[0]["oh"], wins[0]["z0"] - plinth_h),
        "chimneys": [{"x": ch_x, "y": ch_y, "roof": ch_roof, "top": ch_top + 13.0,
                      "foot": 0.0, "w": t["ch_w"], "d": t["ch_d"]}],
        "chimney_gap": round(gap_w, 1),
        "material": "砖砌 + 白石线脚 / 陶瓦 + 高烟囱"})
    return ob, spec


# ---------------------------------------------------------------- 7.4 商铺 shop

SHOP_TIERS = {
    # 8 格 = 单层店面 + 阁楼膝墙；带门层 200px = 2.62m（门占 75%），
    # 屋面 rise 收到 84（坡 33°）以把"店面 + 膝墙 + 坡顶"压在 8 格剪影带内。
    8:  dict(D=156.0, plinth=16.0, storey=221, knee=42.0, rise=84.0, wt=18.0,
             door_w=52.0, front_cx=50.0, front_w=112.0, rail_drop=24.0,
             pier_win=None),
    12: dict(D=196.0, plinth=18.0, storey=221, rise=104.0, wt=20.0, door_w=56.0,
             jetty=10.0, front_cx=78.0, front_w=180.0, rail_drop=22.0,
             pier_win=-51.0),
}


def assemble_shop(width_cells=8):
    """商铺：底层**大开间橱窗**（木框 + 竖棂 + 外挑柜台板 + 雨篷挂点），上层住人小窗。

    8 格档 = 单层店面 + 低矮阁楼（膝墙 42 + 阁楼小窗，剪影比才算得住 1.5，见 §8.2）；
    12 格档 = 正常两层（下层商铺 + 上层住人，前挑 10）。

    与 `townhouse` 的差异（≥2 项肉眼可辨）：
    ① 底层是**整开间玻璃橱窗**（`shop_window`，一层开洞全部由橱窗承担）—— 街屋是一扇扇小窗；
    ② 材质：底层木板 + 上层抹灰、**石板瓦**顶 —— 街屋是通体抹灰 + 陶瓦；
    ③ 立面上有**铁雨篷挂点**（横杆 + 吊环，道具层 awning 挂在这条线上）；
    ④ 8 格档只有"店面 + 阁楼"（单层带膝墙），与 12 格档形成体量对照。
    """
    t = SHOP_TIERS[width_cells]
    W = width_cells * CELL
    D, plinth_h, sh = t["D"], t["plinth"], t["storey"]
    rise, wt, door_w = t["rise"], t["wt"], t["door_w"]
    over = eave_over(W)
    yf0 = -D / 2.0
    bays = bays_of(width_cells)
    bw = W / float(bays)
    # 一层开洞：门 + 橱窗（**不再排开间窗** —— 橱窗区域里的开间窗会浮在洞口里）
    dx, _w1 = bay_openings(W, bays, WIN_LOW, door_w=door_w, door_bay=0,
                           floor_z=plinth_h, skip=tuple(range(1, bays)))
    # 店面与门之间的墙垛补一扇小货窗（12 格档墙垛够宽；8 格档只有 23 宽，不补）
    pw = None
    if t.get("pier_win"):
        pw = win_rect(WIN_LOW, bay_w=bw, floor_z=plinth_h, w_scale=0.70)
        pw["cx"] = t["pier_win"]
    knee = t.get("knee")
    jetty = t.get("jetty", 0.0)
    # 檐口 = 全部墙体的顶：8 格档 = 单层店面 + 阁楼膝墙；12 格档 = 两层
    eave = plinth_h + (sh + knee if knee else sh * 2.0)
    ridge = eave + rise
    yf = yf0 - jetty
    yc = (yf + D / 2.0) / 2.0
    fw = t["front_w"]
    fcx = t["front_cx"]
    glass_z0 = plinth_h + 44.0
    glass_h = min(sh - 100.0, 136.0)

    b = Builder("shop_w%d" % width_cells)
    contact_shadow(b, W, D + jetty, spread=28.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(dx - door_w / 2.0 - 6.0, dx + door_w / 2.0 + 6.0), lip=10.0)
    # ---- 一层：木板墙 + 门洞 + **整开间橱窗洞**
    front = [(dx, door_w, DOOR_SILL, DOOR_SILL + DOOR_H),
             (fcx, fw, glass_z0, glass_z0 + glass_h)]
    if pw is not None:
        front.append((pw["cx"], pw["ow"], pw["z0"], pw["z1"]))
    room_shell(b, W, D, plinth_h, sh, wt, "wood", front_openings=front)
    door(b, h=DOOR_H, w=door_w, mat="wood_door", x=dx, y=yf0, z=DOOR_SILL,
         frame_mat="timber", planks=4)
    step_stone(b, w=door_w + 32.0, depth=26.0, h=10.0, x=dx, y=yf0 - 18.0)
    if pw is not None:
        put_window(b, pw, pw["cx"], yf0)
    shop_window(b, fcx, fw - 2.0 * 11.0, yf0, glass_z0, glass_h, pier=11.0,
                lights=max(3, int(round(fw / 46.0))), counter_mat="wood_light")
    # ---- 层间腰线（木梁 + 白石压条）+ 雨篷挂点
    b.box_bottom((W + 8.0, 29.0, 15.0), (0.0, yf0 + 7.0), plinth_h + sh - 15.0,
                 "white_stone")
    b.box_bottom((W + 10.0, 10.0, 16.0), (0.0, yf0 - 2.0), plinth_h + sh - 16.0,
                 "timber")
    awning_rail(b, fw + 16.0, yf0, plinth_h + sh - t["rail_drop"], x=fcx, hooks=5)
    # ---- 上层：8 格 = 低矮阁楼（膝墙 + 小窗）；12 格 = 完整二层（前挑 + 住人小窗）
    if knee:
        knee_w = win_rect(WIN_GABLE, bay_w=D * 0.5, floor_z=eave - knee)
        knee_w["z0"] = eave - knee + 8.0
        knee_w["z1"] = knee_w["z0"] + knee_w["oh"]
        kx = [cx for cx in bay_centers(W, bays)]
        wall_panel(b, W, knee, D, "plaster", 0.0, yf0, eave - knee,
                   openings=[(cx, knee_w["ow"], knee_w["z0"], knee_w["z1"])
                             for cx in kx])
        for cx in kx:
            put_window(b, knee_w, cx, yf0, frame_mat="timber")
        timber_frame(b, W, knee, "timber", (0.0, yf0), eave - knee, depth=6.0,
                     post=12.0, top_band=13.0, bays=bays, braces=True,
                     openings=[(cx, knee_w["ow"]) for cx in kx])
        roof_gable(b, W, D, rise, over, "slate", z=eave, thickness=13.0,
                   mat_under="wood_dark", cap_size=(26.0, 13.0), board_h=8.0)
        gable_infill(b, W, D, rise, "plaster", z=eave, thickness=13.0)
    else:
        z2 = plinth_h + sh
        _d2, wins2 = bay_openings(W, bays, WIN_UP, floor_z=z2, w_scale=0.9)
        wall_panel(b, W, sh, D + jetty, "plaster", 0.0, yc, z2,
                   openings=win_holes(wins2))
        for i in range(5):
            px = -W / 2.0 + 14.0 + (W - 28.0) * i / 4.0
            b.box_bottom((14.0, 18.0, 14.0), (px, yf + 9.0), z2 - 14.0, "timber")
        timber_frame(b, W, sh, "timber", (0.0, yf), z2, depth=7.0, post=14.0,
                     top_band=14.0, bays=bays, braces=True,
                     openings=[(w["cx"], w["ow"]) for w in wins2])
        for w in wins2:
            put_window(b, w, w["cx"], yf)
        roof_gable(b, W, D + jetty, rise, over, "slate", z=eave, thickness=13.0,
                   mat_under="wood_dark", cap_size=(26.0, 13.0), board_h=8.0,
                   ao_faces=(yf, D / 2.0), y=yc)
        gable_w = win_rect(WIN_GABLE, bay_w=(D + jetty) * 0.5, floor_z=eave)
        gable_w["u"] = -D * 0.14
        gable_infill(b, W, D + jetty, rise, "plaster", z=eave, thickness=13.0,
                     y=yc, hole=(gable_w["u"], gable_w["ow"], gable_w["z0"],
                                 gable_w["z1"]))
        for sx in (-1.0, 1.0):
            gable_timber(b, D + jetty, rise, "timber", (sx * (W / 2.0), yc), eave,
                         axis="Y", face_dir=sx, thick=11.0)
            put_window(b, gable_w, gable_w["u"], sx * (W / 2.0), axis="Y",
                       face_dir=sx)

    # ---- 落地烟囱：山墙端（上层住人要有排烟），贴前坡穿屋面 + 泛水裙
    ch_x = W / 2.0 - 14.0
    ch_y = yf0 - D * 0.06
    ch_top = ridge + (-8.0 if knee is None else -26.0)
    ch_roof = gable_roof_z(eave, rise, (D + jetty) / 2.0 + over, ch_y, y_ridge=yc)
    chimney(b, 30.0, 26.0, ch_top, "brick", ch_x, ch_y, foot=0.0,
            cap_mat="white_stone", cap=11.0, roof=ch_roof, skirt_h=20.0,
            skirt_lip=8.0)

    ob = b.to_object()
    spec = _mk("shop", width_cells, {
        "depth": D + jetty, "plinth_h": plinth_h, "wall_h": sh + (knee or 0.0),
        "eave_h": eave, "rise": rise, "total_h": eave + rise, "overhang": over,
        "roof_t": 13.0, "storey_h": [sh] + ([knee] if knee else [sh]),
        "double_storey": bool(knee is None), "door": (door_w, DOOR_H), "door_x": dx,
        "bays": bays, "shopfront": (fcx, fw, glass_z0, glass_h),
        "window": ((pw["ow"], pw["oh"], pw["z0"] - plinth_h) if pw else None),
        "chimneys": [{"x": ch_x, "y": ch_y, "roof": ch_roof, "top": ch_top + 11.0,
                      "foot": 0.0, "w": 30.0, "d": 26.0}],
        "material": "木板店面 + 抹灰上层 / 石板瓦 + 铁雨篷挂点"})
    return ob, spec


# ---------------------------------------------------------------- 7.5 行会大厅 guildhall

GUILDHALL_TIERS = {
    # 带门层 200px = 2.62m（门占 75%）；两层半 = 2×200 + 山墙阁层 → 剪影比自带口径
    12: dict(D=210.0, plinth=20.0, storey=260, rise=120.0, wt=22.0, door_w=58.0),
    16: dict(D=240.0, plinth=22.0, storey=260, rise=130.0, wt=24.0, door_w=58.0),
}


def assemble_guildhall(width_cells=12):
    """行会大厅：**山墙朝前**（屋脊沿 Y）+ 石砌底层 + 抹灰半木上层 + 白石腰线 + 门廊山花。

    两层半 = 两层（层高 190~193）+ 山墙阁层。
    与 `townhouse` 的差异（≥2 项肉眼可辨）：
    ① 屋顶结构整个换向：正立面是**山墙三角 + 白石压顶**（`roof_gable_y`），
       正面看不到前坡屋面 —— 街屋是前坡瓦面；
    ② 材质：底层 `stone` + 隅石、上层抹灰半木（`timber_frame`）+ 层间白石腰线；
    ③ 门廊：两侧石柱 + 挑出石檐 + 三角山花（`tri_prism_y`）；
    ④ 山墙上有**行会徽章**（白石圆盘 + 铁环 + 四向短梁），不是普通民居窗。
    """
    t = GUILDHALL_TIERS[width_cells]
    W = width_cells * CELL
    D, plinth_h, sh = t["D"], t["plinth"], t["storey"]
    rise, wt, door_w = t["rise"], t["wt"], t["door_w"]
    over = eave_over(W)
    eave = plinth_h + sh * 2.0
    ridge = eave + rise
    yf = -D / 2.0
    z2 = plinth_h + sh
    bays = bays_of(width_cells)
    door_bay = 1
    dx, wins1 = bay_openings(W, bays, WIN_LOW, door_w=door_w, door_bay=door_bay,
                             floor_z=plinth_h, h_scale=1.12)
    _d2, wins2 = bay_openings(W, bays, WIN_UP, floor_z=z2, w_scale=0.92)

    b = Builder("guildhall_w%d" % width_cells)
    contact_shadow(b, W, D, spread=34.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(dx - door_w / 2.0 - 8.0, dx + door_w / 2.0 + 8.0), lip=12.0)
    # ---- 底层：石砌（隅石 + 高窗）
    room_shell(b, W, D, plinth_h, sh, wt, "stone",
               front_openings=[(dx, door_w, DOOR_SILL, DOOR_SILL + DOOR_H)]
                              + win_holes(wins1))
    quoins(b, W - 2.0 * wt, D, sh * 0.94, "white_stone", 0.0, yf + wt / 2.0,
           plinth_h + 6.0, size=24.0, step=46.0, front=False, sides=True)
    door(b, h=DOOR_H, w=door_w, mat="wood_door", x=dx, y=yf, z=DOOR_SILL,
         frame_mat="stone_dark", frame=9.0, planks=4)
    step_stone(b, w=door_w + 44.0, depth=32.0, h=12.0, x=dx, y=yf - 22.0)
    for w in wins1:
        put_window(b, w, w["cx"], yf, frame_mat="stone_dark")
    # ---- 门廊：石柱 + 挑出石檐 + 三角山花
    for sx in (-1.0, 1.0):
        b.cylinder((dx + sx * (door_w / 2.0 + 26.0), yf - 20.0, plinth_h + 88.0),
                   11.0, 176.0, "white_stone", segments=12)
    b.box_bottom((door_w + 92.0, 44.0, 16.0), (dx, yf - 22.0),
                 plinth_h + DOOR_SILL + DOOR_H + 20.0, "white_stone")
    tri_prism_y(b, dx, yf - 22.0, (door_w + 92.0) / 2.0, 40.0,
                plinth_h + DOOR_SILL + DOOR_H + 36.0, 20.0, "white_stone")
    # ---- 上层：抹灰半木（腰线 + 木骨 + 瘦高窗）
    b.box_bottom((W + 10.0, D + 10.0, 18.0), (0.0, yf + 5.0), z2 - 18.0,
                 "white_stone")
    room_shell(b, W, D, z2, sh, wt, "plaster", front_openings=win_holes(wins2))
    timber_frame(b, W, sh, "timber", (0.0, yf), z2, depth=7.0, post=14.0,
                 top_band=18.0, bays=bays, braces=True,
                 openings=[(w["cx"], w["ow"]) for w in wins2])
    for w in wins2:
        put_window(b, w, w["cx"], yf)
    # ---- 山墙朝前：坡顶沿 Y（正面只见山墙三角 + 白石压顶）+ 徽章
    roof_gable_y(b, W, D, rise, over, "tile", x=0.0, y=0.0, z=eave, thickness=15.0,
                 over_y=16.0, mat_under="wood_dark", cap_size=(28.0, 15.0),
                 cap_mat="stone_dark", board_mat="wood_dark", board_h=9.0)
    tri_prism_y(b, 0.0, yf + 14.0, W / 2.0, rise, eave, 28.0, "plaster")
    for sx in (-1.0, 1.0):                      # 山墙白石压顶（顺两腰）
        strut(b, (sx * (W / 2.0 - 12.0), yf - 1.0,
                  ridge - rise * (W / 2.0 - 12.0) / (W / 2.0) + 3.0),
              (0.0, yf - 1.0, ridge - 2.0), 19.0, "white_stone")
    b.box_bottom((30.0, 30.0, 26.0), (0.0, yf + 2.0), ridge - 6.0, "white_stone")
    # 徽章：白石圆盘 + 铁环 + 四向短梁（阁层墙面，不占窗型）
    emb_z = eave + rise * 0.40
    b.cylinder((0.0, yf - 2.0, emb_z), 34.0, 12.0, "white_stone", segments=18,
               axis="Y")
    b.cylinder((0.0, yf - 8.0, emb_z), 24.0, 6.0, "iron", segments=18, axis="Y")
    for k in range(4):
        a = math.pi * 0.5 * k
        strut(b, (math.cos(a) * 30.0, yf - 7.0, emb_z + math.sin(a) * 30.0),
              (-math.cos(a) * 30.0, yf - 7.0, emb_z - math.sin(a) * 30.0), 7.0,
              "iron")
    for sx in (-1.0, 1.0):
        gable_timber(b, D, rise, "timber", (sx * (W / 2.0), 0.0), eave,
                     axis="Y", face_dir=sx, thick=11.0)
    # ---- 双烟囱：落在山墙两端（落地 + 穿顶泛水；顶压在屋脊之下）
    ch_list = []
    for sx in (-1.0, 1.0):
        ch_x = sx * (W / 2.0 - 16.0)
        ch_y = -D * 0.16
        ch_top = ridge - 10.0
        ch_roof = gable_roof_z(eave, rise, D / 2.0 + over, ch_y)
        ch_list.append({"x": ch_x, "y": ch_y, "roof": ch_roof, "top": ch_top + 12.0,
                        "foot": 0.0, "w": 30.0, "d": 28.0})
        chimney(b, 30.0, 28.0, ch_top, "brick", ch_x, ch_y, foot=0.0,
                cap_mat="white_stone", cap=12.0, roof=ch_roof)

    ob = b.to_object()
    spec = _mk("guildhall", width_cells, {
        "depth": D, "plinth_h": plinth_h, "wall_h": sh * 2.0, "eave_h": eave,
        "rise": rise, "total_h": ridge + 20.0, "overhang": over, "roof_t": 15.0,
        "storey_h": [sh, sh], "double_storey": True, "door": (door_w, DOOR_H),
        "door_x": dx, "bays": bays, "gable_front": True, "guild_emblem": True,
        "window": (wins1[0]["ow"], wins1[0]["oh"], wins1[0]["z0"] - plinth_h),
        "window_up": (wins2[0]["ow"], wins2[0]["oh"], wins2[0]["z0"] - z2),
        "chimneys": ch_list, "ratio_band": (1.05, 1.60), "ridge_axis": "Y",
        "material": "石砌底层 + 抹灰半木上层 / 陶瓦 + 白石饰"})
    return ob, spec


# ---------------------------------------------------------------- 7.6 干草棚 hayloft

HAYLOFT_TIERS = {
    # **底层必须高过门**（门 150 + 门槛 8 = 158）：旧 low=134/146 使门顶越过地面层顶
    # 10~24px，被上层木墙压住 → 可见净高只有 1.83/1.86m（火柴人 1.70m 都贴头）。
    # 抬 low 到 158/162（2.07/2.12m）后门顶留出门楣带，屋面 rise 相应压平保住剪影带。
    8:  dict(D=160.0, plinth=14.0, low=158.0, up=88.0, rise=76.0, wt=18.0,
             door_w=54.0, post=15.0),
    12: dict(D=200.0, plinth=16.0, low=162.0, up=94.0, rise=92.0, wt=20.0,
             door_w=56.0, post=16.0),
}


def assemble_hayloft(width_cells=8):
    """干草棚：石砌马厩底层（真门）+ **上层整面开敞的干草棚**（柱撑 + 草垛外露）+ 薄棚顶。

    与 `barn` 的差异（≥2 项肉眼可辨）：
    ① 体量分层：底下是矮石墙马厩、上面是**整面开敞**的木棚（barn 是通高木板墙 + 双扇门）；
    ② 棚顶更薄（14 vs 16）且出檐更大（檩条端头 4 根、外挑 8~20）；
    ③ 开口里**草垛外露**（`hay_heap` 草堆 + 散草），山墙端是真洞的干草装卸门；
    ④ 材质：石 / 木板 / 茅草三层的横向分层 —— barn 通体木板。
    """
    t = HAYLOFT_TIERS[width_cells]
    W = width_cells * CELL
    D, plinth_h = t["D"], t["plinth"]
    low, up, rise = t["low"], t["up"], t["rise"]
    wt, door_w, post_s = t["wt"], t["door_w"], t["post"]
    over = eave_over(W)
    z_mid = plinth_h + low
    eave = z_mid + up
    yf, yb = -D / 2.0, D / 2.0
    bays = bays_of(width_cells)
    dx, wins = bay_openings(W, bays, "vent", door_w=door_w, door_bay=0,
                            floor_z=plinth_h)

    b = Builder("hayloft_w%d" % width_cells)
    contact_shadow(b, W, D, spread=28.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(dx - door_w / 2.0 - 6.0, dx + door_w / 2.0 + 6.0), lip=9.0)
    # ---- 底层：石砌马厩（门 + 通风窄缝）
    room_shell(b, W, D, plinth_h, low, wt, "stone",
               front_openings=[(dx, door_w, DOOR_SILL, DOOR_SILL + DOOR_H)]
                              + win_holes(wins))
    door(b, h=DOOR_H, w=door_w, mat="wood_door", x=dx, y=yf, z=DOOR_SILL,
         frame_mat="timber", planks=3)
    step_stone(b, w=door_w + 30.0, depth=24.0, h=10.0, x=dx, y=yf - 16.0)
    for w in wins:
        put_window(b, w, w["cx"], yf, frame_mat="wood_dark")
    # ---- 上层：后墙 + 两侧墙（木板），**正面完全开敞** + 四角柱 + 中柱
    wall_panel(b, W, up, 13.0, "wood", 0.0, yb - 6.5, z_mid)
    for sx in (-1.0, 1.0):
        wall_panel(b, D, up, 13.0, "wood", sx * (W / 2.0 - 6.5), 0.0, z_mid,
                   axis="Y")
        for yy in (yb - post_s / 2.0, yf + post_s / 2.0):
            post(b, post_s, up, "wood_dark", sx * (W / 2.0 - post_s / 2.0), yy,
                 z_mid)
    posts_x = [0.0] if width_cells <= 8 else [-W / 4.0, W / 4.0]
    for px in posts_x:
        post(b, post_s, up, "wood_dark", px, yf + post_s / 2.0, z_mid)
    for yy in (yf + post_s / 2.0, yb - post_s / 2.0):
        beam(b, W, 17.0, 15.0, "wood_dark", 0.0, yy, eave - 15.0)
    for sx in (-1.0, 1.0):
        beam(b, D - post_s, 15.0, 15.0, "wood_dark",
             sx * (W / 2.0 - post_s / 2.0), 0.0, eave - 15.0, axis="Y")
    strut(b, (0.0, yf + post_s, eave - 4.0), (0.0, yb - 8.0, eave - 4.0), 12.0,
          "wood_dark")
    # ---- 草垛外露：开口内两堆干草捆（**贴到开口前沿**，否则躲在屋顶阴影里读成灰团）
    hay_heap(b, -W * 0.24, yf + D * 0.14, z_mid + 2.0, w=W * 0.36, d=D * 0.34,
             h=min(52.0, up * 0.58), rows=2, seed=width_cells)
    hay_heap(b, W * 0.22, yf + D * 0.20, z_mid + 2.0, w=W * 0.32, d=D * 0.30,
             h=min(46.0, up * 0.52), rows=2, seed=width_cells + 7)
    # ---- 薄棚顶（茅草，出檐 = 宽 × 20.5%，檩条端头 4 根露在檐下）
    roof_gable(b, W, D, rise, over, "thatch", z=eave, thickness=14.0,
               mat_under="wood", cap_size=(30.0, 13.0), board_mat="wood_dark",
               board_h=8.0, eave_ao=False, rafter_ends=4, purlin_ext=(8.0, 20.0))
    # ---- 山墙端：竖板 + 木骨 + 干草装卸口（真洞；**必须落在三角面内**，否则被 gable_infill
    # 夹到檐口以上只剩一条缝）
    hay_w = win_rect("garret", over=dict(w=min(60.0, D * 0.40), h=rise * 0.45))
    hay_w["z0"] = eave + 8.0
    hay_w["z1"] = hay_w["z0"] + hay_w["oh"]
    for sx in (-1.0, 1.0):
        gable_infill(b, W, D, rise, "wood", z=eave, thickness=13.0,
                     hole=(0.0, hay_w["ow"], hay_w["z0"], hay_w["z1"]))
        plank_siding(b, D, rise, "wood_light", (sx * (W / 2.0), 0.0), eave,
                     plank_w=24.0, gap=2.5, depth=6.0, seed=5, axis="Y",
                     face_dir=sx, gable_rise=rise)
        gable_timber(b, D, rise, "timber", (sx * (W / 2.0), 0.0), eave,
                     axis="Y", face_dir=sx, thick=12.0)
    b.box((W * 0.9, 20.0, up * 0.7), (0.0, D * 0.16, z_mid + up * 0.42), "straw")

    ob = b.to_object()
    spec = _mk("hayloft", width_cells, {
        "depth": D, "plinth_h": plinth_h, "wall_h": low + up, "eave_h": eave,
        "rise": rise, "total_h": eave + rise, "overhang": over, "roof_t": 14.0,
        "storey_h": [low, up], "door": (door_w, DOOR_H), "door_x": dx, "bays": bays,
        "open_loft": True, "hay": 2, "window": None,
        "material": "石砌底层 / 木板开敞棚 / 薄茅草顶"})
    return ob, spec


# ---------------------------------------------------------------- 7.7 铁匠铺二号 smithy2

SMITHY2_TIERS = {
    8: dict(D=180.0, post_h=196.0, rise=108.0, post=16.0, roof_t=18.0, door_w=54.0,
            seg=0.42),
}


def assemble_smithy2(width_cells=8):
    """大铁匠铺：smithy1 变体 —— **双炉（两根烟管穿屋面）** + **更大棚檐**（22.5%）+ 半封闭木屋带门。

    与 `smithy1` 的差异（≥2 项肉眼可辨）：
    ① 两座铁炉（左右各一）+ 两根铁烟管**穿屋面出檐之上**（剪影上多两根管）；
    ② 棚檐加大（宽 × 22.5% vs 20.5%，出檐 58 vs 52）；
    ③ 前立面右侧一段木板墙 + 一扇真门（smithy1 全开敞无门）；
    ④ 顶材换木板顶（smithy1 是茅草旧顶）+ 檩条端头 4 根。
    """
    t = SMITHY2_TIERS[width_cells]
    W = width_cells * CELL
    D, post_h, rise, post_s = t["D"], t["post_h"], t["rise"], t["post"]
    roof_t, door_w = t["roof_t"], t["door_w"]
    over = int(EAVE_ABS_MAX)                  # 棚檐（绝对封顶口径；旧宽百分比已废）
    yf = -D / 2.0 + post_s / 2.0
    yb = D / 2.0 - post_s / 2.0
    half = D / 2.0 + over
    seg_w = W * t["seg"]
    seg_x = W / 2.0 - seg_w / 2.0 - 4.0
    side_len = D * 0.62

    b = Builder("smithy2_w%d" % width_cells)
    contact_shadow(b, W, D * 1.15, spread=28.0)
    wall_panel(b, W, post_h, 14.0, "wood", 0.0, D / 2.0 - 7.0, 0.0)
    for sx in (-1.0, 1.0):
        wall_panel(b, side_len, post_h, 14.0, "wood",
                   sx * (W / 2.0 - 7.0), D / 2.0 - side_len / 2.0, 0.0, axis="Y")
    # 前墙右段（带门）——半封闭木屋，左段仍开敞
    wall_panel(b, seg_w, post_h, 14.0, "wood", seg_x, yf, 0.0,
               openings=[(0.0, door_w, DOOR_SILL, DOOR_SILL + DOOR_H)])
    door(b, h=DOOR_H, w=door_w, mat="wood_door", x=seg_x, y=yf, z=DOOR_SILL,
         frame_mat="timber", planks=3)
    step_stone(b, w=door_w + 30.0, depth=24.0, h=9.0, x=seg_x, y=yf - 16.0)
    # 柱：四角 + 前檐中柱（左段）
    for sx in (-1.0, 1.0):
        for yy in (yb, yf):
            post(b, post_s, post_h, "wood_dark", sx * (W / 2.0 - post_s / 2.0), yy)
    for px in (-W * 0.34, -W * 0.02):
        post(b, post_s, post_h, "wood_dark", px, yf)
    for yy in (yf, yb):
        beam(b, W, 18.0, 16.0, "wood_dark", 0.0, yy, post_h - 16.0)
    for sx in (-1.0, 1.0):
        beam(b, D - post_s, 16.0, 16.0, "wood_dark",
             sx * (W / 2.0 - post_s / 2.0), 0.0, post_h - 16.0, axis="Y")
        strut(b, (sx * (W / 2.0 - post_s - 2.0), yf, post_h - 42.0),
              (sx * (W / 2.0 - 84.0), yf, post_h - 4.0), 11.0, "wood_dark")
    beam(b, W * 0.62, 16.0, 16.0, "wood_dark", -W * 0.18, yf,
         post_h - 34.0)                                          # 前檐第二道横梁
    # ---- 薄木板顶 + 大棚檐 + 檩条端头
    roof_gable(b, W, D, rise, over, "wood_roof", z=post_h, thickness=roof_t,
               mat_under="wood_dark", cap_size=(34.0, 15.0), cap_mat="wood_dark",
               board_h=11.0, uv_swap=True, eave_ao=False, rafter_ends=4,
               purlin_ext=(8.0, 20.0))
    gable_infill(b, W, D, rise, "wood", z=post_h, thickness=14.0)
    for sx in (-1.0, 1.0):
        plank_siding(b, D, rise, "wood_light", (sx * (W / 2.0), 0.0), post_h,
                     plank_w=22.0, gap=2.0, depth=6.0, seed=5, axis="Y",
                     face_dir=sx, gable_rise=rise)
        gable_timber(b, D, rise, "timber", (sx * (W / 2.0), 0.0), post_h,
                     axis="Y", face_dir=sx, thick=12.0)
    # ---- 双炉：左右各一，烟管穿屋面往上 44（剪影上两根管，肉眼可辨）
    for fx, fseed in ((-W * 0.27, 0), (W * 0.09, 1)):
        fy = D / 2.0 - 46.0
        rz = gable_roof_z(post_h, rise, half, fy)
        flue_h = max(60.0, (rz + 44.0) - 106.0)
        forge(b, fx, fy, 0.0, w=56.0, d=44.0, body_h=62.0,
              flue_h=flue_h + fseed * 6.0)
    anvil(b, x=W * 0.30, y=-D * 0.18, z=0.0)
    anvil(b, x=-W * 0.04, y=D * 0.02, z=0.0, stump=False)
    barrel(b, x=-W * 0.40, y=D * 0.06, z=0.0, r=15.0, h=42.0, lid=True)
    bench(b, x=W * 0.30, y=D * 0.06, z=0.0, w=68.0, d=32.0, h=50.0)
    stool(b, x=W * 0.38, y=-D * 0.20, z=0.0)

    ob = b.to_object()
    spec = _mk("smithy2", width_cells, {
        "depth": D, "plinth_h": 0.0, "wall_h": post_h, "eave_h": post_h,
        "rise": rise, "total_h": post_h + rise, "overhang": over, "roof_t": roof_t,
        "storey_h": [post_h], "door": (door_w, DOOR_H), "door_x": seg_x,
        "open_shed": True, "forges": 2, "flues": 2,
        "material": "木柱/木板墙 / 木板顶 + 双炉双烟管"})
    return ob, spec


# ---------------------------------------------------------------- 7.8 铁匠工坊 smithy3

SMITHY3_TIERS = {
    # 带门层 200px = 2.62m（门占 75%）
    8:  dict(D=160.0, plinth=16.0, wall=200.0, rise=100.0, wt=18.0, door_w=54.0,
             ch_w=32.0),
    12: dict(D=196.0, plinth=18.0, wall=200.0, rise=108.0, wt=20.0, door_w=56.0,
             ch_w=36.0),
}


def assemble_smithy3(width_cells=8):
    """铁匠工坊（室内化）：石砌墙 + 板岩顶 + 高侧窗/铁栅侧窗 + **落地石烟囱** + 晾铁架。

    与 `smithy1` / `smithy2` 的差异（≥2 项肉眼可辨）：
    ① 完全室内化：石砌四面墙 + 板岩顶 + 门（棚子 → 房子）；
    ② 落地石烟囱（山墙端、穿前坡泛水），与 smithy2 的"双铁管"是两种语言；
    ③ 侧窗带**铁栅**（工坊的防盗窗，走窗表 `side` 档 + bars 覆写）；
    ④ 立面挂**晾铁架**（横杆 + 吊钩 + 挂着的铁件）。
    """
    t = SMITHY3_TIERS[width_cells]
    W = width_cells * CELL
    D, plinth_h, wall_h, rise = t["D"], t["plinth"], t["wall"], t["rise"]
    wt, door_w = t["wt"], t["door_w"]
    over = eave_over(W)
    eave = plinth_h + wall_h
    yf = -D / 2.0
    bays = bays_of(width_cells)
    dx, wins = bay_openings(W, bays, "pitch", door_w=door_w, door_bay=0,
                            floor_z=plinth_h)
    side_w = win_rect("side", bay_w=D, floor_z=plinth_h, over=dict(bars=True))
    side_w["u"] = -D * 0.10

    b = Builder("smithy3_w%d" % width_cells)
    contact_shadow(b, W, D, spread=28.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(dx - door_w / 2.0 - 6.0, dx + door_w / 2.0 + 6.0), lip=10.0)
    room_shell(b, W, D, plinth_h, wall_h, wt, "stone",
               front_openings=[(dx, door_w, DOOR_SILL, DOOR_SILL + DOOR_H)]
                              + win_holes(wins),
               side_openings=[(side_w["u"], side_w["ow"], side_w["z0"],
                               side_w["z1"])])
    door(b, h=DOOR_H, w=door_w, mat="wood_door", x=dx, y=yf, z=DOOR_SILL,
         frame_mat="timber", frame=8.0, planks=4)
    step_stone(b, w=door_w + 32.0, depth=26.0, h=10.0, x=dx, y=yf - 18.0)
    for w in wins:
        put_window(b, w, w["cx"], yf, frame_mat="timber")
    put_window(b, side_w, side_w["u"], W / 2.0, axis="Y", face_dir=1.0,
               frame_mat="iron")
    iron_rack(b, 36.0, x=-W / 2.0 + 22.0, y_wall=yf, z=plinth_h + 46.0, pieces=3)
    for sx in (-1.0, 1.0):                       # 侧墙晾铁架（"侧挂位"）
        iron_rack_side(b, sx * (W / 2.0 + 2.0), yf + D * 0.22, plinth_h + 56.0,
                       length=min(72.0, D * 0.45), pieces=3)
    roof_gable(b, W, D, rise, over, "slate", z=eave, thickness=14.0,
               mat_under="wood_dark", cap_size=(28.0, 14.0), cap_mat="stone_dark",
               board_mat="wood_dark", board_h=9.0, ao_mat="shadow_mid")
    gable_infill(b, W, D, rise, "stone", z=eave, thickness=14.0)
    # ---- 落地石烟囱：山墙端（x = 外皮内 8）、穿前坡泛水、顶**冲出屋脊 10**（不出脊读不出来）
    ch_x = W / 2.0 - 8.0
    ch_y = -D * 0.16
    ch_top = eave + rise + 10.0
    ch_roof = gable_roof_z(eave, rise, D / 2.0 + over, ch_y)
    chimney(b, t["ch_w"], 28.0, ch_top, "stone_dark", ch_x, ch_y, foot=0.0,
            cap_mat="white_stone", cap=12.0, roof=ch_roof, skirt_h=20.0,
            skirt_lip=8.0)
    # 工坊家什：铁砧 + 淬火桶 + 煤堆 + 工作台
    anvil(b, x=-W * 0.22, y=-D * 0.20, z=0.0)
    barrel(b, x=-W * 0.38, y=D * 0.10, z=0.0, r=15.0, h=42.0, lid=True)
    b.box_bottom((40.0, 26.0, 15.0), (W * 0.22, D * 0.24), 0.0, "stone_dark")
    bench(b, x=W * 0.30, y=-D * 0.06, z=0.0, w=64.0, d=30.0, h=50.0)

    ob = b.to_object()
    spec = _mk("smithy3", width_cells, {
        "depth": D, "plinth_h": plinth_h, "wall_h": wall_h, "eave_h": eave,
        "rise": rise, "total_h": ch_top + 12.0, "overhang": over, "roof_t": 14.0,
        "storey_h": [wall_h], "door": (door_w, DOOR_H), "door_x": dx, "bays": bays,
        "window": (wins[0]["ow"], wins[0]["oh"], wins[0]["z0"] - plinth_h) if wins else None,
        "chimneys": [{"x": ch_x, "y": ch_y, "roof": ch_roof, "top": ch_top + 12.0,
                      "foot": 0.0, "w": t["ch_w"], "d": 28.0}],
        "iron_rack": True,
        "material": "石砌 / 板岩顶 + 铁栅侧窗 + 晾铁架"})
    return ob, spec


# ---------------------------------------------------------------- 7.9 锻造车间 smithy4

SMITHY4_TIERS = {
    12: dict(D=196.0, plinth=18.0, wall=204.0, rise=112.0, wt=20.0, door_w=58.0,
             ch_w=44.0, ch_up=56.0, wheel_x=128.0, wheel_w=124.0, wheel_r=62.0,
             wheel_fwd=86.0),
}


def assemble_smithy4(width_cells=12):
    """锻造车间：砖砌大跨度厂房 + **大烟囱（高出屋脊 56）** + **前凸水轮房（可见水轮 + 引水槽）**。

    工业化前夜气质 = 大烟囱 + 水轮传动，两条都在正面上看得见（2D 侧视游戏里
    侧挂的水轮等于不存在，所以水轮房做成**前凸体量**、轮面朝观众，与 `windmill`
    的帆同一约定）。

    与 `smithy1~3` 的差异（≥2 项肉眼可辨）：
    ① 体量：12 格大跨度 + 高侧窗带（`garret` 小窗一排，厂房的采光带）；
    ② 剪影：砖砌大烟囱高出屋脊 40+，顶到 390；
    ③ 前凸水轮房（石砌拱洞 + 木水轮 + 引水槽 + 水轮房平顶）—— 别的工坊没有；
    ④ 材质：砖 + 石基座 + 陶瓦 + 铁箍。
    """
    t = SMITHY4_TIERS[width_cells]
    W = width_cells * CELL
    D, plinth_h, wall_h, rise = t["D"], t["plinth"], t["wall"], t["rise"]
    wt, door_w = t["wt"], t["door_w"]
    over = eave_over(W)
    eave = plinth_h + wall_h
    yf, yb = -D / 2.0, D / 2.0
    bays = bays_of(width_cells)
    dx, wins = bay_openings(W, bays, WIN_LOW, door_w=door_w, door_bay=0,
                            floor_z=plinth_h, w_scale=0.88, skip=(bays - 1,))
    clere = win_rect("garret", over=dict(w=26.0, h=34.0))
    clere_z = eave - 48.0
    # 高侧窗落在**烟囱/工作窗/水轮房之间剩下的采光带**上（否则被前面那些体量挡死）
    clere_x = (-W * 0.36, W * 0.135)

    b = Builder("smithy4_w%d" % width_cells)
    contact_shadow(b, W, D + t["wheel_fwd"], spread=36.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(dx - door_w / 2.0 - 6.0, dx + door_w / 2.0 + 6.0), lip=12.0)
    # ---- 厂房主体：砖墙 + 门 + 工作窗 + 高侧窗带（采光带）
    room_shell(b, W, D, plinth_h, wall_h, wt, "brick",
               front_openings=[(dx, door_w, DOOR_SILL, DOOR_SILL + DOOR_H)]
                              + win_holes(wins)
                              + [(cx, clere["ow"], clere_z, clere_z + clere["oh"])
                                 for cx in clere_x])
    quoins(b, W - 2.0 * wt, D, wall_h * 0.94, "white_stone", 0.0, yf + wt / 2.0,
           plinth_h + 4.0, size=22.0, step=48.0, front=False, sides=True)
    door(b, h=DOOR_H, w=door_w, mat="wood_door", x=dx, y=yf, z=DOOR_SILL,
         frame_mat="iron", frame=9.0, planks=4)
    step_stone(b, w=door_w + 34.0, depth=28.0, h=11.0, x=dx, y=yf - 19.0)
    for w in wins:
        put_window(b, w, w["cx"], yf)
    for cx in clere_x:
        cw = dict(clere, cx=cx)
        put_window(b, cw, cx, yf, frame_mat="iron")
    roof_gable(b, W, D, rise, over, "tile", z=eave, thickness=16.0,
               mat_under="wood_dark", cap_size=(32.0, 16.0), cap_mat="stone_dark",
               board_h=10.0)
    gable_infill(b, W, D, rise, "brick", z=eave, thickness=16.0)
    # ---- 大烟囱：落在门与邻窗之间的墙垛（不压洞），砖砌 + 铁箍 + 白石压顶
    # 占用表里显式把**水轮房所在的右端**也标成"已占" —— 否则 free_gap 会把烟囱
    # 放到最宽的右端，被前凸的水轮房整个挡死。
    gap_w, ch_x = free_gap(W / 2.0, wall_blocks(
        dx, door_w, wins, extra=tuple((cx - 17.0, cx + 17.0) for cx in clere_x)
        + ((W * 0.17, W / 2.0),)))
    ch_y = yf + 13.0
    ch_top = eave + rise + t["ch_up"]
    ch_roof = gable_roof_z(eave, rise, D / 2.0 + over, ch_y)
    chimney(b, t["ch_w"], 40.0, ch_top, "brick", ch_x, ch_y, foot=0.0,
            cap_mat="white_stone", cap=15.0, roof=ch_roof, skirt_h=26.0,
            skirt_lip=11.0, flue=True)
    for zz in (eave + 30.0, eave + rise + 20.0):              # 铁箍两道
        b.box_bottom((t["ch_w"] + 8.0, 44.0, 7.0), (ch_x, ch_y), zz, "iron")
    b.box_bottom((26.0, 20.0, 40.0), (ch_x, ch_y - 26.0),
                 eave + rise - 34.0, "iron")                  # 烟囱侧检修踏板
    # ---- 前凸水轮房：石砌拱洞（真洞）+ 木水轮（轮面朝观众）+ 引水槽 + 平顶
    wx, ww, wr, wf = t["wheel_x"], t["wheel_w"], t["wheel_r"], t["wheel_fwd"]
    wy_f = yf - wf
    wy_c = wy_f + wf / 2.0
    arch_wall(b, ww, eave - 40.0, 18.0, "stone", wx, wy_f + 9.0, 0.0,
              openings=[(0.0, ww - 32.0, 14.0, 112.0, 40.0, "round")])
    # 洞内暗背板必须在**水轮之后**（放在轮前会把轮整个挡住 —— 一轮踩过的坑）
    b.box((ww - 32.0, 20.0, 130.0), (wx, wy_f + 74.0, 79.0), "cavity")
    for sx in (-1.0, 1.0):
        b.box_bottom((18.0, wf, eave - 40.0), (wx + sx * (ww / 2.0 - 9.0), wy_c),
                     0.0, "stone")
    b.box_bottom((ww + 24.0, wf + 26.0, 16.0), (wx, wy_c - 4.0), eave - 40.0,
                 "stone_dark")                                # 水轮房平顶
    b.box_bottom((ww + 24.0, 18.0, 14.0), (wx, wy_f - 4.0), eave - 54.0,
                 "white_stone")                               # 前檐石线脚
    water_wheel(b, wx, wy_f + 40.0, 86.0, r=wr, width=26.0)
    b.box_bottom((ww - 6.0, wf - 30.0, 26.0), (wx, wy_f + 26.0), 6.0, "stone_dark")
    b.box_bottom((ww, 30.0, 12.0), (wx, wy_f + 20.0), eave - 24.0, "wood_dark")
    b.box_bottom((ww - 12.0, 18.0, 5.0), (wx, wy_f + 20.0), eave - 19.0, "water")
    b.box((32.0, 8.0, 46.0), (wx, wy_f + 26.0, eave - 96.0), "water")  # 水舌落到轮上
    # 车间家什
    anvil(b, x=-W * 0.30, y=-D * 0.10, z=0.0)
    barrel(b, x=-W * 0.42, y=D * 0.16, z=0.0, r=16.0, h=46.0, lid=True)
    b.box_bottom((52.0, 30.0, 16.0), (W * 0.30, D * 0.26), 0.0, "stone_dark")

    ob = b.to_object()
    spec = _mk("smithy4", width_cells, {
        "depth": D + t["wheel_fwd"], "plinth_h": plinth_h, "wall_h": wall_h,
        "eave_h": eave, "rise": rise, "total_h": ch_top + 15.0, "overhang": over,
        "roof_t": 16.0, "storey_h": [wall_h], "door": (door_w, DOOR_H),
        "door_x": dx, "bays": bays, "clerestory": len(clere_x),
        "wheel": {"x": wx, "r": wr, "fwd": wf}, "chimney_gap": round(gap_w, 1),
        "window": (wins[0]["ow"], wins[0]["oh"], wins[0]["z0"] - plinth_h) if wins else None,
        "chimneys": [{"x": ch_x, "y": ch_y, "roof": ch_roof, "top": ch_top + 15.0,
                      "foot": 0.0, "w": t["ch_w"], "d": 40.0}],
        "material": "砖砌 / 陶瓦 + 大烟囱 + 水轮房"})
    return ob, spec


ASSEMBLERS["cottage"] = assemble_cottage
ASSEMBLERS["tavern"] = assemble_tavern
ASSEMBLERS["bakery"] = assemble_bakery
ASSEMBLERS["shop"] = assemble_shop
ASSEMBLERS["guildhall"] = assemble_guildhall
ASSEMBLERS["hayloft"] = assemble_hayloft
ASSEMBLERS["smithy2"] = assemble_smithy2
ASSEMBLERS["smithy3"] = assemble_smithy3
ASSEMBLERS["smithy4"] = assemble_smithy4

#: 批次 D3a 探针条目（追加在既有条目之后，不动既有 —— 既有 13 条的判定必须不变）
PROBE_LIST += [("cottage", 6), ("cottage", 8),
               ("tavern", 12), ("tavern", 16),
               ("bakery", 8), ("bakery", 12),
               ("shop", 8), ("shop", 12),
               ("guildhall", 12), ("guildhall", 16),
               ("hayloft", 8), ("hayloft", 12),
               ("smithy2", 8), ("smithy3", 8), ("smithy3", 12), ("smithy4", 12)]


# ================================================================ §8 魔法 / 军政 / 畜牧装配器（批次 D3b）
#
# 7 个新 def：mage_tower / alchemy / library / barracks / warehouse / stable / shelter。
# （hayloft 已在 D3a 独立化，本批**不改其几何** —— 既有剪影 <1px 纪律。）
# 纪律：只新增函数 / 常量 / 窗口档；既有 19 栋装配器与既有 WINDOW_SPEC 条目一律不动。
# 玻璃 / 魔法材质 key（stained_glass / glass_lead / crystal / rune_glow）由并行 agent
# 加入 materials.py；本文件用 `magic_key()` 探测，未注册则优雅回退既有 glass_win / lamp。

#: (首选 key, 回退 key)：`magic_key()` 的探测表
GLASS_STAINED = ("stained_glass", "glass_win")   # 教堂彩窗（玫瑰窗 / 尖拱窗）
GLASS_LEAD = ("glass_lead", "glass_win")         # 铅条玻璃窗（图书馆 / 炼金 / 学院）
MAT_CRYSTAL = ("crystal", "lamp")                # 魔法水晶（自发光冷光）
MAT_RUNE = ("rune_glow", "lamp")                 # 符文石刻（自发光）

_MAGIC_KEYS = {}


def magic_key(pair):
    """解析新材料 key：已注册用新 key，未注册回退 `pair[1]`（优雅降级，不落抹灰纯色）。

    探测顺序与 `material()` 一致：注入解析器 → materials.get()；两处都没有该 key 时
    返回回退名（glass_win / lamp）。结果带缓存（同进程内 materials.py 不会中途重载）。
    """
    if pair in _MAGIC_KEYS:
        return _MAGIC_KEYS[pair]
    name, fallback = pair
    out, ok = fallback, False
    if _RESOLVER is not None:
        try:
            m = _RESOLVER(name)
            ok = m is not None and hasattr(m, "node_tree")
        except Exception:
            ok = False
    if not ok:
        if "materials" not in sys.modules:
            here = os.path.dirname(os.path.abspath(__file__))
            if here not in sys.path:
                sys.path.insert(0, here)
            try:
                __import__("materials")
            except Exception:
                pass
        mod = sys.modules.get("materials")
        fn = getattr(mod, "get", None) if mod is not None else None
        if callable(fn):
            try:
                ok = fn(name) is not None
            except Exception:
                ok = False
    if ok:
        out = name
    _MAGIC_KEYS[pair] = out
    return out


# ---- 追加材质回退色（纯追加；materials.py 缺 key 时的兜底，免得落到抹灰纯色） ----
SPEC_COLOR["stained_glass"] = ((0.20, 0.12, 0.34), 0.35, 0.0)
EMISSIVE["stained_glass"] = ((0.58, 0.36, 0.98), 1.4)
SPEC_COLOR["glass_lead"] = ((0.14, 0.16, 0.20), 0.45, 0.0)
SPEC_COLOR["crystal"] = ((0.55, 0.72, 0.88), 0.16, 0.0)
EMISSIVE["crystal"] = ((0.36, 0.64, 1.00), 2.2)
SPEC_COLOR["rune_glow"] = ((0.35, 0.85, 0.95), 0.40, 0.0)
EMISSIVE["rune_glow"] = ((0.30, 0.80, 1.00), 3.0)
SPEC_COLOR["cloth_red"] = ((0.46, 0.08, 0.07), 0.92, 0.0)


def crystal_shard(b, x, y, z, r, h, mat="crystal", segments=6):
    """悬浮水晶晶柱：六棱柱 + 上尖锥（**底部无支撑** —— 魔法感来自"浮着"）。"""
    b.cylinder((x, y, z + h * 0.5), r, h, mat, segments=segments)
    cone_roof(b, x, y, z + h, r, h * 0.55, mat, segments=segments, eave_ring=False)


def lamp_post(b, x, y, z=0.0, h=178.0, mat="iron", glass="lamp"):
    """门廊灯柱：石基座 + 铁柱 + 四面铁框玻璃灯罩（自发光 lamp）+ 小锥帽。"""
    b.box_bottom((20.0, 20.0, 12.0), (x, y), z, "stone_dark", bevel=BEV_MID)
    b.cylinder((x, y, z + 12.0 + (h - 60.0) / 2.0), 6.5, h - 60.0, mat, segments=8,
               bevel=BEV_SMALL)
    zl = z + h - 48.0
    b.box((17.0, 17.0, 30.0), (x, y, zl + 15.0), glass)
    for k in range(4):
        th = math.pi * 0.5 * k
        b.box_bottom((5.0, 5.0, 32.0),
                     (x + math.cos(th) * 9.5, y + math.sin(th) * 9.5), zl - 1.0, mat,
                     bevel=BEV_SMALL)
    b.box_bottom((21.0, 21.0, 7.0), (x, y), zl - 3.0, mat, bevel=BEV_MID)
    b.box_bottom((21.0, 21.0, 6.0), (x, y), zl + 30.0, mat, bevel=BEV_MID)
    cone_roof(b, x, y, zl + 36.0, 13.0, 13.0, mat, segments=6, eave_ring=False)


def weapon_rack_wall(b, x, y_wall, z, w=118.0, shields=2, spears=5, mat="wood_dark"):
    """兵营兵器架（贴正立面）：竖杆 + 两道横杆 + 斜靠长矛 + 挂盾。"""
    for sx in (-1.0, 1.0):
        b.box_bottom((9.0, 9.0, 100.0), (x + sx * (w / 2.0 - 4.5), y_wall - 7.0), z, mat)
    for zz in (z + 30.0, z + 88.0):
        b.box_bottom((w, 9.0, 9.0), (x, y_wall - 7.0), zz, mat)
    n = max(2, int(spears))
    for i in range(n):
        px = x - w * 0.40 + w * 0.80 * i / (n - 1.0)
        lean = 0.16 if i % 2 else -0.16
        b.box((6.0, 6.0, 156.0), (px + lean * 12.0, y_wall - 11.0, z + 80.0), "wood",
              rot=(0.0, lean, 0.0))
        b.box((9.0, 7.0, 16.0), (px + lean * 22.0, y_wall - 11.0, z + 152.0), "iron")
    for i in range(max(1, int(shields))):
        sx = x - w * 0.5 + w * (i + 0.5) / max(1, int(shields))
        b.cylinder((sx, y_wall - 17.0, z + 78.0), 23.0, 8.0, "iron", segments=8,
                   axis="Y")
        b.box_bottom((7.0, 6.0, 14.0), (sx, y_wall - 15.0), z + 92.0, mat)


def herb_rack(b, x, y_wall, z, w=96.0, bundles=4, mat="wood_dark"):
    """药草晾架：两根竖杆 + 顶横杆 + 倒挂草束（foliage）+ 麻绳捆扎。"""
    for sx in (-1.0, 1.0):
        b.box_bottom((8.0, 8.0, 92.0), (x + sx * (w / 2.0 - 4.0), y_wall - 8.0), z, mat)
    b.box_bottom((w, 8.0, 8.0), (x, y_wall - 8.0), z + 84.0, mat)
    n = max(1, int(bundles))
    for i in range(n):
        j0, j1 = _jit(i, 701), _jit(i, 719)
        px = x - w * 0.42 + w * 0.84 * (i + 0.5) / n
        b.box((11.0 + 2.0 * j0, 9.0, 34.0 + 6.0 * j1),
              (px, y_wall - 10.0, z + 60.0), "foliage")
        b.box((7.0, 6.0, 9.0), (px, y_wall - 10.0, z + 80.0), "rope")


def hoist_arm(b, x, y_wall, z, reach=96.0, rope=76.0, crate=(46.0, 40.0, 38.0)):
    """仓库吊臂/滑车：墙座 + 前挑横臂 + 斜撑 + 滑轮 + 吊绳 + 悬空货箱。"""
    b.box_bottom((18.0, 16.0, 16.0), (x, y_wall - 6.0), z, "wood_dark")
    beam(b, reach, 13.0, 13.0, "wood_dark", x, y_wall - reach / 2.0 - 6.0, z + 4.0,
         axis="Y")
    strut(b, (x, y_wall - 6.0, z - 46.0), (x, y_wall - reach + 12.0, z + 2.0),
          10.0, "wood_dark")
    b.cylinder((x, y_wall - reach + 12.0, z - 3.0), 11.0, 9.0, "iron", segments=10,
               axis="X")
    b.box((4.5, 4.5, rope), (x, y_wall - reach + 12.0, z - 6.0 - rope / 2.0), "rope")
    zc = z - 6.0 - rope - crate[2]
    b.box_bottom(crate, (x, y_wall - reach + 12.0), zc, "wood_light")
    for sx in (-1.0, 1.0):
        b.box_bottom((5.0, crate[1] * 0.98, crate[2] * 0.94),
                     (x + sx * (crate[0] / 2.0 - 2.5), y_wall - reach + 12.0), zc,
                     "wood_dark")


def crate_stack(b, x, y, z=0.0, seed=0):
    """货箱/麻袋堆（仓库货台 / 草棚辎重）：两只板箱 + 叠箱 + 麻袋 + 木桶。"""
    b.box_bottom((58.0, 44.0, 40.0), (x - 22.0, y), z, "wood_light")
    b.box_bottom((44.0, 40.0, 34.0), (x + 34.0, y + 6.0), z, "wood_light")
    b.box_bottom((40.0, 36.0, 34.0), (x - 18.0, y + 2.0), z + 40.0, "wood")
    for sx in (-1.0, 1.0):
        b.box_bottom((3.0, 46.0, 42.0), (x - 22.0 + sx * 26.0, y), z + 1.0, "wood_dark")
    b.box_bottom((34.0, 30.0, 36.0), (x + 30.0, y + 6.0), z + 34.0, "canvas")
    barrel(b, x + 62.0, y - 6.0, z, r=15.0, h=42.0, lid=True)


# ---------------------------------------------------------------- 8.1 法师塔 mage_tower

MAGE_TOWER_TIERS = {
    # 塔身 **2 层**（不是 3 段装饰鼓）：每层净高 ≈ 3.5~3.8m（现实塔每层 3.5~4.5m），
    # 于是"塔身 : 门高" ≈ 3.5~3.8×（够两层）、锥顶组 = 塔身 × 0.41 ≤ 塔身。
    # 旧值（tower_h 300/348/392 ÷3 段 = 每层 1.3~1.7m）矮于门（2.0m），
    # 读数变成"矮鼓 + 大帽子"—— 比例审计里唯一被点名的一栋。
    4: dict(R=54.0, plinth=16.0, tower_h=536.0, taper=0.74, spire_h=224.0,
            door_w=46.0, sec=2, lantern_h=96.0),
    6: dict(R=80.0, plinth=18.0, tower_h=560.0, taper=0.76, spire_h=232.0,
            door_w=52.0, sec=2, lantern_h=100.0),
    8: dict(R=106.0, plinth=20.0, tower_h=584.0, taper=0.78, spire_h=240.0,
            door_w=56.0, sec=2, lantern_h=104.0),
}


def assemble_mage_tower(width_cells=6):
    """法师塔：收分石塔（**2 层**，每层 3.5~3.8m）+ 悬挑观星台 + 水晶灯室 + 尖锥顶 +
    彩窗/符文自发光/悬浮水晶。

    剑与魔法世界观的"名片建筑"——一眼不是民居的四条依据：
    ① 体量：2 层收分圆塔 + 外挑观星台 + 水晶灯室 + 尖锥顶（塔类竖向体量，显式豁免剪影比）；
    ② 材质：彩窗（stained_glass）+ 符文带（rune_glow 自发光）+ 水晶灯室（crystal）；
    ③ 魔法件：塔顶灯室自发光 + **三颗无支撑悬浮水晶**（正面/上方可见）；
    ④ 立面：**逐层一扇**尖拱彩窗 + 门楣符文石板 —— 民居一项都没有。

    比例口径（§0.3 塔类）：塔身每层 3.5~4.5m、锥顶组 ≤ 塔身（锥顶不得压过塔身）；
    塔身 ≥ 3× 门高（门 2.0m → 塔身 ≥ 6m，人才不会觉得"门长在鼓上"）。
    """
    t = MAGE_TOWER_TIERS[width_cells]
    W = width_cells * CELL
    R, plinth_h = t["R"], t["plinth"]
    tower_h, taper, spire_h = t["tower_h"], t["taper"], t["spire_h"]
    door_w, n_sec, lantern_h = t["door_w"], int(t["sec"]), t["lantern_h"]
    D = 2.0 * R
    top_r = R * taper
    yf = -R - 10.0
    stained = magic_key(GLASS_STAINED)
    crystal = magic_key(MAT_CRYSTAL)
    rune = magic_key(MAT_RUNE)

    b = Builder("mage_tower_w%d" % width_cells)
    contact_shadow(b, D, D, spread=28.0)
    b.cylinder((0.0, 0.0, plinth_h * 0.6), R * 1.12, plinth_h * 1.2, "stone_dark",
               segments=20)
    sec = tower_h / float(n_sec)
    r_prev = R
    for k in range(n_sec):
        r_next = R * (taper ** ((k + 1) / float(n_sec)))
        b.cylinder((0.0, 0.0, plinth_h + sec * (k + 0.5)), r_prev, sec, "stone",
                   segments=20, taper=r_next / r_prev)
        if k:
            b.cylinder((0.0, 0.0, plinth_h + sec * k), r_prev * 1.10, 12.0,
                       "white_stone", segments=20)
        r_prev = r_next
    z_top = plinth_h + tower_h
    # ---- 悬挑观星台：一圈外挑石檐 + 一排牛腿
    for k in range(12):
        th = 2.0 * math.pi * k / 12.0
        b.box_bottom((11.0, 11.0, 22.0),
                     (math.cos(th) * top_r * 1.02, math.sin(th) * top_r * 1.02),
                     z_top - 14.0, "stone_dark")
    b.cylinder((0.0, 0.0, z_top + 8.0), top_r * 1.28, 18.0, "stone", segments=20)
    b.cylinder((0.0, 0.0, z_top + 19.0), top_r * 1.32, 6.0, "white_stone",
               segments=20)
    # ---- 符文带（门楣上一道 + 层间一道 + 观星台下一道）+ **每层一扇**尖拱彩窗
    head_z = DOOR_SILL + DOOR_H + door_w * 0.5
    for zz in (head_z + 6.0, plinth_h + sec, z_top - 10.0):
        rr = R * (1.0 - (zz - plinth_h) / tower_h * (1.0 - taper))
        b.cylinder((0.0, 0.0, zz), max(6.0, rr) * 1.035, 9.0, rune, segments=20)
    lanc = win_rect("lancet", w_scale=1.04, h_scale=1.0, mat=stained)
    for k in range(n_sec):
        z_sec = plinth_h + sec * k
        # 底层窗底要让开拱门头（head_z）；上层窗底留一道窗台墙
        wz = head_z + 18.0 if k == 0 else z_sec + 62.0
        # 窗顶不许压到本层顶（层间白石材带之下留 16）
        room = (plinth_h + sec * (k + 1) - 16.0) - wz
        w_oh = max(52.0, min(lanc["oh"], room))
        rr1 = R * (1.0 - (wz - plinth_h) / tower_h * (1.0 - taper))
        # 圆塔是凸面：宽窗必须**整片让到塔身前脸之外**（用 -sqrt 取边角深度会让塔身
        # 中央的鼓起挡住玻璃中段，读成"窗中央一根石柱"）—— 直接取 -rr - 2 让它微凸。
        lancet_window(b, 0.0, -rr1 - 2.0, wz, lanc["ow"], w_oh,
                      head=lanc["ow"] * 0.55, glass=stained, depth=9.0)
    # ---- 底部拱门 + 门楣符文石板
    arched_doorway(b, 0.0, yf, 30.0, door_w, head=door_w * 0.5, mat="stone",
                   porch_w=door_w + 46.0)
    b.box_bottom((door_w + 20.0, 9.0, 26.0), (0.0, yf - 3.0),
                 DOOR_SILL + DOOR_H + door_w * 0.5 + 14.0, rune)
    # ---- 水晶灯室（crystal 自发光）+ 尖锥顶 + 顶尖晶柱
    z_lan = z_top + 36.0
    lantern_room(b, 0.0, 0.0, z_lan, top_r * 0.66, lantern_h, glass=crystal,
                 frame="iron", roof_mat="slate", roof_h=spire_h, posts=8)
    z_spire_top = z_lan + lantern_h + 10.0 + spire_h + 26.0
    crystal_shard(b, 0.0, 0.0, z_spire_top - 4.0, 12.0, 40.0, crystal)
    # ---- 三颗悬浮水晶（无支撑；正面/上方可见）
    for (sx, sy, sz, sr, sh) in ((-R * 0.95, -R * 1.02, z_top + 34.0, 13.0, 48.0),
                                 (R * 0.92, -R * 0.94, z_top + 78.0, 10.0, 38.0),
                                 (R * 0.06, -R * 1.40, z_top + 104.0, 8.0, 30.0)):
        crystal_shard(b, sx, sy, sz, sr, sh, crystal)

    ob = b.to_object()
    spec = _mk("mage_tower", width_cells, {
        "depth": D, "plinth_h": plinth_h, "wall_h": tower_h, "eave_h": z_top,
        "rise": z_spire_top - z_top, "total_h": z_spire_top + 44.0,
        "overhang": top_r * 0.14, "roof_t": 0.0, "storey_h": [tower_h / n_sec] * n_sec,
        "tower_sections": n_sec, "tower_h": tower_h, "spire_h": spire_h,
        "lantern_h": lantern_h,
        "door": (door_w, DOOR_H), "door_x": 0.0, "floor_h": FLOOR_H_SPEC,
        "window": (lanc["ow"], lanc["oh"], lanc["z0"] - plinth_h),
        "round_tower": True, "magic": True, "floating_crystals": 3,
        "ratio_exempt": True, "eave_exempt": True,
        "width_exempt": (width_cells < MIN_DOOR_CELLS),
        "reason": "法师塔：竖向塔体（2 层收分塔身 + 悬挑观星台 + 水晶灯室 + 尖锥顶）；"
                  "锥顶出檐按塔半径比例（非民居坡檐口径，eave_exempt）",
        "material": "石砌 / 板岩尖顶 + 彩窗 + 符文自发光 + 悬浮水晶"})
    return ob, spec


# ---------------------------------------------------------------- 8.2 炼金工坊 alchemy

ALCHEMY_TIERS = {
    # 带门层 200px = 2.62m（门占 75%）；8 格档 rise 80（坡 30°）以把剪影比压在 1.5 内
    8:  dict(D=168.0, plinth=16.0, wall=200.0, rise=80.0, wt=18.0, door_w=52.0),
    12: dict(D=200.0, plinth=18.0, wall=200.0, rise=104.0, wt=20.0, door_w=56.0),
}


def assemble_alchemy(width_cells=8):
    """炼金工坊：砖石工坊 + **多管歪斜烟道群** + 外置蒸馏台 + 药草晾架 + 玻璃器皿。

    与 smithy3（石砌工坊）的差异（≥2 项肉眼可辨）：
    ① 剪影：三根高低错落的砖烟囱、其中一根顶部接**歪斜砖管**（smithy3 是单根直烟囱）；
    ② 立面：铅条玻璃大窗（glass_lead）+ 门前外置蒸馏台（葫芦玻璃甑 + 铜蛇管 + 小火盆）；
    ③ 道具：挂药草束的晾架（foliage + 麻绳）—— 工坊族没有；
    ④ 材质：陶瓦顶 + 砖烟囱 + 门侧玻璃瓶组。
    """
    t = ALCHEMY_TIERS[width_cells]
    W = width_cells * CELL
    D, plinth_h, wall_h, rise = t["D"], t["plinth"], t["wall"], t["rise"]
    wt, door_w = t["wt"], t["door_w"]
    over = eave_over(W)
    eave = plinth_h + wall_h
    yf = -D / 2.0
    bays = bays_of(width_cells)
    lead = magic_key(GLASS_LEAD)
    dx, wins = bay_openings(W, bays, WIN_LOW, door_w=door_w, door_bay=0,
                            floor_z=plinth_h, w_scale=1.12, h_scale=1.06, mat=lead)
    side_w = win_rect(WIN_SIDE, bay_w=D, floor_z=plinth_h, bars=True, mat=lead)
    side_w["u"] = -D * 0.12

    b = Builder("alchemy_w%d" % width_cells)
    contact_shadow(b, W, D, spread=28.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(dx - door_w / 2.0 - 6.0, dx + door_w / 2.0 + 6.0), lip=10.0)
    room_shell(b, W, D, plinth_h, wall_h, wt, "stone",
               front_openings=[(dx, door_w, DOOR_SILL, DOOR_SILL + DOOR_H)]
                              + win_holes(wins),
               side_openings=[(side_w["u"], side_w["ow"], side_w["z0"],
                               side_w["z1"])])
    door(b, h=DOOR_H, w=door_w, mat="wood_door", x=dx, y=yf, z=DOOR_SILL,
         frame_mat="timber", planks=3)
    step_stone(b, w=door_w + 32.0, depth=26.0, h=10.0, x=dx, y=yf - 18.0)
    for w in wins:
        put_window(b, w, w["cx"], yf, frame_mat="timber")
    put_window(b, side_w, side_w["u"], W / 2.0, axis="Y", face_dir=1.0,
               frame_mat="iron")
    roof_gable(b, W, D, rise, over, "tile", z=eave, thickness=15.0,
               mat_under="wood_dark", cap_size=(30.0, 14.0), cap_mat="stone_dark",
               board_h=9.0)
    gable_w = win_rect("garret", bay_w=D * 0.5, floor_z=eave,
                       over=dict(w=34.0, h=36.0))
    gable_w["u"] = -D * 0.12
    gable_infill(b, W, D, rise, "stone", z=eave, thickness=14.0,
                 hole=(gable_w["u"], gable_w["ow"], gable_w["z0"], gable_w["z1"]))
    for sx in (-1.0, 1.0):
        gable_timber(b, D, rise, "timber", (sx * (W / 2.0), 0.0), eave,
                     axis="Y", face_dir=sx, thick=11.0)
        put_window(b, gable_w, gable_w["u"], sx * (W / 2.0), axis="Y", face_dir=sx)
    # ---- 多管歪斜烟道群（三根高低错落，其中一根顶部歪斜）
    ch_y = -D * 0.14
    ch_z = gable_roof_z(eave, rise, D / 2.0 + over, ch_y)
    for (cxx, up, lean, cd) in ((-W * 0.32, 10.0, 0.20, 24.0),
                                (W * 0.04, 26.0, 0.0, 22.0),
                                (W * 0.34, 4.0, -0.17, 26.0)):
        ch_top = eave + rise + up
        chimney(b, cd, cd, ch_top, "brick", cxx, ch_y, foot=0.0,
                cap_mat="stone_dark", cap=10.0, roof=ch_z, flue=True)
        if abs(lean) > 1e-6:
            b.box((cd * 0.86, cd * 0.86, 36.0),
                  (cxx + lean * 20.0, ch_y, ch_top + 26.0), "brick",
                  rot=(0.0, lean, 0.0))
            b.box_bottom((cd + 6.0, cd + 6.0, 9.0), (cxx + lean * 38.0, ch_y),
                         ch_top + 40.0, "stone_dark")
    # ---- 外置蒸馏台（摆在门前前场：玻璃甑 + 铜蛇管 + 小火盆 + 玻璃瓶组）----
    #       y 必须落在前墙之外（yf 更负 = 更靠前），否则整套家什被埋进室内看不见。
    ax, ay = W * 0.16, yf - 44.0
    bench(b, x=ax, y=ay, z=0.0, w=92.0, d=34.0, h=52.0)
    b.cylinder((ax - 18.0, ay, 72.0), 14.0, 40.0, lead, segments=12)
    b.cylinder((ax - 18.0, ay, 98.0), 7.5, 14.0, lead, segments=10)
    b.box((6.5, 6.5, 52.0), (ax + 8.0, ay, 82.0), "iron", rot=(0.0, 0.62, 0.0))
    b.box_bottom((30.0, 30.0, 10.0), (ax + 30.0, ay + 2.0), 0.0, "iron")
    b.box((24.0, 24.0, 9.0), (ax + 30.0, ay + 2.0, 13.0), "fire")
    for i in range(3):
        b.cylinder((ax - 40.0 + i * 11.0, ay + 12.0, 64.0), 5.0, 24.0, lead,
                   segments=8)
    # ---- 药草晾架：门前最左端落地（窄一点，别挡住大门）
    herb_rack(b, -W * 0.42, yf - 30.0, 0.0, w=64.0, bundles=3)
    barrel(b, x=W * 0.40, y=D * 0.06, z=0.0, r=15.0, h=42.0, lid=True)

    ob = b.to_object()
    spec = _mk("alchemy", width_cells, {
        "depth": D, "plinth_h": plinth_h, "wall_h": wall_h, "eave_h": eave,
        "rise": rise, "total_h": eave + rise + 46.0, "overhang": over,
        "roof_t": 15.0, "storey_h": [wall_h], "door": (door_w, DOOR_H),
        "door_x": dx, "bays": bays, "flues": 3, "alembic": True, "herb_rack": True,
        "window": (wins[0]["ow"], wins[0]["oh"], wins[0]["z0"] - plinth_h),
        "material": "石砌 / 陶瓦 + 多管歪斜烟道 + 外置蒸馏器 + 药草晾架"})
    return ob, spec


# ---------------------------------------------------------------- 8.3 图书馆/学院 library

LIBRARY_TIERS = {
    # 带门层 200/202px = 2.62/2.64m（门占 75/74%）
    12: dict(D=204.0, plinth=20.0, storey=260, rise=94.0, wt=22.0, door_w=58.0),
    16: dict(D=236.0, plinth=22.0, storey=260, rise=140.0, wt=24.0, door_w=60.0),
}


def assemble_library(width_cells=12):
    """图书馆/学院：两层石砌 + 大跨铅条高窗成组 + 中央凸出门楼（山墙铭牌+圆窗）+ 石阶灯柱。

    与 cathedral（石砌公共建筑）的差异（≥2 项肉眼可辨）：
    ① 体量：两层**矩形石楼** + 中央凸出门楼（cathedral 是山墙正立面 + 中殿坡顶 + 钟楼）；
    ② 立面：铅条玻璃**成组高窗**（每开间两扇成对、上下两层对齐）+ 门楼铭牌；
    ③ 入口：双扇拱门 + 三级石阶 + 两侧自发光灯柱（cathedral 是尖拱门廊 + 扶手）；
    ④ 屋顶：低坡板岩 + 门楼小山墙 —— 无钟楼、无尖顶。
    """
    t = LIBRARY_TIERS[width_cells]
    W = width_cells * CELL
    D, plinth_h, storey = t["D"], t["plinth"], t["storey"]
    rise, wt, door_w = t["rise"], t["wt"], t["door_w"]
    over = eave_over(W)
    eave = plinth_h + storey * 2.0
    z2 = plinth_h + storey
    yf = -D / 2.0
    bays = bays_of(width_cells)
    lead = magic_key(GLASS_LEAD)
    fp_w = min(190.0, W * 0.34)          # 中央门楼宽
    # 门楼必须**凸出到屋檐线之外**（否则整根门楼被自家前坡挡到只剩一个尖）：
    # 凸出量 = 出檐 + 18，门楼前脸才完整可读。
    fp = over + 18.0
    fp_rise = rise + 26.0
    fpy = yf - fp / 2.0

    b = Builder("library_w%d" % width_cells)
    contact_shadow(b, W, D + fp, spread=32.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(-door_w / 2.0 - 8.0, door_w / 2.0 + 8.0), lip=12.0)
    # ---- 两层石砌墙（正面不开窗洞：高窗为外贴式铅条窗）
    room_shell(b, W, D, plinth_h, storey, wt, "stone")
    room_shell(b, W, D, z2, storey, wt, "stone")
    b.box_bottom((W + 12.0, D + 12.0, 12.0), (0.0, 0.0), z2 - 12.0, "white_stone")
    # ---- 中央凸出门楼（地面到檐口）+ 山墙铭牌 + 圆窗 + 双扇拱门
    b.box_bottom((fp_w, fp, eave), (0.0, fpy), 0.0, "stone")
    tri_prism_y(b, 0.0, fpy, fp_w / 2.0, fp_rise, eave, fp, "stone")
    for sx in (-1.0, 1.0):
        strut(b, (0.0, fpy - fp / 2.0 - 1.0, eave + fp_rise - 6.0),
              (sx * (fp_w / 2.0 - 4.0), fpy - fp / 2.0 - 1.0, eave + 4.0), 16.0,
              "white_stone")
    rose_window(b, 0.0, fpy - fp / 2.0 - 1.0, eave + fp_rise * 0.40, 24.0, glass=lead,
                spokes=8, tracery="white_stone")
    b.box_bottom((fp_w * 0.60, 10.0, 44.0), (0.0, fpy - fp / 2.0 - 2.0),
                 DOOR_SILL + DOOR_H + 30.0, "stone_dark")
    for k in range(3):
        b.box_bottom((fp_w * 0.46, 5.0, 5.0), (0.0, fpy - fp / 2.0 - 8.0),
                     DOOR_SILL + DOOR_H + 40.0 + k * 11.0, "white_stone")
    arched_doorway(b, 0.0, yf - fp, 34.0, door_w, head=door_w * 0.55, mat="white_stone",
                   profile="round", door_mat="wood", leaves=2, porch_w=door_w + 64.0)
    for k, (dy, dw, dh) in enumerate(((0.0, fp_w + 30.0, 12.0),
                                      (22.0, fp_w + 58.0, 8.0),
                                      (42.0, fp_w + 84.0, 6.0))):
        step_stone(b, w=dw, depth=26.0, h=dh, x=0.0, y=yf - fp - dy - 13.0, z=0.0)
    for sx in (-1.0, 1.0):
        lamp_post(b, sx * (fp_w / 2.0 + 34.0), yf - fp - 60.0, 0.0, h=186.0)
    # ---- 成组铅条高窗：每开间成对两扇、上下两层对齐（跳过中央门楼）
    cs = bay_centers(W, bays)
    for cx in cs:
        if abs(cx) < fp_w / 2.0 + 34.0:
            continue
        for fz in (plinth_h, z2):
            for off in (-16.0, 16.0):
                tw = win_rect("tall_lead", floor_z=fz, mat=lead)
                put_window(b, tw, cx + off, yf, frame_mat="stone_dark")
    roof_gable(b, W, D, rise, over, "slate", z=eave, thickness=15.0,
               mat_under="wood_dark", cap_size=(28.0, 14.0), cap_mat="stone_dark",
               board_mat="wood_dark", board_h=9.0)
    gable_infill(b, W, D, rise, "stone", z=eave, thickness=15.0)

    ob = b.to_object()
    spec = _mk("library", width_cells, {
        "depth": D + fp, "plinth_h": plinth_h, "wall_h": storey * 2.0, "eave_h": eave,
        "rise": rise, "total_h": eave + rise, "overhang": over, "roof_t": 15.0,
        "storey_h": [storey, storey], "double_storey": True,
        "storey_band": (175.0, 208.0),
        "ratio_band": (1.05, 1.60),
        "door": (door_w, DOOR_H), "door_x": 0.0, "bays": bays, "frontispiece": fp_w,
        "window": (44.0, 124.0, 69.0), "lamp_posts": 2,
        "reason": "图书馆：两层石楼（层高 2.62m，两层檐高 5.23m 合规）+ 中央凸出门楼"
                  "自带小山墙抬剪影，剪影比 ≈1.50 属高层公共体量（§8.7 多层 1.2~1.6）",
        "material": "石砌 / 板岩 + 铅条高窗成组 + 门楼铭牌 + 石阶灯柱"})
    return ob, spec


# ---------------------------------------------------------------- 8.4 兵营 barracks

BARRACKS_TIERS = {
    12: dict(D=208.0, plinth=24.0, storey=221, rise=86.0, wt=22.0, door_w=58.0,
             leaf=58.0, porch_w=196.0),
    16: dict(D=240.0, plinth=26.0, storey=221, rise=92.0, wt=24.0, door_w=60.0,
             leaf=60.0, porch_w=220.0),
}


def assemble_barracks(width_cells=12):
    """兵营：石砌底层（加固石底）+ 抹灰上层 + **门楼式垛口入口** + 箭窗 + 盾/矛兵器架 + 军旗。

    与 house/townhouse 的差异（≥2 项肉眼可辨）：
    ① 入口：中央**前凸门楼**（拱门洞 + 垛口压顶 + 旗杆军旗）—— 民居没有；
    ② 防御：底层石墙上成排**窄缝箭窗**（squint）；上层小窗；
    ③ 装备：立面挂**盾牌/长矛架**（八棱盾 + 斜靠长矛）；
    ④ 体量：加固石底占满一层、屋顶平缓（rise 只占层高 ~44%）。
    """
    t = BARRACKS_TIERS[width_cells]
    W = width_cells * CELL
    D, plinth_h, storey = t["D"], t["plinth"], t["storey"]
    rise, wt = t["rise"], t["wt"]
    leaf, pw = t["leaf"], t["porch_w"]
    opening_w = leaf * 2.0 + 6.0
    over = eave_over(W)
    eave = plinth_h + storey * 2.0
    yf = -D / 2.0
    bays = bays_of(width_cells)
    dx = 0.0
    slit = win_rect("squint")
    _dz, up_wins = bay_openings(W, bays, WIN_UP, floor_z=plinth_h + storey,
                                w_scale=0.82, h_scale=0.88)

    b = Builder("barracks_w%d" % width_cells)
    contact_shadow(b, W, D + 30.0, spread=32.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(-opening_w / 2.0 - 8.0, opening_w / 2.0 + 8.0), lip=12.0)
    room_shell(b, W, D, plinth_h, storey, wt, "stone",
               front_openings=[(dx, opening_w, DOOR_SILL, DOOR_SILL + DOOR_H)])
    room_shell(b, W, D, plinth_h + storey, storey, wt, "plaster_old",
               front_openings=win_holes(up_wins))
    quoins(b, W - 2.0 * wt, D, storey * 0.9, "white_stone", 0.0, yf + wt / 2.0,
           plinth_h + 6.0, size=22.0, step=46.0, front=False, sides=True)
    # ---- 底层箭窗（成排窄缝，贴石墙）
    for sx in (-1.0, 1.0):
        for zz in (plinth_h + 66.0, plinth_h + 132.0):
            arrow_slit(b, sx * W * 0.30, yf - 1.0, zz, slit["ow"], slit["oh"])
        _side_slit(b, sx * (W / 2.0 - 1.0), -D * 0.12, plinth_h + 74.0, slit["ow"],
                   slit["oh"])
    # ---- 门楼：前凸拱门洞（真洞）+ 半敞门扇 + 垛口压顶 + 旗杆
    ph = plinth_h + storey + 34.0
    gy = yf - 16.0
    arch_wall(b, pw, ph, 32.0, "stone", dx, gy, 0.0,
              openings=[(0.0, opening_w, DOOR_SILL, DOOR_SILL + DOOR_H, 40.0, "round")])
    b.box((opening_w - 2.0, 26.0, DOOR_SILL + DOOR_H),
          (dx, gy + 4.0, (DOOR_SILL + DOOR_H) / 2.0), "cavity")
    for k in range(2):
        b.box_bottom((11.0, 32.0, DOOR_SILL + DOOR_H + 44.0),
                     (dx + (-1.0 if k == 0 else 1.0) * (opening_w / 2.0 - 5.5), gy),
                     0.0, "stone_dark")
    for sx in (-1.0, 1.0):
        door(b, h=DOOR_H, w=leaf, mat="wood_door", x=dx + sx * (leaf / 2.0 + 3.0),
             y=gy - 16.0, z=DOOR_SILL, frame_mat="timber", frame=9.0, planks=3,
             iron=True)
    b.box_bottom((pw + 16.0, 42.0, 14.0), (dx, gy), ph, "white_stone")
    crenellation(b, pw - 14.0, 30.0, ph + 14.0, "stone", dx, gy, merlon=26.0,
                 gap=16.0, h=26.0, band=12.0)
    # 旗杆压到**檐口遮挡线以下**（z ≤ eave - 出檐×tan20°），否则旗子被自家屋顶挡死
    b.box_bottom((9.0, 9.0, 100.0), (dx + pw * 0.30, gy), ph + 26.0, "wood_dark")
    b.box((54.0, 6.0, 32.0), (dx + pw * 0.30 + 29.0, gy, ph + 26.0 + 68.0),
          "cloth_red")
    # ---- 上层窗 + 兵器架（落地摆在门前，避开窗洞墙垛的窄限制）
    for w in up_wins:
        put_window(b, w, w["cx"], yf, frame_mat="timber")
    for sx in (-1.0, 1.0):
        weapon_rack_wall(b, sx * W * 0.30, yf - 42.0, 0.0, w=90.0, shields=2,
                         spears=3)
    roof_gable(b, W, D, rise, over, "tile", z=eave, thickness=15.0,
               mat_under="wood_dark", cap_size=(30.0, 14.0), cap_mat="stone_dark",
               board_mat="wood_dark", board_h=9.0)
    gable_infill(b, W, D, rise, "plaster_old", z=eave, thickness=14.0)

    ob = b.to_object()
    spec = _mk("barracks", width_cells, {
        "depth": D + 32.0, "plinth_h": plinth_h, "wall_h": storey * 2.0, "eave_h": eave,
        "rise": rise, "total_h": eave + rise, "overhang": over, "roof_t": 15.0,
        "storey_h": [storey, storey], "double_storey": True,
        "storey_band": (175.0, 208.0),
        "door": (opening_w, DOOR_H), "composite_door": True, "door_x": dx, "bays": bays,
        "window": (up_wins[0]["ow"], up_wins[0]["oh"],
                   up_wins[0]["z0"] - (plinth_h + storey)),
        "arrow_slits": 6, "weapon_rack": True, "gate_porch": pw,
        "material": "石砌底层 / 抹灰上层 / 陶瓦 + 门楼垛口 + 兵器架军旗"})
    return ob, spec


# ---------------------------------------------------------------- 8.5 仓库 warehouse

WAREHOUSE_TIERS = {
    12: dict(D=204.0, plinth=28.0, wall=230.0, rise=118.0, wt=22.0, door_w=56.0,
             cargo_w=132.0),
    16: dict(D=236.0, plinth=36.0, wall=268.0, rise=148.0, wt=24.0, door_w=58.0,
             cargo_w=156.0),
}


def assemble_warehouse(width_cells=12):
    """仓库：砖石混构 + **高大门洞（近两层高）** + 铁滑轨推拉门 + 吊臂/滑车 + 堆货平台。

    与 barn（大跨木棚）的差异（≥2 项肉眼可辨）：
    ① 材料：砖墙 + 高石勒脚 + 白石隅石（barn 是通体木板）；
    ② 立面：**近两层高的货门洞** + 铁滑轨/吊环 + 半推开的滑门（barn 是双扇木门）；
    ③ 机械：从上层伸出的**吊臂 + 滑轮 + 悬空货箱**（正面可见）；
    ④ 门前货台（石台 + 货箱/麻袋/木桶堆）。
    """
    t = WAREHOUSE_TIERS[width_cells]
    W = width_cells * CELL
    D, plinth_h, wall_h, rise = t["D"], t["plinth"], t["wall"], t["rise"]
    wt, door_w, cargo_w = t["wt"], t["door_w"], t["cargo_w"]
    over = eave_over(W)
    eave = plinth_h + wall_h
    yf = -D / 2.0
    dx = W * 0.30
    cargo_dx = -W * 0.12
    cargo_z1 = eave - 26.0
    front = [(dx, door_w, plinth_h, plinth_h + DOOR_H),
             (cargo_dx, cargo_w, plinth_h, cargo_z1)]
    gw = win_rect("garret", over=dict(w=28.0, h=32.0))
    gap_w, gx = free_gap(W / 2.0, wall_blocks(dx, door_w, [],
                                              extra=((cargo_dx - cargo_w / 2.0 - 12.0,
                                                      cargo_dx + cargo_w / 2.0 + 12.0),)))
    cl_z = eave - 58.0
    if gap_w > 96.0:
        front += [(gx - 34.0, gw["ow"], cl_z, cl_z + gw["oh"]),
                  (gx + 34.0, gw["ow"], cl_z, cl_z + gw["oh"])]

    b = Builder("warehouse_w%d" % width_cells)
    contact_shadow(b, W, D + 96.0, spread=36.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(cargo_dx - cargo_w / 2.0 - 6.0, cargo_dx + cargo_w / 2.0 + 6.0),
           lip=12.0)
    room_shell(b, W, D, plinth_h, wall_h, wt, "brick", front_openings=front)
    quoins(b, W - 2.0 * wt, D, wall_h * 0.92, "white_stone", 0.0, yf + wt / 2.0,
           plinth_h + 6.0, size=22.0, step=50.0, front=False, sides=True)
    # ---- 人员小门（开在勒脚之上）
    door(b, h=DOOR_H, w=door_w, mat="wood_door", x=dx, y=yf, z=plinth_h,
         frame_mat="iron", frame=9.0, planks=4)
    step_stone(b, w=door_w + 30.0, depth=26.0, h=plinth_h, x=dx, y=yf - 18.0)
    # ---- 货门：洞内暗腔 + 半推开滑门（亮板条，读作"门半开"而不是"缺一面墙"）+ 滑轨/吊环
    ch = cargo_z1 - plinth_h
    b.box((cargo_w - 4.0, 24.0, ch), (cargo_dx, yf + 48.0, plinth_h + ch / 2.0),
          "cavity")
    b.box((cargo_w * 0.62, 8.0, ch), (cargo_dx + cargo_w * 0.19, yf - 7.0,
                                      plinth_h + ch / 2.0), "wood_light")
    for k in range(4):
        b.box((7.0, 4.0, ch), (cargo_dx + cargo_w * 0.19 - cargo_w * 0.24
                               + cargo_w * 0.48 * k / 3.0, yf - 12.0,
                               plinth_h + ch / 2.0), "wood_dark")
    b.box((cargo_w * 0.60, 8.0, ch), (cargo_dx - cargo_w * 0.72, yf - 15.0,
                                      plinth_h + ch / 2.0), "wood_door")
    b.box_bottom((cargo_w * 1.7, 11.0, 11.0), (cargo_dx - cargo_w * 0.1, yf - 9.0),
                 cargo_z1 + 6.0, "iron")
    for k in range(4):
        b.box_bottom((5.0, 5.0, 10.0),
                     (cargo_dx - cargo_w * 0.55 + cargo_w * 1.1 * k / 3.0, yf - 15.0),
                     cargo_z1 - 2.0, "iron")
    b.box_bottom((cargo_w + 26.0, 34.0, 14.0), (cargo_dx, yf - 4.0), cargo_z1 + 17.0,
                 "white_stone")
    # ---- 高侧小窗
    if gap_w > 96.0:
        for cx in (gx - 34.0, gx + 34.0):
            cw = dict(gw, cx=cx, z0=cl_z, z1=cl_z + gw["oh"])
            put_window(b, cw, cx, yf, frame_mat="iron")
    # ---- 吊臂/滑车 + 门前货台（石台 + 货箱/麻袋/木桶）
    hoist_arm(b, cargo_dx, yf, eave - 58.0, reach=120.0, rope=42.0)
    b.box_bottom((cargo_w + 56.0, 66.0, 24.0), (cargo_dx, yf - 50.0), 0.0,
                 "stone_dark")
    crate_stack(b, cargo_dx - 16.0, yf - 44.0, 24.0, seed=width_cells)
    roof_gable(b, W, D, rise, over, "tile", z=eave, thickness=16.0,
               mat_under="wood_dark", cap_size=(32.0, 15.0), cap_mat="stone_dark",
               board_h=10.0)
    gable_infill(b, W, D, rise, "brick", z=eave, thickness=16.0)

    ob = b.to_object()
    spec = _mk("warehouse", width_cells, {
        "depth": D + 68.0, "plinth_h": plinth_h, "wall_h": wall_h, "eave_h": eave,
        "rise": rise, "total_h": eave + rise, "overhang": over, "roof_t": 16.0,
        "storey_h": [wall_h], "door": (door_w, DOOR_H), "door_x": dx, "bays": 0,
        "cargo_door": (cargo_w, ch, plinth_h, cargo_z1), "hoist": True,
        "window": (gw["ow"], gw["oh"], cl_z - plinth_h) if gap_w > 96.0 else None,
        "material": "砖石混构 / 陶瓦 + 高大门洞 + 滑轨推拉门 + 吊臂货台"})
    return ob, spec


# ---------------------------------------------------------------- 8.6 马厩 stable（独立化）

STABLE_TIERS = {
    # **底层必须高过门**（门 150 + 门槛 8 = 158）：旧 low=126/134 让门顶越过地面层顶
    # 8~18px、被上层木墙压住（可见净高 1.73/1.86m，低于设计门高）；抬到 158/162
    # （2.07/2.12m）后门顶有门楣带，屋面 rise 压平以保住剪影带。
    8:  dict(D=160.0, plinth=14.0, low=158.0, up=78.0, rise=88.0, wt=18.0,
             leaf=54.0, post=15.0, hay_dw=60.0, hay_dh=54.0),
    12: dict(D=196.0, plinth=16.0, low=162.0, up=88.0, rise=100.0, wt=20.0,
             leaf=56.0, post=16.0, hay_dw=66.0, hay_dh=58.0),
}


def assemble_stable(width_cells=8):
    """马厩（独立化，不再兜底 barn）：石砌底层大开敞厩门 + 明亮木板上层 + 干草阁楼口 + 拴马桩。

    与 barn（深色木板通高 + 双扇门）的差异（≥2 项肉眼可辨）：
    ① 材质明度：底层**石砌**、上层**wood_light 明木板**（barn 通体深木板 → 黑盒子），
       墙面明度显著抬升；
    ② 立面：大开敞厩门洞内是**两道横栏 + 立柱**（读作隔栏厩舍，不是封死的大门）；
    ③ 附属：干草阁楼口（真洞 + 上翻门板）+ 门前拴马桩 + 槽料；
    ④ 屋顶换陶瓦（barn 是木板顶）。
    """
    t = STABLE_TIERS[width_cells]
    W = width_cells * CELL
    D, plinth_h, low, up = t["D"], t["plinth"], t["low"], t["up"]
    rise, wt, leaf = t["rise"], t["wt"], t["leaf"]
    post_s, hay_dw, hay_dh = t["post"], t["hay_dw"], t["hay_dh"]
    opening_w = leaf * 2.0 + 6.0
    over = eave_over(W)
    z_mid = plinth_h + low
    eave = z_mid + up
    yf, yb = -D / 2.0, D / 2.0
    vent = win_rect("vent", floor_z=plinth_h)
    vents = [dict(vent, cx=-W * 0.37), dict(vent, cx=W * 0.37)]
    hdx = -W * 0.26

    b = Builder("stable_w%d" % width_cells)
    contact_shadow(b, W, D, spread=28.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(-opening_w / 2.0 - 6.0, opening_w / 2.0 + 6.0), lip=9.0)
    # ---- 底层：石砌 + 大开敞厩门 + 侧通风
    room_shell(b, W, D, plinth_h, low, wt, "stone",
               front_openings=[(0.0, opening_w, DOOR_SILL, DOOR_SILL + DOOR_H)]
                              + win_holes(vents),
               side_openings=[(-D * 0.14, vent["ow"], vent["z0"], vent["z1"])])
    # 大开敞厩门 = 木门框 + **下半扇实木半门** + 上半立柱/横栏（读作隔栏厩舍，
    # 不是封死的大门；不要在两扇全高门板上再叠立柱 —— 会糊成木笼）。
    for sx in (-1.0, 1.0):
        b.box_bottom((11.0, 16.0, DOOR_H + 12.0),
                     (sx * (opening_w / 2.0 + 5.5), yf), DOOR_SILL - 6.0, "timber")
    b.box_bottom((opening_w + 22.0, 16.0, 13.0), (0.0, yf), DOOR_SILL + DOOR_H,
                 "timber")
    for sx in (-1.0, 1.0):
        b.box((leaf - 3.0, 7.0, 76.0), (sx * (leaf / 2.0 + 2.0), yf - 4.0,
                                        DOOR_SILL + 38.0), "wood_door")
        b.box((6.0, 4.0, 68.0), (sx * (leaf / 2.0 + 2.0), yf - 8.0,
                                 DOOR_SILL + 38.0), "timber")
    for px in (-opening_w * 0.30, 0.0, opening_w * 0.30):
        b.box_bottom((9.0, 12.0, 66.0), (px, yf - 2.0), DOOR_SILL + 80.0,
                     "wood_light")
    b.box((opening_w - 6.0, 9.0, 9.0), (0.0, yf - 2.0, DOOR_SILL + 140.0),
          "wood_light")
    step_stone(b, w=opening_w + 30.0, depth=28.0, h=10.0, x=0.0, y=yf - 19.0)
    for w in vents:
        put_window(b, w, w["cx"], yf, frame_mat="wood_dark")
    # ---- 上层：明亮木板墙（四面封 + 前墙留干草阁楼口，阁楼**封闭带小门** →
    # 与 hayloft 的"整面开敞草垛外露"明确分家）+ 角柱
    z_loft = z_mid + 16.0
    wall_panel(b, W, up, 13.0, "wood_light", 0.0, yb - 6.5, z_mid)
    wall_panel(b, W, up, 13.0, "wood_light", 0.0, yf + 6.5, z_mid,
               openings=[(hdx, hay_dw, z_loft, z_loft + hay_dh)])
    for sx in (-1.0, 1.0):
        wall_panel(b, D, up, 13.0, "wood_light", sx * (W / 2.0 - 6.5), 0.0, z_mid,
                   axis="Y")
        for yy in (yb - post_s / 2.0, yf + post_s / 2.0):
            post(b, post_s, up, "wood_dark", sx * (W / 2.0 - post_s / 2.0), yy, z_mid)
    posts_x = [0.0] if width_cells <= 8 else [-W / 4.0, W / 4.0]
    for px in posts_x:
        post(b, post_s, up, "wood_dark", px, yf + post_s / 2.0, z_mid)
    for yy in (yf + post_s / 2.0, yb - post_s / 2.0):
        beam(b, W, 17.0, 15.0, "wood_dark", 0.0, yy, eave - 15.0)
    for sx in (-1.0, 1.0):
        beam(b, D - post_s, 15.0, 15.0, "wood_dark",
             sx * (W / 2.0 - post_s / 2.0), 0.0, eave - 15.0, axis="Y")
    hay_door(b, hay_dw, hay_dh, x=hdx, y=yf, z=z_loft, mat="wood_light",
             frame_mat="timber")
    # ---- 拴马桩 + 草料槽（前场；横杆收短压低，别在门前读成一道围栏）
    for sx in (-1.0, 1.0):
        post(b, 12.0, 80.0, "wood_dark", sx * W * 0.34, yf - 58.0)
    beam(b, W * 0.62, 10.0, 10.0, "wood_dark", 0.0, yf - 58.0, 62.0)
    b.box_bottom((76.0, 26.0, 18.0), (W * 0.24, yf + D * 0.16), 0.0, "wood_light")
    roof_gable(b, W, D, rise, over, "tile", z=eave, thickness=14.0,
               mat_under="wood_dark", cap_size=(30.0, 14.0), cap_mat="stone_dark",
               board_mat="wood_dark", board_h=8.0)
    gable_w = win_rect("garret", bay_w=D * 0.5, floor_z=eave,
                       over=dict(w=32.0, h=34.0))
    gable_w["u"] = -D * 0.12
    gable_infill(b, W, D, rise, "wood_light", z=eave, thickness=13.0,
                 hole=(gable_w["u"], gable_w["ow"], gable_w["z0"], gable_w["z1"]))
    for sx in (-1.0, 1.0):
        gable_timber(b, D, rise, "timber", (sx * (W / 2.0), 0.0), eave,
                     axis="Y", face_dir=sx, thick=11.0)
        put_window(b, gable_w, gable_w["u"], sx * (W / 2.0), axis="Y", face_dir=sx)

    ob = b.to_object()
    spec = _mk("stable", width_cells, {
        "depth": D, "plinth_h": plinth_h, "wall_h": low + up, "eave_h": eave,
        "rise": rise, "total_h": eave + rise, "overhang": over, "roof_t": 14.0,
        "storey_h": [low, up], "door": (opening_w, DOOR_H), "composite_door": True,
        "door_x": 0.0, "open_stall": True, "hay_loft": True, "tether_posts": 2,
        "material": "石砌底层 / 明亮木板上层 / 陶瓦 + 开敞厩门 + 干草阁楼口"})
    return ob, spec


# ---------------------------------------------------------------- 8.7 柱撑草棚 shelter（独立化）

SHELTER_TIERS = {
    4: dict(D=112.0, post_h=124.0, rise=36.0, post=16.0, roof_t=15.0),
    6: dict(D=150.0, post_h=170.0, rise=58.0, post=17.0, roof_t=17.0),
    # 8 格档：city_layout 的 shelter 声明宽度含 8（村/城档 production 区），必须能装配
    8: dict(D=186.0, post_h=188.0, rise=66.0, post=18.0, roof_t=18.0),
}


def assemble_shelter(width_cells=6):
    """柱撑草棚（独立化，不再兜底 barn）：四柱撑草顶、三面开敞、可放辎重。

    创始人早期点名的"几根柱子那种草棚"——本批做成独立 def：
    ① 只有四角柱（6 格加两根前中柱）+ 檐檩 + 斜撑，**三面开敞**（只封背面下半）；
    ② 草顶更薄、出檐按宽 20.5%；
    ③ 棚下放辎重（货箱/麻袋/木桶/草垛）+ 斜靠板材 —— 与 smithy1（有后墙 + 铁炉铁砧）分家。
    """
    t = SHELTER_TIERS[width_cells]
    W = width_cells * CELL
    D, post_h, rise, post_s = t["D"], t["post_h"], t["rise"], t["post"]
    roof_t = t["roof_t"]
    over = eave_over(W)
    yf = -D / 2.0 + post_s / 2.0
    yb = D / 2.0 - post_s / 2.0

    b = Builder("shelter_w%d" % width_cells)
    contact_shadow(b, W, D * 1.12, spread=26.0)
    for sx in (-1.0, 1.0):
        for yy in (yb, yf):
            post(b, post_s, post_h, "wood_dark", sx * (W / 2.0 - post_s / 2.0), yy)
    posts_x = [] if width_cells <= 4 else [-W / 4.0, W / 4.0]
    for px in posts_x:
        post(b, post_s, post_h, "wood_dark", px, yf)
    for yy in (yf, yb):
        beam(b, W, 16.0, 15.0, "wood_dark", 0.0, yy, post_h - 15.0)
    for sx in (-1.0, 1.0):
        beam(b, D - post_s, 15.0, 15.0, "wood_dark",
             sx * (W / 2.0 - post_s / 2.0), 0.0, post_h - 15.0, axis="Y")
        strut(b, (sx * (W / 2.0 - post_s - 2.0), yf, post_h - 38.0),
              (sx * (W / 2.0 - 70.0), yf, post_h - 4.0), 10.0, "wood_dark")
    # 背面下半封板（其余三面开敞），压得更矮，免得把开敞读成"矮房子"
    wall_panel(b, W, post_h * 0.30, 12.0, "wood_light", 0.0, yb + 6.0, 0.0)
    # 开放棚的顶棚用**亮望板**（mat_under=wood_light）：暗顶棚会把柱子吞掉，
    # 柱子必须衬在亮底上才读得出"几根柱子撑着一个草顶"。
    roof_gable(b, W, D, rise, over, "thatch", z=post_h, thickness=roof_t,
               mat_under="wood_light", cap_size=(30.0, 15.0), cap_mat="thatch",
               board_mat="wood_dark", board_h=8.0, eave_ao=False)
    # ---- 棚下辎重（只留三件、全压在后半棚左侧，前三面留空读开敞）
    b.box_bottom((52.0, 36.0, 36.0), (-W * 0.22, D * 0.24), 0.0, "wood_light")
    b.box_bottom((47.0, 38.0, 5.0), (-W * 0.22, D * 0.24), 0.0, "wood_dark")
    barrel(b, x=-W * 0.02, y=D * 0.26, z=0.0, r=12.0, h=34.0, lid=True)
    hay_heap(b, W * 0.20, yb - D * 0.20, 0.0, w=W * 0.24, d=D * 0.18, h=26.0,
             rows=1, seed=width_cells + 3)

    ob = b.to_object()
    spec = _mk("shelter", width_cells, {
        "depth": D, "plinth_h": 0.0, "wall_h": post_h, "eave_h": post_h,
        "rise": rise, "total_h": post_h + rise, "overhang": over, "roof_t": roof_t,
        "storey_h": [post_h], "door": None, "open_shed": True, "columns": 4,
        "cargo": True,
        "material": "木柱 / 茅草顶 + 三面开敞 + 辎重"})
    return ob, spec


ASSEMBLERS["mage_tower"] = assemble_mage_tower
ASSEMBLERS["alchemy"] = assemble_alchemy
ASSEMBLERS["library"] = assemble_library
ASSEMBLERS["barracks"] = assemble_barracks
ASSEMBLERS["warehouse"] = assemble_warehouse
ASSEMBLERS["stable"] = assemble_stable
ASSEMBLERS["shelter"] = assemble_shelter

#: 批次 D3b 探针条目（追加在既有条目之后，不动既有 —— 既有各条判定必须不变）
PROBE_LIST += [("mage_tower", 4), ("mage_tower", 6), ("mage_tower", 8),
               ("alchemy", 8), ("alchemy", 12),
               ("library", 12), ("library", 16),
               ("barracks", 12), ("barracks", 16),
               ("warehouse", 12), ("warehouse", 16),
               ("stable", 8), ("stable", 12),
               ("shelter", 4), ("shelter", 6), ("shelter", 8)]


# ================================================================ §9 行政与地标装配器（行政/地标轮）
#
# 6 个新 def（依据 `docs/技术/架构/聚落等级与建筑分级.md` §二 行政阶梯 L1~L5 + §五 想象力
# 扩展 + §7.1 P0 清单）：council_hall / town_hall / governor_palace / imperial_palace /
# belfry / mint。硬口径：L4 起行政建筑取代教堂成为城市最高点（总督府 ~800+ 压过
# cathedral 770、宫殿 ~1000+）；塔类用现实塔比例（§0.3）；全部过棱线高光门禁
# （BEV_* 倒角三档 + 端头封端）。
# 纪律同前批：只新增函数/常量/参数表；既有装配器、WINDOW_SPEC 既有条目、既有 PROBE_LIST
# 条目一律不动；窗走 §0.5 窗表（禁写死 ow/oh/窗台），屋顶走 roof_gable/cone_roof/dome_cap，
# 烟囱走 chimney（落地 + 泛水裙），旗/钟/公告板是"建筑自带的行政识别件"（同 hang_sign_iron
# 的自带理由：道具层概率挂载保不住识别符号）。

#: bronze/patina（materials.py 已注册）在纯色回退时的兜底色（纯追加，materials 缺席时免落抹灰色）
SPEC_COLOR["bronze"] = ((0.66, 0.52, 0.30), 0.55, 0.55)
SPEC_COLOR["patina"] = ((0.52, 0.58, 0.53), 0.62, 0.35)
SPEC_COLOR["cloth_blue"] = ((0.13, 0.20, 0.38), 0.92, 0.0)
SPEC_COLOR["cloth_ochre"] = ((0.62, 0.44, 0.16), 0.92, 0.0)


# ---------------------------------------------------------------- 9.0 行政识别件模块

def flag_pole(b, x, y, z=0.0, h=250.0, cloth="cloth_red", flag_w=52.0, flag_h=78.0,
              style="banner", finial="bronze"):
    """旗杆：杆身 + 顶尖球 + 横臂 + 垂幅旗（style="banner"，仪仗旗读法）或侧飘旗（"pennant"）。"""
    b.cylinder((x, y, z + h * 0.5), 4.5, h, "wood_dark", segments=8, bevel=BEV_SMALL)
    b.cylinder((x, y, z + h + 6.0), 2.6, 14.0, finial, segments=8)
    b.cylinder((x, y, z + h + 14.0), 5.5, 4.0, finial, segments=8)
    if style == "banner":            # 垂幅旗：横臂 + 双条垂布（端头剪角用两条不等长表达）
        b.box_bottom((3.0, 3.0, flag_w), (x, y), z + h - flag_w - 4.0, "iron")
        b.box((flag_w * 0.46, 4.0, flag_h),
              (x - flag_w * 0.25, y, z + h - flag_w - 8.0 - flag_h * 0.5), cloth)
        b.box((flag_w * 0.46, 4.0, flag_h * 0.84),
              (x + flag_w * 0.25, y, z + h - flag_w - 8.0 - flag_h * 0.42), cloth)
    else:                            # 侧飘旗：旗面 + 旗索
        b.box((flag_w, 4.0, flag_h * 0.62), (x + flag_w * 0.52, y,
                                             z + h - flag_h * 0.42), cloth)
        strut(b, (x + flag_w, y, z + h - flag_h * 0.72),
              (x + flag_w, y, z + h - flag_h * 0.16), 3.0, "iron")


def notice_board(b, x, y, z=0.0, w=86.0):
    """公告板（行政建筑自带识别件）：双柱 + 板体 + 披檐 + 告示纸（canvas）。"""
    ph = 152.0
    for sx in (-1.0, 1.0):
        post(b, 9.0, ph, "wood_dark", x + sx * (w * 0.5 - 5.0), y)
    bz = z + ph - 86.0
    b.box_bottom((w, 6.0, 66.0), (x, y), bz, "wood_light", bevel=BEV_MID)
    b.box_bottom((w + 12.0, 16.0, 10.0), (x, y - 3.0), bz + 66.0, "wood_dark",
                 bevel=BEV_MID)
    for i in range(3):               # 告示纸（高低错落）
        px = x - w * 0.28 + w * 0.28 * i
        b.box((19.0, 2.0, 25.0), (px, y - 4.0, bz + 33.0 + 5.0 * (i % 2)), "canvas")


def clock_face(b, x, y_face, z, r, ring="white_stone", face="plaster", trim="bronze"):
    """钟面（凸出墙面，朝 -Y）：石圈 + 钟盘 + 四分刻度 + 双针。y_face = 墙面外皮。"""
    b.cylinder((x, y_face - 5.0, z), r * 1.14, 10.0, ring, segments=18, axis="Y",
               bevel=BEV_SMALL, bevel_threshold=70.0)
    b.cylinder((x, y_face - 11.0, z), r, 6.0, face, segments=18, axis="Y")
    b.cylinder((x, y_face - 14.5, z), r * 0.11, 3.0, trim, segments=8, axis="Y")
    for k in range(4):               # 12/3/6/9 点刻度（显式四象限，别用 sin/cos 凑）
        off = r * 0.78
        if k % 2 == 0:               # 12/6：竖刻度
            zz = z + (off if k == 0 else -off)
            b.box_bottom((4.5, 2.0, r * 0.20), (x, y_face - 14.5),
                         zz - r * 0.10, "iron")
        else:                        # 3/9：横刻度
            xx = x + (off if k == 1 else -off)
            b.box_bottom((r * 0.20, 2.0, 4.5), (xx, y_face - 14.5), z - 2.25,
                         "iron")
    strut(b, (x, y_face - 16.0, z), (x, y_face - 16.0, z + r * 0.58), 3.5, "iron")
    strut(b, (x, y_face - 16.0, z), (x + r * 0.42, y_face - 16.0, z + r * 0.14),
          2.8, "iron")


def dome_cap(b, x, y, z, r, h, mat, segments=20, drum=0.0, drum_mat="white_stone",
             finial_h=24.0, finial_mat="bronze"):
    """穹顶：鼓座（可选，带檐口高光棱）+ 三段收分穹壳 + 顶针（金/铜）。z = 鼓座底。

    三段圆柱连续收分（0.46/0.34/0.20 高度比，半径 1.00→0.90→0.60→0.16）近似球壳——
    比"一个 taper 圆锥"读作穹顶而不是尖塔。"""
    if drum > 0.0:
        b.cylinder((x, y, z + drum * 0.5), r * 1.08, drum, drum_mat, segments=segments)
        b.cylinder((x, y, z + drum), r * 1.14, 7.0, drum_mat, segments=segments,
                   bevel=BEV_BIG)
    zz = z + drum
    for (f, k0, k1) in ((0.46, 1.00, 0.90), (0.34, 0.90, 0.60), (0.20, 0.60, 0.16)):
        hh = h * f
        b.cylinder((x, y, zz + hh * 0.5), r * k0, hh, mat, segments=segments,
                   taper=k1 / k0)
        zz += hh
    b.cylinder((x, y, zz + finial_h * 0.38), max(2.4, r * 0.05), finial_h * 0.76,
               finial_mat, segments=8)
    b.cylinder((x, y, zz + finial_h + 4.0), max(4.0, r * 0.16), 6.0, finial_mat,
               segments=10)
    return {"top": zz + finial_h + 7.0}


def bell(b, x, y, z_top, r=20.0, mat="bronze"):
    """铜钟：悬梁 + 钟纽 + 收分钟体 + 外翻钟唇 + 钟舌。z_top = 悬挂梁底。"""
    b.box_bottom((r * 3.6, 12.0, 10.0), (x, y), z_top, "wood_dark", bevel=BEV_MID,
                 ends=((1, 0, 0), "wood_end"))
    b.cylinder((x, y, z_top - 9.0), r * 0.28, 12.0, mat, segments=10)
    body_h = r * 2.6
    b.cylinder((x, y, z_top - 15.0 - body_h * 0.5), r, body_h, mat, segments=14,
               taper=0.52)
    b.cylinder((x, y, z_top - 15.0 - body_h - 4.0), r * 1.14, 8.0, mat, segments=14)
    b.cylinder((x, y, z_top - 15.0 - body_h - 16.0), r * 0.16, r * 0.9, "iron",
               segments=8)
    return {"lip_z": z_top - 15.0 - body_h - 8.0}


def sentry_box(b, x, y, z=0.0, w=66.0, d=56.0, h=116.0):
    """卫兵位（岗亭）：石板底 + 三面石墙（正面开） + 四坡石板顶。"""
    b.box_bottom((w + 12.0, d + 12.0, 8.0), (x, y), z, "stone_dark", bevel=BEV_BIG)
    z0 = z + 8.0
    b.box_bottom((12.0, d, h), (x - w * 0.5 + 6.0, y), z0, "stone", bevel=BEV_MID)
    b.box_bottom((12.0, d, h), (x + w * 0.5 - 6.0, y), z0, "stone", bevel=BEV_MID)
    b.box_bottom((w, 12.0, h), (x, y + d * 0.5 - 6.0), z0, "stone", bevel=BEV_MID)
    b.box_bottom((w - 24.0, 6.0, 46.0), (x, y + d * 0.5 - 10.0), z0 + 6.0,
                 "cavity")                          # 正面看得到暗腔（不读成白墩）
    cone_roof(b, x, y, z0 + h, max(w, d) * 0.70, 30.0, "slate", segments=4)


def grand_stair(b, x, y_front, z_top, w=250.0, n=5, step_h=11.0, step_d=32.0,
                mat="stone"):
    """大台阶：自 y_front（最下一级前缘）向 +Y 升到 z_top；越低越宽（正式读法）。

    每级都是落地实心箱（不做悬空踏步），顶面棱 = 20° 俯视高光线 → BEV_BIG。"""
    for i in range(n):
        zz = z_top - (n - i) * step_h
        yy = y_front + step_d * i + step_d * 0.5
        b.box_bottom((w + (n - 1 - i) * 10.0, step_d, zz + step_h), (x, yy), 0.0,
                     mat, bevel=BEV_BIG)


def pilaster_strip(b, x, y_wall, z0, z1, w=16.0, depth=9.0, mat="white_stone"):
    """壁柱（贴墙竖条）：古典立面分缝，顶底端头封端。"""
    b.box_bottom((w, depth, z1 - z0), (x, y_wall - depth * 0.3), z0, mat,
                 bevel=BEV_MID, ends=((0, 0, 1), end_grain_mat(mat) or mat))


def roundel_emblem(b, x, y_face, z, r=30.0, ring_mat="white_stone",
                   core_mat="bronze"):
    """徽章圆雕（凸出墙面）：石环 + 金属芯 + 四向短梁（镇徽/省徽的通用读法）。"""
    b.cylinder((x, y_face - 5.0, z), r, 10.0, ring_mat, segments=16, axis="Y")
    b.cylinder((x, y_face - 10.5, z), r * 0.70, 5.0, core_mat, segments=16, axis="Y")
    for k in range(4):
        a = math.pi * 0.5 * k
        strut(b, (x + math.cos(a) * r * 0.24, y_face - 13.0,
                  z + math.sin(a) * r * 0.24),
              (x + math.cos(a) * r * 0.94, y_face - 13.0,
               z + math.sin(a) * r * 0.94), 6.0, "iron")


def arched_window(b, x, y_wall, z0, w, h, head, glass="glass", ring="white_stone",
                  sill=True, depth=10.0):
    """圆拱窗（行政立面主窗型）：凹玻璃 + 拱头 + 外圈料石 + 窗台（尺寸由调用方从窗表解出）。

    y_wall = 墙面外皮；玻璃/石圈按惯例再前探 4（同 cathedral 的 lancet_window 调用法）。"""
    lancet_window(b, x, y_wall - 4.0, z0, w, h, head=head, profile="round",
                  glass=glass, ring=ring, depth=depth, sill=sill)


# ---------------------------------------------------------------- 9.1 村议事小屋 council_hall

COUNCIL_TIERS = {
    # 单层（带门层 200px = 2.62m）+ 阁楼；与 cottage 的可辨差异：木板顶（vs 茅草）、
    # 门廊 + 公告板 + 村旗 + 村徽（剪影/开口两项差异）
    8: dict(D=170.0, plinth=16.0, wall=200.0, rise=104.0, wt=18.0, door_w=54.0),
}


def assemble_council_hall(width_cells=8):
    """村议事小屋（行政阶梯 L1）：单层 + 阁楼，木骨 + 木瓦顶；门廊长椅 + 公告板 +
    村旗 + 村徽木牌 —— 朴素但"有权威感"（村里唯一挂旗贴告示的房子）。"""
    t = COUNCIL_TIERS[width_cells]
    W = width_cells * CELL
    D, plinth_h, wall_h, rise = t["D"], t["plinth"], t["wall"], t["rise"]
    wt, door_w = t["wt"], t["door_w"]
    over = eave_over(W)
    eave = plinth_h + wall_h
    yf = -D / 2.0
    bays = bays_of(width_cells)
    dx, wins = bay_openings(W, bays, "hall", door_w=door_w, door_bay=0,
                            floor_z=plinth_h)
    side_w = win_rect("side", bay_w=D, floor_z=plinth_h, shutters=True)
    side_w["u"] = -D * 0.16
    gable_w = win_rect("garret", bay_w=D * 0.5, floor_z=eave)
    gable_w["u"] = -D * 0.12

    b = Builder("council_hall_w%d" % width_cells)
    contact_shadow(b, W, D, spread=28.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(dx - door_w / 2.0 - 6.0, dx + door_w / 2.0 + 6.0), lip=10.0)
    room_shell(b, W, D, plinth_h, wall_h, wt, "plaster",
               front_openings=[(dx, door_w, DOOR_SILL, DOOR_SILL + DOOR_H)]
                              + win_holes(wins),
               side_openings=[(side_w["u"], side_w["ow"], side_w["z0"],
                               side_w["z1"])])
    timber_frame(b, W, wall_h, "timber", (0.0, yf), plinth_h, depth=7.0, post=14.0,
                 top_band=18.0, bays=bays, braces=True,
                 openings=[(dx, door_w)] + [(w["cx"], w["ow"]) for w in wins])
    door(b, h=DOOR_H, w=door_w, mat="wood_door", x=dx, y=yf, z=DOOR_SILL,
         frame_mat="timber", planks=4, iron=True)
    step_stone(b, w=door_w + 42.0, depth=30.0, h=11.0, x=dx, y=yf - 20.0)
    for w in wins:
        put_window(b, w, w["cx"], yf)
    put_window(b, side_w, side_w["u"], W / 2.0, axis="Y", face_dir=1.0)
    # ---- 门廊：双斜撑柱 + 披檐 + 门侧长椅（"议事的门廊"，民居没有）
    porch_z = plinth_h + DOOR_SILL + DOOR_H + 30.0
    door_pentice(b, dx, yf, porch_z, w=door_w + 108.0, depth=56.0, drop=28.0,
                 mat="wood_roof", brace_mat="timber")
    for sx in (-1.0, 1.0):
        post(b, 14.0, porch_z - plinth_h - 10.0, "timber",
             dx + sx * (door_w / 2.0 + 44.0), yf - 38.0, plinth_h)
    bench(b, x=dx + door_w / 2.0 + 62.0, y=yf - 30.0, z=0.0, w=62.0, d=26.0, h=44.0)
    # ---- 村徽木牌（门楣上方）+ 村旗（门廊左柱位）+ 公告板（右前场）
    b.box_bottom((42.0, 8.0, 52.0), (dx, yf - 5.0), porch_z + 4.0, "wood_dark",
                 bevel=BEV_MID)
    b.cylinder((dx, yf - 10.0, porch_z + 30.0), 14.0, 5.0, "white_stone",
               segments=14, axis="Y")
    b.cylinder((dx, yf - 13.0, porch_z + 30.0), 8.0, 4.0, "iron", segments=14,
               axis="Y")
    flag_pole(b, dx - door_w / 2.0 - 76.0, yf - 74.0, 0.0, h=248.0,
              cloth="cloth_red", flag_w=40.0, flag_h=58.0, style="pennant",
              finial="wood_dark")
    notice_board(b, dx + door_w / 2.0 + 108.0, yf - 46.0, 0.0, w=80.0)
    # ---- 屋顶（木板瓦顶，区别于 cottage 茅草）+ 两端阁楼小窗
    roof_gable(b, W, D, rise, over, "wood_roof", z=eave, thickness=17.0,
               mat_under="wood_dark", cap_size=(32.0, 15.0), cap_mat="wood_dark",
               board_h=11.0, uv_swap=True)
    gable_infill(b, W, D, rise, "plaster", z=eave, thickness=14.0,
                 hole=(gable_w["u"], gable_w["ow"], gable_w["z0"], gable_w["z1"]))
    for sx in (-1.0, 1.0):
        gable_timber(b, D, rise, "timber", (sx * (W / 2.0), 0.0), eave,
                     axis="Y", face_dir=sx, thick=11.0)
        put_window(b, gable_w, gable_w["u"], sx * (W / 2.0), axis="Y",
                   face_dir=sx, frame_mat="timber")
    # ---- 落地烟囱（山墙端，穿前坡泛水，顶冲出屋脊 26——不出脊会被厚坡顶埋掉读成天窗）
    ch_x = W / 2.0 - 10.0
    ch_y = -D * 0.18
    ch_top = eave + rise + 26.0
    ch_roof = gable_roof_z(eave, rise, D / 2.0 + over, ch_y)
    chimney(b, 30.0, 28.0, ch_top, "stone_dark", ch_x, ch_y, foot=0.0,
            cap_mat="white_stone", cap=11.0, roof=ch_roof, skirt_h=20.0,
            skirt_lip=8.0)

    ob = b.to_object()
    spec = _mk("council_hall", width_cells, {
        "depth": D, "plinth_h": plinth_h, "wall_h": wall_h, "eave_h": eave,
        "rise": rise, "total_h": ch_top + 11.0, "overhang": over, "roof_t": 17.0,
        "storey_h": [wall_h], "door": (door_w, DOOR_H), "door_x": dx, "bays": bays,
        "floor_h": wall_h,
        "window": (wins[0]["ow"], wins[0]["oh"], wins[0]["z0"] - plinth_h),
        "gable_window": (gable_w["ow"], gable_w["oh"], gable_w["u"], gable_w["z0"]),
        "chimneys": [{"x": ch_x, "y": ch_y, "roof": ch_roof, "top": ch_top + 11.0,
                      "foot": 0.0, "w": 30.0, "d": 28.0}],
        "civic": ["porch", "bench", "notice_board", "flag", "emblem"],
        "material": "抹灰+木骨 / 木瓦顶 + 门廊长椅 + 公告板 + 村旗村徽"})
    return ob, spec


# ---------------------------------------------------------------- 9.2 城市政厅 town_hall

TOWNHALL_TIERS = {
    # 两层（带门层 205）~两层半（阁楼层）；12 格 = 钟挂立面，16 格 = 脊上钟楼（升级识别件）
    # 12 格档 rise 94：384 宽下剪影带上限 576 挤得紧（檐 430 + 坡 + 山墙端点投影）
    12: dict(D=208.0, plinth=20.0, storey=260, rise=94.0, wt=22.0,
             portal=122.0, leaf=58.0, turret=False, low_mat="stone"),
    16: dict(D=236.0, plinth=22.0, storey=260, rise=122.0, wt=24.0,
             portal=122.0, leaf=58.0, turret=True, low_mat="brick"),
}


def assemble_town_hall(width_cells=12):
    """城市政厅（行政阶梯 L2/L3）：石/砖基座 + 抹灰半木上层 + 石柱山花门廊 + 大钟 +
    徽章石雕 + 旗帜列；16 格加脊上钟楼（pyramid 顶小塔楼）。"""
    t = TOWNHALL_TIERS[width_cells]
    W = width_cells * CELL
    D, plinth_h, sh = t["D"], t["plinth"], t["storey"]
    rise, wt = t["rise"], t["wt"]
    portal, leaf = t["portal"], t["leaf"]
    turret, low_mat = t["turret"], t["low_mat"]
    over = eave_over(W)
    eave = plinth_h + sh * 2.0
    z2 = plinth_h + sh
    yf = -D / 2.0
    bays = bays_of(width_cells)
    # ---- 一层开洞：中央拱廊门 + 两侧临街窗（win 表 street 档，官方楼收窄）
    # 16 格档窗外缘让开角部隅石带（±0.36W，±0.40 会撞上 front 隅石）
    wins1 = []
    if width_cells == 12:
        for cx in (-W * 0.33, W * 0.33):
            w = win_rect(WIN_LOW, bay_w=W / 3.0, floor_z=plinth_h, w_scale=0.92)
            w["cx"] = cx
            wins1.append(w)
    else:
        for cx in (-W * 0.24, -W * 0.36, W * 0.24, W * 0.36):
            w = win_rect(WIN_LOW, bay_w=W / 4.0, floor_z=plinth_h, w_scale=0.78)
            w["cx"] = cx
            wins1.append(w)
    # ---- 二层开洞：12 格中央让给大钟，16 格四开间全窗（钟在脊上钟楼）
    skip = (1,) if width_cells == 12 else ()
    _dz, wins2 = bay_openings(W, bays, WIN_UP, floor_z=z2, skip=skip)
    side_w = win_rect(WIN_SIDE, bay_w=D, floor_z=plinth_h, shutters=True)
    side_w["u"] = -D * 0.18

    b = Builder("town_hall_w%d" % width_cells)
    contact_shadow(b, W, D, spread=34.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(-portal / 2.0 - 10.0, portal / 2.0 + 10.0), lip=12.0)
    # ---- 一层：石/砖砌 + 隅石
    room_shell(b, W, D, plinth_h, sh, wt, low_mat,
               front_openings=[(0.0, portal, DOOR_SILL, DOOR_SILL + DOOR_H)]
                              + win_holes(wins1),
               side_openings=[(side_w["u"], side_w["ow"], side_w["z0"],
                               side_w["z1"])])
    quoins(b, W - 2.0 * wt, D, sh * 0.96, "white_stone", 0.0, 0.0,
           plinth_h + 4.0, size=24.0, step=46.0, front=True, sides=True)
    put_window(b, side_w, side_w["u"], W / 2.0, axis="Y", face_dir=1.0)
    for w in wins1:                              # 一层临街窗（洞已开，补框/玻璃/窗台）
        put_window(b, w, w["cx"], yf)
    # ---- 拱廊门（真洞凸门廊：拱洞 + 双扇门 + 拱券石）+ 石柱山花
    arched_doorway(b, 0.0, yf - 12.0, 36.0, portal, head=portal * 0.5,
                   mat=low_mat, door_mat="wood_door", leaves=2,
                   porch_w=portal + 56.0, sill=False, step=False)
    col_z = plinth_h + DOOR_SILL + DOOR_H + 40.0
    for sx in (-1.0, 1.0):
        cx = sx * (portal / 2.0 + 34.0)
        b.box_bottom((34.0, 34.0, 12.0), (cx, yf - 30.0), plinth_h, "white_stone",
                     bevel=BEV_BIG)
        b.cylinder((cx, yf - 30.0, plinth_h + 12.0 + (col_z - plinth_h - 24.0) / 2.0),
                   13.0, col_z - plinth_h - 24.0, "white_stone", segments=12,
                   bevel=BEV_SMALL, bevel_threshold=70.0)
        b.box_bottom((34.0, 34.0, 12.0), (cx, yf - 30.0), col_z - 12.0,
                     "white_stone", bevel=BEV_BIG)
    ped_w = portal + 168.0
    b.box_bottom((ped_w, 46.0, 16.0), (0.0, yf - 32.0), col_z, "white_stone",
                 bevel=BEV_BIG)
    tri_prism_y(b, 0.0, yf - 32.0, ped_w / 2.0, 48.0, col_z + 16.0, 22.0,
                "white_stone")
    step_stone(b, w=portal + 150.0, depth=40.0, h=13.0, x=0.0, y=yf - 40.0)
    # ---- 门侧旗帜（一对）+ 二层徽章石雕
    for sx in (-1.0, 1.0):
        flag_pole(b, sx * (portal / 2.0 + 96.0), yf - 44.0, 0.0, h=286.0,
                  cloth="cloth_red" if sx < 0 else "cloth_blue", flag_w=46.0,
                  flag_h=72.0, style="banner")
    # ---- 二层：抹灰半木 + 腰线
    b.box_bottom((W + 12.0, D + 12.0, 16.0), (0.0, 0.0), z2 - 16.0, "white_stone")
    room_shell(b, W, D, z2, sh, wt, "plaster", front_openings=win_holes(wins2))
    timber_frame(b, W, sh, "timber", (0.0, yf), z2, depth=7.0, post=14.0,
                 top_band=16.0, bays=bays, braces=True,
                 openings=[(w["cx"], w["ow"]) for w in wins2])
    for w in wins2:
        put_window(b, w, w["cx"], yf)
    roundel_emblem(b, 0.0, yf, z2 + sh * 0.44, r=30.0)
    # ---- 大钟：12 格挂立面（徽章上方），16 格上脊钟楼
    z_ridge = eave + rise
    if turret:
        tw = 96.0
        b.box_bottom((tw, tw, 110.0), (0.0, 0.0), z_ridge - 48.0, "plaster",
                     bevel=BEV_MID)
        clock_face(b, 0.0, -tw / 2.0 - 1.0, z_ridge + 6.0, 30.0)
        b.box_bottom((tw + 20.0, tw + 20.0, 12.0), (0.0, 0.0), z_ridge + 62.0,
                     "wood_dark", bevel=BEV_BIG)
        cone_roof(b, 0.0, 0.0, z_ridge + 74.0, tw * 0.62, 58.0, "slate", segments=4)
        b.cylinder((0.0, 0.0, z_ridge + 74.0 + 58.0 + 7.0), 2.6, 16.0, "bronze",
                   segments=8)
        total_top = z_ridge + 74.0 + 58.0 + 15.0
    else:
        clock_face(b, 0.0, yf - 2.0, z2 + sh * 0.74, 38.0)
        total_top = z_ridge + 14.0
    # ---- 坡顶（陶瓦）+ 两端山墙阁楼小窗（"两层半"的读法）
    roof_gable(b, W, D, rise, over, "tile", z=eave, thickness=15.0,
               mat_under="wood_dark", cap_size=(30.0, 15.0), cap_mat="stone_dark",
               board_h=9.0)
    gable_w = win_rect(WIN_GABLE, bay_w=D * 0.5, floor_z=eave)
    gable_w["u"] = -D * 0.13
    gable_infill(b, W, D, rise, "plaster", z=eave, thickness=14.0,
                 hole=(gable_w["u"], gable_w["ow"], gable_w["z0"], gable_w["z1"]))
    for sx in (-1.0, 1.0):
        gable_timber(b, D, rise, "timber", (sx * (W / 2.0), 0.0), eave,
                     axis="Y", face_dir=sx, thick=11.0)
        put_window(b, gable_w, gable_w["u"], sx * (W / 2.0), axis="Y", face_dir=sx)
    # ---- 双烟囱（山墙两端，落地穿顶，顶压屋脊下）
    ch_list = []
    for sx in (-1.0, 1.0):
        ch_x = sx * (W / 2.0 - 18.0)
        ch_y = -D * 0.16
        ch_top = z_ridge - 12.0
        ch_roof = gable_roof_z(eave, rise, D / 2.0 + over, ch_y)
        ch_list.append({"x": ch_x, "y": ch_y, "roof": ch_roof, "top": ch_top + 12.0,
                        "foot": 0.0, "w": 32.0, "d": 28.0})
        chimney(b, 32.0, 28.0, ch_top, "brick", ch_x, ch_y, foot=0.0,
                cap_mat="white_stone", cap=12.0, roof=ch_roof)

    ob = b.to_object()
    spec = _mk("town_hall", width_cells, {
        "depth": D, "plinth_h": plinth_h, "wall_h": sh * 2.0, "eave_h": eave,
        "rise": rise, "total_h": total_top, "overhang": over, "roof_t": 15.0,
        "storey_h": [sh, sh], "double_storey": True,
        "door": (portal, DOOR_H), "composite_door": True, "door_x": 0.0,
        "bays": bays, "floor_h": sh,
        "window": (wins1[0]["ow"], wins1[0]["oh"], wins1[0]["z0"] - plinth_h),
        "window_up": (wins2[0]["ow"], wins2[0]["oh"], wins2[0]["z0"] - z2),
        "gable_window": (gable_w["ow"], gable_w["oh"], gable_w["u"], gable_w["z0"]),
        "chimneys": ch_list, "clock": True, "turret": turret,
        "civic": ["porch_colonnade", "pediment", "clock", "emblem", "flags"],
        "material": "%s底层 + 抹灰半木上层 / 陶瓦 + 石柱山花 + 大钟 + 徽章旗列"
                    % ("石砌" if low_mat == "stone" else "砖砌")})
    return ob, spec


# ---------------------------------------------------------------- 9.3 行省总督府 governor_palace

GOVERNOR_TIERS = {
    # 三层（205×3）：白石 + 砖基座 + 铜顶穹楼 + 双角楼 + 前院围墙门楼
    # 任务书 L4：行政建筑首次夺城市最高点（~800，压过 cathedral 16 的 770）
    16: dict(D=252.0, plinth=26.0, storey=205.0, rise=78.0, wt=24.0,
             portal=122.0, leaf=58.0, court=170.0, wall_h=96.0,
             pav_w=176.0, pav_up=100.0, drum=22.0, dome_h=58.0,
             tur_w=92.0, tur_up=86.0, tur_cone=80.0),
}


def assemble_governor_palace(width_cells=16):
    """行省总督府（行政阶梯 L4）：砖基座 + 白石双 arcade 层 + 中央穹顶楼 + 双角楼 +
    前院围墙门楼 —— 剪影必须压过 cathedral（L4 起行政建筑是城市最高点）。"""
    t = GOVERNOR_TIERS[width_cells]
    W = width_cells * CELL
    D, plinth_h, sh = t["D"], t["plinth"], t["storey"]
    rise, wt = t["rise"], t["wt"]
    portal, leaf = t["portal"], t["leaf"]
    court, wall_h = t["court"], t["wall_h"]
    pav_w, pav_up = t["pav_w"], t["pav_up"]
    eave = plinth_h + sh * 3.0
    z1 = plinth_h + sh
    z2 = z1 + sh
    yf = -D / 2.0
    yf_pav = yf - 26.0
    z_ridge = eave + rise
    aw = win_rect("tall_lead")                    # 拱窗基底尺寸（h=124 铅条高窗档）

    b = Builder("governor_palace_w%d" % width_cells)
    contact_shadow(b, W, D + court, spread=36.0)
    # ---- 前院围墙 + 门楼（先建，在主楼前方）
    gy = yf - court
    for sx in (-1.0, 1.0):
        wx = sx * (W * 0.5 - 30.0)
        b.box_bottom((22.0, court, wall_h), (wx, yf - court * 0.5 - 12.0), 0.0,
                     "brick", bevel=BEV_MID)
        b.box_bottom((34.0, court + 4.0, 10.0), (wx, yf - court * 0.5 - 12.0),
                     wall_h, "white_stone", bevel=BEV_BIG)
        b.cylinder((wx, yf - court - 12.0, wall_h + 14.0), 11.0, 18.0,
                   "white_stone", segments=10)
        b.cylinder((wx, yf - 12.0, wall_h + 14.0), 11.0, 18.0, "white_stone",
                   segments=10)
    gate_w = 200.0
    arch_wall(b, gate_w, wall_h + 88.0, 26.0, "white_stone", 0.0, gy - 13.0, 0.0,
              openings=[(0.0, 96.0, 8.0, 150.0, 48.0, "round")])
    b.box((94.0, 20.0, 150.0), (0.0, gy - 24.0, 83.0), "cavity")
    for sx in (-1.0, 1.0):                        # 铁栅半落门
        for k in range(4):
            px = sx * (12.0 + k * 11.0)
            b.box_bottom((7.0, 7.0, 96.0), (px, gy - 18.0), 62.0, "iron")
        b.box_bottom((52.0, 8.0, 8.0), (sx * 28.5, gy - 18.0), 154.0, "iron")
    ring_stone(b, 0.0, gy - 26.0, 150.0, 54.0, "white_stone", blocks=9, depth=20.0,
               thick=16.0, a0=0.0, a1=math.pi)
    b.box_bottom((gate_w + 16.0, 34.0, 12.0), (0.0, gy - 13.0), wall_h + 76.0,
                 "white_stone", bevel=BEV_BIG)
    for sx in (-1.0, 1.0):                        # 门楼顶球 + 门侧旗
        b.cylinder((sx * (gate_w * 0.5 - 14.0), gy - 13.0, wall_h + 96.0), 12.0,
                   16.0, "bronze", segments=10)
        flag_pole(b, sx * (gate_w * 0.5 + 26.0), gy - 20.0, 0.0, h=252.0,
                  cloth="cloth_red", flag_w=44.0, flag_h=68.0, style="banner")
    for sx in (-1.0, 1.0):
        lamp_post(b, sx * 130.0, gy - 44.0, 0.0, h=196.0)
    step_stone(b, w=150.0, depth=30.0, h=8.0, x=0.0, y=gy - 30.0)
    # ---- 主楼勒脚 + 三层墙（砖基座 / 白石 arcade / 白石殿上层）
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(0.0 - portal / 2.0 - 10.0, portal / 2.0 + 10.0), lip=12.0)
    room_shell(b, W, D, plinth_h, sh, wt, "brick",
               front_openings=[(0.0, portal, DOOR_SILL, DOOR_SILL + DOOR_H)])
    room_shell(b, W, D, z1, sh, wt, "white_stone")
    room_shell(b, W, D, z2, sh, wt, "white_stone")
    quoins(b, W - 2.0 * wt, D, sh, "white_stone", 0.0, 0.0,
           plinth_h + 4.0, size=24.0, step=48.0, front=True, sides=True)
    # ---- 中央凸 Pavilion（门廊体量，上承穹顶楼）+ 拱廊门
    b.box_bottom((pav_w, 44.0, eave + pav_up), (0.0, yf_pav + 22.0), 0.0,
                 "white_stone", bevel=BEV_MID)
    arched_doorway(b, 0.0, yf_pav, 36.0, portal, head=portal * 0.5,
                   mat="white_stone", door_mat="wood_door", leaves=2,
                   porch_w=portal + 60.0, sill=False, step=False)
    step_stone(b, w=portal + 130.0, depth=36.0, h=12.0, x=0.0, y=yf_pav - 26.0)
    # ---- 成排拱窗（S1 基座拱窗 / S2 高拱窗 / S3 殿上层直窗；贴面做法同 library）
    for cx in (-W * 0.32, W * 0.32):
        arched_window(b, cx, yf, plinth_h + 52.0, aw["ow"] * 1.15, aw["oh"] * 0.95,
                      aw["ow"] * 1.15 * 0.5, ring="white_stone")
    for cx in (-W * 0.275, -W * 0.375, W * 0.275, W * 0.375):
        arched_window(b, cx, yf, z1 + 52.0, aw["ow"] * 1.25, aw["oh"],
                      aw["ow"] * 1.25 * 0.5, ring="white_stone")
        arched_window(b, cx, yf, z2 + 58.0, aw["ow"] * 1.10, aw["oh"] * 0.92,
                      aw["ow"] * 1.10 * 0.5, ring="white_stone")
    # pavilion 正面：S2 大拱窗 + S3 圆窗
    arched_window(b, 0.0, yf_pav, z1 + 48.0, 64.0, 128.0, 34.0, ring="white_stone")
    rose_window(b, 0.0, yf_pav - 3.0, z2 + 108.0, 30.0, spokes=8,
                tracery="white_stone")
    # ---- 层间白石腰线（贯通，高光带）
    for zz in (z1, z2):
        b.box_bottom((W + 14.0, D + 14.0, 14.0), (0.0, 0.0), zz - 14.0,
                     "white_stone", bevel=BEV_BIG)
    # ---- 低坡白石顶（穹楼穿脊）+ 双角楼（穿过前坡屋面）
    roof_gable(b, W, D, rise, eave_over(W), "slate", z=eave, thickness=15.0,
               mat_under="wood_dark", cap_size=(30.0, 14.0), cap_mat="stone_dark",
               board_h=9.0)
    for sx in (-1.0, 1.0):
        tx = sx * (W * 0.5 - 56.0)
        b.box_bottom((t["tur_w"], t["tur_w"], t["tur_up"] + 20.0),
                     (tx, yf + 20.0), eave - 20.0, "white_stone", bevel=BEV_MID)
        b.box_bottom((t["tur_w"] + 16.0, t["tur_w"] + 16.0, 12.0),
                     (tx, yf + 20.0), eave + t["tur_up"] - 12.0,
                     "white_stone", bevel=BEV_BIG)
        cone_roof(b, tx, yf + 20.0, eave + t["tur_up"], t["tur_w"] * 0.62,
                  t["tur_cone"], "slate", segments=8)
        b.cylinder((tx, yf + 20.0, eave + t["tur_up"] + t["tur_cone"] + 7.0), 2.4,
                   15.0, "bronze", segments=8)
        blind_arch(b, tx, yf + 20.0 - t["tur_w"] / 2.0 - 1.0, eave + 6.0,
                   t["tur_w"] * 0.30, 64.0, 30.0, mat="cavity", ring="white_stone",
                   blocks=6, depth=8.0)
    # ---- 中央穹顶楼（鼓座 + 铜顶 + 金针）—— 全城最高点
    b.box_bottom((pav_w, 52.0, pav_up), (0.0, yf_pav + 26.0), eave, "white_stone",
                 bevel=BEV_MID)
    arched_window(b, 0.0, yf_pav, eave + 10.0, 56.0, 72.0, 28.0, ring="white_stone",
                  sill=False)
    dm = dome_cap(b, 0.0, yf_pav + 26.0, eave + pav_up, 80.0, t["dome_h"], "patina",
                  drum=t["drum"], drum_mat="white_stone", finial_h=22.0)
    # ---- 双烟囱（后坡，白石）
    ch_list = []
    for sx in (-1.0, 1.0):
        ch_x = sx * W * 0.18
        ch_y = D * 0.16
        ch_top = z_ridge + 6.0
        ch_roof = gable_roof_z(eave, rise, D / 2.0 + eave_over(W), ch_y)
        ch_list.append({"x": ch_x, "y": ch_y, "roof": ch_roof, "top": ch_top + 12.0,
                        "foot": 0.0, "w": 34.0, "d": 30.0})
        chimney(b, 34.0, 30.0, ch_top, "white_stone", ch_x, ch_y, foot=0.0,
                cap_mat="stone_dark", cap=12.0, roof=ch_roof)

    ob = b.to_object()
    spec = _mk("governor_palace", width_cells, {
        "depth": D + court, "plinth_h": plinth_h, "wall_h": sh * 3.0, "eave_h": eave,
        "rise": rise, "total_h": dm["top"], "overhang": eave_over(W),
        "roof_t": 15.0, "storey_h": [sh, sh, sh], "double_storey": True,
        "storey_band": (196.0, 212.0), "ratio_band": (1.20, 1.80),
        "door": (portal, DOOR_H), "composite_door": True, "door_x": 0.0,
        "floor_h": sh, "window": (aw["ow"], aw["oh"], 52.0),
        "dome_top": dm["top"], "forecourt": court, "gate": (96.0, 198.0),
        "civic": ["dome", "corner_turrets", "forecourt_gate", "arcade_rows",
                  "flag_pair", "lamps"],
        "reason": "总督府：三层白石行政体量（205×3 合层高带）+ 穹顶楼 ~800 是任务书 L4 "
                  "首次夺最高点的行政天际线（压过 cathedral16 的 770）；出檐走民居口径",
        "material": "砖基座 + 白石双层 / 铜绿穹顶 + 白石角楼 + 前院门楼旗列"})
    return ob, spec


# ---------------------------------------------------------------- 9.4 帝国宫殿 imperial_palace

IMPERIAL_TIERS = {
    # 单卡做到极致（任务书折中；多卡拼接留待后续）：白石 + 金饰 + 大台阶 + 三段式立面
    # （石基座 + 拱廊层 + 殿上层）+ 穹顶 + 金尖双塔 + 仪仗旗列；~1000+ 全档天际线顶点
    16: dict(D=264.0, plinth=26.0, podium=44.0, storeys=(210.0, 210.0, 205.0),
             rise=74.0, wt=26.0, portal=126.0, leaf=60.0,
             pav_w=190.0, pav_up=96.0, drum=24.0, dome_h=70.0,
             tw_w=108.0, tw_x=200.0, tw_up=150.0, tw_cone=172.0,
             stair_w=260.0, stair_n=4),
}


def assemble_imperial_palace(width_cells=16):
    """帝国宫殿（行政阶梯 L5）：白石台基（大台阶）+ 石基座/拱廊层/殿上层三段式 +
    中央青铜穹顶 + 双金尖塔 + 仪仗旗列 —— 单卡天际线 ~1000+（T5 唯一最高点）。"""
    t = IMPERIAL_TIERS[width_cells]
    W = width_cells * CELL
    D, podium = t["D"], t["podium"]
    s1, s2, s3 = t["storeys"]
    rise, wt = t["rise"], t["wt"]
    portal, leaf = t["portal"], t["leaf"]
    pav_w, pav_up = t["pav_w"], t["pav_up"]
    tw_w, tw_x = t["tw_w"], t["tw_x"]
    # 三段式（§0.3 层高带 196~212）：石基座 s1（210，从台基面起）+ 白石拱廊层 s2 +
    # 白石殿上层 s3；eave = 台基 44 + 625 = 669
    eave = podium + s1 + s2 + s3
    z1 = podium + s1                             # 拱廊层地面
    z2 = z1 + s2                                 # 殿上层地面
    z_g = podium                                 # 石基座层地面（门/窗台基准）
    yf = -D / 2.0
    yf_pav = yf - 26.0
    aw = win_rect("tall_lead")

    b = Builder("imperial_palace_w%d" % width_cells)
    contact_shadow(b, W + 30.0, D + 96.0, spread=36.0)
    # ---- 白石台基（台基前缘供旗列/栏杆/灯柱）+ 大台阶
    pod_d = D + 90.0
    b.box_bottom((W + 24.0, pod_d, podium), (0.0, -45.0), 0.0, "white_stone",
                 bevel=BEV_BIG)
    pod_front = -D / 2.0 - 90.0
    grand_stair(b, 0.0, pod_front - t["stair_n"] * 34.0, podium, w=t["stair_w"],
                n=t["stair_n"], step_h=podium / t["stair_n"], step_d=34.0)
    for sx in (-1.0, 1.0):                       # 台基栏杆（两段，让开台阶）
        railing(b, W * 0.5 - t["stair_w"] * 0.5 - 30.0, x=sx * (W * 0.25
                + t["stair_w"] * 0.25 + 8.0), y=pod_front + 8.0, z=podium,
                mat="white_stone", h=52.0, posts=6, size=9.0)
    for sx in (-1.0, 1.0):                       # 仪仗旗列 + 灯柱
        for fx in (sx * 168.0, sx * 244.0):
            flag_pole(b, fx, pod_front - 16.0, 0.0, h=272.0, cloth="cloth_red",
                      flag_w=48.0, flag_h=84.0, style="banner")
        lamp_post(b, sx * 118.0, pod_front - 20.0, 0.0, h=206.0)
    # ---- 三段式立面：石基座 / 白石拱廊层 / 白石殿上层（台基面上一道石阶带）
    plinth(b, W, D, 12.0, "stone_dark", 0, 0, podium, lip=14.0)
    room_shell(b, W, D, podium, s1, wt, "stone")
    room_shell(b, W, D, z1, s2, wt, "white_stone")
    room_shell(b, W, D, z2, s3, wt, "white_stone")
    quoins(b, W - 2.0 * wt, D, s1, "white_stone", 0.0, 0.0, podium,
           size=24.0, step=50.0, front=True, sides=True)
    # ---- 中央 Pavilion（上承穹顶）+ 青铜拱廊门（门下即台基面）
    b.box_bottom((pav_w, 46.0, eave + pav_up - podium), (0.0, yf_pav + 23.0),
                 podium, "white_stone", bevel=BEV_MID)
    pw_total = DOOR_SILL + DOOR_H + portal * 0.5 + 14.0
    arch_wall(b, portal + 64.0, pw_total, 36.0, "white_stone", 0.0,
              yf_pav + 18.0, podium,
              openings=[(0.0, portal, z_g + DOOR_SILL, z_g + DOOR_SILL + DOOR_H,
                         portal * 0.5, "round")])
    b.box((portal - 2.0, 42.0, DOOR_SILL + DOOR_H + portal * 0.5),
          (0.0, yf_pav + 22.0,
           podium + (DOOR_SILL + DOOR_H + portal * 0.5) * 0.5), "cavity")
    leaf_w = min(60.0, max(DOOR_W_RANGE[0] + 1.0, (portal - 8.0) / 2.0))
    for k in range(2):
        ox = (k - 0.5) * (leaf_w + 4.0)
        door(b, h=DOOR_H, w=leaf_w, mat="wood_door", x=ox, y=yf_pav + 2.0,
             z=z_g + DOOR_SILL, frame_mat="bronze", frame=9.0, planks=4, iron=True)
    ring_stone(b, 0.0, yf_pav - 2.0, z_g + DOOR_SILL + DOOR_H, portal / 2.0 + 8.0,
               "bronze", blocks=11, depth=22.0, thick=17.0, a0=0.0, a1=math.pi)
    # 拱廊门两侧壁柱 + 青青铜楣带（金饰读法）
    for sx in (-1.0, 1.0):
        pilaster_strip(b, sx * (portal / 2.0 + 30.0), yf_pav, z_g,
                       z_g + s1 - 14.0, w=20.0)
    b.box_bottom((pav_w - 8.0, 16.0, 12.0), (0.0, yf_pav + 6.0),
                 z_g + s1 - 12.0, "bronze", bevel=BEV_MID)
    # ---- 成排拱窗（对齐双塔之间的两开间）+ 层间白石/青铜线脚
    for sx in (-1.0, 1.0):
        cx = sx * 117.0
        arched_window(b, cx, yf, z_g + 62.0, aw["ow"] * 1.10, aw["oh"] * 0.92,
                      aw["ow"] * 1.10 * 0.5, ring="white_stone")
        arched_window(b, cx, yf, z1 + 52.0, aw["ow"] * 1.25, aw["oh"],
                      aw["ow"] * 1.25 * 0.5, ring="white_stone")
        arched_window(b, cx, yf, z2 + 56.0, aw["ow"] * 1.10, aw["oh"] * 0.90,
                      aw["ow"] * 1.10 * 0.5, ring="white_stone")
        for zz in (z1, z2):
            b.box_bottom((54.0, D + 12.0, 12.0), (cx, 0.0), zz - 12.0,
                         "white_stone", bevel=BEV_BIG)
        pilaster_strip(b, cx, yf, z_g, eave - 16.0, w=17.0)
    # pavilion 正面拱窗
    arched_window(b, 0.0, yf_pav, z1 + 50.0, 60.0, 122.0, 32.0, ring="white_stone")
    rose_window(b, 0.0, yf_pav - 3.0, z2 + 104.0, 28.0, spokes=8,
                tracery="white_stone")
    # ---- 低坡白石顶（穹顶/双塔穿脊）
    roof_gable(b, W, D, rise, eave_over(W), "slate", z=eave, thickness=15.0,
               mat_under="wood_dark", cap_size=(30.0, 14.0), cap_mat="stone_dark",
               board_h=9.0)
    # ---- 双金尖塔（前沿两角，塔身白石 + 青铜尖顶）—— 全档最高点
    for sx in (-1.0, 1.0):
        tx = sx * tw_x
        b.box_bottom((tw_w, tw_w, eave + t["tw_up"] - z_g), (tx, yf + tw_w / 2.0),
                     z_g, "white_stone", bevel=BEV_MID)
        b.box_bottom((tw_w + 18.0, tw_w + 18.0, 14.0), (tx, yf + tw_w / 2.0),
                     eave + t["tw_up"] - 14.0, "white_stone", bevel=BEV_BIG)
        arched_window(b, tx, yf, z_g + 58.0, 46.0, 96.0, 24.0, ring="white_stone",
                      sill=False)
        arched_window(b, tx, yf, z1 + 54.0, 50.0, 110.0, 26.0, ring="white_stone",
                      sill=False)
        cone_roof(b, tx, yf + tw_w / 2.0, eave + t["tw_up"], tw_w * 0.60,
                  t["tw_cone"], "bronze", segments=8)
        b.cylinder((tx, yf + tw_w / 2.0, eave + t["tw_up"] + t["tw_cone"] + 6.0),
                   3.0, 22.0, "bronze", segments=8)
        b.cylinder((tx, yf + tw_w / 2.0, eave + t["tw_up"] + t["tw_cone"] + 29.0),
                   6.0, 5.0, "bronze", segments=8)
    # ---- 中央青铜穹顶（鼓座 + 穹壳 + 金针）
    dm = dome_cap(b, 0.0, yf_pav + 23.0, eave + pav_up, 86.0, t["dome_h"],
                  "bronze", drum=t["drum"], drum_mat="white_stone", finial_h=26.0)
    arched_window(b, 0.0, yf_pav, eave + 12.0, 54.0, 74.0, 28.0,
                  ring="white_stone", sill=False)
    # ---- 双烟囱（白石，后坡）
    ch_list = []
    for sx in (-1.0, 1.0):
        ch_x = sx * W * 0.14
        ch_y = D * 0.16
        ch_top = eave + rise + 8.0
        ch_roof = gable_roof_z(eave, rise, D / 2.0 + eave_over(W), ch_y)
        ch_list.append({"x": ch_x, "y": ch_y, "roof": ch_roof, "top": ch_top + 12.0,
                        "foot": podium, "w": 34.0, "d": 30.0})
        chimney(b, 34.0, 30.0, ch_top, "white_stone", ch_x, ch_y, foot=podium,
                cap_mat="bronze", cap=12.0, roof=ch_roof)

    ob = b.to_object()
    spec = _mk("imperial_palace", width_cells, {
        "depth": D + 90.0, "plinth_h": podium + 12.0, "wall_h": s1 + s2 + s3,
        "eave_h": eave, "rise": rise, "total_h": max(dm["top"],
                eave + t["tw_up"] + t["tw_cone"] + 34.0),
        "overhang": eave_over(W), "roof_t": 15.0, "storey_h": [s1, s2, s3],
        "double_storey": True, "storey_band": (196.0, 212.0),
        "ratio_band": (1.20, 2.15),
        "door": (portal, DOOR_H), "composite_door": True, "door_x": 0.0,
        "floor_h": s1, "window": (aw["ow"], aw["oh"], 62.0),
        "dome_top": dm["top"], "podium": podium,
        "twin_towers": True, "tower_h": eave + t["tw_up"] + t["tw_cone"],
        "civic": ["grand_stair", "bronze_dome", "twin_gold_spires", "banner_row",
                  "balustrade", "lamps"],
        "reason": "帝国宫殿：任务书 T5 唯一天际线顶点（穹顶 ~1000+，双金尖塔 ~1040），"
                  "白石台基 + 三段式立面 205~210 合层高带；竖向行政纪念体量显式豁免"
                  "单层剪影带；多卡拼接留待后续、本批单卡做到极致",
        "material": "白石 + 石基座 / 青铜穹顶尖塔 + 大台阶 + 仪仗旗列"})
    return ob, spec


# ---------------------------------------------------------------- 9.5 钟楼 belfry

BELFRY_TIERS = {
    # 独立细高塔（现实钟楼比例：钟室开洞层高 ~3m、锥顶 ≤ 塔身）：大城市天际线的
    # "廉价"变奏地标；4 格 = 木塔身，6 格 = 砖塔身（同级两档材质/剪影可辨）
    4: dict(D=124.0, plinth=18.0, shaft=336.0, stage=112.0, cone=128.0,
            door_w=46.0, shaft_mat="wood"),
    6: dict(D=188.0, plinth=20.0, shaft=376.0, stage=120.0, cone=140.0,
            door_w=52.0, shaft_mat="brick"),
}


def assemble_belfry(width_cells=4):
    """钟楼：石基座 + 木/砖塔身（带钟面）+ 钟室（拱洞真洞、铜钟可见）+ 锥顶 +
    顶尖 —— 瘦高剪影，给大城市天际线做"廉价"变奏。"""
    t = BELFRY_TIERS[width_cells]
    W = width_cells * CELL
    D, plinth_h = t["D"], t["plinth"]
    shaft_h, stage_h, cone_h = t["shaft"], t["stage"], t["cone"]
    door_w, shaft_mat = t["door_w"], t["shaft_mat"]
    yf = -D / 2.0
    belf = None                                  # （窗表 belfry 档层高已内化为 bh）
    z_shaft = plinth_h + shaft_h
    z_stage = z_shaft + 14.0                     # 钟室楼板
    z_belltop = z_stage + stage_h

    b = Builder("belfry_w%d" % width_cells)
    contact_shadow(b, W, D, spread=26.0)
    # ---- 基座 + 拱门
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(-door_w / 2.0 - 8.0, door_w / 2.0 + 8.0), lip=10.0)
    arched_doorway(b, 0.0, yf, 32.0, door_w, head=door_w * 0.5,
                   mat="stone", porch_w=door_w + 46.0)
    # ---- 塔身（4 格木板 + 木柱角 / 6 格砖 + 白石隅石）+ 钟面 + 竖窗
    sw = W - (14.0 if shaft_mat == "wood" else 0.0)
    b.box_bottom((sw, D - 10.0, shaft_h), (0.0, 0.0), plinth_h, shaft_mat,
                 bevel=BEV_MID)
    if shaft_mat == "wood":
        for sx in (-1.0, 1.0):
            for sy in (-1.0, 1.0):
                post(b, 18.0, shaft_h, "timber", sx * (sw / 2.0 - 9.0),
                     sy * (D - 10.0) / 2.0, plinth_h)
        for zz in (0.30, 0.62):                  # 木箍带两道
            b.box_bottom((sw + 6.0, D - 4.0, 12.0), (0.0, 0.0),
                         plinth_h + shaft_h * zz, "wood_dark", bevel=BEV_MID)
    else:
        quoins(b, sw, D - 10.0, shaft_h * 0.96, "white_stone", 0.0, 0.0,
               plinth_h + 4.0, size=22.0, step=52.0, front=False, sides=True)
    clock_face(b, 0.0, -(D - 10.0) / 2.0 - 1.0, plinth_h + shaft_h * 0.78,
               min(34.0, W * 0.20))
    for zf in (0.36, 0.58):                      # 塔身竖窗（前 + 两侧）
        zw = win_rect("peephole", floor_z=plinth_h + shaft_h * zf, w_scale=1.15,
                      h_scale=1.25)
        put_window(b, zw, 0.0, -(D - 10.0) / 2.0 - 1.0)
        for sx in (-1.0, 1.0):
            # axis="Y"：u = 沿侧墙的 y 位，face = 墙面 x（u/face 不可换位）
            put_window(b, zw, -D * 0.08, sx * (sw / 2.0 + 1.0), axis="Y",
                       face_dir=sx)
    # ---- 钟室：挑出楼板 + 四角柱 + 前拱洞（真洞见钟）
    b.box_bottom((W + 22.0, D + 22.0, 14.0), (0.0, 0.0), z_shaft, "white_stone",
                 bevel=BEV_BIG)
    for k in range(4):                           # 楼板下斜撑
        a = math.pi * 0.25 + math.pi * 0.5 * k
        strut(b, (math.cos(a) * sw * 0.42, math.sin(a) * (D - 10.0) * 0.42,
                  z_shaft - 16.0),
              (math.cos(a) * (W + 16.0) * 0.44, math.sin(a) * (D + 16.0) * 0.44,
                  z_shaft + 2.0), 11.0, "wood_dark")
    ow = W * (0.54 if shaft_mat == "wood" else 0.46)
    stage_w, stage_d = W + 22.0, D + 22.0
    head = ow * 0.38
    # 拱洞矩形段净高：拱顶（z1+head）必须留在钟室墙内（≤墙顶-8），否则拱头浮出墙面
    bh = stage_h - 14.0 - head
    wall_panel(b, stage_w, stage_h, 12.0, "plaster", 0.0, stage_d / 2.0 - 6.0,
               z_stage)
    for sx in (-1.0, 1.0):
        wall_panel(b, stage_d, stage_h, 12.0, "plaster", sx * (stage_w / 2.0 - 6.0),
                   0.0, z_stage, axis="Y")
        b.box_bottom((14.0, stage_d + 4.0, stage_h + 8.0),
                     (sx * (stage_w / 2.0 - 7.0), 0.0), z_stage - 4.0,
                     "white_stone", bevel=BEV_MID)
    arch_wall1(b, stage_w, stage_h, 16.0, "plaster", 0.0, -stage_d / 2.0 + 8.0,
               z_stage, ow=ow, z0=z_stage + 6.0, z1=z_stage + 6.0 + bh,
               head=head, steps=14)
    # 暗腔收短成薄背板盒：相机在 -Y、y 越小越靠前，前后次序 = 前墙 → 钟 → 亮衬板
    # → 暗腔前脸。谁落在腔体前脸之后，谁就被这面实心前脸整块吃掉
    # （此前钟与衬板"渲染不出来"的根因：都排在了腔前脸之后）。
    b.box((ow - 4.0, 56.0, bh + head),
          (0.0, 4.0, z_stage + 6.0 + (bh + head) * 0.5), "cavity")
    # 钟缩尺 + 前移：整体落在"透过拱洞的可见带"里（悬太高会被拱顶裁头），
    # 青铜钟压在近黑的腔里读不出来，背后衬一块受光木板剪影才立得住；
    # 木 A 字架托梁给"挂钟"的结构读法。
    bell_r = min(17.0, W * 0.115)
    bell_y = -stage_d * 0.26
    bell_z = z_belltop - 24.0
    b.box_bottom((ow + 14.0, 6.0, bh + head), (0.0, bell_y + bell_r * 1.14 + 6.0),
                 z_stage + 6.0, "wood_light")
    for sx in (-1.0, 1.0):                       # 钟室角柱
        b.box_bottom((15.0, 15.0, stage_h), (sx * (stage_w / 2.0 - 8.0),
                                             -stage_d / 2.0 + 8.0), z_stage,
                     "white_stone", bevel=BEV_MID)
    for sx in (-1.0, 1.0):
        post(b, 9.0, stage_h - 30.0, "timber", sx * (bell_r + 14.0),
             bell_y + 6.0, z_stage + 4.0)
    bell(b, 0.0, bell_y, bell_z, r=bell_r)
    # ---- 锥顶（八棱）+ 顶尖
    cone_roof(b, 0.0, 0.0, z_belltop, stage_w * 0.54, cone_h, "slate", segments=8)
    b.cylinder((0.0, 0.0, z_belltop + cone_h + 6.0), 2.6, 18.0, "iron", segments=8)
    b.box_bottom((26.0, 3.0, 3.0), (0.0, 0.0), z_belltop + cone_h + 24.0, "iron")
    total_top = z_belltop + cone_h + 27.0

    ob = b.to_object()
    spec = _mk("belfry", width_cells, {
        "depth": D, "plinth_h": plinth_h, "wall_h": shaft_h, "eave_h": z_belltop,
        "rise": cone_h + 27.0, "total_h": total_top, "overhang": stage_w * 0.03,
        "roof_t": 0.0, "storey_h": [shaft_h], "door": (door_w, DOOR_H),
        "door_x": 0.0, "floor_h": FLOOR_H_SPEC, "window": None,
        "bell_stage": True, "clock": True, "round_tower": False,
        "ratio_exempt": True, "eave_exempt": True,
        "width_exempt": (width_cells < MIN_DOOR_CELLS),
        "reason": "钟楼：独立细高塔（现实钟楼比例：石基座 + 塔身 + 钟室开洞层 + 锥顶），"
                  "竖向地标体量显式豁免单层剪影带；锥顶出檐按钟室宽比例（非民居坡檐口径）",
        "material": "石基座 + %s塔身 / 板岩锥顶 + 铜钟 + 钟面"
                    % ("木构" if shaft_mat == "wood" else "砖砌")})
    return ob, spec


# ---------------------------------------------------------------- 9.6 铸币厂 mint

MINT_TIERS = {
    # 砖石混构两层 + 铁栅重门 + 高窗铁栅 + 铸币烟囱 + 卫兵位（"安全重地"封闭感）
    # 12 格档：rise 86 + 烟囱只出脊 10（384 宽剪影带 ≤576，烟囱铁箍读"工业"即可）
    12: dict(D=212.0, plinth=22.0, storey=260, rise=86.0, wt=22.0, door_w=56.0,
             ch_w=44.0, ch_up=10.0),
    16: dict(D=232.0, plinth=24.0, storey=260, rise=100.0, wt=24.0, door_w=56.0,
             ch_w=48.0, ch_up=44.0),
}


def assemble_mint(width_cells=12):
    """铸币厂：砖墙 + 石勒脚/隅石 + 铁栅重门 + 铁栅高窗 + 铸币烟囱（铁箍）+
    卫兵岗亭 + 箭窗 —— 开口少、墙身实，读"安全重地"。"""
    t = MINT_TIERS[width_cells]
    W = width_cells * CELL
    D, plinth_h, sh = t["D"], t["plinth"], t["storey"]
    rise, wt, door_w = t["rise"], t["wt"], t["door_w"]
    ch_w, ch_up = t["ch_w"], t["ch_up"]
    over = eave_over(W)
    eave = plinth_h + sh * 2.0
    z2 = plinth_h + sh
    yf = -D / 2.0
    high = win_rect("tall_lead", over=dict(bars=True))     # 铁栅高窗
    up = win_rect("hall", over=dict(bars=True))            # 上层铁栅窗
    if width_cells == 12:
        g_x, u_x = (-W * 0.30, W * 0.30), (0.0, -W * 0.32, W * 0.32)
    else:
        # 16 格：地窗两对拉开（±0.185/±0.30 会连成 M 形连洞），外对让开隅石带
        g_x = (-W * 0.16, -W * 0.35, W * 0.16, W * 0.35)
        u_x = (-W * 0.32, -W * 0.12, W * 0.12, W * 0.32)
    gwins = []
    for cx in g_x:
        w = dict(high, cx=cx)
        gwins.append(w)
    uwins = []
    for cx in u_x:
        w = dict(up, cx=cx)
        uwins.append(w)

    b = Builder("mint_w%d" % width_cells)
    contact_shadow(b, W, D, spread=32.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(-door_w / 2.0 - 8.0, door_w / 2.0 + 8.0), lip=12.0)
    # ---- 两层砖墙 + 白石隅石 + 石腰线
    room_shell(b, W, D, plinth_h, sh, wt, "brick",
               front_openings=[(0.0, door_w, DOOR_SILL, DOOR_SILL + DOOR_H)]
                              + win_holes(gwins),
               side_openings=[(-D * 0.16, high["ow"], high["z0"], high["z1"])])
    room_shell(b, W, D, z2, sh, wt, "brick", front_openings=win_holes(uwins))
    quoins(b, W - 2.0 * wt, D, sh * 2.0 * 0.96, "white_stone", 0.0, 0.0,
           plinth_h + 4.0, size=22.0, step=48.0, front=True, sides=True)
    b.box_bottom((W + 12.0, D + 12.0, 14.0), (0.0, 0.0), z2 - 14.0, "white_stone",
                 bevel=BEV_BIG)
    # ---- 铁栅重门：石门框 + 门扇 + 外凸铁栅（半落闸）+ 石铭牌
    for sx in (-1.0, 1.0):
        b.box_bottom((16.0, 22.0, DOOR_H + 22.0), (sx * (door_w / 2.0 + 8.0), yf),
                     DOOR_SILL - 6.0, "white_stone", bevel=BEV_MID)
    b.box_bottom((door_w + 48.0, 20.0, 18.0), (0.0, yf), DOOR_SILL + DOOR_H,
                 "white_stone", bevel=BEV_BIG)
    door(b, h=DOOR_H, w=door_w, mat="wood_door", x=0.0, y=yf, z=DOOR_SILL,
         frame_mat="iron", frame=10.0, planks=4, iron=True)
    for k in range(5):                           # 外凸铁栅（半落）
        px = -door_w * 0.36 + door_w * 0.72 * k / 4.0
        b.box_bottom((7.0, 7.0, DOOR_H * 0.58), (px, yf - 12.0),
                     DOOR_SILL + DOOR_H * 0.42, "iron")
    b.box_bottom((door_w * 0.88, 8.0, 8.0), (0.0, yf - 12.0),
                 DOOR_SILL + DOOR_H * 0.98, "iron")
    b.box_bottom((door_w + 26.0, 9.0, 30.0), (0.0, yf - 4.0),
                 DOOR_SILL + DOOR_H + 24.0, "white_stone", bevel=BEV_MID)
    b.cylinder((0.0, yf - 9.0, DOOR_SILL + DOOR_H + 39.0), 8.0, 4.0, "bronze",
               segments=12, axis="Y")
    step_stone(b, w=door_w + 52.0, depth=32.0, h=12.0, x=0.0, y=yf - 22.0)
    # ---- 卫兵岗亭（门侧）+ 门侧箭窗 + 壁灯
    sentry_box(b, W * 0.22, yf - 44.0, 0.0)
    slit = win_rect("squint")
    for sx in (-1.0, 1.0):
        arrow_slit(b, sx * (door_w / 2.0 + 44.0), yf - 1.0, plinth_h + 58.0,
                   slit["ow"], slit["oh"])
    b.box_bottom((14.0, 10.0, 20.0), (-W * 0.14, yf - 6.0), plinth_h + 118.0,
                 "iron")
    b.box((10.0, 8.0, 14.0), (-W * 0.14, yf - 11.0, plinth_h + 112.0), "lamp")
    # ---- 铁栅窗（下层高窗 + 上层窗）
    for w in gwins + uwins:
        put_window(b, w, w["cx"], yf, frame_mat="iron")
    put_window(b, dict(high, cx=-D * 0.16), -D * 0.16, W / 2.0, axis="Y",
               face_dir=1.0, frame_mat="iron")
    # ---- 屋顶（板岩，肃穆）+ 铸币烟囱（铁箍两道 + 冲出屋脊）
    roof_gable(b, W, D, rise, over, "slate", z=eave, thickness=15.0,
               mat_under="wood_dark", cap_size=(30.0, 15.0), cap_mat="stone_dark",
               board_mat="wood_dark", board_h=9.0, ao_mat="shadow_mid")
    gable_w = win_rect(WIN_GABLE, bay_w=D * 0.5, floor_z=eave)
    gable_w["u"] = -D * 0.13
    gable_infill(b, W, D, rise, "brick", z=eave, thickness=15.0,
                 hole=(gable_w["u"], gable_w["ow"], gable_w["z0"], gable_w["z1"]))
    for sx in (-1.0, 1.0):
        put_window(b, gable_w, gable_w["u"], sx * (W / 2.0), axis="Y",
                   face_dir=sx, frame_mat="iron")
    ch_x = -W * 0.18
    ch_y = -D * 0.16
    ch_top = eave + rise + ch_up
    ch_roof = gable_roof_z(eave, rise, D / 2.0 + over, ch_y)
    chimney(b, ch_w, 40.0, ch_top, "brick", ch_x, ch_y, foot=0.0,
            cap_mat="white_stone", cap=14.0, roof=ch_roof, skirt_h=24.0,
            skirt_lip=10.0, flue=(width_cells >= 16))
    for zz in (eave + 24.0, eave + rise + 12.0):  # 铁箍两道
        b.box_bottom((ch_w + 8.0, 46.0, 7.0), (ch_x, ch_y), zz, "iron")

    ob = b.to_object()
    spec = _mk("mint", width_cells, {
        "depth": D, "plinth_h": plinth_h, "wall_h": sh * 2.0, "eave_h": eave,
        "rise": rise, "total_h": ch_top + 14.0, "overhang": over, "roof_t": 15.0,
        "storey_h": [sh, sh], "double_storey": True,
        "door": (door_w, DOOR_H), "door_x": 0.0, "floor_h": sh,
        "window": (high["ow"], high["oh"], high["z0"] - plinth_h),
        "gable_window": (gable_w["ow"], gable_w["oh"], gable_w["u"], gable_w["z0"]),
        "chimneys": [{"x": ch_x, "y": ch_y, "roof": ch_roof, "top": ch_top + 14.0,
                      "foot": 0.0, "w": ch_w, "d": 40.0}],
        "civic": ["iron_gate", "barred_windows", "mint_chimney", "sentry_box",
                  "arrow_slits"],
        "material": "砖砌 + 白石隅石 / 板岩 + 铁栅重门 + 铸币烟囱 + 卫兵位"})
    return ob, spec


ASSEMBLERS["council_hall"] = assemble_council_hall
ASSEMBLERS["town_hall"] = assemble_town_hall
ASSEMBLERS["governor_palace"] = assemble_governor_palace
ASSEMBLERS["imperial_palace"] = assemble_imperial_palace
ASSEMBLERS["belfry"] = assemble_belfry
ASSEMBLERS["mint"] = assemble_mint

#: 行政/地标轮探针条目（追加在既有条目之后，不动既有 —— 既有判定必须不变）
PROBE_LIST += [("council_hall", 8),
               ("town_hall", 12), ("town_hall", 16),
               ("governor_palace", 16),
               ("imperial_palace", 16),
               ("belfry", 4), ("belfry", 6),
               ("mint", 12), ("mint", 16)]


# ================================================================ §10 分级批次 2：驿站/赌场/科研/花店
#
# 依据《聚落等级与建筑分级.md》§3.1/§3.3 级别窗口 + §7.1 P1 清单，补 8 个装配器：
#   驿站族（全级 5 族之一）：waystation（Lv1 路驿）/ inn_post（Lv2 客栈驿站）/ coach_house（Lv3 车马行）
#   赌场族（2 级）：gambling_den（Lv1 赌坊）/ grand_casino（Lv2 大赌场）
#   科研族（全级）：academy（Lv3 学院）/ observatory（观星台圆顶塔）——library 保持 Lv2
#   花店：flower_shop（文档原口径=shop 载体 DRESS 不新建；本批按任务指令落独立件，窗口标提案/待定）
# 纪律同前批：只新增函数/常量/参数表；既有装配器、WINDOW_SPEC 既有条目、既有 PROBE_LIST
# 条目一律不动；窗走 §0.5 窗表（禁写死 ow/oh/窗台），屋顶走 roof_gable/cone_roof/dome_cap，
# 烟囱走 chimney（落地 + 泛水裙）；识别件（红灯笼/骰子招牌/彩旗串/花器/备轮）为"建筑自带"
# （同 hang_sign_iron 的自带理由：道具层概率挂载保不住识别符号）；花丛/桶栽全部 _jit 确定性。

#: 本批新增件的花色调（染布三色同 props 花坛口径；花头在游戏尺寸下读"一团饱和色"）
_FLOWER_PAL = ("cloth_red", "cloth_ochre", "cloth_blue")


def red_lantern(b, x, y, z, s=13.0):
    """挂式红灯笼：吊带 + 深红鼓身（cloth_red）+ 透光环带（lamp 自发光）+ 流苏。

    驿站/赌坊的识别件（白天靠红读，夜档靠 lamp 环带透光）——为什么自带同 hang_sign_iron。
    `z` = 吊挂点（灯笼从 z 向下挂）。
    """
    b.box((3.0, 3.0, s * 0.8), (x, y, z + s * 0.4), "iron")
    b.cylinder((x, y, z), s * 1.08, s * 0.42, "iron", segments=10)
    b.cylinder((x, y, z - s * 0.85), s, s * 1.30, "cloth_red", segments=12)
    for k in (-0.42, 0.0, 0.42):                    # 三道透光环带
        b.cylinder((x, y, z - s * 0.85 + k * s), s * 1.03, s * 0.16, "lamp", segments=12)
    b.cylinder((x, y, z - s * 1.71), s * 1.08, s * 0.42, "iron", segments=10)
    b.box((2.6, 2.6, s * 0.7), (x, y, z - s * 2.12), "cloth_red")


def wall_lantern_iron(b, x, y_wall, z, s=13.0):
    """壁挂红灯笼：铁座 + 外挑斜臂 + 红灯笼（驿站/赌坊/赌场门侧识别件）。`z` = 铁座底。"""
    b.box_bottom((12.0, 8.0, 16.0), (x, y_wall - 4.0), z, "iron", bevel=BEV_SMALL)
    strut(b, (x, y_wall - 6.0, z + 12.0), (x, y_wall - s * 1.5, z + s * 1.15), 5.0, "iron")
    red_lantern(b, x, y_wall - s * 1.5, z + s * 1.05, s=s)


def spare_wheel(b, x, y, z_c, r=34.0, width=13.0, spokes=6, mat="wood_dark"):
    """备用车轮（备轮架用）：轮面朝观众（XZ 平面，同 water_wheel 约定）——双层轮圈 +
    辐条 + 铁轴毂。轮只有"朝观众"才读得出是轮（2D 侧视纪律）。z_c = 轮心高。"""
    segs = 14
    for sy in (-1.0, 1.0):
        yy = y + sy * width * 0.30
        for k in range(segs):
            a = 2.0 * math.pi * (k + 0.5) / segs
            ca, sa = math.cos(a), math.sin(a)
            axes = (Vector((ca, 0.0, sa)), _Y_AXIS, Vector((-sa, 0.0, ca)))
            b.box_oriented((x + ca * r, yy, z_c + sa * r), axes,
                           (6.5, width * 0.22, math.pi * r / segs * 1.18), mat)
    for k in range(spokes):
        a = 2.0 * math.pi * k / spokes
        strut(b, (x, y, z_c), (x + math.cos(a) * r * 0.96, y,
                               z_c + math.sin(a) * r * 0.96), 7.0, mat)
    b.cylinder((x, y, z_c), r * 0.16, width * 1.7, "iron", segments=12, axis="Y")


def flower_clump(b, x, y, z, s=9.0, seed=0, palette=None, n=5):
    """一丛花（自带版）：茎叶 + 花头三色；_jit 确定性，跨进程逐位一致。"""
    pal = palette or _FLOWER_PAL
    for i in range(max(1, int(n))):
        j0 = _jit(i * 2 + 1, 811 + seed)
        j1 = _jit(i * 3 + 2, 823 + seed)
        j2 = _jit(i * 5 + 3, 839 + seed)
        sx, sy = x + j0 * s * 1.6, y + j1 * s * 1.1
        ln = s * (2.1 + 1.2 * abs(j2))
        b.box((2.4, 2.4, ln), (sx, sy, z + ln * 0.5), "foliage",
              rot=(0.26 * j1, 0.26 * j0, 0.0))
        b.box((s * 1.5, s * 1.5, s * 1.1), (sx, sy, z + ln + s * 0.30),
              pal[i % len(pal)], rot=(0.4 * j0, 0.4 * j1, 3.0 * abs(j2)))


def flower_tub(b, x, y, z, r=12.0, h=24.0, seed=0):
    """桶栽：直筒厚唇木桶 + 土面 + 花丛（直筒不收分——圆锥花盆会读成"小帐篷"，踩过的坑）。"""
    b.cylinder((x, y, z + h * 0.5), r, h, "wood_light", segments=12)
    b.cylinder((x, y, z + h + 2.0), r * 1.10, 4.0, "wood_dark", segments=12,
               bevel=BEV_SMALL)
    b.cylinder((x, y, z + h * 0.78), r * 0.92, 3.0, "cavity", segments=12)
    flower_clump(b, x, y, z + h - 2.0, s=r * 0.52, seed=seed, n=5)


def window_flower_box(b, x, y_wall, z, w=78.0, seed=0):
    """窗台花箱：木箱 + 沿口 + 土面 + 花带 + 铁托架（花店识别件）。y_wall = 墙面外皮。"""
    d, h = 17.0, 15.0
    yc = y_wall - d * 0.62
    b.box_bottom((w, d, h), (x, yc), z, "wood", bevel=BEV_SMALL)
    b.box_bottom((w + 5.0, d + 4.0, 3.5), (x, yc), z + h, "wood_dark")
    for sx in (-1.0, 1.0):
        strut(b, (x + sx * w * 0.34, y_wall - 2.0, z + 2.0),
              (x + sx * w * 0.34, y_wall - d, z + h * 0.5), 3.5, "iron")
    b.box_bottom((w - 8.0, d - 6.0, 2.5), (x, yc), z + h - 1.0, "cavity")
    n = max(3, int(w / 24.0))
    for i in range(n):
        px = x - w * 0.5 + w * (i + 0.5) / n
        flower_clump(b, px, yc, z + h - 2.0, s=6.5, seed=seed * 7 + i, n=3)


def flower_basket_hang(b, x, y, z, r=13.0, seed=0):
    """悬篮：吊环 + 三链 + 柳条篮 + 溢出花球 + 垂蔓（花店雨篷下识别件）。z = 吊点。"""
    b.cylinder((x, y, z), r * 0.10, r * 0.35, "iron", segments=8)
    bz = z - r * 1.15
    for k in range(3):
        a = 2.0 * math.pi * k / 3.0 + 0.5
        strut(b, (x, y, z - r * 0.18),
              (x + math.cos(a) * r * 0.9, y + math.sin(a) * r * 0.9, bz + r * 0.5),
              1.8, "iron")
    b.cylinder((x, y, bz), r, r * 0.62, "wicker", segments=12)
    b.cylinder((x, y, bz + r * 0.28), r * 0.78, 2.5, "cavity", segments=12)
    flower_clump(b, x, y, bz + r * 0.30, s=r * 0.30, seed=seed,
                 palette=("cloth_red", "cloth_ochre"), n=6)
    for k in range(2):                              # 垂蔓
        a = math.pi * (0.6 + 1.2 * k)
        b.box((3.0, 3.0, r * 0.9), (x + math.cos(a) * r * 0.95,
                                    y + math.sin(a) * r * 0.95, bz - r * 0.20),
              "foliage", rot=(math.radians(18.0), 0.0, a))


def pennant_line(b, x0, x1, y, z, n=9, sag=16.0, seed=0):
    """彩旗串（大赌场识别件）：两点悬链（抛物近似）+ 交替三色小旗（旗身收窄读三角）。"""
    n = max(2, int(n))
    px0, pz0 = x0, z
    for i in range(n + 1):
        t = i / float(n)
        px = x0 + (x1 - x0) * t
        pz = z - sag * (4.0 * t * (1.0 - t))
        if i:
            strut(b, (px0, y, pz0), (px, y, pz), 1.8, "iron")
        if i < n:
            j = _jit(i, 853 + seed)
            pmx = (px0 + px) * 0.5
            pmz = (pz0 + pz) * 0.5 - 2.0
            fw = 15.0 + 3.0 * abs(j)
            fh = 21.0
            col = _FLOWER_PAL[i % 3]
            b.box((fw, 2.2, fh * 0.62), (pmx, y - 1.2, pmz - fh * 0.31), col)
            b.box((fw * 0.55, 2.2, fh * 0.38), (pmx, y - 1.2, pmz - fh * 0.80), col)
        px0, pz0 = px, pz


def dice_sign(b, x, y_wall, z_top):
    """骰子招牌（赌坊识别件）：铁挑臂 + 双斜撑 + 挂牌 + 两粒斜叠骰（白石体 + 铁点面）。"""
    yb = y_wall - 46.0
    b.box_bottom((10.0, 7.0, 52.0), (x, y_wall - 3.0), z_top - 46.0, "iron")
    strut(b, (x, y_wall - 4.0, z_top + 12.0), (x, y_wall - 50.0, z_top + 4.0), 5.0, "iron")
    strut(b, (x, y_wall - 4.0, z_top - 40.0), (x, y_wall - 32.0, z_top - 12.0), 4.0, "iron")
    b.box((46.0, 5.0, 34.0), (x, yb, z_top - 18.0), "wood_dark", bevel=BEV_MID)
    for (dx, dz, s, seed) in ((-10.0, 3.0, 15.0, 0), (9.0, -4.0, 11.0, 3)):
        b.box((s, s, s), (x + dx, yb - 5.0, z_top - 18.0 + dz), "white_stone",
              rot=(0.3, 0.5, 0.2 + 0.1 * seed), bevel=BEV_SMALL)
        for k in range(3):                          # 点数面（贴牌一侧的三点）
            b.box((2.6, 1.5, 2.6), (x + dx - s * 0.22 + s * 0.22 * k, yb - 8.0,
                                    z_top - 18.0 + dz + s * 0.18), "iron")


# ---------------------------------------------------------------- 10.1 路驿 waystation

WAYSTATION_TIERS = {
    # 路驿/驿亭（驿站族 Lv1，hamlet/village 投放）：敞棚 + 马桩 + 草料 + 驿牌；无门（开敞）。
    # 6 格档同 smithy1 w6 先例（棚类无门，不占住宅 4 格倍数宽度档；8 格为常规档）。
    6: dict(D=148.0, post_h=172.0, rise=64.0, post=15.0, roof_t=16.0, sign_h=184.0),
    8: dict(D=176.0, post_h=200.0, rise=78.0, post=16.0, roof_t=18.0, sign_h=214.0),
}


def assemble_waystation(width_cells=6):
    """路驿（驿站族 Lv1）：开敞车棚 + 拴马桩横杆 + 草料垛/料槽 + 驿牌立柱 + 歇脚长凳。

    与 shelter（柱撑草棚）的可辨差异（≥2 项）：
    ① 背墙**整面封板**（shelter 只封下半）——读"半户外的驿亭"，不是"堆料棚"；
    ② 附属件群：驿牌立柱（双臂牌 + 披檐帽）+ 拴马横杆 + 草料槽 + 长凳 —— shelter 是货箱桶堆；
    ③ 无门无墙三面开敞这点同 shelter，但草料垛+马桩的前场是"驿站功能位"。
    """
    t = WAYSTATION_TIERS[width_cells]
    W = width_cells * CELL
    D, post_h, rise, post_s = t["D"], t["post_h"], t["rise"], t["post"]
    roof_t, sign_h = t["roof_t"], t["sign_h"]
    over = eave_over(W)
    yf = -D / 2.0 + post_s / 2.0
    yb = D / 2.0 - post_s / 2.0

    b = Builder("waystation_w%d" % width_cells)
    contact_shadow(b, W, D * 1.16, spread=28.0)
    for sx in (-1.0, 1.0):
        for yy in (yb, yf):
            post(b, post_s, post_h, "wood_dark", sx * (W / 2.0 - post_s / 2.0), yy)
    if width_cells >= 8:                            # 前中柱（大档车棚跨度大）
        for px in (-W / 4.0, W / 4.0):
            post(b, post_s, post_h, "wood_dark", px, yf)
    for yy in (yf, yb):
        beam(b, W, 16.0, 15.0, "wood_dark", 0.0, yy, post_h - 15.0)
    for sx in (-1.0, 1.0):
        beam(b, D - post_s, 15.0, 15.0, "wood_dark", sx * (W / 2.0 - post_s / 2.0), 0.0,
             post_h - 15.0, axis="Y")
        strut(b, (sx * (W / 2.0 - post_s - 2.0), yf, post_h - 40.0),
              (sx * (W / 2.0 - 76.0), yf, post_h - 4.0), 10.0, "wood_dark")
    # ---- 背墙整面封板（与 shelter"只封下半"分家）+ 封板竖筋
    wall_panel(b, W - 8.0, post_h, 12.0, "wood_light", 0.0, yb + 6.0, 0.0)
    for i in range(bays_of(width_cells) + 1):
        px = -W / 2.0 + 8.0 + (W - 16.0) * i / float(bays_of(width_cells))
        b.box_bottom((7.0, 4.0, post_h - 6.0), (px, yb + 11.0), 3.0, "wood_dark")
    # 开放棚的顶棚用亮望板（暗顶棚吞柱子——shelter 同款教训）
    roof_gable(b, W, D, rise, over, "thatch", z=post_h, thickness=roof_t,
               mat_under="wood_light", cap_size=(30.0, 15.0), cap_mat="thatch",
               board_mat="wood_dark", board_h=8.0, eave_ao=False)
    # ---- 拴马桩横杆 + 草料槽（前场左侧，压低不读成围栏）
    for sx in (-1.0, 1.0):
        post(b, 12.0, 78.0, "wood_dark", -W * 0.30 + sx * W * 0.17, yf - 54.0)
    beam(b, W * 0.36, 10.0, 10.0, "wood_dark", -W * 0.30, yf - 54.0, 62.0)
    b.box_bottom((72.0, 24.0, 19.0), (-W * 0.30, yf - 26.0), 0.0, "wood_light")
    b.box_bottom((64.0, 16.0, 5.0), (-W * 0.30, yf - 26.0), 14.0, "straw")
    # ---- 棚内：草料垛（右后）+ 歇脚长凳 + 旅行行李（左前）
    hay_heap(b, W * 0.24, yb - D * 0.10, 0.0, w=W * 0.30, d=D * 0.28, h=40.0,
             rows=2, seed=width_cells + 5)
    bench(b, -W * 0.22, yb - D * 0.14, 0.0, w=72.0, d=30.0, h=46.0, mat="wood")
    barrel(b, x=-W * 0.34, y=yf + D * 0.10, z=0.0, r=12.0, h=34.0, lid=True)
    b.box_bottom((40.0, 30.0, 26.0), (-W * 0.14, yf + D * 0.12), 0.0, "wood_light")
    # ---- 驿牌立柱（双臂牌 + 披檐帽 + 告示）：站前场右前——**必须探出屋面檐口之外**
    # （旧版 pole 藏在檐下、只露出牌顶一个盒子，读不出"驿牌"——返工点）
    sgx = W * 0.5 - 18.0
    sgy = yf - (78.0 if width_cells >= 8 else 62.0)
    post(b, 11.0, sign_h, "wood_dark", sgx, sgy)
    b.box_bottom((46.0, 20.0, 8.0), (sgx, sgy - 3.0), sign_h, "wood_dark", bevel=BEV_MID)
    b.box_bottom((36.0, 5.0, 14.0), (sgx - 24.0, sgy - 2.0), sign_h - 26.0, "wood_light")
    b.box((26.0, 2.0, 9.0), (sgx - 24.0, sgy - 5.0, sign_h - 26.0), "canvas")
    b.box_bottom((28.0, 5.0, 12.0), (sgx + 22.0, sgy - 2.0), sign_h - 48.0, "wood_light")
    b.box((20.0, 2.0, 8.0), (sgx + 22.0, sgy - 5.0, sign_h - 48.0), "canvas")

    ob = b.to_object()
    spec = _mk("waystation", width_cells, {
        "depth": D, "plinth_h": 0.0, "wall_h": post_h, "eave_h": post_h,
        "rise": rise, "total_h": post_h + rise, "overhang": over, "roof_t": roof_t,
        "storey_h": [post_h], "door": None, "open_shed": True,
        "post_rail": True, "hay": True, "way_sign_h": sign_h,
        "material": "木柱 / 茅草顶 + 背墙封板 + 拴马桩 + 草料 + 驿牌"})
    return ob, spec


# ---------------------------------------------------------------- 10.2 客栈驿站 inn_post

INN_POST_TIERS = {
    # 客栈驿站（驿站族 Lv2，town 起；townlet 过渡提前解锁见布局器）：两层主楼 +
    # 大院拱门（真洞双扇）+ 前凸马厩翼（开敞厩位）+ 驿号旗 + 红灯笼对 + 铁艺挂招牌。
    12: dict(D=204.0, plinth=18.0, storey=229, rise=104.0, wt=20.0, door_w=56.0,
             jetty=10.0, wing_w=120.0, wing_fwd=64.0, wing_h=150.0, wing_rise=44.0,
             gate_w=104.0, gate_head=36.0, flag_h=252.0),
    16: dict(D=232.0, plinth=20.0, storey=229, rise=118.0, wt=22.0, door_w=58.0,
             jetty=12.0, wing_w=138.0, wing_fwd=72.0, wing_h=156.0, wing_rise=48.0,
             gate_w=112.0, gate_head=40.0, flag_h=264.0),
}


def assemble_inn_post(width_cells=12):
    """客栈驿站（驿站族 Lv2）：两层主楼（石砌公共层 + 抹灰木骨上层前挑）+ 大院拱门 +
    前凸马厩翼 + 驿号旗 + 红灯笼对 + 老虎窗。

    与 tavern 的可辨差异（≥2 项）：
    ① **大院拱门**（通院内院子的真洞双扇拱门 + 拱券石圈）—— 酒馆没有院门；
    ② **前凸马厩翼**（开敞厩位 + 草料 + 料槽，自带小坡顶）—— 换马驿站的职能读法；
    ③ 驿号旗（banner 旗杆）+ 红灯笼对 —— 酒馆是铁艺招牌（两家都有招牌但旗+灯是驿站组）。
    """
    t = INN_POST_TIERS[width_cells]
    W = width_cells * CELL
    D, plinth_h, sh = t["D"], t["plinth"], t["storey"]
    rise, wt, door_w, jetty = t["rise"], t["wt"], t["door_w"], t["jetty"]
    wing_w, wing_fwd, wing_h, wing_rise = (t["wing_w"], t["wing_fwd"], t["wing_h"],
                                           t["wing_rise"])
    gate_w, gate_head, flag_h = t["gate_w"], t["gate_head"], t["flag_h"]
    over = eave_over(W)
    eave = plinth_h + sh * 2.0
    z2 = plinth_h + sh
    yf0 = -D / 2.0
    yf1 = yf0 - jetty
    yb = D / 2.0
    yc2 = (yf1 + yb) / 2.0
    bays = bays_of(width_cells)
    cs = bay_centers(W, bays)
    bw = W / float(bays)
    # ---- 一层开洞：门（中右）+ 院门（右，真洞到顶）；石壁层不再排窗
    # （12/16 格一层被门/院门/灯笼占满，且烟囱要走前坡开间缝——窗留给二层）
    dx = W * 0.10
    gx = W * 0.34
    gate_h = DOOR_SILL + DOOR_H + gate_head
    # ---- 二层窗（前挑墙上）
    _d2, wins2 = bay_openings(W, bays, WIN_UP, floor_z=z2)
    wins2[0]["shutters"] = True
    wins2[-1]["shutters"] = True

    b = Builder("inn_post_w%d" % width_cells)
    contact_shadow(b, W, D + jetty + wing_fwd, spread=34.0)
    # 勒脚缺口给院门（宽），人员门用踏步补台（warehouse 同款手法）
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(gx - gate_w / 2.0 - 8.0, gx + gate_w / 2.0 + 8.0), lip=10.0)
    # ---- 一层：石砌公共层（门 + 窗 + 院门真洞）
    room_shell(b, W, D, plinth_h, sh, wt, "stone",
               front_openings=[(dx, door_w, DOOR_SILL, DOOR_SILL + DOOR_H),
                               (gx, gate_w, DOOR_SILL, gate_h)])
    quoins(b, W - 2.0 * wt, D, sh * 0.96, "white_stone", 0.0, yf0 + wt / 2.0,
           plinth_h + 4.0, size=22.0, step=44.0, front=False, sides=True)
    door(b, h=DOOR_H, w=door_w, mat="wood_door", x=dx, y=yf0, z=DOOR_SILL,
         frame_mat="timber", planks=4)
    step_stone(b, w=door_w + 34.0, depth=26.0, h=plinth_h, x=dx, y=yf0 - 18.0)
    # 院门：拱券石圈 + 暗腔 + 双扇门 + 中梃（真洞已在前墙开出）
    b.box((gate_w - 6.0, 26.0, gate_h - DOOR_SILL), (gx, yf0 + 26.0,
                                                     DOOR_SILL + (gate_h - DOOR_SILL) / 2.0),
          "cavity")
    leaf_w = gate_w * 0.5 - 7.0
    for sx in (-1.0, 1.0):
        door(b, h=DOOR_H, w=leaf_w, mat="wood_door", x=gx + sx * (leaf_w / 2.0 + 2.0),
             y=yf0 + 2.0, z=DOOR_SILL, frame_mat="iron", frame=8.0, planks=4, iron=True)
    b.box_bottom((9.0, 12.0, gate_h - DOOR_SILL), (gx, yf0 - 2.0), DOOR_SILL, "timber")
    ring_stone(b, gx, yf0 - 1.0, DOOR_SILL + DOOR_H, gate_w / 2.0 + 5.0, "white_stone",
               blocks=9, depth=wt * 0.6, thick=15.0, a0=0.0, a1=math.pi)
    # ---- 二层：抹灰 + 木骨（前挑 jetty）
    wall_panel(b, W, sh, D + jetty, "plaster", 0.0, yc2, z2,
               openings=win_holes(wins2))
    for i in range(5):
        px = -W / 2.0 + 14.0 + (W - 28.0) * i / 4.0
        b.box_bottom((14.0, 18.0, 14.0), (px, yf1 + 9.0), z2 - 14.0, "timber")
    b.box_bottom((W + 6.0, 9.0, 16.0), (0.0, yf1), z2 - 16.0, "timber")
    timber_frame(b, W, sh, "timber", (0.0, yf1), z2, depth=7.0, post=14.0,
                 top_band=14.0, bays=bays, braces=True,
                 openings=[(w["cx"], w["ow"]) for w in wins2])
    for w in wins2:
        put_window(b, w, w["cx"], yf1)
    # ---- 屋顶 + 前坡老虎窗（客房层）
    roof_gable(b, W, D + jetty, rise, over, "tile", z=eave, thickness=15.0,
               mat_under="wood_dark", cap_size=(30.0, 16.0), board_h=9.0,
               ao_faces=(yf1, yb), y=yc2)
    half = (D + jetty) / 2.0 + over
    yd = yc2 - (D + jetty) * 0.30 - over * 0.30
    roof_dormer(b, W * 0.24, yd, gable_roof_z(eave, rise, half, yd, y_ridge=yc2),
                w=max(62.0, W * 0.17), h=58.0, depth=46.0, rise=22.0, mat="tile",
                wall_mat="plaster", embed=30.0)
    gable_w = win_rect(WIN_GABLE, bay_w=(D + jetty) * 0.5, floor_z=eave)
    gable_w["u"] = -D * 0.14
    gable_infill(b, W, D + jetty, rise, "plaster", z=eave, thickness=14.0, y=yc2,
                 hole=(gable_w["u"], gable_w["ow"], gable_w["z0"], gable_w["z1"]))
    for sx in (-1.0, 1.0):
        gable_timber(b, D + jetty, rise, "timber", (sx * (W / 2.0), yc2), eave,
                     axis="Y", face_dir=sx, thick=11.0)
        put_window(b, gable_w, gable_w["u"], sx * (W / 2.0), axis="Y", face_dir=sx)
    # ---- 前凸马厩翼（左前）：开敞厩位 + 草料 + 料槽 + 自带小坡顶
    wxc = -W / 2.0 + wing_w / 2.0
    wyf = yf0 - wing_fwd
    wyc = (wyf + yf0) / 2.0
    for px in (wxc - wing_w / 2.0 + 8.0, wxc, wxc + wing_w / 2.0 - 8.0):
        post(b, 14.0, wing_h, "wood_dark", px, wyf + 7.0)
    wall_panel(b, wing_w, wing_h, 12.0, "wood_light", wxc - wing_w / 2.0 + 6.0,
               (wyf + yf0) / 2.0 + 6.0, 0.0, axis="Y")
    wall_panel(b, wing_w, wing_h * 0.46, 12.0, "wood_light", wxc + wing_w / 2.0 - 6.0,
               (wyf + yf0) / 2.0, 0.0, axis="Y")
    b.box_bottom((wing_w - 16.0, 10.0, 12.0), (wxc, wyf + 10.0), wing_h - 12.0,
                 "wood_dark")
    roof_gable(b, wing_w + 22.0, wing_fwd + wt + 16.0, wing_rise, 14.0, "thatch",
               x=wxc, y=wyc + 8.0, z=wing_h, thickness=13.0, mat_under="wood_light",
               cap_size=(26.0, 13.0), cap_mat="thatch", board_h=8.0, eave_ao=False)
    hay_heap(b, wxc + wing_w * 0.22, wyf + wing_fwd * 0.42, 0.0,
             w=wing_w * 0.42, d=wing_fwd * 0.5, h=34.0, rows=1, seed=width_cells)
    b.box_bottom((66.0, 22.0, 18.0), (wxc - wing_w * 0.24, wyf + 26.0), 0.0,
                 "wood_light")
    b.box_bottom((58.0, 14.0, 5.0), (wxc - wing_w * 0.24, wyf + 26.0), 13.0, "straw")
    # ---- 驿号旗（banner 旗杆，院门侧）+ 红灯笼对（人员门侧）+ 铁艺挂招牌（二层）
    flag_pole(b, gx + gate_w * 0.5 + 30.0, yf0 - 16.0, 0.0, h=flag_h,
              cloth="cloth_blue", flag_w=54.0, flag_h=82.0, style="banner")
    for sx in (-1.0, 1.0):
        wall_lantern_iron(b, dx + sx * (door_w / 2.0 + 26.0), yf0 - 1.0,
                          DOOR_SILL + DOOR_H + 22.0, s=13.0)
    sg_x = cs[1] + bw / 2.0
    hang_sign_iron(b, sg_x, yf1, z2 + sh * 0.82, w=54.0, h=40.0)
    # ---- 烟囱（客房有壁炉）：贴前坡**开间缝**（-W/6，躲开二层窗与门）穿屋面 + 泛水裙
    ch_x = -W / 6.0
    ch_y = yf1 - 13.0
    ch_top = eave + rise - 16.0
    ch_roof = gable_roof_z(eave, rise, half, ch_y, y_ridge=yc2)
    chimney(b, 30.0, 26.0, ch_top, "brick", ch_x, ch_y, foot=0.0,
            cap_mat="stone_dark", cap=12.0, roof=ch_roof)

    ob = b.to_object()
    spec = _mk("inn_post", width_cells, {
        "depth": D + jetty, "plinth_h": plinth_h, "wall_h": sh * 2.0, "eave_h": eave,
        "rise": rise, "total_h": eave + rise, "overhang": over, "roof_t": 15.0,
        "storey_h": [sh, sh], "double_storey": True, "door": (door_w, DOOR_H),
        "door_x": dx, "jetty": jetty, "bays": bays, "dormers": 1,
        "courtyard_gate": (gate_w, gate_h - DOOR_SILL), "gate_x": gx,
        "stable_wing": (wing_w, wing_fwd, wing_h), "flag_h": flag_h, "lanterns": 2,
        "window": (wins2[0]["ow"], wins2[0]["oh"], wins2[0]["z0"] - z2),
        "window_up": (wins2[0]["ow"], wins2[0]["oh"], wins2[0]["z0"] - z2),
        "gable_window": (gable_w["ow"], gable_w["oh"], gable_w["u"], gable_w["z0"]),
        "chimneys": [{"x": ch_x, "y": ch_y, "roof": ch_roof, "top": ch_top + 12.0,
                      "foot": 0.0, "w": 30.0, "d": 26.0}],
        "sign_x": sg_x, "material": "石砌 + 抹灰木骨 / 陶瓦 + 大院拱门 + 马厩翼 + 驿号旗 + 红灯笼"})
    return ob, spec


# ---------------------------------------------------------------- 10.3 车马行 coach_house

COACH_HOUSE_TIERS = {
    # 车马行（驿站族 Lv3，city 级投放）：大跨车库（近满高车门）+ 马车台 + 备轮架 + 宿舍翼。
    12: dict(D=198.0, plinth=18.0, wall=288.0, rise=108.0, wt=20.0, door_w=54.0,
             coach_w=124.0, wing_w=126.0, wing_fwd=58.0, wing_h=196.0, wing_rise=64.0),
    16: dict(D=226.0, plinth=20.0, wall=300.0, rise=118.0, wt=22.0, door_w=56.0,
             coach_w=136.0, wing_w=140.0, wing_fwd=64.0, wing_h=202.0, wing_rise=70.0),
}


def assemble_coach_house(width_cells=12):
    """车马行（驿站族 Lv3）：砖砌大跨车库 + 近满高大车门（半开滑门）+ 马车台 + 备轮架 +
    前凸宿舍翼（车夫宿）。

    与 warehouse 的可辨差异（≥2 项）：
    ① **近满高大车门**居中（车行正立面主 reader）+ 高侧采光带 —— warehouse 货门偏置且滑轨外露；
    ② **马车台 + 备轮架**（两只朝观众备用轮）—— 运输行当的前场读法，仓库是吊臂货台；
    ③ **宿舍翼**（前凸小坡顶 + 阁楼窗）—— 车行有人住，仓库无人。
    """
    t = COACH_HOUSE_TIERS[width_cells]
    W = width_cells * CELL
    D, plinth_h, wall_h, rise = t["D"], t["plinth"], t["wall"], t["rise"]
    wt, door_w, coach_w = t["wt"], t["door_w"], t["coach_w"]
    wing_w, wing_fwd, wing_h, wing_rise = (t["wing_w"], t["wing_fwd"], t["wing_h"],
                                           t["wing_rise"])
    over = eave_over(W)
    eave = plinth_h + wall_h
    yf, yb = -D / 2.0, D / 2.0
    ccx = W * 0.16                       # 大车门中心（中右）
    coach_z1 = eave - 26.0               # 车门近满高
    dx = -W * 0.30                       # 人员门
    clere = win_rect("garret", over=dict(w=30.0, h=36.0))
    clere_z = eave - 64.0                # 高侧采光带（山墙端，躲开车门与人员门）
    clere_x = (W * 0.44,)          # 左端被宿舍翼挡住，高侧窗只留右端
    lw = win_rect(WIN_LOW, bay_w=W * 0.22, floor_z=plinth_h, w_scale=0.94)
    lw["cx"] = -W * 0.08

    b = Builder("coach_house_w%d" % width_cells)
    contact_shadow(b, W, D + wing_fwd + 62.0, spread=36.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(ccx - coach_w / 2.0 - 8.0, ccx + coach_w / 2.0 + 8.0), lip=12.0)
    # ---- 主厅：砖墙 + 人员门 + 临街窗 + 高侧采光带 + 近满高车门真洞
    room_shell(b, W, D, plinth_h, wall_h, wt, "brick",
               front_openings=[(dx, door_w, DOOR_SILL, DOOR_SILL + DOOR_H),
                               (lw["cx"], lw["ow"], lw["z0"], lw["z1"]),
                               (ccx, coach_w, plinth_h, coach_z1)]
                              + [(cx, clere["ow"], clere_z, clere_z + clere["oh"])
                                 for cx in clere_x])
    quoins(b, W - 2.0 * wt, D, wall_h * 0.94, "white_stone", 0.0, yf + wt / 2.0,
           plinth_h + 4.0, size=22.0, step=50.0, front=False, sides=True)
    door(b, h=DOOR_H, w=door_w, mat="wood_door", x=dx, y=yf, z=DOOR_SILL,
         frame_mat="iron", frame=9.0, planks=4)
    step_stone(b, w=door_w + 32.0, depth=26.0, h=plinth_h, x=dx, y=yf - 18.0)
    put_window(b, lw, lw["cx"], yf, frame_mat="iron")
    for cx in clere_x:
        cw = dict(clere, cx=cx)
        put_window(b, cw, cx, yf, frame_mat="iron")
    # ---- 大车门：石门框 + 洞内暗腔 + 半开亮板条滑门 + 铁滑轨（读"车能进"）
    ch_h = coach_z1 - plinth_h
    b.box((coach_w - 6.0, 26.0, ch_h), (ccx, yf + 50.0, plinth_h + ch_h / 2.0), "cavity")
    for sx in (-1.0, 1.0):
        b.box_bottom((16.0, 24.0, ch_h + 16.0), (ccx + sx * (coach_w / 2.0 + 8.0), yf),
                     plinth_h - 6.0, "white_stone", bevel=BEV_MID)
    b.box_bottom((coach_w + 54.0, 20.0, 20.0), (ccx, yf), coach_z1, "white_stone",
                 bevel=BEV_BIG)
    b.box((coach_w * 0.58, 8.0, ch_h * 0.96), (ccx - coach_w * 0.21, yf - 7.0,
                                               plinth_h + ch_h * 0.48), "wood_light")
    for k in range(4):
        b.box((7.0, 4.0, ch_h * 0.96), (ccx - coach_w * 0.21 - coach_w * 0.20
                                        + coach_w * 0.40 * k / 3.0, yf - 12.0,
                                        plinth_h + ch_h * 0.48), "wood_dark")
    b.box_bottom((coach_w * 1.6, 11.0, 11.0), (ccx, yf - 9.0), coach_z1 + 8.0, "iron")
    for k in range(4):
        b.box_bottom((5.0, 5.0, 10.0), (ccx - coach_w * 0.5 + coach_w * k / 3.0,
                                        yf - 15.0), coach_z1, "iron")
    # ---- 马车台（石台 + 系缆桩两枚 + 车辕托架）+ 备轮架（两只朝观众备用轮）
    b.box_bottom((coach_w + 44.0, 44.0, 14.0), (ccx, yf - 40.0), 0.0, "stone_dark",
                 bevel=BEV_BIG)
    for sx in (-1.0, 1.0):
        b.cylinder((ccx + sx * coach_w * 0.36, yf - 56.0, 21.0), 6.0, 14.0, "iron",
                   segments=10)
    for sx in (-1.0, 1.0):
        strut(b, (ccx + sx * 26.0, yf - 40.0, 14.0),
              (ccx + sx * 40.0, yf - 58.0, 14.0), 7.0, "wood_dark")
    rk_x = W * 0.40
    for sy in (-1.0, 1.0):
        post(b, 11.0, 58.0, "wood_dark", rk_x + sy * 46.0, yf - 30.0)
    beam(b, 100.0, 9.0, 9.0, "wood_dark", rk_x, yf - 30.0, 52.0)
    spare_wheel(b, rk_x - 24.0, yf - 30.0, 33.0, r=34.0)
    spare_wheel(b, rk_x + 26.0, yf - 26.0, 27.0, r=27.0, width=11.0)
    # ---- 前凸宿舍翼（左前）：石基 + 抹灰 + 真洞小窗（木框）+ 自带小坡顶
    wxc = -W / 2.0 + wing_w / 2.0
    wyf = yf - wing_fwd
    wyc = (wyf + yf) / 2.0
    dw = win_rect(WIN_UP, bay_w=wing_w * 0.5, floor_z=24.0, w_scale=0.88,
                  shutters=True)
    dorm_wins = []
    for sxx in (-1.0, 1.0):
        dorm_wins.append(dict(dw, cx=wxc + sxx * wing_w * 0.30))
    room_shell(b, wing_w, wing_fwd + wt, 0.0, wing_h, 14.0, "plaster",
               front_openings=[(wxc, 46.0, DOOR_SILL, DOOR_SILL + DOOR_H)]
                              + win_holes(dorm_wins))
    for dwx in dorm_wins:
        put_window(b, dwx, dwx["cx"], wyf, frame_mat="timber")
    gw2 = win_rect(WIN_GABLE, bay_w=wing_fwd * 0.5, floor_z=wing_h)
    gw2["u"] = -wing_fwd * 0.10
    b.box_bottom((wing_w + 14.0, (wing_fwd + wt) * 0.5 + 4.0, 10.0), (wxc, wyc),
                 wing_h - 10.0, "wood_dark")
    roof_gable(b, wing_w + 18.0, wing_fwd + wt + 14.0, wing_rise, 13.0, "tile",
               x=wxc, y=wyc, z=wing_h, thickness=12.0, mat_under="wood_dark",
               cap_size=(24.0, 12.0), cap_mat="stone_dark", board_h=8.0)
    # ---- 主屋顶 + 山墙 + 大烟囱（宿舍有灶，烟囱压山墙端）
    roof_gable(b, W, D, rise, over, "tile", z=eave, thickness=16.0,
               mat_under="wood_dark", cap_size=(32.0, 16.0), cap_mat="stone_dark",
               board_h=10.0)
    gable_infill(b, W, D, rise, "brick", z=eave, thickness=16.0)
    ch_x = -W * 0.40
    ch_y = yf + 13.0
    ch_top = eave + rise - 18.0
    ch_roof = gable_roof_z(eave, rise, D / 2.0 + over, ch_y)
    chimney(b, 34.0, 34.0, ch_top, "brick", ch_x, ch_y, foot=0.0,
            cap_mat="white_stone", cap=13.0, roof=ch_roof, skirt_h=22.0, skirt_lip=9.0)

    ob = b.to_object()
    spec = _mk("coach_house", width_cells, {
        "depth": D + wing_fwd, "plinth_h": plinth_h, "wall_h": wall_h, "eave_h": eave,
        "rise": rise, "total_h": eave + rise, "overhang": over, "roof_t": 16.0,
        "storey_h": [wall_h], "door": (door_w, DOOR_H), "door_x": dx,
        "coach_door": (coach_w, ch_h, plinth_h, coach_z1), "coach_x": ccx,
        "dormer_wing": (wing_w, wing_fwd, wing_h), "spare_wheels": 2, "cart_pad": True,
        "window": (lw["ow"], lw["oh"], lw["z0"] - plinth_h),
        "chimneys": [{"x": ch_x, "y": ch_y, "roof": ch_roof, "top": ch_top + 13.0,
                      "foot": 0.0, "w": 34.0, "d": 34.0}],
        "material": "砖砌 + 白石隅石 / 陶瓦 + 近满高车门 + 马车台备轮架 + 宿舍翼"})
    return ob, spec


# ---------------------------------------------------------------- 10.4 赌坊 gambling_den

GAMBLING_TIERS = {
    # 赌坊（赌场族 Lv1，burgh 起投放——窗口放宽为提案/待定）：暗木板门面 + 小高窗铁栅 +
    # 半掩红帘 + 红灯笼对 + 骰子招牌 + 地窖口。后巷营生：不亮、不敞、透着钱。
    8:  dict(D=164.0, plinth=14.0, wall=202.0, rise=84.0, wt=18.0, door_w=50.0),
    12: dict(D=196.0, plinth=16.0, wall=206.0, rise=98.0, wt=20.0, door_w=52.0),
}


def assemble_gambling_den(width_cells=8):
    """赌坊（赌场族 Lv1）：通体暗木板 + 小高窗（铁栅 + 半掩红帘）+ 红灯笼对 + 骰子招牌 +
    地窖口 + 歪烟囱。

    与 tavern 的可辨差异（≥2 项）：
    ① 材质：**通体深木板**（timber 框 + 深板墙）—— 酒馆是石砌公共层 + 明抹灰上层；
    ② 开窗：**小而高 + 铁栅 + 半掩红帘**（暗，不想让人看进去）—— 酒馆是大玻璃公共窗；
    ③ 识别组：红灯笼对 + 骰子招牌 + 地窖口 —— 后巷赌窟的暗读法。
    """
    t = GAMBLING_TIERS[width_cells]
    W = width_cells * CELL
    D, plinth_h, wall_h, rise = t["D"], t["plinth"], t["wall"], t["rise"]
    wt, door_w = t["wt"], t["door_w"]
    over = eave_over(W)
    eave = plinth_h + wall_h
    yf, yb = -D / 2.0, D / 2.0
    bays = bays_of(width_cells)
    dx = -W * 0.08
    # 小高窗：vent 档抬高窗台（floor_z 抬高 = "小而高"，不新增窗型）
    hi_z = plinth_h + 92.0
    wins = []
    for cx in bay_centers(W, bays):
        if abs(cx - dx) < bw_pad_guard(W, bays):
            continue
        w = win_rect("vent", floor_z=hi_z, over=dict(bars=True))
        w["cx"] = cx
        wins.append(w)

    b = Builder("gambling_den_w%d" % width_cells)
    contact_shadow(b, W, D, spread=30.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(dx - door_w / 2.0 - 6.0, dx + door_w / 2.0 + 6.0), lip=9.0)
    # ---- 暗木板门面：深板墙 + 深木骨 + 斜撑（通体暗，同立面 1 档窗）
    room_shell(b, W, D, plinth_h, wall_h, wt, "wood_dark",
               front_openings=[(dx, door_w, DOOR_SILL, DOOR_SILL + DOOR_H)]
                              + win_holes(wins))
    timber_frame(b, W, wall_h, "timber", (0.0, yf), plinth_h, depth=7.0, post=13.0,
                 top_band=16.0, bays=bays, braces=True,
                 openings=[(dx, door_w)] + [(w["cx"], w["ow"]) for w in wins])
    door(b, h=DOOR_H, w=door_w, mat="wood_door", x=dx, y=yf, z=DOOR_SILL,
         frame_mat="timber", planks=3, iron=True)
    step_stone(b, w=door_w + 28.0, depth=24.0, h=9.0, x=dx, y=yf - 17.0)
    # ---- 小高窗 + 铁栅窗 + 半掩红帘（帘占窗上半，留下半缝——"半掩"读法）
    for w in wins:
        put_window(b, w, w["cx"], yf, frame_mat="iron")
        b.box((w["ow"] * 0.94, 3.5, w["oh"] * 0.52), (w["cx"], yf - 2.0,
                                                      w["z1"] - w["oh"] * 0.26),
              "cloth_red")
        b.box((w["ow"] * 0.30, 3.0, w["oh"] * 0.16), (w["cx"] + w["ow"] * 0.24,
                                                      yf - 3.5, w["z1"] - w["oh"] * 0.58),
              "cloth_red", rot=(0.0, 0.0, 0.10))
    # ---- 红灯笼对（门侧）+ 骰子招牌（门上方）
    for sx in (-1.0, 1.0):
        wall_lantern_iron(b, dx + sx * (door_w / 2.0 + 24.0), yf - 1.0,
                          DOOR_SILL + DOOR_H + 18.0, s=13.0)
    dice_sign(b, dx, yf, plinth_h + wall_h - 34.0)
    # ---- 地窖口（右前墙脚）：石槛 + 暗腔斜门 + 铁环
    c_x = W * 0.30
    b.box_bottom((44.0, 20.0, 12.0), (c_x, yf - 8.0), 0.0, "stone_dark", bevel=BEV_MID)
    b.box((38.0, 14.0, 6.0), (c_x, yf - 10.0, 10.0), "cavity", rot=(0.42, 0.0, 0.0))
    b.box_bottom((36.0, 3.0, 20.0), (c_x, yf - 2.0), 0.0, "wood_dark", rot=None)
    b.cylinder((c_x + 12.0, yf - 13.0, 14.0), 4.0, 2.5, "iron", segments=10, axis="Y")
    # ---- 歪烟囱（里面烧着赌桌边的火盆）+ 山墙
    ch_x = W * 0.24
    ch_y = yf + 13.0
    ch_top = eave + rise - 14.0
    ch_roof = gable_roof_z(eave, rise, D / 2.0 + over, ch_y)
    chimney(b, 24.0, 24.0, ch_top, "brick", ch_x, ch_y, foot=0.0,
            cap_mat="stone_dark", cap=10.0, roof=ch_roof)
    roof_gable(b, W, D, rise, over, "wood_roof", z=eave, thickness=14.0,
               mat_under="wood_dark", cap_size=(26.0, 13.0), cap_mat="wood_dark",
               board_h=8.0, ao_mat="shadow_mid")
    gable_w = win_rect("garret", bay_w=D * 0.5, floor_z=eave)
    gable_w["u"] = -D * 0.12
    gable_infill(b, W, D, rise, "wood_dark", z=eave, thickness=13.0,
                 hole=(gable_w["u"], gable_w["ow"], gable_w["z0"], gable_w["z1"]))
    for sx in (-1.0, 1.0):
        put_window(b, gable_w, gable_w["u"], sx * (W / 2.0), axis="Y", face_dir=sx,
                   frame_mat="iron")
    # ---- 门口酒桶两只（进赌坊的"水"）
    barrel(b, x=dx - door_w - 26.0, y=yf - 20.0, z=0.0, r=13.0, h=36.0, lid=True)
    barrel(b, x=dx - door_w - 26.0 + 30.0, y=yf - 14.0, z=0.0, r=13.0, h=36.0)

    ob = b.to_object()
    spec = _mk("gambling_den", width_cells, {
        "depth": D, "plinth_h": plinth_h, "wall_h": wall_h, "eave_h": eave,
        "rise": rise, "total_h": eave + rise, "overhang": over, "roof_t": 14.0,
        "storey_h": [wall_h], "door": (door_w, DOOR_H), "door_x": dx,
        "bays": bays, "high_windows": len(wins), "red_lanterns": 2, "cellar": True,
        "window": (wins[0]["ow"], wins[0]["oh"], wins[0]["z0"] - plinth_h),
        "gable_window": (gable_w["ow"], gable_w["oh"], gable_w["u"], gable_w["z0"]),
        "chimneys": [{"x": ch_x, "y": ch_y, "roof": ch_roof, "top": ch_top + 10.0,
                      "foot": 0.0, "w": 24.0, "d": 24.0}],
        "material": "通体暗木板 + 小高窗铁栅半掩红帘 + 红灯笼对 + 骰子招牌 + 地窖口"})
    return ob, spec


def bw_pad_guard(W, bays):
    """开间窗与门的避让半径：半开间宽（赌坊小高窗避门用）。"""
    return W / float(bays) * 0.5


# ---------------------------------------------------------------- 10.5 大赌场 grand_casino

CASINO_TIERS = {
    # 大赌场（赌场族 Lv2，city/capital 投放）：穹顶门楼（铜金穹顶）+ 彩旗串 + 铜檐口 +
    # 柱廊大门 + 红毯大台阶 + 仪仗卫兵。
    16: dict(D=236.0, plinth=20.0, storey=(204.0, 204.0), rise=100.0, wt=22.0,
             door_w=58.0, risa_w=180.0, risa_fwd=26.0, dome_r=54.0,
             dome_drum=32.0, dome_h=52.0, finial=18.0),
}


def assemble_grand_casino(width_cells=16):
    """大赌场（赌场族 Lv2）：抹灰古典立面（白石壁柱 + 铜檐口）+ 中央穹顶门楼（拱门双柱 +
    玫瑰圆窗）+ 彩旗串 + 红毯大台阶 + 仪仗卫兵（持矛立卫）。

    与 guildhall/town_hall 的可辨差异（≥2 项）：
    ① **穹顶门楼**（铜金穹顶 + 鼓座）—— 行政厅是平檐/钟楼，赌场靠穹顶炫富；
    ② **彩旗串 + 铜檐口 + 红毯**（三件一组的热闹富贵读法）—— 行政建筑克制不挂彩；
    ③ 仪仗卫兵（门口持矛立卫两尊）—— 看场子的。
    """
    t = CASINO_TIERS[width_cells]
    W = width_cells * CELL
    D, plinth_h = t["D"], t["plinth"]
    sh1, sh2 = t["storey"]
    rise, wt, door_w = t["rise"], t["wt"], t["door_w"]
    risa_w, risa_fwd = t["risa_w"], t["risa_fwd"]
    dome_r, dome_drum, dome_h, finial = t["dome_r"], t["dome_drum"], t["dome_h"], t["finial"]
    over = eave_over(W)
    eave = plinth_h + sh1 + sh2
    z2 = plinth_h + sh1
    yf = -D / 2.0
    yrf = yf - risa_fwd                  # 门楼前面
    bays = bays_of(width_cells)
    # 上层拱窗（白石圈 + 铜框玻璃）；拱头高度按窗宽一半，洞口矩形洞顶开到拱顶 —— 洞与拱吻合
    _d1, wins2 = bay_openings(W, bays, WIN_UP, floor_z=z2, w_scale=1.06, h_scale=0.94)
    wins2 = [w for w in wins2 if abs(w["cx"]) > risa_w * 0.5 + 10.0]
    # 一层高窗（铜框直棂，h_scale 抬高读"气派"但拱头不越层间白石带）
    gwins = []
    for cx in (-W * 0.345, W * 0.345):
        w = win_rect(WIN_LOW, bay_w=W * 0.22, floor_z=plinth_h, w_scale=0.96,
                     h_scale=1.15)
        w["cx"] = cx
        gwins.append(w)

    b = Builder("grand_casino_w%d" % width_cells)
    contact_shadow(b, W, D + risa_fwd + 96.0, spread=38.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(-risa_w * 0.42, risa_w * 0.42), lip=12.0)
    # ---- 主体：抹灰两层（白石腰线）+ 一层铜框高窗 + 二层拱窗（白石圈）+ 铜檐口 + 壁柱
    room_shell(b, W, D, plinth_h, sh1, wt, "plaster",
               front_openings=win_holes(gwins))
    room_shell(b, W, D, z2, sh2, wt, "plaster",
               front_openings=[(w["cx"], w["ow"] + 4.0, w["z0"] - 4.0,
                                w["z1"] + w["ow"] * 0.5 + 2.0) for w in wins2])
    b.box_bottom((W + 12.0, D + 10.0, 14.0), (0.0, 0.0), z2 - 14.0, "white_stone",
                 bevel=BEV_BIG)
    for w in gwins:
        put_window(b, w, w["cx"], yf, frame_mat="bronze")
    for w in wins2:
        arched_window(b, w["cx"], yf - 1.0, w["z0"], w["ow"], w["oh"],
                      w["ow"] * 0.5, ring="white_stone")
    for px in (-W / 2.0 + 12.0, -W * 0.30, -risa_w * 0.5 - 14.0,
               risa_w * 0.5 + 14.0, W * 0.30, W / 2.0 - 12.0):
        pilaster_strip(b, px, yf - 1.0, plinth_h + 2.0, eave - 8.0, w=18.0, depth=10.0)
    # 铜檐口两道（层间 + 檐口，"金饰"读法走铜金色）
    for (zc, ww) in ((z2 - 20.0, W + 14.0), (eave - 12.0, W + 16.0)):
        b.box_bottom((ww, 14.0, 9.0), (0.0, yf - 3.0), zc, "bronze", bevel=BEV_SMALL)
    # ---- 中央门楼：前凸壁体 + 拱门（真洞）+ 双柱 + 玫瑰圆窗 + 鼓座 + 铜金穹顶
    yrc = (yrf + yf + wt) / 2.0
    wall_panel(b, risa_w, eave - plinth_h + 26.0, wt, "plaster", 0.0,
               yf - risa_fwd / 2.0, plinth_h,
               openings=[(0.0, 96.0, DOOR_SILL, DOOR_SILL + DOOR_H + 34.0)])
    b.box((96.0 - 4.0, risa_fwd + 18.0, DOOR_SILL + DOOR_H + 34.0),
          (0.0, yrf + 4.0 + (risa_fwd + 18.0) / 2.0,
           (DOOR_SILL + DOOR_H + 34.0) / 2.0), "cavity")
    leaf_w = 46.0
    for sx in (-1.0, 1.0):
        door(b, h=DOOR_H, w=leaf_w, mat="wood_door", x=sx * (leaf_w / 2.0 + 2.0),
             y=yrf + 2.0, z=DOOR_SILL, frame_mat="bronze", frame=8.0, planks=4,
             iron=True)
    b.box_bottom((8.0, 10.0, DOOR_H), (0.0, yrf - 1.0), DOOR_SILL, "bronze")
    b.box_bottom((96.0 - 10.0, 5.0, 36.0), (0.0, yrf + 4.0),
                 DOOR_SILL + DOOR_H + 1.0, "wood_door")   # 拱门上亮板（门扇本身 150）
    ring_stone(b, 0.0, yrf - 1.0, DOOR_SILL + DOOR_H + 34.0, 54.0, "white_stone",
               blocks=11, depth=12.0, thick=16.0, a0=0.0, a1=math.pi)
    for sx in (-1.0, 1.0):               # 双柱（白石 + 铜头铜础）
        cxx = sx * (risa_w * 0.5 - 18.0)
        b.cylinder((cxx, yrf - 12.0, plinth_h + (z2 - plinth_h) * 0.5 + 8.0), 12.0,
                   z2 - plinth_h - 6.0, "white_stone", segments=14)
        b.cylinder((cxx, yrf - 12.0, plinth_h + 7.0), 15.0, 14.0, "bronze", segments=14)
        b.cylinder((cxx, yrf - 12.0, z2 - 4.0), 15.0, 10.0, "bronze", segments=14)
    rose_window(b, 0.0, yrf - wt * 0.5 - 3.0, z2 + sh2 * 0.52, 26.0, spokes=8)
    b.box_bottom((risa_w + 16.0, risa_fwd + 22.0, 16.0), (0.0, yrf + risa_fwd * 0.5 - 2.0),
                 eave + 10.0, "white_stone", bevel=BEV_BIG)     # 门楼披檐压顶
    for sx in (-1.0, 1.0):
        b.box_bottom((20.0, 14.0, 12.0), (sx * (risa_w * 0.5 - 4.0), yrf - 2.0),
                     eave + 26.0, "white_stone", bevel=BEV_MID)  # 压顶端块
    dome_top = dome_cap(b, 0.0, yrf + risa_fwd * 0.5 - 3.0, eave + 26.0, dome_r,
                        dome_h, "bronze", segments=20, drum=dome_drum,
                        drum_mat="white_stone", finial_h=finial, finial_mat="bronze")
    # ---- 红毯大台阶 + 彩旗串 + 仪仗卫兵两尊
    grand_stair(b, 0.0, yrf - 14.0, plinth_h + DOOR_SILL, w=150.0, n=3, step_h=9.3,
                step_d=26.0, mat="stone")
    b.box_bottom((112.0, 66.0, 4.5), (0.0, yrf - 14.0 + 40.0), plinth_h + 0.5,
                 "cloth_red")
    pennant_line(b, -W * 0.40, W * 0.40, yrf - 30.0, eave - 26.0, n=11, sag=20.0)
    for sx in (-1.0, 1.0):               # 卫兵：立卫 + 铁矛 + 铜缨（130 读真人尺寸）
        gxx = sx * (risa_w * 0.5 + 42.0)
        b.box_bottom((30.0, 22.0, 16.0), (gxx, yrf - 34.0), 0.0, "stone_dark",
                     bevel=BEV_SMALL)
        stickman(b, x=gxx, y=yrf - 34.0, z=16.0, h=124.0)
        strut(b, (gxx + 9.0, yrf - 34.0, 16.0), (gxx + 9.0, yrf - 34.0, 172.0), 4.5,
              "iron")
        b.cylinder((gxx + 9.0, yrf - 34.0, 176.0), 4.5, 10.0, "bronze", segments=8)
    # ---- 屋顶（陶瓦缓坡）+ 山墙盲窗 + 角部烟囱
    roof_gable(b, W, D, rise, over, "tile", z=eave, thickness=16.0,
               mat_under="wood_dark", cap_size=(32.0, 15.0), cap_mat="stone_dark",
               board_h=9.0, ao_faces=(yf, D / 2.0))
    gable_infill(b, W, D, rise, "plaster", z=eave, thickness=16.0)
    ch_x = -W * 0.36
    ch_y = D * 0.14
    ch_top = eave + rise + 26.0
    ch_roof = gable_roof_z(eave, rise, D / 2.0 + over, ch_y)
    chimney(b, 30.0, 30.0, ch_top, "brick", ch_x, ch_y, foot=0.0,
            cap_mat="white_stone", cap=12.0, roof=ch_roof, skirt_h=20.0, skirt_lip=8.0)

    ob = b.to_object()
    spec = _mk("grand_casino", width_cells, {
        "depth": D + risa_fwd, "plinth_h": plinth_h, "wall_h": sh1 + sh2,
        "eave_h": eave, "rise": rise, "total_h": dome_top["top"], "overhang": over,
        "roof_t": 16.0, "storey_h": [sh1, sh2], "double_storey": True,
        "door": (leaf_w, DOOR_H), "door_x": 0.0, "bays": bays,
        "dome_r": dome_r, "dome_top": dome_top["top"], "pilasters": 6,
        "pennants": 11, "guards": 2, "red_carpet": True,
        "window": (gwins[0]["ow"], gwins[0]["oh"], gwins[0]["z0"] - plinth_h),
        "window_up": (wins2[0]["ow"], wins2[0]["oh"], wins2[0]["z0"] - z2),
        "chimneys": [{"x": ch_x, "y": ch_y, "roof": ch_roof, "top": ch_top + 12.0,
                      "foot": 0.0, "w": 30.0, "d": 30.0}],
        "material": "抹灰 + 白石壁柱 / 陶瓦 + 铜金穹顶门楼 + 彩旗串 + 红毯 + 仪仗卫兵"})
    return ob, spec


# ---------------------------------------------------------------- 10.6 学院 academy

ACADEMY_TIERS = {
    # 学院（科研族 Lv3，任务口径 town 起双档；文档登记 capital 起——差异见汇报）：
    # 两层 + 前拱廊（真拱柱廊）+ 圆窗 + 天文台小穹顶；library 保持在科研 Lv2。
    12: dict(D=196.0, plinth=18.0, storey=(200.0, 200.0), rise=96.0, wt=20.0,
             door_w=56.0, arc_d=42.0, dome_r=40.0),
    16: dict(D=224.0, plinth=20.0, storey=(204.0, 204.0), rise=112.0, wt=22.0,
             door_w=58.0, arc_d=48.0, dome_r=46.0),
}


def assemble_academy(width_cells=12):
    """学院（科研族 Lv3）：两层抹灰 + 白石隅石，**前拱廊**（真拱开洞柱廊 + 单坡廊顶）+
    上层圆窗（玫瑰小窗）+ 右端天文台小穹顶（白石穹 + 铜顶针）。

    与 library 的可辨差异（≥2 项）：
    ① **前拱廊**（人能在廊下走的开洞柱廊）—— library 是实墙铅条高窗组 + 中央门楼；
    ② 上层**圆窗**（玫瑰小窗一排）—— library 是竖向长窗；
    ③ **天文台小穹顶**（右端鼓座穹顶）—— 科研 Lv3 的天文读法。
    """
    t = ACADEMY_TIERS[width_cells]
    W = width_cells * CELL
    D, plinth_h = t["D"], t["plinth"]
    sh1, sh2 = t["storey"]
    rise, wt, door_w = t["rise"], t["wt"], t["door_w"]
    arc_d, dome_r = t["arc_d"], t["dome_r"]
    over = eave_over(W)
    eave = plinth_h + sh1 + sh2
    z2 = plinth_h + sh1
    yf = -D / 2.0
    arc_h = int(sh1 * 0.70)          # 拱洞净高（拱头另加，面板总高要罩住拱头）
    arc_y = yf - arc_d / 2.0
    bays = bays_of(width_cells)
    dx = 0.0
    # 廊柱间拱洞（真洞）：每开间一拱；**面板高 = 洞高 + 拱头 + 10**（旧版面板比拱头
    # 矮，拱顶被面板上缘削平、读成矩形洞——返工点）
    arches = []
    arc_w = W - 10.0
    n_arch = bays
    arch_head = arc_w / n_arch * 0.31
    for i in range(n_arch):
        cx = -arc_w / 2.0 + arc_w * (i + 0.5) / n_arch
        arches.append((cx, arc_w / n_arch * 0.62, plinth_h, plinth_h + arc_h,
                       arch_head, "round"))
    arc_panel_h = arc_h + arch_head + 10.0

    b = Builder("academy_w%d" % width_cells)
    contact_shadow(b, W, D + arc_d, spread=34.0)
    plinth(b, W, D, plinth_h, "stone_dark", 0, 0, 0,
           gap=(dx - door_w / 2.0 - 6.0, dx + door_w / 2.0 + 6.0), lip=10.0)
    # ---- 主体：两层抹灰 + 白石隅石 + 石腰线
    room_shell(b, W, D, plinth_h, sh1, wt, "plaster",
               front_openings=[(dx, door_w, DOOR_SILL, DOOR_SILL + DOOR_H),
                               (-W * 0.30, 62.0, plinth_h + 74.0, plinth_h + 74.0 + 96.0),
                               (W * 0.30, 62.0, plinth_h + 74.0, plinth_h + 74.0 + 96.0)])
    room_shell(b, W, D, z2, sh2, wt, "plaster", front_openings=[])
    quoins(b, W - 2.0 * wt, D, sh1 + sh2, "white_stone", 0.0, yf + wt / 2.0,
           plinth_h + 4.0, size=22.0, step=46.0, front=False, sides=True)
    b.box_bottom((W + 10.0, D + 8.0, 13.0), (0.0, 0.0), z2 - 13.0, "white_stone",
                 bevel=BEV_BIG)
    door(b, h=DOOR_H, w=door_w, mat="wood_door", x=dx, y=yf, z=DOOR_SILL,
         frame_mat="white_stone", frame=9.0, planks=4, iron=True)
    step_stone(b, w=door_w + 46.0, depth=30.0, h=9.0, x=dx, y=yf - 22.0)
    # 一层廊内窗（方窗贴玻璃即可，洞已开）
    for cxx in (-W * 0.30, W * 0.30):
        b.box((58.0, 6.0, 92.0), (cxx, yf + 1.0, plinth_h + 74.0 + 48.0), "glass")
        for sx in (-1.0, 1.0):
            b.box_bottom((8.0, 10.0, 100.0), (cxx + sx * 33.0, yf), plinth_h + 70.0,
                         "timber")
    # ---- 上层圆窗（玫瑰小窗一排）——学院立面主窗型
    for i, cx in enumerate(bay_centers(W, bays)):
        rose_window(b, cx, yf - wt * 0.5 - 3.0, z2 + sh2 * 0.54,
                    19.0 if width_cells <= 12 else 22.0, spokes=6)
        b.box_bottom((52.0, 8.0, 9.0), (cx, yf - 2.0), z2 + sh2 * 0.54 - 34.0,
                     "white_stone")
    # ---- 前拱廊：白石拱柱廊（真拱开洞，拱头完整）+ 单坡廊顶 + 廊顶檐口
    arc_top = plinth_h + arc_panel_h
    arch_wall(b, W - 10.0, arc_panel_h, arc_d, "white_stone", 0.0,
              arc_y + arc_d / 2.0, plinth_h, openings=arches)
    ang = math.atan2(16.0, arc_d + 6.0)
    # 廊顶必须**罩在面板顶上**（arc_top）——旧写法 z=arc_h+12 比拱头矮，檐板横切
    # 拱头、拱顶露在檐板上方读成"一排小暗窗"（返工点）。
    b.box((W - 2.0, math.hypot(arc_d + 6.0, 16.0) + 8.0, 12.0),
          (0.0, arc_y - (arc_d + 6.0) / 2.0 + 4.0, arc_top + 4.0),
          "slate", rot=(ang, 0.0, 0.0))
    b.box_bottom((W - 2.0, 9.0, 12.0), (0.0, yf - arc_d - 4.0), arc_top - 8.0,
                 "wood_dark")
    for sx in (-1.0, 1.0):               # 廊端封头（半山墙）
        b.box_bottom((12.0, arc_d, arc_panel_h * 0.80), (sx * (W / 2.0 - 6.0), arc_y),
                     plinth_h, "white_stone")
    # ---- 天文台小穹顶（右端：方形基座穿屋面 + 白石鼓座 + 白穹 + 铜顶针）
    # 基座必须把穹顶明显顶过主脊（旧版只探出一个小铜钉，读成"烟囱帽"——返工点）；
    # 剪影预算：穹顶总顶 ≈ eave+138（实测剪影余量 ~23px 内，超了先收 finial）。
    dbs = dome_r * 2.0 + 20.0
    dbx = W / 2.0 - dbs * 0.5 - 8.0
    b.box_bottom((dbs, dbs, 88.0), (dbx, 0.0), eave - 30.0, "plaster")
    b.box_bottom((dbs + 12.0, dbs + 12.0, 12.0), (dbx, 0.0), eave + 58.0,
                 "white_stone", bevel=BEV_BIG)
    dome_top = dome_cap(b, dbx, 0.0, eave + 58.0, dome_r, dome_r * 0.95, "white_stone",
                        segments=18, drum=18.0, drum_mat="white_stone",
                        finial_h=18.0, finial_mat="bronze")
    # ---- 屋顶（石板）+ 山墙阁楼窗 + 烟囱（左端）
    roof_gable(b, W, D, rise, over, "slate", z=eave, thickness=15.0,
               mat_under="wood_dark", cap_size=(28.0, 14.0), cap_mat="stone_dark",
               board_h=9.0, ao_faces=(yf, D / 2.0))
    gable_w = win_rect(WIN_GABLE, bay_w=D * 0.5, floor_z=eave)
    gable_w["u"] = -D * 0.12
    gable_infill(b, W, D, rise, "plaster", z=eave, thickness=15.0,
                 hole=(gable_w["u"], gable_w["ow"], gable_w["z0"], gable_w["z1"]))
    for sx in (-1.0, 1.0):
        put_window(b, gable_w, gable_w["u"], sx * (W / 2.0), axis="Y", face_dir=sx)
    # ---- 烟囱（左翼有壁炉）：立在**拱廊屋顶上**（旧版落地柱穿过拱廊开洞——返工点），
    # 再穿主屋面前坡 + 泛水裙；x 取拱间柱墩位（躲开拱洞）。
    ch_x = W * 0.165
    ch_y = arc_y - 4.0
    ch_top = eave + rise - 16.0
    ch_roof = gable_roof_z(eave, rise, D / 2.0 + over, ch_y)
    chimney(b, 28.0, 26.0, ch_top, "brick", ch_x, ch_y, foot=arc_top - 8.0,
            cap_mat="white_stone", cap=11.0, roof=ch_roof)

    ob = b.to_object()
    spec = _mk("academy", width_cells, {
        "depth": D + arc_d, "plinth_h": plinth_h, "wall_h": sh1 + sh2, "eave_h": eave,
        "rise": rise, "total_h": max(eave + rise, dome_top["top"]), "overhang": over,
        "roof_t": 15.0, "storey_h": [sh1, sh2], "double_storey": True,
        "door": (door_w, DOOR_H), "door_x": dx, "bays": bays,
        "arcade": (n_arch, arc_d, arc_h), "round_windows": bays,
        "dome_r": dome_r, "dome_top": dome_top["top"],
        "window": (62.0, 96.0, 74.0),
        "window_up": (38.0, 38.0, sh2 * 0.54 - 19.0),
        "gable_window": (gable_w["ow"], gable_w["oh"], gable_w["u"], gable_w["z0"]),
        "chimneys": [{"x": ch_x, "y": ch_y, "roof": ch_roof, "top": ch_top + 11.0,
                      "foot": 0.0, "w": 30.0, "d": 26.0}],
        "material": "抹灰 + 白石隅石 / 石板 + 前拱廊 + 圆窗 + 天文台小穹顶"})
    return ob, spec


# ---------------------------------------------------------------- 10.7 观星台 observatory

OBSERVATORY_TIERS = {
    # 观星台（科研族 capital 起识别件——任务口径 8 格单档）：圆塔 + 可开穹缝（暗缝 + 铜轨）
    # + 铜望远镜管 + 露台铜仪（浑环）。
    8: dict(R=94.0, plinth=18.0, body=288.0, taper=0.90, door_w=52.0,
            dome_r=66.0, dome_drum=14.0, dome_h=54.0, finial=16.0, slit_w=17.0),
}


def assemble_observatory(width_cells=8):
    """观星台：收分圆塔（石砌两段）+ 悬挑露台（矮栏）+ 铜穹顶（**可开穹缝**：暗缝 + 铜轨）
    + 铜望远镜管（斜出穹缝）+ 露台浑环仪。

    与 mage_tower 的可辨差异（≥2 项）：
    ① **铜穹顶 + 穹缝 + 望远镜管**（仪器读法）—— 法师塔是尖锥 + 水晶灯室 + 悬浮水晶；
    ② 露台**浑环仪**（铜环十字架）—— 没有彩窗/符文/魔法件，全是铜器；
    ③ 材质：石塔 + 铜顶（patina 铜绿），法师塔是石塔 + 板岩尖顶。
    """
    tt = OBSERVATORY_TIERS[width_cells]
    R, plinth_h = tt["R"], tt["plinth"]
    body_h, taper = tt["body"], tt["taper"]
    door_w = tt["door_w"]
    dome_r, dome_drum, dome_h = tt["dome_r"], tt["dome_drum"], tt["dome_h"]
    finial, slit_w = tt["finial"], tt["slit_w"]
    D = 2.0 * R
    top_r = R * taper
    yf = -R - 10.0

    b = Builder("observatory_w%d" % width_cells)
    contact_shadow(b, D, D, spread=28.0)
    b.cylinder((0.0, 0.0, plinth_h * 0.6), R * 1.12, plinth_h * 1.2, "stone_dark",
               segments=20)
    # ---- 两段收分塔身 + 段间白石带
    sec = body_h / 2.0
    r_prev = R
    for k in range(2):
        r_next = R * (taper ** ((k + 1) / 2.0))
        b.cylinder((0.0, 0.0, plinth_h + sec * (k + 0.5)), r_prev, sec, "stone",
                   segments=20, taper=r_next / r_prev)
        if k:
            b.cylinder((0.0, 0.0, plinth_h + sec), r_prev * 1.10, 12.0, "white_stone",
                       segments=20)
        r_prev = r_next
    z_top = plinth_h + body_h
    # ---- 悬挑露台：牛腿一圈 + 石檐环 + 矮栏（栏要矮——不挡穹顶读数）
    for k in range(12):
        th = 2.0 * math.pi * k / 12.0
        b.box_bottom((11.0, 11.0, 22.0), (math.cos(th) * top_r * 1.02,
                                          math.sin(th) * top_r * 1.02), z_top - 14.0,
                     "stone_dark")
    b.cylinder((0.0, 0.0, z_top + 8.0), top_r * 1.30, 18.0, "stone", segments=20)
    b.cylinder((0.0, 0.0, z_top + 19.0), top_r * 1.34, 6.0, "white_stone", segments=20)
    for k in range(10):
        th = 2.0 * math.pi * k / 10.0
        px, py = math.cos(th) * top_r * 1.28, math.sin(th) * top_r * 1.28
        b.box_bottom((6.0, 6.0, 20.0), (px, py), z_top + 25.0, "white_stone")
    b.cylinder((0.0, 0.0, z_top + 41.0), top_r * 1.30, 6.0, "white_stone", segments=20)
    # ---- 塔身门窗：拱门（真拱门廊）+ 两段各一扇圆头盲拱窗
    arched_doorway(b, 0.0, yf, 28.0, door_w, head=door_w * 0.5, mat="stone",
                   porch_w=door_w + 44.0)
    for k, zz in enumerate((plinth_h + sec * 0.55, plinth_h + sec * 1.55)):
        rr = R * (1.0 - (zz - plinth_h) / body_h * (1.0 - taper))
        blind_arch(b, 0.0, -rr + 2.0, zz, 40.0, 62.0, head=20.0, mat="cavity",
                   ring="white_stone", profile="round", sill=True)
    # ---- 铜穹顶（patina 铜绿）+ 可开穹缝（暗缝凹槽 + 双铜轨）+ 铜望远镜管
    z_dome = z_top + 47.0
    dome_top = dome_cap(b, 0.0, 0.0, z_dome, dome_r, dome_h, "patina", segments=20,
                        drum=dome_drum, drum_mat="stone_dark", finial_h=finial,
                        finial_mat="bronze")
    b.box((slit_w, dome_r * 0.72, dome_h + dome_drum + 6.0),
          (0.0, -dome_r * 0.34, z_dome + dome_drum + (dome_h + dome_drum) * 0.42),
          "cavity")
    for sx in (-1.0, 1.0):               # 穹缝双铜轨
        b.box_bottom((4.5, dome_r * 0.70, dome_h + dome_drum + 4.0),
                     (sx * (slit_w * 0.5 + 3.0), -dome_r * 0.36,
                      z_dome + dome_drum - 2.0), 0.0, "bronze")
    tube_z = z_dome + dome_drum + dome_h * 0.62
    b.box((17.0, 17.0, 112.0), (0.0, -dome_r * 0.42, tube_z + 26.0), "bronze",
          rot=(math.radians(-38.0), 0.0, 0.0), bevel=BEV_MID)
    b.cylinder((0.0, -dome_r * 0.86, tube_z - 12.0), 10.5, 18.0, "bronze", segments=12)
    b.box((13.0, 13.0, 16.0), (0.0, -dome_r * 0.12, tube_z + 74.0), "iron",
          rot=(math.radians(-38.0), 0.0, 0.0))
    # ---- 露台浑环仪（铜环十字架：底柱 + 双正交环 + 轴杆）
    ax, ay = -top_r * 0.86, -top_r * 0.52
    az = z_top + 27.0
    b.cylinder((ax, ay, az + 16.0), 5.0, 32.0, "bronze", segments=10)
    b.cylinder((ax, ay, az + 44.0), 22.0, 3.0, "bronze", segments=18, axis="Y")
    b.cylinder((ax, ay, az + 44.0), 19.0, 3.0, "bronze", segments=18)
    strut(b, (ax, ay, az + 30.0), (ax, ay, az + 58.0), 3.0, "iron")

    ob = b.to_object()
    spec = _mk("observatory", width_cells, {
        "depth": D, "plinth_h": plinth_h, "wall_h": body_h, "eave_h": z_top,
        "rise": dome_top["top"] - z_top, "total_h": dome_top["top"],
        "overhang": top_r * 0.14, "roof_t": 0.0, "storey_h": [body_h / 2.0] * 2,
        "round_tower": True, "tower_h": body_h, "dome_r": dome_r,
        "dome_top": dome_top["top"], "slit_w": slit_w, "telescope": True,
        "armillary": True,
        "door": (door_w, DOOR_H), "door_x": 0.0, "floor_h": FLOOR_H_SPEC,
        "window": (40.0, 62.0, sec * 0.55),
        "ratio_exempt": True, "eave_exempt": True,
        "reason": "观星台：竖向塔体（两段收分圆塔 + 悬挑露台 + 铜穹顶 + 望远镜管）；"
                  "穹顶出檐按塔半径比例（非民居坡檐口径，eave_exempt）",
        "material": "石砌圆塔 + 铜绿穹顶（可开穹缝）+ 铜望远镜 + 浑环仪"})
    return ob, spec


# ---------------------------------------------------------------- 10.8 花店 flower_shop

FLOWER_SHOP_TIERS = {
    # 花店（town 起，窗口标提案/待定——文档原口径为 shop 载体 DRESS，本批按任务指令落独立件）：
    # 大开间店面 + 实布雨篷 + 悬篮 + 窗台花箱 + 桶栽组。识别度全靠花（花量是硬指标）。
    8:  dict(D=158.0, plinth=16.0, storey=221, knee=44.0, rise=80.0, wt=18.0,
             door_w=54.0, front_w=116.0, front_cx=44.0, awn_z=150.0, awn_d=54.0),
    12: dict(D=196.0, plinth=18.0, storey=221, rise=96.0, wt=20.0, door_w=56.0,
             jetty=10.0, front_w=178.0, front_cx=64.0, awn_z=152.0, awn_d=58.0),
}


def assemble_flower_shop(width_cells=8):
    """花店：底层大开间橱窗 + **实布雨篷**（布面 + 扇贝垂边 + 铁撑臂）+ 悬篮 + 窗台花箱 +
    门前桶栽组 + 花架陈列台；上层（12 格）抹灰小窗 + 花箱。

    与 shop 的可辨差异（≥2 项）：
    ① **实布雨篷**（自带布篷 + 垂边扇贝）—— shop 只有铁雨篷挂点（布篷留给道具层）；
    ② **花量三处一组**（悬篮 ×2~3 / 窗台花箱 ×2~3 / 桶栽 ×3 + 陈列台）—— 店面几乎被花包围；
    ③ 底层抹灰明快（shop 是深木板）+ 花色调红黄蓝。
    """
    t = FLOWER_SHOP_TIERS[width_cells]
    W = width_cells * CELL
    D, plinth_h, sh = t["D"], t["plinth"], t["storey"]
    rise, wt, door_w = t["rise"], t["wt"], t["door_w"]
    knee = t.get("knee")
    jetty = t.get("jetty", 0.0)
    fw, fcx, awn_z, awn_d = t["front_w"], t["front_cx"], t["awn_z"], t["awn_d"]
    over = eave_over(W)
    eave = plinth_h + (sh + knee if knee else sh * 2.0)
    yf0 = -D / 2.0
    yf = yf0 - jetty
    yc = (yf + D / 2.0) / 2.0
    bays = bays_of(width_cells)
    glass_z0 = plinth_h + 44.0
    glass_h = min(sh - 100.0, 132.0)
    dx = -W * 0.24

    b = Builder("flower_shop_w%d" % width_cells)
    contact_shadow(b, W, D + jetty, spread=30.0)
    plinth(b, W, D, plinth_h, "white_stone", 0, 0, 0,
           gap=(dx - door_w / 2.0 - 6.0, dx + door_w / 2.0 + 6.0), lip=10.0)
    # ---- 一层：抹灰明快底色 + 门 + 整开间橱窗
    front = [(dx, door_w, DOOR_SILL, DOOR_SILL + DOOR_H),
             (fcx, fw, glass_z0, glass_z0 + glass_h)]
    room_shell(b, W, D, plinth_h, sh, wt, "plaster", front_openings=front)
    door(b, h=DOOR_H, w=door_w, mat="wood_door", x=dx, y=yf0, z=DOOR_SILL,
         frame_mat="timber", planks=3)
    step_stone(b, w=door_w + 30.0, depth=24.0, h=9.0, x=dx, y=yf0 - 17.0)
    shop_window(b, fcx, fw - 22.0, yf0, glass_z0, glass_h, pier=11.0,
                lights=max(3, int(round(fw / 48.0))), counter_mat="wood_light")
    # ---- 实布雨篷：斜布面（cloth_ochre）+ 扇贝垂边（红白相间半圆读法）+ 双铁撑臂
    awn_y = yf0 - 3.0
    ang = math.atan2(20.0, awn_d)
    b.box((fw + 20.0, math.hypot(awn_d, 20.0) + 6.0, 7.0),
          (fcx, awn_y - awn_d / 2.0, awn_z - 10.0), "cloth_ochre", rot=(ang, 0.0, 0.0))
    n_sc = max(4, int((fw + 20.0) / 30.0))
    for i in range(n_sc):
        px = fcx - (fw + 20.0) / 2.0 + (fw + 20.0) * (i + 0.5) / n_sc
        drop = 12.0 + 4.0 * abs(_jit(i, 863))
        b.box((26.0, 4.0, drop), (px, awn_y - awn_d - 1.0,
                                  awn_z - 18.0 - drop * 0.35),
              "cloth_red" if i % 2 else "canvas")
    for sx in (-1.0, 1.0):
        strut(b, (fcx + sx * (fw * 0.5 - 4.0), yf0 - 2.0, awn_z + 8.0),
              (fcx + sx * (fw * 0.5 - 4.0), yf0 - awn_d + 8.0, awn_z - 16.0), 5.0,
              "iron")
    # ---- 悬篮 ×3（雨篷前缘）+ 窗台花箱（橱窗两侧裙墙）
    for i, bx in enumerate((fcx - fw * 0.32, fcx, fcx + fw * 0.32)):
        flower_basket_hang(b, bx, awn_y - awn_d - 2.0, awn_z - 20.0, r=12.0, seed=i + 1)
    for sxx in (-1.0, 1.0):
        window_flower_box(b, fcx + sxx * (fw * 0.5 + 34.0), yf0,
                          plinth_h + 40.0 + (sh - 100.0), w=64.0, seed=width_cells + sxx)
    # ---- 门前桶栽组（三桶一列）+ 花架陈列台（12 格：前场左角，台面 + 两桶 + 散花；
    # 右端被烟囱占、8 格前场摆不下——陈列台只给 12 格配）
    for i in range(3):
        flower_tub(b, dx - door_w / 2.0 - 30.0 - i * 30.0, yf0 - 14.0 - 8.0 * (i % 2),
                   0.0, r=13.0 - i, h=26.0 - i * 2, seed=width_cells * 3 + i)
    if width_cells >= 12:
        st_x = -W * 0.5 + 46.0
        st_y = yf0 - 52.0
        b.box_bottom((74.0, 34.0, 8.0), (st_x, st_y), 0.0, "wood", bevel=BEV_MID)
        for sx in (-1.0, 1.0):
            b.box_bottom((7.0, 7.0, 52.0), (st_x + sx * 30.0, st_y), 8.0,
                         "wood_dark")
        b.box_bottom((74.0, 30.0, 7.0), (st_x, st_y), 60.0, "wood", bevel=BEV_MID)
        flower_tub(b, st_x - 16.0, st_y, 67.0, r=10.0, h=18.0, seed=width_cells)
        flower_tub(b, st_x + 16.0, st_y, 67.0, r=9.0, h=16.0, seed=width_cells + 9)
        flower_clump(b, st_x, st_y, 67.0, s=8.0, seed=width_cells + 4, n=4)
    # ---- 上层：12 格 = 完整二层（抹灰 + 木骨 + 小窗 + 花箱）；8 格 = 阁楼膝墙
    if knee:
        knee_w = win_rect(WIN_GABLE, bay_w=D * 0.5, floor_z=eave - knee)
        knee_w["z0"] = eave - knee + 8.0
        knee_w["z1"] = knee_w["z0"] + knee_w["oh"]
        kx = bay_centers(W, bays)
        wall_panel(b, W, knee, D, "plaster", 0.0, yf0, eave - knee,
                   openings=[(cx, knee_w["ow"], knee_w["z0"], knee_w["z1"])
                             for cx in kx])
        for cx in kx:
            put_window(b, knee_w, cx, yf0, frame_mat="timber")
        window_flower_box(b, kx[1], yf0, knee_w["z0"] - 10.0, w=58.0, seed=width_cells)
        roof_gable(b, W, D, rise, over, "slate", z=eave, thickness=13.0,
                   mat_under="wood_dark", cap_size=(26.0, 13.0), board_h=8.0)
        gable_infill(b, W, D, rise, "plaster", z=eave, thickness=13.0)
    else:
        z2 = plinth_h + sh
        _d2, wins2 = bay_openings(W, bays, WIN_UP, floor_z=z2, w_scale=0.9,
                                  shutters=True, skip=(0,))
        wall_panel(b, W, sh, D + jetty, "plaster", 0.0, yc, z2,
                   openings=win_holes(wins2))
        timber_frame(b, W, sh, "timber", (0.0, yf), z2, depth=7.0, post=14.0,
                     top_band=14.0, bays=bays, braces=True,
                     openings=[(w["cx"], w["ow"]) for w in wins2])
        for w in wins2:
            put_window(b, w, w["cx"], yf)
        for w in wins2:                  # 上层每窗一箱（花店的花包到楼上）
            window_flower_box(b, w["cx"], yf, w["z0"] - 11.0, w=58.0, seed=int(w["cx"]))
        roof_gable(b, W, D + jetty, rise, over, "slate", z=eave, thickness=13.0,
                   mat_under="wood_dark", cap_size=(26.0, 13.0), board_h=8.0,
                   ao_faces=(yf, D / 2.0), y=yc)
        gable_w = win_rect(WIN_GABLE, bay_w=(D + jetty) * 0.5, floor_z=eave)
        gable_w["u"] = -D * 0.14
        gable_infill(b, W, D + jetty, rise, "plaster", z=eave, thickness=13.0, y=yc,
                     hole=(gable_w["u"], gable_w["ow"], gable_w["z0"], gable_w["z1"]))
        for sx in (-1.0, 1.0):
            gable_timber(b, D + jetty, rise, "timber", (sx * (W / 2.0), yc), eave,
                         axis="Y", face_dir=sx, thick=11.0)
            put_window(b, gable_w, gable_w["u"], sx * (W / 2.0), axis="Y", face_dir=sx)
    # ---- 烟囱（店里住人）
    ch_x = W / 2.0 - 14.0
    ch_y = yf0 - D * 0.06
    ch_top = eave + rise - (26.0 if knee else -4.0)
    ch_roof = gable_roof_z(eave, rise, (D + jetty) / 2.0 + over, ch_y, y_ridge=yc)
    chimney(b, 28.0, 24.0, ch_top, "brick", ch_x, ch_y, foot=0.0,
            cap_mat="white_stone", cap=10.0, roof=ch_roof, skirt_h=18.0, skirt_lip=7.0)

    ob = b.to_object()
    spec = _mk("flower_shop", width_cells, {
        "depth": D + jetty, "plinth_h": plinth_h,
        "wall_h": sh + (knee or sh),
        "eave_h": eave, "rise": rise, "total_h": eave + rise, "overhang": over,
        "roof_t": 13.0,
        "storey_h": [sh, knee] if knee else [sh, sh],
        "double_storey": not bool(knee), "door": (door_w, DOOR_H), "door_x": dx,
        "bays": bays, "awning": (fw, awn_d), "baskets": 3, "boxes": 3, "tubs": 3,
        "window": (fw, glass_h, glass_z0 - plinth_h),
        "window_up": (knee_w["ow"], knee_w["oh"], knee_w["z0"] - (eave - knee))
                     if knee else (wins2[0]["ow"], wins2[0]["oh"],
                                   wins2[0]["z0"] - (plinth_h + sh)),
        "chimneys": [{"x": ch_x, "y": ch_y, "roof": ch_roof, "top": ch_top + 10.0,
                      "foot": 0.0, "w": 28.0, "d": 24.0}],
        "material": "抹灰 + 木骨 / 石板 + 实布雨篷 + 悬篮花箱桶栽（提案/待定）"})
    return ob, spec


ASSEMBLERS["waystation"] = assemble_waystation
ASSEMBLERS["inn_post"] = assemble_inn_post
ASSEMBLERS["coach_house"] = assemble_coach_house
ASSEMBLERS["gambling_den"] = assemble_gambling_den
ASSEMBLERS["grand_casino"] = assemble_grand_casino
ASSEMBLERS["academy"] = assemble_academy
ASSEMBLERS["observatory"] = assemble_observatory
ASSEMBLERS["flower_shop"] = assemble_flower_shop

#: 分级批次 2 探针条目（追加在既有条目之后，不动既有 —— 既有判定必须不变）
PROBE_LIST += [("waystation", 6), ("waystation", 8),
               ("inn_post", 12), ("inn_post", 16),
               ("coach_house", 12), ("coach_house", 16),
               ("gambling_den", 8), ("gambling_den", 12),
               ("grand_casino", 16),
               ("academy", 12), ("academy", 16),
               ("observatory", 8),
               ("flower_shop", 8), ("flower_shop", 12)]


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
