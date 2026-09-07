class_name GarrisonSpawner
extends RefCounted
## 守军生成器 —— 按 ConquestAnchor 布阵 + territories 配置刷据点守军。
##
## 出处：docs/技术/架构/出征与领地架构.md §一/§2.3/§4.3（本类为 C4 落地）。
## 职责边界：只刷军不开战——监听 map_loaded 与 CombatApi.start_battle 的接敌
## 编排归 ConquestManager（批次 C5）。刷单位照 initial_content 先例走
## UnitsApi 场景常量 + MapBase.spawn_entity（兵种档案经 spawn 的 def_id 参数
## 在进树前写入，实体 _ready 拉数值）。
##
## 车轮战持久化：剩余守军 = 配置 count 之和 − WorldState.territories[id]
## .garrison_losses（败仗战损累计，ConquestManager 批次 C5 写入）；逐条目从
## 头部填满（前排主力优先满编，后排先缺）。已臣服据点（CAPTURED）短路不刷。
## 敌将（commander）不受 garrison_losses 影响，每次进图均在位。

## 守军单位来源标记（调试/测试识别；战斗侧不读）
const META_GARRISON_UNIT := "garrison_unit"
## 守军战术档位透传（tactics.tres 的战术 id；行为消费端待战术系统实装）
const META_GARRISON_TIER := "garrison_tier"
## 无锚点 fallback：布阵 x 起点 / 间距（相对地图右侧半区）
const FALLBACK_START_RATIO := 0.64
const FALLBACK_SLOT_SPACING := 105.0

## 单位场景经 UnitsApi 常量引用（不直接 preload 模块内部路径）
const _STICKMAN_SCENE: PackedScene = UnitsAPI.STICKMAN_ENTITY_SCENE

## variant（stickmen.tres）→ 武器类型；未知 variant 保持默认剑
const _VARIANT_WEAPONS := {
	"sword": WeaponMount.WeaponType.SWORD,
	"spear": WeaponMount.WeaponType.SPEAR,
	"bow": WeaponMount.WeaponType.BOW,
	"staff": WeaponMount.WeaponType.STAFF,
	"pickaxe": WeaponMount.WeaponType.PICKAXE,
	"meric": WeaponMount.WeaponType.MERIC,
}

var _registry: TerritoryRegistry = null
## 无锚点警告每图只发一次（fallback 属可玩降级，不刷屏）
var _warned_maps: Dictionary = {}


## 注入领地清单（与 expansion/api.gd 共享同一实例）
func setup(registry: TerritoryRegistry) -> void:
	_registry = registry


## 按配置刷据点守军（含敌将），返回全部守军实体数组（供 ConquestManager
## 开战传 defenders；空数组 = 已臣服/配置缺失/无可刷条目）。
func spawn_garrison(map: Node2D, territory_id: String) -> Array:
	var row := get_effective_row(territory_id)
	if row.is_empty() or map == null:
		return []
	var anchor: ConquestAnchor = ConquestAnchor.find_in(map)
	if anchor == null and not _warned_maps.has(map):
		_warned_maps[map] = true
		push_warning("[GarrisonSpawner] %s 未挂 ConquestAnchor，按程序化布阵 fallback" % map.name)
	var slots: Array[Vector2] = _resolve_slots(map, anchor)
	var spawned: Array = []
	var slot_i := 0
	for entry in row.get("garrison", []):
		if not (entry is Dictionary):
			continue
		var profile := String(entry.get("profile", ""))
		var tier := String(entry.get("tier", ""))
		for i in int(entry.get("count", 0)):
			var pos := _slot_position(map, anchor, slots, slot_i)
			slot_i += 1
			var u := _spawn_unit(map, pos, profile)
			if u == null:
				continue
			u.set_meta(META_GARRISON_UNIT, true)
			if not tier.is_empty():
				u.set_meta(META_GARRISON_TIER, tier)
			spawned.append(u)
	# 敌将（不受车轮战扣减；无锚点时布在守军阵末位之后）
	var commander: Dictionary = row.get("commander", {}) if row.get("commander", {}) is Dictionary else {}
	var cmd_profile := String(commander.get("profile", ""))
	if not cmd_profile.is_empty():
		var cmd_pos: Vector2
		var anchor_pos: Vector2 = anchor.get_commander_position() if anchor != null else Vector2.INF
		if anchor_pos.is_finite():
			cmd_pos = anchor_pos
		else:
			cmd_pos = _slot_position(map, anchor, slots, slot_i)
		var c := _spawn_unit(map, cmd_pos, cmd_profile)
		if c != null:
			c.set_meta(META_GARRISON_UNIT, true)
			spawned.append(c)
	return spawned


