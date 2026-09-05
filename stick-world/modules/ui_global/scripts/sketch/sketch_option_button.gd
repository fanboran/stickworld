class_name SketchOptionButton
extends OptionButton
## 手绘涂鸦下拉框 —— 底色走无描边 Flat（引擎画、文字之下），
## boiling 描边 + 手绘箭头由 _draw() 叠加（SketchButton 同款分层）。
##
## 层级原理：native NOTIFICATION_DRAW 先画 stylebox 底 + 文字，
## 脚本 _draw() 后执行——只画边缘描边线与右侧箭头，不碰文字。
## 下拉菜单本体（PopupMenu）由 StickTheme 统一上玻璃窗皮肤。

## 箭头区预留宽（px）：右侧 content_margin 额外让出的空间
const ARROW_RESERVE := 14.0

## 下拉弹窗兜底主题（无祖先主题时的退路，shared 避免每次开菜单重建）
static var _popup_theme_fallback: Theme = null


var _seed: int = 0
var _timer: float = 0.0


func _ready() -> void:
	_seed = randi()
	_apply_flats()
	# 引擎箭头图标置空：∨ 由 _draw 手绘
	add_theme_icon_override("arrow", SketchDraw.empty_texture())
	# PopupMenu 是 Window，不吃 Control 树的主题继承——弹出前显式挂同款皮肤
	pressed.connect(_sync_popup_theme)
	_sync_popup_theme()
	resized.connect(queue_redraw)


## 把祖先树上的 Theme 资源挂到下拉弹窗（无祖先主题时退回 StickTheme 兜底）
func _sync_popup_theme() -> void:
	var pm := get_popup()
	if pm == null or pm.theme != null:
		return
	var n: Node = self
	while n != null:
		if n is Control and (n as Control).theme != null:
			pm.theme = (n as Control).theme
			return
		if n is Window and (n as Window).theme != null:
			pm.theme = (n as Window).theme
			return
		n = n.get_parent()
	if _popup_theme_fallback == null:
		_popup_theme_fallback = StickTheme.create()
	pm.theme = _popup_theme_fallback


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	# boiling：与血条/面板同节拍重掷相位
	_timer += delta
	if _timer >= SketchDraw.WOBBLE_INTERVAL:
		_timer = 0.0
		_seed = randi()
		queue_redraw()


func _draw() -> void:
	var border := _border_for(get_draw_mode())
	if border.a > 0.0:
		SketchDraw.draw_panel(self, Rect2(Vector2.ZERO, size), _seed,
				Color.TRANSPARENT, border, SketchDraw.OUTLINE_WIDTH, _corner_for(size))
	_draw_arrow()


## 四态底色 = 无描边 Flat（描边让位给 _draw 手绘线），右侧让出箭头区
func _apply_flats() -> void:
	for state in ["normal", "hover", "pressed", "disabled"]:
		add_theme_stylebox_override(state, _flat(state))
	add_theme_stylebox_override("focus", StyleBoxEmpty.new())


static func _flat(state: String) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	match state:
		"hover":
			s.bg_color = StickTokens.BTN_BG_HOVER
		"pressed":
			s.bg_color = StickTokens.BTN_BG_PRESSED
		"disabled":
			s.bg_color = StickTokens.BTN_BG_DISABLED
		_:
			s.bg_color = StickTokens.BTN_BG
	s.content_margin_left = StickTokens.PAD_X + 2
	s.content_margin_right = StickTokens.PAD_X + 2 + ARROW_RESERVE
	s.content_margin_top = 2
	s.content_margin_bottom = 2
	return s


static func _border_for(mode: int) -> Color:
	if mode == BaseButton.DRAW_DISABLED:
		return Color.TRANSPARENT
	if mode == BaseButton.DRAW_HOVER or mode == BaseButton.DRAW_HOVER_PRESSED:
		return StickTokens.BORDER_STRONG
	if mode == BaseButton.DRAW_PRESSED:
		return Color(StickTokens.ACCENT, 0.9)
	return StickTokens.BORDER


## 手绘箭头：右侧竖直居中的 ∨（两段折线，逐点小幅扰动），马克笔收笔感
func _draw_arrow() -> void:
	var dim := 0.4 if is_disabled() else 1.0
	var color := StickTokens.TEXT if (is_hovered() and not is_disabled()) \
			else StickTokens.TEXT_DIM
	color = Color(color.r, color.g, color.b, color.a * dim)
	var ax: float = size.x - ARROW_RESERVE * 0.5 - 1.0
	var ay: float = size.y * 0.5
	var pts := PackedVector2Array()
	for i in 3:
		var t := float(i) / 2.0
		var p := Vector2(lerpf(ax - 3.5, ax + 3.5, t),
				lerpf(ay - 2.0, ay + 2.0, t))
		if i == 1:
			p.y = ay + 2.6
		p += Vector2(SketchDraw.wobble(i * 7, _seed), SketchDraw.wobble(i * 7 + 1, _seed)) * 0.7
		pts.append(p)
	draw_polyline(pts, color, 1.6, true)


## 圆角随高度缩放：与 SketchButton 同款轮廓纪律
func _corner_for(s: Vector2) -> float:
	return clampf(SketchDraw.CORNER_R * s.y / 34.0, 3.0, SketchDraw.CORNER_R)
