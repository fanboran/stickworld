# -*- coding: utf-8 -*-
"""管线调试：基本体全套测试（立方体/正球/圆柱/圆锥/圆环）过完整双 pass 管线。
每个基本体单材质、独立 ID 色；三尺寸（64/128/256，2x 超采样）独立渲染。
用法: blender -b --factory-startup -P gen_icon_v9_primitives.py"""
import bpy, math, os, sys
from mathutils import Vector

# 渲染中间产物统一落 <仓库根>/temp/（compose_icon_small_ui.py 从同一处读），CWD 无关
OUT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "temp"))
RES_BASE = 1024


def lin(c):
    return tuple(min(1.0, v) ** 2.2 for v in c)


def diffuse_mat(name, color):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes.get('Principled BSDF')
    b.inputs[0].default_value = (*lin(color), 1.0)
    b.inputs['Roughness'].default_value = 0.9
    return m


def flat_mat(name, color):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new('ShaderNodeOutputMaterial')
    emi = nt.nodes.new('ShaderNodeEmission')
    emi.inputs[0].default_value = (*color, 1.0)
    nt.links.new(emi.outputs[0], out.inputs[0])
    return m


def shade_mat(name):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new('ShaderNodeOutputMaterial')
    diff = nt.nodes.new('ShaderNodeBsdfDiffuse')
    diff.inputs[0].default_value = (0.85, 0.85, 0.85, 1.0)
    nt.links.new(diff.outputs[0], out.inputs[0])
    return m


def setup(az_deg, el_deg, res):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    for eng in ('BLENDER_EEVEE_NEXT', 'BLENDER_EEVEE'):
        try:
            scene.render.engine = eng
            break
        except TypeError:
            continue
    scene.eevee.taa_render_samples = 256   # 审计反馈「抗锯齿开满」：64→256（配合 2x SSAA 出图）
    scene.render.resolution_x = res
    scene.render.resolution_y = res
    scene.render.film_transparent = True
    try:
        scene.view_settings.view_transform = 'Standard'
    except Exception:
        pass
    try:
        scene.eevee.use_shadows = False
    except Exception:
        pass
    cam = bpy.data.objects.new('Cam', bpy.data.cameras.new('C'))
    scene.collection.objects.link(cam)
    cam.data.type = 'ORTHO'
    az, el, r = math.radians(az_deg), math.radians(el_deg), 6.0
    cam.location = (r * math.cos(el) * math.sin(az), -r * math.cos(el) * math.cos(az), r * math.sin(el))
    import mathutils
    direction = mathutils.Vector((0, 0, 0)) - cam.location
    cam.rotation_euler = direction.to_track_quat('-Z', 'Y').to_euler()
    cam.data.clip_end = 100
    scene.camera = cam
    sun = bpy.data.objects.new('Key', bpy.data.lights.new('K', 'SUN'))
    scene.collection.objects.link(sun)
    sun.rotation_euler = (math.radians(40), math.radians(14), math.radians(38))
    sun.data.energy = 4.5
    sun.data.angle = math.radians(10)
    return scene


def fit_ortho(scene, margin=1.06):
    deps = bpy.context.evaluated_depsgraph_get()
    cam = scene.camera
    R = cam.matrix_world.to_3x3()
    Rinv = R.inverted()
    cam_pos = cam.matrix_world.translation
    mn = Vector((1e9,) * 3)
    mx = Vector((-1e9,) * 3)
    for o in scene.objects:
        if o.type != 'MESH':
            continue
        oe = o.evaluated_get(deps)
        for c in oe.bound_box:
            cc = Rinv @ ((o.matrix_world @ Vector(c)) - cam_pos)
            mn = Vector(map(min, mn, cc))
            mx = Vector(map(max, mx, cc))
    ext = mx - mn
    center = (mn + mx) / 2
    shift = R @ Vector((-center.x, -center.y, 0))
    for o in scene.objects:
        if o.type == 'MESH':
            o.location = o.location + shift
    cam.data.ortho_scale = max(ext.x, ext.y) * margin


def smooth(obj, levels=2, render=3):
    m = obj.modifiers.new('subsurf', 'SUBSURF')
    m.levels = levels
    m.render_levels = render
    for p in obj.data.polygons:
        p.use_smooth = True


