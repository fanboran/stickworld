"""城市 blob 容量烘焙（总体设计 §5.7 / C2）

每城 16 方向地形容量预计算，运行时零地形数据（纯查表 + 确定性纯函数生成轮廓）：

  capacity(θᵢ) = slope_cap(θᵢ) × water_cap(θᵢ) × jitter(θᵢ)
    slope_cap = clamp(1 − max_slope(θᵢ)/SLOPE_REF, 0, 1)   沿射线（base 半径起）最大梯度
    water_cap = 遇海 0 / 遇河湖 0.15 / 无水 1（首个命中即定，截断后续扫描）
    jitter    = 0.6 + 0.4 × hash01(settlement_id, i)（DJB2，跨语言确定）

产出（就地 patch，改 JSON 后必须重跑 l_world_bake.gd 刷 bin）：
  1. l1_world.json（出生）+ l1_packs 69 份：settlement 加 blob_capacity[16]；
     population_score 缺失时按 l3_city 同城值回填（l3_city label ↔ settlement_city_N）
  2. l3_city.json：tiles 加 blob_capacity[16] + anchor[x,y]（世界坐标锚点，
     与 L1 position_px+world_origin 同源——centroid 是地块质心，与聚落锚点差数十 px）
  3. l2_packs 13 份：加 cities 数组（该地区城市：id/pos(context 局部 [y,x])/level/
     population_score/blob_capacity）；城市→地区 = l3_city group(老 L1) → pack
     tiles[].global_l1_label，世界→context 原点 = info.json bbox_8192 − tiles_offset

烘焙中心 = L1 position_px + world_origin（L1 主视图锚点精确对齐地形）。

预览（--preview）：全图 T3 blob 叠加 + 代表城特写（s=0.2/0.5/0.9 三档轮廓，
验收「凹凸特征一致 / 各方向增量不均 / 朝山朝水被卡住」）。轮廓公式与运行时
settlement_blob.gd 逐位同源（DJB2 相位 + 同参数表），预览即游戏内形状。
"""

import json
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # tools/worldgen
OUTPUT_DIR = os.path.join(HERE, "output")
GAME_DIR = os.path.normpath(os.path.join(
    HERE, "..", "..", "stick-world", "config", "strategic_map"))
PARAMS_PATH = os.path.join(GAME_DIR, "blob_params.json")


def djb2(s: str) -> int:
    """跨语言确定哈希（GDScript settlement_blob.gd 同实现——base 相位两端逐位一致）"""
    h = 5381
    for c in s.encode("utf-8"):
        h = ((h * 33) + c) & 0xFFFFFFFF
    return h


def hash01(seed_str: str) -> float:
    return (djb2(seed_str) & 0xFFFF) / 65535.0


def load_params() -> dict:
    with open(PARAMS_PATH, encoding="utf-8") as f:
        return json.load(f)


# ==================== 轮廓模型（与 settlement_blob.gd 同公式） ====================

def base_radii(settlement_id: str, level: int, params: dict) -> list:
    """base(θᵢ) = R_lv × (1 + Σ aₙ·sin(n·θᵢ + φₙ))；φₙ 由 settlement_id DJB2 派生"""
    lv = params["levels"][str(level)]
    r_base = float(lv["base"])
    ns, amps = params["harmonics"]["n"], params["harmonics"]["amp"]
    k = int(params["K"])
    seed = djb2(settlement_id)
    phases = []
    for j in range(len(ns)):
        # 每谐波独立相位：seed 与谐波序号混合（golden ratio 扰动）
        phases.append(math.tau * ((seed ^ (j * 0x9E3779B1)) & 0xFFFF) / 65535.0)
    radii = []
    for i in range(k):
        theta = math.tau * i / k
        r = 1.0
        for j in range(len(ns)):
            r += amps[j] * math.sin(ns[j] * theta + phases[j])
        radii.append(r_base * r)
    return radii


