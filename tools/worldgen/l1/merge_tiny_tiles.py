"""把小于"L3 陆地总面积 0.5%"的地块并入同 L2 地区内质心最近的地块（岛屿也不例外）。

迭代合并直到无小于阈值的地块（或仅剩一块）。预览保持各地区风格：
- 岛屿色地区（region_009/010/011，配置 ISLAND_COLOR_REGIONS）：每岛一色、无内部描边
- 其他地区：地块上色 + 边界描边

用法：
  python tools/worldgen/l1/merge_tiny_tiles.py
"""
import argparse
import json
import os

import numpy as np
from PIL import Image
from scipy import ndimage as ndi
from skimage.measure import find_contours

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
L2_DIR = os.path.join(HERE, "output", "l2_packs")
MIN_L3_FRAC = 0.001  # L3 全局最小地块占比
# 特写预览统一用"地块着色"（与全局预览一致）；岛屿色已弃用
ISLAND_COLOR_REGIONS = set()


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


def write_tiles_json(rdir, rid, seg, lab, total):
    tiles = []
    for k in range(1, int(seg.max()) + 1):
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
            "tile_id": "%s_tile_%02d" % (rid, k),
            "label": k,
            "area_px": int(m.sum()),
            "area_ratio": float(m.sum() / total),
            "centroid": [float(xs.mean()), float(ys.mean())],
            "polygon": poly or [],
        })
    tiles.sort(key=lambda t: -t["area_ratio"])
    tiles_data = {"region_id": rid, "label": lab, "n_tiles": int(seg.max()), "tiles": tiles}
    with open(os.path.join(rdir, "tiles.json"), "w", encoding="utf-8") as f:
        json.dump(tiles_data, f, ensure_ascii=False, indent=1)


def write_preview(rdir, seg, mask, island_color):
    h, w = mask.shape
    base = np.array(Image.open(os.path.join(rdir, "base_8192.png"))).astype(np.float32)
    overlay = base.copy()
    if island_color:
        # 岛屿着色：无内部描边
        islands, n_islands = ndi.label(mask)
        colors = unique_colors(n_islands)
        for iid in range(1, n_islands + 1):
            im = islands == iid
            c = colors[iid - 1]
            overlay[im] = overlay[im] * 0.45 + np.array(c, dtype=np.float32) * 0.55
    else:
        n_tiles = int(seg.max())
        colors = unique_colors(n_tiles)
        for k in range(1, n_tiles + 1):
            c = colors[k - 1]
            m = seg == k
            overlay[m] = overlay[m] * 0.5 + np.array(c, dtype=np.float32) * 0.5
        edge = np.zeros((h, w), dtype=bool)
        edge[:, :-1] |= seg[:, :-1] != seg[:, 1:]
        edge[:-1, :] |= seg[:-1, :] != seg[1:, :]
        edge &= seg > 0
        overlay[edge] = (255, 220, 120)
    Image.fromarray(overlay.astype(np.uint8)).save(os.path.join(rdir, "tiles_preview_8192.png"))


def main():
    p = argparse.ArgumentParser(description="合并小于 L3 全局阈值的微小地块")
    p.add_argument("--frac", type=float, default=MIN_L3_FRAC,
                   help="L3 全局最小地块占比（默认 0.001 = 0.1%%）")
    p.add_argument("--regions", type=str, default="",
                   help="只处理指定地区（逗号分隔）")
    p.add_argument("--target-n", type=int, default=0,
                   help="合并到目标地块数（>0 时忽略阈值，一直合并到该数量）")
    args = p.parse_args()
    min_l3_frac = args.frac
    target_n = args.target_n
    all_region_dirs = sorted(d for d in os.listdir(L2_DIR) if d.startswith("region_"))
    region_dirs = all_region_dirs
    if args.regions:
        wanted = set(args.regions.split(","))
        region_dirs = [d for d in region_dirs if d in wanted]
    # L3 陆地总面积（始终基于全部地区）
    total_land = 0
    for rid in all_region_dirs:
        m = np.array(Image.open(os.path.join(L2_DIR, rid, "mask_8192.png"))) > 0
        total_land += int(m.sum())
    min_px = total_land * min_l3_frac
    print("L3 陆地总面积 %d px, %.3f%% 阈值 = %d px" % (total_land, min_l3_frac * 100, min_px))

    for rid in region_dirs:
        rdir = os.path.join(L2_DIR, rid)
        mask = np.array(Image.open(os.path.join(rdir, "mask_8192.png"))) > 0
        seg = np.load(os.path.join(rdir, "tiles_8192.npy"))
        seg[~mask] = 0
        info = json.load(open(os.path.join(rdir, "info.json"), encoding="utf-8"))
        total = int(mask.sum())

        # 规则：独立岛屿（无相邻地块）不合并；大陆上 < 阈值的地块
        # 并入"邻居中面积最小"的地块（两块小的抱团达标后即停止）
        merged = 0
        for _ in range(200):
            sizes = np.bincount(seg.ravel())
            active = np.unique(seg)
            active = active[active > 0]
            n_cur = len(active)
            if target_n and n_cur <= target_n:
                break
            # 找最小的"大陆小块"（有邻居且 < 阈值；--target-n 模式不限制阈值）
            k = None
            best_sz = min_px if not target_n else sizes.max()
            for cand in active:
                if not target_n and sizes[cand] >= min_px:
                    continue
                m = seg == cand
                padded = np.pad(m, 1)
                neigh = ((padded[1:-1, 0:-2] | padded[1:-1, 2:] |
                          padded[0:-2, 1:-1] | padded[2:, 1:-1]) & (seg > 0) & ~m)
                nids = np.unique(seg[neigh])
                if nids.size == 0:
                    continue  # 孤岛：不合并
                if sizes[cand] < best_sz:
                    best_sz = sizes[cand]
                    k = cand
            if k is None:
                break
            # k 的邻居中面积最小的
            m = seg == k
            padded = np.pad(m, 1)
            neigh = ((padded[1:-1, 0:-2] | padded[1:-1, 2:] |
                      padded[0:-2, 1:-1] | padded[2:, 1:-1]) & (seg > 0) & ~m)
            nids = np.unique(seg[neigh])
            tgt = min(nids, key=lambda n: sizes[int(n)])
            seg[m] = tgt
            merged += 1
        if merged:
            # 重编号压缩
            unique_labs = [int(v) for v in np.unique(seg) if v != 0]
            renum = {old: i + 1 for i, old in enumerate(unique_labs)}
            new_seg = np.zeros_like(seg)
            for old, new in renum.items():
                new_seg[seg == old] = new
            seg = new_seg
            np.save(os.path.join(rdir, "tiles_8192.npy"), seg)
            write_tiles_json(rdir, rid, seg, info["label"], total)
            write_preview(rdir, seg, mask, rid in ISLAND_COLOR_REGIONS)
        print("%s: 合并 %d 个微小地块, 剩 %d 块" % (rid, merged, int(seg.max())))

    print("完成。")


if __name__ == "__main__":
    main()
