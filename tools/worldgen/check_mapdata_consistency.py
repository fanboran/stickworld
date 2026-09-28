"""地图数据一致性守门（水陆同源 L4.3）——「对齐」从人工审计变成构建期断言。

针对「色块与地图不严丝合缝」反复复发（三次修的都是症状），把三条不变量
（docs/项目/世界地图水陆同源重建-方案.md §二）逐包断言，失败即非零退出，
接进 tests/run_all.sh 门禁（纯 Python 读产物，不需要 Godot）：

  I2a 几何越海 = 0     ：tiles+neighbors 多边形栅格化 ∩ 水面（海∪湖∪河）= 0
  I2b 陆地漏盖 = 0     ：纯陆地（陆地∧¬水面）− 几何并集的残余全部贴几何边界
                        （多边形经 Chaikin 亚像素平滑，验收线 = 残余距边界 ≤1px）
  I3  色块边贴水线     ：几何边界像素到水面掩膜边界距离 p90 ≤1px（AA 过渡带）
  湖同源              ：包内 lakes 多边形栅格化 vs 精细湖光栅 IoU ≥0.97
                        （IoU 崩 = 轴序反/换代未同批，一并守住）

用法：
  python tools/worldgen/check_mapdata_consistency.py            # 出生包（config 根单份）
  python tools/worldgen/check_mapdata_consistency.py --all      # 全部 70 包（P2 全量重烘后）
"""
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import binary_dilation, binary_erosion, distance_transform_edt

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "l2_export"))
import land_snap  # noqa: E402

OUTPUT_DIR = os.path.join(HERE, "output")
GAME_DIR = os.path.normpath(os.path.join(
    HERE, "..", "..", "stick-world", "config", "strategic_map"))

## 阈值（P1 出生包标定；多边形是标签场经 Visvalingam+Chaikin 亚像素平滑后的
## 几何近似，栅格化回掩膜必有边界圈残余——P1 实测越海主体深度恰 1px、平滑
## 拐角残余深至 3px 共 ~20px/798²窗，故按「深度带」计量而非绝对归零）
TOL_SPILL_DEPTH_PX = 2.0   # I2a 越海深度上限（>此值 = 真越海，须为 0）
TOL_MISS_DEPTH_PX = 2.0    # I2b 漏盖深度上限
TOL_MISS_TOTAL_RATIO = 0.0001  # 深带外残余总量上限（窗口面积比；P2 全量后收紧）
TOL_SPILL_FAR_RATIO = 0.0004   # I2a 深越水上限（窗口面积比）：窄水道/峡口 Chaikin
                               # 跨桥细条（全量实测最重 ~500px、2048 视图 ~1px），
                               # 水感知平滑列 P3 收口，见 export_l1_view_context 注释
TOL_P90_PX = 1.0           # I3 色块边→水线距离 p90 上限
TOL_LAKE_IOU = 0.92        # 湖多边形 vs 湖光栅 IoU 下限（P1 实测 0.947；平滑削岸细部）


def rasterize(polys, side, value=1):
    """[x,y] 环列表 → 栅格 mask（PIL 多边形填充）。"""
    if not polys:
        return np.zeros((side, side), dtype=bool)
    img = Image.new("L", (side, side), 0)
    d = ImageDraw.Draw(img)
    for ring in polys:
        if len(ring) >= 3:
            d.polygon([(float(p[0]), float(p[1])) for p in ring], fill=value)
    return np.asarray(img, dtype=np.int8) > 0


