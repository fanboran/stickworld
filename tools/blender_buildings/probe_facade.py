# -*- coding: utf-8 -*-
"""probe_facade.py —— 立面修正验收特写（管线 v3 · 写实 PBR · 立面批次）

三张 **3x 特写**，逐项自查 `buildings.py` 的立面修正四项：

    pbr_facade_win.png      ① 窗型表化 —— 两层半木结构（townhouse w12）正立面：
                            上下层差异化窗型（下层 street 矮宽 / 上层 hall 瘦高 + 窗板）、
                            同立面 ≤2 种窗型、窗口有真凹进（wall_panel 条带修复后不再是
                            通到屋里的长条透空）
    pbr_facade_chimney.png  ② 烟囱落地泛水 —— 同一栋的正立面烟囱：地面起步（基座石裙）
                            → 二级石裙 → 穿屋面处铅皮带肋泛水裙（两阶外扩下探）→ 压顶
    pbr_facade_gable.png    ③ 山墙补墙 + 小窗 + 檩条端头（house w12 左山墙端，诊断偏航）：
                            三角面按窗表开**真洞**小窗（gable_infill hole）、
                            檩条端头下探到檐口断面以下（正面 20° 俯视可见）、
                            茅草檐缘卷压扁成束状（深:高 = 1:0.60）

相机
----
* 窗阵 / 烟囱：**游戏内视角**（yaw=0 / tilt=20，正交）——验收口径就是游戏里的读法。
* 山墙：诊断偏航 yaw=42（正立面只能看到山墙的"边"；补墙/小窗/檩条端都在 ±X 端面上，
  必须偏航才能同框自检；这不是游戏内交付视角）。

跑法::
    blender -b --factory-startup -P probe_facade.py

产物（stick-world/temp/）::
    pbr_facade_win.png / pbr_facade_chimney.png / pbr_facade_gable.png
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

OUT_DIR = "F:/VSCode/game-2/.temp/building-pipeline-v2/stick-world/temp"
ONLY = os.environ.get("FACADE_ONLY", "").strip()   # 只出某一张（调试用，如 FACADE_ONLY=gable）
YAW = 0.0                  # 游戏内视角：纯正面（§0.3）
TILT = 20.0                # 游戏内视角：微俯视
YAW_GABLE = 42.0           # 山墙诊断偏航（仅自检，非交付视角）
ZOOM = 3.0                 # 3x 特写
TOWN = ("townhouse", 12)   # 两层半木结构样本（正立面 / 烟囱）
HOUSE = ("house", 12)      # 单层茅草民居样本（山墙端）


def want(tag):
    return (not ONLY) or ONLY == tag


# ------------------------------------------------------------------ 场景

def clear():
    """**只在开头调用一次**：多图之间绝不再 `read_factory_settings`（见交接档 §六）。"""
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
    bg = w.node_tree.nodes.get("Background") or w.node_tree.nodes.new(
        "ShaderNodeBackground")
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

    sun("key", 3.3, (40, 0, -38))                       # §8.4 太阳仰角 40°、方位 -38°
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


def shoot_pts(cam, pts, zoom, path, yaw=YAW, tilt=TILT, pad=24.0, pad_top=18.0,
              res_max=4600):
    """正交取景：把给定世界点集全部框进画面，中心对准点集投影中心。"""
    right, up = B.cam_axes(yaw, tilt)
    fwd = -(right.cross(up))
    us = [p.dot(right) for p in pts]
    vs = [p.dot(up) for p in pts]
    u0, u1 = min(us) - pad, max(us) + pad
    v0, v1 = min(vs) - pad, max(vs) + pad_top
    w, h = (u1 - u0), (v1 - v0)
    cu, cv = (u0 + u1) / 2.0, (v0 + v1) / 2.0
    ref = pts[0]
    anchor = ref + right * (cu - ref.dot(right)) + up * (cv - ref.dot(up))
    cam.location = tuple(Vector(anchor) - fwd * 9000.0)
    cam.rotation_euler = (math.radians(90.0 - tilt), 0.0, math.radians(yaw))
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
    print("-> %s  %dx%d  %.2f px/unit  (yaw=%.0f tilt=%.0f)"
          % (path, rx, ry, rx / w, yaw, tilt))
    return {"path": path, "res": (rx, ry)}


# ------------------------------------------------------------------ 装配

def place(name, wc, bx):
    ob, spec = B.ASSEMBLERS[name](wc)
    ob.location.x = bx
    bpy.context.view_layer.update()
    return {"ob": ob, "spec": spec, "bx": bx}


def bbox_pts(o, only_front=False):
    """对象的世界顶点（skip_ground=False：含接地阴影，避免取景把地面裁掉）。"""
    return B.shape_points(o["ob"], skip_ground=False)


def rect_pts(o, x0, x1, y0, y1, z0, z1):
    """给定世界区间取 8 个角点（取景用；比逐顶点稳，画面留白可控）。"""
    pts = []
    for x in (x0, x1):
        for y in (y0, y1):
            for z in (z0, z1):
                pts.append(Vector((x, y, z)))
    return pts


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    clear()
    setup_world()
    cam = make_camera()

    town = place(TOWN[0], TOWN[1], 0.0)
    ts = town["spec"]
    house = place(HOUSE[0], HOUSE[1], ts["grid_w"] + 420.0)
    hs = house["spec"]
    make_ground(-700.0, house["bx"] + hs["grid_w"] / 2.0 + 500.0, -900.0, 900.0)
    for e in (town, house):
        s = e["spec"]
        print("[%s w%d] polys=%d eave=%.0f rise=%.0f over=%.0f win=%s win_up=%s "
              "gable=%s chimneys=%d"
              % (s["def"], s["width_cells"], len(e["ob"].data.polygons), s["eave_h"],
                 s["rise"], s["overhang"], s.get("window"), s.get("window_up"),
                 s.get("gable_window"), len(s.get("chimneys") or [])))

    # ---- ① 窗阵：正立面（游戏内视角）
    if want("win"):
        shoot_pts(cam, bbox_pts(town), ZOOM,
                  os.path.join(OUT_DIR, "pbr_facade_win.png"), pad=26.0, pad_top=20.0)

    # ---- ② 烟囱：地面 → 压顶（同视角，正立面烟囱必须一路看到根部）
    ch = (ts.get("chimneys") or [{}])[0]
    if ch and want("chimney"):
        cx = town["bx"] + ch["x"]
        cw = ch.get("w", 30.0)
        pts = rect_pts(town, cx - cw * 5.2, cx + cw * 5.2, -130.0, -20.0,
                       0.0, ch["top"] + 46.0)
        shoot_pts(cam, pts, ZOOM, os.path.join(OUT_DIR, "pbr_facade_chimney.png"),
                  pad=18.0, pad_top=14.0)

    # ---- ③ 山墙端：右山墙（诊断偏航 42° → 相机在"前右上"，看到的是 +X 端面）
    #      —— 补墙 + 真洞小窗 + 檩条端头 + 压扁檐卷
    if want("gable"):
        hw = hs["grid_w"] / 2.0
        pts = [p for p in B.shape_points(house["ob"], skip_ground=False)
               if p.x > house["bx"] + hw * 0.42]
        shoot_pts(cam, pts, ZOOM, os.path.join(OUT_DIR, "pbr_facade_gable.png"),
                  yaw=YAW_GABLE, tilt=TILT, pad=26.0, pad_top=22.0)

    print("\nFACADE_PROBE_OK")


main()
