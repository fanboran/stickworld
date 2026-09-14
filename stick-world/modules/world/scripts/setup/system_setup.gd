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
const _DebugDrawers: GDScript = preload("res://modules/debug_gui/scripts/debug_drawers.gd")
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
const _OrgPanelScript: GDScript = preload("res://modules/organization/ui/org_panel.gd")
const _StrategicOverviewPanelScript: GDScript = preload("res://modules/organization/ui/strategic_overview_panel.gd")
const _CommandChainViewScene: PackedScene = preload("res://modules/organization/ui/command_chain_view.tscn")
const _SettingsMenuPanelScript: GDScript = preload("res://modules/ui_global/scripts/panels/settings_menu_panel.gd")
const _PauseMenuPanelScript: GDScript = preload("res://modules/ui_global/scripts/panels/pause_menu_panel.gd")
const _MinimapScript: GDScript = preload("res://modules/ui_global/scripts/hud/minimap.gd")
const _L1ThumbnailScript: GDScript = preload("res://modules/world_map/ui/l1_thumbnail.gd")
const _ZoomBarScript: GDScript = preload("res://modules/ui_global/scripts/hud/zoom_bar.gd")
const _InventoryServiceScript: GDScript = preload("res://modules/inventory/scripts/inventory_service.gd")
const _InventoryScreenScript: GDScript = preload("res://modules/inventory/ui/inventory_screen.gd")
const _StatsScreenScript: GDScript = preload("res://modules/inventory/ui/stats_screen.gd")
const _HotbarScript: GDScript = preload("res://modules/inventory/ui/hotbar.gd")
const _PossessionInterfaceScript: GDScript = preload("res://modules/player_control/scripts/possession_interface.gd")
const _PossessPanelScript: GDScript = preload("res://modules/player_control/ui/possess_panel.gd")
const _ResourcesManagerScript: GDScript = preload("res://modules/resources/scripts/resource_manager.gd")
const _ResourcesApiScript: GDScript = preload("res://modules/resources/api.gd")
const _FxPoolScript: GDScript = preload("res://modules/fx/scripts/fx_pool.gd")
const _MapBoundaryDetectorScript: GDScript = preload("res://modules/world/scripts/travel/map_boundary_detector.gd")
const _StrategicMapScene: PackedScene = preload("res://modules/world_map/scenes/strategic_map.tscn")
const _StrategicMapL3Scene: PackedScene = preload("res://modules/world_map/scenes/strategic_map_l3.tscn")
const _StrategicMapL2Scene: PackedScene = preload("res://modules/world_map/scenes/strategic_map_l2.tscn")
const _HoverIndicatorScript: GDScript = preload("res://modules/ui_global/scripts/indicators/hover_indicator.gd")
const _MiddleScrollOverlayScript: GDScript = preload("res://modules/ui_global/scripts/indicators/middle_scroll_overlay.gd")
const _BuildMenuScript: GDScript = preload("res://modules/construction/ui/build_menu.gd")
const _UIRootScene: PackedScene = preload("res://modules/ui_global/scenes/ui_root.tscn")
const _DebugOverlayScene: PackedScene = preload("res://modules/debug_gui/scenes/debug_overlay.tscn")
const _QuestPanelScript: GDScript = preload("res://modules/ui_global/scripts/hud/quest_panel.gd")
const _DemoQuestScript: GDScript = preload("res://modules/world/scripts/setup/demo_quest.gd")
const _UnitLodDirectorScript: GDScript = preload("res://modules/units/scripts/entity/unit_lod_director.gd")
const _ExpansionApiScript: GDScript = preload("res://modules/expansion/api.gd")
const _ConquestManagerScript: GDScript = preload("res://modules/expansion/scripts/conquest_manager.gd")
const _RecruitManagerScript: GDScript = preload("res://modules/organization/scripts/recruit_manager.gd")
const _OrgReportNarratorScript: GDScript = preload("res://modules/organization/ui/org_report_narrator.gd")
const _TeamAiHudScene: PackedScene = preload("res://modules/combat/ui/team_ai_hud.tscn")
const _SquadCardScene: PackedScene = preload("res://modules/combat/ui/squad_card.tscn")

var _root: GameRoot

# ─────────────────────────────── Tab 三态（A3） ────────────────────────────────

## Tab 键循环：缩略窗 ↔ L1 大图互切（创始人反馈：Tab 地图默认展开，关闭大图
## 回到缩略窗，缩略窗与 Minimap 同为常驻）。HIDDEN 态保留作兜底，正常流程不可达。
## 顶部小地图区双窗 = Minimap（本城市俯视）+ L1Thumbnail（出生 L1 世界缩略）。
enum TabMapState { HIDDEN, TOP_MINIMAPS, FULL_L1 }

var _tab_state: int = TabMapState.HIDDEN
## L1 世界缩略窗（与 Minimap 并列）
var _l1_thumbnail: Control = null
## L1 班组卡引用（装配层持有，供 OrgPanel 选中联动调用 show_squad/hide_card——
## 不跨模块 get_node；UI-W4b 班组卡触发源补全）
var _squad_card: Control = null


func setup(root: GameRoot) -> void:
	_root = root
	for step in _step_table():
		(step[1] as Callable).call()
	finish_setup()


## 分帧装配入口（启动加载屏用）：绑定 root 并返回步骤表——调用方逐步执行，
## 每步之间让一帧并推进副进度条（原先整段同步 ~2-3s，转圈全程定格）。
## 与 setup() 共用同一张表，顺序与语义完全一致。
func setup_steps(root: GameRoot) -> Array:
	_root = root
	return _step_table()


## 装配收尾（Demo 目标链 deferred：需在资源初始发放之后做基线快照）
func finish_setup() -> void:
	call_deferred("_setup_demo_quest_deferred")


