"""世界重生成 v2 A1：资源禀赋与宜居度场（fields_build.py）

从底图（高程/河流/湖泊/群系）派生三套场，与现有 mask 同网格（8192 级，
左上原点 y 向下）：
  - 资源丰度场 ×4：矿脉 / 沃土 / 林产 / 渔盐——群系先验 × FBM 空间自相关扰动
    （禁白噪声，资源成带成片；FBM 频率/幅度每类独立，矿脉用 ridged FBM）
  - 宜居度场 suitability：分群系基线 × 水因子（河流密度核卷积 + 湖泊/海岸距离）
    × 坡度罚 + 资源增益饱和曲线（荒漠基线低、河谷/绿洲成局部高点）
  - 进攻成本场 attack_cost：坡度/植被/沙漠通行性 × 河流穿越罚 × 跨海（跨湖）罚，
    [1,∞) 量纲，供 A4 国家合并边权「沿线积分」直接消费

产物（tools/worldgen/output/fields/，gitignored 不入库）：
  mineral.npy / fertile.npy / forest.npy / fishsalt.npy（float16 8192²）
  suitability.npy（float16） / attack_cost.npy（float32，保留积分精度）
  fields_meta.json（分辨率/坐标系/统计摘要/消费口径）
预览（数据自检用，下采样 2048）：
  fields_preview_suitability_2048.png / fields_preview_resources_2048.png
  fields_preview_attack_cost_2048.png

用法：
  python fields_build.py [--skip-preview]
同 seed（fields_v2.fields_seed）逐位确定。
"""

import argparse
import json
import os
import sys

import numpy as np
from PIL import Image
from scipy.ndimage import binary_dilation, distance_transform_edt, gaussian_filter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fields_common as fc  # noqa: E402

C = 4096  # 计算分辨率（= params fields_v2.compute_size；常数仅作初始缓存形状参考）


# ---------- 输入（计算分辨率级） ----------

def load_inputs_compute(cs):
    """底图 → 计算分辨率 cs 级：elev 块均值、river/lake 掩膜 max-pool、群系块复制。"""
    hm = np.load(os.path.join(fc.OUTPUT_DIR, "fractal_heightmap_8192.npy"))
    elev = fc.downsample_mean(hm, cs)
    del hm
    k8 = fc.SIZE_FULL // cs
    river = np.array(Image.open(
        os.path.join(fc.OUTPUT_DIR, "fractal_river_mask_8192.png")).convert("L"))
    river = (river.reshape(cs, k8, cs, k8) > 127).any(axis=(1, 3))
    lake = np.asarray(Image.open(
        os.path.join(fc.OUTPUT_DIR, "fractal_lake_mask_8192.png")).convert("L"))
    lake = (lake.reshape(cs, k8, cs, k8) > 0).any(axis=(1, 3))
    kb = cs // fc.SIZE
    biome = np.repeat(np.repeat(
        np.load(os.path.join(fc.OUTPUT_DIR, "biome_labels_2048.npy")), kb, axis=0),
        kb, axis=1)
    return elev, river, lake, biome


def lut_from_dict(d, default):
    """JSON 的 {"群系标签": 值} → 长度 7 的 LUT 数组（缺项 default）。"""
    lut = np.full(7, float(default), dtype=np.float32)
    for k, v in d.items():
        lut[int(k)] = float(v)
    return lut


# ---------- 资源先验 ----------

def prior_mineral(elev, biome, land, spec):
    """矿脉先验：高程带线性爬升 + 火山/荒漠加成（陆地内）。"""
    lo, hi = float(spec["mount_elev_lo"]), float(spec["mount_elev_hi"])
    m = np.clip((elev - lo) / max(hi - lo, 1e-6), 0.0, 1.0)
    p = (float(spec["base"]) + float(spec["mountain_gain"]) * m
         + float(spec["volcanic_bonus"]) * (biome == fc.BI_VOLCANIC)
         + float(spec["desert_bonus"]) * (biome == fc.BI_DESERT))
    return np.clip(p, 0.0, 1.0) * land


def prior_from_biome(biome, land, spec, river_n=None):
    """群系表驱动先验（沃土/林产），可选河流沿岸加成。"""
    p = lut_from_dict(spec["biome_prior"], 0.0)[biome]
    if river_n is not None and float(spec.get("river_bonus", 0.0)) > 0.0:
        p = p + float(spec["river_bonus"]) * river_n
    return np.clip(p, 0.0, 1.0) * land


