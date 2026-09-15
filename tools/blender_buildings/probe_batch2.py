# -*- coding: utf-8 -*-
"""probe_batch2.py —— 分级批次 2 出图（驿站族 3 / 赌场族 2 / 科研 2 / 花店 1）

渲染内容
--------
* `pbr_b2x_<def>_w<N>.png`  14 张 2.6x 特写（8 个新 def × 各宽度档），每张含
  **门口并排火柴人**（无门开敞件站棚下）
* `pbr_b2x_family_post.png`   驿站族三件同框从小到大（waystation w6 → inn_post w12 →
  coach_house w16）+ 火柴人
* `pbr_b2x_family_casino.png` 赌场两件同框（gambling_den w8 → grand_casino w16）+ 火柴人
* `pbr_b2x_edge.png`          棱线高光门禁图（抽 inn_post w12，强侧光特写，
  口径同 probe_bevel：所有可见棱须呈"亮→暗"高光渐变带，死线即打回）
* stdout 逐件 check_spec 实测表 + PROBE_OK

跑法（timeout 600000）::

    cd /f/VSCode/game-2 && "/f/SteamLibrary/steamapps/common/Blender/blender.exe" \
        -b --factory-startup -P tools/blender_buildings/probe_batch2.py

产物目录：`stick-world/temp/`
"""

import math
import os
import sys

import bpy
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import buildings as B  # noqa: E402

OUT_DIR = "F:/VSCode/game-2/stick-world/temp"
YAW = 0.0               # §0.3：纯正面 + 俯角 20°（禁止水平偏航）
TILT = 20.0
ZOOM_CLOSE = 2.6        # 特写
ZOOM_FAMILY = 1.6       # 家族对比（三件同框画面大，取景zoom略降保分辨率）
ZOOM_EDGE = 3.4         # 棱线门禁特写（同 probe_bevel 口径）
BAY_GAP = 60.0

#: 特写清单（def × 宽度档，与 buildings.PROBE_LIST 本批新增段一致）
CLOSE_LIST = [("waystation", 6), ("waystation", 8),
              ("inn_post", 12), ("inn_post", 16),
              ("coach_house", 12), ("coach_house", 16),
              ("gambling_den", 8), ("gambling_den", 12),
              ("grand_casino", 16),
              ("academy", 12), ("academy", 16),
              ("observatory", 8),
              ("flower_shop", 8), ("flower_shop", 12)]
#: 家族对比（从小到大）
FAMILIES = [("post", [("waystation", 6), ("inn_post", 12), ("coach_house", 16)]),
            ("casino", [("gambling_den", 8), ("grand_casino", 16)])]
#: 棱线门禁抽验件（挑附属件最密的驿站 Lv2）
EDGE_SUBJECT = ("inn_post", 12)


def clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)   # 整个进程只做这一次（踩坑纪律）


def setup_world():
    sc = bpy.context.scene
    for eng in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE"):
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
    w = bpy.data.worlds.new("W_b2x")
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
        try:
            d.use_shadow = True
        except Exception:
            pass
        ob = bpy.data.objects.new(name, d)
        ob.rotation_euler = tuple(math.radians(a) for a in rot)
        sc.collection.objects.link(ob)
        return ob

    sun("key", 3.3, (40, 0, -38))
    sun("fill", 0.15, (55, 0, 128), 20.0, (0.85, 0.90, 1.0))
    return sc


