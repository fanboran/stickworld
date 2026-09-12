# -*- coding: utf-8 -*-
"""probe_roof2.py —— 屋顶结构二轮验收特写（管线 v3 · 写实 PBR）

三张 **3x 特写**，每张同时框住一栋**茅草顶**（house w12）与一栋**瓦顶**（townhouse w12），
同尺度并排，用来逐项自检 `buildings.roof_gable` 的四项纯几何增强：

    pbr_roof2_eave.png    檐口转角 —— ①草檐卷 / 封檐板+瓦口断面 ②檐下 AO 暗带 ④草束
    pbr_roof2_gable.png   山墙     —— ③檩条端头（出挑 6~14、长度抖动、压在屋面下）
    pbr_roof2_ridge.png   屋脊     —— 正脊压顶 + ④脊部草穗（瓦/木顶不做草穗）

相机
----
* 檐口/屋脊：**游戏内视角**（yaw=0 / tilt=20，正交）。
* 山墙：**诊断视角** yaw=38 —— 纯正面看不到侧向出挑的檩条端头，只能偏航把山墙面
  转出来；这不是游戏内交付视角，仅供自检（长宽比自检仍走 check_spec 的口径）。

跑法::
    blender -b --factory-startup -P probe_roof2.py

产物（stick-world/temp/）::
    pbr_roof2_eave.png / pbr_roof2_gable.png / pbr_roof2_ridge.png
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
YAW = 0.0                  # 游戏内视角：纯正面
TILT = 20.0                # 游戏内视角：微俯视
YAW_GABLE = 38.0           # 山墙诊断偏航（仅自检用，非交付视角）
ZOOM = 3.0                 # 3x 特写
THATCH = ("house", 12)     # 茅草顶样本
TILE = ("townhouse", 12)   # 陶瓦顶样本


# ------------------------------------------------------------------ 场景

def clear():
    """**只在开头调用一次**：建空场景（本探针建一次场景、只用不同相机取三张图）。

    多图之间绝不再 `read_factory_settings`，也别乱 `wipe()` 网格 —— 材质/节点组被清掉
    而 `buildings._CACHE` 与 materials 内部缓存仍持旧引用时，`_external_material`
    校验失败会**静默回退纯色**，纹理整片消失（探针层踩过的坑，见交接档 §六）。
    """
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
    """在 x=bx 摆一栋，返回帧取用几何量（檐高/屋脊/出檐/半宽）。"""
    ob, spec = B.ASSEMBLERS[name](wc)
    ob.location.x = bx
    bpy.context.view_layer.update()
    hw = spec["grid_w"] / 2.0 + spec["overhang"]      # 含出檐半宽
    return {"ob": ob, "spec": spec, "bx": bx, "ze": spec["eave_h"],
            "rise": spec["rise"], "over": spec["overhang"],
            "hw": hw, "half": spec["depth"] / 2.0 + spec["overhang"],
            "w2": spec["grid_w"] / 2.0,
            "polys": len(ob.data.polygons)}


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    clear()
    setup_world()
    cam = make_camera()

    # 两栋并排：茅草顶（house 12）与陶瓦顶（townhouse 12），同尺度
    gap = 210.0
    a = place(THATCH[0], THATCH[1], 0.0)
    a["bx"] = 0.0
    b = place(TILE[0], TILE[1], a["hw"] + gap + a["hw"])
    b["bx"] = a["hw"] + gap + a["hw"]      # 两栋中心距（等宽档，直接摆开）
    make_ground(a["bx"] - a["hw"] - 400.0, b["bx"] + b["hw"] + 400.0, -900.0, 900.0)
    for e in (a, b):
        print("[%s w%d] polys=%d eave=%.0f rise=%.0f over=%.0f half=%.0f"
              % (e["spec"]["def"], e["spec"]["width_cells"], e["polys"], e["ze"],
                 e["rise"], e["over"], e["half"]))

    def eave_pts(e, dz_up=52.0, dz_dn=170.0):
        """檐口转角 + 其下墙面（AO 暗带/草束所在带）。"""
        hw, half, ze = e["hw"], e["half"], e["ze"]
        return [Vector((e["bx"] + hw, -half, ze + dz_up)),
                Vector((e["bx"] - hw, -half, ze + dz_up)),
                Vector((e["bx"] + hw, -half, ze - dz_dn)),
                Vector((e["bx"] - hw, -half, ze - dz_dn)),
                Vector((e["bx"] + hw, half, ze + dz_up))]

    def gable_pts(e, dz_dn=90.0):
        """山墙面（含出挑椽/檩端所在檐下三角带）。"""
        hw, half, ze, rise = e["hw"], e["half"], e["ze"], e["rise"]
        x = e["bx"] + e["w2"]
        return [Vector((x, -half, ze + rise + 26.0)),
                Vector((x, half, ze + rise + 26.0)),
                Vector((x, -half, ze - dz_dn)),
                Vector((x, half, ze - dz_dn)),
                Vector((e["bx"] + hw, -half, ze + rise * 0.35))]

    def ridge_pts(e, dz_dn=55.0):
        """正脊（含脊部草穗带 + 上段屋面）——**不要**带前沿檐口点，否则取景被拖到整栋。"""
        hw, half, ze, rise = e["hw"], e["half"], e["ze"], e["rise"]
        return [Vector((e["bx"] - hw * 0.60, -half * 0.30, ze + rise + 26.0)),
                Vector((e["bx"] + hw * 0.60, -half * 0.30, ze + rise + 26.0)),
                Vector((e["bx"] - hw * 0.60, half * 0.30, ze + rise + 26.0)),
                Vector((e["bx"] + hw * 0.60, -half * 0.30, ze + rise - dz_dn)),
                Vector((e["bx"], 0.0, ze + rise))]

    shots = [
        ("pbr_roof2_eave", eave_pts, dict(yaw=YAW, tilt=TILT, pad=26.0, pad_top=20.0)),
        ("pbr_roof2_gable", gable_pts, dict(yaw=YAW_GABLE, tilt=TILT, pad=40.0,
                                            pad_top=30.0)),
        ("pbr_roof2_ridge", ridge_pts, dict(yaw=YAW, tilt=TILT, pad=14.0, pad_top=12.0)),
    ]
    for (tag, fn, kw) in shots:
        pts = fn(a) + fn(b)
        shoot_pts(cam, pts, ZOOM, os.path.join(OUT_DIR, tag + ".png"), **kw)

    print("\nROOF2_PROBE_OK")


main()
