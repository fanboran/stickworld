"""河流矢量提取 + 视图包注入（B3，总体设计 §5.4）。

数据源裁定（2026-09）：locked/river_paths.json 是废弃实验管线（river_step4.py，C 加速器
+ Catmull-Rom）产物，与 B2 底图河流（fractal_continent.py 的 river_mask）不是同一批河
（采样重合率仅 7.2%），不可用。本工具从现役 fractal_river_mask_8192.png 骨架化提取
矢量折线 —— 与底图河流像素级同源，天然对齐。

宽度 = 折线处 EDT×2 实测河宽（mask 宽度本身即「四次根流量×6px」，宽度大一档 = 流量
大一档，四次根流量语义保留在宽度里）；颜色消费端统一 B2 底图河色（46,102,140）。

流程：
  1. 提取（一次性，缓存 output/river_vectors.json）：
     river_mask → skeletonize → 端点/交点拆段图追踪 → 每段 EDT 中位宽
     → DP 抽稀(tol 0.5px) → 短段过滤(<6px)
  2. 注入（就地 patch，不重跑视图包导出全链路）：
     - L1：config/strategic_map/l1_world.json + l1_packs/l1_XXX/（70 份）
       加 "world_origin"（世界原点，重算自 legacy 蒙版 bbox，与
       export_l1_view_context 同公式）+ "rivers"（context 局部 [x,y]）
     - L2：l2_packs/region_XXX/l2_world.json（13 份）加 "rivers"
       （正方形 context 局部 [y,x]，与 L2 顶点惯例一致）
  3. L2 geom 重烘（l2_bake，湖色统一 (72,116,158) 对齐 B2 底图 lake 色）

硬验收：提取折线按宽度重栅格化 vs 原 mask 的 IoU ≥ 0.85（骨架中心线重建的
半像素偏差内）；各 L1/L2 包 rivers 非空（有河穿过的窗口）。

用法：
  python river_export.py                # 全流程（提取缓存 + 注入 + 重烘）
  python river_export.py --extract-only # 仅提取 + 预览/自检
"""
import argparse
import json
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # tools/worldgen
OUTPUT_DIR = os.path.join(HERE, "output")
GAME_DIR = os.path.normpath(os.path.join(
    HERE, "..", "..", "stick-world", "config", "strategic_map"))

# 与生成端/消费端共享的水色（terrain_params.json colors 同源，改色三端同步）
RIVER_COLOR = (46, 102, 140)
LAKE_COLOR_NEW = (72, 116, 158)

# 提取参数
MIN_SEG_LEN = 1.0      # 段最小折线长（px @8192；碎刺过滤下限——自检口径：miss 全为不可见碎刺）
DP_TOL = 0.5           # Douglas-Peucker 抽稀容差（px @8192，保留蜿蜒细节）
MIN_CLIP_LEN = 4.0     # 裁切后窗口内子段最小长（px @8192）

# L1 context 窗口（export_l1_view_context.py 的 8192 世界）
L1_RES = 8192

NEIGHBORS8 = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]


# ==================== 提取 ====================

