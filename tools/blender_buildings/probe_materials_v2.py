# -*- coding: utf-8 -*-
"""材质样片 v2：每个材质一格 = **平面样片 + 球 + 立方体**，同格内并列给出
**1:1（游戏 100%）与 25%（出厂门禁尺寸）两种缩略**。

25% 缩略的实现（关键）
----------------------
不是把大图缩小，而是在同一张图里放一组"1/4 世界尺寸 + UV 放大 4 倍"的小样：
设 UV 尺度因子 s，图案 feature F（UV）在小样上占 F/s 世界单位 = F/s px，
其占小样直径的比例 = (F/s)/D_small；大样是 F/D_big。令 D_small = D_big/4、
s = 4 → 两者比例相同、像素数差 4 倍 —— 这就是"同一材质画到 1/4 大小"的
**物理等价**（真实的像素密度就是 1/4，不是后期降采样）。

跑法:
    blender -b --factory-startup -P probe_materials_v2.py
    blender -b --factory-startup -P probe_materials_v2.py -- thatch iron   # 只渲几个
    blender -b --factory-startup -P probe_materials_v2.py -- --true25      # 追加全表 25% 渲染

输出（stick-world/temp/）:
    pbr_mat2_probe.png      总表（每格 100% + 25%）
    pbr_mat2_probe_<k>.png  单材质特写（`-- <k>` 时）
    pbr_mat2_true25.png     整表按物理 25% 分辨率渲一张（--true25）
"""
import bpy
import bmesh
import math
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() \
    else r"F:/VSCode/game-2/.temp/building-pipeline-v2/tools/blender_buildings"
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import materials as M  # noqa: E402

OUT_DIR = "F:/VSCode/game-2/.temp/building-pipeline-v2/stick-world/temp"
OUT = os.path.join(OUT_DIR, "pbr_mat2_probe.png")

TILT = 20.0                     # 俯角（与建筑渲染一致：水平偏航 0°）
YAW = 0.0
ZOOM = 1.0                      # 每 UV 单位的像素数（1 UV = 32 px = 0.42 m = 游戏 1:1）
PXU = M.PX_PER_UNIT             # 32：1 UV 单位 = 32 世界单位 = 32 px
# ---- 下面所有几何尺寸都按"px @1:1"写，落到世界坐标时统一 /PXU（uv = 世界坐标）
COLS = 4
CELL_W, CELL_H = 400.0, 250.0
MARGIN = 26.0

# ---- 单元内布局（px @1:1，d = 从单元顶部往下的像素）
PL_W, PL_H, PL_D = 344.0, 152.0, 86.0      # 平面样片（看平铺/接缝/UV 尺度）
R_BIG, R_D = 56.0, 97.0                    # 球（看粗糙度/各向异性响应）
C_SIDE, C_D = 88.0, 119.0                  # 立方体（看两个面的转折）
SMALL = 0.25
UV_SMALL = 4.0                             # 25% 缩略的 UV 放大 = 1/SMALL
S_D, S_X1, S_X2 = 202.0, 96.0, 148.0       # 25% 球/方块
LAB_D, LAB_X = 205.0, 282.0


def u(px_):
    """px @1:1 → 世界单位（1 UV = 32 世界单位 = 32 px）。"""
    return float(px_) / PXU

#: 各材质展示时的默认 Wear（越旧越脏）
DEFAULT_WEAR = {
    'thatch': 0.28, 'thatch_old': 0.85, 'tile_roof': 0.45, 'slate_roof': 0.55,
    'plank_wall': 0.40, 'timber': 0.45, 'plaster': 0.20, 'stone': 0.50,
    'white_stone': 0.25, 'brick': 0.55, 'iron': 0.40, 'canvas': 0.45,
    'cavity': 0.0, 'water': 0.10, 'lamp': 0.10, 'glass_win': 0.40,
    'shingle': 0.55, 'log_wall': 0.45, 'straw': 0.45, 'rope': 0.40,
    'sack': 0.50, 'wattle': 0.55, 'ground': 0.25, 'grass_tuft': 0.20,
    'foliage': 0.20, 'vine': 0.35,
}

