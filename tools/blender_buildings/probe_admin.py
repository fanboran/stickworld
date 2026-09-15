# -*- coding: utf-8 -*-
"""probe_admin.py —— 行政/地标轮（6 个新装配器）出图自检

产物（stick-world/temp/）::
    pbr_admin_<def>.png        每 def 一张 2.6x 特写（含同尺度 130px 火柴人，站在门口）
    pbr_admin_<def>_w<N>.png   同 def 其余宽度档
    pbr_admin_ladder.png       行政阶梯一张图：council→town_hall→(cathedral 参照)→
                               governor→palace 从左到右，同一地平线，天际线对比
    pbr_admin_edge.png         棱线高光门禁图：强侧光特写总督府前廊一角（倒角高光渐变）

跑法::
    blender -b --factory-startup -P probe_admin.py         （ADMIN_ONLY=名 可只出部分）
"""

import math
import os
import sys

import bpy

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import buildings as B  # noqa: E402

OUT_DIR = "F:/VSCode/game-2/stick-world/temp"

YAW = 0.0              # 同 probe_buildings：纯正面 + 俯角 20°（§0.3 视角硬约束）
TILT = 20.0
ZOOM = 2.6             # 特写倍率（1 格 = 32 × 2.6 ≈ 83px）
ZOOM_LADDER = 1.35     # 阶梯图（五栋并排，能看清剪影高差即可）

#: 每 def 的主宽度档（出 pbr_admin_<def>.png）；其余宽度档出 _w<N>.png
ADMIN_PRIMARY = {"council_hall": 8, "town_hall": 16, "governor_palace": 16,
                 "imperial_palace": 16, "belfry": 6, "mint": 16}

ADMIN_LIST = [("council_hall", 8),
              ("town_hall", 12), ("town_hall", 16),
              ("governor_palace", 16),
              ("imperial_palace", 16),
              ("belfry", 4), ("belfry", 6),
              ("mint", 12), ("mint", 16)]

#: 行政阶梯图（左→右，从小到大；cathedral16 作"被压过"的参照物）
LADDER = [("council_hall", 8), ("town_hall", 12), ("town_hall", 16),
          ("cathedral", 16), ("governor_palace", 16), ("imperial_palace", 16)]


def clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    B._CACHE.clear()


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
        return ob

    suns = {"key": sun("key", 3.3, (40, 0, -38)),
            "fill": sun("fill", 0.15, (55, 0, 128), 20.0, (0.85, 0.90, 1.0))}
    return sc, suns


def make_camera():
    d = bpy.data.cameras.new("cam")
    d.type = "ORTHO"
    d.clip_start = 1.0
    d.clip_end = 40000.0
    ob = bpy.data.objects.new("cam", d)
    bpy.context.scene.collection.objects.link(ob)
    bpy.context.scene.camera = ob
    return ob


def _render(cam, anchor, w, h, zoom, path, res_max=7600):
    from mathutils import Vector
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


def shoot_fit(cam, objs, zoom, path, pad=46.0, pad_top=34.0, res_max=7600):
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
    return _render(cam, anchor, w, h, zoom, path, res_max=res_max)


