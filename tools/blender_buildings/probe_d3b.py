# -*- coding: utf-8 -*-
"""probe_d3b.py —— 批次 D3b（8 个新/独立化装配器）2.6x 特写自检图

覆盖 def：mage_tower / alchemy / library / barracks / warehouse / stable / shelter
（+ hayloft：D3a 已独立化，本批仅回归复测，不改其几何）。
用途：总图里每栋只剩几十像素宽，看不出"符文带/彩窗/悬浮水晶读不读得出、
吊臂有没有穿模、门楼垛口像不像兵营、马厩还是不是黑盒子"。本探针只出这 8 个 def，
**每栋 2.6x（1 格 = 83px）特写 + 同尺度 130px 火柴人**，逐栋肉眼验收。

跑法::
    blender -b --factory-startup -P probe_d3b.py
    D3B_ONLY=mage_tower,stable blender -b --factory-startup -P probe_d3b.py

产物（stick-world/temp/）::
    pbr_d3b_<def>.png        每 def 一张（主宽度档）
    pbr_d3b_<def>_w<N>.png   同一 def 的其余宽度档
"""

import math
import os
import sys

import bpy

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import buildings as B  # noqa: E402

OUT_DIR = "F:/VSCode/game-2/.temp/building-pipeline-v2/stick-world/temp"

YAW = 0.0              # 同 probe_buildings：纯正面 + 俯角 20°
TILT = 20.0
ZOOM = 2.6             # 特写倍率（1 格 = 32 × 2.6 ≈ 83px）

#: 每个 def 的**主宽度档**（出 pbr_d3b_<def>.png）；其余宽度档出 _w<N>.png
D3B_PRIMARY = {
    "mage_tower": 6, "alchemy": 8, "library": 12, "barracks": 12,
    "warehouse": 12, "stable": 8, "shelter": 4, "hayloft": 8,
}

D3B_LIST = [("mage_tower", 4), ("mage_tower", 6), ("mage_tower", 8),
            ("alchemy", 8), ("alchemy", 12),
            ("library", 12), ("library", 16),
            ("barracks", 12), ("barracks", 16),
            ("warehouse", 12), ("warehouse", 16),
            ("stable", 8), ("stable", 12),
            ("shelter", 4), ("shelter", 6), ("shelter", 8),
            ("hayloft", 8), ("hayloft", 12)]


def clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    B._CACHE.clear()
    B._MAGIC_KEYS.clear()


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
    for attr, val in (("taa_render_samples", 64), ("use_gtao", True)):
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

    sun("key", 3.3, (40, 0, -38))
    sun("fill", 0.15, (55, 0, 128), 20.0, (0.85, 0.90, 1.0))
    return sc


def make_camera():
    d = bpy.data.cameras.new("cam")
    d.type = "ORTHO"
    d.clip_start = 1.0
    d.clip_end = 40000.0
    ob = bpy.data.objects.new("cam", d)
    bpy.context.scene.collection.objects.link(ob)
    bpy.context.scene.camera = ob
    return ob


def shoot_fit(cam, objs, zoom, path, pad=46.0, pad_top=34.0, res_max=7600):
    from mathutils import Vector
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
    right, up = B.cam_axes(YAW, TILT)
    fwd = -(right.cross(up))
    cam.location = tuple(Vector(anchor) - fwd * 9000.0)
    cam.rotation_euler = (math.radians(90.0 - TILT), 0.0, math.radians(YAW))
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
    return {"path": path, "res": (rx, ry), "px_per_unit": rx / w}


def make_ground(x0, x1, y0, y1):
    me = bpy.data.meshes.new("ground_mesh")
    me.from_pydata([(x0, y0, 0), (x1, y0, 0), (x1, y1, 0), (x0, y1, 0)], [],
                   [(0, 1, 2, 3)])
    me.materials.append(B.material("ground"))
    ob = bpy.data.objects.new("ground", me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def one(cam, name, wc, path):
    """一栋特写：建筑 + 同尺度火柴人（站在建筑前缘，不占横向净距）。"""
    ob, spec = B.ASSEMBLERS[name](wc)
    mx = B.measure(ob)
    sb = B.Builder("stick_%s_w%d" % (name, wc))
    B.stickman(sb, x=mx["x"][1] - 26.0, y=mx["y"][0] - 26.0)
    sob = sb.to_object()
    info = shoot_fit(cam, [ob, sob], ZOOM, path)
    rep = B.check_spec(spec, ob)
    bpy.data.objects.remove(sob, do_unlink=True)
    bpy.data.objects.remove(ob, do_unlink=True)
    return rep, info


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    clear()
    setup_world()
    cam = make_camera()
    make_ground(-4000.0, 4000.0, -2400.0, 1600.0)

    print("\n=== D3b 特写自检（2.6x；剪影 = yaw=0/tilt=20 投影）===")
    print("%-11s %2s %6s %7s %6s %8s %7s %-9s %s"
          % ("def", "格", "网格宽", "剪影总高", "檐口", "出檐%", "长宽比", "判定",
             "产物"))
    only = [s for s in os.environ.get("D3B_ONLY", "").split(",") if s]
    pairs = [p for p in D3B_LIST if not only or p[0] in only]
    if only:
        print("（D3B_ONLY=%s → 只出 %d 个宽度档；其余图保持上一轮产物）"
              % (os.environ["D3B_ONLY"], len(pairs)))
    bad = []
    for (name, wc) in pairs:
        fn = ("pbr_d3b_%s.png" % name
              if D3B_PRIMARY.get(name) == wc
              else "pbr_d3b_%s_w%d.png" % (name, wc))
        rep, info = one(cam, name, wc, os.path.join(OUT_DIR, fn))
        print("%-11s %2d %6.0f %7.0f %6.0f %7.1f%% %7.2f %-9s %s  (%dx%d px)"
              % (name, wc, rep["grid_w"], rep["sil_h"], rep["eave_px"],
                 rep["eave_ratio"] * 100.0, rep["ratio"],
                 "PASS" if rep["pass"] else "FAIL", fn, info["res"][0],
                 info["res"][1]))
        if not rep["pass"]:
            bad.append((name, wc))
    if bad:
        print("!! D3b 未过门禁：%s" % ", ".join("%s w%d" % b for b in bad))
    else:
        print("D3b 全部 PASS（8 def / %d 个宽度档）" % len(D3B_LIST))
    print("\nD3B_OK")


if __name__ == "__main__":
    main()
