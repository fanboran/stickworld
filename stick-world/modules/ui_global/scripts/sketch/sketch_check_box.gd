class_name SketchCheckBox
extends CheckBox
## 手绘涂鸦复选框 —— wobble 方框 + 马克笔对勾，全部 _draw 自绘（血条同源 boiling）。
##
## 引擎勾选图标置空，方框由 _draw 全权接管（SketchHSlider 置空 grabber 同款思路）。
## 选中态琥珀只上底不上字（§1.5）：琥珀描边 + 琥珀 14% 底，对勾用白。
## 图标槽位（icon + h_separation）让位给自绘方框，文字起排位置与原生一致。

## 自绘方框边长（px）
const BOX := 16.0


var _seed: int = 0
var _timer: float = 0.0


func _ready() -> void:
	_seed = randi()
	# 引擎图标全部置空：方框交给 _draw。图标用足尺寸透明纹理占住图标槽
	# （最小宽 = 图标宽 + h_separation，1px 空纹理会让控件塌成 1px 宽被裁剪容器剪没）
	for icon_name in ["checked", "unchecked", "checked_disabled", "unchecked_disabled",
			"radio_checked", "radio_unchecked", "radio_checked_disabled", "radio_unchecked_disabled"]:
		add_theme_icon_override(icon_name, SketchDraw.blank_texture(Vector2i(int(BOX), int(BOX))))
	add_theme_constant_override("h_separation", 6)
	toggled.connect(func(_on: bool) -> void: queue_redraw())
	resized.connect(queue_redraw)


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
	# 方框画在图标槽内（无文字时控件最小宽 = 槽宽，向内留 0.5px 防裁剪容器切边）
	var rect := Rect2(0.5, (size.y - BOX) * 0.5 + 0.5, BOX - 1.0, BOX - 1.0)
	var dim := 0.4 if is_disabled() else 1.0
	var hovered := is_hovered() and not is_disabled()
	var fill := Color.TRANSPARENT
	var outline: Color
	if button_pressed:
		fill = Color(StickTokens.ACCENT, 0.14 * dim)
		outline = Color(StickTokens.ACCENT, 0.95 * dim)
	elif hovered:
		outline = StickTokens.BORDER_STRONG
	else:
		outline = Color(StickTokens.TEXT.r, StickTokens.TEXT.g, StickTokens.TEXT.b, 0.32 * dim)
	SketchDraw.draw_panel(self, rect, _seed, fill, outline, 1.4, 4.0)
	# 对勾：三折点马克笔笔画（白），逐点小幅扰动
	if button_pressed:
		var ink := Color(StickTokens.TEXT.r, StickTokens.TEXT.g, StickTokens.TEXT.b, dim)
		var pts := PackedVector2Array()
		for i in 3:
			var t := float(i) / 2.0
			var p := Vector2(
					rect.position.x + lerpf(BOX * 0.22, BOX * 0.78, t),
					rect.position.y + lerpf(BOX * 0.55, BOX * 0.25, t))
			if i == 1:
				p.y = rect.position.y + BOX * 0.74
			p += Vector2(SketchDraw.wobble(i * 3, _seed), SketchDraw.wobble(i * 3 + 1, _seed)) * 0.8
			pts.append(p)
		draw_polyline(pts, ink, 2.2, true)