SHEET = list(M.ORDER)
_COS = math.cos(math.radians(TILT))
_SIN = math.sin(math.radians(TILT))


# ------------------------------------------------------------------ 场景基础
def clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    M.reset_cache()          # 场景重建后必须清缓存，否则会拿到失效 StructRNA


def link(ob):
    bpy.context.collection.objects.link(ob)
    return ob


def mesh_sphere(name, r, seg=32, ring=16):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    try:
        bmesh.ops.create_uvsphere(bm, u_segments=seg, v_segments=ring, radius=r)
    except TypeError:
        try:
            bmesh.ops.create_uvsphere(bm, u_segments=seg, v_segments=ring, diameter=r * 2.0)
        except TypeError:
            bmesh.ops.create_icosphere(bm, subdivisions=4, radius=r)
    bm.to_mesh(me)
    bm.free()
    for p in me.polygons:
        p.use_smooth = True
    return link(bpy.data.objects.new(name, me))


def mesh_cube(name, size, rot_z=0.0):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bm.to_mesh(me)
    bm.free()
    ob = link(bpy.data.objects.new(name, me))
    ob.scale = (size, size, size)
    ob.rotation_euler = (0.0, 0.0, math.radians(rot_z))
    return ob


def mesh_plane(name, w, h):
    """真实顶点尺寸的竖直面（面向 -Y），不打缩放，便于 UV 世界投影。"""
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_grid(bm, x_segments=1, y_segments=1, size=1.0)
    bm.to_mesh(me)
    bm.free()
    ob = link(bpy.data.objects.new(name, me))
    ob.scale = (w / 2.0, h / 2.0, 1.0)
    ob.rotation_euler = (math.radians(90), 0, 0)
    bpy.context.view_layer.update()
    bpy.ops.object.select_all(action='DESELECT')
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
    return ob


def place_down(ob, x, top_z, d, y=0.0):
    """把物体放到"距单元顶 d 像素"的位置（自动补偿 20° 俯视的投影压缩）。"""
    up = -u(d) / _COS                     # 目标屏幕高度（世界单位，相对单元顶）
    ob.location = (x, y, top_z + (up - y * _SIN) / _COS)
    return ob


def assign(ob, mat):
    ob.data.materials.clear()
    ob.data.materials.append(mat)


def label(text, x, top_z, d, size=22.0):
    up = -u(d) / _COS
    loc = (x, 0.0, top_z + up / _COS)
    bpy.ops.object.text_add(location=loc, rotation=(math.radians(90), 0, 0))
    ob = bpy.context.object
    ob.name = "lbl_" + text[:14]
    ob.data.body = text
    ob.data.size = u(size)
    ob.data.align_x = 'CENTER'
    ob.data.align_y = 'CENTER'
    if "mat_label2" not in bpy.data.materials:
        m = bpy.data.materials.new("mat_label2")
        nt = m.node_tree
        nt.nodes.clear()
        o = nt.nodes.new('ShaderNodeOutputMaterial')
        e = nt.nodes.new('ShaderNodeEmission')
        e.inputs[0].default_value = (0.93, 0.95, 0.99, 1.0)
        e.inputs[1].default_value = 1.1
        nt.links.new(e.outputs[0], o.inputs['Surface'])
    assign(ob, bpy.data.materials["mat_label2"])
    return ob


def add_sun(name, elev, azim, energy, color, angle_deg=3.5):
    d = bpy.data.lights.new(name, 'SUN')
    d.energy = energy
    d.color = color[:3]
    d.angle = math.radians(angle_deg)
    d.use_shadow = True
    ob = link(bpy.data.objects.new(name, d))
    ob.rotation_euler = (math.radians(90.0 - elev), 0.0, math.radians(azim))
    return ob


