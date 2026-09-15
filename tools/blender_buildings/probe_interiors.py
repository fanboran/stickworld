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
                        （第三格直接模拟游戏 `WallFront.modulate.a = 0.3` 的合成结果；
                        代表 def = imperial_palace 王座厅，LAYERS_FRAME 取景）
    pbr_int_window.png  shop 大窗特写（front 不透明叠 back）：透过真透明窗格看到内景家具与暖光
    pbr_int_sheet2x.png 全部 def 内景 back 的 2x 拼页（自检 + 观感验收用）

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

OUT_DIR = ("F:/VSCode/game-2/stick-world/temp")

YAW = 0.0
TILT = 20.0

#: 交付清单（与 interiors.defs() 一致；内景与前层共用同一档宽度）
#: 29 套既有全 def 覆盖 + 行政轮 5 套（belfry 钟楼无内景，跳过）= 34 套。
DEFS = (("house", 12), ("townhouse", 12), ("smithy1", 8), ("tavern", 12),
        ("bakery", 12), ("shop", 12), ("cathedral", 16),
        ("barn", 12), ("cottage", 8), ("stable", 12), ("shelter", 6),
        ("hayloft", 12), ("guildhall", 12), ("smithy2", 8), ("smithy3", 12),
        ("smithy4", 12), ("barracks", 12), ("warehouse", 12), ("alchemy", 12),
        ("library", 12), ("rowhouse", 12), ("windmill", 6), ("tower", 6),
        ("gatehouse", 8), ("mage_tower", 6), ("lighthouse", 6),
        ("plaster_house", 12), ("church", 12), ("chapel", 8),
        ("council_hall", 8), ("town_hall", 12), ("governor_palace", 16),
        ("imperial_palace", 16), ("mint", 12))

#: 三格机制图（back / front 不透明 / front@0.3 over back）用的 def 与取景框：
#: 行政轮换成 imperial_palace 王座厅当代表（全档最华丽、最有视觉冲击）。
#: 取景框（世界坐标 x0, x1, z0, z1）压到台基大台阶~三层下段，王座厅占画面主体，
#: 不带双塔穹顶（否则 1000+ 全高会把王座厅压成一条）。
LAYERS_DEF = ("imperial_palace", 16)
LAYERS_FRAME = (-340.0, 340.0, -170.0, 700.0)

#: 像素对齐抽样实测（渲完后读 PNG 的 alpha 包围盒核对，见 `_verify_alignment`）：
#: 行政轮追加 council_hall / imperial_palace / mint（全量渲时 34 套全查）。
ALIGN_SAMPLE = ("house", "barn", "tower",
                "council_hall", "imperial_palace", "mint")

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
    sc["world_int"] = _mk_world("W_int", (0.34, 0.29, 0.24), 0.34)
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
    return (rx, ry, fr)


def _pix_map(B, fr, res):
    """世界坐标 → 渲染像素列的换算（YAW=0 下 right 轴 = 世界 +X）。

    返回的世界→像素映射对 back / front 两张图**是同一个**（同相机同分辨率），
    这正是"两层天然像素级对齐"的算术依据；`_verify_alignment` 再用实测包围盒核对。
    """
    u0, u1, v0, v1 = fr
    rx, ry = res
    right, up = B.cam_axes(YAW, TILT)
    su = rx / float(u1 - u0)
    sv = ry / float(v1 - v0)
    return dict(su=su, sv=sv, u0=u0, v0=v0, right=tuple(right), up=tuple(up),
                rx=rx, ry=ry)


def _world_to_col(pm, p):
    return (p[0] - pm["u0"]) * pm["su"]


def _world_to_row(pm, p):
    """世界点 → 自底向上的像素行（Blender 像素序）：v = up·p。"""
    up = pm["up"]
    v = up[0] * p[0] + up[1] * p[1] + up[2] * p[2]
    return (v - pm["v0"]) * pm["sv"]


def _alpha_bbox(path):
    """读渲染 PNG 的 alpha>阈值 包围盒（Blender 像素序：行 0 = 底部）。"""
    import numpy as np
    img = bpy.data.images.load(path)
    try:
        w, h = img.size
        px = np.array(img.pixels[:], dtype=np.float32).reshape(h, w, 4)
        a = px[..., 3]
        ys, xs = np.nonzero(a > 0.06)
        if len(xs) == 0:
            return None
        return dict(x0=int(xs.min()), x1=int(xs.max()), y0=int(ys.min()),
                    y1=int(ys.max()), w=w, h=h)
    finally:
        bpy.data.images.remove(img)


