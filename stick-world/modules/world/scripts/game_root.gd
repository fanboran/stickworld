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
##   ShortcutGate    —— 暂停期快捷键通道（ALWAYS，转发输入到 handle_shortcuts）
##   SystemSetup     —— 系统装配（system_setup.gd）
##   SaveHandler     —— 存档/读档（save_handler.gd）
##   TravelHandler   —— 传送/过场（travel_handler.gd）
##   InitialContent  —— 初始内容生成（initial_content.gd）
##
## ── process_mode 分层表（暂停原语化，声明集中在 game_root.tscn / ui_root.tscn）──
## 本节点保持默认 PAUSABLE：引擎总闸（SceneTree.paused，由 TimeManager 翻转）
## 一刀冻结世界全家（含 SystemSetup 运行时挂载的全部管理器）。显式例外：
##   ShortcutGate = ALWAYS  ESC/空格/存读档快捷键在暂停期必须存活（本文件 handle_shortcuts）
##   CameraRig    = ALWAYS  暂停布置战术时仍可平移/缩放（输入自门禁防穿透模态）
##   UIRoot       = ALWAYS  ui_root.tscn 内声明；菜单可开可点、沸腾动画继续
##   TimeManager / SaveManager = ALWAYS（自动加载不在两棵子树内，在各自 _ready 声明）
## 其余子节点一律不设 process_mode（INHERIT → PAUSABLE）；新系统挂本节点下
## 默认随闸冻结，需要暂停期存活的必须进上表并注释理由。

# WorldAPI / PlayerControlAPI 是全局 class_name，无需 preload

# ─────────────────────────────── 子模块脚本 ────────────────────────────────

const _SystemSetupScript: GDScript = preload("res://modules/world/scripts/setup/system_setup.gd")
const _SaveHandlerScript: GDScript = preload("res://modules/world/scripts/setup/save_handler.gd")
const _TravelHandlerScript: GDScript = preload("res://modules/world/scripts/setup/travel_handler.gd")
const _InitialContentScript: GDScript = preload("res://modules/world/scripts/setup/initial_content.gd")
## 地图生命周期响应助手（开局分流 / map_loaded 编排 / 跨图携带 / 步行消费；
## 状态留本类，逻辑下沉，_ready 首两句构造）
const _MapFlowScript: GDScript = preload("res://modules/world/scripts/game_root_map_flow.gd")
## 快捷键/模态助手（handle_shortcuts 全分派 / ESC 退栈 / 模态面板开关；
## 状态留本类，逻辑下沉，_ready 首两句构造）
const _ShortcutsScript: GDScript = preload("res://modules/world/scripts/game_root_shortcuts.gd")
## 世界加载覆盖层（消除启动加载期的死灰屏）
## audit-exempt: 组合根装配 ui_global 组件，与 system_setup.gd 同性质
const _WorldLoadingOverlayScript: GDScript = preload("res://modules/ui_global/scripts/overlays/world_loading_overlay.gd")

