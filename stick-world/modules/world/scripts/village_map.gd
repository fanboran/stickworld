class_name VillageMap
extends Node2D
## 村落地图实例 —— 单 Chunk 简化版（P0）。
##
## 详见 docs/技术/架构/场景与战斗架构.md §3.4 / §3.2 / §2.4.3。
## P0 阶段：硬编码单张完整地图，不做 Chunk 流式（留到阶段 0.8）。
##
## 节点结构：
##   VillageMap (Node2D)
##   ├── PlacementGrid (PlacementGrid)        ← 占地网格
##   ├── TerrainLayer (Node2D)                 ← 地面纹理重复渲染
##   │   └── GroundPolygon                     ← 地面多边形（顶点从 ground_y 开始向下）
##   ├── GroundLine (Marker2D)                 ← 地面线标记（y = ground_y）
##   ├── DecorationLayer (Node2D)              ← 装饰物（P0 空）
##   ├── BuildingHost (Node2D)                 ← 建筑容器（P0 空）
##   ├── TerrainBuildings (Node2D)             ← 地形建筑（只读，随场景打包，不可拆除）
##   ├── InitialBuildingsList (Node)           ← 初始建筑数据列表（def_id + cell_x + width）
##   ├── WalkBarrier (Node2D)                  ← 地图级通行障碍容器（悬崖/高楼边缘）
##   ├── BuildMaskLayer (Node2D)               ← 不可放建筑区域（大石头/山坡阶梯处）
##   ├── ForegroundLayer (Node2D)              ← 前景层（z_index=10，火柴人经过被遮挡）
##   ├── EntityHost (Node2D)                   ← 火柴人容器
##   ├── ChunkTriggers (Node2D)                ← 末端触发器（P0 空）
##   └── BattleAnchor (Node2D)                 ← 战斗实例挂载点（P0 空）

# WorldAPI 是全局 class_name，无需 preload


# ─────────────────────────────── 地图元数据（§3.4.1）────────────────────────────────
## 地面线 Y（世界坐标），火柴人可走区域顶部
@export var ground_y: float = 810.0
## 地面占屏幕高度比例（Inspector 可改，默认 0.25 = 1/4）
@export var ground_ratio: float = 0.25
## 地图左边界 X（相机/火柴人 X 下限）
@export var map_left: float = 0.0
## 地图右边界 X（相机/火柴人 X 上限）—— 卷轴式水平展开，P0 设为 8192（足够测试左右移动）
@export var map_right: float = 8192.0
## 地面底部 Y（火柴人可走区域底部，= ground_y + DESIGN_HEIGHT * ground_ratio = 810 + 1080*0.25 = 1080）
## 注意：此值应匹配屏幕可见地面范围，避免地面矩形超出屏幕导致火柴人显示偏下
@export var ground_bottom: float = 1080.0
## 建筑下基准线偏移（地平线向下像素数）：所有房屋类建筑底部对齐到 ground_y + 此值。
## 不是按格子计算，而是固定像素偏移（当前 96px，后续可调整为 100/200 等）。
@export var building_baseline_offset: float = 96.0
## 草地纹理平铺尺寸（世界坐标 px，每 GRASS_TILE_SIZE 像素重复一次纹理）
const GRASS_TILE_SIZE: float = 512.0

# ─────────────────────────────── 地形类型（1D 地块带）────────────────────────────────
## 地形类型常量：每 cell 的地形，影响移动速度与视觉
const TERRAIN_GRASS: int = 0        # 草地（默认，非土路）
const TERRAIN_DIRT_ROAD: int = 1    # 土路（村庄内，全速移动）
const TERRAIN_FOREST: int = 2       # 林地（土路外资源区，移动 -20%）
## 非土路移动速度倍率（土路=1.0，草地/林地=0.8）
const OFF_ROAD_SPEED_MULT: float = 0.8
## 每 cell 的地形类型（Dictionary: cell_x -> terrain_type），未设置=GRASS
var _terrain_types: Dictionary = {}
## 土路多边形节点（运行时创建，叠在草地上显示土黄色）
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
@onready var building_host: Node2D = get_node_or_null(WorldAPI.PATH_MAP_BUILDING_HOST)
@onready var terrain_buildings: Node2D = get_node_or_null(WorldAPI.PATH_MAP_TERRAIN_BUILDINGS)
@onready var initial_buildings_list: Node = get_node_or_null(WorldAPI.PATH_MAP_INITIAL_BUILDINGS_LIST)
@onready var walk_barrier: Node2D = get_node_or_null(WorldAPI.PATH_MAP_WALK_BARRIER)
@onready var build_mask_layer: Node2D = get_node_or_null(WorldAPI.PATH_MAP_BUILD_MASK_LAYER)
@onready var foreground_layer: Node2D = get_node_or_null(WorldAPI.PATH_MAP_FOREGROUND_LAYER)
@onready var entity_host: Node2D = get_node_or_null(WorldAPI.PATH_MAP_ENTITY_HOST)
@onready var chunk_triggers: Node2D = get_node_or_null(WorldAPI.PATH_MAP_CHUNK_TRIGGERS)
@onready var battle_anchor: Node2D = get_node_or_null(WorldAPI.PATH_MAP_BATTLE_ANCHOR)
@onready var ground_line: Marker2D = get_node_or_null(WorldAPI.PATH_MAP_GROUND_LINE)

