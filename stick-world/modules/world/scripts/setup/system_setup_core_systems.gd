extends RefCounted
## SystemSetup 核心系统装配助手 —— 承接宿主分帧步骤表中核心系统域各步骤的函数体
## （建造 / 战斗 / 资源 / 框选 / 组织 / 编队 / 战术 / 指挥传输 / 征服 / 招兵 / 上报叙事）。
##
## 纪律：
## - 状态全部留在宿主（system_setup.gd），本助手经 _host 回引读写，不另立状态；
## - 跨模块 preload 属 composition root 豁免、全部留在宿主，此处经 _host 取用；
## - 各方法与宿主同名壳逐一对应（宿主壳只做一行转发），行为与拆分前逐行等价。

var _host: Node  ## SystemSetup 宿主（无 class_name，动态回引）


func bind(host: Node) -> void:
	_host = host


# ─────────────────────────────── 建造系统装配 ────────────────────────────────

## 实例化 ConstructionManager + api.gd 作为子节点，并互相 setup。
## 详见 §15 阶段 0.4。
func _setup_construction_system() -> void:
	# 实例化 ConstructionManager
	var mgr := Node.new()
	mgr.set_script(_host._ConstructionManagerScript)
	mgr.name = "ConstructionManager"
	_host._root.add_child(mgr)
	_host._root._construction_manager = mgr
	# 实例化 api.gd（公共接口契约）
	var api := Node.new()
	api.set_script(_host._ConstructionApiScript)
	api.name = "ConstructionApi"
	_host._root.add_child(api)
	_host._root._construction_api = api
	# api.setup 必须在 manager._ready 后调用（_ready 中初始化 _assigner）
	# 这里用 call_deferred 保证顺序
	_host.call_deferred("_setup_construction_api_deferred")


func _setup_construction_api_deferred() -> void:
	if _host._root._construction_api == null or _host._root._construction_manager == null:
		return
	if not _host._root._construction_api.has_method("setup"):
		return
	_host._root._construction_api.setup(_host._root._construction_manager)
	# 建造完工 → 音效事件（跨模块经 AudioManager 框架，资产未就位时静默）
	if _host._root._construction_api.has_signal("building_completed") and AudioManager != null:
		_host._root._construction_api.building_completed.connect(
				func(_building_id: String, _region_id: String) -> void:
					AudioManager.play_event("build_complete"))
	# 建造完工 → 尘土特效（经 FxPool 组查找，无池环境静默）
	if _host._root._construction_api.has_signal("building_completed") and _host._root._construction_manager != null:
		var mgr: Node = _host._root._construction_manager
		_host._root._construction_api.building_completed.connect(
				func(building_id: String, _region_id: String) -> void:
					var b: Node = mgr.get_building_node(building_id)
					if b is Node2D:
						FxPool.spawn_burst(b.get_tree(), FxLibrary.BUILD_DUST, (b as Node2D).global_position))


# ─────────────────────────────── 战斗系统装配 ────────────────────────────────

## 给场景中的 BattleDirector 节点挂脚本，并实例化 CombatApi。
## 详见 §15 阶段 0.5。
func _setup_combat_system() -> void:
	# 给场景中已存在的 BattleDirector 节点挂脚本（§8.1）
	if _host._root.battle_director != null:
		_host._root.battle_director.set_script(_host._BattleDirectorScript)
		# 注入地图节点路径（拆 combat→world 硬引用，路径常量真相源仍在 world/api.gd）
		_host._root.battle_director.battle_anchor_path = NodePath(WorldAPI.PATH_MAP_BATTLE_ANCHOR)
		_host._root.battle_director.building_host_path = NodePath(WorldAPI.PATH_MAP_BUILDING_HOST)
	# 实例化 CombatApi（公共接口契约）
	var api := Node.new()
	api.set_script(_host._CombatApiScript)
	api.name = "CombatApi"
	_host._root.add_child(api)
	_host._root._combat_api = api
	# api.setup 必须在 battle_director 脚本挂载后调用
	_host.call_deferred("_setup_combat_api_deferred")


func _setup_combat_api_deferred() -> void:
	if _host._root._combat_api == null or _host._root.battle_director == null:
		return
	if not _host._root._combat_api.has_method("setup"):
		return
	_host._root._combat_api.setup(_host._root.battle_director)
	if _host._root._formation_system != null and _host._root._combat_api.has_method("setup_formation_system"):
		_host._root._combat_api.setup_formation_system(_host._root._formation_system)
	# 号令委托入口（CombatApi.issue_order → TacticalOrders）
	if _host._root._tactical_orders != null and _host._root._combat_api.has_method("set_tactical_orders"):
		_host._root._combat_api.set_tactical_orders(_host._root._tactical_orders)
	# 阵营 AI 装配注入（P6 TeamAi：BattleDirector 透传给 BattleInstance.enable_team_ai 消费）
	if _host._root.battle_director != null:
		if _host._root._tactical_orders != null and _host._root.battle_director.has_method("set_tactical_orders"):
			_host._root.battle_director.set_tactical_orders(_host._root._tactical_orders)
		if _host._root._formation_system != null and _host._root.battle_director.has_method("set_formation_system"):
			_host._root.battle_director.set_formation_system(_host._root._formation_system)


