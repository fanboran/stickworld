# -*- coding: utf-8 -*-
"""R5 城市建成区 v2：场叠加管线（Python 生成端，观感返工 §7.1-3）

「场场叠加 → 阈值 → marching squares」一次拿到路手指/破碎边界/多中心粘连/内部空隙：

    U = a·核场(exp(-d²/2σ²)×cap(θ_d)) + b·道路条带场(exp(-d_r/w_r)×沿路长度衰减→手指)
        + Σ卫星种子高斯(沿路 0.5~1.3R 避水体) + amp·fBm(2~3 八度 value noise)
    U *= 排除层(水体/陡坡/海域硬置 0，SLEUTH 式否决)
    τ 按目标面积分位数反解: τ = quantile(U[可建], 1 - A_target/A_avail)   # A_target = π·R_ref²·k
    binary_opening(1) → binary_closing(2) → find_contours 亚像素多环(外环+内环洞+飞地)
    → shapely simplify 保拓扑；洞面积 < max(3% 城区, 60px²) 丢弃

尺度 R_ref(level, s) = base + g_max·s^gamma 复用旧 blob_params.json 的 level 带
（与 blob_bake.py 的容量探测段同源，保证「容量卡向」语义一致）。

三档（tiers.low/mid/high）：每城按档位 s 各算一版轮廓——运行时随人口增长切档（R5 裁决）。
贫瘠城（s 低 / capacity≈0 / 被山恋水卡死）目标面积自然塌缩 → 合法输出「无建成区」。

本工具只做生成端与预览，不接运行时、不写游戏包（config/ 只读，旧管线 blob_bake.py 不动）。
产物：几何+统计进 output/blob_v2/（gitignored）；入库对比图落 output/ 根 blob_v2_*.png。

用法：
    python blob_v2_generate.py               # 全量 1048 城 × 3 档 + 全部预览
    python blob_v2_generate.py --sample      # 只跑特写/贫瘠抽查/分形样本城（调参快循环）
    python blob_v2_generate.py --no-overview # 跳过全图概览渲染

fBm 不用 opensimplex（逐像素 Python 调用太慢），自写向量化 value noise +
整数 hash（同 seed 跨机器确定性），2~3 八度波长 24/12/6px 幅度几何衰减。
"""

import json
import math
import os
import sys
import time

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage as ndi
from skimage import measure, morphology
from shapely.geometry import Polygon

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # tools/worldgen
OUTPUT_DIR = os.path.join(HERE, "output")
BLOB_V2_DIR = os.path.join(OUTPUT_DIR, "blob_v2")
GAME_DIR = os.path.normpath(os.path.join(HERE, "..", "..", "stick-world", "config", "strategic_map"))
PARAMS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "blob_v2_params.json")

SIZE = 8192                     # 世界统一分辨率
BIOME_NAMES = {0: "ocean", 1: "plains", 2: "forest", 3: "desert",
               4: "tundra", 5: "spring", 6: "volcano"}
TIER_ORDER = ["low", "mid", "high"]
TIER_COLORS = {"low": (255, 220, 90), "mid": (90, 200, 255), "high": (255, 120, 90)}


def djb2(s: str) -> int:
    """跨语言确定哈希（blob_bake.py 同实现）"""
    h = 5381
    for c in s.encode("utf-8"):
        h = ((h * 33) + c) & 0xFFFFFFFF
    return h


def r_ref_of(level, s, area_p, lv_bands):
    """尺度半径：复用旧 blob level 带 base + g_max·s^gamma（与容量探测段同源）"""
    base, g_max = lv_bands.get(level, (30.0, 30.0))
    return base + g_max * (max(s, 0.0) ** float(area_p["gamma"]))


# ==================== 输入加载 ====================

def load_inputs():
    print("[v2] 加载高度场/水体/大陆掩码 ...")
    height = np.load(os.path.join(OUTPUT_DIR, "fractal_heightmap_8192.npy")).astype(np.float32)
    hgy, hgx = np.gradient(height)
    grad = np.sqrt(hgx * hgx + hgy * hgy).astype(np.float32)
    del height, hgy, hgx
    river = np.array(Image.open(os.path.join(OUTPUT_DIR, "fractal_river_mask_8192.png")).convert("L")) > 127
    lake = np.array(Image.open(os.path.join(OUTPUT_DIR, "fractal_lake_mask_8192.png")).convert("L")) > 127
    land = np.array(Image.open(os.path.join(OUTPUT_DIR, "locked", "locked_continent_8192.png")).convert("L")) > 127
    water = river | lake
    del river, lake
    print("  梯度 p50/p90/p97 = %.5f / %.5f / %.5f"
          % tuple(np.percentile(grad[land], [50, 90, 97])))
    return grad, water, land


def load_cities():
    """收集 1048 城：世界锚点 / level / population_score / blob_capacity[16] / 周边道路(世界系)"""
    print("[v2] 收集城市锚点与周边道路（L1 视图包，只读）...")
    paths = [os.path.join(GAME_DIR, "l1_world.json")]
    pack_dir = os.path.join(GAME_DIR, "l1_packs")
    paths += [os.path.join(pack_dir, d, "l1_world.json")
              for d in sorted(os.listdir(pack_dir))
              if os.path.exists(os.path.join(pack_dir, d, "l1_world.json"))]
    cities = {}
    for jp in paths:
        world = json.load(open(jp, encoding="utf-8"))
        worg = world.get("world_origin")
        if not worg:
            continue
        ox, oy = float(worg[0]), float(worg[1])
        roads_by_city = {}
        for r in world.get("roads", []):
            poly = [(float(p[0]) + ox, float(p[1]) + oy) for p in r.get("polyline", [])]
            biomes = r.get("biomes") or []
            for sid in (r.get("from"), r.get("to")):
                if sid:
                    roads_by_city.setdefault(sid, []).append((poly, biomes))
        for t in world.get("tiles", []):
            s = t.get("settlement")
            if not s:
                continue
            sid = s["settlement_id"]
            cities[sid] = {
                "sid": sid,
                "wx": float(s["position_px"][0]) + ox,
                "wy": float(s["position_px"][1]) + oy,
                "level": int(s.get("level", 1)),
                "ps": float(s.get("population_score") or 0.0),
                "cap": [float(v) for v in s.get("blob_capacity") or [1.0] * 16],
                "roads": roads_by_city.get(sid, []),
            }
    spawn_sid = json.load(open(os.path.join(GAME_DIR, "l1_world.json"),
                               encoding="utf-8"))["spawn_settlement_id"]
    print("  %d 城（spawn=%s）" % (len(cities), spawn_sid))
    return cities, spawn_sid


