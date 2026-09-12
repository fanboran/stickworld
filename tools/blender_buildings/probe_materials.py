# -*- coding: utf-8 -*-
"""材质样片总表：每个材质渲一块 400x300px 等效立面样片 + 一个转 20° 的方块（看几何转折处的表现），
拼成一张大图，并额外输出一张 25% 小图做"缩到游戏尺寸是否还认得出"自检。

跑法:
    blender -b --factory-startup -P probe_materials.py
    blender -b --factory-startup -P probe_materials.py -- brick stone   # 只渲指定材质（迭代用）

尺度：1 Blender 单位 = 1 格 = 32px。渲染 100% 时样片恰为 400x300px（= 游戏内建筑量级）。
光照：文档 §5.2（太阳左上前 仰角 50°/方位 -35° 暖白 3.2；右侧冷蓝补光；天空冷蓝环境 + 地面暖棕）。
"""
import bpy
import bmesh
import math
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() \
    else r"F:/VSCode/game-2/.temp/building-pipeline-v2/tools/blender_buildings"
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import materials as M  # noqa: E402

OUT = "F:/VSCode/game-2/.temp/building-pipeline-v2/stick-world/temp/pbr_materials.png"
OUT_SMALL = "F:/VSCode/game-2/.temp/building-pipeline-v2/stick-world/temp/pbr_materials_25pct.png"

PXU = M.PX_PER_UNIT          # 32 px / 单位
SW, SH = 400, 300            # 样片像素（= 12.5 x 9.375 单位）
PW, PH = SW / PXU, SH / PXU  # 样片世界尺寸（单位）
CUBE = 1.75                  # 方块边长（单位）= 56px
COLS = 4
GAP_X, GAP_Y = 2.2, 1.9      # 单元格间距（单位）
MARGIN = 0.8
LABEL_H = 0.55

# 展示顺序（每行 4 个）
SHEET = ['thatch', 'thatch_old', 'tile_roof', 'slate_roof',
         'plank_wall', 'timber', 'plaster', 'stone',
         'brick', 'iron', 'white_stone', 'canvas']

# 装配时的默认 Wear（越旧越脏）
DEFAULT_WEAR = {'thatch': 0.30, 'thatch_old': 0.85, 'tile_roof': 0.45, 'slate_roof': 0.55,
                'plank_wall': 0.40, 'timber': 0.45, 'plaster': 0.45, 'stone': 0.50,
                'white_stone': 0.25, 'brick': 0.55, 'iron': 0.40, 'canvas': 0.45}


# ------------------------------------------------------------------ 场景
def clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def mesh_plane(name, w, h):
    """真实顶点尺寸的竖直面（面向 -Y），不打物体缩放，便于 UV 世界投影。"""
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_grid(bm, x_segments=1, y_segments=1, size=1.0)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(ob)
    ob.scale = (w / 2.0, h / 2.0, 1.0)   # create_grid(size=1) 是 ±1 → 乘 w/2 得到 w×h
    ob.rotation_euler = (math.radians(90), 0, 0)
    bpy.context.view_layer.update()
    bpy.ops.object.select_all(action='DESELECT')
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
    return ob


def mesh_cube(name, size):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(ob)
    ob.scale = (size, size, size)
    return ob


def assign(ob, mat):
    ob.data.materials.clear()
    ob.data.materials.append(mat)


def label(text, loc, size=LABEL_H):
    bpy.ops.object.text_add(location=loc, rotation=(math.radians(90), 0, 0))
    ob = bpy.context.object
    ob.name = "lbl_" + text
    ob.data.body = text
    ob.data.size = size
    ob.data.align_x = 'CENTER'
    ob.data.align_y = 'CENTER'
    if "mat_label" not in bpy.data.materials:
        m = bpy.data.materials.new("mat_label")
        nt = m.node_tree
        nt.nodes.clear()
        o = nt.nodes.new('ShaderNodeOutputMaterial')
        e = nt.nodes.new('ShaderNodeEmission')
        e.inputs[0].default_value = (0.92, 0.94, 0.98, 1.0)
        e.inputs[1].default_value = 1.0
        nt.links.new(e.outputs[0], o.inputs['Surface'])
    assign(ob, bpy.data.materials["mat_label"])
    return ob