def growth(level: int, s: float, params: dict) -> float:
    """g(s) = G_MAX × s^γ（s=population_score ∈ [0,1]）"""
    lv = params["levels"][str(level)]
    return float(lv["g_max"]) * (max(s, 0.0) ** float(params["gamma"]))


def direction_radii(settlement_id: str, level: int, capacity, s: float, params: dict) -> list:
    """r(θᵢ) = base(θᵢ) + capacity(θᵢ) × g(s)（16 方向半径）"""
    g = growth(level, s, params)
    bases = base_radii(settlement_id, level, params)
    return [bases[i] + capacity[i] * g for i in range(len(bases))]


def blob_outline(settlement_id: str, level: int, capacity, s: float, params: dict) -> list:
    """16 方向半径 → 周期 Catmull-Rom 插值 → 闭合折线（以 (0,0) 为中心）"""
    radii = direction_radii(settlement_id, level, capacity, s, params)
    k = len(radii)
    n_out = int(params["sample_points"])
    pts = []
    for m in range(n_out):
        theta = math.tau * m / n_out
        t = theta / math.tau * k          # 连续方向索引
        i = int(t) % k
        f = t - math.floor(t)
        p0, p1 = radii[(i - 1) % k], radii[i]
        p2, p3 = radii[(i + 1) % k], radii[(i + 2) % k]
        # Catmull-Rom 标量插值
        r = 0.5 * ((2.0 * p1)
                   + (-p0 + p2) * f
                   + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * f * f
                   + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * f * f * f)
        pts.append((r * math.cos(theta), r * math.sin(theta)))
    return pts


# ==================== 烘焙 ====================

