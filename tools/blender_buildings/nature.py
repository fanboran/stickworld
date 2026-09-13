# -*- coding: utf-8 -*-
"""nature.py —— 野外自然物层（管线 v3 · 写实 PBR · 自然物批次）

定位
----
`props.py` 解决"建筑前场道具"，本模块解决"建筑之外的世界"：树 / 灌木 / 芦苇 /
蘑菇 / 矿脉 / 岩石。产物是**可独立出图的单件**（接地基线 z=0、真实尺寸、每件带
seed），供游戏当 sprite 消费，也供 `field_dist.py` 做野外分布。

为什么单开一层（与 props.py 的分工）
------------------------------------
* 道具是**立面的一部分**（挂墙、门口、市集），尺寸受建筑约束；
* 自然物是**独立体量**（10 m 的树 vs 2.6 m 的檐口），只受"火柴人 130 = 1.70 m"
  这一个比例锚约束，不能塞进 props 的 GAME_SCALE 口径（那是给"现实尺寸道具在
  游戏尺寸下太小"打的补丁，树本来就大，再乘 1.45 就失控）。

尺寸纪律
--------
* **1 m = 76.4706 单位**（= STICKMAN_H 130 / 1.70 m；与 1 格 = 32 单位 = 0.42 m
  互洽：32.1 单位/m）。所有尺寸先在**米**里给，再 `* M` 换算，便于复核真实感。
* 地面 z=0；所有 builders 的 `z` = 底面绝对高度；`x / y` = 水平中心。
* 正面 = -Y（与 buildings/props 一致），但自然物是**全向体量**，只要求"迎光面
  朝前最好看"（种子决定枝干朝向，无需按 -Y 特化）。

材质纪律
--------
* **四轮起 `materials.py` 已有自然物专用 key**（`bark` / `leaf_card` / `rock` /
  `copper_ore` / `gold_ore` / `grass_band`），本层通过 `MAT_SPEC` 直接引用，
  不再拿建筑材质硬凑；树种/岩性/叶色的差别只走 `materials.tune()` 的
  tint / wear / scale 三旋钮。
* 仍然**不改 materials.py 的入口/缓存/尺度契约**（`get/reset_cache/uv_*/M_PER_UV`）。
* 已知未接入：针叶树冠仍是实心锥台层（贴 alpha 叶卡会打洞），见汇报清单。

跑法（只做规格自检，不渲染）::
    blender -b --factory-startup -P nature.py
"""

import math
import os
import random
import sys

from mathutils import Vector

import bpy  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import buildings as B   # noqa: E402

M = 130.0 / 1.70        # 1 米 = 76.4706 世界单位（比例锚，禁止各处另写）
CELL = B.CELL
_H2 = 0.5               # 每半圈抖动幅度基准


# ============================================================ 工具

def _h(a, b=0.0):
    """确定性 hash → [0,1)。不用 random 的场合（需跨进程逐位一致）。"""
    x = math.sin(float(a) * 12.9898 + float(b) * 78.233) * 43758.5453
    return x - math.floor(x)


def _rng(seed):
    return random.Random(int(seed) & 0x7FFFFFFF)


# ============================================================ 材质解析

#: 本层材质名 → (materials.py 注册 key, tune 参数)。tint 可 >1（乘法，用于提亮/染色）。
#: **全部落在既有 key 内**；括号里注明"借"的语义与缺口。
MAT_SPEC = {
    # ---- 树皮（四轮：真 `bark` key —— 纵向裂沟 + 长条板块 + 苔；树种靠 tint 分）----
    "bark_oak":   ("bark", dict(tint=(1.12, 1.00, 0.84), wear=0.45, scale=0.85)),
    "bark_pine":  ("bark", dict(tint=(0.98, 0.70, 0.48), wear=0.40, scale=0.72)),   # 红松皮
    "bark_dead":  ("bark", dict(tint=(0.98, 0.92, 0.84), wear=0.88, scale=1.00)),
    "bark_birch": ("bark", dict(tint=(1.90, 1.86, 1.74), wear=0.22, scale=1.15)),   # 白桦
    # ---- 树冠（四轮：**alpha 裁切叶卡** `leaf_card`，治"叶团像实心贴片"）----
    "leaf_a":     ("leaf_card", dict(scale=1.00, wear=0.34)),
    "leaf_b":     ("leaf_card", dict(tint=(0.82, 0.90, 0.72), scale=0.85, wear=0.44)),
    "leaf_core":  ("foliage", dict(tint=(0.42, 0.55, 0.36), scale=0.80, wear=0.55)),
    "leaf_dead":  ("leaf_card", dict(tint=(1.30, 1.05, 0.62), scale=0.75, wear=0.70)),
    # 针叶：针叶树几何是**实心锥台层**（不是面片），把 alpha 叶卡贴上去会打出洞 →
    # 仍用不透明 `vine` 的针束读法（诚实清单里注明）。
    "leaf_pine":  ("vine",    dict(scale=0.56, wear=0.30)),
    "leaf_pine2": ("vine",    dict(tint=(0.72, 0.86, 0.80), scale=0.46, wear=0.22)),
    # ---- 地被 ----
    "reed":       ("grass_tuft", dict(tint=(1.15, 1.26, 0.80))),
    "grass":      ("grass_tuft", dict(tint=(1.00, 1.12, 0.76))),
    "grass_dry":  ("grass_tuft", dict(tint=(1.85, 1.60, 0.85))),
    "moss":       ("foliage", dict(tint=(0.55, 0.72, 0.42), scale=1.5, wear=0.4)),
    # 野外地被（四轮新 key）：供 `probe_nature.make_ground` / field_dist 大地面
    "field_ground": ("grass_band", dict(scale=1.00, wear=0.40)),
    # ---- 岩石（四轮：真 `rock` key —— 圆钝岩瘤 + 风化 + 苔，**不再借 slate_roof 层理**）----
    "rock":       ("rock", dict(tint=(1.05, 1.02, 0.96), scale=0.60, wear=0.45)),
    "rock_dark":  ("rock", dict(tint=(0.72, 0.74, 0.78), scale=0.72, wear=0.38)),
    "rock_light": ("rock", dict(tint=(1.35, 1.31, 1.22), scale=0.50, wear=0.55)),
    "rock_mossy": ("rock", dict(tint=(0.80, 0.95, 0.66), scale=0.56, wear=0.85)),
    "cut_stone":  ("stone", dict(tint=(0.92, 0.92, 0.95), scale=1.00, wear=0.70)),
    # ---- 矿 ----
    # 铁块必须**明显暗于岩体、且带红棕氧化**，否则整块露头读作"普通石头堆"；
    # tint 是乘法且作用于氧化后的颜色，所以提高 tint 就能把 dark 基底与锈色一起抬起来。
    "ore_iron":   ("iron", dict(tint=(2.10, 1.12, 0.78), wear=0.72, scale=1.05)),
    "rust":       ("iron", dict(wear=1.00, scale=0.42, tint=(3.60, 1.55, 0.65))),
    # 四轮：铜/金矿改真 key（原来借 slate_roof 染绿 / iron 染金，读作"染色石头"）
    "ore_copper": ("copper_ore", dict(tint=(1.05, 1.00, 0.98), scale=1.00, wear=0.20)),
    "ore_gold":   ("gold_ore", dict(tint=(1.05, 1.00, 0.95), scale=1.00, wear=0.12)),
    # 水晶（四轮：不再借 glass_win 染蓝，改真 `crystal` key —— 半透明 + 内发光）
    "crystal_a":  ("crystal", dict(tint=(0.72, 1.15, 2.30), scale=1.00)),
    "crystal_b":  ("crystal", dict(tint=(0.95, 1.70, 1.90), scale=0.85)),
    "quartz":     ("white_stone", dict(tint=(1.15, 1.18, 1.25), scale=1.5, wear=0.30)),
    # ---- 木质断面 ----
    "wood_break": ("plank_wall", dict(tint=(1.55, 1.48, 1.28), scale=1.5)),   # 断枝口露白木
    "wood_cut":   ("plank_wall", dict(tint=(1.30, 1.22, 1.02), scale=1.1)),   # 树桩端面
    "wood_ring":  ("plank_wall", dict(tint=(0.38, 0.32, 0.26), scale=2.0)),   # 年轮暗圈
    # ---- 蘑菇 ----
    "mush_cap":   ("cloth_red", dict(tint=(1.25, 0.72, 0.62), scale=2.4, wear=0.20)),
    "mush_stalk": ("canvas", dict(tint=(1.15, 1.10, 0.98), scale=1.6)),
    "mush_dot":   ("white_stone", dict(tint=(1.35, 1.34, 1.30), scale=2.2)),
    "mush_brown": ("clay", dict(tint=(0.95, 0.78, 0.55), scale=2.0)),
    # ---- 土 ----
    "dirt":       ("ground", dict(scale=0.55, wear=0.70)),
}


