class_name RoadMap
extends MapBase
## 道路地图实例 -- 村落间道路（阶段 0.8）。
##
## 详见 docs/技术/架构/场景与战斗架构.md §3.1（地图类型）/ §6.2（步行流程）。
## 结构与 VillageMap 类似但简化：无建筑系统，两端有出口触发器。
## 玩家从一端进入，走到另一端触发下一张地图加载。
## 公共 API（spawn_entity/get_entities/get_possessed_entity/元数据 getter 等）继承自 MapBase。
##
## 节点结构：
##   RoadMap (Node2D)
##   ├── TerrainLayer (Node2D)              ← 道路地面
##   │   └── GroundPolygon                  ← 地面多边形
##   ├── GroundLine (Marker2D)              ← 地面线标记
##   ├── EntityHost (Node2D)                ← 火柴人容器
##   └── ChunkTriggers (Node2D)             ← 出口触发器（左右两端）

# WorldAPI 是全局 class_name，无需 preload

# ─────────────────────────────── 子节点引用 ────────────────────────────────
@onready var terrain_layer: Node2D = get_node_or_null(WorldAPI.PATH_MAP_TERRAIN_LAYER)
@onready var chunk_triggers: Node2D = get_node_or_null(WorldAPI.PATH_MAP_CHUNK_TRIGGERS)
@onready var ground_line: Marker2D = get_node_or_null(WorldAPI.PATH_MAP_GROUND_LINE)


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
