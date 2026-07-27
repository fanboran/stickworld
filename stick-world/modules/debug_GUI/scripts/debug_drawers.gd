class_name DebugDrawers
extends RefCounted
## 调试绘制器集合 -- 各模块的调试可视化绘制函数。
##
## 详见 docs/技术/架构/场景与战斗架构.md §10.5.3。
## 每个绘制函数签名为 func(control: Control, ctx: Dictionary) -> void
## ctx 包含：
##   - camera: Camera2D       相机引用
##   - viewport_size: Vector2  视口尺寸
##   - effective_zoom: float   有效缩放
##   - map: Node2D             当前地图实例

# ─────────────────────────────── 辅助 ────────────────────────────────

## 世界坐标 -> 屏幕坐标
static func world_to_screen(world_pos: Vector2, ctx: Dictionary) -> Vector2:
	var cam_pos: Vector2 = ctx.get("camera_pos", Vector2.ZERO)
	var zoom: float = ctx.get("effective_zoom", 1.0)
	var vp_size: Vector2 = ctx.get("viewport_size", Vector2.ZERO)
	return (world_pos - cam_pos) * zoom + vp_size * 0.5


## 世界尺寸 -> 屏幕尺寸（仅缩放，无平移）
static func world_to_screen_size(world_size: float, ctx: Dictionary) -> float:
	var zoom: float = ctx.get("effective_zoom", 1.0)
	return world_size * zoom


# ─────────────────────────────── 绘制器 ────────────────────────────────

## PlacementGrid 竖向条带（绿=占用 红=不可建）+ 网格竖线
static func draw_grid(control: Control, ctx: Dictionary) -> void:
	var map: Node2D = ctx.get("map", null)
	if map == null or not is_instance_valid(map):
		return
	var grid: Node = map.get_node_or_null(WorldAPI.PATH_MAP_PLACEMENT_GRID)
	if grid == null:
		return
	var cell_size: float = float(grid.get("CELL_SIZE")) if grid.get("CELL_SIZE") != null else 32.0
	var gw: int = grid.grid_width
	var zoom: float = ctx.get("effective_zoom", 1.0)
	var screen_cell: float = cell_size * zoom
	var vp_size: Vector2 = ctx.get("viewport_size", Vector2.ZERO)
	var cam_pos: Vector2 = ctx.get("camera_pos", Vector2.ZERO)
	var view_left: float = cam_pos.x - vp_size.x / (2.0 * zoom)
	var view_right: float = cam_pos.x + vp_size.x / (2.0 * zoom)
	var view_top: float = cam_pos.y - vp_size.y / (2.0 * zoom)
	var view_bottom: float = cam_pos.y + vp_size.y / (2.0 * zoom)
	var cell_x_start: int = maxi(0, int(view_left / cell_size))
	var cell_x_end: int = mini(gw, int(view_right / cell_size) + 1)
	# 竖线范围（屏幕全高）
	var line_top := world_to_screen(Vector2(0, view_top), ctx).y
	var line_bottom := world_to_screen(Vector2(0, view_bottom), ctx).y
	# 绘制竖向条带
	for x in range(cell_x_start, cell_x_end):
		var world_x := x * cell_size
		var screen_x := world_to_screen(Vector2(world_x, 0), ctx).x
		if grid.is_occupied(x):
			if grid.is_blocked(x) and grid.get_occupant(x) == null:
				# BuildMask 标记的条带用红色
				control.draw_rect(Rect2(screen_x, line_top, screen_cell, line_bottom - line_top), Color(1.0, 0.3, 0.3, 0.15), true)
			else:
				# 建筑占用的条带用绿色
				control.draw_rect(Rect2(screen_x, line_top, screen_cell, line_bottom - line_top), Color(0.3, 1.0, 0.3, 0.15), true)
		elif grid.is_blocked(x):
			control.draw_rect(Rect2(screen_x, line_top, screen_cell, line_bottom - line_top), Color(1.0, 0.3, 0.3, 0.15), true)
		# 网格竖线
		control.draw_line(Vector2(screen_x, line_top), Vector2(screen_x, line_bottom), Color(1.0, 1.0, 1.0, 0.08), 1.0)


