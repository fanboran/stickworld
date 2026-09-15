# -*- coding: utf-8 -*-
"""bake_nature.py —— HD-2D 原型：把自然物库（16 类树/矿/石）烘成透明底卡。

只做一件事：**只读导入** `tools/blender_buildings/{buildings,nature}.py`（不改它们），
按与 `bake_props.py` 完全同一套相机口径（yaw=0° / tilt=26° / 正交 / 2x / 透明底）
把自然物逐件烘成卡，供 HD-2D 街景两侧的"野外感"摆位用（树/矿/石）。

跑法（固定命令）::

    "F:/SteamLibrary/steamapps/common/Blender/blender.exe" -b --factory-startup \
        -P stick-world/tests/dev/proto_hd2d/bake_nature.py

产物（stick-world/temp/proto_hd2d/nature/）::

    <name>.png / <name>_glow.png    自然物卡（albedo + 自发光层）
    <name>_night.png                夜版卡（月夜灯位 + 水晶自发光，night_mix 切换用）
    nature.json                      px / units / anchor / glow_mats

坐标与尺度口径与建筑卡一致：Godot 单位 = 1 格 = 32 Blender 单位；
Blender (x, y, z) -> Godot (x, z, -y) / 32。自然物**不乘道具的 GAME_SCALE**——
树/矿按真实尺寸（NOMINAL 米制）就是对的口径，灌木/蘑菇贴近火柴人身高。
"""

import json
import math
import os
import sys

import bpy
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
# stick-world/tests/dev/proto_hd2d -> 上溯 4 级到仓库根
REPO = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
TOOLS = os.path.join(REPO, "tools", "blender_buildings")
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

import buildings as B  # noqa: E402  只读导入
import nature as N  # noqa: E402  只读导入（import 时已注入材质解析器）

OUT_DIR = os.path.join(REPO, "stick-world", "temp", "proto_hd2d")
CARD_DIR = os.path.join(OUT_DIR, "nature")

YAW = 0.0
# 26°：与 proto_hd2d 场景 TILT_DEG / 建筑·道具卡烘焙视角同步
TILT = 26.0
ZOOM = 2.0
PAD = 8.0
# 树高 10~15m（760~1150 单位），卡高可达 2300px——上限放到 2048 保细节
RES_MAX = 2048

# 水晶簇的 crystal_a/crystal_b 是本层唯一自发光材质（nature.MAT_SPEC → crystal key）
GLOW_MATS = {"crystal_a", "crystal_b"}

# ------------------------------------------------------------------ 夜档灯位
# 创始人 2026-09-15：月光在 Blender 里烘亮——每件自然物多烘一张 <名>_night.png：
# 亮冷蓝月亮方向光 + 低强度夜环境，水晶自发光烘进夜版 albedo
# （运行时 card.gdshader 的 night_mix 切换；树/矿/水晶夜里不再全黑）。
DAY_BG_COLOR, DAY_BG_STRENGTH = (0.62, 0.70, 0.82), 0.60
# 夜环境给足深蓝底光（阴影面不死黑）；月亮从**正面高角度**斜打（同 blender_proto
# 首版 z=+142 背光导致立面全黑的教训）。
NIGHT_BG_COLOR, NIGHT_BG_STRENGTH = (0.09, 0.12, 0.22), 0.55
DAY_KEY = {"energy": 3.3, "color": (1.0, 0.95, 0.85), "rot": (40, 0, -38), "angle": 3.0}
NIGHT_KEY = {"energy": 2.2, "color": (0.62, 0.74, 1.0), "rot": (55, 0, -75), "angle": 8.0}
DAY_FILL_ENERGY, NIGHT_FILL_ENERGY = 0.15, 0.06
NIGHT_WIN_MATS = set()
NIGHT_FIRE_MATS = set()
NIGHT_CRYSTAL_MATS = {"crystal_a", "crystal_b"}
NIGHT_CRYSTAL_RGB, NIGHT_CRYSTAL_FAC = (0.62, 0.88, 1.0), 0.7

# setup_world() 填充：昼/夜灯位切换要改的三个对象引用
_WORLD_BG = None
_SUN_KEY = None
_SUN_FILL = None

