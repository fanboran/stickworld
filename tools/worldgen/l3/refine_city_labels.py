"""城块标签场 fBm 域扭曲细化（边界超分 S1：细分边缘拟合自然曲线）。

背景（创始人 2026-09-11 指示）：大陆大致形状不动，**细分边缘**用原始生成算法
（LANCZOS+fBm 域扭曲超分的同族思路，见 08-程序化世界生成「mask 超分到 8192
带海岸线扰动」）重新拟合出自然曲线。

问题：city_labels_8192.npy 是划分直出（EDT 最近聚落，8 连通语义），城块边界呈像素级
锯齿 + 大量对角接触（find_contours 提取时爆成 96 连重复点/T 形焊失败，实测
~5% label 面积偏差超 ±5%、5 个 label 无环）。

做法（**label 编号不变**——下游道路/blob/政权/聚落锚点零重灌，只重提取弧拓扑）：
  0. 分区细化（创始人设定 2026-09-11）：**同老 L1 内的城-城边界保持划分
     原始直线**（城市边界=人工直线分割的设计感），仅海岸/湖岸/L1 地块间边界
     做 fBm 自然化——城-城边界像素位移按距离衰减为 0（damp 场）
  1. fBm 域扭曲反向采样：refined(p) = labels(p + warp(p))，warp = 两 octave
     value noise（低频 260px/amp 11px 大弯 + 高频 64px/amp 3.5px 细碎，两通道
     独立 seed）——大致边界保持、边缘分形细化
  2. 海岸贴合（由轮廓提取前的统一贴陆后处理接管，本脚本不再自做）：曾声明
     "refined[原生海岸蒙版==0]=0 贴 locked_continent"，实际实现只做了 EDT 空洞
     回填（warp_sample 内 coast_land & (out==0)），细化场越海 0.79%~3.22%
     （距陆地 p50 3px/max 12px，2026-09-22 审计实测）——本步注释与代码不符
     即「越海缝」来源。现由 l2_export/land_snap.snap_labels_to_land 在
     extract_mesh 调用点统一贴陆（水面归 0 + 纯陆地回填），两代标签场均可套用
  3. 陆地空洞回填：warp 在海岸带把海采进陆地的像素，EDT 填最近城块；
     内陆零碎水域（河流/小池塘——容器 exclude 在 tiles 外的场 0）同回填，
     political 场只保留海与湖 mask 两种水域
  4. 对角接触 4 连通化：2×2 块迭代解耦（a==d&&b==c&&a!=b → d 让给 b），消除
     等值线提取的对角歧义（病态重复点环的根因）
  5. 校验：label 集合不变性 + 面积守恒统计

用法：
  python tools/worldgen/l3/refine_city_labels.py                # 干跑+预览
  python tools/worldgen/l3/refine_city_labels.py --write        # 写 refined_city_labels_8192.npy
"""
import argparse
import json
import os
import time

import numpy as np
from PIL import Image
from scipy import ndimage as ndi

import landmass_util as lmu

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(HERE, "output")
LABELS_PATH = os.path.join(OUT_DIR, "l1_v2", "city_labels_8192.npy")
GEN_PACKS_DIR = os.path.join(OUT_DIR, "l2_packs")
DEFAULT_PARAMS = {
    "comment": "fBm 域扭曲参数：低频大弯+高频细碎，两通道（dx/dy）独立 seed；"
               "amp 相对城块平均尺寸(~63px 边长)取 11/3.5px——自然弯曲且不破碎",
    "low_wavelength": 260,
    "low_amp": 11.0,
    "high_wavelength": 64,
    "high_amp": 3.5,
    "seed_dx": 20260911,
    "seed_dy": 91120260,
    "diag_max_iter": 24,
    "damp_falloff": 28,
    "comment_damp": "城-城边界（同老 L1 内）保持直线分割（设计设定：城市边界=人工直线，"
                    "L1 地块间/海岸/湖岸=自然地形）——城-城边界像素位移衰减为 0，"
                    "falloff=衰减带宽 px",
}


def build_locked_land():
    """最新陆地真相 = locked_continent_8192（水陆同源 I1 唯一海陆真相）。

    旧版用 13 区 tiles 拼图（coast_land）做空洞回填参考——它海岸略内缩且不是
    海岸裁剪真相源；细化场海岸必须贴最新 locked（创始人 2026-09-22 指令）。"""
    p = os.path.join(OUT_DIR, "locked", "locked_continent_8192.png")
    return np.array(Image.open(p).convert("L")) > 127


