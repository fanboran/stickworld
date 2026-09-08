extends Node2D
class_name L2MapRenderer
## L2 地区渲染器 —— 纯矢量渲染（ArrayMesh 静态几何缓存）+ 相邻地区上下文 + 恒城市模式
##
## L2 本身即"具体到城市"的视图：恒以该地区城市蒙版贴图（l2_city_preview.png）为底，
## 无显示模式切换（不提供 toggle_display_mode，MapHUD 因此不显示细分按钮）。
## hover/编号仍按老 L1（索引图不变）；交互不变。
## 线条语言（R8 层2）：非政治模式界线维持现状语义（token 化，MapTokens 零字面量）；
## 政治模式界线走三级——地区界 2px 长虚线 / 地块界 1px 短虚线（国界 3px 由底图
## ID mask 像素色差表达，矢量国界在 L3 落地）；手绘笔触与 SketchDraw 同源
## （MapSketch：固定 seed 不沸腾），hover = boiling 动态笔触（血条同拍）。
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

## ===== 线条/色彩 token（R8 层2）：真相源在 MapTokens，本文件零色值/线宽字面量 =====
## 非政治模式沿用现状线宽语义（原值迁移）；政治模式界线走三级规范（国/地区/地块）。

## hover 描边色（交互线槽 = StickTokens.BORDER_STRONG，R8 语义归位）
const EDGE_COLOR := MapTokens.L2_HOVER_COLOR
const EDGE_WIDTH := MapTokens.L2_HOVER_WIDTH     # hover 地图单位线宽（描边=地图绝对粗细）
const HOVER_SCREEN_CAP := MapTokens.L2_HOVER_SCREEN_CAP
const HOVER_MARGIN := MapTokens.L2_HOVER_MARGIN

## L1 地块编号（F3 调试模式显示，画在 L1 地块质心；调试域专色）
const LABEL_COLOR := MapTokens.DEBUG_INK
const LABEL_BG := MapTokens.DEBUG_BG
const LABEL_SIZE := 28.0          # 地图单位字号（放大跟随，缩小保持可见）
var _debug_was_visible: bool = false

## 相邻地区分界线（非政治模式；深灰墨）
const BORDER_COLOR := MapTokens.L2_BORDER_COLOR
## 地块常驻描边（非政治模式；灰墨、地图单位宽）
const TILE_BORDER_COLOR := MapTokens.L2_TILE_BORDER_COLOR
const TILE_BORDER_WIDTH := MapTokens.L2_TILE_BORDER_WIDTH

## 海洋背景色（B2 同源）/ 湖泊（B2 湖色同源，mesh 顶点色由 l2_bake 烘入）/
## 河流（B3：与底图预渲染河流同色；POLITICAL 模式矢量叠加）
const OCEAN_COLOR := MapTokens.L2_OCEAN
const LAKE_COLOR := MapTokens.L2_LAKE
const RIVER_COLOR := MapTokens.L2_RIVER
const RIVER_MIN_WIDTH := MapTokens.L2_RIVER_MIN_WIDTH
## 相邻地区（灰色，不上色）
const NEIGHBOR_COLOR := MapTokens.L2_NEIGHBOR

var _static_mesh: ArrayMesh = null       # 当前地区地块（彩色）
var _neighbors_mesh: ArrayMesh = null    # 相邻地区（灰色）
var _lakes_mesh: ArrayMesh = null        # 湖泊（浅蓝）
var _holes_mesh: ArrayMesh = null        # 当前地块洞（海洋色）
var _tiles_offset := Vector2.ZERO        # 当前地区 bbox 原点在 context 中的位置
var _context_size := Vector2.ONE
var _tile_border_segs: Array = []        # 地块描边段（烘焙，已合并共线段并滤除湖泊/边缘段）
var _neighbor_border_segs: Array = []    # 相邻地区分界线段（烘焙，同上）

## 政治模式着色层（R7/R9：政权 ID mask + PoliticalLut 查表 shader；mask 含
## 海洋/湖泊/邻区底色保留码，垫底后本节点跳过 1/2/3 层，界线/河流/hover 照常画）
var _political_layer: Sprite2D = null

## 政治模式界线三级缓存（R8 层2）：地块界（1px 短虚线）/地区界（2px 长虚线）——
## 手绘扰动 + 虚线在构建时做一次（固定 seed 不沸腾，笔触烙在地图上）。
## 国界（3px 实线）由底图 ID mask 像素色差表达（L2 pack 无城块矢量几何，
## 三级中的国界矢量层在 L3 落地，数据源 = l3_city 城块邻接）
var _political_plot_segs := PackedVector2Array()
var _political_region_segs := PackedVector2Array()
var _political_borders_built := false

