extends Node
## GameRoot 系统装配器 —— 负责实例化并装配所有常驻子系统。
##
## 职责：
## - UI 覆盖层 / 调试覆盖层装配
## - 建造 / 战斗 / 资源 / 框选 / 组织 / 编队 / 战术系统装配
## - 战斗 UI / 小地图 / 缩放条 / 附身 UI 装配
## - 阶段 F 边界检测 / 大世界地图装配
## - 游玩 UI（主控圆圈 / 悬停方框 / 中键图标）装配
## - 阶段 E 资源条 / 建造菜单装配
## - 调试绘制器注册
##
## 由 GameRoot._ready 挂载为 SystemSetup 子节点并调用 setup(root)。
## 只做装配，不做业务逻辑；业务逻辑保持在 GameRoot 主脚本与各子系统内。

const _ExploreHandlerScript: GDScript = preload("res://modules/player_control/scripts/explore_handler.gd")
const _DebugDrawers: GDScript = preload("res://modules/debug_GUI/scripts/debug_drawers.gd")
const _ConstructionManagerScript: GDScript = preload("res://modules/construction/scripts/construction_manager.gd")
const _ConstructionApiScript: GDScript = preload("res://modules/construction/api.gd")
const _BattleDirectorScript: GDScript = preload("res://modules/combat/scripts/battle/battle_director.gd")
const _CombatApiScript: GDScript = preload("res://modules/combat/api.gd")
const _SelectionSystemScript: GDScript = preload("res://modules/combat/scripts/command/selection_system.gd")
const _FormationSystemScript: GDScript = preload("res://modules/combat/scripts/command/formation_system.gd")
const _OrganizationManagerScript: GDScript = preload("res://modules/organization/scripts/organization_manager.gd")
const _OrganizationApiScript: GDScript = preload("res://modules/organization/api.gd")
const _TacticalOrdersScript: GDScript = preload("res://modules/combat/scripts/command/tactical_orders.gd")
const _CommandChainScript: GDScript = preload("res://modules/combat/scripts/command/command_chain.gd")
const _BattlePanelScript: GDScript = preload("res://modules/combat/ui/battle_panel.gd")
const _FormationPanelScript: GDScript = preload("res://modules/combat/ui/formation_panel.gd")
const _SettingsMenuPanelScript: GDScript = preload("res://modules/ui_global/scripts/panels/settings_menu_panel.gd")
const _MinimapScript: GDScript = preload("res://modules/ui_global/scripts/hud/minimap.gd")
const _ZoomBarScript: GDScript = preload("res://modules/ui_global/scripts/hud/zoom_bar.gd")
const _PossessionInterfaceScript: GDScript = preload("res://modules/player_control/scripts/possession_interface.gd")
const _PossessPanelScript: GDScript = preload("res://modules/player_control/ui/possess_panel.gd")
const _ResourcesManagerScript: GDScript = preload("res://modules/resources/scripts/resource_manager.gd")
const _ResourcesApiScript: GDScript = preload("res://modules/resources/api.gd")
const _MapBoundaryDetectorScript: GDScript = preload("res://modules/world/scripts/travel/map_boundary_detector.gd")
const _StrategicMapScene: PackedScene = preload("res://modules/world_map/scenes/strategic_map.tscn")
const _StrategicMapL3Scene: PackedScene = preload("res://modules/world_map/scenes/strategic_map_l3.tscn")
const _PossessionIndicatorScript: GDScript = preload("res://modules/ui_global/scripts/indicators/possession_indicator.gd")
const _HoverIndicatorScript: GDScript = preload("res://modules/ui_global/scripts/indicators/hover_indicator.gd")
const _MiddleScrollOverlayScript: GDScript = preload("res://modules/ui_global/scripts/indicators/middle_scroll_overlay.gd")
const _ResourceBarScript: GDScript = preload("res://modules/ui_global/scripts/hud/resource_bar.gd")
const _BuildMenuScript: GDScript = preload("res://modules/construction/ui/build_menu.gd")
const _UIRootScene: PackedScene = preload("res://modules/ui_global/scenes/ui_root.tscn")
const _DebugOverlayScene: PackedScene = preload("res://modules/debug_GUI/scenes/debug_overlay.tscn")

