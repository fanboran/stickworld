"""把指定地区合并为"每岛一块"：地块 = 岛屿（连通分量），重建 tiles 数据与预览。

用法：
  python tools/worldgen/l1/merge_island_tiles.py region_009 region_010 region_011
"""
import json
import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage as ndi
from skimage.measure import find_contours

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
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
    rids = sys.argv[1:] or ["region_009", "region_010", "region_011"]
    for rid in rids:
        rdir = os.path.join(L2_DIR, rid)
        mask = np.array(Image.open(os.path.join(rdir, "mask_8192.png"))) > 0
        info = json.load(open(os.path.join(rdir, "info.json"), encoding="utf-8"))
        h, w = mask.shape
        total = int(mask.sum())

        # 地块 = 岛屿（连通分量），重编号压缩
        seg, n_tiles = ndi.label(mask)
        print("%s: %d 个岛屿 -> %d 个地块" % (rid, n_tiles, n_tiles))

        np.save(os.path.join(rdir, "tiles_8192.npy"), seg)

        # tiles.json（结构与 export_l2_maps.py 一致）
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
                "tile_id": "%s_tile_%02d" % (rid, k),
                "label": k,
                "area_px": int(m.sum()),
                "area_ratio": float(m.sum() / total),
                "centroid": [float(xs.mean()), float(ys.mean())],
                "polygon": poly or [],
            })
        tiles.sort(key=lambda t: -t["area_ratio"])
        tiles_data = {"region_id": rid, "label": info["label"], "n_tiles": n_tiles, "tiles": tiles}
        with open(os.path.join(rdir, "tiles.json"), "w", encoding="utf-8") as f:
            json.dump(tiles_data, f, ensure_ascii=False, indent=1)

        # 预览：岛屿纯色，无内部描边
        colors = unique_colors(n_tiles)
        base = np.array(Image.open(os.path.join(rdir, "base_8192.png"))).astype(np.float32)
        overlay = base.copy()
        for k in range(1, n_tiles + 1):
            c = colors[k - 1]
            m = seg == k
            overlay[m] = overlay[m] * 0.45 + np.array(c, dtype=np.float32) * 0.55
        out = os.path.join(rdir, "tiles_preview_8192.png")
        Image.fromarray(overlay.astype(np.uint8)).save(out)
        print("  已更新 tiles_8192.npy / tiles.json / tiles_preview_8192.png")


if __name__ == "__main__":
    main()
