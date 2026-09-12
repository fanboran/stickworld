# -*- coding: utf-8 -*-
"""probe_mat3.py —— 做旧层 / 逐体色变 / 物理 25% 门禁 三段专项对照（材质层 v3.2）

与 `probe_materials_v2.py` 的分工
--------------------------------
* `probe_materials_v2.py`：**出厂样片**（36 材质 × 平面/球/立方体，100% 与 25% 双缩略），
  判"这个材质在这个分辨率下还认不认得出来"。
* 本探针：判**本轮新增的三层**是否真的成立。样片图里物体悬在任意 V 高度（V=世界 Z/32），
  而"近地溅泥"只发生在 V 0~0.83（= 0~35cm）；只有把样件按真实建筑的方式摆在 V=0 的
  地面上才看得出来，所以必须另开一个探针（不是重复劳动）。

三段与产物（`stick-world/temp/`）::
    A  pbr_mat3_age.png     6 种墙面材质站在 Z=0 地面（近地溅泥/苔 + 垂直雨渍 + 日照褪色）
    A' pbr_mat3_noage.png   A 的同构图，但**临时关掉做旧层**（唯一变量＝做旧层）
    A2 pbr_mat3_base.png    墙脚特写（Z 0~110；35cm 溅泥带占其下 1/4）→ 判断"脏不脏"
    B  pbr_mat3_vary.png    同材质 × 6 个独立 Object（抹灰/石砌/陶瓦/茅草）→ 逐体色变
    C  pbr_mat3_gate25.png  A 的**物理 25%**（世界尺寸 1/4 + UV×4，纹素密度真只有 1/4）

段 A 另外**逐高度采样像素**打印 age 与 noage 的亮度差剖面（溅泥带高度/强度的客观读数）；
段 B 打印 6 个同材质物体的 RGB 极差（逐体色变幅度的客观读数）。

跑法::
    blender -b --factory-startup -P probe_mat3.py
"""
import bmesh
import math
import os
import sys

import bpy
from mathutils import Vector
from bpy_extras.object_utils import world_to_camera_view

HERE = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() \
    else r"F:/VSCode/game-2/.temp/building-pipeline-v2/tools/blender_buildings"
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import materials as M          # noqa: E402
import probe_materials_v2 as P2   # noqa: E402（复用其天空/太阳/相机/换算，保证与样片同光照）

OUT_DIR = "F:/VSCode/game-2/.temp/building-pipeline-v2/stick-world/temp"

#: 段 A/C 的墙面材质（全部有 AGE 做旧层登记）
WALL_KEYS = [('plaster', '抹灰'), ('stone', '粗料石'), ('brick', '红砖'),
             ('plank_wall', '木板墙'), ('log_wall', '原木墙'), ('wattle', '编条篱')]
#: 段 B 的逐体色变对照（4 组 × 6 个独立 Object）
VARY_KEYS = [('plaster', '抹灰 wall'), ('stone', '石砌 wall'),
             ('tile_roof', '陶瓦 roof'), ('thatch', '茅草 roof')]

#: 段 A 布局（px@1:1；1 世界单位 = 1px@1:1 = P2.u(1)）
PW, PH, PGAP = 96.0, 160.0, 20.0          # 墙板 3 格宽 × 5 格高
B_PITCH, B_ROWDY = 116.0, 210.0           # 段 B 列距 / 行距（行距沿 +Y，靠俯角抬到画面上方）
B_WALL_H, B_SLAB_D = 160.0, 70.0

_AGE_BAK = dict(M.AGE)
_OBJ_BAK = dict(M.OBJ_VAR)


# ---------------------------------------------------------------- 材质表开关
def cfg(age=True, objv=True):
    """临时改写做旧层/逐体色变表并清缓存 → 下一次 `make()` 重建 NodeGroup。

    旧 NodeGroup 仍留在 `bpy.data` 里（新组自动改名 `nn_x.001`），已建材质引用有效。
    段 C（物理 25%）**不需要**关溅泥层：做旧层走 UV 的 V，与场景/世界尺度无关，
    1/4 世界尺寸 + UV×4 之后它在画面里的相对高度与全尺寸完全一致。
    """
    M.AGE.clear()
    if age:
        M.AGE.update(_AGE_BAK)
    M.OBJ_VAR.clear()
    if objv:
        M.OBJ_VAR.update(_OBJ_BAK)
    M.reset_cache()


