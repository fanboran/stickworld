# -*- coding: utf-8 -*-
"""审计#8：city_preview_8192.png 按细化场重生成（城市模式底图换新代形状）。

旧预览（游戏目录 l3_city_preview_8192.png）是 R3 旧代城块形状 + city_split 调色板；
本工具从旧预览逐 label 收割颜色（多数票，保证零色漂移），再用 S1 细化场
refined_city_labels_8192.npy 重新上形（label 编号不变，直接替换像素归属）。
城市点/描点样式照抄 city_split_v2.py [6/6]。

输出：
  output/l1_v2/city_preview_8192.png   （生成端中间件，l2 采样脚本读这里）
  config/strategic_map/l3_city_preview_8192.png  （运行时 L3 城市模式贴图，直接拷贝）

用法：
  python tools/worldgen/l1/rerender_city_preview.py
"""
import json
import os
import shutil

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # tools/worldgen
V2_DIR = os.path.join(HERE, "output", "l1_v2")
GAME_DIR = os.path.normpath(os.path.join(
    HERE, "..", "..", "stick-world", "config", "strategic_map"))
OLD_PREVIEW = os.path.join(GAME_DIR, "l3_city_preview_8192.png")


def main():
    refined = np.load(os.path.join(V2_DIR, "refined_city_labels_8192.npy")).astype(np.int32)
    old = np.load(os.path.join(V2_DIR, "city_labels_8192.npy")).astype(np.int32)
    old_prev = np.array(Image.open(OLD_PREVIEW).convert("RGB"))
    citydata = json.load(open(os.path.join(V2_DIR, "city_data.json"), encoding="utf-8"))
    res = refined.shape[0]
    assert old.shape == refined.shape == old_prev.shape[:2], "场/预览尺寸不一致"

    # ---- 1. 逐 label 收割旧预览颜色（旧场像素多数票；跨代边界像素噪声被淹没）----
    print("[1/3] 收割 %d 个 label 的旧色 ..." % len(citydata["cities"]))
    labs = old.ravel()
    cols = (old_prev[..., 0].astype(np.uint32) << 16
            | old_prev[..., 1].astype(np.uint32) << 8
            | old_prev[..., 2].astype(np.uint32)).ravel()
    keep = labs > 0
    labs, cols = labs[keep], cols[keep]
    pair = (labs.astype(np.uint64) << 32) | cols
    uniq, cnt = np.unique(pair, return_counts=True)
    palette = {}
    for lab in np.unique(labs):
        m = (uniq >> np.uint64(32)) == np.uint64(lab)
        best = uniq[m][np.argmax(cnt[m])]
        palette[int(lab)] = (int(best >> 16) & 0xFF, int(best >> 8) & 0xFF, int(best) & 0xFF)
    n_missing = sum(1 for c in citydata["cities"] if int(c["label"]) not in palette)
    print("  收割 %d 色，缺失 %d" % (len(palette), n_missing))

    # ---- 2. 细化场上形（LUT 查表）----
    print("[2/3] 细化场上色 ...")
    max_lbl = int(refined.max())
    lut = np.zeros((max_lbl + 1, 3), dtype=np.uint8)
    lut[0] = (30, 55, 95)                       # 海洋（city_split_v2 OCEAN_COLOR）
    n_fb = 0
    for c in citydata["cities"]:
        lbl = int(c["label"])
        if lbl > max_lbl:
            continue
        if lbl in palette:
            lut[lbl] = palette[lbl]
        else:                                   # 收割缺失（极小 label）→ city_data rgb 兜底
            lut[lbl] = tuple(int(v) for v in c["rgb"])
            n_fb += 1
    if n_fb:
        print("  %d label 用 city_data rgb 兜底" % n_fb)
    img = lut[refined]

    # ---- 3. 城市点（样式照抄 city_split_v2 [6/6]，city 坐标已是 8192）----
    print("[3/3] 城市点 + 落盘 ...")
    pil = Image.fromarray(img)
    from PIL import ImageDraw
    dr = ImageDraw.Draw(pil)
    dot_r = 3 * res // 2048
    for c in citydata["cities"]:
        x, y = float(c["city"][0]), float(c["city"][1])
        dr.ellipse([x - dot_r, y - dot_r, x + dot_r, y + dot_r], outline=(12, 12, 12), width=1)
        dr.ellipse([x - dot_r // 3, y - dot_r // 3, x + dot_r // 3, y + dot_r // 3],
                   fill=(250, 250, 250))
    pil.save(os.path.join(V2_DIR, "city_preview_8192.png"))
    shutil.copy(os.path.join(V2_DIR, "city_preview_8192.png"),
                os.path.join(GAME_DIR, "l3_city_preview_8192.png"))
    print("完成：city_preview_8192.png（%d 色）+ l3_city_preview_8192.png 拷贝" % len(palette))


if __name__ == "__main__":
    main()