## 第二个测试村落地图场景（阶段 0.8 多场景衔接）
## 村B = 第一个 city_layout 算法驱动的 HD-2D 村（2026-09-14 全面 HD-2D 化）
const _VILLAGE_MAP_B_SCENE: PackedScene = preload("res://modules/world/scenes/maps/hd2d_village_b.tscn")
## 道路地图场景（阶段 0.8 村落间道路）
const _ROAD_MAP_SCENE: PackedScene = preload("res://modules/world/scenes/maps/road_a_b.tscn")
## 测试大建筑内部地图场景（阶段 0.9.5 传送切换）
const _MEGA_INTERIOR_SCENE: PackedScene = preload("res://modules/world/scenes/maps/mega_interior.tscn")
## 遭遇战战场地图场景（已退役为 dev 验证图，出征与领地架构 §4.3：进图不自动开战）
const _BATTLEFIELD_MAP_SCENE: PackedScene = preload("res://modules/world/scenes/maps/hd2d_battlefield.tscn")
const _RESOURCE_W_MAP_SCENE: PackedScene = preload("res://modules/world/scenes/maps/hd2d_resource_w.tscn")
const _RESOURCE_E_MAP_SCENE: PackedScene = preload("res://modules/world/scenes/maps/hd2d_resource_e.tscn")
const _BATTLEFIELD_2D_MAP_SCENE: PackedScene = preload("res://modules/world/scenes/maps/battlefield.tscn")
## 守城战战场地图场景（右端城墙+波次敌军，接在遭遇战之后）
const _SIEGE_MAP_SCENE: PackedScene = preload("res://modules/world/scenes/maps/siege_battlefield.tscn")
## 森林附属区域场景（阶段 F）
const _FOREST_ZONE_SCENE: PackedScene = preload("res://modules/world/scenes/maps/forest_zone.tscn")
# HD-2D 街景图（3D 原型接入验证场；静态布景，玩家 2D 实体浮于 3D 街景之上）
const _HD2D_STREET_SCENE: PackedScene = preload("res://modules/world/scenes/maps/hd2d_street.tscn")
## L1 八城邦聚落场景（P5 进城闭环；tools/worldgen/l1/settlement_mapgen.py 产出，
## map_id 与 l1_world.json 的 settlement.map_id 一一对应）
const _L1_SETTLEMENT_SCENES: Array[PackedScene] = [
	preload("res://modules/world/scenes/maps/l1_settlement_00.tscn"),
	preload("res://modules/world/scenes/maps/l1_settlement_01.tscn"),
	preload("res://modules/world/scenes/maps/l1_settlement_02.tscn"),
	preload("res://modules/world/scenes/maps/l1_settlement_03.tscn"),
	preload("res://modules/world/scenes/maps/l1_settlement_04.tscn"),
	preload("res://modules/world/scenes/maps/l1_settlement_05.tscn"),
	preload("res://modules/world/scenes/maps/l1_settlement_06.tscn"),
	preload("res://modules/world/scenes/maps/l1_settlement_07.tscn"),
]
## 玩家火柴人实体场景（2026-08 收敛：经 UnitsAPI 常量引用，替代直接 preload 内部路径）
const _UnitsApiScript: GDScript = preload("res://modules/units/api.gd")
const _STICKMAN_ENTITY_SCENE: PackedScene = _UnitsApiScript.STICKMAN_ENTITY_SCENE

## 道路地图 ID（主街 -> 村落 B）
const ROAD_MAP_ID := "road_a_b"
## 第二个测试村落地图 ID
const VILLAGE_B_MAP_ID := "village_b"
## 测试大建筑内部地图 ID
const MEGA_INTERIOR_MAP_ID := "mega_interior"
## 战场地图 ID（HD-2D 城郊战场，主街东门旅行链可达）
const BATTLEFIELD_MAP_ID := "battlefield"
const RESOURCE_W_MAP_ID := "hd2d_resource_w"
const RESOURCE_E_MAP_ID := "hd2d_resource_e"
## 旧 2D 战场保留为 dev 空旷演练场：战斗/AI 测试与 dev 探针的开机图
## （测试需要 2D 空旷初始图 + 秒级开机；不进任何旅行链）
const BATTLEFIELD_2D_MAP_ID := "battlefield_2d"
## 守城战战场地图 ID（右端城墙+波次敌军）
const SIEGE_MAP_ID := "siege_battlefield"
## 森林附属区域地图 ID（阶段 F）
const FOREST_ZONE_MAP_ID := "forest_zone"
const HD2D_STREET_MAP_ID := "hd2d_street"
## 新游戏开局主场景（创始人 2026-09-14：启动直连 HD-2D 主街，不再加载村A旧图；
## 村A保留注册仅供调试，旅行链/出生链全部改挂本图）
const START_MAP_ID := HD2D_STREET_MAP_ID
## 启动图覆盖（测试/开发用，仿 SaveManager.boot_load_slot 模式）：非空时
## _load_start_village 加载它而不是 START_MAP_ID。集成测试测 2D 村庄玩法
## （工位/招兵/战斗…）需要以 village_a 为初始图（含设施生成），显式声明。
var boot_map_id_override: String = ""
## 玩家初始 X 位置（世界原点，土路正负对称各 40 格）
const PLAYER_SPAWN_X: float = 0.0
## NPC 村民数量（小镇生活批次 4 [提案/待定]：起步小镇人口 10——配比在岗
## 铁匠 1 + 伐木 3 + 矿工 3 = 7，余 3 待业闲逛；配额见 professions.tres quota）。
## 性能基准 196 单位远未触顶，10 无性能顾虑。
const NPC_COUNT: int = 10

# ─────────────────────────────── 建造系统（§15 阶段 0.4）────────────────────────────────

## 是否已加载过初始地图（用于区分初始加载 vs 地图切换；map_flow 助手经 _host 读写）
@warning_ignore("unused_private_class_variable")
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

## 背包服务（InventoryService；装备→附身实体桥接，SystemSetup 装配）
var inventory_service: Node = null
## 背包界面（InventoryScreen；E 键开关，SystemSetup 装配；shortcuts 助手经 _host 读写）
@warning_ignore("unused_private_class_variable")
var _inventory_screen: Control = null
## 角色属性面板（StatsScreen；C 键开关，SystemSetup 装配；shortcuts 助手经 _host 读写）
@warning_ignore("unused_private_class_variable")
var _stats_panel: Control = null

