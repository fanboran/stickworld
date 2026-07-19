"""
smithy_lv1_thatch.png 后处理 — 去掉木架和黑色伪影

在 SAM mask 基础上做颜色过滤，只保留茅草色（H: 10-35, S: 25+, V: 40+）
"""

import os
import sys
from pathlib import Path

import numpy as np
from PIL import Image

SRC = Path(r"F:\VSCode\game-2\stick-world\modules\old_buildings\assets\smithy_lv1_thatch.png")
DST = SRC

# 茅草色 HSV 阈值 (PIL/Pillow 的 HSV 是 H: 0-255, S: 0-255, V: 0-255)
H_MIN, H_MAX = 25, 50       # 收紧到纯金黄区, 排除木架偏红棕
S_MIN = 40                  # 排除低饱和灰褐
V_MIN = 75                  # 排除暗色木架/阴影

# 也允许一些棕红色
ALLOW_BROWN_H = (160, 30)   # 棕红范围 (HSV 环形: 160-180 + 0-30)


def is_thatch_color(rgb_uint8: np.ndarray) -> np.ndarray:
    """返回符合茅草色范围的 bool mask (H, W)。"""
    hsv = np.array(
        Image.fromarray(rgb_uint8).convert("HSV"),
        dtype=np.int32,
    )
    h, s, v = hsv[..., 0], hsv[..., 1], hsv[..., 2]

    return (
        (s >= S_MIN) &
        (v >= V_MIN) &
        (
            ((h >= H_MIN) & (h <= H_MAX)) |  # 主金黄区
            ((h >= ALLOW_BROWN_H[0]) | (h <= ALLOW_BROWN_H[1]))  # 棕红边界
        )
    )


def main() -> int:
    if not SRC.exists():
        print(f"[ERR] 源文件不存在: {SRC}", file=sys.stderr)
        return 1

    print(f"[INFO] 读取: {SRC.name}")
    img = Image.open(SRC).convert("RGBA")
    arr = np.array(img)
    h, w, _ = arr.shape
    print(f"[INFO] 尺寸: {w}x{h}")

    # 当前 alpha 通道
    alpha = arr[..., 3]
    # RGB
    rgb = arr[..., :3]

    # 在现有 mask 区域里过滤颜色
    is_thatch = is_thatch_color(rgb)
    new_alpha = np.where(is_thatch, alpha, 0).astype(np.uint8)

    # 清理孤立小点 (小于 100 像素的连通域直接干掉)
    from scipy import ndimage
    labels, num = ndimage.label(new_alpha > 0)
    sizes = ndimage.sum(new_alpha > 0, labels, range(1, num + 1))
    keep_mask = np.zeros_like(new_alpha, dtype=bool)
    for i, size in enumerate(sizes):
        if size >= 100:  # 至少 100 像素
            keep_mask |= (labels == (i + 1))
    new_alpha = np.where(keep_mask, new_alpha, 0).astype(np.uint8)

    arr[..., 3] = new_alpha
    out = Image.fromarray(arr)

    out.save(DST, "PNG")
    print(f"[OK]  写入: {DST.name}  (前景像素: {int((new_alpha>0).sum()):,})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
