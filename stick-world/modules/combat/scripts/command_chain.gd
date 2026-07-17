class_name CommandChain
extends Node
## 指挥链 -- 逐层下达号令，模拟传令延迟。
##
## 详见 docs/技术/架构/场景与战斗架构.md §8.5。
## 延迟公式：delay = base_delay × tier_diff × commander_efficiency_modifier
##   - base_delay = 2s，每跨一层 +2s
##   - 玩家附身指挥官（source_tier=0）时 delay=0（直接指挥）
##   - 指挥官能力高 -> 延迟减半（P0 暂不实现）
##
## P0 阶段只有 L1 小队，source_tier=0（玩家）时无延迟。

# ─────────────────────────────── 常量 ────────────────────────────────
## 基础延迟（秒），每跨一层增加此时长
const BASE_DELAY: float = 2.0

# ─────────────────────────────── 信号 ────────────────────────────────
## 号令已送达单位（延迟结束后发射）
signal order_delivered(order_type: int, squad_id: String, unit_ids: Array)


# ─────────────────────────────── 核心 API ────────────────────────────────

## 下达号令到指定单位列表。
## order_type: TacticalOrders.OrderType
## squad_id: 目标小队 ID
## units: StickmanEntity 节点数组
## behavior_name: 要设置的行为名（如 "move", "idle", "retreat"）
## params: 行为参数（如 {"target": Vector2}）
## source_tier: 发令者层级（0=玩家直接指挥，>0=AI 指挥官层级）
## squad_tier: 接收小队层级（默认 1=L1 排级）
func deliver(order_type: int, squad_id: String, units: Array, behavior_name: String, params: Dictionary, source_tier: int = 0, squad_tier: int = 1) -> void:
	var delay: float = _calculate_delay(source_tier, squad_tier)
	if delay <= 0.0:
		_execute_delivery(order_type, squad_id, units, behavior_name, params)
	else:
		await get_tree().create_timer(delay).timeout
		_execute_delivery(order_type, squad_id, units, behavior_name, params)


# ─────────────────────────────── 内部 ────────────────────────────────

## 计算指挥链延迟
func _calculate_delay(source_tier: int, squad_tier: int) -> float:
	# 玩家直接指挥 -> 无延迟
	if source_tier == 0:
		return 0.0
	# tier_diff = 接收层级 - 发令层级
	var tier_diff: int = maxi(0, squad_tier - source_tier)
	if tier_diff == 0:
		return 0.0
	return BASE_DELAY * tier_diff


## 实际执行号令送达：设置每个单位的 AIController 命令
func _execute_delivery(order_type: int, squad_id: String, units: Array, behavior_name: String, params: Dictionary) -> void:
	var unit_ids: Array = []
	for u in units:
		if not is_instance_valid(u):
			continue
		if u.has_method("is_dead") and u.is_dead():
			continue
		var ai: Node = u.get_ai_controller() if u.has_method("get_ai_controller") else null
		if ai != null and ai.has_method("set_order"):
			ai.set_order(behavior_name, params)
		unit_ids.append(u.get_instance_id())
	order_delivered.emit(order_type, squad_id, unit_ids)
