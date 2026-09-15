# -*- coding: utf-8 -*-
"""gen_initial_city.py —— 初始城市生成器 v2（创始人 2026-09-15 裁决语义）。

与 city_layout.py（镜像五带/固定宽度）的口径差异，本脚本按新裁决实现：

  1. **长度按建筑数量算，不按百分比**：城市大小 = 建筑排完后的自然跨度 +
     墙体留边，不写死——城市因建筑变多而扩展，城墙自动前移（城墙位 =
     width/2，由运行时从布局 JSON 读）。
  2. **中心向两侧排布**：先按分区塞够建筑顺序，然后从中心向两边逐栋放，
     摆位用**画面宽**推挤（保底间隙 0.6 格），重叠在生成阶段不可能出现。
  3. **五带不对称**：核心（行政）居中；市场/工匠/居住/生产四带各自随机
     分配到左或右（种子确定性），不镜像。
  4. **特殊建筑可浮动**：教堂等不属固定分区，随机插进任意一侧序列。
  5. **居住/仓储随机塞**：房子/仓库打乱顺序进队列即可。
  6. **小村子可以没有分区**：tiny 档全部建筑随机排布（zoned=False）。
  7. **背景两层**（row1/row2），第三层废除。

跑法（纯 Python）::

    python tools/blender_buildings/gen_initial_city.py --tier starter --seed 20260915 --name hd2d_street

产物：stick-world/tests/dev/proto_hd2d/tex/proto_hd2d/hd2d_layouts/<name>.json
（HD-2D 布局契约，与 export_city_layout.py 同构：width_cells/buildings/props；
主街 tscn 设 layout_name=<name> 即吃生成结果。）
"""

from __future__ import annotations

import argparse
import json
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
CARDS_JSON = os.path.join(REPO, "stick-world", "tests", "dev", "proto_hd2d", "tex", "proto25d", "cards.json")
OUT_DIR = os.path.join(REPO, "stick-world", "tests", "dev", "proto_hd2d", "tex", "proto_hd2d", "hd2d_layouts")

MIN_GAP = 0.6          # 相邻画面保底间隙（格）
WALL_MARGIN = 3.0      # 前排最外栋到墙线的留边（格，城门转角）
DOOR_DEFS = {"guildhall", "gatehouse", "shop", "tavern", "smithy1"}
GROUND_CELLS = 30.0    # 城心石板半宽（格，≈一屏）

# ── 规模档：各分区建筑数量（创始人：城市规模只是建筑数量问题）────────
# tiny = 几个建筑随机排布无分区；hamlet = 必须建筑各一且全基础版；
# starter = 初始城镇（东西稍全、一个工区两三栋）。
TIERS = {
    "tiny":    dict(core=0, market=0, craft=1, living=3, production=1, storage=0, zoned=False),
    "hamlet":  dict(core=1, market=1, craft=1, living=3, production=1, storage=1, zoned=True),
    "starter": dict(core=1, market=2, craft=2, living=5, production=2, storage=1, zoned=True),
    "village": dict(core=1, market=3, craft=3, living=7, production=3, storage=2, zoned=True),
    "town":    dict(core=1, market=4, craft=4, living=9, production=4, storage=3, zoned=True),
}

# ── 分区 → def 池（小档全基础版；多出的高级版只在大档出现）──────────────
ZONE_POOLS = {
    "core":       ["guildhall_w12"],
    "market":     ["shop_w8", "bakery_w8", "tavern_w12", "shop_w8"],
    "craft":      ["smithy1_w8", "smithy2_w8", "smithy3_w8"],
    "living":     ["house_w16", "house_w8", "house_w8", "cottage_w6", "hayloft_w8",
                   "house_w16", "rowhouse_w12", "townhouse_w12", "cottage_w6"],
    "production": ["barn_w12", "windmill_w6", "barn_w12", "stable_w12"],
    "storage":    ["warehouse_w16", "warehouse_w16"],
}
#: 可浮动特殊建筑（不属分区，随机插进任意一侧序列任意位置）
FLOAT_DEFS = ["cathedral_w16", "mage_tower_w8", "library_w12", "tower_w6"]
#: 背景层 def 池（row1/row2，随分区锚点落）
BG_POOL = ["cathedral_w16", "mage_tower_w8", "library_w12", "tavern_w12",
           "townhouse_w12", "rowhouse_w12", "alchemy_w8", "barracks_w12",
           "smithy4_w12", "shelter_w6"]
