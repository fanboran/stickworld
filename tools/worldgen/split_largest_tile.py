"""把指定 L2 地区面积最大的地块沿最远两点切成两块（均衡），更新 tiles.json 与预览图。

用法：
  python tools/worldgen/split_largest_tile.py region_008
"""
import json
import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage as ndi
from skimage.measure import find_contours
from skimage.segmentation import watershed

HERE = os.path.dirname(os.path.abspath(__file__))
L2_DIR = os.path.join(HERE, "output", "l2_packs")


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


def main():
    rid = sys.argv[1] if len(sys.argv) > 1 else "region_008"
    rdir = os.path.join(L2_DIR, rid)
    seg = np.load(os.path.join(rdir, "tiles_8192.npy"))
    mask = np.array(Image.open(os.path.join(rdir, "mask_8192.png"))) > 0
    seg[~mask] = 0
    h, w = mask.shape

    sizes = np.bincount(seg.ravel())
    k = int(np.argmax(sizes[1:])) + 1
    m = seg == k
    print("%s 最大地块 label=%d 面积 %.1f%%" % (rid, k, sizes[k] / mask.sum() * 100))

    # 自然切分：地形场（起伏+噪声+屏障）网格种子 watershed，再按连通性生长合并成两块
    # 边界沿地形脊线自然蜿蜒，均衡性由"双邻盆地归入后差值最小"的生长合并保证
    info = json.load(open(os.path.join(rdir, "info.json"), encoding="utf-8"))
    b = info["bbox_8192"]
    x0, y0, x1, y1 = b["x0"], b["y0"], b["x1"], b["y1"]
    height = np.load(os.path.join(rdir, "heightmap_8192.npy"))
    relief = ndi.maximum_filter(height, size=15) - ndi.minimum_filter(height, size=15)
    river = np.array(Image.open(os.path.join(HERE, "output", "fractal_river_mask_8192.png"))) > 0
    lake = np.array(Image.open(os.path.join(HERE, "output", "fractal_lake_mask_8192.png"))) > 0
    barrier = (river[y0:y1 + 1, x0:x1 + 1] | lake[y0:y1 + 1, x0:x1 + 1]) & mask
    rng = np.random.default_rng(info["label"] * 1000 + x0)
    h, w = mask.shape
    small = (max(8, h // 24), max(8, w // 24))
    n = rng.random(small)
    nimg = np.array(Image.fromarray((n * 255).astype(np.uint8)).resize(
        (w, h), Image.BILINEAR), dtype=np.float32) / 255.0
    field = relief / max(relief.max(), 1e-6) + (nimg - 0.5) * 0.3
    field[barrier] = 3.0

    grid_n = 5  # 网格种子密度（网格越大盆地越细，合并越均衡）
    ys_all, xs_all = np.where(m)
    y0m, y1m = ys_all.min(), ys_all.max()
    x0m, x1m = xs_all.min(), xs_all.max()
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
            cf = field[ys_all[cell], xs_all[cell]]
            idx = int(np.argmin(cf))
            seeds.append((ys_all[cell][idx], xs_all[cell][idx]))
    seeds = list(dict.fromkeys(seeds))
    markers = np.zeros(m.shape, dtype=np.int32)
    for i, (sy, sx) in enumerate(seeds, 1):
        markers[sy, sx] = i
    sub = watershed(field, markers, mask=m)

    # 生长合并：两锚盆地（最大两个）+ 盆地邻接图，双邻盆地归入"差值更小"的一方
    labels = np.unique(sub)
    labels = labels[labels > 0]
    areas = {int(l): int((sub == l).sum()) for l in labels}
    adj = {}
    for l in labels:
        ml = sub == l
        padded = np.pad(ml, 1)
        neigh = ((padded[1:-1, 0:-2] | padded[1:-1, 2:] |
                  padded[0:-2, 1:-1] | padded[2:, 1:-1]) & (sub > 0) & ~ml)
        adj[int(l)] = set(int(x) for x in np.unique(sub[neigh]) if x != l)
    anchors = sorted(labels, key=lambda l: areas[int(l)], reverse=True)[:2]
    ga, gb = areas[int(anchors[0])], areas[int(anchors[1])]
    grp_a, grp_b = {int(anchors[0])}, {int(anchors[1])}
    unassigned = set(int(l) for l in labels) - grp_a - grp_b
    while unassigned:
        only_a = [l for l in unassigned if adj[l] & grp_a and not (adj[l] & grp_b)]
        only_b = [l for l in unassigned if adj[l] & grp_b and not (adj[l] & grp_a)]
        both = [l for l in unassigned if adj[l] & grp_a and adj[l] & grp_b]
        if not only_a and not only_b and not both:
            break
        for l in only_a:
            grp_a.add(l); ga += areas[l]; unassigned.discard(l)
        for l in only_b:
            grp_b.add(l); gb += areas[l]; unassigned.discard(l)
        for l in both:
            if abs((ga + areas[l]) - gb) <= abs(ga - (gb + areas[l])):
                grp_a.add(l); ga += areas[l]
            else:
                grp_b.add(l); gb += areas[l]
            unassigned.discard(l)
    sub2 = np.zeros(m.shape, dtype=np.int32)
    for l in labels:
        sub2[sub == l] = 1 if int(l) in grp_a else 2
    a1, a2 = ga, gb
    total = a1 + a2
    print("切分: %.1f%% / %.1f%%（均衡度差 %.1f%%）" % (a1 / total * 100, a2 / total * 100,
          abs(a1 - a2) / total * 100))
    sub = sub2

    new_label = int(seg.max()) + 1
    seg[sub == 2] = new_label  # 第二块用新 label（第一块沿用原 label k）

    # 重写 tiles.json（结构与 export_l2_maps.py 一致）
    tiles = []
    for lbl in range(1, int(seg.max()) + 1):
        mm = seg == lbl
        if not mm.any():
            continue
        contours = find_contours(mm.astype(np.uint8), 0.5)
        poly = None
        if contours:
            c = contours[0]
            step = max(1, len(c) // 60)
            poly = [[float(x), float(y)] for x, y in c[::step]]
        ys, xs = np.where(mm)
        tiles.append({
            "tile_id": "%s_tile_%02d" % (rid, lbl),
            "label": lbl,
            "area_px": int(mm.sum()),
            "area_ratio": float(mm.sum() / mask.sum()),
            "centroid": [float(xs.mean()), float(ys.mean())],
            "polygon": poly or [],
        })
    tiles.sort(key=lambda t: -t["area_ratio"])
    info = json.load(open(os.path.join(rdir, "info.json"), encoding="utf-8"))
    tiles_data = {"region_id": rid, "label": info["label"], "n_tiles": int(seg.max()), "tiles": tiles}
    with open(os.path.join(rdir, "tiles.json"), "w", encoding="utf-8") as f:
        json.dump(tiles_data, f, ensure_ascii=False, indent=1)
    np.save(os.path.join(rdir, "tiles_8192.npy"), seg)

    # 重画预览
    colors = unique_colors(int(seg.max()))
    base = np.array(Image.open(os.path.join(rdir, "base_8192.png"))).astype(np.float32)
    overlay = base.copy()
    for lbl in range(1, int(seg.max()) + 1):
        c = colors[lbl - 1]
        mm = seg == lbl
        overlay[mm] = overlay[mm] * 0.5 + np.array(c, dtype=np.float32) * 0.5
    edge = np.zeros((h, w), dtype=bool)
    edge[:, :-1] |= seg[:, :-1] != seg[:, 1:]
    edge[:-1, :] |= seg[:-1, :] != seg[1:, :]
    overlay[edge] = (255, 220, 120)
    Image.fromarray(overlay.astype(np.uint8)).save(os.path.join(rdir, "tiles_preview_8192.png"))
    print("已更新 tiles_8192.npy / tiles.json / tiles_preview_8192.png")


if __name__ == "__main__":
    main()
