# -*- coding: utf-8 -*-
"""probe_buildings.py —— 单体建筑比例对比图（管线 v3 · 写实 PBR · §8 修订版）

渲染内容
--------
* PROBE_LIST 的 def × 宽度档，每栋右侧并排一个 **130px 高火柴人剪影**（同尺度）
* 相机：**正交 + 3/4 偏航（水平 12°、俯角 10°）**（§8.1）——屋面必须露出来
* 接地阴影由 buildings.contact_shadow 以几何方式提供（太阳在前左上方，太阳影
  落在建筑背后看不见，故接触暗带必须自带，§8.2/§8.4）
* 另出：每栋特写、门口净空校验（火柴人站在门口）、窗/炉口细节裁切

跑法::
    blender -b --factory-startup -P probe_buildings.py

产物（stick-world/temp/）::
    pbr_buildings_v2.png      总对比图（交付物；旧图另存 pbr_buildings_v1.png）
    pbr_b2_<def>_w<N>.png     单体特写（自检用）
    pbr_door2_<def>_w<N>.png  门口净空校验（自检用）
"""

import math
import os
import shutil
import sys

import bpy
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import buildings as B  # noqa: E402

OUT_DIR = "F:/VSCode/game-2/.temp/building-pipeline-v2/stick-world/temp"
SHEET = os.path.join(OUT_DIR, "pbr_buildings_v2.png")

YAW = 12.0             # §8.1 水平偏航（建筑统一朝右前）
TILT = 10.0            # §8.1 俯角（显露大面积屋面）
ZOOM_SHEET = 2.0       # 总图每世界单位像素数（§5.3：2x，1 格 = 64px）
ZOOM_CLOSE = 2.6
GAP = 46.0             # 火柴人离建筑外檐的水平净距
BAY_GAP = 120.0        # 相邻建筑净距


# ------------------------------------------------------------------ 场景

def clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def setup_world():
    sc = bpy.context.scene
    try:
        sc.render.engine = "BLENDER_EEVEE_NEXT"
    except Exception:
        try:
            sc.render.engine = "BLENDER_EEVEE"
        except Exception:
            sc.render.engine = "CYCLES"
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
    bg.inputs[0].default_value = (0.62, 0.70, 0.82, 1.0)     # 天空冷蓝（§8.4）
    bg.inputs[1].default_value = 0.60                        # 环境强度 0.60（§8.4 定标）

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

    sun("key", 3.3, (40, 0, -38))               # §8.4 太阳仰角 40°、方位 -38°
    sun("fill", 0.15, (55, 0, 128), 20.0, (0.85, 0.90, 1.0))   # 右前弱冷补光
    return sc


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
    """把相机放到 3/4 视角位置：视线轴穿过世界点 anchor（anchor 落在画面正中）。"""
    right, up = B.cam_axes(YAW, TILT)
    fwd = -(right.cross(up))                     # 视线方向（指向屏幕深处）
    cam.location = tuple(Vector(anchor) - fwd * dist)
    cam.rotation_euler = (math.radians(90.0 - TILT), 0.0, math.radians(YAW))


def shoot(cam, anchor, w, h, zoom, path, res_max=7600):
    """正交取景：画面中心对准世界点 anchor，覆盖 w×h 世界单位。"""
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
    return {"path": path, "res": (rx, ry), "px_per_unit": rx / w}


def shoot_fit(cam, objs, zoom, path, pad=40.0, pad_top=30.0, res_max=7600):
    """按实际顶点的屏幕投影取景（3/4 视角下唯一正确的取景方式）。"""
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
    ref = pts[0]                                  # 先投影、再沿屏幕轴平移到画面中心
    anchor = ref + right * (cu - ref.dot(right)) + up * (cv - ref.dot(up))
    return shoot(cam, anchor, w, h, zoom, path, res_max=res_max)


# ------------------------------------------------------------------ 装配

def layout():
    """按 PROBE_LIST 沿 X 摆开，每栋右侧并排一个 130 高火柴人（同尺度）。"""
    built = []
    cursor = 0.0
    for (name, wc) in B.PROBE_LIST:
        ob, spec = B.ASSEMBLERS[name](wc)
        x0, x1 = B.measure(ob)["x"]
        half = (x1 - x0) / 2.0
        bx = cursor + half + 4.0
        ob.location.x = bx - (x0 + x1) / 2.0
        bpy.context.view_layer.update()
        mx = B.measure(ob)
        stick_x = mx["x"][1] + GAP
        sb = B.Builder("stick_%s_w%d" % (name, wc))
        B.stickman(sb, x=stick_x, y=mx["y"][0] + 10.0)   # 立面前沿同一地面基准
        sob = sb.to_object()
        built.append({"name": name, "wc": wc, "obj": ob, "stick": sob, "spec": spec,
                      "bbox": mx, "x_center": bx})
        cursor = mx["x"][1] + GAP + 40.0 + BAY_GAP
    return built


