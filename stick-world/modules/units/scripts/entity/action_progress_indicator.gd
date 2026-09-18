class_name ActionProgressIndicator
extends ProgressPainter
## 工人/玩家头顶动作进度条 -- 取货/交付/敲击时显示。
##
## 由 StickmanEntity 挂载，行为脚本通过 entity.set_action_progress(ratio) 更新。
## 绘制走 L0 公共基类 ProgressPainter（bg/fg 双 rect + 描边），外观不变。

const _BAR_WIDTH: float = 40.0
const _BAR_HEIGHT: float = 5.0
const _COLOR_FG := Color(1.0, 0.85, 0.3, 1.0)


func _ready() -> void:
	# 绝对顶层（同血条：y 排序后相对 z 会被其他单位盖住）
	z_as_relative = false
	z_index = 1001
	visible = false


func set_progress(ratio: float) -> void:
	set_progress_value(ratio)
	visible = progress > 0.0


func hide_bar() -> void:
	set_progress_value(0.0)
	visible = false


func _draw() -> void:
	if progress <= 0.0:
		return
	draw_bar(-_BAR_WIDTH * 0.5, 0, _BAR_WIDTH, _BAR_HEIGHT, progress, _COLOR_FG)
