class_name CityGen
extends RefCounted
## 初始城市生成器（GD 运行时版，与 tools/blender_buildings/gen_initial_city.py
## 同算法；建筑池按 docs/技术/架构/聚落等级与建筑分级.md 的**级别窗口表**取）。
##
## 语义（创始人 2026-09-15 裁决）：
##   · 城市大小 = 建筑排完的自然跨度 + 墙留边，不写死——建筑变多城市扩展，
##     城墙自动前移（运行时从 width_cells 推导），野地资源窗随之露出；
##   · 核心居中，市场/工匠/居住/生产四带随机分配到某侧（轻量配平，非镜像）；
##   · 居住/仓储随机塞；教堂等特殊建筑浮动插位；从中心向两侧逐栋排布；
##   · 画面宽推挤 + 产物级修复，零重叠；
##   · 背景两层（row1/row2）随分区锚点落。
##
## 选池铁律（级别窗口表 §三）：铁匠 3 级封顶、草棚/干草棚村舍进城消亡、
## 赌场 city 起、花店 town 起（DRESS）、仓库 city 起——别把村舍摆进首都。
## 行政槽：每档主街中心必有一件当级行政建筑（§二），候选按优先级取
## 第一张**已烘卡**（未烘自动降级，不阻塞生成）。
##
## 生成时机：宿主首次进入该城时按**确定性种子**生成（多局尽量一致）。

const MIN_GAP := 0.6
const WALL_MARGIN := 3.0

## 八档链（§一）。建筑数取档位区间下限（密度随扩建增长）。
## zones: 各分区建筑数；admin: 行政候选（取第一张已烘卡）；furniture: 街具数。
const TIERS := {
	"hamlet": {"cells": 80, "n": 10, "admin": ["council_hall_w8", "guildhall_w12"],
		"furniture": 4, "zones": {"market": 1, "craft": 1, "living": 3, "production": 1, "storage": 1}},
	"village": {"cells": 96, "n": 14, "admin": ["council_hall_w8", "guildhall_w12"],
		"furniture": 7, "zones": {"market": 2, "craft": 2, "living": 4, "production": 2, "storage": 1}},
	"townlet": {"cells": 112, "n": 16, "admin": ["council_hall_w8", "guildhall_w12"],
		"furniture": 8, "zones": {"market": 2, "craft": 3, "living": 5, "production": 2, "storage": 1}},
	"town": {"cells": 128, "n": 18, "admin": ["guildhall_w12"],
		"furniture": 10, "zones": {"market": 3, "craft": 3, "living": 5, "production": 3, "storage": 1}},
	"burgh": {"cells": 160, "n": 22, "admin": ["guildhall_w12"],
		"furniture": 12, "zones": {"market": 4, "craft": 4, "living": 6, "production": 3, "storage": 2}},
	"city": {"cells": 192, "n": 26, "admin": ["guildhall_w12"],
		"furniture": 13, "zones": {"market": 5, "craft": 4, "living": 8, "production": 4, "storage": 2}},
	"capital": {"cells": 256, "n": 40, "admin": ["governor_palace_w16", "guildhall_w12"],
		"furniture": 18, "zones": {"market": 9, "craft": 8, "living": 14, "production": 6, "storage": 3}},
	"metropolis": {"cells": 384, "n": 60, "admin": ["imperial_palace_w16", "governor_palace_w16"],
		"furniture": 24, "zones": {"market": 13, "craft": 13, "living": 20, "production": 8, "storage": 6}},
}

