extends Control
## 开局操作大提示（Demo 引导）—— 屏幕中央按键卡，6 秒自动淡出 / 任意键提前关。
## 经 UIKit.full_rect 创建挂 HudOverlay 槽；mouse_filter IGNORE 不挡操作。

const DISMISS_AFTER: float = 6.0

var _card: PanelContainer


func _ready() -> void:
	name = "OpeningHint"
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_card = SketchPanel.new()
	_card.tone = SketchPanel.Tone.LIGHT
	_card.set_anchors_preset(Control.PRESET_CENTER)
	_card.anchor_left = 0.5
	_card.anchor_right = 0.5
	_card.anchor_top = 0.5
	_card.anchor_bottom = 0.5
	_card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_card.offset_left = -300.0
	_card.offset_right = 300.0
	add_child(_card)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	_card.add_child(box)

	var title := Label.new()
	title.text = "欢迎来到火柴人大战略"
	title.add_theme_font_size_override("font_size", StickTokens.FONT_TITLE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color(1.0, 0.84, 0.45))
	box.add_child(title)

	for line: String in [
		"WASD 移动　·　E 采集 / 交互（可按住连采）",
		"Q 战斗模式（左键攻击 / 框选）　·　1-5 换武器",
		"Tab 战略图　·　空格 暂停/继续",
		"跟随右上角「阶段目标」推进游戏",
	]:
		var l := Label.new()
		l.text = line
		l.add_theme_font_size_override("font_size", StickTokens.FONT_BODY)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.add_theme_color_override("font_color", Color(0.92, 0.93, 0.95))
		box.add_child(l)

	var hint := Label.new()
	hint.text = "按任意键关闭"
	hint.add_theme_font_size_override("font_size", StickTokens.FONT_HINT)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.modulate = Color(1, 1, 1, 0.45)
	box.add_child(hint)

	# 入场淡入 + 定时淡出
	modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 1.0, 0.4)
	tween.tween_interval(DISMISS_AFTER)
	tween.tween_property(self, "modulate:a", 0.0, 0.6)
	tween.tween_callback(queue_free)
	set_process_unhandled_input(true)


func _unhandled_input(event: InputEvent) -> void:
	# 任意按键提前关闭（鼠标点击不算——开局误点常见）。
	# 不消费事件、不拦 ESC：ESC 属于暂停/模态语义，引导层不得吞键
	if event is InputEventKey and event.pressed and event.keycode != KEY_ESCAPE:
		_hide_now()


func _hide_now() -> void:
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, 0.25)
	tween.tween_callback(queue_free)
