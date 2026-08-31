class_name ActionProgressIndicator
extends Node2D
## 工人/玩家头顶动作进度条 -- 取货/交付/敲击时显示。
##
## 由 StickmanEntity 挂载，行为脚本通过 entity.set_action_progress(ratio) 更新。

var _progress: float = 0.0
const _BAR_WIDTH: float = 40.0
const _BAR_HEIGHT: float = 5.0
const _COLOR_BG := Color(0, 0, 0, 0.6)
const _COLOR_FG := Color(1.0, 0.85, 0.3, 1.0)
const _COLOR_BORDER := Color(0, 0, 0, 0.8)


func _ready() -> void:
	# 绝对顶层（同血条：y 排序后相对 z 会被其他单位盖住）
	z_as_relative = false
	z_index = 1001
	visible = false


func set_progress(ratio: float) -> void:
	_progress = clampf(ratio, 0.0, 1.0)
	visible = _progress > 0.0
	queue_redraw()


func hide_bar() -> void:
	_progress = 0.0
	visible = false


func _draw() -> void:
	if _progress <= 0.0:
		return
	var x: float = -_BAR_WIDTH * 0.5
	draw_rect(Rect2(x, 0, _BAR_WIDTH, _BAR_HEIGHT), _COLOR_BG, true)
	var fg_w: float = _BAR_WIDTH * _progress
	if fg_w > 0.0:
		draw_rect(Rect2(x, 0, fg_w, _BAR_HEIGHT), _COLOR_FG, true)
	draw_rect(Rect2(x, 0, _BAR_WIDTH, _BAR_HEIGHT), _COLOR_BORDER, false, 1.0)
