# -*- coding: utf-8 -*-
"""probe_nature.py —— 野外自然物验收图（管线 v3 · 写实 PBR）

产物（stick-world/temp/）::
    pbr_nature_strip.png    全部自然物总览条（**每件旁并排火柴人同尺度剪影**）
    pbr_nature_forest.png   森林小景（真实分布场里切出的一个林簇核心→林缘切片）
    pbr_nature_ore.png      矿脉带场景（岩体 → 散矿 → 碎石过渡）
    pbr_field_dist.png      野外资源分布总览（成组—过渡—留白，带地平线与地面）
    pbr_field_dist_plan.png 俯视分布图（field_dist 直出；把密度衰减/留白画出来）
    pbr_nature_focus.png    NATURE_FOCUS=名,名 时的单件高清条（排查"像电线杆"用）

跑法::
    blender -b --factory-startup -P probe_nature.py
    NATURE_FOCUS=broadleaf,conifer blender -b --factory-startup -P probe_nature.py
"""

import math
import os
import sys

import bpy
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import buildings as B       # noqa: E402
import nature as N          # noqa: E402   （import 时即注入材质解析器）
import field_dist as FD     # noqa: E402

OUT_DIR = "F:/VSCode/game-2/.temp/building-pipeline-v2/stick-world/temp"
YAW = 0.0
TILT = 20.0
SEED = 20260913
ORE_KINDS = ("iron_outcrop", "copper_vein", "gold_vein", "crystal_cluster",
             "ore_band", "rubble")


# ---------------------------------------------------------------- 场景

def clear():
    """**只在开头调用一次**（§六 踩坑：中途 read_factory_settings 会让材质缓存失效）。"""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    B._CACHE.clear()
    try:
        import materials as M
        M.reset_cache()
    except Exception:
        pass
    N.install_materials()


def wipe():
    for ob in list(bpy.data.objects):
        if ob.type == "MESH":
            bpy.data.objects.remove(ob, do_unlink=True)


def setup_world():
    """天光渐变（地平线暖白 / 天顶冷蓝）+ 三光源 + 合成器辉光（晶簇/炉火要有光晕）。"""
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
        print("[nature] 合成器辉光不可用：%s" % exc)

    w = bpy.data.worlds.new("W")
    sc.world = w
    w.use_nodes = True
    nt = w.node_tree
    bg = nt.nodes.get("Background") or nt.nodes.new("ShaderNodeBackground")
    bg.inputs[1].default_value = 0.62
    tc = nt.nodes.new("ShaderNodeTexCoord")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (0.76, 0.78, 0.74, 1.0)     # 地平线：暖白
    ramp.color_ramp.elements[1].color = (0.40, 0.54, 0.78, 1.0)     # 天顶：冷蓝
    nt.links.new(tc.outputs["Generated"], sep.inputs["Vector"])
    nt.links.new(sep.outputs["Z"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], bg.inputs[0])

    def sun(name, energy, rot, angle=3.0, color=(1.0, 0.95, 0.85)):
        d = bpy.data.lights.new(name, "SUN")
        d.energy = energy
        d.angle = math.radians(angle)
        d.color = color
        ob = bpy.data.objects.new(name, d)
        ob.rotation_euler = tuple(math.radians(a) for a in rot)
        sc.collection.objects.link(ob)

    sun("key", 3.4, (42, 0, -34), 2.5, (1.0, 0.93, 0.80))
    sun("fill", 0.24, (58, 0, 126), 20.0, (0.80, 0.87, 1.0))
    sun("bounce", 0.32, (-26, 0, 6), 45.0, (0.95, 0.80, 0.62))


def make_ground(x0, x1, y0, y1):
    """地面：**用 Builder 拼四边形**，自动拿到 UV = 世界/32 → 既有 `ground` 材质
    就是世界空间程序纹理（from_pydata 拼的面没有 UV，会得到一片平涂死白——踩过）。"""
    b = B.Builder("ground")
    b.poly([(x0, y0, 0.0), (x1, y0, 0.0), (x1, y1, 0.0), (x0, y1, 0.0)], "ground",
           outward=(0.0, 0.0, 1.0))
    return b.to_object()


def make_camera():
    d = bpy.data.cameras.new("cam")
    d.type = "ORTHO"
    d.clip_start = 1.0
    d.clip_end = 90000.0
    ob = bpy.data.objects.new("cam", d)
    bpy.context.scene.collection.objects.link(ob)
    bpy.context.scene.camera = ob
    return ob


