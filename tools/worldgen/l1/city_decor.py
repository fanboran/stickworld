"""城镇装饰层规划器 —— 地面材质分带 + 装饰物件落位（纯函数，无 IO）。

批次 3（城镇生成管线）消费 city_layout 的布局骨架，产出装饰数据 dict，
由 settlement_mapgen 渲染为 .tscn 节点（烘焙场景内容，无运行时系统）。

地面分带（一维条带内的水平分层，与布局数据同源、随 seed 确定性）：
  [草皮带=城内其余地面] [土路带=沿主街的水平踩踏带] [石板广场=市场地标净空区]
  另有农田带（profile.decor.farmland 开关，落在最宽无建筑间隙，AI 提案·待定）。

装饰物件（纯视觉 Polygon2D 组，无碰撞无脚本）：
  路灯（城门沿主街两侧） / 绿植（树丛+灌木，草带前缘） /
  杂物（木桶/货箱/干草堆，市场与仓库周边）。

净空契约（verify_decor 断言，与 verify_layout 同级守护）：
- 校场带（conquest reserve_band）内无任何装饰物件（军事用地保持开阔可读）；
- 树冠投影不入建筑 footprint（杂物/灌木位于建筑基线前缘，视觉上不与建筑体重叠）；
- 石板广场只出现在市场净空区。

确定性契约：同 profile（同 seed）→ 同装饰数据。装饰使用独立于布局 rng 的
派生流（seed 掺盐），装饰逻辑演化不扰动布局骨架（重生成时建筑 JSON 零 diff）。

层级契约（渲染序，详见同目录 README.md）：
  GroundPolygon(草地贴图, z0) → 草皮带/土路带/石板广场(TerrainLayer 内后置子节点)
  → DecorationLayer(z1, 装饰物件) → BuildingHost(z2, 建筑) → EntityHost(z3, 单位)。
  地面分带与装饰恒在建筑/单位之下，不遮挡交互。
"""
import random

# 装饰 rng 派生盐：与布局 rng（profile.seed 直接播种）隔离
_DECOR_SEED_SALT = 0x5EC0

GROUND_BOTTOM = 1080  # 与 map_base.gd ground_bottom 默认值及场景模板一致

# 土路带默认高度（px）：主街踩踏带（行走线），参数化口子在 defaults.decor.road_h
ROAD_H_DEFAULT = 110

# ── L1 文化圈统一配色（色彩语言全区统一，城间差异来自配比不来自换皮）──────
PALETTE = {
    "turf_base": (0.33, 0.44, 0.21),    # 草皮带基色（贴近 grassland.png 均色）
    "turf_alt": (0.29, 0.40, 0.19),     # 草皮带暗斑
    "road": (0.58, 0.46, 0.30),         # 土路（踩踏裸土）
    "stone": (0.58, 0.55, 0.48),        # 石板亮面（暖灰，读感=铺装广场而非石墙）
    "stone_alt": (0.49, 0.46, 0.40),    # 石板暗面
    "seam": (0.36, 0.34, 0.31),         # 板缝
    "farmland_soil": (0.40, 0.32, 0.21),  # 田垄土
    "farmland_crop": (0.34, 0.51, 0.21),  # 垄上作物
    "lamp_pole": (0.16, 0.15, 0.18),    # 灯柱铁色
    "lamp_glass": (1.00, 0.85, 0.54),   # 灯罩暖黄
    "lamp_glow": (1.00, 0.81, 0.43),    # 灯晕
    "trunk": (0.42, 0.29, 0.18),        # 树干
    "leaf_a": (0.25, 0.43, 0.23),       # 树冠三阶绿
    "leaf_b": (0.30, 0.50, 0.26),
    "leaf_c": (0.36, 0.57, 0.29),
    "bush": (0.28, 0.46, 0.24),         # 灌木
    "bush_hi": (0.34, 0.53, 0.28),
    "barrel": (0.48, 0.32, 0.19),       # 木桶
    "barrel_hoop": (0.25, 0.17, 0.11),
    "crate": (0.64, 0.50, 0.28),        # 货箱
    "crate_in": (0.50, 0.38, 0.20),
    "hay": (0.78, 0.65, 0.31),          # 干草
    "hay_hi": (0.86, 0.74, 0.38),
}


