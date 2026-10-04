"""L1 战略图资源点派生（resource_export.py）—— 各包 resources 字段生成端注入。

战略图「资源开关」画的是资源点图标（docs/技术/架构/世界与战略图/战略图架构.md §4.5），数据源在
L1 视图包顶层 `resources: [{"id": <资源表 id>, "pos": [x, y]}]`（pos = 包 context 本地
坐标，与 roads polyline 同坐标系同原点 world_origin）。运行时零新增文件加载。

    **分布规则为 AI 提案/待验收**（阈值在 resource_params.json，可整表调参）：
      wood 木         = 森林群系（较常见）
      stone 石        = 丘陵（中海拔带）
      iron 铁         = 山地（高海拔）
      gold 金         = 稀有山矿（更高海拔 + 陡坡）
      diamond 钻      = 稀有山矿（最高海拔 + 最陡坡，出现概率最低）
      black_pitch 沥青 = 低地带（低海拔 + 平原/源流群系；黑色沥青是世界观着力点）
    金/钻在资源表（config/resources/resources.tres）暂无条目，id 先用
    res_gold_ore / res_diamond 占位（提案/待验收，接资源系统时补行或改名）。

输入（生成端产物，不进 config）：
  output/biome_labels_2048.npy          七群系标签（0 海 1 平原 2 森林 3 荒漠 4 冰原 5 源流 6 火山）
  output/fractal_heightmap_8192.npy     高度场
  output/locked/locked_continent_8192.png  海陆（陆地掩码，与路网/地形同源）
  output/refined_lake_mask_8192.npy     精细湖光栅（水体上不放点）
  output/fractal_river_mask_8192.png    河流掩膜（河面同样不放点）
  + 各包 tiles 多边形（采样候选 = 本包地块内部，邻块/水面排除）

采样口径（确定性，跨机器一致）：窗口按 step 降采样成栅格 → 逐类型筛合格格 →
以 stable_hash(包名, 类型) 作种子的 Random 抽格 → 格心加种子内抖动 → point-in-polygon
校验（不在地块内则取格心）→ 同包最小间距 min_gap_ratio × 窗口边 去聚集。
每包 0~6 点（配额与总上限见 params；资源开关是地图图层不是清单，别爆炸）。

产出（覆盖写回，json 保持 indent=1 与原字段序，resources 插在 roads 之后）：
  70 份 l1_world.json（config/strategic_map/l1_world.json + l1_packs/l1_*/l1_world.json）

用法：
  python resource_export.py             # 全量 70 包（幂等，重跑覆盖）
  python resource_export.py --dry-run   # 只打印统计不写文件
  python resource_export.py --pack l1_069,spawn   # 指定包（spawn = 出生根包）
  Python 须用完整路径（PATH 首位 python 无 scipy/numpy 完整版）
"""
import argparse
import glob
import hashlib
import json
import math
import os
import random

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # tools/worldgen
OUT_DIR = os.path.join(HERE, "output")
GAME_DIR = os.path.normpath(os.path.join(
    HERE, "..", "..", "stick-world", "config", "strategic_map"))
PARAMS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "resource_params.json")

RES = 8192        # 世界坐标分辨率（与路网/地形同源）
BIOME_2048 = 2048


# ---------------------------------------------------------------- 通用

def stable_hash(*parts):
    """确定性种子（跨机器/跨 Python 版本一致；不用内置 hash——它带随机盐）。"""
    h = hashlib.sha256("|".join(str(p) for p in parts).encode("utf-8")).digest()
    return int.from_bytes(h[:8], "big")


def point_in_ring(pt, ring):
    """射线法 point-in-polygon（与 road_generate 同口径）。"""
    x, y = pt
    inside = False
    n = len(ring)
    j = n - 1
    for i in range(n):
        xi, yi = ring[i]
        xj, yj = ring[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi + 1e-12) + xi:
            inside = not inside
        j = i
    return inside


def load_params():
    with open(PARAMS_PATH, encoding="utf-8") as f:
        raw = json.load(f)
    return {k: v for k, v in raw.items() if not k.startswith("_")}


def block_stat(arr, step, out_hw, fn):
    """按 step 分块聚合（边缘贴边补齐）：fn = "mean" / "max"。

    arr 为 8192 级窗口裁剪；out_hw = (gh, gw)。补齐用边缘值，避免降水陆判定。
    """
    gh, gw = out_hw
    ph, pw = gh * step - arr.shape[0], gw * step - arr.shape[1]
    if ph > 0 or pw > 0:
        arr = np.pad(arr, ((0, max(0, ph)), (0, max(0, pw))), mode="edge")
    arr = arr[:gh * step, :gw * step]
    if arr.ndim == 2:
        blocks = arr.reshape(gh, step, gw, step)
        return blocks.mean(axis=(1, 3)) if fn == "mean" else blocks.max(axis=(1, 3))
    blocks = arr.reshape(gh, step, gw, step, arr.shape[2])
    return blocks.mean(axis=(1, 3)) if fn == "mean" else blocks.max(axis=(1, 3))


