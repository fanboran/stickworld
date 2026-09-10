#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""R8 层2 验收预览 —— 地图线条语言与 SketchDraw 手绘同源（Python 端实现）。

产出（tools/worldgen/output/）：
  r8_line_before_after.png     L1 出生包城界：改造前直线描边 vs 改造后手绘描边（含 400% 放大）
  r8_line_ui_consistency.png   UI 控件边框笔触 vs L1 城界笔触 400% 对照（同源密度/幅度）
  r8_line_boundary_tiers.png   L3 政治模式界线三级：国界 3px 实线 / 地区界 2px 长虚线 / 地块界 1px 短虚线

同源口径（R8 层2，与 GDScript 端对齐）：
  - wobble 公式与 ui_global/scripts/sketch/sketch_draw.gd::wobble **逐位同源**
    （sin(i*127.1+seed*0.3117)*43758.5453，fposmod(v,1)-0.5；Python double 与
    GDScript float 同为 64 位 IEEE754）
  - 采样/扰动几何与 modules/world_map/scripts/map_sketch.gd::wobble_polyline 对齐：
    顶点拖拽（共享端点扰动一致 → 折线连续无缝）+ 边内法向波动
  - 线宽档/虚线节拍与 modules/world_map/scripts/map_tokens.gd 一致：
    国 3px 实线 / 地区 2px 长虚线(dash16 gap8) / 地块 1px 短虚线(dash7 gap5)；
    采样段长 = 12×线宽，扰动幅度 = 0.55×线宽
  - seed 派生（几何 id/坐标 DJB2）为各端自洽实现：同端同几何必同 seed 即达目的
    （不沸腾）；Python 端此实现同时是 R9 静态烘焙管线（per-L1 烘焙）的 wobble 同源基座

用法：
  "C:/Users/fanbo/AppData/Local/Programs/Python/Python312/python.exe" \
      tools/worldgen/r8_sketch_line.py [--outdir tools/worldgen/output]
