extends RefCounted
## 城市生成·街具与组装域（city_gen 管线第 6~7 段，由 CityGen.generate 编排）。
## 职责：街具/道具落位（功能理由制 + 同带互斥登记表 + 门脸避让）→
## 前排/背景组装成 layout_data 契约 → 产物级重叠修复。
## 纯静态纯函数：入参状态、出参结果；街具语义口径（FURNITURE_*/门脸/地面
## 卡名单）属主在本文件。

## 间距口径属主在排布域（产物级修复沿用同一间隙承诺）
const StreetLayout := preload("res://modules/world/scripts/map/city_gen_layout.gd")

const DOOR_DEFS := ["guildhall", "gatehouse", "shop", "tavern", "smithy1", "council_hall"]
const GROUND_DEFS := ["barn", "cottage"]

## 街具（2026-09-16 创始人定案：小件全撤、常识重摆）——**每件道具必须有
## 功能理由**：铁砧/磨刀石=铁匠工位（贴楼）、井=市集聚点、摊/桌/果篮=市集面、
## 旗帜=行政楼前（贴楼）、长椅=井旁对置（village 起）、喷泉=镇起广场位、
## 路标/里程碑=街口、灯=沿街照明、杂物堆=仓储/生产带占格件（§3.5）。
## 随机街具组轮转（长椅/花坛/水龙头等乱点）整体删除——没有功能理由的
## 小件不上街（创始人：好多摆放起来根本没有美感，以后我再微调）。
## 灯距 8~12 格两侧错位（石/铁灯柱逐盏轮换，卡全缺回退灯笼）。
## **带语义**：台面带只留"按建筑算"的东西（建筑+杂物占格件+贴楼功能小件），
## 街具铺路面带（远缘 5.8 / 近缘 7.0 两档错位）；高件 x 避让门脸段。
## **同带互斥**：道具落位即登记 [x0,x1,z]，后放者避让 z 差<1.5 格的已放件
## （≥1.5=前后遮挡合法，保留街景层次），避不开跳过该件。
const FURNITURE_LAMP_EVERY := Vector2(8.0, 12.0)
const FURNITURE_LAMPS := ["lamp_post_stone", "lamp_post_iron", "lantern"]
## 街具纵深（格）：台面带功能件 1.55 贴楼脚；路面带两档（远缘 5.8 / 近缘
## 7.0，同带不同深、x 相遇呈前后遮挡而非同深叠影）
const FURNITURE_Z_PLAT := 1.55
const FURNITURE_Z_ROAD_FAR := 5.8
const FURNITURE_Z_ROAD_NEAR := 7.0
## 同带互斥的 z 差阈值（格）：|Δz|<1.5 视觉必叠须互斥；≥1.5 前后遮挡合法
const PROP_EXCL_BAND := 1.5


