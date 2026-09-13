# -*- coding: utf-8 -*-
"""probe_bevel.py —— 硬边品控门禁（`docs/技术/架构/美术品控-硬边与材质边缘.md` §2.4）

三张验收口径对应三件事
----------------------
1. **棱线高光检查图** `pbr_bevel_specular.png`：强侧光特写下四个抽验件
   （茅草栋 / 瓦顶栋 / 铁器 / 家具）并排 —— 所有可见棱必须呈"亮→暗"的**高光渐变带**，
   出现一条均匀死线（无过渡的 90° 切边）即打回；
2. **1x 可见性** `pbr_bevel_game1x.png`：游戏 1:1（1 px = 1 世界单位）下三行对照
   —— 上=现行（真倒角+磨白）/ 中=**关掉倒角与磨白**（A/B 底片）/ 下=差异×4 放大；
   逐件给出"改动像素数 / 可见带宽度"，倒角带与磨白必须 ≥1 px 可辨（不可辨=白做，省面数）；
3. **数字自证**（stdout）：倒角面数 / 占比、逐 def 覆盖、1x 差异分位数、带宽分布。

跑法::

    blender -b --factory-startup -P probe_bevel.py

产物（`stick-world/temp/`）::

    pbr_bevel_specular.png   棱线高光检查图（门禁图 1）
    pbr_bevel_game1x.png     1px/单位抽验 + A/B 差异（门禁图 2）
    _bevel_tmp/*.png         中间渲染（可删）

口径
----
* 相机 = 游戏视角（yaw 0° / tilt 20°，§0.3 硬约束），特写图 3.4x、1x 图 1.0x；
* "关掉倒角与磨白"只关 `Builder.bevel_faces`（几何倒角）与 `materials.EDGE_WEAR`
  （磨白层）；端头封端（瓦当/年轮）两侧都在 → 差异**只反映倒角与磨白**，判据干净。
"""
import math
import os
import sys

import bpy
import numpy as np
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import buildings as B        # noqa: E402
import materials as M        # noqa: E402

OUT_DIR = "F:/VSCode/game-2/.temp/building-pipeline-v2/stick-world/temp"
SPEC_PNG = os.path.join(OUT_DIR, "pbr_bevel_specular.png")
GAME_PNG = os.path.join(OUT_DIR, "pbr_bevel_game1x.png")
TMP_DIR = os.path.join(OUT_DIR, "_bevel_tmp")

YAW = 0.0
TILT = 20.0                  # §0.3：纯正面 + 俯角 20°（游戏视角）
ZOOM_SPEC = 3.4              # 特写（建筑）
ZOOM_SPEC_PROP = 7.5         # 特写（铁器/家具：小件，拉近才看得清棱带）
ZOOM_1X = 1.0                # 游戏 1:1 = 1px/世界单位
GAP = 44.0                   # 件间距
UPSCALE = 3                  # 门禁图放大倍率（NEAREST，保 1px 带可辨）
BAND_VIS = 6.0 / 255.0       # "肉眼可辨"阈值（sRGB 显示空间）
BAND_CHG = 1.5 / 255.0       # "改动"阈值
RULER_H = 10                 # 底缘 px 标尺高度（1x 像素块：1/2/3/4 px 条带）
#: 1x 行底部居中 ASCII 标签的"剔除框"（占高比例, 占宽比例）。ON/OFF 两行都带状态
#: 标签，字形本身在 A/B 差异里是**假信号**（实测 max diff 183/255 全是字）→ 差异
#: 口径（改动 px / 可见 px / 带宽分位）与差异图都先把这个矩形清零，只留几何差。
LABEL_CUT = (0.90, 0.86)

#: 抽验四件（§2.4 点名：一栋茅草 + 一栋瓦顶 + 一件铁器 + 一件家具）
SUBJECTS = [
    ("thatch", "thatch smithy1 w8", ("asm", "smithy1", 8)),
    ("tile", "tile smithy4 w12", ("asm", "smithy4", 12)),
    ("iron", "iron anvil/hoop/lamp", ("iron",)),
    ("furn", "furniture bench/barrel", ("furn",)),
]


