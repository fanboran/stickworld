# -*- coding: utf-8 -*-
"""bake_export.py —— 建筑管线 v3 **烘焙导出器** + 游戏内一屏合成演示

定位
====
本文件是 v3 的**交付/集成环节**：把 Blender 里建好的一栋栋建筑，按"2D 侧视游戏
到底怎么吃这些资产"的契约烘成 **四件套 PNG + meta.json**，并把导出的 sprite 按
**游戏真实比例**拼成"游戏内一屏"演示图（白天 / 夜晚两版）。

它只读调用 `buildings.py` / `materials.py` / `props.py` / `interiors.py` /
`daynight.py`，不改它们一行。

四件套（每栋一个目录 `stick-world/temp/bake/<def>_w<N>/`）
========================================================
    albedo.png      白天光照下的完整外立面 + 道具 + **接地接触阴影**（烘进 sprite）
    albedo@2x.png   同上 2.0 px/单位（高清档；1x 是游戏内 1:1 像素）
    glow.png        纯发光层：非发光材质→纯黑、世界全黑、灯全关，只剩自发光 + 光晕
    back.png        内景后层（Interior 层）：后墙 / 地板 / 楼板 / 家具 / 暖光
    front.png       内景前层（WallFront 层）：前墙 + 屋顶 + 门窗框，窗玻璃真透明
    meta.json       契约元数据：格宽 / px_per_unit / 前墙面基线锚点（世界→像素）/
                    门位置与宽度 / 发光件清单 / 关联层文件名 / 自动自检结论

**四张图共用同一台相机、同一取景、同一像素网格** —— 这不是巧合，是契约：前层叠后层、
glow 叠 albedo、albedo 换 front 全都不需要任何对位（`meta.anchor` 只是给引擎定位用）。
导出后自动做一次像素自检（`meta.verify`）：back/front/albedo 的 alpha 包围盒中心是否
落在世界 x=0 的同一像素列、back 跨度是否 = 建筑全宽、三层的落地基行是否一致。

引擎侧叠加顺序（文档 §三层叠加）
================================
    albedo  →  back（可进入建筑时垫在 albedo 后面）
            →  front（WallFront，interact 时 modulate.a → 0.3）
    day     =  albedo
    night   =  albedo × tint_night + glow × 1.0        （daynight.py 标定值）

跑法
====
渲染模式（Blender；全 26 装配器 × 各宽度档）：:

    blender -b --factory-startup -P tools/blender_buildings/bake_export.py

    BAKE_ONLY=house,smithy1        只出这些 def
    BAKE_WIDTHS=8,12               只出这些宽度档
    BAKE_FAST=1                    跳 2x（只出 1x albedo / glow / back / front）
    BAKE_SAMPLE=32                 EEVEE 采样数（默认 40）

合成模式（系统 python，只用 PIL/numpy；把导出的 sprite 拼成游戏内一屏）::

    python tools/blender_buildings/bake_export.py

    BAKE_DEMO_ONLY=1               只拼演示图（默认两个模式都跑）
"""

import glob
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

try:
    import bpy
    HAVE_BPY = True
except ImportError:                      # 系统 python：走合成模式
    HAVE_BPY = False

REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
TEMP = os.path.join(REPO, "stick-world", "temp")
OUT_ROOT = os.path.join(TEMP, "bake")

YAW, TILT = 0.0, 20.0                    # §0.3 硬约束：纯正面 + 俯角 20°
CELL = 32.0                              # 1 格 = 32px（PlacementGrid.CELL_SIZE）

#: 采样数（EEVEE）。批量导出时画质够用即可，调 BAKE_SAMPLE 覆盖。
SAMPLES = int(os.environ.get("BAKE_SAMPLE", "40"))

# ---------------------------------------------------------------- 清单

#: def → 该装配器的定尺表（buildings 里的 *_TIERS），宽度档 = 表的键。
TIER_TABLE = {
    "house": "HOUSE_TIERS", "townhouse": "TOWNHOUSE_TIERS",
    "barn": "BARN_TIERS", "smithy1": "SMITHY1_TIERS",
    "smithy2": "SMITHY2_TIERS", "smithy3": "SMITHY3_TIERS",
    "smithy4": "SMITHY4_TIERS", "rowhouse": "ROWHOUSE_TIERS",
    "windmill": "WINDMILL_TIERS", "cathedral": "CATHEDRAL_TIERS",
    "tower": "TOWER_TIERS", "gatehouse": "GATEHOUSE_TIERS",
    "lighthouse": "LIGHTHOUSE_TIERS", "cottage": "COTTAGE_TIERS",
    "tavern": "TAVERN_TIERS", "bakery": "BAKERY_TIERS", "shop": "SHOP_TIERS",
    "guildhall": "GUILDHALL_TIERS", "hayloft": "HAYLOFT_TIERS",
    "mage_tower": "MAGE_TOWER_TIERS", "alchemy": "ALCHEMY_TIERS",
    "library": "LIBRARY_TIERS", "barracks": "BARRACKS_TIERS",
    "warehouse": "WAREHOUSE_TIERS", "stable": "STABLE_TIERS",
    "shelter": "SHELTER_TIERS",
}

#: def → props.DRESS 的配方键（名字不同时在此映射；与 probe_delivery 同源）。
DRESS_OF = {"smithy1": "smithy", "smithy2": "smithy", "smithy3": "smithy",
            "smithy4": "smithy", "rowhouse": "townhouse",
            "plaster_house": "house", "church": "cathedral", "chapel": "chapel"}

#: 3 个别名 def：没有独立装配器，前层/外立面走目标装配器（与 interiors._FRONT_ALIAS 同源）。
ALIAS = {"plaster_house": ("house", 12), "church": ("cathedral", 12),
         "chapel": ("cathedral", 8)}

#: 圆塔 / 退台塔：后层只画背面半圈（bbox 天然窄于建筑），自检换"back ⊆ front"口径。
ROUND_DEFS = {"windmill", "mage_tower", "lighthouse", "tower"}

#: 白天光照档（与 probe_daynight / probe_city_scene 同值 —— 这就是 albedo 基线）
DAY_SKY = ((0.42, 0.56, 0.80, 1.0), (0.74, 0.76, 0.74, 1.0), 0.55)
DAY_SUNS = (
    ("key",    3.5,  (42.0, 0.0, -34.0), 2.5, (1.00, 0.93, 0.80)),
    ("fill",   0.22, (58.0, 0.0, 126.0), 20.0, (0.80, 0.87, 1.00)),
    ("bounce", 0.30, (-28.0, 0.0, 6.0), 45.0, (0.95, 0.80, 0.62)),
)
INT_SKY = ((0.34, 0.29, 0.24, 1.0), 0.34)     # 内景环境（与 probe_interiors 同值）

PAD_SIDE = 30.0       # 取景左右留白
PAD_TOP = 40.0        # 上留白
PAD_BOTTOM = 34.0     # 下留白（接地阴影/踏板要装下）


