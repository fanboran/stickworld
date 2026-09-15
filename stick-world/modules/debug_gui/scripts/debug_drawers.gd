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
##   - map_paths: Dictionary   地图节点路径表（world 装配层注入，键见 system_setup.register_debug_drawers）

## 建筑名称缓存（def_id -> name_zh）
static var _building_name_cache: Dictionary = {}

# ─────────────────────────────── 辅助 ────────────────────────────────

## 世界坐标 -> 屏幕坐标：经 viewport canvas_transform（引擎真值，zoom/vp/相机
## 全部由变换一次承载——缩放算进变换，消费点不再各自附加）。与旧手搓公式
## (pos−cam)·zoom+vp/2 在 CameraRig 居中锚定下逐像素等价；相机 offset/limits
## 变化时手搓会漂而变换不会（协议：禁止手搓相机公式）。
## ctx 无 control（headless 直调）时退回手搓兜底。
static func world_to_screen(world_pos: Vector2, ctx: Dictionary) -> Vector2:
	var control: Control = ctx.get("control", null)
	if control != null and control.is_inside_tree():
		return control.get_viewport().get_canvas_transform() * world_pos
	var cam_pos: Vector2 = ctx.get("camera_pos", Vector2.ZERO)
	var zoom: float = ctx.get("effective_zoom", 1.0)
	var vp_size: Vector2 = ctx.get("viewport_size", Vector2.ZERO)
	return (world_pos - cam_pos) * zoom + vp_size * 0.5


## 世界尺寸 -> 屏幕尺寸（仅缩放，无平移）
static func world_to_screen_size(world_size: float, ctx: Dictionary) -> float:
	var zoom: float = ctx.get("effective_zoom", 1.0)
	return world_size * zoom


## 按注入的路径表从地图取子节点（路径由 world 装配层注入 ctx["map_paths"]，本模块不 import WorldAPI）
static func _map_child(map: Node, ctx: Dictionary, key: String) -> Node:
	var path: String = ctx.get("map_paths", {}).get(key, "")
	return map.get_node_or_null(path) if path != "" else null


## HD-2D 图地面 y 重映射：地图声明 remap_fx_pos 时把行走带 y 压进 3D 投影域
## （2D 图原样返回）。F3 抽屉画"地面锚定物"（线/框/文字/标记）一律经此口，
## 禁止按 2D y 直绘——否则与 3D 世界错开 (1-压缩率) 倍，公式见
## docs/技术/架构/建筑管线/HD-2D街景系统.md §屏幕映射
static func _ground_y(map: Node, y: float) -> float:
	if map != null and is_instance_valid(map) and map.has_method("remap_fx_pos"):
		return (map.remap_fx_pos(Vector2(0.0, y)) as Vector2).y
	return y


# ─────────────────────────────── 绘制器 ────────────────────────────────

## PlacementGrid 竖向条带（绿=占用 红=不可建）+ 网格竖线
static func draw_grid(control: Control, ctx: Dictionary) -> void:
	var map: Node2D = ctx.get("map", null)
	if map == null or not is_instance_valid(map):
		return
	var grid: Node = _map_child(map, ctx, "placement_grid")
	if grid == null:
		# HD-2D 图无 PlacementGrid：整格浅网格画在建筑段包络内
		# （创始人 2026-09-15：画"地面的建筑段内"），样式=2D 图 F3 白色口径
		if map.has_method("get_building_rects"):
			_draw_hd2d_cell_lines(control, ctx, map)
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


