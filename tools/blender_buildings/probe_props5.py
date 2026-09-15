# -*- coding: utf-8 -*-
"""probe_props5.py —— 道具层六轮（街道家具 + 沿街节奏）验收图（管线 v3）

与 `probe_props*.py` 的分工
--------------------------
probe_props 一轮 34 件 / props3 二轮 27 件 / props4 三轮 34 件；
本文件专做**六轮 20 件街道家具**（路灯/花坛/休憩/市政/服务五系）
+ `props.dress_street()` 沿街节奏函数的实景验证。

产物（stick-world/temp/）::
    pbr_props5_strip.png    新道具总览条（挂载口径 GAME_SCALE 放大 + 变体 +
                            火柴人比例尺；挂墙件自动补墙板）
    pbr_props5_street.png   **40 格长双排街道家具节奏实景**：路灯两侧错位等距 +
                            花坛/长椅成组 + 街口公告板 + 中央小喷泉广场位；
                            地面用 ground_tiles 现有分带材质（肩带/路缘/道路），
                            远侧 3 栋现有装配器建筑作背景。

跑法::
    cd /f/VSCode/game-2 && blender -b --factory-startup -P tools/blender_buildings/probe_props5.py
    PROPS5_FOCUS="fountain_small,statue_base" ... -P probe_props5.py   # 单件高清条
"""

import math
import os
import sys

import bpy
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import buildings as B   # noqa: E402
import props as P       # noqa: E402
import ground_tiles as G  # noqa: E402

OUT_DIR = "F:/VSCode/game-2/stick-world/temp"
GT_DIR = os.path.join(OUT_DIR, "gt_props5")
YAW = 0.0
TILT = 20.0
ZOOM_STRIP = 1.45
ZOOM_SCENE = 1.35
WALL_BOARD_H = 214.0
STREET_W = 40                     # 街景：40 格长
BASE_Y = 170.0                    # 远侧建筑基线（前墙面落地线）


# ---------------------------------------------------------------- 场景基建

def clear():
    """**只在开头调用一次**（§六 踩坑：中途 read_factory_settings 会静默回退纯色）。"""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    B._CACHE.clear()
    try:
        import materials as M
        M.reset_cache()
    except Exception:
        pass


def wipe():
    """多图之间只删网格对象（灯/相机/世界跨图复用）。"""
    for ob in list(bpy.data.objects):
        if ob.type in ("MESH", "FONT", "CURVE", "SURFACE"):
            bpy.data.objects.remove(ob, do_unlink=True)


def setup_world():
    """暖调阳光高调 + 合成器辉光（自发光灯头要有光晕）。"""
    sc = bpy.context.scene
    for eng in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE", "CYCLES"):
        try:
            sc.render.engine = eng
            break
        except Exception:
            continue
    sc.render.film_transparent = False
    sc.view_settings.view_transform = "Standard"
    sc.view_settings.look = "None"
    for attr, val in (("taa_render_samples", 96), ("use_gtao", True)):
        try:
            setattr(sc.eevee, attr, val)
        except Exception:
            pass
    try:
        sc.use_nodes = True
        tree = sc.node_tree
        for n in list(tree.nodes):
            tree.nodes.remove(n)
        rl = tree.nodes.new("CompositorNodeRLayers")
        gl = tree.nodes.new("CompositorNodeGlare")
        gl.glare_type = "BLOOM" if "BLOOM" in [i.identifier for i in
                                               gl.bl_rna.properties["glare_type"].enum_items] else "FOG_GLOW"
        gl.quality = "HIGH"
        gl.threshold = 0.85
        gl.mix = -0.55
        cmp = tree.nodes.new("CompositorNodeComposite")
        tree.links.new(rl.outputs["Image"], gl.inputs["Image"])
        tree.links.new(gl.outputs["Image"], cmp.inputs["Image"])
    except Exception as exc:
        print("[props5] 合成器辉光不可用：%s" % exc)

    w = bpy.data.worlds.new("W")
    sc.world = w
    w.use_nodes = True
    bg = w.node_tree.nodes.get("Background") or w.node_tree.nodes.new("ShaderNodeBackground")
    bg.inputs[0].default_value = (0.58, 0.68, 0.84, 1.0)
    bg.inputs[1].default_value = 0.55

    def sun(name, energy, rot, angle=3.0, color=(1.0, 0.95, 0.85)):
        d = bpy.data.lights.new(name, "SUN")
        d.energy = energy
        d.angle = math.radians(angle)
        d.color = color
        ob = bpy.data.objects.new(name, d)
        ob.rotation_euler = tuple(math.radians(a) for a in rot)
        sc.collection.objects.link(ob)

    sun("key", 3.5, (42, 0, -34), 2.5, (1.0, 0.93, 0.80))
    sun("fill", 0.22, (58, 0, 126), 20.0, (0.80, 0.87, 1.0))
    sun("bounce", 0.35, (-28, 0, 6), 45.0, (0.95, 0.80, 0.62))


