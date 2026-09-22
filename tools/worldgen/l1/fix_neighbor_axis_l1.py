"""老 L1 包「邻块多边形轴序」一次性修复 —— (y,x) → (x,y)。

背景（2026-09-22 创始人观感反馈暴露的数据缺陷）：
  `export_l1_view_context.py` 写邻居块时把 mesh_extract 输出的 (y,x) 角点**漏过了
  to_xy 转换**直接落盘，而 L1 数据格式全仓统一 [x,y]（见 `l_world_bake.gd`「L1：原样
  序列化 [x,y]」、`L1TileDef._polygon_from`）。后果：邻块多边形整体沿**主对角轴翻转**，
  画灰色空心轮廓时看不出来（只是形状不对），2026-09-22 邻省上色后立刻暴露为
  「周围色块像被左上右下对称轴翻转」。

本脚本把 70 包（出生包 + l1_packs/*）的 `neighbors[].polygons/holes` 逐点换序，
等价于对已裁切几何补做 to_xy。源导出器同时已修（新导出的包自带 [x,y]，不需要再跑本脚本）。

用法：
  py -3 tools/worldgen/l1/fix_neighbor_axis_l1.py             # 执行
  py -3 tools/worldgen/l1/fix_neighbor_axis_l1.py --check     # 只体检（报告是否还有 (y,x) 包）
"""
import argparse
import glob
import json
import os

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # tools/worldgen
GAME_DIR = os.path.normpath(os.path.join(
    HERE, "..", "..", "stick-world", "config", "strategic_map"))


def pack_paths():
    out = [os.path.join(GAME_DIR, "l1_world.json")]
    out += sorted(glob.glob(os.path.join(GAME_DIR, "l1_packs", "*", "l1_world.json")))
    return [p for p in out if os.path.isfile(p)]


def looks_transposed(pack: dict, prov: dict) -> bool:
    """抽检：邻块多边形读作 [x,y] 时是否能落进「按全局裁窗」的期望 bbox 里。"""
    ox, oy = pack["world_origin"]
    side = int(pack["context_size"][0])
    for nb in pack.get("neighbors", [])[:3]:
        t = prov.get(int(nb["label"]))
        if t is None or not nb.get("polygons"):
            continue
        pts = [p for ring in t["polygons"] for p in ring]
        gx0, gy0 = min(p[1] for p in pts), min(p[0] for p in pts)
        gx1, gy1 = max(p[1] for p in pts), max(p[0] for p in pts)
        ex = (max(0, gx0 - ox), max(0, gy0 - oy), min(side, gx1 - ox), min(side, gy1 - oy))
        if ex[2] <= ex[0] or ex[3] <= ex[1]:
            continue
        got = [p for ring in nb["polygons"] for p in ring]
        b_xy = (min(p[0] for p in got), min(p[1] for p in got),
                max(p[0] for p in got), max(p[1] for p in got))
        b_yx = (min(p[1] for p in got), min(p[0] for p in got),
                max(p[1] for p in got), max(p[0] for p in got))

        def err(b):
            return sum(abs(b[i] - ex[i]) for i in range(4))
        return err(b_yx) < err(b_xy)
    return False


def swap_rings(rings):
    return [[[p[1], p[0]] for p in ring] for ring in rings]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只体检不写盘")
    args = ap.parse_args()
    with open(os.path.join(GAME_DIR, "l3_l1.json"), encoding="utf-8") as f:
        prov = {int(t["label"]): t for t in json.load(f)["tiles"]}

    n_fix = n_ok = n_skip = 0
    for path in pack_paths():
        with open(path, encoding="utf-8") as f:
            pack = json.load(f)
        nbs = pack.get("neighbors", [])
        if not nbs:
            n_skip += 1
            continue
        if not looks_transposed(pack, prov):
            n_ok += 1
            continue
        if args.check:
            n_fix += 1
            print("  [需修] %s" % os.path.relpath(path, GAME_DIR))
            continue
        for nb in nbs:
            nb["polygons"] = swap_rings(nb.get("polygons", []))
            nb["holes"] = swap_rings(nb.get("holes", []))
        with open(path, "w", encoding="utf-8") as f:
            json.dump(pack, f, ensure_ascii=False, separators=(",", ":"))
        n_fix += 1
    print("%s邻块轴序：%s %d 包 / 已正确 %d 包 / 无邻块 %d 包" % (
        "体检" if args.check else "修复",
        "需修" if args.check else "已修", n_fix, n_ok, n_skip))


if __name__ == "__main__":
    main()
