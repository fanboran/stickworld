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
## 第二个测试村落地图场景（阶段 0.8 多场景衔接）
const _VILLAGE_MAP_B_SCENE: PackedScene = preload("res://modules/world/scenes/test_village_map_b.tscn")
## 道路地图场景（阶段 0.8 村落间道路）
const _ROAD_MAP_SCENE: PackedScene = preload("res://modules/world/scenes/test_road_map.tscn")
## 测试大建筑内部地图场景（阶段 0.9.5 传送切换）
const _MEGA_INTERIOR_SCENE: PackedScene = preload("res://modules/world/scenes/test_mega_interior.tscn")
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
## FormationSystem 脚本（§15 阶段 0.6 编队系统）
const _FormationSystemScript: GDScript = preload("res://modules/combat/scripts/formation_system.gd")
## OrganizationManager 脚本（组织模块内部管理器）
const _OrganizationManagerScript: GDScript = preload("res://modules/organization/scripts/organization_manager.gd")
## Organization api 脚本（组织模块公共接口）
const _OrganizationApiScript: GDScript = preload("res://modules/organization/api.gd")
## TacticalOrders 脚本（§15 阶段 0.6 战术号令）
const _TacticalOrdersScript: GDScript = preload("res://modules/combat/scripts/tactical_orders.gd")
## CommandChain 脚本（§15 阶段 0.6 指挥链）
const _CommandChainScript: GDScript = preload("res://modules/combat/scripts/command_chain.gd")
## BattlePanel 脚本（§15 阶段 0.6 战斗 UI）
const _BattlePanelScript: GDScript = preload("res://modules/ui/scripts/battle_panel.gd")
## Minimap 脚本（§15 阶段 0.6 小地图）
const _MinimapScript: GDScript = preload("res://modules/ui/scripts/minimap.gd")
## PossessionInterface 脚本（附身系统，§15 阶段 0.7）
const _PossessionInterfaceScript: GDScript = preload("res://modules/player_control/scripts/possession_interface.gd")
## PossessPanel 脚本（附身 UI，§15 阶段 0.7）
const _PossessPanelScript: GDScript = preload("res://modules/ui/scripts/possess_panel.gd")

## 测试村落地图 ID
const TEST_VILLAGE_MAP_ID := "test_village"
## 道路地图 ID（村落 A -> 村落 B）
const ROAD_MAP_ID := "road_a_to_b"
## 第二个测试村落地图 ID
const VILLAGE_B_MAP_ID := "test_village_b"
## 测试大建筑内部地图 ID
const MEGA_INTERIOR_MAP_ID := "test_mega_interior"
## 玩家初始 X 位置（地图坐标系，偏左便于观察）
const PLAYER_SPAWN_X: float = 300.0
## NPC 村民数量（P0 测试用，展示 AI 行为）
const NPC_COUNT: int = 5
## 演示建筑的 cell_x（远离玩家 spawn，避免阻挡）
const DEMO_BUILDING_CELL_X: int = 50

# ─────────────────────────────── 建造系统（§15 阶段 0.4）────────────────────────────────

## 是否在地图加载完成后自动触发一次演示建造（test_stage_03 等旧测试应关闭）
@export var auto_demo_building: bool = true
## 是否已加载过初始地图（用于区分初始加载 vs 地图切换）
var _initial_map_loaded: bool = false
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

# ─────────────────────────────── 组织 + 编队系统（§15 阶段 0.6）────────────────────────────────
## OrganizationApi 实例引用（运行时由 _ready 装配）
var _organization_api: Node = null
## FormationSystem 实例引用（运行时由 _ready 装配）
var _formation_system: Node = null
## TacticalOrders 实例引用（运行时由 _ready 装配）
var _tactical_orders: Node = null
## CommandChain 实例引用（运行时由 _ready 装配）
var _command_chain: Node = null

# ─────────────────────────────── UI 系统（§15 阶段 0.6）────────────────────────────────
## BattlePanel 实例引用（运行时由 _ready 装配）
var _battle_panel: Control = null
## Minimap 实例引用（运行时由 _ready 装配）
var _minimap: Control = null

# ─────────────────────────────── 附身系统（§15 阶段 0.7）────────────────────────────────
## PossessionInterface 实例引用（运行时由 _ready 装配）
var _possession_interface: Node = null
## PossessPanel 实例引用（运行时由 _ready 装配）
var _possess_panel: Control = null

