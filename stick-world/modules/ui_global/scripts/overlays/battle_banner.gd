extends Control
## 战斗胜负横幅 —— 战果仪式感（Kingdom 式全屏横幅：中央大字滑入停留淡出）。
##
## 经 UIKit.full_rect 挂 HudOverlay 槽；DemoQuest 监听 battle_ended 后调用
## show_banner(victory)。不阻挡输入（mouse_filter IGNORE）。

var _label: Label = null
var _sub: Label = null


func _ready() -> void:
	name = "BattleBanner"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.anchor_left = 0.5
	box.anchor_right = 0.5
	box.anchor_top = 0.32
	box.anchor_bottom = 0.32
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.add_theme_constant_override("separation", 4)
	add_child(box)

	_label = Label.new()
	# 44 无对应 token（FONT_DISPLAY 34 差 10px）：战果仪式感横幅大字，档位待定夺（上报项）
	_label.add_theme_font_size_override("font_size", 44)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_label)

	_sub = Label.new()
	_sub.add_theme_font_size_override("font_size", StickTokens.FONT_BODY)
	_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sub.add_theme_color_override("font_color", Color(0.85, 0.85, 0.88))
	box.add_child(_sub)


## 显示横幅（victory=true 金色"大捷"，false 灰蓝"败退"），3s 后淡出
## 遭遇战预告（红字短横幅，1.6s）
func show_preview() -> void:
	_label.text = "遭 遇 战 ！"
	_label.add_theme_color_override("font_color", Color(0.95, 0.4, 0.32))
	_label.add_theme_color_override("font_outline_color", Color(0.2, 0.02, 0.0, 0.95))
	_sub.text = "战斗开始——按空格暂停布置"
	_show_common(1.6)


func show_banner(victory: bool) -> void:
	if victory:
		_label.text = "大 捷"
		_label.add_theme_color_override("font_color", Color(1.0, 0.84, 0.4))
		_label.add_theme_color_override("font_outline_color", Color(0.35, 0.18, 0.0, 0.95))
		_sub.text = "敌军已被击溃"
	else:
		_label.text = "败 退"
		_label.add_theme_color_override("font_color", Color(0.6, 0.66, 0.75))
		_label.add_theme_color_override("font_outline_color", Color(0.08, 0.1, 0.16, 0.95))
		_sub.text = "重整旗鼓，再战"
	_show_common(2.2)


## 横幅动画公共段：弹入 → hold 秒 → 淡出
func _show_common(hold: float) -> void:
	visible = true
	modulate.a = 0.0
	scale = Vector2(1.0, 1.0)
	pivot_offset = Vector2(960.0, 140.0)
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 1.0, 0.3)
	tw.parallel().tween_property(self, "scale", Vector2.ONE, 0.4).from(Vector2(1.12, 1.12)).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tw.tween_interval(hold)
	tw.tween_property(self, "modulate:a", 0.0, 0.6)
	tw.tween_callback(func() -> void: visible = false)