## WalkBarrier（蓝）+ PassageBarrier（紫）
static func draw_barriers(control: Control, ctx: Dictionary) -> void:
	var map: Node2D = ctx.get("map", null)
	if map == null or not is_instance_valid(map):
		return
	# WalkBarrier（蓝色半透明）
	if map.has_method("get_walk_barriers"):
		for area in map.get_walk_barriers():
			_draw_area_rect(control, ctx, area, Color(0.3, 0.3, 1.0, 0.3))
	# PassageBarrier（紫色半透明）
	if map.has_method("get_passage_barriers"):
		for area in map.get_passage_barriers():
			_draw_area_rect(control, ctx, area, Color(0.6, 0.2, 0.8, 0.3))


## 辅助：绘制 Area2D 的矩形范围
static func _draw_area_rect(control: Control, ctx: Dictionary, area: Area2D, color: Color) -> void:
	for child in area.get_children():
		if child is CollisionShape2D:
			var cs: CollisionShape2D = child as CollisionShape2D
			if cs.shape is RectangleShape2D:
				var rs: RectangleShape2D = cs.shape as RectangleShape2D
				var world_pos: Vector2 = area.global_position + cs.position
				var screen_pos := world_to_screen(world_pos, ctx)
				var screen_size := Vector2(rs.size.x * ctx.get("effective_zoom", 1.0), rs.size.y * ctx.get("effective_zoom", 1.0))
				var rect := Rect2(screen_pos - screen_size * 0.5, screen_size)
				control.draw_rect(rect, color, true)
				control.draw_rect(rect, Color(color.r, color.g, color.b, 0.8), false, 1.0)


## 建筑边界框（白）-- 基于 PassageBarrier CollisionShape2D
static func draw_buildings(control: Control, ctx: Dictionary) -> void:
	var map: Node2D = ctx.get("map", null)
	if map == null or not is_instance_valid(map):
		return
	var building_host: Node2D = map.get_node_or_null(WorldAPI.PATH_MAP_BUILDING_HOST)
	if building_host != null:
		for building in building_host.get_children():
			_draw_building_outline(control, ctx, building, Color(1.0, 1.0, 1.0, 0.6))
	# 地形建筑也绘制
	var terrain_buildings: Node2D = map.get_node_or_null(WorldAPI.PATH_MAP_TERRAIN_BUILDINGS)
	if terrain_buildings != null:
		for building in terrain_buildings.get_children():
			_draw_building_outline(control, ctx, building, Color(0.8, 0.8, 0.8, 0.4))


## 辅助：根据 PassageBarrier 绘制建筑边界框 + 碰撞体下边界红色标记线
static func _draw_building_outline(control: Control, ctx: Dictionary, building: Node2D, color: Color) -> void:
	var pb: Node = building.get_node_or_null("PassageBarrier")
	if pb == null or not pb is Area2D:
		return
	for child in pb.get_children():
		if child is CollisionShape2D:
			var cs: CollisionShape2D = child as CollisionShape2D
			if cs.shape is RectangleShape2D:
				var rs: RectangleShape2D = cs.shape as RectangleShape2D
				var world_pos: Vector2 = building.global_position + cs.position
				var screen_pos := world_to_screen(world_pos, ctx)
				var zoom: float = ctx.get("effective_zoom", 1.0)
				var screen_size := Vector2(rs.size.x * zoom, rs.size.y * zoom)
				var rect := Rect2(screen_pos - screen_size * 0.5, screen_size)
				control.draw_rect(rect, color, false, 1.5)
				# 红色下边界横线：按格子数 × 32px 绘制，居中对齐建筑位置
				var width_cells: int = maxi(1, int(round(rs.size.x / 32.0)))
				var footprint_px: float = width_cells * 32.0
				var bottom_y: float = screen_pos.y + screen_size.y * 0.5
				var foot_center_x: float = world_to_screen(Vector2(building.global_position.x, 0), ctx).x
				var foot_left_x: float = foot_center_x - footprint_px * zoom / 2.0
				var foot_right_x: float = foot_center_x + footprint_px * zoom / 2.0
				var tick_height: float = 20.0
				var red := Color(1.0, 0.2, 0.2, 0.9)
				control.draw_line(Vector2(foot_left_x, bottom_y), Vector2(foot_right_x, bottom_y), red, 2.0)
				control.draw_line(Vector2(foot_left_x, bottom_y), Vector2(foot_left_x, bottom_y - tick_height), red, 2.0)
				control.draw_line(Vector2(foot_right_x, bottom_y), Vector2(foot_right_x, bottom_y - tick_height), red, 2.0)


