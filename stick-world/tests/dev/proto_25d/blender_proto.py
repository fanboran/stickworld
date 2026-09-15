# -*- coding: utf-8 -*-
"""blender_proto.py —— 2.5D 原型（引擎侧可行性验证）的 Blender 半场。

只做两件事，**只读导入** `tools/blender_buildings/buildings.py`（不改它）：

1. **烘焙纸片卡**（albedo 层 + glow 层），相机严格对齐 2.5D 目标视角
   （yaw=0°，tilt=20°，正交），透明底 RGBA，像素级两层对齐；
2. **导出 glb**（同一批建筑，几何 + 材质槽，规模 1/32 = 1 Godot 单位 = 1 格）。

跑法（固定命令）::

    "F:/SteamLibrary/steamapps/common/Blender/blender.exe" -b --factory-startup \
        -P stick-world/tests/dev/proto_25d/blender_proto.py

增量跑法（只烘点名 def，其余跳过；cards.json 合并写回，不出 glb/report）::

    BAKE_ONLY=council_hall,cathedral "F:/.../blender.exe" -b --factory-startup \
        -P stick-world/tests/dev/proto_25d/blender_proto.py

产物（stick-world/temp/proto25d/）::

    cards/<def>_w<N>.png        albedo 卡（透明底）
    cards/<def>_w<N>_glow.png   glow 卡（黑底 + 自发光材质，加色叠加用）
    cards/<def>_w<N>_night.png  夜版卡（月夜灯位 + 窗/火自发光，night_mix 切换用）
    cards/cards.json            每卡的像素尺寸 / 世界锚点 / 单位尺寸（Godot 侧读）
    proto25d_buildings.glb      低模几何（材质为纯色回退，见 stdout 警告）
    build_report.json           三角面数 / 材质数 / 尺寸报表
"""

import json
import math
import os
import sys

import bpy
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
# 仓库根 = stick-world/tests/dev/proto_25d -> 上溯 3 级到 stick-world，再上溯到仓库根
REPO = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
TOOLS = os.path.join(REPO, "tools", "blender_buildings")
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

import buildings as B  # noqa: E402  只读导入

# 台基/勒脚不生成（创始人 2026-09-15：地面灰白台基别烘进卡）——墙脚原本砌在
# 台基顶（plinth_h）上，摘掉后整楼下沉贴地（见 layout() 的 _ground_shift）；
# 引擎侧 base_cut 裁剪随之退役。2D bake_export 管线不置此值，不受影响。
B.PLINTH_ENABLED = False

OUT_DIR = os.path.join(REPO, "stick-world", "temp", "proto25d")
CARD_DIR = os.path.join(OUT_DIR, "cards")
GLB_PATH = os.path.join(OUT_DIR, "proto25d_buildings.glb")

# 2.5D 目标视角（§0.3 硬约束：纯正面 + 微俯视，禁水平偏航）。
# 俯角 26°：与 proto_hd2d 场景 TILT_DEG 一致（场景加俯角后，卡的烘焙视角必须同步重烘，
# 否则卡的俯视感停留在旧角度、与角色 billboard 的取向对不上）。
YAW = 0.0
TILT = 26.0
ZOOM = 2.0            # 烘焙像素/世界单位（2x）
PAD = 10.0            # 卡四周留白（世界单位）
RES_MAX = 3000        # 单卡最长边像素上限（护显存）
SCALE = 1.0 / 32.0    # 世界单位(px) -> Godot 单位(格)