# ─────────────────────────────── 附身系统（§15 阶段 0.7）────────────────────────────────
## PossessionInterface 实例引用（运行时由 SystemSetup 装配）
var _possession_interface: Node = null
## PossessPanel 实例引用（运行时由 SystemSetup 装配）
var _possess_panel: Control = null

# ─────────────────────────────── 资源系统（P0-9）────────────────────────────────
## ResourcesApi 实例引用（运行时由 SystemSetup 装配）
var _resources_api: Node = null

# ─────────────────────────────── 征服系统（出征与领地循环）───────────────────────────────
## ExpansionApi 实例引用（运行时由 SystemSetup 装配）
var _expansion_api: Node = null
## ConquestManager 实例引用（运行时由 SystemSetup 装配）
var _conquest_manager: Node = null

# ─────────────────────────────── 招兵与人口（游戏循环深化批次 1）───────────────────────────────
## RecruitManager 实例引用（运行时由 SystemSetup 装配；招兵经 OrganizationApi 转发）
var _recruit_manager: Node = null

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
## 边界检测器（SystemSetup 装配；map_flow 助手经 _host 读写）
@warning_ignore("unused_private_class_variable")
var _boundary_detector: Node = null
@warning_ignore("unused_private_class_variable")
var _strategic_map: Node = null
@warning_ignore("unused_private_class_variable")
var _strategic_map_l3: Node = null
# ─────────────────────────────── 游玩 UI（SystemSetup 跨脚本写入，故加忽略）────────────────────────────────
@warning_ignore("unused_private_class_variable")
var _hover_indicator: Control = null
@warning_ignore("unused_private_class_variable")
var _middle_scroll_overlay: Control = null
# ─────────────────────────────── 阶段 E 游玩 UI ────────────────────────────────
var _resource_bar: Control = null
var _build_menu: Control = null
## 编制管理窗口（运行时由 SystemSetup 装配到 UIRoot.ModalOverlay）
var _formation_panel: Control = null
## 组织管理窗口（运行时由 SystemSetup 装配到 UIRoot.ModalOverlay）
var _org_panel: Control = null
## 上报叙事器（运行时由 SystemSetup 装配为常驻子节点；三型上报 + 补位事件 → 通知 feed）
var _org_report_narrator: Node = null
## 设置菜单（运行时由 SystemSetup 装配到 UIRoot，齿轮/ESC 打开）
var _settings_menu_panel: Control = null
## 暂停菜单（运行时由 SystemSetup 装配到 UIRoot，ESC 打开；ESC 语义统一在 GameRoot 处理）
var _pause_menu_panel: Control = null
## 世界加载覆盖层（启动加载期显示，世界就绪淡出）
var _world_loading_overlay: Control = null

# ─────────────────────────────── 存档系统（SaveHandler 跨脚本读写，故加忽略）────────────────────────────────
## 是否有存档待加载（读档入口标记；map_flow 助手经 _host 读写）
@warning_ignore("unused_private_class_variable")
var _pending_save_load: bool = false
## 读档时缓存的 map_id（从 save_meta 读取）
@warning_ignore("unused_private_class_variable")
var _cached_load_map_id: String = ""
## 存档 UI 面板
@warning_ignore("unused_private_class_variable")
var _save_panel: Control = null

# ─────────────────────────────── 跨图携带（带队出征）────────────────────────────────
## travel_started 时收集的编队快照（跨图携带），map_loaded 后恢复；map_flow 助手经 _host 读写
@warning_ignore("unused_private_class_variable")
var _pending_squad_snapshots: Array = []

## 地图生命周期响应助手（逻辑下沉；状态仍在本类，助手经 _host 回引读写）
var _map_flow: RefCounted = null
## 快捷键/模态助手（逻辑下沉；面板/服务引用仍在本类，助手经 _host 回引读写）
var _shortcuts: RefCounted = null


# ─────────────────────────────── 生命周期 ────────────────────────────────

## 启动装配总段数（Minecraft 式模块计数进度：7 段装配 + 读档/世界生成 + 地图就绪）
const BOOT_STAGES: int = 9
## 启动期世界生成阶段（8/9 细分文字 + 分帧让步的开关；游戏内切图关闭——
## 不把全屏加载盖回到正在玩的画面上，让帧本身照做只不刷文字）
var _boot_world_phase: bool = false
## 世界生成子阶段总数（初始建筑/存档恢复/村庄设施/村民）——副进度条按此切分
const WORLD_SUB_PHASES: int = 4
## 当前世界生成子阶段序号（1 起）与名称，供副进度条映射与文字刷新
var _world_sub_idx: int = 0
var _world_sub_label: String = ""


