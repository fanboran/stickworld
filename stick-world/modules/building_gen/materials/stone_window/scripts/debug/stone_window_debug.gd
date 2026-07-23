@tool
extends Node2D
## 拱形石窗材质调试场景

var _sprite: Sprite2D
var _material: ShaderMaterial


func _ready() -> void:
	_sprite = get_node_or_null("Sprite2D") as Sprite2D
	if _sprite == null:
		push_warning("[StoneWindowDebug] 缺少 Sprite2D 节点")
		return

	_material = _sprite.material as ShaderMaterial
	if _material == null:
		push_warning("[StoneWindowDebug] Sprite2D 缺少 ShaderMaterial")
		return

	_build_ui()


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.name = "DebugUI"
	add_child(layer)

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
	title.text = "拱形石窗材质参数"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	vbox.add_child(_separator())

	_add_slider(vbox, "window_width", 80.0, 260.0, 180.0, 1.0)
	_add_slider(vbox, "window_height", 120.0, 420.0, 300.0, 1.0)
	_add_slider(vbox, "arch_height", 30.0, 130.0, 90.0, 1.0)
	_add_slider(vbox, "frame_thickness", 8.0, 40.0, 22.0, 0.5)
	_add_slider(vbox, "frame_depth", 0.0, 20.0, 8.0, 0.5)
	_add_slider(vbox, "arch_stones", 3.0, 17.0, 9.0, 1.0)

	vbox.add_child(_separator())

	_add_slider(vbox, "vertical_bars", 1.0, 9.0, 5.0, 1.0)
	_add_slider(vbox, "horizontal_bars", 1.0, 9.0, 4.0, 1.0)
	_add_slider(vbox, "bar_width", 1.0, 10.0, 4.0, 0.5)

	vbox.add_child(_separator())

	_add_slider(vbox, "sill_height", 0.0, 40.0, 18.0, 1.0)
	_add_slider(vbox, "sill_extension", 0.0, 50.0, 18.0, 1.0)

	vbox.add_child(_separator())

	_add_slider(vbox, "wall_brick_size.x", 40.0, 160.0, 96.0, 1.0, "wall_brick_size", 0)
	_add_slider(vbox, "wall_brick_size.y", 30.0, 120.0, 70.0, 1.0, "wall_brick_size", 1)
	_add_slider(vbox, "wall_gap_size.x", 0.0, 12.0, 5.0, 0.5, "wall_gap_size", 0)
	_add_slider(vbox, "wall_gap_size.y", 0.0, 12.0, 5.0, 0.5, "wall_gap_size", 1)


func _add_slider(parent: Control, label_text: String, min_v: float, max_v: float, default_v: float, step: float, uniform_name: String = "", component: int = -1) -> HSlider:
	var label := Label.new()
	label.text = "%s: %s" % [label_text, str(default_v)]
	label.name = "Label_" + label_text.replace(".", "_")
	parent.add_child(label)

	var slider := HSlider.new()
	slider.name = label_text.replace(".", "_")
	slider.min_value = min_v
	slider.max_value = max_v
	slider.value = default_v
	slider.step = step
	slider.custom_minimum_size = Vector2(0, 24)

	var target := uniform_name if uniform_name != "" else label_text

	slider.value_changed.connect(func(v: float) -> void:
		label.text = "%s: %.3f" % [label_text, v]
		if component < 0:
			_material.set_shader_parameter(target, v)
		else:
			var vec = _material.get_shader_parameter(target)
			vec[component] = v
			_material.set_shader_parameter(target, vec)
	)
	parent.add_child(slider)
	return slider


func _separator() -> HSeparator:
	var sep := HSeparator.new()
	sep.custom_minimum_size = Vector2(0, 8)
	return sep
