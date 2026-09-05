class_name SketchLineEdit
extends LineEdit
## 手绘涂鸦输入框 —— 凹槽底走 Flat stylebox（引擎画、文字之下），
## boiling 手绘描边由 _draw() 叠加，聚焦时描边琥珀。


var _seed: int = 0
var _timer: float = 0.0


func _ready() -> void:
	_seed = randi()
	var flat := StyleBoxFlat.new()
	flat.bg_color = StickTokens.GROOVE_BG
	flat.content_margin_left = StickTokens.PAD_X
	flat.content_margin_right = StickTokens.PAD_X
	flat.content_margin_top = StickTokens.PAD_Y
	flat.content_margin_bottom = StickTokens.PAD_Y
	add_theme_stylebox_override("normal", flat)
	add_theme_stylebox_override("focus", flat.duplicate())
	resized.connect(queue_redraw)
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_timer += delta
	if _timer >= SketchDraw.WOBBLE_INTERVAL:
		_timer = 0.0
		_seed = randi()
		queue_redraw()


func _draw() -> void:
	var border := Color(1, 1, 1, 0.05) if not has_focus() else StickTokens.ACCENT
	SketchDraw.draw_panel(self, Rect2(Vector2.ZERO, size), _seed,
			Color.TRANSPARENT, border, 1.3, 5.0)