# ------------------------------------------------------------------ 场景

def clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def setup_world(ambient=0.12):
    sc = bpy.context.scene
    for eng in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE"):
        try:
            sc.render.engine = eng
            break
        except Exception:
            continue
    sc.render.film_transparent = False
    sc.view_settings.view_transform = "Standard"
    sc.view_settings.look = "None"
    for attr, val in (("taa_render_samples", 64), ("use_gtao", True)):
        try:
            setattr(sc.eevee, attr, val)
        except Exception:
            pass
    w = bpy.data.worlds.new("W_bevel")
    sc.world = w
    w.use_nodes = True
    bg = w.node_tree.nodes.get("Background")
    if bg is None:
        bg = w.node_tree.nodes.new("ShaderNodeBackground")
    bg.inputs[0].default_value = (0.55, 0.62, 0.74, 1.0)
    bg.inputs[1].default_value = ambient       # 低环境：棱上的高光才"跳"出来
    return sc


def _sun(name, energy, rot, angle=1.2, color=(1.0, 0.96, 0.88)):
    d = bpy.data.lights.new(name, "SUN")
    d.energy = energy
    d.angle = math.radians(angle)
    d.color = color
    try:
        d.use_shadow = True
    except Exception:
        pass
    ob = bpy.data.objects.new(name, d)
    ob.rotation_euler = tuple(math.radians(a) for a in rot)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def setup_lights():
    """强侧光（门禁口径）：主光从**正前方仰角 45°**打 —— 这是"顶棱高光带"的正解。

    推导：相机从前方俯视 20°，视线方向 V=(0,−0.94,0.34)。顶面↔立面之间那条棱的
    法线是 n=(0,−0.707,0.707)（45° 朝上前），镜面反射要求的入射光方向
    L=2(n·V)n−V 正好是**前方仰角 45°**。此时：
      · 棱带本身 L·n≈1.0（最亮）—— 一条干净的高光带；
      · 相邻的顶面与立面都只有 L·n≈0.71（中等灰）；
      ⇒ "亮→暗"过渡看得见。若光从别处来，棱带与邻面亮度相近，90° 死线和高光带
      就分不出来（第一版取仰角 56°/侧 28° 就是这个毛病：屋面抢光、棱带不跳）。
    另配两盏：低仰角左侧掠射（勾**竖棱**：它的镜面光在仰角 ~9°、方位 −63°）与
    弱冷背光（压出轮廓）。
    """
    _sun("key", 4.6, (45, 0, -10), 0.8)                     # 正前 45°：顶棱高光带
    _sun("side", 1.9, (81, 0, -63), 1.2)                    # 左前 9°：竖棱掠射
    _sun("rim", 0.9, (52, 0, 168), 1.6, (0.84, 0.90, 1.0))  # 背光：压轮廓


def make_camera():
    d = bpy.data.cameras.new("cam_bevel")
    d.type = "ORTHO"
    d.clip_start = 1.0
    d.clip_end = 40000.0
    ob = bpy.data.objects.new("cam_bevel", d)
    bpy.context.scene.collection.objects.link(ob)
    bpy.context.scene.camera = ob
    return ob


def place_camera(cam, anchor, dist=9000.0):
    right, up = B.cam_axes(YAW, TILT)
    fwd = -(right.cross(up))
    cam.location = tuple(Vector(anchor) - fwd * dist)
    cam.rotation_euler = (math.radians(90.0 - TILT), 0.0, math.radians(YAW))


def shoot_fit(cam, objs, zoom, path, pad=34.0, pad_top=26.0, res_max=7600, label=None):
    """按实际顶点屏幕投影取景（与 probe_buildings 同一套相机口径）。

    label 给定时在取景框顶部放一个正对相机的 ASCII 标签（随渲染一起出图）。
    """
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
    rx = max(32, int(round(w * zoom * k)))
    ry = max(32, int(round(h * zoom * k)))
    cam.data.ortho_scale = max(w, h)
    sc = bpy.context.scene
    sc.render.resolution_x = rx
    sc.render.resolution_y = ry
    sc.render.resolution_percentage = 100
    sc.render.filepath = path
    info = {"path": path, "res": (rx, ry), "px_per_unit": rx / w,
            "anchor": anchor, "basis": (right, up), "frame": (u0, u1, v0, v1)}
    lo = add_label(label, info) if label else None
    bpy.ops.render.render(write_still=True)
    if lo is not None:
        cuv = lo.data
        bpy.data.objects.remove(lo, do_unlink=True)
        try:
            bpy.data.curves.remove(cuv)
        except Exception:
            pass
    return info


