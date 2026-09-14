# -*- coding: utf-8 -*-
"""export_city_layout.py —— 把 city_layout 的城镇平面布局导出成 HD-2D 场景布局 JSON。

city_layout.plan_city()（纯 Python，无 bpy 依赖）按规模档+seed 确定性求解城镇平面：
每栋建筑 def/格宽/排位/功能区/材质 + 城墙 + 道路 + 街面道具。本脚本把它换算成
HD-2D 场景（tests/dev/proto_hd2d）能直接消费的布局 JSON：

  - cell 1:1（city_layout 的 CELL_W=32px 与 HD-2D 的 1 格=32px 天然一致）；
  - row 0（临街排）→ HD-2D 前排；row ≥1 → 背景层 layer（bg1 起）；
  - def → 烘焙卡名：按卡库实际档位挑 `def_w<W>`；特殊映射
    church→cathedral_w16、plaster_house→house（卡库无灰泥屋装配器，取木筋屋近似）；
    market_stall/well 走道具卡（props 层）；
  - 街面 props（barrel/crate/hay/cart…）→ HD-2D 道具；tree → 自然物卡（可采集）。

跑法（纯 Python，不用 Blender）::

    python tools/blender_buildings/export_city_layout.py --tier village --seed 611036 --name village_b

产物：stick-world/tests/dev/proto_hd2d/tex/hd2d_layouts/<name>.json（随包入库）
"""

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import city_layout as CL  # noqa: E402

REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT_DIR = os.path.join(REPO, "stick-world", "tests", "dev", "proto_hd2d", "tex", "proto_hd2d", "hd2d_layouts")
CARDS_JSON = os.path.join(REPO, "stick-world", "tests", "dev", "proto_hd2d", "tex", "proto25d", "cards.json")
PROPS_JSON = os.path.join(REPO, "stick-world", "tests", "dev", "proto_hd2d", "tex", "proto_hd2d", "props.json")
NATURE_JSON = os.path.join(REPO, "stick-world", "tests", "dev", "proto_hd2d", "tex", "proto_hd2d", "nature.json")

#: def → 卡库 def 名的特判映射（其余 def 原名找 `def_w<W>`）
DEF_TO_CARD_DEF = {
    "church": "cathedral",       # 卡库教堂装配器名是 cathedral
    "plaster_house": "house",    # 无灰泥屋装配器，取木筋屋近似（卡面差异可接受）
    "chapel": "tower",           # 小礼拜堂无装配器，取塔楼近似（观感落差已登记）
}

#: 布局 def 走道具层的（HD-2D 的 props 卡而非建筑卡）
PROP_DEFS = {"market_stall", "well"}

#: 宏伟建筑给门前短径
DOOR_DEFS = {"guildhall", "gatehouse", "tavern", "church", "barracks", "windmill"}

#: 布局道具 kind → HD-2D 道具卡
PROP_KIND_MAP = {
    "barrel": "barrel", "crate": "crate", "hay": "haystack", "cart": "cart",
    "log": "log_pile", "bench": "bench", "lantern": "lantern",
}

#: 树道具 → 自然物卡池（bake_nature 的卡）与采集类型
TREE_CARDS = [("broadleaf", "wood"), ("conifer", "wood"), ("bush", "")]


def _load_card_defs(path):
    """卡库名集合 + {def 名: [可用格宽档]} + {卡名: 画面宽(格)}。"""
    with open(path, encoding="utf-8") as f:
        cards = json.load(f)
    by_def = {}
    widths = {}
    for c in cards:
        name = c["card"]
        d, w = name.rsplit("_w", 1)
        by_def.setdefault(d, []).append(int(w))
        widths[name] = c["units"][0] / 32.0   # px -> 格
    return by_def, widths


def card_w(by_def_cards, card_name):
    return by_def_cards.get(card_name, 8.0)


def _pick_card(by_def, def_name, w_cells):
    """从卡库挑 `def_w<W>`：先精确 w_cells，再向外找最近的 4 的倍数档。"""
    d = DEF_TO_CARD_DEF.get(def_name, def_name)
    avail = sorted(by_def.get(d, []))
    if not avail:
        return None
    if w_cells in avail:
        return "%s_w%d" % (d, w_cells)
    for delta in (4, 8, 12):
        for w in (w_cells - delta, w_cells + delta):
            if w in avail:
                return "%s_w%d" % (d, w)
    return "%s_w%d" % (d, avail[-1])