# ─────────────────────────────── 传送系统（§5.6）────────────────────────────────
## 传送返回地图 ID（进入 MegaInteriorMap 前记录，退出时返回）
var _return_map_id: String = ""
## 传送进入点 X（返回时 spawn 位置）
var _return_spawn_x: float = 0.0

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
	_setup_organization_system()
	_setup_formation_system()
	_setup_tactical_system()
	_setup_battle_panel()
	_setup_minimap()
	_setup_possession_interface()
	_setup_possess_panel()
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


# ─────────────────────────────── 组织系统装配 ────────────────────────────────

## 实例化 OrganizationManager + OrganizationApi 作为子节点并互相 setup。
func _setup_organization_system() -> void:
	# OrganizationManager 是 RefCounted，直接 new
	var mgr = _OrganizationManagerScript.new()
	# OrganizationApi 是 Node，挂为子节点
	var api := Node.new()
	api.set_script(_OrganizationApiScript)
	api.name = "OrganizationApi"
	add_child(api)
	_organization_api = api
	# api.setup 需要 manager 引用
	if api.has_method("setup"):
		api.setup(mgr)


## 获取 OrganizationApi 引用（供测试用）
func get_organization_api() -> Node:
	return _organization_api


# ─────────────────────────────── 编队系统装配 ────────────────────────────────

## 实例化 FormationSystem，注入 OrganizationApi 引用。
func _setup_formation_system() -> void:
	var fs := Node.new()
	fs.set_script(_FormationSystemScript)
	fs.name = "FormationSystem"
	add_child(fs)
	_formation_system = fs
	if _organization_api != null and fs.has_method("setup"):
		fs.setup(_organization_api)


## 获取 FormationSystem 引用（供测试用）
func get_formation_system() -> Node:
	return _formation_system


# ─────────────────────────────── 战术号令系统装配 ────────────────────────────────

## 实例化 CommandChain + TacticalOrders，注入 FormationSystem 引用。
func _setup_tactical_system() -> void:
	# CommandChain
	var cc := Node.new()
	cc.set_script(_CommandChainScript)
	cc.name = "CommandChain"
	add_child(cc)
	_command_chain = cc
	# TacticalOrders
	var to := Node.new()
	to.set_script(_TacticalOrdersScript)
	to.name = "TacticalOrders"
	add_child(to)
	_tactical_orders = to
	if to.has_method("setup"):
		to.setup(_formation_system, _command_chain)


## 获取 TacticalOrders 引用（供测试用）
func get_tactical_orders() -> Node:
	return _tactical_orders


## 获取 CommandChain 引用（供测试用）
func get_command_chain() -> Node:
	return _command_chain


# ─────────────────────────────── 战斗 UI 装配（§15 阶段 0.6）────────────────────────────────

## 给场景中已存在的 BattlePanel 占位节点挂脚本，并注入系统引用。详见 §10.1。
func _setup_battle_panel() -> void:
	if ui_root == null:
		return
	var mp: Control = ui_root.get_node_or_null("ModePanel")
	if mp == null:
		return
	var bp: Control = mp.get_node_or_null("BattlePanel")
	if bp == null:
		return
	bp.set_script(_BattlePanelScript)
	_battle_panel = bp
	call_deferred("_setup_battle_panel_deferred")


func _setup_battle_panel_deferred() -> void:
	if _battle_panel == null:
		return
	if _battle_panel.has_method("setup"):
		_battle_panel.setup(self)


## 获取 BattlePanel 引用（供测试用）
func get_battle_panel() -> Control:
	return _battle_panel


# ─────────────────────────────── 小地图装配（§15 阶段 0.6）────────────────────────────────

## 创建 Minimap 并挂到 UIRoot。详见 §10.4。
func _setup_minimap() -> void:
	if ui_root == null:
		return
	var mm := Control.new()
	mm.set_script(_MinimapScript)
	mm.name = "Minimap"
	ui_root.add_child(mm)
	_minimap = mm
	if mm.has_method("setup"):
		mm.setup(self)


## 获取 Minimap 引用（供测试用）
func get_minimap() -> Control:
	return _minimap

# ─────────────────────────────── 附身系统装配（§15 阶段 0.7）────────────────────────────────

