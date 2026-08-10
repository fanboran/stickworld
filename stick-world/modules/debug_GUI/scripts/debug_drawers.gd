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

## 建筑名称缓存（def_id -> name_zh）
static var _building_name_cache: Dictionary = {}

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
	# 阶段 F：使用动态边界（支持负数 cell_x）
	var gw_min: int = grid.get_min_cell() if grid.has_method("get_min_cell") else 0
	var gw_max: int = grid.get_max_cell() if grid.has_method("get_max_cell") else grid.grid_width - 1
	var zoom: float = ctx.get("effective_zoom", 1.0)
	var screen_cell: float = cell_size * zoom
	var vp_size: Vector2 = ctx.get("viewport_size", Vector2.ZERO)
	var cam_pos: Vector2 = ctx.get("camera_pos", Vector2.ZERO)
	var view_left: float = cam_pos.x - vp_size.x / (2.0 * zoom)
	var view_right: float = cam_pos.x + vp_size.x / (2.0 * zoom)
	var view_top: float = cam_pos.y - vp_size.y / (2.0 * zoom)
	var view_bottom: float = cam_pos.y + vp_size.y / (2.0 * zoom)
	var cell_x_start: int = maxi(gw_min, int(view_left / cell_size))
	var cell_x_end: int = mini(gw_max + 1, int(view_right / cell_size) + 1)
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


## 辅助：绘制障碍体的矩形范围（WalkBarrier/PassageBarrier 为 StaticBody2D）
static func _draw_area_rect(control: Control, ctx: Dictionary, area: Node2D, color: Color) -> void:
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
				# 红色下边界横线：按建筑 width 属性 × 32px 绘制，左边缘对齐碰撞箱左边缘（网格对齐）
				var width_cells: int = 1
				if "width" in building:
					width_cells = maxi(1, int(building.get("width")))
				else:
					width_cells = maxi(1, int(round(rs.size.x / 32.0)))
				var footprint_px: float = width_cells * 32.0
				var bottom_y: float = screen_pos.y + screen_size.y * 0.5
				var col_left_world: float = building.global_position.x + cs.position.x - rs.size.x / 2.0
				var foot_left_x: float = world_to_screen(Vector2(floor(col_left_world / 32.0) * 32.0, 0), ctx).x
				var foot_right_x: float = foot_left_x + footprint_px * zoom
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


## 火柴人 Collider 矩形（青色）-- 脚部物理碰撞箱
static func draw_entity_colliders(control: Control, ctx: Dictionary) -> void:
	var map: Node2D = ctx.get("map", null)
	if map == null or not is_instance_valid(map):
		return
	var entity_host: Node2D = map.get_node_or_null(WorldAPI.PATH_MAP_ENTITY_HOST)
	if entity_host == null:
		return
	var fill_color := Color(0.2, 1.0, 1.0, 0.2)
	var border_color := Color(0.2, 1.0, 1.0, 0.8)
	var zoom: float = ctx.get("effective_zoom", 1.0)
	for entity in entity_host.get_children():
		if not entity is CharacterBody2D:
			continue
		var col: CollisionShape2D = entity.get_node_or_null("Collider") as CollisionShape2D
		if col == null or not (col.shape is RectangleShape2D):
			continue
		var rs: RectangleShape2D = col.shape as RectangleShape2D
		var screen_pos := world_to_screen(col.global_position, ctx)
		var screen_size := Vector2(rs.size.x * zoom, rs.size.y * zoom)
		var rect := Rect2(screen_pos - screen_size * 0.5, screen_size)
		control.draw_rect(rect, fill_color, true)
		control.draw_rect(rect, border_color, false, 1.0)


## 垂直地形网格（橙线）-- 地面带内按 32px 分行，用于资源点定位
static func draw_terrain_grid(control: Control, ctx: Dictionary) -> void:
	var map: Node2D = ctx.get("map", null)
	if map == null or not is_instance_valid(map):
		return
	var ground_y: float = map.ground_y if "ground_y" in map else 810.0
	var ground_bottom: float = map.ground_bottom if "ground_bottom" in map else 1080.0
	var map_left: float = map.map_left if "map_left" in map else 0.0
	var map_right: float = map.map_right if "map_right" in map else 8192.0
	var cell_size: float = 32.0
	var zoom: float = ctx.get("effective_zoom", 1.0)
	var cam_pos: Vector2 = ctx.get("camera_pos", Vector2.ZERO)
	var vp_size: Vector2 = ctx.get("viewport_size", Vector2.ZERO)
	var view_left: float = cam_pos.x - vp_size.x / (2.0 * zoom)
	var view_right: float = cam_pos.x + vp_size.x / (2.0 * zoom)
	var clamped_left: float = maxf(view_left, map_left)
	var clamped_right: float = minf(view_right, map_right)
	var row_count: int = int((ground_bottom - ground_y) / cell_size)
	for row in range(row_count + 1):
		var y: float = ground_y + row * cell_size
		var p1 := world_to_screen(Vector2(clamped_left, y), ctx)
		var p2 := world_to_screen(Vector2(clamped_right, y), ctx)
		control.draw_line(p1, p2, Color(1.0, 0.6, 0.2, 0.15), 1.0)


