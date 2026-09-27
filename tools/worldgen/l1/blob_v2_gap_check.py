# -*- coding: utf-8 -*-
"""blob_v2 净空验收：逐环量「blob 边到城块界」的最小距离（世界 px @8192）。
判据：tile_clear_margin(40) - roughen 三倍频最坏叠加(~14.5) - closing/栅格化(~1.5) ≈ 24px，
低于下限 = 净空带被侵蚀或剪裁兜底咬到了。用法：
    python blob_v2_gap_check.py            # 全量 1036 正常聚落
    python blob_v2_gap_check.py 100        # 只看差距最小的前 100 环
"""
import os
import sys

import numpy as np
from shapely.geometry import Polygon

from blob_v2_generate import BLOB_V2_DIR, load_cities

GAP_MIN = 24.0


def main():
    top_n = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    cities, _ = load_cities()
    d = np.load(os.path.join(BLOB_V2_DIR, "blob_v2_geoms.npz"))
    rings, meta, ids = d["rings"], d["ring_meta"], list(d["city_ids"])
    rows = []
    n_no_tile = 0
    for ci, ti, kind, oi, s, n in meta:
        sid = str(ids[ci])
        c = cities.get(sid)
        if c is None or c["tile_geom"] is None:
            n_no_tile += 1
            continue
        if n < 3:
            continue
        pg = Polygon(rings[s:s + n])
        if not pg.is_valid:
            pg = pg.buffer(0)
        if pg.is_empty:
            continue
        parts = [pg] if pg.geom_type == "Polygon" else \
            [g for g in getattr(pg, "geoms", []) if g.geom_type == "Polygon"]
        tpe = c["tile_geom"].exterior
        dist = min((g.exterior.distance(tpe) for g in parts if g.exterior is not None),
                   default=None)
        if dist is None:
            continue
        rows.append((dist, sid, int(ti)))
    rows.sort()
    dists = np.asarray([r[0] for r in rows])
    print("[gap] 环数 %d（无城块几何 %d 环）" % (len(rows), n_no_tile))
    print("[gap] 最小 %.1f / p1 %.1f / p5 %.1f / 中位 %.1f px（下限 %.0f）"
          % (dists.min(), np.percentile(dists, 1), np.percentile(dists, 5),
             np.percentile(dists, 50), GAP_MIN))
    bad = [r for r in rows if r[0] < GAP_MIN]
    print("[gap] 低于下限 %d 环" % len(bad))
    for dist, sid, ti in (bad if top_n <= 0 else rows[:top_n]):
        print("  %.1f px  %s tier%d" % (dist, sid, ti))

    # 档间嵌套对账（低⊆中⊆高）：渲染端三档贴图整包叠画，小档溢出大档=重影。
    # 按外环并集量「本档溢出上一档」的面积（构造端以粗糙化轮廓做界，允许贴边不允许出头）
    from shapely.ops import unary_union

    def _valid_union(parts):
        u = unary_union(parts)
        return u if u.is_valid else u.buffer(0)

    tier_polys = {}
    for ci, ti, kind, oi, s, n in meta:
        if n < 3:
            continue
        pg = Polygon(rings[s:s + n])
        if not pg.is_valid:
            pg = pg.buffer(0)
        if pg.is_empty:
            continue
        tier_polys.setdefault((str(ids[ci]), int(ti)), []).append(pg)
    nest_worst = []
    for (sid, ti), parts in tier_polys.items():
        higher = tier_polys.get((sid, ti + 1))
        if not higher:
            continue
        over = _valid_union(parts).difference(_valid_union(higher))
        if not over.is_empty and over.area > 1.0:
            nest_worst.append((over.area, sid, ti))
    nest_worst.sort(reverse=True)
    print("[nest] 档间溢出 %d 城×档" % len(nest_worst))
    for a, sid, ti in nest_worst[:6]:
        print("  %.0f px²  %s tier%d 溢出 tier%d" % (a, sid, ti, ti + 1))


if __name__ == "__main__":
    main()
