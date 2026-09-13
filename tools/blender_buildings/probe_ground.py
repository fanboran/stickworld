# -*- coding: utf-8 -*-
"""probe_ground.py —— 地面可平铺贴图成图（建筑管线 v3）

做什么
------
把 `ground_tiles.py` 生成的 12 种地面贴图**渲染成图看观感**，四张：

    pbr_ground_sheet.png    全部 1×1 高清档（512）对照 + 名称 + 无缝自检比值
    pbr_ground_seam.png     每种 3×3 接缝检查（128 游戏档，1:1 texel:pixel）
    pbr_ground_game1x.png   12 种 ×「游戏内真实大小（128px）1:1」+「放大 2×」两带
    pbr_ground_street.png   街景应用演示：鹅卵石主街 + 砖铺门廊 + 木栈道 +
                            巷道土路（车辙），后景 `buildings.py` 现成 3 栋

渲染路径（与建筑管线同一套纪律）
--------------------------------
* **俯视正交**：相机在 +Z 垂直向下（`tilt=90`），1 世界单位 = 1px；贴图平面恰好
  铺满画面，所以出图**就是那张贴图本身**（无边框、无采样丢失）。
* `view_transform='Standard'`、`look='None'`、`dither=0`。
* 地面图用**均匀顶光**（一盏垂直向下的 SUN，能量 ≈ π → 单位曝光）+ 均匀环境光
  （弱 AO 已烘进反照率谷底，光源本身不带方向）→ 平铺后不会出现方向性明暗。
* 街景演示另开「key/fill/bounce 三光 + 天空」的观感灯（与 probe_city_scene 同款），
  因为那张图是给人看建筑与地面怎么搭的。

尺度口径
--------
游戏档 128px = 4 格 = 1.68m；平面用 `uv_scale=128` 铺 → **1 格正好 32px**。
接缝档与游戏档都是 1:1 texel:pixel 渲染，验的就是游戏里会看到的那一像素。

跑法::
    blender -b --factory-startup -P probe_ground.py
    GROUND_ONLY=street blender -b --factory-startup -P probe_ground.py   # 只出街景
"""

import math
import os
import sys

import numpy as np

import bpy
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import buildings as B          # noqa: E402  （只读调用：取装配器 + 相机基 + 包围盒）
import ground_tiles as G       # noqa: E402

OUT_DIR = "F:/VSCode/game-2/.temp/building-pipeline-v2/stick-world/temp"
TILE_DIR = os.path.join(OUT_DIR, "ground_tiles")

YAW = 0.0
TILT = 20.0                 # 街景：纯正面 + 俯角 20°（§0.3 硬约束）
CELL = 32.0
TILE_UNITS = 512.0          # 一张贴图铺满 512 世界单位（= 渲染 512px 时的 1:1）

FONT_CANDIDATES = ["C:/Windows/Fonts/simhei.ttf", "C:/Windows/Fonts/msyh.ttc",
                   "C:/Windows/Fonts/Deng.ttf", "C:/Windows/Fonts/arial.ttf"]

_FONT = None
_EMIT = None
_MC = {}


def mat(key, n=None, variant=0):
    """材质缓存。**必须缓存**：`tile_material` 每次会先删同名旧材质，同一进程里
    对同一 (key,n,variant) 取两次，第二次会把第一张图上的材质掏空（面渲染成默认白）。"""
    n = G.GAME_PX if n is None else n
    k = (key, n, variant)
    if k not in _MC:
        _MC[k] = G.tile_material(key, n, variant=variant)
    return _MC[k]


# ---------------------------------------------------------------- 场景
def clear():
    """整个进程只调一次（§六 踩坑：中途 read_factory_settings 会静默回退纯色）。"""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    B._CACHE.clear()


def wipe():
    """只删网格/文字（保留相机与灯——它们跨图复用，删了会拿到失效引用）。"""
    for ob in list(bpy.data.objects):
        if ob.type in ("MESH", "FONT", "CURVE"):
            bpy.data.objects.remove(ob, do_unlink=True)


def link(ob):
    bpy.context.scene.collection.objects.link(ob)
    return ob


def plane(name, x0, x1, y0, y1, z, mat, uv_scale=0.0, uv_swap=False, uv_fn=None):
    """水平四边形。UV 三种给法：
    * `uv_fn(x, y) -> (u, v)`：**分带用**（U 按世界 X 铺、V 固定映射到带内 0~1）；
    * `uv_scale>0`：UV = 世界坐标 / uv_scale（世界平铺）；
    * 否则 UV 0~1（一张贴图铺满）。
    `uv_swap=True` 把 UV 转 90°（车辙 / 木纹这类**有走向**的贴图要顺巷道方向）。
    """
    me = bpy.data.meshes.new(name + "_m")
    me.from_pydata([(x0, y0, z), (x1, y0, z), (x1, y1, z), (x0, y1, z)], [], [(0, 1, 2, 3)])
    me.update()
    uvl = me.uv_layers.new(name="UVMap")
    s = float(uv_scale)
    pts = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
    if uv_fn is not None:
        uvs = [uv_fn(px, py) for (px, py) in pts]
    elif s > 0:
        uvs = [((p[1] / s, p[0] / s) if uv_swap else (p[0] / s, p[1] / s)) for p in pts]
    else:
        uvs = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)]
    for lp, uv in zip(me.loops, uvs):
        uvl.data[lp.index].uv = uv
    me.materials.append(mat)
    return link(bpy.data.objects.new(name, me))


def _mark_decal(ob):
    ob["is_decal"] = True
    return ob


def _two_layer_shoot(cam, path, res_x, res_y):
    """**两层分离渲染 + numpy 合成**：底（不透明）+ decal 层（透明底）→ 正确半透明叠加。

    为什么不用 EEVEE 的 alpha 混合：这台机器上的 EEVEE 预览链路对 BLENDED/DITHERED
    的 Alpha 直连处理不可靠（实测贴图 alpha 0.39 时整片渲染成不透明，或整片消失），
    给创始人看的图不能是白块/形状框。两层分离 + 自己合成是确定性的，且与引擎无关
    （引擎用的是导出的 RGBA PNG，自行混合）。
    """
    sc = bpy.context.scene
    ground_tmp = os.path.join(OUT_DIR, "_tmp_ground.png")
    decal_tmp = os.path.join(OUT_DIR, "_tmp_decal.png")
    objs = list(bpy.data.objects)
    dec = [o for o in objs if o.get("is_decal")]
    for o in dec:
        o.hide_render = True
    sc.render.film_transparent = False
    sc.render.image_settings.color_mode = "RGB"
    sc.render.resolution_x, sc.render.resolution_y = res_x, res_y
    sc.render.resolution_percentage = 100
    sc.render.filepath = ground_tmp
    bpy.ops.render.render(write_still=True)
    for o in dec:
        o.hide_render = False
    for o in objs:
        if not o.get("is_decal") and o.type in ("MESH", "FONT", "CURVE"):
            o.hide_render = True
    sc.render.film_transparent = True
    sc.render.image_settings.color_mode = "RGBA"
    sc.render.filepath = decal_tmp
    bpy.ops.render.render(write_still=True)
    for o in objs:
        o.hide_render = False
    a = _load_png_rgba(ground_tmp)
    b = _load_png_rgba(decal_tmp)
    al = np.clip(b[..., 3:4], 0.0, 1.0)
    out = b[..., :3] * al + a[..., :3] * (1.0 - al)
    G._save_png(out, path, "sRGB")
    for f in (ground_tmp, decal_tmp):
        try:
            os.remove(f)
        except OSError:
            pass
    print("-> %s  %dx%d  (两层合成：底 + decal alpha)" % (os.path.basename(path),
                                                         res_x, res_y))


def _load_png_rgba(path):
    img = bpy.data.images.load(path, check_existing=False)
    w, h = img.size
    buf = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(buf)
    a = buf.reshape(h, w, 4).astype(np.float64)
    bpy.data.images.remove(img)
    return a


def band_uv(y_base, height, u_scale=128.0):
    """分带 UV：U 按世界 X 每 u_scale 单位铺一张；V 把 [y_base-height, y_base] 映到 0~1。

    约定 **V=1 = 带的上缘**（建筑基线一侧）——与生成端"V→1 是墙根"一致。
    """
    def f(x, y):
        return (x / u_scale, (y - (y_base - height)) / float(height))
    return f


def world_uv(x, y):
    return (x / 128.0, y / 128.0)


def _emit_mat():
    global _EMIT
    if _EMIT is not None:
        return _EMIT
    m = bpy.data.materials.new("gt_label")
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    o = nt.nodes.new("ShaderNodeOutputMaterial")
    e = nt.nodes.new("ShaderNodeEmission")
    e.inputs[0].default_value = (0.94, 0.96, 1.0, 1.0)
    e.inputs[1].default_value = 1.0
    nt.links.new(e.outputs[0], o.inputs["Surface"])
    _EMIT = m
    return m