def bake_all():
    params = load_params()
    k = int(params["K"])
    slope_ref = float(params["slope_ref"])
    probe_r = int(params["probe_radius"])
    step = int(params["probe_step"])
    water_river = float(params["water_cap"]["river_lake"])
    water_sea = float(params["water_cap"]["sea"])
    jit_base = float(params["jitter"]["base"])
    jit_amp = float(params["jitter"]["amp"])

    print("[blob] 加载高度场/水体/大陆掩码 ...")
    height = np.load(os.path.join(OUTPUT_DIR, "fractal_heightmap_8192.npy")).astype(np.float32)
    hgy, hgx = np.gradient(height)                    # 每像素梯度（y/x 向）
    grad_mag = np.sqrt(hgx * hgx + hgy * hgy)
    river = np.array(Image.open(os.path.join(OUTPUT_DIR, "fractal_river_mask_8192.png")).convert("L")) > 127
    lake = np.array(Image.open(os.path.join(OUTPUT_DIR, "fractal_lake_mask_8192.png")).convert("L")) > 127
    land = np.array(Image.open(os.path.join(OUTPUT_DIR, "locked", "locked_continent_8192.png")).convert("L")) > 127
    water_rl = river | lake
    size = height.shape[0]
    print("  高度场 %dx%d，梯度 p50/p90/p99 = %.5f / %.5f / %.5f"
          % (size, size, *np.percentile(grad_mag[land], [50, 90, 99])))

    # ---- 收集城市世界锚点（L1 position_px + world_origin）----
    print("[blob] 收集城市锚点（L1 视图包）...")
    l1_paths = [os.path.join(GAME_DIR, "l1_world.json")]
    pack_dir = os.path.join(GAME_DIR, "l1_packs")
    l1_paths += [os.path.join(pack_dir, d, "l1_world.json")
                 for d in sorted(os.listdir(pack_dir))
                 if os.path.exists(os.path.join(pack_dir, d, "l1_world.json"))]
    anchors = {}      # settlement_id -> {"wx","wy","level","world"}
    for jp in l1_paths:
        world = json.load(open(jp, encoding="utf-8"))
        worg = world.get("world_origin", None)
        if not worg:
            print("  !! %s 无 world_origin，跳过" % os.path.relpath(jp, GAME_DIR))
            continue
        for t in world.get("tiles", []):
            s = t.get("settlement")
            if not s:
                continue
            px = s["position_px"]
            anchors[s["settlement_id"]] = {
                "wx": float(px[0]) + float(worg[0]),
                "wy": float(px[1]) + float(worg[1]),
                "level": int(s.get("level", 1)),
            }
    print("  %d 城锚点" % len(anchors))

    # ---- 16 方向射线容量 ----
    print("[blob] 烘焙 16 方向容量（probe %d px / step %d）..." % (probe_r, step))
    caps = {}         # settlement_id -> [16]
    stats = {"sea_dir": 0, "water_dir": 0, "slope_zero_dir": 0, "total_dir": 0}
    for sid, a in anchors.items():
        cx, cy = a["wx"], a["wy"]
        lv_cfg = params["levels"][str(a["level"])]
        lv_base, lv_gmax = float(lv_cfg["base"]), float(lv_cfg["g_max"])
        # 探测段 = 该级生长段（base → base+g_max）：capacity 度量生长增量的阻挡，
        # 不扫远端无关地形（否则远处河海被误算成阻挡，容量普遍虚低）
        r_start = max(int(lv_base), 4)
        r_end = min(int(lv_base + lv_gmax) + 2, probe_r)
        out = []
        for i in range(k):
            theta = math.tau * i / k
            dx, dy = math.cos(theta), math.sin(theta)
            max_g = 0.0
            water = 1.0
            for r in range(r_start, r_end, step):
                x = int(round(cx + dx * r))
                y = int(round(cy + dy * r))
                if x < 1 or y < 1 or x >= size - 1 or y >= size - 1:
                    water = water_sea           # 出图 = 视为海
                    break
                if not land[y, x]:
                    water = water_sea
                    stats["sea_dir"] += 1
                    break
                if water_rl[y, x]:
                    water = water_river
                    stats["water_dir"] += 1
                    break
                g = float(grad_mag[y, x])
                if g > max_g:
                    max_g = g
            slope_cap = max(0.0, min(1.0, 1.0 - max_g / slope_ref))
            if slope_cap <= 0.0:
                stats["slope_zero_dir"] += 1
            jitter = jit_base + jit_amp * hash01("%s#%d" % (sid, i))
            out.append(round(slope_cap * water * jitter, 4))
            stats["total_dir"] += 1
        caps[sid] = out
    allv = [v for c in caps.values() for v in c]
    print("  完：capacity 均值 %.3f / p10 %.3f / p90 %.3f；遇海方向 %d / 遇河湖 %d / 坡卡死 %d（共 %d）"
          % (float(np.mean(allv)), float(np.percentile(allv, 10)), float(np.percentile(allv, 90)),
             stats["sea_dir"], stats["water_dir"], stats["slope_zero_dir"], stats["total_dir"]))

    # ---- l3_city 索引（population_score / group）----
    l3_path = os.path.join(GAME_DIR, "l3_city.json")
    l3 = json.load(open(l3_path, encoding="utf-8"))
    l3_by_label = {t["label"]: t for t in l3["tiles"]}

    # ---- 回写 L1（出生 + 69 包）----
    print("[blob] 回写 L1 视图包 ...")
    n_fill = 0
    for jp in l1_paths:
        world = json.load(open(jp, encoding="utf-8"))
        dirty = False
        for t in world.get("tiles", []):
            s = t.get("settlement")
            if not s:
                continue
            sid = s["settlement_id"]
            if sid not in caps:
                continue
            s["blob_capacity"] = caps[sid]
            dirty = True
            # population_score 回填/统一（l3_city 同城值；带校验：级别带错位时保留原值）
            lab = int(sid.rsplit("_", 1)[1])
            ref = l3_by_label.get(lab)
            if ref is not None and ref.get("population_score") is not None:
                if "population_score" not in s or s.get("population_score") is None:
                    s["population_score"] = ref["population_score"]
                    n_fill += 1
                elif abs(float(s["population_score"]) - float(ref["population_score"])) > 1e-9:
                    s["population_score"] = ref["population_score"]   # 统一全大陆分位尺
        if dirty:
            with open(jp, "w", encoding="utf-8") as f:
                json.dump(world, f, ensure_ascii=False, indent=1)
    print("  population_score 回填 %d 处（L1 统一 l3_city 分位尺）" % n_fill)

    # settlement_city_001（三位补零）等原始 id 与 l3 label（int）的映射——禁止自行拼接 id
    label_to_sid = {int(k.rsplit("_", 1)[-1]): k for k in caps}

    # ---- 回写 l3_city（blob_capacity + anchor）----
    print("[blob] 回写 l3_city.json ...")
    for t in l3["tiles"]:
        sid = label_to_sid.get(int(t["label"]))
        if sid is not None:
            t["blob_capacity"] = caps[sid]
            t["anchor"] = [round(anchors[sid]["wx"], 2), round(anchors[sid]["wy"], 2)]
    with open(l3_path, "w", encoding="utf-8") as f:
        json.dump(l3, f, ensure_ascii=False, separators=(",", ":"))   # 原文件紧凑单行，保持纯增量 diff

    # ---- 注入 L2 cities ----
    print("[blob] 注入 L2 cities ...")
    l2_info_dir = os.path.join(OUTPUT_DIR, "l2_packs")
    group_to_sid = {}
    for t in l3["tiles"]:
        group_to_sid.setdefault(int(t["group"]), []).append(t["label"])
    for rid in sorted(os.listdir(os.path.join(GAME_DIR, "l2_packs"))):
        jp = os.path.join(GAME_DIR, "l2_packs", rid, "l2_world.json")
        ip = os.path.join(l2_info_dir, rid, "info.json")
        if not (os.path.exists(jp) and os.path.exists(ip)):
            continue
        world = json.load(open(jp, encoding="utf-8"))
        info = json.load(open(ip, encoding="utf-8"))
        bbox = info["bbox_8192"]
        tx, ty = world["tiles_offset"]
        x0 = int(bbox["x0"]) - int(tx)
        y0 = int(bbox["y0"]) - int(ty)
        cities = []
        for t in world["tiles"]:
            for lab in group_to_sid.get(int(t["global_l1_label"]), []):
                sid = label_to_sid.get(int(lab))
                if sid is None:
                    continue
                a = anchors[sid]
                ref = l3_by_label[lab]
                cities.append({
                    "id": sid,
                    "pos": [round(a["wy"] - y0, 2), round(a["wx"] - x0, 2)],   # [y,x] L2 惯例
                    "level": int(ref["level"]),
                    "population_score": ref["population_score"],
                    "blob_capacity": caps[sid],
                })
        world["cities"] = cities
        with open(jp, "w", encoding="utf-8") as f:
            json.dump(world, f, ensure_ascii=False, separators=(",", ":"))
        print("  %s: %d 城" % (rid, len(cities)))

    print("[blob] 完成。记得重跑 l_world_bake.gd 刷 bin。")
    return params, caps, anchors, l3