func _ready() -> void:
	# 两个 RefCounted 助手最先构造（早于一切信号连接/装配步骤；_init 仅存宿主回引）
	_map_flow = _MapFlowScript.new(self)
	_shortcuts = _ShortcutsScript.new(self)
	# 冻结手绘 UI 沸腾换帧（玩法场景素描控件群庞大，换帧级联拖帧率；
	# 主菜单 _ready 显式恢复 true）
	SketchTextures.animation_enabled = false
	# 加入 game_root group（供 SelectionSystem 等查找相机等服务）
	add_to_group("game_root")
	# 注册 InputDispatcher 到 PlayerControlAPI（units 经 api 获取，不反向依赖 world）
	if input_dispatcher != null:
		PlayerControlAPI.register_input_dispatcher(input_dispatcher)
	# 世界加载覆盖层：先挂上并等到**真正绘制出首帧**再开始重活——同步装配期
	# 无帧渲染，不等首帧覆盖层永远画不出来（旧版"两屏加载夹 10 秒灰屏"根因）
	_setup_world_loading_overlay()
	_show_loading("正在启动…", 0.0)
	await _yield_frame()
	# 分段装配：每段先更新文字/进度条 → 等一帧画出来 → 干重活；进度真实推进。
	# 每段带子步骤表（下条=阶段内细分），故 1/3~7 段下条也连续可见（不再整段隐藏）。
	await _stage(1, "挂载子模块", _mount_module_steps())
	await _setup_systems_staged()
	await _stage(3, "接入存档系统", _save_system.setup_steps(self))
	await _stage(4, "接入传送系统", [["订阅传送事件", _setup_travel_system]])
	await _stage(5, "初始化世界生成器", [["绑定世界生成根", _setup_worldgen]])
	await _stage(6, "校验场景与事件绑定", [
		["校验子节点", _validate_children],
		["绑定事件", _bind_event_bus],
	])
	await _stage(7, "注册默认地图", [
		["注册地图场景与出口", _register_default_maps],
		["设置默认时间速度", _set_default_time_speed],
	])
	# 通知游戏开始
	if EventBus:
		EventBus.game_started.emit()
	# 加载初始村落（延迟一帧确保 SceneLoader 就绪；读档/世界生成显示 8/9，
	# 地图加载完成后 _on_map_loaded 视世界就绪淡出覆盖层）
	_boot_world_phase = true
	call_deferred("_load_start_village")


## 让一帧（「先画再干」的等帧原语，五处启动/切图等帧统一出口）。
## headless 下渲染服务器不绘制帧、frame_post_draw 永不发射——不短路则启动协程
## 在首个等帧点永久挂起、子系统全部不装配（2026-09-11 回归：启动分帧合入后
## 全部集成/冒烟测试崩，game_root 装配未执行即退场）。
func _yield_frame() -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw


## 单段装配：更新进度文字/进度条 → 等渲染出这一帧 → 执行子步骤。
## `steps` = 该段的子步骤表 [[子标签, Callable], ...]：逐项执行，每项先刷文字
## （含子标签）/下条再让一帧后干活，下条值 = 已完成步数/总步数。单元素表 = 该段
## 只有一次原子推进，副条仍会完整扫过本段（不再整段隐藏）。headless 下
## `_yield_frame` 短路，等价同步执行（测试语义不变）。
func _stage(idx: int, label: String, steps: Array) -> void:
	var total: int = maxi(1, steps.size())
	for i in steps.size():
		var step: Array = steps[i]
		_show_loading("%s…（%d/%d）· %s" % [label, idx, BOOT_STAGES, str(step[0])],
				float(idx) / float(BOOT_STAGES), float(i) / float(total))
		await _yield_frame()
		(step[1] as Callable).call()
	_show_loading("%s…（%d/%d）" % [label, idx, BOOT_STAGES],
			float(idx) / float(BOOT_STAGES), 1.0)