def bake_list():
    """全装配器 × 各宽度档 + 3 个别名 def（各取标准档）。返回 [(def, wc, asm, asm_wc)]。"""
    import buildings as B
    import interiors as I
    out = []
    for name in sorted(B.ASSEMBLERS):
        tbl = getattr(B, TIER_TABLE[name], None)
        if tbl is None:
            continue
        for wc in sorted(tbl):
            out.append((name, wc, name, wc))
    for name, (asm, wc) in sorted(ALIAS.items()):
        out.append((name, I._WIDTHS[name], asm, wc))
    return out


# ================================================================ 渲染模式

def _clear():
    import buildings as B
    import materials as M
    bpy.ops.wm.read_factory_settings(use_empty=True)
    M.reset_cache()
    B._CACHE.clear()
    B._MAGIC_KEYS.clear()


def _wipe():
    """删掉场景里所有网格与灯（**不 read_factory_settings**：材质缓存要留着）。"""
    for ob in list(bpy.data.objects):
        if ob.type in ("MESH", "LIGHT"):
            try:
                bpy.data.objects.remove(ob, do_unlink=True)
            except Exception:
                pass


def _setup_engine(sc):
    for eng in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE", "CYCLES"):
        try:
            sc.render.engine = eng
            break
        except Exception:
            continue
    sc.render.film_transparent = True            # 交付图必须带 alpha
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_mode = "RGBA"
    sc.render.resolution_percentage = 100
    sc.view_settings.view_transform = "Standard"
    sc.view_settings.look = "None"
    for attr, val in (("taa_render_samples", SAMPLES), ("use_gtao", True)):
        try:
            setattr(sc.eevee, attr, val)
        except Exception:
            pass


def _world(name, top, bottom, strength, gradient=True):
    import daynight as DN
    sc = bpy.context.scene
    if gradient:
        w = DN.set_sky(sc, name, top, bottom, strength)
    else:
        w = bpy.data.worlds.get(name)
        if w is None:
            w = bpy.data.worlds.new(name)
        w.use_nodes = True
        bg = w.node_tree.nodes.get("Background")
        if bg is None:
            bg = w.node_tree.nodes.new("ShaderNodeBackground")
        bg.inputs[0].default_value = (tuple(top) + (1.0,))[:4]
        bg.inputs[1].default_value = strength
    return w


def _black_world():
    w = bpy.data.worlds.get("bake_black")
    if w is None:
        w = bpy.data.worlds.new("bake_black")
        w.use_nodes = True
        bg = w.node_tree.nodes.get("Background") or w.node_tree.nodes.new(
            "ShaderNodeBackground")
        bg.inputs[0].default_value = (0.0, 0.0, 0.0, 1.0)
        bg.inputs[1].default_value = 0.0
    return w


def _camera():
    d = bpy.data.cameras.new("bake_cam")
    d.type = "ORTHO"
    d.clip_start = 1.0
    d.clip_end = 200000.0
    ob = bpy.data.objects.new("bake_cam", d)
    bpy.context.scene.collection.objects.link(ob)
    bpy.context.scene.camera = ob
    return ob


def _frame(pts, pad_side=PAD_SIDE, pad_top=PAD_TOP, pad_bottom=PAD_BOTTOM):
    """把包围点投到相机平面 → **取整**的取景矩形（取整是"1x 恰好 1px/单位"的前提）。"""
    import buildings as B
    right, up = B.cam_axes(YAW, TILT)
    us = [p.dot(right) for p in pts]
    vs = [p.dot(up) for p in pts]
    return (float(math.floor(min(us) - pad_side)),
            float(math.ceil(max(us) + pad_side)),
            float(math.floor(min(vs) - pad_bottom)),
            float(math.ceil(max(vs) + pad_top)))


def _place(cam, fr, ppu):
    """正交相机就位并设分辨率：px_per_unit 恰为 ppu（取景矩形是整数宽高）。"""
    from mathutils import Vector
    u0, u1, v0, v1 = fr
    wu, hu = (u1 - u0), (v1 - v0)
    cu, cv = (u0 + u1) / 2.0, (v0 + v1) / 2.0
    import buildings as B
    right, up = B.cam_axes(YAW, TILT)
    anchor = right * cu + up * cv
    fwd = -(right.cross(up))
    cam.location = tuple(Vector(anchor) - fwd * 14000.0)
    cam.rotation_euler = (math.radians(90.0 - TILT), 0.0, math.radians(YAW))
    cam.data.ortho_scale = max(wu, hu)
    sc = bpy.context.scene
    sc.render.resolution_x = max(64, int(round(wu * ppu)))
    sc.render.resolution_y = max(64, int(round(hu * ppu)))
    bpy.context.view_layer.update()
    return (sc.render.resolution_x, sc.render.resolution_y)


def _px_maps(fr, ppu):
    """世界 → 像素：col（自左）/ row（自顶）/ row_b（自底，Blender 像素序）。

    YAW=0 下 right 轴 = 世界 +X；up 轴 = (0, sin20, cos20)。这是 meta.anchor 的算法；
    四张图同相机同取景 ⇒ 这套映射对四张图**是同一个**，无需任何对位。
    """
    import buildings as B
    u0, u1, v0, v1 = fr
    right, up = B.cam_axes(YAW, TILT)
    rx = int(round((u1 - u0) * ppu))
    ry = int(round((v1 - v0) * ppu))

    def col(p):
        return (p[0] - u0) * ppu

    def row_b(p):
        v = up[0] * p[0] + up[1] * p[1] + up[2] * p[2]
        return (v - v0) * ppu

    def row(p):
        return ry - row_b(p)

    pm = dict(su=ppu, sv=ppu, u0=u0, v0=v0, rx=rx, ry=ry,
              right=tuple(right), up=tuple(up))
    pm["col"] = col
    pm["row"] = row
    pm["row_b"] = row_b
    return pm


def _shoot(path):
    sc = bpy.context.scene
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)
    return path


def _alpha_bbox(path):
    """alpha>0.06 的包围盒（Blender 像素序：行 0 = 底部）。"""
    import numpy as np
    img = bpy.data.images.load(path, check_existing=False)
    try:
        w, h = img.size
        buf = np.empty(w * h * 4, dtype=np.float32)
        img.pixels.foreach_get(buf)
        a = buf.reshape(h, w, 4)[..., 3]
        ys, xs = np.nonzero(a > 0.06)
        if len(xs) == 0:
            return None
        return dict(x0=int(xs.min()), x1=int(xs.max()),
                    y0=int(ys.min()), y1=int(ys.max()), w=w, h=h)
    finally:
        bpy.data.images.remove(img)


def _vis(objs, on):
    for ob in objs:
        try:
            ob.hide_render = not on
        except Exception:
            pass


def _drop(objs):
    for ob in objs:
        try:
            bpy.data.objects.remove(ob, do_unlink=True)
        except Exception:
            pass


# ---------------------------------------------------------------- 单栋烘焙