# ---------------------------------------------------------------- 场景基础
def link(ob):
    bpy.context.collection.objects.link(ob)
    return ob


def select_only(ob):
    bpy.ops.object.select_all(action='DESELECT')
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob


def quad(name, w, h, vertical=True):
    """w/h 世界单位。vertical → 面向 -Y 的立面板；否则水平板（法线 +Z）。"""
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_grid(bm, x_segments=1, y_segments=1, size=1.0)
    bm.to_mesh(me)
    bm.free()
    ob = link(bpy.data.objects.new(name, me))
    ob.scale = (w / 2.0, h / 2.0, 1.0)
    if vertical:
        ob.rotation_euler = (math.radians(90), 0.0, 0.0)
    bpy.context.view_layer.update()
    select_only(ob)
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
    return ob


def put(ob, mat, x, y, z, uv_scale=1.0):
    ob.location = (P2.u(x), P2.u(y), P2.u(z))
    bpy.context.view_layer.update()
    ob.data.materials.clear()
    ob.data.materials.append(mat)
    M.box_project_uv(ob, uv_scale=uv_scale)
    return ob


def wipe():
    """只删网格对象（材质/世界/灯光保留 → 材质缓存不需要清，见交接档 §六）。"""
    for ob in list(bpy.data.objects):
        if ob.type == 'MESH':
            bpy.data.objects.remove(ob, do_unlink=True)


def frame(cam, w_px, h_px, zoom, anchor_px):
    """取景：w/h 为 px@1:1，anchor 为 px@1:1 三元组（画面中心）。返回渲染像素尺寸。"""
    global _ANCHOR
    sc = bpy.context.scene
    sc.render.resolution_x = max(64, int(round(w_px * zoom)))
    sc.render.resolution_y = max(64, int(round(h_px * zoom)))
    _ORTHO[0] = P2.u(w_px)
    cam.data.ortho_scale = _ORTHO[0]
    _ANCHOR = tuple(P2.u(v) for v in anchor_px)
    P2.place_camera(cam, _ANCHOR)
    return sc.render.resolution_x, sc.render.resolution_y


def render_to(path):
    sc = bpy.context.scene
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)
    print("RENDER -> %s  %dx%d" % (path, sc.render.resolution_x, sc.render.resolution_y))


# ---------------------------------------------------------------- 像素读数
_ANCHOR = (0.0, 0.0, 0.0)
_ORTHO = [1.0]


def world_to_px(p_px, res):
    """世界(px@1:1 三元组) → 像素坐标（x 自左，y 自下）。

    直接用 Blender 自己的 `world_to_camera_view`（手推 screen-y 会把 sensor_fit /
    俯角投影算错，第一版就吃过这个亏：采样点落到地面上了）。
    """
    co = world_to_camera_view(bpy.context.scene, bpy.context.scene.camera,
                              Vector((P2.u(p_px[0]), P2.u(p_px[1]), P2.u(p_px[2]))))
    return co.x * res[0], co.y * res[1]


def sample(img, res, p_px, half=3):
    """采样世界点 p（px@1:1）周围 (2*half+1)^2 像素均值（线性色，PNG 载入即线性）。"""
    px = img.pixels[:]
    x0, y0 = world_to_px(p_px, res)
    acc = [0.0, 0.0, 0.0]
    n = 0
    for dy in range(-half, half + 1):
        for dx in range(-half, half + 1):
            xi = min(max(int(x0) + dx, 0), res[0] - 1)
            yi = min(max(int(y0) + dy, 0), res[1] - 1)
            o = (yi * res[0] + xi) * 4
            acc = [acc[j] + px[o + j] for j in range(3)]
            n += 1
    return [a / n for a in acc]


