"""l3_city 城块面积质心重算（数据对齐审计 #5）。

背景：S2/S3 把 l3_city 城块多边形换成细化场弧拼装同代几何，但 centroid
字段仍是旧代质心（偏差 ≤~10px）——星标/国名锚点深放大不居中。

做法：
  1. polygon/holes 环先过 f32_clean_ring（bin 顶点 float32，float64 合法环
     量化后可能自交 → 运行时三角剖分丢面；与 L1/L2 同一踩坑，本文件漏清洗）
  2. 清洗后的多环+孔洞算鞋带面积质心（外环 +|A|，孔洞 -|A|，多环面积加权）
  3. 写回 centroid 字段（多边形 [y,x] → centroid 落盘 [x,y]，消费方
     map_label_layer 按 c[0]=x 读）；**anchor 不动**（有 blob/历史消费方，
     审计裁定保留旧值）

用法：
  python tools/worldgen/l3/recompute_city_centroids.py            # 干跑
  python tools/worldgen/l3/recompute_city_centroids.py --write    # 回写 json
  写完须重跑 l_world_bake.gd 重烘 l3_city.bin。
"""
import argparse
import json
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(HERE, "l2_export"))
import mesh_extract  # noqa: E402

GAME_JSON = os.path.join(HERE, "..", "..", "stick-world", "config",
                         "strategic_map", "l3_city.json")


def ring_contrib(r):
    """单环鞋带：(signed_area, dim0 质心, dim1 质心)。退化环返回 (0, None, None)。"""
    a = 0.0
    cx = 0.0
    cy = 0.0
    n = len(r)
    for i in range(n):
        x1, y1 = r[i]
        x2, y2 = r[(i + 1) % n]
        cr = x1 * y2 - x2 * y1
        a += cr
        cx += (x1 + x2) * cr
        cy += (y1 + y2) * cr
    if abs(a) < 1e-9:
        return 0.0, None, None
    a *= 0.5
    return a, cx / (6.0 * a), cy / (6.0 * a)


def poly_centroid_xy(polys, holes):
    """多环+孔洞面积加权质心，输入 [y,x] 环，返回 [x,y]。空/退化返回 None。"""
    ax = ay = w = 0.0
    for sign, group in ((1.0, polys), (-1.0, holes)):
        for r in group:
            a, c0, c1 = ring_contrib(r)
            if c0 is None:
                continue
            wa = abs(a)
            ax += sign * wa * c0
            ay += sign * wa * c1
            w += sign * wa
    if w <= 0:
        return None
    return [ay / w, ax / w]   # 几何 [y,x] → 落盘 [x,y]


def main():
    ap = argparse.ArgumentParser(description="l3_city 面积质心重算（审计 #5）")
    ap.add_argument("--write", action="store_true", help="回写 centroid 到 json")
    args = ap.parse_args()

    t0 = time.time()
    with open(GAME_JSON, encoding="utf-8") as f:
        d = json.load(f)
    tiles = d["tiles"]
    print("[1] %s 城块 %d" % (d.get("name"), len(tiles)))

    shifts = []
    n_clean = 0
    n_none = 0
    for t in tiles:
        old_p, old_h = t["polygons"], t["holes"]
        new_p = [r for ring in old_p for r in mesh_extract.f32_clean_ring(ring)]
        new_h = [r for ring in old_h for r in mesh_extract.f32_clean_ring(ring)]
        if len(new_p) != len(old_p) or len(new_h) != len(old_h):
            n_clean += 1
        c = poly_centroid_xy(new_p, new_h)
        if c is None:
            n_none += 1
            print("  !! tile %s 退化（环面积和 ≤0），centroid 保留旧值" % t["label"])
            continue
        old = t["centroid"]
        shifts.append(((c[0] - old[0]) ** 2 + (c[1] - old[1]) ** 2) ** 0.5)
        if args.write:
            if len(new_p) != len(old_p) or len(new_h) != len(old_h):
                t["polygons"], t["holes"] = new_p, new_h
            t["centroid"] = [round(c[0], 4), round(c[1], 4)]

    s = np.array(shifts)
    print("[2] centroid 偏移 px：median %.2f  p95 %.2f  max %.2f （n=%d，未算 %d）"
          % (np.median(s), np.percentile(s, 95), s.max(), len(s), n_none))
    print("    环清洗影响 tile：%d（自交拆分/空环剔除）" % n_clean)

    if args.write:
        with open(GAME_JSON, "w", encoding="utf-8") as f:
            json.dump(d, f, ensure_ascii=False, indent=1)
        print("[3] 已回写 %s（%.1f MB，耗时 %.1fs）——须重跑 l_world_bake.gd"
              % (GAME_JSON, os.path.getsize(GAME_JSON) / 1e6, time.time() - t0))
    else:
        print("[dry-run] 未写（--write 落地）")


if __name__ == "__main__":
    main()