## 步骤 6：街具/道具落位（props 数组，layout_data 契约的 props 字段）。
static func _step_street_props(tier: String, pools: Dictionary, prop_fp: Dictionary,
		prop_set: Dictionary, placements: Array, zone_anchor: Dictionary,
		width_cells: int, rng: RandomNumberGenerator) -> Array:
	# ── 6. 道具（2026-09-16 创始人定案：小件全撤、常识重摆）────────────
	# 每件道具必须有功能理由（见 PROP 注）：铁砧/磨刀石=铁匠工位（贴楼）、
	# 井=市集聚点、摊/桌/果篮=市集面、旗帜=行政楼前（贴楼）、长椅=井旁
	# 对置（village 起，聚点语义）、喷泉=镇起广场位、路标/里程碑=街口、
	# 灯=沿街照明、杂物堆=仓储/生产带占格件（§3.5）。
	# **同带互斥登记表**：每件道具落位即登记 [x0,x1,z]；后放者避让所有
	# z 差<PROP_EXCL_BAND 的已放件（≥阈值=前后遮挡合法，保留街景层次），
	# 避不开跳过该件——道具↔道具零穿模（实测旧版同带叠对 28~62/城）。
	var props: Array = []
	var zone_x := func(z: String) -> float:
		return float(zone_anchor.get(z, 0.0))
	var add_prop := func(card: String, zx: float, py: float, plat: bool = false) -> void:
		props.append({"card": card, "x": snappedf(zx, 0.1), "z": py, "plat": plat})
	var prop_reg: Array = []   # 已放道具/杂物 [x0,x1,z]（同带互斥登记表）
	var reg_same := func(z: float) -> Array:
		var out: Array = []
		for sp: Variant in prop_reg:
			if absf(float(sp[2]) - z) < PROP_EXCL_BAND:
				out.append(sp)
		return out
	# 杂物占格段先入表（台面带；z 与第 7 步出卡公式同源）
	for p: Dictionary in placements:
		if bool(p.get("clutter", false)):
			var fp0: Array = prop_fp.get(str(p["def"]), [2.0, 1.5])
			var cz0: float = clampf(0.42 + float(fp0[1]) * 0.45, 0.42, 1.75)
			prop_reg.append([float(p["x"]) - float(p["w"]) * 0.5,
					float(p["x"]) + float(p["w"]) * 0.5, cz0])
	# 门脸建筑段（高件避让用；建筑不入互斥表——贴楼功能件语义上属于建筑）
	var door_spans: Array = []
	for p: Dictionary in placements:
		var base_d: String = str(p["def"]).rsplit("_w", true, 1)[0]
		if (bool(p.get("door", false)) or base_d in DOOR_DEFS) \
				and not bool(p.get("clutter", false)):
			door_spans.append([float(p["x"]) - float(p["w"]) * 0.5,
					float(p["x"]) + float(p["w"]) * 0.5])
	# 带避让放置：目标位被同带已放件/追加段压住就平移，避不开返回 INF
	# （不出卡）；落位即登记。half=画面半宽+0.1 容差。
	var add_prop_free := func(card: String, zx: float, py: float, plat: bool,
			max_shift: float, extra: Array = []) -> float:
		var half: float = float(prop_set.get(card, 1.5)) * 0.5 + 0.1
		var fx := _avoid_spans(zx, half, reg_same.call(py) + extra, max_shift)
		if not is_finite(fx):
			return INF
		add_prop.call(card, fx, py, plat)
		prop_reg.append([fx - half, fx + half, py])
		return fx
	# 功能件：工坊件/旗帜踩台面（贴建筑门脸），市集件铺路面（开敞读法）。
	# 顺序=主件先于填充件：井→井旁椅→摊/桌/果篮→旗帜→喷泉→灯→街口件，
	# 后放者避让先放者（喷泉若 +9 侧放不下试 −9 侧——广场件择空而居）。
	if pools.has("craft"):
		add_prop_free.call("anvil", float(zone_x.call("craft")) - 1.1,
				FURNITURE_Z_PLAT, true, 4.0)
		add_prop_free.call("grindstone", float(zone_x.call("craft")) + 1.6,
				FURNITURE_Z_PLAT - 0.2, true, 4.0)
	var well_x := INF
	if pools.has("market"):
		well_x = float(add_prop_free.call("well", float(zone_x.call("market")) - 2.5,
				5.2, false, 5.0))
		if is_finite(well_x) and tier != "hamlet":
			add_prop_free.call("bench_wood", well_x - 3.4, 5.2, false, 3.0)
			add_prop_free.call("bench_stone", well_x + 3.4, 5.2, false, 3.0)
		# 市集两翼展开：右翼摊+果篮、左翼桌——避让会自动把件推开到不叠处
		add_prop_free.call("market_stall", float(zone_x.call("market")) + 8.0,
				4.6, false, 8.0)
		add_prop_free.call("market_table", float(zone_x.call("market")) - 8.0,
				5.6, false, 8.0)
		add_prop_free.call("produce_baskets", float(zone_x.call("market")) + 12.5,
				4.6, false, 8.0)
	add_prop_free.call("banner", float(zone_x.call("core")) - 2.0,
			FURNITURE_Z_PLAT + 0.2, true, 4.0)
	# 喷泉：镇起的广场位（市场锚点侧翼，+9 侧放不下试 −9 侧；小聚落没喷泉）
	if pools.has("market") and tier in ["townlet", "town", "burgh", "city",
			"capital", "metropolis"]:
		var fx := float(add_prop_free.call("fountain_small",
				float(zone_x.call("market")) + 9.0, 5.4, false, 8.0, door_spans))
		if not is_finite(fx):
			add_prop_free.call("fountain_small", float(zone_x.call("market")) - 9.0,
					5.4, false, 8.0, door_spans)
	# 街灯：沿街照明（周期 8~12 格两侧/两档纵深错位，石/铁柱逐盏轮换，
	# 卡全缺回退灯笼）；x 避让同带道具+门脸段，避不开跳过该盏。
	var period: float = rng.randf_range(FURNITURE_LAMP_EVERY.x, FURNITURE_LAMP_EVERY.y)
	var lamp_cards: PackedStringArray = []
	for d: String in FURNITURE_LAMPS:
		if d != "lantern" and (prop_set.is_empty() or prop_set.has(d)):
			lamp_cards.append(d)
	if lamp_cards.is_empty():
		lamp_cards.append("lantern")
	var xx := -width_cells * 0.5 + 6.0
	var side := 1
	var li := 0
	while xx < width_cells * 0.5 - 6.0:
		var lz: float = FURNITURE_Z_ROAD_FAR if side > 0 else FURNITURE_Z_ROAD_NEAR
		var lx := _avoid_spans(xx, 1.0, reg_same.call(lz) + door_spans, 6.0)
		if is_finite(lx):
			add_prop.call(lamp_cards[li % lamp_cards.size()], lx, lz, false)
			prop_reg.append([lx - 1.0, lx + 1.0, lz])
			li += 1
		xx += period
		side = -side
	# 街口路标/里程碑（城门旁侧翼找位——门脸段避让不许压门，预算放大防挤没）
	add_prop_free.call("signpost", -width_cells * 0.5 + 3.0,
			FURNITURE_Z_ROAD_FAR, false, 8.0, door_spans)
	add_prop_free.call("milestone", width_cells * 0.5 - 3.0,
			FURNITURE_Z_ROAD_FAR, false, 8.0, door_spans)
	return props


