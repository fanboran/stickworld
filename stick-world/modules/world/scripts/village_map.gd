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
## 草地纹理平铺尺寸（世界坐标 px，每 GRASS_TILE_SIZE 像素重复一次纹理）
const GRASS_TILE_SIZE: float = 512.0

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
		# 从 PassageBarrier 读取宽度
		var width_cells := 1
		var pb: Node = building.get_node_or_null("PassageBarrier")
		if pb:
			for child in pb.get_children():
				if child is CollisionShape2D and child.shape is RectangleShape2D:
					width_cells = maxi(1, int(round((child.shape as RectangleShape2D).size.x / placement_grid.CELL_SIZE)))
					break
		# 建筑原点在底部中心，左边缘 = position.x - width_px / 2
		var width_px: float = width_cells * placement_grid.CELL_SIZE
		var left_x: float = building.position.x - width_px / 2.0
		var cell_x: int = placement_grid.world_to_cell(Vector2(left_x, 0))
		placement_grid.occupy(cell_x, width_cells, building.name)


# ─────────────────────────────── 通行障碍查询（§7.1.2）────────────────────────────────

## 获取所有 WalkBarrier Area2D 列表（地图级通行障碍）
func get_walk_barriers() -> Array:
	if walk_barrier == null:
		return []
	var barriers: Array = []
	for child in walk_barrier.get_children():
		if child is Area2D:
			barriers.append(child)
	return barriers


## 获取所有建筑级 PassageBarrier Area2D 列表
## 同时扫描 building_host（动态建筑）和 terrain_buildings（地形建筑）
func get_passage_barriers() -> Array:
	var barriers: Array = []
	for host in [building_host, terrain_buildings]:
		if host == null:
			continue
		for building in host.get_children():
			var pb: Node = building.get_node_or_null("PassageBarrier") if building.has_method("get_node_or_null") else null
			if pb != null and pb is Area2D:
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
	world_pos = VERTEX;
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
	# 用 ShaderMaterial 的 repeat_enable 强制平铺，shader 内用 VERTEX 计算 UV
	var mat := ShaderMaterial.new()
	mat.shader = Shader.new()
	mat.shader.code = _GRASS_SHADER_CODE
	mat.set_shader_parameter("tex", tex)
	mat.set_shader_parameter("tile_size", Vector2(GRASS_TILE_SIZE, GRASS_TILE_SIZE))
	gp.material = mat
	# 纹理颜色不需要 color 调色，设为白色避免叠加
	gp.color = Color.WHITE


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
