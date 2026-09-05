# 临时视觉指标对比脚本：A组(gdlab) vs B组(python基线)
import numpy as np
from PIL import Image
from collections import deque

def hsv(rgb):
    r, g, b = rgb[..., 0] / 255, rgb[..., 1] / 255, rgb[..., 2] / 255
    mx, mn = np.max(rgb, -1) / 255, np.min(rgb, -1) / 255
    v = mx
    c = mx - mn
    s = np.where(mx > 0, c / np.maximum(mx, 1e-9), 0)
    h = np.zeros_like(mx)
    mask = c > 1e-9
    rm, gm, bm = r, g, b
    hr = ((gm - bm) / np.maximum(c, 1e-9)) % 6
    hg = (bm - rm) / np.maximum(c, 1e-9) + 2
    hb = (rm - gm) / np.maximum(c, 1e-9) + 4
    h = np.where(mx == rm, hr, np.where(mx == gm, hg, hb)) * 60
    h = np.where(mask, h, 0)
    return h, s, v

def erode_depth(mask, max_iter=80):
    """迭代腐蚀, 返回每个前景像素的腐蚀深度(≈半厚,像素)"""
    d = np.zeros(mask.shape, np.float32)
    cur = mask.copy()
    for i in range(1, max_iter + 1):
        m = cur.copy()
        m[1:, :] &= cur[:-1, :]
        m[:-1, :] &= cur[1:, :]
        m[:, 1:] &= cur[:, :-1]
        m[:, :-1] &= cur[:, 1:]
        newly = cur & ~m
        d[newly] = i
        if not m.any():
            break
        cur = m
    d[cur] = max_iter
    return d

def label_components(mask):
    """8连通域标记, 返回(label数组, 每个label面积dict)"""
    h, w = mask.shape
    lab = np.zeros((h, w), np.int32)
    nxt = 0
    areas = {}
    for sy in range(h):
        for sx in range(w):
            if mask[sy, sx] and lab[sy, sx] == 0:
                nxt += 1
                q = deque([(sy, sx)])
                lab[sy, sx] = nxt
                a = 0
                while q:
                    y, x = q.popleft()
                    a += 1
                    for dy in (-1, 0, 1):
                        for dx in (-1, 0, 1):
                            ny, nx = y + dy, x + dx
                            if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and lab[ny, nx] == 0:
                                lab[ny, nx] = nxt
                                q.append((ny, nx))
                areas[nxt] = a
    return lab, areas

