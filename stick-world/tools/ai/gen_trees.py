# -*- coding: utf-8 -*-
"""程序化树/石/铁矿变体贴图生成 —— 结构直绘透明画布 + 笔触拟合，零抠图零白边。

树结构照搬 Terraria WorldGen.GrowTree 的段堆叠系统（反编译源码实测参数）：
    干 = 7-12 段堆叠，每段随机样式（普通变体/左枝/右枝/双枝），
    枝段防连续同侧（GrowTree flag4/flag5 规则直译）；干顶盖"菜花帽"顶冠
    （主团 + 一圈子团 + 底缘下垂团）；干几乎笔直、粗壮（占树高 7-9%）。
    绿色与树干拉开明度/色相双重对比（叶亮饱和、干深棕）。

与旧管线（白底参考图 → 拟合 → 色距抠图）的根本区别：
    参考图与结构蒙版由同一份结构参数同步产出（蒙版数学精确），
    笔触拟合后蒙版直出 RGBA——不存在抠图，也就不存在白边。

游戏内同一棵树外观稳定：resource_node.gd 以位置哈希为种子选变体/缩放/翻转，
位置随存档持久化 → 读档后同一棵树长得一样。

用法：
    python gen_trees.py            # 全量：树×10 石×6 铁矿×4
    python gen_trees.py tree 3     # 只出 3 个树变体（调试）
输出：assets/resources/{tree,stone,metal}_paint_v{i}.png
中间产物：temp/stroke_ref/（参考图+蒙版，可反复调参重跑）
"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
import stroke_paint  # noqa: E402  (同目录，笔触拟合复用其 paint() 入口)

# 大画布（树 672 高）细笔版分层。笔宽对齐 mona-3 原版参考的画布比例
# （原版 1200 宽画布底笔 12.2/detail 1.6 ≈ 画布宽 1%/0.13%——本项目 384 宽
# 画布按同比例约 3.8/0.5；旧版粗了 2.5-4.5 倍）
# 笔宽严格对齐参考画布比例（1200 宽底笔 12.2/detail 1.6 → 384 宽 = 1%/0.13%）：
# 底笔粗则几千笔互相糊叠，视觉只剩"几百笔粗抹"；detail 阈值放宽防提前收笔
THIN_LAYERS = [
    dict(name="underpainting", ratio=0.18, w0=2.2, w1=1.8, ln=18, alpha=0.98,
         typ="Q", region="full", jit=0.24, mode="walk", p_jump=0.95, csteps=6,
         band_jit=0.28),
    dict(name="body", ratio=0.40, w0=1.6, w1=1.15, ln=10, alpha=0.97,
         typ="Q", region="full", jit=0.20, mode="band", p_end=0.01, csteps=6,
         band_jit=0.22, color_break=True),
    dict(name="detail", ratio=0.36, w0=0.85, w1=0.5, ln=6, alpha=0.90,
         typ="Z", region="full", jit=0.9, mode="scatter", csteps=5,
         refine=True, err_thresh=0.12, color_break=True),
    dict(name="glaze", ratio=0.06, w0=2.0, w1=1.6, ln=22, alpha=0.10,
         typ="Q", region="full", jit=0.5, mode="scatter", csteps=6),
]

OUT_DIR = os.path.normpath(os.path.join(_HERE, "..", "..", "assets", "resources"))
REF_DIR = os.path.normpath(os.path.join(_HERE, "..", "..", "..", "temp", "stroke_ref"))

# ─────────────────── 调色板：叶亮饱和绿 × 干深棕，明度/色相双重拉开 ───────────────────
LEAF_PALETTES = [
    # (受光亮, 中间调, 暗部) 三档一组，每变体随机取一组
    [(158, 196, 92), (108, 162, 66), (70, 118, 48)],
    [(140, 192, 104), (92, 152, 76), (58, 112, 54)],
    [(152, 186, 116), (102, 150, 82), (66, 116, 60)],
    [(172, 196, 96), (122, 164, 72), (82, 126, 54)],
]
TRUNK_COLORS = [(116, 72, 34), (88, 52, 26), (58, 34, 18)]  # 亮/中/暗（红棕，与冠绿强对比）
ROCK_COLORS = [(190, 188, 180), (156, 154, 148), (122, 120, 116), (98, 96, 94)]
MOSS_COLOR = (104, 124, 72)
ORE_COLORS = [(238, 178, 92), (214, 148, 70), (248, 208, 140)]


# ─────────────────────────────── 几何工具 ───────────────────────────────
def np2(v):
    return np.array(v, dtype=np.float64)


# ─────────────────────── 树结构：Terraria 段堆叠系统 ───────────────────────
## 结构参数默认值（= 用户满意版数值；lab 模式可整体覆盖）
DEFAULT_PARAMS = {
    "height_factor": 1.00,
    "bare_frac": 0.13,
    "trunk_frac": 0.60,
    "trunk_w": 0.042,
    "crown_r_coef": 0.52,
    "crown_cap": 0.30,
    "crown_lift": 0.30,
    "hat_n": 8,
    "branch_prob": 0.48,
    "seg_n": 9,
}


def gen_tree_struct(rng, W=384, H=672, P=None):
    """一棵树 = 干段序列（每段样式独立）+ 侧枝 + 顶帽叶团系。P 覆盖 DEFAULT_PARAMS。

    Terraria WorldGen.GrowTree 直译要点：
    - 干段样式随机：普通为主，左枝/右枝段穿插，同侧枝不连续（flag4/flag5）；
    - 干几乎笔直：段接缝 ±6px 渐进偏移（手工感），整体再居中；
    - 顶帽：主团 + 帽圈子团（菜花轮廓）+ 底缘下垂团。
    """
    P = dict(DEFAULT_PARAMS) if P is None else {**DEFAULT_PARAMS, **P}
    ground_y = H - 12.0
    usable_h = (ground_y - 14.0) * float(P["height_factor"])
    # 底部延长裸干（后处理追加，不参与枝判定）
    bare_h = usable_h * rng.uniform(float(P["bare_frac"]) * 0.62, float(P["bare_frac"]) * 1.38)
    # 枝叶区：枝干占枝叶区 trunk_frac ±0.06，冠占余下
    leaf_zone = usable_h - bare_h
    trunk_h = leaf_zone * rng.uniform(float(P["trunk_frac"]) - 0.06, float(P["trunk_frac"]) + 0.06)
    n_seg = int(P["seg_n"])
    seg_h = trunk_h / n_seg
    leaf_ground = ground_y - bare_h  # 枝叶树立于裸干顶之上
    # 干宽 ≈ 树高的 3.6%-4.8%（Terraria 比例：干 16px/树 350px ≈ 4.6%）
    w_base = H * rng.uniform(float(P["trunk_w"]) - 0.006, float(P["trunk_w"]) + 0.006)
    w_top = w_base * rng.uniform(0.60, 0.78)

    # 干中线：段接缝渐进偏移（几乎直），整体居中
    xs = [W * 0.5 + rng.uniform(-8.0, 8.0)]
    for _ in range(n_seg):
        xs.append(xs[-1] + rng.uniform(-6.0, 6.0))
    cx_mean = sum(xs) / len(xs)
    xs = [x - (cx_mean - W * 0.5) for x in xs]

    # 枝叶干段（认可版原样：首末段强制普通，中间段按样式池出枝）
    segs = []
    last_l = last_r = False
    for i in range(n_seg):
        y_top = leaf_ground - (i + 1) * seg_h
        y_bot = leaf_ground - i * seg_h
        f = (i + 0.5) / n_seg  # 0 底部 → 1 顶部
        w = w_base + (w_top - w_base) * f
        if i == 0 or i == n_seg - 1:
            style = "plain"  # 首末段强制普通（GrowTree 同款约束）
        else:
            bp = float(P["branch_prob"])
            r = rng.random()
            can_l = not last_l
            can_r = not last_r
            if r < (1.0 - 2.0 * bp) or (not can_l and not can_r):
                style = "plain"
            elif can_l and (r < (1.0 - bp) or not can_r):
                style = "left"
            elif can_r:
                style = "right"
            else:
                style = "plain"
        last_l = style == "left"
        last_r = style == "right"
        segs.append({"xc": (xs[i] + xs[i + 1]) * 0.5, "y_top": y_top, "y_bot": y_bot,
                     "w": w, "style": style})

    # 底部裸干延长段（2-4 段 plain，宽度接续 w_base，无任何枝）
    n_bare = int(rng.integers(2, 5))
    bare_seg_h = bare_h / n_bare
    for j in range(n_bare):
        segs.insert(0, {"xc": xs[0], "y_top": ground_y - (j + 1) * bare_seg_h,
                        "y_bot": ground_y - j * bare_seg_h, "w": w_base + 2.0,
                        "style": "plain"})

    # 侧枝：从枝段侧面伸出，短、斜上（Terraria 分叉段贴图的手绘等效）
    branches = []
    for i, s in enumerate(segs):
        if s["style"] not in ("left", "right"):
            continue
        if rng.random() < 0.25:  # 枝段不一定全长枝（样式池里普通变体占多数的等效）
            continue
        side = -1.0 if s["style"] == "left" else 1.0
        oy = s["y_bot"] - seg_h * rng.uniform(0.3, 0.7)
        length = w_base * rng.uniform(2.2, 3.4)
        ang = np.deg2rad(rng.uniform(28.0, 52.0))
        origin = np2((s["xc"] + side * s["w"] * 0.45, oy))
        # 侧向只作用于 x 分量——side 乘整向量会把 y 也翻转成朝下（180°旋转对称 bug）
        tip = origin + length * np2((side * np.sin(ang), -np.cos(ang)))
        ctrl = origin + length * 0.5 * np2((side * np.sin(ang) * 0.4, -1.0))
        t = np.linspace(0, 1, 10)[:, None]
        path = ((1 - t) ** 2) * origin + 2 * (1 - t) * t * ctrl + (t ** 2) * tip
        branches.append({"path": [tuple(p) for p in path],
                         "w0": w_base * 0.62, "w1": w_base * 0.36, "tip": tuple(tip)})

    # 顶帽：主团 + 帽圈子团（菜花轮廓）+ 底缘下垂团（GrowTree 顶帽占 4-6 格的等效）
    crown_h = leaf_zone - trunk_h
    r_main = min(crown_h * float(P["crown_r_coef"]), W * float(P["crown_cap"]))
    cy = leaf_ground - trunk_h - r_main * float(P["crown_lift"])
    trunk_top_x = xs[-1]
    blobs = [{"c": (trunk_top_x, cy), "r": r_main}]
    n_hat = max(3, int(P["hat_n"]) + int(rng.integers(-2, 3)))
    for k in range(n_hat):
        a = k / n_hat * np.pi * 2 + rng.uniform(-0.22, 0.22)
        d = r_main * rng.uniform(0.68, 1.0)
        blobs.append({"c": (trunk_top_x + d * np.cos(a), cy + d * np.sin(a) * 0.85),
                      "r": r_main * rng.uniform(0.38, 0.58)})
    for _ in range(int(rng.integers(2, 4))):  # 底缘下垂团（帽沿不齐）
        a = np.pi + rng.uniform(-0.6, 0.6)
        d = r_main * rng.uniform(0.8, 1.0)
        by = cy + d * np.sin(a) * 0.8
        # 团底不沉过地面线（否则 fit 以团底贴地、干被抬高悬空）
        by = min(by, ground_y - r_main * 0.45 * 0.8)
        blobs.append({"c": (trunk_top_x + d * np.cos(a), by),
                      "r": r_main * rng.uniform(0.30, 0.45)})
    for br in branches:  # 枝端小团
        blobs.append({"c": (br["tip"][0], br["tip"][1] - 4.0),
                      "r": r_main * rng.uniform(0.26, 0.4)})
    # 每团子斑：主圆 + 2-3 个错位小圆 → 蓬松轮廓
    for b in blobs:
        b["sub"] = [
            (b["c"][0] + rng.uniform(-0.5, 0.5) * b["r"],
             b["c"][1] + rng.uniform(-0.45, 0.45) * b["r"],
             b["r"] * rng.uniform(0.45, 0.65))
            for _ in range(rng.integers(2, 4))
        ]

    palette = LEAF_PALETTES[rng.integers(0, len(LEAF_PALETTES))]
    s = {"segs": segs, "branches": branches, "blobs": blobs,
         "palette": palette, "ground_y": ground_y, "w_base": w_base}
    _fit_tree_to_canvas(s, W, H)
    return s


def _fit_tree_to_canvas(s, W, H):
    """整体适配：求结构包围盒，超画布（留 4px 边距）则等比缩放 + 平移进来。"""
    xs, ys = [], []
    for seg in s["segs"]:
        xs += [seg["xc"] - seg["w"] / 2, seg["xc"] + seg["w"] / 2]
        ys += [seg["y_top"], seg["y_bot"]]
    for br in s["branches"]:
        xs += [p[0] for p in br["path"]]
        ys += [p[1] for p in br["path"]]
    for b in s["blobs"]:
        xs += [b["c"][0] - b["r"], b["c"][0] + b["r"]]
        ys += [b["c"][1] - b["r"], b["c"][1] + b["r"]]
        for (sx, sy, sr) in b["sub"]:
            xs += [sx - sr, sx + sr]
            ys += [sy - sr, sy + sr]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    margin, top_pad = 4.0, 8.0
    k = min(1.0, (W - 2 * margin) / max(x1 - x0, 1.0),
            (s["ground_y"] - top_pad) / max(y1 - y0, 1.0))
    dx = (W / 2.0) - (x0 + x1) / 2.0
    dy = s["ground_y"] - y1 * k  # 底边贴地

    def xf(p):
        return (p[0] * k + dx, p[1] * k + dy)

    for seg in s["segs"]:
        seg["xc"] = seg["xc"] * k + dx
        seg["y_top"] = seg["y_top"] * k + dy
        seg["y_bot"] = seg["y_bot"] * k + dy
        seg["w"] *= k
    for br in s["branches"]:
        br["path"] = [xf(p) for p in br["path"]]
        br["w0"] *= k
        br["w1"] *= k
    for b in s["blobs"]:
        b["c"] = xf(b["c"])
        b["r"] *= k
        b["sub"] = [(sx * k + dx, sy * k + dy, sr * k) for (sx, sy, sr) in b["sub"]]
    s["w_base"] *= k


def render_crown_ref(s, W, H):
    """冠区参考图：背景=冠主绿，叶团受光 dome（光心偏左上）。冠区单独拟合 →
    笔触只见过绿色，物理上不可能出现棕绿混色。"""
    light, mid, dark = s["palette"]
    arr = np.full((H, W, 3), tuple(int(c) for c in mid), dtype=np.float32)
    yy, xx = np.mgrid[0:H, 0:W]
    order = sorted(range(len(s["blobs"])), key=lambda i: s["blobs"][i]["c"][1], reverse=True)
    for bi in order:
        b = s["blobs"][bi]
        cx, cy = b["c"]
        for (sx, sy, sr) in [(cx, cy, b["r"])] + b["sub"]:
            lx, ly = sx - sr * 0.30, sy - sr * 0.34
            d = np.sqrt((xx - lx) ** 2 + (yy - ly) ** 2) / max(sr, 1.0)
            dome = np.clip(1.0 - (d - 0.55) / 0.5, 0.0, 1.0)
            vshade = (0.82 + 0.10 * (1.0 - (yy - sy) / max(sr, 1.0)))[..., None]
            base = np.asarray(mid, np.float32)[None, None, :] * vshade
            col = base * (0.78 + 0.55 * dome)[..., None]
            col = np.clip(col + (dome > 0.75)[..., None] * (np.asarray(light, np.float32) - base) * 0.45, 0, 255)
            col = np.clip(col + (dome < 0.18)[..., None] * (np.asarray(dark, np.float32) - base) * 0.55, 0, 255)
            inside = d < 1.35
            arr[inside] = arr[inside] * 0.25 + col[inside] * 0.75
    # 带色噪声（绿系扰动）：灰白噪声会被 detail 层拟合出灰笔（叶团露灰的根因）
    noise = np.random.default_rng(7).normal(0.0, 8.0, (H, W, 1)).repeat(3, axis=2) \
        * np.asarray([0.95, 1.25, 0.85], np.float32)[None, None, :]
    return Image.fromarray(np.clip(arr + noise, 0, 255).astype(np.uint8))


def render_trunk_ref(s, W, H):
    """干区参考图：背景=干棕，干段描边+棕面+高光+接缝环+木纹、枝干。
    干区单独拟合 → 笔触只见过棕色，绿笔永不入干。"""
    t_mid = np.asarray(TRUNK_COLORS[1], np.float32)
    t_dark = np.asarray(TRUNK_COLORS[2], np.float32)
    arr = np.full((H, W, 3), tuple(int(c) for c in TRUNK_COLORS[1]), dtype=np.float32)
    # 带色噪声（棕系扰动，防灰笔）
    noise = np.random.default_rng(3).normal(0.0, 7.0, (H, W, 1)).repeat(3, axis=2) \
        * np.asarray([1.2, 0.9, 0.65], np.float32)[None, None, :]
    ref = Image.fromarray(np.clip(arr + noise, 0, 255).astype(np.uint8))
    draw = ImageDraw.Draw(ref)
    for i, seg in enumerate(s["segs"]):
        x0, x1 = seg["xc"] - seg["w"] / 2, seg["xc"] + seg["w"] / 2
        f = i / max(len(s["segs"]) - 1, 1)
        draw.rectangle([x0, seg["y_top"], x1, seg["y_bot"]],
                       fill=tuple(int(c) for c in t_dark))
        ins = seg["w"] * 0.15
        col = np.clip(t_mid * (1.10 - f * 0.16), 0, 255).astype(np.uint8)
        draw.rectangle([x0 + ins, seg["y_top"], x1 - ins, seg["y_bot"]],
                       fill=tuple(int(c) for c in col))
        hl = np.clip(np.asarray(TRUNK_COLORS[0], np.float32) * 1.05, 0, 255).astype(np.uint8)
        draw.rectangle([x0 + ins, seg["y_top"], x0 + ins + seg["w"] * 0.18, seg["y_bot"]],
                       fill=tuple(int(c) for c in hl))
        if i > 0:
            draw.rectangle([x0, seg["y_bot"] - 2.5, x1, seg["y_bot"]],
                           fill=tuple(int(c) for c in (t_dark * 0.8)))
        for fx in (0.42, 0.68):
            mx = x0 + (x1 - x0) * fx
            draw.rectangle([mx, seg["y_top"], mx + 2.0, seg["y_bot"]],
                           fill=tuple(int(c) for c in (t_mid * 0.78)))
    for br in s["branches"]:
        m = len(br["path"])
        for i in range(m - 1):
            f = i / max(m - 2, 1)
            w = br["w0"] + (br["w1"] - br["w0"]) * f
            col = np.clip(t_mid * (0.85 - f * 0.15), 0, 255).astype(np.uint8)
            draw.line([br["path"][i], br["path"][i + 1]], fill=tuple(int(c) for c in col),
                      width=max(2, int(round(w))), joint="curve")
    return ref


def render_crown_mask(s, W, H):
    # 硬蒙版（无羽化无渐变）：只做笔触级判定——笔中心在内整笔保留、在外整笔丢弃。
    # 团间空隙也是"内部"：在团圆并集上再填一个整体椭圆（帽形），保证冠内部
    # 笔触密实无缝隙；缝隙只允许出现在最外缘（整笔被删自然产生）
    m = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(m)
    xs, ys = [], []
    for b in s["blobs"]:
        cx, cy, r = b["c"][0], b["c"][1], b["r"]
        for (sx, sy, sr) in [(cx, cy, r)] + b["sub"]:
            d.ellipse([sx - sr, sy - sr, sx + sr, sy + sr], fill=255)
            xs += [sx - sr, sx + sr]
            ys += [sy - sr, sy + sr]
    if xs:
        ex0, ex1, ey0, ey1 = min(xs), max(xs), min(ys), max(ys)
        cx, cy = (ex0 + ex1) / 2.0, (ey0 + ey1) / 2.0
        rx, ry = (ex1 - ex0) * 0.47, (ey1 - ey0) * 0.47
        d.ellipse([cx - rx, cy - ry, cx + rx, cy + ry], fill=255)
    return m


def render_trunk_mask(s, W, H):
    m = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(m)
    for seg in s["segs"]:
        x0, x1 = seg["xc"] - seg["w"] / 2, seg["xc"] + seg["w"] / 2
        d.rectangle([x0, seg["y_top"], x1, seg["y_bot"]], fill=255)
    for br in s["branches"]:
        m2 = len(br["path"])
        for i in range(m2 - 1):
            f = i / max(m2 - 2, 1)
            w = br["w0"] + (br["w1"] - br["w0"]) * f
            d.line([br["path"][i], br["path"][i + 1]], fill=255,
                   width=int(round(w)) + 2, joint="curve")
    return m


def paint_branches_on(trunk_img: Image.Image, s) -> None:
    """枝：程序化圆头笔直接绘制。笔触原子拟合的流场沿主干竖直走向，
    斜向细枝条带内几乎不会有笔中心落入——枝会被笔级判定整体过滤消失；
    因此枝不参与拟合，直接以圆头笔序列（线段+两端圆帽，同 stamp_canvas 手法）
    画在干图上：保证可见、风格与拟合笔触一致、alpha 恒为硬边。"""
    t_mid = TRUNK_COLORS[1]
    d = ImageDraw.Draw(trunk_img)
    for br in s["branches"]:
        path = br["path"]
        m = len(path)
        for i in range(m - 1):
            f = i / max(m - 2, 1)
            w = br["w0"] + (br["w1"] - br["w0"]) * f
            col = tuple(int(c * (0.92 - f * 0.12)) for c in t_mid) + (255,)
            d.line([path[i], path[i + 1]], fill=col, width=max(2, int(round(w))))
            r = w / 2.0
            for p in (path[i], path[i + 1]):
                d.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=col)


def _alpha_over(bottom: Image.Image, top: Image.Image) -> Image.Image:
    """标准 alpha-over 合成：冠（top）盖干（bottom）。"""
    b = np.asarray(bottom).astype(np.float32)
    t = np.asarray(top).astype(np.float32)
    ab = b[..., 3:4] / 255.0
    at = t[..., 3:4] / 255.0
    ao = at + ab * (1.0 - at)
    rgb = (t[..., :3] * at + b[..., :3] * ab * (1.0 - at)) / np.maximum(ao, 1e-4)
    return Image.fromarray(np.dstack([rgb, ao * 255.0]).astype(np.uint8), "RGBA")


# ─────────────────────────────── 石头 / 铁矿 ───────────────────────────────
def gen_rock_struct(rng, W=224, H=176, ore=False):
    """岩石轮廓：极坐标随机半径（低频起伏 + 平滑），圆心略偏上（底面接地平）。"""
    cy = H * 0.62
    cx = W * 0.5 + rng.uniform(-8.0, 8.0)
    r_base = min(W, H) * rng.uniform(0.32, 0.42)
    n_v = int(rng.integers(7, 10))
    angs = np.sort(rng.uniform(0, np.pi * 2, n_v))
    raw = rng.uniform(0.72, 1.18, n_v)
    ker = np.array([0.25, 0.5, 0.25])
    for _ in range(2):
        raw = np.convolve(np.r_[raw[-1], raw, raw[0]], ker, "valid")
    verts = [(cx + r_base * raw[i] * np.cos(a), cy + r_base * raw[i] * np.sin(a) * 0.82)
             for i, a in enumerate(angs)]
    ground = H - 6.0
    verts = [(x, min(y, ground - 1.0)) for (x, y) in verts]
    cracks = []
    for _ in range(int(rng.integers(2, 4))):
        a0 = rng.uniform(0, np.pi * 2)
        p = np2((cx, cy))
        seg = [tuple(p)]
        for _ in range(int(rng.integers(3, 5))):
            p = p + r_base * rng.uniform(0.16, 0.3) * np2((np.cos(a0), np.sin(a0)))
            a0 += rng.uniform(-0.7, 0.7)
            seg.append(tuple(p))
        cracks.append(seg)
    moss = []
    for _ in range(int(rng.integers(2, 5))):
        a = rng.uniform(np.pi * 0.15, np.pi * 0.85)
        mp = (cx + r_base * 0.8 * np.cos(a), cy + r_base * 0.8 * np.sin(a) * 0.8)
        moss.append((mp[0], min(mp[1], ground - 3.0), rng.uniform(8.0, 17.0)))
    ore_bits = []
    if ore:
        for _ in range(int(rng.integers(4, 7))):
            a = rng.uniform(0, np.pi * 2)
            d = rng.uniform(0.2, 0.75)
            op = (cx + r_base * d * np.cos(a), cy + r_base * d * np.sin(a) * 0.8)
            ore_bits.append((op[0], op[1], rng.uniform(3.5, 7.5)))
    return {"verts": verts, "cx": cx, "cy": cy, "r": r_base, "cracks": cracks,
            "moss": moss, "ore": ore_bits, "ground": ground, "is_ore": ore}


def render_rock_ref(s, W, H):
    top, mid, dark, deep = (tuple(c) for c in ROCK_COLORS)
    img = Image.new("RGB", (W, H), mid)
    arr = np.asarray(img).astype(np.float32)
    yy, xx = np.mgrid[0:H, 0:W]
    t = ((s["cy"] - yy) / max(s["r"] * 2, 1) + (s["cx"] - xx) / max(s["r"] * 4, 1))
    shade = np.clip(0.5 + t * 0.9, 0.0, 1.0)
    col = np.asarray(mid, np.float32)[None, None, :] * (0.72 + 0.55 * shade[..., None])
    arr[:] = np.clip(col, 0, 255)
    noise = np.random.default_rng(11).normal(0.0, 8.0, (H, W, 1)).repeat(3, axis=2)
    ref = Image.fromarray(np.clip(arr + noise, 0, 255).astype(np.uint8))
    d = ImageDraw.Draw(ref)
    d.polygon(s["verts"], fill=None, outline=tuple(int(c) for c in dark), width=2)
    for seg in s["cracks"]:
        d.line(seg, fill=tuple(int(c) for c in deep), width=2, joint="curve")
    for (mx, my, mr) in s["moss"]:
        d.ellipse([mx - mr, my - mr * 0.7, mx + mr, my + mr * 0.7],
                  fill=tuple(int(c) for c in MOSS_COLOR))
    if s["is_ore"]:
        for (ox, oy, orr) in s["ore"]:
            bright, base, dim = (tuple(c) for c in ORE_COLORS)
            d.ellipse([ox - orr, oy - orr, ox + orr, oy + orr], fill=base)
            d.ellipse([ox - orr * 0.45, oy - orr * 0.55, ox + orr * 0.2, oy + orr * 0.1],
                      fill=bright)
    return ref


def render_rock_mask(s, W, H):
    m = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(m)
    d.polygon(s["verts"], fill=255)
    return m


# ─────────────────────────────── 批量生成 ───────────────────────────────
def build(kind, idx, rng):
    if kind == "tree":
        W, H = 384, 672
        s = gen_tree_struct(rng, W, H)
        # 分区域拟合：干、冠各自单独跑笔触（干只见过棕、冠只见过绿——
        # 全画布拟合时长笔横穿导致的干绿混色从机制上消除），再 alpha-over 合成
        trunk_ref = os.path.join(REF_DIR, f"tree_v{idx}_trunk_ref.png")
        trunk_mask = os.path.join(REF_DIR, f"tree_v{idx}_trunk_mask.png")
        crown_ref = os.path.join(REF_DIR, f"tree_v{idx}_crown_ref.png")
        crown_mask = os.path.join(REF_DIR, f"tree_v{idx}_crown_mask.png")
        render_trunk_ref(s, W, H).save(trunk_ref)
        render_trunk_mask(s, W, H).save(trunk_mask)
        render_crown_ref(s, W, H).save(crown_ref)
        render_crown_mask(s, W, H).save(crown_mask)
        trunk_png = os.path.join(REF_DIR, f"tree_v{idx}_trunk.png")
        crown_png = os.path.join(REF_DIR, f"tree_v{idx}_crown.png")
        stroke_paint.paint(trunk_ref, trunk_png, 1800, trunk_mask, size=(W, H),
                           bg=tuple(float(c) for c in TRUNK_COLORS[1]), layers=THIN_LAYERS)
        # 流场螺旋注入（mona-3 spirals）：每个叶团中心一个绕圈切向场，
        # 笔触沿团弧线组织排列（手绘树冠的环形笔触感），横穿团缘的笔大幅减少
        crown_spirals = [(b["c"][0], b["c"][1], b["r"] * 1.30, 0.55)
                         for b in s["blobs"]]
        stroke_paint.paint(crown_ref, crown_png, 3600, crown_mask, size=(W, H),
                           bg=tuple(float(c) for c in s["palette"][1]), layers=THIN_LAYERS,
                           spirals=crown_spirals)
        trunk_img = Image.open(trunk_png).convert("RGBA")
        paint_branches_on(trunk_img, s)
        _alpha_over(trunk_img, Image.open(crown_png)).save(
            os.path.join(OUT_DIR, f"tree_paint_tree_v{idx}.png"))
        return os.path.join(OUT_DIR, f"tree_paint_tree_v{idx}.png")
    elif kind == "stone":
        W, H = 224, 176
        s = gen_rock_struct(rng, W, H, ore=False)
        ref, mask = render_rock_ref(s, W, H), render_rock_mask(s, W, H)
        bg = tuple(float(c) for c in ROCK_COLORS[1])
        strokes = 1100
    else:  # metal
        W, H = 224, 176
        s = gen_rock_struct(rng, W, H, ore=True)
        ref, mask = render_rock_ref(s, W, H), render_rock_mask(s, W, H)
        bg = tuple(float(c) for c in ROCK_COLORS[1])
        strokes = 1200
    stem = f"{kind}_v{idx}"
    ref_p = os.path.join(REF_DIR, f"{stem}_ref.png")
    mask_p = os.path.join(REF_DIR, f"{stem}_mask.png")
    ref.save(ref_p)
    mask.save(mask_p)
    dst = os.path.join(OUT_DIR, f"{kind}_paint_{stem}.png")
    stroke_paint.paint(ref_p, dst, strokes, mask_p, size=(W, H), bg=bg,
                       layers=THIN_LAYERS)
    return dst


# ─────────────────────────────── lab 模式：单棵 + 管线全程可视化 ───────────────────────────────
def run_lab(params_path: str) -> None:
    """读参数 JSON → 生成 1 棵（固定种子）→ 输出管线全阶段拼图 + 成品到
    temp/stroke_ref/lab/（stages.png 全家福、final.png 成品、done.json 完成标记）。"""
    import json
    with open(params_path, encoding="utf-8") as f:
        P = json.load(f)
    lab_dir = os.path.join(REF_DIR, "lab")
    os.makedirs(lab_dir, exist_ok=True)
    W, H = 384, 672
    rng = np.random.default_rng(4242)
    s = gen_tree_struct(rng, W, H, P=P)
    trunk_ref = os.path.join(lab_dir, "t_ref.png")
    trunk_mask = os.path.join(lab_dir, "t_mask.png")
    crown_ref = os.path.join(lab_dir, "c_ref.png")
    crown_mask = os.path.join(lab_dir, "c_mask.png")
    render_trunk_ref(s, W, H).save(trunk_ref)
    render_trunk_mask(s, W, H).save(trunk_mask)
    render_crown_ref(s, W, H).save(crown_ref)
    render_crown_mask(s, W, H).save(crown_mask)
    trunk_png = os.path.join(lab_dir, "t_fitted.png")
    crown_png = os.path.join(lab_dir, "c_fitted.png")
    stroke_paint.paint(trunk_ref, trunk_png, 700, trunk_mask, size=(W, H),
                       bg=tuple(float(c) for c in TRUNK_COLORS[1]), layers=THIN_LAYERS)
    crown_spirals = [(b["c"][0], b["c"][1], b["r"] * 1.30, 0.55) for b in s["blobs"]]
    stroke_paint.paint(crown_ref, crown_png, 1600, crown_mask, size=(W, H),
                       bg=tuple(float(c) for c in s["palette"][1]), layers=THIN_LAYERS,
                       spirals=crown_spirals)
    trunk_img = Image.open(trunk_png).convert("RGBA")
    trunk_no_branch = trunk_img.copy()
    paint_branches_on(trunk_img, s)
    final = _alpha_over(trunk_img, Image.open(crown_png).convert("RGBA"))
    final.save(os.path.join(lab_dir, "final.png"))

    stages = [
        ("1 trunk ref", Image.open(trunk_ref)),
        ("2 trunk mask", Image.open(trunk_mask).convert("RGB")),
        ("3 trunk fitted", trunk_no_branch),
        ("4 branches drawn", trunk_img),
        ("5 crown ref", Image.open(crown_ref)),
        ("6 crown mask", Image.open(crown_mask).convert("RGB")),
        ("7 crown fitted", Image.open(crown_png).convert("RGBA")),
        ("8 FINAL", final),
    ]
    cell_w = 200
    cells = []
    for label, im in stages:
        im = im.convert("RGBA")
        im = im.resize((cell_w, int(im.height * cell_w / im.width)))
        bg = Image.new("RGBA", im.size, (26, 26, 32, 255))
        bg.alpha_composite(im)
        cells.append((label, bg.convert("RGB")))
    sh = max(c[1].height for c in cells) + 26
    sw = sum(c[1].width for c in cells) + 10 * (len(cells) + 1)
    strip = Image.new("RGB", (sw, sh), (16, 16, 20))
    d = ImageDraw.Draw(strip)
    x = 10
    for label, c in cells:
        strip.paste(c, (x, 22))
        d.text((x + 2, 5), label, fill=(225, 225, 230))
        x += c.width + 10
    strip.save(os.path.join(lab_dir, "stages.png"))
    with open(os.path.join(lab_dir, "done.json"), "w", encoding="utf-8") as f:
        json.dump({"ok": True, "seed": 4242, "params": P}, f, ensure_ascii=False, indent=1)
    print("[lab] 完成 →", lab_dir)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(REF_DIR, exist_ok=True)
    if len(sys.argv) >= 3 and sys.argv[1] == "--lab":
        run_lab(sys.argv[2])
        return
    jobs = []
    if len(sys.argv) >= 3 and sys.argv[1] in ("tree", "stone", "metal"):
        jobs = [(sys.argv[1], int(sys.argv[2]))]
    else:
        jobs = [("tree", 10), ("stone", 6), ("metal", 4)]
    for kind, count in jobs:
        for i in range(count):
            # 固定种子（hash() 有进程随机化，不可用作变体种子）：同版本工具重跑结果一致
            rng = np.random.default_rng(1000 * KIND_OFFSET[kind] + i)
            build(kind, i, rng)
    print("[gen] 全部完成 →", OUT_DIR)


KIND_OFFSET = {"tree": 7, "stone": 31, "metal": 97}


if __name__ == "__main__":
    main()
