# -*- coding: utf-8 -*-
"""母题库注册表（11-构筑谱系 §4.2：游戏内元素 + 可爱元素，可爱优先于庄重）。

每个母题 = 一个 build 函数（用 helpers 摆基本体）+ 元数据。三份消费者：
  - gen_motifs.py（Blender 内）：调 build() 渲染双 pass 到 <仓库根>/temp/
  - compose_icon_small_ui.py（系统 Python）：读元数据（tag/label/fake/name）进 TAGS
  - 未来 Godot 接入：按 name 取 temp/icons/<name>_<size>.png

建模纪律（v9 教训，必须遵守）：
  - 锥体禁用（极点棱纹）——仅允许 4 棱「刻意棱面」用法（帐篷/塔顶，不平滑着色）
  - 圆柱禁整体细分（桶形），只 BEVEL 边缘；球体要细分
  - 每对象恰好 1 个材质槽（shade pass 原位替换，避开 materials.clear() 钳零坑）
  - pid 存在对象自定义属性 ["pid"]，ID pass 按它取 ID_COLORS
  - 部件间重叠无妨（渲染近者胜），局部细节宁大勿小（64px 可读性优先）

色带家族（pid → cel 家族，与 compose RAMPS 对齐）：
  0红→深灰金属 1绿→中灰金属 2蓝→亮灰金属 3黄→木棕 4品红→红
  5青→叶绿 6白→米白 7黑→墨炭 8橙→金 9藏青→蓝
注：pid 0/1/2 在 ≥128px 被旧「三面锁档」逻辑压成单档（锤/基本体既有语言），
新母题默认不受影响（FACE_LOCK 只圈旧 7 tag），需要灰色金属仍可用 0/1/2。
"""
import math

# ── 元数据 ──────────────────────────────────────────────────────────────────
MOTIFS = []


def motif(tag, label, fake=None, az=32, el=22, key_e=4.5, margin=1.06, classic=False):
    def deco(fn):
        MOTIFS.append({"tag": "mot_" + tag, "name": tag, "label": label,
                       "fake": fake, "az": az, "el": el, "key_e": key_e,
                       "margin": margin, "classic": classic, "build": fn})
        return fn
    return deco


# ── ID 色表（与 compose 的 IDS 列表顺序严格一致，索引即 pid）────────────────
ID_COLORS = [
    (1, 0, 0),        # 0 红 → 深灰金属
    (0, 1, 0),        # 1 绿 → 中灰金属
    (0, 0, 1),        # 2 蓝 → 亮灰金属
    (1, 1, 0),        # 3 黄 → 木棕
    (1, 0, 1),        # 4 品红 → 红
    (0, 1, 1),        # 5 青 → 叶绿
    (1, 1, 1),        # 6 白 → 米白
    (0, 0, 0),        # 7 黑 → 墨炭
    (1, 0.5, 0),      # 8 橙 → 金
    (0, 0.3, 1),      # 9 藏青 → 蓝
]


# ── 建模 helpers（全部 import bpy 延迟到 Blender 内调用）────────────────────
def _chaikin(pts, it=2, closed=True):
    for _ in range(it):
        out = []
        n = len(pts)
        for i in range(n if closed else n - 1):
            a, b = pts[i], pts[(i + 1) % n]
            out.append(tuple(0.75 * a[k] + 0.25 * b[k] for k in range(3)))
            out.append(tuple(0.25 * a[k] + 0.75 * b[k] for k in range(3)))
        if not closed:
            out = [pts[0]] + out + [pts[-1]]
        pts = out
    return pts


def _finish(ob, pid):
    import bpy
    bpy.ops.object.select_all(action='DESELECT')
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.convert(target='MESH')
    ob = bpy.context.object
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.mesh.normals_make_consistent(inside=False)
    bpy.ops.object.mode_set(mode='OBJECT')
    for p in ob.data.polygons:
        p.use_smooth = True
    _base_mat(ob)
    ob["pid"] = pid
    return ob


def _base_mat(ob):
    import bpy
    if not ob.data.materials:
        ob.data.materials.append(bpy.data.materials.get('_mot_base')
                                 or bpy.data.materials.new('_mot_base'))


def box(size, loc=(0, 0, 0), rot=None, bev=0.05, bev_seg=3, pid=3, smooth=False):
    import bpy
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc, rotation=rot or (0, 0, 0))
    ob = bpy.context.object
    ob.scale = size
    if bev:
        bv = ob.modifiers.new('bev', 'BEVEL')
        bv.width = bev
        bv.segments = bev_seg
    for p in ob.data.polygons:
        p.use_smooth = smooth
    _base_mat(ob)
    ob["pid"] = pid
    return ob


def cyl(r, depth, loc=(0, 0, 0), rot=None, verts=48, bev=None, pid=3):
    import bpy
    bpy.ops.mesh.primitive_cylinder_add(radius=r, depth=depth, vertices=verts,
                                        location=loc, rotation=rot or (0, 0, 0))
    ob = bpy.context.object
    if bev:
        bv = ob.modifiers.new('bev', 'BEVEL')
        bv.width = bev
        bv.segments = 3
        bv.limit_method = 'ANGLE'
        bv.angle_limit = math.radians(40)
    _base_mat(ob)
    ob["pid"] = pid
    return ob


def sph(r, loc=(0, 0, 0), segs=(64, 40), pid=3, scale=None, rot=None):
    import bpy
    bpy.ops.mesh.primitive_uv_sphere_add(radius=r, segments=segs[0], ring_count=segs[1],
                                         location=loc, rotation=rot or (0, 0, 0))
    ob = bpy.context.object
    if scale:
        ob.scale = scale
    for p in ob.data.polygons:
        p.use_smooth = True
    _base_mat(ob)
    ob["pid"] = pid
    return ob


def cap(r, depth, loc=(0, 0, 0), rot=None, pid=3):
    """胶囊体；5.2 无 capsule 原语（属性存在但未注册，调用才报错）→ 圆柱+双球退化，
    端球沿旋转后的局部 Z 轴偏移"""
    import bpy
    from mathutils import Euler, Vector
    ob = None
    if hasattr(bpy.ops.mesh, 'primitive_capsule_add'):
        try:
            bpy.ops.mesh.primitive_capsule_add(radius=r, depth=depth, location=loc,
                                               rotation=rot or (0, 0, 0))
            ob = bpy.context.object
        except Exception:
            ob = None
    if ob is None:
        d = Euler(rot or (0, 0, 0), 'XYZ').to_matrix() @ Vector((0, 0, 1))
        cyl(r, depth, loc, rot, pid=pid)
        ob = bpy.context.object
        for s in (1, -1):
            off = d * (depth / 2 + r * 0.55) * s
            sph(r, (loc[0] + off.x, loc[1] + off.y, loc[2] + off.z), pid=pid)
    for p in ob.data.polygons:
        p.use_smooth = True
    _base_mat(ob)
    ob["pid"] = pid
    return ob


def tor(R, r, loc=(0, 0, 0), rot=None, pid=3):
    import bpy
    bpy.ops.mesh.primitive_torus_add(major_radius=R, minor_radius=r,
                                     major_segments=64, minor_segments=32,
                                     location=loc, rotation=rot or (0, 0, 0))
    ob = bpy.context.object
    for p in ob.data.polygons:
        p.use_smooth = True
    _base_mat(ob)
    ob["pid"] = pid
    return ob


def tube(pts, radius=0.07, pid=3, chaikin=2, closed=False, loc=(0, 0, 0), rot=None):
    """折线→Chaikin 光顺→圆管（连续曲线，C¹）；pts 为 (x,y,z) 三元组"""
    import bpy
    if chaikin:
        pts = _chaikin(pts, chaikin, closed)
    cu = bpy.data.curves.new('tube', 'CURVE')
    spl = cu.splines.new('POLY')
    spl.points.add(len(pts) - 1)
    for i, p in enumerate(pts):
        spl.points[i].co = (p[0], p[1], p[2], 1.0)
    spl.use_cyclic_u = closed
    cu.bevel_depth = radius
    if hasattr(cu, 'use_fill_caps'):        # 5.2 改名
        cu.use_fill_caps = True
    else:
        cu.fill_caps = True
    ob = bpy.data.objects.new('tube', cu)
    bpy.context.scene.collection.objects.link(ob)
    ob.location = loc
    ob.rotation_euler = rot or (0, 0, 0)
    return _finish(ob, pid)