## 车轮战扣减后的有效配置（garrison 条目 count 已扣减 garrison_losses；
## 配置缺失返回空字典）。扣减语义：剩余配额从头部条目填满，后排先缺。
func get_effective_row(territory_id: String) -> Dictionary:
	if _registry == null or not _registry.has_territory(territory_id):
		return {}
	var row: Dictionary = _registry.get_territory(territory_id)
	# 已臣服据点再进：不刷守军（架构 §2.3），以友化空图运行
	if get_territory_state(territory_id) == TerritoryRegistry.State.CAPTURED:
		return {}
	var losses: int = WorldState.territories.get(territory_id, {}).get("garrison_losses", 0) \
			if WorldState.territories.get(territory_id, {}) is Dictionary else 0
	if losses <= 0:
		return row
	var effective := row.duplicate(true)
	var quota: int = _registry.get_garrison_count(territory_id) - losses
	for entry in effective.get("garrison", []):
		if not (entry is Dictionary):
			continue
		var count := int(entry.get("count", 0))
		var kept := mini(count, maxi(quota, 0))
		quota -= kept
		entry["count"] = kept
	return effective


## 领地运行时状态（与 api.get_territory_state 同语义：无记录按 HOSTILE）
func get_territory_state(territory_id: String) -> int:
	var record: Variant = WorldState.territories.get(territory_id, {})
	if not (record is Dictionary):
		return TerritoryRegistry.State.HOSTILE
	return int(record.get("state", TerritoryRegistry.State.HOSTILE))


## 守军出生点：锚点 GarrisonSlots 优先；无锚点按地图右侧半区程序化横排
func _resolve_slots(map: Node2D, anchor: ConquestAnchor) -> Array[Vector2]:
	if anchor != null:
		var from_anchor := anchor.get_garrison_slots()
		if not from_anchor.is_empty():
			return from_anchor
	var slots: Array[Vector2] = []
	var start_x: float = map.map_left + (map.map_right - map.map_left) * FALLBACK_START_RATIO
	var spawn_y: float = map.ground_y + (map.ground_bottom - map.ground_y) * 0.5
	for i in 8:
		slots.append(Vector2(start_x + FALLBACK_SLOT_SPACING * i, spawn_y))
	return slots


## 取第 i 个布阵点（槽位用尽沿最后方向续排）
func _slot_position(map: Node2D, anchor: ConquestAnchor, slots: Array[Vector2], index: int) -> Vector2:
	if index < slots.size():
		return slots[index]
	var step := FALLBACK_SLOT_SPACING
	if slots.size() >= 2:
		step = slots[slots.size() - 1].x - slots[slots.size() - 2].x
	var y := slots[slots.size() - 1].y
	# 越过地图右缘时折返上方一排（防御；当前最大配置 8 守军不会触发）
	var x: float = slots[slots.size() - 1].x + step * (index - slots.size() + 1)
	if x > map.map_right - 100.0:
		x = map.map_right - 100.0
		y = map.ground_y + 60.0
	return Vector2(x, y)


## 刷单个单位：兵种档案（进树前写入）+ 武器按 variant + AI 接管
func _spawn_unit(map: Node2D, pos: Vector2, profile: String) -> Node2D:
	var u: Node2D = map.spawn_entity(_STICKMAN_SCENE, pos, profile)
	if u == null:
		return null
	# 脚部对齐布阵点（先例照 initial_content）
	if u.get("foot_offset") != null:
		u.global_position.y = pos.y - u.foot_offset
	_apply_weapon(u, profile)
	if u.has_method("set_possessed"):
		u.set_possessed(false)
	return u


## 按兵种档案的 variant 装武器（setter call_deferred 重挂，spawn 后设置安全；
## 先例照 siege_director）
func _apply_weapon(u: Node2D, profile: String) -> void:
	if profile.is_empty() or u.get("weapon_mount") == null:
		return
	var variant: Variant = BalanceConfig.get_value("units.stickmen.%s.variant" % profile)
	var wtype: Variant = _VARIANT_WEAPONS.get(String(variant), null)
	if wtype != null:
		u.weapon_mount.weapon_type = wtype
