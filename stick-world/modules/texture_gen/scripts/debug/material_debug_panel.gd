@tool
class_name MaterialDebugPanel
extends Node2D
## 材质调试面板公共基类 —— Sprite2D/ShaderMaterial 获取样板 + 滑杆/分隔线构建原语。
##
## 约定场景结构：根 Node2D 下挂 Sprite2D（带 ShaderMaterial）；子类实现 _build_ui()
## 构建参数面板（通常 CanvasLayer + PanelContainer + VBox），用 _add_slider 写 uniform。
## 子类覆写 warning_tag() 定制日志前缀（默认 MaterialDebug）。

var _sprite: Sprite2D
var _material: ShaderMaterial


func _ready() -> void:
	_sprite = get_node_or_null("Sprite2D") as Sprite2D
	if _sprite == null:
		push_warning("[%s] 缺少 Sprite2D 节点" % warning_tag())
		return

	_material = _sprite.material as ShaderMaterial
	if _material == null:
		push_warning("[%s] Sprite2D 缺少 ShaderMaterial" % warning_tag())
		return

	_build_ui()


## 日志前缀（子类覆写）
func warning_tag() -> String:
	return "MaterialDebug"


## 子类构建调试 UI（此时 _sprite/_material 已就绪）
func _build_ui() -> void:
	pass


## 参数滑杆：拖动实时写 uniform（component >= 0 时写 vec/vector 的指定分量；
## uniform_name 为空则用 label_text 作 uniform 名）
func _add_slider(
	parent: Control, label_text: String, min_v: float, max_v: float,
	default_v: float, step: float, uniform_name: String = "", component: int = -1
) -> HSlider:
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


## 面板分组分隔线
func _separator() -> HSeparator:
	var sep := HSeparator.new()
	sep.custom_minimum_size = Vector2(0, 8)
	return sep