def heart_mesh(scale=1.0, loc=(0, 0, 0), pid=4, extrude=0.28, bevel=0.085, lift=0.15):
    """心形（连续曲线处处 C¹，鞍部可折角）——v9 验证过的轮廓，此处缩放复用。
    默认厚枕形（创始人 2026-09-08 二轮反馈：爱心/气球立体感不足要更鼓）"""
    import bpy
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
    cu = bpy.data.curves.new('heart', 'CURVE')
    spl = cu.splines.new('POLY')
    spl.points.add(len(base) - 1)
    for i, (x, y) in enumerate(base):
        spl.points[i].co = (x * scale, (y * scale + lift), 0.0, 1.0)
    spl.use_cyclic_u = True
    cu.extrude = extrude
    cu.bevel_depth = bevel
    cu.fill_mode = 'BOTH'
    ob = bpy.data.objects.new('Heart', cu)
    bpy.context.scene.collection.objects.link(ob)
    ob = _finish(ob, pid)
    ob.rotation_euler = (math.radians(90), 0, 0)
    ob.location = loc
    return ob


def pyramid(size, depth, loc=(0, 0, 0), pid=6):
    """刻意棱面四棱锥（帐篷/塔顶）——禁锥体纪律的许可例外：4 棱不平滑无极点棱纹"""
    import bpy
    bpy.ops.mesh.primitive_cone_add(vertices=4, radius1=size, radius2=0.0,
                                    depth=depth, location=loc)
    ob = bpy.context.object
    ob.rotation_euler = (0, 0, math.radians(45))
    for p in ob.data.polygons:
        p.use_smooth = False
    _base_mat(ob)
    ob["pid"] = pid
    return ob


def crystal(r, h_body, h_tip, loc=(0, 0, 0), rot=None, pid=9):
    """四棱水晶 = 四棱柱 + 四棱尖（flat 刻面，柱轴沿局部 Z）。矿石专用：
    创始人 2026-09-08 定向不做石头嵌晶、直接做水晶形；4 棱面大，64px 棱面可读
    （6 棱太密糊成圆柱观感）"""
    import bpy
    from mathutils import Euler, Vector
    ax = Euler(rot or (0, 0, 0), 'XYZ').to_matrix() @ Vector((0, 0, 1))
    cyl(r, h_body, loc, rot, verts=4, pid=pid)
    c = loc[0] + ax.x * (h_body + h_tip) / 2, loc[1] + ax.y * (h_body + h_tip) / 2, \
        loc[2] + ax.z * (h_body + h_tip) / 2
    bpy.ops.mesh.primitive_cone_add(vertices=4, radius1=r, radius2=0.0,
                                    depth=h_tip, location=c, rotation=rot or (0, 0, 0))
    ob = bpy.context.object
    for p in ob.data.polygons:
        p.use_smooth = False
    _base_mat(ob)
    ob["pid"] = pid
    return ob


def drop_mesh(scale=1.0, loc=(0, 0, 0), pid=4, extrude=0.22, bevel=0.065):
    """水滴/火舌形实心挤出（圆底 + 收尖，连续曲线同 heart_mesh 范式）。
    篝火专用：椭球火焰被创始人判"像鸡蛋"，水滴轮廓才是火的语言"""
    import bpy
    base = [
        (0.06, 0.98), (0.10, 0.86), (0.17, 0.71), (0.27, 0.52), (0.34, 0.26),
        (0.30, 0.02), (0.16, -0.12), (0.0, -0.16), (-0.16, -0.12), (-0.30, 0.02),
        (-0.34, 0.26), (-0.27, 0.52), (-0.17, 0.71), (-0.10, 0.86),
    ]
    for _ in range(2):
        out = []
        n = len(base)
        for i in range(n):
            a, b = base[i], base[(i + 1) % n]
            out.append((0.75 * a[0] + 0.25 * b[0], 0.75 * a[1] + 0.25 * b[1]))
            out.append((0.25 * a[0] + 0.75 * b[0], 0.25 * a[1] + 0.75 * b[1]))
        base = out
    cu = bpy.data.curves.new('drop', 'CURVE')
    spl = cu.splines.new('POLY')
    spl.points.add(len(base) - 1)
    for i, (x, y) in enumerate(base):
        spl.points[i].co = (x * scale, y * scale, 0.0, 1.0)
    spl.use_cyclic_u = True
    cu.extrude = extrude * scale
    cu.bevel_depth = bevel * scale
    cu.fill_mode = 'BOTH'
    ob = bpy.data.objects.new('Drop', cu)
    bpy.context.scene.collection.objects.link(ob)
    ob = _finish(ob, pid)
    ob.rotation_euler = (math.radians(90), 0, 0)
    ob.location = loc
    return ob


# ── 元老迁移（原 gen_icon_v9 首批图标；锤子仍留 gen_icon_v9 回归套件）───────
def _heart_outline():
    """心形轮廓：16 点基形 + 三轮 2D Chaikin（与 gen_icon_v9 heart_outline 逐字一致）"""
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


@motif("heart", "爱心", az=38, el=22, key_e=5.0)
def _m_heart():
    # 曲线挤出枕形 + REMESH/SUBSURF/CAST 0.22 浅穹顶（气球感，剪影不动；
    # 强球化会把双叶/底尖磨圆成歪嘴桃子——见 v2 交接档 §九）
    import bpy
    pts = _heart_outline()
    cu = bpy.data.curves.new('heart', 'CURVE')
    spl = cu.splines.new('POLY')
    spl.points.add(len(pts) - 1)
    for i, (x, y) in enumerate(pts):
        spl.points[i].co = (x, y + 0.15, 0.0, 1.0)
    spl.use_cyclic_u = True
    cu.extrude = 0.34
    cu.bevel_depth = 0.10
    cu.fill_mode = 'BOTH'
    ob = bpy.data.objects.new('Heart', cu)
    bpy.context.scene.collection.objects.link(ob)
    ob = _finish(ob, 4)
    ob.rotation_euler = (math.radians(90), 0, 0)
    rm = ob.modifiers.new('remesh', 'REMESH')
    rm.mode = 'VOXEL'
    rm.voxel_size = 0.05
    ss = ob.modifiers.new('subdiv', 'SUBSURF')
    ss.levels = 1
    ss.render_levels = 3
    puff = ob.modifiers.new('puff', 'CAST')
    try:
        if puff.type != 'SPHERE':
            puff.type = 'SPHERE'   # 5.2 只读（默认即 SPHERE），旧版本可写
    except AttributeError:
        pass
    puff.factor = 0.22
    return ob


# ── 生产工具 ────────────────────────────────────────────────────────────────
@motif("pick", "十字镐")
def _m_pick():
    cyl(0.07, 1.15, (0, 0, 0), rot=(0, 0, math.radians(20)), pid=3)
    # 镐头=单根弯管贯穿柄顶（旧三块 box 左翼与中块不重叠=分离观感）
    tube([(-0.60, 0, 0.26), (-0.32, 0, 0.45), (0.02, 0, 0.53),
          (0.36, 0, 0.45), (0.62, 0, 0.22)], 0.075, pid=2, chaikin=2)


@motif("axe", "斧头")
def _m_axe():
    cyl(0.065, 1.15, (0, 0, 0.28), pid=3)
    # 斧刃=立三角棱柱。⚠️ 转正对镜头要 X90 后绕全局 Y 转（绕 Z 会把刃盘转侧立）
    cyl(0.33, 0.095, (0.30, 0, 0.60), rot=(math.radians(90), math.radians(-120), 0),
        verts=3, pid=2)
    box((0.16, 0.15, 0.26), (0.10, 0, 0.60), bev=0.03, pid=2)


@motif("saw", "木锯")
def _m_saw():
    # 旧版无齿无握把读作木条：补锯齿排 + 环形木握把
    c, s = math.cos(math.radians(-16)), math.sin(math.radians(-16))
    for i in range(7):
        t = -0.40 + i * 0.135
        box((0.10, 0.05, 0.055), (0.02 + t * c, 0, 0.26 + t * s - 0.145),
            rot=(0, 0, math.radians(-16)), pid=2)
    box((1.00, 0.05, 0.22), (0.02, 0, 0.26), rot=(0, 0, math.radians(-16)), pid=2)
    tor(0.14, 0.055, (0.68, 0, 0.36), pid=3)
    box((0.16, 0.10, 0.28), (0.56, 0, 0.33), rot=(0, 0, math.radians(-16)), bev=0.03, pid=3)


