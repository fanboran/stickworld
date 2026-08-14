class_name BattleDirector
extends Node
## 多战场调度 -- 挂到 GameRoot.BattleDirector，管理多个 BattleInstance。
##
## 详见 docs/技术/架构/场景与战斗架构.md §2.2（BattleDirector）、§8.1。
## 职责：在指定地图上启动/结束战斗实例，查询活跃战斗。
## P0 阶段只支持单战场，但保留多战场接口供后续扩展。

const ScriptBattleInstance := preload("res://modules/combat/scripts/battle/battle_instance.gd")

# ─────────────────────────────── 运行时 ────────────────────────────────
## 活跃的 BattleInstance 列表
var _battles: Array = []


## 每帧裁剪已释放的战斗实例（BattleInstance 结束时会 queue_free）。
## 修复：此前 _battles 只 append 永不清理，结束战斗残留为失效引用。
func _process(_delta: float) -> void:
	if _battles.is_empty():
		return
	var alive: Array = []
	for b in _battles:
		if is_instance_valid(b):
			alive.append(b)
	_battles = alive


## 在指定地图上启动一场战斗。
## attacker_units / defender_units: StickmanEntity 数组
## 返回创建的 BattleInstance（失败返回 null）
func start_battle_at(map: Node2D, attacker_units: Array, defender_units: Array) -> Node:
	if map == null:
		push_error("[BattleDirector] map 为空，无法启动战斗")
		return null
	var anchor: Node2D = map.get_node_or_null(WorldAPI.PATH_MAP_BATTLE_ANCHOR)
	if anchor == null:
		push_error("[BattleDirector] 地图缺少 BattleAnchor 节点")
		return null
	var bi: Node = ScriptBattleInstance.new()
	bi.name = "BattleInstance"
	bi.setup(map)
	for u in attacker_units:
		bi.add_unit(u, ScriptBattleInstance.FACTION_ATTACKER)
	for u in defender_units:
		bi.add_unit(u, ScriptBattleInstance.FACTION_DEFENDER)
	anchor.add_child(bi)
	bi.start()
	_battles.append(bi)
	return bi


## 是否有进行中的战斗
func has_active_battle() -> bool:
	for b in _battles:
		if is_instance_valid(b) and b.has_method("is_active") and b.is_active():
			return true
	return false


## 获取所有进行中的战斗
func get_active_battles() -> Array:
	var result: Array = []
	for b in _battles:
		if is_instance_valid(b) and b.has_method("is_active") and b.is_active():
			result.append(b)
	return result


## 获取所有战斗（含已结束）
func get_all_battles() -> Array:
	return _battles


# ─────────────────────────────── 攻城战（阶段 F §5.7.6）──────────────────────────────────

## 在城镇地图上启动攻城战（不切换场景，城镇地图即战场）。
## attacker_units: 攻城方单位, defender_units: 守城方单位
## siege_side: 0=从左侧攻城, 1=从右侧攻城
## 返回创建的 BattleInstance（失败返回 null）
func start_siege_battle(map: Node2D, attacker_units: Array, defender_units: Array, siege_side: int = 1) -> Node:
	if map == null:
		push_error("[BattleDirector] map 为空，无法启动攻城战")
		return null
	# 查找城墙，确定攻城方 spawn 位置
	var wall_x: float = _find_outermost_wall_x(map, siege_side)
	var spawn_x: float = wall_x + 200.0 if siege_side == 1 else wall_x - 200.0
	# 设置攻城方单位位置
	var ground_y: float = map.ground_y if "ground_y" in map else 810.0
	var ground_bottom: float = map.ground_bottom if "ground_bottom" in map else 1080.0
	var mid_y: float = (ground_y + ground_bottom) * 0.5
	for i in range(attacker_units.size()):
		var u: Node2D = attacker_units[i]
		if is_instance_valid(u):
			u.global_position = Vector2(spawn_x, mid_y + (i % 5) * 30 - 60)
	# 复用 start_battle_at 在城镇地图上启动战斗
	return start_battle_at(map, attacker_units, defender_units)


## 查找最外层城墙的 X 坐标（攻城方从该侧接近）
func _find_outermost_wall_x(map: Node2D, siege_side: int) -> float:
	var building_host: Node2D = map.get_node_or_null(WorldAPI.PATH_MAP_BUILDING_HOST)
	var map_left: float = map.map_left if "map_left" in map else 0.0
	var map_right: float = map.map_right if "map_right" in map else 8192.0
	if building_host == null:
		return map_right if siege_side == 1 else map_left
	var wall_x: float = map_right if siege_side == 1 else map_left
	for building in building_host.get_children():
		if building.has_method("is_wall") and building.is_wall():
			var bx: float = building.global_position.x
			if siege_side == 1:
				wall_x = max(wall_x, bx)
			else:
				wall_x = min(wall_x, bx)
	return wall_x


# ─────────────────────────────── 战场持续性（阶段 F §5.7.8）──────────────────────────────────

## 标记玩家离开战场，AI 接管。
## P0 简化：仅标记 + BattleInstance 继续 tick。完整 AI 指挥在 P1+ 实现。
func mark_player_absent(battle: Node) -> void:
	if battle != null and battle.has_method("set_player_present"):
		battle.set_player_present(false)


## 标记玩家返回战场
func mark_player_present(battle: Node) -> void:
	if battle != null and battle.has_method("set_player_present"):
		battle.set_player_present(true)
