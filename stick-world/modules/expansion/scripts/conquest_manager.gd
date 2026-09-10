class_name ConquestManager
extends Node
## 征服流程状态机 —— 出征接敌 → 战斗绑定 → 占领 → 奖励 → 通关判定。
##
## 出处：docs/技术/架构/出征与领地架构.md §三（数据流总图，本类为 C5 落地）。
## 职责边界（§〇 核心原则）：expansion 是流程编排者不是新引擎——刷军归
## GarrisonSpawner、战斗归 CombatApi/BattleInstance、跨图归 SceneLoader、
## 资源归 ResourcesApi，本类只持流程状态与 EventBus 对话。
##
## 接敌时序：SceneLoader 先发本地 map_loaded（GameRoot 在回调内同步 spawn 玩家
## 与随行编队），再双发 EventBus.map_loaded——本类监听后者，回调时玩家侧已就绪。
## 常驻挂 GameRoot（领地状态跨图存活 + 监听全局 battle_ended），SystemSetup 装配
## （照 ConstructionApi 先例注入各系统引用）。
##
## victory 语义（C2）：battle_ended 的 victory = 玩家阵营胜；玩家为攻方
## （faction 1），败仗 = 玩家侧全灭/撤离，不判负——守军战损持久化（车轮战）、
## 玩家传回村A 可再征。

## region_owner_changed 的玩家侧归属标识（P0 无接收端；§9.1 语义：发 tile 级 id）
const PLAYER_OWNER_ID := "player"
## 败仗回村（game_root._register_default_maps 的注册 id；expansion 不引 world 常量）
const HOME_MAP_ID := "village_a"
## 奖励入账 region（与初始资源发放/建造扣减同池，保证玩家可直接消费）
const REWARD_REGION := "test_region"

## 领地清单（与 expansion/api.gd 共享实例）
var _registry: TerritoryRegistry = null
## 守军生成（共享同一 registry）
var _spawner: GarrisonSpawner = null
## expansion api（点对点信号 territory_captured/conquest_completed 的挂载点）
var _api: Node = null
var _combat_api: Node = null
var _resources_api: Node = null
var _scene_loader: Node = null

## map_id → territory_id 接敌索引（setup 时从配置建）
var _territory_by_map: Dictionary = {}
## 进行中的征伐：battle_id → {territory_id, attackers, garrison, commander}
var _campaigns: Dictionary = {}
## 累计玩家侧伤亡（通关结算统计；死亡即 fade 释放，invalid 也计损失）
var _player_losses: int = 0


## 装配注入（SystemSetup；各系统引用装配时已就绪，使用都在运行时）
func setup(registry: TerritoryRegistry, spawner: GarrisonSpawner, api: Node,
		combat_api: Node, resources_api: Node, scene_loader: Node) -> void:
	_registry = registry
	_spawner = spawner
	_api = api
	_combat_api = combat_api
	_resources_api = resources_api
	_scene_loader = scene_loader
	for row in _registry.get_all():
		if row is Dictionary:
			var map_id := String(row.get("map_id", ""))
			if not map_id.is_empty():
				_territory_by_map[map_id] = String(row.get("id", ""))
	if EventBus != null:
		EventBus.map_loaded.connect(_on_map_loaded)
		EventBus.battle_ended.connect(_on_battle_ended)


# ─────────────────────────────── 流程入口（api 转发 / 测试直达）────────────────────────────

## 出征：校验状态 → 直达 travel（决策记录：P0 不走道路步行）。可出征返回 true。
func launch_campaign(territory_id: String) -> bool:
	if _registry == null or not _registry.has_territory(territory_id):
		push_warning("[ConquestManager] 未知领地: %s" % territory_id)
		return false
	if _get_state(territory_id) == TerritoryRegistry.State.CAPTURED:
		push_warning("[ConquestManager] %s 已臣服，无需再征" % territory_id)
		return false
	if _scene_loader == null or not _scene_loader.has_method("travel_to_map"):
		push_warning("[ConquestManager] SceneLoader 未就绪")
		return false
	var row: Dictionary = _registry.get_territory(territory_id)
	var entry_side := int(row.get("entry_side", 0))
	_scene_loader.travel_to_map(String(row.get("map_id", "")),
			WorldAPI.TravelMode.WALK, entry_side)
	return true