# ==================== 场基元 ====================

def _hash01(ix, iy, seed):
    """整数网格 hash → [0,1]（numpy 向量化，跨机器确定）"""
    h = ix.astype(np.int64) * 374761393 + iy.astype(np.int64) * 668265263 + np.int64(seed)
    h = (h ^ (h >> np.int64(13))) * np.int64(1274126177)
    h = h ^ (h >> np.int64(16))
    return (h & np.int64(0x7FFFFFFF)).astype(np.float32) / float(0x7FFFFFFF)


def _value_noise(X, Y, wavelength, seed):
    """单倍频 value noise（双线性 + smoothstep），波长以 px 计"""
    f = 1.0 / max(wavelength, 2.0)
    gx, gy = X * f, Y * f
    ix, iy = np.floor(gx), np.floor(gy)
    fx, fy = gx - ix, gy - iy
    fx = fx * fx * (3.0 - 2.0 * fx)
    fy = fy * fy * (3.0 - 2.0 * fy)
    ixi, iyi = ix.astype(np.int64), iy.astype(np.int64)
    v00 = _hash01(ixi, iyi, seed)
    v10 = _hash01(ixi + 1, iyi, seed)
    v01 = _hash01(ixi, iyi + 1, seed)
    v11 = _hash01(ixi + 1, iyi + 1, seed)
    return (v00 * (1 - fx) + v10 * fx) * (1 - fy) + (v01 * (1 - fx) + v11 * fx) * fy


def fbm_field(X, Y, seed, fp):
    """2~3 八度 fBm → [-1,1]×amp（同窗口/seed 三档共用一份）"""
    amps, tot, a = [], 0.0, 1.0
    for _ in fp["wavelengths"]:
        amps.append(a)
        tot += a
        a *= float(fp["amp_decay"])
    out = np.zeros(np.shape(X), np.float32)
    for i, (wl, am) in enumerate(zip(fp["wavelengths"], amps)):
        out += am * (_value_noise(X, Y, wl, seed + i * 101) * 2.0 - 1.0)
    return out / max(tot, 1e-6) * float(fp["amp"])


def cap_at(cap16, dx, dy):
    """16 方向容量双线性插值（角向环绕），dx/dy 为相对锚点位移"""
    cap = np.asarray(cap16, np.float32)
    ang = np.arctan2(dy, dx) % math.tau
    t = ang / math.tau * 16.0
    i0 = np.floor(t).astype(np.int32) % 16
    f = (t - np.floor(t)).astype(np.float32)
    return cap[i0] * (1.0 - f) + cap[(i0 + 1) % 16] * f


def _dense_polyline(poly, step):
    """折线等弧长重采样 → (N,2) 点列 + 沿线弧长 t"""
    pts = np.asarray(poly, np.float32)
    if len(pts) < 2:
        return pts, np.zeros(len(pts), np.float32)
    seg = np.sqrt(((pts[1:] - pts[:-1]) ** 2).sum(axis=1))
    L = float(seg.sum())
    n = max(int(L / step), 2)
    s = np.linspace(0.0, L, n).astype(np.float32)
    c = np.cumsum(np.insert(seg, 0, 0.0))
    return np.stack([np.interp(s, c, pts[:, 0]), np.interp(s, c, pts[:, 1])], axis=1), s


def _oriented(poly, ax, ay):
    """折线定向：城端（离锚点近端）在前，返回 (点列, 离城沿路弧长)"""
    pts, t = _dense_polyline(poly, 2.0)
    if len(pts) < 2:
        return pts, t
    d0 = math.hypot(pts[0, 0] - ax, pts[0, 1] - ay)
    d1 = math.hypot(pts[-1, 0] - ax, pts[-1, 1] - ay)
    if d1 < d0:
        pts, t = pts[::-1].copy(), t[::-1].copy()
    return pts, t


def _stamp(field, cx, cy, rad, kernel, w, h):
    """核模板局部注入（越界裁剪）"""
    xi, yi = int(round(cx)), int(round(cy))
    x0, x1 = max(xi - rad, 0), min(xi + rad + 1, w)
    y0, y1 = max(yi - rad, 0), min(yi + rad + 1, h)
    if x0 >= x1 or y0 >= y1:
        return
    field[y0:y1, x0:x1] += kernel[y0 - yi + rad:y1 - yi + rad,
                                  x0 - xi + rad:x1 - xi + rad]


def gauss_stamp(field, cx, cy, sigma, amp, w, h):
    rad = int(math.ceil(3.0 * sigma))
    yy, xx = np.mgrid[-rad:rad + 1, -rad:rad + 1]
    _stamp(field, cx, cy, rad,
           (amp * np.exp(-(xx * xx + yy * yy) / (2.0 * sigma * sigma))).astype(np.float32),
           w, h)


