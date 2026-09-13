# -*- coding: utf-8 -*-
"""probe_props4.py —— 道具层三轮（玻璃 / 魔法 / 宗教 / 军政农事）验收图（管线 v3）

与 `probe_props*.py` 的分工
--------------------------
`probe_props.py` 覆盖一轮 34 件（容器/铁匠/家具/运输/立面挂载）；
`probe_props3.py` 覆盖二轮 27 件（市集/民生）+ shop/market 配方；
本文件专做**三轮 34 件**（玻璃器 / 魔法器具 / 宗教器物 / 军械农事）+ 三套新配方
（`alchemy` 炼金坊 / `chapel` 教堂 / `library` 图书馆）的实景。

产物（stick-world/temp/）::
    pbr_props4_strip.png    新道具总览条（真实尺寸 + 变体 + 火柴人比例尺 + 挂墙件补墙板）
    pbr_props4_alchemy.png  炼金坊立面（真实装配器 alchemy(8) + `alchemy` 配方）
    pbr_props4_chapel.png   教堂立面（cathedral(8) + `chapel` 配方；彩窗板/祭坛/烛架）

跑法::
    blender -b --factory-startup -P probe_props4.py
    PROPS4_FOCUS="alembic,glass_crate" blender -b --factory-startup -P probe_props4.py
        （只出这几件的高清条 → pbr_props4_focus.png，3.4 px/单位，查穿插/比例用）
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
WALL_BOARD_H = 214.0


# ---------------------------------------------------------------- 场景

def clear():
    """**只在开头调用一次**：建空场景。

    `read_factory_settings` 会清掉 bpy.data 里的材质/节点组，而 `buildings._CACHE` 与
    `materials` 的内部缓存仍持旧引用 → 之后拿到 "StructRNA ... has been removed"，
    `_external_material` 校验失败就静默回退纯色、纹理整片消失。多张图之间只能用
    `wipe()` 删网格对象（§六 踩坑）。
    """
    bpy.ops.wm.read_factory_settings(use_empty=True)
    B._CACHE.clear()
    try:
        import materials as M
        M.reset_cache()
    except Exception:
        pass


def wipe():
    for ob in list(bpy.data.objects):
        if ob.type == "MESH":
            bpy.data.objects.remove(ob, do_unlink=True)


def setup_world():
    """暖调光照 + 合成器辉光（自发光件要有光晕，否则"发光的太暗"）。"""
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
        print("[props4] 合成器辉光不可用：%s" % exc)

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
    """暖沙地面（用 Object 坐标驱动噪声：运行时拼的四边形没有 UV 层）。"""
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


def put(b, pname, x, y, z=0.0, scale=P.GAME_SCALE, **kw):
    """按 `dress()` 同口径挂载单件（主尺寸 ×GAME_SCALE，z 不缩放）。"""
    fn = P.TABLE[pname]
    p = dict(kw)
    if scale != 1.0:
        for k in ("r", "h", "w", "d", "s"):
            if k in p:
                p[k] = p[k] * scale
    p.setdefault("seed", int(abs(x) + abs(y)))
    p["seed"] = int(p["seed"])
    try:
        fn(b, x=x, y=y, z=z, **p)
    except TypeError:
        p.pop("seed", None)
        fn(b, x=x, y=y, z=z, **p)


# ---------------------------------------------------------------- 总览条

#: 条目 = (道具名, kwargs, 站位宽)。**含变体**（同件不同参数），按族相邻：
#: 玻璃器 → 魔法器具 → 宗教器物 → 军政农事。挂墙件（P.FLUSH）在 z>40 时自动补一块
#: 墙板，否则条上会看到"窗板浮在半空"；立式的挂墙件（z=0）不补。
STRIP = [
    # ---- 玻璃系（10 件 / 12 条）----
    ("stained_glass_panel", dict(w=46.0, h=68.0), 58.0),
    ("stained_glass_panel", dict(w=62.0, h=90.0, broken=False, z=150.0), 74.0),
    ("stained_arch_frame", dict(w=54.0, h=104.0), 64.0),
    ("glass_lantern", dict(h=46.0), 38.0),
    ("glass_lantern", dict(h=46.0, hang=True, lit=False), 38.0),
    ("potion_bottles", dict(w=52.0, h=56.0), 60.0),
    ("potion_bottles", dict(w=52.0, h=56.0, n=4), 60.0),
    ("alembic", dict(h=108.0), 58.0),
    ("alembic", dict(h=108.0, heat=False), 58.0),
    ("candle_glass", dict(h=50.0), 32.0),
    ("crystal_orb", dict(r=16.0), 40.0),
    ("hourglass", dict(h=40.0), 32.0),
    ("inkwell_quill", dict(w=44.0), 54.0),
    ("glass_crate", dict(s=44.0, h=42.0), 56.0),
    # ---- 魔法系（10 件 / 13 条）----
    ("rune_stone", dict(h=150.0), 70.0),
    ("rune_stone", dict(h=104.0, w=44.0), 62.0),
    ("crystal_cluster", dict(w=58.0, h=56.0, n=4), 68.0),
    ("crystal_cluster", dict(w=44.0, h=38.0, n=3), 54.0),
    ("cauldron", dict(r=24.0, h=28.0), 58.0),
    ("cauldron", dict(r=24.0, h=28.0, fire=False, ladle=False), 58.0),
    ("book_stack", dict(w=36.0, h=32.0, n=5), 46.0),
    ("book_stack", dict(w=36.0, h=32.0, n=3), 46.0),
    ("scroll_rack", dict(w=72.0, h=94.0), 84.0),
    ("censer", dict(h=36.0), 38.0),
    ("summon_circle", dict(r=60.0), 132.0),
    ("magic_spring", dict(r=36.0, h=56.0), 88.0),
    ("staff_rack", dict(w=58.0, h=88.0), 68.0),
    ("astrolabe", dict(r=19.0), 42.0),
    # ---- 宗教系（4 件 / 5 条）----
    ("altar", dict(w=104.0, h=80.0), 122.0),
    ("altar", dict(w=104.0, h=80.0, cloth="cloth_blue", candles=2), 122.0),
    ("font", dict(r=22.0, h=66.0), 54.0),
    ("pew", dict(w=140.0, h=60.0), 154.0),
    ("candle_rack", dict(w=66.0, h=84.0), 78.0),
    # ---- 军事 / 农事（10 件）----
    ("weapon_rack", dict(w=80.0, h=106.0), 92.0),
    ("training_dummy", dict(h=142.0), 68.0),
    ("archery_target", dict(h=106.0), 64.0),
    ("beehive", dict(w=46.0, h=64.0), 56.0),
    ("saddle_rack", dict(w=82.0, h=104.0), 92.0),
    ("fork_stand", dict(w=52.0, h=98.0), 62.0),
    ("wheel_pile", dict(w=76.0, h=66.0), 86.0),
    ("wine_cart", dict(w=124.0), 170.0),
    ("shield_plaque", dict(w=42.0, h=48.0, z=118.0), 54.0),
    ("scarecrow", dict(h=150.0), 74.0),
]


def strip_objects(camera_objs):
    """建总览条，返回 (objs, 总宽, 摆放清单)。camera_objs 留着给调用方塞火柴人。"""
    objs, placed, cursor = [], [], 0.0
    for (pname, kw, span) in STRIP:
        b = B.Builder("prop4_%s_%.0f" % (pname, cursor))
        zz = float(kw.get("z", 0.0))
        if pname in P.FLUSH and zz > 40.0:
            bh = max(WALL_BOARD_H, zz + float(kw.get("h", 60.0)) + 20.0)
            # 墙板用**浅色抹灰**：木色墙板会把木盾/皮革道具整个吃掉（实测盾牌浮雕在
            # 木墙板上完全看不见），抹灰才衬得出深色器物。
            b.box_bottom((span - 10.0, 14.0, bh), (0.0, 7.0), 0.0, "plaster")
        p = dict(kw)
        p.pop("z", None)
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
        placed.append((pname, cursor, span))
        cursor += span
    return objs, cursor, placed


def add_stickmen(objs, total, n=9, y=-210.0):
    for i in range(n):
        sb = B.Builder("stick4_%d" % i)
        B.stickman(sb, x=0.0, y=y)
        sob = sb.to_object()
        sob.location.x = total * (i + 0.5) / n
        bpy.context.view_layer.update()
        objs.append(sob)


# ---------------------------------------------------------------- 立面实景

def dressed(name, wc, kind, seed, tag, front_y=None):
    ob, spec = B.ASSEMBLERS[name](wc)
    mx = B.measure(ob)
    fy = front_y if front_y is not None else mx["y"][0]
    pb = B.Builder("props4_" + tag)
    d = spec.get("door")
    placed = P.dress(pb, kind, spec["grid_w"], fy, seed=seed,
                     door_x=spec.get("door_x", 0.0), door_w=(d[0] if d else 0.0))
    pob = pb.to_object()
    return ob, pob, spec, placed, mx


def shoot_facade(cam, name, wc, kind, tag, seed=7, zoom=ZOOM_SCENE, people=2):
    wipe()
    ob, pob, spec, placed, mx = dressed(name, wc, kind, seed, tag)
    objs = [ob, pob]
    sb = B.Builder("stick4_" + tag)
    # 比例尺人放在**立面两端之外**（i 越大越远）：站进立面里会挡住溢出到屋前的道具
    for i in range(people):
        B.stickman(sb, x=mx["x"][1] + 110.0 + i * 80.0, y=mx["y"][0] - 70.0)
        B.stickman(sb, x=mx["x"][0] - 110.0 - i * 80.0, y=mx["y"][0] - 70.0)
    objs.append(sb.to_object())
    make_ground(mx["x"][0] - 600.0, mx["x"][1] + 600.0, -900.0, 700.0)
    shoot_fit(cam, objs, zoom, os.path.join(OUT_DIR, tag + ".png"),
              pad=70.0, pad_top=50.0)
    print("   %s(%d) W=%.0f door_x=%.0f door_w=%.1f  前墙面 y=%.1f"
          % (name, wc, spec["grid_w"], spec.get("door_x", 0.0),
             (spec["door"][0] if spec.get("door") else 0.0), mx["y"][0]))
    print("   挂载：%s" % (placed,))
    return placed


# ---------------------------------------------------------------- 主流程

def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    clear()
    setup_world()
    cam = make_camera()

    focus = [s.strip() for s in os.environ.get("PROPS4_FOCUS", "").split(",") if s.strip()]
    only_focus = os.environ.get("PROPS4_ONLY_FOCUS") == "1"

    if not only_focus:
        # 1) 新道具总览条（含变体 + 火柴人比例尺）
        objs, span, placed = strip_objects([])
        add_stickmen(objs, span, n=9)
        print("\n[strip] %d 条（含变体）总宽 %.0f 单位" % (len(placed), span))
        for (pname, x, sp) in placed:
            print("   %-20s x=%7.1f  span=%5.1f" % (pname, x, sp))
        make_ground(-260.0, span + 260.0, -520.0, 520.0)
        shoot_fit(cam, objs, ZOOM_STRIP, os.path.join(OUT_DIR, "pbr_props4_strip.png"),
                  pad=44.0, pad_top=18.0)

        # 2) 炼金坊立面（真实装配器 alchemy(8) + `alchemy` 配方）
        shoot_facade(cam, "alchemy", 12, "alchemy", "pbr_props4_alchemy", seed=11)

        # 3) 教堂立面（cathedral(8) + `chapel` 配方：彩窗板 / 祭坛 / 烛架）
        shoot_facade(cam, "cathedral", 12, "chapel", "pbr_props4_chapel", seed=13)

    # 4) 诊断用高清条：PROPS4_FOCUS="alembic,glass_crate" 只出这几件（3.4 px/单位）
    if focus:
        wipe()
        fobjs, cursor = [], 0.0
        for pname in focus:
            kw = dict(next((k for (n, k, _s) in STRIP if n == pname), {}))
            span = next((s for (n, _k, s) in STRIP if n == pname), 120.0)
            span = max(span, 90.0)
            b = B.Builder("focus_%s" % pname)
            zz = float(kw.get("z", 0.0))
            if pname in P.FLUSH and zz > 40.0:
                bh = max(WALL_BOARD_H, zz + float(kw.get("h", 60.0)) + 20.0)
                b.box_bottom((span - 10.0, 14.0, bh), (0.0, 7.0), 0.0, "plaster")
            p = dict(kw)
            p.pop("z", None)
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
            cursor += span
        add_stickmen(fobjs, cursor, n=4)
        make_ground(-260.0, cursor + 260.0, -520.0, 520.0)
        shoot_fit(cam, fobjs, 3.4, os.path.join(OUT_DIR, "pbr_props4_focus.png"),
                  pad=60.0, pad_top=20.0)

    print("\nPROPS4_PROBE_OK")


main()
