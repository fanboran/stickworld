"""L2 地图内部分块 —— 每个 L2 地区自然碎开成若干地块（L1 级）。

方法：
  1. 连通分量预处理：L2 地区 mask 拆成若干岛屿
     - 大岛（>= 6% 地区面积）：单独作为地块（不参与分块）
     - 碎岛（<= 0.5% 地区面积，几十~几百像素）：并入最近大陆地块
     - 中间岛：独立成地块
  2. 大陆主体分块：watershed + 地形场
     - 场 = 起伏度（山脊=高值=边界） + 河流/湖泊屏障 + 噪声扰动
     - 河流/湖泊作为实际分界线（屏障像素强制成为边界）
     - 噪声让平原区边界随机自然（非直线）
  3. 合并过小碎片（< 1.5% 并入相邻最大块）
  4. 产出：地块标签图 .npy + 预览 PNG + tiles.json

用法：
  python tools/worldgen/export_l2_maps.py
"""
import argparse
import json
import os

import numpy as np
from PIL import Image
from scipy import ndimage as ndi
from scipy.ndimage import distance_transform_edt
from skimage.measure import find_contours
from skimage.segmentation import watershed

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
L2_DIR = os.path.join(HERE, "output", "l2_packs")
REGIONS_DIR = os.path.join(HERE, "output", "regions")
BACKUP_DIR = os.path.join(HERE, "output", "regions_backup_v2")
OUT_ROOT = os.path.join(HERE, "output")

# 岛屿分类阈值（占 L2 地区面积比例）
BIG_ISLAND_FRAC = 0.06      # >= 此比例：单独成地块
SMALL_ISLAND_FRAC = 0.005   # <= 此比例：碎岛，并入最近大陆
# 分块参数
SEED_FRAC = 0.04            # 每约 4% 面积一个种子
MIN_TILE_FRAC = 0.03        # 地块最小面积占比（< 并入相邻最大块）
MAX_TILE_FRAC = 0.22        # 地块最大面积占比（> 拆分，岛屿单独块除外）
MIN_L3_FRAC = 0.0           # L3 全局最小地块占比（0 = 禁用，按地区相对值拆分）
MAX_L3_FRAC = 0.05          # L3 全局最大地块占比（跨地区统一）
MAX_REGION_FRAC = 0.5       # 下限按地区上调的上限（小地区可允许一块占 50%）
MAX_SPLIT_ROUNDS = 4        # 超上限拆分的递归轮数上限
# 噪声（让边界随机自然）
NOISE_SCALE = 0.15          # 噪声振幅（相对场归一化）
NOISE_OCTAVES = 3


def unique_colors(n):
    colors = []
    for i in range(n):
        h = (i * 0.618033988749895) % 1.0
        s = 0.65 + 0.2 * ((i * 7) % 3) / 2.0
        l = 0.45 + 0.25 * ((i * 11) % 3) / 2.0
        c = (1 - abs(2 * l - 1)) * s
        x = c * (1 - abs((h * 6) % 2 - 1))
        m = l - c / 2
        if h < 1 / 6: r, g, b = c, x, 0
        elif h < 2 / 6: r, g, b = x, c, 0
        elif h < 3 / 6: r, g, b = 0, c, x
        elif h < 4 / 6: r, g, b = 0, x, c
        elif h < 5 / 6: r, g, b = x, 0, c
        else: r, g, b = c, 0, x
        colors.append((int((r + m) * 255), int((g + m) * 255), int((b + m) * 255)))
    return colors


