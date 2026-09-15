class_name CityGen
extends RefCounted
## 初始城市生成器（GD 移植，与 tools/blender_buildings/gen_initial_city.py 同算法）。
##
## 语义（创始人 2026-09-15 裁决）：
##   · 城市大小 = 建筑排完的自然跨度 + 墙留边，不写死——建筑变多城市扩展；
##   · 核心居中，市场/工匠/居住/生产四带随机分配到某侧（轻量配平，非镜像）；
##   · 居住/仓储随机塞；教堂等特殊建筑浮动插位；
##   · 从中心向两侧逐栋排布，画面宽推挤 + 产物级修复，零重叠；
##   · 背景两层（row1/row2）随分区锚点落。
##
## 生成时机：宿主首次进入该城时按**确定性种子**生成（多局尽量一致）；
## 产物即 proto_hd2d 的 layout_data 契约（width_cells/buildings/props）。

const MIN_GAP := 0.6
const WALL_MARGIN := 3.0

const TIERS := {
	"tiny": {"core": 0, "market": 0, "craft": 1, "living": 3, "production": 1, "storage": 0, "zoned": false},
	"hamlet": {"core": 1, "market": 1, "craft": 1, "living": 3, "production": 1, "storage": 1, "zoned": true},
	"starter": {"core": 1, "market": 2, "craft": 2, "living": 5, "production": 2, "storage": 1, "zoned": true},
	"village": {"core": 1, "market": 3, "craft": 3, "living": 7, "production": 3, "storage": 2, "zoned": true},
	"town": {"core": 1, "market": 4, "craft": 4, "living": 9, "production": 4, "storage": 3, "zoned": true},
}

const ZONE_POOLS := {
	"core": ["guildhall_w12"],
	"market": ["shop_w8", "bakery_w8", "tavern_w12", "shop_w8"],
	"craft": ["smithy1_w8", "smithy2_w8", "smithy3_w8"],
	"living": ["house_w16", "house_w8", "house_w8", "cottage_w6", "hayloft_w8",
		"house_w16", "rowhouse_w12", "townhouse_w12", "cottage_w6"],
	"production": ["barn_w12", "windmill_w6", "barn_w12", "stable_w12"],
	"storage": ["warehouse_w16", "warehouse_w16"],
}
const FLOAT_DEFS := ["cathedral_w16", "mage_tower_w8", "library_w12", "tower_w6"]
const BG_POOL := ["cathedral_w16", "mage_tower_w8", "library_w12", "tavern_w12",
	"townhouse_w12", "rowhouse_w12", "alchemy_w8", "barracks_w12",
	"smithy4_w12", "shelter_w6"]
const BG_DEF_ZONE := {
	"cathedral_w16": "core", "mage_tower_w8": "core", "library_w12": "core",
	"tower_w6": "core", "tavern_w12": "market", "townhouse_w12": "market",
	"rowhouse_w12": "living", "shelter_w6": "living",
	"alchemy_w8": "craft", "smithy4_w12": "craft", "barracks_w12": "production",
}
const GATE_DEF := "gatehouse_w8"
const DOOR_DEFS := ["guildhall", "gatehouse", "shop", "tavern", "smithy1"]
const GROUND_DEFS := ["barn", "cottage"]


## 卡画面宽表（格）：temp/proto25d/cards.json，缺失回退 tex 入库副本
static func card_widths() -> Dictionary:
	var out: Dictionary = {}
	for base_path: String in ["res://temp/proto25d/cards.json",
			"res://tests/dev/proto_hd2d/tex/proto25d/cards.json"]:
		if not FileAccess.file_exists(base_path):
			continue
		var f := FileAccess.open(base_path, FileAccess.READ)
		if f == null:
			continue
		var v: Variant = JSON.parse_string(f.get_as_text())
		if v is Array:
			for c: Variant in v:
				var name: String = str(c["card"])
				out[name] = float(c["units"][0]) / 32.0
			break
	if out.is_empty():   # 兜底：全按 8 格
		for d: String in ["guildhall", "shop", "bakery", "tavern", "smithy1", "smithy2",
				"smithy3", "smithy4", "house", "cottage", "hayloft", "rowhouse",
				"townhouse", "barn", "windmill", "stable", "warehouse", "alchemy",
				"library", "mage_tower", "barracks", "shelter", "tower", "cathedral",
				"gatehouse"]:
			for w: int in [4, 6, 8, 12, 16]:
				out["%s_w%d" % [d, w]] = float(w) + 2.0
	return out