def make_camera():
    d = bpy.data.cameras.new("cam")
    d.type = "ORTHO"
    d.clip_start = 1.0
    d.clip_end = 60000.0
    ob = bpy.data.objects.new("cam", d)
    bpy.context.scene.collection.objects.link(ob)
    bpy.context.scene.camera = ob
    return ob


def place_camera(cam, anchor, dist=16000.0, yaw=None, tilt=None):
    yaw = YAW if yaw is None else yaw
    tilt = TILT if tilt is None else tilt
    right, up = B.cam_axes(yaw, tilt)
    fwd = -(right.cross(up))
    cam.location = tuple(Vector(anchor) - fwd * dist)
    cam.rotation_euler = (math.radians(90.0 - tilt), 0.0, math.radians(yaw))


def shoot_fit(cam, objs, zoom, path, pad=40.0, pad_top=30.0, res_max=7000,
              yaw=None, tilt=None):
    yaw = YAW if yaw is None else yaw
    tilt = TILT if tilt is None else tilt
    pts = []
    for ob in objs:
        pts += B.shape_points(ob, skip_ground=False)
    right, up = B.cam_axes(yaw, tilt)
    us = [p.dot(right) for p in pts]
    vs = [p.dot(up) for p in pts]
    u0, u1 = min(us) - pad, max(us) + pad
    v0, v1 = min(vs) - pad, max(vs) + pad_top
    w, h = (u1 - u0), (v1 - v0)
    cu, cv = (u0 + u1) / 2.0, (v0 + v1) / 2.0
    ref = pts[0]
    anchor = ref + right * (cu - ref.dot(right)) + up * (cv - ref.dot(up))
    place_camera(cam, anchor, yaw=yaw, tilt=tilt)
    k = min(1.0, res_max / float(max(w, h) * zoom))
    rx = max(64, int(round(w * zoom * k)))
    ry = max(64, int(round(h * zoom * k)))
    cam.data.ortho_scale = max(w, h)
    sc = bpy.context.scene
    sc.render.resolution_x = rx
    sc.render.resolution_y = ry
    sc.render.resolution_percentage = 100
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)
    print("-> %s  %dx%d  (%.2f px/unit)" % (os.path.basename(path), rx, ry, zoom * k))
    return {"path": path, "res": (rx, ry), "ppx": zoom * k}


def put(b, pname, x, y, z=0.0, scale=P.GAME_SCALE, **kw):
    """按 `dress()` 同口径挂载单件（主尺寸 ×GAME_SCALE×MOUNT_SCALE，z 不缩放）。"""
    fn = P.TABLE[pname]
    p = dict(kw)
    eff = scale * P.mount_scale(pname)
    if eff != 1.0:
        for k in ("r", "h", "w", "d", "s"):
            if k in p:
                p[k] = p[k] * eff
    p.setdefault("seed", int(abs(x) + abs(y)))
    p["seed"] = int(p["seed"])
    try:
        fn(b, x=x, y=y, z=z, **p)
    except TypeError:
        p.pop("seed", None)
        fn(b, x=x, y=y, z=z, **p)


# ---------------------------------------------------------------- 总览条

