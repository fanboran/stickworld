"""道路沿线群系预采样注入（F6/E4，总体设计 §5.10 道路场景生成器输入）。

道路场景（场景图侧 road_map_generator.gd）地面色带按沿线群系切换——运行时
不持有 biome 栅格（biome_labels_2048.npy 是生成端再生产物，不进 config），
故由本工具在生成端一次性预采样：每条路 polyline 逐弧长采样群系标签，
写回 roads[i].biomes（int 数组，随 L1 视图包分发）。

坐标链（B3/P4 踩坑口径）：
  polyline 是 L1 本地 [x,y]（side@2048 级 context）
  → 世界 8192 = local + world_origin（B3 注入的 8192 级原点）
  → 2048 栅格 = /4 采样 biome_labels

标签表（biome_generate.py 同源）：0 海洋 / 1 平原 / 2 森林 / 3 荒漠 /
4 冰原 / 5 源流 / 6 火山。贴海岸路段可能采到海洋——保留原值，消费端
照标签上色（海边路基是沙滩语义，可接受）。

用法：
  python road_biome_export.py            # 注入 70 份（幂等，重跑覆盖）
  python road_biome_export.py --dry-run  # 只打印统计不写文件
注入后必须重跑 l_world_bake.gd 刷 bin（改 JSON 不刷 bin 运行时看不到）。
"""
import argparse
import glob
import json
import os

import numpy as np

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # tools/worldgen
OUTPUT_DIR = os.path.join(HERE, "output")
GAME_DIR = os.path.normpath(os.path.join(
    HERE, "..", "..", "stick-world", "config", "strategic_map"))

BIOME_LABELS_PATH = os.path.join(OUTPUT_DIR, "biome_labels_2048.npy")

SAMPLE_STEP_PX = 12.0    # 采样弧长间隔（px @2048 context）——色带粒度下限
MIN_SAMPLES = 2          # 每路保底采样数（极短路两端各一点）


def sample_polyline_biomes(polyline, world_origin, labels):
    """沿 polyline 逐弧长采样群系标签。polyline 为 L1 本地 [x,y] 列表。"""
    wo_x, wo_y = float(world_origin[0]), float(world_origin[1])
    # 世界 8192 → 2048 栅格坐标
    pts = [((x + wo_x) / 4.0, (y + wo_y) / 4.0) for x, y in polyline]
    # 弧长参数化
    arcs = [0.0]
    for i in range(1, len(pts)):
        dx = pts[i][0] - pts[i - 1][0]
        dy = pts[i][1] - pts[i - 1][1]
        arcs.append(arcs[-1] + (dx * dx + dy * dy) ** 0.5)
    total = arcs[-1]
    n = max(MIN_SAMPLES, int(total / SAMPLE_STEP_PX) + 1)
    h, w = labels.shape
    out = []
    for k in range(n):
        target = total * k / (n - 1) if n > 1 else 0.0
        # 线性定位目标弧长所在段
        i = 1
        while i < len(arcs) - 1 and arcs[i] < target:
            i += 1
        seg = arcs[i] - arcs[i - 1]
        t = 0.0 if seg <= 0 else (target - arcs[i - 1]) / seg
        x = pts[i - 1][0] + (pts[i][0] - pts[i - 1][0]) * t
        y = pts[i - 1][1] + (pts[i][1] - pts[i - 1][1]) * t
        ix = min(max(int(x), 0), w - 1)
        iy = min(max(int(y), 0), h - 1)
        out.append(int(labels[iy, ix]))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", help="只打印统计不写文件")
    args = ap.parse_args()

    labels = np.load(BIOME_LABELS_PATH)
    assert labels.dtype in (np.uint8, np.int32, np.int64), "biome 标签图 dtype 异常: %s" % labels.dtype
    print("[road_biome] 标签图 %s shape=%s" % (BIOME_LABELS_PATH, labels.shape))

    packs = [os.path.join(GAME_DIR, "l1_world.json")]
    packs += sorted(glob.glob(os.path.join(GAME_DIR, "l1_packs", "l1_*", "l1_world.json")))

    total_roads = 0
    patched_roads = 0
    skip_no_origin = 0
    dist = {}
    for pack_path in packs:
        with open(pack_path, encoding="utf-8") as f:
            data = json.load(f)
        roads = data.get("roads", [])
        if not roads:
            continue
        wo = data.get("world_origin")
        if wo is None:
            skip_no_origin += len(roads)
            print("[road_biome] ⚠ 缺 world_origin 跳过: %s（%d 条）" % (pack_path, len(roads)))
            continue
        changed = False
        for rd in roads:
            poly = rd.get("polyline", [])
            if len(poly) < 2:
                continue  # 直线回退段（无贴地折线）——消费端按两端均值兜底
            biomes = sample_polyline_biomes(poly, wo, labels)
            rd["biomes"] = biomes
            dist.update({b: dist.get(b, 0) + biomes.count(b) for b in set(biomes)})
            total_roads += 1
            patched_roads += 1
            changed = True
        if changed and not args.dry_run:
            with open(pack_path, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=1)

    names = ["海洋", "平原", "森林", "荒漠", "冰原", "源流", "火山"]
    print("[road_biome] pack 数=%d 采样路数=%d（缺 origin 跳过 %d 条）"
          % (len(packs), patched_roads, skip_no_origin))
    summary = "  ".join("%s %d(%.1f%%)" % (names[b] if b < len(names) else b, c, 100.0 * c / max(1, sum(dist.values())))
                        for b, c in sorted(dist.items()))
    print("[road_biome] 采样分布: %s" % summary)
    if not args.dry_run:
        print("[road_biome] 已注入，记得重跑 l_world_bake.gd 刷 bin！")


if __name__ == "__main__":
    main()