def road_field(shape, wx0, wy0, roads, r_ref, s, rp, seed):
    """道路条带场：沿路「串珠」高斯（幅度/尺寸随离城衰减 + 确定性扰动）。
    珠串粘连成手指但保留斑块波动——比均匀条带多尺度（D_b↑），直路段不再出人工直边。
    roads 折线是世界坐标，本地栅格 = 世界 - 窗口原点"""
    h, w = shape
    field = np.zeros(shape, np.float32)
    hw = float(np.clip(rp["half_width_r"] * r_ref,
                       rp["half_width_min"], rp["half_width_max"]))
    L = rp["finger_r"] * r_ref * (1.0 + rp["finger_s_gain"] * s)
    gap = rp["bead_gap_hw"] * hw                     # 珠间距（hw 倍数）
    ax, ay = wx0 + w * 0.5, wy0 + h * 0.5
    for ri, (poly, _biomes) in enumerate(roads):
        pts, t = _oriented(poly, ax, ay)
        if pts.ndim != 2 or len(pts) < 2:
            continue
        rng = np.random.default_rng((seed ^ (ri * 0x85EBCA6B)) & 0x7FFFFFFF)
        lx = pts[:, 0] - wx0
        ly = pts[:, 1] - wy0
        for tj in np.arange(rng.uniform(0.0, gap), float(t.max()) + gap, gap):
            i = int(np.argmin(np.abs(t - tj)))
            if not (-3 * hw <= lx[i] < w + 3 * hw and -3 * hw <= ly[i] < h + 3 * hw):
                continue
            amp = math.exp(-tj / max(L, 4.0))
            if amp < 0.02:
                break
            bead_rng = rng.uniform(0.0, 1.0, 2)
            amp *= 1.0 + rp["bead_amp_var"] * (bead_rng[0] - 0.5) * 2.0
            sigma = hw * (1.0 + rp["bead_size_var"] * (bead_rng[1] - 0.5) * 2.0)
            gauss_stamp(field, lx[i], ly[i], max(sigma, 2.0), amp, w, h)
    return field


def park_holes(U, ax, ay, r_ref, excl, pp, rng):
    """内部空隙（绿楔/裸地）显式注入：0.3~0.8R 环带撒负高斯（排斥场），U 就地修改。
    数量按 r_ref/60 缩放（贫村无绿楔）"""
    h, w = U.shape
    d_lo, d_hi = pp["dist_r"]
    scale = float(np.clip(r_ref / 60.0, 0.45, 1.0))
    n = int(round(pp["n_max"] * scale * (0.5 + 0.5 * rng.uniform(0.0, 1.0))))
    for _ in range(n):
        ang = rng.uniform(0.0, math.tau)
        dist = (d_lo + (d_hi - d_lo) * rng.uniform(0.0, 1.0)) * r_ref
        x, y = ax + dist * math.cos(ang), ay + dist * math.sin(ang)
        xi, yi = int(round(x)), int(round(y))
        if 2 <= xi < w - 2 and 2 <= yi < h - 2 and excl[yi, xi] > 0:
            sigma = max(float(pp["sigma_r"]) * r_ref, 3.0)
            rad = int(math.ceil(3.0 * sigma))
            yy, xx = np.mgrid[-rad:rad + 1, -rad:rad + 1]
            _stamp(U, x, y, rad,
                   (-float(pp["amp"]) * np.exp(-(xx * xx + yy * yy) / (2.0 * sigma * sigma))).astype(np.float32),
                   w, h)


def seed_positions(shape, wx0, wy0, roads, r_ref, buildable, sp, rng):
    """卫星种子：沿路 0.5~1.3R_ref 取点，须落可建区（避水体/陡坡）且在窗内"""
    h, w = shape
    d_lo, d_hi = sp["dist_r"]
    ax, ay = wx0 + w * 0.5, wy0 + h * 0.5
    cands = []
    for poly, _biomes in roads:
        pts, t = _oriented(poly, ax, ay)
        if pts.ndim != 2 or len(pts) < 2:
            continue
        for u in np.linspace(0.05, 0.95, 9):
            dist = (d_lo + (d_hi - d_lo) * u) * r_ref
            i = int(np.argmin(np.abs(t - dist)))
            x, y = pts[i, 0] - wx0, pts[i, 1] - wy0
            xi, yi = int(round(x)), int(round(y))
            if 1 <= xi < w - 1 and 1 <= yi < h - 1 and buildable[yi, xi]:
                cands.append((float(x), float(y)))
    rng.shuffle(cands)
    return cands[:int(sp["n_max"])]


# ==================== 单城单档管线 ====================

def window_of(wx, wy, r_ref, wp):
    """本地栅格 W×W（W≈5×R_ref，clamp 192~512），窗口尽量以锚点为中心"""
    W = int(np.clip(math.ceil(wp["w_r"] * r_ref), wp["w_min"], wp["w_max"]))
    wx0 = min(max(int(round(wx - W * 0.5)), 0), SIZE - W)
    wy0 = min(max(int(round(wy - W * 0.5)), 0), SIZE - W)
    return W, wx0, wy0


