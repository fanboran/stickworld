extends Node
## BattleInstance 最小桩（test_combat_control 用）：
## 提供 is_active() / get_nearest_enemy() / get_cover() 供 BehaviorAttack 驱动。

var _units: Array = []
var _enemies: Array = []


func setup(units: Array, enemies: Array) -> void:
	_units = units
	_enemies = enemies


func is_active() -> bool:
	return true


func get_nearest_enemy(unit: Node) -> Node:
	var best: Node = null
	var best_dist: float = INF
	for e in _enemies:
		if e != null and is_instance_valid(e):
			var d: float = unit.global_position.distance_to(e.global_position)
			if d < best_dist:
				best_dist = d
				best = e
	return best


func get_cover() -> Node:
	return null
