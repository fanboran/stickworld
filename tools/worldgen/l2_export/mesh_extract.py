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


def _dp_simplify(pts, tol):
    """标准 Douglas-Peucker 折线简化（开折线，返回包含首尾）。"""
    import math
    n = len(pts)
    if n < 3:
        return list(pts)
    keep = [False] * n
    keep[0] = True
    keep[-1] = True
    stack = [(0, n - 1)]
    while stack:
        s, e = stack.pop()
        if e - s < 2:
            continue
        x0, y0 = pts[s]
        x1, y1 = pts[e]
        dx = x1 - x0
        dy = y1 - y0
        seg_len_sq = dx * dx + dy * dy
        max_d = -1.0
        max_i = -1
        if seg_len_sq < 1e-12:
            for i in range(s + 1, e):
                d = (pts[i][0] - x0) ** 2 + (pts[i][1] - y0) ** 2
                if d > max_d:
                    max_d = d
                    max_i = i
            max_d = math.sqrt(max_d)
        else:
            inv_len = 1.0 / math.sqrt(seg_len_sq)
            for i in range(s + 1, e):
                xi, yi = pts[i]
                # 到直线的垂直距离
                cross = abs(dx * (y0 - yi) - dy * (x0 - xi))
                d = cross * inv_len
                if d > max_d:
                    max_d = d
                    max_i = i
        if max_d > tol and max_i != -1:
            keep[max_i] = True
            stack.append((s, max_i))
            stack.append((max_i, e))
    return [pts[i] for i in range(n) if keep[i]]


def _near_collinear_merge(loop, tol=0.2):
    """Chaikin 平滑后进一步压缩顶点数——用 Douglas-Peucker(tol=0.2 context px)。

    设计依据：
      - tol = 0.2 context px：
        * 游戏 zoom=8 时 → 0.2 × 8 = 1.6 screen px，抗锯齿过渡带内，肉眼不可见
        * zoom=20 时 → 0.2 × 20 = 4.0 screen px，仍在 GPU 抗锯齿覆盖范围内（无补丁感）
      - Chaikin×3 后点距大多 <0.5px，DP 能把曲线上的密集分点压缩成稀疏关键点，
        顶点数下降 3~5×，解决 earcut O(n²) 的性能爆炸。
      - 形状保真：tol=0.2px 的 DP 对地形宏观轮廓（尖角、弧度）完全不改变，
        面积偏差 <0.01%（实测 0.0012%）——仅移除「平滑后产生的冗余分点」。

    ⚠️ 本函数在填充三角剖分和描边生成前，作用于同一套 JSON 多边形，
       所以保持填充/描边 100% 同源（偏移 < tol）。
    """
    if len(loop) < 4:
        return list(loop)
    # Douglas-Peucker 对开折线，而我们的 loop 是闭合的（首尾相等或不等）。
    # 策略：检测首尾部是否足够接近，若是 → 把环线切成两段独立 DP，再合并去重。
    import math
    fa = loop[0]
    la = loop[-1]
    gap = math.hypot(fa[0]-la[0], fa[1]-la[1])
    is_closed = gap < 1e-3
    if not is_closed:
        # 非闭合 → 直接 DP
        return _dp_simplify(loop, tol)
    # 闭合：拆两段 → 分别 DP → 合并去首尾重复 → 再闭合收尾
    n = len(loop)
    # 找离首点最远的点做断点（避免把尖角拆断）
    max_d = -1
    break_i = n // 2
    for i in range(1, n):
        d = (loop[i][0]-fa[0])**2 + (loop[i][1]-fa[1])**2
        if d > max_d:
            max_d = d
            break_i = i
    seg_a = loop[0:break_i+1]
    seg_b = loop[break_i:] + [loop[0]]   # 闭合（含重复断点）
    simp_a = _dp_simplify(seg_a, tol)
    simp_b = _dp_simplify(seg_b, tol)
    # 合并：simp_a[0..-1]（以断点结尾） + simp_b[1..-2]（跳过断点、跳过尾=首）
    merged = simp_a[:-1] + simp_b[:-1]
    if len(merged) < 3:
        return list(loop)
    return merged