def prior_fishsalt(coast_dist, lake_dist, biome, land, spec):
    """渔盐先验：海岸带 + 湖泊沿岸指数衰减，荒漠内陆小基线（盐碱）。"""
    p = (float(spec["coast_gain"]) * np.exp(-coast_dist / float(spec["coast_tau_px"]))
         + float(spec["lake_gain"]) * np.exp(-lake_dist / float(spec["lake_tau_px"]))
         + float(spec["desert_base"]) * (biome == fc.BI_DESERT))
    return np.clip(p, 0.0, 1.0) * land


# ---------- 统计 ----------

def field_stats(v, m):
    """掩膜内统计摘要（float32 视角）。"""
    x = v[m].astype(np.float64)
    if x.size == 0:
        return {"min": 0.0, "max": 0.0, "mean": 0.0, "median": 0.0,
                "p10": 0.0, "p90": 0.0}
    q = np.quantile(x, [0.1, 0.5, 0.9])
    return {"min": round(float(x.min()), 4), "max": round(float(x.max()), 4),
            "mean": round(float(x.mean()), 4), "median": round(float(q[1]), 4),
            "p10": round(float(q[0]), 4), "p90": round(float(q[2]), 4)}


# ---------- 预览 ----------

def save_preview(img, path, title, font):
    from PIL import ImageDraw
    if isinstance(img, np.ndarray):
        img = Image.fromarray(img)
    canvas = Image.new("RGB", (img.width + 40, img.height + 70), (14, 16, 22))
    canvas.paste(img, (20, 50))
    dr = ImageDraw.Draw(canvas)
    dr.text((20, 12), title, font=font, fill=(240, 240, 245))
    canvas.save(path)


def make_previews(suit, attack, res, river, lake, land, out_dir, font):
    """三张自检预览（下采样 2048）：宜居度热图 / 资源叠图 / 进攻成本图。"""
    pv = 2048

    # 1) 宜居度热图（河流描蓝、湖泊描青，验收「热区贴河」）
    s_img = Image.fromarray(fc.colormap(
        fc.upsample_bilinear(suit, pv), fc.HEAT_STOPS))
    s = np.asarray(s_img).copy()
    r_pv = fc.downsample_mask_max(river, pv)
    l_pv = fc.downsample_mask_max(lake, pv)
    s[r_pv] = (70, 130, 200)
    s[l_pv] = (90, 170, 190)
    save_preview(s, os.path.join(out_dir, "fields_preview_suitability_2048.png"),
                 "A1 宜居度场 suitability（蓝=河 青=湖；热区应贴河/平原，荒漠冰原低值）", font)

    # 2) 资源叠图：R=矿 G=沃土 B=渔盐，林产单独一格（与沃土同绿色系会混）
    def to_pv(v):
        return fc.upsample_bilinear(v, pv)

    rgb = np.zeros((pv, pv, 3), dtype=np.float32)
    rgb[..., 0] = to_pv(res["mineral"])
    rgb[..., 1] = to_pv(res["fertile"])
    rgb[..., 2] = to_pv(res["fishsalt"])
    rgb = (np.clip(rgb, 0, 1) * 255 + 0.5).astype(np.uint8)
    forest_rgb = (fc.colormap(to_pv(res["forest"]), fc.HEAT_STOPS))
    grid = Image.new("RGB", (pv * 2 + 30, pv + 20), (14, 16, 22))
    grid.paste(Image.fromarray(rgb), (10, 10))
    grid.paste(Image.fromarray(forest_rgb), (pv + 20, 10))
    from PIL import ImageDraw
    dr = ImageDraw.Draw(grid)
    dr.text((12, pv - 26), "左：R矿 G沃土 B渔盐 叠图    右：林产丰度", font=font,
            fill=(240, 240, 245))
    grid.save(os.path.join(out_dir, "fields_preview_resources_2048.png"))

    # 3) 进攻成本（log1p 归一；水体恒罚单独涂色不进色带）
    a = np.log1p(attack.astype(np.float32))
    a_norm = a / max(float(np.quantile(a[land], 0.98)), 1e-6)
    a_img = fc.colormap(to_pv(np.clip(a_norm, 0, 1)), fc.COST_STOPS)
    a_arr = np.asarray(a_img).copy()
    sea_pv = fc.downsample_mask_max(~land, pv)
    a_arr[sea_pv] = (26, 34, 58)
    a_arr[r_pv] = (120, 180, 235)
    a_arr[l_pv] = (120, 180, 235)
    save_preview(a_arr, os.path.join(out_dir, "fields_preview_attack_cost_2048.png"),
                 "A1 进攻成本场 attack_cost（暗=易攻 亮=难攻 蓝=水体恒罚；山脊/密林应高值）", font)