# ─────────────────────────────── 资源系统装配（P0-9）────────────────────────────────

## 实例化 ResourcesApi 作为子节点，并注入 ResourceManager。
func _setup_resources_system() -> void:
	var api := Node.new()
	api.set_script(_host._ResourcesApiScript)
	api.name = "ResourcesApi"
	_host._root.add_child(api)
	_host._root._resources_api = api
	# 粒子特效池（PLACEHOLDER 素材，见 fx_library.gd 头注释）
	var fx := Node.new()
	fx.set_script(_host._FxPoolScript)
	fx.name = "FxPool"
	_host._root.add_child(fx)
	_host.call_deferred("_setup_resources_api_deferred")


func _setup_resources_api_deferred() -> void:
	if _host._root._resources_api == null:
		return
	if not _host._root._resources_api.has_method("setup"):
		return
	var mgr = _host._ResourcesManagerScript.new()
	_host._root._resources_api.setup(mgr)
	# P0-9 注入到 ConstructionManager（若已就绪）
	if _host._root._construction_manager != null and _host._root._construction_manager.has_method("set_resources_api"):
		_host._root._construction_manager.set_resources_api(_host._root._resources_api)
	# 阶段 E：给玩家初始资源（P0 简化，资源不持久化，每次启动重置）
	# produce 到 "test_region"（与建造扣减 region 一致），资源条显示全局总量
	_grant_initial_resources()
	# 资源条并入顶栏（GlobalHUD 中块），不再单独挂 HudOverlay
	_attach_resource_bar_to_hud()


## 把资源条注入 GlobalHUD 顶栏中块（跨模块经 UIRoot 路径，非直接 get_node）
func _attach_resource_bar_to_hud() -> void:
	if _host._root.ui_root == null:
		return
	var hud = _host._root.ui_root.get_node_or_null(UIAPI.PATH_GLOBAL_HUD)
	if hud != null and hud.has_method("attach_resources"):
		var rb: Control = hud.attach_resources(_host._root._resources_api)
		if rb != null:
			_host._root._resource_bar = rb


## P0 初始资源：木材 300 / 石料 300 / 铁矿 100（足够建造兵营 + 几段城墙）
func _grant_initial_resources() -> void:
	if _host._root._resources_api == null or not _host._root._resources_api.has_method("produce"):
		return
	var initial: Dictionary = {
		"res_wood": 300.0,
		"res_stone": 300.0,
		"res_metal_ore": 100.0,
	}
	for res_id in initial.keys():
		_host._root._resources_api.produce(res_id, initial[res_id], "test_region", "初始资源")
	print_verbose("[GameRoot] 初始资源已发放: %s" % str(initial))


# ─────────────────────────────── 框选系统装配 ────────────────────────────────

## 实例化 SelectionSystem，挂到 UIRoot 下，注册为 BATTLE 模式 handler。
## 详见 §15 阶段 0.6。
func _setup_selection_system() -> void:
	if _host._root.ui_root == null:
		push_warning("[GameRoot] UIRoot 为空，跳过框选系统装配")
		return
	# 全屏输入层走 UIKit.full_rect（2026-08 审计收敛，替代 Control.new 自设 anchor）
	var sel := UIKit.full_rect(_host._SelectionSystemScript, "SelectionSystem")
	_host._root.ui_root.add_child(sel)
	_host._root._selection_system = sel
	# 注入 GameRoot（替代 group 反查）
	if sel.has_method("setup"):
		sel.setup(_host._root)
	# 注册为 BATTLE 模式 handler
	if _host._root.input_dispatcher != null and _host._root.input_dispatcher.has_method("register_handler"):
		_host._root.input_dispatcher.register_handler(PlayerControlAPI.Mode.BATTLE, sel)


# ─────────────────────────────── 组织系统装配 ────────────────────────────────

## 实例化 OrganizationManager + OrganizationApi 作为子节点并互相 setup。
func _setup_organization_system() -> void:
	# OrganizationManager 是 RefCounted，直接 new
	var mgr = _host._OrganizationManagerScript.new()
	# OrganizationApi 是 Node，挂为子节点
	var api := Node.new()
	api.set_script(_host._OrganizationApiScript)
	api.name = "OrganizationApi"
	_host._root.add_child(api)
	_host._root._organization_api = api
	# api.setup 需要 manager 引用
	if api.has_method("setup"):
		api.setup(mgr)