var _root: GameRoot


func setup(root: GameRoot) -> void:
	_root = root
	_setup_ui_root()
	_setup_debug_overlay()
	_setup_construction_system()
	_setup_combat_system()
	_setup_resources_system()
	_setup_selection_system()
	_setup_organization_system()
	_setup_formation_system()
	_setup_tactical_system()
	_setup_battle_panel()
	_setup_formation_panel()
	_setup_settings_menu_panel()
	_setup_minimap()
	_setup_zoom_bar()
	_setup_possession_interface()
	_setup_possess_panel()
	_register_explore_handler()
	_setup_boundary_detector()
	_setup_game_ui()
	_setup_resource_bar()
	_setup_build_menu()


# ─────────────────────────────── UI / Debug 覆盖层装配 ────────────────────────────────

## 实例化 UIRoot 场景并挂为子节点。
## UI 覆盖层从 UI 模块自包含场景加载，不再内嵌于 game_root.tscn。
func _setup_ui_root() -> void:
	if _root.ui_root != null:
		return  # 场景中已存在（兼容旧场景）
	var ur: CanvasLayer = _UIRootScene.instantiate()
	ur.name = "UIRoot"
	_root.add_child(ur)
	_root.ui_root = ur
	# 注入依赖（不自行向上遍历查找）：InputDispatcher 切换时同步面板
	if ur.has_method("setup"):
		ur.setup(_root.input_dispatcher)
	# GlobalHUD 注入 CameraRig / GameRoot（居中/脱困/编制/设置按钮）
	var hud: Control = ur.get_node_or_null(UIAPI.PATH_GLOBAL_HUD)
	if hud != null and hud.has_method("setup"):
		hud.setup(_root.camera_rig, _root)


## 实例化 DebugOverlay 场景并挂为子节点。
## 调试覆盖层从 debug_GUI 模块自包含场景加载，不再内嵌于 game_root.tscn。
func _setup_debug_overlay() -> void:
	if _root.get_node_or_null("DebugOverlay") != null:
		return  # 已存在，避免重复添加
	var dop: CanvasLayer = _DebugOverlayScene.instantiate()
	_root.add_child(dop)


# ─────────────────────────────── 建造系统装配 ────────────────────────────────

## 实例化 ConstructionManager + api.gd 作为子节点，并互相 setup。
## 详见 §15 阶段 0.4。
func _setup_construction_system() -> void:
	# 实例化 ConstructionManager
	var mgr := Node.new()
	mgr.set_script(_ConstructionManagerScript)
	mgr.name = "ConstructionManager"
	_root.add_child(mgr)
	_root._construction_manager = mgr
	# 实例化 api.gd（公共接口契约）
	var api := Node.new()
	api.set_script(_ConstructionApiScript)
	api.name = "ConstructionApi"
	_root.add_child(api)
	_root._construction_api = api
	# api.setup 必须在 manager._ready 后调用（_ready 中初始化 _assigner）
	# 这里用 call_deferred 保证顺序
	call_deferred("_setup_construction_api_deferred")


func _setup_construction_api_deferred() -> void:
	if _root._construction_api == null or _root._construction_manager == null:
		return
	if not _root._construction_api.has_method("setup"):
		return
	_root._construction_api.setup(_root._construction_manager)


# ─────────────────────────────── 战斗系统装配 ────────────────────────────────

## 给场景中的 BattleDirector 节点挂脚本，并实例化 CombatApi。
## 详见 §15 阶段 0.5。
func _setup_combat_system() -> void:
	# 给场景中已存在的 BattleDirector 节点挂脚本（§8.1）
	if _root.battle_director != null:
		_root.battle_director.set_script(_BattleDirectorScript)
	# 实例化 CombatApi（公共接口契约）
	var api := Node.new()
	api.set_script(_CombatApiScript)
	api.name = "CombatApi"
	_root.add_child(api)
	_root._combat_api = api
	# api.setup 必须在 battle_director 脚本挂载后调用
	call_deferred("_setup_combat_api_deferred")


