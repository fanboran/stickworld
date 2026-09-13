# -*- coding: utf-8 -*-
"""probe_mat5.py —— 四轮材质探针（玻璃语义修正 + 自然物 key）

本探针只判**本轮新增/修改的 key**，以及它们贴到真实场景后的样子：

产物（`stick-world/temp/`）::
    pbr_mat5_sheet.png    新 7 key + 本轮改过的 4 个玻璃 key：平面/球/立方体，
                          同格并列 100% 与**物理 25%** 双缩略（复用 P2.build）
    pbr_mat5_true25.png   新 7 key 整表按物理 25% 分辨率渲一张（出厂门禁底片）
    pbr_mat5_glass.png    **透明窗玻璃透视实证**：墙上开窗 → 窗后放可辨认彩对象
                          （红布/蓝桶/黄筐）+ 室内暖光；旁边两只灯笼并置对比
                          `glass_lead`（本轮修黑）与 `glass_clear`
    pbr_mat5_nature.png   更新后的树/矿/岩石特写条（nature.py 真场景，同尺度火柴人）
    pbr_mat5_regress.png  回归底片：不改动的既有 key 整表（与改动前逐像素比对用）

跑法::
    blender -b --factory-startup -P probe_mat5.py
    blender -b --factory-startup -P probe_mat5.py -- regress      # 只出回归底片
"""
import math
import os
import sys

import bpy
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() \
    else r"F:/VSCode/game-2/.temp/building-pipeline-v2/tools/blender_buildings"
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import materials as M            # noqa: E402
import buildings as B            # noqa: E402
import nature as N               # noqa: E402   （import 时注入自然物材质解析器）
import probe_materials_v2 as P2  # noqa: E402
import probe_mat4 as P4          # noqa: E402（复用几何/取景/标注助手）

OUT_DIR = "F:/VSCode/game-2/.temp/building-pipeline-v2/stick-world/temp"

#: 本轮新增 key（顺序 = 样片排布顺序）
NEW_KEYS = ['glazing_win', 'bark', 'leaf_card', 'rock',
            'copper_ore', 'gold_ore', 'grass_band']
#: 本轮按创始人口径**有意修改**的既有玻璃 key（其余既有 key 必须逐像素不变）
CHANGED_GLASS = ['stained_glass', 'glass_lead', 'glass_clear', 'glass_bottle']

#: 回归底片的 key 清单：**硬编码**（不随 M.ORDER 变化），改动前先渲一次存 base，
#: 改动后逐像素比对；包含除有意修改的 4 个玻璃 key 之外的**全部既有 key**。
REGRESS_KEYS = [
    'thatch', 'thatch_old', 'tile_roof', 'slate_roof',
    'plank_wall', 'timber', 'plaster', 'stone',
    'brick', 'iron', 'white_stone', 'canvas',
    'cavity', 'water', 'lamp', 'glass_win',
    'shingle', 'log_wall', 'straw', 'rope',
    'sack', 'wattle', 'ground', 'grass_tuft',
    'foliage', 'vine',
    'cloth_red', 'cloth_blue', 'cloth_ochre', 'wicker', 'clay',
    'produce', 'produce_root', 'fish', 'bread', 'dye_bath',
    'crystal', 'rune_glow', 'bronze', 'patina',
    'glow_water', 'parchment', 'leather',
    'cobble_small', 'cobble_large', 'brick_paving', 'stone_flag',
    'dirt_packed', 'dirt_mud', 'gravel', 'grass_lawn', 'sand', 'wood_deck',
]

TILT = 20.0


# ------------------------------------------------------------------ 场景重建
def clear_scene():
    """read_factory_settings + 清 materials **与 buildings** 两级缓存。

    交接档 §六：`buildings._CACHE` 会留下已删除的 Material 引用 → 之后装配
    `_external_material` 校验失败会**静默回退纯色**（纹理整片消失）。
    """
    P2.clear()
    B._CACHE.clear()
    N.install_materials()


def mat_of(name, **kw):
    return P4.mat_of(name, **kw)


