extends Node2D
class_name L2MapRenderer
## L2 地区渲染器 —— 静态几何缓存（ArrayMesh）+ hover 灰色描边
##
## 性能方案（Godot 官方推荐）：
##  - 地块几何在 set_data 时一次性三角剖分，构建 ArrayMesh（顶点+颜色+索引）
##  - 每帧仅 1 次 draw_mesh（零 CPU 三角剖分）——解决每帧 draw_colored_polygon 卡顿
##  - 洞（C 形地块内海洋）数量少，每帧直接覆盖海洋色
##  - hover 描边用 draw_polyline（单条，开销可忽略）
## 索引图仅用于 hover 像素查询（不动）

var _data: L2WorldData = null
var _camera: MapCamera = null

## hover 命中的地块（Dictionary，未命中为空）
var hovered_tile: Dictionary = {}

## hover 描边色（灰色）
const EDGE_COLOR := Color(0.55, 0.55, 0.55)
const EDGE_WIDTH := 5.0          # 地图单位线宽（与地块比例恒定，放大不显细）
const MIN_SCREEN_PX := 2.0       # 最小屏幕像素线宽（缩小保底，细到看不见）

## 海洋背景色
const OCEAN_COLOR := Color(30.0 / 255.0, 55.0 / 255.0, 95.0 / 255.0)

var _static_mesh: ArrayMesh = null
var _holes_mesh: ArrayMesh = null   # 洞挖空（海洋色，预剖分）


func set_data(data: L2WorldData) -> void:
	_data = data
	_build_static_mesh()
	queue_redraw()


func set_camera(camera: MapCamera) -> void:
	_camera = camera


func refresh() -> void:
	queue_redraw()


## 一次性构建静态网格（所有地块合并为单个 ArrayMesh）
func _build_static_mesh() -> void:
	_static_mesh = null
	_holes_mesh = null
	if _data == null:
		return
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var hverts := PackedVector3Array()
	var hcols := PackedColorArray()
	var hindices := PackedInt32Array()
	for t in _data.tiles:
		var col: Array = t.get("color", [])
		var fill := Color(0.6, 0.7, 0.8)
		if col.size() >= 3:
			fill = Color(col[0] / 255.0, col[1] / 255.0, col[2] / 255.0)
		# 外轮廓 -> 三角剖分
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
		# 洞 -> 预剖分（海洋色覆盖）
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
	if not verts.is_empty():
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = verts
		arr[Mesh.ARRAY_COLOR] = colors
		arr[Mesh.ARRAY_INDEX] = indices
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		_static_mesh = mesh
	if not hverts.is_empty():
		var harr := []
		harr.resize(Mesh.ARRAY_MAX)
		harr[Mesh.ARRAY_VERTEX] = hverts
		harr[Mesh.ARRAY_COLOR] = hcols
		harr[Mesh.ARRAY_INDEX] = hindices
		var hmesh := ArrayMesh.new()
		hmesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, harr)
		_holes_mesh = hmesh


func _process(_delta: float) -> void:
	if not visible or _data == null:
		return
	var viewport := get_viewport()
	if viewport == null:
		return
	var mouse_pos: Vector2 = viewport.get_mouse_position()
	if _camera != null and _camera.has_method("screen_to_map"):
		mouse_pos = _camera.screen_to_map(mouse_pos)
	# 渲染坐标 -> 索引图坐标（L2 同尺寸系数 1；保险处理）
	if _data.mask_image != null and _data.size.x > 0:
		mouse_pos *= Vector2(
			float(_data.mask_image.get_width()) / float(_data.size.x),
			float(_data.mask_image.get_height()) / float(_data.size.y))
	var query: Dictionary = _data.query_at_map_pos(mouse_pos)
	var tile: Dictionary = query.get("tile", {})
	var label: int = int(tile.get("label", -1))
	if label != int(hovered_tile.get("label", -1)):
		hovered_tile = tile
		queue_redraw()


func _draw() -> void:
	if _data == null:
		return
	# 1. 海洋背景（纯色）
	draw_rect(Rect2(Vector2.ZERO, Vector2(_data.size)), OCEAN_COLOR)
	# 2. 全部地块静态网格（一次 draw_mesh，零三角剖分）
	if _static_mesh != null:
		draw_mesh(_static_mesh, null)
	# 3. 洞挖空（C 形地块内海洋；预剖分 mesh）
	if _holes_mesh != null:
		draw_mesh(_holes_mesh, null)
	# 4. hover 地块轮廓描边（全部连通块轮廓；抗锯齿矢量线，闭合，最上层）
	var hpolys: Array = hovered_tile.get("polygons", [hovered_tile.get("polygon", [])])
	for hp in hpolys:
		if (hp as Array).size() < 3:
			continue
		var hpts := PackedVector2Array()
		for pp in hp:
			hpts.append(Vector2(pp[1], pp[0]))
		hpts.append(hpts[0])
		# 线宽：地图单位保底 2 屏像素（缩小也可见；放大随地图比例）
		var w := EDGE_WIDTH
		if _camera != null and _camera.has_method("get_zoom"):
			var z: float = _camera.get_zoom()
			if z > 0.0001:
				w = maxf(EDGE_WIDTH, MIN_SCREEN_PX / z)
		draw_polyline(hpts, EDGE_COLOR, w, true)
