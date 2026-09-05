class_name SketchButton
extends Button
## 手绘涂鸦按钮 —— 底色走 Flat stylebox（引擎画、文字之下），
## boiling 手绘描边由 _draw() 叠加（血条同源算法，边缘区不碰文字）。
##
## 层级原理：native NOTIFICATION_DRAW 先画 stylebox 底 + 文字，
## 脚本 _draw() 后执行——只画边缘描边线（1.6px）就不会盖文字。
## hover 微缩放/音效/信号行为全部继承（与 StickKit.button 交互一致）。

enum Kind { NORMAL, ACCENT, DANGER }

@export var kind: Kind = Kind.NORMAL:
	set(v):
		kind = v
		_apply_flats()
		queue_redraw()
## 深墨描边（亮背景用，血条黑墨同思路）：非透明时覆盖常规白描边。
## 主菜单浮在暖金天空上的按钮用它，描边才醒目。
@export var ink := Color.TRANSPARENT

var _seed: int = 0
var _timer: float = 0.0


func _ready() -> void:
	_seed = randi()
	_apply_flats()
	resized.connect(queue_redraw)


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_timer += delta
	if _timer >= SketchDraw.WOBBLE_INTERVAL:
		_timer = 0.0
		_seed = randi()
		queue_redraw()


func _draw() -> void:
	var border := _border_for(get_draw_mode())
	if ink.a > 0.0 and border.a > 0.0:
		border = Color(ink.r, ink.g, ink.b, clampf(border.a * 3.0, ink.a * 0.8, 1.0))
	if border.a <= 0.0:
		return
	SketchDraw.draw_panel(self, Rect2(Vector2.ZERO, size), _seed,
			Color.TRANSPARENT, border, SketchDraw.OUTLINE_WIDTH, _corner_for(size))


## 四态底色 = 无描边 Flat（描边让位给 _draw 手绘线）
func _apply_flats() -> void:
	for state in ["normal", "hover", "pressed", "disabled"]:
		add_theme_stylebox_override(state, _flat(state, kind))
	add_theme_stylebox_override("focus", StyleBoxEmpty.new())


static func _flat(state: String, k: Kind) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = _skin_for(state, k)[0]
	s.content_margin_left = StickTokens.PAD_X + 2
	s.content_margin_right = StickTokens.PAD_X + 2
	s.content_margin_top = 2
	s.content_margin_bottom = 2
	return s


static func _border_for(mode: int) -> Color:
	if mode == BaseButton.DRAW_DISABLED:
		return Color.TRANSPARENT
	if mode == BaseButton.DRAW_HOVER:
		return StickTokens.BORDER_STRONG
	if mode == BaseButton.DRAW_PRESSED:
		return Color(StickTokens.ACCENT, 0.9)
	return StickTokens.BORDER


static func _skin_for(state: String, k: Kind) -> Array:
	var disabled: bool = state == "disabled"
	match k:
		Kind.ACCENT:
			if disabled:
				return [StickTokens.BTN_BG_DISABLED]
			if state == "hover":
				return [Color(StickTokens.ACCENT, 0.26)]
			if state == "pressed":
				return [Color(StickTokens.ACCENT, 0.08)]
			return [StickTokens.ACCENT_BG]
		Kind.DANGER:
			if disabled:
				return [StickTokens.BTN_BG_DISABLED]
			if state == "hover":
				return [Color(StickTokens.DANGER, 0.26)]
			if state == "pressed":
				return [Color(StickTokens.DANGER, 0.10)]
			return [StickTokens.DANGER_BG]
		_:
			if disabled:
				return [StickTokens.BTN_BG_DISABLED]
			if state == "hover":
				return [StickTokens.BTN_BG_HOVER]
			if state == "pressed":
				return [StickTokens.BTN_BG_PRESSED]
			return [StickTokens.BTN_BG]


## 圆角随高度缩放：矮按钮圆角小一点，保持"正常按钮"轮廓
func _corner_for(s: Vector2) -> float:
	return clampf(SketchDraw.CORNER_R * s.y / 34.0, 3.0, SketchDraw.CORNER_R)
