"""生成对比图：贴图本身 vs 渲染图 vs 参考图屋顶"""
import cv2
import numpy as np
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BUILDING_GEN = os.path.normpath(os.path.join(SCRIPT_DIR, "..", ".."))
REF_DIR = os.path.join(BUILDING_GEN, "reference")

TEX_PATH = os.path.join(REF_DIR, "preview_thatch.png")
RENDER_PATH = os.path.join(REF_DIR, "smithy_preview_render.png")
REF_PATH = os.path.join(REF_DIR, "smithy_lv1_full.png")
OUT_PATH = os.path.join(REF_DIR, "jv9_comparison.png")

tex = cv2.imread(TEX_PATH, cv2.IMREAD_COLOR)
render = cv2.imread(RENDER_PATH, cv2.IMREAD_COLOR)
ref = cv2.imread(REF_PATH, cv2.IMREAD_COLOR)

# 缩放到统一高度 400
target_h = 400
tex_r = cv2.resize(tex, (int(tex.shape[1] * target_h / tex.shape[0]), target_h))
render_r = cv2.resize(render, (int(render.shape[1] * target_h / render.shape[0]), target_h))
ref_r = cv2.resize(ref, (int(ref.shape[1] * target_h / ref.shape[0]), target_h))

# 拼接
gap = 20
total_w = tex_r.shape[1] + render_r.shape[1] + ref_r.shape[1] + gap * 2
canvas = np.full((target_h + 60, total_w, 3), 255, dtype=np.uint8)

# 贴标签
cv2.putText(canvas, "Texture (preview_thatch.png)", (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 0), 2)
cv2.putText(canvas, "Render (smithy_preview_render.png)", (tex_r.shape[1] + gap + 10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 0), 2)
cv2.putText(canvas, "Reference (smithy_lv1_full.png)", (tex_r.shape[1] + gap + render_r.shape[1] + gap + 10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 0), 2)

x_off = 0
canvas[40:40+target_h, x_off:x_off+tex_r.shape[1]] = tex_r
x_off += tex_r.shape[1] + gap
canvas[40:40+target_h, x_off:x_off+render_r.shape[1]] = render_r
x_off += render_r.shape[1] + gap
canvas[40:40+target_h, x_off:x_off+ref_r.shape[1]] = ref_r

cv2.imwrite(OUT_PATH, canvas)
print(f"OK: {OUT_PATH}  size={canvas.shape[1]}x{canvas.shape[0]}")