## 装配步骤表：每项 = [细分标签, 可调用]。顺序有依赖（UI 根/核心系统先于
## 依赖它们的面板，LOD 在核心系统之后）。setup() 与 setup_steps() 共用。
func _step_table() -> Array:
	# 激活平衡配置装载：扫描 res://config 下全部 BalanceResource .tres
	# （此前 reload() 零调用者，数据驱动层运行时为空字典，2026-08 审计修复）
	BalanceConfig.reload()
	return [
		["界面根", _setup_ui_root],
		["调试层", _setup_debug_overlay],
		["建造系统", _setup_construction_system],
		["战斗系统", _setup_combat_system],
		["资源系统", _setup_resources_system],
		["选择系统", _setup_selection_system],
		["组织系统", _setup_organization_system],
		["编队系统", _setup_formation_system],
		["战术系统", _setup_tactical_system],
		["指挥传输", _setup_command_transport],
		["征服系统", _setup_conquest_system],
		["招兵系统", _setup_recruit_system],
		["战斗面板", _setup_battle_panel],
		["编队面板", _setup_formation_panel],
		["组织面板", _setup_org_panel],
		["战略总览", _setup_strategic_overview],
		["指挥链视图", _setup_command_chain_view],
		["上报叙事", _setup_org_report_narrator],
		["设置菜单", _setup_settings_menu_panel],
		["暂停菜单", _setup_pause_menu_panel],
		["小地图", _setup_minimap],
		["TeamAi HUD", _setup_team_ai_hud],
		["班组卡", _setup_squad_card],
		["缩放条", _setup_zoom_bar],
		# 战略图初始化从懒加载提前进装配（创始人反馈：Tab 地图默认展开）——
		# 拆成 L1/L3 两步分帧消化 JSON+索引图重载，副进度条如实显示
		["战略图 L1", _setup_l1_strategic_map],
		["战略图 L3", _setup_l3_strategic_map],
		["地图缩略窗", _open_tab_map_default],
		["背包", _setup_inventory],
		["附身界面", _setup_possession_interface],
		["附身面板", _setup_possess_panel],
		["探索交互", _register_explore_handler],
		["边界检测", _setup_boundary_detector],
		["游戏 UI", _setup_game_ui],
		["建造菜单", _setup_build_menu],
		["后处理", _setup_post_process],
		["地图过渡", _setup_map_transition],
		# 单位 LOD 调度（性能优化）：核心系统装配完成后挂载，自动发现模式——
		# 覆盖演练场（battle_arena）/世界村庄/真实战斗全部场景（headless 无相机时空转）
		["单位 LOD", _setup_unit_lod],
	]


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
	# 注入依赖（不自行向上遍历查找）：InputDispatcher 切换时同步面板；
	# 模式→面板映射在本装配层完成（UIRoot 不依赖业务模块枚举，断 ui_global↔player_control 环）
	if ur.has_method("setup"):
		ur.setup(_root.input_dispatcher, _mode_to_panel_type)
	# GlobalHUD 注入 CameraRig / GameRoot（居中/脱困/编制/设置按钮）
	var hud: Control = ur.get_node_or_null(UIAPI.PATH_GLOBAL_HUD)
	if hud != null and hud.has_method("setup"):
		hud.setup(_root.camera_rig, _root)


## 模式 → UI 面板类型映射（UIAPI.PanelType），装配时注入 UIRoot。
func _mode_to_panel_type(mode: int) -> int:
	match mode:
		PlayerControlAPI.Mode.EXPLORE, PlayerControlAPI.Mode.INDOOR, PlayerControlAPI.Mode.BUILD:
			return UIAPI.PanelType.VILLAGE
		PlayerControlAPI.Mode.BATTLE:
			return UIAPI.PanelType.BATTLE
		PlayerControlAPI.Mode.POSSESS:
			return UIAPI.PanelType.POSSESS
		_:
			return UIAPI.PanelType.VILLAGE


## 实例化 DebugOverlay 场景并挂为子节点。
## 调试覆盖层从 debug_gui 模块自包含场景加载，不再内嵌于 game_root.tscn。
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
	# 建造完工 → 音效事件（跨模块经 AudioManager 框架，资产未就位时静默）
	if _root._construction_api.has_signal("building_completed") and AudioManager != null:
		_root._construction_api.building_completed.connect(
				func(_building_id: String, _region_id: String) -> void:
					AudioManager.play_event("build_complete"))
	# 建造完工 → 尘土特效（经 FxPool 组查找，无池环境静默）
	if _root._construction_api.has_signal("building_completed") and _root._construction_manager != null:
		var mgr: Node = _root._construction_manager
		_root._construction_api.building_completed.connect(
				func(building_id: String, _region_id: String) -> void:
					var b: Node = mgr.get_building_node(building_id)
					if b is Node2D:
						FxPool.spawn_burst(b.get_tree(), FxLibrary.BUILD_DUST, (b as Node2D).global_position))


# ─────────────────────────────── 战斗系统装配 ────────────────────────────────

## 给场景中的 BattleDirector 节点挂脚本，并实例化 CombatApi。
## 详见 §15 阶段 0.5。
func _setup_combat_system() -> void:
	# 给场景中已存在的 BattleDirector 节点挂脚本（§8.1）
	if _root.battle_director != null:
		_root.battle_director.set_script(_BattleDirectorScript)
		# 注入地图节点路径（拆 combat→world 硬引用，路径常量真相源仍在 world/api.gd）
		_root.battle_director.battle_anchor_path = NodePath(WorldAPI.PATH_MAP_BATTLE_ANCHOR)
		_root.battle_director.building_host_path = NodePath(WorldAPI.PATH_MAP_BUILDING_HOST)
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
	# 号令委托入口（CombatApi.issue_order → TacticalOrders）
	if _root._tactical_orders != null and _root._combat_api.has_method("set_tactical_orders"):
		_root._combat_api.set_tactical_orders(_root._tactical_orders)
	# 阵营 AI 装配注入（P6 TeamAi：BattleDirector 透传给 BattleInstance.enable_team_ai 消费）
	if _root.battle_director != null:
		if _root._tactical_orders != null and _root.battle_director.has_method("set_tactical_orders"):
			_root.battle_director.set_tactical_orders(_root._tactical_orders)
		if _root._formation_system != null and _root.battle_director.has_method("set_formation_system"):
			_root.battle_director.set_formation_system(_root._formation_system)


