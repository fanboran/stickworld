"""政权简化版生成器（总体设计 §5.11，Phase F/P7）

文化圈锚点 = §5.11.1 种族-地域表；国名采用世界观设定 §6.1 王国表（提案名，可改）。

流程（§5.11 五步）：
  1. 文化圈：锚点种子 → 栅格 flood-fill（cost = 距离 + 坡度 + 河流 + 群系加成）
     → culture_labels（边界自然贴合山川河流）
  2. 都城：每文化圈取人口最高的 T3+ 城为都城（大圈多部分裂；出生地区额外加密）
  3. 扩张：城图多源 Dijkstra（cost = 距离 + 文化摩擦 + 地形粗糙 + 贫瘠 + 跨海），
     单国城数硬 cap，遇他国已占即停 → city_owners
  4. 碎度：出生老 L1 的 8 城邦沿用 l1_world.json 既有 states 不动（is_city_state）；
     region_013 其余城碎成小政权（便于初期扩张）
  5. 产出：political_data.json（字段按完整版预留，alliance 留空）
     + 注入 l3_city.json / l2_packs（state_id + states 表）
     + l3_political.png（L3 政治底图 2048）+ l2_political_preview.png ×13
     + output/ 预览两张（政权版图 / 文化圈）供观感验收

用法：
  python state_expand_lite.py [--dry-run] [--skip-preview]
    --dry-run     只跑算法与指标，不写任何 config 文件
    --skip-preview 不输出 output/ 验收预览大图
"""

import argparse
import colorsys
import heapq
import json
import math
import os
import random
from collections import Counter, defaultdict

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy.ndimage import map_coordinates
from skimage.graph import MCP_Geometric

SIZE = 2048
SIZE_FULL = 8192
HERE = os.path.dirname(os.path.abspath(__file__))
OUTPUT_DIR = os.path.join(os.path.dirname(HERE), "output")
GAME_CFG = os.path.normpath(os.path.join(
    HERE, "..", "..", "..", "stick-world", "config", "strategic_map"))
PARAMS_PATH = os.path.join(HERE, "state_params.json")

OCEAN = (30, 55, 95)
# 群系标签（biome_generate.py 同源）
BI_SOURCE, BI_VOLCANIC, BI_DESERT, BI_ICE = 5, 6, 3, 4


def sid_of(label):
    """城 label（int）→ settlement id（P4 惯例：三位补零）"""
    return "settlement_city_%03d" % int(label)


def load_params():
    with open(PARAMS_PATH, encoding="utf-8") as f:
        return json.load(f)


def load_inputs():
    hm = np.load(os.path.join(OUTPUT_DIR, "fractal_heightmap_8192.npy"))
    k = SIZE_FULL // SIZE
    elev = hm.reshape(SIZE, k, SIZE, k).mean(axis=(1, 3)).astype(np.float32)
    river = np.array(Image.open(
        os.path.join(OUTPUT_DIR, "fractal_river_mask_8192.png")).convert("L"))
    river = np.asarray(
        Image.fromarray(river).resize((SIZE, SIZE), Image.NEAREST)) > 127
    biome = np.load(os.path.join(OUTPUT_DIR, "biome_labels_2048.npy"))
    region = np.load(os.path.join(OUTPUT_DIR, "regions", "region_labels.npy"))
    with open(os.path.join(GAME_CFG, "l3_city.json"), encoding="utf-8") as f:
        city_json = json.load(f)
    with open(os.path.join(GAME_CFG, "l1_world.json"), encoding="utf-8") as f:
        birth_json = json.load(f)
    return elev, river, biome, region, city_json, birth_json


# ---------- Step 1：文化圈 ----------