## 生成布局（tier/seed 确定性）。tier 见 TIERS；seed 固定 → 多局一致。
static func generate(tier: String, seed_v: int) -> Dictionary:
	var widths := card_widths()
	var prof: Dictionary = TIERS.get(tier, TIERS["starter"])
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v

	# ── 1. 分区 → 侧位（随机序 + 轻量配平）────────────────────────────
	var zones: Array = ["market", "craft", "living", "production", "storage"]
	zones.shuffle()
	var sides: Dictionary = {}
	var load := {-1: 0.0, 1: 0.0}
	for z: String in zones:
		if not bool(prof.get("zoned", true)):
			sides[z] = 0
			continue
		var zload := 0.0
		for i in int(prof.get(z, 0)):
			zload += float(widths.get(str(ZONE_POOLS[z][i % ZONE_POOLS[z].size()]), 8.0))
		var s := -1 if float(load[-1]) <= float(load[1]) else 1
		sides[z] = s
		load[s] = float(load[s]) + zload

	# ── 2. 各区塞够建筑（队列洗牌 = 随机塞）───────────────────────────
	var queues: Dictionary = {}
	for z: String in zones:
		var defs: Array = []
		var n: int = int(prof.get(z, 0))
		for i in n:
			defs.append(ZONE_POOLS[z][i % ZONE_POOLS[z].size()])
		defs.shuffle()
		queues[z] = defs

	# ── 3. 两侧序列拼接 + 浮动建筑随机插位 ────────────────────────────
	var seq := {-1: PackedStringArray(), 1: PackedStringArray()}
	for z: String in zones:
		var side: int = int(sides[z])
		var target: int = side
		if side == 0:
			target = -1 if rng.randf() < 0.5 else 1
		for d: String in queues[z]:
			seq[target].append(d)
	for i in mini(2, FLOAT_DEFS.size()):
		var side2: int = -1 if rng.randf() < 0.5 else 1
		var at: int = rng.randi_range(0, seq[side2].size())
		seq[side2].insert(at, FLOAT_DEFS[i])

	# ── 4. 核心居中，从中心向两侧排布（推挤保底）──────────────────────
	var placements: Array = []   # {def, x, w, zone, door}
	var cursor := {-1: 0.0, 1: 0.0}
	for d: String in ZONE_POOLS["core"]:
		var w := float(widths.get(d, 8.0))
		placements.append({"def": d, "x": 0.0, "w": w, "zone": "core"})
		cursor[-1] = -w * 0.5 - MIN_GAP
		cursor[1] = w * 0.5 + MIN_GAP
	var qi := {-1: 0, 1: 0}
	while int(qi[-1]) < seq[-1].size() or int(qi[1]) < seq[1].size():
		for s: int in [-1, 1]:
			if int(qi[s]) < seq[s].size():
				var d: String = seq[s][int(qi[s])]
				qi[s] = int(qi[s]) + 1
				var w := float(widths.get(d, 8.0))
				var x: float = float(cursor[s]) + s * w * 0.5
				var zone := "float"
				for z: String in queues:
					if d in queues[z]:
						zone = z
						break
				placements.append({"def": d, "x": x, "w": w, "zone": zone})
				cursor[s] = float(cursor[s]) + s * (w + MIN_GAP)
	for s: int in [-1, 1]:
		var w2 := float(widths.get(GATE_DEF, 10.5))
		var x2: float = float(cursor[s]) + s * w2 * 0.5
		placements.append({"def": GATE_DEF, "x": x2, "w": w2, "zone": "gate", "door": true})
		cursor[s] = float(cursor[s]) + s * (w2 + MIN_GAP)

	var left := INF
	var right := -INF
	for p: Dictionary in placements:
		left = minf(left, float(p["x"]) - float(p["w"]) * 0.5)
		right = maxf(right, float(p["x"]) + float(p["w"]) * 0.5)
	var shift: float = (left + right) * 0.5
	for p: Dictionary in placements:
		p["x"] = float(p["x"]) - shift
	var width_cells := int(round(right - left + WALL_MARGIN * 2.0))

	# ── 5. 背景两层随分区锚点落（行内推挤）────────────────────────────
	var zone_anchor: Dictionary = {}
	for p: Dictionary in placements:
		var zn: String = str(p["zone"])
		if zn == "core" or zn == "gate":
			continue
		zone_anchor[zn] = (float(zone_anchor.get(zn, p["x"])) + float(p["x"])) * 0.5
	var bg_rows := {1: [], 2: []}
	for i in mini(9, BG_POOL.size()):
		var d: String = BG_POOL[i]
		var row: int = 1 if i % 2 == 0 else 2
		var zone: String = BG_DEF_ZONE.get(d, "living")
		var anchor: float = float(zone_anchor.get(zone, 0.0))
		bg_rows[row].append({"def": d, "x": anchor + rng.randf_range(-9.0, 9.0),
			"w": float(widths.get(d, 8.0))})
	for row: int in [1, 2]:
		var bs: Array = bg_rows[row]
		bs.sort_custom(func(a, b): return float(a["x"]) < float(b["x"]))
		for i in range(1, bs.size()):
			var need: float = float(bs[i - 1]["x"]) + float(bs[i - 1]["w"]) * 0.5 + MIN_GAP + float(bs[i]["w"]) * 0.5
			if float(bs[i]["x"]) < need:
				bs[i]["x"] = need

	# ── 6. 道具随分区落 ───────────────────────────────────────────────
	var props: Array = []
	var zone_x := func(z: String) -> float:
		return float(zone_anchor.get(z, 0.0))
	var add_prop := func(card: String, z: String, dx: float, py: float, plat: bool = false) -> void:
		props.append({"card": card, "x": snappedf(float(zone_x.call(z)) + dx, 0.1),
			"z": py, "plat": plat})
	if int(prof["craft"]) > 0:
		add_prop.call("anvil", "craft", -1.1, 4.5, true)
		add_prop.call("grindstone", "craft", 1.6, 4.3, true)
	if int(prof["market"]) > 0:
		add_prop.call("well", "market", -2.5, 5.2)
		add_prop.call("market_stall", "market", 1.5, 4.6)
		add_prop.call("market_table", "market", 4.2, 5.6)
		add_prop.call("produce_baskets", "market", 6.5, 4.6)
	if int(prof["core"]) > 0:
		add_prop.call("banner", "core", -2.0, 4.5, true)
	if int(prof["storage"]) > 0:
		add_prop.call("crate", "storage", -1.5, 4.4, true)
		add_prop.call("barrel", "storage", 1.2, 4.2, true)
		add_prop.call("sack_stack", "storage", 3.6, 5.8)
	if int(prof["production"]) > 0:
		add_prop.call("haystack", "production", -2.0, 5.6)
		add_prop.call("log_pile", "production", 2.4, 6.0)
		add_prop.call("trough", "production", 5.0, 5.0)
	add_prop.call("bench", "market", -5.5, 5.0)
	add_prop.call("bench", "living", 2.0, 5.0)
	add_prop.call("lantern", "gate", -2.2, 4.6, true)
	add_prop.call("lantern", "gate", 2.2, 4.6, true)

	# ── 7. 组装（row0=前排，row1/2=背景两层）+ 产物级重叠修复 ─────────
	var buildings: Array = []
	for p: Dictionary in placements:
		var d: String = str(p["def"])
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


## 产物级修复：同排逐栋推挤，画面间隙保底（重叠不可能出现在产物里）
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
			var need: float = float(bs[i - 1]["x"]) + float(bs[i - 1]["cells"]) * 0.5 + MIN_GAP + float(bs[i]["cells"]) * 0.5
			if float(bs[i]["x"]) < need:
				bs[i]["x"] = snappedf(need, 0.01)
