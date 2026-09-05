class_name MapBase
extends Node2D
## 场景图地图公共基类 —— VillageMap / RoadMap 公共实现（2026-08 去重）。
##
## 两个地图脚本原先重复约 90 行公共 API（元数据 getter / spawn_entity /
## 实体查询 / 障碍收集），现统一上移到本基类。子类只保留各自特有逻辑：
##   - VillageMap：动态地图模型、地形遮罩、建筑系统、存档
##   - RoadMap：道路纹理、出口触发器
##
## 节点引用全部 get_node_or_null + WorldAPI.PATH_*（缺失节点返回 null，
## 对应 API 自然返回空——RoadMap 无 WalkBarrier/BuildingHost 即返回空数组）。

# WorldAPI 是全局 class_name，无需 preload

# ─────────────────────────────── 地图元数据（§3.4.1）────────────────────────────────
## 地面线 Y（世界坐标），火柴人可走区域顶部
@export var ground_y: float = 810.0
## 地面占屏幕高度比例（Inspector 可改，默认 0.25 = 1/4）
@export var ground_ratio: float = 0.25
## 地图左边界 X（相机/火柴人 X 下限）
@export var map_left: float = 0.0
## 地图右边界 X（相机/火柴人 X 上限）
@export var map_right: float = 8192.0
## 地面底部 Y（火柴人可走区域底部）
@export var ground_bottom: float = 1080.0
## 正下方水带开关（K2C 布局原型；Demo 阶段默认封印——战场 ground_y 偏高时
## 水带会横在屏幕中央，且未适配缩放，待地面构图定稿后重做，见待办事项）
@export var enable_water: bool = false
## 天空背景地形组（Terraria 各地形一套独立贴图）：
## "mountains"=纯远山（村落/战场/道路等开阔地）、"forest"=远山+森林树线
@export var sky_biome: String = "mountains"

# ─────────────────────────────── 子节点引用 ────────────────────────────────
@onready var entity_host: Node2D = get_node_or_null(WorldAPI.PATH_MAP_ENTITY_HOST)
@onready var walk_barrier: Node2D = get_node_or_null(WorldAPI.PATH_MAP_WALK_BARRIER)
@onready var building_host: Node2D = get_node_or_null(WorldAPI.PATH_MAP_BUILDING_HOST)
@onready var terrain_buildings: Node2D = get_node_or_null(WorldAPI.PATH_MAP_TERRAIN_BUILDINGS)

# ─────────────────────────────── 元数据 ────────────────────────────────
var map_id: String = ""


# ─────────────────────────────── 渲染层级 ────────────────────────────────

func _ready() -> void:
	# 场景层序唯一真相源：WorldZ 常量（场景文件不保存 z_index）
	WorldZ.apply(self)
	# 火柴人 y-sort：Y 越大（越靠下）渲染越靠顶层
	if entity_host != null:
		entity_host.y_sort_enabled = true
		# 实体进出树即失效缓存（spawn/死亡清理的当帧查询必须看到最新列表）
		entity_host.child_entered_tree.connect(_invalidate_entity_cache)
		entity_host.child_exiting_tree.connect(_invalidate_entity_cache)
	# 建筑 y-sort（排序原点 = 基线，见各摆放处 y_sort_origin 设置）
	if building_host != null:
		building_host.y_sort_enabled = true
	if terrain_buildings != null:
		terrain_buildings.y_sort_enabled = true


# ─────────────────────────────── 公共 API（§3.4.2）────────────────────────────────

func get_ground_y() -> float:
	return ground_y


func get_ground_ratio() -> float:
	return ground_ratio


func get_camera_bounds() -> Vector2:
	return Vector2(map_left, map_right)


func get_entity_walk_bounds() -> Vector2:
	return Vector2(map_left, map_right)


func get_ground_bottom() -> float:
	return ground_bottom


## 获取地图宽度（像素）
func get_map_width() -> float:
	return map_right - map_left