#: 街排（def, 格数）——宽度档规则（创始人 2026-09-15 拍板）：**新增档位一律
#: 2 格整数倍**（2/4/6/8/10…），推翻旧"4 格整数倍"约束；存量 4/6/8/12/16 档
#: 保留不动、不返工
#: 2026-09-14 补 house_w16 / warehouse_w16：手工摆主场景（村A语义翻译）需要
#: 16 格档的民居与仓库（村A InitialBuildingsList 的 placeholder/stone_warehouse 均 w16）
STREET = [
    ("cottage", 6),
    ("shelter", 6),
    ("house", 8),
    ("house", 16),
    ("smithy1", 8),
    ("bakery", 8),
    ("shop", 8),
    ("stable", 12),
    ("tavern", 12),
    ("rowhouse", 12),
    ("townhouse", 12),
    ("guildhall", 12),
    ("tower", 6),
    ("cathedral", 16),
    ("barn", 12),
    ("gatehouse", 8),
    ("chapel", 8),
    ("alchemy", 8),
    ("library", 12),
    ("mage_tower", 8),
    ("warehouse", 16),
    # 2026-09-14 city_layout 算法驱动 HD-2D：布局会排到的 def 补卡
    ("barracks", 12),
    ("hayloft", 8),
    ("smithy2", 8),
    ("smithy3", 8),
    ("smithy4", 12),
    ("windmill", 6),
    # 2026-09-14 行政/金融/驿站/赌场/科研族装配器补卡（宽度档 = buildings.py 各
    # XXX_TIERS 字典的实际键，逐档一张卡；6 格档仅装配器允许时用）
    ("council_hall", 8),
    ("town_hall", 12),
    ("town_hall", 16),
    ("governor_palace", 16),
    ("imperial_palace", 16),
    ("belfry", 4),
    ("belfry", 6),
    ("mint", 12),
    ("mint", 16),
    ("waystation", 6),
    ("waystation", 8),
    ("inn_post", 12),
    ("inn_post", 16),
    ("coach_house", 12),
    ("coach_house", 16),
    ("gambling_den", 8),
    ("gambling_den", 12),
    ("grand_casino", 16),
    ("academy", 12),
    ("academy", 16),
    ("observatory", 8),
    ("flower_shop", 8),
    ("flower_shop", 12),
    # cathedral 补 w8 小礼拜堂档（CATHEDRAL_TIERS 有 8/12/16 三档，此前只烘了 16）
    ("cathedral", 8),
]

#: glow 卡里当作"自发光窗/火"的材质名（其余一律压成纯黑，加色叠加下不可见）
GLOW_MATS = {"glass", "glass_win", "lamp", "fire", "ember", "candle", "torch"}

# ------------------------------------------------------------------ 夜档灯位
# 创始人 2026-09-15：月光在 Blender 里烘亮——每卡多烘一张 <卡>_night.png：
# 亮冷蓝月亮方向光 + 低强度夜环境，窗/火自发光直接烘进夜版 albedo
# （运行时 card.gdshader 的 night_mix 切换；夜窗=暖白"亮着灯"，不是整块橙）。
DAY_BG_COLOR, DAY_BG_STRENGTH = (0.62, 0.70, 0.82), 0.60
# 夜环境给足深蓝底光（阴影面不死黑）；月亮从**正面高角度**斜打（z 转速与白天的
# 主光同 hemisphere）——首版 z=+142 从背面打光，正立面全在阴影里，夜里依然一坨黑
# （创始人判"一塌糊涂"的主因）。
NIGHT_BG_COLOR, NIGHT_BG_STRENGTH = (0.09, 0.12, 0.22), 0.55
DAY_KEY = {"energy": 3.3, "color": (1.0, 0.95, 0.85), "rot": (40, 0, -38), "angle": 3.0}
NIGHT_KEY = {"energy": 2.2, "color": (0.62, 0.74, 1.0), "rot": (55, 0, -75), "angle": 8.0}
DAY_FILL_ENERGY, NIGHT_FILL_ENERGY = 0.15, 0.06
#: 夜版 albedo 里叠半透明发光的材质族（与各卡库 GLOW_MATS 同源，窗/火分色）。
#: FAC=发光占比（Mix Shader）：原材质占 (1-FAC) 透出来——灯笼罩架那种"透"
#: 靠几何遮挡，平面窗玻璃要靠 FAC 压低发光、留出原材质的月光反光。
NIGHT_WIN_MATS = {"glass", "glass_win", "glazing_win", "clear_glass"}
NIGHT_WIN_RGB, NIGHT_WIN_FAC = (1.0, 0.87, 0.68), 0.65
NIGHT_FIRE_MATS = {"fire", "ember", "flat_fire", "candle", "torch", "lamp"}
NIGHT_FIRE_RGB, NIGHT_FIRE_FAC = (1.0, 0.62, 0.30), 0.85
NIGHT_CRYSTAL_MATS = {"crystal_a", "crystal_b"}
NIGHT_CRYSTAL_RGB, NIGHT_CRYSTAL_FAC = (0.62, 0.88, 1.0), 0.7

