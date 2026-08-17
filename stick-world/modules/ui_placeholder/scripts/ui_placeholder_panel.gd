class_name UIPlaceholderPanel
extends BaseScreen
## 通用空面板 —— 依赖系统未建立的大界面占位（黑玻璃样式已就绪）。
##
## 用法：UIPlaceholderPanel.open_panel(layer, preset_id)
## 内容区按预设生成演示骨架（让面板像样、可验收）；系统接入时替换为真实内容，
## 并按 modules/ui_placeholder/api.gd 的说明移入对应业务模块。

const PANEL_W := 520
const PANEL_H := 540

## 面板内容实例缓存（同类单例，重复打开提至栈顶——见 02 篇模态栈规则）
var _preset: Dictionary = {}
var _content_box: VBoxContainer = null


static func open_panel(layer: Control, preset_id: String) -> UIPlaceholderPanel:
	for preset in UIPlaceholderPresets.PRESETS:
		if preset["id"] == preset_id:
			var panel := UIKit.full_rect(UIPlaceholderPanel, "UIPlaceholder_" + preset_id) as UIPlaceholderPanel
			panel._preset = preset
			panel.panel_size = Vector2(PANEL_W, PANEL_H)
			layer.add_child(panel)
			panel._build_screen()
			panel.open()
			return panel
	push_warning("[UIPlaceholder] 未知预设: %s" % preset_id)
	return null


## 覆盖 BaseScreen：构建面板内容（预设数据驱动）
func _build_content() -> void:
	# 标题
	var title := Label.new()
	title.text = _preset.get("title", "未命名界面")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", UITheme.FONT_TITLE)
	_panel.add_child(title)
	title.set_anchors_preset(Control.PRESET_TOP_WIDE)
	title.offset_top = 16
	title.offset_bottom = 52
	# 说明
	var desc := Label.new()
	desc.text = _preset.get("desc", "")
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.add_theme_font_size_override("font_size", UITheme.FONT_HINT)
	desc.modulate = UITheme.COLOR_DIM_TEXT
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel.add_child(desc)
	desc.set_anchors_preset(Control.PRESET_TOP_WIDE)
	desc.offset_top = 54
	desc.offset_bottom = 84
	desc.offset_left = 24
	desc.offset_right = -24
	# 内容区（演示骨架）
	_content_box = VBoxContainer.new()
	_content_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	_content_box.offset_top = 92
	_content_box.offset_bottom = -64
	_content_box.offset_left = 24
	_content_box.offset_right = -24
	_content_box.add_theme_constant_override("separation", 10)
	_panel.add_child(_content_box)
	_build_demo_body()
	# 接入点提示
	var note := Label.new()
	note.text = _preset.get("note", "")
	note.add_theme_font_size_override("font_size", UITheme.FONT_HINT)
	note.modulate = UITheme.COLOR_DIM_TEXT
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel.add_child(note)
	note.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	note.offset_top = -56
	note.offset_bottom = -14
	note.offset_left = 24
	note.offset_right = -24
	# 关闭按钮
	var close_btn := Button.new()
	close_btn.text = "关闭（ESC）"
	close_btn.pressed.connect(close)
	_panel.add_child(close_btn)
	close_btn.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	close_btn.offset_left = -110
	close_btn.offset_top = -52
	close_btn.offset_right = -16
	close_btn.offset_bottom = -16


## 演示骨架：每面板一小组占位元素，让界面"像样"（系统接入后整体替换）
func _build_demo_body() -> void:
	match _preset.get("id", ""):
		"tech_tree":
			var grid := GridContainer.new()
			grid.columns = 4
			grid.add_theme_constant_override("h_separation", 8)
			grid.add_theme_constant_override("v_separation", 8)
			_content_box.add_child(grid)
			for i in range(8):
				grid.add_child(_node_card("课题 %d" % (i + 1)))
		"logistics":
			_content_box.add_child(_node_card("商队 A — 北境行省"))
			_content_box.add_child(_node_card("商队 B — 东海岸"))
			_content_box.add_child(_node_card("干线 · 中央物流网"))
		"collection":
			var grid := GridContainer.new()
			grid.columns = 4
			grid.add_theme_constant_override("h_separation", 8)
			grid.add_theme_constant_override("v_separation", 8)
			_content_box.add_child(grid)
			for i in range(8):
				grid.add_child(_node_card("图鉴 %d" % (i + 1)))
		"empire_overview":
			for stat in [["人口", 12540], ["编制数", 12], ["国库", 3480]]:
				var row := HBoxContainer.new()
				row.add_theme_constant_override("separation", 12)
				var name_l := Label.new()
				name_l.text = stat[0]
				name_l.custom_minimum_size = Vector2(90, 0)
				row.add_child(name_l)
				var bar := ProgressBar.new()
				bar.min_value = 0
				bar.max_value = 20000 if stat[0] == "人口" else 100
				bar.value = stat[1]
				bar.custom_minimum_size = Vector2(0, 18)
				bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				row.add_child(bar)
				_content_box.add_child(row)
		"new_game_wizard":
			for field in [["世界种子", "20260817"], ["城邦数", "8"], ["世界尺寸", "标准"]]:
				var row := HBoxContainer.new()
				row.add_theme_constant_override("separation", 12)
				var name_l := Label.new()
				name_l.text = field[0]
				name_l.custom_minimum_size = Vector2(90, 0)
				row.add_child(name_l)
				var line := LineEdit.new()
				line.text = field[1]
				line.editable = false
				line.custom_minimum_size = Vector2(0, 32)
				line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				row.add_child(line)
				_content_box.add_child(row)
		_:
			pass


func _node_card(text: String) -> PanelContainer:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", StickStyle.window_panel_light())
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", UITheme.FONT_HINT)
	card.add_child(l)
	return card


## ESC 关闭
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()
