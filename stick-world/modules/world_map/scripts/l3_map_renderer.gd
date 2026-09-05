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
## 描边=地图单位绝对粗细（不随缩放；放大超屏幕像素上限时 clamp）——=原值×1.3
const HOVER_MAP_WIDTH := 6.5      # hover 地图固定宽（原 5 ×1.3）
const HOVER_SCREEN_CAP := 10.4    # hover 屏幕像素上限（原 8 ×1.3）
const L2_BORDER_MAP_WIDTH := 11.7 # L2 地区边界地图固定宽（原 9 ×1.3）
const L2_BORDER_SCREEN_CAP := 20.8

## 海洋背景色
const OCEAN_COLOR := Color(30.0 / 255.0, 55.0 / 255.0, 95.0 / 255.0)
## L2 地区常驻描边（标识可下钻单元）
const L2_BORDER_COLOR := Color(0.14, 0.14, 0.14, 0.85)
## L2 地区编号（F3 调试模式）
const L2_LABEL_COLOR := Color(1.0, 0.9, 0.3, 0.95)
const L2_LABEL_BG := Color(0.0, 0.0, 0.0, 0.75)
const L2_LABEL_SIZE := 40.0

## 玩家当前所在 L2 地区（全局 label；出生=13 即 region_013，含老 L1 #69）。
## **整个地区**陆地带蓝光流动描边（"你在这里"，粗粒度层级）。
## Phase C 接入玩家跨区移动后改由事件动态更新（现阶段恒出生区）
var player_region_label: int = 13
## 地区描边双色（亮青蓝 ↔ 深蓝，均不透明；色调流动替代透明度闪烁——A3 定标）
const PLAYER_GLOW_A := Color(0.35, 0.85, 1.0)
const PLAYER_GLOW_B := Color(0.15, 0.45, 0.95)
const PLAYER_GLOW_MAP_WIDTH := 10.0  # 地图单位固定宽（不随缩放；地区轮廓比地块大一档）
const PLAYER_GLOW_SCREEN_CAP := 20.0 # 极端放大时屏幕像素上限

## 当前所在老 L1 轮廓的等弧长分段缓存（几何不变，重采样一次复用）
var _glow_outlines: Array[PackedVector2Array] = []
## 流动动画相位（秒）
var _glow_time := 0.0

var _l1_mesh: ArrayMesh = null
var _l1_holes_mesh: ArrayMesh = null
var _debug_was_visible: bool = false

## 异步后台加载（8192 PNG 解码不阻塞主线程）：l1_index（hover 查询）+ city_preview（城市模式底图）
var _l1_index_thread: Thread = null
var _l1_index_result: Image = null
var _city_preview_thread: Thread = null
var _city_preview_result: Image = null


func set_data(data: L3WorldData) -> void:
	_data = data
	_build_static_meshes()
	_build_glow_outlines()
	_ensure_l1_index()
	queue_redraw()


## 设置玩家当前所在 L2 地区（Phase C 动态跟踪入口；变化时重建描边缓存）
func set_player_region(label: int) -> void:
	if label == player_region_label:
		return
	player_region_label = label
	_build_glow_outlines()
	queue_redraw()


## 构建所在 L2 地区的流动描边分段缓存：该地区全部陆地多边形（land_polygons，
## 顶点 [y,x] 或 Vector2，与 _draw_l2_borders 同口径换算）
func _build_glow_outlines() -> void:
	_glow_outlines = []
	if _data == null or player_region_label <= 0:
		return
	for r in _data.regions:
		if int(r.get("label", 0)) != player_region_label:
			continue
		for poly in r.get("land_polygons", [r.get("land_polygon", [])]):
			var pts := PackedVector2Array()
			for pp in poly:
				pts.append(pp if pp is Vector2 else Vector2(pp[1], pp[0]))
			var resampled := FlowOutline.resample_closed(pts)
			if resampled.size() >= 3:
				_glow_outlines.append(resampled)


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
			if poly.size() < 3:
				continue
			var pts2 := PackedVector2Array()
			for p in poly:
				pts2.append(p if p is Vector2 else Vector2(p[1], p[0]))
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
			if hole.size() < 3:
				continue
			var hpts := PackedVector2Array()
			for p in hole:
				hpts.append(p if p is Vector2 else Vector2(p[1], p[0]))
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


func _process(delta: float) -> void:
	_poll_async_loads()
	# 当前位置流动光动画：相位推进 + 每帧重绘（mesh 均为缓存一次性 draw 命令，成本低）
	if visible and not _glow_outlines.is_empty():
		_glow_time += delta
		queue_redraw()
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


