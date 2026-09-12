# -*- coding: utf-8 -*-
"""probe_props.py —— 道具层验收图（管线 v3）

产物（stick-world/temp/）::
    pbr_props.png          道具总览条（每件道具独立站位，前视微俯视，含火柴人比例尺）
    pbr_props_smithy.png   铁匠铺前场（真实装配器 + dress 配方）
    pbr_props_house.png    民居前场（真实装配器 + dress 配方）

跑法::
    blender -b --factory-startup -P probe_props.py
"""

import math
import os
import sys

import bpy
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import buildings as B   # noqa: E402
import props as P       # noqa: E402

OUT_DIR = "F:/VSCode/game-2/.temp/building-pipeline-v2/stick-world/temp"
YAW = 0.0
TILT = 20.0
ZOOM = 1.6


def clear():
    """**只在开头调用一次**：建空场景。

    注意：`read_factory_settings` 会把 bpy.data 里的材质/节点组全部清掉，而
    `buildings._CACHE` 与 `materials` 内部的缓存仍持有旧引用 → 之后拿到的是
    "StructRNA of type Material has been removed"，`_external_material` 校验失败就
    静默回退成 `_flat_pbr` 纯色，**纹理整片消失**（我踩过一次）。所以多张图之间
    只能用 `wipe()` 删网格对象，绝不能再次 read_factory_settings。
    """
    bpy.ops.wm.read_factory_settings(use_empty=True)
    B._CACHE.clear()


def wipe():
    """删掉场景里的所有网格对象（保留灯光/世界/相机/材质），供多张图复用场景。"""
    for ob in list(bpy.data.objects):
        if ob.type == "MESH":
            bpy.data.objects.remove(ob, do_unlink=True)


def setup_world():
    sc = bpy.context.scene
    for eng in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE", "CYCLES"):
        try:
            sc.render.engine = eng
            break
        except Exception:
            continue
    sc.render.film_transparent = False
    sc.view_settings.view_transform = "Standard"
    sc.view_settings.look = "None"
    for attr, val in (("taa_render_samples", 64), ("use_gtao", True),
                      ("use_bloom", True), ("bloom_intensity", 0.06)):
        try:
            setattr(sc.eevee, attr, val)
        except Exception:
            pass
    w = bpy.data.worlds.new("W")
    sc.world = w
    w.use_nodes = True
    bg = w.node_tree.nodes.get("Background") or w.node_tree.nodes.new("ShaderNodeBackground")
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

    sun("key", 3.3, (40, 0, -38))
    sun("fill", 0.15, (55, 0, 128), 20.0, (0.85, 0.90, 1.0))


def make_ground(x0, x1, y0, y1):
    me = bpy.data.meshes.new("ground_mesh")
    me.from_pydata([(x0, y0, 0), (x1, y0, 0), (x1, y1, 0), (x0, y1, 0)], [], [(0, 1, 2, 3)])
    me.materials.append(B.material("ground"))
    ob = bpy.data.objects.new("ground", me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def make_camera():
    d = bpy.data.cameras.new("cam")
    d.type = "ORTHO"
    d.clip_start = 1.0
    d.clip_end = 40000.0
    ob = bpy.data.objects.new("cam", d)
    bpy.context.scene.collection.objects.link(ob)
    bpy.context.scene.camera = ob
    return ob


def place_camera(cam, anchor, dist=9000.0):
    right, up = B.cam_axes(YAW, TILT)
    fwd = -(right.cross(up))
    cam.location = tuple(Vector(anchor) - fwd * dist)
    cam.rotation_euler = (math.radians(90.0 - TILT), 0.0, math.radians(YAW))


def shoot_fit(cam, objs, zoom, path, pad=40.0, pad_top=30.0, res_max=6000):
    pts = []
    for ob in objs:
        pts += B.shape_points(ob, skip_ground=False)
    right, up = B.cam_axes(YAW, TILT)
    us = [p.dot(right) for p in pts]
    vs = [p.dot(up) for p in pts]
    u0, u1 = min(us) - pad, max(us) + pad
    v0, v1 = min(vs) - pad, max(vs) + pad_top
    w, h = (u1 - u0), (v1 - v0)
    cu, cv = (u0 + u1) / 2.0, (v0 + v1) / 2.0
    ref = pts[0]
    anchor = ref + right * (cu - ref.dot(right)) + up * (cv - ref.dot(up))
    place_camera(cam, anchor)
    k = min(1.0, res_max / float(max(w, h) * zoom))
    rx = max(64, int(round(w * zoom * k)))
    ry = max(64, int(round(h * zoom * k)))
    cam.data.ortho_scale = max(w, h)
    sc = bpy.context.scene
    sc.render.resolution_x = rx
    sc.render.resolution_y = ry
    sc.render.resolution_percentage = 100
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)
    print("-> %s  %dx%d" % (path, rx, ry))
    return {"path": path, "res": (rx, ry)}


# ---------------------------------------------------------------- 总览条

