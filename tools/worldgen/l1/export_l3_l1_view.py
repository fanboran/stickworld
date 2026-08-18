"""L3 视觉层导出（老 L1 / 城市两级 + 老 L1 索引图）—— L3 直接用多边形色块显示细分子地块。

背景（2026-08）：
  - L3 视觉 = 老 L1 地块（69 块）或城市（1038 块，像 city_preview 花花绿绿），
    通过游戏内"显示模式"按钮切换；
  - 交互不变：hover 命中老 L1 地块（l3_l1_index.png 索引图），点击下钻 L2；
  - 配色调鲜艳（s=0.85，明度 0.5~0.98，亮色比例高）。

输入：output/l1_v2/legacy_l1_labels_2048.npy + city_labels_2048.npy + region_labels.npy
输出（config/strategic_map/）：
  - l3_l1.json   老 L1 视觉层（69 块，8192 级 polygons/holes/color）
  - l3_city.json 城市视觉层（1038 块，同上；DP 抽稀控制体积）
  - l3_l1_index_2048.png  老 L1 索引图（label 直编，hover 查询用）

用法：
  python tools/worldgen/l1/export_l3_l1_view.py
"""
import colorsys
import json
import os
import shutil
import sys
from collections import defaultdict

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # tools/worldgen
V2_DIR = os.path.join(HERE, "output", "l1_v2")
REGIONS_DIR = os.path.join(HERE, "output", "regions")
GAME_DIR = os.path.normpath(os.path.join(
    HERE, "..", "..", "stick-world", "config", "strategic_map"))
sys.path.insert(0, os.path.join(HERE, "l2_export"))
import mesh_extract  # noqa: E402

SIZE = 8192
# 鲜艳配色：高饱和（0.85）+ 亮明度（0.5~0.98）——"鲜艳、亮色比例高"
SAT = 0.85
V0, V1 = 0.50, 0.98


def golden_hue(r_index):
    return (r_index * 0.618033988749895) % 1.0


def rank_groups(label_map, group_of, n_all):
    """返回 (seq, total)：seq[label]=组内面积排名 k，total[label]=组内数量 m。"""
    areas = {lab: int((label_map == lab).sum()) for lab in range(1, n_all + 1)}
    byg = defaultdict(list)
    for lab in range(1, n_all + 1):
        if areas[lab] > 0:
            byg[group_of.get(lab, 0)].append((lab, areas[lab]))
    seq, total = {}, {}
    for g, items in byg.items():
        items.sort(key=lambda x: -x[1])
        for k, (lab, _a) in enumerate(items):
            seq[lab] = k
            total[lab] = len(items)
    return seq, total


def extract_mesh(arr2048):
    arr8192 = np.array(Image.fromarray(arr2048.astype(np.uint32), "I").resize(
        (SIZE, SIZE), Image.NEAREST)).astype(np.int32)
    return mesh_extract.simplify_mesh(mesh_extract.extract_mesh(arr8192))


def build_layer(label_map, group_of, group_seq, group_total, n_all, decimate_tol):
    mesh = extract_mesh(label_map)
    tiles = []
    for lab in range(1, n_all + 1):
        m = label_map == lab
        if not m.any():
            continue
        ys, xs = np.where(m)
        mv = mesh.get(lab, {"outer": [], "holes": []})
        def _dec(loop):
            # 坐标约定：mesh 角点即 (y,x)；DP 对称，直接保留 (y,x) 写入 JSON，
            # 与 l3_world.json 的 land_polygons 一致——渲染端统一 Vector2(p[1],p[0]) 解读。
            pts = mesh_extract._dp_simplify([(float(p[0]), float(p[1])) for p in loop], decimate_tol)
            return [[p[0], p[1]] for p in pts]
        rings = [_dec(r) for r in mv["outer"] if len(r) >= 3]
        holes = [_dec(r) for r in mv["holes"] if len(r) >= 3]
        g = group_of.get(lab, 0)
        tiles.append({
            "label": lab,
            "group": g,
            "color": vivid_color(g, group_seq.get(lab, 0), group_total.get(lab, 1)),
            "polygons": rings,
            "holes": holes,
            "centroid_2048": [float(xs.mean()), float(ys.mean())],
            "area_px": int(m.sum()),
        })
    return tiles


