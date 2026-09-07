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


def heart_mesh(scale=1.0, loc=(0, 0, 0), pid=4, extrude=0.17, bevel=0.06, lift=0.15):
    """心形（连续曲线处处 C¹，鞍部可折角）——v9 验证过的轮廓，此处缩放复用"""
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


def _stick(pose):
    """火柴人（墨炭身体 + 米白大头）。pose: dict(armL, armR, legL, legR) 为绕 Y 角度
    （0=垂下，正=向 +X 抬）。返回手/脚世界坐标供道具对接。"""
    sph(0.30, (0, 0, 1.32), segs=(48, 32), pid=6)
    cap(0.10, 0.42, (0, 0, 0.80), pid=7)
    j = {}
    for side, key in ((-1, 'L'), (1, 'R')):
        ang = pose.get('arm' + key, 0.15 * side)
        sh = (0.17 * side, 0, 1.02)
        d = (math.sin(ang) * side, 0, -math.cos(ang))
        cap(0.075, 0.30, (sh[0] + d[0] * 0.22, sh[1], sh[2] + d[2] * 0.22), pid=7)
        j['hand' + key] = (sh[0] + d[0] * 0.48, sh[2] + d[2] * 0.48)
        ang = pose.get('leg' + key, 0.12 * side)
        hp = (0.09 * side, 0, 0.55)
        d = (math.sin(ang) * side, 0, -math.cos(ang))
        cap(0.07, 0.32, (hp[0] + d[0] * 0.23, hp[1], hp[2] + d[2] * 0.23), pid=7)
        j['foot' + key] = (hp[0] + d[0] * 0.50, hp[2] + d[2] * 0.50)
    return j


# ── 生产工具 ────────────────────────────────────────────────────────────────
@motif("pick", "十字镐")
def _m_pick():
    cyl(0.07, 1.15, (0, 0, 0), rot=(0, 0, math.radians(20)), pid=3)
    box((0.30, 0.14, 0.16), (0.20, 0, 0.52), rot=(0, 0, math.radians(20)), pid=2)
    box((0.34, 0.13, 0.14), (-0.42, 0, 0.28), rot=(0, math.radians(24), math.radians(20)), pid=2)
    box((0.30, 0.13, 0.12), (0.44, 0, 0.36), rot=(0, math.radians(-24), math.radians(20)), pid=2)


@motif("axe", "斧头")
def _m_axe():
    cyl(0.07, 1.25, (0, 0, 0), pid=3)
    box((0.20, 0.34, 0.42), (0.24, 0, 0.42), bev=0.07, pid=2)
    box((0.16, 0.20, 0.30), (0.44, 0, 0.42), rot=(0, math.radians(18), 0), pid=2)


@motif("saw", "木锯")
def _m_saw():
    box((1.15, 0.05, 0.30), (-0.15, 0, 0.15), rot=(0, 0, math.radians(-6)), pid=2)
    box((0.34, 0.09, 0.22), (0.56, 0, 0.26), rot=(0, 0, math.radians(-18)), bev=0.06, pid=3)


@motif("shovel", "铁锹")
def _m_shovel():
    cyl(0.07, 1.00, (0, 0, 0.38), pid=3)
    box((0.14, 0.14, 0.16), (0, 0, 0.98), bev=0.04, pid=3)
    sph(0.32, (0, 0, -0.36), scale=(1.0, 0.38, 1.15), pid=2)


@motif("handcart", "手推车")
def _m_handcart():
    box((0.95, 0.55, 0.34), (0.15, 0, 0.42), bev=0.07, pid=3)
    for x in (-0.10, 0.40):
        tor(0.18, 0.06, (x, -0.30, 0.18), rot=(math.radians(90), 0, 0), pid=7)
        tor(0.18, 0.06, (x, 0.30, 0.18), rot=(math.radians(90), 0, 0), pid=7)
    tube([(-0.32, 0, 0.55), (-0.75, 0, 0.72), (-1.05, 0, 0.70)], 0.05, pid=3)


