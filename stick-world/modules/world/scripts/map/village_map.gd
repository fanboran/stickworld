class_name VillageMap
extends MapBase
## 村落地图实例 —— 单 Chunk 简化版（P0）。
##
## 详见 docs/技术/架构/场景与战斗架构.md §3.4 / §3.2 / §2.4.3。
## P0 阶段：硬编码单张完整地图，不做 Chunk 流式（留到阶段 0.8）。
## 公共 API（spawn_entity/get_entities/get_possessed_entity/元数据 getter/障碍收集）
## 继承自 MapBase（2026-08 去重）。
##
## 节点结构：
##   VillageMap (Node2D)
##   ├── PlacementGrid (PlacementGrid)        ← 占地网格
##   ├── TerrainLayer (Node2D)                 ← 地面纹理重复渲染
##   │   └── GroundPolygon                     ← 地面多边形（顶点从 ground_y 开始向下）
##   ├── GroundLine (Marker2D)                 ← 地面线标记（y = ground_y）
##   ├── DecorationLayer (Node2D)              ← 装饰物（含程序化资源点）
##   ├── BuildingHost (Node2D)                 ← 建筑容器（P0 空）
##   ├── TerrainBuildings (Node2D)             ← 地形建筑（只读，随场景打包，不可拆除）
##   ├── InitialBuildingsList (Node)           ← 初始建筑数据列表（def_id + cell_x + width）
##   ├── WalkBarrier (Node2D)                  ← 地图级通行障碍容器（悬崖/高楼边缘）
##   ├── BuildMaskLayer (Node2D)               ← 不可放建筑区域（大石头/山坡阶梯处）
##   ├── ForegroundLayer (Node2D)              ← 前景层（z_index=10，火柴人经过被遮挡）
##   ├── EntityHost (Node2D)                   ← 火柴人容器
##   ├── ChunkTriggers (Node2D)                ← 末端触发器（P0 空）
##   ├── BattleAnchor (Node2D)                 ← 战斗实例挂载点（P0 空）
##   ├── TerrainRenderer (Node, terrain_renderer.gd)   ← 草地纹理/城内遮罩/土路视觉
##   └── ResourceGen (Node, resource_gen.gd) ← 垂直网格/资源点生成

# WorldAPI 是全局 class_name，无需 preload

const _TerrainRendererScript: GDScript = preload("res://modules/world/scripts/map/terrain_renderer.gd")
const _ResourceGenScript: GDScript = preload("res://modules/world/scripts/map/resource_gen.gd")
const ScriptResourceNode := preload("res://modules/world/scripts/map/resource_node.gd")
## 林区梯度常量来源（新开局生成与存档恢复共用同一规则）
const _ResourceGen := preload("res://modules/world/scripts/map/resource_gen.gd")

# SQL 白名单：表名/列名为固定常量；运行时值（slot_id/map_id）一律经 ? 绑定
# （query_with_bindings），禁止字符串拼接进 SQL。
const _SQL_MAPS_DELETE := "DELETE FROM maps WHERE slot_id = ? AND map_id = ?"
const _SQL_MAPS_SELECT := "SELECT * FROM maps WHERE slot_id = ? AND map_id = ?"
const _SQL_NODES_DELETE := "DELETE FROM resource_nodes WHERE slot_id = ? AND map_id = ?"
const _SQL_NODES_SELECT := "SELECT * FROM resource_nodes WHERE slot_id = ? AND map_id = ?"

# ─────────────────────────────── 地图元数据（§3.4.1）────────────────────────────────
## 建筑下基准线偏移（地平线向下像素数）：所有房屋类建筑底部对齐到 ground_y + 此值。
## 不是按格子计算，而是固定像素偏移（当前 96px，后续可调整为 100/200 等）。
@export var building_baseline_offset: float = 96.0

