# -*- coding: utf-8 -*-
"""probe_mat4.py —— 三轮追加材质探针（玻璃系 / 魔法元素 / 城市地面系）

与 `probe_materials_v2.py`（出厂样片）与 `probe_mat3.py`（做旧层/逐体色变）的分工
--------------------------------------------------------------------------------
本探针只判**本轮追加的 18 个 key**，以及它们"贴到建筑/地面"之后的样子：

产物（`stick-world/temp/`）::
    pbr_mat4_sheet.png    新 18 key × 平面/球/立方体，同格并列 100% 与**物理 25%** 双缩略
                          （25% 缩略 = 1/4 世界尺寸 + UV×4 → 纹素密度真的只有 1/4，见 P2 说明）
    pbr_mat4_true25.png   **全库 54 key**（既有 36 + 新增 18）按物理 25% 分辨率整表渲一张
                          —— 这就是"25% 出厂门禁复跑"的客观底片
    pbr_mat4_glass.png    彩窗/铅条窗/清水玻璃/瓶玻璃/水晶/符文石刻/青铜/铜绿
                          贴在一面（自建的）建筑立面上做特写，判"玻璃会不会渲成死黑、
                          彩窗会不会糊成马赛克"
    pbr_mat4_ground.png   10 种城市地面各一块 **2×2 格**平铺对照（查色差与粗读层），
                          另加"相邻 2×2 块拼起来"的拼缝检查（cobble_small / stone_flag）

两个刻意的取舍
--------------
1. **玻璃必须上墙看**：透射（Transmission）在"背后没东西"时会被读成死黑，
   只有把窗子放进墙上、背后是天光时才能判断"这扇窗到底成立不成立"。
2. **同材质的一整面构件合成一个 Object**：本库的逐体色变（`OBJ_VAR`）是
   `Object Info > Random` —— 若把一面墙拆成 6 个盒子对象，六个盒子会各自偏色、
   在接缝处露出硬色阶（那是"探针自己造的假缝"，不是材质问题）。所以墙/窗套/包边
   一律用 `mesh_quads` 合成单个网格对象。

跑法::
    blender -b --factory-startup -P probe_mat4.py
    blender -b --factory-startup -P probe_mat4.py -- sheet        # 只出样片
"""
import bmesh
import math
import os
import sys

import bpy

HERE = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() \
    else r"F:/VSCode/game-2/.temp/building-pipeline-v2/tools/blender_buildings"
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import materials as M            # noqa: E402
import probe_materials_v2 as P2  # noqa: E402（复用天空/太阳/相机/换算/样片装配）

OUT_DIR = "F:/VSCode/game-2/.temp/building-pipeline-v2/stick-world/temp"

#: 本轮新增（顺序 = 样片排布顺序；玻璃/魔法一排，地面一排）
GLASS_KEYS = ['stained_glass', 'glass_lead', 'glass_clear', 'glass_bottle',
              'crystal', 'rune_glow', 'bronze', 'patina']
GROUND_KEYS = ['cobble_small', 'cobble_large', 'brick_paving', 'stone_flag',
               'dirt_packed', 'dirt_mud', 'gravel', 'grass_lawn', 'sand', 'wood_deck']
NEW_KEYS = GLASS_KEYS + GROUND_KEYS

#: 地面构图（px @1:1；1 格 = 32 px = 1 UV = 0.42 m）
G_TILE = 32.0                       # 1 格
G_PATCH = 2.0 * G_TILE              # 每块 2×2 格
G_COLS, G_COLX, G_ROWY = 5, 84.0, 150.0
G_SEAMY = 330.0                     # 拼接检查那一排的 y
G_TILT = 50.0                       # 看地面开到 50° 俯角（20° 会把地面压扁到看不清缝）


def u(px_):
    return P2.u(px_)


def clear_scene():
    """一张场景只 read_factory_settings 一次，随后必须清材质缓存（交接档 §六）。"""
    P2.clear()


# ------------------------------------------------------------------ 几何
def assign(ob, mat):
    ob.data.materials.clear()
    ob.data.materials.append(mat)
    return ob