# ─────────────────────────────── 资源系统装配（P0-9）────────────────────────────────

## 实例化 ResourcesApi 作为子节点，并注入 ResourceManager。
func _setup_resources_system() -> void:
	var api := Node.new()
	api.set_script(_ResourcesApiScript)
	api.name = "ResourcesApi"
	_root.add_child(api)
	_root._resources_api = api
	# 粒子特效池（PLACEHOLDER 素材，见 fx_library.gd 头注释）
	var fx := Node.new()
	fx.set_script(_FxPoolScript)
	fx.name = "FxPool"
	_root.add_child(fx)
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
	# 资源条并入顶栏（GlobalHUD 中块），不再单独挂 HudOverlay
	_attach_resource_bar_to_hud()


## 把资源条注入 GlobalHUD 顶栏中块（跨模块经 UIRoot 路径，非直接 get_node）
func _attach_resource_bar_to_hud() -> void:
	if _root.ui_root == null:
		return
	var hud := _root.ui_root.get_node_or_null(UIAPI.PATH_GLOBAL_HUD)
	if hud != null and hud.has_method("attach_resources"):
		var rb: Control = hud.attach_resources(_root._resources_api)
		if rb != null:
			_root._resource_bar = rb


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
	print_verbose("[GameRoot] 初始资源已发放: %s" % str(initial))


# ─────────────────────────────── 框选系统装配 ────────────────────────────────

## 实例化 SelectionSystem，挂到 UIRoot 下，注册为 BATTLE 模式 handler。
## 详见 §15 阶段 0.6。
func _setup_selection_system() -> void:
	if _root.ui_root == null:
		push_warning("[GameRoot] UIRoot 为空，跳过框选系统装配")
		return
	# 全屏输入层走 UIKit.full_rect（2026-08 审计收敛，替代 Control.new 自设 anchor）
	var sel := UIKit.full_rect(_SelectionSystemScript, "SelectionSystem")
	_root.ui_root.add_child(sel)
	_root._selection_system = sel
	# 注入 GameRoot（替代 group 反查）
	if sel.has_method("setup"):
		sel.setup(_root)
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
	# 注入 FormationSystem（队内目标点散开依赖；3-F2 接力复用 _execute_delivery 时补挂——
	# 此前装配缺口使 spread 散点静默失效，全队退化为同一点）
	if _root._formation_system != null and cc.has_method("setup_formation"):
		cc.setup_formation(_root._formation_system)
	# TacticalOrders
	var to := Node.new()
	to.set_script(_TacticalOrdersScript)
	to.name = "TacticalOrders"
	_root.add_child(to)
	_root._tactical_orders = to
	if to.has_method("setup"):
		to.setup(_root._formation_system, _root._command_chain, _root._organization_api)


# ─────────────────────────────── 指挥链传输层装配（3-F2）────────────────────────────────

## 传输层三 provider + cmd 属性 provider 注入（架构文档 §4.2.1/§4.3.1）：
## organization 保持零出向依赖——实体坐标/玩家位置/属性查询在此装配（world 侧高视角取值）。
func _setup_command_transport() -> void:
	var api: Node = _root._organization_api
	if api == null or not api.has_method("set_transport_providers"):
		return
	api.set_transport_providers(
		_org_commander_position,
		_player_command_position,
		_region_distance_stub,
	)
	if api.has_method("set_attribute_provider"):
		api.set_attribute_provider(_stickman_cmd_attribute)


## 组织指挥官实体坐标（同图）；无指挥官/实体不在场 → Vector2.INF（走跨图分支，不掺假距离）。
## 中间层指挥官也是真实实体（指挥官不变量：某人实际指挥着下级指挥官），坐标同样可取。
func _org_commander_position(org_id: String) -> Variant:
	var api: Node = _root._organization_api
	if api == null or not api.has_method("get_organization"):
		return Vector2.INF
	var info: Dictionary = api.get_organization(org_id)
	if not info.get("ok", false):
		return Vector2.INF
	var cid := String(info.get("data", {}).get("commander_id", ""))
	if cid.is_empty():
		return Vector2.INF
	var unit: Node = instance_from_id(int(cid))
	if unit == null or not is_instance_valid(unit) or not (unit is Node2D):
		return Vector2.INF
	return (unit as Node2D).global_position


## 玩家位置：附身实体坐标；未附身 = 相机视野中心；全不可得 → Vector2.INF
func _player_command_position() -> Vector2:
	var map: Node = _root.get_current_map() if _root.has_method("get_current_map") else null
	if map != null and map.has_method("get_possessed_entity"):
		var p: Node2D = map.get_possessed_entity()
		if p != null and is_instance_valid(p):
			return p.global_position
	if _root.camera_rig != null:
		return _root.camera_rig.get_screen_center_position()
	return Vector2.INF


## 跨图驻地距离 v1 收口（§4.2.2）：world_map 侧取数接口未立——恒 -1 走 fallback 常数
##（balance var_command_cross_map_distance）；接口落地后换真值（待办已登记）
func _region_distance_stub(_from_loc: String, _to_loc: String) -> float:
	return -1.0


## cmd 属性查询（补位排序，§4.3.1）：instance_id 字符串 → attributes.cmd；失败 -1 沉底
func _stickman_cmd_attribute(stickman_id: String) -> float:
	var iid := int(stickman_id)
	if iid <= 0:
		return -1.0
	var unit: Node = instance_from_id(iid)
	if unit == null or not is_instance_valid(unit):
		return -1.0
	var attrs: Variant = unit.get("attributes")
	if not (attrs is Dictionary):
		return -1.0
	var value: Variant = (attrs as Dictionary).get("cmd", -1.0)
	return float(value) if value is float or value is int else -1.0


# ─────────────────────────────── 征服系统装配（出征与领地架构 §一）───────────────────────────────