# ─────────────────────────────── 地形类型（1D 地块带）────────────────────────────────
## 地形类型常量：每 cell 的地形，影响移动速度与视觉
const TERRAIN_GRASS: int = 0        # 草地（默认，非土路）
const TERRAIN_DIRT_ROAD: int = 1    # 土路（村庄内，全速移动）
const TERRAIN_FOREST: int = 2       # 林地（土路外资源区，移动 -20%）
## 非土路移动速度倍率（土路=1.0，草地/林地=0.8）
const OFF_ROAD_SPEED_MULT: float = 0.8
## 每 cell 的地形类型（Dictionary: cell_x -> terrain_type），未设置=GRASS
var _terrain_types: Dictionary = {}
## 土路多边形节点（运行时创建，叠在草地上显示土黄色，由 TerrainRenderer 跨脚本维护）
@warning_ignore("unused_private_class_variable")
var _dirt_road_poly: Polygon2D = null

# ─────────────────────────────── 动态地图模型（阶段 F §5.7.2）────────────────────────────────
## 城镇中心的世界坐标 X（运行时原点，加载时确定）
var town_center_world_x: float = 0.0
## 可移动范围外推格数（最外围建筑外推 128 格）
const WALKABLE_MARGIN: int = 128
## 扩展粒度（64 格向上取整）
const EXPAND_GRANULARITY: int = 64
## 动态边界（cell 坐标）
var map_left_cell: int = 0
var map_right_cell: int = 0
## 是否已初始化动态边界
var _dynamic_bounds_initialized: bool = false

# ─────────────────────────────── 子节点引用 ────────────────────────────────
@onready var placement_grid: Node = get_node_or_null(WorldAPI.PATH_MAP_PLACEMENT_GRID)
@onready var terrain_layer: Node2D = get_node_or_null(WorldAPI.PATH_MAP_TERRAIN_LAYER)
@onready var decoration_layer: Node2D = get_node_or_null(WorldAPI.PATH_MAP_DECORATION_LAYER)
@onready var initial_buildings_list: Node = get_node_or_null(WorldAPI.PATH_MAP_INITIAL_BUILDINGS_LIST)
@onready var build_mask_layer: Node2D = get_node_or_null(WorldAPI.PATH_MAP_BUILD_MASK_LAYER)
@onready var foreground_layer: Node2D = get_node_or_null(WorldAPI.PATH_MAP_FOREGROUND_LAYER)
@onready var chunk_triggers: Node2D = get_node_or_null(WorldAPI.PATH_MAP_CHUNK_TRIGGERS)
@onready var battle_anchor: Node2D = get_node_or_null(WorldAPI.PATH_MAP_BATTLE_ANCHOR)
@onready var ground_line: Marker2D = get_node_or_null(WorldAPI.PATH_MAP_GROUND_LINE)

# ─────────────────────────────── 子组件引用 ────────────────────────────────
## 地形渲染系统（草地纹理/城内遮罩/土路视觉，_ready 装配）
var _terrain: Node = null
## 资源点生成器（垂直网格/资源点生成，_ready 装配）
var _resource_gen: Node = null

# ─────────────────────────────── 元数据 ────────────────────────────────
## 村落配置 ID（对应 VillageDefinition.tres，P0 留空）
var village_id: String = ""


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	super()
	_mount_components()
	_validate_children()
	_sync_ground_line()
	_terrain.apply_grass_texture()
	_sync_build_mask()
	_register_terrain_buildings()
	_init_dynamic_bounds()
	_mount_sky_decor()


