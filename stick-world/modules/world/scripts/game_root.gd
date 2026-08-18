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
##
## 子节点：
##   SystemSetup     —— 系统装配（system_setup.gd）
##   SaveHandler     —— 存档/读档（save_handler.gd）
##   TravelHandler   —— 传送/过场（travel_handler.gd）
##   InitialContent  —— 初始内容生成（initial_content.gd）

# WorldAPI / PlayerControlAPI 是全局 class_name，无需 preload

# ─────────────────────────────── 子模块脚本 ────────────────────────────────

const _SystemSetupScript: GDScript = preload("res://modules/world/scripts/setup/system_setup.gd")
const _SaveHandlerScript: GDScript = preload("res://modules/world/scripts/setup/save_handler.gd")
const _TravelHandlerScript: GDScript = preload("res://modules/world/scripts/setup/travel_handler.gd")
const _InitialContentScript: GDScript = preload("res://modules/world/scripts/setup/initial_content.gd")
## 世界加载覆盖层（消除启动加载期的死灰屏）
const _WorldLoadingOverlayScript: GDScript = preload("res://modules/ui_global/scripts/overlays/world_loading_overlay.gd")

## 测试村落地图场景（P0 硬编码）
const _VILLAGE_MAP_SCENE: PackedScene = preload("res://modules/world/scenes/maps/village_a.tscn")
## 第二个测试村落地图场景（阶段 0.8 多场景衔接）
const _VILLAGE_MAP_B_SCENE: PackedScene = preload("res://modules/world/scenes/maps/village_b.tscn")
## 道路地图场景（阶段 0.8 村落间道路）
const _ROAD_MAP_SCENE: PackedScene = preload("res://modules/world/scenes/maps/road_a_b.tscn")
## 测试大建筑内部地图场景（阶段 0.9.5 传送切换）
const _MEGA_INTERIOR_SCENE: PackedScene = preload("res://modules/world/scenes/maps/mega_interior.tscn")
## 遭遇战战场地图场景（阶段 F）
const _BATTLEFIELD_MAP_SCENE: PackedScene = preload("res://modules/world/scenes/maps/battlefield.tscn")
## 森林附属区域场景（阶段 F）
const _FOREST_ZONE_SCENE: PackedScene = preload("res://modules/world/scenes/maps/forest_zone.tscn")
## 玩家火柴人实体场景（2026-08 收敛：经 UnitsAPI 常量引用，替代直接 preload 内部路径）
const _UnitsApiScript: GDScript = preload("res://modules/units/api.gd")
const _STICKMAN_ENTITY_SCENE: PackedScene = _UnitsApiScript.STICKMAN_ENTITY_SCENE

## 测试村落地图 ID
const VILLAGE_A_MAP_ID := "village_a"
## 道路地图 ID（村落 A -> 村落 B）
const ROAD_MAP_ID := "road_a_b"
## 第二个测试村落地图 ID
const VILLAGE_B_MAP_ID := "village_b"
## 测试大建筑内部地图 ID
const MEGA_INTERIOR_MAP_ID := "mega_interior"
## 遭遇战战场地图 ID（阶段 F）
const BATTLEFIELD_MAP_ID := "battlefield"
## 森林附属区域地图 ID（阶段 F）
const FOREST_ZONE_MAP_ID := "forest_zone"
## 玩家初始 X 位置（世界原点，土路正负对称各 40 格）
const PLAYER_SPAWN_X: float = 0.0
## NPC 村民数量（P0 测试用，展示 AI 行为；阶段 E 创始人确认改为 2）
const NPC_COUNT: int = 2

# ─────────────────────────────── 建造系统（§15 阶段 0.4）────────────────────────────────

## 是否已加载过初始地图（用于区分初始加载 vs 地图切换）
var _initial_map_loaded: bool = false
## ConstructionManager 实例引用（运行时由 SystemSetup 装配）
var _construction_manager: Node = null
## Construction api 实例引用（运行时由 SystemSetup 装配）
var _construction_api: Node = null

# ─────────────────────────────── 战斗系统（§15 阶段 0.5）────────────────────────────────
## CombatApi 实例引用（运行时由 SystemSetup 装配）
var _combat_api: Node = null

# ─────────────────────────────── 框选系统（§15 阶段 0.6）────────────────────────────────
## SelectionSystem 实例引用（运行时由 SystemSetup 装配，挂到 UIRoot）
var _selection_system: Control = null

