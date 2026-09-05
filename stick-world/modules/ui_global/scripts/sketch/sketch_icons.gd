class_name SketchIcons
extends Object
## 手绘图标纹理工厂 —— CheckBox / CheckButton / OptionButton 的主题兜底图标。
##
## Theme 层全局生效（未换 Sketch* 控件类的使用点也吃到手绘感）；纹理表达不了
## boiling（逐帧重掷要控件类 _draw），所以这里的扰动是「定型」的：每个图形按
## 固定 seed 微扰，与 StickHand 字体同一哲学——每个图标"定型地微微不一样"。
## 栅格化用 SDF 逐像素合成（1px 解析抗锯齿），结果按 key 缓存共享。

## CheckBox 图标边长（px）
const BOX_SIZE := Vector2i(18, 18)
## CheckButton 拨动开关图标尺寸（px）
const TOGGLE_SIZE := Vector2i(34, 18)
## OptionButton 下拉箭头图标尺寸（px）
const ARROW_SIZE := Vector2i(12, 10)

static var _cache: Dictionary = {}


## CheckBox 勾选框图标：方框白描边；选中琥珀描边 + 琥珀 14% 底 + 白对勾（§1.5 只上底不上字）
static func checkbox(checked: bool, disabled: bool = false) -> ImageTexture:
	var key := "cb_%s_%s" % [checked, disabled]
	return _tex(key, BOX_SIZE, func(img: Image) -> void: _paint_checkbox(img, checked, disabled))


## CheckButton 拨动开关图标：凹槽 + 圆钮。开 = 琥珀凹槽 + 白圆钮（右）；关 = 白描边 + 白圆钮（左）
static func toggle(checked: bool, disabled: bool = false) -> ImageTexture:
	var key := "tg_%s_%s" % [checked, disabled]
	return _tex(key, TOGGLE_SIZE, func(img: Image) -> void: _paint_toggle(img, checked, disabled))


## OptionButton 下拉箭头图标：白描马克笔 ∨
static func arrow(disabled: bool = false) -> ImageTexture:
	var key := "ar_%s" % disabled
	return _tex(key, ARROW_SIZE, func(img: Image) -> void: _paint_arrow(img, disabled))


# ─────────────────────────────── 逐图标画法 ────────────────────────────────

static func _paint_checkbox(img: Image, checked: bool, disabled: bool) -> void:
	var dim: float = 0.45 if disabled else 1.0
	var center := Vector2(BOX_SIZE) * 0.5
	var half := Vector2(6.0, 6.0) + Vector2(_w(11, 3) * 0.8, _w(12, 5) * 0.8)
	if checked:
		_blend_rect(img, center, half, 3.5, 7, "fill", 0.20 * dim, StickTokens.ACCENT)
		_blend_rect(img, center, half, 3.5, 7, "ring", 0.95 * dim, StickTokens.ACCENT)
		_blend_stroke(img, _check_pts(center, half, 1), 2.1, dim, StickTokens.TEXT)
	else:
		_blend_rect(img, center, half, 3.5, 7, "ring", 0.75 * dim, StickTokens.TEXT)


static func _paint_toggle(img: Image, checked: bool, disabled: bool) -> void:
	var dim: float = 0.45 if disabled else 1.0
	var center := Vector2(TOGGLE_SIZE) * 0.5
	var half := Vector2(TOGGLE_SIZE.x * 0.5 - 0.75, TOGGLE_SIZE.y * 0.5 - 0.75)
	var ring_a: float = 0.95 if checked else 0.7
	var ring_c: Color = StickTokens.ACCENT if checked else StickTokens.TEXT
	if checked:
		_blend_rect(img, center, half, half.y, 21, "fill", 0.20 * dim, StickTokens.ACCENT)
	_blend_rect(img, center, half, half.y, 21, "ring", ring_a * dim, ring_c)
	var r := TOGGLE_SIZE.y * 0.5 - 4.5
	var cx: float = center.x + (half.x - r - 1.0) * (1.0 if checked else -1.0)
	_blend_circle(img, Vector2(cx, center.y), r, 29, dim, StickTokens.TEXT)


static func _paint_arrow(img: Image, disabled: bool) -> void:
	var dim: float = 0.45 if disabled else 1.0
	var c := Vector2(ARROW_SIZE) * 0.5
	var a := Vector2(c.x - 3.2, c.y - 1.6) + Vector2(_w(1, 4), _w(2, 4)) * 0.5
	var b := Vector2(c.x, c.y + 1.8) + Vector2(_w(3, 4), _w(4, 4)) * 0.5
	var d := Vector2(c.x + 3.2, c.y - 1.6) + Vector2(_w(5, 4), _w(6, 4)) * 0.5
	_blend_stroke(img, [a, b], 1.7, dim, StickTokens.TEXT)
	_blend_stroke(img, [b, d], 1.7, dim, StickTokens.TEXT)