def nature_material(name):
    """材质解析器：本层名（MAT_SPEC）→ 现造；其余交回 buildings 的默认链路。"""
    spec = MAT_SPEC.get(name)
    if spec is None:
        return None
    import materials as Mt
    key, kw = spec
    m = Mt.make(key)
    if kw:
        Mt.tune(m, **kw)
    m.name = name
    return m


def install_materials():
    """把本层解析器注入 buildings（公共 API；不改 materials.py）。"""
    B.set_material_resolver(nature_material)


# ============================================================ 几何原语

def _tube(b, p0, p1, r0, r1, mat, segs=8, jitter=0.0, seed=0.0, droop=0.0,
          cap0=True, cap1=True, floor=None):
    """两段圆台（枝干/锥顶/晶柱通用）：UV 的 U 沿轴、V 绕周。

    为什么不用 `Builder.cylinder`：圆柱没有 uv_axes 参数，UV 只能按主导轴投影，
    树干上的木纹会**横着长**（读成"堆起来的原木"而不是"一根树干"）。这里显式
    传 uv_axes=(轴, 切向)，木纹顺枝干走。

    `floor` 给定时把所有顶点 z 夹到 floor（**接地纪律**）：斜向树根/枝干的圆环会
    下探到地面以下，出图后表现为"贴地物下方多出隐藏几何"，sprite 按底边对齐时
    会整体上浮。夹平后底面落在 z=floor，直接读作"埋进地里"。
    """
    p0, p1 = Vector(p0), Vector(p1)
    ax = p1 - p0
    ln = ax.length
    if ln < 1e-6:
        return
    a = ax / ln
    ref = Vector((0.0, 0.0, 1.0)) if abs(a.z) < 0.9 else Vector((1.0, 0.0, 0.0))
    t1 = a.cross(ref).normalized()
    t2 = a.cross(t1)
    mid = (p0 + p1) * 0.5

    def C(v):
        if floor is not None and v.z < floor:
            return Vector((v.x, v.y, floor))
        return v

    ring0, ring1, dirs = [], [], []
    for i in range(segs):
        th = 2.0 * math.pi * i / segs
        d = t1 * math.cos(th) + t2 * math.sin(th)
        dirs.append(d)
        k0 = 1.0 + jitter * (_h(i, seed + 11.0) - 0.5) * 2.0
        k1 = 1.0 + jitter * (_h(i, seed + 23.0) - 0.5) * 2.0
        drop = droop * _h(i, seed + 31.0)
        ring0.append(C(p0 + d * (r0 * k0) - a * drop))
        ring1.append(C(p1 + d * (r1 * k1)))
    for i in range(segs):
        j = (i + 1) % segs
        quad = [ring0[i], ring0[j], ring1[j], ring1[i]]
        uniq = []
        for v in quad:
            if all((v - u).length > 1e-5 for u in uniq):
                uniq.append(v)
        if len(uniq) < 3:
            continue
        cc = Vector((0.0, 0.0, 0.0))
        for v in uniq:
            cc = cc + v
        cc = cc / float(len(uniq))
        dm = (dirs[i] + dirs[j])
        if dm.length < 1e-6:
            dm = dirs[i]
        b.poly(uniq, mat, outward=(cc - mid), uv_axes=(a, dm.normalized()))
    if cap0 and r0 > 1e-4:
        b.poly(list(reversed(ring0)), mat, outward=-a, uv_axes=(t1, t2))
    if cap1 and r1 > 1e-4:
        b.poly(list(ring1), mat, outward=a, uv_axes=(t1, t2))


def _blob(b, c, r, mat, rings=5, segs=9, seed=0.0, jitter=0.22,
          ry=None, rz=None, floor=None):
    """抖动低多边形球（叶团 / 岩石体）：flat 面 + 顶点抖动 = 有机轮廓。

    `floor` 把底面夹平成一块"埋入地面"的平底（岩石必需：圆底球坐在平地上只会
    单点接触，读作"浮着"；夹平后既像嵌进土里，又保证 sprite 底边就是地面线）。
    """
    c = Vector(c)
    ry = r if ry is None else ry
    rz = r if rz is None else rz

    def vert(i, j):
        phi = math.pi * (float(i) / rings) - math.pi / 2.0
        cz, cr = math.sin(phi), math.cos(phi)
        th = 2.0 * math.pi * j / segs
        k = 1.0 + jitter * (_h(i * 97.0 + j, seed) - 0.5) * 2.0
        v = c + Vector((cr * math.cos(th) * ry * k, cr * math.sin(th) * ry * k,
                        cz * rz * k))
        if floor is not None and v.z < floor:
            v = Vector((v.x, v.y, floor))
        return v

    rp = [[vert(i, j) for j in range(segs)] for i in range(rings + 1)]
    for i in range(rings):
        for j in range(segs):
            j2 = (j + 1) % segs
            a0, a1 = rp[i][j], rp[i][j2]
            b0, b1 = rp[i + 1][j], rp[i + 1][j2]
            if i == 0:
                quad = [a0, b0, b1]
            elif i == rings - 1:
                quad = [a0, a1, b1]
            else:
                quad = [a0, a1, b1, b0]
            uniq = []
            for v in quad:
                if all((v - u).length > 1e-5 for u in uniq):
                    uniq.append(v)
            if len(uniq) < 3:
                continue
            cc = Vector((0.0, 0.0, 0.0))
            for v in uniq:
                cc = cc + v
            cc = cc / float(len(uniq))
            b.poly(uniq, mat, outward=(cc - c))


def _leafcard(b, c, size, normal, mat="leaf_a", seed=0.0, curl=0.22):
    """一张 **alpha 裁切的叶卡**（十字交叉的两片方形面片）。

    四轮返工：此前用"实心叶形多边形"堆叶团 → 边缘是几何剪影，游戏尺寸下读作
    "实心贴片"。现在改用 `leaf_card` 材质（alpha 裁切：团内是叶、团间透明），
    几何退化成两张交叉方片 —— 叶团的碎边由 alpha 给出，"叶簇"读法才成立。

    卡要**够大**（0.3~0.6 m）才在卡内看到 3~10 片叶；卡太小会整张落进 alpha 空隙
    里消失（尺寸由调用方给，见 broadleaf/bush）。
    """
    n = Vector(normal).normalized()
    ref = Vector((0.0, 0.0, 1.0)) if abs(n.z) < 0.9 else Vector((1.0, 0.0, 0.0))
    up = (n.cross(ref)).cross(n).normalized()
    right = up.cross(n)
    s = size * 0.5
    tilt = max(-0.35, min(0.35, curl))
    a = (up * math.cos(tilt) + n * math.sin(tilt)).normalized()
    cc = Vector(c)
    b.poly([cc - right * s - a * s, cc + right * s - a * s,
            cc + right * s + a * s, cc - right * s + a * s], mat, outward=n)
    ca, sa = math.cos(1.12), math.sin(1.12)
    r2 = (right * ca + a * sa).normalized()
    a2 = (a * ca - right * sa).normalized()
    b.poly([cc - r2 * s - a2 * s, cc + r2 * s - a2 * s,
            cc + r2 * s + a2 * s, cc - r2 * s + a2 * s], mat, outward=n)


def _rock(b, x, y, z, r, mat="rock", seed=0.0, squash=0.72, n=1, spread=0.55,
          bury=0.30, rings=3, segs=7, floor=None):
    """岩石：1~n 个互相咬合的抖多面体，底面**夹平到地面线**（z = floor）。

    `floor` 默认 z+0.5；**堆叠**场景（碎石堆）要显式传 `floor=地面+0.5`，否则
    以抬高的 z 当基准会让整堆悬空。
    """
    rng = _rng(seed)
    fl = z + 0.5 if floor is None else floor
    for i in range(n):
        f = 1.0 if n == 1 else rng.uniform(0.60, 1.00)
        ox = 0.0 if n == 1 else rng.uniform(-spread, spread) * r
        oy = 0.0 if n == 1 else rng.uniform(-spread, spread) * r
        rr = r * f
        ry = rr * rng.uniform(0.85, 1.20)
        rz = rr * squash * rng.uniform(0.90, 1.10)
        c = (x + ox, y + oy, z + rz * (1.0 - bury))
        _blob(b, c, rr, mat, rings=rings, segs=segs, seed=seed + i * 13.0,
              jitter=0.32, ry=ry, rz=rz, floor=fl)