def label(text, x, y, size_px, z=6.0):
    """顶视图用的地面文字（文字本体躺在 XY 面、朝 +Z → 俯视读法正常）。"""
    global _FONT
    if _FONT is None:
        for p in FONT_CANDIDATES:
            if os.path.exists(p):
                try:
                    _FONT = bpy.data.fonts.load(p)
                    break
                except Exception:
                    _FONT = False
        if _FONT is None:
            _FONT = False
    bpy.ops.object.text_add(location=(x, y, z))
    ob = bpy.context.object
    ob.name = "lbl_" + text[:18]
    ob.data.body = text
    ob.data.size = float(size_px)
    ob.data.align_x = "CENTER"
    ob.data.align_y = "CENTER"
    if _FONT:
        ob.data.font = _FONT
    ob.data.materials.append(_emit_mat())
    return ob


# ---------------------------------------------------------------- 相机 / 灯光
def make_cam():
    d = bpy.data.cameras.new("gt_cam")
    d.type = "ORTHO"
    d.clip_start = 1.0
    d.clip_end = 100000.0
    ob = link(bpy.data.objects.new("gt_cam", d))
    bpy.context.scene.camera = ob
    return ob


def render_rect(cam, x0, x1, y0, y1, zoom, path):
    """俯视正交渲一张：世界矩形 → 像素（1 单位 = zoom px），水平向定 ortho_scale。"""
    w = float(x1 - x0)
    h = float(y1 - y0)
    rx = max(64, int(round(w * zoom)))
    ry = max(64, int(round(h * zoom)))
    cam.data.sensor_fit = "HORIZONTAL"
    cam.data.ortho_scale = w
    cam.location = ((x0 + x1) / 2.0, (y0 + y1) / 2.0, 6000.0)
    cam.rotation_euler = (0.0, 0.0, 0.0)
    sc = bpy.context.scene
    sc.render.resolution_x = rx
    sc.render.resolution_y = ry
    sc.render.resolution_percentage = 100
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)
    print("-> %s  %dx%d  (%.4f px/unit)" % (os.path.basename(path), rx, ry, zoom))
    return (rx, ry)


def render_tilt(cam, objs, zoom, path, pad_side=44.0, pad_top=44.0, pad_bottom=300.0):
    """斜俯视取景（只按 `objs` 的屏幕投影包围盒，地面另给 pad_bottom）。"""
    pts = []
    for ob in objs:
        pts += B.shape_points(ob, skip_ground=False)
    right, up = B.cam_axes(YAW, TILT)
    us = [p.dot(right) for p in pts]
    vs = [p.dot(up) for p in pts]
    u0, u1 = min(us) - pad_side, max(us) + pad_side
    v0, v1 = min(vs) - pad_bottom, max(vs) + pad_top
    w, h = (u1 - u0), (v1 - v0)
    cu, cv = (u0 + u1) / 2.0, (v0 + v1) / 2.0
    ref = pts[0]
    anchor = ref + right * (cu - ref.dot(right)) + up * (cv - ref.dot(up))
    fwd = -(right.cross(up))
    cam.data.sensor_fit = "AUTO"
    cam.data.ortho_scale = max(w, h)
    cam.location = tuple(Vector(anchor) - fwd * 12000.0)
    cam.rotation_euler = (math.radians(90.0 - TILT), 0.0, math.radians(YAW))
    rx = max(64, int(round(w * zoom)))
    ry = max(64, int(round(h * zoom)))
    sc = bpy.context.scene
    sc.render.resolution_x = rx
    sc.render.resolution_y = ry
    sc.render.resolution_percentage = 100
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)
    print("-> %s  %dx%d  (%.2f px/unit)" % (os.path.basename(path), rx, ry, zoom))
    return (rx, ry)


def setup_render():
    sc = bpy.context.scene
    for eng in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE", "CYCLES"):
        try:
            sc.render.engine = eng
            break
        except Exception:
            continue
    sc.view_settings.view_transform = "Standard"
    sc.view_settings.look = "None"
    sc.view_settings.exposure = 0.0
    sc.render.film_transparent = False
    sc.render.dither_intensity = 0.0
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_mode = "RGB"
    sc.render.image_settings.compression = 15
    for attr, val in (("taa_render_samples", 48), ("use_gtao", True),
                      ("gtao_distance", 0.4), ("use_shadows", True)):
        try:
            setattr(sc.eevee, attr, val)
        except Exception:
            pass
    return sc


def _sun(name, energy, rot, angle=3.0, color=(1.0, 1.0, 1.0)):
    d = bpy.data.lights.new(name, "SUN")
    d.energy = energy
    d.angle = math.radians(angle)
    d.color = color
    ob = link(bpy.data.objects.new(name, d))
    ob.rotation_euler = tuple(math.radians(a) for a in rot)
    return ob


def build_lights():
    """三套灯同时在场，用 hide_render 切换（避免反复新建删灯）。

    flat  = 地面资产图专用：**一盏垂直向下的 SUN**（无水平分量 → 光照各向同性，
            不会把任何单一方向的明暗烘进贴图）+ 均匀环境。这就是"光照中性"的实现：
            N·L = Nz 只跟坡度有关，跟朝向无关。
    street= 街景演示的观感灯（key/fill/bounce，与 probe_city_scene 同款）。
    night = 夜晚调制：冷暗顶光（等同"整体乘冷蓝色调压暗"）+ 几盏暖色点光（灯笼光斑）。
    """
    flat = [_sun("gt_flat", 2.72, (0, 0, 0), 2.0, (1.0, 1.0, 1.0))]
    street = [
        _sun("gt_key", 3.5, (42, 0, -34), 2.5, (1.0, 0.93, 0.80)),
        _sun("gt_fill", 0.22, (58, 0, 126), 20.0, (0.80, 0.87, 1.0)),
        _sun("gt_bounce", 0.30, (-28, 0, 6), 45.0, (0.95, 0.80, 0.62)),
    ]
    night = [_sun("nt_moon", 2.25, (0, 0, 0), 4.0, (0.40, 0.55, 0.90))]
    # 灯笼：低挂点光（z=88 ≈ 1.15m），能量按"落点照度 ≈ 白天"反算
    lum = []
    for i, (x, y) in enumerate(NIGHT_LAMPS):
        z = 88.0
        d = z - 2.0
        d_light = bpy.data.lights.new("nt_lamp%d" % i, "POINT")
        d_light.color = (1.0, 0.62, 0.28)
        d_light.energy = 4.0 * math.pi ** 2 * d * d * 1.40
        d_light.shadow_soft_size = 14.0
        ob = link(bpy.data.objects.new("nt_lamp%d" % i, d_light))
        ob.location = (x, y, z)
        lum.append(ob)
    return {"flat": flat, "street": street, "night": night + lum}


#: 灯笼摆位（世界 x,y）：三栋门前各一盏 + 巷口一盏
NIGHT_LAMPS = [(-452.0, -70.0), (34.0, -70.0), (414.0, -70.0),
               (-158.0, 250.0), (-158.0, 760.0)]


def lights_mode(rigs, on):
    for name, obs in rigs.items():
        for ob in obs:
            ob.hide_render = (name != on)


def world_flat():
    w = bpy.data.worlds.new("gt_wflat")
    w.use_nodes = True
    nt = w.node_tree
    bg = nt.nodes.get("Background") or nt.nodes.new("ShaderNodeBackground")
    bg.inputs[0].default_value = (0.50, 0.52, 0.56, 1.0)
    bg.inputs[1].default_value = 0.30
    bg.location = (0.0, 0.0)
    return w


def world_night():
    """夜晚环境：冷暗（青蓝），只有很弱的天光。"""
    w = bpy.data.worlds.new("gt_wnight")
    w.use_nodes = True
    nt = w.node_tree
    bg = nt.nodes.get("Background") or nt.nodes.new("ShaderNodeBackground")
    bg.inputs[0].default_value = (0.10, 0.16, 0.30, 1.0)
    bg.inputs[1].default_value = 0.16
    bg.location = (0.0, 0.0)
    return w


def world_sky():
    w = bpy.data.worlds.new("gt_wsky")
    w.use_nodes = True
    nt = w.node_tree
    bg = nt.nodes.get("Background") or nt.nodes.new("ShaderNodeBackground")
    bg.inputs[1].default_value = 0.55
    tc = nt.nodes.new("ShaderNodeTexCoord")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (0.74, 0.76, 0.74, 1.0)
    ramp.color_ramp.elements[1].color = (0.42, 0.56, 0.80, 1.0)
    nt.links.new(tc.outputs["Generated"], sep.inputs["Vector"])
    nt.links.new(sep.outputs["Z"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], bg.inputs[0])
    return w


# ---------------------------------------------------------------- 单块成图
#: 需要出"面"类成图的 key（12 平铺 + 9 分带 + 3 过渡）
FACE_KEYS = G.all_keys()