# ─────────────────────────────── 组织 + 编队系统（§15 阶段 0.6）────────────────────────────────
## OrganizationApi 实例引用（运行时由 SystemSetup 装配）
var _organization_api: Node = null
## FormationSystem 实例引用（运行时由 SystemSetup 装配）
var _formation_system: Node = null
## TacticalOrders 实例引用（运行时由 SystemSetup 装配）
var _tactical_orders: Node = null
## CommandChain 实例引用（运行时由 SystemSetup 装配）
var _command_chain: Node = null

# ─────────────────────────────── UI 系统（§15 阶段 0.6）────────────────────────────────
## BattlePanel 实例引用（运行时由 SystemSetup 装配）
var _battle_panel: Control = null
## Minimap 实例引用（运行时由 SystemSetup 装配）
var _minimap: Control = null
## ZoomBar 实例引用（运行时由 SystemSetup 装配；SystemSetup 跨脚本写入，故加忽略）
@warning_ignore("unused_private_class_variable")
var _zoom_bar: Control = null

# ─────────────────────────────── 附身系统（§15 阶段 0.7）────────────────────────────────
## PossessionInterface 实例引用（运行时由 SystemSetup 装配）
var _possession_interface: Node = null
## PossessPanel 实例引用（运行时由 SystemSetup 装配）
var _possess_panel: Control = null

# ─────────────────────────────── 资源系统（P0-9）────────────────────────────────
## ResourcesApi 实例引用（运行时由 SystemSetup 装配）
var _resources_api: Node = null

# ─────────────────────────────── 传送系统（§5.6；TravelHandler 跨脚本读写，故加忽略）────────────────────────────────
## 传送返回地图 ID（进入 MegaInteriorMap 前记录，退出时返回）
@warning_ignore("unused_private_class_variable")
var _return_map_id: String = ""
## 传送进入点 X（返回时 spawn 位置）
@warning_ignore("unused_private_class_variable")
var _return_spawn_x: float = 0.0

# ─────────────────────────────── 子节点引用 ────────────────────────────────
@onready var environment_system: Node = get_node_or_null(WorldAPI.PATH_ENVIRONMENT)
@onready var camera_rig: Camera2D = get_node_or_null(WorldAPI.PATH_CAMERA_RIG)
@onready var scene_loader: Node = get_node_or_null(WorldAPI.PATH_SCENE_LOADER)
@onready var input_dispatcher: Node = get_node_or_null(WorldAPI.PATH_INPUT_DISPATCHER)
@onready var world_chunk_host: Node2D = get_node_or_null(WorldAPI.PATH_WORLD_CHUNK_HOST)
@onready var ui_root: CanvasLayer = get_node_or_null(WorldAPI.PATH_UI_ROOT)
@onready var battle_director: Node = get_node_or_null(WorldAPI.PATH_BATTLE_DIRECTOR)

# ─────────────────────────────── 子模块实例 ────────────────────────────────
## 系统装配器（SystemSetup 子节点）
var _bootstrap: Node = null
## 存档子系统（SaveHandler 子节点）
var _save_system: Node = null
## 传送子系统（TravelHandler 子节点）
var _travel_system: Node = null
## 初始内容生成器（InitialContent 子节点）
var _worldgen: Node = null

# ─────────────────────────────── 阶段 F 子系统（SystemSetup 跨脚本写入，故加忽略）────────────────────────────────
var _boundary_detector: Node = null
@warning_ignore("unused_private_class_variable")
var _strategic_map: Node = null
@warning_ignore("unused_private_class_variable")
var _strategic_map_l3: Node = null
# ─────────────────────────────── 游玩 UI（SystemSetup 跨脚本写入，故加忽略）────────────────────────────────
@warning_ignore("unused_private_class_variable")
var _possession_indicator: Control = null
@warning_ignore("unused_private_class_variable")
var _hover_indicator: Control = null
@warning_ignore("unused_private_class_variable")
var _middle_scroll_overlay: Control = null
# ─────────────────────────────── 阶段 E 游玩 UI ────────────────────────────────
var _resource_bar: Control = null
var _build_menu: Control = null
## 编制管理窗口（运行时由 SystemSetup 装配到 UIRoot.ModalOverlay）
var _formation_panel: Control = null
## 设置菜单（运行时由 SystemSetup 装配到 UIRoot，齿轮/ESC 打开）
var _settings_menu_panel: Control = null
## 暂停菜单（运行时由 SystemSetup 装配到 UIRoot，ESC 打开；ESC 语义统一在 GameRoot 处理）
var _pause_menu_panel: Control = null
## 世界加载覆盖层（启动加载期显示，世界就绪淡出）
var _world_loading_overlay: Control = null