#: 街景两侧要用的自然物（点名烘；ore_band 是 10m 长条分布件、非单体，不进本批）
NATURE = [
    "broadleaf", "broadleaf_tall", "conifer", "dead_tree", "stump",
    "bush", "reeds", "grass_clump", "mushrooms",
    "boulder", "rubble",
    "iron_outcrop", "copper_vein", "gold_vein", "crystal_cluster",
]
#: 挡人的种类（树/巨岩/矿露头/水晶）；矮草花蘑菇碎石不挡
SOLID = {
    "broadleaf", "broadleaf_tall", "conifer", "dead_tree",
    "boulder", "iron_outcrop", "copper_vein", "gold_vein", "crystal_cluster",
}


# ------------------------------------------------------------------ 场景

def clear():
    """与 probe_nature.clear() 同一套（§六 踩坑：缓存清理 + 材质重装）。"""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    B._CACHE.clear()
    try:
        import materials as M
        M.reset_cache()
    except Exception:
        pass
    N.install_materials()


def setup_world():
    """与 bake_props.setup_world 同口径（§8.4 定标，不自创）。"""
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

    copy 原材质后在 Material Output 前插 Mix Shader：原表面占 (1-fac)、
    Emission 占 fac（字面半透明；Add 加法会把暗原材质淹没成平光块）。
    copy() 不删原件，materials.py 的材质缓存引用不受影响。
    """
    m = orig.copy()
    m.name = "__nnightglow_" + orig.name
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
    （创始人 2026-09-15：烘卡时把建筑地面占地范围一起输出）。z_max 以下才算地脚。"""
    mw = ob.matrix_world
    xs, ys = [], []
    for v in ob.data.vertices:
        p = mw @ v.co
        if p.z <= z_max:
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

def make_camera():
    d = bpy.data.cameras.new("cam")
    d.type = "ORTHO"
    d.clip_start = 1.0
    d.clip_end = 40000.0
    ob = bpy.data.objects.new("cam", d)
    bpy.context.scene.collection.objects.link(ob)
    bpy.context.scene.camera = ob
    return ob


