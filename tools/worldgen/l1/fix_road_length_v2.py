# -*- coding: utf-8 -*-
"""跨包道路段 length_px 回填（V2 重烤后处理）——road_writeback 写回时
跨包边被窗口截成多片的段落 length_px 记为 null；按 polyline 折线长度就地回填。
无 polyline 条目（直线渡线等）保持原值不动。确定性；改后须重刷 bin。
"""
import glob
import json
import math
import os

GAME = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    "..", "..", "stick-world", "config", "strategic_map")
GAME = os.path.normpath(GAME)


def poly_len(pl):
    s = 0.0
    for i in range(1, len(pl)):
        dx = float(pl[i][0]) - float(pl[i - 1][0])
        dy = float(pl[i][1]) - float(pl[i - 1][1])
        s += math.hypot(dx, dy)
    return s


total = 0
fixed = 0
paths = [os.path.join(GAME, "l1_world.json")] + sorted(
    glob.glob(os.path.join(GAME, "l1_packs", "l1_*", "l1_world.json")))
for p in paths:
    d = json.load(open(p, encoding="utf-8"))
    dirty = False
    for r in d.get("roads", []):
        total += 1
        v = r.get("length_px", "M")
        try:
            need = not (float(v) > 0)
        except (TypeError, ValueError):
            need = True
        if not need:
            continue
        pl = r.get("polyline", [])
        if len(pl) >= 2:
            r["length_px"] = round(poly_len(pl), 2)
            fixed += 1
            dirty = True
    if dirty:
        with open(p, "w", encoding="utf-8", newline="\n") as f:
            json.dump(d, f, ensure_ascii=False, indent=1)
print("条目 %d，回填 %d" % (total, fixed))
