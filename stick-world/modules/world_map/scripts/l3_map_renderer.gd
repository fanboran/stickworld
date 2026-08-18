extends Node2D
class_name L3MapRenderer
## L3 大世界渲染器 —— 静态几何缓存（ArrayMesh）+ hover 老 L1 高亮 + 双显示模式
##
## 显示模式（模式按钮切换，见 l3_zoom_indicator）：
##   MODE_L1   : 底 = 69 块老 L1 地块（鲜艳配色）
##   MODE_CITY : 底 = 1038 块城市（像 city_preview 花花绿绿）
## hover 恒命中老 L1 索引图（label 直编）；点击下钻仍按 L2（L3MapController 用 L2 索引图）。
## 性能：两级 mesh 加载时一次性烘焙，每帧按模式 draw_mesh。

enum DisplayMode { MODE_L1, MODE_CITY }

var _data: L3WorldData = null
var _camera: MapCamera = null

## 当前显示模式
var display_mode: int = DisplayMode.MODE_L1

## hover 命中的老 L1（Dictionary，未命中为空）
var hovered_l1: Dictionary = {}

## hover 高亮色（黄）
const HOVER_COLOR := Color(1.0, 0.9, 0.3, 0.95)
const EDGE_WIDTH := 5.0
const MIN_SCREEN_PX := 2.0

## 海洋背景色
const OCEAN_COLOR := Color(30.0 / 255.0, 55.0 / 255.0, 95.0 / 255.0)
## L2 地区常驻描边（标识可下钻单元）
const L2_BORDER_COLOR := Color(0.14, 0.14, 0.14, 0.85)
## L2 地区编号（F3 调试模式）
const L2_LABEL_COLOR := Color(1.0, 0.9, 0.3, 0.95)
const L2_LABEL_BG := Color(0.0, 0.0, 0.0, 0.75)
const L2_LABEL_SIZE := 40.0

var _l1_mesh: ArrayMesh = null
var _l1_holes_mesh: ArrayMesh = null
var _debug_was_visible: bool = false


func set_data(data: L3WorldData) -> void:
	_data = data
	_build_static_meshes()
	queue_redraw()


func get_data() -> L3WorldData:
	return _data


func set_camera(camera: MapCamera) -> void:
	_camera = camera


func refresh() -> void:
	queue_redraw()


## 切换显示模式（L1 <-> 城市），返回新模式
func toggle_display_mode() -> int:
	display_mode = DisplayMode.MODE_CITY if display_mode == DisplayMode.MODE_L1 else DisplayMode.MODE_L1
	queue_redraw()
	return display_mode


func set_display_mode(mode: int) -> void:
	display_mode = mode
	queue_redraw()


func get_mode_name() -> String:
	return "城市" if display_mode == DisplayMode.MODE_CITY else "L1"


## 一次性构建静态网格：老 L1 矢量 mesh（城市模式用栅格贴图，见 _draw）
func _build_static_meshes() -> void:
	_l1_mesh = null
	_l1_holes_mesh = null
	if _data == null:
		return
	var built: Array = _build_layer_mesh(_data.l1_tiles)
	if built[0] != null:
		_l1_mesh = built[0]
	if built[1] != null:
		_l1_holes_mesh = built[1]


func _build_layer_mesh(tiles: Array) -> Array:
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var hverts := PackedVector3Array()
	var hcols := PackedColorArray()
	var hindices := PackedInt32Array()
	for t in tiles:
		var col: Array = t.get("color", [])
		var fill := Color(0.6, 0.7, 0.8)
		if col.size() >= 3:
			fill = Color(col[0] / 255.0, col[1] / 255.0, col[2] / 255.0)
		for poly in t.get("polygons", []):
			if (poly as Array).size() < 3:
				continue
			var pts2 := PackedVector2Array()
			for p in poly:
				pts2.append(Vector2(p[1], p[0]))
			var tri := Geometry2D.triangulate_polygon(pts2)
			if tri.is_empty():
				continue
			var base := verts.size()
			for v in pts2:
				verts.append(Vector3(v.x, v.y, 0.0))
				colors.append(fill)
			for idx in tri:
				indices.append(base + idx)
		# 洞
		for hole in t.get("holes", []):
			if (hole as Array).size() < 3:
				continue
			var hpts := PackedVector2Array()
			for p in hole:
				hpts.append(Vector2(p[1], p[0]))
			var htri := Geometry2D.triangulate_polygon(hpts)
			if htri.is_empty():
				continue
			var hb := hverts.size()
			for v in hpts:
				hverts.append(Vector3(v.x, v.y, 0.0))
				hcols.append(OCEAN_COLOR)
			for idx in htri:
				hindices.append(hb + idx)
	var fill_mesh: ArrayMesh = null
	var holes_mesh: ArrayMesh = null
	if not verts.is_empty():
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = verts
		arr[Mesh.ARRAY_COLOR] = colors
		arr[Mesh.ARRAY_INDEX] = indices
		fill_mesh = ArrayMesh.new()
		fill_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	if not hverts.is_empty():
		var harr := []
		harr.resize(Mesh.ARRAY_MAX)
		harr[Mesh.ARRAY_VERTEX] = hverts
		harr[Mesh.ARRAY_COLOR] = hcols
		harr[Mesh.ARRAY_INDEX] = hindices
		holes_mesh = ArrayMesh.new()
		holes_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, harr)
	return [fill_mesh, holes_mesh]