## 实例化 PossessionInterface，注册为 POSSESS 模式 handler。
func _setup_possession_interface() -> void:
	var pi := Node.new()
	pi.set_script(_PossessionInterfaceScript)
	pi.name = "PossessionInterface"
	add_child(pi)
	_possession_interface = pi
	# 注册为 POSSESS handler
	if input_dispatcher != null and input_dispatcher.has_method("register_handler"):
		input_dispatcher.register_handler(PlayerControlAPI.Mode.POSSESS, pi)

## 给场景中已存在的 PossessPanel 占位节点挂脚本，并调用 setup。
func _setup_possess_panel() -> void:
	if ui_root == null:
		return
	var mp: Control = ui_root.get_node_or_null("ModePanel")
	if mp == null:
		return
	var pp: Control = mp.get_node_or_null("PossessPanel")
	if pp == null:
		return
	pp.set_script(_PossessPanelScript)
	_possess_panel = pp
	call_deferred("_setup_possess_panel_deferred")

func _setup_possess_panel_deferred() -> void:
	if _possess_panel == null:
		return
	if _possess_panel.has_method("setup"):
		_possess_panel.setup(self)

## 获取 PossessionInterface 引用（供测试和 Building 调用）
func get_possession_interface() -> Node:
	return _possession_interface

## 获取 PossessPanel 引用（供测试用）
func get_possess_panel() -> Control:
	return _possess_panel

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
	# 注册地图场景
	scene_loader.register_map(TEST_VILLAGE_MAP_ID, _VILLAGE_MAP_SCENE, WorldAPI.MapType.VILLAGE)
	scene_loader.register_map(ROAD_MAP_ID, _ROAD_MAP_SCENE, WorldAPI.MapType.ROAD)
	scene_loader.register_map(VILLAGE_B_MAP_ID, _VILLAGE_MAP_B_SCENE, WorldAPI.MapType.VILLAGE)
	scene_loader.register_map(MEGA_INTERIOR_MAP_ID, _MEGA_INTERIOR_SCENE, WorldAPI.MapType.MEGA_INTERIOR)
	# 配置地图出口（步行衔接，详见 §6.2）
	scene_loader.register_map_exit(TEST_VILLAGE_MAP_ID, WorldAPI.EntrySide.RIGHT, ROAD_MAP_ID, WorldAPI.EntrySide.LEFT)
	scene_loader.register_map_exit(ROAD_MAP_ID, WorldAPI.EntrySide.LEFT, TEST_VILLAGE_MAP_ID, WorldAPI.EntrySide.RIGHT)
	scene_loader.register_map_exit(ROAD_MAP_ID, WorldAPI.EntrySide.RIGHT, VILLAGE_B_MAP_ID, WorldAPI.EntrySide.LEFT)
	scene_loader.register_map_exit(VILLAGE_B_MAP_ID, WorldAPI.EntrySide.LEFT, ROAD_MAP_ID, WorldAPI.EntrySide.RIGHT)


func _load_test_village() -> void:
	if scene_loader == null or not scene_loader.has_method("load_map"):
		return
	# 永久监听 map_loaded，处理所有地图加载（初始 + 切换）
	if not scene_loader.map_loaded.is_connected(_on_map_loaded):
		scene_loader.map_loaded.connect(_on_map_loaded)
	scene_loader.load_map(TEST_VILLAGE_MAP_ID)