# ─────────────────────────────── 元数据 ────────────────────────────────
## 地图 ID（由 SceneLoader 注册时分配）
var map_id: String = ""
## 村落配置 ID（对应 VillageDefinition.tres，P0 留空）
var village_id: String = ""


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	_validate_children()
	_sync_ground_line()
	_apply_grass_texture()
	_sync_build_mask()
	_register_terrain_buildings()
	_init_dynamic_bounds()


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
	print("[VillageMap] 地图扩展: left_cell=%d right_cell=%d (world %.0f~%.0f)" % [map_left_cell, map_right_cell, map_left, map_right])


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


# ─────────────────────────────── 垂直地形网格 + 资源点生成（阶段 F §5.7.4.5）────────────────────────────────
## 垂直格子大小（与水平 CELL_SIZE 一致，32px）
const TERRAIN_CELL_SIZE_Y: float = 32.0
const ScriptResourceNode := preload("res://modules/world/scripts/resource_node.gd")

## 获取地面垂直行数（ground_y ~ ground_bottom 之间按 32px 分行）
func get_terrain_row_count() -> int:
	return maxi(1, int((ground_bottom - ground_y) / TERRAIN_CELL_SIZE_Y))


## 在指定 cell_x 的地面上生成随机 Y 位置（垂直网格内随机行）
func random_resource_y(cell_x: int) -> float:
	var rows: int = get_terrain_row_count()
	var row: int = randi() % rows
	return ground_y + row * TERRAIN_CELL_SIZE_Y + TERRAIN_CELL_SIZE_Y * 0.5


## 在指定 cell 范围内程序化生成自然资源点。
## start_cell / end_cell: cell_x 范围
## density: 每格资源点概率（0.0~1.0）
## 返回生成的 ResourceNode 数组
func generate_resource_nodes(start_cell: int, end_cell: int, density: float) -> Array:
	if decoration_layer == null:
		return []
	var nodes: Array = []
	# 保证 start <= end，避免调用端传反范围
	var a: int = mini(start_cell, end_cell)
	var b: int = maxi(start_cell, end_cell)
	for cx in range(a, b):
		# 硬化路面/土路上不可能长资源
		if get_terrain_type_at_cell(cx) == TERRAIN_DIRT_ROAD:
			continue
		if randf() > density:
			continue
		# 资源类型权重：WOOD 55% / STONE 35% / METAL 10%（树林密、石头次之、铁矿稀有）
		var r: float = randf()
		var rtype: int
		if r < 0.55:
			rtype = 0  # WOOD
		elif r < 0.9:
			rtype = 1  # STONE
		else:
			rtype = 2  # METAL
		var node: Node2D = ScriptResourceNode.new()
		node.resource_type = rtype
		node.amount = 50 + randi() % 100
		var px: float = cx * 32.0 + 16.0
		var py: float = random_resource_y(cx)
		node.position = Vector2(px, py)
		decoration_layer.add_child(node)
		nodes.append(node)
	print("[VillageMap] 生成 %d 个资源点 (cell %d~%d, density=%.2f)" % [nodes.size(), start_cell, end_cell, density])
	return nodes


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
	_update_dirt_road_visual()
	# 同步 grass shader 的 city_bounds，让土路范围显示土黄色（覆盖草地）
	set_city_bounds(road_left_x, road_right_x)
	print("[VillageMap] set_dirt_road_range: cell %d~%d, map_left=%.0f, map_right=%.0f, dirt_poly=%s" % [start_cell, end_cell, map_left, map_right, _dirt_road_poly != null])


