# -*- coding: utf-8 -*-
"""母题库批量渲染：MOTIFS 注册表 × 3 尺寸 × 双 pass（ID/shade），产物到 <仓库根>/temp/。
用法:
  blender -b --factory-startup -P gen_motifs.py                 # 全量（约 64 枚 × 6 渲）
  blender -b --factory-startup -P gen_motifs.py -- axe bell     # 只渲指定母题（tag 或 name）
单枚失败不中断批次，结尾汇总；退出码 1 = 有失败。
setup/fit_ortho 与 gen_icon_v9.py 逐字一致（验证过的基准），勿单改一处。"""
import bpy, math, os, sys, traceback
from mathutils import Vector

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)
OUT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", "temp"))
import motifs as M


def lin(c):
    return tuple(min(1.0, v) ** 2.2 for v in c)


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


def setup(az_deg, el_deg, res, key_e=4.5):
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
    direction = Vector((0, 0, 0)) - cam.location
    cam.rotation_euler = direction.to_track_quat('-Z', 'Y').to_euler()
    cam.data.clip_end = 100
    scene.camera = cam
    bpy.context.view_layer.update()          # 不更新则 matrix_world 是陈旧单位阵（黑脸根因）
    R = cam.matrix_world.to_3x3()
    cam_pos = cam.matrix_world.translation

    cam_left = R @ Vector((-1, 0, 0))
    cam_up = R @ Vector((0, 1, 0))
    cam_back = R @ Vector((0, 0, 1))
    sun = bpy.data.objects.new('Key', bpy.data.lights.new('K', 'SUN'))
    scene.collection.objects.link(sun)
    sun.location = cam_pos + cam_left * 3.0 + cam_up * 2.6 + cam_back * 0.6
    d = Vector((0, 0, 0)) - sun.location
    sun.rotation_euler = d.to_track_quat('-Z', 'Y').to_euler()
    sun.data.energy = key_e
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


def render_two(scene, tag, t):
    """先 shade 后 ID：母题对象全部单槽，原位替换材质，无钳零问题"""
    white = shade_mat('_w')
    for o in scene.objects:
        if o.type == 'MESH':
            o.data.materials[0] = white
    scene.render.filepath = os.path.join(OUT, f"{tag}_{t}_shade.png")
    bpy.ops.render.render(write_still=True)
    print("rendered", tag, t, "shade")
    sys.stdout.flush()
    for o in scene.objects:
        if o.type == 'MESH':
            o.data.materials[0] = flat_mat(f"_id{o['pid']}", M.ID_COLORS[o['pid']])
    scene.render.filepath = os.path.join(OUT, f"{tag}_{t}_id.png")
    bpy.ops.render.render(write_still=True)
    print("rendered", tag, t, "id")
    sys.stdout.flush()


only = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
fails = []
for m in M.MOTIFS:
    if only and m["tag"] not in only and m["name"] not in only:
        continue
    for t in (64, 128, 256):
        try:
            scene = setup(m["az"], m["el"], t * 2, m["key_e"])
            m["build"]()
            fit_ortho(scene, m["margin"])
            render_two(scene, m["tag"], t)
        except Exception:
            fails.append((m["tag"], t, traceback.format_exc()))

if fails:
    for tag, t, tb in fails:
        print(f"FAIL {tag} {t}\n{tb}")
    print(f"== {len(fails)} render(s) failed ==")
    sys.stdout.flush()
    sys.exit(1)
print("== all motif renders done ==")