# ─────────────────────────────── 存档系统（SaveHandler 跨脚本读写，故加忽略）────────────────────────────────
## 是否有存档待加载（读档入口标记）
var _pending_save_load: bool = false
## 读档时缓存的 map_id（从 save_meta 读取）
@warning_ignore("unused_private_class_variable")
var _cached_load_map_id: String = ""
## 存档 UI 面板
@warning_ignore("unused_private_class_variable")
var _save_panel: Control = null

# ─────────────────────────────── 跨图携带（带队出征）────────────────────────────────
## travel_started 时收集的编队快照（跨图携带），map_loaded 后恢复
var _pending_squad_snapshots: Array = []
## 遭遇战敌方数量（dev 场景可调，默认 4）
var dev_enemy_count: int = 4


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	# 加入 game_root group（供 SelectionSystem 等查找相机等服务）
	add_to_group("game_root")
	# 注册 InputDispatcher 到 PlayerControlAPI（units 经 api 获取，不反向依赖 world）
	if input_dispatcher != null:
		PlayerControlAPI.register_input_dispatcher(input_dispatcher)
	# 挂载子模块（SystemSetup / SaveHandler / TravelHandler / InitialContent）
	_mount_child_modules()
	# 世界加载覆盖层：game_root 一启动立即显示，覆盖装配+加载全期（防裸灰屏）。
	# 挂自身高层 CanvasLayer（不依赖尚未装配的 UIRoot），世界就绪后淡出。
	_setup_world_loading_overlay()
	_show_loading("正在加载…")
	# 装配 UI 覆盖层 + 所有子系统（由 SystemSetup 执行）
	_bootstrap.setup(self)
	# 存档系统：信号连接 + 注册 + SavePanel 实例化
	_save_system.setup(self)
	# 传送系统：EventBus 信号连接
	_travel_system.setup(self)
	# 初始内容生成器
	_worldgen.setup(self)
	_validate_children()
	_bind_event_bus()
	# 注册默认地图与地图出口
	_register_default_maps()
	# 默认 X1 速度
	if TimeManager:
		TimeManager.set_speed(TimeManager.Speed.X1)
	# 世界加载覆盖层（启动即显示，_on_map_loaded 世界就绪后淡出）
	# 通知游戏开始
	if EventBus:
		EventBus.game_started.emit()
	# 加载测试村落地图（延迟一帧确保 SceneLoader 就绪）
	# 地图加载完成后会 set_mode(EXPLORE) 激活 handler，此时实体已就绪
	call_deferred("_load_start_village")


## 实例化四个子模块节点并挂到 GameRoot 下。
## 子模块通过 setup(root) 拿到主脚本引用，业务逻辑保持在子模块内部。
func _mount_child_modules() -> void:
	_bootstrap = Node.new()
	_bootstrap.set_script(_SystemSetupScript)
	_bootstrap.name = "SystemSetup"
	add_child(_bootstrap)

	_save_system = Node.new()
	_save_system.set_script(_SaveHandlerScript)
	_save_system.name = "SaveHandler"
	add_child(_save_system)

	_travel_system = Node.new()
	_travel_system.set_script(_TravelHandlerScript)
	_travel_system.name = "TravelHandler"
	add_child(_travel_system)

	_worldgen = Node.new()
	_worldgen.set_script(_InitialContentScript)
	_worldgen.name = "InitialContent"
	add_child(_worldgen)


# ─────────────────────────────── 系统引用访问（供测试/UI 使用）────────────────────────────────

## 获取 CombatApi 引用（供测试用）
func get_combat_api() -> Node:
	return _combat_api


## 获取 ResourcesApi 引用（供测试用）
func get_resources_api() -> Node:
	return _resources_api


## 获取 SelectionSystem 引用（供测试用）
func get_selection_system() -> Control:
	return _selection_system


## 获取 OrganizationApi 引用（供测试用）
func get_organization_api() -> Node:
	return _organization_api


## 获取 FormationSystem 引用（供测试用）
func get_formation_system() -> Node:
	return _formation_system


## 获取 TacticalOrders 引用（供测试用）
func get_tactical_orders() -> Node:
	return _tactical_orders


## 获取 CommandChain 引用（供测试用）
func get_command_chain() -> Node:
	return _command_chain


## 获取 BattlePanel 引用（供测试用）
func get_battle_panel() -> Control:
	return _battle_panel


## 获取 Minimap 引用（供测试用）
func get_minimap() -> Control:
	return _minimap


## 获取 PossessionInterface 引用（供测试和 Building 调用）
func get_possession_interface() -> Node:
	return _possession_interface


