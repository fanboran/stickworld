"""城镇布局骨架规划器 —— seed 驱动的一维街区生成（纯函数，无 IO）。

死亡细胞式随机边界：seed 决定结构与布局（城门位/街区分块/建筑落位），
美术风格不归这里管（材质/层高/装饰是批次 2/3 的消费端）。

一维骨架（横向卷轴退化为条带布局，从左到右）：

  [左城墙带] [左街区：仓库+民居群] [城门(主街锚)] [右街区：校场+兵营+民居群] [右城墙带]

- 城门位置在可用区中部随机（主街走向的一维表达）；
- 校场（conquest reserve）紧邻城门右侧——守军布阵开阔带，语义同
  ConquestAnchor 现状（城门右侧空旷带）；
- 民居按街区（block 10~18 cell）填充，block 间留巷道，密度由 profile 控制。

确定性契约：同 profile（同 seed）→ 同 layout，跨平台跨时间可重放。
profile/schema 见同目录 city_profiles.json。
"""
import random

# 校场（守军布阵带）宽度：8 守军槽(间距105px) + 敌将位 + 集结线 ≈ 910px，取 30 cell=960px
RESERVE_CELLS = 30
WALL_SEGMENT_COUNT = 6  # 每侧城墙段数（现状节奏：6 段 × 4 cell）

_LM_GATE = "gate"
_LM_WAREHOUSE = "warehouse"
_LM_BARRACKS = "barracks"


