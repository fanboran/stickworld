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
	_setup_button(b, callback, kind)
	parent.add_child(b)
	return b


## 手绘按钮（游戏内默认）：boiling 自绘四态底，交互行为与 button() 完全一致
static func sketch_button(parent: Control, text: String, callback: Callable = Callable(),
		kind: ButtonKind = ButtonKind.NORMAL, height: float = StickTokens.BTN_H) -> SketchButton:
	var b := SketchButton.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, height)
	_setup_button(b, callback, kind)
	parent.add_child(b)
	return b


## 按钮公共装配：点击音 + kind 文字色 + hover 微缩放
static func _setup_button(b: Button, callback: Callable, kind: ButtonKind) -> void:
	# 统一 UI 点击音（AudioManager 框架先行，资产未就位时静默跳过）
	b.pressed.connect(func() -> void:
		if AudioManager and AudioManager.has_method("play_event"):
			AudioManager.play_event("ui_click"))
	match kind:
		ButtonKind.ACCENT:
			# Flat override：对原生 Button 生效；SketchButton 在 _ready 用 Empty 覆盖后自绘
			b.add_theme_stylebox_override("normal", StickStyle.accent_normal())
			b.add_theme_stylebox_override("hover", StickStyle.accent_hover())
			b.add_theme_stylebox_override("pressed", StickStyle.accent_pressed())
			# 强调按钮字：白 + 伪粗（区分靠琥珀底，不靠字色）
			b.add_theme_color_override("font_color", StickTokens.TEXT)
			var bold := SketchFonts.bold()
			if bold != null:
				b.add_theme_font_override("font", bold)
		ButtonKind.DANGER:
			b.add_theme_stylebox_override("normal", StickStyle.danger_normal())
			b.add_theme_stylebox_override("hover", StickStyle.danger_hover())
			b.add_theme_color_override("font_color", StickTokens.DANGER)
	if callback.is_valid():
		b.pressed.connect(callback)
	# hover 微缩放（精致细节：按钮"浮起"感；pivot 居中避免缩放偏移）
	b.pivot_offset = Vector2(0, b.custom_minimum_size.y * 0.5)
	b.mouse_entered.connect(func() -> void:
		if AudioManager and AudioManager.has_method("play_event"):
			AudioManager.play_event("ui_hover")
		var tw := b.create_tween()
		tw.tween_property(b, "scale", Vector2(1.03, 1.03), 0.08))
	b.mouse_exited.connect(func() -> void:
		var tw := b.create_tween()
		tw.tween_property(b, "scale", Vector2.ONE, 0.1))


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


## 竖直分隔线（横向 HUD 行内分节用，替代旧 PanelKit.add_separator）
static func vseparator(parent: Control) -> void:
	parent.add_child(VSeparator.new())


## 水平分隔线：手绘波浪线
static func separator(parent: Control) -> void:
	var sep := SketchSeparator.new()
	sep.direction = SketchSeparator.Dir.HORIZONTAL
	parent.add_child(sep)


# ─────────────────────────────── 皮肤路由 ────────────────────────────────
# 手绘涂鸦是全局唯一皮肤（主菜单与游戏内统一）；auto_* 是历史名保留的别名。
# 玻璃样式（GlassStyle）仅存于 theme 兜底与对照陈列。

## 面板：直出手绘 SketchPanel（DARK/LIGHT）
static func panel(parent: Control, tone: int = 0) -> PanelContainer:
	var p := SketchPanel.new()
	p.tone = tone
	parent.add_child(p)
	return p


