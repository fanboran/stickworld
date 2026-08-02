class_name StickmanTextureGen
extends RefCounted
## 火柴人纹理生成器
## SSAA 超采样 + Lanczos 降采样抗锯齿

const SSAA: int = 4
const OUTPUT_SCALE: float = 4.0

enum Type { ROUND_SEG = 0, CIRCLE = 2, TRIANGLE = 3, ELLIPSE = 5 }


static func generate(node_type: int, length: int, thickness: int, color: Color) -> ImageTexture:
	match node_type:
		Type.ROUND_SEG:
			return _gen_pill(float(length), thickness, color)
		Type.CIRCLE:
			return _gen_circle(max(length, thickness * 2), color)
		Type.TRIANGLE:
			return _gen_tri(float(length), max(thickness, 2), color)
		Type.ELLIPSE:
			return _gen_ellipse(float(length), max(thickness, 4), color)
		_:
			return _gen_pill(float(length), thickness, color)


# ============================================================
#  各形状纹理生成
# ============================================================

static func _gen_pill(length: float, thickness: int, color: Color) -> ImageTexture:
	var w: int = int((max(int(length) + thickness, 4)) * OUTPUT_SCALE)
	var h: int = int(max(thickness, 4) * OUTPUT_SCALE)
	return ImageTexture.create_from_image(_draw_pill(w, h, thickness * int(OUTPUT_SCALE), color))


static func _gen_circle(diameter: int, color: Color) -> ImageTexture:
	var d: int = int(max(diameter, 4) * OUTPUT_SCALE)
	return ImageTexture.create_from_image(_draw_circle(d, color))


static func _gen_tri(length: float, thickness: int, color: Color) -> ImageTexture:
	var w: int = int(max(int(length), 4) * OUTPUT_SCALE)
	var h: int = int(max(thickness * 2, 8) * OUTPUT_SCALE)
	return ImageTexture.create_from_image(_draw_triangle(w, h, color))


static func _gen_ellipse(length: float, thickness: int, color: Color) -> ImageTexture:
	var w: int = int(max(int(length), 4) * OUTPUT_SCALE)
	var h: int = int(max(thickness, 4) * OUTPUT_SCALE)
	return ImageTexture.create_from_image(_draw_ellipse(w, h, color))


# ============================================================
#  SSAA 像素绘制
# ============================================================

static func _draw_pill(w: int, h: int, thickness: int, color: Color) -> Image:
	var sw: int = w * SSAA
	var sh: int = h * SSAA
	var st: int = thickness * SSAA
	var img := Image.create(sw, sh, false, Image.FORMAT_RGBA8)
	img.fill(Color(color.r, color.g, color.b, 0.0))
	var radius: float = st / 2.0
	var rect_left: float = radius
	var rect_right: float = sw - radius
	for py in range(sh):
		for px in range(sw):
			var alpha: float = _pill_coverage(float(px), float(py), radius, rect_left, rect_right, sh)
			if alpha > 0.0:
				img.set_pixel(px, py, Color(color.r, color.g, color.b, alpha * color.a))
	return _downscale(img, w, h)


static func _draw_circle(d: int, color: Color) -> Image:
	var sd: int = d * SSAA
	var img := Image.create(sd, sd, false, Image.FORMAT_RGBA8)
	img.fill(Color(color.r, color.g, color.b, 0.0))
	var cx: float = sd / 2.0
	var cy: float = sd / 2.0
	var radius: float = sd / 2.0
	for py in range(sd):
		for px in range(sd):
			var dist := Vector2(px + 0.5 - cx, py + 0.5 - cy).length()
			var alpha: float = clampf(radius - dist + 0.5, 0.0, 1.0)
			if alpha > 0.0:
				img.set_pixel(px, py, Color(color.r, color.g, color.b, alpha * color.a))
	return _downscale(img, d, d)


static func _draw_triangle(w: int, h: int, color: Color) -> Image:
	var sw: int = w * SSAA
	var sh: int = h * SSAA
	var img := Image.create(sw, sh, false, Image.FORMAT_RGBA8)
	img.fill(Color(color.r, color.g, color.b, 0.0))
	var p1 := Vector2(0.0, sh / 2.0)
	var p2 := Vector2(float(sw), 0.0)
	var p3 := Vector2(float(sw), float(sh))
	for py in range(sh):
		for px in range(sw):
			var pt := Vector2(float(px) + 0.5, float(py) + 0.5)
			if _point_in_tri(pt, p1, p2, p3):
				img.set_pixel(px, py, color)
	return _downscale(img, w, h)


static func _draw_ellipse(w: int, h: int, color: Color) -> Image:
	var sw: int = w * SSAA
	var sh: int = h * SSAA
	var img := Image.create(sw, sh, false, Image.FORMAT_RGBA8)
	img.fill(Color(color.r, color.g, color.b, 0.0))
	var rx: float = sw / 2.0
	var ry: float = sh / 2.0
	var cx: float = rx
	var cy: float = ry
	for py in range(sh):
		for px in range(sw):
			var dx: float = (px + 0.5 - cx) / rx
			var dy: float = (py + 0.5 - cy) / ry
			var d2: float = dx * dx + dy * dy
			var alpha: float = clampf((1.0 - d2) * 2.0, 0.0, 1.0)
			if alpha > 0.0:
				img.set_pixel(px, py, Color(color.r, color.g, color.b, alpha * color.a))
	return _downscale(img, w, h)


# ============================================================
#  数学辅助
# ============================================================

static func _pill_coverage(px: float, py: float, radius: float, rect_left: float, rect_right: float, sh: int) -> float:
	var cy: float = sh / 2.0
	if px >= rect_left and px <= rect_right:
		return clampf(radius - abs(py + 0.5 - cy) + 0.5, 0.0, 1.0)
	if px < rect_left:
		var dist := Vector2(px + 0.5 - rect_left, py + 0.5 - cy).length()
		return clampf(radius - dist + 0.5, 0.0, 1.0)
	var dist2 := Vector2(px + 0.5 - rect_right, py + 0.5 - cy).length()
	return clampf(radius - dist2 + 0.5, 0.0, 1.0)


static func _point_in_tri(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var d1: float = _sign2d(p, a, b)
	var d2: float = _sign2d(p, b, c)
	var d3: float = _sign2d(p, c, a)
	var has_neg: bool = (d1 < 0) or (d2 < 0) or (d3 < 0)
	var has_pos: bool = (d1 > 0) or (d2 > 0) or (d3 > 0)
	return not (has_neg and has_pos)


static func _sign2d(p1: Vector2, p2: Vector2, p3: Vector2) -> float:
	return (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y)


static func _downscale(img: Image, tw: int, th: int) -> Image:
	img.resize(tw, th, Image.INTERPOLATE_LANCZOS)
	return img


# ============================================================
#  类型字符串（用于烘焙 PNG 路径）
# ============================================================

static func type_str(node_type: int) -> String:
	match node_type:
		Type.ROUND_SEG: return "pill"
		Type.CIRCLE: return "circle"
		Type.TRIANGLE: return "tri"
		Type.ELLIPSE: return "ellipse"
		_: return "pill"