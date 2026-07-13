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
##   ├── EntityHost (Node2D)                   ← 火柴人容器
##   ├── ChunkTriggers (Node2D)                ← 末端触发器（P0 空）
##   └── BattleAnchor (Node2D)                 ← 战斗实例挂载点（P0 空）

const WorldAPI := preload("res://modules/world/api.gd")

# ─────────────────────────────── 地图元数据（§3.4.1）────────────────────────────────
## 地面线 Y（世界坐标），火柴人可走区域顶部
@export var ground_y: float = 450.0
## 地面占屏幕高度比例（Inspector 可改，默认 0.4 = 2/5）
@export var ground_ratio: float = 0.4
## 地图左边界 X（相机/火柴人 X 下限）
@export var map_left: float = 0.0
## 地图右边界 X（相机/火柴人 X 上限）—— 卷轴式水平展开，P0 设为 8192（足够测试左右移动）
@export var map_right: float = 8192.0
## 地面底部 Y（火柴人可走区域底部，= ground_y + DESIGN_HEIGHT * ground_ratio = 450 + 1080*0.4 = 882）
## 注意：此值应匹配屏幕可见地面范围，避免地面矩形超出屏幕导致火柴人显示偏下
@export var ground_bottom: float = 882.0
## 草地纹理平铺尺寸（世界坐标 px，每 96px 重复一次噪波纹理）
const GRASS_TILE_SIZE: float = 96.0

# ─────────────────────────────── 子节点引用 ────────────────────────────────
@onready var placement_grid: Node = get_node_or_null(WorldAPI.PATH_MAP_PLACEMENT_GRID)
@onready var terrain_layer: Node2D = get_node_or_null(WorldAPI.PATH_MAP_TERRAIN_LAYER)
@onready var decoration_layer: Node2D = get_node_or_null(WorldAPI.PATH_MAP_DECORATION_LAYER)
@onready var building_host: Node2D = get_node_or_null(WorldAPI.PATH_MAP_BUILDING_HOST)
@onready var entity_host: Node2D = get_node_or_null(WorldAPI.PATH_MAP_ENTITY_HOST)
@onready var chunk_triggers: Node2D = get_node_or_null(WorldAPI.PATH_MAP_CHUNK_TRIGGERS)
@onready var battle_anchor: Node2D = get_node_or_null(WorldAPI.PATH_MAP_BATTLE_ANCHOR)
@onready var ground_line: Marker2D = get_node_or_null("GroundLine")

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


func _validate_children() -> void:
	var required := {
		WorldAPI.PATH_MAP_PLACEMENT_GRID: "PlacementGrid",
		WorldAPI.PATH_MAP_TERRAIN_LAYER: "TerrainLayer",
		WorldAPI.PATH_MAP_BUILDING_HOST: "BuildingHost",
		WorldAPI.PATH_MAP_ENTITY_HOST: "EntityHost",
	}
	for path: String in required.keys():
		if get_node_or_null(path) == null:
			push_error("[VillageMap] 缺少必需子节点: %s" % path)


func _sync_ground_line() -> void:
	# GroundLine 节点位置对齐 ground_y（可视化调试用）
	if ground_line != null:
		ground_line.position = Vector2(0, ground_y)


# ─────────────────────────────── 草地噪波材质（临时调试）────────────────────────────────
# 用 FastNoiseLite 生成噪波，着色为绿色草地纹理，平铺到 GroundPolygon 上作为移动参照物。
# 详见用户需求："给调试时的地面加个临时的材质，可以是一个噪波生成的绿色草地"。
func _apply_grass_texture() -> void:
	if terrain_layer == null:
		push_warning("[VillageMap] terrain_layer 为空，跳过草地材质")
		return
	var gp: Polygon2D = terrain_layer.get_node_or_null("GroundPolygon")
	if gp == null:
		push_warning("[VillageMap] GroundPolygon 不存在，跳过草地材质")
		return
	var tex: ImageTexture = _generate_grass_texture()
	# 直接设置 texture + uv，用 ShaderMaterial 实现 repeat（Polygon2D 默认 clamp uv>1）
	gp.texture = tex
	# 用 ShaderMaterial 覆盖采样行为，让 uv>1 时平铺
	var mat := ShaderMaterial.new()
	mat.shader = _get_grass_shader()
	mat.set_shader_parameter("tex", tex)
	gp.material = mat
	# 平铺 UV：每 GRASS_TILE_SIZE 世界像素重复一次
	var w: float = map_right - map_left
	var h: float = ground_bottom - ground_y
	gp.uv = PackedVector2Array([
		Vector2(0.0, 0.0),
		Vector2(w / GRASS_TILE_SIZE, 0.0),
		Vector2(w / GRASS_TILE_SIZE, h / GRASS_TILE_SIZE),
		Vector2(0.0, h / GRASS_TILE_SIZE)
	])


func _generate_grass_texture() -> ImageTexture:
	# FastNoiseLite 生成 SIMPLEX 噪声，映射到深绿→浅绿渐变
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.08
	noise.seed = 42
	var size: int = 128
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	# 草地配色：深绿 (0.22, 0.42, 0.16) → 浅绿 (0.52, 0.72, 0.36)
	for y in size:
		for x in size:
			var n: float = noise.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			n = clampf(n, 0.0, 1.0)
			var r: float = lerpf(0.22, 0.52, n)
			var g: float = lerpf(0.42, 0.72, n)
			var b: float = lerpf(0.16, 0.36, n)
			img.set_pixel(x, y, Color(r, g, b, 1.0))
	return ImageTexture.create_from_image(img)


const _GRASS_SHADER_CODE: String = """
shader_type canvas_item;

uniform sampler2D tex : repeat_enable, filter_linear_mipmap;

void fragment() {
	COLOR = texture(tex, UV);
}
"""


func _get_grass_shader() -> Shader:
	# 用 const 字符串避免运行时拼接错误
	var shader := Shader.new()
	shader.code = _GRASS_SHADER_CODE
	return shader


# ─────────────────────────────── 公共 API（§3.4.2）────────────────────────────────

func get_ground_y() -> float:
	return ground_y


func get_ground_ratio() -> float:
	return ground_ratio


func get_camera_bounds() -> Vector2:
	return Vector2(map_left, map_right)


func get_entity_walk_bounds() -> Vector2:
	return Vector2(map_left, map_right)


## 生成实体到 EntityHost，并注入 ground_y / map_left / map_right
func spawn_entity(entity_scene: PackedScene, position: Vector2) -> Node2D:
	if entity_host == null or entity_scene == null:
		push_error("[VillageMap] 无法生成实体: entity_host 或 scene 为空")
		return null
	var instance: Node2D = entity_scene.instantiate() as Node2D
	if instance == null:
		push_error("[VillageMap] 实体场景实例化失败")
		return null
	entity_host.add_child(instance)
	instance.global_position = position
	# 注入地面约束参数（详见 §7.1.1）
	if instance.has_method("set_ground_constraints"):
		instance.set_ground_constraints(ground_y, ground_bottom, map_left, map_right)
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