## 获取 PossessPanel 引用（供测试用）
func get_possess_panel() -> Control:
	return _possess_panel


## 获取 BattleDirector 引用（供测试用）
func get_battle_director_node() -> Node:
	return battle_director


## 获取 ConstructionManager 引用（供测试用）
func get_construction_manager() -> Node:
	return _construction_manager


## 获取 Construction api 引用（供测试用）
func get_construction_api() -> Node:
	return _construction_api


## 获取 ResourceBar 引用（供测试用）
func get_resource_bar() -> Control:
	return _resource_bar


## 获取 BuildMenu 引用（供测试用）
func get_build_menu() -> Control:
	return _build_menu


## 获取编制管理窗口引用（供测试用）
func get_formation_panel() -> Control:
	return _formation_panel


## 打开/关闭编制管理窗口（GlobalHUD 编制按钮 / BattlePanel 编制按钮调用）
func toggle_formation_panel() -> void:
	if _formation_panel != null and _formation_panel.has_method("toggle"):
		_formation_panel.toggle()


## 获取设置菜单引用（供测试用）
func get_settings_menu_panel() -> Control:
	return _settings_menu_panel


## 打开/关闭设置菜单（左上角齿轮按钮 / 暂停菜单「设置」调用）。
## 经模态栈开合（层键 SETTINGS）；无栈环境回退面板自身 toggle。
func toggle_settings_menu() -> void:
	if _settings_menu_panel == null:
		return
	var stack := _get_modal_stack()
	if stack != null:
		if stack.is_open(UIModalStack.Layer.SETTINGS):
			stack.pop(UIModalStack.Layer.SETTINGS)
		else:
			stack.push(_settings_menu_panel, UIModalStack.Layer.SETTINGS)
	elif _settings_menu_panel.has_method("toggle"):
		_settings_menu_panel.toggle()


## 获取暂停菜单引用（供测试/装配）
func get_pause_menu_panel() -> Control:
	return _pause_menu_panel


## 启动一场测试战斗（供遭遇战/测试调用）。
## attacker_units / defender_units: StickmanEntity 数组
## 返回 BattleInstance（失败返回 null）
## 统一走 CombatApi（不再直调 battle_director，2026-08 审计收敛）
func start_test_battle(attacker_units: Array, defender_units: Array) -> Node:
	if _combat_api == null or not _combat_api.has_method("start_battle"):
		push_warning("[GameRoot] CombatApi 未就绪")
		return null
	var map: Node2D = get_current_map()
	if map == null:
		push_warning("[GameRoot] 当前无地图，无法启动战斗")
		return null
	return _combat_api.start_battle(map, attacker_units, defender_units)


# ─────────────────────────────── 地图注册与加载 ────────────────────────────────

func _register_default_maps() -> void:
	if scene_loader == null or not scene_loader.has_method("register_map"):
		return
	# 注册地图场景
	scene_loader.register_map(VILLAGE_A_MAP_ID, _VILLAGE_MAP_SCENE, WorldAPI.MapType.VILLAGE)
	scene_loader.register_map(ROAD_MAP_ID, _ROAD_MAP_SCENE, WorldAPI.MapType.ROAD)
	scene_loader.register_map(VILLAGE_B_MAP_ID, _VILLAGE_MAP_B_SCENE, WorldAPI.MapType.VILLAGE)
	scene_loader.register_map(MEGA_INTERIOR_MAP_ID, _MEGA_INTERIOR_SCENE, WorldAPI.MapType.MEGA_INTERIOR)
	# 阶段 F：注册遭遇战战场地图
	scene_loader.register_map(BATTLEFIELD_MAP_ID, _BATTLEFIELD_MAP_SCENE, WorldAPI.MapType.BATTLEFIELD)
	# 阶段 F：注册森林附属区域
	scene_loader.register_map(FOREST_ZONE_MAP_ID, _FOREST_ZONE_SCENE, WorldAPI.MapType.VILLAGE)
	# 配置地图出口（步行衔接，详见 §6.2）
	scene_loader.register_map_exit(VILLAGE_A_MAP_ID, WorldAPI.EntrySide.RIGHT, ROAD_MAP_ID, WorldAPI.EntrySide.LEFT)
	scene_loader.register_map_exit(ROAD_MAP_ID, WorldAPI.EntrySide.LEFT, VILLAGE_A_MAP_ID, WorldAPI.EntrySide.RIGHT)
	scene_loader.register_map_exit(ROAD_MAP_ID, WorldAPI.EntrySide.RIGHT, VILLAGE_B_MAP_ID, WorldAPI.EntrySide.LEFT)
	scene_loader.register_map_exit(VILLAGE_B_MAP_ID, WorldAPI.EntrySide.LEFT, ROAD_MAP_ID, WorldAPI.EntrySide.RIGHT)
	# 阶段 F：健全地图系统（任何地图可步行回村，链式衔接：村↔战场↔森林）
	scene_loader.register_map_exit(BATTLEFIELD_MAP_ID, WorldAPI.EntrySide.LEFT, VILLAGE_A_MAP_ID, WorldAPI.EntrySide.RIGHT)
	scene_loader.register_map_exit(VILLAGE_A_MAP_ID, WorldAPI.EntrySide.LEFT, BATTLEFIELD_MAP_ID, WorldAPI.EntrySide.RIGHT)
	scene_loader.register_map_exit(BATTLEFIELD_MAP_ID, WorldAPI.EntrySide.RIGHT, FOREST_ZONE_MAP_ID, WorldAPI.EntrySide.LEFT)
	scene_loader.register_map_exit(FOREST_ZONE_MAP_ID, WorldAPI.EntrySide.LEFT, BATTLEFIELD_MAP_ID, WorldAPI.EntrySide.RIGHT)


