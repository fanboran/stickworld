"""应用合并/拆分计划（region_merge_tool.html 导出的 merge_split_plan.json）。

流程：
  1. 读取当前 region_labels.npy（2048 工作分辨率）
  2. 先执行全部合并（labels 组内像素并入同一 label）
  3. 再执行全部拆分（watershed 分水岭在地区内部沿地形自然二分）
  4. 重新编号、重算地区数据（多边形/邻接/面积/类型）
  5. 重新生成唯一色预览图 + color_map.json
  6. 生成各地区裁切特写图（L3 地形图裁切 + 蒙版 + 描边 + 标注）

用法：
  python tools/worldgen/apply_region_plan.py [--plan <json>] [--size 2048]
"""
import argparse
import json
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage as ndi
from skimage.measure import find_contours
from skimage.segmentation import watershed

HERE = os.path.dirname(os.path.abspath(__file__))
REGIONS_DIR = os.path.join(HERE, "..", "output", "regions")
LOCKED_DIR = os.path.join(HERE, "..", "output", "locked")
DEFAULT_PLAN = r"F:\Downloads\merge_split_plan.json"

OCEAN_COLOR = (30, 55, 95)


def load_labels_size(size):
    labels = np.load(os.path.join(REGIONS_DIR, "region_labels.npy"))
    if labels.shape[0] != size:
        from PIL import Image as I
        img = I.fromarray(labels.astype(np.int32) if labels.dtype == np.int32 else labels, "I")
        # 直接最近邻重采样
        arr = np.array(img.resize((size, size), I.NEAREST))
        labels = arr.astype(np.int32)
    return labels


def apply_merges(labels, merges):
    """合并：把每组 labels 统一为组内最小 label。返回 label 映射信息。"""
    applied = []
    for m in merges:
        group = sorted(m.get("labels", []))
        if not group:
            continue
        target = group[0]
        for lab in group[1:]:
            labels[labels == lab] = target
        applied.append((group, target))
    return applied


