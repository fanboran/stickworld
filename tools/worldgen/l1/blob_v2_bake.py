# -*- coding: utf-8 -*-
"""R5 运行时接入：建成区三档贴图烘焙进 L1 包（观感返工 §R5 / §7.1-4 卫星感分层）

对 70 份 L1 包（出生 1 + 批量 69）各产出：
  blob_low.png / blob_mid.png / blob_high.png   三档透明叠加贴图（context_size，1:1 坐标）
  blob_v2_geo.bin                                压缩几何（环顶点，运行时单城刷新/流动描边用）

贴图结构（严格嵌套 high ⊂ mid ⊂ low → 逐层叠加渲染）：
  low  = 全量城的 low 档形状（底）
  mid  = 烘焙档 ≥mid 的城（ps ≥ 0.35）的 mid 档形状（盖 low）
  high = 烘焙档 ≥high 的城（ps ≥ 0.65）的 high 档形状（盖 mid）
  叠加后每城显示其烘焙档形状；运行时档位判定（扰动后分数 0.35/0.65 分界，与
  blob_v2_generate.render_overview 概览口径一致）与烘焙档的偏差由单城小贴图修正。
  贫瘠城（该档无环）自然缺席。

卫星感填充（§7.1-4 分层清单）：
  1. 底色 = l1_terrain.png 城锚环带均值 → 脱饱和暖灰化（周边群系色派生）
  2. 城内 fBm 明暗（blob_v2_generate 同款 value noise，观感同源）
  3. 屋顶噪点 = 网格 jitter 撒矩形（密度 ∝ ps、随距锚点衰减、长边对齐主路方位）
  4. 隐约路网线 = 主路方位 ±90° 正交线，10-20% 透明度，clip 进形状
  5. 边缘裸土晕圈（mask 膨胀环，浅土色）+ 1px 暗描边

几何 bin（blob_v2_geo.bin）= [u32 LE 原始长度][zlib(json)]；json 环顶点为相对
聚落锚点（settlement.position_px）的局部坐标（×10 取整量化）。运行时用于：
初始档位对账叠加 / settlement_updated 单城重判档 / R2 当前城 mid 档流动描边。

用法：
  python blob_v2_bake.py                 # 全部 70 包
  python blob_v2_bake.py --pack l1_001   # 指定包
  python blob_v2_bake.py --spawn-only    # 只跑出生包（调参快速预览）
  python blob_v2_bake.py --no-preview    # 跳过运行时预览拼图
"""

import argparse
import json
import math
import os
import sys
import time

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage as ndi

HERE = os.path.dirname(os.path.abspath(__file__))
OUTPUT_DIR = os.path.normpath(os.path.join(HERE, "..", "output"))
BLOB_V2_DIR = os.path.join(OUTPUT_DIR, "blob_v2")
GAME_DIR = os.path.normpath(os.path.join(HERE, "..", "..", "..", "stick-world", "config", "strategic_map"))
PARAMS_PATH = os.path.join(HERE, "blob_v2_params.json")
NPZ_PATH = os.path.join(BLOB_V2_DIR, "blob_v2_geoms.npz")

TIERS = ["low", "mid", "high"]
GEO_FILE = "blob_v2_geo.bin"
TIER_FILES = {"low": "blob_low.png", "mid": "blob_mid.png", "high": "blob_high.png"}

# 运行时档位分界（与 blob_v2_generate.render_overview 概览口径一致；GDScript 端
# SettlementBlob.TIER_THRESHOLDS 同值，改边界两端同步）
TIER_THRESHOLDS = [0.35, 0.65]

