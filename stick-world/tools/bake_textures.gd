@tool
extends Node
## 从 stickman_rig.gd 的 SWL_SWORDWRATH 数据烘焙所有骨骼纹理为 PNG
##
## 运行方式:
##   godot --headless --path "f:/VSCode/game-2/stick-world" res://tools/bake_textures.tscn

const TYPE_ROUND_SEG: int = 0
const TYPE_CIRCLE: int = 2
const TYPE_TRIANGLE: int = 3
const TYPE_ELLIPSE: int = 5
const SSAA: int = 2

const SWL_SWORDWRATH: Dictionary = {
	0:  {"parent": -1, "x": 0.0,    "y": 0.0,    "length": 0,   "thickness": 0,  "type": -1},
	3:  {"parent": 0,  "x": 25.4,   "y": 60.9,   "length": 66,  "thickness": 23, "type": TYPE_ROUND_SEG},
	4:  {"parent": 3,  "x": 2.9,    "y": 68.9,   "length": 69,  "thickness": 23, "type": TYPE_ROUND_SEG},
	5:  {"parent": 4,  "x": 11.0,   "y": 0.0,    "length": 11,  "thickness": 23, "type": TYPE_ROUND_SEG},
	11: {"parent": 0,  "x": -4.8,   "y": 65.8,   "length": 66,  "thickness": 23, "type": TYPE_ROUND_SEG},
	12: {"parent": 11, "x": -16.9,  "y": 66.9,   "length": 69,  "thickness": 23, "type": TYPE_ROUND_SEG},
	13: {"parent": 12, "x": 11.0,   "y": -0.2,   "length": 11,  "thickness": 23, "type": TYPE_ROUND_SEG},
	6:  {"parent": 0,  "x": 1.8,    "y": -30.9,  "length": 31,  "thickness": 23, "type": TYPE_ROUND_SEG},
	7:  {"parent": 6,  "x": 5.7,    "y": -30.5,  "length": 31,  "thickness": 23, "type": TYPE_ROUND_SEG},
	8:  {"parent": 7,  "x": 10.4,   "y": -29.2,  "length": 31,  "thickness": 23, "type": TYPE_ROUND_SEG},
	1:  {"parent": 8,  "x": -34.7,  "y": 53.9,   "length": 64,  "thickness": 23, "type": TYPE_ROUND_SEG},
	2:  {"parent": 1,  "x": -3.1,   "y": 48.7,   "length": 49,  "thickness": 23, "type": TYPE_ROUND_SEG},
	14: {"parent": 8,  "x": 1.1,    "y": 64.1,   "length": 64,  "thickness": 23, "type": TYPE_ROUND_SEG},
	15: {"parent": 14, "x": 33.8,   "y": 35.2,   "length": 49,  "thickness": 23, "type": TYPE_ROUND_SEG},
	16: {"parent": 15, "x": 144.2,  "y": -91.9,  "length": 171, "thickness": 0,  "type": TYPE_ROUND_SEG},
	17: {"parent": 16, "x": -100.3, "y": 64.0,   "length": 119, "thickness": 18, "type": TYPE_TRIANGLE},
	18: {"parent": 17, "x": -28.7,  "y": 18.3,   "length": 34,  "thickness": 18, "type": TYPE_TRIANGLE},
	23: {"parent": 18, "x": 15.4,   "y": 24.2,   "length": 29,  "thickness": 18, "type": TYPE_TRIANGLE},
	22: {"parent": 18, "x": -15.4,  "y": -24.2,  "length": 29,  "thickness": 18, "type": TYPE_TRIANGLE},
	19: {"parent": 18, "x": -13.9,  "y": 8.9,    "length": 17,  "thickness": 7,  "type": TYPE_TRIANGLE},
	20: {"parent": 19, "x": -11.8,  "y": 7.5,    "length": 14,  "thickness": 7,  "type": TYPE_TRIANGLE},
	21: {"parent": 20, "x": -26.1,  "y": 16.7,   "length": 31,  "thickness": 14, "type": TYPE_ELLIPSE},
	9:  {"parent": 8,  "x": 19.9,   "y": -45.9,  "length": 50,  "thickness": 23, "type": TYPE_ROUND_SEG},
	10: {"parent": 9,  "x": -15.1,  "y": 34.8,   "length": 38,  "thickness": 23, "type": TYPE_CIRCLE},
}

