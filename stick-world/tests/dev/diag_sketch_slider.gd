extends Control
## 诊断：SketchHSlider 手绘滑条视觉验收 —— SketchPanel 托底 + 0%/60% 两态滑条，
## 截图后退出。运行（必须带显示）：
##   godot --path stick-world res://tests/dev/diag_sketch_slider.tscn --resolution 1920x1080
## 产物：user://shots/diag_slider_0.png / diag_slider_60.png

const SHOT_DIR := "user://shots"

var _frames: int = 0
var _slider60: SketchHSlider = null


func _ready() -> void:
	get_window().size = Vector2i(1920, 1080)
	var panel := SketchPanel.new()
	panel.tone = SketchPanel.Tone.DARK
	add_child(panel)
	StickKit.center_on_screen(panel, Vector2(520, 240))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	panel.add_child(box)
	var title := StickKit.label(box, "手绘滑条陈列", StickKit.LabelKind.BODY)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# 0%：轨道 + 滑块贴左（填充不暴露）
	var s0 := SketchHSlider.new()
	s0.min_value = 0.0
	s0.max_value = 100.0
	s0.custom_minimum_size = Vector2(420, 0)
	box.add_child(s0)
	# 60%：琥珀填充暴露（中间值验收态）
	_slider60 = SketchHSlider.new()
	_slider60.min_value = 0.0
	_slider60.max_value = 100.0
	_slider60.value = 60.0
	_slider60.custom_minimum_size = Vector2(420, 0)
	box.add_child(_slider60)
	# 原生 tick_count 刻度机制演示（均匀 6 档）
	var s_tick := SketchHSlider.new()
	s_tick.min_value = 0.0
	s_tick.max_value = 100.0
	s_tick.value = 30.0
	s_tick.tick_count = 6
	s_tick.custom_minimum_size = Vector2(420, 0)
	box.add_child(s_tick)
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)


func _process(_delta: float) -> void:
	_frames += 1
	if _frames == 40:
		_snap("diag_slider_60")
	elif _frames == 46:
		# 切到 0% 态再截（同帧对比填充有无）
		_slider60.value = 0.0
	elif _frames == 52:
		_snap("diag_slider_0")
		get_tree().quit(0)


func _snap(shot_name: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [SHOT_DIR, shot_name])
	print("[DiagSlider] %s.png" % shot_name)