# bake 段缺省（blob_v2_params.json "bake" 可覆写）
BAKE_DEFAULTS = {
    "ss": 2,                    # 形状/内容超采样倍数（边缘 AA）
    "desat": 0.62,              # 底色脱饱和（向亮度收敛比例）
    "warm_shift": [8, 3, -6],   # 暖灰化 RGB 偏移
    "value_noise_amp": 0.06,    # 城内明暗 fBm 幅度（±）
    "value_noise_wl": [42.0, 13.0],
    "roof_grid": 4.2,           # 屋顶噪点网格步长（1x px）
    "roof_size": [1.0, 3.0],    # 屋顶矩形短/长边（1x px）
    "roof_density": 0.8,        # 密度系数（×ps×距离衰减）
    "roof_align_deg": 25.0,     # 长边相对主路方位角抖动半角
    "gridline_gap": [9.0, 16.0],
    "gridline_alpha": 0.13,     # 隐约路网线透明度（10-20%）
    "halo_px": 3,               # 裸土晕圈宽
    "halo_alpha": 0.40,
    "halo_bright": 1.16,        # 晕圈提亮
    "edge_alpha": 0.55,         # 1px 暗描边
    "preview_win": 700,         # 运行时预览三联单幅宽
    "closeup_win": 512,
}


def djb2(s: str) -> int:
    h = 5381
    for c in s.encode("utf-8"):
        h = ((h * 33) + c) & 0xFFFFFFFF
    return h


def _hash01(ix, iy, seed):
    """整数网格 hash → [0,1]（blob_v2_generate 同实现，跨机器确定）"""
    h = np.asarray(ix, np.int64) * 374761393 + np.asarray(iy, np.int64) * 668265263 + np.int64(seed)
    h = (h ^ (h >> np.int64(13))) * np.int64(1274126177)
    h = h ^ (h >> np.int64(16))
    return (h & np.int64(0x7FFFFFFF)).astype(np.float32) / float(0x7FFFFFFF)


def _value_noise(X, Y, wavelength, seed):
    """单倍频 value noise（blob_v2_generate 同实现）"""
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


# ==================== 输入 ====================

def list_packs():
    """全部 L1 包：[(目录, 标签), ...]。出生包 = config 根单份，批量 = l1_packs/l1_XXX。"""
    packs = [(os.path.join(GAME_DIR), "spawn(l1_069)")]
    packs_dir = os.path.join(GAME_DIR, "l1_packs")
    for name in sorted(os.listdir(packs_dir)):
        if os.path.isfile(os.path.join(packs_dir, name, "l1_world.json")):
            packs.append((os.path.join(packs_dir, name), name))
    return packs


def load_geoms():
    z = np.load(NPZ_PATH, allow_pickle=True)
    rings = z["rings"]
    meta = z["ring_meta"]          # [city_idx, tier_idx, kind(0=outer,1=hole), ordinal, start, count]
    ids = [str(s) for s in z["city_ids"]]
    info = z["city_info"]          # [wx, wy, level, ps]（世界 8192 / 烘焙基准 ps）
    geoms = {}
    for ci, sid in enumerate(ids):
        geoms[sid] = {"level": int(info[ci, 2]), "ps": float(info[ci, 3]),
                      "tiers": {t: [] for t in TIERS}}
    for ci, ti, kind, _ord, start, count in meta:
        ring = rings[start:start + count]
        rec = geoms[ids[ci]]
        tier = TIERS[ti]
        if kind == 0:
            rec["tiers"][tier].append({"o": ring, "h": []})
        elif rec["tiers"][tier]:
            rec["tiers"][tier][-1]["h"].append(ring)
    return geoms


def bake_tier_of(ps: float) -> int:
    """烘焙档资格（ps = 烘焙基准分，未扰动）——0/1/2 = low/mid/high"""
    return 0 if ps < TIER_THRESHOLDS[0] else (1 if ps < TIER_THRESHOLDS[1] else 2)


def pack_settlements(world):
    """包内城清单：[{sid, level, ps, px, py}]（px/py = context 局部锚点）"""
    out = []
    for t in world.get("tiles", []):
        s = t.get("settlement")
        if not s:
            continue
        out.append({
            "sid": s["settlement_id"],
            "level": int(s.get("level", 1)),
            "ps": float(s.get("population_score") or 0.0),
            "px": float(s["position_px"][0]),
            "py": float(s["position_px"][1]),
        })
    return out


