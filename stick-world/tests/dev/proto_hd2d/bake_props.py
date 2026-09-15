# -*- coding: utf-8 -*-
"""bake_props.py —— HD-2D 原型：把现有道具库（94+ 件 3D 道具）烘成透明底卡。

只做一件事：**只读导入** `tools/blender_buildings/{buildings,props}.py`（不改它们），
按与 `tests/dev/proto_25d/blender_proto.py` 完全同一套相机口径（yaw=0° / tilt=20° /
正交 / 2x / 透明底）把道具逐件烘成卡，供 HD-2D 街景的空当填充用。

跑法（固定命令）::

    "F:/SteamLibrary/steamapps/common/Blender/blender.exe" -b --factory-startup \
        -P stick-world/tests/dev/proto_hd2d/bake_props.py

产物（stick-world/temp/proto_hd2d/props/）::

    <name>.png / <name>_glow.png    道具卡（albedo + 自发光层）
    props.json                       px / units / anchor / glow_mats

坐标与尺度口径与建筑卡一致：Godot 单位 = 1 格 = 32 Blender 单位；
Blender (x, y, z) -> Godot (x, z, -y) / 32。道具按 `props.GAME_SCALE`（×1.45）挂载，
与 `props.dress()` 同口径 —— 不这么缩放，道具会比火柴人还大。
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
import props as P  # noqa: E402  只读导入

OUT_DIR = os.path.join(REPO, "stick-world", "temp", "proto_hd2d")
CARD_DIR = os.path.join(OUT_DIR, "props")

YAW = 0.0
# 26°：与 proto_hd2d 场景 TILT_DEG / 建筑卡烘焙视角同步（2026-09-14）
TILT = 26.0
ZOOM = 2.0
PAD = 6.0
RES_MAX = 1024

GLOW_MATS = {"glass", "glass_win", "lamp", "fire", "ember", "candle", "torch",
             "clear_glass",
             # materials.py 实名（2026-09-14 实测）：六轮街具灯头走 props.clear_glass()
             # -> 罩子注册名 glazing_win；灯芯 "fire" 不在 materials 注册表、走
             # _flat_pbr 回退后对象名带前缀 = flat_fire。不含这两名则灯具 glow 全空。
             "glazing_win", "flat_fire"}

#: 街景空当要用的道具（点名烘，不做全库 —— 每件两次渲染）
PROPS = [
    "market_stall", "market_table", "barrel", "barrel_stand", "crate",
    "sack_stack", "basket", "produce_baskets", "bench", "signboard",
    "hanging_sign", "lantern", "well", "cart", "wheelbarrow", "log_pile",
    "haystack", "anvil", "pot", "planter", "ladder", "standing_board",
    "flower_box", "pottery_row", "tools_rack", "trough", "banner",
    "grindstone",
    # ---- 六轮：街道家具 20 件（props.py TABLE "六轮"段全量；石灯/铁艺灯/壁灯/
    #      花坛×4/长椅×2/露天桌/大小喷泉/公告板/旗杆/雕像基座/里程碑/路标/马槽/
    #      水龙头/桶栽/吊篮）----
    "lamp_post_stone", "lamp_post_iron", "wall_sconce",
    "flower_bed_round", "flower_bed_long", "hanging_basket", "planter_ring",
    "bench_wood", "bench_stone", "table_outdoor", "fountain_small",
    "fountain_grand", "notice_board", "flag_pole", "statue_base",
    "milestone", "signpost", "horse_trough", "water_tap", "barrel_planter",
]
#: 库里签名不是"点摆件"的（fence/clothesline 要 x0,x1），不进本批

#: 增量烘焙过滤：设 BAKE_ONLY=lamp_post_stone,fountain_grand（逗号分隔件名）时
#: 只烘点名件（PROPS 其余跳过）；未设/空 = 全量，默认行为不变。增量模式下
#: props.json 做**合并写回**（旧条目保留原序、同名覆盖、新卡追加尾部）。
BAKE_ONLY = [s.strip() for s in os.environ.get("BAKE_ONLY", "").split(",")
             if s.strip()]


# ------------------------------------------------------------------ 场景

def clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def setup_world():
    """与 proto_25d 的 blender_proto.setup_world 同口径（§8.4 定标，不自创）。"""
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
    """glow 层用的纯色材质。

    **必须 `new()` 而不是 `get()` + `remove()`**：`buildings.material()` 内部有
    材质缓存（Material 结构体引用），用同名新建再删掉会让缓存里的引用失效
    （实测报 `ReferenceError: StructRNA of type Material has been removed`
    并中断整轮烘焙）。这里一律新建、不删，Blender 自动加 .001 后缀。
    """
    m = bpy.data.materials.new("__pglow_" + name)
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


def build_prop(name):
    """按 dress() 的口径装配单件（×GAME_SCALE×MOUNT_SCALE，z 不缩放）。"""
    b = B.Builder("prop_" + name)
    fn = P.TABLE.get(name)
    if fn is None:
        return None
    eff = P.GAME_SCALE * P.mount_scale(name)
    kw = {}
    # 让主尺寸乘上挂载缩放（与 dress() 完全同一处理）
    for k in ("r", "h", "w", "d", "s"):
        pass
    try:
        fn(b, x=0.0, y=0.0, z=0.0, seed=7, **kw)
    except TypeError:
        try:
            fn(b, x=0.0, y=0.0, z=0.0)
        except TypeError as e:
            print("[prop] 跳过（签名不符）: %s (%s)" % (name, e))
            return None
    ob = b.to_object()
    # 挂载缩放：直接缩物体（dress 是缩参数，结果等价且更简单）
    ob.scale = (eff, eff, 1.0)
    bpy.context.view_layer.update()
    return ob


def bake_card(ob, cam, name):
    """与 blender_proto.bake_cards 同一套：屏幕包围盒 -> 正交相机 -> 透明底两层。"""
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
    for other, hv in saved_hide.items():
        other.hide_render = hv

    return {
        "card": name, "def": name,
        "px": [rx, ry], "zoom": rx / w if w > 0 else ZOOM,
        "units": [rx / (rx / w) if w > 0 else w, ry / (rx / w) if w > 0 else h],
        "anchor": [anchor.x, anchor.y, anchor.z],
        "glow_mats": sorted(set(hit)),
    }


def load_props_json():
    """读旧 props.json（缺失/损坏返回空列表，增量合并不因旧档异常而中断）。"""
    try:
        with open(os.path.join(OUT_DIR, "props.json"), encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, list) else []
    except Exception:
        return []


def merge_cards(new_cards):
    """增量合并：旧 props.json 条目保留原序（同名去重保首个，顺带修掉旧表里的
    重复件），本批同名覆盖、新卡追加尾部。全量模式不经过此函数，写盘行为不变。"""
    old = load_props_json()
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

    cards = []
    for name in PROPS:
        if BAKE_ONLY and name not in BAKE_ONLY:
            continue
        # 每件单独进一个新场景太重；在同一个场景里逐件建、烘完即删
        try:
            ob = build_prop(name)
        except Exception as e:          # noqa: BLE001 单件失败不该中断整轮
            print("[prop] 跳过（装配/烘焙异常）: %s (%s)" % (name, e))
            ob = None
        if ob is None:
            print("[prop] 跳过（库中无此件或签名不符）: " + name)
            continue
        c = bake_card(ob, cam, name)
        cards.append(c)
        print("[prop] %-18s %4dx%-5d units=(%.0f,%.0f) anchor=(%.1f,%.1f,%.1f) glow=%s"
              % (name, c["px"][0], c["px"][1], c["units"][0], c["units"][1],
                 c["anchor"][0], c["anchor"][1], c["anchor"][2],
                 ",".join(c["glow_mats"]) or "-"))
        me = ob.data
        bpy.data.objects.remove(ob, do_unlink=True)
        bpy.data.meshes.remove(me)

    if BAKE_ONLY:
        # 增量模式：合并写回（旧条目保留、同名覆盖、新卡追加）
        cards = merge_cards(cards)
        print("[prop] BAKE_ONLY=(%s) 合并后共 %d 条" % (",".join(BAKE_ONLY), len(cards)))
    with open(os.path.join(OUT_DIR, "props.json"), "w", encoding="utf-8") as f:
        json.dump(cards, f, ensure_ascii=False, indent=1)
    print("[prop] 共 %d 件 -> %s" % (len(cards), os.path.join(OUT_DIR, "props.json")))
    print("PROPS_OK")


main()