## 实例化 ExpansionApi + ConquestManager：单一 TerritoryRegistry 共享给
## api 查询面/GarrisonSpawner/ConquestManager；ConquestManager 常驻 GameRoot
## （监听全局 map_loaded/battle_ended，领地状态跨图存活）。
func _setup_conquest_system() -> void:
	var registry := TerritoryRegistry.new()
	registry.load_config()
	var api := Node.new()
	api.set_script(_ExpansionApiScript)
	api.name = "ExpansionApi"
	_root.add_child(api)
	_root._expansion_api = api
	api.setup(registry)
	var spawner := GarrisonSpawner.new()
	spawner.setup(registry)
	var manager := Node.new()
	manager.set_script(_ConquestManagerScript)
	manager.name = "ConquestManager"
	_root.add_child(manager)
	_root._conquest_manager = manager
	manager.setup(registry, spawner, api,
			_root._combat_api, _root._resources_api, _root.scene_loader)
	api.set_flow_manager(manager)


# ─────────────────────────────── 招兵与人口装配（游戏循环深化批次 1）───────────────────────────────

## RecruitManager 常驻 GameRoot（人口再生 tick 跨图存活但只在村A 计时）；
## 招兵逻辑经 OrganizationApi 转发（api.gd 招兵段），玩家交互注入见 game_root._on_map_loaded。
func _setup_recruit_system() -> void:
	var mgr := Node.new()
	mgr.set_script(_RecruitManagerScript)
	mgr.name = "RecruitManager"
	_root.add_child(mgr)
	_root._recruit_manager = mgr
	mgr.setup(_root._construction_api, _root._resources_api,
			_root.scene_loader, _root._formation_system)
	if _root._organization_api != null and _root._organization_api.has_method("set_recruit_manager"):
		_root._organization_api.set_recruit_manager(mgr)


# ─────────────────────────────── 上报叙事装配（UI-W2-B ②③）───────────────────────────────

## OrgReportNarrator 常驻 GameRoot：消费 organization api 的 report_filed（组织侧
## 门控后的可见集）与 EventBus.commander_assigned，经 EventBus.ui_notification 落既有通知 feed。
## 归 organization/ui（消费组织域数据、组织域 UI），不建跨模块面板。
func _setup_org_report_narrator() -> void:
	if _root._organization_api == null:
		return
	var n := Node.new()
	n.set_script(_OrgReportNarratorScript)
	n.name = "OrgReportNarrator"
	_root.add_child(n)
	_root._org_report_narrator = n
	if n.has_method("setup"):
		n.setup(_root._organization_api)


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
	var fp := UIKit.full_rect(_FormationPanelScript, "FormationPanel")
	if not _root.ui_root.add_to_slot("ModalOverlay", fp):
		return
	_root._formation_panel = fp
	call_deferred("_setup_formation_panel_deferred")


func _setup_formation_panel_deferred() -> void:
	if _root._formation_panel == null:
		return
	if _root._formation_panel.has_method("setup"):
		_root._formation_panel.setup(_root)


# ─────────────────────────────── 组织管理窗口装配 ────────────────────────────────

## 实例化 OrgPanel 并挂到 UIRoot.ModalOverlay 槽（FLOATING 浮动窗口，open/close 控制可见性）。
func _setup_org_panel() -> void:
	if _root.ui_root == null:
		return
	var op := UIKit.full_rect(_OrgPanelScript, "OrgPanel")
	if not _root.ui_root.add_to_slot("ModalOverlay", op):
		return
	_root._org_panel = op
	# 装配层接线：OrgPanel 选中变更 → 班组卡（UI-W4b 触发源补全，不跨模块 get_node）
	if op.has_signal("org_selection_changed") \
			and not op.org_selection_changed.is_connected(_on_org_selection_changed):
		op.org_selection_changed.connect(_on_org_selection_changed)
	call_deferred("_setup_org_panel_deferred")


## OrgPanel 选中组织 → 班组卡联动（选中 L1 唤起；其余/取消/关面板收起）。
## 班组卡未装配（步骤表更靠后）时静默跳过，装配完成后自然生效。
func _on_org_selection_changed(org_id: String) -> void:
	if _squad_card == null or not is_instance_valid(_squad_card):
		return
	var show: bool = false
	if not org_id.is_empty() and _root._organization_api != null \
			and _root._organization_api.has_method("get_organization"):
		var r: Dictionary = _root._organization_api.get_organization(org_id)
		show = r.get("ok", false) and int((r.get("data", {}) as Dictionary).get("tier", 0)) == 1
	if show and _squad_card.has_method("show_squad"):
		_squad_card.call("show_squad", org_id)
	elif _squad_card.has_method("hide_card"):
		_squad_card.call("hide_card")


func _setup_org_panel_deferred() -> void:
	if _root._org_panel == null:
		return
	if _root._org_panel.has_method("setup"):
		_root._org_panel.setup(_root)


# ─────────────────────────── 战略总览装配（UI-W4b §3.2.C）───────────────────────────

## 实例化 StrategicOverviewPanel（全屏根走 UIKit.full_rect 合规出口，OrgPanel 同款）
## 挂 UIRoot.ModalOverlay 槽；入口在 OrgPanel 顶部「总览」按钮（group 查找，
## 装配层不导引用）。数据自取：组织 api 报表 + report_filed/commander_assigned 时间线。
func _setup_strategic_overview() -> void:
	if _root.ui_root == null:
		return
	var sp := UIKit.full_rect(_StrategicOverviewPanelScript, "StrategicOverviewPanel")
	if not _root.ui_root.add_to_slot("ModalOverlay", sp):
		sp.queue_free()
		return
	if sp.has_method("setup"):
		sp.setup(_root)


# ─────────────────────────── 指挥链视图装配（UI-W3）───────────────────────────

