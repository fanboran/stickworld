"""生成仅屋顶渲染与参考图的 side-by-side 对比图。"""
import os
import cv2
import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BUILDING_GEN = os.path.normpath(os.path.join(SCRIPT_DIR, "..", ".."))
REF_DIR = os.path.join(BUILDING_GEN, "reference")

GEN_PATH = os.path.join(REF_DIR, "roof_only_render.png")
REF_PATH = os.path.join(REF_DIR, "thatch_ref.png")
OUT_PATH = os.path.join(REF_DIR, "roof_side_by_side.png")


def load_rgba(path):
    """以 RGBA 方式读取图片，保持透明通道。"""
    img = cv2.imread(path, cv2.IMREAD_UNCHANGED)
    if img is None:
        raise FileNotFoundError(f"无法读取: {path}")
    if len(img.shape) == 2:
        img = cv2.cvtColor(img, cv2.COLOR_GRAY2RGBA)
    elif img.shape[2] == 3:
        img = cv2.cvtColor(img, cv2.COLOR_BGR2RGBA)
    elif img.shape[2] == 4:
        img = cv2.cvtColor(img, cv2.COLOR_BGRA2RGBA)
    return img


def resize_to_height(img, target_h):
    """等比缩放到指定高度。"""
    h, w = img.shape[:2]
    new_w = max(1, int(w * target_h / h))
    return cv2.resize(img, (new_w, target_h), interpolation=cv2.INTER_AREA)


def main():
    gen = load_rgba(GEN_PATH)
    ref = load_rgba(REF_PATH)

    target_h = 400
    gen_r = resize_to_height(gen, target_h)
    ref_r = resize_to_height(ref, target_h)

    gap = 30
    total_h = target_h + 80
    total_w = gen_r.shape[1] + ref_r.shape[1] + gap

    # 浅灰背景，RGBA
    canvas = np.full((total_h, total_w, 4), 240, dtype=np.uint8)

    # 标签
    font = cv2.FONT_HERSHEY_SIMPLEX
    cv2.putText(canvas, "Generated Roof", (10, 35), font, 0.8, (60, 60, 60, 255), 2)
    cv2.putText(canvas, "Reference (thatch_ref)", (gen_r.shape[1] + gap + 10, 35), font, 0.8, (60, 60, 60, 255), 2)

    y_off = 50
    x_off = 0
    canvas[y_off:y_off+target_h, x_off:x_off+gen_r.shape[1]] = gen_r
    x_off += gen_r.shape[1] + gap
    canvas[y_off:y_off+target_h, x_off:x_off+ref_r.shape[1]] = ref_r

    cv2.imwrite(OUT_PATH, cv2.cvtColor(canvas, cv2.COLOR_RGBA2BGRA))
    print(f"OK: {OUT_PATH}  size={total_w}x{total_h}")


if __name__ == "__main__":
    main()