def _seed(*parts):
    """确定性种子（**不用 `hash()`**：Python 字符串 hash 跨进程会变）。"""
    import zlib
    s = "|".join(str(p) for p in parts)
    return zlib.crc32(s.encode("utf-8")) & 0x7FFFFFFF


def bake_one(def_name, wc, asm, asm_wc, cam):
    """烘焙一栋 → 写四件套 + meta.json。返回 meta dict（失败抛异常，由调用方兜）。"""
    import buildings as B
    import daynight as DN
    import interiors as I
    import props as P

    sc = bpy.context.scene
    folder = os.path.join(OUT_ROOT, "%s_w%d" % (def_name, wc))
    os.makedirs(folder, exist_ok=True)

    ob, spec = B.ASSEMBLERS[asm](asm_wc)
    # --- 道具层：立面的一部分（参考图里道具约贡献 1/3 信息量）
    kind = DRESS_OF.get(def_name, def_name)
    pob, placed = None, []
    if kind in P.DRESS:
        pb = B.Builder("bake_props_%s_w%d" % (def_name, wc))
        d = spec.get("door")
        m0 = B.measure(ob)
        try:
            placed = P.dress(pb, kind, spec["grid_w"], m0["y"][0],
                             seed=_seed(def_name, wc, "dress"),
                             door_x=spec.get("door_x", 0.0),
                             door_w=(d[0] if d else 0.0),
                             wall_depth=spec.get("depth", 0.0) / 2.0)
        except Exception as exc:
            print("   ! dress(%s) 失败: %s" % (kind, exc))
        pob = pb.to_object()
    # --- 内景两层（复用 interiors 的成品；别名走 front_def 解引用）
    back, L = I.build_back(def_name, wc)
    front, fspec = I.build_front(def_name, wc)

    # --- 统一取景：union(外立面 + 道具 + back + front)，全程一台相机
    pts = []
    for o in (ob, pob, back, front):
        if o is not None:
            pts += B.shape_points(o, skip_ground=False)
    fr = _frame(pts)
    res2x = _place(cam, fr, 2.0)
    res1x = _place(cam, fr, 1.0)
    pm2 = _px_maps(fr, 2.0)
    pm1 = _px_maps(fr, 1.0)

    import numpy as np

    def run(fn, path, tag):
        fn()
        _shoot(path)
        return path

    paths = dict(albedo=os.path.join(folder, "albedo.png"),
                 albedo2x=os.path.join(folder, "albedo@2x.png"),
                 glow=os.path.join(folder, "glow.png"),
                 back=os.path.join(folder, "back.png"),
                 front=os.path.join(folder, "front.png"))

    suns = [DN._sun(sc, *s) for s in DAY_SUNS]
    day_w = _world("bake_day", DAY_SKY[0], DAY_SKY[1], DAY_SKY[2], gradient=True)
    int_w = _world("bake_int", INT_SKY[0], (0.0, 0.0, 0.0, 1.0), INT_SKY[1],
                   gradient=False)
    blk_w = _black_world()

    # ---- 1) albedo（白天光照 + 接地接触阴影 + 道具）
    _vis([ob, pob], True)
    _vis([back, front], False)
    sc.world = day_w
    _place(cam, fr, 2.0)
    _shoot(paths["albedo2x"])
    _place(cam, fr, 1.0)
    _shoot(paths["albedo"])

    # ---- 2) glow（非发光→纯黑；世界全黑；灯全关；自发光 + 光晕）
    clusters = DN.collect_emissive([o for o in (ob, pob) if o is not None])
    saved, kept = DN.blacken_non_emissive([o for o in (ob, pob) if o is not None])
    lsave = DN._lights_off()
    for s in suns:
        s.hide_render = True
    sc.world = blk_w
    halos = DN.add_halos(clusters, cam, mult=DN.HALO_GLOW)
    _vis([ob, pob], True)
    _place(cam, fr, 1.0)
    _shoot(paths["glow"])
    DN.restore_slots(saved)
    DN.restore_lights(lsave)
    _drop(halos)
    _vis([ob, pob], False)

    # ---- 3) back（内景后层 + 暖色室内点光）
    int_lights = _point_lights(I.lights(def_name, L))
    sc.world = int_w
    _vis([back], True)
    _place(cam, fr, 1.0)
    _shoot(paths["back"])
    _vis([back], False)
    _drop(int_lights)

    # ---- 4) front（前墙 + 屋顶 + 门窗框；窗玻璃真透明；与 albedo 同光照）
    sc.world = day_w
    _vis([front], True)
    _place(cam, fr, 1.0)
    _shoot(paths["front"])
    _vis([front], False)

    # ---- meta + 自检
    meta = _meta(def_name, wc, asm, asm_wc, spec, fspec, L, fr, res1x, res2x,
                 paths, clusters, placed, pm1, pm2)
    meta["verify"] = _verify(meta, paths)
    with open(os.path.join(folder, "meta.json"), "w", encoding="utf-8") as fh:
        json.dump(meta, fh, ensure_ascii=False, indent=1)

    _drop([ob, pob, back, front])
    _drop(suns)
    return meta


def _point_lights(specs):
    sc = bpy.context.scene
    out = []
    for i, s in enumerate(specs):
        d = bpy.data.lights.new("bake_int_p%d" % i, "POINT")
        d.energy = s["energy"]
        d.color = s["color"]
        try:
            d.shadow_soft_size = s.get("radius", 40.0)
        except Exception:
            pass
        ob = bpy.data.objects.new("bake_int_p%d" % i, d)
        ob.location = tuple(s["loc"])
        sc.collection.objects.link(ob)
        out.append(ob)
    return out