## 分区 def 池（按级别窗口表取**已烘卡**；运行时按 card_widths 过滤，
## 未烘的自动跳过——资产侧补烘后即生效，生成器无需改码）
const ZONE_POOLS := {
	"hamlet": {
		"core": ["council_hall_w8", "guildhall_w12"],
		"market": ["shop_w8"],
		"craft": ["smithy1_w8"],
		"living": ["cottage_w6", "house_w8", "house_w16"],
		"production": ["barn_w12"],
		"storage": ["shelter_w6", "hayloft_w8"],
	},
	"village": {
		"core": ["council_hall_w8", "guildhall_w12"],
		"market": ["shop_w8", "tavern_w12"],
		"craft": ["smithy1_w8", "smithy2_w8"],
		"living": ["house_w16", "house_w8", "house_w8", "cottage_w6", "hayloft_w8"],
		"production": ["barn_w12", "windmill_w6"],
		"storage": ["shelter_w6", "hayloft_w8"],
	},
	"townlet": {
		"core": ["council_hall_w8", "guildhall_w12"],
		"market": ["shop_w8", "bakery_w8"],
		"craft": ["smithy1_w8", "smithy2_w8", "alchemy_w8"],
		"living": ["house_w16", "house_w8", "house_w8", "cottage_w6", "hayloft_w8"],
		"production": ["barn_w12", "windmill_w6"],
		"storage": ["shelter_w6", "hayloft_w8"],
	},
	"town": {
		"core": ["guildhall_w12"],
		"market": ["shop_w8", "bakery_w8", "tavern_w12"],
		"craft": ["smithy1_w8", "smithy2_w8", "alchemy_w8"],
		"living": ["house_w16", "house_w8", "house_w8", "townhouse_w12", "hayloft_w8"],
		"production": ["barn_w12", "windmill_w6", "stable_w12"],
		"storage": ["shelter_w6", "hayloft_w8"],
	},
	"burgh": {
		"core": ["guildhall_w12"],
		"market": ["shop_w8", "bakery_w8", "tavern_w12", "shop_w8"],
		"craft": ["smithy1_w8", "smithy2_w8", "smithy3_w8", "alchemy_w8"],
		"living": ["house_w16", "house_w8", "townhouse_w12", "rowhouse_w12", "townhouse_w12", "house_w16"],
		"production": ["barn_w12", "windmill_w6", "stable_w12"],
		"storage": ["shelter_w6", "hayloft_w8"],
	},
	"city": {
		"core": ["guildhall_w12"],
		"float_extra": ["gambling_den_w8"],
		"market": ["shop_w8", "bakery_w8", "tavern_w12", "rowhouse_w12", "shop_w8"],
		"craft": ["smithy1_w8", "smithy2_w8", "smithy3_w8", "smithy4_w12", "alchemy_w8"],
		"living": ["house_w16", "house_w8", "townhouse_w12", "rowhouse_w12", "townhouse_w12",
			"rowhouse_w12", "house_w16", "house_w8"],
		"production": ["barn_w12", "stable_w12", "windmill_w6", "stable_w12"],
		"storage": ["warehouse_w16", "shelter_w6", "hayloft_w8"],
	},
	"capital": {
		"core": ["governor_palace_w16", "guildhall_w12"],
		"market": ["rowhouse_w12", "bakery_w8", "tavern_w12", "rowhouse_w12", "shop_w8",
			"tavern_w12", "flower_shop_w8", "rowhouse_w12", "bakery_w8"],
		"craft": ["smithy4_w12", "smithy3_w8", "alchemy_w8", "coach_house_w12",
			"smithy4_w12", "alchemy_w8", "coach_house_w12", "smithy3_w8"],
		"living": ["townhouse_w12", "rowhouse_w12", "house_w16", "townhouse_w12",
			"rowhouse_w12", "house_w16", "rowhouse_w12", "townhouse_w12",
			"house_w16", "rowhouse_w12", "townhouse_w12", "house_w16",
			"rowhouse_w12", "townhouse_w12"],
		"production": ["barn_w12", "stable_w12", "coach_house_w16", "barn_w12",
			"stable_w12", "coach_house_w16"],
		"storage": ["warehouse_w16", "warehouse_w16", "inn_post_w12"],
	},
	"metropolis": {
		"core": ["imperial_palace_w16", "governor_palace_w16"],
		"market": ["rowhouse_w12", "tavern_w12", "flower_shop_w8", "rowhouse_w12",
			"bakery_w8", "rowhouse_w12", "tavern_w12", "flower_shop_w8", "rowhouse_w12",
			"bakery_w8", "shop_w8", "rowhouse_w12", "tavern_w12"],
		"craft": ["smithy4_w12", "alchemy_w8", "academy_w12", "smithy4_w12",
			"alchemy_w8", "academy_w12", "coach_house_w16", "smithy4_w12",
			"alchemy_w8", "academy_w12", "observatory_w8", "coach_house_w16",
			"smithy4_w12"],
		"living": ["townhouse_w12", "rowhouse_w12", "house_w16", "rowhouse_w12",
			"townhouse_w12", "house_w16", "rowhouse_w12", "townhouse_w12",
			"house_w16", "rowhouse_w12", "townhouse_w12", "house_w16",
			"rowhouse_w12", "townhouse_w12", "rowhouse_w12", "townhouse_w12",
			"house_w16", "rowhouse_w12", "townhouse_w12", "house_w16"],
		"production": ["barn_w12", "stable_w12", "coach_house_w16", "inn_post_w12",
			"stable_w12", "coach_house_w16", "inn_post_w12", "stable_w12"],
		"storage": ["warehouse_w16", "warehouse_w16", "mint_w12", "warehouse_w16",
			"inn_post_w16", "warehouse_w16"],
	},
}

