## 城市规模分级与布局算法。
## 规模 → 城墙高度 / 建筑数量 / 地面材质 / 功能区配比；按"核心→市场→工匠→居住→生产"由中心向两侧展开。
## 分级口径对齐项目设定：docs/设计/系统/08-程序化世界生成.md（T1村落~T5首都）、
## tools/worldgen/l1/city_profiles.json（hamlet 2560 / town 4096 / city 6144 px）、
## 城墙像素高 64/128/192（tier1/2/3）。
extends RefCounted

const Registry := preload("res://tools/building_pipeline/registry.gd")

## 规模档：wall_h 为城墙像素高（1x），buildings 为目标建筑数量，ground 为城内地面材质。
const TIERS := {
	"hamlet": {"label": "村落", "wall_h": 130, "wall_tier": 1, "buildings": 11, "ground": "grass", "has_gate": true},
	"village": {"label": "村庄", "wall_h": 200, "wall_tier": 2, "buildings": 15, "ground": "grass", "has_gate": true},
	"town": {"label": "镇", "wall_h": 320, "wall_tier": 2, "buildings": 20, "ground": "dirt", "has_gate": true},
	"city": {"label": "城市", "wall_h": 460, "wall_tier": 3, "buildings": 26, "ground": "cobble", "has_gate": true},
}

## 功能区（由中心向两侧交替展开）：核心 → 市场 → 工匠 → 居住 → 生产。
const ZONES := [
	{"name": "核心", "pool": ["guildhall", "church", "chapel"]},
	{"name": "市场", "pool": ["tavern", "bakery", "shop", "market_stall", "well"]},
	{"name": "工匠", "pool": ["smithy2", "smithy3", "smithy4", "stable", "stone_upper"]},
	{"name": "居住", "pool": ["house", "townhouse", "plaster_house", "cottage", "stone_upper"]},
	{"name": "生产", "pool": ["barn", "windmill", "shelter", "stable"]},
]

## 各 def 在城市里使用的代表宽度（格）；未列出者取 registry 宽度档中位数。
const CITY_WIDTH := {
	"guildhall": 12, "church": 12, "chapel": 6,
	"tavern": 8, "bakery": 6, "shop": 4, "market_stall": 4, "well": 3,
	"smithy2": 6, "smithy3": 6, "smithy4": 8, "stable": 6, "stone_upper": 6,
	"house": 6, "townhouse": 6, "plaster_house": 6, "cottage": 4,
	"barn": 8, "windmill": 4, "shelter": 4,
}


## 生成城市布局：返回 {tier, label, wall_h, wall_tier, ground, has_gate, buildings:[{def,w,zone,side}], total_w}
## side: 0=中心, -1=左侧, 1=右侧（由中心向两侧交替填入）
static func plan(tier: String, seed_val: int) -> Dictionary:
	var cfg: Dictionary = TIERS.get(tier, TIERS["town"])
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
	var total: int = int(cfg["buildings"])

	# 逐块取功能区：核心占 2 栋、市场 ~22%、工匠 ~22%、居住 ~40%、生产 ~16%
	var zone_quota := _zone_quota(total, rng)
	var left: Array = []
	var right: Array = []
	var used := {}
	var zidx := 0
	var remaining := total
	while remaining > 0:
		var zone: Dictionary = ZONES[zidx % ZONES.size()]
		var quota: int = zone_quota[zidx % zone_quota.size()]
		for k in quota:
			if remaining <= 0:
				break
			var def := _pick(zone["pool"], used, rng)
			var w: int = int(CITY_WIDTH.get(def, 6))
			var item := {"def": def, "w": w, "zone": String(zone["name"])}
			if left.size() <= right.size():
				left.append(item)
			else:
				right.append(item)
			remaining -= 1
			used[def] = true
		zidx += 1
	# 中心区放在中间：左列表反转后 + 右列表 → 中心在中间
	left.reverse()
	var buildings: Array = []
	for it in left:
		buildings.append(it)
	for it in right:
		buildings.append(it)
	var total_w := 0
	for b_v in buildings:
		var b: Dictionary = b_v
		total_w += int(b["w"]) * 32
	return {
		"tier": tier,
		"label": String(cfg["label"]),
		"wall_h": int(cfg["wall_h"]),
		"wall_tier": int(cfg["wall_tier"]),
		"ground": String(cfg["ground"]),
		"has_gate": bool(cfg["has_gate"]),
		"buildings": buildings,
		"total_w": total_w,
		"seed": seed_val,
	}


static func _zone_quota(total: int, rng: RandomNumberGenerator) -> Array:
	var core := 2
	var market := maxi(2, roundi(float(total) * rng.randf_range(0.18, 0.26)))
	var craft := maxi(2, roundi(float(total) * rng.randf_range(0.18, 0.26)))
	var rural := maxi(1, roundi(float(total) * rng.randf_range(0.12, 0.2)))
	var live := maxi(2, total - core - market - craft - rural)
	return [core, market, craft, live, rural]


static func _pick(pool: Array, used: Dictionary, rng: RandomNumberGenerator) -> String:
	# 优先未出现过（避免同型连排），池空则放开
	var fresh: Array = []
	for d in pool:
		if not used.has(String(d)):
			fresh.append(d)
	var src: Array = fresh if not fresh.is_empty() else pool
	return String(src[rng.randi_range(0, src.size() - 1)])