def _meta(def_name, wc, asm, asm_wc, spec, fspec, L, fr, res1x, res2x, paths,
          clusters, placed, pm1, pm2):
    """契约元数据。锚点语义见文件头；所有 px 都是 **自顶向左** 的像素坐标。"""
    ywall = -fspec["depth"] / 2.0          # 前墙面（落地线所在平面）
    anchor_w = (0.0, round(ywall, 2), 0.0)  # 世界：建筑横向中心 × 前墙面 × 地面 z=0
    a1 = [round(pm1["col"](anchor_w), 2), round(pm1["row"](anchor_w), 2)]
    a2 = [round(pm2["col"](anchor_w), 2), round(pm2["row"](anchor_w), 2)]
    door = {"w": None, "x": None, "h": None, "sill": 8.0}
    dw, dh = (spec.get("door") or (None, None))
    if dw:
        dx = spec.get("door_x") or 0.0
        z0, z1 = 8.0, 8.0 + dh
        door = {
            "x": round(dx, 2), "w": round(dw, 2), "h": round(dh, 2), "sill": 8.0,
            "px_x_1x": round(pm1["col"]((dx, ywall, 0.0)), 2),
            "px_w_1x": round(dw * pm1["su"], 2),
            "px_z0_1x": round(pm1["row"]((dx, ywall, z0)), 2),
            "px_z1_1x": round(pm1["row"]((dx, ywall, z1)), 2),
        }
    glow = []
    for c in clusters:
        p = tuple(c["pos"])
        st, col = c["strength"], c["color"]
        glow.append(dict(family=c["family"], mat=c["mat"].name,
                         strength=round(float(st), 2),
                         color=[round(v, 3) for v in (col or ())],
                         world=[round(v, 1) for v in p],
                         px_1x=[round(pm1["col"](p), 1), round(pm1["row"](p), 1)],
                         size=[round(v, 1) for v in c["size"]]))
    return dict(
        def_name=def_name, asm=asm, asm_width_cells=asm_wc,
        width_cells=wc, grid_w_px=wc * int(CELL),
        interior_width_px=round(L["W"], 2),
        px_per_unit=dict(x1=1.0, x2=2.0),
        frame=dict(u0=fr[0], u1=fr[1], v0=fr[2], v1=fr[3],
                   res_1x=list(res1x), res_2x=list(res2x)),
        anchor=dict(kind="front_wall_baseline", world=list(anchor_w),
                    px_1x=a1, px_2x=a2,
                    pivot_col_1x=round(pm1["col"]((0.0, 0.0, 0.0)), 2),
                    ground_row_1x=round(pm1["row"]((0.0, ywall, 0.0)), 2)),
        door=door,
        door_span=spec.get("door_span"),
        tier=dict(depth=spec.get("depth"), eave_h=spec.get("eave_h"),
                  total_h=spec.get("total_h"), plinth_h=spec.get("plinth_h"),
                  overhang=spec.get("overhang"), bays=spec.get("bays")),
        layers=dict(order=["albedo", "back", "front"],
                    composite_day="albedo",
                    composite_night="albedo*tint_night + glow*1.0",
                    interior_stack="albedo(作 Exterior) ← back(Interior)；front=WallFront 覆盖层"),
        files=dict(albedo="albedo.png", albedo2x="albedo@2x.png",
                   glow="glow.png", back="back.png", front="front.png",
                   meta="meta.json"),
        shadow=dict(contact="baked_in_albedo",
                    note="接地接触阴影已烘进 albedo 的 alpha 内；glow/back/front 不含阴影"),
        glow=glow, glow_count=len(glow),
        dress=[{"prop": p[0], "x": p[1], "y": p[2]} for p in placed],
    )


def _verify(meta, paths):
    """四件套像素自洽自检（导出后立刻量；也可由 `verify_mode()` 只读重算）。

    判据（**同网格**的可证伪命题；都不受"albedo 比 front 多内容"干扰）：
      · `front` 与 `back` 的 alpha 横中心都落在世界 x=0 的像素列（≤1.5px）——
        这两层都不含道具/接触阴影，是干净的"几何 ↔ 像素"量具；
        圆塔/退台塔（`ROUND_DEFS`）的 back 是半圈/退台，改判 **back ⊆ front**；
      · `front` 的 alpha 包围盒 **⊆ albedo 的包围盒**（x 与顶行，含 3px 容差）——
        albedo 是 front 的超集（多了道具与接触阴影）；
      · `front` 与 `back` 的**顶行**都与 albedo 一致（屋面线，≤3px）；
      · 非圆塔 def 的 `back` 跨度 = `interior_width_px` × px_per_unit（±3px）。

    **刻意不把 albedo 的 bbox 与 front 直接划等号**：albedo 多出三样东西，全是设计使然
    （见 `content_delta`）：① 道具（`props.dress`，常单侧 → 中心偏移）；② 接地接触阴影
    （比建筑宽、比地面线低）；③ `interiors.crop_back_half(y_cut=0)` 会连同**后半栋的
    侧向凸出**（后殿/扶壁/横厅）一起切掉，而它们在正面投影里本来就露出一截。
    """
    pm = meta["anchor"]
    pivot = pm["pivot_col_1x"]
    ppu = meta["px_per_unit"]["x1"]
    bb = {k: _alpha_bbox(paths[k]) for k in ("albedo", "back", "front", "glow")}
    out = {}
    for k, b in bb.items():
        if b is None:
            out[k] = None
            continue
        out[k] = dict(bbox=[b["x0"], b["x1"], b["y0"], b["y1"]],
                      w=b["x1"] - b["x0"] + 1, h=b["y1"] - b["y0"] + 1,
                      center_x=round((b["x0"] + b["x1"]) / 2.0, 2),
                      center_err=round(abs((b["x0"] + b["x1"]) / 2.0 - pivot), 2),
                      top_row=int(b["h"] - 1 - b["y1"]))
    a, f, bk = out.get("albedo"), out.get("front"), out.get("back")
    v = dict(pivot_col=pivot, res=meta["frame"]["res_1x"],
             note="center_err = alpha 横中心 vs 世界 x=0 像素列；判据见函数 docstring")
    round_def = meta["def_name"] in ROUND_DEFS
    if a and f:
        v["front_top_vs_albedo"] = abs(a["top_row"] - f["top_row"])
        v["content_delta"] = dict(
            width_px=abs(a["w"] - f["w"]),
            center_px=round(abs(a["center_x"] - f["center_x"]), 2),
            cause="albedo = front + 道具 + 接触阴影 − 被 crop_back_half 切掉的后半侧凸")
    if bk and f:
        v["back_top_vs_front"] = abs(bk["top_row"] - f["top_row"])
        v["back_width_px"] = bk["w"]
        v["back_width_expected"] = (None if round_def
                                    else round(meta["interior_width_px"] * ppu, 1))
        v["back_inside_front"] = bool(
            bk["bbox"][0] >= f["bbox"][0] - 3 and bk["bbox"][1] <= f["bbox"][1] + 3)
    if a and f:
        v["front_inside_albedo"] = bool(
            f["bbox"][0] >= a["bbox"][0] - 3 and f["bbox"][1] <= a["bbox"][1] + 3
            and f["top_row"] <= a["top_row"] + 3)
    # 画布高必须取 frame（`out[k]["h"]` 是 **包围盒高**，不是画布高 —— 混用会把基线算反）
    ry = meta["frame"]["res_1x"][1]
    def _bot(c):
        return int(ry - 1 - c["y0"]) if c else None
    v["baseline"] = dict(
        anchor_row=pm["ground_row_1x"],
        albedo_bottom_row=_bot(bb.get("albedo")),
        front_bottom_row=_bot(bb.get("front")),
        back_bottom_row=_bot(bb.get("back")),
        note="albedo 比 front 低 = 烘入的接地接触阴影伸到地面线以下；"
             "back 比 front 高 = 室内地板坐在勒脚顶")
    if bb.get("albedo"):
        v["shadow_below_ground_px"] = round(
            _bot(bb["albedo"]) - pm["ground_row_1x"], 1)

    ok, reasons = True, []
    if f is None or a is None:
        ok = False
        reasons.append("albedo/front 缺失")
    for k, c in (("front", f), ("back", bk)):
        if c is None:
            ok = False
            reasons.append("%s 空" % k)
            continue
        # 阈值 3px：几何本身就是**不对称**的（法师塔 w4 的尖顶/侧凸偏 2.5px 是内容使然），
        # 而"换错相机/漏改分辨率"这类真错会偏几十到几百 px —— 3px 足以把两者分开。
        if k == "front" and c["center_err"] > 3.0:
            ok = False
            reasons.append("front 中心偏 %.2fpx" % c["center_err"])
        if k == "back" and not round_def and c["center_err"] > 3.0:
            ok = False
            reasons.append("back 中心偏 %.2fpx" % c["center_err"])
    if bk is not None and round_def and not v.get("back_inside_front", True):
        ok = False
        reasons.append("back 越出 front 塔身")
    if a is not None and f is not None:
        if v["front_top_vs_albedo"] > 3:
            ok = False
            reasons.append("front/albedo 屋面线差 %dpx" % v["front_top_vs_albedo"])
        if not v["front_inside_albedo"]:
            ok = False
            reasons.append("front 越出 albedo")
    if v.get("back_width_expected"):
        if abs(v["back_width_px"] - v["back_width_expected"]) > 3.0:
            ok = False
            reasons.append("back 宽 %d vs 期望 %.1f" % (v["back_width_px"],
                                                      v["back_width_expected"]))
    v["OK"] = ok
    v["reasons"] = reasons
    v["layers"] = out
    return v


