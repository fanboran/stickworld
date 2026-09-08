"""城镇布局骨架规划器 —— seed 驱动的一维街区生成（纯函数，无 IO）。

死亡细胞式随机边界：seed 决定结构与布局（城门位/地标落位/街区分块/民居填充），
美术风格不归这里管（材质/层高/装饰是批次 3 的消费端）。

一维骨架（横向卷轴退化为条带布局，从左到右）：

  [左城墙带] [左街区：市场·铁匠铺·仓库 + 民居群] [城门(主街锚)] [右街区：校场·兵营·码头 + 民居群] [右城墙带]

功能区锚定布局（先占位再填民居）：地标按 LANDMARK_SPECS 的 side/order 在
城门两侧顺序落位，占满自己的 footprint + plaza 净空后，剩余空间才给民居：

- 市场（market）：紧贴城门左侧，footprint 大 + 双侧广场净空（集市人流语义）；
- 铁匠铺区（smith）：市场之后仍靠主街（工匠区近门、远离仓储的烟火语义）；
- 仓库（warehouse）：左街区深端（仓储远离主街喧嚣）；
- 校场（conquest reserve）：紧邻城门右侧——守军布阵开阔带（30 cell 净空，
  ConquestAnchor 位置由它派生，见 RESERVE_CELLS）；
- 兵营（barracks）：校场之后（无校场则城门右侧第一地标）；
- 码头（dock）：贴右街区边缘（水岸语义，profile 配了才有）；
- 民居按街区（block 10~18 cell）填充剩余空间，block 间巷道，密度由 profile 控制。

一维表达约定（横向卷轴的空间语义退化）：
- 「面向主街」= 同侧落位次序靠前（order 小，紧邻城门）；
- 「广场净空」= plaza cell 的禁区段，净空内除该地标本身不出任何建筑
  （verify_layout 校验）；
- 「贴边/水岸」= 压着可用区内缘（edge=True 的地标从右端倒着落位）。

确定性契约：同 profile（同 seed）→ 同 layout，跨平台跨时间可重放。
profile/schema 见同目录 city_profiles.json。
"""
import random

# 校场（守军布阵带）宽度：8 守军槽(间距105px) + 敌将位 + 集结线 ≈ 910px，取 30 cell=960px
RESERVE_CELLS = 30
WALL_SEGMENT_COUNT = 6  # 每侧城墙段数（现状节奏：6 段 × 4 cell）

_LM_GATE = "gate"

# ── 地标类型 → 建筑 def 映射 ──────────────────────────────────────────────
# [占位] = A 线（建筑与美术升级）专用 def 未就绪，先用现有 def 占位；
# A 线相应批次落地后在此换真 def，并复核 LANDMARK_SPECS 的宽度/净空
# （占位 landmark 的辨识度目前靠宽度与净空，视觉辨识批次 3/4 增强）。
LANDMARK_DEFS = {
    "market": "placeholder",   # [占位] 市场：placeholder 宽幅拉伸渲染，待 A 线市场/商铺 def
    "smith": "placeholder",    # [占位] 铁匠铺：待 A 线批次1 smithy_lv1 场景+注册
    "dock": "placeholder",     # [占位] 码头：无对应 def，栈桥类建筑未立项
    "warehouse": "warehouse",
    "barracks": "barracks",
}

# ── 地标落位规格 ─────────────────────────────────────────────────────────
# width  = 建筑 footprint（cell）
# plaza  = 单侧净空（cell）——广场/防火带语义，净空内禁其他建筑
# side   = 落位区段（left=城门左侧街区 / right=城门右侧街区）
# order  = 同侧落位次序（1=最靠城门，即「面向主街」）
# edge   = True 时贴可用区边缘落位（水岸语义，从区段尾端倒着放）
LANDMARK_SPECS = {
    "market":    {"width": 8, "plaza": 3, "side": "left",  "order": 1},
    "smith":     {"width": 6, "plaza": 1, "side": "left",  "order": 2},
    "warehouse": {"width": 8, "plaza": 0, "side": "left",  "order": 3},
    "barracks":  {"width": 8, "plaza": 0, "side": "right", "order": 1},
    "dock":      {"width": 6, "plaza": 2, "side": "right", "order": 2, "edge": True},
}

