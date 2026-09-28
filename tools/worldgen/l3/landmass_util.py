# -*- coding: utf-8 -*-
"""同陆块约束工具——城块不得跨陆块（隔水即异块）。

群岛窄海峡问题：直线 EDT「最近城块」回填会把海峡对岸的块染过来、并缝膨胀
也会隔着 1-2px 水缝吃掉邻岛小岛。本模块提供两个共用件：
  - edt_fill_within_landmass：目标像素填「同陆块内最近城块」（无块陆块不填）
  - enforce_single_landmass：跨陆块城块保留主陆块像素，其余陆块上的零散像素
    清 0 后同陆块回填（warp 位移跨水采样、并缝越界等的兜底收尾）

lm 分组数组约定：0 = 不参与（水域/界外），>0 = 陆块 id；4 连通标记（对角贴
不算同块——窄海峡/对角接触不应把两岛连成一块）。需要给水域像素分组时，调用
方先用最近陆地传播（EDT 索引）扩展 lm 后传入（水像素归最近岸的陆块）。
"""
import numpy as np
from scipy import ndimage as ndi


def landmass_ids(landmask):
    """陆地 4 连通分量 id 数组（对角接触不算同块）。"""
    return ndi.label(landmask)


def propagate_over_water(lm, landmask):
    """lm 按最近陆地传播到全域（水像素归最近岸所属陆块；湾心/远海归最近岛）。"""
    _, inds = ndi.distance_transform_edt(~landmask, return_indices=True)
    return lm[inds[0], inds[1]]


def edt_fill_within_landmass(labels, target, lm):
    """target（bool，且 labels 处为 0）内像素填「同陆块内最近城块」。
    只取与目标像素同 lm id 的城块做种子（不同陆块的块再近也不许染过来）；
    该陆块无城块则不填（保持 0）。原地修改 labels，返回填充像素数。"""
    filled = 0
    for lid in np.unique(lm[target]):
        if lid == 0:
            continue
        t = target & (lm == lid)
        if not t.any():
            continue
        ys, xs = np.nonzero(t)
        y0, y1 = int(ys.min()), int(ys.max()) + 1
        x0, x1 = int(xs.min()), int(xs.max()) + 1
        sub_lab = labels[y0:y1, x0:x1]
        sub_t = t[y0:y1, x0:x1]
        sub_lm = lm[y0:y1, x0:x1]
        markers = (sub_lab > 0) & (sub_lm == lid)
        if not markers.any():
            continue
        _, inds = ndi.distance_transform_edt(~markers, return_indices=True)
        vals = sub_lab[inds[0], inds[1]]
        m = sub_t & (vals > 0)
        sub_lab[m] = vals[m]
        filled += int(m.sum())
    return filled


def enforce_single_landmass(labels, lm):
    """一城块一陆块收尾：每个 label 只保留其像素数最多的主陆块上的像素，
    其它陆块上的零散像素清 0 并按「同陆块最近城块」回填（无块可填则留 0）。
    返回 (清理 px, 回填 px)。"""
    m = labels > 0
    if not m.any():
        return 0, 0
    n_lm = int(lm.max()) + 1
    keys = labels[m].astype(np.int64) * n_lm + lm[m].astype(np.int64)
    ku, kc = np.unique(keys, return_counts=True)
    lab_u = ku // n_lm
    lm_u = ku % n_lm
    order = np.argsort(lab_u * np.int64(1 << 30) - kc, kind="stable")
    # 每 label 取计数最大的 lm（argsort 后同 label 首见即最大计数）
    seen = {}
    for i in order:
        l = int(lab_u[i])
        if l not in seen:
            seen[l] = int(lm_u[i])
    maj = np.zeros(int(labels.max()) + 1, dtype=lm.dtype)
    for l, lid in seen.items():
        maj[l] = lid
    bad = m & (maj[labels] != lm)
    n_bad = int(bad.sum())
    if not n_bad:
        return 0, 0
    labels[bad] = 0
    filled = edt_fill_within_landmass(labels, bad, lm)
    return n_bad, filled
