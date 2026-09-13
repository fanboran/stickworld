# -*- coding: utf-8 -*-
"""ground_transitions.py —— 手工预制过渡件库（建筑管线 v3 · 地面体系）

为什么单独一套
--------------
创始人两次纠正：材质之间的过渡**要手工制作的预制块**（红警的 auto-shore 海岸块 /
泰拉瑞亚的 blob 边块那一路），不是"程序噪声算出来的渐变"。所以本文件里：

* **边界形状是手写的关键点折线**（`MASTERS[...][i]["kp"]`）——不对称、犬牙交错，
  一段一段直线连起来，像画师勾的边，不是 `sin` / 噪声函数拟的。
* **缝里的每颗石子 / 草簇 / 碎砖逐个显式摆放**（`MASTERS[...][i]["els"]`）——
  每一条都写死：`dx`（相对该行边界的横向偏移）、`y`（整幅里的绝对纵坐标）、
  尺寸、转角、明度。**没有任何一处用噪声决定位置**。
* 两侧材质直接调 `ground_tiles` 的平铺生成器（与分段集同源），
  所以石板还是石板、草皮还是草皮，一眼可辨；铺法也是引擎的铺法（128px 游戏档
  × 显式指定的变体序列），件级不引入新的材质定义。
* 与既有 `tr_*`（`ground_tiles.t_transition`：边界来自 `gwh` 噪声）**并存**：
  那三个是"带内噪声咬合"，本库是"手工预制件"，用途不同（见
  `docs/技术/架构/建筑管线v3-地面体系.md` §三 新旧过渡段 / §五 预制过渡块）。

画幅与分带（为什么是"整幅 264 再切三带"）
------------------------------------------
地面纵向是一条连续的带子：路肩 96 + 路缘 8 + 道路 160 = **264px**（`ground_tiles`
同一口径）。手工边界**在一整幅 264px 上画一次**（折线与摆件的 y 都是整幅坐标），
然后按带**裁剪**出件：道路带 = 整幅 y∈[0,160)、路肩带 = y∈[168,264)。
于是把"路肩件 + 路缘 + 道路件"上下摞起来，边界与摆件**自然连成一条**——
这正是红警式预制块的做法（同一张手绘边切成 tile），而不是每带各画一遍。

* 路缘带（8px）不单出件：10.5cm 的缘石条上做材质过渡看不出名堂，
  过渡由道路件 + 路肩件两头夹住（json 里写清）。
* 摆件被裁到件外是**对的**：被裁掉的那半在相邻带的那一件里，摞起来才是完整一颗。

一件的规格：16 格宽（512px = 与分段集同口径）× 所属带高；左 = 材质 A、右 = 材质 B。

产物（`stick-world/temp/ground_tiles/transitions/`）
    src/<key>_alb.png / _nrm.png / _rgh.png    反照率（sRGB）/ 法线 / 粗糙度
    <key>.json                                  契约（材质对 / 左右约定 / 变体号 / 摆件数）
    _manifest.json                              件清单
成图见 `probe_transitions.py` → `pbr_ground_transitions.png`（全件 + 两侧分段拼接对照）。

跑法::
    blender -b --factory-startup -P ground_transitions.py
"""

import json
import math
import os
import re
import sys
import types

import numpy as np

import bpy

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)


def load_ground_tiles():
    """只读载入 `ground_tiles`。

    它由**另一个 agent 并行修改**，编辑到一半会出现"模块级常量写在使用之后"这种瞬时
    NameError（例：`b_kerb(..., gap=KERB_GAP_BAND)` 而常量还在文件后面）。这时把该文件
    **自己写的**数字常量先注入命名空间再 exec —— 不改它的任何文件，只补定义顺序；
    正常导入能过就正常导入。真语法错误（改了一半）不掩盖，原样抛出。
    """
    mod = sys.modules.get("ground_tiles")
    if mod is not None:
        return mod
    try:
        import ground_tiles as g
        return g
    except NameError:
        path = os.path.join(HERE, "ground_tiles.py")
        with open(path, encoding="utf-8") as fh:
            src = fh.read()
        ns = {"__name__": "ground_tiles", "__file__": path}
        pat = r"(?m)^([A-Z][A-Z0-9_]*)\s*=\s*([0-9]+(?:\.[0-9]*)?)\s*(?:#.*)?$"
        for m in re.finditer(pat, src):
            ns.setdefault(m.group(1), float(m.group(2)))
        mod = types.ModuleType("ground_tiles")
        mod.__dict__.update(ns)
        exec(compile(src, path, "exec"), mod.__dict__)
        sys.modules["ground_tiles"] = mod
        print("[loader] ground_tiles 以「常量前置」方式载入（兼容另一 agent 编辑中的定义顺序）")
        return mod


G = load_ground_tiles()          # 只读：借平铺生成器 / 分带尺寸 / 收口与落盘工具

#: 1 格 = 32px（与 ground_tiles.CELL 同源）
CELL = G.CELL
#: 件宽 = 16 格 = 512px（与分段集 seg_* 同口径）
GAME_W = 512
#: 整幅高 = 路肩 96 + 路缘 8 + 道路 160（地面纵向连续带）
CHART_H = G.STRIP_SHOULDER + G.STRIP_KERB + G.STRIP_ROAD
#: 内部超采样倍率（落盘前箱式降采样，边界毛刺才干净）
RASTER = 2
#: 每个带在哪一段（整幅坐标，y 从道路带底边起算；数组第 0 行 = 图片底部）
BANDS = {
    "road": (0, G.STRIP_ROAD),                                    # y 0..159
    "shoulder": (G.STRIP_ROAD + G.STRIP_KERB, CHART_H),           # y 168..263
}
#: 件级起伏（米）：与分段集同口径
RELIEF_M = 0.030
#: 主料层的基准高度与摆件可用的剩余高度
H_BASE = 0.42
H_MAT = 0.34


# ============================================================ 材质：128px 游戏档平铺
_TILE = {}


def tile(key, variant=0, raster=RASTER):
    """取一张平铺贴图（游戏档 128px → raster 倍密度）。与分段集同一批生成器。"""
    k = (key, variant, raster)
    if k not in _TILE:
        _TILE[k] = G.generate(key, 128 * raster, variant=int(variant))
    return _TILE[k]


def _column(key, variant, rows, tpx, raster, pad=0):
    """一列（1 格宽 = 128×raster px）纵向按同一变体铺。

    纵向：同变体重复 → 周期函数 → 无缝。横向：左右各多铺 `pad` px 的**周期延拓**
    （同一张周期贴图的下一个循环），供列边界的十字淡接取用。
    """
    d = tile(key, variant, raster)
    width = tpx + 2 * pad
    idx = np.mod(np.arange(width) - pad, tpx)
    alb = np.zeros((rows * tpx, width, 3), dtype=np.float64)
    hh = np.zeros((rows * tpx, width), dtype=np.float64)
    rr = np.ones((rows * tpx, width), dtype=np.float64)
    for j in range(rows):
        sl = slice(j * tpx, (j + 1) * tpx)
        alb[sl] = d["alb"][:tpx][:, idx]
        hh[sl] = d["h"][:tpx][:, idx]
        rr[sl] = d["rough"][:tpx][:, idx]
    return alb, hh, rr


