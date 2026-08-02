class_name BehaviorStateMachine
extends Node
## 行为状态机 -- 管理行为注册、切换、每帧调度。
##
## 详见 docs/技术/架构/场景与战斗架构.md §7.2。
## 持有所有已注册行为的引用，通过 travel(name, params) 切换当前行为。
## AIController 负责决策，状态机只负责执行。

## 当前激活的行为名（空字符串表示无行为）
var _current_name: String = ""
## 当前激活的行为引用
var _current_behavior: BehaviorBase = null
## 已注册行为字典 { behavior_name: BehaviorBase }
var _behaviors: Dictionary = {}


# ─────────────────────────────── 注册 ────────────────────────────────

## 注册一个行为节点。行为必须已设置 behavior_name。
func register_behavior(behavior: BehaviorBase) -> void:
	if behavior == null or behavior.behavior_name.is_empty():
		push_error("[BehaviorStateMachine] 注册失败：行为为空或未设 behavior_name")
		return
	_behaviors[behavior.behavior_name] = behavior


# ─────────────────────────────── 切换 ────────────────────────────────

## 切换到指定行为。previous 由内部自动填充，params 传给 enter()。
func travel(behavior_name: String, params: Dictionary = {}) -> void:
	if not _behaviors.has(behavior_name):
		push_warning("[BehaviorStateMachine] 未注册行为: %s" % behavior_name)
		return

	var previous := _current_name
	# 退出旧行为
	if _current_behavior != null and _current_behavior.is_active():
		_current_behavior.exit(behavior_name)

	# 进入新行为
	_current_name = behavior_name
	_current_behavior = _behaviors[behavior_name] as BehaviorBase
	_current_behavior.enter(previous, params)


# ─────────────────────────────── 每帧调度 ────────────────────────────────

## 每物理帧调用，转发给当前行为的 update()。
func physics_update(delta: float) -> void:
	if _current_behavior != null and _current_behavior.is_active():
		_current_behavior.update(delta)


# ─────────────────────────────── 查询 ────────────────────────────────

## 获取当前行为名。
func get_current_behavior_name() -> String:
	return _current_name


## 当前行为是否已完成。
func is_current_finished() -> bool:
	if _current_behavior == null:
		return true
	return _current_behavior.is_finished()


## 是否有激活的行为。
func has_active_behavior() -> bool:
	return _current_behavior != null and _current_behavior.is_active()