def setup_world():
    w = bpy.data.worlds.new("sky2")
    bpy.context.scene.world = w
    w.use_nodes = True
    nt = w.node_tree
    nt.nodes.clear()
    out = nt.nodes.new('ShaderNodeOutputWorld')
    bg = nt.nodes.new('ShaderNodeBackground')
    nt.links.new(bg.outputs[0], out.inputs['Surface'])
    tc = nt.nodes.new('ShaderNodeTexCoord')
    sep = nt.nodes.new('ShaderNodeSeparateXYZ')
    nt.links.new(tc.outputs['Generated'], sep.inputs[0])
    mr = nt.nodes.new('ShaderNodeMapRange')
    nt.links.new(sep.outputs[2], mr.inputs[0])
    mr.inputs[1].default_value = -1.0
    mr.inputs[2].default_value = 1.0
    mr.inputs[3].default_value = 0.0
    mr.inputs[4].default_value = 1.0
    ramp = nt.nodes.new('ShaderNodeValToRGB')
    nt.links.new(mr.outputs[0], ramp.inputs[0])
    ramp.color_ramp.elements[0].position = 0.0
    ramp.color_ramp.elements[0].color = (0.34, 0.295, 0.245, 1.0)
    ramp.color_ramp.elements[1].position = 1.0
    ramp.color_ramp.elements[1].color = (0.60, 0.68, 0.80, 1.0)
    e = ramp.color_ramp.elements.new(0.40)
    e.color = (0.60, 0.585, 0.550, 1.0)
    nt.links.new(ramp.outputs[0], bg.inputs[0])
    bg.inputs[1].default_value = 0.55
    return w


def make_camera():
    d = bpy.data.cameras.new("cam")
    d.type = 'ORTHO'
    d.sensor_fit = 'HORIZONTAL'
    d.clip_start = 0.5
    d.clip_end = 40000.0
    ob = link(bpy.data.objects.new("cam", d))
    bpy.context.scene.camera = ob
    return ob


def place_camera(cam, anchor, dist=9000.0):
    t = math.radians(TILT)
    right = (1.0, 0.0, 0.0)
    up = (0.0, math.sin(t), math.cos(t))
    fwd = (-(right[1] * up[2] - right[2] * up[1]),
           -(right[2] * up[0] - right[0] * up[2]),
           -(right[0] * up[1] - right[1] * up[0]))
    cam.location = tuple(a - f * dist for a, f in zip(anchor, fwd))
    cam.rotation_euler = (math.radians(90.0 - TILT), 0.0, math.radians(YAW))


def setup_render(cam, sheet_w, sheet_h, zoom):
    sc = bpy.context.scene
    sc.render.engine = 'BLENDER_EEVEE'
    sc.render.resolution_x = max(64, int(round(sheet_w * zoom)))
    sc.render.resolution_y = max(64, int(round(sheet_h * zoom)))
    sc.render.resolution_percentage = 100
    sc.render.image_settings.file_format = 'PNG'
    sc.render.image_settings.color_mode = 'RGBA'
    sc.render.film_transparent = False
    sc.view_settings.view_transform = 'Standard'
    sc.view_settings.look = 'None'
    sc.view_settings.exposure = 0.0
    try:
        sc.eevee.taa_render_samples = 48
        sc.eevee.use_shadows = True
        sc.eevee.use_raytracing = True
        sc.eevee.ray_tracing_options.use_denoise = True
    except Exception as e:
        print("eevee setup warn:", e)
    cam.data.ortho_scale = u(sheet_w)       # 取景不随 zoom 变 → 两次渲染完全对位
    place_camera(cam, (0.0, 0.0, 0.0))
    return sc


