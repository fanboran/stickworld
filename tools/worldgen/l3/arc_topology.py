"""共享弧拓扑提取 + 政治矢量 mesh 导出（边界超分 S2/S3 生成端）。

背景（《世界地图边界质量-管线审计与超分方案.md》）：政治图边界的质量洼地在
「矢量↔栅格」往返——l3_city 城块多边形是旧整数角点管线各自独立平滑的产物
（实测 34433 条边仅 6% 能两侧配对），运行时政治色块又是一张 8192 ID 栅格
（NEAREST 采样，L2 近 1:1 视角马赛克全暴露）。本工具把边界的权威表示换成
**解析共享弧拓扑**：
  [S2] city_labels_8192.npy（1040 城块标签场，源头连续场）一次提取 → 弧图
       （每条弧恰属两个标签或贴海），Visvalingam+Chaikin 只作用于弧，三界交点
       焊合 → 水密多边形（接缝零裂缝零重叠，配对率 6% → 100%）
  [S3]political_mesh 导出：
       - L3 全图 fill（earcut 预剖分，顶点色 = 政权 lut code）+ 湖 + 三级界线
         （国界/地区界/自由城邦界，从弧两侧政权直接判定——mask 探针退役）
       - 13 份 L2 pack 注入 political_mesh（context 坐标裁剪展开）
       - l3_city.json 城块多边形换源（弧拼装展开，兼容旧格式）
  运行时保留「改 LUT 即全图换色零重烘」：顶点/弧只存 lut code（1..80/253/254），
  颜色全部运行时查 PoliticalLut。

标签场升 8192 的 S1（city_split 重跑换更高细节）不在本工具范围——本工具只换
「表示」，不改城块形状语义（弧来自现役 8192 标签场的 0.5 等值线，与渲染端
R3 管线同源同参）。

用法：
  python arc_topology.py                  # 干跑：提取+指标+预览，不写任何数据
  python arc_topology.py --write          # 落地：l3_city 换源 + political_mesh + L2 注入
  python arc_topology.py --smoke 13       # 只跑一个 region 的标签切片（快速自检）
"""
import argparse
import json
import os
import sys
import time

import numpy as np
from PIL import Image
from scipy import ndimage as ndi

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # tools/worldgen
sys.path.insert(0, os.path.join(HERE, "l2_export"))
import mesh_extract   # noqa: E402

GAME_DIR = os.path.normpath(os.path.join(HERE, "..", "..", "stick-world",
                                         "config", "strategic_map"))
OUT_DIR = os.path.join(HERE, "output")
GEN_PACKS_DIR = os.path.join(OUT_DIR, "l2_packs")   # 生成端 pack 元数据（info.json）
LABELS_PATH = os.path.join(OUT_DIR, "l1_v2", "city_labels_8192.npy")
REFINED_LABELS_PATH = os.path.join(OUT_DIR, "l1_v2", "refined_city_labels_8192.npy")

CODE_FREE_CITY = 253   # 与 PoliticalLut 同码表
CODE_LAKE = 254

# 界分类（arc_border）
BORDER_NONE = 0
BORDER_NATIONAL = 1
BORDER_REGION = 2
BORDER_FREE_CITY = 3


def load_tile_attrs():
    """l3_city.json：label -> (lut_code, region, state_id)。

    code：政权 lut_index 1..80；无归属/空 state_id → 253 自由城邦。
    """
    d = json.load(open(os.path.join(GAME_DIR, "l3_city.json"), encoding="utf-8"))
    states = d.get("states", {})
    code_of, region_of = {}, {}
    for t in d["tiles"]:
        lab = int(t["label"])
        sid = t.get("state_id") or ""
        info = states.get(sid, {}) if sid else {}
        code = int(info.get("lut_index", 0))
        if code <= 0:
            code = CODE_FREE_CITY
        code_of[lab] = code
        region_of[lab] = int(t.get("region", 0))
    return d, code_of, region_of


def classify_border(ca, cb, ra, rb):
    """弧两侧 (code, region) → 界类型。海岸（一侧 0）= 非界。"""
    if ca <= 0 or cb <= 0:
        return BORDER_NONE
    if (ca == CODE_FREE_CITY) != (cb == CODE_FREE_CITY):
        return BORDER_FREE_CITY
    if ca != cb:                       # 两侧均政权且不同
        return BORDER_NATIONAL
    return BORDER_REGION if ra != rb else BORDER_NONE


def ring_area(loop):
    """shoelace（[x,y] 系）绝对面积。"""
    a = 0.0
    n = len(loop)
    for k in range(n):
        x1, y1 = loop[k]
        x2, y2 = loop[(k + 1) % n]
        a += x1 * y2 - x2 * y1
    return abs(a) * 0.5


def expand_ring(refs, arcs_xy):
    """弧引用序列 → 展开顶点（闭合去重），refs 元素 = (arc_id, forward)。"""
    pts = []
    for aid, fw in refs:
        ap = arcs_xy[aid]
        pts.extend(ap if fw else [(y, x) for (x, y) in reversed(ap)])
    dedup = [pts[0]]
    for p in pts[1:]:
        if p != dedup[-1]:
            dedup.append(p)
    if len(dedup) > 1 and dedup[-1] == dedup[0]:
        dedup.pop()
    return dedup


def _clean_ring(ring):
    """相邻重复点去重 + 尾首重复去重（病态环第一步清洗）。"""
    out = []
    for p in ring:
        if not out or p != out[-1]:
            out.append(p)
    while len(out) > 1 and out[0] == out[-1]:
        out.pop()
    return out