def _resolve_overlaps(bs, card_widths):
    """同排推挤：city_layout 的 x 是墙格位（相邻可贴），烘焙卡画面含出檐
    比格宽宽 2~5 格——直接摆会互相压（创始人 2026-09-14 指正）。按 x 排序
    逐栋保证画面间隙 ≥0.6 格，推完整体平移回质心 0（保持中心化坐标系）。"""
    GAP = 0.6
    bs = sorted(bs, key=lambda b: b["x"])
    for i in range(1, len(bs)):
        need = (card_widths[bs[i - 1]["card"]] + card_widths[bs[i]["card"]]) / 2.0 + GAP
        if bs[i]["x"] < bs[i - 1]["x"] + need:
            bs[i]["x"] = bs[i - 1]["x"] + need
    if bs:
        shift = -sum(b["x"] for b in bs) / len(bs)
        for b in bs:
            b["x"] += shift
    return bs


def export(name, tier, seed):
    plan = CL.plan_city(tier, seed=seed)
    by_def, by_def_cards = _load_card_defs(CARDS_JSON)
    with open(PROPS_JSON, encoding="utf-8") as f:
        prop_cards = {c["card"] for c in json.load(f)}
    with open(NATURE_JSON, encoding="utf-8") as f:
        nature_cards = {c["card"] for c in json.load(f)}

    buildings = []
    props = []
    trees = []
    skipped = []
    # x 中心化：布局以 0 为中心（与 HD-2D 主街/相机横移/出生点同坐标系）
    half = plan["width_px"] / plan["cell_w"] / 2.0
    for l in plan["lots"]:
        d = l["def"]
        w = l["w_cells"]
        cx = sum(l["x_cells"]) / 2.0 - half
        if d in PROP_DEFS:
            card = d if d in prop_cards else None
            if card is None:
                skipped.append((d, "无道具卡"))
                continue
            props.append({"card": card, "x": cx, "z": 4.6, "plat": False, "row": l["row"]})
            continue
        card = _pick_card(by_def, d, w)
        if card is None:
            skipped.append((d, "无装配卡"))
            continue
        buildings.append({
            "card": card, "def": d, "x": cx, "cells": w, "row": l["row"],
            "door": d in DOOR_DEFS,
            "zone": l.get("zone", ""), "wall_mat": l.get("wall_mat", ""),
            "roof_mat": l.get("roof_mat", ""),
        })

    for p in plan["props"]:
        kind = p["kind"]
        cx = sum(p["x_cells"]) / 2.0 - half
        if kind == "tree":
            card, res = TREE_CARDS[hash((p["x_cells"][0], seed)) % len(TREE_CARDS)]
            if card in nature_cards:
                trees.append({"card": card, "x": cx, "z": 5.5, "res": res})
            continue
        card = PROP_KIND_MAP.get(kind)
        if card is None or card not in prop_cards:
            continue
        props.append({"card": card, "x": cx, "z": 5.2, "plat": False, "row": 0})

    # 同排推挤（卡画面宽含出檐，修正布局格位直摆的重叠）
    card_widths = {}
    for b in buildings:
        card_widths.setdefault(b["card"], card_w(by_def_cards, b["card"]))
    rows_map = {}
    for b in buildings:
        rows_map.setdefault(b["row"], []).append(b)
    for row_bs in rows_map.values():
        _resolve_overlaps(row_bs, card_widths)

    out = {
        "name": name, "tier": tier, "seed": seed,
        "cell_w": plan["cell_w"], "width_cells": int(plan["width_px"] // plan["cell_w"]),
        "buildings": buildings, "props": props, "trees": trees,
        "skipped": skipped,
    }
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, name + ".json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
    print("[export] %s: %d 建筑（前排 %d）+ %d 道具 + %d 树，跳过 %s -> %s"
          % (name, len(buildings), sum(1 for b in buildings if b["row"] == 0),
             len(props), len(trees), skipped or "无", path))
    return path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tier", default="village",
                    choices=("hamlet", "village", "town", "city"))
    ap.add_argument("--seed", type=int, default=611036)
    ap.add_argument("--name", default=None, help="输出文件名（缺省 <tier>_<seed>）")
    args = ap.parse_args()
    export(args.name or ("%s_%d" % (args.tier, args.seed)), args.tier, args.seed)


if __name__ == "__main__":
    main()
