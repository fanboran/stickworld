class_name TacticalOrders
extends Node
## 战术号令系统 -- 预设号令的下达入口。
##
## 详见 docs/技术/架构/场景与战斗架构.md §8.3、§8.4。
## 流程：
##   tactical_orders.issue(ORDER_ADVANCE_ALL, squad_id, target_pos)
##   -> command_chain.deliver(...) 逐层下达（带延迟）
##   -> 各单位 AIController.set_order(behavior, params)
##   -> AI 覆盖自主决策执行号令
##
## P0 范围号令（§8.4）：
##   ADVANCE_ALL  - 全体向目标点前进（behavior: move）
##   SPRINT       - 加速冲刺（behavior: move, run=true）
##   HOLD_POSITION - 原地坚守（behavior: idle，清除移动命令）
##   RETREAT      - 有序后撤（behavior: retreat）
##   TAKE_COVER   - 就近找掩体（behavior: seek_cover）
##   RALLY        - 集结溃兵（behavior: move 到集结点）

# ─────────────────────────────── 号令类型 ────────────────────────────────
enum OrderType {
	ADVANCE_ALL,     ## 全体向目标点前进
	SPRINT,          ## 消耗体力加速冲刺
	HOLD_POSITION,   ## 原地坚守
	RETREAT,         ## 有序后撤
	TAKE_COVER,      ## 就近找掩体
	RALLY,           ## 集结溃兵
}

# ─────────────────────────────── 信号 ────────────────────────────────
## 号令已下达（送达前即发射，含延迟信息）
signal order_issued(order_type: int, target_squad_id: String, issuer_unit_id: int)

# ─────────────────────────────── 状态 ────────────────────────────────
## FormationSystem 引用（查询小队成员）
var _formation_system: Node = null
## CommandChain 引用（延迟下达）
var _command_chain: Node = null


# ─────────────────────────────── 装配 ────────────────────────────────

func setup(formation_system: Node, command_chain: Node) -> void:
	_formation_system = formation_system
	_command_chain = command_chain


# ─────────────────────────────── 核心 API ────────────────────────────────

## 对指定小队下达号令。
## order_type: OrderType 枚举值
## squad_id: 目标小队 ID
## target_pos: 目标位置（世界坐标，ADVANCE/RALLY 用）
## source_tier: 发令者层级（0=玩家直接指挥，延迟为 0）
## 返回是否成功下达（小队存在且有有效单位）。
func issue(order_type: int, squad_id: String, target_pos: Vector2 = Vector2.ZERO, source_tier: int = 0) -> bool:
	if _formation_system == null or _command_chain == null:
		push_warning("[TacticalOrders] 未注入 formation_system 或 command_chain")
		return false
	var units: Array = _formation_system.get_squad_units(squad_id)
	if units.is_empty():
		push_warning("[TacticalOrders] 小队 %s 无有效单位" % squad_id)
		return false
	var behavior_name: String = _order_to_behavior(order_type)
	var params: Dictionary = _order_to_params(order_type, target_pos)
	# 通过指挥链下达（P0 source_tier=0 时无延迟）
	_command_chain.deliver(order_type, squad_id, units, behavior_name, params, source_tier, 1)
	# 发射信号
	order_issued.emit(order_type, squad_id, source_tier)
	if EventBus != null and EventBus.has_signal("order_issued"):
		EventBus.order_issued.emit(order_type, squad_id, source_tier)
	return true


## 对所有小队下达号令。返回成功下达的小队数。
func issue_to_all(order_type: int, target_pos: Vector2 = Vector2.ZERO) -> int:
	if _formation_system == null:
		return 0
	var count: int = 0
	for squad_id in _formation_system.get_all_squads():
		if issue(order_type, squad_id, target_pos):
			count += 1
	return count


# ─────────────────────────────── 查询 ────────────────────────────────

## 获取号令名称（供 UI/调试用）
func get_order_name(order_type: int) -> String:
	match order_type:
		OrderType.ADVANCE_ALL: return "ADVANCE_ALL"
		OrderType.SPRINT: return "SPRINT"
		OrderType.HOLD_POSITION: return "HOLD_POSITION"
		OrderType.RETREAT: return "RETREAT"
		OrderType.TAKE_COVER: return "TAKE_COVER"
		OrderType.RALLY: return "RALLY"
		_: return "UNKNOWN"


# ─────────────────────────────── 内部映射 ────────────────────────────────

## 号令类型 -> AIController 行为名
func _order_to_behavior(order_type: int) -> String:
	match order_type:
		OrderType.ADVANCE_ALL, OrderType.RALLY:
			return "move"
		OrderType.SPRINT:
			return "move"
		OrderType.HOLD_POSITION:
			return "idle"
		OrderType.RETREAT:
			return "retreat"
		OrderType.TAKE_COVER:
			return "seek_cover"
		_:
			return "idle"


## 号令类型 -> 行为参数
func _order_to_params(order_type: int, target_pos: Vector2) -> Dictionary:
	match order_type:
		OrderType.ADVANCE_ALL, OrderType.RALLY:
			return {"target": target_pos}
		OrderType.SPRINT:
			return {"target": target_pos, "run": true}
		OrderType.HOLD_POSITION:
			return {}
		OrderType.RETREAT:
			return {}  # battle_instance 由 behavior 自动从 entity 获取
		OrderType.TAKE_COVER:
			return {}
		_:
			return {}