def _pebbles(b, x, y, z, r, n, mat="rock", seed=0.0, spread=1.0):
    rng = _rng(seed)
    for i in range(n):
        th = rng.uniform(0.0, 2.0 * math.pi)
        d = rng.uniform(0.35, 1.0) * spread * r * 2.2
        rr = r * rng.uniform(0.18, 0.45)
        _rock(b, x + math.cos(th) * d, y + math.sin(th) * d, z, rr, mat,
              seed=seed + 7.0 * i, squash=0.62, rings=2, segs=6, bury=0.35)


def shadow(b, w, d, x=0.0, y=0.0, spread=26.0, steps=3):
    """接地阴影：**椭圆碟**（三级，由内向外变浅）。

    不用 `buildings.contact_shadow` 的方踏板：建筑是直角体量，方踏板读作接触阴影；
    树/石头是圆立面，方踏板在细树干下面就是"铺了块灰毯"（首轮实拍踩到）。
    椭圆碟的圆轮廓才是自然物该有的接地读法。被 `shape_points` 排除出剪影。
    """
    rx = max(8.0, w * 0.5)
    ry = max(7.0, d * 0.5)
    cap = min(1.0 + 0.55 * spread / max(1.0, rx), 2.4)
    for i in range(steps):
        k = float(i) / float(max(1, steps - 1))
        sp = 1.0 + (cap - 1.0) * k
        h = max(0.8, 2.0 - 0.6 * i)
        b.ellipse_prism((x, y, h * 0.5), rx * sp, ry * sp, h,
                        ("shadow_near", "shadow_mid", "shadow_far")[min(i, 2)],
                        segments=18, axis="Z")
    return {"spread": spread}


def _chunk(b, c, size, mat, rng, flat=False):
    """一块有棱角的矿石/碎块（随机朝向的扁盒）。

    `flat=True` 只绕 Z 转（**落地碎块**用）：带俯仰的盒子角会戳到地面以下，
    出图后 sprite 底边就多出隐藏几何。
    """
    if flat:
        b.box((size, size * rng.uniform(0.7, 1.1), size * rng.uniform(0.5, 0.9)),
              (c[0], c[1], c[2]), mat, rot=(0.0, 0.0, rng.uniform(0, 3.14)))
        return
    s = (size, size * rng.uniform(0.6, 1.0), size * rng.uniform(0.5, 0.9))
    b.box(s, c, mat, rot=(rng.uniform(0, 0.8), rng.uniform(0, 0.8),
                          rng.uniform(0, 3.14)))


# ============================================================ 树木

def broadleaf(b, x=0.0, y=0.0, z=0.0, seed=0, h=0.0, spread=0.0, lod="full",
              lean=0.0):
    """阔叶乔木：主干（两段微弯 + 根部放脚）→ 3~4 级分枝 → 分层叶团。

    叶团 = 球状实体叶簇（体积）+ 枝梢与簇面的**叶形面片**（打碎边缘）。
    单靠面片会读成"贴片"、单靠球会读成"绿气球"，两者叠加才成立。
    """
    rng = _rng(seed)
    H = h * M if h else rng.uniform(8.0, 11.5) * M
    trunk_r = H * rng.uniform(0.030, 0.040)
    clear = H * rng.uniform(0.30, 0.40)
    crown_r = (spread * M if spread else H * rng.uniform(0.40, 0.52))
    bark = "bark_oak" if rng.random() < 0.75 else "bark_birch"
    leaf = "leaf_a"
    bx = rng.uniform(-0.05, 0.05) * H
    by = rng.uniform(-0.05, 0.05) * H
    x += lean * H * 0.35

    # 主干
    mid_p = (x + bx * 0.5, y + by * 0.5, z + clear * 0.55)
    top_p = Vector((x + bx, y + by, z + clear + H * 0.20))
    _tube(b, (x, y, z + 0.6), mid_p, trunk_r, trunk_r * 0.84, bark,
          segs=9, jitter=0.07, seed=seed, floor=z + 0.5)
    _tube(b, mid_p, top_p, trunk_r * 0.84, trunk_r * 0.52, bark,
          segs=8, jitter=0.07, seed=seed + 3.0)
    # 根部放脚（4~6 条：树干"抓地"，是树不像电线杆的关键之一）
    nr = rng.randint(4, 6)
    for i in range(nr):
        th = 2.0 * math.pi * (i + rng.uniform(-0.22, 0.22)) / nr
        ro = trunk_r * rng.uniform(2.3, 3.6)
        _tube(b, (x + math.cos(th) * ro, y + math.sin(th) * ro,
                  z + rng.uniform(0.0, 0.05) * M),
              (x, y, z + trunk_r * 1.3), trunk_r * 0.40, trunk_r * 0.72, bark,
              segs=5, jitter=0.12, seed=seed + 7.0 + i, floor=z + 0.5)

    # 分枝（3~4 级，递归）
    tips = []
    nb = rng.randint(3, 5)
    base = top_p - Vector((0.0, 0.0, 0.07 * H))
    cards = (lod == "full")
    for i in range(nb):
        th = 2.0 * math.pi * (i + rng.uniform(-0.25, 0.25)) / nb
        elev = math.radians(rng.uniform(34, 56))
        d = Vector((math.sin(elev) * math.cos(th), math.sin(elev) * math.sin(th),
                    math.cos(elev)))
        _limb(b, rng, base, d, crown_r * rng.uniform(0.40, 0.58),
              trunk_r * 0.52, bark, leaf, 2, tips, seed + i * 17.0, cards)
    if lod == "simple":
        for i, c in enumerate(((x, y, z + clear + H * 0.34),
                               (x + bx * 0.5, y + by * 0.5, z + clear + H * 0.54))):
            # 远景 LOD：内核用不透明 `leaf_core` 撑剪影 + 少量大叶卡打碎边缘
            _blob(b, c, crown_r * 0.58, "leaf_core", rings=4, segs=8, seed=seed + i,
                  jitter=0.26, rz=crown_r * 0.46)
            for q in range(3):
                d = _sphere_dir(rng)
                _leafcard(b, (c[0] + d.x * crown_r * 0.5, c[1] + d.y * crown_r * 0.5,
                              c[2] + d.z * crown_r * 0.4),
                          crown_r * 0.55, d, leaf, seed=seed + 8.0 + q,
                          curl=rng.uniform(-0.2, 0.2))
        _pad(b, x, y, crown_r * 2.0)
        return {"h": H, "crown": crown_r, "trunk": trunk_r}

    # 分层叶团：底层宽、顶层窄（正/侧读都分层）
    layers = ((z + clear + H * 0.20, crown_r * 0.34, 3),
              (z + clear + H * 0.38, crown_r * 0.48, 4),
              (z + clear + H * 0.55, crown_r * 0.40, 4),
              (z + clear + H * 0.68, crown_r * 0.26, 3),
              (z + clear + H * 0.78, crown_r * 0.15, 2))
    for li, (zz, rr, cnt) in enumerate(layers):
        for k in range(cnt):
            th = 2.0 * math.pi * (k + rng.uniform(-0.3, 0.3)) / cnt
            off = rr * rng.uniform(0.15, 0.78)
            c = (x + bx * 0.6 + math.cos(th) * off, y + by * 0.6 + math.sin(th) * off,
                 zz + rng.uniform(-0.09, 0.09) * H)
            # 实心内核（暗、不透明 → 撑住体积，避免树冠"空心"）+ 比旧版小一圈
            _blob(b, c, rr * rng.uniform(0.56, 0.72), "leaf_core",
                  rings=4, segs=8, seed=seed + 40.0 + li * 5 + k, jitter=0.24,
                  rz=rr * 0.58)
            # 外层 **alpha 叶卡**（大卡、多朝向 → 由 alpha 打出碎叶边）
            lm = leaf if rng.random() < 0.68 else "leaf_b"
            for q in range(rng.randint(9, 13)):
                d = _sphere_dir(rng)
                pc = Vector(c) + d * (rr * rng.uniform(0.50, 1.05))
                _leafcard(b, pc, rr * rng.uniform(0.58, 1.02), d, lm,
                          seed=seed + 40.0 + q * 1.7,
                          curl=rng.uniform(-0.30, 0.30))
    # 枝梢叶卡片（树冠外缘的稀疏感；卡放大到能显出叶簇）
    for (tp, mat_i) in tips:
        for q in range(rng.randint(4, 7)):
            d = _sphere_dir(rng)
            _leafcard(b, (tp[0] + d.x * 0.18 * M, tp[1] + d.y * 0.18 * M,
                          tp[2] + d.z * 0.18 * M),
                      crown_r * rng.uniform(0.28, 0.46), d, leaf,
                      seed=seed + 90.0 + q, curl=rng.uniform(-0.12, 0.24))
    _pad(b, x, y, crown_r * 2.0)
    return {"h": H, "crown": crown_r, "trunk": trunk_r}


def broadleaf_tall(b, x=0.0, y=0.0, z=0.0, seed=0, h=0.0, lod="full"):
    """窄冠高阔叶（山毛榉/杨）：冠幅只有 oak 的 0.6，用于林冠上层的竖向变化。"""
    r = _rng(seed)
    return broadleaf(b, x=x, y=y, z=z, seed=seed,
                     h=(h or r.uniform(10.5, 14.0)),
                     spread=r.uniform(3.0, 4.0), lod=lod)


def _limb(b, rng, p, d, ln, r, bark, leaf, depth, tips, seed, cards):
    """递归分枝：每级 2~3 叉，角度 20~48°，长度 ×0.62~0.78。"""
    p = Vector(p)
    d = Vector(d).normalized()
    p1 = p + d * ln
    r1 = r * rng.uniform(0.55, 0.68)
    _tube(b, p, p1, r, r1, bark, segs=6 if depth >= 2 else 5, jitter=0.10,
          seed=seed, droop=0.0)
    # 枝上铺叶：只在枝梢堆叶会露出"光秃的树枝 + 末端一撮绿"（首轮实拍就是如此），
    # 每条分枝沿途撒小叶卡，叶团才连成一片而不是挂在枝头。
    if cards and depth >= 1:
        for q in range(rng.randint(2, 4)):
            t = rng.uniform(0.20, 0.98)
            pc = p + (p1 - p) * t
            dd = _sphere_dir(rng)
            _leafcard(b, (pc.x + dd.x * ln * 0.18, pc.y + dd.y * ln * 0.18,
                          pc.z + dd.z * ln * 0.18),
                      max(0.26 * M, ln * rng.uniform(0.26, 0.42)), dd, leaf,
                      seed=seed + 400.0 + q, curl=rng.uniform(-0.12, 0.22))
    if depth <= 0 or ln < 0.28 * M:
        tips.append((tuple(p1), 0))
        return
    for i in range(rng.randint(2, 3)):
        a1 = rng.uniform(0.0, 2.0 * math.pi)
        polar = math.radians(rng.uniform(20, 48))
        ref = Vector((0.0, 0.0, 1.0)) if abs(d.z) < 0.9 else Vector((1.0, 0.0, 0.0))
        u1 = d.cross(ref).normalized()
        u2 = d.cross(u1)
        nd = (d * math.cos(polar) +
              (u1 * math.cos(a1) + u2 * math.sin(a1)) * math.sin(polar)).normalized()
        _limb(b, rng, p1, nd, ln * rng.uniform(0.62, 0.78), r1, bark, leaf,
              depth - 1, tips, seed * 7.0 + i * 31.0, cards)


def _sphere_dir(rng):
    z = rng.uniform(-1.0, 1.0)
    t = rng.uniform(0.0, 2.0 * math.pi)
    r = math.sqrt(max(0.0, 1.0 - z * z))
    return Vector((r * math.cos(t), r * math.sin(t), z))


def _pad(b, x, y, w):
    """接地阴影：给一个与"落地体量"相称的椭圆暗斑（不是建筑那种精确接触阴影）。

    `w` 传的是冠幅/体量宽度；阴影只取 ~22%，再大就成了"铺在地上的灰毯"。
    """
    sw = min(max(22.0, w * 0.22), 1.8 * M)
    shadow(b, sw, sw * 0.78, x=x, y=y, spread=max(14.0, sw * 0.35), steps=2)


def conifer(b, x=0.0, y=0.0, z=0.0, seed=0, h=0.0, lod="full"):
    """针叶树：细直干 + 锥形层叠（每层底面下坠、边缘参差）+ 塔尖。"""
    rng = _rng(seed)
    H = h * M if h else rng.uniform(11.0, 18.0) * M
    trunk_r = H * rng.uniform(0.016, 0.024)
    bark = "bark_pine"
    leaf = "leaf_pine"
    layers = rng.randint(6, 9) if lod == "full" else 4
    z0 = z + H * rng.uniform(0.10, 0.16)
    span = H - (z0 - z) - H * 0.06
    lh = span / layers
    # 每层是一个"底面外挑、向上急收"的锥台：层与层之间留下**可见的檐唇台阶**。
    # 首轮把层高给到 1.55×lh 且顶半径 0.26~0.38×底半径，结果整棵糊成一根光滑
    # 绿瓶子（"分层"完全看不见）——唇必须由"下缘外挑 + 层间色差"两件事一起给。
    for i in range(layers):
        t = float(i) / max(1, layers - 1)
        rb = H * (0.160 - 0.138 * t) * rng.uniform(0.94, 1.06)
        rt = rb * rng.uniform(0.19, 0.29)
        zb = z0 + lh * i
        mat = leaf if i % 2 == 0 else "leaf_pine2"
        _tube(b, (x, y, zb), (x, y, zb + lh * 1.28), rb, rt, mat,
              segs=13, jitter=0.22, seed=seed + i * 5.0, droop=lh * 0.32,
              cap0=False, cap1=True)
    _tube(b, (x, y, z + 0.6), (x, y, z0 + span * 0.9), trunk_r,
          trunk_r * 0.55, bark, segs=7, jitter=0.05, seed=seed,
          floor=z + 0.5)
    # 塔尖
    _tube(b, (x, y, z0 + span * 0.88), (x, y, z + H), H * 0.030, H * 0.004,
          leaf, segs=7, jitter=0.10, seed=seed + 99.0, droop=0.0)
    # 下部枯枝（针叶林下部的"裙边"剪影）
    for i in range(rng.randint(2, 4)):
        th = rng.uniform(0.0, 2.0 * math.pi)
        zb = z + rng.uniform(0.12, 0.28) * H
        ln = H * rng.uniform(0.06, 0.12)
        d = Vector((math.cos(th), math.sin(th), -0.25)).normalized()
        _tube(b, (x, y, zb), (x + d.x * ln, y + d.y * ln, zb - ln * 0.22),
              trunk_r * 0.55, trunk_r * 0.18, "bark_dead", segs=4, jitter=0.15,
              seed=seed + 200.0 + i)
    _pad(b, x, y, H * 0.30)
    return {"h": H, "crown": H * 0.16, "trunk": trunk_r}