func _setup_combat_api_deferred() -> void:
	if _root._combat_api == null or _root.battle_director == null:
		return
	if not _root._combat_api.has_method("setup"):
		return
	_root._combat_api.setup(_root.battle_director)
	if _root._formation_system != null and _root._combat_api.has_method("setup_formation_system"):
		_root._combat_api.setup_formation_system(_root._formation_system)


# ─────────────────────────────── 资源系统装配（P0-9）────────────────────────────────

## 实例化 ResourcesApi 作为子节点，并注入 ResourceManager。
func _setup_resources_system() -> void:
	var api := Node.new()
	api.set_script(_ResourcesApiScript)
	api.name = "ResourcesApi"
	_root.add_child(api)
	_root._resources_api = api
	call_deferred("_setup_resources_api_deferred")


func _setup_resources_api_deferred() -> void:
	if _root._resources_api == null:
		return
	if not _root._resources_api.has_method("setup"):
		return
	var mgr = _ResourcesManagerScript.new()
	_root._resources_api.setup(mgr)
	# P0-9 注入到 ConstructionManager（若已就绪）
	if _root._construction_manager != null and _root._construction_manager.has_method("set_resources_api"):
		_root._construction_manager.set_resources_api(_root._resources_api)
	# 阶段 E：给玩家初始资源（P0 简化，资源不持久化，每次启动重置）
	# produce 到 "test_region"（与建造扣减 region 一致），资源条显示全局总量
	_grant_initial_resources()


## P0 初始资源：木材 300 / 石料 300 / 铁矿 100（足够建造兵营 + 几段城墙）
func _grant_initial_resources() -> void:
	if _root._resources_api == null or not _root._resources_api.has_method("produce"):
		return
	var initial: Dictionary = {
		"res_wood": 300.0,
		"res_stone": 300.0,
		"res_metal_ore": 100.0,
	}
	for res_id in initial.keys():
		_root._resources_api.produce(res_id, initial[res_id], "test_region", "初始资源")
	print("[GameRoot] 初始资源已发放: %s" % str(initial))


# ─────────────────────────────── 框选系统装配 ────────────────────────────────

## 实例化 SelectionSystem，挂到 UIRoot 下，注册为 BATTLE 模式 handler。
## 详见 §15 阶段 0.6。
func _setup_selection_system() -> void:
	if _root.ui_root == null:
		push_warning("[GameRoot] UIRoot 为空，跳过框选系统装配")
		return
	var sel := Control.new()
	sel.set_script(_SelectionSystemScript)
	sel.name = "SelectionSystem"
	_root.ui_root.add_child(sel)
	_root._selection_system = sel
	# 注册为 BATTLE 模式 handler
	if _root.input_dispatcher != null and _root.input_dispatcher.has_method("register_handler"):
		_root.input_dispatcher.register_handler(PlayerControlAPI.Mode.BATTLE, sel)


# ─────────────────────────────── 组织系统装配 ────────────────────────────────

## 实例化 OrganizationManager + OrganizationApi 作为子节点并互相 setup。
func _setup_organization_system() -> void:
	# OrganizationManager 是 RefCounted，直接 new
	var mgr = _OrganizationManagerScript.new()
	# OrganizationApi 是 Node，挂为子节点
	var api := Node.new()
	api.set_script(_OrganizationApiScript)
	api.name = "OrganizationApi"
	_root.add_child(api)
	_root._organization_api = api
	# api.setup 需要 manager 引用
	if api.has_method("setup"):
		api.setup(mgr)


# ─────────────────────────────── 编队系统装配 ────────────────────────────────

## 实例化 FormationSystem，注入 OrganizationApi 引用。
func _setup_formation_system() -> void:
	var fs := Node.new()
	fs.set_script(_FormationSystemScript)
	fs.name = "FormationSystem"
	_root.add_child(fs)
	_root._formation_system = fs
	if _root._organization_api != null and fs.has_method("setup"):
		fs.setup(_root._organization_api)