@motif("shovel", "铁锹")
def _m_shovel():
    cyl(0.06, 1.10, (0, 0, 0.40), pid=3)
    tor(0.13, 0.045, (0, 0, 1.00), rot=(math.radians(90), 0, 0), pid=3)   # D 形握把
    box((0.30, 0.10, 0.13), (0, 0, -0.02), pid=2)                          # 肩部
    box((0.46, 0.09, 0.52), (0, 0, -0.33), bev=0.05, pid=2)                # 方铲头（椭球=勺子观感）


@motif("handcart", "手推车")
def _m_handcart():
    box((0.95, 0.55, 0.30), (0.15, 0, 0.38), bev=0.07, pid=3)
    for x in (-0.10, 0.40):
        for y in (-0.30, 0.30):
            cyl(0.17, 0.06, (x, y, 0.17), rot=(math.radians(90), 0, 0), pid=7)  # 实心轮
    sph(0.17, (0.15, 0, 0.56), scale=(1.1, 0.75, 0.7), pid=6)                   # 车上麻袋货
    tube([(-0.28, 0, 0.50), (-0.72, 0, 0.68), (-1.02, 0, 0.66)], 0.05, pid=3)


@motif("anvil", "铁砧")
def _m_anvil():
    # 锻造/建造 UI：底座+台肩+砧身+角喙
    box((0.30, 0.30, 0.22), (0, 0, 0.11), pid=2)
    box((0.44, 0.36, 0.16), (0, 0, 0.30), pid=2)
    box((0.80, 0.30, 0.20), (0.02, 0, 0.52), bev=0.05, pid=2)
    sph(0.17, (0.52, 0, 0.52), scale=(1.25, 0.55, 0.6), pid=2)                  # 角喙


# ── 物流运输 ────────────────────────────────────────────────────────────────
@motif("boat", "小木船")
def _m_boat():
    # 帆船读法：椭圆船体+甲板+桅杆+三角帆（旧三盒拼接读不出"船"）
    sph(0.42, (0, 0, 0.26), scale=(1.6, 0.55, 0.5), pid=3)                      # 船体
    box((1.05, 0.42, 0.06), (0, 0, 0.47), pid=3)                                # 甲板
    cyl(0.035, 1.10, (0.02, 0, 0.98), pid=3)                                    # 桅杆
    cyl(0.52, 0.02, (0.35, -0.03, 1.10), rot=(math.radians(90), 0, math.radians(20)),
        verts=3, pid=6)                                                          # 三角帆
    sph(0.05, (0.02, 0, 1.56), pid=4)                                           # 桅顶旗


@motif("wagon", "货运板车")
def _m_wagon():
    box((1.15, 0.62, 0.24), (0, 0, 0.44), bev=0.06, pid=3)
    for x in (-0.38, 0.38):
        for y in (-0.34, 0.34):
            cyl(0.20, 0.07, (x, y, 0.20), rot=(math.radians(90), 0, 0), pid=7)  # 实心轮
    sph(0.20, (-0.16, 0, 0.70), scale=(1.15, 0.8, 0.85), pid=6)                 # 麻袋
    sph(0.19, (0.20, 0, 0.68), scale=(1.05, 0.75, 0.78), pid=8)                 # 货袋
    tube([(0.62, 0, 0.40), (1.00, 0, 0.26), (1.20, 0, 0.08)], 0.05, pid=3)


@motif("sack", "麻袋")
def _m_sack():
    # 旧版顶部双圆结读成骨头：改单结+麻绳扎口
    sph(0.46, (0, 0, 0.40), scale=(1.0, 0.88, 1.0), pid=6)
    cyl(0.14, 0.22, (0, 0, 0.92), pid=6)
    tor(0.145, 0.05, (0, 0, 1.00), rot=(math.radians(90), 0, 0), pid=5)         # 麻绳
    sph(0.11, (0, 0, 1.10), scale=(1, 0.85, 0.8), pid=6)                        # 顶结


@motif("barrel", "木桶")
def _m_barrel():
    # 矮胖桶+深色铁箍（旧细高+箍同色读成罐子）
    cyl(0.46, 0.72, (0, 0, 0.40), pid=3)
    tor(0.47, 0.05, (0, 0, 0.60), rot=(math.radians(90), 0, 0), pid=7)
    tor(0.47, 0.05, (0, 0, 0.20), rot=(math.radians(90), 0, 0), pid=7)
    cyl(0.36, 0.05, (0, 0, 0.78), pid=3)                                        # 顶盖


@motif("crate", "板条箱")
def _m_crate():
    # 竖板条+上下横框（旧单根斜条读成礼盒丝带）
    box((0.85, 0.85, 0.75), (0, 0, 0.40), bev=0.04, pid=3)
    for x in (-0.26, 0, 0.26):
        box((0.16, 0.06, 0.60), (x, -0.44, 0.40), pid=8)                        # 前脸竖板条
    box((0.92, 0.06, 0.10), (0, -0.44, 0.72), pid=8)
    box((0.92, 0.06, 0.10), (0, -0.44, 0.08), pid=8)


@motif("lantern", "提灯")
def _m_lantern():
    # 四柱笼式（旧实心灯室挡火）：内部火苗可见
    box((0.50, 0.50, 0.09), (0, 0, 0.10), bev=0.03, pid=2)
    for x in (-0.20, 0.20):
        for y in (-0.20, 0.20):
            box((0.06, 0.06, 0.55), (x, y, 0.42), pid=2)                        # 四角柱
    drop_mesh(0.42, (0, 0, 0.24), pid=4, extrude=0.09, bevel=0.03)              # 内焰
    box((0.54, 0.54, 0.09), (0, 0, 0.74), bev=0.03, pid=2)
    box((0.14, 0.14, 0.12), (0, 0, 0.83), bev=0.03, pid=2)
    tor(0.13, 0.04, (0, 0, 0.98), rot=(math.radians(90), 0, 0), pid=2)          # 提环


@motif("signpost", "路牌", fake=(0.10, 0.02, 0.18), classic=True)
def _m_signpost():
    cyl(0.06, 1.30, (0, 0, 0.65), pid=3)
    box((0.85, 0.07, 0.30), (0.05, 0, 0.98), rot=(0, math.radians(6), math.radians(4)), bev=0.04, pid=6)
    box((0.62, 0.07, 0.24), (-0.08, 0, 0.62), rot=(0, math.radians(-5), math.radians(-3)), bev=0.04, pid=6)
    sph(0.045, (0.30, -0.05, 0.98), pid=2)
    sph(0.045, (0.10, -0.05, 0.62), pid=2)


# ── 经济资源 ────────────────────────────────────────────────────────────────
@motif("bread", "面包")
def _m_bread():
    # 斜置长棍+侧面割痕（枕形割痕在俯视角只露点读不出）
    cap(0.23, 1.05, (0, 0, 0.42), rot=(0, math.radians(90), math.radians(-24)), pid=8)
    for t in (-0.34, 0.0, 0.34):
        px = t * math.cos(math.radians(66))
        py = -t * math.sin(math.radians(66))
        box((0.055, 0.055, 0.26), (px, py, 0.55), rot=(0, 0, math.radians(66)), pid=3)


@motif("gold_coin", "金币")
def _m_gold_coin():
    # 西式金币堆（三枚小角度错叠，旧 44° 大转差+星歪斜塌成薯片）
    for i, (z, ry) in enumerate(((0.10, 0.0), (0.26, math.radians(14)), (0.42, math.radians(28)))):
        cyl(0.42 - i * 0.02, 0.13, (0, 0, z), rot=(math.radians(90), 0, ry), pid=8)
        tor(0.40 - i * 0.02, 0.034, (0, 0, z), rot=(math.radians(90), 0, ry), pid=8)
    pts = []   # 顶枚五角星浮雕：随顶枚同角度转，chaikin=0 保星角尖锐
    for k in range(10):
        a = math.radians(90 + k * 36)
        r = 0.20 if k % 2 == 0 else 0.088
        pts.append((math.cos(a) * r, math.sin(a) * r, 0.075))
    tube(pts, 0.028, pid=6, chaikin=0, closed=True,
         loc=(0, 0, 0.42), rot=(math.radians(90), 0, math.radians(28)))


