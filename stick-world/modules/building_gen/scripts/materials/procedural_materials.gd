class_name ProceduralMaterials
extends RefCounted
## 程序化材质贴图生成器 —— 用代码生成木材/稻草/石材纹理，不依赖外部 PNG。


# ═══════════════════════ 木材 ═══════════════════════

## 竖纹木柱贴图（w × h）
static func make_wood_pillar(w: int, h: int, base_color: Color = Color(0.45, 0.30, 0.15)) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("wood_pillar_%dx%d" % [w, h])
	for y in range(h):
		var shade := 1.0 + rng.randf_range(-0.08, 0.08)
		for x in range(w):
			var grain := 1.0 + sin(x * 0.6 + y * 0.1) * 0.06 + sin(x * 1.3 + y * 0.04) * 0.04
			var c := base_color * shade * grain
			c.a = 1.0
			img.set_pixel(x, y, c)
	# 加暗色边缘
	for y in range(h):
		img.set_pixel(0, y, base_color * 0.7)
		img.set_pixel(w - 1, y, base_color * 0.7)
	for x in range(w):
		img.set_pixel(x, 0, base_color * 0.75)
		img.set_pixel(x, h - 1, base_color * 0.75)
	return ImageTexture.create_from_image(img)


## 横纹木板贴图（w × h，用于内部物体）
static func make_wood_plank(w: int, h: int, base_color: Color = Color(0.50, 0.33, 0.18)) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("wood_plank_%dx%d" % [w, h])
	var plank_h := maxi(6, h / 5)
	for y in range(h):
		var plank_idx := y / plank_h
		var shade := 1.0 + rng.randf_range(-0.06, 0.06) + (plank_idx % 2) * 0.03
		for x in range(w):
			var grain := 1.0 + sin(y * 0.4 + x * 0.08) * 0.04 + sin(x * 0.3) * 0.03
			var c := base_color * shade * grain
			c.a = 1.0
			img.set_pixel(x, y, c)
		# 板缝暗线
		if y > 0 and y % plank_h == 0:
			for x in range(w):
				var existing := img.get_pixel(x, y)
				img.set_pixel(x, y, existing * 0.5)
	return ImageTexture.create_from_image(img)


# ═══════════════════════ 稻草 ═══════════════════════

## 稻草顶棚贴图（w × h，纤维质感）
static func make_straw_thatch(w: int, h: int, base_color: Color = Color(0.72, 0.60, 0.30)) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("straw_thatch_%dx%d" % [w, h])
	for y in range(h):
		for x in range(w):
			var fiber := 1.0 + sin(y * 1.5 + x * 0.3) * 0.1 + sin(x * 2.0 + y * 0.7) * 0.06
			var shade := 1.0 + rng.randf_range(-0.04, 0.04)
			var c := base_color * fiber * shade
			if (x + y) % 7 < 2:
				c = c.darkened(0.08)
			c.a = 1.0
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)


# ═══════════════════════ 石头/金属 ═══════════════════════

## 深色石质贴图（高炉用）
static func make_stone_dark(w: int, h: int, base_color: Color = Color(0.25, 0.22, 0.20)) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("stone_dark_%dx%d" % [w, h])
	for y in range(h):
		for x in range(w):
			var shade := 1.0 + rng.randf_range(-0.06, 0.06)
			var c := base_color * shade
			c.a = 1.0
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)


## 铁色贴图（铁砧用）
static func make_metal_iron(w: int, h: int) -> ImageTexture:
	return make_stone_dark(w, h, Color(0.30, 0.28, 0.30))


## 纯色矩形贴图
static func make_solid(w: int, h: int, color: Color) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(color)
	return ImageTexture.create_from_image(img)