## 浮动建筑（不属分区，随机插位）：教堂 chapel（Lv1）/法师塔（平行不占级）/
## 城防塔——窗口内按档取
const FLOAT_DEFS := {
	"hamlet": ["cathedral_w8", "tower_w6"],
	"village": ["cathedral_w8", "mage_tower_w8", "tower_w6"],
	"townlet": ["cathedral_w8", "mage_tower_w8", "tower_w6"],
	"town": ["cathedral_w16", "mage_tower_w8", "tower_w6"],
	"burgh": ["cathedral_w16", "mage_tower_w8", "tower_w6"],
	"city": ["cathedral_w16", "mage_tower_w8", "tower_w6", "library_w12", "gambling_den_w8"],
	"capital": ["cathedral_w16", "mage_tower_w8", "tower_w6", "academy_w12",
		"gambling_den_w12", "mint_w12", "belfry_w6"],
	"metropolis": ["cathedral_w16", "mage_tower_w8", "tower_w6", "academy_w12",
		"grand_casino_w16", "mint_w12", "belfry_w6", "observatory_w8"],
}
const GATE_DEF := "gatehouse_w8"
const DOOR_DEFS := ["guildhall", "gatehouse", "shop", "tavern", "smithy1", "council_hall"]
const GROUND_DEFS := ["barn", "cottage"]

## 街具节奏（port 自 props.py dress_street 的 founder 定稿参数）：
## 灯距 8~12 格两侧错位；组距 10~16（长椅必配花）；喷泉留广场位；
## 公告板贴行政建筑；里程碑/路标守街口。档位街具数 = 表内 furniture。
const FURNITURE_LAMP_EVERY := Vector2(8.0, 12.0)
const FURNITURE_GROUP_EVERY := Vector2(10.0, 16.0)
const FURNITURE_LAMPS := ["lamp_post_stone", "lamp_post_iron", "lantern"]
const FURNITURE_GROUPS := [
	["bench_wood", "planter_ring"], ["bench_stone", "barrel_planter"],
	["horse_trough"], ["signpost"], ["milestone"], ["water_tap"],
]


## 道具卡名集合（props.json；街具节奏里的未烘卡由调用侧过滤）
static func prop_names() -> Dictionary:
	var out: Dictionary = {}
	for base_path: String in ["res://temp/proto_hd2d/props.json",
			"res://tests/dev/proto_hd2d/tex/proto_hd2d/props.json"]:
		if not FileAccess.file_exists(base_path):
			continue
		var f := FileAccess.open(base_path, FileAccess.READ)
		if f == null:
			continue
		var v: Variant = JSON.parse_string(f.get_as_text())
		if v is Array:
			for c: Variant in v:
				out[str(c["card"])] = true
			break
	return out


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
				"council_hall", "gatehouse"]:
			for w: int in [4, 6, 8, 12, 16]:
				out["%s_w%d" % [d, w]] = float(w) + 2.0
	return out