@motif("ore", "矿石")
def _m_ore():
    # 水晶簇：4 棱刻面尖刺（旧晶柱太钝读成圆水滴）
    sph(0.32, (0, 0, 0.14), scale=(1.3, 0.9, 0.5), pid=1)                 # 低矮岩基
    crystal(0.145, 0.30, 0.58, (-0.05, 0.02, 0.42),
            rot=(math.radians(-5), math.radians(7), math.radians(8)), pid=9)
    crystal(0.115, 0.22, 0.46, (0.28, -0.05, 0.34),
            rot=(math.radians(24), math.radians(10), math.radians(-18)), pid=9)
    crystal(0.10, 0.18, 0.36, (-0.33, -0.06, 0.30),
            rot=(math.radians(-14), math.radians(-12), math.radians(26)), pid=5)


@motif("fish", "小鱼干")
def _m_fish():
    # 尾鳍小型化贴身（旧两片大斜板离体读成炸弹翼）
    sph(0.26, (0.0, 0, 0.42), scale=(1.45, 0.5, 0.7), rot=(0, 0, math.radians(-6)), pid=8)
    box((0.20, 0.035, 0.13), (-0.42, 0, 0.52), rot=(0, math.radians(30), math.radians(30)), pid=8)
    box((0.20, 0.035, 0.13), (-0.42, 0, 0.32), rot=(0, math.radians(-30), math.radians(-30)), pid=8)
    box((0.13, 0.035, 0.12), (0.04, 0, 0.62), rot=(0, math.radians(12), 0), pid=8)
    sph(0.035, (0.38, -0.10, 0.46), pid=7)


@motif("apple", "苹果")
def _m_apple():
    # 食物/农业 UI：红果+柄+叶+高光
    sph(0.44, (0, 0, 0.42), scale=(1.0, 0.92, 0.9), pid=4)
    cyl(0.04, 0.18, (0, 0, 0.86), rot=(0, math.radians(10), 0), pid=3)
    sph(0.11, (0.13, 0.03, 0.90), scale=(1.4, 0.35, 0.55), rot=(0, 0, math.radians(24)), pid=5)
    sph(0.05, (-0.15, -0.28, 0.62), pid=6)


@motif("wheat", "麦穗")
def _m_wheat():
    # 收成/农业 UI：麦秆+交错麦粒+叶
    tube([(0, 0, 0), (0.02, 0, 0.55), (0.0, 0, 1.05)], 0.035, pid=5, chaikin=2)
    for i in range(6):
        z = 0.72 + i * 0.115
        s = 1 - i * 0.075
        cap(0.055 * s, 0.17, (0.055 * s, 0, z), rot=(0, math.radians(-34), 0), pid=8)
        cap(0.055 * s, 0.17, (-0.055 * s, 0, z + 0.055), rot=(0, math.radians(34), 0), pid=8)
    sph(0.16, (0.15, 0, 0.28), scale=(0.8, 0.10, 0.30), rot=(0, 0, math.radians(38)), pid=5)


# ── 组织权力 ────────────────────────────────────────────────────────────────
@motif("seal", "印章", az=18, el=12, key_e=6.5)
def _m_seal():
    # 创始人 2026-09-08 定向：现代公章（红圆盘+柄），不要中式玉玺
    from mathutils import Euler, Vector
    tilt = math.radians(26)
    ax = Euler((tilt, 0, 0), 'XYZ').to_matrix() @ Vector((0, 0, 1))   # 章面法线
    cyl(0.46, 0.14, (0, 0, 0.10), rot=(tilt, 0, 0), pid=4)           # 红章盘（斜置露章面）
    off = ax * 0.30
    cyl(0.115, 0.42, (off.x, off.y, 0.10 + off.z), rot=(tilt, 0, 0), pid=3)  # 木柄沿法线
    off2 = ax * 0.56
    sph(0.16, (off2.x, off2.y, 0.10 + off2.z), scale=(1, 1, 0.8), pid=3)     # 顶帽


@motif("flag", "旗帜", az=24, el=14, key_e=6.0)
def _m_flag():
    # 旗面全部挂在杆右侧渐进旋转（旧对称分布飘到杆两侧像耳朵）
    cyl(0.045, 1.65, (0, 0, 0.82), pid=3)
    sph(0.07, (0, 0, 1.68), pid=8)
    for i, x in enumerate((0.16, 0.43, 0.70)):
        box((0.30, 0.05, 0.40), (x, 0.04 * i, 1.40 - abs(i - 1) * 0.03),
            rot=(0, math.radians(-4 + 12 * i), 0), pid=4)


@motif("scroll", "卷轴", az=24, el=12, key_e=6.0)
def _m_scroll():
    # 上下双卷轴（旧单杆像挂纸巾）+ 火漆印
    cyl(0.07, 1.02, (0, 0, 1.00), rot=(0, math.radians(90), 0), pid=8)
    cyl(0.16, 0.94, (0, 0, 1.00), rot=(0, math.radians(90), 0), pid=6)
    box((0.80, 0.05, 0.70), (0, 0, 0.58), pid=6)
    cyl(0.10, 0.90, (0, 0, 0.17), rot=(0, math.radians(90), 0), pid=6)          # 底卷
    cyl(0.045, 1.08, (0, 0, 1.00), rot=(0, math.radians(90), 0), pid=8)         # 轴芯出头
    cyl(0.045, 1.04, (0, 0, 0.17), rot=(0, math.radians(90), 0), pid=8)
    cyl(0.085, 0.05, (0.12, -0.05, 0.56), rot=(math.radians(90), 0, 0), pid=4)  # 火漆印


@motif("chair", "高背椅")
def _m_chair():
    # 板条背（旧整块背板+双金球读成墓碑眼睛）+ 金坐垫；
    # 背柱真落地（旧柱长只到座面，256px 复审发现后半悬空缺腿）
    box((0.66, 0.58, 0.10), (0, 0, 0.46), bev=0.03, pid=3)                      # 座面
    for x in (-0.28, 0.28):
        cyl(0.045, 1.48, (x, 0.24, 0.74), pid=3)                                # 背柱兼后腿（z 0..1.48 落地）
        cyl(0.05, 0.44, (x, -0.22, 0.22), pid=3)                                # 前腿
    for z in (0.80, 1.04, 1.28):
        box((0.58, 0.07, 0.10), (0, 0.24, z), pid=3)                            # 背板条×3
    box((0.54, 0.48, 0.09), (0, -0.02, 0.55), bev=0.04, pid=8)                  # 金坐垫
    sph(0.06, (0, 0.24, 1.52), pid=8)


@motif("whistle", "哨子")
def _m_whistle():
    # 豌豆哨：横筒+同轴侧吹嘴+尾环（旧吹嘴竖在背上读不出哨）
    cyl(0.19, 0.42, (0.14, 0, 0.40), rot=(0, math.radians(90), 0), pid=8)
    box((0.32, 0.15, 0.10), (-0.22, 0, 0.44), rot=(0, math.radians(-8), 0), bev=0.03, pid=8)
    tor(0.11, 0.035, (0.44, 0, 0.40), rot=(0, math.radians(90), 0), pid=8)
    sph(0.05, (0.10, 0, 0.60), pid=7)                                           # 哨孔


@motif("crown", "王冠")
def _m_crown():
    # 直立冠环（旧环面朝镜头读成笑脸）：金环+上下箍沿+一圈尖+正面宝石
    cyl(0.44, 0.24, (0, 0, 0.32), pid=8)
    tor(0.44, 0.04, (0, 0, 0.44), rot=(math.radians(90), 0, 0), pid=8)
    tor(0.44, 0.04, (0, 0, 0.20), rot=(math.radians(90), 0, 0), pid=8)
    for a in (0, 60, 120, 180, 240, 300):
        r_ = math.radians(a)
        pyramid(0.085, 0.30, (math.cos(r_) * 0.36, math.sin(r_) * 0.36, 0.58), pid=8)
    sph(0.055, (0, -0.44, 0.32), pid=4)
    sph(0.05, (0.32, -0.31, 0.32), pid=9)