def plan_layout(profile: dict, config: dict) -> dict:
    """由一份 city profile 规划完整布局。

    profile: city_profiles.json -> cities.<map_id>（size/wall_tier/seed/density/landmarks/conquest_anchor）
    config:  city_profiles.json（含 defaults + sizes）
    返回 layout dict（buildings 按 cell_x 升序；anchor 仅 conquest 城有值）。
    """
    defaults = config["defaults"]
    size = config["sizes"][profile["size"]]
    cell_w = defaults["cell_w"]
    house_w = defaults["house_width"]
    grid = size["grid_width"]
    ground_y = defaults["ground_y"]
    edge = defaults["edge_cells"]
    wall_tier = int(profile.get("wall_tier", 0))
    wall_len = defaults["wall_band_len"] if wall_tier > 0 else 0
    density = float(profile.get("density", defaults["density"]))
    landmarks = list(profile.get("landmarks", []))
    conquest = bool(profile.get("conquest_anchor", False))
    if _LM_GATE not in landmarks:
        raise ValueError("landmarks 必须含 gate（主街锚点），got %r" % landmarks)

    rng = random.Random(int(profile["seed"]))

    # 可用区（城墙带内侧）
    s = edge + wall_len
    e = grid - edge - wall_len

    # 城门（主街锚点）：两侧须容下必配地标 + 至少一个民居街区
    gate_w = house_w
    left_min = 26 if _LM_WAREHOUSE in landmarks else 12
    if conquest:
        right_min = RESERVE_CELLS + 26
    elif _LM_BARRACKS in landmarks:
        right_min = 26
    else:
        right_min = 12
    lo_align = -(-max(s + left_min, s) // house_w)  # ceil 对齐 house_w
    hi_align = (e - gate_w - right_min) // house_w
    if lo_align > hi_align:
        raise ValueError("可用区容不下必配地标：grid=%d s=%d e=%d" % (grid, s, e))
    gate_x = rng.randint(lo_align, hi_align) * house_w

    buildings = []

    # 城墙带（贴边缘，位置固定不随机——城墙就该贴边）
    if wall_tier > 0:
        wall_def = "wall_tier%d" % wall_tier
        for i in range(WALL_SEGMENT_COUNT):
            buildings.append({"def_id": wall_def, "cell_x": edge + i * house_w, "width": house_w})
            buildings.append({"def_id": wall_def, "cell_x": grid - edge - wall_len + i * house_w,
                              "width": house_w})

    # 城门
    buildings.append({"def_id": "wall_gate", "cell_x": gate_x, "width": gate_w})

    # 左街区：仓库（靠入口侧，随机落位）+ 民居
    anchor = None
    warehouse_x = None
    if _LM_WAREHOUSE in landmarks:
        warehouse_x = rng.randint(s + 2, gate_x - 9)
        buildings.append({"def_id": _LM_WAREHOUSE, "cell_x": warehouse_x, "width": 8})
    for seg in _segments_around(s, gate_x, warehouse_x, 8):
        buildings.extend(_houses_in(rng, seg, density, house_w))

    # 右街区：校场（紧邻城门右侧）→ 兵营（远端）→ 民居
    cur = gate_x + gate_w
    if conquest:
        cur += rng.randint(2, 4)  # 城门与校场间巷道
        reserve_start = cur
        cur += RESERVE_CELLS
        base_px = reserve_start * cell_w
        slot_xs = [base_px + 20 + i * 105 for i in range(8)]
        anchor = {
            "y": ground_y + 135,
            "rally_x": base_px - 20,
            "slot_xs": slot_xs,
            "commander_x": slot_xs[-1] + 115,
        }
    if _LM_BARRACKS in landmarks:
        cur += rng.randint(1, 3)
        barracks_x = -(-cur // house_w) * house_w  # ceil 对齐
        buildings.append({"def_id": _LM_BARRACKS, "cell_x": barracks_x, "width": 8})
        cur = barracks_x + 8
    buildings.extend(_houses_in(rng, (cur, e), density, house_w))

    buildings.sort(key=lambda b: (b["cell_x"], b["def_id"]))
    layout = {
        "grid_width": grid,
        "width_px": size["width_px"],
        "ground_y": ground_y,
        "wall_tier": wall_tier,
        "buildings": buildings,
        "anchor": anchor,
    }
    verify_layout(layout, cell_w)
    return layout


def _segments_around(zone_start: int, zone_end: int, occupied_x, occupied_w: int):
    """一块区域被单个地标占用后，剩余的民居可用段。"""
    if occupied_x is None:
        return [(zone_start, zone_end)]
    return [(zone_start, occupied_x - 1), (occupied_x + occupied_w + 1, zone_end)]


def _houses_in(rng, seg, density: float, house_w: int) -> list:
    """街区内民居填充：block 10~18 cell、block 间巷道 2~4、房距 1~4、density 概率落房。"""
    seg_start, seg_end = seg
    houses = []
    cur = max(seg_start, 0)
    while seg_end - cur >= 10:
        block_w = min(rng.randint(10, 18), seg_end - cur)
        pos = cur + rng.randint(0, 2)
        while pos + house_w <= cur + block_w:
            if rng.random() < density:
                houses.append({"def_id": "placeholder", "cell_x": pos, "width": house_w})
            pos += house_w + rng.randint(1, 4)
        cur += block_w + rng.randint(2, 4)
    return houses


def verify_layout(layout: dict, cell_w: int) -> None:
    """布局不变式：越界/重叠/校场净空/城门存在。规划期 assert，防算法回归。"""
    grid = layout["grid_width"]
    bl = layout["buildings"]
    assert any(b["def_id"] == "wall_gate" for b in bl), "缺城门"
    ordered = sorted(bl, key=lambda b: b["cell_x"])
    for b in ordered:
        assert 0 <= b["cell_x"] and b["cell_x"] + b["width"] <= grid, \
            "越界: %s@%d+%d" % (b["def_id"], b["cell_x"], b["width"])
    for a, b in zip(ordered, ordered[1:]):
        assert a["cell_x"] + a["width"] <= b["cell_x"], \
            "重叠: %s@%d vs %s@%d" % (a["def_id"], a["cell_x"], b["def_id"], b["cell_x"])
    anchor = layout["anchor"]
    if anchor is not None:
        clear_lo = anchor["rally_x"] - 40
        clear_hi = anchor["commander_x"] + 60
        for b in bl:
            bx = b["cell_x"] * cell_w
            bx2 = (b["cell_x"] + b["width"]) * cell_w
            assert bx2 <= clear_lo or bx >= clear_hi, \
                "校场被占: %s@%d 侵入 [%d,%d]" % (b["def_id"], b["cell_x"], clear_lo, clear_hi)