# ─────────────────────────────── 战术号令系统装配 ────────────────────────────────

## 实例化 CommandChain + TacticalOrders，注入 FormationSystem 引用。
func _setup_tactical_system() -> void:
	# CommandChain
	var cc := Node.new()
	cc.set_script(_CommandChainScript)
	cc.name = "CommandChain"
	_root.add_child(cc)
	_root._command_chain = cc
	# TacticalOrders
	var to := Node.new()
	to.set_script(_TacticalOrdersScript)
	to.name = "TacticalOrders"
	_root.add_child(to)
	_root._tactical_orders = to
	if to.has_method("setup"):
		to.setup(_root._formation_system, _root._command_chain)


# ─────────────────────────────── 战斗 UI 装配（§15 阶段 0.6）────────────────────────────────

## 给场景中已存在的 BattlePanel 占位节点挂脚本，并注入系统引用。详见 §10.1。
func _setup_battle_panel() -> void:
	if _root.ui_root == null:
		return
	var mp: Control = _root.ui_root.get_node_or_null("ModePanel")
	if mp == null:
		return
	var bp: Control = mp.get_node_or_null("BattlePanel")
	if bp == null:
		return
	bp.set_script(_BattlePanelScript)
	_root._battle_panel = bp
	call_deferred("_setup_battle_panel_deferred")


func _setup_battle_panel_deferred() -> void:
	if _root._battle_panel == null:
		return
	if _root._battle_panel.has_method("setup"):
		_root._battle_panel.setup(_root)


# ─────────────────────────────── 编制管理窗口装配 ────────────────────────────────

## 实例化 FormationPanel 并挂到 UIRoot.ModalOverlay（模态面板，open/close 控制可见性）。
func _setup_formation_panel() -> void:
	if _root.ui_root == null:
		return
	var overlay: Control = _root.ui_root.get_node_or_null(UIAPI.PATH_MODAL_OVERLAY)
	if overlay == null:
		return
	var fp := Control.new()
	fp.set_script(_FormationPanelScript)
	fp.name = "FormationPanel"
	overlay.add_child(fp)
	_root._formation_panel = fp
	call_deferred("_setup_formation_panel_deferred")


func _setup_formation_panel_deferred() -> void:
	if _root._formation_panel == null:
		return
	if _root._formation_panel.has_method("setup"):
		_root._formation_panel.setup(_root)


# ─────────────────────────────── 设置菜单装配（齿轮/ESC 打开）────────────────────────────────

## 实例化 SettingsMenuPanel 并挂到 UIRoot.ModalOverlay（Control 容器，
## anchors 布局可靠——直接挂 CanvasLayer 下 anchors 不生效会堆左上角）。
func _setup_settings_menu_panel() -> void:
	if _root.ui_root == null:
		return
	var overlay: Control = _root.ui_root.get_node_or_null(UIAPI.PATH_MODAL_OVERLAY)
	if overlay == null:
		return
	var sp := Control.new()
	sp.set_script(_SettingsMenuPanelScript)
	sp.name = "SettingsMenuPanel"
	overlay.add_child(sp)
	_root._settings_menu_panel = sp
	call_deferred("_setup_settings_menu_panel_deferred")


func _setup_settings_menu_panel_deferred() -> void:
	if _root._settings_menu_panel == null:
		return
	if _root._settings_menu_panel.has_method("setup"):
		_root._settings_menu_panel.setup(_root)


# ─────────────────────────────── 小地图装配（§15 阶段 0.6）────────────────────────────────

## 创建 Minimap 并挂到 UIRoot。详见 §10.4。
func _setup_minimap() -> void:
	if _root.ui_root == null:
		return
	var mm := Control.new()
	mm.set_script(_MinimapScript)
	mm.name = "Minimap"
	_root.ui_root.add_child(mm)
	_root._minimap = mm
	if mm.has_method("setup"):
		mm.setup(_root)


