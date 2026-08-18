"""L2 城市模式贴图导出 —— 点开 L2 地区后可选"下探到城市"模式（像 L3 城市模式）。

输入：output/l1_v2/city_preview_2048.png（全局城市蒙版视觉）+ l2_packs/region_XXX/
      （info.json bbox_8192 / tiles_8192.npy）
输出（每地区，写入 config/strategic_map/l2_packs/region_XXX/l2_city_preview.png）：
  RGBA context 尺寸贴图：该地区陆地(tiles 区域)填城市蒙版色，其余全透明
  —— 运行时 L2 城市模式 draw_texture_rect 铺在 context 上，露出底层海洋/邻居/湖泊。

用法：
  python tools/worldgen/l1/export_l2_city_previews.py [region_XXX ...]
"""
import json
import os
import shutil

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # tools/worldgen
V2_DIR = os.path.join(HERE, "output", "l1_v2")
L2_PACKS = os.path.join(HERE, "output", "l2_packs")
OUT_DIR = os.path.join(HERE, "output", "l2_view_packs")
GAME_DIR = os.path.normpath(os.path.join(
    HERE, "..", "..", "stick-world", "config", "strategic_map", "l2_packs"))


def main():
    rids = (os.environ.get("PARTIAL_REGIONS") or "").split()
    rids = rids or sorted(d for d in os.listdir(L2_PACKS) if d.startswith("region_"))
    city_prev = np.array(Image.open(os.path.join(V2_DIR, "city_preview_2048.png")).convert("RGB"))

    for rid in rids:
        info = json.load(open(os.path.join(L2_PACKS, rid, "info.json"), encoding="utf-8"))
        bbox = info["bbox_8192"]
        x0, y0 = int(bbox["x0"]), int(bbox["y0"])
        tiles = np.load(os.path.join(L2_PACKS, rid, "tiles_8192.npy")).astype(np.int32)
        wider = json.load(open(os.path.join(OUT_DIR, rid, "l2_world.json"), encoding="utf-8"))
        ctx_w, ctx_h = wider["context_size"]
        tx, ty = wider["tiles_offset"]
        H, W = tiles.shape   # bbox 尺寸

        # context 尺寸 RGBA：全透明（0），tiles 区域填城市蒙版色
        out = np.zeros((ctx_h, ctx_w, 4), dtype=np.uint8)
        for yy in range(H):
            gyy = y0 + yy
            for xx in range(W):
                v = tiles[yy, xx]
                if v <= 0:
                    continue   # 海洋/湖/非地块 -> 透明，露出底层
                # 全局 8192 像素 (gy,gx) -> city_preview 2048 像素（y//4, x//4）
                gx = x0 + xx
                cpx, cpy = gx // 4, gyy // 4
                c = city_prev[cpy, cpx]
                cy, cx = ty + yy, tx + xx   # context 坐标
                if 0 <= cy < ctx_h and 0 <= cx < ctx_w:
                    out[cy, cx, 0] = c[0]
                    out[cy, cx, 1] = c[1]
                    out[cy, cx, 2] = c[2]
                    out[cy, cx, 3] = 255

        img = Image.fromarray(out)
        # 输出到 l2_view_packs（开发产物）与 config（运行时）
        os.makedirs(os.path.join(OUT_DIR, rid), exist_ok=True)
        src = os.path.join(OUT_DIR, rid, "l2_city_preview.png")
        img.save(src)
        dst = os.path.join(GAME_DIR, rid)
        os.makedirs(dst, exist_ok=True)
        shutil.copy(src, os.path.join(dst, "l2_city_preview.png"))
        n_color = int((out[..., 3] > 0).sum())
        print("  %s: ctx %dx%d 城市贴图像素数 %d" % (rid, ctx_w, ctx_h, n_color))
    print("完成。")


if __name__ == "__main__":
    main()