def mat_of(name, **kw):
    """按装配层名字取材质（走 materials.get 的别名表），可选 tune 参数。"""
    m = M.get(name)
    if m is None:
        m = M.make(name)
    if kw:
        M.tune(m, **kw)
    return m


def box(name, w, h, d, x, y, z, mat, uv_scale=1.0):
    """单件盒子（尺寸 px@1:1，位置 = 盒心；-Y 为正前）。

    **轴映射纪律**：`w` → X（水平）、`h` → **Z（竖直）**、`d` → Y（进深）。
    写成 `scale=(u(w), u(h), u(d))` 会让高变成"进深"、盒子躺平（探针第一版就踩了：
    "竖着的窗玻璃"实际是一块 4 px 高、120 px 深的平板，从上往下看只看到顶面纹理）。
    """
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bm.to_mesh(me)
    bm.free()
    ob = P2.link(bpy.data.objects.new(name, me))
    ob.scale = (u(w), u(d), u(h))
    ob.location = (u(x), u(y), u(z))
    bpy.context.view_layer.update()
    assign(ob, mat)
    M.box_project_uv(ob, uv_scale=uv_scale)
    return ob


def quad(name, w, d, x, y, z, mat, uv_scale=1.0):
    """水平面（地面/台面）：法线 +Z。"""
    return mesh_quads(name, [[(x - w / 2.0, y - d / 2.0, z), (x + w / 2.0, y - d / 2.0, z),
                              (x + w / 2.0, y + d / 2.0, z), (x - w / 2.0, y + d / 2.0, z)]],
                      mat, uv_scale=uv_scale)


def mesh_quads(name, quads, mat, uv_scale=1.0):
    """把若干四边形合成**一个** Object（同材质构件必须同对象，理由见文件头注释）。"""
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    for q in quads:
        vs = [bm.verts.new((u(p[0]), u(p[1]), u(p[2]))) for p in q]
        try:
            bm.faces.new(vs)
        except ValueError:
            pass
    bm.to_mesh(me)
    bm.free()
    ob = P2.link(bpy.data.objects.new(name, me))
    bpy.context.view_layer.update()
    assign(ob, mat)
    M.box_project_uv(ob, uv_scale=uv_scale)
    return ob


def rects_front(x0, x1, z0, z1, holes):
    """带矩形洞的立面板：按洞的 x 边界切列、列内按 z 边界切块，返回矩形列表。"""
    xs = sorted(set([x0, x1] + [v for h in holes for v in (h[0], h[1])]))
    out = []
    for i in range(len(xs) - 1):
        cx0, cx1 = xs[i], xs[i + 1]
        if cx1 - cx0 < 1e-6:
            continue
        col = [h for h in holes if h[0] <= cx0 + 1e-6 and h[1] >= cx1 - 1e-6]
        zs = sorted(set([z0, z1] + [v for h in col for v in (h[2], h[3])])) if col else [z0, z1]
        for j in range(len(zs) - 1):
            cz0, cz1 = zs[j], zs[j + 1]
            if cz1 - cz0 < 1e-6:
                continue
            if any(h[2] <= cz0 + 1e-6 and h[3] >= cz1 - 1e-6 for h in col):
                continue
            out.append((cx0, cx1, cz0, cz1))
    return out


def ring_quads(x0, x1, z0, z1, t):
    """窗套/包边环（4 条，合成一个对象用）。"""
    return [(x0, x0 + t, z0 - t, z1 + t), (x1 - t, x1, z0 - t, z1 + t),
            (x0 + t, x1 - t, z1, z1 + t), (x0 + t, x1 - t, z0 - t, z0)]


