extends SceneTree
## 仅渲染 smithy_preview.tscn 的三个屋顶多边形，用于和 thatch_ref.png 对比
## 用法：godot --path project/ --script res://modules/building_gen/tools/render_roof_only.gd
## 不要加 --headless（SubViewport 需要真实渲染服务器）

const SCENE_PATH := "res://modules/building_gen/scenes/smithy_preview.tscn"
const OUT_PATH := "res://modules/building_gen/reference/roof_only_render.png"
const VIEWPORT_PATH := "res://modules/building_gen/reference/roof_only_viewport.png"
const TRANSPARENT_PATH := "res://modules/building_gen/reference/roof_only_transparent.png"

var _frame := 0
var _node: Node2D
var _sub: SubViewport
var _drawer: Node2D
var _draw_data: Array[Dictionary] = []

func _initialize() -> void:
	print("[RoofOnly] init")
	var scene: PackedScene = load(SCENE_PATH)
	if scene == null:
		push_error("无法加载场景: %s" % SCENE_PATH)
		quit(1)
		return

	_node = scene.instantiate()
	# 移除运行时 _ready 自动添加的 Camera2D（如果有）
	var cam := _node.get_node_or_null("Camera")
	if cam != null:
		_node.remove_child(cam)
		cam.queue_free()

	if _node.has_method("force_build"):
		print("[RoofOnly] force_build...")
		_node.force_build()
		print("[RoofOnly] force_build done")

	# 只保留 L5_Roof 子树
	var roof: Node2D = _node.get_node_or_null("L5_Roof")
	if roof == null:
		push_error("找不到 L5_Roof 节点")
		quit(1)
		return

	# 从 _node 中分离 L5_Roof
	_node.remove_child(roof)

	# 清理 L5_Roof 中的木梁/精灵等非 Polygon2D 节点，只保留茅草屋顶多边形
	_prune_non_polygons(roof)

	# 清理其余节点
	for child in _node.get_children():
		_node.remove_child(child)
		child.queue_free()
	_node.queue_free()
	_node = null

	# 收集绘制数据并保存调试用纹理（带父节点位置变换，确保渲染坐标 = 编辑器坐标）
	for item in _collect_with_transform(roof, Vector2.ZERO):
		print("[RoofOnly] poly=%s nverts=%d first_pt=%s uv0=%s" % [
			item["name"], item["polygon"].size(),
			item["polygon"][0] if item["polygon"].size() > 0 else "none",
			item["uv"][0] if item["uv"].size() > 0 else "none"
		])
		if item["texture"] != null and item["texture"] is ImageTexture:
			item["texture"].get_image().save_png("res://modules/building_gen/reference/debug_%s.png" % item["name"])
		_draw_data.append(item)

	# 计算包围盒
	var rect := _compute_rect_from_data(_draw_data)
	var pad := 24.0
	var view_size := Vector2i(int(rect.size.x + pad * 2.0), int(rect.size.y + pad * 2.0))
	if view_size.x < 100: view_size.x = 100
	if view_size.y < 100: view_size.y = 100

	# 将 polygon 本地坐标平移，使屋顶整体落入 viewport 可见区域
	var poly_offset := -rect.position + Vector2(pad, pad)
	for item in _draw_data:
		var shifted: PackedVector2Array = []
		for pt in item["polygon"]:
			shifted.append(pt + poly_offset)
		item["polygon"] = shifted

	# 释放原始 Polygon2D 节点，改用 Node2D + draw_polygon 渲染
	# 这样可以绕过 Godot Polygon2D 节点在 --script + SubViewport 下对透明纹理的渲染问题
	roof.queue_free()

	_drawer = Node2D.new()
	_drawer.name = "RoofDrawer"
	_drawer.draw.connect(_draw_roof)

	_sub = SubViewport.new()
	_sub.size = view_size
	_sub.transparent_bg = false
	_sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_sub.disable_3d = true
	root.add_child(_sub)
	_sub.add_child(_drawer)

	print("[RoofOnly] viewport=%s, rect=%s" % [view_size, rect])


