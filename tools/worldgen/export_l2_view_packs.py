"""L2 地区视图素材导出 —— 供 L3→L2 下钻（M 键战略图点地区进入）。

每地区产出（输出到 output/l2_view_packs/region_XXX/ 并复制到游戏
stick-world/config/strategic_map/l2_packs/region_XXX/）：
  - l2_base_2048.png        底图（8192 裁切底图降采样，最长边 2048，BILINEAR）
  - l2_tiles_index_2048.png 地块索引图（label 直编 RGB，P 社机制；0=海洋/无地块）
  - l2_tiles_border_2048.png 地块边界图（RGBA 透明背景 + 黄边）
  - l2_world.json           元数据（size/文件名/tiles 列表，polygon 已换算到视图坐标）

索引图降采样用"分块众数"（mode），保证小块不丢失；地块 label 与 L3 独立命名空间。

用法：
  python tools/worldgen/export_l2_view_packs.py [region_XXX ...]
"""
import json
import os
import shutil
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
L2_DIR = os.path.join(HERE, "output", "l2_packs")
OUT_DIR = os.path.join(HERE, "output", "l2_view_packs")
GAME_DIR = os.path.normpath(os.path.join(
    HERE, "..", "..", "stick-world", "config", "strategic_map", "l2_packs"))

MAX_SIDE = 2048  # 视图最长边

OCEAN_COLOR = (30, 55, 95)


def unique_colors():
    colors = []
    for i in range(80):
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


def downsample_mode(seg, th, tw):
    """分块众数降采样：把 (H,W) 标签图降到 (th,tw)，每目标像素 = 源块内出现最多的 label。

    映射与 polygon/centroid 换算严格一致：源像素 (s_y, s_x) -> 目标
    (floor(s_y*th/H), floor(s_x*tw/W))，众数在该目标像素的源像素集合上统计。
    """
    H, W = seg.shape
    row_map = np.floor(np.arange(H) * th / H).astype(int)
    col_map = np.floor(np.arange(W) * tw / W).astype(int)
    out = np.zeros((th, tw), dtype=np.int32)
    best = np.zeros((th, tw), dtype=np.int32)
    maxv = int(seg.max()) + 1
    for lab in range(maxv):
        ys_m, xs_m = np.where(seg == lab)
        if ys_m.size == 0:
            continue
        keys = row_map[ys_m] * tw + col_map[xs_m]
        cnt = np.bincount(keys, minlength=th * tw).reshape(th, tw)
        m = cnt > best
        out[m] = lab
        best[m] = cnt[m]
    return out


def main():
    rids = sys.argv[1:] or sorted(d for d in os.listdir(L2_DIR) if d.startswith("region_"))
    for rid in rids:
        rdir = os.path.join(L2_DIR, rid)
        info = json.load(open(os.path.join(rdir, "info.json"), encoding="utf-8"))
        bbox = info["bbox_8192"]
        x0, y0, x1, y1 = bbox["x0"], bbox["y0"], bbox["x1"], bbox["y1"]
        H, W = y1 - y0 + 1, x1 - x0 + 1

        # 直接用 8192 裁切原分辨率（像素块细，放大无马赛克感；纯色 PNG 压缩率高）
        seg = np.load(os.path.join(rdir, "tiles_8192.npy"))
        seg[seg < 0] = 0
        tiles_small = seg.astype(np.int32)

        colors = unique_colors()
        # 索引图：label 直编 RGB（8192 级，hover 像素级查询精度）
        idx = np.zeros((H, W, 3), dtype=np.uint8)
        for lab in range(1, int(tiles_small.max()) + 1):
            m = tiles_small == lab
            idx[m, 0] = (lab >> 16) & 0xFF
            idx[m, 1] = (lab >> 8) & 0xFF
            idx[m, 2] = lab & 0xFF

        # 元数据（polygon/centroid 视图坐标）
        # 共享顶点网格提取（复现 P 社架构：相邻地块共享角点 -> 渲染绝对无缝）
        from mesh_extract import extract_mesh, simplify_mesh
        mesh = simplify_mesh(extract_mesh(tiles_small.astype(np.int32)))
        tiles = []
        for lab, mv in mesh.items():
            polys = mv["outer"]
            holes = mv["holes"]
            m = tiles_small == lab
            ys, xs = np.where(m)
            tiles.append({
                "label": lab,
                "color": list(colors[lab - 1]),
                "area_px": int(m.sum()),
                "area_ratio": float(m.sum() / (tiles_small > 0).sum()),
                "centroid": [float(ys.mean()), float(xs.mean())],
                "polygon": polys[0] if polys else [],
                "polygons": polys,
                "holes": holes,
            })
        tiles.sort(key=lambda t: -t["area_ratio"])
        world = {
            "region_id": rid,
            "label": info["label"],
            "size": [W, H],
            "base_texture": "",
            "mask_texture": "l2_tiles_index.png",
            "tiles": tiles,
        }

        outd = os.path.join(OUT_DIR, rid)
        os.makedirs(outd, exist_ok=True)
        Image.fromarray(idx).save(os.path.join(outd, "l2_tiles_index.png"))
        with open(os.path.join(outd, "l2_world.json"), "w", encoding="utf-8") as f:
            json.dump(world, f, ensure_ascii=False, indent=1)

        # 复制到游戏 config
        gamed = os.path.join(GAME_DIR, rid)
        os.makedirs(gamed, exist_ok=True)
        for fn in ("l2_world.json", "l2_tiles_index.png"):
            shutil.copy(os.path.join(outd, fn), os.path.join(gamed, fn))
        print("  %s: %dx%d, %d 个地块" % (rid, W, H, len(tiles)))

    print("完成。输出: %s" % OUT_DIR)


if __name__ == "__main__":
    main()