## 占领：写状态/发奖励/广播三信号/通关判定（battle_ended 胜利时调，也供测试直达）
func capture_territory(territory_id: String) -> void:
	if _registry == null or not _registry.has_territory(territory_id):
		push_warning("[ConquestManager] 未知领地: %s" % territory_id)
		return
	if _get_state(territory_id) == TerritoryRegistry.State.CAPTURED:
		return  # 幂等（测试直达与 battle_ended 双路径）
	var row: Dictionary = _registry.get_territory(territory_id)
	var record: Dictionary = WorldState.territories.get(territory_id, {})
	var state: Dictionary = TerritoryRegistry.initial_state()
	state["garrison_losses"] = int(record.get("garrison_losses", 0)) if record is Dictionary else 0
	state["state"] = TerritoryRegistry.State.CAPTURED
	WorldState.territories[territory_id] = state
	_grant_rewards(territory_id, row)
	EventBus.territory_state_changed.emit(territory_id, TerritoryRegistry.State.CAPTURED)
	# §9.1 P 社化预留：发 tile 级 id（P0 一座据点占一个 tile）；P0 无接收端
	EventBus.region_owner_changed.emit(String(row.get("tile_key", "")), PLAYER_OWNER_ID)
	if _api != null and _api.has_signal("territory_captured"):
		_api.territory_captured.emit(territory_id, row.get("rewards", {}))
	if EventBus.has_signal("ui_notification"):
		EventBus.ui_notification.emit("征服", "%s已臣服" % String(row.get("name_zh", "")), "info")
	_check_conquest_completed()


## 进行中的征伐查询（battle_id 维度；测试/调试用）
func get_active_campaign_count() -> int:
	return _campaigns.size()


# ─────────────────────────────── 接敌（map_loaded → 开战）────────────────────────────

func _on_map_loaded(map_id: String, _map_type: int) -> void:
	var territory_id: String = String(_territory_by_map.get(map_id, ""))
	if territory_id.is_empty():
		return  # 非据点图
	if _get_state(territory_id) == TerritoryRegistry.State.CAPTURED:
		return  # 已臣服：友化空图巡视（GarrisonSpawner 同语义短路）
	if _has_campaign_for(territory_id):
		return  # 同据点重复加载防重开战
	if _scene_loader == null or not _scene_loader.has_method("get_current_map"):
		return
	var map: Node2D = _scene_loader.get_current_map()
	if map == null or _spawner == null or _combat_api == null:
		return
	var defenders: Array = _spawner.spawn_garrison(map, territory_id)
	if defenders.is_empty():
		push_warning("[ConquestManager] %s 无可刷守军，跳过接敌" % territory_id)
		return
	var attackers: Array = _collect_player_units(map)
	if attackers.is_empty():
		push_warning("[ConquestManager] 玩家侧无单位，跳过接敌（%s）" % territory_id)
		return
	var battle: Node = _combat_api.start_battle(map, attackers, defenders, 1)
	if battle == null:
		push_warning("[ConquestManager] 据点战开启失败: %s" % territory_id)
		return
	_enable_commander_retreat(battle, _registry.get_territory(territory_id))
	_register_campaign(battle, territory_id, attackers, defenders)
	print_verbose("[ConquestManager] 据点战开启: %s（守军 %d + 敌将）" % [territory_id, defenders.size() - 1])


## 守军阵营启用 TeamAi（据点战专属，架构 §4.2）：注入敌将撤仗评估阈值。
## 普通战斗不注册（注册制零回归闸门）。
func _enable_commander_retreat(battle: Node, row: Dictionary) -> void:
	if not battle.has_method("enable_team_ai"):
		return
	var commander: Dictionary = row.get("commander", {}) if row.get("commander", {}) is Dictionary else {}
	var th: Dictionary = commander.get("retreat_thresholds", {}) \
			if commander.get("retreat_thresholds", {}) is Dictionary else {}
	var overrides := {
		"retreat_casualty_rate": float(th.get("casualty_rate", -1.0)),
		"retreat_loss_ratio": float(th.get("loss_ratio", -1.0)),
		"retreat_timeout": float(th.get("timeout", -1.0)),
	}
	battle.enable_team_ai(2, overrides)  # 2 = FACTION_DEFENDER（守军）


## 登记征伐：拆分守军/敌将（败仗统计敌将不占 garrison_losses，架构 §2.3）
func _register_campaign(battle: Node, territory_id: String,
		attackers: Array, defenders: Array) -> void:
	var garrison: Array = []
	var commander: Node = null
	for u in defenders:
		if not is_instance_valid(u):
			continue
		if bool(u.get_meta(GarrisonSpawner.META_GARRISON_COMMANDER, false)):
			commander = u
		else:
			garrison.append(u)
	_campaigns[battle.get_battle_id()] = {
		"territory_id": territory_id,
		"attackers": attackers.duplicate(),
		"garrison": garrison,
		"commander": commander,
	}


func _has_campaign_for(territory_id: String) -> bool:
	for campaign in _campaigns.values():
		if campaign.get("territory_id", "") == territory_id:
			return true
	return false


# ─────────────────────────────── 收束（battle_ended）────────────────────────────