def city_field_mask(city, s, tier_idx, ctx, p, lv_bands, fbm_cache):
    """管线 1~8 步：场叠加 + 排除层 + τ 分位数反解 + 形态学清理 → mask（及诊断 info）"""
    r_ref = r_ref_of(city["level"], s, p["area"], lv_bands)
    W, wx0, wy0 = window_of(city["wx"], city["wy"], r_ref, p["window"])
    key = (city["sid"], W, wx0, wy0)
    if key not in fbm_cache:
        Y, X = np.mgrid[0:W, 0:W].astype(np.float32)
        fbm_cache[key] = fbm_field(X, Y, djb2(city["sid"]) & 0xFFFF, p["fbm"])
    fbm = fbm_cache[key]

    ax, ay = city["wx"] - wx0, city["wy"] - wy0
    Y, X = np.mgrid[0:W, 0:W].astype(np.float32)
    dx, dy = X - ax, Y - ay
    sigma = max(float(p["core"]["sigma_r"]) * r_ref, 3.0)

    # 细节幅度按城市尺度缩放：小城（贫村）不该被全幅噪声搅碎
    ds = p.get("detail_scale", {})
    scale = float(np.clip(r_ref / float(ds.get("ref", 60.0)),
                          float(ds.get("min", 0.45)), 1.0))

    # 6 排除层先算：水体/陡坡/海域硬置 0（SLEUTH 式否决）
    sl = ctx["world"]["grad"][wy0:wy0 + W, wx0:wx0 + W]
    wt = ctx["world"]["water"][wy0:wy0 + W, wx0:wx0 + W]
    ld = ctx["world"]["land"][wy0:wy0 + W, wx0:wx0 + W]
    excl = (ld & (~wt) & (sl < p["exclusion"]["slope_hard"])).astype(np.float32)

    # 2 核场 exp(-d²/2σ²)×cap(θ_d) + 3 道路串珠场 + 5 fBm（fBm 不参与种子落点判定）
    core = np.exp(-(dx * dx + dy * dy) / (2.0 * sigma * sigma)) * cap_at(city["cap"], dx, dy)
    road = road_field((W, W), wx0, wy0, city["roads"], r_ref, s, p["road"],
                      djb2(city["sid"]) & 0x7FFFFFFF)
    U = float(p["core"]["a"]) * core + float(p["road"]["b"]) * road

    # 4 卫星种子：沿路 0.5~1.3R、避水体/陡坡（多中心粘连）
    rng = np.random.default_rng((djb2(city["sid"]) ^ (tier_idx * 0x9E3779B1)) & 0x7FFFFFFF)
    seeds = seed_positions((W, W), wx0, wy0, city["roads"], r_ref,
                           (U * excl) > 0.15, p["seeds"], rng)
    sig_s = max(float(p["seeds"]["sigma_r"]) * r_ref, 2.5)
    for sx, sy in seeds:
        gauss_stamp(U, sx, sy, sig_s, float(p["seeds"]["amp"]), W, W)
    park_holes(U, ax, ay, r_ref, excl, p["parks"], rng)     # 内部空隙（绿楔）负场
    U += float(p["fbm"]["amp"]) * scale * fbm

    # 6 乘排除层 + 7 阈值分位数反解（A_target = π·R_ref²·k）
    U *= excl
    a_target = math.pi * r_ref * r_ref * float(p["area"]["k"])
    avail = int(excl.sum())
    info = {"r_ref": r_ref, "W": W, "target": round(a_target, 1), "n_seeds": len(seeds),
            "scale": scale,
            "tau": None, "area": 0}
    if avail < 8 or float(U.max()) <= 1e-4:
        return np.zeros((W, W), bool), info, (wx0, wy0)
    q = 1.0 - a_target / avail
    if q < 0.0:                     # 可建区比目标还小（被山水围死）→ 退而取最强 fallback_q
        q = float(p["area"]["fallback_q"])
    tau = float(np.quantile(U[excl > 0], float(np.clip(q, 0.0, 0.999))))
    info["tau"] = round(tau, 4)

    # 8 形态学清理：opening 去孤点（0=跳过，飞地由面积阈值把关），closing 连近斑（绿楔保留）
    mask = U > tau
    orad, crad = int(p["morph"]["opening_r"]), int(p["morph"]["closing_r"])
    if orad > 0:
        mask = morphology.opening(mask, morphology.disk(orad))
    if crad > 0:
        mask = morphology.closing(mask, morphology.disk(crad))
    info["area"] = int(mask.sum())
    if info["area"] < int(p["area"]["min_total_area"]):
        return np.zeros((W, W), bool), info, (wx0, wy0)
    return mask, info, (wx0, wy0)


def roughen_rings(rings_local, sid, rp, scale=1.0):
    """§7.1-2.6 边界噪声扰动：对等值线点列沿法线叠加 2~3 八度 fBm 位移（去圆滑感最后一公里）。
    噪声以环点坐标直接采样 → 空间一致（共享边界的内外环位移天然咬合，不撕裂）"""
    amp0 = float(rp["amp"]) * scale
    if amp0 <= 0 or not rings_local:
        return rings_local
    seed = djb2(sid) & 0xFFFF
    out = []
    for xy in rings_local:
        pts = np.asarray(xy, np.float64)
        if len(pts) < int(rp["min_ring_pts"]):
            out.append(pts)
            continue
        # 法线 = 切线（中心差分）旋转 -90°
        tang = np.zeros_like(pts)
        tang[1:-1] = pts[2:] - pts[:-2]
        tang[0] = pts[1] - pts[0]
        tang[-1] = pts[-1] - pts[-2]
        ln = np.hypot(tang[:, 0], tang[:, 1])
        ln[ln == 0] = 1.0
        normal = np.stack([tang[:, 1] / ln, -tang[:, 0] / ln], axis=1)
        disp = np.zeros(len(pts))
        amp, k = amp0, 0
        for wl in rp["wavelengths"]:
            nz = _value_noise(pts[:, 0], pts[:, 1], wl, seed + k * 17) * 2.0 - 1.0
            disp += nz * amp
            amp *= float(rp["amp_decay"])
            k += 1
        moved = pts + normal * disp[:, None]
        win = int(rp.get("smooth_win", 3))
        if win >= 2:                               # 环形滑动平均：抑制位移自交尖刺，保毛边
            moved = ndi.uniform_filter1d(moved, win, axis=0, mode="wrap")
        out.append(moved)
    return out