# ── 物流运输 ────────────────────────────────────────────────────────────────
@motif("boat", "小木船")
def _m_boat():
    box((1.35, 0.55, 0.30), (0, 0, 0.18), bev=0.11, pid=3)
    box((0.22, 0.42, 0.34), (-0.62, 0, 0.38), bev=0.06, pid=3)
    box((0.22, 0.42, 0.34), (0.62, 0, 0.38), bev=0.06, pid=3)
    cyl(0.045, 1.05, (0.05, 0, 0.52), rot=(0, math.radians(28), math.radians(90)), pid=3)
    box((0.30, 0.10, 0.16), (-0.42, 0, 0.64), rot=(0, math.radians(28), 0), pid=3)


@motif("wagon", "货运板车")
def _m_wagon():
    box((1.15, 0.62, 0.30), (0, 0, 0.52), bev=0.06, pid=3)
    for x in (-0.38, 0.38):
        tor(0.22, 0.07, (x, -0.34, 0.22), rot=(0, math.radians(90), 0), pid=7)
        tor(0.22, 0.07, (x, 0.34, 0.22), rot=(0, math.radians(90), 0), pid=7)
    tube([(0.55, 0, 0.45), (0.95, 0, 0.30), (1.15, 0, 0.10)], 0.05, pid=3)
    box((0.55, 0.50, 0.28), (-0.10, 0, 0.82), bev=0.05, pid=8)


@motif("sack", "麻袋")
def _m_sack():
    sph(0.45, (0, 0, 0.42), scale=(1.0, 0.85, 1.05), pid=6)
    cyl(0.15, 0.20, (0, 0, 0.98), pid=6)
    tor(0.16, 0.045, (0, 0, 1.02), rot=(math.radians(90), 0, 0), pid=5)
    sph(0.13, (-0.14, 0, 1.12), scale=(1, 0.7, 0.8), pid=6)
    sph(0.13, (0.14, 0, 1.12), scale=(1, 0.7, 0.8), pid=6)


@motif("barrel", "木桶")
def _m_barrel():
    cyl(0.42, 0.85, (0, 0, 0.45), pid=3)
    tor(0.43, 0.045, (0, 0, 0.72), rot=(math.radians(90), 0, 0), pid=2)
    tor(0.43, 0.045, (0, 0, 0.18), rot=(math.radians(90), 0, 0), pid=2)
    tor(0.30, 0.035, (0, 0, 0.88), rot=(math.radians(90), 0, 0), pid=3)


@motif("crate", "板条箱")
def _m_crate():
    box((0.85, 0.85, 0.75), (0, 0, 0.42), bev=0.05, pid=3)
    box((1.02, 0.05, 0.16), (0, -0.44, 0.42), rot=(0, math.radians(38), 0), pid=8)
    box((1.02, 0.05, 0.16), (0, 0.44, 0.42), rot=(0, math.radians(-38), 0), pid=8)
    box((0.90, 0.90, 0.10), (0, 0, 0.84), pid=3)


@motif("lantern", "提灯")
def _m_lantern():
    box((0.55, 0.55, 0.10), (0, 0, 0.10), bev=0.03, pid=2)
    box((0.40, 0.40, 0.50), (0, 0, 0.42), pid=8)
    box((0.55, 0.55, 0.10), (0, 0, 0.74), bev=0.03, pid=2)
    box((0.16, 0.16, 0.18), (0, 0, 0.88), bev=0.03, pid=2)
    tor(0.12, 0.035, (0, 0, 1.04), rot=(math.radians(90), 0, 0), pid=2)


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
    cap(0.30, 0.55, (0, 0, 0.34), rot=(0, math.radians(90), 0), pid=8)
    sph(0.20, (-0.28, 0, 0.30), scale=(0.8, 0.85, 0.75), pid=8)
    sph(0.20, (0.28, 0, 0.30), scale=(0.8, 0.85, 0.75), pid=8)
    box((0.10, 0.52, 0.06), (0, 0, 0.60), rot=(math.radians(10), 0, 0), pid=3)


@motif("gold_coin", "金币")
def _m_gold_coin():
    cyl(0.48, 0.13, (0, 0, 0.10), rot=(math.radians(90), 0, 0), pid=8)
    cyl(0.33, 0.16, (0, 0, 0.10), rot=(math.radians(90), 0, 0), pid=8)
    box((0.17, 0.17, 0.18), (0, 0, 0.10), pid=7)


