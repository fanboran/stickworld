extends Node2D
class_name L2MapRenderer
## L2 地区渲染器 —— 纯矢量渲染（ArrayMesh 静态几何缓存）+ 相邻地区上下文 + 恒城市模式
##
## L2 本身即"具体到城市"的视图：恒以该地区城市蒙版贴图（l2_city_preview.png）为底，
## 无显示模式切换（不提供 toggle_display_mode，MapHUD 因此不显示细分按钮）。
## hover/编号仍按老 L1（索引图不变）；交互不变。
## 分层（context 坐标系，含相邻地区扩展区域）：
##   海洋背景 -> 湖泊(浅蓝) -> 相邻地区(灰色) -> 当前地区城市贴图
##   -> 相邻地区分界线(深色) -> hover 描边
## 性能：全部几何加载时一次性三角剖分合并为 ArrayMesh，每帧零 CPU 剖分。

enum DisplayMode { MODE_L1, MODE_CITY }

var _data: L2WorldData = null
var _camera: MapCamera = null

## 当前地图模式（B4 TERRAIN/POLITICAL，MapModeManager 广播 → 控制器转发）。
## 地形底图层（B2 产 l2_terrain.png）与政权叠加层（Phase F）落地前两模式渲染一致
## （回退现状着色），本字段为届时分层绘制的接入口
var map_mode: int = MapModeManager.Mode.TERRAIN

## 恒城市模式（L2 即"具体到城市"的视图）；不再提供 toggle_display_mode（无细分按钮）
var display_mode: int = DisplayMode.MODE_CITY

## hover 命中的地块（Dictionary，未命中为空）
var hovered_tile: Dictionary = {}

## hover 描边色（灰色）
const EDGE_COLOR := Color(0.55, 0.55, 0.55)
const EDGE_WIDTH := 6.5          # 地图单位线宽（描边=地图绝对粗细；放大超屏幕上限时 clamp）——原×1.3
const HOVER_SCREEN_CAP := 11.7   # hover 描边屏幕像素上限（原 9 ×1.3）
const HOVER_MARGIN := 2.0        # hover 描边至少比地块常驻描边粗的裕量（地图单位）

## L1 地块编号（F3 调试模式显示，画在 L1 地块质心）
const LABEL_COLOR := Color(1.0, 0.9, 0.3, 0.95)
const LABEL_BG := Color(0.0, 0.0, 0.0, 0.75)
const LABEL_SIZE := 28.0          # 地图单位字号（放大跟随，缩小保持可见）
var _debug_was_visible: bool = false

## 相邻地区分界线（深色）
const BORDER_COLOR := Color(0.25, 0.25, 0.25)
## 地块常驻描边（内部省份边界；与邻居分界线风格协调：深灰、中等粗细）
const TILE_BORDER_COLOR := Color(0.35, 0.35, 0.35)
const TILE_BORDER_WIDTH := 5.2   # 原 4 ×1.3

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
var _tile_border_segs: Array = []        # 地块描边段（烘焙，已合并共线段并滤除湖泊/边缘段）
var _neighbor_border_segs: Array = []    # 相邻地区分界线段（烘焙，同上）


func set_data(data: L2WorldData) -> void:
	_data = data
	_build_static_mesh()
	queue_redraw()


func set_camera(camera: MapCamera) -> void:
	_camera = camera


## 地图模式切换（控制器在 open() 时也推一次当前模式——跨视图全局状态）
func set_map_mode(mode: int) -> void:
	if mode == map_mode:
		return
	map_mode = mode
	queue_redraw()


func refresh() -> void:
	queue_redraw()


## 一次性构建静态网格：直接读烘焙几何（素材阶段已三角剖分），运行时零几何计算。
func _build_static_mesh() -> void:
	_static_mesh = null
	_neighbors_mesh = null
	_lakes_mesh = null
	_holes_mesh = null
	if _data == null:
		return
	_tiles_offset = Vector2(_data.tiles_offset[0], _data.tiles_offset[1])
	_context_size = Vector2(_data.context_size[0], _data.context_size[1])
	# 烘焙 mesh 顺序：[tiles, holes, lakes, neighbors]
	var meshes: Array = _data.baked_meshes
	if meshes.size() >= 1:
		_static_mesh = _make_mesh_from_baked(meshes[0])
	if meshes.size() >= 2:
		_holes_mesh = _make_mesh_from_baked(meshes[1])
	if meshes.size() >= 3:
		_lakes_mesh = _make_mesh_from_baked(meshes[2])
	if meshes.size() >= 4:
		_neighbors_mesh = _make_mesh_from_baked(meshes[3])
	# 描边段（烘焙时已合并共线段并滤除边缘段）
	_tile_border_segs = _data.tile_border_segs
	_neighbor_border_segs = _data.neighbor_border_segs