def place_camera(cam, anchor, dist=20000.0):
    right, up = B.cam_axes(YAW, TILT)
    fwd = -(right.cross(up))
    cam.location = tuple(Vector(anchor) - fwd * dist)
    cam.rotation_euler = (math.radians(90.0 - TILT), 0.0, math.radians(YAW))


def shoot_fit(cam, objs, zoom, path, pad=40.0, pad_top=30.0, res_max=9000,
              extra_pts=()):
    """按内容取景；`extra_pts` 用来把**地平线（地面远边）**拉进画面。"""
    pts = []
    for ob in objs:
        pts += B.shape_points(ob, skip_ground=False)
    pts += [Vector(p) for p in extra_pts]
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
    print("-> %s  %dx%d  (%.3f px/unit)" % (os.path.basename(path), rx, ry, zoom * k))
    return {"path": path, "res": (rx, ry)}


# ---------------------------------------------------------------- 总览条

#: (类型, kwargs, seed)。分类相邻：乔木 → 地被 → 矿岩。每件右侧配一个火柴人。
STRIP = [
    ("broadleaf", {}, 3),
    ("broadleaf_tall", {}, 11),
    ("conifer", {}, 21),
    ("dead_tree", dict(leaves=2), 31),
    ("stump", {}, 41),
    ("bush", {}, 51),
    ("reeds", {}, 61),
    ("grass_clump", {}, 71),
    ("mushrooms", dict(log=True), 81),
    ("crystal_cluster", {}, 91),
    ("gold_vein", {}, 101),
    ("copper_vein", {}, 111),
    ("iron_outcrop", {}, 121),
    ("ore_band", dict(ln=8.0, angle=0.22), 131),
    ("rubble", {}, 141),
    ("boulder", {}, 151),
]

STICK_SLOT = 250.0


def span_of(kind, kw):
    w, h, r = N.NOMINAL.get(kind, (2.0, 1.5, 1.0))
    if kind == "ore_band":
        w = kw.get("ln", 8.0)
    return max(w * N.M * 1.16, 90.0)


def build_strip(entries, seed0=0):
    b = B.Builder("nature_strip")
    cursor = 0.0
    placed = []
    for (kind, kw, sd) in entries:
        span = span_of(kind, kw)
        N.place(b, kind, x=cursor + span * 0.5, y=0.0, z=0.0,
                seed=sd + seed0, **kw)
        placed.append((kind, cursor + span * 0.5, span))
        cursor += span + STICK_SLOT
    return b, cursor, placed


def build_stickmen(cursor, n=9, name="sticks"):
    """在总览条上等距插 n 个火柴人（同尺度比例尺）。每个单独一个对象便于摆位。"""
    objs = []
    for i in range(n):
        s = B.Builder("%s_%d" % (name, i))
        B.stickman(s, x=0.0, y=-40.0)
        o = s.to_object()
        o.location.x = cursor * (i + 0.5) / float(n)
        bpy.context.view_layer.update()
        objs.append(o)
    return objs


def shoot_strip(cam):
    wipe()
    entries = STRIP
    focus = [s.strip() for s in os.environ.get("NATURE_FOCUS", "").split(",") if s.strip()]
    tag = "pbr_nature_strip"
    if focus:
        entries = [(k, dict(next((kw for (n2, kw, _s) in STRIP if n2 == k), {})), i * 13)
                   for i, k in enumerate(focus)]
        tag = "pbr_nature_focus"
    b, cursor, placed = build_strip(entries)
    ob = b.to_object()
    objs = [ob] + build_stickmen(cursor)
    make_ground(-500.0, cursor + 500.0, -1000.0, 1100.0)
    shoot_fit(cam, objs, 1.55 if focus else 0.62,
              os.path.join(OUT_DIR, tag + ".png"), pad=50.0, pad_top=40.0)
    print("[strip] %d 件，总宽 %.0f 单位" % (len(placed), cursor))
    for (k, x, sp) in placed:
        print("   %-16s x=%8.1f  span=%6.1f" % (k, x, sp))


# ---------------------------------------------------------------- 分布切景

def gen():
    return FD.generate(seed=SEED)


def cluster_slice(g, ci=0, half_x=2700.0, back=1700.0, front=900.0,
                  drop_ore=True):
    c = g["clusters"][ci]
    x0, x1 = c["cx"] - half_x, c["cx"] + half_x
    y0, y1 = c["cy"] - front, c["cy"] + back
    out = []
    for i in FD.window(g, x0, x1, y0, y1):
        if drop_ore and i["kind"] in ORE_KINDS:
            continue
        out.append(i)
    return out, (x0, x1, y0, y1)