@motif("moneybag", "钱袋")
def _m_moneybag():
    # 经济/金库 UI：梨形袋身（双球叠）+宽口金币外露（圆球细颈读成手雷）
    sph(0.42, (0, 0, 0.30), scale=(1.1, 0.95, 0.9), pid=3)
    sph(0.33, (0, 0, 0.66), scale=(0.85, 0.75, 0.7), pid=3)                     # 袋肩收窄
    cyl(0.22, 0.14, (0, 0, 0.92), pid=3)                                        # 宽口
    cyl(0.13, 0.05, (0.06, -0.10, 0.96), rot=(math.radians(22), 0, 0), pid=8)   # 口沿金币
    sph(0.08, (-0.14, -0.06, 0.98), pid=8)


@motif("scale", "天平")
def _m_scale():
    # 交易/司法 UI：立柱天平+双盘砝码
    box((0.62, 0.30, 0.10), (0, 0, 0.06), bev=0.03, pid=3)
    cyl(0.05, 1.00, (0, 0, 0.58), pid=3)
    box((1.30, 0.06, 0.07), (0, 0, 1.10), pid=3)
    sph(0.06, (0, 0, 1.10), pid=8)
    for x in (-0.55, 0.55):
        tube([(x - 0.15, 0, 1.02), (x, 0, 0.84), (x + 0.15, 0, 1.02)], 0.02, pid=6, chaikin=1)
        cyl(0.20, 0.045, (x, 0, 0.76), rot=(math.radians(90), 0, 0), pid=8)
    sph(0.085, (-0.55, 0, 0.82), pid=4)                                         # 红砝码
    sph(0.07, (0.55, 0, 0.80), pid=9)


@motif("envelope", "信封")
def _m_envelope():
    # 情报/外交/信件 UI：立放信封+三角盖+火漆
    box((0.95, 0.06, 0.62), (0, 0, 0.30), pid=6)
    cyl(0.33, 0.03, (0, -0.045, 0.61), rot=(math.radians(90), 0, math.radians(-90)),
        verts=3, pid=6)                                                          # 封盖三角
    sph(0.06, (0, -0.07, 0.46), pid=4)                                          # 火漆


@motif("olive", "橄榄枝")
def _m_olive():
    # 和平/休战 UI：弯枝+对生叶（叶角更陡防"梯子"感）+果
    tube([(-0.55, 0, 0.10), (-0.10, 0, 0.42), (0.35, 0, 0.85), (0.62, 0, 1.25)], 0.04,
         pid=5, chaikin=2)
    for x, z in ((-0.28, 0.26), (0.0, 0.46), (0.24, 0.70), (0.44, 0.96)):
        sph(0.13, (x - 0.10, 0.03, z + 0.10), scale=(1.5, 0.26, 0.45),
            rot=(0, 0, math.radians(56)), pid=5)
        sph(0.12, (x + 0.10, -0.03, z - 0.04), scale=(1.4, 0.26, 0.45),
            rot=(0, 0, math.radians(56)), pid=6)
    sph(0.07, (0.60, 0, 1.16), pid=7)                                           # 橄榄果


@motif("keys", "钥匙串", fake=(0.10, 0.02, 0.18), classic=True)
def _m_keys():
    tor(0.28, 0.065, (0, 0, 0.85), rot=(math.radians(90), 0, 0), pid=8)
    tor(0.13, 0.05, (0.14, -0.04, 0.42), rot=(0, math.radians(90), 0), pid=2)
    box((0.11, 0.06, 0.44), (0.14, -0.04, 0.16), pid=2)
    box((0.15, 0.06, 0.08), (0.22, -0.04, 0.07), pid=2)
    box((0.12, 0.06, 0.08), (0.20, -0.04, 0.18), pid=2)
    tor(0.11, 0.045, (-0.20, 0.04, 0.52), rot=(math.radians(20), math.radians(90), math.radians(15)), pid=4)
    box((0.10, 0.06, 0.38), (-0.25, 0.05, 0.28), rot=(math.radians(20), 0, 0), pid=4)
    box((0.14, 0.06, 0.07), (-0.18, 0.03, 0.20), rot=(math.radians(20), 0, 0), pid=4)


@motif("ledger", "账本", az=20, el=10, key_e=6.0, fake=(0.10, 0.05, 0.38), classic=True)
def _m_ledger():
    box((0.82, 0.20, 1.02), (0, 0, 0.55), bev=0.05, pid=4)
    box((0.74, 0.14, 0.94), (0.03, -0.05, 0.55), pid=6)
    box((0.10, 0.24, 1.04), (-0.22, 0, 0.55), pid=8)



@motif("flask", "药瓶")
def _m_flask():
    # 透明瓶=轮廓曲线勾瓶壁（空心可见空气/药水；旧实心瓶读不出玻璃）
    prof = [(-0.10, 1.30), (-0.13, 1.10), (-0.17, 0.94), (-0.36, 0.80), (-0.45, 0.58),
            (-0.40, 0.30), (-0.22, 0.13), (0, 0.10), (0.22, 0.13), (0.40, 0.30),
            (0.45, 0.58), (0.36, 0.80), (0.17, 0.94), (0.13, 1.10), (0.10, 1.30)]
    tube([(x, 0, z) for x, z in prof], 0.042, pid=6, chaikin=2)
    sph(0.30, (0, 0, 0.42), scale=(1.12, 0.85, 0.9), pid=5)                     # 药水
    cyl(0.075, 0.12, (0, 0, 1.33), pid=3)                                       # 软木塞
    sph(0.045, (0.10, 0.05, 0.52), pid=6)                                       # 气泡
    sph(0.032, (-0.08, 0.05, 0.36), pid=6)


@motif("erlenmeyer", "锥形瓶")
def _m_erlenmeyer():
    # 化工/科技 UI：三角烧瓶，同透明瓶语言
    prof = [(-0.09, 1.22), (-0.11, 1.02), (-0.18, 0.78), (-0.30, 0.50), (-0.40, 0.24),
            (-0.42, 0.14), (0, 0.11), (0.42, 0.14), (0.40, 0.24), (0.30, 0.50),
            (0.18, 0.78), (0.11, 1.02), (0.09, 1.22)]
    tube([(x, 0, z) for x, z in prof], 0.040, pid=6, chaikin=2)
    cyl(0.23, 0.15, (0, 0, 0.21), pid=9)                                        # 蓝试剂
    cyl(0.085, 0.10, (0, 0, 1.26), pid=6)                                       # 瓶口沿


@motif("testrack", "试管架")
def _m_testrack():
    # 三支试管（U 形轮廓管=透明）+ 木架，三色液体
    box((1.05, 0.30, 0.08), (0, 0, 0.06), bev=0.02, pid=3)                      # 底座
    box((1.05, 0.14, 0.10), (0, 0, 0.72), pid=3)                                # 上横梁
    for x in (-0.46, 0.46):
        box((0.08, 0.24, 0.70), (x, 0, 0.40), pid=3)                            # 立柱
    for x, c in ((-0.30, 4), (0.0, 5), (0.30, 8)):
        prof = [(x - 0.075, 0, 0.92), (x - 0.075, 0, 0.26), (x, 0, 0.16),
                (x + 0.075, 0, 0.26), (x + 0.075, 0, 0.92)]
        tube(prof, 0.026, pid=6, chaikin=2)
        cyl(0.052, 0.20, (x, 0, 0.30), pid=c)                                   # 液体柱


@motif("hourglass", "沙漏")
def _m_hourglass():
    # 时间/回合 UI：木框+玻璃轮廓+沙（下堆+流柱）
    cyl(0.36, 0.06, (0, 0, 0.92), pid=3)
    cyl(0.40, 0.07, (0, 0, 0.06), pid=3)
    for x in (-0.28, 0.28):
        cyl(0.035, 0.92, (x, 0, 0.48), pid=3)
    prof = [(-0.26, 0.88), (-0.19, 0.64), (-0.055, 0.50), (-0.24, 0.24), (-0.30, 0.12),
            (0, 0.10), (0.30, 0.12), (0.24, 0.24), (0.055, 0.50), (0.19, 0.64), (0.26, 0.88)]
    tube([(x, 0, z) for x, z in prof], 0.032, pid=6, chaikin=2)
    cyl(0.23, 0.11, (0, 0, 0.18), pid=8)                                        # 底沙
    pyramid(0.15, 0.11, (0, 0, 0.29), pid=8)                                    # 沙堆
    cyl(0.018, 0.30, (0, 0, 0.42), pid=8)                                       # 流沙柱


