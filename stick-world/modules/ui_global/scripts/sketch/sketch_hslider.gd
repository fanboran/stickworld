class_name SketchHSlider
extends HSlider
## 手绘涂鸦滑条 —— 轨道/填充（血条同源 boiling）+ 手绘圆点滑块，全部 _draw 自绘。
##
## 替代 GlassStyle 兜底的原生 HSlider（01-设计语言 §1.0 点名的未自绘原生控件）。
## 复用 SketchDraw.draw_progress 画轨道与填充（相位错开的独立沸腾）；
## 滑块 = wobble 圆（SketchGearButton 同款画法）：白圆墨描边，聚焦/拖动变琥珀
## （§1.2 选中态用强调色）。引擎默认 grabber 图标置空，圆点由 _draw 全权接管。

## 空纹理：覆盖引擎 grabber 图标（shared，避免每实例建图）
static var _empty_tex: ImageTexture = null

var _seed: int = 0
var _timer: float = 0.0


func _ready() -> void:
	_seed = randi()
	# 引擎绘制全部置空：底/填充交给 _draw（自绘在上，native 不画）
	add_theme_stylebox_override("slider", StyleBoxEmpty.new())
	add_theme_stylebox_override("grabber_area", StyleBoxEmpty.new())
	add_theme_stylebox_override("grabber_area_highlight", StyleBoxEmpty.new())
	if _empty_tex == null:
		_empty_tex = ImageTexture.create_from_image(
				Image.create_empty(1, 1, false, Image.FORMAT_RGBA8))
	add_theme_icon_override("grabber", _empty_tex)
	add_theme_icon_override("grabber_highlight", _empty_tex)
	add_theme_icon_override("grabber_disabled", _empty_tex)
	# 命中区：默认高度太薄难拖拽，24px 舒适（SHRINK_CENTER 下不挤行）
	custom_minimum_size.y = maxf(custom_minimum_size.y, 24.0)
	value_changed.connect(func(_v: float) -> void: queue_redraw())
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
	var ratio := 0.0
	if max_value > min_value:
		ratio = clampf((value - min_value) / (max_value - min_value), 0.0, 1.0)
	var grab_r := clampf(size.y * 0.42, 5.0, 9.0)
	# 轨道区：水平让出滑块半径（滑块圆心的活动范围），垂直居中细条
	var track_h := 6.0
	var track := Rect2(grab_r, (size.y - track_h) * 0.5, size.x - grab_r * 2.0, track_h)
	var outline := Color(StickTokens.BORDER.r, StickTokens.BORDER.g, StickTokens.BORDER.b, 0.28)
	# 凹槽底 + 上下边缘波浪墨线（draw_wavy_line 抖动不随矩形缩小——draw_panel 的
	# amp_for 会把 6px 细条的扰动缩到近零，沸腾感全无的教训）
	draw_rect(track, StickTokens.GROOVE_BG)
	SketchDraw.draw_wavy_line(self, track.position, Vector2(track.end.x, track.position.y),
			_seed, outline, 1.3)
	SketchDraw.draw_wavy_line(self, Vector2(track.position.x, track.end.y), track.end,
			_seed + 13, outline, 1.3)
	# 填充 = 中心一条粗马克笔笔画（血条「实心线条」同思路，沸腾 + 长度 = 值）
	if ratio > 0.01:
		var fw: float = track.size.x * ratio
		var mid_y: float = track.position.y + track_h * 0.5
		var cap_r: float = (track_h - 1.0) * 0.5
		var from := Vector2(track.position.x + cap_r, mid_y)
		var to := Vector2(track.position.x + fw - cap_r, mid_y)
		SketchDraw.draw_wavy_line(self, from, to, _seed + 77,
				StickTokens.ACCENT, track_h - 1.0)
		# 圆头端帽（血条收笔同款：方头 polyline 显机械）
		draw_circle(from, cap_r, StickTokens.ACCENT)
		draw_circle(to, cap_r, StickTokens.ACCENT)
	var cx: float = track.position.x + track.size.x * ratio
	_draw_grabber(Vector2(cx, size.y * 0.5), grab_r)


## 手绘圆点滑块：白实心 + 深墨描边；聚焦（拖动/键盘）转琥珀 = §1.2 选中态
func _draw_grabber(center: Vector2, radius: float) -> void:
	var pts := PackedVector2Array()
	var seg := 14
	for i in seg:
		var a := TAU * float(i) / float(seg)
		var rr := radius + SketchDraw.wobble(i * 3, _seed + 31) * SketchDraw.WOBBLE_AMP
		pts.append(center + Vector2(cos(a), sin(a)) * rr)
	var fill := StickTokens.ACCENT if has_focus() else StickTokens.TEXT
	var outline := Color(0.05, 0.04, 0.03, 0.95)  # 血条 COLOR_OUTLINE 同源墨色
	draw_colored_polygon(pts, fill)
	var loop := pts.duplicate()
	loop.append(pts[0])
	draw_polyline(loop, outline, SketchDraw.OUTLINE_WIDTH, true)
