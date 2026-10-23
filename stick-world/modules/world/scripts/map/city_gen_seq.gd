extends RefCounted
## 城市生成·主街序列规划域（city_gen 管线第 1~3.7 段，由 CityGen.generate 编排）。
## 职责：档位配置解析 → 分区侧位配平 → 各区建筑队列 → 两侧序列拼接
## （浮动建筑插位 / 杂物占格 / 刻意空档 / 前排 2 层补额）。
## 纯静态纯函数：入参状态、出参结果，rng 显式传参（种子驱动，确定性契约）。
## 属主常量：TIERS / ZONE_POOLS / FLOAT_DEFS / TALL2_* / GAP_*。

## 八档链（§一）。建筑数取档位区间下限（密度随扩建增长）。
## zones: 各分区建筑数；admin: 行政候选（取第一张已烘卡）；furniture: 街具数
## （街具组已删、字段暂留不用）。
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
		"market": ["shop_w8", "tavern_w12", "bakery_w8"],
		"craft": ["smithy1_w8", "smithy2_w8", "alchemy_w8"],
		"living": ["house_w16", "house_w8", "house_w8", "cottage_w6", "hayloft_w8"],
		"production": ["barn_w12", "windmill_w6"],
		"storage": ["shelter_w6", "hayloft_w8"],
	},
	"town": {
		"core": ["guildhall_w12"],
		"market": ["shop_w8", "bakery_w8", "tavern_w12"],
		"craft": ["smithy1_w8", "smithy2_w8", "alchemy_w8"],
		"living": ["house_w16", "townhouse_w12", "house_w8", "rowhouse_w12", "hayloft_w8"],
		"production": ["inn_post_w12", "barn_w12", "stable_w12", "windmill_w6"],
		"storage": ["shelter_w6", "hayloft_w8"],
	},
	"burgh": {
		"core": ["guildhall_w12"],
		"market": ["shop_w8", "tavern_w12", "bakery_w8", "rowhouse_w12"],
		"craft": ["smithy1_w8", "smithy2_w8", "smithy3_w8", "alchemy_w8"],
		"living": ["house_w16", "house_w8", "townhouse_w12", "rowhouse_w12", "townhouse_w12", "house_w16"],
		"production": ["inn_post_w12", "barn_w12", "stable_w12", "windmill_w6"],
		"storage": ["shelter_w6", "hayloft_w8"],
	},
	"city": {
		"core": ["guildhall_w12"],
		"market": ["rowhouse_w12", "tavern_w12", "bakery_w8", "shop_w8", "flower_shop_w8"],
		"craft": ["smithy1_w8", "smithy2_w8", "smithy3_w8", "smithy4_w12", "alchemy_w8"],
		"living": ["house_w16", "house_w8", "townhouse_w12", "rowhouse_w12", "townhouse_w12",
			"rowhouse_w12", "house_w16", "house_w8"],
		"production": ["barn_w12", "stable_w12", "windmill_w6", "stable_w12"],
		"storage": ["inn_post_w12", "warehouse_w16", "shelter_w6", "hayloft_w8"],
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
	"village": ["abbey_w24", "cathedral_w8", "mage_tower_w8", "tower_w6"],
	"townlet": ["abbey_w24", "cathedral_w8", "mage_tower_w8", "tower_w6"],
	"town": ["cathedral_w16", "mage_tower_w8", "tower_w6"],
	"burgh": ["cathedral_w16", "mage_tower_w8", "tower_w6"],
	"city": ["cathedral_w16", "mage_tower_w8", "tower_w6", "library_w12"],
	"capital": ["cathedral_w16", "mage_tower_w8", "tower_w6", "academy_w12",
		"mint_w12", "belfry_w6"],
	"metropolis": ["cathedral_w16", "mage_tower_w8", "tower_w6", "academy_w12",
		"mint_w12", "belfry_w6", "observatory_w8"],
}

## 一格/两格空位：小概率塞入建筑序列的占格空档（不出任何卡）——街景偶尔
## 出现刻意的整格留白（创始人：较小概率随机出现，偶尔两格宽）。
## 识别端在排布域（city_gen_layout 第 4 段按同名字面量比对）。
const GAP_SLOT := "_gap"
const GAP_SLOT_WIDE := "_gap2"
const GAP_SLOT_CHANCE := 0.09
const GAP_SLOT_WIDE_CHANCE := 0.03

## 前排 2 层卡白名单（已烘、立面节奏用；档位可得性由各区池守级别窗口——
## 只对池内已出现的 def 复制补位，不越级引进新 def）。千篇一律一层楼的
## 解法：按档配额保前排 2 层占比（townlet 2 / town 5 / burgh 8 / city 9 /
## capital 14 / metropolis 18，hamlet/village 村貌不上配额）。
const TALL2_DEFS := ["tavern", "townhouse", "rowhouse", "inn_post",
	"coach_house", "academy", "mint", "barracks", "library"]
const TALL2_QUOTA := {"townlet": 2, "town": 5, "burgh": 8, "city": 9,
	"capital": 14, "metropolis": 18}


## 档位配置解析（TIERS/ZONE_POOLS 属主在本文件；缺档回退 townlet，
## 编排层 city_gen.gd 经此取 prof/pools，不直查常量）。
static func resolve_profile(tier: String) -> Dictionary:
	return {"prof": TIERS.get(tier, TIERS["townlet"]),
			"pools": ZONE_POOLS.get(tier, ZONE_POOLS["townlet"])}


