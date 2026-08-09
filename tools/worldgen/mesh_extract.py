"""共享顶点网格提取 —— 复现 P 社（Clausewitz 引擎）省份网格架构。

从标签图（索引图）提取每 label 的边界多边形，**相邻 label 共享同一角点坐标**：
- 顶点 = 像素角点（整数坐标），同一边界被相邻地块共用 -> 渲染绝对无缝
- 洞（C 形地块内海洋）自动成为独立环
- 追踪规则：有向段（label 在段左侧），角点处选"最小逆时针转角"的下一段

性能：段收集向量化（numpy）；环追踪 O(边界段数)（Python 循环，秒级）。
"""
import numpy as np
import math


def extract_mesh(labels):
    """从标签图提取共享顶点网格。

    Args:
        labels: (H, W) int32，0 = 海洋/背景

    Returns:
        {label: {"outer": [[(y, x), ...], ...], "holes": [[(y, x), ...], ...]}}
        坐标 = 像素角点（0..H, 0..W）
    """
    H, W = labels.shape
    lp = np.pad(labels, 1, mode="constant", constant_values=0)
    inner = lp[1:H + 1, 1:W + 1]  # (H,W) 真实像素

    # ---- 向量化段收集 ----
    # 每段 (label, y1, x1, y2, x2)，label 在段前进方向左侧
    diff_r = inner != lp[1:H + 1, 2:W + 2]
    diff_l = inner != lp[1:H + 1, 0:W]
    diff_d = inner != lp[2:H + 2, 1:W + 1]
    diff_u = inner != lp[0:H, 1:W + 1]
    valid = inner != 0

    def collect(mask, v1_off, v2_off):
        # mask: (H,W) 布尔（该方向邻不同）；角点 = 像素角点 + 偏移
        ys, xs = np.nonzero(mask & valid)
        if ys.size == 0:
            return np.zeros((0, 5), dtype=np.int64)
        labs = inner[ys, xs].astype(np.int64)
        y1 = ys + v1_off[0]
        x1 = xs + v1_off[1]
        y2 = ys + v2_off[0]
        x2 = xs + v2_off[1]
        return np.column_stack([labs, y1, x1, y2, x2])

    segs = np.concatenate([
        collect(diff_r, (1, 1), (0, 1)),    # 右邻：段 (r+1,c+1)->(r,c+1) 北向
        collect(diff_l, (0, 0), (1, 0)),    # 左邻：段 (r,c)->(r+1,c) 南向
        collect(diff_d, (1, 0), (1, 1)),    # 下邻：段 (r+1,c)->(r+1,c+1) 东向
        collect(diff_u, (0, 1), (0, 0)),    # 上邻：段 (r,c+1)->(r,c) 西向
    ], axis=0)

    # ---- 角点出向邻接（向量化分组）----
    # 按 (label, v1) 排序分组
    order = np.lexsort((segs[:, 4], segs[:, 3], segs[:, 2], segs[:, 1], segs[:, 0]))
    srt = segs[order]
    # 每组起始索引（按 label 分组）
    group_key = srt[:, 0]
    new_group = np.ones(len(srt), dtype=bool)
    if len(srt) > 1:
        new_group[1:] = group_key[1:] != group_key[:-1]
    group_start = np.nonzero(new_group)[0]
    group_end = np.append(group_start[1:], len(srt))
    # 方向角（y 向下）：下=90, 右=0, 上=270, 左=180
    dy = srt[:, 3] - srt[:, 1]   # y2 - y1
    dx = srt[:, 4] - srt[:, 2]   # x2 - x1
    theta = np.where(dy == 1, 90, np.where(dy == -1, 270,
                     np.where(dx == 1, 0, np.where(dx == -1, 180, -1))))

    # ---- 环追踪（Python 循环，O(段数)）----
    result = {}
    visited = set()
    for gi in range(len(group_start)):
        g0, g1 = group_start[gi], group_end[gi]
        lab = int(srt[g0, 0])
        seg_ids = list(range(g0, g1))
        if lab not in result:
            result[lab] = {"outer": [], "holes": []}
        # 角点 -> 出向段索引（O(1) 候选查找）
        by_start = {}
        for k in seg_ids:
            by_start.setdefault((int(srt[k, 1]), int(srt[k, 2])), []).append(k)
        for si in seg_ids:
            if si in visited:
                continue
            loop = []
            cur = si
            closed = False
            while True:
                visited.add(cur)
                y1, x1 = int(srt[cur, 1]), int(srt[cur, 2])
                y2, x2 = int(srt[cur, 3]), int(srt[cur, 4])
                loop.append((y1, x1))
                t_in = int(theta[cur])
                # 角点 (y2,x2) 的出向候选（同 label；排除回头段）
                # 规则：最左转（CCW 最大角，含 180° 锯齿舌掉头）——保持 label 在左的
                #       "左手沿墙"追踪，T 形/凹角/1px 锯齿不产生自交、不分裂环
                best = -1
                best_d = -1.0
                for k in by_start.get((y2, x2), []):
                    if k == cur or k in visited:
                        continue
                    if int(srt[k, 3]) == y1 and int(srt[k, 4]) == x1:
                        continue  # 回头段（走回刚来的角点）
                    d = (int(theta[k]) - t_in) % 360
                    if d > best_d:
                        best_d = d
                        best = k
                if best < 0:
                    break
                cur = best
                nv2 = (int(srt[cur, 3]), int(srt[cur, 4]))
                if nv2 == (loop[0][0], loop[0][1]):
                    visited.add(cur)
                    loop.append((int(srt[cur, 1]), int(srt[cur, 2])))
                    closed = True
                    break
            if closed and len(loop) >= 3:
                # 面积符号（屏幕 y 向下：外环负、洞正）
                area = 0.0
                n = len(loop)
                for k in range(n):
                    py1, px1 = loop[k]
                    py2, px2 = loop[(k + 1) % n]
                    area += px1 * py2 - px2 * py1
                area *= 0.5
                if area < 0:
                    result[lab]["outer"].append(loop)
                else:
                    # 洞环验证：质心 3x3 邻域多数"是本 label"= 假洞（边界自接触，
                    # 1px 细节分支重叠角点让追踪跨分支围住本 label 陆地）——丢弃，
                    # 外环本身完整覆盖该区域；环内是其他 label（海洋/湖泊/邻居）= 真洞保留。
                    cy = int(sum(p[0] for p in loop) / len(loop))
                    cx = int(sum(p[1] for p in loop) / len(loop))
                    sub = labels[max(0, cy - 1):cy + 2, max(0, cx - 1):cx + 2]
                    if sub.size and np.bincount(sub.ravel()).argmax() != lab:
                        result[lab]["holes"].append(loop)
    return result