def shoot_one(cam, key, n, out_path, variant=0):
    """一张 key × 分辨率 × 变体：俯视正交 1:1（贴图 = 出图，无边框无采样丢失）。"""
    nx, ny = G.kind_size(key, None if n == G.GAME_PX else n)
    if n != G.GAME_PX:
        nx, ny = G.kind_size(key, n)
    wipe()
    mm = mat(key, n, variant)
    plane("one_" + key, -nx / 2.0, nx / 2.0, -ny / 2.0, ny / 2.0, 0.0, mm)
    render_rect(cam, -nx / 2.0, nx / 2.0, -ny / 2.0, ny / 2.0, 1.0, out_path)


def shoot_all_faces(cam):
    """所有面类：512 高清档 + 128 游戏档 + 3 个游戏档变体。"""
    for key in FACE_KEYS:
        kind = G.kind_info(key)[3]
        # 分段 / 件 / 长条本身就是最终像素尺寸 → 只出 1:1（不再有 4× 高清档）
        if kind in ("segment", "piece", "strip"):
            shoot_one(cam, key, G.GAME_PX, os.path.join(TILE_DIR, "%s.png" % key))
            continue
        shoot_one(cam, key, G.HD_PX, os.path.join(TILE_DIR, "%s.png" % key))
        shoot_one(cam, key, G.GAME_PX,
                  os.path.join(TILE_DIR, "%s_%d.png" % (key, G.GAME_PX)))
        if kind in ("tile", "band"):                     # 变体只给平铺类与分带
            for v in range(1, G.VARIANTS + 1):
                shoot_one(cam, key, G.GAME_PX,
                          os.path.join(TILE_DIR,
                                       "%s_%d_v%d.png" % (key, G.GAME_PX, v)),
                          variant=v)


def _backing(cx, cy, w, h, z=-1.0, name="back", col=(0.16, 0.16, 0.17)):
    """深色垫板：让薄带（路缘 16px）与带 alpha 的 decal 有底可读。"""
    if "gt_backing" not in bpy.data.materials:
        m = bpy.data.materials.new("gt_backing")
        m.use_nodes = True
        nt = m.node_tree
        nt.nodes.clear()
        o = nt.nodes.new("ShaderNodeOutputMaterial")
        b = nt.nodes.new("ShaderNodeBsdfPrincipled")
        b.inputs["Base Color"].default_value = tuple(col) + (1.0,)
        b.inputs["Roughness"].default_value = 0.85
        nt.links.new(b.outputs["BSDF"], o.inputs["Surface"])
    return plane(name, cx, cx + w, cy, cy + h, z, bpy.data.materials["gt_backing"])


def shot_kind_sheet(cam):
    """`pbr_ground_sheet.png`：**种类 × 变体**对照。

    2 列 × 12 行，每个"种类条"= 标签 + 基础档 + 3 个变体（都是 128 游戏档、1:1）。
    变体之间比的是"斑驳位置 / 接缝相位 / 逐块色"，所以放在同一行最容易看出差别。
    """
    wipe()
    ks = FACE_KEYS
    ncol = 2
    cellw, cellh, gap = 128.0, 128.0, 22.0
    labw = 300.0
    rows = (len(ks) + ncol - 1) // ncol
    stripw = labw + 4 * cellw + 3 * gap
    W = ncol * stripw + (ncol + 1) * gap
    H = rows * (cellh + 34.0) + (rows + 1) * gap + 60.0
    x0, y1 = -W / 2.0, H / 2.0
    label("地面种类 × 变体对照（128px 游戏档 1:1；每种：基础 + 变体 1/2/3）",
          0.0, y1 - 30.0, 40.0)
    for i, key in enumerate(ks):
        c, r = i % ncol, i // ncol
        sx = x0 + gap + c * (stripw + gap)
        sy = y1 - 60.0 - gap - r * (cellh + 34.0)
        nm, nx, ny, kind = G.kind_info(key)
        _backing(sx, sy - cellh, stripw, cellh + 34.0, name="bk_%s" % key)
        label("%s\n%s" % (key, nm), sx + labw * 0.5 - 6.0, sy - cellh * 0.5, 26.0)
        has_var = kind in ("tile", "band")
        for vi in range(4):
            cx = sx + labw + vi * (cellw + gap)
            cy = sy - (cellh - ny) / 2.0
            plane("s_%s_%d" % (key, vi), cx, cx + nx, cy - ny, cy, 0.0,
                  mat(key, G.GAME_PX, vi if has_var else 0))
        label("基础 / v1 / v2 / v3" if has_var else "（过渡带不做变体）",
              sx + labw + 2 * cellw, sy - cellh - 16.0, 20.0)
    render_rect(cam, x0, x0 + W, y1 - H, y1, 1.0,
                os.path.join(OUT_DIR, "pbr_ground_sheet.png"))


def shot_seam(cam):
    """`pbr_ground_seam.png`：上段 12 平铺 3×3；下段 9 分带（3 带堆叠 × X 向 3 连）。"""
    wipe()
    t = float(G.GAME_PX)
    ks = G.keys()
    cols = 4
    gap, lab = 20.0, 50.0
    cell = 3.0 * t
    rows = (len(ks) + cols - 1) // cols
    W1 = cols * cell + (cols + 1) * gap
    H1 = rows * (cell + lab) + (rows + 1) * gap
    # 下段：每族一条"路肩 / 路缘 / 道路"堆叠（X 向 3 连），读的就是真实分带结构
    S, K, R = G.SHOULDER_PX, G.KERB_PX, G.ROAD_PX
    fam_w = 3.0 * t
    fam_h = S + K + R
    W2 = 3 * (fam_w + gap) + gap
    H2 = 3 * (fam_h + lab) + 4 * gap
    W = max(W1, W2)
    H = H1 + H2 + gap + 70.0
    x0, y1 = -W / 2.0, H / 2.0
    label("① 12 种平铺地面：3×3 接缝检查（128 游戏档 1:1）",
          0.0, y1 - 34.0, 40.0)
    yy = y1 - 70.0
    for i, key in enumerate(ks):
        c, r = i % cols, i // cols
        cx = x0 + gap + c * (cell + gap)
        cy = yy - gap - r * (cell + lab)
        mm = mat(key, G.GAME_PX)
        for ry in range(3):
            for rx in range(3):
                plane("sm_%s_%d%d" % (key, rx, ry),
                      cx + rx * t, cx + (rx + 1) * t,
                      cy - (ry + 1) * t, cy - ry * t, 0.0, mm)
        label("%s %s" % (key, G._SPEC[key]["name"]),
              cx + cell / 2.0, cy - cell - lab * 0.75, 28.0)
    yy2 = yy - H1 - gap
    label("② 9 种分带：族内「路肩 96px / 路缘沟 16px / 道路 128px」纵向堆叠 + X 向 3 连"
          "（上缘贴建筑基线）", 0.0, yy2 - 30.0, 36.0)
    fy = yy2 - 60.0
    for f, (fk, fname) in enumerate(G.FAMILIES):
        fx = x0 + gap
        _backing(fx, fy - fam_h - lab, fam_w, fam_h + lab, name="bkfam_%s" % fk)
        for kk in range(3):
            plane("bd_%s_%d" % (fk, kk), fx + kk * t, fx + (kk + 1) * t,
                  fy - fam_h, fy - fam_h + S, 0.0, mat("band_shoulder_%s" % fk))
            plane("bk_%s_%d" % (fk, kk), fx + kk * t, fx + (kk + 1) * t,
                  fy - fam_h + S, fy - fam_h + S + K, 0.0, mat("band_kerb_%s" % fk))
            plane("br_%s_%d" % (fk, kk), fx + kk * t, fx + (kk + 1) * t,
                  fy - fam_h + S + K, fy - fam_h + S + K + R, 0.0,
                  mat("band_road_%s" % fk))
        label("%s（%s）" % (fname, fk), fx + fam_w / 2.0, fy - fam_h - lab * 0.6, 26.0)
        fy -= fam_h + lab + gap
    render_rect(cam, x0, x0 + W, y1 - H, y1, 1.0,
                os.path.join(OUT_DIR, "pbr_ground_seam.png"))


