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


def _cel_bake_mat():
    """面烘色材质：读网格的 FACE 域顶点色 'cel_tone' 直出发光（不受光）。
    单槽 discipline 不破——每对象仍 1 材质，面级颜色走属性。"""
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
    """曲面 toon 材质（D 着色器分档）：白模漫反射受光 → ShaderToRGB → 明度 →
    ColorRamp 常量插值量化 N 档 → Emission。shade pass 出图即文件域 cel 灰阶
    （三档 0.32/0.62/0.92），compose 只按灰阶查表映射色带，不再拉伸/聚类。
    断点 TOON_LO/TOON_HI 默认 0.76/0.95（文件域，按 main v1 基线 shade 的线性
    明度三分位校准——v1 k-means 簇边界实测 lin≈0.59/0.94；首版 0.35/0.70 偏低，
    亮档吞掉中段致圆环近纯色，2026-09-08 审计返工调正；进材质前经 _srgb_inv
    换算线性域）、档数 TOON_STEPS（默认 3）环境变量化，供创始人验收调优。
    ShaderToRGB 仅 EEVEE 支持；节点不可用时回退白模受光（compose 按灰阶分类
    三档，语义等价兜底）。"""
    import os
    steps = max(2, int(os.environ.get('TOON_STEPS', '3')))
    lo = float(os.environ.get('TOON_LO', '0.76'))
    hi = float(os.environ.get('TOON_HI', '0.95'))
    # 材质按参数签名缓存：TOON_LO/HI 可在脚本中途改（单枚特殊光位自定断点，
    # 如爱心的头灯径向场），场景切换时自动重建
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
        # 站位（线性明度域）：档位间留 2*TRANS 的窄过渡带（LINEAR 插值），不用
        # CONSTANT 硬台阶——EEVEE Next 光照是逐像素延迟着色，MSAA 平滑不了
        # ShaderToRGB 之后的档位边界（锯齿根因），细窄倒角条骑在断点上还会
        # 逐面抖档成深色虚线；窄过渡让边界成 1-3px 渐变（2x SSAA 后干净），
        # 细窄件并入邻档
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
    """平面着色网格：按「面法线·主光方向」量化三档灰烘进顶点色——
    每个平面恰好一色，朝向不同色不同（cel 一面一色惯例；来源方向=相机基
    向量，与 setup 主光一致：左上主光）。平滑网格（球/胶囊/环/曲线管）
    走 toon 材质：着色器内把漫反射光照量化成同三档灰（D 分档，取代
    v1 的白模受光→图像域 k-means）。烘色灰存线性域（出图=文件域三档灰）。
    倒角等修改器生成的新面从相邻基面插值属性=柔和棱过渡。"""
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
    """描边壳材质：纯墨色 emission（不受光、无分档），开启背面剔除——
    反向壳原理：壳沿法线外扩+法线反转后，叠在形体正面的壳面是背面被剔除，
    只有轮廓外露出的壳面朝向相机，形成描边。"""
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
    """反向壳描边（C 阶段，取代图像域外轮廓环）：
    - 对场景每个 mesh 复制一份（修改器栈随对象复制，bevel 等形状保留），
      追加 SOLIDIFY 沿法线外扩成壳，材质=纯墨+背面剔除；
    - 5.2 的 Solidify 无独立法线翻转开关，用 use_flip 探测，失败则 bmesh
      反转壳网格法线（基面反转后 offset=-1 语义即向外）；
    - 壳边缘=几何边缘，MSAA 真抗锯齿（ShaderToRGB 会关 MSAA，图像域描边
      拿不到的 AA 几何线白送）；墨线与形体轮廓零对位误差（双层线根除）；
    - 壳不带 pid：ID pass 前 hide_render，ID 渲完在 shade 里可见；
    - 线宽按目标尺寸参数化（世界单位 thickness=ortho_scale×px/target）"""
    import bmesh
    cam = scene.camera
    px = {64: 2.2, 128: 2.6, 256: 3.0}.get(target, 2.2)
    thickness = cam.data.ortho_scale * px / target
    ink = _ink_mat()
    for o in list(scene.objects):
        if o.type != 'MESH' or o.get('is_ink_shell'):
            continue
        sh = o.copy()                  # 修改器栈随对象复制
        sh.data = o.data.copy()        # 网格数据独立（材质可安全替换）
        sh['is_ink_shell'] = 1
        sol = sh.modifiers.new('ink_shell', 'SOLIDIFY')
        sol.thickness = thickness
        sol.offset = -1
        flipped = False
        try:
            sol.use_flip = True        # 5.2 探测：直接反转壳法线
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
    return thickness


def render_two(scene, tag, t, classic=False, margin=1.06):
    """shade pass：平面物体面烘色、曲面物体 toon 着色器分档（输出即 cel 灰阶
    +几何描边壳）；再 ID pass（壳先隐藏，壳不带 pid）。
    母题对象全部单槽，原位替换材质，无钳零问题。classic=True 全白模受光
    连续明度（豁免母题 v1 渲染语义——其 compose 侧假光依赖连续明度场）"""
    build_ink_shells(scene, t)
    fit_ortho(scene, margin)   # 二次取景：把描边壳的外扩纳入画框
    if not classic:
        bake_flat_faces(scene)
    else:
        white = shade_mat('_w')
        for o in scene.objects:
            if o.get('is_ink_shell'):
                continue
            if o.type == 'MESH':
                o.data.materials[0] = white
    # shade pass：壳隐藏——shade 保持纯 cel（墨线由 ink pass 单独承担）
    for o in scene.objects:
        if o.get('is_ink_shell'):
            o.hide_render = True
    scene.render.filepath = os.path.join(OUT, f"{tag}_{t}_shade.png")
    bpy.ops.render.render(write_still=True)
    print("rendered", tag, t, "shade")
    sys.stdout.flush()
    # 墨线 pass：只渲描边壳（透明底）；compose「cel 在上、墨壳在下」合成，
    # 墨壳被 cel 覆盖的部分不显形，只在轮廓外露出一圈描边
    for o in scene.objects:
        if o.type == 'MESH':
            o.hide_render = not bool(o.get('is_ink_shell'))
    scene.render.filepath = os.path.join(OUT, f"{tag}_{t}_ink.png")
    bpy.ops.render.render(write_still=True)
    print("rendered", tag, t, "ink")
    sys.stdout.flush()
    for o in scene.objects:
        if o.get('is_ink_shell'):
            o.hide_render = True
            continue
        if o.type == 'MESH':
            o.hide_render = False   # 墨线 pass 曾隐藏原体——ID 前必须解封（曾致 ID 全黑、全库误涂墨炭）
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
            render_two(scene, m["tag"], t, m.get("classic", False), m["margin"])
        except Exception:
            fails.append((m["tag"], t, traceback.format_exc()))

if fails:
    for tag, t, tb in fails:
        print(f"FAIL {tag} {t}\n{tb}")
    print(f"== {len(fails)} render(s) failed ==")
    sys.stdout.flush()
    sys.exit(1)
print("== all motif renders done ==")