## 异步加载：老 L1 索引图（hover 查询用）——8192 PNG 后台线程解码（纯 CPU、线程安全），
## 主线程零阻塞；完成前 query_l1_at_map_pos 因 l1_index_image 为 null 自然返回空（hover 静默）
func _ensure_l1_index() -> void:
	if _data == null or _data.l1_index_image != null or _l1_index_thread != null:
		return
	_l1_index_thread = Thread.new()
	_l1_index_thread.start(_load_l1_index_async)


func _load_l1_index_async() -> void:
	var f := FileAccess.open("res://config/strategic_map/l3_l1_index_8192.png", FileAccess.READ)
	if f == null:
		return
	var img := Image.new()
	if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
		_l1_index_result = img


## 异步加载：城市模式栅格贴图——切到城市模式首次需要时后台解码（省 ~143ms 阻塞），
## 完成前城市模式短暂无底图（下一帧自动补上）
func _ensure_city_preview() -> void:
	if _data == null or _data.city_preview_texture != null or _city_preview_thread != null:
		return
	_city_preview_thread = Thread.new()
	_city_preview_thread.start(_load_city_preview_async)


func _load_city_preview_async() -> void:
	var f := FileAccess.open("res://config/strategic_map/l3_city_preview_8192.png", FileAccess.READ)
	if f == null:
		return
	var img := Image.new()
	if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
		_city_preview_result = img


## 每帧检查后台线程：解码完成 → wait_to_finish + 取结果（ImageTexture 需主线程创建）
func _poll_async_loads() -> void:
	if _data == null:
		return
	if _l1_index_thread != null and not _l1_index_thread.is_alive():
		_l1_index_thread.wait_to_finish()
		_l1_index_thread = null
		if _l1_index_result != null:
			_data.l1_index_image = _l1_index_result
			_l1_index_result = null
	if _city_preview_thread != null and not _city_preview_thread.is_alive():
		_city_preview_thread.wait_to_finish()
		_city_preview_thread = null
		if _city_preview_result != null:
			_data.city_preview_texture = ImageTexture.create_from_image(_city_preview_result)
			_city_preview_result = null
			queue_redraw()


func _draw() -> void:
	if _data == null:
		return
	# 1. 海洋背景
	draw_rect(Rect2(Vector2.ZERO, Vector2(float(_data.size), float(_data.size))), OCEAN_COLOR)
	if display_mode == DisplayMode.MODE_CITY:
		# 城市模式：直接贴 city_preview 栅格图（花花绿绿、零剖分、快）
		_ensure_city_preview()
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
	# 3.5 玩家当前所在 L2 地区：整区蓝光流动描边（"你在这里"）
	if not _glow_outlines.is_empty():
		var gw := PLAYER_GLOW_MAP_WIDTH
		if _camera != null and _camera.has_method("get_zoom"):
			var gz: float = _camera.get_zoom()
			if gz > 0.0001:
				gw = minf(PLAYER_GLOW_MAP_WIDTH, PLAYER_GLOW_SCREEN_CAP / gz)
		for outline in _glow_outlines:
			FlowOutline.draw_flow(self, outline, PLAYER_GLOW_A, PLAYER_GLOW_B, _glow_time, gw)
	# 4. hover 老 L1 高亮（黄线轮廓）
	_draw_hover_l1()
	# 5. L2 地区编号（F3 调试模式）
	if DebugApi != null and DebugApi.is_visible():
		_draw_l2_labels()


func _draw_l2_borders() -> void:
	var bw := BORDER_WIDTH()
	for r in _data.regions:
		for poly in r.get("land_polygons", [r.get("land_polygon", [])]):
			if poly.size() < 3:
				continue
			var bpts := PackedVector2Array()
			for pp in poly:
				bpts.append(pp if pp is Vector2 else Vector2(pp[1], pp[0]))
			bpts.append(bpts[0])
			draw_polyline(bpts, L2_BORDER_COLOR, bw, true)


func BORDER_WIDTH() -> float:
	# 地图固定宽 9；放大超 16 屏像素时 clamp（极端放大防糊屏）
	if _camera != null and _camera.has_method("get_zoom"):
		var z: float = _camera.get_zoom()
		if z > 0.0001:
			return minf(L2_BORDER_MAP_WIDTH, L2_BORDER_SCREEN_CAP / z)
	return L2_BORDER_MAP_WIDTH


func _draw_hover_l1() -> void:
	if hovered_l1.is_empty():
		return
	var hpolys: Array = hovered_l1.get("polygons", [])
	for hp in hpolys:
		if hp.size() < 3:
			continue
		var hpts := PackedVector2Array()
		for pp in hp:
			hpts.append(pp if pp is Vector2 else Vector2(pp[1], pp[0]))
		hpts.append(hpts[0])
		var hw := HOVER_MAP_WIDTH
		if _camera != null and _camera.has_method("get_zoom"):
			var z: float = _camera.get_zoom()
			if z > 0.0001:
				hw = minf(HOVER_MAP_WIDTH, HOVER_SCREEN_CAP / z)
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