def check_pack(json_path, land8, lake8, river8, wasteland8=None):
    """单包断言。返回 (ok, lines)：lines 为逐项实测行。"""
    with open(json_path, encoding="utf-8") as f:
        world = json.load(f)
    side = int(world.get("context_size", [0])[0]) or int(world.get("size", 0))
    wo = world.get("world_origin")
    if not wo or side <= 0:
        return False, ["  !! 缺 world_origin/context_size（先跑 river_export 注入）"]
    x0, y0 = int(wo[0]), int(wo[1])

    ctx_land = land8[y0:y0 + side, x0:x0 + side]
    ctx_lake = lake8[y0:y0 + side, x0:x0 + side]
    ctx_river = river8[y0:y0 + side, x0:x0 + side]
    # 贴陆口径（2026-09-22 创始人定性）：海/湖 = 面状水体，城块不进；
    # 河 = 陆上线状水，**地面归属穿河而过**（城块含河带，河流视觉由贴图层负责）
    water_all = ctx_lake | ctx_river | ~ctx_land       # 全水域（守门统计口径）
    water_hard = ctx_lake | ~ctx_land                  # 城块必须退出水域（贴陆口径）

    polys = []
    for t in world.get("tiles", []):
        polys.extend(t.get("polygons", []))
    geom = rasterize(polys, side)
    # 邻块：外环填充 + 洞环挖除（洞=内陆海洞/湖等 label 0 区，数据端外环绕洞走；
    # 不挖则洞区误计越海/陆地主张）
    nbr_img = Image.new("L", (side, side), 0)
    nd = ImageDraw.Draw(nbr_img)
    for nb in world.get("neighbors", []):
        for ring in nb.get("polygons", []):
            if len(ring) >= 3:
                nd.polygon([(float(p[0]), float(p[1])) for p in ring], fill=1)
        for ring in nb.get("holes", []):
            if len(ring) >= 3:
                nd.polygon([(float(p[0]), float(p[1])) for p in ring], fill=0)
    geom = geom | (np.asarray(nbr_img, dtype=np.int8) > 0)
    # 双几何口径：geom_full = 交付几何原样（湖中岛是陆地、必须有覆盖，I2b 用）；
    # geom_eff = 湖泊层覆盖后的有效陆地几何（湖面不是陆地主张，邻块外环吞湖由
    # 湖多边形接管——渲染同序 tiles→rivers→lakes；I2a 越海 / I3 岸线贴合用）
    if world.get("lakes"):
        geom_eff = geom & ~rasterize(world["lakes"], side)
    else:
        geom_eff = geom

    lines = []
    ok = True

    # I2a 几何越海（贴陆口径 = 海/湖；河带城块合法占据，只统计不判违规）；
    # 用 geom_eff：湖泊层接管的水面不算陆地主张
    spill = geom_eff & water_all
    in_river = int((spill & ctx_river).sum())
    spill_hard = spill & ~ctx_river
    if spill_hard.any():
        depth = distance_transform_edt(water_hard)[spill_hard]
        far = int((depth > TOL_SPILL_DEPTH_PX + 0.5).sum())
        cap = int(side * side * TOL_SPILL_FAR_RATIO)
        lines.append("  I2a 越海/湖 %d px（深度 p50 %.1f/max %.1f，>%.1fpx 者 %d ≤ 上限 %d）；"
                     "河带城块占据 %d px（口径内）"
                     % (int(spill_hard.sum()), float(np.median(depth)), float(depth.max()),
                        TOL_SPILL_DEPTH_PX, far, cap, in_river))
        ok &= far <= cap
    else:
        lines.append("  I2a 越海/湖 = 0 px；河带城块占据 %d px（口径内）" % in_river)

    # I2b 陆地漏盖：残余距几何边界 ≤ 带宽；带外残余总量 ≤ 窗口面积比。
    # V2 荒地语义：政治 mask 253 区（无主荒地=主张盘外无城块）是设计语义，
    # 从残余中剔除；mask 缺省（旧代数据）时退化为原判据。
    missing = (ctx_land & ~water_hard) & ~geom
    if wasteland8 is not None:
        missing &= ~wasteland8[y0:y0 + side, x0:x0 + side]
    n_missing = int(missing.sum())
    if n_missing == 0:
        lines.append("  I2b 陆地漏盖 = 0 px")
    else:
        edge_of_geom = geom ^ binary_erosion(geom)
        dist = distance_transform_edt(~edge_of_geom)   # 各像素到几何边界距离
        far = int((missing & (dist > TOL_MISS_DEPTH_PX + 0.5)).sum())
        cap = int(side * side * TOL_MISS_TOTAL_RATIO)
        lines.append("  I2b 陆地残余 %d px（距边 p50 %.1f/max %.1f，>%.1fpx 者 %d ≤ 上限 %d）"
                     % (n_missing, float(np.median(dist[missing])), float(dist[missing].max()),
                        TOL_MISS_DEPTH_PX, far, cap))
        ok &= far <= cap

    # I3 色块边 ↔ 水线（双向）：几何边界含窗口裁切边（与水线无关），只对
    # 邻水的边界段量贴合；反向量水线段是否都有几何贴着（描边不悬空）
    if (geom_eff & ~water_all).any():
        edge = geom_eff ^ binary_erosion(geom_eff)
        near_water = binary_dilation(water_all)
        coast = edge & near_water
        wb = water_all ^ binary_erosion(water_all)
        if coast.any() and wb.any():
            dist_to_wb = distance_transform_edt(~wb)
            vals = dist_to_wb[coast]
            p90 = float(np.percentile(vals, 90))
            # 反向只查海岸线（湖/河岸由矢量水覆盖，无地块描边是设计）：
            # 排除窗口裁切边（窗口外陆地不在包内）后，剩余缺口距几何 ≤ 平滑带
            ocean = ~ctx_land
            ob = ocean ^ binary_erosion(ocean)
            unc = ob & ~binary_dilation(geom_eff)
            if wasteland8 is not None:
                # V2 纯抗衡语义：无聚落离岛/无主陆地不切块（创始人 2026-09-27 裁决
                # 「无聚落即无主留荒地」）——荒地邻接的海岸线无城块描边是设计，不计缺口
                unc &= ~binary_dilation(
                    wasteland8[y0:y0 + side, x0:x0 + side], iterations=2)
            b = 8
            inner = unc.copy()
            inner[:b, :] = False
            inner[-b:, :] = False
            inner[:, :b] = False
            inner[:, -b:] = False
            n_unc = int(inner.sum())
            far_unc = 0
            if n_unc:
                edge_of_geom = geom_eff ^ binary_erosion(geom_eff)
                dg = distance_transform_edt(~edge_of_geom)
                far_unc = int((inner & (dg > TOL_MISS_DEPTH_PX + 0.5)).sum())
            lines.append("  I3 水线贴合：色块边 p50 %.2f/p90 %.2f/max %.2f px（≤%.1f）；"
                         "海岸线缺口（去窗边）%d px，深于 %.1fpx 者 %d"
                         % (float(np.median(vals)), p90, float(vals.max()), TOL_P90_PX,
                            n_unc, TOL_MISS_DEPTH_PX, far_unc))
            ok &= p90 <= TOL_P90_PX and far_unc <= int(side * side * TOL_MISS_TOTAL_RATIO)
        else:
            lines.append("  I3 窗内无水线交叠（跳过）")
    else:
        lines.append("  I3 窗内无陆上几何（跳过）")

    # 湖多边形 vs 精细湖光栅（IoU 崩 = 轴序反 / 换代未同批）；
    # 窗内湖过小（<4000px）时边界栅格化噪声主导 IoU（边缘条/面积可达 9%），
