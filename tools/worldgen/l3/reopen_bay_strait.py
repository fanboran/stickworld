# -*- coding: utf-8 -*-
"""审计#4 海湾案裁决（创始人 2026-09-12：重开海峡通道）。

S1 细化场把一个 63.5k px 的老海湾口子封了（细化场陆地压在老大陆掩码的海域上，
海湾零组件由「连海」变「封闭」→ 政权侧按 mesh 湖口径判湖，与已验收地形渲染分歧）。

本工具做**手术式重开**：在海湾 bbox 外扩窗口内，从海湾零组件出发沿「老掩码水域走廊」
泛洪（只许穿过 refined>0 且老掩码为水的 lid 像素，被真实老水/老陆阻挡）——
泛洪到达的 lid 像素 = 封口通道，全部翻回 0（海）。通道形状与老掩码水廊逐像素一致；
窗口外的全球海岸 warp 漂移一概不动。幂等（重跑无 lid 可翻即 no-op）。

附带：受影响 label 的连通域数/面积变化检查（劈裂风险）。

用法：
  python tools/worldgen/l3/reopen_bay_strait.py --check   # 只报告不写
  python tools/worldgen/l3/reopen_bay_strait.py           # 写回 refined_city_labels_8192.npy
"""
import argparse
import json
import os
from collections import deque

import numpy as np
from PIL import Image
from scipy import ndimage as ndi

HERE = os.path.dirname(os.path.abspath(__file__))
V2_DIR = os.path.join(HERE, "..", "output", "l1_v2")
OUTPUT_DIR = os.path.join(HERE, "..", "output")
REFINED = os.path.join(V2_DIR, "refined_city_labels_8192.npy")
CONTINENT = os.path.join(OUTPUT_DIR, "locked", "locked_continent_8192.png")

# 海湾案现场（2026-09-12 实测）：63.5k px 湾体 bbox + 外扩窗口
BAY_SEED = (2770, 3608)          # 湾体质心 (y, x)
WIN_HALF = 480                   # 窗口半宽：湾 bbox(315x380) 外扩，覆盖水廊与两岸


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只报告不写回")
    args = ap.parse_args()

    refined = np.load(REFINED).astype(np.int32)
    land = np.array(Image.open(CONTINENT).convert("L")) > 127
    water_old = ~land                                   # 老掩码水域（含海+老通道）
    H, W = refined.shape

    # 湾体 = 种子所在 refined 零组件（全场标注避免窗口切组件）
    zc, _ = ndi.label(refined == 0)
    bay_id = int(zc[BAY_SEED])
    assert bay_id > 0, "种子不在零组件内"
    border_ids = set(np.unique(np.concatenate(
        [zc[0, :], zc[-1, :], zc[:, 0], zc[:, -1]]))) - {0}
    enclosed = bay_id not in border_ids
    bay_px = int((zc == bay_id).sum())
    print("湾体零组件 %d：%.1f k px，封闭=%s" % (bay_id, bay_px / 1000, enclosed))
    if not enclosed:
        print("湾体已连海（此前已重开或场已变化）→ no-op")
        return

    y0 = max(BAY_SEED[0] - WIN_HALF, 0)
    y1 = min(BAY_SEED[0] + WIN_HALF, H)
    x0 = max(BAY_SEED[1] - WIN_HALF, 0)
    x1 = min(BAY_SEED[1] + WIN_HALF, W)
    print("窗口 y%d..%d x%d..%d" % (y0, y1, x0, x1))

    # 走廊泛洪：从湾体出发，穿 refined>0 且老掩码为水的 lid；老水(非湾)与老陆阻挡
    passable = np.zeros_like(refined, dtype=bool)
    passable[y0:y1, x0:x1] = (refined[y0:y1, x0:x1] > 0) & water_old[y0:y1, x0:x1]
    seed = (zc == bay_id)                               # 湾体全像素作种子
    reach = np.zeros_like(refined, dtype=bool)
    dq = deque()
    for yy, xx in zip(*np.where(seed)):
        reach[yy, xx] = True
        dq.append((yy, xx))
    hit_sea = False
    while dq:
        cy, cx = dq.popleft()
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = cy + dy, cx + dx
            if not (y0 <= ny < y1 and x0 <= nx < x1) or reach[ny, nx]:
                continue
            if zc[ny, nx] == bay_id:
                reach[ny, nx] = True
                dq.append((ny, nx))
            elif passable[ny, nx]:
                reach[ny, nx] = True
                dq.append((ny, nx))
            elif refined[ny, nx] == 0 and water_old[ny, nx]:
                reach[ny, nx] = True       # 到达非湾老水（连海侧）→ 停止扩展但标记
                if int(zc[ny, nx]) in border_ids:
                    hit_sea = True
    lid_all = reach & (refined > 0) & water_old
    # 收紧：只保留「湾体↔连海侧」通道上的 lid 连通域——
    # 湾岸一圈与通道无关的老水 sliver（不能通往连海侧）不翻，避免无谓劈裂城块
    lc, n_lid = ndi.label(lid_all)
    # 每个 lid 组件：是否邻湾体 / 是否邻连海侧老水（BFS 传递）
    touches_bay = np.zeros(n_lid + 1, dtype=bool)
    touches_sea = np.zeros(n_lid + 1, dtype=bool)
    for lid_id in range(1, n_lid + 1):
        m = lc == lid_id
        d = ndi.binary_dilation(m)
        if (d & (zc == bay_id)).any():
            touches_bay[lid_id] = True
        sea_nbs = d & (refined == 0) & water_old & (zc != bay_id)
        if sea_nbs.any() and np.isin(zc[sea_nbs], list(border_ids)).any():
            touches_sea[lid_id] = True
    # 传递闭包：从邻湾组件出发，沿「组件相邻」（共享城块桥接不成立——组件分离即
    # 不相连；相邻判定 = 膨胀后相交）传播，能到达邻海组件者保留
    lid_adj = ndi.binary_dilation(lc > 0) & (lc > 0)
    lid_adj_ids = [set(np.unique(lc[lid_adj & (lc == i)])) - {0} for i in range(n_lid + 1)]
    ok = [False] * (n_lid + 1)
    dq2 = deque(i for i in range(1, n_lid + 1) if touches_bay[i])
    seen = set(dq2)
    reach_sea = set()
    while dq2:
        i = dq2.popleft()
        if touches_sea[i]:
            reach_sea.add(i)
        for j in lid_adj_ids[i]:
            if j not in seen:
                seen.add(j)
                dq2.append(j)
    # 反向：能到海的组件沿相邻图回传标记
    keep = set()
    for i in reach_sea:
        dq3, seen3 = deque([i]), {i}
        while dq3:
            k = dq3.popleft()
            keep.add(k)
            for j in lid_adj_ids[k]:
                if j not in seen3:
                    seen3.add(j)
                    dq3.append(j)
    keep &= seen                            # 从湾可达 且 能到海
    lid = np.isin(lc, list(keep)) if keep else np.zeros_like(lid_all)
    lid_n = int(lid.sum())
    labels_hit = sorted(int(v) for v in np.unique(refined[lid]) if v > 0)
    print("封口 lid：%.1f k px（全量 %.1f k 中保留通道组件 %s）"
          % (lid_n / 1000, lid_all.sum() / 1000, sorted(keep)))
    print("涉及城块 label %s" % labels_hit)
    print("泛洪%s连海侧" % ("已触及" if hit_sea else "未触及（窗口可能不够大）"))
    if lid_n == 0 or not hit_sea:
        print("无手术目标或未打通 → 不写回")
        return

    # 劈裂/面积检查
    print("受影响城块完整性：")
    for lab in labels_hit:
        m_before = refined == lab
        n_before = ndi.label(m_before)[1]
        m_after = m_before & ~lid
        n_after = ndi.label(m_after)[1]
        a_before, a_after = int(m_before.sum()), int(m_after.sum())
        frag = ""
        if n_after > n_before:
            fc, _ = ndi.label(m_after)
            fs = sorted((ndi.sum_indices if False else np.bincount(fc.ravel()))[1:], reverse=True)
            frag = " ⚠️ 劈裂，碎片 %s" % fs[:4]
        print("  label %d：%d→%d px（-%.1f%%），组件 %d→%d%s"
              % (lab, a_before, a_after, 100 * (a_before - a_after) / max(a_before, 1),
                 n_before, n_after, frag))

    if args.check:
        print("--check：不写回")
        return

    refined[lid] = 0
    np.save(REFINED, refined.astype(np.int32))
    zc2, _ = ndi.label(refined == 0)
    now_border = int(zc2[BAY_SEED]) in set(np.unique(np.concatenate(
        [zc2[0, :], zc2[-1, :], zc2[:, 0], zc2[:, -1]]))) - {0}
    print("已写回 %s；湾体现在连海=%s" % (os.path.normpath(REFINED), now_border))


if __name__ == "__main__":
    main()
