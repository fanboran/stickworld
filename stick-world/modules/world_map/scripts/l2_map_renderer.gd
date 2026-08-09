extends Node2D
class_name L2MapRenderer
## L2 地区渲染器 —— 纯矢量渲染（ArrayMesh 静态几何缓存）+ 相邻地区上下文
##
## 分层（context 坐标系，含相邻地区扩展区域）：
##   海洋背景 -> 湖泊(浅蓝) -> 相邻地区(灰色) -> 当前地区地块(彩色)
##   -> 相邻地区分界线(深色) -> hover 灰色描边
## 性能：全部几何加载时一次性三角剖分合并为 ArrayMesh，每帧零 CPU 剖分。

var _data: L2WorldData = null
var _camera: MapCamera = null

## hover 命中的地块（Dictionary，未命中为空）
var hovered_tile: Dictionary = {}

## hover 描边色（灰色）
const EDGE_COLOR := Color(0.55, 0.55, 0.55)
const EDGE_WIDTH := 5.0          # 地图单位线宽（邻居/地块常驻描边用）
const EDGE_SCREEN_PX := 2.5      # hover 描边固定屏幕像素（不随缩放）
const HOVER_MARGIN := 2.0        # hover 描边至少比地块常驻描边粗的裕量（地图单位）

## 相邻地区分界线（深色）
const BORDER_COLOR := Color(0.25, 0.25, 0.25)
## 地块常驻描边（内部省份边界；与邻居分界线风格协调：深灰、中等粗细）
const TILE_BORDER_COLOR := Color(0.35, 0.35, 0.35)
const TILE_BORDER_WIDTH := 4.0

## 海洋背景色
const OCEAN_COLOR := Color(30.0 / 255.0, 55.0 / 255.0, 95.0 / 255.0)
## 湖泊（深色系，比海洋更深更沉）
const LAKE_COLOR := Color(28.0 / 255.0, 50.0 / 255.0, 82.0 / 255.0)
## 相邻地区（灰色，不上色）
const NEIGHBOR_COLOR := Color(0.45, 0.45, 0.45)

var _static_mesh: ArrayMesh = null       # 当前地区地块（彩色）
var _neighbors_mesh: ArrayMesh = null    # 相邻地区（灰色）
var _lakes_mesh: ArrayMesh = null        # 湖泊（浅蓝）
var _holes_mesh: ArrayMesh = null        # 当前地块洞（海洋色）
var _tiles_offset := Vector2.ZERO        # 当前地区 bbox 原点在 context 中的位置
var _context_size := Vector2.ONE
var _neighbor_polys: Array = []          # 相邻地区轮廓（分界线绘制）
var _lake_pt_grid := {}                  # 湖泊边界点网格（cell->点列表，用于湖泊接壤判定）
var _tile_border_segs: Array = []        # 地块描边段（已滤除湖泊接壤段与画框边缘段）
var _neighbor_border_segs: Array = []    # 相邻地区分界线段（同上过滤）
const _GRID_CELL := 16.0
const _LAKE_DIST := 4.0


## 点是否在 context 画框边缘
func _on_context_edge(v: Vector2) -> bool:
	var cw := _context_size.x
	var ch := _context_size.y
	return v.x <= 0.5 or v.y <= 0.5 or v.x >= cw - 0.5 or v.y >= ch - 0.5


## 把多边形顶点加入湖泊边界点网格
func _add_lake_points(pts: PackedVector2Array) -> void:
	for p in pts:
		var key := "%d,%d" % [int(p.x / _GRID_CELL), int(p.y / _GRID_CELL)]
		if not _lake_pt_grid.has(key):
			_lake_pt_grid[key] = []
		(_lake_pt_grid[key] as Array).append(p)


## 判定线段是否与湖泊接壤：线段的两端与中点任一落在湖泊边界附近(容忍距离内)即视为接壤。
## 湖泊接壤的边界线段因共享边界/Chaikin 平滑而与湖边界点高度接近；检查三点可覆盖
## 边界平滑后产生的轻微偏移（~数单位），避免残留零星短描边。
func _near_lake(pt: Vector2) -> bool:
	var cx := int(pt.x / _GRID_CELL)
	var cy := int(pt.y / _GRID_CELL)
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key := "%d,%d" % [cx + dx, cy + dy]
			if not _lake_pt_grid.has(key):
				continue
			for p in _lake_pt_grid[key]:
				if (p - pt).length() <= _LAKE_DIST:
					return true
	return false


func _is_lake_adjacent(a: Vector2, b: Vector2) -> bool:
	if _near_lake(a) or _near_lake(b):
		return true
	return _near_lake((a + b) * 0.5)