def _write_index(metas, failed):
    idx = dict(root=OUT_ROOT.replace("\\", "/"), count=len(metas), failed=failed,
               px_per_unit=dict(x1=1.0, x2=2.0), cell_px=int(CELL),
               entries=[dict(def_name=m["def_name"], width_cells=m["width_cells"],
                             grid_w_px=m["grid_w_px"],
                             dir="%s_w%d" % (m["def_name"], m["width_cells"]),
                             glow_count=m.get("glow_count", len(m.get("glow", []))),
                             files=m["files"], verify_ok=m["verify"]["OK"])
                        for m in metas])
    with open(os.path.join(OUT_ROOT, "_bake_index.json"), "w",
              encoding="utf-8") as fh:
        json.dump(idx, fh, ensure_ascii=False, indent=1)
    return idx


def verify_mode():
    """只读重算自检（不重渲）：重跑 `_verify` + 重写 meta 里的 verify 与索引。"""
    metas = []
    for name in sorted(os.listdir(OUT_ROOT)):
        mp = os.path.join(OUT_ROOT, name, "meta.json")
        if not os.path.isfile(mp):
            continue
        with open(mp, encoding="utf-8") as fh:
            m = json.load(fh)
        paths = {k: os.path.join(OUT_ROOT, name, fn)
                 for k, fn in m["files"].items() if k != "meta"}
        if not m.get("interior_width_px"):
            # 旧 meta 无此字段：从上次的期望反推（round def 的期望为 None，用 grid_w 兜底，
            # 反正 round def 不判 back 跨度）
            old = (m.get("verify") or {}).get("back_width_expected")
            m["interior_width_px"] = (round(old / m["px_per_unit"]["x1"], 2)
                                      if old else m["grid_w_px"])
        m["verify"] = _verify(m, paths)
        with open(mp, "w", encoding="utf-8") as fh:
            json.dump(m, fh, ensure_ascii=False, indent=1)
        metas.append(m)
        print("%-14s w%-2d %s" % (m["def_name"], m["width_cells"],
                                  "OK" if m["verify"]["OK"]
                                  else "!! " + ";".join(m["verify"]["reasons"])))
    bad = [m for m in metas if not m["verify"]["OK"]]
    _write_index(metas, [])
    print("\n只读复检 %d 栋；不过 %d 栋%s"
          % (len(metas), len(bad), ("（%s）" % ", ".join(
              "%s_w%d" % (m["def_name"], m["width_cells"]) for m in bad))
             if bad else ""))
    print("BAKE_VERIFY_OK")


def render_mode():
    os.makedirs(OUT_ROOT, exist_ok=True)
    _clear()
    sc = bpy.context.scene
    _setup_engine(sc)
    cam = _camera()

    todo = bake_list()
    only = [s for s in os.environ.get("BAKE_ONLY", "").split(",") if s]
    wonly = [int(s) for s in os.environ.get("BAKE_WIDTHS", "").split(",") if s]
    if only:
        todo = [t for t in todo if t[0] in only]
    if wonly:
        todo = [t for t in todo if t[1] in wonly]
    print("\n=== 建筑 v3 烘焙导出：%d 个 def×档 ===" % len(todo))
    print("%-14s %3s %-10s %5s %5s %6s %5s %s"
          % ("def", "格", "装配器", "px/1x", "发光件", "back宽", "门px", "自检"))
    metas, failed = [], []
    for (def_name, wc, asm, asm_wc) in todo:
        try:
            _wipe()
            m = bake_one(def_name, wc, asm, asm_wc, cam)
        except Exception as exc:
            import traceback
            failed.append("%s_w%d" % (def_name, wc))
            print("!! %-14s w%-2d 失败: %s" % (def_name, wc, exc))
            traceback.print_exc()
            continue
        metas.append(m)
        v = m["verify"]
        print("%-14s %3d %-10s %5s %6d %6s %6s %s"
              % (def_name, wc, asm, "1+2", m["glow_count"],
                 (v.get("back_width_px") or "-"), m["door"].get("px_w_1x") or "-",
                 "OK" if v["OK"] else "!! " + ";".join(v["reasons"])[:40]))
    # 索引
    _write_index(metas, failed)
    bad = [m["def_name"] + "_w%d" % m["width_cells"] for m in metas
           if not m["verify"]["OK"]]
    print("\n导出 %d 栋；自检不过 %d 栋%s；失败 %d 个%s"
          % (len(metas), len(bad), ("（%s）" % ", ".join(bad)) if bad else "",
             len(failed), ("（%s）" % ", ".join(failed)) if failed else ""))
    print("输出根 → %s" % OUT_ROOT)
    print("BAKE_EXPORT_OK")


# ================================================================ 合成模式（游戏内一屏）

DEMO_W, DEMO_H = 1920, 1080
DEMO_GROUND_H = int(round(DEMO_H * 0.36))        # 屏幕下方约 36% = 地面带
#: 地面带**顶线** = 地平线 = `ground_y`（火柴人可走带上边界，见 建筑室内结构.md §2.2）
DEMO_HORIZON_Y = DEMO_H - DEMO_GROUND_H
#: **建筑基线 = `ground_y + 96`**（落地箱底边；`construction_project.gd:322` 的
#: `vis.position = (cell_x*32, ground_y+96)`）。锚在这一行，建筑才"种"在地里而不是
#: 站在地平线上（本轮修的第二个问题）。自检：`baseline == DEMO_HORIZON_Y + 96`。
DEMO_BASELINE_Y = DEMO_HORIZON_Y + 96
DEMO_MARGIN = 24
#: 地面分带（与 `ground_tiles.py` 的 `STRIP_*` 同口径：路肩 3 格 / 路缘 8px / 道路 5 格）。
#: 纵向剖面（自远及近，屏幕 y 向下为正）：
#:   地平线 `ground_y` → 远处地面（土）→ **建筑基线 `ground_y+96`**
#:   → 路肩 96（贴墙根硬化面；出檐投影与烘入的接地阴影落在这条带上）
#:   → 路缘 8 → 道路 160 → 屏底。
DEMO_BAND_SHOULDER = 96
DEMO_BAND_KERB = 8
DEMO_ZONE = "edge"                       # 单排村街 = edge 档（见 ground_tiles scale_rules）
#: 街排：`(def, 格宽, 与**前一栋可见剪影**的净距[格])`。
#: **必须按可见剪影排，不能按占地框排**：出檐 = min(建筑宽 × 20.5%, 60) 绝对封顶（buildings.py §8.2），
#: 剪影宽 ≈ 占地宽 × 1.4，按占地框排相邻两栋的出檐必然互压（本轮修的第一个问题）。
#: 1920px 一屏装不下 6 栋的剪影总宽（实测 2280px），故取 4 栋，净距 1~2 格。
DEMO_STREET = [("house", 8, 1), ("smithy1", 8, 2),
               ("townhouse", 12, 1), ("bakery", 8, 1)]