def build_fill(tiles_geom, code_of, dy=0, dx=0, scale=1.0, sea_rect=None):
    """tiles 多边形 → earcut fill（verts/code/idx 平铺）。

    tiles_geom: [(outer, holes, label)]，顶点 (x, y)；dy/dx 平移；scale 缩放。
    sea_rect: (w, h) 海洋底矩形——排顶点数组最前（同 mesh 先画 = 垫底），
      code 0 → shader empty_color。运行时父节点 _draw 在 z=0、fill 层 z=-1，
      海洋必须在 fill mesh 内自带，否则被父绘海洋色整幅盖住（实测踩坑）。
    返回 (verts, codes, idx, n_washed)。

    ⚠️ 剖分前必须清洗环：实测 mapbox_earcut 对含重复点/自接触的环**静默丢三角形**
    （50 个连续重复点让面积丢一半）——病态环来自 find_contours 的对角接触伪影与
    T 形焊合。清洗路径 = 相邻重复去重 → shapely buffer(0) 拆自接触/自交 → 有效
    简单环集合逐环 earcut（shapely 输出环必干净，earcut 不再失败）。
    """
    import mapbox_earcut as earcut
    from shapely.geometry import Polygon as ShPolygon

    verts = []
    codes = []
    idx = []
    n_washed = 0
    if sea_rect:
        w, h = sea_rect
        verts.extend([(0.0, 0.0), (w, 0.0), (w, h), (0.0, h)])
        codes.extend([0, 0, 0, 0])
        idx.extend([0, 1, 2, 0, 2, 3])
    for outer, holes, lab in tiles_geom:
        tf = [(x * scale + dx, y * scale + dy) for (x, y) in outer]
        tf_holes = [[(x * scale + dx, y * scale + dy) for (x, y) in h]
                    for h in holes if len(h) >= 3]
        clean = _clean_ring(tf)
        clean_holes = [_clean_ring(h) for h in tf_holes]
        clean_holes = [h for h in clean_holes if len(h) >= 3]
        if len(clean) < 3:
            n_washed += 1
            continue
        try:
            poly = ShPolygon(clean, clean_holes)
            fixed = poly if poly.is_valid else poly.buffer(0)
        except Exception:
            fixed = None
        parts = []
        if fixed is not None and not fixed.is_empty:
            for g in getattr(fixed, "geoms", [fixed]):
                if g.geom_type == "Polygon" and g.area > 1e-6:
                    parts.append(g)
        if not parts:
            n_washed += 1
            continue
        if len(parts) > 1 or parts[0].area < poly.area * 0.995:
            n_washed += 1
        for g in parts:
            rings = [list(g.exterior.coords)] + \
                    [list(r.coords) for r in g.interiors]
            ring_pts = []
            ring_ends = []
            for r in rings:
                rr = [(p[0], p[1]) for p in r]
                if len(rr) < 3:
                    continue
                for p in rr:
                    ring_pts.append(p)
                ring_ends.append(len(ring_pts))
            if len(ring_pts) < 3:
                continue
            arr = np.array(ring_pts, dtype=np.float64)
            # mapbox_earcut 约定：ring_ends = 每环**结束**索引（含外环），uint32
            starts = np.array(ring_ends, dtype=np.uint32)
            tri = earcut.triangulate_float64(arr, starts)
            base = len(verts)
            for (x, y) in ring_pts:
                verts.append((x, y))
                codes.append(code_of.get(lab, 0))
            idx.extend(int(base + t) for t in tri)
    return verts, codes, idx, n_washed


