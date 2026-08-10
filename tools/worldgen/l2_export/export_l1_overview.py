"""生成 L3 全图预览：显示全部 L1 地块（13 个 L2 地区分块拼回 8192 坐标系）。

- 背景：13 地区 base_8192.png 按 bbox 拼回（高清陆地），海洋纯色
- 地块：tiles_8192.npy 按 bbox 贴入，HSL 随机着色 + 边界描边

用法：
  python tools/worldgen/l2_export/export_l1_overview.py
"""
import json
import os

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
L2_DIR = os.path.join(HERE, "output", "l2_packs")
L3_DIR = os.path.join(HERE, "output", "l3_view")
SIZE = 8192


def tile_colors(n):
    colors = []
    for i in range(n):
        h = (i * 0.618033988749895) % 1.0
        s = 0.55 + 0.2 * ((i * 7) % 3) / 2.0
        l = 0.5 + 0.25 * ((i * 11) % 3) / 2.0
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
    region_dirs = sorted(d for d in os.listdir(L2_DIR) if d.startswith("region_"))

    # 背景：先放 L3 2048 底图放大（海洋），再贴各地区 8192 底图（陆地）
    canvas = np.full((SIZE, SIZE, 3), (30, 55, 95), dtype=np.float32)  # 海洋纯色

    # 全局 L1 地块 ID 图（8192），tile_id 唯一
    global_labels = np.zeros((SIZE, SIZE), dtype=np.int32)
    n_tiles = 0
    for rid in region_dirs:
        rdir = os.path.join(L2_DIR, rid)
        info = json.load(open(os.path.join(rdir, "info.json"), encoding="utf-8"))
        b = info["bbox_8192"]
        x0, y0, x1, y1 = b["x0"], b["y0"], b["x1"], b["y1"]
        # 高清底图贴回
        base = np.array(Image.open(os.path.join(rdir, "base_8192.png")).convert("RGB")).astype(np.float32)
        canvas[y0:y1 + 1, x0:x1 + 1] = base
        # 地块标签贴回（全局唯一 ID）
        tiles = np.load(os.path.join(rdir, "tiles_8192.npy"))
        tiles = tiles.astype(np.int32)
        tiles[tiles < 0] = 0
        region_offset = n_tiles
        sub = tiles.copy()
        sub[tiles > 0] += region_offset
        global_labels[y0:y1 + 1, x0:x1 + 1] = np.where(sub > 0, sub, global_labels[y0:y1 + 1, x0:x1 + 1])
        n_tiles += int(tiles.max())
        print("  %s: %d 地块, 偏移后 id 1..%d" % (rid, int(tiles.max()), n_tiles))

    # 上色（半透明）
    overlay = canvas.copy()
    valid = global_labels > 0
    ids = np.unique(global_labels[valid])
    colors = tile_colors(len(ids) + 1)
    id2color = {int(i): colors[idx] for idx, i in enumerate(ids)}
    for i, col in id2color.items():
        mm = global_labels == i
        overlay[mm] = overlay[mm] * 0.45 + np.array(col, dtype=np.float32) * 0.55

    # 边界描边（相邻地块不同）
    edge = np.zeros((SIZE, SIZE), dtype=bool)
    edge[:, :-1] |= global_labels[:, :-1] != global_labels[:, 1:]
    edge[:-1, :] |= global_labels[:-1, :] != global_labels[1:, :]
    edge &= valid
    overlay[edge] = (255, 220, 120)

    out = os.path.join(L2_DIR, "l1_all_tiles_8192.png")
    Image.fromarray(overlay.astype(np.uint8)).save(out)
    print("已保存: %s（L1 地块总数 %d）" % (out, len(ids)))


if __name__ == "__main__":
    main()
