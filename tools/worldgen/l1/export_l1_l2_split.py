"""L2 视图 L1 细分导出 —— 把全大陆 L1 蒙版按地区切片，供 L3→L2 下钻视图显示。

输入：
  - output/l1/l1_data.json            全大陆 L1 蒙版元数据（2048 全局坐标）
  - output/l2_packs/region_XXX/info.json  每地区 bbox_8192（全局 8192 坐标范围）

像素角点换算（与 export_l2_view_packs.py 同语义）：
  context 坐标 = 全局 8192 角点 - (x0 - tx, y0 - ty)，其中 (x0,y0) 为地区 bbox 左上、
  (tx,ty) 为该地区 l2_world.json 的 tiles_offset（bbox 在正方形 context 中的位置）。

产出（output/l2_view_packs/region_XXX/l1_split.json，并复制到
  stick-world/config/strategic_map/l2_packs/region_XXX/）：
  {region_id, region_label, context_size, tiles_offset,
   cells: [{label, city, rgb, polygons(全部外环), small_exempt}]}  坐标 = context 局部

用法：
  python tools/worldgen/l1/export_l1_l2_split.py [region_XXX ...]
"""
import json
import os
import shutil
import sys

import numpy as np

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # tools/worldgen
L1_DIR = os.path.join(HERE, "output", "l1")
L2_PACKS = os.path.join(HERE, "output", "l2_packs")
OUT_DIR = os.path.join(HERE, "output", "l2_view_packs")
GAME_DIR = os.path.normpath(os.path.join(
    HERE, "..", "..", "stick-world", "config", "strategic_map", "l2_packs"))


def main():
    rids = sys.argv[1:] or sorted(d for d in os.listdir(L2_PACKS) if d.startswith("region_"))
    l1 = json.load(open(os.path.join(L1_DIR, "l1_data.json"), encoding="utf-8"))
    size2 = int(l1["size"])  # 2048
    for rid in rids:
        info = json.load(open(os.path.join(L2_PACKS, rid, "info.json"), encoding="utf-8"))
        bbox = info["bbox_8192"]
        x0, y0 = int(bbox["x0"]), int(bbox["y0"])
        lab = int(info["label"])
        wider = json.load(open(os.path.join(OUT_DIR, rid, "l2_world.json"), encoding="utf-8"))
        csz = wider["context_size"]
        tx, ty = wider["tiles_offset"]

        cells = []
        for t in l1["tiles"]:
            if int(t["region"]) != lab:
                continue
            rings = []
            for r in t.get("polygons", []):
                ring = [[round(float(p[0]) * 4 - (x0 - tx), 3),
                         round(float(p[1]) * 4 - (y0 - ty), 3)] for p in r]
                if len(ring) >= 3:
                    rings.append(ring)
            cells.append({
                "label": int(t["label"]),
                "city": [round(float(t["city"][0]) * 4 - (x0 - tx), 3),
                         round(float(t["city"][1]) * 4 - (y0 - ty), 3)],
                "rgb": list(t["rgb"]),
                "polygons": rings,
                "small_exempt": bool(t.get("small_exempt", False)),
            })

        out = {
            "region_id": rid,
            "region_label": lab,
            "context_size": csz,
            "tiles_offset": [tx, ty],
            "source_size_2048": size2,
            "cells": cells,
        }
        outd = os.path.join(OUT_DIR, rid)
        os.makedirs(outd, exist_ok=True)
        with open(os.path.join(outd, "l1_split.json"), "w", encoding="utf-8") as f:
            json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
        gamed = os.path.join(GAME_DIR, rid)
        os.makedirs(gamed, exist_ok=True)
        shutil.copy(os.path.join(outd, "l1_split.json"), os.path.join(gamed, "l1_split.json"))
        print("  %s (label %d): L1 细胞 %d 个 -> %s/l1_split.json" % (rid, lab, len(cells), gamed))
    print("完成。输出: %s" % OUT_DIR)


if __name__ == "__main__":
    main()