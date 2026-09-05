class_name SketchCheckButton
extends CheckButton
## 手绘涂鸦拨动开关 —— 手绘凹槽 + 圆钮，全部 _draw 自绘（血条同源 boiling）。
##
## 画法承 SketchHSlider：凹槽 = wobble 胶囊（draw_panel 半径拉满），
## 圆钮 = 14 段 wobble 圆 + 深墨描边（血条 COLOR_OUTLINE 同源墨色）。
## 开：琥珀凹槽底 + 琥珀描边，圆钮右移（§1.2 选中态琥珀只上底不上字）；
## 关：白描边凹槽 + 白圆钮。

## 凹槽尺寸（px）
const GROOVE := Vector2(34.0, 18.0)
## 圆钮半径（px）
const KNOB_R := 6.5


var _seed: int = 0
var _timer: float = 0.0


func _ready() -> void:
	_seed = randi()
	# 引擎图标全部置空：凹槽与圆钮交给 _draw。图标用足尺寸透明纹理占住图标槽
	# （最小宽 = 图标宽 + h_separation，1px 空纹理会让控件塌成 1px 宽被裁剪容器剪没）
	for icon_name in ["checked", "unchecked", "checked_disabled", "unchecked_disabled",
			"checked_mirrored", "unchecked_mirrored",
			"checked_disabled_mirrored", "unchecked_disabled_mirrored"]:
		add_theme_icon_override(icon_name, SketchDraw.blank_texture(
				Vector2i(int(GROOVE.x), int(GROOVE.y))))
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
	# 凹槽画在图标槽内（无文字时控件最小宽 = 槽宽，向内留 1px 防裁剪容器切边）
	var rect := Rect2(1.0, (size.y - GROOVE.y) * 0.5, GROOVE.x - 2.0, GROOVE.y)
	var dim := 0.4 if is_disabled() else 1.0
	var hovered := is_hovered() and not is_disabled()
	var t := 1.0 if button_pressed else 0.0
	var fill := Color(StickTokens.ACCENT, 0.14 * dim) if button_pressed else Color.TRANSPARENT
	var outline: Color
	if button_pressed:
		outline = Color(StickTokens.ACCENT, 0.95 * dim)
	elif hovered:
		outline = StickTokens.BORDER_STRONG
	else:
		outline = Color(StickTokens.TEXT.r, StickTokens.TEXT.g, StickTokens.TEXT.b, 0.32 * dim)
	# 凹槽：wobble 胶囊（圆角拉到半高）
	SketchDraw.draw_panel(self, rect, _seed, fill, outline, 1.4, GROOVE.y * 0.5)
	# 圆钮：wobble 圆，off 左 / on 右，各留 2px 内边
	var cx: float = lerpf(rect.position.x + KNOB_R + 2.0,
			rect.end.x - KNOB_R - 2.0, t)
	_draw_knob(Vector2(cx, rect.position.y + GROOVE.y * 0.5), KNOB_R, dim)


## 手绘圆钮：白实心 + 深墨描边；开启态转琥珀（§1.2 选中态）
func _draw_knob(center: Vector2, radius: float, dim: float) -> void:
	var pts := PackedVector2Array()
	var seg := 14
	for i in seg:
		var a := TAU * float(i) / float(seg)
		var rr := radius + SketchDraw.wobble(i * 3, _seed + 31) * SketchDraw.WOBBLE_AMP
		pts.append(center + Vector2(cos(a), sin(a)) * rr)
	var fill := Color(StickTokens.ACCENT, dim) if button_pressed \
			else Color(StickTokens.TEXT.r, StickTokens.TEXT.g, StickTokens.TEXT.b, dim)
	var outline := Color(0.05, 0.04, 0.03, 0.95 * dim)  # 血条 COLOR_OUTLINE 同源墨色
	draw_colored_polygon(pts, fill)
	var loop := pts.duplicate()
	loop.append(pts[0])
	draw_polyline(loop, outline, SketchDraw.OUTLINE_WIDTH, true)