def plan_decor(layout: dict, profile: dict, config: dict) -> dict:
    """由布局骨架 + profile 装饰配置规划装饰数据。

    profile: city_profiles.json -> cities.<map_id>（复用其 seed；decor 字段可覆盖 defaults.decor）
    config:  city_profiles.json（含 defaults）
    返回 decor dict：
      bands    地面分带 [{name, style, rect}] （style 对应 ground_band.gdshader）
      lamps    路灯 [{x, y}]（基点在地面上，灯体向上）
      trees    树丛 [{x, y, r, tone}]
      bushes   灌木 [{x, y, r}]
      clutter  杂物 [{x, y, kind}]（kind: barrel/crate/hay）
    """
    defaults = config["defaults"]
    cfg = dict(defaults.get("decor", {}))
    cfg.update(profile.get("decor") or {})
    road_h = int(cfg.get("road_h", ROAD_H_DEFAULT))
    lamp_count = int(cfg.get("lamp_count", 10))
    lamp_spacing = float(cfg.get("lamp_spacing", 210))
    n_trees = int(cfg.get("trees", 10))
    n_bushes = int(cfg.get("bushes", 16))
    n_clutter_mkt = int(cfg.get("clutter_market", 7))
    n_clutter_wh = int(cfg.get("clutter_warehouse", 4))
    farmland_on = bool(cfg.get("farmland", False))

    cell_w = int(defaults["cell_w"])
    ground_y = float(layout["ground_y"])
    s, e = layout["usable"]
    inner_l, inner_r = s * cell_w, e * cell_w
    road_top = ground_y
    road_bot = ground_y + road_h
    front_top = road_bot + 14            # 前缘草带（装饰物件活动区）上界
    front_bot = GROUND_BOTTOM - 22       # 下界

    rng = random.Random(int(profile["seed"]) ^ _DECOR_SEED_SALT)

    # 建筑像素矩形（树冠/杂物净空用）；门/墙段也含在内
    brects = [(b["cell_x"] * cell_w, 0.0, (b["cell_x"] + b["width"]) * cell_w, 0.0)
              for b in layout["buildings"]]
    gate = next(b for b in layout["buildings"] if b["def_id"] == "wall_gate")
    gate_l = gate["cell_x"] * cell_w
    gate_r = (gate["cell_x"] + gate["width"]) * cell_w

    reserve = layout.get("reserve_band")
    reserve_rect = None
    if reserve:
        reserve_rect = (reserve[0] * cell_w, 0.0, reserve[1] * cell_w, GROUND_BOTTOM)

    # ── 地面分带 ─────────────────────────────────────────────────────────
    bands = [
        {"name": "GroundTurf", "style": 0,
         "rect": (inner_l, ground_y, inner_r, GROUND_BOTTOM)},
        {"name": "GroundRoad", "style": 1,
         "rect": (inner_l, road_top, inner_r, road_bot)},
    ]
    plaza_rects = []
    for lo, hi, t in layout.get("landmark_zones", []):
        if t != "market":
            continue  # 石板带=市场广场语义；其余地标净空区保持地面留白
        pr = (max(lo * cell_w, inner_l), ground_y, min(hi * cell_w, inner_r), GROUND_BOTTOM)
        plaza_rects.append(pr)
        bands.append({"name": "GroundPlaza%d" % len(plaza_rects), "style": 2, "rect": pr})

    # ── 农田带（AI 提案·待定）：最宽无建筑/校场/广场间隙，前缘草带内的垄沟田 ──
    farmland_rect = None
    if farmland_on:
        occ = sorted((r[0], r[2]) for r in brects)
        if reserve_rect:
            occ.append((reserve_rect[0], reserve_rect[2]))
        occ += [(p[0], p[2]) for p in plaza_rects]
        lo_m, hi_m = inner_l + 64, inner_r - 64  # 两端退离墙线
        need = 560                                # 最窄田宽（px）
        best = None
        cur = inner_l
        for lo, hi in occ:
            lo2 = max(lo, lo_m)
            if lo2 - cur >= (best[1] - best[0] if best else need):
                best = (cur, lo2)
            cur = max(cur, hi)
        if hi_m - cur >= (best[1] - best[0] if best else need):
            best = (cur, hi_m)
        if best and best[1] - best[0] >= need:
            ft = road_bot + 10
            fb = min(ft + 130, front_bot)
            farmland_rect = (best[0] + 24, ft, best[1] - 24, fb)
            bands.append({"name": "GroundFarmland", "style": 3, "rect": farmland_rect})

    def in_forbidden_zone(x: float, margin: float) -> bool:
        """校场带/农田带内禁入装饰物件（地面分带不受限）。"""
        if reserve_rect and reserve_rect[0] - margin <= x <= reserve_rect[2] + margin:
            return True
        if farmland_rect and farmland_rect[0] - margin <= x <= farmland_rect[2] + margin:
            # 前缘物件只挡农田矩形 y 范围内的落点（农田只占前缘一部分深度）
            return True
        return False

    def in_building(x: float, margin: float) -> bool:
        return any(r[0] - margin <= x <= r[2] + margin for r in brects)

    # ── 路灯：城门沿主街向两侧布灯（跳过建筑/校场，广场内可落灯）──────────
    lamps = []
    side_x = {"L": gate_l, "R": gate_r}
    first_gap = rng.uniform(36.0, 64.0)
    side_x["L"] -= first_gap
    side_x["R"] += first_gap
    attempts = 0
    while len(lamps) < lamp_count and attempts < lamp_count * 6:
        attempts += 1
        side = "L" if (len(lamps) % 2 == 0 and side_x["L"] > inner_l + 30) or side_x["R"] > inner_r - 30 else "R"
        x = side_x[side]
        step = lamp_spacing * rng.uniform(0.85, 1.25)
        side_x[side] = x - step if side == "L" else x + step
        if not (inner_l + 30 <= x <= inner_r - 30):
            continue
        if in_building(x, 10) or in_forbidden_zone(x, 24):
            continue
        lamps.append({"x": round(x, 1), "y": round(road_top + road_h * rng.uniform(0.42, 0.62), 1)})

    # ── 树丛：前缘草带，树冠不入建筑投影/校场/广场/农田 ─────────────────────
    trees = []
    tries = 0
    while len(trees) < n_trees and tries < n_trees * 12:
        tries += 1
        x = rng.uniform(inner_l + 40, inner_r - 40)
        y = rng.uniform(front_top + 34, front_bot)
        if in_building(x, 26) or in_forbidden_zone(x, 30):
            continue
        if any(abs(x - t["x"]) < 90 for t in trees):
            continue
        trees.append({"x": round(x, 1), "y": round(y, 1),
                      "r": round(rng.uniform(16.0, 26.0), 1), "tone": rng.randint(0, 2)})

    # ── 灌木：前缘草带（低于建筑基线，允许贴建筑脚）────────────────────────
    bushes = []
    tries = 0
    while len(bushes) < n_bushes and tries < n_bushes * 12:
        tries += 1
        x = rng.uniform(inner_l + 24, inner_r - 24)
        y = rng.uniform(front_top + 8, front_bot)
        if in_forbidden_zone(x, 24):
            continue
        if any(abs(x - b["x"]) < 46 and abs(y - b["y"]) < 30 for b in bushes):
            continue
        if any(abs(x - t["x"]) < 60 and abs(y - t["y"]) < 40 for t in trees):
            continue
        bushes.append({"x": round(x, 1), "y": round(y, 1), "r": round(rng.uniform(8.0, 13.0), 1)})

    # ── 杂物：市场/仓库周边（货物散置语义，不入建筑 footprint 与校场）────────
    clutter = []

    def _scatter(n, x_lo, x_hi, anchor_rect=None):
        placed = 0
        tries = 0
        while placed < n and tries < n * 14:
            tries += 1
            x = rng.uniform(x_lo, x_hi)
            y = rng.uniform(front_top, front_bot)
            if anchor_rect and anchor_rect[0] - 14 <= x <= anchor_rect[2] + 14:
                continue  # 不进建筑本体投影
            if in_forbidden_zone(x, 24):
                continue
            if any(abs(x - c["x"]) < 44 and abs(y - c["y"]) < 26 for c in clutter):
                continue
            kind = rng.choices(["barrel", "crate", "hay"], weights=[0.4, 0.4, 0.2])[0]
            clutter.append({"x": round(x, 1), "y": round(y, 1), "kind": kind})
            placed += 1

    mzone = next((z for z in layout.get("landmark_zones", []) if z[2] == "market"), None)
    if mzone and n_clutter_mkt > 0:
        mkt_cell = layout.get("landmarks", {}).get("market")
        mkt_rect = next((r for r, b in zip(brects, layout["buildings"])
                         if b["def_id"] == "placeholder" and b["cell_x"] == mkt_cell), None)
        _scatter(n_clutter_mkt,
                 max(mzone[0] * cell_w, inner_l) + 10, min(mzone[1] * cell_w, inner_r) - 10,
                 anchor_rect=mkt_rect)
    wh = layout.get("landmarks", {}).get("warehouse")
    if wh is not None and n_clutter_wh > 0:
        wr = next((r for r, b in zip(brects, layout["buildings"])
                   if b["def_id"] == "warehouse" and b["cell_x"] == wh), None)
        if wr:
            _scatter(n_clutter_wh,
                     max(wr[0] - 70, inner_l + 16), min(wr[2] + 70, inner_r - 16), anchor_rect=wr)

    decor = {
        "bands": bands,
        "lamps": lamps,
        "trees": trees,
        "bushes": bushes,
        "clutter": clutter,
    }
    verify_decor(decor, layout, cell_w)
    return decor