## 获取 cell 的地形类型（未设置默认 GRASS）。
func get_terrain_type_at_cell(cell_x: int) -> int:
	return _terrain_types.get(cell_x, TERRAIN_GRASS)


## 获取世界坐标 X 对应的地形类型。
func get_terrain_type_at_x(world_x: float) -> int:
	return get_terrain_type_at_cell(int(world_x / 32.0))


## 获取世界坐标 X 处的移动速度倍率（土路=1.0，非土路=0.8）。
func get_move_speed_mult_at_x(world_x: float) -> float:
	if get_terrain_type_at_x(world_x) == TERRAIN_DIRT_ROAD:
		return 1.0
	return OFF_ROAD_SPEED_MULT


## 更新土路视觉：用土黄色 Polygon2D 覆盖土路 cell 范围的地面区域。
func _update_dirt_road_visual() -> void:
	if terrain_layer == null:
		return
	var min_cell: int = -1
	var max_cell: int = -1
	for cx: int in _terrain_types.keys():
		if _terrain_types[cx] == TERRAIN_DIRT_ROAD:
			if min_cell < 0 or cx < min_cell:
				min_cell = cx
			if cx > max_cell:
				max_cell = cx
	if min_cell < 0:
		return  # 无土路
	if _dirt_road_poly == null:
		_dirt_road_poly = Polygon2D.new()
		_dirt_road_poly.color = Color(0.62, 0.50, 0.32, 1.0)  # 土黄色
		# z=1（decoration 层）：低于建筑（BuildingHost z=2），否则路面盖住建筑画面
		_dirt_road_poly.z_index = 1
		add_child(_dirt_road_poly)
	var x0: float = float(min_cell) * 32.0
	var x1: float = float(max_cell + 1) * 32.0
	_dirt_road_poly.polygon = PackedVector2Array([Vector2(x0, ground_y), Vector2(x1, ground_y), Vector2(x1, ground_bottom), Vector2(x0, ground_bottom)])


# ─────────────────────────────── 通行障碍查询（§7.1.2）────────────────────────────────

## 获取所有 WalkBarrier 静态体列表（地图级通行障碍，供 DebugOverlay 绘制）
func get_walk_barriers() -> Array:
	if walk_barrier == null:
		return []
	var barriers: Array = []
	for child in walk_barrier.get_children():
		if child is StaticBody2D:
			barriers.append(child)
	return barriers


## 获取所有建筑级 PassageBarrier StaticBody2D 列表（供 DebugOverlay 绘制）
## 同时扫描 building_host（动态建筑）和 terrain_buildings（地形建筑）
func get_passage_barriers() -> Array:
	var barriers: Array = []
	for host in [building_host, terrain_buildings]:
		if host == null:
			continue
		for building in host.get_children():
			var pb: Node = building.get_node_or_null("PassageBarrier") if building.has_method("get_node_or_null") else null
			if pb != null and pb is StaticBody2D:
				barriers.append(pb)
	return barriers


## 获取地面底部 Y
func get_ground_bottom() -> float:
	return ground_bottom


# ─────────────────────────────── 草地纹理 ────────────────────────────────
# 使用 assets/environment/grassland.jpeg 作为平铺草地纹理。
# 用 ShaderMaterial 实现 Stochastic Tiling（随机偏移+随机翻转，打破规则网格感）。

