extends RefCounted
## SystemSetup 核心系统装配助手 —— 承接宿主分帧步骤表中核心系统域各步骤的函数体
## （战斗 / 资源 / 框选 / 组织 / 编队 / 战术 / 指挥传输 / 征服 / 招兵 / 上报叙事；
## 建造已下沉 modules/construction/setup.gd，AR-1 装配下沉首批）。
##
## 纪律：
## - 状态全部留在宿主（system_setup.gd），本助手经 _host 回引读写，不另立状态；
## - 跨模块 preload 属 composition root 豁免、全部留在宿主，此处经 _host 取用；
## - 各方法与宿主同名壳逐一对应（宿主壳只做一行转发），行为与拆分前逐行等价。

var _host: Node  ## SystemSetup 宿主（无 class_name，动态回引）


func bind(host: Node) -> void:
	_host = host


# 建造系统装配已下沉 modules/construction/setup.gd（AR-1 装配下沉首批）：
# manager/api 互装与完工呈现接线（音效/尘土）随迁模块自持，
# SystemSetup 步骤表「建造系统」步骤直达模块自装配器。

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
		_host._root.battle_director.entity_host_path = NodePath(WorldAPI.PATH_MAP_ENTITY_HOST)
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

## ResourcesApi 实例化与 ResourceManager 注入已下沉 modules/resources/setup.gd
## （AR-1 装配下沉首批）；本步骤保留粒子特效池创建（fx 基础设施，PLACEHOLDER
## 素材见 fx_library.gd 头注释）与跨模块接线编排。
func _setup_resources_system() -> void:
	_host._resources_assembler().assemble(_host._root)
	# 粒子特效池（原随资源步骤创建，原位原序不动——composition root 装配）
	var fx := Node.new()
	fx.set_script(_host._FxPoolScript)
	fx.name = "FxPool"
	_host._root.add_child(fx)
	_host.call_deferred("_setup_resources_api_deferred")


func _setup_resources_api_deferred() -> void:
	if _host._root._resources_api == null or not _host._root._resources_api.has_method("setup"):
		return
	_host._resources_assembler().api_deferred(_host._root)
	# P0-9 注入到 ConstructionManager（若已就绪）——跨模块接线留装配编排
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


