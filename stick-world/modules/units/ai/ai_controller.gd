class_name AIController
extends Node
## AI 决策大脑 -- 持有行为状态机，根据三层命令系统决策行为切换。
##
## 详见 docs/技术/架构/场景与战斗架构.md §7.1 / §7.3。
## 职责：
##   1. 持有 BehaviorStateMachine，注册并调度行为
##   2. 每决策周期检查当前状态，决定是否切换行为
##   3. 玩家附身时暂停 AI，取消附身时恢复
##
## P0 阶段实现最简决策：
##   - idle 完成后，随机概率切换到 wander（Reynolds 漫游）
##   - wander 完成后，自动回 idle

# ─────────────────────────────── 常量 ────────────────────────────────
## 决策检查间隔（秒）
const DECISION_INTERVAL: float = 0.3
## idle 后切换到 wander 的概率
const WANDER_PROBABILITY: float = 0.7

# ─────────────────────────────── 运行时 ────────────────────────────────
## 所属实体引用
var _entity: CharacterBody2D = null
## 行为状态机
var _state_machine: BehaviorStateMachine = null
## 决策计时器
var _decision_timer: float = 0.0
## 上一帧是否被附身（用于检测附身状态变化）
var _was_possessed: bool = false


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	_entity = get_parent() as CharacterBody2D
	if _entity == null:
		push_error("[AIController] 父节点非 CharacterBody2D，AI 无法工作")
		return
	_setup_state_machine()


## 创建状态机并注册基础行为
func _setup_state_machine() -> void:
	_state_machine = BehaviorStateMachine.new()
	_state_machine.name = "BehaviorStateMachine"
	add_child(_state_machine)

	var idle := BehaviorIdle.new()
	idle.name = "BehaviorIdle"
	idle.behavior_name = "idle"
	idle.entity = _entity
	_state_machine.add_child(idle)
	_state_machine.register_behavior(idle)

	var wander := BehaviorWander.new()
	wander.name = "BehaviorWander"
	wander.behavior_name = "wander"
	wander.entity = _entity
	_state_machine.add_child(wander)
	_state_machine.register_behavior(wander)

	# 初始行为：闲置
	_state_machine.travel("idle")


# ─────────────────────────────── 每物理帧（由 StickmanEntity 调用）────────────────────────────────

## 由 StickmanEntity._physics_process 在处理 AI 输入前调用。
## 负责状态机调度 + 决策，设置 entity 的 AI 移动方向。
func physics_update(delta: float) -> void:
	if _entity == null or not is_instance_valid(_entity):
		return
	if _state_machine == null:
		return

	# 附身检测
	var possessed: bool = _entity.is_possessed()
	if possessed:
		if not _was_possessed:
			_was_possessed = true
		return  # 附身时暂停 AI

	if _was_possessed:
		# 刚取消附身，恢复 AI 从 idle 开始
		_was_possessed = false
		_state_machine.travel("idle")

	# 状态机调度
	_state_machine.physics_update(delta)

	# 决策
	_decision_timer += delta
	if _decision_timer >= DECISION_INTERVAL:
		_decision_timer = 0.0
		_make_decision()


# ─────────────────────────────── 决策逻辑 ────────────────────────────────

## P0 简单决策：idle -> wander -> idle 循环。
func _make_decision() -> void:
	if not _state_machine.has_active_behavior():
		_state_machine.travel("idle")
		return

	var current := _state_machine.get_current_behavior_name()
	if not _state_machine.is_current_finished():
		return  # 当前行为未完成，不切换

	if current == "idle":
		# 闲置完成，随机决定是否漫游
		if randf() < WANDER_PROBABILITY:
			_state_machine.travel("wander")
		else:
			_state_machine.travel("idle")  # 重新闲置
	elif current == "wander":
		# 漫游完成，回 idle
		_state_machine.travel("idle")
	else:
		# 未知行为，回 idle
		_state_machine.travel("idle")


# ─────────────────────────────── 公共 API ────────────────────────────────

## 获取当前行为名。
func get_current_behavior() -> String:
	if _state_machine == null:
		return ""
	return _state_machine.get_current_behavior_name()


## 获取状态机引用（供测试用）。
func get_state_machine() -> BehaviorStateMachine:
	return _state_machine
