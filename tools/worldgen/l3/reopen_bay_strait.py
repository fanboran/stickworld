# -*- coding: utf-8 -*-
"""审计#4 海湾案裁决（创始人 2026-09-12：重开海峡通道 → 2026-09-12 扩展：一并重开全部同类站点）。

S1 细化场把若干老水域的口子封住：细化的陆地压在老大陆掩码的海域上，水域零组件由
「连海」变「封闭」→ 政权侧按 mesh 湖口径判湖（湖色平涂），地形侧按海渲染（深海+岸架），
切模式水色跳变。本工具自动发现全部此类站点并逐个手术式重开：

  分歧站点 = 现行湖光栅（build_lake_raster 同 mesh 口径）落在老掩码水域(~land)、
  而旧 fractal_lake_mask 无水 的区域 → 按其所在的 refined 零组件归并站点；
  每站点：从组件出发沿「老掩码水域走廊」泛洪（只许穿过 refined>0 且老掩码为水的
  封口像素，被真实老水/老陆阻挡），泛洪到达的 lid 全部翻回 0（海）。
  泛洪在整块老水域内进行，翻出的通道形状与老掩码水廊逐像素一致；
  与「湾体↔连海侧」无关的 lid 连通域不翻（避免无谓劈裂城块）。

幂等（重跑无分歧即 no-op）。--check 只报告不写。

用法：
  python tools/worldgen/l3/reopen_bay_strait.py --check      # 报告全部分歧站点
  python tools/worldgen/l3/reopen_bay_strait.py              # 全部重开并写回
  python tools/worldgen/l3/reopen_bay_strait.py --seed 2770 3608   # 只处理指定站点（y x）
"""
import argparse
import os
import sys
from collections import deque

import numpy as np
from PIL import Image
from scipy import ndimage as ndi

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
V2_DIR = os.path.join(HERE, "..", "output", "l1_v2")
OUTPUT_DIR = os.path.join(HERE, "..", "output")
REFINED = os.path.join(V2_DIR, "refined_city_labels_8192.npy")
CONTINENT = os.path.join(OUTPUT_DIR, "locked", "locked_continent_8192.png")
LAKE_MASK = os.path.join(OUTPUT_DIR, "fractal_lake_mask_8192.png")

MARGIN = 320          # 每站点窗口 = 组件 bbox 外扩


def load_all():
    refined = np.load(REFINED).astype(np.int32)
    land = np.array(Image.open(CONTINENT).convert("L")) > 127
    lake8 = np.array(Image.open(LAKE_MASK).convert("L")) > 127
    from reexport_political_id import build_lake_raster
    return refined, land, lake8, build_lake_raster


def divergence_sites(refined, land, lake8, build_lake_raster):
    """分歧站点：现行湖光栅判湖、旧 mask 无水、且落在老掩码水域 → 按 refined 零组件归并"""
    new_lake = build_lake_raster(refined, lake8)
    div = new_lake & ~lake8 & ~land
    zc, _ = ndi.label(refined == 0)
    border_ids = set(np.unique(np.concatenate(
        [zc[0, :], zc[-1, :], zc[:, 0], zc[:, -1]]))) - {0}
    cids = [int(c) for c in np.unique(zc[div]) if int(c) > 0 and int(c) not in border_ids]
    return div, zc, border_ids, cids, new_lake


def is_enclosed(zc, border_ids, cid):
    return cid not in border_ids