def _as_polygon(pts):
    """构造有效 Polygon：roughen 自交先 buffer(0) 修复（contains 判定依赖有效几何），Multi 取最大子块"""
    pg = Polygon(pts)
    if not pg.is_valid:
        fixed = pg.buffer(0)
        if fixed.geom_type in ("MultiPolygon", "GeometryCollection"):
            parts = [x for x in fixed.geoms if x.geom_type == "Polygon"]
            pg = max(parts, key=lambda x: x.area) if parts else pg
        elif fixed.geom_type == "Polygon":
            pg = fixed
    return pg


def assemble_polygons(rings_local, wx0, wy0, cp):
    """环 → (外环, [洞]) 集合：嵌套深度定角色（偶=外环/奇=洞），面积阈值过滤 + simplify 保拓扑"""
    rings = []
    for xy in rings_local:
        arr = np.asarray(xy, np.float64)
        if len(arr) < 4:
            continue
        pts = np.stack([arr[:, 0] + wx0, arr[:, 1] + wy0], axis=1)   # 本地(x,y)→世界
        pg = _as_polygon(pts)
        if pg.area > 1.0:
            rings.append((np.asarray(pg.exterior.coords)[:-1], pg))
    if not rings:
        return []
    depth = [0] * len(rings)
    host = [-1] * len(rings)
    order = sorted(range(len(rings)), key=lambda i: rings[i][1].area, reverse=True)
    for a in range(len(order)):
        ia = order[a]
        for b in range(a):
            ib = order[b]
            if rings[ib][1].contains(rings[ia][1].representative_point()):
                depth[ia] += 1
                if host[ia] < 0 or rings[ib][1].area < rings[host[ia]][1].area:
                    host[ia] = ib
    outers, holes_of = [], {}
    for ia in order:
        if depth[ia] % 2 == 0:
            outers.append(ia)
            holes_of[ia] = []
        elif host[ia] >= 0:
            root = host[ia]
            while depth[root] % 2 == 1 and host[root] >= 0:   # 洞的洞 → 归属最外外环
                root = host[root]
            if root in holes_of:
                holes_of[root].append(ia)
    result = []
    for io in outers:
        _, opg = rings[io]
        if opg.area < cp["enclave_min_area"]:
            continue
        o = _simp(opg, cp["simplify_tol"])
        if o is None or o.area < cp["enclave_min_area"] * 0.5:
            continue
        holes = []
        for ih in holes_of.get(io, []):
            _, hpg = rings[ih]
            if hpg.area < max(cp["hole_min_frac"] * o.area, cp["hole_min_abs"]):
                continue
            h = _simp(hpg, cp["simplify_tol"])
            if h is None or h.area >= o.area:
                continue
            h = h.intersection(o)                 # 洞 clip 回外环内，保拓扑有效
            if h.is_empty or h.area < cp["hole_min_abs"] * 0.5:
                continue
            geom = h if h.geom_type == "Polygon" else max(h.geoms, key=lambda g: g.area)
            holes.append(np.asarray(geom.exterior.coords)[:-1])
        result.append((np.asarray(o.exterior.coords)[:-1], holes))
    return result


def _simp(pg, tol):
    """simplify 保拓扑；roughen 自交环先 buffer(0) 修复，产出 Multi 时取最大子块"""
    try:
        if not pg.is_valid:
            pg = pg.buffer(0)
        g = pg.simplify(tol, preserve_topology=True)
        if not g.is_valid:
            g = g.buffer(0)
        if g.is_empty:
            return None
        if g.geom_type == "MultiGeometry" or g.geom_type == "GeometryCollection":
            parts = [x for x in g.geoms if x.geom_type == "Polygon"]
            if not parts:
                return None
            g = max(parts, key=lambda x: x.area)
        return g if g.geom_type == "Polygon" else None
    except Exception:
        return None


def mask_to_polys(mask, sid, wx0, wy0, p, scale=1.0):
    """mask → 亚像素等值线（本地 x,y）→ 法向噪声粗糙化 → shapely 组装多环。
    mask pad 一圈 0：手指/斑块触窗边时等值线仍闭合（开放折线会令 Polygon 面积≈0 全环丢失）"""
    pm = np.pad(mask.astype(np.float32), 1)
    rings = [c[:, ::-1] - 1.0 for c in measure.find_contours(pm, 0.5)]   # pad 补偿，本地(x,y)
    rings = roughen_rings(rings, sid, p["roughen"], scale)
    return assemble_polygons(rings, wx0, wy0, p["contour"])


def generate_city_tier(city, s, tier_idx, ctx, p, lv_bands, fbm_cache):
    """完整单城单档：管线 → 多边形集合（世界坐标）+ 诊断 info"""
    mask, info, (wx0, wy0) = city_field_mask(city, s, tier_idx, ctx, p, lv_bands, fbm_cache)
    if not mask.any():
        return [], info
    polys = mask_to_polys(mask, city["sid"], wx0, wy0, p, info.get("scale", 1.0))
    info["n_outer"] = len(polys)
    info["n_holes"] = sum(len(h) for _, h in polys)
    return polys, info


def box_counting_dim_pts(pts, eps_list):
    """盒计数估边界维数 D_b：对最终输出轮廓折线点集数盒子（log-log 回归斜率；合理带 1.2~1.5）"""
    if len(pts) < 32:
        return None
    ns = []
    for e in eps_list:
        keys = np.floor(np.asarray(pts, np.float64) / e).astype(np.int64)
        ns.append(len(np.unique(keys, axis=0)))
    ns = np.asarray(ns, np.float64)
    eps = np.asarray(eps_list, np.float64)
    keep = ns >= 8                        # 尾部盒子过少不稳
    if keep.sum() < 3:
        return None
    return float(np.polyfit(np.log(1.0 / eps[keep]), np.log(ns[keep]), 1)[0])