def add_label(text, info):
    """在取景框顶部放一个**正对相机**的 ASCII 标签（Blender 内建字体，不引外部资源）。

    门禁图是给创始人看的：没有图例的话"上=现行 / 中=关倒角 / 下=差异"要靠猜。
    中文要 CJK 字体（本机不确定有），故标签一律 ASCII（thatch/tile/iron/furn、ON/OFF/DIFF）。
    """
    try:
        right, up = info["basis"]
        _u0, _u1, _v0, _v1 = info["frame"]
        h = _v1 - _v0
        cur = bpy.data.curves.new(name="lbl_" + text, type='FONT')
        cur.body = text
        cur.size = h * 0.050
        cur.align_x = 'CENTER'
        cur.align_y = 'BOTTOM'
        ob = bpy.data.objects.new("lbl_" + text, cur)
        bpy.context.scene.collection.objects.link(ob)
        ob.rotation_euler = (math.radians(90.0 - TILT), 0.0, math.radians(YAW))
        ob.location = tuple(info["anchor"] - up * (h * (0.5 - 0.010)))
        m = bpy.data.materials.new("lbl_mat")
        m.use_nodes = True
        nt = m.node_tree
        nt.nodes.clear()
        e = nt.nodes.new('ShaderNodeEmission')
        e.inputs[0].default_value = (0.97, 0.95, 0.88, 1.0)
        e.inputs[1].default_value = 2.2
        o = nt.nodes.new('ShaderNodeOutputMaterial')
        nt.links.new(e.outputs[0], o.inputs['Surface'])
        cur.materials.append(m)
        return ob
    except Exception as exc:
        print("[bevel] 标签 %s 失败（%s）" % (text, exc))
        return None


# ------------------------------------------------------------------ 抽验件

def build_subject(kind, tag):
    """返回该抽验件的对象列表（建筑走 ASSEMBLERS；铁器/家具用 Builder 现搭）。"""
    if kind == "asm":
        ob, _spec = B.ASSEMBLERS[tag[0]](tag[1])
        return [ob]
    b = B.Builder("bev_" + kind)
    if kind == "iron":          # 注意判 kind（spec 首元素），tag 对铁器/家具是空元组
        B.anvil(b, x=-38.0, y=0.0, z=0.0)                       # 铁砧（砧面/腰/底座棱）
        B.beam(b, 64.0, size=11.0, mat="iron", x=-38.0, y=-4.0, z=62.0)   # 砧上铁料
        B.barrel(b, x=14.0, y=0.0, z=0.0, r=15.0, h=42.0, mat="wood", band_mat="iron")
        B.lamp_post(b, x=56.0, y=0.0, z=0.0, h=150.0)           # 铁柱 + 灯罩八角棱
    else:
        B.bench(b, x=-46.0, y=0.0, z=0.0, w=66.0, d=32.0, h=50.0)
        B.stool(b, x=6.0, y=4.0, z=0.0)
        B.barrel(b, x=40.0, y=0.0, z=0.0, r=15.0, h=44.0, lid=True)
        B.railing(b, 76.0, -42.0, -24.0, 0.0, h=62.0, posts=3)
        B.beam(b, 118.0, size=12.0, mat="wood_dark", x=-10.0, y=-30.0, z=104.0)
    return [b.to_object()]


#: 各 def 的抽验宽度（取 city_layout 的规范档；缺省 8）
_W = {}