## 过滤一条闭合多边形环：返回可绘制的分段（跳过湖泊接壤段与画框边缘段）
func _filter_border_segs(pts: PackedVector2Array) -> PackedVector2Array:
	var segs := PackedVector2Array()
	for i in range(pts.size()):
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[(i + 1) % pts.size()]
		if _on_context_edge(a) and _on_context_edge(b):
			continue  # 贴边段：不画（消除贴边分界线）
		if _is_lake_adjacent(a, b):
			continue  # 湖泊接壤段：不画（避免湖泊被描边成小孔）
		segs.append(a)
		segs.append(b)
	return segs


func set_data(data: L2WorldData) -> void:
	_data = data
	_build_static_mesh()
	queue_redraw()


func set_camera(camera: MapCamera) -> void:
	_camera = camera


func refresh() -> void:
	queue_redraw()


func _add_polygon_mesh(verts: PackedVector3Array, colors: PackedColorArray,
		indices: PackedInt32Array, pts2: PackedVector2Array, fill: Color) -> void:
	var tri := Geometry2D.triangulate_polygon(pts2)
	if tri.is_empty():
		return
	var base := verts.size()
	for v in pts2:
		verts.append(Vector3(v.x, v.y, 0.0))
		colors.append(fill)
	for idx in tri:
		indices.append(base + idx)