def polys_boundary_pts(polys):
    """多边形集合 → 边界点集（世界坐标，每环按 1px 弧长加密——盒计数要求线段连续覆盖）"""
    pts = []
    for outer, holes in polys:
        for ring in [outer] + list(holes):
            r = np.asarray(ring, np.float64)
            if len(r) >= 2:
                r = np.vstack([r, r[:1]])           # 闭合
                seg = np.sqrt(((r[1:] - r[:-1]) ** 2).sum(axis=1))
                L = float(seg.sum())
                if L < 4:
                    continue
                s = np.linspace(0.0, L, max(int(L), 2))
                c = np.cumsum(np.insert(seg, 0, 0.0))
                pts.append(np.stack([np.interp(s, c, r[:, 0]),
                                     np.interp(s, c, r[:, 1])], axis=1))
    return np.vstack(pts) if pts else np.zeros((0, 2))


# ==================== 渲染 ====================

def _tile_base(ctx, wx0, wy0, win):
    """特写底图：l3_terrain.png(2048) 裁切放大 + 水体 tint 保证水系清晰"""
    terr = ctx["terrain_img"]
    k = SIZE // terr.size[0]                       # 4
    box = (wx0 // k, wy0 // k, (wx0 + win) // k, (wy0 + win) // k)
    tile = terr.crop(box).resize((win, win), Image.LANCZOS).convert("RGB")
    wt = ctx["world"]["water"][wy0:wy0 + win, wx0:wx0 + win]
    arr = np.asarray(tile).astype(np.float32)
    arr[wt] = arr[wt] * 0.45 + np.array([62.0, 108.0, 150.0]) * 0.55
    return Image.fromarray(arr.astype(np.uint8), "RGB")


def draw_city_polys(base, polys_by_tier, wx0, wy0, fill_tier="mid"):
    """多环+洞+飞地如实画：fill_tier 填充（洞挖空），三档描边（黄 low/青 mid/红 high）"""
    ov = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)
    polys = polys_by_tier.get(fill_tier) or (list(polys_by_tier.values())[-1] if polys_by_tier else [])
    for outer, holes in polys:
        pts = [(x - wx0, y - wy0) for x, y in outer]
        if len(pts) >= 3:
            d.polygon(pts, fill=(196, 186, 168, 165))
    alpha = ov.getchannel("A")
    da = ImageDraw.Draw(alpha)
    for outer, holes in polys:
        for hring in holes:
            pts = [(x - wx0, y - wy0) for x, y in hring]
            if len(pts) >= 3:
                da.polygon(pts, fill=0)
    ov.putalpha(alpha)
    out = base.convert("RGBA")
    out.alpha_composite(ov)
    dr = ImageDraw.Draw(out, "RGBA")
    for tier in TIER_ORDER:
        for outer, holes in polys_by_tier.get(tier, []):
            col = TIER_COLORS[tier] + (255,)
            pts = [(x - wx0, y - wy0) for x, y in outer]
            if len(pts) >= 3:
                dr.line(pts + [pts[0]], fill=col, width=2)
            for hring in holes:
                hp = [(x - wx0, y - wy0) for x, y in hring]
                if len(hp) >= 3:
                    dr.line(hp + [hp[0]], fill=col, width=1)
    return out


def _center_win(c, win):
    wx0 = min(max(int(round(c["wx"] - win * 0.5)), 0), SIZE - win)
    wy0 = min(max(int(round(c["wy"] - win * 0.5)), 0), SIZE - win)
    return wx0, wy0