def wall_mesh(name, x0, x1, z0, z1, holes, mat, thick=16.0, uv_scale=1.0):
    """墙 = 一块带洞的立面 + 洞的内侧四壁（全在一个网格对象里）。"""
    quads = []
    for (a, b, c, d) in rects_front(x0, x1, z0, z1, holes):
        quads.append([(a, 0.0, c), (b, 0.0, c), (b, 0.0, d), (a, 0.0, d)])
    for (hx0, hx1, hz0, hz1) in holes:
        quads.append([(hx0, 0.0, hz1), (hx1, 0.0, hz1), (hx1, thick, hz1), (hx0, thick, hz1)])
        quads.append([(hx0, 0.0, hz0), (hx1, 0.0, hz0), (hx1, thick, hz0), (hx0, thick, hz0)])
        quads.append([(hx0, 0.0, hz0), (hx0, 0.0, hz1), (hx0, thick, hz1), (hx0, thick, hz0)])
        quads.append([(hx1, 0.0, hz0), (hx1, 0.0, hz1), (hx1, thick, hz1), (hx1, thick, hz0)])
    return mesh_quads(name, quads, mat, uv_scale=uv_scale)


def shard(name, r, h, x, y, z, mat, seg=6, yaw=0.0, tilt_r=0.0, tip=0.34, taper=0.96):
    """晶体/瓶：**棱柱 + 锥尖**（`tip` = 尖占高的比例）。锥体（create_cone 单段）在
    渲染里读成"巫女帽"，所以晶体一律做成"柱身 + 收尖"两段（柱身 6 面 → 实时光照
    自然给出面与面的明暗转折，这就是"晶体"的读法来源）。瓶用 `tip=0.0`（直筒）。"""
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    h1, h2 = h * (1.0 - tip), h * tip

    def cone(r1, r2, dep, dz):
        before = set(bm.verts)
        try:
            bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=True, segments=seg,
                                  radius1=u(r1), radius2=u(r2), depth=u(dep))
        except TypeError:
            bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=True, segments=seg,
                                  diameter1=u(r1 * 2.0), diameter2=u(r2 * 2.0), depth=u(dep))
        for vv in bm.verts:
            if vv not in before:
                vv.co.z += u(dz)

    if tip > 0.0:
        cone(r, r * taper, h1, -h2 / 2.0)
        cone(r * taper, r * 0.05, h2, h1 / 2.0)
    else:
        cone(r, r * 0.92, h1, 0.0)
    bm.to_mesh(me)
    bm.free()
    ob = P2.link(bpy.data.objects.new(name, me))
    ob.rotation_euler = (0.0, tilt_r, yaw)
    ob.location = (u(x), u(y), u(z))
    bpy.context.view_layer.update()
    assign(ob, mat)
    M.box_project_uv(ob)
    return ob


# ------------------------------------------------------------------ 取景 / 标注
def place_cam(cam, anchor, tilt, dist=9000.0):
    t = math.radians(tilt)
    right = (1.0, 0.0, 0.0)
    up = (0.0, math.sin(t), math.cos(t))
    fwd = (-(right[1] * up[2] - right[2] * up[1]),
           -(right[2] * up[0] - right[0] * up[2]),
           -(right[0] * up[1] - right[1] * up[0]))
    cam.location = tuple(a - f * dist for a, f in zip(anchor, fwd))
    cam.rotation_euler = (math.radians(90.0 - tilt), 0.0, 0.0)


def frame(cam, w_px, h_px, zoom, anchor_px, tilt=20.0):
    """取景：w/h 为 px@1:1（= 世界跨度），anchor 为画面中心的 px@1:1 三元组。"""
    sc = bpy.context.scene
    sc.render.resolution_x = max(64, int(round(w_px * zoom)))
    sc.render.resolution_y = max(64, int(round(h_px * zoom)))
    cam.data.ortho_scale = u(w_px)
    place_cam(cam, tuple(u(v) for v in anchor_px), tilt)
    return sc.render.resolution_x, sc.render.resolution_y


def render_to(path):
    sc = bpy.context.scene
    os.makedirs(os.path.dirname(path), exist_ok=True)
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)
    print("RENDER -> %s  %dx%d" % (path, sc.render.resolution_x, sc.render.resolution_y))