def build_primitive(scene, kind):
    """单材质基本体；返回 (object, base_color)"""
    COLORS = {"cube": (0.62, 0.42, 0.22), "sphere": (0.78, 0.26, 0.22),
              "cylinder": (0.30, 0.55, 0.48), "cone": (0.80, 0.62, 0.28),
              "torus": (0.48, 0.38, 0.62)}
    col = COLORS[kind]
    mat = diffuse_mat('m_' + kind, col)
    if kind == "cube":
        bpy.ops.mesh.primitive_cube_add(size=1.5, location=(0, 0, 0))
        ob = bpy.context.object
        bv = ob.modifiers.new('bev', 'BEVEL')
        bv.width = 0.12; bv.segments = 5
    elif kind == "sphere":
        bpy.ops.mesh.primitive_uv_sphere_add(radius=0.85, segments=96, ring_count=64,
                                             location=(0, 0, 0))
        ob = bpy.context.object
        smooth(ob)
    elif kind == "cylinder":
        bpy.ops.mesh.primitive_cylinder_add(radius=0.55, depth=1.5, vertices=48,
                                            location=(0, 0, 0))
        ob = bpy.context.object
        bv = ob.modifiers.new('bev', 'BEVEL')
        bv.width = 0.05; bv.segments = 3
    elif kind == "cone":
        bpy.ops.mesh.primitive_cone_add(radius1=0.75, radius2=0.0, depth=1.6, vertices=64,
                                        location=(0, 0, 0))
        ob = bpy.context.object
        # flat 刻面：subsurf 会把锥尖圆化成"水滴"（创始人 2026-09-08 反馈）；
        # 64 棱 flat 的微 banding 由 compose 的 cel 三档量化吸收
        for p in ob.data.polygons:
            p.use_smooth = False
    elif kind == "torus":
        bpy.ops.mesh.primitive_torus_add(major_radius=0.72, minor_radius=0.28,
                                         major_segments=72, minor_segments=36,
                                         location=(0, 0, 0))
        ob = bpy.context.object
        ob.rotation_euler = (math.radians(80), 0, 0)   # 立起：孔朝相机（微俯见环内壁）
        smooth(ob)
    ob.data.materials.append(mat)
    return ob, col


def _cel_bake_mat():
    """面烘色材质：读网格的 FACE 域顶点色 'cel_tone' 直出发光（不受光）。
    单槽 discipline 不破——每对象仍 1 材质，面级颜色走属性。（与 gen_motifs.py 逐字一致）"""
    m = bpy.data.materials.get('_cel_bake')
    if m:
        return m
    m = bpy.data.materials.new('_cel_bake')
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new('ShaderNodeOutputMaterial')
    emi = nt.nodes.new('ShaderNodeEmission')
    try:
        a = nt.nodes.new('ShaderNodeAttribute')
        a.attribute_name = 'cel_tone'
        nt.links.new(a.outputs[0], emi.inputs[0])
    except Exception:
        pass
    nt.links.new(emi.outputs[0], out.inputs[0])
    return m


def _srgb_inv(f):
    """文件域灰度 → 线性域：渲染 'Standard' 视图变换仍做 sRGB 显示编码，
    要出图恰为文件域 cel 灰（0.32/0.62/0.92），材质里须存线性值。"""
    return f / 12.92 if f <= 0.04045 else ((f + 0.055) / 1.055) ** 2.4


def _toon_band_grays(steps):
    """N 档 cel 灰（文件域均布 0.32..0.92）与其线性域值"""
    fs = [0.32 + (0.92 - 0.32) * i / (steps - 1) for i in range(steps)]
    return fs, [_srgb_inv(f) for f in fs]