GATE_DEF = "gatehouse_w8"

#: def → 背景归属分区（跟前排同区，锚点取该区前排跨度中心）
BG_DEF_ZONE = {
    "cathedral_w16": "core", "mage_tower_w8": "core", "library_w12": "core",
    "tower_w6": "core", "tavern_w12": "market", "townhouse_w12": "market",
    "rowhouse_w12": "living", "shelter_w6": "living",
    "alchemy_w8": "craft", "smithy4_w12": "craft", "barracks_w12": "production",
}

#: def → 门前短径 / 落地面（z≥2 不上台面）
DOOR_DEFS = {"guildhall", "gatehouse", "shop", "tavern", "smithy1"}
GROUND_DEFS = {"barn", "cottage"}


def load_card_widths() -> dict:
    with open(CARDS_JSON, encoding="utf-8") as f:
        cards = json.load(f)
    return {c["card"]: c["units"][0] / 32.0 for c in cards}


def pick_widths(pool: list, n: int, widths: dict, rng: random.Random) -> list:
    """从池里按序循环取 n 个 def（池内即基础版顺位）。"""
    return [pool[i % len(pool)] for i in range(n)]


def span_of(def_name: str, widths: dict) -> tuple:
    w = widths.get(def_name, 8.0)
    return w


def place_run(defs: list, cursor: float, direction: int, widths: dict) -> tuple:
    """从 cursor 沿 direction 逐栋推挤放置；返回 ( placements, new_cursor )。
    cursor 指向下一栋可用的画面边缘（direction=+1 左缘 / -1 右缘）。"""
    out = []
    for d in defs:
        w = span_of(d, widths)
        x = cursor + direction * (w * 0.5)
        out.append((d, x, w))
        cursor += direction * (w + MIN_GAP)
    return out, cursor