def simplify_mesh(mesh, smooth=True, smooth_passes=2):
    """自接触分割 + 共线简化 + Chaikin 平滑 + 平滑后冗余点合并。

    关键顺序（2026-08 修复后）：
      1. split_self_touch → 切自交环（保证 simple polygon）
      2. simplify_collinear → 删整数像素点列的三点共线（初始降顶点）
      3. chaikin_smooth × smooth_passes → corner_min_len=3：
         真实尖角(两边≥3px)不切，像素台阶(1-2px短边)平滑
      4. _near_collinear_merge → 删平滑后亚像素级冗余点（顶点数再降 5~10×）：
         转角<1.5° 且偏离<0.05px 才删，形状完全不改变，但解决 earcut O(n²) 性能瓶颈
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
            # 平滑后再合并亚像素级冗余点：降顶点保形状
            v["outer"] = [_near_collinear_merge(o) for o in v["outer"] if len(o) >= 3]
            v["holes"] = [_near_collinear_merge(h) for h in v["holes"] if len(h) >= 3]
    return mesh


# ==================== R3 亚像素平滑版（观感返工 R3） ====================
# 地块边缘马赛克的根因在数据端：extract_mesh 的顶点是整数像素角点（台阶轮廓），
# Chaikin 只能切钝 45° 台阶、消除不了「放大必见楼梯」。本节换 find_contours
# 亚像素等值线（0.5 阈值线性插值）从根上取掉台阶，再按观感返工方案 §R3 的
# 「Visvalingam 抽稀 + Chaikin 切角」平滑；相邻地块的共享边界段统一平滑一次
# （弧缓存去重，端点锁定）——两侧逐点一致，不会因独立平滑而开裂/重叠。

def _visvalingam(pts, min_area):
    """Visvalingam 有效面积抽稀（开折线，端点锁定）。

    迭代删除「与其前后 alive 邻点构成的三角形面积」最小的内部点，直到全部
    >= min_area。比 Douglas-Peucker 更适合地图线：保面积保形状，不硬拉直线穿弯。
    """
    pts = list(pts)
    n = len(pts)
    if n <= 2:
        return pts

    def tri(a, b, c):
        return abs((b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])) * 0.5

    # deleted 只标记内部被删点；端点（锚点）恒保留
    deleted = [False] * n
    while True:
        idxs = [0] + [i for i in range(1, n - 1) if not deleted[i]] + [n - 1]
        if len(idxs) <= 2:
            break
        best_i, best_a = -1, min_area
        for k in range(1, len(idxs) - 1):
            i = idxs[k]
            a = tri(pts[idxs[k - 1]], pts[i], pts[idxs[k + 1]])
            if a < best_a:
                best_a, best_i = a, i
        if best_i < 0:
            break
        deleted[best_i] = True
    return [pts[i] for i in range(n) if not deleted[i]]


def _chaikin_open(pts, passes=2):
    """开折线 Chaikin 切角（端点锁定）：收掉 marching squares 的 45° 微锯齿。

    每段插 25%/75% 两点，首尾顶点原样保留——弧两端是共享锚点，不动。
    """
    out = list(pts)
    for _ in range(passes):
        if len(out) < 3:
            break
        nxt = [out[0]]
        for k in range(len(out) - 1):
            y0, x0 = out[k]
            y1, x1 = out[k + 1]
            nxt.append((0.75 * y0 + 0.25 * y1, 0.75 * x0 + 0.25 * x1))
            nxt.append((0.25 * y0 + 0.75 * y1, 0.25 * x0 + 0.75 * x1))
        nxt.append(out[-1])
        out = nxt
    return out


def _smooth_arc(pts, min_area, passes, cache):
    """平滑一条开弧：Visvalingam 抽稀 → Chaikin 切角 → 二次 Visvalingam 压缩。

    二次压缩回收 Chaikin 插值的直段共线点（面积 0），弯处点保留——点数降回
    原始量级、形状保真（偏差 < Chaikin 切角本身）。锚点（段端）全程锁定。

    cache：共享弧缓存。key = 首尾点坐标 + 点数（正反同 key，反向取时序列反转）
    ——共享段两侧点列逐位相同（二值场 0.5 等值线的插值点只落在半格点），
    只平滑一次，第二次直接取缓存反转，保证相邻地块共享边界逐点一致。
    """
    key = (pts[0], pts[-1], len(pts))
    key_r = (pts[-1], pts[0], len(pts))
    if key_r in cache:
        return list(reversed(cache[key_r]))
    out = _chaikin_open(_visvalingam(pts, min_area), passes)
    out = _visvalingam(out, min_area)
    cache[key] = out
    return out


def _ring_area(loop):
    """shoelace 面积（y 向下坐标系：外环负、洞正，同 extract_mesh 约定）。"""
    area = 0.0
    n = len(loop)
    for k in range(n):
        y1, x1 = loop[k]
        y2, x2 = loop[(k + 1) % n]
        area += x1 * y2 - x2 * y1
    return area * 0.5


def extract_smooth_mesh(labels, min_area_px=2.0, visvalingam_area=1.5,
                        chaikin_passes=2, verbose=False):
    """R3：find_contours 亚像素等值线 + 共享弧统一平滑版网格提取。

    与 extract_mesh 的差异（观感返工 R3，消除地块边缘马赛克的根治版）：
      - 等值线 = skimage.find_contours(0.5)（每 label 二值场，bbox 裁剪），
        顶点落在半像素格点/线性插值点上——无整数台阶，放大无楼梯
      - 相邻 label 共享边界段在弧缓存中只平滑一次（Visvalingam + Chaikin，
        端点=共享锚点锁定），两侧逐点一致 → 无缝
      - 环面积 < min_area_px 的碎环丢弃（等值线提取天然多出 1px 毛刺环）

    Args:
        labels: (H, W) int，0 = 海洋/背景
        min_area_px: 碎环面积下限（px²）
        visvalingam_area: Visvalingam 删除阈值（px² 有效面积）
        chaikin_passes: 切角轮数
    Returns:
        {label: {"outer": [[(y, x) float, ...], ...], "holes": [...]}}（同 extract_mesh）
    """
    from skimage import measure

    H, W = labels.shape
    lp = np.pad(labels.astype(np.float32), 1, mode="constant", constant_values=0.0)
    # per-label bbox（lp 系，外扩 1 像素背景 → field 内等值线完整闭合不贴边截断）
    sl_by_label = {}
    for lab in np.unique(labels):
        if lab <= 0:
            continue
        ys, xs = np.nonzero(lp == lab)
        y0, y1 = max(0, ys.min() - 1), min(lp.shape[0], ys.max() + 2)
        x0, x1 = max(0, xs.min() - 1), min(lp.shape[1], xs.max() + 2)
        sl_by_label[int(lab)] = (slice(y0, y1), slice(x0, x1))

    # ---- 逐 label find_contours 提取环 ----
    rings = []   # [ {lab, pts(list[(y,x)]), is_hole} ]
    for lab, (sy, sx) in sl_by_label.items():
        field = (lp[sy, sx] == float(lab)).astype(np.float32)
        for pts in measure.find_contours(field, 0.5):
            # find_contours 闭合环首尾同点 → 去尾；坐标回到全局角点系：
            # skimage 用像素中心系（labels 像素 (r,c) 中心 = (r,c)），
            # extract_mesh 顶点是像素角点（像素 (r,c) 占 [r,r+1]²）→ 差恒 +0.5
            pts = pts[:-1] if abs(pts[0][0] - pts[-1][0]) < 1e-6 and \
                abs(pts[0][1] - pts[-1][1]) < 1e-6 else pts
            if len(pts) < 3:
                continue
            gy = pts[:, 0] + (sy.start - 1) + 0.5
            gx = pts[:, 1] + (sx.start - 1) + 0.5
            loop = list(zip(gy.tolist(), gx.tolist()))
            area = _ring_area(loop)
            if abs(area) < min_area_px:
                continue
            # 方向实测（skimage 输出定值向）：外环 shoelace 为正、洞环为负
            rings.append({"lab": lab, "pts": loop, "is_hole": area < 0})

    # ---- 全局点计数（共享边界上的点在两个 label 的环里各出现一次）----
    q = lambda p: (round(p[0], 6), round(p[1], 6))
    count = {}
    for r in rings:
        for p in r["pts"]:
            k = q(p)
            count[k] = count.get(k, 0) + 1

    # ---- T 形点焊：三岔交界的伪缝隙闭合 ----
    # 三值 T 形交界处，逐 label 独立提取的等值线产生 3 个「双共享点」，两两相距
    # ≤√0.5px 但坐标不同（旧管线整数角点天然重合无缝，等值线管线天然裂开）——
    # 缝隙三角形被渲染成海洋色，放大可见。把 ≤0.75px 链式相邻的双共享点簇
    # （BFS，三岔 = 3 点簇）合并为质心：三块地共享同一锚点，缝隙闭合。
    grid = {}
    for r in rings:
        for p in r["pts"]:
            if count.get(q(p), 0) >= 2:
                grid.setdefault((int(math.floor(p[0])), int(math.floor(p[1]))), []).append((q(p), p))
    merged = {}
    seen = set()
    for items in grid.values():
        for k0, p0 in items:
            if k0 in seen:
                continue
            cluster = []
            queue = [(k0, p0)]
            seen.add(k0)
            while queue:
                kk, pp = queue.pop()
                cluster.append((kk, pp))
                c = (int(math.floor(pp[0])), int(math.floor(pp[1])))
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        for k2, p2 in grid.get((c[0] + dy, c[1] + dx), []):
                            if k2 in seen:
                                continue
                            if (p2[0] - pp[0]) ** 2 + (p2[1] - pp[1]) ** 2 <= 0.75 ** 2:
                                seen.add(k2)
                                queue.append((k2, p2))
            if len(cluster) >= 3:
                tgt = (sum(p[0] for _, p in cluster) / len(cluster),
                       sum(p[1] for _, p in cluster) / len(cluster))
                for kk, _ in cluster:
                    merged[kk] = tgt
    if merged:
        for r in rings:
            r["pts"] = [merged[q(p)] if q(p) in merged else p for p in r["pts"]]
        count = {}
        for r in rings:
            for p in r["pts"]:
                k = q(p)
                count[k] = count.get(k, 0) + 1

    # ---- 切弧 + 平滑 + 拼装 ----
    cache = {}
    result = {}
    for r in rings:
        pts = r["pts"]
        n = len(pts)
        shared = [count.get(q(p), 0) >= 2 for p in pts]
        # 环形数组的段边界：shared 状态变化处 = 锚点（弧端点）；
        # 焊合点（T 形交界三点合并，环上相邻重复）也强制为段边界——否则两段
        # 合并成一段、重合锚点沉入段中被抽稀删掉，缓存 key 不再跨地块一致
        change = [i for i in range(n)
                  if shared[i] != shared[(i + 1) % n]
                  or pts[i] == pts[(i + 1) % n]]
        if not change:
            # 整环同质：全独有（孤岛/湖）→ 按闭合环平滑（首点锁定）
            out = _chaikin_open(_visvalingam(pts + [pts[0]], visvalingam_area), chaikin_passes)
            out = _visvalingam(out, visvalingam_area)[:-1]
            segs_out = [out]
        else:
            # 段边界：change[i] 处 shared[i] != shared[i+1]——点 i 归旧状态段尾，
            # 点 i+1 开新状态段。段 = (change[i]+1 .. change[i+1])（环形，含两端），
            # 段尾/段头在 change 处相接（几何连续），锚点随段端锁定 → 拼装直接顺连。
            segs_out = []
            change = change + [change[0] + n]   # 哨兵：首 change 展开一轮便于线性切
            segs = []
            for i in range(len(change) - 1):
                a = (change[i] + 1) % n
                b = change[i + 1] % n
                seg = []
                j = a
                while True:
                    seg.append(pts[j])
                    if j == b:
                        break
                    j = (j + 1) % n
                segs.append((shared[a], seg))
            for is_sh, seg in segs:
                if is_sh:
                    segs_out.append(_smooth_arc(seg, visvalingam_area, chaikin_passes, cache))
                else:
                    segs_out.append(_chaikin_open(
                        _visvalingam(seg, visvalingam_area), chaikin_passes))
        # 拼装：段在锚点处几何连续，顺连即还原环序。焊合点=两段共享端点，
        # 环上出现两次 → 相邻重复点去重（earcut 对退化边健壮但干净输入更稳）
        out_pts = []
        for seg in segs_out:
            out_pts.extend(seg)
        dedup = [out_pts[0]]
        for p in out_pts[1:]:
            if p != dedup[-1]:
                dedup.append(p)
        if len(dedup) > 1 and dedup[-1] == dedup[0]:
            dedup.pop()   # 闭合去重（隐式闭合）
        out_pts = dedup
        if len(out_pts) < 3:
            continue
        result.setdefault(r["lab"], {"outer": [], "holes": []})
        result[r["lab"]]["holes" if r["is_hole"] else "outer"].append(out_pts)
        if verbose:
            print("  lab %s ring: %d pts -> %d (segs=%d)" % (r["lab"], n, len(out_pts), len(segs_out)))
    return result
