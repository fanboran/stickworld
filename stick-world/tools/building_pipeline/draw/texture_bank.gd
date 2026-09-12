## 笔触纹理库：CPU 一次性烘制的可平铺质感小纹理（离线管线专用）。
## 除 paper 外全部为透明底，供 draw_texture_rect 以调制色叠加。
## 注意：本机 Polygon2D/draw_polygon 带 UV 的采样会坍缩为平均色，
## 纹理一律经 draw_texture_rect（rect 路径）使用，见 docs/技术/架构/建筑生成管线v2-笔触手绘.md。
extends RefCounted

const SIZE := 64

static var _cache: Dictionary = {}


static func get_tex(kind: String, rng_seed: int = 1) -> ImageTexture:
	var key := "%s_%d" % [kind, rng_seed]
	if not _cache.has(key):
		_cache[key] = ImageTexture.create_from_image(_bake(kind, rng_seed))
	return _cache[key]


static func bake_paper(w: int, h: int, rng_seed: int = 7) -> ImageTexture:
	# 全屏纸纹（multiply 用）：白底 + 灰噪 + 水平纤维，非平铺，按视口尺寸现烘。
	var key := "paper_%d_%d_%d" % [w, h, rng_seed]
	if _cache.has(key):
		return _cache[key]
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var v := rng.randf_range(0.90, 1.0)
			if rng.randf() < 0.012:
				v -= 0.06
			var fib := 0.985 + 0.015 * sin(float(x) * 0.13 + float(y) * 3.1)
			var g := clampf(v * fib, 0.0, 1.0)
			img.set_pixel(x, y, Color(g, g, g * 0.995, 1.0))
	var tex := ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex


static func _bake(kind: String, seed_val: int) -> Image:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
	var img := Image.create_empty(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	match kind:
		"hatch":
			_hatch(img, rng, 8, 0.38)
		"hatch_fine":
			_hatch(img, rng, 5, 0.26)
		"dry_brush":
			_dry_brush(img, rng)
		"plank":
			_plank(img, rng)
		"stone_courses":
			_stone_courses(img, rng)
		"thatch":
			_thatch(img, rng)
		"plaster_noise":
			_plaster_noise(img, rng)
		_:
			push_error("texture_bank: 未知纹理 kind=%s" % kind)
	return img


static func _px(img: Image, x: int, y: int, c: Color) -> void:
	var ix := posmod(x, img.get_width())
	var iy := posmod(y, img.get_height())
	var base := img.get_pixel(ix, iy)
	var a := clampf(base.a + c.a * (1.0 - base.a), 0.0, 1.0)
	if a > 0.0:
		img.set_pixel(ix, iy, Color(c.r, c.g, c.b, a))


static func _hatch(img: Image, rng: RandomNumberGenerator, spacing: int, alpha: float) -> void:
	var c := Color(0.16, 0.12, 0.08, alpha)
	for y in SIZE:
		for x in SIZE:
			var d := posmod(x + y, spacing)
			if d < 2:
				var jitter := 1.0 - 0.4 * rng.randf()
				_px(img, x, y, Color(c.r, c.g, c.b, c.a * jitter))


static func _dry_brush(img: Image, rng: RandomNumberGenerator) -> void:
	var c := Color(0.18, 0.13, 0.08, 1.0)
	for i in 46:
		var y := rng.randi_range(0, SIZE - 1)
		var x0 := rng.randi_range(-8, SIZE - 1)
		var ln := rng.randi_range(8, 26)
		var a := rng.randf_range(0.08, 0.2)
		for t in ln:
			var x := x0 + t
			var dy := 0
			if rng.randf() < 0.3:
				dy = 1 if rng.randf() < 0.5 else -1
			_px(img, x, y + dy, Color(c.r, c.g, c.b, a))


static func _plank(img: Image, rng: RandomNumberGenerator) -> void:
	var gap := Color(0.15, 0.11, 0.07, 0.55)
	var board_h := 16
	for y in SIZE:
		if y % board_h < 1:
			for x in SIZE:
				var a := gap.a * (0.75 + 0.25 * rng.randf())
				_px(img, x, y, Color(gap.r, gap.g, gap.b, a))
	# 每板一道错位竖缝
	for b in SIZE / board_h:
		var sx := rng.randi_range(8, SIZE - 8) + b * 7
		var y0 := b * board_h + 1
		for yy in board_h - 1:
			_px(img, sx, y0 + yy, Color(gap.r, gap.g, gap.b, 0.4))
	# 板内木纹细线
	var grain := Color(0.2, 0.15, 0.09, 0.14)
	for i in 30:
		var y := rng.randi_range(1, SIZE - 1)
		if y % board_h == 0:
			continue
		var x0 := rng.randi_range(0, SIZE - 1)
		var ln := rng.randi_range(10, 24)
		for t in ln:
			_px(img, x0 + t, y + (1 if rng.randf() < 0.2 else 0), grain)


static func _stone_courses(img: Image, rng: RandomNumberGenerator) -> void:
	var gap := Color(0.16, 0.14, 0.12, 0.6)
	var course_h := 12
	for y in SIZE:
		if y % course_h < 1:
			for x in SIZE:
				_px(img, x, y, Color(gap.r, gap.g, gap.b, gap.a * rng.randf_range(0.7, 1.0)))
	# 竖缝按行错位
	for row in SIZE / course_h:
		var offset := (row * 9) % 20
		var x := offset + rng.randi_range(0, 4)
		while x < SIZE:
			for yy in course_h - 1:
				_px(img, x, row * course_h + 1 + yy, Color(gap.r, gap.g, gap.b, 0.45))
			x += rng.randi_range(14, 22)
	# 石面斑驳
	var blot := Color(0.25, 0.23, 0.2, 0.12)
	for i in 60:
		var bx := rng.randi_range(0, SIZE - 1)
		var by := rng.randi_range(1, SIZE - 1)
		if by % course_h == 0:
			continue
		_px(img, bx, by, blot)
		_px(img, bx + 1, by, blot)


static func _thatch(img: Image, rng: RandomNumberGenerator) -> void:
	# 斜向草束 + 束线，营造层叠茅草
	for row in SIZE / 4 + 2:
		var y0 := row * 4 - 2
		var phase := (row * 7) % 11
		var x := -6 + phase
		while x < SIZE + 6:
			var ln := rng.randi_range(6, 11)
			var drift := 1 if rng.randf() < 0.65 else 0
			for t in ln:
				var a := 0.5 * (1.0 - float(t) / float(ln)) + 0.1
				_px(img, x + t, y0 + t * drift, Color(0.16, 0.11, 0.05, a))
			x += rng.randi_range(3, 5)
	# 水平压束线（更深的少数几条）
	for row in SIZE / 12:
		var y0 := row * 12 + rng.randi_range(0, 3)
		for x in SIZE:
			_px(img, x, y0, Color(0.13, 0.09, 0.04, 0.42))
			if x % 3 == 0:
				_px(img, x, y0 + 1, Color(0.13, 0.09, 0.04, 0.24))


static func _plaster_noise(img: Image, rng: RandomNumberGenerator) -> void:
	var c := Color(0.3, 0.26, 0.2, 1.0)
	for i in 220:
		var x := rng.randi_range(0, SIZE - 1)
		var y := rng.randi_range(0, SIZE - 1)
		var a := rng.randf_range(0.04, 0.12)
		_px(img, x, y, Color(c.r, c.g, c.b, a))
		if rng.randf() < 0.25:
			_px(img, x + 1, y, Color(c.r, c.g, c.b, a * 0.6))