def build_land_mask():
    """陆地真相源 = 13 地区 tiles_8192.npy 拼回全图（update_tiles_coastline 已按
    8K mask_8192_full 裁过海岸——自然分形；与城块容器同一真相源）。"""
    land = np.zeros((8192, 8192), dtype=bool)
    for i in range(1, 14):
        rid = "region_%03d" % i
        info = json.load(open(os.path.join(GEN_PACKS_DIR, rid, "info.json"),
                              encoding="utf-8"))
        bb = info["bbox_8192"]
        seg = np.load(os.path.join(GEN_PACKS_DIR, rid, "tiles_8192.npy"))
        m = seg > 0
        land[int(bb["y0"]) + np.where(m)[0], int(bb["x0"]) + np.where(m)[1]] = True
    return land


def _hash_noise(ix, iy, seed):
    """无状态格点噪声（GLSL sin-hash）：格点值全局一致，支持分块计算。"""
    t = np.sin(np.float64(ix) * 127.1 + np.float64(iy) * 311.7 + np.float64(seed)) * 43758.5453
    return (t - np.floor(t)).astype(np.float32)


def _value_noise(x, y, wavelength, seed):
    """value noise： smootherstep 双线性插值格点噪声，输出 [0,1)。x/y 为全局像素坐标。"""
    fx = x / float(wavelength)
    fy = y / float(wavelength)
    ix0 = np.floor(fx).astype(np.int64)
    iy0 = np.floor(fy).astype(np.int64)
    tx = fx - ix0
    ty = fy - iy0
    sx = tx * tx * tx * (tx * (tx * 6.0 - 15.0) + 10.0)
    sy = ty * ty * ty * (ty * (ty * 6.0 - 15.0) + 10.0)
    n00 = _hash_noise(ix0, iy0, seed)
    n10 = _hash_noise(ix0 + 1, iy0, seed)
    n01 = _hash_noise(ix0, iy0 + 1, seed)
    n11 = _hash_noise(ix0 + 1, iy0 + 1, seed)
    top = n00 + (n10 - n00) * sx
    bot = n01 + (n11 - n01) * sx
    return top + (bot - top) * sy


def build_warp_chunk(x0, y0, h, w, prm):
    """块内位移场（dx,dy），噪声按全局坐标取值 → 分块无缝。"""
    yy, xx = np.meshgrid(
        np.arange(y0, y0 + h, dtype=np.float64),
        np.arange(x0, x0 + w, dtype=np.float64),
        indexing="ij")
    dx = (_value_noise(xx, yy, prm["low_wavelength"], prm["seed_dx"]) - 0.5) * 2.0 * prm["low_amp"] \
        + (_value_noise(xx, yy, prm["high_wavelength"], prm["seed_dx"] + 77) - 0.5) * 2.0 * prm["high_amp"]
    dy = (_value_noise(xx, yy, prm["low_wavelength"], prm["seed_dy"]) - 0.5) * 2.0 * prm["low_amp"] \
        + (_value_noise(xx, yy, prm["high_wavelength"], prm["seed_dy"] + 77) - 0.5) * 2.0 * prm["high_amp"]
    return dx, dy


def build_parent_map(labels):
    """像素 → 老 L1 归属（city_data.json 的 parent_l1 映射；海=0）。"""
    city_data = json.load(open(os.path.join(OUT_DIR, "l1_v2", "city_data.json"),
                               encoding="utf-8"))
    parent_of = {}
    for c in city_data["cities"]:
        parent_of[int(c["label"])] = int(c["parent_l1"])
    flat = labels.ravel()
    pm = np.zeros(flat.shape[0], dtype=np.int32)
    for lab, par in parent_of.items():
        pm[flat == lab] = par
    return pm.reshape(labels.shape)


def build_damp(labels, parent_map, falloff):
    """城-城边界位移衰减场：到「同老 L1 内城-城边界」的距离 → [0,1] 系数
    （0 = 边界处位移为 0，保持 watershed 原始直线；falloff 带宽外=1 正常细化）。"""
    H, W = labels.shape
    # 城-城边界像素：与正交邻域像素同 parent 但 label 不同
    same_p = (parent_map[1:, :] == parent_map[:-1, :])
    diff_l = (labels[1:, :] != labels[:-1, :])
    both = (labels[1:, :] > 0) & (labels[:-1, :] > 0)
    vert = same_p & diff_l & both
    horiz = (parent_map[:, 1:] == parent_map[:, :-1]) &             (labels[:, 1:] != labels[:, :-1]) &             (labels[:, 1:] > 0) & (labels[:, :-1] > 0)
    cc_bound = np.zeros((H, W), dtype=bool)
    cc_bound[1:, :][vert] = True
    cc_bound[:-1, :][vert] = True
    cc_bound[:, 1:][horiz] = True
    cc_bound[:, :-1][horiz] = True
    if not cc_bound.any():
        return np.ones((H, W), dtype=np.float32)
    dist = ndi.distance_transform_edt(~cc_bound)
    return np.clip(dist / float(falloff), 0.0, 1.0).astype(np.float32)