## boiling 时钟/帧号（R8 层2 动态线节拍，hover 笔触用；0.12s 重掷，血条同拍）
var _boiling_time := 0.0
var _boiling_frame := 0


func set_data(data: L2WorldData) -> void:
	_data = data
	_build_static_mesh()
	_ensure_political_layer()
	_political_borders_built = false
	queue_redraw()


func set_camera(camera: MapCamera) -> void:
	_camera = camera


## 政权 ID mask 着色层（R7/R9）：贴图随包同步加载，LUT 全游戏共享一份
## （PoliticalLut.shared_from_states 首调构建）——改 LUT 即 L2/L3/图例全换色
func _ensure_political_layer() -> void:
	if _political_layer != null or _data == null or _data.political_id_texture == null:
		return
	var lut := PoliticalLut.shared_from_states(_data.states)
	if lut == null:
		return
	var mat := ShaderMaterial.new()
	mat.shader = PoliticalLut.COLORIZE_SHADER
	mat.set_shader_parameter("id_mask", _data.political_id_texture)
	mat.set_shader_parameter("lut", lut.texture)
	_political_layer = Sprite2D.new()
	_political_layer.texture = _data.political_id_texture
	_political_layer.centered = false
	_political_layer.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_political_layer.material = mat
	# z=-1（相对）：垫在本节点 _draw 的界线/河流/hover 之下
	_political_layer.z_index = -1
	_political_layer.visible = map_mode == MapModeManager.Mode.POLITICAL
	add_child(_political_layer)


## 地图模式切换（控制器在 open() 时也推一次当前模式——跨视图全局状态）
func set_map_mode(mode: int) -> void:
	if mode == map_mode:
		return
	map_mode = mode
	_ensure_political_layer()
	if _political_layer != null:
		_political_layer.visible = mode == MapModeManager.Mode.POLITICAL
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


func _process(delta: float) -> void:
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
	# 动态线 boiling（hover 笔触）：0.12s 重掷帧号（血条同拍），变化才重绘
	if hovered_tile.is_empty():
		_boiling_time = 0.0
		_boiling_frame = 0
	else:
		_boiling_time += delta
		var frame := MapSketch.boiling_seed(_boiling_time)
		if frame != _boiling_frame:
			_boiling_frame = frame
			queue_redraw()
	# F3 调试模式变化时刷新（L1 编号显隐）
	var debug_now: bool = DebugApi != null and DebugApi.is_visible()
	if debug_now != _debug_was_visible:
		_debug_was_visible = debug_now
		queue_redraw()