# setup_world() 填充：昼/夜灯位切换要改的三个对象引用
_WORLD_BG = None
_SUN_KEY = None
_SUN_FILL = None

#: 增量烘焙过滤：设 BAKE_ONLY=council_hall,cathedral（逗号分隔 def 名）时只装配并
#: 烘这些 def（STREET 其余条目跳过）；未设/空 = 全量，默认行为不变。增量模式下
#: cards.json 做**合并写回**（旧条目保留原序、同名覆盖、新卡追加尾部），并跳过
#: glb / build_report 这两个全量产物（避免被增量批次覆盖）。
BAKE_ONLY = [s.strip() for s in os.environ.get("BAKE_ONLY", "").split(",")
             if s.strip()]


# ------------------------------------------------------------------ 场景

def clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def setup_world():
    """天空环境光 + 太阳（沿用 probe_buildings 的 §8.4 定标，不自创）。"""
    sc = bpy.context.scene
    try:
        sc.render.engine = "BLENDER_EEVEE_NEXT"
    except Exception:
        sc.render.engine = "BLENDER_EEVEE"
    sc.render.film_transparent = True
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_mode = "RGBA"
    sc.view_settings.view_transform = "Standard"
    sc.view_settings.look = "None"
    for attr, val in (("taa_render_samples", 48), ("use_gtao", True)):
        try:
            setattr(sc.eevee, attr, val)
        except Exception:
            pass
    w = bpy.data.worlds.new("W")
    sc.world = w
    w.use_nodes = True
    bg = w.node_tree.nodes.get("Background")
    if bg is None:
        bg = w.node_tree.nodes.new("ShaderNodeBackground")
    bg.inputs[0].default_value = (0.62, 0.70, 0.82, 1.0)
    bg.inputs[1].default_value = 0.60

    def sun(name, energy, rot, angle=3.0, color=(1.0, 0.95, 0.85)):
        d = bpy.data.lights.new(name, "SUN")
        d.energy = energy
        d.angle = math.radians(angle)
        d.color = color
        ob = bpy.data.objects.new(name, d)
        ob.rotation_euler = tuple(math.radians(a) for a in rot)
        sc.collection.objects.link(ob)
        return ob

    sun("key", 3.3, (40, 0, -38))
    sun("fill", 0.15, (55, 0, 128), 20.0, (0.85, 0.90, 1.0))

    global _WORLD_BG, _SUN_KEY, _SUN_FILL
    _WORLD_BG = bg
    _SUN_KEY = bpy.data.objects["key"]
    _SUN_FILL = bpy.data.objects["fill"]


def set_night(on):
    """昼/夜灯位切换：夜烘期间切入，烘完切回（日档产物逐位不变）。"""
    day = on is False
    k_bg = DAY_BG_COLOR if day else NIGHT_BG_COLOR
    _WORLD_BG.inputs[0].default_value = (k_bg[0], k_bg[1], k_bg[2], 1.0)
    _WORLD_BG.inputs[1].default_value = DAY_BG_STRENGTH if day else NIGHT_BG_STRENGTH
    key = DAY_KEY if day else NIGHT_KEY
    _SUN_KEY.data.energy = key["energy"]
    _SUN_KEY.data.color = key["color"]
    _SUN_KEY.data.angle = math.radians(key["angle"])
    _SUN_KEY.rotation_euler = tuple(math.radians(a) for a in key["rot"])
    _SUN_FILL.data.energy = DAY_FILL_ENERGY if day else NIGHT_FILL_ENERGY