# ------------------------------------------------------------------ 段 1/2：样片 + 25% 门禁
def section_sheet():
    print("=== 段 1：新 %d key + 改动 %d 玻璃 key 样片（100%% | 物理 25%% 双缩略）==="
          % (len(NEW_KEYS), len(CHANGED_GLASS)))
    P2.build(NEW_KEYS + CHANGED_GLASS, 1.0)
    P2.render_to(os.path.join(OUT_DIR, "pbr_mat5_sheet.png"))


def section_true25():
    print("=== 段 2：新 7 key 物理 25%% 门禁（1/4 世界尺寸 + UV×4）===")
    P2.build(NEW_KEYS, 0.25)
    P2.render_to(os.path.join(OUT_DIR, "pbr_mat5_true25.png"))


# ------------------------------------------------------------------ 段 3：玻璃透视 + 灯笼
WIN = (-42.0, 42.0, 108.0, 192.0)          # 窗洞 (x0,x1,z0,z1)，px@1:1


def _glass_box(name, x, y, z, w, d, h, mat):
    """四面玻璃 + 顶盖的**空心**盒（灯笼/罩子）：给内部的灯芯留出可见空间。"""
    x0, x1 = x - w / 2.0, x + w / 2.0
    y0, y1 = y - d / 2.0, y + d / 2.0
    z0, z1 = z, z + h
    quads = [
        [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)],   # 前面
        [(x1, y1, z0), (x0, y1, z0), (x0, y1, z1), (x1, y1, z1)],   # 后面
        [(x0, y1, z0), (x0, y0, z0), (x0, y0, z1), (x0, y1, z1)],   # 左
        [(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)],   # 右
        [(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)],   # 顶
    ]
    return P4.mesh_quads(name, quads, mat)


def _lantern(x, glass_key, tag):
    """一只灯笼：铁骨架 + 空心玻璃罩 + 内部 `lamp` 灯芯（判"灯芯看不看得见"）。"""
    z0, w, h = 40.0, 34.0, 46.0
    P4.box("lpost_" + tag, 5.0, 48.0, 5.0, x, -46.0, 22.0, mat_of('iron'))   # 立柱
    P4.box("lbase_" + tag, w + 8.0, 6.0, w + 8.0, x, -46.0, z0 - 3.0, mat_of('iron'))
    _glass_box("lglass_" + tag, x, -46.0, z0, w, w, h, M.make(glass_key, wear=0.35))
    for dx in (-1.0, 1.0):                                                   # 四角竖梁
        for dy in (-1.0, 1.0):
            P4.box("ledge_%s_%d%d" % (tag, dx > 0, dy > 0), 3.0, h + 4.0, 3.0,
                   x + dx * (w / 2.0), -46.0 + dy * (w / 2.0), z0 + h / 2.0,
                   mat_of('iron'))
    P4.box("lcore_" + tag, 13.0, 26.0, 13.0, x, -46.0, z0 + h * 0.42, mat_of('lamp'))
    P4.mesh_quads("lcap_" + tag, [[(x - w / 2 - 5, -46 - w / 2 - 5, z0 + h + 2),
                                   (x + w / 2 + 5, -46 - w / 2 - 5, z0 + h + 2),
                                   (x + w / 2 + 5, -46 + w / 2 + 5, z0 + h + 2),
                                   (x - w / 2 - 5, -46 + w / 2 + 5, z0 + h + 2)]],
                  mat_of('iron'))