def band_slice(g, ore="iron", half_x=2000.0, back=1700.0, front=1200.0):
    bd = next(b for b in g["bands"] if b["ore"] == ore)
    (ax, ay), (bx, by) = bd["p0"], bd["p1"]
    cx, cy = (ax + bx) * 0.5, (ay + by) * 0.5
    x0, x1 = cx - half_x, cx + half_x
    y0, y1 = cy - front, cy + back
    out = list(FD.window(g, x0, x1, y0, y1))
    return out, (x0, x1, y0, y1)


def build_instances(insts, name, lod_far_y=None, far_lod="simple"):
    """把实例列表写进一个 Builder（远排可选降级 LOD）。返回 (objs, 计数)。"""
    b = B.Builder(name)
    used = []
    for it in insts:
        lod = "full"
        if lod_far_y is not None and it["y"] > lod_far_y:
            lod = far_lod
        N.place(b, it["kind"], x=it["x"], y=it["y"], z=0.0, seed=it["seed"],
                scale=it["s"], lod=lod)
        used.append(it)
    return [b.to_object()], used


#: 林下地被：把"树排 + 光秃地面"补成"林床"（确定性 seed；属于场景 dressing，
#: 与 city 场景的"空 lot 内容物"同一手法，不改分布数据）
FOREST_FLOOR = [
    ("grass_clump", 0.04, 0.11), ("grass_clump", 0.11, 0.16),
    ("grass_clump", 0.19, 0.08), ("grass_clump", 0.27, 0.14),
    ("grass_clump", 0.35, 0.10), ("grass_clump", 0.43, 0.17),
    ("grass_clump", 0.51, 0.09), ("grass_clump", 0.59, 0.15),
    ("grass_clump", 0.67, 0.11), ("grass_clump", 0.75, 0.16),
    ("grass_clump", 0.83, 0.08), ("grass_clump", 0.91, 0.14),
    ("grass_clump", 0.15, 0.21), ("grass_clump", 0.47, 0.22),
    ("grass_clump", 0.79, 0.20),
    ("reeds", 0.24, 0.05), ("reeds", 0.70, 0.05), ("reeds", 0.55, 0.19),
    ("bush", 0.12, 0.06), ("bush", 0.44, 0.12), ("bush", 0.86, 0.10),
    ("bush", 0.32, 0.18), ("bush", 0.66, 0.20),
    ("mushrooms", 0.52, 0.05), ("mushrooms", 0.28, 0.12), ("mushrooms", 0.90, 0.21),
    ("rubble", 0.38, 0.10), ("rubble", 0.60, 0.22), ("boulder", 0.90, 0.16),
]


def dress_forest_floor(b, rect, seed=17):
    x0, x1, y0, y1 = rect
    for i, (kind, fx, fy) in enumerate(FOREST_FLOOR):
        N.place(b, kind, x=x0 + (x1 - x0) * fx, y=y0 + (y1 - y0) * fy,
                z=0.0, seed=seed * 100 + i * 7)
    return len(FOREST_FLOOR)


def shoot_forest(cam):
    wipe()
    g = gen()
    insts, rect = cluster_slice(g, ci=0)
    objs, used = build_instances(insts, "forest_inst")
    fb = B.Builder("forest_floor")
    ndress = dress_forest_floor(fb, rect)
    objs = objs + [fb.to_object()]
    x0, x1, y0, y1 = rect
    gx0, gx1 = x0 - 900.0, x1 + 900.0
    gy0, gy1 = y0 - 1100.0, y1 + 900.0
    make_ground(gx0, gx1, gy0, gy1)
    # 前景比例尺（3 个火柴人，站在林缘）
    st = []
    for i, fx in enumerate((0.30, 0.52, 0.72)):
        s = B.Builder("fstick_%d" % i)
        B.stickman(s, x=0.0, y=0.0)
        o = s.to_object()
        o.location = (x0 + (x1 - x0) * fx, y0 + 260.0, 0.0)
        bpy.context.view_layer.update()
        st.append(o)
    shoot_fit(cam, objs + st, 1.15, os.path.join(OUT_DIR, "pbr_nature_forest.png"),
              pad=70.0, pad_top=40.0, extra_pts=[(gx0, gy1, 0.0), (gx1, gy1, 0.0)])
    print("[forest] 分布 %d 件（树 %d）+ 林床 dressing %d 件" % (
        len(used), sum(1 for i in used if i["kind"] in FD.TREE_KINDS), ndress))


