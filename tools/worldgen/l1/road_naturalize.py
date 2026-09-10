"""R6 道路自然化后处理 —— 现役 1107 条折线就地加工（不重搜路，不动游戏包）。

§R6（世界地图观感返工-诉求与方案）生成端：现役折线（DP+Chaikin 产出）太圆滑无地形感，
本工具做「路径自然化后处理」（§7.2-1 直接答案）：
  1. 等弧长重采样（步长 ≈ 路宽×0.5-1，路宽按 tier 现行渲染口径）
  2. 法向噪声位移：value-noise 按【世界坐标】采样（同位置同值，共线段/路口不穿帮），
     低频双八度（80-200px 波长）大摆动 + 高频（20-40px）细碎；
     幅度按等级衰减（土路 5px / 官道 2.5px）×坡度大段衰减 ×端点 fade
  3. 位移后仅一次窗口=3 滑动平均（禁样条平滑）
  4. 陡坡段（行进方向与等高线夹角>60°）锐折角锚点：0 位移、不参与平均（标记「不可圆滑」）
  5. tier 保持不变（流量重分级暂缓）
确定性：噪声 seed = DJB2(道路id)（blob 两端同源先例），同一路重跑逐位一致。

输入：70 份 L1 包 roads[].polyline（context 局部坐标，+world_origin=世界 8192）；
      高度场 fractal_heightmap_8192.npy（坡度采样）。
输出（全部进 tools/worldgen/output/，不写游戏包）：
  - road_v2/roads_v2_global.json  自然化后全量折线（世界坐标）+ 锐折角锚点索引
  - road_v2/metrics.json          自检指标（长度变化率/端点位移/路口趋同/确定性）
  - road_v2_closeup_plains.png    特写三图（新旧并排，casing 双层渲染模拟最终观感）
  - road_v2_closeup_mountain.png    出生平原路 / 山地穿行路 / 跨河路
  - road_v2_closeup_river.png
  - road_v2_overview.png          全大陆路网自然化前后概览

用法：
  python road_naturalize.py                    # 全量 + 指标 + 预览
  python road_naturalize.py --verify           # 全量跑两遍，逐位对比自证确定性
  python road_naturalize.py --only 69          # 只处理出生 L1 相关边（调参循环）
  python road_naturalize.py --no-preview       # 只算折线与指标
  Python 须用完整路径（PATH 首位 python 无 numpy 完整版）
"""
import argparse
import json
import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # tools/worldgen
OUT_DIR = os.path.join(HERE, "output")
V2_DIR = os.path.join(OUT_DIR, "road_v2")
GAME_DIR = os.path.normpath(os.path.join(
    HERE, "..", "..", "stick-world", "config", "strategic_map"))
PARAMS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "road_naturalize_params.json")

RES = 8192
FONT_CANDIDATES = ["C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/simhei.ttf"]


# ---------------------------------------------------------------- 基础件

def djb2(s):
    """跨语言确定哈希（blob_bake.py / settlement_blob.gd 同实现，两端同源先例）。"""
    h = 5381
    for c in s.encode("utf-8"):
        h = ((h * 33) + c) & 0xFFFFFFFF
    return h


def load_params():
    with open(PARAMS_PATH, encoding="utf-8") as f:
        raw = json.load(f)
    return {k: v for k, v in raw.items() if not k.startswith("_")}


