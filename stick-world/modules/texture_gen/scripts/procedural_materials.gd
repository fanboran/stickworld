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


# ═══════════════════════ 层叠茅草 ═══════════════════════

## 简化版层叠茅草屋顶贴图（横向 tileable）
## 斜向茅草束 + 底边垂挂 + 外框描边
static func make_thatch_layered(w: int, h: int, seed: int = 0) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("thatch_layered_%dx%d_s%d" % [w, h, seed])

	# 调色板（从浅到深）
	var palette: Array[Color] = [
		Color(0.898, 0.698, 0.459),  # e5b275
		Color(0.749, 0.498, 0.255),  # bf7f41
		Color(0.667, 0.416, 0.235),  # aa6a3c
		Color(0.675, 0.337, 0.196),  # ac5632
		Color(0.475, 0.294, 0.173),  # 794b2c
	]
	var edge_color := Color(0.475, 0.235, 0.027)  # 793c07

	img.fill(palette[4])

	var row_h := maxi(12, h / 32)
	var rows := h / row_h + 2

	for row in range(rows):
		var row_y := row * row_h
		var color_idx: int
		var progress := float(row) / float(rows)
		if progress < 0.33:
			color_idx = row % 2
		else:
			color_idx = 1 + (row % 3)
		if rng.randf() < 0.12:
			color_idx = 3
		elif rng.randf() < 0.06:
			color_idx = 4
		var base_c: Color = palette[clampi(color_idx, 0, 4)]
		var x_offset := rng.randf_range(-row_h * 0.5, row_h * 0.5)
		var bundle_w := maxi(8, w / 24)
		var num_bundles := w / bundle_w + 2
		for b in range(num_bundles):
			var bx := int(b * bundle_w + x_offset) % w
			if bx < 0:
				bx += w
			var bh := row_h + rng.randf_range(-3, 5)
			var bw := bundle_w + rng.randf_range(-2, 2)
			_draw_thatch_bundle(img, bx, row_y, int(bw), int(bh), base_c, edge_color, rng, w)
		if row >= rows - 4:
			var overhang := (row - rows + 4) * 6
			for x in range(0, w, 3):
				if rng.randf() < 0.4:
					var hl := overhang + rng.randf_range(0, 8)
					_draw_hair_strand(img, x, row_y + row_h, hl, base_c.darkened(0.15), w, h)

	# 外框描边
	for x in range(w):
		img.set_pixel(x, 0, edge_color)
		img.set_pixel(x, h - 1, edge_color)
	for y in range(h):
		img.set_pixel(0, y, edge_color)
		img.set_pixel(w - 1, y, edge_color)

	return ImageTexture.create_from_image(img)


## 为多边形生成指定尺寸的茅草贴图（带 seed 控制随机性）
static func make_thatch_for_polygon(w: int, h: int, seed: int = 0) -> ImageTexture:
	return make_thatch_layered(w, h, seed)


## 用纹理创建茅草 ShaderMaterial
static func create_thatch_material(tex: ImageTexture) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	# 简单 shader：直接采样纹理
	var shader := Shader.new()
	shader.code = """
shader_type canvas_item;
uniform sampler2D tex;
void fragment() {
	COLOR = texture(tex, UV);
}
"""
	mat.shader = shader
	mat.set_shader_parameter("tex", tex)
	return mat


static func _draw_thatch_bundle(img: Image, x: int, y: int, w: int, h: int, color: Color, edge: Color, rng: RandomNumberGenerator, wrap_w: int) -> void:
	var half_w := w / 2
	for dy in range(h):
		var py := y + dy
		if py < 0 or py >= img.get_height():
			continue
		var taper := 0.7 + 0.3 * float(dy) / float(h)
		var cw := int(half_w * taper)
		for dx in range(-cw, cw):
			var px := x + dx
			px = ((px % wrap_w) + wrap_w) % wrap_w
			var c: Color = color
			var dist := absi(dx) / float(cw + 1)
			c = c.lightened((1.0 - dist) * 0.08)
			c = c * (1.0 + rng.randf_range(-0.05, 0.05))
			c.a = 1.0
			if dist > 0.85:
				c = edge
			img.set_pixel(px, py, c)


static func _draw_hair_strand(img: Image, x: int, y: int, length: float, color: Color, wrap_w: int, h: int) -> void:
	for dy in range(int(length)):
		var py := y + dy
		if py >= h:
			break
		var px := ((x % wrap_w) + wrap_w) % wrap_w
		var c: Color = color * (1.0 - float(dy) / length * 0.3)
		c.a = 1.0
		img.set_pixel(px, py, c)


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