@motif("quill", "羽毛笔")
def _m_quill():
    # 羽=羽轴管+两侧斜羽枝（实心水滴读成勺/棒棒糖）
    tube([(-0.20, 0, 0.28), (-0.02, 0, 0.58), (0.18, 0, 0.92), (0.30, 0, 1.12)],
         0.028, pid=6, chaikin=2)                                               # 羽轴
    for i in range(6):
        t = i / 5
        px = -0.14 + t * 0.42
        pz = 0.42 + t * 0.62
        ln = 0.26 - t * 0.10
        sph(ln * 0.5, (px - ln * 0.30, 0, pz + 0.07), scale=(1.7, 0.10, 0.42),
            rot=(0, 0, math.radians(32)), pid=6)                                # 左羽枝
        sph(ln * 0.46, (px + ln * 0.28, 0, pz - 0.05), scale=(1.6, 0.10, 0.40),
            rot=(0, 0, math.radians(32)), pid=6)                                # 右羽枝
    cyl(0.02, 0.10, (-0.24, 0, 0.20), rot=(0, math.radians(-40), 0), pid=7)     # 笔尖
    cyl(0.11, 0.035, (-0.30, 0, 0.06), pid=9)                                   # 墨池


@motif("medkit", "医疗箱")
def _m_medkit():
    # 治疗/医疗 UI：白箱+绿十字（红十字为红十字保护标志，游戏内用绿十字）+提手
    box((0.85, 0.45, 0.62), (0, 0, 0.33), bev=0.06, pid=6)
    box((0.40, 0.06, 0.12), (0, -0.24, 0.38), pid=5)                            # 十字横
    box((0.12, 0.06, 0.38), (0, -0.24, 0.38), pid=5)                            # 十字竖
    tor(0.10, 0.03, (0, 0, 0.70), rot=(0, 0, 0), pid=3)                         # 提手


@motif("gear", "齿轮")
def _m_gear():
    cyl(0.52, 0.22, (0, 0, 0.45), rot=(math.radians(90), 0, 0), pid=2)
    for i in range(8):
        a = math.radians(i * 45)
        box((0.20, 0.18, 0.16), (math.cos(a) * 0.60, 0, 0.45 + math.sin(a) * 0.60),
            rot=(0, -a, 0), pid=2)
    cyl(0.16, 0.26, (0, 0, 0.45), rot=(math.radians(90), 0, 0), pid=8)


@motif("books", "两本书", az=20, el=12, key_e=6.0)
def _m_books():
    # 书口白页右侧外露（旧白页顶面外露读成夹心蛋糕层）
    box((0.92, 0.66, 0.18), (0, 0, 0.10), bev=0.03, pid=4)                      # 红封面壳
    box((0.78, 0.52, 0.12), (0.08, 0, 0.11), pid=6)                             # 书口白页外露
    box((0.80, 0.56, 0.16), (0.02, 0.02, 0.30), rot=(0, 0, math.radians(12)),
        bev=0.03, pid=9)                                                        # 蓝封面斜叠
    box((0.68, 0.44, 0.10), (0.09, 0.02, 0.31), rot=(0, 0, math.radians(12)), pid=6)
    box((0.14, 0.34, 0.05), (-0.04, -0.06, 0.42), rot=(0, 0, math.radians(12)), pid=8)  # 书签带


@motif("magnifier", "放大镜")
def _m_magnifier():
    # 细环+淡蓝镜片+细长柄（旧粗环奶白镜片+粗柄读成平底锅）
    tor(0.40, 0.06, (0, 0, 0.72), rot=(math.radians(90), 0, 0), pid=2)
    cyl(0.37, 0.035, (0, 0, 0.72), rot=(math.radians(90), 0, 0), pid=9)         # 淡蓝镜片
    tube([(0.16, 0, 0.44), (0.32, 0, 0.22), (0.54, 0, -0.12)], 0.045, pid=3, chaikin=2)
    sph(0.05, (-0.13, -0.02, 0.86), pid=6)                                      # 镜面高光




@motif("telescope", "望远镜")
def _m_telescope():
    d = (math.cos(math.radians(28)), 0, math.sin(math.radians(28)))
    cyl(0.19, 0.52, (d[0] * -0.50, 0, 0.62 + d[2] * -0.50), rot=(0, math.radians(62), 0), pid=2)
    cyl(0.15, 0.50, (d[0] * 0.02, 0, 0.62 + d[2] * 0.02), rot=(0, math.radians(62), 0), pid=8)
    cyl(0.115, 0.46, (d[0] * 0.52, 0, 0.62 + d[2] * 0.52), rot=(0, math.radians(62), 0), pid=2)
    sph(0.10, (d[0] * -0.82, 0, 0.62 + d[2] * -0.82), pid=7)


# ── 战斗 ────────────────────────────────────────────────────────────────────
@motif("sword", "短剑", fake=(0.10, 0.02, 0.18), classic=True)
def _m_sword():
    box((0.30, 0.09, 1.15), (0, 0, 0.76), bev=0.04, pid=2)
    box((0.20, 0.06, 0.26), (0, 0, 1.42), rot=(0, math.radians(45), 0), pid=2)
    box((0.58, 0.15, 0.12), (0, 0, 0.12), bev=0.03, pid=8)
    cyl(0.075, 0.34, (0, 0, -0.14), pid=4)
    sph(0.10, (0, 0, -0.37), pid=8)


@motif("spear", "长矛")
def _m_spear():
    # 薄叶刃+单道缠绳（旧双红环读成蛇缠）
    cyl(0.07, 1.55, (0, 0, 0.35), pid=3)
    sph(0.14, (0, 0, 1.30), scale=(0.55, 0.28, 1.9), pid=2)
    tor(0.08, 0.035, (0, 0, 1.04), rot=(math.radians(90), 0, 0), pid=3)


@motif("shield", "圆盾", az=20, el=10)
def _m_shield():
    # 鸢盾（heater）轮廓挤出——正圆+同心圆读成箭靶
    base = [(-0.50, 0.78), (0, 0.90), (0.50, 0.78), (0.56, 0.40), (0.40, -0.05),
            (0.18, -0.36), (0, -0.55), (-0.18, -0.36), (-0.40, -0.05), (-0.56, 0.40)]
    for _ in range(3):
        out = []
        n = len(base)
        for i in range(n):
            a, b = base[i], base[(i + 1) % n]
            out.append((0.75 * a[0] + 0.25 * b[0], 0.75 * a[1] + 0.25 * b[1]))
            out.append((0.25 * a[0] + 0.75 * b[0], 0.25 * a[1] + 0.75 * b[1]))
        base = out
    import bpy
    cu = bpy.data.curves.new('shield', 'CURVE')
    spl = cu.splines.new('POLY')
    spl.points.add(len(base) - 1)
    for i, (x, z) in enumerate(base):
        spl.points[i].co = (x, z + 0.55, 0.0, 1.0)
    spl.use_cyclic_u = True
    cu.extrude = 0.15
    cu.bevel_depth = 0.055
    cu.fill_mode = 'BOTH'
    ob = bpy.data.objects.new('Shield', cu)
    bpy.context.scene.collection.objects.link(ob)
    ob = _finish(ob, 4)
    ob.rotation_euler = (math.radians(90), 0, 0)


@motif("bow", "弓箭")
def _m_bow():
    # 弓臂开角 150°，弦接两端，箭头左/羽尾右归位（旧羽装在箭头端）
    pts = []
    for i in range(13):
        a = math.radians(-75 + i * (150 / 12))
        pts.append((math.cos(a) * 0.70, 0, 0.55 + math.sin(a) * 0.70))
    tube(pts, 0.09, pid=3, chaikin=2)
    cyl(0.018, 1.36, (0.181, 0, 0.55), pid=6)                                   # 弦
    cyl(0.04, 0.90, (-0.30, 0, 0.55), rot=(0, math.radians(90), 0), pid=2)      # 箭杆（尾扣弦）
    cyl(0.07, 0.16, (-0.82, 0, 0.55), rot=(0, math.radians(-90), 0), verts=4, pid=2)  # 箭头
    box((0.17, 0.03, 0.13), (0.00, 0, 0.63), rot=(0, 0, math.radians(18)), pid=4)     # 羽尾×2
    box((0.17, 0.03, 0.13), (0.00, 0, 0.47), rot=(0, 0, math.radians(-18)), pid=4)