def shot_game1x(cam):
    """`pbr_ground_game1x.png`：**1:1 游戏尺寸**两张——
    上=三族分带按真实结构叠出来的地面条（4 张贴图宽），下=24 种单块 1:1 目录。"""
    wipe()
    margin, title, gap = 40.0, 54.0, 16.0
    S, K, R = G.SHOULDER_PX, G.KERB_PX, G.ROAD_PX
    # ---- 上段：三族分带条（宽 4 张贴图 = 512）
    sw = 512.0
    sh = S + K + R
    W = sw + 2 * margin
    H = margin * 4 + title * 2 + 3 * (sh + 40.0) + 6 * (128.0 + 30.0)
    x0, y1 = -W / 2.0, H / 2.0
    y = y1 - margin
    label("① 分带按真实结构叠出来的地面条（1:1 游戏尺寸：4 张贴图宽 = 512px = 2.15m）",
          0.0, y - title * 0.5, 36.0)
    y -= title
    for fi, (fk, fname) in enumerate(G.FAMILIES):
        bx = -sw / 2.0
        label("%s：路肩(96) / 路缘沟(16) / 道路" % fname, bx + sw / 2.0,
              y - 14.0, 26.0)
        y -= 30.0
        for kk in range(4):
            plane("g1s_%s_%d" % (fk, kk), bx + kk * 128.0, bx + (kk + 1) * 128.0,
                  y - sh, y - sh + S, 0.0, mat("band_shoulder_%s" % fk))
            plane("g1k_%s_%d" % (fk, kk), bx + kk * 128.0, bx + (kk + 1) * 128.0,
                  y - sh + S, y - sh + S + K, 0.0, mat("band_kerb_%s" % fk))
            plane("g1r_%s_%d" % (fk, kk), bx + kk * 128.0, bx + (kk + 1) * 128.0,
                  y - sh + S + K, y - sh + S + K + R, 0.0, mat("band_road_%s" % fk))
        y -= sh + 40.0
    # ---- 下段：24 种单块 1:1 目录
    ks = FACE_KEYS
    ncol = 6
    label("② 24 种单块 1:1 目录（每块按游戏内真实像素尺寸）", 0.0, y - title * 0.45, 36.0)
    y -= title
    bx = -(ncol * 128.0 + (ncol + 1) * gap) / 2.0
    for i, key in enumerate(ks):
        c, r = i % ncol, i // ncol
        nm, nx, ny, kind = G.kind_info(key)
        cx = bx + gap + c * (128.0 + gap)
        cy = y - gap - r * (128.0 + 30.0)
        _backing(cx, cy - 128.0, 128.0, 128.0, name="bk1_%s" % key)
        plane("g1_%s" % key, cx, cx + nx, cy - 128.0 + (128.0 - ny) / 2.0,
              cy - 128.0 + (128.0 - ny) / 2.0 + ny, 0.0, mat(key, G.GAME_PX))
        label(key, cx + 64.0, cy - 128.0 - 15.0, 20.0)
    render_rect(cam, x0, x0 + W, y1 - H, y1, 1.0,
                os.path.join(OUT_DIR, "pbr_ground_game1x.png"))


# ---------------------------------------------------------------- 链式分段集（交付主形态）
SEG_TITLE = {"edge": "边缘·村（夯土/砾石/草皮啃噬）＝ 村庄级城市只用这一档",
             "mid": "中环·镇（旧砖+碎石混铺）＝ 镇级起",
             "center": "中心·城（石板/大理石+残块修补）＝ 仅城级"}
BAND_TITLE = {"shoulder": "路肩底", "kerb": "路缘", "road": "道路带"}


def shot_segments(cam):
    """`pbr_ground_segments.png`：3 档 × 3 带 × 5 段可互换分段图鉴（1:1，512px = 16 格）。"""
    wipe()
    gap, tlab, rlab = 14.0, 42.0, 26.0
    nv = G.SEG_VARIANTS
    W = nv * (G.SEG_W + gap) + gap
    # 每档：地/缘/道 三带纵向堆叠（读的是真实分带结构）+ 档标签
    tier_h = G.STRIP_SHOULDER + G.STRIP_KERB + G.STRIP_ROAD
    H = 60.0 + 3 * (tlab + tier_h + rlab + gap) + 40.0
    x0, y1 = -W / 2.0, H / 2.0
    label("链式分段集：城市内区带梯度 3 档（边缘 edge / 中环 mid / 中心 center）"
          "× 3 带（路肩底 96 / 路缘 16 / 道路带 160）× %d 个可互换段"
          "（每段 512px = 16 格；规模=包含：村只用 edge，镇=mid+edge，城=全档）" % nv,
          0.0, y1 - 30.0, 36.0)
    y = y1 - 60.0
    for tn, tname, _fam in G.TIERS:
        label(SEG_TITLE[tn], x0 + 300.0, y - tlab * 0.45, 28.0)
        y -= tlab
        for bn, bname, bh in (("shoulder", "路肩底", G.STRIP_SHOULDER),
                              ("kerb", "路缘", G.STRIP_KERB),
                              ("road", "道路带", G.STRIP_ROAD)):
            for i in range(nv):
                cx = x0 + gap + i * (G.SEG_W + gap)
                plane("sg_%s_%s_%d" % (tn, bn, i + 1), cx, cx + G.SEG_W,
                      y - bh, y, 0.0, mat("seg_%s_%s_v%d" % (bn, tn, i + 1)),
                      uv_fn=world_uv)
            label("%s（%dpx）" % (bname, bh), x0 + 150.0, y - bh / 2.0, 22.0)
            y -= bh
        label("横向接缝同级 → 引擎按种子链式铺；城市延长 = 续链", x0 + 420.0,
              y - rlab * 0.5, 22.0)
        y -= rlab + gap
    render_rect(cam, x0, x0 + W, y1 - H, y1, 0.55,
                os.path.join(OUT_DIR, "pbr_ground_segments.png"))


def shot_chain(cam):
    """`pbr_ground_chain_demo.png`：链式拼接示范 + 新旧过渡段衔接两档 + 分段当底摆建筑。"""
    wipe()
    gap, title = 18.0, 46.0
    order_road = [3, 1, 5, 2, 4]
    W = 6 * (G.SEG_W + gap) + gap
    H = 60.0 + (title + G.STRIP_ROAD + 30.0) * 2 + title + G.STRIP_SHOULDER + 60.0 + 60.0
    x0, y1 = -W / 2.0, H / 2.0
    label("链式拼接示范：同档 5 段按种子乱序连铺 / 新旧过渡段衔接「城 ↔ 村」/ "
          "分段纵向固定 + 横向续链", 0.0, y1 - 30.0, 34.0)
    y = y1 - 60.0
    # ---- ① 镇档道路带 5 段乱序连铺
    label("① 中环(mid)道路带：%s（seed 乱序，无对缝、无重复感）" % order_road,
          x0 + 300.0, y - title * 0.5, 28.0)
    y -= title
    for i, v in enumerate(order_road):
        cx = x0 + gap + i * (G.SEG_W + gap)
        plane("ch1_%d" % i, cx, cx + G.SEG_W, y - G.STRIP_ROAD, y, 0.0,
              mat("seg_road_mid_v%d" % v), uv_fn=world_uv)
    y -= G.STRIP_ROAD + 30.0
    # ---- ② 新旧过渡：城 → （过渡段）→ 村
    label("② 新旧过渡段：中心(center)新铺装 → 过渡段（不规则边缘半盖旧土面 + 缝里碎石）→ 边缘(edge)",
          x0 + 520.0, y - title * 0.5, 28.0)
    y -= title
    for i in range(6):
        cx = x0 + gap + i * (G.SEG_W + gap)
        if i < 2:
            mk = "seg_road_center_v%d" % order_road[i]
        elif i in (2, 3):
            mk = "seg_newold_v%d" % (i - 1)
        else:
            mk = "seg_road_edge_v%d" % order_road[i - 3]
        plane("ch2_%d" % i, cx, cx + G.SEG_W, y - G.STRIP_ROAD, y, 0.0,
              mat(mk), uv_fn=world_uv)
    y -= G.STRIP_ROAD + 30.0
    # ---- ③ 村档路肩底连铺（读"不是整齐砖台"）
    label("③ 边缘(edge)路肩底连铺：夯土/砾石/旧石板混杂 + 上缘被草皮与泥土不规则啃噬"
          "（村庄级城市的地面），横向链式续链",
          x0 + 460.0, y - title * 0.5, 28.0)
    y -= title
    for i in range(5):
        cx = x0 + gap + i * (G.SEG_W + gap)
        plane("ch3_%d" % i, cx, cx + G.SEG_W, y - G.STRIP_SHOULDER, y, 0.0,
              mat("seg_shoulder_edge_v%d" % order_road[i]), uv_fn=world_uv)
    render_rect(cam, x0, x0 + W, y1 - H, y1, 0.62,
                os.path.join(OUT_DIR, "pbr_ground_chain_demo.png"))