def city_road_azimuth(world, sid):
    """主路方位角（城端出城方向弧度；PAVED 优先；无路 None → 用形状主轴）"""
    best = None
    for r in world.get("roads", []):
        if r.get("from") != sid and r.get("to") != sid:
            continue
        poly = r.get("polyline") or []
        if len(poly) < 2:
            continue
        fwd = r.get("from") == sid          # 城端在前？
        pts = poly[:4] if fwd else poly[-4:][::-1]
        a = np.asarray(pts[0], np.float64)
        b = np.asarray(pts[-1], np.float64)
        d = b - a
        ln = math.hypot(d[0], d[1])
        if ln < 1e-6:
            continue
        az = math.atan2(d[1], d[0])
        if best is None or (r.get("tier") == "PAVED" and not best[1]):
            best = (az, r.get("tier") == "PAVED")
    return best[0] if best else None


# ==================== 卫星感填充 ====================

def derive_base_color(terrain_img, ax, ay, r_in, r_out, bake_p):
    """底色 = 地形底图锚点环带均值 → 脱饱和暖灰化（周边群系色派生，§7.1-4.1）"""
    W, H = terrain_img.size
    x0, x1 = max(0, int(ax - r_out)), min(W, int(ax + r_out) + 1)
    y0, y1 = max(0, int(ay - r_out)), min(H, int(ay + r_out) + 1)
    rgb = np.zeros(3, np.float32)
    if x1 > x0 and y1 > y0:
        win = np.asarray(terrain_img.crop((x0, y0, x1, y1)), np.float32)
        yy, xx = np.mgrid[y0:y1, x0:x1]
        d = np.sqrt((xx - ax) ** 2 + (yy - ay) ** 2)
        band = (d >= r_in) & (d <= r_out)
        if band.sum() >= 16:
            rgb = win[band].mean(axis=0)
    g = float(rgb.mean())
    rgb = rgb * (1.0 - bake_p["desat"]) + g * bake_p["desat"]
    rgb = rgb + np.asarray(bake_p["warm_shift"], np.float32)
    return np.clip(rgb, 24.0, 246.0)


