class_name BattleDirector
extends Node
## 多战场调度 -- 挂到 GameRoot.BattleDirector，管理多个 BattleInstance。
##
## 详见 docs/技术/架构/场景与战斗架构.md §2.2（BattleDirector）、§8.1。
## 职责：在指定地图上启动/结束战斗实例，查询活跃战斗。
## P0 阶段只支持单战场，但保留多战场接口供后续扩展。

const ScriptBattleInstance := preload("res://modules/combat/scripts/battle_instance.gd")

# ─────────────────────────────── 运行时 ────────────────────────────────
## 活跃的 BattleInstance 列表
var _battles: Array = []


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
