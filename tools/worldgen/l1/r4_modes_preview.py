"""R4 验收预览 —— 同一 L1 地块三模式渲染并排对比图（地形 / 政治 / 交通）。

三模式语义（创始人 2026-09-08 拍板，观感返工 §R4）：
  地形   = l1_terrain.png 贴图 + 建成区 blob + 城市中心点
  政治   = 运行时矢量政权色填充（tile polygon，无贴图）+ 地块界线；无建成区/道路
  交通   = l1_travel.png 贴图（含 R6 道路 casing）+ 城市中心点；无建成区
三画面必须截然不同；建成区仅地形模式可见。

数据源 = 出生 L1 包（l1_world.json + l1_terrain.png + l1_travel.png），与运行时
渲染器同源；blob 轮廓用 blob_bake.py 同公式函数（两端同源，预览即游戏内形状）。

用法：
  python r4_modes_preview.py [--pack l1_001]   # 缺省 = 出生包
  输出 tools/worldgen/output/r4_modes_<name>.png
"""
import argparse
import json
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import blob_bake as bb  # noqa: E402  blob 轮廓同公式（两端同源）

GAME_DIR = os.path.normpath(os.path.join(
    HERE, "..", "..", "..", "stick-world", "config", "strategic_map"))
OUT_DIR = os.path.normpath(os.path.join(HERE, "..", "output"))

FONT_CANDIDATES = ["C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/simhei.ttf"]

# 与 map_renderer.gd 常量同源（改色两端同步）
OCEAN_COLOR = (30, 55, 95)
BLOB_FILL = (round(0.62 * 255), round(0.57 * 255), round(0.50 * 255))
BLOB_EDGE = (round(0.24 * 255), round(0.20 * 255), round(0.15 * 255))
CITY_DOT = (242, 242, 230)
CITY_RING = (31, 31, 31)
BORDER_COLOR = (64, 64, 64)
TILE_BORDER_COLOR = (89, 89, 89)


def load_font(size):
    for fp in FONT_CANDIDATES:
        if os.path.exists(fp):
            try:
                return ImageFont.truetype(fp, size)
            except OSError:
                break
    return ImageFont.load_default()


def outline_world_pts(sref, params):
    """聚落 blob 轮廓（context 坐标）：同公式 16→72 点 + position 平移。"""
    cap = sref.get("blob_capacity") or [0.0] * 16
    s = float(sref.get("population_score") or 0.0)
    local = bb.blob_outline(sref["settlement_id"], int(sref.get("level", 1)), cap, s, params)
    px, py = sref["position_px"]
    return [(x + px, y + py) for x, y in local]


def panel_terrain(world, params, side):
    """地形模式：l1_terrain.png + blob + 城市中心点 + 出生 L1 轮廓。"""
    tex = Image.open(os.path.join(os.path.dirname(PACK_PATH), "l1_terrain.png")).convert("RGB")
    img = tex.resize((side, side), Image.LANCZOS) if tex.width != side else tex.copy()
    dr = ImageDraw.Draw(img)
    # 建成区 blob（仅本模式）
    for t in world["tiles"]:
        s = t.get("settlement")
        if not s:
            continue
        pts = outline_world_pts(s, params)
        if len(pts) < 3:
            continue
        dr.polygon(pts, fill=BLOB_FILL, outline=BLOB_EDGE)
    # 城市中心点 + 环
    for t in world["tiles"]:
        s = t.get("settlement")
        if not s:
            continue
        x, y = s["position_px"]
        dr.ellipse([x - 3, y - 3, x + 3, y + 3], fill=CITY_DOT, outline=CITY_RING)
    # 出生 L1 权威轮廓
    dr.line([(p[0], p[1]) for p in world["l1_polygon"]]
            + [(world["l1_polygon"][0][0], world["l1_polygon"][0][1])],
            fill=BORDER_COLOR, width=2)
    return img


def panel_political(world, side):
    """政治模式：政权色 tile 填充（运行时矢量语义）+ 地块界线；无贴图/建成区/道路。"""
    img = Image.new("RGB", (side, side), OCEAN_COLOR)
    dr = ImageDraw.Draw(img)
    colors = {s["state_id"]: tuple(s["color"]) for s in world.get("states", [])}
    # 政权色填充
    for t in world["tiles"]:
        poly = t.get("polygon") or []
        if len(poly) < 3:
            continue
        col = colors.get(t.get("owner_state_id"), (128, 128, 128))
        dr.polygon([(p[0], p[1]) for p in poly], fill=col)
    # 地块界线（内部城界）
    for t in world["tiles"]:
        poly = t.get("polygon") or []
        if len(poly) < 3:
            continue
        pts = [(p[0], p[1]) for p in poly]
        dr.line(pts + [pts[0]], fill=TILE_BORDER_COLOR, width=1)
    # 出生 L1 权威轮廓（略粗）
    pts = [(p[0], p[1]) for p in world["l1_polygon"]]
    dr.line(pts + [pts[0]], fill=BORDER_COLOR, width=2)
    return img


def panel_traffic(world, side):
    """交通模式：l1_travel.png（地形底图 + R6 道路 casing 已烘焙）+ 城市中心点。"""
    tex = Image.open(os.path.join(os.path.dirname(PACK_PATH), "l1_travel.png")).convert("RGB")
    img = tex.resize((side, side), Image.LANCZOS) if tex.width != side else tex.copy()
    dr = ImageDraw.Draw(img)
    for t in world["tiles"]:
        s = t.get("settlement")
        if not s:
            continue
        x, y = s["position_px"]
        dr.ellipse([x - 3, y - 3, x + 3, y + 3], fill=CITY_DOT, outline=CITY_RING)
    return img


def main():
    global PACK_PATH
    ap = argparse.ArgumentParser(description="R4 三模式并排验收预览")
    ap.add_argument("--pack", default="spawn", help="spawn = 出生包，或目录名如 l1_001")
    args = ap.parse_args()

    if args.pack == "spawn":
        pack_dir = GAME_DIR
    else:
        pack_dir = os.path.join(GAME_DIR, "l1_packs", args.pack)
    PACK_PATH = os.path.join(pack_dir, "l1_world.json")
    with open(PACK_PATH, encoding="utf-8") as f:
        world = json.load(f)
    params = bb.load_params()

    side = 760
    panels = [
        ("地形（贴图 + 建成区）", panel_terrain(world, params, side)),
        ("政治（政权色 + 界线）", panel_political(world, side)),
        ("交通（底图 + 道路）", panel_traffic(world, side)),
    ]

    title_h = 48
    gap = 10
    combo = Image.new("RGB", (side * 3 + gap * 2, side + title_h), (24, 24, 24))
    dr = ImageDraw.Draw(combo)
    font = load_font(22)
    for i, (name, img) in enumerate(panels):
        x = i * (side + gap)
        dr.text((x + 10, 12), name, fill=(230, 230, 230), font=font)
        combo.paste(img, (x, title_h))
    name = "r4_modes_%s.png" % ("spawn" if args.pack == "spawn" else args.pack)
    out = os.path.join(OUT_DIR, name)
    combo.save(out)
    print("三模式并排预览 -> %s" % out)


if __name__ == "__main__":
    main()
