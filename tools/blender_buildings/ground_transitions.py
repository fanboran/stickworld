# -*- coding: utf-8 -*-
"""ground_transitions.py —— 手工预制过渡件库（建筑管线 v3 · 地面体系）

创始人定的常识（这条是全部逻辑的起点）
--------------------------------------
现实里两块地之间**有路坎**：铺装边缘要有 edge restraint（路缘石 / 镶边石 / 立砌砖牙 /
枕木横档），红警的海岸过渡块、泰拉瑞亚的草↔土边界也都是**硬质边界件**，
**不是两种材质大面积互相渗透**。所以本库：

* **先在材质之间立一道硬质收边**，两侧材质在收边处**硬切**（不犬牙互咬）：
    - 石板 / 砾石 ↔ 土 / 草皮 → `sett` 镶边石（一列手凿方石）
    - 旧砖 ↔ 碎石 → `soldier` 立砌砖牙（砖侧立收边）
    - 夯土 ↔ 草皮 → `turf` 草皮切边（草皮像被切开的毯子，边缘略翘、切口露土）
    - 木栈道 ↔ 泥地 → `sleeper` 端头横档 / 枕木（板端顶着横档）
* **收边件逐块手摆**：放线（`line`）是人写的缓折线；收边上的**每一块**
  （方向偏移 / 沿边长短 / 转角 / 明度）都写死在 `units` 里 —— 像铺装工人一块一块砌。
* **溢出极少量**：`els` 只写 3~5 条贴着收边的碎屑 / 草须（不是大面积互渗）。
* 两侧材质直接调 `ground_tiles` 的平铺生成器（与分段集同源），
  铺法也是引擎的铺法（128px 游戏档 × 显式指定的变体序列）。

画幅与分带
----------
地面纵向是连续一条：路肩 96 + 路缘 8 + 道路 160 = **264px**（`ground_tiles` 同口径）。
放线 / 收边 / 碎屑**在一整幅 264px 上做一次**，再按带裁剪成件：道路带 y∈[0,160)、
路肩带 y∈[168,264)。上下摞起来收边自然连成一条（红警式预制块的切法）。

一件的规格：16 格宽（512px = 与分段集同口径）× 所属带高；左 = 材质 A、右 = 材质 B。

产物（`stick-world/temp/ground_tiles/transitions/`）
    src/<key>_alb.png / _nrm.png / _rgh.png    反照率（sRGB）/ 法线 / 粗糙度
    <key>.json                                  契约（材质对 / 收边类型 / 左右约定 / 变体号 / 块数）
    _manifest.json                              件清单
成图见 `probe_transitions.py` → `pbr_ground_transitions.png`。

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
#: 内部超采样倍率（落盘前箱式降采样）
RASTER = 2
#: 每个带在哪一段（整幅坐标，y 从道路带底边起算；数组第 0 行 = 图片底部）
BANDS = {
    "road": (0, G.STRIP_ROAD),                                    # y 0..159
    "shoulder": (G.STRIP_ROAD + G.STRIP_KERB, CHART_H),           # y 168..263
}
#: 件级起伏（米）：与分段集同口径
RELIEF_M = 0.036
#: 两侧主料层的基准高度
HB_A, HB_B, HM = 0.46, 0.40, 0.30

#: 收边类型：w = 收边进深 px / rise = 顶面高出 A 侧主料多少 / col 两色 / face 缝里与立面暗
EDGES = {
    "sett": dict(w=16, rise=0.13, rough=0.86, lip=0.0, joint=0.30,
                 col=((0.235, 0.232, 0.234), (0.575, 0.556, 0.520)),
                 face=(0.200, 0.172, 0.140),
                 name="镶边石", note="一列手凿方石压住铺装边；缝里塞土，石顶被踩磨亮"),
    "soldier": dict(w=15, rise=0.10, rough=0.88, lip=0.0, joint=0.30,
                    col=((0.270, 0.140, 0.104), (0.545, 0.320, 0.230)),
                    face=(0.185, 0.115, 0.085),
                    name="立砌砖牙", note="砖侧立收边：一块块砖牙顶着碎石垫层，砖缝对着走道"),
    "turf": dict(w=18, rise=0.12, rough=0.92, lip=1.0, joint=0.18,
                 col=((0.185, 0.285, 0.098), (0.335, 0.460, 0.176)),
                 face=(0.205, 0.155, 0.100),
                 name="草皮切边", note="草皮像被切开的毯子：边缘略翘、切口露土，几根草须漫过来"),
    "sleeper": dict(w=20, rise=0.09, rough=0.82, lip=0.0, joint=0.30,
                    col=((0.245, 0.160, 0.092), (0.520, 0.372, 0.222)),
                    face=(0.160, 0.115, 0.072),
                    name="端头横档", note="栈道板端顶在枕木横档上；横档外就是泥，档面溅着泥点"),
}


# ============================================================ 材质：128px 游戏档平铺
_TILE = {}


def tile(key, variant=0, raster=RASTER, rot90=False):
    """取一张平铺贴图（游戏档 128px → raster 倍密度）。与分段集同一批生成器。

    `rot90`：把贴图转 90°（板纹走向要垂直于纵向边界时用，见木栈道）。
    平铺贴图两轴都是周期函数，转 90° 后仍严格周期 → 仍可无缝平铺。
    """
    k = (key, variant, raster, bool(rot90))
    if k not in _TILE:
        d = G.generate(key, 128 * raster, variant=int(variant))
        if rot90:
            d = dict(d)
            for ch in ("alb", "h", "rough"):
                d[ch] = np.ascontiguousarray(np.swapaxes(d[ch], 0, 1))
        _TILE[k] = d
    return _TILE[k]


def _column(key, variant, rows, tpx, raster, pad=0, rot90=False):
    """一列（1 格宽 = 128×raster px）纵向按同一变体铺。

    纵向：同变体重复 → 周期函数 → 无缝。横向：左右各多铺 `pad` px 的**周期延拓**，
    供列边界的十字淡接取用。
    """
    d = tile(key, variant, raster, rot90)
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


def mosaic(key, w, h, seq, raster=RASTER, fade=20, rot90=False):
    """按**显式给定的变体序列**把平铺贴图铺成 w×h。

    `seq` 是人写的（哪一格用哪个相位由人定），不是随机撒。同一变体纵向重复天然无缝；
    **列与列之间**换变体则会在 128px 处留下一条低频色阶（实测看得见），所以在列边界
    按 `fade`（游戏 px，人定）把左右两列各自的**周期延拓**十字淡接。
    `fade=0` 用于必须逐像素周期连续的材料（木栈道：板色与钉子会重影）。
    """
    tpx = 128 * raster
    cols = int(math.ceil(w / float(tpx)))
    rows = int(math.ceil(h / float(tpx)))
    n = max(1, len(seq))
    colv = [seq[i % n] for i in range(cols)]
    fw = int(fade * raster)
    half = max(1, fw // 2)
    cans = [_column(key, v, rows, tpx, raster, half, rot90) for v in colv]
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


# ============================================================ 放线 → 逐行边界 x
def line_x(line, raster=RASTER):
    """人写的**放线**折线 → 整幅逐行边界 x（光栅 px）。

    `line` = [(x_game_px, y_chart_px), ...] 按 y 升序，首尾盖满 0..CHART_H。
    放线是缓的（工人拉线），局部错落交给逐块摆的收边件 —— 这正是"手工"的落点。
    """
    ys = np.array([p[1] for p in line], dtype=np.float64) * raster
    xs = np.array([p[0] for p in line], dtype=np.float64) * raster
    yy = np.arange(CHART_H * raster, dtype=np.float64) + 0.5
    return np.interp(yy, ys, xs)


# ============================================================ 画法原语
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


#: 石子/碎料周围压出来的接触暗（土色偏冷，不是纯灰）
STONE_SHADOW = (0.175, 0.150, 0.118)


def _stone_col(tone):
    """石子色：tone 0 = 冷灰深，1 = 暖灰浅（明度由人写，不是随机）。"""
    return _mixc(tone, (0.228, 0.226, 0.228), (0.556, 0.538, 0.500))


def el_stone(cv, cx, cy, w, hgt, rot, tone):
    """一颗石子：不规则轮廓 + 穹顶 + 周围接触压痕（只用于缝里漏出的小碎屑）。"""
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
    """一小把碎屑（3~6 颗）：位置按固定扇形散开（画笔点一下，不是噪声）。"""
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
    """碎砖 / 碎板：带缺角的小块。"""
    alb, h, rough, W, H = cv
    rx, ry = max(1.5, w * 0.5), max(1.2, hgt * 0.5)
    x0, x1, y0, y1 = _win(cx, cy, max(rx, ry) * 1.8, max(rx, ry) * 1.8, W, H)
    if x1 <= x0 or y1 <= y0:
        return
    u, v = _local(x0, x1, y0, y1, cx, cy, rot)
    r = np.maximum(np.abs(u) / rx, np.abs(v) / ry)
    m = np.clip((1.0 - r) * 7.0, 0.0, 1.0)
    chip = np.clip(1.12 - 0.58 * (np.abs(u) / rx + np.abs(v) / ry), 0.0, 1.0)
    m = m * chip
    ring = np.exp(-(((r - 1.16) / 0.18) ** 2))
    sl = (slice(y0, y1), slice(x0, x1))
    alb[sl] = _mixm(ring * 0.18, alb[sl], STONE_SHADOW)
    alb[sl] = _mixm(m * 0.94, alb[sl], _stone_col(tone))
    h[sl] = h[sl] - ring * 0.10 + m * 0.20
    rough[sl] = rough[sl] * (1.0 - m) + m * 0.88


def el_tuft(cv, cx, cy, ln, spread, nbl, rot, tone):
    """草簇 / 几根草须：n 根叶从根部成扇形散开 + 根下一小块压暗的土。"""
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


def el_smear(cv, cx, cy, w, hgt, rot, tone, col_a, col_b):
    """一小块糊上去的料（溅在收边上的泥点）。tone=0 取 B 的均色。"""
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


# ---------------------------------------------------------------- 收边块（逐块手摆）
def unit_block(cv, cx, cy, w, ln, rot, tone, spec, top):
    """一块收边件：方正顶面 + 立面（靠 h 的落差，明暗交给引擎）+ 四周接触暗。

    `top` = 顶面绝对高度（两侧主料都比它低 → 收边读成"砌起来的一道边"）。
    `turf` 类型额外带一条向 A 侧探出的翘边（草皮被切开的毯子边）。
    """
    alb, h, rough, W, H = cv
    rx, ry = max(1.5, w * 0.5), max(1.2, ln * 0.5)
    x0, x1, y0, y1 = _win(cx, cy, max(rx, ry) + 5, max(rx, ry) + 5, W, H)
    if x1 <= x0 or y1 <= y0:
        return
    u, v = _local(x0, x1, y0, y1, cx, cy, rot)
    r = np.maximum(np.abs(u) / rx, np.abs(v) / ry)
    m = np.clip((1.0 - r) * 9.0, 0.0, 1.0)
    corner = np.clip((np.abs(u) / rx + np.abs(v) / ry - 0.76) / 0.30, 0.0, 1.0)
    m = m * (1.0 - 0.28 * corner)                     # 手凿的方石：棱角略钝
    ring = np.exp(-(((r - 1.06) / 0.14) ** 2))
    sl = (slice(y0, y1), slice(x0, x1))
    col = _mixc(tone, spec["col"][0], spec["col"][1])
    alb[sl] = _mixm(ring * spec["joint"], alb[sl], spec["face"])
    alb[sl] = _mixm(m * 0.97, alb[sl], col)
    h[sl] = h[sl] * (1.0 - m) + top * m
    h[sl] = h[sl] - ring * 0.10
    rough[sl] = rough[sl] * (1.0 - m) + m * spec["rough"]
    if spec["lip"] > 0.0:                             # 草皮翘边：向 A 侧探出一小条
        lw = max(2.0, w * 0.22)
        xa = cx - rx - lw * 0.5
        x2, x3, y2, y3 = _win(xa, cy, lw, ln * 0.5, W, H)
        if x3 > x2 and y3 > y2:
            uu, vv = _local(x2, x3, y2, y3, xa, cy, rot)
            mm = np.clip((1.0 - np.maximum(np.abs(uu) / (lw * 0.5),
                                           np.abs(vv) / (ln * 0.5))) * 6.0, 0.0, 1.0)
            s2 = (slice(y2, y3), slice(x2, x3))
            alb[s2] = _mixm(mm * 0.78, alb[s2], col * 0.88)
            h[s2] = h[s2] * (1.0 - mm) + (top - 0.02) * mm


def draw_units(cv, units, xb, spec, raster, top):
    """沿放线**逐块**摆收边件；每块的方向偏移/长短/转角/明度都是人写的。"""
    y = 0.0
    placed = []
    for q in units:
        dx, ln, rot, tone = (float(q[0]), float(q[1]), float(q[2]), float(q[3]))
        ymid = y + ln * 0.5
        row = int(min(max(0, ymid * raster), CHART_H * raster - 1))
        cx = float(xb[row]) + dx * raster
        unit_block(cv, cx, ymid * raster, spec["w"] * raster, ln * raster,
                   rot, tone, spec, top)
        placed.append((ymid, dx, ln))
        y += ln
    return placed


def place(cv, e, xb, raster, cols):
    """缝里漏出的小碎屑：`e` 是人写在 MASTERS 里的那条数据。"""
    kind = e[0]
    y = float(e[2]) * raster
    row = int(min(max(0, y), CHART_H * raster - 1))
    cx = float(xb[row]) + float(e[1]) * raster
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
    """画一整幅（512 × 264）：两材质硬切 + 一道手摆收边 + 少量贴边碎屑。"""
    W, H = GAME_W * raster, CHART_H * raster
    fade = int(pair.get("fade", 20))
    albA, hA, rA = mosaic(pair["a"], W, H, master.get("seq_a", (0,)), raster, fade,
                          bool(pair.get("rot90_a")))
    albB, hB, rB = mosaic(pair["b"], W, H, master.get("seq_b", (1,)), raster, fade,
                          bool(pair.get("rot90_b")))
    xb = line_x(master["line"], raster)

    X = (np.arange(W, dtype=np.float64) + 0.5)[None, :]
    left = X < xb[:, None]                       # 左 = 材质 A（收边压在分界上）
    lift = float(pair.get("lift", 0.0))
    alb = np.where(left[..., None], albA, albB)
    h = np.where(left, HB_A + HM * hA + lift, HB_B + HM * hB)
    rough = np.where(left, rA, rB)

    spec = EDGES[pair["edge"]]
    top = HB_A + HM * 0.5 + lift + spec["rise"]
    cv = [alb, h, rough, W, H]
    placed = draw_units(cv, master["units"], xb, spec, raster, top)
    cols = (albA.reshape(-1, 3).mean(axis=0), albB.reshape(-1, 3).mean(axis=0))
    for e in master["els"]:
        place(cv, e, xb, raster, cols)
    return cv[0], cv[1], cv[2], xb, placed, top


def _box2(a, k=RASTER):
    """k×k 箱式降采样（超采样收口）。"""
    if k <= 1:
        return a
    h, w = a.shape[0] // k * k, a.shape[1] // k * k
    a = a[:h, :w]
    return a.reshape(h // k, k, w // k, k, *a.shape[2:]).mean(axis=(1, 3))


def generate(key, raster=RASTER):
    """出一件（按 key 里的材质对 / 带 / 变体号）。返回 alb/nrm/rough + 元数据。"""
    rec = _PIECE_OF[key]
    pair, master = _PAIR_OF[rec["pair"]], _MASTER_OF[rec["pair"]][rec["variant"] - 1]
    alb, h, rough, xb, placed, top = build_chart(pair, master, raster)
    y0, y1 = BANDS[rec["band"]]
    sl = (slice(y0 * raster, y1 * raster), slice(0, alb.shape[1]))
    alb, h, rough = alb[sl], h[sl], rough[sl]
    out = G._packw(alb, h, rough, alb.shape[1], alb.shape[0],
                   seed=7000 + rec["pair_idx"] * 97 + rec["variant"] * 13,
                   relief_m=RELIEF_M, ao=0.30, nstr=0.95)
    nrm = G.normal_map_w(out["h"], alb.shape[1], alb.shape[0], RELIEF_M, out["nstr"])
    a_down, n_down, r_down = _box2(out["alb"]), _box2(nrm), _box2(out["rough"])
    return {"alb": a_down, "nrm": n_down, "rough": r_down,
            "relief_m": RELIEF_M, "nstr": out["nstr"],
            "size": (a_down.shape[1], a_down.shape[0]),
            "pair": pair, "master": master, "rec": rec,
            "units": placed, "kerb_top": top}


# ============================================================ 落盘
def _stats(alb):
    return [round(float(alb[..., i].mean()), 3) for i in range(3)]


def units_in_band(master, band, pad=6.0):
    """这件实际摆到的收边块数（整幅上一次摆好、按带切开）。"""
    y0, y1 = BANDS[band]
    y = 0.0
    n = 0
    for q in master["units"]:
        ln = float(q[1])
        ymid = y + ln * 0.5
        if y0 - ln * 0.5 - pad <= ymid < y1 + ln * 0.5 + pad:
            n += 1
        y += ln
    return n


def elements_in_band(master, band, pad=22.0):
    """这件实际摆到的贴边碎屑条数。"""
    y0, y1 = BANDS[band]
    return sum(1 for e in master["els"]
               if y0 - pad <= float(e[2]) < y1 + pad)


def export_all(out_dir, quiet=False):
    """全部件：src/<key>_alb|nrm|rgh.png + <key>.json + _manifest.json。"""
    os.makedirs(os.path.join(out_dir, "src"), exist_ok=True)
    recs = []
    for key in piece_keys():
        d = generate(key)
        pair, rec = d["pair"], d["rec"]
        nx, ny = d["size"]
        spec = EDGES[pair["edge"]]
        src = os.path.join(out_dir, "src")
        G._save_png(d["alb"], os.path.join(src, "%s_alb.png" % key), "sRGB")
        G._save_png(d["nrm"], os.path.join(src, "%s_nrm.png" % key), "Non-Color")
        G._save_png(d["rough"], os.path.join(src, "%s_rgh.png" % key), "Non-Color")
        nunit = units_in_band(d["master"], rec["band"])
        nel = elements_in_band(d["master"], rec["band"])
        meta = {
            "key": key,
            "name": "手工收边过渡·%s·%s·变体%d" % (pair["name"], BAND_CN[rec["band"]],
                                                rec["variant"]),
            "kind": "transition",
            "master": rec["pair"],
            "handmade": True,
            "variant": rec["variant"],
            "pair": [pair["a"], pair["b"]],
            "pair_name": pair["name"],
            "band": rec["band"],
            "tier": "handmade",
            "edge_restraint": {
                "type": pair["edge"],
                "name": spec["name"],
                "width_px": spec["w"],
                "note": spec["note"],
                "units_in_this_piece": nunit,
                "units_master": len(d["master"]["units"]),
                "unit_ledger": "每块的方向偏移/长短/转角/明度写死在 MASTERS[*].units",
                "spill_elements": nel,
                "spill_note": "只写贴着收边的少量碎屑/草须，不做大面积互渗",
            },
            "px": [nx, ny],
            "cells_w": nx // CELL,
            "px_per_cell": CELL,
            "supersample": RASTER,
            "edge_convention": "左=材质A、右=材质B，**两者在收边处硬切**；收边（%s）由逐块手摆的件"
                               "连成一条；两外侧各接对应材质的纯料面（分段/补丁）" % spec["name"],
            "x_tileable": False,
            "y_tileable": False,
            "note": pair["note"],
            "lighting_neutral": "albedo + 微 AO（收边立面靠法线出层次，不烘方向光）；光源=垂直向下 SUN",
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
            print("  %-34s %-14s %-6s %-6s 块%2d 屑%2d  meanRGB=(%.2f,%.2f,%.2f) %dx%d"
                  % (key, pair["name"], BAND_CN[rec["band"]], spec["name"],
                     nunit, nel, meta["mean_srgb"][0], meta["mean_srgb"][1],
                     meta["mean_srgb"][2], nx, ny))
    man = {
        "spec": "手工预制过渡件库 v2（硬质收边 + 逐块手摆；红警式预制块）",
        "why": "创始人纠偏：现实里两块地之间有路坎（edge restraint），过渡=一条硬质收边，"
               "不是两种材质大面积互相渗透",
        "chart_px": [GAME_W, CHART_H],
        "bands_px": {"shoulder": G.STRIP_SHOULDER, "kerb": G.STRIP_KERB,
                     "road": G.STRIP_ROAD},
        "band_note": "放线/收边/碎屑在一整幅 264px（路肩96+路缘8+道路160）上做一次，再按带裁剪；"
                     "路缘带 8px 不单出件（过渡由路肩件+道路件夹住）",
        "edge_kinds": {k: dict(name=v["name"], width_px=v["w"], note=v["note"])
                       for k, v in EDGES.items()},
        "raster": RASTER,
        "pairs": [dict(key=p["key"], name=p["name"], left=p["a"], right=p["b"],
                       edge=p["edge"], bands=list(p["bands"]), usage=p["usage"])
                  for p in PAIRS],
        "pieces": [dict(key=r["key"], master=r["master"], band=r["band"],
                        variant=r["variant"], sides=r["sides"],
                        edge=r["edge_restraint"]["type"],
                        units=r["edge_restraint"]["units_in_this_piece"],
                        spill=r["edge_restraint"]["spill_elements"])
                   for r in recs],
    }
    with open(os.path.join(out_dir, "_manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(man, fh, ensure_ascii=False, indent=1)
    return recs


def render_dir():
    return os.path.join(os.path.dirname(os.path.dirname(HERE)),
                        "stick-world", "temp", "ground_tiles", "transitions")


# ============================================================ 自检
def selfcheck():
    """查四件事：收边盖满整幅 / 每块偏移不露边 / 碎屑贴着收边 / 放线两侧留够料面。"""
    bad = 0
    for key in piece_keys():
        rec = _PIECE_OF[key]
        pair = _PAIR_OF[rec["pair"]]
        master = _MASTER_OF[rec["pair"]][rec["variant"] - 1]
        spec = EDGES[pair["edge"]]
        total = sum(float(q[1]) for q in master["units"])
        if total < CHART_H - 1.0:
            bad += 1
            print("  [缺口] %s 收边只铺了 %.0fpx（要 ≥%d）" % (key, total, CHART_H))
        for q in master["units"]:
            if abs(float(q[0])) > spec["w"] * 0.5 - 2.0:
                bad += 1
                print("  [露边] %s 某块偏移 %.0f 超出 %.0fpx 进深"
                      % (key, q[0], spec["w"]))
        lim = spec["w"] * 0.5 + 16.0
        for e in master["els"]:
            if abs(float(e[1])) > lim:
                bad += 1
                print("  [离边] %s 碎屑 dx=%.0f 离收边太远（>%.0f）" % (key, e[1], lim))
        xb = line_x(master["line"], 1)
        if xb.min() < 150 or xb.max() > GAME_W - 150:
            bad += 1
            print("  [偏线] %s 放线 x∈[%.0f,%.0f]（两侧料面不足）"
                  % (key, xb.min(), xb.max()))
    print("手工收边过渡自检：%s" % ("OK" if bad == 0 else "%d 处需修" % bad))
    return bad


# ============================================================ 登记表
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


# ============================================================ 手工数据
# 材质对：a=左（材质 A）/ b=右（材质 B）；edge = 收边类型；lift = A 侧比 B 侧高多少（h 单位）
PAIRS = [
    dict(key="flagstone_dirt", a="flagstone", b="dirt_rut", name="石板↔土",
         edge="sett", bands=("shoulder", "road"), lift=0.10,
         note="石板铺装边上砌一列镶边石压住板边；石头外就是踩实的土面（土面低一档）",
         usage="城区(center/中环)石板铺装与土面/空地交界；拆掉房子后的空地四周"),
    dict(key="brick_gravel", a="brick_pave", b="gravel", name="旧砖↔碎石",
         edge="soldier", bands=("shoulder", "road"), lift=0.08,
         note="砖铺装边立砌一列砖牙收边，砖牙外是碎石垫层；砖牙缝里塞着碎石与碎砖",
         usage="中环(mid)砖铺装与碎石垫层/工地/马厩前交界"),
    dict(key="rammed_grass", a="rammed_earth", b="grass", name="夯土↔草皮",
         edge="turf", bands=("shoulder", "road"), lift=-0.14,
         note="草皮被切成毯子边：边缘略翘、切口露土，土面被踩低一档；只有几根草须漫过来",
         usage="edge 档夯土路/院坝与草地交界；城墙外的踩踏路缘"),
    dict(key="gravel_grass", a="gravel", b="grass", name="砾石↔草皮",
         edge="sett", bands=("shoulder", "road"), lift=0.08,
         note="矮路缘石挡住砾石不往草里跑；草把石缝长满，只有零散几颗砾石滚过界",
         usage="edge 档砾石巷与草皮交界；村庄边缘最常见的一道收边"),
    dict(key="boardwalk_dirt", a="boardwalk", b="dirt_rut", name="木栈道↔泥地",
         edge="sleeper", bands=("road",), lift=0.50, fade=0, rot90_a=True,
         note="栈道板端顶在一条枕木横档上（板长轴垂直于横档）；横档外就是泥，档面溅着泥点",
         usage="商铺前檐廊、码头木栈道的长边/端头与泥地交界（栈道整体抬高一级）"),
]

#: 手写母版：每对 3 变体
#   line  = 放线（缓折线，工人的线）
#   units = 收边件：**逐块**写 (方向偏移, 沿边长短, 转角, 明度)；从 y=0 起沿 y 顺序铺
#   els   = 缝里漏出的少量碎屑 (kind, dx, y, ...)：st 石子 / peb 碎屑 / brk 碎砖 / tuft 草须 / smear 泥点
MASTERS = {
    # ================================================================ 石板 ↔ 土（镶边石）
    "flagstone_dirt": [
        dict(seq_a=(0, 2, 1, 3), seq_b=(1, 0, 3, 2),
             line=[(248, 0), (242, 62), (252, 124), (245, 186), (250, 264)],
             units=[(1, 26, -2, 0.55), (3, 24, 1, 0.62), (-2, 28, -3, 0.48),
                    (2, 25, -1, 0.66), (-3, 27, 2, 0.52), (1, 24, -2, 0.60),
                    (4, 26, 1, 0.44), (-1, 25, -3, 0.58), (2, 27, 2, 0.64),
                    (-2, 28, -1, 0.50), (1, 26, 1, 0.56)],
             els=[("brk", 13, 42, 13, 9, 16, 0.58),
                  ("peb", 14, 112, 12, 9, 3, 0.50),
                  ("tuft", -12, 170, 12, 26, 3, 8, 0.20),
                  ("st", 12, 236, 12, 10, -18, 0.60)]),
        dict(seq_a=(1, 3, 2, 0), seq_b=(2, 0, 3, 1),
             line=[(240, 0), (250, 58), (244, 124), (256, 188), (246, 264)],
             units=[(-1, 24, 2, 0.48), (2, 26, -1, 0.58), (3, 22, 2, 0.66),
                    (-2, 27, 1, 0.52), (1, 25, -2, 0.62), (-3, 23, 3, 0.44),
                    (2, 28, -1, 0.56), (-1, 26, 2, 0.68), (3, 24, -2, 0.50),
                    (-2, 25, 1, 0.60), (1, 26, -1, 0.46)],
             els=[("peb", 13, 64, 12, 9, 3, 0.52),
                  ("st", -11, 136, 12, 10, 14, 0.62),
                  ("tuft", -12, 198, 11, 24, 3, 6, 0.25),
                  ("brk", 12, 248, 12, 8, -20, 0.56)]),
        dict(seq_a=(3, 0, 2, 1), seq_b=(0, 2, 1, 3),
             line=[(252, 0), (246, 50), (258, 114), (248, 178), (254, 264)],
             units=[(2, 26, 1, 0.62), (-1, 27, -2, 0.52), (3, 24, 2, 0.58),
                    (-2, 26, -1, 0.66), (1, 29, 3, 0.46), (-3, 25, 1, 0.60),
                    (2, 24, -2, 0.54), (-1, 27, 2, 0.64), (3, 26, -1, 0.48),
                    (-2, 26, 2, 0.58), (1, 25, -1, 0.50)],
             els=[("st", 12, 54, 13, 10, 20, 0.56),
                  ("tuft", -11, 124, 12, 24, 3, 12, 0.22),
                  ("peb", 13, 182, 11, 8, 3, 0.48),
                  ("brk", 12, 240, 12, 9, -14, 0.60)]),
    ],
    # ================================================================ 旧砖 ↔ 碎石（立砌砖牙）
    "brick_gravel": [
        dict(seq_a=(0, 1, 3, 2), seq_b=(2, 3, 0, 1),
             line=[(250, 0), (246, 60), (254, 130), (248, 196), (252, 264)],
             units=[(0, 8, 0, 0.58), (1, 8, -2, 0.46), (-1, 8, 1, 0.62),
                    (0, 8, 0, 0.52), (1, 8, -1, 0.66), (-1, 8, 2, 0.44),
                    (0, 8, 0, 0.56), (1, 8, -2, 0.60), (-1, 8, 1, 0.48),
                    (0, 8, 0, 0.64), (1, 8, -1, 0.52), (-1, 8, 2, 0.58),
                    (0, 8, 0, 0.46), (1, 8, -2, 0.62), (-1, 8, 1, 0.54),
                    (0, 8, 0, 0.60), (1, 8, -1, 0.48), (-1, 8, 2, 0.66),
                    (0, 8, 0, 0.52), (1, 8, -2, 0.58), (-1, 8, 1, 0.44),
                    (0, 8, 0, 0.62), (1, 8, -1, 0.56), (-1, 8, 2, 0.50),
                    (0, 8, 0, 0.64), (1, 8, -2, 0.46), (-1, 8, 1, 0.60),
                    (0, 8, 0, 0.54), (1, 8, -1, 0.62), (-1, 8, 2, 0.48),
                    (0, 8, 0, 0.58), (1, 8, -2, 0.52), (-1, 8, 1, 0.64)],
             els=[("brk", 13, 76, 12, 8, 18, 0.60),
                  ("peb", 14, 152, 11, 8, 3, 0.50),
                  ("tuft", -13, 216, 11, 22, 3, 8, 0.25)]),
        dict(seq_a=(2, 0, 1, 3), seq_b=(1, 2, 3, 0),
             line=[(244, 0), (252, 70), (246, 140), (254, 210), (248, 264)],
             units=[(-1, 8, 1, 0.50), (0, 8, 0, 0.62), (1, 8, -2, 0.44),
                    (0, 8, 0, 0.58), (-1, 8, 2, 0.52), (1, 8, -1, 0.66),
                    (0, 8, 0, 0.48), (-1, 8, 1, 0.60), (1, 8, -2, 0.54),
                    (0, 8, 0, 0.64), (-1, 8, 2, 0.46), (1, 8, -1, 0.58),
                    (0, 8, 0, 0.52), (-1, 8, 1, 0.62), (1, 8, -2, 0.50),
                    (0, 8, 0, 0.66), (-1, 8, 2, 0.44), (1, 8, -1, 0.60),
                    (0, 8, 0, 0.56), (-1, 8, 1, 0.64), (1, 8, -2, 0.48),
                    (0, 8, 0, 0.58), (-1, 8, 2, 0.52), (1, 8, -1, 0.66),
                    (0, 8, 0, 0.46), (-1, 8, 1, 0.60), (1, 8, -2, 0.54),
                    (0, 8, 0, 0.62), (-1, 8, 2, 0.50), (1, 8, -1, 0.58),
                    (0, 8, 0, 0.64), (-1, 8, 1, 0.48), (1, 8, -2, 0.56)],
             els=[("peb", 13, 46, 12, 9, 3, 0.54),
                  ("brk", 12, 120, 12, 8, -16, 0.58),
                  ("st", -12, 188, 12, 9, 12, 0.60)]),
        dict(seq_a=(3, 2, 0, 1), seq_b=(0, 3, 2, 1),
             line=[(252, 0), (248, 88), (256, 170), (250, 264)],
             units=[(1, 8, -1, 0.62), (0, 8, 0, 0.48), (-1, 8, 2, 0.58),
                    (1, 8, -2, 0.52), (0, 8, 0, 0.66), (-1, 8, 1, 0.44),
                    (1, 8, -1, 0.60), (0, 8, 0, 0.54), (-1, 8, 2, 0.64),
                    (1, 8, -2, 0.46), (0, 8, 0, 0.58), (-1, 8, 1, 0.62),
                    (1, 8, -1, 0.50), (0, 8, 0, 0.66), (-1, 8, 2, 0.56),
                    (1, 8, -2, 0.48), (0, 8, 0, 0.60), (-1, 8, 1, 0.64),
                    (1, 8, -1, 0.44), (0, 8, 0, 0.58), (-1, 8, 2, 0.52),
                    (1, 8, -2, 0.62), (0, 8, 0, 0.46), (-1, 8, 1, 0.60),
                    (1, 8, -1, 0.54), (0, 8, 0, 0.64), (-1, 8, 2, 0.50),
                    (1, 8, -2, 0.58), (0, 8, 0, 0.62), (-1, 8, 1, 0.48),
                    (1, 8, -1, 0.56), (0, 8, 0, 0.66), (-1, 8, 2, 0.52)],
             els=[("brk", 13, 62, 13, 8, 20, 0.62),
                  ("brk", -12, 170, 12, 8, -12, 0.56),
                  ("tuft", -13, 242, 11, 20, 3, 10, 0.20)]),
    ],
    # ================================================================ 夯土 ↔ 草皮（草皮切边）
    "rammed_grass": [
        dict(seq_a=(0, 3, 1, 2), seq_b=(2, 1, 3, 0),
             line=[(252, 0), (246, 70), (254, 140), (247, 210), (252, 264)],
             units=[(1, 28, 2, 0.55), (-2, 30, -1, 0.62), (2, 26, 1, 0.48),
                    (-1, 32, -2, 0.58), (3, 28, 2, 0.66), (-2, 26, -1, 0.52),
                    (1, 30, 1, 0.60), (-3, 28, -2, 0.46), (2, 26, 2, 0.64),
                    (-1, 28, -1, 0.56)],
             els=[("tuft", -13, 60, 14, 30, 3, 170, 0.35),
                  ("tuft", -12, 144, 13, 26, 3, 168, 0.30),
                  ("peb", 13, 106, 12, 9, 3, 0.52),
                  ("tuft", -13, 234, 14, 28, 3, 172, 0.40)]),
        dict(seq_a=(1, 2, 3, 0), seq_b=(0, 3, 1, 2),
             line=[(246, 0), (254, 80), (248, 150), (256, 216), (250, 264)],
             units=[(2, 30, 1, 0.62), (-1, 28, -2, 0.50), (1, 32, 2, 0.58),
                    (-2, 26, -1, 0.66), (2, 28, 1, 0.46), (-3, 30, -2, 0.54),
                    (1, 26, 2, 0.60), (-1, 32, -1, 0.44), (2, 28, 2, 0.62),
                    (-2, 26, -1, 0.52)],
             els=[("tuft", -12, 74, 13, 28, 3, 166, 0.30),
                  ("tuft", -13, 180, 14, 30, 3, 172, 0.25),
                  ("brk", 13, 126, 12, 9, 18, 0.54),
                  ("tuft", -12, 250, 12, 24, 3, 170, 0.35)]),
        dict(seq_a=(2, 0, 3, 1), seq_b=(3, 1, 0, 2),
             line=[(250, 0), (248, 56), (256, 132), (249, 204), (253, 264)],
             units=[(0, 26, 2, 0.50), (-2, 30, -1, 0.58), (2, 28, 1, 0.64),
                    (-3, 26, -2, 0.46), (1, 32, 2, 0.56), (-1, 28, -1, 0.62),
                    (2, 26, 1, 0.50), (-2, 30, 2, 0.60), (1, 28, -1, 0.48),
                    (-3, 26, 2, 0.66), (2, 26, 1, 0.54)],
             els=[("tuft", -13, 44, 13, 26, 3, 164, 0.32),
                  ("peb", 13, 150, 12, 9, 3, 0.50),
                  ("tuft", -12, 228, 14, 30, 3, 174, 0.28)]),
    ],
    # ================================================================ 砾石 ↔ 草皮（矮路缘石）
    "gravel_grass": [
        dict(seq_a=(0, 2, 3, 1), seq_b=(1, 0, 2, 3),
             line=[(250, 0), (245, 72), (255, 146), (248, 214), (253, 264)],
             units=[(1, 24, -2, 0.56), (-2, 26, 1, 0.50), (2, 23, -1, 0.62),
                    (-1, 25, 2, 0.46), (3, 24, -2, 0.58), (-2, 27, 1, 0.64),
                    (1, 23, -1, 0.52), (-3, 25, 2, 0.60), (2, 24, -1, 0.48),
                    (-1, 26, 1, 0.66), (1, 26, -2, 0.54)],
             els=[("peb", 13, 68, 13, 9, 3, 0.50),
                  ("tuft", -11, 142, 12, 24, 3, 166, 0.30),
                  ("peb", 12, 222, 12, 9, 3, 0.54)]),
        dict(seq_a=(1, 3, 0, 2), seq_b=(2, 1, 3, 0),
             line=[(244, 0), (252, 64), (246, 140), (254, 206), (248, 264)],
             units=[(-1, 23, 1, 0.52), (2, 25, -2, 0.60), (3, 22, 2, 0.46),
                    (-2, 26, 1, 0.64), (1, 24, -1, 0.50), (-3, 25, 2, 0.58),
                    (2, 23, -2, 0.48), (1, 26, 1, 0.62), (-2, 24, -1, 0.54),
                    (3, 25, 2, 0.66), (-1, 24, 1, 0.56)],
             els=[("peb", 12, 88, 13, 9, 4, 0.52),
                  ("tuft", -12, 174, 12, 26, 3, 170, 0.28),
                  ("st", 13, 236, 12, 9, 14, 0.58)]),
        dict(seq_a=(2, 1, 3, 0), seq_b=(0, 2, 1, 3),
             line=[(252, 0), (247, 96), (257, 164), (250, 264)],
             units=[(2, 25, -1, 0.60), (1, 23, 2, 0.48), (-2, 26, -2, 0.56),
                    (3, 24, 1, 0.64), (-1, 25, -1, 0.50), (2, 22, 2, 0.58),
                    (-3, 26, -2, 0.46), (1, 24, 1, 0.62), (-2, 25, -1, 0.52),
                    (2, 24, 2, 0.66), (-1, 25, -1, 0.56)],
             els=[("tuft", -11, 52, 12, 24, 3, 168, 0.30),
                  ("peb", 13, 158, 12, 9, 3, 0.52),
                  ("brk", 12, 244, 12, 8, -18, 0.56)]),
    ],
    # ================================================================ 木栈道 ↔ 泥地（端头横档）
    "boardwalk_dirt": [
        dict(seq_a=(0,), seq_b=(1,),
             line=[(266, 0), (262, 90), (268, 180), (264, 264)],
             units=[(1, 132, 0, 0.58), (-1, 132, 0, 0.62)],
             els=[("peb", 15, 58, 14, 10, 4, 0.48),
                  ("peb", 17, 182, 15, 10, 4, 0.52),
                  ("brk", 14, 238, 13, 9, 16, 0.58),
                  ("smear", 13, 118, 24, 16, 4, 0.0)]),
        dict(seq_a=(2,), seq_b=(3,),
             line=[(262, 0), (268, 96), (260, 186), (266, 264)],
             units=[(-1, 148, 0, 0.60), (1, 116, 0, 0.56)],
             els=[("peb", 16, 44, 14, 10, 4, 0.52),
                  ("smear", 15, 96, 22, 15, 4, 0.0),
                  ("peb", 15, 196, 15, 10, 4, 0.48),
                  ("st", 14, 252, 13, 10, -14, 0.58)]),
        dict(seq_a=(3,), seq_b=(2,),
             line=[(266, 0), (261, 72), (269, 158), (263, 264)],
             units=[(1, 120, 0, 0.54), (-1, 88, 0, 0.62), (1, 56, 0, 0.58)],
             els=[("peb", 16, 72, 14, 10, 4, 0.50),
                  ("smear", 14, 150, 26, 17, 4, 0.0),
                  ("brk", 14, 222, 13, 9, -16, 0.60),
                  ("peb", 15, 262, 14, 10, 4, 0.46)]),
    ],
}

_register()


# ============================================================ main
def main():
    out = render_dir()
    os.makedirs(os.path.join(out, "src"), exist_ok=True)
    print("== 手工收边过渡件落盘 →", out)
    recs = export_all(out)
    print("GTX_OK", len(recs))
    selfcheck()


if __name__ == "__main__":
    main()