def load_px(path):
    return bpy.data.images.load(path)


def free_px(img):
    bpy.data.images.remove(img)


def fmt(c):
    return "(%.3f,%.3f,%.3f)" % tuple(c)


def lum(c):
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]


# ---------------------------------------------------------------- 段 A / C
def build_walls(scale=1.0, uv_scale=1.0, mat_scale=1.0, wear=None):
    """6 面带做旧层的独立墙板 + 一块地面。scale=0.25/uv_scale=4 → 物理 25%。"""
    s = scale
    g = quad("ground", P2.u(900.0 * s), P2.u(600.0 * s), vertical=False)
    put(g, M.get('ground') or M.make('ground', wear=0.25), 0.0, 0.0, 0.0, uv_scale=uv_scale)
    n = len(WALL_KEYS)
    span = n * PW * s + (n - 1) * PGAP * s
    x0 = -span / 2.0 + PW * s / 2.0
    for i, (key, _label) in enumerate(WALL_KEYS):
        x = x0 + i * (PW + PGAP) * s
        ob = quad("A_%s" % key, P2.u(PW * s), P2.u(PH * s), vertical=True)
        w = wear if wear is not None else P2.DEFAULT_WEAR.get(key, 0.5)
        put(ob, M.make(key, wear=w, scale=mat_scale), x, 0.0, PH * s / 2.0,
            uv_scale=uv_scale)
    return span


def section_age(cam, path, noage=False):
    wipe()
    # objv 恒为 True：段 A 与 A' 的物体同名 → Object Random 相同 → 逐体色变抵消，
    # 两张图之差**只剩做旧层**（否则色偏会混进竖向剖面读数）。
    cfg(age=not noage, objv=True)
    # wear=0.5 = buildings.py 走 `materials.get(name)` 时的实拍值（不是样片那套按材质调过的）
    span = build_walls(wear=0.5)
    res = frame(cam, span + 2 * 26.0, 300.0, 1.9, (0.0, 0.0, 62.0))
    render_to(path)
    return span, res


def section_base(cam, path):
    """墙脚特写：只拍 Z 0~110（0.35m 溅泥带占其下 1/4），放大看这层做旧脏不脏。"""
    wipe()
    cfg(age=True, objv=True)
    span = build_walls(wear=0.5)
    frame(cam, span + 2 * 26.0, 140.0, 3.0, (0.0, 0.0, 42.0))
    render_to(path)


def profile_age(cam, path_age, span, res):
    """墙脚→墙腰的**竖向剖面**：逐高度采样 age 图与 noage 图的亮度差。

    这是"近地溅泥带到底有多高、有多强"的唯一客观读数（视觉判断容易被光照骗）。
    """
    a = load_px(path_age)
    b = load_px(os.path.join(OUT_DIR, "pbr_mat3_noage.png"))
    zs = [2.0, 6.0, 10.0, 15.0, 20.0, 26.0, 34.0, 45.0, 60.0, 95.0, 140.0]
    n = len(WALL_KEYS)
    x0 = -span / 2.0 + PW / 2.0
    print("--- 竖向剖面：Δlum(age - noage)，每列一个材质；Z 为世界单位(1格=32) ---")
    print("      Z:" + "".join("%7.0f" % z for z in zs))
    for i, (key, _label) in enumerate(WALL_KEYS):
        x = x0 + i * (PW + PGAP)
        row = []
        for z in zs:
            ca = sample(a, res, (x, 0.0, z))
            cb = sample(b, res, (x, 0.0, z))
            row.append(100.0 * (lum(ca) - lum(cb)) / max(lum(cb), 1e-6))
        print("  %-11s" % key + "".join("%+7.1f" % v for v in row))
    free_px(a)
    free_px(b)


def section_gate25(cam, path):
    """物理 25%：世界尺寸 1/4 + UV×4（纹素密度真的 1/4；UV 不变 → 做旧层也等比）。"""
    wipe()
    cfg(age=True, objv=True)
    span = build_walls(scale=0.25, uv_scale=4.0)
    frame(cam, span + 2 * 26.0 * 0.25, 300.0 * 0.25, 7.6, (0.0, 0.0, 62.0 * 0.25))
    render_to(path)