## 阶段 2 专用：装配界面与子系统（29 个 _setup_* 步骤）分帧执行。
## 原先是整段同步调用——实测 2.2~3.2s 内转圈与文字全定格；分帧后每步一帧、
## 副进度条随步推进，最坏单次卡顿从「整段」降为「最重的那一步」。
func _setup_systems_staged() -> void:
	var steps: Array = _bootstrap.setup_steps(self)
	var total: int = maxi(1, steps.size())
	_show_loading(_stage2_msg(""), 2.0 / float(BOOT_STAGES), 0.0)
	await _yield_frame()
	for i in steps.size():
		var step: Array = steps[i]
		_show_loading(_stage2_msg(str(step[0])), 2.0 / float(BOOT_STAGES), float(i) / float(total))
		await _yield_frame()
		(step[1] as Callable).call()
	_bootstrap.finish_setup()
	_show_loading(_stage2_msg(""), 2.0 / float(BOOT_STAGES), 1.0)


## 阶段 2 的文字（step_label 为空 = 不带细分名）
func _stage2_msg(step_label: String) -> String:
	if step_label.is_empty():
		return "装配界面与子系统…（2/%d）" % BOOT_STAGES
	return "装配界面与子系统…（2/%d）· %s" % [BOOT_STAGES, step_label]


## 世界生成子阶段：细化 8/9 的阶段文字并让一帧（分帧生成，转圈持续转动）。
## 仅启动期刷文字；游戏内切图静默让帧（两态都让，动画在两种场景下都不断流）。
## 副进度条 = 子阶段序号切片 + 子阶段内细分（_world_sub_progress），单调不回退。
func _world_sub_phase(label: String) -> void:
	_world_sub_label = label
	_world_sub_idx += 1
	if _boot_world_phase:
		_show_loading("正在生成世界…（%d/%d）· %s" % [BOOT_STAGES - 1, BOOT_STAGES, label],
				float(BOOT_STAGES - 1) / float(BOOT_STAGES),
				float(_world_sub_idx - 1) / float(WORLD_SUB_PHASES))
	await _yield_frame()


## 世界生成子阶段内部细分进度（逐个建筑/逐个村民/逐个资源点等）：副条在当前子阶段
## 切片内推进。`detail` 非空时在阶段文字后补「· detail」（同一套下条，不新造 UI）。
func _world_sub_progress(done: int, total: int, detail: String = "") -> void:
	if not _boot_world_phase or total <= 0:
		return
	var sub: float = (float(_world_sub_idx - 1) + float(done) / float(total)) / float(WORLD_SUB_PHASES)
	var msg: String = "正在生成世界…（%d/%d）· %s" % [
			BOOT_STAGES - 1, BOOT_STAGES, _world_sub_label]
	if not detail.is_empty():
		msg += " · " + detail
	_show_loading(msg, float(BOOT_STAGES - 1) / float(BOOT_STAGES), sub)


## 「村庄设施」子阶段：资源点放置逐项进度（下条文字「布置资源点 n/m」）。
func _world_sub_phase_resources(placed: int, target: int) -> void:
	_world_sub_progress(placed, target, "布置资源点 %d/%d" % [placed, target])


## 子模块挂载步骤表（阶段 1 下条细分）：每项 = [子标签, 可调用]。
## 顺序即依赖顺序（SystemSetup 先挂，其余子模块 setup 依赖它）。
func _mount_module_steps() -> Array:
	return [
		["界面与子系统", _mount_bootstrap],
		["存档子系统", _mount_save_handler],
		["传送子系统", _mount_travel_handler],
		["世界生成子系统", _mount_worldgen],
	]


## 挂一个脚本化子节点（Node.new + set_script + add_child），返回实例。
func _mount_scripted_child(script: GDScript, node_name: String) -> Node:
	var n := Node.new()
	n.set_script(script)
	n.name = node_name
	add_child(n)
	return n


func _mount_bootstrap() -> void:
	_bootstrap = _mount_scripted_child(_SystemSetupScript, "SystemSetup")


func _mount_save_handler() -> void:
	_save_system = _mount_scripted_child(_SaveHandlerScript, "SaveHandler")


func _mount_travel_handler() -> void:
	_travel_system = _mount_scripted_child(_TravelHandlerScript, "TravelHandler")


func _mount_worldgen() -> void:
	_worldgen = _mount_scripted_child(_InitialContentScript, "InitialContent")


## 阶段 4/5 的单次原子装配与阶段 7 的时间速度设置（供 _stage 步骤表引用）。
func _setup_travel_system() -> void:
	_travel_system.setup(self)


func _setup_worldgen() -> void:
	_worldgen.setup(self)


func _set_default_time_speed() -> void:
	if TimeManager:
		TimeManager.set_speed(TimeManager.Speed.X1)


# ─────────────────────────────── 系统引用访问（供测试/UI 使用）────────────────────────────────

## 获取 CombatApi 引用（供测试用）
func get_combat_api() -> Node:
	return _combat_api