## HD-2D 建筑段整格浅网格（F3 grid_drawer 开关管辖）：32px（1 格）一条竖线，
## 横纵都裁在建筑占地包络内（创始人 2026-09-15：画"地面的建筑段内"），
## 纵向经 _ground_y 压进 3D 投影域，样式对齐 2D 图 F3（白 0.08 细线）。
## 占地带四元组口径：x=格（×32 转 px）、y=px（与 get_solid_rects/碰撞墙同源）
static func _draw_hd2d_cell_lines(control: Control, ctx: Dictionary, map: Node2D) -> void:
	var rects: Array = map.get_building_rects()
	if rects.is_empty():
		return
	var x0: float = INF
	var x1: float = -INF
	var y_top: float = INF
	var y_bottom: float = -INF
	for r: Variant in rects:
		x0 = minf(x0, float(r[0]))
		x1 = maxf(x1, float(r[1]))
		y_top = minf(y_top, float(r[2]))
		y_bottom = maxf(y_bottom, float(r[3]))
	var zoom: float = ctx.get("effective_zoom", 1.0)
	var cam_pos: Vector2 = ctx.get("camera_pos", Vector2.ZERO)
	var vp_size: Vector2 = ctx.get("viewport_size", Vector2.ZERO)
	var view_left: float = cam_pos.x - vp_size.x / (2.0 * zoom)
	var view_right: float = cam_pos.x + vp_size.x / (2.0 * zoom)
	var line_top: float = world_to_screen(Vector2(0.0, _ground_y(map, y_top)), ctx).y
	var line_bottom: float = world_to_screen(Vector2(0.0, _ground_y(map, y_bottom)), ctx).y
	var col := Color(1.0, 1.0, 1.0, 0.08)
	var x: float = ceilf(maxf(x0 * 32.0, view_left) / 32.0) * 32.0
	var to_x: float = minf(x1 * 32.0, view_right)
	while x <= to_x:
		var screen_x: float = world_to_screen(Vector2(x, 0.0), ctx).x
		control.draw_line(Vector2(screen_x, line_top), Vector2(screen_x, line_bottom), col, 1.0)
		x += 32.0


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
	var map: Node2D = ctx.get("map", null)
	var remaps: bool = map != null and is_instance_valid(map) and map.has_method("remap_fx_pos")
	for child in area.get_children():
		if child is CollisionShape2D:
			# HD-2D 建筑形状（meta 打标，见 Hd2dStreetMap._build_solid_bodies）
			# 的显示改由 draw_buildings 直立包楼框承担，这里跳过防双重绘制
			if child.has_meta("hd2d_building"):
				continue
			var cs: CollisionShape2D = child as CollisionShape2D
			if cs.shape is RectangleShape2D:
				var rs: RectangleShape2D = cs.shape as RectangleShape2D
				var world_pos: Vector2 = area.global_position + cs.position
				var size_y: float = rs.size.y
				if remaps:
					# HD-2D 图：碰撞箱画进 3D 投影域（y 压缩率与角色渲染一致），
					# 否则蓝箱与角色实际所在画面位置对不上（创始人 2026-09-14）
					var y0: float = map.remap_fx_pos(Vector2(0.0, world_pos.y - rs.size.y * 0.5)).y
					var y1: float = map.remap_fx_pos(Vector2(0.0, world_pos.y + rs.size.y * 0.5)).y
					world_pos.y = (y0 + y1) * 0.5
					size_y = y1 - y0
				var screen_pos := world_to_screen(world_pos, ctx)
				var screen_size := Vector2(rs.size.x * ctx.get("effective_zoom", 1.0), size_y * ctx.get("effective_zoom", 1.0))
				var rect := Rect2(screen_pos - screen_size * 0.5, screen_size)
				control.draw_rect(rect, color, true)
				control.draw_rect(rect, Color(color.r, color.g, color.b, 0.8), false, 1.0)


