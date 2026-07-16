class_name GameRoot
extends Node2D
## 游戏主场景控制器 —— 常驻容器。
##
## 持有所有跨场景保持的子系统：
##   EnvironmentSystem / CameraRig / SceneLoader / InputDispatcher
##   WorldChunkHost / UIRoot / BattleDirector
##
## 子场景（村落/战场/室内）通过 SceneLoader 加载到 WorldChunkHost。
## 详见 docs/技术/架构/场景与战斗架构.md §二。

# WorldAPI / PlayerControlAPI 是全局 class_name，无需 preload

## 测试村落地图场景（P0 硬编码）
const _VILLAGE_MAP_SCENE: PackedScene = preload("res://modules/world/scenes/test_village_map.tscn")
## 玩家火柴人实体场景
const _STICKMAN_ENTITY_SCENE: PackedScene = preload("res://modules/units/scenes/stickman_entity.tscn")
## EXPLORE 模式 handler 脚本
const _ExploreHandlerScript: GDScript = preload("res://modules/player_control/scripts/explore_handler.gd")
## 调试绘制器
const _DebugDrawers: GDScript = preload("res://modules/debug/scripts/debug_drawers.gd")

## 测试村落地图 ID
const TEST_VILLAGE_MAP_ID := "test_village"
## 玩家初始 X 位置（地图坐标系，偏左便于观察）
const PLAYER_SPAWN_X: float = 300.0
## NPC 村民数量（P0 测试用，展示 AI 行为）
const NPC_COUNT: int = 5

# ─────────────────────────────── 子节点引用 ────────────────────────────────
@onready var environment_system: Node = get_node_or_null(WorldAPI.PATH_ENVIRONMENT)
@onready var camera_rig: Camera2D = get_node_or_null(WorldAPI.PATH_CAMERA_RIG)
@onready var scene_loader: Node = get_node_or_null(WorldAPI.PATH_SCENE_LOADER)
@onready var input_dispatcher: Node = get_node_or_null(WorldAPI.PATH_INPUT_DISPATCHER)
@onready var world_chunk_host: Node2D = get_node_or_null(WorldAPI.PATH_WORLD_CHUNK_HOST)
@onready var ui_root: CanvasLayer = get_node_or_null(WorldAPI.PATH_UI_ROOT)
@onready var battle_director: Node = get_node_or_null(WorldAPI.PATH_BATTLE_DIRECTOR)


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	_validate_children()
	_bind_event_bus()
	_register_default_maps()
	# 注册 EXPLORE handler（不立即激活，等地图加载完再 set_mode）
	_register_explore_handler()
	# 默认 X1 速度
	if TimeManager:
		TimeManager.set_speed(TimeManager.Speed.X1)
	# 通知游戏开始
	if EventBus:
		EventBus.game_started.emit()
	# 加载测试村落地图（延迟一帧确保 SceneLoader 就绪）
	# 地图加载完成后会 set_mode(EXPLORE) 激活 handler，此时实体已就绪
	call_deferred("_load_test_village")


func _register_explore_handler() -> void:
	if input_dispatcher == null or not input_dispatcher.has_method("register_handler"):
		return
	var handler := Node.new()
	handler.set_script(_ExploreHandlerScript)
	handler.name = "ExploreHandler"
	add_child(handler)
	input_dispatcher.register_handler(PlayerControlAPI.Mode.EXPLORE, handler)


func _register_default_maps() -> void:
	if scene_loader == null or not scene_loader.has_method("register_map"):
		return
	scene_loader.register_map(TEST_VILLAGE_MAP_ID, _VILLAGE_MAP_SCENE, WorldAPI.MapType.VILLAGE)


func _load_test_village() -> void:
	if scene_loader == null or not scene_loader.has_method("load_map"):
		return
	# 监听一次 map_loaded，加载完成后 spawn 玩家
	if not scene_loader.map_loaded.is_connected(_on_test_village_loaded):
		scene_loader.map_loaded.connect(_on_test_village_loaded)
	scene_loader.load_map(TEST_VILLAGE_MAP_ID)