@motif("ore", "矿石")
def _m_ore():
    sph(0.48, (0, 0, 0.32), scale=(1.2, 0.95, 0.85), rot=(0, 0, math.radians(15)), pid=2)
    # 晶体=4 棱平锥（帐篷同款刻意棱面许可）：椭球无尖角，64px 读不出晶尖
    pyramid(0.17, 0.62, (0.16, 0.05, 0.78), pid=9)
    pyramid(0.14, 0.46, (-0.26, 0, 0.66), pid=9)
    pyramid(0.12, 0.38, (-0.02, 0.06, 0.72), pid=9)
    sph(0.18, (0.46, 0, 0.22), pid=2)


@motif("fish", "小鱼干")
def _m_fish():
    sph(0.30, (0.10, 0, 0.35), scale=(1.5, 0.7, 0.8), rot=(0, 0, math.radians(-8)), pid=8)
    sph(0.14, (-0.42, 0, 0.38), scale=(0.9, 0.25, 1.1), rot=(0, math.radians(30), math.radians(15)), pid=8)
    sph(0.12, (-0.38, 0, 0.20), scale=(0.9, 0.25, 1.0), rot=(0, math.radians(-25), math.radians(-8)), pid=8)
    sph(0.045, (0.48, -0.14, 0.42), pid=7)


# ── 组织权力 ────────────────────────────────────────────────────────────────
@motif("seal", "印章", az=14, el=8, key_e=7.0)
def _m_seal():
    box((0.55, 0.55, 0.42), (0, 0, 0.36), bev=0.08, pid=8)
    sph(0.22, (0, 0, 0.72), scale=(1, 1, 0.8), pid=8)
    box((0.50, 0.50, 0.07), (0, 0, 0.10), pid=4)


@motif("flag", "旗帜", az=24, el=14, key_e=6.0)
def _m_flag():
    cyl(0.045, 1.65, (0, 0, 0.82), pid=3)
    sph(0.07, (0, 0, 1.68), pid=8)
    box((0.72, 0.05, 0.28), (0.42, 0, 1.38), rot=(0, 0, math.radians(3)), pid=4)
    box((0.60, 0.05, 0.26), (0.44, 0, 1.10), rot=(0, 0, math.radians(-4)), pid=4)


@motif("scroll", "卷轴", az=24, el=12, key_e=6.0)
def _m_scroll():
    cyl(0.07, 1.05, (0, 0, 1.05), rot=(0, math.radians(90), 0), pid=8)
    cyl(0.16, 0.98, (0, 0, 1.05), rot=(0, math.radians(90), 0), pid=6)
    box((0.78, 0.05, 0.78), (0, 0, 0.42), bev=0.03, pid=6)
    cyl(0.09, 0.05, (0.18, -0.05, 0.55), rot=(math.radians(90), 0, 0), pid=4)


@motif("chair", "高背椅")
def _m_chair():
    box((0.72, 0.62, 0.12), (0, 0, 0.52), bev=0.04, pid=3)
    box((0.72, 0.10, 0.95), (0, 0.26, 1.05), bev=0.04, pid=3)
    for x in (-0.28, 0.28):
        for y in (-0.24, 0.24):
            cyl(0.055, 0.50, (x, y, 0.26), pid=3)
    sph(0.07, (-0.24, 0.26, 1.56), pid=8)
    sph(0.07, (0.24, 0.26, 1.56), pid=8)


@motif("whistle", "哨子")
def _m_whistle():
    cyl(0.17, 0.55, (0.10, 0, 0.40), rot=(0, math.radians(90), 0), pid=8)
    box((0.22, 0.16, 0.14), (-0.30, 0, 0.40), bev=0.04, pid=8)
    tor(0.11, 0.035, (0.48, 0, 0.40), rot=(0, math.radians(90), 0), pid=8)
    box((0.10, 0.14, 0.34), (0.05, 0, 0.62), rot=(0, math.radians(8), 0), pid=8)


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


@motif("bell", "铃铛")
def _m_bell():
    sph(0.42, (0, 0, 0.52), scale=(1, 1, 0.9), pid=8)
    tor(0.40, 0.06, (0, 0, 0.16), rot=(math.radians(90), 0, 0), pid=8)
    sph(0.09, (0, 0, 0.04), pid=2)
    tor(0.10, 0.035, (0, 0, 0.98), rot=(math.radians(90), 0, 0), pid=8)


