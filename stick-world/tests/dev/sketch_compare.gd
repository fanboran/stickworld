extends Control
## 手绘自绘皮肤测试场景（B 路线定稿版）—— 从主菜单「测试场景」进入。
##
## 血条同源 boiling 自绘控件全族陈列：SketchPanel（DARK/LIGHT）、SketchButton
## 四态三色族、SketchProgress、SketchLineEdit、SketchSeparator 波浪线，
## 含 300px 宽 / 80px 高 / 30px 矮尺寸边界件；StickHand 程序化手写字体；
## 底部 GLASS 玻璃对照（主菜单皮肤）。ESC 返回主菜单。


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = StickTheme.create()  # SKETCH：Flat 兜底 + StickHand 字体
	var col := VBoxContainer.new()
	add_child(col)
	col.set_anchors_preset(Control.PRESET_CENTER)
	col.grow_horizontal = Control.GROW_DIRECTION_BOTH
	col.grow_vertical = Control.GROW_DIRECTION_BOTH
	col.offset_left = -360.0
	col.offset_right = 360.0
	col.offset_top = -430.0
	col.offset_bottom = 70.0
	col.add_theme_constant_override("separation", 12)
	_build(col)
	_build_glass_bar()


func _build(col: VBoxContainer) -> void:
	var title := Label.new()
	title.text = "手绘自绘皮肤（血条同源沸腾 + StickHand 字体）"
	title.add_theme_font_size_override("font_size", 24)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(title)

	# 主面板 + 按钮族
	var panel := SketchPanel.new()
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	_lab(v, "手绘面板 DARK（每 0.12s 独立重掷）", StickTokens.ACCENT, 15)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	v.add_child(row)
	StickKit.sketch_button(row, "普通", Callable(), StickKit.ButtonKind.NORMAL, 30)
	StickKit.sketch_button(row, "强调", Callable(), StickKit.ButtonKind.ACCENT, 30)
	StickKit.sketch_button(row, "危险", Callable(), StickKit.ButtonKind.DANGER, 30)
	var dis := StickKit.sketch_button(row, "禁用", Callable(), StickKit.ButtonKind.NORMAL, 30)
	dis.disabled = true
	StickKit.sketch_button(v, "大按钮 BTN_H_LG", Callable(), StickKit.ButtonKind.ACCENT, StickTokens.BTN_H_LG)
	col.add_child(panel)

	# 输入 + 进度
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 12)
	col.add_child(row2)
	var le := SketchLineEdit.new()
	le.text = "手绘输入框"
	le.custom_minimum_size = Vector2(220, 34)
	row2.add_child(le)
	var pb := SketchProgress.new()
	pb.value = 63
	pb.custom_minimum_size = Vector2(260, 24)
	row2.add_child(pb)

	# 尺寸边界件
	var row3 := HBoxContainer.new()
	row3.add_theme_constant_override("separation", 10)
	col.add_child(row3)
	var wide := StickKit.sketch_button(row3, "超宽 300px", Callable(), StickKit.ButtonKind.NORMAL, 32)
	wide.custom_minimum_size = Vector2(300, 32)
	var tall := StickKit.sketch_button(row3, "高 80px", Callable(), StickKit.ButtonKind.NORMAL, 80)
	tall.custom_minimum_size = Vector2(0, 80)

	# 分隔线 + LIGHT 面板
	var sep := SketchSeparator.new()
	col.add_child(sep)
	var light := SketchPanel.new()
	light.tone = SketchPanel.Tone.LIGHT
	_lab(light, "LIGHT 面板条（HUD 横条用）", StickTokens.TEXT_DIM, 13)
	col.add_child(light)

	# 竖波浪线 + 字体梯度
	var row4 := HBoxContainer.new()
	row4.add_theme_constant_override("separation", 10)
	row4.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(row4)
	var vsep := SketchSeparator.new()
	vsep.direction = SketchSeparator.Dir.VERTICAL
	vsep.custom_minimum_size = Vector2(10, 0)
	row4.add_child(vsep)
	var fl := VBoxContainer.new()
	fl.add_theme_constant_override("separation", 2)
	fl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row4.add_child(fl)
	for s in [34, 22, 14, 11]:
		var l := Label.new()
		l.text = "火柴人帝国 %dpx StickHand" % s
		l.add_theme_font_size_override("font_size", s)
		fl.add_child(l)


func _build_glass_bar() -> void:
	var bar := HBoxContainer.new()
	bar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	bar.offset_bottom = -16
	bar.offset_top = -60
	bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	bar.add_theme_constant_override("separation", 8)
	add_child(bar)
	var glass_note := Label.new()
	glass_note.text = "GLASS 对照（主菜单原样）："
	bar.add_child(glass_note)
	var gbox := PanelContainer.new()
	gbox.theme = StickTheme.create(StickTheme.Mode.GLASS)
	gbox.add_theme_stylebox_override("panel", GlassStyle.window_panel_light())
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	gbox.add_child(row)
	var g1 := Button.new(); g1.text = "普通"; g1.custom_minimum_size = Vector2(0, 30); row.add_child(g1)
	var g2 := Button.new(); g2.text = "强调"
	g2.add_theme_stylebox_override("normal", GlassStyle.accent_normal())
	g2.add_theme_stylebox_override("hover", GlassStyle.accent_hover())
	g2.custom_minimum_size = Vector2(0, 30); row.add_child(g2)
	bar.add_child(gbox)


func _lab(parent: Control, text: String, color: Color, size: int) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", size)
	parent.add_child(l)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		get_tree().change_scene_to_file("res://modules/ui_global/scenes/menus/main_menu.tscn")