def add_sun(name, elev, azim, energy, color, angle_deg=3.0):
    d = bpy.data.lights.new(name, 'SUN')
    d.energy = energy
    d.color = color[:3]
    d.angle = math.radians(angle_deg)
    d.use_shadow = True
    ob = bpy.data.objects.new(name, d)
    bpy.context.collection.objects.link(ob)
    ob.rotation_euler = (math.radians(90.0 - elev), 0.0, math.radians(azim))
    return ob


def setup_world():
    w = bpy.data.worlds.new("sky")
    bpy.context.scene.world = w
    w.use_nodes = True
    nt = w.node_tree
    nt.nodes.clear()
    out = nt.nodes.new('ShaderNodeOutputWorld')
    bg = nt.nodes.new('ShaderNodeBackground')
    nt.links.new(bg.outputs[0], out.inputs['Surface'])
    tc = nt.nodes.new('ShaderNodeTexCoord')
    sep = nt.nodes.new('ShaderNodeSeparateXYZ')
    nt.links.new(tc.outputs['Generated'], sep.inputs[0])
    mr = nt.nodes.new('ShaderNodeMapRange')
    nt.links.new(sep.outputs[2], mr.inputs[0])
    mr.inputs[1].default_value = -1.0
    mr.inputs[2].default_value = 1.0
    mr.inputs[3].default_value = 0.0
    mr.inputs[4].default_value = 1.0
    ramp = nt.nodes.new('ShaderNodeValToRGB')
    nt.links.new(mr.outputs[0], ramp.inputs[0])
    ramp.color_ramp.elements[0].position = 0.0
    ramp.color_ramp.elements[0].color = (0.34, 0.29, 0.24, 1.0)   # 地面暖棕反射
    ramp.color_ramp.elements[1].position = 1.0
    ramp.color_ramp.elements[1].color = (0.62, 0.70, 0.82, 1.0)   # 天空冷蓝（文档 §5.2）
    e = ramp.color_ramp.elements.new(0.40)
    e.color = (0.60, 0.585, 0.545, 1.0)   # 地平线中性偏暖：避免暖色材质被蓝环境洗成橄榄
    nt.links.new(ramp.outputs[0], bg.inputs[0])
    bg.inputs[1].default_value = 0.60     # 环境强度（文档 0.8~1.0 会压掉对比）
    return w


def setup_render(sheet_w, sheet_h, zoom=1.0, raytracing=True):
    sc = bpy.context.scene
    sc.render.engine = 'BLENDER_EEVEE'
    sc.render.resolution_x = int(round(sheet_w * PXU * zoom))
    sc.render.resolution_y = int(round(sheet_h * PXU * zoom))
    sc.render.resolution_percentage = 100
    sc.render.image_settings.file_format = 'PNG'
    sc.render.image_settings.color_mode = 'RGBA'
    sc.render.film_transparent = False          # 样片表要背景便于判断明度
    sc.view_settings.view_transform = 'Standard'
    sc.view_settings.look = 'None'
    sc.view_settings.exposure = 0.0
    try:
        sc.eevee.taa_render_samples = 64
        sc.eevee.use_shadows = True
        sc.eevee.use_raytracing = bool(raytracing)
        sc.eevee.ray_tracing_options.use_denoise = True
    except Exception as e:
        print("eevee setup warn:", e)
    # 正交相机，正对（横向 12.5 单位 = 400px 对应游戏内 1 格 = 32px）
    cam_data = bpy.data.cameras.new("cam")
    cam_data.type = 'ORTHO'
    cam_data.ortho_scale = sheet_w / zoom
    cam_data.clip_start = 0.1
    cam_data.clip_end = 200.0
    cam = bpy.data.objects.new("cam", cam_data)
    bpy.context.collection.objects.link(cam)
    cam.location = (0.0, -40.0, 0.0)
    cam.rotation_euler = (math.radians(90), 0, 0)
    sc.camera = cam
    return cam