## 天空装饰层（Terraria 原版贴图多层视差背景，按地形选组；贴图提取见 tools/ai/extract_terraria_sky.py）
func _mount_sky_decor() -> void:
	var sky := SkyDecor.new()
	sky.name = "SkyDecor"
	sky.horizon_y = ground_y
	sky.map_left = map_left
	sky.map_right = map_right
	sky.biome = sky_biome
	add_child(sky)
	# 环境浮尘（空气感；相机视野内 60 粒微光）
	var motes := AmbientMotes.new()
	motes.name = "AmbientMotes"
	add_child(motes)
	# 夜间萤火虫（星月在天、萤火在野——昼夜视觉语言的地面层）
	var flies := Fireflies.new()
	flies.name = "Fireflies"
	add_child(flies)
	# 正下方水（K2C 布局：水面在可行走区域正下方横贯全图——单位站堤岸、
	# 水在脚下；镜像倒影映天景，水线滚动白沫）。战场（enable_water=false）
	# 不挂——ground_y=432 时水带会横在屏幕中央
	if enable_water:
		var water := Pond.new()
		water.name = "WaterBelow"
		water.pond_width = (map_right - map_left) + 1000.0
		water.pond_depth = 170.0
		water.position = Vector2(map_left - 500.0, ground_y + 120.0)
		add_child(water)
	# 天气（Terraria 式降雨状态机：斜线雨 + 雨声循环 + 云层加浓；开局 90s 保护）
	var weather := Weather.new()
	weather.name = "Weather"
	add_child(weather)


## 实例化并挂载子组件（TerrainRenderer / ResourceGen）。
func _mount_components() -> void:
	_terrain = Node.new()
	_terrain.set_script(_TerrainRendererScript)
	_terrain.name = "TerrainRenderer"
	add_child(_terrain)
	if _terrain.has_method("setup"):
		_terrain.setup(self)

	_resource_gen = Node.new()
	_resource_gen.set_script(_ResourceGenScript)
	_resource_gen.name = "ResourceGen"
	add_child(_resource_gen)
	if _resource_gen.has_method("setup"):
		_resource_gen.setup(self)


func _validate_children() -> void:
	var required := {
		WorldAPI.PATH_MAP_PLACEMENT_GRID: "PlacementGrid",
		WorldAPI.PATH_MAP_TERRAIN_LAYER: "TerrainLayer",
		WorldAPI.PATH_MAP_BUILDING_HOST: "BuildingHost",
		WorldAPI.PATH_MAP_ENTITY_HOST: "EntityHost",
		WorldAPI.PATH_MAP_TERRAIN_BUILDINGS: "TerrainBuildings",
		WorldAPI.PATH_MAP_INITIAL_BUILDINGS_LIST: "InitialBuildingsList",
		WorldAPI.PATH_MAP_WALK_BARRIER: "WalkBarrier",
		WorldAPI.PATH_MAP_BUILD_MASK_LAYER: "BuildMaskLayer",
		WorldAPI.PATH_MAP_FOREGROUND_LAYER: "ForegroundLayer",
	}
	for path: String in required.keys():
		if get_node_or_null(path) == null:
			push_error("[VillageMap] 缺少必需子节点: %s" % path)


func _sync_ground_line() -> void:
	# GroundLine 节点位置对齐 ground_y（可视化调试用）
	if ground_line != null:
		ground_line.position = Vector2(0, ground_y)


# ─────────────────────────────── BuildMask（§4.2）────────────────────────────────
# 设计时在 BuildMaskLayer 下放置 ColorRect（红色半透明），运行时读取其位置尺寸，
# 注册到 PlacementGrid.blockage_mask。

func _sync_build_mask() -> void:
	if build_mask_layer == null or placement_grid == null:
		return
	if not placement_grid.has_method("set_blocked_area"):
		return
	for child in build_mask_layer.get_children():
		if child is ColorRect:
			var rect: ColorRect = child as ColorRect
			# ColorRect 的 position 和 size 都是局部坐标（BuildMaskLayer 在地图原点）
			var pos: Vector2 = rect.position
			var size: Vector2 = rect.size
			# 世界坐标 X -> 条带坐标（1D，只关心宽度）
			var cell_start: int = placement_grid.world_to_cell(pos)
			var cell_end: int = placement_grid.world_to_cell(pos + size)
			var w: int = cell_end - cell_start
			if w > 0:
				placement_grid.set_blocked_area(cell_start, w)
			# 运行时隐藏 ColorRect（仅设计时可见）
			rect.visible = false


