"""R3 地块边缘平滑特写对比图 —— 验收用。

并排渲染同一窗口的「patch 前（git HEAD 整数台阶轮廓）」vs「patch 后（find_contours
亚像素等值线）」多边形填充，另加一张高倍放大图验证放大无台阶。

用法：
  python tools/worldgen/l1/smooth_closeup.py
  python tools/worldgen/l1/smooth_closeup.py --pack l1_004 --city city_0212
产出 output/smooth_closeup_<pack>_<city>.png（四联：旧 4x / 新 4x / 新 12x / 旧 12x）
"""
import argparse
import json
import os
import subprocess

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # tools/worldgen
GAME_DIR = os.path.normpath(os.path.join(
    HERE, "..", "..", "stick-world", "config", "strategic_map"))
OCEAN = (30, 55, 95)
NEIGHBOR = (115, 115, 115)
LAKE = (72, 116, 158)


def load_old(pack_dir, name):
    """git HEAD 版本的包 json（patch 前几何）。"""
    rel = os.path.relpath(os.path.join(pack_dir, name), os.path.normpath(os.path.join(HERE, "..", "..")))
    raw = subprocess.run(["git", "show", "HEAD:%s" % rel.replace("\\", "/")],
                         capture_output=True, check=True).stdout
    return json.loads(raw)


def load_new(pack_dir):
    with open(os.path.join(pack_dir, "l1_world.json"), encoding="utf-8") as f:
        return json.load(f)


def render(world, win, scale, size):
    """窗口 win=(x0,y0,x1,y1) 内的多边形填充渲染（scale 放大）。"""
    img = Image.new("RGB", (size, size), OCEAN)
    dr = ImageDraw.Draw(img)
    x0, y0, x1, y1 = win

    def draw_ring(ring, fill, outline, width):
        pts = [((p[0] - x0) * scale, (p[1] - y0) * scale) for p in ring]
        if len(pts) >= 3:
            dr.polygon(pts, fill=fill)
        if outline and len(pts) >= 2:
            dr.line(pts + [pts[0]], fill=outline, width=width)

    for nb in world.get("neighbors", []):
        for poly in nb.get("polygons", []):
            draw_ring(poly, NEIGHBOR, (90, 90, 90), max(1, int(scale // 2)))
    for lk in world.get("lakes", []):
        draw_ring(lk, LAKE, None, 0)
    for t in world.get("tiles", []):
        col = (120, 140, 100)   # 中性绿代替政权色（对比几何不对比配色）
        polys = t.get("polygons") or [t.get("polygon", [])]
        for poly in polys:
            draw_ring(poly, col, (40, 55, 30), max(1, int(scale // 2)))
    return img


def main():
    ap = argparse.ArgumentParser(description="R3 平滑前后特写对比")
    ap.add_argument("--pack", default=".",
                    help="包目录名（l1_packs/l1_004 等；'.' = 出生包 config/strategic_map）")
    ap.add_argument("--city", default=None, help="特写城市 tile_id（默认取面积最大城）")
    ap.add_argument("--pad", type=int, default=25, help="特写窗口外扩 px")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    pack_dir = os.path.normpath(os.path.join(GAME_DIR, args.pack))
    old = load_old(pack_dir, "l1_world.json")
    new = load_new(pack_dir)

    tile = None
    for t in new["tiles"]:
        if args.city and t["tile_id"] == args.city:
            tile = t
            break
        if tile is None or _area(t.get("polygon", [])) > _area(tile.get("polygon", [])):
            tile = t
    assert tile is not None, "城市未找到"
    poly = tile["polygon"]
    xs = [p[0] for p in poly]
    ys = [p[1] for p in poly]
    bx0, bx1 = int(min(xs)) - args.pad, int(max(xs)) + args.pad
    by0, by1 = int(min(ys)) - args.pad, int(max(ys)) + args.pad
    side = max(bx1 - bx0, by1 - by0)
    win = (bx0, by0, bx0 + side, by0 + side)
    print("特写窗口 %s（%s）" % (win, tile["tile_id"]))

    size = 480
    imgs = [
        ("旧几何 4x（整数台阶）", render(old, win, size / side, size)),
        ("新几何 4x（亚像素平滑）", render(new, win, size / side, size)),
        ("旧几何 12x", render(old, win, size * 2.4 / side, size)),
        ("新几何 12x", render(new, win, size * 2.4 / side, size)),
    ]
    sheet = Image.new("RGB", (size * 2 + 30, (size + 34) * 2 + 10), (24, 24, 24))
    from PIL import ImageFont, ImageDraw as D2
    for i, (label, im) in enumerate(imgs):
        cx, cy = (i % 2) * (size + 30) + 10, (i // 2) * (size + 34) + 26
        sheet.paste(im, (cx, cy))
        D2.Draw(sheet).text((cx, cy - 18), label, fill=(230, 230, 230))
    out = args.out or os.path.join(
        HERE, "output", "smooth_closeup_%s_%s.png" % (
            os.path.basename(pack_dir) or "birth", tile["tile_id"]))
    sheet.save(out)
    print("->", out)


def _area(ring):
    if len(ring) < 3:
        return 0.0
    a = 0.0
    for k in range(len(ring)):
        x1, y1 = ring[k]
        x2, y2 = ring[(k + 1) % len(ring)]
        a += x1 * y2 - x2 * y1
    return a * 0.5


if __name__ == "__main__":
    main()
