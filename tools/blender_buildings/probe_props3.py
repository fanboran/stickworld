# -*- coding: utf-8 -*-
"""probe_props3.py —— 道具层二轮验收图（管线 v3 · 写实 PBR）

与 `probe_props.py` 的分工
--------------------------
`probe_props.py` 覆盖一轮的 34 件（容器/铁匠/家具/运输/立面挂载）；
本文件专做**二轮的 27 件**（市集摊/鱼摊/菜筐/染缸/面包架/鸡笼/石料堆…）+ 两套新配方
（`shop` 店铺立面 / `market` 市集立面）的实景。

产物（stick-world/temp/）::
    pbr_props3_strip.png    新道具总览条（真实尺寸 + 火柴人比例尺 + 挂墙件背后补墙板）
    pbr_props3_shop.png     店铺立面（真实装配器 townhouse(16) + `shop` 配方）
    pbr_props3_market.png   市集小广场（4 摊聚簇 + 广场件 + 散养人群比例尺）

跑法::
    blender -b --factory-startup -P probe_props3.py
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

OUT_DIR = "F:/VSCode/game-2/.temp/building-pipeline-v2/stick-world/temp"
YAW = 0.0
TILT = 20.0
ZOOM_STRIP = 1.45
ZOOM_SCENE = 1.7


# ---------------------------------------------------------------- 场景

def clear():
    """**只在开头调用一次**：建空场景。

    `read_factory_settings` 会清掉 bpy.data 里的材质/节点组，而 `buildings._CACHE` 与
    `materials` 的内部缓存仍持旧引用 → 之后拿到 "StructRNA ... has been removed"，
    `_external_material` 校验失败就静默回退纯色、纹理整片消失。所以多张图之间只能
    用 `wipe()` 删网格对象，绝不能再次 read_factory_settings（§六 踩坑）。
    """
    bpy.ops.wm.read_factory_settings(use_empty=True)
    B._CACHE.clear()
    try:
        import materials as M
        M.reset_cache()
    except Exception:
        pass


def wipe():
    """删掉场景里的所有网格对象（保留灯光/世界/相机/材质），供多张图复用场景。"""
    for ob in list(bpy.data.objects):
        if ob.type == "MESH":
            bpy.data.objects.remove(ob, do_unlink=True)


def setup_world():
    """暖调光照 + 合成器辉光（与 probe_delivery 同源：炉火/灯笼要有光晕）。"""
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
        print("[props3] 合成器辉光不可用：%s" % exc)

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


_GROUND = [None]


def warm_ground_material():
    """暖沙地面：**用 Object 坐标而不是 UV** 驱动噪声。

    地面是运行时 `from_pydata` 拼的四边形，**没有 UV 层**，套 UV 纹理只会得到一片
    平涂（踩过：整个地面死白）。Object 坐标在正交相机下等价于世界坐标。
    """
    if _GROUND[0] is not None:
        return _GROUND[0]
    m = bpy.data.materials.new("warm_ground")
    m.use_nodes = True
    nt = m.node_tree
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    bsdf.inputs["Roughness"].default_value = 0.96
    bsdf.inputs["Base Color"].default_value = (0.60, 0.51, 0.35, 1.0)
    tc = nt.nodes.new("ShaderNodeTexCoord")
    mp = nt.nodes.new("ShaderNodeMapping")
    mp.inputs["Scale"].default_value = (0.022, 0.022, 0.022)
    nz = nt.nodes.new("ShaderNodeTexNoise")
    nz.inputs["Scale"].default_value = 5.0
    nz.inputs["Detail"].default_value = 6.0
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].position = 0.32
    ramp.color_ramp.elements[0].color = (0.45, 0.36, 0.24, 1.0)
    ramp.color_ramp.elements[1].position = 0.75
    ramp.color_ramp.elements[1].color = (0.72, 0.62, 0.42, 1.0)
    bump = nt.nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.25
    nt.links.new(tc.outputs["Object"], mp.inputs["Vector"])
    nt.links.new(mp.outputs["Vector"], nz.inputs["Vector"])
    nt.links.new(nz.outputs["Fac"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    nt.links.new(nz.outputs["Fac"], bump.inputs["Height"])
    nt.links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
    _GROUND[0] = m
    return m


def make_ground(x0, x1, y0, y1):
    me = bpy.data.meshes.new("ground_mesh")
    me.from_pydata([(x0, y0, 0), (x1, y0, 0), (x1, y1, 0), (x0, y1, 0)], [], [(0, 1, 2, 3)])
    me.materials.append(warm_ground_material())
    ob = bpy.data.objects.new("ground", me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def make_camera():
    d = bpy.data.cameras.new("cam")
    d.type = "ORTHO"
    d.clip_start = 1.0
    d.clip_end = 60000.0
    ob = bpy.data.objects.new("cam", d)
    bpy.context.scene.collection.objects.link(ob)
    bpy.context.scene.camera = ob
    return ob


def place_camera(cam, anchor, dist=14000.0):
    right, up = B.cam_axes(YAW, TILT)
    fwd = -(right.cross(up))
    cam.location = tuple(Vector(anchor) - fwd * dist)
    cam.rotation_euler = (math.radians(90.0 - TILT), 0.0, math.radians(YAW))


def shoot_fit(cam, objs, zoom, path, pad=40.0, pad_top=30.0, res_max=7000):
    pts = []
    for ob in objs:
        pts += B.shape_points(ob, skip_ground=False)
    right, up = B.cam_axes(YAW, TILT)
    us = [p.dot(right) for p in pts]
    vs = [p.dot(up) for p in pts]
    u0, u1 = min(us) - pad, max(us) + pad
    v0, v1 = min(vs) - pad, max(vs) + pad_top
    w, h = (u1 - u0), (v1 - v0)
    cu, cv = (u0 + u1) / 2.0, (v0 + v1) / 2.0
    ref = pts[0]
    anchor = ref + right * (cu - ref.dot(right)) + up * (cv - ref.dot(up))
    place_camera(cam, anchor)
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
    return {"path": path, "res": (rx, ry)}


# ---------------------------------------------------------------- 总览条

#: 条目 = (道具名, kwargs, 站位宽)。同类相邻：筐货 → 摊台 → 立面挂件 → 摊场件 →
#: 盆缸 → 堆垛 → 运输/围养。挂墙件（P.FLUSH）会自动在身后补一块墙板，否则总览条上
#: 会看到"布篷/招牌浮在半空"。
STRIP = [
    ("basket", dict(r=19.0, h=19.0), 46.0),
    ("basket", dict(r=17.0, h=17.0, handle=True), 44.0),
    ("produce_baskets", dict(r=18.0, h=18.0), 92.0),
    ("flower_bucket", dict(r=10.0, h=21.0), 56.0),
    ("market_table", dict(w=120.0, d=60.0, h=62.0, goods="produce"), 132.0),
    ("market_table", dict(w=120.0, d=60.0, h=62.0, goods="cheese"), 132.0),
    ("fish_table", dict(w=110.0, d=52.0, h=60.0), 126.0),
    ("pottery_row", dict(n=5, r=17.0, h=30.0), 108.0),
    ("bread_tray", dict(w=60.0, h=76.0), 70.0),
    ("market_stall", dict(w=170.0, d=88.0, h=165.0), 214.0),
    ("awning", dict(w=140.0, z=118.0), 156.0),
    ("hanging_sign", dict(w=48.0, h=38.0, swing=2.0, z=150.0), 72.0),
    ("herb_rack", dict(w=64.0, z=150.0), 74.0),
    ("broom_bundle", dict(h=118.0), 48.0),
    ("standing_board", dict(w=44.0, h=66.0), 58.0),
    ("lantern_post", dict(h=196.0), 58.0),
    ("wash_tub", dict(r=30.0, h=26.0), 106.0),
    ("dye_pots", dict(n=3, r=21.0, h=32.0), 144.0),
    ("barrel_stand", dict(w=104.0), 122.0),
    ("sack_stack", dict(r=13.0, h=30.0), 72.0),
    ("crate_stack", dict(s=30.0, h=26.0, n=3), 50.0),
    ("firewood_basket", dict(r=20.0, h=22.0), 52.0),
    ("milk_churn", dict(r=12.0, h=54.0), 36.0),
    ("water_butt", dict(r=16.0, h=54.0), 46.0),
    ("hay_bale", dict(w=76.0, d=42.0, h=34.0), 88.0),
    ("stone_pile", dict(w=88.0, h=40.0), 100.0),
    ("stew_pot", dict(r=22.0, h=26.0), 68.0),
    ("chicken_coop", dict(w=92.0, d=60.0, h=56.0, hens=3), 112.0),
    ("cart_loaded", dict(w=110.0, d=52.0), 158.0),
]


def build_strip():
    objs = []
    cursor = 0.0
    placed = []
    for (pname, kw, span) in STRIP:
        fn = P.TABLE[pname]
        b = B.Builder("prop3_%s_%.0f" % (pname, cursor))
        if pname in P.FLUSH:                 # 挂墙件补一块墙板（否则读作"浮空"）
            b.box_bottom((span - 10.0, 14.0, 214.0), (0.0, 7.0), 0.0, "wood")
        p = dict(kw)
        zz = p.pop("z", 0.0)
        p["seed"] = int(cursor)
        try:
            fn(b, x=0.0, y=0.0, z=zz, **p)
        except TypeError:
            p.pop("seed", None)
            fn(b, x=0.0, y=0.0, z=zz, **p)
        ob = b.to_object()
        ob.location.x = cursor
        bpy.context.view_layer.update()
        objs.append(ob)
        placed.append((pname, cursor, span))
        cursor += span
    n = 9                                   # 比例尺：等距插火柴人
    for i in range(n):
        sb = B.Builder("stick3_%d" % i)
        B.stickman(sb, x=0.0, y=-30.0)
        sob = sb.to_object()
        sob.location.x = cursor * (i + 0.5) / n
        bpy.context.view_layer.update()
        objs.append(sob)
    return objs, cursor, placed


# ---------------------------------------------------------------- 立面实景

def dressed(name, wc, kind, seed, tag, doorless=False):
    ob, spec = B.ASSEMBLERS[name](wc)
    mx = B.measure(ob)
    pb = B.Builder("props3_" + tag)
    d = spec.get("door")
    placed = P.dress(pb, kind, spec["grid_w"], mx["y"][0], seed=seed,
                     door_x=spec.get("door_x", 0.0), door_w=(d[0] if d else 0.0))
    pob = pb.to_object()
    return ob, pob, spec, placed, mx


def shoot_facade(cam, name, wc, kind, tag, seed=7, zoom=ZOOM_SCENE):
    wipe()
    ob, pob, spec, placed, mx = dressed(name, wc, kind, seed, tag)
    sb = B.Builder("stick3_" + tag)
    B.stickman(sb, x=mx["x"][1] + 40.0, y=mx["y"][0] - 40.0)
    sob = sb.to_object()
    make_ground(mx["x"][0] - 500.0, mx["x"][1] + 500.0, -700.0, 700.0)
    shoot_fit(cam, [ob, pob, sob], zoom, os.path.join(OUT_DIR, tag + ".png"),
              pad=70.0, pad_top=50.0)
    print("   %s W=%.0f 挂载：%s" % (tag, spec["grid_w"], placed))
    return placed


# ---------------------------------------------------------------- 市集小广场

#: (道具名, x, y, 站位宽, kwargs)。市集广场靠"摊篷领衔 + 前场散件 + 亮灯柱"读出来；
#: 所有散件都乘 GAME_SCALE（与 dress() 一致的挂载口径）。
MARKET = [
    # 前排三摊（正面朝观众）
    ("market_stall", -330.0, -40.0, 0.0,
     dict(w=170.0, d=88.0, h=165.0, cloth="cloth_ochre", seed=11)),
    ("market_stall", -30.0, -40.0, 0.0,
     dict(w=170.0, d=88.0, h=165.0, cloth="cloth_red", seed=22)),
    ("market_stall", 270.0, -40.0, 0.0,
     dict(w=170.0, d=88.0, h=165.0, cloth="cloth_blue", seed=33)),
    # 后排一摊（多一行读"广场"而不是"一排店"；放左后方，别被前排整条吃掉）
    ("market_stall", -640.0, 330.0, 0.0,
     dict(w=150.0, d=80.0, h=155.0, cloth="cloth_ochre", seed=44)),
    # 广场散件
    ("barrel_stand", -540.0, -150.0, 0.0, dict(w=104.0)),
    ("produce_baskets", -180.0, -240.0, 0.0, dict(r=18.0, h=18.0)),
    ("fish_table", 250.0, -250.0, 0.0, dict(w=110.0)),
    ("pottery_row", 570.0, -120.0, 0.0, dict(n=5, r=17.0, h=30.0)),
    ("sack_stack", 440.0, -300.0, 0.0, dict(r=13.0, h=30.0)),
    ("crate_stack", -430.0, -310.0, 0.0, dict(s=30.0, h=26.0)),
    ("stew_pot", -60.0, -430.0, 0.0, dict(r=22.0, h=26.0)),
    ("wash_tub", 650.0, -340.0, 0.0, dict(r=28.0, h=24.0)),
    ("milk_churn", -650.0, -300.0, 0.0, dict(r=12.0, h=54.0)),
    ("water_butt", -290.0, -440.0, 0.0, dict(r=16.0, h=54.0)),
    ("firewood_basket", 60.0, -480.0, 0.0, dict(r=20.0, h=22.0)),
    ("standing_board", -170.0, -350.0, 0.0, dict(w=44.0, h=66.0)),
    ("basket", 350.0, -430.0, 0.0, dict(r=17.0, h=17.0, handle=True)),
    ("hay_bale", -780.0, -160.0, 0.0, dict(w=76.0, d=42.0, h=34.0)),
    ("cart_loaded", 860.0, -90.0, 0.0, dict(w=110.0, d=52.0)),
    ("lantern_post", -900.0, -40.0, 0.0, dict(h=196.0)),
    ("lantern_post", 980.0, -40.0, 0.0, dict(h=196.0)),
]

#: 广场上的人（火柴人比例尺）：(x, y)
PEOPLE = [(-250.0, -330.0), (120.0, -360.0), (500.0, -220.0), (-720.0, -230.0),
          (-90.0, -560.0), (800.0, -420.0)]


def put(b, pname, x, y, z=0.0, scale=P.GAME_SCALE, **kw):
    """按 dress() 同口径挂载单件（主尺寸 ×GAME_SCALE）。"""
    fn = P.TABLE[pname]
    p = dict(kw)
    if scale != 1.0:
        for k in ("r", "h", "w", "d", "s"):
            if k in p:
                p[k] = p[k] * scale
    p.setdefault("seed", int(abs(x) + abs(y)))
    try:
        fn(b, x=x, y=y, z=z, **p)
    except TypeError:
        p.pop("seed", None)
        fn(b, x=x, y=y, z=z, **p)


def build_market():
    """市集小广场：4 摊 + 广场件 + 一栋民居立面（带 house 配方，看追加道具的实景）。"""
    objs = []
    b = B.Builder("market_ground_set")
    for (pname, x, y, z, kw) in MARKET:
        put(b, pname, x, y, z, **kw)
    objs.append(b.to_object())

    # 民居立面（放在右后角：前排摊不挡它，能把 house 配方的新道具一并看到）
    hob, spec = B.ASSEMBLERS["house"](12)
    hmx = B.measure(hob)
    hob.location = (560.0, 360.0 - hmx["y"][0], 0.0)
    bpy.context.view_layer.update()
    hmx2 = B.measure(hob)
    pb = B.Builder("market_house_props")
    d = spec.get("door")
    placed = P.dress(pb, "house", spec["grid_w"], hmx2["y"][0], seed=5,
                     door_x=spec.get("door_x", 0.0), door_w=(d[0] if d else 0.0))
    pob = pb.to_object()
    objs += [hob, pob]
    print("   民居(12) house 配方挂载：%s" % (placed,))

    sb = B.Builder("market_people")
    for (px, py) in PEOPLE:
        B.stickman(sb, x=px, y=py)
    objs.append(sb.to_object())
    return objs


# ---------------------------------------------------------------- 主流程

def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    clear()
    setup_world()
    cam = make_camera()

    # 1) 新道具总览条
    objs, span, placed = build_strip()
    print("\n[strip] %d 件（含变体）总宽 %.0f 单位" % (len(placed), span))
    for (pname, x, sp) in placed:
        print("   %-16s x=%7.1f  span=%5.1f" % (pname, x, sp))
    make_ground(-260.0, span + 260.0, -520.0, 520.0)
    shoot_fit(cam, objs, ZOOM_STRIP, os.path.join(OUT_DIR, "pbr_props3_strip.png"),
              pad=44.0, pad_top=18.0)

    # 1b) 诊断用高清条：PROPS3_FOCUS="market_stall,awning" 只出这几件（放大 3.4 px/单位）
    focus = [s.strip() for s in os.environ.get("PROPS3_FOCUS", "").split(",") if s.strip()]
    if focus:
        wipe()
        fobjs = []
        cursor = 0.0
        for pname in focus:
            kw = dict(next((k for (n, k, _s) in STRIP if n == pname), {}))
            span = next((s for (n, _k, s) in STRIP if n == pname), 120.0)
            span = max(span, 90.0)
            b = B.Builder("focus_%s" % pname)
            if pname in P.FLUSH:
                b.box_bottom((span - 10.0, 14.0, 214.0), (0.0, 7.0), 0.0, "wood")
            zz = kw.pop("z", 0.0)
            kw["seed"] = int(cursor) + 3
            try:
                P.TABLE[pname](b, x=0.0, y=0.0, z=zz, **kw)
            except TypeError:
                kw.pop("seed", None)
                P.TABLE[pname](b, x=0.0, y=0.0, z=zz, **kw)
            ob = b.to_object()
            ob.location.x = cursor
            bpy.context.view_layer.update()
            fobjs.append(ob)
            cursor += span
        for i in range(4):
            sb = B.Builder("focus_stick_%d" % i)
            B.stickman(sb, x=0.0, y=-30.0)
            sob = sb.to_object()
            sob.location.x = cursor * (i + 0.5) / 4.0
            bpy.context.view_layer.update()
            fobjs.append(sob)
        make_ground(-260.0, cursor + 260.0, -520.0, 520.0)
        shoot_fit(cam, fobjs, 3.4, os.path.join(OUT_DIR, "pbr_props3_focus.png"),
                  pad=60.0, pad_top=20.0)

    # 2) 店铺立面（真实装配器 + `shop` 配方）
    shoot_facade(cam, "townhouse", 16, "shop", "pbr_props3_shop", seed=7)

    # 3) 市集小广场（多图之间只 wipe() 网格，绝不重建场景，否则材质缓存失效）
    wipe()
    mobjs = build_market()
    make_ground(-1500.0, 1500.0, -1000.0, 900.0)
    shoot_fit(cam, mobjs, ZOOM_SCENE, os.path.join(OUT_DIR, "pbr_props3_market.png"),
              pad=90.0, pad_top=60.0)

    print("\nPROPS3_PROBE_OK")


main()