const BODY_COLOR := Color(0.82, 0.82, 0.85, 1.0)
const WEAPON_COLOR := Color(0.72, 0.74, 0.78, 1.0)
const GUARD_COLOR := Color(0.65, 0.45, 0.18, 1.0)
const OUTPUT_DIR := "res://assets/textures/stickman/"


func _ready() -> void:
	print("=== 开始烘焙 StickmanRig 纹理 ===")
	DirAccess.make_dir_recursive_absolute(OUTPUT_DIR)

	for id in SWL_SWORDWRATH.keys():
		if id == 0:
			continue
		var data: Dictionary = SWL_SWORDWRATH[id]
		var node_type: int = data["type"]
		var length: int = data["length"]
		var thickness: int = data["thickness"]
		var color := _get_color_for_type(node_type)

		var tex_name := "bone_%d_%s.png" % [id, _type_name(node_type)]
		var tex := _generate_texture(node_type, length, thickness, color)
		if tex == null:
			print("  SKIP bone_%d: 纹理生成失败" % id)
			continue

		var path := OUTPUT_DIR + tex_name
		var img := tex.get_image()
		var err := img.save_png(path)
		if err == OK:
			print("  OK  %s  (%dx%d, len=%d, thick=%d)" % [tex_name, img.get_width(), img.get_height(), length, thickness])
		else:
			print("  ERR bone_%d: 保存失败 (err=%d)" % [id, err])

	print("=== 烘焙完成 ===")
	get_tree().quit(0)


func _get_color_for_type(node_type: int) -> Color:
	match node_type:
		TYPE_TRIANGLE:
			return WEAPON_COLOR
		TYPE_ELLIPSE:
			return GUARD_COLOR
		_:
			return BODY_COLOR


func _type_name(t: int) -> String:
	match t:
		TYPE_ROUND_SEG: return "pill"
		TYPE_CIRCLE: return "circle"
		TYPE_TRIANGLE: return "tri"
		TYPE_ELLIPSE: return "ellipse"
	return "unk"


func _generate_texture(node_type: int, length: int, thickness: int, color: Color) -> ImageTexture:
	match node_type:
		TYPE_ROUND_SEG:
			return _generate_pill_texture(float(length), thickness, color)
		TYPE_CIRCLE:
			return _generate_circle_texture(max(length, thickness * 2), color)
		TYPE_TRIANGLE:
			return _generate_triangle_texture(float(length), max(thickness, 2), color)
		TYPE_ELLIPSE:
			return _generate_ellipse_texture(float(length), max(thickness, 4), color)
		_:
			return _generate_pill_texture(float(length), thickness, color)


# ============================================================
#  纹理生成（复制自 stickman_rig.gd）
# ============================================================

func _generate_pill_texture(length: float, thickness: int, color: Color) -> ImageTexture:
	var w: int = max(int(length) + thickness, 4)
	var h: int = max(thickness, 4)
	var img := _draw_pill_ssaa(w, h, thickness, color)
	return ImageTexture.create_from_image(img)


func _generate_circle_texture(diameter: int, color: Color) -> ImageTexture:
	var d: int = max(diameter, 4)
	var img := _draw_circle_ssaa(d, color)
	return ImageTexture.create_from_image(img)


func _generate_triangle_texture(length: float, thickness: int, color: Color) -> ImageTexture:
	var w: int = max(int(length), 4)
	var h: int = max(thickness * 2, 8)
	var img := _draw_triangle_ssaa(w, h, color)
	return ImageTexture.create_from_image(img)


func _generate_ellipse_texture(length: float, thickness: int, color: Color) -> ImageTexture:
	var w: int = max(int(length), 4)
	var h: int = max(thickness, 4)
	var img := _draw_ellipse_ssaa(w, h, color)
	return ImageTexture.create_from_image(img)


