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
		"wood_grain":
			_wood_grain(img, rng)
		"brick":
			_brick(img, rng)
		"stone_block":
			_stone_block(img, rng)
		"slate":
			_slate(img, rng)
		"tile":
			_tile(img, rng)
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


## 纵向木纹 + 板缝（参考图木材表现：竖向纹路清晰）。
static func _wood_grain(img: Image, rng: RandomNumberGenerator) -> void:
	var seam := Color(0.18, 0.1, 0.04, 0.5)
	# 板缝：竖向，间距不均
	var x := 0
	while x < SIZE:
		for y in SIZE:
			_px(img, x, y, Color(seam.r, seam.g, seam.b, seam.a * rng.randf_range(0.7, 1.0)))
		x += rng.randi_range(14, 26)
	# 木纹：竖向长线
	for i in 46:
		var gx := rng.randi_range(0, SIZE - 1)
		var gy0 := rng.randi_range(-10, SIZE)
		var ln := rng.randi_range(20, 50)
		var a := rng.randf_range(0.1, 0.3)
		for t in ln:
			var bend := 1 if rng.randf() < 0.06 else 0
			_px(img, gx + bend, gy0 + t, Color(0.2, 0.11, 0.04, a))
	# 少量横向结疤
	for i in 7:
		var bx := rng.randi_range(0, SIZE - 1)
		var by := rng.randi_range(0, SIZE - 1)
		_px(img, bx, by, Color(0.16, 0.09, 0.03, 0.4))
		_px(img, bx, by + 1, Color(0.16, 0.09, 0.03, 0.25))


## 砖缝：水平缝每 8px + 竖缝错位（参考图 Lv4 红砖）。
static func _brick(img: Image, rng: RandomNumberGenerator) -> void:
	var mortar := Color(0.42, 0.34, 0.28, 0.5)
	var row_h := 8
	for y in SIZE:
		if y % row_h < 1:
			for x in SIZE:
				_px(img, x, y, Color(mortar.r, mortar.g, mortar.b, mortar.a * rng.randf_range(0.8, 1.0)))
	for row in SIZE / row_h:
		var x := (row * 9) % 18
		while x < SIZE:
			for yy in row_h - 1:
				_px(img, x, row * row_h + 1 + yy, Color(mortar.r, mortar.g, mortar.b, 0.4))
			x += rng.randi_range(14, 20)
	# 砖面轻微明暗（每砖一档）
	for row in SIZE / row_h:
		var x := (row * 9) % 18
		while x < SIZE:
			if rng.randf() < 0.4:
				var bx := rng.randi_range(0, 10)
				var by := rng.randi_range(1, row_h - 1)
				_px(img, x + bx, row * row_h + by, Color(0.3, 0.15, 0.1, 0.12) if rng.randf() < 0.5 else Color(0.95, 0.8, 0.7, 0.1))
			x += rng.randi_range(14, 20)


## 大块石砌：水平层缝每 14px + 竖缝错位 + 石面斑驳（参考图 Lv3 石工）。
static func _stone_block(img: Image, rng: RandomNumberGenerator) -> void:
	var gap := Color(0.2, 0.19, 0.17, 0.55)
	var ch := 14
	for y in SIZE:
		if y % ch < 1:
			for x in SIZE:
				_px(img, x, y, Color(gap.r, gap.g, gap.b, gap.a * rng.randf_range(0.7, 1.0)))
	for row in SIZE / ch:
		var x := (row * 11) % 24 + rng.randi_range(0, 3)
		while x < SIZE:
			for yy in ch - 1:
				_px(img, x, row * ch + 1 + yy, Color(gap.r, gap.g, gap.b, 0.45))
			x += rng.randi_range(18, 28)
	# 石面明暗块（大块面感）
	for i in 34:
		var bx := rng.randi_range(0, SIZE - 6)
		var by := rng.randi_range(1, SIZE - 4)
		if by % ch == 0:
			continue
		var dark := rng.randf() < 0.55
		var c := Color(0.28, 0.27, 0.25, 0.14) if dark else Color(1.0, 0.99, 0.95, 0.12)
		for dx in rng.randi_range(3, 7):
			for dy in rng.randi_range(2, 4):
				_px(img, bx + dx, by + dy, c)


## 石板瓦：横向瓦排 + 每排错位短缝（冷灰）。
static func _slate(img: Image, rng: RandomNumberGenerator) -> void:
	var line := Color(0.16, 0.17, 0.2, 0.45)
	var row_h := 7
	for y in SIZE:
		if y % row_h < 1:
			for x in SIZE:
				_px(img, x, y, Color(line.r, line.g, line.b, line.a * rng.randf_range(0.75, 1.0)))
	for row in SIZE / row_h:
		var x := (row * 7) % 14
		while x < SIZE:
			for yy in row_h - 1:
				_px(img, x, row * row_h + 1 + yy, Color(line.r, line.g, line.b, 0.35))
			x += rng.randi_range(11, 16)


## 红瓦：横向瓦垄弧线 + 错位（参考图 Lv4 遮棚瓦）。
static func _tile(img: Image, rng: RandomNumberGenerator) -> void:
	var line := Color(0.26, 0.11, 0.07, 0.5)
	var row_h := 8
	for y in SIZE:
		var phase := (y / row_h) % 2
		if y % row_h < 1:
			for x in SIZE:
				var sag := int(1.5 * sin(float(x + phase * 8) * 0.5))
				_px(img, x, y + sag, Color(line.r, line.g, line.b, line.a * rng.randf_range(0.75, 1.0)))
	for row in SIZE / row_h:
		var x := (row * 8) % 16
		while x < SIZE:
			for yy in row_h - 1:
				_px(img, x, row * row_h + 1 + yy, Color(line.r, line.g, line.b, 0.3))
			x += rng.randi_range(10, 15)
	# 瓦面高光条（每垄一亮线）
	for row in SIZE / row_h:
		var x := (row * 8) % 16 + 4
		while x < SIZE:
			for yy in row_h - 2:
				_px(img, x, row * row_h + 2 + yy, Color(1.0, 0.85, 0.72, 0.1))
			x += rng.randi_range(10, 15)
