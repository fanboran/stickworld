# -*- coding: utf-8 -*-
"""政治数据 v2 落地注入（世界重生成 v2 Wg-3b 全链重烤）—— political_data_v2.json
（179 政权 / 1036 城真源，output/fields/）→ 游戏消费产物（config/strategic_map/）。

取代旧链 state_expand_lite.py 的注入段 + population_score.py（两步合一）：
  1. l3_city.json tiles[]：level / population_score（settlements_v2，档位阈值
     0.187/0.342 场景口径全球单一）+ state_id / culture（v2 主导文化序号）/ region
     （region_split 蒙版在聚落点位采样）+ 顶层 states（v2 179 国表）。
  2. political_data.json：v2 states + city_owners 原样落位（meta 补 id_mask 说明；
     253=无主荒地 / 254=湖泊 / 255=邻区灰底，与运行时 political_lut.gd 同码表）。
  3. --l2 模式：13 份 l2_packs/region_XXX/l2_world.json 注入 cities[].state_id +
     顶层 states——必须在 blob_bake.py 之后跑（blob_bake 整体重建 cities 数组，
     先注会被冲掉）。

与旧链的语义差异（v2）：
  - 出生 8 城邦特殊态取消：1036 城全部由 city_owners 分配给 179 国（state_v2_*），
    L1 包侧不再回灌 owner（旧链出生包 tiles[].owner_state_id 定义出生城邦，已废）。
  - 无主荒地：城块划分 v3 主张盘封顶留下的无城陆地不属任何政权，政治 ID mask 上
    为 253（reexport_political_id.py 重导时落码）。
  - culture 字段从文化圈字符串（"plain" 等 9 圈）改为 v2 文化源点序号 1..22
    （0=荒野文化，settlements_v2 dominant 直传）；culture_id/race 在 states 表。

用法：
  python tools/worldgen/l3/bake_political_v2.py          # l3_city 注入 + political_data.json
  python tools/worldgen/l3/bake_political_v2.py --l2     # 13 份 L2 packs states/state_id 注入
跑完记得：reexport_political_id.py --write（ID mask）→ l_world_bake.gd 刷 bin。
"""
import argparse
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fields_common as fc  # noqa: E402

FIELDS_DIR = fc.FIELDS_DIR
GAME_CFG = fc.GAME_CFG
K = fc.SIZE_FULL // fc.SIZE   # 4：8192 坐标 → 2048 场网格缩比

V2_DATA = os.path.join(FIELDS_DIR, "political_data_v2.json")
V2_SETTLEMENTS = os.path.join(FIELDS_DIR, "settlements_v2.json")
L3_CITY = os.path.join(GAME_CFG, "l3_city.json")
POLITICAL_DATA = os.path.join(GAME_CFG, "political_data.json")
L2_PACKS = os.path.join(GAME_CFG, "l2_packs")


def sid_of(label):
    return "settlement_city_%03d" % int(label)


def load_region2048():
    return np.load(os.path.join(fc.OUTPUT_DIR, "regions", "region_labels.npy"))


def region_at(region, x, y):
    """8192 坐标 → region label（聚落点位；0=水时螺旋找最近非零，防御贴岸点）。"""
    cx, cy = int(x) // K, int(y) // K
    v = int(region[cy, cx])
    if v > 0:
        return v
    for r in range(1, 8):
        y0, y1 = max(0, cy - r), min(region.shape[0], cy + r + 1)
        x0, x1 = max(0, cx - r), min(region.shape[1], cx + r + 1)
        win = region[y0:y1, x0:x1]
        nz = win[win > 0]
        if nz.size:
            return int(np.bincount(nz.ravel()).argmax())
    return 0


