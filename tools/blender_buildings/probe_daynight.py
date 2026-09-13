# -*- coding: utf-8 -*-
"""probe_daynight.py —— 昼夜分层出图证明（管线 v3 · 写实 PBR）

回答创始人："游戏昼夜光效怎么处理？夜晚建筑和场景发光？"

做法：搭一条**代表街景**（house / townhouse / tavern / smithy1 / cathedral /
mage_tower 六栋，覆盖民居到魔法单体），同一套取景下出四张图：

    pbr_dn_day.png     白天 —— 沿用现有光照（暖主光 3.5 + 冷补光 + 暖地面反弹），
                       **albedo 交付基线**
    pbr_dn_night.png   夜晚 —— 环境光压到 ~10% 并偏冷蓝（月光感）、方向主光降到 0.16
                       改冷白；灯笼/炉火/符文/水晶/**点亮的窗**位置挂真实点光源
                       （暖橙），光真的洒在墙面与地面上；自发光材质正常发亮
    pbr_dn_glow.png    **纯发光层** —— 非发光材质全换纯黑、世界全黑、所有灯关闭，
                       只剩自发光 + 光晕贴片。引擎 additive 叠加用这一层
    pbr_dn_layers.png  分层说明图 —— 四格并排（albedo / ×tint_night / +glow / 真实夜图）
                       让"两层 + 一次调色"一眼看懂

内部自检图（下划线前缀 = 不进交付，供审计）：
    _dn_glow_nohalo.png   glow 层**去掉光晕**的控制图 —— 用来实测"非发光物有没有
                          漏进 glow 层"（它若在非发光几何位置有亮度，就是漏了）

跑法::
    blender -b --factory-startup -P probe_daynight.py
    DN_FAST=1 blender ...        # 只出 day/night（跳过分层图，快速看光照）
    DN_LIGHT_GAIN=1.6 ...        # 点光源整体增益（调夜景观感的第一旋钮）

产物（stick-world/temp/）：上面四张 + `pbr_daynight_report.json`
"""

import json
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
import daynight as DN        # noqa: E402
import materials as M        # noqa: E402
import props as P            # noqa: E402

OUT_DIR = "F:/VSCode/game-2/.temp/building-pipeline-v2/stick-world/temp"
YAW, TILT = 0.0, 20.0        # §0.3 硬约束：纯正面 + 俯角 20°
CELL = 32.0

#: 街景：装配器 → (宽度档, 道具配方键)。配方键取自 props.DRESS 既有键（不新增）。
#: 六栋刻意覆盖**四类发光件**：灯笼（townhouse/tavern）、炉火（smithy1）、
#: 彩窗+灯柱（cathedral）、符文+水晶（mage_tower）；house 是"零发光"的对照。
STREET = [
    ("house",      8,  "house"),
    ("townhouse",  12, "townhouse"),
    ("tavern",     12, "townhouse"),
    ("smithy1",    8,  "smithy"),
    ("cathedral",  12, "cathedral"),
    ("mage_tower", 6,  "tower"),
]
GAP = 30.0

#: 白天光照档（与 probe_city_scene 同值 —— 这就是"现有光照"，是 albedo 基线）
DAY_SKY = ((0.42, 0.56, 0.80, 1.0), (0.74, 0.76, 0.74, 1.0), 0.55)
DAY_SUNS = (
    ("key",    3.5,  (42.0, 0.0, -34.0), 2.5, (1.00, 0.93, 0.80)),
    ("fill",   0.22, (58.0, 0.0, 126.0), 20.0, (0.80, 0.87, 1.00)),
    ("bounce", 0.30, (-28.0, 0.0, 6.0), 45.0, (0.95, 0.80, 0.62)),
)


# ---------------------------------------------------------------- 场景

def clear():
    """一次场景只 read_factory_settings 一次（踩坑 §六）；之后只删网格对象。
    这里因为要出多层光照，一次读工厂 + 三个世界对象复用。"""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    B._CACHE.clear()
    M.reset_cache()
    DN.reset()


def setup_engine(sc):
    for eng in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE", "CYCLES"):
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