def split_at_isthmus(labels, cut_labels, new_label, relief):
    """在地峡（最窄列/行）处切开地区主体，贴合上下边界形成自然切口。

    步骤：
      1. 取拆分目标的最大连通分量作为"主体"（排除被合并进来的远处不相连小岛）
      2. 沿 x 方向扫描每列主体宽度（y 跨度），平滑后找中段局部最小值 = 竖直地峡
      3. 沿 y 方向扫描每行主体宽度（x 跨度），找中段局部最小值 = 水平地峡
      4. 选择相对更窄的那个方向，在该地峡列/行处切开（贴合边界，非直线硬切）
      5. 附属小岛按质心距离并入就近一块

    返回 (切走像素数, 面积占比)。失败返回 (0, 0)。
    """
    mask = np.isin(labels, cut_labels)
    ys, xs = np.where(mask)
    if xs.size == 0:
        return 0, 0.0
    area = mask.sum()
    # 连通分量：取最大者为主体
    lbl, n_comp = ndi.label(mask)
    sizes = np.bincount(lbl.ravel())
    main = int(sizes[1:].argmax()) + 1
    main_mask = lbl == main
    m_ys, m_xs = np.where(main_mask)
    main_area = int(m_ys.size)
    if main_area < 200:
        return 0, 0.0

    y0, y1 = m_ys.min(), m_ys.max()
    x0, x1 = m_xs.min(), m_xs.max()

    # 竖直地峡检测：每列宽度（y 跨度），平滑后找中段局部最小
    col_w = np.zeros(x1 - x0 + 1)
    for x in range(x0, x1 + 1):
        col = main_mask[:, x]
        if col.any():
            yys = np.where(col)[0]
            col_w[x - x0] = yys.max() - yys.min() + 1
    kern = np.ones(9) / 9
    col_sm = np.convolve(col_w, kern, mode="same")

    # 水平地峡检测：每行宽度（x 跨度）
    row_w = np.zeros(y1 - y0 + 1)
    for y in range(y0, y1 + 1):
        row = main_mask[y, :]
        if row.any():
            xxs = np.where(row)[0]
            row_w[y - y0] = xxs.max() - xxs.min() + 1
    row_sm = np.convolve(row_w, kern, mode="same")

    def _find_waists(sm, span, edge_margin=0.08):
        """找平滑曲线的中段窄区（地峡候选）。

        返回 [(index, 谷值, 谷深比)]：
          - 谷值 = 该处平滑宽度
          - 谷深比 = min(两侧较宽均值) / 谷值（>1 表示两侧更宽）
        条件放宽：宽度 < 中位数 0.85 倍即可（允许宽谷/台地状地峡），
        且两侧 4% 跨度均值 > 谷值（不要求 1.15 倍，避免漏掉平缓地峡）。
        """
        n = len(sm)
        lo, hi = int(n * edge_margin), int(n * (1 - edge_margin))
        if hi - lo < 10:
            return []
        vals = sm[sm > 0]
        med = np.median(vals) if vals.size else 1.0
        out = []
        w = max(4, int(n * 0.04))
        for i in range(lo, hi):
            v = sm[i]
            if v <= 0 or v >= med * 0.85:
                continue
            left = np.mean(sm[max(0, i - w):i])
            right = np.mean(sm[i + 1:min(n, i + w + 1)])
            if left > v and right > v:
                ratio = min(left, right) / v
                out.append((i, float(v), float(ratio)))
        return out

    def _cut_ratio(axis_mask):
        """给定切割掩码（主体内一侧），返回其面积占比。"""
        px = int(axis_mask.sum())
        return px / main_area

    # 分别收集竖直/水平地峡候选
    col_waists = _find_waists(col_sm, x1 - x0 + 1)
    row_waists = _find_waists(row_sm, y1 - y0 + 1)
    xx, yy = np.meshgrid(np.arange(main_mask.shape[1]), np.arange(main_mask.shape[0]))

    # 评分：均衡度（50/50 满分）× 谷深比。均衡度 = 4*r*(1-r)（0~1）
    # 竖直方向（区分左右）权重略高：大陆默认左右延伸，左右地峡更常见
    DIR_BIAS = {'col': 1.15, 'row': 1.0}
    def _score(ratio, cut_r, direction):
        balance = 4.0 * cut_r * (1.0 - cut_r)
        return ratio * balance * DIR_BIAS[direction]

    best = None  # (score, 'col'/'row', index, ratio, cut_r)
    for idx, v, ratio in col_waists:
        cut_x = x0 + idx
        cut = main_mask & (xx > cut_x)
        r = _cut_ratio(cut)
        if r < 0.15 or r > 0.85:
            continue
        s = _score(ratio, r, 'col')
        if best is None or s > best[0]:
            best = (s, 'col', idx, ratio, r)
    for idx, v, ratio in row_waists:
        cut_y = y0 + idx
        cut = main_mask & (yy > cut_y)
        r = _cut_ratio(cut)
        if r < 0.15 or r > 0.85:
            continue
        s = _score(ratio, r, 'row')
        if best is None or s > best[0]:
            best = (s, 'row', idx, ratio, r)

    if best is None:
        print("    未找到均衡的地峡（主体 %d px），放弃拆分" % main_area)
        return 0, 0.0

    # 若竖直候选均衡度很好（切出 40-60%），强制优先竖直——大陆"区分左右"是明确意图
    col_balanced = None
    for idx, v, ratio in col_waists:
        cut_x = x0 + idx
        r = _cut_ratio(main_mask & (xx > cut_x))
        if 0.40 <= r <= 0.60:
            col_balanced = (idx, r)
            break
    if col_balanced is not None:
        direction, idx, _r = 'col', col_balanced[0], col_balanced[1]
    else:
        _, direction, idx, _v, _r = best
    if direction == 'col':
        # 竖直地峡：沿 x = 地峡列 竖直切开（左归原，右归新）
        cut_x = x0 + idx
        cut = main_mask & (xx > cut_x)
        labels[cut] = new_label
        dir_name = "竖直地峡 x=%d" % cut_x
    else:
        # 水平地峡：沿 y = 地峡行 水平切开（上归原，下归新）
        cut_y = y0 + idx
        cut = main_mask & (yy > cut_y)
        labels[cut] = new_label
        dir_name = "水平地峡 y=%d" % cut_y

    # 附属小岛（其他连通分量）：按质心距离并入就近一块
    if n_comp > 1:
        ys1, xs1 = np.where(main_mask & (labels == cut_labels[0] if len(cut_labels) == 1 else 0))
        # 计算两块质心（当前 label 分布）
        cur_main = main_mask & ((labels == cut_labels[0]) | (labels == new_label))
        ys1, xs1 = np.where(cur_main & (labels != new_label))
        ys2, xs2 = np.where(cur_main & (labels == new_label))
        if ys1.size > 0 and ys2.size > 0:
            c1 = (ys1.mean(), xs1.mean())
            c2 = (ys2.mean(), xs2.mean())
            for c in range(1, n_comp + 1):
                if c == main:
                    continue
                sub = lbl == c
                sy, sx = np.where(sub)
                if sy.size == 0:
                    continue
                sc = (sy.mean(), sx.mean())
                d1 = (sc[0] - c1[0]) ** 2 + (sc[1] - c1[1]) ** 2
                d2_ = (sc[0] - c2[0]) ** 2 + (sc[1] - c2[1]) ** 2
                if d2_ <= d1:
                    labels[sub] = new_label
    n_new = int((labels == new_label).sum())
    print("    %s 切开，新块 %d px（%.0f%%）" % (dir_name, n_new, n_new / area * 100))
    return n_new, float(n_new / area)