@motif("drum", "战鼓")
def _m_drum():
    # 战鼓标志=侧面交叉拉绳（旧金环绕鼓读成蛋糕箍）
    cyl(0.50, 0.55, (0, 0, 0.42), pid=4)
    cyl(0.44, 0.06, (0, 0, 0.72), pid=6)
    cyl(0.44, 0.06, (0, 0, 0.12), pid=6)
    for i in range(4):
        a0 = math.radians(i * 90 + 25)
        a1 = math.radians(i * 90 + 85)
        tube([(math.cos(a0) * 0.505, math.sin(a0) * 0.505, 0.68),
              (math.cos((a0 + a1) / 2) * 0.52, math.sin((a0 + a1) / 2) * 0.52, 0.42),
              (math.cos(a1) * 0.505, math.sin(a1) * 0.505, 0.16)], 0.028, pid=3, chaikin=1)
    cap(0.035, 0.52, (0.18, 0.12, 0.80), rot=(0, math.radians(58), math.radians(30)), pid=3)
    cap(0.035, 0.52, (-0.14, -0.16, 0.80), rot=(0, math.radians(58), math.radians(-35)), pid=3)


@motif("helmet", "头盔")
def _m_helmet():
    # 扁盔顶+宽檐+护鼻+盔缨拱（旧正球+细环读成气球）
    sph(0.48, (0, 0, 0.44), scale=(1.0, 0.95, 0.75), pid=2)
    cyl(0.50, 0.09, (0, 0, 0.26), rot=(math.radians(90), 0, 0), pid=2)          # 檐
    box((0.09, 0.10, 0.26), (0, -0.44, 0.40), pid=2)                            # 护鼻
    tube([(0, -0.08, 0.84), (0.05, 0, 1.02), (0, 0.08, 0.84)], 0.055, pid=4, chaikin=2)  # 盔缨


@motif("sling", "弹弓")
def _m_sling():
    # Y 收紧+皮筋 V 兜石下拉（旧平弧兜+悬球读不出弹弓发力）
    cyl(0.09, 0.60, (0, 0, 0.30), pid=3)
    tube([(0, 0, 0.56), (-0.13, 0, 0.92), (-0.18, 0, 1.18)], 0.075, pid=3, chaikin=2)
    tube([(0, 0, 0.56), (0.13, 0, 0.92), (0.18, 0, 1.18)], 0.075, pid=3, chaikin=2)
    tube([(-0.18, 0, 1.14), (0, 0, 0.80), (0.18, 0, 1.14)], 0.045, pid=4, chaikin=2)
    sph(0.11, (0, 0, 0.84), pid=7)


@motif("cannon", "小炮")
def _m_cannon():
    # 炮管 30° 仰角；轮子必须在炮管正下方（旧轮炮水平错位读成两件套）
    ax = math.radians(30)
    cyl(0.155, 0.88, (-0.10, 0, 0.58), rot=(0, ax, 0), pid=2)
    cyl(0.19, 0.10, (-0.10 + math.sin(ax) * 0.44, 0, 0.58 + math.cos(ax) * 0.44),
        rot=(0, ax, 0), pid=7)                                                  # 炮口箍
    sph(0.13, (-0.10 - math.sin(ax) * 0.44, 0, 0.58 - math.cos(ax) * 0.44), pid=2)  # 尾球
    box((0.88, 0.24, 0.09), (-0.06, 0, 0.36), rot=(0, math.radians(-30), 0), pid=3) # 炮架
    for y in (-0.26, 0.26):
        cyl(0.19, 0.06, (-0.10, y, 0.19), rot=(math.radians(90), 0, 0), pid=7)  # 轮（居中）
        tor(0.19, 0.04, (-0.10, y, 0.19), rot=(math.radians(90), 0, 0), pid=3)  # 轮辋


# ── 扩张探索 ────────────────────────────────────────────────────────────────
@motif("maproll", "卷地图", az=20, el=10, key_e=6.0)
def _m_maproll():
    # 双卷杆+图面路线标记（旧单杆白纸读成挂纸巾）
    cyl(0.13, 1.00, (0, 0, 1.00), rot=(0, math.radians(90), 0), pid=6)
    cyl(0.10, 0.90, (0, 0, 0.18), rot=(0, math.radians(90), 0), pid=6)          # 底卷
    box((0.84, 0.05, 0.68), (0.02, 0, 0.56), pid=6)
    for i in range(4):                                                          # 红色虚线路线
        sph(0.032, (-0.26 + i * 0.17, -0.045, 0.70 - i * 0.13), pid=4)
    pyramid(0.075, 0.13, (0.28, -0.045, 0.68), pid=2)                           # 小山
    sph(0.055, (0.28, -0.045, 0.34), pid=9)                                     # 湖


@motif("compass_nav", "罗盘", az=14, el=10, key_e=7.0)
def _m_compass_nav():
    import bpy
    tor(0.50, 0.055, (0, 0, 0.10), rot=(math.radians(90), 0, 0), pid=8)   # 金环
    cyl(0.46, 0.11, (0, 0, 0.10), rot=(math.radians(90), 0, 0), pid=6)    # 米白表盘
    # ⚠️ 相机在 -y 侧（v9 教训），指针/刻点必须放盘面之前（-y）。
    # 指针斜指东北-西南；4 灰刻点会读成时钟 → 换顶部单个红色北标
    bpy.ops.mesh.primitive_cone_add(vertices=4, radius1=0.16, depth=0.32,
                                    location=(0.085, -0.05, 0.19),
                                    rotation=(0, math.radians(35), 0))
    north = bpy.context.object                  # 欧拉只绕 Y：+z 轴向 (sin35,0,cos35)=东北
    bpy.ops.mesh.primitive_cone_add(vertices=4, radius1=0.16, depth=0.36,
                                    location=(-0.097, -0.05, -0.06),
                                    rotation=(0, math.radians(215), 0))
    south = bpy.context.object                  # 215° → 轴向西南下
    for ob in (north, south):
        ob.scale = (1, 0.4, 1)
        for p in ob.data.polygons:
            p.use_smooth = False
        _base_mat(ob)
    north["pid"] = 4
    south["pid"] = 6
    box((0.09, 0.08, 0.09), (0, -0.04, 0.385), rot=(0, 0, math.radians(45)), pid=4)  # 北标
    sph(0.055, (0, -0.07, 0.05), pid=2)  # 中心轴帽


@motif("horseshoe", "马蹄铁")
def _m_horseshoe():
    pts = []
    for i in range(21):
        a = math.radians(120 + i * (300 / 20))
        pts.append((math.cos(a) * 0.52, 0, 0.50 + math.sin(a) * 0.52))
    tube(pts, 0.10, pid=2, chaikin=2, closed=True)


@motif("tent", "帐篷")
def _m_tent():
    # 脊沿纵深（三角山墙朝镜头）=经典帐篷正面读法（脊沿横放读成折叠布单）
    cyl(0.85, 1.20, (0, 0, 0.22), rot=(math.radians(-90), 0, 0), verts=3, pid=6)
    cyl(0.42, 0.06, (0, -0.60, 0.15), rot=(math.radians(-90), 0, 0), verts=3, pid=7)  # 门
    sph(0.055, (0, 0.62, 1.10), pid=8)                                          # 脊顶饰
    box((0.05, 0.20, 0.14), (0.12, 0.62, 1.12), rot=(math.radians(10), 0, 0), pid=4)  # 小旗


@motif("campfire", "篝火")
def _m_campfire():
    # 火舌收窄拉高+柴火加大外露（旧火焰太圆+柴埋没）
    for a in (0, 60, 120):
        cyl(0.09, 0.92, (0, 0, 0.06), rot=(math.radians(90), 0, math.radians(a)), pid=3)
    flame = drop_mesh(0.78, (0, 0, 0.10), pid=4, extrude=0.20, bevel=0.06)
    flame.scale = (1.0, 1.15, 1.0)   # 局部 Y=世界 Z（rotX90 后），拉高火舌
    drop_mesh(0.45, (0, -0.06, 0.28), pid=8, extrude=0.16, bevel=0.05)          # 内焰金（前置）


