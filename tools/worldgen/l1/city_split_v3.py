# -*- coding: utf-8 -*-
"""城块划分 v3 —— 接世界重生成 v2 聚落表（settlements_v2.json）重切城市地块。

与 v2（city_split_v2.py，jittered grid 撒点）的差异：
  1. 城市点 = settlements_v2.json 的 1036 聚落（变半径泊松盘选址产物），不再撒点。
     tile label = 聚落 label（1..1036 连续），settlement_id = settlement_city_%03d
     ——与 political_data.city_owners / world_contract_initializer 的映射体系同源。
  2. 纯「最近聚落抗衡」（创始人 2026-09-27 裁决：抗衡即唯一边界）：城块生长按
     老 L1 分组做 EDT 一次距离变换取每像素最近种子（平面多源膨胀的等价快算），
     每寸陆地都有归属、无缝无灰。早期「主张盘封顶」（距聚落超主张半径退灰，
     再撒填充点补洞）已退役——圆块/灰缝/填充点链的根源，git 历史可考古。
  3. 无聚落的老 L1 连通分量（离岛等）不再兜底撒点——直接留荒地（v2 语义：
     无聚落即无主，不再造「质心兜底城」）。
  4. 面积下限合并取消：小城块是贫瘠带的正常形态，合并会破坏
     「一聚落一城块」的 1:1 映射。
  5. 落水聚落吸附：v2 聚落位置自 2048 场采样（±4px），个别点位按 region 蒙版
     落在水上——吸附到最近老 L1 陆地像素（≤ 数 px，仅影响城块种子位置，
     settlements_v2.json 不改动，仍为聚落位置真源）。

产出（output/l1_v2/，与 v2 同名覆盖）：
  - city_labels_8192.npy    城块蒙版（0=海洋/荒地，1..1036=label=聚落 label）
  - city_data.json          城块元数据（label/settlement_id/parent_l1/city/centroid/
                            area_px/rgb/polygon(s)/neighbors/claim_r/level/
                            population_score/name）
  - city_preview_8192.png   预览（荒地=中性灰陆地色）
  - city_partition_8192.png / city_cities_8192.png

用法：
  python tools/worldgen/l1/city_split_v3.py            # 全量（确定性，seed 只进配色无算法随机）
  python tools/worldgen/l1/city_split_v3.py --labels-only --cached-parent
      # 填缝迭代快跑：只算标签场 + 缝隙统计（跳过 mesh/配色/预览/JSON），
      # 复用已落盘的 legacy_l1_labels_8192.npy（ Packs 变更后须删缓存全量重跑）
"""
import argparse
import colorsys
import json
import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage as ndi

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # tools/worldgen
L2_PACKS = os.path.join(HERE, "output", "l2_packs")
REGIONS_DIR = os.path.join(HERE, "output", "regions")
OUT_DIR = os.path.join(HERE, "output", "l1_v2")
FIELDS_DIR = os.path.join(HERE, "output", "fields")
sys.path.insert(0, os.path.join(HERE, "l2_export"))
sys.path.insert(0, os.path.join(HERE, "l3"))
import landmass_util as lmu  # noqa: E402
import mesh_extract  # noqa: E402
import settlement_build as sb  # noqa: E402  （suitability bilinear 采样复用）

OCEAN_COLOR = (30, 55, 95)
WASTELAND_COLOR = (120, 118, 112)   # 荒地中性灰（预览用；政治 mask 保留码 253）
STRUCT8 = np.ones((3, 3), dtype=bool)

RES = 8192
K_FIELD = 4   # 8192 坐标 → 2048 场网格缩比（settlement_build 同值）