def setup_edge_lights():
    """棱线门禁三灯（probe_bevel 同口径）：正前 45° 主光出顶棱高光带 + 左前掠射勾竖棱 +
    背光压轮廓；环境光压低、**日常主辅灯熄火**（不熄则门禁口径不纯）。返回可恢复句柄。"""
    sc = bpy.context.scene
    olds = []
    for o in bpy.data.objects:
        if o.type == "LIGHT" and o.data.name in ("key", "fill"):
            olds.append((o.data, o.data.energy))
            o.data.energy = 0.0

    def sun(name, energy, rot, angle=1.2, color=(1.0, 0.96, 0.88)):
        d = bpy.data.lights.new(name, "SUN")
        d.energy = energy
        d.angle = math.radians(angle)
        d.color = color
        try:
            d.use_shadow = True
        except Exception:
            pass
        ob = bpy.data.objects.new(name, d)
        ob.rotation_euler = tuple(math.radians(a) for a in rot)
        sc.collection.objects.link(ob)
        return ob

    lamps = (sun("edge_key", 4.6, (45, 0, -10), 0.8),
             sun("edge_side", 1.9, (81, 0, -63), 1.2),
             sun("edge_rim", 0.9, (52, 0, 168), 1.6, (0.84, 0.90, 1.0)))
    sc.world.node_tree.nodes.get("Background").inputs[1].default_value = 0.12
    return lamps, olds


def restore_world(lamps, olds):
    for ob in lamps:
        bpy.data.objects.remove(ob, do_unlink=True)
    for d, energy in olds:
        d.energy = energy
    sc = bpy.context.scene
    sc.world.node_tree.nodes.get("Background").inputs[1].default_value = 0.60