## 实例化 CommandChainView 场景（command_chain_view.tscn，场景=布局唯一真相源）挂
## UIRoot.ModalOverlay 槽（独立 FLOATING 窗口，与 OrgPanel 并存不互嵌——方案 §五.2）。
## 视图自带 group("command_chain_view")，OrgPanel 顶部「指挥链」按钮按 group 打开，
## 装配层不导引用（不新增 GameRoot getter）。
func _setup_command_chain_view() -> void:
	if _root.ui_root == null:
		return
	var cv: Control = _CommandChainViewScene.instantiate()
	if not _root.ui_root.add_to_slot("ModalOverlay", cv):
		cv.queue_free()
		return
	if cv.has_method("setup"):
		cv.setup(_root)


# ─────────────────────────────── 设置菜单装配（齿轮/ESC 打开）────────────────────────────────

## 实例化 SettingsMenuPanel 并挂到 UIRoot.ModalOverlay 槽（全屏 UI 根走 UIKit.full_rect）。
func _setup_settings_menu_panel() -> void:
	if _root.ui_root == null:
		return
	var sp := UIKit.full_rect(_SettingsMenuPanelScript, "SettingsMenuPanel")
	if not _root.ui_root.add_to_slot("ModalOverlay", sp):
		return
	_root._settings_menu_panel = sp
	call_deferred("_setup_settings_menu_panel_deferred")


func _setup_settings_menu_panel_deferred() -> void:
	if _root._settings_menu_panel == null:
		return
	if _root._settings_menu_panel.has_method("setup"):
		_root._settings_menu_panel.setup(_root)


# ─────────────────────────────── 暂停菜单装配（ESC 打开）────────────────────────────────

## 实例化 PauseMenuPanel 并挂到 UIRoot.ModalOverlay 槽（全屏 UI 根走 UIKit.full_rect）。
func _setup_pause_menu_panel() -> void:
	if _root.ui_root == null:
		return
	var pp := UIKit.full_rect(_PauseMenuPanelScript, "PauseMenuPanel")
	if not _root.ui_root.add_to_slot("ModalOverlay", pp):
		return
	_root._pause_menu_panel = pp
	call_deferred("_setup_pause_menu_panel_deferred")


func _setup_pause_menu_panel_deferred() -> void:
	if _root._pause_menu_panel == null:
		return
	if _root._pause_menu_panel.has_method("setup"):
		_root._pause_menu_panel.setup(_root)


# ─────────────────────────────── 小地图装配（§15 阶段 0.6）────────────────────────────────

## 创建顶部小地图区（Minimap + L1 缩略窗）并挂到 UIRoot。详见 §10.4。
## Minimap（本城市俯视）**常驻恒显**——Tab 三态不影响（创始人反馈）；
## L1 缩略窗也常驻（创始人反馈：Tab 地图默认展开），初始隐藏，由步骤表
## 后段的「地图缩略窗」步骤喂完数据后显示。
func _setup_minimap() -> void:
	if _root.ui_root == null:
		return
	var mm := UIKit.widget(_MinimapScript, "Minimap")
	_root.ui_root.add_to_slot("HudOverlay", mm)
	# 定位归 zone（顶部中央堆叠区，见 hud_zone_layout.gd）；先落位再 setup，
	# 让 L1 缩略窗读到最终 rect
	_root.ui_root.place_in_zone(&"top_center", mm)
	_root._minimap = mm
	if mm.has_method("setup"):
		mm.setup(_root)
	mm.visible = true
	# L1 世界缩略窗（贴 Minimap 右侧并列；点击 = 切到 L1 大图）
	_l1_thumbnail = UIKit.widget(_L1ThumbnailScript, "L1Thumbnail")
	_root.ui_root.add_to_slot("HudOverlay", _l1_thumbnail)
	if _l1_thumbnail.has_signal("open_l1_requested"):
		_l1_thumbnail.open_l1_requested.connect(_on_l1_thumbnail_clicked)
	if _l1_thumbnail.has_method("place_right_of_minimap"):
		# deferred：top_center 已改 stack 模式，Minimap 的 rect 由 deferred 重排
		# 写入，立即调用会读到旧 rect（0,0 起）；call_deferred 排在重排之后必就绪
		_l1_thumbnail.call_deferred("place_right_of_minimap", mm)
	_l1_thumbnail.visible = false


# ─────────────────────────────── TeamAi 状态 HUD 装配（W1 观测接线批）────────────────────────────────

## 挂 TeamAi 姿态 HUD（combat/ui/team_ai_hud.tscn，场景=布局唯一真相源）到
## HudOverlay 槽并注入 BattleDirector 引用（数据自取，本层只装配）。显隐走
## DebugApi drawer "team_ai_hud"（F3 开关族，注册见 register_debug_drawers）；
## 槽位路由见 UI.md §10.7，模块专属 UI 归 combat/ui（组织界面与AI状态接线 §2.2）。
func _setup_team_ai_hud() -> void:
	if _root.ui_root == null or _root.battle_director == null:
		return
	var hud := _TeamAiHudScene.instantiate()
	if not _root.ui_root.add_to_slot("HudOverlay", hud):
		hud.queue_free()
		return
	if hud.has_method("setup"):
		hud.setup(_root.battle_director)


# ─────────────────────────────── L1 班组卡装配（W2 · 组织界面）────────────────────────────────

## 挂 L1 班组卡（combat/ui/squad_card.tscn，场景=布局唯一真相源）到 ContextPanel 的
## SquadInspector 具名槽（槽在 context_panel.tscn 声明，UI.md §10.1 层级图），
## 并注入 GameRoot（卡片数据自取：框选解析小队 → 编制/相位/士气 duck 取数）。
## 显隐由卡片自管（框选到小队即有、清空即收），装配层不参与业务判断。
## 走 add_to_slot 的路径形式——槽在 ContextPanel 之下（UI.md §10.1 组织层级），
## 槽名即 UIRoot 下的相对 NodePath。
func _setup_squad_card() -> void:
	if _root.ui_root == null:
		return
	var card := _SquadCardScene.instantiate()
	if not _root.ui_root.add_to_slot("ContextPanel/SquadInspector", card):
		card.queue_free()
		return
	_squad_card = card
	if card.has_method("setup"):
		card.setup(_root)


