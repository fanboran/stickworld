class_name UIPlaceholderPanel
extends StickScreen
## 通用空面板 —— 依赖系统未建立的大界面占位（黑玻璃统一弹窗骨架）。
##
## 用法：UIPlaceholderPanel.open_panel(layer, preset_id)
## 内容区按预设生成演示骨架（让面板像样、可验收）；系统接入时替换为真实内容，
## 并按 placeholder_presets.gd 各项「将来接入点」移入对应业务模块。
##
## 游戏内经 UIModalStack EMPIRE_PANEL 层管理（同类单例：重复触发提到栈顶、
## 换预设替换不叠加——见 02 篇模态栈规则）；无 UIRoot 环境（模板预览）回退自管理。

const PANEL_W := 520
const PANEL_H := 540

## 面板内容预设
var _preset: Dictionary = {}


static func open_panel(layer: Control, preset_id: String) -> UIPlaceholderPanel:
	for preset in UIPlaceholderPresets.PRESETS:
		if preset["id"] == preset_id:
			var stack := UIModalStack.find(layer)
			if stack != null and stack.is_open(UIModalStack.Layer.EMPIRE_PANEL):
				var existing: Control = stack.get_entry(UIModalStack.Layer.EMPIRE_PANEL)
				if existing is UIPlaceholderPanel and existing._preset.get("id", "") == preset_id:
					# 重复触发 → 提到栈顶（同类单例）
					stack.raise_to_top(UIModalStack.Layer.EMPIRE_PANEL)
					return existing
				# 同层不同预设 → 替换（同类单例，不叠加）
				stack.pop(UIModalStack.Layer.EMPIRE_PANEL)
			var panel := UIKit.full_rect(UIPlaceholderPanel, "UIPlaceholder_" + preset_id) as UIPlaceholderPanel
			panel._preset = preset
			panel.panel_size = Vector2(PANEL_W, PANEL_H)
			panel.panel_title = preset["title"]
			layer.add_child(panel)
			panel._build_screen()
			if stack != null:
				stack.push(panel, UIModalStack.Layer.EMPIRE_PANEL)
			else:
				panel.open()
			return panel
	push_warning("[UIPlaceholder] 未知预设: %s" % preset_id)
	return null


## 覆盖 StickScreen：占位面板为瞬态（每次打开新建），关闭即销毁，不残留隐藏实例
func close() -> void:
	super.close()
	queue_free()


## 覆盖 StickScreen：往 _body 加说明 + 演示骨架 + 接入点提示；_footer 关闭
func _build_content() -> void:
	# 说明
	var desc := Label.new()
	desc.text = _preset.get("desc", "")
	desc.add_theme_font_size_override("font_size", StickTokens.FONT_HINT)
	desc.modulate = StickTokens.TEXT_DIM
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_child(desc)
	StickKit.separator(_body)
	_build_demo_body()
	# 接入点提示
	var note := Label.new()
	note.text = _preset.get("note", "")
	note.add_theme_font_size_override("font_size", StickTokens.FONT_HINT)
	note.modulate = StickTokens.TEXT_FAINT
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_child(note)
	# 底栏
	StickKit.button(_footer, "关闭（ESC）", close)


## 演示骨架：每面板一小组占位元素，让界面"像样"（系统接入后整体替换）
func _build_demo_body() -> void:
	match _preset.get("id", ""):
		"tech_tree":
			var grid := GridContainer.new()
			grid.columns = 4
			grid.add_theme_constant_override("h_separation", 8)
			grid.add_theme_constant_override("v_separation", 8)
			_body.add_child(grid)
			for i in range(8):
				grid.add_child(_node_card("课题 %d" % (i + 1)))
		"logistics":
			_body.add_child(_node_card("商队 A — 北境行省"))
			_body.add_child(_node_card("商队 B — 东海岸"))
			_body.add_child(_node_card("干线 · 中央物流网"))
		"collection":
			var grid := GridContainer.new()
			grid.columns = 4
			grid.add_theme_constant_override("h_separation", 8)
			grid.add_theme_constant_override("v_separation", 8)
			_body.add_child(grid)
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
				_body.add_child(row)
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
				_body.add_child(row)
		_:
			pass


func _node_card(text: String) -> PanelContainer:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", StickStyle.window_panel_light())
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", StickTokens.FONT_HINT)
	card.add_child(l)
	return card


## ESC 关闭。在模态栈中时让位给 GameRoot._handle_escape 统一退栈（不自行消费）；
## 无栈环境（模板预览场景）自关。
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		var stack := UIModalStack.find(self)
		if stack != null and stack.get_entry(UIModalStack.Layer.EMPIRE_PANEL) == self:
			return
		close()
		get_viewport().set_input_as_handled()
