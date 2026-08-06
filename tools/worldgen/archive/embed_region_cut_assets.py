"""内嵌 region 资源到 region_cut_tool.html（画线切割工具，打开即用）。

用法：
  python tools/worldgen/embed_region_cut_assets.py
"""
import base64
import os

HERE = os.path.dirname(os.path.abspath(__file__))
HTML = os.path.join(HERE, "region_cut_tool.html")
REGIONS = os.path.join(HERE, "..", "output", "regions")

BASE_PNG = os.path.join(REGIONS, "region_preview_unique_labels.png")
COLOR_PNG = os.path.join(REGIONS, "region_preview_unique.png")


def data_url_png(path):
    with open(path, "rb") as f:
        return "data:image/png;base64," + base64.b64encode(f.read()).decode()


def main():
    html = open(HTML, encoding="utf-8").read()
    base = data_url_png(BASE_PNG)
    color = data_url_png(COLOR_PNG)
    html = html.replace("__EMBED_BASE__", '"%s"' % base)
    html = html.replace("__EMBED_COLOR__", '"%s"' % color)
    with open(HTML, "w", encoding="utf-8") as f:
        f.write(html)
    print("已内嵌: %s (%.0f KB)" % (BASE_PNG, os.path.getsize(BASE_PNG) / 1024))
    print("已内嵌: %s (%.0f KB)" % (COLOR_PNG, os.path.getsize(COLOR_PNG) / 1024))
    print("HTML 大小: %.0f KB" % (os.path.getsize(HTML) / 1024))


if __name__ == "__main__":
    main()