def _toon_mat():
    """曲面 toon 材质（D 着色器分档）：漫反射光照 → ShaderToRGB → 明度 →
    ColorRamp 常量量化 N 档灰（出图=文件域 0.32/0.62/0.92）→ Emission。
    断点 TOON_LO/TOON_HI（文件域默认 0.76/0.95，v1 三分位校准）、档数
    TOON_STEPS 环境变量（与 gen_motifs 共享）。ShaderToRGB 仅 EEVEE 支持；
    不可用时回退白模受光。（与 gen_motifs.py 逐字一致）"""
    import os
    steps = max(2, int(os.environ.get('TOON_STEPS', '3')))
    lo = float(os.environ.get('TOON_LO', '0.76'))
    hi = float(os.environ.get('TOON_HI', '0.95'))
    # 材质按参数签名缓存（TOON_LO/HI 可中途改，场景切换自动重建）。
    # （与 gen_motifs.py 逐字一致）
    sig = f"{steps}|{lo}|{hi}"
    m = bpy.data.materials.get('_toon')
    if m:
        if m.get('_sig') == sig:
            return m
        bpy.data.materials.remove(m)
    m = bpy.data.materials.new('_toon')
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new('ShaderNodeOutputMaterial')
    try:
        diff = nt.nodes.new('ShaderNodeBsdfDiffuse')
        diff.inputs[0].default_value = (0.85, 0.85, 0.85, 1.0)
        s2r = nt.nodes.new('ShaderNodeShaderToRGB')
        bw = nt.nodes.new('ShaderNodeRGBToBW')
        ramp = nt.nodes.new('ShaderNodeValToRGB')
        ramp.color_ramp.interpolation = 'LINEAR'
        elems = ramp.color_ramp.elements
        while len(elems) > 1:
            elems.remove(elems[-1])
        # 窄过渡带替代 CONSTANT 硬台阶（EEVEE Next 逐像素光照平滑不了档位边界：
        # 锯齿+细窄件抖档虚线的根因）。（与 gen_motifs.py 逐字一致）
        _, grays = _toon_band_grays(steps)
        poss = [_srgb_inv(lo + (hi - lo) * (i + 1) / (steps - 1)) for i in range(steps - 1)]
        trans = 0.03
        e0 = elems[0]
        e0.position = 0.0
        e0.color = (grays[0], grays[0], grays[0], 1.0)
        for i in range(steps - 1):
            ea = elems.new(min(max(poss[i] - trans, 0.001), 0.998))
            ea.color = (grays[i], grays[i], grays[i], 1.0)
            eb = elems.new(min(poss[i] + trans, 0.999))
            eb.color = (grays[i + 1], grays[i + 1], grays[i + 1], 1.0)
        last = elems[-1]
        last.position = 1.0
        last.color = (grays[-1], grays[-1], grays[-1], 1.0)
        nt.links.new(diff.outputs[0], s2r.inputs[0])
        nt.links.new(s2r.outputs[0], bw.inputs[0])
        nt.links.new(bw.outputs[0], ramp.inputs[0])
        emi = nt.nodes.new('ShaderNodeEmission')
        nt.links.new(ramp.outputs[0], emi.inputs[0])
        nt.links.new(emi.outputs[0], out.inputs[0])
    except Exception:
        print("toon shader unavailable, fallback to white diffuse")
        sys.stdout.flush()
        diff = nt.nodes.new('ShaderNodeBsdfDiffuse')
        diff.inputs[0].default_value = (0.85, 0.85, 0.85, 1.0)
        nt.links.new(diff.outputs[0], out.inputs[0])
    m['_sig'] = sig
    return m


def bake_flat_faces(scene):
    """平面着色网格按「面法线·主光方向」量化三档灰烘进顶点色（一面一色，
    烘色灰存线性域）；平滑网格走 toon 材质着色器分档。（与 gen_motifs.py 逐字一致）"""
    cam = scene.camera
    R = cam.matrix_world.to_3x3()
    ldir = (R @ Vector((-3.0, 2.6, 0.6))).normalized()
    bake = _cel_bake_mat()
    toon = _toon_mat()
    _, grays = _toon_band_grays(3)   # [lin(0.32), lin(0.62), lin(0.92)] 暗/中/亮
    g_dark, g_mid, g_bright = grays
    for o in scene.objects:
        if o.type != 'MESH' or o.get('is_ink_shell'):
            continue
        polys = o.data.polygons
        if polys and all(p.use_smooth for p in polys):
            o.data.materials[0] = toon
            continue
        attr = o.data.color_attributes.get('cel_tone')
        if attr is None:
            attr = o.data.color_attributes.new('cel_tone', 'FLOAT_COLOR', 'FACE')
        for p in polys:
            t = p.normal.dot(ldir)
            g = g_bright if t > 0.5 else (g_mid if t > 0.2 else g_dark)
            attr.data[p.index].color = (g, g, g, 1.0)
        o.data.materials[0] = bake