def warp_sample(labels, coast_land, prm, block=1024, damp=None, lake_mask=None, land_true=None,
                preserve=None):
    """fBm 域扭曲反向采样 + 海岸贴合 + 陆地空洞回填。damp=城-城边界位移衰减场。

    海岸贴合（2026-09-22 创始人指令「陆地边缘蒙版对齐最新版」真正落地）：
    warp 是连续位移场，会把海岸边的城块整体位移 ±amp——输出场的 0 区不是最新
    海岸（旧注释「无需额外海岸蒙版」不成立，审计实测细化场越海 0.79%~3.22%）。
    现按最新 locked_continent_8192 真相裁切：越海标签归 0，让细化蒙版的陆地
    边缘精确贴最新海岸；内部省界/城块划分从原始 labels 提取（warp 反向采样
    拓扑不变，同省城-城界 damp 保持直线）。

    preserve（v2 荒地语义）：无主荒地掩膜（bool 场，True=保持 0 不回填）。
    城块划分 v3 的主张盘封顶在陆地上留 0=荒地——这些 0 是设计产物不是 warp
    空洞，两处回填（海岸带空洞 + 内陆零碎水域）都必须跳过，否则荒地被最近
    城块吃掉。空洞回填只修城块域内的 warp 裂缝；荒地边界随 warp 自然摆动。
    """
    H, W = labels.shape
    out = np.zeros_like(labels)
    for y0 in range(0, H, block):
        hh = min(block, H - y0)
        for x0 in range(0, W, block):
            ww = min(block, W - x0)
            dx, dy = build_warp_chunk(x0, y0, hh, ww, prm)
            if damp is not None:
                dx = dx * damp[y0:y0 + hh, x0:x0 + ww]
                dy = dy * damp[y0:y0 + hh, x0:x0 + ww]
            # 反向采样：输出 (x,y) 取输入 (x+dx, y+dy)——NEAREST
            sx = np.clip(np.rint(np.arange(x0, x0 + ww, dtype=np.float64)[None, :] + dx),
                         0, W - 1).astype(np.int64)
            sy = np.clip(np.rint(np.arange(y0, y0 + hh, dtype=np.float64)[:, None] + dy),
                         0, H - 1).astype(np.int64)
            out[y0:y0 + hh, x0:x0 + ww] = labels[sy, sx]
        print("    warp %d/%d" % (y0 + hh, H), flush=True)
    # 海岸贴合（真实现）：陆地边缘对齐最新 locked 海岸，越海归 0
    if land_true is not None:
        n_sea = int((out[~land_true] != 0).sum())
        out[~land_true] = 0
        print("    海岸贴合（locked 最新版）：越海清除 %d px" % n_sea, flush=True)
        land_true_use = land_true
    else:
        land_true_use = coast_land
    # 陆地空洞回填：最新陆地内 warp 位移跨界产生的 0 空洞（细半岛 11px 位移）
    # （v2 荒地语义：preserve=True 的设计荒地 0 不算空洞，不回填）。
    # 同陆块约束：直线 EDT 最近会把海峡对岸的块染过来（群岛跨水染色根因），
    # 回填按陆块分组、只取同陆块城块做种子
    lm_base, _ = ndi.label(land_true_use)
    lm_ext = lmu.propagate_over_water(lm_base, land_true_use)
    hole = land_true_use & (out == 0)
    if preserve is not None:
        hole &= ~preserve
    n_hole = int(hole.sum())
    if n_hole:
        n_fill = lmu.edt_fill_within_landmass(out, hole, lm_ext)
        print("    陆地空洞回填 %d/%d px（同陆块最近城块）" % (n_fill, n_hole),
              flush=True)
    # 内陆零碎水域回填（河流/小池塘）：watershed 容器把它们 exclude 在 tiles 外
    #（场 0），political 渲染下成为 navy 细缝，岸线轮廓弧被当界线画成细丝。
    # 政治场只保留两种水域：块状海/湖 与 湖 mask——其余场 0 一律 EDT 填最近
    # 城块（政治图盖掉河塘，EU4 惯例）。海组件按**局部厚度**判定（开运算剪细
    # 枝）：河口水道再细也与海连通，按组件整判会把整条河留成 navy 细缝
    if lake_mask is not None:
        zero = out == 0
        # 厚度 ≥ 2×5+1 px 的水域才算「块状水」；细水道/发丝海峡剪除回填
        struct = np.ones((3, 3), dtype=bool)
        thick = ndi.binary_opening(zero, structure=struct, iterations=5)
        keep = thick | lake_mask
        hole2 = zero & ~keep
        if preserve is not None:
            hole2 &= ~preserve
        n2 = int(hole2.sum())
        if n2:
            n_fill2 = lmu.edt_fill_within_landmass(out, hole2, lm_ext)
            print("    内陆零碎水域回填 %d/%d px（河流/池塘/河口细道 → 同陆块最近城块）"
                  % (n_fill2, n2), flush=True)
    return out


