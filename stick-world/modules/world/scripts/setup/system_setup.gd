extends Node
## GameRoot 系统装配器 —— 负责实例化并装配所有常驻子系统。
##
## 职责：
## - 分帧步骤表编排（加载屏双进度条契约：步骤顺序/名称/数量语义不得变化）
## - 全部跨模块 preload 集中于此（composition root 豁免，audit_deps 口径）
## - 装配状态持有（Tab 三态 / L1 缩略窗 / 班组卡引用等）
##
## 各步骤函数体按域下沉到同目录 RefCounted 助手（bind(host) 回引宿主，宿主壳一行转发）：
## - system_setup_core_systems.gd   建造/战斗/资源/框选/组织/编队/战术/指挥传输/征服/招兵/上报叙事
## - system_setup_ui_panels.gd      界面根/调试层/战斗·编队·组织面板/战略总览/指挥链视图/设置·暂停菜单/TeamAi HUD/班组卡/缩放条/背包
## - system_setup_strategic_map.gd  小地图/战略图 L1·L3/地图缩略窗/Tab 三态与 M 键运行时/边界检测/地图旅行
## - system_setup_extras.gd         附身界面·面板/探索交互/游戏 UI/建造菜单/调试绘制器注册/Demo 目标链/后处理/地图过渡/单位 LOD
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

# 域助手（同模块内 preload，非跨模块依赖；实例懒初始化见各 _xxx_part() getter）
const _CorePartScript: GDScript = preload("res://modules/world/scripts/setup/system_setup_core_systems.gd")
const _PanelsPartScript: GDScript = preload("res://modules/world/scripts/setup/system_setup_ui_panels.gd")
const _MapPartScript: GDScript = preload("res://modules/world/scripts/setup/system_setup_strategic_map.gd")
const _ExtrasPartScript: GDScript = preload("res://modules/world/scripts/setup/system_setup_extras.gd")

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

# 域助手实例（bind(self) 需运行期绑定，不用引用 self 的字段初始化器）
var _core_part = null
var _panels_part = null
var _map_part = null
var _extras_part = null


func _core():
	if _core_part == null:
		_core_part = _CorePartScript.new()
		_core_part.bind(self)
	return _core_part


func _panels():
	if _panels_part == null:
		_panels_part = _PanelsPartScript.new()
		_panels_part.bind(self)
	return _panels_part


func _maps():
	if _map_part == null:
		_map_part = _MapPartScript.new()
		_map_part.bind(self)
	return _map_part


func _extras():
	if _extras_part == null:
		_extras_part = _ExtrasPartScript.new()
		_extras_part.bind(self)
	return _extras_part


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
## 步骤的顺序/名称/数量语义是加载屏副进度条契约，不得变化。
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


# ─────────────────── 壳方法：核心系统域（转发 system_setup_core_systems.gd） ───────────────────

func _setup_construction_system() -> void:
	_core()._setup_construction_system()


func _setup_construction_api_deferred() -> void:
	_core()._setup_construction_api_deferred()


func _setup_combat_system() -> void:
	_core()._setup_combat_system()


func _setup_combat_api_deferred() -> void:
	_core()._setup_combat_api_deferred()


func _setup_resources_system() -> void:
	_core()._setup_resources_system()


func _setup_resources_api_deferred() -> void:
	_core()._setup_resources_api_deferred()


func _setup_selection_system() -> void:
	_core()._setup_selection_system()


func _setup_organization_system() -> void:
	_core()._setup_organization_system()


func _setup_formation_system() -> void:
	_core()._setup_formation_system()


func _setup_tactical_system() -> void:
	_core()._setup_tactical_system()


func _setup_command_transport() -> void:
	_core()._setup_command_transport()


func _setup_conquest_system() -> void:
	_core()._setup_conquest_system()


func _setup_recruit_system() -> void:
	_core()._setup_recruit_system()


func _setup_org_report_narrator() -> void:
	_core()._setup_org_report_narrator()


