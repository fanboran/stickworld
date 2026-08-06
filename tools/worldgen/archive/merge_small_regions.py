"""合并地区（用户指令，修正版：按实际最近距离而非质心距离）。

指令（crops 编号 = label）：
  - region_013 + region_009 合并
  - region_008 + region_023 合并
  - 小地区 {12, 14-22, 24-35} 就近并入最近地区
    合并规则：对小岛计算到每个其他地区的最短像素距离（EDT），
    并入距离最近的地区（而非质心欧氏距离——后者会跨海错并）。

用法：
  python tools/worldgen/merge_small_regions.py
"""
import json
import os

import numpy as np
from scipy.ndimage import distance_transform_edt

HERE = os.path.dirname(os.path.abspath(__file__))
REGIONS_DIR = os.path.join(HERE, "..", "output", "regions")

# 显式合并对（源 -> 目标）
EXPLICIT_MERGES = [(13, 9), (23, 8)]
# 小地区就近合并（12-22, 24-35，排除已显式处理的 13/23）
SMALL_LABELS = [l for l in list(range(12, 23)) + list(range(24, 36)) if l not in (13, 23)]

# 搜索窗口（小岛周围多少像素内找最近地区；超出视为无更近）
SEARCH_RADIUS = 80


def nearest_region(labels, lab):
    """小岛 lab 到每个其他地区的最短像素距离（局部窗口 EDT）。"""
    m = labels == lab
    ys, xs = np.where(m)
    if ys.size == 0:
        return None
    y0, y1 = max(0, ys.min() - SEARCH_RADIUS), min(labels.shape[0], ys.max() + SEARCH_RADIUS + 1)
    x0, x1 = max(0, xs.min() - SEARCH_RADIUS), min(labels.shape[1], xs.max() + SEARCH_RADIUS + 1)
    m_win = m[y0:y1, x0:x1]
    if not m_win.any():
        return None
    best, best_d = None, float("inf")
    for other in range(1, int(labels.max()) + 1):
        if other == lab:
            continue
        o_win = (labels[y0:y1, x0:x1] == other)
        if not o_win.any():
            continue
        d = distance_transform_edt(~o_win)
        mind = int(d[m_win].min())
        if mind < best_d:
            best_d = mind
            best = other
    return (best, best_d) if best is not None else None


def main():
    print("[1/4] 读取当前 labels...")
    labels = np.load(os.path.join(REGIONS_DIR, "region_labels.npy"))
    old_data = json.load(open(os.path.join(REGIONS_DIR, "region_data.json"), encoding="utf-8"))
    old_region_info = {r["label"]: r for r in old_data["regions"]}
    n_before = int(labels.max())
    print("  当前地区数: %d" % n_before)

    print("[2/4] 显式合并 %s ..." % EXPLICIT_MERGES)
    for src, dst in EXPLICIT_MERGES:
        n_px = int((labels == src).sum())
        labels[labels == src] = dst
        print("  L%d -> L%d (%d px)" % (src, dst, n_px))

    print("[3/4] 小地区就近合并（%d 个，按实际最近距离）..." % len(SMALL_LABELS))
    merged = 0
    for src in SMALL_LABELS:
        if src not in np.unique(labels):
            continue
        result = nearest_region(labels, src)
        if result is None:
            print("  L%d 无更近地区，保留" % src)
            continue
        dst, dist = result
        n_px = int((labels == src).sum())
        labels[labels == src] = dst
        merged += 1
        print("  L%d -> L%d (%d px, 最近距离 %dpx)" % (src, dst, n_px, dist))
    print("  共就近合并 %d 个" % merged)

    print("[4/4] 重编号 + 重算 + 预览图 + 特写图...")
    from apply_region_plan import (
        compute_regions, relabel_compact, render_crops, render_preview,
    )
    labels, mapping = relabel_compact(labels)
    regions = compute_regions(labels, labels.shape[0], mapping, old_region_info)
    data = {"size": int(labels.shape[0]), "n_regions": len(regions), "regions": regions}
    with open(os.path.join(REGIONS_DIR, "region_data.json"), "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    np.save(os.path.join(REGIONS_DIR, "region_labels.npy"), labels)
    render_preview(labels, regions, REGIONS_DIR)
    render_crops(labels, regions, REGIONS_DIR, labels.shape[0])
    from collections import Counter
    print("  最终地区数: %d, 类型: %s" % (len(regions), dict(Counter(r["type"] for r in regions))))
    print("完成。")


if __name__ == "__main__":
    main()