def shot_decals(cam):
    """`pbr_ground_decals.png`：decal 图鉴（alpha 形状 + 采样色）+ 撒布参数表。"""
    wipe()
    gap, title = 16.0, 44.0
    dks = [d["key"] for d in G.DECALS]
    cols = 8
    cell = 96.0
    W = cols * (cell + gap) + gap
    H = 60.0 + title + cell + 26.0 + title + 3 * 40.0 + 40.0
    x0, y1 = -W / 2.0, H / 2.0
    label("decal 集（单件，带 alpha；左=alpha 形状，右=色层采样）× 撒布参数（json 里给"
          "「种子 + 密度」建议，不烘进分段）", 0.0, y1 - 30.0, 32.0)
    y = y1 - 60.0 - title
    for i, dk in enumerate(dks):
        cx = x0 + gap + i * (cell + gap)
        plane("dc_bg_%d" % i, cx, cx + cell, y - cell, y, 0.0,
              mat("seg_road_mid_v1"), uv_fn=world_uv)
        nx, ny = G.kind_size(dk)
        _mark_decal(plane("dca_%d" % i, cx + (cell - nx * 0.7) / 2.0,
                          cx + (cell + nx * 0.7) / 2.0,
                          y - (cell + ny * 0.7) / 2.0,
                          y - (cell - ny * 0.7) / 2.0, 1.0,
                          G.decal_material(dk)))
        label(dk.replace("dc_", ""), cx + cell / 2.0, y - cell - 14.0, 20.0)
    y -= cell + 26.0 + title
    for i, ln in enumerate((
            "撒布参数（建议）：density = 每 10m 期望件数；size = 世界格数 ×0.7~1.3 抖动",
            "污渍 0.6/10m·0.5~1格   水洼 0.4/10m·1~2格   裂缝 0.5/10m·1~2格   苔藓 0.5/10m·1~2格",
            "碎屑 1.2/10m·0.5~1格   磨光带 0.3/10m·1~2格   修补块 0.25/10m·1.5~2格   门口径 每门 1 件")):
        label(ln, x0 + 520.0, y - i * 40.0, 20.0)
    sc = bpy.context.scene
    cam.data.sensor_fit = "HORIZONTAL"
    cam.data.ortho_scale = W
    cam.location = ((x0 + x0 + W) / 2.0, (y1 - H + y1) / 2.0, 6000.0)
    cam.rotation_euler = (0.0, 0.0, 0.0)
    _two_layer_shoot(cam, os.path.join(OUT_DIR, "pbr_ground_decals.png"),
                     int(round(W * 0.85)), int(round(H * 0.85)))


def shot_pieces(cam):
    """`pbr_ground_pieces.png`：动态建造层件图鉴（落地面环 / 邻居过渡 / 门前径）。"""
    wipe()
    gap, title = 20.0, 44.0
    cols = 5
    cellw, cellh = 128.0, 128.0
    ks = [q["key"] for q in G.PIECES]
    rows = (len(ks) + cols - 1) // cols
    W = cols * (cellw + gap) + gap
    H = 60.0 + title + rows * (cellh + 44.0) + gap
    x0, y1 = -W / 2.0, H / 2.0
    label("动态建造层·网格拼接件（落地面环中段/端头、邻居过渡件、门前踩踏小径；"
          "网格锚点对齐）", 0.0, y1 - 30.0, 32.0)
    y = y1 - 60.0 - title
    for i, key in enumerate(ks):
        c, r = i % cols, i // cols
        nm, nx, ny, kind = G.kind_info(key)
        cx = x0 + gap + c * (cellw + gap)
        cy = y - r * (cellh + 44.0)
        _backing(cx, cy - cellh, cellw, cellh, name="bkp_%s" % key)
        _mark_decal(plane("pp_%s" % key, cx + (cellw - nx) / 2.0,
                          cx + (cellw + nx) / 2.0,
                          cy - cellh + (cellh - ny) / 2.0,
                          cy - cellh + (cellh + ny) / 2.0, 0.0, mat(key)))
        q = G._PIECE_OF[key]
        label("%s\n%s（%d×%d 格）" % (key, nm, q["cells"][0], q["cells"][1]),
              cx + cellw / 2.0, cy - cellh - 18.0, 19.0)
    sc = bpy.context.scene
    cam.data.sensor_fit = "HORIZONTAL"
    cam.data.ortho_scale = W
    cam.location = ((x0 + x0 + W) / 2.0, (y1 - H + y1) / 2.0, 6000.0)
    cam.rotation_euler = (0.0, 0.0, 0.0)
    _two_layer_shoot(cam, os.path.join(OUT_DIR, "pbr_ground_pieces.png"),
                     int(round(W)), int(round(H)))


def _grid_floor(cx0, width_cells, rows=3):
    """分段当底：横向链式铺（16 格一段），纵向按带高重复；返回底面积范围。"""
    for i in range(rows):
        y0 = -i * G.STRIP_H
        segn = max(1, int(round(width_cells / 16.0)))
        for j in range(segn):
            xa = cx0 + j * G.SEG_W
            plane("gf_%d_%d" % (i, j), xa, xa + G.SEG_W, y0 - G.STRIP_H, y0,
                  0.0 if i == 0 else 0.5, mat("seg_road_mid_v%d" % (j % 5 + 1)),
                  uv_fn=world_uv)


def shot_grid_demo(cam):
    """`pbr_ground_grid_demo.png`：左=建造后（落地面环 + 门前径 + 过渡件融合）/ 右=拆一栋露底。"""
    wipe()
    objs = []
    # 6 / 8 / 12 格三档（装配器最小 6 格）；前两栋贴近 → 中间摆邻居过渡件
    plan = [("cottage", 6, -460.0), ("house", 8, -172.0), ("townhouse", 12, 300.0)]
    for (name, wc, cx) in plan:
        ob, spec = B.ASSEMBLERS[name](wc)
        front_local = B.measure(ob)["y"][0]
        ob.location = (cx, 0.0 - front_local, 0.0)
        bpy.context.view_layer.update()
        objs.append(ob)
        w = wc * CELL
        bx0, bx1 = cx - w / 2.0, cx + w / 2.0
        nb = max(1, int(round(w / float(G.PIECE_CELLS * CELL))))
        for j in range(nb):
            xa = bx0 + j * G.PIECE_CELLS * CELL
            plane("ring_%d_%d" % (int(cx), j), xa, xa + G.PIECE_CELLS * CELL,
                  -G.RING_H, 0.0, 2.0, mat("p_ring_mid"), uv_fn=world_uv)
        plane("capL_%d" % int(cx), bx0 - 96.0, bx0, -G.RING_H, 0.0, 2.0,
              mat("p_ring_cap_l"))
        plane("capR_%d" % int(cx), bx1, bx1 + 96.0, -G.RING_H, 0.0, 2.0,
              mat("p_ring_cap_r"))
        dx = cx + float(spec.get("door_x", 0.0))
        _mark_decal(plane("path_%d" % int(cx), dx - 64.0, dx + 64.0,
                          -G.RING_H - 32.0, 0.0, 3.0,
                          G.decal_material("p_path_a"), uv_fn=world_uv))
    # 相邻两栋之间：右邻有建筑 → 该侧改铺过渡件
    plane("edge_mid", -428.0, -236.0, -G.RING_H, 0.0, 2.5, mat("p_edge_r"),
          uv_fn=world_uv)
    _grid_floor(-640.0, 40)
    _grid_floor(1560.0, 20)          # 右半：拆掉建筑后的静态底
    fit = list(objs)
    pts = []
    for ob in fit:
        pts += B.shape_points(ob, skip_ground=False)
    right, up = B.cam_axes(YAW, TILT)
    us = [p.dot(right) for p in pts]
    vs = [p.dot(up) for p in pts]
    u0, u1 = -760.0, 1820.0
    v0, v1 = min(vs) - 460.0, max(vs) + 40.0
    W, Hh = (u1 - u0), (v1 - v0)
    cam.data.sensor_fit = "AUTO"
    cam.data.ortho_scale = max(W, Hh)
    cu, cv = (u0 + u1) / 2.0, (v0 + v1) / 2.0
    ref = pts[0]
    anchor = ref + right * (cu - ref.dot(right)) + up * (cv - ref.dot(up))
    fwd = -(right.cross(up))
    cam.location = tuple(Vector(anchor) - fwd * 14000.0)
    cam.rotation_euler = (math.radians(90.0 - TILT), 0.0, math.radians(YAW))
    label("建造后：落地面环（3 格高）+ 门前踩踏径 + 相邻两栋之间的过渡件融合",
          -300.0, max(vs) + 10.0, 34.0)
    label("拆掉建筑后：露出静态基础层（分段底），无需特殊资产", 1600.0,
          max(vs) + 10.0, 34.0)
    sc = bpy.context.scene
    _two_layer_shoot(cam, os.path.join(OUT_DIR, "pbr_ground_grid_demo.png"),
                     max(64, int(round(W))), max(64, int(round(Hh))))
    return objs


# ---------------------------------------------------------------- 街景应用（分带结构）
#: 主街两侧：3 栋现成装配器（宽度 4/8/12 格的整数倍口径）
STREET_PLAN = [("townhouse", 12), ("house", 8), ("house", 12)]
ALLEY_W = 4 * CELL           # 巷道宽（4 格）
FAM = "stone"                # 街景用的材质族（石砌镇）