def build_culture_seeds(cities, region, biome, cultures):
    """锚点种子：culture 列表 → 像素种子 [(row, col, culture_idx)]。

    - n_states 型：regions 全部城的 anchor 质心一枚种子
    - per_region_states 型：每 region 一枚（质心）
    - south_seed_regions：在这些 region 的最南城 anchor 加撒种子（荒漠带跨 region 延伸）
    群岛质心常落海（MCP 海洋 cost 巨大无法扩散）→ 落海时改用离质心最近的城 anchor。
    """
    by_region = defaultdict(list)
    for c in cities:
        by_region[c["region"]].append(c)

    def snap_to_land(cy, cx, grp):
        if biome[int(cy), int(cx)] > 0:
            return int(cy), int(cx)
        best = min(grp, key=lambda g: (g["sx"] - cx) ** 2 + (g["sy"] - cy) ** 2)
        return int(best["sy"]), int(best["sx"])

    seeds = []
    for ci, cu in enumerate(cultures):
        regs = cu["regions"]
        if cu.get("per_region_states"):
            for r in regs:
                grp = by_region.get(r, [])
                if not grp:
                    print("  [warn] culture %s region_%03d 无城，跳过该种子" % (cu["id"], r))
                    continue
                cy = sum(g["sy"] for g in grp) / len(grp)
                cx = sum(g["sx"] for g in grp) / len(grp)
                seeds.append(snap_to_land(cy, cx, grp) + (ci,))
        else:
            grp = [g for r in regs for g in by_region.get(r, [])]
            if not grp:
                print("  [warn] culture %s 无城（regions=%s），跳过" % (cu["id"], regs))
                continue
            cy = sum(g["sy"] for g in grp) / len(grp)
            cx = sum(g["sx"] for g in grp) / len(grp)
            seeds.append(snap_to_land(cy, cx, grp) + (ci,))
        for r in cu.get("south_seed_regions", []):
            grp = by_region.get(r, [])
            if not grp:
                continue
            south = max(grp, key=lambda g: g["sy"])
            seeds.append((int(south["sy"]), int(south["sx"]), ci))
    return seeds


def culture_flood(seeds, elev, river, biome, region, cultures, fp):
    """分 culture 的测地 flood：每 culture 一张 cost 场（region 越界罚只对自己的
    合法 region 集外生效，§5.11.1 锚点语义），各自 MCP 求累计代价 → 逐像素
    argmin 归圈。返回 culture_idx+1 标签图（0 = 海/无）。
    """
    gy, gx = np.gradient(elev)
    gradmag = np.sqrt(gy * gy + gx * gx)
    land = biome > 0
    base = 1.0 + fp["k_slope"] * gradmag         + fp["k_river"] * river         + fp["k_desert"] * (biome == BI_DESERT)         + fp["k_ice"] * (biome == BI_ICE)
    base = np.where(land, base, 1e6).astype(np.float64)

    n_cu = len(cultures)
    cum_all = np.full((n_cu, region.shape[0], region.shape[1]),
                      np.inf, dtype=np.float32)
    for ci, cu in enumerate(cultures):
        starts = [(sd[0], sd[1]) for sd in seeds if sd[2] == ci]
        if not starts:
            continue
        costs = base.copy()
        legal = np.zeros(region.shape, dtype=bool)
        for r in cu["regions"]:
            legal |= (region == r)
        costs = costs + np.where(legal, 0.0, fp["k_cross_region"]) * land
        mcp = MCP_Geometric(costs)
        cum, _ = mcp.find_costs(starts)
        cum_all[ci] = cum.astype(np.float32)

    best = np.argmin(cum_all, axis=0)
    best_cost = np.take_along_axis(cum_all, best[None, ...], axis=0)[0]
    labels = np.where(best_cost > 6000.0, 0, (best + 1).astype(np.int16))
    return labels


# ---------- Step 2/3：都城与扩张 ----------

def pick_capitals(circle_cities, want, min_sep, label):
    """圈内按 population_score 降序选都城（T3 优先，距离间隔防扎堆）。"""
    t3 = [c for c in circle_cities if c["level"] >= 3]
    pool = t3 if t3 else [c for c in circle_cities if c["level"] >= 2]
    pool = pool if pool else list(circle_cities)
    pool.sort(key=lambda c: -c["pop"])
    caps = []
    for c in pool:
        if len(caps) >= want:
            break
        ok = True
        for g in caps:
            if math.hypot(c["ax"] - g["ax"], c["ay"] - g["ay"]) < min_sep:
                ok = False
                break
        if ok:
            caps.append(c)
    # 间隔/级别约束导致不足时逐级放宽补齐（无视间隔 -> 降级 T2 -> 降级全圈）
    for relax_pool in [pool, [c for c in circle_cities if c["level"] >= 2], list(circle_cities)]:
        for c in relax_pool:
            if len(caps) >= want:
                break
            if c not in caps:
                caps.append(c)
        if len(caps) >= want:
            break
    if len(caps) < want:
        print("  [warn] culture %s 只选出 %d/%d 都城（城池不足）" % (label, len(caps), want))
    return caps