def label(text, x, y, z, size=15.0, tilt=20.0):
    """自建标签（面朝相机：绕 X 转 90-tilt）。P2.label 写死了 20° 的模块常量，地面段用不了。"""
    bpy.ops.object.text_add(location=(u(x), u(y), u(z)),
                            rotation=(math.radians(90.0 - tilt), 0.0, 0.0))
    ob = bpy.context.object
    ob.name = "lbl_" + text[:16]
    ob.data.body = text
    ob.data.size = u(size)
    ob.data.align_x = 'CENTER'
    ob.data.align_y = 'CENTER'
    if "mat_label4" not in bpy.data.materials:
        m = bpy.data.materials.new("mat_label4")
        nt = m.node_tree
        nt.nodes.clear()
        o = nt.nodes.new('ShaderNodeOutputMaterial')
        e = nt.nodes.new('ShaderNodeEmission')
        e.inputs[0].default_value = (0.93, 0.95, 0.99, 1.0)
        e.inputs[1].default_value = 1.15
        nt.links.new(e.outputs[0], o.inputs['Surface'])
    assign(ob, bpy.data.materials["mat_label4"])
    return ob


def scene_base():
    """世界 + 两盏太阳 + 相机 + 渲染设置（与样片/做旧探针同光照）。"""
    P2.setup_world()
    P2.add_sun("key", 42.0, -38.0, 3.4, (1.00, 0.95, 0.86), 3.5)
    P2.add_sun("fill", 18.0, 125.0, 0.70, (0.72, 0.80, 0.95), 25.0)
    cam = P2.make_camera()
    P2.setup_render(cam, 100.0, 100.0, 1.0)     # 只取引擎/采样/色彩管理
    return cam


# ------------------------------------------------------------------ 段 1/2：样片 + 25% 门禁
def section_sheet():
    print("=== 段 1：新 %d key 样片（平面/球/立方体 + 100%% / 物理 25%% 双缩略）===" % len(NEW_KEYS))
    P2.build(NEW_KEYS, 1.0)
    render_to(os.path.join(OUT_DIR, "pbr_mat4_sheet.png"))


def section_true25():
    """全库 54 key 的物理 25%（1/4 世界尺寸 + UV×4 → 真的只有 1/4 像素密度）。"""
    print("=== 段 2：全库 %d key 物理 25%% 门禁（与 pbr_mat2_true25.png 同规）===" % len(M.ORDER))
    P2.build(None, 0.25)
    render_to(os.path.join(OUT_DIR, "pbr_mat4_true25.png"))


# ------------------------------------------------------------------ 段 3：玻璃上墙
STAIN = (-120.0, -56.0, 86.0, 206.0)     # 彩窗洞口 (x0,x1,z0,z1)
LEAD = (26.0, 90.0, 96.0, 196.0)         # 铅条窗
CLEAR = (-176.0, -136.0, 46.0, 86.0)     # 清水玻璃小窗


