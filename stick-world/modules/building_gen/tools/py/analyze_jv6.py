"""
方案Jv6 渲染诊断：对比贴图本身和渲染图屋顶区域的视觉特征
- 贴图：preview_thatch.png（应有草束细节）
- 渲染图：smithy_preview_render.png（屋顶区域应有草束细节）
- 参考图：smithy_lv1_full.png（屋顶区域有草束细节）

输出：
1. 贴图的 std/对比度/边缘密度
2. 渲染图屋顶区域的 std/对比度/边缘密度
3. 参考图屋顶区域的 std/对比度/边缘密度
4. 渲染图屋顶区域是否真的"均匀色块"
"""

import cv2
import numpy as np
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BUILDING_GEN = os.path.normpath(os.path.join(SCRIPT_DIR, "..", ".."))
REF_DIR = os.path.join(BUILDING_GEN, "reference")

TEX_PATH = os.path.join(REF_DIR, "preview_thatch.png")
RENDER_PATH = os.path.join(REF_DIR, "smithy_preview_render.png")
REF_PATH = os.path.join(REF_DIR, "smithy_lv1_full.png")


def analyze_region(name, img):
    """分析一张图（或区域）的视觉特征"""
    if img is None:
        print(f"  [{name}] 图像为空")
        return
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    h, w = gray.shape
    mean = np.mean(gray)
    std = np.std(gray)
    # 边缘密度（Canny）
    edges = cv2.Canny(gray, 50, 150)
    edge_density = np.sum(edges > 0) / (h * w) * 100
    # 对比度（最大最小差）
    contrast = int(gray.max()) - int(gray.min())
    # 颜色变化（BGR std）
    color_std = np.mean(np.std(img.reshape(-1, 3), axis=0))
    print(f"  [{name}] size={w}x{h}  mean={mean:.1f}  std={std:.1f}  contrast={contrast}  edge_density={edge_density:.2f}%  color_std={color_std:.1f}")


def main():
    print("=" * 70)
    print("【贴图本身】preview_thatch.png")
    tex = cv2.imread(TEX_PATH, cv2.IMREAD_COLOR)
    analyze_region("texture_full", tex)
    # 切成 4 个区域看分布
    if tex is not None:
        h, w = tex.shape[:2]
        analyze_region("texture_topleft", tex[:h//2, :w//2])
        analyze_region("texture_topright", tex[:h//2, w//2:])
        analyze_region("texture_botleft", tex[h//2:, :w//2])
        analyze_region("texture_botright", tex[h//2:, w//2:])

    print("=" * 70)
    print("【渲染图】smithy_preview_render.png 全图")
    render = cv2.imread(RENDER_PATH, cv2.IMREAD_COLOR)
    analyze_region("render_full", render)

    # 渲染图屋顶区域 — 手动指定 ROI（从历史日志：rect=(-291,-358,652,358)，缩放后约 645x365）
    # RoofMain 在场景坐标系中 bl=(103,-232), tr=(39+rm_dw,-346)
    # 简化：在渲染图中中央偏上区域找屋顶
    if render is not None:
        h, w = render.shape[:2]
        print(f"\n  渲染图尺寸: {w}x{h}")
        # 试着切几个区域看哪个是屋顶（屋顶通常是浅棕色）
        # 渲染图整体范围：约 (20, 20) 到 (665, 385)
        # 屋顶在场景 y=-346 到 -200，对应渲染图 y 较小（顶部）
        # 场景 x 范围 -291 到 361，渲染图 x 范围 20 到 665
        # 取渲染图中央偏上区域作为屋顶候选
        roi_y1 = int(h * 0.05)
        roi_y2 = int(h * 0.45)
        roi_x1 = int(w * 0.15)
        roi_x2 = int(w * 0.85)
        roof_roi = render[roi_y1:roi_y2, roi_x1:roi_x2]
        print(f"\n  屋顶候选 ROI: y=[{roi_y1},{roi_y2}], x=[{roi_x1},{roi_x2}]")
        analyze_region("render_roof_roi", roof_roi)
        # 把 ROI 保存出来便于人工查看
        cv2.imwrite(os.path.join(REF_DIR, "_debug_render_roof_roi.png"), roof_roi)
        print(f"  → 已保存 _debug_render_roof_roi.png")

        # 在 ROI 内做更细的分块分析（看是否有局部变化）
        if roof_roi is not None:
            rh, rw = roof_roi.shape[:2]
            block_size = 32
            print(f"\n  分块 std 热力图（{block_size}x{block_size} 块）:")
            for by in range(0, rh, block_size):
                line = ""
                for bx in range(0, rw, block_size):
                    block = roof_roi[by:by+block_size, bx:bx+block_size]
                    if block.size == 0:
                        continue
                    bstd = np.std(cv2.cvtColor(block, cv2.COLOR_BGR2GRAY))
                    # 用符号表示 std 大小
                    if bstd < 10:
                        line += "· "  # 几乎纯色
                    elif bstd < 25:
                        line += "○ "  # 略有变化
                    elif bstd < 50:
                        line += "◯ "  # 中等变化
                    elif bstd < 80:
                        line += "◉ "  # 较大变化
                    else:
                        line += "★ "  # 大变化
                print("    " + line)

    print("=" * 70)
    print("【参考图】smithy_lv1_full.png 全图")
    ref = cv2.imread(REF_PATH, cv2.IMREAD_COLOR)
    analyze_region("ref_full", ref)
    # 参考图屋顶区域 — 从历史信息，参考图屋顶在中央偏上
    if ref is not None:
        h, w = ref.shape[:2]
        print(f"\n  参考图尺寸: {w}x{h}")
        # 假设屋顶在上半部分中央
        roi_y1 = int(h * 0.20)
        roi_y2 = int(h * 0.50)
        roi_x1 = int(w * 0.20)
        roi_x2 = int(w * 0.80)
        ref_roof = ref[roi_y1:roi_y2, roi_x1:roi_x2]
        print(f"\n  参考图屋顶 ROI: y=[{roi_y1},{roi_y2}], x=[{roi_x1},{roi_x2}]")
        analyze_region("ref_roof_roi", ref_roof)
        cv2.imwrite(os.path.join(REF_DIR, "_debug_ref_roof_roi.png"), ref_roof)
        print(f"  → 已保存 _debug_ref_roof_roi.png")

        # 分块分析
        if ref_roof is not None:
            rh, rw = ref_roof.shape[:2]
            block_size = 32
            print(f"\n  分块 std 热力图（{block_size}x{block_size} 块）:")
            for by in range(0, rh, block_size):
                line = ""
                for bx in range(0, rw, block_size):
                    block = ref_roof[by:by+block_size, bx:bx+block_size]
                    if block.size == 0:
                        continue
                    bstd = np.std(cv2.cvtColor(block, cv2.COLOR_BGR2GRAY))
                    if bstd < 10:
                        line += "· "
                    elif bstd < 25:
                        line += "○ "
                    elif bstd < 50:
                        line += "◯ "
                    elif bstd < 80:
                        line += "◉ "
                    else:
                        line += "★ "
                print("    " + line)


if __name__ == "__main__":
    main()