def build_graph(cities, elev, land, xp):
    """城图：k 近邻 + 距离上限；边权 = dist × (1 + 文化摩擦 + 地形 + 贫瘠 + 跨海)。

    返回 adj: idx -> [(nbr_idx, w), ...]
    """
    n = len(cities)
    xs = np.array([c["ax"] for c in cities])
    ys = np.array([c["ay"] for c in cities])
    pts = np.stack([xs, ys], axis=1)
    d2 = ((pts[:, None, :] - pts[None, :, :]) ** 2).sum(axis=2)
    kn = xp["knear"]
    max_edge = xp["max_edge_px"]

    # 采样线：地形 std / 跨海判定共用
    def line_stats(a, b):
        ts = np.linspace(0, 1, 24)
        lx = (a["sx"] + (b["sx"] - a["sx"]) * ts).astype(int).clip(0, SIZE - 1)
        ly = (a["sy"] + (b["sy"] - a["sy"]) * ts).astype(int).clip(0, SIZE - 1)
        h = elev[ly, lx]
        sea_ratio = 1.0 - land[ly, lx].mean()
        return float(h.std()), float(sea_ratio)

    adj = [[] for _ in range(n)]
    near = np.argsort(d2, axis=1)[:, 1:kn + 1]
    # k 近邻关系对称化（A∈B 的近邻但反向未必），set 去重
    edges = set()
    for i in range(n):
        for j in near[i]:
            if i != j and d2[i, j] ** 0.5 <= max_edge:
                edges.add((min(i, j), max(i, j)))

    # 连通性兜底：桥接非最大连通分量到最近的异分量城对（含孤立城 = 单城分量；
    # 群岛/飞地整体离群时 max_edge 内无桥）。桥接新增边豁免下方距离过滤。
    bridged = _bridge_components(edges, d2, n)
    forced = bridged - edges
    edges |= bridged

    for i, j in edges:
        if i == j:
            continue
        a, b = cities[i], cities[j]
        dist = float(d2[i, j] ** 0.5)
        if dist > max_edge and (i, j) not in forced:
            continue
        terr, sea = line_stats(a, b)
        w = 1.0
        if a["culture"] != b["culture"]:
            w += xp["k_culture"]
        w += xp["k_terrain"] * terr
        w += xp["k_barren"] * (1.0 - (a["pop"] + b["pop"]) / 2.0)
        if sea > xp["sea_edge_ratio"]:
            w += xp["k_sea"]
        w *= dist
        adj[i].append((j, w))
        adj[j].append((i, w))
    return adj


def _bridge_components(edges, d2, n):
    """迭代桥接：每个非最大分量取离其它分量最近的一对城连边，直到全连通。"""
    edges = set(edges)

    def components():
        adj = [[] for _ in range(n)]
        for i, j in edges:
            adj[i].append(j)
            adj[j].append(i)
        seen = [False] * n
        comps = []
        for i in range(n):
            if seen[i]:
                continue
            stack, comp = [i], []
            seen[i] = True
            while stack:
                u = stack.pop()
                comp.append(u)
                for v in adj[u]:
                    if not seen[v]:
                        seen[v] = True
                        stack.append(v)
            comps.append(comp)
        return comps

    for _ in range(32):
        comps = components()
        if len(comps) <= 1:
            break
        comps.sort(key=len, reverse=True)
        main = set(comps[0])
        rest = [c for c in comps[1:]]
        linked = False
        for comp in rest:
            best = None
            for i in comp:
                order = np.argsort(d2[i])
                for j in order[1:]:
                    j = int(j)
                    if j in main or any(j in c2 for c2 in rest if c2 is not comp):
                        if best is None or d2[i][j] < best[0]:
                            best = (d2[i][j], i, j)
                        break
            if best is not None:
                _, i, j = best
                edges.add((min(i, j), max(i, j)))
                linked = True
        if not linked:
            break
    return edges