def section_glass():
    clear_scene()
    # ---- 立面：抹灰墙（带三个洞）+ 石基座 + 铜绿泛水 + 大地面
    quad("ground", 900.0, 780.0, 0.0, -260.0, -0.6, mat_of('cobble_large'))
    wall_mesh("wall", -200.0, 200.0, 0.0, 220.0, [STAIN, LEAD, CLEAR], mat_of('plaster'),
              thick=18.0)
    box("plinth", 400.0, 26.0, 24.0, 0.0, 2.0, 13.0, mat_of('stone'), uv_scale=0.6)
    box("coping_patina", 404.0, 10.0, 28.0, 0.0, 2.0, 224.0, mat_of('patina'))
    # ---- 彩窗：白石窗套（一个对象）+ 玻璃 + 窗台
    mesh_quads("stain_frame", [[(a, 0.0, c), (b, 0.0, c), (b, 0.0, d), (a, 0.0, d)]
                               for (a, b, c, d) in ring_quads(STAIN[0], STAIN[1],
                                                              STAIN[2], STAIN[3], 11.0)],
               mat_of('white_stone'), uv_scale=1.2)
    box("stain_glass", STAIN[1] - STAIN[0], STAIN[3] - STAIN[2], 4.0,
        (STAIN[0] + STAIN[1]) / 2.0, 6.0, (STAIN[2] + STAIN[3]) / 2.0,
        M.make('stained_glass', wear=0.45))
    box("stain_sill", STAIN[1] - STAIN[0] + 30.0, 9.0, 18.0,
        (STAIN[0] + STAIN[1]) / 2.0, 4.0, STAIN[2] - 15.0, mat_of('white_stone'))
    # ---- 铅条窗：青铜窗套（一个对象）+ 玻璃 + 白石窗台
    mesh_quads("lead_frame", [[(a, 0.0, c), (b, 0.0, c), (b, 0.0, d), (a, 0.0, d)]
                              for (a, b, c, d) in ring_quads(LEAD[0], LEAD[1],
                                                             LEAD[2], LEAD[3], 8.0)],
               M.make('bronze', wear=0.40))
    box("lead_glass", LEAD[1] - LEAD[0], LEAD[3] - LEAD[2], 4.0,
        (LEAD[0] + LEAD[1]) / 2.0, 6.0, (LEAD[2] + LEAD[3]) / 2.0,
        M.make('glass_lead', wear=0.45))
    box("lead_sill", LEAD[1] - LEAD[0] + 20.0, 9.0, 20.0,
        (LEAD[0] + LEAD[1]) / 2.0, 4.0, LEAD[2] - 11.0, mat_of('white_stone'))
    # ---- 清水玻璃小窗（背后是天空 → 判"会不会渲成死黑"）+ 铁窗棂
    box("clear_glass", CLEAR[1] - CLEAR[0], CLEAR[3] - CLEAR[2], 3.0,
        (CLEAR[0] + CLEAR[1]) / 2.0, 5.0, (CLEAR[2] + CLEAR[3]) / 2.0,
        M.make('glass_clear', wear=0.45))
    mesh_quads("clear_bars", [[(a, 0.0, c), (b, 0.0, c), (b, 0.0, d), (a, 0.0, d)]
                              for (a, b, c, d) in (
                                  (CLEAR[0] + 18.0, CLEAR[0] + 22.0, CLEAR[2], CLEAR[3]),
                                  (CLEAR[0], CLEAR[1], CLEAR[2] + 18.0, CLEAR[2] + 22.0))],
               mat_of('iron'))
    # ---- 符文石板（贴墙）+ 青铜包边（包边放在石板**正面之前**，否则被石板挡住）
    box("rune_slab", 62.0, 104.0, 8.0, 152.0, -6.0, 90.0, M.make('rune_glow', wear=0.35))
    mesh_quads("rune_band", [[(a, -10.6, c), (b, -10.6, c), (b, -10.6, d), (a, -10.6, d)]
                             for (a, b, c, d) in ring_quads(116.0, 188.0, 33.0, 147.0, 7.0)],
               M.make('bronze', wear=0.55))
    # ---- 水晶簇（石板台 + 5 根晶柱）
    quad("crystal_apron", 150.0, 130.0, -40.0, -46.0, 0.4, mat_of('stone_flag'))
    box("crystal_plinth", 96.0, 26.0, 60.0, -40.0, -46.0, 13.0, mat_of('stone'), uv_scale=0.8)
    for i, (dx, dy, r, h, tl) in enumerate(((-23.0, 2.0, 9.0, 56.0, 0.24),
                                            (6.0, -5.0, 11.0, 74.0, -0.14),
                                            (27.0, 6.0, 7.5, 44.0, 0.36),
                                            (-5.0, 13.0, 6.5, 34.0, -0.32),
                                            (15.0, 15.0, 5.5, 26.0, 0.12))):
        shard("crystal_%d" % i, r, h, -40.0 + dx, -46.0 + dy, 26.0 + h / 2.0 - 9.0,
              M.make('crystal'), yaw=i * 0.7, tilt_r=tl, taper=0.90)
    # ---- 瓶玻璃（两只立瓶 + 一只倒瓶；按现实尺寸 ~40/32 px 高 = 0.5/0.4 m）
    for i, (dx, dy, r, h, tl) in enumerate(((-10.0, 30.0, 8.0, 42.0, 0.0),
                                            (10.0, 26.0, 6.5, 32.0, 0.10))):
        shard("bottle_%d" % i, r, h, 150.0 + dx, -54.0 + dy, h / 2.0,
              M.make('glass_bottle'), seg=10, yaw=float(i), tilt_r=tl, tip=0.0)
    shard("bottle_2", 7.0, 34.0, 176.0, -20.0, 7.5, M.make('glass_bottle'),
          seg=10, yaw=1.0, tilt_r=1.45, tip=0.0)
    label("stained_glass", -88.0, -2.0, 62.0, size=17.0)
    label("glass_lead + bronze", 58.0, -2.0, 72.0, size=17.0)
    label("glass_clear + iron", -156.0, -2.0, 26.0, size=14.0)
    label("rune_glow + bronze", 152.0, -2.0, 22.0, size=14.0)
    label("crystal", -40.0, -108.0, 6.0, size=17.0)
    label("glass_bottle", 150.0, -98.0, 6.0, size=14.0)
    label("plaster / stone / patina", 0.0, -2.0, 232.0, size=14.0)

    cam = scene_base()
    frame(cam, 470.0, 330.0, 2.35, (0.0, -30.0, 116.0), tilt=20.0)
    render_to(os.path.join(OUT_DIR, "pbr_mat4_glass.png"))