# ==================== 预览 ====================

def preview(params, caps, anchors, l3):
    print("[blob] 预览 ...")
    terrain = Image.open(os.path.join(OUTPUT_DIR, "l3_terrain.png")).convert("RGB")
    ts = terrain.size[0]

    # 全图：T3 城 blob（s=population_score）叠加 + 其余城市锚点
    label_to_sid = {int(k.rsplit("_", 1)[-1]): k for k in caps}
    img = terrain.copy()
    dr = ImageDraw.Draw(img, "RGBA")
    scale = ts / 8192.0
    n_blob = 0
    for t in l3["tiles"]:
        sid = label_to_sid.get(int(t["label"]))
        if sid is None or sid not in caps or "anchor" not in t:
            continue
        a = anchors[sid]
        cx, cy = a["wx"] * scale, a["wy"] * scale
        if int(t["level"]) >= 3:
            outline = blob_outline(sid, int(t["level"]), caps[sid],
                                   float(t["population_score"]), params)
            pts = [(cx + p[0] * scale, cy + p[1] * scale) for p in outline]
            dr.polygon(pts, fill=(120, 110, 100, 160), outline=(60, 52, 44, 255))
            n_blob += 1
        else:
            dr.ellipse([cx - 1.5, cy - 1.5, cx + 1.5, cy + 1.5], fill=(230, 225, 215, 200))
    img.save(os.path.join(OUTPUT_DIR, "blob_preview_2048.png"))
    print("  blob_preview_2048.png（%d 个 T3 blob）" % n_blob)

    # 特写：出生城 + 容量差异最大的三城（山城/水城代表），s 三档轮廓叠加
    def cap_span(sid):
        c = caps[sid]
        return max(c) - min(c)
    cands = sorted(caps, key=cap_span, reverse=True)
    spawn_sid = json.load(open(os.path.join(GAME_DIR, "l1_world.json"), encoding="utf-8"))["spawn_settlement_id"]
    picks = [spawn_sid] + cands[:3]

    height = np.load(os.path.join(OUTPUT_DIR, "fractal_heightmap_8192.npy"), mmap_mode="r")
    land = np.array(Image.open(os.path.join(OUTPUT_DIR, "locked", "locked_continent_8192.png")).convert("L")) > 127
    water = (np.array(Image.open(os.path.join(OUTPUT_DIR, "fractal_river_mask_8192.png")).convert("L")) > 127) \
        | (np.array(Image.open(os.path.join(OUTPUT_DIR, "fractal_lake_mask_8192.png")).convert("L")) > 127)

    tiles = []
    for sid in picks:
        a = anchors[sid]
        cx, cy = int(a["wx"]), int(a["wy"])
        lv, cap = a["level"], caps[sid]
        # 512² 特写窗（8192 级，起点 clamp），numpy 向量着色：海深蓝/水浅蓝/地灰阶高程
        x0 = min(max(cx - 256, 0), 8192 - 512)
        y0 = min(max(cy - 256, 0), 8192 - 512)
        hwin = np.asarray(height[y0:y0 + 512, x0:x0 + 512], dtype=np.float32)
        g = (140 + 100 * hwin).clip(0, 255).astype(np.uint8)
        rgb = np.stack([g, (g - 10).clip(0, 255), (g - 25).clip(0, 255)], axis=-1)
        rgb[~land[y0:y0 + 512, x0:x0 + 512]] = (20, 40, 70)
        rgb[water[y0:y0 + 512, x0:x0 + 512]] = (72, 116, 158)
        tile = Image.fromarray(rgb, "RGB")
        tdr = ImageDraw.Draw(tile, "RGBA")
        lx, ly = cx - x0, cy - y0
        # 三档 s 轮廓（凹凸一致 / 增量不均 / 地形卡向）
        for s, col in ((0.2, (255, 220, 90, 255)), (0.5, (90, 200, 255, 255)), (0.9, (255, 120, 90, 255))):
            outline = blob_outline(sid, lv, cap, s, params)
            pts = [(lx + p[0], ly + p[1]) for p in outline] + [(lx + outline[0][0], ly + outline[0][1])]
            tdr.line(pts, fill=col, width=2)
        # 16 方向 capacity 条（白色辐射条 = 该方向生长容量）
        for i in range(16):
            th = math.tau * i / 16
            r_in, r_out = 40, 40 + 60 * cap[i]
            tdr.line([(lx + r_in * math.cos(th), ly + r_in * math.sin(th)),
                      (lx + r_out * math.cos(th), ly + r_out * math.sin(th))],
                     fill=(255, 255, 255, 180), width=2)
        tiles.append(tile)
    out = Image.new("RGB", (1024, 1024), (10, 10, 10))
    for i, tile in enumerate(tiles):
        out.paste(tile, ((i % 2) * 512, (i // 2) * 512))
    out.save(os.path.join(OUTPUT_DIR, "blob_closeup.png"))
    print("  blob_closeup.png（%s 等 4 城，黄 s=0.2 / 青 s=0.5 / 红 s=0.9）" % spawn_sid)


if __name__ == "__main__":
    result = bake_all()
    preview(*result)