def _alpha_row_span(path, row):
    """取某一行（自底向上计数）的 alpha>0.06 列跨度 —— 用于量"墙/地板边缘"。

    比包围盒可靠：包围盒中心会被**单侧伸出的家具**（左墙边一只箱等）带偏，
    而地板行只在 `±xh` 有实体，量出来的就是后墙内表面的像素列。
    """
    import numpy as np
    img = bpy.data.images.load(path)
    try:
        w, h = img.size
        if row < 0 or row >= h:
            return None
        px = np.array(img.pixels[:], dtype=np.float32).reshape(h, w, 4)
        xs = np.nonzero(px[row, :, 3] > 0.06)[0]
        if len(xs) == 0:
            return None
        return (int(xs.min()), int(xs.max()))
    finally:
        bpy.data.images.remove(img)


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
    """建一栋的 back/front 两层，同一相机取景各渲一张（带 alpha）。

    返回 (L, spec, res, info)；`info` 里带该栋的世界包围盒与像素映射，
    供 `_verify_alignment` 做"渲染像素 ↔ 装配器实际宽度/基线"的实测核对。
    """
    sc = bpy.context.scene
    back, L = interiors.build_back(name, wc)
    front, spec = interiors.build_front(name, wc)
    fr = frame if frame else _framing_objs(B, [front, back])
    rx, ry, fr = _place_cam(B, cam, fr, zoom)
    res = (rx, ry)
    pm = _pix_map(B, fr, res)
    mb = B.measure(back)
    mf = B.measure(front)
    info = dict(pm=pm, back_x=mb["x"], front_x=mf["x"], back_z=mb["z"],
                front_z=mf["z"])
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
    return L, spec, res, info


def _verify_alignment(name, back_path, front_path, info, L):
    """抽样实测：两层 PNG 的 alpha 包围盒 vs **装配器实测世界尺寸 × 像素映射**。

    `_world_to_col` 只用到世界 x（YAW=0 下 right 轴 = +X），所以 alpha 包围盒的
    左右极值 = 该层几何的世界 x 跨度，是干净的"墙↔像素"量具（不会像"行扫描"那样
    被 20° 俯角斜切进来的家具干扰）：

      · back 层已按外墙夹紧（`interiors.clip_to_walls`）→ 跨度应 = 建筑全宽 `W`；
      · front 层 = 装配器成品（含出檐/前凸）→ 跨度应 = `B.measure(front)` 的 x 跨度；
      · 两层的**跨度中心**都应落在世界 x=0 的同一像素列（建筑以原点为中心）。

    这三条成立 ⇒ "后层内景与前层外皮同宽度、同基线、像素级对齐"（两层同机位同分辨率，
    映射唯一）。`px_per_unit` 顺带给出该档 1 世界单位 = 多少像素（1:1 = 1.000）。
    """
    pm = info["pm"]
    su = pm["su"]
    pivot = _world_to_col(pm, (0.0, 0.0, 0.0))
    bb = _alpha_bbox(back_path)
    bf = _alpha_bbox(front_path)
    if bb is None or bf is None:
        return None
    back_c = (bb["x0"] + bb["x1"]) / 2.0
    front_c = (bf["x0"] + bf["x1"]) / 2.0
    back_w = bb["x1"] - bb["x0"] + 1
    front_w = bf["x1"] - bf["x0"] + 1
    back_w_exp = L["W"] * su
    front_w_exp = (info["front_x"][1] - info["front_x"][0]) * su
    out = dict(def_name=name, res=(pm["rx"], pm["ry"]), px_per_unit=round(su, 4),
               floor_row=int(round(_world_to_row(pm, (0.0, 0.0, L["plinth"])))),
               pivot_col=round(pivot, 2),
               back_bbox=(bb["x0"], bb["x1"]), front_bbox=(bf["x0"], bf["x1"]),
               back_center=round(back_c, 2), front_center=round(front_c, 2),
               back_px=back_w, front_px=front_w,
               back_px_exp=round(back_w_exp, 1),
               front_px_exp=round(front_w_exp, 1),
               clipped=int(L.get("clipped", 0)))
    out["back_w_err"] = round(abs(back_w - back_w_exp), 1)
    out["front_w_err"] = round(abs(front_w - front_w_exp), 1)
    out["back_c_err"] = round(abs(back_c - pivot), 2)
    out["front_c_err"] = round(abs(front_c - pivot), 2)
    out["OK"] = bool(out["back_w_err"] <= 3.0 and out["front_w_err"] <= 3.0
                     and out["back_c_err"] <= 1.5 and out["front_c_err"] <= 1.5)
    return out


