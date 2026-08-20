extends Control
## 预览 demo —— 白色磨砂面板 + 生成艺术模态背景（旋转立方体/鼠标排斥/光标光晕）。
##
## 运行（会短暂弹窗，渲染 ~1.5s 后自动保存截图退出）：
##   godot --path stick-world res://tests/dev/preview_glass_demo.tscn -- --shot=F:/out.png

var _backdrop: GenerativeBackdrop = null
var _shot_path: String = ""
var _frames: int = 0
const SHOT_FRAME: int = 70


func _ready() -> void:
	theme = StickTheme.create()
	set_anchors_preset(Control.PRESET_FULL_RECT)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			_shot_path = arg.trim_prefix("--shot=")
	# 多彩背景（让磨砂白面板/立方体的透感可见）
	var bg := Control.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	bg.draw.connect(func():
		var s: Vector2 = bg.size
		bg.draw_rect(Rect2(Vector2.ZERO, s), Color(0.1, 0.14, 0.22))
		var colors: Array = [Color(0.95, 0.68, 0.25), Color(0.55, 0.78, 1.0), Color(0.45, 0.8, 0.48), Color(0.9, 0.34, 0.3)]
		for i in range(14):
			bg.draw_circle(Vector2(
					fmod(float(i) * 173.0 + 90.0, s.x),
					fmod(float(i * 97), 900.0) + 60.0), 60.0 + float(i) * 7.0,
					Color(colors[i % colors.size()], 0.35))
	)
	# 生成艺术背景（模拟鼠标在偏右位置，让排斥 + 光晕入镜）
	_backdrop = GenerativeBackdrop.new()
	_backdrop.name = "Backdrop"
	_backdrop.dim_color = Color(0.02, 0.03, 0.06, 0.5)
	_backdrop.set_simulated_mouse(Vector2(1180, 430))
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_backdrop)
	# 白色磨砂面板 + 按钮
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", StickStyle.window_panel())
	add_child(panel)
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.offset_left = -320.0
	panel.offset_top = -220.0
	panel.offset_right = 320.0
	panel.offset_bottom = 220.0
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	panel.add_child(vbox)
	StickKit.label(vbox, "白色磨砂面板", StickKit.LabelKind.TITLE)
	StickKit.label(vbox, "无描边 + 柔和投影 · 半透明白玻璃质感", StickKit.LabelKind.HINT)
	vbox.add_child(HSeparator.new())
	var row1 := StickKit.row(vbox, 10)
	StickKit.button(row1, "主按钮", Callable(), StickKit.ButtonKind.ACCENT)
	StickKit.button(row1, "普通按钮")
	StickKit.button(row1, "危险按钮", Callable(), StickKit.ButtonKind.DANGER)
	var row2 := StickKit.row(vbox, 10)
	StickKit.button(row2, "禁用按钮")
	row2.get_child(row2.get_child_count() - 1).disabled = true
	StickKit.label(vbox, "背景：旋转圆润立方体 · 鼠标排斥 · 光标范围光效", StickKit.LabelKind.HINT)


func _process(_delta: float) -> void:
	_frames += 1
	if _frames == SHOT_FRAME:
		_save_shot()
	elif _frames > SHOT_FRAME + 5:
		get_tree().quit(0)


func _save_shot() -> void:
	if _shot_path.is_empty():
		return
	await get_tree().process_frame
	await get_tree().process_frame
	var img: Image = get_viewport().get_texture().get_image()
	var err: int = img.save_png(_shot_path)
	print("[preview] 截图保存: %s (err=%d)" % [_shot_path, err])
