# -*- coding: utf-8 -*-
"""probe_transitions.py —— 手工预制过渡件成图（建筑管线 v3 · 地面体系）

出两张：
    pbr_ground_transitions.png   全件对照：每件 = [左邻纯料段 | 手工过渡件 | 右邻纯料段]，
                                 整幅 264px（路肩 96 + 路缘 8 + 道路 160）上下连成一条
    transitions/<key>.png        每件 1:1 正面图（写进资产目录，与分段集口径一致）

为什么用"整幅 264"对照
----------------------
手工边界是**在一整幅 264px 上手写的**，再按带裁成件（见 `ground_transitions.py`
文档头）。所以对照图把三带按真实上下顺序摞起来（路肩在墙根一侧、路缘 8px、道路带在
下面），左右两侧各接对应材质的**真分段**（`ground_tiles.b_segment` 现场算，不是另画
一张近似图）——拼上去边界连不连、材质尺度对不对，一眼就能判。

渲染路径（与地面管线同一套纪律）
--------------------------------
俯视正交（相机在 +Z 垂直向下）、`view_transform='Standard'`、dither=0、
一盏垂直向下的 SUN（能量 ≈ π → 单位曝光）+ 均匀环境 → **1 世界单位 = 1px**，
关 GTAO（AO 已烘进反照率）→ 出图就是资产本身那一像素。

跑法::
    blender -b --factory-startup -P probe_transitions.py
    GTX_ONLY=pieces blender -b --factory-startup -P probe_transitions.py   # 只出单件图
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

import ground_tiles as G          # noqa: E402  只读：分段生成器（对照用的真邻居）
import ground_transitions as X    # noqa: E402  本任务的手工件库

OUT_DIR = "F:/VSCode/game-2/.temp/building-pipeline-v2/stick-world/temp"
TILE_DIR = os.path.join(OUT_DIR, "ground_tiles")
GTX_DIR = os.path.join(TILE_DIR, "transitions")
NB_DIR = os.path.join(GTX_DIR, "_neighbors")

CELL = 32.0
CHART_H = float(X.CHART_H)          # 264
CHART_W = float(X.GAME_W)           # 512

FONT_CANDIDATES = ["C:/Windows/Fonts/simhei.ttf", "C:/Windows/Fonts/msyh.ttc",
                   "C:/Windows/Fonts/Deng.ttf", "C:/Windows/Fonts/arial.ttf"]

#: 每对的左右邻居（"seg" = ground_tiles 的区带分段 / "tile" = 平铺贴图）
NB = {
    "flagstone_dirt": (("seg", "center"), ("seg", "edge")),
    "brick_gravel": (("seg", "mid"), ("seg", "edge")),
    "rammed_grass": (("seg", "edge"), ("tile", "grass")),
    "gravel_grass": (("seg", "edge"), ("tile", "grass")),
    "boardwalk_dirt": (("tile", "boardwalk"), ("seg", "edge")),
}
TIER_CN = {"edge": "边缘档(夯土/砾石/草皮)", "mid": "中环档(旧砖/碎石)",
           "center": "中心档(石板/大理石)", "grass": "草地(城郊)",
           "boardwalk": "木栈道"}

_FONT = None
_EMIT = None
_MC = {}


# ---------------------------------------------------------------- 场景
def clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def wipe():
    for ob in list(bpy.data.objects):
        if ob.type in ("MESH", "FONT", "CURVE"):
            bpy.data.objects.remove(ob, do_unlink=True)


def link(ob):
    bpy.context.scene.collection.objects.link(ob)
    return ob


def plane(name, x0, x1, y0, y1, mat, z=0.0):
    me = bpy.data.meshes.new(name + "_m")
    me.from_pydata([(x0, y0, z), (x1, y0, z), (x1, y1, z), (x0, y1, z)], [],
                   [(0, 1, 2, 3)])
    me.update()
    uvl = me.uv_layers.new(name="UVMap")
    for lp, uv in zip(me.loops, [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)]):
        uvl.data[lp.index].uv = uv
    me.materials.append(mat)
    return link(bpy.data.objects.new(name, me))


def _emit_mat():
    global _EMIT
    if _EMIT is not None:
        return _EMIT
    m = bpy.data.materials.new("gtx_label")
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    o = nt.nodes.new("ShaderNodeOutputMaterial")
    e = nt.nodes.new("ShaderNodeEmission")
    e.inputs[0].default_value = (0.95, 0.96, 1.0, 1.0)
    e.inputs[1].default_value = 1.0
    nt.links.new(e.outputs[0], o.inputs["Surface"])
    _EMIT = m
    return m


def label(text, x, y, size_px, z=8.0):
    global _FONT
    if _FONT is None:
        _FONT = False
        for p in FONT_CANDIDATES:
            if os.path.exists(p):
                try:
                    _FONT = bpy.data.fonts.load(p)
                    break
                except Exception:
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


# ---------------------------------------------------------------- 材质
def _img(path, cs):
    name = os.path.basename(path)
    img = bpy.data.images.get(name)
    if img is None:
        img = bpy.data.images.load(path, check_existing=True)
    img.colorspace_settings.name = cs
    return img


def mat_files(name, alb, nrm, rgh):
    """从落盘的三张图建材质（albedo sRGB / 法线 Non-Color / 粗糙 Non-Color）。"""
    if name in _MC:
        return _MC[name]
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    tc = nt.nodes.new("ShaderNodeTexCoord")

    def tex(path, cs):
        nd = nt.nodes.new("ShaderNodeTexImage")
        nd.image = _img(path, cs)
        nd.interpolation = "Linear"
        nd.extension = "CLIP"                      # 件不是可平铺的 → 不许环绕
        nt.links.new(tc.outputs["UV"], nd.inputs["Vector"])
        return nd

    nt.links.new(tex(alb, "sRGB").outputs["Color"], bsdf.inputs["Base Color"])
    nm = nt.nodes.new("ShaderNodeNormalMap")
    nt.links.new(tex(nrm, "Non-Color").outputs["Color"], nm.inputs["Color"])
    nt.links.new(nm.outputs["Normal"], bsdf.inputs["Normal"])
    nt.links.new(tex(rgh, "Non-Color").outputs["Color"], bsdf.inputs["Roughness"])
    for kk, vv in (("IOR", 1.45), ("Specular IOR Level", 0.5)):
        try:
            bsdf.inputs[kk].default_value = vv
        except Exception:
            pass
    _MC[name] = m
    return m


def mat_np(name, alb, h, rough, relief_m, nstr):
    """从内存数组建材质（邻居对照条用）：先落盘三张图再建材质。"""
    os.makedirs(NB_DIR, exist_ok=True)
    a, n, r = (os.path.join(NB_DIR, "%s_%s.png" % (name, s))
               for s in ("alb", "nrm", "rgh"))
    G._save_png(alb, a, "sRGB")
    G._save_png(G.normal_map_w(h, alb.shape[1], alb.shape[0], relief_m, nstr),
                n, "Non-Color")
    G._save_png(rough, r, "Non-Color")
    return mat_files(name, a, n, r)


# ---------------------------------------------------------------- 相机 / 灯
def make_cam():
    d = bpy.data.cameras.new("gtx_cam")
    d.type = "ORTHO"
    d.clip_start = 1.0
    d.clip_end = 100000.0
    ob = link(bpy.data.objects.new("gtx_cam", d))
    bpy.context.scene.camera = ob
    return ob


def render_rect(cam, x0, x1, y0, y1, zoom, path):
    w, hgt = float(x1 - x0), float(y1 - y0)
    rx = max(64, int(round(w * zoom)))
    ry = max(64, int(round(hgt * zoom)))
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
    print("-> %s  %dx%d" % (os.path.basename(path), rx, ry))
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
    for attr, val in (("taa_render_samples", 32), ("use_gtao", False),
                      ("use_raytracing", False), ("use_shadows", True)):
        try:
            setattr(sc.eevee, attr, val)
        except Exception:
            pass
    return sc


def build_light():
    """地面资产图：**一盏垂直向下的 SUN**（无水平分量 → 光照各向同性）+ 均匀环境。"""
    d = bpy.data.lights.new("gtx_flat", "SUN")
    d.energy = 2.72
    d.angle = math.radians(2.0)
    ob = link(bpy.data.objects.new("gtx_flat", d))
    ob.rotation_euler = (0.0, 0.0, 0.0)
    return ob


def world_flat():
    w = bpy.data.worlds.new("gtx_wflat")
    w.use_nodes = True
    bg = w.node_tree.nodes.get("Background") or w.node_tree.nodes.new(
        "ShaderNodeBackground")
    bg.inputs[0].default_value = (0.50, 0.52, 0.56, 1.0)
    bg.inputs[1].default_value = 0.30
    return w


# ---------------------------------------------------------------- 对照条：邻居（真分段）
def nb_chart(kind, tier, seed, band_h=CHART_H):
    """邻居整幅（512×264）：按真实上下顺序摞三段（路肩 96 / 路缘 8 / 道路 160）。"""
    band_h = int(band_h)
    alb = np.zeros((band_h, X.GAME_W, 3))
    hh = np.zeros((band_h, X.GAME_W))
    rr = np.ones((band_h, X.GAME_W))
    y = 0
    for bn, bh in (("road", G.STRIP_ROAD), ("kerb", G.STRIP_KERB),
                   ("shoulder", G.STRIP_SHOULDER)):
        if kind == "seg":
            d = G.b_segment(bn, tier, seed=seed, nx=X.GAME_W, ny=bh)
        else:                                   # 平铺贴图：按引擎的铺法摞
            a, h2, r2 = X.mosaic(tier, X.GAME_W, bh, (0, 1, 2, 3), raster=1)
            d = {"alb": a, "h": h2, "rough": r2, "relief_m": 0.024, "nstr": 0.9}
        alb[y:y + bh] = d["alb"][:bh]
        hh[y:y + bh] = d["h"][:bh]
        rr[y:y + bh] = d["rough"][:bh]
        y += bh
    relief = d.get("relief_m", 0.024)
    return alb, hh, rr, relief, d.get("nstr", 0.9)


def piece_chart(pair, variant):
    """过渡件整幅（512×264）：直接调生成端，与落盘件同一份数据。"""
    p = X._PAIR_OF[pair]
    master = X._MASTER_OF[pair][variant - 1]
    alb, h, rough = X.build_chart(p, master, 1)[:3]
    return alb, h, rough


def piece_key(pair, band, variant):
    return "gtx_%s_%s_v%d" % (pair, band, variant)


def stack_pieces(name, cx, yb, pair, variant):
    """把**真件**按真实上下顺序摞起来（路缘那 8px、以及该材质对没出件的带，
    取整幅里对应那一段补上，只用于看图；json 里写清了哪个带出了件）。"""
    for band in ("road", "kerb", "shoulder"):
        y0, y1 = X.BANDS.get(band, (G.STRIP_ROAD, G.STRIP_ROAD + G.STRIP_KERB))
        has = band in X._PAIR_OF[pair]["bands"]
        if has:
            k = piece_key(pair, band, variant)
            m = mat_files("gtx_m_" + k,
                          os.path.join(GTX_DIR, "src", "%s_alb.png" % k),
                          os.path.join(GTX_DIR, "src", "%s_nrm.png" % k),
                          os.path.join(GTX_DIR, "src", "%s_rgh.png" % k))
        else:
            alb, h, rough = piece_chart(pair, variant)
            m = mat_np("%s_%s_fill" % (name, band), alb[y0:y1], h[y0:y1],
                       rough[y0:y1], X.RELIEF_M, 0.95)
        plane("%s_%s" % (name, band), cx, cx + CHART_W, yb + y0, yb + y1, m)


def shot_pieces(cam):
    """每件 1:1 正面图（写进资产目录，与分段集口径一致）。"""
    for key in X.piece_keys():
        rec = X._PIECE_OF[key]
        p, v = rec["pair"], rec["variant"]
        y0, y1 = X.BANDS[rec["band"]]
        m = mat_files("gtx_m_" + key,
                      os.path.join(GTX_DIR, "src", "%s_alb.png" % key),
                      os.path.join(GTX_DIR, "src", "%s_nrm.png" % key),
                      os.path.join(GTX_DIR, "src", "%s_rgh.png" % key))
        wipe()
        hgt = float(y1 - y0)
        plane(key, -X.GAME_W / 2.0, X.GAME_W / 2.0, -hgt / 2.0, hgt / 2.0, m)
        render_rect(cam, -X.GAME_W / 2.0, X.GAME_W / 2.0, -hgt / 2.0, hgt / 2.0,
                    1.0, os.path.join(GTX_DIR, "%s.png" % key))


def shot_zoom(cam):
    """调试用放大图：`GTX_ZOOM=key1,key2` 把指定件的缝区域放大 3×（给人工判图用）。"""
    want = [k for k in os.environ.get("GTX_ZOOM", "").split(",") if k]
    for key in want:
        if key not in X._PIECE_OF:
            print("  跳过未知件", key)
            continue
        rec = X._PIECE_OF[key]
        y0, y1 = X.BANDS[rec["band"]]
        p, v = rec["pair"], rec["variant"]
        alb, h, rough = piece_chart(p, v)
        sub = (slice(y0, y1), slice(0, X.GAME_W))
        m = mat_np("gtx_zoom_%s" % key, alb[sub], h[sub], rough[sub],
                   X.RELIEF_M, 0.95)
        wipe()
        hgt = float(y1 - y0)
        plane(key, -X.GAME_W / 2.0, X.GAME_W / 2.0, -hgt / 2.0, hgt / 2.0, m)
        render_rect(cam, -110.0, 140.0, -hgt / 2.0, hgt / 2.0, 3.0,
                    os.path.join(OUT_DIR, "_gtx_zoom_%s.png" % key))


def shot_sheet(cam):
    """`pbr_ground_transitions.png`：每件 = [左邻纯料 | 手工件 | 右邻纯料]，整幅 264 上下连条。"""
    wipe()
    zoom = 0.78
    gap, pad = 14.0, 60.0
    lab, blk = 22.0, CHART_H + 30.0
    blocks = [(p["key"], v) for p in X.PAIRS
              for v in range(1, len(X._MASTER_OF[p["key"]]) + 1)]
    W = 3 * CHART_W + 2 * gap + 2 * pad
    H = 64.0 + len(blocks) * blk + 16.0
    x0, y1 = -W / 2.0, H / 2.0
    label("手工预制过渡件（红警式预制块）：两块地之间**先立一道硬质收边**（镶边石 / 立砌砖牙 / "
          "草皮切边 / 端头横档），两侧材质在收边处硬切；收边逐块手摆、缝里只漏出少量碎屑；"
          "两边接对应材质的真分段（ground_tiles.b_segment 现场算）",
          0.0, y1 - 30.0, 25.0)
    y = y1 - 64.0
    for (pk, v) in blocks:
        pair = X._PAIR_OF[pk]
        nbL, nbR = NB[pk]
        ms = X._MASTER_OF[pk][v - 1]
        nms = ["左邻：" + TIER_CN[nbL[1]] + "（真分段三带摞起来）",
               "手工过渡件 %s · 变体%d（%s %d 块 + 贴边碎屑 %d 条）"
               % (pair["name"], v, X.EDGES[pair["edge"]]["name"],
                  X.units_in_band(ms, "road"), X.elements_in_band(ms, "road")),
               "右邻：" + TIER_CN[nbR[1]]
               + ("（真分段三带摞起来）" if nbR[0] == "seg" else "（平铺贴图摞起来）")]
        for i, nk in enumerate((nbL, None, nbR)):
            cx = x0 + pad + i * (CHART_W + gap)
            if nk is None:
                stack_pieces("gtx_pc_%s_v%d" % (pk, v), cx, y - CHART_H, pk, v)
            else:
                alb, hh, rr, relief, nstr = nb_chart(nk[0], nk[1], seed=v * 313)
                m = mat_np("gtx_sheet_%s_v%d_c%d" % (pk, v, i), alb, hh, rr,
                           relief, nstr)
                plane("c%d_%s_v%d" % (i, pk, v), cx, cx + CHART_W, y - CHART_H, y, m)
            label(nms[i], cx + CHART_W / 2.0, y - CHART_H - lab * 0.55, 19.0)
        label("%s：%s ↔ %s，中间砌一条%s（进深 %dpx，%d 块手摆）  ←  %s"
              % (pair["name"], pair["a"], pair["b"],
                 X.EDGES[pair["edge"]]["name"], X.EDGES[pair["edge"]]["w"],
                 len(ms["units"]), BAND_TXT), x0 + pad + CHART_W / 2.0,
              y + 8.0, 20.0)
        y -= blk
    render_rect(cam, x0, x0 + W, y1 - H, y1, zoom,
                os.path.join(OUT_DIR, "pbr_ground_transitions.png"))


BAND_TXT = ("整幅 264px = 路肩 96 / 路缘 8 / 道路带 160，上下连成一条；"
            "路缘带太窄不单出件")


# ---------------------------------------------------------------- main
def main():
    os.makedirs(GTX_DIR, exist_ok=True)
    os.makedirs(NB_DIR, exist_ok=True)
    only = os.environ.get("GTX_ONLY", "")

    print("== 落盘手工过渡件（alb / 法线 / 粗糙度 + json）→", GTX_DIR)
    X.export_all(GTX_DIR)
    X.selfcheck()

    clear()
    setup_render()
    build_light()
    bpy.context.scene.world = world_flat()
    cam = make_cam()

    if only in ("", "pieces"):
        shot_pieces(cam)
    if only == "zoom" or os.environ.get("GTX_ZOOM"):
        shot_zoom(cam)
    if only in ("", "sheet"):
        shot_sheet(cam)
    print("\nGTX_PROBE_OK")


main()