def simplify_collinear(loop):
    """删除共线中间点（三点共线），保留转弯角点。

    只删线上冗余点：相邻地块共享的转弯角点不变 -> 无缝渲染保持；
    顶点数大幅下降（大环 earcut 剖分不再失败）。
    """
    out = []
    n = len(loop)
    for k in range(n):
        a = loop[(k - 1) % n]
        b = loop[k]
        c = loop[(k + 1) % n]
        cross = (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0])
        if cross != 0:
            out.append(b)
    return out


def split_self_touch(loop):
    """角点接触型自交分割：环中同一角点出现两次 -> 切成多个简单子环。

    追踪在 T 形/复杂角点处可能让环"触角"自接触（共享角点经过两次），
    earcut 无法剖分；在重复角点处分割成简单子环后即可正常剖分填充。
    """
    out = []
    cur = []
    seen = {}
    for p in loop:
        if p in seen:
            idx = seen[p]
            sub = cur[idx:] + [p]
            if len(sub) >= 4:
                out.append(sub)
            cur = cur[:idx]
            seen = {q: i for i, q in enumerate(cur)}
        else:
            seen[p] = len(cur)
            cur.append(p)
    if len(cur) >= 3:
        out.append(cur)
    return out


def chaikin_smooth(loop, corner_min_len=3.0):
    """Chaikin 曲线细分一次：平滑像素台阶，但保留真实直角角。

    每段插值 25%/75% 两点，直线台阶变圆滑折线；插值点在共享线段上 ->
    相邻地块同一段生成相同插值点，无缝保持。

    关键：原实现删除**所有**顶点（含真实长边直角角），把直角角切成 45° 斜边，
    放大后表现为"直角角落塌陷成三角形"（像 3D 建模删顶点）。这里改成：
    某顶点相邻两条边都足够长（>=corner_min_len）视为**真实角**，保留原顶点不切角；
    像素台阶（边长 1~2px 的小凸点）仍做 Chaikin 平滑。判定只依赖共享边长 ->
    相邻地块结论一致，无缝保持。
    """
    n = len(loop)
    if n < 3:
        return list(loop)
    keep = [False] * n
    for k in range(n):
        a = loop[(k - 1) % n]
        b = loop[k]
        c = loop[(k + 1) % n]
        len1 = math.hypot(b[0] - a[0], b[1] - a[1])
        len2 = math.hypot(c[0] - b[0], c[1] - b[1])
        if len1 >= corner_min_len and len2 >= corner_min_len:
            keep[k] = True
    out = []
    for k in range(n):
        if keep[k]:
            out.append(loop[k])  # 真实角：保留原顶点（不切角）
        else:
            y0, x0 = loop[k]
            y1, x1 = loop[(k + 1) % n]
            out.append((0.75 * y0 + 0.25 * y1, 0.75 * x0 + 0.25 * x1))
            out.append((0.25 * y0 + 0.75 * y1, 0.25 * x0 + 0.75 * x1))
    return out


def simplify_mesh(mesh, smooth=True, smooth_passes=2):
    """自接触分割 + 共线简化（原地修改外层 dict）。

    smooth=True 时对环做 smooth_passes 次 Chaikin 细分（放大边界圆滑，无缝保持）。
    多次细分：像素台阶变缓坡，描边毛边大幅减少。
    """
    for v in mesh.values():
        outer = []
        for o in v["outer"]:
            outer.extend(split_self_touch(o))
        v["outer"] = [simplify_collinear(o) for o in outer]
        holes = []
        for h in v["holes"]:
            holes.extend(split_self_touch(h))
        v["holes"] = [simplify_collinear(h) for h in holes]
        if smooth:
            for _ in range(smooth_passes):
                v["outer"] = [chaikin_smooth(o) for o in v["outer"]]
                v["holes"] = [chaikin_smooth(h) for h in v["holes"]]
    return mesh
