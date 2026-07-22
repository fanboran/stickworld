@tool
extends Node2D
## 茅草材质调试场景
##
## 左侧：Sprite2D + ShaderMaterial，实时渲染茅草
## 右侧：参数面板（Slider / SpinBox / CheckButton），实时调整 uniform
##
## 用法：运行场景 → 拖动右侧滑动条 → 左侧实时反映 Shader 渲染效果

var _sprite: Sprite2D
var _material: ShaderMaterial


func _ready() -> void:
	_sprite = get_node_or_null("Sprite2D") as Sprite2D
	if _sprite == null:
		push_warning("[ThatchDebug] 缺少 Sprite2D 节点")
		return

	_material = _sprite.material as ShaderMaterial
	if _material == null:
		push_warning("[ThatchDebug] Sprite2D 缺少 ShaderMaterial")
		return

	_build_ui()


# ── 构建 UI ──

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.name = "DebugUI"
	add_child(layer)

	# 右侧面板容器
	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.anchor_right = 1.0
	panel.offset_left = -320.0
	panel.offset_right = -10.0
	panel.offset_top = 10.0
	panel.offset_bottom = -10.0
	layer.add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	panel.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.name = "Params"
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)

	var title := Label.new()
	title.text = "茅草材质参数"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	vbox.add_child(_separator())

	# 角度（度数，0 = 竖直，-60 = 左屋顶，+60 = 右屋顶）
	var angle_slider := _add_slider(vbox, "blade_angle (°)", -90.0, 90.0, -60.0, 1.0)
	angle_slider.value_changed.connect(func(v: float) -> void:
		_material.set_shader_parameter("blade_angle", deg_to_rad(v))
	)

	# 层数
	var rows_slider := _add_slider(vbox, "rows", 1.0, 32.0, 6.0, 1.0)
	rows_slider.value_changed.connect(func(v: float) -> void:
		_material.set_shader_parameter("rows", int(v))
	)

	# 每层叶片数
	var blades_slider := _add_slider(vbox, "blades_per_row", 1.0, 64.0, 20.0, 1.0)
	blades_slider.value_changed.connect(func(v: float) -> void:
		_material.set_shader_parameter("blades_per_row", int(v))
	)

	# 叶片长度
	var len_slider := _add_slider(vbox, "blade_length_base", 20.0, 300.0, 120.0, 5.0)
	len_slider.value_changed.connect(func(v: float) -> void:
		_material.set_shader_parameter("blade_length_base", v)
	)

	# 叶片宽度
	var wid_slider := _add_slider(vbox, "blade_width_base", 1.0, 30.0, 10.0, 0.5)
	wid_slider.value_changed.connect(func(v: float) -> void:
		_material.set_shader_parameter("blade_width_base", v)
	)

	# 根部宽度倍率
	var root_w_slider := _add_slider(vbox, "root_width_mul", 0.5, 3.0, 1.6, 0.1)
	root_w_slider.value_changed.connect(func(v: float) -> void:
		_material.set_shader_parameter("root_width_mul", v)
	)

	# 梢部宽度倍率
	var tip_w_slider := _add_slider(vbox, "tip_width_mul", 0.05, 1.5, 0.25, 0.05)
	tip_w_slider.value_changed.connect(func(v: float) -> void:
		_material.set_shader_parameter("tip_width_mul", v)
	)

	# 笔触宽度抖动
	var wnoise_slider := _add_slider(vbox, "width_noise", 0.0, 1.5, 0.45, 0.05)
	wnoise_slider.value_changed.connect(func(v: float) -> void:
		_material.set_shader_parameter("width_noise", v)
	)

	# 油画边缘粗糙度
	var oil_slider := _add_slider(vbox, "oil_roughness", 0.0, 1.5, 0.55, 0.05)
	oil_slider.value_changed.connect(func(v: float) -> void:
		_material.set_shader_parameter("oil_roughness", v)
	)

	# 下边缘余量
	var margin_slider := _add_slider(vbox, "margin_bottom", 0.0, 120.0, 55.0, 1.0)
	margin_slider.value_changed.connect(func(v: float) -> void:
		_material.set_shader_parameter("margin_bottom", v)
	)

	# 随机种子
	var seed_slider := _add_slider(vbox, "seed", 0.0, 100.0, 0.0, 1.0)
	seed_slider.value_changed.connect(func(v: float) -> void:
		_material.set_shader_parameter("seed", int(v))
	)

	vbox.add_child(_separator())

	# 显示边界框
	var bounds_btn := CheckButton.new()
	bounds_btn.text = "show_bounds"
	bounds_btn.button_pressed = false
	bounds_btn.toggled.connect(func(pressed: bool) -> void:
		_material.set_shader_parameter("show_bounds", pressed)
	)
	vbox.add_child(bounds_btn)


func _add_slider(parent: Control, label_text: String, min_v: float, max_v: float, default_v: float, step: float) -> HSlider:
	var label := Label.new()
	label.text = "%s: %s" % [label_text, str(default_v)]
	label.name = "Label_" + label_text
	parent.add_child(label)

	var slider := HSlider.new()
	slider.name = label_text
	slider.min_value = min_v
	slider.max_value = max_v
	slider.value = default_v
	slider.step = step
	slider.custom_minimum_size = Vector2(0, 24)
	slider.value_changed.connect(func(v: float) -> void:
		label.text = "%s: %.3f" % [label_text, v]
	)
	parent.add_child(slider)
	return slider


func _separator() -> HSeparator:
	var sep := HSeparator.new()
	sep.custom_minimum_size = Vector2(0, 8)
	return sep
