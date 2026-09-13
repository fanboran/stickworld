# -*- coding: utf-8 -*-
"""probe_props4.py —— 道具层三轮（玻璃 / 魔法 / 宗教 / 军政农事）验收图（管线 v3）

与 `probe_props*.py` 的分工
--------------------------
`probe_props.py` 覆盖一轮 34 件（容器/铁匠/家具/运输/立面挂载）；
`probe_props3.py` 覆盖二轮 27 件（市集/民生）+ shop/market 配方；
本文件专做**三轮 34 件**（玻璃器 / 魔法器具 / 宗教器物 / 军械农事）+ 三套新配方
（`alchemy` 炼金坊 / `chapel` 教堂 / `library` 图书馆）的实景。

产物（stick-world/temp/）::
    pbr_props4_strip.png    新道具总览条（**挂载后的游戏尺寸** + 变体 + 火柴人比例尺 +
                            挂墙件补墙板；小件含 `props.MOUNT_SCALE` 补偿放大）
    pbr_props4_alchemy.png  炼金坊立面（真实装配器 alchemy(12) + `alchemy` 配方；
                            配方只补空位，装配器自带前场蒸馏台/火盆不再与配方叠两套）
    pbr_props4_chapel.png   教堂立面（cathedral(12) + `chapel` 配方；彩窗板贴真实墙面）
    pbr_props4_wallfix.png  **门廊贴墙对照图**（侧视剖影）：同一深门廊立面上，
                            左=旧口径（按包围盒最外沿挂 → 悬空在门廊前方），
                            右=新口径（贴真实前墙面）。cathedral 尖拱门廊前凸 ~0.4D。

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
        if ob.type in ("MESH", "FONT", "CURVE", "SURFACE"):
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


def place_camera(cam, anchor, dist=14000.0, yaw=None, tilt=None):
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
    return {"path": path, "res": (rx, ry), "u0": u0, "w": w, "ppx": zoom * k}


def add_label(text, x, y, z, size=54.0):
    """在场景里放一块面向相机（+X）的 ASCII 文字牌（侧视对照图标注用）。

    用 Blender 自带 FONT 曲线（无外部依赖）；Blender 默认字体不含中文字形，故标注
    一律 ASCII。`to_track_quat("Z","Y")`：字面法线朝 +X、字身朝上。
    """
    cu = bpy.data.curves.new("lbl_" + text, type="FONT")
    cu.body = text
    cu.size = size
    cu.align_x = "CENTER"
    cu.align_y = "BOTTOM"
    ob = bpy.data.objects.new("lbl_" + text, cu)
    ob.location = (x, y, z)
    ob.rotation_mode = "QUATERNION"
    ob.rotation_quaternion = Vector((1.0, 0.0, 0.0)).to_track_quat("Z", "Y")
    bpy.context.scene.collection.objects.link(ob)
    return ob


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


def front_side_zones(ob, wall_y, W, gap=26.0, min_w=8.0, pad=6.0, z_min=26.0,
                     z_max=None, depth=20.0, x_margin=20.0):
    """建筑**前墙面之外**的**立式体量/家什**的 x 占位区间（门廊体量 / 前场家什）。

    喂给 `P.dress(reserved=...)`：落地件绕开这些 x 段（不往装配器自带的家什上堆），
    挂墙件也绕开（免得埋进凸出门廊的实体里 —— cathedral 的尖拱门廊是 x 向 ±93 的
    实体，彩窗板落到它后面就整个看不见了）。

    过滤（都是"横贯全宽、不代表可让位的家什"的几何，必须剔掉，否则区间会连成一片）：
      ① 接地阴影贴片（材质名含 `shadow_`）；
      ② `z < z_min` 的贴地贴片（台基凸唇 / 门前石阶）；
      ③ `z > z_max` 的屋面（传建筑的 `eave_h`）；
      ④ `|x| > W/2 + x_margin` 的**屋面侧向挑檐**（超出立面宽度）；
      ⑤ 进深不足 `depth` 的墙面凸出物（窗台/门框，只凸出几单位，不是障碍）。
    返回 [(x0, x1), ...]（外扩 pad；过窄的碎区间丢弃）。
    """
    me = ob.data
    mw = ob.matrix_world
    zhi = float("inf") if z_max is None else float(z_max)
    xl = W / 2.0 + x_margin
    xs = []
    for p in me.polygons:
        mat = me.materials[p.material_index] if p.material_index < len(me.materials) else None
        if mat is not None and "shadow_" in mat.name:
            continue
        for i in p.vertices:
            co = mw @ me.vertices[i].co
            if (co.y < wall_y - depth and z_min < co.z < zhi and abs(co.x) <= xl):
                xs.append(co.x)
    if not xs:
        return []
    xs.sort()
    zones, s, last = [], xs[0], xs[0]
    for x in xs[1:]:
        if x - last > gap:
            zones.append((s, last))
            s = x
        last = x
    zones.append((s, last))
    # 只保留落在立面可铺范围内的区间（屋面侧挑檐等残段在立面之外，避让它们没意义）
    inner = W / 2.0 - 30.0
    keep = [(a - pad, b + pad) for (a, b) in zones
            if b - a >= min_w and b > -inner and a < inner]
    return keep


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
    """建总览条，返回 (objs, 总宽, 摆放清单)。camera_objs 留着给调用方塞火柴人。

    条上按**挂载口径**出图（主尺寸 ×GAME_SCALE×MOUNT_SCALE）—— 1 单位≈1px，所以
    条上的像素尺寸就是游戏里的尺寸；否则小件（沙漏/墨水瓶）在条上比游戏里还大，
    看不出"放大后够不够读"。
    """
    objs, placed, cursor = [], [], 0.0
    for (pname, kw, span) in STRIP:
        b = B.Builder("prop4_%s_%.0f" % (pname, cursor))
        zz = float(kw.get("z", 0.0))
        eff = P.GAME_SCALE * P.mount_scale(pname)
        uspan = span * P.mount_scale(pname)
        if pname in P.FLUSH and zz > 40.0:
            bh = max(WALL_BOARD_H, zz + float(kw.get("h", 60.0)) * eff + 20.0)
            # 墙板用**浅色抹灰**：木色墙板会把木盾/皮革道具整个吃掉（实测盾牌浮雕在
            # 木墙板上完全看不见），抹灰才衬得出深色器物。
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


def add_stickmen(objs, total, n=9, y=-210.0):
    for i in range(n):
        sb = B.Builder("stick4_%d" % i)
        B.stickman(sb, x=0.0, y=y)
        sob = sb.to_object()
        sob.location.x = total * (i + 0.5) / n
        bpy.context.view_layer.update()
        objs.append(sob)


# ---------------------------------------------------------------- 立面实景

#: 需要"绕开装配器自带前场家什"的配方（落地件避让；其余配方地面照铺）。
GROUND_AVOID = ("alchemy",)


def dressed(name, wc, kind, seed, tag, front_y=None, wall_mode="wall"):
    """装一套立面道具。

    `wall_mode`：
      * `"wall"`  —— 挂墙件贴**真实前墙面**（`-spec["depth"]/2`），并按建筑前凸几何
        生成 `reserved` 避让区间（门廊体量 / 出檐 / 装配器自带前场家什）；
      * `"outer"` —— 旧口径：挂墙件按包围盒最外沿（`front_y - 4`），只用于 wallfix 对照。
    """
    ob, spec = B.ASSEMBLERS[name](wc)
    mx = B.measure(ob)
    fy = front_y if front_y is not None else mx["y"][0]
    wall = -spec["depth"] / 2.0
    zones = front_side_zones(ob, wall, spec["grid_w"],
                             z_max=spec.get("eave_h", mx["z"][1]) - 6.0)
    pb = B.Builder("props4_" + tag)
    d = spec.get("door")
    kw = dict(seed=seed, door_x=spec.get("door_x", 0.0),
              door_w=(d[0] if d else 0.0), flush_reserved=zones)
    if kind in GROUND_AVOID:           # 只有"装配器自带前场家什"的配方才避让地面
        kw["reserved"] = zones
    if wall_mode == "outer":
        kw["wall_depth"] = 0.0
    else:
        kw["wall_y"] = wall
    placed = P.dress(pb, kind, spec["grid_w"], fy, **kw)
    pob = pb.to_object()
    return ob, pob, spec, placed, mx


def shoot_facade(cam, name, wc, kind, tag, seed=7, zoom=ZOOM_SCENE, people=2,
                 wall_mode="wall"):
    wipe()
    ob, pob, spec, placed, mx = dressed(name, wc, kind, seed, tag,
                                        wall_mode=wall_mode)
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
    print("   %s(%d) W=%.0f door_x=%.0f door_w=%.1f  包围盒最外沿 y=%.1f  真实墙面 y=%.1f"
          % (name, wc, spec["grid_w"], spec.get("door_x", 0.0),
             (spec["door"][0] if spec.get("door") else 0.0), mx["y"][0],
             -spec["depth"] / 2.0))
    print("   挂载：%s" % (placed,))
    return placed


# ---------------------------------------------------------------- 门廊贴墙对照

#: 对照用例的参数：深门廊装配器 + 用它的配方。
WALLFIX = ("cathedral", 12, "chapel")


def shoot_wallfix(cam, name=None, wc=None, kind=None, zoom=1.30):
    """深门廊立面的**挂墙件贴墙对照**（侧视剖影，新旧并排）。

    侧视（yaw=90°）：屏幕横轴 = 建筑进深 Y、纵轴 = 高度 Z，两栋同款建筑的**侧影剖面**
    沿 Y 错开放置 → 屏幕上并排两条剖面。正交前视看不出这 ~1.5m 的进深差
    （投影只错开 cos20°×127 ≈ 122 单位），侧视才读得出。

    每栋旁边立**两根参照柱**（在立面宽度之外，不挡剖面）：
      * `white_stone` 柱 = 真实前墙面（`-depth/2`）；
      * `brick` 柱 = 建筑包围盒最外沿（门廊/雨棚前缘）。
    左栋 = **旧口径**（挂墙件与 brick 柱齐 → 悬空）；右栋 = **新口径**（与 white_stone
    柱齐 → 贴墙）。挂墙件本身是彩窗板（`stained_glass`），一眼能找到它对齐哪根柱。
    """
    name, wc, kind = name or WALLFIX[0], wc or WALLFIX[1], kind or WALLFIX[2]
    wipe()
    objs = []
    for (ytag, mode) in (("旧：按包围盒最外沿挂（悬空）", "outer"),
                         ("新：贴真实前墙面（wall_y）", "wall")):
        ob, spec = B.ASSEMBLERS[name](wc)
        mx = B.measure(ob)
        wall = -spec["depth"] / 2.0
        zones = front_side_zones(ob, wall, spec["grid_w"],
                                 z_max=spec.get("eave_h", mx["z"][1]) - 6.0)
        pb = B.Builder("wallfix_%s" % mode)
        d = spec.get("door")
        kw = dict(seed=13, door_x=spec.get("door_x", 0.0),
                  door_w=(d[0] if d else 0.0), flush_reserved=zones)
        if mode == "outer":
            kw["wall_depth"] = 0.0
        else:
            kw["wall_y"] = wall
        placed = P.dress(pb, kind, spec["grid_w"], mx["y"][0], **kw)
        # 再补一件**向前挑出**的挂墙件（铁艺挂招牌）：侧视里能看出挑臂是从墙面伸出、
        # 还是从空中伸出 —— 平贴的彩窗板侧看只剩一条线，挑臂才有"挂上了"的读法。
        mount = (mx["y"][0] if mode == "outer" else wall) - 4.0
        put(pb, "hanging_sign", spec["grid_w"] * 0.42, mount, z=150.0,
            w=48.0, h=38.0)
        pob = pb.to_object()
        off = -YSIDE if mode == "outer" else YSIDE    # 屏幕横轴 +Y：旧在左、新在右
        # 参照柱：**墙面**（lamp 自发光黄）/ **包围盒最外沿**（cloth_red 红）。柱高停在
        # 挂墙件下沿以下（彩窗板 z=262 起）—— 既当"色标尺"，又不会挡住彩窗板本身；
        # 柱立在立面宽度之外且在建筑物之前，不被剖面轮廓挡住。看哪根柱正下方就是哪一层。
        rb = B.Builder("wallref_%s" % mode)
        xref = spec["grid_w"] / 2.0 + 90.0
        ztop = 250.0
        rb.box_bottom((24.0, 24.0, ztop), (xref, wall), 0.0, "lamp")
        rb.box_bottom((24.0, 24.0, ztop), (xref, mx["y"][0]), 0.0, "cloth_red")
        rob = rb.to_object()
        rob.location.y = off
        ob.location.y = off
        pob.location.y = off
        bpy.context.view_layer.update()
        objs += [ob, pob, rob]
        add_label("WALL", xref, wall + off, 375.0, size=34.0)
        add_label("EDGE", xref, mx["y"][0] + off, 375.0, size=34.0)
        print("[wallfix] %-28s offset_y=%+7.1f  最外沿=%.1f 墙面=%.1f  挂墙件 y=%s"
              % (ytag, off, mx["y"][0], wall,
                 [p[2] for p in placed if p[0] in P.FLUSH]))
    make_ground(-700.0, 700.0, -YSIDE - 900.0, YSIDE + 900.0)
    proj = shoot_fit(cam, objs, zoom, os.path.join(OUT_DIR, "pbr_props4_wallfix.png"),
                     pad=60.0, pad_top=210.0, yaw=90.0, tilt=6.0)
    # 打印三个平面的**屏幕像素列**，供人对着图核验（u = y，侧视）
    ppx, u0 = proj["ppx"], proj["u0"]
    for (tag, off) in (("旧 outer", -YSIDE), ("新 wall", YSIDE)):
        px = lambda yy: round((yy + off - u0) * ppx)          # noqa: E731
        print("    %s 像素列： EDGE(y=%.0f)=%d   WALL(y=%.0f)=%d"
              % (tag, mx["y"][0], px(mx["y"][0]), wall, px(wall)))


#: wallfix 对照里两栋建筑的 Y 向错位（侧视屏幕横轴）
YSIDE = 620.0


# ---------------------------------------------------------------- 主流程

def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    clear()
    setup_world()
    cam = make_camera()

    focus = [s.strip() for s in os.environ.get("PROPS4_FOCUS", "").split(",") if s.strip()]
    only_focus = os.environ.get("PROPS4_ONLY_FOCUS") == "1"
    only_wallfix = os.environ.get("PROPS4_ONLY_WALLFIX") == "1"

    if only_wallfix:                      # 只迭代 wallfix 对照图（秒级）
        shoot_wallfix(cam)
        print("\nPROPS4_PROBE_OK")
        return

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

        # 2) 炼金坊立面（真实装配器 alchemy(12) + `alchemy` 配方：只补空位）
        shoot_facade(cam, "alchemy", 12, "alchemy", "pbr_props4_alchemy", seed=11)

        # 3) 教堂立面（cathedral(12) + `chapel` 配方：彩窗板贴真实前墙面 / 祭坛 / 烛架）
        shoot_facade(cam, "cathedral", 12, "chapel", "pbr_props4_chapel", seed=13)

        # 3b) 深门廊挂墙件贴墙对照（侧视剖影：旧=悬空，新=贴墙）
        shoot_wallfix(cam)

    # 4) 诊断用高清条：PROPS4_FOCUS="alembic,glass_crate" 只出这几件（3.4 px/单位）
    if focus:
        wipe()
        fobjs, cursor = [], 0.0
        for pname in focus:
            kw = dict(next((k for (n, k, _s) in STRIP if n == pname), {}))
            span = next((s for (n, _k, s) in STRIP if n == pname), 120.0)
            span = max(span, 90.0) * P.mount_scale(pname)
            eff = P.GAME_SCALE * P.mount_scale(pname)
            b = B.Builder("focus_%s" % pname)
            zz = float(kw.get("z", 0.0))
            if pname in P.FLUSH and zz > 40.0:
                bh = max(WALL_BOARD_H, zz + float(kw.get("h", 60.0)) * eff + 20.0)
                b.box_bottom((span - 10.0, 14.0, bh), (0.0, 7.0), 0.0, "plaster")
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
            cursor += span
        add_stickmen(fobjs, cursor, n=4)
        make_ground(-260.0, cursor + 260.0, -520.0, 520.0)
        shoot_fit(cam, fobjs, 3.4, os.path.join(OUT_DIR, "pbr_props4_focus.png"),
                  pad=60.0, pad_top=20.0)

    print("\nPROPS4_PROBE_OK")


if __name__ == "__main__":
    main()
