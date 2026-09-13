# -*- coding: utf-8 -*-
"""probe_interiors.py —— 建筑内景层 + 前/后分层交付探针（管线 v3 · 写实 PBR）

跑法（渲染模式，Blender）::

    "/f/SteamLibrary/steamapps/common/Blender/blender.exe" -b --factory-startup \\
        -P tools/blender_buildings/probe_interiors.py

跑法（合成模式，系统 python；不需要 Blender，只用 PIL/numpy）::

    python tools/blender_buildings/probe_interiors.py

渲染模式产出（均带 alpha，`film_transparent=True`；`stick-world/temp/`）::

    pbr_int_<def>_back.png    后层（Interior 层）：后墙 + 地板 + 天花 + 家具 + 暖光
    pbr_int_<def>_front.png   前层（Exterior + WallFront）：前墙 + 屋顶 + 门窗框，
                              窗玻璃真透明（教堂保留彩窗）
    _int_layers_{back,front}.png   house 2x 临时对（供合成演示）
    _int_win_{back,front}.png      shop 4x 窗洞临时对（供窗户特写）

合成模式产出::

    pbr_int_layers.png  三格并排：back / front 全不透明 / front alpha=0.3 叠在 back 上
                        （第三格直接模拟游戏 `WallFront.modulate.a = 0.3` 的合成结果）
    pbr_int_window.png  shop 大窗特写（front 不透明叠 back）：透过真透明窗格看到内景家具与暖光
    pbr_int_sheet2x.png 七套内景 back 的 2x 拼页（自检 + 观感验收用）

约定：视角 yaw=0 / tilt=20（硬约束）；相机对 back/front 是**同一台、同一取景**，
所以两张图天然像素级对齐（前层叠后层不需要任何对位）。
"""

import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

try:
    import bpy
    HAVE_BPY = True
except ImportError:            # 系统 python：走合成模式
    HAVE_BPY = False

OUT_DIR = ("F:/VSCode/game-2/.temp/building-pipeline-v2/stick-world/temp")

YAW = 0.0
TILT = 20.0

#: 交付清单（与 interiors.defs() 一致；内景与前层共用同一档宽度）
DEFS = (("house", 12), ("townhouse", 12), ("smithy1", 8), ("tavern", 12),
        ("bakery", 12), ("shop", 12), ("cathedral", 16))

#: 窗户特写用的 def 与取景矩形（世界坐标：x0, x1, z0, z1，落在前墙面上）
#: shop w12 的橱窗 = x 78±90、玻璃 z 62~140（`assemble_shop`：glass_z0 = plinth+44）
WIN_DEF = ("shop", 12)
WIN_RECT = (-24.0, 184.0, 12.0, 206.0)


# ================================================================ 渲染模式

def _clear():
    import buildings as B
    import materials
    bpy.ops.wm.read_factory_settings(use_empty=True)
    materials.reset_cache()
    B._CACHE.clear()
    B._MAGIC_KEYS.clear()


def _mk_world(name, color, strength):
    w = bpy.data.worlds.new(name)
    w.use_nodes = True
    bg = w.node_tree.nodes.get("Background")
    if bg is None:
        bg = w.node_tree.nodes.new("ShaderNodeBackground")
    bg.inputs[0].default_value = tuple(color) + (1.0,)
    bg.inputs[1].default_value = strength
    return w


def _setup_scene():
    sc = bpy.context.scene
    for eng in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE", "CYCLES"):
        try:
            sc.render.engine = eng
            break
        except Exception:
            continue
    sc.render.film_transparent = True               # 交付图必须带 alpha
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_mode = "RGBA"
    sc.render.resolution_percentage = 100
    sc.view_settings.view_transform = "Standard"
    sc.view_settings.look = "None"
    for attr, val in (("taa_render_samples", 48),):
        try:
            setattr(sc.eevee, attr, val)
        except Exception:
            pass
    sc["world_int"] = _mk_world("W_int", (0.30, 0.25, 0.20), 0.26)
    sc["world_ext"] = _mk_world("W_ext", (0.62, 0.70, 0.82), 0.60)
    return sc


def _sun(name, energy, rot, angle=3.0, color=(1.0, 0.95, 0.85)):
    sc = bpy.context.scene
    d = bpy.data.lights.new(name, "SUN")
    d.energy = energy
    d.angle = math.radians(angle)
    d.color = color
    ob = bpy.data.objects.new(name, d)
    ob.rotation_euler = tuple(math.radians(a) for a in rot)
    sc.collection.objects.link(ob)
    return ob


def _point_lights(specs):
    sc = bpy.context.scene
    out = []
    for i, s in enumerate(specs):
        d = bpy.data.lights.new("int_p%d" % i, "POINT")
        d.energy = s["energy"]
        d.color = s["color"]
        try:
            d.shadow_soft_size = s.get("radius", 40.0)
        except Exception:
            pass
        ob = bpy.data.objects.new("int_p%d" % i, d)
        ob.location = tuple(s["loc"])
        sc.collection.objects.link(ob)
        out.append(ob)
    return out


def _make_camera():
    d = bpy.data.cameras.new("cam")
    d.type = "ORTHO"
    d.clip_start = 1.0
    d.clip_end = 60000.0
    ob = bpy.data.objects.new("cam", d)
    bpy.context.scene.collection.objects.link(ob)
    bpy.context.scene.camera = ob
    return ob


def _framing_objs(B, objs, pad_side=38.0, pad_top=30.0):
    pts = []
    for ob in objs:
        pts += B.shape_points(ob, skip_ground=False)
    right, up = B.cam_axes(YAW, TILT)
    us = [p.dot(right) for p in pts]
    vs = [p.dot(up) for p in pts]
    return (min(us) - pad_side, max(us) + pad_side, min(vs) - pad_side,
            max(vs) + pad_top)


def _framing_rect(B, x0, x1, z0, z1, y=0.0, pad=18.0):
    from mathutils import Vector
    right, up = B.cam_axes(YAW, TILT)
    cs = [(x0, y, z0), (x1, y, z0), (x0, y, z1), (x1, y, z1)]
    us = [Vector(c).dot(right) for c in cs]
    vs = [Vector(c).dot(up) for c in cs]
    return (min(us) - pad, max(us) + pad, min(vs) - pad, max(vs) + pad)


def _place_cam(B, cam, fr, zoom, res_max=6000):
    from mathutils import Vector
    u0, u1, v0, v1 = fr
    w, h = (u1 - u0), (v1 - v0)
    cu, cv = (u0 + u1) / 2.0, (v0 + v1) / 2.0
    right, up = B.cam_axes(YAW, TILT)
    anchor = right * cu + up * cv
    fwd = -(right.cross(up))
    cam.location = tuple(Vector(anchor) - fwd * 12000.0)
    cam.rotation_euler = (math.radians(90.0 - TILT), 0.0, math.radians(YAW))
    cam.data.ortho_scale = max(w, h)
    k = min(1.0, res_max / float(max(w, h) * zoom))
    rx = max(64, int(round(w * zoom * k)))
    ry = max(64, int(round(h * zoom * k)))
    sc = bpy.context.scene
    sc.render.resolution_x = rx
    sc.render.resolution_y = ry
    return (rx, ry)


def _vis(obs, on):
    for ob in obs:
        ob.hide_render = not on


def _shoot(path):
    sc = bpy.context.scene
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)


def _drop(objs):
    for ob in objs:
        try:
            bpy.data.objects.remove(ob, do_unlink=True)
        except Exception:
            pass


def _render_pair(B, interiors, cam, ext, name, wc, zoom, back_path, front_path,
                 frame=None, samples=None):
    """建一栋的 back/front 两层，同一相机取景各渲一张（带 alpha）。"""
    sc = bpy.context.scene
    back, L = interiors.build_back(name, wc)
    front, spec = interiors.build_front(name, wc)
    fr = frame if frame else _framing_objs(B, [front, back])
    res = _place_cam(B, cam, fr, zoom)
    il = _point_lights(interiors.lights(name, L))
    sc.world = sc["world_int"]
    if samples:
        sc.eevee.taa_render_samples = samples
    # ---- 后层（Interior）
    _vis([back], True)
    _vis([front], False)
    _vis(ext, False)
    _vis(il, True)
    _shoot(back_path)
    # ---- 前层（Exterior + WallFront）
    _vis([back], False)
    _vis([front], True)
    _vis(ext, True)
    _vis(il, False)
    sc.world = sc["world_ext"]
    _shoot(front_path)
    _drop(il)
    _drop([back, front])
    return L, spec, res


def render_mode():
    import buildings as B
    import interiors

    os.makedirs(OUT_DIR, exist_ok=True)
    _clear()
    sc = _setup_scene()
    cam = _make_camera()
    ext = [_sun("key", 3.3, (40, 0, -38)),
           _sun("fill", 0.15, (55, 0, 128), 20.0, (0.85, 0.90, 1.0))]

    only = [s for s in os.environ.get("INT_ONLY", "").split(",") if s]
    pairs = [d for d in DEFS if not only or d[0] in only]
    print("\n=== 内景 + 前/后分层交付 ===")
    print("%-10s %3s %6s %6s %7s %6s %5s %s"
          % ("def", "格", "净宽", "净深", "层高", "点光", "换玻璃", "产物"))
    for (name, wc) in pairs:
        bp = os.path.join(OUT_DIR, "pbr_int_%s_back.png" % name)
        fp = os.path.join(OUT_DIR, "pbr_int_%s_front.png" % name)
        L, spec, res = _render_pair(B, interiors, cam, ext, name, wc, 1.0,
                                    bp, fp, samples=48)
        print("%-10s %3d %6.0f %6.0f %7.0f %6d %5s %s  (%dx%d)"
              % (name, wc, L["xh"] * 2.0, L["depth"], L["back_h"],
                 len(interiors.lights(name, L)), "-", "back+front", res[0], res[1]))

    # ---- 合成用的临时对：house 2x（层叠演示）、shop 4x 窗洞特写
    if not only:
        lv_b = os.path.join(OUT_DIR, "_int_layers_back.png")
        lv_f = os.path.join(OUT_DIR, "_int_layers_front.png")
        _render_pair(B, interiors, cam, ext, "house", 12, 2.0, lv_b, lv_f,
                     samples=64)
        win_name, win_wc = WIN_DEF
        wb = os.path.join(OUT_DIR, "_int_win_back.png")
        wf = os.path.join(OUT_DIR, "_int_win_front.png")
        fr = _framing_rect(B, *WIN_RECT)
        _render_pair(B, interiors, cam, ext, win_name, win_wc, 4.0, wb, wf, frame=fr,
                     samples=64)
    print("\n渲染完成 → %s" % OUT_DIR)
    print("（合成模式：python tools/blender_buildings/probe_interiors.py）")
    print("INTERIORS_RENDER_OK")


# ================================================================ 合成模式

