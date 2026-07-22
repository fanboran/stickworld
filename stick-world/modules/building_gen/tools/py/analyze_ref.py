"""深度分析参考图的视觉特征——理解手绘茅草的形状特征"""
import cv2
import numpy as np
import os

REF_DIR = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "reference"))

for name in ["thatch_ref.png", "smithy_lv1_full.png"]:
    path = os.path.join(REF_DIR, name)
    if not os.path.isfile(path):
        print(f"[SKIP] {name} 不存在")
        continue
    img = cv2.imread(path, cv2.IMREAD_COLOR)
    h, w = img.shape[:2]
    print(f"\n{'='*60}")
    print(f"  {name}  ({w}x{h})")
    print(f"{'='*60}")

    # 颜色统计
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    print(f"  亮度: min={gray.min()} max={gray.max()} mean={gray.mean():.1f} std={gray.std():.1f}")

    # 颜色聚类（提取主色调）
    data = img.reshape(-1, 3).astype(np.float32)
    criteria = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 20, 1.0)
    k = 6
    _, labels, centers = cv2.kmeans(data, k, None, criteria, 3, cv2.KMEANS_PP_CENTERS)
    centers = centers.astype(np.uint8)
    counts = np.bincount(labels.flatten())
    print(f"  主色调 (BGR) + 占比:")
    for i in np.argsort(-counts):
        pct = counts[i] / len(labels) * 100
        if pct > 2:
            print(f"    BGR={centers[i]}  {pct:.1f}%")

    # 边缘分析
    edges = cv2.Canny(gray, 50, 150)
    edge_density = np.count_nonzero(edges) / edges.size
    print(f"  边缘密度: {edge_density:.4f}")

    # 边缘方向（霍夫变换）
    lines = cv2.HoughLinesP(edges, 1, np.pi/180, threshold=30, minLineLength=15, maxLineGap=5)
    if lines is not None:
        angles = []
        for line in lines:
            l = line.flatten()
            x1, y1, x2, y2 = int(l[0]), int(l[1]), int(l[2]), int(l[3])
            angle = np.degrees(np.arctan2(y2-y1, x2-x1))
            angles.append(angle)
        angles = np.array(angles)
        print(f"  检测到 {len(angles)} 条线段")
        vert = np.sum((np.abs(angles) > 70) & (np.abs(angles) < 110))
        horiz = np.sum((np.abs(angles) < 20))
        diag = np.sum((np.abs(angles) > 30) & (np.abs(angles) < 60))
        print(f"    垂直: {vert}  水平: {horiz}  斜向: {diag}")

    # 垂直剖面（亮度随Y的变化）
    print(f"  垂直亮度剖面 (每10%):")
    for i in range(10):
        y0 = int(h * i / 10)
        y1 = int(h * (i+1) / 10)
        region = gray[y0:y1]
        print(f"    Y {i*10:3d}-{(i+1)*10:3d}%: mean={region.mean():.1f} std={region.std():.1f}")

    # 水平带状结构检测——看是否有明显的水平分层
    row_means = np.mean(gray, axis=1)
    row_diffs = np.abs(np.diff(row_means.astype(np.int32)))
    print(f"  行间亮度跳变 (top 5): {sorted(row_diffs, reverse=True)[:5]}")

    # 检测"草束"形状——用连通域分析
    # 二值化后看连通块的大小和形状
    _, binary = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
    num_labels, labels_img, stats, centroids = cv2.connectedComponentsWithStats(binary)
    if num_labels > 1:
        areas = stats[1:, cv2.CC_STAT_AREA]
        widths = stats[1:, cv2.CC_STAT_WIDTH]
        heights = stats[1:, cv2.CC_STAT_HEIGHT]
        # 过滤太小的
        valid = areas > 50
        if np.any(valid):
            print(f"  连通域 (面积>50): {np.sum(valid)} 个")
            print(f"    面积: mean={areas[valid].mean():.0f} max={areas[valid].max()}")
            print(f"    宽度: mean={widths[valid].mean():.1f} max={widths[valid].max()}")
            print(f"    高度: mean={heights[valid].mean():.1f} max={heights[valid].max()}")
            # 宽高比
            ratios = widths[valid] / np.maximum(heights[valid], 1)
            print(f"    宽高比: mean={ratios.mean():.2f} (横向>1, 纵向<1)")