## 按钮：直出手绘 SketchButton（auto_button 为旧调用名保留）
static func auto_button(parent: Control, text: String, callback: Callable = Callable(),
		kind: ButtonKind = ButtonKind.NORMAL, height: float = StickTokens.BTN_H) -> Button:
	return sketch_button(parent, text, callback, kind, height)


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
static func dock(node: Control, corner: int, size: Vector2,
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


# ─────────────────────────────── HUD 预留区与安全矩形（防 UI 重合）────────────────────────────────

## HUD 预留区高度 —— 单一真相源，弹窗/浮动窗口定位必须避让（行业惯例：常驻 HUD 占位）。
## 顶栏 GlobalHUD 高 60（global_hud.tscn offset_bottom=60）+ 材料横条 y=64~99
const HUD_TOP_RESERVED := 104.0
## 底部模式面板 ModePanel 高 80（mode_panel.tscn offset_top=-80，含留白）
const HUD_BOTTOM_RESERVED := 88.0

## 计算"安全矩形"：viewport 减去 HUD 预留区（顶栏+材料条 / 底部面板）。
## 弹窗初始定位、浮动窗口开窗都必须把自身矩形夹进安全矩形——
## 一劳永逸防"弹窗盖住常驻 HUD 按钮"（如材料条与顶栏按钮重叠的历史问题）。
static func safe_rect(control: Control, margin: float = StickTokens.SCREEN_MARGIN) -> Rect2:
	var vp := Rect2(0, 0, 1920, 1080)
	if control != null and control.get_viewport() != null:
		vp = control.get_viewport().get_visible_rect()
	var pos := vp.position + Vector2(margin, HUD_TOP_RESERVED)
	var size := vp.size - Vector2(margin * 2.0, HUD_TOP_RESERVED + HUD_BOTTOM_RESERVED)
	return Rect2(pos, size)


## 把期望矩形夹进安全矩形（保持尺寸，只平移；过大的窗口缩到安全区大小）。
static func clamp_to_safe_rect(control: Control, desired: Rect2, margin: float = StickTokens.SCREEN_MARGIN) -> Rect2:
	var safe := safe_rect(control, margin)
	var size := Vector2(minf(desired.size.x, safe.size.x), minf(desired.size.y, safe.size.y))
	var pos := desired.position
	pos.x = clampf(pos.x, safe.position.x, maxf(safe.position.x, safe.end.x - size.x))
	pos.y = clampf(pos.y, safe.position.y, maxf(safe.position.y, safe.end.y - size.y))
	return Rect2(pos, size)


# ─────────────────────────────── Toast ────────────────────────────────

## 系统层（toast/确认框统一挂载，不随调用者层，根治"confirm 跑出屏幕"类问题）：
## 找 UIRoot.SystemOverlay（z=90，模态之上）；无 UIRoot（如主菜单场景）回退调用者层。
static func _system_overlay(layer: Control) -> Control:
	var tree := layer.get_tree()
	if tree != null:
		var root: CanvasLayer = tree.get_first_node_in_group("ui_root")
		if root != null:
			var slot := root.get_node_or_null("SystemOverlay") as Control
			if slot != null:
				return slot
	return layer


## 在指定层弹一条 toast（自动淡出销毁）。底部居中。
static func toast(layer: Control, text: String, kind: String = "info") -> void:
	layer = _system_overlay(layer)
	var panel := panel(layer, SketchPanel.Tone.DARK)
	var l := label(panel, text, LabelKind.BODY,
			StickTokens.INFO if kind == "info" else (StickTokens.WARN if kind == "warn" else StickTokens.DANGER))
	l.add_theme_font_size_override("font_size", StickTokens.FONT_BODY)
	layer.add_child(panel)
	_toast_apply_width_limit(panel, l, text, layer)
	# 绝对定位（anchor 归零），底部居中、离底 80px；不混用 anchor 与 position setter
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.resized.connect(func():
		if is_instance_valid(panel) and is_instance_valid(layer):
			panel.position = Vector2((layer.size.x - panel.size.x) * 0.5,
					layer.size.y - panel.size.y - 80.0)
	)
	var tween := panel.create_tween()
	tween.tween_interval(StickTokens.T_TOAST)
	tween.tween_property(panel, "modulate:a", 0.0, StickTokens.T_PANEL * 2)
	tween.tween_callback(panel.queue_free)


## toast 宽度约束：文本单行宽度超出屏幕安全区时开启自动换行并钳制标签宽，
## 防止长文本把面板顶出屏幕左右边缘（参照《药剂工艺》Tooltip 的 marginFromScreenEdge）。
static func _toast_apply_width_limit(panel: PanelContainer, l: Label, text: String, layer: Control) -> void:
	var max_w := layer.size.x - StickTokens.SCREEN_MARGIN * 2.0
	if max_w <= 0.0:
		return
	var font := l.get_theme_font(&"font")
	if font == null:
		return
	var text_w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, StickTokens.FONT_BODY).x
	var sb := panel.get_theme_stylebox(&"panel")
	var inset := 24.0
	if sb != null:
		inset = maxf(24.0, sb.get_margin(SIDE_LEFT) + sb.get_margin(SIDE_RIGHT))
	if text_w > max_w - inset:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = max_w - inset


# ─────────────────────────────── 确认框 ────────────────────────────────

## 模态确认框（确认框族最小实现）：message + 确定/取消。
## on_confirm 在点确定后调用；点遮罩/取消关闭。
## 游戏内入 UIModalStack CONFIRM 层（ESC = 取消，逐层退栈）；无 UIRoot 环境
## （主菜单）回退自管理。
static func confirm(layer: Control, title: String, message: String,
		on_confirm: Callable, confirm_text: String = "确定",
		kind: ButtonKind = ButtonKind.ACCENT) -> void:
	var host := _system_overlay(layer)
	var dialog := StickConfirmDialog.new()
	dialog.setup(title, message, on_confirm, confirm_text, kind)
	host.add_child(dialog)
	var stack := UIModalStack.find(layer)
	if stack != null:
		stack.push(dialog, UIModalStack.Layer.CONFIRM)
	else:
		dialog.open()