def smoothstep(t):
    t = np.clip(t, 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def polyline_len(pts):
    """折线长度（np 数组或嵌套 list）。"""
    p = np.asarray(pts, np.float64)
    return float(np.hypot(*(p[1:] - p[:-1]).T).sum())


def detour_stats(pts):
    ax, ay = pts[0]
    bx, by = pts[-1]
    seg = math.hypot(bx - ax, by - ay)
    if seg < 1e-6:
        return 1.0
    p = np.asarray(pts, np.float64)
    return polyline_len(p) / seg


def load_font(size):
    for fp in FONT_CANDIDATES:
        if os.path.exists(fp):
            try:
                return ImageFont.truetype(fp, size)
            except OSError:
                break
    return ImageFont.load_default()


# ---------------------------------------------------------------- 噪声（世界坐标 value-noise）

def value_noise(seed, lam, x, y, gain=1.0):
    """世界网格对齐的 2D value-noise ∈ [-1,1]×gain。

    格点落在世界坐标的 λ 整数倍位置：噪声是 (x, y, seed) 的场函数——
    不同路/同路不同段在同一世界位置采样到同一值（共线段/路口两侧一致不穿帮）。
    smoothstep 双线性插值；seed 与波长共同决定 rng（同路各频段独立、跨跑确定）。
    """
    lam = float(lam)
    fx = np.asarray(x, np.float64) / lam
    fy = np.asarray(y, np.float64) / lam
    ix = np.floor(fx)
    iy = np.floor(fy)
    gx0 = int(ix.min()) - 1
    gx1 = int(ix.max()) + 2
    gy0 = int(iy.min()) - 1
    gy1 = int(iy.max()) + 2
    rng = np.random.default_rng([int(seed) & 0x7FFFFFFF, int(lam)])
    g = rng.random((gy1 - gy0 + 1, gx1 - gx0 + 1))
    tx = (ix - gx0).astype(np.int64)
    ty = (iy - gy0).astype(np.int64)
    dx = fx - ix
    dy = fy - iy
    sx = dx * dx * (3.0 - 2.0 * dx)
    sy = dy * dy * (3.0 - 2.0 * dy)
    v = (g[ty, tx] * (1 - sx) + g[ty, tx + 1] * sx) * (1 - sy) \
        + (g[ty + 1, tx] * (1 - sx) + g[ty + 1, tx + 1] * sx) * sy
    return (v - 0.5) * 2.0 * gain


# ---------------------------------------------------------------- 折线加工

def resample_by_arclength(pts, step):
    """等弧长重采样：首尾点强制保留（聚落锚精确），内部按 step 均匀取点。"""
    p = np.asarray(pts, np.float64)
    d = np.hypot(*(p[1:] - p[:-1]).T)
    cum = np.concatenate([[0.0], np.cumsum(d)])
    total = float(cum[-1])
    if total <= step:
        return p
    n = max(int(math.floor(total / step)), 1)
    targets = np.linspace(0.0, total, n + 1)
    # 首尾吸附 0 与 total（linspace 端点本就是 0/total，浮点误差防护）
    targets[0], targets[-1] = 0.0, total
    idx = np.clip(np.searchsorted(cum, targets, side="right") - 1, 0, len(d) - 1)
    t = (targets - cum[idx]) / np.maximum(d[idx], 1e-12)
    out = p[idx] + (p[idx + 1] - p[idx]) * t[:, None]
    out[0], out[-1] = p[0], p[-1]
    return out


def naturalize(pts_w, tier, road_id, p, terrain):
    """单路自然化。返回 (new_pts or None, sharp_idx, info)。

    None = 保持原样（无折线/直线渡线/过短）。sharp_idx = 锐折角锚点索引（不可圆滑）。
    """
    info = {}
    src = np.asarray(pts_w, np.float64)
    if len(src) <= 2:   # 直线回退路（群岛无陆路渡线）：位移会画出海域假路，保持原样
        return None, [], {"skipped": "straight_fallback"}
    width = float(p["width_px"].get(tier, p["width_px"]["DIRT"]))
    step = width * float(p["step_mult"])
    q = resample_by_arclength(src, step)
    if len(q) < 5:
        return None, [], {"skipped": "too_short"}
    n = len(q)

    # 切向/法向（中心差分，端点单侧）
    t = np.gradient(q, axis=0)
    tlen = np.maximum(np.hypot(t[:, 0], t[:, 1]), 1e-12)
    tx, ty = t[:, 0] / tlen, t[:, 1] / tlen
    nx, ny = -ty, tx

    # 地形：坡度 + 梯度单位向量（窗口读高度场）
    pad = 4
    x0, y0 = q[:, 0].min() - pad, q[:, 1].min() - pad
    x1, y1 = q[:, 0].max() + pad, q[:, 1].max() + pad
    win = terrain.slope_window(x0, y0, x1, y1)
    slope, gxn, gyn = terrain.sample_grad(win, q[:, 0], q[:, 1])
    slope, gxn, gyn = np.asarray(slope), np.asarray(gxn), np.asarray(gyn)
    gnorm = np.maximum(np.hypot(gxn, gyn), 1e-9)
    dgx, dgy = gxn / gnorm, gyn / gnorm
    info["slope_mean"] = float(slope.mean())
    info["slope_p95"] = float(np.percentile(slope, 95))

    # 锐折角锚点：坡度超门槛 且 行进方向与等高线夹角>angle（=与梯度夹角<90-angle）
    ang = math.radians(float(p["sharp"]["angle_deg"]))
    sharp = (slope > float(p["sharp"]["slope_min"])) & \
            (np.abs(tx * dgx + ty * dgy) > math.cos(math.pi / 2 - ang))

    # 噪声位移标量：低频双八度 + 高频×ratio
    seed = djb2(road_id)
    lams = p["low_wavelengths_px"]
    wts = p["low_weights"]
    low = sum(w * value_noise(seed, lm, q[:, 0], q[:, 1])
              for w, lm in zip(wts, lams)) / sum(wts)
    high = value_noise(seed, p["high_wavelength_px"], q[:, 0], q[:, 1])
    disp = low + high * float(p["high_ratio"])

    # 坡度衰减（线性 start→full 过渡到 mult）
    ss = p["slope_soften"]
    k = np.clip((slope - float(ss["start"])) /
                max(float(ss["full"]) - float(ss["start"]), 1e-9), 0.0, 1.0)
    sm = 1.0 + (float(ss["mult"]) - 1.0) * k

    # 端点 fade（弧长两端 0→1 smoothstep）：聚落锚 0 位移，路口两侧趋同
    seg = np.hypot(*(q[1:] - q[:-1]).T)
    arc = np.concatenate([[0.0], np.cumsum(seg)])
    total = float(arc[-1])
    fade = float(p["endpoint_fade_px"])
    f = np.minimum(smoothstep(arc / fade), smoothstep((total - arc) / fade))

    amp = float(p["amp_px"].get(tier, p["amp_px"]["DIRT"])) * float(p["noise_gain"])
    # 超短路衰减：路长摆不开高频波长时，位移只会推高弧长不出弯（衰减到 floor 保底）
    srs = p.get("short_road_scale", {})
    if srs:
        scale = float(np.clip(total / (float(srs.get("ref_mult", 4.0)) *
                                       float(p["high_wavelength_px"])),
                              float(srs.get("floor", 0.3)), 1.0))
        amp *= scale
    # 零均值化（对 disp 在乘 fade 之前）：低频在短路带内常整段同号（=整体平移而非
    # 弯曲，端点锚定后变弓/抄近）；按弧长权重去 DC，位移只剩「弯」的成分且端点渐变不变
    wgt = np.maximum(f, 1e-6)
    disp = disp - float(np.average(disp, weights=wgt))
    off = disp * amp * sm * f
    off[sharp] = 0.0
    info["off_max"] = float(np.abs(off).max())
    info["off_at_ends_px"] = float(np.abs(off[:3]).max())   # 端点附近位移（趋同/锚定验证用）

    qd = q.copy()
    qd[:, 0] += nx * off
    qd[:, 1] += ny * off

    # 仅一次窗口=3 滑动平均（端点 + 锐折角锚点固定）
    w = int(p["smooth_window"])
    half = w // 2
    out = qd.copy()
    if half >= 1 and n >= w:
        kernel = np.ones(w) / w
        for c in (0, 1):
            smooth = np.convolve(qd[:, c], kernel, mode="valid")
            mid = slice(half, half + len(smooth))
            keep = np.ones(n, bool)
            keep[mid] = sharp[mid]   # 锚点保持不平均
            sc = qd[:, c].copy()
            sc[mid] = np.where(keep[mid], sc[mid], smooth)
            out[:, c] = sc
    out[0], out[-1] = q[0], q[-1]   # 端点精确锚定

    sharp_idx = [int(i) for i in np.where(sharp)[0]]
    return out, sharp_idx, info


# ---------------------------------------------------------------- 数据装载

def pack_files():
    files = [os.path.join(GAME_DIR, "l1_world.json")]
    pdir = os.path.join(GAME_DIR, "l1_packs")
    files += [os.path.join(pdir, d, "l1_world.json")
              for d in sorted(os.listdir(pdir)) if d.startswith("l1_")]
    return files


def load_all(p, only=None):
    """70 份包 → 全局边集（道路 id 去重，世界坐标折线）+ 城市表。

    返回 (edges, cities)：edges 为 list（稳定顺序），cities[sid] = {pos, level, label}。
    """
    cities = {}
    edges = {}
    n_dup = 0
    n_bad = 0
    for fp in pack_files():
        with open(fp, encoding="utf-8") as f:
            w = json.load(f)
        label = int(w["parent_l1_label"])
        wo = w.get("world_origin", [0, 0])
        for t in w["tiles"]:
            s = t.get("settlement")
            if not s:
                continue
            cities[s["settlement_id"]] = {
                "pos": (float(s["position_px"][0]) + wo[0],
                        float(s["position_px"][1]) + wo[1]),
                "level": int(s.get("level", 1)),
                "label": label,
            }
        for rd in w["roads"]:
            key = tuple(sorted((rd["from"], rd["to"])))
            if only is not None and not (
                    cities.get(rd["from"], {}).get("label") == only or
                    cities.get(rd["to"], {}).get("label") == only):
                continue
            e = edges.get(key)
            if e is not None:
                n_dup += 1
                e["packs"].add(os.path.basename(os.path.dirname(fp)))
                if "polyline" in rd and "polyline" in e:
                    a = np.asarray(e["polyline"], np.float64)
                    b = np.asarray(
                        [[px + wo[0], py + wo[1]] for px, py in rd["polyline"]],
                        np.float64)
                    if len(a) == len(b) and float(np.hypot(*(a - b).T).max()) > 0.5:
                        n_bad += 1
                        print("  ⚠ 跨包折线不一致 %s（%s vs %s），取先见"
                              % (key, sorted(e["packs"])[0],
                                 os.path.basename(os.path.dirname(fp))))
                continue
            pl = rd.get("polyline")
            edges[key] = {
                "id": "|".join(key),
                "from": rd["from"], "to": rd["to"],
                "tier": rd.get("tier"),
                "polyline": [[px + wo[0], py + wo[1]] for px, py in pl] if pl else None,
                "packs": {os.path.basename(os.path.dirname(fp))},
            }
    if n_bad:
        print("  ⚠ 跨包折线不一致 %d 处（已取先见，写回接线时需复核）" % n_bad)
    order = sorted(edges.values(), key=lambda e: e["id"])
    print("  边 %d 条（跨包重复记录 %d，无 polyline %d，城市 %d）"
          % (len(order), n_dup,
             sum(1 for e in order if e["polyline"] is None), len(cities)))
    return order, cities


# ---------------------------------------------------------------- 高度场/掩码缓存

class Terrain:
    """高度场 mmap 窗口采样 + 大陆/河/湖掩码（惰性全图 np）。"""

    def __init__(self):
        self.hm = np.load(os.path.join(OUT_DIR, "fractal_heightmap_8192.npy"),
                          mmap_mode="r")
        self._cont = None
        self._river = None
        self._lake = None

    def _mask(self, name):
        if getattr(self, "_" + name) is None:
            fn = {"cont": os.path.join("locked", "locked_continent_8192.png"),
                  "river": "fractal_river_mask_8192.png",
                  "lake": "fractal_lake_mask_8192.png"}[name]
            self.__dict__["_" + name] = np.array(
                Image.open(os.path.join(OUT_DIR, fn)).convert("L"))
        return self.__dict__["_" + name]

    def slope_window(self, x0, y0, x1, y1):
        """世界 bbox → 梯度窗口（超 2048 自动 4x 块均值降采样，控内存）。"""
        pad = 3
        X0 = max(0, int(x0) - pad)
        Y0 = max(0, int(y0) - pad)
        X1 = min(RES, int(x1) + pad + 1)
        Y1 = min(RES, int(y1) + pad + 1)
        block = 4 if (X1 - X0 > 2048 or Y1 - Y0 > 2048) else 1
        raw = np.asarray(self.hm[Y0:Y1, X0:X1], np.float32)
        if block > 1:
            h, wd = raw.shape
            raw = raw[:h // block * block, :wd // block * block] \
                .reshape(h // block, block, wd // block, block).mean(axis=(1, 3))
        gy, gx = np.gradient(raw)
        if block > 1:
            gx, gy = gx / block, gy / block
        return {"X0": X0, "Y0": Y0, "block": block, "gx": gx, "gy": gy}

    def sample_grad(self, win, xs, ys):
        """窗口内双线性最近邻采样 → (slope, gx, gy)。"""
        block = win["block"]
        ix = np.clip(((np.asarray(xs) - win["X0"]) / block).round().astype(np.int64),
                     0, win["gx"].shape[1] - 1)
        iy = np.clip(((np.asarray(ys) - win["Y0"]) / block).round().astype(np.int64),
                     0, win["gx"].shape[0] - 1)
        gxn = win["gx"][iy, ix]
        gyn = win["gy"][iy, ix]
        return np.hypot(gxn, gyn), gxn, gyn

    def height_at(self, xs, ys):
        idx = np.clip(np.round(np.asarray(xs)).astype(np.int64), 0, RES - 1)
        idy = np.clip(np.round(np.asarray(ys)).astype(np.int64), 0, RES - 1)
        return np.asarray(self.hm[idy, idx], np.float32)

    def mask_hits(self, name, xs, ys, thr=127):
        m = self._mask(name)
        idx = np.clip(np.round(np.asarray(xs)).astype(np.int64), 0, RES - 1)
        idy = np.clip(np.round(np.asarray(ys)).astype(np.int64), 0, RES - 1)
        return m[idy, idx] > thr

    def mask_window(self, name, x0, y0, x1, y1, thr=127):
        m = self._mask(name)
        X0, Y0 = max(0, int(x0)), max(0, int(y0))
        X1, Y1 = min(RES, int(x1)), min(RES, int(y1))
        return m[Y0:Y1, X0:X1] > thr


# ---------------------------------------------------------------- 全量处理 + 指标

def run_naturalize(edges, p, terrain, tag=""):
    """全量边自然化。返回处理结果 list（与 edges 同序）。"""
    results = []
    n_skip = 0
    for e in edges:
        if e["polyline"] is None:
            results.append({**e, "new": None, "sharp": [], "info": {"skipped": "no_polyline"}})
            n_skip += 1
            continue
        out, sharp, info = naturalize(e["polyline"], e["tier"], e["id"], p, terrain)
        results.append({**e, "new": out, "sharp": sharp, "info": info})
        if out is None:
            n_skip += 1
    print("  [%s] 处理 %d 条，保持原样 %d 条（无折线/直线渡线/过短）"
          % (tag, len(results) - n_skip, n_skip))
    return results


def compute_metrics(edges, results, p):
    """自检指标：长度变化率 / 端点位移 / 路口趋同 / 锐折角统计。"""
    grows = []
    skipped = 0
    end_disp_max = 0.0
    off_ends = []
    n_sharp = 0
    sharp_by_tier = {"DIRT": 0, "PAVED": 0}
    for e, r in zip(edges, results):
        if r["new"] is None:
            skipped += 1
            continue
        lo = polyline_len(e["polyline"])
        ln = polyline_len(r["new"])
        grows.append((ln - lo) / max(lo, 1e-9))
        end_disp_max = max(
            end_disp_max,
            float(np.hypot(*(np.asarray(r["new"][[0, -1]]) -
                             np.asarray(e["polyline"])[[0, -1]]).T).max()))
        off_ends.append(r["info"].get("off_at_ends_px", 0.0))
        n_sharp += len(r["sharp"])
        if e["tier"] in sharp_by_tier:
            sharp_by_tier[e["tier"]] += len(r["sharp"])

    # 路口趋同：共享端点的路组，端点必须全部 0 位移（构造保证，逐组断言）
    by_sid = {}
    for e, r in zip(edges, results):
        for sid in (e["from"], e["to"]):
            by_sid.setdefault(sid, []).append((e, r))
    n_junction = 0
    junc_bad = 0
    for sid, group in by_sid.items():
        if len(group) < 2:
            continue
        n_junction += 1
        for e, r in group:
            if r["new"] is None:
                continue
            ep_old = np.asarray(e["polyline"])[0 if sid == e["from"] else -1]
            ep_new = np.asarray(r["new"])[0 if sid == e["from"] else -1]
            if float(np.hypot(*(ep_new - ep_old))) > 0.0:
                junc_bad += 1

    g = np.array(grows) if grows else np.array([0.0])
    over = p["max_len_growth"]
    m = {
        "n_total": len(results),
        "n_processed": len(grows),
        "n_kept_as_is": skipped,
        "len_growth": {
            "p50": float(np.percentile(g, 50)),
            "p90": float(np.percentile(g, 90)),
            "p99": float(np.percentile(g, 99)),
            "max": float(g.max()),
            "min": float(g.min()),
            "n_over_threshold": int((np.abs(g) > over).sum()),
            "threshold": over,
        },
        "endpoint_displacement_max": end_disp_max,
        "junctions": {"n_shared_endpoints": n_junction, "n_bad": junc_bad},
        "endpoint_offset_within_fade_max": float(max(off_ends)) if off_ends else 0.0,
        "sharp_anchors": {"n_total": n_sharp, "by_tier": sharp_by_tier},
    }
    return m


def print_metrics(m):
    g = m["len_growth"]
    print("  长度变化率 p50/p90/p99/max = %+.2f%% / %+.2f%% / %+.2f%% / %+.2f%%"
          % (g["p50"] * 100, g["p90"] * 100, g["p99"] * 100, g["max"] * 100))
    print("  超阈值(|Δ|>%.0f%%) %d 条；端点位移 max = %.4f px（要求 0）；"
          "端点 fade 内位移 max = %.3f px"
          % (g["threshold"] * 100, g["n_over_threshold"],
             m["endpoint_displacement_max"], m["endpoint_offset_within_fade_max"]))
    print("  共享端点路口 %d 个（坏 %d）；锐折角锚点 %d 个（DIRT %d / PAVED %d）"
          % (m["junctions"]["n_shared_endpoints"], m["junctions"]["n_bad"],
             m["sharp_anchors"]["n_total"], m["sharp_anchors"]["by_tier"]["DIRT"],
             m["sharp_anchors"]["by_tier"]["PAVED"]))
    ok = (m["endpoint_displacement_max"] == 0.0 and m["junctions"]["n_bad"] == 0
          and g["n_over_threshold"] == 0)
    print("  自检：%s" % ("PASS" if ok else "⚠ 存在超阈值项，见上"))


# ---------------------------------------------------------------- 渲染（预览专用，不入游戏包）

def _shade_terrain(h, land, river=None, lake=None):
    """高度/掩码窗口 → (RGB uint8 底图, hillshade float 0-1)。

    灰褐地形 + 海洋 + 河湖；光照左上（l=normalize(-0.7,-0.7,0.9)）。
    """
    gy, gx = np.gradient(h.astype(np.float32))
    norm = np.sqrt(gx * gx + gy * gy + 1.0)
    shade = np.clip((-gx * 0.7 - gy * 0.7 + 0.9) / (norm * 1.323), 0.35, 1.35)
    hh = np.clip(h.astype(np.float32), 0.0, 1.0)
    base_lo = np.array([146.0, 128.0, 96.0])
    base_hi = np.array([198.0, 178.0, 134.0])
    t = np.clip(hh * 1.25, 0, 1)[..., None]
    rgb = (base_lo * (1 - t) + base_hi * t) * shade[..., None]
    sea_t = np.clip((-hh) / 0.12, 0, 1)[..., None]
    sea_lo = np.array([38.0, 66.0, 104.0])
    sea_hi = np.array([16.0, 32.0, 58.0])
    sea = (sea_hi * (1 - sea_t) + sea_lo * sea_t)
    rgb = np.where(land[..., None], rgb, sea)
    if river is not None:
        rgb[river] = (64, 118, 168)
    if lake is not None:
        rgb[lake] = (48, 96, 148)
    return rgb.astype(np.uint8), shade


def _draw_roads(img, roads_pts, x0, y0, k, p, shade_img=None):
    """casing 双层画一组折线（世界坐标→画布）。shade_img 给定时路面乘 hillshade。"""
    r = p["render"]
    dr = ImageDraw.Draw(img)
    face = Image.new("RGBA", img.size, (0, 0, 0, 0))
    df = ImageDraw.Draw(face)
    for tier, pts in roads_pts:
        if pts is None or len(pts) < 2:
            continue
        cw = max(1, round((p["width_px"].get(tier, 2.0) + float(r["case_extra_px"])) * k))
        fw = max(1, round(p["width_px"].get(tier, 2.0) * k))
        pix = [((x - x0) * k, (y - y0) * k) for x, y in pts]
        dr.line(pix, fill=tuple(r["case_color"].get(tier, r["case_color"]["DIRT"])),
                width=cw, joint="curve")
        df.line(pix, fill=tuple(r["face_color"].get(tier, r["face_color"]["DIRT"])) + (255,),
                width=fw, joint="curve")
    if shade_img is not None:
        arr = np.array(face)
        sh = np.asarray(shade_img.resize(img.size, Image.BILINEAR), np.float32) / 255.0
        arr[..., :3] = np.clip(arr[..., :3].astype(np.float32) * sh[..., None], 0, 255)
        face = Image.fromarray(arr)
    img.alpha_composite(face)


def _draw_settlements(dr, cities, x0, y0, k, ss=1.0, in_view=None):
    for sid, c in cities.items():
        x, y = (c["pos"][0] - x0) * k, (c["pos"][1] - y0) * k
        if not (0 <= x < in_view[0] and 0 <= y < in_view[1]):
            continue
        r = {1: 3, 2: 5, 3: 8}.get(c["level"], 3) * ss
        col = {1: (225, 225, 225), 2: (245, 225, 130), 3: (255, 160, 70)}[c["level"]]
        dr.ellipse([x - r, y - r, x + r, y + r], fill=col, outline=(15, 15, 15),
                   width=max(1, int(ss)))


def _window_arrays(terrain, bbox, k):
    """世界 bbox → (放大 k 倍的地形底图数组, hillshade 灰度 PIL, 窗口原点)。

    bbox 须已 clamp 在世界内（调用方保证），画布尺寸 = bbox 尺寸 × k。
    """
    x0, y0, x1, y1 = bbox
    X0, Y0 = max(0, int(x0)), max(0, int(y0))
    X1, Y1 = min(RES, int(x1)), min(RES, int(y1))
    h = np.asarray(terrain.hm[Y0:Y1, X0:X1], np.float32)
    land = terrain.mask_window("cont", X0, Y0, X1, Y1)
    river = terrain.mask_window("river", X0, Y0, X1, Y1)
    lake = terrain.mask_window("lake", X0, Y0, X1, Y1)
    W = int((X1 - X0) * k)
    H = int((Y1 - Y0) * k)
    if W < 2 or H < 2:
        return None, None, X0, Y0
    rgb, shade = _shade_terrain(h, land, river, lake)
    hi = Image.fromarray(rgb).resize((W, H), Image.BILINEAR)
    sh = Image.fromarray((np.clip(shade / 1.35, 0, 1) * 255).astype(np.uint8)) \
        .resize((W, H), Image.BILINEAR)
    return np.array(hi), sh, X0, Y0


def render_closeup_pair(rec_old, rec_new, all_results, cities, terrain, p, path):
    """单路特写：旧（现行圆滑）| 新（自然化）并排，同视野同风格。"""
    r = p["render"]
    ss = int(r["ss"])
    pad = float(r["closeup_pad_px"])
    out_px = int(r["closeup_out_px"])
    src = np.asarray(rec_old["polyline"], np.float64)
    L = polyline_len(src)
    pad = float(np.clip(L * 0.35, 70.0, float(r["closeup_pad_px"])))   # 短路视野收紧
    bx0, by0 = src.min(axis=0) - pad
    bx1, by1 = src.max(axis=0) + pad
    side = max(bx1 - bx0, by1 - by0)
    side = min(side, RES - 10.0)
    cx, cy = (bx0 + bx1) / 2, (by0 + by1) / 2
    # 视野 clamp 在世界内（底图窗口按世界 px 取整，防 clamp 拉伸错位）
    wx0 = float(np.clip(cx - side / 2, 0.0, RES - side))
    wy0 = float(np.clip(cy - side / 2, 0.0, RES - side))
    wx1, wy1 = wx0 + side, wy0 + side
    k = out_px * ss / side

    base, shade_img, ax0, ay0 = _window_arrays(terrain, (wx0, wy0, wx1, wy1), k)
    if base is None:
        print("  ⚠ 特写视野无效，跳过 %s" % rec_old["id"])
        return

    def view_recs(version):
        out = []
        for rec in all_results:
            if rec["polyline"] is None:
                continue
            pts = rec["polyline"] if version == "old" else \
                ([[round(x, 2), round(y, 2)] for x, y in rec["new"]]
                 if rec["new"] is not None else rec["polyline"])
            a = np.asarray(pts, np.float64)
            if a[:, 0].max() < wx0 - 10 or a[:, 0].min() > wx1 + 10 \
                    or a[:, 1].max() < wy0 - 10 or a[:, 1].min() > wy1 + 10:
                continue
            out.append((rec["tier"] or "DIRT", pts))
        return out

    panels = []
    for version in ("old", "new"):
        img = Image.new("RGBA", (out_px * ss, out_px * ss))
        img.paste(Image.fromarray(base).resize((out_px * ss, out_px * ss),
                                               Image.NEAREST), (0, 0))
        _draw_roads(img, view_recs(version), ax0, ay0, k, p, shade_img)
        dr = ImageDraw.Draw(img)
        # NEW 面板：锐折角锚点标记（陡坡直穿点，不可圆滑）
        if version == "new" and rec_new["new"] is not None and rec_new["sharp"]:
            rr = 3.5 * ss
            for i in rec_new["sharp"]:
                x, y = (rec_new["new"][i][0] - ax0) * k, (rec_new["new"][i][1] - ay0) * k
                dr.ellipse([x - rr, y - rr, x + rr, y + rr],
                           outline=(255, 70, 200), width=ss)
        _draw_settlements(dr, cities, ax0, ay0, k, ss=ss, in_view=(img.width, img.height))
        panels.append(img.resize((out_px, out_px), Image.LANCZOS))

    # 拼接 + 标题条
    title_h = 44
    combo = Image.new("RGB", (out_px * 2 + 12, out_px + title_h), (24, 24, 24))
    font = load_font(20)
    dr = ImageDraw.Draw(combo)
    lo = polyline_len(rec_old["polyline"])
    ln = polyline_len(rec_new["new"]) if rec_new["new"] is not None else lo
    label = "%s   %s   len %.0f→%.0f px (%+.1f%%)   sharp anchors %d" % (
        rec_old["id"], rec_old["tier"] or "-", lo, ln, (ln - lo) / lo * 100,
        len(rec_new["sharp"]))
    dr.text((10, 10), label, fill=(230, 230, 230), font=font)
    combo.paste(panels[0].convert("RGB"), (0, title_h))
    combo.paste(panels[1].convert("RGB"), (out_px + 12, title_h))
    for i, txt in enumerate(["OLD  (chaikin-rounded)", "NEW  (naturalized)"]):
        dr.rectangle([i * (out_px + 12), title_h + 6,
                      i * (out_px + 12) + 240, title_h + 30], fill=(0, 0, 0))
        dr.text((i * (out_px + 12) + 8, title_h + 9), txt, fill=(255, 220, 140),
                font=load_font(16))
        if i == 1 and rec_new["sharp"]:
            dr.text((i * (out_px + 12) + 248, title_h + 9),
                    "○ = sharp anchor (no rounding)", fill=(255, 120, 210),
                    font=load_font(16))
    combo.save(path)
    print("  特写 -> %s" % path)


def render_overview(results, cities, terrain, p, path):
    """全大陆概览：旧 | 新 并排（各 2048）。"""
    r = p["render"]
    S = int(r["overview_px"])
    k_full = 0.5   # 4096 画布 / 8192 世界
    ss = 2         # 4096 = 2048 输出 × 2
    hm_small = np.asarray(terrain.hm, np.float32)
    hm_small = hm_small.reshape(4096, 2, 4096, 2).mean(axis=(1, 3))
    land = terrain.mask_window("cont", 0, 0, RES, RES)
    land = land.reshape(4096, 2, 4096, 2).any(axis=(1, 3))
    river = terrain.mask_window("river", 0, 0, RES, RES)
    river = river.reshape(4096, 2, 4096, 2).any(axis=(1, 3))
    lake = terrain.mask_window("lake", 0, 0, RES, RES)
    lake = lake.reshape(4096, 2, 4096, 2).any(axis=(1, 3))
    base = Image.fromarray(_shade_terrain(hm_small, land, river, lake)[0])
    del hm_small, land, river, lake

    def panel(version):
        img = Image.new("RGBA", (4096, 4096))
        img.paste(base.resize((4096, 4096), Image.BILINEAR), (0, 0))
        pts_list = []
        for rec in results:
            pts = rec["polyline"]
            if version == "new" and rec["new"] is not None:
                pts = rec["new"]
            if pts is None or len(pts) < 2:
                continue
            pts_list.append((rec["tier"] or "DIRT", pts))
        _draw_roads(img, pts_list, 0, 0, k_full * ss, p)
        dr = ImageDraw.Draw(img)
        _draw_settlements(dr, cities, 0, 0, k_full * ss, ss=ss * 0.5,
                          in_view=(4096, 4096))
        return img.resize((S, S), Image.LANCZOS).convert("RGB")

    old = panel("old")
    new = panel("new")
    title_h = 40
    combo = Image.new("RGB", (S * 2 + 10, S + title_h), (24, 24, 24))
    dr = ImageDraw.Draw(combo)
    dr.text((10, 10), "road network OLD (chaikin-rounded)", fill=(230, 230, 230),
            font=load_font(20))
    dr.text((S + 20, 10), "road network NEW (naturalized)", fill=(230, 230, 230),
            font=load_font(20))
    combo.paste(old, (0, title_h))
    combo.paste(new, (S + 10, title_h))
    combo.save(path)
    print("  概览 -> %s" % path)


# ---------------------------------------------------------------- 特写选路

def _sample_every(pts, step_px):
    p = np.asarray(pts, np.float64)
    d = np.hypot(*(p[1:] - p[:-1]).T)
    cum = np.concatenate([[0.0], np.cumsum(d)])
    if cum[-1] < 1e-6:
        return p
    targets = np.arange(0.0, cum[-1], step_px)
    idx = np.clip(np.searchsorted(cum, targets, side="right") - 1, 0, len(d) - 1)
    return p[idx]


def _hit_runs(mask):
    """布尔序列的连续段数。"""
    return int(np.diff(np.concatenate([[0], mask.astype(np.int64), [0]])).clip(0).sum())


def choose_showcases(results, cities, terrain, p):
    """自动挑特写样本：出生平原路 / 山地穿行路 / 跨河路。"""
    info_all = []
    for r in results:
        if r["polyline"] is None or r["new"] is None:
            continue
        a = np.asarray(r["polyline"], np.float64)
        bbox = (a[:, 0].max() - a[:, 0].min(), a[:, 1].max() - a[:, 1].min())
        smp = _sample_every(a, 4.0)
        info_all.append({"rec": r, "pts": a, "smp": smp, "bbox": max(bbox),
                         "detour": detour_stats(a), "L": polyline_len(a)})
    plains, mountain, river = None, None, None

    # 平原：出生 L1 内土路，无河湖、地势平、有微弯不呆板
    cands = []
    for it in info_all:
        r = it["rec"]
        if r["tier"] != "DIRT" or it["L"] < 120 or it["L"] > 420 or it["bbox"] > 600:
            continue
        if not all(cities.get(s, {}).get("label") == 69 for s in (r["from"], r["to"])):
            continue
        if terrain.mask_hits("river", it["pts"][:, 0], it["pts"][:, 1]).any() \
                or terrain.mask_hits("lake", it["pts"][:, 0], it["pts"][:, 1]).any():
            continue
        h = terrain.height_at(it["pts"][:, 0], it["pts"][:, 1])
        if float(h.std()) > 0.05:
            continue
        win = terrain.slope_window(a[:, 0].min(), a[:, 1].min(),
                                   a[:, 0].max(), a[:, 1].max())
        sl, _, _ = terrain.sample_grad(win, it["pts"][:, 0], it["pts"][:, 1])
        if float(np.percentile(sl, 95)) > 0.008:
            continue
        cands.append(it)
    if cands:
        cands.sort(key=lambda it: abs(it["detour"] - 1.10))
        plains = cands[len(cands) // 3]

    # 山地穿行：高山环境（路带平均高程高、不沿海）优先，取地形起伏最大的一条——
    # 山里的路本身走缓处（坡度/高差都不大），「山感」来自两侧山体环境
    cands = []
    for it in info_all:
        if it["L"] < 150 or it["bbox"] > 1200:
            continue
        if not terrain.mask_hits("cont", it["smp"][:, 0], it["smp"][:, 1]).all():
            continue
        h = terrain.height_at(it["smp"][:, 0], it["smp"][:, 1])
        if float(h.min()) < 0.05:
            continue
        it["h_mean"], it["hstd"] = float(h.mean()), float(h.std())
        cands.append(it)
    hi = [it for it in cands if it["h_mean"] >= 0.35]
    if hi:
        hi.sort(key=lambda it: -it["hstd"])
        mountain = hi[0]
    else:   # fallback：绕行度中高 + 坡度大（低山丘陵）
        for it in cands:
            it["slope95"] = float(it["rec"]["info"].get("slope_p95", 0.0))
        fb = [it for it in cands if 1.15 <= it["detour"] <= 2.2
              and it["slope95"] >= 0.006]
        if fb:
            fb.sort(key=lambda it: -it["slope95"])
            mountain = fb[0]

    # 跨河：垂直穿越（命中段居中、连续段 1-2、伴行占比低），按穿越宽度取最宽河
    cands = []
    for it in info_all:
        if it["bbox"] > 1400 or it["L"] < 140:
            continue
        if not terrain.mask_hits("cont", it["smp"][:, 0], it["smp"][:, 1]).all():
            continue
        hit = terrain.mask_hits("river", it["smp"][:, 0], it["smp"][:, 1])
        if not hit.any():
            continue
        runs = _hit_runs(hit)
        if not (1 <= runs <= 2) or hit.mean() > 0.35:
            continue
        first = int(np.argmax(hit))
        last = len(hit) - 1 - int(np.argmax(hit[::-1]))
        if first / len(hit) < 0.2 or last / len(hit) > 0.8:
            continue
        it["width"] = float(hit.sum()) / runs * 4.0   # 采样步 4px
        cands.append(it)
    if cands:
        cands.sort(key=lambda it: -it["width"])
        river = cands[0]

    out = {}
    for name, it, how in (("plains", plains, "detour=%.2f"),
                          ("mountain", mountain, "h_mean=%.2f h_std=%.3f"),
                          ("river", river, "river width~%.0fpx")):
        if it is None:
            print("  ⚠ 未找到 %s 特写样本" % name)
            continue
        out[name] = it["rec"]
        arg = (it["width"],) if name == "river" else \
              (it["h_mean"], it["hstd"]) if name == "mountain" else (it["detour"],)
        print("  特写样本 %s：%s [%s] L=%.0f %s"
              % (name, it["rec"]["id"], it["rec"]["tier"], it["L"], how % arg))
    return out


# ---------------------------------------------------------------- 输出

def write_outputs(edges, results, metrics, p):
    os.makedirs(V2_DIR, exist_ok=True)
    roads = []
    for e, r in zip(edges, results):
        rec = {
            "id": e["id"], "from": e["from"], "to": e["to"],
            "tier": e["tier"], "packs": sorted(e["packs"]),
            "length_old": round(polyline_len(e["polyline"]), 1) if e["polyline"] else None,
            "length_new": round(polyline_len(r["new"]), 1) if r["new"] is not None else None,
            "sharp_anchors": r["sharp"],
        }
        if r["new"] is not None:
            rec["polyline"] = [[round(float(x), 2), round(float(y), 2)] for x, y in r["new"]]
        else:
            rec["polyline"] = e["polyline"]
            if r["info"].get("skipped"):
                rec["kept_as_is"] = r["info"]["skipped"]
        roads.append(rec)
    doc = {
        "_注释": "R6 道路自然化产物（road_naturalize.py）。折线=世界坐标 8192"
                 "（局部 = 世界 − 包 world_origin）；sharp_anchors=锐折角锚点索引"
                 "（陡坡直穿点，渲染/写回端不可圆滑）。写回分包与刷 bin 由下一批接线。",
        "coordinate": "[x,y] 8192 全局",
        "params_snapshot": {k: v for k, v in p.items() if k != "render"},
        "metrics": metrics,
        "roads": roads,
    }
    fp = os.path.join(V2_DIR, "roads_v2_global.json")
    with open(fp, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=1)
    print("  折线 -> %s（%d 条）" % (fp, len(roads)))
    fp = os.path.join(V2_DIR, "metrics.json")
    with open(fp, "w", encoding="utf-8") as f:
        json.dump(metrics, f, ensure_ascii=False, indent=1)
    return fp


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description="R6 道路自然化后处理（不重搜路/不写包）")
    ap.add_argument("--only", type=int, default=None,
                    help="只处理端点落在指定老 L1 label 的边（调参循环）")
    ap.add_argument("--verify", action="store_true",
                    help="全量跑两遍逐位对比，自证 seed 确定性")
    ap.add_argument("--no-preview", action="store_true", help="跳过预览渲染")
    args = ap.parse_args()
    p = load_params()
    terrain = Terrain()

    print("[1/5] 装载 70 份 L1 包（全局边去重，世界坐标）...")
    edges, cities = load_all(p, only=args.only)

    print("[2/5] 自然化（重采样→噪声位移→滑动平均，锐折角锚点保留）...")
    results = run_naturalize(edges, p, terrain, "pass1")

    print("[3/5] 自检指标...")
    metrics = compute_metrics(edges, results, p)
    print_metrics(metrics)

    if args.verify:
        print("[3.5] 确定性自证：第二遍全量重算...")
        results2 = run_naturalize(edges, p, terrain, "pass2")
        diff = 0
        for a, b in zip(results, results2):
            if a["new"] is None and b["new"] is None:
                continue
            if (a["new"] is None) != (b["new"] is None) \
                    or a["sharp"] != b["sharp"] \
                    or not np.array_equal(a["new"], b["new"]):
                diff += 1
                if diff <= 3:
                    print("  ✗ 不一致：%s" % a["id"])
        metrics["determinism"] = {"passed": diff == 0, "n_diff": diff}
        print("  确定性：%s（%d/%d 条逐位一致）"
              % ("PASS" if diff == 0 else "FAIL", len(results) - diff, len(results)))

    print("[4/5] 输出 road_v2/ ...")
    write_outputs(edges, results, metrics, p)

    if not args.no_preview:
        print("[5/5] 预览渲染（casing 双层模拟最终观感）...")
        show = choose_showcases(results, cities, terrain, p)
        name_map = {"plains": "road_v2_closeup_plains.png",
                    "mountain": "road_v2_closeup_mountain.png",
                    "river": "road_v2_closeup_river.png"}
        for name, rec in show.items():
            render_closeup_pair(rec, rec, results, cities, terrain, p,
                                os.path.join(OUT_DIR, name_map[name]))
        render_overview(results, cities, terrain, p,
                        os.path.join(OUT_DIR, "road_v2_overview.png"))
    print("完成")


if __name__ == "__main__":
    main()