def mosaic(key, w, h, seq, raster=RASTER, fade=20):
    """按**显式给定的变体序列**把平铺贴图铺成 w×h。

    `seq` 是人写的（哪一格用哪个相位由人定），不是随机撒。同一变体纵向重复天然无缝；
    **列与列之间**换变体则会在 128px 处留下一条低频色阶（实测看得见），所以在列边界
    按 `fade`（游戏 px，人定）把左右两列各自的**周期延拓**十字淡接 —— 两边是同一材质、
    同一特征尺度，读起来是"这一带斑驳换了"，不是一条硬缝。
    `fade=0` 用于必须逐像素周期连续的材料（木栈道：板色与钉子会重影）。
    """
    tpx = 128 * raster
    cols = int(math.ceil(w / float(tpx)))
    rows = int(math.ceil(h / float(tpx)))
    n = max(1, len(seq))
    colv = [seq[i % n] for i in range(cols)]
    fw = int(fade * raster)
    half = max(1, fw // 2)
    cans = [_column(key, v, rows, tpx, raster, half) for v in colv]
    alb = np.zeros((rows * tpx, cols * tpx, 3), dtype=np.float64)
    hh = np.zeros((rows * tpx, cols * tpx), dtype=np.float64)
    rr = np.ones((rows * tpx, cols * tpx), dtype=np.float64)
    for i in range(cols):
        sl = slice(i * tpx, (i + 1) * tpx)
        alb[:, sl] = cans[i][0][:, half:half + tpx]
        hh[:, sl] = cans[i][1][:, half:half + tpx]
        rr[:, sl] = cans[i][2][:, half:half + tpx]
    for i in range(1, cols):
        if colv[i] == colv[i - 1] or fw < 2:
            continue
        xb = i * tpx
        g0, g1 = max(0, xb - half), min(cols * tpx, xb + half)
        width = g1 - g0
        if width < 2:
            continue
        t = (np.arange(g0, g1, dtype=np.float64) + 0.5 - (xb - half)) / float(2 * half)
        t = G.smoothstep(0.0, 1.0, np.clip(t, 0.0, 1.0))[None, :]
        l0 = g0 - xb + tpx + half
        r0 = g0 - xb + half
        L = [c[:, l0:l0 + width] for c in cans[i - 1]]
        R = [c[:, r0:r0 + width] for c in cans[i]]
        alb[:, g0:g1] = L[0] * (1.0 - t[..., None]) + R[0] * t[..., None]
        hh[:, g0:g1] = L[1] * (1.0 - t) + R[1] * t
        rr[:, g0:g1] = L[2] * (1.0 - t) + R[2] * t
    return alb[:h, :w], hh[:h, :w], rr[:h, :w]


# ============================================================ 手写边界 → 逐行边界 x
def seam_x(kp, raster=RASTER, tz=(1.0, 0.62, 0.88, 0.72)):
    """手写折线关键点 → 整幅逐行边界 x（光栅 px）。

    `kp` = [(x_game_px, y_chart_px[, n, amp]), ...] 按 y 升序，首尾盖满 0..CHART_H。
    点与点之间**直线相连**（折线，不是样条）；`n`/`amp` = 这一段上再崩出的几颗犬牙
    （`n` 颗、峰值 ±`amp` px，左右交替，幅度按手写的循环系数 `tz` 错开）。
    大形状来自点怎么摆、小齿来自这一段"崩了几口"，两者都是人写的，不是噪声。
    """
    xx, yy = [], []
    for i, q in enumerate(kp):
        x, y = float(q[0]), float(q[1])
        if i:
            px, py = float(kp[i - 1][0]), float(kp[i - 1][1])
            n = int(q[2]) if len(q) > 2 else 0
            amp = float(q[3]) if len(q) > 3 else 0.0
            for j in range(n):
                f = (j + 1.0) / (n + 1.0)
                sgn = 1.0 if j % 2 == 0 else -1.0
                a0 = amp * tz[j % len(tz)]
                d = 0.30 / (n + 1.0)          # 齿顶不是尖锥：两颗顶点撑出一个小梯形口
                for ff, aa in ((f - d, a0), (f + d, a0 * 0.70)):
                    xx.append(x * ff + px * (1.0 - ff) + sgn * aa)
                    yy.append(y * ff + py * (1.0 - ff))
        xx.append(x)
        yy.append(y)
    ys = np.array(yy, dtype=np.float64) * raster
    xs = np.array(xx, dtype=np.float64) * raster
    yy2 = np.arange(CHART_H * raster, dtype=np.float64) + 0.5
    return np.interp(yy2, ys, xs)


def seam_x_deck(ends, raster=RASTER):
    """木栈道专用：**每块板一条断口 x**（板长轴沿 y，断口是竖切）。

    `ends` = 每块 16px 板程的断口 x（游戏 px）。竖切落在板程边界上 → 每块板
    端是一刀直的切口（画师逐块锯断），板程之间才横移。
    """
    tpx = 16 * raster
    cnt = int(math.ceil(CHART_H / 16.0))
    kp = []
    for i in range(cnt):
        x = float(ends[min(i, len(ends) - 1)])
        y0 = min(i * 16, CHART_H)
        y1 = min((i + 1) * 16, CHART_H)
        kp.append((x, y0))
        kp.append((x, y1))
    return seam_x(kp, raster)


# ============================================================ 摆件原语（逐个显式摆）
def _mixc(t, a, b):
    """标量 t 的两色混合（tone 是人写的一个数；G.cmix 只吃数组掩码）。"""
    t = float(t)
    return np.array([a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t,
                     a[2] + (b[2] - a[2]) * t])


def _mixm(m, a, b):
    """(H,W) 掩码 m 把 a 混向 b（a/b 可为 3 元组或 (H,W,3)）。画摆件统一走这条。"""
    m3 = np.asarray(m, dtype=np.float64)[..., None]
    A = a if np.ndim(a) == 3 else np.asarray(a, dtype=np.float64).reshape(1, 1, 3)
    B = b if np.ndim(b) == 3 else np.asarray(b, dtype=np.float64).reshape(1, 1, 3)
    return A + (B - A) * m3


#: 石子/碎料周围压出来的接触暗（土色偏冷，不是纯灰）
STONE_SHADOW = (0.175, 0.150, 0.118)


def _stone_col(tone):
    """石子色：tone 0 = 冷灰深，1 = 暖灰浅（明度由人写，不是随机）。"""
    return _mixc(tone, (0.228, 0.226, 0.228), (0.556, 0.538, 0.500))


def _win(cx, cy, rw, rh, W, H):
    x0 = max(0, int(math.floor(cx - rw)))
    x1 = min(W, int(math.ceil(cx + rw)))
    y0 = max(0, int(math.floor(cy - rh)))
    y1 = min(H, int(math.ceil(cy + rh)))
    return x0, x1, y0, y1


def _local(x0, x1, y0, y1, cx, cy, rot):
    xx = np.arange(x0, x1, dtype=np.float64) + 0.5 - cx
    yy = np.arange(y0, y1, dtype=np.float64) + 0.5 - cy
    X, Y = np.meshgrid(xx, yy)
    a = math.radians(float(rot))
    c, s = math.cos(a), math.sin(a)
    return X * c + Y * s, -X * s + Y * c


def el_stone(cv, cx, cy, w, hgt, rot, tone):
    """一颗石子：**手画的不规则轮廓** + 穹顶 + 周围一圈接触压痕。

    高度进 h、颜色进 albedo，明暗交给引擎（光源垂直向下 → 不烘方向光）。
    轮廓用低阶角向起伏拿"石头不是椭圆"的读法，起伏相位取作者写的 `rot`。
    """
    alb, h, rough, W, H = cv
    rx, ry = max(1.2, w * 0.5), max(1.2, hgt * 0.5)
    x0, x1, y0, y1 = _win(cx, cy, max(rx, ry) * 1.8, max(rx, ry) * 1.8, W, H)
    if x1 <= x0 or y1 <= y0:
        return
    u, v = _local(x0, x1, y0, y1, cx, cy, rot)
    ph = math.radians(float(rot))
    th = np.arctan2(v / ry, u / rx)
    lump = (1.0 + 0.13 * np.cos(3.0 * th + ph) + 0.075 * np.cos(5.0 * th - 2.0 * ph)
            + 0.05 * np.cos(2.0 * th + 3.0 * ph))
    r = np.hypot(u / rx, v / ry) / lump
    m = np.clip((1.0 - r) * 3.6, 0.0, 1.0)
    dome = np.sqrt(np.clip(1.0 - r, 0.0, None))
    ring = np.exp(-(((r - 1.26) / 0.22) ** 2))
    sl = (slice(y0, y1), slice(x0, x1))
    alb[sl] = _mixm(ring * 0.16, alb[sl], STONE_SHADOW)
    alb[sl] = _mixm(m * 0.96, alb[sl], _stone_col(tone))
    h[sl] = h[sl] - ring * 0.13 + m * (0.14 + 0.30 * dome)
    rough[sl] = (rough[sl] * (1.0 - m) + m * (0.87 + 0.08 * (1.0 - dome))
                 - ring * 0.02)


def el_peb(cv, cx, cy, w, hgt, count, tone):
    """一小把碎石（4~8 颗）：位置按固定扇形散开（画笔的"点一下"，不是噪声）。"""
    n = max(1, int(count))
    for i in range(n):
        t = (i + 0.5) / n
        a = math.radians(38.0 + 137.5 * i)
        rr = 0.46 * math.sqrt(t)
        s = 0.52 + 0.34 * ((i * 7) % 3) / 2.0
        el_stone(cv, cx + math.cos(a) * rr * w, cy + math.sin(a) * rr * hgt,
                 w * 0.42 * s, hgt * 0.40 * s, math.degrees(a) * 0.32,
                 min(1.0, max(0.0, tone + 0.10 * ((i % 3) - 1))))


def el_brk(cv, cx, cy, w, hgt, rot, tone):
    """碎砖 / 碎板：带缺角的小矩形。"""
    alb, h, rough, W, H = cv
    rx, ry = max(1.5, w * 0.5), max(1.2, hgt * 0.5)
    x0, x1, y0, y1 = _win(cx, cy, max(rx, ry) * 1.8, max(rx, ry) * 1.8, W, H)
    if x1 <= x0 or y1 <= y0:
        return
    u, v = _local(x0, x1, y0, y1, cx, cy, rot)
    r = np.maximum(np.abs(u) / rx, np.abs(v) / ry)
    m = np.clip((1.0 - r) * 7.0, 0.0, 1.0)
    chip = np.clip(1.12 - 0.58 * (np.abs(u) / rx + np.abs(v) / ry), 0.0, 1.0)
    m = m * chip                                   # 缺角（不是完美砖块）
    ring = np.exp(-(((r - 1.16) / 0.18) ** 2))
    sl = (slice(y0, y1), slice(x0, x1))
    alb[sl] = _mixm(ring * 0.18, alb[sl], STONE_SHADOW)
    alb[sl] = _mixm(m * 0.94, alb[sl], _stone_col(tone))
    h[sl] = h[sl] - ring * 0.10 + m * 0.20
    rough[sl] = rough[sl] * (1.0 - m) + m * 0.88


def el_tuft(cv, cx, cy, ln, spread, nbl, rot, tone):
    """草簇：n 根叶从根部成扇形散开 + 根下一小块压暗的土。

    叶的角度由 `rot`/`spread` 定，叶长叶宽也写死 —— 是"画的"，不是撒的。
    """
    alb, h, rough, W, H = cv
    n = max(1, int(nbl))
    _clump_shadow(alb, h, cx, cy, ln * 0.62, ln * 0.30)
    for i in range(n):
        t = (i / float(n - 1) - 0.5) if n > 1 else 0.0
        ang = float(rot) + t * float(spread)
        L = ln * (1.0 - 0.30 * abs(t) * 2.0)
        bx = cx + math.cos(math.radians(ang)) * L * 0.5
        by = cy + math.sin(math.radians(ang)) * L * 0.5
        gr = _mixc(min(1.0, max(0.0, tone + 0.5)) * 0.55
                   + 0.30 * (1.0 - abs(t) * 2.0),
                   (0.150, 0.248, 0.076), (0.335, 0.470, 0.175))
        _blade(alb, h, rough, bx, by, L, max(2.4, ln * 0.14), ang, gr, W, H)


def _clump_shadow(alb, h, cx, cy, rx, ry):
    """草簇 / 小件根下的那点暗（接触读法，不加方向光）。"""
    W, H = alb.shape[1], alb.shape[0]
    x0, x1, y0, y1 = _win(cx, cy, rx * 1.4, ry * 1.4, W, H)
    if x1 <= x0 or y1 <= y0:
        return
    u, v = _local(x0, x1, y0, y1, cx, cy, 0.0)
    m = np.clip((1.0 - np.hypot(u / max(1.0, rx), v / max(1.0, ry))) * 2.2, 0.0, 1.0)
    sl = (slice(y0, y1), slice(x0, x1))
    alb[sl] = _mixm(m * 0.42, alb[sl], STONE_SHADOW)
    h[sl] = h[sl] - m * 0.10


def _blade(alb, h, rough, cx, cy, ln, wd, ang, col, W, H):
    rx, ry = max(1.0, ln * 0.5), max(0.9, wd * 0.5)
    x0, x1, y0, y1 = _win(cx, cy, rx * 1.5, rx * 1.5, W, H)
    if x1 <= x0 or y1 <= y0:
        return
    u, v = _local(x0, x1, y0, y1, cx, cy, ang)
    r = np.hypot(u / rx, v / ry)
    m = np.clip((1.0 - r) * 2.6, 0.0, 1.0) * (1.0 - 0.55 * np.clip(u / rx, 0.0, 1.0))
    sl = (slice(y0, y1), slice(x0, x1))
    alb[sl] = _mixm(m * 0.85, alb[sl], col)
    h[sl] = h[sl] + m * 0.14
    rough[sl] = rough[sl] * (1.0 - m) + m * 0.94


def el_smear(cv, cx, cy, w, hgt, rot, tone, col_a, col_b):
    """漫上来的料（土 / 砾 / 泥）：对方材质色的一块，压平、压暗。tone=0 取 B 色。"""
    alb, h, rough, W, H = cv
    rx, ry = max(1.5, w * 0.5), max(1.5, hgt * 0.5)
    x0, x1, y0, y1 = _win(cx, cy, max(rx, ry) * 1.6, max(rx, ry) * 1.6, W, H)
    if x1 <= x0 or y1 <= y0:
        return
    u, v = _local(x0, x1, y0, y1, cx, cy, rot)
    r = np.hypot(u / rx, v / ry)
    m = np.clip((1.0 - r) * 2.4, 0.0, 1.0)
    col = _mixc(tone, col_b, col_a)
    sl = (slice(y0, y1), slice(x0, x1))
    alb[sl] = _mixm(m * 0.80, alb[sl], col * 0.92)
    h[sl] = h[sl] - m * 0.16
    rough[sl] = rough[sl] * (1.0 - m) + m * 0.96


#: 摆件派发表：(kind, dx, y, ...) → 画法。dx = 相对该行边界 x 的偏移（游戏 px）。
def place(cv, e, xb, raster, cols):
    """摆一颗/一簇：`e` 是人写在 MASTERS 里的那条数据。"""
    kind = e[0]
    y = float(e[2]) * raster
    row = int(min(max(0, y), CHART_H * raster - 1))
    cx = (float(xb[row]) + float(e[1]) * raster)
    cy = y
    p = e[3:]
    if kind == "st":
        el_stone(cv, cx, cy, p[0] * raster, p[1] * raster, p[2], p[3])
    elif kind == "peb":
        el_peb(cv, cx, cy, p[0] * raster, p[1] * raster, p[2], p[3])
    elif kind == "brk":
        el_brk(cv, cx, cy, p[0] * raster, p[1] * raster, p[2], p[3])
    elif kind == "tuft":
        el_tuft(cv, cx, cy, p[0] * raster, p[1], p[2], p[3], p[4])
    elif kind == "smear":
        el_smear(cv, cx, cy, p[0] * raster, p[1] * raster, p[2], p[3],
                 cols[0], cols[1])
    else:
        raise KeyError("未知摆件 %s" % kind)


# ============================================================ 整幅 → 带
def build_chart(pair, master, raster=RASTER):
    """画一整幅（512 × 264）：两材质拼接 + 手写边界 + 逐个摆件。"""
    W, H = GAME_W * raster, CHART_H * raster
    fade = int(pair.get("fade", 20))
    albA, hA, rA = mosaic(pair["a"], W, H, master["seq_a"], raster, fade)
    albB, hB, rB = mosaic(pair["b"], W, H, master["seq_b"], raster, fade)
    if "plank_ends" in master:
        xb = seam_x_deck(master["plank_ends"], raster)
    else:
        xb = seam_x(master["kp"], raster)

    X = (np.arange(W, dtype=np.float64) + 0.5)[None, :]
    left = X < xb[:, None]                       # 左 = 材质 A
    lift = float(pair.get("lift", 0.0))
    alb = np.where(left[..., None], albA, albB)
    h = np.where(left, H_BASE + H_MAT * hA + lift, H_BASE + H_MAT * hB)
    rough = np.where(left, rA, rB)

    # 缝：贴边接触暗（微 AO，允许）+ 缝里低一档（沉积）
    d = (X - xb[:, None]) / float(raster)
    g = np.exp(-((d / 2.4) ** 2))
    h = h - g * (0.20 + 0.10 * lift)
    alb = G.cshade(alb, 1.0 - g * 0.30)
    rough = np.clip(rough + g * 0.05, 0.05, 1.0)
    # 抬高件的"台下阴影"（只压 B 侧）：木栈道这类高出地面一级的件，台下要暗一层
    es = float(pair.get("edge_shadow", 0.0))
    if es > 0.0:
        sh = np.exp(-((np.clip(d, 0.0, None) / es) ** 2)) * (d > 0.0)
        alb = G.cshade(alb, 1.0 - sh * 0.34)
        h = h - sh * 0.07

    cv = [alb, h, rough, W, H]
    cols = (albA.reshape(-1, 3).mean(axis=0), albB.reshape(-1, 3).mean(axis=0))
    for e in master["els"]:
        place(cv, e, xb, raster, cols)
    return cv[0], cv[1], cv[2], xb


def _box2(a, k=RASTER):
    """k×k 箱式降采样（超采样收口）。"""
    if k <= 1:
        return a
    h, w = a.shape[0] // k * k, a.shape[1] // k * k
    a = a[:h, :w]
    out = a.reshape(h // k, k, w // k, k, *a.shape[2:]).mean(axis=(1, 3))
    return out


def generate(key, raster=RASTER):
    """出一件（按 key 里的材质对 / 带 / 变体号）。返回 alb/h/rough/nrm + 元数据。"""
    rec = _PIECE_OF[key]
    pair, master = _PAIR_OF[rec["pair"]], _MASTER_OF[rec["pair"]][rec["variant"] - 1]
    alb, h, rough, xb = build_chart(pair, master, raster)
    # 按带裁剪：整幅上画一次，件 = 该带那一段（跨带的摆件两头各留一半，摞起来才连着）
    y0, y1 = BANDS[rec["band"]]
    sl = (slice(y0 * raster, y1 * raster), slice(0, alb.shape[1]))
    alb, h, rough = alb[sl], h[sl], rough[sl]
    # 摆件后统一收口（颗粒 + 谷底 AO），再取法线
    out = G._packw(alb, h, rough, alb.shape[1], alb.shape[0],
                   seed=7000 + rec["pair_idx"] * 97 + rec["variant"] * 13,
                   relief_m=RELIEF_M, ao=0.30, nstr=0.95)
    nrm = G.normal_map_w(out["h"], alb.shape[1], alb.shape[0], RELIEF_M, out["nstr"])
    a_down = _box2(out["alb"])
    n_down = _box2(nrm)
    r_down = _box2(out["rough"])
    return {"alb": a_down, "nrm": n_down, "rough": r_down,
            "relief_m": RELIEF_M, "nstr": out["nstr"],
            "size": (a_down.shape[1], a_down.shape[0]),
            "pair": pair, "master": master, "rec": rec}


def elements_in_band(master, band, pad=22.0):
    """这件实际摆到的摆件条数（整幅上画一次、按带切开；跨带边缘的算进来）。"""
    y0, y1 = BANDS[band]
    return sum(1 for e in master["els"]
               if y0 - pad <= float(e[2]) < y1 + pad)


def element_kinds_in_band(master, band, pad=22.0):
    y0, y1 = BANDS[band]
    return sorted(set(e[0] for e in master["els"]
                      if y0 - pad <= float(e[2]) < y1 + pad))


# ============================================================ 落盘
def _stats(alb):
    return [round(float(alb[..., i].mean()), 3) for i in range(3)]


def export_all(out_dir, quiet=False):
    """全部件：src/<key>_alb|nrm|rgh.png + <key>.json + _manifest.json。"""
    os.makedirs(os.path.join(out_dir, "src"), exist_ok=True)
    recs = []
    for key in piece_keys():
        d = generate(key)
        pair, rec = d["pair"], d["rec"]
        nx, ny = d["size"]
        src = os.path.join(out_dir, "src")
        G._save_png(d["alb"], os.path.join(src, "%s_alb.png" % key), "sRGB")
        G._save_png(d["nrm"], os.path.join(src, "%s_nrm.png" % key), "Non-Color")
        G._save_png(d["rough"], os.path.join(src, "%s_rgh.png" % key), "Non-Color")
        meta = {
            "key": key,
            "name": "手工过渡·%s·%s·变体%d" % (pair["name"], BAND_CN[rec["band"]],
                                              rec["variant"]),
            "kind": "transition",
            "master": rec["pair"],
            "handmade": True,
            "variant": rec["variant"],
            "pair": [pair["a"], pair["b"]],
            "pair_name": pair["name"],
            "band": rec["band"],
            "tier": "handmade",
            "px": [nx, ny],
            "cells_w": nx // CELL,
            "px_per_cell": CELL,
            "supersample": RASTER,
            "edge_convention": "左=材质A、右=材质B；边界是手写关键点折线（犬牙交错、不对称）；"
                               "两外侧各接对应材质的纯料面（分段/补丁）",
            "x_tileable": False,
            "y_tileable": False,
            "note": pair["note"] + "；边界折线与摆件坐标全部写死在 ground_transitions.py 的 MASTERS 里",
            "lighting_neutral": "albedo + 微 AO（缝边接触暗）；光源=垂直向下 SUN，"
                                "无水平分量 → 无方向性明暗",
            "handmade": {
                "boundary": ("plank_ends（每块板一条断口 x）" if "plank_ends"
                             in d["master"] else "keypoints（手写折线）"),
                "boundary_points": (len(d["master"]["plank_ends"])
                                    if "plank_ends" in d["master"]
                                    else len(d["master"]["kp"])),
                "placed_elements": elements_in_band(d["master"], rec["band"]),
                "placed_elements_master": len(d["master"]["els"]),
                "element_kinds": element_kinds_in_band(d["master"], rec["band"]),
            },
            "mean_srgb": _stats(d["alb"]),
            "sides": {"left": pair["a"], "right": pair["b"]},
            "usage": pair["usage"],
            "files": {
                "albedo": "src/%s_alb.png" % key,
                "normal": "src/%s_nrm.png" % key,
                "roughness": "src/%s_rgh.png" % key,
                "render": "%s.png" % key,
            },
        }
        with open(os.path.join(out_dir, "%s.json" % key), "w", encoding="utf-8") as fh:
            json.dump(meta, fh, ensure_ascii=False, indent=1)
        recs.append(meta)
        if not quiet:
            print("  %-34s %-14s %-6s 摆件%2d  边界%2d点  meanRGB=(%.2f,%.2f,%.2f) %dx%d"
                  % (key, pair["name"], BAND_CN[rec["band"]],
                     meta["handmade"]["placed_elements"],
                     meta["handmade"]["boundary_points"],
                     meta["mean_srgb"][0], meta["mean_srgb"][1],
                     meta["mean_srgb"][2], nx, ny))
    man = {
        "spec": "手工预制过渡件库 v1（手写折线边界 + 逐个显式摆件；红警式预制块）",
        "why": "创始人定：材质过渡要手工做的预制块（预画好、按邻居选块），不要程序噪声渐变",
        "chart_px": [GAME_W, CHART_H],
        "bands_px": {"shoulder": G.STRIP_SHOULDER, "kerb": G.STRIP_KERB,
                     "road": G.STRIP_ROAD},
        "band_note": "边界在一整幅 264px（路肩96+路缘8+道路160）上手写一次，再按带裁剪；"
                     "路缘带 8px 不单出件（过渡由路肩件+道路件夹住）",
        "raster": RASTER,
        "pairs": [dict(key=p["key"], name=p["name"], left=p["a"], right=p["b"],
                       bands=list(p["bands"]), usage=p["usage"]) for p in PAIRS],
        "pieces": [dict(key=r["key"], master=r["master"], band=r["band"],
                        variant=r["variant"], sides=r["sides"],
                        boundary=r["handmade"]["boundary"],
                        points=r["handmade"]["boundary_points"],
                        elements=r["handmade"]["placed_elements"])
                   for r in recs],
    }
    with open(os.path.join(out_dir, "_manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(man, fh, ensure_ascii=False, indent=1)
    return recs


def render_dir():
    return os.path.join(os.path.dirname(os.path.dirname(HERE)),
                        "stick-world", "temp", "ground_tiles", "transitions")


# ============================================================ 自检（摆件是否真在缝上）
def selfcheck():
    """逐个摆件回报：它离边界多远。写歪了（>60px 落在纯色区里）会报出来。"""
    bad = 0
    for key in piece_keys():
        rec = _PIECE_OF[key]
        master = _MASTER_OF[rec["pair"]][rec["variant"] - 1]
        if "plank_ends" in master:
            xb = seam_x_deck(master["plank_ends"], 1)
        else:
            xb = seam_x(master["kp"], 1)
        for e in master["els"]:
            y = int(min(max(0, float(e[2])), CHART_H - 1))
            dd = abs(float(e[1]))
            if dd > 60.0:
                bad += 1
                print("  [歪] %s y=%d dx=%.0f（离缝 %.0fpx）" % (key, y, e[1], dd))
        # 边界是否始终落在画面内、两侧都留得下料
        if xb.min() < 120 or xb.max() > GAME_W - 120:
            bad += 1
            print("  [窄] %s 边界 x∈[%.0f,%.0f]（两侧料面不足）"
                  % (key, xb.min(), xb.max()))
    print("手工过渡自检：%s" % ("OK" if bad == 0 else "%d 处需修" % bad))
    return bad


# ============================================================ 登记表（按 key 索引）
_PIECE_OF = {}
_PAIR_OF = {}
_MASTER_OF = {}
BAND_CN = {"road": "道路带", "shoulder": "路肩带", "kerb": "路缘带"}


def _register():
    _PIECE_OF.clear()
    _PAIR_OF.clear()
    _MASTER_OF.clear()
    for i, p in enumerate(PAIRS):
        _PAIR_OF[p["key"]] = p
        _MASTER_OF[p["key"]] = MASTERS[p["key"]]
        for band in p["bands"]:
            for v in range(1, len(MASTERS[p["key"]]) + 1):
                k = "gtx_%s_%s_v%d" % (p["key"], band, v)
                _PIECE_OF[k] = dict(key=k, pair=p["key"], pair_idx=i, band=band,
                                    variant=v)
    return _PIECE_OF


def piece_keys():
    return list(sorted(_PIECE_OF.keys()))


# ============================================================ 手工数据（下面是全部"画"的部分）
# ↓↓↓ 全部手写数据：材质对 / 手写边界折线 / 逐个摆件
# 摆件一条 = (kind, dx, y, ...)：
#   dx = 相对**该行手写边界 x** 的横向偏移（游戏 px，负=往左=材质A一侧）
#   y  = 整幅纵向坐标（0 = 道路带底边，264 = 墙根；路肩带是 y∈[168,264)）
# kind / 后面跟的参数：
#   st   石子     w, h, rot, tone(0冷深→1暖浅)
#   peb  一把碎石 w, h, count, tone
#   brk  碎砖/碎板 w, h, rot, tone
#   tuft 草簇     len, spread°, 叶数, rot°, tone
#   smear 漫上来的料 w, h, rot, tone(0=取B的均色 1=取A的均色)
PAIRS = [
    dict(key="flagstone_dirt", a="flagstone", b="dirt_rut", name="石板↔土",
         bands=("shoulder", "road"), lift=0.10,
         note="城区石板铺装 ↔ 荒废土面：板缝积土、土侧的湿泥漫上板角",
         usage="城区(center/中环)铺装与荒废土面交界；村边、拆掉房子的空地四周"),
    dict(key="brick_gravel", a="brick_pave", b="gravel", name="旧砖↔碎石",
         bands=("shoulder", "road"), lift=0.06,
         note="中环旧砖铺装 ↔ 工地/次级巷碎石垫层：砖被撬走留下断口，碎石填进缺砖的坑",
         usage="中环(mid)砖铺装与碎石垫层/工地/马厩前交界"),
    dict(key="rammed_grass", a="rammed_earth", b="grass", name="夯土↔草皮",
         bands=("shoulder", "road"), lift=0.00,
         note="院坝夯土 ↔ 城边草皮：草从夯土干裂里钻出来，土侧被草啃掉一层",
         usage="edge 档夯土路肩/院坝与草地交界；城墙外、村口"),
    dict(key="gravel_grass", a="gravel", b="grass", name="砾石↔草皮",
         bands=("shoulder", "road"), lift=0.00,
         note="edge 档内部：砾石路肩被草啃（村里最常见的两种料），砾石滚进草里",
         usage="edge 档砾石巷与草皮交界；村庄边缘最常见的一道过渡"),
    dict(key="boardwalk_dirt", a="boardwalk", b="dirt_rut", name="木栈道↔泥地",
         bands=("road",), lift=0.52, edge_shadow=14.0,
         note="檐廊/码头木栈道断口 ↔ 泥地：板逐块锯成不同长度，缝里塞着泥和碎石",
         usage="商铺前檐廊、码头木栈道末端与泥地交界（栈道整体抬高一级）",
         plank_ends=True, fade=0),
]
BAND_CN = {"road": "道路带", "shoulder": "路肩带", "kerb": "路缘带"}

#: 手写母版：每对 3 变体，每变体一张整幅（264px）折线 + 一列表摆件
MASTERS = {
    # ---------------------------------------------------------------- 石板 ↔ 土
    "flagstone_dirt": [
        # v1 大咬 + 长舌：土侧在 y≈0.32 处整块咬进石板，石板在 y≈0.55 伸出一条长舌
        dict(seq_a=(0, 2, 1, 3), seq_b=(1, 3, 0, 2),
             kp=[(238, 0, 1, 5), (254, 18, 2, 8), (230, 34, 1, 11), (244, 52, 2, 6),
                 (214, 68, 1, 10), (206, 82, 2, 5), (222, 92, 1, 7),
                 (232, 102, 0, 0), (220, 118, 1, 9), (240, 126, 1, 6),
                 (268, 134, 2, 10), (282, 150, 1, 6), (262, 160, 2, 8),
                 (236, 176, 1, 7), (248, 200, 2, 10), (224, 216, 1, 6),
                 (240, 234, 2, 9), (230, 252, 1, 5), (254, 264, 0, 0)],
             els=[
                 # --- 道路带（y 0..159）
                 ("st", -9, 22, 24, 18, -18, 0.62),
                 ("peb", 8, 40, 16, 13, 4, 0.50),
                 ("smear", -12, 58, 40, 22, 8, 0.00),
                 ("st", 11, 74, 19, 15, 24, 0.72),
                 ("tuft", 17, 88, 22, 46, 5, 78, 0.20),
                 ("peb", -19, 100, 20, 15, 5, 0.58),
                 ("st", -24, 110, 24, 19, 8, 0.55),
                 ("brk", 7, 122, 21, 13, -32, 0.66),
                 ("st", 30, 136, 22, 17, -12, 0.68),
                 ("st", 41, 146, 17, 14, 30, 0.60),
                 ("smear", 13, 130, 38, 21, -14, 0.00),
                 # --- 路缘 + 路肩带（y 160..264）
                 ("peb", -6, 166, 18, 14, 4, 0.46),
                 ("st", -11, 180, 21, 16, -22, 0.70),
                 ("tuft", -10, 196, 20, 34, 4, 96, 0.35),
                 ("st", -6, 210, 15, 12, 14, 0.52),
                 ("smear", 10, 224, 34, 20, 6, 0.50),
                 ("tuft", 15, 238, 22, 36, 5, 96, 0.10),
                 ("peb", 10, 252, 17, 13, 4, 0.56),
                 ("tuft", 12, 64, 19, 40, 5, 66, 0.3),
                 ("tuft", -9, 104, 20, 44, 4, 100, 0.2),
                 ("tuft", 8, 190, 18, 36, 4, 88, 0.25),
             ]),
        # v2 细碎犬牙：小幅高频的齿（14~18px 摆幅），碎料多、草多
        dict(seq_a=(1, 3, 2, 0), seq_b=(2, 0, 3, 1),
             kp=[(248, 0, 1, 6), (236, 14, 1, 9), (254, 26, 2, 6), (240, 40, 1, 8),
                 (258, 52, 1, 5), (244, 66, 2, 9), (232, 78, 1, 7),
                 (250, 92, 1, 10), (238, 106, 2, 6), (224, 118, 1, 8),
                 (242, 132, 1, 7), (232, 146, 2, 9), (254, 158, 1, 6),
                 (240, 172, 1, 8), (226, 184, 2, 7), (248, 198, 1, 9),
                 (234, 212, 1, 6), (244, 226, 2, 8), (232, 240, 1, 7),
                 (246, 252, 1, 5), (238, 264, 0, 0)],
             els=[
                 # --- 道路带
                 ("st", -7, 17, 17, 13, -24, 0.58),
                 ("peb", 6, 30, 15, 12, 4, 0.48),
                 ("st", 8, 45, 15, 12, 16, 0.70),
                 ("smear", -9, 58, 32, 18, 0, 0.00),
                 ("tuft", 12, 70, 18, 42, 5, 74, 0.30),
                 ("peb", -12, 84, 16, 12, 5, 0.62),
                 ("st", -14, 96, 19, 15, 28, 0.52),
                 ("brk", 9, 108, 17, 11, 24, 0.64),
                 ("tuft", -11, 120, 19, 40, 4, 102, 0.25),
                 ("st", 13, 132, 16, 13, -14, 0.74),
                 ("peb", 8, 146, 14, 11, 4, 0.55),
                 ("smear", 12, 138, 30, 17, 8, 0.00),
                 # --- 路肩带
                 ("st", -8, 176, 18, 14, 12, 0.60),
                 ("tuft", -6, 190, 18, 38, 5, 92, 0.20),
                 ("peb", 9, 204, 15, 12, 4, 0.50),
                 ("st", 7, 218, 17, 13, -20, 0.66),
                 ("tuft", 11, 232, 19, 36, 4, 98, 0.35),
                 ("smear", -7, 246, 30, 18, -6, 0.00),
                 ("peb", -10, 256, 15, 12, 4, 0.58),
                 ("tuft", -10, 52, 17, 38, 4, 104, 0.2),
                 ("tuft", 9, 118, 18, 40, 5, 70, 0.3),
                 ("tuft", -7, 222, 17, 36, 4, 92, 0.15),
             ]),
        # v3 斜切 + 断口：边界整体右斜，两处硬断口（一处崩掉一块板，一处塌进土里）
        dict(seq_a=(3, 0, 2, 1), seq_b=(0, 2, 1, 3),
             kp=[(214, 0, 1, 7), (226, 20, 2, 9), (220, 40, 1, 6), (246, 56, 2, 11),
                 (240, 76, 1, 5), (262, 92, 2, 8), (252, 112, 1, 9),
                 (232, 128, 2, 7), (280, 144, 1, 12), (292, 162, 2, 6),
                 (272, 182, 1, 8), (256, 200, 2, 10), (264, 218, 1, 6),
                 (242, 236, 2, 8), (258, 252, 1, 5), (250, 264, 0, 0)],
             els=[
                 # --- 道路带
                 ("st", -10, 20, 26, 20, -14, 0.64),
                 ("brk", -18, 40, 24, 15, 18, 0.60),
                 ("st", 12, 58, 22, 17, 22, 0.72),
                 ("peb", -8, 76, 20, 15, 6, 0.52),
                 ("st", 16, 92, 25, 19, -8, 0.58),
                 ("tuft", -14, 108, 22, 44, 5, 66, 0.30),
                 ("smear", 14, 122, 44, 24, 10, 0.45),
                 ("st", 34, 140, 26, 20, 26, 0.68),
                 ("st", 48, 152, 20, 16, -18, 0.56),
                 ("peb", 30, 150, 18, 14, 4, 0.48),
                 # --- 路肩带
                 ("st", -12, 176, 24, 18, 14, 0.62),
                 ("peb", 10, 194, 19, 15, 5, 0.54),
                 ("tuft", -10, 212, 21, 40, 5, 94, 0.15),
                 ("st", 9, 228, 22, 17, -26, 0.70),
                 ("smear", -12, 244, 36, 22, -8, 0.00),
                 ("peb", 8, 256, 17, 13, 4, 0.50),
                 ("tuft", 11, 46, 19, 42, 5, 76, 0.25),
                 ("tuft", -8, 116, 18, 38, 4, 98, 0.2),
                 ("tuft", 9, 204, 17, 36, 4, 84, 0.3),
             ]),
    ],
    # ---------------------------------------------------------------- 旧砖 ↔ 碎石
    "brick_gravel": [
        # v1 整砖层缺角：砖按 8px 一个砖程被撬走（边界落在砖缝上），碎石填进缺砖的坑
        dict(seq_a=(0, 1, 3, 2), seq_b=(2, 3, 0, 1),
             kp=[(256, 0, 0, 0), (256, 8, 0, 0), (240, 8, 0, 0), (240, 16, 0, 0),
                 (256, 16, 1, 4), (256, 32, 0, 0), (240, 32, 0, 0),
                 (240, 40, 0, 0), (224, 40, 0, 0), (224, 48, 0, 0),
                 (240, 48, 1, 3), (240, 64, 0, 0), (256, 64, 0, 0),
                 (256, 80, 0, 0), (240, 80, 0, 0), (240, 96, 0, 0),
                 (224, 96, 0, 0), (224, 104, 0, 0), (240, 104, 1, 4),
                 (240, 120, 0, 0), (256, 120, 0, 0), (256, 136, 0, 0),
                 (272, 136, 0, 0), (272, 144, 0, 0), (256, 144, 1, 3),
                 (256, 160, 0, 0), (240, 160, 0, 0), (240, 176, 0, 0),
                 (256, 176, 0, 0), (256, 192, 0, 0), (240, 192, 0, 0),
                 (240, 208, 0, 0), (224, 208, 0, 0), (224, 216, 0, 0),
                 (240, 216, 1, 4), (240, 232, 0, 0), (256, 232, 0, 0),
                 (256, 248, 0, 0), (240, 248, 0, 0), (240, 264, 0, 0)],
             els=[
                 # --- 道路带
                 ("st", 6, 12, 20, 15, 16, 0.55),
                 ("brk", -9, 28, 22, 13, -14, 0.62),
                 ("peb", 10, 44, 22, 16, 6, 0.48),
                 ("brk", -12, 60, 20, 12, 28, 0.68),
                 ("smear", 8, 74, 34, 20, 6, 0.00),
                 ("st", 14, 88, 22, 17, -22, 0.60),
                 ("brk", -8, 104, 24, 14, 12, 0.58),
                 ("peb", -14, 118, 20, 15, 5, 0.52),
                 ("st", 9, 132, 19, 15, 24, 0.72),
                 ("brk", -16, 146, 22, 13, -30, 0.64),
                 ("peb", 12, 152, 18, 14, 4, 0.46),
                 # --- 路肩带
                 ("brk", 8, 172, 22, 13, 10, 0.60),
                 ("peb", -10, 188, 19, 15, 5, 0.50),
                 ("brk", -13, 204, 20, 12, -18, 0.66),
                 ("st", 11, 220, 21, 16, 20, 0.58),
                 ("brk", 7, 236, 21, 13, 26, 0.56),
                 ("peb", 9, 252, 18, 14, 4, 0.52),
                 ("tuft", 9, 68, 16, 36, 4, 74, 0.3),
                 ("tuft", -8, 208, 15, 34, 4, 92, 0.25),
             ]),
        # v2 大崩口：一边被扒掉一大片砖（露出碎石垫层），断口参差
        dict(seq_a=(2, 0, 1, 3), seq_b=(1, 2, 3, 0),
             kp=[(272, 0, 0, 0), (272, 16, 0, 0), (256, 16, 0, 0), (256, 24, 1, 4),
                 (232, 24, 0, 0), (232, 32, 0, 0), (208, 32, 0, 0),
                 (208, 40, 0, 0), (232, 40, 1, 5), (232, 56, 0, 0),
                 (256, 56, 0, 0), (256, 72, 0, 0), (240, 72, 0, 0),
                 (240, 88, 0, 0), (216, 88, 0, 0), (216, 96, 1, 4),
                 (240, 96, 0, 0), (240, 112, 0, 0), (256, 112, 0, 0),
                 (256, 128, 0, 0), (272, 128, 0, 0), (272, 152, 0, 0),
                 (256, 152, 0, 0), (256, 168, 0, 0), (240, 168, 0, 0),
                 (240, 192, 0, 0), (224, 192, 0, 0), (224, 200, 1, 3),
                 (240, 200, 0, 0), (240, 216, 0, 0), (256, 216, 0, 0),
                 (256, 240, 0, 0), (240, 240, 0, 0), (240, 264, 0, 0)],
             els=[
                 # --- 道路带
                 ("st", 8, 20, 21, 16, -18, 0.52),
                 ("peb", -20, 36, 26, 18, 7, 0.44),
                 ("st", -26, 46, 24, 18, 12, 0.66),
                 ("brk", 9, 64, 22, 13, 22, 0.60),
                 ("smear", -16, 80, 42, 24, -10, 0.00),
                 ("st", 10, 96, 20, 16, -26, 0.58),
                 ("peb", -8, 110, 24, 17, 6, 0.50),
                 ("brk", -12, 126, 24, 14, 14, 0.64),
                 ("st", 13, 140, 19, 15, 30, 0.70),
                 ("peb", 11, 154, 20, 15, 5, 0.46),
                 # --- 路肩带
                 ("brk", 9, 176, 22, 13, 8, 0.58),
                 ("st", -14, 192, 23, 18, -16, 0.62),
                 ("peb", -9, 208, 21, 16, 6, 0.48),
                 ("brk", 12, 226, 21, 12, 28, 0.62),
                 ("st", 8, 242, 20, 16, 18, 0.56),
                 ("peb", -11, 256, 18, 14, 4, 0.50),
                 ("tuft", 10, 104, 16, 36, 4, 78, 0.3),
                 ("tuft", -8, 200, 15, 34, 4, 90, 0.25),
             ]),
        # v3 断口 + 塌陷：边界近竖直（沿一条砖缝走），中段塌进两个坑
        dict(seq_a=(3, 2, 0, 1), seq_b=(0, 3, 2, 1),
             kp=[(248, 0, 0, 0), (248, 24, 1, 4), (232, 24, 0, 0), (232, 48, 0, 0),
                 (248, 48, 1, 3), (248, 72, 0, 0), (264, 72, 0, 0),
                 (264, 88, 0, 0), (248, 88, 0, 0), (248, 112, 0, 0),
                 (232, 112, 0, 0), (232, 128, 1, 4), (216, 128, 0, 0),
                 (216, 136, 0, 0), (232, 136, 0, 0), (232, 160, 0, 0),
                 (248, 160, 0, 0), (248, 184, 1, 3), (232, 184, 0, 0),
                 (232, 200, 1, 4), (248, 200, 0, 0), (248, 224, 0, 0),
                 (264, 224, 0, 0), (264, 240, 0, 0), (248, 240, 0, 0),
                 (248, 264, 0, 0)],
             els=[
                 # --- 道路带
                 ("brk", 7, 16, 23, 14, -12, 0.62),
                 ("peb", 9, 36, 21, 16, 6, 0.48),
                 ("st", -8, 56, 20, 16, 20, 0.66),
                 ("brk", -11, 76, 22, 13, -22, 0.58),
                 ("peb", -7, 96, 23, 17, 5, 0.52),
                 ("smear", 10, 110, 36, 22, 0, 0.00),
                 ("st", -9, 124, 21, 16, 26, 0.60),
                 ("brk", 8, 140, 21, 13, 16, 0.64),
                 ("peb", 12, 154, 19, 14, 4, 0.46),
                 # --- 路肩带
                 ("peb", -9, 174, 20, 15, 5, 0.50),
                 ("brk", 10, 190, 22, 13, 10, 0.60),
                 ("st", -12, 208, 22, 17, -18, 0.64),
                 ("brk", 8, 226, 21, 13, 24, 0.56),
                 ("peb", -8, 242, 19, 15, 5, 0.52),
                 ("st", 11, 256, 20, 16, 14, 0.58),
                 ("tuft", -9, 90, 16, 34, 4, 96, 0.25),
                 ("tuft", 8, 216, 15, 34, 4, 80, 0.3),
             ]),
    ],
    # ---------------------------------------------------------------- 夯土 ↔ 草皮
    "rammed_grass": [
        # v1 草啃边：草侧沿夯层一层层啃进来，夯土侧一块块崩掉（崩口对齐夯层 14cm≈10px）
        dict(seq_a=(0, 3, 1, 2), seq_b=(2, 1, 3, 0),
             kp=[(258, 0, 1, 6), (246, 12, 1, 8), (262, 24, 2, 6), (248, 36, 1, 9),
                 (266, 48, 1, 5), (252, 62, 2, 8), (236, 74, 1, 7),
                 (254, 86, 1, 9), (240, 98, 2, 6), (226, 110, 1, 8),
                 (244, 124, 1, 6), (234, 138, 2, 8), (252, 150, 1, 5),
                 (238, 164, 1, 7), (224, 178, 2, 6), (242, 192, 1, 8),
                 (230, 206, 1, 6), (246, 220, 2, 7), (234, 234, 1, 6),
                 (248, 248, 1, 5), (240, 264, 0, 0)],
             els=[
                 # --- 道路带
                 ("tuft", 9, 14, 20, 44, 5, 76, 0.15),
                 ("st", -6, 28, 15, 12, -16, 0.55),
                 ("tuft", 12, 42, 18, 40, 4, 82, 0.30),
                 ("peb", -9, 56, 16, 12, 5, 0.50),
                 ("tuft", 8, 68, 19, 46, 5, 72, 0.10),
                 ("smear", -10, 82, 34, 20, 6, 0.00),
                 ("tuft", 13, 96, 18, 38, 4, 88, 0.25),
                 ("st", -7, 108, 16, 13, 22, 0.62),
                 ("tuft", 10, 122, 20, 42, 5, 80, 0.20),
                 ("peb", 11, 136, 15, 12, 4, 0.46),
                 ("tuft", 9, 148, 17, 40, 4, 94, 0.35),
                 # --- 路肩带
                 ("tuft", 10, 172, 19, 42, 5, 86, 0.20),
                 ("st", -6, 186, 15, 12, -14, 0.58),
                 ("tuft", 11, 200, 18, 38, 4, 78, 0.15),
                 ("peb", -8, 214, 16, 13, 5, 0.52),
                 ("tuft", 9, 228, 19, 44, 5, 90, 0.30),
                 ("st", 7, 242, 16, 13, 18, 0.60),
                 ("tuft", 10, 254, 17, 36, 4, 84, 0.10),
             ]),
        # v2 草斑成片：两大块草皮盖在夯土上（草从坡上滚下来），中间夯土成岛
        dict(seq_a=(1, 2, 3, 0), seq_b=(0, 3, 1, 2),
             kp=[(228, 0, 1, 7), (242, 16, 1, 6), (224, 32, 2, 8), (246, 44, 1, 5),
                 (234, 58, 1, 9), (254, 70, 2, 6), (240, 84, 1, 8),
                 (258, 96, 1, 6), (244, 110, 2, 7), (262, 122, 1, 5),
                 (248, 136, 1, 9), (264, 148, 2, 6), (248, 162, 1, 7),
                 (266, 176, 1, 5), (250, 190, 2, 8), (262, 204, 1, 6),
                 (246, 218, 1, 7), (256, 232, 2, 6), (242, 246, 1, 5),
                 (250, 264, 0, 0)],
             els=[
                 # --- 道路带
                 ("tuft", 10, 12, 21, 46, 6, 74, 0.20),
                 ("st", -8, 26, 16, 13, 20, 0.54),
                 ("tuft", 14, 40, 22, 50, 6, 82, 0.15),
                 ("tuft", 18, 54, 19, 44, 5, 70, 0.30),
                 ("peb", -10, 68, 17, 13, 5, 0.48),
                 ("smear", -9, 84, 36, 22, -6, 0.00),
                 ("tuft", 12, 98, 20, 42, 5, 88, 0.10),
                 ("st", -6, 112, 15, 12, -18, 0.60),
                 ("tuft", 11, 126, 21, 48, 6, 78, 0.25),
                 ("tuft", 15, 142, 18, 40, 4, 92, 0.35),
                 # --- 路肩带
                 ("tuft", 9, 172, 20, 44, 5, 84, 0.15),
                 ("peb", -7, 186, 16, 12, 4, 0.50),
                 ("tuft", 12, 200, 21, 46, 6, 76, 0.20),
                 ("st", 8, 214, 15, 12, 16, 0.56),
                 ("tuft", 10, 228, 19, 42, 5, 90, 0.30),
                 ("tuft", 13, 244, 18, 38, 4, 80, 0.10),
                 ("peb", -6, 256, 15, 12, 4, 0.46),
             ]),
        # v3 干裂延伸：夯土的干裂顺着裂缝张开，草长在裂缝里（裂缝走向与边界同向）
        dict(seq_a=(2, 0, 3, 1), seq_b=(3, 1, 0, 2),
             kp=[(246, 0, 1, 5), (260, 14, 1, 7), (244, 28, 2, 5), (258, 42, 1, 8),
                 (242, 56, 1, 6), (256, 70, 2, 7), (240, 84, 1, 5),
                 (254, 98, 1, 8), (238, 112, 2, 6), (252, 126, 1, 7),
                 (236, 140, 1, 5), (250, 154, 2, 8), (234, 168, 1, 6),
                 (248, 182, 1, 7), (232, 196, 2, 5), (246, 210, 1, 8),
                 (230, 224, 1, 6), (244, 238, 2, 7), (228, 252, 1, 5),
                 (242, 264, 0, 0)],
             els=[
                 # --- 道路带
                 ("st", -7, 18, 16, 12, -20, 0.58),
                 ("tuft", 8, 34, 17, 38, 4, 80, 0.25),
                 ("peb", -8, 48, 15, 12, 5, 0.50),
                 ("tuft", 10, 62, 19, 44, 5, 74, 0.15),
                 ("st", -6, 78, 14, 11, 18, 0.62),
                 ("tuft", 9, 94, 18, 40, 5, 86, 0.30),
                 ("smear", -9, 108, 32, 20, 4, 0.50),
                 ("tuft", 11, 124, 16, 36, 4, 92, 0.20),
                 ("peb", 7, 138, 14, 11, 4, 0.44),
                 ("st", -5, 152, 15, 12, -12, 0.56),
                 # --- 路肩带
                 ("tuft", 8, 174, 18, 40, 5, 88, 0.20),
                 ("peb", -7, 188, 15, 12, 4, 0.48),
                 ("tuft", 10, 204, 17, 38, 4, 78, 0.30),
                 ("st", -6, 218, 15, 12, 16, 0.60),
                 ("tuft", 9, 234, 18, 42, 5, 90, 0.15),
                 ("peb", 8, 252, 14, 11, 4, 0.52),
             ]),
    ],
    # ---------------------------------------------------------------- 砾石 ↔ 草皮
    "gravel_grass": [
        # v1 砾石散进草里：边界两侧各留一把滚出去的砾石（近处密远处疏）
        dict(seq_a=(0, 2, 3, 1), seq_b=(1, 0, 2, 3),
             kp=[(250, 0, 1, 7), (238, 14, 1, 9), (254, 28, 2, 6), (240, 42, 1, 8),
                 (256, 56, 1, 6), (242, 70, 2, 9), (226, 84, 1, 7),
                 (244, 98, 1, 8), (230, 112, 2, 6), (246, 126, 1, 9),
                 (232, 140, 1, 7), (248, 154, 2, 8), (234, 168, 1, 6),
                 (250, 182, 1, 9), (236, 196, 2, 7), (252, 210, 1, 6),
                 (238, 224, 1, 8), (252, 238, 2, 6), (240, 252, 1, 5),
                 (248, 264, 0, 0)],
             els=[
                 # --- 道路带
                 ("peb", 8, 16, 22, 16, 7, 0.50),
                 ("st", -7, 30, 16, 13, -18, 0.58),
                 ("tuft", 11, 44, 18, 40, 4, 78, 0.25),
                 ("peb", -11, 58, 20, 15, 6, 0.62),
                 ("peb", 13, 72, 18, 14, 5, 0.44),
                 ("smear", -9, 86, 32, 20, 6, 0.00),
                 ("st", 10, 100, 17, 13, 22, 0.66),
                 ("tuft", -10, 114, 19, 42, 5, 86, 0.15),
                 ("peb", 12, 128, 24, 17, 8, 0.52),
                 ("peb", -13, 142, 21, 16, 6, 0.48),
                 ("st", 9, 154, 15, 12, -14, 0.60),
                 # --- 路肩带
                 ("peb", 10, 172, 20, 15, 6, 0.46),
                 ("tuft", -9, 188, 18, 38, 4, 80, 0.20),
                 ("st", 8, 204, 16, 13, 18, 0.62),
                 ("peb", -8, 220, 19, 14, 5, 0.54),
                 ("tuft", 11, 234, 18, 40, 5, 88, 0.30),
                 ("peb", 9, 252, 17, 13, 5, 0.50),
                 ("tuft", -9, 36, 17, 38, 4, 84, 0.2),
                 ("tuft", 10, 120, 18, 40, 5, 72, 0.3),
             ]),
        # v2 草吞砾石：草成片盖过来，只剩零散几颗砾石探出草面
        dict(seq_a=(1, 3, 0, 2), seq_b=(2, 1, 3, 0),
             kp=[(238, 0, 1, 6), (250, 18, 2, 8), (236, 36, 1, 7), (248, 52, 1, 9),
                 (232, 70, 2, 6), (244, 88, 1, 8), (228, 104, 1, 7),
                 (242, 122, 2, 9), (226, 140, 1, 6), (240, 156, 1, 8),
                 (224, 174, 2, 7), (238, 192, 1, 6), (222, 210, 1, 8),
                 (236, 228, 2, 6), (220, 246, 1, 7), (234, 264, 0, 0)],
             els=[
                 # --- 道路带
                 ("peb", 9, 20, 20, 15, 6, 0.48),
                 ("tuft", -8, 36, 20, 44, 5, 76, 0.15),
                 ("peb", 11, 54, 17, 13, 5, 0.52),
                 ("st", -6, 70, 15, 12, -20, 0.56),
                 ("tuft", 12, 88, 21, 46, 6, 82, 0.30),
                 ("smear", -10, 104, 34, 21, 0, 0.00),
                 ("peb", 13, 120, 22, 16, 7, 0.44),
                 ("tuft", -11, 136, 19, 42, 5, 90, 0.20),
                 ("peb", 10, 152, 19, 14, 5, 0.50),
                 # --- 路肩带
                 ("tuft", 9, 176, 19, 42, 5, 84, 0.20),
                 ("peb", -8, 192, 18, 14, 5, 0.50),
                 ("tuft", 11, 208, 20, 44, 5, 78, 0.15),
                 ("peb", 9, 224, 19, 14, 5, 0.46),
                 ("tuft", -9, 240, 18, 40, 4, 88, 0.30),
                 ("peb", 10, 256, 16, 13, 4, 0.52),
                 ("tuft", 10, 46, 17, 38, 4, 80, 0.25),
                 ("tuft", -9, 100, 17, 36, 4, 96, 0.2),
             ]),
        # v3 车辙切边：砾石侧的车辙（两道）在边界处断掉，草从断口长出来
        dict(seq_a=(2, 1, 3, 0), seq_b=(0, 2, 1, 3),
             kp=[(256, 0, 1, 6), (244, 16, 1, 8), (260, 32, 2, 7), (248, 48, 1, 6),
                 (264, 64, 1, 8), (250, 80, 2, 7), (236, 96, 1, 6),
                 (252, 112, 1, 9), (238, 128, 2, 6), (254, 144, 1, 7),
                 (240, 160, 1, 8), (256, 176, 2, 6), (242, 192, 1, 7),
                 (258, 208, 1, 8), (244, 224, 2, 6), (258, 240, 1, 7),
                 (246, 252, 1, 5), (254, 264, 0, 0)],
             els=[
                 # --- 道路带
                 ("peb", -10, 14, 21, 15, 6, 0.46),
                 ("st", 8, 30, 17, 13, 20, 0.60),
                 ("peb", 12, 46, 19, 14, 5, 0.54),
                 ("tuft", -9, 62, 19, 42, 5, 80, 0.25),
                 ("peb", -12, 78, 20, 15, 6, 0.50),
                 ("st", 10, 94, 16, 13, -16, 0.64),
                 ("tuft", 11, 110, 20, 44, 5, 86, 0.15),
                 ("peb", -11, 126, 22, 16, 7, 0.48),
                 ("smear", -8, 140, 32, 20, 8, 0.00),
                 ("peb", 10, 152, 18, 14, 5, 0.52),
                 # --- 路肩带
                 ("peb", -9, 172, 19, 14, 5, 0.48),
                 ("tuft", 10, 188, 19, 42, 5, 82, 0.20),
                 ("st", -7, 204, 16, 13, 16, 0.58),
                 ("peb", 11, 220, 20, 15, 6, 0.52),
                 ("tuft", -8, 236, 18, 40, 4, 88, 0.30),
                 ("peb", 9, 254, 17, 13, 4, 0.46),
                 ("tuft", -8, 54, 16, 34, 4, 92, 0.25),
                 ("tuft", 9, 132, 17, 38, 4, 76, 0.3),
             ]),
    ],
    # ---------------------------------------------------------------- 木栈道 ↔ 泥地
    "boardwalk_dirt": [
        # v1 逐块锯断：每块板一条断口 x（板宽 16px），断口在板程边界上竖切
        dict(seq_a=(0,), seq_b=(1,),
             plank_ends=[264, 264, 248, 248, 248, 232, 232, 248, 264, 264,
                         280, 280, 264, 248, 248, 232, 248],
             els=[
                 # --- 道路带（栈道侧抬高一级 → 崖下的泥地里塞着掉下去的碎石与板屑）
                 ("st", -8, 20, 20, 15, -16, 0.58),
                 ("brk", -11, 38, 22, 13, 14, 0.62),
                 ("peb", -14, 56, 20, 15, 6, 0.46),
                 ("smear", -16, 74, 40, 22, -8, 0.00),
                 ("st", -10, 92, 17, 13, 22, 0.66),
                 ("peb", -9, 110, 18, 14, 5, 0.50),
                 ("brk", -13, 128, 20, 12, -24, 0.58),
                 ("st", -7, 146, 16, 12, 12, 0.62),
                 ("peb", -11, 156, 17, 13, 4, 0.48),
             ]),
        # v2 大断口：中段被整片锯掉（三块板同一刀），断口外斜
        dict(seq_a=(2,), seq_b=(3,),
             plank_ends=[272, 272, 272, 272, 256, 248, 240, 224, 224, 224,
                         240, 256, 272, 272, 256, 256, 256],
             els=[
                 # --- 道路带
                 ("peb", -9, 16, 21, 16, 6, 0.48),
                 ("st", -12, 34, 22, 17, 18, 0.62),
                 ("brk", -15, 52, 24, 14, -12, 0.60),
                 ("smear", -20, 70, 46, 24, 6, 0.45),
                 ("peb", -13, 88, 22, 16, 7, 0.52),
                 ("st", -8, 106, 18, 14, -20, 0.56),
                 ("brk", -10, 124, 21, 13, 26, 0.64),
                 ("peb", -14, 142, 20, 15, 6, 0.46),
                 ("st", -9, 158, 17, 13, 14, 0.60),
             ]),
        # v3 长短交错：断口一长一短来回（像被人随手拔掉几块板）
        dict(seq_a=(3,), seq_b=(2,),
             plank_ends=[280, 248, 280, 232, 264, 248, 264, 232, 248, 264,
                         248, 280, 264, 248, 232, 248, 264],
             els=[
                 # --- 道路带
                 ("st", -10, 18, 19, 15, -22, 0.60),
                 ("peb", -12, 36, 20, 15, 5, 0.50),
                 ("brk", -14, 54, 22, 13, 16, 0.58),
                 ("peb", -16, 72, 24, 17, 7, 0.44),
                 ("smear", -18, 90, 42, 23, 4, 0.00),
                 ("st", -9, 108, 18, 14, 20, 0.64),
                 ("peb", -11, 126, 19, 14, 5, 0.48),
                 ("brk", -13, 144, 20, 12, -18, 0.62),
                 ("st", -8, 158, 16, 13, 10, 0.56),
             ]),
    ],
}

_register()


# ============================================================ main
def main():
    out = render_dir()
    os.makedirs(os.path.join(out, "src"), exist_ok=True)
    print("== 手工过渡件落盘 →", out)
    recs = export_all(out)
    print("GTX_OK", len(recs))
    selfcheck()


if __name__ == "__main__":
    main()
