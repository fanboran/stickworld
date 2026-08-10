"""唯一色标注预览生成器 —— 给每个地区分配唯一颜色 + 编号标注，消除色板循环歧义。

用法：
  python tools/worldgen/region_preview_annotated.py [--size 2048]
输出：
  output/regions/region_preview_unique.png    # 每地区唯一色（含编号）
  output/regions/region_preview_unique_labels.png # 唯一色 + label 编号标注
  output/regions/color_map.json               # label -> 唯一色 十六进制
"""
import argparse
import json
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFont

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "output", "regions")


def unique_colors(n):
    """HSL 均匀分布生成 n 个可区分颜色（避免色板循环）。"""
    colors = []
    for i in range(n):
        h = (i * 0.618033988749895) % 1.0  # 黄金角均匀散布色相
        s = 0.65 + 0.2 * ((i * 7) % 3) / 2.0
        l = 0.45 + 0.25 * ((i * 11) % 3) / 2.0
        # HSL -> RGB
        c = (1 - abs(2 * l - 1)) * s
        x = c * (1 - abs((h * 6) % 2 - 1))
        m = l - c / 2
        if h < 1 / 6:
            r, g, b = c, x, 0
        elif h < 2 / 6:
            r, g, b = x, c, 0
        elif h < 3 / 6:
            r, g, b = 0, c, x
        elif h < 4 / 6:
            r, g, b = 0, x, c
        elif h < 5 / 6:
            r, g, b = x, 0, c
        else:
            r, g, b = c, 0, x
        colors.append((int((r + m) * 255), int((g + m) * 255), int((b + m) * 255)))
    return colors


def main():
    p = argparse.ArgumentParser(description="唯一色标注预览生成器")
    args = p.parse_args()

    labels = np.load(os.path.join(OUT_DIR, "region_labels.npy"))
    size = labels.shape[0]
    data = json.load(open(os.path.join(OUT_DIR, "region_data.json"), encoding="utf-8"))
    n_regions = data["n_regions"]

    # 唯一色（海洋用深蓝）
    colors = unique_colors(n_regions)
    ocean = (30, 55, 95)
    preview = np.zeros((size, size, 3), dtype=np.uint8)
    preview[labels == 0] = ocean
    color_map = {}
    for r in range(1, n_regions + 1):
        color = colors[r - 1]
        preview[labels == r] = color
        color_map[r] = "#%02x%02x%02x" % color

    img = Image.fromarray(preview)
    img.save(os.path.join(OUT_DIR, "region_preview_unique.png"))

    # 编号标注版（每个地区质心画 label 数字）
    img2 = img.convert("RGB")
    draw = ImageDraw.Draw(img2)
    try:
        font = ImageFont.truetype("arial.ttf", 18)
    except Exception:
        font = ImageFont.load_default()
    for r in range(1, n_regions + 1):
        ys, xs = np.where(labels == r)
        if ys.size == 0:
            continue
        cy, cx = int(ys.mean()), int(xs.mean())
        text = str(r)
        box = draw.textbbox((0, 0), text, font=font)
        tw, th = box[2] - box[0], box[3] - box[1]
        draw.rectangle([cx - tw / 2 - 2, cy - th / 2 - 2, cx + tw / 2 + 2, cy + th / 2 + 2],
                       fill=(0, 0, 0))
        draw.text((cx - tw / 2, cy - th / 2), text, fill=(255, 255, 255), font=font)
    img2.save(os.path.join(OUT_DIR, "region_preview_unique_labels.png"))

    with open(os.path.join(OUT_DIR, "color_map.json"), "w", encoding="utf-8") as f:
        json.dump({"ocean": "#1e375f", "labels": color_map}, f, indent=1)
    print("唯一色预览: ", os.path.join(OUT_DIR, "region_preview_unique.png"))
    print("编号标注图: ", os.path.join(OUT_DIR, "region_preview_unique_labels.png"))
    print("色表: ", os.path.join(OUT_DIR, "color_map.json"))
    print("地区数:", n_regions)


if __name__ == "__main__":
    main()