@motif("watchtower", "瞭望塔")
def _m_watchtower():
    # 四腿架高+平台+塔室+红顶（旧实心方箱读成鸟屋）
    for x in (-0.30, 0.30):
        for y in (-0.24, 0.24):
            cyl(0.06, 0.62, (x, y, 0.30), pid=3)                                # 四腿
    box((1.00, 0.80, 0.10), (0, 0, 0.66), pid=3)                                # 平台
    box((0.78, 0.62, 0.52), (0, 0, 0.97), pid=3)                                # 塔室
    box((0.14, 0.05, 0.16), (0, -0.32, 0.96), pid=7)                            # 窗
    box((0.98, 0.80, 0.07), (0, 0, 1.28), pid=3)                                # 檐板
    pyramid(0.62, 0.50, (0, 0, 1.56), pid=4)                                    # 红顶尖


@motif("house", "房屋")
def _m_house():
    # 定居点/建筑 UI：墙体+三棱柱屋顶+门窗+烟囱
    box((0.90, 0.80, 0.55), (0, 0, 0.28), pid=3)
    cyl(0.50, 0.95, (0, 0, 0.82), rot=(0, math.radians(90), math.radians(180)),
        verts=3, pid=4)                                                          # 屋顶（脊沿X）
    box((0.16, 0.05, 0.26), (0, -0.41, 0.23), pid=7)                            # 门
    box((0.14, 0.05, 0.14), (0.26, -0.41, 0.40), pid=9)                         # 窗
    box((0.12, 0.12, 0.24), (0.28, 0.10, 1.05), pid=2)                          # 烟囱


@motif("anchor", "锚")
def _m_anchor():
    # 海军/港口 UI：顶环+横杆+锚干+弧臂双爪（臂展加宽防瘦长）
    tor(0.10, 0.035, (0, 0, 1.30), pid=2)
    box((0.09, 0.07, 0.24), (0, 0, 1.14), pid=2)
    box((0.62, 0.07, 0.09), (0, 0, 1.00), pid=3)                                # 横杆
    cyl(0.055, 0.88, (0, 0, 0.58), pid=2)
    tube([(-0.42, 0, 0.20), (-0.34, 0, 0.36), (-0.12, 0, 0.40), (0, 0, 0.24),
          (0.12, 0, 0.40), (0.34, 0, 0.36), (0.42, 0, 0.20)], 0.055, pid=2, chaikin=2)
    sph(0.07, (-0.44, 0, 0.18), scale=(0.8, 0.8, 1.3), pid=2)                   # 爪尖
    sph(0.07, (0.44, 0, 0.18), scale=(0.8, 0.8, 1.3), pid=2)


# ── 可爱生活 ────────────────────────────────────────────────────────────────
@motif("heart_balloon", "心形气球")
def _m_heart_balloon():
    heart_mesh(scale=0.72, loc=(0, 0, 0.55), pid=4, extrude=0.24, bevel=0.075)
    box((0.11, 0.11, 0.10), (0, 0, -0.03), rot=(0, math.radians(45), 0), pid=4)
    tube([(0, 0, -0.06), (0.06, 0, -0.34), (-0.05, 0, -0.60), (0.04, 0, -0.82)], 0.024, pid=6, chaikin=2)


@motif("button_hand", "按按钮小手", az=24, el=14, key_e=6.0)
def _m_button_hand():
    # 极简两部件：圆拳+食指伸向按钮（拇指/蜷指凸出物都会读成鸟头/散架）
    box((0.95, 0.70, 0.16), (0, 0, 0.08), bev=0.04, pid=2)
    cyl(0.24, 0.12, (0, 0, 0.22), rot=(math.radians(90), 0, 0), pid=4)
    box((0.42, 0.38, 0.22), (0.06, 0.20, 0.52), rot=(math.radians(-14), 0, 0),
        bev=0.10, pid=6)                                                        # 拳
    cap(0.08, 0.28, (0.05, -0.10, 0.33), rot=(math.radians(-16), 0, 0), pid=6)  # 食指


@motif("foxtail", "狗尾巴草")
def _m_foxtail():
    # 单穗两段渐细沿秆向（旧两段错位读成两根肠）+叶角抬高
    tube([(0, 0, 0), (0.02, 0, 0.45), (0.06, 0, 0.85), (0.12, 0, 1.08)], 0.035, pid=5, chaikin=2)
    cap(0.075, 0.34, (0.20, 0, 1.22), rot=(0, math.radians(-24), 0), pid=3)
    cap(0.048, 0.20, (0.31, 0, 1.44), rot=(0, math.radians(-24), 0), pid=3)
    sph(0.20, (0.04, 0, 0.36), scale=(0.85, 0.08, 0.36), rot=(0, 0, math.radians(58)), pid=5)
    sph(0.17, (0.16, 0, 0.62), scale=(0.85, 0.08, 0.32), rot=(0, 0, math.radians(70)), pid=5)


@motif("bone", "狗骨头", fake=(0.10, 0.02, 0.18))
def _m_bone():
    cap(0.11, 0.62, (0, 0, 0.35), rot=(0, math.radians(90), math.radians(-10)), pid=6)
    for sx in (-1, 1):
        x = 0.44 * sx
        sph(0.14, (x, 0, 0.46), scale=(0.8, 1, 0.9), pid=6)
        sph(0.14, (x, 0, 0.24), scale=(0.8, 1, 0.9), pid=6)


@motif("teacup", "茶杯")
def _m_teacup():
    # 宽杯+茶汤+碟+热气（旧深筒+大把手读成罐子）
    cyl(0.30, 0.05, (0, 0, 0.05), pid=8)                                        # 碟
    cyl(0.34, 0.30, (0, 0, 0.25), pid=6)
    cyl(0.29, 0.04, (0, 0, 0.38), pid=9)                                        # 茶汤
    tor(0.16, 0.035, (0.40, 0, 0.28), rot=(0, math.radians(90), 0), pid=6)      # 把手
    tube([(0.0, 0, 0.52), (0.05, 0, 0.66), (0.0, 0, 0.78)], 0.024, pid=6, chaikin=2)
    tube([(-0.11, 0, 0.50), (-0.06, 0, 0.62), (-0.13, 0, 0.72)], 0.019, pid=6, chaikin=2)


@motif("dango", "团子串")
def _m_dango():
    cyl(0.045, 1.15, (0, 0, 0.52), rot=(0, math.radians(22), 0), pid=3)
    for i, (pid, z) in enumerate(((6, 0.30), (5, 0.62), (4, 0.94))):
        sph(0.21, (math.sin(math.radians(22)) * (z - 0.52), 0, z), segs=(48, 32), pid=pid)


@motif("riceball", "饭团", az=24, el=12, key_e=6.0)
def _m_riceball():
    # 圆角三角柱（旧白椭球读成鸡蛋）+ 底部海苔
    cyl(0.52, 0.34, (0, 0, 0.50), rot=(math.radians(90), 0, math.radians(90)),
        verts=3, bev=0.13, pid=6)
    box((0.36, 0.06, 0.26), (0, -0.155, 0.30), pid=7)                           # 海苔
    sph(0.03, (0.10, -0.16, 0.52), pid=6)                                       # 饭粒高光


@motif("medal", "奖章", az=14, el=8, key_e=7.0)
def _m_medal():
    # V 绶带压章后+星浮雕章面（旧素金球+绶带被遮死）
    box((0.20, 0.05, 0.44), (-0.15, 0, 0.86), rot=(0, 0, math.radians(16)), pid=4)
    box((0.20, 0.05, 0.44), (0.15, 0, 0.86), rot=(0, 0, math.radians(-16)), pid=4)
    cyl(0.34, 0.10, (0, 0, 0.52), rot=(math.radians(90), 0, 0), pid=8)
    tor(0.31, 0.032, (0, 0, 0.52), rot=(math.radians(90), 0, 0), pid=8)
    pts = []
    for k in range(10):
        a = math.radians(90 + k * 36)
        r = 0.16 if k % 2 == 0 else 0.07
        pts.append((math.cos(a) * r, -0.062, 0.52 + math.sin(a) * r))
    tube(pts, 0.024, pid=6, chaikin=1, closed=True)                             # 星浮雕


@motif("star_badge", "星章", az=14, el=8, key_e=7.0)
def _m_star_badge():
    pts = []
    for i in range(10):
        a = math.radians(90 + i * 36)
        r = 0.55 if i % 2 == 0 else 0.23
        pts.append((math.cos(a) * r, 0, 0.50 + math.sin(a) * r))
    tube(pts, 0.05, pid=8, chaikin=1, closed=True)
    sph(0.10, (0, 0, 0.50), pid=4)