# ─────────────────────────────── 内部 ────────────────────────────────

## 对勾三折点（带固定扰动）：左肩 → 底点 → 右上
static func _check_pts(center: Vector2, half: Vector2, seed: int) -> Array:
	var left: float = center.x - half.x
	var top: float = center.y - half.y
	return [
		Vector2(left + half.x * 0.42, top + half.y * 1.12) + Vector2(_w(1, seed), _w(2, seed)) * 0.7,
		Vector2(left + half.x * 0.86, top + half.y * 1.5) + Vector2(_w(3, seed), _w(4, seed)) * 0.7,
		Vector2(left + half.x * 1.62, top + half.y * 0.28) + Vector2(_w(5, seed), _w(6, seed)) * 0.7,
	]


## 定型扰动（-0.5~0.5）：复用 SketchDraw.wobble，固定 seed
static func _w(i: int, seed: int) -> float:
	return SketchDraw.wobble(i, seed)


## 手绘感圆角矩形 SDF：坐标加低频正弦位移 = 边缘小幅波摆
static func _sd_rect(p: Vector2, center: Vector2, half: Vector2, r: float, seed: int) -> float:
	var q := p - center
	q.x += 0.5 * sin(q.y * 0.9 + float(seed) * 0.77)
	q.y += 0.5 * sin(q.x * 1.1 + float(seed) * 1.31)
	var d := q.abs() - half + Vector2(r, r)
	return Vector2(maxf(d.x, 0.0), maxf(d.y, 0.0)).length() \
			+ minf(maxf(d.x, d.y), 0.0) - r


## 手绘感圆 SDF：半径随角度低频波摆
static func _sd_circle(p: Vector2, center: Vector2, r: float, seed: int) -> float:
	var d := p - center
	var rr: float = r * (1.0 + 0.06 * sin(3.0 * d.angle() + float(seed)))
	return d.length() - rr


## 线段 SDF 距离（两端点）
static func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var pa := p - a
	var ba := b - a
	var h: float = clampf(pa.dot(ba) / maxf(ba.length_squared(), 0.0001), 0.0, 1.0)
	return (pa - ba * h).length()


## 圆角矩形层合成：mode "ring" = 1.4px 描边圈，"fill" = 实心底
static func _blend_rect(img: Image, center: Vector2, half: Vector2, corner_r: float,
		seed: int, mode: String, strength: float, color: Color) -> void:
	for y in img.get_height():
		for x in img.get_width():
			var d := _sd_rect(Vector2(x + 0.5, y + 0.5), center, half, corner_r, seed)
			var a := 0.0
			if mode == "ring":
				a = clampf(1.2 - absf(d), 0.0, 1.0) * strength
			else:
				a = clampf(0.5 - d, 0.0, 1.0) * strength
			if a > 0.0:
				_composite(img, x, y, a, color)


## wobble 圆实心层合成
static func _blend_circle(img: Image, center: Vector2, radius: float, seed: int,
		strength: float, color: Color) -> void:
	for y in img.get_height():
		for x in img.get_width():
			var d := _sd_circle(Vector2(x + 0.5, y + 0.5), center, radius, seed)
			var a := clampf(0.5 - d, 0.0, 1.0) * strength
			if a > 0.0:
				_composite(img, x, y, a, color)


## 马克笔笔画层合成（折线 = 相邻点两两成段，笔宽外置）
static func _blend_stroke(img: Image, pts: Array, width: float, strength: float,
		color: Color) -> void:
	for y in img.get_height():
		for x in img.get_width():
			var p := Vector2(x + 0.5, y + 0.5)
			var best := 1e9
			for i in pts.size() - 1:
				best = minf(best, _seg_dist(p, pts[i], pts[i + 1]))
			var a := clampf(0.5 + width * 0.5 - best, 0.0, 1.0) * strength
			if a > 0.0:
				_composite(img, x, y, a, color)


## over 逐像素合成（src 在上）
static func _composite(img: Image, x: int, y: int, a: float, color: Color) -> void:
	var dst := img.get_pixel(x, y)
	var out_a: float = a + dst.a * (1.0 - a)
	if out_a <= 0.0:
		return
	var r := (color.r * a + dst.r * dst.a * (1.0 - a)) / out_a
	var g := (color.g * a + dst.g * dst.a * (1.0 - a)) / out_a
	var b := (color.b * a + dst.b * dst.a * (1.0 - a)) / out_a
	img.set_pixel(x, y, Color(r, g, b, out_a))


## 纹理工厂：按 key 缓存，painter 收到 Image 逐层绘制
static func _tex(key: String, size: Vector2i, painter: Callable) -> ImageTexture:
	if _cache.has(key):
		return _cache[key]
	var img := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	painter.call(img)
	var tex := ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex
