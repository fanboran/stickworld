class_name BehaviorMove
extends "res://modules/units/ai/behavior_base.gd"
## 移动行为 -- 向目标点直线移动，到达后完成。
##
## 详见 docs/技术/架构/场景与战斗架构.md §7.2。
## P0 阶段为简单直线移动，不做 A* 寻路（障碍由 entity 的通行障碍检测处理）。
## params 必填字段：
##   - target: Vector2  目标位置（世界坐标）
## 可选字段：
##   - run: bool  是否奔跑（默认 false）

## 到达目标的距离阈值（像素）
const ARRIVAL_THRESHOLD: float = 20.0

## 目标位置（世界坐标）
var _target: Vector2 = Vector2.ZERO
## 是否奔跑
var _running: bool = false


func _ready() -> void:
	behavior_name = "move"


func enter(previous: String, params: Dictionary) -> void:
	super.enter(previous, params)
	if params.has("target"):
		_target = params["target"]
	else:
		_target = entity.global_position if entity != null else Vector2.ZERO
	_running = params.get("run", false)


func update(delta: float) -> void:
	if entity == null or not is_instance_valid(entity):
		finish()
		return

	var pos: Vector2 = entity.global_position
	var dist: float = pos.distance_to(_target)

	# 到达目标
	if dist <= ARRIVAL_THRESHOLD:
		finish()
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		return

	# 计算移动方向并驱动 entity
	var dir: Vector2 = (_target - pos).normalized()
	if entity.has_method("ai_move"):
		entity.ai_move(dir, _running)
