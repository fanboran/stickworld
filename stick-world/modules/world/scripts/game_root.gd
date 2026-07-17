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
## ConstructionManager 脚本（用于实例化建造系统）
const _ConstructionManagerScript: GDScript = preload("res://modules/construction/scripts/construction_manager.gd")
## Construction api 脚本
const _ConstructionApiScript: GDScript = preload("res://modules/construction/api.gd")
## BattleDirector 脚本（战斗系统，§8.1）
const _BattleDirectorScript: GDScript = preload("res://modules/combat/scripts/battle_director.gd")
## Combat api 脚本
const _CombatApiScript: GDScript = preload("res://modules/combat/api.gd")
## SelectionSystem 脚本（§15 阶段 0.6 框选系统）
const _SelectionSystemScript: GDScript = preload("res://modules/combat/scripts/selection_system.gd")

## 测试村落地图 ID
const TEST_VILLAGE_MAP_ID := "test_village"
## 玩家初始 X 位置（地图坐标系，偏左便于观察）
const PLAYER_SPAWN_X: float = 300.0
## NPC 村民数量（P0 测试用，展示 AI 行为）
const NPC_COUNT: int = 5
## 演示建筑的 cell_x（远离玩家 spawn，避免阻挡）
const DEMO_BUILDING_CELL_X: int = 50

# ─────────────────────────────── 建造系统（§15 阶段 0.4）────────────────────────────────

## 是否在地图加载完成后自动触发一次演示建造（test_stage_03 等旧测试应关闭）
@export var auto_demo_building: bool = true
## ConstructionManager 实例引用（运行时由 _ready 装配）
var _construction_manager: Node = null
## Construction api 实例引用（运行时由 _ready 装配）
var _construction_api: Node = null

# ─────────────────────────────── 战斗系统（§15 阶段 0.5）────────────────────────────────
## CombatApi 实例引用（运行时由 _ready 装配）
var _combat_api: Node = null

# ─────────────────────────────── 框选系统（§15 阶段 0.6）────────────────────────────────
## SelectionSystem 实例引用（运行时由 _ready 装配，挂到 UIRoot）
var _selection_system: Control = null

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
	_setup_construction_system()
	_setup_combat_system()
	_setup_selection_system()
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


# ─────────────────────────────── 建造系统装配 ────────────────────────────────

## 实例化 ConstructionManager + api.gd 作为子节点，并互相 setup。
## 详见 §15 阶段 0.4。
func _setup_construction_system() -> void:
	# 实例化 ConstructionManager
	var mgr := Node.new()
	mgr.set_script(_ConstructionManagerScript)
	mgr.name = "ConstructionManager"
	add_child(mgr)
	_construction_manager = mgr
	# 实例化 api.gd（公共接口契约）
	var api := Node.new()
	api.set_script(_ConstructionApiScript)
	api.name = "ConstructionApi"
	add_child(api)
	_construction_api = api
	# api.setup 必须在 manager._ready 后调用（_ready 中初始化 _assigner）
	# 这里用 call_deferred 保证顺序
	call_deferred("_setup_construction_api_deferred")


func _setup_construction_api_deferred() -> void:
	if _construction_api == null or _construction_manager == null:
		return
	if not _construction_api.has_method("setup"):
		return
	_construction_api.setup(_construction_manager)


# ─────────────────────────────── 战斗系统装配 ────────────────────────────────

## 给场景中的 BattleDirector 节点挂脚本，并实例化 CombatApi。
## 详见 §15 阶段 0.5。
func _setup_combat_system() -> void:
	# 给场景中已存在的 BattleDirector 节点挂脚本（§8.1）
	if battle_director != null:
		battle_director.set_script(_BattleDirectorScript)
	# 实例化 CombatApi（公共接口契约）
	var api := Node.new()
	api.set_script(_CombatApiScript)
	api.name = "CombatApi"
	add_child(api)
	_combat_api = api
	# api.setup 必须在 battle_director 脚本挂载后调用
	call_deferred("_setup_combat_api_deferred")


func _setup_combat_api_deferred() -> void:
	if _combat_api == null or battle_director == null:
		return
	if not _combat_api.has_method("setup"):
		return
	_combat_api.setup(battle_director)


## 获取 CombatApi 引用（供测试用）
func get_combat_api() -> Node:
	return _combat_api


# ─────────────────────────────── 框选系统装配 ────────────────────────────────