def _bg_checker(w, h, cell=22):
    import numpy as np
    yy, xx = np.mgrid[0:h, 0:w]
    chk = ((xx // cell + yy // cell) % 2).astype(np.float32)
    g = 0.40 + 0.06 * chk
    out = np.ones((h, w, 4), np.float32)
    out[..., 0] = g
    out[..., 1] = g
    out[..., 2] = g * 1.04
    return out


def _over(bg, src, mul=1.0):
    """直通 alpha 合成：src 的 alpha 再乘 mul（mul=0.3 → 模拟 WallFront.modulate.a）。"""
    import numpy as np
    a = src[..., 3:4] * mul
    out = bg.copy()
    out[..., :3] = src[..., :3] * a + bg[..., :3] * (1.0 - a)
    out[..., 3] = 1.0
    return out


def _load(path):
    import numpy as np
    from PIL import Image
    im = Image.open(path).convert("RGBA")
    a = np.asarray(im).astype(np.float32) / 255.0
    return a[::-1]                      # PIL 顶行 → 翻成底行（与渲染像素序一致）


def _save(arr, path):
    import numpy as np
    from PIL import Image
    a = np.clip(arr[::-1], 0.0, 1.0)
    Image.fromarray((a * 255.0 + 0.5).astype(np.uint8), "RGBA").save(path)


def _label(img, text, h=34):
    """在顶部压一条标题带（PIL 默认字体，够读即可）。"""
    from PIL import Image, ImageDraw
    w, hh = img.size
    band = Image.new("RGBA", (w, h), (18, 18, 20, 255))
    d = ImageDraw.Draw(band)
    d.text((10, 9), text.encode("ascii", "replace").decode("ascii"),
           fill=(235, 232, 226, 255))
    out = Image.new("RGBA", (w, hh + h), (0, 0, 0, 0))
    out.paste(band, (0, 0))
    out.paste(img, (0, h))
    return out


def _npimg(arr):
    import numpy as np
    from PIL import Image
    a = np.clip(arr[::-1], 0.0, 1.0)
    return Image.fromarray((a * 255.0 + 0.5).astype(np.uint8), "RGBA")


def compose_mode():
    from PIL import Image
    os.makedirs(OUT_DIR, exist_ok=True)

    # ---- 1) pbr_int_layers.png：三格并排（back / front / front@0.3 over back）
    lb = _load(os.path.join(OUT_DIR, "_int_layers_back.png"))
    lf = _load(os.path.join(OUT_DIR, "_int_layers_front.png"))
    h, w, _ = lb.shape
    bg = _bg_checker(w, h, 22)
    p1 = _over(bg, lb)
    p2 = _over(bg, lf)
    p3 = _over(_over(bg, lb), lf, mul=0.30)
    gap = 10
    sheet = Image.new("RGBA", (w * 3 + gap * 2, h), (24, 24, 26, 255))
    for i, arr in enumerate((p1, p2, p3)):
        sheet.paste(_npimg(arr), (i * (w + gap), 0))
    sheet = _label(sheet, "back (Interior) | front opaque (Exterior+WallFront) | "
                          "front alpha=0.3 over back  == game WallFront.modulate.a=0.3")
    sheet.save(os.path.join(OUT_DIR, "pbr_int_layers.png"))

    # ---- 2) pbr_int_window.png：shop 大窗特写（front 不透明叠 back）
    wb = _load(os.path.join(OUT_DIR, "_int_win_back.png"))
    wf = _load(os.path.join(OUT_DIR, "_int_win_front.png"))
    h2, w2, _ = wb.shape
    bg2 = _bg_checker(w2, h2, 18)
    win = _label(_npimg(_over(_over(bg2, wb), wf)), "see-through window: interior "
                 "furniture + warm light visible through clear glass")
    win.save(os.path.join(OUT_DIR, "pbr_int_window.png"))

    # ---- 3) pbr_int_sheet2x.png：七套内景 back 的 2x 拼页
    tiles = []
    for (name, _wc) in DEFS:
        im = Image.open(os.path.join(OUT_DIR, "pbr_int_%s_back.png" % name)).convert("RGBA")
        im = im.resize((im.width * 2, im.height * 2), Image.LANCZOS)
        tiles.append(_label(im, "%s interior (back) 2x" % name))
    rows, cols = 2, 4
    cw = max(t.width for t in tiles)
    ch = max(t.height for t in tiles)
    sheet2 = Image.new("RGBA", (cols * (cw + 8) + 8, rows * (ch + 8) + 8),
                       (26, 26, 28, 255))
    for i, t in enumerate(tiles):
        r, c = divmod(i, cols)
        sheet2.paste(t, (8 + c * (cw + 8), 8 + r * (ch + 8)))
    sheet2.convert("RGB").save(os.path.join(OUT_DIR, "pbr_int_sheet2x.png"))

    for f in ("pbr_int_layers.png", "pbr_int_window.png", "pbr_int_sheet2x.png"):
        p = os.path.join(OUT_DIR, f)
        print("%-24s %s" % (f, p))
    print("INTERIORS_COMPOSE_OK")


def main():
    if HAVE_BPY:
        render_mode()
    else:
        compose_mode()


if __name__ == "__main__":
    main()