func _on_battle_ended(battle_id: String, victory: bool) -> void:
	var campaign: Dictionary = _campaigns.get(battle_id, {})
	if campaign.is_empty():
		return  # 非据点战（普通战斗/守城战）
	_campaigns.erase(battle_id)
	var territory_id: String = campaign.get("territory_id", "")
	_player_losses += _count_losses(campaign.get("attackers", []))
	if victory:
		capture_territory(territory_id)
		return
	# 败仗不判负：守军战损持久化（车轮战），玩家传回村A 可再征（架构 §三败仗路径）
	var losses := _count_losses(campaign.get("garrison", []))
	if losses > 0:
		var record: Dictionary = WorldState.territories.get(territory_id, {})
		var state: Dictionary = TerritoryRegistry.initial_state()
		state["state"] = _get_state(territory_id)
		state["garrison_losses"] = int(record.get("garrison_losses", 0)) \
				if record is Dictionary else 0
		state["garrison_losses"] += losses
		WorldState.territories[territory_id] = state
	if EventBus.has_signal("ui_notification"):
		var name_zh := String(_registry.get_territory(territory_id).get("name_zh", territory_id))
		EventBus.ui_notification.emit("征服", "攻取%s失利，率残部退回本营（守军折损 %d）" % [name_zh, losses], "warn")
	# 延迟回村：battle_ended 在 BattleInstance._end 执行栈内发射，同帧切图
	# 会卸载地图销毁战斗实例；deferred 等栈退出后再 travel
	call_deferred("_return_home")


func _return_home() -> void:
	if _scene_loader == null or not _scene_loader.has_method("travel_to_map"):
		return
	_scene_loader.travel_to_map(HOME_MAP_ID, WorldAPI.TravelMode.WALK, WorldAPI.EntrySide.RIGHT)


## 损失计数：死亡/离场/已释放（死亡单位 fade 后 queue_free，invalid 即损失）
func _count_losses(units: Array) -> int:
	var n := 0
	for u in units:
		if not is_instance_valid(u):
			n += 1
			continue
		if u.has_method("is_dead") and u.is_dead():
			n += 1
			continue
		if "departed" in u and bool(u.get("departed")):
			n += 1
	return n


# ─────────────────────────────── 收益与通关 ─────────────────────────────

## 奖励发放：资源入账（与建造同池可直接消费）+ 解锁广播（消费端各系统自听）
func _grant_rewards(territory_id: String, row: Dictionary) -> void:
	var rewards: Dictionary = row.get("rewards", {}) if row.get("rewards", {}) is Dictionary else {}
	var resources: Dictionary = rewards.get("resources", {}) \
			if rewards.get("resources", {}) is Dictionary else {}
	var name_zh := String(row.get("name_zh", ""))
	for res_id in resources:
		if _resources_api != null and _resources_api.has_method("produce"):
			_resources_api.produce(String(res_id), float(resources[res_id]),
					REWARD_REGION, "占领奖励:%s" % name_zh)
	var unlocks: Array = rewards.get("unlocks", []) if rewards.get("unlocks", []) is Array else []
	for unlock_id in unlocks:
		EventBus.unlock_granted.emit(String(unlock_id))


## 通关判定：全部 CAPTURED → conquest_completed（通关结算 UI 归批次 C6 消费）
func _check_conquest_completed() -> void:
	if _api == null or not _api.has_method("is_all_captured") \
			or not _api.has_signal("conquest_completed"):
		return
	if not _api.is_all_captured():
		return
	var total := _registry.get_count()
	var captured := 0
	for row in _registry.get_all():
		if row is Dictionary and _get_state(String(row.get("id", ""))) \
				== TerritoryRegistry.State.CAPTURED:
			captured += 1
	var stats := {
		"captured": captured,
		"total": total,
		"player_losses": _player_losses,
		"game_time": WorldState.game_time,
	}
	_api.conquest_completed.emit(stats)
	if EventBus.has_signal("ui_notification"):
		EventBus.ui_notification.emit("征服", "敌据点已全部荡平！本域再无敌手", "info")


# ─────────────────────────────── 内部工具 ─────────────────────────────

## 领地运行时状态（与 api.get_territory_state 同语义）
func _get_state(territory_id: String) -> int:
	var record: Variant = WorldState.territories.get(territory_id, {})
	if not (record is Dictionary):
		return TerritoryRegistry.State.HOSTILE
	return int(record.get("state", TerritoryRegistry.State.HOSTILE))


## 玩家侧单位收集：EntityHost 全扫，排除守军来源（garrison meta）与非存活。
## 据点图无原住民 NPC（C4 契约），= 被附身玩家 + 跨图随行编队成员
func _collect_player_units(map: Node2D) -> Array:
	var host: Node2D = map.get_node_or_null(WorldAPI.PATH_MAP_ENTITY_HOST)
	if host == null:
		return []
	var result: Array = []
	for u in host.get_children():
		if not (u is Node2D) or not is_instance_valid(u):
			continue
		if bool(u.get_meta(GarrisonSpawner.META_GARRISON_UNIT, false)):
			continue
		if u.has_method("is_dead") and u.is_dead():
			continue
		if "departed" in u and bool(u.get("departed")):
			continue
		result.append(u)
	return result
