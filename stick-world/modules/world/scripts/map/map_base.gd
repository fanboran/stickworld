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