def _night_glow_mat(orig, rgb, fac):
    """夜版发光材质（创始人 2026-09-15：**半透明发光**——原材质要透出来）。

    copy 原材质（连节点树）后在 Material Output 前插一枚 Mix Shader：
    原表面占 (1-fac)、Emission 占 fac——**字面意义的半透明叠加**，原材质的
    月光反光/明暗按比例保留。不用 Add 加法（原材质夜里很暗，加法会把
    原材质淹没成平光块——实测窗子烘出来看不出透）。copy() 不删原件，
    materials.py 的材质缓存引用不受影响。
    """
    m = orig.copy()
    m.name = "__nightglow_" + orig.name
    nt = m.node_tree
    out = None
    for n in nt.nodes:
        if n.type == "OUTPUT_MATERIAL":
            out = n
            break
    if out is None:
        return m
    emi = nt.nodes.new("ShaderNodeEmission")
    emi.inputs["Color"].default_value = (rgb[0], rgb[1], rgb[2], 1.0)
    emi.inputs["Strength"].default_value = 1.0
    mix = nt.nodes.new("ShaderNodeMixShader")
    mix.inputs["Fac"].default_value = fac
    if out.inputs["Surface"].is_linked:
        nt.links.new(out.inputs["Surface"].links[0].from_socket, mix.inputs[1])
    nt.links.new(emi.outputs["Emission"], mix.inputs[2])
    nt.links.new(mix.outputs["Shader"], out.inputs["Surface"])
    return m


def ground_footprint(ob, z_max=8.0):
    """贴地顶点的 x/y 范围（世界单位）——真实地面占地，排除出檐/顶棚等高处悬挑
    （创始人 2026-09-15：烘卡时把建筑地面占地范围一起输出）。
    阈值是**相对**的：z ≤ 对象自身最低点 + z_max——整楼按最低点贴地后，基座环
    若有台阶/坡度，绝对阈值会把大部分墙脚顶点排除在外、量出扁片占地
    （创始人 2026-09-15 指认"紫色扁片"后的修正）。"""
    mw = ob.matrix_world
    zs = []
    for v in ob.data.vertices:
        zs.append((mw @ v.co).z)
    if not zs:
        m = B.measure(ob)
        return m["x"], m["y"]
    z_floor = min(zs) + z_max
    xs, ys = [], []
    for v in ob.data.vertices:
        p = mw @ v.co
        if p.z <= z_floor:
            xs.append(p.x)
            ys.append(p.y)
    if not xs:
        m = B.measure(ob)
        return m["x"], m["y"]
    return (min(xs), max(xs)), (min(ys), max(ys))


def footprint_cells(ob):
    """占地 [宽格, 深格]（1 格 = 32 世界单位）。"""
    (x0, x1), (y0, y1) = ground_footprint(ob)
    return [round((x1 - x0) / 32.0, 2), round((y1 - y0) / 32.0, 2)]


def footprint_full(ob):
    """全模型包围盒 [宽格, 深格]（不过滤高度——含屋顶出檐的整楼地面占用）。
    引擎紫占地带/碰撞的深度口径（创始人 2026-09-15：紫色不能是扁片，
    墙脚贴地实测对大屋顶建筑只是窄条）。注意 B.measure 返回的是 (min,max)
    元组对而非跨度，直接自算最稳。"""
    mw = ob.matrix_world
    xs, ys = [], []
    for v in ob.data.vertices:
        pt = mw @ v.co
        xs.append(pt.x)
        ys.append(pt.y)
    if not xs:
        m = B.measure(ob)
        return [round((m["x"][1] - m["x"][0]) / 32.0, 2),
                round((m["y"][1] - m["y"][0]) / 32.0, 2)]
    return [round((max(xs) - min(xs)) / 32.0, 2),
            round((max(ys) - min(ys)) / 32.0, 2)]


