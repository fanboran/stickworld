# -*- coding: utf-8 -*-
"""v9 批量合成：注册表驱动，全部图标（锤/心/基本体测试组）过同一 cel 管线，
输出三档尺寸 + 网格验收图"""
import sys
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

# 读 <仓库根>/temp/ 渲染中间产物，写 <仓库根>/temp/icons/ 成品，CWD 无关
BASE = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "temp"))

# 母题注册表（motifs.py，失败则只出旧 7 枚）
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import motifs as _M
    _MOTIFS = [(m["tag"], m["label"], m["fake"]) for m in _M.MOTIFS]
    _NAME = {m["tag"]: m["name"] for m in _M.MOTIFS}
except Exception as _e:
    print("motif registry unavailable:", _e)
    _MOTIFS, _NAME = [], {}

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
INK = np.array([18, 14, 9])

# (tag, 中文名, 假光参数 or None)
TAGS = [
    ("icon_hammer_v9", "锻造锤", (0.10, 0.02, 0.20)),
    ("icon_heart_v9", "爱心", (0.12, 0.05, 0.45)),
    ("test_cube_v9", "立方体", None),
    ("test_sphere_v9", "正球", None),
    ("test_cylinder_v9", "圆柱", None),
    ("test_cone_v9", "圆锥", None),
    ("test_torus_v9", "圆环", None),
] + _MOTIFS
SIZES = (64, 128, 256)

# 旧 tag 沿用「三面锁档」：pid 0/1/2 在 ≥128px 压单档（锤三面灰阶+基本体既有语言）
FACE_LOCK = {t[0] for t in TAGS[:7]}
# 旧 tag 的 ID 候选锁定为前 5 色：10 色全开会让红/黄材质的 AA 混合中间色
# （恰好=新橙 (1,.5,0)）在接缝处改判家族，破坏逐字节回归
NIDS = {t[0]: 5 for t in TAGS[:7]}