func _load_start_village() -> void:
	if scene_loader == null or not scene_loader.has_method("load_map"):
		return
	# 永久监听 map_loaded，处理所有地图加载（初始 + 切换）
	if not scene_loader.map_loaded.is_connected(_on_map_loaded):
		scene_loader.map_loaded.connect(_on_map_loaded)
	# 监听 travel_started：旧图卸载前收集编队快照（跨图携带）
	if not scene_loader.travel_started.is_connected(_on_travel_started):
		scene_loader.travel_started.connect(_on_travel_started)
	# 主菜单指定读档槽位：启动即读档（代替新游戏）
	if SaveManager and SaveManager.boot_load_slot >= 0:
		var boot_slot: int = SaveManager.boot_load_slot
		SaveManager.boot_load_slot = -1
		print_verbose("[GameRoot] 启动读档: 槽位 %d" % boot_slot)
		_show_loading("正在读取存档…")
		load_game_from_slot(boot_slot)
		return
	# 新游戏：重置游戏时间（防上一局残留）
	if WorldState and "game_time" in WorldState:
		WorldState.game_time = 0.0
	# 原型阶段：每次启动都是新游戏（重建存档），不自动读档——旧存档与新代码
	# 不兼容会带来异常状态（灰屏/位置错乱）；手动存档/读档（SavePanel/quick_*）保留
	print_verbose("[GameRoot] 开始新游戏")
	_show_loading("正在生成世界…")
	scene_loader.load_map(VILLAGE_A_MAP_ID)


## 显示世界加载覆盖（启动加载期）
func _show_loading(message: String) -> void:
	if _world_loading_overlay != null and _world_loading_overlay.has_method("show_loading"):
		_world_loading_overlay.show_loading(message)


## 装配世界加载覆盖层：挂 game_root 自身高层 CanvasLayer（layer=10，盖住 UIRoot），
## 在 game_root._ready 最开头调用，覆盖装配+加载全期，不依赖尚未装配的 UIRoot。
func _setup_world_loading_overlay() -> void:
	if _world_loading_overlay != null:
		return
	var layer := CanvasLayer.new()
	layer.name = "WorldLoadingLayer"
	layer.layer = LayerOrder.WORLD_LOADING
	add_child(layer)
	var ov := Control.new()
	ov.set_script(_WorldLoadingOverlayScript)
	ov.name = "WorldLoadingOverlay"
	layer.add_child(ov)
	_world_loading_overlay = ov


## travel_started 回调：旧图卸载前快照全部编队（跨图携带，带队出征）。
func _on_travel_started(_from_id: String, _to_id: String, _mode: int) -> void:
	_snapshot_squads_for_travel()


## 从 FormationSystem 导出编队快照，存入 _pending_squad_snapshots。
## 导出后立即解散全部编队（旧图实体即将随地图销毁，避免 freed 引用残留）。
## 统一走 CombatApi（2026-08 审计收敛，不再直调 combat 内部 manager）。
func _snapshot_squads_for_travel() -> void:
	_pending_squad_snapshots = []
	if _combat_api == null:
		return
	if _combat_api.has_method("export_squads"):
		_pending_squad_snapshots = _combat_api.export_squads()
	if _combat_api.has_method("disband_all_squads"):
		_combat_api.disband_all_squads()