# ── 科技知识 ────────────────────────────────────────────────────────────────
@motif("flask", "药瓶")
def _m_flask():
    # 整瓶药水色（瓶+颈一体绿）——瓶内液体被不透明瓶壁挡住（64px 读不到），合并才可读
    sph(0.48, (0, 0, 0.38), scale=(1, 1, 0.95), pid=5)
    cyl(0.14, 0.45, (0, 0, 0.98), pid=5)
    cyl(0.10, 0.12, (0, 0, 1.26), pid=3)
    sph(0.06, (0.10, 0.05, 0.62), pid=6)
    sph(0.045, (-0.09, 0.04, 0.46), pid=6)


@motif("gear", "齿轮")
def _m_gear():
    cyl(0.52, 0.22, (0, 0, 0.45), rot=(math.radians(90), 0, 0), pid=2)
    for i in range(8):
        a = math.radians(i * 45)
        box((0.20, 0.18, 0.16), (math.cos(a) * 0.60, 0, 0.45 + math.sin(a) * 0.60),
            rot=(0, -a, 0), pid=2)
    cyl(0.16, 0.26, (0, 0, 0.45), rot=(math.radians(90), 0, 0), pid=8)


@motif("book_open", "摊开的书", az=20, el=10, key_e=6.0)
def _m_book_open():
    # 浅 V 页面朝相机（绕 Y 斜置）；白页在前（-y 朝相机）、红封面垫后
    box((0.66, 0.06, 0.50), (-0.30, 0.03, 0.48), rot=(0, math.radians(-17), 0), pid=4)
    box((0.66, 0.06, 0.50), (0.30, 0.03, 0.48), rot=(0, math.radians(17), 0), pid=4)
    box((0.60, 0.05, 0.44), (-0.29, -0.04, 0.52), rot=(0, math.radians(-17), 0), pid=6)
    box((0.60, 0.05, 0.44), (0.29, -0.04, 0.52), rot=(0, math.radians(17), 0), pid=6)
    box((0.92, 0.30, 0.09), (0, 0, 0.14), bev=0.03, pid=4)


@motif("magnifier", "放大镜")
def _m_magnifier():
    tor(0.42, 0.085, (0, 0, 0.75), rot=(math.radians(90), 0, 0), pid=2)
    cyl(0.34, 0.05, (0, 0, 0.75), rot=(math.radians(90), 0, 0), pid=6)
    cyl(0.065, 0.62, (0.38, 0, 0.22), rot=(0, math.radians(38), 0), pid=3, bev=0.02)


@motif("mortar", "研钵")
def _m_mortar():
    sph(0.48, (0, 0, 0.30), scale=(1, 1, 0.62), pid=6)
    tor(0.34, 0.07, (0, 0, 0.52), rot=(math.radians(90), 0, 0), pid=6)
    cap(0.09, 0.42, (0.22, 0, 0.72), rot=(0, math.radians(-32), math.radians(20)), pid=3)


@motif("abacus", "算盘", az=24, el=16)
def _m_abacus():
    box((1.05, 0.10, 0.14), (0, 0, 1.02), pid=3)
    box((1.05, 0.10, 0.14), (0, 0, 0.12), pid=3)
    box((0.10, 0.10, 1.02), (-0.48, 0, 0.57), pid=3)
    box((0.10, 0.10, 1.02), (0.48, 0, 0.57), pid=3)
    for i, x in enumerate((-0.24, 0, 0.24)):
        cyl(0.03, 0.86, (x, 0, 0.57), rot=(math.radians(90), 0, 0), pid=2)
        for j in range(4):
            sph(0.085, (x, -0.24 + j * 0.16, 0.57), segs=(32, 20), pid=(8, 4, 6)[i])


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
    cyl(0.08, 1.55, (0, 0, 0.35), pid=3)
    sph(0.15, (0, 0, 1.28), scale=(0.7, 0.7, 1.8), pid=2)
    tor(0.13, 0.055, (0, 0, 1.06), rot=(math.radians(90), 0, 0), pid=4)