## 建筑边界框（白）-- 基于 PassageBarrier CollisionShape2D
static func draw_buildings(control: Control, ctx: Dictionary) -> void:
	var map: Node2D = ctx.get("map", null)
	if map == null or not is_instance_valid(map):
		return
	var building_host: Node2D = _map_child(map, ctx, "building_host")
	if building_host != null:
		for building in building_host.get_children():
			_draw_building_outline(control, ctx, building, Color(1.0, 1.0, 1.0, 0.6))
	# 地形建筑也绘制
	var terrain_buildings: Node2D = _map_child(map, ctx, "terrain_buildings")
	if terrain_buildings != null:
		for building in terrain_buildings.get_children():
			_draw_building_outline(control, ctx, building, Color(0.8, 0.8, 0.8, 0.4))
	# HD-2D 图：2D 建筑宿主为空壳（视觉在 3D 卡片），建筑左右边界竖线直接取
	# 3D 侧占地数据（F3 building_drawer 开关管辖；白 0.6 口径同 2D 描边，
	# 宽度=建筑格宽，经 _ground_y 压进 3D 投影域）
	if map.has_method("get_building_rects"):
		var edge_col := Color(1.0, 1.0, 0.6)
		for r: Variant in map.get_building_rects():
			var top_y: float = world_to_screen(Vector2(0.0, _ground_y(map, float(r[2]))), ctx).y
			var bot_y: float = world_to_screen(Vector2(0.0, _ground_y(map, float(r[3]))), ctx).y
			# 占地带 x=格（×32 转 px）、y=px（混合口径，见 _draw_hd2d_cell_lines 注）
			for rx: float in [float(r[0]) * 32.0, float(r[1]) * 32.0]:
				var sx: float = world_to_screen(Vector2(rx, 0.0), ctx).x
				control.draw_line(Vector2(sx, top_y), Vector2(sx, bot_y), edge_col, 1.5)
			# 占地格子宽度显示（创始人 2026-09-15：左右边界竖线+逐格浅线，
			# 一格一档数宽，不标数字）：footprint 内部每 1 格一条浅分隔线，
			# 压在紫占地带上仍可读
			var cells_n := maxi(1, int(round(float(r[1]) - float(r[0]))))
			for i in range(1, cells_n):
				var cx_line: float = world_to_screen(
						Vector2((float(r[0]) + i) * 32.0, 0.0), ctx).x
				control.draw_line(Vector2(cx_line, top_y), Vector2(cx_line, bot_y),
						Color(1.0, 1.0, 1.0, 0.35), 1.0)
			# 紫色占地带（PassageBarrier 口径，2D 图建筑紫框语义；创始人 2026-09-15
			# 问"紫色碰撞箱是不是不显示了"）：真实墙脚 footprint 的地面投影，
			# y0/y1 各自 remap——占地贴着楼脚，不再躺到楼前街面上
			var px0: float = world_to_screen(Vector2(float(r[0]) * 32.0, 0.0), ctx).x
			var px1: float = world_to_screen(Vector2(float(r[1]) * 32.0, 0.0), ctx).x
			var prect := Rect2(Vector2(px0, top_y), Vector2(px1 - px0, bot_y - top_y))
			control.draw_rect(prect, Color(0.6, 0.2, 0.8, 0.3), true)
			control.draw_rect(prect, Color(0.6, 0.2, 0.8, 0.8), false, 1.0)
			# 直立包楼框（白 0.6 描边）：底=卡底基线（贴卡底贴地落位）、
			# 宽=**占位格宽**（[6][7]，4 格整倍数槽位——创始人已认可口径；
			# 真实墙脚 footprint=[0][1] 归紫占地带）、高=卡可见高——框住楼的
			# 视觉范围；真实地面阻挡带=[2][3] 即上面紫带
			if r.size() >= 6:
				var occ_x0: float = float(r[6]) if r.size() >= 8 else float(r[0])
				var occ_x1: float = float(r[7]) if r.size() >= 8 else float(r[1])
				var bx0: float = world_to_screen(Vector2(occ_x0 * 32.0, 0.0), ctx).x
				var bx1: float = world_to_screen(Vector2(occ_x1 * 32.0, 0.0), ctx).x
				var base_line: float = world_to_screen(
						Vector2(0.0, _ground_y(map, float(r[4]))), ctx).y
				var box_h: float = float(r[5]) * ctx.get("effective_zoom", 1.0)
				var brect := Rect2(Vector2(bx0, base_line - box_h), Vector2(bx1 - bx0, box_h))
				control.draw_rect(brect, edge_col, false, 1.5)


