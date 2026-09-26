# -*- coding: utf-8 -*-
"""原地块位置优先复种（创始人定稿）——项目最初城块划分（submodule
l1_world.json / l1_packs/*/l1_world.json 的 tiles 多边形质心，几何自最初划分
未动）中，落在当前划分**灰色区**（city_labels==0 ∧ 陆地）的位置，直接作为
规模 0 聚落点写回 settlements_v2.json。

顺序契约（创始人指定）：本步在通用灰缝撒点（fill_gap_seeds）**之前**——灰区里
先有「原有地块位置」当点，插点收尾后才轮到算法贪心点。这些点与缝隙填充点同
语义（规模 0 / 不参与政权 / 主张盘满半径），只是位置来自创始人的原地块设置。

用法：python tools/worldgen/l3/origin_seed_recover.py [--min-dist 24]
"""
import argparse
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fields_common as fc  # noqa: E402

FIELDS = fc.FIELDS_DIR
GAME = fc.GAME_CFG
S = fc.SIZE


def original_tile_positions():
    """最初城块划分的各地块质心（8192 级，世界坐标 = 多边形均值 + world_origin）。"""
    pts = []
    packs = [("", os.path.join(GAME, "l1_world.json"))]
    for name in sorted(os.listdir(os.path.join(GAME, "l1_packs"))):
        p = os.path.join(GAME, "l1_packs", name, "l1_world.json")
        if os.path.isfile(p):
            packs.append((name, p))
    for pname, ppath in packs:
        d = json.load(open(ppath, encoding="utf-8"))
        wo = d.get("world_origin") or [0.0, 0.0]
        for t in d.get("tiles", []):
            poly = t.get("polygon") or (t.get("polygons") or [[]])[0]
            if not poly:
                continue
            arr = np.asarray(poly, dtype=np.float64)
            pts.append((float(arr[:, 0].mean()) + float(wo[0]),
                        float(arr[:, 1].mean()) + float(wo[1])))
    return pts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--min-dist", type=float, default=24.0,
                    help="与既有聚落/已复种点的最小间距（8192 级 px，防同位重复种子）")
    args = ap.parse_args()

    lab = np.load(os.path.join(fc.OUTPUT_DIR, "l1_v2", "city_labels_8192.npy"),
                  mmap_mode="r")
    parent = np.load(os.path.join(fc.OUTPUT_DIR, "l1_v2", "legacy_l1_labels_8192.npy"),
                     mmap_mode="r")
    domf = np.asarray(np.load(os.path.join(FIELDS, "culture_field.npy")))
    mixf = np.asarray(np.load(os.path.join(FIELDS, "culture_mix.npy")))
    if domf.shape[0] != S:
        domf, mixf = domf[::4, ::4], mixf[::4, ::4]
    K = fc.SIZE / fc.SIZE_FULL

    data = json.load(open(os.path.join(FIELDS, "settlements_v2.json"),
                          encoding="utf-8"))
    pts = data["settlements"]
    taken = np.array([[float(s["x"]), float(s["y"])] for s in pts],
                     dtype=np.float64)
    label = max(int(s["label"]) for s in pts)

    origins = original_tile_positions()
    n_land = n_gray = added = 0
    for x, y in origins:
        px, py = int(round(x)), int(round(y))
        if not (0 <= px < lab.shape[1] and 0 <= py < lab.shape[0]):
            continue
        n_land += 1
        if np.asarray(parent[py, px]) == 0:
            continue          # 质心落水：不复种（本步只认「陆地灰区」）
        if np.asarray(lab[py, px]) != 0:
            continue          # 已有地块：不动
        n_gray += 1
        if taken.size and np.min((taken[:, 0] - x) ** 2 + (taken[:, 1] - y) ** 2) \
                < args.min_dist ** 2:
            continue          # 与既有种子过近：跳过（防同位重复种子）
        label += 1
        sy, sx = min(int(y * K), S - 1), min(int(x * K), S - 1)
        pts.append({
            "label": label,
            "settlement_id": "settlement_city_%03d" % label,
            "x": float(x), "y": float(y),
            "level": 0,
            "population_score": 0.0,
            "dominant": int(domf[sy, sx]),
            "mix": float(mixf[sy, sx]),
            "filler": True,
            "origin": True,
        })
        taken = np.vstack([taken, [x, y]])
        added += 1
    with open(os.path.join(FIELDS, "settlements_v2.json"), "w",
              encoding="utf-8", newline="\n") as f:
        json.dump(data, f, ensure_ascii=False)
    print("原地块位置 %d 个（陆地 %d）；落在灰区 %d 个；复种 %d 个（总聚落 %d）"
          % (len(origins), n_land, n_gray, added, len(pts)))


if __name__ == "__main__":
    main()