def fill_city_layer(canvas, mask, holes_mask, ax, ay, r_ref, azimuth, seed,
                    base_rgb, bake_p, ps):
    """在 ss 超采样小画布上铺单档卫星感内容（底色/fBm/路网线/屋顶点），乘形状 mask。

    canvas: float32 (h*ss, w*ss, 4)；mask/holes_mask: bool（ss 尺度）
    坐标：ax/ay 为小画布内锚点（ss 尺度）；r_ref 为 1x 尺度参考半径。
    """
    ss = int(bake_p["ss"])
    H, W = mask.shape
    ys, xs = np.mgrid[0:H, 0:W].astype(np.float32)

    # 1. 底色 + 城内 fBm 明暗（value noise 2 八度，blob_v2_generate 同源公式）
    amp = float(bake_p["value_noise_amp"])
    shade = np.zeros((H, W), np.float32)
    wl_all = [float(w) for w in bake_p["value_noise_wl"]]
    amps, tot, a = [], 0.0, 1.0
    for _ in wl_all:
        amps.append(a)
        tot += a
        a *= 0.5
    for i, wl in enumerate(wl_all):
        shade += amps[i] * (_value_noise(xs / ss, ys / ss, wl, seed + i * 101) * 2.0 - 1.0)
    shade /= max(tot, 1e-6)
    lum = 1.0 + amp * shade
    rgb = base_rgb[None, None, :] * lum[..., None]

    # 2. 隐约路网线（主路方位 & +90° 正交，§7.1-4.3）——画在独立层再乘 mask
    az = azimuth if azimuth is not None else 0.0
    line_layer = np.zeros((H, W, 4), np.float32)
    line_rgb = base_rgb * 0.78
    alpha = float(bake_p["gridline_alpha"])
    for azk in (az, az + math.pi / 2.0):
        gap = float(bake_p["gridline_gap"][0] if azk == az else bake_p["gridline_gap"][1]) * ss
        dx, dy = math.cos(azk), math.sin(azk)
        nx, ny = -dy, dx
        off0 = ((xs - ax) * nx + (ys - ay) * ny)
        k = np.floor(off0 / max(gap, 3.0))
        frac = np.abs(off0 - (k + 0.5) * gap)          # 距格线距离（px, ss）
        on_line = frac <= 0.6 * ss
        line_layer[on_line, 0] = line_rgb[0]
        line_layer[on_line, 1] = line_rgb[1]
        line_layer[on_line, 2] = line_rgb[2]
        line_layer[on_line, 3] = 255.0 * alpha
    # 线层 alpha 合成进 rgb（简化 over）
    la = line_layer[..., 3:4] / 255.0
    rgb = rgb * (1.0 - la) + line_layer[..., :3] * la

    # 3. 屋顶噪点（§7.1-4.2）：网格 jitter 撒矩形，密度 ∝ ps、随距锚衰减、长边对齐主路方位
    grid = float(bake_p["roof_grid"]) * ss
    gx0, gy0 = int(xs.min() / grid), int(ys.min() / grid)
    gx1, gy1 = int(xs.max() / grid) + 1, int(ys.max() / grid) + 1
    l_px, l_long = float(bake_p["roof_size"][0]), float(bake_p["roof_size"][1])
    dens = float(bake_p["roof_density"])
    rng = np.random.RandomState(seed & 0x7FFFFFFF)
    n_try = max((gx1 - gx0) * (gy1 - gy0), 1)
    gxs = rng.randint(gx0, max(gx0 + 1, gx1), size=n_try)
    gys = rng.randint(gy0, max(gy0 + 1, gy1), size=n_try)
    jx = (gxs + 0.5) * grid + (rng.rand(n_try) - 0.5) * grid * 0.9
    jy = (gys + 0.5) * grid + (rng.rand(n_try) - 0.5) * grid * 0.9
    keep = rng.rand(n_try)
    dist = np.sqrt((jx - ax) ** 2 + (jy - ay) ** 2)
    p_keep = dens * (0.35 + 0.65 * ps) * np.clip(1.2 - 1.1 * dist / (1.5 * r_ref * ss), 0.05, 1.0)
    sel = keep < p_keep
    rgb4 = np.clip(rgb, 0, 255).astype(np.uint8)
    img = Image.fromarray(np.dstack([rgb4, np.full((H, W), 255, np.uint8)]), "RGBA")
    dr = ImageDraw.Draw(img, "RGBA")
    half_min = max(0.6 * ss, 0.5 * l_px * ss)
    for x, y in zip(jx[sel], jy[sel]):
        xi, yi = float(x), float(y)   # 窗口系坐标（mgrid 原点 = 窗口原点）
        if xi < 1 or yi < 1 or xi >= W - 1 or yi >= H - 1:
            continue
        # 形状内才画（mask 已排除洞）
        ix, iy = int(xi), int(yi)
        if not mask[iy, ix]:
            continue
        ang = az + (rng.rand() - 0.5) * 2.0 * math.radians(bake_p["roof_align_deg"])
        L = l_long * ss * (0.7 + 0.6 * rng.rand())
        S = max(half_min, l_px * ss * (0.7 + 0.6 * rng.rand()))
        ca, sa = math.cos(ang), math.sin(ang)
        hx, hy = (ca * L * 0.5), (sa * L * 0.5)
        px_, py_ = (-sa * S * 0.5), (ca * S * 0.5)
        jitter = 0.86 + 0.28 * rng.rand()
        col = tuple(int(min(255, v * jitter)) for v in base_rgb) + (255,)
        dr.polygon([(xi - hx - px_, yi - hy - py_), (xi + hx - px_, yi + hy - py_),
                    (xi + hx + px_, yi + hy + py_), (xi - hx + px_, yi - hy + py_)], fill=col)
    # 重建为 float 并裁进形状（洞内置 0）
    out = np.asarray(img, np.float32)
    out[holes_mask] = 0.0
    out[~mask] = 0.0
    canvas[:] = out


