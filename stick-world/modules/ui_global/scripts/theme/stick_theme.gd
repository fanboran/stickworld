class_name StickTheme
extends RefCounted
## Theme 构建器 —— 把 StickTokens/StickStyle/GlassStyle + 手写字体打包成 Theme。
##
## 用法：
##   func _ready() -> void:
##       theme = StickTheme.create()                      # 游戏内：手绘涂鸦皮肤（默认）
##       theme = StickTheme.create(StickTheme.Mode.GLASS) # 主菜单/载入屏：玻璃窗原样
##
## 两种皮肤共用同一套 Flat 玻璃 StyleBox（GlassStyle，兜底未自绘控件）：
## - SKETCH：游戏内 —— StickHand 程序化手写字体；主视觉由自绘控件（SketchPanel/
##   SketchButton 等，血条同源沸腾）承担
## - GLASS：主菜单/载入屏 —— 引擎默认字体，完全原样
##
## 原生控件兜底的手绘感：CheckBox/CheckButton/OptionButton 的勾选框/拨动开关/
## 下拉箭头由 SketchIcons 生成定型扰动图标（boiling 版走 SketchCheckBox/
## SketchCheckButton/SketchOptionButton 控件类）；PopupMenu 弹出菜单走黑玻璃。
##
## 覆盖控件：Button / Label / Panel / PanelContainer / LineEdit / OptionButton /
## CheckBox / CheckButton / HSlider / ProgressBar / TabContainer / ItemList /
## HSeparator / VSeparator / TooltipPanel。

enum Mode { SKETCH, GLASS }


## 构建完整主题（每次调用新建实例，调用方持有）
static func create(skin_mode: int = Mode.SKETCH) -> Theme:
	var t := Theme.new()
	if skin_mode == Mode.SKETCH:
		var hand := SketchFonts.hand()
		if hand != null:
			t.default_font = hand
			t.default_font_size = StickTokens.FONT_BODY
			# default_font 兜底对部分控件（Button 等）不可靠——显式设字体
			for type in ["Button", "Label", "LineEdit", "OptionButton", "CheckBox",
					"CheckButton", "ProgressBar", "TabContainer", "ItemList", "TooltipLabel",
					"PopupMenu"]:
				t.set_font("font", type, hand)
	var s := SketchStyle if skin_mode == Mode.SKETCH else GlassStyle
	_apply_button(t, s, skin_mode)
	_apply_label(t)
	_apply_panel(t, s)
	_apply_inputs(t, s)
	_apply_slider(t, s)
	_apply_progress(t, s)
	_apply_tabs(t, s)
	_apply_list(t, s)
	_apply_misc(t, s)
	_apply_popup(t, s)
	return t


## 热切换：把新主题挂到根节点（整树生效）
static func refresh(root: Control, skin_mode: int = Mode.SKETCH) -> void:
	root.theme = create(skin_mode)


# ─────────────────────────────── 控件装配 ────────────────────────────────

static func _apply_button(t: Theme, s: Object, skin_mode: int = Mode.SKETCH) -> void:
	t.set_stylebox("normal", "Button", s.button_normal())
	t.set_stylebox("hover", "Button", s.button_hover())
	t.set_stylebox("pressed", "Button", s.button_pressed())
	t.set_stylebox("disabled", "Button", s.button_disabled())
	t.set_stylebox("focus", "Button", _empty_focus())
	t.set_color("font_color", "Button", StickTokens.TEXT)
	t.set_color("font_hover_color", "Button", StickTokens.TEXT)
	t.set_color("font_pressed_color", "Button", StickTokens.ACCENT)
	t.set_color("font_disabled_color", "Button", StickTokens.TEXT_DISABLED)
	t.set_font_size("font_size", "Button", StickTokens.FONT_HUD)


static func _apply_label(t: Theme) -> void:
	t.set_color("font_color", "Label", StickTokens.TEXT)
	t.set_font_size("font_size", "Label", StickTokens.FONT_BODY)


static func _apply_panel(t: Theme, s: Object) -> void:
	t.set_stylebox("panel", "Panel", s.window_panel())
	t.set_stylebox("panel", "PanelContainer", s.window_panel())