## ground_y 线（黄）+ ground_bottom 线（青）
static func draw_ground_lines(control: Control, ctx: Dictionary) -> void:
	var map: Node2D = ctx.get("map", null)
	if map == null or not is_instance_valid(map):
		return
	var ground_y: float = map.ground_y if "ground_y" in map else 0.0
	var ground_bottom: float = map.ground_bottom if "ground_bottom" in map else 0.0
	var map_left: float = map.map_left if "map_left" in map else 0.0
	var map_right: float = map.map_right if "map_right" in map else 0.0
	# ground_y 线（黄色）
	var p1 := world_to_screen(Vector2(map_left, ground_y), ctx)
	var p2 := world_to_screen(Vector2(map_right, ground_y), ctx)
	control.draw_line(p1, p2, Color(1.0, 1.0, 0.2, 0.8), 2.0)
	# ground_bottom 线（青色）
	p1 = world_to_screen(Vector2(map_left, ground_bottom), ctx)
	p2 = world_to_screen(Vector2(map_right, ground_bottom), ctx)
	control.draw_line(p1, p2, Color(0.2, 1.0, 1.0, 0.8), 2.0)


## Chunk 触发器范围（紫矩形边框）
static func draw_chunk_triggers(control: Control, ctx: Dictionary) -> void:
	var map: Node2D = ctx.get("map", null)
	if map == null or not is_instance_valid(map):
		return
	var chunk_triggers: Node2D = map.get_node_or_null(WorldAPI.PATH_MAP_CHUNK_TRIGGERS)
	if chunk_triggers == null:
		return
	for child in chunk_triggers.get_children():
		if child is Area2D:
			_draw_area_rect(control, ctx, child as Area2D, Color(0.6, 0.2, 0.8, 0.2))


## 火柴人状态文字（速度/动画/朝向/坐标）
static func draw_entity_states(control: Control, ctx: Dictionary) -> void:
	var map: Node2D = ctx.get("map", null)
	if map == null or not is_instance_valid(map):
		return
	var entity_host: Node2D = map.get_node_or_null(WorldAPI.PATH_MAP_ENTITY_HOST)
	if entity_host == null:
		return
	var font: Font = control.get_theme_default_font()
	var font_size: int = 12
	for entity in entity_host.get_children():
		if not entity is CharacterBody2D:
			continue
		var screen_pos := world_to_screen(entity.global_position, ctx)
		var info := "pos:(%d,%d)" % [int(entity.global_position.x), int(entity.global_position.y)]
		if "possessed" in entity:
			info += " %s" % ("[P]" if entity.possessed else "[AI]")
		if entity.has_method("get_current_anim"):
			info += " %s" % entity.get_current_anim()
		if entity.has_method("get_facing"):
			info += " face:%d" % entity.get_facing()
		control.draw_string(font, screen_pos + Vector2(-30, -50), info, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(1.0, 1.0, 1.0, 0.8))