## 生成布局（tier ∈ TIERS；seed 确定性 → 多局尽量一致）。
## 返回 proto_hd2d 的 layout_data 契约（width_cells/buildings/props/trees）。
static func generate(tier: String, seed_v: int, prop_set: Dictionary = {}) -> Dictionary:
	var widths := card_widths()
	var prof: Dictionary = TIERS.get(tier, TIERS["townlet"])
	var pools: Dictionary = ZONE_POOLS.get(tier, ZONE_POOLS["townlet"])
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v

	# ── 1. 分区 → 侧位（随机序 + 轻量配平，非镜像）────────────────────
	var zones: Array = ["market", "craft", "living", "production", "storage"]
	zones.shuffle()
	var sides: Dictionary = {}
	var load := {-1: 0.0, 1: 0.0}
	for z: String in zones:
		var n: int = int(prof["zones"].get(z, 0))
		if n <= 0:
			sides[z] = 0
			continue
		var zload := 0.0
		for i in n:
			zload += float(widths.get(str(pools[z][i % pools[z].size()]), 8.0))
		var s := -1 if float(load[-1]) <= float(load[1]) else 1
		sides[z] = s
		load[s] = float(load[s]) + zload

	# ── 2. 各区塞够建筑（池内顺位循环；未烘卡过滤）────────────────────
	var queues: Dictionary = {}
	for z: String in zones:
		var defs: Array = []
		var n: int = int(prof["zones"].get(z, 0))
		for i in n:
			var d: String = str(pools[z][i % pools[z].size()])
			if widths.has(d) and not d in defs:
				defs.append(d)
		if defs.is_empty():
			defs.append("house_w8")   # 池全未烘兜底（民居通用填充件）
		defs.shuffle()
		queues[z] = defs

	# ── 3. 两侧序列拼接 + 浮动建筑随机插位（未烘过滤）─────────────────
	var seq := {-1: PackedStringArray(), 1: PackedStringArray()}
	for z: String in zones:
		var target: int = int(sides[z])
		if target == 0:
			target = -1 if rng.randf() < 0.5 else 1
		for d: String in queues[z]:
			seq[target].append(d)
	var float_list: Array = []
	for d: String in FLOAT_DEFS.get(tier, []):
		float_list.append(d)
	for d: String in ZONE_POOLS.get(tier, {}).get("float_extra", []):
		if widths.has(d):
			float_list.append(d)
	for d: String in float_list:
		if not widths.has(d):
			continue
		var side2: int = -1 if rng.randf() < 0.5 else 1
		var at: int = rng.randi_range(0, seq[side2].size())
		seq[side2].insert(at, d)

	# ── 4. 行政居中（当级行政槽，§二），从中心向两侧排布（推挤保底）────
	var admin: String = "guildhall_w12"
	for d: String in prof["admin"]:
		if widths.has(d):
			admin = d
			break
	var placements: Array = []   # {def, x, w, zone}
	var w_a := float(widths.get(admin, 12.0))
	placements.append({"def": admin, "x": 0.0, "w": w_a, "zone": "core"})
	var cursor := {-1: -w_a * 0.5 - MIN_GAP, 1: w_a * 0.5 + MIN_GAP}
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

	# 城心 = 行政建筑（x=0 不再按跨度平移——出生点/广场贴着行政槽，创始人
	# 2026-09-15：别让出生点贴着城边）；墙线取两侧最远需求（对称城门）
	var left := INF
	var right := -INF
	for p: Dictionary in placements:
		left = minf(left, float(p["x"]) - float(p["w"]) * 0.5)
		right = maxf(right, float(p["x"]) + float(p["w"]) * 0.5)
	var wall_x: float = maxf(right, -left) + WALL_MARGIN
	var width_cells := int(round(wall_x * 2.0))

	# ── 5. 背景两层随分区锚点落（行内推挤）────────────────────────────
	var zone_anchor: Dictionary = {}
	for p: Dictionary in placements:
		var zn: String = str(p["zone"])
		if zn == "core" or zn == "gate":
			continue
		zone_anchor[zn] = (float(zone_anchor.get(zn, float(p["x"]))) + float(p["x"])) * 0.5
	var bg_rows := {1: [], 2: []}
	var bg_i := 0
	for p: Dictionary in placements:
		var zn2: String = str(p["zone"])
		if zn2 == "core" or zn2 == "gate":
			continue
		var zpool: Array = pools.get(zn2, ["house_w8"])
		for k in 2:
			var d: String = str(zpool[(bg_i + k) % zpool.size()])
			bg_i += 1
			var row: int = 1 if bg_i % 2 == 0 else 2
			var anchor: float = float(zone_anchor.get(zn2, float(p["x"])))
			bg_rows[row].append({"def": d, "x": anchor + rng.randf_range(-9.0, 9.0),
				"w": float(widths.get(d, 8.0))})
	# 背景跨度契约（创始人：后景只比前景短几格）——每排线性拉伸到
	# 前排跨度各收 3 格，拉伸后再行内推挤（间隙只增不减）
	var front_lo: float = INF
	var front_hi: float = -INF
	for p: Dictionary in placements:
		front_lo = minf(front_lo, float(p["x"]) - float(p["w"]) * 0.5)
		front_hi = maxf(front_hi, float(p["x"]) + float(p["w"]) * 0.5)
	var front_span: float = front_hi - front_lo
	for row: int in [1, 2]:
		var bs: Array = bg_rows[row]
		bs.sort_custom(func(a, b): return float(a["x"]) < float(b["x"]))
		if bs.is_empty():
			continue
		var lo: float = float(bs[0]["x"]) - float(bs[0]["w"]) * 0.5
		var hi: float = float(bs[bs.size() - 1]["x"]) + float(bs[bs.size() - 1]["w"]) * 0.5
		var target_lo: float = front_lo + 3.0
		var target_hi: float = front_hi - 3.0
		if hi - lo > 1.0 and target_hi - target_lo > hi - lo:
			var k: float = (target_hi - target_lo) / (hi - lo)
			var mid: float = (lo + hi) * 0.5
			for b: Dictionary in bs:
				b["x"] = mid + (float(b["x"]) - mid) * k
		for i in range(1, bs.size()):
			var need: float = float(bs[i - 1]["x"]) + float(bs[i - 1]["w"]) * 0.5 + MIN_GAP + float(bs[i]["w"]) * 0.5
			if float(bs[i]["x"]) < need:
				bs[i]["x"] = need

	# ── 6. 道具：功能件随分区 + 街具节奏（dress_street 参数移植）───────
	var props: Array = []
	var zone_x := func(z: String) -> float:
		return float(zone_anchor.get(z, 0.0))
	var add_prop := func(card: String, zx: float, py: float, plat: bool = false) -> void:
		props.append({"card": card, "x": snappedf(zx, 0.1), "z": py, "plat": plat})
	# 功能件
	if pools.has("craft"):
		add_prop.call("anvil", float(zone_x.call("craft")) - 1.1, 4.5, true)
		add_prop.call("grindstone", float(zone_x.call("craft")) + 1.6, 4.3, true)
	if pools.has("market"):
		add_prop.call("well", float(zone_x.call("market")) - 2.5, 5.2)
		add_prop.call("market_stall", float(zone_x.call("market")) + 1.5, 4.6)
		add_prop.call("market_table", float(zone_x.call("market")) + 4.2, 5.6)
		add_prop.call("produce_baskets", float(zone_x.call("market")) + 6.5, 4.6)
	add_prop.call("banner", float(zone_x.call("core")) - 2.0, 4.5, true)
	# 街具节奏：灯两侧错位（周期 8~12 格内确定性抽取）+ 组槽（10~16 格，
	# 长椅必配花）+ 广场喷泉（市场锚点）+ 街口路标/里程碑
	var furniture_n: int = int(prof["furniture"])
	var period: float = rng.randf_range(FURNITURE_LAMP_EVERY.x, FURNITURE_LAMP_EVERY.y)
	var lamp_card: String = FURNITURE_LAMPS[0] if widths.has(FURNITURE_LAMPS[0]) else "lantern"
	var xx := -width_cells * 0.5 + 6.0
	var side := 1
	while xx < width_cells * 0.5 - 6.0:
		add_prop.call(lamp_card, xx, 4.6 if side > 0 else 6.2, side > 0)
		xx += period
		side = -side
	var gx := -width_cells * 0.5 + 10.0
	var gi := 0
	while gx < width_cells * 0.5 - 10.0:
		var grp: Array = FURNITURE_GROUPS[gi % FURNITURE_GROUPS.size()]
		for d: String in grp:
			if prop_set.is_empty() or prop_set.has(d):
				add_prop.call(d, gx + rng.randf_range(-1.0, 1.0),
						5.0 if d.begins_with("bench") else 4.8, d.begins_with("bench"))
		gx += rng.randf_range(FURNITURE_GROUP_EVERY.x, FURNITURE_GROUP_EVERY.y)
		gi += 1
	if pools.has("market"):
		add_prop.call("fountain_small", float(zone_x.call("market")) + 9.0, 5.4)
	add_prop.call("signpost", -width_cells * 0.5 + 3.0, 5.0)
	add_prop.call("milestone", width_cells * 0.5 - 3.0, 5.0)

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
