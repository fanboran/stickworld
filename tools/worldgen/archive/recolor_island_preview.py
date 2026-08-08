"""把指定地区的预览图改为"每个岛屿一个颜色"（岛屿间区分，地块边界仍描边）。

用法：
  python tools/worldgen/recolor_island_preview.py region_009 region_010 region_011
"""
import json
import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage as ndi

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
    rids = sys.argv[1:] or ["region_009", "region_010", "region_011"]
    for rid in rids:
        rdir = os.path.join(L2_DIR, rid)
        mask = np.array(Image.open(os.path.join(rdir, "mask_8192.png"))) > 0
        seg = np.load(os.path.join(rdir, "tiles_8192.npy"))
        h, w = mask.shape

        # 岛屿 = 陆地连通分量
        islands, n_islands = ndi.label(mask)
        colors = unique_colors(n_islands)
        base = np.array(Image.open(os.path.join(rdir, "base_8192.png"))).astype(np.float32)
        overlay = base.copy()
        for iid in range(1, n_islands + 1):
            im = islands == iid
            c = colors[iid - 1]
            overlay[im] = overlay[im] * 0.45 + np.array(c, dtype=np.float32) * 0.55

        # 地块边界描边（地块相邻不同 label；与海洋交界不描）
        seg[~mask] = 0
        edge = np.zeros((h, w), dtype=bool)
        edge[:, :-1] |= seg[:, :-1] != seg[:, 1:]
        edge[:-1, :] |= seg[:-1, :] != seg[1:, :]
        edge &= seg > 0
        overlay[edge] = (255, 220, 120)

        out = os.path.join(rdir, "tiles_preview_8192.png")
        Image.fromarray(overlay.astype(np.uint8)).save(out)
        print("%s: %d 个岛屿各自着色，地块边界保留 -> %s" % (rid, n_islands, out))


if __name__ == "__main__":
    main()
