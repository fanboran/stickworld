"""L1 政治层复刻渲染（一次性诊断）：按 map_renderer 的实际叠序离线复现，
用于定位"省份色块与地图不严丝合缝"到底出在哪一层。

叠序（与 map_renderer._draw 一致）：
  1) 地形贴图整幅 1:1 贴上
  2) 邻省块（暗一阶政权色，alpha=POLITICAL_FILL_ALPHA）
  3) 本省地块（政权色，alpha=POLITICAL_FILL_ALPHA）
  4) 水面回贴（RGB=贴图原样，A=waterness）
输出：out_dir/full.png + 沿岸/省界放大 crop（最近邻放大 6 倍便于肉眼看缝）。

用法：python tools/worldgen/l1/render_l1_political_replica.py [l1_label=69]
"""
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[3]
SM = ROOT / "stick-world" / "config" / "strategic_map"
POLITICAL_FILL_ALPHA = 0.55
L1_NEIGHBOR_DIM = 0.28
L1_WATER_GB_MID = -0.06
L1_WATER_GB_SOFT = 0.03
OUT = ROOT / "stick-world" / "temp" / "audit_l1_fit"


def load(label: int):
    if label == 69:
        return json.loads((SM / "l1_world.json").read_text(encoding="utf-8")), SM
    base = SM / "l1_packs" / f"l1_{label:03d}"
    return json.loads((base / "l1_world.json").read_text(encoding="utf-8")), base


def state_color(d, state_id) -> tuple:
    for s in d.get("states", []):
        if s.get("state_id") == state_id or s.get("id") == state_id:
            c = s.get("color", [128, 128, 128])
            return tuple(int(v) for v in c[:3])
    return (128, 128, 128)


def main(label: int) -> None:
    d, base = load(label)
    size = int(d["size"])
    ter = np.array(Image.open(base / "l1_terrain.png").convert("RGB")).astype(np.float32)
    canvas = ter.copy()

    def tint(mask_img: Image.Image, rgb, alpha):
        a = np.array(mask_img).astype(np.float32) / 255.0 * alpha
        a = a[:, :, None]
        c = np.array(rgb, dtype=np.float32)[None, None, :]
        out = canvas * (1.0 - a) + c * a
        np.copyto(canvas, out)

    # 自表：state_id -> 色（地块级）
    tile_masks = []
    for t in d["tiles"]:
        im = Image.new("L", (size, size), 0)
        ImageDraw.Draw(im).polygon([(float(p[0]), float(p[1])) for p in t["polygon"]], fill=255)
        tile_masks.append(im)
    # 2) 邻省块
    pol = json.loads((SM / "l1_province_politics.json").read_text(encoding="utf-8"))
    lut = {int(k): v for k, v in pol["provinces"].items()}
    for nb in d.get("neighbors", []):
        im = Image.new("L", (size, size), 0)
        dr = ImageDraw.Draw(im)
        for pg in nb.get("polygons", []):
            if len(pg) >= 3:
                dr.polygon([(float(p[0]), float(p[1])) for p in pg], fill=255)
        ent = lut.get(int(nb["label"]))
        rgb = tuple(ent["color"][:3]) if ent else (128, 128, 128)
        rgb = tuple(max(0, min(255, int(round(v * (1.0 - L1_NEIGHBOR_DIM))))) for v in rgb)
        tint(im, rgb, POLITICAL_FILL_ALPHA)
    # 3) 本省地块
    for t, im in zip(d["tiles"], tile_masks):
        tint(im, state_color(d, t.get("owner_state_id")), POLITICAL_FILL_ALPHA)
    # 4) 水面回贴
    gb = (ter[:, :, 1] - ter[:, :, 2]) / 255.0
    lo = L1_WATER_GB_MID - L1_WATER_GB_SOFT
    land = np.clip((gb - lo) / (2.0 * L1_WATER_GB_SOFT), 0.0, 1.0)
    a = (1.0 - land)[:, :, None]
    canvas = canvas * (1.0 - a) + ter * a

    img = Image.fromarray(np.clip(canvas, 0, 255).astype(np.uint8))
    OUT.mkdir(parents=True, exist_ok=True)
    img.save(OUT / f"replica_{label:03d}_full.png")
    print(f"saved {OUT / f'replica_{label:03d}_full.png'} ({img.size})")

    # 放大 crop：沿岸 4 处 + 省界 2 处
    water = (gb < L1_WATER_GB_MID)
    landm = ~water
    # 找海岸线：陆地边界点
    er = landm.copy()
    er[1:, :] &= landm[:-1, :]
    er[:-1, :] &= landm[1:, :]
    er[:, 1:] &= landm[:, :-1]
    er[:, :-1] &= landm[:, 1:]
    bnd = landm & ~er
    ys, xs = np.nonzero(bnd)
    sel = [(int(y), int(x)) for y, x in zip(ys[::max(1, len(ys) // 4)], xs[::max(1, len(xs) // 4)])][:4]
    nm = 0
    for (cy, cx) in sel:
        nm += 1
        box = (max(0, cx - 40), max(0, cy - 40), min(size, cx + 40), min(size, cy + 40))
        crop = img.crop(box).resize(((box[2] - box[0]) * 6, (box[3] - box[1]) * 6), Image.NEAREST)
        crop.save(OUT / f"replica_{label:03d}_coast{nm}_{cx}_{cy}.png")
    print("crops:", [p.name for p in sorted(OUT.glob(f'replica_{label:03d}_coast*.png'))])


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 69)