def footprint_off(ob):
    """占地原点偏移 [dx格, dz格]（1 格 = 32 世界单位），footprint 的配套字段。

    dx = 占地包围盒x中心 − 剪影包围盒x中心：相对**卡面（剪影）中心**——引擎把
    图片中心钉在槽位 x。剪影与取景（bake_cards 的 pts/us）同源：同一
    B.shape_points(ob, skip_ground=False) + B.cam_axes(YAW, TILT) 投影。
    dz = 墙脚基线y − 占地包围盒y中心：相对**墙脚基线**——引擎卡底贴地落位把该
    线钉在落位 z（_card_base_cut 扫到的卡可视底边内容行），正 dz 朝相机/前方。
    基线 y 取卡可视底边内容行的地面等效值：地面点 v = y·sin t，故基线 y =
    min(v)/sin(tilt)（与取景同源，典型建筑 = 前墙基线 y）。
    兜底（ground_footprint 走 B.measure）同样出数；无剪影/异常回退 [0.0, 0.0]
    （引擎侧退化为居中 + 从基线向后，与旧 JSON 行为一致）。
    """
    try:
        (x0, x1), (y0, y1) = ground_footprint(ob)
        right, up = B.cam_axes(YAW, TILT)
        pts = B.shape_points(ob, skip_ground=False)
        if not pts:
            return [0.0, 0.0]
        us = [p.dot(right) for p in pts]
        vs = [p.dot(up) for p in pts]
        base_y = min(vs) / math.sin(math.radians(TILT))
        dx = (x0 + x1) * 0.5 - (min(us) + max(us)) * 0.5
        dz = base_y - (y0 + y1) * 0.5
        return [round(dx / 32.0, 2), round(dz / 32.0, 2)]
    except Exception:
        return [0.0, 0.0]


def make_camera():
    d = bpy.data.cameras.new("cam")
    d.type = "ORTHO"
    d.clip_start = 1.0
    d.clip_end = 40000.0
    ob = bpy.data.objects.new("cam", d)
    bpy.context.scene.collection.objects.link(ob)
    bpy.context.scene.camera = ob
    return ob


# ------------------------------------------------------------------ 装配

def _strip_shadow_faces(ob):
    """删除接地阴影踏板面片（flat_shadow_*）：台基删除+整楼下沉后它落到地面以下，
    读作卡底脏带；游戏的接地感由引擎 building_shadow 自绘承担。"""
    me = ob.data
    kill = {i for i, m in enumerate(me.materials)
            if m is not None and "shadow" in m.name}
    if not kill:
        return
    # Blender 5.2 的 Mesh.polygons 无 remove()，删面走 bmesh
    import bmesh
    bm = bmesh.new()
    bm.from_mesh(me)
    dead = [f for f in bm.faces if f.material_index in kill]
    if dead:
        bmesh.ops.delete(bm, geom=dead, context="FACES")
    bm.to_mesh(me)
    bm.free()
    me.update()


def _ground_shift(ob):
    """本体（非阴影面片）最低点落到 z=0——台基不生成后墙脚悬在 plinth_h 高度，
    整楼按实测最低点（墙脚/台阶石）下沉贴地。（非阴影顶点集合只算一遍——
    放在逐顶点循环里是 O(顶点×面数)，实测直接把整轮烘焙卡死。）"""
    me = ob.data
    mw = ob.matrix_world
    kill = {i for i, m in enumerate(me.materials)
            if m is not None and "shadow" in m.name}
    zs = [(mw @ me.vertices[vi].co).z for vi in _verts_of(me, kill)]
    if zs:
        ob.location.z -= min(zs)


def _verts_of(me, kill_mats):
    """非阴影面片用到的顶点索引集合。"""
    vs = set()
    for p in me.polygons:
        if p.material_index in kill_mats:
            continue
        vs.update(p.vertices)
    return vs