def _flat_mat(name, color, emissive=False, strength=0.0):
    """glow 层纯色材质（一律 new() 不删——见 bake_props._flat_mat 的缓存失效坑）。"""
    m = bpy.data.materials.new("__nglow_" + name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes.get("Principled BSDF")
    if bsdf is None:
        return m
    bsdf.inputs["Base Color"].default_value = (color[0], color[1], color[2], 1.0)
    if "Emission Color" in bsdf.inputs:
        bsdf.inputs["Emission Color"].default_value = (color[0], color[1],
                                                       color[2], 1.0)
        bsdf.inputs["Emission Strength"].default_value = strength if emissive else 0.0
    for key in ("Roughness", "Metallic", "Specular IOR Level"):
        if key in bsdf.inputs:
            bsdf.inputs[key].default_value = 1.0 if key == "Roughness" else 0.0
    return m


def _strip_shadow_faces(ob):
    """删除贴地阴影踏板面片（shadow_near/mid/far）：半透明椭圆碟烘进透明底卡，
    alpha 硬切（alpha_cut=0.4）后会在树脚下留一圈白雾（实测踩到）；游戏侧的
    接地感由卡内接触暗部 + 地面承担。判定与 buildings.shape_points 同款前缀。"""
    me = ob.data
    kill = {i for i, m in enumerate(me.materials)
            if m is not None and m.name.startswith("shadow_")}
    if not kill:
        return
    for p in list(me.polygons):
        if p.material_index in kill:
            me.polygons.remove(p.index)
    me.update()


def build_nature(kind):
    """按 place() 统一入口装配单件（seed 固定，保证卡跨进程确定）。"""
    b = B.Builder("nature_" + kind)
    if kind not in N.TABLE:
        return None
    try:
        N.place(b, kind, x=0.0, y=0.0, z=0.0, seed=7)
    except TypeError as e:
        print("[nature] 跳过（签名不符）: %s (%s)" % (kind, e))
        return None
    ob = b.to_object()
    _strip_shadow_faces(ob)
    bpy.context.view_layer.update()
    return ob


def bake_card(ob, cam, name):
    """与 bake_props.bake_card 同一套：屏幕包围盒 -> 正交相机 -> 透明底两层。"""
    right, up = B.cam_axes(YAW, TILT)
    fwd = -(right.cross(up))
    pts = B.shape_points(ob, skip_ground=False)
    us = [p.dot(right) for p in pts]
    vs = [p.dot(up) for p in pts]
    u0, u1 = min(us) - PAD, max(us) + PAD
    v0, v1 = min(vs) - PAD, max(vs) + PAD
    w, h = (u1 - u0), (v1 - v0)
    k = min(1.0, RES_MAX / float(max(w, h) * ZOOM))
    rx = max(32, int(round(w * ZOOM * k)))
    ry = max(32, int(round(h * ZOOM * k)))
    cu, cv = (u0 + u1) / 2.0, (v0 + v1) / 2.0
    ref = Vector((0.0, 0.0, 0.0))
    anchor = ref + right * (cu - ref.dot(right)) + up * (cv - ref.dot(up))

    cam.location = tuple(anchor - fwd * 9000.0)
    cam.rotation_euler = (math.radians(90.0 - TILT), 0.0, math.radians(YAW))
    cam.data.ortho_scale = max(w, h)

    sc = bpy.context.scene
    sc.render.resolution_x = rx
    sc.render.resolution_y = ry
    sc.render.resolution_percentage = 100

    saved_hide = {}
    for other in bpy.data.objects:
        if other.type == "MESH" and other is not ob:
            saved_hide[other] = other.hide_render
            other.hide_render = True

    albedo_png = os.path.join(CARD_DIR, name + ".png")
    glow_png = os.path.join(CARD_DIR, name + "_glow.png")
    sc.render.filepath = albedo_png
    bpy.ops.render.render(write_still=True)

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

    # -- 夜档层：月夜灯位 + 水晶自发光烘进 albedo（创始人：月光在 Blender 里烘亮）--
    night_png = os.path.join(CARD_DIR, name + "_night.png")
    set_night(True)
    night_repl = []
    for mat in slots:
        nm = mat.name if mat else ""
        if nm in NIGHT_CRYSTAL_MATS:
            night_repl.append(_night_glow_mat(mat, NIGHT_CRYSTAL_RGB, NIGHT_CRYSTAL_FAC))
        elif nm in NIGHT_WIN_MATS:
            night_repl.append(_night_glow_mat(mat, (1.0, 0.87, 0.68), 0.65))
        elif nm in NIGHT_FIRE_MATS:
            night_repl.append(_night_glow_mat(mat, (1.0, 0.62, 0.30), 0.85))
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
    set_night(False)

    for other, hv in saved_hide.items():
        other.hide_render = hv

    return {
        "card": name, "def": name,
        "px": [rx, ry], "zoom": rx / w if w > 0 else ZOOM,
        "units": [rx / (rx / w) if w > 0 else w, ry / (rx / w) if w > 0 else h],
        "anchor": [anchor.x, anchor.y, anchor.z],
        "footprint": footprint_cells(ob),   # 真实地面占地 [宽格, 深格]（贴地顶点）
        "solid": name in SOLID,
        "glow_mats": sorted(set(hit)),
    }


def main():
    clear()
    setup_world()
    cam = make_camera()
    os.makedirs(CARD_DIR, exist_ok=True)

    cards = []
    for kind in NATURE:
        try:
            ob = build_nature(kind)
        except Exception as e:          # noqa: BLE001 单件失败不该中断整轮
            print("[nature] 跳过（装配/烘焙异常）: %s (%s)" % (kind, e))
            ob = None
        if ob is None:
            print("[nature] 跳过（库中无此件或签名不符）: " + kind)
            continue
        c = bake_card(ob, cam, kind)
        cards.append(c)
        print("[nature] %-16s %4dx%-5d units=(%.0f,%.0f) anchor=(%.1f,%.1f,%.1f) solid=%s glow=%s"
              % (kind, c["px"][0], c["px"][1], c["units"][0], c["units"][1],
                 c["anchor"][0], c["anchor"][1], c["anchor"][2], c["solid"],
                 ",".join(c["glow_mats"]) or "-"))
        me = ob.data
        bpy.data.objects.remove(ob, do_unlink=True)
        bpy.data.meshes.remove(me)

    with open(os.path.join(OUT_DIR, "nature.json"), "w", encoding="utf-8") as f:
        json.dump(cards, f, ensure_ascii=False, indent=1)
    print("[nature] 共 %d 件 -> %s" % (len(cards), os.path.join(OUT_DIR, "nature.json")))
    print("NATURE_OK")


main()