const _GRASS_SHADER_CODE: String = """
shader_type canvas_item;

uniform sampler2D tex : repeat_enable, filter_linear_mipmap;
uniform vec2 tile_size = vec2(512.0, 512.0);
uniform float jitter = 0.35;        // 随机偏移强度 (0=无偏移, 0.5=最大偏移)
uniform float color_jitter = 0.15;   // 明暗变化强度
uniform float noise_scale = 0.0006;  // 噪波频率（越小=色块越大）
uniform bool random_flip = true;     // 随机翻转
uniform float seam_blend = 0.2;      // 接缝过渡宽度（占格子比例）

// 阶段 F §5.7.3：城内/城外地形混合
uniform vec4 city_color = vec4(0.45, 0.38, 0.28, 1.0);  // 城内泥土色
uniform float city_left_x = -99999.0;   // 城内左边界（世界坐标）
uniform float city_right_x = -99999.0;  // 城内右边界（世界坐标）
uniform float city_fade = 320.0;        // 过渡带宽度（10 格 = 320px）

// 传递顶点局部坐标（= 世界坐标）到 fragment，避免 fragment 中 VERTEX 是视空间导致贴图不跟随世界
varying vec2 world_pos;

// 2D hash -> [0,1]
float hash21(vec2 p) {
	p = fract(p * vec2(443.897, 441.423));
	p += dot(p, p.yx + 19.19);
	return fract((p.x + p.y) * p.x);
}

// 2D value noise（平滑连续噪波，覆盖整个地面）
float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f); // smoothstep 插值
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// 分形布朗运动（多频叠加，更自然）
float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 3; i++) {
		v += a * value_noise(p);
		p *= 2.0;
		a *= 0.5;
	}
	return v;
}

// 格子内到最近边缘的距离 [0, 0.5]
float edge_dist(vec2 local_uv) {
	return min(min(local_uv.x, 1.0 - local_uv.x), min(local_uv.y, 1.0 - local_uv.y));
}

// 计算单个格子的随机采样 UV
vec2 stochastic_uv(vec2 cell, vec2 local_uv, float seed) {
	vec2 offset = vec2(hash21(cell + seed), hash21(cell + seed + 1.0)) * jitter;
	vec2 uv = local_uv;
	if (random_flip) {
		if (hash21(cell + seed + 2.0) > 0.5) uv.x = 1.0 - uv.x;
		if (hash21(cell + seed + 3.0) > 0.5) uv.y = 1.0 - uv.y;
	}
	return fract(uv + offset);
}

void vertex() {
	// MODEL_MATRIX 把局部顶点变换到世界坐标，兼容 Polygon2D 的 position 偏移
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	vec2 pos = world_pos / tile_size;

	// Layer 1: 原始网格
	vec2 cell1 = floor(pos);
	vec2 luv1 = fract(pos);
	vec4 c1 = texture(tex, stochastic_uv(cell1, luv1, 0.0));

	// Layer 2: 网格偏移半格，接缝与 Layer 1 错开
	vec2 pos2 = pos + 0.5;
	vec2 cell2 = floor(pos2);
	vec2 luv2 = fract(pos2);
	vec4 c2 = texture(tex, stochastic_uv(cell2, luv2, 10.0));

	// 按到边缘距离加权混合：一层在接缝处时另一层在格子中心
	float w1 = smoothstep(0.0, seam_blend, edge_dist(luv1));
	float w2 = smoothstep(0.0, seam_blend, edge_dist(luv2));
	COLOR = (c1 * w1 + c2 * w2) / (w1 + w2);

	// 连续噪波控制整体明暗（平滑过渡，不按格子）
	float n = fbm(world_pos * noise_scale);
	float tint = 1.0 + (n - 0.5) * 2.0 * color_jitter;
	COLOR.rgb *= tint;

	// 阶段 F §5.7.3：城内/城外地形混合
	float city_factor = smoothstep(city_left_x - city_fade, city_left_x + city_fade, world_pos.x)
		* (1.0 - smoothstep(city_right_x - city_fade, city_right_x + city_fade, world_pos.x));
	COLOR = mix(COLOR, city_color, city_factor * 1.0);
}
"""

func _apply_grass_texture() -> void:
	if terrain_layer == null:
		push_warning("[VillageMap] terrain_layer 为空，跳过草地材质")
		return
	var gp: Polygon2D = terrain_layer.get_node_or_null("GroundPolygon")
	if gp == null:
		push_warning("[VillageMap] GroundPolygon 不存在，跳过草地材质")
		return
	# 自动查找 assets/environment/ 下以 grassland 开头的图片文件
	var img_path := _find_grass_texture()
	if img_path.is_empty():
		push_warning("[VillageMap] 未找到草地纹理文件")
		return
	# 按文件头检测真实格式加载（避免扩展名与实际格式不匹配）
	var img := _load_image_auto(img_path)
	if img == null:
		push_warning("[VillageMap] 草地图片加载失败: " + img_path)
		return
	var tex := ImageTexture.create_from_image(img)
	gp.texture = tex
	# 重置设计时可能存在的 position 偏移，确保 shader 世界坐标与地面边界一致
	gp.position = Vector2.ZERO
	# 用 ShaderMaterial 的 repeat_enable 强制平铺，shader 内用世界坐标计算 UV
	var mat := ShaderMaterial.new()
	mat.shader = Shader.new()
	mat.shader.code = _GRASS_SHADER_CODE
	mat.set_shader_parameter("tex", tex)
	mat.set_shader_parameter("tile_size", Vector2(GRASS_TILE_SIZE, GRASS_TILE_SIZE))
	gp.material = mat
	# 土路颜色（city_color）：土黄色，覆盖草地显示硬化路面
	mat.set_shader_parameter("city_color", Color(0.62, 0.50, 0.32, 1.0))
	# 土路硬边界（1px 过渡避免 smoothstep 退化）
	mat.set_shader_parameter("city_fade", 1.0)
	# 纹理颜色不需要 color 调色，设为白色避免叠加
	gp.color = Color.WHITE


## 阶段 F §5.7.3：设置城内范围（世界坐标），更新地形遮罩 Shader 参数。
## 城墙建造时调用此方法标记城内区域。
func set_city_bounds(left_x: float, right_x: float) -> void:
	if terrain_layer == null:
		return
	var gp: Polygon2D = terrain_layer.get_node_or_null("GroundPolygon")
	if gp == null or gp.material == null:
		return
	gp.material.set_shader_parameter("city_left_x", left_x)
	gp.material.set_shader_parameter("city_right_x", right_x)


## 阶段 F：根据城墙建筑列表自动计算城内范围并更新地形遮罩。
## city_walls: Array of {cell_x, width}，取最左和最右城墙作为城内边界。
func update_terrain_mask_from_walls(city_walls: Array) -> void:
	if city_walls.is_empty():
		return
	var min_x: float = INF
	var max_x: float = -INF
	for wall in city_walls:
		if wall is Dictionary:
			var cx: int = wall.get("cell_x", 0)
			var w: int = wall.get("width", 1)
			var left_x: float = cx * 32.0
			var right_x: float = (cx + w) * 32.0
			min_x = min(min_x, left_x)
			max_x = max(max_x, right_x)
	if min_x != INF and max_x != -INF:
		set_city_bounds(min_x, max_x)


## 在 assets/environment/ 目录下查找 grassland 开头的图片文件，返回绝对路径
func _find_grass_texture() -> String:
	var dir_path := "res://assets/environment"
	var abs_dir := ProjectSettings.globalize_path(dir_path)
	var dir := DirAccess.open(abs_dir)
	if dir == null:
		return ""
	var exts := [".png", ".jpg", ".jpeg", ".webp", ".bmp", ".tga"]
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir():
			var lower := file_name.to_lower()
			if lower.begins_with("grassland"):
				for ext in exts:
					if lower.ends_with(ext):
						return abs_dir + "/" + file_name
		file_name = dir.get_next()
	dir.list_dir_end()
	return ""


## 按文件头检测真实图片格式并加载（不依赖文件扩展名）
func _load_image_auto(path: String) -> Image:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var buf := file.get_buffer(file.get_length())
	file.close()
	if buf.size() < 4:
		return null
	var img := Image.new()
	var err: int = ERR_FILE_UNRECOGNIZED
	# JPEG: FF D8 FF
	if buf[0] == 0xFF and buf[1] == 0xD8 and buf[2] == 0xFF:
		err = img.load_jpg_from_buffer(buf)
	# PNG: 89 50 4E 47
	elif buf[0] == 0x89 and buf[1] == 0x50 and buf[2] == 0x4E and buf[3] == 0x47:
		err = img.load_png_from_buffer(buf)
	# WebP: 52 49 46 46
	elif buf.size() >= 12 and buf[0] == 0x52 and buf[1] == 0x49 and buf[2] == 0x46 and buf[3] == 0x46:
		err = img.load_webp_from_buffer(buf)
	if err == OK:
		return img
	return null


# ─────────────────────────────── 公共 API（§3.4.2）────────────────────────────────

func get_ground_y() -> float:
	return ground_y


func get_ground_ratio() -> float:
	return ground_ratio


func get_camera_bounds() -> Vector2:
	return Vector2(map_left, map_right)


func get_entity_walk_bounds() -> Vector2:
	return Vector2(map_left, map_right)


## 生成实体到 EntityHost，并注入 ground_y / map_left / map_right / 地图引用
func spawn_entity(entity_scene: PackedScene, p_position: Vector2) -> Node2D:
	if entity_host == null or entity_scene == null:
		push_error("[VillageMap] 无法生成实体: entity_host 或 scene 为空")
		return null
	var instance: Node2D = entity_scene.instantiate() as Node2D
	if instance == null:
		push_error("[VillageMap] 实体场景实例化失败")
		return null
	entity_host.add_child(instance)
	instance.global_position = p_position
	# 修复：_ready 中 _last_valid_position 被初始化为 (0,0)，这里刷新为正确位置
	if instance.has_method("set_last_valid_position"):
		instance.set_last_valid_position(p_position)
	# 注入地面约束参数（详见 §7.1.1）
	if instance.has_method("set_ground_constraints"):
		instance.set_ground_constraints(ground_y, ground_bottom, map_left, map_right)
	# 注入地图引用（供通行障碍查询，详见 §7.1.2）
	if instance.has_method("set_map_reference"):
		instance.set_map_reference(self)
	return instance