def decouple_diagonal(labels, max_iter):
    """对角接触 4 连通化：2×2 块 a==d&&b==c&&a!=b → d 让给 b，迭代到收敛。"""
    total = 0
    for it in range(max_iter):
        a = labels[0:-1, 0:-1]
        b = labels[0:-1, 1:]
        c = labels[1:, 0:-1]
        d = labels[1:, 1:]
        m = (a == d) & (b == c) & (a != b) & (a > 0) & (b > 0)
        n = int(m.sum())
        if n == 0:
            print("    对角解耦收敛（%d 轮，累计 %d px）" % (it, total), flush=True)
            return labels
        labels[1:, 1:][m] = b[m]
        total += n
    print("    ⚠️ 对角解耦未收敛（%d 轮累计 %d px，残余对角接触）" % (max_iter, total), flush=True)
    return labels


def main():
    ap = argparse.ArgumentParser(description="城块标签场 fBm 域扭曲细化（S1）")
    ap.add_argument("--write", action="store_true", help="写 refined_city_labels_8192.npy")
    ap.add_argument("--params", default=os.path.join(HERE, "l3", "refine_params.json"))
    args = ap.parse_args()

    t0 = time.time()
    prm = dict(DEFAULT_PARAMS)
    if os.path.exists(args.params):
        prm.update(json.load(open(args.params, encoding="utf-8")))
    else:
        json.dump(prm, open(args.params, "w", encoding="utf-8"),
                  ensure_ascii=False, indent=1)

    labels = np.load(LABELS_PATH).astype(np.int32)
    coast_land = build_land_mask()
    n_lab = int(labels.max())
    print("[1] 标签场 %s 城块 %d；tiles 陆地 %.1f%%"
          % (labels.shape, n_lab, coast_land.mean() * 100))

    print("[2] 分区细化：海岸/湖岸/L1 地块间边界 fBm 自然化，"
          "同 L1 内城-城边界保持直线（衰减带宽 %spx）..." % prm.get("damp_falloff", 28))
    parent_map = build_parent_map(labels)
    damp = build_damp(labels, parent_map, prm.get("damp_falloff", 28))
    lake_mask = np.array(Image.open(os.path.join(
        OUT_DIR, "fractal_lake_mask_8192.png")).convert("L")) > 0
    land_locked = build_locked_land()
    # 设计荒地（v2）：城块划分 v3 主张盘封顶 + 无聚落分量留在输入场的陆地 0。
    # 判别「荒地 vs 细水（河/塘）」：荒地 = 能容纳 ~9px 厚度核的 0 陆地组件
    # （腐蚀 4 轮存活再膨胀回收）——河/塘/贫富城块间的薄缝容不下核，仍按 EU4
    # 惯例回填城块；不能用厚度开运算判（荒地连海成一片，开运算分不开）。
    river_mask = np.array(Image.open(os.path.join(
        OUT_DIR, "fractal_river_mask_8192.png")).convert("L")) > 127
    zero_land = land_locked & (labels == 0) & ~lake_mask & ~river_mask
    ones3 = np.ones((3, 3), dtype=bool)
    core = ndi.binary_erosion(zero_land, structure=ones3, iterations=4)
    preserve = ndi.binary_dilation(core, structure=ones3, iterations=5) & zero_land
    print("    设计荒地 %d px（陆地 %.1f%%）" % (
        int(preserve.sum()), preserve.sum() / max(land_locked.sum(), 1) * 100))
    refined = warp_sample(labels, coast_land, prm, damp=damp, lake_mask=lake_mask,
                          land_true=land_locked, preserve=preserve)

    print("[3] 对角接触 4 连通化 ...")
    refined = decouple_diagonal(refined, int(prm["diag_max_iter"]))

    # warp 位移跨水采样的兜底：一城块一陆块（外块的零散像素清 0 后同陆块回填）
    print("[3.5] 一城块一陆块收尾 ...")
    lm_base, _ = ndi.label(land_locked)
    lm_ext = lmu.propagate_over_water(lm_base, land_locked)
    n_bad, n_ref = lmu.enforce_single_landmass(refined, lm_ext)
    print("    跨陆块清理 %d px（同陆块回填 %d px）" % (n_bad, n_ref))

    # ---- 校验 ----
    print("[4] 校验 ...")
    old_set = set(int(v) for v in np.unique(labels) if v > 0)
    new_set = set(int(v) for v in np.unique(refined) if v > 0)
    lost = sorted(old_set - new_set)
    print("    label 集合：旧 %d → 新 %d（消失 %d %s）"
          % (len(old_set), len(new_set), len(lost), lost[:8] if lost else ""))
    px_old = np.bincount(labels.ravel(), minlength=n_lab + 1)
    px_new = np.bincount(refined.ravel(), minlength=n_lab + 1)
    ratio = px_new[1:] / np.maximum(px_old[1:], 1)
    print("    面积比（新/旧）中位 %.4f  p05 %.4f  p95 %.4f  超出±5%% 的 label 数 %d"
          % (np.median(ratio), np.percentile(ratio, 5), np.percentile(ratio, 95),
             int(((ratio < 0.95) | (ratio > 1.05)).sum())))
    # 对角接触残留（采样统计）
    a = refined[0:-1, 0:-1]
    b = refined[0:-1, 1:]
    c = refined[1:, 0:-1]
    d = refined[1:, 1:]
    resid = int(((a == d) & (b == c) & (a != b) & (a > 0) & (b > 0)).sum())
    print("    对角接触残留（全量）：%d 处" % resid)

    if args.write:
        out_path = os.path.join(OUT_DIR, "l1_v2", "refined_city_labels_8192.npy")
        np.save(out_path, refined)
        print("[5] 已写 %s（%.0f MB）" % (out_path, os.path.getsize(out_path) / 1e6))
    else:
        print("[dry-run] 未写数据（--write 落地）")

    _preview(labels, refined, coast_land)
    print("完成，耗时 %.1fs" % (time.time() - t0))