"""
import argparse
import json
import math
import os

from PIL import Image, ImageDraw, ImageFont

SS = 4  # 超采样倍率（降采样出 AA，烘焙管线同法）

# ────────────────── wobble 同源核心（逐位对齐 SketchDraw / MapSketch）──────────────────

def wobble(i: int, seed: int) -> float:
    """确定性伪噪声（-0.5~0.5）：与 SketchDraw.wobble 逐位同源。"""
    v = math.sin(float(i) * 127.1 + float(seed) * 0.3117) * 43758.5453
    return v - math.floor(v) - 0.5  # = GDScript fposmod(v, 1.0) - 0.5


def _mix(h: int, v: int) -> int:
    return ((h << 5) + h + v) & 0x7FFFFFFF  # DJB2 整型混合一步


def _quant(p) -> tuple:
    return (round(p[0] * 4.0), round(p[1] * 4.0))  # 0.25px 格


def vertex_seed(p) -> int:
    q = _quant(p)
    return _mix(_mix(5381, q[0]), q[1])


def edge_seed(a, b, salt: int) -> int:
    qa, qb = _quant(a), _quant(b)
    if qb < qa:
        qa, qb = qb, qa
    h = _mix(5381, salt)
    h = _mix(h, qa[0]); h = _mix(h, qa[1])
    h = _mix(h, qb[0]); h = _mix(h, qb[1])
    return h


def djb2_str(s: str) -> int:
    h = 5381
    for c in s.encode("utf-8"):
        h = _mix(h, c)
    return h


def id_seed(s: str, salt: int = 0) -> int:
    return djb2_str(s) + salt * 2654435761


# MapTokens（map_tokens.gd）同值：段长/幅度相对线宽
SEG_LEN_RATIO = 12.0
AMP_RATIO = 0.55


def wobble_polyline(pts, seed: int, width: float, closed: bool):
    """对齐 MapSketch.wobble_polyline：顶点拖拽 + 边内法向波动。
    closed=True 返回首尾不重复点列；closed=False 补末点。"""
    n_in = len(pts)
    if n_in < 2 or width <= 0.0:
        return list(pts)
    amp = width * AMP_RATIO
    seg_len = max(width * SEG_LEN_RATIO, 2.0)
    out = []
    edge_count = n_in if closed else n_in - 1

    def vertex_offset(p):
        s = vertex_seed(p) + seed
        return (wobble(1, s) * amp, wobble(2, s) * amp)

    for e in range(edge_count):
        a, b = pts[e], pts[(e + 1) % n_in]
        eseed = edge_seed(a, b, seed)
        oa, ob = vertex_offset(a), vertex_offset(b)
        seg_px = math.dist(a, b)
        if seg_px <= 0.0001:
            continue
        steps = max(1, round(seg_px / seg_len))
        dx, dy = (b[0] - a[0]) / seg_px, (b[1] - a[1]) / seg_px
        nx, ny = -dy, dx
        for i in range(steps):
            t = i / steps
            drag = (oa[0] + (ob[0] - oa[0]) * t, oa[1] + (ob[1] - oa[1]) * t)
            wav = wobble(i, eseed) * amp
            out.append((a[0] + (b[0] - a[0]) * t + drag[0] + nx * wav,
                        a[1] + (b[1] - a[1]) * t + drag[1] + ny * wav))
    if not closed:
        last = pts[-1]
        lo = vertex_offset(last)
        out.append((last[0] + lo[0], last[1] + lo[1]))
    return out


def dash_segments(segs, pts, dash: float, gap: float) -> None:
    """对齐 MapSketch.dash_segments：dash/gap 交替弧长切段（相位跨顶点连续）。"""
    drawing = True
    remain = dash
    for i in range(len(pts) - 1):
        a, b = pts[i], pts[i + 1]
        seg_len = math.dist(a, b)
        if seg_len <= 0.0001:
            continue
        walked = 0.0
        while walked < seg_len - 0.0001:
            step = min(remain, seg_len - walked)
            if drawing:
                segs.append((a[0] + (b[0] - a[0]) * walked / seg_len,
                             a[1] + (b[1] - a[1]) * walked / seg_len))
                segs.append((a[0] + (b[0] - a[0]) * (walked + step) / seg_len,
                             a[1] + (b[1] - a[1]) * (walked + step) / seg_len))
            walked += step
            remain -= step
            if remain <= 0.0001:
                drawing = not drawing
                remain = dash if drawing else gap


# ────────────────── UI 面板边框复刻（SketchDraw.wobbly_rect_path）──────────────────

WOBBLE_AMP = 0.95
UI_SEG_LEN = 18.0
ARC_STEPS = 4


def amp_for(w: float, h: float) -> float:
    m = min(w, h)
    return min(max(WOBBLE_AMP * m / 40.0, WOBBLE_AMP), 1.3)


def wobbly_rect_path(x, y, w, h, seed: int, corner_r=7.0, amp=-1.0):
    """对齐 SketchDraw.wobbly_rect_path（四边 SEG_LEN 分段 + 四角外凸圆弧全扰动）。
    返回闭合路径（首尾不重复，长度 = 每边 n+1 + 4角×ARC_STEPS，与 GDScript 同构）。"""
    if amp < 0.0:
        amp = amp_for(w, h)
    idx = 0
    pts = []
    left, top = x, y
    right, bottom = x + w, y + h

    def edge(p_from, p_to, normal, n):
        nonlocal idx
        for i in range(n + 1):
            t = i / n
            o = wobble(idx, seed) * amp
            idx += 1
            pts.append((p_from[0] + (p_to[0] - p_from[0]) * t + normal[0] * o,
                        p_from[1] + (p_to[1] - p_from[1]) * t + normal[1] * o))

    def arc(center, a0, a1, radius):
        nonlocal idx
        for i in range(ARC_STEPS):
            t = i / ARC_STEPS
            a = a0 + (a1 - a0) * t
            rr = radius + wobble(idx, seed) * amp * 0.9
            idx += 1
            rr = max(rr, radius * 0.55)
            pts.append((center[0] + math.cos(a) * rr, center[1] + math.sin(a) * rr))

    cr = min(corner_r, w * 0.5 - 2.0, h * 0.5 - 2.0)
    if cr < 2.0:
        cr = 2.0
    # 顶边（左→右）→ 右上角弧 → 右边（上→下）→ 右下弧 → 底边（右→左）→ 左下弧
    # → 左边（下→上）→ 左上弧（与 GDScript 同序，保证扰动相位同构）
    n = max(2, round((right - left - cr * 2) / UI_SEG_LEN))
    edge((left + cr, top), (right - cr, top), (0, -1), n)
    arc((right - cr, top + cr), -math.pi * 0.5, 0.0, cr)
    n = max(2, round((bottom - top - cr * 2) / UI_SEG_LEN))
    edge((right, top + cr), (right, bottom - cr), (1, 0), n)
    arc((right - cr, bottom - cr), 0.0, math.pi * 0.5, cr)
    n = max(2, round((right - left - cr * 2) / UI_SEG_LEN))
    edge((right - cr, bottom), (left + cr, bottom), (0, 1), n)
    arc((left + cr, bottom - cr), math.pi * 0.5, math.pi, cr)
    n = max(2, round((bottom - top - cr * 2) / UI_SEG_LEN))
    edge((left, bottom - cr), (left, top + cr), (-1, 0), n)
    arc((left + cr, top + cr), math.pi, math.pi * 1.5, cr)
    return pts


# ────────────────── 绘制工具（超采样 AA）──────────────────

def draw_wobbled(draw, pts, seed, width, color, closed=False, dash=None, gap=None):
    wpts = wobble_polyline(pts, seed, width, closed)
    if dash is not None:
        segs = []
        dash_segments(segs, wpts, dash, gap)
        pairs = [(segs[i], segs[i + 1]) for i in range(0, len(segs) - 1, 2)]
    else:
        loop = list(wpts)
        if closed:
            loop.append(loop[0])
        pairs = [(loop[i], loop[i + 1]) for i in range(len(loop) - 1)]
    for a, b in pairs:
        draw.line([a[0] * SS, a[1] * SS, b[0] * SS, b[1] * SS],
                  fill=color, width=max(1, round(width * SS)))
    # 端点圆头（画布同宽圆点补出 joint 观感）
    r = width * SS / 2.0
    for a, b in pairs:
        for p in (a, b):
            draw.ellipse([p[0] * SS - r, p[1] * SS - r, p[0] * SS + r, p[1] * SS + r],
                         fill=color)


def downscale(img: Image.Image) -> Image.Image:
    return img.resize((img.width // SS, img.height // SS), Image.LANCZOS)


def font(sz=22):
    try:
        return ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", sz)
    except OSError:
        return ImageFont.load_default()


# ────────────────── 预览 1：L1 城界 改造前 vs 改造后 ──────────────────

def preview_before_after(pack_path, out_path):
    data = json.load(open(pack_path, encoding="utf-8"))
    tiles = [t for t in data["tiles"] if len(t.get("polygon", [])) >= 3]
    ctx = data["context_size"]
    panel = 760.0 / max(ctx)
    W, H = 1620, 1560
    img = Image.new("RGB", (W * SS, H * SS), (232, 228, 218))  # 纸面浅底
    d = ImageDraw.Draw(img)
    tile_border = (89, 89, 89)  # MapTokens.L1_TILE_BORDER_COLOR 0.35 灰

    def draw_tiles(ox, oy, wobbled: bool):
        for t in tiles:
            pts = [(p[0] * panel + ox, p[1] * panel + oy) for p in t["polygon"]]
            seed = id_seed(t["tile_id"])
            width = 1.6
            if wobbled:
                draw_wobbled(d, pts, seed, width, tile_border, closed=True)
            else:
                loop = pts + [pts[0]]
                for i in range(len(loop) - 1):
                    a, b = loop[i], loop[i + 1]
                    d.line([a[0] * SS, a[1] * SS, b[0] * SS, b[1] * SS],
                           fill=tile_border, width=round(width * SS))

    ox_l, ox_r, oy = 40, 820, 90
    draw_tiles(ox_l, oy, False)
    draw_tiles(ox_r, oy, True)
    f = font(30)
    d.text((ox_l * SS, 30 * SS), "BEFORE  改造前：直线段描边", fill=(40, 40, 40), font=f)
    d.text((ox_r * SS, 30 * SS), "AFTER  R8 层2：手绘同源描边（固定 seed 不沸腾）",
           fill=(40, 40, 40), font=f)
    # 400% 放大：两栏取同一相对区域（tile 交界处）并排对照
    zx, zy = 200, 380   # 左栏 crop 原点；右栏 = +780（同相对位置）
    cw, ch = 190, 130   # crop 尺寸 → 4x = 760x520
    c1 = img.crop((int(zx * SS), int(zy * SS), int((zx + cw) * SS), int((zy + ch) * SS)))
    c1 = c1.resize((c1.width * 4, c1.height * 4), Image.NEAREST)
    c2 = img.crop((int((zx + ox_r - ox_l) * SS), int(zy * SS),
                   int((zx + ox_r - ox_l + cw) * SS), int((zy + ch) * SS)))
    c2 = c2.resize((c2.width * 4, c2.height * 4), Image.NEAREST)
    by = 950
    img.paste(c1, (int(ox_l * SS), int(by * SS)))
    img.paste(c2, (int(ox_r * SS), int(by * SS)))
    f2 = font(24)
    d2 = ImageDraw.Draw(img)
    d2.text((ox_l * SS, (by - 40) * SS), "BEFORE 400%", fill=(40, 40, 40), font=f2)
    d2.text((ox_r * SS, (by - 40) * SS), "AFTER 400%（同区域）", fill=(40, 40, 40), font=f2)
    downscale(img).save(out_path)
    print("saved", out_path)


# ────────────────── 预览 2：UI 边框笔触 vs 城界笔触 一致性对照 ──────────────────

def preview_ui_consistency(pack_path, out_path):
    data = json.load(open(pack_path, encoding="utf-8"))
    tiles = [t for t in data["tiles"] if len(t.get("polygon", [])) >= 3]
    W, H = 1620, 700
    img = Image.new("RGB", (W * SS, H * SS), (18, 19, 24))  # UI 黑玻璃底
    d = ImageDraw.Draw(img)
    # 左：UI 面板边框（SketchDraw 同构：OUTLINE_WIDTH 1.6 / SEG_LEN 18 / amp_for）
    panel_r = (60, 60, 300, 170)
    x, y, w, h = panel_r
    path = wobbly_rect_path(x, y, w, h, id_seed("panel"))
    loop = path + [path[0]]
    for i in range(len(loop) - 1):
        a, b = loop[i], loop[i + 1]
        d.line([a[0] * SS, a[1] * SS, b[0] * SS, b[1] * SS],
               fill=(240, 240, 244), width=round(1.6 * SS))
    # 右：L1 城界（放大到与面板同观感尺度：width 2 / 段长 24 —— 与 UI 18/1.6 密度同量级）
    t = tiles[0]
    poly = t["polygon"]
    xs = [p[0] for p in poly]; ys = [p[1] for p in poly]
    sw, sh = max(xs) - min(xs), max(ys) - min(ys)
    sc = min(300.0 / sw, 170.0 / sh)
    ox, oy = 900 - min(xs) * sc, 145 - min(ys) * sc
    pts = [(p[0] * sc + ox, p[1] * sc + oy) for p in poly]
    draw_wobbled(d, pts, id_seed(t["tile_id"]), 2.0, (240, 240, 244), closed=True)
    # 两块 400% 放大对照条（crop 均穿过边框/城界线本体）
    def zoom4(box, target):
        c = img.crop(tuple(int(v * SS) for v in box))
        c = c.resize((c.width * 4, c.height * 4), Image.NEAREST)
        img.paste(c, (int(target[0] * SS), int(target[1] * SS)))
    zoom4((250, 30, 375, 105), (60, 330))      # 面板顶边 + 右上圆角 + 右边框
    zoom4((945, 95, 1070, 170), (900, 330))    # 城界左缘
    f = font(26)
    d.text((60 * SS, 20 * SS), "UI 面板边框（SketchDraw：1.6px / 18px 采样 / 0.55×宽 幅度）",
           fill=(235, 235, 240), font=f)
    d.text((900 * SS, 20 * SS), "L1 城界（MapSketch：2px / 12×宽=24px 采样 / 0.55×宽 幅度）",
           fill=(235, 235, 240), font=f)
    d.text((60 * SS, 300 * SS), "UI 400%", fill=(160, 160, 168), font=font(22))
    d.text((900 * SS, 300 * SS), "城界 400%", fill=(160, 160, 168), font=font(22))
    d.text((760 * SS, 660 * SS), "同款马克笔笔触：扰动密度同量级（18px vs 24px 段长）、幅度同为 ~0.55×线宽",
           fill=(160, 160, 168), font=font(22))
    downscale(img).save(out_path)
    print("saved", out_path)


# ────────────────── 预览 3：L3 政治模式界线三级 ──────────────────

def preview_boundary_tiers(base, out_path):
    city = json.load(open(os.path.join(base, "l3_city.json"), encoding="utf-8"))
    l1 = json.load(open(os.path.join(base, "l3_l1.json"), encoding="utf-8"))
    l3 = json.load(open(os.path.join(base, "l3_world.json"), encoding="utf-8"))
    pol = json.load(open(os.path.join(base, "political_data.json"), encoding="utf-8"))
    states = pol["states"]
    S = 2048 / 8192.0  # 8192 级 → 2048 出图（≈游戏整图 zoom 0.23 的屏幕观感 1:1）

    img = Image.new("RGB", (2048 * SS, 2048 * SS), (26, 38, 58))
    d = ImageDraw.Draw(img)
    # 底：1040 城块政权色淡填充（图例观感对齐 LUT 彩底）
    for t in city["tiles"]:
        st = states.get(t.get("state_id", ""))
        if not st:
            continue
        c = st["color"]
        col = (int(255 - (255 - c[0]) * 0.55), int(255 - (255 - c[1]) * 0.55),
               int(255 - (255 - c[2]) * 0.55))
        for poly in t.get("polygons", []):
            pts = [(p[1] * S, p[0] * S) for p in poly]  # [y,x] → (x,y)
            if len(pts) >= 3:
                d.polygon([(x * SS, y * SS) for x, y in pts], fill=col)
    # 地块界（1px 短虚线，深灰墨）：69 块老 L1 边界
    for t in l1["tiles"]:
        for poly in t.get("polygons", []):
            pts = [(p[1] * S, p[0] * S) for p in poly]
            if len(pts) >= 3:
                draw_wobbled(d, pts, id_seed("l3_plot"), 1.0, (96, 96, 96),
                             closed=True, dash=7.0, gap=5.0)
    # 地区界（2px 长虚线，深墨）：13 个 L2 地区轮廓
    for r in l3["regions"]:
        for poly in r.get("land_polygons", [r.get("land_polygon", [])]):
            pts = [(p[1] * S, p[0] * S) for p in poly]
            if len(pts) >= 3:
                draw_wobbled(d, pts, id_seed("l3_region_%d" % r.get("label", 0)),
                             2.0, (36, 36, 38), closed=True, dash=16.0, gap=8.0)
    # 国界（3px 实线，亮白）：城块共享边两侧政权不同（states 邻接，edge_key 提取）
    edges = {}
    for t in city["tiles"]:
        st = t.get("state_id", "")
        if not st:
            continue
        for poly in t.get("polygons", []):
            pts = [(p[1], p[0]) for p in poly]  # 渲染系 (x,y)，8192 级
            n = len(pts)
            if n < 3:
                continue
            for i in range(n):
                a, b = pts[i], pts[(i + 1) % n]
                qa, qb = _quant(a), _quant(b)
                key = (qa + qb) if qa < qb else (qb + qa)
                e = edges.get(key)
                if e is None:
                    e = edges[key] = {"a": a, "b": b, "states": set()}
                e["states"].add(st)
    for e in edges.values():
        if len(e["states"]) < 2:
            continue
        seg = [(e["a"][0] * S, e["a"][1] * S), (e["b"][0] * S, e["b"][1] * S)]
        draw_wobbled(d, seg, id_seed("l3_national"), 3.0, (238, 240, 244), closed=False)
    img = downscale(img)
    f = font(34)
    d2 = ImageDraw.Draw(img)
    d2.rectangle([24, 24, 560, 190], fill=(20, 22, 30))
    d2.line([40 * SS // SS, 64, 110, 64], fill=(238, 240, 244), width=3)
    d2.text((124, 48), "国界 3px 实线（亮）— states 邻接", fill=(238, 240, 244), font=font(26))
    for i in range(0, 84, 16):
        d2.line([40 + i, 104, 40 + i + 10, 104], fill=(60, 60, 64), width=2)
    d2.text((124, 88), "地区界 2px 长虚线（dash16/gap8）", fill=(200, 200, 206), font=font(26))
    for i in range(0, 70, 12):
        d2.line([40 + i, 144, 40 + i + 7, 144], fill=(120, 120, 120), width=1)
    d2.text((124, 128), "地块界 1px 短虚线（dash7/gap5）", fill=(170, 170, 176), font=font(26))
    img.save(out_path)
    print("saved", out_path, "国界段数:", sum(1 for e in edges.values() if len(e["states"]) >= 2))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--outdir", default="tools/worldgen/output")
    args = ap.parse_args()
    base = "stick-world/config/strategic_map"
    pack = os.path.join(base, "l1_packs/l1_001/l1_world.json")
    os.makedirs(args.outdir, exist_ok=True)
    preview_before_after(pack, os.path.join(args.outdir, "r8_line_before_after.png"))
    preview_ui_consistency(pack, os.path.join(args.outdir, "r8_line_ui_consistency.png"))
    preview_boundary_tiers(base, os.path.join(args.outdir, "r8_line_boundary_tiers.png"))


if __name__ == "__main__":
    main()
