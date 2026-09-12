## 质感纹理库：CPU 一次性烘制的高精细可平铺纹理（离线管线专用）。
## 目标精度对齐 3D 材质球：单像素级笔触（草茎/纤维）、做旧与风化、多尺度斑驳、
## 每块砖石独立色偏与缺角。平铺周期 SIZE(128px @1x = 4 格)。
## 注意：本机 Polygon2D/draw_polygon 带 UV 的采样会坍缩为平均色，
## 纹理一律经 draw_texture_rect（rect 路径）使用，见 docs/技术/架构/建筑生成管线v2-笔触手绘.md。
extends RefCounted

const SIZE := 128

static var _cache: Dictionary = {}


static func get_tex(kind: String, rng_seed: int = 1) -> ImageTexture:
	var key := "%s_%d" % [kind, rng_seed]
	if not _cache.has(key):
		_cache[key] = ImageTexture.create_from_image(bake(kind, rng_seed))
	return _cache[key]


## 直接取 Image（city_view 等纯 Image 场景平铺用）。
static func bake(kind: String, rng_seed: int = 1) -> Image:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([kind, rng_seed])
	var img := Image.create_empty(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	match kind:
		"straw":
			_straw(img, rng)
		"straw_dark":
			_straw(img, rng, true)
		"thatch":
			_thatch(img, rng)
		"brick":
			_brick(img, rng)
		"stone":
			_stone(img, rng)
		"stone_light":
			_stone(img, rng, 1.16)
		"stone_dark":
			_stone(img, rng, 0.78)
		"wood_grain":
			_wood(img, rng)
		"plank":
			_plank(img, rng)
		"slate":
			_slate(img, rng)
		"tile":
			_tile(img, rng)
		"lime":
			_lime(img, rng)
		"plaster_noise":
			_lime(img, rng, 0.7)
		"hemp":
			_hemp(img, rng)
		"hatch":
			_hatch(img, rng, 10, 0.34)
		"dry_brush":
			_dry_brush(img, rng)
		"moss":
			_moss(img, rng)
		"grass":
			_grass(img, rng)
		"dirt":
			_dirt(img, rng)
		"cobble":
			_cobble(img, rng)
		_:
			push_error("texture_bank: 未知纹理 kind=%s" % kind)
	return img


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
			var v := rng.randf_range(0.93, 1.0)
			if rng.randf() < 0.010:
				v -= 0.05
			var fib := 0.99 + 0.01 * sin(float(x) * 0.11 + float(y) * 2.7)
			var g := clampf(v * fib, 0.0, 1.0)
			img.set_pixel(x, y, Color(g, g, g * 0.997, 1.0))
	var tex := ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex


# ---------- 像素工具 ----------

static func _px(img: Image, x: int, y: int, c: Color) -> void:
	var ix := posmod(x, img.get_width())
	var iy := posmod(y, img.get_height())
	var base := img.get_pixel(ix, iy)
	# 标准 source-over 合成：out = src*a + dst*(1-a)
	var out_a := c.a + base.a * (1.0 - c.a)
	if out_a <= 0.0001:
		return
	var inv := 1.0 - c.a
	var out_r := (c.r * c.a + base.r * base.a * inv) / out_a
	var out_g := (c.g * c.a + base.g * base.a * inv) / out_a
	var out_b := (c.b * c.a + base.b * base.a * inv) / out_a
	img.set_pixel(ix, iy, Color(clampf(out_r, 0.0, 1.0), clampf(out_g, 0.0, 1.0), clampf(out_b, 0.0, 1.0), out_a))


static func _fill(img: Image, c: Color) -> void:
	img.fill(c)


static func _tint(c: Color, f: float) -> Color:
	return Color(clampf(c.r * f, 0.0, 1.0), clampf(c.g * f, 0.0, 1.0), clampf(c.b * f, 0.0, 1.0), c.a)


# ---------- 稻草 / 茅草（单像素草茎层叠） ----------

## 稻草：上千根 1px 草茎，分上下两层（下层深、上层亮），根根可辨。
static func _straw(img: Image, rng: RandomNumberGenerator, dark: bool = false) -> void:
	_fill(img, Color(0.28, 0.2, 0.08, 1.0))
	var bright := Color(0.95, 0.8, 0.42)
	var mid := Color(0.78, 0.6, 0.26)
	for layer in 2:
		var lower := layer == 0
		var count := 1500 if lower else 1200
		for i in count:
			var x := rng.randf() * float(SIZE)
			var y := rng.randf() * float(SIZE)
			var ln := rng.randi_range(5, 20)
			var ang := -PI * 0.5 + rng.randf_range(-0.55, 0.55)
			var dx := cos(ang)
			var dy := sin(ang)
			var bend := rng.randf_range(-0.5, 0.5)
			var phase := rng.randf() * TAU
			var base_c := mid if lower else bright
			var f := rng.randf_range(0.72, 1.08) * (0.72 if lower else 1.0)
			var c := _tint(base_c, f)
			var a0 := rng.randf_range(0.55, 0.9) * (0.85 if lower else 1.0)
			for t in ln:
				var tt := float(t)
				var px := x + dx * tt + sin(tt * 0.4 + phase) * bend * 2.0
				var py := y + dy * tt
				var a := a0 * (1.0 - tt / float(ln) * 0.3)
				_px(img, int(round(px)), int(round(py)), Color(c.r, c.g, c.b, a))
	if dark:
		# 整体压暗当"旧草/下层草"
		for y in SIZE:
			for x in SIZE:
				var p := img.get_pixel(x, y)
				img.set_pixel(x, y, Color(p.r * 0.72, p.g * 0.7, p.b * 0.72, p.a))


## 茅草瓦鳞（束状叠压，用于屋面）。
static func _thatch(img: Image, rng: RandomNumberGenerator) -> void:
	_fill(img, Color(0.3, 0.21, 0.08, 1.0))
	var bright := Color(0.9, 0.72, 0.34)
	for row in 22:
		var y0 := row * 6 - 3
		var phase := float(row * 13 % 23)
		var x := -8.0 + phase
		while x < float(SIZE) + 8.0:
			var ln := rng.randi_range(9, 20)
			var drift := rng.randf_range(0.4, 1.2)
			var c := _tint(bright, rng.randf_range(0.7, 1.1))
			var a0 := rng.randf_range(0.5, 0.85)
			for t in ln:
				var tt := float(t)
				_px(img, int(x + tt), int(y0 + tt * drift * 0.35), Color(c.r, c.g, c.b, a0 * (1.0 - tt / float(ln) * 0.35)))
			x += rng.randf_range(4.0, 8.0)
	# 横向压束线（捆扎感）
	for row in 6:
		var y0 := row * 21 + rng.randi_range(0, 4)
		for x in SIZE:
			_px(img, x, y0, Color(0.16, 0.1, 0.03, 0.30))
			_px(img, x, y0 + 1, Color(0.16, 0.1, 0.03, 0.14))


# ---------- 砖（做旧 / 多尺寸 / 独立色偏 / 缺角） ----------

static func _brick(img: Image, rng: RandomNumberGenerator) -> void:
	_fill(img, Color(0.64, 0.55, 0.47, 1.0))  # 灰浆底
	var y := -rng.randi_range(0, 6)
	while y < SIZE:
		var row_h := rng.randi_range(9, 13)
		var x := -rng.randi_range(0, 20)
		while x < SIZE:
			var bw := rng.randi_range(16, 27)
			# 每块砖独立色偏与明暗
			var tone := rng.randf_range(0.72, 1.06)
			var warm := rng.randf_range(0.9, 1.1)
			var c := Color(clampf(0.72 * tone * warm, 0, 1), clampf(0.36 * tone, 0, 1), clampf(0.24 * tone * 0.95, 0, 1), 1.0)
			var gap := rng.randi_range(1, 3)
			for by in row_h:
				for bx in bw:
					if bx < 1 or by < 1:
						continue
					var px := x + bx
					var py := y + by
					if px >= SIZE or py >= SIZE:
						continue
					# 缺角（随机挖掉角部）
					var corner := rng.randf()
					var cut := false
					if corner < 0.18:
						var cz := rng.randi_range(1, 3)
						if (bx < cz and by < cz) or (bx > bw - cz - 1 and by < cz) or (bx < cz and by > row_h - cz - 1) or (bx > bw - cz - 1 and by > row_h - cz - 1):
							cut = true
					if cut:
						continue
					var shade := 1.0
					# 顶部受光 1~2px 亮、底部压暗 1px
					if by <= 1:
						shade = 1.16
					elif by >= row_h - 2:
						shade = 0.8
					# 砖面细颗粒
					shade *= rng.randf_range(0.94, 1.06)
					_px(img, px, py, Color(c.r * shade, c.g * shade, c.b * shade, 1.0))
			x += bw + gap
		y += row_h + rng.randi_range(1, 2)
	# 做旧：大尺度污渍 + 苔斑 + 磨损
	for i in rng.randi_range(4, 7):
		var cx := rng.randf() * SIZE
		var cy := rng.randf() * SIZE
		var rad := rng.randf_range(10.0, 30.0)
		var dark := rng.randf() < 0.6
		for dy in range(-int(rad), int(rad) + 1):
			for dx in range(-int(rad), int(rad) + 1):
				var d := sqrt(float(dx * dx + dy * dy))
				if d > rad:
					continue
				var a := (1.0 - d / rad) * 0.16
				var c := Color(0.16, 0.12, 0.1, a) if dark else Color(0.9, 0.86, 0.78, a * 0.7)
				_px(img, int(cx) + dx, int(cy) + dy, c)
	for i in rng.randi_range(8, 16):
		var mx := rng.randi_range(0, SIZE - 1)
		var my := rng.randi_range(0, SIZE - 1)
		for k in rng.randi_range(2, 6):
			_px(img, mx + rng.randi_range(-2, 2), my + rng.randi_range(-2, 2), Color(0.34, 0.42, 0.24, rng.randf_range(0.15, 0.4)))


# ---------- 石（不规则块 + 风化 + 苔藓） ----------

static func _stone(img: Image, rng: RandomNumberGenerator, tone: float = 1.0) -> void:
	_fill(img, Color(0.46, 0.44, 0.41, 1.0))
	var y := -rng.randi_range(0, 8)
	while y < SIZE:
		var row_h := rng.randi_range(13, 20)
		var x := -rng.randi_range(0, 24)
		while x < SIZE:
			var bw := rng.randi_range(20, 40)
			var t := rng.randf_range(0.78, 1.14) * tone
			var base := Color(0.78 * t, 0.76 * t, 0.72 * t, 1.0)
			var gap := rng.randi_range(1, 3)
			# 石角随机内缩（不规则轮廓）
			var cut_tl := rng.randi_range(0, 3)
			var cut_tr := rng.randi_range(0, 3)
			var cut_bl := rng.randi_range(0, 2)
			var cut_br := rng.randi_range(0, 2)
			for by in row_h:
				for bx in bw:
					if bx < 1 or by < 1:
						continue
					if bx < cut_tl and by < cut_tl:
						continue
					if bx > bw - cut_tr - 1 and by < cut_tr:
						continue
					if bx < cut_bl and by > row_h - cut_bl - 1:
						continue
					if bx > bw - cut_br - 1 and by > row_h - cut_br - 1:
						continue
					var shade := 1.0
					if by <= 1:
						shade = 1.18
					elif by >= row_h - 2:
						shade = 0.78
					shade *= rng.randf_range(0.93, 1.07)
					_px(img, x + bx, y + by, Color(base.r * shade, base.g * shade, base.b * shade, 1.0))
			x += bw + gap
		y += row_h + rng.randi_range(1, 3)
	# 风化斑 + 裂纹 + 苔
	for i in rng.randi_range(5, 9):
		var cx := rng.randf() * SIZE
		var cy := rng.randf() * SIZE
		var rad := rng.randf_range(8.0, 24.0)
		var dark := rng.randf() < 0.55
		for dy in range(-int(rad), int(rad) + 1):
			for dx in range(-int(rad), int(rad) + 1):
				var d := sqrt(float(dx * dx + dy * dy))
				if d > rad:
					continue
				var a := (1.0 - d / rad) * 0.13
				var c := Color(0.2, 0.2, 0.19, a) if dark else Color(0.94, 0.93, 0.88, a * 0.6)
				_px(img, int(cx) + dx, int(cy) + dy, c)
	for i in rng.randi_range(2, 4):
		var sx := rng.randi_range(0, SIZE - 1)
		var sy := rng.randi_range(0, SIZE - 1)
		var ang := rng.randf() * TAU
		var ln := rng.randi_range(10, 30)
		for t in ln:
			if rng.randf() < 0.35:
				continue
			_px(img, int(sx + cos(ang) * t), int(sy + sin(ang) * t), Color(0.18, 0.18, 0.17, 0.4))
	for i in rng.randi_range(10, 20):
		var mx := rng.randi_range(0, SIZE - 1)
		var my := rng.randi_range(0, SIZE - 1)
		for k in rng.randi_range(2, 7):
			_px(img, mx + rng.randi_range(-3, 3), my + rng.randi_range(-3, 3), Color(0.36, 0.44, 0.26, rng.randf_range(0.12, 0.36)))


# ---------- 木（纵向纤维 + 结节 + 板缝 + 裂纹） ----------

static func _wood(img: Image, rng: RandomNumberGenerator) -> void:
	_fill(img, Color(0.42, 0.28, 0.15, 1.0))
	# 纵向纤维
	for i in 700:
		var x := rng.randf() * float(SIZE)
		var y0 := rng.randf() * float(SIZE)
		var ln := rng.randi_range(12, 60)
		var f := rng.randf_range(0.82, 1.2)
		var c := Color(0.24 * f, 0.15 * f, 0.075 * f, rng.randf_range(0.12, 0.34))
		for t in ln:
			var px := x + sin(float(t) * 0.09 + x) * 0.8
			_px(img, int(round(px)), int(y0 + float(t)), c)
	# 板缝（竖，间距不均）+ 缝旁倒角亮线
	var bx := -rng.randi_range(0, 10)
	while bx < SIZE:
		var a0 := rng.randf_range(0.4, 0.7)
		for y in SIZE:
			_px(img, bx, y, Color(0.12, 0.075, 0.035, a0))
			if rng.randf() < 0.3:
				_px(img, bx + 1, y, Color(0.12, 0.075, 0.035, a0 * 0.4))
		for y in SIZE:
			_px(img, bx + 2, y, Color(0.6, 0.42, 0.24, 0.14))
		bx += rng.randi_range(22, 40)
	# 结节（同心椭圆）
	for i in rng.randi_range(2, 4):
		var kx := rng.randf() * SIZE
		var ky := rng.randf() * SIZE
		for ring in 4:
			var rr := float(ring) * 2.2 + 1.5
			for a_i in 22:
				var a := TAU * float(a_i) / 22.0
				_px(img, int(kx + cos(a) * rr * 0.7), int(ky + sin(a) * rr), Color(0.16, 0.1, 0.05, 0.35 - float(ring) * 0.06))
	# 裂纹
	for i in rng.randi_range(2, 3):
		var cx := rng.randf() * SIZE
		var cy := rng.randf() * SIZE
		for t in rng.randi_range(20, 50):
			_px(img, int(cx + sin(float(t) * 0.15) * 1.5), int(cy + float(t)), Color(0.1, 0.06, 0.03, 0.34))


static func _plank(img: Image, rng: RandomNumberGenerator) -> void:
	_wood(img, rng)
	# 木板顶：加深横向板端缝
	for i in rng.randi_range(3, 5):
		var yy := rng.randi_range(0, SIZE - 1)
		for x in SIZE:
			_px(img, x, yy, Color(0.1, 0.06, 0.03, 0.4))


# ---------- 瓦（石板 / 红瓦） ----------

static func _slate(img: Image, rng: RandomNumberGenerator) -> void:
	_fill(img, Color(0.4, 0.41, 0.45, 1.0))
	var row_h := 8
	for row in SIZE / row_h + 1:
		var y0 := row * row_h
		var x := -rng.randi_range(0, 14)
		while x < SIZE:
			var w := rng.randi_range(11, 17)
			var t := rng.randf_range(0.8, 1.18)
			var c := Color(0.42 * t, 0.44 * t, 0.48 * t, 1.0)
			for by in row_h - 1:
				for bx in w:
					if bx < 1:
						continue
					var shade := 1.15 if by <= 1 else (0.82 if by >= row_h - 3 else 1.0)
					shade *= rng.randf_range(0.95, 1.05)
					_px(img, x + bx, y0 + by, Color(c.r * shade, c.g * shade, c.b * shade, 1.0))
			# 瓦下缘阴影
			for bx in w:
				_px(img, x + bx, y0 + row_h - 1, Color(0.14, 0.15, 0.17, 0.5))
			x += w
	# 苔 / 水渍
	for i in rng.randi_range(6, 12):
		var mx := rng.randi_range(0, SIZE - 1)
		var my := rng.randi_range(0, SIZE - 1)
		for k in rng.randi_range(2, 8):
			_px(img, mx + rng.randi_range(-3, 3), my + rng.randi_range(-3, 3), Color(0.34, 0.42, 0.24, rng.randf_range(0.1, 0.3)))


static func _tile(img: Image, rng: RandomNumberGenerator) -> void:
	_fill(img, Color(0.36, 0.18, 0.13, 1.0))
	var row_h := 9
	for row in SIZE / row_h + 1:
		var y0 := row * row_h
		var x := -rng.randi_range(0, 12)
		var phase := float(row % 2) * 5.5
		while x < SIZE:
			var w := rng.randi_range(8, 12)
			var t := rng.randf_range(0.82, 1.16)
			var c := Color(0.66 * t, 0.34 * t, 0.24 * t, 1.0)
			for bx in w:
				# 瓦垄弧形（中间隆起）
				var arc := sin(float(bx) / float(w) * PI)
				for by in row_h - 1:
					var shade := (1.12 if by <= 1 else (0.8 if by >= row_h - 3 else 1.0)) * (0.88 + 0.22 * arc)
					_px(img, x + bx + int(phase), y0 + by, Color(c.r * shade, c.g * shade, c.b * shade, 1.0))
			x += w
	# 苔 / 做旧
	for i in rng.randi_range(5, 10):
		var mx := rng.randi_range(0, SIZE - 1)
		var my := rng.randi_range(0, SIZE - 1)
		for k in rng.randi_range(2, 7):
			_px(img, mx + rng.randi_range(-3, 3), my + rng.randi_range(-3, 3), Color(0.3, 0.38, 0.22, rng.randf_range(0.1, 0.28)))


# ---------- 抹灰 / 麻布 ----------

static func _lime(img: Image, rng: RandomNumberGenerator, strength: float = 1.0) -> void:
	_fill(img, Color(0.88, 0.85, 0.77, 1.0))
	# 抹刀痕（大块弧度）+ 颗粒 + 剥落斑
	for i in 160:
		var x := rng.randf() * float(SIZE)
		var y := rng.randf() * float(SIZE)
		var ln := rng.randi_range(8, 34)
		var ang := rng.randf() * TAU
		var a := rng.randf_range(0.03, 0.1) * strength
		var light := rng.randf() < 0.5
		for t in ln:
			var c := Color(0.98, 0.96, 0.9, a) if light else Color(0.72, 0.68, 0.6, a)
			_px(img, int(x + cos(ang) * t), int(y + sin(ang) * t), c)
	for i in rng.randi_range(4, 8):
		var cx: float = rng.randf() * float(SIZE)
		var cy: float = rng.randf() * float(SIZE)
		var rad := rng.randf_range(5.0, 16.0)
		for dy in range(-int(rad), int(rad) + 1):
			for dx in range(-int(rad), int(rad) + 1):
				var d := sqrt(float(dx * dx + dy * dy))
				if d > rad:
					continue
				_px(img, int(cx) + dx, int(cy) + dy, Color(0.62, 0.57, 0.48, (1.0 - d / rad) * 0.22 * strength))


static func _hemp(img: Image, rng: RandomNumberGenerator) -> void:
	_fill(img, Color(0.78, 0.72, 0.6, 1.0))
	# 麻布经纬编织
	for x in SIZE:
		if x % 4 == 0:
			for y in SIZE:
				_px(img, x, y, Color(0.62, 0.56, 0.45, 0.28))
	for y in SIZE:
		if y % 4 == 0:
			for x in SIZE:
				_px(img, x, y, Color(0.66, 0.6, 0.48, 0.24))
	# 污渍磨损
	for i in rng.randi_range(6, 12):
		var cx := rng.randf() * float(SIZE)
		var cy := rng.randf() * float(SIZE)
		var rad := rng.randf_range(6.0, 18.0)
		for dy in range(-int(rad), int(rad) + 1):
			for dx in range(-int(rad), int(rad) + 1):
				var d := sqrt(float(dx * dx + dy * dy))
				if d > rad:
					continue
				_px(img, int(cx) + dx, int(cy) + dy, Color(0.5, 0.44, 0.34, (1.0 - d / rad) * 0.18))


# ---------- 排线 / 干刷 / 苔藓 ----------

static func _hatch(img: Image, rng: RandomNumberGenerator, spacing: int, alpha: float) -> void:
	for y in SIZE:
		for x in SIZE:
			if posmod(x + y, spacing) < 2:
				_px(img, x, y, Color(0.16, 0.12, 0.08, alpha * (1.0 - 0.4 * rng.randf())))


static func _dry_brush(img: Image, rng: RandomNumberGenerator) -> void:
	for i in 150:
		var y := rng.randi_range(0, SIZE - 1)
		var x0 := rng.randi_range(-12, SIZE - 1)
		var ln := rng.randi_range(10, 40)
		var a := rng.randf_range(0.06, 0.18)
		for t in ln:
			var dy := 1 if rng.randf() < 0.12 else 0
			_px(img, x0 + t, y + dy, Color(0.18, 0.13, 0.08, a))


static func _moss(img: Image, rng: RandomNumberGenerator) -> void:
	for i in 60:
		var cx := rng.randf() * float(SIZE)
		var cy := rng.randf() * float(SIZE)
		var rad := rng.randf_range(4.0, 14.0)
		for dy in range(-int(rad), int(rad) + 1):
			for dx in range(-int(rad), int(rad) + 1):
				var d := sqrt(float(dx * dx + dy * dy))
				if d > rad:
					continue
				var a := (1.0 - d / rad) * rng.randf_range(0.2, 0.5)
				_px(img, int(cx) + dx, int(cy) + dy, Color(0.3, 0.42, 0.2, a))


# ---------- 地面（草坪 / 泥土 / 石板路） ----------

## 草坪：土壤底 + 草簇（每簇 6~14 根 1px 草叶，颜色深绿→黄绿）。
static func _grass(img: Image, rng: RandomNumberGenerator) -> void:
	_fill(img, Color(0.31, 0.26, 0.14, 1.0))
	for clump in 320:
		var cx := rng.randf() * float(SIZE)
		var cy := rng.randf() * float(SIZE)
		var blades := rng.randi_range(6, 14)
		for b in blades:
			var ang := -PI * 0.5 + rng.randf_range(-0.85, 0.85)
			var ln := rng.randi_range(5, 13)
			var t := rng.randf()
			var c := Color(0.28 + 0.34 * t, 0.48 + 0.3 * t, 0.17 + 0.12 * t, 1.0)
			var bend := rng.randf_range(-1.2, 1.2)
			for k in ln:
				var px := cx + cos(ang) * float(k) + bend * float(k) * 0.12 * float(k) * 0.1
				var py := cy + sin(ang) * float(k)
				_px(img, int(round(px)), int(round(py)), Color(c.r, c.g, c.b, rng.randf_range(0.6, 0.95)))
	# 少量枯草 / 小花
	for i in rng.randi_range(14, 24):
		var x := rng.randi_range(0, SIZE - 1)
		var y := rng.randi_range(0, SIZE - 1)
		var dry := rng.randf() < 0.7
		var c := Color(0.62, 0.56, 0.28, rng.randf_range(0.4, 0.8)) if dry else Color(0.85, 0.78, 0.5, 0.7)
		_px(img, x, y, c)
		_px(img, x, y - 1, Color(c.r, c.g, c.b, c.a * 0.7))


## 泥土路：颗粒土 + 小石 + 车辙。
static func _dirt(img: Image, rng: RandomNumberGenerator) -> void:
	_fill(img, Color(0.6, 0.51, 0.37, 1.0))
	for i in 2600:
		var x := rng.randi_range(0, SIZE - 1)
		var y := rng.randi_range(0, SIZE - 1)
		var t := rng.randf_range(0.78, 1.22)
		_px(img, x, y, Color(0.5 * t, 0.42 * t, 0.3 * t, rng.randf_range(0.2, 0.6)))
	for i in rng.randi_range(26, 40):
		var x := rng.randi_range(0, SIZE - 1)
		var y := rng.randi_range(0, SIZE - 1)
		var t := rng.randf_range(0.6, 1.15)
		# 小石（2~4px，带亮顶暗底）
		for dy in rng.randi_range(2, 4):
			for dx in rng.randi_range(2, 4):
				_px(img, x + dx, y + dy, Color(0.56 * t, 0.54 * t, 0.5 * t, 0.9))
		_px(img, x, y, Color(0.7 * t, 0.68 * t, 0.62 * t, 0.7))
	# 车辙（两条纵向压痕）
	for lane in 2:
		var lx := SIZE / 3 + lane * SIZE / 3
		for y in SIZE:
			_px(img, lx + int(sin(float(y) * 0.08) * 2.0), y, Color(0.36, 0.29, 0.2, 0.25))
			_px(img, lx + 1 + int(sin(float(y) * 0.08) * 2.0), y, Color(0.36, 0.29, 0.2, 0.15))


## 石板路：不规则小石块铺装 + 缝 + 磨损。
static func _cobble(img: Image, rng: RandomNumberGenerator) -> void:
	_fill(img, Color(0.52, 0.5, 0.47, 1.0))
	var y := -rng.randi_range(0, 6)
	while y < SIZE:
		var row_h := rng.randi_range(10, 15)
		var x := -rng.randi_range(0, 14)
		while x < SIZE:
			var bw := rng.randi_range(12, 20)
			var t := rng.randf_range(0.78, 1.16)
			var base := Color(0.74 * t, 0.73 * t, 0.69 * t, 1.0)
			for by in row_h:
				for bx in bw:
					var inner := bx > 0 and by > 0 and bx < bw - 1 and by < row_h - 1
					if not inner and rng.randf() < 0.6:
						continue
					var shade := 1.14 if by <= 1 else (0.8 if by >= row_h - 2 else 1.0)
					shade *= rng.randf_range(0.94, 1.06)
					_px(img, x + bx, y + by, Color(base.r * shade, base.g * shade, base.b * shade, 1.0))
			x += bw + rng.randi_range(1, 2)
		y += row_h + rng.randi_range(1, 2)
	# 磨损 + 缝隙积灰 + 苔
	for i in rng.randi_range(8, 14):
		var cx := rng.randf() * float(SIZE)
		var cy := rng.randf() * float(SIZE)
		var rad := rng.randf_range(4.0, 12.0)
		for dy in range(-int(rad), int(rad) + 1):
			for dx in range(-int(rad), int(rad) + 1):
				var d := sqrt(float(dx * dx + dy * dy))
				if d > rad:
					continue
				_px(img, int(cx) + dx, int(cy) + dy, Color(0.3, 0.34, 0.2, (1.0 - d / rad) * 0.22))
