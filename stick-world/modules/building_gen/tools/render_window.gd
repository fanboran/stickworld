extends SceneTree
## 用 SubViewport 渲染 smithy_preview.tscn 为 PNG（匹配编辑器预览，无窗口装饰干扰）
## 用法：godot --path project/ --script res://modules/building_gen/tools/render_window.gd
## 注意：Godot 4 的 --headless 使用 Dummy 渲染服务器，无法从 SubViewport 获取图像，
##       因此不要加 --headless。脚本会在保存图片后自动 quit。

const SCENE_PATH := "res://modules/building_gen/scenes/smithy_preview.tscn"
const OUT_PATH := "res://modules/building_gen/reference/smithy_preview_render.png"
const VIEWPORT_PATH := "res://modules/building_gen/reference/smithy_preview_viewport.png"
const TRANSPARENT_PATH := "res://modules/building_gen/reference/smithy_preview_transparent.png"

var _frame := 0
var _node: Node2D
var _sub: SubViewport

func _initialize() -> void:
	print("[RenderWindow] init")
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

	# 计算包围盒
	var rect := _compute_rect(_node)
	var pad := 20.0
	var view_size := Vector2i(int((rect.size.x + pad * 2.0)), int((rect.size.y + pad * 2.0)))
	if view_size.x < 100: view_size.x = 100
	if view_size.y < 100: view_size.y = 100

	# 创建 SubViewport，完全避开主窗口的装饰、拉伸、canvas transform 干扰
	_sub = SubViewport.new()
	_sub.size = view_size
	_sub.transparent_bg = false
	_sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_sub.disable_3d = true
	root.add_child(_sub)

	# 居中场景
	_node.position = -rect.position + Vector2(pad, pad)
	_sub.add_child(_node)

	print("[RenderWindow] viewport=%s, scene_pos=%s, rect=%s" % [view_size, _node.position, rect])


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame < 3:
		return false

	print("[RenderWindow] capturing frame %d" % _frame)
	var tex := _sub.get_texture()
	if tex == null:
		push_error("SubViewport texture is null")
		quit(1)
		return true

	var img: Image = tex.get_image()
	if img == null or img.is_empty():
		push_error("SubViewport image is null/empty")
		quit(1)
		return true

	if _frame == 3:
		# 第一帧：根据实际渲染的 content 边界自动居中，然后保存完整视口
		var used := img.get_used_rect()
		var content_center := Vector2(used.position) + Vector2(used.size) / 2.0
		var view_center := Vector2(_sub.size) / 2.0
		var delta := view_center - content_center
		_node.position += delta
		print("[RenderWindow] auto-center delta=%s used=%s" % [delta, used])
		# 保存居中后的完整视口（灰色背景 + 辅助线）
		img.save_png(VIEWPORT_PATH)
		print("[RenderWindow] saved viewport %dx%d -> %s" % [img.get_width(), img.get_height(), VIEWPORT_PATH])
		# 切换到透明无辅助线模式
		_sub.transparent_bg = true
		_node.set_meta("no_guides", true)
		_node.queue_redraw()
		return false

	if _frame == 4:
		# 第二帧：保存完整透明 viewport（诊断用）
		img.save_png(TRANSPARENT_PATH)
		print("[RenderWindow] saved transparent full %dx%d -> %s" % [img.get_width(), img.get_height(), TRANSPARENT_PATH])
		# 再保存透明背景、无辅助线的裁剪版
		_save_cropped(img)
		quit()
		return true

	return false


func _save_cropped(img: Image) -> void:
	var used := img.get_used_rect()
	print("[RenderWindow] used_rect=%s" % used)
	if used.size.x > 0 and used.size.y > 0:
		var crop := img.get_region(used)
		if crop.get_format() != img.get_format():
			crop.convert(img.get_format())
		var final := Image.create(used.size.x + 8, used.size.y + 8, false, img.get_format())
		final.fill(Color(0, 0, 0, 0))
		final.blit_rect(crop, Rect2i(0, 0, crop.get_width(), crop.get_height()), Vector2i(4, 4))
		final.save_png(OUT_PATH)
		print("[RenderWindow] saved cropped %dx%d -> %s" % [final.get_width(), final.get_height(), OUT_PATH])
	else:
		img.save_png(OUT_PATH)
		print("[RenderWindow] saved full %dx%d -> %s" % [img.get_width(), img.get_height(), OUT_PATH])


func _compute_rect(node: Node) -> Rect2:
	var r := Rect2()
	for child in _collect(node):
		if child is Sprite2D:
			var tex = child.texture
			if tex == null: continue
			var ts: Vector2 = tex.get_size() * child.scale
			var offset = ts * 0.5 if child.centered else Vector2.ZERO
			var pos: Vector2 = child.position - offset
			r = r.expand(pos)
			r = r.expand(pos + ts)
		elif child is Polygon2D:
			for pt in child.polygon:
				r = r.expand(child.position + pt * child.scale)
	return r


func _collect(node: Node) -> Array:
	var arr := []
	_collect_recursive(node, arr)
	return arr


func _collect_recursive(node: Node, arr: Array) -> void:
	if node is Sprite2D or node is Polygon2D:
		arr.append(node)
	for child in node.get_children():
		_collect_recursive(child, arr)
