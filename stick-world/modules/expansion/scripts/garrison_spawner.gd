class_name GarrisonSpawner
extends RefCounted
## 驻军生成管道 —— 按 ConquestAnchor 布阵 + 外部传入编成刷守军。
##
## 职责边界：只刷军不开战（接敌开战编排归调用方）。刷单位照 initial_content
## 先例走 UnitsApi 场景常量 + MapBase.spawn_entity（兵种档案经 spawn 的 def_id
## 参数在进树前写入，实体 _ready 拉数值）。编成数据源 = 调用方给的 row
## （{garrison: [{profile, count, tier}], commander: {profile}}）。

## 守军单位来源标记（调试/测试识别；战斗侧不读）
const META_GARRISON_UNIT := "garrison_unit"
## 敌将来源标记（战损统计/筛选排除敌将用——敌将属指挥层不计入伍额）
const META_GARRISON_COMMANDER := "garrison_commander"
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

## 无锚点警告每图只发一次（fallback 属可玩降级，不刷屏）
var _warned_maps: Dictionary = {}


## 按编成刷守军（含敌将），返回全部守军实体数组（供调用方开战传
## defenders；空数组 = 编成缺失/无可刷条目）。
## row 字段：{garrison: [{profile: String, count: int, tier: String}],
## commander: {profile: String}}（tier 为 tactics.tres 战术 id 透传）
func spawn_garrison(map: Node2D, row: Dictionary) -> Array:
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
	# 敌将（无锚点时布在守军阵末位之后）
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
			c.set_meta(META_GARRISON_COMMANDER, true)
			spawned.append(c)
	return spawned


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


## 按兵种档案的 variant 装武器（setter call_deferred 重挂，spawn 后设置安全）
func _apply_weapon(u: Node2D, profile: String) -> void:
	if profile.is_empty() or u.get("weapon_mount") == null:
		return
	var variant: Variant = BalanceConfig.get_value("units.stickmen.%s.variant" % profile)
	var wtype: Variant = _VARIANT_WEAPONS.get(String(variant), null)
	if wtype != null:
		u.weapon_mount.weapon_type = wtype
