extends Control
## 手绘控件诊断页 —— SketchCheckBox/SketchCheckButton/SketchOptionButton/
## SketchTabContainer 单独陈列截图，用于手绘化视觉排查（对齐 diag_* 系列惯例）。
##
## 运行：godot --path stick-world res://tests/dev/diag_sketch_controls.tscn
## 产物：user://shots/diag_sketch_controls.png，画完自动退出。


func _ready() -> void:
	theme = StickTheme.create()
	var bg := ColorRect.new()
	bg.color = Color(0.04, 0.05, 0.06)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	_build()
	_shot_async()


func _build() -> void:
	var box := VBoxContainer.new()
	box.position = Vector2(60, 60)
	box.custom_minimum_size = Vector2(500, 0)
	box.add_theme_constant_override("separation", 18)
	add_child(box)

	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 16)
	box.add_child(row1)
	var t_on := SketchCheckButton.new()
	t_on.button_pressed = true
	row1.add_child(t_on)
	var t_off := SketchCheckButton.new()
	row1.add_child(t_off)
	var t_dis := SketchCheckButton.new()
	t_dis.button_pressed = true
	t_dis.disabled = true
	row1.add_child(t_dis)

	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 16)
	box.add_child(row2)
	var c_on := SketchCheckBox.new()
	c_on.text = "复选 选中"
	c_on.button_pressed = true
	row2.add_child(c_on)
	var c_off := SketchCheckBox.new()
	c_off.text = "复选 未选"
	row2.add_child(c_off)
	var c_dis := SketchCheckBox.new()
	c_dis.text = "复选 禁用"
	c_dis.button_pressed = true
	c_dis.disabled = true
	row2.add_child(c_dis)

	var opt := SketchOptionButton.new()
	for item in ["窗口化", "无边框全屏", "独占全屏"]:
		opt.add_item(item)
	opt.selected = 1
	opt.custom_minimum_size = Vector2(220, StickTokens.BTN_H)
	box.add_child(opt)

	var native_opt := OptionButton.new()
	for item in ["低", "中", "高"]:
		native_opt.add_item(item)
	native_opt.selected = 0
	native_opt.custom_minimum_size = Vector2(220, StickTokens.BTN_H)
	box.add_child(native_opt)

	var native_chk := CheckBox.new()
	native_chk.text = "原生 CheckBox（主题图标兜底）"
	box.add_child(native_chk)
	var native_tg := CheckButton.new()
	native_tg.button_pressed = true
	box.add_child(native_tg)

	var tabs := SketchTabContainer.new()
	tabs.position = Vector2(620, 60)
	tabs.custom_minimum_size = Vector2(280, 150)
	add_child(tabs)
	for title in ["总览", "编制", "科技"]:
		var page := MarginContainer.new()
		page.name = title
		var l := Label.new()
		l.text = "「%s」页" % title
		page.add_child(l)
		tabs.add_child(page)
		tabs.set_tab_title(page.get_index(), title)

	# ── 设置面板行复刻（ScrollContainer + 行高 36 + Label EXPAND_FILL）──
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(620, 240)
	scroll.custom_minimum_size = Vector2(320, 130)
	add_child(scroll)
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 8)
	scroll.add_child(rows)
	for cfg in [["战斗开始时自动暂停", true, false], ["附身微操时自动减速", true, false],
			["缩放时 UI 渐隐渐显", false, true]]:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		row.custom_minimum_size = Vector2(0, StickTokens.ROW_H)
		rows.add_child(row)
		var name_l := Label.new()
		name_l.text = cfg[0]
		name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(name_l)
		var tg := SketchCheckButton.new()
		tg.button_pressed = cfg[1]
		row.add_child(tg)
		if cfg[2]:
			row.modulate = Color(1.0, 1.0, 1.0, 0.5)
			tg.disabled = true


func _shot_async() -> void:
	for i in 8:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute("user://shots")
	img.save_png("user://shots/diag_sketch_controls.png")
	print("[DiagSketchControls] saved")
	get_tree().quit()