def verify_decor(decor: dict, layout: dict, cell_w: int) -> None:
    """装饰不变式：校场净空/建筑投影/广场语义。规划期 assert，防算法回归。"""
    reserve = layout.get("reserve_band")
    if reserve:
        rl, rr = reserve[0] * cell_w - 24, reserve[1] * cell_w + 24
        for lamp in decor["lamps"]:
            assert not (rl <= lamp["x"] <= rr), "路灯侵入校场: x=%.1f" % lamp["x"]
        for group, key in (("树", "trees"), ("灌木", "bushes"), ("杂物", "clutter")):
            for it in decor[key]:
                assert not (rl <= it["x"] <= rr), "%s侵入校场: x=%.1f" % (group, it["x"])
        for band in decor["bands"]:
            if band["style"] in (2, 3):
                assert band["rect"][2] <= rl or band["rect"][0] >= rr, \
                    "石板/农田带侵入校场: %s" % band["name"]
    # 石板带只出现在市场净空区
    mzone = [(z[0] * cell_w, z[1] * cell_w) for z in layout.get("landmark_zones", []) if z[2] == "market"]
    for band in decor["bands"]:
        if band["style"] == 2:
            assert any(lo <= band["rect"][0] and band["rect"][2] <= hi for lo, hi in mzone), \
                "石板带越出市场净空: %s" % band["name"]
    # 基本规模：主街与城门必可辨识
    assert len(decor["lamps"]) >= 2, "路灯过少: %d" % len(decor["lamps"])