# ─────────────────────────────── 地形建筑注册 ────────────────────────────────
# 运行时扫描 TerrainBuildings 子节点，读取 PassageBarrier 宽度，
# 自动注册到 PlacementGrid，使地形建筑在调试方格中显示为绿色条带。

func _register_terrain_buildings() -> void:
	if terrain_buildings == null or placement_grid == null:
		return
	for building in terrain_buildings.get_children():
		if not building is Node2D:
			continue
		# 宽度：优先用 building.width 属性，无则从碰撞箱尺寸反推
		var width_cells := 1
		if "width" in building:
			width_cells = maxi(1, int(building.get("width")))
		# 从 PassageBarrier 读取碰撞箱左边缘（网格对齐）注册占地
		var pb: Node = building.get_node_or_null("PassageBarrier")
		if pb:
			for child in pb.get_children():
				if child is CollisionShape2D and child.shape is RectangleShape2D:
					var cs: CollisionShape2D = child as CollisionShape2D
					if width_cells <= 1:
						width_cells = maxi(1, int(round((cs.shape as RectangleShape2D).size.x / placement_grid.CELL_SIZE)))
					var col_left: float = building.position.x + cs.position.x - (cs.shape as RectangleShape2D).size.x / 2.0
					var cell_x: int = placement_grid.world_to_cell(Vector2(col_left, 0))
					placement_grid.occupy(cell_x, width_cells, building.name)
					break
		# 地形建筑默认设为 OPERATIONAL（不透明）
		if building.has_method("set_state"):
			building.set_state(Building.State.OPERATIONAL)


# ─────────────────────────────── 动态地图模型（阶段 F §5.7.2）────────────────────────────────

## 初始化动态边界：从 map_left/map_right 计算 cell 范围，扩展 PlacementGrid
func _init_dynamic_bounds() -> void:
	if _dynamic_bounds_initialized:
		return
	# 城镇中心 = 地图中间
	town_center_world_x = (map_left + map_right) * 0.5
	if placement_grid != null:
		map_left_cell = int(map_left / placement_grid.CELL_SIZE)
		map_right_cell = int(map_right / placement_grid.CELL_SIZE)
		# 扩展 PlacementGrid 覆盖整个地图范围
		placement_grid.expand_to(map_left_cell)
		placement_grid.expand_to(map_right_cell)
	else:
		map_left_cell = int(map_left / 32)
		map_right_cell = int(map_right / 32)
	_dynamic_bounds_initialized = true


## 扩展地图以包含指定 cell_x（建筑放置时由 ConstructionManager 触发）。
## 以 64 格为单位向上取整，可移动范围 = 最外围建筑 + 128 格。
func expand_map(cell_x: int, width: int = 1) -> void:
	_init_dynamic_bounds()
	# 计算需要的可移动范围（建筑外缘 + WALKABLE_MARGIN）
	var needed_right: int = cell_x + width + WALKABLE_MARGIN
	var needed_left: int = cell_x - WALKABLE_MARGIN
	# 64 格向上取整
	needed_right = int(ceil(float(needed_right) / EXPAND_GRANULARITY)) * EXPAND_GRANULARITY
	needed_left = int(floor(float(needed_left) / EXPAND_GRANULARITY)) * EXPAND_GRANULARITY
	var changed: bool = false
	if needed_right > map_right_cell:
		map_right_cell = needed_right
		changed = true
	if needed_left < map_left_cell:
		map_left_cell = needed_left
		changed = true
	if not changed:
		return
	# 更新世界坐标边界
	if placement_grid != null:
		map_left = map_left_cell * placement_grid.CELL_SIZE
		map_right = map_right_cell * placement_grid.CELL_SIZE
		placement_grid.expand_to(map_left_cell)
		placement_grid.expand_to(map_right_cell)
	else:
		map_left = map_left_cell * 32.0
		map_right = map_right_cell * 32.0
	# 更新 GroundPolygon 顶点
	_update_ground_polygon()
	# 更新所有已存在实体的边界约束（修复空气墙：expand_map 后实体仍用旧的 map_left/map_right）
	if entity_host != null:
		for entity in entity_host.get_children():
			if entity.has_method("set_ground_constraints"):
				entity.set_ground_constraints(ground_y, ground_bottom, map_left, map_right)
	print_verbose("[VillageMap] 地图扩展: left_cell=%d right_cell=%d (world %.0f~%.0f)" % [map_left_cell, map_right_cell, map_left, map_right])