## 通用地图加载回调（初始加载 + 地图切换共用）
func _on_map_loaded(map_id: String, _map_type: int) -> void:
	var map: Node2D = scene_loader.get_current_map() if scene_loader.has_method("get_current_map") else null
	if map == null or not map.has_method("spawn_entity"):
		return
	# 计算玩家 spawn 位置
	var spawn_x: float
	var entry_side: int = scene_loader.get_last_entry_side() if scene_loader.has_method("get_last_entry_side") else WorldAPI.EntrySide.LEFT
	if not _initial_map_loaded:
		# 初始加载：固定 spawn 位置
		spawn_x = PLAYER_SPAWN_X
	else:
		# 地图切换：根据进入方向决定 spawn 位置
		if entry_side == WorldAPI.EntrySide.LEFT:
			spawn_x = map.map_left + 150.0
		else:
			spawn_x = map.map_right - 150.0
	var spawn_y: float = map.ground_y + (map.ground_bottom - map.ground_y) * 0.5
	# Spawn 玩家
	var player: Node2D = map.spawn_entity(_STICKMAN_ENTITY_SCENE, Vector2(spawn_x, spawn_y))
	if player == null:
		return
	# 修正 Y：让脚部对齐 spawn_y
	if player.get("foot_offset") != null:
		player.global_position.y = spawn_y - player.foot_offset
	# 附身玩家实体（地图切换时需重新附身新实体）
	if player.has_method("set_possessed"):
		player.set_possessed(true)
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
	# 配置小地图地图信息（详见 §10.4.6）
	if _minimap != null and _minimap.has_method("set_map_info"):
		_minimap.set_map_info(map.map_left, map.map_right, map.ground_y, map.ground_ratio)
	# 注入地图到 ConstructionManager（供项目实例化建筑用）
	if _construction_manager != null and _construction_manager.has_method("set_map"):
		_construction_manager.set_map(map)
	# 仅初始加载时 spawn 初始建筑、NPC 和演示建造
	if not _initial_map_loaded:
		_initial_map_loaded = true
		_spawn_initial_buildings(map)
		_spawn_npcs(map, spawn_y)
		# 自动触发演示建造（test_stage_03 等旧测试应通过 auto_demo_building=false 关闭）
		if auto_demo_building:
			call_deferred("_start_demo_building")
	# 切到 EXPLORE 模式激活 handler（此时实体已就绪，不会触发"未找到可附身实体"警告）
	if input_dispatcher and input_dispatcher.has_method("set_mode"):
		input_dispatcher.set_mode(PlayerControlAPI.Mode.EXPLORE)
	# 注册调试绘制器
	_register_debug_drawers()


## 请求地图旅行（由 ChunkTrigger 调用，详见 §6.2 步行流程）
func request_map_travel(target_map_id: String, entry_side: int) -> void:
	if scene_loader == null or not scene_loader.has_method("travel_to_map"):
		return
	scene_loader.travel_to_map(target_map_id, WorldAPI.TravelMode.WALK, entry_side)


# ─────────────────────────────── 初始建筑 ────────────────────────────────

## 读取地图的 InitialBuildingsList，直接创建 OPERATIONAL 状态建筑（跳过建造过程）。
## P0-2 修复：绕过存档系统，在 VillageMap 首次加载时预置建筑。
func _spawn_initial_buildings(map: Node2D) -> void:
	var ibl: Node = map.get("initial_buildings_list") if "initial_buildings_list" in map else null
	if ibl == null or not ibl.has_method("get_defs"):
		return
	var defs: Array = ibl.get_defs()
	if defs.is_empty():
		return
	if _construction_manager == null or not _construction_manager.has_method("spawn_operational_building"):
		push_warning("[GameRoot] ConstructionManager 未就绪，跳过初始建筑生成")
		return
	for d in defs:
		var def_id: String = d.get("def_id") if d is Dictionary else d.def_id
		var cell_x: int = int(d.get("cell_x") if d is Dictionary else d.cell_x)
		var width: int = int(d.get("width") if d is Dictionary else d.width)
		if def_id.is_empty():
			push_warning("[GameRoot] 初始建筑 def_id 为空，跳过")
			continue
		var result: Dictionary = _construction_manager.spawn_operational_building(def_id, cell_x, width)
		if not result.get("ok", false):
			push_warning("[GameRoot] 初始建筑生成失败: %s cell_x=%d: %s" % [def_id, cell_x, result.get("error", "未知错误")])


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
	# 玩家离开建筑交互区 -> 全局检查是否退出 INDOOR
	if EventBus.has_signal("interior_exited"):
		EventBus.interior_exited.connect(_on_interior_exited)
	# 传送进入大建筑 -> 过场 + 旅行
	if EventBus.has_signal("mega_interior_entered"):
		EventBus.mega_interior_entered.connect(_on_mega_interior_entered)
	# 从大建筑返回
	if EventBus.has_signal("mega_interior_exited"):
		EventBus.mega_interior_exited.connect(_on_mega_interior_exited)


# ─────────────────────────────── 传送系统（§5.6）───────────────────────────────

## 进入大建筑：校验 -> 记录返回信息 -> 过场 -> 旅行
func _on_mega_interior_entered(building_id: int, map_id: String) -> void:
	# 校验：战斗中禁止传送
	if is_in_battle():
		push_warning("[GameRoot] 战斗中禁止传送进入大建筑")
		return
	# 校验：附身中禁止传送
	if _possession_interface != null and _possession_interface.has_method("get_possessed_entity"):
		var pe: Node = _possession_interface.get_possessed_entity()
		if pe != null and is_instance_valid(pe) and _possession_interface.has_method("get") and _possession_interface.get("_slowed_time") == true:
			push_warning("[GameRoot] 附身中禁止传送进入大建筑")
			return
	# 记录返回信息
	_return_map_id = scene_loader.current_map_id if scene_loader != null and scene_loader.has_method("get") else ""
	var player: Node2D = _find_player_entity()
	if player != null and is_instance_valid(player):
		_return_spawn_x = player.global_position.x
	# 显示过场
	_show_transition_overlay("进入宫殿")
	# 延迟执行旅行（等过场淡入完成）
	var tween := create_tween()
	tween.tween_interval(0.5)
	tween.tween_callback(_travel_to_interior.bind(map_id))


