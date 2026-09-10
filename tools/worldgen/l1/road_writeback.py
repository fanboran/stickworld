"""R6 道路写包 —— roads_v2_global.json 自然化折线写回 70 份 L1 包（观感返工 §R6 渲染端前置）。

road_naturalize.py 产物（road_v2/roads_v2_global.json，世界 8192 坐标 [x,y]）按包
world_origin 转局部坐标，就地替换各包 roads[] 条目：
  - polyline  自然化折线（局部 = 世界 − world_origin，round 2 与 v2 产物同精度）
  - length_px 更新为自然化后长度（快速旅行计价消费 length_px，§5.10）
  - sharp_anchors 锐折角锚点索引（陡坡直穿点；交通贴图烘焙端据此保留折角不圆滑）
  - tier 与 biomes 等其余既有字段全部保留不动
kept_as_is 条目（113 条 = 41 直线渡线 + 72 无折线）原样透传：直线渡线不可位移不可
加工（群岛无陆路，位移会画出海域假路）；无折线条目本就无 polyline 字段，不动。

确定性：纯坐标平移无随机量，重复执行幂等（二跑零 diff）。
写回后必须刷 bin（json 改动 bin 不刷则运行时不可见，交接档踩坑）：
  godot --headless --path stick-world -s res://tools/worldgen/l_world_bake.gd

用法：
  python road_writeback.py                # 全部 70 包
  python road_writeback.py --pack l1_001  # 指定包（spawn = 出生包）
  python road_writeback.py --dry-run      # 只对账不写
  Python 须用完整路径（PATH 首位 python 无完整库）
"""
import argparse
import json
import os
import time

HERE = os.path.dirname(os.path.abspath(__file__))
V2_PATH = os.path.normpath(os.path.join(
    HERE, "..", "output", "road_v2", "roads_v2_global.json"))
GAME_DIR = os.path.normpath(os.path.join(
    HERE, "..", "..", "..", "stick-world", "config", "strategic_map"))


def pack_files():
    """70 份包 json 路径（出生 1 + 批量 69），与 road_naturalize.pack_files 同口径。"""
    files = [os.path.join(GAME_DIR, "l1_world.json")]
    pdir = os.path.join(GAME_DIR, "l1_packs")
    files += [os.path.join(pdir, d, "l1_world.json")
              for d in sorted(os.listdir(pdir)) if d.startswith("l1_")]
    return files


def load_v2():
    with open(V2_PATH, encoding="utf-8") as f:
        doc = json.load(f)
    by_key = {}
    for rec in doc["roads"]:
        key = tuple(sorted((rec["from"], rec["to"])))
        if key in by_key:
            raise SystemExit("v2 产物边重复: %s" % (key,))
        by_key[key] = rec
    return doc, by_key


def writeback(json_path, by_key, dry=False):
    """单包写回。返回 (n_total, n_updated, n_kept)。"""
    with open(json_path, encoding="utf-8") as f:
        world = json.load(f)
    wo = world.get("world_origin")
    if not wo:
        print("  !! 缺 world_origin，跳过: %s" % json_path)
        return 0, 0, 0
    n_total = n_updated = n_kept = 0
    for rd in world.get("roads", []):
        n_total += 1
        key = tuple(sorted((rd["from"], rd["to"])))
        rec = by_key.get(key)
        if rec is None:
            raise SystemExit("包内边在 v2 产物缺失: %s (%s)" % (key, json_path))
        pl = rec.get("polyline")
        if pl is None:
            # kept_as_is 原样透传（直线渡线不可位移加工 / 无折线本就无 polyline）
            n_kept += 1
            continue
        rd["polyline"] = [[round(px - wo[0], 2), round(py - wo[1], 2)] for px, py in pl]
        rd["length_px"] = rec["length_new"]
        if rec.get("sharp_anchors"):
            rd["sharp_anchors"] = list(rec["sharp_anchors"])
        else:
            rd.pop("sharp_anchors", None)  # 无锐锚点清历史字段（幂等）
        n_updated += 1
    if not dry:
        with open(json_path, "w", encoding="utf-8") as f:
            json.dump(world, f, ensure_ascii=False, indent=1)
    return n_total, n_updated, n_kept


def main():
    ap = argparse.ArgumentParser(description="R6 道路写包（v2 自然化折线 → 70 份 L1 包）")
    ap.add_argument("--pack", nargs="*", help="只处理指定包（目录名如 l1_001；spawn = 出生包）")
    ap.add_argument("--dry-run", action="store_true", help="只对账不写文件")
    args = ap.parse_args()

    t0 = time.time()
    _, by_key = load_v2()
    print("v2 产物边 %d 条 <- %s" % (len(by_key), V2_PATH))

    files = pack_files()
    if args.pack:
        want = set(args.pack)
        files = [fp for fp in files
                 if os.path.basename(os.path.dirname(fp)) in want
                 or ("spawn" in want and fp == os.path.join(GAME_DIR, "l1_world.json"))]
    tot = upd = kept = 0
    for fp in files:
        n_total, n_updated, n_kept = writeback(fp, by_key, dry=args.dry_run)
        tot += n_total
        upd += n_updated
        kept += n_kept
        print("  %s: 条目 %d / 写回 %d / 透传 %d" % (
            os.path.basename(os.path.dirname(fp)) or "spawn", n_total, n_updated, n_kept))
    print("%s %d 包：条目 %d / 写回 %d / kept_as_is 透传 %d，耗时 %.1fs%s" % (
        "对账" if args.dry_run else "写回", len(files), tot, upd, kept,
        time.time() - t0, "（dry-run 未写文件）" if args.dry_run else ""))
    print("提醒：改 json 后必须刷 bin —— godot --headless --path stick-world "
          "-s res://tools/worldgen/l_world_bake.gd")
    if tot != upd + kept:
        raise SystemExit("条目对账不平（存在未分类条目）")


if __name__ == "__main__":
    main()