#: 矿脉场景里补的"矿物组合"：(类型, x 比例, y 比例, seed)——铜/金/水晶只在各自
#: 的带里，单切一条铁矿带看不到它们；这里并置进来（一张"矿物总览"）。
ORE_EXTRA = [("copper_vein", 0.80, 0.30, 5), ("copper_vein", 0.88, 0.20, 9),
             ("gold_vein", 0.65, 0.16, 13), ("gold_vein", 0.72, 0.34, 21),
             ("crystal_cluster", 0.93, 0.40, 33), ("crystal_cluster", 0.55, 0.30, 41),
             ("boulder", 0.30, 0.42, 51), ("rubble", 0.42, 0.34, 61)]


def shoot_ore(cam):
    wipe()
    g = gen()
    insts, rect = band_slice(g, ore="iron")
    objs, used = build_instances(insts, "ore_inst")
    x0e, x1e, y0e, y1e = rect
    eb = B.Builder("ore_extra")
    for i, (kind, fx, fy, sd) in enumerate(ORE_EXTRA):
        N.place(eb, kind, x=x0e + (x1e - x0e) * fx, y=y0e + (y1e - y0e) * fy,
                z=0.0, seed=sd * 13)
    objs = objs + [eb.to_object()]
    x0, x1, y0, y1 = rect
    make_ground(x0 - 800.0, x1 + 800.0, y0 - 1100.0, y1 + 900.0)
    st = []
    for i, fx in enumerate((0.42, 0.66)):
        s = B.Builder("ostick_%d" % i)
        B.stickman(s, x=0.0, y=0.0)
        o = s.to_object()
        o.location = (x0 + (x1 - x0) * fx, y0 + 320.0, 0.0)
        bpy.context.view_layer.update()
        st.append(o)
    shoot_fit(cam, objs + st, 1.25, os.path.join(OUT_DIR, "pbr_nature_ore.png"),
              pad=70.0, pad_top=40.0,
              extra_pts=[(x0 - 800.0, y1 + 900.0, 0.0), (x1 + 800.0, y1 + 900.0, 0.0)])
    print("[ore] 分布 %d 件（矿 %d）+ 矿物组合 %d 件" % (
        len(used), sum(1 for i in used if i["kind"] in ORE_KINDS), len(ORE_EXTRA)))


def shoot_field(cam):
    """野外资源分布总览：整片区域 + 地平线 + 地面；远排降级 LOD。"""
    wipe()
    g = gen()
    insts = list(g["instances"])
    reg = g["region"]
    ymid = (reg["y"][0] + reg["y"][1]) * 0.5
    objs, used = build_instances(insts, "field_inst", lod_far_y=ymid)
    x0, x1 = reg["x"]
    gy1 = reg["y"][1] + 1100.0
    make_ground(x0 - 1200.0, x1 + 1200.0, reg["y"][0] - 1600.0, gy1)
    st = []
    for i, fx in enumerate((0.14, 0.34, 0.55, 0.78)):
        s = B.Builder("fldstick_%d" % i)
        B.stickman(s, x=0.0, y=0.0)
        o = s.to_object()
        o.location = (x0 + (x1 - x0) * fx, reg["y"][0] + 380.0, 0.0)
        bpy.context.view_layer.update()
        st.append(o)
    shoot_fit(cam, objs + st, 0.235, os.path.join(OUT_DIR, "pbr_field_dist.png"),
              pad=90.0, pad_top=50.0,
              extra_pts=[(x0 - 1200.0, gy1, 0.0), (x1 + 1200.0, gy1, 0.0)],
              res_max=5200)
    stt = g["stats"]
    print("[field] %d 件（树 %d）  四分格离散指数 %.2f  空格 %.0f%%  最近邻CV %.2f"
          % (stt["n_total"], stt["n_trees"], stt["quadrat_index"],
             stt["quadrat_empty"] * 100, stt["nn_cv"]))
    # 俯视分布图（field_dist 直出，作为"非均匀"的直接证据）
    r = FD.plan_png(g, os.path.join(OUT_DIR, "pbr_field_dist_plan.png"))
    if r.get("path"):
        print("-> %s  %dx%d" % (os.path.basename(r["path"]),
                                r["res"][0], r["res"][1]))


# ---------------------------------------------------------------- 主流程

def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    clear()
    setup_world()
    cam = make_camera()
    only = [x.strip() for x in os.environ.get("NATURE_ONLY", "").split(",") if x.strip()]
    foc = os.environ.get("NATURE_FOCUS")

    def want(name):
        return (not only and not foc) or name in only

    if want("strip") or foc:
        shoot_strip(cam)
    if want("forest"):
        shoot_forest(cam)
    if want("ore"):
        shoot_ore(cam)
    if want("field"):
        shoot_field(cam)
    print("\nNATURE_PROBE_OK")


main()
