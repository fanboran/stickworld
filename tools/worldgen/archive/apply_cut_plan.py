"""应用画线切割计划（region_cut_tool.html 导出的 region_cut_plan.json）。

切割语义（切口法）：手绘线 = 物理切口，只在**线经过的像素处**把地区挖断，
不做任何延长/外推。对每个被切口穿过的地区：
  1. 把线栅格化（切口宽约 3px），挖掉地区内切口像素
  2. 对剩余像素做连通分量分析
  3. 若分成 >= 2 个分量：最大分量保留原 label，其余分量（>=8% 面积）各分配新 label
  4. 若仍是 1 个分量（切口未贯穿，如 C 形只切到一条臂）：不动，不误伤
线穿过水域的部分不作用于任何地区，绝不会影响线未经过的远处地块。

流程：
  1. 读取合并态 region_labels_merged.npy（合并后、未拆分）
  2. 对每条切割线：切口法切开穿过的地区
  3. 重编号、重算地区数据、重新生成预览图 + 特写图

用法：
  python tools/worldgen/apply_cut_plan.py --plan <json>
"""
import argparse
import json
import os
import sys

import numpy as np
from scipy import ndimage as ndi

HERE = os.path.dirname(os.path.abspath(__file__))
REGIONS_DIR = os.path.join(HERE, "..", "output", "regions")
DEFAULT_PLAN = os.path.join(HERE, "..", "output", "region_cut_plan.json")

# 复用 apply_region_plan 的公共函数
sys.path.insert(0, HERE)
from apply_region_plan import (  # noqa: E402
    compute_regions, relabel_compact, render_crops, render_preview,
)


def rasterize_line(points, thickness=1):
    """把手绘线栅格化为像素集合（切口），厚度 = 半径（像素）。

    返回 set[(x, y)]。不做延长，只覆盖线实际经过的像素。
    """
    pixels = set()
    for i in range(len(points) - 1):
        ax, ay = points[i]
        bx, by = points[i + 1]
        seg_len = ((bx - ax) ** 2 + (by - ay) ** 2) ** 0.5
        n = max(1, int(seg_len / 1.0))
        for k in range(n + 1):
            t = k / n
            sx, sy = int(round(ax + (bx - ax) * t)), int(round(ay + (by - ay) * t))
            for dy in range(-thickness, thickness + 1):
                for dx in range(-thickness, thickness + 1):
                    pixels.add((sx + dx, sy + dy))
    return pixels


def cut_along_line(labels, points, new_label_base):
    """切口法：沿手绘线局部切开穿过的地区。

    返回 (n_new, stats, split_sources)：
      - n_new: 切出的新 label 数
      - stats: [(lab, 'cut'|'intact', 占比), ...]
      - split_sources: {new_label: [源 label]}（类型继承用）
    """
    cut_pixels = rasterize_line(points, thickness=1)
    # 线穿过的地区（切口像素所在地区）
    crossed = set()
    for sx, sy in cut_pixels:
        if 0 <= sx < labels.shape[1] and 0 <= sy < labels.shape[0]:
            v = labels[sy, sx]
            if v != 0:
                crossed.add(int(v))
    if not crossed:
        return 0, [], {}
    stats = []
    split_sources = {}
    next_label = new_label_base
    for lab in sorted(crossed):
        lab_mask = labels == lab
        total = int(lab_mask.sum())
        if total == 0:
            continue
        # 挖空切口（只挖该地区内的切口像素）
        notch = lab_mask.copy()
        for sx, sy in cut_pixels:
            if 0 <= sx < labels.shape[1] and 0 <= sy < labels.shape[0] \
                    and labels[sy, sx] == lab:
                notch[sy, sx] = False
        # 连通分量（4 邻域）
        lbl, n_comp = ndi.label(notch)
        if n_comp < 2:
            stats.append((lab, 'intact', 0.0))
            continue
        sizes = np.bincount(lbl.ravel())
        comps = [(i, int(sizes[i])) for i in range(1, n_comp + 1)]
        comps.sort(key=lambda kv: -kv[1])
        main_comp, main_size = comps[0]
        # 其余分量：>=8% 面积才独立成区，否则并入主体（防碎屑）
        cut_total = 0
        for comp, csize in comps[1:]:
            if csize < total * 0.08:
                continue
            labels[lbl == comp] = next_label
            split_sources[next_label] = [lab]
            next_label += 1
            cut_total += csize
        stats.append((lab, 'cut', cut_total / total))
    return next_label - new_label_base, stats, split_sources


