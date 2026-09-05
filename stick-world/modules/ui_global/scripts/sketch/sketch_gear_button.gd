class_name SketchGearButton
extends SketchButton
## 正圆形手绘齿轮图标按钮（设置入口）。无文字，纯图标 + 沸腾描边。

## 齿轮颜色（默认随文字色：普通白 / ink 模式黑）
@export var gear_color := Color.TRANSPARENT


func _ready() -> void:
	super._ready()  # 基类已连 resized→queue_redraw，不重复
	# 正圆：宽高一致由 custom_minimum_size 保证（36x36）
	custom_minimum_size = Vector2(36, 36)


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	var mode := get_draw_mode()
	var border := _border_for(mode)
	if ink.a > 0.0 and border.a > 0.0:
		border = Color(ink.r, ink.g, ink.b, clampf(border.a * 3.0, ink.a * 0.8, 1.0))
	# 圆形沸腾描边（不走基类的圆角矩形）
	if border.a > 0.0:
		var center := r.size * 0.5
		var radius: float = minf(r.size.x, r.size.y) * 0.5 - 1.5
		var pts := PackedVector2Array()
		var seg := 18
		for i in seg:
			var a: float = TAU * float(i) / float(seg)
			var rr: float = radius + SketchDraw.wobble(i * 3, _seed) * SketchDraw.WOBBLE_AMP
			pts.append(center + Vector2(cos(a), sin(a)) * rr)
		var loop := pts.duplicate()
		loop.append(pts[0])
		draw_polyline(loop, border, SketchDraw.OUTLINE_WIDTH, true)
	# 齿轮图标
	var gear := gear_color
	if gear == Color.TRANSPARENT:
		gear = Color(0.05, 0.04, 0.03, 0.95) if ink.a > 0.0 else StickTokens.TEXT
	var state := "normal"
	if mode == BaseButton.DRAW_HOVER:
		state = "hover"
	elif mode == BaseButton.DRAW_PRESSED:
		state = "pressed"
	var bg := _flat(state, kind).bg_color
	SketchDraw.draw_gear(self, r.size * 0.5, minf(r.size.x, r.size.y) * 0.34, _seed, gear, bg)