## 跨图携带：在新地图 spawn 随行编队成员（在玩家右侧依次排开）并重建编队。
## map 必须为 scene_loader.get_current_map()（新图）——get_current_map() 取
## world_chunk_host 第一个子节点，旧图 queue_free 延迟销毁时可能返回旧图。
## 返回新地图上的随行实体列表（不含玩家）。无快照时返回空数组。
func _spawn_travel_followers(map: Node2D, player: Node2D, spawn_y: float) -> Array:
	var followers: Array = []
	if _pending_squad_snapshots.is_empty():
		return followers
	var snapshots: Array = _pending_squad_snapshots
	_pending_squad_snapshots = []
	if map == null or not map.has_method("spawn_entity"):
		return followers
	# 旧 instance_id -> 新实体
	var entity_map: Dictionary = {}
	var idx: int = 1
	for snap in snapshots:
		for m in snap.get("members", []):
			var old_iid: int = int(m.get("iid", 0))
			if old_iid == 0 or entity_map.has(old_iid):
				continue
			var x: float = player.global_position.x + 70.0 * idx
			var f: Node2D = map.spawn_entity(_STICKMAN_ENTITY_SCENE, Vector2(x, spawn_y))
			if f == null:
				continue
			# 修正 Y：脚部对齐
			if f.get("foot_offset") != null:
				f.global_position.y = spawn_y - f.foot_offset
			# 不附身（AI 接管），注入系统引用
			if f.has_method("set_possessed"):
				f.set_possessed(false)
			if f.has_method("set_construction_manager") and _construction_api != null:
				f.set_construction_manager(_construction_api)
			if f.has_method("set_formation_system") and _formation_system != null:
				f.set_formation_system(_formation_system)
			entity_map[old_iid] = f
			followers.append(f)
			idx += 1
	# 重建编队（preset/职责/排长）
	if _combat_api != null and _combat_api.has_method("restore_squads"):
		_combat_api.restore_squads(snapshots, entity_map)
	return followers


