extends Control
## 世界加载覆盖 —— 游戏根启动后、世界就绪前的全屏黑 + 加载环 + 阶段文字 + 进度条。
##
## 用途：消除"切到 game_root 后同步加载世界导致的死灰屏"——加载期有明确指示，
## 世界就绪（玩家生成 + 相机跟随）后淡出。
## 进度条由 game_root 分段装配驱动（Minecraft 式模块计数），每段先更新再让出
## 一帧渲染后干活——进度是真实推进，不是假动画。
## 挂 UIRoot 高 z（模态 z=50 之上、F3 调试 z=100 之下）。

const _SpinnerScript: GDScript = preload("res://modules/ui_global/scripts/menus/loading_spinner.gd")
const BAR_WIDTH: float = 260.0

var _label: Label = null
var _bar_track: Control = null
var _bar_fill: ColorRect = null
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
	# 进度条（分段装配驱动；ratio < 0 时隐藏——纯文案阶段不假装有进度）
	_bar_track = Control.new()
	_bar_track.custom_minimum_size = Vector2(BAR_WIDTH, 6)
	_bar_track.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_bar_track.clip_contents = true
	_bar_track.visible = false
	center.add_child(_bar_track)
	var track_bg := ColorRect.new()
	track_bg.color = Color(1, 1, 1, 0.12)
	track_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bar_track.add_child(track_bg)
	_bar_fill = ColorRect.new()
	_bar_fill.color = StickTokens.ACCENT
	_bar_fill.position = Vector2.ZERO
	_bar_fill.size = Vector2(0, 6)
	_bar_track.add_child(_bar_fill)
	visible = false


## 显示加载覆盖（阶段文字，如"正在生成世界…"；ratio 0~1 同时亮进度条，<0 隐藏）
func show_loading(message: String, ratio: float = -1.0) -> void:
	_label.text = message
	set_progress(ratio)
	visible = true
	modulate.a = 1.0
	_shown = true


## 更新进度条（钳 0~1；<0 隐藏进度条只留文字）
func set_progress(ratio: float) -> void:
	if ratio < 0.0:
		_bar_track.visible = false
		return
	_bar_track.visible = true
	_bar_fill.size.x = BAR_WIDTH * clampf(ratio, 0.0, 1.0)


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