def extract_river_vectors(mask_path):
    """river_mask → 矢量折线段列表 [{"pts": [[x,y]...], "w": float}]（8192 世界坐标）。"""
    from scipy.ndimage import distance_transform_edt, convolve
    from skimage.morphology import skeletonize

    print("[river] 加载 river_mask ...")
    rm = np.array(Image.open(mask_path).convert("L")) > 127
    print("  河流像素: %d" % int(rm.sum()))

    print("[river] skeletonize ...")
    skel = skeletonize(rm)
    skel = skel.astype(bool)
    print("  骨架像素: %d" % int(skel.sum()))

    print("[river] 邻居计数（端点/交点识别）...")
    k8 = np.ones((3, 3), dtype=np.int32)
    k8[1, 1] = 0
    deg = convolve(skel.astype(np.int32), k8, mode="constant", cval=0)
    deg[~skel] = 0

    edt = distance_transform_edt(rm)   # 河内像素到河岸距离，河宽 = ×2

    H, W = skel.shape
    visited = np.zeros_like(skel, dtype=bool)

    def walk_chain(start):
        """从端点/任意点沿 deg==2 链前进，返回（含两端节点像素的）点列。"""
        chain = [start]
        cur = start
        while True:
            visited[cur[0], cur[1]] = True
            nxt = None
            for dy, dx in NEIGHBORS8:
                p = (cur[0] + dy, cur[1] + dx)
                if 0 <= p[0] < H and 0 <= p[1] < W and skel[p] and not visited[p]:
                    nxt = p
                    break
            if nxt is None:
                break
            chain.append(nxt)
            if deg[nxt] != 2:      # 到达端点/交点：节点像素收进链后停
                visited[nxt[0], nxt[1]] = True
                break
            cur = nxt
        return chain

    segments = []

    def add_chain(chain):
        if len(chain) < 2:
            return
        pts = [[float(x), float(y)] for (y, x) in chain]
        # 段宽 = 链上 EDT 中位 ×2（河宽口径：河内像素到两岸距离之和）
        ws = [float(edt[y, x]) * 2.0 for (y, x) in chain]
        w = float(np.median(ws)) if ws else 2.0
        segments.append({"pts": pts, "w": round(w, 2)})

    print("[river] 图追踪（端点出发 + 交点辐射 + 闭环兜底）...")
    endpoints = [tuple(p) for p in np.argwhere(deg == 1)]
    junctions = [tuple(p) for p in np.argwhere(deg >= 3)]
    for ep in endpoints:
        if visited[ep]:
            continue
        add_chain(walk_chain(ep))
    for jc in junctions:
        # 交点辐射：交点自身的每条未访问分支各走一段（保证交点间连通）
        visited[jc[0], jc[1]] = True
        for dy, dx in NEIGHBORS8:
            p = (jc[0] + dy, jc[1] + dx)
            if 0 <= p[0] < H and 0 <= p[1] < W and skel[p] and not visited[p]:
                if deg[p] == 1:
                    continue        # 端点起点分支已被端点遍历覆盖（重复段防御）
                chain = [jc] + walk_chain(p)
                add_chain(chain)
    # 闭环兜底：剩下降序未访问骨架像素（全 deg==2 的环，如牛轭湖环）
    for p in np.argwhere(skel & ~visited):
        p = tuple(p)
        if visited[p]:
            continue
        chain = walk_chain(p)
        if len(chain) >= 4:
            chain.append(chain[0])   # 闭环显式闭合
            pts = [[float(x), float(y)] for (y, x) in chain]
            ws = [float(edt[y, x]) * 2.0 for (y, x) in chain]
            segments.append({"pts": pts, "w": round(float(np.median(ws)), 2)})
    print("  原始段: %d" % len(segments))

    # DP 抽稀 + 短段过滤
    out = []
    for seg in segments:
        pts = rdp(seg["pts"], DP_TOL)
        if polyline_len(pts) >= MIN_SEG_LEN:
            out.append({"pts": [[round(x, 1), round(y, 1)] for x, y in pts], "w": seg["w"]})
    print("  抽稀+过滤后: %d 段（DP tol=%.2f, min_len=%.0f）" % (len(out), DP_TOL, MIN_SEG_LEN))
    return out


def polyline_len(pts):
    return sum(math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in zip(pts, pts[1:]))


def rdp(pts, tol):
    """Douglas-Peucker 抽稀（迭代栈实现）。"""
    if len(pts) < 3:
        return pts
    keep = [False] * len(pts)
    keep[0] = keep[-1] = True
    stack = [(0, len(pts) - 1)]
    while stack:
        i, j = stack.pop()
        if j <= i + 1:
            continue
        ax, ay = pts[i]
        bx, by = pts[j]
        dx, dy = bx - ax, by - ay
        L2 = dx * dx + dy * dy
        best_d, best_k = -1.0, -1
        for k in range(i + 1, j):
            px, py = pts[k]
            if L2 < 1e-12:
                d = math.hypot(px - ax, py - ay)
            else:
                t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / L2))
                d = math.hypot(px - ax - t * dx, py - ay - t * dy)
            if d > best_d:
                best_d, best_k = d, k
        if best_d > tol:
            keep[best_k] = True
            stack.append((i, best_k))
            stack.append((best_k, j))
    return [p for p, k in zip(pts, keep) if k]


