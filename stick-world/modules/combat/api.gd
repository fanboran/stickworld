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

## FormationSystem 实例引用（由 GameRoot 装配时注入，用于跨图编队快照）
var _formation: Node = null


## 注入 BattleDirector 引用（由 GameRoot._setup_combat_system 调用）
func setup(director: Node) -> void:
	_director = director


## 注入 FormationSystem 引用（跨图编队快照/恢复用）
func setup_formation_system(formation: Node) -> void:
	_formation = formation


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


# ─────────────────────────────── 编队跨图快照 ────────────────────────────────

## 导出全部编队快照（跨图前调用，含 preset/职责/排长）。
func export_squads() -> Array:
	if _formation == null:
		return []
	if _formation.has_method("export_squads"):
		return _formation.export_squads()
	return []


## 解散全部编队（旧图实体即将销毁前调用，防 freed 引用残留）。
func disband_all_squads() -> void:
	if _formation != null and _formation.has_method("disband_all_squads"):
		_formation.disband_all_squads()


## 在新地图重建编队（快照 + 新旧实体映射）。
func restore_squads(snapshots: Array, entity_map: Dictionary) -> void:
	if _formation != null and _formation.has_method("restore_squads"):
		_formation.restore_squads(snapshots, entity_map)