def dijkstra_expand(capitals, adj, caps, n, allow=None, balance_eps=0.0):
    """多源 Dijkstra（§5.11 扩张）。

    - caps：每源容量硬上限（防巨无霸；源满即"扩张预算耗尽"退役）
    - allow：城 → 可认领 state 集合（锚点圈城只接受本圈政权认领，
      source/volcanic/空洞城无限制 = 无主留地任周边国 claim）
    - balance_eps：均衡系数——边权按源当前规模放大（w×(1+eps×size)），
      大国边际成本递增 → 同圈多国自然均分（"都城密度高→国家小"的平滑实现）
    返回 owner 数组（-1 未分）。
    """
    owner = [-1] * n
    counts = defaultdict(int)
    heap = []
    for ci, sid in capitals:
        heapq.heappush(heap, (0.0, sid, ci))
    while heap:
        cost, st, ci = heapq.heappop(heap)
        if owner[ci] != -1:
            continue
        if counts[st] >= caps[st]:
            continue
        if allow is not None and ci in allow and st not in allow[ci]:
            continue
        owner[ci] = st
        counts[st] += 1
        for nbr, w in adj[ci]:
            if owner[nbr] == -1:
                nw = w * (1.0 + balance_eps * counts[st]) if balance_eps > 0 else w
                heapq.heappush(heap, (cost + nw, st, nbr))
    return owner


# ---------- 政权色 ----------

def state_colors(ordered_states, birth_colors, seed):
    """HSL 黄金角分布保色相分离；出生 8 城邦色保持原值。"""
    rng = random.Random(seed)
    out = dict(birth_colors)
    for i, st in enumerate(ordered_states):
        h = (i * 137.508) % 360.0 / 360.0
        # 黄金角有限项会在部分色相聚簇（gap 可 <10°），用饱和/明度随机拉大差异兜底
        s = 0.50 + rng.uniform(0.0, 0.18)
        l = 0.38 + rng.uniform(0.0, 0.20)
        r, g, b = colorsys.hls_to_rgb(h, l, s)
        out[st] = (int(r * 255), int(g * 255), int(b * 255))
    return out


# ---------- 蒙版与贴图 ----------

def rasterize_mask(city_json, colors, owners_by_label):
    """城市 polygon × 政权色 → 8192 RGBA 蒙版（非城透明，城 holes 挖空）。

    l3_city.json 顶点为 8192 级 [y,x]（city_split_v2 产物），直接同级光栅化。
    """
    img = Image.new("RGBA", (SIZE_FULL, SIZE_FULL), (0, 0, 0, 0))
    dr = ImageDraw.Draw(img)
    for t in city_json["tiles"]:
        col = colors.get(owners_by_label.get(int(t["label"]), ""))
        if col is None:
            continue
        for poly in t.get("polygons", []):
            if len(poly) < 3:
                continue
            dr.polygon([(p[1], p[0]) for p in poly], fill=col + (255,))
        for hole in t.get("holes", []):
            if len(hole) < 3:
                continue
            dr.polygon([(p[1], p[0]) for p in hole], fill=(0, 0, 0, 0))
    return img


def export_l2_previews(mask_rgba, l2_packs_dir):
    """L2 政治贴图：8192 蒙版按 context 窗口直接采样（同级坐标，NEAREST）。"""
    arr = np.asarray(mask_rgba)
    made = []
    for rid in sorted(d for d in os.listdir(l2_packs_dir) if d.startswith("region_")):
        info = json.load(open(
            os.path.join(OUTPUT_DIR, "l2_packs", rid, "info.json"), encoding="utf-8"))
        world = json.load(open(
            os.path.join(l2_packs_dir, rid, "l2_world.json"), encoding="utf-8"))
        bb = info["bbox_8192"]
        ctx_w, ctx_h = world["context_size"]
        tx, ty = world["tiles_offset"]
        # context 像素 (cx,cy) → 世界 8192 (bb.x0 - tx + cx, bb.y0 - ty + cy)
        gx = bb["x0"] - tx + np.arange(ctx_w)
        gy = bb["y0"] - ty + np.arange(ctx_h)
        GX, GY = np.meshgrid(gx, gy)
        out = np.zeros((ctx_h, ctx_w, 4), dtype=np.uint8)
        for ch in range(4):
            out[..., ch] = map_coordinates(
                arr[..., ch], [GY, GX], order=0, mode="constant", cval=0)
        img = Image.fromarray(out, "RGBA")
        dst = os.path.join(l2_packs_dir, rid, "l2_political_preview.png")
        img.save(dst)
        made.append((rid, dst, int((out[..., 3] > 0).sum())))
    return made