def make_ground(x0, x1, y0, y1):
    me = bpy.data.meshes.new("ground_mesh")
    me.from_pydata([(x0, y0, 0), (x1, y0, 0), (x1, y1, 0), (x0, y1, 0)], [], [(0, 1, 2, 3)])
    me.materials.append(B.material("ground"))
    ob = bpy.data.objects.new("ground", me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def make_camera():
    d = bpy.data.cameras.new("cam_b2x")
    d.type = "ORTHO"
    d.clip_start = 1.0
    d.clip_end = 40000.0
    ob = bpy.data.objects.new("cam_b2x", d)
    bpy.context.scene.collection.objects.link(ob)
    bpy.context.scene.camera = ob
    return ob


def place_camera(cam, anchor, dist=9000.0):
    right, up = B.cam_axes(YAW, TILT)
    fwd = -(right.cross(up))
    cam.location = tuple(Vector(anchor) - fwd * dist)
    cam.rotation_euler = (math.radians(90.0 - TILT), 0.0, math.radians(YAW))


def shoot(cam, anchor, w, h, zoom, path, res_max=7600):
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
    return {"path": path, "res": (rx, ry)}


def shoot_fit(cam, objs, zoom, path, pad=40.0, pad_top=34.0, res_max=7600):
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
    return shoot(cam, anchor, w, h, zoom, path, res_max=res_max)


def build_with_stickman(name, wc, dx=None):
    """装配一栋 + 门口并排火柴人（无 door 的开敞件站棚下前缘）；返回 (ob, stick, spec)。"""
    ob, spec = B.ASSEMBLERS[name](wc)
    mx = B.measure(ob)
    y_front = mx["y"][0]
    sx = spec.get("door_x", 0.0) if dx is None else dx
    sb = B.Builder("stick_%s_w%d" % (name, wc))
    B.stickman(sb, x=sx, y=y_front + 10.0)
    stick = sb.to_object()
    return ob, stick, spec


def main():
    clear()
    setup_world()
    cam = make_camera()
    os.makedirs(OUT_DIR, exist_ok=True)

    built = []
    cursor = 0.0
    for (name, wc) in CLOSE_LIST:
        ob, stick, spec = build_with_stickman(name, wc)
        mx = B.measure(ob)
        shift = cursor - mx["x"][0]
        ob.location.x += shift
        stick.location.x += shift
        bpy.context.view_layer.update()
        built.append({"name": name, "wc": wc, "obj": ob, "stick": stick, "spec": spec})
        cursor = B.measure(ob)["x"][1] + BAY_GAP

    xs = []
    for e in built:
        mx = B.measure(e["obj"])
        xs += [mx["x"][0], mx["x"][1]]
    make_ground(min(xs) - 800.0, max(xs) + 800.0, -1400.0, 1200.0)

    # ---- 1) 特写（含火柴人）
    for e in built:
        info = shoot_fit(cam, [e["obj"], e["stick"]], ZOOM_CLOSE,
                         os.path.join(OUT_DIR, "pbr_b2x_%s_w%d.png" % (e["name"], e["wc"])),
                         pad=44.0, pad_top=36.0)
        print("CLOSE %s w%d -> %s res=%s" % (e["name"], e["wc"],
                                             os.path.basename(info["path"]), info["res"]))

    # ---- 2) 家族对比（从小到大，同框 + 火柴人）
    # 先清掉特写行（旧版不删，家族行与其重叠、画面混入邻栋——返工点）；
    # 规格实测先算好存下（对象删掉后 check_spec 无 ob 可测）。
    for e in built:
        e["rep"] = B.check_spec(e["spec"], e["obj"])
        bpy.data.objects.remove(e["obj"], do_unlink=True)
        bpy.data.objects.remove(e["stick"], do_unlink=True)
    bpy.context.view_layer.update()
    for (tag, defs) in FAMILIES:
        objs = []
        gap = 70.0
        cur = 0.0
        for (name, wc) in defs:
            ob, stick, _spec = build_with_stickman(name, wc)
            mx = B.measure(ob)
            shift = cur - mx["x"][0]
            ob.location.x += shift
            stick.location.x += shift
            bpy.context.view_layer.update()      # 不更新 matrix_world 是旧的 → 重叠
            objs += [ob, stick]
            cur = B.measure(ob)["x"][1] + gap
        bpy.context.view_layer.update()
        info = shoot_fit(cam, objs, ZOOM_FAMILY,
                         os.path.join(OUT_DIR, "pbr_b2x_family_%s.png" % tag),
                         pad=70.0, pad_top=56.0)
        print("FAMILY %s -> %s res=%s" % ([d for d in defs],
                                          os.path.basename(info["path"]), info["res"]))
        for ob in objs:
            bpy.data.objects.remove(ob, do_unlink=True)

    # ---- 3) 棱线高光门禁（强侧光特写，probe_bevel 三灯口径）
    lamps, olds = setup_edge_lights()
    name, wc = EDGE_SUBJECT
    ob, stick, _spec = build_with_stickman(name, wc)
    shoot_fit(cam, [ob, stick], ZOOM_EDGE,
              os.path.join(OUT_DIR, "pbr_b2x_edge.png"), pad=30.0, pad_top=26.0)
    print("EDGE %s w%d -> pbr_b2x_edge.png" % (name, wc))
    bpy.data.objects.remove(ob, do_unlink=True)
    bpy.data.objects.remove(stick, do_unlink=True)
    restore_world(lamps, olds)

    # ---- 4) 规格表（实测 + check_spec 判定）
    print("\n=== 分级批次 2 实测规格（yaw=0 / tilt=20 投影）===")
    print("%-13s %2s %6s %6s %7s %6s %-9s %-9s %5s %6s %8s %s"
          % ("def", "格", "网格宽", "剪影宽", "剪影高", "檐口", "层高", "门(净)",
             "出檐", "檐%", "长宽比", "判定"))
    n_pass = 0
    for e in built:
        s = e["spec"]
        rep = e["rep"]
        n_pass += 1 if rep["pass"] else 0
        d = s.get("door")
        ds = "-" if not d else "%.0fx%.0f%s" % (d[0], d[1],
                                                "*" if s.get("composite_door") else "")
        st = "+".join("%.0f" % v for v in s["storey_h"])
        print("%-13s %2d %6.0f %6.0f %7.0f %6.0f %-9s %-9s %5.0f %5.1f%% %8.2f %s"
              % (e["name"], e["wc"], rep["grid_w"], rep["sil_w"], rep["sil_h"],
                 s["eave_h"], st, ds, rep["eave_px"], rep["eave_ratio"] * 100.0,
                 rep["ratio"], "PASS" if rep["pass"] else "FAIL"))
    print("\n%d/%d PASS（豁免条目见 [exempt] 行，理由随 spec.reason）" % (n_pass, len(built)))
    print("\nPROBE_OK")


main()