#: 条目 = (道具名, kwargs, 站位宽 model 单位)。含变体；FLUSH 高挂件自动补墙板。
STRIP = [
    # ---- 路灯系 ----
    ("lamp_post_stone", dict(h=200.0, lit=True), 44.0),
    ("lamp_post_iron", dict(h=225.0, lit=True), 52.0),
    ("lamp_post_iron", dict(h=225.0, lit=False), 52.0),
    ("wall_sconce", dict(h=36.0, z=176.0), 42.0),
    # ---- 花坛系 ----
    ("flower_bed_round", dict(r=55.0, h=34.0), 124.0),
    ("flower_bed_round", dict(r=40.0, h=30.0), 92.0),
    ("flower_bed_long", dict(w=170.0, d=44.0, h=38.0), 186.0),
    ("hanging_basket", dict(r=16.0, z=150.0), 44.0),
    ("hanging_basket", dict(r=16.0, on_post=True, post_r=7.0), 44.0),
    ("planter_ring", dict(r=34.0, h=15.0), 80.0),
    # ---- 休憩系 ----
    ("bench_wood", dict(w=130.0, d=44.0, h=44.0), 146.0),
    ("bench_stone", dict(w=120.0, d=40.0, h=44.0), 134.0),
    ("table_outdoor", dict(w=96.0, h=58.0, stools=3), 212.0),
    # ---- 市政系 ----
    ("fountain_small", dict(r=50.0, h=110.0), 190.0),
    ("fountain_grand", dict(r=115.0, h=260.0), 372.0),
    ("notice_board", dict(w=110.0, h=190.0), 122.0),
    ("flag_pole", dict(h=300.0, cloth="cloth_blue"), 54.0),
    ("statue_base", dict(s=60.0, h=185.0, mat="stone_dark"), 100.0),
    ("statue_base", dict(s=56.0, h=175.0, mat="bronze"), 94.0),
    ("milestone", dict(h=70.0), 44.0),
    ("signpost", dict(h=190.0, arms=3), 112.0),
    # ---- 服务系 ----
    ("horse_trough", dict(w=96.0, d=36.0, h=34.0), 108.0),
    ("water_tap", dict(h=110.0), 52.0),
    ("barrel_planter", dict(r=18.0, h=42.0), 58.0),
]


def strip_objects():
    """建总览条，返回 (objs, 总宽, 摆放清单)。按挂载口径出图（×GAME_SCALE）。"""
    objs, placed, cursor = [], [], 0.0
    for (pname, kw, span) in STRIP:
        b = B.Builder("prop5_%s_%.0f" % (pname, cursor))
        zz = float(kw.get("z", 0.0))
        eff = P.GAME_SCALE * P.mount_scale(pname)
        uspan = span * eff
        if pname in P.FLUSH and zz > 40.0:
            bh = max(WALL_BOARD_H, zz + float(kw.get("h", 60.0)) * eff + 20.0)
            b.box_bottom((uspan - 10.0, 14.0, bh), (0.0, 7.0), 0.0, "plaster")
        p = dict(kw)
        p.pop("z", None)
        if eff != 1.0:
            for k in ("r", "h", "w", "d", "s"):
                if k in p:
                    p[k] = p[k] * eff
        p["seed"] = int(cursor) + 3
        try:
            P.TABLE[pname](b, x=0.0, y=0.0, z=zz, **p)
        except TypeError:
            p.pop("seed", None)
            P.TABLE[pname](b, x=0.0, y=0.0, z=zz, **p)
        ob = b.to_object()
        ob.location.x = cursor
        bpy.context.view_layer.update()
        objs.append(ob)
        placed.append((pname, cursor, uspan))
        cursor += uspan
    return objs, cursor, placed


def add_stickmen(objs, total, n=8, y=-240.0):
    for i in range(n):
        sb = B.Builder("stick5_%d" % i)
        B.stickman(sb, x=0.0, y=y)
        sob = sb.to_object()
        sob.location.x = total * (i + 0.5) / n
        bpy.context.view_layer.update()
        objs.append(sob)


# ---------------------------------------------------------------- 地面（ground_tiles 分带）

_MC = {}


def gt_mat(key):
    """ground_tiles 材质缓存（tile_material 会删同名旧材质，必须缓存）。"""
    if key not in _MC:
        _MC[key] = G.tile_material(key, G.GAME_PX)
    return _MC[key]