## 更新 GroundPolygon 顶点以匹配当前 map_left/map_right
func _update_ground_polygon() -> void:
	if terrain_layer == null:
		return
	var gp: Polygon2D = terrain_layer.get_node_or_null("GroundPolygon")
	if gp == null:
		return
	var p := PackedVector2Array()
	p.append(Vector2(map_left, ground_y))
	p.append(Vector2(map_right, ground_y))
	p.append(Vector2(map_right, ground_bottom))
	p.append(Vector2(map_left, ground_bottom))
	gp.polygon = p
	# 重置 Polygon2D 的 position，避免设计时偏移导致地面与世界坐标错位
	gp.position = Vector2.ZERO


## 获取可移动范围（世界坐标 X）
func get_walkable_bounds() -> Vector2:
	return Vector2(map_left, map_right)


# ─────────────────────────────── 地形类型（1D 地块带）────────────────────────────────

## 标记 cell 范围 [start_cell, end_cell) 为土路，并刷新土路视觉。
func set_dirt_road_range(start_cell: int, end_cell: int) -> void:
	for cx in range(start_cell, end_cell):
		_terrain_types[cx] = TERRAIN_DIRT_ROAD
	# 确保地图边界覆盖土路范围（可能需要向负坐标扩展地面多边形）
	var road_left_x: float = float(start_cell) * 32.0
	var road_right_x: float = float(end_cell) * 32.0
	var bounds_changed: bool = false
	if road_left_x < map_left:
		map_left = road_left_x
		map_left_cell = start_cell
		if placement_grid != null:
			placement_grid.expand_to(start_cell)
		bounds_changed = true
	if road_right_x > map_right:
		map_right = road_right_x
		map_right_cell = end_cell
		if placement_grid != null:
			placement_grid.expand_to(end_cell)
		bounds_changed = true
	if bounds_changed:
		_update_ground_polygon()
		# 更新所有已存在实体的边界约束
		if entity_host != null:
			for entity in entity_host.get_children():
				if entity.has_method("set_ground_constraints"):
					entity.set_ground_constraints(ground_y, ground_bottom, map_left, map_right)
	_terrain.update_dirt_road_visual()
	# 同步 grass shader 的 city_bounds，让土路范围显示土黄色（覆盖草地）
	_terrain.set_city_bounds(road_left_x, road_right_x)


## 获取 cell 的地形类型（未设置默认 GRASS）。
func get_terrain_type_at_cell(cell_x: int) -> int:
	return _terrain_types.get(cell_x, TERRAIN_GRASS)


## 获取世界坐标 X 对应的地形类型。
func get_terrain_type_at_x(world_x: float) -> int:
	return get_terrain_type_at_cell(floori(world_x / 32.0))


## 获取世界坐标 X 处的移动速度倍率（土路=1.0，非土路=0.8）。
func get_move_speed_mult_at_x(world_x: float) -> float:
	if get_terrain_type_at_x(world_x) == TERRAIN_DIRT_ROAD:
		return 1.0
	return OFF_ROAD_SPEED_MULT


# ─────────────────────────────── 垂直地形网格 + 资源点生成（转发到 ResourceGen）────────────────────────────────