def dead_tree(b, x=0.0, y=0.0, z=0.0, seed=0, h=0.0, lod="full", leaves=0):
    """枯树：扭干 + 折枝。每根断枝收在**露白木的断裂口**（不是尖锥）。"""
    rng = _rng(seed)
    H = h * M if h else rng.uniform(5.5, 9.5) * M
    trunk_r = H * rng.uniform(0.048, 0.068)      # 枯树没有树冠遮丑，杆太细就是电线杆
    bark = "bark_dead"
    # 扭干：4 段，逐段偏折
    p = Vector((x, y, z + 0.6))
    d = Vector((rng.uniform(-0.12, 0.12), rng.uniform(-0.12, 0.12), 1.0)).normalized()
    segs_n = 4
    r = trunk_r
    for i in range(segs_n):
        ln = H * (0.34 - 0.05 * i) * rng.uniform(0.9, 1.1)
        p1 = p + d * ln
        _tube(b, p, p1, r, r * 0.82, bark, segs=8, jitter=0.10, seed=seed + i,
              floor=z + 0.5)
        ref = Vector((0.0, 0.0, 1.0)) if abs(d.z) < 0.9 else Vector((1.0, 0.0, 0.0))
        u1 = d.cross(ref).normalized()
        u2 = d.cross(u1)
        d = (d + (u1 * rng.uniform(-1, 1) + u2 * rng.uniform(-1, 1)) * 0.16).normalized()
        p, r = p1, r * 0.80
    # 残枝（5~9 根；每根两段带折角 → 扭曲感；末端是大断口而不是尖锥）
    nb = rng.randint(5, 9)
    for i in range(nb):
        t = rng.uniform(0.30, 0.98)
        bp = Vector((x, y, z)) + Vector((0, 0, t * H * 0.92))
        th = rng.uniform(0.0, 2.0 * math.pi)
        elev = math.radians(rng.uniform(38, 76))
        bd = Vector((math.sin(elev) * math.cos(th), math.sin(elev) * math.sin(th),
                     math.cos(elev)))
        ln = H * rng.uniform(0.16, 0.40)
        br = trunk_r * rng.uniform(0.32, 0.55)
        bp1 = bp + bd * ln
        _tube(b, bp, bp1, br, br * 0.62, bark, segs=6, jitter=0.14, seed=seed + 30.0 + i)
        ref = Vector((0.0, 0.0, 1.0)) if abs(bd.z) < 0.9 else Vector((1.0, 0.0, 0.0))
        u1 = bd.cross(ref).normalized()
        u2 = bd.cross(u1)
        bd2 = (bd + (u1 * rng.uniform(-1, 1) + u2 * rng.uniform(-1, 1)) * 0.34).normalized()
        bp2 = bp1 + bd2 * (ln * rng.uniform(0.35, 0.62))
        _tube(b, bp1, bp2, br * 0.62, br * 0.42, bark, segs=5, jitter=0.16,
              seed=seed + 45.0 + i)
        _tube(b, bp2, bp2 + bd2 * (br * 1.5), br * 0.42, br * 0.26, "wood_break",
              segs=5, jitter=0.30, seed=seed + 60.0 + i)
    _tube(b, p, p + d * (trunk_r * 1.2), r, r * 0.5, "wood_break",
          segs=6, jitter=0.3, seed=seed + 88.0)
    if leaves and lod == "full":
        for i in range(leaves):
            th = rng.uniform(0.0, 2.0 * math.pi)
            d2 = _sphere_dir(rng)
            c = (x + math.cos(th) * H * 0.12, y + math.sin(th) * H * 0.12,
                 z + H * rng.uniform(0.65, 0.95))
            for q in range(4):
                dd = _sphere_dir(rng)
                _leafcard(b, (c[0] + dd.x * H * 0.06, c[1] + dd.y * H * 0.06,
                              c[2] + dd.z * H * 0.06),
                          H * 0.14, dd, "leaf_dead", seed=seed + q * 3.1,
                          curl=rng.uniform(-0.15, 0.2))
    _pad(b, x, y, H * 0.16)
    return {"h": H, "crown": H * 0.05, "trunk": trunk_r}


def stump(b, x=0.0, y=0.0, z=0.0, seed=0, h=0.0, r=0.0):
    """树桩：断干 + **年轮端面**（同心暗圈 + 放射干裂）+ 根部放脚。"""
    rng = _rng(seed)
    H = h * M if h else rng.uniform(0.62, 1.05) * M
    R = r * M if r else rng.uniform(0.42, 0.62) * M
    _tube(b, (x, y, z + 0.6), (x, y, z + H), R, R * rng.uniform(0.86, 0.98),
          "bark_dead", segs=10, jitter=0.09, seed=seed, floor=z + 0.5)
    # 年轮端面：同轴薄板，半径递减（低多边形圆盘）
    n_ring = rng.randint(3, 5)
    for i in range(n_ring):
        fr = 1.0 - 0.22 * i
        b.cylinder((x, y, z + H + 0.35 + i * 0.30), R * fr * 0.95, 0.8,
                   "wood_cut" if i == 0 else "wood_ring",
                   segments=16, axis="Z", taper=1.0)
    # 放射干裂
    for i in range(rng.randint(2, 4)):
        th = rng.uniform(0.0, 2.0 * math.pi)
        ln = R * rng.uniform(0.55, 0.95)
        b.box((ln, R * 0.10, 0.9), (x + math.cos(th) * ln * 0.45,
                                    y + math.sin(th) * ln * 0.45, z + H + 1.3),
              "wood_ring", rot=(0.0, 0.0, th))
    # 断口木刺：3~5 根向上的劈裂尖（树桩读作"断"而不是"桶"的关键）
    for i in range(rng.randint(3, 5)):
        th = rng.uniform(-2.9, 2.9)
        ln = R * rng.uniform(0.35, 0.85)
        rb = R * rng.uniform(0.10, 0.18)
        p0 = (x + math.cos(th) * R * 0.72, y + math.sin(th) * R * 0.72, z + H - 1.0)
        p1 = (p0[0] + math.cos(th) * ln * 0.35, p0[1] + math.sin(th) * ln * 0.35,
              z + H + ln)
        _tube(b, p0, p1, rb, rb * 0.16, "wood_break", segs=4, jitter=0.30,
              seed=seed + 300.0 + i)
    # 根部放脚
    for i in range(rng.randint(3, 5)):
        th = 2.0 * math.pi * (i + rng.uniform(-0.2, 0.2)) / 4.0
        ro = R * rng.uniform(1.8, 2.6)
        _tube(b, (x + math.cos(th) * ro, y + math.sin(th) * ro, z),
              (x, y, z + R * 0.9), R * 0.26, R * 0.52, "bark_dead",
              segs=5, jitter=0.14, seed=seed + 5.0 + i, floor=z + 0.5)
    _pad(b, x, y, R * 3.0)
    return {"h": H, "crown": R, "trunk": R}


# ============================================================ 地被 / 灌丛

def bush(b, x=0.0, y=0.0, z=0.0, seed=0, r=0.0, lod="full"):
    """灌木丛：2~5 个叶球聚簇 + 细枝 + 稀疏叶卡片（低矮团块）。"""
    rng = _rng(seed)
    R = r * M if r else rng.uniform(0.55, 1.05) * M
    n = rng.randint(2, 5)
    mat = "leaf_a" if rng.random() < 0.7 else "leaf_b"
    _tube(b, (x, y, z), (x + rng.uniform(-0.1, 0.1) * R, y + rng.uniform(-0.1, 0.1) * R,
                         z + R * 0.9), R * 0.07, R * 0.05, "bark_dead",
          segs=5, jitter=0.2, seed=seed)
    for i in range(n):
        th = 2.0 * math.pi * (i + rng.uniform(-0.3, 0.3)) / n
        off = R * rng.uniform(0.15, 0.65)
        rr = R * rng.uniform(0.48, 0.80)
        c = (x + math.cos(th) * off, y + math.sin(th) * off,
             z + rr * rng.uniform(0.55, 0.85))
        # 实心内核（暗）+ 外层 alpha 叶卡（同阔叶树冠的做法）
        _blob(b, c, rr * rng.uniform(0.60, 0.78), "leaf_core", rings=4, segs=8,
              seed=seed + 10.0 + i, jitter=0.28, rz=rr * 0.66, floor=z + 0.5)
        if lod == "full":
            for q in range(rng.randint(4, 7)):
                d = _sphere_dir(rng)
                if d.z < -0.25:              # 贴地那圈不铺叶卡（会被地面吃掉/扎地）
                    continue
                _leafcard(b, (c[0] + d.x * rr * 0.85, c[1] + d.y * rr * 0.85,
                              c[2] + d.z * rr * 0.85),
                          rr * rng.uniform(0.55, 0.90), d, mat, seed=seed + q * 2.3,
                          curl=rng.uniform(-0.25, 0.30))
    # 基部杂草
    if lod == "full":
        for i in range(rng.randint(2, 4)):
            th = rng.uniform(0.0, 2.0 * math.pi)
            _reed_card(b, x + math.cos(th) * R * 1.05, y + math.sin(th) * R * 1.05, z,
                       R * 0.55, R * 0.42, rng.uniform(0.0, 2.0 * math.pi), "grass",
                       seed + 300.0 + i, sample=1.0)
    _pad(b, x, y, R * 1.8)
    return {"h": R * 1.7, "crown": R, "trunk": R * 0.1}