## 获取 ResourcesApi 引用（供测试用）
func get_resources_api() -> Node:
	return _resources_api


## 征服流程管理器（出征/占领/收益；测试与跨模块消费走 expansion/api.gd）
func get_conquest_manager() -> Node:
	return _conquest_manager


## 招兵与人口管理器（测试/调试用；玩家交互走 organization/api.gd 转发）
func get_recruit_manager() -> Node:
	return _recruit_manager


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


## 获取组织管理窗口引用（供测试用）
func get_org_panel() -> Control:
	return _org_panel


## 获取上报叙事器引用（供测试用）
func get_org_report_narrator() -> Node:
	return _org_report_narrator


## 打开/关闭组织管理窗口（GlobalHUD 组织按钮调用）
func toggle_org_panel() -> void:
	if _org_panel != null and _org_panel.has_method("toggle"):
		_org_panel.toggle()


## 获取设置菜单引用（供测试用）
func get_settings_menu_panel() -> Control:
	return _settings_menu_panel


## 打开/关闭设置菜单（左上角齿轮按钮 / 暂停菜单「设置」调用）。
## 经模态栈开合（层键 SETTINGS）；无栈环境回退面板自身 toggle。
## 逻辑在 game_root_shortcuts.gd（薄壳转发，测试直调签名不变）。
func toggle_settings_menu() -> void:
	_shortcuts.toggle_settings_menu()


## 获取暂停菜单引用（供测试/装配）
func get_pause_menu_panel() -> Control:
	return _pause_menu_panel


## 启动一场测试战斗（供遭遇战/测试调用）。
## attacker_units / defender_units: StickmanEntity 数组
## player_faction: 玩家阵营（victory 语义基准；默认攻方。守城战等玩家为守方的战斗传 2）
## 返回 BattleInstance（失败返回 null）
## 统一走 CombatApi（不再直调 battle_director，2026-08 审计收敛）
func start_test_battle(attacker_units: Array, defender_units: Array,
		player_faction: int = 1) -> Node:
	if _combat_api == null or not _combat_api.has_method("start_battle"):
		push_warning("[GameRoot] CombatApi 未就绪")
		return null
	var map: Node2D = get_current_map()
	if map == null:
		push_warning("[GameRoot] 当前无地图，无法启动战斗")
		return null
	return _combat_api.start_battle(map, attacker_units, defender_units, player_faction)


# ─────────────────────────────── 地图注册与加载 ────────────────────────────────