## 获取地面垂直行数（ground_y ~ ground_bottom 之间按 32px 分行）
func get_terrain_row_count() -> int:
	return _resource_gen.get_terrain_row_count()


## 在指定 cell_x 的地面上生成随机 Y 位置（垂直网格内随机行）
func random_resource_y(cell_x: int) -> float:
	return _resource_gen.random_resource_y(cell_x)


## 在指定 cell 范围内程序化生成自然资源点。
## start_cell / end_cell: cell_x 范围
## density: 每格资源点概率（0.0~1.0）
## 返回生成的 ResourceNode 数组
func generate_resource_nodes(start_cell: int, end_cell: int, density: float) -> Array:
	return _resource_gen.generate_resource_nodes(start_cell, end_cell, density)


func set_city_bounds(left_x: float, right_x: float) -> void:
	_terrain.set_city_bounds(left_x, right_x)


## 阶段 F：根据城墙建筑列表自动计算城内范围并更新地形遮罩。
## city_walls: Array of {cell_x, width}，取最左和最右城墙作为城内边界。
func update_terrain_mask_from_walls(city_walls: Array) -> void:
	_terrain.update_terrain_mask_from_walls(city_walls)


## 获取城内左边界（从 Shader 参数读，存档用）
func _get_city_left_x() -> float:
	return _terrain.get_city_left_x()


## 获取城内右边界
func _get_city_right_x() -> float:
	return _terrain.get_city_right_x()


func get_minimap_buildings() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	_collect_minimap_buildings(building_host, false, result)
	_collect_minimap_buildings(terrain_buildings, true, result)
	return result


func _collect_minimap_buildings(host: Node, is_terrain: bool, result: Array[Dictionary]) -> void:
	if host == null:
		return
	for building in host.get_children():
		if not building is Node2D:
			continue
		result.append({
			"x": (building as Node2D).global_position.x,
			"width": _get_building_width(building),
			"terrain": is_terrain,
		})


## 建筑宽度：优先取 PassageBarrier 碰撞箱宽度，缺省 32px
func _get_building_width(building: Node) -> float:
	var pb: Node = building.get_node_or_null("PassageBarrier")
	if pb != null:
		for child in pb.get_children():
			if child is CollisionShape2D and (child as CollisionShape2D).shape is RectangleShape2D:
				return ((child as CollisionShape2D).shape as RectangleShape2D).size.x
	return 32.0


func save_to_db(db, slot_id: int, p_map_id: String) -> void:
	if not db.query_with_bindings(_SQL_MAPS_DELETE, [slot_id, p_map_id]):
		push_error("[VillageMap] maps 旧边界清理失败 slot=%d map=%s: %s" % [slot_id, p_map_id, str(db.error_message)])
	if not db.insert_row("maps", {
		"slot_id": slot_id, "map_id": p_map_id,
		"town_center_world_x": town_center_world_x,
		"map_left_cell": map_left_cell, "map_right_cell": map_right_cell,
		"city_left_x": _get_city_left_x(), "city_right_x": _get_city_right_x(),
		"ground_y": ground_y, "ground_bottom": ground_bottom,
	}):
		push_error("[VillageMap] 地图边界写入失败 slot=%d map=%s: %s" % [slot_id, p_map_id, str(db.error_message)])


## 取地图上全部资源点（供建造清场等查询，替代全局 group 扫描）
func get_resource_nodes() -> Array:
	var result: Array = []
	if decoration_layer == null:
		return result
	for node in decoration_layer.get_children():
		if node is ScriptResourceNode:
			result.append(node)
	return result