func _process(_delta: float) -> void:
	if not visible or _data == null:
		return
	var viewport := get_viewport()
	if viewport == null:
		return
	var mouse_pos: Vector2 = viewport.get_mouse_position()
	if _camera != null and _camera.has_method("screen_to_map"):
		mouse_pos = _camera.screen_to_map(mouse_pos)
	# 渲染坐标（8192 级网格）-> 索引图坐标（2048 级查询）；hover 恒老 L1 索引图
	if _data.l1_index_image != null and _data.size > 0:
		mouse_pos *= float(_data.l1_index_image.get_width()) / float(_data.size)
	var query: Dictionary = _data.query_l1_at_map_pos(mouse_pos)
	var l1: Dictionary = query.get("l1", {})
	if int(l1.get("label", -1)) != int(hovered_l1.get("label", -1)):
		hovered_l1 = l1
		queue_redraw()
	# F3 调试模式变化时刷新（L2 编号显隐）
	var debug_now: bool = DebugApi != null and DebugApi.is_visible()
	if debug_now != _debug_was_visible:
		_debug_was_visible = debug_now
		queue_redraw()


func _draw() -> void:
	if _data == null:
		return
	# 1. 海洋背景
	draw_rect(Rect2(Vector2.ZERO, Vector2(float(_data.size), float(_data.size))), OCEAN_COLOR)
	if display_mode == DisplayMode.MODE_CITY:
		# 城市模式：直接贴 city_preview 栅格图（花花绿绿、零剖分、快）
		if _data.city_preview_texture != null:
			draw_texture_rect(_data.city_preview_texture,
				Rect2(Vector2.ZERO, Vector2(float(_data.size), float(_data.size))), false)
		# 城市贴图像素是 2048 级，L2 边界/ hover 坐标在 8192 级 → 贴图拉伸到 8192 自带对齐
	else:
		# 2. 老 L1 模式：矢量 mesh
		if _l1_mesh != null:
			draw_mesh(_l1_mesh, null)
		if _l1_holes_mesh != null:
			draw_mesh(_l1_holes_mesh, null)
	# 3. L2 地区常驻描边（标识可下钻单元）
	_draw_l2_borders()
	# 4. hover 老 L1 高亮（黄线轮廓）
	_draw_hover_l1()
	# 5. L2 地区编号（F3 调试模式）
	if DebugApi != null and DebugApi.is_visible():
		_draw_l2_labels()


func _draw_l2_borders() -> void:
	var bw := BORDER_WIDTH()
	for r in _data.regions:
		for poly in r.get("land_polygons", [r.get("land_polygon", [])]):
			if (poly as Array).size() < 3:
				continue
			var bpts := PackedVector2Array()
			for pp in poly:
				bpts.append(Vector2(pp[1], pp[0]))
			bpts.append(bpts[0])
			draw_polyline(bpts, L2_BORDER_COLOR, bw, true)


func BORDER_WIDTH() -> float:
	var w := 9.0
	if _camera != null and _camera.has_method("get_zoom"):
		var z: float = _camera.get_zoom()
		if z > 0.0001:
			w = maxf(w, MIN_SCREEN_PX / z)
	return w


func _draw_hover_l1() -> void:
	if hovered_l1.is_empty():
		return
	var hpolys: Array = hovered_l1.get("polygons", [])
	for hp in hpolys:
		if (hp as Array).size() < 3:
			continue
		var hpts := PackedVector2Array()
		for pp in hp:
			hpts.append(Vector2(pp[1], pp[0]))
		hpts.append(hpts[0])
		var hw := EDGE_WIDTH
		if _camera != null and _camera.has_method("get_zoom"):
			var z: float = _camera.get_zoom()
			if z > 0.0001:
				hw = maxf(EDGE_WIDTH, MIN_SCREEN_PX / z)
		draw_polyline(hpts, HOVER_COLOR, hw, true)


## F3 调试：给每个 L2 地区打编号（地区质心；centroid 2048 级 × size/mask 比例）
func _draw_l2_labels() -> void:
	var font := ThemeDB.fallback_font
	var scale := 1.0
	if _data.size > 0 and _data.mask_image != null:
		scale = float(_data.size) / float(_data.mask_image.get_width())
	for r in _data.regions:
		var label: int = int(r.get("label", 0))
		if label <= 0:
			continue
		var c: Array = r.get("centroid", [0, 0])
		if c.size() < 2:
			continue
		var pos := Vector2(float(c[0]), float(c[1])) * scale
		var txt := "L2#%d" % label
		for off in [Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1)]:
			draw_string(font, pos + off * 2.0, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, L2_LABEL_SIZE, L2_LABEL_BG)
		draw_string(font, pos + Vector2(4.0, -L2_LABEL_SIZE * 0.3), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, L2_LABEL_SIZE, L2_LABEL_COLOR)