func _register_default_maps() -> void:
	if scene_loader == null or not scene_loader.has_method("register_map"):
		return
	# 注册地图场景
	scene_loader.register_map(ROAD_MAP_ID, _ROAD_MAP_SCENE, WorldAPI.MapType.ROAD)
	scene_loader.register_map(VILLAGE_B_MAP_ID, _VILLAGE_MAP_B_SCENE, WorldAPI.MapType.VILLAGE)
	scene_loader.register_map(MEGA_INTERIOR_MAP_ID, _MEGA_INTERIOR_SCENE, WorldAPI.MapType.MEGA_INTERIOR)
	# 阶段 F：注册遭遇战战场地图（2026-09-14 HD-2D 重建：主街东门外城郊战场，
	# 旧 battlefield.tscn 退役 dev 验证图）
	scene_loader.register_map(BATTLEFIELD_MAP_ID, _BATTLEFIELD_MAP_SCENE, WorldAPI.MapType.BATTLEFIELD)
	# 城外资源图两张（创始人 2026-09-15：左右城墙各自传送到一个资源点地图）——
	# 战场式开阔野地变体，resource_gen 全域密布；城门选项框直达，内缘触发器回城
	scene_loader.register_map(RESOURCE_W_MAP_ID, _RESOURCE_W_MAP_SCENE, WorldAPI.MapType.BATTLEFIELD)
	scene_loader.register_map(RESOURCE_E_MAP_ID, _RESOURCE_E_MAP_SCENE, WorldAPI.MapType.BATTLEFIELD)
	# 旧 2D 战场 = dev 空旷演练场（战斗/AI 测试开机图，不进旅行链）
	scene_loader.register_map(BATTLEFIELD_2D_MAP_ID, _BATTLEFIELD_2D_MAP_SCENE, WorldAPI.MapType.BATTLEFIELD)
	# 守城战战场地图（遭遇战右出即达；城防布景+波次敌军由 SiegeDirector 组织）
	scene_loader.register_map(SIEGE_MAP_ID, _SIEGE_MAP_SCENE, WorldAPI.MapType.BATTLEFIELD)
	# 阶段 F：注册森林附属区域
	scene_loader.register_map(FOREST_ZONE_MAP_ID, _FOREST_ZONE_SCENE, WorldAPI.MapType.VILLAGE)
	# HD-2D 街景图（创始人 2026-09-14：接入游戏内场景；设置面板「调试→测试地图」可选）
	scene_loader.register_map(HD2D_STREET_MAP_ID, _HD2D_STREET_SCENE, WorldAPI.MapType.VILLAGE)
	# P5/D1：注册 L1 八城邦聚落图（城内边界不配 register_map_exit——玩家顶到边界
	# 3 秒由 MapBoundaryDetector 开 L1 大图回战略图，双击下一城再进）
	for i: int in _L1_SETTLEMENT_SCENES.size():
		scene_loader.register_map("l1_settlement_%02d" % i, _L1_SETTLEMENT_SCENES[i], WorldAPI.MapType.VILLAGE)
	# 配置地图出口（步行衔接，详见 §6.2）。
	# 2026-09-14 启动直连：旅行链原挂在 village_a，现全部改挂 hd2d_street
	# （新主场景）；村A 保留注册仅供调试，不再承担主场景职责。
	scene_loader.register_map_exit(HD2D_STREET_MAP_ID, WorldAPI.EntrySide.RIGHT, ROAD_MAP_ID, WorldAPI.EntrySide.LEFT)
	scene_loader.register_map_exit(ROAD_MAP_ID, WorldAPI.EntrySide.LEFT, HD2D_STREET_MAP_ID, WorldAPI.EntrySide.RIGHT)
	scene_loader.register_map_exit(ROAD_MAP_ID, WorldAPI.EntrySide.RIGHT, VILLAGE_B_MAP_ID, WorldAPI.EntrySide.LEFT)
	scene_loader.register_map_exit(VILLAGE_B_MAP_ID, WorldAPI.EntrySide.LEFT, ROAD_MAP_ID, WorldAPI.EntrySide.RIGHT)
	# 阶段 F：健全地图系统（任何地图可步行回村，链式衔接：村↔战场↔森林）
	# （主街↔战场双缘衔接走两图场景内 ChunkTrigger 硬目标——street 的西出
	# 实际挂 road_a_b，此处不配 street 左出战场，防与场景触发器语义打架）
	scene_loader.register_map_exit(BATTLEFIELD_MAP_ID, WorldAPI.EntrySide.LEFT, HD2D_STREET_MAP_ID, WorldAPI.EntrySide.RIGHT)
	# 守城图（独立区域）左出回主街：仅作为 travel 目标登记；平时进出走村口选项
	scene_loader.register_map_exit(SIEGE_MAP_ID, WorldAPI.EntrySide.LEFT, HD2D_STREET_MAP_ID, WorldAPI.EntrySide.RIGHT)
	# 恢复原链：遭遇战场右出通森林（守城图独立后不再串链）
	scene_loader.register_map_exit(BATTLEFIELD_MAP_ID, WorldAPI.EntrySide.RIGHT, FOREST_ZONE_MAP_ID, WorldAPI.EntrySide.LEFT)
	scene_loader.register_map_exit(FOREST_ZONE_MAP_ID, WorldAPI.EntrySide.LEFT, BATTLEFIELD_MAP_ID, WorldAPI.EntrySide.RIGHT)
	# 资源图↔主街双缘登记（西图接主街西门/东图接主街东门）：城门选项框的
	# 目的地按钮与城外舆图读出口表生成（hd2d_gate_prompt），内缘触发器回程
	# 也走这里
	scene_loader.register_map_exit(HD2D_STREET_MAP_ID, WorldAPI.EntrySide.LEFT, RESOURCE_W_MAP_ID, WorldAPI.EntrySide.RIGHT)
	scene_loader.register_map_exit(HD2D_STREET_MAP_ID, WorldAPI.EntrySide.RIGHT, RESOURCE_E_MAP_ID, WorldAPI.EntrySide.LEFT)
	scene_loader.register_map_exit(RESOURCE_W_MAP_ID, WorldAPI.EntrySide.RIGHT, HD2D_STREET_MAP_ID, WorldAPI.EntrySide.LEFT)
	scene_loader.register_map_exit(RESOURCE_E_MAP_ID, WorldAPI.EntrySide.LEFT, HD2D_STREET_MAP_ID, WorldAPI.EntrySide.RIGHT)


## 切图：注销已释放的音效空间化宿主（新图加载时会在 _on_map_loaded 重新注册）
## 逻辑在 game_root_map_flow.gd（薄壳转发，信号连接面不变）。
func _on_sfx_map_unloaded(_map_id: String) -> void:
	_map_flow._on_sfx_map_unloaded(_map_id)