## 资源点标记（彩色小方块 + 储量文字）
static func draw_resource_nodes(control: Control, ctx: Dictionary) -> void:
	var map: Node2D = ctx.get("map", null)
	if map == null or not is_instance_valid(map):
		return
	var zoom: float = ctx.get("effective_zoom", 1.0)
	var nodes: Array = map.get_tree().get_nodes_in_group("resource_node")
	var font: Font = control.get_theme_default_font()
	for node in nodes:
		if not node is Node2D or not is_instance_valid(node):
			continue
		var n: Node2D = node as Node2D
		var screen_pos := world_to_screen(n.global_position, ctx)
		var s: float = 16.0 * zoom
		# 资源类型颜色
		var rtype: int = n.get("resource_type") if "resource_type" in n else 0
		var colors: Array[Color] = [
			Color(0.2, 0.6, 0.2, 0.6),  # WOOD=绿
			Color(0.5, 0.5, 0.5, 0.6),  # STONE=灰
			Color(0.6, 0.3, 0.2, 0.6),  # METAL=棕
		]
		var c: Color = colors[rtype] if rtype < colors.size() else Color.WHITE
		control.draw_rect(Rect2(screen_pos - Vector2(s * 0.5, s * 0.5), Vector2(s, s)), c, true)
		control.draw_rect(Rect2(screen_pos - Vector2(s * 0.5, s * 0.5), Vector2(s, s)), Color(c.r, c.g, c.b, 1.0), false, 1.0)
		# 储量文字
		var amount: int = n.get("amount") if "amount" in n else 0
		var text: String = str(amount)
		control.draw_string(font, screen_pos + Vector2(-10, s * 0.5 + 12), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1.0, 1.0, 1.0, 0.8))


## 建筑名称（建筑头顶显示中文名 + def_id）
static func draw_building_names(control: Control, ctx: Dictionary) -> void:
	var map: Node2D = ctx.get("map", null)
	if map == null or not is_instance_valid(map):
		return
	var font: Font = control.get_theme_default_font()
	# 扫描 BuildingHost（动态建筑）
	var hosts: Array[Node] = []
	var bh: Node2D = map.get_node_or_null(WorldAPI.PATH_MAP_BUILDING_HOST)
	if bh != null:
		hosts.append(bh)
	var tb: Node2D = map.get_node_or_null(WorldAPI.PATH_MAP_TERRAIN_BUILDINGS)
	if tb != null:
		hosts.append(tb)
	for host in hosts:
		for building in host.get_children():
			if not building is Node2D:
				continue
			var def_id: String = ""
			if "def_id" in building:
				def_id = str(building.def_id)
			if def_id.is_empty():
				continue
			var name_zh: String = _get_building_name(def_id)
			# 在建筑上方绘制名称
			var offset_y: float = -80.0
			if building.has_method("get_collision_bottom_local"):
				offset_y = building.get_collision_bottom_local() - 20.0
			var label_pos := world_to_screen(building.global_position + Vector2(0, offset_y), ctx)
			# 半透明背景
			var label_text: String = "%s (%s)" % [name_zh, def_id]
			var ts: Vector2 = font.get_string_size(label_text, HORIZONTAL_ALIGNMENT_CENTER, -1, 11)
			control.draw_rect(Rect2(label_pos - Vector2(ts.x * 0.5 + 4, 2), ts + Vector2(8, 4)), Color(0.0, 0.0, 0.0, 0.6), true)
			control.draw_string(font, label_pos + Vector2(-ts.x * 0.5, ts.y - 1), label_text, HORIZONTAL_ALIGNMENT_CENTER, -1, 11, Color(1.0, 1.0, 0.8, 0.95))