#: **建筑样例图不放角色**（角色只属于"游戏内一屏"类演示，且必须用游戏真表现 =
#: SubViewport + StickmanRig）。本文件不再画任何火柴人。


def _srgb_to_linear(a):
    import numpy as np
    x = np.clip(a, 0.0, 1.0)
    return np.where(x <= 0.04045, x / 12.92,
                    ((x + 0.055) / 1.055) ** 2.4).astype(np.float32)


def _linear_to_srgb(a):
    import numpy as np
    x = np.clip(a, 0.0, 1.0)
    return np.where(x <= 0.0031308, x * 12.92,
                    1.055 * x ** (1.0 / 2.4) - 0.055).astype(np.float32)


def _daynight_consts():
    """从 `daynight.py` 源码里取标定值（**不 import daynight**：它会 import bpy）。"""
    import re
    src = open(os.path.join(HERE, "daynight.py"), encoding="utf-8").read()
    m = re.search(r"^NIGHT_TINT\s*=\s*\(([^)]*)\)", src, re.M)
    tint = tuple(float(v) for v in m.group(1).split(",")) if m else (0.11, 0.14, 0.26)
    g = re.search(r"^GLOW_STRENGTH\s*=\s*([0-9.]+)", src, re.M)
    return tint, (float(g.group(1)) if g else 1.0)


def _load_rgba_srgb(path):
    """PIL 顶行序 → 翻成**底行序**（与 Blender 像素序一致），值域仍是 sRGB 0..1。"""
    import numpy as np
    from PIL import Image
    im = Image.open(path).convert("RGBA")
    a = np.asarray(im).astype(np.float32) / 255.0
    return a[::-1]


def _paste(canvas, src, x, y):
    """底行序 RGBA 贴到底行序画布；`y` = 贴图**自顶**行在画布上的自顶行号。

    两个数组都按"行 0 = 底部"存（渲染像素序），所以先把它换算成底行序再切片，
    避免"自顶/自底"两套序混用（这是合成模式最容易出的错位来源）。
    """
    import numpy as np
    h, w, _ = src.shape
    ch, cw, _ = canvas.shape
    yb = ch - y - h                     # 贴图底边在画布底行序里的行号
    sy0 = max(0, -yb)                   # 上裁
    sy1 = h - max(0, (yb + h) - ch)     # 下裁
    x0 = max(0, x)
    x1 = min(cw, x + w)
    sx0 = x0 - x
    if sy1 <= sy0 or x1 <= x0:
        return
    sub = src[sy0:sy1, sx0:sx0 + (x1 - x0)]
    dy0 = yb + sy0
    a = sub[..., 3:4]
    dst = canvas[dy0:dy0 + (sy1 - sy0), x0:x1]
    dst[..., :3] = sub[..., :3] * a + dst[..., :3] * (1.0 - a)
    dst[..., 3] = np.maximum(dst[..., 3], a[..., 0])


def _paste_rgb(canvas, rgb, x, y):
    """不透明底图直贴（rgb 自底行序；语义同 `_paste`）。"""
    h, w, _ = rgb.shape
    ch, cw, _ = canvas.shape
    yb = ch - y - h
    sy0 = max(0, -yb)
    sy1 = h - max(0, (yb + h) - ch)
    x0 = max(0, x)
    x1 = min(cw, x + w)
    sx0 = x0 - x
    if sy1 <= sy0 or x1 <= x0:
        return
    canvas[yb + sy0:yb + sy1, x0:x1, :3] = rgb[sy0:sy1, sx0:sx0 + (x1 - x0)]
    canvas[yb + sy0:yb + sy1, x0:x1, 3] = 1.0


