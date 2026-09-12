"""河流入湖末端 snap 到细化湖岸（数据对齐审计 #6）。

背景：river_export 的矢量折线从 fractal_river_mask_8192 骨架提取，入湖端点
停在**旧代湖岸**；湖岸经 S1 细化 warp 后偏移 ≤~15px——深放大下河流 either
悬空差几 px 落不到湖面，or 微微刺入湖面。

做法（只动矢量/政治消费路径；terrain 纹理里烘死的河与旧湖自成一致，不动）：
  1. 湖岸真值 = 细化场湖面光栅（reexport_political_id.build_lake_raster，
     与 political mesh 湖面同口径）的 0.5 等值线（subpixel，与弧同族提取）
  2. 端点识别：距**旧湖 mask** ≤3px 的折线端点 = 入湖端（骨架在旧岸停笔）
  3. snap：入湖端点移到最近湖岸等值线点（≤20px；超阈报告不动——湖被 warp
     吃掉/连海的病态场景，维持原状不造新错）
  4. 回写矢量缓存 river_vectors.json → 重跑 river_export 注入 + l_world_bake

用法：
  python tools/worldgen/l2_export/river_snap_lakes.py            # 干跑
  python tools/worldgen/l2_export/river_snap_lakes.py --write    # 回写缓存
  写完：python river_export.py && godot -s l_world_bake.gd
"""
import argparse
import json
import math
import os
import sys
import time

import numpy as np
from PIL import Image
from scipy.ndimage import distance_transform_edt

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(HERE, "output")
CACHE = os.path.join(OUT_DIR, "river_vectors.json")
REFINED = os.path.join(OUT_DIR, "l1_v2", "refined_city_labels_8192.npy")
LAKE8 = os.path.join(OUT_DIR, "fractal_lake_mask_8192.png")

OLD_NEAR = 3.0    # 端点距旧湖 ≤3px 视为入湖端（骨架停笔处）
SNAP_MAX = 20.0   # snap 最大位移（细化 warp 峰值 ~15px + 余量）


def shore_points(lake_r):
    """湖面光栅 0.5 等值线采样点集 (N,2) [x,y]（subpixel）。"""
    from skimage import measure
    cs = measure.find_contours(lake_r.astype(np.float32), 0.5)
    pts = []
    for c in cs:
        # c = (row, col) = (y, x)
        pts.append(np.column_stack([c[:, 1], c[:, 0]]))
    if not pts:
        return np.zeros((0, 2))
    return np.concatenate(pts, axis=0)


def main():
    ap = argparse.ArgumentParser(description="河流入湖端 snap 细化湖岸（审计 #6）")
    ap.add_argument("--write", action="store_true", help="回写矢量缓存")
    args = ap.parse_args()
    t0 = time.time()

    sys.path.insert(0, os.path.join(HERE, "l3"))
    from reexport_political_id import build_lake_raster
    refined = np.load(REFINED)
    lake8 = np.asarray(Image.open(LAKE8).convert("L")) > 0
    lake_r = build_lake_raster(refined, lake8)

    vectors = json.load(open(CACHE, encoding="utf-8"))
    print("[1] 矢量段 %d，湖面 %d px" % (len(vectors), int(lake_r.sum())))

    sp = shore_points(lake_r)
    from scipy.spatial import cKDTree
    tree = cKDTree(sp)
    dist_old = distance_transform_edt(~lake8)

    n_mouth = 0
    n_snap = 0
    disp = []
    n_far = 0
    for seg in vectors:
        pts = seg["pts"]
        for idx in (0, len(pts) - 1):
            p = pts[idx]
            if dist_old[int(round(p[1])), int(round(p[0]))] > OLD_NEAR:
                continue
            n_mouth += 1
            d, j = tree.query([p[0], p[1]])
            if d > SNAP_MAX:
                n_far += 1
                continue
            q = sp[j]
            if d > 0.01:
                pts[idx] = [round(float(q[0]), 1), round(float(q[1]), 1)]
                disp.append(float(d))
                n_snap += 1
    if disp:
        a = np.array(disp)
        print("[2] 入湖端 %d：snap %d（位移 median %.2f / p95 %.2f / max %.2f px），"
              "超阈不动 %d" % (n_mouth, n_snap, np.median(a), np.percentile(a, 95),
                              a.max(), n_far))
    else:
        print("[2] 入湖端 %d：无需 snap" % n_mouth)

    if args.write:
        with open(CACHE, "w", encoding="utf-8") as f:
            json.dump(vectors, f, separators=(",", ":"))
        print("[3] 已回写 %s（%.1f KB）——重跑 river_export.py 注入 + l_world_bake.gd"
              % (CACHE, os.path.getsize(CACHE) / 1024))
    else:
        print("[dry-run] 未写（--write 落地）")
    print("耗时 %.1fs" % (time.time() - t0))


if __name__ == "__main__":
    main()
