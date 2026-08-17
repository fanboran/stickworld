class_name StickKit
extends RefCounted
## 组件装配工厂 —— 模板共用的小型控件生产线。
##
## 设计：界面骨架放 .tscn（锚定布局），内容用本工厂按数据装配（加一项 = 加一行数据）。
## 所有控件从 StickTokens 取样式，不手写字面量颜色/字号。
##
## 用法：
##   var section := StickKit.section(content_vbox, "按钮族")
##   StickKit.button(section, "普通按钮", _on_pressed)
##   StickKit.label(section, "说明文字", StickKit.LabelKind.HINT)


## 标签档位
enum LabelKind { TITLE, SECTION, BODY, HINT, TINY }

## 按钮档位（视觉变体）
enum ButtonKind { NORMAL, ACCENT, DANGER }


# ─────────────────────────────── 标签 ────────────────────────────────

static func label(parent: Control, text: String, kind: LabelKind = LabelKind.BODY,
		color: Color = Color.TRANSPARENT) -> Label:
	var l := Label.new()
	l.text = text
	match kind:
		LabelKind.TITLE:
			l.add_theme_font_size_override("font_size", StickTokens.FONT_TITLE)
		LabelKind.SECTION:
			l.add_theme_font_size_override("font_size", StickTokens.FONT_SECTION)
			l.modulate = StickTokens.ACCENT if color == Color.TRANSPARENT else color
		LabelKind.BODY:
			l.add_theme_font_size_override("font_size", StickTokens.FONT_BODY)
		LabelKind.HINT:
			l.add_theme_font_size_override("font_size", StickTokens.FONT_HINT)
			l.modulate = StickTokens.TEXT_DIM if color == Color.TRANSPARENT else color
		LabelKind.TINY:
			l.add_theme_font_size_override("font_size", StickTokens.FONT_TINY)
			l.modulate = StickTokens.TEXT_DIM if color == Color.TRANSPARENT else color
	if color != Color.TRANSPARENT and kind != LabelKind.SECTION \
			and kind != LabelKind.HINT and kind != LabelKind.TINY:
		l.modulate = color
	parent.add_child(l)
	return l


# ─────────────────────────────── 按钮 ────────────────────────────────

static func button(parent: Control, text: String, callback: Callable = Callable(),
		kind: ButtonKind = ButtonKind.NORMAL, height: float = StickTokens.BTN_H) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, height)
	match kind:
		ButtonKind.ACCENT:
			b.add_theme_stylebox_override("normal", StickStyle.accent_normal())
			b.add_theme_stylebox_override("hover", StickStyle.accent_hover())
			b.add_theme_stylebox_override("pressed", StickStyle.accent_pressed())
			b.add_theme_color_override("font_color", StickTokens.ACCENT)
		ButtonKind.DANGER:
			b.add_theme_stylebox_override("normal", StickStyle.danger_normal())
			b.add_theme_stylebox_override("hover", StickStyle.danger_hover())
			b.add_theme_color_override("font_color", StickTokens.DANGER)
	if callback.is_valid():
		b.pressed.connect(callback)
	parent.add_child(b)
	return b


# ─────────────────────────────── 区块 ────────────────────────────────

