class_name BehaviorIdle
extends "res://modules/units/ai/behavior_base.gd"
## 闲置行为 -- 站立不动，持续一段时间后完成。
##
## 详见 docs/技术/架构/场景与战斗架构.md §7.2。
## enter 时停止移动并播放 idle 动画，到时间后 finish()。
## params 可选字段：
##   - duration: float  闲置时长（秒），不传则随机 2~5 秒

## 默认最短闲置时间（秒）
const MIN_DURATION: float = 2.0
## 默认最长闲置时间（秒）
const MAX_DURATION: float = 5.0

## 已闲置时间
var _timer: float = 0.0
## 本次闲置时长
var _duration: float = 3.0


func _ready() -> void:
	behavior_name = "idle"


func enter(previous: String, params: Dictionary) -> void:
	super.enter(previous, params)
	_timer = 0.0
	if params.has("duration"):
		_duration = params["duration"]
	else:
		_duration = randf_range(MIN_DURATION, MAX_DURATION)
	# 停止移动
	if entity != null and entity.has_method("ai_stop"):
		entity.ai_stop()


func update(delta: float) -> void:
	_timer += delta
	if _timer >= _duration:
		finish()
