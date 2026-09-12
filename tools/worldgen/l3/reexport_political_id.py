"""政权 ID mask 重导（数据对齐审计 #7）——细化场 + 现行 LUT code 重光栅化。

背景：l3_political_id_8192.png + 13×l2_political_id.png 是 R7 旧代产物
（旧 watershed 多边形描画）。矢量路线正常时不可见，矢量缺失回退时会退回
旧代边界旧代湖。本脚本从 S1 细化场直接映射重导：

  城块像素 = 所属政权 lut_index（l3_city.json tiles.state_id → states.lut_index）
  细化场 0 且湖 mask = CODE_LAKE(254)；其余 0 = 海洋
  L2 = 8192 蒙版按 context 窗口 order=0 采样 + neighbors=CODE_NEIGHBOR(255)
       / lakes=CODE_LAKE 补底（沿用 R7 export_l2_id_masks 语义，邻区/lake
       几何已是细化场同代）

无归属城块 → CODE_FREE(253)（现行数据 0 块，防御性保留）。

用法：
  python tools/worldgen/l3/reexport_political_id.py            # 干跑（统计 diff）
  python tools/worldgen/l3/reexport_political_id.py --write    # 写 PNG
  写完须 headless --import（新 PNG 不导入运行时静默 null）。
"""
import argparse
import json
import os
import sys
import time

import numpy as np
from PIL import Image
from scipy.ndimage import map_coordinates

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(HERE, "output")
REFINED = os.path.join(OUT_DIR, "l1_v2", "refined_city_labels_8192.npy")
LAKE8 = os.path.join(OUT_DIR, "fractal_lake_mask_8192.png")
GAME_CFG = os.path.join(HERE, "..", "..", "stick-world", "config", "strategic_map")
L2_PACKS = os.path.join(GAME_CFG, "l2_packs")

CODE_FREE = 253
CODE_LAKE = 254
CODE_NEIGHBOR = 255