## 带小标题的 VBox 区块（面板内分节）
static func section(parent: Control, title: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	label(box, title, LabelKind.SECTION)
	parent.add_child(box)
	return box


## 横向行容器
static func row(parent: Control, separation: int = 8) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", separation)
	parent.add_child(h)
	return h


static func separator(parent: Control) -> void:
	parent.add_child(HSeparator.new())


# ─────────────────────────────── 键值行 ────────────────────────────────

## 左标签右控件的设置行（返回右侧容器供放控件）
static func field_row(parent: Control, name_text: String, hint_text: String = "") -> HBoxContainer:
	var h := row(parent, 12)
	h.custom_minimum_size = Vector2(0, StickTokens.ROW_H)
	var l := label(h, name_text, LabelKind.BODY)
	l.custom_minimum_size = Vector2(160, 0)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if hint_text != "":
		var hint := label(h, hint_text, LabelKind.HINT)
		hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return h


# ─────────────────────────────── 布局约束（摆放 UI 的唯一正确姿势）────────────────────────────────

## 屏幕四角
enum Corner { TOP_LEFT, TOP_RIGHT, BOTTOM_LEFT, BOTTOM_RIGHT }

## 把面板居中到父节点中央（anchor 方案，不手写 viewport 计算，不受窗口尺寸影响）。
## 要求父节点是全屏容器（FULL_RECT）。固定尺寸居中：
static func center_on_screen(panel: Control, size: Vector2) -> void:
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.offset_left = -size.x * 0.5
	panel.offset_right = size.x * 0.5
	panel.offset_top = -size.y * 0.5
	panel.offset_bottom = size.y * 0.5


## 把控件停靠到屏幕某角，自动留 SCREEN_MARGIN 安全边距（禁止贴边）。
## 要求父节点是全屏容器（FULL_RECT）。
static func dock(node: Control, corner: Corner, size: Vector2,
		margin: float = StickTokens.SCREEN_MARGIN) -> void:
	match corner:
		Corner.TOP_LEFT:
			node.set_anchors_preset(Control.PRESET_TOP_LEFT)
			node.offset_left = margin
			node.offset_top = margin
			node.offset_right = margin + size.x
			node.offset_bottom = margin + size.y
		Corner.TOP_RIGHT:
			node.set_anchors_preset(Control.PRESET_TOP_RIGHT)
			node.offset_left = -margin - size.x
			node.offset_top = margin
			node.offset_right = -margin
			node.offset_bottom = margin + size.y
		Corner.BOTTOM_LEFT:
			node.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
			node.offset_left = margin
			node.offset_top = -margin - size.y
			node.offset_right = margin + size.x
			node.offset_bottom = -margin
		Corner.BOTTOM_RIGHT:
			node.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
			node.offset_left = -margin - size.x
			node.offset_top = -margin - size.y
			node.offset_right = -margin
			node.offset_bottom = -margin
	node.custom_minimum_size = size


# ─────────────────────────────── Toast ────────────────────────────────

## 在指定层弹一条 toast（自动淡出销毁）。anchor 底部居中。
static func toast(layer: Control, text: String, kind: String = "info") -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", StickStyle.window_panel())
	var l := label(panel, text, LabelKind.BODY,
			StickTokens.INFO if kind == "info" else (StickTokens.WARN if kind == "warn" else StickTokens.DANGER))
	l.add_theme_font_size_override("font_size", StickTokens.FONT_BODY)
	layer.add_child(panel)
	panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	panel.position = Vector2(-panel.size.x * 0.5, -80)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	# 出场在下帧按实际尺寸校正水平居中
	panel.resized.connect(func():
		if is_instance_valid(panel):
			panel.position.x = -panel.size.x * 0.5
	)
	var tween := panel.create_tween()
	tween.tween_interval(StickTokens.T_TOAST)
	tween.tween_property(panel, "modulate:a", 0.0, StickTokens.T_PANEL * 2)
	tween.tween_callback(panel.queue_free)


# ─────────────────────────────── 确认框 ────────────────────────────────

## 模态确认框（确认框族最小实现）：message + 确定/取消。
## on_confirm 在点确定后调用；点遮罩/取消关闭。
static func confirm(layer: Control, title: String, message: String,
		on_confirm: Callable, confirm_text: String = "确定",
		kind: ButtonKind = ButtonKind.ACCENT) -> void:
	var dim := ColorRect.new()
	dim.color = StickTokens.MODAL_DIM
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	layer.add_child(dim)
	var window := PanelContainer.new()
	window.add_theme_stylebox_override("panel", StickStyle.window_panel())
	window.custom_minimum_size = Vector2(360, 0)
	dim.add_child(window)
	# 确定性居中（anchor + 半尺寸 offset，不依赖时序）
	window.set_anchors_preset(Control.PRESET_CENTER)
	window.grow_horizontal = Control.GROW_DIRECTION_BOTH
	window.grow_vertical = Control.GROW_DIRECTION_BOTH
	window.resized.connect(func():
		if is_instance_valid(window):
			window.position = -window.size * 0.5
	)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	window.add_child(box)
	label(box, title, LabelKind.SECTION)
	var msg := label(box, message, LabelKind.BODY)
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var btn_row := row(box, 8)
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	var close := func():
		if is_instance_valid(dim):
			dim.queue_free()
	button(btn_row, "取消", close)
	button(btn_row, confirm_text, func():
		close.call()
		if on_confirm.is_valid():
			on_confirm.call()
	, kind)