def bake_city_tier(tier_canvas, rings, ax, ay, r_ref, azimuth, seed, base_rgb,
                   bake_p, ps):
    """单城单档：形状 mask → 卫星感内容 → 晕圈/描边 → alpha 合成进档位画布。

    rings: [{"o": (N,2) 相对锚点局部坐标, "h": [(M,2), ...]}, ...]
    ax/ay: 城锚 context 局部坐标；tier_canvas: PIL RGBA（context_size）
    """
    ss = int(bake_p["ss"])
    halo = int(bake_p["halo_px"])
    # 相对锚点 bbox → 画布窗（含晕圈余量；环/锚点分离传参，窗原点相对锚点 = x0）
    all_pts = [r["o"] for r in rings] + [h for r in rings for h in r["h"]]
    cat = np.concatenate(all_pts, axis=0)
    margin = (halo + 4) * ss
    x0 = int(cat[:, 0].min()) - margin
    x1 = int(cat[:, 0].max()) + margin
    y0 = int(cat[:, 1].min()) - margin
    y1 = int(cat[:, 1].max()) + margin
    win_w, win_h = x1 - x0, y1 - y0
    if win_w <= 0 or win_h <= 0 or win_w * win_h > 40_000_000:
        return
    # ss 尺度 mask（环点 ×ss）
    msk = Image.new("L", (win_w * ss, win_h * ss), 0)
    d = ImageDraw.Draw(msk)
    for r in rings:
        pts = [((p[0] - x0) * ss, (p[1] - y0) * ss) for p in r["o"]]
        if len(pts) >= 3:
            d.polygon(pts, fill=255)
    mask = np.asarray(msk, np.bool_)
    # 洞（even-odd：洞区置 0）
    if any(r["h"] for r in rings):
        hm = Image.new("L", msk.size, 0)
        dh = ImageDraw.Draw(hm)
        for r in rings:
            for h in r["h"]:
                pts = [((p[0] - x0) * ss, (p[1] - y0) * ss) for p in h]
                if len(pts) >= 3:
                    dh.polygon(pts, fill=255)
        holes_mask = np.asarray(hm, np.bool_) & mask
    else:
        holes_mask = np.zeros_like(mask)
    mask &= ~holes_mask

    # 锚点在窗口系 = (0,0) - 窗原点(x0,y0)（环是相对锚点坐标）
    ax_s = (0 - x0) * ss
    ay_s = (0 - y0) * ss
    canvas = np.zeros((mask.shape[0], mask.shape[1], 4), np.float32)

    # 晕圈（裸土，先铺在底层）：膨胀区 - 形状
    struct = ndi.generate_binary_structure(2, 2)
    dil = ndi.binary_dilation(mask, structure=struct, iterations=halo * ss)
    halo_band = dil & ~mask
    halo_rgb = np.clip(base_rgb * float(bake_p["halo_bright"])
                       + np.array([6.0, 4.0, -2.0], np.float32), 0, 255)
    canvas[halo_band, 0] = halo_rgb[0]
    canvas[halo_band, 1] = halo_rgb[1]
    canvas[halo_band, 2] = halo_rgb[2]
    canvas[halo_band, 3] = 255.0 * float(bake_p["halo_alpha"])

    # 卫星感主体（底色/fBm/路网线/屋顶点）
    fill_city_layer(canvas, mask, holes_mask, ax_s, ay_s, r_ref, azimuth, seed,
                    base_rgb, bake_p, ps)

    # 1px 暗描边（mask 内缘环）
    inner = mask & ~ndi.binary_erosion(mask, structure=struct)
    canvas[inner, 0] = canvas[inner, 0] * 0.42
    canvas[inner, 1] = canvas[inner, 1] * 0.40
    canvas[inner, 2] = canvas[inner, 2] * 0.40
    canvas[inner, 3] = 255.0

    # 回 1x 并合成进档位画布（窗口可能越 context 边界 → 裁剪）
    layer = Image.fromarray(np.clip(canvas, 0, 255).astype(np.uint8), "RGBA")
    if ss > 1:
        layer = layer.resize((win_w, win_h), Image.LANCZOS)
    # 窗口贴回 context（dx/dy 可为负 → 裁剪；坐标全 int 化，PIL paste 不收 float）
    dx = int(round(x0 + ax))
    dy = int(round(y0 + ay))
    sx = max(0, -dx)
    sy = max(0, -dy)
    ddx = max(0, dx)
    ddy = max(0, dy)
    cw = min(win_w - sx, tier_canvas.size[0] - ddx)
    ch = min(win_h - sy, tier_canvas.size[1] - ddy)
    if cw <= 0 or ch <= 0:
        return
    tier_canvas.alpha_composite(layer.crop((sx, sy, sx + cw, sy + ch)), (ddx, ddy))