def fit_font(size):
    try:
        return ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", size)
    except OSError:
        return ImageFont.load_default()


def draw_legend(dr, entries, x0, y0, font):
    for i, (name, col) in enumerate(entries):
        y = y0 + i * 30
        dr.rectangle([x0, y + 4, x0 + 26, y + 22], fill=col + (255,),
                     outline=(20, 20, 24, 255))
        dr.text((x0 + 34, y + 2), name, font=font, fill=(235, 235, 240, 255))


# ---------- 主流程 ----------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--skip-preview", action="store_true")
    args = ap.parse_args()

    P = load_params()
    elev, river, biome, region, city_json, birth_json = load_inputs()
    cultures = P["cultures"]
    cu_by_id = {c["id"]: c for c in cultures}

    # 城数组：anchor/centroid/polygons 均为 8192 级（city_split_v2 产物）；
    # ax/ay 保留 8192（城图距离/蒙版），sx/sy = /4 后的 2048 级（栅格采样）
    cities = []
    for t in city_json["tiles"]:
        ax, ay = t["anchor"][0], t["anchor"][1]
        sx, sy = ax / 4.0, ay / 4.0
        cities.append({
            "label": int(t["label"]), "group": int(t["group"]),
            "ax": float(ax), "ay": float(ay), "sx": float(sx), "sy": float(sy),
            "level": int(t.get("level", 1)),
            "pop": float(t.get("population_score", 0.0)),
            "region": int(region[int(sy), int(sx)]),
            "culture": "",
        })
    birth_labels = set()
    birth_states = {}
    for s in birth_json["states"]:
        sid = s["state_id"]
        birth_states[sid] = {
            "name": s["name"], "capital": s["capital_settlement_id"],
            "culture": "plain", "alliance": None,
            "color": [int(c) for c in s["color"]], "is_city_state": True,
        }
    for tl in birth_json["tiles"]:
        birth_labels.add(int(tl["tile_id"].split("_")[1]))
        birth_states[tl["owner_state_id"]].setdefault("cities", []).append(
            tl["settlement"]["settlement_id"])
    print("输入：1040 城中出生 8 城邦 label=%s；文化圈定义 %d 个" % (
        sorted(birth_labels), len(cultures)))

    # Step 1 文化圈
    seeds = build_culture_seeds(cities, region, biome, cultures)
    print("文化圈种子 %d 枚（%s）" % (len(seeds), ", ".join(
        "%s@(%d,%d)" % (cultures[s[2]]["id"], s[1], s[0]) for s in seeds)))
    cul_labels = culture_flood(seeds, elev, river, biome, region, cultures, P["culture_flood"])

    # 城文化采样 + 特殊文化覆盖（源流/火山 = 非占领文化标签）
    sp = P["special_cultures"]
    for c in cities:
        b = int(biome[int(c["sy"]), int(c["sx"])])
        if b == BI_SOURCE:
            c["culture"] = "source"
        elif b == BI_VOLCANIC:
            c["culture"] = "volcanic"
        else:
            cl = int(cul_labels[int(c["sy"]), int(c["sx"])]) - 1
            c["culture"] = cultures[cl]["id"] if cl >= 0 else ""
    region_culture = {}
    for cu in cultures:
        for r in cu["regions"]:
            region_culture.setdefault(r, cu["id"])
    no_cul = [c for c in cities if not c["culture"]]
    for c in no_cul:  # 兜底：优先 region 锚点表，再借最近有文化城
        c["culture"] = region_culture.get(c["region"], "")
        if not c["culture"]:
            best = min((o for o in cities if o["culture"]),
                       key=lambda o: (o["ax"] - c["ax"]) ** 2 + (o["ay"] - c["ay"]) ** 2)
            c["culture"] = best["culture"]
    stat = Counter(c["culture"] for c in cities)
    print("城文化分布：" + "  ".join("%s:%d" % kv for kv in sorted(stat.items())))

    # Step 2 都城 + 政权表
    cap_per = P["expansion"]["cap_per_state"]
    states = {}          # state_id -> state dict（先锚点后出生）
    capitals = []        # (city_idx, state_id)
    city_by_idx_all = cities
    label_to_idx = {c["label"]: i for i, c in enumerate(cities)}
    culture_order = []   # 政权生成序（配色黄金角用）

    for cu in cultures:
        cid = cu["id"]
        circle = [c for c in cities if c["culture"] == cid and c["label"] not in birth_labels]
        if not circle:
            print("  [warn] culture %s 无可分配城" % cid)
            continue
        want = cu.get("n_states", 1)
        if cu.get("per_region_states"):
            want = max(want, len(cu["regions"]))
        want = max(want, math.ceil(len(circle) / cap_per))
        # 都城间距自适应圈尺寸（bbox 对角线 / sqrt(N)，下限参数值）——大圈都城平铺
        dia = math.hypot(max(c["ax"] for c in circle) - min(c["ax"] for c in circle),
                         max(c["ay"] for c in circle) - min(c["ay"] for c in circle))
        sep = max(P["capital_min_sep_px"], dia / math.sqrt(want) * 0.7)
        caps = pick_capitals(circle, want, sep, cid)
        for i, cp in enumerate(caps):
            sid = "state_p7_%s_%d" % (cid, i)
            states[sid] = {
                "name": "", "capital": sid_of(cp["label"]), "culture": cid,
                "alliance": None, "is_city_state": False,
            }
            culture_order.append((cu["id"], -cp["pop"], sid))
            capitals.append((label_to_idx[cp["label"]], sid))

    # 出生 8 城邦（沿用既有 states）
    for sid, sd in birth_states.items():
        sd["n_cities"] = len(sd.pop("cities", []))
        states[sid] = sd
    print("政权总数 %d（出生 8 城邦 + 新国 %d）" % (
        len(states), len(capitals)))

    # Step 3 城图扩张（出生城移出图 =「遇他国已占即停」）
    expandable = [i for i, c in enumerate(cities) if c["label"] not in birth_labels]
    sub_pos = {g: k for k, g in enumerate(expandable)}
    sub = [cities[i] for i in expandable]
    land = biome > 0
    adj = build_graph(sub, elev, land, P["expansion"])
    # 每源容量：圈内城数/圈政权数 + 裕量，且 ≤ 全局 cap（防巨无霸）
    caps_sub = {}
    for cu in cultures:
        circle_n = sum(1 for c in sub if c["culture"] == cu["id"])
        n_st = sum(1 for (_, sid) in capitals if states[sid]["culture"] == cu["id"])
        if n_st == 0:
            continue
        per = min(cap_per, math.ceil(circle_n / n_st) + 8)
        for (_, sid) in capitals:
            if states[sid]["culture"] == cu["id"]:
                caps_sub[sid] = per
    sub_caps = [(sub_pos[gidx], sid) for (gidx, sid) in capitals]
    # 认领过滤：锚点圈城只接受本圈政权认领（国界≈文化圈界，跨圈只经留地过渡）；
    # source/volcanic/空洞城 = 无主留地，任周边国 claim。均衡系数 = 大国边际成本
    # 递增，同圈多国平滑均分（"都城密度高→国家小"的连续实现）
    circle_states = defaultdict(set)
    for (_, sid) in capitals:
        circle_states[states[sid]["culture"]].add(sid)
    allow = {}
    for k, c in enumerate(sub):
        if c["culture"] in circle_states:
            allow[k] = circle_states[c["culture"]]
    owner_sub = dijkstra_expand(sub_caps, adj, caps_sub, len(sub),
                                allow=allow, balance_eps=0.008)

    # 兜底两轮：二轮无容量（容量是软约束，认领过滤保留——溢出城归本圈）；
    # 三轮无过滤（圈飞地：被别圈城墙隔开、本圈源图上不可达的城，归图上最近源，
    # 语义 = 飞地被邻国实际控制）。容量/认领都是软约束，不许留无主城。
    if any(o == -1 for o in owner_sub):
        free = dijkstra_expand(sub_caps, adj,
            {sid: 1 << 30 for _, sid in sub_caps}, len(sub), allow=allow)
        for k, o in enumerate(owner_sub):
            if o == -1:
                owner_sub[k] = free[k]
    if any(o == -1 for o in owner_sub):
        free = dijkstra_expand(sub_caps, adj,
            {sid: 1 << 30 for _, sid in sub_caps}, len(sub))
        orphans = 0
        for k, o in enumerate(owner_sub):
            if o == -1:
                owner_sub[k] = free[k]
                orphans += 1
        print("  [info] 圈飞地兜底 %d 城（放开认领归图上最近源）" % orphans)

    # city_owners 全表
    city_owners = {}
    for i, c in enumerate(cities):
        if c["label"] in birth_labels:
            continue
        city_owners[sid_of(c["label"])] = owner_sub[sub_pos[i]]
    for tl in birth_json["tiles"]:
        city_owners[tl["settlement"]["settlement_id"]] = tl["owner_state_id"]

    # 命名：圈内按城数降序取 names（主名 = 圈内主导国；链式竞速下先手优势
    # 可能让 pop 最高的都城反而地盘小，名字跟着地盘走观感才对）
    n_cnt_pre = Counter(city_owners.values())
    for cu in cultures:
        sids = [sid for (_, sid) in capitals if states[sid]["culture"] == cu["id"]]
        sids.sort(key=lambda x: -n_cnt_pre.get(x, 0))
        names = list(cu["names"])
        prefix = cu.get("name_prefix", "")
        for i, sid in enumerate(sids):
            states[sid]["name"] = prefix + (
                names[i] if i < len(names) else "%s·%d" % (cu["label"], i + 2))

    # Step 4 色
    birth_colors = {sid: tuple(sd["color"]) for sid, sd in birth_states.items()}
    ordered = [sid for _, _, sid in sorted(culture_order)]
    colors = state_colors(ordered, birth_colors, P["seed"])
    for sid in states:
        states[sid]["color"] = list(colors[sid])
        states[sid]["n_cities"] = 0
    for sid in city_owners.values():
        states[sid]["n_cities"] += 1

    # 指标
    n_cnt = Counter(city_owners.values())
    print("\n=== 政权指标 ===")
    for sid in sorted(states, key=lambda s: -n_cnt.get(s, 0)):
        sd = states[sid]
        print("  %-18s %-14s 城%3d  culture=%s%s" % (
            sid, sd["name"], n_cnt.get(sid, 0), sd["culture"],
            "  [城邦]" if sd["is_city_state"] else ""))
    sizes = [n_cnt.get(s, 0) for s in states if not states[s]["is_city_state"]]
    print("新国城数 max=%d min=%d mean=%.1f；总城=%d（应 1040）" % (
        max(sizes), min(sizes), sum(sizes) / len(sizes), len(city_owners)))

    if args.dry_run:
        print("\n--dry-run：不写任何文件，结束。")
        return

    # ---------- 产物 ----------
    owners_by_label = {}
    for t in city_json["tiles"]:
        sid = city_owners.get(sid_of(int(t["label"])))
        if sid:
            owners_by_label[int(t["label"])] = sid

    # political_data.json（真相源）
    pdata = {
        "meta": {
            "generated_by": "state_expand_lite.py",
            "params": "state_params.json",
            "n_states": len(states), "n_cities": len(city_owners),
            "cap_per_state": cap_per,
        },
        "states": states,
        "city_owners": city_owners,
    }
    with open(os.path.join(GAME_CFG, "political_data.json"), "w", encoding="utf-8") as f:
        json.dump(pdata, f, ensure_ascii=False, indent=1)

    # 注入 l3_city.json（tiles[].state_id + 顶层 states）
    for t in city_json["tiles"]:
        t["state_id"] = owners_by_label.get(int(t["label"]), "")
    city_json["states"] = states
    with open(os.path.join(GAME_CFG, "l3_city.json"), "w", encoding="utf-8") as f:
        json.dump(city_json, f, ensure_ascii=False, indent=1)

    # 注入 l2 packs ×13（cities[].state_id + 顶层 states）
    l2_dir = os.path.join(GAME_CFG, "l2_packs")
    for rid in sorted(d for d in os.listdir(l2_dir) if d.startswith("region_")):
        p = os.path.join(l2_dir, rid, "l2_world.json")
        with open(p, encoding="utf-8") as f:
            w = json.load(f)
        for c in w.get("cities", []):
            c["state_id"] = city_owners.get(c["id"], "")
        w["states"] = states
        with open(p, "w", encoding="utf-8") as f:
            json.dump(w, f, ensure_ascii=False, indent=1)

    # 蒙版 → L3 底图（2048 RGB 不透明，非城/洞 = 海洋色）
    mask8 = rasterize_mask(city_json, colors, owners_by_label)
    l3_full = Image.new("RGB", (SIZE_FULL, SIZE_FULL), OCEAN)
    l3_full.paste(mask8, (0, 0), mask8)
    l3_img = l3_full.resize((SIZE, SIZE), Image.NEAREST)
    l3_img.save(os.path.join(GAME_CFG, "l3_political.png"))

    made = export_l2_previews(mask8, l2_dir)
    for rid, _, npx in made:
        print("  L2 贴图 %s：%d px" % (rid, npx))

    # 验收预览（政权版图 + 都城标注 + 图例 / 文化圈）
    if not args.skip_preview:
        prev = l3_img.copy()
        dr = ImageDraw.Draw(prev)
        font = fit_font(24)
        font_s = fit_font(20)
        cap_xy = {}
        for t in city_json["tiles"]:
            sid = t.get("state_id", "")
            if sid and states[sid]["capital"] == sid_of(int(t["label"])):
                cap_xy[sid] = (t["anchor"][0] / 4.0, t["anchor"][1] / 4.0)
        for sid, (x, y) in cap_xy.items():
            dr.ellipse([x - 7, y - 7, x + 7, y + 7], fill=(255, 255, 255),
                       outline=(20, 20, 24), width=2)
            dr.text((x + 10, y - 14), states[sid]["name"], font=font,
                    fill=(255, 255, 255), stroke_width=2, stroke_fill=(20, 20, 24))
        entries = [(states[s]["name"] + ("·城邦" if states[s]["is_city_state"] else "")
                    + " %d城" % n_cnt.get(s, 0), tuple(states[s]["color"]))
                   for s in sorted(states, key=lambda s: -n_cnt.get(s, 0))]
        canvas = Image.new("RGB", (SIZE + 420, SIZE), (14, 16, 22))
        canvas.paste(prev, (0, 0))
        dr2 = ImageDraw.Draw(canvas)
        dr2.text((SIZE + 20, 24), "政权版图（P7 简化版）", font=font, fill=(240, 240, 245))
        draw_legend(dr2, entries, SIZE + 20, 70, font_s)
        canvas.save(os.path.join(OUTPUT_DIR, "political_preview_2048.png"))

        # 文化圈图
        cu_colors = {}
        rng = random.Random(P["seed"] + 7)
        for cu in cultures:
            cu_colors[cu["id"]] = tuple(
                int(v * 255) for v in colorsys.hls_to_rgb(
                    rng.random(), 0.5, 0.6))
        cu_colors["source"] = (95, 160, 195)
        cu_colors["volcanic"] = (150, 70, 60)
        cprev = Image.new("RGB", (SIZE, SIZE), OCEAN)
        drw = ImageDraw.Draw(cprev)
        for t in city_json["tiles"]:
            sid = owners_by_label.get(int(t["label"]), "")
            cu = states.get(sid, {}).get("culture", "")
            if cu not in cu_colors:
                continue
            for poly in t.get("polygons", []):
                if len(poly) >= 3:
                    drw.polygon([(p[1] / 4.0, p[0] / 4.0) for p in poly], fill=cu_colors[cu])
        canvas2 = Image.new("RGB", (SIZE + 420, SIZE), (14, 16, 22))
        canvas2.paste(cprev, (0, 0))
        dr3 = ImageDraw.Draw(canvas2)
        dr3.text((SIZE + 20, 24), "文化圈（=城的 culture 字段）", font=font, fill=(240, 240, 245))
        ent = [(cu["label"] + "（%s）" % cu["id"] + " %d城" % stat.get(cu["id"], 0),
                cu_colors[cu["id"]]) for cu in cultures]
        ent += [("清源（沿岸，非占领）", cu_colors["source"]),
                ("熔岩（蚀变区，非占领）", cu_colors["volcanic"])]
        draw_legend(dr3, ent, SIZE + 20, 70, font_s)
        canvas2.save(os.path.join(OUTPUT_DIR, "culture_preview_2048.png"))
        print("预览：output/political_preview_2048.png + culture_preview_2048.png")

    print("\n完成。json 已注入，记得：1) godot --headless --path . --import（新 PNG）"
          " 2) 跑 l_world_bake.gd 刷 bin")


if __name__ == "__main__":
    main()
