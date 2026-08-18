extends Node2D
class_name MapRenderer
## 战略图渲染器（L1 单层）—— 卫星图底图 + 边界线描边 + 聚落/道路/文字
##
## 详见 docs/技术/架构/战略图架构.md §4.5（L1 渲染，P0 简版用 _draw 不上 Shader）
##
## 渲染层次：
##   1. 卫星图底图（l1_base.png，地形色）
##   2. 每个 L1 地块边界线描边（政权色，不填充内部）
##   3. 聚落间道路（MST，白色虚线感实线）
##   4. 聚落图标（按级别大小）+ 聚落名文字
##   5. 悬停/选中高亮

## 关联的 L1 世界数据
var _data: L1WorldData = null

## 当前选中的聚落 ID（""表示无）
var selected_id: String = ""

## 当前悬停的地块/聚落
var hovered_tile_id: String = ""
var hovered_settlement_id: String = ""

## 选中高亮色
@export var selection_color: Color = Color(1.0, 0.85, 0.2, 0.9)

## 悬停高亮色
@export var hover_color: Color = Color(1.0, 1.0, 1.0, 0.6)

## 道路颜色
@export var road_color: Color = Color(0.95, 0.85, 0.6, 0.85)

## L1 地块边界粗线（出生 L1 权威轮廓，城市对外边界套用它；调试时强调）
@export var l1_border_color: Color = Color(0.08, 0.08, 0.08, 0.9)
@export var l1_border_width: float = 5.0

## 城市标号开关（G 键切换；调试时给每个城市地块打上编号）
var show_city_labels: bool = false

## 空聚落地块边界颜色（灰，表示贫瘠）
@export var empty_tile_color: Color = Color(0.6, 0.6, 0.6, 0.7)

## 边界线宽度
@export var border_width: float = 2.0

## 聚落图标最小半径（T1）
@export var icon_radius_min: float = 6.0

## 聚落图标半径递增（每级 +）
@export var icon_radius_step: float = 3.0

## 相机引用（悬停检测做 screen->map 坐标换算用）
var _camera: MapCamera = null


func set_data(data: L1WorldData) -> void:
	_data = data
	queue_redraw()


func set_camera(camera: MapCamera) -> void:
	_camera = camera


func select(id: String) -> void:
	selected_id = id
	queue_redraw()


func deselect() -> void:
	selected_id = ""
	queue_redraw()


func get_selected() -> String:
	return selected_id


func refresh() -> void:
	queue_redraw()


## G 键切换城市标号（调试）
func toggle_city_labels() -> void:
	show_city_labels = not show_city_labels
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
	var settlement: SettlementRef = query.get("settlement", null)
	var new_tile_id: String = tile.tile_id if tile != null else ""
	var new_settlement_id: String = settlement.settlement_id if settlement != null else ""
	if new_tile_id != hovered_tile_id or new_settlement_id != hovered_settlement_id:
		hovered_tile_id = new_tile_id
		hovered_settlement_id = new_settlement_id
		queue_redraw()


func _draw() -> void:
	if _data == null:
		return
	# 1. 卫星图底图
	if _data.base_texture != null:
		draw_texture(_data.base_texture, Vector2.ZERO)
	# 2. 地块边界线（政权色）
	for tile in _data.tiles:
		_draw_tile_border(tile)
	# 3. 道路
	for road in _data.roads:
		if road.size() >= 2:
			draw_polyline(road, road_color, 3.0)
	# 4. 聚落图标 + 名称
	for tile in _data.tiles:
		if tile.settlement != null:
			_draw_settlement(tile)
	# 4.5 L1 地块边界粗线（出生 L1 权威轮廓：贴边城市对外边界 = L1 边界，调试强调用）
	if _data.l1_polygon.size() >= 3 and show_city_labels:
		var l1p: PackedVector2Array = _data.l1_polygon
		l1p.append(l1p[0])
		draw_polyline(l1p, l1_border_color, l1_border_width)
	# 5. 悬停高亮（最后画，盖在图标上）
	if not hovered_tile_id.is_empty():
		for tile in _data.tiles:
			if tile.tile_id == hovered_tile_id:
				_draw_tile_border(tile, hover_color, border_width + 2.0)
				break


func _draw_tile_border(tile: L1TileDef, color: Color = Color.WHITE, width: float = -1.0) -> void:
	if tile.polygon.size() < 3:
		return
	if width < 0.0:
		width = border_width
	# 政权色（有归属）+ 选中高亮
	var border_color: Color = color
	if color == Color.WHITE:
		if not tile.owner_state_id.is_empty():
			border_color = _data.get_state_color(tile.owner_state_id)
		elif tile.is_empty():
			border_color = empty_tile_color
	# 闭合多边形描边（首尾相连）
	var pts: PackedVector2Array = tile.polygon
	pts.append(pts[0])
	draw_polyline(pts, border_color, width)


func _draw_settlement(tile: L1TileDef) -> void:
	var s: SettlementRef = tile.settlement
	var pos: Vector2 = s.position
	# 按级别大小画实心圆（城市最大）
	var radius: float = icon_radius_min + float(s.level - 1) * icon_radius_step
	var color: Color = _data.get_state_color(tile.owner_state_id) if not tile.owner_state_id.is_empty() else Color.GRAY
	var is_selected: bool = s.settlement_id == selected_id
	# 外圈（政权色）
	draw_circle(pos, radius + 2.0, color)
	# 内圈（白色，可读性）
	draw_circle(pos, radius * 0.6, Color(0.98, 0.98, 0.95, 0.95))
	# 选中环
	if is_selected:
		draw_arc(pos, radius + 5.0, 0.0, TAU, 24, selection_color, 2.5)
	# 名称文字
	draw_string(
		ThemeDB.fallback_font,
		pos + Vector2(radius + 4.0, -radius * 0.4),
		s.name,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		14,
		Color(1.0, 1.0, 1.0, 0.95)
	)
	# 城市标号（调试，G 键）：tile_id "city_XXXX" -> 编号
	if show_city_labels:
		var num := _city_num_from_tile_id(tile.tile_id)
		if not num.is_empty():
			draw_string(
				ThemeDB.fallback_font,
				pos + Vector2(-radius, radius + 18.0),
				"L1城#" + num,
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				maxf(14, radius * 0.8),
				Color(1.0, 0.88, 0.25, 0.95)
			)


## 从 tile_id（"city_2082"）解析城市编号
func _city_num_from_tile_id(tile_id: String) -> String:
	var prefix := "city_"
	if tile_id.begins_with(prefix):
		return tile_id.substr(prefix.length())
	return tile_id