## 通用地图加载回调（初始加载 + 地图切换共用）
func _on_map_loaded(map_id: String, _map_type: int) -> void:
	var map: Node2D = scene_loader.get_current_map() if scene_loader.has_method("get_current_map") else null
	if map == null or not map.has_method("spawn_entity"):
		return
	# 注入地图到 ConstructionManager（供项目实例化建筑用；走 api 收敛）
	if _construction_api != null and _construction_api.has_method("set_map"):
		_construction_api.set_map(map)
	# 阶段 F：注入地图到 MapBoundaryDetector
	if _boundary_detector != null and _boundary_detector.has_method("set_map"):
		_boundary_detector.set_map(map)
	# 配置相机：注入 ground_y / ground_ratio / map_bounds（详见 §2.4.7）
	if camera_rig != null and camera_rig.has_method("set_ground_y"):
		camera_rig.set_ground_y(map.ground_y)
	if camera_rig != null and camera_rig.has_method("set_ground_ratio"):
		camera_rig.set_ground_ratio(map.ground_ratio)
	if camera_rig != null and camera_rig.has_method("set_map_bounds"):
		camera_rig.set_map_bounds(map.map_left, map.map_right)
	# 配置小地图地图信息（详见 §10.4.6）
	if _minimap != null and _minimap.has_method("set_map_info"):
		_minimap.set_map_info(map.map_left, map.map_right, map.ground_y, map.ground_ratio)
	# 读档恢复：跳过默认 spawn，由 SaveHandler 接管
	if _pending_save_load:
		_pending_save_load = false
		_save_system._restore_from_save(map, map_id)
	# 正常流程：spawn 玩家 + 初始内容
	else:
		var spawn_x: float
		var entry_side: int = scene_loader.get_last_entry_side() if scene_loader.has_method("get_last_entry_side") else WorldAPI.EntrySide.LEFT
		if not _initial_map_loaded:
			spawn_x = PLAYER_SPAWN_X
		else:
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
		# 玩家也注入 ConstructionManager（按E搬运/建造交互需要）
		if player.has_method("set_construction_manager") and _construction_api != null:
			player.set_construction_manager(_construction_api)
		# 玩家注入 FormationSystem（编队职责查询）
		if player.has_method("set_formation_system") and _formation_system != null:
			player.set_formation_system(_formation_system)
		# 让 CameraRig 跟随玩家
		if camera_rig != null and camera_rig.has_method("set_follow_target"):
			camera_rig.set_follow_target(player)
		# 进入即对准玩家（水平居中；1/4 跟随机制下不 snap 会在触发线偏移）
		if camera_rig != null and camera_rig.has_method("snap_to_follow_target"):
			camera_rig.snap_to_follow_target()
		# 仅初始加载时 spawn 初始建筑、NPC 和演示建造
		if not _initial_map_loaded:
			_initial_map_loaded = true
			_worldgen.spawn_initial_buildings(map)
			# 预置村庄仓库（搬运系统取货点，放在出生点右侧土路区）
			_worldgen.spawn_initial_warehouse()
			# 阶段 F：村庄土路区（出生点±40格）+ 程序化生成自然资源点（土路外，含负坐标侧）
			var spawn_cell: int = int(PLAYER_SPAWN_X / 32.0)
			var safe_radius: int = 40  # 出生点±40格内为村庄土路区
			if map.has_method("set_dirt_road_range"):
				map.set_dirt_road_range(spawn_cell - safe_radius, spawn_cell + safe_radius)
			if map.has_method("generate_resource_nodes"):
				var map_left_cell: int = int(float(map.get("map_left")) / 32.0) if "map_left" in map else 0
				var map_right_cell: int = int(float(map.get("map_right")) / 32.0) if "map_right" in map else 256
				# 全地图生成，generate_resource_nodes 内部会跳过土路 cell，保证硬化路面不长资源
				map.generate_resource_nodes(map_left_cell, map_right_cell, 0.65)
			# 重新设置相机/小地图边界（土路可能向负坐标扩展了 map_left）
			if camera_rig != null and camera_rig.has_method("set_map_bounds"):
				camera_rig.set_map_bounds(map.map_left, map.map_right)
			if _minimap != null and _minimap.has_method("set_map_info"):
				_minimap.set_map_info(map.map_left, map.map_right, map.ground_y, map.ground_ratio)
			_worldgen.spawn_npcs(map, spawn_y)
		# 跨图携带：spawn 随行编队成员并重建编队（带队出征）
		var followers: Array = _spawn_travel_followers(map, player, spawn_y)
		# 阶段 E：遭遇战战场 spawn 敌方火柴人 + 启动战斗（地图切换进入战场时触发）
		if map_id == BATTLEFIELD_MAP_ID and _initial_map_loaded:
			var allies: Array = [player]
			allies.append_array(followers)
			_worldgen.spawn_battlefield_enemies(map, allies, dev_enemy_count)
	# 切到 EXPLORE 模式激活 handler（此时实体已就绪，不会触发"未找到可附身实体"警告）
	if input_dispatcher and input_dispatcher.has_method("set_mode"):
		input_dispatcher.set_mode(PlayerControlAPI.Mode.EXPLORE)
	# 注册调试绘制器
	_bootstrap.register_debug_drawers()
	# 世界就绪：淡出加载覆盖（玩家已生成、相机已跟随）
	if _world_loading_overlay != null and _world_loading_overlay.has_method("hide_loading"):
		_world_loading_overlay.hide_loading()


## 请求地图旅行（由 ChunkTrigger 调用，详见 §6.2 步行流程）
func request_map_travel(target_map_id: String, entry_side: int) -> void:
	if scene_loader == null or not scene_loader.has_method("travel_to_map"):
		return
	scene_loader.travel_to_map(target_map_id, WorldAPI.TravelMode.WALK, entry_side)


## 主动按指定 cell_x 触发建造（供调试 / 集成测试调用）。
## 返回 {ok, project_id, cell_x, width} 或 {ok:false, error}。
func start_demo_building_at(cell_x: int) -> Dictionary:
	if _construction_api == null or not _construction_api.has_method("start_construction_at"):
		return {"ok": false, "error": "建造系统未就绪"}
	# 统一走 api（2026-08 审计收敛：不再直调内部 manager）
	return _construction_api.start_construction_at("test_region", "placeholder", cell_x)


# ─────────────────────────────── 存档转发（实现见 SaveHandler 子模块）────────────────────────────────

## 外部调用：启动读档流程
func load_game_from_slot(slot_index: int) -> void:
	if _save_system != null and _save_system.has_method("load_game_from_slot"):
		_save_system.load_game_from_slot(slot_index)


## 切换存档面板可见性
func toggle_save_panel() -> void:
	if _save_system != null and _save_system.has_method("toggle_save_panel"):
		_save_system.toggle_save_panel()


## 快速保存到槽位 0
func quick_save() -> void:
	if _save_system != null and _save_system.has_method("quick_save"):
		_save_system.quick_save()


## 快速读取槽位 0
func quick_load() -> void:
	if _save_system != null and _save_system.has_method("quick_load"):
		_save_system.quick_load()


# ─────────────────────────────── 玩家实体查找（实现见 TravelHandler 子模块）────────────────────────────────