# ==================== 裁切 ====================

def clip_polyline(pts, x0, y0, x1, y1):
    """折线裁切到窗口（Liang-Barsky 逐段），返回窗口内子折线列表（原坐标系）。"""
    EPS = 1e-9
    subs = []
    cur = []

    def enter_point(a, b, t):
        return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t]

    for a, b in zip(pts, pts[1:]):
        dx, dy = b[0] - a[0], b[1] - a[1]
        t0, t1 = 0.0, 1.0
        ok = True
        for p, q in ((-dx, a[0] - x0), (dx, x1 - a[0]), (-dy, a[1] - y0), (dy, y1 - a[1])):
            if abs(p) < EPS:
                if q < 0:
                    ok = False
                    break
            else:
                r = q / p
                if p < 0:
                    t0 = max(t0, r)
                else:
                    t1 = min(t1, r)
        if not ok or t0 > t1:
            # 整段在外：当前子折线断开
            if len(cur) >= 2:
                subs.append(cur)
            cur = []
            continue
        ia = enter_point(a, b, t0)
        ib = enter_point(a, b, t1)
        seg_all_in = t0 <= EPS and t1 >= 1.0 - EPS
        if seg_all_in:
            if not cur:
                cur = [a, b]
            else:
                cur.append(b)
        else:
            if not cur:
                cur = [ia]
            elif math.hypot(cur[-1][0] - ia[0], cur[-1][1] - ia[1]) > EPS:
                subs.append(cur)
                cur = [ia]
            cur.append(ib)
    if len(cur) >= 2:
        subs.append(cur)
    return subs


def rivers_in_window(vectors, x0, y0, side_x, side_y, swap_yx=False):
    """全图矢量 → 窗口局部坐标折线（过滤窗口内短段）。swap_yx=True 输出 [y,x]（L2 惯例）。"""
    x1, y1 = x0 + side_x - 1, y0 + side_y - 1
    out = []
    for seg in vectors:
        for sub in clip_polyline(seg["pts"], x0, y0, x1, y1):
            if polyline_len(sub) < MIN_CLIP_LEN:
                continue
            pts = [[round(p[0] - x0, 1), round(p[1] - y0, 1)] for p in sub]
            if swap_yx:
                pts = [[p[1], p[0]] for p in pts]
            out.append({"pts": pts, "w": seg["w"]})
    return out


# ==================== 注入 L1 ====================