func _make_mesh_from_baked(baked: Dictionary) -> ArrayMesh:
	var verts: PackedVector3Array = baked.get("verts", PackedVector3Array())
	var colors: PackedColorArray = baked.get("colors", PackedColorArray())
	var indices: PackedInt32Array = baked.get("indices", PackedInt32Array())
	if verts.is_empty() or indices.is_empty():
		return null
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_COLOR] = colors
	arr[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


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
	# F3 调试模式变化时刷新（L1 编号显隐）
	var debug_now: bool = DebugApi != null and DebugApi.is_visible()
	if debug_now != _debug_was_visible:
		_debug_was_visible = debug_now
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
	if display_mode == DisplayMode.MODE_CITY:
		# 城市模式：铺该地区城市蒙版贴图（tiles 区域填城市色，其余透明露底层）
		if _data.city_preview_texture != null:
			draw_texture_rect(_data.city_preview_texture,
				Rect2(Vector2.ZERO, _context_size), false)
	else:
		# 4. 当前地区地块（彩色）
		if _static_mesh != null:
			draw_mesh(_static_mesh, null)
		# 5. 当前地块洞（海洋色）
		if _holes_mesh != null:
			draw_mesh(_holes_mesh, null)
	# 5.5 地块常驻描边（地图绝对粗细，放大超屏幕上限时 clamp）
	var twidth := TILE_BORDER_WIDTH
	if _camera != null and _camera.has_method("get_zoom"):
		var zz: float = _camera.get_zoom()
		if zz > 0.0001:
			twidth = minf(TILE_BORDER_WIDTH, 7.8 / zz)
	for seg in _tile_border_segs:
		draw_line(seg[0], seg[1], TILE_BORDER_COLOR, twidth, true)
	# 6. 相邻地区分界线（深色，抗锯齿矢量线；已烘焙合并共线段）
	if not _neighbor_border_segs.is_empty():
		var bw := BORDER_WIDTH()
		for seg in _neighbor_border_segs:
			draw_line(seg[0], seg[1], BORDER_COLOR, bw, true)
	# 6.5 湖泊绘制到最上层：覆盖灰色相邻地区/非地块区（湖是水域，不应被灰影盖住）。
	# 地块内湖泊已作洞（5 步洞网格同色），此处再绘一次湖泊多边形，确保非地块区的湖也显现。
	if _lakes_mesh != null:
		draw_mesh(_lakes_mesh, null)
	# 7. hover 地块轮廓描边（灰，最上层；固定屏幕像素粗细，不随缩放）
	var hpolys: Array = hovered_tile.get("polygons", [hovered_tile.get("polygon", [])])
	for hp in hpolys:
		if hp.size() < 3:
			continue
		var hpts := PackedVector2Array()
		for pp in hp:
			hpts.append(pp if pp is Vector2 else Vector2(pp[1], pp[0]))
		hpts.append(hpts[0])
		var hw := TILE_BORDER_WIDTH + HOVER_MARGIN
		if _camera != null and _camera.has_method("get_zoom"):
			var z: float = _camera.get_zoom()
			if z > 0.0001:
				# hover 比地块常驻描边粗一个裕量（地图绝对），放大超屏幕上限 clamp
				hw = minf(TILE_BORDER_WIDTH + HOVER_MARGIN, HOVER_SCREEN_CAP / z)
		draw_polyline(hpts, EDGE_COLOR, hw, true)
	# 8. L1 地块编号（F3 调试模式）：标在各地块质心，指认地块用
	if DebugApi != null and DebugApi.is_visible() and _data != null:
		_draw_l1_labels()


## F3 调试：给当前地区内的每个 L1 地块打编号
func _draw_l1_labels() -> void:
	var font := ThemeDB.fallback_font
	for tile in _data.tiles:
		var label: int = int(tile.get("label", 0))
		if label <= 0:
			continue
		var c: Array = tile.get("centroid", [0, 0])
		if c.size() < 2:
			continue
		var pos := Vector2(float(c[1]), float(c[0]))   # centroid 存 (y, x) -> 渲染 (x, y)
		var txt := "L1#%d" % label
		for off in [Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1)]:
			draw_string(font, pos + off * 2.0, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_SIZE, LABEL_BG)
		draw_string(font, pos + Vector2(2.0, -LABEL_SIZE * 0.4), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_SIZE, LABEL_COLOR)


func BORDER_WIDTH() -> float:
	# 相邻地区分界：地图绝对宽 6.5，放大超 10 屏像素 clamp
	if _camera != null and _camera.has_method("get_zoom"):
		var z: float = _camera.get_zoom()
		if z > 0.0001:
			return minf(EDGE_WIDTH * 1.3, 13.0 / z)
	return EDGE_WIDTH * 1.3
