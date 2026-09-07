# -*- coding: utf-8 -*-
"""图标管线 v8（思路重整版）：
渲染：正交相机 + 单一主光（左上），无补光/环境/轮缘——明度场=纯光向梯度，
     分档边界为方向性流畅曲线（心形内部天然亮暗面）；ID 先渲、shade 后渲
     （materials.clear() 会钳零 material_index，ID 先渲避开该坑）。
建模：锤=柄+三面材质头；心=心形多边形+Chaikin×3+曲线挤出枕头体。
出图: temp/icon_<name>_v8_id.png / _shade.png
用法: blender -b --factory-startup -P gen_icon_v8.py"""
import bpy, math, os, sys
from mathutils import Vector

# 渲染中间产物统一落 <仓库根>/temp/（compose_icon_small_ui.py 从同一处读）；
# 锚定脚本位置，CWD 无关。历史注：本脚本曾住在 temp/ 内，dirname(__file__) 恰为其别名。
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", "temp"))
RES = 1024


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
    # 无世界光（纯黑环境）——明暗全由主光方向决定

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
    bpy.context.view_layer.update()          # 不更新则 matrix_world 是陈旧单位阵（黑脸根因）
    R = cam.matrix_world.to_3x3()
    cam_pos = cam.matrix_world.translation

    # 唯一主光：屏幕空间恒定左上（由相机基向量推导——相机方位变化时光向不变）
    cam_left = R @ Vector((-1, 0, 0))
    cam_up = R @ Vector((0, 1, 0))
    cam_back = R @ Vector((0, 0, 1))
    sun = bpy.data.objects.new('Key', bpy.data.lights.new('K', 'SUN'))
    scene.collection.objects.link(sun)
    # 对象在原点：主光放屏幕左上、相机侧 1.2——3/4 光位（贴相机轴会退化成头灯=无内部差）
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


def build_hammer(scene):
    wood = diffuse_mat('wood', (0.62, 0.42, 0.22))
    irons = [diffuse_mat('iron_top', (0.72, 0.74, 0.78)),
             diffuse_mat('iron_front', (0.62, 0.64, 0.68)),
             diffuse_mat('iron_side', (0.44, 0.46, 0.50))]
    bpy.ops.mesh.primitive_cylinder_add(radius=0.19, depth=1.30, vertices=48,
                                        location=(0, 0, -0.42))
    h = bpy.context.object
    hv = h.modifiers.new('bev', 'BEVEL')
    hv.width = 0.04; hv.segments = 3; hv.limit_method = 'ANGLE'; hv.angle_limit = math.radians(40)
    h.data.materials.append(wood)

    bpy.ops.mesh.primitive_cube_add(size=1, location=(0, 0, 0.50))
    head = bpy.context.object
    head.scale = (1.10, 0.42, 0.46)
    bv = head.modifiers.new('bev', 'BEVEL')
    bv.width = 0.09; bv.segments = 6
    for m in irons:
        head.data.materials.append(m)
    for poly in head.data.polygons:
        n = poly.normal
        if n.z > 0.7:
            poly.material_index = 0
        elif n.y < -0.7:
            poly.material_index = 1
        elif n.x > 0.7:
            poly.material_index = 2
        else:
            poly.material_index = 1
    return {h.name: ['handle'], head.name: ['head_top', 'head_front', 'head_side']}


def heart_outline():
    base = [
        (0.00, 0.42), (-0.20, 0.70), (-0.52, 0.86), (-0.84, 0.72),
        (-1.00, 0.36), (-0.94, 0.00), (-0.70, -0.42), (-0.36, -0.72),
        (0.00, -0.98),
        (0.36, -0.72), (0.70, -0.42), (0.94, 0.00), (1.00, 0.36),
        (0.84, 0.72), (0.52, 0.86), (0.20, 0.70),
    ]
    for _ in range(3):
        out = []
        n = len(base)
        for i in range(n):
            a, b = base[i], base[(i + 1) % n]
            out.append((0.75 * a[0] + 0.25 * b[0], 0.75 * a[1] + 0.25 * b[1]))
            out.append((0.25 * a[0] + 0.75 * b[0], 0.25 * a[1] + 0.75 * b[1]))
        base = out
    return base


def build_heart(scene):
    red = diffuse_mat('red', (0.78, 0.26, 0.22))
    pts = heart_outline()
    cu = bpy.data.curves.new('heart', 'CURVE')
    spl = cu.splines.new('POLY')
    spl.points.add(len(pts) - 1)
    for i, (x, y) in enumerate(pts):
        spl.points[i].co = (x, y + 0.15, 0.0, 1.0)
    spl.use_cyclic_u = True
    cu.extrude = 0.17
    cu.bevel_depth = 0.06
    cu.fill_mode = 'BOTH'
    ob = bpy.data.objects.new('Heart', cu)
    scene.collection.objects.link(ob)
    bpy.ops.object.select_all(action='DESELECT')
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.convert(target='MESH')
    ob = bpy.context.object
    ob.rotation_euler = (math.radians(90), 0, 0)
    # 法线一致化：曲线盖面法线方向不确定，翻转会让正面渲染全黑
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.mesh.normals_make_consistent(inside=False)
    bpy.ops.object.mode_set(mode='OBJECT')
    ob.data.materials.append(red)
    for p_ in ob.data.polygons:
        p_.use_smooth = True
    return {ob.name: ['heart']}


def fix_head_faces(scene):
    """ID pass 前按法线重指派锤头三面（防钳零）"""
    for o in scene.objects:
        if o.type == 'MESH' and len(o.data.materials) == 3:
            for poly in o.data.polygons:
                n = poly.normal
                poly.material_index = 0 if n.z > 0.7 else (1 if n.y < -0.7 else (2 if n.x > 0.7 else 1))


def render_passes(scene, tag, id_slots):
    """ID 先渲（此时 material_index 新鲜），再清空渲 shade"""
    for o in scene.objects:
        if o.type != 'MESH':
            continue
        o.data.materials.clear()
        for m in id_slots[o.name]:
            o.data.materials.append(m)
    if any(len(o.data.materials) == 3 for o in scene.objects if o.type == 'MESH'):
        fix_head_faces(scene)
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


ID_COLS = {
    "head_top": (1, 0, 0), "head_front": (0, 1, 0), "head_side": (0, 0, 1),
    "handle": (1, 1, 0), "heart": (1, 0, 1),
}

# 分尺寸渲染（render-per-LOD）：每个目标尺寸独立出图，线宽/细节量在目标像素域定义
ENERGY = {"icon_heart_v9": 7.0}   # 平面脸受光少，单独提亮（其余默认 4.5）
for t in (64, 128, 256):
    scene = setup(32, 30, t * 2)
    hmap = build_hammer(scene)
    fit_ortho(scene)
    id_h = {n: flat_mat('id_' + n, ID_COLS[n]) for n in ID_COLS}
    render_passes(scene, f"icon_hammer_v9_{t}",
                  {oname: [id_h[n] for n in names] for oname, names in hmap.items()})
    sys.stdout.flush()

# ── 爱心（能量 7.0：平面脸受光少需提亮）──
for t in (64, 128, 256):
    scene = setup(14, 8, t * 2, ENERGY["icon_heart_v9"])
    emap = build_heart(scene)
    fit_ortho(scene)

    id_e = {n: flat_mat('id_' + n, ID_COLS[n]) for n in ID_COLS}
    render_passes(scene, f"icon_heart_v9_{t}",
                  {oname: [id_e[n] for n in names] for oname, names in emap.items()})
    sys.stdout.flush()
