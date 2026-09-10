"""L1 地形底图烘焙 —— R9 静态层烘焙化基建（观感返工 §R9，先地形单一模式打通）

对 70 份 L1 包（出生 1 + 批量 69）各产一张 l1_terrain.png：
按包内 world_origin（8192 全局 [x,y]）+ context_size 裁窗 → B2 同管线分层合成
（群系基色 / 高度明度·岩石·雪线 / hillshade / 海洋离岸渐变 / 海岸暗线 / 河湖）
→ 8192 原生分辨率（1:1，无降采样）写入各包目录。

着色与 tools/worldgen/l3/terrain_render.py（B2 已验收）同一代码路径：
  import terrain_render 复用其 load_inputs / build_fields / render_block，
  参数经 l1_terrain_params.json 的 inherits 字段继承 terrain_params.json
  （单一真相源：B2 调参后本工具重跑即同源）。

L1 特有差异（相对 L3/L2 全图渲染）：
  1. 群系基色柔化（biome_blend_sigma）：群系标签是 2048 级 ×4 块状映射，
     8192 原生输出时边界呈 4px 台阶——仅对 LUT 基色层做小 sigma 高斯
     （hillshade/高度调制后乘，高频细节保留），等效柔和过渡。
  2. 不做超采样 AA：本批贴图 = 纯场合成（无矢量描边），逐像素运算无光栅锯齿；
     R9 方案的「4x 超采样」为批 3 矢量层（建成区/道路烘进贴图）预留，届时启用。

窗口读取方式与 export_l1_view_context.py --polys-only 同口径：
  只信包内 world_origin + context_size（规避 margin 不统一坑），不重算窗口。

输入（output/，缺失先从主工作区复制；biome 两件可用 l3/biome_generate.py 确定性重跑）：
  fractal_heightmap_8192.npy / fractal_lake_mask_8192.png / fractal_river_mask_8192.png
  biome_labels_2048.npy / biome_hot_zone_2048.png / locked/locked_continent_8192.png

用法：
  python l1_terrain_bake.py                 # 全部 70 包（terrain + travel 两变体）
  python l1_terrain_bake.py --pack l1_001   # 指定包（spawn = 出生包）
  python l1_terrain_bake.py --spawn-only    # 只跑出生包（调参快速预览）

R4 交通模式变体（l1_travel.png）：params l1.travel 配置存在即随每包产出——
地形底图（同 terrain）+ R6 道路 casing 双层实线（road_v2 自然化折线，
2x 超采样 AA / 路面乘 hillshade / 端部收尖 / 锐折角锚点拆段保留折角）。
"""
import argparse
import json
import os
import sys
import time

import numpy as np
from scipy.ndimage import gaussian_filter
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
L3_DIR = os.path.join(os.path.dirname(HERE), "l3")
sys.path.insert(0, L3_DIR)
import terrain_render as tr  # noqa: E402  B2 着色管线（单一真相源）

OUTPUT_DIR = tr.OUTPUT_DIR
REPO_ROOT = tr.REPO_ROOT
CONFIG_DIR = tr.CONFIG_DIR
PARAMS_PATH = os.path.join(HERE, "l1_terrain_params.json")

SIZE_FULL = 8192


def load_params():
    """继承 terrain_params.json（B2 同源）+ 本地 l1 覆写（浅合并顶层键）。"""
    with open(PARAMS_PATH, encoding="utf-8") as f:
        p = json.load(f)
    parent_rel = p.pop("inherits", None)
    if parent_rel:
        with open(os.path.normpath(os.path.join(HERE, parent_rel)), encoding="utf-8") as f:
            base = json.load(f)
        base.update(p)  # 本地键覆盖父值
        return base
    return p


def list_packs():
    """全部 L1 包：[(目录, 标签说明), ...]。出生包 = config 根的单份，批量 = l1_packs/l1_XXX。"""
    packs = [(os.path.join(CONFIG_DIR, "l1_world.json"), "spawn(l1_069)")]
    packs_dir = os.path.join(CONFIG_DIR, "l1_packs")
    for name in sorted(os.listdir(packs_dir)):
        jp = os.path.join(packs_dir, name, "l1_world.json")
        if os.path.isfile(jp):
            packs.append((jp, name))
    return packs