def vivid_color(g, k, m):
    h = golden_hue(g)
    v = V0 + (V1 - V0) * (k + 0.5) / m
    r, gg, b = colorsys.hsv_to_rgb(h, SAT, v)
    return [int(r * 255), int(gg * 255), int(b * 255)]


def main():
    print("[1/5] 加载 l1_v2 数据 ...")
    l1 = np.load(os.path.join(V2_DIR, "legacy_l1_labels_2048.npy"))
    city = np.load(os.path.join(V2_DIR, "city_labels_2048.npy"))
    region = np.load(os.path.join(REGIONS_DIR, "region_labels.npy"))
    n_l1, n_city = int(l1.max()), int(city.max())
    print("  老 L1 %d 块 / 城市 %d 块" % (n_l1, n_city))

    # 配色组：老 L1 -> region；城市 -> 父老 L1（同组相似色），组序号 = 该组在图上怎么给 hue
    # （老 L1 的 group 用 region label；城市用父老 L1 label，hue 由 golden_hue(父L1序号) 给出，同 L1 城市相似）
    l1_group = {lab: int(region.ravel()[np.flatnonzero(l1 == lab)[0]]) for lab in range(1, n_l1 + 1)}
    city_group = {}
    for lab in range(1, n_city + 1):
        m = city == lab
        if m.any():
            city_group[lab] = int(np.flatnonzero(m)[0] and l1.ravel()[np.flatnonzero(m)[0]])
    # 城市配色组的 hue 要体现父老 L1：城市 group 用父老 L1 序号来出 hue，
    # 但 golden_hue 需要 0.. 序号——父老 L1 序号 1..69 直接当 hue index（非 L2-region 语义）
    l1_seq, l1_total = rank_groups(l1, l1_group, n_l1)
    city_seq, city_total = rank_groups(city, city_group, n_city)

    print("[2/5] 老 L1 视觉层（69 块，鲜艳色）...")
    l1_tiles = build_layer(l1, l1_group, l1_seq, l1_total, n_l1, decimate_tol=0.3)
    with open(os.path.join(GAME_DIR, "l3_l1.json"), "w", encoding="utf-8") as f:
        json.dump({"name": "L3 老 L1 视觉层", "size": SIZE, "n_l1": n_l1, "tiles": l1_tiles},
                  f, ensure_ascii=False, separators=(",", ":"))
    shutil.copy(os.path.join(GAME_DIR, "l3_l1.json"), os.path.join(V2_DIR, "l3_l1.json"))
    print("  老 L1 层 %d 块 -> l3_l1.json" % len(l1_tiles))

    print("[3/5] 城市视觉层（%d 块，鲜艳色，DP 抽稀）..." % n_city)
    city_tiles = build_layer(city, city_group, city_seq, city_total, n_city, decimate_tol=0.5)
    with open(os.path.join(GAME_DIR, "l3_city.json"), "w", encoding="utf-8") as f:
        json.dump({"name": "L3 城市视觉层", "size": SIZE, "n_city": n_city, "tiles": city_tiles},
                  f, ensure_ascii=False, separators=(",", ":"))
    shutil.copy(os.path.join(GAME_DIR, "l3_city.json"), os.path.join(V2_DIR, "l3_city.json"))
    print("  城市层 %d 块 -> l3_city.json" % len(city_tiles))

    print("[4/5] 老 L1 索引图（hover 查询用，label 直编 2048）...")
    idx = np.zeros((2048, 2048, 3), dtype=np.uint8)
    idx[l1 > 0, 0] = (l1[l1 > 0] >> 16) & 0xFF
    idx[l1 > 0, 1] = (l1[l1 > 0] >> 8) & 0xFF
    idx[l1 > 0, 2] = l1[l1 > 0] & 0xFF
    Image.fromarray(idx).save(os.path.join(GAME_DIR, "l3_l1_index_2048.png"))
    shutil.copy(os.path.join(GAME_DIR, "l3_l1_index_2048.png"),
                os.path.join(V2_DIR, "l3_l1_index_2048.png"))

    # 城市模式栅格贴图（运行时 MODE_CITY 直接贴这张——即用户认为最好看的 city_preview）
    shutil.copy(os.path.join(V2_DIR, "city_preview_2048.png"),
                os.path.join(GAME_DIR, "l3_city_preview_2048.png"))
    print("[5/5] 完成。配色调鲜艳：s=%.2f, v=%.2f~%.2f；城市贴图 l3_city_preview_2048.png" % (SAT, V0, V1))


if __name__ == "__main__":
    main()