def solve(tier: str, seed: int) -> dict:
    rng = random.Random(seed)
    prof = TIERS[tier]
    widths = load_card_widths()

    # ── 1. 分区 → 左右侧（非镜像：随机顺序逐区分配给累计较轻的一侧）───
    zones = ["market", "craft", "living", "production", "storage"]
    rng.shuffle(zones)
    sides = {}
    load = {-1: 0.0, 1: 0.0}
    for z in zones:
        if not prof["zoned"]:
            sides[z] = 0   # tiny：无分区
            continue
        zload = sum(widths.get(d, 8.0) for d in ZONE_POOLS[z][:int(prof.get(z, 0))])
        s = -1 if load[-1] <= load[1] else 1
        sides[z] = s
        load[s] += zload

    # ── 2. 各区塞够建筑（队列内洗牌 = 居住/仓储随机塞）─────────────────
    queues: dict[str, list] = {}
    for z in zones:
        n = int(prof.get(z, 0))
        defs = pick_widths(ZONE_POOLS[z], n, widths, rng)
        rng.shuffle(defs)
        queues[z] = defs

    # ── 3. 两侧序列：按区拼接（区内已洗牌），特殊建筑随机插位 ──────────
    seq = {-1: [], 1: []}
    for z in zones:
        side = sides[z]
        if side == 0:
            (seq[-1] if rng.random() < 0.5 else seq[1]).extend(queues[z])
        else:
            seq[side].extend(queues[z])
    floats = pick_widths(FLOAT_DEFS, min(2, len(FLOAT_DEFS)), widths, rng) \
        if tier in ("starter", "village", "town") else []
    for d in floats:
        side = rng.choice([-1, 1]) if any(seq[s_] for s_ in (-1, 1)) else 1
        seq[side].insert(rng.randint(0, len(seq[side])), d)

    # ── 4. 核心居中，从中心向两侧排布 ─────────────────────────────────
    placements: list[dict] = []
    core_defs = pick_widths(ZONE_POOLS["core"], int(prof["core"]), widths, rng)
    cursor = {-1: 0.0, 1: 0.0}
    for d in core_defs:
        w = span_of(d, widths)
        placements.append({"def": d, "x": 0.0, "w": w, "zone": "core"})
        cursor[-1] = -w * 0.5 - MIN_GAP
        cursor[1] = w * 0.5 + MIN_GAP
    # 两侧交替出队（队列长者先出一点，防一侧堆完另一侧全空）
    order = []
    qi = {-1: 0, 1: 0}
    while qi[-1] < len(seq[-1]) or qi[1] < len(seq[1]):
        for s in (-1, 1):
            if qi[s] < len(seq[s]):
                order.append((s, seq[s][qi[s]]))
                qi[s] += 1
    for s, d in order:
        w = span_of(d, widths)
        x = cursor[s] + s * w * 0.5
        placements.append({"def": d, "x": x, "w": w,
                           "zone": next((z for z, q in queues.items() if d in q), "float")})
        cursor[s] += s * (w + MIN_GAP)
    # 城门楼收两端（结构性，不入分区）
    for s in (-1, 1):
        w = span_of(GATE_DEF, widths)
        x = cursor[s] + s * w * 0.5
        placements.append({"def": GATE_DEF, "x": x, "w": w, "zone": "gate", "door": True})
        cursor[s] += s * (w + MIN_GAP)

    left_edge = min(p["x"] - p["w"] * 0.5 for p in placements)
    right_edge = max(p["x"] + p["w"] * 0.5 for p in placements)
    width_cells = int(round((right_edge - left_edge) + WALL_MARGIN * 2.0))
    # x 平移：布局以 0 为街中心（左右等宽）
    shift = (left_edge + right_edge) * 0.5
    for p in placements:
        p["x"] -= shift

    # ── 5. 背景两层：随分区锚点落（锚点 = 该区前排跨度中心 ± 抖动）──────
    zone_anchor: dict[str, float] = {}
    for p in placements:
        if p["zone"] in ("core", "gate"):
            continue
        zone_anchor.setdefault(p["zone"], p["x"])
        zone_anchor[p["zone"]] = (zone_anchor[p["zone"]] + p["x"]) * 0.5
    bg_defs = pick_widths(BG_POOL, min(9, len(BG_POOL)), widths, rng)
    bg_rows: dict[int, list] = {1: [], 2: []}
    for i, d in enumerate(bg_defs):
        row = 1 if i % 2 == 0 else 2
        zone = BG_DEF_ZONE.get(d, "living")
        anchor = zone_anchor.get(zone, 0.0)
        bg_rows[row].append({"def": d, "x": anchor + rng.uniform(-9.0, 9.0), "w": span_of(d, widths)})
    for row_bs in bg_rows.values():
        row_bs.sort(key=lambda b: b["x"])
        for i in range(1, len(row_bs)):   # 行内推挤防重叠
            need = row_bs[i - 1]["x"] + row_bs[i - 1]["w"] * 0.5 + MIN_GAP + row_bs[i]["w"] * 0.5
            if row_bs[i]["x"] < need:
                row_bs[i]["x"] = need

    # ── 6. 道具随分区落（锚点 = 区内前排中心 ± 抖动）──────────────────
    props: list[dict] = []
    def zone_x(z: str) -> float:
        return zone_anchor.get(z, 0.0)
    def prop(card: str, z: str, dx: float, py: float, plat: bool = False):
        props.append({"card": card, "x": round(zone_x(z) + dx, 1), "z": py, "plat": plat})
    if prof["craft"] > 0:
        prop("anvil", "craft", -1.1, 4.5, True); prop("grindstone", "craft", 1.6, 4.3, True)
    if prof["market"] > 0:
        prop("well", "market", -2.5, 5.2); prop("market_stall", "market", 1.5, 4.6)
        prop("market_table", "market", 4.2, 5.6); prop("produce_baskets", "market", 6.5, 4.6)
    if prof["core"] > 0:
        prop("banner", "core", -2.0, 4.5, True)
    if prof["storage"] > 0:
        prop("crate", "storage", -1.5, 4.4, True); prop("barrel", "storage", 1.2, 4.2, True)
        prop("sack_stack", "storage", 3.6, 5.8)
    if prof["production"] > 0:
        prop("haystack", "production", -2.0, 5.6); prop("log_pile", "production", 2.4, 6.0)
        prop("trough", "production", 5.0, 5.0)
    prop("bench", "market", -5.5, 5.0); prop("bench", "living", 2.0, 5.0)
    prop("lantern", "gate", -2.2, 4.6, True); prop("lantern", "gate", 2.2, 4.6, True)

    # ── 7. 组装 JSON 契约（row0=前排，row1/2=背景两层）─────────────────
    buildings = []
    for p in placements:
        d = p["def"]
        base = d.rsplit("_w", 1)[0]
        z = p.get("z")
        if z is None:
            z = 2.4 if base in GROUND_DEFS else 0.45 + (absf_hash(p["x"]) % 85) / 100.0
        buildings.append({
            "card": d, "def": base, "x": round(p["x"], 1), "cells": round(p["w"], 2),
            "row": 0, "door": bool(p.get("door") or base in DOOR_DEFS), "z": round(z, 2),
            "zone": p["zone"],
        })
    for row, row_bs in bg_rows.items():
        for b in row_bs:
            base = b["def"].rsplit("_w", 1)[0]
            buildings.append({"card": b["def"], "def": base, "x": round(b["x"], 2),
                              "cells": round(b["w"], 2), "row": row, "door": False})
    plan = {
        "cell_w": 32,
        "width_cells": width_cells,
        "tier": tier, "seed": seed,
        "zone_sides": {z: sides[z] for z in zones},
        "buildings": buildings,
        "props": props,
        "trees": [],
    }
    return plan