def holes(mask):
    """前景内部的封闭孔洞: 不接触边界的背景连通域"""
    bg = ~mask
    touch = np.zeros_like(bg)
    h, w = bg.shape
    seen = np.zeros_like(bg)
    q = deque()
    for x in range(w):
        for y in (0, h - 1):
            if bg[y, x] and not seen[y, x]:
                seen[y, x] = True; q.append((y, x))
    for y in range(h):
        for x in (0, w - 1):
            if bg[y, x] and not seen[y, x]:
                seen[y, x] = True; q.append((y, x))
    while q:
        y, x = q.popleft()
        for dy, dx in ((1,0),(-1,0),(0,1),(0,-1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < h and 0 <= nx < w and bg[ny, nx] and not seen[ny, nx]:
                seen[ny, nx] = True; q.append((ny, nx))
    inner = bg & ~seen
    return inner  # 冠内封闭孔洞

def analyze(path):
    img = np.array(Image.open(path).convert("RGBA"), np.float32)
    a = img[..., 3] / 255
    mask = a > 0.5
    rgb = img[..., :3] * a[..., None] + 255 * (1 - a[..., None])  # 白底合成看颜色
    H, S, V = hsv(rgb)
    ys, xs = np.where(mask)
    y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()
    h_, w_ = y1 - y0 + 1, x1 - x0 + 1

    # 边界与粗糙度
    er = mask.copy()
    er[1:, :] &= mask[:-1, :]; er[:-1, :] &= mask[1:, :]
    er[:, 1:] &= mask[:, :-1]; er[:, :-1] &= mask[:, 1:]
    boundary = (mask & ~er).sum()
    area = mask.sum()
    roughness = boundary / (2 * np.sqrt(np.pi * area))  # 圆=1

    # 冠区 = mask上部到树干起点; 简化: y < y0+0.72h_ 且属于前景
    crown = mask & (np.arange(mask.shape[0])[:, None] < y0 + 0.72 * h_)
    trunk = mask & (np.arange(mask.shape[0])[:, None] >= y0 + 0.72 * h_)

    # 冠内厚度分布(腐蚀深度=半宽)
    d = erode_depth(crown)
    dp = d[crown & (d > 0)]
    thin = (dp <= 2).mean()      # 细刺 宽<=4px
    mid = ((dp >= 3) & (dp <= 5)).mean()   # 6-10px
    thickmid = ((dp >= 6) & (dp <= 8)).mean()  # 12-16px
    fat = (dp >= 9).mean()       # >=18px 宽笔

    # 灰条: 低饱和度
    graypix = crown & (S < 0.20) & (V > 0.25) & (V < 0.90)
    gray_ratio = graypix.sum() / max(crown.sum(), 1)
    lab, areas = label_components(graypix)
    gray_bars = sorted([v for v in areas.values() if v >= 60], reverse=True)[:6]

    # 高光: 亮黄绿
    hi = crown & (H > 55) & (H < 165) & (V > 0.62) & (S > 0.15)
    hi_ratio = hi.sum() / max(crown.sum(), 1)

    # 冠内孔洞
    hl = holes(crown)
    hlab, hareas = label_components(hl)
    hole_cnt = sum(1 for v in hareas.values() if v >= 8)
    hole_area = sum(v for v in hareas.values() if v >= 8)

    # 树干颜色与宽度
    tpix = trunk.sum()
    if tpix > 50:
        tV = V[trunk].mean(); tS = S[trunk].mean()
        tR = rgb[..., 0][trunk].mean(); tG = rgb[..., 1][trunk].mean(); tB = rgb[..., 2][trunk].mean()
        # 每行干宽
        widths = []
        for yy in np.unique(np.where(trunk)[0]):
            xr = np.where(trunk[yy])[0]
            widths.append(xr.max() - xr.min() + 1)
        wmean, wstd = np.mean(widths), np.std(widths)
    else:
        tV = tS = tR = tG = tB = wmean = wstd = 0

    return dict(rough=roughness, crown_hw=h_ / w_, area=area,
        thin=thin, mid=mid, thickmid=thickmid, fat=fat,
        gray=gray_ratio, gray_bars=gray_bars, hi=hi_ratio,
        holes=hole_cnt, hole_area=hole_area,
        tV=tV, tS=tS, tRGB=(tR, tG, tB), tW=(wmean, wstd))

A = [rf"F:/VSCode/game-2/temp/stroke_ref/gdlab/gd_v{i}.png" for i in range(4)]
B = [rf"F:/VSCode/game-2/stick-world/assets/resources/tree_paint_tree_v{i}.png" for i in range(10)]

for name, paths in (("A(gd)", A), ("B(py)", B)):
    print("=" * 20, name)
    for p in paths:
        r = analyze(p)
        print(f"{p.split('/')[-1]:24s} rough={r['rough']:.3f} AR={r['crown_hw']:.2f} "
              f"thick%<=4px={r['thin']:.2f} 6-10={r['mid']:.2f} 12-16={r['thickmid']:.2f} >=18={r['fat']:.2f} | "
              f"gray%={r['gray']:.3f} bars={r['gray_bars']} hi%={r['hi']:.2f} "
              f"holes={r['holes']}/{r['hole_area']}px | trunk RGB=({r['tRGB'][0]:.0f},{r['tRGB'][1]:.0f},{r['tRGB'][2]:.0f}) V={r['tV']:.2f} w={r['tW'][0]:.1f}±{r['tW'][1]:.1f}")