def main():
    p = argparse.ArgumentParser(description="应用画线切割计划")
    p.add_argument("--plan", type=str, default=DEFAULT_PLAN)
    args = p.parse_args()

    with open(args.plan, encoding="utf-8") as f:
        plan = json.load(f)

    print("[1/4] 读取合并态 labels（合并后、未拆分）...")
    # 优先使用合并态（extract_isthmus_masks.py 产出）；无则退回当前
    merged_path = os.path.join(REGIONS_DIR, "region_labels_merged.npy")
    backup_data = json.load(open(os.path.join(REGIONS_DIR, "..", "regions_backup_v2", "region_data.json"), encoding="utf-8"))
    if os.path.exists(merged_path):
        labels = np.load(merged_path)
        print("  使用合并态: %s" % merged_path)
    else:
        labels = np.load(os.path.join(REGIONS_DIR, "region_labels.npy"))
        print("  使用当前 labels")
    # 类型信息用合并前的 59 地区数据（合并态的 label 编号与之对应）
    old_region_info = {r["label"]: r for r in backup_data["regions"]}
    print("  当前地区数: %d" % int(labels.max()))

    cuts = plan.get("cuts", [])
    print("[2/4] 沿 %d 条切割线切口切开..." % len(cuts))
    next_label = int(labels.max()) + 1
    split_sources = {}
    for ci, cut in enumerate(cuts):
        points = cut.get("points", [])
        if len(points) < 2:
            print("  线 %d：点太少，跳过" % (ci + 1))
            continue
        n_new, stats, sources = cut_along_line(labels, points, next_label)
        if n_new == 0:
            detail = ", ".join(
                "L%d %s" % (lab, "切口未贯穿(保持原状)" if st == "intact" else "无目标")
                for lab, st, _r in stats
            ) or "未穿过任何地区"
            print("  线 %d：%s" % (ci + 1, detail))
            continue
        split_sources.update(sources)
        detail = ", ".join(
            "L%d -> %d 块(%.0f%%)" % (lab, 2 if st == "cut" else 1, r * 100)
            for lab, st, r in stats
        )
        print("  线 %d：切出 %d 个新地区 [%s]" % (ci + 1, n_new, detail))
        next_label += n_new

    print("[3/4] 重编号 + 重算 + 预览图...")
    labels, mapping = relabel_compact(labels)
    # 切割产生的新 label 经 mapping 转换后，类型继承源 label（continent）
    split_sources_mapped = {}
    for newl, srcs in split_sources.items():
        newl_new = mapping.get(newl)
        if newl_new is not None:
            split_sources_mapped[newl_new] = srcs
    regions = compute_regions(labels, labels.shape[0], mapping, old_region_info, split_sources_mapped)
    data = {"size": int(labels.shape[0]), "n_regions": len(regions), "regions": regions}
    with open(os.path.join(REGIONS_DIR, "region_data.json"), "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    np.save(os.path.join(REGIONS_DIR, "region_labels.npy"), labels)
    render_preview(labels, regions, REGIONS_DIR)
    from collections import Counter
    print("  最终地区数: %d, 类型: %s" % (len(regions), dict(Counter(r["type"] for r in regions))))

    print("[4/4] 特写图...")
    render_crops(labels, regions, REGIONS_DIR, labels.shape[0])
    print("完成。")


if __name__ == "__main__":
    main()
