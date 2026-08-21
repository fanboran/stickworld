extends Control
## 世界加载覆盖 —— 游戏根启动后、世界就绪前的全屏黑 + 加载环 + 阶段文字。
##
## 用途：消除"切到 game_root 后同步加载世界导致的死灰屏"——加载期有明确指示，
## 世界就绪（玩家生成 + 相机跟随）后淡出。
## 挂 UIRoot 高 z（模态 z=50 之上、F3 调试 z=100 之下）。

const _SpinnerScript: GDScript = preload("res://modules/ui_global/scripts/menus/loading_spinner.gd")

var _label: Label = null
var _shown: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.01, 0.012, 0.016, 1.0)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var center := VBoxContainer.new()
	center.set_anchors_preset(Control.PRESET_CENTER)
	center.grow_horizontal = Control.GROW_DIRECTION_BOTH
	center.grow_vertical = Control.GROW_DIRECTION_BOTH
	center.add_theme_constant_override("separation", 18)
	add_child(center)
	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", StickTokens.FONT_TITLE)
	center.add_child(_label)
	var spinner := Control.new()
	spinner.set_script(_SpinnerScript)
	spinner.custom_minimum_size = Vector2(56, 56)
	spinner.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	center.add_child(spinner)
	visible = false


## 显示加载覆盖（阶段文字，如"正在生成世界…"）
func show_loading(message: String) -> void:
	_label.text = message
	visible = true
	modulate.a = 1.0
	_shown = true


## 世界就绪后淡出（幂等）
func hide_loading() -> void:
	if not _shown:
		return
	_shown = false
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, 0.35)
	tween.tween_callback(func():
		visible = false
		modulate.a = 1.0
	)