def make_ground(x0, x1, y0, y1):
    me = bpy.data.meshes.new("ground_mesh")
    me.from_pydata([(x0, y0, 0), (x1, y0, 0), (x1, y1, 0), (x0, y1, 0)], [],
                   [(0, 1, 2, 3)])
    me.materials.append(B.material("ground"))
    ob = bpy.data.objects.new("ground", me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def build_with_stickman(name, wc):
    """装配一栋 + 同尺度火柴人（站在门前：门洞 x 对齐、整栋最前缘再往前 12）。"""
    ob, spec = B.ASSEMBLERS[name](wc)
    mx = B.measure(ob)
    dx = spec.get("door_x", 0.0) or 0.0
    sb = B.Builder("stick_%s_w%d" % (name, wc))
    B.stickman(sb, x=dx, y=mx["y"][0] - 12.0)
    sob = sb.to_object()
    return ob, sob, spec, mx


def one(cam, name, wc, path):
    ob, sob, spec, mx = build_with_stickman(name, wc)
    info = shoot_fit(cam, [ob, sob], ZOOM, path)
    rep = B.check_spec(spec, ob)
    bpy.data.objects.remove(sob, do_unlink=True)
    bpy.data.objects.remove(ob, do_unlink=True)
    return rep, info


def ladder(cam):
    """行政阶梯一张图：同一地平线沿 X 并排（含 cathedral 参照），天际线高差一目了然。"""
    objs = []
    cursor = 0.0
    for (name, wc) in LADDER:
        ob, _spec = B.ASSEMBLERS[name](wc)
        mx = B.measure(ob)
        ob.location.x = cursor + (mx["x"][1] - mx["x"][0]) / 2.0 \
            - (mx["x"][0] + mx["x"][1]) / 2.0 + 4.0
        bpy.context.view_layer.update()
        objs.append(ob)
        cursor = B.measure(ob)["x"][1] + 90.0
    xs = [B.measure(o)["x"][i] for o in objs for i in (0, 1)]
    make_ground(min(xs) - 800.0, max(xs) + 800.0, -1400.0, 1200.0)
    info = shoot_fit(cam, objs, ZOOM_LADDER, os.path.join(OUT_DIR,
                                                         "pbr_admin_ladder.png"),
                     pad=80.0, pad_top=60.0)
    for ob in objs:
        bpy.data.objects.remove(ob, do_unlink=True)
    return info


def edge_gate(cam, suns):
    """棱线高光门禁图：强侧光（左前方低角度掠射）特写总督府前廊一角——
    隅石/层间腰线/拱券石圈/柱身的倒角必须读出"亮→暗"高光渐变带，死线即打回。"""
    suns["key"].data.energy = 0.45          # 压掉常规正面主光
    suns["fill"].data.energy = 0.06
    d = bpy.data.lights.new("rake", "SUN")
    d.energy = 5.2
    d.angle = math.radians(1.2)
    d.color = (1.0, 0.93, 0.82)
    rob = bpy.data.objects.new("rake", d)
    rob.rotation_euler = tuple(math.radians(a) for a in (26, 0, -80))
    bpy.context.scene.collection.objects.link(rob)
    ob, _spec = B.ASSEMBLERS["governor_palace"](16)
    mx = B.measure(ob)
    # 取景：左下象限（角部隅石 + 基座拱窗 + 门廊柱 + 上一层腰线/拱窗），贴紧建筑左缘
    anchor = (-135.0, mx["y"][0] - 60.0, 300.0)
    info = _render(cam, anchor, 380.0, 420.0, 3.0,
                   os.path.join(OUT_DIR, "pbr_admin_edge.png"))
    bpy.data.objects.remove(ob, do_unlink=True)
    return info


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    clear()
    sc, suns = setup_world()
    cam = make_camera()
    make_ground(-4200.0, 4200.0, -2600.0, 1800.0)

    print("\n=== 行政/地标轮 特写自检（2.6x；剪影 = yaw=0/tilt=20 投影）===")
    print("%-16s %2s %6s %7s %6s %8s %7s %s"
          % ("def", "格", "网格宽", "剪影总高", "檐口", "出檐%", "长宽比", "判定"))
    only = [s for s in os.environ.get("ADMIN_ONLY", "").split(",") if s]
    pairs = [p for p in ADMIN_LIST if not only or p[0] in only]
    if only:
        print("（ADMIN_ONLY=%s → 只出 %d 个宽度档）" % (os.environ["ADMIN_ONLY"],
                                                        len(pairs)))
    bad = []
    for (name, wc) in pairs:
        fn = ("pbr_admin_%s.png" % name
              if ADMIN_PRIMARY.get(name) == wc
              else "pbr_admin_%s_w%d.png" % (name, wc))
        rep, info = one(cam, name, wc, os.path.join(OUT_DIR, fn))
        print("%-16s %2d %6.0f %7.0f %6.0f %7.1f%% %7.2f %s  -> %s  (%dx%d px)"
              % (name, wc, rep["grid_w"], rep["sil_h"], rep["eave_px"],
                 rep["eave_ratio"] * 100.0, rep["ratio"],
                 "PASS" if rep["pass"] else "FAIL", fn, info["res"][0],
                 info["res"][1]))
        if not rep["pass"]:
            bad.append((name, wc))
    if not only:
        info = ladder(cam)
        print("阶梯图 -> %s  (%dx%d px)" % (info["path"], info["res"][0],
                                            info["res"][1]))
        info = edge_gate(cam, suns)
        print("棱线门禁图 -> %s  (%dx%d px)" % (info["path"], info["res"][0],
                                                info["res"][1]))
    if bad:
        print("!! 行政轮未过门禁：%s" % ", ".join("%s w%d" % b for b in bad))
    else:
        print("行政轮全部 PASS（6 def / %d 个宽度档）" % len(pairs))
    print("\nADMIN_OK")


if __name__ == "__main__":
    main()