func _draw_pill_ssaa(w: int, h: int, thickness: int, color: Color) -> Image:
	var sw: int = w * SSAA
	var sh: int = h * SSAA
	var st: int = thickness * SSAA
	var img := Image.create(sw, sh, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var radius: float = st / 2.0
	var rect_left: float = radius
	var rect_right: float = sw - radius
	for py in range(sh):
		for px in range(sw):
			var alpha: float = _pill_coverage(float(px), float(py), radius, rect_left, rect_right, sh)
			if alpha > 0.0:
				img.set_pixel(px, py, Color(color.r, color.g, color.b, alpha * color.a))
	return _downscale_lanczos(img, w, h)


func _draw_circle_ssaa(d: int, color: Color) -> Image:
	var sd: int = d * SSAA
	var img := Image.create(sd, sd, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var cx: float = sd / 2.0
	var cy: float = sd / 2.0
	var radius: float = sd / 2.0
	for py in range(sd):
		for px in range(sd):
			var dist := Vector2(px + 0.5 - cx, py + 0.5 - cy).length()
			var alpha: float = clampf(radius - dist + 0.5, 0.0, 1.0)
			if alpha > 0.0:
				img.set_pixel(px, py, Color(color.r, color.g, color.b, alpha * color.a))
	return _downscale_lanczos(img, d, d)


func _draw_triangle_ssaa(w: int, h: int, color: Color) -> Image:
	var sw: int = w * SSAA
	var sh: int = h * SSAA
	var img := Image.create(sw, sh, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var p1 := Vector2(0.0, sh / 2.0)
	var p2 := Vector2(float(sw), 0.0)
	var p3 := Vector2(float(sw), float(sh))
	for py in range(sh):
		for px in range(sw):
			var pt := Vector2(float(px) + 0.5, float(py) + 0.5)
			if _point_in_triangle(pt, p1, p2, p3):
				img.set_pixel(px, py, color)
	return _downscale_lanczos(img, w, h)


func _draw_ellipse_ssaa(w: int, h: int, color: Color) -> Image:
	var sw: int = w * SSAA
	var sh: int = h * SSAA
	var img := Image.create(sw, sh, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rx: float = sw / 2.0
	var ry: float = sh / 2.0
	var cx: float = rx
	var cy: float = ry
	for py in range(sh):
		for px in range(sw):
			var dx: float = (px + 0.5 - cx) / rx
			var dy: float = (py + 0.5 - cy) / ry
			var d: float = dx * dx + dy * dy
			var edge: float = 1.0 - d
			var alpha: float = clampf(edge * 2.0, 0.0, 1.0)
			if alpha > 0.0:
				img.set_pixel(px, py, Color(color.r, color.g, color.b, alpha * color.a))
	return _downscale_lanczos(img, w, h)


static func _pill_coverage(px: float, py: float, radius: float, rect_left: float, rect_right: float, sh: int) -> float:
	var cy: float = sh / 2.0
	if px >= rect_left and px <= rect_right:
		var dy: float = abs(py + 0.5 - cy)
		return clampf(radius - dy + 0.5, 0.0, 1.0)
	if px < rect_left:
		var dist := Vector2(px + 0.5 - rect_left, py + 0.5 - cy).length()
		return clampf(radius - dist + 0.5, 0.0, 1.0)
	var dist2 := Vector2(px + 0.5 - rect_right, py + 0.5 - cy).length()
	return clampf(radius - dist2 + 0.5, 0.0, 1.0)


static func _point_in_triangle(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var d1: float = _sign2d(p, a, b)
	var d2: float = _sign2d(p, b, c)
	var d3: float = _sign2d(p, c, a)
	var has_neg: bool = (d1 < 0) or (d2 < 0) or (d3 < 0)
	var has_pos: bool = (d1 > 0) or (d2 > 0) or (d3 > 0)
	return not (has_neg and has_pos)


static func _sign2d(p1: Vector2, p2: Vector2, p3: Vector2) -> float:
	return (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y)


static func _downscale_lanczos(img: Image, target_w: int, target_h: int) -> Image:
	img.resize(target_w, target_h, Image.INTERPOLATE_LANCZOS)
	return img
