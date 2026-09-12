# -*- coding: utf-8 -*-
"""城镇平面示意图渲染（PIL，不依赖 Blender）—— 自证 §4 城市设计规范。

跑法：cd tools/blender_buildings && python probe_city_plan.py
输出：stick-world/temp/city_plan_<tier>.png（4 档）+ 同名 .json（布局数据）

一张图里三块内容，纵向对齐同一 x 轴：
  ① 平面图  —— 城墙/塔楼/城门、主街+纵向支路+排间巷、广场、按 zone 上色的建筑块 + def 标注、
                院坝/田地、前景 props；带 zone 分带标签与 5 格比例尺
  ② 立面天际线条 —— 按 baseline_y 分层叠画（前排最后画=遮住后排），画墙顶线与塔楼，
                用来直读 §4.4：唯一最高点是不是教堂钟楼、墙顶是否在 80% 建筑之上
  ③ 图例/校验 —— def → index 对照、五条规范校验结果（与 city_layout.verify_plan 同源）
"""
import json
import os
import sys

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import city_layout as CL  # noqa: E402

OUT_DIR = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "..", "stick-world", "temp"))
PROBE_SEEDS = {"hamlet": 611036, "village": 611039, "town": 611033, "city": 611036}
CONTENT_W = 1880            # 内容区目标宽度（px），几何按此缩放
MARGIN = 24

ZONE_FILL = {
    "core":        (196, 122, 200),   # 紫：核心（教堂/行会馆）
    "market":      (247, 181, 78),    # 橙：市场
    "artisan":     (232, 108, 74),    # 砖红：工匠
    "residential": (126, 178, 232),   # 蓝：居住
    "production":  (122, 196, 122),   # 绿：生产
}
ZONE_EDGE = {k: tuple(max(0, c - 70) for c in v) for k, v in ZONE_FILL.items()}
WALL_FILL = (108, 108, 118)
WALL_EDGE = (66, 66, 74)
TOWER_FILL = (74, 74, 86)
ROAD_FILL = (206, 200, 188)
ROAD_EDGE = (176, 168, 156)
PLAZA_FILL = (243, 232, 205)
PLAZA_EDGE = (196, 178, 140)
YARD_FILL = (206, 224, 196)
GATE_FILL = (92, 82, 78)
PROP_FILL = (150, 120, 82)
INK = (32, 32, 36)
BG = (250, 249, 246)
GRID = (232, 230, 224)

FONT_CANDIDATES = [
    "C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/msyhbd.ttc",
    "C:/Windows/Fonts/simhei.ttf", "C:/Windows/Fonts/arial.ttf",
]
FONT_PATH = next((p for p in FONT_CANDIDATES if os.path.exists(p)), None)


def font(size):
    if FONT_PATH:
        try:
            return ImageFont.truetype(FONT_PATH, size)
        except Exception:
            pass
    return ImageFont.load_default()


def text(dr, xy, s, size=13, fill=INK, anchor="la"):
    dr.text(xy, s, font=font(size), fill=fill, anchor=anchor)


def vtext(img, xy, s, size=11, fill=INK):
    """竖排标注（窄建筑块用）。"""
    f = font(size)
    w = size + 4
    h = size * len(s) + 4
    tmp = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(tmp).text((1, 1), s, font=f, fill=fill)
    img.paste(tmp.rotate(90, expand=True), (int(xy[0] - (h / 2) + 6), int(xy[1] - (w / 2))),
              tmp.rotate(90, expand=True))


def fit_label(dr, s, size, max_w):
    while len(s) > 3 and dr.textlength(s, font=font(size)) > max_w:
        s = s[:-1]
    return s


