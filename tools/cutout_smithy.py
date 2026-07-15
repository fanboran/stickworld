"""
smithy.png 切分 + rembg 抠图脚本

将 2×2 拼接的铁匠铺素材图切成 4 份，分别用 rembg 抠图（保留 alpha 通道），
输出 4 张透明 PNG。

布局:
    左上 -> lv1  (茅草顶简易铁匠铺)
    右上 -> lv2  (木板结构)
    左下 -> lv3  (石墙结构)
    右下 -> lv4  (精装砖石)

用法:
    python tools/cutout_smithy.py

输入: stick-world/assets/buildings/smithy.png
输出: stick-world/assets/buildings/smithy_lv1.png ... smithy_lv4.png
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

os.environ["CODEBUDDY_UNSAFE_DELETE"] = "1"

from PIL import Image

# 本地模型路径 (绕过 pooch 的 SSL 问题)
MODEL_PATH = Path(os.environ.get("USERPROFILE", "")) / ".u2net" / "isnet-general-use.onnx"

from rembg import new_session, remove
from rembg.sessions.dis_general_use import DisSession

# ---- 配置 -----------------------------------------------------------------

SRC = Path(__file__).resolve().parent.parent / "stick-world" / "assets" / "buildings" / "smithy.png"
OUT_DIR = SRC.parent

# rembg 模型选择:
#   - isnet-general-use  对硬边人造物体(建筑/产品)边缘更干净, 推荐
#   - u2net              通用, 但对人造物体易糊边
#   - u2netp             轻量快速, 质量稍弱
MODEL_NAME = "isnet-general-use"

# 四个等级的输出文件名, 顺序对应 [左上, 右上, 左下, 右下]
LEVEL_NAMES = ["smithy_lv1", "smithy_lv2", "smithy_lv3", "smithy_lv4"]

MODEL_NAME = "isnet-general-use"


def split_into_quadrants(img: Image.Image) -> list[Image.Image]:
    """把 2×2 拼接图切成 4 份。顺序: 左上, 右上, 左下, 右下。"""
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

    print(f"[INFO] 加载本地模型: {MODEL_PATH}")
    if not MODEL_PATH.exists():
        print(f"[ERR] 模型文件不存在: {MODEL_PATH}", file=sys.stderr)
        return 1
    # 用 LocalSession (绕过 pooch SSL 问题)
    DisSession.download_models = classmethod(lambda cls, *a, **kw: MODEL_PATH)
    session = new_session(MODEL_NAME)

    quadrants = split_into_quadrants(src_img)
    if len(quadrants) != len(LEVEL_NAMES):
        print(f"[ERR] 切分数量({len(quadrants)}) 与命名数量({len(LEVEL_NAMES)})不匹配", file=sys.stderr)
        return 2

    rel_root = OUT_DIR.parent.parent
    for name, quad in zip(LEVEL_NAMES, quadrants):
        print(f"[INFO] 抠图: {name}  ({quad.size[0]}x{quad.size[1]}) ...")
        result = remove(quad, session=session)
        out_path = OUT_DIR / f"{name}.png"
        result.save(out_path, "PNG")
        print(f"[OK]  写入: {out_path.relative_to(rel_root)}")

    print("[DONE] 全部完成")
    return 0


if __name__ == "__main__":
    sys.exit(main())