static func _apply_inputs(t: Theme, s: Object) -> void:
	# LineEdit
	t.set_stylebox("normal", "LineEdit", s.groove())
	if s == GlassStyle:
		var fb := (s.groove() as StyleBoxFlat).duplicate()
		fb.border_color = StickTokens.ACCENT
		fb.border_width_left = StickTokens.BORDER_W
		fb.border_width_top = StickTokens.BORDER_W
		fb.border_width_right = StickTokens.BORDER_W
		fb.border_width_bottom = StickTokens.BORDER_W
		t.set_stylebox("focus", "LineEdit", fb)
	else:
		t.set_stylebox("focus", "LineEdit", s.groove_focus())
	t.set_color("font_color", "LineEdit", StickTokens.TEXT)
	t.set_color("font_placeholder_color", "LineEdit", StickTokens.TEXT_FAINT)
	t.set_color("caret_color", "LineEdit", StickTokens.ACCENT)
	t.set_font_size("font_size", "LineEdit", StickTokens.FONT_BODY)
	# OptionButton（复用按钮族）
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		t.set_stylebox(state, "OptionButton", t.get_stylebox(state, "Button"))
	t.set_color("font_color", "OptionButton", StickTokens.TEXT)
	t.set_font_size("font_size", "OptionButton", StickTokens.FONT_BODY)
	# CheckBox / CheckButton：手绘兜底图标（定型扰动，boiling 版走 Sketch* 控件类）
	t.set_icon("checked", "CheckBox", SketchIcons.checkbox(true))
	t.set_icon("unchecked", "CheckBox", SketchIcons.checkbox(false))
	t.set_icon("checked_disabled", "CheckBox", SketchIcons.checkbox(true, true))
	t.set_icon("unchecked_disabled", "CheckBox", SketchIcons.checkbox(false, true))
	t.set_icon("checked", "CheckButton", SketchIcons.toggle(true))
	t.set_icon("unchecked", "CheckButton", SketchIcons.toggle(false))
	t.set_icon("checked_disabled", "CheckButton", SketchIcons.toggle(true, true))
	t.set_icon("unchecked_disabled", "CheckButton", SketchIcons.toggle(false, true))
	# OptionButton 下拉箭头：手绘 ∨
	t.set_icon("arrow", "OptionButton", SketchIcons.arrow())
	# 主题类型回退会沿基类链吃到 Button 的玻璃 stylebox（选中态变琥珀边框大胶囊），
	# 显式置空 = 回归"图标 + 文字"的原生布局
	for type in ["CheckBox", "CheckButton"]:
		for sb in ["normal", "hover", "pressed", "disabled", "focus"]:
			t.set_stylebox(sb, type, _empty_focus())
		t.set_color("font_color", type, StickTokens.TEXT)
		t.set_color("font_hover_color", type, StickTokens.TEXT)
		t.set_color("font_pressed_color", type, StickTokens.TEXT)
		t.set_color("font_hover_pressed_color", type, StickTokens.TEXT)
		t.set_color("font_disabled_color", type, StickTokens.TEXT_DISABLED)
		t.set_font_size("font_size", type, StickTokens.FONT_BODY)


static func _apply_slider(t: Theme, s: Object) -> void:
	var grabber: StyleBox = s.progress_fill()
	grabber.content_margin_left = 4
	grabber.content_margin_right = 4
	t.set_stylebox("slider", "HSlider", s.groove())
	t.set_stylebox("grabber_area", "HSlider", grabber)
	t.set_stylebox("grabber_area_highlight", "HSlider", grabber)


static func _apply_progress(t: Theme, s: Object) -> void:
	t.set_stylebox("background", "ProgressBar", s.progress_bg())
	t.set_stylebox("fill", "ProgressBar", s.progress_fill())
	t.set_color("font_color", "ProgressBar", StickTokens.TEXT)
	t.set_font_size("font_size", "ProgressBar", StickTokens.FONT_HINT)


static func _apply_tabs(t: Theme, s: Object) -> void:
	t.set_stylebox("tab_selected", "TabContainer", s.tab_selected())
	t.set_stylebox("tab_hovered", "TabContainer", s.tab_hover())
	t.set_stylebox("tab_unselected", "TabContainer", s.tab_normal())
	t.set_stylebox("panel", "TabContainer", s.window_panel_light())
	t.set_stylebox("tab_focus", "TabContainer", _empty_focus())
	t.set_color("font_selected_color", "TabContainer", StickTokens.TEXT)
	t.set_color("font_unselected_color", "TabContainer", StickTokens.TEXT_DIM)
	t.set_color("font_hovered_color", "TabContainer", StickTokens.TEXT)
	t.set_font_size("font_size", "TabContainer", StickTokens.FONT_BODY)


static func _apply_list(t: Theme, s: Object) -> void:
	t.set_stylebox("panel", "ItemList", s.window_panel_light())
	t.set_stylebox("selected", "ItemList", s.accent_normal())
	t.set_stylebox("selected_focus", "ItemList", s.accent_normal())
	t.set_stylebox("hovered", "ItemList", s.button_hover())
	t.set_color("font_color", "ItemList", StickTokens.TEXT)
	t.set_color("font_selected_color", "ItemList", StickTokens.ACCENT)
	t.set_font_size("font_size", "ItemList", StickTokens.FONT_BODY)


static func _apply_misc(t: Theme, s: Object) -> void:
	t.set_stylebox("separator", "HSeparator", s.separator())
	t.set_stylebox("separator", "VSeparator", s.vseparator())
	t.set_stylebox("panel", "TooltipPanel", s.window_panel())
	t.set_color("font_color", "TooltipLabel", StickTokens.TEXT)
	t.set_font_size("font_size", "TooltipLabel", StickTokens.FONT_HINT)


## 弹出菜单（OptionButton 下拉等）：黑玻璃窗 + 低对比悬停（不走使用点，全局兜底）
static func _apply_popup(t: Theme, s: Object) -> void:
	t.set_stylebox("panel", "PopupMenu", s.menu_panel())
	t.set_stylebox("hover", "PopupMenu", s.menu_hover())
	t.set_stylebox("separator", "PopupMenu", s.separator())
	t.set_color("font_color", "PopupMenu", StickTokens.TEXT)
	t.set_color("font_hover_color", "PopupMenu", StickTokens.TEXT)
	t.set_color("font_disabled_color", "PopupMenu", StickTokens.TEXT_DISABLED)
	t.set_color("font_separator_color", "PopupMenu", StickTokens.TEXT_FAINT)
	t.set_color("font_accelerator_color", "PopupMenu", StickTokens.TEXT_DIM)
	t.set_font_size("font_size", "PopupMenu", StickTokens.FONT_BODY)


# ─────────────────────────────── 内部 ────────────────────────────────

## 空焦点框（用描边态表达焦点，不要默认虚线框）
static func _empty_focus() -> StyleBoxEmpty:
	return StyleBoxEmpty.new()