## 实例化 SelectionSystem，挂到 UIRoot 下，注册为 BATTLE 模式 handler。
## 详见 §15 阶段 0.6。
func _setup_selection_system() -> void:
	if ui_root == null:
		push_warning("[GameRoot] UIRoot 为空，跳过框选系统装配")
		return
	var sel := Control.new()
	sel.set_script(_SelectionSystemScript)
	sel.name = "SelectionSystem"
	ui_root.add_child(sel)
	_selection_system = sel
	# 注册为 BATTLE 模式 handler
	if input_dispatcher != null and input_dispatcher.has_method("register_handler"):
		input_dispatcher.register_handler(PlayerControlAPI.Mode.BATTLE, sel)


## 获取 SelectionSystem 引用（供测试用）
func get_selection_system() -> Control:
	return _selection_system


## 获取 BattleDirector 引用（供测试用）
func get_battle_director_node() -> Node:
	return battle_director


## 启动一场测试战斗（供 test_stage_05 调用）。
## attacker_units / defender_units: StickmanEntity 数组
## 返回 BattleInstance（失败返回 null）
func start_test_battle(attacker_units: Array, defender_units: Array) -> Node:
	if battle_director == null or not battle_director.has_method("start_battle_at"):
		push_warning("[GameRoot] BattleDirector 未就绪")
		return null
	var map: Node2D = get_current_map()
	if map == null:
		push_warning("[GameRoot] 当前无地图，无法启动战斗")
		return null
	return battle_director.start_battle_at(map, attacker_units, defender_units)


## 获取 ConstructionManager 引用（供测试用）
func get_construction_manager() -> Node:
	return _construction_manager


## 获取 Construction api 引用（供测试用）
func get_construction_api() -> Node:
	return _construction_api


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
	# 注入地图到 ConstructionManager（供项目实例化建筑用）
	if _construction_manager != null and _construction_manager.has_method("set_map"):
		_construction_manager.set_map(map)
	# spawn NPC 村民（不附身，AI 自动驱动 idle ↔ move，详见 §7.2）
	_spawn_npcs(map, spawn_y)
	# 切到 EXPLORE 模式激活 handler（此时实体已就绪，不会触发"未找到可附身实体"警告）
	if input_dispatcher and input_dispatcher.has_method("set_mode"):
		input_dispatcher.set_mode(PlayerControlAPI.Mode.EXPLORE)
	# 注册调试绘制器
	_register_debug_drawers()
	# 自动触发演示建造（test_stage_03 等旧测试应通过 auto_demo_building=false 关闭）
	if auto_demo_building:
		call_deferred("_start_demo_building")


# ─────────────────────────────── 演示建造 ────────────────────────────────

## 触发一次演示建造：在 DEMO_BUILDING_CELL_X 处建一栋 bld_workshop。
## NPC 会通过 AIController 自动派工并完成建造。
func _start_demo_building() -> void:
	if _construction_api == null or not _construction_api.has_method("start_construction"):
		push_warning("[GameRoot] 建造系统未就绪，跳过演示建造")
		return
	var region_id := "test_region"
	var building_type := "bld_workshop"
	var result: Dictionary = _construction_api.start_construction(region_id, building_type, "")
	if result.get("ok", false):
		print("[GameRoot] 演示建造已启动: project=%s cell_x=%d" % [result.get("project_id", ""), DEMO_BUILDING_CELL_X])
	else:
		push_warning("[GameRoot] 演示建造失败: %s" % result.get("error", "未知错误"))


## 主动按指定 cell_x 触发建造（供 test_stage_04 测试用）。
## 返回 {ok, project_id, cell_x, width} 或 {ok:false, error}。
func start_demo_building_at(cell_x: int) -> Dictionary:
	if _construction_api == null or not _construction_api.has_method("start_construction"):
		return {"ok": false, "error": "建造系统未就绪"}
	if _construction_manager == null or not _construction_manager.has_method("start_construction_at"):
		return {"ok": false, "error": "ConstructionManager 未就绪"}
	# 直接调用 manager 的 start_construction_at（按指定位置）
	return _construction_manager.start_construction_at("test_region", "bld_workshop", cell_x, "")


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
			# 注入 ConstructionManager 引用，使 NPC 可被派工（§15 阶段 0.4）
			if npc.has_method("set_construction_manager") and _construction_manager != null:
				npc.set_construction_manager(_construction_manager)


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