def build_street(fam=FAM, decals_on=True, mottle=None, variant_mix=True):
    """按**真实分带结构**摆一条街：

        （上）建筑背后的远处地面
        建筑基线 ────────────────────────────  路肩带（96px，贴墙根的硬化面）
        路缘石 + 排水沟（16px）
        道路带（向下到画面底，主可走区，站人）
    """
    band = lambda k: mat("band_%s_%s" % (k, fam))
    nb = G.SHOULDER_PX
    nk = G.KERB_PX
    wx = 4200.0
    # ① 建筑背后的远处地面（草地，露在建筑上方与两侧）
    plane("g_far", -wx, wx, -40.0, 3200.0, 0.0, mat("grass_sparse"), 128.0,
          uv_fn=world_uv)
    yb = 40.0                                   # 建筑基线（前墙面落地线）
    # ② 路肩带：96px，V=1 贴建筑基线
    plane("g_shoulder", -wx, wx, yb - nb, yb, 1.0, band("shoulder"),
          uv_fn=band_uv(yb, nb))
    # ③ 路缘石 + 排水沟：16px
    plane("g_kerb", -wx, wx, yb - nb - nk, yb - nb, 1.2, band("kerb"),
          uv_fn=band_uv(yb - nb, nk))
    # ④ 道路带：向下铺到画面底（Y 向可平铺）
    plane("g_road", -wx, wx, -2400.0, yb - nb - nk, 0.8, band("road"),
          uv_fn=world_uv)
    # 建筑
    widths = [w * CELL for (_n, w) in STREET_PLAN]
    gaps = [ALLEY_W, 60.0]
    total = sum(widths) + sum(gaps)
    x = -total / 2.0
    objs = []
    bands = []
    doors = []
    for i, ((name, wc), w) in enumerate(zip(STREET_PLAN, widths)):
        x0, x1 = x, x + w
        ob, spec = B.ASSEMBLERS[name](wc)
        front_local = B.measure(ob)["y"][0]
        ob.location = ((x0 + x1) / 2.0, yb - front_local, 0.0)
        bpy.context.view_layer.update()
        objs.append(ob)
        bands.append((name, wc, x0, x1))
        doors.append(((x0 + x1) / 2.0 + float(spec.get("door_x", 0.0)),
                      float((spec.get("door") or [96.0])[0])))
        x = x1 + (gaps[i] if i < len(gaps) else 0.0)
    # ⑤ 巷口（第 1~2 栋之间的土巷，从路肩一直通到背后）
    plane("g_alley", bands[0][3], bands[0][3] + ALLEY_W, yb - nb - nk, 1400.0, 1.4,
          mat("band_road_earth"), uv_fn=world_uv)
    # ⑥ 门口通道 decal：每栋门口一条（"磨损集中在门口"）
    dec = []
    if decals_on:
        for (dx, dw) in doors:
            dec.append(plane("d_door_%d" % len(dec), dx - 16.0, dx + 16.0, yb - 96.0, yb,
                             2.2, G.decal_material("dc_door_path"),
                             uv_fn=lambda xx, yy, _yb=yb: ((xx - 0.0) / 32.0,
                                                           (yy - (_yb - 96.0)) / 96.0)))
    # ⑦ 道路上的随机 decal + 变体轮换（治重复度）
    if decals_on:
        for si, (dk, dx, dy, dw, dh) in enumerate((
                ("dc_puddle", -420.0, -150.0, 96, 64),
                ("dc_patch", 210.0, -60.0, 96, 96),
                ("dc_worn", -160.0, -46.0, 128, 64),
                ("dc_moss", 470.0, -420.0, 96, 96),
                ("dc_crack", -60.0, -330.0, 128, 128),
                ("dc_stain", 330.0, -250.0, 64, 64),
                ("dc_debris", -300.0, -480.0, 96, 64))):
            dec.append(plane("d_%s" % dk, dx, dx + dw, dy, dy + dh, 2.0,
                             G.decal_material(dk),
                             uv_fn=lambda xx, yy, _x=dx, _y=dy, _w=dw, _h=dh:
                             ((xx - _x) / _w, (yy - _y) / _h)))
    # ⑧ 柴垛/人形：火柴人站在道路带里（比例锚 130px）
    sb = B.Builder("stickman")
    B.stickman(sb, x=-40.0, y=yb - nb - nk - 260.0, z=0.8)
    objs.append(sb.to_object())
    return objs, bands, doors, dec


def shot_street(cam):
    """街景（分带结构 + 门口通道 + decal + 变体轮换 + 火柴人）。"""
    wipe()
    objs, bands, doors, dec = build_street()
    render_tilt(cam, objs, 1.0, os.path.join(OUT_DIR, "pbr_ground_street.png"),
                pad_side=70.0, pad_top=40.0, pad_bottom=470.0)
    return objs, bands


def shot_wear(cam):
    """`pbr_ground_wear.png`：**重复度治理对照**（治理前 vs 治理后）+ decal 组 + 斑驳图。

    上段：decal 组 8 件（叠在道路带上，2× 放大看形态）
    中段：同一段路面 4×4 —— 左"治理前"（单变体、无斑驳、无 decal）、
          右"治理后"（变体轮换 + 低频斑驳乘图 + decal 撒布）
    下段：3 张低频大尺度斑驳乘图
    """
    wipe()
    gap, title = 22.0, 50.0
    R = G.ROAD_PX
    # ---- 上段：decal 组（2×）
    dks = [d["key"] for d in G.DECALS]
    dcell = 128.0
    W1 = 4 * (dcell + gap) + gap
    H1 = title + 2 * (dcell + 30.0) + gap
    # ---- 中段：治理前 / 治理后（各 4×4 张道路带，1:1）
    seg = 4 * R
    W2 = 2 * (seg + gap) + gap + 40.0
    H2 = title + seg + 60.0
    # ---- 下段：3 张斑驳乘图
    mot = G.MOTTLE_PX
    W3 = 3 * (mot + gap) + gap
    H3 = title + mot + 40.0
    W = max(W1, W2, W3) + 80.0
    H = 40.0 + H1 + gap + H2 + gap + H3 + 40.0
    x0, y1 = -W / 2.0, H / 2.0
    y = y1 - 40.0
    label("① 做旧 decal 组（8 件；叠在道路带上，这里显示 alpha 形状——色层见 src/*_alb）",
          0.0, y - title * 0.5, 34.0)
    y -= title
    bx = x0 + (W - W1) / 2.0 + gap
    for i, dk in enumerate(dks):
        c, r = i % 4, i // 4
        cx = bx + c * (dcell + gap)
        cy = y - r * (dcell + 30.0)
        plane("w_bg_%d" % i, cx, cx + dcell, cy - dcell, cy, 0.0,
              mat("band_road_%s" % FAM))
        nx, ny = G.kind_size(dk)
        w = nx * 1.0
        h = ny * 1.0
        plane("w_%s" % dk, cx + (dcell - w) / 2.0, cx + (dcell + w) / 2.0,
              cy - (dcell + h) / 2.0, cy - (dcell - h) / 2.0, 1.0,
              alpha_material("gt_a_%s" % dk, "%s_alb_%d.png" % (dk, G.GAME_PX)),
              uv_fn=lambda xx, yy, _a=cx + (dcell - w) / 2.0, _b=cy - (dcell + h) / 2.0,
              _w=w, _h=h: ((xx - _a) / _w, (yy - _b) / _h))
        label(dk, cx + dcell / 2.0, cy - dcell - 16.0, 22.0)
    y -= H1
    # ---- 中段：治理前 / 治理后
    label("② 同一段路面（4×4 张道路带，1:1）：左 = 治理前（单变体铺满）  右 = 治理后"
          "（变体轮换 + 低频斑驳乘图 + decal 撒布）", 0.0, y - title * 0.5, 34.0)
    y -= title
    bx2 = x0 + (W - W2) / 2.0
    for side, tag in ((0, "治理前"), (1, "治理后")):
        sx = bx2 + gap + side * (seg + gap)
        for rr in range(4):
            for cc in range(4):
                vi = 0 if side == 0 else (cc * 3 + rr * 5) % (G.VARIANTS + 1)
                m = mat("band_road_%s" % FAM, G.GAME_PX, vi)
                if side == 1:
                    m = G.mottle_material("band_road_%s" % FAM,
                                          "mottle_%s" % "abc"[rr % 3],
                                          name="gtm_seg_%d_%d" % (rr, cc))
                plane("seg_%d_%d_%d" % (side, rr, cc), sx + cc * R, sx + (cc + 1) * R,
                      y - seg + rr * R, y - seg + (rr + 1) * R, 0.0, m,
                      uv_fn=world_uv)
        if side == 1:                       # 撒 decal
            for (dk, dx, dy2, dw, dh) in (("dc_puddle", 0.30, 0.55, 96, 64),
                                          ("dc_crack", 0.62, 0.20, 128, 128),
                                          ("dc_moss", 0.12, 0.22, 96, 96),
                                          ("dc_debris", 0.45, 0.86, 96, 64),
                                          ("dc_stain", 0.80, 0.62, 64, 64)):
                ax = sx + dx * seg
                ay = y - seg + dy2 * seg
                plane("segd_%s" % dk, ax, ax + dw, ay, ay + dh, 1.5,
                      G.decal_material(dk),
                      uv_fn=lambda xx, yy, _x=ax, _y=ay, _w=dw, _h=dh:
                      ((xx - _x) / _w, (yy - _y) / _h))
        label(tag, sx + seg / 2.0, y - seg - 24.0, 30.0)
    y -= H2
    # ---- 下段：斑驳乘图
    label("③ 低频大尺度斑驳乘图（256px = 8×8 格；0.5 = 不变，引擎按 1+(m-0.5)*k 相乘，"
          "k≈0.45）", 0.0, y - title * 0.5, 34.0)
    y -= title
    bx3 = x0 + (W - W3) / 2.0 + gap
    for i, mk in enumerate(("mottle_a", "mottle_b", "mottle_c")):
        cx = bx3 + i * (mot + gap)
        _backing(cx, y - mot, mot, mot, name="bk_%s" % mk)
        mm = bw_material("gt_mshow_%s" % mk, "%s.png" % mk)
        plane("mot_%s" % mk, cx, cx + mot, y - mot, y, 0.0, mm)
        label(mk, cx + mot / 2.0, y - mot - 20.0, 24.0)
    render_rect(cam, x0, x0 + W, y1 - H, y1, 1.0,
                os.path.join(OUT_DIR, "pbr_ground_wear.png"))


