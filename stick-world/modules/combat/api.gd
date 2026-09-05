extends Node
## 战斗模块公共 API -- 外部只能通过此文件调用战斗系统功能。
##
## 详见 docs/技术/架构/场景与战斗架构.md §8.2。
## P0 阶段委托给 BattleDirector（GameRoot.BattleDirector 节点）。
##
## ⚠️ 契约说明（2026-08-22 修正）：模块API契约.md §六 的"战略级"接口拆解如下——
##   - initiate_battle：由 start_battle（实体级）承接，战略图触发属阶段 1+ 设计空间；
##   - issue_order：已实现（委托 TacticalOrders，经 CommandChain 逐层下达）；
##   - possess_commander：本属 player_control 职责（PossessionInterface），不在本模块。
## 以本文件实际签名为准。
##
## 公共类型契约：TargetFinder（公共目标选择核心，反编译参考实装 A）为对外公共类，
## units 的战斗 AI（behavior_attack.gd）经其静态方法 find_target() 选目标。
## 该引用属 headless 防御性路径 preload（行内 audit-exempt 标记），见审计工具豁免清单。
##
## 编队职责查询契约：FormationSystem 为 combat 内部类，units 侧禁止 class_name/preload
## 引用——实例经 world 装配器注入 StickmanEntity.set_formation_system(fs: Node)（弱类型
## Node），units 侧（ai_controller.gd）只依赖 duck 协议（has_method 门禁，未注入时放行）：
##   - is_work_allowed(unit: Node, work_type: String) -> bool（未注入/未编队视为允许）
##   - is_unit_squad_following(unit: Node) -> bool（未注入视为不跟随）
## 工作类型字符串对齐 FormationSystem.WorkType（units/ai_controller.gd 持本地常量副本
## WORK_COMBAT/WORK_BUILD/WORK_HAUL/WORK_TRANSPORT/WORK_FORAGE，避免跨模块依赖；
## WORK_HAUL 为全员基础能力，is_work_allowed 恒放行。

# ─────────────────────────────── 运行时 ────────────────────────────────
## BattleDirector 实例引用（由 GameRoot 装配时注入）
var _director: Node = null

## FormationSystem 实例引用（由 GameRoot 装配时注入，用于跨图编队快照）
var _formation: Node = null

## TacticalOrders 实例引用（由 GameRoot 装配时注入，issue_order 委托目标）
var _tactical_orders: Node = null


## 注入 BattleDirector 引用（由 GameRoot._setup_combat_system 调用）
func setup(director: Node) -> void:
	_director = director


## 注入 FormationSystem 引用（跨图编队快照/恢复用）
func setup_formation_system(formation: Node) -> void:
	_formation = formation


## 注入 TacticalOrders 引用（由 SystemSetup 装配，issue_order 用）
func set_tactical_orders(tactical: Node) -> void:
	_tactical_orders = tactical


# ─────────────────────────────── 创建战斗 ────────────────────────────────

## 在指定地图上启动一场战斗。
## attacker_units / defender_units: StickmanEntity 数组
## 返回 BattleInstance（失败返回 null）
func start_battle(map: Node2D, attacker_units: Array, defender_units: Array) -> Node:
	if _director == null:
		push_warning("[CombatApi] BattleDirector 未注入")
		return null
	return _director.start_battle_at(map, attacker_units, defender_units)


# ─────────────────────────────── 号令下达 ────────────────────────────────

## 对指定小队下达战术号令（委托 TacticalOrders，经 CommandChain 逐层延迟下达）。
## order_type 见 TacticalOrders.OrderType；source_tier 0=玩家直接指挥。
## 返回是否受理（小队不存在/无战斗职责时拒绝）。
func issue_order(order_type: int, squad_id: String, target_pos: Vector2 = Vector2.ZERO,
		source_tier: int = 0) -> bool:
	if _tactical_orders == null:
		push_warning("[CombatApi] TacticalOrders 未注入")
		return false
	return _tactical_orders.issue(order_type, squad_id, target_pos, source_tier)


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