@motif("shield", "圆盾", az=20, el=10)
def _m_shield():
    cyl(0.55, 0.13, (0, 0, 0.50), rot=(math.radians(90), 0, 0), pid=4)
    tor(0.55, 0.07, (0, 0, 0.50), rot=(math.radians(90), 0, 0), pid=8)
    sph(0.15, (0, -0.08, 0.50), pid=8)


@motif("bow", "弓箭")
def _m_bow():
    pts = []
    for i in range(13):
        a = math.radians(-62 + i * (124 / 12))
        pts.append((math.cos(a) * 0.72, 0, 0.55 + math.sin(a) * 0.72))
    tube(pts, 0.095, pid=3, chaikin=2)
    cyl(0.022, 1.26, (-0.20, 0, 0.55), pid=6)
    cyl(0.05, 1.02, (-0.12, 0, 0.55), rot=(0, math.radians(90), 0), pid=2)
    sph(0.08, (-0.66, 0, 0.55), scale=(0.6, 0.6, 1.6), pid=2)
    box((0.13, 0.20, 0.06), (0.32, 0, 0.55), rot=(0, 0, math.radians(20)), pid=4)


@motif("drum", "战鼓")
def _m_drum():
    cyl(0.52, 0.62, (0, 0, 0.42), pid=4)
    cyl(0.47, 0.06, (0, 0, 0.76), pid=6)
    tor(0.52, 0.055, (0, 0, 0.74), rot=(math.radians(90), 0, 0), pid=8)
    tor(0.52, 0.055, (0, 0, 0.10), rot=(math.radians(90), 0, 0), pid=8)
    cap(0.045, 0.55, (0.55, 0, 0.85), rot=(0, math.radians(35), math.radians(25)), pid=3)


@motif("helmet", "头盔")
def _m_helmet():
    sph(0.50, (0, 0, 0.32), scale=(1, 1, 0.72), pid=2)
    tor(0.50, 0.075, (0, 0, 0.14), rot=(math.radians(90), 0, 0), pid=8)
    sph(0.42, (0, 0, 0.68), scale=(0.16, 0.5, 0.8), pid=4)


@motif("sling", "弹弓")
def _m_sling():
    cyl(0.08, 0.55, (0, 0, 0.28), pid=3)
    tube([(0, 0, 0.52), (-0.17, 0, 0.85), (-0.23, 0, 1.12)], 0.07, pid=3, chaikin=2)
    tube([(0, 0, 0.52), (0.17, 0, 0.85), (0.23, 0, 1.12)], 0.07, pid=3, chaikin=2)
    tube([(-0.23, 0, 1.10), (0, 0, 0.98), (0.23, 0, 1.10)], 0.04, pid=4, chaikin=2)
    sph(0.12, (0, 0, 0.99), pid=7)


@motif("cannon", "小炮")
def _m_cannon():
    cyl(0.19, 0.95, (-0.05, 0, 0.62), rot=(0, math.radians(90), math.radians(-6)), pid=2)
    tor(0.21, 0.05, (-0.55, 0, 0.60), rot=(0, math.radians(90), 0), pid=8)
    for x in (-0.28, 0.28):
        tor(0.22, 0.07, (x, -0.26, 0.22), rot=(0, math.radians(90), 0), pid=3)
        tor(0.22, 0.07, (x, 0.26, 0.22), rot=(0, math.radians(90), 0), pid=3)
    box((0.55, 0.42, 0.14), (0, 0, 0.44), pid=3)
    sph(0.15, (0.52, 0, 0.66), pid=7)


# ── 扩张探索 ────────────────────────────────────────────────────────────────
@motif("maproll", "卷地图", az=20, el=10, key_e=6.0)
def _m_maproll():
    cyl(0.13, 1.00, (0, 0, 1.00), rot=(0, math.radians(90), 0), pid=6)
    box((0.86, 0.05, 0.80), (0.05, 0, 0.45), bev=0.03, pid=6)
    cyl(0.08, 0.04, (0.16, -0.05, 0.52), rot=(math.radians(90), 0, 0), pid=4)