# ---------------------------------------------------------------- 段 B
def section_vary(cam, path):
    wipe()
    cfg(age=True, objv=True)
    n = 6
    span = n * PW + (n - 1) * PGAP
    x0 = -span / 2.0 + PW / 2.0
    rows = []
    for r, (key, label) in enumerate(VARY_KEYS):
        y = r * B_ROWDY
        roof = key in ('tile_roof', 'thatch', 'slate_roof', 'shingle')
        for i in range(n):
            x = x0 + i * (PW + PGAP)
            name = "B_%s_%d" % (key, i)          # 名字不同 → Object Random 各不同
            if roof:
                ob = quad(name, P2.u(PW), P2.u(B_SLAB_D), vertical=False)
                put(ob, M.make(key, wear=P2.DEFAULT_WEAR.get(key, 0.5)),
                    x, y, 150.0)
            else:
                ob = quad(name, P2.u(PW), P2.u(B_WALL_H), vertical=True)
                put(ob, M.make(key, wear=P2.DEFAULT_WEAR.get(key, 0.5)),
                    x, y, B_WALL_H / 2.0)
        rows.append((key, label, y, roof))
    res = frame(cam, span + 2 * 26.0, 430.0, 1.55, (0.0, 0.0, 196.0))
    render_to(path)

    print("--- 逐体色变客观读数（同一材质 × 6 个独立 Object）---")
    img = load_px(path)
    for key, label, y, roof in rows:
        cs = []
        for i in range(n):
            x = x0 + i * (PW + PGAP)
            z = 150.0 if roof else B_WALL_H * 0.62
            cs.append(sample(img, res, (x, y, z)))
        lums = [lum(c) for c in cs]
        lo, hi = min(lums), max(lums)
        spread = 100.0 * (hi - lo) / max(sum(lums) / len(lums), 1e-6)
        print("  %-11s %-10s 明度极差 %5.1f%%  R极差 %5.1f%%  样本 %s"
              % (key, label, spread,
                 100.0 * (max(c[0] for c in cs) - min(c[0] for c in cs))
                 / max(sum(c[0] for c in cs) / len(cs), 1e-6),
                 " ".join("%.3f" % l for l in lums)))
    free_px(img)


def main():
    P2.clear()                                  # 一张场景只 read_factory_settings 一次
    P2.setup_world()
    P2.add_sun("key", 42.0, -38.0, 3.4, (1.00, 0.95, 0.86), 3.5)
    P2.add_sun("fill", 18.0, 125.0, 0.70, (0.72, 0.80, 0.95), 25.0)
    cam = P2.make_camera()
    P2.setup_render(cam, 100.0, 100.0, 1.0)     # 只取引擎/采样/色彩管理

    print("=== 段 A：做旧层（墙脚溅泥/苔 + 雨渍 + 日照褪色）===")
    span, res = section_age(cam, os.path.join(OUT_DIR, "pbr_mat3_age.png"))
    print("=== 段 A'：同构图 · 关掉做旧层（对照）===")
    section_age(cam, os.path.join(OUT_DIR, "pbr_mat3_noage.png"), noage=True)
    profile_age(cam, os.path.join(OUT_DIR, "pbr_mat3_age.png"), span, res)
    print("=== 段 A2：墙脚特写（判断溅泥脏不脏）===")
    section_base(cam, os.path.join(OUT_DIR, "pbr_mat3_base.png"))
    print("=== 段 B：逐体色变 ===")
    section_vary(cam, os.path.join(OUT_DIR, "pbr_mat3_vary.png"))
    print("=== 段 C：物理 25% 门禁 ===")
    section_gate25(cam, os.path.join(OUT_DIR, "pbr_mat3_gate25.png"))
    cfg(age=True, objv=True)
    print("DONE")


if __name__ == "__main__":
    main()
