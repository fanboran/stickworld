# -*- coding: utf-8 -*-
"""管线调试：基本体全套测试（立方体/正球/圆柱/圆锥/圆环）过完整双 pass 管线。
每个基本体单材质、独立 ID 色；三尺寸（64/128/256，2x 超采样）独立渲染。
用法: blender -b --factory-startup -P gen_icon_v9_primitives.py"""
import bpy, math, os, sys
from mathutils import Vector

OUT = os.path.dirname(os.path.abspath(__file__))
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
    scene.eevee.taa_render_samples = 64
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
        smooth(ob)
    elif kind == "torus":
        bpy.ops.mesh.primitive_torus_add(major_radius=0.72, minor_radius=0.28,
                                         major_segments=72, minor_segments=36,
                                         location=(0, 0, 0))
        ob = bpy.context.object
        ob.rotation_euler = (math.radians(80), 0, 0)   # 立起：孔朝相机（微俯见环内壁）
        smooth(ob)
    ob.data.materials.append(mat)
    return ob, col


def render_passes(scene, tag, id_mat):
    for o in scene.objects:
        if o.type != 'MESH':
            continue
        o.data.materials.clear()
        o.data.materials.append(id_mat)
    scene.render.filepath = os.path.join(OUT, f"{tag}_id.png")
    bpy.ops.render.render(write_still=True)
    print("rendered", tag, "id")
    white = shade_mat('shade_all')
    for o in scene.objects:
        if o.type != 'MESH':
            continue
        o.data.materials.clear()
        o.data.materials.append(white)
    scene.render.filepath = os.path.join(OUT, f"{tag}_shade.png")
    bpy.ops.render.render(write_still=True)
    print("rendered", tag, "shade")


KINDS = ["cube", "sphere", "cylinder", "cone", "torus"]
ID_COLS = {"cube": (1, 0, 0), "sphere": (0, 1, 0), "cylinder": (0, 0, 1),
           "cone": (1, 1, 0), "torus": (1, 0, 1)}

for kind in KINDS:
    for t in (64, 128, 256):
        scene = setup(32, 22, t * 2)
        ob, col = build_primitive(scene, kind)
        fit_ortho(scene)
        render_passes(scene, f"test_{kind}_v9_{t}", flat_mat(f'id_{kind}', ID_COLS[kind]))
sys.stdout.flush()