func _draw_roof() -> void:
	for item in _draw_data:
		var poly: PackedVector2Array = item["polygon"]
		var uvs: PackedVector2Array = item["uv"]
		var tex: Texture2D = item["texture"]
		var col: Color = item["color"]
		var colors := PackedColorArray()
		colors.resize(poly.size())
		colors.fill(col)
		if tex != null and uvs.size() == poly.size():
			_drawer.draw_polygon(poly, colors, uvs, tex)
		else:
			_drawer.draw_polygon(poly, colors)


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame < 3:
		return false

	print("[RoofOnly] capturing frame %d" % _frame)
	var tex := _sub.get_texture()
	if tex == null:
		push_error("SubViewport texture is null")
		quit(1)
		return true

	var img: Image = tex.get_image()
	if img == null or img.is_empty():
		if _frame < 10:
			return false
		push_error("SubViewport image is null/empty after %d frames" % _frame)
		quit(1)
		return true

	if _frame == 3:
		var used := img.get_used_rect()
		var content_center := Vector2(used.position) + Vector2(used.size) / 2.0
		var view_center := Vector2(_sub.size) / 2.0
		var delta := view_center - content_center
		_drawer.position += delta
		print("[RoofOnly] auto-center delta=%s used=%s" % [delta, used])
		img.save_png(VIEWPORT_PATH)
		print("[RoofOnly] saved viewport %dx%d -> %s" % [img.get_width(), img.get_height(), VIEWPORT_PATH])
		_sub.transparent_bg = true
		_drawer.queue_redraw()
		return false

	if _frame == 4:
		img.save_png(TRANSPARENT_PATH)
		print("[RoofOnly] saved transparent full %dx%d -> %s" % [img.get_width(), img.get_height(), TRANSPARENT_PATH])
		_save_cropped(img)
		quit()
		return true

	return false


func _save_cropped(img: Image) -> void:
	var used := img.get_used_rect()
	print("[RoofOnly] used_rect=%s" % used)
	if used.size.x > 0 and used.size.y > 0:
		var crop := img.get_region(used)
		if crop.get_format() != img.get_format():
			crop.convert(img.get_format())
		var final := Image.create(used.size.x + 8, used.size.y + 8, false, img.get_format())
		final.fill(Color(0, 0, 0, 0))
		final.blit_rect(crop, Rect2i(0, 0, crop.get_width(), crop.get_height()), Vector2i(4, 4))
		final.save_png(OUT_PATH)
		print("[RoofOnly] saved cropped %dx%d -> %s" % [final.get_width(), final.get_height(), OUT_PATH])
	else:
		img.save_png(OUT_PATH)
		print("[RoofOnly] saved full %dx%d -> %s" % [img.get_width(), img.get_height(), OUT_PATH])


func _compute_rect_from_data(data: Array[Dictionary]) -> Rect2:
	var r := Rect2()
	var first := true
	for item in data:
		for pt in item["polygon"]:
			if first:
				r = Rect2(pt, Vector2.ZERO)
				first = false
			else:
				r = r.expand(pt)
	return r


func _collect(node: Node) -> Array:
	var arr := []
	_collect_recursive(node, arr)
	return arr


func _collect_recursive(node: Node, arr: Array) -> void:
	if node is Polygon2D:
		arr.append(node)
	for child in node.get_children():
		_collect_recursive(child, arr)


func _collect_with_transform(node: Node, parent_offset: Vector2) -> Array:
	var arr: Array = []
	_collect_tf(node, parent_offset, arr)
	return arr


func _collect_tf(node: Node, parent_offset: Vector2, arr: Array) -> void:
	var my_offset := parent_offset
	if node is Node2D:
		my_offset += node.position
	if node is Polygon2D:
		var shifted: PackedVector2Array = []
		for pt in node.polygon:
			shifted.append(pt + my_offset)
		arr.append({
			"polygon": shifted,
			"uv": node.uv.duplicate(),
			"texture": node.texture,
			"color": Color(1, 1, 1, 1),
			"name": node.name,
		})
		return
	for child in node.get_children():
		_collect_tf(child, my_offset, arr)


func _prune_non_polygons(node: Node) -> void:
	var to_remove: Array = []
	for child in node.get_children():
		if child is Polygon2D:
			_prune_non_polygons(child)
		elif _has_polygon_descendant(child):
			_prune_non_polygons(child)
		else:
			to_remove.append(child)
	for child in to_remove:
		node.remove_child(child)
		child.queue_free()


func _has_polygon_descendant(node: Node) -> bool:
	if node is Polygon2D:
		return true
	for child in node.get_children():
		if _has_polygon_descendant(child):
			return true
	return false