def _reed_card(b, x, y, z, w, h, yaw, mat, seed, sample=1.0):
    """一张竖直草/芦苇面片（贴 grass_tuft alpha 材质）。

    UV 是**手动压缩**的：grass_tuft 用 `frc(v)` 取格内高度，若按世界坐标给 UV，
    2 m 高的芦苇会得到 5 个上下堆叠的草簇（叶片重复、读作"叠罗汉"）。所以把
    V 压到"一张面片 = 一格草簇"，U 也按 sample 压缩到"十几根粗草茎"。
    """
    c = math.cos(yaw)
    s = math.sin(yaw)
    hw = w * 0.5
    u_scale = 0.42 * sample                      # 1 UV tile = 0.42 m 的 U 向压缩
    v_dir = Vector((0.0, 0.0, (0.42 / max(1e-6, h))))
    u_dir = Vector((c * u_scale, s * u_scale, 0.0))
    p0 = Vector((x - c * hw, y - s * hw, z))
    p1 = Vector((x + c * hw, y + s * hw, z))
    pts = [p0, p1, p1 + Vector((0.0, 0.0, h)), p0 + Vector((0.0, 0.0, h))]
    b.poly(pts, mat, outward=(s, -c, 0.0), uv_axes=(u_dir, v_dir))
    # 交叉第二片（避免侧看是一条线）
    yaw2 = yaw + math.pi * 0.5
    c2, s2 = math.cos(yaw2), math.sin(yaw2)
    q0 = Vector((x - c2 * hw, y - s2 * hw, z))
    q1 = Vector((x + c2 * hw, y + s2 * hw, z))
    pts2 = [q0, q1, q1 + Vector((0.0, 0.0, h)), q0 + Vector((0.0, 0.0, h))]
    b.poly(pts2, mat, outward=(s2, -c2, 0.0),
           uv_axes=(Vector((c2 * u_scale, s2 * u_scale, 0.0)), v_dir))


def reeds(b, x=0.0, y=0.0, z=0.0, seed=0, h=0.0, w=0.0, n=0, mat="reed"):
    """芦苇/高草簇：8~18 张交叉草片，越靠中心越高（丛生感）。"""
    rng = _rng(seed)
    H = h * M if h else rng.uniform(1.9, 3.0) * M
    W = w * M if w else rng.uniform(1.6, 3.2) * M
    n = n or rng.randint(9, 16)
    for i in range(n):
        th = rng.uniform(0.0, 2.0 * math.pi)
        dd = rng.uniform(0.0, 0.5) * W
        cz = 1.0 - (dd / max(1e-6, W * 0.5)) * 0.45
        _reed_card(b, x + math.cos(th) * dd, y + math.sin(th) * dd, z,
                   W * rng.uniform(0.22, 0.40), H * cz * rng.uniform(0.72, 1.0),
                   rng.uniform(0.0, math.pi), mat, seed + i, sample=rng.uniform(0.7, 1.3))
    # 竖向茎：给草片团一个"挺立"的骨架（只有草片的芦苇在游戏尺寸下是一坨模糊绿）
    for i in range(rng.randint(4, 7)):
        th = rng.uniform(0.0, 2.0 * math.pi)
        dd = rng.uniform(0.0, 0.42) * W
        hh = H * rng.uniform(0.72, 1.02)
        lean = rng.uniform(-0.06, 0.06) * hh
        _tube(b, (x + math.cos(th) * dd, y + math.sin(th) * dd, z + 0.5),
              (x + math.cos(th) * dd + lean, y + math.sin(th) * dd + lean * 0.5,
               z + hh), W * rng.uniform(0.010, 0.018), W * 0.004, "leaf_b",
              segs=4, jitter=0.12, seed=seed + 500.0 + i)
    # 根部土堆
    _rock(b, x, y, z, W * 0.13, "dirt", seed=seed + 77.0, squash=0.28, rings=2,
          segs=7, bury=0.45)
    return {"h": H, "crown": W * 0.5, "trunk": W * 0.1}


def grass_clump(b, x=0.0, y=0.0, z=0.0, seed=0, h=0.0, w=0.0, mat="grass"):
    """矮草丛（补地面留白用）。"""
    return reeds(b, x=x, y=y, z=z, seed=seed, h=(h or _rng(seed).uniform(0.35, 0.7)),
                 w=(w or _rng(seed + 1).uniform(0.9, 1.8)), mat=mat,
                 n=_rng(seed + 2).randint(5, 9))


def mushrooms(b, x=0.0, y=0.0, z=0.0, seed=0, n=0, log=False):
    """蘑菇群：毒蝇伞（红伞白点）+ 褐伞 + 小伞；`log=True` 落在腐木上（腐木簇生）。"""
    rng = _rng(seed)
    n = n or rng.randint(5, 11)
    ybase = z
    if log:
        ln = rng.uniform(1.6, 2.8) * M
        r = rng.uniform(0.10, 0.16) * M
        yaw = rng.uniform(0.0, 0.6)
        d = Vector((math.cos(yaw), math.sin(yaw), 0.0))
        p0 = Vector((x, y, ybase + r * 0.85)) - d * ln * 0.5
        p1 = p0 + d * ln
        _tube(b, p0, p1, r, r * 0.92, "bark_dead", segs=8, jitter=0.08, seed=seed,
              floor=z + 0.5)
        # 腐木苔
        for i in range(3):
            t = rng.uniform(0.15, 0.85)
            c = p0 + d * (ln * t)
            _blob(b, (c.x, c.y, c.z + r * 0.75), r * rng.uniform(0.5, 0.9), "moss",
                  rings=3, segs=7, seed=seed + i, jitter=0.3, rz=r * 0.3)
        ybase = ybase + r * 1.6
    for i in range(n):
        th = rng.uniform(0.0, 2.0 * math.pi)
        dd = rng.uniform(0.0, 0.45) * M
        fly = rng.random() < 0.45
        cap_mat = "mush_cap" if fly else ("mush_brown" if rng.random() < 0.6 else "mush_stalk")
        st_r = rng.uniform(0.022, 0.040) * M
        st_h = rng.uniform(0.09, 0.24) * M * (1.35 if fly else 1.0)
        c_r = st_r * rng.uniform(2.8, 4.4) * (1.45 if fly else 1.0)
        px = x + math.cos(th) * dd
        py = y + math.sin(th) * dd
        pz = ybase + rng.uniform(0.0, 0.03) * M
        tilt = rng.uniform(-0.12, 0.12)
        _tube(b, (px, py, pz), (px + tilt * st_h, py + tilt * 0.6 * st_h, pz + st_h),
              st_r, st_r * 0.72, "mush_stalk", segs=6, jitter=0.08, seed=seed + i)
        c = (px + tilt * st_h, py + tilt * 0.6 * st_h, pz + st_h)
        _blob(b, (c[0], c[1], c[2] + c_r * 0.28), c_r, cap_mat, rings=3, segs=9,
              seed=seed + 40.0 + i, jitter=0.16, rz=c_r * 0.52)
        if fly:
            for q in range(rng.randint(2, 5)):
                a = rng.uniform(0.0, 2.0 * math.pi)
                rr = c_r * rng.uniform(0.30, 0.72)
                _blob(b, (c[0] + math.cos(a) * rr, c[1] + math.sin(a) * rr,
                          c[2] + c_r * 0.34),
                      c_r * rng.uniform(0.09, 0.15), "mush_dot", rings=2, segs=6,
                      seed=seed + 60.0 + q, jitter=0.2, rz=c_r * 0.05)
    return {"h": 0.3 * M, "crown": 0.5 * M, "trunk": 0.05 * M}


# ============================================================ 矿物 / 岩石

def _ore_body(b, x, y, z, r, rng, seed, rock_mat="rock", squash=0.70):
    """矿体底盘：2~4 块岩石咬合，给矿石一个"从山体里露出来"的载体。"""
    n = rng.randint(2, 4)
    _rock(b, x, y, z, r, rock_mat, seed=seed, squash=squash, n=n, spread=0.62,
          bury=0.28)


def iron_outcrop(b, x=0.0, y=0.0, z=0.0, seed=0, w=0.0, h=0.0):
    """铁矿脉露头：岩体 + 嵌深色铁块（高 wear → 锈红氧化）+ 锈痕下淌 + 伴生碎石。"""
    rng = _rng(seed)
    W = w * M if w else rng.uniform(1.6, 2.8) * M
    H = h * M if h else rng.uniform(1.1, 2.2) * M
    rock_mat = "rock_dark" if rng.random() < 0.6 else "rock"
    _ore_body(b, x, y, z, W * 0.5, rng, seed, rock_mat, squash=H / (W * 0.5) * 0.9)
    # 铁块：从岩体表面往外顶出的棱角块
    for i in range(rng.randint(6, 10)):
        th = rng.uniform(-2.55, -0.59)          # 前半球（y<0 一侧）
        rr = W * rng.uniform(0.22, 0.50)
        zz = z + H * rng.uniform(0.42, 0.95)
        _chunk(b, (x + math.cos(th) * rr, y + math.sin(th) * rr, zz),
               W * rng.uniform(0.20, 0.36), "ore_iron", rng)
    # 锈痕（从铁块下淌的窄条）
    for i in range(rng.randint(5, 8)):
        th = rng.uniform(-2.55, -0.59)
        rr = W * rng.uniform(0.24, 0.52)
        zz = z + H * rng.uniform(0.35, 0.90)
        _chunk(b, (x + math.cos(th) * rr, y + math.sin(th) * rr, zz),
               W * rng.uniform(0.14, 0.26), "rust", rng)
    _pebbles(b, x, y, z, W * 0.5, rng.randint(5, 9), "rock_dark", seed=seed + 5.0,
             spread=0.7)
    # 散落铁矿石过渡
    for i in range(rng.randint(3, 6)):
        th = rng.uniform(0.0, 2.0 * math.pi)
        dd = W * rng.uniform(0.6, 1.4)
        sz = W * rng.uniform(0.05, 0.11)
        _chunk(b, (x + math.cos(th) * dd, y + math.sin(th) * dd, z + sz * 0.5),
               sz, "ore_iron", rng, flat=True)
    _pad(b, x, y, W * 1.3)
    return {"h": H, "crown": W * 0.5, "trunk": W * 0.3}