def render_window(sl, fields, colors, blend_sigma):
    """单窗口合成（render_full 块内逻辑的窗口版 + L1 基色柔化）。返回 RGB uint8。"""
    labels8, elev, land, lake = fields["labels8"], fields["elev"], fields["land"], fields["lake"]
    shade, ocean_edt, lake_in, coast_dark, river_a = (
        fields["shade"], fields["ocean_edt"], fields["lake_in"],
        fields["coast_dark"], fields["river_a"])
    hot8 = fields["hot8"]
    p = fields["p"]

    lut = np.zeros((8, 3), dtype=np.float32)
    for i, c in tr.BIOME_COLORS.items():
        lut[i] = c
    # 1. 群系基色（L1 柔化：labels 2048 级 ×4 块状映射的 4px 台阶 → 2-3px 渐变带）
    rgb = lut[labels8[sl]]
    if blend_sigma > 0:
        rgb = gaussian_filter(rgb, sigma=(blend_sigma, blend_sigma, 0))

    # 2/3/6. 高度调制 + hillshade + 炎热偏移（B2 同函数）
    ctx = {"elev": elev, "shade": shade, "hot": hot8,
           "rock": colors["rock"], "snow": colors["snow"], "p": p}
    rgb = tr.render_block(rgb, sl, ctx)

    # 4. 水体（render_full 同式：河流软化混色 → 湖泊覆盖 → 海洋离岸渐变）
    ra = river_a[sl]
    rgb = rgb * (1.0 - ra[..., None]) + colors["river"][None, None, :] * ra[..., None]
    lm = lake[sl]
    if lm.any():
        depth = np.clip(lake_in[sl] / 30.0, 0.0, 1.0)
        lc = colors["lake"][None, None, :] * (1.0 - 0.08 * depth[..., None])
        rgb = np.where(lm[..., None], lc, rgb)
    om = ~land[sl]
    if om.any():
        d = ocean_edt[sl]
        op = p["ocean"]
        t = np.clip(d / op["shelf_px"], 0.0, 1.0) ** op["gamma"]
        oc_rgb = colors["ocean_near"][None, None, :] \
            + (colors["ocean_far"] - colors["ocean_near"])[None, None, :] * t[..., None]
        rgb = np.where(om[..., None], oc_rgb, rgb)

    # 5. 海岸暗线（陆地侧）
    cd = coast_dark[sl]
    if cd.any():
        rgb = np.where(cd[..., None], rgb * p["coast"]["darken"], rgb)

    np.clip(rgb, 0.0, 255.0, out=rgb)
    return rgb.astype(np.uint8)


def bake_pack(json_path, fields, colors, lp, texture_name):
    """单包：读 world_origin/context_size 裁窗合成 → 写 l1_terrain.png。"""
    with open(json_path, encoding="utf-8") as f:
        world = json.load(f)
    wo = world.get("world_origin")
    csz = world.get("context_size")
    if not wo or not csz:
        print("  !! 缺 world_origin/context_size，跳过: %s" % json_path, flush=True)
        return False
    x0, y0 = int(wo[0]), int(wo[1])
    side = int(csz[0])
    if x0 < 0 or y0 < 0 or x0 + side > SIZE_FULL or y0 + side > SIZE_FULL:
        print("  !! 窗口越界 (%d,%d)+%d，跳过: %s" % (x0, y0, side, json_path), flush=True)
        return False
    sl = (slice(y0, y0 + side), slice(x0, x0 + side))
    rgb = render_window(sl, fields, colors, lp["biome_blend_sigma"])
    out = os.path.join(os.path.dirname(json_path), texture_name)
    Image.fromarray(rgb).save(out)
    print("  %s: %d² @ (%d,%d) -> %.1f MB" % (
        os.path.basename(os.path.dirname(json_path)) or "spawn",
        side, x0, y0, os.path.getsize(out) / 1048576), flush=True)
    return True


# ---------------------------------------------------------------- R4 交通模式变体

def load_v2_roads(tp):
    """R6 自然化产物 → [(tier, pts ndarray Nx2 世界坐标, sharp 锚点索引 set), ...]。

    无折线条目（kept_as_is 的 no_polyline）跳过——包内本就无 polyline 不渲染。
    """
    path = os.path.normpath(os.path.join(HERE, tp["v2_roads"]))
    with open(path, encoding="utf-8") as f:
        doc = json.load(f)
    roads = []
    for rec in doc["roads"]:
        pl = rec.get("polyline")
        if not pl or len(pl) < 2:
            continue
        roads.append((
            rec.get("tier") or "DIRT",
            np.asarray(pl, np.float64),
            set(rec.get("sharp_anchors") or []),
        ))
    print("  v2 道路折线 %d 条 <- %s" % (len(roads), path), flush=True)
    return roads