def plane(name, x0, x1, y0, y1, z, mat, uv="world"):
    """水平四边形；uv="world" 世界平铺（x/128），"band" 配合 band_uv。"""
    me = bpy.data.meshes.new(name + "_m")
    me.from_pydata([(x0, y0, z), (x1, y0, z), (x1, y1, z), (x0, y1, z)], [], [(0, 1, 2, 3)])
    me.update()
    uvl = me.uv_layers.new(name="UVMap")
    pts = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
    for lp, (px, py) in zip(me.loops, pts):
        uvl.data[lp.index].uv = ((px / 128.0, py / 128.0) if uv == "world"
                                 else (px / 128.0, 0.5))
    me.materials.append(mat)
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def band_uv_plane(name, x0, x1, y_base, height, z, mat):
    """分带 UV：V 把 [y_base-height, y_base] 映到 0~1（V=1 贴建筑基线一侧）。"""
    me = bpy.data.meshes.new(name + "_m")
    me.from_pydata([(x0, y_base - height, z), (x1, y_base - height, z),
                    (x1, y_base, z), (x0, y_base, z)], [], [(0, 1, 2, 3)])
    me.update()
    uvl = me.uv_layers.new(name="UVMap")
    for lp, (px, py) in zip(me.loops, [(x0, y_base - height), (x1, y_base - height),
                                       (x1, y_base), (x0, y_base)]):
        uvl.data[lp.index].uv = (px / 128.0, (py - (y_base - height)) / float(height))
    me.materials.append(mat)
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def ensure_gt_textures():
    """街景要用的 4 张分带/平铺贴图（游戏档 128）——直接在内存生成并落盘。"""
    os.makedirs(GT_DIR, exist_ok=True)
    for key in ("grass_sparse", "band_shoulder_stone", "band_kerb_stone",
                "band_road_stone"):
        G.export_one(key, GT_DIR, G.GAME_PX)
        print("[gt] %s ok" % key)


# ---------------------------------------------------------------- 街道实景

#: 远侧背景建筑（现有装配器，档位取各自 TIERS 里真实存在的宽度档）
STREET_BUILDINGS = (("house", 12), ("house", 8), ("smithy1", 8), ("house", 8))
BUILDING_GAP = 40.0


def build_street(seed=907, density=1.4, plaza_x=8.0):
    """40 格双排街道家具节奏实景，返回 (objs, placements)。"""
    objs = []
    W = STREET_W * P.CELL
    X0, X1 = -W / 2.0, W / 2.0
    nb = G.SHOULDER_PX
    nk = G.KERB_PX
    wx = W + 700.0
    # ① 分带地面（肩带/路缘/道路/远处草地）
    objs.append(plane("g_far", -wx, wx, BASE_Y + 2.0, BASE_Y + 560.0, 0.0,
                      gt_mat("grass_sparse")))
    objs.append(band_uv_plane("g_shoulder", -wx, wx, BASE_Y, nb, 1.0,
                              gt_mat("band_shoulder_stone")))
    objs.append(band_uv_plane("g_kerb", -wx, wx, BASE_Y - nb, nk, 1.2,
                              gt_mat("band_kerb_stone")))
    objs.append(plane("g_road", -wx, wx, -600.0, BASE_Y - nb - nk, 0.8,
                      gt_mat("band_road_stone")))
    # ② 远侧背景建筑（贴基线）
    widths = [wc * P.CELL for (_n, wc) in STREET_BUILDINGS]
    gaps = [BUILDING_GAP, BUILDING_GAP]
    total = sum(widths) + sum(gaps)
    bx = -total / 2.0
    for (name, wc), wd in zip(STREET_BUILDINGS, widths):
        ob, _spec = B.ASSEMBLERS[name](wc)
        front_local = B.measure(ob)["y"][0]
        ob.location = (bx + wd / 2.0, BASE_Y - front_local, 0.0)
        bpy.context.view_layer.update()
        objs.append(ob)
        bx += wd + gaps[0]
    # ③ 沿街家具（dress_street 节奏输出 → 世界位）
    plan = P.dress_street(STREET_W, seed=seed, density=density, plaza_x=plaza_x,
                          lamp_every=(7.0, 10.0), group_every=(9.0, 14.0),
                          entrance=4.0)
    pb = B.Builder("props5_street")
    for e in plan:
        nm, x, side, y_off = e["name"], e["x"], e["side"], e["y_off"]
        kw = dict(e["kw"])
        if side > 0:                       # 远侧：踩肩带，大件允许压到路缘线
            y = BASE_Y - 40.0 - y_off * 0.35
        elif side < 0:                     # 近侧：前场道路带（靠画面这侧的路缘）
            y = -215.0 - y_off * 0.40
        else:                              # 街轴中央（广场件）
            y = -70.0
        put(pb, nm, x, y, **kw)
    objs.append(pb.to_object())
    # ④ 比例尺火柴人（路中）
    sb = B.Builder("stick5_street")
    for (sx, sy) in ((-380.0, -170.0), (170.0, -370.0), (540.0, -210.0)):
        B.stickman(sb, x=sx, y=sy, z=1.0)
    objs.append(sb.to_object())
    print("[street] %d 件家具：%s" % (len(plan), [(e["name"], e["side"]) for e in plan]))
    return objs, plan