# ==================== 几何 bin ====================

def quant_ring(ring):
    """(N,2) float → 扁平量化列表（×10 取整，相对锚点局部坐标）"""
    q = np.round(np.asarray(ring, np.float64) * 10.0).astype(np.int64)
    return [int(v) for v in q.ravel()]


def build_geo_doc(cities, geoms, rel_by_sid):
    """geo bin 的 json 结构：sid → {bt, r:[3][poly]}，poly={"o":..., "h":[...]}
    （相对锚点局部坐标 ×10 量化；锚点 = settlement.position_px，运行时已知）"""
    cities_out = {}
    for c in cities:
        rel = rel_by_sid.get(c["sid"])
        if rel is None:
            continue
        tiers_out = []
        for t in TIERS:
            polys = []
            for p in rel[t]:
                polys.append({"o": quant_ring(p["o"]),
                              "h": [quant_ring(h) for h in p["h"]]})
            tiers_out.append(polys)
        cities_out[c["sid"]] = {"bt": bake_tier_of(geoms[c["sid"]]["ps"]), "r": tiers_out}
    return {"v": 1, "q": 10, "cities": cities_out}


def write_geo_bin(path, doc):
    """[u32 LE 原始长度][gzip(json)]（mtime=0 确定性；Godot 端
    PackedByteArray.decompress(len, FileAccess.COMPRESSION_GZIP) 读）"""
    import gzip
    raw = json.dumps(doc, separators=(",", ":")).encode("utf-8")
    with open(path, "wb") as f:
        f.write(len(raw).to_bytes(4, "little"))
        f.write(gzip.compress(raw, 9, mtime=0))


# ==================== 单包烘焙 ====================