## 辅助：根据 PassageBarrier 绘制建筑边界框 + 碰撞体下边界红色标记线
static func _draw_building_outline(control: Control, ctx: Dictionary, building: Node2D, color: Color) -> void:
	var map: Node2D = ctx.get("map", null)
	var remaps: bool = map != null and is_instance_valid(map) and map.has_method("remap_fx_pos")
	var pb: Node = building.get_node_or_null("PassageBarrier")
	if pb == null or not pb is Area2D:
		return
	for child in pb.get_children():
		if child is CollisionShape2D:
			var cs: CollisionShape2D = child as CollisionShape2D
			if cs.shape is RectangleShape2D:
				var rs: RectangleShape2D = cs.shape as RectangleShape2D
				var world_pos: Vector2 = building.global_position + cs.position
				var size_y: float = rs.size.y
				if remaps:
					# HD-2D 图：建筑碰撞箱同蓝箱口径画进 3D 投影域
					var y0: float = map.remap_fx_pos(Vector2(0.0, world_pos.y - rs.size.y * 0.5)).y
					var y1: float = map.remap_fx_pos(Vector2(0.0, world_pos.y + rs.size.y * 0.5)).y
					world_pos.y = (y0 + y1) * 0.5
					size_y = y1 - y0
				var screen_pos := world_to_screen(world_pos, ctx)
				var zoom: float = ctx.get("effective_zoom", 1.0)
				var screen_size := Vector2(rs.size.x * zoom, size_y * zoom)
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
	# HD-2D 图：黄线 = 前后景分界线（zoom=1 压屏幕下 1/3 线；旧文档叫
	# "地平线"，实为前后景分界——创始人 2026-09-15 术语校准），不再用
	# ground_y（那是 2D 村图"地面线"语义，落到街面中间）；青线 = 屏幕底沿锚线不变
	var yellow_y: float = map.ground_y if "ground_y" in map else 0.0
	if map.has_method("get_fg_bg_boundary_y"):
		yellow_y = map.get_fg_bg_boundary_y()
	var ground_y: float = _ground_y(map, yellow_y)
	var ground_bottom: float = _ground_y(map, map.ground_bottom if "ground_bottom" in map else 0.0)
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
	var chunk_triggers: Node2D = _map_child(map, ctx, "chunk_triggers")
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
	var entity_host: Node2D = _map_child(map, ctx, "entity_host")
	if entity_host == null:
		return
	var font: Font = control.get_theme_default_font()
	var font_size: int = 12
	for entity in entity_host.get_children():
		if not entity is CharacterBody2D:
			continue
		var screen_pos := world_to_screen(Vector2(
				entity.global_position.x, _ground_y(map, entity.global_position.y)), ctx)
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
	var entity_host: Node2D = _map_child(map, ctx, "entity_host")
	if entity_host == null:
		return
	var fill_color := Color(0.2, 1.0, 1.0, 0.2)
	var border_color := Color(0.2, 1.0, 1.0, 0.8)
	var zoom: float = ctx.get("effective_zoom", 1.0)
	# HD-2D 图：角色渲染在 3D 投影域——碰撞箱按 2D 投影直绘会与角色
	# "定位不重合、纵向速差"。宿主声明 remap_fx_pos 时把箱中心压到
	# 3D 投影同一地面线；箱体尺寸不压（创始人：压扁的碰撞箱读不出碰撞语义）
	var remaps: bool = map.has_method("remap_fx_pos")
	for entity in entity_host.get_children():
		if not entity is CharacterBody2D:
			continue
		var col: CollisionShape2D = entity.get_node_or_null("Collider") as CollisionShape2D
		if col == null or not (col.shape is RectangleShape2D):
			continue
		var rs: RectangleShape2D = col.shape as RectangleShape2D
		var w: float = rs.size.x * zoom
		var h: float = rs.size.y * zoom
		if remaps:
			# HD-2D：画在**物理碰撞位**（F3=碰撞真相）。物理脚印已由实体
			# origin 空间口径贴到视觉脚线（Collider 居 origin，stickman_entity
			# set_ground_constraints 门控）——物理位=脚下线框位，两口径合一
			# （创始人 2026-09-16："碰撞箱要和脚下线框一个位置"+"蓝紫相撞
			# 真的会停"）。箱心经 remap（含台面 lift），宽高不压、x 用物理箱
			# 真实横向范围。
			var c_world: Vector2 = map.remap_fx_pos(col.global_position)
			var screen_pos := world_to_screen(c_world, ctx)
			var rect := Rect2(screen_pos - Vector2(w, h) * 0.5, Vector2(w, h))
			control.draw_rect(rect, fill_color, true)
			control.draw_rect(rect, border_color, false, 1.0)
		else:
			var wpos: Vector2 = col.global_position
			var screen_pos := world_to_screen(wpos, ctx)
			var rect := Rect2(screen_pos - Vector2(w, h) * 0.5, Vector2(w, h))
			control.draw_rect(rect, fill_color, true)
			control.draw_rect(rect, border_color, false, 1.0)