## P0 初始资源：木材 85 / 石料 75 / 铁矿 32（数值口径：自然数不膨胀；约为民居成本
## 28/12 的 3 倍，够建造兵营 45/32/14 + 一两座民居 + 几段土墙 8/12）
func _grant_initial_resources() -> void:
	if _host._root._resources_api == null or not _host._root._resources_api.has_method("produce"):
		return
	var initial: Dictionary = {
		"res_wood": 85.0,
		"res_stone": 75.0,
		"res_metal_ore": 32.0,
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

## 实例化 OrganizationManager + OrganizationApi 作为子节点并互相 setup；
## 随后接槽位板/技能台账/明面前提/训练推进器的进程级装配（组织本位落地批）。
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
	_setup_org_slot_system(mgr)


## 槽位板/技能台账/明面前提/训练推进器装配（不加新装配步骤）：每局 reset+prime
## 消跨局残留（GameRoot 每局一建、旅行不重建）；prime 保证 boot 读档的
## game_loaded 行恢复不丢订阅；providers 注入实体侧实现。
func _setup_org_slot_system(mgr: RefCounted) -> void:
	OrgSlotSystem.reset_for_new_run()
	OrgSlotSystem.instance()
	SkillAPI.reset_for_new_run()
	SkillAPI.prime()
	OrgPrereqs.set_providers(
		func(org_id: String) -> Array:
			var r: Dictionary = mgr.get_organization(org_id)
			if not r.get("ok", false):
				return []
			return r.get("data", {}).get("personnel", []),
		_stickman_attribute,
	)
	var post := TrainingPost.new()
	post.name = "TrainingPost"
	_host._root.add_child(post)  # 常驻 GameRoot；消费方经 get_node_or_null("TrainingPost") 取
	post.setup(
		func(org_id: String) -> Dictionary:
			var r: Dictionary = mgr.get_organization(org_id)
			if not r.get("ok", false):
				return {"ok": false}
			var data: Dictionary = r.get("data", {})
			return {"ok": true, "tier": int(data.get("tier", 0)),
					"personnel": data.get("personnel", [])},
		_training_building_present,
		_stickman_attribute,
		_bump_stickman_attribute,
	)


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
## 同时接 org_created → location 回填（org.location 语义源，§4.2.2 建队回填起步）。
func _setup_command_transport() -> void:
	var api: Node = _host._root._organization_api
	if api == null or not api.has_method("set_transport_providers"):
		return
	api.set_transport_providers(
		_org_commander_position,
		_player_command_position,
		_region_distance,
	)
	if api.has_method("set_attribute_provider"):
		api.set_attribute_provider(_stickman_cmd_attribute)
	# org.location 语义源（§4.2.2 建队回填起步）：组织诞生即在当前场景图——
	# org_created 统一回填 location = current_map_id（FormationSystem 建队/
	# OrgPanel 手建/insert_tier 同口径；读档恢复不走 create_organization 不触发）
	if api.has_signal("org_created") and not api.org_created.is_connected(_on_org_created_backfill_location):
		api.org_created.connect(_on_org_created_backfill_location)


## org_created 回填：location = 当前场景图 map_id（地图根级区域标识，战略图
## settlement.map_id 反查可得锚点）；战略图外场景（hd2d_street/road_*）无锚点，
## 传输层查 -1 走 fallback 常数——语义正确
func _on_org_created_backfill_location(org_id: String) -> void:
	var api: Node = _host._root._organization_api
	if api == null or not api.has_method("set_organization_location"):
		return
	var map_id := ""
	if _host._root.scene_loader != null and "current_map_id" in _host._root.scene_loader:
		map_id = _host._root.scene_loader.current_map_id
	api.set_organization_location(org_id, map_id)


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


## 玩家位置：接管实体坐标；未接管 = 相机视野中心；全不可得 → Vector2.INF
func _player_command_position() -> Vector2:
	var root: GameRoot = _host._root
	var map: Node = root.get_current_map() if root.has_method("get_current_map") else null
	if map != null and map.has_method("get_user_controlled_entity"):
		var p: Node2D = map.get_user_controlled_entity()
		if p != null and is_instance_valid(p):
			return p.global_position
	if root.camera_rig != null:
		return root.camera_rig.get_screen_center_position()
	return Vector2.INF


## 跨图驻地距离（§4.2.2 真值）：world_map api.region_distance——两区域
## （settlement_id/map_id）战略图世界坐标直线距离；战略图未装配/未初始化/
## 区域无锚点 → -1 走 fallback 常数（balance var_command_cross_map_distance）
func _region_distance(from_loc: String, to_loc: String) -> float:
	var sm: Node = _host._root._strategic_map
	if sm == null:
		return -1.0
	var content: Node = sm.get_node_or_null("Content")
	var map_api: Node = content.get_node_or_null("Api") if content != null else null
	if map_api == null or not map_api.has_method("region_distance"):
		return -1.0
	return float(map_api.region_distance(from_loc, to_loc))


## cmd 属性查询（补位排序，§4.3.1）：instance_id 字符串 → attributes.cmd；失败 -1 沉底
func _stickman_cmd_attribute(stickman_id: String) -> float:
	return _stickman_attribute(stickman_id, "cmd")


# ───────────────────────── 组织本位：属性/建筑注入实现 ─────────────────────────

## 任意基础属性查询（明面前提/训练速率用；id→实体→attributes，17 号 §一域 0~10）。
func _stickman_attribute(stickman_id: String, attr_key: String) -> float:
	var iid := int(stickman_id)
	if iid <= 0:
		return -1.0
	var unit: Node = instance_from_id(iid)
	if unit == null or not is_instance_valid(unit):
		return -1.0
	var attrs: Variant = unit.get("attributes")
	if not (attrs is Dictionary):
		return -1.0
	var value: Variant = (attrs as Dictionary).get(attr_key, -1.0)
	return float(value) if value is float or value is int else -1.0


## 属性 +delta（钳 0~10）——训练进度落地用；返回新值（查无实体 -1）。
func _bump_stickman_attribute(stickman_id: String, attr_key: String, delta: int) -> float:
	var iid := int(stickman_id)
	if iid <= 0:
		return -1.0
	var unit: Node = instance_from_id(iid)
	if unit == null or not is_instance_valid(unit):
		return -1.0
	var attrs: Variant = unit.get("attributes")
	if not (attrs is Dictionary):
		return -1.0
	var value: Variant = (attrs as Dictionary).get(attr_key, null)
	if not (value is float or value is int):
		return -1.0
	var new_value := clampf(float(value) + float(delta), 0.0, 10.0)
	(attrs as Dictionary)[attr_key] = new_value
	return new_value


## 职能对应建筑在场（训练等职能的隐形前提，01 §2.5）：占位口径 [待定]——
## 职能→建筑映射待内容（03 场所需求清单），暂按兵营 OPERATIONAL 当训练建筑
## （def 同 RecruitManager.BARRACKS_DEF_ID）。
func _training_building_present(_function_name: String) -> bool:
	var map: Node2D = _host._root.get_current_map()
	if map == null:
		return false
	var host: Node2D = map.get("building_host") if "building_host" in map else null
	if host == null:
		return false
	for b in host.get_children():
		if b is Node2D and is_instance_valid(b) and String(b.get("def_id")) == "barracks":
			var state: int = int(b.get("state")) if "state" in b else -1
			if state == Building.State.OPERATIONAL:
				return true
	return false


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
	# 世界账面日脉冲接线（M2）：置于早退守卫前——组织 api 缺位时接线不得静默失效
	EventBus.world_day_advanced.connect(func() -> void: WorldLedger.advance_day(WorldState))
	if _host._root._organization_api == null:
		return
	var n := Node.new()
	n.set_script(_host._OrgReportNarratorScript)
	n.name = "OrgReportNarrator"
	_host._root.add_child(n)
	_host._root._org_report_narrator = n
	if n.has_method("setup"):
		n.setup(_host._root._organization_api)
