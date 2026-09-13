"""一次性数据补丁：对已落盘的战略图 JSON 做运行时 float32 环清洗（审计#1 踩坑）。

背景：bin 的 polygon 顶点是 float32（PackedVector2Array），float64 下合法的环量化后
可能自交/重合 → 运行时 Geometry2D.triangulate_polygon 报错丢面。本脚本就地清洗：
  - 出生 L1 + 69 份 l1_packs（tiles polygon/polygons、neighbors、lakes、l1_polygon）
  - 13 份 l2_packs（tiles polygon/polygons/holes、neighbors、lakes）
  - l3_l1.json（tiles polygons/holes）
仅重写有变更的文件；跑完须 l_world_bake.gd 重刷 bin。导出工具已同步接线
mesh_extract.f32_clean_ring，本脚本只为免重跑全量提取。

用法：python tools/worldgen/l2_export/f32_clean_packs.py
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(HERE, "l2_export"))
from mesh_extract import f32_clean_ring  # noqa: E402

GAME_DIR = os.path.normpath(os.path.join(
    HERE, "..", "..", "stick-world", "config", "strategic_map"))


def _ring_area(ring):
    s = 0.0
    n = len(ring)
    for i in range(n):
        x1, y1 = ring[i]
        x2, y2 = ring[(i + 1) % n]
        s += x1 * y2 - x2 * y1
    return abs(s) / 2.0


def _clean_list(rings):
    """环列表逐环清洗（自交拆分拼回列表）。"""
    out = []
    for r in rings:
        out.extend(f32_clean_ring(r))
    return out


def _clean_tile(t, has_polygon):
    changed = False
    if has_polygon:
        polys = _clean_list(t.get("polygons", []))
        if polys != t.get("polygons"):
            changed = True
        t["polygons"] = polys
        pg = _clean_list([t.get("polygon", [])]) if t.get("polygon") else []
        if pg:
            main = max(pg, key=_ring_area)
            if main != t.get("polygon"):
                changed = True
            t["polygon"] = main
            # 拆分出的附加片并入 polygons（去重）
            for r in pg:
                if r != main and r not in t["polygons"]:
                    t["polygons"].append(r)
                    changed = True
        elif t.get("polygon"):
            t["polygon"] = []
            changed = True
    return changed


def patch_l1(path):
    d = json.load(open(path, encoding="utf-8"))
    changed = False
    for t in d.get("tiles", []):
        if _clean_tile(t, has_polygon=True):
            changed = True
    for n in d.get("neighbors", []):
        new_p = _clean_list(n.get("polygons", []))
        new_h = _clean_list(n.get("holes", []))
        if new_p != n.get("polygons") or new_h != n.get("holes"):
            n["polygons"], n["holes"] = new_p, new_h
            changed = True
    lakes = _clean_list(d.get("lakes", []))
    if lakes != d.get("lakes"):
        d["lakes"] = lakes
        changed = True
    lp = d.get("l1_polygon", [])
    if lp:
        cl = _clean_list([lp])
        d["l1_polygon"] = max(cl, key=_ring_area) if cl else []
        if d["l1_polygon"] != lp:
            changed = True
    if changed:
        json.dump(d, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    return changed


def patch_l2(path):
    d = json.load(open(path, encoding="utf-8"))
    changed = False
    for t in d.get("tiles", []):
        if _clean_tile(t, has_polygon=True):
            changed = True
        holes = t.get("holes", [])
        new_holes = []
        for h in holes:
            pts = h["points"] if isinstance(h, dict) else h
            parts = f32_clean_ring(pts)
            if parts != [pts]:
                changed = True
            for p in parts:
                new_holes.append({"points": p, "lake": h.get("lake", False)}
                                 if isinstance(h, dict) else p)
        if new_holes != holes:
            t["holes"] = new_holes
    for n in d.get("neighbors", []):
        new_p = _clean_list(n.get("polygons", []))
        new_h = _clean_list(n.get("holes", []))
        if new_p != n.get("polygons") or new_h != n.get("holes"):
            n["polygons"], n["holes"] = new_p, new_h
            changed = True
    lakes = _clean_list(d.get("lakes", []))
    if lakes != d.get("lakes"):
        d["lakes"] = lakes
        changed = True
    if changed:
        json.dump(d, open(path, "w", encoding="utf-8"), ensure_ascii=False,
                  separators=(",", ":"))
    return changed


def patch_l3l1(path):
    d = json.load(open(path, encoding="utf-8"))
    changed = False
    for t in d.get("tiles", []):
        new_p = _clean_list(t.get("polygons", []))
        new_h = _clean_list(t.get("holes", []))
        if new_p != t.get("polygons") or new_h != t.get("holes"):
            t["polygons"], t["holes"] = new_p, new_h
            changed = True
    if changed:
        json.dump(d, open(path, "w", encoding="utf-8"), ensure_ascii=False,
                  separators=(",", ":"))
    return changed


def main():
    n = 0
    for p in ["l1_world.json"] + [
            "l1_packs/l1_%03d/l1_world.json" % i for i in range(1, 70)]:
        path = os.path.join(GAME_DIR, p)
        if os.path.exists(path) and patch_l1(path):
            print("  L1 cleaned:", p)
            n += 1
    for i in range(1, 14):
        path = os.path.join(GAME_DIR, "l2_packs", "region_%03d" % i, "l2_world.json")
        if os.path.exists(path) and patch_l2(path):
            print("  L2 cleaned:", "region_%03d" % i)
            n += 1
    path = os.path.join(GAME_DIR, "l3_l1.json")
    if os.path.exists(path) and patch_l3l1(path):
        print("  L3 cleaned: l3_l1.json")
        n += 1
    print("完成：%d 份文件有清洗变更（其余本就干净）" % n)


if __name__ == "__main__":
    main()