## 创建 ZoomBar 并挂到 UIRoot，钉进 top_center stack（Minimap 正下方，见 hud_zone_layout.gd）。
func _setup_zoom_bar() -> void:
	if _root.ui_root == null:
		return
	var zb := UIKit.widget(_ZoomBarScript, "ZoomBar")
	_root.ui_root.add_to_slot("HudOverlay", zb)
	_root.ui_root.place_in_zone(&"top_center", zb)
	_root._zoom_bar = zb
	if zb.has_method("setup"):
		zb.setup(_root.camera_rig)


# ─────────────────────────────── 背包装备系统装配（modules/inventory）────────────────────────────────

## 装配背包装备系统四件套：
##   1. InventoryService（GameRoot 子节点：玩家背包 + 装备→附身实体桥接）
##   2. Hotbar（HudOverlay 底部常驻物品栏：主副手/Hotbar 物品/动作快捷键三组）
##   3. InventoryScreen（ModalOverlay 模态背包：E 键开关，UIModalStack.INVENTORY）
##   4. StatsScreen（ModalOverlay 角色属性面板：C 键开关，UIModalStack.STATS）
func _setup_inventory() -> void:
	if _root.ui_root == null:
		return
	var service := Node.new()
	service.set_script(_InventoryServiceScript)
	service.name = "InventoryService"
	_root.add_child(service)
	if service.has_method("setup"):
		service.setup(_root)
	_root.inventory_service = service
	var hb := UIKit.widget(_HotbarScript, "Hotbar")
	_root.ui_root.add_to_slot("HudOverlay", hb)
	if hb.has_method("setup"):
		hb.setup(_root, service)
	var inv := UIKit.full_rect(_InventoryScreenScript, "InventoryScreen")
	if not _root.ui_root.add_to_slot("ModalOverlay", inv):
		return
	_root._inventory_screen = inv
	if inv.has_method("setup"):
		inv.setup(_root, service)
	var stats := UIKit.full_rect(_StatsScreenScript, "StatsScreen")
	if not _root.ui_root.add_to_slot("ModalOverlay", stats):
		return
	_root._stats_panel = stats
	if stats.has_method("setup"):
		stats.setup(_root, service)


# ─────────────────────────────── 附身系统装配（§15 阶段 0.7）────────────────────────────────

## 实例化 PossessionInterface，注册为 POSSESS 模式 handler。
func _setup_possession_interface() -> void:
	var pi := Node.new()
	pi.set_script(_PossessionInterfaceScript)
	pi.name = "PossessionInterface"
	_root.add_child(pi)
	_root._possession_interface = pi
	# 注入 GameRoot（替代父链反查）
	if pi.has_method("setup"):
		pi.setup(_root)
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
	# 注入 GameRoot（替代父链反查）
	if handler.has_method("setup"):
		handler.setup(_root)
	_root.input_dispatcher.register_handler(PlayerControlAPI.Mode.EXPLORE, handler)


# ─────────────────────────────── 阶段 F：边界检测出城系统 ────────────────────────────────

func _setup_boundary_detector() -> void:
	# 实例化边界检测器
	_root._boundary_detector = Node.new()
	_root._boundary_detector.set_script(_MapBoundaryDetectorScript)
	_root._boundary_detector.name = "MapBoundaryDetector"
	_root.add_child(_root._boundary_detector)
	# 注入 GameRoot（替代根节点遍历反查）
	if _root._boundary_detector.has_method("setup"):
		_root._boundary_detector.setup(_root)
	# 战略图初始化已进装配步骤表（「战略图 L1/L3」两步分帧，创始人反馈 Tab 地图
	# 默认展开）；此处仍留 _ensure_strategic_maps 兜底——步骤表未跑到的早开路径
	# （Tab / M / 边界提示）首次触发时补初始化，见 _open_strategic_map。
	_root._boundary_detector.open_world_map_requested.connect(_open_strategic_map)
	# 战略图关闭 -> 恢复场景图输入（api.close_strategic_map / ESC 都发此信号）
	if EventBus != null:
		EventBus.strategic_map_closed.connect(_on_strategic_map_closed)
	# F2/C1 玩家位置动态接线（总体设计 §5.6）：每次场景图加载 → world_map api
	# 反查所在聚落，更新图钉 + 当前地块描边（跨 L1 的 region/Tab 跟随留 D 期）
	if _root.scene_loader != null and _root.scene_loader.has_signal("map_loaded") \
			and not _root.scene_loader.map_loaded.is_connected(_on_player_map_changed):
		_root.scene_loader.map_loaded.connect(_on_player_map_changed)


## 玩家所在场景图变化（F2/C1）：经 world_map api 反查所在聚落。
## api 未初始化（战略图未装配）时跳过——图钉默认锚出生聚落，语义仍正确。
func _on_player_map_changed(map_id: String, _map_type: int) -> void:
	if _root._strategic_map == null:
		return
	var content: Node = _root._strategic_map.get_node_or_null("Content")
	var api: Node = content.get_node_or_null("Api") if content != null else null
	if api != null and api.has_method("is_initialized") and api.is_initialized() \
			and api.has_method("set_player_map"):
		api.set_player_map(map_id)
	# 缩略窗常驻（创始人反馈）：随场景图切换重喂，保当前位置标记新鲜
	_feed_thumbnail_data()


## 战略图初始化（幂等兜底）：常规路径由装配步骤表「战略图 L1/L3」分帧完成，
## 早于步骤表的打开路径（Tab / M / 边界提示）经此处补齐。
## 战略图 Content 常驻隐藏，其 instantiate + 数据加载（l1/l3 JSON + 索引图）耗时巨大，
## 已拆进步骤表借加载屏分帧消化（当年整段同步曾致启动卡 10s+）。
func _ensure_strategic_maps() -> void:
	if _root._strategic_map == null:
		_setup_l1_strategic_map()
	if _root._strategic_map_l3 == null:
		_setup_l3_strategic_map()