def alpha_material(name, img_name):
    """把 albedo 的 **alpha 通道当亮度**显示（decal 的形状一览用）。

    为什么不用 `decal_material` 直接叠：EEVEE 里带 alpha 的 BLENDED 面在正交俯视
    下经常整片不显示 / 或显示成实心（预览层问题，**不是资产问题**——资产是 RGBA
    PNG，已逐通道验过）。形状图能如实说明 decal 覆盖范围，色层另有 alb PNG。
    """
    old = bpy.data.materials.get(name)
    if old is not None:
        bpy.data.materials.remove(old)
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    o = nt.nodes.new("ShaderNodeOutputMaterial")
    b = nt.nodes.new("ShaderNodeBsdfPrincipled")
    b.inputs["Roughness"].default_value = 0.9
    nt.links.new(b.outputs["BSDF"], o.inputs["Surface"])
    tc = nt.nodes.new("ShaderNodeTexCoord")
    t = nt.nodes.new("ShaderNodeTexImage")
    t.image = bpy.data.images[img_name]
    t.extension = "CLIP"
    nt.links.new(tc.outputs["UV"], t.inputs["Vector"])
    nt.links.new(t.outputs["Alpha"], b.inputs["Base Color"])
    return m


def bw_material(name, img_name):
    """把灰度图当反照率显示（只用于"看图"，不是游戏材质）。"""
    old = bpy.data.materials.get(name)
    if old is not None:
        bpy.data.materials.remove(old)
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    o = nt.nodes.new("ShaderNodeOutputMaterial")
    b = nt.nodes.new("ShaderNodeBsdfPrincipled")
    b.inputs["Roughness"].default_value = 0.9
    nt.links.new(b.outputs["BSDF"], o.inputs["Surface"])
    tc = nt.nodes.new("ShaderNodeTexCoord")
    t = nt.nodes.new("ShaderNodeTexImage")
    t.image = bpy.data.images[img_name]
    t.extension = "REPEAT"
    t.image.colorspace_settings.name = "Non-Color"
    nt.links.new(tc.outputs["UV"], t.inputs["Vector"])
    nt.links.new(t.outputs["Color"], b.inputs["Base Color"])
    return m


# ---------------------------------------------------------------- 自检
SEAM = {}


def seam_check(n=G.GAME_PX):
    """边界剖面锐度：把"跨缝相邻像素差"放进**图内所有剖面的平均相邻差**分布里看百分位。

    为什么这条只能当参考：砖缝 / 石板缝 / 板端缝 / 车辙这类**有结构**的图案，缝可能
    正好落在贴图边界上，这时百分位会很高，却完全不是接缝（边界就是一条真缝）。
    **真无缝由 `periodic_check` 证明**（平移整像素后图案按定义不变），
    本条只用来提示"这个图案的边界是否落在一条锐利结构上"。
    """
    print("\n=== 边界剖面锐度（%d 档；百分位 = 跨缝剖面在全部剖面中的位置）===" % n)
    for key in G.keys():
        rec = G.generate(key, n)
        row = {}
        for tag, arr in (("颜色", rec["alb"]), ("高度", rec["h"])):
            a = arr.mean(2) if arr.ndim == 3 else arr
            gu = np.abs(a[:, 1:] - a[:, :-1]).mean(0)
            gv = np.abs(a[1:, :] - a[:-1, :]).mean(1)
            su = float(np.abs(a[:, 0] - a[:, -1]).mean())
            sv = float(np.abs(a[0, :] - a[-1, :]).mean())
            row[tag] = (float((gu < su).mean()) * 100.0,
                        float((gv < sv).mean()) * 100.0, max(su, sv))
        SEAM[key] = ((row["颜色"][0] + row["颜色"][1]) / 2.0,
                     (row["高度"][0] + row["高度"][1]) / 2.0)
        hot = max(SEAM[key]) >= 95.0
        print("  %s%-14s 颜色 U/V=%3.0f%%/%3.0f%%  高度 U/V=%3.0f%%/%3.0f%%"
              "  跨缝绝对差≤%.4f  %s"
              % ("·  " if not hot else "!  ", key, row["颜色"][0], row["颜色"][1],
                 row["高度"][0], row["高度"][1],
                 max(row["颜色"][2], row["高度"][2]),
                 "（边界落在自家缝上，3×3 图复核）" if hot else ""))
    return SEAM


#: 平移校验用的整数像素偏移（含 1px 与不可约偏移，覆盖 U/V 双向）
SHIFT_CASES = [(1, 0), (0, 1), (1, 1), (37, 53), (64, 64)]


def periodic_check(n=G.GAME_PX):
    """**真无缝的证明**：把采样网格平移整数像素后重算，结果必须等于原图 roll 同样的量。

    这条不依赖任何统计口径 —— 图案若真是"世界坐标的周期函数"，平移一个像素只是
    换了取样序列；反之若哪里少取了模 / 混进了绝对下标，就会在这一步露出残差。
    三张底图（反照率 / 高度 / 粗糙度）都查，逐位看最大残差。
    平铺类（12）查 **U/V 双向**；分带 / 过渡带（12）只查 **U 向**（V 是结构方向：
    上缘贴建筑基线、下缘接下一带），所以只 roll 列。
    """
    print("\n=== 周期性证明（网格平移整像素 == 原图 roll；最大残差应为 0）===")
    bad = []
    for key in G.all_keys():
        two_way = key in G._SPEC
        base = G.generate(key, 1)
        worst = 0.0
        for (dx, dy) in (SHIFT_CASES if two_way
                         else [(1, 0), (7, 0), (37, 0), (64, 0)]):
            sh = G.generate(key, 1, shift=(dx, dy))
            for field in ("alb", "h", "rough"):
                ref = np.roll(base[field], (-dy, -dx), (0, 1))
                worst = max(worst, float(np.abs(sh[field] - ref).max()))
        bad.append((key, worst))
        print("  %s%-22s %s向，最大残差 = %.2e"
              % ("OK " if worst < 1e-12 else "!! ", key,
                 "U/V 双" if two_way else "U  ", worst))
    print("  结论：%d 种面类最大残差 %.2e → %s"
          % (len(bad), max(b[1] for b in bad),
             "图案是严格的周期函数，可平铺方向真无缝"
             if max(b[1] for b in bad) < 1e-12 else "存在非周期项，需修"))
    return bad


def _load_png_np(path):
    """把落盘的 PNG 读回 numpy（用于自检，不参与渲染）。"""
    img = bpy.data.images.load(path, check_existing=False)
    w, h = img.size
    buf = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(buf)
    a = buf.reshape(h, w, 4)[:, :, :3].astype(np.float64)
    bpy.data.images.remove(img)
    return a


def _srgb_to_lin(x):
    x = np.clip(x, 0.0, 1.0)
    return np.where(x <= 0.04045, x / 12.92, ((x + 0.055) / 1.055) ** 2.4)