def layout():
    """沿 X 摆开一条街；返回 [{def,cells,obj,spec,origin}]。"""
    built = []
    cursor = 0.0
    for (name, wc) in STREET:
        if BAKE_ONLY and name not in BAKE_ONLY:
            continue
        if name not in B.ASSEMBLERS:
            print("[SKIP] 无装配器: %s" % name)
            continue
        ob, spec = B.ASSEMBLERS[name](wc)
        _strip_shadow_faces(ob)
        _ground_shift(ob)
        bpy.context.view_layer.update()
        m = B.measure(ob)
        width = m["x"][1] - m["x"][0]
        bx = cursor + width / 2.0
        ob.location.x = bx - (m["x"][0] + m["x"][1]) / 2.0
        bpy.context.view_layer.update()
        built.append({"def": name, "cells": wc, "obj": ob, "spec": spec,
                      "origin": Vector((bx, 0.0, 0.0))})
        cursor = bx + width / 2.0 + 4.0
    return built


# ------------------------------------------------------------------ 烘焙

def _flat_mat(name, color, emission=False, strength=0.0):
    m = bpy.data.materials.new("bake_" + name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes.get("Principled BSDF")
    if bsdf is None:
        for n in m.node_tree.nodes:
            if n.type == "BSDF_PRINCIPLED":
                bsdf = n
    bsdf.inputs["Base Color"].default_value = (color[0], color[1], color[2], 1.0)
    bsdf.inputs["Roughness"].default_value = 0.85
    if emission:
        for slot in ("Emission Color", "Emission"):
            if slot in bsdf.inputs:
                bsdf.inputs[slot].default_value = (1.0, 1.0, 1.0, 1.0)
                break
        if "Emission Strength" in bsdf.inputs:
            bsdf.inputs["Emission Strength"].default_value = strength
    return m


def bake_cards(entry, cam):
    """把单栋建筑烘成两张透明底卡（albedo / glow），返回卡的元数据。"""
    ob = entry["obj"]
    origin = entry["origin"]
    right, up = B.cam_axes(YAW, TILT)
    fwd = -(right.cross(up))

    pts = B.shape_points(ob, skip_ground=False)
    us = [p.dot(right) for p in pts]
    vs = [p.dot(up) for p in pts]
    u0, u1 = min(us) - PAD, max(us) + PAD
    v0, v1 = min(vs) - PAD, max(vs) + PAD
    w, h = (u1 - u0), (v1 - v0)
    k = min(1.0, RES_MAX / float(max(w, h) * ZOOM))
    rx = max(64, int(round(w * ZOOM * k)))
    ry = max(64, int(round(h * ZOOM * k)))

    # 画面中心对应的世界点（先投影再沿屏幕轴平移回来，见 probe_buildings.shoot_fit）
    cu, cv = (u0 + u1) / 2.0, (v0 + v1) / 2.0
    ref = origin
    anchor = ref + right * (cu - ref.dot(right)) + up * (cv - ref.dot(up))

    cam.location = tuple(anchor - fwd * 9000.0)
    cam.rotation_euler = (math.radians(90.0 - TILT), 0.0, math.radians(YAW))
    cam.data.ortho_scale = max(w, h)

    sc = bpy.context.scene
    sc.render.resolution_x = rx
    sc.render.resolution_y = ry
    sc.render.resolution_percentage = 100

    # 只留本体可见
    saved_hide = {}
    for other in bpy.data.objects:
        if other.type == "MESH" and other is not ob:
            saved_hide[other] = other.hide_render
            other.hide_render = True

    tag = "%s_w%d" % (entry["def"], entry["cells"])
    albedo_png = os.path.join(CARD_DIR, tag + ".png")
    glow_png = os.path.join(CARD_DIR, tag + "_glow.png")

    sc.render.filepath = albedo_png
    bpy.ops.render.render(write_still=True)

    # -- glow 层：自发光材质留白，其余压黑（加色叠加下黑=透明）--
    slots = [s.material for s in ob.material_slots]
    glow_repl = []
    hit = []
    for mat in slots:
        nm = mat.name if mat else ""
        if nm in GLOW_MATS:
            glow_repl.append(_flat_mat(nm + "_glow", (0.02, 0.02, 0.02), True, 6.0))
            hit.append(nm)
        else:
            glow_repl.append(_flat_mat(nm + "_dark", (0.0, 0.0, 0.0)))
    for i, s in enumerate(ob.material_slots):
        s.material = glow_repl[i]
    sc.render.filepath = glow_png
    bpy.ops.render.render(write_still=True)
    for i, s in enumerate(ob.material_slots):
        s.material = slots[i]
    for m in glow_repl:
        bpy.data.materials.remove(m)

    # -- 夜档层：月夜灯位 + 窗/火自发光烘进 albedo（创始人：月光在 Blender 里烘亮）--
    night_png = os.path.join(CARD_DIR, tag + "_night.png")
    set_night(True)
    night_repl = []
    for mat in slots:
        nm = mat.name if mat else ""
        if nm in NIGHT_WIN_MATS:
            night_repl.append(_night_glow_mat(mat, NIGHT_WIN_RGB, NIGHT_WIN_FAC))
        elif nm in NIGHT_FIRE_MATS:
            night_repl.append(_night_glow_mat(mat, NIGHT_FIRE_RGB, NIGHT_FIRE_FAC))
        elif nm in NIGHT_CRYSTAL_MATS:
            night_repl.append(_night_glow_mat(mat, NIGHT_CRYSTAL_RGB, NIGHT_CRYSTAL_FAC))
        else:
            night_repl.append(None)
    for i, s in enumerate(ob.material_slots):
        if night_repl[i] is not None:
            s.material = night_repl[i]
    sc.render.filepath = night_png
    bpy.ops.render.render(write_still=True)
    for i, s in enumerate(ob.material_slots):
        if night_repl[i] is not None:
            s.material = slots[i]
    for m in [x for x in night_repl if x is not None]:
        bpy.data.materials.remove(m)
    set_night(False)

    for other, hv in saved_hide.items():
        other.hide_render = hv

    return {
        "card": tag, "def": entry["def"], "cells": entry["cells"],
        "px": [rx, ry], "zoom": rx / w if w > 0 else ZOOM,
        "units": [rx / (rx / w) if w > 0 else w, ry / (rx / w) if w > 0 else h],
        "anchor": [anchor.x, anchor.y, anchor.z],
        "footprint": footprint_cells(ob),   # 墙脚贴地占地 [宽格, 深格]（相对阈值贴地顶点）
        "footprint_full": footprint_full(ob),   # 全模型占地 [宽格, 深格]（含屋顶出檐——碰撞深度口径）
        # 占地原点 [dx格, dz格]：dx 相对卡面（剪影）中心（引擎把图片中心钉在槽位 x）；
        # dz 相对墙脚基线（引擎把该线钉在落位 z），正 dz 朝相机
        "footprint_off": footprint_off(ob),
        "glow_mats": sorted(set(hit)),
    }


# ------------------------------------------------------------------ glb

def export_glb(built):
    objs = [e["obj"] for e in built]
    for ob in bpy.data.objects:
        ob.hide_render = False
    for ob in objs:
        ob.scale = (SCALE, SCALE, SCALE)
    bpy.context.view_layer.update()
    bpy.ops.object.select_all(action="DESELECT")
    for ob in objs:
        ob.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)

    kw = dict(filepath=GLB_PATH, export_format="GLB", use_selection=True,
              export_apply=True, export_yup=True)
    try:
        bpy.ops.export_scene.gltf(export_materials="EXPORT", **kw)
    except TypeError:
        bpy.ops.export_scene.gltf(**kw)