def build_lake_raster(refined, lake8):
    """湖面光栅真值——与 arc_topology.build_interblock_lakes 同口径：
    细化场 0 组件中，非沾边（海）且满足其一者 = 湖：
      · 有湖 mask 组件种子（种子所在场组件 cid>0，且组件面积 ≤3×湖 mask 面积
        ——连海剔除）
      · 残余内陆厚水 40..100000 px（refine 开运算保留的中小湖，深放大的
        最小可见水斑下限）"""
    from scipy import ndimage as ndi
    zero = refined == 0
    cl, _ = ndi.label(zero)
    comp_sizes = np.bincount(cl.ravel())
    border_ids = set(int(i) for i in np.unique(np.concatenate(
        [cl[0, :], cl[-1, :], cl[:, 0], cl[:, -1]])) if i > 0)
    mc, n_mk = ndi.label(lake8)
    seeded = set()
    for lid in range(1, n_mk + 1):
        ys, xs = np.where(mc == lid)
        gy0, gy1 = int(ys.min()), int(ys.max()) + 1
        gx0, gx1 = int(xs.min()), int(xs.max()) + 1
        sub = mc[gy0:gy1, gx0:gx1] == lid
        d = ndi.distance_transform_edt(sub)
        k = int(d.argmax())
        cid = int(cl[gy0 + k // sub.shape[1], gx0 + k % sub.shape[1]])
        if cid > 0 and comp_sizes[cid] <= 3 * int(sub.sum()):
            seeded.add(cid)
    ok = np.zeros(len(comp_sizes), dtype=bool)
    for cid in range(1, len(comp_sizes)):
        if cid in border_ids:
            continue
        if cid in seeded or (40 <= comp_sizes[cid] <= 100000):
            ok[cid] = True
    return ok[cl]


def build_mask8():
    refined = np.load(REFINED)
    lake8 = np.asarray(Image.open(LAKE8).convert("L")) > 0
    lake_r = build_lake_raster(refined, lake8)
    city = json.load(open(os.path.join(GAME_CFG, "l3_city.json"), encoding="utf-8"))
    lut_of_state = {sid: int(s.get("lut_index", 0))
                    for sid, s in city.get("states", {}).items()}
    n_lab = int(refined.max())
    code_lut = np.zeros(n_lab + 1, dtype=np.uint8)
    n_free = 0
    for t in city["tiles"]:
        sid = str(t.get("state_id", ""))
        code = lut_of_state.get(sid, 0)
        if code <= 0:
            code = CODE_FREE
            n_free += 1
        code_lut[int(t["label"])] = code
    arr = np.zeros(refined.shape, dtype=np.uint8)
    land = refined > 0
    arr[land] = code_lut[refined[land]]
    arr[(~land) & lake_r] = CODE_LAKE
    print("[1] mask8 %s 城块码 %d 种，无归属=FREE %d 块，湖 %d px"
          % (arr.shape, len(np.unique(arr[land])), n_free, int(((~land) & lake_r).sum())))
    return arr


def export_l2(arr):
    made = []
    for rid in sorted(d for d in os.listdir(L2_PACKS) if d.startswith("region_")):
        info = json.load(open(os.path.join(OUT_DIR, "l2_packs", rid, "info.json"),
                              encoding="utf-8"))
        world = json.load(open(os.path.join(L2_PACKS, rid, "l2_world.json"),
                               encoding="utf-8"))
        bb = info["bbox_8192"]
        ctx_w, ctx_h = world["context_size"]
        tx, ty = world["tiles_offset"]
        gx = bb["x0"] - tx + np.arange(ctx_w)
        gy = bb["y0"] - ty + np.arange(ctx_h)
        GX, GY = np.meshgrid(gx, gy)
        sm = map_coordinates(arr, [GY, GX], order=0, mode="constant", cval=0)
        base = np.zeros((ctx_h, ctx_w), dtype=np.uint8)
        for nb in world.get("neighbors", []):
            for poly in nb.get("polygons", []):
                if len(poly) >= 3:
                    _raster_poly(base, poly, CODE_NEIGHBOR)
            for hole in nb.get("holes", []):
                if len(hole) >= 3:
                    _raster_poly(base, hole, 0)
        for lake in world.get("lakes", []):
            if len(lake) >= 3:
                _raster_poly(base, lake, CODE_LAKE)
        out = np.where(sm > 0, sm, base).astype(np.uint8)
        made.append((rid, out))
    return made


def _raster_poly(base, poly, code):
    """PIL 多边形填充（与 R7 export_l2_id_masks 同语义；环为 [y,x]）。"""
    from PIL import ImageDraw
    h, w = base.shape
    img = Image.fromarray(base, "L")
    drw = ImageDraw.Draw(img)
    drw.polygon([(p[1], p[0]) for p in poly], fill=int(code))
    base[:] = np.asarray(img)


def main():
    ap = argparse.ArgumentParser(description="政权 ID mask 重导（审计 #7）")
    ap.add_argument("--write", action="store_true", help="写 PNG（8192 + 13 区）")
    args = ap.parse_args()
    t0 = time.time()

    arr = build_mask8()
    dst3 = os.path.join(GAME_CFG, "l3_political_id_8192.png")
    if args.write:
        Image.fromarray(arr, "L").save(dst3)
        print("[2] 已写 %s" % dst3)

    old3 = np.asarray(Image.open(dst3).convert("L"))
    diff3 = int((old3 != arr).sum())
    print("    与旧版差异 %d px（%.2f%%）" % (diff3, diff3 / arr.size * 100))

    for rid, out in export_l2(arr):
        dst = os.path.join(L2_PACKS, rid, "l2_political_id.png")
        old = np.asarray(Image.open(dst).convert("L"))
        if old.shape != out.shape:
            print("  %s 尺寸变了 %s → %s（全量重导）" % (rid, old.shape, out.shape))
            diff = -1
        else:
            diff = int((old != out).sum())
        if args.write:
            Image.fromarray(out, "L").save(dst)
        print("  %s 差异 %s px" % (rid, diff))

    if args.write:
        print("[3] 完成（耗时 %.1fs）——须 headless --import" % (time.time() - t0))
    else:
        print("[dry-run] 未写（--write 落地）")


if __name__ == "__main__":
    main()
