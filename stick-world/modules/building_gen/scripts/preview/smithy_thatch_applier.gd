extends Node
## 铁匠铺预览场景茅草屋顶适配器（v11 - 油画笔迹风格）

@export var roof_paths: Array[NodePath] = []

# 笔迹数量
@export var stroke_count: int = 60
@export var stroke_count_var: int = 15

# 笔迹尺寸
@export var stroke_length_base: float = 200.0
@export var stroke_length_var: float = 40.0
@export var stroke_width_base: float = 16.0
@export var stroke_width_var: float = 6.0

# 笔迹外观
@export var stroke_roughness: float = 0.6
@export var stroke_opacity: float = 0.85
@export var stroke_color_var: float = 0.15

# 红色辅助线（场景中的 Line2D）
@export var show_guides: bool = true
@export var guide_color: Color = Color(1.0, 0.1, 0.1, 1.0)
@export var guide_width: float = 1.0

@export var seed_offset: int = 0

# 颜色 - 油画颜料色调
@export var color_a: Color = Color(0.75, 0.45, 0.18)  # 赭石
@export var color_b: Color = Color(0.82, 0.55, 0.25)  # 土黄
@export var color_c: Color = Color(0.65, 0.35, 0.10)  # 深褐
@export var color_d: Color = Color(0.88, 0.62, 0.35)  # 浅棕

@export var stroke_angle_deg: float = -30.0
@export var alternate_angle_per_roof: bool = true
@export var match_angle_to_slope: bool = true


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	for i in range(roof_paths.size()):
		var poly := get_node_or_null(roof_paths[i]) as Polygon2D
		if poly == null:
			continue
		_generate_and_apply(poly, i)


func _generate_and_apply(poly: Polygon2D, index: int) -> void:
	var pts := poly.polygon
	if pts.size() < 3:
		return

	var min_pt := pts[0]
	var max_pt := pts[0]
	for p in pts:
		min_pt = min_pt.min(p)
		max_pt = max_pt.max(p)

	var size := max_pt - min_pt
	if size.x <= 0.0 or size.y <= 0.0:
		return

	var xform := poly.get_global_transform()
	var scale: Vector2 = xform.get_scale()
	var tex_w: int = maxi(1, int(size.x * absf(scale.x)))
	var tex_h: int = maxi(1, int(size.y * absf(scale.y)))

	# 笔迹方向
	var effective_angle_deg: float = stroke_angle_deg
	if alternate_angle_per_roof and (index % 2) == 0:
		effective_angle_deg = -effective_angle_deg
	if match_angle_to_slope:
		var top_xs: Array[float] = []
		var bot_xs: Array[float] = []
		for p in pts:
			if absf(p.y - min_pt.y) < 1.0:
				top_xs.append(p.x)
			if absf(p.y - max_pt.y) < 1.0:
				bot_xs.append(p.x)
		if top_xs.size() >= 2 and bot_xs.size() >= 2:
			top_xs.sort()
			bot_xs.sort()
			var top_center: float = (top_xs[0] + top_xs[top_xs.size() - 1]) * 0.5
			var bot_center: float = (bot_xs[0] + bot_xs[bot_xs.size() - 1]) * 0.5
			var slope_sign: float = sign(bot_center - top_center)
			if slope_sign != 0:
				effective_angle_deg = absf(effective_angle_deg) * slope_sign

	# 生成纹理
	var tex := _generate_brush_texture(tex_w, tex_h, effective_angle_deg, seed_offset + index * 7)

	# 用 Sprite2D 替代 Polygon2D 纹理，避免透明纹理渲染问题
	# 先隐藏原 Polygon2D
	poly.visible = false

	# 查找或创建 Sprite2D 子节点
	var sprite_name := "ThatchSprite_" + poly.name
	var parent := poly.get_parent()
	var sprite := parent.get_node_or_null(sprite_name) as Sprite2D
	if sprite == null:
		sprite = Sprite2D.new()
		sprite.name = sprite_name
		parent.add_child(sprite)

	sprite.texture = tex
	sprite.global_position = poly.global_position + (min_pt + max_pt) * 0.5 * scale
	sprite.scale = scale
	sprite.centered = true
	sprite.z_index = poly.z_index
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

	# 添加辅助线（Line2D 沿多边形边缘）
	_add_guide_lines(poly, pts)

	print("[SmithyThatchApplier] applied sprite texture to ", poly.name,
		" size=", tex_w, "x", tex_h, " angle=", effective_angle_deg)