def _tip_polygon(p0, p1, width, tip_len):
    """端部收尖锥形（聚落处半宽渐缩到 0，§7.2「端部收尖」）。

    主体 line 的方形端帽以 p0 为中心向外伸 width/2——锥形长度 = tip_len + width/2
    盖住端帽，从 p0（宽 0）线性升到底边全宽。
    """
    d = p1 - p0
    ln = float(np.hypot(*d))
    if ln < 1e-6:
        return None
    dirv = d / ln
    nrm = np.array([-dirv[1], dirv[0]])
    base = p0 + dirv * (tip_len + width * 0.5)
    half = width * 0.5
    return [tuple(p0), tuple(base + nrm * half), tuple(base - nrm * half)]


def draw_road_layer(side, x0, y0, roads, shade_win, tp):
    """道路层（窗口局部，side² 底图分辨率 → ss 倍超采样）→ RGBA Image。

    每 tier 两层：casing（深棕底）→ face（赭土面 ×hillshade）。tier 顺序 DIRT 先
    PAVED 后 = 路口低级让高级（§7.2-3）。折线在 sharp_anchors 锚点处拆段绘制，
    段间 joint="curve" 只作用于段内——锐折角不被圆角化（之字保留）。
    """
    ss = int(tp["ss"])
    S = side * ss
    margin = float(tp["cull_margin_px"])
    tip = float(tp["tip_px"]) * ss
    sh_k = float(tp["shade_strength"])
    x1, y1 = x0 + side, y0 + side

    # 窗口内折线预筛（bbox 相交，外扩 margin）
    in_view = []
    for tier, pts, sharp in roads:
        if (pts[:, 0].max() < x0 - margin or pts[:, 0].min() > x1 + margin
                or pts[:, 1].max() < y0 - margin or pts[:, 1].min() > y1 + margin):
            continue
        in_view.append((tier, pts, sharp))

    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    # hillshade 窗口 → ss 倍放大（face 乘法用，uint8 灰度 → float）
    sh_img = Image.fromarray(
        (np.clip(shade_win, 0.0, 4.0) * 64.0).astype(np.uint8)).resize((S, S), Image.BILINEAR)
    shade = np.asarray(sh_img, np.float32) / 64.0
    shade = 1.0 + (shade - 1.0) * sh_k

    for tier in ("DIRT", "PAVED"):
        recs = [(pts, sharp) for t, pts, sharp in in_view if t == tier]
        if not recs:
            continue
        w = float(tp["width_px"].get(tier, 1.2))
        cw = max(1, round((w + float(tp["case_extra_px"])) * ss))
        fw = max(1, round(w * ss))
        case_col = tuple(tp["case_color"].get(tier, tp["case_color"]["DIRT"]))
        face_col = tuple(tp["face_color"].get(tier, tp["face_color"]["DIRT"]))

        case_layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        dc = ImageDraw.Draw(case_layer)
        face_layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        df = ImageDraw.Draw(face_layer)
        for pts, sharp in recs:
            pix = (pts - np.array([x0, y0])) * ss
            # sharp 锚点拆段（锚点 = 段共享边界，折角不参与 joint 圆角化）
            if sharp:
                cuts = sorted(i for i in sharp if 0 < i < len(pix) - 1)
                segs = []
                lo = 0
                for ci in cuts:
                    segs.append(pix[lo:ci + 1])
                    lo = ci
                segs.append(pix[lo:])
            else:
                segs = [pix]
            for seg in segs:
                if len(seg) < 2:
                    continue
                dc.line([tuple(p) for p in seg], fill=case_col + (255,), width=cw,
                        joint="curve")
                df.line([tuple(p) for p in seg], fill=face_col + (255,), width=fw,
                        joint="curve")
            # 端部收尖：两端各一锥形（casing/face 同步，先主体后锥盖住方形端帽）
            for a, b in ((0, 1), (len(pix) - 1, len(pix) - 2)):
                tri_c = _tip_polygon(pix[a], pix[b], float(cw), tip)
                if tri_c:
                    dc.polygon(tri_c, fill=case_col + (255,))
                tri_f = _tip_polygon(pix[a], pix[b], float(fw), tip)
                if tri_f:
                    df.polygon(tri_f, fill=face_col + (255,))
        # 路面乘 hillshade（casing 不乘——底衬保持深色统一，§7.2-3 Imhof 原理）
        arr = np.asarray(face_layer).copy()
        arr[..., :3] = np.clip(arr[..., :3].astype(np.float32) * shade[..., None], 0, 255)
        # 合成顺序：casing 底在下，shaded face 盖其上（§7.2-3 双层描边）
        canvas.alpha_composite(case_layer)
        canvas.alpha_composite(Image.fromarray(arr))
    return canvas


