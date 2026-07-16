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
#   - work（有派工）优先级最高
#   - idle 完成后，随机概率切换到 wander（Reynolds 漫游）
#   - wander 完成后，自动回 idle

# 显式 preload，避免 headless 模式下 class_name 全局注册未触发
const ScriptBehaviorWork := preload("res://modules/units/ai/behavior_work.gd")
const ScriptBehaviorAttack := preload("res://modules/units/ai/behavior_attack.gd")
const ScriptBehaviorSeekCover := preload("res://modules/units/ai/behavior_seek_cover.gd")
const ScriptBehaviorRetreat := preload("res://modules/units/ai/behavior_retreat.gd")

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

	var work := ScriptBehaviorWork.new()
	work.name = "BehaviorWork"
	work.behavior_name = "work"
	work.entity = _entity
	_state_machine.add_child(work)
	_state_machine.register_behavior(work)

	# 战斗行为（§7.2 / §8，阶段 0.5）
	var attack := ScriptBehaviorAttack.new()
	attack.name = "BehaviorAttack"
	attack.behavior_name = "attack"
	attack.entity = _entity
	_state_machine.add_child(attack)
	_state_machine.register_behavior(attack)

	var seek_cover := ScriptBehaviorSeekCover.new()
	seek_cover.name = "BehaviorSeekCover"
	seek_cover.behavior_name = "seek_cover"
	seek_cover.entity = _entity
	_state_machine.add_child(seek_cover)
	_state_machine.register_behavior(seek_cover)

	var retreat := ScriptBehaviorRetreat.new()
	retreat.name = "BehaviorRetreat"
	retreat.behavior_name = "retreat"
	retreat.entity = _entity
	_state_machine.add_child(retreat)
	_state_machine.register_behavior(retreat)

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

## P0 决策：战斗（参战时）> work（有派工）> idle/wander 循环。
## 参战时（entity 有激活的 battle_instance）战斗行为优先级最高。
func _make_decision() -> void:
	# 1. 战斗决策（最高优先级，阶段 0.5）
	if _try_combat():
		return
	if not _state_machine.has_active_behavior():
		# 无激活行为，检查派工
		if _try_work():
			return
		_state_machine.travel("idle")
		return

	var current := _state_machine.get_current_behavior_name()
	if not _state_machine.is_current_finished():
		return  # 当前行为未完成，不切换

	if current == "idle":
		# 闲置完成：优先看是否有派工
		if _try_work():
			return
		# 没有派工，随机决定是否漫游
		if randf() < WANDER_PROBABILITY:
			_state_machine.travel("wander")
		else:
			_state_machine.travel("idle")  # 重新闲置
	elif current == "wander":
		# 漫游完成：先检查派工
		if _try_work():
			return
		_state_machine.travel("idle")
	elif current == "work":
		# work 完成（项目完工或取消）：检查是否还有派工
		if _try_work():
			return
		_state_machine.travel("idle")
	else:
		# 未知行为，回 idle
		_state_machine.travel("idle")


## 尝试战斗决策。当 entity 参战（有激活的 battle_instance）时返回 true 并切换到战斗行为。
## 决策优先级：溃逃/士气极低 -> retreat；重伤且附近有掩体 -> seek_cover；默认 -> attack。
func _try_combat() -> bool:
	if _entity == null or not is_instance_valid(_entity):
		return false
	if not _entity.has_method("get_battle_instance"):
		return false
	var bi: Node = _entity.get_battle_instance()
	if bi == null or not is_instance_valid(bi):
		return false
	if not bi.has_method("is_active") or not bi.is_active():
		return false
	if _entity.has_method("is_dead") and _entity.is_dead():
		return false
	# 战斗行为进行中且未完成 -> 保持
	var current: String = _state_machine.get_current_behavior_name()
	if current in ["attack", "seek_cover", "retreat"]:
		if not _state_machine.is_current_finished():
			return true
	var bi_param: Dictionary = {"battle": bi}
	var health: Node = _entity.get_health() if _entity.has_method("get_health") else null
	# 溃逃或士气极低 -> retreat
	if health != null:
		if health.has_method("is_routed") and health.is_routed():
			_state_machine.travel("retreat", bi_param)
			return true
		if health.has_method("get_morale_ratio") and health.get_morale_ratio() < 0.25:
			_state_machine.travel("retreat", bi_param)
			return true
		# HP 低且附近有掩体 -> seek_cover
		if health.has_method("get_hp_ratio") and health.get_hp_ratio() < 0.4:
			var cover = bi.get_cover() if bi.has_method("get_cover") else null
			if cover != null and cover.has_method("has_covers") and cover.has_covers():
				_state_machine.travel("seek_cover", bi_param)
				return true
	# 默认 -> attack
	_state_machine.travel("attack", bi_param)
	return true


## 尝试进入 work 行为。如果工人被派工到活跃项目，travel("work", {project})。
## 返回 true 表示已切换到 work。
func _try_work() -> bool:
	if _entity == null or not is_instance_valid(_entity):
		return false
	if not _entity.has_method("get_construction_manager"):
		return false
	var manager: Node = _entity.get_construction_manager()
	if manager == null:
		return false
	if not manager.has_method("get_worker_project"):
		return false
	var project: RefCounted = manager.get_worker_project(_entity)
	if project == null:
		# 没有派工，尝试自动派工
		if manager.has_method("try_assign_worker"):
			if manager.try_assign_worker(_entity):
				project = manager.get_worker_project(_entity)
	if project == null:
		return false
	# 检查项目是否还在接受工人（PLANNED 或 UNDER_CONSTRUCTION）
	if not project.is_accepting_workers():
		return false
	_state_machine.travel("work", {"project": project})
	return true


# ─────────────────────────────── 公共 API ────────────────────────────────

## 获取当前行为名。
func get_current_behavior() -> String:
	if _state_machine == null:
		return ""
	return _state_machine.get_current_behavior_name()


## 获取状态机引用（供测试用）。
func get_state_machine() -> BehaviorStateMachine:
	return _state_machine
