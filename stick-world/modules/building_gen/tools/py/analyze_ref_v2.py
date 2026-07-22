"""
重新分析参考图：色板 + 草束方向（修正之前误读霍夫变换结果）
"""
import cv2
import numpy as np

REF_PATH = r"f:/VSCode/game-2/stick-world/modules/building_gen/reference/thatch_ref.png"
REF_FULL = r"f:/VSCode/game-2/stick-world/modules/building_gen/reference/smithy_lv1_full.png"

print("=== 1. 参考图基本信息 ===")
ref = cv2.imread(REF_PATH, cv2.IMREAD_COLOR)
print(f"thatch_ref.png: {ref.shape}")
# 透明像素 RGB 已清零，所以可以用 BGR 全0的像素作为背景
# 计算非背景像素的色板
mask = np.any(ref > 5, axis=2)  # 任何通道 >5 即非背景
print(f"非背景像素比例: {mask.mean():.3f}")
fg_pixels = ref[mask]

print("\n=== 2. 真实色板（K-Means 主色调） ===")
# 用 K-Means 聚类提取8种主色调
pixels_f = np.float32(fg_pixels.reshape(-1, 3))
criteria = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 0.5)
K = 8
_, labels, centers = cv2.kmeans(pixels_f, K, None, criteria, 5, cv2.KMEANS_PP_CENTERS)
centers = np.uint8(centers)
label_counts = np.bincount(labels.flatten())
# 按出现频率排序
sorted_idx = np.argsort(-label_counts)
print(f"{'排名':<4}{'BGR':<25}{'RGB':<25}{'归一化RGB':<25}{'占比':<8}")
for rank, idx in enumerate(sorted_idx):
    bgr = centers[idx]
    rgb = bgr[::-1]
    rgb_n = rgb / 255.0
    pct = label_counts[idx] / len(labels) * 100
    print(f"{rank+1:<4}{str(bgr.tolist()):<25}{str(rgb.tolist()):<25}{str([round(x,3) for x in rgb_n]):<25}{pct:.2f}%")

print("\n=== 3. 边缘方向分析（更精细）===")
gray = cv2.cvtColor(ref, cv2.COLOR_BGR2GRAY)
edges = cv2.Canny(gray, 50, 150)
# 用 Sobel 计算梯度方向
gx = cv2.Sobel(gray, cv2.CV_64F, 1, 0, ksize=3)
gy = cv2.Sobel(gray, cv2.CV_64F, 0, 1, ksize=3)
mag = np.sqrt(gx**2 + gy**2)
# 只看强边缘
strong = mag > 50
angles = np.arctan2(gy[strong], gx[strong])  # -pi 到 pi
# 转为 0-180 度（无方向）
angles_deg = np.degrees(angles) % 180
# 直方图统计
hist, bin_edges = np.histogram(angles_deg, bins=18, range=(0, 180))
print(f"{'角度区间':<15}{'像素数':<10}{'占比':<8}")
for i, count in enumerate(hist):
    pct = count / len(angles_deg) * 100
    bar = '█' * int(pct * 2)
    print(f"{int(bin_edges[i]):>3}°-{int(bin_edges[i+1]):>3}°  {count:<10}{pct:>5.1f}%  {bar}")

print("\n=== 4. 亮度分布（垂直/水平剖面）===")
h, w = ref.shape[:2]
# 只看前景
fg_mask = mask
# 按行计算前景平均亮度
row_brightness = []
for y in range(h):
    row_pixels = ref[y][mask[y]]
    if len(row_pixels) > 0:
        mean_b = row_pixels.mean()
        row_brightness.append((y, mean_b))
print("垂直亮度剖面（每10行采样）:")
for i in range(0, len(row_brightness), max(1, len(row_brightness)//15)):
    y, b = row_brightness[i]
    bar = '█' * int(b / 10)
    print(f"  y={y:>3}  B={b:>5.1f}  {bar}")

print("\n=== 5. 与 smithy_lv1_full.png 屋顶区域对比 ===")
full = cv2.imread(REF_FULL, cv2.IMREAD_COLOR)
print(f"smithy_lv1_full.png: {full.shape}")
# 提取屋顶区域的颜色分布（粗略取上半部分）
roof_region = full[:512, :]
roof_pixels = roof_region.reshape(-1, 3)
# 排除背景（黑色或白色）
roof_fg = roof_pixels[np.any(roof_pixels > 20, axis=1) & np.any(roof_pixels < 240, axis=1)]
print(f"上半部分前景像素数: {len(roof_fg)}")
# K-Means 提取主色
if len(roof_fg) > 100:
    pixels_f2 = np.float32(roof_fg.reshape(-1, 3))
    _, labels2, centers2 = cv2.kmeans(pixels_f2, 6, None, criteria, 5, cv2.KMEANS_PP_CENTERS)
    centers2 = np.uint8(centers2)
    label_counts2 = np.bincount(labels2.flatten())
    sorted_idx2 = np.argsort(-label_counts2)
    print(f"{'排名':<4}{'BGR':<25}{'RGB':<25}{'占比':<8}")
    for rank, idx in enumerate(sorted_idx2):
        bgr = centers2[idx]
        rgb = bgr[::-1]
        pct = label_counts2[idx] / len(labels2) * 100
        print(f"{rank+1:<4}{str(bgr.tolist()):<25}{str(rgb.tolist()):<25}{pct:.2f}%")