## 从 buildings.tres 加载建筑名称缓存
static func _load_building_names() -> void:
	_building_name_cache.clear()
	var res: Resource = load("res://config/buildings/buildings.tres")
	if res == null or not (res.get("variables") is Dictionary):
		return
	var data: Array = res.variables.get("data", [])
	for entry in data:
		if entry is Dictionary and entry.has("id"):
			_building_name_cache[entry["id"]] = String(entry.get("name_zh", entry["id"]))


static func _get_building_name(def_id: String) -> String:
	if _building_name_cache.is_empty():
		_load_building_names()
	return _building_name_cache.get(def_id, def_id)


## 世界坐标水平标尺（地平线上，标注世界原点 0 + 每10格标数字）
static func draw_world_ruler(control: Control, ctx: Dictionary) -> void:
	var map: Node2D = ctx.get("map", null)
	if map == null or not is_instance_valid(map):
		return
	var ground_y: float = map.ground_y if "ground_y" in map else 810.0
	var map_left: float = map.map_left if "map_left" in map else 0.0
	var map_right: float = map.map_right if "map_right" in map else 8192.0
	var zoom: float = ctx.get("effective_zoom", 1.0)
	var cam_pos: Vector2 = ctx.get("camera_pos", Vector2.ZERO)
	var vp_size: Vector2 = ctx.get("viewport_size", Vector2.ZERO)
	var view_left: float = cam_pos.x - vp_size.x / (2.0 * zoom)
	var view_right: float = cam_pos.x + vp_size.x / (2.0 * zoom)
	var font: Font = control.get_theme_default_font()
	# 水平基准线
	var p1 := world_to_screen(Vector2(maxf(view_left, map_left), ground_y), ctx)
	var p2 := world_to_screen(Vector2(minf(view_right, map_right), ground_y), ctx)
	control.draw_line(p1, p2, Color(0.8, 0.8, 0.8, 0.3), 1.0)
	# 自适应刻度间距：目标屏幕间距 ~60px，世界间距向上取整到 32px（1 cell）的倍数
	var target_screen_step: float = 60.0
	var world_step: float = target_screen_step / zoom
	world_step = maxf(32.0, ceil(world_step / 32.0) * 32.0)
	# 每 10 格（320px）标数字
	var label_step: float = 320.0
	var clamped_left: float = maxf(view_left, map_left)
	var clamped_right: float = minf(view_right, map_right)
	var start_x: int = int(clamped_left / world_step) * int(world_step)
	var end_x: int = int(clamped_right / world_step) * int(world_step) + int(world_step)
	var x: float = float(start_x)
	while x <= end_x:
		var screen_x: float = world_to_screen(Vector2(x, ground_y), ctx).x
		var is_label: bool = absf(fmod(x, label_step)) < 0.5  # 每 10 格标数字
		var tick_len: float = 10.0 if is_label else 4.0
		var tick_color: Color = Color(0.9, 0.9, 0.9, 0.6) if is_label else Color(0.7, 0.7, 0.7, 0.35)
		control.draw_line(Vector2(screen_x, p1.y), Vector2(screen_x, p1.y + tick_len), tick_color, 1.0)
		if is_label:
			var cell_num: int = int(x / 32.0)
			if x == 0.0:
				control.draw_string(font, Vector2(screen_x - 40, p1.y + 24), "★ 0 (世界原点)", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1.0, 0.8, 0.2, 0.95))
			else:
				control.draw_string(font, Vector2(screen_x - 16, p1.y + 24), "cell %d" % cell_num, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.8, 0.8, 0.85, 0.7))
		x += world_step


## 鼠标位置调试信息（鼠标旁边显示世界坐标）
static func draw_entity_info(control: Control, ctx: Dictionary) -> void:
	var camera: Camera2D = ctx.get("camera", null) as Camera2D
	if camera == null:
		return
	var zoom: float = ctx.get("effective_zoom", 1.0)
	var cam_pos: Vector2 = ctx.get("camera_pos", Vector2.ZERO)
	var vp_size: Vector2 = ctx.get("viewport_size", Vector2.ZERO)
	var mouse_screen: Vector2 = control.get_viewport().get_mouse_position()
	var mouse_world: Vector2 = (mouse_screen - vp_size * 0.5) / zoom + cam_pos
	var font: Font = control.get_theme_default_font()
	# 鼠标旁边显示绿色世界坐标
	var diag_pos := world_to_screen(mouse_world, ctx)
	control.draw_string(
		font, diag_pos + Vector2(12, -12),
		"世界:(%d,%d)" % [int(mouse_world.x), int(mouse_world.y)],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.8, 1.0, 0.8, 0.7)
	)