# ------------------------------------------------------------------ 装配
def build(only=None, zoom=1.0, labels_on=True):
    clear()
    keys = [k for k in SHEET if (not only or k in only)]
    n = len(keys)
    cols = max(1, min(COLS, n))
    rows = int(math.ceil(n / float(cols))) if n else 1
    sheet_w = CELL_W * cols + MARGIN * 2.0            # px @1:1
    sheet_h = CELL_H * rows + MARGIN * 2.0
    row_dz = u(CELL_H) / _COS                  # 行距（补偿俯角投影压缩）
    x0 = -u(sheet_w) / 2.0 + u(MARGIN)
    z0 = u(sheet_h) / 2.0 - u(MARGIN)

    for i, key in enumerate(keys):
        cx = i % cols
        cz = i // cols
        px_ = x0 + cx * u(CELL_W)
        pz_ = z0 - cz * row_dz
        wear = DEFAULT_WEAR.get(key, 0.45)
        mat = M.make(key, wear=wear)

        # ---- 平面样片（背后，看平铺与 UV 尺度）
        pl = mesh_plane("pl_" + key, u(PL_W), u(PL_H))
        place_down(pl, px_ + u(CELL_W * 0.5), pz_, PL_D, y=u(30.0))
        bpy.context.view_layer.update()
        assign(pl, mat)
        M.box_project_uv(pl)

        # ---- 1:1（游戏 100%）：球 + 立方体
        sp = mesh_sphere("sph_" + key, u(R_BIG))
        place_down(sp, px_ + u(92.0), pz_, R_D)
        bpy.context.view_layer.update()
        assign(sp, mat)
        M.box_project_uv(sp)

        cb = mesh_cube("cube_" + key, u(C_SIDE), 34.0)
        place_down(cb, px_ + u(296.0), pz_, C_D)
        bpy.context.view_layer.update()
        assign(cb, mat)
        M.box_project_uv(cb)

        # ---- 25%（出厂门禁）：1/4 世界尺寸 + UV ×4 → 像素密度真的只有 1/4
        sr = u(R_BIG) * SMALL
        sp2 = mesh_sphere("sphS_" + key, sr, 20, 12)
        place_down(sp2, px_ + u(S_X1), pz_, S_D)
        bpy.context.view_layer.update()
        assign(sp2, mat)
        M.box_project_uv(sp2, uv_scale=UV_SMALL)

        cs = u(C_SIDE) * SMALL
        cb2 = mesh_cube("cubeS_" + key, cs, 34.0)
        place_down(cb2, px_ + u(S_X2), pz_, S_D - 2.0)
        bpy.context.view_layer.update()
        assign(cb2, mat)
        M.box_project_uv(cb2, uv_scale=UV_SMALL)

        if labels_on:
            label("%s   100%% | 25%%" % key, px_ + u(LAB_X), pz_, LAB_D)
        print("  + %-12s %-18s wear=%.2f" % (key, M._BUILDERS[key][1], wear))

    setup_world()
    add_sun("key", 42.0, -38.0, 3.4, (1.00, 0.95, 0.86), 3.5)
    add_sun("fill", 18.0, 125.0, 0.70, (0.72, 0.80, 0.95), 25.0)
    cam = make_camera()
    setup_render(cam, sheet_w, sheet_h, zoom)
    return keys, sheet_w, sheet_h


def render_to(path):
    sc = bpy.context.scene
    os.makedirs(os.path.dirname(path), exist_ok=True)
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)
    print("RENDER -> %s  %dx%d" % (path, sc.render.resolution_x, sc.render.resolution_y))


def main():
    argv = sys.argv
    names, flags = [], []
    if "--" in argv:
        for a in argv[argv.index("--") + 1:]:
            (flags if a.startswith("-") else names).append(a)
    only = names or None
    bad = [k for k in (only or []) if k not in M._BUILDERS]
    if bad:
        print("未知材质:", bad)
        return

    print("=== 材质样片 v2（1 UV = 32px = 0.42m；1:1 = %.0f px/m，25%% = %.0f px/m）==="
          % (32.0 / M.M_PER_UV, 8.0 / M.M_PER_UV))

    build(only, ZOOM)
    render_to(OUT if not only else os.path.join(
        OUT_DIR, "pbr_mat2_probe_%s.png" % "_".join(only[:3])))

    if "--true25" in flags:
        build(only, 0.25, labels_on=True)      # 整表按物理 25% 分辨率
        render_to(os.path.join(OUT_DIR, "pbr_mat2_true25.png"))

    print("\n=== 特征尺寸换算表（现实 / 游戏 1:1 / 25%%）===")
    M.audit(verbose=True)


if __name__ == "__main__":
    main()
