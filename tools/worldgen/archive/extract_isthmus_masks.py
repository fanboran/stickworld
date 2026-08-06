"""提取要拆分的两个岛的蒙版图（供画线切割工具使用）。

流程：
  1. 从备份（regions_backup_v2 = 原始 59 地区）恢复 labels
  2. 只执行 7 组合并（不做拆分）→ 得到"合并后、拆分前"状态
  3. 提取两个拆分目标（label 8 = L8+L32、label 3 = L3+L13）的蒙版 PNG
     - 目标岛：亮色显示（用其所在地区颜色）
     - 其他陆地：深灰压暗
     - 海洋：深蓝
  4. 同时保存合并态 labels（供画线后切割用）

用法：
  python tools/worldgen/extract_isthmus_masks.py
"""
import json
import os

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
REGIONS_DIR = os.path.join(HERE, "..", "output", "regions")
BACKUP_DIR = os.path.join(HERE, "..", "output", "regions_backup_v2")
MASKS_DIR = os.path.join(HERE, "..", "output", "regions", "isthmus_masks")

# 拆分目标（来自用户 merge_split_plan.json 的 splits）
SPLIT_TARGETS = [8, 3]

OCEAN = (28, 42, 72)
OTHER_LAND = (60, 66, 78)


def main():
    os.makedirs(MASKS_DIR, exist_ok=True)

    print("[1/4] 从备份恢复原始 59 地区 labels...")
    labels = np.load(os.path.join(BACKUP_DIR, "region_labels.npy"))
    old_data = json.load(open(os.path.join(BACKUP_DIR, "region_data.json"), encoding="utf-8"))
    old_region_info = {r["label"]: r for r in old_data["regions"]}
    print("  恢复地区数: %d" % int(labels.max()))

    print("[2/4] 执行 7 组合并（来自 merge_split_plan.json）...")
    plan = json.load(open(r"F:\Downloads\merge_split_plan.json", encoding="utf-8"))
    for m in plan.get("merges", []):
        group = sorted(m.get("labels", []))
        if len(group) >= 2:
            target = group[0]
            for lab in group[1:]:
                labels[labels == lab] = target
            print("  %s -> %d" % (group, target))

    # 保存合并态（供 apply_cut_plan 使用）
    merged_path = os.path.join(REGIONS_DIR, "region_labels_merged.npy")
    np.save(merged_path, labels)
    print("  合并态保存: %s" % merged_path)

    print("[3/4] 生成蒙版图...")
    # 目标岛颜色：从当前唯一色预览图取（若存在）或用亮色
    target_colors = {
        8: (255, 200, 80),
        3: (120, 220, 255),
    }
    size = labels.shape[0]
    for lab in SPLIT_TARGETS:
        mask = labels == lab
        img = np.zeros((size, size, 3), dtype=np.uint8)
        img[labels == 0] = OCEAN
        other = (labels > 0) & (labels != lab)
        img[other] = OTHER_LAND
        img[mask] = target_colors[lab]
        out = os.path.join(MASKS_DIR, "isthmus_%d.png" % lab)
        Image.fromarray(img).save(out)
        n_px = int(mask.sum())
        ys, xs = np.where(mask)
        print("  岛 %d 蒙版 -> %s (%d px, bbox %d-%d, %d-%d)" % (
            lab, out, n_px, xs.min(), xs.max(), ys.min(), ys.max()))

    print("[4/4] 合并后地区统计：")
    from collections import Counter
    cnt = Counter(int(l) for l in labels.ravel() if l != 0)
    for lab in SPLIT_TARGETS:
        print("  label %d: %d px (%.1f%% 陆地)" % (lab, cnt[lab], cnt[lab] / (labels > 0).sum() * 100))
    print("完成。蒙版目录: %s" % MASKS_DIR)


if __name__ == "__main__":
    main()
