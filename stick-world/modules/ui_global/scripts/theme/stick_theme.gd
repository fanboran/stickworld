class_name StickTheme
extends RefCounted
## Theme 构建器 —— 把 StickTokens/StickStyle 打包成一个可挂任意根节点的 Theme。
##
## 用法：
##   func _ready() -> void:
##       theme = StickTheme.create()        # 整棵子树自动继承
##
## 覆盖控件：Button / Label / Panel / PanelContainer / LineEdit / OptionButton /
## CheckBox / CheckButton / HSlider / ProgressBar / TabContainer / ItemList /
## HSeparator / VSeparator / TooltipPanel。
## 主题热切换 = 重新赋值 theme（token 变更后调用 refresh(node) 即可）。


## 构建完整主题（每次调用新建实例，调用方持有）
static func create() -> Theme:
	var t := Theme.new()
	_apply_button(t)
	_apply_label(t)
	_apply_panel(t)
	_apply_inputs(t)
	_apply_slider(t)
	_apply_progress(t)
	_apply_tabs(t)
	_apply_list(t)
	_apply_misc(t)
	return t


## 热切换：把新主题挂到根节点（整树生效）
static func refresh(root: Control) -> void:
	root.theme = create()


## 浅色表面主题（白色磨砂面板子树专用）：全局默认是深色面（浅字），
## 白面板上文字要反转为深色。只翻 Label 族（按钮/输入框仍是深玻璃浅字，两态通用）。
## 用法：白色 PanelContainer 上挂 `theme = StickTheme.create_light_surface()`。
static func create_light_surface() -> Theme:
	var t := create()
	t.set_color("font_color", "Label", StickTokens.TEXT_ON_LIGHT)
	t.set_color("font_color", "CheckBox", StickTokens.TEXT_ON_LIGHT)
	t.set_color("font_disabled_color", "CheckBox", StickTokens.TEXT_ON_LIGHT_DISABLED)
	t.set_color("font_color", "CheckButton", StickTokens.TEXT_ON_LIGHT)
	t.set_color("font_disabled_color", "CheckButton", StickTokens.TEXT_ON_LIGHT_DISABLED)
	t.set_color("font_color", "ProgressBar", StickTokens.TEXT_ON_LIGHT)
	t.set_color("font_color", "TooltipLabel", StickTokens.TEXT_ON_LIGHT)
	return t


# ─────────────────────────────── 控件装配 ────────────────────────────────

static func _apply_button(t: Theme) -> void:
	t.set_stylebox("normal", "Button", StickStyle.button_normal())
	t.set_stylebox("hover", "Button", StickStyle.button_hover())
	t.set_stylebox("pressed", "Button", StickStyle.button_pressed())
	t.set_stylebox("disabled", "Button", StickStyle.button_disabled())
	t.set_stylebox("focus", "Button", _empty_focus())
	# 按钮=磨砂玻璃（浅色底）→ 深色文字，两表面通用
	t.set_color("font_color", "Button", StickTokens.TEXT_ON_LIGHT)
	t.set_color("font_hover_color", "Button", StickTokens.TEXT_ON_LIGHT)
	t.set_color("font_pressed_color", "Button", StickTokens.ACCENT)
	t.set_color("font_disabled_color", "Button", StickTokens.TEXT_ON_LIGHT_DISABLED)
	t.set_font_size("font_size", "Button", StickTokens.FONT_BODY)


static func _apply_label(t: Theme) -> void:
	t.set_color("font_color", "Label", StickTokens.TEXT)
	t.set_font_size("font_size", "Label", StickTokens.FONT_BODY)


static func _apply_panel(t: Theme) -> void:
	t.set_stylebox("panel", "Panel", StickStyle.window_panel())
	t.set_stylebox("panel", "PanelContainer", StickStyle.window_panel())