## 创建 ZoomBar 并挂到 UIRoot，位于小地图下方。
func _setup_zoom_bar() -> void:
	if _root.ui_root == null:
		return
	var zb := Control.new()
	zb.set_script(_ZoomBarScript)
	zb.name = "ZoomBar"
	_root.ui_root.add_child(zb)
	_root._zoom_bar = zb
	if zb.has_method("setup"):
		zb.setup(_root.camera_rig)


# ─────────────────────────────── 附身系统装配（§15 阶段 0.7）────────────────────────────────

## 实例化 PossessionInterface，注册为 POSSESS 模式 handler。
func _setup_possession_interface() -> void:
	var pi := Node.new()
	pi.set_script(_PossessionInterfaceScript)
	pi.name = "PossessionInterface"
	_root.add_child(pi)
	_root._possession_interface = pi
	# 注册为 POSSESS handler
	if _root.input_dispatcher != null and _root.input_dispatcher.has_method("register_handler"):
		_root.input_dispatcher.register_handler(PlayerControlAPI.Mode.POSSESS, pi)


## 给场景中已存在的 PossessPanel 占位节点挂脚本，并调用 setup。
func _setup_possess_panel() -> void:
	if _root.ui_root == null:
		return
	var mp: Control = _root.ui_root.get_node_or_null("ModePanel")
	if mp == null:
		return
	var pp: Control = mp.get_node_or_null("PossessPanel")
	if pp == null:
		return
	pp.set_script(_PossessPanelScript)
	_root._possess_panel = pp
	call_deferred("_setup_possess_panel_deferred")


func _setup_possess_panel_deferred() -> void:
	if _root._possess_panel == null:
		return
	if _root._possess_panel.has_method("setup"):
		_root._possess_panel.setup(_root)


## 注册 EXPLORE 模式 handler（不立即激活，等地图加载完再 set_mode）。
func _register_explore_handler() -> void:
	if _root.input_dispatcher == null or not _root.input_dispatcher.has_method("register_handler"):
		return
	var handler := Node.new()
	handler.set_script(_ExploreHandlerScript)
	handler.name = "ExploreHandler"
	_root.add_child(handler)
	_root.input_dispatcher.register_handler(PlayerControlAPI.Mode.EXPLORE, handler)


# ─────────────────────────────── 阶段 F：边界检测出城系统 ────────────────────────────────

func _setup_boundary_detector() -> void:
	# 实例化边界检测器
	_root._boundary_detector = Node.new()
	_root._boundary_detector.set_script(_MapBoundaryDetectorScript)
	_root._boundary_detector.name = "MapBoundaryDetector"
	_root.add_child(_root._boundary_detector)
	# 实例化战略图（CanvasLayer 独立渲染层，全屏覆盖；Content 初始隐藏）
	_root._strategic_map = _StrategicMapScene.instantiate()
	_root._strategic_map.name = "StrategicMap"
	_root.add_child(_root._strategic_map)
	# 初始化 L1 世界数据（Api 在 Content 子节点下）
	var content: Node = _root._strategic_map.get_node_or_null("Content")
	var api: Node = content.get_node_or_null("Api") if content != null else null
	if api != null and api.has_method("initialize"):
		api.initialize(
			"res://config/strategic_map/l1_world.json",
			"res://config/strategic_map"
		)
	# 连接边界检测器 -> 打开战略图
	_root._boundary_detector.open_world_map_requested.connect(_open_strategic_map)
	# 战略图关闭 -> 恢复场景图输入（api.close_strategic_map / ESC 都发此信号）
	if EventBus != null:
		EventBus.strategic_map_closed.connect(_on_strategic_map_closed)
	# M 键 -> L3 大世界战略图（与 Tab 的 L1 地图独立）
	_setup_l3_strategic_map()


## 装配 L3 大世界战略图（M 键视图）
func _setup_l3_strategic_map() -> void:
	_root._strategic_map_l3 = _StrategicMapL3Scene.instantiate()
	_root._strategic_map_l3.name = "StrategicMapL3"
	_root.add_child(_root._strategic_map_l3)
	# 初始化 L3 数据（渲染器持有）
	var content: Node = _root._strategic_map_l3.get_node_or_null("Content")
	var renderer: Node = content.get_node_or_null("L3MapRenderer") if content != null else null
	if renderer != null and renderer.has_method("set_data"):
		var data := L3WorldData.load_from(
			"res://config/strategic_map/l3_world.json",
			"res://config/strategic_map"
		)
		renderer.set_data(data)


