extends SceneTree
## 直接渲染 smithy_reference.tscn 为 PNG，用于对比正确位置

const SCENE_PATH := "res://modules/building_gen/scenes/smithy_reference.tscn"
const OUT_PATH := "res://modules/building_gen/reference/smithy_reference_render.png"

func _initialize() -> void:
	var scene: PackedScene = load(SCENE_PATH)
	if scene == null:
		push_error("无法加载场景: %s" % SCENE_PATH)
		quit(1)
		return
	var node: Node2D = scene.instantiate()
	root.add_child(node)

	var render_scale := 2.5
	var canvas := _render_to_image(node, render_scale)
	canvas.save_png(OUT_PATH)
	print("OK: " + ProjectSettings.globalize_path(OUT_PATH))
	quit()


func _render_to_image(root: Node2D, scale: float) -> Image:
	var nodes := _collect(root)
	var rect := Rect2()
	for item in nodes:
		rect = rect.merge(_item_rect(item))
	if rect.size.x <= 0 or rect.size.y <= 0:
		rect = Rect2(-400, -500, 800, 600)

	var pad := 20.0
	var canvas_pos := Vector2i(int((-rect.position.x + pad) * scale), int((-rect.position.y + pad) * scale))
	var cw := int((rect.size.x + pad * 2.0) * scale)
	var ch := int((rect.size.y + pad * 2.0) * scale)
	var canvas := Image.create(cw, ch, false, Image.FORMAT_RGBA8)
	canvas.fill(Color(0, 0, 0, 0))

	_draw_node_recursive(root, canvas, canvas_pos, scale, Vector2.ZERO, 0.0, Vector2.ONE)
	return canvas


func _draw_node_recursive(node: Node, canvas: Image, canvas_pos: Vector2i,
		parent_scale: float, parent_pos: Vector2, parent_rot: float, parent_local_scale: Vector2) -> void:
	if node is Node2D:
		var n2d: Node2D = node
		var gpos := parent_pos + n2d.position.rotated(parent_rot) * parent_local_scale
		var gscale := parent_local_scale * n2d.scale
		var grot := parent_rot + n2d.rotation
		var final_scale := parent_scale * n2d.scale.x

		if node is Sprite2D:
			_draw_sprite(canvas, n2d, canvas_pos, final_scale, gpos, grot)
		elif node is Polygon2D:
			_draw_polygon(canvas, n2d, canvas_pos, final_scale, gpos, grot)

		for child in node.get_children():
			_draw_node_recursive(child, canvas, canvas_pos, parent_scale, gpos, grot, gscale)


func _draw_sprite(canvas: Image, s: Sprite2D, canvas_pos: Vector2i, scale: float, gpos: Vector2, grot: float) -> void:
	var tex = s.texture
	if tex == null:
		return
	var img: Image = tex.get_image()
	if img == null or img.is_empty():
		return
	var src_size := Vector2(img.get_width(), img.get_height())
	var dst_w := maxi(1, int(src_size.x * scale))
	var dst_h := maxi(1, int(src_size.y * scale))
	var scaled := img.duplicate()
	scaled.resize(dst_w, dst_h, Image.INTERPOLATE_BILINEAR)
	var offset := (Vector2(dst_w, dst_h) * 0.5) if s.centered else Vector2.ZERO
	var dst_pos := Vector2i(int((gpos.x - offset.x) * scale + canvas_pos.x),
			int((gpos.y - offset.y) * scale + canvas_pos.y))
	canvas.blit_rect(scaled, Rect2i(0, 0, dst_w, dst_h), dst_pos)