@motif("compass_nav", "罗盘", az=14, el=8, key_e=7.0)
def _m_compass_nav():
    cyl(0.50, 0.15, (0, 0, 0.12), rot=(math.radians(90), 0, 0), pid=8)
    tor(0.50, 0.05, (0, 0, 0.12), rot=(math.radians(90), 0, 0), pid=2)
    sph(0.30, (0, -0.02, 0.26), scale=(0.28, 0.16, 1.05), pid=4)
    sph(0.30, (0, 0.02, 0.26), scale=(0.28, 0.16, 1.05), rot=(0, 0, math.radians(180)), pid=6)
    sph(0.08, (0, 0, 0.28), pid=2)


@motif("horseshoe", "马蹄铁")
def _m_horseshoe():
    pts = []
    for i in range(21):
        a = math.radians(120 + i * (300 / 20))
        pts.append((math.cos(a) * 0.52, 0, 0.50 + math.sin(a) * 0.52))
    tube(pts, 0.10, pid=2, chaikin=2, closed=True)


@motif("tent", "帐篷")
def _m_tent():
    pyramid(0.95, 1.05, (0, 0, 0.55), pid=6)
    box((0.30, 0.05, 0.45), (0, -0.42, 0.24), rot=(math.radians(-16), 0, 0), pid=8)
    sph(0.07, (0, 0, 1.12), pid=3)


@motif("campfire", "篝火")
def _m_campfire():
    for i, a in enumerate((0, 60, 120)):
        cyl(0.075, 0.85, (0, 0, 0.10), rot=(math.radians(90), 0, math.radians(a)), pid=3)
    sph(0.26, (0, 0, 0.48), scale=(0.85, 0.85, 1.35), pid=4)
    sph(0.16, (0, 0, 0.42), scale=(0.85, 0.85, 1.30), pid=8)


@motif("watchtower", "瞭望塔")
def _m_watchtower():
    box((0.95, 0.80, 0.95), (0, 0, 0.48), bev=0.05, pid=3)
    box((1.25, 1.05, 0.14), (0, 0, 1.02), pid=3)
    pyramid(0.85, 0.65, (0, 0, 1.42), pid=4)
    box((0.16, 0.16, 0.14), (0, -0.42, 0.70), pid=7)


# ── 可爱生活 ────────────────────────────────────────────────────────────────
@motif("heart_balloon", "心形气球")
def _m_heart_balloon():
    heart_mesh(scale=0.72, loc=(0, 0, 0.55), pid=4, extrude=0.16, bevel=0.055)
    box((0.11, 0.11, 0.10), (0, 0, -0.03), rot=(0, math.radians(45), 0), pid=4)
    tube([(0, 0, -0.06), (0.06, 0, -0.34), (-0.05, 0, -0.60), (0.04, 0, -0.82)], 0.024, pid=6, chaikin=2)


@motif("button_hand", "按按钮小手", az=24, el=14, key_e=6.0)
def _m_button_hand():
    box((0.95, 0.70, 0.16), (0, 0, 0.08), bev=0.04, pid=2)
    cyl(0.28, 0.13, (0, 0, 0.22), rot=(math.radians(90), 0, 0), pid=4)
    sph(0.30, (0.30, 0, 0.62), scale=(1, 0.8, 0.85), rot=(0, math.radians(-14), 0), pid=6)
    cap(0.085, 0.34, (0.02, 0, 0.44), rot=(0, math.radians(8), 0), pid=6)
    cap(0.075, 0.22, (0.52, 0, 0.44), rot=(0, math.radians(55), math.radians(15)), pid=6)


@motif("foxtail", "狗尾巴草")
def _m_foxtail():
    tube([(0, 0, 0), (0.04, 0, 0.45), (0.16, 0, 0.88), (0.40, 0, 1.18)], 0.042, pid=5, chaikin=2)
    cap(0.15, 0.52, (0.52, 0, 1.38), rot=(0, math.radians(-58), 0), pid=6)
    sph(0.24, (0.02, 0, 0.42), scale=(0.9, 0.10, 0.30), rot=(0, 0, math.radians(35)), pid=5)
    sph(0.20, (0.14, 0, 0.68), scale=(0.9, 0.10, 0.28), rot=(0, 0, math.radians(50)), pid=5)


