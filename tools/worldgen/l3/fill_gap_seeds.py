# -*- coding: utf-8 -*-
"""缝隙填充灰点（创始人定稿）：撒点版聚落保留，在其「主张盘」之间的空隙处
补撒**规模 0 的灰色点**（level 0 / population_score 0 / dominant 场采样）——
这些点的地块盘把地图填满成「没有一块没被地块覆盖的像素」；它们不参与政权
划分（无主 → 渲染灰）。

用法：python fill_gap_seeds.py [--spacing 190] [--cap 110]
"""
import argparse
import json
import math
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fields_common as fc  # noqa: E402

FIELDS = fc.FIELDS_DIR
S = 2048
K = fc.SIZE / fc.SIZE_FULL  # 8192 → 2048


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--spacing", type=float, default=190.0, help="填充点间距（8192 级 px）")
    ap.add_argument("--cap", type=float, default=110.0, help="主张盘封顶半径（8192 级 px）")
    args = ap.parse_args()

    P = fc.load_params()["fields_v2"]["settlements"]
    data = json.load(open(os.path.join(FIELDS, "settlements_v2.json"), encoding="utf-8"))
    pts = data["settlements"]
    n0 = len(pts)
    suit = np.load(os.path.join(FIELDS, "suitability.npy")).astype(np.float32)[::4, ::4]
    biome = np.load(os.path.join(fc.OUTPUT_DIR, "biome_labels_2048.npy"))
    domf = np.load(os.path.join(FIELDS, "culture_field.npy"))
    mixf = np.load(os.path.join(FIELDS, "culture_mix.npy"))
    if domf.shape[0] != S:
        domf = np.asarray(domf)[::4, ::4]
        mixf = np.asarray(mixf)[::4, ::4]
    land = biome > 0
    # 排除湖（湖不该有地块）：用 lake 掩膜粗判（fractal_lake_mask）
    lake = np.array(Image.open(os.path.join(
        fc.OUTPUT_DIR, "fractal_lake_mask_8192.png")).convert("L")) > 127
    lake = lake[::4, ::4]

    r_min = float(P["r_min_px"])
    r_max = float(P["r_max_px"])
    rc = float(P["radius_curve"])
    s_min = float(P["suit_min"])
    cap = args.cap
    scale = float(P.get("claim_scale", 1.0))

    # 已有盘并集（claim = min(泊松半径, cap)；与 city_split_v3 同式）
    covered = np.zeros((S, S), dtype=bool)
    for s in pts:
        sv = float(suit[min(int(s["y"] * K), S - 1), min(int(s["x"] * K), S - 1)])
        t = max(0.0, min(1.0, (sv - s_min) / max(1.0 - s_min, 1e-6)))
        r_px = r_max - (r_max - r_min) * (t ** rc)
        r_use = min(r_px, cap) * scale * K
        cx, cy = s["x"] * K, s["y"] * K
        x0, x1 = max(0, int(cx - r_use)), min(S, int(cx + r_use) + 1)
        y0, y1 = max(0, int(cy - r_use)), min(S, int(cy + r_use) + 1)
        if x1 <= x0 or y1 <= y0:
            continue
        yy, xx = np.mgrid[y0:y1, x0:x1]
        covered[y0:y1, x0:x1] |= ((yy - cy) ** 2 + (xx - cx) ** 2) <= r_use * r_use
    gap = land & ~lake & ~covered
    print("缝隙（陆地∧非湖∧盘外）: %d px（%.1f%% 陆地）"
          % (int(gap.sum()), 100.0 * gap.sum() / max(int((land & ~lake).sum()), 1)))

    # 网格撒填充点：多轮迭代（间距逐轮 ×0.7）直到残缝 < 0.5% 陆地
    added = 0
    label = n0
    filler_r = cap * scale  # filler 的 claim 与正常点同口径（cap×scale）
    land_n = max(int((land & ~lake).sum()), 1)
    sp = args.spacing
    rounds = 0
    while True:
        rounds += 1
        step = max(3, int(round(sp * K)))
        for gy in range(step // 2, S, step):
            for gx in range(step // 2, S, step):
                if not gap[gy, gx]:
                    continue
            # 邻域再查（边界点尽量贴缝隙）：若周围 1 格内已填，跳过（防堆积）
                x8, y8 = int(gx / K), int(gy / K)
                label += 1
                pts.append({
                    "label": label,
                    "settlement_id": "settlement_city_%03d" % label,
                    "x": x8, "y": y8,
                    "level": 0,
                    "population_score": 0.0,
                    "dominant": int(domf[min(gy, S - 1), min(gx, S - 1)]),
                    "mix": float(mixf[min(gy, S - 1), min(gx, S - 1)]),
                    "filler": True,
                })
                added += 1
                cx, cy = gx, gy
                r_use = filler_r * K
                x0, x1 = max(0, int(cx - r_use)), min(S, int(cx + r_use) + 1)
                y0, y1 = max(0, int(cy - r_use)), min(S, int(cy + r_use) + 1)
                yy, xx = np.mgrid[y0:y1, x0:x1]
                m = ((yy - cy) ** 2 + (xx - cx) ** 2) <= r_use * r_use
                covered[y0:y1, x0:x1] |= m
                gap = land & ~lake & ~covered
        gap2 = int(gap.sum())
        print("  轮 %d（间距 %.0f）：累计填充 %d，残缝 %.3f%%"
              % (rounds, sp, added, 100.0 * gap2 / land_n))
        if gap2 <= 0.005 * land_n or rounds >= 6:
            break
        sp *= 0.7
    gap2 = int(gap.sum())
    print("填充点 %d 个（label %d..%d）；剩余未覆盖 %d px（%.3f%% 陆地）"
          % (added, n0 + 1, label, gap2,
             100.0 * gap2 / max(int((land & ~lake).sum()), 1)))
    data.setdefault("meta", {})["fillers"] = {"n": added, "spacing_px": args.spacing,
                               "claim_cap_px": cap,
                               "note": "规模 0 灰色填充点：铺满地图、不参与政权（无主灰）"}
    with open(os.path.join(FIELDS, "settlements_v2.json"), "w",
              encoding="utf-8", newline="\n") as f:
        json.dump(data, f, ensure_ascii=False)
    print("已写 settlements_v2.json（%d 正常点 + %d 填充点）" % (n0, added))


if __name__ == "__main__":
    main()