# ---------------------------------------------------------------- 主流程

def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    clear()
    setup_world()
    cam = make_camera()

    focus = [s.strip() for s in os.environ.get("PROPS5_FOCUS", "").split(",") if s.strip()]
    only_street = os.environ.get("PROPS5_ONLY_STREET") == "1"
    only_strip = os.environ.get("PROPS5_ONLY_STRIP") == "1"

    if not only_street:
        # 1) 新道具总览条（含变体 + 火柴人比例尺）
        objs, span, placed = strip_objects()
        add_stickmen(objs, span, n=8)
        print("\n[strip] %d 条（含变体）总宽 %.0f 单位（挂载口径）" % (len(placed), span))
        for (pname, x, sp) in placed:
            print("   %-20s x=%7.1f  span=%5.1f" % (pname, x, sp))
        sb = B.Builder("strip_ground")
        sb.box_bottom((span + 700.0, 1300.0, 4.0), (span / 2.0, -160.0), -4.0, "dirt_packed")
        objs.append(sb.to_object())
        shoot_fit(cam, objs, ZOOM_STRIP, os.path.join(OUT_DIR, "pbr_props5_strip.png"),
                  pad=44.0, pad_top=18.0)

    if not only_strip:
        # 2) 40 格双排街道家具节奏实景
        wipe()
        ensure_gt_textures()
        objs, plan = build_street()
        shoot_fit(cam, objs, ZOOM_SCENE, os.path.join(OUT_DIR, "pbr_props5_street.png"),
                  pad=80.0, pad_top=60.0)

    # 3) 诊断用高清条：PROPS5_FOCUS="fountain_small" 只出这几件（3.4 px/单位）
    if focus:
        wipe()
        fobjs, cursor = [], 0.0
        for pname in focus:
            kw = dict(next((k for (n, k, _s) in STRIP if n == pname), {}))
            span = max(next((s for (n, _k, s) in STRIP if n == pname), 120.0), 100.0)
            eff = P.GAME_SCALE * P.mount_scale(pname)
            uspan = span * eff
            b = B.Builder("focus_%s" % pname)
            zz = float(kw.get("z", 0.0))
            if pname in P.FLUSH and zz > 40.0:
                bh = max(WALL_BOARD_H, zz + float(kw.get("h", 60.0)) * eff + 20.0)
                b.box_bottom((uspan - 10.0, 14.0, bh), (0.0, 7.0), 0.0, "plaster")
            p = dict(kw)
            p.pop("z", None)
            if eff != 1.0:
                for k in ("r", "h", "w", "d", "s"):
                    if k in p:
                        p[k] = p[k] * eff
            p["seed"] = int(cursor) + 3
            try:
                P.TABLE[pname](b, x=0.0, y=0.0, z=zz, **p)
            except TypeError:
                p.pop("seed", None)
                P.TABLE[pname](b, x=0.0, y=0.0, z=zz, **p)
            ob = b.to_object()
            ob.location.x = cursor
            bpy.context.view_layer.update()
            fobjs.append(ob)
            cursor += uspan
        add_stickmen(fobjs, cursor, n=3)
        gb = B.Builder("focus_ground")
        gb.box_bottom((cursor + 500.0, 900.0, 4.0), (cursor / 2.0, -120.0), -4.0,
                      "dirt_packed")
        fobjs.append(gb.to_object())
        shoot_fit(cam, fobjs, 3.4, os.path.join(OUT_DIR, "pbr_props5_focus.png"),
                  pad=60.0, pad_top=20.0)

    print("\nPROPS5_PROBE_OK")


if __name__ == "__main__":
    main()
