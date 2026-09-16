# -*- coding: utf-8 -*-
"""grass_ai_reskin.py —— 绿草地贴图换 AI 手绘源（地面贴图库 grass 族重生成）

背景
----
`ground_tiles.py` 的 grass 是值噪声程序化底（画不出"草叶笔触"，见
docs/项目/待办事项.md「绿草地贴图换 AI 手绘源」调研）。本工具改用创始人
认可的原 AI 贴图 `stick-world/assets/environment/grassland.png`（1024²，
手绘风草叶 + 小花）为源，派生管线既有文件名的全套 grass 族产物，消费端
零改动（`hd2d_world.gd` 的 `_add_ground_plane_at` 优先读工程内副本，
GroundFallback 与缺档回退读游戏档）。

无缝化
------
源图边缘差 ~4%~7%（非严格可平铺）。做法 = **半偏移 + 羽化交叉混合**：
`out = w·img + (1−w)·roll(img, 半幅)`，权重 w 在贴图中心为 1、按羽化带宽
向四边平滑降为 0。img 与 roll(img) 都是周期数组，w 按到边距离定义天然周期
⇒ 乘积和处处周期无缝；接缝风险区（img 的四边）权重为 0，被 roll 副本
（该区恰是 img 的连续中心）接管。羽化带内两层内容交叉淡化，笔触可能轻微
重影，羽化带取 80px（1024 源）控制重影面积。

派生档（与 ground_tiles.py 同名同尺寸约定）
------------------------------------------
- `src/grass_alb.png`        512 高清反照率（游戏运行时优先档）
- `src/grass_alb_128.png`    128 游戏档（+ _v1..v3 = 旋转 90/180/270 变体；
  旋转保无缝，取代程序化管线的 seed 变体）
- `src/grass_nrm.png`        512 法线（亮度场高程 → 环绕差分，公式与
  ground_tiles.normal_map_w 同号：nxa=−dx/mpp、nya=−dy/mpp，草叶 relief 1.8cm）
- `src/grass_nrm_128.png`    128 法线（+ 变体）
- `src/grass_rgh.png`        粗糙度（均匀 0.93 ± 白噪声 0.02；hd2d_world 运行时
  粗糙度写死 0.95，此档仅供材质库完整性）
- `grass.json` 不改（现实尺寸口径仍按"一张 = 4 格"读取）

落盘位置
--------
- `stick-world/temp/ground_tiles/src/`   烘焙工作区全套（运行时回退档）
- `stick-world/modules/hd2d/assets/tex/ground_tiles/`
  + `src/` 工程内入库副本（运行时**优先**读取；只落库内既有文件名：
  grass_alb_128[+_v1..v3] / src/grass_alb / src/grass_nrm_128）
- 工程内 PNG 替换后需重跑一次 `godot --headless --import` 刷新导入缓存。

用法
----
    python tools/blender_buildings/grass_ai_reskin.py            # 全套生成+落盘
    python tools/blender_buildings/grass_ai_reskin.py --dryrun   # 只算不写
"""

import argparse
import os
import sys

import numpy as np
from PIL import Image, ImageFilter

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC_AI = os.path.join(REPO, "stick-world", "assets", "environment", "grassland.png")
OUT_DIRS = [
    os.path.join(REPO, "stick-world", "temp", "ground_tiles", "src"),
    os.path.join(REPO, "stick-world", "modules", "hd2d", "assets", "tex",
                 "ground_tiles", "src"),
]
OUT_GAME_DIRS = [
    os.path.join(REPO, "stick-world", "temp", "ground_tiles"),
    os.path.join(REPO, "stick-world", "modules", "hd2d", "assets", "tex",
                 "ground_tiles"),
]
TILE_M = 1.68          # 一张贴图 = 4 格（与 ground_tiles.py 尺度契约一致）
FEATHER = 80           # 无缝化羽化带宽（1024 源像素）
RELIEF_M = 0.018       # 草叶起伏（米），法线强度语义同 ground_tiles.normal_map_w
ROUGH_BASE = 0.93      # 粗糙度基档
_SEAM_REPORT = {}