func _draw_polygon(canvas: Image, p: Polygon2D, canvas_pos: Vector2i, scale: float, gpos: Vector2, grot: float) -> void:
	var tex = p.texture
	if tex == null:
		return
	var img: Image = tex.get_image()
	if img == null or img.is_empty():
		return
	var src_w := img.get_width()
	var src_h := img.get_height()
	var poly: PackedVector2Array = p.polygon
	var uvs: PackedVector2Array = p.uv
	if uvs.size() != poly.size():
		return

	var min_x := 1e9
	var max_x := -1e9
	var min_y := 1e9
	var max_y := -1e9
	for i in range(poly.size()):
		var wp := gpos + poly[i].rotated(grot) * p.scale
		var sp := Vector2(wp.x * scale + canvas_pos.x, wp.y * scale + canvas_pos.y)
		min_x = minf(min_x, sp.x)
		max_x = maxf(max_x, sp.x)
		min_y = minf(min_y, sp.y)
		max_y = maxf(max_y, sp.y)
	var ix0 := maxi(0, int(min_x) - 1)
	var ix1 := mini(canvas.get_width() - 1, int(max_x) + 1)
	var iy0 := maxi(0, int(min_y) - 1)
	var iy1 := mini(canvas.get_height() - 1, int(max_y) + 1)

	for y in range(iy0, iy1 + 1):
		for x in range(ix0, ix1 + 1):
			var sp := Vector2(x, y)
			var lp := (sp - Vector2(canvas_pos)) / scale - gpos
			lp = lp.rotated(-grot)
			if not _point_in_polygon(lp, poly):
				continue
			var uv := _interpolate_uv(lp, poly, uvs)
			var sx := clampi(int(uv.x), 0, src_w - 1)
			var sy := clampi(int(uv.y), 0, src_h - 1)
			var c := img.get_pixel(sx, sy)
			if c.a > 0.0:
				canvas.set_pixel(x, y, c)


func _interpolate_uv(p: Vector2, poly: PackedVector2Array, uvs: PackedVector2Array) -> Vector2:
	for i in range(2, poly.size()):
		var a := poly[0]
		var b := poly[i - 1]
		var c := poly[i]
		var wa := _barycentric(p, a, b, c)
		if wa.x >= -0.001 and wa.y >= -0.001 and wa.z >= -0.001:
			var ua := uvs[0]
			var ub := uvs[i - 1]
			var uc := uvs[i]
			return ua * wa.x + ub * wa.y + uc * wa.z
	return uvs[0]


func _barycentric(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> Vector3:
	var v0 := b - a
	var v1 := c - a
	var v2 := p - a
	var d00 := v0.dot(v0)
	var d01 := v0.dot(v1)
	var d11 := v1.dot(v1)
	var d20 := v2.dot(v0)
	var d21 := v2.dot(v1)
	var denom := d00 * d11 - d01 * d01
	if abs(denom) < 1e-9:
		return Vector3(-1, -1, -1)
	var v := (d11 * d20 - d01 * d21) / denom
	var w := (d00 * d21 - d01 * d20) / denom
	var u := 1.0 - v - w
	return Vector3(u, v, w)


func _point_in_polygon(p: Vector2, poly: PackedVector2Array) -> bool:
	var inside := false
	var j := poly.size() - 1
	for i in range(poly.size()):
		var vi := poly[i]
		var vj := poly[j]
		if ((vi.y > p.y) != (vj.y > p.y)) and (p.x < (vj.x - vi.x) * (p.y - vi.y) / (vj.y - vi.y) + vi.x):
			inside = not inside
		j = i
	return inside


func _collect(root: Node) -> Array:
	var arr := []
	_collect_recursive(root, arr)
	return arr


func _collect_recursive(node: Node, arr: Array) -> void:
	if node is Sprite2D or node is Polygon2D:
		arr.append(node)
	for child in node.get_children():
		_collect_recursive(child, arr)


func _item_rect(item: Node2D) -> Rect2:
	if item is Sprite2D:
		var s: Sprite2D = item
		if s.texture == null:
			return Rect2(s.position, Vector2.ZERO)
		var ts := s.texture.get_size() * s.scale
		var offset := ts * 0.5 if s.centered else Vector2.ZERO
		return Rect2(s.position - offset, ts)
	elif item is Polygon2D:
		var p: Polygon2D = item
		var r := Rect2()
		for pt in p.polygon:
			r = r.expand(p.position + pt * p.scale)
		return r
	return Rect2(item.position, Vector2.ZERO)