## 生成实体到 EntityHost，注入地面约束参数与地图引用。
## 兼容注入（has_method 防御）：set_ground_constraints / set_map_reference / set_last_valid_position
func spawn_entity(entity_scene: PackedScene, p_position: Vector2) -> Node2D:
	if entity_host == null or entity_scene == null:
		push_error("[MapBase] 无法生成实体: entity_host 或 scene 为空")
		return null
	var instance: Node2D = entity_scene.instantiate() as Node2D
	if instance == null:
		push_error("[MapBase] 实体场景实例化失败")
		return null
	entity_host.add_child(instance)
	instance.global_position = p_position
	# 刷新初始有效位置（实体 _ready 中默认 (0,0)，此处修正）
	if instance.has_method("set_last_valid_position"):
		instance.set_last_valid_position(p_position)
	# 注入地面约束参数
	if instance.has_method("set_ground_constraints"):
		instance.set_ground_constraints(ground_y, ground_bottom, map_left, map_right)
	# 注入地图引用（供通行障碍查询）
	if instance.has_method("set_map_reference"):
		instance.set_map_reference(self)
	return instance


## 获取所有 StickmanEntity。
## 性能（战斗优化）：每物理帧只重建一次缓存——此前每次调用都
## entity_host.get_children() 新分配数组，196 单位混战时每帧几十次调用
## 是显著的分配压力；树结构变化（spawn/queue_free）自动失效重建。
func get_entities() -> Array:
	if _entity_cache_frame != Engine.get_physics_frames():
		_rebuild_entity_cache()
	return _entity_cache


## 空间邻域查询（战斗性能优化核心）：统一网格（cell=GRID_CELL）按半径取候选，
## 替代各单位逐帧对全实体列表的 O(n²) 线性扫描。网格与实体缓存同帧重建；
## 位置为本帧网格重建时刻的快照（帧内位移 ≤ 单帧步长，查询半径留余量即可）。
func query_neighbors(pos: Vector2, radius: float) -> Array:
	if _entity_cache_frame != Engine.get_physics_frames():
		_rebuild_entity_cache()
	var out: Array = []
	var min_c := Vector2i(floori((pos.x - radius) / GRID_CELL), floori((pos.y - radius) / GRID_CELL))
	var max_c := Vector2i(floori((pos.x + radius) / GRID_CELL), floori((pos.y + radius) / GRID_CELL))
	for cy in range(min_c.y, max_c.y + 1):
		for cx in range(min_c.x, max_c.x + 1):
			# 注：缺键返回 Nil（不能直接赋类型化 Array）；空键高频出现，避免 [] 缺省值分配
			var cell = _entity_grid.get(Vector2i(cx, cy))
			if cell != null:
				out.append_array(cell)
	return out


# ─────────────────────────────── 实体缓存/空间网格（内部）────────────────────────────────
## 网格边长（px）：略大于分离半径与近战威胁半径，3×3 邻域即可覆盖常用查询
const GRID_CELL: float = 64.0
var _entity_cache_frame: int = -1
var _entity_cache: Array = []
var _entity_grid: Dictionary = {}


func _rebuild_entity_cache() -> void:
	_entity_cache_frame = Engine.get_physics_frames()
	_entity_cache = entity_host.get_children() if entity_host != null else []
	_entity_grid.clear()
	for e in _entity_cache:
		if e == null or not is_instance_valid(e) or not e is Node2D:
			continue
		var key := Vector2i(
				floori((e as Node2D).global_position.x / GRID_CELL),
				floori((e as Node2D).global_position.y / GRID_CELL))
		var cell: Array = _entity_grid.get_or_add(key, [])
		cell.append(e)


func _invalidate_entity_cache(_node: Node) -> void:
	_entity_cache_frame = -1


## 获取玩家附身的实体（如有）
func get_possessed_entity() -> Node2D:
	for e in get_entities():
		if e is CharacterBody2D and e.has_method("is_possessed") and e.is_possessed():
			return e
	return null


## 获取所有 WalkBarrier Area2D 列表（无 WalkBarrier 节点时返回空）
func get_walk_barriers() -> Array:
	if walk_barrier == null:
		return []
	var barriers: Array = []
	for child in walk_barrier.get_children():
		if child is StaticBody2D:
			barriers.append(child)
	return barriers


## 获取所有建筑级 PassageBarrier StaticBody2D 列表（无建筑节点时返回空）。
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