#: 条目 = (道具名, kwargs, 站位宽)——按功能聚类排列，同类相邻便于对比
STRIP = [
    ("barrel", dict(r=15.0, h=42.0), 46.0),
    ("barrel", dict(r=14.0, h=38.0, lying=True, water=True), 52.0),
    ("bucket", dict(), 30.0),
    ("trough", dict(w=76.0, h=24.0), 86.0),
    ("sack", dict(), 34.0),
    ("crate", dict(), 36.0),
    ("chest", dict(), 56.0),
    ("log_pile", dict(rows=2, per_row=5), 96.0),
    ("plank_pile", dict(), 74.0),
    ("coal_pile", dict(), 52.0),
    ("haystack", dict(), 58.0),
    ("anvil", dict(), 66.0),
    ("quench_barrel", dict(), 40.0),
    ("tools_rack", dict(w=54.0), 62.0),
    ("grindstone", dict(), 56.0),
    ("tongs", dict(), 30.0),
    ("bench", dict(back=True), 70.0),
    ("stool", dict(), 32.0),
    ("table", dict(), 68.0),
    ("signboard", dict(swing=3.0), 66.0),
    ("lantern", dict(), 40.0),
    ("pot", dict(), 32.0),
    ("ladder", dict(h=110.0), 34.0),
    ("cart", dict(loaded=3), 128.0),
    ("wheelbarrow", dict(), 116.0),
    ("fence", dict(x0=-40.0, x1=40.0, wattle=True), 92.0),
    ("well", dict(), 62.0),
    ("banner", dict(), 40.0),
    ("clothesline", dict(x0=-40.0, x1=40.0, z=110.0, items=3), 92.0),
    ("hay_fork", dict(), 26.0),
    ("grind_post", dict(), 30.0),
    ("rope_coil", dict(), 32.0),
    ("mooring_post", dict(), 30.0),
    ("flower_box", dict(w=44.0), 52.0),
]


def build_strip():
    objs = []
    cursor = 0.0
    for (pname, kw, span) in STRIP:
        fn = P.TABLE[pname]
        b = B.Builder("prop_%s_%.0f" % (pname, cursor))
        p = dict(kw)
        zz = p.pop("z", 0.0)          # 挂墙件自带 z 偏移（如晾衣绳）
        p["seed"] = int(cursor)
        try:
            fn(b, x=0.0, y=0.0, z=zz, **p)
        except TypeError:
            p.pop("seed", None)
            fn(b, x=0.0, y=0.0, z=zz, **p)
        ob = b.to_object()
        ob.location.x = cursor
        bpy.context.view_layer.update()
        objs.append(ob)
        cursor += span
    # 比例尺：等距插火柴人
    n = 7
    for i in range(n):
        sb = B.Builder("stick_%d" % i)
        B.stickman(sb, x=0.0, y=-24.0)
        sob = sb.to_object()
        sob.location.x = cursor * (i + 0.5) / n
        bpy.context.view_layer.update()
        objs.append(sob)
    return objs, cursor


# ---------------------------------------------------------------- 前场

def dressed(name, wc, kind, seed, tag, doorless=False):
    ob, spec = B.ASSEMBLERS[name](wc)
    mx = B.measure(ob)
    pb = B.Builder("props_" + tag)
    d = spec.get("door")
    P.dress(pb, kind, spec["grid_w"], mx["y"][0], seed=seed,
            door_x=spec.get("door_x", 0.0), door_w=(d[0] if d else 0.0))
    pob = pb.to_object()
    return ob, pob, spec


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    clear()
    setup_world()
    cam = make_camera()

    # 1) 道具总览条
    objs, span = build_strip()
    make_ground(-200.0, span + 200.0, -400.0, 400.0)
    shoot_fit(cam, objs, ZOOM, os.path.join(OUT_DIR, "pbr_props.png"),
              pad=40.0, pad_top=16.0)

    # 2) 真实装配器 + 配方（前场道具就位后的整体读感）
    #    每栋之间只 wipe() 网格，不重建场景（否则材质缓存失效、纹理全丢）
    for (nm, wc, kind, tag) in (("smithy1", 8, "smithy", "pbr_props_smithy"),
                                ("house", 12, "house", "pbr_props_house"),
                                ("barn", 12, "barn", "pbr_props_barn")):
        wipe()
        try:
            ob, pob, spec = dressed(nm, wc, kind, seed=7, tag=tag)
        except Exception as exc:
            print("!! %s/%d 装配失败：%s" % (nm, wc, exc))
            continue
        mx = B.measure(ob)
        sb = B.Builder("stick")
        B.stickman(sb, x=mx["x"][1] + 40.0, y=mx["y"][0] - 30.0)
        sob = sb.to_object()
        make_ground(mx["x"][0] - 400.0, mx["x"][1] + 400.0, -600.0, 600.0)
        shoot_fit(cam, [ob, pob, sob], 1.9, os.path.join(OUT_DIR, tag + ".png"),
                  pad=70.0, pad_top=50.0)

    print("\nPROPS_PROBE_OK")


main()