def render_mode():
    import buildings as B
    import interiors

    os.makedirs(OUT_DIR, exist_ok=True)
    _clear()
    sc = _setup_scene()
    cam = _make_camera()
    ext = [_sun("key", 3.3, (40, 0, -38)),
           _sun("fill", 0.15, (55, 0, 128), 20.0, (0.85, 0.90, 1.0))]

    # 清单一致性：字面量 DEFS 必须与 interiors.defs() 完全一致（防漏/防多）
    live = interiors.defs()
    want = dict(DEFS)
    miss = sorted(set(live) - set(want))
    extra = sorted(set(want) - set(live))
    dif = sorted(k for k in set(live) & set(want) if live[k] != want[k])
    if miss or extra or dif:
        print("!! DEFS 与 interiors.defs() 不一致：缺 %s / 多 %s / 档位差 %s"
              % (miss, extra, dif))

    only = [s for s in os.environ.get("INT_ONLY", "").split(",") if s]
    pairs = [d for d in DEFS if not only or d[0] in only]
    print("\n=== 内景 + 前/后分层交付（%d 套）===" % len(pairs))
    print("%-14s %3s %5s %5s %6s %5s %5s %s"
          % ("def", "格", "净宽", "净深", "层高", "层", "点光", "产物"))
    aligns = []
    failed = []
    for (name, wc) in pairs:
        bp = os.path.join(OUT_DIR, "pbr_int_%s_back.png" % name)
        fp = os.path.join(OUT_DIR, "pbr_int_%s_front.png" % name)
        try:
            L, spec, res, info = _render_pair(B, interiors, cam, ext, name, wc, 1.0,
                                              bp, fp, samples=48)
        except Exception as exc:                # 一个 def 崩了不要拖垮整批
            import traceback
            failed.append(name)
            print("!! %-14s 渲染失败: %s" % (name, exc))
            traceback.print_exc()
            continue
        print("%-14s %3d %5.0f %5.0f %6.0f %5d %5d %s  (%dx%d) 夹紧 %d 面"
              % (name, wc, L["xh"] * 2.0, L["depth"], L["back_h"],
                 len(L.get("mids", [])), len(interiors.lights(name, L)),
                 "back+front", res[0], res[1], L.get("clipped", 0)))
        if name in ALIGN_SAMPLE or not only:
            a = _verify_alignment(name, bp, fp, info, L)
            if a is not None:
                aligns.append(a)
    if failed:
        print("!! 失败 def：%s" % ", ".join(failed))

    # ---- 三格机制图 + 窗洞特写的临时对
    if not only:
        try:
            lv_name, lv_wc = LAYERS_DEF
            lv_b = os.path.join(OUT_DIR, "_int_layers_back.png")
            lv_f = os.path.join(OUT_DIR, "_int_layers_front.png")
            lv_fr = _framing_rect(B, *LAYERS_FRAME)
            _render_pair(B, interiors, cam, ext, lv_name, lv_wc, 2.0, lv_b, lv_f,
                         frame=lv_fr, samples=64)
        except Exception as exc:
            failed.append("layers:%s" % LAYERS_DEF[0])
            print("!! 三格机制图渲染失败: %s" % exc)
        try:
            win_name, win_wc = WIN_DEF
            wb = os.path.join(OUT_DIR, "_int_win_back.png")
            wf = os.path.join(OUT_DIR, "_int_win_front.png")
            fr = _framing_rect(B, *WIN_RECT)
            _render_pair(B, interiors, cam, ext, win_name, win_wc, 4.0, wb, wf,
                         frame=fr, samples=64)
        except Exception as exc:
            failed.append("window:%s" % WIN_DEF[0])
            print("!! 窗洞特写渲染失败: %s" % exc)

    # ---- 像素对齐实测汇总（写 json，报告直接引用；**与既有表合并**，
    #      这样 `INT_ONLY=` 的重渲不会把其它 def 的实测记录抹掉）
    import json
    ap = os.path.join(OUT_DIR, "pbr_int_alignment.json")
    if os.path.exists(ap):
        try:
            with open(ap, encoding="utf-8") as fh:
                old = {a["def_name"]: a for a in json.load(fh)}
        except Exception:
            old = {}
    else:
        old = {}
    for a in aligns:
        old[a["def_name"]] = a
    merged = [old[k] for k in sorted(old)]
    with open(ap, "w", encoding="utf-8") as fh:
        json.dump(merged, fh, ensure_ascii=False, indent=1)
    print("\n=== 像素对齐实测（抽样 %d 栋：两层包围盒跨度 vs 装配器实测宽度）==="
          % len(aligns))
    print("%-14s %7s %8s %8s %8s %8s %8s %8s %6s"
          % ("def", "px/单位", "back宽", "期望", "back中心", "front宽", "期望",
             "front中心", "结论"))
    bad = []
    for a in aligns:
        if not a["OK"]:
            bad.append(a["def_name"])
        print("%-14s %7.3f %8d %8.1f %8.2f %8d %8.1f %8.2f %6s"
              % (a["def_name"], a["px_per_unit"], a["back_px"], a["back_px_exp"],
                 a["back_c_err"], a["front_px"], a["front_px_exp"],
                 a["front_c_err"], "OK" if a["OK"] else "!!"))
    print("（标准：back 跨度 = 建筑全宽 W × px/单位；front 跨度 = 装配器实测 x 跨度 ×"
          " px/单位；两中心都落在世界 x=0 的像素列；后层已按外墙夹紧）")
    if bad:
        print("!! 不过：%s" % ", ".join(bad))
    print("对齐实测明细 → %s" % ap)
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
    sheet = _label(sheet, "%s back (Interior) | front opaque | "
                          "front alpha=0.3 over back == game WallFront.modulate.a=0.3"
                          % LAYERS_DEF[0])
    sheet.save(os.path.join(OUT_DIR, "pbr_int_layers.png"))

    # ---- 2) pbr_int_window.png：shop 大窗特写（front 不透明叠 back）
    wb = _load(os.path.join(OUT_DIR, "_int_win_back.png"))
    wf = _load(os.path.join(OUT_DIR, "_int_win_front.png"))
    h2, w2, _ = wb.shape
    bg2 = _bg_checker(w2, h2, 18)
    win = _label(_npimg(_over(_over(bg2, wb), wf)), "see-through window: interior "
                 "furniture + warm light visible through clear glass")
    win.save(os.path.join(OUT_DIR, "pbr_int_window.png"))

    # ---- 3) pbr_int_sheet2x.png：全部 def 内景 back 总览拼页
    #: 小体量（单层）给到真 2x 便于看清家具；高塔（>450px）按 900px 上限缩放，
    #: 保证整页尺寸可控（标注里写明每格的倍率）。
    MAX_TILE_H = 900
    tiles = []
    for (name, _wc) in DEFS:
        p = os.path.join(OUT_DIR, "pbr_int_%s_back.png" % name)
        if not os.path.exists(p):
            continue
        im = Image.open(p).convert("RGBA")
        sc = min(2.0, MAX_TILE_H / float(im.height))
        im = im.resize((max(1, int(im.width * sc)), max(1, int(im.height * sc))),
                       Image.LANCZOS)
        tiles.append(_label(im, "%s  x%.2f" % (name, sc)))
    cols = 6
    rows = (len(tiles) + cols - 1) // cols
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