## 装配 L1 战略图（Tab / 边界提示打开的世界地图）
func _setup_l1_strategic_map() -> void:
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
	# 装配 L2 下钻视图（L3 单击地区 -> L2 详细地图）
	var l2: Node = _StrategicMapL2Scene.instantiate()
	l2.name = "StrategicMapL2"
	_root.add_child(l2)
	var l2_content: Node = l2.get_node_or_null("Content")
	if l2_content != null and content != null and content.has_method("set_l2_view") \
			and l2_content.has_method("open"):
		content.call("set_l2_view", l2_content)
	# 装配 L2 -> L1 下钻（L2 点击 L1 地块打开对应老 L1 的 Tab 视图；L1 controller = strategic_map.tscn 的 Content）
	var l1_content: Node = _root._strategic_map.get_node_or_null("Content") if _root._strategic_map != null else null
	if l2_content != null and l1_content != null and l2_content.has_method("set_l1_view"):
		l2_content.call("set_l1_view", l1_content)


## M 键全局监听（打开/关闭 L3 大世界战略图）
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_M:
		_toggle_l3_strategic_map()
		get_viewport().set_input_as_handled()


func _toggle_l3_strategic_map() -> void:
	_ensure_strategic_maps()
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


## Tab / 边界触发入口（Minimap 常驻不受 Tab 影响；L1 缩略窗也常驻——创始人反馈）。
## full_map=true（边界自动触发，如顶边界持续推进）：直接开 L1 大图（保留原"出城看图"语义）；
## full_map=false（玩家按 Tab）：缩略窗态开 L1 大图 / 大图态关闭回缩略窗（互切）。
## M（L3/L2）会话期间忽略：新开视图 = 玩家所见的互斥原则——否则状态机在 L3 海洋层下
## 悄悄切态（L1 被盖住打开），M 一关 L1 意外弹出。
func _open_strategic_map(full_map: bool) -> void:
	if _is_l3_session_active():
		return
	_ensure_strategic_maps()
	if full_map:
		if _tab_state != TabMapState.FULL_L1:
			_set_l1_thumbnail_visible(false)
			_open_l1_full_map()
		return
	match _tab_state:
		TabMapState.HIDDEN:
			_feed_thumbnail_data()
			_set_l1_thumbnail_visible(true)
			_tab_state = TabMapState.TOP_MINIMAPS
		TabMapState.TOP_MINIMAPS:
			_set_l1_thumbnail_visible(false)
			_open_l1_full_map()
		TabMapState.FULL_L1:
			_close_l1_full_map()


## M 会话是否激活（L3 可见，或下钻中的 L2 可见——L3 隐藏但 _l2_active 保留）
func _is_l3_session_active() -> bool:
	if _root._strategic_map_l3 == null:
		return false
	var l3_content: Node = _root._strategic_map_l3.get_node_or_null("Content")
	if l3_content == null:
		return false
	if l3_content.visible:
		return true
	var l2_active: Variant = l3_content.get("_l2_active")
	return l2_active != null and bool(l2_active) and l3_content.l2_view != null \
			and l3_content.l2_view.visible


## L1 缩略窗显隐（仅开 L1 大图时收起、关闭即回显；Minimap/缩略窗双常驻——创始人反馈）
func _set_l1_thumbnail_visible(v: bool) -> void:
	if _l1_thumbnail != null:
		_l1_thumbnail.visible = v


## 喂 L1 缩略窗世界数据（当前位置标记数据源）：从 L1 战略图 api 取已初始化的
## L1WorldData（ensure 后必就绪；幂等，每次进入顶部小地图态时刷新）
func _feed_thumbnail_data() -> void:
	if _l1_thumbnail == null or not _l1_thumbnail.has_method("set_map_data"):
		return
	var content: Node = _root._strategic_map.get_node_or_null("Content") \
			if _root._strategic_map != null else null
	var api: Node = content.get_node_or_null("Api") if content != null else null
	if api != null and api.has_method("is_initialized") and api.is_initialized() \
			and api.has_method("get_data"):
		_l1_thumbnail.set_map_data(api.get_data())


## 地图缩略窗默认展开（装配步骤表「地图缩略窗」；创始人反馈：Tab 地图开局即显示）。
## 前置：战略图 L1/L3 步骤已完成初始化，此处只喂数据 + 置顶双窗态。
func _open_tab_map_default() -> void:
	if _l1_thumbnail == null:
		return
	_feed_thumbnail_data()
	_tab_state = TabMapState.TOP_MINIMAPS
	_set_l1_thumbnail_visible(true)


## 打开 L1 大图（三态第三态；L1 缩略窗先收起，Minimap 常驻不动）
func _open_l1_full_map() -> void:
	if _root._strategic_map == null:
		return
	# 战略图是 CanvasLayer，控制器在 Content 子节点（visible 控制全层显隐）
	var content: Node = _root._strategic_map.get_node_or_null("Content")
	if content == null or not content.has_method("open"):
		return
	content.open()
	_pause_scene_input(true)
	_tab_state = TabMapState.FULL_L1


## 关闭 L1 大图（close 发 strategic_map_closed → _on_strategic_map_closed 归位 HIDDEN）
func _close_l1_full_map() -> void:
	var content: Node = _root._strategic_map.get_node_or_null("Content") \
			if _root._strategic_map != null else null
	if content != null and content.visible and content.has_method("close"):
		content.close()
	else:
		_tab_state = TabMapState.HIDDEN


## L1 缩略窗点击 = 缩略窗态 → 大图（与 Tab 第二次按下等效；Minimap 常驻不动）
func _on_l1_thumbnail_clicked() -> void:
	if _tab_state != TabMapState.TOP_MINIMAPS:
		return
	_set_l1_thumbnail_visible(false)
	_open_l1_full_map()