def _smoothstep(t):
    t = np.clip(t, 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def make_seamless(img):
    """半偏移 + 羽化交叉混合 → 可平铺（见模块 docstring 推导）。"""
    a = np.asarray(img.convert("RGB"), dtype=np.float64) / 255.0
    h, w = a.shape[:2]
    off = np.roll(a, (h // 2, w // 2), axis=(0, 1))
    yy, xx = np.mgrid[0:h, 0:w]
    dist = np.minimum(np.minimum(xx, w - 1 - xx), np.minimum(yy, h - 1 - yy))
    wgt = _smoothstep(dist / float(FEATHER))[..., None]
    out = wgt * a + (1.0 - wgt) * off
    _SEAM_REPORT["h"] = float(np.abs(out[0, :, :] - out[-1, :, :]).mean())
    _SEAM_REPORT["v"] = float(np.abs(out[:, 0, :] - out[:, -1, :]).mean())
    return out


def _blur_wrap(a, passes=3):
    """环绕盒模糊 ×3 ≈ 高斯；np.roll 实现保周期无缝。"""
    for _ in range(passes):
        a = (np.roll(a, 1, 0) + a + np.roll(a, -1, 0)) / 3.0
        a = (np.roll(a, 1, 1) + a + np.roll(a, -1, 1)) / 3.0
    return a


def to_albedo(a, n):
    """float 数组 → n×n LANCZOS 降采样（512 档加轻度锐化保笔触）。"""
    im = Image.fromarray(np.clip(a * 255.0 + 0.5, 0, 255).astype(np.uint8))
    im = im.resize((n, n), Image.LANCZOS)
    if n >= 512:
        im = im.filter(ImageFilter.UnsharpMask(radius=1.2, percent=55, threshold=2))
    return im


def make_normal(a, n):
    """亮度场高程 → 切线空间法线（环绕差分；符号约定同 ground_tiles.py）。"""
    im = Image.fromarray(np.clip(a * 255.0 + 0.5, 0, 255).astype(np.uint8))
    if im.size != (n, n):
        im = im.resize((n, n), Image.LANCZOS)
    lum = np.asarray(im, dtype=np.float64) / 255.0
    lum = lum[..., 0] * 0.299 + lum[..., 1] * 0.587 + lum[..., 2] * 0.114
    h = _blur_wrap(lum, passes=2 if n <= 128 else 3)
    dh = float(h.max() - h.min())
    scale = RELIEF_M / (dh if dh > 1e-9 else 1.0)
    mpp = TILE_M / float(n)                      # 米/像素（整图 = 4 格）
    dx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * 0.5 * scale
    dy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * 0.5 * scale
    nxa = -(dx / mpp)
    nya = -(dy / mpp)
    nza = np.ones_like(h)
    ln = np.sqrt(nxa * nxa + nya * nya + nza * nza)
    out = np.stack([nxa / ln * 0.5 + 0.5, nya / ln * 0.5 + 0.5,
                    nza / ln * 0.5 + 0.5], -1)
    return Image.fromarray(np.clip(out * 255.0 + 0.5, 0, 255).astype(np.uint8))


def make_rough(n):
    """均匀粗糙度 + 无缝白噪声微扰（运行时暂不消费，材质库完整性档）。"""
    rng = np.random.default_rng(7)
    r = np.full((n, n), ROUGH_BASE) + (rng.random((n, n)) - 0.5) * 0.04
    return Image.fromarray(np.clip(r * 255.0 + 0.5, 0, 255).astype(np.uint8))


def rot_variants(im):
    """旋转 90/180/270 变体（旋转保无缝）。"""
    return [im.rotate(-90), im.rotate(-180), im.rotate(-270)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dryrun", action="store_true")
    args = ap.parse_args()

    src = Image.open(SRC_AI)
    assert src.size == (1024, 1024), "源图应为 1024²，实测 %s" % (src.size,)
    seam = make_seamless(src)

    alb512 = to_albedo(seam, 512)
    alb128 = to_albedo(seam, 128)
    nrm512 = make_normal(seam, 512)
    nrm128 = make_normal(seam, 128)
    rgh512 = make_rough(512)
    rgh128 = make_rough(128)

    plan = []  # (落盘目录, 文件名)
    # 128 游戏档的旋转变体（512 高清档单文件，管线无 512 变体）
    for vi, v in enumerate(rot_variants(alb128)):
        plan.append((OUT_DIRS[0], "grass_alb_128_v%d.png" % (vi + 1), v))
        plan.append((OUT_DIRS[0], "grass_nrm_128_v%d.png" % (vi + 1),
                     rot_variants(nrm128)[vi]))
        plan.append((OUT_DIRS[0], "grass_rgh_128_v%d.png" % (vi + 1),
                     rot_variants(rgh128)[vi]))
    plan += [
        (OUT_DIRS[0], "grass_alb.png", alb512),
        (OUT_DIRS[0], "grass_nrm.png", nrm512),
        (OUT_DIRS[0], "grass_rgh.png", rgh512),
        (OUT_DIRS[0], "grass_alb_128.png", alb128),
        (OUT_DIRS[0], "grass_nrm_128.png", nrm128),
        (OUT_DIRS[0], "grass_rgh_128.png", rgh128),
        # 工程内入库副本（运行时优先读取；只落库内既有文件名）
        (OUT_DIRS[1], "grass_alb.png", alb512),
        (OUT_DIRS[1], "grass_nrm_128.png", nrm128),
        (OUT_GAME_DIRS[1], "grass_alb_128.png", alb128),
    ]
    for vi, v in enumerate(rot_variants(alb128)):
        plan.append((OUT_GAME_DIRS[1], "grass_alb_128_v%d.png" % (vi + 1), v))

    print("[grass-ai-reskin] 源=%s" % SRC_AI)
    print("[grass-ai-reskin] 无缝化后边缘差: 水平 %.4f / 垂直 %.4f (0~1)"
          % (_SEAM_REPORT["h"], _SEAM_REPORT["v"]))
    for d, fname, im in plan:
        print("  -> %s/%s" % (os.path.relpath(d, REPO), fname))
        if not args.dryrun:
            os.makedirs(d, exist_ok=True)
            im.save(os.path.join(d, fname))
    print("[grass-ai-reskin] %d 个文件%s" % (len(plan),
          "（dryrun 未写盘）" if args.dryrun else " 已落盘"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
