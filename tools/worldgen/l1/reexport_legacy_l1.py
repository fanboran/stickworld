"""老 L1 省界重导（水陆同源·创始人 2026-09-22 拍板 A：省界跟城块走）。

背景：城块划分（city_split_v3 + refine，parent_l1 挂城市归属）是玩法真值，
但 legacy_l1_labels_8192.npy（老 L1 省蒙版）停留在城块重划之前的旧省界——
沿海城块沿河重划后，城块边界与省界两套真值打架（实测：半岛区 legacy 87% 说 69、
城块 parent 说 68；左缘城块锯齿 1017/1020/1021/1025(68) 插进 legacy 67 条带）。
渲染层忠实呈现矛盾 = 「半岛头部异色 / 省界分叉」。

口径：**每个老 L1 省 = 其内部城块（city_data.parent_l1）的并集**。
  - 城块像素（refined > 0）→ 按其 parent_l1 归省（逐像素，不用质心投票——
    城块边界即省边界，锯齿随之自然消失）；
  - 无城块覆盖的陆地（refined == 0 且陆地）：EDT 最近城块的 parent 归省
    （内陆零碎水域/细化场空洞随近邻；**水面保持 0**，省不进海/湖）；
  - 海/湖 = 0。

用法：
  python tools/worldgen/l1/reexport_legacy_l1.py            # 干跑：统计逐省分歧
  python tools/worldgen/l1/reexport_legacy_l1.py --write    # 覆写 legacy_l1_labels_8192.npy
重导后须全链重跑：export_l1_view_context（70 包）→ l1_terrain_bake → l_world_bake.gd。
"""
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage as ndi

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(HERE, "l2_export"))
import land_snap  # noqa: E402

OUTPUT_DIR = os.path.join(HERE, "output")
V2_DIR = os.path.join(OUTPUT_DIR, "l1_v2")


def main():
    ap = argparse.ArgumentParser(description="老 L1 省界重导（省界=城块 parent 聚合）")
    ap.add_argument("--write", action="store_true", help="覆写 legacy_l1_labels_8192.npy")
    args = ap.parse_args()

    refined = np.load(os.path.join(V2_DIR, "refined_city_labels_8192.npy")).astype(np.int32)
    legacy = np.load(os.path.join(V2_DIR, "legacy_l1_labels_8192.npy")).astype(np.int32)
    citydata = json.load(open(os.path.join(V2_DIR, "city_data.json"), encoding="utf-8"))
    parent = {int(c["label"]): int(c["parent_l1"]) for c in citydata["cities"]}

    print("[1/3] 城块像素按 parent 归省 ...")
    n_lab = int(refined.max())
    prov_lut = np.zeros(n_lab + 1, dtype=np.int32)
    for lab, p in parent.items():
        if lab <= n_lab:
            prov_lut[lab] = p
    prov = prov_lut[refined]          # 城块像素 → 省；refined==0 处 → 0

    print("[2/3] 无城块陆地按 EDT 最近城块的 parent 归省 ...")
    land, _lake, _river = land_snap.load_water_masks(OUTPUT_DIR)
    holes = land & (refined == 0)     # 陆地上无城块覆盖（内陆水/空洞）
    n_hole_filled = 0
    if holes.any() and (prov > 0).any():
        _, idx = ndi.distance_transform_edt(prov == 0, return_indices=True)
        src = prov[idx[0], idx[1]]
        take = holes & (src != 0)
        prov[take] = src[take]
        n_hole_filled = int(take.sum())
    prov[~land] = 0                   # 海不进省

    print("[3/3] 对比旧省界 ...")
    diff = (prov != legacy) & ((prov > 0) | (legacy > 0))
    n_diff = int(diff.sum())
    print("  与旧蒙版差异 %d px（%.2f%% 全图）" % (n_diff, 100.0 * n_diff / prov.size))
    # 逐省面积变化 Top
    for p in np.unique(np.concatenate([np.unique(prov[prov > 0]), np.unique(legacy[legacy > 0])])):
        a_new = int((prov == p).sum())
        a_old = int((legacy == p).sum())
        if abs(a_new - a_old) > 5000:
            print("  省 %d: %d -> %d px（%+d）" % (p, a_old, a_new, a_new - a_old))
    print("  陆地空洞回填 %d px" % n_hole_filled)

    if args.write:
        np.save(os.path.join(V2_DIR, "legacy_l1_labels_8192.npy"), prov.astype(np.int32))
        print("已覆写 legacy_l1_labels_8192.npy（省界=城块 parent 聚合）")
    else:
        print("[dry-run] 未写（--write 落地）")


if __name__ == "__main__":
    main()