def section_glass():
    clear_scene()
    # ---- 地面 + 立面（开窗洞）+ 石基座
    P4.quad("g5_ground", 900.0, 760.0, 0.0, -250.0, -0.6, mat_of('cobble_large'))
    P4.wall_mesh("g5_wall", -170.0, 170.0, 0.0, 244.0, [WIN], mat_of('plaster'),
                 thick=16.0)
    P4.box("g5_plinth", 344.0, 26.0, 24.0, 0.0, 2.0, 13.0, mat_of('stone'),
           uv_scale=0.6)
    # ---- 白色窗套 + 窗台 + 透明玻璃
    P4.mesh_quads("g5_frame", [[(a, 0.0, c), (b, 0.0, c), (b, 0.0, d), (a, 0.0, d)]
                               for (a, b, c, d) in P4.ring_quads(
                                   WIN[0], WIN[1], WIN[2], WIN[3], 10.0)],
                  mat_of('white_stone'), uv_scale=1.2)
    P4.box("g5_glass", WIN[1] - WIN[0], WIN[3] - WIN[2], 3.0,
           (WIN[0] + WIN[1]) / 2.0, 6.0, (WIN[2] + WIN[3]) / 2.0,
           M.make('glazing_win', wear=0.35))
    P4.box("g5_sill", WIN[1] - WIN[0] + 28.0, 9.0, 18.0,
           (WIN[0] + WIN[1]) / 2.0, 4.0, WIN[2] - 14.0, mat_of('white_stone'))
    # ---- 室内：暗腔后墙 + 侧壁 + 可辨认彩对象（红布/蓝桶/黄筐）+ 暖光
    P4.mesh_quads("g5_back", [[(-110, 150, 0), (110, 150, 0),
                               (110, 150, 210), (-110, 150, 210)]],
                  mat_of('cavity'))
    P4.mesh_quads("g5_floorin", [[(-110, 0, 96), (110, 0, 96),
                                  (110, 150, 96), (-110, 150, 96)]],
                  mat_of('plank_wall'))
    for (nx, mat, w, h, d, z) in ((0, 'cloth_red', 26.0, 44.0, 6.0, 108.0),
                                  (-1, 'cloth_blue', 18.0, 30.0, 18.0, 122.0),
                                  (1, 'cloth_ochre', 22.0, 24.0, 20.0, 114.0)):
        P4.box("g5_obj_%s" % mat, w, h, d, nx * 17.0, 56.0, z, mat_of(mat))
    P4.box("g5_pot", 18.0, 18.0, 18.0, 30.0, 60.0, 111.0, mat_of('clay'))
    _room_light(0.0, 96.0, 176.0)
    # ---- 两只灯笼并置（glass_lead 修黑对照 / glass_clear）
    _lantern(-124.0, 'glass_lead', 'lead')
    _lantern(124.0, 'glass_clear', 'clear')
    P4.label("glazing_win (see-through)", 0.0, -2.0, 232.0, size=15.0)
    P4.label("glass_lead + lamp", -124.0, -2.0, 22.0, size=12.5)
    P4.label("glass_clear + lamp", 124.0, -2.0, 22.0, size=12.5)
    P4.label("interior: cloth/barrel/crate (behind window)", 0.0, -2.0, 252.0,
             size=12.0)

    cam = P4.scene_base()
    P4.frame(cam, 430.0, 320.0, 2.5, (0.0, -40.0, 128.0), tilt=TILT)
    P4.render_to(os.path.join(OUT_DIR, "pbr_mat5_glass.png"))


def _room_light(x, y, z):
    d = bpy.data.lights.new("roomlight", 'POINT')
    d.energy = 26.0
    d.color = (1.0, 0.72, 0.42)
    d.shadow_soft_size = 30.0
    ob = bpy.data.objects.new("roomlight", d)
    ob.location = (P4.u(x), P4.u(y), P4.u(z))
    bpy.context.collection.objects.link(ob)


# ------------------------------------------------------------------ 段 4：自然物特写条
NATURE_STRIP = [
    ("broadleaf", {}, 3),
    ("conifer", {}, 11),
    ("dead_tree", dict(leaves=2), 21),
    ("bush", {}, 31),
    ("boulder", {}, 41),
    ("rubble", {}, 51),
    ("copper_vein", {}, 61),
    ("gold_vein", {}, 71),
    ("iron_outcrop", {}, 81),
    ("crystal_cluster", {}, 91),
    ("ore_band", dict(ln=8.0, angle=0.18), 101),
]
N_GAP = 110.0