def _preview(old, new, coast_land):
    """特写对比：海岸段 + 内陆两国交界段（原 vs 细化并排）。"""
    from PIL import ImageDraw

    def render(labels, x0, y0, w):
        lut = {}
        rng = np.random.default_rng(7)
        img = Image.new("RGB", (w, w), (30, 55, 95))
        px = img.load()
        sub_o = labels[y0:y0 + w, x0:x0 + w]
        # 简化渲染：label 边界描白（相邻不同），内部按 label 哈希灰阶
        import colorsys
        for yy in range(w):
            row = sub_o[yy]
            for xx in range(w):
                v = int(row[xx])
                if v == 0:
                    px[xx, yy] = (30, 55, 95)
                    continue
                if v not in lut:
                    h = (v * 0.6180339887) % 1.0
                    rgb = colorsys.hsv_to_rgb(h, 0.5, 0.75)
                    lut[v] = tuple(int(c * 255) for c in rgb)
                edge = (xx > 0 and int(sub_o[yy, xx - 1]) != v) or \
                       (yy > 0 and int(sub_o[yy - 1, xx]) != v)
                px[xx, yy] = (20, 20, 20) if edge else lut[v]
        return img

    spots = [("海岸段", 2740, 900), ("内陆界", 5400, 2800)]
    for name, cx, cy in spots:
        w = 512
        a = render(old, cx, cy, w)
        b = render(new, cx, cy, w)
        canvas = Image.new("RGB", (w * 2 + 8, w), (60, 60, 60))
        canvas.paste(a, (0, 0))
        canvas.paste(b, (w + 8, 0))
        dr = ImageDraw.Draw(canvas)
        dr.text((6, 4), "old", fill=(255, 255, 255))
        dr.text((w + 14, 4), "refined", fill=(255, 255, 255))
        dst = os.path.join(OUT_DIR, "refine_preview_%s.png" % name)
        canvas.save(dst)
        print("    预览 %s" % dst)


if __name__ == "__main__":
    main()
