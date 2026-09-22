"""L1 全包几何↔贴图同代性审计（一次性诊断）。

背景：L1 视图包由多个脚本分步产出（几何 = export_l1_view_context 的 --polys-only patch；
贴图 = l1_terrain_bake / --base-only 重烘；河流 = river_export 注入）。任一步用了
不同的窗口（margin/原点）就会让"色块"与"贴图"错位——本脚本逐包对账：

  1. 包内 l1_polygon + world_origin  ←→  l3_l1.json 的省级权威多边形（地真）
        一致（IoU 高 / 质心偏移 ≈ 0）→ 几何窗口与全局坐标自洽
  2. 包内 rivers/lakes 折线是否落在 l1_terrain.png 的水域上（轴序/窗口双重校验）
  3. 包内 roads 折线是否落在 l1_travel.png 的道路像素上
  4. neighbors[] 环 ←→ 邻省在 l3_l1.json 的权威多边形 ∩ 本窗

任何一项大幅异常 = 该包是"混代"产物（几何与贴图不同代），即为色块不严丝合缝的根因。

用法：python tools/worldgen/l1/audit_l1_packs_consistency.py [--all|--labels 18,67]
"""
import argparse
import json
import os

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GAME = os.path.normpath(os.path.join(HERE, "..", "..", "stick-world", "config", "strategic_map"))
L3L1 = os.path.join(GAME, "l3_l1.json")
ROAD_DIRT = np.array([166, 122, 60])
ROAD_PAVED = np.array([198, 132, 82])


def load_l3l1():
    d = json.load(open(L3L1, encoding="utf-8"))
    out = {}
    for t in d["tiles"]:
        polys = [[(float(p[1]), float(p[0])) for p in ring] for ring in t.get("polygons", [])]
        out[int(t["label"])] = polys
    return out


def raster(rings, size, ox, oy, swap=False):
    im = Image.new("L", (size, size), 0)
    dr = ImageDraw.Draw(im)
    for ring in rings:
        pts = [((p[1] - ox, p[0] - oy) if swap else (p[0] - ox, p[1] - oy)) for p in ring]
        if len(pts) >= 3:
            dr.polygon(pts, fill=255)
    return np.array(im) > 127


def on_water(ter, pts):
    """折线顶点落在水域（绿-蓝差判水）的比例。"""
    h, w = ter.shape[:2]
    hit = tot = 0
    for x, y in pts:
        xi, yi = int(round(x)), int(round(y))
        if 0 <= xi < w and 0 <= yi < h:
            tot += 1
            gb = (int(ter[yi, xi, 1]) - int(ter[yi, xi, 2])) / 255.0
            if gb < -0.06:
                hit += 1
    return (hit / tot if tot else -1.0), tot


def on_road(img, pts, tol=26):
    h, w = img.shape[:2]
    hit = tot = 0
    for x, y in pts:
        xi, yi = int(round(x)), int(round(y))
        if 0 <= xi < w and 0 <= yi < h:
            tot += 1
            px = img[yi, xi].astype(np.int32)
            if np.abs(px - ROAD_DIRT).max() <= tol or np.abs(px - ROAD_PAVED).max() <= tol:
                hit += 1
    return (hit / tot if tot else -1.0), tot


def iou(a, b):
    u = (a | b).sum()
    return float((a & b).sum()) / u if u else 1.0


def centroid(m):
    ys, xs = np.nonzero(m)
    return (float(xs.mean()), float(ys.mean())) if xs.size else (float("nan"), float("nan"))