def report(built, cards):
    per = {}
    tris_total = 0
    mats = set()
    for e in built:
        me = e["obj"].data
        me.calc_loop_triangles()
        tri = len(me.loop_triangles)
        tris_total += tri
        for m in me.materials:
            if m:
                mats.add(m.name)
        m = B.measure(e["obj"])
        per[e["def"] + "_w%d" % e["cells"]] = {
            "tris": tri, "verts": len(me.vertices), "mat_slots": len(me.materials),
            "w": round(m["x"][1] - m["x"][0], 1), "h": round(m["z"][1] - m["z"][0], 1),
            "d": round(m["y"][1] - m["y"][0], 1),
        }
    return {"buildings": per, "tris_total": tris_total,
            "unique_materials": sorted(mats), "unique_material_count": len(mats),
            "glb_bytes": os.path.getsize(GLB_PATH) if os.path.exists(GLB_PATH) else 0,
            "cards": cards}


def load_cards(path):
    """读旧 cards.json（缺失/损坏返回空列表，增量合并不因旧档异常而中断）。"""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, list) else []
    except Exception:
        return []


def merge_cards(new_cards):
    """增量合并：旧 cards.json 条目保留原序（同名去重保首个），本批同名覆盖、
    新卡按 STREET 序追加尾部。全量模式不经过此函数，写盘行为不变。"""
    old = load_cards(os.path.join(OUT_DIR, "cards.json"))
    by_card = {c["card"]: c for c in new_cards}
    out, seen = [], set()
    for c in old:
        k = c.get("card")
        if k is None or k in seen:
            continue
        out.append(by_card.get(k, c))
        seen.add(k)
    for c in new_cards:
        if c["card"] not in seen:
            out.append(c)
            seen.add(c["card"])
    return out