def render(tier, seed=611036, out_path=None, write_json=True):
    plan = CL.plan_city(tier, seed=seed)
    cw = plan["cell_w"]
    cols, rows = plan["cols"], plan["rows"]
    width_px, depth_px = plan["width_px"], plan["depth_px"]
    S = min(1.0, CONTENT_W / width_px)
    plan_w, plan_h = width_px * S, depth_px * S

    # 立面空间跨度（用于天际线条高度）
    max_top = 0
    for l in plan["lots"]:
        max_top = max(max_top, l["top_h_px"])
    wall_b = plan["rows_bands"][-1]["b1"]
    b_wall_all = wall_b + plan["params"]["margin_cells"]
    max_top = max(max_top, plan["walls"]["height_px"])
    for t in plan["walls"]["towers"]:
        max_top = max(max_top, t["height_px"])
    strip_h = max_top * S + 34

    header_h, legend_row_h = 42, 17
    n_defs = len({l["def"] for l in plan["lots"]} | {"wall_seg", "gatehouse", "tower"})
    legend_cols = 4
    legend_h = 28 + ((n_defs + legend_cols - 1) // legend_cols) * legend_row_h + 118
    img_h = int(MARGIN + header_h + plan_h + 34 + strip_h + legend_h + MARGIN)
    img_w = int(MARGIN * 2 + plan_w)
    img = Image.new("RGB", (img_w, img_h), BG)
    dr = ImageDraw.Draw(img)

    ox, oy = MARGIN, MARGIN + header_h
    X = lambda px: ox + px * S              # noqa: E731
    Y = lambda py: oy + py * S              # noqa: E731

    # ── ① 平面：底/网格/院坝 ────────────────────────────────────────────
    text(dr, (MARGIN, MARGIN + 2),
         "城镇平面示意图 · %s · %d×%dpx（%d×%d 格）· seed %d · 依据 §4 城市设计规范"
         % (tier, width_px, depth_px, cols, rows, seed), 17, INK)
    text(dr, (MARGIN, MARGIN + 24),
         "上=城后（北）；下=观察者（南）。红色底边 = 该建筑前进线被广场北推（正对广场）。"
         "数字 = 建筑序号（见图例 def 名）；塔楼上的数字 = 塔顶高 px。", 12, (110, 108, 104))
    dr.rectangle([ox, oy, ox + plan_w, oy + plan_h], fill=(238, 236, 230))

    def rect_cells(x0, x1, y0, y1, fill, edge=None, w=1):
        dr.rectangle([X(x0 * cw), Y(y0 * cw), X(x1 * cw) - 1, Y((y1 + 1) * cw) - 1],
                     fill=fill, outline=edge, width=w)

    for yd in plan["yards"]:
        ya, yb = yard_y(plan, yd)
        rect_cells(yd["x0"], yd["x1"], ya, yb,
                   YARD_FILL if yd["kind"] == "yard" else (228, 208, 132))

    # 行带整体铺「院坝/后yard」底色（建筑之后的进深余量 = 后院/菜园）
    for rb in plan["rows_bands"]:
        ya, yb = row_band_y(plan, rb)
        rect_cells(0, cols, ya, yb, (226, 234, 218) if rb["row"] % 2 == 0
                   else (232, 238, 224))

    # 道路：主街
    m = plan["roads"]["main"]
    rect_cells(m["x_cells"][0], m["x_cells"][1], m["y_cells"][0], m["y_cells"][1] - 1,
               ROAD_FILL, ROAD_EDGE)
    # 排间巷
    for ln in plan["roads"]["lanes"]:
        rect_cells(0, cols, ln["y_cells"][0], ln["y_cells"][1] - 1,
                   (224, 219, 208), ROAD_EDGE)
    # 纵向支路
    for br in plan["roads"]["branches"]:
        y0 = (rows - plan["params"]["street_w_cells"] - 1) - br["b1"]
        y1 = (rows - plan["params"]["street_w_cells"] - 1) - br["b0"]
        rect_cells(br["x0"], br["x1"], y0, y1, ROAD_FILL, ROAD_EDGE)

    # 广场
    pl = plan["roads"]["plaza"]
    if pl:
        rect_cells(pl["x_cells"][0], pl["x_cells"][1], pl["y_cells"][0],
                   pl["y_cells"][1] - 1, PLAZA_FILL, PLAZA_EDGE, 2)
        plaza_label = None
    if pl:
        plaza_label = (X(pl["center_x_px"]),
                       Y((pl["y_cells"][1] - 1) * cw) - 10,
                       "广场 %d×%d（紧贴主街）" % (pl["w_cells"], pl["h_cells"]))

    # 城墙（左右后三趟）
    for run in plan["walls"]["runs"]:
        rect_cells(run["x_cells"][0], run["x_cells"][1], run["y_cells"][0],
                   run["y_cells"][1] - 1, WALL_FILL, WALL_EDGE)
    # 城墙段等分刻度（4 格 = 128px 一段）
    seg = plan["walls"]["seg_cells"]
    for run in plan["walls"]["runs"]:
        if run["axis"] == "y":
            xx = X(run["x_cells"][0] * cw) + 1
            for i in range(seg, rows, seg):
                dr.line([xx, Y(i * cw) - 4, xx, Y(i * cw) + 4], fill=(228, 226, 232))
        else:
            yy = Y(run["y_cells"][0] * cw) + 1
            for i in range(seg, cols, seg):
                dr.line([X(i * cw), yy, X(i * cw), yy + 5], fill=(228, 226, 232))
    # 塔楼
    for t in plan["walls"]["towers"]:
        tw = t["w_cells"]
        if t["axis"] == "y":
            x0 = 0 if t["side"] == "left" else cols - tw
            y0 = t["i_cells"] - tw // 2
        else:
            x0 = t["i_cells"] - tw // 2
            y0 = 0
        dr.rectangle([X(x0 * cw), Y(y0 * cw), X((x0 + tw) * cw), Y((y0 + tw) * cw)],
                     fill=TOWER_FILL, outline=(40, 40, 48), width=1)
        text(dr, (X((x0 + tw / 2) * cw), Y((y0 + tw / 2) * cw)),
             "%d" % t["height_px"], 10, (255, 235, 200), "mm")
    # 城门
    st0 = rows - plan["params"]["street_w_cells"]
    for g in plan["walls"]["gates"]:
        cy = (st0 + rows) / 2.0
        y0 = int(cy - g["facade_w_cells"] / 2.0)
        y1 = y0 + g["facade_w_cells"]
        rect_cells(g["x_cells"][0], g["x_cells"][1], y0, y1, GATE_FILL, (44, 40, 38), 2)
        text(dr, (X((g["x_cells"][0] + (g["x_cells"][1] - g["x_cells"][0]) / 2) * cw),
                  Y(y0 * cw) - 12), "城门", 12, (70, 40, 30), "mm")

    # 建筑块
    for l in plan["lots"]:
        x0, x1 = l["x_cells"]
        y0, y1 = l["back_y_cell"], l["front_y_cell"]
        zf, ze = ZONE_FILL[l["zone"]], ZONE_EDGE[l["zone"]]
        dr.rectangle([X(x0 * cw), Y(y0 * cw), X(x1 * cw) - 1, Y((y1 + 1) * cw) - 1],
                     fill=zf, outline=ze, width=1)
        if l["front_faces_plaza"]:
            dr.line([X(x0 * cw), Y((y1 + 1) * cw) - 1, X(x1 * cw), Y((y1 + 1) * cw) - 1],
                    fill=(180, 60, 40), width=2)
        w_px = (x1 - x0) * cw * S
        d_px = (y1 - y0 + 1) * cw * S
        cx, cy = X((x0 + x1) / 2.0 * cw), Y((y0 + y1 + 1) / 2.0 * cw)
        lab = "%d %s" % (l["index"], l["def"])
        if dr.textlength(lab, font=font(10)) <= w_px - 4 and y0 != y1:
            text(dr, (cx, cy), lab, 10, (24, 24, 28), "mm")
        elif d_px > 42 and x1 - x0 <= 6:
            vtext(img, (cx, cy), l["def"], 9, (24, 24, 28))
        else:
            text(dr, (cx, cy), "%d" % l["index"], 10, (24, 24, 28), "mm")

    if plan["roads"]["plaza"]:
        text(dr, (plaza_label[0], plaza_label[1]), plaza_label[2], 13,
             (150, 96, 20), "ms")

    # 前景 props
    for p in plan["props"]:
        px0, px1 = p["x_cells"]
        py = p["y_cells"][0]
        col = (176, 106, 70) if p.get("in_plaza") else PROP_FILL
        dr.ellipse([X(px0 * cw), Y(py * cw) - 4, X(px1 * cw), Y(py * cw) + 4],
                   fill=col, outline=(90, 70, 50))

    # zone 分带标签（平面顶部）
    for b in plan["bands"]:
        c0, c1 = b["x_cells"]
        if c1 - c0 < 3:
            continue
        txt = "%s%s" % (CL.ZONE_CN[b["zone"]], "" if b["side"] == "center"
                        else ("·左" if b["side"] == "left" else "·右"))
        text(dr, (X((c0 + c1) / 2.0 * cw), oy - 8), txt, 12,
             ZONE_EDGE[b["zone"]], "ms")
    text(dr, (ox + 4, oy + plan_h + 6), "← 西   平面（上=城后/北，下=观察者/南）   东 →",
         13, (90, 88, 84), "la")
    # 比例尺
    sbx = ox + 300
    sby = oy + plan_h + 8
    dr.rectangle([sbx, sby, sbx + 5 * cw * S, sby + 8], fill=(70, 70, 74))
    text(dr, (sbx + 5 * cw * S / 2, sby + 12), "5 格 = 160px", 11, (70, 70, 74), "ma")

    # ── ② 立面天际线条 ─────────────────────────────────────────────────
    sy_base = oy + plan_h + 34
    sl_h = strip_h
    dr.rectangle([ox, sy_base, ox + plan_w, sy_base + sl_h], fill=(246, 245, 240))
    ground = sy_base + sl_h
    SY = lambda pt: ground - pt * S      # 立面高度 → 图内 y    # noqa: E731
    b_wall = (plan["rows_bands"][-1]["b1"] + plan["params"]["margin_cells"])
    # 后城墙（最后画在最底层的“背景” → 这里按 b 从大到小先画）
    for run in plan["walls"]["runs"]:
        if run["side"] != "back":
            continue
        y0 = SY(plan["walls"]["height_px"])
        dr.rectangle([X(run["x_cells"][0] * cw), y0, X(run["x_cells"][1] * cw), SY(0)],
                     fill=(226, 224, 228), outline=WALL_EDGE)
    # 左右城墙趟在立面里是 1 格宽的端柱（§4.5 左右两端以城墙转角收边）
    for run in plan["walls"]["runs"]:
        if run["side"] not in ("left", "right"):
            continue
        xa = X(run["x_cells"][0] * cw)
        xb = X(run["x_cells"][1] * cw)
        dr.rectangle([xa, SY(plan["walls"]["height_px"]), xb, SY(0)],
                     fill=WALL_FILL, outline=WALL_EDGE)
    cy_crest = SY(plan["walls"]["height_px"])
    for xx in range(int(ox), int(ox + plan_w), 22):
        dr.line([xx, cy_crest, min(xx + 9, ox + plan_w), cy_crest],
                fill=(216, 118, 100), width=1)
    crest_label = (cy_crest, "墙顶 %dpx（高于非核心 %.0f%%，红虚线）"
                    % (plan["skyline"]["wall_crest_px"],
                       plan["skyline"]["wall_above_ratio_non_core"] * 100))
    dr.line([ox, SY(0), ox + plan_w, SY(0)], fill=(150, 146, 140), width=2)
    # 后排先画（前排压住后排），共用基线：直接读「谁最高」（§4.4）
    for l in sorted(plan["lots"], key=lambda l: (-l["row"], l["x_cells"][0])):
        x0, x1 = l["x_cells"]
        zf, ze = ZONE_FILL[l["zone"]], ZONE_EDGE[l["zone"]]
        dr.rectangle([X(x0 * cw), SY(l["top_h_px"]), X(x1 * cw) - 1, SY(0)],
                     fill=zf, outline=ze)
        if l["top_h_px"] >= 390:
            text(dr, (X((x0 + x1) / 2.0 * cw), SY(l["top_h_px"]) - 7),
                 "%s %d 第%d排" % (l["def"], l["top_h_px"], l["row"]), 11, ze, "ms")
    for t in plan["walls"]["towers"]:
        tw = t["w_cells"]
        c0 = (0 if t["side"] == "left" else cols - tw) * cw if t["axis"] == "y"             else (t["i_px"] - tw * cw / 2)
        c1 = c0 + tw * cw
        dr.rectangle([X(c0), SY(t["height_px"]), X(c1), SY(0)],
                     fill=TOWER_FILL, outline=(40, 40, 48))
        text(dr, (X((c0 + c1) / 2), SY(t["height_px"]) - 6),
             "%d" % t["height_px"], 10, (60, 60, 68), "ms")
    text(dr, (ox + 4, sy_base + 4),
         "天际线（高度剖面·共用基线；后城墙画作背景轮廓，排深 layering 见平面图）",
         12, (110, 108, 104), "la")

    cy_l, txt_l = crest_label
    tw_l = dr.textlength(txt_l, font=font(12))
    bx = ox + 160
    dr.rectangle([bx - 4, cy_l - 17, bx + 10 + tw_l, cy_l - 2],
                 fill=(252, 248, 244), outline=(216, 140, 120))
    text(dr, (bx, cy_l - 9), txt_l, 12, (176, 44, 30), "lm")

    # ── ③ 图例 + 校验 ───────────────────────────────────────────────────
    ly = sy_base + sl_h + 22
    k = plan["counts"]
    text(dr, (MARGIN, ly), "【%s】%d/%d 格  %d×%dpx  深 %dpx  建筑 %d"
         % (tier, cols, rows, width_px, depth_px, depth_px, len(plan["lots"])),
         16, INK)
    ly += 22
    text(dr, (MARGIN, ly),
         "分区数量 核心 %d / 市场 %d / 工匠 %d / 居住 %d / 生产 %d（§4.2 权重 %s）"
         % (k["core"], k["market"], k["artisan"], k["residential"], k["production"],
            "8/22/22/34/14%"), 13, (80, 78, 74))
    ly += 20
    sk, c = plan["skyline"], plan["checks"]
    text(dr, (MARGIN, ly),
         "① 街宽 %d 格（支路 %s） ② 压路 %d 格/不贴街 %d 栋 ③ 最长连排 %d 栋 / 缝 %d 处 "
         "④ 广场 %s"
         % (c["street_width"]["main_cells"], c["street_width"]["branch_cells"],
            c["setback"]["lot_road_overlap_cells"],
            c["setback"]["lots_without_frontage"], c["alley"]["max_block_run"],
            c["alley"]["alley_count"],
            ("无（hamlet）" if c["plaza"].get("none")
             else "%d×%d 格" % (c["plaza"]["w_cells"], c["plaza"]["h_cells"]))),
         13, (80, 78, 74))
    ly += 20
    text(dr, (MARGIN, ly),
         "⑤ 最高点 %s %dpx（偏移 %d 格，第 %d 排）| 次高 %s %dpx | 塔 %d 座 间距 %s | 塔高极差 %dpx"
         % (sk["tallest"]["def"], sk["tallest"]["top_h_px"],
            sk["tallest_x_offset_cells"], sk["tallest_row"],
            sk["second_highest"]["def"], sk["second_highest"]["top_h_px"],
            len(plan["walls"]["towers"]),
            ",".join(str(g) for g in c["skyline"]["tower_gap_px"]),
            c["skyline"]["tower_height_spread_px"]), 13, (80, 78, 74))
    ly += 20
    col = (176, 40, 30) if c["issues"] else (30, 120, 60)
    text(dr, (MARGIN, ly), "校验：%s%s" % (
        "全部通过" if not c["issues"] else " / ".join(c["issues"]),
        ("   ⚠ " + " / ".join(c["notes"])) if c["notes"] else ""), 12, col)
    ly += 24

    # def 图例（index → def/中文/宽/高/材质）
    seen = {}
    for l in plan["lots"]:
        seen.setdefault(l["def"], l)
    entries = ["%d %s %s w%d h%d" % (l["index"], l["def"], l["def_cn"],
                                     l["w_cells"], l["top_h_px"])
               for l in sorted(seen.values(), key=lambda l: l["index"])]
    entries += ["— wall_seg w1 h%d" % plan["walls"]["height_px"],
                "— gatehouse w%d" % (plan["walls"]["gates"][0]["facade_w_cells"]
                                     if plan["walls"]["gates"] else 0),
                "— tower h%d~%d" % (min([t["height_px"] for t in
                                         plan["walls"]["towers"]] or [0]),
                                    max([t["height_px"] for t in
                                         plan["walls"]["towers"]] or [0]))]
    per_col = (len(entries) + legend_cols - 1) // legend_cols
    for i, e in enumerate(entries):
        cx = MARGIN + (i // per_col) * (CONTENT_W // legend_cols)
        cy = ly + (i % per_col) * legend_row_h
        text(dr, (cx, cy), e, 12, (86, 84, 80))

    # zone 配色图例
    zx = MARGIN
    zy = ly + per_col * legend_row_h + 6
    for z in CL.ZONE_ORDER:
        dr.rectangle([zx, zy, zx + 16, zy + 12], fill=ZONE_FILL[z], outline=ZONE_EDGE[z])
        text(dr, (zx + 20, zy + 6), "%s %s" % (z, CL.ZONE_CN[z]), 12, (70, 68, 64), "lm")
        zx += 20 + int(dr.textlength("%s %s" % (z, CL.ZONE_CN[z]), font=font(12))) + 26
    for lab, f, e in (("道路", ROAD_FILL, ROAD_EDGE), ("广场", PLAZA_FILL, PLAZA_EDGE),
                      ("院坝", YARD_FILL, (150, 180, 140)), ("田地", (228, 208, 132), (190, 172, 96)),
                      ("城墙", WALL_FILL, WALL_EDGE), ("塔楼", TOWER_FILL, (40, 40, 48)),
                      ("城门", GATE_FILL, (40, 40, 48))):
        dr.rectangle([zx, zy, zx + 16, zy + 12], fill=f, outline=e)
        text(dr, (zx + 20, zy + 6), lab, 12, (70, 68, 64), "lm")
        zx += 20 + int(dr.textlength(lab, font=font(12))) + 26
    text(dr, (MARGIN, zy + 20),
         "确定性：tier+seed 固定 → 同布局；seed=%d。数据源 city_layout.plan_city()（纯 Python）。"
         % seed, 11, (130, 128, 124))

    out_path = out_path or os.path.join(OUT_DIR, "city_plan_%s.png" % tier)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    img.save(out_path)
    if write_json:
        with open(out_path.replace(".png", ".json"), "w", encoding="utf-8") as f:
            json.dump(plan, f, ensure_ascii=False, indent=1)
    print("→ %s  (%dx%d, scale %.2f)" % (out_path, img_w, img_h, S))
    return out_path


def row_band_y(plan, rb):
    rows, sw = plan["rows"], plan["params"]["street_w_cells"]
    return (rows - sw - 1) - (rb["b1"] - 1), (rows - sw - 1) - rb["b0"]


def yard_y(plan, yd):
    """yard 的 y 格范围：取该排 band 的 b 范围。"""
    rb = plan["rows_bands"][yd["row"]]
    rows, sw = plan["rows"], plan["params"]["street_w_cells"]
    b0, b1 = rb["b0"], rb["b0"] + rb["depth_cells"]
    return (rows - sw - 1) - (b1 - 1), (rows - sw - 1) - b0


def main():
    which = sys.argv[1:] or ["hamlet", "village", "town", "city"]
    for t in which:
        render(t, seed=PROBE_SEEDS.get(t, 611036))
    print("PLAN_OK ->", OUT_DIR)


if __name__ == "__main__":
    main()