# ------------------------------------------------------------------ 装配
def build(only=None, zoom=1.0, solo=False, raytracing=True):
    clear()
    del RECTS[:]
    keys = [k for k in SHEET if (not only or k in only)]
    n = len(keys)
    cols = max(1, min(COLS, n))
    rows = int(math.ceil(n / float(cols))) if n else 1
    cell_w = PW + CUBE + GAP_X if not solo else PW + GAP_X * 0.6
    cell_h = PH + LABEL_H + GAP_Y * 0.5 if not solo else PH + GAP_Y * 0.5
    sheet_w = MARGIN * 2 + cell_w * cols
    sheet_h = MARGIN * 2 + cell_h * rows
    x0 = -sheet_w / 2.0 + MARGIN
    z0 = sheet_h / 2.0 - MARGIN

    built = []
    for i, key in enumerate(keys):
        cx = i % cols
        cz = i // cols
        px_ = x0 + cx * cell_w
        pz_ = z0 - cz * cell_h
        wear = DEFAULT_WEAR.get(key, 0.45)
        mat = M.make(key, wear=wear)
        # 立面样片
        pl = mesh_plane("sw_" + key, PW, PH)
        pl.location = (px_ + PW / 2.0, 0.0, pz_ - PH / 2.0)
        assign(pl, mat)
        M.box_project_uv(pl)
        if not solo:
            # 方块（绕 Z 转 20°，看两个面的光照/材质转折）；贴单元格右下，阴影落进空档
            cb = mesh_cube("cube_" + key, CUBE)
            cb.location = (px_ + PW + CUBE * 0.5 + GAP_X * 0.30, -1.0, pz_ - PH + CUBE * 0.5)
            cb.rotation_euler = (0.0, 0.0, math.radians(20))
            assign(cb, mat)
            bpy.context.view_layer.update()
            M.box_project_uv(cb)
            label(key.replace("_", " "), (px_ + PW / 2.0, -0.2, pz_ - PH - LABEL_H * 0.9))
        built.append(key)
        print("  + {:12s} {}  wear={}".format(key, M._BUILDERS[key][1], wear))
        # 记录样片在最终渲染图中的像素矩形（供尺度自检）
        RECTS.append((key,
                      (px_ + sheet_w / 2.0) * PXU * zoom,
                      (sheet_h / 2.0 - pz_) * PXU * zoom,
                      PW * PXU * zoom, PH * PXU * zoom))

    setup_world()
    add_sun("key", 50.0, -35.0, 3.2, (1.0, 0.95, 0.85), 3.0)
    add_sun("fill", 25.0, 30.0, 0.42, (0.62, 0.70, 0.82), 25.0)
    setup_render(sheet_w, sheet_h, zoom, raytracing)
    return built


# 尺度规范（px @ 1 格 = 32px），用于自检"纹理尺度是否与平面尺寸匹配"
SPEC_PX = {
    'brick':       dict(h=(16, 24), v=(8, 12)),
    'stone':       dict(h=(20, 40), v=(12, 24)),
    'white_stone': dict(h=(12, 22), v=(7, 14)),
    'plank_wall':  dict(h=None, v=(16, 22)),
    'timber':      dict(h=None, v=None),
    'tile_roof':   dict(h=(8, 14), v=(8, 13)),
    'slate_roof':  dict(h=(10, 17), v=(9, 14)),
    'thatch':      dict(h=None, v=(14, 18)),
    'thatch_old':  dict(h=None, v=(14, 18)),
    'canvas':      dict(h=(1.5, 4), v=(1.5, 4)),
    'plaster':     dict(h=None, v=None),
    'iron':        dict(h=None, v=None),
}

RECTS = []      # (key, x_px, y_top_px, w_px, h_px) —— 用于尺度自检


def measure(path, zoom):
    """自检：对每块样片做自相关，估计纹理周期（px@1x），与 SPEC_PX 对照。"""
    try:
        import numpy as np
    except Exception as e:
        print("measure skip:", e)
        return
    img = bpy.data.images.load(path)
    w, h = img.size
    buf = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(buf)
    a = buf.reshape(h, w, 4)[::-1]                 # 转 top-down
    print("\n=== 尺度自检（自相关主周期，px@1x）===")
    print("{:12s} {:>10s} {:>10s}   {}".format("材质", "横向周期", "纵向周期", "规范(横/纵)"))
    for key, x, y, cw_, chh_ in RECTS:
        x, y, cw_, chh_ = int(x), int(y), int(cw_), int(chh_)
        if cw_ < 8 or chh_ < 8:
            continue
        g = a[y:y + chh_, x:x + cw_, :3].mean(axis=2)
        # 逐行/逐列各自求自相关再平均 —— 这样"错缝"（上下行缝相位不同）不会把周期抵消掉
        ph = _period_multi(g[::3, :], zoom)
        pv = _period_multi(g[:, ::3].T, zoom)
        sp = SPEC_PX.get(key, {})
        tgt = "{}/{}".format(sp.get('h'), sp.get('v'))
        print("{:12s} {:>10s} {:>10s}   {}".format(
            key,
            "-" if ph is None else "{:.1f}".format(ph),
            "-" if pv is None else "{:.1f}".format(pv),
            tgt))
    bpy.data.images.remove(img)


