extends Node2D
class_name MapRenderer
## 战略图渲染器（L1 单层，Tab 键）—— 与 L2 同款分层矢量绘制
##
## 数据来自 l1_world.json（含 context_size/neighbors/lakes，坐标 = context 局部）。
## 全部矢量绘制（地块少），任意缩放清晰，不依赖底图纹理。
## 分层（context 坐标系，含灰色邻居 L1 块扩展区域，与 L2MapRenderer 一致）：
##   海洋背景 -> 湖泊(浅蓝) -> 邻居老 L1 块(灰色) -> 当前 L1 城市块(政权色)
##   -> 城市描边 + 出生 L1 权威轮廓(深色) -> hover 描边(灰) -> F3 地块编号
##
## 交互：hover 命中城市块（经相机换算 + 索引图查询），点击选中由控制器经 api 处理。

## 关联的 L1 世界数据
var _data: L1WorldData = null

## 相机引用（悬停检测做 screen->map 坐标换算）
var _camera: MapCamera = null

## 当前悬停的地块 ID（""=无）
var hovered_tile_id: String = ""

## 配色（与 L2MapRenderer 完全一致）
const OCEAN_COLOR := Color(30.0 / 255.0, 55.0 / 255.0, 95.0 / 255.0)
const LAKE_COLOR := Color(28.0 / 255.0, 50.0 / 255.0, 82.0 / 255.0)
const NEIGHBOR_COLOR := Color(0.45, 0.45, 0.45)
## 出生 L1 轮廓 / 邻居分界（细线，屏显上限 3px）
const BORDER_COLOR := Color(0.25, 0.25, 0.25)
const BORDER_WIDTH := 4.5
const BORDER_SCREEN_CAP := 3.0
## hover 城市块描边（灰，固定屏幕像素粗细，不随缩放）
const HOVER_COLOR := Color(0.55, 0.55, 0.55)
const HOVER_WIDTH := 4.0
const HOVER_SCREEN_CAP := 3.5
## F3 调试：城市编号
const LABEL_COLOR := Color(1.0, 0.9, 0.3, 0.95)
const LABEL_BG := Color(0.0, 0.0, 0.0, 0.75)
const LABEL_SIZE := 28.0
## F3 城市编号的屏幕恒定字号（像素）：地图单元字号 ÷ 缩放，避免 L1 高缩放下"雷霆大字"
const LABEL_SCREEN_SIZE := 22.0
var _debug_was_visible: bool = false


func set_data(data: L1WorldData) -> void:
	_data = data
	queue_redraw()


func set_camera(camera: MapCamera) -> void:
	_camera = camera


## 接口保留（api.select 调用）；选中高亮交给 hover/控制器
func select(_id: String) -> void:
	queue_redraw()


func deselect() -> void:
	queue_redraw()


func get_selected() -> String:
	return ""


func refresh() -> void:
	queue_redraw()


func _process(_delta: float) -> void:
	if not is_visible_in_tree() or _data == null:
		return
	# 屏幕坐标 -> 地图坐标（一次换算，与 api.query_at_screen 同路径；
	# 不能用 get_global_mouse_position——它已按节点 transform 逆变换过，再换算会双重扭曲）
	var viewport := get_viewport()
	if viewport == null:
		return
	var mouse_pos: Vector2 = viewport.get_mouse_position()
	if _camera != null and _camera.has_method("screen_to_map"):
		mouse_pos = _camera.screen_to_map(mouse_pos)
	var query: Dictionary = _data.query_at_map_pos(mouse_pos)
	var tile: L1TileDef = query.get("tile", null)
	var new_tile_id: String = tile.tile_id if tile != null else ""
	if new_tile_id != hovered_tile_id:
		hovered_tile_id = new_tile_id
		queue_redraw()
	# F3 调试模式变化时刷新（城市编号显隐）
	var debug_now: bool = DebugApi != null and DebugApi.is_visible()
	if debug_now != _debug_was_visible:
		_debug_was_visible = debug_now
		queue_redraw()