def main():
    clear()
    setup_world()
    cam = make_camera()
    os.makedirs(CARD_DIR, exist_ok=True)

    built = layout()
    print("[proto] 装配 %d 栋" % len(built))

    cards = []
    for e in built:
        c = bake_cards(e, cam)
        cards.append(c)
        print("[card] %-18s %4dx%-5d anchor=(%.1f,%.1f,%.1f) glow=%s"
              % (c["card"], c["px"][0], c["px"][1], c["anchor"][0], c["anchor"][1],
                 c["anchor"][2], ",".join(c["glow_mats"]) or "-"))

    if BAKE_ONLY:
        # 增量模式：只合并写回 cards.json，不碰 glb / build_report 全量产物
        merged = merge_cards(cards)
        with open(os.path.join(OUT_DIR, "cards.json"), "w", encoding="utf-8") as f:
            json.dump(merged, f, ensure_ascii=False, indent=1)
        print("[proto] BAKE_ONLY=(%s) 本批 %d 卡，合并后共 %d 条 -> cards.json"
              % (",".join(BAKE_ONLY), len(cards), len(merged)))
    else:
        export_glb(built)
        rep = report(built, cards)
        with open(os.path.join(OUT_DIR, "cards.json"), "w", encoding="utf-8") as f:
            json.dump(cards, f, ensure_ascii=False, indent=1)
        with open(os.path.join(OUT_DIR, "build_report.json"), "w",
                  encoding="utf-8") as f:
            json.dump(rep, f, ensure_ascii=False, indent=1)

        print("\n=== 报表 ===")
        print("glb=%s  %.2f MB" % (GLB_PATH, rep["glb_bytes"] / 1048576.0))
        print("三角面合计 %d；唯一材质 %d 个" % (rep["tris_total"],
                                                rep["unique_material_count"]))
        for k, v in rep["buildings"].items():
            print("  %-16s tris=%-6d verts=%-6d slots=%-3d  %.0f x %.0f x %.0f px"
                  % (k, v["tris"], v["verts"], v["mat_slots"], v["w"], v["h"], v["d"]))
        print("材质名清单:", ", ".join(rep["unique_materials"]))
    print("PROTO_OK")


main()