def build_legacy_l1_mask(size=RES):
    """拼 13 地区老 L1 → 全局蒙版（与 city_split_v2.build_legacy_l1_mask 同式）。

    结果不做 EDT 缺口修复（v2 原版有：land 缺口按最近老 L1 回填）——荒地语义下
    修复像素会把无主陆地并进邻块城块，保留 0 让其自然成荒地。"""
    glob8192 = np.zeros((RES, RES), dtype=np.int32)
    shift = 0
    for i in range(1, 14):
        rid = "region_%03d" % i
        info = json.load(open(os.path.join(L2_PACKS, rid, "info.json"), encoding="utf-8"))
        bbox = info["bbox_8192"]
        x0, y0 = int(bbox["x0"]), int(bbox["y0"])
        seg = np.load(os.path.join(L2_PACKS, rid, "tiles_8192.npy")).astype(np.int32)
        m = seg > 0
        yy, xx = np.where(m)
        glob8192[y0 + yy, x0 + xx] = seg[yy, xx] + shift
        shift += int(seg.max())
    l1 = np.array(Image.fromarray(glob8192.astype(np.uint32), "I").resize(
        (size, size), Image.NEAREST)).astype(np.int32)
    np.save(os.path.join(OUT_DIR, "legacy_l1_labels_%d.npy" % size), l1)
    return l1


def claim_radius_of(suit_px, sp):
    """聚落主张半径（8192 级像素）= min(泊松盘半径, claim_cap_px)。

    泊松盘半径公式与 settlement_build.radius_at 同式（suit 采样自 2048 宜居度场
    bilinear）；suit ≤ suit_min 的聚落不存在（选址阈值），防御返回 r_max。"""
    suit_min = float(sp["suit_min"])
    r_min, r_max = float(sp["r_min_px"]), float(sp["r_max_px"])
    curve = float(sp["radius_curve"])
    cap = float(sp["claim_cap_px"])
    scale = float(sp.get("claim_scale", 1.0))
    suit = float(suit_px)
    if suit <= suit_min:
        return cap * scale
    t = (suit - suit_min) / (1.0 - suit_min)
    r = r_max - (r_max - r_min) * (t ** curve)
    return min(r, cap) * scale


def load_settlement_seeds(parent, sp):
    """settlements_v2 → (seeds[Nx2 float64 xy], labels[N], claim_r[N])。

    落水聚落（round 后像素不在老 L1 陆地）吸附到最近老 L1 像素（环形扫描）。"""
    with open(os.path.join(FIELDS_DIR, "settlements_v2.json"), encoding="utf-8") as f:
        st = json.load(f)
    meta = st["_meta"]
    items = st["settlements"]
    # 城名表在 A4 政治产物（political_data_v2.json meta.city_names，构型命名批次产出）
    with open(os.path.join(FIELDS_DIR, "political_data_v2.json"), encoding="utf-8") as f:
        city_names = json.load(f).get("meta", {}).get("city_names", {})
    # 2048 场口径（settlement_build._sub4 同式）：8192 原图 [::4,::4] 抽取后
    # 供 bilinear_at（其按 2048 场索引，直接喂 8192 原图会错位采样）
    suit = np.ascontiguousarray(
        np.load(os.path.join(FIELDS_DIR, "suitability.npy"))[::4, ::4]
    ).astype(np.float32)

    seeds, labels, claims = [], [], []
    n_snap = 0
    for s in items:
        x, y = float(s["x"]), float(s["y"])
        px, py = int(round(x)), int(round(y))
        if parent[py, px] == 0:
            # 吸附最近老 L1 像素（环形扫描，r≤60 必中——聚落贴岸 ±4px）
            found = None
            for r in range(1, 61):
                y0, y1 = max(0, py - r), min(RES, py + r + 1)
                x0, x1 = max(0, px - r), min(RES, px + r + 1)
                win = parent[y0:y1, x0:x1]
                ys, xs = np.where(win > 0)
                if ys.size:
                    d2 = (ys + y0 - y) ** 2 + (xs + x0 - x) ** 2
                    k = int(np.argmin(d2))
                    found = (float(xs[k] + x0), float(ys[k] + y0))
                    break
            if found is None:
                raise RuntimeError("聚落 %s 周围 60px 无老 L1 陆地，无法吸附" % s["settlement_id"])
            x, y = found
            n_snap += 1
        suit_px = sb.bilinear_at(suit, x, y)   # bilinear_at 收 8192 级坐标（内除 K_FIELD）
        if int(s.get("level", 1)) == 0:
            # 缝隙填充点（规模 0）：主张盘强制满半径 cap×scale——其使命是把
            # 地图铺满无残缝，不随宜居度收缩（与 fill_gap_seeds 的覆盖估算一致）
            claims.append(float(sp["claim_cap_px"]) * float(sp.get("claim_scale", 1.0)))
        else:
            claims.append(claim_radius_of(suit_px, sp))
        seeds.append([x, y])
        labels.append(int(s["label"]))
    print("  聚落 %d 个（落水吸附 %d）" % (len(seeds), n_snap))
    return (np.array(seeds, dtype=np.float64), np.array(labels, dtype=np.int64),
            np.array(claims, dtype=np.float64), meta, items, city_names)