def neutral_check(out_dir, keys=None, n=G.HD_PX):
    """**光照中性自检**（硬约束）：贴图里不许残留单一方向的高光/阴影梯度。

    做法（对着已落盘的 512 资产图 + 生成端的解析法线）：

    ① **方向相关性**（主判据）：把渲染亮度还原成"光照倍率" `sh = L_render / L_albedo`
       （都在线性空间，暗处钳到 0.02），再与法线的三个分量求相关：
        * `corr(sh, nx)`、`corr(sh, ny)` —— 光有没有水平分量。垂直顶光下坡度朝 +X 与
          朝 -X 的像素受光相同，两个相关**必须 ≈0**；一旦混进方向光 / 烘了太阳投影，
          nx 或 ny 的相关会立刻抬起来。
        * `corr(sh, nz)` —— 顶光本身该有的"越陡越暗"，应当是显著正值（证明法线在起作用）。
    ② **低频亮度斜坡 tilt**（辅助）：全图亮度拟合 `a + b·x + c·y`，`(b+c)/a` 即整幅
       从一头到另一头的亮暗差。含方向的太阳投影会把它推到几个百分点。注意：**图案
       自带的内容偏置（比如一边恰好多两块暗砖）也会抬高它**，所以只当辅助，别单独定罪。
    ③ 四象限极差 / 边缘-中心 / 左右上下半幅差：同上，内容偏置敏感，仅供参考。

    构造上还有两条兜底：唯一的光是**方向恰为 (0,0,-1) 的 SUN**（N·L = Nz，只与坡度
    大小有关、与朝向无关），AO 走**各向同性盒式模糊**（`G.pblur`）。
    """
    print("\n=== 光照中性自检（512 资产图；主判据 corr(sh,nx)/corr(sh,ny) ≈ 0）===")
    rows = []
    sl = (slice(None, None, 3), slice(None, None, 3))

    def corr(a, b):
        x = a[sl].ravel().astype(np.float64)
        y = b[sl].ravel().astype(np.float64)
        x = x - x.mean()
        y = y - y.mean()
        return float((x * y).sum() / (np.sqrt((x * x).sum() * (y * y).sum()) + 1e-12))

    for key in (keys or G.all_keys()):
        ren = _load_png_np(os.path.join(out_dir, "ground_tiles", "%s.png" % key))
        _k = G.kind_info(key)[3]
        alb = _load_png_np(os.path.join(
            out_dir, "ground_tiles", "src",
            "%s_alb%s.png" % (key, "" if _k in ("tile", "band", "transition")
                              else "_%d" % G.GAME_PX)))
        rec = G.generate(key, G.HD_PX)
        nx, ny = rec["size"]
        if (ren.shape[0], ren.shape[1]) != (ny, nx):
            print("  --  %-22s 跳过：薄带在出图里带上下留白（%s vs %s），"
                  "该口径不适用" % (key, (ren.shape[0], ren.shape[1]), (ny, nx)))
            continue
        nrm = G.normal_map_w(rec["h"], nx, ny, rec["relief_m"], rec["nstr"])
        nx = nrm[..., 0] * 2.0 - 1.0
        ny = nrm[..., 1] * 2.0 - 1.0
        nz = nrm[..., 2] * 2.0 - 1.0
        sh = np.clip(_srgb_to_lin(ren).mean(2)
                     / np.maximum(_srgb_to_lin(alb).mean(2), 0.02), 0.0, 4.0)
        cx, cy = corr(sh, nx), corr(sh, ny)
        sm, ss = float(sh.mean()), float(sh.std())
        L = ren.mean(2)
        # 方向对比度（主判据）：坡朝 +X 与朝 -X 的像素**原始亮度**平均差（相对 %）。
        # 必须用原始亮度：一旦除以反照率，镜面项（∝1/反照率）会把图案自身的明暗
        # 结构放大成假的"方向性"（实测 boardwalk 原始 0.00% ↔ 比值口径 +4.27%）。
        # 方向光一进来，这个数会立刻从 <1% 抬到几个百分点。
        base = max(1e-6, float(L.mean()))
        need = 0.003 * L.size

        def ddir(maskp, maskn):
            if maskp.sum() < need or maskn.sum() < need:
                return None                      # 样本不足（太平的材质没有足够斜像素）
            return (float(L[maskp].mean()) - float(L[maskn].mean())) / base * 100.0

        dirx = ddir(nx > 0.12, nx < -0.12)
        diry = ddir(ny > 0.12, ny < -0.12)
        h, w = ren.shape[0], ren.shape[1]
        yy, xx = np.mgrid[0:h, 0:w]
        X = np.stack([np.ones(h * w), xx.ravel() / float(w), yy.ravel() / float(h)], 1)
        coef = np.linalg.lstsq(X, L.ravel(), rcond=None)[0]
        tilt = (abs(coef[1]) + abs(coef[2])) / max(1e-9, abs(coef[0])) * 100.0
        q = [L[:h // 2, :w // 2].mean(), L[:h // 2, w // 2:].mean(),
             L[h // 2:, :w // 2].mean(), L[h // 2:, w // 2:].mean()]
        spread = (max(q) - min(q)) / max(1e-9, float(np.mean(q))) * 100.0
        is_tile0 = key in G._SPEC                # 分带/过渡的 V 向是结构方向，不做判定
        rows.append((key, dirx, diry, ss, tilt, spread))
        lim = 1.5
        ok = (dirx is None or abs(dirx) < lim) and             (not is_tile0 or diry is None or abs(diry) < lim)
        fmt = lambda v: ("  n/a " if v is None else "%+.2f%%" % v)
        print("  %s%-22s 方向对比度 U=%s V=%s  [参考] corr=%.2f/%.2f 光照倍率σ=%.2f  %s"
              % ("OK " if ok else "!! ", key, fmt(dirx), fmt(diry), cx, cy, ss,
                 ("内容偏置 tilt=%4.1f%%" % tilt)
                 if is_tile0 else "（分带/过渡：V 向结构，tilt/V 判定不适用）"))
    wx = max([abs(r[1]) for r in rows if r[1] is not None] or [0.0])
    wy = max([abs(r[2]) for r in rows if r[2] is not None] or [0.0])
    nbad = sum(1 for r in rows if not (
        (r[1] is None or abs(r[1]) < 1.5)
        and (r[0] not in G._SPEC or r[2] is None or abs(r[2]) < 1.5)))
    print("  结论：面上坡朝 +U/-U 的像素平均亮度差最大 %.2f%%（V 向 %.2f%%，分带不计判定）；"
          "不合格 %d/%d → %s"
          % (wx, wy, nbad, len(rows),
             "无方向性明暗：光源是垂直向下 SUN（无水平分量），AO 各向同性，"
             "贴图光照中性" if nbad == 0 else "有方向性残留，需复查"))
    print("  （[参考] 光照倍率 = 渲染/反照率：它与 nx/ny 无关而与高度有关 —— 这正是"
          "\"只有坡度、没有朝向\"的读数；标准差>0 说明 AO/起伏确实在起作用）")
    return rows


def shot_night(cam, objs, day_path):
    """夜晚调制示意：同一批中性贴图 + 冷暗顶光 + 暖色灯笼光斑，同机位再渲一张。"""
    path = os.path.join(OUT_DIR, "pbr_ground_night.png")
    bpy.context.scene.world = bpy.data.worlds["gt_wnight"]
    lights_mode(LIGHTS, "night")
    render_tilt(cam, objs, 1.0, path, pad_side=60.0, pad_top=40.0, pad_bottom=620.0)
    day = _load_png_np(day_path)
    night = _load_png_np(path)
    # 只统计画面下方 45%（地面主场），避免天空/屋顶干扰
    cut = int(day.shape[0] * 0.55)
    dl = day[cut:].mean()
    nl = night[cut:].mean()
    print("  夜晚调制：地面区平均亮度 %.3f → %.3f（%+.0f%%），冷蓝顶光 x 暖色灯笼光斑"
          % (dl, nl, (nl / max(1e-9, dl) - 1.0) * 100.0))
    return path


LIGHTS = {}


# ---------------------------------------------------------------- main
def main():
    global TILT, LIGHTS
    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(TILE_DIR, exist_ok=True)
    only = os.environ.get("GROUND_ONLY", "")
    no_night = os.environ.get("GROUND_NO_NIGHT", "") == "1"

    clear()
    setup_render()
    LIGHTS = build_lights()
    w_flat = world_flat()
    world_night()
    w_sky = world_sky()

    print("== 落盘贴图（alb / 法线 / 粗糙度 + json）→", TILE_DIR)
    G.export_all(TILE_DIR)
    periodic_check()
    seam_check()

    cam = make_cam()
    bpy.context.scene.world = w_flat
    lights_mode(LIGHTS, "flat")
    if only in ("", "faces"):
        for attr in ("use_gtao", "use_gtao_bent_normals", "use_raytracing"):
            try:
                setattr(bpy.context.scene.eevee, attr, False)
            except Exception:
                pass
        shoot_all_faces(cam)            # 24 个"面"类 × (512 / 128 / 128_v1~v3)
        neutral_check(OUT_DIR)          # 对着刚落盘的 512 资产图自查光照中性
        try:
            bpy.context.scene.eevee.use_gtao = True
        except Exception:
            pass
    if only in ("", "sheets"):
        shot_kind_sheet(cam)
        shot_seam(cam)
        shot_game1x(cam)
        shot_wear(cam)
    if only in ("", "segs"):
        shot_segments(cam)
        shot_chain(cam)
        shot_decals(cam)
        shot_pieces(cam)

    bpy.context.scene.world = w_sky
    lights_mode(LIGHTS, "street")
    objs = shot_grid_demo(cam)          # 动态建造层网格拼接演示（含拆一栋露底）
    objs, bands = shot_street(cam)
    for (name, wc, x0, x1) in bands:
        print("  街景: %s w%d  x∈[%.0f, %.0f]（%.0f 宽 = %d 格）"
              % (name, wc, x0, x1, x1 - x0, int(round((x1 - x0) / CELL))))
    if not no_night:
        shot_night(cam, objs, os.path.join(OUT_DIR, "pbr_ground_street.png"))

    print("\nGROUND_OK")


main()