def main():
    clear()
    setup_world()
    cam = make_camera()
    built = layout()

    all_objs = []
    for e in built:
        all_objs += [e["obj"], e["stick"]]
    xs = [B.measure(o)["x"][i] for o in all_objs for i in (0, 1)]
    make_ground(min(xs) - 1000.0, max(xs) + 1000.0, -1200.0, 1000.0)

    os.makedirs(OUT_DIR, exist_ok=True)
    # 旧总图留档为 v1（只做一次，不覆盖已有的 v1）
    old = os.path.join(OUT_DIR, "pbr_buildings.png")
    v1 = os.path.join(OUT_DIR, "pbr_buildings_v1.png")
    if os.path.exists(old) and not os.path.exists(v1):
        shutil.copy2(old, v1)
        print("旧总图留档 -> %s" % v1)

    # 1) 总对比图
    info = shoot_fit(cam, all_objs, ZOOM_SHEET, SHEET, pad=90.0, pad_top=70.0)
    print("SHEET -> %s  res=%s  px/unit=%.2f  (yaw=%.0f tilt=%.0f)"
          % (info["path"], info["res"], info["px_per_unit"], YAW, TILT))

    # 2) 单体特写（含旁边的火柴人）
    for e in built:
        shoot_fit(cam, [e["obj"], e["stick"]], ZOOM_CLOSE,
                  os.path.join(OUT_DIR, "pbr_b2_%s_w%d.png" % (e["name"], e["wc"])),
                  pad=40.0, pad_top=34.0)

    # 3) 门口净空校验：火柴人站在门口（贴前墙面）
    for (name, wc) in (("house", 6), ("house", 8), ("townhouse", 12), ("barn", 8)):
        ob, spec = B.ASSEMBLERS[name](wc)
        mx = B.measure(ob)
        if not spec.get("door"):
            bpy.data.objects.remove(ob, do_unlink=True)
            continue
        dx = spec.get("door_x", 0.0)
        sb = B.Builder("stickdoor")
        B.stickman(sb, x=dx, y=mx["y"][0] + 10.0)
        sob = sb.to_object()
        shoot_fit(cam, [ob, sob], ZOOM_CLOSE,
                  os.path.join(OUT_DIR, "pbr_door2_%s_w%d.png" % (name, wc)),
                  pad=30.0, pad_top=26.0)
        bpy.data.objects.remove(sob, do_unlink=True)
        bpy.data.objects.remove(ob, do_unlink=True)

    # 4) 规格表（实测：3/4 视角下的屏幕剪影）
    print("\n=== 实测规格（单位 px；剪影为 yaw=12°/tilt=10° 投影）===")
    print("%-9s %2s %6s %6s %7s %6s %-9s %-11s %5s %6s %8s %s"
          % ("def", "格", "网格宽", "剪影宽", "剪影总高", "檐口", "层高", "门(净)",
             "出檐", "檐%", "长宽比", "判定"))
    for e in built:
        s = e["spec"]
        rep = B.check_spec(s, e["obj"])
        d = s.get("door")
        ds = "-" if not d else "%.0fx%.0f%s" % (d[0], d[1],
                                                "*" if s.get("composite_door") else "")
        st = "+".join("%.0f" % v for v in s["storey_h"])
        print("%-9s %2d %6.0f %6.0f %7.0f %6.0f %-9s %-11s %5.0f %5.1f%% %8.2f %s"
              % (e["name"], e["wc"], rep["grid_w"], rep["sil_w"], rep["sil_h"],
                 s["eave_h"], st, ds, rep["eave_px"], rep["eave_ratio"] * 100.0,
                 rep["ratio"], "PASS" if rep["pass"] else "FAIL"))
    print("(* = 复合门洞，§8.3 豁免；长宽比 = 剪影总高 / 网格宽，§8.2 区间 0.85~1.50)")
    print("\nPROBE_OK")


main()