def load_widths():
    try:
        import city_layout as CL
        for k, v in CL.DEFS.items():
            ws = v.get("widths") or []
            if ws:
                _W[k] = ws[-1] if len(ws) > 1 else ws[0]
    except Exception as exc:
        print("[bevel] city_layout 宽度表不可用（%s），退回默认 8 格" % exc)
    _W.setdefault("smithy1", 8)
    _W.setdefault("smithy4", 12)


# ------------------------------------------------------------------ 图像工具

def load_rgba(path):
    """读回 PNG（行序翻成上→下，值是 sRGB 显示 0~1）。"""
    img = bpy.data.images.load(path, check_existing=False)
    w, h = img.size
    buf = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(buf)
    a = buf.reshape(h, w, 4)[::-1].copy()
    bpy.data.images.remove(img)
    return a


def save_rgba(path, arr):
    h, w = arr.shape[:2]
    img = bpy.data.images.new(os.path.basename(path), w, h, alpha=False,
                              float_buffer=False)
    img.colorspace_settings.name = 'sRGB'
    img.pixels.foreach_set(np.ascontiguousarray(arr[::-1]).reshape(-1).astype(np.float32))
    img.file_format = 'PNG'
    img.filepath_raw = path
    img.save()
    bpy.data.images.remove(img)


def up(a, k):
    """NEAREST 放大 k 倍（门禁图放大后 1px 带仍数得清）。"""
    return np.repeat(np.repeat(a, k, axis=0), k, axis=1)


def hstack(items, gutter=10, bg=(0.08, 0.09, 0.11)):
    """底对齐横向拼接（各图高度不同 → 用背景补）。"""
    hs = max(a.shape[0] for a in items)
    ws = sum(a.shape[1] for a in items) + gutter * (len(items) - 1)
    out = np.zeros((hs, ws, 4), dtype=np.float32)
    out[..., 0], out[..., 1], out[..., 2], out[..., 3] = bg[0], bg[1], bg[2], 1.0
    x = 0
    for a in items:
        out[hs - a.shape[0]:hs, x:x + a.shape[1], :] = a
        x += a.shape[1] + gutter
    return out


def vstack(items, gutter=10, bg=(0.08, 0.09, 0.11)):
    ws = max(a.shape[1] for a in items)
    hs = sum(a.shape[0] for a in items) + gutter * (len(items) - 1)
    out = np.zeros((hs, ws, 4), dtype=np.float32)
    out[..., 0], out[..., 1], out[..., 2], out[..., 3] = bg[0], bg[1], bg[2], 1.0
    y = 0
    for a in items:
        out[y:y + a.shape[0], 0:a.shape[1], :] = a
        y += a.shape[0] + gutter
    return out