def _ink_mat():
    """描边壳材质：纯墨色 emission+背面剔除（反向壳原理）。
    （与 gen_motifs.py 逐字一致）"""
    m = bpy.data.materials.get('_ink_shell')
    if m:
        return m
    m = bpy.data.materials.new('_ink_shell')
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new('ShaderNodeOutputMaterial')
    emi = nt.nodes.new('ShaderNodeEmission')
    emi.inputs[0].default_value = (18 / 255, 14 / 255, 9 / 255, 1.0)
    nt.links.new(emi.outputs[0], out.inputs[0])
    m.use_backface_culling = True
    return m


def build_ink_shells(scene, target):
    """反向壳描边（C 阶段）：复制+SOLIDIFY 外扩成壳，纯墨只渲背面。
    （与 gen_motifs.py 逐字一致）"""
    import bmesh
    cam = scene.camera
    px = {64: 2.2, 128: 2.6, 256: 3.0}.get(target, 2.2)
    thickness = cam.data.ortho_scale * px / target
    ink = _ink_mat()
    for o in list(scene.objects):
        if o.type != 'MESH' or o.get('is_ink_shell'):
            continue
        sh = o.copy()
        sh.data = o.data.copy()
        sh['is_ink_shell'] = 1
        sol = sh.modifiers.new('ink_shell', 'SOLIDIFY')
        sol.thickness = thickness
        sol.offset = -1
        flipped = False
        try:
            sol.use_flip = True
            flipped = True
        except AttributeError:
            pass
        if not flipped:
            bm = bmesh.new()
            bm.from_mesh(sh.data)
            bmesh.ops.reverse_faces(bm, faces=bm.faces[:])
            bm.to_mesh(sh.data)
            bm.free()
        sh.data.materials.clear()
        sh.data.materials.append(ink)
        scene.collection.objects.link(sh)


def render_passes(scene, tag, id_mat, target=64, margin=1.06):
    """C 阶段三分 pass：ID（无壳）→ shade（原体+壳）→ ink（只有壳）"""
    for o in scene.objects:
        if o.type != 'MESH':
            continue
        o.data.materials.clear()
        o.data.materials.append(id_mat)
    scene.render.filepath = os.path.join(OUT, f"{tag}_id.png")
    bpy.ops.render.render(write_still=True)
    print("rendered", tag, "id")
    build_ink_shells(scene, target)
    fit_ortho(scene, margin)   # 二次取景：描边壳外扩纳入画框
    for o in scene.objects:
        if o.get('is_ink_shell'):
            o.hide_render = True   # shade 保持纯 cel
    bake_flat_faces(scene)     # D 分档：平面面烘色/曲面 toon，取代白模受光
    scene.render.filepath = os.path.join(OUT, f"{tag}_shade.png")
    bpy.ops.render.render(write_still=True)
    print("rendered", tag, "shade")
    for o in scene.objects:
        if o.type == 'MESH':
            o.hide_render = not bool(o.get('is_ink_shell'))
    scene.render.filepath = os.path.join(OUT, f"{tag}_ink.png")
    bpy.ops.render.render(write_still=True)
    print("rendered", tag, "ink")


KINDS = ["cube", "sphere", "cylinder", "cone", "torus"]
ID_COLS = {"cube": (1, 0, 0), "sphere": (0, 1, 0), "cylinder": (0, 0, 1),
           "cone": (1, 1, 0), "torus": (1, 0, 1)}

for kind in KINDS:
    for t in (64, 128, 256):
        scene = setup(32, 22, t * 2)
        ob, col = build_primitive(scene, kind)
        fit_ortho(scene)
        render_passes(scene, f"test_{kind}_v9_{t}", flat_mat(f'id_{kind}', ID_COLS[kind]), target=t)
sys.stdout.flush()
