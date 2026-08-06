"""内嵌岛蒙版资源到 isthmus_cut_tool.html（画线切割工具，打开即用）。

用法：
  python tools/worldgen/embed_isthmus_masks.py
"""
import base64
import os

HERE = os.path.dirname(os.path.abspath(__file__))
HTML = os.path.join(HERE, "isthmus_cut_tool.html")
MASKS = os.path.join(HERE, "..", "output", "regions", "isthmus_masks")

MASK8 = os.path.join(MASKS, "isthmus_8.png")
MASK3 = os.path.join(MASKS, "isthmus_3.png")


def data_url_png(path):
    with open(path, "rb") as f:
        return "data:image/png;base64," + base64.b64encode(f.read()).decode()


def main():
    html = open(HTML, encoding="utf-8").read()
    html = html.replace("__EMBED_MASK8__", '"%s"' % data_url_png(MASK8))
    html = html.replace("__EMBED_MASK3__", '"%s"' % data_url_png(MASK3))
    with open(HTML, "w", encoding="utf-8") as f:
        f.write(html)
    print("已内嵌: %s (%.0f KB)" % (MASK8, os.path.getsize(MASK8) / 1024))
    print("已内嵌: %s (%.0f KB)" % (MASK3, os.path.getsize(MASK3) / 1024))
    print("HTML 大小: %.0f KB" % (os.path.getsize(HTML) / 1024))


if __name__ == "__main__":
    main()