def px_ruler(width):
    """底缘"像素块标尺"：1/2/3/4 px 宽的明暗条带各一段（放大后即 3/6/9/12 px）。

    门禁图没有文字图例也得能判"倒角带 ≥1px"：把 1x 像素块直接摊在旁边当尺子。
    设计成 1x 尺寸 int 取整后与 gam1x 行同宽，避免行宽不一致导致错位。
    """
    h = RULER_H
    buf = np.zeros((h, width, 4), dtype=np.float32)
    buf[..., 3] = 1.0
    x = 0
    for wpx in (1, 2, 3, 4):
        seg = 64 * wpx                       # 每段长度 = 64 个像素块
        for i in range(seg):
            x0 = x + i * wpx
            if x0 + wpx > width:
                break
            v = 0.92 if (i % 2 == 0) else 0.10
            buf[h // 4: h - h // 4, x0:x0 + wpx, :3] = v
        x += seg * wpx + 16
    return buf


def run_len_stats(mask):
    """逐行/逐列连续 True 段的长度分布（判"倒角带几 px 宽"）。"""
    out = []
    for axis in (1, 0):
        m = mask if axis == 1 else mask.T
        for row in m:
            if not row.any():
                continue
            d = np.diff(np.concatenate(([0], row.view(np.int8), [0])))
            starts = np.flatnonzero(d == 1)
            ends = np.flatnonzero(d == -1)
            out += list(ends - starts)
    return np.array(out, dtype=np.int32) if out else np.zeros(1, dtype=np.int32)


def cut_label(d):
    """把 1x 行底部标签区从差异里清零（见 LABEL_CUT 注释），返回剔除框。"""
    h, w = d.shape
    r0 = int(h * LABEL_CUT[0])
    cw = LABEL_CUT[1]
    c0 = int(w * (0.5 - cw * 0.5))
    c1 = w - c0
    d[r0:, c0:c1] = 0.0
    return (r0, c0, c1)


# ------------------------------------------------------------------ 主流程

def render_subjects(state):
    """按 state（bevel/wear 开关）重建四件 → 特写 + 1x 两张图。返回指标。"""
    on = (state == "on")
    if not on:
        _orig_bev = B.Builder.bevel_faces
        B.Builder.bevel_faces = lambda self, *a, **k: []      # 关几何倒角
        _orig_wear = dict(M.EDGE_WEAR)
        M.EDGE_WEAR.clear()                                   # 关磨白层
    M.reset_cache()
    B._CACHE.clear()
    sc = bpy.context.scene
    cam = sc.camera
    res = {}
    cursor = 0.0
    for name, label, spec in SUBJECTS:
        objs = build_subject(spec[0], spec[1:])
        xs = [B.measure(o)["x"] for o in objs]
        x0, x1 = min(v[0] for v in xs), max(v[1] for v in xs)
        for ob in objs:
            ob.location.x += (cursor - x0)
        bpy.context.view_layer.update()
        zoom = ZOOM_SPEC if spec[0] == "asm" else ZOOM_SPEC_PROP
        # 特写（强侧光）——含一个正对相机的 ASCII 标签
        shoot_fit(cam, objs, zoom,
                  os.path.join(TMP_DIR, "spec_%s_%s.png" % (name, state)),
                  pad=26.0, pad_top=20.0,
                  label=label + ("  [ON]" if on else "  [OFF]"))
        # 1x（游戏 1:1）——两行都带状态标签（差异口径会把标签框清零，见 LABEL_CUT）
        info = shoot_fit(cam, objs, ZOOM_1X,
                         os.path.join(TMP_DIR, "g1x_%s_%s.png" % (name, state)),
                         pad=16.0, pad_top=14.0, res_max=20000,
                         label=label + ("  [ON]" if on else "  [OFF]"))
        res[name] = dict(label=label, path=info["path"], res=info["res"],
                         px=info["px_per_unit"])
        cursor = cursor + (x1 - x0) + GAP
        for ob in objs:
            bpy.data.objects.remove(ob, do_unlink=True)
    if not on:
        B.Builder.bevel_faces = _orig_bev
        M.EDGE_WEAR.update(_orig_wear)
    return res


def build_any(name):
    """按 def 建一栋（宽度档优先用规范档，失败逐个回退 —— 各 def 的档表不一样）。"""
    cands = []
    if name in _W:
        cands.append(_W[name])
    cands += [12, 8, 16, 6, 4]
    for wc in cands:
        try:
            return B.ASSEMBLERS[name](wc)
        except Exception:
            continue
    raise KeyError("无法装配 %s（试过 %s）" % (name, cands))


def audit_coverage():
    """逐 def 几何自证：面数 / 倒角面数 / 占比（回答"多少 def 受益"）。"""
    print("\n=== 倒角覆盖（%d 个装配器，宽度档按规范档回退）===" % len(B.ASSEMBLERS))
    print("%-12s %3s %8s %8s %7s" % ("def", "格", "面数", "倒角面", "占比"))
    tot = tb = 0
    cov = 0
    for name in sorted(B.ASSEMBLERS):
        try:
            ob, spec = build_any(name)
        except Exception as exc:
            print("%-12s  --  跳过（%s）" % (name, exc))
            continue
        wc = spec.get("width_cells", 0)
        me = ob.data
        lay = me.attributes.get("edge")
        n = len(me.polygons)
        bf = 0
        if lay is not None:
            vals = np.empty(n, dtype=np.float32)
            lay.data.foreach_get("value", vals)
            bf = int((vals > 0.5).sum())
        tot += n
        tb += bf
        cov += 1 if bf else 0
        print("%-12s %3d %8d %8d %6.1f%%" % (name, wc, n, bf, 100.0 * bf / max(1, n)))
        bpy.data.objects.remove(ob, do_unlink=True)
    print("合计：%d 个装配器有倒角面（登记 %d 个）/ 总面 %d / 倒角面 %d（%.1f%%）"
          % (cov, len(B.ASSEMBLERS), tot, tb, 100.0 * tb / max(1, tot)))
    return cov, tot, tb


def main():
    clear()
    load_widths()
    setup_world()
    setup_lights()
    make_camera()
    os.makedirs(TMP_DIR, exist_ok=True)
    os.makedirs(OUT_DIR, exist_ok=True)

    on = render_subjects("on")
    off = render_subjects("off")

    # ---- 门禁图 1：强侧光特写排 ------------------------------------------
    tiles = [load_rgba(os.path.join(TMP_DIR, "spec_%s_on.png" % k)) for k, _l, _s in SUBJECTS]
    save_rgba(SPEC_PNG, hstack(tiles, gutter=14))
    print("SPEC -> %s  tiles=%s" % (SPEC_PNG, [t.shape[1] for t in tiles]))

    # ---- 门禁图 2：1x 抽验 + A/B 差异 -----------------------------------
    print("\n=== 1x 可见性（%d px / 世界单位；差 = 现行 − 关倒角/磨白）===" % int(ZOOM_1X))
    print("%-6s %-22s %9s %9s %9s %9s %9s" %
          ("件", "名称", "改动px", "可见px", "Δp50", "带宽p50", "带宽p90"))
    row_on, row_off, row_df, ok = [], [], [], True
    for k, label, _s in SUBJECTS:
        a = load_rgba(on[k]["path"])
        b = load_rgba(off[k]["path"])
        hh = min(a.shape[0], b.shape[0])
        ww = min(a.shape[1], b.shape[1])
        a, b = a[:hh, :ww], b[:hh, :ww]
        d = np.abs(a[..., :3] - b[..., :3]).max(axis=2)
        cut_label(d)                        # 标签字形不是几何差 → 先剔除
        chg = d > BAND_CHG
        vis = d > BAND_VIS
        ln = run_len_stats(vis)
        p50, p90 = int(np.percentile(ln, 50)), int(np.percentile(ln, 90))
        dp50 = float(np.percentile(d[chg], 50)) if chg.any() else 0.0
        print("%-6s %-22s %9d %9d %9.1f %9d %9d"
              % (k, label, int(chg.sum()), int(vis.sum()), dp50 * 255.0, p50, p90))
        if int(vis.sum()) == 0 or p50 < 1:
            ok = False
        diff = np.zeros_like(a)
        diff[..., 3] = 1.0
        diff[..., :3] = np.clip(d[..., None] * 4.0, 0.0, 1.0)
        row_on.append(up(a, UPSCALE))
        row_off.append(up(b, UPSCALE))
        row_df.append(up(diff, UPSCALE))

    # 三行（上=现行 / 中=关倒角磨白 / 下=差异×4）；四件同序 → 三行天然按列对齐
    band_on = hstack([up(r, UPSCALE) for r in row_on], gutter=12)
    band_off = hstack([up(r, UPSCALE) for r in row_off], gutter=12)
    band_df = hstack([up(r, UPSCALE) for r in row_df], gutter=12)
    ruler = px_ruler(band_on.shape[1])
    save_rgba(GAME_PNG, vstack([band_on, band_off, band_df, ruler], gutter=12))
    print("GAME -> %s  行=%dx%d ×3 行 + 1px 标尺（上=现行 / 中=关倒角磨白 / 下=差异×4）"
          % (GAME_PNG, band_on.shape[1], band_on.shape[0]))

    # ---- 数字自证 --------------------------------------------------------
    M.reset_cache()
    B._CACHE.clear()
    audit_coverage()
    print("\n门禁判定：1x 可辨 %s（可见带 p50 ≥1px 且每件都有可见改动）" %
          ("PASS" if ok else "FAIL"))
    print("PROBE_BEVEL_OK")


main()