def bake_pack(pack_dir, geoms, lv_bands, gamma, bake_p, terrain_img):
    with open(os.path.join(pack_dir, "l1_world.json"), encoding="utf-8") as f:
        world = json.load(f)
    wo = world.get("world_origin")
    csz = world.get("context_size")
    if not wo or not csz:
        print("  !! 缺 world_origin/context_size，跳过: %s" % pack_dir, flush=True)
        return False
    W, H = int(csz[0]), int(csz[1])
    cities = pack_settlements(world)
    az_by_sid = {c["sid"]: city_road_azimuth(world, c["sid"]) for c in cities}

    canvases = {t: Image.new("RGBA", (W, H), (0, 0, 0, 0)) for t in TIERS}
    n_draw = 0
    rel_by_sid = {}
    ox, oy = float(wo[0]), float(wo[1])
    for c in cities:
        g = geoms.get(c["sid"])
        if g is None:
            continue
        # npz 环 = 世界 8192 坐标 → 减 (world_origin + 锚点 context 局部) = 相对锚点
        # （geo bin 与运行时同系；锚点 = settlement.position_px）
        base_off = np.array([ox + c["px"], oy + c["py"]])
        rel = {}
        for t in TIERS:
            rel[t] = [{"o": np.asarray(p["o"], np.float64) - base_off,
                       "h": [np.asarray(h, np.float64) - base_off for h in p["h"]]}
                      for p in g["tiers"][t]]
        rel_by_sid[c["sid"]] = rel
        bt = bake_tier_of(g["ps"])
        az = az_by_sid.get(c["sid"])
        for ti, t in enumerate(TIERS):
            if ti > bt or not rel[t]:
                continue
            s_lvl = {"low": 0.18, "mid": 0.5, "high": 0.82}[t]
            band = lv_bands.get(g["level"], (30.0, 30.0))
            rr = band[0] + band[1] * (s_lvl ** gamma)
            # 底色采样环带随档（low 小、high 大）
            base = derive_base_color(terrain_img, c["px"], c["py"],
                                     max(10.0, rr * 0.9), rr * 1.7, bake_p)
            seed = djb2(c["sid"]) + ti * 7919
            bake_city_tier(canvases[t], rel[t], c["px"], c["py"], rr, az,
                           seed, base, bake_p, g["ps"])
            n_draw += 1
    for t in TIERS:
        canvases[t].save(os.path.join(pack_dir, TIER_FILES[t]))
    doc = build_geo_doc(cities, geoms, rel_by_sid)
    write_geo_bin(os.path.join(pack_dir, GEO_FILE), doc)
    total = sum(os.path.getsize(os.path.join(pack_dir, TIER_FILES[t])) for t in TIERS)
    print("  %s: %d 城绘制 %d 档层，3 贴图 %.2f MB + geo %.0f KB"
          % (os.path.basename(pack_dir) or "spawn", len(doc["cities"]), n_draw,
             total / 1048576, os.path.getsize(os.path.join(pack_dir, GEO_FILE)) / 1024),
          flush=True)
    return True


# ==================== 运行时预览 ====================

def render_runtime_preview(pack_dir, bake_p, win):
    """同一 L1 地块三档位并排（terrain + 对应档贴图叠加）——切档差异与卫星感验收"""
    with open(os.path.join(pack_dir, "l1_world.json"), encoding="utf-8") as f:
        world = json.load(f)
    csz = world.get("context_size")
    W, H = int(csz[0]), int(csz[1])
    base = Image.open(os.path.join(pack_dir, "l1_terrain.png")).convert("RGBA")
    tiles = []
    for t in TIERS:
        frame = base.copy()
        bp = os.path.join(pack_dir, TIER_FILES[t])
        if os.path.isfile(bp):
            frame.alpha_composite(Image.open(bp).convert("RGBA"))
        k = win / max(W, H)
        tiles.append(frame.resize((int(W * k), int(H * k)), Image.LANCZOS))
    out = Image.new("RGB", (sum(t.size[0] for t in tiles) + 8 * (len(tiles) - 1),
                            max(t.size[1] for t in tiles)), (12, 12, 12))
    x = 0
    for i, t in enumerate(tiles):
        out.paste(t.convert("RGB"), (x, 0))
        ImageDraw.Draw(out).text((x + 6, 4), "%s tier" % TIERS[i].upper(), fill=(255, 220, 90))
        x += t.size[0] + 8
    path = os.path.join(BLOB_V2_DIR, "..", "blob_v2_runtime_lowmidhigh.png")
    out.save(os.path.normpath(path))
    print("  %s" % os.path.basename(path), flush=True)


