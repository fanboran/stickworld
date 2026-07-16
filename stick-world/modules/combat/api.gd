extends Node
## 战斗模块公共 API -- 外部只能通过此文件调用战斗系统功能。
##
## 详见 docs/技术/架构/场景与战斗架构.md §8.2。
## P0 阶段委托给 BattleDirector（GameRoot.BattleDirector 节点）。

# ─────────────────────────────── 运行时 ────────────────────────────────
## BattleDirector 实例引用（由 GameRoot 装配时注入）
var _director: Node = null


## 注入 BattleDirector 引用（由 GameRoot._setup_combat_system 调用）
func setup(director: Node) -> void:
	_director = director


# ─────────────────────────────── 创建战斗 ────────────────────────────────

## 在指定地图上启动一场战斗。
## attacker_units / defender_units: StickmanEntity 数组
## 返回 BattleInstance（失败返回 null）
func start_battle(map: Node2D, attacker_units: Array, defender_units: Array) -> Node:
	if _director == null:
		push_warning("[CombatApi] BattleDirector 未注入")
		return null
	return _director.start_battle_at(map, attacker_units, defender_units)


# ─────────────────────────────── 查询 ────────────────────────────────

func has_active_battle() -> bool:
	if _director == null:
		return false
	return _director.has_active_battle()


func get_active_battles() -> Array:
	if _director == null:
		return []
	return _director.get_active_battles()