# ─────────────────────────────── 编队系统装配 ────────────────────────────────

## 实例化 FormationSystem，注入 OrganizationApi 引用。
func _setup_formation_system() -> void:
	var fs := Node.new()
	fs.set_script(_host._FormationSystemScript)
	fs.name = "FormationSystem"
	_host._root.add_child(fs)
	_host._root._formation_system = fs
	if _host._root._organization_api != null and fs.has_method("setup"):
		fs.setup(_host._root._organization_api)


# ─────────────────────────────── 战术号令系统装配 ────────────────────────────────

## 实例化 CommandChain + TacticalOrders，注入 FormationSystem 引用。
func _setup_tactical_system() -> void:
	# CommandChain
	var cc := Node.new()
	cc.set_script(_host._CommandChainScript)
	cc.name = "CommandChain"
	_host._root.add_child(cc)
	_host._root._command_chain = cc
	# 注入 FormationSystem（队内目标点散开依赖；3-F2 接力复用 _execute_delivery 时补挂——
	# 此前装配缺口使 spread 散点静默失效，全队退化为同一点）
	if _host._root._formation_system != null and cc.has_method("setup_formation"):
		cc.setup_formation(_host._root._formation_system)
	# TacticalOrders
	var to := Node.new()
	to.set_script(_host._TacticalOrdersScript)
	to.name = "TacticalOrders"
	_host._root.add_child(to)
	_host._root._tactical_orders = to
	if to.has_method("setup"):
		to.setup(_host._root._formation_system, _host._root._command_chain, _host._root._organization_api)


# ─────────────────────────────── 指挥链传输层装配（3-F2）────────────────────────────────

## 传输层三 provider + cmd 属性 provider 注入（架构文档 §4.2.1/§4.3.1）：
## organization 保持零出向依赖——实体坐标/玩家位置/属性查询在此装配（world 侧高视角取值）。
func _setup_command_transport() -> void:
	var api: Node = _host._root._organization_api
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
	var api: Node = _host._root._organization_api
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
	var root: GameRoot = _host._root
	var map: Node = root.get_current_map() if root.has_method("get_current_map") else null
	if map != null and map.has_method("get_possessed_entity"):
		var p: Node2D = map.get_possessed_entity()
		if p != null and is_instance_valid(p):
			return p.global_position
	if root.camera_rig != null:
		return root.camera_rig.get_screen_center_position()
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
	api.set_script(_host._ExpansionApiScript)
	api.name = "ExpansionApi"
	_host._root.add_child(api)
	_host._root._expansion_api = api
	api.setup(registry)
	var spawner := GarrisonSpawner.new()
	spawner.setup(registry)
	var manager := Node.new()
	manager.set_script(_host._ConquestManagerScript)
	manager.name = "ConquestManager"
	_host._root.add_child(manager)
	_host._root._conquest_manager = manager
	manager.setup(registry, spawner, api,
			_host._root._combat_api, _host._root._resources_api, _host._root.scene_loader)
	api.set_flow_manager(manager)


# ─────────────────────────────── 招兵与人口装配（游戏循环深化批次 1）───────────────────────────────

## RecruitManager 常驻 GameRoot（人口再生 tick 跨图存活但只在村A 计时）；
## 招兵逻辑经 OrganizationApi 转发（api.gd 招兵段），玩家交互注入见 game_root._on_map_loaded。
func _setup_recruit_system() -> void:
	var mgr := Node.new()
	mgr.set_script(_host._RecruitManagerScript)
	mgr.name = "RecruitManager"
	_host._root.add_child(mgr)
	_host._root._recruit_manager = mgr
	mgr.setup(_host._root._construction_api, _host._root._resources_api,
			_host._root.scene_loader, _host._root._formation_system)
	if _host._root._organization_api != null and _host._root._organization_api.has_method("set_recruit_manager"):
		_host._root._organization_api.set_recruit_manager(mgr)


# ─────────────────────────────── 上报叙事装配（UI-W2-B ②③）───────────────────────────────

## OrgReportNarrator 常驻 GameRoot：消费 organization api 的 report_filed（组织侧
## 门控后的可见集）与 EventBus.commander_assigned，经 EventBus.ui_notification 落既有通知 feed。
## 归 organization/ui（消费组织域数据、组织域 UI），不建跨模块面板。
func _setup_org_report_narrator() -> void:
	if _host._root._organization_api == null:
		return
	var n := Node.new()
	n.set_script(_host._OrgReportNarratorScript)
	n.name = "OrgReportNarrator"
	_host._root.add_child(n)
	_host._root._org_report_narrator = n
	if n.has_method("setup"):
		n.setup(_host._root._organization_api)
