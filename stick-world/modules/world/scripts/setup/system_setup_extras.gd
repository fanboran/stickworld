extends RefCounted
## SystemSetup 玩家交互与环境装配助手 —— 承接宿主分帧步骤表中的函数体
## （附身界面·面板 / 探索交互 / 游戏 UI / 建造菜单 / 后处理 / 地图过渡 / 单位 LOD）
## 及调试绘制器注册、Demo 目标链装配。
##
## 纪律：
## - 状态全部留在宿主（system_setup.gd），本助手经 _host 回引读写，不另立状态；
## - 跨模块 preload 属 composition root 豁免、全部留在宿主，此处经 _host 取用；
## - 各方法与宿主同名壳逐一对应（宿主壳只做一行转发），行为与拆分前逐行等价。

var _host: Node  ## SystemSetup 宿主（无 class_name，动态回引）


func bind(host: Node) -> void:
	_host = host


# ─────────────────────────────── 附身系统装配（§15 阶段 0.7）────────────────────────────────

## 实例化 PossessionInterface，注册为 POSSESS 模式 handler。
func _setup_possession_interface() -> void:
	var pi := Node.new()
	pi.set_script(_host._PossessionInterfaceScript)
	pi.name = "PossessionInterface"
	_host._root.add_child(pi)
	_host._root._possession_interface = pi
	# 注入 GameRoot（替代父链反查）
	if pi.has_method("setup"):
		pi.setup(_host._root)
	# 注册为 POSSESS handler
	if _host._root.input_dispatcher != null and _host._root.input_dispatcher.has_method("register_handler"):
		_host._root.input_dispatcher.register_handler(PlayerControlAPI.Mode.POSSESS, pi)


## 给场景中已存在的 PossessPanel 占位节点挂脚本，并调用 setup。
func _setup_possess_panel() -> void:
	if _host._root.ui_root == null:
		return
	var mp: Control = _host._root.ui_root.get_node_or_null("ModePanel")
	if mp == null:
		return
	var pp: Control = mp.get_node_or_null("PossessPanel")
	if pp == null:
		return
	pp.set_script(_host._PossessPanelScript)
	_host._root._possess_panel = pp
	_host.call_deferred("_setup_possess_panel_deferred")


func _setup_possess_panel_deferred() -> void:
	if _host._root._possess_panel == null:
		return
	if _host._root._possess_panel.has_method("setup"):
		_host._root._possess_panel.setup(_host._root)


## 注册 EXPLORE 模式 handler（不立即激活，等地图加载完再 set_mode）。
func _register_explore_handler() -> void:
	if _host._root.input_dispatcher == null or not _host._root.input_dispatcher.has_method("register_handler"):
		return
	var handler := Node.new()
	handler.set_script(_host._ExploreHandlerScript)
	handler.name = "ExploreHandler"
	_host._root.add_child(handler)
	# 注入 GameRoot（替代父链反查）
	if handler.has_method("setup"):
		handler.setup(_host._root)
	_host._root.input_dispatcher.register_handler(PlayerControlAPI.Mode.EXPLORE, handler)


# ─────────────────────────────── 游玩 UI ────────────────────────────────

func _setup_game_ui() -> void:
	# （possessed 玩家白四角框已归并入 SelectionSystem._draw，2026-09-14）
	# 鼠标悬停方框
	_host._root._hover_indicator = UIKit.widget(_host._HoverIndicatorScript, "HoverIndicator")
	_host._root._hover_indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _host._root._hover_indicator.has_method("setup"):
		_host._root._hover_indicator.setup(_host._root)
	if _host._root.ui_root != null:
		_host._root.ui_root.add_to_slot("HudOverlay", _host._root._hover_indicator)
	else:
		_host._root.add_child(_host._root._hover_indicator)
	# 中键滚动图标
	_host._root._middle_scroll_overlay = UIKit.widget(_host._MiddleScrollOverlayScript, "MiddleScrollOverlay")
	_host._root._middle_scroll_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _host._root._middle_scroll_overlay.has_method("setup"):
		_host._root._middle_scroll_overlay.setup(_host._root.camera_rig)
	if _host._root.ui_root != null:
		_host._root.ui_root.add_to_slot("HudOverlay", _host._root._middle_scroll_overlay)
	else:
		_host._root.add_child(_host._root._middle_scroll_overlay)


# ─────────────────────────────── 阶段 E：建造菜单装配 ────────────────────────────────

## 实例化建造菜单并挂到 UIRoot，延迟 setup 等 ConstructionManager 就绪。
func _setup_build_menu() -> void:
	if _host._root.ui_root == null:
		return
	# P1 + P2：全屏 UI 根一律用 UIKit.full_rect（强制 FULL_RECT，杜绝"Control.new()
	# 丢 anchor → 按钮静默不可见"），并挂到 HudOverlay 槽（槽位化路由）
	_host._root._build_menu = UIKit.full_rect(_host._BuildMenuScript, "BuildMenu")
	_host._root.ui_root.add_to_slot("HudOverlay", _host._root._build_menu)
	_host.call_deferred("_setup_build_menu_deferred")


