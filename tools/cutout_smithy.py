"""
smithy.jpeg 切分 + rembg 抠图脚本

将 4096×4096 的 2×2 拼接铁匠铺素材图切成 4 张 2048×2048，
分别用 rembg 抠图（保留 alpha 通道），输出 4 张透明 PNG。

布局:
    左上 -> lv1  (茅草顶简易铁匠铺)
    右上 -> lv2  (木板结构)
    左下 -> lv3  (石墙结构)
    右下 -> lv4  (精装砖石)

用法:
    python tools/cutout_smithy.py

输入: stick-world/assets/buildings/smithy.jpeg
输出: stick-world/assets/buildings/smithy_lv1.png ... smithy_lv4.png
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image
from rembg import remove, new_session

# ---- 配置 -----------------------------------------------------------------

SRC = Path(__file__).resolve().parent.parent / "stick-world" / "assets" / "buildings" / "smithy.jpeg"
OUT_DIR = SRC.parent

# rembg 模型选择:
#   - isnet-general-use  对硬边人造物体(建筑/产品)边缘更干净, 推荐
#   - u2net              通用, 但对人造物体易糊边
#   - u2netp             轻量快速, 质量稍弱
MODEL_NAME = "isnet-general-use"

# 四个等级的输出文件名, 顺序对应 [左上, 右上, 左下, 右下]
LEVEL_NAMES = ["smithy_lv1", "smithy_lv2", "smithy_lv3", "smithy_lv4"]


def split_into_quadrants(img: Image.Image) -> list[Image.Image]:
    """把 4096×4096 图切成 4 份 2048×2048。顺序: 左上, 右上, 左下, 右下。"""
    w, h = img.size
    half_w, half_h = w // 2, h // 2
    boxes = [
        (0, 0, half_w, half_h),           # 左上
        (half_w, 0, w, half_h),           # 右上
        (0, half_h, half_w, h),           # 左下
        (half_w, half_h, w, h),           # 右下
    ]
    return [img.crop(box) for box in boxes]


def main() -> int:
    if not SRC.exists():
        print(f"[ERR] 源文件不存在: {SRC}", file=sys.stderr)
        return 1

    print(f"[INFO] 源图: {SRC.name}")
    src_img = Image.open(SRC).convert("RGB")
    print(f"[INFO] 尺寸: {src_img.size}  模式: {src_img.mode}")

    print(f"[INFO] 加载 rembg 模型: {MODEL_NAME} (首次会下载 ~180MB)")
    session = new_session(MODEL_NAME)

    quadrants = split_into_quadrants(src_img)
    if len(quadrants) != len(LEVEL_NAMES):
        print(f"[ERR] 切分数量({len(quadrants)}) 与命名数量({len(LEVEL_NAMES)})不匹配", file=sys.stderr)
        return 2

    for name, quad in zip(LEVEL_NAMES, quadrants):
        print(f"[INFO] 抠图: {name}  ({quad.size[0]}x{quad.size[1]}) ...")
        # alpha_matting=True 对硬边物体边缘更精细, 但慢一些
        rgba_bytes = remove(
            quad,
            session=session,
            alpha_matting=True,
            alpha_matting_background_threshold=30,
            alpha_matting_foreground_threshold=240,
            alpha_matting_erode_size=10,
        )
        out_path = OUT_DIR / f"{name}.png"
        Image.open(__import__("io").BytesIO(rgba_bytes)).save(out_path, "PNG")
        print(f"[OK]  写入: {out_path.relative_to(OUT_DIR.parent.parent)}")

    print("[DONE] 全部完成")
    return 0


if __name__ == "__main__":
    sys.exit(main())