func _load_start_village() -> void:
	_map_flow._load_start_village()


## 开局图唯一出口：boot 覆盖（测试声明初始图）优先，否则启动直连主图。
## 新游戏开局与存档缺地图信息兜底（SaveHandler）共用，保证两路取图一致。
## 逻辑在 game_root_map_flow.gd（薄壳转发，SaveHandler 直调签名不变）。
func _start_map_id_for_fallback() -> String:
	return _map_flow._start_map_id_for_fallback()


## 显示世界加载覆盖（启动加载期）。ratio = 总阶段进度；sub_ratio = 当前阶段
## 内部细分进度（<0 = 该阶段无细分，副进度条隐藏）。
func _show_loading(message: String, ratio: float = -1.0, sub_ratio: float = -1.0) -> void:
	if _world_loading_overlay != null and _world_loading_overlay.has_method("show_loading"):
		_world_loading_overlay.show_loading(message, ratio, sub_ratio)


## 装配世界加载覆盖层：优先认领启动跳板（loading_screen）挂在**场景树根**的
## 常驻加载层（跨场景切换存活——交接零缝隙）；直启（编辑器 F5/测试）无跳板时
## 自建兜底（game_root 自身高层 CanvasLayer，layer=10，盖住 UIRoot）。
func _setup_world_loading_overlay() -> void:
	if _world_loading_overlay != null:
		return
	for n in get_tree().get_nodes_in_group("world_loading_overlay"):
		if is_instance_valid(n):
			_world_loading_overlay = n
			return
	var layer := CanvasLayer.new()
	layer.name = "WorldLoadingLayer"
	layer.layer = LayerOrder.WORLD_LOADING
	add_child(layer)
	var ov := UIKit.full_rect(_WorldLoadingOverlayScript, "WorldLoadingOverlay")
	layer.add_child(ov)
	_world_loading_overlay = ov


## travel_started 回调：旧图卸载前快照全部编队（跨图携带，带队出征）。
## 逻辑在 game_root_map_flow.gd（薄壳转发，信号连接面不变）。
func _on_travel_started(_from_id: String, _to_id: String, _mode: int) -> void:
	_map_flow._on_travel_started(_from_id, _to_id, _mode)


## 通用地图加载回调（初始加载 + 地图切换共用）
## 逻辑在 game_root_map_flow.gd（薄壳转发；信号触发走 fire-and-forget，等价原协程语义）。
func _on_map_loaded(map_id: String, map_type: int) -> void:
	_map_flow._on_map_loaded(map_id, map_type)


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

## 外部调用：启动读档流程（返回 false = 拒读，见 SaveHandler.load_game_from_slot）
func load_game_from_slot(slot_index: int) -> bool:
	if _save_system != null and _save_system.has_method("load_game_from_slot"):
		return _save_system.load_game_from_slot(slot_index)
	return false


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

## 快捷键总入口（由子节点 ShortcutGate 转发，暂停期照常触发；本节点自身
## PAUSABLE，引擎暂停期 _unhandled_input 不再触发，故不经标准回调接入口）。
## 全分派逻辑在 game_root_shortcuts.gd（薄壳转发，ShortcutGate 调用签名不变）。
func handle_shortcuts(event: InputEvent) -> void:
	_shortcuts.handle_shortcuts(event)


## 开关背包界面（E 键）：Hotbar / StatsScreen 调用。逻辑在 game_root_shortcuts.gd。
func toggle_inventory() -> void:
	_shortcuts.toggle_inventory()


## 开关角色属性面板（C 键）：Hotbar 调用。逻辑在 game_root_shortcuts.gd。
func toggle_stats_panel() -> void:
	_shortcuts.toggle_stats_panel()


## 打开功能空面板（经 ui_global/placeholders，系统落地后替换真实面板）。
## 快捷键（K/O/J/L）与暂停菜单「功能」分区共用此入口。
## 逻辑在 game_root_shortcuts.gd（薄壳转发，测试直调签名不变）。
func _open_placeholder_panel(preset_id: String) -> void:
	_shortcuts._open_placeholder_panel(preset_id)


## ESC 语义（统一模态栈逐层退栈）：有模态 → 退栈顶；无模态 → 开暂停菜单。
## 附身模式返回 false（ESC 留给退出附身，不消费）。
## 逻辑在 game_root_shortcuts.gd（薄壳转发，测试直调签名不变）。
func _handle_escape() -> bool:
	return _shortcuts._handle_escape()
