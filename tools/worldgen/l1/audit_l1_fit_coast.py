"""L1 全包「色块 ↔ 地形贴图」贴合度审计（一次性诊断）。

对每个包量三件事（都直接对应"省份色块与地图不严丝合缝"的观感）：
  A. 色块边界离地形水线的距离分布（溢出 = 色块伸进海里 / 内缩 = 陆上留白）
  B. 省内"地形陆地但无任何色块覆盖"的面积占比（盖不满）
  C. 色块越出地形陆地的面积占比（盖过头）

地形判水与运行时同口径：绿-蓝差 < -0.06。

用法：python tools/worldgen/l1/audit_l1_fit_coast.py [--all] [--labels 69,18]
"""
import argparse
import json
import os

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GAME = os.path.normpath(os.path.join(HERE, "..", "..", "stick-world", "config", "strategic_map"))
GB_MID = -0.06


def poly_mask(rings, size):
    im = Image.new("L", (size, size), 0)
    dr = ImageDraw.Draw(im)
    for ring in rings:
        if len(ring) >= 3:
            dr.polygon([(float(p[0]), float(p[1])) for p in ring], fill=255)
    return np.array(im) > 127


def dilate(m, k):
    o = m.copy()
    for _ in range(k):
        n = o.copy()
        n[1:, :] |= o[:-1, :]
        n[:-1, :] |= o[1:, :]
        n[:, 1:] |= o[:, :-1]
        n[:, :-1] |= o[:, 1:]
        o = n
    return o


def boundary(m):
    er = m.copy()
    er[1:, :] &= m[:-1, :]
    er[:-1, :] &= m[1:, :]
    er[:, 1:] &= m[:, :-1]
    er[:, :-1] &= m[:, 1:]
    return m & ~er


def dist_to(target, pts, max_d=25):
    """pts 中每个像素到 target 的切比雪夫距离（迭代膨胀，超 max_d 记 -1）。"""
    out = np.full(pts.shape, -1, dtype=np.int16)
    cur = target.copy()
    todo = pts.copy()
    for d in range(max_d + 1):
        hit = todo & cur
        out[hit] = d
        todo &= ~hit
        if not todo.any():
            break
        cur = dilate(cur, 1)
    return out


def audit(path, label):
    j = os.path.join(path, "l1_world.json")
    if not os.path.exists(j):
        return None
    d = json.load(open(j, encoding="utf-8"))
    size = int(d["size"])
    ter = np.array(Image.open(os.path.join(path, "l1_terrain.png")).convert("RGB")).astype(np.int32)
    gb = (ter[:, :, 1] - ter[:, :, 2]) / 255.0
    water = gb < GB_MID
    land = ~water
    own = poly_mask([t["polygon"] for t in d.get("tiles", [])], size)
    prov = poly_mask([d.get("l1_polygon") or []], size)
    nbr = poly_mask([r for nb in d.get("neighbors", []) for r in nb.get("polygons", [])], size)

    res = {"label": label, "size": size}
    res["tiles"] = int(own.sum())
    res["prov"] = int(prov.sum())
    res["iou_tiles_prov"] = round(float((own & prov).sum()) / max(1, (own | prov).sum()), 4)
    # A. 色块边界 ↔ 水线
    bp = boundary(own)
    onw = bp & water
    d_land = dist_to(land, onw)
    v = d_land[d_land >= 0]
    res["edge_px"] = int(bp.sum())
    res["edge_on_water_pct"] = round(100.0 * onw.sum() / max(1, bp.sum()), 1)
    if v.size:
        res["spill_p50"] = int(np.percentile(v, 50))
        res["spill_p90"] = int(np.percentile(v, 90))
        res["spill_max"] = int(v.max())
        res["spill_gt4"] = int((v > 4).sum())
    # B/C. 省内覆盖
    res["prov_land_uncovered_pct"] = round(100.0 * (prov & land & ~own).sum() / max(1, (prov & land).sum()), 2)
    res["tiles_on_water_pct"] = round(100.0 * (own & water).sum() / max(1, own.sum()), 2)
    # 邻省块与自身地块的重叠（叠色 = 观感脏）
    res["nbr_overlap_tiles_px"] = int((nbr & own).sum())
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--labels", default="")
    a = ap.parse_args()
    rows = []
    if a.all:
        for n in sorted(os.listdir(os.path.join(GAME, "l1_packs"))):
            p = os.path.join(GAME, "l1_packs", n)
            if os.path.isdir(p):
                r = audit(p, int(n.split("_")[1]))
                if r:
                    rows.append(r)
    else:
        for lab in [int(x) for x in a.labels.split(",") if x.strip()] or [69]:
            p = GAME if lab == 69 else os.path.join(GAME, "l1_packs", "l1_%03d" % lab)
            r = audit(p, lab)
            if r:
                rows.append(r)
    rows.sort(key=lambda r: -(r.get("spill_p90", 0) * 10 + r.get("prov_land_uncovered_pct", 0)))
    print("%-6s %-8s %-9s %-9s %-9s %-9s %-9s %-8s %s" % (
        "label", "tiles", "IOU/prov", "edge-onw", "spill50", "spill90", "spill>4", "未盖%", "块越水%"))
    for r in rows:
        print("#%-5d %-8d %-9.4f %-9.1f %-9s %-9s %-9s %-8.2f %.2f" % (
            r["label"], r["tiles"], r["iou_tiles_prov"], r["edge_on_water_pct"],
            r.get("spill_p50"), r.get("spill_p90"), r.get("spill_gt4"),
            r["prov_land_uncovered_pct"], r["tiles_on_water_pct"]))
    n_bad = [r["label"] for r in rows if r.get("spill_p90", 0) > 3 or r["iou_tiles_prov"] < 0.97]
    print("可疑包（spill_p90>3px 或 tiles≠prov）:", n_bad)


if __name__ == "__main__":
    main()
