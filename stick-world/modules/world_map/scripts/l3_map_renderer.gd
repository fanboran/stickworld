extends Node2D
class_name L3MapRenderer
## L3 大世界渲染器 —— 底图 + 13 地区分块描边 + hover 高亮
##
## 描边策略：
##   - 陆地轮廓（land_polygon）按地区实际边界画
##   - 隔海相邻对（sea_links）用质心连线直线画（用户要求：海洋上分界画直线）
## hover：鼠标位置解码分区索引图 -> 命中地区 -> 半透明高亮（overlay 混合）

var _data: L3WorldData = null
var _camera: MapCamera = null

## hover 命中的地区（Dictionary，未命中为空）
var hovered_region: Dictionary = {}

## hover 高亮色（暖橙，半透明）
const HIGHLIGHT_COLOR := Color(1.0, 0.75, 0.25, 0.35)

var _overlay_cache: ImageTexture = null
var _overlay_key: int = -1


func set_data(data: L3WorldData) -> void:
	_data = data
	queue_redraw()


func set_camera(camera: MapCamera) -> void:
	_camera = camera


func refresh() -> void:
	queue_redraw()


func _process(_delta: float) -> void:
	if not is_visible_in_tree() or _data == null:
		return
	var viewport := get_viewport()
	if viewport == null:
		return
	var mouse_pos: Vector2 = viewport.get_mouse_position()
	if _camera != null and _camera.has_method("screen_to_map"):
		mouse_pos = _camera.screen_to_map(mouse_pos)
	var query: Dictionary = _data.query_at_map_pos(mouse_pos)
	var region: Dictionary = query.get("region", {})
	var label: int = int(region.get("label", -1))
	if label != _overlay_key:
		_overlay_key = label
		_build_overlay(label)
		hovered_region = region
		queue_redraw()


## 预生成 hover 高亮层（仅选中地区半透明填充，其余透明）
func _build_overlay(label: int) -> void:
	if _data == null or _data.mask_image == null:
		_overlay_cache = null
		return
	var w: int = _data.mask_image.get_width()
	var h: int = _data.mask_image.get_height()
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	if label <= 0:
		_overlay_cache = ImageTexture.create_from_image(img)
		return
	var src: Image = _data.mask_image
	# 分区索引图 = label 直编：解码像素 == label 则高亮
	for y in range(h):
		for x in range(w):
			var px: Color = src.get_pixel(x, y)
			var code := (int(px.r * 255.0) << 16) | (int(px.g * 255.0) << 8) | int(px.b * 255.0)
			if code == label:
				img.set_pixel(x, y, Color(1.0, 0.75, 0.25, 0.35))
	_overlay_cache = ImageTexture.create_from_image(img)


func _draw() -> void:
	if _data == null:
		return
	# 1. 底图
	if _data.base_texture != null:
		draw_texture(_data.base_texture, Vector2.ZERO)
	# 2. 边界边缘图（像素级分界线，与 hover 高光边缘同源：
	#    陆地实际边界 + 海上归边延长线，即"地面+海洋一起分"的分界）
	if _data.border_texture != null:
		draw_texture(_data.border_texture, Vector2.ZERO)
	# 3. hover 高亮（半透明填充）
	if _overlay_cache != null:
		draw_texture_rect(_overlay_cache, Rect2(Vector2.ZERO, Vector2(_data.size, _data.size)), false)