func _generate_brush_texture(w: int, h: int, angle_deg: float, tex_seed: int) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))

	var rng := RandomNumberGenerator.new()
	rng.seed = tex_seed

	var angle_rad := deg_to_rad(angle_deg)
	var ca: float = cos(angle_rad)
	var sa: float = sin(angle_rad)

	# 笔迹方向：确保向下
	var dir_x: float = ca
	var dir_y: float = absf(sa)
	var dir_len: float = sqrt(dir_x * dir_x + dir_y * dir_y)
	if dir_len > 0.001:
		dir_x /= dir_len
		dir_y /= dir_len

	# 垂直方向（用于笔迹宽度）
	var perp_x: float = -dir_y
	var perp_y: float = dir_x

	# 确定笔迹数量
	var n_strokes: int = stroke_count + rng.randi_range(-stroke_count_var, stroke_count_var)
	n_strokes = maxi(2, n_strokes)

	# 颜色列表
	var colors: Array[Color] = [color_a, color_b, color_c, color_d]

	for _k in range(n_strokes):
		# 笔迹起点：沿屋顶方向分布
		var t_start: float = rng.randf_range(0.0, 0.85)
		var t_end: float = t_start + rng.randf_range(0.1, 0.5)
		t_end = minf(t_end, 1.0)

		# 沿垂直方向偏移
		var offset: float = rng.randf_range(-0.3, 0.3) * float(h)

		# 起点和终点
		var sx: float = w * 0.5 + dir_x * (t_start - 0.5) * float(w) + perp_x * offset
		var sy: float = h * 0.5 + dir_y * (t_start - 0.5) * float(h) + perp_y * offset
		var ex: float = w * 0.5 + dir_x * (t_end - 0.5) * float(w) + perp_x * offset
		var ey: float = h * 0.5 + dir_y * (t_end - 0.5) * float(h) + perp_y * offset

		# 再加一些随机偏移
		sx += rng.randf_range(-15.0, 15.0)
		sy += rng.randf_range(-15.0, 15.0)
		ex += rng.randf_range(-10.0, 10.0)
		ey += rng.randf_range(-10.0, 10.0)

		var stroke_w: float = stroke_width_base + rng.randf_range(-stroke_width_var, stroke_width_var)
		stroke_w = maxf(3.0, stroke_w)

		# 随机选颜色并微调 — 使用完全不透明的颜色
		var base_col: Color = colors[rng.randi() % colors.size()]
		var col_var: float = stroke_color_var
		var col: Color = Color(
			clampf(base_col.r + rng.randf_range(-col_var, col_var), 0.0, 1.0),
			clampf(base_col.g + rng.randf_range(-col_var, col_var), 0.0, 1.0),
			clampf(base_col.b + rng.randf_range(-col_var, col_var), 0.0, 1.0),
			1.0  # 完全不透明
		)

		_draw_brush_stroke_opaque(img, sx, sy, ex, ey, stroke_w, rng, w, h, col)

	return ImageTexture.create_from_image(img)


func _draw_brush_stroke_opaque(img: Image, x0: float, y0: float, x1: float, y1: float, width: float, rng: RandomNumberGenerator, w: int, h: int, col: Color) -> void:
	var dx: float = x1 - x0
	var dy: float = y1 - y0
	var length: float = sqrt(dx * dx + dy * dy)
	if length < 0.5:
		return

	var ux: float = dx / length
	var uy: float = dy / length
	var px: float = -uy
	var py: float = ux

	var steps: int = maxi(1, int(length * 0.7))
	for s in range(steps + 1):
		var t: float = float(s) / float(steps)
		var cx: float = x0 + ux * (t * length)
		var cy: float = y0 + uy * (t * length)

		var taper: float = 1.0 - absf(t - 0.5) * 2.0
		taper = taper * taper * 0.7 + 0.3
		var half_w: float = width * taper * 0.5

		var rough_r: float = half_w * (1.0 + stroke_roughness * 0.8)
		var ir: int = maxi(1, int(ceil(rough_r)))

		for dy_off in range(-ir, ir + 1):
			for dx_off in range(-ir, ir + 1):
				var px_i: int = int(cx) + dx_off
				var py_i: int = int(cy) + dy_off
				if px_i < 0 or px_i >= w or py_i < 0 or py_i >= h:
					continue

				var dist: float = sqrt(float(dx_off * dx_off + dy_off * dy_off))
				var noise_factor: float = 1.0 + (rng.randf() - 0.5) * stroke_roughness * 0.6
				var effective_radius: float = half_w * noise_factor

				var cov: float = 1.0 - clampf(dist / effective_radius, 0.0, 1.0)
				if cov <= 0.02:
					continue

				# 笔迹内部颜色微变
				var shade: float = 1.0 + (rng.randf() - 0.5) * 0.15
				var pixel_col: Color = Color(
					clampf(col.r * shade, 0.0, 1.0),
					clampf(col.g * shade, 0.0, 1.0),
					clampf(col.b * shade, 0.0, 1.0),
					1.0  # 完全不透明
				)

				img.set_pixel(px_i, py_i, pixel_col)


func _add_guide_lines(poly: Polygon2D, pts: PackedVector2Array) -> void:
	if not show_guides:
		return

	var guide_name := "ThatchGuides_" + poly.name
	var parent := poly.get_parent()
	# 移除旧的辅助线
	var old := parent.get_node_or_null(guide_name)
	if old != null:
		old.queue_free()

	var guide_root := Node2D.new()
	guide_root.name = guide_name
	parent.add_child(guide_root)

	# 将多边形局部坐标转换到父级坐标空间
	# pts 是 poly 的局部坐标，而 guide_root 挂在 parent 下
	# 需要用 poly.position 偏移来对齐
	var offset := poly.position

	var n := pts.size()
	for i in range(n):
		var a := pts[i] + offset
		var b := pts[(i + 1) % n] + offset

		var line := Line2D.new()
		line.points = PackedVector2Array([a, b])
		line.default_color = guide_color
		line.width = guide_width
		line.z_index = poly.z_index + 1
		guide_root.add_child(line)


