# -*- coding: utf-8 -*-
"""色板验收贴图 v2：纹章墙（3D 模板→滤镜预演：受光渐变/三层描边/铆钉/飘带/纸纹）"""
import math, random
from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageOps

SS = 2
W, H = 1600 * SS, 1250 * SS
img = Image.new("RGB", (W, H), (8, 10, 15))
d = ImageDraw.Draw(img)


def font(sz):
    for p in ("C:/Windows/Fonts/msyhbd.ttc", "C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/simhei.ttf"):
        try:
            return ImageFont.truetype(p, sz * SS)
        except Exception:
            pass
    return ImageFont.load_default()


FT, FS, FL, FN = font(40), font(26), font(21), font(17)


def rgb(c, k=1.0):
    return tuple(max(0, min(255, int(v * 255 * k))) for v in c)


def qbez(p0, p1, p2, n=24):
    return [((1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t * t * p2[0],
             (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t * t * p2[1])
            for t in (i / n for i in range(n + 1))]


def shield_pts(cx, cy, w, h):
    tl, tr = (cx - w, cy - h * 0.52), (cx + w, cy - h * 0.52)
    bot = (cx, cy + h * 0.58)
    rmid = (cx + w * 1.02, cy + h * 0.26)
    rlow = (bot[0] + w * 0.10, bot[1] - h * 0.12)
    lmid = (cx - w * 1.02, cy + h * 0.26)
    llow = (bot[0] - w * 0.10, bot[1] - h * 0.12)
    pts = qbez(tl, (cx, cy - h * 0.60), tr)
    pts += qbez(tr, rmid, rlow)
    pts += qbez(rlow, (cx + w * 0.02, bot[1] + h * 0.04), bot)
    pts += qbez(bot, (cx - w * 0.02, bot[1] + h * 0.04), llow)
    pts += qbez(llow, lmid, (cx - w, cy - h * 0.52))
    return pts


def linear_grad(size, c, k0=1.06, k1=0.62):
    w, h = size
    g = Image.new("RGB", (w, h))
    px = g.load()
    for y in range(h):
        ty = y / max(h - 1, 1)
        for x in range(w):
            t = (x / max(w - 1, 1)) * 0.6 + ty * 0.4
            px[x, y] = rgb(c, k0 + (k1 - k0) * t)
    return g


def draw_motif(dr, kind, cx, cy):
    lw = max(2, 3 * SS // 2)
    wh = (250, 248, 240)
    sh = (20, 18, 14)
    if kind == "hammer":
        dr.line([(cx - 2 * SS, cy - 6 * SS), (cx - 2 * SS, cy + 26 * SS)], fill=wh, width=lw + 1)
        dr.rectangle([cx - 22 * SS, cy - 24 * SS, cx + 18 * SS, cy - 9 * SS], fill=wh)
        dr.line([(cx - 22 * SS, cy - 9 * SS), (cx + 18 * SS, cy - 9 * SS)], fill=sh, width=2)
    elif kind == "flag":
        dr.line([(cx - 14 * SS, cy - 24 * SS), (cx - 14 * SSS if False else cx - 14 * SS, cy + 26 * SS)], fill=wh, width=lw + 1)
        dr.polygon([(cx - 14 * SS, cy - 24 * SS), (cx + 24 * SS, cy - 14 * SS), (cx - 14 * SS, cy - 4 * SS)], fill=wh)
    elif kind == "cart":
        dr.rectangle([cx - 20 * SS, cy - 12 * SS, cx + 6 * SS, cy + 2 * SS], outline=wh, width=lw)
        for ox in (-14, 0):
            dr.ellipse([cx + (ox - 6) * SS, cy + 2 * SS, cx + (ox + 6) * SS, cy + 14 * SS], outline=wh, width=lw)
        dr.line([(cx + 6 * SS, cy - 6 * SS), (cx + 22 * SS, cy - 18 * SS)], fill=wh, width=lw)
    elif kind == "star":
        pts = [(cx + 20 * SS * math.cos(math.radians(90 + i * 72)),
                cy - 20 * SS * math.sin(math.radians(90 + i * 72))) for i in range(5)]
        dr.polygon(pts, fill=wh)
    elif kind == "grass":
        for i, ox in enumerate((-12, -4, 4, 12)):
            dr.arc([cx + (ox - 7) * SS, cy - 16 * SS, cx + (ox + 7) * SS, cy + 22 * SS],
                   270 + i * 12, 60 + i * 12, fill=wh, width=lw)
    elif kind == "heart":
        r = 11 * SS
        dr.ellipse([cx - 2 * r, cy - int(1.8 * r), cx, cy], fill=wh)
        dr.ellipse([cx, cy - int(1.8 * r), cx + 2 * r, cy], fill=wh)
        dr.polygon([(cx - 2 * r + 2, cy - int(0.4 * r)), (cx + 2 * r - 2, cy - int(0.4 * r)), (cx, cy + int(1.7 * r))], fill=wh)


def draw_badge(img, cx, cy, w, h, c1, c2, motif, name, sub):
    dr = ImageDraw.Draw(img)
    pts = shield_pts(cx, cy, w, h)
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    bx0, by0, bx1, by1 = min(xs), min(ys), max(xs), max(ys)
    # 柔光
    glow = Image.new("L", img.size, 0)
    ImageDraw.Draw(glow).polygon(pts, fill=80)
    glow = glow.filter(ImageFilter.GaussianBlur(20))
    img.paste(Image.new("RGB", img.size, rgb((0.95, 0.68, 0.25), 0.45)), (0, 0), glow)
    # 渐变分区填充
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).polygon(pts, fill=255)
    half = Image.new("L", img.size, 0)
    ImageDraw.Draw(half).polygon([(cx, by0 - 2), (bx1 + 2, by0 - 2), (bx1 + 2, by1 + 2), (cx, by1 + 2)], fill=255)
    m_left = Image.composite(mask, Image.new("L", img.size, 0), half)
    m_right = Image.composite(mask, Image.new("L", img.size, 0), ImageOps.invert(half))
    box = (int(bx0) - 1, int(by0) - 1, int(bx1) + 1, int(by1) + 1)
    for m, c in ((m_left, c1), (m_right, c2)):
        grad = linear_grad((box[2] - box[0], box[3] - box[1]), c)
        img.paste(grad, (box[0], box[1]), m.crop(box))
    # 三层描边
    dr.line(pts + [pts[0]], fill=(16, 14, 10), width=3 * SS + 2, joint="curve")
    dr.line(pts + [pts[0]], fill=rgb((0.80, 0.68, 0.42)), width=3 * SS // 2 + 1, joint="curve")
    random.seed(hash(name) & 0xFFFF)
    hl = [p for i, p in enumerate(pts) if i % 3 != 2]
    dr.line(hl, fill=(255, 255, 250), width=max(1, SS // 2), joint="curve")
    # 分区金线 + 铆钉
    dr.line([(cx, by0 + 2), (cx, by0 + (by1 - by0) * 0.72)], fill=rgb((0.80, 0.68, 0.42)), width=SS)
    for i in range(5):
        t = 0.12 + i * 0.19
        px, py = bx0 + (bx1 - bx0) * t, by0 + (by1 - by0) * 0.06
        r = 3 * SS // 2 + 1
        dr.ellipse([px - r, py - r, px + r, py + r], fill=rgb((0.80, 0.68, 0.42), 1.15), outline=(30, 26, 18), width=2)
    draw_motif(dr, motif, cx, cy - h * 0.02)
    # 飘带名条
    ry, rw, rh = by1 + 10 * SS, w * 1.42, 20 * SS
    dr.polygon([(cx - rw * 1.14, ry + rh * 0.2), (cx - rw, ry), (cx - rw * 0.92, ry + rh)], fill=(22, 18, 12))
    dr.polygon([(cx + rw * 1.14, ry + rh * 0.2), (cx + rw, ry), (cx + rw * 0.92, ry + rh)], fill=(22, 18, 12))
    d2 = [(cx - rw, ry), (cx + rw, ry), (cx + rw * 0.9, ry + rh), (cx - rw * 0.9, ry + rh)]
    dr.polygon(d2, fill=(30, 26, 20))
    dr.line(d2 + [d2[0]], fill=rgb((0.80, 0.68, 0.42)), width=2, joint="curve")
    dr.text((cx, ry + rh * 0.5), name, font=FL, fill=(240, 236, 226), anchor="mm")
    dr.text((cx, ry + rh + 8 * SS), sub, font=FN, fill=(150, 155, 165), anchor="mm")


# ── 布局 ──
d.text((48 * SS, 30 * SS), "内容色板 v2 · 应用示意（纹章墙）— 3D 模板→滤镜预演：受光渐变/三层描边/铆钉/飘带", font=FT, fill=(238, 240, 246))
d.text((48 * SS, 88 * SS), "色板 20 色全部派生自游戏贴图盘点（草地/树线/远山/木建筑/资源图标/语义红）", font=FL, fill=(150, 156, 168))

BADGES = [
    ("锻造行会", "FORGE GUILD", "hammer", (0.62, 0.44, 0.26), (0.80, 0.68, 0.42)),
    ("先锋旗队", "VANGUARD", "flag", (0.66, 0.36, 0.30), (0.95, 0.68, 0.25)),
    ("运输号", "HAULAGE CO.", "cart", (0.33, 0.52, 0.28), (0.62, 0.62, 0.58)),
    ("测绘局", "CARTOGRAPHY", "star", (0.42, 0.62, 0.80), (0.35, 0.48, 0.66)),
    ("垦荒团", "PIONEERS", "grass", (0.48, 0.68, 0.32), (0.78, 0.72, 0.48)),
    ("育儿堂", "NURSERY", "heart", (0.48, 0.38, 0.52), (0.52, 0.27, 0.25)),
]
for i, (nm, sub, mk, c1, c2) in enumerate(BADGES):
    draw_badge(img, 150 * SS + i * 218 * SS, 255 * SS, 72 * SS, 92 * SS, c1, c2, mk, nm, sub)

d.text((48 * SS, 470 * SS), "色板（每色标注来源）", font=FS, fill=(238, 240, 246))
PAL = [
    ("wheat", (0.78, 0.72, 0.48), "←草地#84b43c"), ("meadow", (0.66, 0.76, 0.34), "←#6c9c3c"),
    ("grass", (0.48, 0.68, 0.32), "←#54843c"), ("forest", (0.33, 0.52, 0.28), "←压暗"),
    ("teal_tree", (0.30, 0.58, 0.52), "←树线#3c8484"), ("lake", (0.35, 0.62, 0.64), "←#549cb4"),
    ("pine", (0.20, 0.42, 0.38), "←#246c54"), ("sky_blue", (0.42, 0.62, 0.80), "←远山#6c9ccc"),
    ("dusk_blue", (0.35, 0.48, 0.66), "←#549c9c系"), ("amber", (0.95, 0.68, 0.25), "=ACCENT同源"),
    ("wood", (0.62, 0.44, 0.26), "←木#845424"), ("umber", (0.45, 0.30, 0.18), "←压暗"),
    ("sand", (0.80, 0.68, 0.42), "←提亮"), ("earth", (0.52, 0.42, 0.30), "←资源#6c543c"),
    ("clay", (0.62, 0.52, 0.40), "←提亮"), ("stone", (0.62, 0.62, 0.58), "←#9c9c9c"),
    ("iron", (0.44, 0.45, 0.47), "←#848484"), ("brick", (0.66, 0.36, 0.30), "←DANGER降饱和"),
    ("blood_earth", (0.52, 0.27, 0.25), "←再压暗"), ("grape", (0.48, 0.38, 0.52), "←补缺"),
]
for i, (nm, c, src) in enumerate(PAL):
    row, col = divmod(i, 10)
    x = 48 * SS + col * 152 * SS
    y = 515 * SS + row * 108 * SS
    sw = 138 * SS
    img.paste(linear_grad((sw, 52 * SS), c, 1.04, 0.72), (int(x), int(y)), Image.new("L", (sw, 52 * SS), 255))
    d.rounded_rectangle([x, y, x + sw, y + 52 * SS], 4, outline=(16, 14, 10), width=3)
    d.rounded_rectangle([x + 1, y + 1, x + sw - 1, y + 52 * SS - 1], 4, outline=(255, 255, 250), width=1)
    d.text((x + 4, y + 56 * SS), nm, font=FN, fill=(212, 216, 224))
    d.text((x + 4, y + 78 * SS), src, font=FN, fill=(122, 128, 140))

d.text((48 * SS, 775 * SS), "组织标签色（谱系树/部门面板/世界地图点缀）", font=FS, fill=(238, 240, 246))
ORGS = [("军事 brick", (0.66, 0.36, 0.30)), ("科研 sky_blue", (0.42, 0.62, 0.80)),
        ("工程 sand", (0.80, 0.68, 0.42)), ("行政 stone", (0.62, 0.62, 0.58)),
        ("运输 teal_tree", (0.30, 0.58, 0.52)), ("后勤 grape", (0.48, 0.38, 0.52))]
for i, (nm, c) in enumerate(ORGS):
    x = 48 * SS + i * 218 * SS
    y = 820 * SS
    img.paste(linear_grad((196 * SS, 44 * SS), c, 1.02, 0.74), (int(x), int(y)), Image.new("L", (196 * SS, 44 * SS), 255))
    d.rounded_rectangle([x, y, x + 196 * SS, y + 44 * SS], 5, outline=(16, 14, 10), width=3)
    d.text((x + 14 * SS, y + 22 * SS), nm, font=FL, fill=(14, 12, 10), anchor="lm")

d.text((48 * SS, 912 * SS), "琥珀「确定」= 唯一操作强调色对照（内容色永不用于按钮/选中态）", font=FL, fill=(150, 156, 168))
img.paste(linear_grad((112 * SS, 48 * SS), (0.95, 0.68, 0.25), 1.08, 0.82), (48 * SS, 950 * SS),
          Image.new("L", (112 * SS, 48 * SS), 255))
d.rounded_rectangle([48 * SS, 950 * SS, 160 * SS, 998 * SS], 6, outline=(16, 14, 10), width=3)
d.text((104 * SS, 974 * SS), "确定", font=FL, fill=(16, 13, 8), anchor="mm")

# 纸纹（克制：≤2% 对比）
random.seed(42)
noise = Image.effect_noise((W // 4, H // 4), 18).resize((W, H)).filter(ImageFilter.GaussianBlur(1))
img = Image.composite(Image.new("RGB", (W, H), (255, 255, 255)), img, noise.point(lambda v: max(0, v - 252) * 2))
img = img.resize((1600, 1250), Image.LANCZOS)
img.save("temp/palette_review_v2.png")
print("saved temp/palette_review_v2.png")
