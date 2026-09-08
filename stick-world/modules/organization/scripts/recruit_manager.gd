class_name RecruitManager
extends Node
## 招兵与人口 —— 兵源闭环（游戏循环深化批次 1，核心循环 §7.1 断点 1/6）。
##
## 出处：docs/设计/核心循环.md §七；玩法愿景 docs/设计/系统/12-小镇生活与美术.md §三。
## 职责边界：招兵=扣资源 + 取空闲村民变身士兵；人口再生=村A 周期性自然增长。
## 战斗归 combat、建筑归 building_gen/construction、资源归 resources，
## 本类只持人事变动与人口节律，经 EventBus/OrganizationApi 对话。
##
## 人口口径（设计支柱 #3"每个火柴人都在真实生活"）：村民实体即人口，所见
## 即所得——空闲村民 = 工人池中无 META_SOLDIER 标记且存活者；士兵变身即退出
## 劳工池（不再被建造派工），战损后由人口再生补员，回路闭合：
## 资源 → 招兵 → 村民减少 → 人口再生 → 可再招。
##
## 装配：SystemSetup 挂 GameRoot 常驻（照 ConquestManager 同模式）；跨模块
## 消费经 OrganizationApi 转发（api.gd 招兵段），玩家交互经
## interaction_controller → entity.get_organization_api() 触发。

## 士兵标记（招兵选取排除 + 人口统计排除；C 线职业系统沿用此 meta 惯例）
const META_SOLDIER := "recruit_soldier"

## 招兵成本（AI 提案待实测定稿；只吃木/石——铁锭留给 C 线矿→锭装备链，不阻塞首战兵源）
const RECRUIT_COST := {"res_wood": 30.0, "res_stone": 10.0}
## 资源账区（与采集/建造/征服奖励同池）
const RECRUIT_REGION := "test_region"
## 兵营建筑 def_id（config/buildings/buildings.tres；场景注册归 building_gen）
const BARRACKS_DEF_ID := "barracks"
## 村庄人口上限（村民实体数，不含玩家与士兵；住宅化归 C 线）
const POP_CAP_DEFAULT := 8
## 人口再生默认间隔（游戏秒；TimeManager 暂停不计时）
const POP_GROWTH_DEFAULT := 45.0
## P0 人口再生只在村A（多城人口归 C 线/城镇生成线）
const HOME_MAP_ID := "village_a"
## 新村民出生排布（照 initial_content.spawn_npcs：仓库右侧 1050 起）
const NPC_START_X := 1050.0

const _STICKMAN_SCENE: PackedScene = UnitsAPI.STICKMAN_ENTITY_SCENE

var _construction_api: Node = null
var _resources_api: Node = null
var _scene_loader: Node = null
var _formation_system: Node = null

## 再生参数（var 供测试注入加速；运行时保持默认值）
var pop_growth_interval: float = POP_GROWTH_DEFAULT
var pop_cap: int = POP_CAP_DEFAULT
var _accum: float = 0.0


## 装配注入（SystemSetup；引用装配期已建，使用全在运行时）
func setup(construction_api: Node, resources_api: Node, scene_loader: Node,
		formation_system: Node) -> void:
	_construction_api = construction_api
	_resources_api = resources_api
	_scene_loader = scene_loader
	_formation_system = formation_system


func _process(delta: float) -> void:
	if TimeManager != null and TimeManager.is_paused():
		return
	if _scene_loader == null or not _scene_loader.has_method("get_current_map_id"):
		return
	if String(_scene_loader.get_current_map_id()) != HOME_MAP_ID:
		return
	_accum += delta
	if _accum < pop_growth_interval:
		return
	_accum = 0.0
	if _villager_count() < pop_cap:
		_spawn_villager()


# ─────────────────────────────── 招兵（interaction_controller 经 OrganizationApi 调用）────────────────────────────

## 招募一名民兵：扣资源 + 空闲村民变身士兵。失败返回 {ok:false, reason} 并通知。
func recruit() -> Dictionary:
	var player: Node2D = _possessed_entity()
	var barracks: Node2D = find_nearest_barracks(
			player.global_position if player != null else Vector2.INF)
	if barracks == null:
		return _fail("附近没有可用的兵营", "no_barracks")
	var villager: Node2D = _pick_villager(player)
	if villager == null:
		return _fail("没有空闲村民可应征（等待人口增长）", "no_villager")
	for res_id in RECRUIT_COST:
		if float(_resources_api.get_stock(String(res_id))) < float(RECRUIT_COST[res_id]):
			return _fail("招募民兵需要 30 木材 10 石材（资源不足）", "insufficient_resources")
	for res_id in RECRUIT_COST:
		_resources_api.consume(String(res_id), float(RECRUIT_COST[res_id]),
				RECRUIT_REGION, "招兵")
	_construction_api.unregister_worker(villager)
	villager.set_meta(META_SOLDIER, true)
	if villager.get("weapon_mount") != null:
		villager.weapon_mount.weapon_type = WeaponMount.WeaponType.SWORD
	if villager.has_method("play_arrive"):
		villager.play_arrive()
	EventBus.ui_notification.emit("兵营", "一名村民应征入伍（-30 木材 -10 石材）", "info")
	return {"ok": true, "soldier": villager}