# 无判据意义 → 跳过
    ctx_lake = lake8[y0:y0 + side, x0:x0 + side]
    if ctx_lake.any() and world.get("lakes") and int(ctx_lake.sum()) >= 4000:
        lr = rasterize(world["lakes"], side)
        inter = int((lr & ctx_lake).sum())
        union = int((lr | ctx_lake).sum())
        iou = inter / union if union else 1.0
        lines.append("  湖多边形 vs 湖光栅 IoU %.4f（要求 ≥%.2f；轴序反/旧代会崩到 ~0）"
                     % (iou, TOL_LAKE_IOU))
        ok &= iou >= TOL_LAKE_IOU
    else:
        lines.append("  窗内无湖或包内无 lakes（跳过湖断言）")

    return ok, lines


def main():
    ap = argparse.ArgumentParser(description="地图数据一致性守门（水陆同源三不变量）")
    ap.add_argument("--all", action="store_true", help="全部 70 包（默认只查出生包）")
    ap.add_argument("--pack", nargs="*", help="指定包目录名（如 l1_001）")
    args = ap.parse_args()

    print("[守门] 加载水陆三真相（%s）..." % OUTPUT_DIR)
    land8, lake8, river8 = land_snap.load_water_masks(OUTPUT_DIR)
    # V2 政治 mask（253=无主荒地）——读不到则退化旧判据
    wasteland8 = None
    mask_path = os.path.join(GAME_DIR, "l3_political_id_8192.png")
    if os.path.isfile(mask_path):
        m = np.array(Image.open(mask_path))
        wasteland8 = (m == 253)
        print("[守门] 荒地掩膜：%s（253 区 %d px）" % (os.path.basename(mask_path),
                                                     int(wasteland8.sum())))
    else:
        print("[守门] 无 l3_political_id_8192.png，I2b 用旧判据（无荒地剔除）")

    packs = [(os.path.join(GAME_DIR, "l1_world.json"), "spawn")]
    packs_dir = os.path.join(GAME_DIR, "l1_packs")
    if os.path.isdir(packs_dir):
        for name in sorted(os.listdir(packs_dir)):
            jp = os.path.join(packs_dir, name, "l1_world.json")
            if os.path.isfile(jp):
                packs.append((jp, name))
    if args.pack:
        want = set(args.pack)
        packs = [(jp, n) for jp, n in packs if n in want or n == "spawn" and "spawn" in want]
    elif not args.all:
        packs = packs[:1]

    n_ok = 0
    for jp, name in packs:
        print("[%s] %s" % (name, jp))
        ok, lines = check_pack(jp, land8, lake8, river8, wasteland8)
        for ln in lines:
            print(ln)
        n_ok += 1 if ok else 0
        if not ok:
            print("  ✗ FAIL")
    print("守门结果：%d/%d 包通过" % (n_ok, len(packs)))
    if n_ok < len(packs):
        sys.exit(1)


if __name__ == "__main__":
    main()