## 保存资源点到 DB
func save_resource_nodes_to_db(db, slot_id: int, p_map_id: String) -> void:
	if not db.query_with_bindings(_SQL_NODES_DELETE, [slot_id, p_map_id]):
		push_error("[VillageMap] resource_nodes 旧数据清理失败 slot=%d map=%s: %s" % [slot_id, p_map_id, str(db.error_message)])
	if decoration_layer == null:
		return
	var idx: int = 0
	for node in decoration_layer.get_children():
		if node is ScriptResourceNode and not node.is_depleted():
			if not db.insert_row("resource_nodes", {
				"slot_id": slot_id, "map_id": p_map_id,
				"node_id": "rn_%04d" % idx,
				"pos_x": node.global_position.x, "pos_y": node.global_position.y,
				"resource_type": node.resource_type, "amount": node.amount,
			}):
				push_error("[VillageMap] 资源点写入失败 slot=%d map=%s id=rn_%04d: %s" % [slot_id, p_map_id, idx, str(db.error_message)])
			idx += 1


## 从 DB 恢复地图边界
func load_from_db(db, slot_id: int, p_map_id: String) -> void:
	var rows: Array = []
	if db.query_with_bindings(_SQL_MAPS_SELECT, [slot_id, p_map_id]):
		rows = db.query_result
	if rows.is_empty():
		_init_dynamic_bounds()
		return
	var row: Dictionary = rows[0]
	town_center_world_x = float(row["town_center_world_x"])
	map_left_cell = int(row["map_left_cell"])
	map_right_cell = int(row["map_right_cell"])
	ground_y = float(row["ground_y"])
	ground_bottom = float(row["ground_bottom"])
	if placement_grid != null:
		map_left = map_left_cell * placement_grid.CELL_SIZE
		map_right = map_right_cell * placement_grid.CELL_SIZE
		placement_grid.expand_to(map_left_cell)
		placement_grid.expand_to(map_right_cell)
	_update_ground_polygon()
	var clx: float = float(row["city_left_x"])
	var crx: float = float(row["city_right_x"])
	if clx > -99990.0:
		_terrain.set_city_bounds(clx, crx)
		# 从 city_bounds 恢复土路地形类型（cell 范围）
		var start_cell: int = floori(clx / 32.0)
		var end_cell: int = floori(crx / 32.0)
		for cx in range(start_cell, end_cell):
			_terrain_types[cx] = TERRAIN_DIRT_ROAD
		_terrain.update_dirt_road_visual()
	_dynamic_bounds_initialized = true


## 从 DB 恢复资源点
func load_resource_nodes_from_db(db, slot_id: int, p_map_id: String) -> void:
	if decoration_layer == null:
		return
	# 清除现有资源点
	for node in decoration_layer.get_children():
		if node is ScriptResourceNode:
			node.queue_free()
	var rows: Array = []
	if db.query_with_bindings(_SQL_NODES_SELECT, [slot_id, p_map_id]):
		rows = db.query_result
	for row in rows:
		# 林区梯度（与 resource_gen 新开局同规则）：旧存档里贴着硬化区的资源
		# 是旧密度规则撒的，恢复时丢弃不摆（净空带内无树无石无矿）
		if _violates_forest_clear(float(row["pos_x"])):
			continue
		var node: Node2D = ScriptResourceNode.new()
		node.resource_type = int(row["resource_type"])
		node.amount = int(row["amount"])
		node.position = Vector2(float(row["pos_x"]), float(row["pos_y"]))
		decoration_layer.add_child(node)


## 世界 x 坐标是否落在硬化区一屏净空带内（true = 该处不该有树）
func _violates_forest_clear(world_x: float) -> bool:
	var lo := 1 << 30
	var hi := -(1 << 30)
	for cx: int in _terrain_types.keys():
		if _terrain_types[cx] == TERRAIN_DIRT_ROAD:
			lo = mini(lo, cx)
			hi = maxi(hi, cx)
	if lo > hi:
		return false
	var cell := floori(world_x / 32.0)
	var dist: int = maxi(maxi(lo - cell, cell - hi), 0)
	return dist <= _ResourceGen.FOREST_CLEAR_CELLS