## 交互提示文案（interaction_controller.update_hint 消费）
func get_recruit_hint() -> String:
	if _pick_villager(null) == null:
		return "没有空闲村民可应征"
	for res_id in RECRUIT_COST:
		if float(_resources_api.get_stock(String(res_id))) < float(RECRUIT_COST[res_id]):
			return "招募民兵需 30木材 10石材（资源不足）"
	return "按F 招募民兵（30木材 10石材）"


## 距 pos 最近的可用兵营（OPERATIONAL 状态；无则 null）。
## interaction_controller 用它做交互探测，recruit 用它做执行校验。
func find_nearest_barracks(pos: Vector2) -> Node2D:
	var map: Node2D = _current_map()
	if map == null:
		return null
	var host: Node2D = map.get("building_host") if "building_host" in map else null
	if host == null:
		return null
	var best: Node2D = null
	var best_dist: float = INF
	for b in host.get_children():
		if not (b is Node2D) or not is_instance_valid(b):
			continue
		if String(b.get("def_id")) != BARRACKS_DEF_ID:
			continue
		var state: int = int(b.get("state")) if "state" in b else -1
		if state != Building.State.OPERATIONAL:
			continue
		var d: float = absf(b.global_position.x - pos.x)
		if d < best_dist:
			best_dist = d
			best = b
	return best


# ─────────────────────────────── 人口（再生/统计）────────────────────────────

## 村民实体数（非士兵、非附身、存活；P0 村A 单地图口径）
func _villager_count() -> int:
	return _scan_villagers(null).size()


## 扫当前地图 EntityHost 的村民（exclude 为额外排除项；供选取与计数共用口径）
func _scan_villagers(exclude: Node2D) -> Array:
	var map: Node2D = _current_map()
	if map == null:
		return []
	var host: Node = map.get_node_or_null(WorldAPI.PATH_MAP_ENTITY_HOST)
	if host == null:
		return []
	var result: Array = []
	for u in host.get_children():
		if not (u is Node2D) or not is_instance_valid(u):
			continue
		if u == exclude:
			continue
		if bool(u.get_meta(META_SOLDIER, false)):
			continue
		# "garrison_unit" 是 expansion.GarrisonSpawner 的守军来源标记（跨模块 meta 契约，
		# 不引内部脚本）；据点图无村民，此处防御性排除
		if bool(u.get_meta("garrison_unit", false)):
			continue
		if u.has_method("is_possessed") and u.is_possessed():
			continue
		if u.has_method("is_dead") and u.is_dead():
			continue
		result.append(u)
	return result


## 选取一名空闲村民（优先距 player 最近；经工人池缩小范围，池缺引用时全扫兜底）
func _pick_villager(player: Node2D) -> Node2D:
	var pool: Array = []
	if _construction_api != null and _construction_api.has_method("get_available_workers"):
		pool = _construction_api.get_available_workers()
	var candidates: Array = _scan_villagers(null) if pool.is_empty() else pool
	var best: Node2D = null
	var best_dist: float = INF
	for u in candidates:
		if not (u is Node2D) or not is_instance_valid(u) or u.is_inside_tree() == false:
			continue
		if bool(u.get_meta(META_SOLDIER, false)):
			continue
		if u.has_method("is_possessed") and u.is_possessed():
			continue
		if u.has_method("is_dead") and u.is_dead():
			continue
		var ref_x: float = player.global_position.x if player != null else u.global_position.x
		var d: float = absf(u.global_position.x - ref_x)
		if d < best_dist:
			best_dist = d
			best = u
	return best


## 人口再生：spawn 一名村民（照 initial_content.spawn_npcs 先例：仓库右侧排布，
## 注入建造/编队引用使可派工）
func _spawn_villager() -> void:
	var map: Node2D = _current_map()
	if map == null or not map.has_method("spawn_entity"):
		return
	var spawn_y: float = float(map.ground_y) + (float(map.ground_bottom) - float(map.ground_y)) * 0.5
	var x: float = NPC_START_X + randf_range(0.0, 400.0)
	if x > float(map.map_right) - 100.0:
		x = NPC_START_X + randf_range(0.0, 400.0)
	var npc: Node2D = map.spawn_entity(_STICKMAN_SCENE, Vector2(x, spawn_y))
	if npc == null:
		return
	if npc.get("foot_offset") != null:
		npc.global_position.y = spawn_y - npc.foot_offset
	if npc.has_method("set_possessed"):
		npc.set_possessed(false)
	if npc.has_method("set_construction_manager") and _construction_api != null:
		npc.set_construction_manager(_construction_api)
	if npc.has_method("set_formation_system") and _formation_system != null:
		npc.set_formation_system(_formation_system)


# ─────────────────────────────── 内部工具 ─────────────────────────────

func _current_map() -> Node2D:
	if _scene_loader == null or not _scene_loader.has_method("get_current_map"):
		return null
	return _scene_loader.get_current_map()


func _possessed_entity() -> Node2D:
	var map: Node2D = _current_map()
	if map == null or not map.has_method("get_possessed_entity"):
		return null
	return map.get_possessed_entity()


## 失败统一出口：通知 + 结构化返回（交互层零通知职责）
func _fail(msg: String, reason: String) -> Dictionary:
	EventBus.ui_notification.emit("兵营", msg, "warn")
	return {"ok": false, "reason": reason}
