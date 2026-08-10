"""L2 地区视图素材导出 —— 供 L3→L2 下钻（M 键战略图点地区进入）。

每地区产出（输出到 output/l2_view_packs/region_XXX/ 并复制到游戏
stick-world/config/strategic_map/l2_packs/region_XXX/）：
  - l2_base_2048.png        底图（8192 裁切底图降采样，最长边 2048，BILINEAR）
  - l2_tiles_index_2048.png 地块索引图（label 直编 RGB，P 社机制；0=海洋/无地块）
  - l2_tiles_border_2048.png 地块边界图（RGBA 透明背景 + 黄边）
  - l2_world.json           元数据（size/文件名/tiles 列表，polygon 已换算到视图坐标）

索引图降采样用"分块众数"（mode），保证小块不丢失；地块 label 与 L3 独立命名空间。

用法：
  python tools/worldgen/l2_export/export_l2_view_packs.py [region_XXX ...]
"""
import json
import os
import shutil
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
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

    # 8192 合成标签图（region_labels 2048 放大 + 8K 大陆蒙版裁切海岸线）——
    # 用于渲染相邻 L2 地区（灰色）与湖泊（浅蓝）
    labels_2048 = np.load(os.path.join(HERE, "output", "regions", "region_labels.npy"))
    labels8192 = np.array(Image.fromarray(
        labels_2048.astype(np.int32), "I").resize((8192, 8192), Image.NEAREST)).astype(np.int32)
    continent = np.array(Image.open(os.path.join(HERE, "output", "locked", "locked_continent_8192.png")))
    labels8192[continent[:, :, 0] <= 127] = 0
    lake_mask = np.array(Image.open(os.path.join(HERE, "output", "fractal_lake_mask_8192.png"))) > 0
    # 邻接（分区后 4 邻域，来自 l3_world.json）
    l3w = json.load(open(os.path.join(HERE, "output", "l3_view", "l3_world.json"), encoding="utf-8"))
    adj_by_label = {int(r["label"]): r.get("adjacent", []) for r in l3w["regions"]}

    from mesh_extract import extract_mesh, simplify_mesh

    for rid in rids:
        rdir = os.path.join(L2_DIR, rid)
        info = json.load(open(os.path.join(rdir, "info.json"), encoding="utf-8"))
        bbox = info["bbox_8192"]
        x0, y0, x1, y1 = bbox["x0"], bbox["y0"], bbox["x1"], bbox["y1"]
        H, W = y1 - y0 + 1, x1 - x0 + 1
        lab = info["label"]

        # 直接用 8192 裁切原分辨率（像素块细，放大无马赛克感；纯色 PNG 压缩率高）
        seg = np.load(os.path.join(rdir, "tiles_8192.npy"))
        seg[seg < 0] = 0
        tiles_small = seg.astype(np.int32)

        # 上下文：正方形（边长 = 地区长边，对称补齐；地图边界外虚空）。
        # 同一网格提取地块/邻居/湖泊（8192 精度，共享角点无缝）
        side = max(W, H)
        tx, ty = (side - W) // 2, (side - H) // 2  # tiles 区域在正方形中的偏移
        ctx_w, ctx_h = side, side

        # 正方形 context 标签图：地图边界外虚空 0
        PAD_EDGE = max(0, ty - y0, tx - x0, y1 + ty - 8191, x1 + tx - 8191)
        lp = np.pad(labels8192, ((PAD_EDGE, PAD_EDGE), (PAD_EDGE, PAD_EDGE)), mode="constant")
        yy0, xx0 = y0 - ty + PAD_EDGE, x0 - tx + PAD_EDGE
        ctx = lp[yy0:yy0 + ctx_h, xx0:xx0 + ctx_w].copy()
        lm = np.pad(lake_mask, ((PAD_EDGE, PAD_EDGE), (PAD_EDGE, PAD_EDGE)), mode="constant")
        ctx_lake = lm[yy0:yy0 + ctx_h, xx0:xx0 + ctx_w]
        TILE_LABEL = 1000
        LAKE_LABEL = 2000
        ctx[(ctx == 0) & ctx_lake] = LAKE_LABEL
        # 陆地上所有湖像素标为 LAKE_LABEL（含地块内部 -> 地块洞；含非地块铺地区 -> 湖泊）
        # （原实现只在 ctx==0 处标湖 + 整块铺地块标签 -> 地块内/非地块区的湖被覆盖成地块色/灰影）
        ctx[ctx_lake & (ctx != 0)] = LAKE_LABEL
        tile_zone = tiles_small[0:H, 0:W] > 0
        land_in_tile = tile_zone & ~ctx_lake[ty:ty + H, tx:tx + W]
        ctx[ty:ty + H, tx:tx + W][land_in_tile] = TILE_LABEL + tiles_small[0:H, 0:W][land_in_tile]

        # Chaikin 3 次 + corner_min_len=3（mesh_extract 中 chaikin_smooth 默认值）：
        # · 相邻两边 ≥3px 的「真实地形尖角」原顶点保留不切角 → 海角/河湾锐度不丢
        # · 仅 1~2px 短边的「像素台阶」经 3 次 Chaikin 抹平 → 马赛克感彻底消除
        # 提取后多边形是填充 mesh 和描边的唯一真源，保证两者渲染严丝合缝
        ctx_mesh = simplify_mesh(extract_mesh(ctx.astype(np.int32)), smooth_passes=3)
        # 灰影 = context 内出现的其他地区（8192 精度）
        neighbors_data = []
        for n, mv in ctx_mesh.items():
            if n == LAKE_LABEL or TILE_LABEL < n < TILE_LABEL + 100:
                continue
            if mv["outer"]:
                neighbors_data.append({"label": n, "polygons": mv["outer"], "holes": mv["holes"]})
        lakes = []
        lmv = ctx_mesh.get(LAKE_LABEL, {"outer": [], "holes": []})
        lakes = lmv["outer"]
        # 地块（统一网格取，label 映射回原值；坐标 = 正方形 context 局部）
        tile_mesh = {}
        for k, mv in ctx_mesh.items():
            if TILE_LABEL < k < TILE_LABEL + 100 and mv["outer"]:
                tile_mesh[k - TILE_LABEL] = mv

        colors = unique_colors()
        # 索引图：label 直编 RGB（8192 级，hover 像素级查询精度）
        idx = np.zeros((H, W, 3), dtype=np.uint8)
        for k in range(1, int(tiles_small.max()) + 1):
            m = tiles_small == k
            idx[m, 0] = (k >> 16) & 0xFF
            idx[m, 1] = (k >> 8) & 0xFF
            idx[m, 2] = k & 0xFF

        # 元数据（tiles 坐标 = tiles 区域局部，渲染时平移 ty/tx 到正方形）
        tiles = []
        for k, mv in tile_mesh.items():
            polys = mv["outer"]
            holes = mv["holes"]
            m = ctx == (TILE_LABEL + k)
            ys, xs = np.where(m)
            # holes 标记湖泊（质心在 ctx_lake 上 = 湖泊，渲染用湖泊色）
            holes_out = []
            for h in holes:
                cy = int(sum(p[0] for p in h) / len(h))
                cx = int(sum(p[1] for p in h) / len(h))
                is_lake = bool(ctx_lake[cy, cx]) if ctx_lake.shape[0] > cy and ctx_lake.shape[1] > cx else False
                holes_out.append({"points": h, "lake": is_lake})
            tiles.append({
                "label": k,
                "color": list(colors[(k - 1) % len(colors)]),
                "area_px": int(m.sum()),
                "area_ratio": float(m.sum() / (tiles_small > 0).sum()),
                "centroid": [float(ys.mean()), float(xs.mean())],
                "polygon": polys[0] if polys else [],
                "polygons": polys,
                "holes": holes_out,
            })
        tiles.sort(key=lambda t: -t["area_ratio"])
        world = {
            "region_id": rid,
            "label": lab,
            "size": [W, H],
            "context_size": [ctx_w, ctx_h],
            "tiles_offset": [tx, ty],   # tiles 区域原点在正方形 context 中的位置（渲染平移）
            "mask_texture": "l2_tiles_index.png",
            "tiles": tiles,
            "neighbors": neighbors_data,
            "lakes": lakes,
        }

        outd = os.path.join(OUT_DIR, rid)
        os.makedirs(outd, exist_ok=True)
        Image.fromarray(idx).save(os.path.join(outd, "l2_tiles_index.png"))
        with open(os.path.join(outd, "l2_world.json"), "w", encoding="utf-8") as f:
            json.dump(world, f, ensure_ascii=False, separators=(",", ":"))

        # 烘焙几何：三角剖分 + 描边段提前到素材阶段，运行时零几何计算
        from l2_bake import bake
        stats = bake(world, os.path.join(outd, "l2_geom.bin"))

        # 复制到游戏 config
        gamed = os.path.join(GAME_DIR, rid)
        os.makedirs(gamed, exist_ok=True)
        for fn in ("l2_world.json", "l2_tiles_index.png", "l2_geom.bin"):
            shutil.copy(os.path.join(outd, fn), os.path.join(gamed, fn))
        print("  %s: %dx%d -> 正方形 %d, %d 地块, 邻居 %d, 湖泊 %d | tris T%d H%d L%d N%d | border %d/%d"
              % (rid, W, H, side, len(tiles), len(neighbors_data), len(lakes),
                 stats["tile_tris"], stats["hole_tris"], stats["lake_tris"], stats["neighbor_tris"],
                 stats["tile_border_segs"], stats["neighbor_border_segs"]))

    print("完成。输出: %s" % OUT_DIR)


if __name__ == "__main__":
    main()