def make_value_noise(shape, seed, scale=0.15, octaves=3):
    """确定性多倍频值噪声（0-1），用于让平原边界随机自然。"""
    rng = np.random.default_rng(seed)
    h, w = shape
    noise = np.zeros(shape, dtype=np.float32)
    amp = 1.0
    total = 0.0
    for o in range(octaves):
        freq = 8 * (2 ** o)
        rh = max(4, h // freq)
        rw = max(4, w // freq)
        coarse = rng.random((rh, rw)).astype(np.float32)
        coarse_img = Image.fromarray((coarse * 255).astype(np.uint8)).resize((w, h), Image.BILINEAR)
        noise += amp * (np.array(coarse_img).astype(np.float32) / 255.0 - 0.5)
        total += amp
        amp *= 0.5
    return noise / total * scale


def split_continents_watershed(mask, relief, barrier, noise, n_seeds, seed=0):
    """大陆主体 watershed 分块：场 = 起伏 + 屏障 + 噪声。"""
    h, w = mask.shape
    # 场：屏障（河流/湖泊）高值 -> 边界强制
    field = relief.copy()
    field = field / max(field.max(), 1e-6)  # 0-1
    field = field + noise  # 噪声扰动（±0.15）
    field[barrier] = 3.0  # 河流/湖泊屏障：最高值，watershed 边界必沿此

    # 种子：网格均匀撒在 field 低处（盆地中心，避开屏障）；
    # 网格不足 n_seeds 时（异形块）用随机像素补足
    ys_all, xs_all = np.where(mask)
    if ys_all.size == 0:
        return np.zeros(mask.shape, dtype=np.int32)
    y0m, y1m = ys_all.min(), ys_all.max()
    x0m, x1m = xs_all.min(), xs_all.max()
    grid_n = max(2, int(np.ceil(np.sqrt(n_seeds))))
    seeds = []
    for gy in range(grid_n):
        for gx in range(grid_n):
            gy0 = y0m + (y1m - y0m) * gy // grid_n
            gy1 = y0m + (y1m - y0m) * (gy + 1) // grid_n
            gx0 = x0m + (x1m - x0m) * gx // grid_n
            gx1 = x0m + (x1m - x0m) * (gx + 1) // grid_n
            cell = (ys_all >= gy0) & (ys_all < gy1) & (xs_all >= gx0) & (xs_all < gx1)
            if not cell.any():
                continue
            # 找 cell 内 field 最低点（避开屏障）
            cell_field = field[ys_all[cell], xs_all[cell]]
            idx = int(np.argmin(cell_field))
            seeds.append((ys_all[cell][idx], xs_all[cell][idx]))
    # 随机补足：异形块网格 cell 可能空，种子不足时随机撒点
    rng = np.random.default_rng(seed)
    if len(seeds) < n_seeds:
        valid = [(ys_all[i], xs_all[i]) for i in range(ys_all.size)
                 if not barrier[ys_all[i], xs_all[i]]]
        if valid:
            perm = rng.permutation(len(valid))
            for pi in perm:
                if len(seeds) >= n_seeds:
                    break
                seeds.append(valid[pi])
    seeds = list(dict.fromkeys(seeds))
    if len(seeds) < 2:
        return np.zeros(mask.shape, dtype=np.int32)

    markers = np.zeros(mask.shape, dtype=np.int32)
    for k, (sy, sx) in enumerate(seeds):
        if mask[sy, sx] and not barrier[sy, sx]:
            markers[sy, sx] = k + 1
    seg = watershed(field, markers, mask=mask)
    return seg


def main():
    p = argparse.ArgumentParser(description="L2 地图内部分块")
    p.add_argument("--min-frac", type=float, default=MIN_TILE_FRAC)
    p.add_argument("--max-frac", type=float, default=MAX_TILE_FRAC)
    p.add_argument("--min-l3-frac", type=float, default=MIN_L3_FRAC)
    p.add_argument("--max-l3-frac", type=float, default=MAX_L3_FRAC)
    p.add_argument("--regions", type=str, default="",
                   help="只处理指定地区（逗号分隔，如 region_003,region_004）")
    p.add_argument("--max-mult", type=float, default=1.0,
                   help="地块上限比例倍率（如 1.1 = 上限调高 10%）")
    args = p.parse_args()
    min_frac = args.min_frac
    max_frac = args.max_frac
    min_l3 = args.min_l3_frac
    max_l3 = args.max_l3_frac
    max_mult = args.max_mult

    # 河流/湖泊 8192 屏障
    river = np.array(Image.open(os.path.join(OUT_ROOT, "fractal_river_mask_8192.png"))) > 0
    lake = np.array(Image.open(os.path.join(OUT_ROOT, "fractal_lake_mask_8192.png"))) > 0

    all_region_dirs = sorted(d for d in os.listdir(L2_DIR) if d.startswith("region_"))

    # 各地区占 L3 陆地比例（分母始终用全部地区总面积，与 --regions 过滤无关）
    region_l3_frac = {}
    total_land = 0
    for rid_dir in all_region_dirs:
        m = np.array(Image.open(os.path.join(L2_DIR, rid_dir, "mask_8192.png"))) > 0
        region_l3_frac[rid_dir] = int(m.sum())
        total_land += int(m.sum())
    for rid_dir in all_region_dirs:
        region_l3_frac[rid_dir] = region_l3_frac[rid_dir] / total_land

    region_dirs = all_region_dirs
    if args.regions:
        wanted = set(args.regions.split(","))
        region_dirs = [d for d in region_dirs if d in wanted]
        print("[1/4] 只处理 %d 个指定地区" % len(region_dirs))
    else:
        print("[1/4] 发现 %d 个 L2 地区目录" % len(region_dirs))

    for rid_dir in region_dirs:
        rdir = os.path.join(L2_DIR, rid_dir)
        info = json.load(open(os.path.join(rdir, "info.json"), encoding="utf-8"))
        lab = info["label"]
        bbox = info["bbox_8192"]
        x0, y0, x1, y1 = bbox["x0"], bbox["y0"], bbox["x1"], bbox["y1"]
        w, h = x1 - x0 + 1, y1 - y0 + 1
        print("\n[%s] L%02d (%dx%d)" % (rid_dir, lab, w, h))

        height = np.load(os.path.join(rdir, "heightmap_8192.npy"))
        mask = np.array(Image.open(os.path.join(rdir, "mask_8192.png"))) > 0
        assert mask.shape == height.shape, (mask.shape, height.shape)

        # 起伏度场
        relief = ndi.maximum_filter(height, size=15) - ndi.minimum_filter(height, size=15)
        # 河流/湖泊屏障（裁切）
        barrier = np.zeros(mask.shape, dtype=bool)
        barrier |= river[y0:y1 + 1, x0:x1 + 1]
        barrier |= lake[y0:y1 + 1, x0:x1 + 1]
        barrier &= mask  # 只在地内生效

        total = int(mask.sum())
        area = total
        # L3 全局统一换算：小地区下限上调（允许单块占 50% 地区），上限保底 >= 2x 下限
        l3f = region_l3_frac[rid_dir]
        min_r = max(min_frac, min(MAX_REGION_FRAC, min_l3 / l3f))
        max_r = max(max_frac, min_r * 2) * max_mult
        print("  地区面积 %d px (占L3 %.2f%%), 地块区间 %.1f%% ~ %.1f%%（L3 %.3f%% ~ %.3f%%）" % (
            area, l3f * 100, min_r * 100, max_r * 100, min_l3 * 100, max_l3 * 100))

        # [1] 连通分量预处理：岛屿分类
        labels_island, n_islands = ndi.label(mask)
        island_sizes = np.bincount(labels_island.ravel())[1:]
        big_islands = []    # 单独成地块
        mid_islands = []    # 独立地块
        small_islands = []  # 碎岛并入最近
        for iid, sz in enumerate(island_sizes, start=1):
            frac = sz / area
            if frac >= BIG_ISLAND_FRAC:
                big_islands.append(iid)
            elif frac <= SMALL_ISLAND_FRAC:
                small_islands.append(iid)
            else:
                mid_islands.append(iid)
        print("  岛屿 %d 个：大岛(单独) %d, 中岛(独立) %d, 碎岛(并入) %d" % (
            n_islands, len(big_islands), len(mid_islands), len(small_islands)))

        # [2] 大陆主体 = 所有大岛并集（内部分块）
        seg = np.zeros(mask.shape, dtype=np.int32)
        tile_id = 0
        # 中岛：每个独立成地块
        for iid in mid_islands:
            tile_id += 1
            seg[labels_island == iid] = tile_id
        # 大岛：watershed 内部分块
        mainland = np.isin(labels_island, big_islands)
        if mainland.any():
            n_seeds = max(4, int(round(1.0 / max(min_r, SEED_FRAC))))
            noise = make_value_noise(mask.shape, seed=lab * 1000 + x0, scale=NOISE_SCALE, octaves=NOISE_OCTAVES)
            seg_main = split_continents_watershed(mainland, relief, barrier, noise, n_seeds, seed=lab * 1000 + x0)
            for k in range(1, int(seg_main.max()) + 1):
                m = seg_main == k
                if m.any():
                    tile_id += 1
                    seg[m] = tile_id
        n_tiles = tile_id
        # 中岛独立块 label：不参与超上限拆分（自然岛屿）
        island_tiles = set(range(1, len(mid_islands) + 1))
        print("  分块后 %d 个地块（中岛 %d + 大陆分块）" % (n_tiles, len(mid_islands)))

        # [3] 碎岛并入最近地块
        merged_small = 0
        for iid in small_islands:
            m = labels_island == iid
            ys, xs = np.where(m)
            if ys.size == 0:
                continue
            # 找最近已有地块（质心距离）
            cy, cx = ys.mean(), xs.mean()
            best_t, best_d = None, np.inf
            for k in range(1, n_tiles + 1):
                km = seg == k
                kys, kxs = np.where(km)
                if kys.size == 0:
                    continue
                d = (kys.mean() - cy) ** 2 + (kxs.mean() - cx) ** 2
                if d < best_d:
                    best_d = d
                    best_t = k
            if best_t is not None:
                seg[m] = best_t
                merged_small += 1
        if merged_small:
            print("  碎岛并入 %d 个" % merged_small)

        # [4] 合并过小碎片（< min_r 并入相邻块）
        def merge_small():
            min_area = area * min_r
            # 合并/拆分统一使用同一上限阈值，避免 merge 造出超限块被拆的死循环
            max_merge_area = area * max_r * 1.2
            for _ in range(5):
                sizes = np.bincount(seg.ravel())
                merged_any = False
                n_cur = int(seg.max())
                for k in range(1, n_cur + 1):
                    if k in island_tiles:
                        continue  # 中岛例外，不参与合并
                    if k >= len(sizes) or sizes[k] >= min_area:
                        continue
                    m = seg == k
                    padded = np.pad(m, 1)
                    neigh = ((padded[1:-1, 0:-2] | padded[1:-1, 2:] |
                              padded[0:-2, 1:-1] | padded[2:, 1:-1]) & (seg > 0) & ~m)
                    neigh_ids = np.unique(seg[neigh])
                    if neigh_ids.size == 0:
                        # 孤立碎片（拆分时从大块分离出的碎岛）：并入质心最近块
                        #（极小且岛屿性质，允许略超上限；并后超限的邻居不选）
                        ys, xs = np.where(m)
                        if ys.size == 0:
                            continue
                        cy, cx = ys.mean(), xs.mean()
                        best_t, best_d = None, np.inf
                        for nid in range(1, n_cur + 1):
                            if nid == k:
                                continue
                            nid_m = seg == nid
                            if not nid_m.any():
                                continue
                            if sizes[int(nid)] + sizes[k] > max_merge_area:
                                continue
                            nys, nxs = np.where(nid_m)
                            d = (nys.mean() - cy) ** 2 + (nxs.mean() - cx) ** 2
                            if d < best_d:
                                best_d, best_t = d, nid
                        if best_t is None:
                            # 所有块都太满：退回无条件并入质心最近块（极小碎片，可容忍）
                            for nid in range(1, n_cur + 1):
                                if nid == k:
                                    continue
                                nid_m = seg == nid
                                if not nid_m.any():
                                    continue
                                nys, nxs = np.where(nid_m)
                                d = (nys.mean() - cy) ** 2 + (nxs.mean() - cx) ** 2
                                if d < best_d:
                                    best_d, best_t = d, nid
                        if best_t is None:
                            continue
                        v = sizes[k]
                        seg[m] = best_t
                        sizes[k] = 0
                        sizes[int(best_t)] += v
                        merged_any = True
                        continue
                    # 只并给"并后不超上限"的最小邻居；
                    cands = [nid for nid in neigh_ids
                             if sizes[int(nid)] + sizes[k] <= max_merge_area]
                    if not cands:
                        # 所有邻居并入都会超限：并入面积最大的邻居，
                        # 接受软上限溢出（oversized 阈值 max_r*1.26 保证不再被拆）
                        best = max(neigh_ids, key=lambda nid: sizes[int(nid)])
                        v = sizes[k]
                        seg[m] = best
                        sizes[k] = 0
                        sizes[int(best)] += v
                        merged_any = True
                        continue
                    best = min(cands, key=lambda nid: sizes[int(nid)])
                    v = sizes[k]
                    seg[m] = best
                    sizes[k] = 0
                    sizes[int(best)] += v
                    merged_any = True
                if not merged_any:
                    break

        # [5] 下限合并与上限拆分交替，直到无超限块
        # 拆分阈值比 merge 上限稍宽（max_r * 1.26）：让"碎片并入后略超上限"的
        # 组合稳定落地，避免拆-并死循环；merge 造出的块永不触发拆分
        max_area = area * max_r * 1.26
        split_count = 0
        for _ in range(MAX_SPLIT_ROUNDS + 3):
            merge_small()
            sizes = np.bincount(seg.ravel())
            oversized = [k for k in range(1, int(seg.max()) + 1)
                         if k not in island_tiles and sizes[k] > max_area]
            if not oversized:
                break
            for k in oversized:
                m = seg == k
                karea = sizes[k]
                n_seeds = max(3, int(round(1.0 / max(min_r, SEED_FRAC))))
                sub = split_continents_watershed(m, relief, barrier, noise, n_seeds, seed=lab * 1000 + x0 + k)
                submax = int(sub.max())
                if submax < 2:
                    continue  # 拆不开（如种子不足）保持原块
                next_id = int(seg.max()) + 1
                seg[m] = 0
                for j in range(1, submax + 1):
                    sm = sub == j
                    if sm.any():
                        seg[sm] = next_id
                        next_id += 1
                split_count += 1
        # 兜底：最后若停在"刚拆完"状态，再合并一次碎片
        merge_small()
        if split_count:
            print("  超上限拆分 %d 块" % split_count)
        n_tiles = int(seg.max())
        seg[~mask] = 0
        # 重编号压缩（碎片合并后 label 可能有空洞）
        unique_labs = [int(v) for v in np.unique(seg) if v != 0]
        renum = {old: i + 1 for i, old in enumerate(unique_labs)}
        new_seg = np.zeros_like(seg)
        for old, new in renum.items():
            new_seg[seg == old] = new
        seg = new_seg
        n_tiles = int(seg.max())

        # 地块元数据
        tiles = []
        for k in range(1, n_tiles + 1):
            m = seg == k
            if not m.any():
                continue
            contours = find_contours(m.astype(np.uint8), 0.5)
            poly = None
            if contours:
                c = contours[0]
                step = max(1, len(c) // 60)
                poly = [[float(x), float(y)] for x, y in c[::step]]
            ys, xs = np.where(m)
            tiles.append({
                "tile_id": "%s_tile_%02d" % (rid_dir, k),
                "label": k,
                "area_px": int(m.sum()),
                "area_ratio": float(m.sum() / total),
                "centroid": [float(xs.mean()), float(ys.mean())],
                "polygon": poly or [],
            })
        tiles.sort(key=lambda t: -t["area_ratio"])

        np.save(os.path.join(rdir, "tiles_8192.npy"), seg)
        colors = unique_colors(n_tiles)
        base = np.array(Image.open(os.path.join(rdir, "base_8192.png"))).astype(np.float32)
        overlay = base.copy()
        for k in range(1, n_tiles + 1):
            c = colors[k - 1]
            m = seg == k
            overlay[m] = overlay[m] * 0.5 + np.array(c, dtype=np.float32) * 0.5
        edge = np.zeros((h, w), dtype=bool)
        edge[:, :-1] |= seg[:, :-1] != seg[:, 1:]
        edge[:-1, :] |= seg[:-1, :] != seg[1:, :]
        overlay[edge] = (255, 220, 120)
        Image.fromarray(overlay.astype(np.uint8)).save(os.path.join(rdir, "tiles_preview_8192.png"))

        tiles_data = {"region_id": rid_dir, "label": lab, "n_tiles": n_tiles, "tiles": tiles}
        with open(os.path.join(rdir, "tiles.json"), "w", encoding="utf-8") as f:
            json.dump(tiles_data, f, ensure_ascii=False, indent=1)
        print("  -> %d 个地块, 预览 tiles_preview_8192.png" % len(tiles))

    print("\n完成。")


if __name__ == "__main__":
    main()
