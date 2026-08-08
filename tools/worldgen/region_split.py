"""L3 地区切分器 —— 沿自然地形把大陆切成若干"地区"（L2 级单元）。

开发期一次性工具（Python），输入 L3 锁定产物，输出：
  output/regions/region_labels.npy         # 每像素地区 ID（0=海洋，1..N=地区）
  output/regions/region_preview.png        # 纯色块预览（每地区一色，海洋深蓝）
  output/regions/region_preview_overlay.png# 叠加在 L3 地形图上的半透明预览
  output/regions/region_data.json          # 地区多边形/邻接/面积/类型（island/continent/archipelago）

切分策略（沿自然地形，非网格）：
  1. 岛屿检测：陆地掩码连通分量
  2. 大岛（>= BIG_ISLAND_RATIO 陆地）内部用 watershed 分水岭切分——
     盆地种子按面积配额撒在局部低点，山脊/高地自然成为地区边界
  3. 中岛：独立成一个地区
  4. 小岛：按质心距离聚类成"群岛"地区（一组小岛 = 一个地区）
  5. 大陆太小（无大岛）时整个大陆单独一个地区

用法：
  python tools/worldgen/region_split.py [--size 2048] [--out <dir>]
"""
import argparse
import json
import os

import numpy as np
from PIL import Image
from scipy import ndimage as ndi
from skimage.segmentation import watershed
from skimage.measure import find_contours

LOCKED_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "output", "locked")
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "output", "regions")

# 大岛阈值：占陆地比例 >= 此值的岛需要内部切分（大陆）
BIG_ISLAND_RATIO = 0.05
# 小岛阈值：占陆地比例 < 此值的岛进入群岛聚类
SMALL_ISLAND_RATIO = 0.005
# 群岛聚类距离（像素，工作分辨率下质心距离阈值）
ARCHIPELAGO_CLUSTER_DIST = 90   # 像素单位，运行时分辨率自适应（2048 基准）
# 大陆内部分割：每个地区约占陆地比例（决定盆地种子数量）
REGION_LAND_FRACTION = 0.04

# 预览用色板（地区颜色，避开海洋蓝）
REGION_COLORS = [
    (230, 90, 90), (90, 160, 230), (110, 210, 130), (240, 180, 70),
    (180, 110, 220), (70, 200, 200), (235, 120, 180), (160, 200, 90),
    (220, 150, 60), (120, 120, 230), (90, 210, 160), (230, 100, 130),
    (180, 180, 90), (140, 160, 220), (200, 130, 200), (110, 190, 120),
    (230, 160, 120), (130, 210, 90), (200, 100, 90), (90, 140, 200),
]
OCEAN_COLOR = (30, 55, 95)


def load_inputs(size):
    """加载锁定产物并降采样到工作分辨率。"""
    h = np.load(os.path.join(LOCKED_DIR, "locked_heightmap_8192.npy"), mmap_mode="r")
    m = np.load(os.path.join(LOCKED_DIR, "locked_continent_8192.png.npy"), mmap_mode="r")
    def _resize(arr, method):
        if arr.dtype == np.float32:
            img = Image.fromarray(arr, "F")
            img = img.resize((size, size), method)
            return np.array(img, dtype=np.float32)
        img = Image.fromarray((arr * 255).astype(np.uint8), "L")
        img = img.resize((size, size), method)
        return (np.array(img) > 127).astype(np.uint8)
    return _resize(h, Image.BILINEAR), _resize(m, Image.NEAREST)


