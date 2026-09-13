# -*- coding: utf-8 -*-
"""ground_tiles.py —— 城市地面「真无缝」可平铺贴图库（建筑管线 v3）

为什么单独一套
--------------
现行管线只有一块素色 `ground`（世界空间程序纹理，给大平面用，**不是**可平铺贴图）。
游戏内地面是**平铺贴图**（1 格 = 32px 基准），需要：砖地面、土地面、各式各样
城市里会出现的地面 —— 且**左右/上下边缘必须能对接**。

无缝是怎么保证的（本文件的全部技术含量就在这一条）
--------------------------------------------------
程序纹理（`materials.py` 的 `_b_ground`）用世界坐标噪声，天然看不到接缝，但把它
裁成一张贴图就必然在边界断掉。本库反过来做：**图案从一开始就定义在周期域上**，
所以任何一层都不可能断：

1. **逐像素颗粒** —— 纯哈希白噪声，本身无结构，接缝不存在。
2. **值噪声 / fBm** —— 整数格点哈希，取格坐标时 `mod(周期)`；贴图恰好跨整数个
   格点，于是 `u=0` 与 `u=1` 取到的是同一个格点 → 精确无缝（`pnoise` / `pfbm`）。
3. **Worley（石块 / 石板 / 砾石）** —— 特征点定义在**周期格**上（格坐标取模后
   哈希），3×3 邻域搜索时越界格索引也取模 → 边界的特征点与对侧完全同一颗石子。
4. **砌块类（砖 / 石板 / 木栈道）** —— 份数取 `1.68m / 现实尺寸` 的**最近整数**
   （`_cells`），所以横缝纵缝都整好落在贴图边界；错缝砖的错位量为半砖，边界相位
   不变。木栈道的板端横缝干脆**故意摆在贴图边界**（现实中板端本来就接在龙骨上），
   把接缝藏在真实结构里。
5. **风纹 / 夯层带** —— `sin(2π·k·V + 周期噪声扰动)`，k 为整数 → 周期函数。

尺度契约（与 materials.py 同源，只读取不改）
--------------------------------------------
* `materials.M_PER_UV = 0.42`（1 UV = 1 格 = 32px = 42cm）。
* 本库一张贴图 = **4 格 = 128px = 1.68m**（游戏档 128×128；高清档 512×512 是同一
  块 1.68m 的高密度版，305 px/m）。
* 所有图案按**现实尺寸（米）**标定：`_cells(0.084)` = 8.4cm 的份数 = 20。
  砖 21×10.5cm、小鹅卵石 8.4cm、大鹅卵石 14cm、石板 42cm、木板 21cm、
  夯层 14cm、风纹波距 9.3cm、车辙宽 13cm —— 都在创始人给的现实区间内。
* **低分辨率档会按分辨率截断 fBm 层数**（`_oct_for`，最细层不许细于 ~2.2px），
  所以 128 档不是 512 档的降采样（那会糊成一团摩尔纹），而是同一图案在低密度下
  重新取样的干净版本。

导出（`stick-world/temp/ground_tiles/`）
----------------------------------------
    <key>.png            512 高清档（俯视正交渲染）
    <key>_128.png        128 游戏档（1 格 32px，4 格一张）
    <key>.json           现实特征尺寸 / 适用区域 / 平铺尺寸
    src/<key>_alb[_128].png   未打光反照率（游戏可直接用，sRGB）
    src/<key>_nrm[_128].png   切线空间法线（Non-Color）
    src/<key>_rgh[_128].png   粗糙度（Non-Color）

对外接口
--------
    SPECS                 12 种地面登记表
    generate(key, n)      生成某分辨率的三张 numpy 底图
    export_all(out_dir)   落盘全部贴图 + json，返回记录表
    tile_material(key, n, img_dir)  建可平铺材质（UV 0~1 = 一张贴图）
"""

import json
import math
import os
import sys

import numpy as np

import bpy

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import materials as M          # 只读：借 M_PER_UV / PX_PER_UNIT 两个常量，不改它

#: 1 格 = 32px（与 materials.PX_PER_UNIT / buildings.CELL 同源）
CELL = int(M.PX_PER_UNIT)
#: 一张贴图跨 4 格
TILE_CELLS = 4
#: 游戏档像素 = 4 格 × 32px
GAME_PX = TILE_CELLS * CELL
HD_PX = 512
#: 一张贴图覆盖的现实长度（米）
TILE_M = TILE_CELLS * M.M_PER_UV          # 1.68 m


# ============================================================ 数值工具
#: 采样网格的像素偏移（用于"平移一个整像素后图案应当不变"的**周期性证明**：
#: `generate(key, n, shift=(dx,dy))` 必须等于 `np.roll(generate(key, n), (-dy,-dx))`。
#: 所有逐像素哈希（`_speck` / `_dots` / `_nails`）都必须把这个偏移算进去，
#: 否则它们不是"世界位置的函数"，平移校验会在它们身上假失败。
_SHIFT = (0, 0)
#: 全库哈希种子偏移：变体只用改这个（+ `_SHIFT` 相位），就能让斑驳位置 / 接缝抖动 /
#: 逐块色全部换一套，而**不动任何一个不变量**（周期性、光照中性都不受影响）。
_SEEDOFF = 0


def _uv(n):
    """像素中心归一化坐标。U 沿轴 1（列），V 沿轴 0（行，第 0 行在图片底部）。"""
    ix = np.arange(n, dtype=np.float64) + 0.5 + float(_SHIFT[0])
    iy = np.arange(n, dtype=np.float64) + 0.5 + float(_SHIFT[1])
    U, V = np.meshgrid(ix / float(n), iy / float(n))
    return U, V


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0 + 1e-12), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def lerp(a, b, t):
    return a + (b - a) * t


def _c3(x, shape):
    a = np.asarray(x, dtype=np.float64)
    if a.ndim == 0:
        return np.full(shape, float(a))
    if a.ndim == 1:
        return np.broadcast_to(a.reshape((1, 1) + a.shape), shape).astype(np.float64)
    if a.ndim == 2:
        return np.repeat(a[..., None], 3, axis=2).astype(np.float64)
    return a.astype(np.float64)


def cmix(t, a, b):
    """按 t（H,W）在 a、b 之间混色；a/b 可为 3 元组、灰度图或彩色图。"""
    shape = t.shape + (3,)
    A = _c3(a, shape)
    B = _c3(b, shape)
    return A + (B - A) * t[..., None]


def cshade(col, k):
    kk = np.asarray(k, dtype=np.float64)
    return col * (kk[..., None] if kk.ndim == 2 else kk)


def pblur(a, r=1):
    """周期盒式模糊（np.roll 环绕 → 无缝）。"""
    out = a
    for _ in range(max(0, int(r))):
        out = (out + np.roll(out, 1, 0) + np.roll(out, -1, 0)
               + np.roll(out, 1, 1) + np.roll(out, -1, 1)) * 0.2
    return out


def wdist(t, c):
    """V 向**环绕距离**（0~0.5）。做车辙 / 踩踏亮径这类"定点高斯"必须用它：
    直接写 `exp(-((V-c)/s)^2)` 只在 V∈[0,1] 上连续，不是 1-周期函数（平移校验会
    露出残差），换用环绕距离后就严格周期了。"""
    d = np.abs(np.mod(t, 1.0) - c)
    return np.minimum(d, 1.0 - d)


def _hash01(ix, iy, seed):
    """整数格点 → [0,1)。入参必须非负（调用方先取模）。

    种子统一叠 `_SEEDOFF`（变体开关）——全库所有随机都从这一个函数出，所以"换变体"
    等价于"换一整套随机"，不需要逐个生成器改种子。
    """
    x = np.asarray(ix, dtype=np.int64).astype(np.uint64)
    y = np.asarray(iy, dtype=np.int64).astype(np.uint64)
    s = np.uint64((int(seed) + int(_SEEDOFF)) * 2654435761 & 0xFFFFFFFF)
    h = x * np.uint64(0x9E3779B97F4A7C15) + y * np.uint64(0xC2B2AE3D27D4EB4F) + s
    with np.errstate(over="ignore"):
        h = h ^ (h >> np.uint64(30))
        h = h * np.uint64(0xBF58476D1CE4E5B9)
        h = h ^ (h >> np.uint64(27))
        h = h * np.uint64(0x94D049BB133111EB)
        h = h ^ (h >> np.uint64(31))
    return (h >> np.uint64(11)).astype(np.float64) * (1.0 / float(1 << 53))


def pnoise(x, y, pu, pv, seed):
    """周期值噪声。x ∈ [0,pu)、y ∈ [0,pv) 的连续格坐标（越界内部取模）。"""
    xi = np.floor(x)
    yi = np.floor(y)
    fx = x - xi
    fy = y - yi
    xi = xi.astype(np.int64)
    yi = yi.astype(np.int64)
    sx = fx * fx * (3.0 - 2.0 * fx)
    sy = fy * fy * (3.0 - 2.0 * fy)
    x0 = np.mod(xi, pu)
    x1 = np.mod(xi + 1, pu)
    y0 = np.mod(yi, pv)
    y1 = np.mod(yi + 1, pv)
    c00 = _hash01(x0, y0, seed)
    c10 = _hash01(x1, y0, seed)
    c01 = _hash01(x0, y1, seed)
    c11 = _hash01(x1, y1, seed)
    a = c00 + (c10 - c00) * sx
    b = c01 + (c11 - c01) * sx
    return a + (b - a) * sy


def _oct_for(finest_px, want, min_px=2.2):
    """限制 fBm 层数：最细一层在贴图里不小于 ~2.2px（否则低分辨率档变摩尔纹）。"""
    o = int(want)
    while o > 1 and finest_px / (2.0 ** (o - 1)) < min_px:
        o -= 1
    return o