static func _apply_inputs(t: Theme) -> void:
	# LineEdit
	t.set_stylebox("normal", "LineEdit", StickStyle.groove())
	t.set_stylebox("focus", "LineEdit", _bordered(StickStyle.groove(), StickTokens.ACCENT))
	t.set_color("font_color", "LineEdit", StickTokens.TEXT)
	t.set_color("font_placeholder_color", "LineEdit", StickTokens.TEXT_FAINT)
	t.set_color("caret_color", "LineEdit", StickTokens.ACCENT)
	t.set_font_size("font_size", "LineEdit", StickTokens.FONT_BODY)
	# OptionButton（复用按钮族）
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		t.set_stylebox(state, "OptionButton", t.get_stylebox(state, "Button"))
	t.set_color("font_color", "OptionButton", StickTokens.TEXT)
	t.set_font_size("font_size", "OptionButton", StickTokens.FONT_BODY)
	# CheckBox / CheckButton：文字色即可（勾选图形用引擎默认，P1 换自绘图标）
	for type in ["CheckBox", "CheckButton"]:
		t.set_color("font_color", type, StickTokens.TEXT)
		t.set_color("font_disabled_color", type, StickTokens.TEXT_DISABLED)
		t.set_font_size("font_size", type, StickTokens.FONT_BODY)


static func _apply_slider(t: Theme) -> void:
	var grabber := StickStyle.progress_fill(StickTokens.ACCENT)
	grabber.content_margin_left = 4
	grabber.content_margin_right = 4
	t.set_stylebox("slider", "HSlider", StickStyle.groove())
	t.set_stylebox("grabber_area", "HSlider", grabber)
	t.set_stylebox("grabber_area_highlight", "HSlider", grabber)


static func _apply_progress(t: Theme) -> void:
	t.set_stylebox("background", "ProgressBar", StickStyle.progress_bg())
	t.set_stylebox("fill", "ProgressBar", StickStyle.progress_fill())
	t.set_color("font_color", "ProgressBar", StickTokens.TEXT)
	t.set_font_size("font_size", "ProgressBar", StickTokens.FONT_HINT)


static func _apply_tabs(t: Theme) -> void:
	t.set_stylebox("tab_selected", "TabContainer", StickStyle.tab_selected())
	t.set_stylebox("tab_hovered", "TabContainer", StickStyle.tab_hover())
	t.set_stylebox("tab_unselected", "TabContainer", StickStyle.tab_normal())
	t.set_stylebox("panel", "TabContainer", StickStyle.window_panel_light())
	t.set_color("font_selected_color", "TabContainer", StickTokens.ACCENT)
	t.set_color("font_unselected_color", "TabContainer", StickTokens.TEXT_DIM)
	t.set_color("font_hovered_color", "TabContainer", StickTokens.TEXT)
	t.set_font_size("font_size", "TabContainer", StickTokens.FONT_BODY)


static func _apply_list(t: Theme) -> void:
	t.set_stylebox("panel", "ItemList", StickStyle.window_panel_light())
	t.set_stylebox("selected", "ItemList", StickStyle.accent_normal())
	t.set_stylebox("selected_focus", "ItemList", StickStyle.accent_normal())
	t.set_stylebox("hovered", "ItemList", StickStyle.button_hover())
	t.set_color("font_color", "ItemList", StickTokens.TEXT)
	t.set_color("font_selected_color", "ItemList", StickTokens.ACCENT)
	t.set_font_size("font_size", "ItemList", StickTokens.FONT_BODY)


static func _apply_misc(t: Theme) -> void:
	t.set_stylebox("separator", "HSeparator", StickStyle.separator())
	t.set_stylebox("separator", "VSeparator", StickStyle.separator())
	t.set_stylebox("panel", "TooltipPanel", StickStyle.window_panel())
	t.set_color("font_color", "TooltipLabel", StickTokens.TEXT)
	t.set_font_size("font_size", "TooltipLabel", StickTokens.FONT_HINT)


# ─────────────────────────────── 内部 ────────────────────────────────

## 空焦点框（用描边态表达焦点，不要默认虚线框）
static func _empty_focus() -> StyleBoxEmpty:
	return StyleBoxEmpty.new()


static func _bordered(base: StyleBoxFlat, color: Color) -> StyleBoxFlat:
	var s := base.duplicate() as StyleBoxFlat
	s.border_color = color
	s.border_width_left = StickTokens.BORDER_W
	s.border_width_top = StickTokens.BORDER_W
	s.border_width_right = StickTokens.BORDER_W
	s.border_width_bottom = StickTokens.BORDER_W
	return s