## M 键全局监听（打开/关闭 L3 大世界战略图）
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_M:
		_toggle_l3_strategic_map()
		get_viewport().set_input_as_handled()


func _toggle_l3_strategic_map() -> void:
	if _root._strategic_map_l3 == null:
		return
	var content: Node = _root._strategic_map_l3.get_node_or_null("Content")
	if content == null or not content.has_method("open"):
		return
	if content.visible:
		content.close()
		_pause_scene_input(false)
	else:
		# 打开 L3 前先关掉 L1（互斥）
		var l1_content: Node = _root._strategic_map.get_node_or_null("Content") if _root._strategic_map != null else null
		if l1_content != null and l1_content.visible and l1_content.has_method("close"):
			l1_content.close()
		content.open()
		_pause_scene_input(true)


func _open_strategic_map() -> void:
	if _root._strategic_map == null:
		return
	# 战略图是 CanvasLayer，控制器在 Content 子节点（visible 控制全层显隐）
	var content: Node = _root._strategic_map.get_node_or_null("Content")
	if content != null and content.has_method("open"):
		content.open()
		_pause_scene_input(true)


func _on_strategic_map_closed() -> void:
	_pause_scene_input(false)


## 暂停/恢复场景图输入（战略图打开时场景图不响应输入）
## 方式：地图内容（WorldChunkHost）+ 相机置为 DISABLED（子树 _input/_process 全停），
## 场景图仍保持渲染（战略图透明背景悬浮其上，作背景可见）；
## 战略图（CanvasLayer 100）/UIRoot 不受影响；关闭时恢复 INHERIT
func _pause_scene_input(paused: bool) -> void:
	var mode := Node.PROCESS_MODE_INHERIT if not paused else Node.PROCESS_MODE_DISABLED
	if _root.world_chunk_host != null:
		_root.world_chunk_host.process_mode = mode
	if _root.camera_rig != null:
		_root.camera_rig.process_mode = mode
	if _root.scene_loader != null:
		_root.scene_loader.process_mode = mode


func _on_world_map_travel(target_map_id: String, entry_side: int) -> void:
	if _root.scene_loader != null and _root.scene_loader.has_method("travel_to_map"):
		_root.scene_loader.travel_to_map(target_map_id, WorldAPI.TravelMode.WALK, entry_side)


# ─────────────────────────────── 游玩 UI ────────────────────────────────

func _setup_game_ui() -> void:
	# 主控单位圆圈
	_root._possession_indicator = Control.new()
	_root._possession_indicator.set_script(_PossessionIndicatorScript)
	_root._possession_indicator.name = "PossessionIndicator"
	_root._possession_indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _root._possession_indicator.has_method("setup"):
		_root._possession_indicator.setup(_root.camera_rig, _root)
	if _root.ui_root != null:
		_root.ui_root.add_child(_root._possession_indicator)
	else:
		_root.add_child(_root._possession_indicator)
	# 鼠标悬停方框
	_root._hover_indicator = Control.new()
	_root._hover_indicator.set_script(_HoverIndicatorScript)
	_root._hover_indicator.name = "HoverIndicator"
	_root._hover_indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _root._hover_indicator.has_method("setup"):
		_root._hover_indicator.setup(_root.camera_rig, _root)
	if _root.ui_root != null:
		_root.ui_root.add_child(_root._hover_indicator)
	else:
		_root.add_child(_root._hover_indicator)
	# 中键滚动图标
	_root._middle_scroll_overlay = Control.new()
	_root._middle_scroll_overlay.set_script(_MiddleScrollOverlayScript)
	_root._middle_scroll_overlay.name = "MiddleScrollOverlay"
	_root._middle_scroll_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _root._middle_scroll_overlay.has_method("setup"):
		_root._middle_scroll_overlay.setup(_root.camera_rig)
	if _root.ui_root != null:
		_root.ui_root.add_child(_root._middle_scroll_overlay)
	else:
		_root.add_child(_root._middle_scroll_overlay)