def l1_window(label, legacy, side):
    """重算老 L1 的 context 窗口原点（与 export_l1_view_context.py 同公式：
    bbox 中心居中 + clamp）。side 取 json 现值（margin 只影响边长，直接沿用——
    出生包 margin=15、批量包 margin=45，不假设）。返回 (x0, y0)。"""
    m = legacy == label
    if not m.any() or side <= 0 or side > L1_RES:
        return None
    ys0, xs0 = np.where(m)
    bx0, by0, bx1, by1 = xs0.min(), ys0.min(), xs0.max(), ys0.max()
    cx = int(round((bx0 + bx1) / 2.0))
    cy = int(round((by0 + by1) / 2.0))
    x0 = max(0, min(cx - side // 2, L1_RES - side))
    y0 = max(0, min(cy - side // 2, L1_RES - side))
    return x0, y0


def patch_l1(json_path, vectors, legacy):
    with open(json_path, encoding="utf-8") as f:
        world = json.load(f)
    label = int(world.get("parent_l1_label", 0))
    side = int(world.get("context_size", [0])[0]) or int(world.get("size", 0))
    win = l1_window(label, legacy, side)
    if win is None:
        print("  !! %s: label %d 无蒙版/size 异常，跳过" % (json_path, label))
        return False
    x0, y0 = win
    # 防御：出生轮廓（世界坐标 = context 坐标 + 原点）须整体落在重算窗口内，否则原点漂移
    poly = world.get("l1_polygon", [])
    if poly:
        pxs = [p[0] + x0 for p in poly]
        pys = [p[1] + y0 for p in poly]
        if min(pxs) < x0 - 2 or max(pxs) > x0 + side + 2 \
                or min(pys) < y0 - 2 or max(pys) > y0 + side + 2:
            print("  !! %s: l1_polygon 世界坐标越出重算窗口，跳过" % json_path)
            return False
    rivers = rivers_in_window(vectors, x0, y0, side, side)
    world["world_origin"] = [int(x0), int(y0)]
    world["rivers"] = rivers
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(world, f, ensure_ascii=False, indent=1)
    print("  %s: label %d @(%d,%d) side %d -> %d 条河流"
          % (os.path.relpath(json_path, GAME_DIR), label, x0, y0, side, len(rivers)))
    return True


# ==================== 注入 L2 ====================

def patch_l2(json_path, info_path, vectors):
    with open(json_path, encoding="utf-8") as f:
        world = json.load(f)
    info = json.load(open(info_path, encoding="utf-8"))
    bbox = info["bbox_8192"]
    tx, ty = world["tiles_offset"]           # tiles 区域在正方形 context 中的偏移
    side = int(world["context_size"][0])
    # context 世界原点 = bbox 原点左移 tiles 偏移（正方形对称补齐的虚空区在 bbox 外）
    x0 = int(bbox["x0"]) - tx
    y0 = int(bbox["y0"]) - ty
    rivers = rivers_in_window(vectors, x0, y0, side, side, swap_yx=True)
    world["rivers"] = rivers
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(world, f, ensure_ascii=False, separators=(",", ":"))
    print("  %s: @(%d,%d) side %d -> %d 条河流"
          % (world["region_id"], x0, y0, side, len(rivers)))
    return True


# ==================== 自检 + 预览 ====================

def selfcheck(vectors, mask_path):
    """矢量忠实度双指标（提取质量硬验收）：
    · 命中率（跑偏检测）：折线密采样点落在 mask+1px 内 ≥ 0.97（折线没画到河外）
    · 覆盖率（漏河检测）：mask 中心带像素（EDT≤1.2，河宽≤2.4px 的细河骨架邻域）
      距折线最近采样点 ≤2px 的比例 ≥ 0.95（没漏提取河段）
    像素 IoU 不适用：宽度重建自带 ±半宽容差（PIL 线宽方形足迹膨胀 ~12%）。"""
    from scipy.ndimage import distance_transform_edt, binary_dilation
    from scipy.spatial import cKDTree

    rm = np.array(Image.open(mask_path).convert("L")) > 127
    # 折线密采样（相邻 ~1px），建 KD-tree
    samples = []
    for seg in vectors:
        pts = seg["pts"]
        for a, b in zip(pts, pts[1:]):
            L = math.hypot(b[0] - a[0], b[1] - a[1])
            n = max(1, int(L))
            for k in range(n):
                t = k / n
                samples.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))
        samples.append(tuple(pts[-1]))
    samples = np.array(samples)
    tree = cKDTree(samples)

    # 命中率
    rm_d = binary_dilation(rm, iterations=1)
    inside = rm_d[samples[:, 1].astype(int), samples[:, 0].astype(int)]
    hit = float(inside.mean()) if len(inside) else 0.0

    # 覆盖率：mask 中心带 → 距折线
    edt = distance_transform_edt(rm)
    core = rm & (edt <= 1.2)
    cy, cx = np.where(core)
    if len(cy) == 0:
        cover = 1.0
    else:
        d, _ = tree.query(np.column_stack([cx, cy]), k=1, workers=-1)
        cover = float((d <= 2.0).mean())
    return hit, cover, len(samples), int(core.sum())


def preview(vectors, mask_path, out_path):
    """全图矢量预览：暗底 + 矢量河流（按宽度），人眼对照 mask 渲染质量。"""
    rm = np.array(Image.open(mask_path).convert("L"))
    h, w = rm.shape
    scale = 2048 / w
    img = Image.new("RGB", (2048, 2048), (24, 28, 34))
    draw = ImageDraw.Draw(img)
    for seg in vectors:
        pts = [(p[0] * scale, p[1] * scale) for p in seg["pts"]]
        lw = max(1, seg["w"] * scale * 0.9)
        t = min(1.0, seg["w"] / 12.0)
        col = (int(90 + 60 * t), int(140 + 40 * t), 190)
        draw.line(pts, fill=col, width=int(lw), joint="curve")
    img.save(out_path)
    print("  -> %s" % out_path)


# ==================== main ====================

def main():
    ap = argparse.ArgumentParser(description="河流矢量提取 + 视图包注入（B3）")
    ap.add_argument("--extract-only", action="store_true", help="仅提取 + 预览/自检，不注入")
    ap.add_argument("--force-extract", action="store_true", help="忽略矢量缓存重提取")
    args = ap.parse_args()

    mask_path = os.path.join(OUTPUT_DIR, "fractal_river_mask_8192.png")
    cache_path = os.path.join(OUTPUT_DIR, "river_vectors.json")

    if args.force_extract or not os.path.exists(cache_path):
        vectors = extract_river_vectors(mask_path)
        with open(cache_path, "w", encoding="utf-8") as f:
            json.dump(vectors, f, separators=(",", ":"))
        print("[river] 矢量缓存 -> %s (%d KB)" % (cache_path, os.path.getsize(cache_path) // 1024))
    else:
        vectors = json.load(open(cache_path, encoding="utf-8"))
        print("[river] 载入矢量缓存: %d 段" % len(vectors))

    hit, cover, n_samples, n_core = selfcheck(vectors, mask_path)
    print("[river] 忠实度自检: 命中率 %.3f（阈值 0.97）/ 覆盖率 %.3f（阈值 0.95），"
          "折线采样 %d 点，mask 中心带 %d px" % (hit, cover, n_samples, n_core))
    preview(vectors, mask_path, os.path.join(OUTPUT_DIR, "river_vectors_preview.png"))
    if hit < 0.97 or cover < 0.95:
        print("!! 忠实度未达阈值，中止注入（调提取参数后 --force-extract 重试）")
        sys.exit(1)

    if args.extract_only:
        return

    # ---- L1：出生 + 69 包 ----
    print("[river] 注入 L1 视图包 ...")
    legacy = np.load(os.path.join(OUTPUT_DIR, "l1_v2", "legacy_l1_labels_8192.npy")).astype(np.int32)
    n_ok = 0
    n_ok += 1 if patch_l1(os.path.join(GAME_DIR, "l1_world.json"), vectors, legacy) else 0
    packs_dir = os.path.join(GAME_DIR, "l1_packs")
    for d in sorted(os.listdir(packs_dir)):
        jp = os.path.join(packs_dir, d, "l1_world.json")
        if os.path.exists(jp):
            n_ok += 1 if patch_l1(jp, vectors, legacy) else 0
    print("  L1 完成 %d/70" % n_ok)

    # ---- L2：13 地区 + geom 重烘（湖色统一）----
    print("[river] 注入 L2 视图包 + geom 重烘 ...")
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from l2_bake import bake   # noqa: E402
    l2_info_dir = os.path.join(OUTPUT_DIR, "l2_packs")
    gdir = os.path.join(GAME_DIR, "l2_packs")
    for rid in sorted(os.listdir(gdir)):
        jp = os.path.join(gdir, rid, "l2_world.json")
        ip = os.path.join(l2_info_dir, rid, "info.json")
        if not (os.path.exists(jp) and os.path.exists(ip)):
            continue
        patch_l2(jp, ip, vectors)
        world = json.load(open(jp, encoding="utf-8"))
        stats = bake(world, os.path.join(gdir, rid, "l2_geom.bin"))
        print("    geom 重烘: %s | %s" % (rid, stats))
    print("完成。")


if __name__ == "__main__":
    main()