@motif("bone", "狗骨头", fake=(0.10, 0.02, 0.18))
def _m_bone():
    cap(0.11, 0.62, (0, 0, 0.35), rot=(0, math.radians(90), math.radians(-10)), pid=6)
    for sx in (-1, 1):
        x = 0.44 * sx
        sph(0.14, (x, 0, 0.46), scale=(0.8, 1, 0.9), pid=6)
        sph(0.14, (x, 0, 0.24), scale=(0.8, 1, 0.9), pid=6)


@motif("teacup", "茶杯")
def _m_teacup():
    cyl(0.40, 0.42, (0, 0, 0.28), pid=6)
    tor(0.40, 0.055, (0, 0, 0.49), rot=(math.radians(90), 0, 0), pid=6)
    cyl(0.33, 0.05, (0, 0, 0.44), pid=8)
    tor(0.15, 0.05, (0.44, 0, 0.30), rot=(0, math.radians(90), 0), pid=6)


@motif("dango", "团子串")
def _m_dango():
    cyl(0.045, 1.15, (0, 0, 0.52), rot=(0, math.radians(22), 0), pid=3)
    for i, (pid, z) in enumerate(((6, 0.30), (5, 0.62), (4, 0.94))):
        sph(0.21, (math.sin(math.radians(22)) * (z - 0.52), 0, z), segs=(48, 32), pid=pid)


@motif("riceball", "饭团", az=24, el=12, key_e=6.0)
def _m_riceball():
    sph(0.52, (0, 0, 0.45), scale=(1.15, 0.9, 0.85), pid=6)
    box((0.44, 0.07, 0.42), (0, -0.36, 0.20), rot=(math.radians(-58), 0, 0), pid=7)


@motif("medal", "奖章", az=14, el=8, key_e=7.0)
def _m_medal():
    cyl(0.44, 0.10, (0, 0, 0.28), rot=(math.radians(90), 0, 0), pid=8)
    cyl(0.27, 0.13, (0, 0, 0.28), rot=(math.radians(90), 0, 0), pid=8)
    box((0.26, 0.05, 0.55), (-0.16, 0, 0.82), rot=(0, 0, math.radians(-14)), pid=4)
    box((0.26, 0.05, 0.55), (0.16, 0, 0.82), rot=(0, 0, math.radians(14)), pid=4)


@motif("star_badge", "星章", az=14, el=8, key_e=7.0)
def _m_star_badge():
    pts = []
    for i in range(10):
        a = math.radians(90 + i * 36)
        r = 0.55 if i % 2 == 0 else 0.23
        pts.append((math.cos(a) * r, 0, 0.50 + math.sin(a) * r))
    tube(pts, 0.05, pid=8, chaikin=1, closed=True)
    sph(0.10, (0, 0, 0.50), pid=4)


# ── 火柴人姿态 ──────────────────────────────────────────────────────────────
@motif("stick_cart", "推车小人")
def _m_stick_cart():
    j = _stick({'armL': 1.05, 'armR': 1.15, 'legL': -0.45, 'legR': 0.35})
    box((0.62, 0.42, 0.26), (j['handR'][0] + 0.28, 0, 0.40), bev=0.05, pid=3)
    tor(0.13, 0.05, (j['handR'][0] + 0.10, 0, 0.15), rot=(0, math.radians(90), 0), pid=7)
    tor(0.13, 0.05, (j['handR'][0] + 0.50, 0, 0.15), rot=(0, math.radians(90), 0), pid=7)
    tube([(j['handR'][0] - 0.02, 0, j['handR'][1]), (j['handR'][0] + 0.12, 0, 0.48)],
         0.04, pid=3, chaikin=1)


@motif("stick_hammer", "敲锤小人")
def _m_stick_hammer():
    j = _stick({'armR': 2.45, 'armL': -0.5, 'legL': -0.2, 'legR': 0.25})
    hx, hz = j['handR']
    cyl(0.045, 0.52, (hx + 0.05, 0, hz + 0.10), rot=(0, 0, math.radians(30)), pid=3)
    box((0.34, 0.16, 0.15), (hx + 0.16, 0, hz + 0.24), bev=0.04, pid=2)