## 步骤 7：组装（row0=前排，row1/2=背景两层）+ 产物级重叠修复。
## props 传入即接管：杂物占格件在此并入 props（与建筑同 Z 台面带出卡）。
static func _step_assemble(tier: String, seed_v: int, prop_fp: Dictionary,
		placements: Array, bg_rows: Dictionary, props: Array,
		width_cells: int) -> Dictionary:
	var buildings: Array = []
	for p: Dictionary in placements:
		var d: String = str(p["def"])
		if bool(p.get("gap", false)):
			continue   # 一格空位：只占格不出卡
		# 建筑间杂物：与建筑同 Z 带（台面带内，z 按卡自身 footprint 纵深推导——
		# 浅卡贴楼脚、深卡略靠前），占格坐标随排布来；occ_cells=占格宽，
		# 渲染端据此把杂物并进 F3 建筑辅助线（双黄线，与建筑同口径）
		if bool(p.get("clutter", false)):
			var fp: Array = prop_fp.get(d, [2.0, 1.5])
			var cz: float = clampf(0.42 + float(fp[1]) * 0.45, 0.42, 1.75)
			props.append({"card": d, "x": snappedf(float(p["x"]), 0.1),
				"z": snappedf(cz, 0.01), "plat": true, "occ_cells": float(p["w"])})
			continue
		var base: String = d.rsplit("_w", true, 1)[0]
		var z: float = 2.4 if base in GROUND_DEFS else 0.45 + fposmod(absf(float(p["x"])) * 0.618, 0.85)
		buildings.append({"card": d, "def": base, "x": snappedf(float(p["x"]), 0.01),
			"cells": snappedf(float(p["w"]), 0.01), "row": 0,
			"door": bool(p.get("door", false)) or base in DOOR_DEFS, "z": snappedf(z, 0.01)})
	for row: int in [1, 2]:
		for b: Dictionary in bg_rows[row]:
			var d2: String = str(b["def"])
			buildings.append({"card": d2, "def": d2.rsplit("_w", true, 1)[0],
				"x": snappedf(float(b["x"]), 0.01), "cells": snappedf(float(b["w"]), 0.01),
				"row": row, "door": false})
	var plan := {"cell_w": 32, "width_cells": width_cells, "tier": tier, "seed": seed_v,
		"buildings": buildings, "props": props, "trees": []}
	_repair_rows(plan)
	return plan


## 高件避让：把目标 x 平移到 [x-half, x+half] 不与任何占格段相交的最近位置
## （±交替步进扫描，格距 0.5）；max_shift 内找不到返回 INF（调用方跳过）。
## 候选先对齐 0.1 格再测——add_prop 落盘同样 snappedf(0.1)，"测的值=最终值"，
## 否则四舍五入会把合法落点反推进占格段（实测 0.0125 格咬边）。
static func _avoid_spans(x: float, half: float, spans: Array, max_shift: float) -> float:
	var d := 0.0
	while d <= max_shift:
		for sgn: int in [1, -1]:
			var cand: float = snappedf(x + float(sgn) * d, 0.1)
			var ok := true
			for sp: Variant in spans:
				if cand + half > float(sp[0]) and cand - half < float(sp[1]):
					ok = false
					break
			if ok:
				return cand
		d += 0.5
	return INF


## 产物级修复：同排逐栋推挤，画面间隙保底（重叠不可能出现在产物里）；
## 推挤落点向上取整——前排已是整格吸附口径，修复不把中心拉回分数位
static func _repair_rows(plan: Dictionary) -> void:
	var rows: Dictionary = {}
	for b: Variant in plan["buildings"]:
		var row: int = int(b["row"])
		if not rows.has(row):
			rows[row] = []
		rows[row].append(b)
	for row: int in rows:
		var bs: Array = rows[row]
		bs.sort_custom(func(a, b): return float(a["x"]) < float(b["x"]))
		for i in range(1, bs.size()):
			var need: float = float(bs[i - 1]["x"]) + float(bs[i - 1]["cells"]) * 0.5 + StreetLayout.MIN_GAP + float(bs[i]["cells"]) * 0.5
			if float(bs[i]["x"]) < need:
				bs[i]["x"] = snappedf(ceilf(need), 0.01)