## 获取所有 StickmanEntity
func get_entities() -> Array:
	if entity_host == null:
		return []
	return entity_host.get_children()


## 获取玩家附身的实体（如有）
func get_possessed_entity() -> Node2D:
	for e in get_entities():
		if e is CharacterBody2D and e.has_method("is_possessed") and e.is_possessed():
			return e
	return null


## 获取地图宽度（像素）
func get_map_width() -> float:
	return map_right - map_left


# ─────────────────────────────── SQLite 存档 ────────────────────────────────
# 详见 docs/技术/架构/SQLite存档迁移方案.md §5.3

## 保存地图边界到 DB
func save_to_db(db, slot_id: int, map_id: String) -> void:
	db.delete_rows("maps", "slot_id = %d AND map_id = '%s'" % [slot_id, map_id])
	db.insert_row("maps", {
		"slot_id": slot_id, "map_id": map_id,
		"town_center_world_x": town_center_world_x,
		"map_left_cell": map_left_cell, "map_right_cell": map_right_cell,
		"city_left_x": _get_city_left_x(), "city_right_x": _get_city_right_x(),
		"ground_y": ground_y, "ground_bottom": ground_bottom,
	})


## 保存资源点到 DB
func save_resource_nodes_to_db(db, slot_id: int, map_id: String) -> void:
	db.delete_rows("resource_nodes", "slot_id = %d AND map_id = '%s'" % [slot_id, map_id])
	if decoration_layer == null:
		return
	var idx: int = 0
	for node in decoration_layer.get_children():
		if node is ScriptResourceNode and not node.is_depleted():
			db.insert_row("resource_nodes", {
				"slot_id": slot_id, "map_id": map_id,
				"node_id": "rn_%04d" % idx,
				"pos_x": node.global_position.x, "pos_y": node.global_position.y,
				"resource_type": node.resource_type, "amount": node.amount,
			})
			idx += 1


## 从 DB 恢复地图边界
func load_from_db(db, slot_id: int, map_id: String) -> void:
	var rows: Array = db.select_rows("maps",
		"slot_id = %d AND map_id = '%s'" % [slot_id, map_id], ["*"])
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
		set_city_bounds(clx, crx)
		# 从 city_bounds 恢复土路地形类型（cell 范围）
		var start_cell: int = int(clx / 32.0)
		var end_cell: int = int(crx / 32.0)
		for cx in range(start_cell, end_cell):
			_terrain_types[cx] = TERRAIN_DIRT_ROAD
		_update_dirt_road_visual()
	_dynamic_bounds_initialized = true


## 从 DB 恢复资源点
func load_resource_nodes_from_db(db, slot_id: int, map_id: String) -> void:
	if decoration_layer == null:
		return
	# 清除现有资源点
	for node in decoration_layer.get_children():
		if node is ScriptResourceNode:
			node.queue_free()
	var rows: Array = db.select_rows("resource_nodes",
		"slot_id = %d AND map_id = '%s'" % [slot_id, map_id], ["*"])
	for row in rows:
		var node: Node2D = ScriptResourceNode.new()
		node.resource_type = int(row["resource_type"])
		node.amount = int(row["amount"])
		node.position = Vector2(float(row["pos_x"]), float(row["pos_y"]))
		decoration_layer.add_child(node)


## 获取城内左边界（从 Shader 参数读）
func _get_city_left_x() -> float:
	if terrain_layer == null:
		return -99999.0
	var gp: Polygon2D = terrain_layer.get_node_or_null("GroundPolygon")
	if gp == null or gp.material == null:
		return -99999.0
	var v = gp.material.get_shader_parameter("city_left_x")
	if v == null:
		return -99999.0
	return float(v)


## 获取城内右边界
func _get_city_right_x() -> float:
	if terrain_layer == null:
		return -99999.0
	var gp: Polygon2D = terrain_layer.get_node_or_null("GroundPolygon")
	if gp == null or gp.material == null:
		return -99999.0
	var v = gp.material.get_shader_parameter("city_right_x")
	if v == null:
		return -99999.0
	return float(v)
