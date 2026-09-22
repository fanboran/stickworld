"""L1 政治模式分层图导出 —— 渲染链逐层单独成图，供人工识图定位错层。

按 map_renderer._draw 政治分支的叠序，用数据真值离线复刻每层（与游戏渲染
的差异仅在 AA/字体，几何与色彩同源）：

  layer1_terrain            地形贴图原样（第 1 层，含海/湖/河/C 版源流带）
  layer2_blocks_flat        色块形状平涂（本省城邦色不透明 + 邻省政权色暗一阶，
                            海底色——只看形状与边界，无地形干扰）
  layer3_composite          第 1+2/3 层合成（色块 0.55 半透明叠地形 = 政治观感）
  layer4_borders            描边层（贴图底 + 国色描边 3px，贴水面段断开）
  layer5_base_and_mask      l1_base / l1_mask 并排（回退底图与索引图）

用法：python tools/worldgen/l1/layer_dump.py [--pack l1_001]
产物：stick-world/temp/l1_layers/
"""
import argparse
import json
import os

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
GAME_DIR = os.path.normpath(os.path.join(
    HERE, "..", "..", "..", "stick-world", "config", "strategic_map"))
OUT_DIR = os.path.normpath(os.path.join(
    HERE, "..", "..", "..", "stick-world", "temp", "l1_layers"))
FILL_ALPHA = 0.55
NEIGHBOR_DIM = 0.28
BORDER_W = 3.0


def rasterize(polys, side, color):
    img = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for ring in polys:
        if len(ring) >= 3:
            d.polygon([(float(p[0]), float(p[1])) for p in ring], fill=color)
    return np.asarray(img, dtype=np.float32)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pack", default=None, help="出生包（默认）或 l1_packs 目录名")
    args = ap.parse_args()
    pack_dir = GAME_DIR if not args.pack else os.path.join(GAME_DIR, "l1_packs", args.pack)
    with open(os.path.join(pack_dir, "l1_world.json"), encoding="utf-8") as f:
        world = json.load(f)
    side = int(world["context_size"][0])
    pol_path = os.path.join(GAME_DIR, "l1_province_politics.json")
    politics = json.load(open(pol_path, encoding="utf-8")) if os.path.exists(pol_path) else {}
    pol_color = {}
    for label, info in politics.get("provinces", {}).items():
        if isinstance(info, dict) and info.get("color"):
            pol_color[int(label)] = info["color"]
    os.makedirs(OUT_DIR, exist_ok=True)

    terrain = np.asarray(Image.open(os.path.join(pack_dir, "l1_terrain.png"))
                         .convert("RGB"), dtype=np.float32)

    # ---- layer1 地形贴图原样
    Image.fromarray(terrain.astype(np.uint8)).save(os.path.join(OUT_DIR, "layer1_terrain.png"))

    # ---- layer2 色块平涂（本省 states 色 + 邻省政权色暗一阶）
    flat = np.full((side, side, 3), (30, 55, 95), dtype=np.float32)
    for nb in world.get("neighbors", []):
        rgb = pol_color.get(int(nb.get("label", 0)))
        c = tuple(int(v * (1.0 - NEIGHBOR_DIM)) for v in rgb) if rgb else (115, 115, 115)
        m = rasterize(nb.get("polygons", []), side, c + (255,))[..., :3]
        flat = np.where(m > 0, m, flat)
    for t in world.get("tiles", []):
        sid = t.get("owner_state_id")
        st = next((s for s in world.get("states", []) if s.get("state_id") == sid), None)
        c = tuple(st["color"]) if st else (150, 150, 150)
        m = rasterize(t.get("polygons", []), side, c + (255,))[..., :3]
        flat = np.where(m > 0, m, flat)
    Image.fromarray(flat.astype(np.uint8)).save(os.path.join(OUT_DIR, "layer2_blocks_flat.png"))

    # ---- layer3 半透明合成（政治观感）
    comp = flat * FILL_ALPHA + terrain * (1.0 - FILL_ALPHA)
    Image.fromarray(np.clip(comp, 0, 255).astype(np.uint8)).save(
        os.path.join(OUT_DIR, "layer3_composite.png"))

    # ---- layer4 描边层（贴图底 + 国色描边；贴水面段用数据侧近似：湖/河多边形
    #      缓冲区内不描，海岸描边保留）
    borders = Image.fromarray(terrain.astype(np.uint8)).convert("RGBA")
    drw = ImageDraw.Draw(borders)
    lake_buf = Image.new("L", (side, side), 0)
    dl = ImageDraw.Draw(lake_buf)
    for lake in world.get("lakes", []):
        if len(lake) >= 3:
            dl.polygon([(float(p[0]), float(p[1])) for p in lake], fill=255)
    river_buf = Image.new("L", (side, side), 0)
    dr = ImageDraw.Draw(river_buf)
    for rv in world.get("rivers", []):
        pts = [(float(p[0]), float(p[1])) for p in rv.get("pts", [])]
        if len(pts) >= 2:
            dr.line(pts, fill=255, width=int(float(rv.get("w", 2.0))) + 12, joint="curve")
    water_near = Image.new("L", (side, side), 0)
    dw = ImageDraw.Draw(water_near)
    for y in range(0, side, 2):
        for x in range(0, side, 2):
            pass  # 逐像素太慢——用 lake/river 缓冲图膨胀近似（draw 已加宽）
    def near_water(p):
        x, y = int(p[0]), int(p[1])
        if 0 <= x < side and 0 <= y < side:
            return lake_buf.getpixel((x, y)) > 0 or river_buf.getpixel((x, y)) > 0
        return False
    tol = side * 0.01
    for t in world.get("tiles", []):
        sid = t.get("owner_state_id")
        st = next((s for s in world.get("states", []) if s.get("state_id") == sid), None)
        c = tuple(int(v * 0.72) for v in st["color"]) if st else (60, 60, 60)
        for ring in t.get("polygons", []):
            if len(ring) < 3:
                continue
            pts = [(float(p[0]), float(p[1])) for p in ring]
            segs = []
            cur = []
            for i in range(len(pts)):
                a = pts[i]
                b = pts[(i + 1) % len(pts)]
                mid = ((a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5)
                if near_water(mid):
                    if len(cur) >= 2:
                        segs.append(cur)
                    cur = []
                else:
                    if not cur:
                        cur = [a]
                    cur.append(b)
            if len(cur) >= 2:
                segs.append(cur)
            for seg in segs:
                drw.line(seg, fill=c + (255,), width=int(BORDER_W), joint="curve")
    borders.convert("RGB").save(os.path.join(OUT_DIR, "layer4_borders.png"))

    # ---- layer5 base/mask 并排
    base = Image.open(os.path.join(pack_dir, "l1_base.png")).convert("RGB")
    mask = Image.open(os.path.join(pack_dir, "l1_mask.png")).convert("RGB")
    duo = Image.new("RGB", (side * 2 + 8, side), (20, 20, 20))
    duo.paste(base, (0, 0))
    duo.paste(mask, (side + 8, 0))
    duo.save(os.path.join(OUT_DIR, "layer5_base_and_mask.png"))

    print("完成 -> %s（5 张分层图）" % OUT_DIR)


if __name__ == "__main__":
    main()