def copper_vein(b, x=0.0, y=0.0, z=0.0, seed=0, w=0.0, h=0.0):
    """铜矿脉：岩体 + 青绿锈纹（slate_roof 染绿——**缺 ore_copper key**）+ 孔雀石斑。"""
    rng = _rng(seed)
    W = w * M if w else rng.uniform(1.6, 2.8) * M
    H = h * M if h else rng.uniform(1.0, 2.0) * M
    _ore_body(b, x, y, z, W * 0.5, rng, seed, "rock", squash=H / (W * 0.5) * 0.9)
    for i in range(rng.randint(7, 11)):
        th = rng.uniform(-2.55, -0.59)
        rr = W * rng.uniform(0.20, 0.48)
        zz = z + H * rng.uniform(0.40, 0.95)
        _blob(b, (x + math.cos(th) * rr, y + math.sin(th) * rr, zz),
              W * rng.uniform(0.10, 0.20), "ore_copper", rings=3, segs=7,
              seed=seed + i, jitter=0.28, rz=W * 0.09)
    for i in range(rng.randint(4, 7)):
        th = rng.uniform(-2.55, -0.59)
        rr = W * rng.uniform(0.28, 0.52)
        _chunk(b, (x + math.cos(th) * rr, y + math.sin(th) * rr,
                   z + H * rng.uniform(0.35, 0.85)), W * rng.uniform(0.11, 0.19),
               "ore_copper", rng)
    _pebbles(b, x, y, z, W * 0.5, rng.randint(5, 8), "rock", seed=seed + 6.0, spread=0.7)
    _pad(b, x, y, W * 1.3)
    return {"h": H, "crown": W * 0.5, "trunk": W * 0.3}


def gold_vein(b, x=0.0, y=0.0, z=0.0, seed=0, w=0.0, h=0.0):
    """金矿脉：石英岩体（白）+ 石英脉（白stone）+ 裸金点（iron 染金，低 wear 保持金属光）。"""
    rng = _rng(seed)
    W = w * M if w else rng.uniform(1.6, 2.6) * M
    H = h * M if h else rng.uniform(1.1, 2.0) * M
    # 母岩用**中灰** `rock`（不用 rock_light）：白石头上的金点看不见，
    # 暗母岩才衬得出裸金的黄（四轮实拍教训）。
    _ore_body(b, x, y, z, W * 0.5, rng, seed, "rock", squash=H / (W * 0.5) * 0.9)
    # 石英脉（近垂直的白条）
    for i in range(rng.randint(2, 4)):
        th = rng.uniform(-2.55, -0.59)
        rr = W * rng.uniform(0.18, 0.44)
        _chunk(b, (x + math.cos(th) * rr, y + math.sin(th) * rr,
                   z + H * rng.uniform(0.35, 0.9)),
               W * rng.uniform(0.16, 0.28), "quartz", rng)
    # 裸金点（放大 + 加密 + 往外顶：15px 的小点在游戏尺寸下读成"石头上的脏点"）
    for i in range(rng.randint(10, 16)):
        th = rng.uniform(-2.55, -0.59)
        rr = W * rng.uniform(0.30, 0.62)
        zz = z + H * rng.uniform(0.32, 0.95)
        _blob(b, (x + math.cos(th) * rr, y + math.sin(th) * rr, zz),
              W * rng.uniform(0.18, 0.30), "ore_gold", rings=2, segs=6,
              seed=seed + i, jitter=0.3, rz=W * 0.14)
    # 大块金脉板（3 块；给"一眼看到黄"的粗读层）
    for i in range(3):
        th = rng.uniform(-2.45, -0.69)
        rr = W * rng.uniform(0.30, 0.54)
        _chunk(b, (x + math.cos(th) * rr, y + math.sin(th) * rr,
                   z + H * rng.uniform(0.45, 0.90)), W * rng.uniform(0.26, 0.40),
               "ore_gold", rng)
    _pebbles(b, x, y, z, W * 0.5, rng.randint(5, 9), "rock_light", seed=seed + 9.0,
             spread=0.7)
    _pad(b, x, y, W * 1.3)
    return {"h": H, "crown": W * 0.5, "trunk": W * 0.3}


def crystal_cluster(b, x=0.0, y=0.0, z=0.0, seed=0, h=0.0, n=0):
    """水晶簇：岩基 + 尖柱群（六棱柱，长短/倾角/色相各异）。

    自发光没有 key（`lamp` 是暖橙），冷蓝晶柱只能靠 glass_win 染蓝 —— 缺
    `crystal` 自发光 key，见汇报。
    """
    rng = _rng(seed)
    H = h * M if h else rng.uniform(1.1, 2.6) * M
    n = n or rng.randint(5, 11)
    _rock(b, x, y, z, H * 0.38, "rock_mossy" if rng.random() < 0.4 else "rock",
          seed=seed, squash=0.38, n=2, spread=0.6, bury=0.45)
    for i in range(n):
        th = rng.uniform(0.0, 2.0 * math.pi)
        dd = rng.uniform(0.0, 0.34) * H
        hl = H * rng.uniform(0.35, 1.0)
        rr = hl * rng.uniform(0.15, 0.26)
        tilt = rng.uniform(-0.42, 0.42)
        base = Vector((x + math.cos(th) * dd, y + math.sin(th) * dd, z + H * 0.10))
        tip = base + Vector((tilt * rng.uniform(0.4, 1.0), tilt * rng.uniform(-1.0, 1.0),
                             hl))
        mat = "crystal_a" if rng.random() < 0.6 else "crystal_b"
        _tube(b, base, tip, rr, rr * rng.uniform(0.18, 0.42), mat, segs=6,
              jitter=0.06, seed=seed + i)
        # 尖端小晶面
        _tube(b, tip, tip + (tip - base).normalized() * (hl * 0.16), rr * 0.30,
              rr * 0.02, mat, segs=6, jitter=0.05, seed=seed + 50.0 + i)
    _pebbles(b, x, y, z, H * 0.30, rng.randint(3, 6), "rock", seed=seed + 7.0, spread=1.2)
    _pad(b, x, y, H * 1.1)
    return {"h": H, "crown": H * 0.4, "trunk": H * 0.2}


def boulder(b, x=0.0, y=0.0, z=0.0, seed=0, r=0.0, n=0):
    """巨岩/巨石群：1~3 块大岩咬合 + 苔斑 + 根部碎石。"""
    rng = _rng(seed)
    R = r * M if r else rng.uniform(1.0, 2.6) * M
    n = n or rng.randint(1, 3)
    mat = "rock" if rng.random() < 0.5 else "rock_dark"
    _rock(b, x, y, z, R, mat, seed=seed, squash=rng.uniform(0.62, 0.86), n=n,
          spread=0.75, bury=0.30, rings=3, segs=8)
    # 苔斑（顶面）
    for i in range(rng.randint(2, 4)):
        th = rng.uniform(0.0, 2.0 * math.pi)
        dd = R * rng.uniform(0.1, 0.6)
        _blob(b, (x + math.cos(th) * dd, y + math.sin(th) * dd,
                  z + R * rng.uniform(0.55, 0.85)),
              R * rng.uniform(0.18, 0.34), "moss", rings=2, segs=7, seed=seed + i,
              jitter=0.3, rz=R * 0.06)
    _pebbles(b, x, y, z, R * 0.45, rng.randint(3, 7), mat, seed=seed + 11.0, spread=1.3)
    _pad(b, x, y, R * 2.6)
    return {"h": R * 1.5, "crown": R, "trunk": R}