## 垂直地形网格（橙线）-- 地面带内按 32px 分行，用于资源点定位
static func draw_terrain_grid(control: Control, ctx: Dictionary) -> void:
	var map: Node2D = ctx.get("map", null)
	if map == null or not is_instance_valid(map):
		return
	# HD-2D 图不画：分行语义属于 2D 图的底部地面条带，HD-2D 的
	# ground_y~ground_bottom 覆盖整个可见街面，横线会铺满全屏（创始人 2026-09-15）
	if map.has_method("remap_fx_pos"):
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
	# 调试可视化职责豁免：直接读地图资源节点（本模块职责就是可视化 map 内容，2026-08 审计标注）
	var nodes: Array = map.get_tree().get_nodes_in_group("resource_node")
	var font: Font = control.get_theme_default_font()
	for node in nodes:
		if not node is Node2D or not is_instance_valid(node):
			continue
		var n: Node2D = node as Node2D
		var screen_pos := world_to_screen(
				Vector2(n.global_position.x, _ground_y(map, n.global_position.y)), ctx)
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
	var bh: Node2D = _map_child(map, ctx, "building_host")
	if bh != null:
		hosts.append(bh)
	var tb: Node2D = _map_child(map, ctx, "terrain_buildings")
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
	var ground_y: float = _ground_y(map, map.ground_y if "ground_y" in map else 810.0)
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
	# HD-2D 图：垂直方向 3D 取景固定（不随 2D 相机纵移），鼠标命中的是地面
	# 点——y 走压缩逆变换（x 仍是仿射）；2D 图维持仿射逆变换
	var map: Node2D = ctx.get("map", null)
	if map != null and is_instance_valid(map) and map.has_method("screen_y_to_ground_y"):
		mouse_world.y = map.screen_y_to_ground_y(mouse_screen.y, zoom)
	var font: Font = control.get_theme_default_font()
	# 鼠标旁边显示绿色世界坐标（标签钉鼠标屏幕位——HD-2D 的世界 y 是地面带
	# 坐标，经 2D 投影回屏幕会漂，不能再用 world_to_screen）
	control.draw_string(
		font, mouse_screen + Vector2(12, -12),
		"世界:(%d,%d)" % [int(mouse_world.x), int(mouse_world.y)],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.8, 1.0, 0.8, 0.7)
	)


## TeamAi 姿态 HUD 开关占位（W1 观测接线批）：HUD 本体是独立 Control
## （combat/ui/team_ai_hud.tscn，随 F3 + team_ai_hud 开关显隐），无逐帧绘制
## 内容——注册进 DebugApi 仅为进 F3 开关族（debug_panel 复选框清单口径）。
static func draw_team_ai_hud(_control: Control, _ctx: Dictionary) -> void:
	pass