func _on_strategic_map_closed() -> void:
	_pause_scene_input(false)
	# L1 大图任何路径关闭（ESC / Tab / M 互斥）都回到顶部双窗态（缩略窗常驻，
	# 创始人反馈；关闭时重喂数据刷新当前位置标记）。TOP_MINIMAPS 态下的 M 开关
	# L3 不影响（其 close 也发此信号，但此时不在 FULL_L1）
	if _tab_state == TabMapState.FULL_L1:
		_tab_state = TabMapState.TOP_MINIMAPS
		_feed_thumbnail_data()
		_set_l1_thumbnail_visible(true)


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
	# （possessed 玩家白四角框已归并入 SelectionSystem._draw，2026-09-14）
	# 鼠标悬停方框
	_root._hover_indicator = UIKit.widget(_HoverIndicatorScript, "HoverIndicator")
	_root._hover_indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _root._hover_indicator.has_method("setup"):
		_root._hover_indicator.setup(_root.camera_rig, _root)
	if _root.ui_root != null:
		_root.ui_root.add_to_slot("HudOverlay", _root._hover_indicator)
	else:
		_root.add_child(_root._hover_indicator)
	# 中键滚动图标
	_root._middle_scroll_overlay = UIKit.widget(_MiddleScrollOverlayScript, "MiddleScrollOverlay")
	_root._middle_scroll_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _root._middle_scroll_overlay.has_method("setup"):
		_root._middle_scroll_overlay.setup(_root.camera_rig)
	if _root.ui_root != null:
		_root.ui_root.add_to_slot("HudOverlay", _root._middle_scroll_overlay)
	else:
		_root.add_child(_root._middle_scroll_overlay)


# ─────────────────────────────── 阶段 E：建造菜单装配 ────────────────────────────────

## 实例化建造菜单并挂到 UIRoot，延迟 setup 等 ConstructionManager 就绪。
func _setup_build_menu() -> void:
	if _root.ui_root == null:
		return
	# P1 + P2：全屏 UI 根一律用 UIKit.full_rect（强制 FULL_RECT，杜绝"Control.new()
	# 丢 anchor → 按钮静默不可见"），并挂到 HudOverlay 槽（槽位化路由）
	_root._build_menu = UIKit.full_rect(_BuildMenuScript, "BuildMenu")
	_root.ui_root.add_to_slot("HudOverlay", _root._build_menu)
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
	# 注入地图节点路径表：绘制器经 ctx 查节点，不反向 import WorldAPI（避免 debug_gui↔world 依赖环）
	DebugApi.set_ctx_extra("map_paths", {
		"placement_grid": WorldAPI.PATH_MAP_PLACEMENT_GRID,
		"building_host": WorldAPI.PATH_MAP_BUILDING_HOST,
		"terrain_buildings": WorldAPI.PATH_MAP_TERRAIN_BUILDINGS,
		"chunk_triggers": WorldAPI.PATH_MAP_CHUNK_TRIGGERS,
		"entity_host": WorldAPI.PATH_MAP_ENTITY_HOST,
	})
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
	# W1 观测接线批：TeamAi 姿态 HUD 开关（HUD 本体独立 Control，此注册仅进 F3 复选框族）
	DebugApi.register_drawer("team_ai_hud", Callable(_DebugDrawers, "draw_team_ai_hud"))


# ─────────────────────────────── Demo 目标链装配 ────────────────────────────────

## 装配演示目标链（四阶段引导 + 胜利结算）。
## deferred 时机：晚于 _setup_resources_api_deferred（deferred 队列 FIFO），
## 保证初始资源已发放、DemoQuest 的采集基线快照不被初始资源污染。
func _setup_demo_quest_deferred() -> void:
	if _root.ui_root == null or _root._resources_api == null:
		return
	var panel: Control = _QuestPanelScript.new()
	panel.name = "QuestPanel"
	if not _root.ui_root.add_to_slot("HudOverlay", panel):
		panel.queue_free()
		return
	# 定位归 zone：top_left_stack 堆叠区（排在资源条之下，见 hud_zone_layout.gd）
	_root.ui_root.place_in_zone(&"top_left_stack", panel)
	var quest := Node.new()
	quest.set_script(_DemoQuestScript)
	quest.name = "DemoQuest"
	_root.add_child(quest)
	quest.setup(panel, _root._resources_api, _root._construction_api, _root.ui_root)


# ─────────────────────────────── 后处理层装配（Demo P3）────────────────────────────────

## 全屏后处理层：暖色分级/太阳炫光/渐晕/色差/颗粒（layer 0.5，压世界不压 UI）。
func _setup_post_process() -> void:
	var layer := PostProcessLayer.new()
	layer.name = "PostProcess"
	_root.add_child(layer)
	var env: Node = _root.get_node_or_null("EnvironmentSystem")
	if env != null:
		layer.bind_env(env)


# ─────────────────────────────── 转场遮罩装配（Demo P3）────────────────────────────────

## 地图切换黑场转场（travel_started 渐黑 / travel_completed 渐明，零侵入）。
func _setup_map_transition() -> void:
	var overlay := MapTransitionOverlay.new()
	overlay.name = "MapTransition"
	_root.add_child(overlay)


# ─────────────────────────────── 单位 LOD 调度装配 ────────────────────────────────

## 创建单位 LOD 调度器（性能优化：混战表现层按相机距离分档节流——48v48 场景下
## 每单位动画采样/程序化叠加/血条重绘是大头）。自动发现模式：注入 GameRoot 后
## 每 10Hz 经 get_current_map() 解析 EntityHost 单位集 + 视口激活相机分档，
## 地图实例变更自动换绑。挂 GameRoot 下持久存在，不随战斗实例生灭；
## headless 无相机时空转（单位保持默认全速，零行为变化）。
func _setup_unit_lod() -> void:
	if _root.get_node_or_null("UnitLodDirector") != null:
		return  # 已存在，避免重复添加
	var lod := Node.new()
	lod.set_script(_UnitLodDirectorScript)
	lod.name = "UnitLodDirector"
	_root.add_child(lod)
	# 自动发现模式：无需外部喂数据，注入宿主后自取地图/单位集/相机
	if lod.has_method("setup"):
		lod.setup(_root)