# ─────────────────── 壳方法：UI 与面板域（转发 system_setup_ui_panels.gd） ───────────────────

func _setup_ui_root() -> void:
	_panels()._setup_ui_root()


func _setup_debug_overlay() -> void:
	_panels()._setup_debug_overlay()


func _setup_battle_panel() -> void:
	_panels()._setup_battle_panel()


func _setup_battle_panel_deferred() -> void:
	_panels()._setup_battle_panel_deferred()


func _setup_formation_panel() -> void:
	_panels()._setup_formation_panel()


func _setup_formation_panel_deferred() -> void:
	_panels()._setup_formation_panel_deferred()


func _setup_org_panel() -> void:
	_panels()._setup_org_panel()


func _setup_org_panel_deferred() -> void:
	_panels()._setup_org_panel_deferred()


func _setup_strategic_overview() -> void:
	_panels()._setup_strategic_overview()


func _setup_command_chain_view() -> void:
	_panels()._setup_command_chain_view()


func _setup_settings_menu_panel() -> void:
	_panels()._setup_settings_menu_panel()


func _setup_settings_menu_panel_deferred() -> void:
	_panels()._setup_settings_menu_panel_deferred()


func _setup_pause_menu_panel() -> void:
	_panels()._setup_pause_menu_panel()


func _setup_pause_menu_panel_deferred() -> void:
	_panels()._setup_pause_menu_panel_deferred()


func _setup_team_ai_hud() -> void:
	_panels()._setup_team_ai_hud()


func _setup_squad_card() -> void:
	_panels()._setup_squad_card()


func _setup_zoom_bar() -> void:
	_panels()._setup_zoom_bar()


func _setup_inventory() -> void:
	_panels()._setup_inventory()


# ─────────────────── 壳方法：战略图域（转发 system_setup_strategic_map.gd） ───────────────────

func _setup_minimap() -> void:
	_maps()._setup_minimap()


func _setup_l1_strategic_map() -> void:
	_maps()._setup_l1_strategic_map()


func _setup_l3_strategic_map() -> void:
	_maps()._setup_l3_strategic_map()


## 战略图初始化兜底（幂等）：测试（test_menu_navigation）与早开路径经宿主壳调用。
func _ensure_strategic_maps() -> void:
	_maps()._ensure_strategic_maps()


func _open_tab_map_default() -> void:
	_maps()._open_tab_map_default()


func _setup_boundary_detector() -> void:
	_maps()._setup_boundary_detector()


# ─────────────────── 壳方法：玩家交互与环境域（转发 system_setup_extras.gd） ───────────────────

func _setup_possession_interface() -> void:
	_extras()._setup_possession_interface()


func _setup_possess_panel() -> void:
	_extras()._setup_possess_panel()


func _setup_possess_panel_deferred() -> void:
	_extras()._setup_possess_panel_deferred()


func _register_explore_handler() -> void:
	_extras()._register_explore_handler()


func _setup_game_ui() -> void:
	_extras()._setup_game_ui()


func _setup_build_menu() -> void:
	_extras()._setup_build_menu()


func _setup_build_menu_deferred() -> void:
	_extras()._setup_build_menu_deferred()


## 注册调试绘制器到 DebugApi（详见 §10.5.7；GameRoot._ready 调用）
func register_debug_drawers() -> void:
	_extras().register_debug_drawers()


func _setup_demo_quest_deferred() -> void:
	_extras()._setup_demo_quest_deferred()


func _setup_post_process() -> void:
	_extras()._setup_post_process()


func _setup_map_transition() -> void:
	_extras()._setup_map_transition()


func _setup_unit_lod() -> void:
	_extras()._setup_unit_lod()


# ─────────────────────────────── 引擎回调（必须留在 Node 宿主） ───────────────────────────────

## M 键全局监听（打开/关闭 L3 大世界战略图）
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_M:
		_maps()._toggle_l3_strategic_map()
		get_viewport().set_input_as_handled()