def grow_cities(land, parent, seeds, seed_labels):
    """老 L1 分组「最近聚落抗衡」（EDT）：
    - 每分量内每像素归「欧氏最近的聚落种子」——平面多源膨胀的等价快算
      （平地上 watershed 膨胀 = 欧氏 Voronoi，一次距离变换出全图）；
    - 无聚落分量不兜底撒点，直接留 0（荒地）；
    - label = 聚落 label（不再分配新 id）。"""
    size = land.shape[0]
    labels = np.zeros((size, size), dtype=np.int32)
    seeds_by_parent = {}
    for i in range(len(seeds)):
        seeds_by_parent.setdefault(int(parent[int(seeds[i][1]), int(seeds[i][0])]),
                                   []).append(i)
    empty_parents = 0
    for plab in np.unique(parent[parent > 0]):
        pmask = parent == plab
        py_, px_ = np.nonzero(pmask)
        y0p, y1p = int(py_.min()), int(py_.max())
        x0p, x1p = int(px_.min()), int(px_.max())
        sub_pmask = pmask[y0p:y1p + 1, x0p:x1p + 1].copy()
        pcomp, npc = ndi.label(sub_pmask, structure=STRUCT8)
        seeds_plab = seeds_by_parent.get(int(plab), [])
        for k in range(1, npc + 1):
            cmask = pcomp == k
            idxs = [i for i in seeds_plab
                    if cmask[int(seeds[i][1]) - y0p, int(seeds[i][0]) - x0p]]
            if not idxs:
                empty_parents += 1
                continue
            markers = np.zeros(cmask.shape, dtype=np.int32)
            for gi, sidx in enumerate(idxs):
                px = int(seeds[sidx][0]) - x0p
                py = int(seeds[sidx][1]) - y0p
                markers[py, px] = int(seed_labels[sidx])
            _, inds = ndi.distance_transform_edt(markers == 0,
                                                 return_indices=True)
            seg = markers[inds[0], inds[1]]
            sub = labels[y0p:y1p + 1, x0p:x1p + 1]
            m = cmask & (seg > 0)
            sub[m] = seg[m]
    if empty_parents:
        print("  无聚落连通分量 %d 个 → 荒地" % empty_parents)
    return labels


def cap_by_claim(labels, seeds, seed_labels, claims):
    """主张盘封顶：距自己聚落欧氏距离 > 主张半径的像素退归荒地（label 0）。"""
    lab_of = {int(lb): i for i, lb in enumerate(seed_labels)}
    labs = np.unique(labels[labels > 0])
    removed = 0
    for lb in labs:
        i = lab_of[int(lb)]
        m = labels == lb
        ys, xs = np.nonzero(m)
        y0p, y1p = int(ys.min()), int(ys.max()) + 1
        x0p, x1p = int(xs.min()), int(xs.max()) + 1
        sy, sx = seeds[i][1], seeds[i][0]
        yy, xx = np.mgrid[y0p:y1p, x0p:x1p]
        d2 = (yy - sy) ** 2 + (xx - sx) ** 2
        far = m[y0p:y1p, x0p:x1p] & (d2 > claims[i] ** 2)
        removed += int(far.sum())
        labels[y0p:y1p, x0p:x1p][far] = 0
    return removed


