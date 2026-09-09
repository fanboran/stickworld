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


def fix_head_faces(scene):
    """ID pass 前按法线重指派锤头三面（防钳零）"""
    for o in scene.objects:
        if o.type == 'MESH' and len(o.data.materials) == 3:
            for poly in o.data.polygons:
                n = poly.normal
                poly.material_index = 0 if n.z > 0.7 else (1 if n.y < -0.7 else (2 if n.x > 0.7 else 1))


def _srgb_inv(f):
    """文件域灰度 → 线性域（Standard 视图变换仍做 sRGB 显示编码）。
    （与 gen_motifs.py 逐字一致）"""
    return f / 12.92 if f <= 0.04045 else ((f + 0.055) / 1.055) ** 2.4


def _toon_band_grays(steps):
    """N 档 cel 灰（文件域均布 0.32..0.92）与其线性域值"""
    fs = [0.32 + (0.92 - 0.32) * i / (steps - 1) for i in range(steps)]
    return fs, [_srgb_inv(f) for f in fs]


def _toon_mat():
    """曲面 toon 材质（D 着色器分档）：漫反射 → ShaderToRGB → 明度 →
    ColorRamp 窄过渡带量化 → Emission。TOON_LO/HI/STEPS 环境变量默认
    0.76/0.95/3，材质按参数签名缓存。
    ShaderToRGB 仅 EEVEE 支持；不可用时回退白模受光。（与 gen_motifs.py 逐字一致）"""
    import os
    steps = max(2, int(os.environ.get('TOON_STEPS', '3')))
    lo = float(os.environ.get('TOON_LO', '0.76'))
    hi = float(os.environ.get('TOON_HI', '0.95'))
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
    return m


def build_ink_shells(scene, target):
    """反向壳描边（C 阶段）：取每个 mesh「修改器求值后」的几何，顶点沿法线
    外推 thickness、面序反转，得到比原体大一圈的墨壳；单独渲 ink pass，
    compose「cel 在上、墨壳在下」只露外圈。壳边=几何边，MSAA 真抗锯齿。
    不用 SOLIDIFY/背面剔除：EEVEE Next DITHERED 延迟管线不理会剔除，
    5.2 的 solidify offset/use_flip 组合实测外扩为零（壳剪影与原体逐像素
    重合），故直接对求值几何做法线位移，确定性成立。
    线宽按目标尺寸参数化：thickness=ortho_scale×px/target（世界单位）。"""
    import bmesh
    cam = scene.camera
    px = {64: 2.2, 128: 2.6, 256: 3.0}.get(target, 2.2)
    thickness = cam.data.ortho_scale * px / target
    ink = _ink_mat()
    deps = bpy.context.evaluated_depsgraph_get()
    for o in list(scene.objects):
        if o.type != 'MESH' or o.get('is_ink_shell'):
            continue
        oe = o.evaluated_get(deps)
        me = oe.to_mesh()
        bm = bmesh.new()
        bm.from_mesh(me)
        oe.to_mesh_clear()
        bm.normal_update()
        # 屏幕空间恒宽：沿「法线去掉视线分量」的相机平面方向外推——正交相机
        # 下位移在屏幕平面内恒为 thickness 像素，不随面与视线的夹角变化。
        # （3D 法线外推在掠射面变粗/陡直面变细：铁砧左右不匀、圆锥上细下粗的根因）
        R = o.matrix_world.to_3x3()
        Rinv = R.inverted()
        RinvN = Rinv.transposed()   # 法线矩阵：防非均匀尺度扭曲法线方向
        view = (R @ Vector((0.0, 0.0, -1.0))).normalized()
        for v in bm.verts:
            wn = (RinvN @ v.normal).normalized()
            n_plane = wn - view * wn.dot(view)
            if n_plane.length > 1e-4:
                n_plane.normalize()
                v.co = v.co + Rinv @ (n_plane * thickness)   # 只回转方向，不平移（防壳飞离原体）
        bmesh.ops.reverse_faces(bm, faces=bm.faces[:])
        sh_mesh = bpy.data.meshes.new(f"{o.name}_ink_shell")
        bm.to_mesh(sh_mesh)
        bm.free()
        sh = bpy.data.objects.new(f"{o.name}_ink_shell", sh_mesh)
        sh['is_ink_shell'] = 1
        sh.matrix_world = o.matrix_world.copy()
        sh.data.materials.append(ink)
        scene.collection.objects.link(sh)

def render_passes(scene, tag, id_slots, toon=False, target=64, margin=1.06):
    """ID 先渲（此时 material_index 新鲜）；C 阶段三分 pass：shade（原体+壳）、
    ink（只有壳）、ID 复用首段（壳不存在）。toon=True 时 shade 挂 toon 材质
    （保留给母题库特殊件）；锤保持白模（compose 假光依赖连续明度场）。
    壳在 ID 时不创建（ID 先渲），shade 前建壳+二次取景"""
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

    build_ink_shells(scene, target)
    fit_ortho(scene, margin)   # 二次取景：描边壳外扩纳入画框
    for o in scene.objects:
        if o.get('is_ink_shell'):
            o.hide_render = True   # shade 保持纯 cel
    if toon:
        for o in scene.objects:
            if o.type == 'MESH' and not o.get('is_ink_shell'):
                o.data.materials.clear()
                o.data.materials.append(_toon_mat())
    else:
        white = shade_mat('shade_all')
        for o in scene.objects:
            if o.type == 'MESH' and not o.get('is_ink_shell'):
                o.data.materials.clear()
                o.data.materials.append(white)
    scene.render.filepath = os.path.join(OUT, f"{tag}_shade.png")
    bpy.ops.render.render(write_still=True)
    print("rendered", tag, "shade")

    for o in scene.objects:
        if o.type == 'MESH':
            o.hide_render = not bool(o.get('is_ink_shell'))
    scene.render.filepath = os.path.join(OUT, f"{tag}_ink.png")
    bpy.ops.render.render(write_still=True)
    print("rendered", tag, "ink")


ID_COLS = {
    "head_top": (1, 0, 0), "head_front": (0, 1, 0), "head_side": (0, 0, 1),
    "handle": (1, 1, 0),
}

# 分尺寸渲染（render-per-LOD）：每个目标尺寸独立出图，线宽/细节量在目标像素域定义
for t in (64, 128, 256):
    scene = setup(32, 30, t * 2)
    hmap = build_hammer(scene)
    fit_ortho(scene)
    id_h = {n: flat_mat('id_' + n, ID_COLS[n]) for n in ID_COLS}
    render_passes(scene, f"icon_hammer_v9_{t}",
                  {oname: [id_h[n] for n in names] for oname, names in hmap.items()},
                  target=t)
    sys.stdout.flush()