# profile.landmarks 里 gate 的校验位（gate 由算法独占落位，不进 SPEC 表）
_GATE_KEY = _LM_GATE


def _normalize_landmarks(landmarks) -> list:
    """profile.landmarks 条目归一化：支持 "market" 串或 {"type": "market", ...覆盖}。

    dict 形式可覆盖 width/plaza（批次 4 精调口子），未指定字段取 LANDMARK_SPECS 默认。
    返回按落位次序（side 内 order 升序）排序的规格列表，gate 不在其中。
    """
    out = []
    for lm in landmarks:
        if isinstance(lm, str):
            lm = {"type": lm}
        t = lm.get("type")
        if t == _LM_GATE:
            continue
        spec = LANDMARK_SPECS.get(t)
        if spec is None:
            raise ValueError("未知地标类型: %r（可选: %s）" % (t, sorted(LANDMARK_SPECS)))
        merged = dict(spec)
        for k in ("width", "plaza"):
            if k in lm:
                merged[k] = int(lm[k])
        merged["type"] = t
        out.append(merged)
    out.sort(key=lambda m: (m["side"], m["order"]))
    return out


def _align_up(x: int, step: int) -> int:
    return -(-x // step) * step


def plan_layout(profile: dict, config: dict) -> dict:
    """由一份 city profile 规划完整布局。

    profile: city_profiles.json -> cities.<map_id>（size/wall_tier/seed/density/landmarks/conquest_anchor）
    config:  city_profiles.json（含 defaults + sizes）
    返回 layout dict：
      buildings        按 cell_x 升序的建筑落位（def_id/cell_x/width）
      anchor           ConquestAnchor 数据（仅 conquest 城非 None）
      landmarks        {类型: cell_x} 地标落位索引（gate 除外）
      landmark_zones   [(lo, hi, 类型)] 含净空的禁区段（verify_layout 校验用）
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
    raw_landmarks = list(profile.get("landmarks", []))
    if _GATE_KEY not in raw_landmarks:
        raise ValueError("landmarks 必须含 gate（主街锚点），got %r" % raw_landmarks)
    lms = _normalize_landmarks(raw_landmarks)
    conquest = bool(profile.get("conquest_anchor", False))

    rng = random.Random(int(profile["seed"]))

    # 可用区（城墙带内侧）
    s = edge + wall_len
    e = grid - edge - wall_len
    gate_w = house_w

    left_lms = [m for m in lms if m["side"] == "left"]
    right_lms = [m for m in lms if m["side"] == "right"]

    # 城门（主街锚点）可放区间：两侧须容下全部地标（footprint+双侧净空+最小巷道1）
    # + 至少一个民居街区（12 cell）；conquest 右侧另加校场带+城门巷道
    left_need = 12 + sum(m["width"] + 2 * m["plaza"] + 1 for m in left_lms)
    right_need = 12
    if conquest:
        right_need += RESERVE_CELLS + 2  # 校场 + 城门与校场间巷道（2~4 取下限）
    right_need += sum(m["width"] + 2 * m["plaza"] + 1 for m in right_lms)
    lo_align = _align_up(s + left_need, house_w) // house_w  # ceil 对齐 house_w 后取 cell 索引
    hi_align = (e - gate_w - right_need) // house_w
    if lo_align > hi_align:
        raise ValueError("可用区容不下必配地标：grid=%d s=%d e=%d left_need=%d right_need=%d"
                         % (grid, s, e, left_need, right_need))
    gate_x = rng.randint(lo_align, hi_align) * house_w

    buildings = []
    marks = {}      # 类型 -> 建筑左缘 cell_x
    zones = []      # (lo, hi, 类型) 含净空禁区

    # 城墙带（贴边缘，位置固定不随机——城墙就该贴边）
    if wall_tier > 0:
        wall_def = "wall_tier%d" % wall_tier
        for i in range(WALL_SEGMENT_COUNT):
            buildings.append({"def_id": wall_def, "cell_x": edge + i * house_w, "width": house_w})
            buildings.append({"def_id": wall_def, "cell_x": grid - edge - wall_len + i * house_w,
                              "width": house_w})

    # 城门
    buildings.append({"def_id": "wall_gate", "cell_x": gate_x, "width": gate_w})

    # ── 左街区：从城门向左按 order 落位地标，剩余空间填民居 ──
    cur = gate_x  # 左侧游标（下一地标的右缘基准）
    for m in left_lms:
        cur -= rng.randint(1, 3)   # 与主街/前一地标的巷道
        cur -= m["plaza"]
        x2 = cur
        x1 = x2 - m["width"]
        if x1 < s:
            raise ValueError("左街区容不下地标 %s：x1=%d < s=%d" % (m["type"], x1, s))
        buildings.append({"def_id": LANDMARK_DEFS[m["type"]], "cell_x": x1, "width": m["width"]})
        marks[m["type"]] = x1
        zones.append((max(x1 - m["plaza"], s), min(x2 + m["plaza"], e), m["type"]))
        cur = x1 - m["plaza"]
    buildings.extend(_houses_in(rng, (s, cur), density, house_w))

    # ── 右街区：校场（紧邻城门右侧，conquest 专属）→ 地标按 order → 民居 ──
    cur = gate_x + gate_w
    anchor = None
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
    tail_end = e  # 民居填充的右边界（贴边地标会把它往里收）
    for m in right_lms:
        if m.get("edge"):
            # 水岸语义：贴可用区右缘落位
            x1 = tail_end - m["width"] - rng.randint(0, 2)
            if x1 - m["plaza"] < cur:
                raise ValueError("右街区容不下地标 %s：x1=%d 与游标 %d 冲突" % (m["type"], x1, cur))
            tail_end = x1 - m["plaza"]
        else:
            cur += rng.randint(1, 3)  # 与校场/前一地标的巷道
            x1 = cur
            if x1 + m["width"] + m["plaza"] > tail_end:
                raise ValueError("右街区容不下地标 %s：右缘 %d 越界 %d" % (m["type"], x1 + m["width"], tail_end))
            cur = x1 + m["width"] + m["plaza"]
        buildings.append({"def_id": LANDMARK_DEFS[m["type"]], "cell_x": x1, "width": m["width"]})
        marks[m["type"]] = x1
        zones.append((max(x1 - m["plaza"], s), min(x1 + m["width"] + m["plaza"], e), m["type"]))
    buildings.extend(_houses_in(rng, (cur, tail_end), density, house_w))

    # 地标可辨识守护：每个配置地标必须真实落位（程序性验收门）
    for m in lms:
        assert m["type"] in marks, "地标缺失: %s" % m["type"]

    buildings.sort(key=lambda b: (b["cell_x"], b["def_id"]))
    layout = {
        "grid_width": grid,
        "width_px": size["width_px"],
        "ground_y": ground_y,
        "wall_tier": wall_tier,
        "buildings": buildings,
        "anchor": anchor,
        "landmarks": marks,
        "landmark_zones": zones,
    }
    verify_layout(layout, cell_w)
    return layout


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
    """布局不变式：越界/重叠/校场净空/城门存在/地标净空。规划期 assert，防算法回归。"""
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
    # 地标净空：禁区段内只允许该地标本身（同类型多地标以落位坐标区分）
    marks = layout.get("landmarks", {})
    for lo, hi, t in layout.get("landmark_zones", []):
        lx = marks.get(t)
        for b in bl:
            if b["cell_x"] == lx and b["def_id"] == LANDMARK_DEFS[t]:
                continue
            bx2 = b["cell_x"] + b["width"]
            assert b["cell_x"] >= hi or bx2 <= lo, \
                "净空被占: %s@%d 侵入 %s 区 [%d,%d]" % (b["def_id"], b["cell_x"], t, lo, hi)
