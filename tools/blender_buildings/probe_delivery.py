# -*- coding: utf-8 -*-
"""probe_delivery.py —— **交付图**（管线 v3 · 写实 PBR）

与 `probe_buildings.py` 的分工
------------------------------
`probe_buildings.py` 是**规范自检图**（比例/门高/出檐打表，判定 PASS/FAIL）；
本文件是**给人看的交付图**——把建筑本体 + 道具层 + 比例尺 + 街景拼在一起，
按创始人参考图 `assets/_raw/建筑/smithy.png` 的观感标准打光出图。

产物（stick-world/temp/）::
    pbr_sheet_2x.png        全部 def × 宽度档总图（2 px/单位，看细节）
    pbr_street_2x.png       街道排（混合建筑 + 道具 + 比例尺，观感主图）
    pbr_game_1x.png         **1 px/单位 = 游戏内真实大小**（1 格 = 32px）——能不能认出
                            材质、道具会不会糊，只看这张
    pbr_game_25.png         上图的 25%（游戏内远景/缩略图尺度）

跑法::
    blender -b --factory-startup -P probe_delivery.py
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

# 视角：2D 侧视 + 微俯视（§8.1 修订后口径；禁止水平偏航）
YAW = 0.0
TILT = 20.0

BAY_GAP = 30.0          # 街排相邻建筑净距（街道感）
ZOOM_SHEET = 2.0
ZOOM_STREET = 1.9
ZOOM_CLOSE = 2.4

#: 登记表里要出的 def × 宽度档（缺的自动跳过）
WANT = [("house", 8), ("house", 12), ("house", 16),
        ("townhouse", 12), ("townhouse", 16),
        ("barn", 12), ("barn", 16), ("smithy1", 8),
        ("rowhouse", 12), ("rowhouse", 16),
        ("windmill", 6), ("cathedral", 16),
        ("tower", 6), ("gatehouse", 8), ("lighthouse", 6)]

#: 道具配方键：def -> props.DRESS 的键（名字不同时在此映射）
DRESS_OF = {"smithy1": "smithy", "smithy2": "smithy", "smithy3": "smithy",
            "smithy4": "smithy", "rowhouse": "townhouse"}


# ---------------------------------------------------------------- 场景

def clear():
    """只在开头调用一次（read_factory_settings 会清掉材质缓存，之后只能 wipe）。"""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    B._CACHE.clear()


def wipe():
    for ob in list(bpy.data.objects):
        if ob.type == "MESH":
            bpy.data.objects.remove(ob, do_unlink=True)


def setup_world():
    """暖调光照（§8.4 定标 + 交付图层加暖）：主光暖白、天光偏冷、补地面反弹。

    参考图是"暖色饱和、对比明确"的插画感；纯物理正确的 0.60 环境光 + 3.3 主光
    出来偏灰，所以交付图把主光调到暖色并加一盏自下而上的弱暖反弹光（模拟地面
    反照），把道具和墙面的暗部从灰里拉出来。
    """
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
    for attr, val in (("taa_render_samples", 96), ("use_gtao", True)):
        try:
            setattr(sc.eevee, attr, val)
        except Exception:
            pass
    try:                                    # 让炉火/灯笼有辉光（EEVEE Next 无 use_bloom）
        sc.use_nodes = True
        tree = sc.node_tree
        for n in list(tree.nodes):
            tree.nodes.remove(n)
        rl = tree.nodes.new("CompositorNodeRLayers")
        gl = tree.nodes.new("CompositorNodeGlare")
        gl.glare_type = "BLOOM" if "BLOOM" in [i.identifier for i in
                                               gl.bl_rna.properties["glare_type"].enum_items] else "FOG_GLOW"
        gl.quality = "HIGH"
        gl.threshold = 0.85
        gl.mix = -0.55
        cmp = tree.nodes.new("CompositorNodeComposite")
        tree.links.new(rl.outputs["Image"], gl.inputs["Image"])
        tree.links.new(gl.outputs["Image"], cmp.inputs["Image"])
    except Exception as exc:
        print("[delivery] 合成器辉光不可用：%s" % exc)

    w = bpy.data.worlds.new("W")
    sc.world = w
    w.use_nodes = True
    bg = w.node_tree.nodes.get("Background") or w.node_tree.nodes.new("ShaderNodeBackground")
    bg.inputs[0].default_value = (0.58, 0.68, 0.84, 1.0)      # 天空冷蓝（暖地面才不闷）
    bg.inputs[1].default_value = 0.55

    def sun(name, energy, rot, angle=3.0, color=(1.0, 0.95, 0.85)):
        d = bpy.data.lights.new(name, "SUN")
        d.energy = energy
        d.angle = math.radians(angle)
        d.color = color
        ob = bpy.data.objects.new(name, d)
        ob.rotation_euler = tuple(math.radians(a) for a in rot)
        sc.collection.objects.link(ob)
        return ob

    sun("key", 3.5, (42, 0, -34), 2.5, (1.0, 0.93, 0.80))      # 主光：暖白，前左上
    sun("fill", 0.22, (58, 0, 126), 20.0, (0.80, 0.87, 1.0))   # 补光：冷，右前
    sun("bounce", 0.35, (-28, 0, 6), 45.0, (0.95, 0.80, 0.62))  # 地面反弹：自下而上暖
    return sc


_GROUND_MAT = [None]


def warm_ground_material():
    """交付图专用暖沙地面（不依赖材料库是否已注册 `ground`）。

    用 Object 坐标而不是 UV 驱动噪声 —— 地面是运行时用 `from_pydata` 拼的四边形，
    **没有 UV 层**，套纹理只会得到一片平涂。Object 坐标在正交相机下等价于世界坐标，
    按 1/50 缩放后正好是"几米一个色斑"的低频，符合参考图的地面读感。
    """
    if _GROUND_MAT[0] is not None:
        return _GROUND_MAT[0]
    m = bpy.data.materials.new("warm_ground")
    m.use_nodes = True
    nt = m.node_tree
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    bsdf.inputs["Roughness"].default_value = 0.96
    bsdf.inputs["Base Color"].default_value = (0.60, 0.51, 0.35, 1.0)   # 暖米沙（线性）
    tc = nt.nodes.new("ShaderNodeTexCoord")
    mp = nt.nodes.new("ShaderNodeMapping")
    mp.inputs["Scale"].default_value = (0.022, 0.022, 0.022)
    nz = nt.nodes.new("ShaderNodeTexNoise")
    nz.inputs["Scale"].default_value = 5.0
    nz.inputs["Detail"].default_value = 6.0
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].position = 0.32
    ramp.color_ramp.elements[0].color = (0.45, 0.36, 0.24, 1.0)          # 湿/阴处偏深
    ramp.color_ramp.elements[1].position = 0.75
    ramp.color_ramp.elements[1].color = (0.72, 0.62, 0.42, 1.0)          # 受光处偏亮
    bump = nt.nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.25
    nt.links.new(tc.outputs["Object"], mp.inputs["Vector"])
    nt.links.new(mp.outputs["Vector"], nz.inputs["Vector"])
    nt.links.new(nz.outputs["Fac"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    nt.links.new(nz.outputs["Fac"], bump.inputs["Height"])
    nt.links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
    _GROUND_MAT[0] = m
    return m


def make_ground(x0, x1, y0, y1, mat=None):
    me = bpy.data.meshes.new("ground_mesh")
    me.from_pydata([(x0, y0, 0), (x1, y0, 0), (x1, y1, 0), (x0, y1, 0)], [], [(0, 1, 2, 3)])
    me.materials.append(mat if mat is not None else warm_ground_material())
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


def shoot_fit(cam, objs, zoom, path, pad=40.0, pad_top=30.0, res_max=9000):
    """正交取景：按实际顶点的屏幕投影包围盒（3/4 视角下唯一正确的取景方式）。"""
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
    print("-> %s  %dx%d  (%.2f px/unit)" % (os.path.basename(path), rx, ry, zoom * k))
    return {"path": path, "res": (rx, ry), "px_per_unit": zoom * k}


# ---------------------------------------------------------------- 装配

def build(name, wc, seed=11, with_props=True, x=0.0, y=0.0):
    """装配一栋：建筑本体 + 道具层（同场景两个对象，渲染时并置）。"""
    ob, spec = B.ASSEMBLERS[name](wc)
    ob.location = (x, y, 0.0)
    bpy.context.view_layer.update()
    mx = B.measure(ob)
    pob = None
    if with_props:
        kind = DRESS_OF.get(name, name)
        pb = B.Builder("props_%s_%d" % (name, wc))
        d = spec.get("door")
        P.dress(pb, kind, spec["grid_w"], mx["y"][0], seed=seed,
                door_x=spec.get("door_x", 0.0), door_w=(d[0] if d else 0.0))
        pob = pb.to_object()
        pob.location = (x, y, 0.0)
        bpy.context.view_layer.update()
    return ob, pob, spec, mx


def stick(x, y):
    sb = B.Builder("stick_%.0f_%.0f" % (x, y))
    B.stickman(sb, x=x, y=y)
    return sb.to_object()


def available(pairs):
    return [(n, w) for (n, w) in pairs if n in B.ASSEMBLERS]


# ---------------------------------------------------------------- 出图

def sheet(cam, pairs):
    """总图：每栋并排 + 建筑前缘一个火柴人（同尺度）。"""
    objs = []
    cursor = 0.0
    rows = []
    for (name, wc) in pairs:
        try:
            ob, pob, spec, mx = build(name, wc, with_props=True)
        except Exception as exc:
            print("!! %s/%d 失败：%s" % (name, wc, exc))
            continue
        half = (mx["x"][1] - mx["x"][0]) / 2.0
        bx = cursor + half + 4.0
        dx = bx - (mx["x"][0] + mx["x"][1]) / 2.0
        ob.location.x += dx
        if pob is not None:
            pob.location.x += dx
        bpy.context.view_layer.update()
        mx = B.measure(ob)
        sob = stick(mx["x"][1] - 26.0, mx["y"][0] - 26.0)   # 站建筑前缘（不占横向）
        objs += [ob, sob] + ([pob] if pob is not None else [])
        rows.append((name, wc, spec, mx))
        cursor = mx["x"][1] + BAY_GAP
    xs = [B.measure(o)["x"][i] for o in objs for i in (0, 1)]
    ys = [B.measure(o)["y"][i] for o in objs for i in (0, 1)]
    make_ground(min(xs) - 600.0, max(xs) + 600.0, min(ys) - 400.0, max(ys) + 400.0)
    shoot_fit(cam, objs, ZOOM_SHEET, os.path.join(OUT_DIR, "pbr_sheet_2x.png"),
              pad=90.0, pad_top=70.0)
    # 每栋特写（自检用）
    for (name, wc, spec, mx) in rows:
        wipe()
        ob, pob, spec, mx = build(name, wc, with_props=True)
        sob = stick(mx["x"][1] + 46.0, mx["y"][0] - 26.0)
        make_ground(mx["x"][0] - 400.0, mx["x"][1] + 400.0, -500.0, 500.0)
        shoot_fit(cam, [ob, pob, sob], ZOOM_CLOSE,
                  os.path.join(OUT_DIR, "pbr_c_%s_w%d.png" % (name, wc)),
                  pad=60.0, pad_top=44.0)


def street(cam):
    """街景：混合建筑一排（含道具），1 px/单位 = **游戏内真实大小**。"""
    plan = [("lighthouse", 6), ("house", 12), ("townhouse", 12), ("rowhouse", 12),
            ("smithy1", 8), ("house", 16), ("barn", 12), ("tower", 6),
            ("townhouse", 16), ("windmill", 6), ("cathedral", 16), ("gatehouse", 8)]
    plan = [p for p in plan if p[0] in B.ASSEMBLERS]
    objs = []
    cursor = 0.0
    for (name, wc) in plan:
        try:
            ob, pob, spec, mx = build(name, wc, seed=wcc(name, wc))
        except Exception as exc:
            print("!! 街景 %s/%d 失败：%s" % (name, wc, exc))
            continue
        half = (mx["x"][1] - mx["x"][0]) / 2.0
        dx = cursor + half + 4.0 - (mx["x"][0] + mx["x"][1]) / 2.0
        ob.location.x += dx
        if pob is not None:
            pob.location.x += dx
        bpy.context.view_layer.update()
        mx = B.measure(ob)
        objs += [ob] + ([pob] if pob is not None else [])
        cursor = mx["x"][1] + BAY_GAP
    xs = [B.measure(o)["x"][i] for o in objs for i in (0, 1)]
    ys = [B.measure(o)["y"][i] for o in objs for i in (0, 1)]
    make_ground(min(xs) - 600.0, max(xs) + 600.0, min(ys) - 400.0, max(ys) + 400.0)
    shoot_fit(cam, objs, 1.0, os.path.join(OUT_DIR, "pbr_game_1x.png"),
              pad=60.0, pad_top=30.0)
    shoot_fit(cam, objs, 1.9, os.path.join(OUT_DIR, "pbr_street_2x.png"),
              pad=60.0, pad_top=30.0)
    return objs


def wcc(name, wc):
    return (hash(name) % 97) * 131 + wc


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    fast = os.environ.get("DELIVERY_FAST") == "1"      # 只出街景两张，跳过总图/特写
    clear()
    setup_world()
    cam = make_camera()
    pairs = available(WANT)
    print("交付图覆盖 %d 个 def×宽度档：%s"
          % (len(pairs), ", ".join("%s/%d" % p for p in pairs)))
    if fast:
        street(cam)
    else:
        sheet(cam, pairs)
        wipe()
        street(cam)
    print("\nDELIVERY_OK")


main()
