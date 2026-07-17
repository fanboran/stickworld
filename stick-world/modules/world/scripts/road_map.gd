class_name RoadMap
extends Node2D
## 道路地图实例 -- 村落间道路（阶段 0.8）。
##
## 详见 docs/技术/架构/场景与战斗架构.md §3.1（地图类型）/ §6.2（步行流程）。
## 结构与 VillageMap 类似但简化：无建筑系统，两端有出口触发器。
## 玩家从一端进入，走到另一端触发下一张地图加载。
##
## 节点结构：
##   RoadMap (Node2D)
##   ├── TerrainLayer (Node2D)              ← 道路地面
##   │   └── GroundPolygon                  ← 地面多边形
##   ├── GroundLine (Marker2D)              ← 地面线标记
##   ├── EntityHost (Node2D)                ← 火柴人容器
##   └── ChunkTriggers (Node2D)             ← 出口触发器（左右两端）

# WorldAPI 是全局 class_name，无需 preload

# ─────────────────────────────── 地图元数据（§3.4.1）────────────────────────────────
@export var ground_y: float = 810.0
@export var ground_ratio: float = 0.25
@export var map_left: float = 0.0
@export var map_right: float = 4096.0
@export var ground_bottom: float = 1080.0

# ─────────────────────────────── 子节点引用 ────────────────────────────────
@onready var terrain_layer: Node2D = get_node_or_null(WorldAPI.PATH_MAP_TERRAIN_LAYER)
@onready var entity_host: Node2D = get_node_or_null(WorldAPI.PATH_MAP_ENTITY_HOST)
@onready var chunk_triggers: Node2D = get_node_or_null(WorldAPI.PATH_MAP_CHUNK_TRIGGERS)
@onready var ground_line: Marker2D = get_node_or_null(WorldAPI.PATH_MAP_GROUND_LINE)

# ─────────────────────────────── 元数据 ────────────────────────────────
var map_id: String = ""


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	_sync_ground_line()
	_apply_road_texture()


func _sync_ground_line() -> void:
	if ground_line != null:
		ground_line.position = Vector2(0, ground_y)


# ─────────────────────────────── 道路纹理 ────────────────────────────────
# 道路使用纯色填充（P0 简化），后续可替换为道路纹理。

func _apply_road_texture() -> void:
	if terrain_layer == null:
		return
	var gp: Polygon2D = terrain_layer.get_node_or_null("GroundPolygon")
	if gp == null:
		return
	# P0：道路用深棕色
	gp.color = Color(0.45, 0.35, 0.25, 1.0)


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


func get_map_width() -> float:
	return map_right - map_left


## 生成实体到 EntityHost，注入地面约束参数
func spawn_entity(entity_scene: PackedScene, p_position: Vector2) -> Node2D:
	if entity_host == null or entity_scene == null:
		push_error("[RoadMap] 无法生成实体: entity_host 或 scene 为空")
		return null
	var instance: Node2D = entity_scene.instantiate() as Node2D
	if instance == null:
		push_error("[RoadMap] 实体场景实例化失败")
		return null
	entity_host.add_child(instance)
	instance.global_position = p_position
	if instance.has_method("set_ground_constraints"):
		instance.set_ground_constraints(ground_y, ground_bottom, map_left, map_right)
	if instance.has_method("set_map_reference"):
		instance.set_map_reference(self)
	return instance


## 获取所有 StickmanEntity
func get_entities() -> Array:
	if entity_host == null:
		return []
	return entity_host.get_children()


## 获取玩家附身的实体
func get_possessed_entity() -> Node2D:
	for e in get_entities():
		if e is CharacterBody2D and e.has_method("is_possessed") and e.is_possessed():
			return e
	return null


## 获取所有 WalkBarrier Area2D 列表（道路无障碍，返回空）
func get_walk_barriers() -> Array:
	return []


## 获取所有建筑级 PassageBarrier Area2D 列表（道路无建筑，返回空）
func get_passage_barriers() -> Array:
	return []