# ─────────────────────────────── 阶段 E：资源条 / 建造菜单装配 ────────────────────────────────

## 实例化资源条并挂到 UIRoot，延迟 setup 等 ResourcesApi 就绪。
func _setup_resource_bar() -> void:
	# 优先从 ui_root.tscn 预置节点挂载（编辑器可见位置/范围）
	if _root.ui_root != null:
		var rb: Control = _root.ui_root.get_node_or_null("ResourceBar")
		if rb != null:
			rb.set_script(_ResourceBarScript)
			_root._resource_bar = rb
			call_deferred("_setup_resource_bar_deferred")
			return
	# 回退：代码创建
	_root._resource_bar = Control.new()
	_root._resource_bar.set_script(_ResourceBarScript)
	_root._resource_bar.name = "ResourceBar"
	_root._resource_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _root.ui_root != null:
		_root.ui_root.add_child(_root._resource_bar)
	else:
		_root.add_child(_root._resource_bar)
	call_deferred("_setup_resource_bar_deferred")


func _setup_resource_bar_deferred() -> void:
	if _root._resource_bar == null or _root._resources_api == null:
		return
	if _root._resource_bar.has_method("setup"):
		_root._resource_bar.setup(_root._resources_api)


## 实例化建造菜单并挂到 UIRoot，延迟 setup 等 ConstructionManager 就绪。
func _setup_build_menu() -> void:
	# 优先从 ui_root.tscn 预置节点挂载（编辑器可见位置/范围）
	if _root.ui_root != null:
		var bm: Control = _root.ui_root.get_node_or_null("BuildMenu")
		if bm != null:
			bm.set_script(_BuildMenuScript)
			_root._build_menu = bm
			call_deferred("_setup_build_menu_deferred")
			return
	# 回退：代码创建
	_root._build_menu = Control.new()
	_root._build_menu.set_script(_BuildMenuScript)
	_root._build_menu.name = "BuildMenu"
	if _root.ui_root != null:
		_root.ui_root.add_child(_root._build_menu)
	else:
		_root.add_child(_root._build_menu)
	call_deferred("_setup_build_menu_deferred")


func _setup_build_menu_deferred() -> void:
	if _root._build_menu == null:
		return
	if _root._build_menu.has_method("setup"):
		_root._build_menu.setup(_root)


# ─────────────────────────────── 调试绘制器注册 ────────────────────────────────

## 注册调试绘制器到 DebugApi（详见 §10.5.7）
func register_debug_drawers() -> void:
	if DebugApi == null:
		return
	DebugApi.register_drawer("grid_drawer", Callable(_DebugDrawers, "draw_grid"))
	DebugApi.register_drawer("barrier_drawer", Callable(_DebugDrawers, "draw_barriers"))
	DebugApi.register_drawer("building_drawer", Callable(_DebugDrawers, "draw_buildings"))
	DebugApi.register_drawer("ground_line_drawer", Callable(_DebugDrawers, "draw_ground_lines"))
	DebugApi.register_drawer("chunk_trigger_drawer", Callable(_DebugDrawers, "draw_chunk_triggers"))
	DebugApi.register_drawer("entity_state_drawer", Callable(_DebugDrawers, "draw_entity_states"))
	DebugApi.register_drawer("entity_collider_drawer", Callable(_DebugDrawers, "draw_entity_colliders"))
	DebugApi.register_drawer("terrain_grid", Callable(_DebugDrawers, "draw_terrain_grid"))
	DebugApi.register_drawer("resource_nodes", Callable(_DebugDrawers, "draw_resource_nodes"))
	DebugApi.register_drawer("building_names", Callable(_DebugDrawers, "draw_building_names"))
	DebugApi.register_drawer("world_ruler", Callable(_DebugDrawers, "draw_world_ruler"))
	DebugApi.register_drawer("entity_info", Callable(_DebugDrawers, "draw_entity_info"))
