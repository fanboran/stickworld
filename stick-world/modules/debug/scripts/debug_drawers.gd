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

## PlacementGrid 占用格（绿）+ BuildMask 不可放建筑格（红）
static func draw_grid(control: Control, ctx: Dictionary) -> void:
	var map: Node2D = ctx.get("map", null)
	if map == null or not is_instance_valid(map):
		return
	var grid: Node = map.get_node_or_null(WorldAPI.PATH_MAP_PLACEMENT_GRID)
	if grid == null:
		return
	var cell_size: float = float(grid.get("CELL_SIZE")) if grid.get("CELL_SIZE") != null else 32.0
	var gw: int = grid.grid_width
	var gh: int = grid.grid_height
	var zoom: float = ctx.get("effective_zoom", 1.0)
	var screen_cell: float = cell_size * zoom
	# 仅绘制可见范围内的格子
	var vp_size: Vector2 = ctx.get("viewport_size", Vector2.ZERO)
	var cam_pos: Vector2 = ctx.get("camera_pos", Vector2.ZERO)
	var view_left: float = cam_pos.x - vp_size.x / (2.0 * zoom)
	var view_right: float = cam_pos.x + vp_size.x / (2.0 * zoom)
	var cell_x_start: int = maxi(0, int(view_left / cell_size))
	var cell_x_end: int = mini(gw, int(view_right / cell_size) + 1)
	# 绘制占用格（绿色半透明）和 BuildMask 格（红色半透明）
	for x in range(cell_x_start, cell_x_end):
		for y in range(gh):
			var world_pos := Vector2(x * cell_size, y * cell_size)
			var screen_pos := world_to_screen(world_pos, ctx)
			var rect := Rect2(screen_pos, Vector2(screen_cell, screen_cell))
			if grid.is_occupied(x, y):
				# BuildMask 标记的格用红色，建筑占用的用绿色
				if grid.is_blocked(x, y) and not grid.get_occupant(x, y) != null:
					control.draw_rect(rect, Color(1.0, 0.3, 0.3, 0.3), true)
				else:
					control.draw_rect(rect, Color(0.3, 1.0, 0.3, 0.3), true)
			elif grid.is_blocked(x, y):
				control.draw_rect(rect, Color(1.0, 0.3, 0.3, 0.3), true)


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


## 建筑边界框（白）
static func draw_buildings(control: Control, ctx: Dictionary) -> void:
	var map: Node2D = ctx.get("map", null)
	if map == null or not is_instance_valid(map):
		return
	var building_host: Node2D = map.get_node_or_null(WorldAPI.PATH_MAP_BUILDING_HOST)
	if building_host == null:
		return
	for building in building_host.get_children():
		var footprint: Node = building.get_node_or_null("Footprint") if building.has_method("get_node_or_null") else null
		if footprint != null and footprint is CollisionShape2D:
			var cs: CollisionShape2D = footprint as CollisionShape2D
			if cs.shape is RectangleShape2D:
				var rs: RectangleShape2D = cs.shape as RectangleShape2D
				var world_pos: Vector2 = building.global_position + cs.position
				var screen_pos := world_to_screen(world_pos, ctx)
				var zoom: float = ctx.get("effective_zoom", 1.0)
				var screen_size := Vector2(rs.size.x * zoom, rs.size.y * zoom)
				var rect := Rect2(screen_pos - screen_size * 0.5, screen_size)
				control.draw_rect(rect, Color(1.0, 1.0, 1.0, 0.6), false, 1.5)
	# 地形建筑也绘制
	var terrain_buildings: Node2D = map.get_node_or_null(WorldAPI.PATH_MAP_TERRAIN_BUILDINGS)
	if terrain_buildings != null:
		for building in terrain_buildings.get_children():
			var footprint: Node = building.get_node_or_null("Footprint") if building.has_method("get_node_or_null") else null
			if footprint != null and footprint is CollisionShape2D:
				var cs: CollisionShape2D = footprint as CollisionShape2D
				if cs.shape is RectangleShape2D:
					var rs: RectangleShape2D = cs.shape as RectangleShape2D
					var world_pos: Vector2 = building.global_position + cs.position
					var screen_pos := world_to_screen(world_pos, ctx)
					var zoom: float = ctx.get("effective_zoom", 1.0)
					var screen_size := Vector2(rs.size.x * zoom, rs.size.y * zoom)
					var rect := Rect2(screen_pos - screen_size * 0.5, screen_size)
					control.draw_rect(rect, Color(0.8, 0.8, 0.8, 0.4), false, 1.0)


## ground_y 线（黄）+ ground_bottom 线（青）
static func draw_ground_lines(control: Control, ctx: Dictionary) -> void:
	var map: Node2D = ctx.get("map", null)
	if map == null or not is_instance_valid(map):
		return
	var ground_y: float = map.ground_y if "ground_y" in map else 0.0
	var ground_bottom: float = map.ground_bottom if "ground_bottom" in map else 0.0
	var map_left: float = map.map_left if "map_left" in map else 0.0
	var map_right: float = map.map_right if "map_right" in map else 0.0
	var vp_size: Vector2 = ctx.get("viewport_size", Vector2.ZERO)
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