func _draw() -> void:
	if _data == null:
		return
	# 地形模式（B2）：程序着色底图替代填充层（湖泊/海洋/邻居地形已在纹理内）
	var terrain := map_mode == MapModeManager.Mode.TERRAIN and _data.terrain_texture != null
	# 政治模式（R7/R9）：政权 ID mask shader 层已垫底（mask 含海洋/湖泊/邻区底色
	# 保留码），本节点跳过 1/2/3 层直出；层未就绪（贴图缺失）时回退城市贴图
	var political := map_mode == MapModeManager.Mode.POLITICAL 				and _political_layer != null
	# 1. 海洋背景（context 尺寸；地形纹理的虚空透明区透出此色）
	if not political:
		draw_rect(Rect2(Vector2.ZERO, _context_size), OCEAN_COLOR)
	if terrain:
		draw_texture_rect(_data.terrain_texture,
			Rect2(Vector2.ZERO, _context_size), false)
	elif political:
		pass  # 政权 ID + LUT 查表层已垫底
	else:
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
	# 5.5 界线（R8 层2 分级）：
	#     政治模式 = 界线三级——地区界 2px 长虚线 / 地块界 1px 短虚线（§7.3-6 规范表，
	#     屏幕像素口径恒定粗细；手绘固定 seed 不沸腾；国界由底图 ID mask 像素色差表达）
	#     非政治模式 = 现状语义（地块常驻描边，地图绝对粗细，放大超屏幕上限时 clamp）
	if political:
		if not _political_borders_built:
			_build_political_borders()
		var regw := MapTokens.LINE_REGION
		var plw := MapTokens.LINE_PLOT
		if _camera != null and _camera.has_method("get_zoom"):
			var pz: float = _camera.get_zoom()
			if pz > 0.0001:
				regw = MapTokens.LINE_REGION / pz
				plw = MapTokens.LINE_PLOT / pz
		if _political_plot_segs.size() >= 2:
			draw_multiline(_political_plot_segs, MapTokens.LINE_PLOT_COLOR, plw, true)
		if _political_region_segs.size() >= 2:
			draw_multiline(_political_region_segs, MapTokens.LINE_REGION_COLOR, regw, true)
	else:
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
	# 地形模式下纹理已含湖色，跳过（避免纯色湖 mesh 盖掉纹理湖渐变）。
	if _lakes_mesh != null and not terrain:
		draw_mesh(_lakes_mesh, null)
	# 6.6 河流矢量（B3）：POLITICAL 模式叠加（TERRAIN 底图已含河流，不重复画）。
	# 画在湖泊上层之外的水系表达——河折线止于湖岸/海岸（生成端 mask 同源），画湖后即可。
	if not terrain:
		for rv in _data.rivers:
			var rpts: PackedVector2Array = rv.get("pts", PackedVector2Array())
			if rpts.size() >= 2:
				draw_polyline(rpts, RIVER_COLOR, maxf(float(rv.get("w", 2.0)), RIVER_MIN_WIDTH), true)
	# 7. hover 地块轮廓描边（交互线槽，最上层；固定屏幕像素粗细，不随缩放；
	#    boiling 手绘笔触——"活"的笔触只给交互层，R8 层2）
	var hpolys: Array = hovered_tile.get("polygons", [hovered_tile.get("polygon", [])])
	for hp in hpolys:
		if hp.size() < 3:
			continue
		var hpts := PackedVector2Array()
		for pp in hp:
			hpts.append(pp if pp is Vector2 else Vector2(pp[1], pp[0]))
		var hw := TILE_BORDER_WIDTH + HOVER_MARGIN
		if _camera != null and _camera.has_method("get_zoom"):
			var z: float = _camera.get_zoom()
			if z > 0.0001:
				# hover 比地块常驻描边粗一个裕量（地图绝对），放大超屏幕上限 clamp
				hw = minf(TILE_BORDER_WIDTH + HOVER_MARGIN, HOVER_SCREEN_CAP / z)
		var hseed := MapSketch.id_seed("l2_hover") + _boiling_frame
		var hwobble := MapSketch.wobble_polyline(hpts, hseed, hw, true)
		hwobble.append(hwobble[0])
		draw_polyline(hwobble, EDGE_COLOR, hw, true)
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


## 构建政治模式界线三级缓存（首次政治绘制时一次）：地块界/地区界逐段手绘扰动
## （固定 seed——顶点拖拽由坐标 hash 决定，段间共享端点连续无缝）+ 虚线切段。
## 笔触/虚线按构建时 zoom 固化成地图单位（烙在地图上，缩放观感一致）；线宽绘制时
## 实时 ÷zoom 保持屏幕恒定。
func _build_political_borders() -> void:
	_political_plot_segs = PackedVector2Array()
	_political_region_segs = PackedVector2Array()
	_political_borders_built = true
	var zz := 1.0
	if _camera != null and _camera.has_method("get_zoom"):
		zz = _camera.get_zoom()
	if zz <= 0.0001:
		zz = 1.0
	var plot_w := MapTokens.LINE_PLOT / zz
	var region_w := MapTokens.LINE_REGION / zz
	var plot_seed := MapSketch.id_seed("l2_plot")
	var region_seed := MapSketch.id_seed("l2_region")
	for seg in _tile_border_segs:
		var wpts := MapSketch.wobble_polyline(
			PackedVector2Array([seg[0], seg[1]]), plot_seed, plot_w, false)
		MapSketch.dash_segments(_political_plot_segs, wpts,
			MapTokens.DASH_SHORT / zz, MapTokens.DASH_SHORT_GAP / zz)
	for seg in _neighbor_border_segs:
		var wpts := MapSketch.wobble_polyline(
			PackedVector2Array([seg[0], seg[1]]), region_seed, region_w, false)
		MapSketch.dash_segments(_political_region_segs, wpts,
			MapTokens.DASH_LONG / zz, MapTokens.DASH_LONG_GAP / zz)


func BORDER_WIDTH() -> float:
	# 相邻地区分界：地图绝对宽，放大超屏幕像素 clamp
	if _camera != null and _camera.has_method("get_zoom"):
		var z: float = _camera.get_zoom()
		if z > 0.0001:
			return minf(MapTokens.L2_BORDER_WIDTH, MapTokens.L2_BORDER_SCREEN_CAP / z)
	return MapTokens.L2_BORDER_WIDTH
