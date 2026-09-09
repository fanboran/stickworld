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
    ("test_cube_v9", "立方体", None),
    ("test_sphere_v9", "正球", None),
    ("test_cylinder_v9", "圆柱", None),
    ("test_cone_v9", "圆锥", None),
    ("test_torus_v9", "圆环", None),
] + _MOTIFS
SIZES = (64, 128, 256)

# 旧 tag 的 ID 候选锁定为前 5 色：10 色全开会让红/黄材质的 AA 混合中间色
# （恰好=新橙 (1,.5,0)）在接缝处改判家族，破坏逐字节回归
_OLD_TAGS = ("icon_hammer_v9", "test_cube_v9", "test_sphere_v9",
             "test_cylinder_v9", "test_cone_v9", "test_torus_v9")
NIDS = {t[0]: 5 for t in TAGS if t[0] in _OLD_TAGS}

# D 着色器分档（v2）：shade pass 在渲染端已量化为 cel 灰阶（曲面 toon 材质/
# 平面面烘色，三档 0.32/0.62/0.92），compose 只按灰阶查表映射色带。
# 本表阈值只承担「分类三档灰」（含 classic 连续明度 ≈v1 0.36/0.68 语义），
# 与渲染端档位轮廓调优（TOON_LO/HI，默认 0.76/0.95）解耦——轮廓怎么移，
# 出图灰阶恒为三档，此表不必跟调。RAMPS 固定三带，档数>3 时钳到亮带。
_TH = (0.35, 0.70)


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
    # 轻模糊压渲染噪点，档位边界随平滑明度场走（半径与 v1 非豁免一致；
    # 豁免大半径 0.03 分支随 NO_STRETCH 退役）
    br = max(1.2, target * 0.012)
    L = np.asarray(Image.fromarray(np.clip(gray, 0, 255).astype(np.uint8))
                   .filter(ImageFilter.GaussianBlur(br))).astype(np.float32) / 255.0
    if fake:
        lx, ly, k = fake
        yy, xx = np.mgrid[0:H, 0:W]
        d = np.sqrt(((xx - W * lx) / W) ** 2 + ((yy - H * ly) / H) ** 2)
        L = np.clip(L * (1 - k * d), 0.05, 1.2)

    # D 分档查表：渲染端已定档（toon 材质/面烘色），此处仅按灰阶映射色带。
    # v1 的采样域腐蚀/p5-p98 拉伸/k-means/单面退化保护随图像域分档一并退役。
    band = np.digitize(L, _TH)
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
    out = np.zeros((H, W, 3), dtype=np.float32)
    for pid, ramp in RAMPS.items():
        m = part == pid
        if not m.any():
            continue
        out[m] = np.array([ramp[min(b, len(ramp) - 1)] for b in band[m]]) * 255

    # 超分抗锯齿（全量统一，NO_STRETCH 豁免退役）：渲染是 2x SSAA+64x MSAA，
    # 边缘 alpha 本来平滑——保留软 alpha + BOX 面积平均缩放（纯平均无负瓣
    # 零振铃），边缘半透明带细腻；描边仍在最终尺寸上画不受影响。
    # 软 alpha 边缘环填部件色：环上 part=-1，取最近实心像素的部件色，
    # 防 BOX 平均把黑底 RGB 混进边缘出黑边
    fill = part.copy()
    for _ in range(4):
        holes = (sa[..., 3] > 0) & (fill < 0)
        if not holes.any():
            break
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            sh = np.roll(fill, (dy, dx), axis=(0, 1))
            m = (fill < 0) & (sh >= 0)
            fill[m] = sh[m]
    for pid, ramp in RAMPS.items():
        m = (fill == pid) & (part < 0) & (sa[..., 3] > 0)
        if m.any():
            out[m] = np.array([ramp[min(b, len(ramp) - 1)] for b in band[m]]) * 255

    # 反向壳墨线层（C 阶段）：渲染端单独渲 ink pass（只有描边壳完整剪影，
    # 透明底），合成次序=「cel 在上、墨壳在下」的标准 over——墨壳被 cel 覆盖
    # 的部分不显形，只在轮廓外露出一圈描边。壳轮廓=几何边缘，MSAA 真抗锯齿
    # （ShaderToRGB 会关 MSAA，图像域描边拿不到），墨线与形体零对位误差
    # （双层线根除）。无 ink 层的旧产物回退图像域外轮廓环。
    ink_fp = os.path.join(BASE, f"{tag}_{target}_ink.png")
    has_ink = os.path.exists(ink_fp)
    if has_ink:
        inkim = np.asarray(Image.open(ink_fp).convert("RGBA")).astype(np.float32)
        a_cel = sa[..., 3:4]                      # 0..255
        a_ink = inkim[..., 3:4]                   # 0..255
        alpha = a_cel + a_ink * (1 - a_cel / 255.0)
        w = a_cel / np.maximum(alpha, 1e-3)       # cel 在最终透明度中的权重
        out = out * w + inkim[..., :3] * (1 - w)
    else:
        alpha = sa[..., 3]

    # 火焰层（真实火焰质感）：渲染端单独渲 fire pass（平滑渐变发光材质），
    # 原样合成不过色带——量化三档会把火做成糖果条
    fire_fp = os.path.join(BASE, f"{tag}_{target}_fire.png")
    if os.path.exists(fire_fp):
        fireim = np.asarray(Image.open(fire_fp).convert("RGBA")).astype(np.float32)
        a_f = fireim[..., 3:4] / 255.0
        a_bot = alpha / 255.0
        A = a_f + a_bot * (1 - a_f)
        out = (fireim[..., :3] * a_f + out * a_bot * (1 - a_f)) / np.maximum(A, 1e-4)
        alpha = A * 255.0

    rgba = np.dstack([out, alpha])
    img = Image.fromarray(np.clip(rgba, 0, 255).astype(np.uint8), "RGBA")

    ys, xs = np.where(np.asarray(img)[..., 3] > 40)
    box = (max(0, xs.min() - 4), max(0, ys.min() - 4), min(W, xs.max() + 4), min(H, ys.max() + 4))
    crop = img.crop(box)
    side = max(crop.size)
    sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    sq.paste(crop, ((side - crop.width) // 2, (side - crop.height) // 2))
    inner = target - max(1, round(target * 0.008) * 2)
    small = sq.resize((inner, inner), Image.BOX)
    cv = Image.new("RGBA", (target, target), (0, 0, 0, 0))
    cv.paste(small, ((target - inner) // 2, (target - inner) // 2))

    a = np.asarray(cv).copy()
    op = a[..., 3] > 128
    op_img = Image.fromarray((op * 255).astype(np.uint8))
    ero3 = np.asarray(op_img.filter(ImageFilter.MinFilter(3))) > 120
    # 外轮廓墨线已由渲染端反向壳承担（ink pass 合成）。此节只剩：无 ink 层的
    # 回退环（视觉轮廓 alpha>16 向内一圈）+ ID 结合缝线（拼版概念，保留图像域）。
    if has_ink:
        ring = np.zeros_like(op, dtype=np.float32)
    else:
        vis = a[..., 3] > 16
        vis_img = Image.fromarray((vis * 255).astype(np.uint8))
        ero_vis = np.asarray(vis_img.filter(ImageFilter.MinFilter(3))) > 120
        ring = (vis & ~ero_vis).astype(np.float32)
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
        icons[t].save(os.path.join(BASE, "icons", f"{label}_{t}.png"))   # 成品文件名=中文名
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
