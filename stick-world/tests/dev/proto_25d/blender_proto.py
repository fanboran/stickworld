# -*- coding: utf-8 -*-
"""blender_proto.py —— 2.5D 原型（引擎侧可行性验证）的 Blender 半场。

只做两件事，**只读导入** `tools/blender_buildings/buildings.py`（不改它）：

1. **烘焙纸片卡**（albedo 层 + glow 层），相机严格对齐 2.5D 目标视角
   （yaw=0°，tilt=20°，正交），透明底 RGBA，像素级两层对齐；
2. **导出 glb**（同一批建筑，几何 + 材质槽，规模 1/32 = 1 Godot 单位 = 1 格）。

跑法（固定命令）::

    "F:/SteamLibrary/steamapps/common/Blender/blender.exe" -b --factory-startup \
        -P stick-world/tests/dev/proto_25d/blender_proto.py

产物（stick-world/temp/proto25d/）::

    cards/<def>_w<N>.png        albedo 卡（透明底）
    cards/<def>_w<N>_glow.png   glow 卡（黑底 + 自发光材质，加色叠加用）
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

OUT_DIR = os.path.join(REPO, "stick-world", "temp", "proto25d")
CARD_DIR = os.path.join(OUT_DIR, "cards")
GLB_PATH = os.path.join(OUT_DIR, "proto25d_buildings.glb")

# 2.5D 目标视角（§0.3 硬约束：纯正面 + 20° 微俯视，禁水平偏航）
YAW = 0.0
TILT = 20.0
ZOOM = 2.0            # 烘焙像素/世界单位（2x）
PAD = 10.0            # 卡四周留白（世界单位）
RES_MAX = 3000        # 单卡最长边像素上限（护显存）
SCALE = 1.0 / 32.0    # 世界单位(px) -> Godot 单位(格)

#: 街排（def, 格数）——宽度档按 §0.3 取 4 的整数倍，6 格档仅装配器允许时用
STREET = [
    ("cottage", 6),
    ("house", 8),
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
]

#: glow 卡里当作"自发光窗/火"的材质名（其余一律压成纯黑，加色叠加下不可见）
GLOW_MATS = {"glass", "glass_win", "lamp", "fire", "ember", "candle", "torch"}


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

def layout():
    """沿 X 摆开一条街；返回 [{def,cells,obj,spec,origin}]。"""
    built = []
    cursor = 0.0
    for (name, wc) in STREET:
        if name not in B.ASSEMBLERS:
            print("[SKIP] 无装配器: %s" % name)
            continue
        ob, spec = B.ASSEMBLERS[name](wc)
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

    for other, hv in saved_hide.items():
        other.hide_render = hv

    return {
        "card": tag, "def": entry["def"], "cells": entry["cells"],
        "px": [rx, ry], "zoom": rx / w if w > 0 else ZOOM,
        "units": [rx / (rx / w) if w > 0 else w, ry / (rx / w) if w > 0 else h],
        "anchor": [anchor.x, anchor.y, anchor.z],
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

    export_glb(built)
    rep = report(built, cards)
    with open(os.path.join(OUT_DIR, "cards.json"), "w", encoding="utf-8") as f:
        json.dump(cards, f, ensure_ascii=False, indent=1)
    with open(os.path.join(OUT_DIR, "build_report.json"), "w", encoding="utf-8") as f:
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