def section_nature():
    clear_scene()
    P4.scene_base()
    cam = bpy.context.scene.camera
    b = B.Builder("n5_strip")
    cursor = 0.0
    placed = []
    for (kind, kw, sd) in NATURE_STRIP:
        w, _h, _r = N.NOMINAL.get(kind, (2.0, 1.5, 1.0))
        span = max(w * N.M * 1.15, 60.0)
        N.place(b, kind, x=cursor + span * 0.5, y=0.0, z=0.0, seed=sd, **kw)
        placed.append((kind, cursor + span * 0.5, span))
        cursor += span + N_GAP
    ob = b.to_object()
    objs = [ob]
    for i in range(8):                       # 同尺度火柴人比例尺
        s = B.Builder("n5_stick_%d" % i)
        B.stickman(s, x=0.0, y=-30.0)
        o = s.to_object()
        o.location.x = cursor * (i + 0.5) / 8.0
        bpy.context.view_layer.update()
        objs.append(o)
    # 野外地被：grass_band（本轮新 key）。地面**不参与取景**（它远大于素材剪影）
    gb = B.Builder("n5_ground")
    gb.poly([(-500.0, -1400.0, 0.0), (cursor + 500.0, -1400.0, 0.0),
             (cursor + 500.0, 1400.0, 0.0), (-500.0, 1400.0, 0.0)],
            "field_ground", outward=(0.0, 0.0, 1.0))
    gb.to_object()

    # ---- 取景：**nature 的世界单位 = 1px@1:1**（Builder 直给 px），与样片探针的
    #      u()=px/32 口径不同 → 这里自己算 ortho_scale / 分辨率，不能套 P4.frame。
    pts = []
    for o in objs:
        pts += B.shape_points(o, skip_ground=False)
    right, up = B.cam_axes(0.0, TILT)
    us = [p.dot(right) for p in pts]
    vs = [p.dot(up) for p in pts]
    u0, u1 = min(us) - 70.0, max(us) + 70.0
    v0, v1 = min(vs) - 40.0, max(vs) + 80.0
    w, h = (u1 - u0), (v1 - v0)
    cu, cv = (u0 + u1) / 2.0, (v0 + v1) / 2.0
    anchor = right * cu + up * cv
    fwd = -(right.cross(up))
    cam.location = tuple(anchor - fwd * 20000.0)
    cam.rotation_euler = (math.radians(90.0 - TILT), 0.0, 0.0)
    cam.data.ortho_scale = max(w, h)
    sc = bpy.context.scene
    sc.render.resolution_x = max(64, int(round(w * 1.10)))
    sc.render.resolution_y = max(64, int(round(h * 1.10)))
    P4.render_to(os.path.join(OUT_DIR, "pbr_mat5_nature.png"))
    print("[nature] %d 件：%s" % (len(placed), ", ".join(p[0] for p in placed)))


# ------------------------------------------------------------------ 段 5：回归底片
def section_regress():
    print("=== 段 5：回归底片（%d 个未改动的既有 key）===" % len(REGRESS_KEYS))
    P2.build(REGRESS_KEYS, 1.0)
    P2.render_to(os.path.join(OUT_DIR, "pbr_mat5_regress.png"))


def main():
    argv = sys.argv
    flags = [a for a in argv[argv.index("--") + 1:]] if "--" in argv else []
    only = [a for a in flags if not a.startswith("-")]
    print("=== probe_mat5：四轮材质（新 %d key / 全库 %d key）===" % (len(NEW_KEYS), len(M.ORDER)))
    if not only or "sheet" in only:
        section_sheet()
    if not only or "true25" in only:
        section_true25()
    if not only or "glass" in only:
        section_glass()
    if not only or "nature" in only:
        section_nature()
    if not only or "regress" in only:
        section_regress()

    print("\n=== 特征尺寸换算表（现实 / 游戏 1:1 / 25%%）—— 只列本轮新增 + 改动 ===")
    for k, desc, n, feats in M.audit(verbose=False):
        if k in NEW_KEYS or k in CHANGED_GLASS:
            print("%-13s %-26s nodes=%-4d %s" % (k, desc, n, feats))
    print("DONE")


if __name__ == "__main__":
    main()