func _setup_build_menu_deferred() -> void:
	if _host._root._build_menu == null:
		return
	if _host._root._build_menu.has_method("setup"):
		_host._root._build_menu.setup(_host._root)


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
	DebugApi.register_drawer("grid_drawer", Callable(_host._DebugDrawers, "draw_grid"))
	DebugApi.register_drawer("barrier_drawer", Callable(_host._DebugDrawers, "draw_barriers"))
	DebugApi.register_drawer("building_drawer", Callable(_host._DebugDrawers, "draw_buildings"))
	DebugApi.register_drawer("ground_line_drawer", Callable(_host._DebugDrawers, "draw_ground_lines"))
	DebugApi.register_drawer("chunk_trigger_drawer", Callable(_host._DebugDrawers, "draw_chunk_triggers"))
	DebugApi.register_drawer("entity_state_drawer", Callable(_host._DebugDrawers, "draw_entity_states"))
	DebugApi.register_drawer("entity_collider_drawer", Callable(_host._DebugDrawers, "draw_entity_colliders"))
	DebugApi.register_drawer("terrain_grid", Callable(_host._DebugDrawers, "draw_terrain_grid"))
	DebugApi.register_drawer("resource_nodes", Callable(_host._DebugDrawers, "draw_resource_nodes"))
	DebugApi.register_drawer("building_names", Callable(_host._DebugDrawers, "draw_building_names"))
	DebugApi.register_drawer("world_ruler", Callable(_host._DebugDrawers, "draw_world_ruler"))
	DebugApi.register_drawer("entity_info", Callable(_host._DebugDrawers, "draw_entity_info"))
	# W1 观测接线批：TeamAi 姿态 HUD 开关（HUD 本体独立 Control，此注册仅进 F3 复选框族）
	DebugApi.register_drawer("team_ai_hud", Callable(_host._DebugDrawers, "draw_team_ai_hud"))


# ─────────────────────────────── Demo 目标链装配 ────────────────────────────────

## 装配演示目标链（四阶段引导 + 胜利结算）。
## deferred 时机：晚于 _setup_resources_api_deferred（deferred 队列 FIFO），
## 保证初始资源已发放、DemoQuest 的采集基线快照不被初始资源污染。
func _setup_demo_quest_deferred() -> void:
	if _host._root.ui_root == null or _host._root._resources_api == null:
		return
	var panel: Control = _host._QuestPanelScript.new()
	panel.name = "QuestPanel"
	if not _host._root.ui_root.add_to_slot("HudOverlay", panel):
		panel.queue_free()
		return
	# 定位归 zone：top_left_stack 堆叠区（排在资源条之下，见 hud_zone_layout.gd）
	_host._root.ui_root.place_in_zone(&"top_left_stack", panel)
	var quest := Node.new()
	quest.set_script(_host._DemoQuestScript)
	quest.name = "DemoQuest"
	_host._root.add_child(quest)
	quest.setup(panel, _host._root._resources_api, _host._root._construction_api, _host._root.ui_root)


# ─────────────────────────────── 后处理层装配（Demo P3）────────────────────────────────

## 全屏后处理层：暖色分级/太阳炫光/渐晕/色差/颗粒（layer 0.5，压世界不压 UI）。
func _setup_post_process() -> void:
	var layer := PostProcessLayer.new()
	layer.name = "PostProcess"
	_host._root.add_child(layer)
	var env: Node = _host._root.get_node_or_null("EnvironmentSystem")
	if env != null:
		layer.bind_env(env)


# ─────────────────────────────── 转场遮罩装配（Demo P3）────────────────────────────────

## 地图切换黑场转场（travel_started 渐黑 / travel_completed 渐明，零侵入）。
func _setup_map_transition() -> void:
	var overlay := MapTransitionOverlay.new()
	overlay.name = "MapTransition"
	_host._root.add_child(overlay)


# ─────────────────────────────── 单位 LOD 调度装配 ────────────────────────────────

## 创建单位 LOD 调度器（性能优化：混战表现层按相机距离分档节流——48v48 场景下
## 每单位动画采样/程序化叠加/血条重绘是大头）。自动发现模式：注入 GameRoot 后
## 每 10Hz 经 get_current_map() 解析 EntityHost 单位集 + 视口激活相机分档，
## 地图实例变更自动换绑。挂 GameRoot 下持久存在，不随战斗实例生灭；
## headless 无相机时空转（单位保持默认全速，零行为变化）。
func _setup_unit_lod() -> void:
	if _host._root.get_node_or_null("UnitLodDirector") != null:
		return  # 已存在，避免重复添加
	var lod := Node.new()
	lod.set_script(_host._UnitLodDirectorScript)
	lod.name = "UnitLodDirector"
	_host._root.add_child(lod)
	# 自动发现模式：无需外部喂数据，注入宿主后自取地图/单位集/相机
	if lod.has_method("setup"):
		lod.setup(_host._root)
