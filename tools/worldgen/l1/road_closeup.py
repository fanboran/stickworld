"""L1 视图包道路特写 —— 8192 原生坐标下渲染单个 L1 pack 的城市块 + 道路（创始人观感验收用）。

底图取该包 l1_base.png（context 原生尺寸，与 l1_world.json 坐标一一对应），
叠加：地块轮廓（细灰）+ 道路（DIRT 土黄 / PAVED 亮橙，宽度按 tier）+ 聚落点（按级别）。
4× 超采样后缩回 --scale 倍，线条抗锯齿——看到的折线感即数据本身的折线感。

用法：
  python road_closeup.py                 # 出生根份 config/strategic_map/l1_world.json
  python road_closeup.py --pack 69       # l1_packs/l1_069
  python road_closeup.py --scale 2       # 输出 = context × 2 像素
产出：output/road_closeup_<name>.png
"""
import argparse
import json
import os

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # tools/worldgen
OUT_DIR = os.path.join(HERE, "output")
GAME_DIR = os.path.normpath(os.path.join(
    HERE, "..", "..", "stick-world", "config", "strategic_map"))

SS = 4   # 超采样倍数
STYLE = {"DIRT": ((196, 160, 96), 2.0), "PAVED": ((255, 186, 72), 3.5),
         "HIGHWAY": ((255, 110, 70), 5.0)}


def main():
    ap = argparse.ArgumentParser(description="L1 道路特写渲染")
    ap.add_argument("--pack", type=int, default=None, help="老 L1 label（默认出生根份）")
    ap.add_argument("--scale", type=float, default=2.0, help="输出相对 context 的放大倍数")
    args = ap.parse_args()
    if args.pack is None:
        d, name = GAME_DIR, "spawn"
    else:
        d, name = os.path.join(GAME_DIR, "l1_packs", "l1_%03d" % args.pack), "l1_%03d" % args.pack
    w = json.load(open(os.path.join(d, "l1_world.json"), encoding="utf-8"))
    side = int(w["size"])
    k = args.scale * SS
    S = int(side * k)

    base = Image.open(os.path.join(d, w["base_texture"])).convert("RGB").resize((S, S), Image.NEAREST)
    dr = ImageDraw.Draw(base)
    for t in w["tiles"]:
        for ring in t.get("polygons") or [t["polygon"]]:
            if len(ring) >= 3:
                dr.polygon([(x * k, y * k) for x, y in ring], outline=(20, 20, 20), width=int(SS))
    n_pl = 0
    for rd in w["roads"]:
        col, wd = STYLE.get(rd.get("tier", "DIRT"), STYLE["DIRT"])
        pl = rd.get("polyline")
        if pl is None:   # 无 polyline：回退直线（与运行时 l1_world_data 语义一致）
            pos = {t["settlement"]["settlement_id"]: t["settlement"]["position_px"]
                   for t in w["tiles"] if t.get("settlement")}
            pl = [pos[rd["from"]], pos[rd["to"]]]
            col = (255, 80, 80)
        else:
            n_pl += 1
        dr.line([(x * k, y * k) for x, y in pl], fill=col, width=max(1, int(wd * SS)),
                joint="curve")
    for t in w["tiles"]:
        s = t.get("settlement")
        if not s:
            continue
        x, y = s["position_px"][0] * k, s["position_px"][1] * k
        r = {1: 4, 2: 6, 3: 9}.get(int(s.get("level", 1)), 4) * SS * args.scale / 2
        col = {1: (225, 225, 225), 2: (245, 225, 130), 3: (255, 160, 70)}.get(int(s.get("level", 1)))
        dr.ellipse([x - r, y - r, x + r, y + r], fill=col, outline=(15, 15, 15), width=int(SS))
    out = base.resize((int(side * args.scale), int(side * args.scale)), Image.LANCZOS)
    path = os.path.join(OUT_DIR, "road_closeup_%s.png" % name)
    out.save(path)
    n_v = [len(rd.get("polyline") or []) for rd in w["roads"]]
    print("%s：context %d，道路 %d 条（含 polyline %d），顶点数 %s -> %s"
          % (name, side, len(w["roads"]), n_pl, n_v, path))


if __name__ == "__main__":
    main()