func _on_test_village_loaded(map_id: String, _map_type: int) -> void:
	if map_id != TEST_VILLAGE_MAP_ID:
		return
	# 解除连接（仅一次性）
	if scene_loader and scene_loader.map_loaded.is_connected(_on_test_village_loaded):
		scene_loader.map_loaded.disconnect(_on_test_village_loaded)
	# 在地图上 spawn 玩家，Y 在地面垂直范围内偏中心
	var map: Node2D = scene_loader.get_current_map() if scene_loader.has_method("get_current_map") else null
	if map == null or not map.has_method("spawn_entity"):
		return
	# 火柴人生成 Y = 地面偏中心（ground_y 与 ground_bottom 中间偏上）
	# 注意：spawn_y 是脚部目标 Y，entity origin 需要偏移 foot_offset
	var spawn_y: float = map.ground_y + (map.ground_bottom - map.ground_y) * 0.5
	var player: Node2D = map.spawn_entity(_STICKMAN_ENTITY_SCENE, Vector2(PLAYER_SPAWN_X, spawn_y))
	if player == null:
		return
	# 修正 Y：让脚部对齐 spawn_y
	if player.get("foot_offset") != null:
		player.global_position.y = spawn_y - player.foot_offset
	# 配置相机：注入 ground_y / ground_ratio / map_bounds（详见 §2.4.7）
	if camera_rig != null and camera_rig.has_method("set_ground_y"):
		camera_rig.set_ground_y(map.ground_y)
	if camera_rig != null and camera_rig.has_method("set_ground_ratio"):
		camera_rig.set_ground_ratio(map.ground_ratio)
	if camera_rig != null and camera_rig.has_method("set_map_bounds"):
		camera_rig.set_map_bounds(map.map_left, map.map_right)
	# 让 CameraRig 跟随玩家
	if camera_rig != null and camera_rig.has_method("set_follow_target"):
		camera_rig.set_follow_target(player)
	# spawn NPC 村民（不附身，AI 自动驱动 idle ↔ move，详见 §7.2）
	_spawn_npcs(map, spawn_y)
	# 切到 EXPLORE 模式激活 handler（此时实体已就绪，不会触发"未找到可附身实体"警告）
	if input_dispatcher and input_dispatcher.has_method("set_mode"):
		input_dispatcher.set_mode(PlayerControlAPI.Mode.EXPLORE)
	# 注册调试绘制器
	_register_debug_drawers()


## 生成 NPC 村民，分布在玩家右侧不同 X 位置，不附身（AI 接管）。
func _spawn_npcs(map: Node2D, spawn_y: float) -> void:
	for i in NPC_COUNT:
		var x: float = PLAYER_SPAWN_X + 200.0 * (i + 1)
		# 确保在地图边界内
		if x > map.map_right - 100.0:
			x = PLAYER_SPAWN_X + randf_range(100.0, 800.0)
		var npc: Node2D = map.spawn_entity(_STICKMAN_ENTITY_SCENE, Vector2(x, spawn_y))
		if npc != null:
			# 修正 Y：让脚部对齐 spawn_y
			if npc.get("foot_offset") != null:
				npc.global_position.y = spawn_y - npc.foot_offset
			if npc.has_method("set_possessed"):
				npc.set_possessed(false)  # NPC 不被附身，AIController 自动接管


## 注册调试绘制器到 DebugApi（详见 §10.5.7）
func _register_debug_drawers() -> void:
	if DebugApi == null:
		return
	DebugApi.register_drawer("grid_drawer", Callable(_DebugDrawers, "draw_grid"))
	DebugApi.register_drawer("barrier_drawer", Callable(_DebugDrawers, "draw_barriers"))
	DebugApi.register_drawer("building_drawer", Callable(_DebugDrawers, "draw_buildings"))
	DebugApi.register_drawer("ground_line_drawer", Callable(_DebugDrawers, "draw_ground_lines"))
	DebugApi.register_drawer("chunk_trigger_drawer", Callable(_DebugDrawers, "draw_chunk_triggers"))
	DebugApi.register_drawer("entity_state_drawer", Callable(_DebugDrawers, "draw_entity_states"))


func _validate_children() -> void:
	# 校验必需子节点存在（缺一不可）
	var required := {
		WorldAPI.PATH_ENVIRONMENT: "EnvironmentSystem",
		WorldAPI.PATH_CAMERA_RIG: "CameraRig",
		WorldAPI.PATH_SCENE_LOADER: "SceneLoader",
		WorldAPI.PATH_INPUT_DISPATCHER: "InputDispatcher",
		WorldAPI.PATH_WORLD_CHUNK_HOST: "WorldChunkHost",
		WorldAPI.PATH_UI_ROOT: "UIRoot",
	}
	for path: String in required.keys():
		if get_node_or_null(path) == null:
			push_error("[GameRoot] 缺少必需子节点: %s" % path)


func _bind_event_bus() -> void:
	if not EventBus:
		return
	# 玩家请求暂停/恢复
	if EventBus.has_signal("ui_toggle_pause_requested"):
		EventBus.ui_toggle_pause_requested.connect(_on_pause_requested)


func _on_pause_requested() -> void:
	if TimeManager:
		TimeManager.toggle_pause()


# ─────────────────────────────── 公共 API ────────────────────────────────

## 启动新游戏：加载初始村落地图。
func start_new_game(initial_map_id: String) -> void:
	if scene_loader and scene_loader.has_method("load_map"):
		scene_loader.load_map(initial_map_id)


## 获取当前地图实例（可能为空）
func get_current_map() -> Node2D:
	if world_chunk_host and world_chunk_host.get_child_count() > 0:
		return world_chunk_host.get_child(0) as Node2D
	return null


## 当前是否处于战斗中
func is_in_battle() -> bool:
	if battle_director and battle_director.has_method("has_active_battle"):
		return battle_director.has_active_battle()
	return false
