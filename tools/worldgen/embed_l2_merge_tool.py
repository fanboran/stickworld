"""内嵌 L2 地块数据到 l2_merge_tool.html（标记工具，打开即用）。

每地区：tiles_preview_8192.png 缩小到 1024 内嵌 + tiles.json 内嵌。

用法：
  python tools/worldgen/embed_l2_merge_tool.py
"""
import base64
import io
import json
import os

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
HTML = os.path.join(HERE, "l2_merge_tool.html")
L2_DIR = os.path.join(HERE, "output", "l2_packs")

PREVIEW_MAX_W = 1024  # 预览图最大宽度（内嵌体积控制）


def data_url_png_resized(path, max_w):
    img = Image.open(path).convert("RGB")
    if img.width > max_w:
        img = img.resize((max_w, int(img.height * max_w / img.width)), Image.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()


def main():
    region_ids = sorted(
        d for d in os.listdir(L2_DIR) if d.startswith("region_")
    )
    images = {}
    tiles = {}
    native_sizes = {}  # {rid: [w, h]} 原生 8192 裁切尺寸（坐标换算用）
    for rid in region_ids:
        d = os.path.join(L2_DIR, rid)
        prev = os.path.join(d, "tiles_preview_8192.png")
        tjson = os.path.join(d, "tiles.json")
        if not os.path.exists(prev) or not os.path.exists(tjson):
            print("  跳过 %s（缺预览/tiles.json）" % rid)
            continue
        im = Image.open(prev)
        native_sizes[rid] = [im.width, im.height]
        images[rid] = data_url_png_resized(prev, PREVIEW_MAX_W)
        with open(tjson, encoding="utf-8") as f:
            tiles[rid] = json.load(f)
        print("  %s: 原生 %dx%d, %d 个地块" % (rid, im.width, im.height, len(tiles[rid]["tiles"])))

    html = open(HTML, encoding="utf-8").read()
    html = html.replace("__EMBED_IMAGES__", json.dumps(images, ensure_ascii=False))
    html = html.replace("__EMBED_TILES__", json.dumps(tiles, ensure_ascii=False))
    html = html.replace("__EMBED_SIZES__", json.dumps(native_sizes))
    with open(HTML, "w", encoding="utf-8") as f:
        f.write(html)
    print("已内嵌 %d 个地区。HTML: %.1f KB" % (len(images), os.path.getsize(HTML) / 1024))


if __name__ == "__main__":
    main()
