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
		"float_extra": ["gambling_den_w8"],
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
	"city": ["cathedral_w16", "mage_tower_w8", "tower_w6", "library_w12", "gambling_den_w8"],
	"capital": ["cathedral_w16", "mage_tower_w8", "tower_w6", "academy_w12",
		"gambling_den_w12", "mint_w12", "belfry_w6"],
	"metropolis": ["cathedral_w16", "mage_tower_w8", "tower_w6", "academy_w12",
		"grand_casino_w16", "mint_w12", "belfry_w6", "observatory_w8"],
}
const GATE_DEF := "gatehouse_w8"
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
## 一格/两格空位：小概率塞入建筑序列的占格空档（不出任何卡）——街景偶尔
## 出现刻意的整格留白（创始人：较小概率随机出现，偶尔两格宽）
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


## 道具卡宽表（格 = props.json units[0]/32；兼当"已烘卡名集合"用——
## has()/is_empty() 语义与卡名集合一致，值=卡画面宽供组内肩并肩排布）。
## 街具节奏里的未烘卡由调用侧过滤。
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
				out[str(c["card"])] = float(c["units"][0]) / 32.0
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
	var prop_fp := prop_footprints()   # 杂物占格宽/贴楼 z 用（footprint=[宽,纵深]）
	var prof: Dictionary = TIERS.get(tier, TIERS["townlet"])
	var pools: Dictionary = ZONE_POOLS.get(tier, ZONE_POOLS["townlet"])
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v

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
				if d == GAP_SLOT or d == GAP_SLOT_WIDE:
					# 刻意留白：占 1~2 整格不出卡
					var gw: float = 2.0 if d == GAP_SLOT_WIDE else 1.0
					var xg: float = float(cursor[s]) + s * gw * 0.5
					placements.append({"def": d, "x": xg, "w": gw, "zone": "gap",
						"gap": true})
					cursor[s] = float(cursor[s]) + s * (gw + MIN_GAP)
				else:
					# 杂物占格宽按**真实地面占地**（footprint[0]）向上取整——画面宽
					# 含透视外扩，按它取整会让盆/筐这类小件虚占 2~3 格（创始人
					# 2026-09-15 指正）；卡库缺失兜底 footprint [2.0,1.5]→2 格。
					# 建筑照旧查卡宽表。
					var w_default := 2.0 if clutter_all.has(d) else float(widths.get(d, 8.0))
					var w := float(prop_set.get(d, w_default))
					if clutter_all.has(d):
						var fpw: Array = prop_fp.get(d, [2.0, 1.5])
						w = ceilf(float(fpw[0]))
					var x: float = float(cursor[s]) + s * w * 0.5
					var zone := "float"
					if clutter_all.has(d):
						zone = "clutter"
					else:
						for z: String in queues:
							if d in queues[z]:
								zone = z
								break
					placements.append({"def": d, "x": x, "w": w, "zone": zone,
						"clutter": clutter_all.has(d)})
					cursor[s] = float(cursor[s]) + s * (w + MIN_GAP)
	for s: int in [-1, 1]:
		var w2 := float(widths.get(GATE_DEF, 10.5))
		var x2: float = float(cursor[s]) + s * w2 * 0.5
		placements.append({"def": GATE_DEF, "x": x2, "w": w2, "zone": "gate", "door": true})
		cursor[s] = float(cursor[s]) + s * (w2 + MIN_GAP)

	# 城市中心 = 前排跨度中点（创始人 2026-09-15：出生点应在城市中心——
	# 分区非对称时行政槽自然偏于一侧属城区分布，出生点仍落跨度正中）
	var left := INF
	var right := -INF
	for p: Dictionary in placements:
		left = minf(left, float(p["x"]) - float(p["w"]) * 0.5)
		right = maxf(right, float(p["x"]) + float(p["w"]) * 0.5)
	var shift: float = (left + right) * 0.5
	for p: Dictionary in placements:
		p["x"] = float(p["x"]) - shift
	# 整格吸附（创始人 2026-09-15：建筑位置必须整格摆放——宽度本就是格
	# 整数倍）：中心取整，同排整格步进推开（间隙承诺 ≥MIN_GAP 由整格步距
	# ≥1 格兑现），再把跨度中点回正（整数平移保持整格）
	for p: Dictionary in placements:
		p["x"] = float(roundi(float(p["x"])))
	placements.sort_custom(func(a, b): return float(a["x"]) < float(b["x"]))
	for i in range(1, placements.size()):
		var need_i: float = float(placements[i - 1]["x"]) + float(placements[i - 1]["w"]) * 0.5 \
				+ MIN_GAP + float(placements[i]["w"]) * 0.5
		if float(placements[i]["x"]) < need_i:
			placements[i]["x"] = float(ceilf(need_i))
	left = INF
	right = -INF
	for p: Dictionary in placements:
		left = minf(left, float(p["x"]) - float(p["w"]) * 0.5)
		right = maxf(right, float(p["x"]) + float(p["w"]) * 0.5)
	var mid_shift := (left + right) * 0.5
	if absf(mid_shift) >= 0.5:
		for p: Dictionary in placements:
			p["x"] = float(p["x"]) - roundf(mid_shift)
	left = INF
	right = -INF
	for p: Dictionary in placements:
		left = minf(left, float(p["x"]) - float(p["w"]) * 0.5)
		right = maxf(right, float(p["x"]) + float(p["w"]) * 0.5)
	var width_cells := int(round(right - left + WALL_MARGIN * 2.0))

	# ── 5. 背景两层随分区锚点落（行内推挤）────────────────────────────
	var zone_anchor: Dictionary = {}
	for p: Dictionary in placements:
		var zn: String = str(p["zone"])
		if zn == "core" or zn == "gate" or zn == "clutter" or zn == "gap":
			continue
		zone_anchor[zn] = (float(zone_anchor.get(zn, float(p["x"]))) + float(p["x"])) * 0.5
	var bg_rows := {1: [], 2: []}
	var bg_i := 0
	for p: Dictionary in placements:
		var zn2: String = str(p["zone"])
		if zn2 == "core" or zn2 == "gate" or zn2 == "clutter" or zn2 == "gap":
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
	# 喷泉：镇起的广场位（市场锚点侧翼，+9 侧放不下试 −9 侧；小村落没喷泉）
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

	# ── 7. 组装（row0=前排，row1/2=背景两层）+ 产物级重叠修复 ─────────
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


## 道具卡占地表：props.json footprint = [宽格, 纵深格]——杂物占格宽按**真实
## 地面占地宽**（footprint[0]）向上取整（画面宽含透视外扩，按它取整小件
## 虚占格子），贴楼脚 z 落深按纵深分量（footprint[1]）推导。
static func prop_footprints() -> Dictionary:
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
				var fp: Variant = c.get("footprint", [1.5, 1.5])
				var fpa: Array = fp if fp is Array else [1.5, 1.5]
				out[str(c["card"])] = [float(fpa[0]) if fpa.size() > 0 else 1.5,
						float(fpa[1]) if fpa.size() > 1 else 1.5]
			break
	return out


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


## 种子驱动洗牌（Fisher-Yates）：替代 Array.shuffle()——后者用全局随机源，
## 不吃 rng.seed，会破坏生成器的确定性契约
static func _shuffle_rng(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp: Variant = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


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
			var need: float = float(bs[i - 1]["x"]) + float(bs[i - 1]["cells"]) * 0.5 + MIN_GAP + float(bs[i]["cells"]) * 0.5
			if float(bs[i]["x"]) < need:
				bs[i]["x"] = snappedf(ceilf(need), 0.01)