def reopen_site(refined, land, zc, border_ids, cid, verbose=True):
    """单站点手术：返回 (lid mask, 是否打通, 受影响 label 统计)"""
    m = zc == cid
    ys, xs = np.where(m)
    y0, y1 = max(ys.min() - MARGIN, 0), min(ys.max() + MARGIN + 1, refined.shape[0])
    x0, x1 = max(xs.min() - MARGIN, 0), min(xs.max() + MARGIN + 1, refined.shape[1])
    water_old = ~land
    passable = np.zeros_like(refined, dtype=bool)
    passable[y0:y1, x0:x1] = (refined[y0:y1, x0:x1] > 0) & water_old[y0:y1, x0:x1]
    # 连通泛洪：组件 ∪ passable 的连通块即为可从组件到达的 lid（scipy 一次标注）
    lab, _ = ndi.label(m | passable)
    reach = lab == lab[ys[0], xs[0]]
    lid_all = reach & (refined > 0) & water_old
    if not lid_all.any():
        return None, False, []
    # 收紧：只保留能把组件接到连海侧老水的 lid 连通域
    lc, n_lid = ndi.label(lid_all)
    lid_adj_ids = {}
    touches_bay, touches_sea = {}, {}
    dil_bay = ndi.binary_dilation(m)
    for lid_id in range(1, n_lid + 1):
        mm = lc == lid_id
        d = ndi.binary_dilation(mm)
        touches_bay[lid_id] = bool((d & m).any())
        sea_nbs = d & (refined == 0) & water_old & ~m
        touches_sea[lid_id] = bool(sea_nbs.any() and np.isin(zc[sea_nbs], list(border_ids)).any())
        nb = set(np.unique(lc[d & (lc > 0)])) - {0, lid_id}
        lid_adj_ids[lid_id] = nb
    # 正向（邻组件可达）+ 反向（能到连海侧）取交
    fwd = set(i for i in range(1, n_lid + 1) if touches_bay[i])
    dq = deque(fwd)
    while dq:
        i = dq.popleft()
        for j in lid_adj_ids.get(i, ()):  # noqa: B007
            if j not in fwd:
                fwd.add(j)
                dq.append(j)
    bwd = set(i for i in range(1, n_lid + 1) if touches_sea[i])
    dq = deque(bwd)
    while dq:
        i = dq.popleft()
        for j in lid_adj_ids.get(i, ()):
            if j not in bwd:
                bwd.add(j)
                dq.append(j)
    keep = fwd & bwd
    if not keep:
        return None, False, []
    lid = np.isin(lc, list(keep))
    # 打通判定：翻掉后组件经翻出的通道与连海侧老水相邻
    proj = ndi.binary_dilation(reach) & (refined == 0) & water_old & ~m
    reached_sea = bool(proj.any() and np.isin(zc[proj], list(border_ids)).any())
    if not reached_sea:
        return None, False, []
    labels_hit = sorted(int(v) for v in np.unique(refined[lid]) if v > 0)
    if verbose:
        print("  组 %d（%.1f k px）：lid %.1f k px，城块 %s"
              % (cid, m.sum() / 1000, lid.sum() / 1000, labels_hit))
    return lid, True, labels_hit


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只报告不写回")
    ap.add_argument("--seed", nargs=2, type=int, default=None,
                    metavar=("Y", "X"), help="只处理指定站点（默认全部）")
    args = ap.parse_args()

    refined, land, lake8, build_lake_raster = load_all()
    div, zc, border_ids, cids, _ = divergence_sites(refined, land, lake8, build_lake_raster)
    print("分歧总量 %d px，封闭站点 %d 处" % (div.sum(), len(cids)), flush=True)
    if args.seed:
        cid = int(zc[args.seed[0], args.seed[1]])
        cids = [cid] if cid > 0 else []
        print("--seed 指定站点组 %d" % cid)

    if args.check:
        total_lid, stats = 0, {}
        for cid in cids:
            if not is_enclosed(zc, border_ids, cid):
                continue
            lid, ok, labels = reopen_site(refined, land, zc, border_ids, cid)
            if not ok or lid is None:
                print("  !! 组 %d 未打通（跳过）" % cid)
                continue
            total_lid += int(lid.sum())
            for lab in labels:
                m = refined == lab
                stats[lab] = (int(m.sum()), int((m & ~lid).sum()),
                              ndi.label(m)[1], ndi.label(m & ~lid)[1])
        report_blocks(stats)
        print("共翻海 %.1f k px，涉及城块 %d 个（--check 不写回）"
              % (total_lid / 1000, len(stats)))
        return

    # 写入模式：每次只做一个站点 → 重算站点集（组件 id 会随场变化重编），直到收敛。
    # 每次转换后重算保证判定用最新场；迭代上限防病态死循环。
    total_lid, stats, it = 0, {}, 0
    while it < 400:
        div, zc, border_ids, cids, _ = divergence_sites(refined, land, lake8, build_lake_raster)
        cids = [c for c in cids if is_enclosed(zc, border_ids, c)]
        if not cids:
            break
        did = False
        for cid in cids:
            lid, ok, labels = reopen_site(refined, land, zc, border_ids, cid)
            if not ok or lid is None:
                continue
            for lab in labels:
                m = refined == lab
                a = stats.setdefault(lab, [int(m.sum()), 0, ndi.label(m)[1], 0])
                a[3] = ndi.label(m & ~lid)[1]
            refined[lid] = 0
            total_lid += int(lid.sum())
            did = True
            it += 1
            if it % 10 == 0:
                print("  ... 已处理 %d 站点，累计翻海 %.1f k px" % (it, total_lid / 1000),
                      flush=True)
            break                            # 场已变 → 重算站点集
        if not did:
            print("!! 剩余 %d 站点无法打通（跳过）：%s" % (len(cids), cids[:8]))
            break
    for lab, a in stats.items():
        a[1] = int((refined == lab).sum())
    report_blocks({k: v for k, v in stats.items()})
    print("共翻海 %.1f k px，涉及城块 %d 个，迭代 %d 次" % (total_lid / 1000, len(stats), it))
    np.save(REFINED, refined.astype(np.int32))
    div2, _, _, cids2, _ = divergence_sites(refined, land, lake8, build_lake_raster)
    print("已写回 %s；复核残余分歧 %d px（站点 %d）"
          % (os.path.normpath(REFINED), div2.sum(), len(cids2)))


def report_blocks(stats):
    print("受影响城块完整性：")
    for lab in sorted(stats):
        a0, a1, n0, n1 = stats[lab]
        flag = " ⚠️ 劈裂" if n1 > n0 else ""
        print("  label %d：%d→%d px（-%.1f%%），组件 %d→%d%s"
              % (lab, a0, a1, 100 * (a0 - a1) / max(a0, 1), n0, n1, flag))


if __name__ == "__main__":
    main()