func _travel_to_interior(map_id: String) -> void:
	if scene_loader == null or not scene_loader.has_method("travel_to_map"):
		_hide_transition_overlay()
		return
	scene_loader.travel_to_map(map_id, WorldAPI.TravelMode.TELEPORT, WorldAPI.EntrySide.LEFT)
	# 地图加载完成后隐藏过场
	var tween := create_tween()
	tween.tween_interval(0.05)
	tween.tween_callback(_hide_transition_overlay)


## 从大建筑返回
func _on_mega_interior_exited(_return_map_id_received: String) -> void:
	var target := _return_map_id
	if target.is_empty():
		target = _return_map_id_received
	if target.is_empty():
		push_warning("[GameRoot] 无返回地图 ID，无法退出大建筑")
		return
	_show_transition_overlay("离开宫殿")
	var tween := create_tween()
	tween.tween_interval(0.5)
	tween.tween_callback(_travel_back.bind(target))


func _travel_back(target: String) -> void:
	if scene_loader == null or not scene_loader.has_method("travel_to_map"):
		_hide_transition_overlay()
		return
	scene_loader.travel_to_map(target, WorldAPI.TravelMode.TELEPORT, WorldAPI.EntrySide.LEFT)
	var tween := create_tween()
	tween.tween_interval(0.05)
	tween.tween_callback(_hide_transition_overlay)
	# 清空返回记录
	_return_map_id = ""
	_return_spawn_x = 0.0


## 显示过场黑屏
func _show_transition_overlay(text: String) -> void:
	if ui_root == null:
		return
	# 移除旧 overlay
	_hide_transition_overlay()
	var overlay := ColorRect.new()
	overlay.name = "TransitionOverlay"
	overlay.color = Color(0, 0, 0, 0)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_root.add_child(overlay)
	var label := Label.new()
	label.name = "TransitionLabel"
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.add_theme_font_size_override("font_size", 36)
	label.add_theme_color_override("font_color", Color.WHITE)
	overlay.add_child(label)
	# 淡入动画
	var tween := create_tween()
	tween.tween_property(overlay, "color:a", 1.0, 0.5)


## 隐藏过场
func _hide_transition_overlay() -> void:
	if ui_root == null:
		return
	var overlay: Node = ui_root.get_node_or_null("TransitionOverlay")
	if overlay == null:
		return
	var tween := create_tween()
	tween.tween_property(overlay, "color:a", 0.0, 0.5)
	tween.tween_callback(overlay.queue_free)


## 查找当前玩家实体
func _find_player_entity() -> Node2D:
	var map: Node2D = get_current_map()
	if map == null:
		return null
	for e in map.get_entities():
		if e is CharacterBody2D and e.has_method("is_possessed") and e.is_possessed():
			return e
	return null


## 某个建筑的 InteractionZone 离开 -> 检查是否所有建筑都不含玩家
func _on_interior_exited(_building_id: int) -> void:
	_check_indoor_exit()


## 遍历当前地图所有 Building，无玩家在内则退出 INDOOR 模式
func _check_indoor_exit() -> void:
	if input_dispatcher == null or not input_dispatcher.has_method("get_mode"):
		return
	if input_dispatcher.get_mode() != PlayerControlAPI.Mode.INDOOR:
		return
	var map: Node2D = get_current_map()
	if map == null:
		return
	if not _has_any_player_in_building(map):
		if input_dispatcher.has_method("exit_to_explore"):
			input_dispatcher.exit_to_explore()


## 递归遍历节点树，检查是否有 Building 内含玩家
func _has_any_player_in_building(node: Node) -> bool:
	if node is Building and node.has_method("is_player_inside_interaction_zone"):
		if node.is_player_inside_interaction_zone():
			return true
	for child in node.get_children():
		if _has_any_player_in_building(child):
			return true
	return false


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