func _draw() -> void:
	if _data == null:
		return
	var ctx := _data.context_size
	var ctx_size := Vector2(float(ctx.x), float(ctx.y))
	if ctx_size.x <= 0.0:
		ctx_size = Vector2(float(_data.size), float(_data.size))
	var zz: float = 1.0
	if _camera != null and _camera.has_method("get_zoom"):
		zz = _camera.get_zoom()
	# 1. 海洋背景（context 尺寸）
	draw_rect(Rect2(Vector2.ZERO, ctx_size), OCEAN_COLOR)
	# 2. 湖泊（浅蓝，覆盖灰色邻居/非地块区）
	for lake in _data.lakes:
		if (lake as Array).size() >= 3:
			draw_colored_polygon(_pts(lake), LAKE_COLOR)
	# 3. 邻居老 L1 块（灰色）
	for nb in _data.neighbors:
		for poly in nb.get("polygons", []):
			if (poly as Array).size() >= 3:
				draw_colored_polygon(_pts(poly), NEIGHBOR_COLOR)
	# 4. 当前 L1 城市块（政权色，纯色块不描边——内部城界靠政权色区分，湖边界不画追踪线）
	for tile in _data.tiles:
		if tile.polygon.size() < 3:
			continue
		draw_colored_polygon(tile.polygon, _data.get_state_color(tile.owner_state_id))
	# 5. 出生 L1 权威轮廓（深色细线，邻居分界同理）
	var bw: float = BORDER_WIDTH
	if zz > 0.0001:
		bw = minf(BORDER_WIDTH, BORDER_SCREEN_CAP / zz)
	if _data.l1_polygon.size() >= 3:
		draw_polyline(_closed(_data.l1_polygon), BORDER_COLOR, bw, true)
	# 6. hover 城市块描边（灰，固定屏幕像素粗细，不随缩放）
	if not hovered_tile_id.is_empty():
		var hw: float = HOVER_WIDTH
		if zz > 0.0001:
			hw = minf(HOVER_WIDTH, HOVER_SCREEN_CAP / zz)
		for tile in _data.tiles:
			if tile.tile_id == hovered_tile_id and tile.polygon.size() >= 3:
				draw_polyline(_closed(tile.polygon), HOVER_COLOR, hw, true)
				break
	# 8. F3 调试：城市编号（标在聚落位置）
	if DebugApi != null and DebugApi.is_visible():
		_draw_city_labels()


## 闭合多边形点列（首尾相连）
func _closed(pts: PackedVector2Array) -> PackedVector2Array:
	if pts.size() < 3:
		return pts
	var out := pts.duplicate()
	out.append(out[0])
	return out


## Array[[x,y],...] -> PackedVector2Array
func _pts(arr: Array) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for pt in arr:
		if pt is Array and pt.size() >= 2:
			pts.append(Vector2(float(pt[0]), float(pt[1])))
	return pts


## F3 调试：给城市打编号（屏幕恒定字号，不随缩放放大成大字）
func _draw_city_labels() -> void:
	var font := ThemeDB.fallback_font
	var zz: float = 1.0
	if _camera != null and _camera.has_method("get_zoom"):
		zz = _camera.get_zoom()
	var fs: float = LABEL_SCREEN_SIZE
	if zz > 0.0001:
		fs = clampf(LABEL_SCREEN_SIZE / zz, 13.0, 30.0)
	var halo: float = maxf(1.5, fs * 0.12)
	for tile in _data.tiles:
		if tile.settlement == null:
			continue
		var num := _city_num_from_tile_id(tile.tile_id)
		if num.is_empty():
			continue
		var pos := tile.settlement.position
		var txt := "L1城#" + num
		for off in [Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1)]:
			draw_string(font, pos + off * halo, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, LABEL_BG)
		draw_string(font, pos + Vector2(2.0, -fs * 0.35), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, LABEL_COLOR)


## 从 tile_id（"city_2082"）解析城市编号
func _city_num_from_tile_id(tile_id: String) -> String:
	var prefix := "city_"
	if tile_id.begins_with(prefix):
		return tile_id.substr(prefix.length())
	return tile_id