# ------------------------------------------------------------------ 段 4：地面上样
def section_ground():
    clear_scene()
    for i, key in enumerate(GROUND_KEYS):
        cx = (i % G_COLS) * G_COLX - (G_COLS - 1) * G_COLX / 2.0
        cy = (i // G_COLS) * G_ROWY
        quad("g_" + key, G_PATCH, G_PATCH, cx, cy, 0.0, M.make(key, wear=0.45))
        label(key, cx, cy + G_PATCH / 2.0 + 20.0, 0.5, size=15.0, tilt=G_TILT)
    # ---- 拼接检查：同材质 3 块 2×2 **紧邻**（世界坐标 UV → 缝上应是同一函数取值，不该有色阶）
    for i in range(3):
        quad("seam_cobble_%d" % i, G_PATCH, G_PATCH,
             (i - 1.0) * G_PATCH - 128.0, G_SEAMY, 0.0, M.make('cobble_small', wear=0.45))
        quad("seam_flag_%d" % i, G_PATCH, G_PATCH,
             (i - 1.0) * G_PATCH + 128.0, G_SEAMY, 0.0, M.make('stone_flag', wear=0.45))
    label("cobble_small x3 紧邻拼接", -128.0, G_SEAMY + G_PATCH / 2.0 + 20.0, 0.5,
          size=15.0, tilt=G_TILT)
    label("stone_flag x3 紧邻拼接", 128.0, G_SEAMY + G_PATCH / 2.0 + 20.0, 0.5,
          size=15.0, tilt=G_TILT)

    cam = scene_base()
    # 俯角 50° → 屏幕竖直 = 进深 × sin(50°)；内容 up 坐标 ∈ [-25, 292] → 锚点 up = 132
    frame(cam, 470.0, 330.0, 2.6, (0.0, 172.0, 0.0), tilt=G_TILT)
    render_to(os.path.join(OUT_DIR, "pbr_mat4_ground.png"))


def main():
    argv = sys.argv
    flags = [a for a in argv[argv.index("--") + 1:]] if "--" in argv else []
    only = [a for a in flags if not a.startswith("-")]

    print("=== probe_mat4：三轮追加材质（%d 新 key / 全库 %d key）===" % (len(NEW_KEYS), len(M.ORDER)))
    if not only or "sheet" in only:
        section_sheet()
    if not only or "true25" in only:
        section_true25()
    if not only or "glass" in only:
        section_glass()
    if not only or "ground" in only:
        section_ground()

    print("\n=== 特征尺寸换算表（现实 / 游戏 1:1 / 25%%）—— 只列本轮新增 ===")
    rows = M.audit(verbose=False)
    for k, desc, n, feats in rows:
        if k in NEW_KEYS:
            print("%-13s %-24s nodes=%-4d %s" % (k, desc, n, feats))
    print("DONE")


if __name__ == "__main__":
    main()