## 步骤 1+2：分区侧位配平 + 各区建筑队列。
## 返回 {"sides": {zone: -1/0/1}, "queues": {zone: Array[String def]}}。
static func _step_zone_queues(prof: Dictionary, pools: Dictionary,
		widths: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	# ── 1. 分区 → 侧位（随机序 + 轻量配平，非镜像）────────────────────
	# 洗牌必须走 rng（种子驱动）——Array.shuffle() 用全局随机源，会让
	# 同种子每次进城街区侧位重排，"确定性种子→多局尽量一致"契约即破。
	var zones: Array = ["market", "craft", "living", "production", "storage"]
	_shuffle_rng(zones, rng)
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

	# ── 2. 各区塞够建筑（池内顺位循环；未烘卡过滤；2 层卡每区放宽到 2 张
	#    ——连排街屋本就同款相邻，配额靠它凑数）────────────────────────
	var queues: Dictionary = {}
	for z: String in zones:
		var defs: Array = []
		var n: int = int(prof["zones"].get(z, 0))
		for i in n:
			var d: String = str(pools[z][i % pools[z].size()])
			var dup_ok: bool = TALL2_DEFS.has(d.rsplit("_w", true, 1)[0]) \
					and defs.count(d) < 2
			if widths.has(d) and (not d in defs or dup_ok):
				defs.append(d)
		if defs.is_empty():
			defs.append("house_w8")   # 池全未烘兜底（民居通用填充件）
		_shuffle_rng(defs, rng)
		queues[z] = defs
	return {"sides": sides, "queues": queues}


## 步骤 3~3.7：两侧序列拼接 + 浮动建筑随机插位（未烘过滤）+ 杂物占格/
## 刻意空档 + 前排 2 层配额补位。
## 返回 {"seq": {-1/1: PackedStringArray}, "clutter": {杂物def: true}}。
static func _step_build_sequences(tier: String, pools: Dictionary,
		widths: Dictionary, prop_set: Dictionary, sides: Dictionary,
		queues: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	# ── 3. 两侧序列拼接 + 浮动建筑随机插位（未烘过滤）─────────────────
	var seq := {-1: PackedStringArray(), 1: PackedStringArray()}
	# queues 键序 = 步骤 1 的分区洗牌序（Dictionary 保插入序），与原实现遍历
	# zones 数组逐位同序，rng 调用序列不变
	for z: String in queues:
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

	# ── 3.5 建筑间杂物（占格件，创始人定案）：与建筑同 Z 的杂物默认占水平
	#     格——塞入所属分区侧序列的随机位置段，随建筑一起整格排布推挤；
	#     随机插入位让空档分布不均（偶尔空一格自然出现）。未烘卡跳过。
	#     2026-09-16 创始人定案"小件全撤"：杂物缩回仓储/生产两带（箱桶麻袋
	#     /草垛柴堆料槽——都是撑得起两格以上槽位的体量件），盆/筐/花箱等
	#     又矮又小的不上街。
	var clutter_defs := {
		"storage": ["crate", "barrel", "sack_stack"],
		"production": ["haystack", "log_pile", "trough"],
	}
	var clutter_per_zone: int = 1 if tier in ["hamlet", "village", "townlet"] else 2
	var clutter_all: Dictionary = {}
	for z: String in clutter_defs:
		var side3: int = int(sides.get(z, 0))
		if side3 == 0:
			side3 = -1 if rng.randf() < 0.5 else 1
		var lst: Array = (clutter_defs[z] as Array).duplicate()
		_shuffle_rng(lst, rng)
		var taken := 0
		for d: String in lst:
			if taken >= clutter_per_zone:
				break
			if not prop_set.is_empty() and not prop_set.has(d):
				continue
			clutter_all[d] = true
			seq[side3].insert(rng.randi_range(0, seq[side3].size()), d)
			taken += 1
	# 一格/两格空位：从尾向头插（插入不扰动未遍历下标），每位置小概率出空档
	for gap_side: int in [-1, 1]:
		var gi2: int = int(seq[gap_side].size()) - 1
		while gi2 >= 0:
			var r: float = rng.randf()
			if r < GAP_SLOT_WIDE_CHANCE:
				seq[gap_side].insert(gi2, GAP_SLOT_WIDE)
			elif r < GAP_SLOT_WIDE_CHANCE + GAP_SLOT_CHANCE:
				seq[gap_side].insert(gi2, GAP_SLOT)
			gi2 -= 1

	# ── 3.7 前排 2 层配额（创始人：主街别千篇一律一层楼）：配额按档取
	#     （TALL2_QUOTA），缺额从已有 2 层卡的区队列复制补位（每 def ≤2 张，
	#     连排街屋同款相邻属真实肌理）；池内无 2 层卡（hamlet/village）不动。
	var quota: int = int(TALL2_QUOTA.get(tier, 0))
	if quota > 0:
		var n_tall := 0
		for s: int in [-1, 1]:
			for d: String in seq[s]:
				if TALL2_DEFS.has(str(d).rsplit("_w", true, 1)[0]):
					n_tall += 1
		var guard := 0
		while n_tall < quota and guard < 32:
			guard += 1
			var placed := false
			for z: String in queues:
				for d: String in queues[z]:
					if TALL2_DEFS.has(d.rsplit("_w", true, 1)[0]):
						var side4: int = int(sides.get(z, -1))
						if side4 == 0:
							continue
						seq[side4].append(d)
						n_tall += 1
						placed = true
						break
				if placed:
					break
			if not placed:
				break
	return {"seq": seq, "clutter": clutter_all}


## 种子驱动洗牌（Fisher-Yates）：替代 Array.shuffle()——后者用全局随机源，
## 不吃 rng.seed，会破坏生成器的确定性契约
static func _shuffle_rng(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp: Variant = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp
