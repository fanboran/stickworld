class_name SketchGearButton
extends SketchButton
## 空白正方形手绘按钮（设置入口）：方底 + 沸腾方框描边，无任何图标。
## 方形走 SketchDraw.draw_panel 同款 wobbly 矩形——与其他 Sketch 按钮同语言。


func _ready() -> void:
	_seed = randi()
	custom_minimum_size = Vector2(31, 31)
	# 底与描边全自绘（禁用父类贴图四态）
	var states := ["normal", "hover", "pressed", "disabled", "focus"]
	for state in states:
		add_theme_stylebox_override(state, StyleBoxEmpty.new())
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
	var r := Rect2(Vector2.ZERO, size)
	var mode := get_draw_mode()
	# 底色（贴图配方的色值）
	var bg := Color(1, 1, 1, 0.07)
	var border := Color(1, 1, 1, 0.16)
	if mode == BaseButton.DRAW_HOVER:
		bg = Color(1, 1, 1, 0.10)
		border = Color(1, 1, 1, 0.30)
	elif mode == BaseButton.DRAW_PRESSED:
		bg = Color(1, 1, 1, 0.04)
		border = Color(StickTokens.ACCENT, 0.9)
	elif mode == BaseButton.DRAW_DISABLED:
		bg = Color(1, 1, 1, 0.03)
		border = Color.TRANSPARENT
	if ink.a > 0.0:
		# 亮背景：深墨描边
		border = Color(0.05, 0.04, 0.03, 1.0) if border.a > 0.0 else border
	# 方形底 + 沸腾方框描边（空白正方形，无图标）
	SketchDraw.draw_panel(self, r, _seed, bg, border)