def absorb_gaps(labels, land, area_of, sp, lm):
    """缝隙并入相邻地块——陆地（老 L1 覆盖）内 labels==0 的连通缝 → 并入
    「同陆块邻接地块中面积最小者」（顺带缩小地块面积差）。缝按 4 连通标记、
    邻接地块按陆块过滤：窄海峡对岸的块再近也不并（防群岛跨水染色）；同陆块
    无邻接地块的孤缝保留 0（由撒点给它自己的地块）。返回吸收像素数。"""
    from scipy import ndimage as ndi2
    gaps = (labels == 0) & land
    if not gaps.any():
        return 0
    th = float(sp.get("absorb_max_px", 600.0))  # 极小缝阈值（约地块 1/30）
    lab, n = ndi2.label(gaps)   # 4 连通：缝块不跨对角贴（与陆块 4 连通一致）
    sizes = np.bincount(lab.ravel())
    n_abs = 0
    for k in range(1, n + 1):
        if int(sizes[k]) > th:
            continue  # 大缝/长缝：不并（由 fill_gap_seeds 撒新地块）
        m = lab == k
        ys, xs = np.nonzero(m)
        y0, y1 = max(0, ys.min() - 2), min(labels.shape[0], ys.max() + 3)
        x0, x1 = max(0, xs.min() - 2), min(labels.shape[1], xs.max() + 3)
        win = labels[y0:y1, x0:x1]
        sub = m[y0:y1, x0:x1]
        dil = ndi2.binary_dilation(sub, iterations=2)
        lm_id = int(lm[ys[0], xs[0]])
        neigh = win[(win > 0) & dil & (lm[y0:y1, x0:x1] == lm_id)]
        if neigh.size == 0:
            continue  # 同陆块无邻接地块（孤缝/隔水）保留
        vals = [int(v) for v in np.unique(neigh)]
        best = min(vals, key=lambda v: (area_of.get(v, 1 << 30), v))
        win[sub] = best
        n_abs += int(sub.sum())
    return n_abs


def load_legacy_parent_colors():
    """老 L1 的父色（city_split_v2.load_legacy_parent_colors 同式）。"""
    pc = {}
    shift = 0
    for i in range(1, 14):
        rid = "region_%03d" % i
        view = json.load(open(os.path.join(
            HERE, "output", "l2_view_packs", rid, "l2_world.json"), encoding="utf-8"))
        for t in view["tiles"]:
            pc[shift + int(t["label"])] = list(t["color"])
        shift += max(int(t["label"]) for t in view["tiles"])
    return pc


def city_palette(labels, parent, parent_color):
    """城块配色（v2 同式：父老 L1 色 hue + 面积排名明度）。"""
    palette = {}
    flat_parent = parent.ravel()
    flat_labels = labels.ravel()
    for plab in np.unique(parent[parent > 0]):
        in_p = (flat_parent == plab) & (flat_labels > 0)
        if not in_p.any():
            continue
        labs, counts = np.unique(flat_labels[in_p], return_counts=True)
        order = np.argsort(-counts)
        labs = labs[order]
        m = len(labs)
        base = parent_color.get(int(plab), (170, 170, 170))
        h, s, v = colorsys.rgb_to_hsv(base[0] / 255, base[1] / 255, base[2] / 255)
        for k, lab in enumerate(labs):
            vv = 0.32 + 0.60 * (k + 0.5) / m
            r8, g8, b8 = colorsys.hsv_to_rgb(h, 0.62, vv)
            palette[int(lab)] = (int(r8 * 255), int(g8 * 255), int(b8 * 255))
    for lb in seed_labels:
        palette.setdefault(int(lb), (190, 190, 190))
    return palette