def quad(name, x0, x1, y0, y1, z, material):
    me = bpy.data.meshes.new(name + "_mesh")
    me.from_pydata([(x0, y0, z), (x1, y0, z), (x1, y1, z), (x0, y1, z)], [],
                   [(0, 1, 2, 3)])
    me.materials.append(material)
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def ground_material():
    """暖沙地面（与 probe_city_scene 同口径；程序纹理，1 UV = 1 格）。"""
    m = bpy.data.materials.get("dn_ground")
    if m is not None:
        return m
    m = bpy.data.materials.new("dn_ground")
    m.use_nodes = True
    nt = m.node_tree
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    bsdf.inputs["Roughness"].default_value = 0.96
    bsdf.inputs["Base Color"].default_value = (0.58, 0.49, 0.33, 1.0)
    tc = nt.nodes.new("ShaderNodeTexCoord")
    mp = nt.nodes.new("ShaderNodeMapping")
    mp.inputs["Scale"].default_value = (0.02, 0.02, 0.02)
    nz = nt.nodes.new("ShaderNodeTexNoise")
    nz.inputs["Scale"].default_value = 6.0
    nz.inputs["Detail"].default_value = 6.0
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].position = 0.34
    ramp.color_ramp.elements[0].color = (0.42, 0.34, 0.22, 1.0)
    ramp.color_ramp.elements[1].position = 0.76
    ramp.color_ramp.elements[1].color = (0.70, 0.60, 0.41, 1.0)
    bump = nt.nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.30
    nt.links.new(tc.outputs["Object"], mp.inputs["Vector"])
    nt.links.new(mp.outputs["Vector"], nz.inputs["Vector"])
    nt.links.new(nz.outputs["Fac"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    nt.links.new(nz.outputs["Fac"], bump.inputs["Height"])
    nt.links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
    return m


def road_material():
    m = bpy.data.materials.get("dn_road")
    if m is not None:
        return m
    m = bpy.data.materials.new("dn_road")
    m.use_nodes = True
    nt = m.node_tree
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    bsdf.inputs["Roughness"].default_value = 0.88
    bsdf.inputs["Base Color"].default_value = (0.32, 0.31, 0.29, 1.0)
    tc = nt.nodes.new("ShaderNodeTexCoord")
    vn = nt.nodes.new("ShaderNodeTexVoronoi")
    vn.inputs["Scale"].default_value = 26.0
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (0.20, 0.195, 0.185, 1.0)
    ramp.color_ramp.elements[1].color = (0.44, 0.43, 0.40, 1.0)
    bump = nt.nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.35
    nt.links.new(tc.outputs["Object"], vn.inputs["Vector"])
    nt.links.new(vn.outputs["Distance"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    nt.links.new(vn.outputs["Distance"], bump.inputs["Height"])
    nt.links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
    return m


def build_street(report):
    """六栋并排 + 各自 props.dress()。返回 (对象列表, 明细)。

    摆放口径与 probe_city_scene 一致：装配器以**原点为中心**建模，所以按实测包围盒
    把每栋的左边缘对齐到游标（`dx = cursor - measure.x[0]`），建筑与它的道具用同一个
    dx 平移 —— 否则道具会留在原地、飘在街上。
    """
    objs, rows = [], []
    cursor = 0.0
    for i, (asm, wc, kind) in enumerate(STREET):
        ob, spec = B.ASSEMBLERS[asm](wc)
        mx = B.measure(ob)
        dx = cursor - mx["x"][0]
        ob.location = (dx, 0.0, 0.0)
        bpy.context.view_layer.update()
        pob = None
        if kind in P.DRESS:
            pb = B.Builder("props_%s" % asm)
            d = spec.get("door")
            P.dress(pb, kind, spec["grid_w"], B.measure(ob)["y"][0],
                    seed=i * 37 + 11,           # 确定性（不能用 hash()：跨进程会变）
                    door_x=spec.get("door_x", 0.0), door_w=(d[0] if d else 0.0))
            pob = pb.to_object()
            pob.location = (dx, 0.0, 0.0)
            bpy.context.view_layer.update()
        objs.append(ob)
        if pob is not None:
            objs.append(pob)
        mx = B.measure(ob)
        width = mx["x"][1] - mx["x"][0]
        rows.append(dict(asm=asm, cells=wc, kind=kind, x0=round(mx["x"][0], 1),
                         x1=round(mx["x"][1], 1), width=round(width, 1),
                         height=round(mx["z"][1], 1), y_front=round(mx["y"][0], 1)))
        cursor += width + GAP
    # 地面 + 主街（主街在临街面前方 = 世界 y 更小的一侧）
    x0 = min(B.measure(o)["x"][0] for o in objs) - 240.0
    x1 = max(B.measure(o)["x"][1] for o in objs) + 240.0
    front = min(B.measure(o)["y"][0] for o in objs)
    objs.append(quad("dn_ground", x0, x1, front - 320.0, 300.0, -1.0,
                     ground_material()))
    objs.append(quad("dn_road", x0, x1, front - 230.0, front - 4.0, 0.6,
                     road_material()))
    report["street"] = rows
    report["street_width"] = round(cursor - GAP, 1)
    return objs


# ---------------------------------------------------------------- 图像工具

def _rgba(path):
    a, (w, h) = DN._load_rgba(path)
    return a, w, h


def _luma(a):
    return (0.2126 * a[..., 0] + 0.7152 * a[..., 1] + 0.0722 * a[..., 2])


def _texture_mask(a, thr=0.005, box=9):
    """"这是几何面，不是天/背景"的掩码：局部有纹理（高频）的像素。

    为什么需要它：天空是**一大片平滑渐变**，如果把它算进 tint 的统计样本，
    量出来的 tint 就变成"天空的压暗比"（天空占了画面很大一块面积），
    而引擎要乘的是**材质反照率**的 tint —— 两者不是一回事。
    用"原图 − 均值滤波"的残差当高频量：抹灰/砖/地面的纹理残差 ≫ 天空。
    """
    l = _luma(a)
    k = np.ones(box, dtype=np.float32) / float(box)
    blur = l
    for ax in (0, 1):
        blur = np.apply_along_axis(lambda m: np.convolve(m, k, mode="same"),
                                   ax, blur)
    return np.abs(l - blur) > thr


def calibrate_tint(day, amb, glow, mask):
    """**最小二乘**标定 tint：在几何面上解 min || day_c · t − (amb_c − glow_c) ||。

    比"逐像素比值的位数"更适合引擎里的一次性乘法：tint 是全局常数，要最小化的是
    整幅图的误差，不是"典型像素的比值"。先用 `amb − glow`（无点光/无光晕的环境
    标定图减去发光层的控制图）把自发光物自身的亮度从目标里剔掉，剩下的才是
    "albedo 该被压到多少"。
    """
    out = []
    for c in range(3):
        tgt = amb[..., c][mask] - glow[..., c][mask]
        src = day[..., c][mask]
        den = float(np.sum(src * src))
        out.append(float(np.clip(np.sum(src * tgt) / den, 0.0, 1.0))
                   if den > 1e-6 else 0.0)
    return out


def measure_tint(day, night, glow):
    """实测 tint：在"几何面 + 白天够亮 + 发光层没贡献"的像素上取 night/day 的通道中位数。

    这是合成公式里 tint_night 的**标定依据**；它也顺带回答"夜晚是不是只整体压暗"：
    若三通道比值几乎相等就是没偏色（不叫月光），本题量出来 B/R ≈ 2.3，是偏冷蓝的。
    """
    m = (_texture_mask(day) & (_luma(day) > 0.12) & (_luma(glow) < 0.004)
         & (_luma(night) > 0.002))
    if int(m.sum()) < 500:
        return None, int(m.sum())
    out = []
    for c in range(3):
        r = night[..., c][m] / np.maximum(day[..., c][m], 1e-5)
        out.append(float(np.median(np.clip(r, 0.0, 1.0))))
    return out, int(m.sum())


def compose(day, glow, tint, strength):
    return np.clip(day[..., :3] * np.asarray(tint, np.float32)[None, None, :]
                   + glow[..., :3] * strength, 0.0, 1.0)


def sky_radiance(top, bottom, strength):
    """天空环境的平均辐亮度（渐变取两端均值）。用来算"夜晚 = 白天的百分之几"的
    **光照口径**比值 —— 它和像素口径比值会差很多，因为白天基线大片过曝（见汇报）。"""
    return strength * sum((sum(top[:3]) / 3.0 + sum(bottom[:3]) / 3.0) / 2.0
                          for _ in (0,))


def audit_glow_separation(path):
    """glow 层的干净度实测：不带光晕的控制图里，非黑像素的占比与亮度上限。

    非发光材质已被换成**纯黑无光**材质、世界全黑、全部灯关闭，所以理论上只有
    自发光面能亮。这一步把"理论"变成数字：非黑像素占比应 ≈ 发光面占画面的比例
    （个位数 %），且不该出现大片中等亮度（那是"某处非发光物被照亮了"）。
    """
    a, w, h = _rgba(path)
    lum = _luma(a)
    nz = lum > 0.004                       # 阈值是**线性**值（≈ sRGB 0.06）
    stats = dict(pixels=int(w * h), nonblack=int(nz.sum()),
                 nonblack_pct=round(100.0 * float(nz.mean()), 3),
                 luma_max=round(float(lum.max()), 4),
                 luma_p50_nonblack=round(float(np.median(lum[nz])) if nz.any() else 0.0,
                                         4))
    return stats


# ---------------------------------------------------------------- 主流程

def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    gain = float(os.environ.get("DN_LIGHT_GAIN", str(DN.LIGHT_GAIN)))
    win_prob = float(os.environ.get("DN_WIN_PROB", "0.42"))
    fast = os.environ.get("DN_FAST", "") == "1"
    report = {"light_gain": gain, "window_prob": win_prob}

    clear()
    sc = bpy.context.scene
    setup_engine(sc)
    cam = DN.make_camera(sc, TILT)

    print("[1/6] 搭街景 + 白天光照")
    DN.set_sky(sc, "dn_day_sky", *DAY_SKY)
    DN.set_suns(sc, DAY_SUNS)
    objs = build_street(report)
    info = DN.frame(cam, objs, zoom=1.0, pad=70.0, pad_top=50.0, pad_bottom=0.0,
                    yaw=YAW, tilt=TILT)
    report["frame"] = dict(res=info["res"], tilt=TILT, ortho=round(cam.data.ortho_scale, 1))
    for r in report["street"]:
        print("   %-11s w%-3d  %5.1f 单位宽  高 %5.1f" % (r["asm"], r["cells"],
                                                          r["width"], r["height"]))

    day_png = os.path.join(OUT_DIR, "pbr_dn_day.png")
    DN.render(day_png)

    print("[2/6] 点亮部分窗户 + 收集自发光簇")
    lit, total = DN.light_some_windows(
        objs, M.make("lamp", name="dn_window_lit"), prob=win_prob, seed=17)
    clusters = DN.collect_emissive(objs)
    rows, blackened = DN.audit_glow_source(objs)
    names = set()
    for o in objs:
        if o.type == "MESH" and o.data is not None:
            names |= {m.name for m in o.data.materials if m is not None}
    report["material_names"] = sorted(names)
    report["window_kind"] = "glass"
    report["windows"] = dict(lit=lit, total=total, prob=win_prob)
    report["emissive_materials"] = rows
    report["blackened_slots"] = blackened
    report["clusters"] = [dict(family=c["family"], mat=c["mat"].name,
                               strength=round(c["strength"], 2),
                               pos=tuple(round(v, 1) for v in c["pos"]),
                               size=tuple(round(v, 1) for v in c["size"]),
                               area=round(c["area"], 0), faces=c["n_faces"])
                          for c in clusters]
    print("   发光材质 %d 种：%s" % (len(rows), ", ".join(sorted(rows))))
    print("   发光簇 %d 个（窗 %d/%d 点亮）" % (len(clusters), lit, total))

    print("[3/6] 夜晚光照 + 点光源 + 光晕")
    DN.set_sky(sc, "dn_night_sky", DN.NIGHT_SKY_TOP, DN.NIGHT_SKY_BOTTOM,
               DN.NIGHT_SKY_STRENGTH)
    DN.set_suns(sc, DN.NIGHT_SUNS)
    # 先出一张**只有环境+月光、没有点光源/光晕**的标定图：它是"albedo × tint_night"
    # 那一层的真值，用来实测 tint（含点光源的夜图会把暖色算进 tint，R 通道被抬高）。
    amb_png = os.path.join(OUT_DIR, "_dn_night_ambient.png")
    DN.render(amb_png)
    plights, lrows = DN.add_point_lights(clusters, cam, gain=gain)
    halos = DN.add_halos(clusters, cam, mult=DN.HALO_NIGHT)
    report["point_lights"] = lrows
    print("   点光源 %d 盏 / 光晕贴片 %d 片" % (len(plights), len(halos)))
    night_png = os.path.join(OUT_DIR, "pbr_dn_night.png")
    DN.render(night_png)

    print("[4/6] 纯发光层（非发光材质 → 纯黑、世界全黑、灯全关）")
    saved, kept = DN.blacken_non_emissive(objs)
    lights_off = DN._lights_off()
    DN.set_sky(sc, "dn_black_sky", (0, 0, 0, 1), (0, 0, 0, 1), 0.0)
    for h in halos:
        h.hide_render = True
    ctrl_png = os.path.join(OUT_DIR, "_dn_glow_nohalo.png")
    DN.render(ctrl_png)
    for h in halos:                       # glow 层光晕足额（引擎 additive 用）
        h.hide_render = False
    DN.set_halo_mult(DN.HALO_GLOW)
    glow_png = os.path.join(OUT_DIR, "pbr_dn_glow.png")
    DN.render(glow_png)
    report["glow_separation"] = audit_glow_separation(ctrl_png)
    report["glow_kept_slots"] = kept
    ill_day = (sum(s[1] for s in DAY_SUNS) + math.pi * sky_radiance(*DAY_SKY))
    ill_night = (sum(s[1] for s in DN.NIGHT_SUNS)
                 + math.pi * sky_radiance(DN.NIGHT_SKY_TOP, DN.NIGHT_SKY_BOTTOM,
                                          DN.NIGHT_SKY_STRENGTH))
    report["illumination_ratio"] = round(ill_night / ill_day, 4)
    report["sky_radiance_day"] = round(sky_radiance(*DAY_SKY), 4)
    report["sky_radiance_night"] = round(
        sky_radiance(DN.NIGHT_SKY_TOP, DN.NIGHT_SKY_BOTTOM, DN.NIGHT_SKY_STRENGTH), 4)
    print("   glow 分离实测：非黑像素 %.2f%%，亮度上限 %.4f（非黑中位 %.4f）"
          % (report["glow_separation"]["nonblack_pct"],
             report["glow_separation"]["luma_max"],
             report["glow_separation"]["luma_p50_nonblack"]))
    DN.restore_lights(lights_off)
    DN.restore_slots(saved)

    print("[5/6] 分层合成 + 实测标定")
    day, w, h = _rgba(day_png)
    night, _w, _h = _rgba(night_png)
    glow, _w, _h = _rgba(glow_png)
    ctrl, _w, _h = _rgba(ctrl_png)
    amb, _w, _h = _rgba(amb_png)
    # tint 必须从**没有点光源/光晕**的环境标定图上量：夜图里点光源是暖橙的，
    # 直接量会把 R 通道算高（会把 tint 推成中性灰，丢掉冷蓝）。
    tint_median, npx = measure_tint(day, amb, ctrl)
    gm0 = _texture_mask(day) & (_luma(day) > 0.12) & (_luma(ctrl) < 0.004)
    tint_use = (calibrate_tint(day, amb, ctrl, gm0) if gm0.sum() > 500
                else (tint_median or list(DN.NIGHT_TINT)))
    if all(v <= 0.0 for v in tint_use):
        tint_use = list(DN.NIGHT_TINT)
    comp = compose(day, glow, tint_use, DN.GLOW_STRENGTH)
    d = float(np.mean(np.abs(comp - night[..., :3])))
    # 只在**几何面**上比：合成式管的是建筑/地面，天空是引擎另铺的一层
    # （把烘焙好的白天天空一起乘 tint 只会得到"变暗的白天天空"，不是夜景）。
    gm = _texture_mask(day) & (_luma(day) > 0.12)
    dg = float(np.mean(np.abs(comp[gm] - night[..., :3][gm]))) if gm.any() else None
    ld = float(np.mean(_luma(day)))
    ln = float(np.mean(_luma(night)))
    la = float(np.mean(_luma(amb)))
    report["tint_recommended"] = [round(v, 4) for v in tint_use]
    report["tint_design_start"] = list(DN.NIGHT_TINT)
    report["tint_median"] = [round(v, 4) for v in tint_median] if tint_median else None
    report["tint_measured"] = report["tint_median"]
    report["tint_measured_px"] = npx
    report["glow_strength"] = DN.GLOW_STRENGTH
    report["mean_luma_day"] = round(ld, 4)
    report["mean_luma_night_ambient"] = round(la, 4)
    report["mean_luma_night"] = round(ln, 4)
    report["night_ambient_vs_day"] = round(la / max(ld, 1e-6), 4)
    report["night_day_luma_ratio"] = round(ln / max(ld, 1e-6), 4)
    report["composite_vs_render_mae"] = round(d, 4)
    report["composite_vs_render_mae_geometry"] = (round(dg, 4) if dg is not None
                                                  else None)
    report["glow_mean_luma"] = round(float(np.mean(_luma(glow))), 4)
    print("   tint 建议 %s（最小二乘标定；逐像素比值中位 %s / 设计起点 %s，样本 %d px）"
          % (tuple(round(v, 3) for v in tint_use),
             tuple(round(v, 4) for v in tint_median) if tint_median else "样本不足",
             tuple(round(v, 3) for v in DN.NIGHT_TINT), npx))
    print("   平均亮度 白天 %.4f → 夜晚环境 %.4f (%.1f%%) → 夜图 %.4f (%.1f%%)"
          % (ld, la, 100.0 * la / max(ld, 1e-6), ln, 100.0 * ln / max(ld, 1e-6)))
    print("   光照口径（天空辐亮度 %.4f→%.4f，含方向光总辐照 %.3f→%.3f = %.1f%%）"
          % (report["sky_radiance_day"], report["sky_radiance_night"], ill_day,
             ill_night, 100.0 * report["illumination_ratio"]))
    print("   glow 层均值 %.4f；合成式 vs 真实夜图 MAE：全图 %.4f / **几何面 %.4f**"
          "（0=完全一致）" % (report["glow_mean_luma"], d,
                              dg if dg is not None else -1.0))

    print("[6/6] 分层说明图")
    if not fast:
        DN.montage([
            (day_png, "① 白天 albedo（暖主光 3.5 基线）"),
            ((compose(day, glow, tint_use, 0.0), w, h),
             "② albedo × tint_night(%s)" % ",".join("%.2f" % v for v in tint_use)),
            ((comp, w, h), "③ ② + glow × %.1f（引擎加法层）" % DN.GLOW_STRENGTH),
            (night_png, "④ 真实夜晚渲染（点光源 + 自发光 + 光晕）"),
        ], os.path.join(OUT_DIR, "pbr_dn_layers.png"),
            title="昼夜分层：夜 = albedo × tint_night + glow × strength"
                  "   |   白天烘焙一次，夜 = 一行调色 + 一层加法")

    with open(os.path.join(OUT_DIR, "pbr_daynight_report.json"), "w",
              encoding="utf-8") as fh:
        json.dump(report, fh, ensure_ascii=False, indent=1)
    print("\nDAYNIGHT_OK  灯 %d / 簇 %d / 点亮窗 %d/%d"
          % (len(plights), len(clusters), lit, total))


main()