def build_interblock_lakes(arcs, arcs_xy, labels, lake_mask):
    """城块间湖面同源化：湖岸弧按 0 侧组件串链成环（与城块弧严格同源零漂移）。

    旧方案湖面用 L2 pack 的 lakes 旧几何（与细化城块弧不同代），湖面与城块洞
    边界错位 → sea_rect 海洋底从缝隙漏出（湖缘一圈黑斑）。本函数以湖 mask
    组件（湖的真相源）为种子，在细化场上重建湖面：
      候选弧 = 一侧为 0 且 0 侧的场 0 组件 = 该湖的场 0 组件（弧上多点沿法向
      偏移采样判定；场 0 组件即城块洞——湖岸弧与城块 fill 共用同一批弧）
    串链闭环中包含种子的为湖面外环；不含种子的闭环为湖中岛（作洞，岛面由
    城块 fill 自带）。串链不闭合（病态）或湖连海（场 0 组件面积远超湖 mask
    组件，串链会卷进整条海岸线）→ 跳过/回退光栅描迹——同场 0.5 等值线 +
    同参平滑管线，与弧仅有平滑方向独立的亚像素差异。
    返回 [(outer, holes, 0)]（build_fill 消费形态，(x,y)@8192）。
    """
    zero = labels == 0
    cl, _ = ndi.label(zero)
    comp_sizes = np.bincount(cl.ravel())
    H, W = labels.shape

    def _zero_comp(aid):
        """弧的 0 侧场组件 id：弧上取样点的 3×3 邻域找最近水像素（弧即 0.5
        等值线，水侧必在 1px 邻域内——法向偏移采样在湖尖/窄水两侧都会落陆）。"""
        a = arcs_xy[aid]
        n = len(a)
        if n < 2:
            return 0
        for f in (0.5, 0.25, 0.75, 0.125, 0.875):
            if n >= 3:
                i = max(1, min(n - 2, int(n * f)))
                mx = (a[i - 1][0] + a[i + 1][0]) * 0.5
                my = (a[i - 1][1] + a[i + 1][1]) * 0.5
            else:
                mx = (a[0][0] + a[-1][0]) * 0.5
                my = (a[0][1] + a[-1][1]) * 0.5
            px = int(np.clip(round(mx), 1, W - 2))
            py = int(np.clip(round(my), 1, H - 2))
            best = 0
            bestd = 1e18
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    if zero[py + dy, px + dx]:
                        d2 = (px + dx - mx) ** 2 + (py + dy - my) ** 2
                        if d2 < bestd:
                            bestd = d2
                            best = int(cl[py + dy, px + dx])
            if best > 0:
                return best
        return 0

    comp_arcs = {}
    for aid in range(len(arcs_xy)):
        la, lb = arcs[aid]["sides"]
        if la > 0 and lb > 0:
            continue
        c = _zero_comp(aid)
        if c > 0:
            comp_arcs.setdefault(c, []).append(aid)

    def _chain(aids):
        """端点焊合串链（0.01px 格）→ (闭环列表, 开链列表)。"""
        end_map = {}
        for aid in aids:
            a = arcs_xy[aid]
            end_map.setdefault((round(a[0][0] * 100), round(a[0][1] * 100)),
                               []).append((aid, 0))
            end_map.setdefault((round(a[-1][0] * 100), round(a[-1][1] * 100)),
                               []).append((aid, 1))
        used = set()
        loops, opens = [], []
        for aid0 in aids:
            if aid0 in used:
                continue
            used.add(aid0)
            pts = list(arcs_xy[aid0])
            for at_head in (False, True):
                while True:
                    p = pts[0] if at_head else pts[-1]
                    key = (round(p[0] * 100), round(p[1] * 100))
                    nxt = None
                    for cand in end_map.get(key, []):
                        if cand[0] not in used:
                            nxt = cand
                            break
                    if nxt is None:
                        break
                    aid2, e2 = nxt
                    used.add(aid2)
                    ap = arcs_xy[aid2]
                    seg = (ap if e2 == 0 else ap[::-1])[1:]   # e2=0 弧首在接点
                    if at_head:
                        pts[:0] = seg
                    else:
                        pts.extend(seg)
            k0 = (round(pts[0][0] * 100), round(pts[0][1] * 100))
            k1 = (round(pts[-1][0] * 100), round(pts[-1][1] * 100))
            if k0 == k1 and len(pts) >= 3:
                loops.append(pts)
            elif len(pts) >= 2:
                opens.append(pts)
        return loops, opens

    def _trace_comp(cid):
        """回退：场 0 组件光栅描迹（同场 0.5 等值线 + 同参平滑管线）。"""
        ys, xs = np.where(cl == cid)
        gy0, gy1 = int(ys.min()), int(ys.max()) + 1
        gx0, gx1 = int(xs.min()), int(xs.max()) + 1
        sub = (cl[gy0:gy1, gx0:gx1] == cid).astype(np.int32)
        res = mesh_extract.extract_smooth_mesh(sub)
        info = res.get(1)
        if not info:
            return []
        out = []
        for oi, outer in enumerate(info["outer"]):
            holes = info["holes"] if oi == 0 else []
            out.append(([(p[1] + gx0, p[0] + gy0) for p in outer],
                        [[(p[1] + gx0, p[0] + gy0) for p in h] for h in holes],
                        0))
        return out

    from shapely.geometry import Polygon as ShPolygon, Point
    geom = []
    n_open = 0
    n_skip = 0
    n_seaconn = 0
    lc, n_lk = ndi.label(lake_mask > 0)
    # 湖 mask 组件 → 场 0 组件分组（连体湖共享同一场 0 组件，只串链一次）
    comp_seeds = {}   # cid -> [(seed, mask_area), ...]
    for lid in range(1, n_lk + 1):
        ys, xs = np.where(lc == lid)
        gy0, gy1 = int(ys.min()), int(ys.max()) + 1
        gx0, gx1 = int(xs.min()), int(xs.max()) + 1
        sub = lc[gy0:gy1, gx0:gx1] == lid
        d = ndi.distance_transform_edt(sub)
        k = int(d.argmax())
        seed = (float(gx0 + k % sub.shape[1]), float(gy0 + k // sub.shape[1]))
        cid = int(cl[int(seed[1]), int(seed[0])])
        if cid <= 0:
            n_skip += 1   # 湖被细化场 warp 吃成陆地 → 无湖面可画
            continue
        if comp_sizes[cid] > 3 * int(sub.sum()):
            n_seaconn += 1   # 湖连海（场 0 组件远大于湖）→ 政治场按海表达
            continue
        comp_seeds.setdefault(cid, []).append((seed, int(sub.sum())))
    # 残余内陆块状水域补种子：湖 mask 阈值下的中小湖泊（refine 开运算保留下来的
    # 厚水、不沾图边、无 mask 种子）——旧版旧几何把它们画成湖色，政治图保持
    # 一致观感；下限 40px（≈10px 直径，深放大下的最小可见水斑），上限 10 万 px
    #（再大是内陆海，按海色表达）
    RESID_MIN, RESID_MAX = 40, 100000
    border_ids = set(int(i) for i in np.unique(np.concatenate(
        [cl[0, :], cl[-1, :], cl[:, 0], cl[:, -1]])) if i > 0)
    n_resid = 0
    for cid in range(1, len(comp_sizes)):
        ca = int(comp_sizes[cid])
        if cid in comp_seeds or cid in border_ids or ca < RESID_MIN or ca > RESID_MAX:
            continue
        ys, xs = np.where(cl == cid)
        gy0, gy1 = int(ys.min()), int(ys.max()) + 1
        gx0, gx1 = int(xs.min()), int(xs.max()) + 1
        sub = cl[gy0:gy1, gx0:gx1] == cid
        d = ndi.distance_transform_edt(sub)
        k = int(d.argmax())
        seed = (float(gx0 + k % sub.shape[1]), float(gy0 + k // sub.shape[1]))
        comp_seeds[cid] = [(seed, ca)]
        n_resid += 1
    if n_resid:
        print("    残余内陆水域补种 %d 个（湖 mask 阈值下的中湖泊，%d..%d px）"
              % (n_resid, RESID_MIN, RESID_MAX))
    for cid, seeds in comp_seeds.items():
        loops, opens = _chain(comp_arcs.get(cid, []))
        n_open += len(opens)
        polys = []
        for lp in loops:
            try:
                poly = ShPolygon(_clean_ring(lp))
                if not poly.is_valid:
                    poly = poly.buffer(0)
            except Exception:
                poly = None
            if poly is not None and not poly.is_empty:
                polys.append((lp, poly))
        mains = []   # (loop, poly)：包含至少一个种子的环为湖面外环
        used_ids = set()
        for seed, _ma in seeds:
            for it in polys:
                if id(it[0]) in used_ids:
                    continue
                if it[1].contains(Point(seed)):
                    mains.append(it)
                    used_ids.add(id(it[0]))
                    break
        if not mains:
            geom.extend(_trace_comp(cid))
            continue
        for loop, _poly in mains:
            holes = [other for other, op in polys
                     if id(other) not in used_ids and _poly.contains(Point(other[0]))]
            geom.append((loop, holes, 0))   # 湖中岛作洞，岛面由城块 fill 自带

    # ── 盲端水 pocket（河口盲湾）补画 ──
    # 特征：opening(8) 后独立的厚水块（≤17px 的细水道把它与海隔开），但场 0
    # 组件=海（细水道仍连通，逃过 refine 的内陆水回填、也进不了上面的串链）。
    # 视觉上是从海伸进大陆的水道末端开阔部，旧版被旧湖几何盖成湖色。处理：
    # 以 pocket 为中心截取局部窗口（dilate 25px），窗口内的场 0 连通块=盲湾
    # 全域（海在窗口外），同参描迹成湖面。
    struct8 = np.ones((3, 3), dtype=bool)
    thick8 = ndi.binary_opening(zero, structure=struct8, iterations=8)
    tc8, tn8 = ndi.label(thick8)
    ts8 = np.bincount(tc8.ravel())
    n_pocket = 0
    for pid in range(1, tn8 + 1):
        pa = int(ts8[pid])
        if pa < 250 or pa > 100000:
            continue
        pys, pxs = np.where(tc8 == pid)
        if int(cl[pys[0], pxs[0]]) in comp_seeds:
            continue   # 内陆水域已按场 0 组件正常串链
        if pys.min() == 0 or pys.max() == H - 1 or pxs.min() == 0 or pxs.max() == W - 1:
            continue   # 沾图边 = 海体本身
        # EDT 最深点（bbox 窗口内）
        sub8 = tc8[pys.min():pys.max() + 1, pxs.min():pxs.max() + 1] == pid
        k8 = int(ndi.distance_transform_edt(sub8).argmax())
        seed = (float(pxs.min() + k8 % sub8.shape[1]),
                float(pys.min() + k8 // sub8.shape[1]))
        # 局部窗口内的场 0 连通块（窗口截断海侧连接）
        R = 25
        gx0, gx1 = int(max(0, seed[0] - R)), int(min(W, seed[0] + R + 1))
        gy0, gy1 = int(max(0, seed[1] - R)), int(min(H, seed[1] + R + 1))
        local = zero[gy0:gy1, gx0:gx1]
        lc2, _ = ndi.label(local)
        sid2 = int(lc2[int(seed[1]) - gy0, int(seed[0]) - gx0])
        if sid2 <= 0:
            continue
        pm = lc2 == sid2
        if int(pm.sum()) > 20000:
            continue   # 窗口内仍连着大水域 = 不是盲端
        subm = pm.astype(np.int32)
        res2 = mesh_extract.extract_smooth_mesh(subm)
        info2 = res2.get(1)
        if not info2:
            continue
        appended = False
        for oi, outer in enumerate(info2["outer"]):
            holes2 = info2["holes"] if oi == 0 else []
            geom.append(([(p[1] + gx0, p[0] + gy0) for p in outer],
                         [[(p[1] + gx0, p[0] + gy0) for p in h] for h in holes2],
                         0))
            appended = True
        if appended:
            n_pocket += 1
    if n_pocket:
        print("    盲端水 pocket 补画 %d 个（opening(8) 独立 + 局部窗口描迹）" % n_pocket)
    if n_open:
        print("    ⚠️ %d 条湖岸弧串链未闭合（该湖回退光栅描迹）" % n_open)
    if n_skip or n_seaconn:
        print("    湖组件跳过：%d 被细化场吃掉 / %d 连海按海表达"
              % (n_skip, n_seaconn))
    return geom


def build_hole_lakes(arcs_xy, ring_refs, city_data):
    """城块内湖：tiles 洞弧引用展开成闭合环（与城块弧同源，零漂移）。

    ring_refs 的 holes 元素 = [(arc_id, forward)]；返回 [(outer, label=0)] 形态
    （供 build_fill 消费，顶点 (x,y)@8192）。
    """
    lakes = []
    for lab, info in ring_refs.items():
        for refs in info["holes"]:
            ring = expand_ring(refs, arcs_xy)   # (x,y) 顶点（arcs_xy 已 xy 序）
            if len(ring) >= 3:
                lakes.append(ring)
    return lakes


def export_l2(world_path, tiles_geom_ctx, borders_ctx, code_of, ctx_size=None):
    """构造单份 L2 political_mesh 字段（context 坐标）。"""
    verts, codes, idx, _ = build_fill(
        tiles_geom_ctx, code_of,
        sea_rect=(ctx_size[0], ctx_size[1]) if ctx_size else None)
    return {
        "verts": [[round(x, 2), round(y, 2)] for (x, y) in verts],
        "code": codes,
        "idx": idx,
        "borders_national": [[[round(x, 2), round(y, 2)] for (x, y) in ln]
                             for ln in borders_ctx[BORDER_NATIONAL]],
        "borders_region": [[[round(x, 2), round(y, 2)] for (x, y) in ln]
                           for ln in borders_ctx[BORDER_REGION]],
        "borders_free": [[[round(x, 2), round(y, 2)] for (x, y) in ln]
                         for ln in borders_ctx[BORDER_FREE_CITY]],
    }


def main():
    ap = argparse.ArgumentParser(description="共享弧拓扑 + 政治矢量 mesh 导出（S2/S3）")
    ap.add_argument("--write", action="store_true",
                    help="写回 l3_city.json 换源 + 产 l3_political_mesh.json + 注入 13 份 L2")
    ap.add_argument("--labels", default=None,
                    help="城块标签场路径（缺省=细化场 refined_city_labels_8192.npy，"
                         "无则回退原始 watershed 场；S1 细化场是正典数据源）")
    ap.add_argument("--smoke", type=int, default=0, metavar="REGION",
                    help="只跑 region_NNN 的标签切片（快速自检，不写数据）")
    ap.add_argument("--no-preview", action="store_true", help="跳过预览图")
    args = ap.parse_args()

    t0 = time.time()
    labels_path = args.labels
    if labels_path is None:
        labels_path = REFINED_LABELS_PATH if os.path.exists(REFINED_LABELS_PATH) \
            else LABELS_PATH
    labels = np.load(labels_path)
    print("[1] 标签场 %s（%s）城块 %d 个"
          % (labels.shape, labels_path, int(labels.max())))

    if args.smoke:
        # 烟测：取 region 窗口的标签切片（对拍 with_arcs vs 原 extract_smooth_mesh）
        rid = "region_%03d" % args.smoke
        info = json.load(open(os.path.join(GEN_PACKS_DIR, rid, "info.json"),
                              encoding="utf-8"))
        world = json.load(open(os.path.join(GAME_DIR, "l2_packs", rid, "l2_world.json"),
                               encoding="utf-8"))
        bb = info["bbox_8192"]
        tx, ty = world["tiles_offset"]
        cw, ch = world["context_size"]
        ox, oy = int(bb["x0"]) - int(tx), int(bb["y0"]) - int(ty)
        sub = labels[oy:oy + ch, ox:ox + cw].copy()
        sub[sub == 0] = 0
        res_a, arcs, refs = mesh_extract.extract_smooth_mesh_with_arcs(sub)
        res_b = mesh_extract.extract_smooth_mesh(sub)
        same = True
        for lab in res_a:
            for slot in ("outer", "holes"):
                la = sorted(tuple(sorted(map(tuple, r))) for r in res_a[lab][slot])
                lb = sorted(tuple(sorted(map(tuple, r))) for r in res_b.get(lab, {}).get(slot, []))
                if la != lb:
                    same = False
        print("    smoke region_%03d: labels=%d arcs=%d 展开与原管线一致=%s"
              % (args.smoke, len(res_a), len(arcs), same))
        return

    print("[2] 弧拓扑提取（find_contours + 焊点 + 弧化平滑）...")
    result, arcs, ring_refs = mesh_extract.extract_smooth_mesh_with_arcs(labels)
    # 弧顶点转 (x, y)（本工具统一 xy 序；mesh_extract 内部是 (y, x)）
    arcs_xy = [[(float(x), float(y)) for (y, x) in a["pts"]] for a in arcs]
    print("    环 label 数 %d，弧 %d 条，弧顶点 %d，耗时 %.1fs"
          % (len(result), len(arcs), sum(len(a) for a in arcs_xy), time.time() - t0))

    city_data, code_of, region_of = load_tile_attrs()

    # ---- 验收指标 ----
    print("[3] 验收指标 ...")
    # 出现次数按「不同 label 环」计（同环自接触重复引用不重复计）
    occ = {}
    for lab in ring_refs:
        seen_in_lab = set()
        for slot in ("outer", "holes"):
            for refs in ring_refs[lab][slot]:
                for aid, _fw in refs:
                    if aid not in seen_in_lab:
                        seen_in_lab.add(aid)
                        occ[aid] = occ.get(aid, 0) + 1
    n_shared = 0      # 城块间弧（两侧均城块且不同——水密主角）
    n_self = 0        # 同侧弧（同 label 自接触段，两侧同 label）
    n_coast = 0       # 海岸弧（另一侧海洋）
    n_mismatch = 0
    for aid, a in enumerate(arcs):
        la, lb = a["sides"]
        if la > 0 and lb > 0 and la != lb:
            n_shared += 1
            if occ.get(aid, 0) != 2:
                n_mismatch += 1
        elif la > 0 and lb > 0:
            n_self += 1
        else:
            n_coast += 1
            if occ.get(aid, 0) != 1:
                n_mismatch += 1
    print("    城块间弧 %d（%.1f%%）/ 海岸弧 %d / 同侧自接触弧 %d / 跨块配对错配 %d（目标 0）"
          % (n_shared, 100.0 * n_shared / max(1, len(arcs)), n_coast, n_self, n_mismatch))
    missing = sorted(set(int(t["label"]) for t in city_data["tiles"]) - set(result.keys()))
    if missing:
        print("    ⚠️ 无环 label（%d 个）：%s —— 该城块多边形保持原样不换源"
              % (len(missing), missing[:10]))
    # 三界交点唯一性：弧端点聚类（0.01px 格）
    ends = {}
    for a in arcs_xy:
        for p in (a[0], a[-1]):
            k = (round(p[0] * 100), round(p[1] * 100))
            ends[k] = ends.get(k, 0) + 1
    n_end_slots = len(ends)
    print("    弧端点 %d → 唯一交点格 %d（比值越接近 1 三岔焊合越干净）"
          % (2 * len(arcs), n_end_slots))
    # 面积守恒（弧拼装 vs 标签像素）
    px = np.bincount(labels.ravel(), minlength=int(labels.max()) + 1)
    area_ratio = []
    for lab, polys in result.items():
        a = sum(ring_area(r) for r in polys["outer"]) - \
            sum(ring_area(h) for h in polys["holes"])
        if int(px[lab]) > 0:
            area_ratio.append(a / float(px[lab]))
    ar = np.array(area_ratio)
    print("    面积守恒：弧拼装/标签像素 中位 %.4f p05 %.4f p95 %.4f（等值线半像素系统差内≈1）"
          % (np.median(ar), np.percentile(ar, 5), np.percentile(ar, 95)))

    # ---- L3 political_mesh 组装 ----
    print("[4] L3 political_mesh 组装（fill earcut + 界线分类 + 湖）...")
    side_code = []
    border_type = []
    for a in arcs:
        la, lb = a["sides"]
        ca = code_of.get(la, 0) if la > 0 else 0
        cb = code_of.get(lb, 0) if lb > 0 else 0
        side_code.append((ca, cb))
        border_type.append(classify_border(ca, cb, region_of.get(la, 0), region_of.get(lb, 0)))

    tiles_geom = []
    for t in city_data["tiles"]:
        lab = int(t["label"])
        info = result.get(lab)
        if not info:
            continue
        for oi, outer in enumerate(info["outer"]):
            holes = info["holes"] if oi == 0 else []
            # result 环顶点是 mesh_extract 的 (y,x) 约定 → 转 (x,y)
            tiles_geom.append(([(p[1], p[0]) for p in outer],
                               [[(p[1], p[0]) for p in h] for h in holes], lab))
    fill_verts, fill_codes, fill_idx, n_washed = build_fill(
        tiles_geom, code_of, sea_rect=(8192, 8192))
    # 湖面两层，均与城块弧同源零漂移：① 城块内湖 = 洞弧展开 ② 城块间湖 =
    # 湖岸弧按场 0 组件串链（旧 L2 pack lakes 几何退役——与细化场不同代，
    # 湖面与城块洞错位漏 navy 底色）
    lake_mask = np.array(Image.open(os.path.join(
        OUT_DIR, "fractal_lake_mask_8192.png")).convert("L"))
    hole_lakes = build_hole_lakes(arcs_xy, ring_refs, city_data)
    lakes_geom = build_interblock_lakes(arcs, arcs_xy, labels, lake_mask)
    lake_verts, _, lake_idx, _ = build_fill(
        [(lk, [], 0) for lk in hole_lakes] + lakes_geom, {0: CODE_LAKE})
    base = len(fill_verts)
    fill_verts.extend(lake_verts)
    fill_codes.extend([CODE_LAKE] * len(lake_verts))
    fill_idx.extend(int(base + t) for t in lake_idx)
    if n_washed:
        print("    ⚠️ %d 个 tile 走 shapely 清洗/退化跳过（清洗比例应 <10%%）" % n_washed)
    print("    fill 顶点 %d（含湖 %d）三角 %d"
          % (len(fill_verts), len(lake_verts), len(fill_idx) // 3))

    # 贴湖弧标记（arc_lakeshore）：弧中点采样**原生湖 mask**（fractal_lake_mask，
    # 湖的真相源）——覆盖洞湖/旧湖/城块间湖岸的一切贴湖弧。湖是水域，政治界线
    #（国界/地区界/自由城邦界）与 glow 均不沿湖岸画（湖面由湖色与政权色的对比
    # 表达；界线沿湖岸走会产生断续黑线与 glow 不一致的观感杂乱）。
    arc_lakeshore = [0] * len(arcs_xy)
    # 膨胀湖 mask：城块弧在**岸上**（陆地一侧），弧顶点/近邻采样都可能偏出
    # 湖面（单点/三点/4 向偏 2px 均实测漏判 → 湖岸残留拉丝）。湖 mask 膨胀
    # LAKE_DILATE px 后「弧任一顶点落膨胀湖」= 贴湖弧，判定保守且完备
    lake_dilate = 8   # 膨胀带宽 px（覆盖岸宽；城界弧远端不受影响）
    lake_mask = ndi.binary_dilation(lake_mask > 0, iterations=lake_dilate)
    H8, W8 = lake_mask.shape

    def _in_lake(pt):
        mx = int(np.clip(round(pt[0]), 0, W8 - 1))
        my = int(np.clip(round(pt[1]), 0, H8 - 1))
        return lake_mask[my, mx]

    for aid, a in enumerate(arcs_xy):
        n = len(a)
        if _in_lake(a[0]) or _in_lake(a[n // 4]) or _in_lake(a[n // 2])                 or _in_lake(a[(3 * n) // 4]) or _in_lake(a[-1]):
            arc_lakeshore[aid] = 1
    print("    贴湖弧 %d 条（膨胀 %dpx；界线与 glow 均排除）"
          % (sum(arc_lakeshore), lake_dilate))

    mesh = {
        "name": "L3 政治矢量 mesh（共享弧拓扑，arc_topology.py 产；改色零重烘走 PoliticalLut）",
        "size": 8192,
        "coord": "xy@8192（Vector2(x,y) 直接渲染；顶点 code = lut 1..80 / 253 自由城邦 / 254 湖）",
        "arcs": [c for a in arcs_xy for p in a for c in p],
        "arc_ptr": _arc_ptr(arcs_xy),
        "arc_code_a": [sc[0] for sc in side_code],
        "arc_code_b": [sc[1] for sc in side_code],
        "arc_border": border_type,
        "arc_lakeshore": arc_lakeshore,
        "tiles": _tiles_refs(city_data, ring_refs),
        "fill_verts": [[round(x, 2), round(y, 2)] for (x, y) in fill_verts],
        "fill_code": fill_codes,
        "fill_idx": fill_idx,
    }

    if not args.write:
        print("[dry-run] 未写数据（--write 落地）。总耗时 %.1fs" % (time.time() - t0))
        _maybe_preview(args, mesh, arcs_xy, border_type, city_data)
        return

    # ---- 写回 ----
    print("[5] l3_city.json 城块多边形换源（弧拼装展开，[y,x] 序兼容旧格式）...")
    for t in city_data["tiles"]:
        lab = int(t["label"])
        info = result.get(lab)
        if not info:
            continue
        # result 环顶点 (y,x) → l3_city 格式 [y,x]，原样输出（勿解构成 (x,y)）
        t["polygons"] = [[[round(p[0], 3), round(p[1], 3)] for p in poly]
                         for poly in info["outer"]]
        t["holes"] = [[[round(p[0], 3), round(p[1], 3)] for p in poly]
                      for poly in info["holes"]]
    with open(os.path.join(GAME_DIR, "l3_city.json"), "w", encoding="utf-8") as f:
        json.dump(city_data, f, ensure_ascii=False, indent=1)
    print("    l3_city.json 已换源（%d tiles）" % len(city_data["tiles"]))

    mesh_path = os.path.join(GAME_DIR, "l3_political_mesh.json")
    with open(mesh_path, "w", encoding="utf-8") as f:
        json.dump(mesh, f, ensure_ascii=False, indent=1)
    print("    %s（%.1f MB）" % (mesh_path, os.path.getsize(mesh_path) / 1e6))

    print("[6] 13 份 L2 pack 注入 political_mesh ...")
    _inject_l2(arcs_xy, side_code, border_type, ring_refs, result, code_of, region_of,
               lakes_geom=lakes_geom)

    print("完成。总耗时 %.1fs。记得跑 l_world_bake.gd 刷 bin + headless --import"
          % (time.time() - t0))
    _maybe_preview(args, mesh, arcs_xy, border_type, city_data)


def _arc_ptr(arcs_xy):
    """每弧顶点在 arcs 平铺数组中的 float 起始偏移（末尾附总长哨兵）。"""
    ptr = []
    off = 0
    for a in arcs_xy:
        ptr.append(off)
        off += len(a) * 2
    ptr.append(off)
    return ptr


def _tiles_refs(city_data, ring_refs):
    """tiles 弧引用（带符号 id：负 = 反向；弧 id 从 1 起，0 保留）。"""
    out = []
    for t in city_data["tiles"]:
        lab = int(t["label"])
        info = ring_refs.get(lab)
        if not info:
            continue

        def enc(refs):
            return [[(aid + 1) if fw else -(aid + 1) for aid, fw in r] for r in refs]

        out.append({"label": lab,
                    "rings": enc(info["outer"]),
                    "holes": enc(info["holes"])})
    return out


def _inject_l2(arcs_xy, side_code, border_type, ring_refs, result, code_of, region_of,
               lakes_geom=None):
    """把窗口相交的城块 fill + 界线（context 坐标）注入 13 份 l2_world.json。"""
    code_of_lk = dict(code_of)
    code_of_lk[0] = CODE_LAKE
    for i in range(1, 14):
        rid = "region_%03d" % i
        info = json.load(open(os.path.join(GEN_PACKS_DIR, rid, "info.json"),
                              encoding="utf-8"))
        world = json.load(open(os.path.join(GAME_DIR, "l2_packs", rid, "l2_world.json"),
                               encoding="utf-8"))
        bb = info["bbox_8192"]
        tx, ty = world["tiles_offset"]
        cw, ch = world["context_size"]
        ox, oy = int(bb["x0"]) - int(tx), int(bb["y0"]) - int(ty)

        def to_ctx(pt):
            return (pt[0] - ox, pt[1] - oy)

        # 窗口相交 tile：环的 bbox 与窗口相交
        tiles_geom = []
        for t in result:
            polys = result[t]["outer"]
            holes = result[t]["holes"]
            # result 环顶点 (y,x)：bbox 用 y→x 域、顶点转 (x,y) 再平移
            ys = [p[0] for poly in polys for p in poly]
            xs = [p[1] for poly in polys for p in poly]
            if not xs or max(xs) < ox or min(xs) > ox + cw or max(ys) < oy or min(ys) > oy + ch:
                continue

            def to_ctx_yx(p):
                return (p[1] - ox, p[0] - oy)

            for oi, outer in enumerate(polys):
                h = holes if oi == 0 else []
                tiles_geom.append(([to_ctx_yx(p) for p in outer],
                                   [[to_ctx_yx(p) for p in hh] for hh in h], t))
        # 窗口相交湖面（与城块弧同源串链）→ context 坐标，code 0 湖色
        lk_ctx = []
        for outer, holes, _lab in (lakes_geom or []):
            xs = [p[0] for p in outer]
            ys = [p[1] for p in outer]
            if max(xs) < ox or min(xs) > ox + cw or max(ys) < oy or min(ys) > oy + ch:
                continue
            lk_ctx.append(([(p[0] - ox, p[1] - oy) for p in outer],
                           [[(p[0] - ox, p[1] - oy) for p in h] for h in holes],
                           0))
        # 窗口相交弧 → 界线折线（context 坐标），按界分类分组
        borders = {BORDER_NATIONAL: [], BORDER_REGION: [], BORDER_FREE_CITY: []}
        for aid, a in enumerate(arcs_xy):
            bt = border_type[aid]
            if bt not in borders:
                continue
            xs = [p[0] for p in a]
            ys = [p[1] for p in a]
            if max(xs) < ox or min(xs) > ox + cw or max(ys) < oy or min(ys) > oy + ch:
                continue
            borders[bt].append([to_ctx(p) for p in a])
        world["political_mesh"] = export_l2(
            world, tiles_geom + lk_ctx, borders, code_of_lk, ctx_size=(cw, ch))
        with open(os.path.join(GAME_DIR, "l2_packs", rid, "l2_world.json"), "w",
                  encoding="utf-8") as f:
            json.dump(world, f, ensure_ascii=False, indent=1)
        pm = world["political_mesh"]
        print("    %s: fill %d 顶点 / 国界 %d 地区界 %d 自由城邦界 %d 条"
              % (rid, len(pm["verts"]), len(pm["borders_national"]),
                 len(pm["borders_region"]), len(pm["borders_free"])))


def _maybe_preview(args, mesh, arcs_xy, border_type, city_data):
    """验收预览：全景（LUT 色填充）+ 政治界线叠加 + 出生区 1:1 特写。"""
    if args.no_preview:
        return
    from PIL import Image, ImageDraw

    states = city_data.get("states", {})
    lut_rgb = {}
    for sid, info in states.items():
        lut_rgb[int(info.get("lut_index", 0))] = tuple(info.get("color", [200, 200, 200]))
    lut_rgb[CODE_FREE_CITY] = (110, 110, 110)
    lut_rgb[CODE_LAKE] = (72, 116, 158)

    S = 2048
    img = Image.new("RGB", (S, S), (30, 55, 95))
    dr = ImageDraw.Draw(img)
    fv = mesh["fill_verts"]
    fc = mesh["fill_code"]
    fi = mesh["fill_idx"]
    k = S / 8192.0
    for t in range(0, len(fi), 3):
        c = lut_rgb.get(fc[fi[t]], None)
        if c is None:
            continue
        pts = []
        for j in (fi[t], fi[t + 1], fi[t + 2]):
            x, y = fv[j]
            pts.append((x * k, y * k))
        dr.polygon(pts, fill=c)
    bd_col = {1: (20, 20, 20), 2: (60, 60, 60), 3: (160, 160, 160)}
    for aid, bt in enumerate(border_type):
        if bt not in bd_col:
            continue
        dr.line([(x * k, y * k) for (x, y) in arcs_xy[aid]], fill=bd_col[bt], width=1)
    dst = os.path.join(OUT_DIR, "arcs_preview_2048.png")
    img.save(dst)
    print("    预览 %s" % dst)

    # 出生区特写 1:1（世界 8192：出生 ≈ (5864,3252)，取 1024² 窗口）
    cx, cy = 5864, 3252
    w = 1024
    img2 = Image.new("RGB", (w, w), (30, 55, 95))
    dr2 = ImageDraw.Draw(img2)
    x0, y0 = cx - w // 2, cy - w // 2

    def in_win(pt):
        return x0 <= pt[0] < x0 + w and y0 <= pt[1] < y0 + w

    for t in range(0, len(fi), 3):
        c = lut_rgb.get(fc[fi[t]])
        if c is None:
            continue
        tri = [fv[j] for j in (fi[t], fi[t + 1], fi[t + 2])]
        if not any(in_win(p) for p in tri):
            continue
        dr2.polygon([((x - x0), (y - y0)) for (x, y) in tri], fill=c)
    for aid, bt in enumerate(border_type):
        if bt not in bd_col:
            continue
        pts = arcs_xy[aid]
        if not any(in_win(p) for p in pts):
            continue
        dr2.line([((x - x0), (y - y0)) for (x, y) in pts], fill=bd_col[bt], width=2)
    dst2 = os.path.join(OUT_DIR, "arcs_preview_birth_closeup.png")
    img2.save(dst2)
    print("    预览 %s" % dst2)


if __name__ == "__main__":
    main()
