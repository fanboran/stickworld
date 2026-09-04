class_name VillagerBubble
extends Node2D
## 村民对话气泡 —— 目标提示的"世界内"表达（跟随 NPC 头顶，几秒淡出）。
##
## 由 DemoQuest 在目标推进时调用 speak()；挂在村民实体头顶（跟随 y 排序微调）。

var _label: Label = null
var _tail: Polygon2D = null
var _tween: Tween = null


func _ready() -> void:
	z_index = 95
	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 14)
	_label.add_theme_color_override("font_color", Color(0.12, 0.1, 0.08))
	_label.add_theme_color_override("font_outline_color", Color(0.97, 0.95, 0.9, 0.95))
	_label.add_theme_constant_override("outline_size", 6)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.size = Vector2(280, 44)
	_label.position = Vector2(-140, -34)
	add_child(_label)
	visible = false


## 说话：显示气泡 duration 秒后淡出（重复调用刷新文本与计时）
func speak(text: String, duration: float = 4.0) -> void:
	_label.text = "「 %s 」" % text
	visible = true
	modulate.a = 0.0
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(self, "modulate:a", 1.0, 0.25)
	_tween.tween_interval(duration)
	_tween.tween_property(self, "modulate:a", 0.0, 0.5)
	_tween.tween_callback(func() -> void: visible = false)
