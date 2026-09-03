class_name FpsCounter
extends Label
## FPS 计数器 —— 右上角时钟下方的小标签（设置面板「显示 FPS」开关驱动）。
##
## 由 UIRoot 挂载管理可见性；每 0.5s 刷新一次，避免每帧写文本。

var _timer: float = 0.0


func _ready() -> void:
	set_anchors_preset(Control.PRESET_TOP_RIGHT)
	offset_left = -80.0
	offset_top = 84.0
	offset_right = -12.0
	offset_bottom = 104.0
	horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_theme_font_size_override("font_size", StickTokens.FONT_HINT)
	modulate = StickTokens.TEXT_DIM
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	text = "FPS: --"


func _process(delta: float) -> void:
	_timer += delta
	if _timer >= 0.5:
		_timer = 0.0
		text = "FPS: %d" % Engine.get_frames_per_second()
