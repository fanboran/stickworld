extends Control
## Demo 胜利结算画面 —— 全屏半透明遮罩 + 中心结算卡（统计 + 继续按钮）。
##
## 经 UIKit.full_rect 创建、挂 UIRoot.ModalOverlay 槽；由 DemoQuest 调 setup(stats)
## 填充内容。点「继续游玩」隐藏自身（Demo 继续自由沙盒）。

var _card: PanelContainer


func _ready() -> void:
	name = "VictoryOverlay"
	mouse_filter = Control.MOUSE_FILTER_STOP  # 模态：挡住下层输入

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	_card = PanelContainer.new()
	_card.set_anchors_preset(Control.PRESET_CENTER)
	_card.anchor_left = 0.5
	_card.anchor_right = 0.5
	_card.anchor_top = 0.5
	_card.anchor_bottom = 0.5
	_card.offset_left = -260.0
	_card.offset_right = 260.0
	_card.offset_top = -190.0
	_card.offset_bottom = 190.0
	_card.add_theme_stylebox_override("panel", StickStyle.window_panel_light())
	add_child(_card)
	visible = false


## 填充并显示。stats: {time_text, harvest, builds, squads, battles}
func show_victory(stats: Dictionary) -> void:
	for child in _card.get_children():
		child.queue_free()

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	_card.add_child(box)

	var title := Label.new()
	title.text = "第 一 章 · 完 成"
	title.add_theme_font_size_override("font_size", 26)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color(1.0, 0.84, 0.45))
	box.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "火柴人大战略 —— 求职 Demo 阶段目标全部达成"
	subtitle.add_theme_font_size_override("font_size", 13)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_color_override("font_color", Color(0.7, 0.73, 0.78))
	box.add_child(subtitle)

	var stats_line := Label.new()
	stats_line.text = "用时 %s　·　采集木材 %d　·　建造 %d　·　编队 %d　·　战斗胜利 %d" % [
		String(stats.get("time_text", "-")),
		int(stats.get("harvest", 0)), int(stats.get("builds", 0)),
		int(stats.get("squads", 0)), int(stats.get("battles", 0)),
	]
	stats_line.add_theme_font_size_override("font_size", 14)
	stats_line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stats_line.add_theme_color_override("font_color", Color(0.9, 0.92, 0.9))
	box.add_child(stats_line)

	var hint := Label.new()
	hint.text = "自由沙盒已开放：Tab 战略图 / Q 战斗指挥 / 附身任意士兵微操"
	hint.add_theme_font_size_override("font_size", 12)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_color_override("font_color", Color(0.6, 0.63, 0.68))
	box.add_child(hint)

	var btn := Button.new()
	btn.text = "继 续 游 玩"
	btn.custom_minimum_size = Vector2(180, 40)
	btn.pressed.connect(_on_continue)
	box.add_child(btn)

	visible = true
	# 入场：卡片从 0.85 缩放弹入 + 整体淡入
	_card.scale = Vector2(0.85, 0.85)
	modulate.a = 0.0
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "modulate:a", 1.0, 0.4)
	tween.tween_property(_card, "scale", Vector2.ONE, 0.45).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)


func _on_continue() -> void:
	visible = false
