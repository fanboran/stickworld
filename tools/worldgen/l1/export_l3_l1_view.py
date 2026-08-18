"""L3 老 L1 视觉层导出 —— L3 大世界直接显示老 L1 地块（69 块丰富配色），交互仍下钻 L2。

背景：L3 视觉 = 老 L1 地块（"L3 直接把 L1 地块显示出来"，同地区相似色，类 city_preview
丰富度）；点击/下钻仍按 L2 地区（l3_partition_2048.hover/label 不变）。

输入：output/l1_v2/legacy_l1_labels_2048.npy（老 L1 全局蒙版）+ region_labels.npy
输出（写入 config/strategic_map/l3_l1.json，L3 渲染器读取）：
  {size: 8192, tiles: [{label(1..69), region, color, polygons(8192 角点), holes,
    centroid_2048, area_px}]}   坐标 = L3 渲染网格（8192 级）

用法：
  python tools/worldgen/l1/export_l3_l1_view.py
"""
import colorsys
import json
import os
import shutil
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # tools/worldgen
V2_DIR = os.path.join(HERE, "output", "l1_v2")
REGIONS_DIR = os.path.join(HERE, "output", "regions")
GAME_DIR = os.path.normpath(os.path.join(
    HERE, "..", "..", "stick-world", "config", "strategic_map"))
sys.path.insert(0, os.path.join(HERE, "l2_export"))
import mesh_extract  # noqa: E402


def golden_hue(r_index):
    return (r_index * 0.618033988749895) % 1.0


def main():
    print("[1/4] 加载老 L1 蒙版（2048 -> 8192）...")
    l1 = np.load(os.path.join(V2_DIR, "legacy_l1_labels_2048.npy"))
    size = 8192
    l1_8192 = np.array(Image.fromarray(l1.astype(np.uint32), "I").resize(
        (size, size), Image.NEAREST)).astype(np.int32)
    n_l1 = int(l1.max())
    print("  老 L1 地块 %d 个" % n_l1)

    print("[2/4] 提取多边形（8192 级共享网格）...")
    mesh = mesh_extract.simplify_mesh(mesh_extract.extract_mesh(l1_8192))

    print("[3/4] 配色（同 L2 地区相似色：地区基色 + 区内明度阶梯）...")
    region = np.load(os.path.join(REGIONS_DIR, "region_labels.npy"))
    # 每老 L1 的 region 与 2048 质心
    tiles = []
    region_of = {}
    for lab in range(1, n_l1 + 1):
        m = l1 == lab
        ys, xs = np.where(m)
        region_of[lab] = int(region.ravel()[np.flatnonzero(m)[0]])
        tiles.append({"label": lab, "region": region_of[lab],
                      "centroid_2048": [float(xs.mean()), float(ys.mean())],
                      "area_px": int(m.sum())})
    # 区内按面积排序 -> 明度阶梯
    from collections import defaultdict
    by_region = defaultdict(list)
    for t in tiles:
        by_region[t["region"]].append(t)
    for r, ts in by_region.items():
        ts.sort(key=lambda t: -t["area_px"])
        m = len(ts)
        h = golden_hue(r - 1)
        for k, t in enumerate(ts):
            v = 0.38 + 0.55 * (k + 0.5) / m
            rr, gg, bb = colorsys.hsv_to_rgb(h, 0.72, v)
            t["color"] = [int(rr * 255), int(gg * 255), int(bb * 255)]
    # 8192 多边形
    for t in tiles:
        mv = mesh.get(t["label"], {"outer": [], "holes": []})
        t["polygons"] = [list(list(p) for p in ring) for ring in mv["outer"]]
        t["holes"] = [list(list(p) for p in ring) for ring in mv["holes"]]

    print("[4/4] 写 l3_l1.json ...")
    out = {"name": "L3 老 L1 视觉层", "size": size, "n_l1": n_l1, "tiles": tiles}
    with open(os.path.join(GAME_DIR, "l3_l1.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
    shutil.copy(os.path.join(GAME_DIR, "l3_l1.json"), os.path.join(V2_DIR, "l3_l1.json"))
    print("  完成 -> %s（%d 块老 L1，多边形/配色已就绪）" % (os.path.join(GAME_DIR, "l3_l1.json"), n_l1))


if __name__ == "__main__":
    main()