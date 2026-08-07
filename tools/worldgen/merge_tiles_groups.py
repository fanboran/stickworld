"""把指定地区的地块按"邻接 + 面积差最小"分组合并到目标组数（边界沿用原地块边界）。

锚 = 面积最大的两个地块，其余地块按邻接关系生长归组：
- 只邻 A 组 -> 归 A；只邻 B 组 -> 归 B
- 双邻 -> 归入"归后 |A-B| 更小"的组（保持两块均衡）

用法：
  python tools/worldgen/merge_tiles_groups.py region_002 --n 2
"""
import argparse
import json
import os

import numpy as np
from PIL import Image
from skimage.measure import find_contours

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
    p = argparse.ArgumentParser(description="地块分组合并（均衡）")
    p.add_argument("region", help="地区名，如 region_002")
    p.add_argument("--n", type=int, default=2, help="目标组数（默认 2）")
    args = p.parse_args()
    rid = args.region
    target = args.n
    rdir = os.path.join(L2_DIR, rid)
    mask = np.array(Image.open(os.path.join(rdir, "mask_8192.png"))) > 0
    seg = np.load(os.path.join(rdir, "tiles_8192.npy"))
    seg[~mask] = 0
    info = json.load(open(os.path.join(rdir, "info.json"), encoding="utf-8"))
    total = int(mask.sum())

    labels = np.unique(seg)
    labels = labels[labels > 0]
    areas = {int(l): int((seg == l).sum()) for l in labels}
    # 邻接图
    adj = {}
    for l in labels:
        ml = seg == l
        padded = np.pad(ml, 1)
        neigh = ((padded[1:-1, 0:-2] | padded[1:-1, 2:] |
                  padded[0:-2, 1:-1] | padded[2:, 1:-1]) & (seg > 0) & ~ml)
        adj[int(l)] = set(int(x) for x in np.unique(seg[neigh]) if x != l)

    anchors = sorted(labels, key=lambda l: areas[int(l)], reverse=True)[:target]
    gs = [areas[int(a)] for a in anchors]
    groups = [{int(a)} for a in anchors]
    unassigned = set(int(l) for l in labels) - set().union(*groups)
    while unassigned:
        assigned = set().union(*groups)
        only = []
        both = []
        for l in unassigned:
            neigh_groups = [gi for gi, g in enumerate(groups) if adj[l] & g]
            if len(neigh_groups) == 1:
                only.append((l, neigh_groups[0]))
            elif len(neigh_groups) > 1:
                both.append((l, neigh_groups))
        if not only and not both:
            break
        for l, gi in only:
            groups[gi].add(l)
            gs[gi] += areas[l]
            unassigned.discard(l)
        for l, ngis in both:
            # 归入"归后最大差最小"的组
            gi = min(ngis, key=lambda g: abs((gs[g] + areas[l]) - max(
                (gs[gg] - (areas[l] if gg == g else 0) for gg in range(target)), default=0)))
            # 简化：归入归后使 (max-min) 最小的组
            best_gi, best_diff = ngis[0], None
            for g in ngis:
                ng = gs[:]
                ng[g] += areas[l]
                d = max(ng) - min(ng)
                if best_diff is None or d < best_diff:
                    best_diff, best_gi = d, g
            groups[best_gi].add(l)
            gs[best_gi] += areas[l]
            unassigned.discard(l)

    # 写回 seg
    new_seg = np.zeros_like(seg)
    for gi, g in enumerate(groups, 1):
        for l in g:
            new_seg[seg == l] = gi
    seg = new_seg
    np.save(os.path.join(rdir, "tiles_8192.npy"), seg)

    # tiles.json
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
    tiles_data = {"region_id": rid, "label": info["label"], "n_tiles": int(seg.max()), "tiles": tiles}
    with open(os.path.join(rdir, "tiles.json"), "w", encoding="utf-8") as f:
        json.dump(tiles_data, f, ensure_ascii=False, indent=1)

    # 预览
    h, w = mask.shape
    colors = unique_colors(int(seg.max()))
    base = np.array(Image.open(os.path.join(rdir, "base_8192.png"))).astype(np.float32)
    overlay = base.copy()
    for k in range(1, int(seg.max()) + 1):
        c = colors[k - 1]
        m = seg == k
        overlay[m] = overlay[m] * 0.5 + np.array(c, dtype=np.float32) * 0.5
    edge = np.zeros((h, w), dtype=bool)
    edge[:, :-1] |= seg[:, :-1] != seg[:, 1:]
    edge[:-1, :] |= seg[:-1, :] != seg[1:, :]
    edge &= seg > 0
    overlay[edge] = (255, 220, 120)
    Image.fromarray(overlay.astype(np.uint8)).save(os.path.join(rdir, "tiles_preview_8192.png"))

    print("%s: %d 块 -> %d 块，占比 %s" % (rid, len(labels), target,
          ["%.1f%%" % (a / total * 100) for a in gs]))


if __name__ == "__main__":
    main()