# ---------- 主流程 ----------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-preview", action="store_true")
    args = ap.parse_args()

    P = fc.load_params()
    fp = P["fields_v2"]
    cs = int(fp["compute_size"])
    rng = np.random.default_rng(int(fp["fields_seed"]))

    print("[1/6] 读底图（计算分辨率 %d 级）..." % cs, flush=True)
    elev, river, lake, biome = load_inputs_compute(cs)
    land = biome > 0            # 群系意义的陆地（含源流带；湖泊=源流群系，另行排除）
    water_body = (biome == fc.BI_OCEAN) | lake
    eff_land = land & (~lake)   # 有效陆地（资源/宜居的作用域）

    gy, gx = np.gradient(elev)
    gradmag = np.sqrt(gy * gy + gx * gx).astype(np.float32)
    del gy, gx

    print("[2/6] 水因子（河流密度卷积 / 湖海距离）...", flush=True)
    wp = fp["water"]
    dens = gaussian_filter(river.astype(np.float32), float(wp["river_sigma_px"]))
    q = float(np.quantile(dens[eff_land], float(wp["river_norm_quantile"])))
    river_n = np.clip(dens / max(q, 1e-6), 0.0, 1.0)
    del dens
    coast_dist = distance_transform_edt(land).astype(np.float32)   # 陆地内距海
    lake_dist = distance_transform_edt(~lake).astype(np.float32)   # 距最近湖
    water = (float(wp["w_river"]) * river_n
             + float(wp["w_lake"]) * np.exp(-lake_dist / float(wp["lake_tau_px"]))
             + float(wp["w_coast"]) * np.exp(-coast_dist / float(wp["coast_tau_px"])))
    water = water * lut_from_dict(wp["biome_multiplier"], 1.0)[biome]

    print("[3/6] 资源丰度场 ×4（群系先验 × FBM）...", flush=True)
    rs = fp["resources"]
    floor = float(rs["floor"])
    priors = {
        "mineral": prior_mineral(elev, biome, eff_land, rs["mineral"]),
        "fertile": prior_from_biome(biome, eff_land, rs["fertile"], river_n),
        "forest": prior_from_biome(biome, eff_land, rs["forest"], river_n),
        "fishsalt": prior_fishsalt(coast_dist, lake_dist, biome, eff_land,
                                   rs["fishsalt"]),
    }
    res = {}
    for name in ("mineral", "fertile", "forest", "fishsalt"):
        f = fc.fbm(elev.shape, rng, rs[name]["fbm"])
        res[name] = np.clip(priors[name] * (floor + (1.0 - floor) * f),
                            0.0, 1.0).astype(np.float32)
        priors[name] = None  # 释放

    print("[4/6] 宜居度合成...", flush=True)
    sp = fp["suitability"]
    sq = float(np.quantile(gradmag[land], float(sp["slope_norm_quantile"])))
    slope_n = np.clip(gradmag / max(sq, 1e-6), 0.0, float(sp["slope_cap"]))
    suit = (lut_from_dict(sp["biome_base"], 0.0)[biome] + water
            - float(sp["slope_penalty"]) * slope_n)
    gain = (float(sp["w_mineral"]) * res["mineral"]
            + float(sp["w_fertile"]) * res["fertile"]
            + float(sp["w_forest"]) * res["forest"]
            + float(sp["w_fishsalt"]) * res["fishsalt"])
    suit = suit + float(sp["gain_max"]) * np.tanh(gain / float(sp["gain_norm"]))
    suit = np.clip(suit, 0.0, 1.0).astype(np.float32)
    suit[water_body] = 0.0

    print("[5/6] 进攻成本场...", flush=True)
    acp = fp["attack_cost"]
    mob = (1.0 + float(acp["c_slope"]) * slope_n
           + float(acp["c_veg"]) * lut_from_dict(acp["veg_by_biome"], 0.3)[biome])
    if int(acp["river_band_px"]) > 0:
        band = binary_dilation(river, iterations=int(acp["river_band_px"]))
    else:
        band = river
    attack = np.where(water_body, float(acp["k_water_cost"]),
                      mob * np.where(band, float(acp["k_river_cross"]),
                                     1.0)).astype(np.float32)

    print("[6/6] 上采样 8192 + 落盘...", flush=True)
    os.makedirs(fc.FIELDS_DIR, exist_ok=True)

    # 8192 级原生水体掩膜（biome 块复制 + 湖泊 png）：连续项 bilinear 平滑，
    # 但水体必须严格清零/恒值——bilinear 会把陆地值渗进沿岸水体像素
    biome8 = fc.upsample_nearest(biome, fc.SIZE_FULL)
    lake8 = np.asarray(Image.open(
        os.path.join(fc.OUTPUT_DIR, "fractal_lake_mask_8192.png")).convert("L")) > 0
    water8 = (biome8 == fc.BI_OCEAN) | lake8
    del biome8, lake8

    def save_f16(name, v):
        up = fc.upsample_bilinear(v, fc.SIZE_FULL)
        up[water8] = 0.0
        np.save(os.path.join(fc.FIELDS_DIR, name + ".npy"),
                up.astype(np.float16))

    save_f16("mineral", res["mineral"])
    save_f16("fertile", res["fertile"])
    save_f16("forest", res["forest"])
    save_f16("fishsalt", res["fishsalt"])
    save_f16("suitability", suit)
    # attack_cost：水体恒值 k_water_cost，河流带乘罚用块复制掩膜在 8192 级 assert
    mob8 = fc.upsample_bilinear(mob, fc.SIZE_FULL)
    band8 = fc.upsample_nearest(band, fc.SIZE_FULL)
    attack8 = np.where(water8, float(acp["k_water_cost"]),
                       mob8 * np.where(band8, float(acp["k_river_cross"]),
                                       1.0)).astype(np.float32)
    np.save(os.path.join(fc.FIELDS_DIR, "attack_cost.npy"), attack8)
    del mob8, water8, band8, attack8

    # 统计摘要（计算分辨率级即可代表；上采样不改变分布）
    stats = {
        "suitability": field_stats(suit, eff_land),
        "attack_cost": field_stats(attack, eff_land),
    }
    for name in res:
        stats[name] = field_stats(res[name], eff_land)
    stats["suitability"]["plains_median"] = round(float(
        np.median(suit[eff_land & (biome == fc.BI_PLAIN)].astype(np.float64))), 4)
    stats["suitability"]["desert_median"] = round(float(
        np.median(suit[eff_land & (biome == fc.BI_DESERT)].astype(np.float64))), 4)
    stats["suitability"]["ice_median"] = round(float(
        np.median(suit[eff_land & (biome == fc.BI_ICE)].astype(np.float64))), 4)

    meta = {
        "generated_by": "fields_build.py",
        "params_source": "state_params.json#fields_v2",
        "fields_seed": int(fp["fields_seed"]),
        "resolution": fc.SIZE_FULL,
        "coords": "与 fractal_*_mask_8192 / l3_political_id_8192 同网格：左上原点、"
                  "y 向下；群系/region 标签底图原生 2048 级，此处块复制到 8192",
        "compute_note": "FBM/卷积/EDT 在 %d 级计算，连续场 bilinear 上采样 ×%d（见 "
                        "fields_v2.compute_size_comment）" % (cs, fc.SIZE_FULL // cs),
        "dtype": {"resources/suitability": "float16", "attack_cost": "float32"},
        "ocean_value": {"suitability": 0, "resources": 0,
                        "attack_cost": "k_water_cost（水体恒值罚）"},
        "consumption_notes": {
            "A3": "聚落密度/规模直接采样 suitability 与资源场（宜先排除水体："
                  "ocean=biome0 或 lake 掩膜）",
            "A4": "geo_cost(edge) = attack_cost 沿连线采样积分（采样均值×距离）；"
                  "河流带已膨胀 river_band_px 防稀疏采样漏罚",
        },
        "stats": stats,
    }
    with open(os.path.join(fc.FIELDS_DIR, "fields_meta.json"), "w",
              encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=1)

    print("\n=== A1 场统计摘要（有效陆地）===")
    for k, v in stats.items():
        print("  %-12s %s" % (k, v))
    print("贫瘠/富庶对照：平原中位 %.3f vs 荒漠 %.3f / 冰原 %.3f" % (
        stats["suitability"]["plains_median"],
        stats["suitability"]["desert_median"],
        stats["suitability"]["ice_median"]))

    if not args.skip_preview:
        make_previews(suit, attack, res, river, lake, land, fc.FIELDS_DIR,
                      fc.fit_font(22))
        print("预览：output/fields/fields_preview_{suitability,resources,"
              "attack_cost}_2048.png")

    print("完成。产物在 %s（gitignored）" % fc.FIELDS_DIR)


if __name__ == "__main__":
    main()
