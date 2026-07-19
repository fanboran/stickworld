"""
smithy_lv1.png 茅草材质提取 (SAM)

用 Meta SAM 模型分割两侧屋檐茅草区域，输出：
  1. 原始形状贴图 (保留完整屋檐轮廓，半透明木架)
  2. 可平铺茅草贴图 (中央对齐，边缘羽化 alpha)

用法:
    CODEBUDDY_UNSAFE_DELETE=1 python tools/sam_extract_thatch.py
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import numpy as np
import torch
from PIL import Image, ImageFilter
from segment_anything import SamPredictor, sam_model_registry

# ---- 配置 -----------------------------------------------------------------

SRC = Path(r"F:\VSCode\game-2\stick-world\modules\old_buildings\assets\smithy_lv1.png")
OUT_DIR = SRC.parent

# SAM 模型路径
SAM_MODEL = Path(os.path.expanduser("~/.cache/sam/sam_vit_b_01ec64.pth"))
SAM_TYPE = "vit_b"

# 两侧屋檐的 Box Prompt [x1, y1, x2, y2]
# 大框覆盖整个屋檐+木架, 配合正样本点定位茅草
LEFT_ROOF_BOX = np.array([10, 10, 410, 380])
RIGHT_ROOF_BOX = np.array([610, 10, 1010, 380])

# 茅草区域内的正样本点 (x, y) — 帮 SAM 锁定"茅草"对象
LEFT_THATCH_POINTS = np.array([
    [120, 80],
    [200, 130],
    [80, 170],
    [250, 200],
])
RIGHT_THATCH_POINTS = np.array([
    [900, 80],
    [820, 130],
    [950, 170],
    [780, 200],
])

# 负样本点 — 不用了, 改用颜色过滤后处理排木架
NEGATIVE_POINTS = np.array([]).reshape(0, 2)

# 可平铺贴图参数
TILE_SIZE = 256  # 裁切 256×256
TILE_FEATHER = 32  # 边缘羽化像素


def load_sam():
    """加载 SAM 模型。"""
    print(f"[INFO] 加载 SAM 模型: {SAM_MODEL}")
    sam = sam_model_registry[SAM_TYPE](checkpoint=str(SAM_MODEL))
    sam.to(device="cpu")
    return SamPredictor(sam)


def load_image(path: Path) -> Image.Image:
    """加载 RGBA 图片。"""
    im = Image.open(path).convert("RGBA")
    print(f"[INFO] 源图: {path.name}  {im.size} {im.mode}")
    return im


def sam_point_mask(
    predictor: SamPredictor,
    image_rgb: np.ndarray,
    fg_points: np.ndarray,
    bg_points: np.ndarray | None = None,
) -> np.ndarray:
    """用 SAM 正+负样本点 prompt 生成前景 mask。"""
    predictor.set_image(image_rgb)
    if bg_points is not None and len(bg_points) > 0:
        points = np.concatenate([fg_points, bg_points], axis=0)
        labels = np.concatenate([
            np.ones(len(fg_points), dtype=np.int32),
            np.zeros(len(bg_points), dtype=np.int32),
        ])
    else:
        points = fg_points
        labels = np.ones(len(points), dtype=np.int32)

    masks, scores, _ = predictor.predict(
        point_coords=points,
        point_labels=labels,
        multimask_output=True,  # 多粒度取最优, 保茅草完整性
    )
    best = masks[np.argmax(scores)]
    return best.astype(np.uint8) * 255


def feather_alpha(alpha: np.ndarray, feather_px: int) -> np.ndarray:
    """对 alpha 边缘做羽化衰减。"""
    h, w = alpha.shape
    feathered = alpha.astype(np.float32)

    # 四边线性衰减
    for y in range(h):
        dist = min(y, h - 1 - y) / feather_px
        if dist < 1.0:
            feathered[y, :] *= dist
    for x in range(w):
        dist = min(x, w - 1 - x) / feather_px
        if dist < 1.0:
            feathered[:, x] *= dist

    return np.clip(feathered, 0, 255).astype(np.uint8)


def find_densest_roi(mask: np.ndarray, tile_size: int) -> tuple[int, int] | None:
    """在 mask 内找像素密度最高的 tile_size×tile_size 区域, 返回 (x, y) 左上角。"""
    h, w = mask.shape
    if h < tile_size or w < tile_size:
        return None

    # 用 box filter 算每个滑动窗口的像素总数, 取最大
    from PIL import ImageFilter
    m_img = Image.fromarray(mask).convert("L")
    blurred = m_img.filter(ImageFilter.BoxBlur(radius=tile_size // 4))
    density = np.array(blurred, dtype=np.float32)

    # 滑窗扫描找最大密度区域
    best = (0, 0)
    best_val = 0
    for y in range(0, h - tile_size + 1, 8):
        for x in range(0, w - tile_size + 1, 8):
            v = density[y:y + tile_size, x:x + tile_size].sum()
            if v > best_val:
                best_val = v
                best = (x, y)
    return best


def extract_tile(rgba: Image.Image, mask: np.ndarray, tile_size: int, feather: int) -> Image.Image | None:
    """从茅草最密集区域裁切 tile_size×tile_size 的可平铺贴图。"""
    roi = find_densest_roi(mask, tile_size)
    if roi is None:
        return None
    x, y = roi

    tile = rgba.crop((x, y, x + tile_size, y + tile_size)).copy()

    # 对茅草区域内的 alpha 做边缘羽化 (让平铺时边缘自然过渡)
    alpha = np.array(tile.split()[-1])
    feathered = feather_alpha(alpha, feather)
    tile.putalpha(Image.fromarray(feathered))

    return tile


def main() -> int:
    if not SRC.exists():
        print(f"[ERR] 源文件不存在: {SRC}", file=sys.stderr)
        return 1

    predictor = load_sam()
    img = load_image(SRC)

    # 转 RGB 给 SAM (SAM 接受 RGB)
    img_rgb = np.array(img.convert("RGB"))

    # 1) 分割左侧屋顶茅草
    print("[INFO] 分割左侧屋顶茅草 ...")
    mask_left = sam_point_mask(predictor, img_rgb, LEFT_THATCH_POINTS, NEGATIVE_POINTS)

    # 2) 分割右侧屋顶茅草
    print("[INFO] 分割右侧屋顶茅草 ...")
    mask_right = sam_point_mask(predictor, img_rgb, RIGHT_THATCH_POINTS, NEGATIVE_POINTS)

    # 合并两侧 mask
    mask_combined = np.maximum(mask_left, mask_right)

    # ---- 后处理: 膨胀 + 颜色过滤 ----
    from scipy import ndimage

    # 1) 膨胀 6px 填小洞
    mask_combined = ndimage.binary_dilation(mask_combined > 0, iterations=6).astype(np.uint8) * 255

    # 2) 颜色过滤: 去掉木架暗色区域
    arr_full = np.array(img)
    hsv = np.array(Image.fromarray(arr_full[..., :3]).convert("HSV"), dtype=np.int32)
    h, s, v = hsv[..., 0], hsv[..., 1], hsv[..., 2]
    is_thatch = (s >= 35) & (v >= 65) & (h >= 20) & (h <= 55)
    is_brown = (s >= 35) & (v >= 65) & (h >= 5) & (h < 20)
    dark_mask = ~(is_thatch | is_brown)
    mask_combined[dark_mask] = 0

    # 3) 再膨胀 3px 让边缘自然
    mask_combined = ndimage.binary_dilation(mask_combined > 0, iterations=3).astype(np.uint8) * 255

    # 4) 位置约束: 只保留图片上部 (茅草), 下部渐变透明
    h_img, w_img = mask_combined.shape
    y_coords = np.arange(h_img)[:, None]
    Y_KEEP = 480
    Y_CUT = 550
    in_zone = y_coords < Y_KEEP
    fade_zone = (y_coords >= Y_KEEP) & (y_coords < Y_CUT)
    fade = np.where(fade_zone, 1.0 - (y_coords - Y_KEEP) / (Y_CUT - Y_KEEP), 1.0)
    fade = np.where(in_zone, 1.0, fade)
    fade = np.where(y_coords >= Y_CUT, 0.0, fade)
    mask_combined = (mask_combined.astype(np.float32) * fade).astype(np.uint8)

    # ---- 输出1: 原始形状贴图 ----
    arr = np.array(img)
    arr[:, :, 3] = mask_combined
    shaped = Image.fromarray(arr)
    shaped_path = OUT_DIR / "smithy_lv1_thatch.png"
    shaped.save(shaped_path, "PNG")
    print(f"[OK]  原始形状茅草: {shaped_path.name}")

    # ---- 输出2: 可平铺贴图 ----
    tile = extract_tile(Image.fromarray(arr), mask_combined, TILE_SIZE, TILE_FEATHER)
    if tile:
        tile_path = OUT_DIR / "smithy_lv1_thatch_tile.png"
        tile.save(tile_path, "PNG")
        print(f"[OK]  可平铺茅草: {tile_path.name}")
    else:
        print("[WARN] 未找到茅草区域，跳过可平铺贴图")

    print("[DONE] 全部完成")
    return 0


if __name__ == "__main__":
    sys.exit(main())