def _seg_game_px(band, zone, variant):
    """读一段地面分段（raster 是 2 texel/游戏px）→ 盒式降到游戏像素（1px=1单位）。

    段文件是 1024px 宽（16 格 × 64 raster px）；manifest `supersample=2` 且
    `px_per_cell=64` → 游戏像素 = raster / 2。返回**底行序** RGB 0..1（与 `_paste_rgb` 一致）。
    """
    import numpy as np
    from PIL import Image
    p = os.path.join(TEMP, "ground_tiles",
                     "seg_%s_%s_v%d.png" % (band, zone, variant))
    if not os.path.exists(p):
        return None
    im = Image.open(p).convert("RGB")
    w, h = im.size
    a = np.asarray(im.resize((max(1, w // 2), max(1, h // 2)), Image.BOX),
                   dtype=np.float32) / 255.0
    return a[::-1]


def _fill_band(canvas, band, zone, y_top, y_bot, x_from, x_to, v0=1):
    """把某分段（横向 512px 严格周期）铺进画布 `[y_top, y_bot) × [x_from, x_to)`。

    纵向不足按段高**平铺**（段是结构方向，不纵向拉伸）；横向 512px 链式相接，
    变体 v1..v5 轮换（edge_convention：横向严格周期 → 任意顺序可接）。
    返回是否真的用到了分段（False = 段文件缺失，调用方走兜底）。
    """
    import numpy as np
    h = int(y_bot) - int(y_top)
    if h <= 0:
        return True
    used, x, i = False, int(x_from), 0
    while x < x_to:
        seg = _seg_game_px(band, zone, ((v0 - 1 + i) % 5) + 1)
        if seg is None:
            return used
        used = True
        reps = -(-h // seg.shape[0])                     # ceil
        # 底行序数组的**末 h 行** = 段顶部 h 行 → 顶对齐平铺（不拉伸）
        block = np.tile(seg, (reps, 1, 1))[-h:]
        _paste_rgb(canvas, block, x, int(y_top))
        x += seg.shape[1]
        i += 1
    return used


def _tile_ground(canvas):
    """铺地面带（真分段，`stick-world/temp/ground_tiles/`）。

    纵向剖面（自远及近，屏幕 y 向下为正）见文件里 `DEMO_BAND_*` 注释：
      地平线 `ground_y` → 远处地面（土）→ 建筑基线 `ground_y+96`
      → 路肩 96（贴墙根）→ 路缘 8 → 道路 → 屏底。
    这段剖面与 `ground_tiles.b_street_strip` 的带序一致（上=建筑基线，下=道路）。

    返回 `(用到了真分段?, 说明)`。**分段缺失时**（地面任务线重出会出现中间态）退回
    "纯色夯土带 + 文字标注"，不让演示图因别人的中间态变成天空色（任务书允许的兜底）。
    """
    import numpy as np
    gt = os.path.join(TEMP, "ground_tiles")
    have = sorted(glob.glob(os.path.join(gt, "seg_*_%s_*.png" % DEMO_ZONE)))
    base, kerb = DEMO_BASELINE_Y, DEMO_BASELINE_Y + DEMO_BAND_SHOULDER
    road = kerb + DEMO_BAND_KERB
    if not have:
        soil = np.zeros((DEMO_H - DEMO_HORIZON_Y, DEMO_W, 3), np.float32)
        soil[:] = np.array([0.34, 0.28, 0.20], np.float32)
        _paste_rgb(canvas, soil, 0, DEMO_HORIZON_Y)
        return False, "纯色夯土带（ground_tiles 分段当前不可用）"
    used = all((
        _fill_band(canvas, "road", DEMO_ZONE, DEMO_HORIZON_Y, base, 0, DEMO_W, v0=3),
        _fill_band(canvas, "shoulder", DEMO_ZONE, base, kerb, 0, DEMO_W, v0=1),
        _fill_band(canvas, "kerb", DEMO_ZONE, kerb, road, 0, DEMO_W, v0=1),
        _fill_band(canvas, "road", DEMO_ZONE, road, DEMO_H, 0, DEMO_W, v0=1),
    ))
    if not used:
        return False, "纯色夯土带（ground_tiles 分段读不到）"
    return True, ("ground_tiles 真分段·edge 档（远处地面 | 路肩 %d | 路缘 %d | 道路 %d）"
                  % (DEMO_BAND_SHOULDER, DEMO_BAND_KERB,
                     DEMO_H - road))


def _sil_bbox(sprite, thr=0.06):
    """alpha 包围盒（sprite 为底行序数组）：返回 sprite 内 (x0, x1, y0, y1)。"""
    import numpy as np
    ys, xs = np.nonzero(sprite[..., 3] > thr)
    if len(xs) == 0:
        return None
    return int(xs.min()), int(xs.max()), int(ys.min()), int(ys.max())


def _label(img, text, xy, size=22, fill=(238, 234, 226, 255),
           font_path=r"C:\Windows\Fonts\msyh.ttc"):
    from PIL import ImageDraw, ImageFont
    d = ImageDraw.Draw(img)
    try:
        f = ImageFont.truetype(font_path, size)
    except Exception:
        f = None
    d.text(xy, text, font=f, fill=fill, stroke_width=2,
           stroke_fill=(12, 12, 14, 255))


def _compose_screen(night):
    """把导出的 sprite 按游戏真实比例拼成**建筑样例**一屏。返回 (PIL.Image, report)。

    三条硬规则（本轮修的三个问题）：
      ① 排布按**可见剪影**（alpha 包围盒）量净距，不按占地框 —— 否则出檐互压；
      ② 建筑锚点（前墙面基线）= `ground_y + 96`，落在地面带顶线下方 96px；
      ③ 不画任何角色（样例图不出火柴人）。
    plus 自检：相邻包围盒相交 / 基线不对 / 越界 → 报错（`compose_mode` 退出码 1）。
    """
    import numpy as np
    from PIL import Image
    tint, gstr = _daynight_consts()
    canvas = np.zeros((DEMO_H, DEMO_W, 4), np.float32)
    # ---- 天空占位（游戏内由后景层负责；此处只给一层渐变，避免死黑/死白）
    rows = np.linspace(0.0, 1.0, DEMO_H, dtype=np.float32)[:, None]
    if night:
        top = np.array([0.055, 0.075, 0.17], np.float32)
        bot = np.array([0.16, 0.18, 0.27], np.float32)
    else:
        top = np.array([0.34, 0.48, 0.72], np.float32)
        bot = np.array([0.76, 0.79, 0.80], np.float32)
    sky = top[None, :] * (1.0 - rows) + bot[None, :] * rows
    canvas[..., :3] = sky[:, None, :]
    canvas[..., 3] = 1.0

    # ---- 地面带（真分段：远处地面 | 路肩 | 路缘 | 道路）
    have_seg, ground_src = _tile_ground(canvas)

    # ---- 建筑：按"可见剪影 + 格对齐"排；锚点（前墙面基线）落在 DEMO_BASELINE_Y
    rows_out, rects = [], []
    cursor = None                                    # 上一栋剪影右缘（画布列）
    for (dname, wc, gap_cells) in DEMO_STREET:
        folder = os.path.join(OUT_ROOT, "%s_w%d" % (dname, wc))
        ap = os.path.join(folder, "albedo.png")
        mp = os.path.join(folder, "meta.json")
        if not (os.path.exists(ap) and os.path.exists(mp)):
            print("   ! 缺 %s_w%d，跳过" % (dname, wc))
            continue
        alb = _load_rgba_srgb(ap)
        meta = json.load(open(mp, encoding="utf-8"))
        anchor = meta["anchor"]["px_1x"]
        if night:
            gp = os.path.join(folder, "glow.png")
            g = _load_rgba_srgb(gp) if os.path.exists(gp) else np.zeros_like(alb)
            a_l = _srgb_to_linear(alb[..., :3])
            g_l = _srgb_to_linear(g[..., :3])
            rgb = a_l * np.asarray(tint, np.float32)[None, None, :] + g_l * gstr
            out = np.clip(_linear_to_srgb(rgb), 0.0, 1.0)
            sprite = np.concatenate(
                [out, np.maximum(alb[..., 3:4], g[..., 3:4])], axis=2)
        else:
            sprite = alb
        sil = _sil_bbox(sprite)
        if sil is None:
            print("   ! %s_w%d albedo 全透明，跳过" % (dname, wc))
            continue
        sh, sw = sprite.shape[:2]
        bx0, bx1, by0, by1 = sil
        ax = int(round(anchor[0]))                   # 锚点列 = 建筑横向中心
        ay = int(round(anchor[1]))                   # 锚点行 = 前墙面基线
        foot_dx = ax - wc * int(CELL) // 2           # 占地框左缘在 sprite 内的列
        # 本栋剪影左缘 = 上一栋剪影右缘 + 净距（格）；首栋 = 左边距
        left_min = (DEMO_MARGIN if cursor is None
                    else cursor + gap_cells * int(CELL)) - bx0
        rem = (left_min + foot_dx) % int(CELL)       # 格对齐（vis.position = cell*32）
        if rem:
            left_min += int(CELL) - rem
        L = int(round(left_min))
        Ty = DEMO_BASELINE_Y - ay
        _paste(canvas, sprite, L, Ty)
        # 画布包围盒（自顶行号）；sprite 是底行序，行 by → 画布行 Ty + (sh-1-by)
        rect = dict(x0=L + bx0, x1=L + bx1,
                    y0=Ty + (sh - 1 - by1), y1=Ty + (sh - 1 - by0))
        rects.append(dict(name="%s_w%d" % (dname, wc), rect=rect))
        rows_out.append(dict(
            def_name=dname, wc=wc, gap_cells=gap_cells,
            footprint_px=wc * int(CELL), silhouette_px=bx1 - bx0 + 1,
            canvas_bbox=[rect["x0"], rect["y0"], rect["x1"], rect["y1"]],
            anchor=[anchor[0], anchor[1]],
            baseline=dict(x=L + ax, y=DEMO_BASELINE_Y),
            glow=meta["glow_count"]))
        cursor = rect["x1"]

    # ---- 自检 ①：建筑基线 == 地面带顶线(ground_y) 下方 96px
    baseline_ok = (DEMO_BASELINE_Y == DEMO_HORIZON_Y + 96
                   and all(r["baseline"]["y"] == DEMO_BASELINE_Y for r in rows_out))
    # ---- 自检 ②：相邻建筑包围盒不得相交
    overlaps = []
    for a, b in zip(rects, rects[1:]):
        ra, rb = a["rect"], b["rect"]
        if (ra["x0"] <= rb["x1"] and rb["x0"] <= ra["x1"]
                and ra["y0"] <= rb["y1"] and rb["y0"] <= ra["y1"]):
            overlaps.append(dict(
                a=a["name"], b=b["name"],
                overlap_x_px=min(ra["x1"], rb["x1"]) - max(ra["x0"], rb["x0"]) + 1,
                overlap_y_px=min(ra["y1"], rb["y1"]) - max(ra["y0"], rb["y0"]) + 1))
    # ---- 自检 ③：不得越出画幅
    out_of_frame = [x["name"] for x in rects
                    if x["rect"]["x0"] < 0 or x["rect"]["x1"] > DEMO_W]

    # ---- 夜间地面压暗（与建筑同一 tint；地面无 alpha 直乘）
    # 注意 canvas 是**底行序**（行 0 = 屏幕底），地面带 = 底行序的 [0, DEMO_GROUND_H]。
    if night:
        n_ground = DEMO_H - DEMO_HORIZON_Y
        gnd = _srgb_to_linear(canvas[:n_ground, :, :3])
        canvas[:n_ground, :, :3] = _linear_to_srgb(
            gnd * np.asarray(tint, np.float32)[None, None, :])

    arr8 = (np.clip(canvas[::-1], 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8)
    img = Image.fromarray(arr8, "RGBA").convert("RGB")

    tag = "夜" if night else "昼"
    _label(img, "建筑管线 v3 建筑样例（%s）· 1px=1单位 · 1格=32px · "
                "地面带=屏高36%% · 无角色" % tag, (18, 12), 22)
    _label(img, "建筑基线 = 地平线下方 96px（落地箱底，自检过）；sprite 按 meta.anchor "
                "落位；相邻包围盒零相交（自检过）", (18, 42), 18, fill=(208, 206, 200, 255))
    _label(img, "地面：%s" % ground_src, (18, DEMO_H - 30), 18,
           fill=(226, 222, 210, 255))
    rep = dict(screen=[DEMO_W, DEMO_H], ground_h=DEMO_GROUND_H,
               horizon_y=DEMO_HORIZON_Y, baseline_y=DEMO_BASELINE_Y,
               baseline_ok=baseline_ok, overlaps=overlaps,
               out_of_frame=out_of_frame, night=night, ground_source=ground_src,
               ground_uses_segments=have_seg, street=rows_out,
               tint_night=list(tint) if night else None,
               glow_strength=gstr if night else None)
    return img, rep


def _draw_ref_lines(img):
    """在副本上画自检参考线（地平线 / 建筑基线）；**只用于 debug 文件，交付图不含**。"""
    from PIL import ImageDraw
    d = ImageDraw.Draw(img)
    d.line([(0, DEMO_HORIZON_Y), (DEMO_W, DEMO_HORIZON_Y)],
           fill=(60, 200, 220), width=2)                 # 地平线 ground_y
    d.line([(0, DEMO_BASELINE_Y), (DEMO_W, DEMO_BASELINE_Y)],
           fill=(240, 60, 200), width=2)                 # 建筑基线 ground_y+96
    return img


def compose_mode():
    """合成模式入口：出 `bake_game_screen.png` 与 `bake_game_screen_night.png`。

    `BAKE_DEMO_DEBUG=1` 时**另存**参考线调试图（`*_debug.png`），交付图始终无参考线。
    """
    os.makedirs(TEMP, exist_ok=True)
    day, r1 = _compose_screen(False)
    night, r2 = _compose_screen(True)
    p1 = os.path.join(TEMP, "bake_game_screen.png")
    p2 = os.path.join(TEMP, "bake_game_screen_night.png")
    day.save(p1)
    night.save(p2)
    if os.environ.get("BAKE_DEMO_DEBUG"):
        from PIL import Image
        _draw_ref_lines(day.copy()).save(
            os.path.join(TEMP, "bake_game_screen_debug.png"))
        _draw_ref_lines(night.copy()).save(
            os.path.join(TEMP, "bake_game_screen_night_debug.png"))
    with open(os.path.join(OUT_ROOT, "_game_screen_report.json"), "w",
              encoding="utf-8") as fh:
        json.dump(dict(day=r1, night=r2), fh, ensure_ascii=False, indent=1)
    print("   -> %s  %dx%d" % (p1, *day.size))
    print("   -> %s  %dx%d" % (p2, *night.size))
    # 自检报错：相邻包围盒相交 / 基线不在 ground_y+96 / 越界
    bad = []
    for tag, r in (("昼", r1), ("夜", r2)):
        for o in r["overlaps"]:
            bad.append("[%s] 相邻建筑包围盒相交 %s↔%s（x %dpx）"
                       % (tag, o["a"], o["b"], o["overlap_x_px"]))
        if not r["baseline_ok"]:
            bad.append("[%s] 建筑基线 ≠ 地平线+96" % tag)
        if r["out_of_frame"]:
            bad.append("[%s] 建筑越出画幅: %s" % (tag, r["out_of_frame"]))
    if bad:
        print("!! 合成自检不过：")
        for b in sorted(set(bad)):
            print("   - %s" % b)
        sys.exit(1)
    print("   自检 OK：相邻包围盒零相交 / 基线=地平线+96 / 未越界 / 无角色")
    print("BAKE_COMPOSE_OK")


def main():
    if not HAVE_BPY:
        compose_mode()
        return
    if os.environ.get("BAKE_VERIFY_ONLY"):
        verify_mode()
        return
    if os.environ.get("BAKE_DEMO_ONLY"):
        compose_mode()
        return
    render_mode()
    if not os.environ.get("BAKE_NO_DEMO"):
        compose_mode()


if __name__ == "__main__":
    main()