def upsample_labels(labels_2048, x0, y0, step, out_hw):
    """2048 群系标签 → 栅格（按栅格格心的世界坐标取 2048 级最近邻）。

    坐标链：8192 世界 = 包本地 + world_origin；2048 级 = 世界 / 4（与
    road_biome_export 同口径、同轴序 labels[iy, ix]）。
    """
    gh, gw = out_hw
    iy = np.clip(((y0 + (np.arange(gh) + 0.5) * step) // 4).astype(np.int64),
                 0, labels_2048.shape[0] - 1)
    ix = np.clip(((x0 + (np.arange(gw) + 0.5) * step) // 4).astype(np.int64),
                 0, labels_2048.shape[1] - 1)
    return labels_2048[iy[:, None], ix[None, :]]


# ---------------------------------------------------------------- 单包派生

def pack_resources(world, p, masks, labels):
    """单包资源点列表。返回 ([{"id","pos"}...], 统计 dict)。"""
    x0, y0 = int(world["world_origin"][0]), int(world["world_origin"][1])
    side = int((world.get("context_size") or [0])[0]) or int(world["size"])
    step = int(p["grid_step"])
    while side // step > int(p["grid_max"]):
        step *= 2
    gh, gw = max(1, side // step), max(1, side // step)

    # 地块栅格（值为 tile 序号，0 = 窗外/邻块）
    img = Image.new("I", (gw, gh), 0)
    dr = ImageDraw.Draw(img)
    rings = {}
    for i, t in enumerate(world.get("tiles", []), start=1):
        polys = t.get("polygons") or ([t["polygon"]] if t.get("polygon") else [])
        for ring in polys:
            if len(ring) >= 3:
                dr.polygon([(float(pt[0]) / step, float(pt[1]) / step) for pt in ring], fill=i)
                rings.setdefault(i, []).append(ring)
    tile_raster = np.asarray(img, np.int32)

    # 水体（海 ∪ 湖 ∪ 河）与地形
    cont = masks["continent"][y0:y0 + side, x0:x0 + side]
    land = block_stat(cont.astype(np.float32), step, (gh, gw), "mean") >= 0.5
    lake = block_stat(masks["lake"][y0:y0 + side, x0:x0 + side].astype(np.uint8),
                      step, (gh, gw), "max") > 0
    river = block_stat(masks["river"][y0:y0 + side, x0:x0 + side].astype(np.uint8),
                       step, (gh, gw), "max") > 0
    h = block_stat(masks["height"][y0:y0 + side, x0:x0 + side].astype(np.float32),
                   step, (gh, gw), "mean")
    gy, gx = np.gradient(h)
    slope = np.hypot(gx, gy) / step        # 单位 = 每世界 px 高度（与分辨率无关）
    biome = upsample_labels(labels, x0, y0, step, (gh, gw))

    dry = land & ~lake & ~river & (tile_raster > 0)
    ok = {}
    for rtype, rule in p["rules"].items():
        m = dry.copy()
        if "biomes" in rule:
            m &= np.isin(biome, rule["biomes"])
        if "h_min" in rule:
            m &= h >= float(rule["h_min"])
        if "h_max" in rule:
            m &= h <= float(rule["h_max"])
        if "slope_min" in rule:
            m &= slope >= float(rule["slope_min"])
        ok[rtype] = m

    # 配额（每包随机档，稀有类型按概率出现）→ 总上限截断（先砍常见类型）
    pack_key = "%s@%d,%d" % (world.get("parent_l1_label"), x0, y0)
    q_rng = random.Random(stable_hash(pack_key, "quota"))
    counts = {}
    for rtype, q in p["quota"].items():
        if q["kind"] == "fixed":
            counts[rtype] = int(q["n"])
        elif q["kind"] == "range":
            counts[rtype] = q_rng.randint(int(q["lo"]), int(q["hi"]))
        else:   # chance
            counts[rtype] = 1 if q_rng.random() < float(q["p"]) else 0
    order = [r for r in p["order"] if counts.get(r, 0) > 0]
    total = sum(counts.values())
    dropped = {}
    while total > int(p["max_per_pack"]):      # 超上限先砍常见类型（order 头部优先）
        for rtype in order:
            if total <= int(p["max_per_pack"]):
                break
            if counts[rtype] > 0:
                counts[rtype] -= 1
                total -= 1
                dropped[rtype] = dropped.get(rtype, 0) + 1

    min_gap = float(p["min_gap_ratio"]) * side
    out = []
    placed_local = []
    for rtype in p["order"]:
        if counts.get(rtype, 0) <= 0:
            continue
        cells = np.flatnonzero(ok[rtype].ravel())
        if cells.size == 0:
            continue
        rng = random.Random(stable_hash(pack_key, rtype))
        pool = rng.sample(range(cells.size), min(cells.size, int(p["sample_pool"])))
        got = 0
        for k in pool:
            ci = int(cells[k])
            cy, cx = divmod(ci, gw)
            tid = int(tile_raster[cy, cx])
            if tid <= 0:
                continue
            ring = rings.get(tid) or []
            jx = rng.uniform(-0.5, 0.5) * step
            jy = rng.uniform(-0.5, 0.5) * step
            # 格心加抖动 → 先按写出口径 round(2) 定稿，再用**定稿坐标**做
            # point-in-polygon（栅格化边界与矢量环有亚格差，round 也能把贴边点
            # 推出环外）；不合法退格心、格心也不合法就跳过换下一个候选——
            # 采样点严格落在地块多边形内，且与本包 roads polyline 同精度同坐标系
            lx, ly = round((cx + 0.5) * step + jx, 2), round((cy + 0.5) * step + jy, 2)
            if not any(point_in_ring((lx, ly), r) for r in ring):
                lx, ly = round((cx + 0.5) * step, 2), round((cy + 0.5) * step, 2)
                if not any(point_in_ring((lx, ly), r) for r in ring):
                    continue
            if any(math.dist((lx, ly), q) < min_gap for q in placed_local):
                continue
            placed_local.append((lx, ly))
            out.append({"id": p["resources"][rtype], "pos": [lx, ly]})
            got += 1
            if got >= counts[rtype]:
                break
    return out, {"n": len(out), "dropped": dropped}


# ---------------------------------------------------------------- 主流程

def main():
    ap = argparse.ArgumentParser(description="L1 战略图资源点派生（resources 进各包）")
    ap.add_argument("--dry-run", action="store_true", help="只打印统计不写文件")
    ap.add_argument("--pack", default=None, help="指定包（逗号分隔，spawn = 出生根包）")
    args = ap.parse_args()
    p = load_params()

    print("[1/3] 加载生成端产物（群系 2048 / 高度 8192 / 海陆·湖·河掩膜）...")
    labels = np.load(os.path.join(OUT_DIR, "biome_labels_2048.npy"))
    masks = {
        "height": np.load(os.path.join(OUT_DIR, "fractal_heightmap_8192.npy"), mmap_mode="r"),
        "lake": np.load(os.path.join(OUT_DIR, "refined_lake_mask_8192.npy"), mmap_mode="r"),
        "continent": np.array(Image.open(os.path.join(
            OUT_DIR, "locked", "locked_continent_8192.png")).convert("L")),
        "river": np.array(Image.open(os.path.join(
            OUT_DIR, "fractal_river_mask_8192.png")).convert("L")) > 127,
    }

    print("[2/3] 逐包派生（tile 多边形内确定性采样；分布规则为 AI 提案/待验收）...")
    spawn_path = os.path.join(GAME_DIR, "l1_world.json")
    packs = [spawn_path]
    packs += sorted(glob.glob(os.path.join(GAME_DIR, "l1_packs", "l1_*", "l1_world.json")))
    if args.pack:
        want = {v.strip() for v in args.pack.split(",")}
        packs = [pp for pp in packs
                 if pp == spawn_path and "spawn" in want
                 or os.path.basename(os.path.dirname(pp)) in want]
    hist = {}
    type_totals = {}
    slots = []
    written = 0
    for pp in packs:
        with open(pp, encoding="utf-8") as f:
            world = json.load(f)
        if not world.get("world_origin"):
            print("  !! 缺 world_origin，跳过 %s" % pp)
            continue
        res, st = pack_resources(world, p, masks, labels)
        hist[st["n"]] = hist.get(st["n"], 0) + 1
        slots.append(st["n"])
        for rd in res:
            type_totals[rd["id"]] = type_totals.get(rd["id"], 0) + 1
        if not args.dry_run:
            # 字段序：resources 插在 roads 之后，其余字段原样；**必须跳过包内已有的
            # resources 键**——否则复制循环走到旧键时会把刚算出的新值又覆盖回旧值
            # （键位置不变、值是旧的，重跑看起来幂等其实永不生效）
            new = {}
            for k, v in world.items():
                if k == "resources":
                    continue
                new[k] = v
                if k == "roads":
                    new["resources"] = res
            if "roads" not in world:            # 理论不发生
                new["resources"] = res
            with open(pp, "w", encoding="utf-8") as f:
                json.dump(new, f, ensure_ascii=False, indent=1)
            written += 1
    print("  包 %d：资源点合计 %d，每包 %s（分布 %s）"
          % (len(packs), sum(slots), "%.1f~%.1f（均 %.2f）"
             % (min(slots), max(slots), sum(slots) / max(1, len(slots))),
             " ".join("%d点×%d包" % (k, v) for k, v in sorted(hist.items()))))
    print("  按类型：%s" % " / ".join(
        "%s %d" % (k, v) for k, v in sorted(type_totals.items())))
    print("[3/3] %s" % ("--dry-run 未写文件" if args.dry_run else
                        "已写 %d 份 l1_world.json（resources 插在 roads 之后；"
                        "json 改动须重跑 l_world_bake.gd 刷 bin）" % written))


if __name__ == "__main__":
    main()