def absf_hash(v: float) -> float:
    return abs(v * 2654435761.0) % 97.0


def repair_rows(plan: dict) -> None:
    """产物级修复：同排按 x 排序后逐栋推挤，画面间隙保底 MIN_GAP。
    上游摆位链的任何算术偏差在这里归零——重叠不可能出现在最终 JSON。"""
    rows: dict[int, list] = {}
    for b in plan["buildings"]:
        rows.setdefault(b["row"], []).append(b)
    for bs in rows.values():
        bs.sort(key=lambda b: b["x"])
        for i in range(1, len(bs)):
            need = (bs[i - 1]["x"] + bs[i - 1]["cells"] * 0.5 + MIN_GAP
                    + bs[i]["cells"] * 0.5)
            if bs[i]["x"] < need:
                bs[i]["x"] = round(need, 2)


def verify(plan: dict, widths: dict) -> list:
    """审计：同排无重叠（画面间隙 ≥0.6）、墙线内无出界、分区宽度表。"""
    fails = []
    rows: dict[int, list] = {}
    for b in plan["buildings"]:
        rows.setdefault(b["row"], []).append(b)
    for row, bs in rows.items():
        bs.sort(key=lambda b: b["x"])
        for i in range(1, len(bs)):
            gap = (bs[i]["x"] - bs[i]["cells"] * 0.5) - (bs[i - 1]["x"] + bs[i - 1]["cells"] * 0.5)
            if gap < MIN_GAP - 0.01:
                fails.append(f"row{row} 重叠: {bs[i-1]['card']}@{bs[i-1]['x']} ~ {bs[i]['card']}@{bs[i]['x']} gap={gap:.2f}")
    half = plan["width_cells"] * 0.5
    for b in plan["buildings"]:
        if b["row"] == 0:
            if abs(b["x"]) + b["cells"] * 0.5 > half + 0.01:
                fails.append(f"出墙: {b['card']}@{b['x']} 跨越 ±{half}")
    print("== 城市生成审计 ==")
    print(f"tier={plan['tier']} seed={plan['seed']} width={plan['width_cells']}格 "
          f"(墙 ±{half:.0f}，城心石板 ±{GROUND_CELLS:.0f})")
    zs: dict[str, int] = {}
    for b in plan["buildings"]:
        if b["row"] == 0:
            zs[b.get("zone", "?")] = zs.get(b.get("zone", "?"), 0) + 1
    print("前排分区计数:", zs, " 侧位:", plan["zone_sides"])
    n_bg = sum(1 for b in plan["buildings"] if b["row"] >= 1)
    print(f"背景两层: {n_bg} 栋")
    for f in fails:
        print("  !", f)
    print("审计:", "PASS" if not fails else f"FAIL x{len(fails)}")
    return fails


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="初始城市生成器 v2（中心向两侧/数量定长/非对称分区）")
    ap.add_argument("--tier", default="starter", choices=list(TIERS.keys()))
    ap.add_argument("--seed", type=int, default=20260915)
    ap.add_argument("--name", default="hd2d_street")
    args = ap.parse_args(argv)

    plan = solve(args.tier, args.seed)
    repair_rows(plan)
    widths = load_card_widths()
    fails = verify(plan, widths)
    os.makedirs(OUT_DIR, exist_ok=True)
    out = os.path.join(OUT_DIR, f"{args.name}.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(plan, f, ensure_ascii=False, indent=1)
    print("产物:", out)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