def rubble(b, x=0.0, y=0.0, z=0.0, seed=0, w=0.0, n=0):
    """碎石堆：大小混杂的棱角块 + 少量土面（矿区/崖脚过渡）。"""
    rng = _rng(seed)
    W = w * M if w else rng.uniform(1.4, 3.0) * M
    n = n or rng.randint(10, 20)
    for i in range(n):
        th = rng.uniform(0.0, 2.0 * math.pi)
        dd = rng.uniform(0.0, 0.5) * W
        rr = W * rng.uniform(0.05, 0.17)
        zz = z + rr * rng.uniform(0.2, 0.7)
        mat = "cut_stone" if rng.random() < 0.6 else "rock"
        _rock(b, x + math.cos(th) * dd, y + math.sin(th) * dd, zz, rr, mat,
              seed=seed + 3.0 * i, squash=0.66, rings=2, segs=6, bury=0.30,
              floor=z + 0.5)
    _pad(b, x, y, W * 1.1)
    return {"h": W * 0.3, "crown": W * 0.5, "trunk": W * 0.4}


def ore_band(b, x=0.0, y=0.0, z=0.0, seed=0, ln=0.0, angle=0.0, ore="iron"):
    """地表矿脉带：沿走向的**低矮岩脊 + 散落矿石 + 两侧碎石过渡**。

    这是"从岩体到荒地的过渡"的几何本体：中心密（矿石 + 岩脊）、两侧疏
    （碎石 → 单块石 → 无）。`field_dist.py` 在场景级复现同一节奏。
    """
    rng = _rng(seed)
    L = ln * M if ln else rng.uniform(6.0, 12.0) * M
    ca, sa = math.cos(angle), math.sin(angle)
    n_out = max(2, int(L / (2.2 * M)))
    chunk_mat = {"iron": "ore_iron", "copper": "ore_copper",
                 "gold": "ore_gold"}[ore]
    for i in range(n_out):
        t = (i + 0.5) / n_out
        px = x + ca * (t - 0.5) * L + rng.uniform(-0.4, 0.4) * M
        py = y + sa * (t - 0.5) * L + rng.uniform(-0.4, 0.4) * M
        if i % 2 == 0:
            rock_mat = "rock_dark" if ore == "iron" else "rock"
            _rock(b, px, py, z, rng.uniform(0.35, 0.75) * M, rock_mat,
                  seed=seed + i, squash=0.55, n=2, spread=0.7, bury=0.42)
        for q in range(rng.randint(3, 6)):
            ox = px + rng.uniform(-1.1, 1.1) * M
            oy = py + rng.uniform(-1.1, 1.1) * M
            sz = rng.uniform(0.08, 0.20) * M
            _chunk(b, (ox, oy, z + sz * 0.5), sz, chunk_mat, rng, flat=True)
    # 两侧碎石过渡（带外 0.6~2.2 m）
    for side in (-1.0, 1.0):
        for i in range(int(L / (1.8 * M))):
            t = rng.uniform(0.0, 1.0)
            off = rng.uniform(0.55, 2.2) * M * side
            px = x + ca * (t - 0.5) * L - sa * off
            py = y + sa * (t - 0.5) * L + ca * off
            if rng.random() < 0.55:
                _rock(b, px, py, z, rng.uniform(0.07, 0.22) * M, "rock",
                      seed=seed + 100.0 + i + side * 7, squash=0.6, rings=2, segs=6,
                      bury=0.35)
            else:
                sz2 = rng.uniform(0.06, 0.14) * M
                _chunk(b, (px, py, z + sz2 * 0.5), sz2,
                       chunk_mat if rng.random() < 0.4 else "rock", rng, flat=True)
    _pad(b, x, y, L)
    return {"h": 0.8 * M, "crown": L * 0.5, "trunk": L}


# ============================================================ 注册表

TABLE = {
    "broadleaf": broadleaf, "broadleaf_tall": broadleaf_tall,
    "conifer": conifer, "dead_tree": dead_tree, "stump": stump,
    "bush": bush, "reeds": reeds, "grass_clump": grass_clump,
    "mushrooms": mushrooms,
    "iron_outcrop": iron_outcrop, "copper_vein": copper_vein,
    "gold_vein": gold_vein, "crystal_cluster": crystal_cluster,
    "boulder": boulder, "rubble": rubble, "ore_band": ore_band,
}

#: 名义占位尺寸（米）：(宽, 高, 落地半径)。分布排布 / strip 站位用，宁可略宽。
NOMINAL = {
    "broadleaf": (9.0, 10.5, 3.6), "broadleaf_tall": (6.0, 12.5, 2.4),
    "conifer": (4.2, 15.0, 2.1), "dead_tree": (5.0, 7.5, 1.2),
    "stump": (1.0, 0.8, 0.5), "bush": (2.2, 1.6, 1.1),
    "reeds": (3.0, 2.1, 1.5), "grass_clump": (1.8, 0.6, 0.9),
    "mushrooms": (1.2, 0.32, 0.6),
    "iron_outcrop": (3.0, 1.9, 1.5), "copper_vein": (2.6, 1.6, 1.3),
    "gold_vein": (2.0, 1.2, 1.0), "crystal_cluster": (1.6, 1.7, 0.8),
    "boulder": (4.0, 2.6, 2.6), "rubble": (2.6, 0.6, 1.3),
    "ore_band": (10.0, 0.9, 5.0),
}

#: 群系 / 分布角色 → 树种权重（field_dist 用；放这里是为了"树与分布"同文件对齐）
FOREST_MIX = {
    "broadleaf": {"broadleaf": 0.52, "broadleaf_tall": 0.16, "conifer": 0.18,
                  "dead_tree": 0.05, "stump": 0.04, "bush": 0.05},
    "conifer": {"conifer": 0.64, "broadleaf": 0.16, "broadleaf_tall": 0.06,
                "dead_tree": 0.06, "stump": 0.04, "bush": 0.04},
    "mixed": {"broadleaf": 0.40, "broadleaf_tall": 0.12, "conifer": 0.32,
              "dead_tree": 0.05, "stump": 0.04, "bush": 0.07},
    "scrub": {"bush": 0.50, "grass_clump": 0.18, "dead_tree": 0.12,
              "stump": 0.06, "boulder": 0.08, "rubble": 0.06},
}


#: 支持 `lod`（"full"/"simple"）的 builders；其余类型 `place()` 会自动丢掉该参数
LOD_KINDS = {"broadleaf", "broadleaf_tall", "conifer", "dead_tree", "bush"}


def place(b, kind, x=0.0, y=0.0, z=0.0, seed=0, scale=1.0, lod="full", **kw):
    """把一件自然物写进 Builder（统一入口；scale 只作用于 x/y/z 之外的尺寸）。"""
    fn = TABLE[kind]
    p = dict(kw)
    for k in ("h", "w", "r", "spread", "ln", "n"):
        if k in p and p[k] and scale != 1.0:
            p[k] = p[k] * scale
    p.setdefault("seed", int(seed))
    if kind in LOD_KINDS:
        p["lod"] = lod
    return fn(b, x=x, y=y, z=z, **p)


def footprint(kind, scale=1.0):
    """落地半径（单位），供分布排布做最小间距。"""
    w, h, r = NOMINAL.get(kind, (2.0, 1.5, 1.0))
    return r * M * scale


def height(kind, scale=1.0):
    w, h, r = NOMINAL.get(kind, (2.0, 1.5, 1.0))
    return h * M * scale


install_materials()


# ============================================================ 自检

def _selftest():
    import sys
    print("nature.py 自检：%d 类自然物" % len(TABLE))
    rows = []
    for kind in sorted(TABLE):
        b = B.Builder("t_" + kind)
        info = place(b, kind, x=0.0, y=0.0, z=0.0, seed=17)
        ob = b.to_object()
        mx = B.measure(ob)
        pts = B.shape_points(ob, skip_ground=True)
        hmin = min(p.z for p in pts)
        rows.append((kind, mx["x"][1] - mx["x"][0], mx["z"][1] - mx["z"][0], hmin))
        bpy.data.objects.remove(ob, do_unlink=True)
    print("%-16s %8s %8s %8s  (宽 / 高 / 最低 z，单位)" % ("kind", "w", "h", "zmin"))
    for (k, w, h, zmin) in rows:
        flag = "OK" if abs(zmin) < 1.0 else ("!! 离地 %.2f" % zmin)
        print("%-16s %8.1f %8.1f %8.2f  %s" % (k, w, h, zmin, flag))
    return rows


if __name__ == "__main__":
    _selftest()