def render_closeup(pack_dir, bake_p, win):
    """出生包城锚特写三档（2x 放大，看填充纹理）"""
    with open(os.path.join(pack_dir, "l1_world.json"), encoding="utf-8") as f:
        world = json.load(f)
    cities = pack_settlements(world)
    if not cities:
        return
    cities.sort(key=lambda c: -c["ps"])
    c = cities[0]
    ax, ay = c["px"], c["py"]
    base = Image.open(os.path.join(pack_dir, "l1_terrain.png")).convert("RGBA")
    tiles = []
    for t in TIERS:
        frame = base.copy()
        bp = os.path.join(pack_dir, TIER_FILES[t])
        if os.path.isfile(bp):
            frame.alpha_composite(Image.open(bp).convert("RGBA"))
        x0, y0 = int(max(0, ax - win / 2)), int(max(0, ay - win / 2))
        crop = frame.crop((x0, y0, min(frame.size[0], x0 + win), min(frame.size[1], y0 + win)))
        tiles.append(crop)
    out = Image.new("RGB", (win * len(tiles) + 8 * (len(tiles) - 1), win), (12, 12, 12))
    x = 0
    for i, tl in enumerate(tiles):
        out.paste(tl.convert("RGB"), (x, 0))
        ImageDraw.Draw(out).text((x + 6, 4), "%s tier" % TIERS[i].upper(), fill=(255, 220, 90))
        x += win + 8
    path = os.path.normpath(os.path.join(BLOB_V2_DIR, "..", "blob_v2_runtime_closeup.png"))
    out.save(path)
    print("  %s（%s 特写）" % (os.path.basename(path), c["sid"]), flush=True)


# ==================== 主流程 ====================

def pick_preview_pack(packs, geoms):
    """预览包 = ps 最大的城所在包（保证三档差异可见——出生包城 ps 全 <0.65 无 high 档）"""
    best_sid, best_ps = None, -1.0
    for sid, g in geoms.items():
        if g["ps"] > best_ps:
            best_ps, best_sid = g["ps"], sid
    for d, _n in packs:
        try:
            with open(os.path.join(d, "l1_world.json"), encoding="utf-8") as f:
                world = json.load(f)
        except OSError:
            continue
        for t in world.get("tiles", []):
            s = t.get("settlement")
            if s and s["settlement_id"] == best_sid:
                return d
    return packs[0][0]


def main():
    ap = argparse.ArgumentParser(description="R5 建成区三档贴图 + 几何 bin 烘焙进 L1 包")
    ap.add_argument("--pack", nargs="*", help="只处理指定包（如 l1_001；spawn = 出生包）")
    ap.add_argument("--spawn-only", action="store_true")
    ap.add_argument("--no-preview", action="store_true")
    args = ap.parse_args()

    t0 = time.time()
    with open(PARAMS_PATH, encoding="utf-8") as f:
        params = json.load(f)
    bake_p = dict(BAKE_DEFAULTS)
    bake_p.update(params.get("bake") or {})
    with open(os.path.join(GAME_DIR, "blob_params.json"), encoding="utf-8") as f:
        old = json.load(f)
    lv_bands = {int(k): (float(v["base"]), float(v["g_max"])) for k, v in old["levels"].items()}
    gamma = float(params.get("area", {}).get("gamma", 0.7))

    print("[bake] 载入 blob_v2 几何 ...", flush=True)
    geoms = load_geoms()
    print("  %d 城 × 3 档" % len(geoms), flush=True)

    packs = list_packs()
    if args.pack:
        want = set(args.pack)
        packs = [(d, n) for d, n in packs if n in want or (n.startswith("spawn") and "spawn" in want)]
    elif args.spawn_only:
        packs = packs[:1]

    ok = 0
    for d, n in packs:
        terr = os.path.join(d, "l1_terrain.png")
        if not os.path.isfile(terr):
            print("  !! 缺 l1_terrain.png，跳过: %s" % n, flush=True)
            continue
        terrain_img = Image.open(terr).convert("RGB")
        if bake_pack(d, geoms, lv_bands, gamma, bake_p, terrain_img):
            ok += 1
    if not args.no_preview and ok > 0:
        print("[bake] 运行时预览 ...", flush=True)
        prev_pack = pick_preview_pack(packs, geoms)
        render_runtime_preview(prev_pack, bake_p, int(bake_p["preview_win"]))
        render_closeup(prev_pack, bake_p, int(bake_p["closeup_win"]))
    print("完成 %d/%d 包，总耗时 %.1fs" % (ok, len(packs), time.time() - t0), flush=True)
    if ok < len(packs):
        sys.exit(1)


if __name__ == "__main__":
    main()
