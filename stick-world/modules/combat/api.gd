extends Node
## 战斗模块公共 API -- 外部只能通过此文件调用战斗系统功能。
##
## 详见 docs/技术/架构/场景与战斗架构.md §8.2。
## P0 阶段委托给 BattleDirector（GameRoot.BattleDirector 节点）。
##
## ⚠️ 契约说明（2026-08 审计收敛）：模块API契约.md §六 文档的"战略级"接口
## （initiate_battle/issue_order/possess_commander 等）尚未实现——当前玩法是
## 实体级战场（地图上单位直接战斗），战略级接口待阶段 1+ 战略图接入后补充。
## 以本文件实际签名为准。

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