def _period_multi(rows, zoom, lo_px=1.5, hi_px=170.0):
    """对多条 1D 信号各自求自相关再平均，取平均自相关的最强峰 → 纹理主周期(px@1x)。

    逐行平均自相关（而非先平均信号）才能保住"错缝砌法"的周期。
    """
    import numpy as np
    arr = np.asarray(rows, dtype=np.float64)
    if arr.ndim == 1:
        arr = arr[None, :]
    if arr.shape[1] < 32:
        return None
    lo = max(2, int(lo_px * zoom))
    hi = min(arr.shape[1] - 2, int(hi_px * zoom))
    if hi <= lo + 2:
        return None
    acc = None
    n = 0
    for r in arr:
        s = r - r.mean()
        if np.allclose(s, 0):
            continue
        ac = np.correlate(s, s, mode='full')[s.size - 1:]
        if ac[0] <= 0:
            continue
        ac = ac / ac[0]
        acc = ac if acc is None else acc + ac
        n += 1
    if acc is None or n == 0:
        return None
    acc /= n
    pk = [i for i in range(lo, hi)
          if acc[i] >= acc[i - 1] and acc[i] > acc[i + 1] and acc[i] > 0.12]
    if not pk:
        return None
    best = max(pk, key=lambda i: acc[i])
    return best / float(zoom)


def _period(sig, zoom, lo_px=1.5, hi_px=170.0):
    """自相关最强峰的滞后（px@1x）——取最强而非第一个，避免被木纹等高频细节抢先。"""
    import numpy as np
    s = np.asarray(sig, dtype=np.float64)
    if s.size < 32:
        return None
    s = s - s.mean()
    if np.allclose(s, 0):
        return None
    ac = np.correlate(s, s, mode='full')[s.size - 1:]
    lo = max(2, int(lo_px * zoom))
    hi = min(s.size - 2, int(hi_px * zoom))
    if hi <= lo + 2:
        return None
    pk = [i for i in range(lo, hi)
          if ac[i] >= ac[i - 1] and ac[i] > ac[i + 1] and ac[i] > 0.10 * ac[0]]
    if not pk:
        return None
    best = max(pk, key=lambda i: ac[i])
    return best / float(zoom)


def render_and_scale(tag="", zoom=1.0, do_measure=True):
    sc = bpy.context.scene
    out = OUT if not tag else OUT.replace(".png", "_" + tag + ".png")
    out_small = OUT_SMALL if not tag else OUT_SMALL.replace(".png", "_" + tag + ".png")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    sc.render.filepath = out
    bpy.ops.render.render(write_still=True)
    print("SHEET ->", out, sc.render.resolution_x, "x", sc.render.resolution_y)
    if sc.render.resolution_x > 4000 or sc.render.resolution_y > 4000:
        return
    img = bpy.data.images.load(out)
    w, h = img.size
    img.scale(max(1, w // 4), max(1, h // 4))
    img.filepath_raw = out_small
    img.file_format = 'PNG'
    img.save()
    print("SMALL ->", out_small, w // 4, "x", h // 4)
    bpy.data.images.remove(img)
    if do_measure:
        measure(out, zoom)


def main():
    argv = sys.argv
    only = None
    zoom = 1.0
    tag = ""
    solo = False
    nort = False
    if "--" in argv:
        args = argv[argv.index("--") + 1:]
        i = 0
        names = []
        while i < len(args):
            a = args[i]
            if a == "--zoom" and i + 1 < len(args):
                zoom = float(args[i + 1])
                i += 2
                continue
            if a == "--tag" and i + 1 < len(args):
                tag = args[i + 1]
                i += 2
                continue
            if a == "--solo":
                solo = True
                i += 1
                continue
            if a == "--nort":
                nort = True
                i += 1
                continue
            if not a.startswith("-"):
                names.append(a)
            i += 1
        only = names or None
        if only:
            bad = [k for k in only if k not in M._BUILDERS]
            if bad:
                print("未知材质:", bad)
                return
    print("=== 材质样片总表 (zoom={}, solo={}) ===".format(zoom, solo))
    built = build(only, zoom, solo, not nort)
    print("材质数:", len(built))
    render_and_scale(tag if not solo else (tag or "solo"), zoom, do_measure=not solo)


if __name__ == "__main__":
    main()
