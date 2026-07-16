class_name BehaviorBase
extends Node
## AI 行为基类 -- 所有行为状态的最小单元。
##
## 详见 docs/技术/架构/场景与战斗架构.md §7.2。
## 每个行为定义 enter / update / exit 三个回调，由 BehaviorStateMachine 调度。
## 行为本身不决策"下一步做什么"，只负责执行当前逻辑，
## 完成后调用 finish() 通知状态机，由 AIController 决策切换。

# ─────────────────────────────── 运行时 ────────────────────────────────
## 行为名称（唯一标识，用于状态机 travel，子类 _ready 中赋值）
var behavior_name: String = ""
## 所属实体引用（由 AIController 注入）
var entity: CharacterBody2D = null
## 是否已完成（到达目标 / 闲置时间到），由 finish() 设置
var _finished: bool = false
## 是否已激活（enter 后 true，exit 后 false）
var _active: bool = false


# ─────────────────────────────── 生命周期回调 ────────────────────────────────

## 进入此行为时调用。previous 为上一个行为名（可能为空），params 为 travel 传入的参数。
func enter(_previous: String, _params: Dictionary) -> void:
	_finished = false
	_active = true


## 每物理帧更新（由 BehaviorStateMachine.physics_update 转发）。
func update(_delta: float) -> void:
	pass


## 退出此行为时调用。next 为下一个行为名。
func exit(_next: String) -> void:
	_active = false


# ─────────────────────────────── 公共方法 ────────────────────────────────

## 标记此行为已完成，通知 AIController 决策下一步。
func finish() -> void:
	_finished = true


## 此行为是否已完成。
func is_finished() -> bool:
	return _finished


## 此行为是否处于激活状态。
func is_active() -> bool:
	return _active