def audit_pack(path, l3, label_hint=None, verbose=True):
    j = os.path.join(path, "l1_world.json")
    if not os.path.exists(j):
        return None
    d = json.load(open(j, encoding="utf-8"))
    size = int(d["size"])
    wo = d.get("world_origin") or [0, 0]
    ox, oy = int(wo[0]), int(wo[1])
    ctx = d.get("context_size") or [size, size]
    label = label_hint or int(d.get("parent_l1_label", 0))
    terr = np.array(Image.open(os.path.join(path, "l1_terrain.png")).convert("RGB"))
    trav_p = os.path.join(path, "l1_travel.png")
    trav = np.array(Image.open(trav_p).convert("RGB")) if os.path.exists(trav_p) else None

    r = {"label": label, "dir": os.path.basename(path), "size": size, "ctx": list(ctx),
         "origin": [ox, oy], "notes": []}
    if [terr.shape[1], terr.shape[0]] != [size, size]:
        r["notes"].append("贴图 %dx%d != size %d" % (terr.shape[1], terr.shape[0], size))
    if list(ctx) != [size, size]:
        r["notes"].append("context_size != size（贴图按 1:1 铺满 context，尺寸不符即拉伸）")

    own = d.get("l1_polygon") or []
    gt = l3.get(label)
    if own and gt:
        mine = raster([own], size, 0, 0)
        mine_sw = raster([own], size, 0, 0, swap=True)
        g = raster(gt, size, ox, oy)
        r["iou_own"] = round(iou(mine, g), 3)
        r["iou_own_swapped"] = round(iou(mine_sw, g), 3)
        cx1, cy1 = centroid(mine)
        cx2, cy2 = centroid(g)
        r["own_centroid_off"] = [round(cx1 - cx2, 1), round(cy1 - cy2, 1)]

    rivers = [p for rv in d.get("rivers", []) for p in (rv.get("pts") or [])]
    if rivers:
        w1, n1 = on_water(terr, rivers)
        w2, _ = on_water(terr, [(p[1], p[0]) for p in rivers])
        r["rivers"] = {"n": n1, "on_water_xy": round(w1, 3), "on_water_swapped": round(w2, 3)}

    lakes = [p for lk in d.get("lakes", []) if isinstance(lk, list) for p in lk]
    if lakes:
        r["lakes"] = {"n": len(lakes), "on_water_xy": round(on_water(terr, lakes)[0], 3),
                      "on_water_swapped": round(on_water(terr, [(p[1], p[0]) for p in lakes])[0], 3)}

    if trav is not None:
        roads = [p for rd in d.get("roads", []) for p in (rd.get("polyline") or [])]
        if roads:
            s1 = on_road(trav, roads)[0]
            s2 = on_road(trav, [(p[1], p[0]) for p in roads])[0]
            r["roads"] = {"n": len(roads), "on_road_xy": round(s1, 3), "on_road_swapped": round(s2, 3)}

    nbr_rows = []
    for nb in d.get("neighbors", []):
        nl = int(nb["label"])
        gtn = l3.get(nl)
        if not gtn:
            continue
        mine = raster([pg for pg in nb.get("polygons", [])], size, 0, 0)
        mine_sw = raster([pg for pg in nb.get("polygons", [])], size, 0, 0, swap=True)
        g = raster(gtn, size, ox, oy)
        nbr_rows.append({"label": nl, "iou": round(iou(mine, g), 3),
                         "iou_swapped": round(iou(mine_sw, g), 3)})
    if nbr_rows:
        r["neighbors"] = nbr_rows
    if verbose:
        print(json.dumps(r, ensure_ascii=False))
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--labels", default="")
    ap.add_argument("--all", action="store_true")
    a = ap.parse_args()
    l3 = load_l3l1()
    if a.all:
        dirs = [os.path.join(GAME, "l1_packs", n)
                for n in sorted(os.listdir(os.path.join(GAME, "l1_packs")))]
        dirs = [d for d in dirs if os.path.isdir(d)]
        rows = []
        for d in dirs:
            lab = int(os.path.basename(d).split("_")[1])
            r = audit_pack(d, l3, lab, verbose=False)
            if r:
                rows.append(r)
        # 汇总：把异常挑出来
        print("=== 全包汇总（仅列异常）===")
        for r in rows:
            bad = []
            if r.get("iou_own", 1) < 0.9:
                bad.append("own IoU %.3f" % r["iou_own"])
            if r.get("iou_own_swapped", 0) > r.get("iou_own", 0):
                bad.append("own 疑似轴序反（swap IoU %.3f > %.3f）"
                           % (r["iou_own_swapped"], r["iou_own"]))
            off = r.get("own_centroid_off")
            if off and (abs(off[0]) > 6 or abs(off[1]) > 6):
                bad.append("质心偏移 %s" % off)
            rv = r.get("rivers")
            if rv and rv["on_water_xy"] >= 0 and rv["on_water_xy"] < 0.75:
                if rv["on_water_swapped"] > rv["on_water_xy"] + 0.15:
                    bad.append("rivers 疑似轴序反（%.2f → swap %.2f）"
                               % (rv["on_water_xy"], rv["on_water_swapped"]))
                else:
                    bad.append("rivers 落水率低 %.2f" % rv["on_water_xy"])
            lk = r.get("lakes")
            if lk and lk["on_water_xy"] >= 0 and lk["on_water_xy"] < 0.75:
                if lk["on_water_swapped"] > lk["on_water_xy"] + 0.15:
                    bad.append("lakes 疑似轴序反（%.2f → swap %.2f）"
                               % (lk["on_water_xy"], lk["on_water_swapped"]))
                else:
                    bad.append("lakes 落水率低 %.2f" % lk["on_water_xy"])
            rd = r.get("roads")
            if rd and rd["on_road_xy"] >= 0 and rd["on_road_xy"] < 0.5 and rd["on_road_xy"] < rd["on_road_swapped"] - 0.15:
                bad.append("roads 疑似轴序反（%.2f → swap %.2f）"
                           % (rd["on_road_xy"], rd["on_road_swapped"]))
            for nb in r.get("neighbors", []):
                if nb["iou"] < 0.85:
                    bad.append("neighbor #%d IoU %.3f%s" % (
                        nb["label"], nb["iou"],
                        "（swap 更高 %.3f）" % nb["iou_swapped"] if nb["iou_swapped"] > nb["iou"] else ""))
            if r["notes"]:
                bad.extend(r["notes"])
            if bad:
                print("#%02d %s  %s" % (r["label"], r["dir"], "; ".join(bad)))
        print("共 %d 包" % len(rows))
        return
    labels = [int(x) for x in a.labels.split(",") if x.strip()] or [69]
    for lab in labels:
        audit_pack(os.path.join(GAME, "l1_packs", "l1_%03d" % lab) if lab != 69 else GAME,
                   l3, lab)


if __name__ == "__main__":
    main()