def _k_count(metres, n):
    k = max(1, int(round(TILE_M / float(metres))))
    return min(k, max(1, n // 3))


def pfbm(x, y, pu, pv, seed, oct=4, gain=0.5):
    tot = np.zeros(x.shape)
    amp = 1.0
    norm = 0.0
    for o in range(int(oct)):
        m = 2 ** o
        tot = tot + amp * pnoise(x * m, y * m, pu * m, pv * m, seed + o * 17)
        norm += amp
        amp *= gain
    return tot / norm


def gnoise(U, V, metres, n, seed, oct=3, gain=0.5):
    """各向同性噪声，特征尺度 ≈ metres（现实尺寸，自动按分辨率截层）。"""
    k = _k_count(metres, n)
    o = _oct_for(n / float(k), oct)
    return pfbm(U * k, V * k, k, k, seed, o, gain)


def gnoise2(U, V, mu, mv, n, seed, oct=3, gain=0.5):
    """各向异性噪声：U 向特征尺度 mu、V 向 mv（做草叶、木纹的"顺纹"）。"""
    ku = _k_count(mu, n)
    kv = _k_count(mv, n)
    o = _oct_for(min(n / float(ku), n / float(kv)), oct)
    return pfbm(U * ku, V * kv, ku, kv, seed, o, gain)


def pworley(x, y, pu, pv, seed, jitter=0.85):
    """周期 Worley：返回 (f1, f2, 所在格的哈希)。特征点在周期格上 → 精确无缝。"""
    xi = np.floor(x).astype(np.int64)
    yi = np.floor(y).astype(np.int64)
    f1 = np.full(x.shape, 1e9)
    f2 = np.full(x.shape, 1e9)
    cid = np.zeros(x.shape)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            cx = xi + dx
            cy = yi + dy
            wx = np.mod(cx, pu)
            wy = np.mod(cy, pv)
            r1 = _hash01(wx, wy, seed)
            r2 = _hash01(wx, wy, seed + 991)
            r3 = _hash01(wx, wy, seed + 1777)
            px = cx + 0.5 + (r1 - 0.5) * jitter
            py = cy + 0.5 + (r2 - 0.5) * jitter
            d = np.hypot(x - px, y - py)
            lt = d < f1
            lt2 = d < f2
            f2 = np.where(lt, f1, np.where(lt2, d, f2))
            cid = np.where(lt, r3, cid)
            f1 = np.where(lt, d, f1)
    return f1, f2, cid


def cellhash(U, V, k, seed):
    """按 k×k 周期格的逐格哈希（砖 / 石板的逐块随机）。"""
    xi = np.mod(np.floor(U * k).astype(np.int64), k)
    yi = np.mod(np.floor(V * k).astype(np.int64), k)
    return _hash01(xi, yi, seed)


def _speck(n, seed):
    """逐像素白噪声：永远无缝，也是唯一在高频上不会走样的"颗粒层"。

    索引走 `(i + shift) % n`，所以它是**世界像素位置的函数**而非"数组下标的函数"，
    平移校验（periodic_check）才能对它成立。
    """
    i = (np.arange(n, dtype=np.int64) + int(_SHIFT[0])) % n
    j = (np.arange(n, dtype=np.int64) + int(_SHIFT[1])) % n
    U, V = np.meshgrid(i, j)
    return _hash01(U, V, seed)


def _dots(n, count, seed, radius_px):
    """周期化圆点（用环绕距离 → 无缝）。做花朵 / 炭渣 / 钉帽这类"件"。"""
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float64)
    xx = np.mod(xx + float(_SHIFT[0]), float(n))
    yy = np.mod(yy + float(_SHIFT[1]), float(n))
    out = np.zeros((n, n))
    for i in range(int(count)):
        px = float(_hash01(np.array([i]), np.array([0]), seed)[0]) * n
        py = float(_hash01(np.array([i]), np.array([1]), seed)[0]) * n
        dx = np.abs(xx - px)
        dx = np.minimum(dx, n - dx)
        dy = np.abs(yy - py)
        dy = np.minimum(dy, n - dy)
        out = np.maximum(out, np.exp(-(np.hypot(dx, dy) / float(radius_px)) ** 2))
    return out


def _cells(metres):
    """现实尺寸 → 在一张贴图里的整数份数（+ 修正后的现实尺寸，误差 ≤5%）。"""
    k = max(1, int(round(TILE_M / float(metres))))
    return k, TILE_M / k


def feat(n, metres):
    """现实尺寸 → 该分辨率下的像素数。"""
    return float(metres) / (TILE_M / float(n))


def addgrain(alb, n, seed, amt=0.045):
    return cshade(alb, lerp(1.0 - amt, 1.0 + amt, _speck(n, seed)))


def normal_map(h, n, relief_m, strength=1.0):
    """高度图 → 切线空间法线（环绕差分 → 无缝；坡度按现实米数换算）。"""
    return normal_map_w(h, n, n, relief_m, strength)


def normal_map_w(h, nx, ny, relief_m, strength=1.0):
    """同上，任意长宽。**前提：两轴同格宽（32px/格）**，所以两轴 m/px 相同。

    分带贴图（路肩 128×96 / 路缘 128×16）都是 32px 一格，故只用一个 mpp。
    """
    mpp = M.M_PER_UV / float(CELL)
    dh = float(h.max() - h.min())
    scale = float(relief_m) / (dh if dh > 1e-9 else 1.0)
    dx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * 0.5 * scale
    dy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * 0.5 * scale
    nxa = -(dx / mpp) * strength
    nya = -(dy / mpp) * strength
    nza = np.ones_like(h)
    ln = np.sqrt(nxa * nxa + nya * nya + nza * nza)
    out = np.stack([nxa / ln * 0.5 + 0.5, nya / ln * 0.5 + 0.5,
                    nza / ln * 0.5 + 0.5], -1)
    return np.clip(out, 0.0, 1.0)


def _pack(alb, h, rough, n, seed, relief_m, ao=0.40, ao_r=1, nstr=1.0):
    """统一收口：高度归一 → 谷底 AO 压暗 → 逐像素颗粒 → 法线。"""
    hn = (h - float(h.min())) / (float(h.max() - h.min()) + 1e-9)
    alb = addgrain(alb, n, seed + 7, 0.045 if n >= 256 else 0.028)
    k = lerp(1.0 - ao, 1.0, smoothstep(0.08, 0.78, pblur(hn, ao_r)))
    alb = cshade(alb, k)
    rough = np.clip(rough + (_speck(n, seed + 3) - 0.5)
                    * (0.04 if n >= 256 else 0.02), 0.25, 1.0)
    return {"alb": np.clip(alb, 0.0, 1.0),
            "h": hn,
            "rough": np.clip(rough, 0.05, 1.0),
            "relief_m": float(relief_m),
            "nstr": float(nstr),
            "size": (int(n), int(n))}


# ------------------------------------------------------------ 非方形（分带）支持
# 路肩带 128×96、路缘沟 128×16 都不是方的；下面这组是同一套数值工具的长宽版。
# 两轴仍是 32px/格，所以现实尺寸换算只用一个常数 mpp。

def _uvw(nx, ny):
    ix = np.arange(nx, dtype=np.float64) + 0.5 + float(_SHIFT[0])
    iy = np.arange(ny, dtype=np.float64) + 0.5 + float(_SHIFT[1])
    U, V = np.meshgrid(ix / float(nx), iy / float(ny))
    return U, V


def addgrain_w(alb, nx, ny, seed, amt=0.030):
    return lerp(1.0 - amt, 1.0 + amt, _speckw(nx, ny, seed))


def _speckw(nx, ny, seed):
    i = (np.arange(nx, dtype=np.int64) + int(_SHIFT[0])) % nx
    j = (np.arange(ny, dtype=np.int64) + int(_SHIFT[1])) % ny
    U, V = np.meshgrid(i, j)
    return _hash01(U, V, seed)


def _dotsw(nx, ny, count, seed, radius_px):
    yy, xx = np.mgrid[0:ny, 0:nx].astype(np.float64)
    xx = np.mod(xx + float(_SHIFT[0]), float(nx))
    yy = np.mod(yy + float(_SHIFT[1]), float(ny))
    out = np.zeros((ny, nx))
    for i in range(int(count)):
        px = float(_hash01(np.array([i]), np.array([0]), seed)[0]) * nx
        py = float(_hash01(np.array([i]), np.array([1]), seed)[0]) * ny
        dx = np.abs(xx - px)
        dx = np.minimum(dx, nx - dx)
        dy = np.abs(yy - py)
        dy = np.minimum(dy, ny - dy)
        out = np.maximum(out, np.exp(-(np.hypot(dx, dy) / float(radius_px)) ** 2))
    return out

def klatt(px, metres):
    """按该轴的像素长度 px 换算"这个现实尺寸"占多少整格（逐轴各算）。"""
    k = max(1, int(round((px / float(CELL)) * M.M_PER_UV / float(metres))))
    return min(k, max(1, px // 3))


def gwh(U, V, metres, nx, ny, seed, oct=3, gain=0.5):
    """长宽版各向同性噪声（特征尺度 = 现实米数，逐轴独立定格数）。"""
    ku, kv = klatt(nx, metres), klatt(ny, metres)
    o = _oct_for(min(nx / float(ku), ny / float(kv)), oct)
    return pfbm(U * ku, V * kv, ku, kv, seed, o, gain)


def gwh2(U, V, mu, mv, nx, ny, seed, oct=3, gain=0.5):
    ku, kv = klatt(nx, mu), klatt(ny, mv)
    o = _oct_for(min(nx / float(ku), ny / float(kv)), oct)
    return pfbm(U * ku, V * kv, ku, kv, seed, o, gain)


def cellhw(U, V, ku, kv, seed):
    xi = np.mod(np.floor(U * ku).astype(np.int64), ku)
    yi = np.mod(np.floor(V * kv).astype(np.int64), kv)
    return _hash01(xi, yi, seed)


def featw(metres):
    """现实尺寸 → 像素（1 格 = 32px，与分辨率无关的是格宽）。"""
    return float(metres) / (M.M_PER_UV / float(CELL))


def _packw(alb, h, rough, nx, ny, seed, relief_m, ao=0.40, ao_r=1, nstr=1.0,
           alpha=None):
    """长宽版收口。alpha 给定时顺带产出"decal 用"的带 alpha 版本。"""
    hn = (h - float(h.min())) / (float(h.max() - h.min()) + 1e-9)
    gr = addgrain_w(alb, nx, ny, seed + 7)
    alb = cshade(alb, gr)
    k = lerp(1.0 - ao, 1.0, smoothstep(0.08, 0.78, pblur(hn, ao_r)))
    alb = cshade(alb, k)
    rough = np.clip(rough + (_speckw(nx, ny, seed + 3) - 0.5) * 0.028, 0.25, 1.0)
    out = {"alb": np.clip(alb, 0.0, 1.0),
           "h": hn,
           "rough": np.clip(rough, 0.05, 1.0),
           "relief_m": float(relief_m),
           "nstr": float(nstr),
           "size": (int(nx), int(ny))}
    if alpha is not None:
        out["alpha"] = np.clip(alpha, 0.0, 1.0)
    return out


# ============================================================ 十二种地面
# —— 主街 / 广场系 ——

def t_cobble_small(n):
    """小鹅卵石（10.5cm，16 颗/贴图）：主街最常见的铺装，冷灰带磨亮。

    粒径取 10.5cm 而非 8.4cm：8.4cm 在 128 档只有 6.4px，缩到游戏尺寸读成噪点
    （实测 `pbr_ground_street.png`）——仍在小鹅卵石区间内，但 8px 才读得出"一颗颗"。
    """
    U, V = _uv(n)
    k, _p = _cells(0.12)
    f1, f2, cid = pworley(U * k, V * k, k, k, 11, 0.74)
    stone = smoothstep(0.03, 0.15, np.clip(f2 - f1, 0.0, None))
    dome = np.sqrt(np.clip(0.52 - f1, 0.0, None))
    dome = dome / (dome.max() + 1e-9)
    wet = smoothstep(0.35, 0.85, gnoise(U, V, 0.45, n, 21, oct=3))
    alb = cmix(cid, (0.400, 0.412, 0.438), (0.640, 0.652, 0.674))
    warm = smoothstep(0.80, 1.00, cellhash(U, V, k, 51))
    alb = cmix(warm * 0.75, alb, (0.600, 0.545, 0.470))
    alb = cshade(alb, lerp(0.88, 1.10, cid))
    pol = smoothstep(0.60, 0.95, gnoise(U, V, 0.05, n, 61, oct=2))
    mud = cmix(gnoise(U, V, 0.03, n, 71, oct=2), (0.270, 0.256, 0.234),
               (0.378, 0.361, 0.328))
    alb = cmix(stone, mud, alb)
    h = 0.10 + stone * (0.30 + 0.70 * dome) * 0.78
    rough = lerp(0.93, lerp(0.54, 0.72, cid), stone)
    rough = rough * lerp(1.0, 0.88, pol * stone) * lerp(1.0, 0.70, (1.0 - wet) * 0.6)
    return _pack(alb, h, rough, n, 101, 0.022, ao=0.36)


def t_cobble_large(n):
    """大鹅卵石（14cm）：广场 / 老街区，暖灰、石缝里有苔。"""
    U, V = _uv(n)
    k, _p = _cells(0.14)
    f1, f2, cid = pworley(U * k, V * k, k, k, 113, 0.88)
    stone = smoothstep(0.020, 0.15, np.clip(f2 - f1, 0.0, None))
    dome = np.sqrt(np.clip(0.50 - f1, 0.0, None))
    dome = dome / (dome.max() + 1e-9)
    alb = cmix(cid, (0.430, 0.404, 0.362), (0.700, 0.672, 0.624))
    warm = smoothstep(0.66, 0.96, cellhash(U, V, k, 123))
    alb = cmix(warm * 0.90, alb, (0.645, 0.570, 0.472))
    alb = cshade(alb, lerp(0.88, 1.10, cellhash(U, V, k, 133)))
    moss = smoothstep(0.72, 0.95, gnoise(U, V, 0.30, n, 143, oct=2))
    alb = cmix(moss * 0.38 * stone, alb, (0.315, 0.375, 0.255))
    trav = smoothstep(0.45, 0.90, gnoise(U, V, 0.85, n, 153, oct=2))
    alb = cshade(alb, lerp(1.0, 0.90, trav))
    mud = cmix(gnoise(U, V, 0.035, n, 163, oct=2), (0.255, 0.244, 0.220),
               (0.395, 0.378, 0.342))
    alb = cmix(stone, mud, alb)
    h = 0.10 + stone * (0.25 + 0.75 * dome) * 0.80
    rough = lerp(0.95, lerp(0.62, 0.79, cellhash(U, V, k, 173)), stone)
    return _pack(alb, h, rough, n, 201, 0.030, ao=0.38)


def t_brick_pave(n):
    """砖铺错缝（21×10.5cm，走砌长边）：红陶砖 + 灰浆缝 + 磨亮交通带。

    份数 8 列 × 16 行 → 横缝纵缝都整落在贴图边界；错缝半砖，边界相位不变。
    """
    U, V = _uv(n)
    ncol, _bw = _cells(0.21)
    nrow, _bh = _cells(0.105)
    x = U * ncol
    y = V * nrow
    row = np.floor(y).astype(np.int64)
    xo = x + np.where(row % 2 == 1, 0.5, 0.0)
    col = np.floor(xo).astype(np.int64)
    fx = xo - col
    fy = y - row
    dx = np.minimum(fx, 1.0 - fx)
    dy = np.minimum(fy, 1.0 - fy)
    jx, jy = 0.038, 0.055           # 竖缝 1.6cm / 横缝 1.15cm（半缝占格比）
    wmod = 0.82 + 0.55 * gnoise(U, V, 0.030, n, 301, oct=2)   # 缝宽起伏 = 缺角边缘
    brick = (smoothstep(jx * wmod - 0.012, jx * wmod + 0.016, dx)
             * smoothstep(jy * wmod - 0.016, jy * wmod + 0.020, dy))
    rid = np.mod(row, nrow)
    cid = np.mod(col, ncol)
    r1 = _hash01(rid, cid, 311)
    r2 = _hash01(rid, cid, 321)
    alb = cmix(r1, (0.335, 0.170, 0.128), (0.655, 0.375, 0.262))
    alb = cmix(smoothstep(0.80, 0.97, r2) * 0.85, alb, (0.460, 0.425, 0.390))
    alb = cmix(smoothstep(0.07, 0.01, r2) * 0.5, alb, (0.250, 0.150, 0.130))
    alb = cshade(alb, lerp(0.90, 1.08, gnoise(U, V, 0.022, n, 331, oct=2)))
    trav = smoothstep(0.55, 0.95, gnoise(U, V, 0.38, n, 341, oct=2))
    alb = cshade(alb, lerp(1.0, 0.90, trav * 0.7))
    mor = cmix(gnoise(U, V, 0.018, n, 351, oct=2), (0.400, 0.378, 0.330),
               (0.585, 0.560, 0.500))
    alb = cmix(brick, mor, alb)
    dom = np.sqrt(np.clip(0.5 - np.abs(fy - 0.5), 0.0, None))
    h = 0.10 + brick * (0.80 + 0.12 * dom / (dom.max() + 1e-9))
    rough = lerp(0.95, lerp(0.78, 0.92, r2), brick)
    rough = rough * lerp(1.0, 0.88, trav * 0.8)
    return _pack(alb, h, rough, n, 401, 0.014, ao=0.40)


def t_flagstone(n):
    """大石板不规则（≈42cm 多边形）：市政厅前 / 广场，浅暖灰 + 凿痕 + 磨光边。

    板缝收到 ≈2.3cm（`smoothstep(0.012, 0.052)`）：早先用 0.09 时缝宽到 4cm 以上，
    缩到游戏尺寸整块读成"彩色玻璃"（`pbr_ground_game1x.png` 的教训）。
    """
    U, V = _uv(n)
    k = 4                       # 1.68 / 4 = 42cm 基准格
    f1, f2, cid = pworley(U * k, V * k, k, k, 501, 0.52)
    slab = smoothstep(0.008, 0.038, np.clip(f2 - f1, 0.0, None))
    dome = np.sqrt(np.clip(0.55 - f1, 0.0, None))
    dome = dome / (dome.max() + 1e-9)
    r1 = cellhash(U, V, k, 511)
    # 板面基调：逐板只给小幅差别，大尺度明暗交给**连续**低频噪声 —— 否则 4×4 块
    # 拼色会读成"彩色玻璃拼贴"，而且每 1.68m 复读一次
    alb = cmix(r1, (0.560, 0.544, 0.512), (0.735, 0.716, 0.680))
    alb = cmix(gnoise(U, V, 0.42, n, 521, oct=3), alb,
               cmix(r1, (0.700, 0.662, 0.598), (0.578, 0.588, 0.606)))
    tool = gnoise2(U, V, 0.013, 0.070, n, 541, oct=2)      # 顺 U 的细凿痕
    alb = cshade(alb, lerp(0.90, 1.10, tool))
    alb = cshade(alb, lerp(0.94, 1.06, gnoise(U, V, 0.10, n, 551, oct=2)))
    alb = cshade(alb, lerp(0.95, 1.05, gnoise(U, V, 0.022, n, 561, oct=2)))
    pit = _dots(n, 120, 562, feat(n, 0.008))               # 板面麻点（凿击痕）
    alb = cmix(pit * 0.30, alb, (0.405, 0.396, 0.376))
    mud = cmix(gnoise(U, V, 0.05, n, 571, oct=2), (0.410, 0.392, 0.356),
               (0.545, 0.526, 0.484))
    mud = cmix(smoothstep(0.80, 0.97, gnoise(U, V, 0.26, n, 581, oct=2)) * 0.35,
               mud, (0.300, 0.350, 0.250))
    alb = cmix(slab, mud, alb)
    edge = slab * (1.0 - smoothstep(0.0, 0.35, np.clip(f2 - f1, 0.0, None)))
    alb = cshade(alb, lerp(1.0, 1.07, edge))               # 磨光的板边
    h = (0.09 + slab * (0.30 + 0.70 * dome) * 0.80 + tool * 0.06
         + slab * (r1 - 0.5) * 0.10)
    rough = lerp(0.94, lerp(0.70, 0.86, r1), slab)
    rough = rough * lerp(1.0, 0.90, edge)
    return _pack(alb, h, rough, n, 601, 0.018, ao=0.36)


# —— 土地 / 巷道系 ——

def t_rammed_earth(n):
    """夯土（夯层 14cm）：村道 / 院坝，暖褐 + 层带 + 少量干裂与小石子。"""
    U, V = _uv(n)
    alb = cmix(gnoise(U, V, 0.85, n, 701, oct=3), (0.480, 0.388, 0.278),
               (0.700, 0.595, 0.448))
    alb = cmix(gnoise(U, V, 0.16, n, 711, oct=2) * 0.55, alb, (0.400, 0.332, 0.248))
    warp = gnoise(U, V, 0.55, n, 721, oct=2) - 0.5
    band = np.sin(2.0 * math.pi * (12.0 * V + 0.35 * warp))       # 12 层 × 14cm
    alb = cshade(alb, lerp(0.962, 1.032, band * 0.5 + 0.5))
    alb = cshade(alb, lerp(0.92, 1.08, gnoise(U, V, 0.035, n, 731, oct=3)))
    alb = cshade(alb, lerp(0.955, 1.045, gnoise(U, V, 0.022, n, 741, oct=2)))
    f1p, f2p, cp = pworley(U * 21, V * 21, 21, 21, 751, 0.90)
    peb = (smoothstep(0.955, 1.0, cellhash(U, V, 21, 761))
           * smoothstep(0.0, 0.045, np.clip(f2p - f1p, 0.0, None)))
    alb = cmix(peb * 0.55, alb, cmix(cp, (0.375, 0.360, 0.334), (0.510, 0.492, 0.458)))
    f1c, f2c, _cc = pworley(U * 5, V * 5, 5, 5, 771, 0.60)
    crack = smoothstep(0.010, 0.0, np.clip(f2c - f1c, 0.0, None))
    alb = cshade(alb, 1.0 - crack * 0.20)
    h = 0.45 + band * 0.07 + gnoise(U, V, 0.05, n, 781, oct=3) * 0.30 \
        + peb * 0.26 - crack * 0.20
    rough = np.clip(0.96 - crack * 0.04, 0.5, 1.0)
    return _pack(alb, h, rough, n, 801, 0.010, ao=0.30)


def t_dirt_rut(n):
    """泥地带车辙（车辙宽 13cm × 2）：巷道主路，辙内压实发暗、辙间干燥起垄。"""
    U, V = _uv(n)
    alb = cmix(gnoise(U, V, 0.75, n, 901, oct=3), (0.372, 0.296, 0.215),
               (0.585, 0.478, 0.354))
    alb = cmix(gnoise(U, V, 0.14, n, 911, oct=2) * 0.50, alb, (0.312, 0.250, 0.184))
    wob = (gnoise(U, V, 0.35, n, 921, oct=2) - 0.5) * 0.035
    s = 0.13 / TILE_M                       # 13cm 半宽（V 比例）
    vv = V + wob
    rut = np.clip(np.exp(-((wdist(vv, 0.34) / s) ** 2))
                  + np.exp(-((wdist(vv, 0.66) / s) ** 2)), 0.0, 1.0)
    crown = np.exp(-((wdist(V, 0.50) / (s * 1.4)) ** 2))
    # 辙内被碾实：更暗、更光、顺路向拉出细密压实纹
    stamp = gnoise2(U, V, 0.070, 0.028, n, 931, oct=2)
    alb = cmix(rut * 0.62, alb, cmix(stamp, (0.290, 0.228, 0.168),
                                     (0.375, 0.302, 0.222)))
    alb = cmix(crown * 0.26, alb, (0.565, 0.468, 0.352))
    f1c, f2c, _cc = pworley(U * 6, V * 6, 6, 6, 941, 0.50)
    crack = smoothstep(0.013, 0.0, np.clip(f2c - f1c, 0.0, None))
    alb = cshade(alb, 1.0 - crack * 0.15 * (1.0 - rut))
    alb = cshade(alb, lerp(0.92, 1.08, gnoise(U, V, 0.03, n, 951, oct=3)))
    f1p, f2p, cp = pworley(U * 21, V * 21, 21, 21, 961, 0.90)
    peb = (smoothstep(0.88, 0.99, cellhash(U, V, 21, 971))
           * smoothstep(0.0, 0.075, np.clip(f2p - f1p, 0.0, None)))
    alb = cmix(peb * 0.80, alb, cmix(cp, (0.430, 0.410, 0.385), (0.630, 0.610, 0.580)))
    straw = _dots(n, 12, 981, feat(n, 0.011)) * (1.0 - rut * 0.6)
    alb = cmix(straw * 0.55, alb, (0.655, 0.585, 0.395))
    h = (0.55 - rut * 0.52 + crown * 0.22 + gnoise(U, V, 0.045, n, 991, oct=3) * 0.24
         + peb * 0.24 - crack * 0.20 + straw * 0.10)
    rough = np.clip(0.95 - rut * 0.16, 0.5, 1.0)
    return _pack(alb, h, rough, n, 1001, 0.030, ao=0.32)


def t_gravel(n):
    """砾石（8cm 主石 + 4cm 碎砾）：次级巷道 / 工地，浅灰米、高起伏。"""
    U, V = _uv(n)
    k, _p = _cells(0.08)
    f1, f2, cid = pworley(U * k, V * k, k, k, 1101, 0.92)
    peb = smoothstep(0.012, 0.10, np.clip(f2 - f1, 0.0, None))
    dome = np.sqrt(np.clip(0.50 - f1, 0.0, None))
    dome = dome / (dome.max() + 1e-9)
    alb = cmix(cid, (0.470, 0.450, 0.415), (0.705, 0.680, 0.630))
    alb = cmix(smoothstep(0.78, 1.00, cellhash(U, V, k, 1111)) * 0.70, alb,
               (0.625, 0.545, 0.435))
    alb = cmix(smoothstep(0.72, 1.00, cellhash(U, V, k, 1121)) * 0.55, alb,
               (0.330, 0.325, 0.315))
    dust = cmix(gnoise(U, V, 0.04, n, 1131, oct=3), (0.400, 0.370, 0.315),
                (0.560, 0.525, 0.460))
    alb = cmix(peb, dust, alb)
    f1b, f2b, cb = pworley(U * 42, V * 42, 42, 42, 1141, 0.95)
    fine = (smoothstep(0.0, 0.09, np.clip(f2b - f1b, 0.0, None))
            * smoothstep(0.45, 0.72, cellhash(U, V, 42, 1151)))
    alb = cmix(fine * 0.55, alb, cmix(cb, (0.430, 0.415, 0.385), (0.665, 0.645, 0.605)))
    h = 0.10 + peb * (0.35 + 0.65 * dome) * 0.62 + fine * 0.12
    rough = np.clip(lerp(0.92, lerp(0.70, 0.86, cid), peb), 0.30, 1.0)
    return _pack(alb, h, rough, n, 1201, 0.020, ao=0.45)


def t_ash_soil(n):
    """灰渣土：炉灰 / 屠宰场后巷 / 贫民区，暗灰 + 炭块 + 灰堆 + 锈色焦渣。

    这版比初版整体提亮并加了两级"件"（灰堆斑 45cm / 炭块 1.6cm / 焦渣 0.9cm）——
    初版在游戏尺寸下是一块没有结构的暗板（`pbr_ground_seam.png` 的教训）。
    """
    U, V = _uv(n)
    alb = cmix(gnoise(U, V, 0.75, n, 1301, oct=3), (0.270, 0.262, 0.254),
               (0.520, 0.504, 0.482))
    alb = cmix(gnoise(U, V, 0.18, n, 1311, oct=2) * 0.55, alb, (0.190, 0.182, 0.178))
    drift = smoothstep(0.50, 0.88, gnoise(U, V, 0.45, n, 1321, oct=3))
    alb = cmix(drift * 0.45, alb, (0.520, 0.512, 0.498))
    # 焦渣块（12cm）：块面明暗 + 块缝更暗 → 给"灰渣"一层能读出来的mid-scale结构
    # （初版在 1:1 游戏尺寸下就是一块没有结构的暗斑，见 pbr_ground_game1x.png 上带）
    f1k, f2k, ck = pworley(U * 14, V * 14, 14, 14, 1331, 0.85)
    kl = smoothstep(0.02, 0.14, np.clip(f2k - f1k, 0.0, None))
    alb = cmix(kl, (0.200, 0.191, 0.185), alb)
    alb = cshade(alb, lerp(0.88, 1.14, ck))
    alb = cmix(smoothstep(0.50, 0.86, gnoise(U, V, 0.10, n, 1341, oct=2)) * 0.35,
               alb, (0.380, 0.364, 0.344))
    alb = cmix(smoothstep(0.45, 0.80, gnoise(U, V, 0.32, n, 1342, oct=3)) * 0.35,
               alb, (0.410, 0.396, 0.376))
    alb = cshade(alb, lerp(0.90, 1.10, gnoise(U, V, 0.03, n, 1341, oct=3)))
    lump = _dots(n, 70, 1351, feat(n, 0.016))
    alb = cmix(lump * 0.42, alb, (0.175, 0.166, 0.160))
    lump2 = _dots(n, 28, 1361, feat(n, 0.022))
    alb = cmix(lump2 * 0.14, alb, (0.500, 0.492, 0.482))
    cinder = _dots(n, 26, 1371, feat(n, 0.009))
    alb = cmix(cinder * 0.50, alb, (0.420, 0.205, 0.100))
    path = np.exp(-((wdist(V, 0.52) / 0.10) ** 2))
    alb = cshade(alb, lerp(1.0, 1.12, path * 0.5))
    h = (0.45 + gnoise(U, V, 0.035, n, 1381, oct=3) * 0.24 + drift * 0.16
         + kl * 0.20 + lump * 0.26 + lump2 * 0.20 + cinder * 0.10)
    rough = np.clip(0.95 - drift * 0.04, 0.60, 1.0)
    return _pack(alb, h, rough, n, 1401, 0.014, ao=0.34)


# —— 自然系 ——

def t_grass(n):
    """草地：城郊 / 公园，密生草皮 + 枯斑 + 苔绿块 + 零星黄白野花。"""
    U, V = _uv(n)
    clump = (0.6 * gnoise(U, V, 0.55, n, 1501, oct=3)
             + 0.4 * gnoise(U, V, 0.14, n, 1502, oct=2))
    alb = cmix(clump, (0.310, 0.440, 0.150), (0.160, 0.266, 0.080))
    dry = smoothstep(0.56, 0.86, gnoise(U, V, 0.50, n, 1511, oct=3))
    alb = cmix(dry * 0.70, alb, (0.480, 0.438, 0.198))
    moss = smoothstep(0.70, 0.94, gnoise(U, V, 0.20, n, 1521, oct=2))
    alb = cmix(moss * 0.40, alb, (0.090, 0.145, 0.058))
    blade = (0.55 * gnoise2(U, V, 0.060, 0.16, n, 1531, oct=2)
             + 0.45 * gnoise(U, V, 0.075, n, 1532, oct=2))
    alb = cshade(alb, lerp(0.76, 1.24, blade))
    alb = cshade(alb, lerp(0.90, 1.10, gnoise(U, V, 0.012, n, 1541, oct=2)))
    alb = cshade(alb, lerp(0.92, 1.08, gnoise2(U, V, 0.018, 0.045, n, 1551, oct=2)))
    fl = _dots(n, 14, 1561, feat(n, 0.020))
    alb = cmix(fl * 0.80, alb, (0.900, 0.872, 0.400))
    fl2 = _dots(n, 10, 1571, feat(n, 0.016))
    alb = cmix(fl2 * 0.65, alb, (0.915, 0.915, 0.895))
    h = (0.30 + 0.30 * blade + 0.18 * clump + 0.12 * (dry - 0.5) + 0.08 * fl
         + 0.10 * gnoise2(U, V, 0.020, 0.05, n, 1581, oct=2))
    rough = np.clip(0.90 - (1.0 - dry) * 0.02, 0.60, 1.0)
    return _pack(alb, h, rough, n, 1601, 0.026, ao=0.26, nstr=0.85)


def t_grass_sparse(n):
    """稀疏草土地：路边 / 荒地，土为主（约 60%）、草簇缀其中。"""
    U, V = _uv(n)
    alb = cmix(gnoise(U, V, 0.70, n, 1701, oct=3), (0.415, 0.348, 0.252),
               (0.630, 0.548, 0.418))
    alb = cmix(gnoise(U, V, 0.14, n, 1711, oct=2) * 0.55, alb, (0.340, 0.278, 0.198))
    alb = cmix(gnoise(U, V, 0.05, n, 1721, oct=2) * 0.45, alb, (0.470, 0.398, 0.288))
    alb = cshade(alb, lerp(1.0, 1.10, smoothstep(0.45, 0.90,
                                                 gnoise(U, V, 0.50, n, 1731, oct=2)) * 0.6))
    f1p, f2p, cp = pworley(U * 21, V * 21, 21, 21, 1741, 0.90)
    peb = (smoothstep(0.86, 0.99, cellhash(U, V, 21, 1751))
           * smoothstep(0.0, 0.075, np.clip(f2p - f1p, 0.0, None)))
    alb = cmix(peb * 0.80, alb, cmix(cp, (0.440, 0.425, 0.400), (0.670, 0.655, 0.620)))
    # 草簇遮罩：1 = 草。（初版把 t 用反了 → 草成了"被挖掉的一块"）
    tuft = smoothstep(0.40, 0.60, gnoise(U, V, 0.14, n, 1761, oct=3))
    tuft = np.clip(tuft * (1.0 + (gnoise(U, V, 0.045, n, 1771, oct=2) - 0.5) * 1.8),
                   0.0, 1.0)
    tuft = smoothstep(0.16, 0.90, tuft)
    g1 = cmix(gnoise(U, V, 0.30, n, 1781, oct=2), (0.300, 0.430, 0.145),
              (0.155, 0.252, 0.078))
    g1 = cshade(g1, lerp(0.70, 1.30, gnoise2(U, V, 0.04, 0.09, n, 1791, oct=2)))
    g1 = cshade(g1, lerp(0.92, 1.08, gnoise2(U, V, 0.016, 0.04, n, 1801, oct=2)))
    alb = cmix(tuft, alb, g1)
    h = (0.30 + tuft * 0.35 + gnoise(U, V, 0.04, n, 1811, oct=3) * 0.20 + peb * 0.22
         + tuft * gnoise2(U, V, 0.02, 0.05, n, 1821, oct=2) * 0.12)
    rough = np.clip(0.94 - tuft * 0.03, 0.60, 1.0)
    return _pack(alb, h, rough, n, 1802, 0.030, ao=0.30, nstr=0.9)


def t_sand(n):
    """沙地（风纹波距 9.3cm）：河滩 / 沙路，暖黄 + 波纹 + 潮斑 + 零星砾。"""
    U, V = _uv(n)
    alb = cmix(gnoise(U, V, 0.60, n, 1901, oct=3), (0.650, 0.575, 0.418),
               (0.850, 0.782, 0.622))
    alb = cmix(gnoise(U, V, 0.15, n, 1911, oct=2) * 0.50, alb, (0.570, 0.492, 0.342))
    warp = gnoise(U, V, 0.75, n, 1921, oct=3) - 0.5
    rip = np.sin(2.0 * math.pi * (18.0 * V + 0.85 * warp
                                  + 0.40 * (gnoise(U, V, 1.4, n, 1931, oct=2) - 0.5)))
    # 波纹的明暗压低（初版 ±10% 在游戏尺寸下读成瓦楞纸）
    alb = cshade(alb, lerp(0.962, 1.038, rip * 0.5 + 0.5))
    alb = cshade(alb, lerp(0.93, 1.07, gnoise(U, V, 0.015, n, 1941, oct=2)))
    grit = _dots(n, 90, 1951, feat(n, 0.006))
    alb = cmix(grit * 0.35, alb, (0.590, 0.556, 0.480))
    f1p, f2p, cp = pworley(U * 42, V * 42, 42, 42, 1961, 0.92)
    peb = (smoothstep(0.93, 1.00, cellhash(U, V, 42, 1971))
           * smoothstep(0.0, 0.05, np.clip(f2p - f1p, 0.0, None)))
    alb = cmix(peb * 0.60, alb, cmix(cp, (0.470, 0.452, 0.428), (0.660, 0.640, 0.612)))
    h = (0.50 + rip * 0.07 + gnoise(U, V, 0.03, n, 1981, oct=3) * 0.34
         + grit * 0.10 + peb * 0.18)
    rough = np.clip(0.90, 0.60, 1.0)
    return _pack(alb, h, rough, n, 2001, 0.010, ao=0.24, nstr=0.75)


def t_boardwalk(n):
    """木栈道（板宽 21cm，板端横缝故意落在贴图边界）：商铺前檐廊 / 码头。"""
    U, V = _uv(n)
    npl, _pw = _cells(0.21)
    x = U * npl
    pidx = np.floor(x).astype(np.int64)
    fx = x - pidx
    dx = np.minimum(fx, 1.0 - fx)
    g = 0.0333                                  # 缝 1.4cm（半缝占板宽比）
    plank = smoothstep(g - 0.012, g + 0.014, dx)
    fy = np.mod(V, 1.0)
    dy = np.minimum(fy, 1.0 - fy)
    ts = 0.022 / TILE_M                          # 板端缝 2.2cm
    endj = smoothstep(ts - 0.004, ts + 0.007, dy)
    plank = plank * endj
    pid = np.mod(pidx, npl)
    zero = np.zeros_like(pid)
    r1 = _hash01(pid, zero, 2101)
    r2 = _hash01(pid, zero, 2111)
    alb = cmix(r1, (0.420, 0.288, 0.168), (0.700, 0.520, 0.340))
    alb = cmix(smoothstep(0.72, 0.95, r2) * 0.55, alb, (0.520, 0.502, 0.478))
    grain = gnoise2(U, V, 0.055, 0.40, n, 2121, oct=3)
    alb = cshade(alb, lerp(0.86, 1.14, grain))
    alb = cshade(alb, lerp(0.94, 1.06, gnoise2(U, V, 0.012, 0.08, n, 2131, oct=2)))
    knot = _dots(n, 16, 2141, feat(n, 0.013)) * plank
    alb = cmix(knot * 0.70, alb, (0.180, 0.112, 0.062))
    nail = _nails(n, npl, feat(n, 0.013))
    alb = cmix(nail * 0.80, alb, (0.330, 0.322, 0.316))
    # 缝里是**与板无关**的统一暗影：板缝正好落在贴图边界上，若缝里留着逐板色，
    # 边界两侧就是两块不同颜色的板 → 一条明显的接缝台阶（初版 bug）。
    # cmix 的 t=1 取 b，所以这里 t=plank（不是 1-plank）。
    alb = cmix(plank, (0.170, 0.138, 0.106), alb)
    walk = smoothstep(0.45, 0.95, gnoise(U, V, 0.40, n, 2151, oct=2))
    alb = cshade(alb, lerp(1.0, 0.93, walk * 0.6))
    h = 0.12 + plank * 0.66 + grain * 0.10 + knot * 0.06
    rough = np.clip(lerp(0.94, lerp(0.62, 0.80, grain), plank), 0.35, 1.0)
    return _pack(alb, h, rough, n, 2201, 0.018, ao=0.40)


def _nails(n, npl, radius_px):
    """每块板的板端各两颗钉（板端缝本来就在贴图边界 → 无缝）。"""
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float64)
    xx = np.mod(xx + float(_SHIFT[0]), float(n))
    yy = np.mod(yy + float(_SHIFT[1]), float(n))
    out = np.zeros((n, n))
    for p in range(npl):
        for off in (0.33, 0.67):
            px = (p + off) / float(npl) * n
            for vv in (0.040, 0.960):
                py = vv * n
                dx = np.abs(xx - px)
                dx = np.minimum(dx, n - dx)
                dy = np.abs(yy - py)
                dy = np.minimum(dy, n - dy)
                out = np.maximum(out, np.exp(-(np.hypot(dx, dy) / float(radius_px)) ** 2))
    return out


# ============================================================ 分带（路肩 / 路缘沟 / 道路）
# 游戏场景的地面是**一条从地面线到 ground_bottom 的可走带**（见 battle_sim.ground_y /
# ground_bottom、construction 的 96px 占地口径）。建筑基线的墙根往下依次是：
#     ① 路肩带（96px = 3 格）：贴墙根的硬化面 + 墙根立边 + 墙脚接触暗（微 AO）
#     ② 路缘石 + 排水沟（16px 薄带）：石缘 / 木石缘 + 沟槽 + 沉积 + 积水
#     ③ 道路带（下方主可走区）：车辙顺 X 连续、碾纹、踩踏磨损、泥泞、积水、
#        修补块、排水微拱
# **同一套带换"材质族"就是换城镇类型**（ground_texture_type 思路）：
#     石砌镇（军事/要塞）= 石板 + 石缘 + 石铺路
#     土作镇（农业/乡野）= 夯土 + 木石缘 + 土路
#     矿渣镇（矿业/工坊）= 夯砾渣 + 碎石缘 + 矿渣路
# 周期约定：三带都**只在 X 方向平铺**（Y 是结构方向：上缘贴建筑基线、下缘接下一带）；
# 道路带 V 向也是周期函数（车辙只跟 V 有关），所以额外允许 Y 向平铺。

#: 材质族（key, 中文名）
FAMILIES = [("stone", "石砌镇"), ("earth", "土作镇"), ("slag", "矿渣镇")]
SHOULDER_PX = 3 * CELL          # 96px = 3 格
KERB_PX = 16                    # 路缘石 + 排水沟薄带
ROAD_PX = 4 * CELL              # 道路带基准高（Y 向可平铺）


def _fam_pal(fam):
    """族 → (硬化面基色, 缝与散料色, 湿痕色)。"""
    if fam == "stone":
        return ((0.585, 0.572, 0.545), (0.300, 0.286, 0.262), (0.330, 0.330, 0.338))
    if fam == "earth":
        return ((0.520, 0.418, 0.300), (0.352, 0.276, 0.192), (0.300, 0.226, 0.158))
    return ((0.470, 0.448, 0.410), (0.250, 0.240, 0.228), (0.290, 0.280, 0.268))


def b_shoulder(fam, nx=128, ny=SHOULDER_PX):
    """① 路肩带：贴墙根的硬化面。上缘(V→1)贴建筑基线，下缘(V→0)接路缘沟。"""
    U, V = _uvw(nx, ny)
    hard, fill, _wet = _fam_pal(fam)
    edge_n = np.exp(-((wdist(V, 0.960) / 0.030) ** 2))     # 墙根立边
    wall_ao = smoothstep(0.88, 1.0, V) * 0.15              # 墙脚接触暗（微 AO）
    if fam == "stone":
        f1, f2, cid = pworley(U * 4, V * 4, 4, 4, 4011, 0.52)
        face = smoothstep(0.008, 0.040, np.clip(f2 - f1, 0.0, None))
        base = cmix(cid, (0.545, 0.530, 0.500), (0.740, 0.722, 0.688))
        base = cmix(gwh(U, V, 0.42, nx, ny, 4021, oct=3), base,
                    cmix(cid, (0.700, 0.662, 0.598), (0.578, 0.588, 0.606)))
        base = cshade(base, lerp(0.90, 1.10, gwh2(U, V, 0.013, 0.070, nx, ny, 4031)))
        jointc = cmix(gwh(U, V, 0.05, nx, ny, 4041, oct=2), (0.400, 0.386, 0.356),
                      (0.535, 0.516, 0.474))
        alb = cmix(face, jointc, base)
        h = 0.10 + face * 0.70 + gwh(U, V, 0.02, nx, ny, 4051, oct=2) * 0.16
        rough = lerp(0.93, lerp(0.72, 0.88, cid), face)
    elif fam == "earth":
        alb = cmix(gwh(U, V, 0.70, nx, ny, 4111, oct=3), (0.470, 0.372, 0.262),
                   (0.660, 0.552, 0.408))
        alb = cmix(gwh(U, V, 0.12, nx, ny, 4121, oct=2) * 0.5, alb,
                   (0.370, 0.298, 0.212))
        band = np.sin(2.0 * math.pi * (3.0 * V
                                       + 0.3 * (gwh(U, V, 1.2, nx, ny, 4131) - 0.5)))
        alb = cshade(alb, lerp(0.960, 1.036, band * 0.5 + 0.5))
        grit = gwh2(U, V, 0.048, 0.036, nx, ny, 4141, oct=2)
        alb = cshade(alb, lerp(0.90, 1.10, grit))
        h = 0.5 + gwh(U, V, 0.05, nx, ny, 4161, oct=3) * 0.30 + grit * 0.16
        rough = np.clip(0.96 - grit * 0.03, 0.5, 1.0)
    else:
        f1, f2, cid = pworley(U * 21, V * 21, 21, 21, 4211, 0.92)
        peb = smoothstep(0.010, 0.10, np.clip(f2 - f1, 0.0, None))
        dome = np.sqrt(np.clip(0.50 - f1, 0.0, None))
        dome = dome / (dome.max() + 1e-9)
        alb = cmix(cid, (0.470, 0.450, 0.415), (0.705, 0.680, 0.630))
        alb = cmix(cellhw(U, V, 21, 21, 4221) * 0.45, alb, (0.330, 0.325, 0.315))
        dust = cmix(gwh(U, V, 0.04, nx, ny, 4231, oct=3), (0.320, 0.300, 0.268),
                    (0.470, 0.448, 0.406))
        alb = cmix(peb, dust, alb)
        ash = _dotsw(nx, ny, 60, 4241, featw(0.010))
        alb = cmix(ash * 0.35, alb, (0.240, 0.232, 0.226))
        h = 0.12 + peb * (0.35 + 0.65 * dome) * 0.60 + ash * 0.10
        rough = np.clip(lerp(0.93, lerp(0.72, 0.88, cid), peb), 0.4, 1.0)
    # 墙根立边一条（砖边 / 石立边 / 碎石列）
    alb = cmix(edge_n * 0.85, alb,
               cmix(cellhw(U, V, max(2, nx // 4), 1, 4311), fill, hard))
    h = h + edge_n * 0.34
    rough = lerp(rough, 0.88, edge_n * 0.7)
    # 行人磨损带：路肩中上段一条踩得更光更亮的通道
    trav = (smoothstep(0.42, 0.86, gwh(U, V, 0.85, nx, ny, 4321, oct=2))
            * smoothstep(0.20, 0.62, V) * (1.0 - smoothstep(0.80, 0.97, V)))
    alb = cshade(alb, lerp(1.0, 1.10, trav * 0.45))
    rough = rough * lerp(1.0, 0.90, trav * 0.5)
    # 墙根堆积的细碎（草屑 / 渣土）
    lit = gwh2(U, V, 0.05, 0.016, nx, ny, 4331, oct=2) * smoothstep(0.74, 0.95, V) * 0.5
    alb = cmix(lit, alb, (0.430, 0.372, 0.262))
    alb = cshade(alb, 1.0 - wall_ao)
    h = h + 0.05 * V                        # 排水微倾（几何，克制：V 向大坡度会被顶光读成暗带）
    return _packw(alb, h, rough, nx, ny, 4401, 0.014, ao=0.30, nstr=0.9)


def b_kerb(fam, nx=128, ny=KERB_PX):
    """② 路缘石 + 排水沟：上(V→1)缘石列，下(V→0)沟槽（沉积 / 积水）。"""
    U, V = _uvw(nx, ny)
    _hard, _fill, wet = _fam_pal(fam)
    top = smoothstep(0.42, 0.58, V)
    if fam == "stone":
        # 缘石宽 = 24cm（4 格 / 7 块）。**份数必须整除带宽**，否则 U 向不是周期函数
        nst = 7
        fx = U * nst
        dx = np.minimum(fx - np.floor(fx), 1.0 - (fx - np.floor(fx)))
        stone = smoothstep(0.030, 0.075, dx)
        ci = cellhw(U, V, nst, 1, 4411)
        alb = cmix(ci, (0.560, 0.548, 0.520), (0.740, 0.726, 0.694))
        alb = cshade(alb, lerp(0.92, 1.07, gwh2(U, V, 0.05, 0.012, nx, ny, 4421)))
        alb = cmix(stone, cmix(gwh(U, V, 0.03, nx, ny, 4431, oct=2),
                               (0.300, 0.286, 0.262), (0.420, 0.404, 0.372)), alb)
        h = 0.55 + stone * 0.42
        rough = lerp(0.95, 0.86, stone)
    elif fam == "earth":
        rowh = np.sin(2.0 * math.pi * (4.0 * V
                                       + 0.2 * (gwh(U, V, 0.9, nx, ny, 4511) - 0.5)))
        alb = cmix(gwh(U, V, 0.30, nx, ny, 4521, oct=3), (0.430, 0.336, 0.234),
                   (0.610, 0.502, 0.368))
        alb = cshade(alb, lerp(0.95, 1.06, rowh * 0.5 + 0.5))
        wood = gwh2(U, V, 0.30, 0.020, nx, ny, 4531, oct=2)
        alb = cmix(smoothstep(0.30, 0.55, V) * 0.75, alb,
                   cmix(wood, (0.400, 0.286, 0.168), (0.560, 0.430, 0.278)))
        knotb = _dotsw(nx, ny, 6, 4541, featw(0.010))
        alb = cmix(knotb * 0.5, alb, (0.230, 0.150, 0.086))
        alb = cshade(alb, lerp(0.92, 1.08, gwh2(U, V, 0.048, 0.026, nx, ny, 4551)))
        h = 0.50 + smoothstep(0.30, 0.60, V) * 0.14 + knotb * 0.06
        rough = np.clip(0.95 - 0.04 * smoothstep(0.3, 0.6, V), 0.5, 1.0)
    else:
        f1, f2, cid = pworley(U * 24, V * 3, 24, 3, 4611, 0.92)
        peb = smoothstep(0.02, 0.13, np.clip(f2 - f1, 0.0, None))
        alb = cmix(cid, (0.440, 0.420, 0.386), (0.660, 0.640, 0.596))
        alb = cmix(peb, cmix(gwh(U, V, 0.03, nx, ny, 4621, oct=2),
                             (0.250, 0.244, 0.238), (0.400, 0.386, 0.360)), alb)
        ash = _dotsw(nx, ny, 40, 4631, featw(0.009))
        alb = cmix(ash * 0.45, alb, (0.220, 0.212, 0.208))
        h = 0.45 + peb * 0.55 + ash * 0.10
        rough = np.clip(lerp(0.93, 0.84, peb), 0.4, 1.0)
    chan = 1.0 - top
    dep = gwh(U, V, 0.22, nx, ny, 4711, oct=2)
    sed = cmix(dep, (0.300, 0.268, 0.220), (0.470, 0.428, 0.360))
    if fam == "slag":
        sed = cmix(dep, (0.230, 0.222, 0.216), (0.380, 0.366, 0.344))
    puddle = (smoothstep(0.72, 0.92, gwh(U, V, 0.55, nx, ny, 4721, oct=2))
              * smoothstep(0.40, 0.24, V))
    sed = cmix(puddle * 0.85, sed, wet)
    alb = cmix(chan, sed, alb)
    h = h * top + (0.06 + dep * 0.16) * chan
    rough = rough * top + np.clip(0.97 - puddle * 0.80, 0.05, 1.0) * chan
    return _packw(alb, h, rough, nx, ny, 4731, 0.012, ao=0.34, nstr=0.9)


#: 修补块的换料色（按族）：石=新碎石 / 土=新夯土 / 渣=新矿渣
_PATCH = {
    "stone": ((0.425, 0.412, 0.392), (0.560, 0.542, 0.512)),
    "earth": ((0.330, 0.300, 0.262), (0.520, 0.480, 0.420)),
    "slag": ((0.300, 0.292, 0.286), (0.455, 0.438, 0.408)),
}


def b_road(fam, nx=ROAD_PX, ny=ROAD_PX):
    """③ 道路带：车辙顺 X 连续（只跟 V 有关 → V 向也周期）、碾纹、泥泞、修补块。"""
    U, V = _uvw(nx, ny)
    _hard, _fill, wet = _fam_pal(fam)
    camber = 1.0 - ((V - 0.5) / 0.5) ** 2 * 0.30           # 排水微拱（几何）
    s = 0.13 / TILE_M
    wob = (gwh(U, V, 0.35, nx, ny, 4801, oct=2) - 0.5) * 0.030
    vv = V + wob
    rut = np.clip(np.exp(-((wdist(vv, 0.34) / s) ** 2))
                  + np.exp(-((wdist(vv, 0.66) / s) ** 2)), 0.0, 1.0)
    stamp = gwh2(U, V, 0.09, 0.026, nx, ny, 4811, oct=2)
    peb = np.zeros((ny, nx))
    if fam == "stone":
        f1, f2, cid = pworley(U * 16, V * 16, 16, 16, 4821, 0.80)
        setts = smoothstep(0.020, 0.13, np.clip(f2 - f1, 0.0, None))
        dome = np.sqrt(np.clip(0.50 - f1, 0.0, None))
        dome = dome / (dome.max() + 1e-9)
        alb = cmix(cid, (0.390, 0.406, 0.442), (0.645, 0.660, 0.692))
        alb = cmix(cellhw(U, V, 16, 16, 4831) * 0.28, alb, (0.600, 0.562, 0.510))
        base_j = cmix(gwh(U, V, 0.03, nx, ny, 4841, oct=2), (0.250, 0.242, 0.228),
                      (0.370, 0.356, 0.334))
        alb = cmix(setts, base_j, alb)
        h = 0.10 + setts * (0.34 + 0.66 * dome) * 0.62
        rough = lerp(0.94, lerp(0.60, 0.80, cid), setts)
        rut_dirt = cmix(gwh(U, V, 0.025, nx, ny, 4851, oct=2),
                        (0.300, 0.286, 0.262), (0.430, 0.410, 0.372))
        alb = cmix(rut * 0.42, alb, rut_dirt)          # 辙内积土发暗
        alb = cshade(alb, lerp(1.0, 1.06, rut * 0.5))  # 局部又被碾亮
        rough = rough * lerp(1.0, 0.72, rut * 0.7)
        alb = cmix(rut * 0.35, alb, cmix(stamp, (0.430, 0.432, 0.438),
                                         (0.560, 0.560, 0.562)))
    elif fam == "earth":
        alb = cmix(gwh(U, V, 0.75, nx, ny, 4911, oct=3), (0.360, 0.282, 0.202),
                   (0.575, 0.468, 0.348))
        alb = cmix(gwh(U, V, 0.14, nx, ny, 4921, oct=2) * 0.50, alb,
                   (0.300, 0.238, 0.174))
        alb = cmix(rut * 0.70, alb, cmix(stamp, (0.285, 0.222, 0.162),
                                         (0.372, 0.300, 0.220)))
        crown = np.exp(-((wdist(V, 0.50) / (s * 1.4)) ** 2))
        alb = cmix(crown * 0.30, alb, (0.570, 0.470, 0.352))
        alb = cshade(alb, lerp(0.92, 1.08, gwh(U, V, 0.03, nx, ny, 4931, oct=3)))
        f1c, f2c, _c = pworley(U * 6, V * 6, 6, 6, 4941, 0.50)
        crack = smoothstep(0.012, 0.0, np.clip(f2c - f1c, 0.0, None))
        alb = cshade(alb, 1.0 - crack * 0.14 * (1.0 - rut))
        f1p, f2p, _cp = pworley(U * 21, V * 21, 21, 21, 4951, 0.90)
        peb = (smoothstep(0.90, 0.99, cellhw(U, V, 21, 21, 4961))
               * smoothstep(0.0, 0.06, np.clip(f2p - f1p, 0.0, None)))
        alb = cmix(peb * 0.70, alb, (0.520, 0.484, 0.428))
        h = (0.50 - rut * 0.36 + crown * 0.16
             + gwh(U, V, 0.045, nx, ny, 4971, oct=3) * 0.24 + peb * 0.20
             - crack * 0.18)
        rough = np.clip(0.95 - rut * 0.10, 0.5, 1.0)
    else:
        f1, f2, cid = pworley(U * 21, V * 21, 21, 21, 5011, 0.92)
        peb = smoothstep(0.012, 0.10, np.clip(f2 - f1, 0.0, None))
        dome = np.sqrt(np.clip(0.50 - f1, 0.0, None))
        dome = dome / (dome.max() + 1e-9)
        alb = cmix(cid, (0.450, 0.430, 0.398), (0.680, 0.658, 0.612))
        alb = cmix(cellhw(U, V, 21, 21, 5021) * 0.55, alb, (0.310, 0.318, 0.330))
        dust = cmix(gwh(U, V, 0.04, nx, ny, 5031, oct=3), (0.300, 0.282, 0.252),
                    (0.440, 0.420, 0.382))
        alb = cmix(peb, dust, alb)
        alb = cmix(rut * 0.55, alb, cmix(stamp, (0.300, 0.286, 0.268),
                                         (0.390, 0.368, 0.338)))
        ash = _dotsw(nx, ny, 90, 5041, featw(0.011))
        alb = cmix(ash * 0.48, alb, (0.205, 0.208, 0.212))
        cinder = _dotsw(nx, ny, 24, 5051, featw(0.008))
        alb = cmix(cinder * 0.55, alb, (0.430, 0.205, 0.095))
        h = (0.12 + peb * (0.35 + 0.65 * dome) * 0.58 - rut * 0.30
             + ash * 0.10 + camber * 0.10)
        rough = np.clip(lerp(0.93, lerp(0.70, 0.87, cid), peb) - rut * 0.08,
                        0.4, 1.0)
    tramp = smoothstep(0.52, 0.86, gwh2(U, V, 0.14, 0.055, nx, ny, 5091, oct=2))
    alb = cshade(alb, lerp(1.0, 0.90, tramp * 0.40))   # 踩踏磨损（暗斑）
    hoof = _dotsw(nx, ny, 26, 5095, featw(0.020))
    alb = cshade(alb, lerp(1.0, 0.93, hoof * 0.5))     # 蹄印/脚印压痕
    h = h - hoof * 0.10
    mud = smoothstep(0.70, 0.94, gwh(U, V, 0.90, nx, ny, 5101, oct=3))
    alb = cmix(mud * 0.42, alb, wet)
    rough = rough * lerp(1.0, 0.62, mud)
    puddle = smoothstep(0.76, 0.95, gwh(U, V, 0.70, nx, ny, 5111, oct=2)) * rut
    alb = cmix(puddle * 0.75, alb, wet)
    rough = np.clip(rough * lerp(1.0, 0.20, puddle), 0.05, 1.0)
    # 修补块：矩形换料补丁（打破周期感最有效的一招）。U 向走环绕距离 → 仍可平铺
    for (u0, v0, w, hgt, sd) in ((0.10, 0.62, 0.30, 0.24, 5201),
                                 (0.64, 0.16, 0.24, 0.20, 5211)):
        ju = (U - u0 + 0.5) % 1.0 - 0.5
        jv = V - v0
        m = (smoothstep(w, w * 1.05, np.abs(ju))
             * smoothstep(hgt, hgt * 1.05, np.abs(jv)))
        pat = cmix(gwh(U, V, 0.02, nx, ny, sd, oct=2), _PATCH[fam][0], _PATCH[fam][1])
        pat = cshade(pat, lerp(0.90, 1.12, cellhw(U, V, 32, 32, sd + 7)))
        alb = cmix(m, pat, alb)
        h = h + m * 0.10
        rough = lerp(rough, 0.95, m)
    h = h + camber * 0.22
    return _packw(alb, h, rough, nx, ny, 5301, 0.030, ao=0.32, nstr=0.9)


# ============================================================ 过渡带（铺装 ↔ 土路）
# 两种材质被一条不规则边界咬合；带内 X 可平铺，Y 是"结构方向"。

def t_transition(kind, nx=128, ny=2 * CELL):
    U, V = _uvw(nx, ny)
    b = (0.5 + (gwh(U, V, 0.55, nx, ny, 6001, oct=3) - 0.5) * 1.5
         + (gwh(U, V, 0.16, nx, ny, 6011, oct=2) - 0.5) * 0.40)
    b = np.clip(b, 0.18, 0.86)
    pav = smoothstep(b - 0.030, b + 0.030, V)               # 1 = 上侧（铺装）
    if kind == "cobble_dirt":
        f1, f2, cid = pworley(U * 12, V * 12, 12, 12, 6021, 0.70)
        pm = smoothstep(0.025, 0.14, np.clip(f2 - f1, 0.0, None))
        pa = cmix(cid, (0.420, 0.400, 0.368), (0.680, 0.658, 0.616))
        pa = cmix(pm, cmix(gwh(U, V, 0.03, nx, ny, 6031, oct=2),
                           (0.240, 0.230, 0.214), (0.360, 0.342, 0.316)), pa)
        ph = 0.30 + pm * 0.55
        pr = lerp(0.94, 0.66, pm)
    else:
        f1, f2, cid = pworley(U * 4, V * 4, 4, 4, 6041, 0.52)
        sm = smoothstep(0.008, 0.040, np.clip(f2 - f1, 0.0, None))
        pa = cmix(cid, (0.560, 0.544, 0.512), (0.735, 0.716, 0.680))
        pa = cshade(pa, lerp(0.92, 1.08, gwh2(U, V, 0.013, 0.070, nx, ny, 6051)))
        if kind == "brick_grass":
            pa = cmix(gwh(U, V, 0.20, nx, ny, 6061, oct=2) * 0.5, pa,
                      (0.640, 0.360, 0.250))
        pa = cmix(sm, cmix(gwh(U, V, 0.05, nx, ny, 6071, oct=2),
                           (0.330, 0.318, 0.296), (0.440, 0.424, 0.394)), pa)
        ph = 0.30 + sm * 0.60
        pr = lerp(0.94, 0.82, sm)
    if kind == "brick_grass":
        fu = smoothstep(0.42, 0.62, gwh(U, V, 0.16, nx, ny, 6081, oct=3))
        fu = smoothstep(0.18, 0.86, fu)
        g = cmix(gwh(U, V, 0.30, nx, ny, 6091, oct=2), (0.300, 0.430, 0.145),
                 (0.155, 0.252, 0.078))
        g = cshade(g, lerp(0.72, 1.26, gwh2(U, V, 0.04, 0.09, nx, ny, 6101, oct=2)))
        ga = cmix(fu, (0.400, 0.335, 0.240), g)
        gh, gr = 0.30 + fu * 0.60, 0.90
    else:
        da = cmix(gwh(U, V, 0.60, nx, ny, 6111, oct=3), (0.365, 0.288, 0.208),
                  (0.580, 0.474, 0.352))
        da = cmix(gwh(U, V, 0.12, nx, ny, 6121, oct=2) * 0.5, da,
                  (0.300, 0.240, 0.176))
        f1p, f2p, _cp = pworley(U * 21, V * 21, 21, 21, 6141, 0.9)
        peb = (smoothstep(0.90, 0.99, cellhw(U, V, 21, 21, 6131))
               * smoothstep(0.0, 0.06, np.clip(f2p - f1p, 0.0, None)))
        da = cmix(peb * 0.7, da, (0.520, 0.484, 0.428))
        da = cshade(da, lerp(0.92, 1.08, gwh(U, V, 0.03, nx, ny, 6151, oct=3)))
        ga = da
        gh = 0.35 + peb * 0.24 + gwh(U, V, 0.05, nx, ny, 6161, oct=3) * 0.24
        gr = 0.95
    alb = cmix(pav, ga, pa)
    h = pav * ph + (1.0 - pav) * gh
    rough = pav * pr + (1.0 - pav) * gr
    # 咬合带：边界附近撒几颗"垫脚石"（不规则边界的读法来源）
    band = np.exp(-(((V - b) / 0.070) ** 2))
    bridge = _dotsw(nx, ny, 26, 6201, featw(0.014)) * band
    alb = cmix(bridge * 0.8, alb, (0.580, 0.562, 0.528))
    h = h + bridge * 0.28
    return _packw(alb, h, rough, nx, ny, 6301, 0.024, ao=0.30, nstr=0.9)


# ============================================================ 做旧 decal 组（单件，带 alpha）
# 全部**光照中性**（albedo + 微 AO）；不带任何方向性明暗，引擎随机撒在场景上打破规律。

def d_stain(nx=32, ny=32):
    """污渍：油/酒渍暗斑，边缘不规则。"""
    U, V = _uvw(nx, ny)
    r = np.hypot(U - 0.5, V - 0.5)
    bl = gwh(U, V, 0.25, nx, ny, 7001, oct=3)
    m = smoothstep(0.46, 0.20, r + (bl - 0.5) * 0.55)
    dark = cmix(gwh(U, V, 0.10, nx, ny, 7011, oct=2),
                (0.245, 0.222, 0.196), (0.360, 0.336, 0.300))
    h = 0.5 - m * 0.10
    rough = np.clip(0.94 - m * 0.20, 0.3, 1.0)
    return _packw(dark, h, rough, nx, ny, 7021, 0.006, ao=0.0, alpha=m * 0.88)


def d_puddle(nx=48, ny=32):
    """水洼：不规则深色 + 湿边，低粗糙度（吃天光反射）。"""
    U, V = _uvw(nx, ny)
    r = np.hypot(U - 0.5, (V - 0.5) * 1.35)
    bl = gwh(U, V, 0.30, nx, ny, 7101, oct=3) + gwh(U, V, 0.12, nx, ny, 7111, oct=2)
    m = smoothstep(0.42, 0.24, r + (bl - 1.0) * 0.42)
    h = 0.5 - m * 0.14
    rough = np.clip(0.90 - m * 0.72, 0.05, 1.0)
    return _packw((0.185, 0.196, 0.212), h, rough, nx, ny, 7121, 0.005,
                  ao=0.0, alpha=np.clip(m * 0.94, 0.0, 1.0))


def d_moss(nx=48, ny=48):
    """苔藓斑：叶状边缘、带一点厚度。"""
    U, V = _uvw(nx, ny)
    m1 = gwh(U, V, 0.22, nx, ny, 7201, oct=3)
    m2 = gwh2(U, V, 0.05, 0.16, nx, ny, 7211, oct=2)
    m = smoothstep(0.54, 0.74, m1 * 0.8 + m2 * 0.2)
    m = np.clip(m * 1.2, 0.0, 1.0)
    alb = cmix(gwh(U, V, 0.06, nx, ny, 7221, oct=2),
               (0.100, 0.148, 0.052), (0.215, 0.300, 0.096))
    return _packw(alb, 0.5 + m * 0.22, np.clip(0.92, 0.6, 1.0), nx, ny, 7231,
                  0.010, ao=0.25, alpha=m * 0.92)


def d_crack(nx=64, ny=64):
    """裂缝：多尺度网状裂纹（Worley 边）。"""
    U, V = _uvw(nx, ny)
    f1a, f2a, _a = pworley(U * 4, V * 4, 4, 4, 7301, 0.55)
    f1b, f2b, _b = pworley(U * 9, V * 9, 9, 9, 7311, 0.60)
    g1 = smoothstep(0.012, 0.0, np.clip(f2a - f1a, 0.0, None))
    g2 = smoothstep(0.008, 0.0, np.clip(f2b - f1b, 0.0, None)) * 0.7
    g = np.clip(g1 + g2 * (1.0 - g1), 0.0, 1.0)
    g = g * smoothstep(0.30, 0.62, gwh(U, V, 0.40, nx, ny, 7321, oct=3))
    h = 0.5 - g * 0.30
    return _packw((0.185, 0.174, 0.160), h, np.clip(0.95, 0.5, 1.0), nx, ny, 7331,
                  0.010, ao=0.0, alpha=np.clip(g * 0.85, 0.0, 1.0))


def d_debris(nx=48, ny=32):
    """散落碎屑：干草 + 小石 + 细枝。"""
    U, V = _uvw(nx, ny)
    straw = gwh2(U, V, 0.22, 0.018, nx, ny, 7401, oct=2)
    m = smoothstep(0.62, 0.86, straw)
    st = _dotsw(nx, ny, 16, 7411, featw(0.010))
    m = np.clip(m * 0.75 + st * 0.75, 0.0, 1.0)
    alb = cmix(gwh(U, V, 0.05, nx, ny, 7421, oct=2),
               (0.560, 0.500, 0.320), (0.700, 0.640, 0.420))
    peb = _dotsw(nx, ny, 10, 7431, featw(0.012))
    alb = cmix(peb * 0.9, alb, (0.520, 0.500, 0.462))
    h = 0.5 + m * 0.10 + peb * 0.18
    return _packw(alb, h, np.clip(0.93 - peb * 0.05, 0.5, 1.0), nx, ny, 7441,
                  0.010, ao=0.20, alpha=np.clip(m * 0.80 + peb * 0.85, 0.0, 1.0))


def d_worn(nx=64, ny=32):
    """磨光带：被车马人脚磨亮磨平的一条（横向拉长、边缘参差）。"""
    U, V = _uvw(nx, ny)
    blade = smoothstep(0.16, 0.40, V) * (1.0 - smoothstep(0.60, 0.86, V))
    blade = blade * np.clip(1.0 + (gwh(U, V, 0.14, nx, ny, 7501, oct=2) - 0.5) * 2.2,
                            0.0, 1.0)
    blade = smoothstep(0.12, 0.72, blade)
    alb = cmix(gwh(U, V, 0.08, nx, ny, 7511, oct=2),
               (0.640, 0.628, 0.604), (0.790, 0.776, 0.748))
    return _packw(alb, 0.5 + blade * 0.06,
                  np.clip(0.62 + (1.0 - blade) * 0.30, 0.2, 1.0), nx, ny, 7521,
                  0.004, ao=0.0, alpha=blade * 0.62)


def d_patch(nx=48, ny=48):
    """修补块：换料补丁（碎石/矿渣），边缘硬、周围撒落碎料。"""
    U, V = _uvw(nx, ny)
    wob = (gwh(U, V, 0.20, nx, ny, 7601, oct=2) - 0.5) * 0.16
    inside = smoothstep(0.30, 0.36,
                        np.maximum(np.abs(U - 0.5), np.abs(V - 0.5)) + wob)
    m = 1.0 - inside
    f1, f2, cid = pworley(U * 22, V * 22, 22, 22, 7611, 0.92)
    peb = smoothstep(0.02, 0.12, np.clip(f2 - f1, 0.0, None))
    pad = cmix(cid, (0.330, 0.310, 0.276), (0.540, 0.512, 0.452))
    pad = cmix(peb, cmix(gwh(U, V, 0.03, nx, ny, 7621, oct=2),
                         (0.220, 0.212, 0.202), (0.330, 0.318, 0.300)), pad)
    spill = _dotsw(nx, ny, 30, 7631, featw(0.010)) * (1.0 - m)
    h = 0.5 + m * 0.06 + peb * 0.12 * m + spill * 0.06
    return _packw(pad, h, np.clip(0.94 - peb * 0.04, 0.5, 1.0), nx, ny, 7641,
                  0.012, ao=0.25,
                  alpha=np.clip(m * 0.95 + spill * 0.35, 0.0, 1.0))


def d_door_path(nx=32, ny=3 * CELL):
    """门口踩出来的通道（32×96 = 1×3 格）：压实磨光竖条，下缘参差、两侧被土侵。

    摆在**路肩带上**：每栋门口一条，从门槛往下接到路缘 —— "磨损集中在门口"的实现
    方式（门的 X 只有建筑知道，所以做成单件 decal 由引擎按门位摆放）。
    """
    U, V = _uvw(nx, ny)
    w = 0.62 + (gwh(U, V, 0.16, nx, ny, 7701, oct=2) - 0.5) * 0.55
    side = np.abs(U - 0.5) * 2.0
    m = smoothstep(w, w * 0.55, side) * smoothstep(0.02, 0.20, V)
    edge = gwh2(U, V, 0.06, 0.02, nx, ny, 7711, oct=2)
    m = smoothstep(0.10, 0.70, np.clip(m * (0.75 + edge * 0.5), 0.0, 1.0))
    stone = cmix(gwh(U, V, 0.05, nx, ny, 7721, oct=2),
                 (0.505, 0.492, 0.468), (0.625, 0.610, 0.582))
    stone = cshade(stone, lerp(0.94, 1.08, gwh2(U, V, 0.02, 0.06, nx, ny, 7731)))
    grit = gwh2(U, V, 0.025, 0.012, nx, ny, 7741, oct=2)
    stone = cshade(stone, lerp(0.92, 1.08, grit))
    soil = cmix(gwh(U, V, 0.12, nx, ny, 7751, oct=2), (0.360, 0.292, 0.212),
                (0.520, 0.424, 0.312))
    alb = cmix(m, soil, stone)
    h = 0.5 + m * 0.12 + grit * 0.05
    return _packw(alb, h, np.clip(lerp(0.95, 0.72, m), 0.3, 1.0), nx, ny, 7761,
                  0.008, ao=0.15, alpha=np.clip(0.05 + m * 0.42, 0.0, 1.0))


# ============================================================ 低频大尺度斑驳遮蔽图
# 8×8 格（256px）尺度的灰度乘图，用来打破 1.68m 周期感。
# **编码约定**：0.5 = 不变，>0.5 变亮、<0.5 变暗；引擎按 `mult = 1 + (m-0.5)*k`
# 使用（k 建议 0.35~0.55）。它是**乘图，不是贴图**：不带光照，也不带颜色。
MOTTLE_PX = 8 * CELL
MOTTLE_K = 0.45


def m_mottle(seed=9001, nx=MOTTLE_PX):
    U, V = _uvw(nx, nx)
    n = 0.6 * gwh(U, V, 1.6, nx, nx, seed, oct=3) \
        + 0.4 * gwh(U, V, 0.75, nx, nx, seed + 11, oct=2)
    n = pblur(n, 1)
    lo, hi = float(n.min()), float(n.max())
    t = (n - lo) / max(1e-9, hi - lo)
    return 0.5 + (t - 0.5)


# ============================================================ 像素级材质层（拼补丁用）
# 街面长条与动态件是**一次拼好**的（红警式预制 + 泰拉瑞亚式邻居变体，都在烘焙时解决），
# 所以这里需要一批"按像素直接铺某种料"的小函数：每块补丁从几种料里挑一种。

def _pal(kind):
    if kind == "brick_old":      # 旧砖：褪色、发灰、色差大
        return ((0.380, 0.245, 0.205), (0.610, 0.400, 0.320),
                (0.470, 0.455, 0.430), (0.590, 0.575, 0.545))
    if kind == "brick_new":      # 新砖（补丁里偶见：色差明显的"新补的"）
        return ((0.400, 0.170, 0.120), (0.660, 0.360, 0.240),
                (0.585, 0.560, 0.500), (0.660, 0.640, 0.585))
    if kind == "granite":
        return ((0.430, 0.428, 0.430), (0.700, 0.694, 0.690),
                (0.330, 0.326, 0.322), (0.440, 0.435, 0.428))
    if kind == "marble":
        return ((0.640, 0.632, 0.616), (0.830, 0.824, 0.808),
                (0.470, 0.462, 0.448), (0.610, 0.602, 0.585))
    if kind == "gravel":
        return ((0.470, 0.452, 0.415), (0.715, 0.690, 0.638),
                (0.330, 0.312, 0.278), (0.460, 0.438, 0.396))
    if kind == "rubble":         # 混合碎石：破石板 + 砾石
        return ((0.400, 0.392, 0.372), (0.680, 0.664, 0.628),
                (0.300, 0.290, 0.272), (0.430, 0.416, 0.390))
    if kind == "dirt":
        return ((0.360, 0.282, 0.202), (0.570, 0.462, 0.344),
                (0.300, 0.238, 0.174), (0.420, 0.342, 0.250))
    if kind == "mud":
        return ((0.245, 0.190, 0.140), (0.400, 0.325, 0.240),
                (0.195, 0.150, 0.112), (0.300, 0.238, 0.176))
    if kind == "grass":
        return ((0.250, 0.380, 0.120), (0.150, 0.255, 0.075),
                (0.360, 0.300, 0.200), (0.470, 0.410, 0.290))
    if kind == "cobble":         # 小方石
        return ((0.400, 0.412, 0.438), (0.645, 0.658, 0.688),
                (0.240, 0.232, 0.218), (0.360, 0.348, 0.326))
    return ((0.450, 0.450, 0.450), (0.700, 0.700, 0.700),
            (0.300, 0.300, 0.300), (0.400, 0.400, 0.400))


def _px_pave(U, V, nx, ny, sd, kind):
    """铺装层：砖（错缝）/ 方石 / 石板 / 大理石 / 碎石 的排布（按 kind 选）。"""
    lo, hi, ma, mb = _pal(kind)
    if kind in ("brick_old", "brick_new"):
        ncol, nrow = klatt(nx, 0.21), klatt(ny, 0.105)
        x, y = U * ncol, V * nrow
        row = np.floor(y).astype(np.int64)
        xo = x + np.where(row % 2 == 1, 0.5, 0.0)
        col = np.floor(xo).astype(np.int64)
        fx, fy = xo - col, y - row
        dx = np.minimum(fx, 1.0 - fx)
        dy = np.minimum(fy, 1.0 - fy)
        wm = 0.80 + 0.55 * gwh(U, V, 0.05, nx, ny, sd, oct=2)
        mask = (smoothstep(0.030 * wm, 0.050 * wm, dx)
                * smoothstep(0.045 * wm, 0.070 * wm, dy))
        bid = cellhw(U, V, ncol, nrow, sd + 3)
        alb = cmix(bid, lo, hi)
        alb = cmix(smoothstep(0.82, 0.98, cellhw(U, V, ncol, nrow, sd + 9)) * 0.7,
                   alb, (0.500, 0.485, 0.462))
        h = 0.14 + mask * 0.72
        rough = lerp(0.96, 0.89, mask)
    else:
        metres = {"cobble": 0.12, "granite": 0.34, "marble": 0.56,
                  "rubble": 0.30}.get(kind, 0.30)
        ku, kv = klatt(nx, metres), klatt(ny, metres)
        jit = {"cobble": 0.88, "granite": 0.30, "marble": 0.18,
               "rubble": 0.75}.get(kind, 0.5)
        f1, f2, cid = pworley(U * ku, V * kv, ku, kv, sd, jit)
        mask = smoothstep(0.010, 0.055 if kind == "marble" else 0.09,
                          np.clip(f2 - f1, 0.0, None))
        dome = np.sqrt(np.clip(0.52 - f1, 0.0, None))
        dome = dome / (dome.max() + 1e-9)
        alb = cmix(cid, lo, hi)
        alb = cmix(cellhw(U, V, ku, kv, sd + 11) * (0.35 if kind == "granite" else 0.5),
                   alb, cmix(cid, lo, hi) * 1.10)
        if kind == "marble":          # 石纹
            vein = gwh2(U, V, 0.90, 0.10, nx, ny, sd + 13, oct=3)
            alb = cshade(alb, lerp(0.90, 1.06, np.abs(vein - 0.5) * 2.0))
        h = 0.10 + mask * (0.25 + 0.75 * dome) * (0.62 if kind != "marble" else 0.45)
        rough = lerp(0.95, lerp(0.66, 0.86, cid), mask)
    mor = cmix(gwh(U, V, 0.03, nx, ny, sd + 5, oct=2), ma, mb)
    alb = cmix(mask, mor, alb)
    return alb, h, rough


def _px_loose(U, V, nx, ny, sd, kind):
    """散料层：砾石 / 土 / 泥 / 草（不同的"件"尺寸与走向）。"""
    lo, hi, ma, _mb = _pal(kind)
    if kind == "grass":
        tuft = smoothstep(0.40, 0.62, gwh(U, V, 0.16, nx, ny, sd, oct=3))
        tuft = smoothstep(0.18, 0.86, np.clip(
            tuft * (1.0 + (gwh(U, V, 0.05, nx, ny, sd + 1, oct=2) - 0.5) * 1.8),
            0.0, 1.0))
        alb = cmix(gwh(U, V, 0.30, nx, ny, sd + 2, oct=2), lo, hi)
        alb = cshade(alb, lerp(0.72, 1.26,
                               gwh2(U, V, 0.05, 0.10, nx, ny, sd + 3, oct=2)))
        h = 0.30 + tuft * 0.55
        return alb, h, np.full_like(h, 0.90)
    metres = {"gravel": 0.08, "rubble": 0.14, "dirt": 0.30, "mud": 0.40}.get(kind, 0.12)
    ku, kv = klatt(nx, metres), klatt(ny, metres)
    f1, f2, cid = pworley(U * ku, V * kv, ku, kv, sd, 0.92 if kind != "dirt" else 0.7)
    mask = smoothstep(0.012, 0.10, np.clip(f2 - f1, 0.0, None))
    dome = np.sqrt(np.clip(0.50 - f1, 0.0, None))
    dome = dome / (dome.max() + 1e-9)
    alb = cmix(cid, lo, hi)
    alb = cmix(cellhw(U, V, ku, kv, sd + 7) * 0.45, alb, ma)
    alb = cshade(alb, lerp(0.90, 1.10, gwh(U, V, 0.03, nx, ny, sd + 9, oct=3)))
    if kind == "dirt":
        band = np.sin(2.0 * math.pi * (klatt(ny, 0.14) * V
                                       + 0.3 * (gwh(U, V, 1.0, nx, ny, sd + 11) - 0.5)))
        alb = cshade(alb, lerp(0.958, 1.038, band * 0.5 + 0.5))
    h = 0.12 + mask * (0.30 + 0.70 * dome) * 0.60
    rough = np.clip(lerp(0.94, lerp(0.70, 0.88, cid), mask), 0.4, 1.0)
    return alb, h, rough


# ============================================================ 静态基础层：烘焙长条
# 一次拼好整条街的地面（补丁 / 车辙 / 材质过渡 / 路肩啃噬边 / 残破低路缘），引擎只做
# "横向平铺 / 整条切换 + decal 撒布"，不在引擎里 autotile。
# 横向是**周期函数**（可平铺），纵向是结构方向（上=建筑基线，下=道路）。
STRIP_W = 4096                 # 128 格 = 53.8m
STRIP_SHOULDER = 96            # 路肩 = 3 格（与建筑落地箱 ground_y~+96 同口径）
STRIP_KERB = 8                 # 路缘石高 = 10.5cm（≤ 半砖），且断续残缺
STRIP_ROAD = 160               # 道路带 5 格
STRIP_H = STRIP_SHOULDER + STRIP_KERB + STRIP_ROAD

#: 区域档次 → 面层主料菜单（"按区域分档次"）
ZONE_MENU = {
    "plaza": ["marble", "granite", "marble", "granite", "cobble", "brick_old"],
    "street": ["brick_old", "brick_old", "brick_old", "gravel", "granite",
               "brick_new", "rubble", "cobble"],
    "alley": ["dirt", "dirt", "gravel", "rubble", "dirt", "grass"],
    "gate": ["mud", "mud", "dirt", "gravel", "mud", "rubble"],
}


def b_street_strip(seed=0, nx=STRIP_W, ny=STRIP_H, zone="street"):
    """烘焙一条街的地面长条（**静态基础层**）。

    zone = 区域档次（plaza / street / alley / gate）。补丁、车辙、路缘残缺、
    路肩啃噬边都在这里一次算完。
    """
    U, V = _uvw(nx, ny)
    y_k = STRIP_ROAD / float(ny)                 # 路缘下缘（= 道路带顶）
    y_s = (STRIP_ROAD + STRIP_KERB) / float(ny)  # 路缘上缘（= 路肩底）
    j1 = (gwh(U, V, 0.55, nx, ny, seed + 101, oct=3) - 0.5) * 0.016
    j2 = (gwh(U, V, 0.55, nx, ny, seed + 103, oct=3) - 0.5) * 0.016
    road = V < (y_k + j1)                        # 有机边界（不是直线）
    shoulder = V >= (y_s + j2)
    # ---- 面层主料：按补丁（Worley 单元）选料 = "各种补丁拼在一起"
    ku, kv = klatt(nx, 1.1), max(2, klatt(ny, 1.1))   # 补丁 ≈ 1.1m（太粗会读成竖条）
    f1, f2, cid = pworley(U * ku, V * kv, ku, kv, seed + 201, 0.72)
    menu = ZONE_MENU[zone]
    pick = np.minimum((cid * len(menu)).astype(np.int64), len(menu) - 1)
    layers = {}
    for kd in sorted(set(menu)):
        layers[kd] = (_px_pave(U, V, nx, ny, seed + 311, kd)
                      if kd in ("brick_old", "brick_new", "granite", "marble",
                                "cobble", "rubble")
                      else _px_loose(U, V, nx, ny, seed + 311, kd))
    alb = np.zeros((ny, nx, 3))
    h = np.zeros((ny, nx))
    rough = np.zeros((ny, nx))
    for i, kd in enumerate(menu):
        m = (pick == i)
        if not m.any():
            continue
        a, hh, rr = layers[kd]
        alb = np.where(m[..., None], a, alb)
        h = np.where(m, hh, h)
        rough = np.where(m, rr, rough)
    # 补丁边缘的"脏线"（不规则 + 色差 → 补丁读得出来）
    edge = smoothstep(0.020, 0.0, np.clip(f2 - f1, 0.0, None))
    dirty = cmix(gwh(U, V, 0.05, nx, ny, seed + 401, oct=2),
                 (0.230, 0.208, 0.180), (0.330, 0.300, 0.262))
    alb = cmix(edge * 0.75, alb, dirty)
    h = h - edge * 0.16
    # ---- 车辙：沿 X 连续三道，辙内压实、露浅色基层，局部汇成泥洼
    s = 0.13 / TILE_M
    rut = np.zeros((ny, nx))
    for vc in (0.10, 0.30, 0.52):
        wob = (gwh(U, V, 0.35, nx, ny, seed + 501, oct=2) - 0.5) * 0.030
        rut = np.maximum(rut, np.exp(-((wdist(V + wob, vc) / s) ** 2)))
    rut = rut * road * (0.55 + 0.45 * smoothstep(
        0.35, 0.75, gwh(U, V, 0.8, nx, ny, seed + 511, oct=2)))
    base = cmix(gwh(U, V, 0.025, nx, ny, seed + 521, oct=2),
                (0.560, 0.545, 0.520), (0.700, 0.686, 0.658))
    alb = cmix(rut * 0.55, alb, base)
    h = h - rut * 0.30
    rough = rough * lerp(1.0, 0.80, rut * 0.7)
    mudp = smoothstep(0.76, 0.96, gwh(U, V, 0.75, nx, ny, seed + 531, oct=2)) * rut
    mudc = cmix(gwh(U, V, 0.10, nx, ny, seed + 541, oct=2),
                (0.235, 0.180, 0.132), (0.360, 0.290, 0.212))
    alb = cmix(mudp * 0.80, alb, mudc)
    rough = np.clip(rough * lerp(1.0, 0.35, mudp), 0.05, 1.0)
    # ---- 路缘石：低（8px ≈ 10.5cm ≤ 半砖）、断续残缺、缺处被土/草替代
    kerb_seg = klatt(nx, 0.26)
    seg = np.mod(np.floor(U * kerb_seg).astype(np.int64), kerb_seg)
    zero = np.zeros_like(seg)
    present = smoothstep(0.30, 0.45, _hash01(seg, zero, seed + 601))
    present = present * (1.0 - smoothstep(0.86, 0.98,
                                          gwh(U, V, 0.45, nx, ny, seed + 611, oct=2)))
    bandk = (smoothstep(y_k - 0.010, y_k + 0.004, V)
             * (1.0 - smoothstep(y_s - 0.004, y_s + 0.010, V)))
    kstone = cmix(_hash01(seg, zero, seed + 621),
                  (0.520, 0.510, 0.486), (0.700, 0.688, 0.660))
    kstone = cshade(kstone, lerp(0.92, 1.08,
                                 gwh(U, V, 0.03, nx, ny, seed + 631, oct=2)))
    km = bandk * present
    alb = cmix(km * 0.92, alb, kstone)
    h = h + km * 0.55
    rough = lerp(rough, 0.90, km * 0.8)
    gap = bandk * (1.0 - present)
    fillk = smoothstep(0.45, 0.60, gwh(U, V, 0.30, nx, ny, seed + 641, oct=2))
    soilf = cmix(gwh(U, V, 0.06, nx, ny, seed + 651, oct=2),
                 (0.330, 0.272, 0.196), (0.470, 0.390, 0.290))
    grassf = cmix(gwh(U, V, 0.20, nx, ny, seed + 661, oct=2),
                  (0.250, 0.372, 0.120), (0.150, 0.250, 0.075))
    alb = cmix(gap * 0.85, alb, cmix(fillk, soilf, grassf))
    h = h + gap * 0.10
    # ---- 路肩：混合面 + 上缘被草/土啃噬（有机边界，不是直线）
    nib = smoothstep(0.62, 0.90, gwh(U, V, 0.60, nx, ny, seed + 701, oct=3))
    nibv = smoothstep(0.84, 1.0, V) * nib
    grass2 = cmix(gwh(U, V, 0.18, nx, ny, seed + 711, oct=2),
                  (0.245, 0.368, 0.118), (0.145, 0.246, 0.072))
    soil2 = cmix(gwh(U, V, 0.07, nx, ny, seed + 721, oct=2),
                 (0.350, 0.288, 0.208), (0.500, 0.415, 0.310))
    alb = cmix(nibv * 0.80, alb,
               cmix(smoothstep(0.30, 0.70, gwh(U, V, 0.25, nx, ny, seed + 731,
                                               oct=2)), soil2, grass2))
    h = h + nibv * 0.12
    trav = (smoothstep(0.45, 0.85, gwh(U, V, 0.80, nx, ny, seed + 741, oct=2))
            * smoothstep(y_s + 0.04, y_s + 0.14, V) * shoulder)
    alb = cshade(alb, lerp(1.0, 1.10, trav * 0.40))
    rough = rough * lerp(1.0, 0.90, trav * 0.5)
    alb = cshade(alb, np.where(shoulder, 0.965, 1.0))   # 路肩整体更旧更土
    return _packw(alb, h, rough, nx, ny, seed + 801, 0.030, ao=0.26, nstr=0.9)


# ============================================================ 动态建造层：网格拼接件
# RTS 建造：玩家在 32px 网格上自由建/拆 → "落地面环 / 门前径 / 邻居过渡件"必须跟随
# 建筑动态拼合，**不能烘进长条**。件一律按网格锚点对齐。
PIECE_CELLS = 4                 # 落地面环可平铺段宽（4 格）
RING_H = 96                     # 落地面环高 = 3 格 = 建筑落地箱口径


def p_ring_mid(seed=0, nx=PIECE_CELLS * CELL, ny=RING_H):
    """落地面环·中段（4 格可平铺）：夯土/碎石/旧石板混合面，横向周期。"""
    U, V = _uvw(nx, ny)
    ku, kv = klatt(nx, 0.9), max(2, klatt(ny, 0.9))
    _f1, _f2, cid = pworley(U * ku, V * kv, ku, kv, seed + 11, 0.75)
    menu = ["dirt", "gravel", "rubble", "dirt", "brick_old", "grass"]
    pick = np.minimum((cid * len(menu)).astype(np.int64), len(menu) - 1)
    alb = np.zeros((ny, nx, 3))
    h = np.zeros((ny, nx))
    rough = np.zeros((ny, nx))
    for i, kd in enumerate(menu):
        m = (pick == i)
        if not m.any():
            continue
        a, hh, rr = (_px_pave(U, V, nx, ny, seed + 21, kd)
                     if kd in ("brick_old", "rubble")
                     else _px_loose(U, V, nx, ny, seed + 21, kd))
        alb = np.where(m[..., None], a, alb)
        h = np.where(m, hh, h)
        rough = np.where(m, rr, rough)
    alb = cshade(alb, 1.0 - smoothstep(0.90, 1.0, V) * 0.14)   # 贴墙一线接触暗
    nib = (smoothstep(0.55, 0.85, gwh(U, V, 0.35, nx, ny, seed + 31, oct=3))
           * (1.0 - smoothstep(0.10, 0.0, V)))
    g = cmix(gwh(U, V, 0.15, nx, ny, seed + 41, oct=2),
             (0.245, 0.368, 0.118), (0.145, 0.246, 0.072))
    alb = cmix(nib * 0.7, alb, g)
    return _packw(alb, h + 0.10 * V, rough, nx, ny, seed + 51, 0.018, ao=0.26, nstr=0.9)


def p_ring_cap(seed=0, side="l", nx=3 * CELL, ny=RING_H):
    """落地面环·端头（3 格）：外缘被草/土啃成有机边界（不是直线切）。"""
    U, V = _uvw(nx, ny)
    P = U if side == "r" else (1.0 - U)          # 0 = 内侧（贴建筑）1 = 外侧
    d = 1.0 - P
    wob = (gwh(U, V, 0.30, nx, ny, seed + 61, oct=3) - 0.5) * 0.55
    inside = smoothstep(0.72 + wob, 0.34 + wob, d)
    alb = cmix(gwh(U, V, 0.9, nx, ny, seed + 71, oct=2),
               (0.470, 0.388, 0.278), (0.620, 0.530, 0.400))
    alb = cshade(alb, lerp(0.90, 1.10, gwh(U, V, 0.05, nx, ny, seed + 81, oct=3)))
    grit = gwh2(U, V, 0.045, 0.03, nx, ny, seed + 91, oct=2)
    alb = cshade(alb, lerp(0.90, 1.10, grit))
    kp = klatt(nx, 0.09)
    f1p, f2p, _cp = pworley(U * kp, V * kp, kp, kp, seed + 111, 0.9)
    peb = (smoothstep(0.92, 1.0, cellhw(U, V, kp, kp, seed + 101))
           * smoothstep(0.0, 0.06, np.clip(f2p - f1p, 0.0, None)))
    alb = cmix(peb * 0.6, alb, (0.560, 0.542, 0.508))
    h = 0.5 + grit * 0.22 + peb * 0.20
    rough = np.clip(0.95 - grit * 0.03, 0.5, 1.0)
    gg = cmix(gwh(U, V, 0.14, nx, ny, seed + 121, oct=2),
              (0.245, 0.368, 0.118), (0.145, 0.246, 0.072))
    alb = cmix(1.0 - inside, gg, alb)
    h = h * inside + 0.30 * (1.0 - inside)
    alb = cshade(alb, 1.0 - smoothstep(0.90, 1.0, V) * 0.14)
    return _packw(alb, h, rough, nx, ny, seed + 131, 0.018, ao=0.26,
                  nstr=0.9, alpha=inside)


def p_edge_h(seed=0, side="l", nx=PIECE_CELLS * CELL, ny=RING_H):
    """邻居过渡件·边件：邻居**有建筑**的那一侧不铺落地面环，改铺这条融合带。"""
    U, V = _uvw(nx, ny)
    P = U if side == "r" else (1.0 - U)
    alb = cmix(gwh(U, V, 0.55, nx, ny, seed + 141, oct=3),
               (0.400, 0.318, 0.222), (0.560, 0.470, 0.352))
    g = cmix(gwh(U, V, 0.16, nx, ny, seed + 151, oct=2),
             (0.250, 0.372, 0.120), (0.150, 0.250, 0.075))
    mixm = smoothstep(0.25, 0.85, gwh(U, V, 0.22, nx, ny, seed + 161, oct=2))
    alb = cmix(mixm * 0.75, alb, g)
    grit = gwh2(U, V, 0.05, 0.03, nx, ny, seed + 171, oct=2)
    alb = cshade(alb, lerp(0.90, 1.10, grit))
    alb = cmix(smoothstep(0.55, 0.95, P) * 0.5, alb,
               cmix(gwh(U, V, 0.05, nx, ny, seed + 181, oct=2),
                    (0.560, 0.545, 0.520), (0.700, 0.686, 0.658)))
    h = 0.45 + grit * 0.20 + mixm * 0.12
    rough = np.clip(0.95 - grit * 0.03, 0.5, 1.0)
    alb = cshade(alb, 1.0 - smoothstep(0.90, 1.0, V) * 0.14)
    return _packw(alb, h, rough, nx, ny, seed + 191, 0.016, ao=0.26, nstr=0.9)


def p_path(seed=0, nx=4 * CELL, ny=RING_H + CELL):
    """门前踩踏小径：从门口（V=1 中点）扇形展开接到道路（V=0）的有机形状。

    锚点：**上边中点 = 门口中点，下边 = 道路带边**。带 alpha，引擎按门位摆。
    """
    U, V = _uvw(nx, ny)
    half = 0.16 + (1.0 - V) * 0.34               # 上窄下宽的扇形
    wob = (gwh(U, V, 0.25, nx, ny, seed + 201, oct=3) - 0.5) * 0.30
    m = smoothstep(half + wob * 0.12, half * 0.55 + wob * 0.12,
                   np.abs(U - 0.5) * 2.0) * smoothstep(0.0, 0.06, V)
    stone = cmix(gwh(U, V, 0.06, nx, ny, seed + 211, oct=2),
                 (0.500, 0.488, 0.462), (0.640, 0.626, 0.596))
    stone = cshade(stone, lerp(0.94, 1.08,
                               gwh2(U, V, 0.022, 0.06, nx, ny, seed + 221)))
    soil = cmix(gwh(U, V, 0.10, nx, ny, seed + 231, oct=2),
                (0.360, 0.292, 0.212), (0.510, 0.418, 0.312))
    alb = cmix(m, soil, stone)
    h = 0.45 + m * 0.14
    rough = np.clip(lerp(0.95, 0.74, m), 0.3, 1.0)
    return _packw(alb, h, rough, nx, ny, seed + 241, 0.010, ao=0.16,
                  alpha=np.clip(0.06 + m * 0.60, 0.0, 1.0))


def _cap_l(seed=0, nx=96, ny=RING_H):
    return p_ring_cap(seed, "l", nx, ny)


def _cap_r(seed=0, nx=96, ny=RING_H):
    return p_ring_cap(seed, "r", nx, ny)


def _edge_l(seed=0, nx=128, ny=RING_H):
    return p_edge_h(seed, "l", nx, ny)


def _edge_r(seed=0, nx=128, ny=RING_H):
    return p_edge_h(seed, "r", nx, ny)


def _path_a(seed=0, nx=128, ny=128):
    return p_path(0, nx, ny)


def _path_b(seed=0, nx=128, ny=128):
    return p_path(131, nx, ny)


def _path_c(seed=0, nx=96, ny=128):
    return p_path(271, nx, ny)


#: 动态件登记表（格尺寸 / 锚点 / 适用邻居掩码）
PIECES = [
    dict(key="p_ring_mid", name="落地面环·中段", fn=p_ring_mid, cells=(4, 3),
         anchor="底边中点 = 建筑前进线中点", mask="任意（不含邻居判定）",
         x_tile=True, variants=2, note="4 格可平铺段；宽度档 4/8/12/16 靠重复次数拼"),
    dict(key="p_ring_cap_l", name="落地面环·左端头", fn=_cap_l, cells=(3, 3),
         anchor="右下角 = 前进线左端", mask="任意", x_tile=False, variants=2,
         note="外缘被草/土啃成有机边界"),
    dict(key="p_ring_cap_r", name="落地面环·右端头", fn=_cap_r, cells=(3, 3),
         anchor="左下角 = 前进线右端", mask="任意", x_tile=False, variants=2,
         note="同上（镜像）"),
    dict(key="p_edge_l", name="过渡·左邻有建筑", fn=_edge_l, cells=(4, 3),
         anchor="底边中点", mask="左邻居有建筑（掩码位 0x01）", x_tile=True,
         variants=2, note="邻居判定对象是**建筑**而不是同材质"),
    dict(key="p_edge_r", name="过渡·右邻有建筑", fn=_edge_r, cells=(4, 3),
         anchor="底边中点", mask="右邻居有建筑（掩码位 0x02）", x_tile=True,
         variants=2, note="同上（镜像）"),
    dict(key="p_path_a", name="门前踩踏小径·a", fn=_path_a, cells=(4, 4),
         anchor="上边中点 = 门口中点；下边接道路带", mask="任意", x_tile=False,
         variants=1, note="扇形展开、有机边缘；2~3 变体随机"),
    dict(key="p_path_b", name="门前踩踏小径·b", fn=_path_b, cells=(4, 4),
         anchor="同上", mask="任意", x_tile=False, variants=1, note="变体 b"),
    dict(key="p_path_c", name="门前踩踏小径·c（窄档）", fn=_path_c, cells=(3, 4),
         anchor="同上", mask="任意", x_tile=False, variants=1, note="4 格小屋用"),
]

#: 分带登记表（3 带 × 3 族 = 9）
BANDS = []
for _fk, _fn in FAMILIES:
    for _bk, _bn, _note in (
            ("shoulder", "路肩带",
             "贴墙根的硬化面；上缘贴建筑基线（含极弱接触暗），下缘接路缘沟"),
            ("kerb", "路缘石+排水沟", "上=缘石列、下=沟槽沉积与积水；薄带 16px"),
            ("road", "道路带",
             "主可走区：车辙顺 X 连续 + 碾纹 + 泥泞 + 积水 + 修补块 + 排水微拱")):
        BANDS.append(dict(key="band_%s_%s" % (_bk, _fk),
                          name="%s·%s" % (_bn, _fn), fam=_fk, band=_bk, note=_note))

#: 区域档次长条（静态基础层，3 个种子变体；横向可平铺）
STRIPS = [
    dict(key="strip_plaza", zone="plaza", name="长条·广场（大理石/大石板/残块拼贴）",
         note="广场：大理石 + 花岗岩 + 小方石 + 旧砖 混拼，1.9m 补丁"),
    dict(key="strip_street", zone="street", name="长条·主街（旧砖 + 碎石修补混搭）",
         note="主街：旧砖为主，碎石/花岗岩/新砖/破石板补丁，三道车辙"),
    dict(key="strip_alley", zone="alley", name="长条·巷道（土 + 砾石 + 草）",
         note="巷道：土为主，砾石/破石板补丁，路缘多缺失被草土替代"),
    dict(key="strip_gate", zone="gate", name="长条·城门外（深泥 + 车辙）",
         note="城门：深泥 + 砾石补丁，车辙汇成泥洼"),
]
STRIP_VARIANTS = 3            # 每档长条 3 个种子变体（引擎整条切换）

# ============================================================ 链式分段集（交付主形态）
# 城市会长、规模会升级（村→镇→城），所以**不出整条死长条**：每种带出 N 段可互换分段
# （512px = 16 格宽），同族左右边缘约定一致、任意顺序可链式拼接，城市延长 = 续链。
# 我们的"边缘约定"不是靠美术对缝，而是**构造保证**：分段横向都是周期函数
# （`periodic_check` 逐位证明），所以任意两段的接缝与段内接缝完全同级。
SEG_W = 512                    # 16 格
SEG_VARIANTS = 5               # 每档 5 段可互换

#: **城市内区带梯度**（同一座城市从中心到边缘的材质梯度，key 直接带区带位）
#:   center = 中心：石板 / 大理石 + 残块修补
#:   mid    = 中环：旧砖 + 碎石混铺
#:   edge   = 边缘：夯土 / 砾石 / 草皮啃噬
#: **规模 = 区带包含关系（创始人定，不是并列）**：
#:   村庄级城市 **只用 edge 档**（村 = 边的子集）→ 镇 = mid + edge → 城 = center + mid + edge
#: 所以 edge 档（= 原"村"素材）必须**单独成套可用**：3 带 × 5 段 = 15 段自成一套。
TIERS = [("edge", "边缘（夯土/砾石/草皮啃噬，村庄级城市全用它）", "earth"),
         ("mid", "中环（旧砖+碎石混铺，镇级起）", "stone"),
         ("center", "中心（石板/大理石+残块修补，仅城级）", "city")]

#: 城市规模 → 允许使用的区带（**包含关系**；村庄的地面就是城市边缘的地面）
SCALE_ZONES = {
    "village": ["edge"],
    "town": ["mid", "edge"],
    "city": ["center", "mid", "edge"],
}

#: 区域型长条的区带归属（长条已降级为观感参考，仍标清归属）
STRIP_ZONE = {"plaza": "center", "street": "mid", "alley": "mid", "gate": "edge"}

#: 三种带（引擎里纵向固定，横向链式）
SEG_BANDS = [("shoulder", "路肩底", STRIP_SHOULDER),
             ("kerb", "路缘", STRIP_KERB),
             ("road", "道路带", STRIP_ROAD)]


def _city_band(kind, nx, ny, seed):
    """"城"档：大理石 / 花岗岩成片铺装（含残块拼贴）。"""
    U, V = _uvw(nx, ny)
    ku, kv = klatt(nx, 1.2), max(2, klatt(ny, 1.2))
    _f1, _f2, cid = pworley(U * ku, V * kv, ku, kv, seed + 11, 0.55)
    menu = ["marble", "marble", "granite", "marble", "granite", "cobble"]
    pick = np.minimum((cid * len(menu)).astype(np.int64), len(menu) - 1)
    alb = np.zeros((ny, nx, 3))
    h = np.zeros((ny, nx))
    rough = np.zeros((ny, nx))
    for i, kd in enumerate(menu):
        m = (pick == i)
        if not m.any():
            continue
        a, hh, rr = _px_pave(U, V, nx, ny, seed + 21, kd)
        alb = np.where(m[..., None], a, alb)
        h = np.where(m, hh, h)
        rough = np.where(m, rr, rough)
    if kind == "kerb":
        # 城档路缘：仍然是"低而断续"的（不是现代市政路缘），但石块更方、更整
        y_k = 0.42
        bandk = smoothstep(0.34, 0.44, V) * (1.0 - smoothstep(0.86, 0.96, V))
        seg = np.mod(np.floor(U * klatt(nx, 0.32)).astype(np.int64),
                     klatt(nx, 0.32))
        zero = np.zeros_like(seg)
        pres = smoothstep(0.22, 0.38, _hash01(seg, zero, seed + 31))
        kst = cmix(_hash01(seg, zero, seed + 41), (0.600, 0.596, 0.588),
                   (0.800, 0.796, 0.786))
        km = bandk * pres
        alb = cmix(km * 0.95, alb, kst)
        h = h + km * 0.45
        rough = lerp(rough, 0.82, km)
        alb = cmix(bandk * (1.0 - pres) * 0.8, alb,
                   cmix(gwh(U, V, 0.10, nx, ny, seed + 51, oct=2),
                        (0.420, 0.408, 0.380), (0.560, 0.548, 0.520)))
    elif kind == "shoulder":
        nib = smoothstep(0.70, 0.94, gwh(U, V, 0.55, nx, ny, seed + 61, oct=3)) \
            * smoothstep(0.86, 1.0, V)
        g = cmix(gwh(U, V, 0.20, nx, ny, seed + 71, oct=2),
                 (0.250, 0.372, 0.120), (0.150, 0.250, 0.075))
        alb = cmix(nib * 0.7, alb, g)
        h = h + nib * 0.10
    else:
        s = 0.13 / TILE_M
        rut = np.zeros((ny, nx))
        for vc in (0.22, 0.62):
            wob = (gwh(U, V, 0.35, nx, ny, seed + 81, oct=2) - 0.5) * 0.030
            rut = np.maximum(rut, np.exp(-((wdist(V + wob, vc) / s) ** 2)))
        rut = rut * (0.5 + 0.5 * smoothstep(
            0.35, 0.75, gwh(U, V, 0.8, nx, ny, seed + 91, oct=2)))
        alb = cmix(rut * 0.45, alb,
                   cmix(gwh(U, V, 0.03, nx, ny, seed + 101, oct=2),
                        (0.560, 0.552, 0.540), (0.700, 0.690, 0.672)))
        h = h - rut * 0.22
        rough = rough * lerp(1.0, 0.80, rut)
    return alb, h, rough


def b_segment(band, tier, seed=0, nx=SEG_W, ny=None):
    """链式分段：`band` ∈ shoulder/kerb/road，`tier` ∈ village/town/city。

    横向**严格周期**（任意两段可任意顺序相接），段内自带变化（补丁 / 车辙 / 残缺）。
    """
    ny = {"shoulder": STRIP_SHOULDER, "kerb": STRIP_KERB,
          "road": STRIP_ROAD}[band] if ny is None else ny
    fam = dict((t[0], t[2]) for t in TIERS)[tier]   # edge→earth / mid→stone / center→city
    if fam == "city":
        alb, h, rough = _city_band(band, nx, ny, seed)
        alb = alb
    else:
        if band == "shoulder":
            r = b_shoulder(fam, nx, ny)
        elif band == "kerb":
            r = b_kerb(fam, nx, ny)
        else:
            r = b_road(fam, nx, ny)
        alb, h, rough = r["alb"], r["h"] * 0.999, r["rough"]
    # 段内固定少量变化：补丁（跨档混料，但**不越档**：村的段里不出现大理石）
    U, V = _uvw(nx, ny)
    ku, kv = klatt(nx, 0.85), max(2, klatt(ny, 0.85))
    f1, f2, cid = pworley(U * ku, V * kv, ku, kv, seed + 211, 0.75)
    menu = {"edge": ["dirt", "gravel", "grass"],
            "mid": ["rubble", "gravel", "brick_new"],
            "center": ["granite", "marble", "cobble"]}[tier]
    pick = np.minimum((cid * (len(menu) + 1)).astype(np.int64), len(menu))
    for i, kd in enumerate(menu):
        m = (pick == i)
        if not m.any():
            continue
        a, hh, rr = (_px_pave(U, V, nx, ny, seed + 221, kd)
                     if kd in ("rubble", "brick_new", "granite", "marble", "cobble")
                     else _px_loose(U, V, nx, ny, seed + 221, kd))
        alb = np.where(m[..., None], a, alb)
        h = np.where(m, hh, h)
        rough = np.where(m, rr, rough)
    edge = smoothstep(0.018, 0.0, np.clip(f2 - f1, 0.0, None))
    alb = cmix(edge * 0.55, alb, cmix(gwh(U, V, 0.05, nx, ny, seed + 231, oct=2),
                                      (0.240, 0.218, 0.192),
                                      (0.340, 0.312, 0.272)))
    h = h - edge * 0.12
    return _packw(alb, h, rough, nx, ny, seed + 241,
                  0.026 if ny < 40 else 0.030, ao=0.24, nstr=0.9)


def b_newold(seed=0, nx=SEG_W, ny=STRIP_ROAD):
    """新旧过渡分段：**新铺装**以不规则边缘半盖旧土面，缝里夹碎石（城市升级的层次）。"""
    U, V = _uvw(nx, ny)
    b = 0.55 + (gwh(U, V, 0.55, nx, ny, seed + 311, oct=3) - 0.5) * 1.15 \
        + (gwh(U, V, 0.16, nx, ny, seed + 321, oct=2) - 0.5) * 0.35
    b = np.clip(b, 0.16, 0.90)
    newm = smoothstep(b - 0.022, b + 0.022, V)
    a_new, h_new, r_new = _px_pave(U, V, nx, ny, seed + 331, "marble")
    pa2, ph2, pr2 = _px_pave(U, V, nx, ny, seed + 341, "granite")
    m2 = smoothstep(0.45, 0.75, gwh(U, V, 0.9, nx, ny, seed + 351, oct=2))
    a_new = np.where(m2[..., None], pa2, a_new)
    a_old, h_old, r_old = _px_loose(U, V, nx, ny, seed + 361, "dirt")
    ob2, oh2, or2 = _px_loose(U, V, nx, ny, seed + 371, "gravel")
    m3 = smoothstep(0.40, 0.70, gwh(U, V, 0.7, nx, ny, seed + 381, oct=2))
    a_old = np.where(m3[..., None], ob2, a_old)
    alb = cmix(newm, a_old, a_new)
    h = newm * (h_new + 0.18) + (1.0 - newm) * h_old
    rough = newm * r_new + (1.0 - newm) * r_old
    # 缝里夹碎石 + 新面边缘的碎料（不规则边界的读法）
    band = np.exp(-(((V - b) / 0.055) ** 2))
    kp = klatt(nx, 0.09)
    f1p, f2p, cp = pworley(U * kp, V * kp, kp, kp, seed + 391, 0.9)
    peb = (smoothstep(0.55, 0.72, cellhw(U, V, kp, kp, seed + 401))
           * smoothstep(0.0, 0.06, np.clip(f2p - f1p, 0.0, None)))
    grav = cmix(cp, (0.470, 0.452, 0.415), (0.715, 0.690, 0.638))
    alb = cmix(peb * band, grav, alb)
    h = h + peb * band * 0.35
    return _packw(alb, h, rough, nx, ny, seed + 411, 0.026, ao=0.24, nstr=0.9)


#: 分段集登记表：3 带 × 3 档 × SEG_VARIANTS 段（key = seg_<band>_<tier>_v<N>）
SEGS = []
for _bn, _bname, _bh in SEG_BANDS:
    for _tn, _tname, _tfam in TIERS:
        for _v in range(1, SEG_VARIANTS + 1):
            SEGS.append(dict(key="seg_%s_%s_v%d" % (_bn, _tn, _v), band=_bn,
                             tier=_tn, variant=_v, h_px=_bh,
                             name="%s·%s·段%d" % (_bname, _tname.split("（")[0], _v),
                             note="16 格宽可互换分段；横向周期保证任意顺序可链式相接"))

#: 新旧过渡分段（城档新铺装半盖旧土面）
NEWOLD = [dict(key="seg_newold_v%d" % v, band="road", tier="newold", variant=v,
               h_px=STRIP_ROAD, name="新旧过渡·段%d" % v,
               note="新铺装以不规则边缘半盖旧土面，缝里夹碎石（城市升级层次）")
          for v in range(1, 4)]

#: decal **撒布参数**（引擎按"种子 + 密度"撒，不烘进分段；分段内只留少量固定变化）
SCATTER = {
    "dc_stain":     dict(density_per_10m=0.6, size_cells=[0.5, 1.0],
                         where="道路 / 路肩随机"),
    "dc_puddle":    dict(density_per_10m=0.4, size_cells=[1.0, 2.0],
                         where="车辙内 / 低洼优先"),
    "dc_crack":     dict(density_per_10m=0.5, size_cells=[1.0, 2.0], where="道路"),
    "dc_moss":      dict(density_per_10m=0.5, size_cells=[1.0, 2.0],
                         where="路缘 / 墙根 / 阴影侧"),
    "dc_debris":    dict(density_per_10m=1.2, size_cells=[0.5, 1.0],
                         where="墙根 / 摊贩前"),
    "dc_worn":      dict(density_per_10m=0.3, size_cells=[1.0, 2.0],
                         where="门前到道路的路径上"),
    "dc_patch":     dict(density_per_10m=0.25, size_cells=[1.5, 2.0], where="道路"),
    "dc_door_path": dict(density_per_10m=1.0, size_cells=[1.0, 3.0],
                         where="每扇门 1 件（锚点 = 门口中点，下接道路带）"),
}

#: decal 登记表（单件，带 alpha）
DECALS = [
    dict(key="dc_stain", name="污渍", fn=d_stain, note="油/酒渍暗斑（贴路面或墙根）"),
    dict(key="dc_puddle", name="水洼", fn=d_puddle, note="低粗糙度深色积水（吃天光反射）"),
    dict(key="dc_moss", name="苔藓", fn=d_moss, note="顺缝生长的苔藓斑（阴湿角落）"),
    dict(key="dc_crack", name="裂缝", fn=d_crack, note="多尺度网状干裂/地裂"),
    dict(key="dc_debris", name="碎屑/干草", fn=d_debris, note="干草 + 小石 + 细枝"),
    dict(key="dc_worn", name="磨光带", fn=d_worn, note="车马人脚磨亮磨平的一条（横向拉长）"),
    dict(key="dc_patch", name="修补块", fn=d_patch, note="换料补丁 + 周边撒落碎料"),
    dict(key="dc_door_path", name="门口通道", fn=d_door_path,
         note="32×96 竖条：门口踩出来的通道，摆在路肩带上接路缘"),
]

#: 过渡带登记表
TRANS = [
    dict(key="tr_cobble_dirt", name="鹅卵石↔土路", note="卵石铺装咬进土路的边界"),
    dict(key="tr_stone_dirt", name="石板↔土路", note="石板铺装咬进土路的边界"),
    dict(key="tr_brick_grass", name="砖铺↔草皮", note="砖铺咬进草皮的边界"),
]

#: 12 种地面登记表（key、中文名、适用区域、现实特征尺寸、备注）
SPECS = [
    dict(key="cobble_small", name="小鹅卵石", zone="主街 / 广场",
         feats=[("鹅卵石粒径", 12.0), ("石缝宽", 1.4)],
         note="主街最常用铺装；冷灰、踩踏磨亮，缝里积湿泥。粒径取 10.5cm 是"
              "为了让 128 档仍有一颗 9px、石缝只占 12% 面积（读得出「一颗颗」而不是灰雪）", fn=t_cobble_small),
    dict(key="cobble_large", name="大鹅卵石", zone="广场 / 老街",
         feats=[("鹅卵石粒径", 14.0), ("石缝宽", 2.0)],
         note="石更大、色更暖，缝里有苔；老城区与广场。", fn=t_cobble_large),
    dict(key="brick_pave", name="砖铺错缝", zone="主街 / 市政厅前",
         feats=[("砖", 21.0), ("砖（短边）", 10.5), ("灰缝", 1.6)],
         note="错缝砌法（半个砖错位），8 列 × 16 行；红陶砖 + 灰浆。", fn=t_brick_pave),
    dict(key="flagstone", name="大石板不规则", zone="市政厅前 / 广场",
         feats=[("石板边长", 42.0), ("板缝宽", 2.3)],
         note="多边形不规则石板（Worley 边界），浅暖灰 + 细凿痕 + 磨光的板边。",
         fn=t_flagstone),
    dict(key="rammed_earth", name="夯土", zone="村道 / 院坝 / 次级街",
         feats=[("夯层厚", 14.0), ("小石子", 8.0)],
         note="12 层夯带 + 干裂纹；村庄与城墙内空地。", fn=t_rammed_earth),
    dict(key="dirt_rut", name="泥地带车辙", zone="巷道 / 城门道",
         feats=[("车辙宽", 13.0), ("车辙间距", 54.0)],
         note="两条压实车辙 + 辙间干燥起垄，辙向沿 U（东西向街道）。", fn=t_dirt_rut),
    dict(key="gravel", name="砾石", zone="次级巷道 / 工地 / 马厩前",
         feats=[("主砾石", 8.0), ("碎砾", 4.0)],
         note="8cm 主石 + 4cm 碎砾双层；高起伏、浅灰米。", fn=t_gravel),
    dict(key="ash_soil", name="灰渣土", zone="后巷 / 炉场 / 贫民区",
         feats=[("炭块", 1.4), ("灰堆斑", 45.0)],
         note="暗灰灰渣 + 炭块 + 锈色焦渣，带一条踩踏亮径。", fn=t_ash_soil),
    dict(key="grass", name="草地", zone="城郊 / 公园 / 城外",
         feats=[("草簇", 33.0), ("草叶宽", 4.5), ("野花", 2.0)],
         note="密生草皮 + 枯斑 + 苔绿块 + 零星黄白野花。", fn=t_grass),
    dict(key="grass_sparse", name="稀疏草土地", zone="路边 / 荒地 / 院角",
         feats=[("草簇", 22.0), ("小石子", 8.0)],
         note="土为主（约 60%）、草簇缀其中，边界参差。", fn=t_grass_sparse),
    dict(key="sand", name="沙地", zone="河滩 / 沙路 / 城外",
         feats=[("风纹波距", 9.3), ("沙粒", 0.6)],
         note="18 条风纹（周期函数，噪声扰动其走向）+ 潮斑。", fn=t_sand),
    dict(key="boardwalk", name="木栈道", zone="商铺前檐廊 / 码头",
         feats=[("木板宽", 21.0), ("板缝", 1.4), ("板端缝", 2.2)],
         note="板端横缝故意落在贴图边界（现实中板端接龙骨）→ 接缝即结构。",
         fn=t_boardwalk),
]

_FN = {s["key"]: s["fn"] for s in SPECS}
_SPEC = {s["key"]: s for s in SPECS}

#: 变体数：每种地面出 3 个变体（v1~v3），引擎随机轮换 → 治"重复度太高"的第一招。
#: 变体 = ① 逐像素相位平移（接缝相位/图案相位不同）+ ② 全库哈希种子偏移
#: （斑驳位置、接缝抖动、逐块色全都不一样），两条都**不破坏**任何一个不变量：
#: 周期性证明仍逐位成立，光照中性也不受影响。
VARIANTS = 3
_VARIANT_SEED = 977


def keys():
    return [s["key"] for s in SPECS]


def all_keys():
    """全部"面"类（可平铺 / 分带 / 过渡 / 分段集）的 key。"""
    return (keys() + [b["key"] for b in BANDS] + [t["key"] for t in TRANS]
            + [x["key"] for x in SEGS] + [x["key"] for x in NEWOLD])


def seg_keys():
    return [x["key"] for x in SEGS]


def newold_keys():
    return [x["key"] for x in NEWOLD]


def piece_keys():
    return [q["key"] for q in PIECES]


def kind_info(key):
    """key → (中文名, nx, ny, 类别)。

    类别 ∈ tile/band/transition/segment/strip/piece/decal/mottle。
    """
    if key in _SEG_OF:
        q = _SEG_OF[key]
        return (q["name"], SEG_W, q["h_px"], "segment")
    if key in _PIECE_OF:
        q = _PIECE_OF[key]
        return (q["name"], q["cells"][0] * CELL, q["cells"][1] * CELL, "piece")
    if key in _STRIP_OF:
        return (_STRIP_OF[key]["name"], STRIP_W, STRIP_H, "strip")
    if key in _SPEC:
        s = _SPEC[key]
        n = s.get("px", GAME_PX)
        return (s["name"], kind_size(key)[0], kind_size(key)[1], "tile")
    for b in BANDS:
        if b["key"] == key:
            nx, ny = _BAND_SIZE[b["band"]]
            return (b["name"], nx, ny, "band")
    for t in TRANS:
        if t["key"] == key:
            return (t["name"], 128, 2 * CELL, "transition")
    for d in DECALS:
        if d["key"] == key:
            nx, ny = _DECAL_SIZE.get(key, (48, 48))
            return (d["name"], nx, ny, "decal")
    if key.startswith("mottle"):
        return ("大尺度斑驳遮蔽图", MOTTLE_PX, MOTTLE_PX, "mottle")
    raise KeyError("未知地面: %s" % key)


#: 分带各带的游戏档尺寸（长 × 高）
_BAND_SIZE = {"shoulder": (128, SHOULDER_PX), "kerb": (128, KERB_PX),
              "road": (128, ROAD_PX)}
#: decal 的游戏档尺寸（单件；门口通道是竖条）
_DECAL_SIZE = {"dc_stain": (32, 32), "dc_puddle": (48, 32), "dc_moss": (48, 48),
               "dc_crack": (64, 64), "dc_debris": (48, 32), "dc_worn": (64, 32),
               "dc_patch": (48, 48), "dc_door_path": (32, 3 * CELL)}
#: 过渡带两侧的族（仅用于元数据说明）
_TRANS_KIND = {"tr_cobble_dirt": "cobble_dirt", "tr_stone_dirt": "stone_dirt",
               "tr_brick_grass": "brick_grass"}


_BAND_OF = {b["key"]: b for b in BANDS}
_STRIP_OF = {x["key"]: x for x in STRIPS}
_PIECE_OF = {q["key"]: q for q in PIECES}
_SEG_OF = {q["key"]: q for q in SEGS}
_SEG_OF.update({q["key"]: q for q in NEWOLD})
_TRANS_OF = {t["key"]: t for t in TRANS}
_DECAL_OF = {d["key"]: d for d in DECALS}


def kind_size(key, px=None):
    """游戏档像素尺寸 (nx, ny)；px 给定时按倍率缩放（HD = 4×）。"""
    if key.startswith("mottle"):
        return (MOTTLE_PX, MOTTLE_PX)
    if key in _SEG_OF:
        return (SEG_W, _SEG_OF[key]["h_px"])
    if key in _STRIP_OF:
        nx = ny = GAME_PX                      # 长条不按 4× 放大（本身已 4096 宽）
    elif key in _PIECE_OF:
        cx, cy = _PIECE_OF[key]["cells"]
        nx, ny = cx * CELL, cy * CELL
    elif key in _SPEC:
        nx = ny = GAME_PX
    elif key in _BAND_OF:
        nx, ny = _BAND_SIZE[_BAND_OF[key]["band"]]
    elif key in _TRANS_OF:
        nx, ny = 128, 2 * CELL
    elif key in _DECAL_OF:
        nx, ny = _DECAL_SIZE[key]
    else:
        raise KeyError("未知地面: %s" % key)
    if key in _STRIP_OF:
        return (STRIP_W, STRIP_H)
    if px is None:
        return (nx, ny)
    k = float(px) / float(GAME_PX)
    return (max(4, int(round(nx * k))), max(4, int(round(ny * k))))


def _fn_of(key):
    if key in _FN:
        return _FN[key]
    if key in _SEG_OF:
        q = _SEG_OF[key]
        if q["tier"] == "newold":
            return lambda nx, ny, s0=q["variant"] * 137: b_newold(s0, nx, ny)
        return lambda nx, ny, b0=q["band"], t0=q["tier"]: b_segment(b0, t0, 0, nx, ny)
    if key in _STRIP_OF:
        zn = _STRIP_OF[key]["zone"]
        return lambda nx, ny, z=zn: b_street_strip(0, nx, ny, z)
    if key in _PIECE_OF:
        q = _PIECE_OF[key]["fn"]

        def _pf(nx, ny, _q=q):
            try:
                return _q(seed=0, nx=nx, ny=ny)
            except TypeError:
                return _q(nx, ny)
        return _pf
    if key in _BAND_OF:
        fam, band = _BAND_OF[key]["fam"], _BAND_OF[key]["band"]

        def _band_fn(nx, ny, f=fam, bd=band):
            if bd == "shoulder":
                return b_shoulder(f, nx, ny)
            if bd == "kerb":
                return b_kerb(f, nx, ny)
            return b_road(f, nx, ny)
        return _band_fn
    if key in _TRANS_OF:
        kd = _TRANS_KIND[key]
        return lambda nx, ny, k=kd: t_transition(k, nx, ny)
    if key in _DECAL_OF:
        return _DECAL_OF[key]["fn"]
    raise KeyError("未知地面: %s" % key)


def generate(key, n=None, shift=None, variant=0, px=None):
    """生成一张底图（dict: alb / h / rough / relief_m / nstr / size[/alpha]）。

    * `n`：游戏档像素长边基准（默认 128；给 px 时按 px 反推倍率）。
    * `shift=(dx,dy)`：采样网格平移整数像素（周期性证明用）。
    * `variant=v`：变体序号（0 = 基础）。
    """
    global _SHIFT, _SEEDOFF
    nx, ny = kind_size(key, px if px is not None
                       else (None if n is None else int(n)))
    if key in _STRIP_OF and px is None and n is not None and int(n) > 0:
        nx, ny = STRIP_W, STRIP_H
    if key.startswith("mottle"):
        U, V = _uvw(nx, ny)
        out = {"alb": np.repeat(m_mottle(9001 + variant * 131, nx)[..., None], 3,
                                axis=2),
               "h": np.full((ny, nx), 0.5), "rough": np.full((ny, nx), 0.9),
               "relief_m": 0.0, "nstr": 0.0, "size": (nx, ny)}
        return out
    old_s, old_o = _SHIFT, _SEEDOFF
    dx, dy = (int(shift[0]), int(shift[1])) if shift else (0, 0)
    _SHIFT = (dx + variant * 37, dy + variant * 53)
    _SEEDOFF = variant * _VARIANT_SEED
    try:
        if key in _SEG_OF:
            q = _SEG_OF[key]
            # **变体号必须从 key 里取**：seg_*_v3 的"v3"就是它的段号，
            # 段之间靠 seed 分家（早先只吃函数参数 variant → 5 段一模一样，已修）
            if q["tier"] == "newold":
                return b_newold(seed=q["variant"] * 137 + variant * 313,
                                nx=nx, ny=ny)
            return b_segment(q["band"], q["tier"],
                             seed=q["variant"] * 313 + variant * 173,
                             nx=nx, ny=ny)
        if key in _STRIP_OF:
            return b_street_strip(variant * 137, nx, ny, _STRIP_OF[key]["zone"])
        if key in _PIECE_OF:
            q = _PIECE_OF[key]["fn"]
            try:
                return q(seed=variant * 173, nx=nx, ny=ny)
            except TypeError:
                return q(nx, ny)
        if key in _SPEC:                       # 平铺类：方形，只吃一个 n
            return _fn_of(key)(nx)
        return _fn_of(key)(nx, ny)
    finally:
        _SHIFT, _SEEDOFF = old_s, old_o


# ============================================================ 落盘 / 材质
def _save_png(arr, path, colorspace, alpha=None):
    """numpy → PNG（经 bpy.data.images，避免依赖 PIL）。arr 第 0 行 = 图片底部。"""
    a = np.asarray(arr, dtype=np.float64)
    if a.ndim == 2:
        a = np.repeat(a[..., None], 3, axis=2)
    h, w = a.shape[0], a.shape[1]
    buf = np.ones((h, w, 4), dtype=np.float32)
    buf[..., :3] = np.clip(a, 0.0, 1.0)
    if alpha is not None:
        buf[..., 3] = np.clip(np.asarray(alpha, dtype=np.float64), 0.0, 1.0)
    name = os.path.basename(path)
    old = bpy.data.images.get(name)
    if old is not None:
        bpy.data.images.remove(old)
    # **必须按有无 alpha 建图**：alpha=False 的图会丢掉 alpha 通道，
    # decal 就变成不透明方块（这条踩过）
    img = bpy.data.images.new(name, width=w, height=h, alpha=(alpha is not None))
    img.colorspace_settings.name = colorspace
    img.pixels.foreach_set(buf.reshape(-1))
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    return img


def _tag_of(n):
    return "" if n == HD_PX else "_%d" % int(n)


def export_one(key, out_dir, n, variant=0, with_alpha=None):
    """某 key × 某分辨率 × 某变体：alb(+alpha) / nrm / rgh 落盘。

    返回 (rec, 图像三元组)。alpha 只有 decal 有（`with_alpha=None` 时按 key 自动判）。
    """
    rec = generate(key, n, variant=variant)
    if with_alpha is None:
        with_alpha = "alpha" in rec
    nx, ny = rec["size"]
    src = os.path.join(out_dir, "src")
    os.makedirs(src, exist_ok=True)
    vtag = "" if variant == 0 else "_v%d" % variant
    tag = _tag_of(n) + vtag
    if variant == 0:
        tag = _tag_of(n) + vtag
    pa = os.path.join(src, "%s_alb%s%s.png" % (key, _tag_of(n), vtag))
    pn = os.path.join(src, "%s_nrm%s%s.png" % (key, _tag_of(n), vtag))
    pr = os.path.join(src, "%s_rgh%s%s.png" % (key, _tag_of(n), vtag))
    ia = _save_png(rec["alb"], pa, "sRGB",
                   alpha=rec.get("alpha") if with_alpha else None)
    inn = _save_png(normal_map_w(rec["h"], nx, ny, rec["relief_m"], rec["nstr"]),
                    pn, "Non-Color",
                    alpha=rec.get("alpha") if with_alpha else None)
    ir = _save_png(rec["rough"], pr, "Non-Color",
                   alpha=rec.get("alpha") if with_alpha else None)
    return rec, (ia, inn, ir), (pa, pn, pr)


def export_all(out_dir, n_list=(HD_PX, GAME_PX), quiet=False):
    """全部"面"类（12 平铺 + 9 分带 + 3 过渡）= 各分辨率 + 各变体；decal / mottle 一并落盘。"""
    os.makedirs(out_dir, exist_ok=True)
    records = []
    for key in all_keys():
        is_tile = key in _SPEC
        is_strip = key in _STRIP_OF
        spec = _SPEC.get(key)
        band = None
        for b in BANDS:
            if b["key"] == key:
                band = b
        is_seg = key in _SEG_OF
        nl = (GAME_PX,) if (is_strip or is_seg) else n_list
        recs = {}
        for n in nl:
            rec, _imgs, _paths = export_one(key, out_dir, n)
            recs[n] = rec
        if is_tile or band is not None:
            for v in range(1, VARIANTS + 1):        # 变体只出游戏档源图
                export_one(key, out_dir, GAME_PX, variant=v)
        if is_strip:                                # 长条：3 个种子变体（主街），其余 1 个
            nv = STRIP_VARIANTS if key == "strip_street" else 1
            for v in range(1, nv + 1):
                export_one(key, out_dir, GAME_PX, variant=v)
        r512 = recs[GAME_PX if (is_strip or is_seg) else HD_PX]
        meta = {
            "key": key,
            "name": spec["name"] if spec else (band["name"] if band else
                                              kind_info(key)[0]),
            "kind": kind_info(key)[3],
            "note": spec["note"] if spec else (band["note"] if band else ""),
            "zone": spec["zone"] if spec else "（分带，非单块地面）",
            "size_game_px": list(kind_size(key)),
            "size_hd_px": (list(kind_size(key, HD_PX))
                           if not (is_strip or is_seg) else None),
            "variants": VARIANTS if is_tile or band else 0,
            "px_per_m_game": round(GAME_PX / TILE_M, 2),
            "relief_m": r512["relief_m"],
            "x_tileable": True,
            "y_tileable": bool(is_tile) or (band is not None and band["band"] == "road"),
            "lighting_neutral": "albedo + 微 AO（谷底盒式模糊）; 光源是垂直向下 SUN，"
                                "无水平分量 → 无方向性明暗",
            "mean_srgb": [round(float(r512["alb"][..., i].mean()), 3) for i in range(3)],
            "files": {
                "hd": "%s.png" % key,
                "game": "%s_%d.png" % (key, GAME_PX),
                "src_albedo_game": "src/%s_alb_%d.png" % (key, GAME_PX),
                "src_normal_game": "src/%s_nrm_%d.png" % (key, GAME_PX),
                "src_roughness_game": "src/%s_rgh_%d.png" % (key, GAME_PX),
            },
        }
        if spec is not None:
            meta["features_real"] = [
                {"name": nm, "cm": cm,
                 "game_px": round(feat(GAME_PX, cm / 100.0), 2)}
                for nm, cm in spec["feats"]]
        if is_tile or band is not None:
            meta["variant_files"] = [
                "src/%s_alb_%d_v%d.png" % (key, GAME_PX, v)
                for v in range(1, VARIANTS + 1)]
        if is_strip:
            meta["kind"] = "strip"
            meta["strip_px"] = [STRIP_W, STRIP_H]
            meta["bands_px"] = [STRIP_SHOULDER, STRIP_KERB, STRIP_ROAD]
            meta["area"] = _STRIP_OF[key]["zone"]
            meta["zone"] = STRIP_ZONE[_STRIP_OF[key]["zone"]]
            meta["x_tileable"] = True
            meta["y_tileable"] = False
            meta["seed_variants"] = (STRIP_VARIANTS if key == "strip_street" else 1)
        with open(os.path.join(out_dir, "%s.json" % key), "w", encoding="utf-8") as fh:
            json.dump(meta, fh, ensure_ascii=False, indent=1)
        records.append(meta)
        if not quiet:
            m = meta["mean_srgb"]
            print("  %-22s %-10s %-4s meanRGB=(%.2f,%.2f,%.2f) %dx%d%s"
                  % (key, meta["name"], meta["kind"], m[0], m[1], m[2],
                     meta["size_game_px"][0], meta["size_game_px"][1],
                     "  ×%d 变体" % (meta["variants"] or 0) if meta["variants"] else ""))
    # 段落集（链式拼接单元）
    for q in SEGS + NEWOLD:
        key = q["key"]
        rec, _im, _pp = export_one(key, out_dir, GAME_PX)
        nx, ny = rec["size"]
        meta = {"key": key, "name": q["name"], "kind": "segment",
                "band": q["band"], "tier": q["tier"], "zone": q["tier"],
                "scale_includes": SCALE_ZONES, "variant": q["variant"],
                "px": [nx, ny], "cells_w": int(round(nx / 32.0)),
                "edge_convention": "横向严格周期（左右边缘同级）→ 任意顺序可链式相接",
                "x_tileable": True, "y_tileable": False,
                "note": q["note"],
                "lighting_neutral": "albedo + 微 AO（无光照）",
                "files": {"game": "%s_%d.png" % (key, GAME_PX),
                          "src_albedo_game": "src/%s_alb_%d.png" % (key, GAME_PX)}}
        with open(os.path.join(out_dir, "%s.json" % key), "w",
                  encoding="utf-8") as fh:
            json.dump(meta, fh, ensure_ascii=False, indent=1)
        records.append(meta)
        if not quiet:
            print("  %-24s %-18s seg %dx%d（%d 格宽）"
                  % (key, q["name"], nx, ny, meta["cells_w"]))
    # 动态建造层：件 + json（格尺寸 / 锚点 / 邻居掩码）
    for q in PIECES:
        key = q["key"]
        rec, _im, _pp = export_one(key, out_dir, GAME_PX)
        for v in range(1, q.get("variants", 1) + 1):
            export_one(key, out_dir, GAME_PX, variant=v)
        nx, ny = rec["size"]
        meta = {"key": key, "name": q["name"], "kind": "piece",
                "zone": q.get("zone", "any（按所在区带取对应区带的段落材质族）"),
                "cells": list(q["cells"]), "px": [nx, ny], "anchors": q["anchor"],
                "neighbor_mask": q["mask"], "x_tileable": q["x_tile"],
                "variants": q.get("variants", 1), "note": q["note"],
                "usage": "按网格锚点吸附；环中段按建筑格宽/4 重复、两端接端头件；"
                         "邻居判定 = 左右邻居**有无建筑**（掩码 0x01/0x02），"
                         "有则不铺该侧环、改铺过渡件；拆除后不铺任何件 → 露出静态基础层",
                "alpha": "alpha" in rec,
                "lighting_neutral": "albedo + 微 AO（无光照）",
                "files": {"game": "%s_%d.png" % (key, GAME_PX),
                          "src_albedo_game": "src/%s_alb_%d.png" % (key, GAME_PX)}}
        with open(os.path.join(out_dir, "%s.json" % key), "w", encoding="utf-8") as fh:
            json.dump(meta, fh, ensure_ascii=False, indent=1)
        records.append(meta)
        if not quiet:
            print("  %-22s %-16s piece %dx%d（%d×%d 格，%d 变体）"
                  % (key, q["name"], nx, ny, q["cells"][0], q["cells"][1],
                     q.get("variants", 1)))
    # decal
    for d in DECALS:
        key = d["key"]
        rec, _im, _pp = export_one(key, out_dir, GAME_PX)
        export_one(key, out_dir, HD_PX)
        nx, ny = rec["size"]
        hx, hy = kind_size(key, HD_PX)
        meta = {"key": key, "name": d["name"], "kind": "decal", "zone": "any",
                "scatter": dict(seed_rule="每实例 rng = hash(场景种子, 格坐标)，"
                                          "同种子逐位可复现",
                                scale_jitter="尺寸 ×0.7~1.3",
                                rotation="仅 0/90/180/270（贴地件按格对齐）",
                                **SCATTER.get(key, {})),
                "note": d["note"],
                "size_game_px": [nx, ny], "size_hd_px": [hx, hy],
                "alpha": True,
                "zone_usage": "任意区带通用（色层与区带无关；密度按上表）",
                "lighting_neutral": "albedo + alpha（无光照）",
                "files": {"game": "%s_%d.png" % (key, GAME_PX),
                          "src_albedo_game": "src/%s_alb_%d.png" % (key, GAME_PX)},
                }
        with open(os.path.join(out_dir, "%s.json" % key), "w", encoding="utf-8") as fh:
            json.dump(meta, fh, ensure_ascii=False, indent=1)
        records.append(meta)
        if not quiet:
            print("  %-22s %-10s decal %dx%d（带 alpha）" % (key, d["name"], nx, ny))
    # ---- 交付清单 / 区带梯度 / 规模包含关系（引擎按此表取用）
    man = {
        "spec": "地面贴图体系 v3（分段链式 + 区带梯度 + 动态建造层）",
        "band_layout_px": {"shoulder": STRIP_SHOULDER, "kerb": STRIP_KERB,
                           "road": STRIP_ROAD,
                           "total": STRIP_H,
                           "note": "路肩 96px 贴建筑基线（= 建筑落地箱 "
                                   "ground_y~+96）；路缘 8px ≈ 10.5cm（≤ 半砖，"
                                   "断续残缺）；其下为道路带"},
        "zone_gradient": {
            "center": "市中心：石板 / 大理石 + 残块修补",
            "mid": "中环：旧砖 + 碎石混铺",
            "edge": "边缘：夯土 / 砾石 / 草皮啃噬"},
        "scale_rules": {
            "village": {"zones": ["edge"],
                        "note": "村庄级城市**只用 edge 档**；村的地面 = 城市边缘的地面"},
            "town": {"zones": ["mid", "edge"], "note": "镇 = 中环 + 边缘"},
            "city": {"zones": ["center", "mid", "edge"], "note": "城 = 全档（包含关系）"},
            "edge_standalone": "edge 档自成一套：seg_{shoulder,kerb,road}_edge_v1..v5 "
                               "共 15 段，不依赖其他档"},
        "segment_sets": {"count": len(SEGS), "width_px": SEG_W,
                         "cells_w": SEG_W // CELL, "variants": SEG_VARIANTS,
                         "edge_convention": "横向严格周期（左右同级）→ 任意顺序链式相接",
                         "keys": [q["key"] for q in SEGS]},
        "newold_segments": {"count": len(NEWOLD), "keys": [q["key"] for q in NEWOLD],
                            "note": "新铺装以不规则边缘半盖旧土面，缝里夹碎石"},
        "pieces": [{"key": q["key"], "name": q["name"], "cells": list(q["cells"]),
                    "anchors": q["anchor"], "neighbor_mask": q["mask"],
                    "variants": q.get("variants", 1), "x_tileable": q["x_tile"]}
                   for q in PIECES],
        "decals": [{"key": d["key"], "name": d["name"]} for d in DECALS],
        "constraints": {
            "lighting_neutral": "albedo + 微 AO；光源为垂直向下 SUN（无水平分量），"
                                "禁烘方向光/太阳投影",
            "seamless": "所有图案定义在周期域（格哈希取模/周期 Worley/整数份数砌块/"
                        "整数倍正弦）→ periodic_check 逐位证明",
            "aging": "本轮做旧克制（污渍/苔藓/水洼以 decal 形式撒布，不烘进分段）"},
    }
    with open(os.path.join(out_dir, "_manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(man, fh, ensure_ascii=False, indent=1)
    if not quiet:
        print("  %-24s %s" % ("_manifest.json", "区带梯度 + 规模包含 + 分段/件/清单"))
    # 低频大尺度斑驳乘图（3 变体，纯灰度，直接写盘不渲染）
    for i in range(3):
        key = "mottle_%s" % "abc"[i]
        msk = m_mottle(9001 + i * 131, MOTTLE_PX)
        _save_png(np.repeat(msk[..., None], 3, axis=2),
                  os.path.join(out_dir, "%s.png" % key), "Non-Color")
        meta = _mottle_meta(key, i)
        meta["files"] = {"mask": "%s.png" % key}
        with open(os.path.join(out_dir, "%s.json" % key), "w", encoding="utf-8") as fh:
            json.dump(meta, fh, ensure_ascii=False, indent=1)
        records.append(meta)
        if not quiet:
            print("  %-22s %-10s %dpx（%d 格，灰度乘图）"
                  % (key, "斑驳遮蔽图", MOTTLE_PX, MOTTLE_PX // CELL))
    return records


def _mottle_meta(key, variant):
    return {"key": key, "kind": "mottle", "variant": variant,
            "px": MOTTLE_PX, "cells": MOTTLE_PX // CELL,
            "encode": "0.5 = 不变；引擎按 mult = 1 + (m-0.5)*k 使用（k 建议 0.35~0.55）",
            "usage": "与地面反照率相乘（或与分带 albedo 相乘），用于打破 1.68m 周期感",
            "lighting_neutral": "纯灰度乘图，不含光照"}


def tile_material(key, n=GAME_PX, name=None, variant=0):
    """可平铺材质：UV 0~1 = 一张贴图。地面平面按"世界坐标 / 该带的世界尺寸"给 UV。

    `variant=v` 取第 v 个变体（v=0 基础；1~VARIANTS 为变体，引擎随机轮换）。
    """
    suffix = _tag_of(n)
    vtag = "" if variant == 0 else "_v%d" % variant
    img_a = bpy.data.images.get("%s_alb%s%s.png" % (key, suffix, vtag))
    img_n = bpy.data.images.get("%s_nrm%s%s.png" % (key, suffix, vtag))
    img_r = bpy.data.images.get("%s_rgh%s%s.png" % (key, suffix, vtag))
    if img_a is None or img_n is None or img_r is None:
        raise RuntimeError("贴图未落盘，先 export_all()（缺 %s %s %s）"
                           % (key, suffix, vtag))
    mname = name or ("gt_%s_%d%s" % (key, n, vtag))
    old = bpy.data.materials.get(mname)
    if old is not None:
        bpy.data.materials.remove(old)
    m = bpy.data.materials.new(mname)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    tc = nt.nodes.new("ShaderNodeTexCoord")
    nmap = nt.nodes.new("ShaderNodeNormalMap")
    nmap.inputs["Strength"].default_value = 1.0

    def tex(img):
        nd = nt.nodes.new("ShaderNodeTexImage")
        nd.image = img
        nd.extension = "REPEAT"
        nd.interpolation = "Linear"
        nt.links.new(tc.outputs["UV"], nd.inputs["Vector"])
        return nd

    ta = tex(img_a)
    tn = tex(img_n)
    tr = tex(img_r)
    nt.links.new(ta.outputs["Color"], bsdf.inputs["Base Color"])
    nt.links.new(tn.outputs["Color"], nmap.inputs["Color"])
    nt.links.new(nmap.outputs["Normal"], bsdf.inputs["Normal"])
    nt.links.new(tr.outputs["Color"], bsdf.inputs["Roughness"])
    for k, v in (("IOR", 1.45), ("Coat Weight", 0.0), ("Specular IOR Level", 0.5)):
        try:
            bsdf.inputs[k].default_value = v
        except Exception:
            pass
    return m


def decal_material(key, n=GAME_PX, name=None):
    """decal 材质：带 alpha 的**透明混合**（引擎直接摆单件用）。"""
    suffix = _tag_of(n)
    img_a = bpy.data.images.get("%s_alb%s.png" % (key, suffix))
    img_n = bpy.data.images.get("%s_nrm%s.png" % (key, suffix))
    img_r = bpy.data.images.get("%s_rgh%s.png" % (key, suffix))
    if img_a is None:
        raise RuntimeError("decal 未落盘：%s %s" % (key, suffix))
    mname = name or ("gtd_%s_%d" % (key, n))
    old = bpy.data.materials.get(mname)
    if old is not None:
        bpy.data.materials.remove(old)
    m = bpy.data.materials.new(mname)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    tc = nt.nodes.new("ShaderNodeTexCoord")

    def tex(img, cs):
        nd = nt.nodes.new("ShaderNodeTexImage")
        nd.image = img
        nd.extension = "CLIP"
        nd.interpolation = "Linear"
        nd.image.colorspace_settings.name = cs
        nd.outputs["Alpha"].default_value = 1.0
        nt.links.new(tc.outputs["UV"], nd.inputs["Vector"])
        return nd

    ta = tex(img_a, "sRGB")
    tn = tex(img_n, "Non-Color")
    tr = tex(img_r, "Non-Color")
    nmap = nt.nodes.new("ShaderNodeNormalMap")
    nt.links.new(ta.outputs["Color"], bsdf.inputs["Base Color"])
    nt.links.new(ta.outputs["Alpha"], bsdf.inputs["Alpha"])
    nt.links.new(tn.outputs["Color"], nmap.inputs["Color"])
    nt.links.new(nmap.outputs["Normal"], bsdf.inputs["Normal"])
    nt.links.new(tr.outputs["Color"], bsdf.inputs["Roughness"])
    for attr, val in (("blend_method", "BLEND"),
                      ("surface_render_method", "BLENDED"),
                      ("shadow_method", "NONE")):
        try:
            setattr(m, attr, val)
        except Exception:
            pass
    for k, v in (("IOR", 1.45), ("Coat Weight", 0.0), ("Specular IOR Level", 0.5)):
        try:
            bsdf.inputs[k].default_value = v
        except Exception:
            pass
    return m


def mottle_material(tile_key, mottle_key="mottle_a", n=GAME_PX, name=None,
                    k=MOTTLE_K, mottle_scale=1.0):
    """"带贴图 albedo × 低频斑驳乘图"的地面材质（k = 斑驳强度）。

    乘图按 `mult = 1 + (m-0.5)*k` 使用（m 是 [0,1] 灰度；0.5 = 不变）。
    """
    mname = name or ("gtm_%s_%s" % (tile_key, mottle_key))
    old = bpy.data.materials.get(mname)
    if old is not None:
        bpy.data.materials.remove(old)
    m = bpy.data.materials.new(mname)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    tc = nt.nodes.new("ShaderNodeTexCoord")

    def _img(name):
        img = bpy.data.images.get(name)
        if img is None:
            raise RuntimeError("缺图 %s（先 export_all）" % name)
        return img

    def tex(img, cs, ext="REPEAT"):
        nd = nt.nodes.new("ShaderNodeTexImage")
        nd.image = img
        nd.extension = ext
        nd.interpolation = "Linear"
        nd.image.colorspace_settings.name = cs
        nt.links.new(tc.outputs["UV"], nd.inputs["Vector"])
        return nd

    ta = tex(_img("%s_alb_%d.png" % (tile_key, GAME_PX)), "sRGB")
    tn = tex(_img("%s_nrm_%d.png" % (tile_key, GAME_PX)), "Non-Color")
    tr = tex(_img("%s_rgh_%d.png" % (tile_key, GAME_PX)), "Non-Color")
    mo = tex(_img("%s.png" % mottle_key), "Non-Color")
    if abs(mottle_scale - 1.0) > 1e-6:
        mp = nt.nodes.new("ShaderNodeMapping")
        mp.inputs["Scale"].default_value = (mottle_scale, mottle_scale, 1.0)
        nt.links.new(tc.outputs["UV"], mp.inputs["Vector"])
        nt.links.new(mp.outputs["Vector"], mo.inputs["Vector"])
    nmap = nt.nodes.new("ShaderNodeNormalMap")
    nt.links.new(tn.outputs["Color"], nmap.inputs["Color"])
    nt.links.new(nmap.outputs["Normal"], bsdf.inputs["Normal"])
    nt.links.new(tr.outputs["Color"], bsdf.inputs["Roughness"])
    mth = nt.nodes.new("ShaderNodeMath")
    mth.operation = "MULTIPLY_ADD"
    mth.inputs[1].default_value = float(k)
    mth.inputs[2].default_value = 1.0 - 0.5 * float(k)
    nt.links.new(mo.outputs["Color"], mth.inputs[0])
    try:                                     # Blender 4+: ShaderNodeMix（RGBA）
        mx = nt.nodes.new("ShaderNodeMix")
        mx.data_type = "RGBA"
        mx.blend_type = "MULTIPLY"
        mx.inputs["Factor"].default_value = 1.0
        nt.links.new(ta.outputs["Color"], mx.inputs[6])
        nt.links.new(mth.outputs[0], mx.inputs[7])
        nt.links.new(mx.outputs[2], bsdf.inputs["Base Color"])
    except Exception:                        # 老接口回退
        mx = nt.nodes.new("ShaderNodeMixRGB")
        mx.blend_type = "MULTIPLY"
        mx.inputs["Fac"].default_value = 1.0
        nt.links.new(ta.outputs["Color"], mx.inputs[1])
        nt.links.new(mth.outputs[0], mx.inputs[2])
        nt.links.new(mx.outputs[0], bsdf.inputs["Base Color"])
    for kk, vv in (("IOR", 1.45), ("Coat Weight", 0.0), ("Specular IOR Level", 0.5)):
        try:
            bsdf.inputs[kk].default_value = vv
        except Exception:
            pass
    return m


if __name__ == "__main__":
    # 只做数据层：落盘贴图 + json（渲染见 probe_ground.py）
    OUT = os.path.join(os.path.dirname(os.path.dirname(HERE)),
                       "stick-world", "temp", "ground_tiles")
    print("== ground_tiles 落盘 →", OUT)
    recs = export_all(OUT)
    print("GS_OK", len(recs))