def gap_stats(labels, land, th):
    """陆地 0 区统计：(总px, 陆地%, >th 连通块数, 最大块px)。填缝迭代的收敛判据。"""
    gaps = (labels == 0) & land
    total = int(gaps.sum())
    if total == 0:
        return 0, 0.0, 0, 0
    glab, gn = ndi.label(gaps, structure=STRUCT8)
    sizes = np.bincount(glab.ravel())[1:]
    big = int((sizes > th).sum())
    return total, 100.0 * total / max(int(land.sum()), 1), big, int(sizes.max())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--labels-only", action="store_true",
                    help="只算标签场 + 缝隙统计（填缝迭代用，不写 mesh/预览/JSON）")
    ap.add_argument("--cached-parent", action="store_true",
                    help="复用已落盘的 legacy_l1_labels_%d.npy（同 Packs 前提下确定性一致）" % RES)
    args = ap.parse_args()
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(os.path.join(HERE, "l3", "state_params.json"), encoding="utf-8") as f:
        sp = json.load(f)["fields_v2"]["settlements"]

    print("[1/6] 构建全局老 L1 蒙版（res=%d）..." % RES)
    cache = os.path.join(OUT_DIR, "legacy_l1_labels_%d.npy" % RES)
    if args.cached_parent and os.path.exists(cache):
        parent = np.load(cache)
        print("  复用缓存 %s（老 L1 地块 %d 个）" % (os.path.basename(cache), int(parent.max())))
    else:
        parent = build_legacy_l1_mask(RES)
    n_l1 = int(parent.max())
    land = parent > 0
    print("  老 L1 地块 %d 个，陆地 %.1f%%" % (n_l1, land.mean() * 100))

    print("[2/6] 聚落种子（settlements_v2 + 主张半径）...")
    global seed_labels
    seeds, seed_labels, claims, st_meta, st_items, city_names = load_settlement_seeds(parent, sp)
    by_id = {s["settlement_id"]: s for s in st_items}

    print("[3/6] 按老 L1 分组多源膨胀生长城块 ...")
    labels = grow_cities(land, parent, seeds, seed_labels)

    # 主张盘封顶已退役（创始人 2026-09-27：抗衡即唯一边界）——纯 EDT 划分无缝无灰
    removed = 0
    n_city = len(seed_labels)
    present = set(int(v) for v in np.unique(labels) if v > 0)
    missing = [int(l) for l in seed_labels if int(l) not in present]
    counts = np.bincount(labels.ravel())
    areas = {int(lb): int(counts[lb]) if lb < counts.size else 0 for lb in seed_labels}
    if args.labels_only:
        # 迭代快跑跳过 absorb（≤阈值微缝逐块循环慢，且不影响 >阈值 撒点判据）；
        # 微缝吸收只在全量跑做
        if missing:
            raise RuntimeError("城块缺失（聚落无地盘）: %s" % missing[:10])
        np.save(os.path.join(OUT_DIR, "city_labels_%d.npy" % RES), labels)
        th = float(sp.get("absorb_max_px", 600.0))
        total, pct, big, mx = gap_stats(labels, land, th)
        print("[labels-only] 缝隙：%d px（%.2f%% 陆地）；>%.0fpx² 块 %d 个（最大 %dpx）%s"
              % (total, pct, th, big, mx, "→ 已收敛" if big == 0 else "→ 需继续撒点"))
        return
    lm_land, n_lmass = lmu.landmass_ids(land)
    n_absorbed = absorb_gaps(labels, land, areas, sp, lm_land)
    n_bad, n_refill = lmu.enforce_single_landmass(labels, lm_land)
    if n_bad:
        print("  一城块一陆块收尾：跨陆块清理 %d px（同陆块回填 %d px）"
              % (n_bad, n_refill))
    counts = np.bincount(labels.ravel())
    areas = {int(lb): int(counts[lb]) if lb < counts.size else 0 for lb in seed_labels}
    print("  缝隙并入相邻地块 %d px（陆地 0 区清零）" % n_absorbed)
    tiny = [lb for lb, a in areas.items() if a < 40]
    land_px = int(land.sum())
    wild_px = land_px - int((labels > 0).sum())
    print("  封顶退地 %d px；城块 %d/%d 在场；荒地 %.1f%% 陆地；<40px 城块 %d %s"
          % (removed, len(present), n_city, wild_px / max(land_px, 1) * 100,
             len(tiny), tiny[:8]))
    if missing:
        raise RuntimeError("城块缺失（聚落无地盘）: %s" % missing[:10])

    print("[5/6] 多边形 + 邻接 + 配色 ...")
    mesh = mesh_extract.simplify_mesh(mesh_extract.extract_mesh(labels))
    padded = np.pad(labels, 1, mode="constant")
    adj = {int(lb): set() for lb in seed_labels}
    yy, xx = np.where(padded[1:-1, 1:-1] > 0)
    for y, x in zip(yy, xx):
        v = padded[y + 1, x + 1]
        for dy, dx in ((1, 0), (0, 1)):
            w = padded[y + 1 + dy, x + 1 + dx]
            if w > 0 and w != v:
                adj[int(v)].add(int(w))
                adj[int(w)].add(int(v))
    parent_color = load_legacy_parent_colors()
    palette = city_palette(labels, parent, parent_color)

    print("[6/6] 写文件 ...")
    # 预览：海洋底 + 荒地中性灰 + 城块配色 + 聚落点
    preview = np.zeros((RES, RES, 3), dtype=np.uint8)
    preview[land] = WASTELAND_COLOR
    for lb, rgb in palette.items():
        m = labels == lb
        if m.any():
            preview[m] = rgb
    prev_img = Image.fromarray(preview)
    from PIL import ImageDraw as _ID
    dr = _ID.Draw(prev_img)
    dot_r = 3
    for i, (cx, cy) in enumerate(seeds):
        x, y = float(cx), float(cy)
        dr.ellipse([x - dot_r, y - dot_r, x + dot_r, y + dot_r],
                   outline=(12, 12, 12), width=1)
        dr.ellipse([x - 1, y - 1, x + 1, y + 1], fill=(250, 250, 250))
    prev_img.save(os.path.join(OUT_DIR, "city_preview_%d.png" % RES))

    idx_img = np.zeros((RES, RES, 3), dtype=np.uint8)
    idx_img[labels > 0, 0] = (labels[labels > 0] >> 16) & 0xFF
    idx_img[labels > 0, 1] = (labels[labels > 0] >> 8) & 0xFF
    idx_img[labels > 0, 2] = labels[labels > 0] & 0xFF
    Image.fromarray(idx_img).save(os.path.join(OUT_DIR, "city_partition_%d.png" % RES))

    city_img = np.full((RES, RES, 3), 235, dtype=np.uint8)
    city_img[land, :] = 220
    box = 5
    for (cx, cy) in seeds:
        x0c, y0c = int(cx) - box // 2, int(cy) - box // 2
        city_img[max(0, y0c):y0c + box, max(0, x0c):x0c + box, 0] = 200
        city_img[max(0, y0c):y0c + box, max(0, x0c):x0c + box, 1] = 40
        city_img[max(0, y0c):y0c + box, max(0, x0c):x0c + box, 2] = 40
    Image.fromarray(city_img).save(os.path.join(OUT_DIR, "city_cities_%d.png" % RES))

    np.save(os.path.join(OUT_DIR, "city_labels_%d.npy" % RES), labels)

    def _decimate(loop):
        xy = [(float(p[1]), float(p[0])) for p in loop]
        pts = mesh_extract._dp_simplify(xy, 0.3)
        return [[p[0], p[1]] for p in pts]

    cities_out = []
    for i, lb in enumerate(seed_labels):
        lb = int(lb)
        m = labels == lb
        ys, xs = np.where(m)
        rings = [list(list(p) for p in loop) for loop in mesh.get(lb, {}).get("outer", [])]
        polys = [_decimate(r) for r in rings if len(r) >= 3]
        sid = "settlement_city_%03d" % lb
        src = by_id[sid]
        cities_out.append({
            "label": lb,
            "settlement_id": sid,
            "parent_l1": int(parent[int(ys[0]), int(xs[0])]) if ys.size else 0,
            "city": [round(float(seeds[i][0]), 3), round(float(seeds[i][1]), 3)],
            "centroid": [round(float(xs.mean()), 3), round(float(ys.mean()), 3)],
            "area_px": int(m.sum()),
            "rgb": list(palette[lb]),
            "polygon": polys[0] if polys else [],
            "polygons": polys,
            "neighbors": sorted(x for x in adj[lb] if x > 0),
            "claim_r": round(float(claims[i]), 2),
            "level": int(src["level"]),
            "population_score": float(src["population_score"]),
            "name": str(city_names.get(sid, "")),
        })
    out = {
        "name": "全大陆城市蒙版 v3（世界重生成 v2 聚落表 + 主张盘封顶，无主荒地语义）",
        "algorithm": "settlements-v3（v2 聚落种子 + 老 L1 分组多源膨胀 + 主张盘封顶退地）",
        "size": RES,
        "coord": "xy@%d" % RES,
        "claim_cap_px": sp["claim_cap_px"],
        "n_legacy_l1": n_l1,
        "n_city": n_city,
        "wilderness_px": wild_px,
        "land_px": land_px,
        "cities": cities_out,
    }
    with open(os.path.join(OUT_DIR, "city_data.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)

    print("完成。城块=%d 荒地=%.1f%% 最小城块=%dpx 最大=%dpx"
          % (n_city, wild_px / max(land_px, 1) * 100,
             min(areas.values()), max(areas.values())))


if __name__ == "__main__":
    main()
