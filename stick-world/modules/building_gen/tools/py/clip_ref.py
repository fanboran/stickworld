"""
reference 目录管理工具：裁剪 smithy_lv1.png 中指定材质的参考区域。
支持：手动坐标裁剪 / rembg 辅助边界检测 / 输出到 reference/ 目录
用法：python clip_ref.py --type thatch_roof
"""
import cv2
import numpy as np
import argparse
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
# tools/py → 上两级到 building_gen
BUILDING_GEN = os.path.normpath(os.path.join(SCRIPT_DIR, "..", ".."))
REFERENCE_DIR = os.path.join(BUILDING_GEN, "reference")
SRC_IMAGE = os.path.join(BUILDING_GEN, "..", "old_buildings", "assets", "smithy_lv1.png")

# --- 各材质的裁剪坐标（来源：smithy_lv1.png 中的像素坐标）---
# 格式：(x, y, w, h)   ← OpenCV 格式
CROP_REGIONS = {
    "thatch_roof":    (120, 140, 180, 120),   # 茅草屋顶主体区域
    "thatch_edge":    (50,  180, 80,  80),    # 屋顶左下边缘（下垂参差）
    "thatch_right":   (280, 150, 100, 100),   # 屋顶右侧区域
    "wood_pillar":    (40,  350, 30,  120),   # 木柱
    "stone_furnace":  (320, 380, 100, 80),    # 石炉
}

os.makedirs(REFERENCE_DIR, exist_ok=True)

def clip_region(name: str, region: tuple):
    img = cv2.imread(SRC_IMAGE)
    if img is None:
        print(f"[ERROR] 无法加载 {SRC_IMAGE}")
        sys.exit(1)
    h, w = img.shape[:2]
    x, y, rw, rh = region
    # 确保裁剪不越界
    x = max(0, min(x, w-1))
    y = max(0, min(y, h-1))
    rw = min(rw, w - x)
    rh = min(rh, h - y)
    crop = img[y:y+rh, x:x+rw]
    out_path = os.path.join(REFERENCE_DIR, f"{name}.png")
    cv2.imwrite(out_path, crop)
    print(f"[OK] {out_path}  ({rw}x{rh})")

def clip_all():
    for name, region in CROP_REGIONS.items():
        clip_region(name, region)

def auto_detect_thatch():
    """使用 rembg 去掉背景后，用 OpenCV 找茅草区域边界"""
    try:
        from rembg import remove
    except ImportError:
        print("[WARN] rembg 未安装，无法自动检测。pip install rembg")
        return
    
    img = cv2.imread(SRC_IMAGE)
    if img is None:
        print(f"[ERROR] 无法加载 {SRC_IMAGE}")
        return
    
    # rembg 去除背景 → 保留前景建筑
    img_rgb = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
    result = remove(img_rgb)
    result_bgr = cv2.cvtColor(np.array(result), cv2.COLOR_RGB2BGR)
    
    # 灰度 → 找到前景的边界框
    gray = cv2.cvtColor(result_bgr, cv2.COLOR_BGR2GRAY)
    _, binary = cv2.threshold(gray, 10, 255, cv2.THRESH_BINARY)
    contours, _ = cv2.findContours(binary, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    
    if contours:
        # 取最大轮廓 (建筑主体)
        cnt = max(contours, key=cv2.contourArea)
        x, y, w, h = cv2.boundingRect(cnt)
        
        # 粗略分割：上半部分是屋顶（约顶部 35%）
        roof_h = int(h * 0.35)
        roof_crop = img[y:y+roof_h, x:x+w]
        out_path = os.path.join(REFERENCE_DIR, "thatch_roof_auto.png")
        cv2.imwrite(out_path, roof_crop)
        print(f"[OK] 自动检测 → {out_path}  ({w}x{roof_h})")
        
        # 保存完整前景框作为参考
        full_path = os.path.join(REFERENCE_DIR, "foreground_mask.png")
        cv2.imwrite(full_path, result_bgr)
        print(f"[OK] 完整前景 → {full_path}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--type", type=str, default="all", help="材质名称 (all / thatch_roof / wood_pillar / ...)")
    parser.add_argument("--auto", action="store_true", help="自动检测屋顶区域 (需要 rembg)")
    args = parser.parse_args()
    
    if args.auto:
        auto_detect_thatch()
    elif args.type == "all":
        clip_all()
    else:
        region = CROP_REGIONS.get(args.type)
        if region:
            clip_region(args.type, region)
        else:
            print(f"[ERROR] 未知材质类型: {args.type}")
            print(f"可选: {list(CROP_REGIONS.keys())}")