def render_closeup(ctx, picks, results, p):
    """特写对比图（入库）：出生城 + 不同群系/级别的 3 城，2×2 拼图，多环+洞+飞地如实画"""
    win = int(p["preview"]["closeup_win"])
    tiles = []
    for c in picks:
        r = results[c["sid"]]
        wx0, wy0 = _center_win(c, win)
        base = _tile_base(ctx, wx0, wy0, win)
        img = draw_city_polys(base, r["polys"], wx0, wy0)
        dr = ImageDraw.Draw(img, "RGBA")
        ax, ay = c["wx"] - wx0, c["wy"] - wy0
        dr.ellipse([ax - 3, ay - 3, ax + 3, ay + 3], outline=(255, 255, 255, 255), width=2)
        dr.line([(10, win - 14), (110, win - 14)], fill=(255, 255, 255, 220), width=2)
        biome = BIOME_NAMES.get(r["biome"], "?")
        dr.text((8, 6), "%s lv%d ps%.2f %s%s"
                % (c["sid"].replace("settlement_city_", "city_"), c["level"], c["ps"], biome,
                   "  (NO BUILT-UP)" if not r["polys"] else ""),
                fill=(255, 255, 255, 255))
        tiles.append(img)
    while len(tiles) < 4:
        tiles.append(Image.new("RGB", (win, win), (10, 10, 10)))
    out = Image.new("RGB", (win * 2, win * 2), (10, 10, 10))
    for i, tile in enumerate(tiles[:4]):
        out.paste(tile.convert("RGB"), ((i % 2) * win, (i // 2) * win))
    path = os.path.join(OUTPUT_DIR, "blob_v2_closeup.png")
    out.save(path)
    print("  %s（%s）" % (os.path.basename(path),
                          " / ".join(c["sid"].replace("settlement_city_", "city_") for c in picks)))


def render_barren(ctx, barren_cities, results, p):
    """贫瘠抽查拼图（入库）：最贫瘠 N 城 mid 档渲染，确认总面积≈0 或零星小村斑点"""
    win = int(p["preview"]["barren_win"])
    cols = 5
    rows = (len(barren_cities) + cols - 1) // cols
    out = Image.new("RGB", (win * cols, win * rows), (10, 10, 10))
    for i, c in enumerate(barren_cities):
        r = results[c["sid"]]
        wx0, wy0 = _center_win(c, win)
        img = draw_city_polys(_tile_base(ctx, wx0, wy0, win),
                              {"mid": r["polys"]["mid"]}, wx0, wy0, fill_tier="mid")
        dr = ImageDraw.Draw(img, "RGBA")
        ax, ay = c["wx"] - wx0, c["wy"] - wy0
        dr.ellipse([ax - 2, ay - 2, ax + 2, ay + 2], outline=(255, 255, 255, 255), width=1)
        total = sum(Polygon(o).area for o, _ in r["polys"]["mid"])
        dr.text((6, 4), "%s ps%.2f" % (c["sid"].replace("settlement_city_", "city_"), c["ps"]),
                fill=(255, 255, 255, 255))
        dr.text((6, 18), ("area=%d" % total) if total else "NO BUILT-UP",
                fill=(255, 220, 90, 255) if total else (255, 90, 90, 255))
        out.paste(img.convert("RGB"), ((i % cols) * win, (i // cols) * win))
    path = os.path.join(OUTPUT_DIR, "blob_v2_barren_check.png")
    out.save(path)
    print("  %s（%d 城拼图）" % (os.path.basename(path), len(barren_cities)))


def render_fractal(db_rows, eps_list, outlines):
    """分形性自检图（入库）：样本城边界盒计数 log-log + mid 档轮廓缩略"""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, axes = plt.subplots(1, 1 + len(outlines), figsize=(4.2 + 3.2 * len(outlines), 4.4))
    for sid, ns, db in db_rows:
        eps = np.asarray(eps_list, float)
        keep = np.asarray(ns, float) >= 8
        axes[0].plot(eps[keep], np.asarray(ns, float)[keep], "o-",
                     label="%s D=%.2f" % (sid.replace("settlement_city_", "city_"), db))
    axes[0].set_xscale("log")
    axes[0].set_yscale("log")
    axes[0].invert_xaxis()
    axes[0].set_xlabel("box size (px)")
    axes[0].set_ylabel("N(eps) boundary boxes")
    axes[0].set_title("Box-counting D_b (target 1.2~1.5)")
    axes[0].legend(fontsize=8)
    axes[0].grid(True, which="both", alpha=0.3)
    for j, (sid, rings) in enumerate(outlines):
        for r in rings:
            axes[j + 1].plot(r[:, 0], -r[:, 1], lw=0.7, color="#404040")
        axes[j + 1].set_title(sid.replace("settlement_city_", "city_"), fontsize=9)
        axes[j + 1].set_aspect("equal")
        axes[j + 1].axis("off")
    out = os.path.join(OUTPUT_DIR, "blob_v2_fractal_check.png")
    fig.tight_layout()
    fig.savefig(out, dpi=110)
    plt.close(fig)
    print("  %s" % os.path.basename(out))


def render_overview(ctx, cities_order, results):
    """全图概览（gitignored）：按 population_score 选档画到 2048 地形底图（洞不画，0.25x 不可辨）"""
    terr = ctx["terrain_img"]
    img = terr.convert("RGBA")
    dr = ImageDraw.Draw(img, "RGBA")
    k = SIZE / terr.size[0]
    n = 0
    for c in cities_order:
        r = results.get(c["sid"])
        if not r or not r["polys"]["mid"]:
            continue
        tier = "low" if c["ps"] < 0.35 else ("mid" if c["ps"] < 0.65 else "high")
        for outer, _holes in r["polys"][tier] or r["polys"]["mid"]:
            pts = [(x / k, y / k) for x, y in outer]
            if len(pts) >= 3:
                dr.polygon(pts, fill=(198, 188, 170, 150), outline=(70, 62, 50, 200))
                n += 1
    path = os.path.join(BLOB_V2_DIR, "blob_v2_preview_2048.png")
    img.convert("RGB").save(path)
    print("  %s（%d 个多边形）" % (path, n))


# ==================== 样本挑选 ====================

def city_biome(c):
    """城周边道路 biomes 众数（road_biome_export 预采样）"""
    cnt = {}
    for _poly, biomes in c["roads"]:
        for b in biomes:
            if b in BIOME_NAMES:
                cnt[b] = cnt.get(b, 0) + 1
    return max(cnt.items(), key=lambda kv: kv[1])[0] if cnt else 1


def pick_closeup(cities_order, spawn_sid):
    """出生城 + 富 T3(异群系) + 中 T2(异群系) + 最贫 T1，尽量覆盖不同群系/级别"""
    spawn = next(c for c in cities_order if c["sid"] == spawn_sid)
    used = {city_biome(spawn)}
    picks = [spawn]
    pool = [c for c in cities_order if c["sid"] != spawn_sid]
    for lv, target in ((3, 0.80), (2, 0.5)):
        cands = [c for c in pool if c["level"] == lv]
        cands.sort(key=lambda c: abs(c["ps"] - target))
        got = next((c for c in cands if city_biome(c) not in used), None) \
            or (cands[0] if cands else None)
        if got:
            picks.append(got)
            used.add(city_biome(got))
    poor = sorted(pool, key=lambda c: c["ps"])[:40]
    picks.append(next((c for c in poor if city_biome(c) not in used), poor[0]))
    return picks


# ==================== 主流程 ====================

def main():
    sample_only = "--sample" in sys.argv
    no_overview = "--no-overview" in sys.argv
    p = json.load(open(PARAMS_PATH, encoding="utf-8"))
    os.makedirs(BLOB_V2_DIR, exist_ok=True)

    grad, water, land = load_inputs()
    cities, spawn_sid = load_cities()
    terr_path = os.path.join(OUTPUT_DIR, "l3_terrain.png")
    terrain_img = Image.open(terr_path).convert("RGB") if os.path.exists(terr_path) else None
    if terrain_img is None:
        print("  !! 缺 %s，预览跳过（几何仍生成）" % terr_path)
    ctx = {"world": {"grad": grad, "water": water, "land": land}, "terrain_img": terrain_img}
    old = json.load(open(os.path.join(GAME_DIR, "blob_params.json"), encoding="utf-8"))
    lv_bands = {int(k): (float(v["base"]), float(v["g_max"])) for k, v in old["levels"].items()}

    order = sorted(cities.values(), key=lambda c: c["sid"])
    picks = pick_closeup(order, spawn_sid)
    barren = sorted(order, key=lambda c: c["ps"])[:int(p["preview"]["barren_n"])]
    fractal_picks = picks[:3]
    if sample_only:
        keep = {c["sid"] for c in picks + barren}
        order = [c for c in order if c["sid"] in keep]
        print("[v2] --sample 模式：%d 城" % len(order))

    results, stats = {}, {}
    t0 = time.time()
    for n, c in enumerate(order):
        fbm_cache = {}                      # 每城独立（3 档共享同窗 fBm），防全量内存累积
        polys_by_tier, info_by_tier = {}, {}
        for ti, tier in enumerate(TIER_ORDER):
            polys, info = generate_city_tier(c, float(p["tiers"][tier]), ti,
                                             ctx, p, lv_bands, fbm_cache)
            polys_by_tier[tier] = polys
            info_by_tier[tier] = info
        results[c["sid"]] = {"polys": polys_by_tier, "info": info_by_tier,
                             "biome": city_biome(c)}
        stats[c["sid"]] = {"level": c["level"], "ps": c["ps"],
                           "tiers": {t: {k: (round(v, 3) if isinstance(v, float) else v)
                                         for k, v in info_by_tier[t].items()}
                                     for t in TIER_ORDER}}
        if (n + 1) % 100 == 0:
            print("  ... %d/%d 城（%.0fs）" % (n + 1, len(order), time.time() - t0))
    print("[v2] 管线完成 %.1fs" % (time.time() - t0))

    # ---- 几何落盘（npz：环拼接 + 元数据索引；世界坐标 float32）----
    # start/count 是 rings 的「点索引」区间（不是环序号！曾误用环计数当 start，
    # 读端按点切片导致全部环内容错位——预览图直读 results 不受影响，npz 独错）
    rings_all, meta_all, ids, cinfos = [], [], [], []
    n_pts = 0
    for ci, c in enumerate(order):
        ids.append(c["sid"])
        cinfos.append([c["wx"], c["wy"], c["level"], c["ps"]])
        for ti, tier in enumerate(TIER_ORDER):
            for oi, (outer, holes) in enumerate(results[c["sid"]]["polys"][tier]):
                for kind, ring in ((0, outer),) + tuple((1, h) for h in holes):
                    ring_arr = np.asarray(ring, np.float32)
                    meta_all.append([ci, ti, kind, oi, n_pts, len(ring_arr)])
                    rings_all.append(ring_arr)
                    n_pts += len(ring_arr)
    np.savez_compressed(
        os.path.join(BLOB_V2_DIR, "blob_v2_geoms.npz"),
        rings=np.concatenate(rings_all) if rings_all else np.zeros((0, 2), np.float32),
        ring_meta=np.asarray(meta_all, np.int32).reshape(-1, 6),
        city_ids=np.asarray(ids),
        city_info=np.asarray(cinfos, np.float32))
    print("[v2] %d 环 → blob_v2_geoms.npz" % len(meta_all))

    with open(os.path.join(BLOB_V2_DIR, "stats.json"), "w", encoding="utf-8") as f:
        json.dump(stats, f, ensure_ascii=False, indent=1)
    empties = sum(1 for c in order if not results[c["sid"]]["polys"]["mid"])
    n_holes = sum(r["info"][t].get("n_holes", 0) for r in results.values() for t in TIER_ORDER)
    print("[v2] mid 档无建成区 %d / %d 城；三档累计洞 %d 个" % (empties, len(order), n_holes))

    # ---- 预览 ----
    print("[v2] 预览渲染 ...")
    if terrain_img is not None:
        render_closeup(ctx, picks, results, p)
        render_barren(ctx, barren, results, p)
        if not no_overview or sample_only:
            render_overview(ctx, order, results)

    # ---- D_b 盒计数自检（3 样本城 mid 档最终轮廓，合理带 1.2~1.5）----
    print("[v2] 盒计数 D_b 自检 ...")
    eps_list = p["preview"]["fractal_eps"]
    db_rows, masks, report = [], [], {}
    for c in fractal_picks:
        polys = results[c["sid"]]["polys"]["mid"]
        db = box_counting_dim_pts(polys_boundary_pts(polys), eps_list)
        report[c["sid"]] = db
        if db is not None:
            pts = polys_boundary_pts(polys)
            ns = [int(len(np.unique(np.floor(pts / e).astype(np.int64), axis=0)))
                  for e in eps_list]
            db_rows.append((c["sid"], ns, db))
            outlines = [np.asarray(r) for outer, holes in polys for r in [outer] + list(holes)]
            masks.append((c["sid"], outlines))
        print("  %s lv%d ps%.2f  D_b = %s（合理带 1.2~1.5）"
              % (c["sid"], c["level"], c["ps"], ("%.3f" % db) if db else "N/A(太小)"))
    with open(os.path.join(BLOB_V2_DIR, "fractal_report.json"), "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=1)
    if db_rows:
        render_fractal(db_rows, eps_list, masks)
    print("[v2] 全部完成")


if __name__ == "__main__":
    main()