def bake_l3_and_political_data():
    with open(V2_DATA, encoding="utf-8") as f:
        v2 = json.load(f)
    states = v2["states"]
    owners = v2["city_owners"]
    n_states, n_cities = len(states), len(owners)
    with open(V2_SETTLEMENTS, encoding="utf-8") as f:
        settl = {int(s["label"]): s for s in json.load(f)["settlements"]}
    region = load_region2048()
    assert len(settl) == n_cities, "settlements_v2 与 city_owners 城数不一致"

    with open(L3_CITY, encoding="utf-8") as f:
        l3 = json.load(f)
    tiles = l3["tiles"]
    labels = sorted(int(t["label"]) for t in tiles)
    # owners 可含原址复种点（level 0，涌现制下已归政权）——l3_city tiles 只覆盖正常聚落，
    # 对齐口径 = tiles label 连续且全部在 owners 内
    assert labels == list(range(1, len(labels) + 1)), \
        "l3_city tiles label 应连续 1..N（现 %d..%d / %d 块）" % (
            labels[0], labels[-1], len(labels))
    assert all(sid_of(lb) in owners for lb in labels), \
        "l3_city tiles 存在 owners 未覆盖的城块"

    for t in tiles:
        lb = int(t["label"])
        s = settl[lb]
        t["state_id"] = owners.get(sid_of(lb), "")
        t["culture"] = int(s["dominant"])
        t["region"] = region_at(region, s["x"], s["y"])
        t["level"] = int(s["level"])
        t["population_score"] = float(s["population_score"])
    l3["states"] = states
    with open(L3_CITY, "w", encoding="utf-8") as f:
        json.dump(l3, f, ensure_ascii=False, separators=(",", ":"))
    print("l3_city.json：%d tiles 注入 state_id/culture/region/level/population_score "
          "+ 顶层 states（%d 国）" % (len(tiles), n_states))

    meta = dict(v2.get("meta", {}))
    meta["baked_by"] = "bake_political_v2.py（Wg-3b 全链重烤：political_data_v2 → 消费落位）"
    meta["id_mask"] = {
        "l3": "l3_political_id_8192.png（单通道，像素值=lut_index 1..%d；保留码 "
              "253=无主荒地（无城陆地）254=湖泊，0=海洋）" % n_states,
        "l2": "l2_packs/*/l2_political_id.png（context 窗口裁切，同编码；保留码 "
              "253=无主荒地 254=湖泊 255=邻区灰底）",
        "runtime": "PoliticalLut 查表上色（改 LUT 即全图换色，零重烘）",
    }
    pdata = {"meta": meta, "states": states, "city_owners": owners}
    with open(POLITICAL_DATA, "w", encoding="utf-8") as f:
        json.dump(pdata, f, ensure_ascii=False, indent=1)
    n_empty = sum(1 for v in owners.values() if not str(v))
    lv = {1: 0, 2: 0, 3: 0}
    for s in settl.values():
        lv[int(s["level"])] = lv.get(int(s["level"]), 0) + 1
    print("political_data.json：%d 国 / %d 城（空归属 %d）；level 1/2/3 = %d/%d/%d"
          % (n_states, n_cities, n_empty, lv[1], lv[2], lv[3]))


def bake_l2():
    with open(POLITICAL_DATA, encoding="utf-8") as f:
        pd = json.load(f)
    states, owners = pd["states"], pd["city_owners"]
    for i in range(1, 14):
        rid = "region_%03d" % i
        jp = os.path.join(L2_PACKS, rid, "l2_world.json")
        with open(jp, encoding="utf-8") as f:
            w = json.load(f)
        n_miss = 0
        for c in w.get("cities", []):
            sid = str(c.get("id", ""))
            owner = owners.get(sid, "")
            if not owner:
                n_miss += 1
            c["state_id"] = owner
        w["states"] = states
        with open(jp, "w", encoding="utf-8") as f:
            json.dump(w, f, ensure_ascii=False, separators=(",", ":"))
        print("  %s：%d 城（无归属 %d）+ states %d 国" % (
            rid, len(w.get("cities", [])), n_miss, len(states)))


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="政治数据 v2 落地注入（Wg-3b）")
    ap.add_argument("--l2", action="store_true",
                    help="只跑 13 份 L2 packs 注入（须在 blob_bake 之后）")
    args = ap.parse_args()
    if args.l2:
        bake_l2()
    else:
        bake_l3_and_political_data()