def bake_travel_pack(json_path, fields, colors, lp, tp, v2_roads):
    """单包交通变体：地形底图 + 道路层（ss 超采样后降回 1x 合成）→ l1_travel.png。"""
    with open(json_path, encoding="utf-8") as f:
        world = json.load(f)
    wo = world.get("world_origin")
    csz = world.get("context_size")
    if not wo or not csz:
        return False
    x0, y0 = int(wo[0]), int(wo[1])
    side = int(csz[0])
    if x0 < 0 or y0 < 0 or x0 + side > SIZE_FULL or y0 + side > SIZE_FULL:
        return False
    sl = (slice(y0, y0 + side), slice(x0, x0 + side))
    rgb = render_window(sl, fields, colors, lp["biome_blend_sigma"])
    base = Image.fromarray(rgb).convert("RGBA")
    ss = int(tp["ss"])
    layer = draw_road_layer(side, x0, y0, v2_roads, fields["shade"][sl], tp)
    if ss > 1:
        layer = layer.resize((side, side), Image.LANCZOS)
    base.alpha_composite(layer)
    out = os.path.join(os.path.dirname(json_path), tp["texture_name"])
    base.convert("RGB").save(out)
    print("  %s [travel]: %d² -> %.1f MB" % (
        os.path.basename(os.path.dirname(json_path)) or "spawn",
        side, os.path.getsize(out) / 1048576), flush=True)
    return True


def main():
    ap = argparse.ArgumentParser(description="L1 地形底图烘焙（R9，B2 同管线 per-L1 裁切）")
    ap.add_argument("--pack", nargs="*", help="只处理指定包（目录名如 l1_001；spawn = 出生包）")
    ap.add_argument("--spawn-only", action="store_true", help="只跑出生包（调参快速预览）")
    args = ap.parse_args()

    t0 = time.time()
    p = load_params()
    lp = p["l1"]
    tp = lp.get("travel")   # R4 交通变体配置（缺省 = 只烘 terrain，向后兼容）
    colors = {
        "rock": np.array(p["colors"]["rock"], dtype=np.float32),
        "snow": np.array(p["colors"]["snow"], dtype=np.float32),
        "ocean_near": np.array(p["colors"]["ocean_near"], dtype=np.float32),
        "ocean_far": np.array(p["colors"]["ocean_far"], dtype=np.float32),
        "lake": np.array(p["colors"]["lake"], dtype=np.float32),
        "river": np.array(p["colors"]["river"], dtype=np.float32),
    }

    print("[1/2] 加载 B2 全局场（terrain_render 同源）...", flush=True)
    elev, land, lake, river, labels8, hot8 = tr.load_inputs()
    shade, ocean_edt, lake_in, coast_dark, river_a = tr.build_fields(
        elev, land, lake, river, p)
    # EDT 返回 float64，压成 float32 减半内存（8192² 场 ×2）
    fields = {"labels8": labels8, "elev": elev, "land": land, "lake": lake,
              "shade": shade, "ocean_edt": ocean_edt.astype(np.float32),
              "lake_in": lake_in.astype(np.float32), "coast_dark": coast_dark,
              "river_a": river_a, "hot8": hot8, "p": p}

    v2_roads = None
    if tp:
        print("[1.5/2] 加载 R6 自然化道路（travel 变体）...", flush=True)
        v2_roads = load_v2_roads(tp)

    print("[2/2] 逐包烘焙...", flush=True)
    packs = list_packs()
    if args.pack:
        want = set(args.pack)
        packs = [(jp, name) for jp, name in packs
                 if name in want or (name.startswith("spawn") and "spawn" in want)]
    elif args.spawn_only:
        packs = packs[:1]
    ok = 0
    for jp, name in packs:
        good = bake_pack(jp, fields, colors, lp, lp["texture_name"])
        if good and v2_roads:
            good = bake_travel_pack(jp, fields, colors, lp, tp, v2_roads)
        if good:
            ok += 1
    print("完成 %d/%d 包，总耗时 %.1fs" % (ok, len(packs), time.time() - t0), flush=True)
    if ok < len(packs):
        sys.exit(1)


if __name__ == "__main__":
    main()