def verify_report_mode():
    """只读 `pbr_int_alignment.json` 重印对齐表（不需要 Blender，也不重渲）。"""
    import json
    ap = os.path.join(OUT_DIR, "pbr_int_alignment.json")
    if not os.path.exists(ap):
        print("!! 缺 %s（先跑一次渲染模式）" % ap)
        return
    with open(ap, encoding="utf-8") as fh:
        data = json.load(fh)
    # 圆塔：后层只画 y>0 的**背面半圈**（否则会把室内糊住），bbox 天然窄于建筑宽度、
    # 也不关于 x=0 对称 → 判据换成**上界**："后层不得越出前层塔身外皮"（W = 2R，
    # 两层的 x 极值都已被 `clip_to_walls` 夹在 ±W/2 内）。
    for a in data:
        if a["def_name"] in ("windmill", "mage_tower", "lighthouse"):
            a["OK"] = bool(a["back_px"] <= a["back_px_exp"] + 2.0
                           and a["front_w_err"] <= 3.0 and a["front_c_err"] <= 1.5)
            a["criterion"] = "round: back ⊆ front tower body"
        else:
            a["criterion"] = "bbox_vs_assembler_width"
    with open(ap, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=1)
    print("\n=== 像素对齐实测（%d 栋）===" % len(data))
    print("%-14s %7s %8s %8s %8s %8s %8s %5s %6s"
          % ("def", "px/单位", "back宽", "期望", "back中心", "front宽", "期望",
             "夹紧", "结论"))
    bad = []
    for a in data:
        if not a["OK"]:
            bad.append(a["def_name"])
        exp = a.get("back_px_exp_round", a["back_px_exp"])
        print("%-14s %7.3f %8d %8.1f %8.2f %8d %8.1f %5d %6s"
              % (a["def_name"], a["px_per_unit"], a["back_px"], exp,
                 a["back_c_err"], a["front_px"], a["front_px_exp"],
                 a.get("clipped", 0), "OK" if a["OK"] else "!!"))
    print("结论：%d/%d 通过%s；明细 → %s"
          % (len(data) - len(bad), len(data),
             ("（不过：%s）" % ", ".join(bad)) if bad else "", ap))
    print("INTERIORS_VERIFY_OK")


def main():
    if os.environ.get("INT_REPORT"):
        verify_report_mode()
        return
    if HAVE_BPY:
        render_mode()
    else:
        compose_mode()


if __name__ == "__main__":
    main()