@motif("stick_flag", "举旗小人")
def _m_stick_flag():
    j = _stick({'armR': 2.9, 'armL': 0.3, 'legL': -0.18, 'legR': 0.18})
    hx, hz = j['handR']
    cyl(0.035, 1.0, (hx + 0.02, 0, hz + 0.25), pid=3)
    box((0.52, 0.04, 0.24), (hx + 0.28, 0, hz + 0.55), pid=4)


@motif("stick_salute", "敬礼小人")
def _m_stick_salute():
    _stick({'armR': 2.75, 'armL': -0.15, 'legL': -0.1, 'legR': 0.1})


@motif("stick_run", "传令小人")
def _m_stick_run():
    j = _stick({'armL': -0.95, 'armR': 1.05, 'legL': -0.75, 'legR': 0.65})
    hx, hz = j['handL']
    cyl(0.07, 0.26, (hx - 0.04, 0, hz), rot=(0, math.radians(90), 0), pid=6)


@motif("stick_carry", "扛袋小人")
def _m_stick_carry():
    j = _stick({'armR': 2.35, 'armL': 0.4, 'legL': -0.25, 'legR': 0.3})
    hx, hz = j['handR']
    sph(0.26, (hx + 0.14, 0, hz + 0.28), scale=(0.9, 0.8, 1.05), pid=6)
    cyl(0.09, 0.14, (hx + 0.14, 0, hz + 0.56), pid=6)
    tor(0.10, 0.03, (hx + 0.14, 0, hz + 0.58), rot=(math.radians(90), 0, 0), pid=5)


@motif("stick_sword", "挥剑小人")
def _m_stick_sword():
    j = _stick({'armR': 1.65, 'armL': -0.55, 'legL': -0.4, 'legR': 0.3})
    hx, hz = j['handR']
    d = (math.sin(1.65), -math.cos(1.65))
    box((0.13, 0.05, 0.78), (hx + d[0] * 0.50, 0, hz + d[1] * 0.50),
        rot=(0, 0, math.radians(90 - 1.65 * 57.3)), pid=2)
    box((0.26, 0.07, 0.06), (hx + d[0] * 0.12, 0, hz + d[1] * 0.12), pid=8)


@motif("stick_water", "浇水小人")
def _m_stick_water():
    j = _stick({'armL': 1.15, 'armR': 1.30, 'legL': -0.15, 'legR': 0.15})
    hx, hz = j['handR']
    box((0.30, 0.24, 0.24), (hx + 0.16, 0, hz - 0.06), bev=0.04, pid=8)
    tube([(hx + 0.28, 0, hz + 0.02), (hx + 0.44, 0, hz + 0.10), (hx + 0.52, 0, hz - 0.04)],
         0.035, pid=8, chaikin=2)
    sph(0.035, (hx + 0.60, 0, hz - 0.14), pid=9)
    sph(0.03, (hx + 0.63, 0, hz - 0.24), pid=9)


@motif("stick_read", "读书小人")
def _m_stick_read():
    j = _stick({'armL': 1.25, 'armR': 1.35, 'legL': -0.12, 'legR': 0.12})
    hx, hz = j['handR']
    box((0.16, 0.06, 0.40), (hx + 0.02, 0, hz + 0.02), pid=4)
    box((0.30, 0.24, 0.045), (hx - 0.16, 0, hz + 0.14), rot=(math.radians(-70), 0, math.radians(12)), pid=6)
    box((0.30, 0.24, 0.045), (hx + 0.16, 0, hz + 0.18), rot=(math.radians(-70), 0, math.radians(-12)), pid=6)


@motif("stick_sleep", "睡觉小人")
def _m_stick_sleep():
    sph(0.27, (-0.62, 0, 0.30), segs=(48, 32), pid=6)
    sph(0.17, (-0.62, 0, 0.10), scale=(1, 0.7, 0.5), pid=6)
    cap(0.10, 0.46, (0.02, 0, 0.28), rot=(0, math.radians(90), 0), pid=7)
    cap(0.07, 0.30, (0.42, 0, 0.28), rot=(0, math.radians(90), math.radians(8)), pid=7)
    cap(0.07, 0.30, (0.44, 0, 0.24), rot=(0, math.radians(90), math.radians(-6)), pid=7)
    box((0.55, 0.45, 0.09), (0.05, 0, 0.44), rot=(0, math.radians(4), 0), pid=4)