def relabel_compact(labels):
    """重编号为 1..N（保持稳定顺序）。返回旧 label -> 新 label 映射。"""
    unique = [int(l) for l in np.unique(labels) if l != 0]
    mapping = {old: i + 1 for i, old in enumerate(unique)}
    new = np.zeros_like(labels)
    for old, newl in mapping.items():
        new[labels == old] = newl
    return new, mapping


def compute_regions(labels, size, mapping, old_region_info, split_sources=None):
    """重算地区数据（多边形/邻接/面积/类型）。"""
    total_land = int((labels > 0).sum())
    n = int(labels.max())
    # 类型继承：旧 label 类型 -> 新 label 类型（取该组最大的）
    type_priority = {"continent": 3, "island": 2, "archipelago": 1}
    new_type = {}
    for old, newl in mapping.items():
        t = old_region_info.get(old, {}).get("type", "archipelago")
        cur = new_type.get(newl)
        if cur is None or type_priority[t] > type_priority[cur]:
            new_type[newl] = t
    # 拆分产生的 label：继承来源旧 label 的类型（拆分不改变地形性质）
    if split_sources:
        for newl, old_labels in split_sources.items():
            best = "archipelago"
            for ol in old_labels:
                t = old_region_info.get(ol, {}).get("type", "archipelago")
                if type_priority[t] > type_priority[best]:
                    best = t
            new_type[newl] = best
    regions = []
    for r in range(1, n + 1):
        mask_r = labels == r
        area = int(mask_r.sum())
        contours = find_contours(mask_r.astype(np.uint8), 0.5)
        poly = None
        if contours:
            c = contours[0]
            step = max(1, len(c) // 64)
            poly = [[float(x), float(y)] for x, y in c[::step]]
        regions.append({
            "region_id": "region_%03d" % r,
            "label": r,
            "type": new_type.get(r, "archipelago"),
            "area_px": area,
            "area_ratio": float(area / total_land),
            "polygon": poly or [],
        })
    # 邻接
    adj = {r: set() for r in range(1, n + 1)}
    padded = np.pad(labels, 1, mode="constant")
    ys, xs = np.where(padded[1:-1, 1:-1] > 0)
    for y, x in zip(ys, xs):
        v = padded[y + 1, x + 1]
        for dy, dx in ((1, 0), (0, 1)):
            w = padded[y + 1 + dy, x + 1 + dx]
            if w != 0 and w != v:
                adj[int(v)].add(int(w))
    for r in regions:
        r["adjacent"] = sorted(adj[r["label"]])
    return regions


def render_preview(labels, regions, out_dir):
    """唯一色预览 + color_map.json。"""
    from collections import Counter
    n = int(labels.max())
    colors = []
    for i in range(n):
        h = (i * 0.618033988749895) % 1.0
        s = 0.65 + 0.2 * ((i * 7) % 3) / 2.0
        l = 0.45 + 0.25 * ((i * 11) % 3) / 2.0
        c = (1 - abs(2 * l - 1)) * s
        x = c * (1 - abs((h * 6) % 2 - 1))
        m = l - c / 2
        if h < 1/6: r_, g, b = c, x, 0
        elif h < 2/6: r_, g, b = x, c, 0
        elif h < 3/6: r_, g, b = 0, c, x
        elif h < 4/6: r_, g, b = 0, x, c
        elif h < 5/6: r_, g, b = x, 0, c
        else: r_, g, b = c, 0, x
        colors.append((int((r_ + m) * 255), int((g + m) * 255), int((b + m) * 255)))
    size = labels.shape[0]
    preview = np.zeros((size, size, 3), dtype=np.uint8)
    preview[labels == 0] = OCEAN_COLOR
    color_map = {"ocean": "#%02x%02x%02x" % OCEAN_COLOR, "labels": {}}
    for r in range(1, n + 1):
        color = colors[r - 1]
        preview[labels == r] = color
        color_map["labels"][str(r)] = "#%02x%02x%02x" % color
    Image.fromarray(preview).save(os.path.join(out_dir, "region_preview_unique.png"))
    with open(os.path.join(out_dir, "color_map.json"), "w", encoding="utf-8") as f:
        json.dump(color_map, f, indent=1)
    # 标注版
    img2 = Image.fromarray(preview).convert("RGB")
    draw = ImageDraw.Draw(img2)
    try:
        font = ImageFont.truetype("arial.ttf", 16)
    except Exception:
        font = ImageFont.load_default()
    for r in range(1, n + 1):
        ys_, xs_ = np.where(labels == r)
        if ys_.size == 0:
            continue
        cy, cx = int(ys_.mean()), int(xs_.mean())
        text = str(r)
        box = draw.textbbox((0, 0), text, font=font)
        tw, th = box[2] - box[0], box[3] - box[1]
        draw.rectangle([cx - tw/2 - 2, cy - th/2 - 2, cx + tw/2 + 2, cy + th/2 + 2], fill=(0, 0, 0))
        draw.text((cx - tw/2, cy - th/2), text, fill=(255, 255, 255), font=font)
    img2.save(os.path.join(out_dir, "region_preview_unique_labels.png"))


def render_crops(labels, regions, out_dir, size=2048):
    """各地区裁切特写图：L3 地形图裁切 + 蒙版 + 描边 + 标注。"""
    crops_dir = os.path.join(out_dir, "crops")
    os.makedirs(crops_dir, exist_ok=True)
    # L3 底图（preview_fractal.png 8192 -> 与 labels 同分辨率）
    base_path = os.path.join(LOCKED_DIR, "..", "preview_fractal.png")
    base = Image.open(base_path).convert("RGB")
    if base.size[0] != size:
        base = base.resize((size, size), Image.BILINEAR)
    base_arr = np.array(base).astype(np.float32)
    n = int(labels.max())
    for r in range(1, n + 1):
        mask_r = labels == r
        ys_, xs_ = np.where(mask_r)
        if ys_.size == 0:
            continue
        pad = 20
        y0 = max(0, int(ys_.min()) - pad); y1 = min(size - 1, int(ys_.max()) + pad)
        x0 = max(0, int(xs_.min()) - pad); x1 = min(size - 1, int(xs_.max()) + pad)
        # 裁底图 + 蒙版（地区外压暗）
        crop = base_arr[y0:y1+1, x0:x1+1].copy()
        mask_c = mask_r[y0:y1+1, x0:x1+1]
        dim = crop * 0.25 + np.array(OCEAN_COLOR, dtype=np.float32) * 0.75
        crop[~mask_c] = dim[~mask_c]
        img = Image.fromarray(crop.astype(np.uint8)).convert("RGB")
        draw = ImageDraw.Draw(img)
        # 边界描边（find_contours 的点 -> 折线）
        contours = find_contours(mask_c.astype(np.uint8), 0.5)
        for c in contours:
            pts = [(float(p[1]), float(p[0])) for p in c[::max(1, len(c)//200)]]
            if len(pts) >= 2:
                draw.line(pts, fill=(255, 200, 60), width=2)
        # 标注
        cy, cx = int((ys_.mean() - y0)), int((xs_.mean() - x0))
        info = regions[r - 1]
        text = "L%02d  %s  %.1f%%" % (r, info["type"], info["area_ratio"] * 100)
        try:
            font = ImageFont.truetype("arial.ttf", 18)
        except Exception:
            font = ImageFont.load_default()
        draw.text((max(4, cx - 60), max(4, cy - 10)), text, fill=(255, 255, 255),
                  stroke_width=2, stroke_fill=(0, 0, 0), font=font)
        img.save(os.path.join(crops_dir, "region_%03d.png" % r))
    print("  特写图 -> %s（%d 张）" % (crops_dir, n))


def main():
    p = argparse.ArgumentParser(description="应用合并/拆分计划 + 生成特写图")
    p.add_argument("--plan", type=str, default=DEFAULT_PLAN)
    p.add_argument("--size", type=int, default=2048)
    args = p.parse_args()

    with open(args.plan, encoding="utf-8") as f:
        plan = json.load(f)

    print("[1/5] 读取当前 labels + 高度场（用于 watershed 拆分）...")
    labels = load_labels_size(args.size)
    # 加载高度场并降采样到工作分辨率，计算地形起伏度场（局部 max-min）
    h = np.load(os.path.join(LOCKED_DIR, "locked_heightmap_8192.npy"), mmap_mode="r")
    img_h = Image.fromarray(h, "F").resize((args.size, args.size), Image.BILINEAR)
    h_small = np.array(img_h, dtype=np.float32)
    relief = ndi.maximum_filter(h_small, size=15) - ndi.minimum_filter(h_small, size=15)
    old_data = json.load(open(os.path.join(REGIONS_DIR, "region_data.json"), encoding="utf-8"))
    old_region_info = {r["label"]: r for r in old_data["regions"]}
    total_before = int((labels > 0).sum())
    print("  当前地区数: %d, 陆地 %.1f%%" % (int(labels.max()), total_before / (args.size**2) * 100))

    print("[2/5] 合并 %d 组..." % len(plan.get("merges", [])))
    for m in plan.get("merges", []):
        group = sorted(m.get("labels", []))
        if len(group) >= 2:
            target = group[0]
            for lab in group[1:]:
                n_px = int((labels == lab).sum())
                labels[labels == lab] = target
            print("  %s -> %d" % (group, target))

    print("[3/5] 拆分 %d 组（watershed 自然二分）..." % len(plan.get("splits", [])))
    # 记录拆分来源：new_label -> 旧 label 列表（用于类型继承）
    split_sources = {}
    current_max = int(labels.max()) + 1
    for s in plan.get("splits", []):
        target = [int(l) for l in s.get("labels", [])]
        if not target:
            continue
        # 拆分对象：target 中仍存在的 label（合并后的当前地区）
        group_labels = sorted(set(int(l) for l in target if (labels == l).any()))
        if not group_labels:
            print("  跳过（label 已不存在）: %s" % target)
            continue
        # 若该组已合并为单一 label，仅切该 label；否则切 target 集合
        uniq = np.unique(labels[np.isin(labels, group_labels)])
        cut_labels = [int(u) for u in uniq] if len(uniq) > 1 else group_labels
        new_label = current_max
        current_max += 1
        split_sources[new_label] = cut_labels
        n_cut, ratio = split_at_isthmus(labels, cut_labels, new_label, relief)
        print("  %s -> 新 %d（地峡切开，切 %.0f%% 面积）" % (cut_labels, new_label, ratio * 100))

    print("[4/5] 重编号 + 重算地区数据 + 预览图...")
    labels, mapping = relabel_compact(labels)
    # 拆分来源的临时 label 需经 mapping 转换到新编号
    split_sources_mapped = {}
    for newl, old_labels in split_sources.items():
        newl_new = mapping.get(newl)
        if newl_new is not None:
            split_sources_mapped[newl_new] = old_labels
    regions = compute_regions(labels, args.size, mapping, old_region_info, split_sources_mapped)
    data = {"size": args.size, "n_regions": len(regions), "regions": regions}
    with open(os.path.join(REGIONS_DIR, "region_data.json"), "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    np.save(os.path.join(REGIONS_DIR, "region_labels.npy"), labels)
    render_preview(labels, regions, REGIONS_DIR)
    from collections import Counter
    print("  最终地区数: %d, 类型: %s" % (len(regions), dict(Counter(r["type"] for r in regions))))

    print("[5/5] 生成各地区裁切特写图...")
    render_crops(labels, regions, REGIONS_DIR, args.size)
    print("完成。")


if __name__ == "__main__":
    main()
