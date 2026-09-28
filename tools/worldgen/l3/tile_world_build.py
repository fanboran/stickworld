# -*- coding: utf-8 -*-
"""地块世界属性重生成（V2-属性层，已废弃路线）。

已废弃：城块定稿走 settlements/city_split_v3 链（见 worldgen README §V2）。
在**既有 1048 地块网格**（最初划分，几何不动）上重赋属性：
  1. 逐地块：质心（世界 8192 = 包 world_origin + 局部多边形质心）采样 A1 场
     （宜居度 / 资源 / 文化 / 群系）
  2. 聚落规模重赋（地区差异化 + 荒地语义）：
       suit_eff = suit × region_tilt[biome]（贫瘠区整体下压）
       suit_eff < dead_threshold → 规模 0（无人地块 = 无主荒地）
       否则 population_score = clamp(h(suit_eff, res) × LogNormal(μ_b, σ_b), 0, 1)
       level 按 0.187/0.342（场景口径）
  3. 输出 `output/fields/settlements_v2.json`（state_build_v2 直接消费的输入形；
     规模 0 的地块**不写入**=不参与政权划分）
     + `tile_meta.json`（地块↔包/索引映射，供回写）

用法：python tile_world_build.py
"""
import glob
import json
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fields_common as fc  # noqa: E402

FIELDS = fc.FIELDS_DIR
GAME = fc.GAME_CFG


def main():
    P = fc.load_params()["fields_v2"]
    ssp = P["settlements"]
    stp = P["states_v2"]["spectrum"]
    tilt = stp.get("region_tilt", {})

    suit = np.load(os.path.join(FIELDS, "suitability.npy")).astype(np.float32)
    rkeys = ["mineral", "fertile", "forest", "fishsalt"]
    res = {k: np.load(os.path.join(FIELDS, k + ".npy")).astype(np.float32)
           for k in rkeys}
    domf = np.load(os.path.join(FIELDS, "culture_field.npy"))
    mixf = np.load(os.path.join(FIELDS, "culture_mix.npy"))
    biome = np.load(os.path.join(fc.OUTPUT_DIR, "biome_labels_2048.npy"))
    S = biome.shape[0]  # 2048

    def to2048(a):
        return np.asarray(a)[::4, ::4] if np.asarray(a).shape[0] != S else np.asarray(a)

    suit = to2048(suit)
    res = {k: to2048(v) for k, v in res.items()}
    domf = to2048(domf)
    mixf = to2048(mixf)
    K = fc.SIZE / fc.SIZE_FULL  # 8192 → 2048（质心坐标换算）

    rw = ssp["resource_weights"]
    gn = float(ssp["gain_norm"])
    hws = float(ssp["h_w_suit"])
    hwr = float(ssp["h_w_res"])
    dead = float(ssp.get("suit_min", 0.16))  # 与聚落生成同口径：低于此=无聚落
    mu_bands = ssp.get("mu_by_band", [-1.25, -1.05, -0.85, -0.62])
    sigma = float(ssp.get("sigma_b", 0.5))
    bq = ssp.get("band_quantiles", [0.25, 0.5, 0.75])
    rng = np.random.default_rng(int(ssp.get("seed", 7)))

    # 宜居度分位带（全局陆地）
    land = biome > 0
    qs = [float(np.quantile(suit[land], q)) for q in bq]
    print("宜居度分位（%s）: %s" % (bq, [round(q, 3) for q in qs]))

    def band_mu(sv):
        for i, q in enumerate(qs):
            if sv < q:
                return mu_bands[i]
        return mu_bands[-1]

    packs = [("", os.path.join(GAME, "l1_world.json"))]
    for name in sorted(os.listdir(os.path.join(GAME, "l1_packs"))):
        p = os.path.join(GAME, "l1_packs", name, "l1_world.json")
        if os.path.isfile(p):
            packs.append((name, p))

    out = []
    meta = []
    label = 0
    n_dead = 0
    for pname, ppath in packs:
        d = json.load(open(ppath, encoding="utf-8"))
        wo = d.get("world_origin")
        for ti, t in enumerate(d.get("tiles", [])):
            label += 1
            poly = t.get("polygon") or []
            if not poly and t.get("polygons"):
                poly = t["polygons"][0]
            if not poly:
                continue
            arr = np.asarray(poly, dtype=np.float64)
            cx = float(arr[:, 0].mean()) + float(wo[0])
            cy = float(arr[:, 1].mean()) + float(wo[1])
            sx, sy = min(int(cx * K), S - 1), min(int(cy * K), S - 1)
            sv = float(suit[sy, sx])
            b = int(biome[sy, sx])
            f = float(tilt.get(str(b), 1.0))
            sv_eff = max(0.0, min(1.0, sv * f))
            r = 0.0
            for rk, wk in rw.items():
                r += float(wk) * float(res[rk][sy, sx])
            r = math.tanh(r / gn)
            h = hws * sv_eff + hwr * r
            dead_here = sv_eff < dead
            if dead_here:
                ps = 0.0
                lev = 0
                n_dead += 1
            else:
                mu = band_mu(sv_eff)
                ps = float(np.clip(h * math.exp(rng.normal(mu, sigma)), 0.0, 1.0))
                lev = 1 if ps < 0.187 else (2 if ps < 0.342 else 3)
            meta.append({"pack": pname or "spawn", "idx": ti,
                         "tile_id": t.get("tile_id", ""),
                         "settlement_id": (t.get("settlement") or {}).get("settlement_id", ""),
                         "label": label, "x": round(cx, 1), "y": round(cy, 1)})
            if ps <= 0.0:
                continue  # 规模 0：不参与政权划分（无主）
            live_label = len(out) + 1
            meta[-1]["live_label"] = live_label if ps > 0 else 0
            out.append({
                "label": live_label,
                "settlement_id": "settlement_city_%03d" % live_label,
                "x": int(cx), "y": int(cy),
                "level": lev,
                "population_score": round(ps, 4),
                "dominant": int(domf[sy, sx]),
                "mix": float(mixf[sy, sx]),
            })
    print("地块 %d：规模>0 %d / 规模0（无主荒芜）%d（%.1f%%）"
          % (label, len(out), n_dead, 100.0 * n_dead / max(label, 1)))
    lv = {}
    for o in out:
        lv[o["level"]] = lv.get(o["level"], 0) + 1
    print("档位分布:", {k: lv.get(k, 0) for k in (1, 2, 3)})

    with open(os.path.join(FIELDS, "settlements_v2.json"), "w",
              encoding="utf-8", newline="\n") as f:
        json.dump({"settlements": out,
                   "meta": {"source": "tile_world_build（既有 1048 地块网格，属性重赋）",
                            "n_tiles": label, "n_live": len(out),
                            "n_dead": n_dead}}, f, ensure_ascii=False)
    with open(os.path.join(FIELDS, "tile_meta.json"), "w",
              encoding="utf-8", newline="\n") as f:
        json.dump(meta, f, ensure_ascii=False)
    print("已写 settlements_v2.json（tile 版）+ tile_meta.json")


if __name__ == "__main__":
    main()