func _make_mesh(verts: PackedVector3Array, colors: PackedColorArray,
		indices: PackedInt32Array) -> ArrayMesh:
	if verts.is_empty():
		return null
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_COLOR] = colors
	arr[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


## 一次性构建静态网格（全部几何合并为 ArrayMesh）
func _build_static_mesh() -> void:
	_static_mesh = null
	_neighbors_mesh = null
	_lakes_mesh = null
	_holes_mesh = null
	_neighbor_polys = []
	if _data == null:
		return
	_tiles_offset = Vector2(_data.tiles_offset[0], _data.tiles_offset[1])
	_context_size = Vector2(_data.context_size[0], _data.context_size[1])

	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var hverts := PackedVector3Array()
	var hcols := PackedColorArray()
	var hindices := PackedInt32Array()
	# 地块/湖泊/邻居多边形均为 ctx 系坐标（提取时已含 tiles_offset 偏移），渲染不平移
	for t in _data.tiles:
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
			_add_polygon_mesh(verts, colors, indices, pts2, fill)
		for hole in t.get("holes", []):
			var hpts_inner: Array = hole.get("points", []) if hole is Dictionary else hole
			if (hpts_inner as Array).size() < 3:
				continue
			var hpts := PackedVector2Array()
			for p in hpts_inner:
				hpts.append(Vector2(p[1], p[0]))
			var hfill := OCEAN_COLOR
			if hole is Dictionary and hole.get("lake", false):
				hfill = LAKE_COLOR
			_add_polygon_mesh(hverts, hcols, hindices, hpts, hfill)
	_static_mesh = _make_mesh(verts, colors, indices)
	_holes_mesh = _make_mesh(hverts, hcols, hindices)

	# 湖泊（ctx 系，不平移）
	var lverts := PackedVector3Array()
	var lcols := PackedColorArray()
	var lindices := PackedInt32Array()
	for poly in _data.lakes:
		if (poly as Array).size() < 3:
			continue
		var pts2 := PackedVector2Array()
		for p in poly:
			pts2.append(Vector2(p[1], p[0]))
		_add_polygon_mesh(lverts, lcols, lindices, pts2, LAKE_COLOR)
	_lakes_mesh = _make_mesh(lverts, lcols, lindices)

	# 相邻地区（灰色，坐标已在 context 系，无需平移）
	var nverts := PackedVector3Array()
	var ncols := PackedColorArray()
	var nindices := PackedInt32Array()
	for nb in _data.neighbors:
		var polys: Array = nb.get("polygons", [])
		for poly in polys:
			if (poly as Array).size() < 3:
				continue
			var pts2 := PackedVector2Array()
			for p in poly:
				pts2.append(Vector2(p[1], p[0]))
			_add_polygon_mesh(nverts, ncols, nindices, pts2, NEIGHBOR_COLOR)
		for poly in polys:
			if (poly as Array).size() < 3:
				continue
			var line := PackedVector2Array()
			for p in poly:
				line.append(Vector2(p[1], p[0]))
			_neighbor_polys.append(line)
	_neighbors_mesh = _make_mesh(nverts, ncols, nindices)

	# 湖泊边界点网格：描边时跳过与湖泊接壤的段（避免湖泊被描边成小孔/出现接壤描边）
	_lake_pt_grid = {}
	for poly in _data.lakes:
		var lpts := PackedVector2Array()
		for p in poly:
			lpts.append(Vector2(p[1], p[0]))
		_add_lake_points(lpts)
	for t in _data.tiles:
		for hole in t.get("holes", []):
			if not (hole is Dictionary and hole.get("lake", false)):
				continue
			var hpts := PackedVector2Array()
			for p in hole.get("points", []):
				hpts.append(Vector2(p[1], p[0]))
			_add_lake_points(hpts)

	# 预计算地块描边段与相邻地区分界线段（滤除湖泊接壤段与画框边缘段）
	_tile_border_segs = []
	for t in _data.tiles:
		for poly in t.get("polygons", []):
			if (poly as Array).size() < 3:
				continue
			var tpts := PackedVector2Array()
			for pp in poly:
				tpts.append(Vector2(pp[1], pp[0]))
			var segs := _filter_border_segs(tpts)
			if segs.size() >= 2:
				_tile_border_segs.append(segs)
	_neighbor_border_segs = []
	for line in _neighbor_polys:
		var closed := PackedVector2Array(line)
		var segs := PackedVector2Array()
		for i in range(closed.size()):
			var a: Vector2 = closed[i]
			var b: Vector2 = closed[(i + 1) % closed.size()]
			if _on_context_edge(a) and _on_context_edge(b):
				continue  # 整段在画框边缘：不画
			if _is_lake_adjacent(a, b):
				continue  # 湖泊接壤段：不画（避免湖泊被描边成小孔）
			segs.append(a)
			segs.append(b)
		if segs.size() >= 2:
			_neighbor_border_segs.append(segs)


func _process(_delta: float) -> void:
	if not visible or _data == null:
		return
	var viewport := get_viewport()
	if viewport == null:
		return
	var mouse_pos: Vector2 = viewport.get_mouse_position()
	if _camera != null and _camera.has_method("screen_to_map"):
		mouse_pos = _camera.screen_to_map(mouse_pos)
	# context 坐标 -> 当前地区索引图坐标（-tiles_offset）
	mouse_pos -= _tiles_offset
	# 正方形特写：tiles 区域已平移到正方形中心，hover 查询用 tiles 区域坐标
	var query: Dictionary = _data.query_at_map_pos(mouse_pos)
	var tile: Dictionary = query.get("tile", {})
	var label: int = int(tile.get("label", -1))
	if label != int(hovered_tile.get("label", -1)):
		hovered_tile = tile
		queue_redraw()


func _draw() -> void:
	if _data == null:
		return
	# 1. 海洋背景（context 尺寸）
	draw_rect(Rect2(Vector2.ZERO, _context_size), OCEAN_COLOR)
	# 2. 湖泊（浅蓝）
	if _lakes_mesh != null:
		draw_mesh(_lakes_mesh, null)
	# 3. 相邻地区（灰色）
	if _neighbors_mesh != null:
		draw_mesh(_neighbors_mesh, null)
	# 4. 当前地区地块（彩色）
	if _static_mesh != null:
		draw_mesh(_static_mesh, null)
	# 5. 当前地块洞（海洋色）
	if _holes_mesh != null:
		draw_mesh(_holes_mesh, null)
	# 5.5 地块常驻描边（内部省份边界；已预滤除湖泊接壤段与画框边缘段）
	for segs in _tile_border_segs:
		for i in range(0, segs.size() - 1, 2):
			draw_line(segs[i], segs[i + 1], TILE_BORDER_COLOR, TILE_BORDER_WIDTH, true)
	# 6. 相邻地区分界线（深色，抗锯齿矢量线；已预滤除湖泊接壤段与画框边缘段）
	if not _neighbor_border_segs.is_empty():
		var bw := BORDER_WIDTH()
		for segs in _neighbor_border_segs:
			for i in range(0, segs.size() - 1, 2):
				draw_line(segs[i], segs[i + 1], BORDER_COLOR, bw, true)
	# 6.5 湖泊绘制到最上层：覆盖灰色相邻地区/非地块区（湖是水域，不应被灰影盖住）。
	# 地块内湖泊已作洞（5 步洞网格同色），此处再绘一次湖泊多边形，确保非地块区的湖也显现。
	if _lakes_mesh != null:
		draw_mesh(_lakes_mesh, null)
	# 7. hover 地块轮廓描边（灰，最上层；固定屏幕像素粗细，不随缩放）
	var hpolys: Array = hovered_tile.get("polygons", [hovered_tile.get("polygon", [])])
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
				# hover 描边至少比地块常驻描边粗一个裕量：放大时避免比地块描边还细
				hw = maxf(EDGE_SCREEN_PX / z, TILE_BORDER_WIDTH + HOVER_MARGIN)
		draw_polyline(hpts, EDGE_COLOR, hw, true)


func BORDER_WIDTH() -> float:
	var w := EDGE_WIDTH * 1.3
	if _camera != null and _camera.has_method("get_zoom"):
		var z: float = _camera.get_zoom()
		if z > 0.0001:
			w = maxf(w, EDGE_SCREEN_PX / z)
	return w