def split_continents(h, m, labels_island, island_ids, region_offset):
    """大岛内部 watershed 切分：盆地种子按面积配额，山脊成边界。

    返回 (labels, next_id, continent_labels)：labels 为工作分辨率标签图（0=海洋），
    next_id 下一地区号，continent_labels 为大岛切分产生的地区 label 集合。
    """
    size = h.shape[0]
    labels = np.zeros((size, size), dtype=np.int32)
    next_id = region_offset
    continent_labels = set()
    for iid in island_ids:
        mask = labels_island == iid
        # 该岛陆地面积（工作分辨率像素）
        n_land = int(mask.sum())
        # 地区数 = 面积 / 配额（最少 1）
        n_regions = max(1, int(round(n_land / (size * size) / REGION_LAND_FRACTION)))
        # 地形起伏度场（局部 max-min）：起伏大=陡坡/山脊，用作分水岭强度
        # （绝对高度不行：低海拔也可能有山脊，见开发记录）
        # 邻域按工作分辨率缩放（2048 基准 15px -> 8192 用 60px，保持相同物理尺度）
        relief_r = max(15, size * 15 // 2048)
        maxf = ndi.maximum_filter(h, size=relief_r)
        minf = ndi.minimum_filter(h, size=relief_r)
        relief = maxf - minf
        # 取 n_regions 个"低且分散"的种子：网格法（岛 bbox 分格，每格取最平缓点）
        # 保证种子均匀散布，避免贪心导致局部聚集
        ys_all, xs_all = np.where(mask)
        chosen = []
        if ys_all.size > 0:
            y0, y1 = ys_all.min(), ys_all.max()
            x0, x1 = xs_all.min(), xs_all.max()
            grid_n = max(1, int(np.ceil(np.sqrt(n_regions))))
            for gy in range(grid_n):
                for gx in range(grid_n):
                    if len(chosen) >= n_regions:
                        break
                    gy0 = y0 + (y1 - y0) * gy // grid_n
                    gy1 = y0 + (y1 - y0) * (gy + 1) // grid_n
                    gx0 = x0 + (x1 - x0) * gx // grid_n
                    gx1 = x0 + (x1 - x0) * (gx + 1) // grid_n
                    cell = (ys_all >= gy0) & (ys_all < gy1) & (xs_all >= gx0) & (xs_all < gx1)
                    if not cell.any():
                        continue
                    idx = np.argmin(relief[ys_all[cell], xs_all[cell]])
                    chosen.append((ys_all[cell][idx], xs_all[cell][idx]))
        if not chosen:
            continue
        # 分水岭：用起伏度场（起伏大 = 山脊/陡坡 = 边界），标记种子
        markers = np.zeros((size, size), dtype=np.int32)
        for k, (cy, cx) in enumerate(chosen):
            markers[cy, cx] = next_id + k
        seg = watershed(relief, markers, mask=mask)
        for k in range(len(chosen)):
            labels[seg == (next_id + k)] = next_id + k
            continent_labels.add(next_id + k)
        next_id += len(chosen)
    return labels, next_id, continent_labels


def cluster_small_islands(labels_island, island_ids, size):
    """小岛按质心距离聚类成群岛地区。返回 {iid: group_id}。"""
    centroids = {}
    for iid in island_ids:
        ys, xs = np.where(labels_island == iid)
        centroids[iid] = (ys.mean(), xs.mean())
    groups = []
    assigned = {}
    for iid in island_ids:
        if iid in assigned:
            continue
        group = [iid]
        assigned[iid] = len(groups)
        # 贪婪：把未分配且距离近的小岛并入
        changed = True
        while changed:
            changed = False
            for jid in island_ids:
                if jid in assigned:
                    continue
                if any(
                    (centroids[jid][0] - centroids[g][0]) ** 2 + (centroids[jid][1] - centroids[g][1]) ** 2
                    <= (ARCHIPELAGO_CLUSTER_DIST * size // 2048) ** 2
                    for g in group
                ):
                    group.append(jid)
                    assigned[jid] = len(groups)
                    changed = True
        groups.append(group)
    return assigned, groups


def main():
    p = argparse.ArgumentParser(description="L3 地区切分器")
    p.add_argument("--size", type=int, default=2048, help="工作分辨率")
    p.add_argument("--out", type=str, default=OUT_DIR)
    args = p.parse_args()
    size = args.size
    os.makedirs(args.out, exist_ok=True)

    print(f"[1/6] 加载锁定产物，工作分辨率 {size}x{size}...")
    h, m = load_inputs(size)
    land = m > 0
    total_land = int(land.sum())

    print("[2/6] 岛屿检测（连通分量）...")
    labels_island, n_islands = ndi.label(land)
    sizes = np.bincount(labels_island.ravel())[1:]
    big_ids = [i + 1 for i, s in enumerate(sizes) if s / total_land >= BIG_ISLAND_RATIO]
    mid_ids = [i + 1 for i, s in enumerate(sizes) if SMALL_ISLAND_RATIO <= s / total_land < BIG_ISLAND_RATIO]
    small_ids = [i + 1 for i, s in enumerate(sizes) if s / total_land < SMALL_ISLAND_RATIO]
    print(f"  岛屿 {n_islands} 个：大岛 {len(big_ids)}（需切分），中岛 {len(mid_ids)}（独立地区），小岛 {len(small_ids)}（群岛聚类）")

    print("[3/6] 大岛内部 watershed 切分...")
    labels, next_id, continent_labels = split_continents(h, m, labels_island, big_ids, 1)

    print("[4/6] 中岛独立地区 + 小岛群岛聚类...")
    mid_labels = set()
    for iid in mid_ids:
        labels[labels_island == iid] = next_id
        mid_labels.add(next_id)
        next_id += 1
    assigned, groups = cluster_small_islands(labels_island, small_ids, size)
    for g in groups:
        for iid in g:
            labels[labels_island == iid] = next_id
        next_id += 1
    labels[m == 0] = 0
    n_regions = next_id - 1
    print(f"  总地区数: {n_regions}（含群岛 {len(groups)} 组）")

    print("[4.5/6] 碎片合并（<1% 陆地的地区并入相邻最大地区）...")
    # 用全像素统计面积与邻接（避免循环里重复计算）
    frac_min = 0.01
    for _ in range(3):  # 多轮迭代合并
        region_sizes = np.bincount(labels.ravel())
        merged_any = False
        for r in range(1, n_regions + 1):
            if region_sizes[r] / total_land >= frac_min:
                continue
            if r in mid_labels:
                continue  # 中岛独立地区不合并
            mask_r = labels == r
            # 找相邻地区（4 邻域：padded 中心区 1:-1 对应 mask_r）
            padded = np.pad(mask_r, 1, mode="constant")
            neigh = (
                padded[1:-1, 0:-2] | padded[1:-1, 2:] |
                padded[0:-2, 1:-1] | padded[2:, 1:-1]
            ) & (labels > 0) & ~mask_r
            neigh_ids = np.unique(labels[neigh])
            if neigh_ids.size == 0:
                continue
            # 并入面积最大的邻居
            best = max(neigh_ids, key=lambda n: region_sizes[int(n)])
            labels[mask_r] = best
            merged_any = True
        if not merged_any:
            break
    n_regions = int(labels.max())

    # 合并后的类型归属：被并掉的 label 继承目标类型（用合并前的归属集判断现 label）
    label_types = {}
    for r in range(1, next_id):
        t = "continent" if r in continent_labels else ("island" if r in mid_labels else "archipelago")
        label_types[r] = t
    # 过滤微型地区（<0.1% 陆地，如单像素岛）：并入最近陆地邻居或清除为海洋
    micro_frac = 0.001
    for r in range(1, int(labels.max()) + 1):
        if (labels == r).sum() / total_land >= micro_frac:
            continue
        mask_r = labels == r
        padded = np.pad(mask_r, 1, mode="constant")
        neigh = (
            padded[1:-1, 0:-2] | padded[1:-1, 2:] |
            padded[0:-2, 1:-1] | padded[2:, 1:-1]
        ) & (labels > 0) & ~mask_r
        neigh_ids = np.unique(labels[neigh])
        if neigh_ids.size > 0:
            best = max(neigh_ids, key=lambda n: int((labels == n).sum()))
            labels[mask_r] = best
        # 无陆地邻居（孤立微型岛）：保留（仍是有效微型地区）
    n_regions = int(labels.max())
    print("[5/6] 生成预览图 + 色块图...")
    # 纯色块
    preview = np.zeros((size, size, 3), dtype=np.uint8)
    preview[~land] = OCEAN_COLOR
    for r in range(1, n_regions + 1):
        color = REGION_COLORS[(r - 1) % len(REGION_COLORS)]
        preview[labels == r] = color
    Image.fromarray(preview).save(os.path.join(args.out, "region_preview.png"))
    # 叠加 L3 地形图（地形图来自 8192 高度场渲染——用预览图作底）
    base = Image.open(os.path.join(LOCKED_DIR, "..", "preview_fractal.png")).convert("RGB")
    base = base.resize((size, size), Image.BILINEAR)
    base_arr = np.array(base).astype(np.float32)
    overlay = base_arr * 0.45 + np.array(preview).astype(np.float32) * 0.55
    Image.fromarray(overlay.astype(np.uint8)).save(os.path.join(args.out, "region_preview_overlay.png"))
    np.save(os.path.join(args.out, "region_labels.npy"), labels)

    print("[6/6] 写地区数据（多边形/邻接/面积）...")
    regions = []
    for r in range(1, n_regions + 1):
        mask_r = labels == r
        area = int(mask_r.sum())
        # 多边形轮廓（简化：取边界像素的凸包太粗，用 find_contours 首条）
        contours = find_contours(mask_r.astype(np.uint8), 0.5)
        poly = None
        if contours:
            c = contours[0]
            # 简化：间隔采样到 <= 64 点
            step = max(1, len(c) // 64)
            poly = [[float(x), float(y)] for x, y in c[::step]]
        regions.append({
            "region_id": "region_%03d" % r,
            "label": int(r),
            "type": label_types.get(int(r), "archipelago"),
            "area_px": area,
            "area_ratio": float(area / total_land),
            "polygon": poly or [],
        })
    # 邻接：边界像素 4 邻域不同地区
    adj = {r: set() for r in range(1, n_regions + 1)}
    padded = np.pad(labels, 1, mode="constant", constant_values=0)
    for y in range(1, size + 1):
        for x in range(1, size + 1):
            v = padded[y, x]
            if v == 0:
                continue
            for dy, dx in ((1, 0), (0, 1)):
                w = padded[y + dy, x + dx]
                if w != 0 and w != v:
                    adj[v].add(w)
    for r in regions:
        r["adjacent"] = sorted(int(a) for a in adj[r["label"]])
    data = {
        "size": size,
        "n_regions": n_regions,
        "n_islands": n_islands,
        "regions": regions,
    }
    with open(os.path.join(args.out, "region_data.json"), "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    print(f"  -> {args.out}/region_preview.png")
    print(f"  -> {args.out}/region_preview_overlay.png")
    print(f"  -> {args.out}/region_labels.npy")
    print(f"  -> {args.out}/region_data.json")
    print("完成。")


if __name__ == "__main__":
    main()
