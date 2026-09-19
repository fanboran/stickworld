class_name KeymapView
extends VBoxContainer
## 键鼠说明组合视图 —— 域过滤条 + 键盘图（SketchKeyboard）+ 鼠标图与域图例（SketchMouse）。
##
## 嵌入设置界面「控制」分类与组件陈列廊使用；纯展示，不消费任何输入事件。

var _kb: SketchKeyboard = null
var _mouse: SketchMouse = null
var _filter_buttons: Dictionary = {}  # domain id（"" = 全部）-> Button
var _filter: PackedStringArray = PackedStringArray()


func _ready() -> void:
	add_theme_constant_override("separation", 8)
	_build_filter_row()
	_kb = SketchKeyboard.new()
	_kb.custom_minimum_size = Vector2(0.0, 190.0)
	_kb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_kb)
	_build_mouse_row()
	var hint := Label.new()
	hint.text = "悬停键位查看功能说明 · 按下键位实时点亮（不影响游戏输入）"
	hint.add_theme_font_size_override("font_size", StickTokens.FONT_HINT)
	hint.modulate = StickTokens.TEXT_FAINT
	add_child(hint)


func _build_filter_row() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	add_child(row)
	var data := KeyBindingRegistry.load_default()
	_filter_buttons[""] = StickKit.auto_button(row, "全部", _on_filter.bind(""),
			StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_SM)
	for d: Dictionary in KeyBindingRegistry.domains(data):
		var id := String(d["id"])
		_filter_buttons[id] = StickKit.auto_button(row, String(d["title"]),
				_on_filter.bind(id), StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_SM)
	_update_filter_buttons()


func _build_mouse_row() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	add_child(row)
	_mouse = SketchMouse.new()
	row.add_child(_mouse)
	# 域图例（鼠标右侧余量）：域色块 + 域名 + 该域绑定数
	var legend := VBoxContainer.new()
	legend.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	legend.add_theme_constant_override("separation", 4)
	legend.alignment = BoxContainer.AlignmentMode.ALIGNMENT_CENTER
	row.add_child(legend)
	var data := KeyBindingRegistry.load_default()
	for d: Dictionary in KeyBindingRegistry.domains(data):
		var lrow := HBoxContainer.new()
		lrow.add_theme_constant_override("separation", 6)
		legend.add_child(lrow)
		var swatch := ColorRect.new()
		swatch.custom_minimum_size = Vector2(10, 10)
		swatch.color = StickTokens.content_color(
				KeyBindingRegistry.domain_color_id(data, String(d["id"])))
		lrow.add_child(swatch)
		var l := Label.new()
		l.text = "%s · %d 项" % [d["title"], _count_bindings(data, String(d["id"]))]
		l.add_theme_font_size_override("font_size", StickTokens.FONT_HINT)
		l.modulate = StickTokens.TEXT_DIM
		lrow.add_child(l)


func _count_bindings(data: Dictionary, domain: String) -> int:
	var n: int = 0
	for b: Dictionary in data.get("bindings", []):
		if String(b.get("domain", "")) == domain:
			n += 1
	return n


func _on_filter(domain_id: String) -> void:
	_filter = PackedStringArray() if domain_id.is_empty() else PackedStringArray([domain_id])
	_kb.set_domain_filter(_filter)
	_mouse.set_domain_filter(_filter)
	_update_filter_buttons()


func _update_filter_buttons() -> void:
	for id: String in _filter_buttons:
		var btn: Button = _filter_buttons[id]
		btn.kind = SketchButton.Kind.ACCENT if id == _filtered_id() else SketchButton.Kind.DARK


func _filtered_id() -> String:
	return "" if _filter.is_empty() else _filter[0]