def cel(tag, fake, target, out_ink=None, nids=10):
    shade = Image.open(os.path.join(BASE, f"{tag}_{target}_shade.png")).convert("RGBA")
    idim = Image.open(os.path.join(BASE, f"{tag}_{target}_id.png")).convert("RGBA")
    sa = np.asarray(shade).astype(np.float32)
    ia = np.asarray(idim).astype(np.float32)
    H, W = sa.shape[:2]
    solid = sa[..., 3] >= 128

    IDS = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0), (1, 0, 1),
           (0, 1, 1), (1, 1, 1), (0, 0, 0), (1, 0.5, 0), (0, 0.3, 1)][:nids]
    idarr = np.stack([np.array(c) for c in IDS]) * 255.0
    dist = ((ia[..., :3][..., None, :] - idarr[None, None, :, :]) ** 2).sum(axis=3)
    part = np.argmin(dist, axis=2)
    part[~solid] = -1

    gray = (sa[..., 0] * 0.299 + sa[..., 1] * 0.587 + sa[..., 2] * 0.114)
    L = np.asarray(Image.fromarray(np.clip(gray, 0, 255).astype(np.uint8))
                   .filter(ImageFilter.GaussianBlur(max(1.5, target * 0.03)))).astype(np.float32) / 255.0
    if fake:
        lx, ly, k = fake
        yy, xx = np.mgrid[0:H, 0:W]
        d = np.sqrt(((xx - W * lx) / W) ** 2 + ((yy - H * ly) / H) ** 2)
        L = np.clip(L * (1 - k * d), 0.05, 1.2)

    th = (0.5,) if target <= 64 else (0.36, 0.68)
    band = np.digitize(L, th)
    RAMPS = {
        0: [(0.38, 0.40, 0.45), (0.55, 0.57, 0.62), (0.74, 0.76, 0.80)],
        1: [(0.30, 0.32, 0.36), (0.47, 0.49, 0.54), (0.62, 0.64, 0.68)],
        2: [(0.24, 0.25, 0.28), (0.36, 0.38, 0.42), (0.50, 0.52, 0.56)],
        3: [(0.34, 0.22, 0.12), (0.52, 0.34, 0.18), (0.72, 0.52, 0.30)],
        4: [(0.42, 0.13, 0.11), (0.78, 0.26, 0.22), (0.92, 0.45, 0.38)],
        5: [(0.20, 0.32, 0.14), (0.34, 0.48, 0.20), (0.52, 0.66, 0.30)],
        6: [(0.66, 0.60, 0.46), (0.82, 0.76, 0.62), (0.94, 0.90, 0.78)],
        7: [(0.14, 0.13, 0.13), (0.24, 0.23, 0.23), (0.36, 0.35, 0.34)],
        8: [(0.52, 0.36, 0.10), (0.76, 0.56, 0.16), (0.92, 0.76, 0.32)],
        9: [(0.14, 0.22, 0.40), (0.24, 0.38, 0.60), (0.40, 0.58, 0.80)],
    }
    ramp_at = lambda ramp, b: (ramp[0] if b == 0 else ramp[-1]) if len(th) == 1 else ramp[b]
    out = np.zeros((H, W, 3), dtype=np.float32)
    for pid, ramp in RAMPS.items():
        m = part == pid
        if not m.any():
            continue
        out[m] = np.array([ramp_at(ramp, b) for b in band[m]]) * 255
        if tag in FACE_LOCK and pid in (0, 1, 2) and len(th) == 3:
            out[m] = np.array(ramp[{0: 2, 1: 1, 2: 0}[pid]]) * 255   # 锤头三面锁档（旧 tag 专用）

    rgba = np.dstack([out, solid * 255.0])
    img = Image.fromarray(np.clip(rgba, 0, 255).astype(np.uint8), "RGBA")

    ys, xs = np.where(np.asarray(img)[..., 3] > 40)
    box = (max(0, xs.min() - 4), max(0, ys.min() - 4), min(W, xs.max() + 4), min(H, ys.max() + 4))
    crop = img.crop(box)
    side = max(crop.size)
    sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    sq.paste(crop, ((side - crop.width) // 2, (side - crop.height) // 2))
    inner = target - max(1, round(target * 0.008) * 2)
    small = sq.resize((inner, inner), Image.LANCZOS)
    cv = Image.new("RGBA", (target, target), (0, 0, 0, 0))
    cv.paste(small, ((target - inner) // 2, (target - inner) // 2))

    a = np.asarray(cv).copy()
    op = a[..., 3] > 128
    op_img = Image.fromarray((op * 255).astype(np.uint8))
    ero3 = np.asarray(op_img.filter(ImageFilter.MinFilter(3))) > 120
    ring = (op & ~ero3).astype(np.float32)
    if target >= 128:
        ero5 = np.asarray(op_img.filter(ImageFilter.MinFilter(5))) > 120
        ring = ring + np.where(ero3 & ~ero5, 0.3 if target == 128 else 0.4, 0.0)
    if target >= 128:
        id_t = Image.fromarray((part + 1).astype(np.uint8)).resize((target, target), Image.NEAREST)
        idedge = (np.asarray(id_t.filter(ImageFilter.MaxFilter(3))) !=
                  np.asarray(id_t.filter(ImageFilter.MinFilter(3)))) & op
        ring = ring + np.asarray(Image.fromarray((idedge * 255).astype(np.uint8))
                                 .filter(ImageFilter.MaxFilter(3))).astype(np.float32) / 255.0 * (0.6 if target == 128 else 0.8)
    w = np.clip(ring, 0, 1)
    w = np.asarray(Image.fromarray((w * 255).astype(np.uint8))
                   .filter(ImageFilter.GaussianBlur(0.6))).astype(np.float32) / 255.0
    w = w[..., None]
    a[..., :3] = a[..., :3] * (1 - w) + INK * w
    cv = Image.fromarray(a, "RGBA")

    aa = np.asarray(cv)
    ys, xs = np.where(aa[..., 3] > 10)
    left, right = int(xs.min()), target - 1 - int(xs.max())
    top, bot = int(ys.min()), target - 1 - int(ys.max())
    dx, dy = (right - left) // 2, (bot - top) // 2
    if dx or dy:
        cv = Image.fromarray(np.roll(aa, (dy, dx), axis=(0, 1)))
        ys2, xs2 = np.where(np.asarray(cv)[..., 3] > 10)
        print(f"  [{tag}@{target}] L{int(xs2.min())} R{target-1-int(xs2.max())} T{int(ys2.min())} B{target-1-int(ys2.max())}")
    if out_ink:
        fin = np.asarray(cv)
        li = np.full((target, target, 3), 255, dtype=np.float32)
        li = li * (1 - fin[..., 3:4] / 255.0) + (fin[..., :3] * (fin[..., 3:4] / 255.0))
        Image.fromarray(np.clip(li, 0, 255).astype(np.uint8), "RGB").save(out_ink)
    return cv


def font(sz, bold=False):
    for p in ((("C:/Windows/Fonts/msyhbd.ttc") if bold else "C:/Windows/Fonts/msyh.ttc"),
              "C:/Windows/Fonts/simhei.ttf"):
        try:
            return ImageFont.truetype(p, sz)
        except Exception:
            pass
    return ImageFont.load_default()


def checkerboard(size, cell=16):
    board = Image.new("RGB", size, (198, 198, 198))
    dd = ImageDraw.Draw(board)
    for y in range(0, size[1], cell):
        for x in range(0, size[0], cell):
            if (x // cell + y // cell) % 2:
                dd.rectangle([x, y, x + cell, y + cell], fill=(158, 158, 158))
    return board


# ── 批处理：全部图标出三档尺寸 ──
results = {}
os.makedirs(os.path.join(BASE, "icons"), exist_ok=True)
FT = font(32, True)
FN = font(15)
for tag, label, fake in TAGS:
    icons = {}
    for t in SIZES:
        icons[t] = cel(tag, fake, t, nids=NIDS.get(tag, 10))
        name = _NAME.get(tag) or tag.replace("icon_", "").replace("_v9", "").replace("test_", "")
        icons[t].save(os.path.join(BASE, "icons", f"{name}_{t}.png"))
    results[tag] = (label, icons)
    print(f"[{tag}] done")

# ── 网格验收图：每行一个图标，三列定位（64/128/256），10 行一页 ──
ROW_H = 292
COLS = {64: 170, 128: 320, 256: 520}   # 各尺寸格子左缘 x
CW = 520 + 272 + 30
PAGE = 10
FT = font(32, True)
FL = font(20)
FN = font(14)
pages = [list(results.items())[i:i + PAGE] for i in range(0, len(results), PAGE)]
for pi, chunk in enumerate(pages):
    CH = 80 + len(chunk) * ROW_H + 20
    canvas = Image.new("RGB", (CW, CH), (8, 10, 15))
    d = ImageDraw.Draw(canvas)
    d.text((24, 20), f"管线验收总表 v10 — 第{pi + 1}/{len(pages)}页（基本体+锤/心+母题库，格内居中）",
           font=FT, fill=(238, 240, 246))
    for r, (tag, (label, icons)) in enumerate(chunk):
        y = 80 + r * ROW_H
        if r % 2 == 0:
            d.rectangle([0, y - 4, CW, y + ROW_H - 4], fill=(12, 14, 20))
        d.text((24, y + ROW_H // 2), label, font=FL, fill=(200, 204, 212), anchor="lm")
        for t in SIZES:
            x = COLS[t]
            tile = t + 16
            board = checkerboard((tile, tile), cell=max(8, t // 8))
            canvas.paste(board, (x, y + (ROW_H - tile) // 2))
            canvas.paste(icons[t], (x + (tile - t) // 2, y + (ROW_H - tile) // 2), icons[t])
            d.text((x + tile + 6, y + 14), f"{t}", font=FN, fill=(120, 126, 138), anchor="lm")
    canvas.save(os.path.join(BASE, f"icon_grid_p{pi + 1}.png"))
print(f"saved {len(pages)} grid page(s)")