## 获取当前玩家实体（公开接口，供 HUD 等 UI 调用）
func get_player_entity() -> Node2D:
	if _travel_system != null and _travel_system.has_method("find_player_entity"):
		return _travel_system.find_player_entity()
	return null


# ─────────────────────────────── 校验与事件绑定 ────────────────────────────────

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
	# 注：interior_exited / mega_interior_entered / mega_interior_exited 由 TravelHandler 绑定，
	#     game_saving / game_loaded 由 SaveHandler 绑定
	#     （ui_toggle_pause_requested 死连接已删：暂停走设置面板速度按钮，2026-08 审计）

# ─────────────────────────────── 公共 API ────────────────────────────────

## 启动新游戏：加载初始村落地图。
func start_new_game(initial_map_id: String) -> void:
	if scene_loader and scene_loader.has_method("load_map"):
		scene_loader.load_map(initial_map_id)


## 获取当前地图实例（可能为空）。
## 优先用 SceneLoader.current_map（唯一可靠来源）；world_chunk_host 第一个
## 子节点在旧图 queue_free 延迟销毁期间可能仍是旧图，仅作兜底。
func get_current_map() -> Node2D:
	if scene_loader != null and scene_loader.has_method("get_current_map"):
		var m: Node2D = scene_loader.get_current_map()
		if m != null and is_instance_valid(m):
			return m
	if world_chunk_host and world_chunk_host.get_child_count() > 0:
		return world_chunk_host.get_child(0) as Node2D
	return null


## 当前是否处于战斗中
func is_in_battle() -> bool:
	if battle_director and battle_director.has_method("has_active_battle"):
		return battle_director.has_active_battle()
	return false


# ─────────────────────────────── 快捷键 ────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	var ek: InputEventKey = event as InputEventKey
	# F5 快速保存到槽位 0
	if ek.keycode == KEY_F5:
		quick_save()
		get_viewport().set_input_as_handled()
	# F9 快速读取槽位 0
	elif ek.keycode == KEY_F9:
		quick_load()
		get_viewport().set_input_as_handled()
	# Ctrl+S 打开/关闭存档面板
	elif ek.keycode == KEY_S and (ek.ctrl_pressed or ek.meta_pressed):
		toggle_save_panel()
		get_viewport().set_input_as_handled()
	# 帝国功能界面快捷键（K/O/J/L → 空面板占位；系统落地后替换真实面板）
	elif ek.keycode == KEY_K:
		_open_placeholder_panel("tech_tree")
		get_viewport().set_input_as_handled()
	elif ek.keycode == KEY_O:
		_open_placeholder_panel("empire_overview")
		get_viewport().set_input_as_handled()
	elif ek.keycode == KEY_J:
		_open_placeholder_panel("collection")
		get_viewport().set_input_as_handled()
	elif ek.keycode == KEY_L:
		_open_placeholder_panel("logistics")
		get_viewport().set_input_as_handled()
	# ESC：统一模态/暂停菜单栈控制（见 _handle_escape）
	elif ek.keycode == KEY_ESCAPE:
		if _handle_escape():
			get_viewport().set_input_as_handled()


## 打开帝国功能空面板（经 ui_placeholder 模块，系统落地后替换真实面板）。
## 快捷键（K/O/J/L）与暂停菜单「帝国功能」共用此入口。
func _open_placeholder_panel(preset_id: String) -> void:
	if ui_root == null:
		return
	var overlay: Control = ui_root.get_slot("ModalOverlay")
	if overlay == null:
		return
	UIPlaceholderPanel.open_panel(overlay, preset_id)


## ESC 语义（统一模态栈逐层退栈）：有模态 → 退栈顶（设置→关设置、确认框→取消、
## 占位面板→关面板，逐层返回）；无模态 → 开暂停菜单。附身模式返回 false
## （ESC 留给退出附身，不消费）。返回是否已消费事件。
func _handle_escape() -> bool:
	if input_dispatcher != null and input_dispatcher.get_mode() == PlayerControlAPI.Mode.POSSESS:
		return false
	var stack := _get_modal_stack()
	if stack != null and stack.handle_escape():
		return true
	# 无模态 → 开暂停菜单
	if _pause_menu_panel != null:
		if stack != null:
			stack.push(_pause_menu_panel, UIModalStack.Layer.PAUSE_MENU)
		else:
			_pause_menu_panel.open()
	return true


## 取 UIRoot 统一模态栈（无则 null）
func _get_modal_stack() -> UIModalStack:
	if ui_root == null:
		return null
	return ui_root.get_modal_stack()
