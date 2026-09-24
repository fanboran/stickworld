extends Node
## 运行时世界状态中心 —— 集中管理所有实体状态。
##
## ⚠️ 冻结状态（2026-08-22 审计决策）：
##   - 六大实体容器（stickmen/organizations/regions/battles/projects/supply_chains）
##     全部零调用，处于冻结预留态——不删除、不接线，technology 阶段 1 重建时
##     再决策接入或归档；core/entities/ 对应七个状态类同步冻结；
##   - 存档走 game_saving/game_loaded 信号直写 world_state 表（含旧档回退）。
##
## 统一契约生产域（世界模型整合 M1，完整版蓝图 §3.4）：cities/factions 两容器
## 为生产数据——所有城（玩家/AI）同一套城市模型，政权实力 = 名下城市聚合；
## 玩家政权与 AI 政权同构（不设 is_player 标记，由 id 约定判定，见
## PLAYER_FACTION_ID）。
##
## 各模块通过 WorldState 读写实体数据，而非各自维护独立状态。

# ─────────────────────────── 冻结预留容器 ────────────────────────────────

var stickmen: Dictionary = {}          # {id: StickmanState}
var organizations: Dictionary = {}      # {id: OrganizationState}
var regions: Dictionary = {}            # {str(id): RegionState}
var battles: Dictionary = {}            # {id: BattleState}
var projects: Dictionary = {}           # {id: ProjectState}
var supply_chains: Dictionary = {}      # {id: SupplyChainState}

# ─────────────────────── 统一契约生产域（M1）─────────────────────────────

## 玩家政权 id 约定（与 world_map api 的 PLAYER_OWNER_ID 对齐；core 不依赖
## 模块，两处各持一份字面量，语义一致由契约文档保证）
const PLAYER_FACTION_ID := "player"

## 城市域 {settlement_id: CityState}——所有城（玩家/AI）同一套城市模型。
## 主键与 mapdata 生成端聚落 id 同格式（settlement_city_%03d）；
## CityState 字段规范见 core/entities/city_state.gd
var cities: Dictionary = {}

## 政权域 {state_id: FactionState}——键为 80 国表 id 或 "player"。
## FactionState 字段规范见 core/entities/faction_state.gd
var factions: Dictionary = {}

# ─────────────────────────────── 全局状态 ────────────────────────────────

## 当前游戏时刻（小时 0.0 ~ 24.0，由 EnvironmentSystem 推进与写入）
var game_time: float = 0.0

## 本局随机种子（新开局随机一次，随存档保存/恢复；读档后逐点复现本局扰动，
## 供 population_score ±15% 每局扰动等确定性随机使用，总体设计 §5.7）
var run_seed: int = 0

## 已到访聚落（P6 快速旅行语义，总体设计 §5.10）：{settlement_id: true}。
## 玩家进入聚落场景（map_loaded 反查命中）时由 world_map api 写入；
## 出生聚落不落此表——api 判定时恒视为已到访（不依赖开局加载时序）
var visited_settlements: Dictionary = {}

## 已获解锁/科技 id 池（{unlock_id: true}）——"科技随征服到手"（设计 04-科技系统
## §二）在科技系统实装前的通用台账：解锁发放方经 grant_unlock 写此池，消费端
## （建筑可建集等）按 id 查询。开局基线见 STARTING_UNLOCKS。
var unlocks: Dictionary = {}

## 开局已获解锁/科技 id（基线）：门禁只挡"未获"项，基线保证门禁引入前后开局
## 可建集不变（当前唯一受门禁的现役建筑是 tech_military_1 的兵营）。
## 科技系统实装（config/tech）后本基线随科技表迁出。
const STARTING_UNLOCKS: Array[String] = ["tech_military_1"]

## ── 步行旅行队列（F6/E5，瞬态不进存档——读档恒回出发聚落）──
## 途经道路段序列（按行进序）：[{road_id, road(道路数据条目), from_map_id, to_map_id}]。
## road_id 即道路场景 id（road_map_generator 生成/缓存键）；from/to_map_id 为两端
## 聚落场景 id（出口触发目标）。由 world_map api.walk_to 组装，GameRoot 消费推进。
var walk_legs: Array = []
## 当前所在段下标（进入道路场景时由 GameRoot 依 road_id 反查校正）
var walk_index: int = -1
## 步行终点聚落场景 id（最后一段走完进城）；空 = 无步行进行中
var walk_target_map_id: String = ""
## 步行出发聚落场景 id（第一段往回走 = 回这里）
var walk_origin_map_id: String = ""


## 新开局：重置本局种子（GameRoot 新游戏分支调用；读档路径走 load_save_data 恢复）
func start_new_run() -> void:
	run_seed = randi()
	visited_settlements = {}
	unlocks = {}
	# 统一契约两域重置 + 玩家政权同构壳——壳在此先立（capital 空 / lut_index -1 /
	# 0 城，M5 三出身才定初始条件）；name 用通用描述性称谓，禁武侠雅名
	cities = {}
	factions = {}
	var player_faction := FactionState.new()
	player_faction.state_id = PLAYER_FACTION_ID
	player_faction.name = "玩家政权"
	register_faction(player_faction)
	# worldgen 真源灌入 80 政权 + 1040 城（世界模型整合 M1）：新开局 = 真源构建
	# （political_data.json + l3_city），读档 = 存档恢复（load_save_data，不经
	# 初始化器）；merge 非覆盖，上面的玩家政权壳保留
	WorldContractInitializer.apply_to_world_state(self)
	reset_walk()


## 是否已获某解锁/科技 id。基线恒成立——不依赖 start_new_run/读档是否已跑，
## 测试与工具直达（只 new 出 WorldState 环境）判定一致
func has_unlock(unlock_id: String) -> bool:
	if unlock_id.is_empty():
		return false
	return unlocks.has(unlock_id) or STARTING_UNLOCKS.has(unlock_id)


## 授予解锁/科技（幂等）。首次授予返回 true——调用方据此决定是否广播/提示
func grant_unlock(unlock_id: String) -> bool:
	if unlock_id.is_empty():
		return false
	var is_new := not has_unlock(unlock_id)
	unlocks[unlock_id] = true
	return is_new


## 已获解锁/科技 id（含基线；基线在前、其余按字典序，供展示与断言稳定比对）
func get_unlock_ids() -> Array[String]:
	var out: Array[String] = []
	for id in STARTING_UNLOCKS:
		out.append(id)
	var rest: Array[String] = []
	for id in unlocks.keys():
		var s := String(id)
		if not out.has(s):
			rest.append(s)
	rest.sort()
	for s in rest:
		out.append(s)
	return out


## 清空步行队列（步行完成/读档/新开局）
func reset_walk() -> void:
	walk_legs = []
	walk_index = -1
	walk_target_map_id = ""
	walk_origin_map_id = ""


## 步行是否进行中（在道路场景上）
func is_walking() -> bool:
	return not walk_legs.is_empty()

# SQL 白名单：表名/列名为固定常量；运行时值（slot_id）一律经 ? 绑定
# （query_with_bindings），禁止字符串拼接进 SQL。
const _SQL_WS_SELECT := "SELECT data FROM world_state WHERE slot_id = ? AND module_name = 'world_state'"
const _SQL_WS_DELETE := "DELETE FROM world_state WHERE slot_id = ?"
const _SQL_LEGACY_SELECT := "SELECT data FROM legacy_modules WHERE slot_id = ? AND module_name = 'world_state'"

# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	# 存档走统一信号接口（与 SaveHandler 同契约）；EventBus 先于本单例加载，_ready 时必在
	if EventBus:
		if EventBus.has_signal("game_saving"):
			EventBus.game_saving.connect(_on_game_saving)
		if EventBus.has_signal("game_loaded"):
			EventBus.game_loaded.connect(_on_game_loaded)
	else:
		push_warning("[WorldState] EventBus 不可用，存档功能未接线")


## 存档回调：序列化快照写入 world_state 表
func _on_game_saving(_slot_index: int) -> void:
	var db = SaveManager.get_db() if SaveManager and SaveManager.has_method("get_db") else null
	var slot_id: int = SaveManager.get_current_slot() if SaveManager.has_method("get_current_slot") else -1
	if db == null or slot_id < 0:
		return
	if not db.query_with_bindings(_SQL_WS_DELETE, [slot_id]):
		push_error("[WorldState] world_state 旧状态清理失败 slot=%d: %s" % [slot_id, str(db.error_message)])
	if not db.insert_row("world_state", {
		"slot_id": slot_id,
		"module_name": "world_state",
		"data": JSON.stringify(get_save_data()),
	}):
		push_error("[WorldState] world_state 状态写入失败 slot=%d: %s" % [slot_id, str(db.error_message)])


## 读档回调：从 world_state 表恢复；旧档回退读 legacy_modules（见 _read_legacy_world_state）
func _on_game_loaded(slot_index: int) -> void:
	var db = SaveManager.get_db() if SaveManager and SaveManager.has_method("get_db") else null
	if db == null:
		return
	var rows: Array = []
	if db.query_with_bindings(_SQL_WS_SELECT, [slot_index]):
		rows = db.query_result
	if rows.is_empty():
		rows = _read_legacy_world_state(db, slot_index)
	var data: Dictionary = {}
	if not rows.is_empty():
		var parsed = JSON.parse_string(str(rows[0]["data"]))
		if typeof(parsed) == TYPE_DICTIONARY:
			data = parsed
	load_save_data(data)


## 旧档兼容（2026-08-22 前的存档）：world_state 表无行时回退 legacy_modules.world_state。
## 新存档不再创建 legacy_modules 表，先查 sqlite_master 判断存在性避免查询报错。
func _read_legacy_world_state(db, slot_id: int) -> Array:
	var tables: Array = db.select_rows("sqlite_master", "type = 'table' AND name = 'legacy_modules'", ["name"])
	if tables.is_empty():
		return []
	var rows: Array = []
	if db.query_with_bindings(_SQL_LEGACY_SELECT, [slot_id]):
		rows = db.query_result
	return rows


# ─────────────────────────────── 实体注册 ────────────────────────────────

## 注册一个火柴人实体。
func register_stickman(state: StickmanState) -> void:
	stickmen[state.id] = state


## 注销一个火柴人实体。
func unregister_stickman(entity_id: String) -> void:
	stickmen.erase(entity_id)


## 注册一个组织实体。
func register_organization(state: OrganizationState) -> void:
	organizations[state.id] = state


## 注销一个组织实体。
func unregister_organization(entity_id: String) -> void:
	organizations.erase(entity_id)


## 注册一个地块实体。
## 注意：RegionState.id 为 int 类型，容器中以 str(id) 为 key 存储。
func register_region(state: RegionState) -> void:
	regions[str(state.id)] = state


## 注销一个地块实体。
func unregister_region(entity_id: String) -> void:
	regions.erase(entity_id)


## 注册一个战斗实例实体。
func register_battle(state: BattleState) -> void:
	battles[state.id] = state


## 注销一个战斗实例实体。
func unregister_battle(entity_id: String) -> void:
	battles.erase(entity_id)


## 注册一个项目实体。
func register_project(state: ProjectState) -> void:
	projects[state.id] = state


## 注销一个项目实体。
func unregister_project(entity_id: String) -> void:
	projects.erase(entity_id)


## 注册一个物流链路实体。
func register_supply_chain(state: SupplyChainState) -> void:
	supply_chains[state.id] = state


## 注销一个物流链路实体。
func unregister_supply_chain(entity_id: String) -> void:
	supply_chains.erase(entity_id)


## 注册一个城市实体（统一契约生产域）。
func register_city(state: CityState) -> void:
	cities[state.settlement_id] = state


## 注销一个城市实体。
func unregister_city(settlement_id: String) -> void:
	cities.erase(settlement_id)


## 注册一个政权实体（统一契约生产域）。
func register_faction(state: FactionState) -> void:
	factions[state.state_id] = state


## 注销一个政权实体。
func unregister_faction(state_id: String) -> void:
	factions.erase(state_id)


# ─────────────────────── 统一契约聚合查询 ────────────────────────────────
# 政权实力 = 名下城市聚合（完整版蓝图 §3.4）；所有查询按 settlement_id 排序
# 保证确定性（id 为 %03d 零填充格式，字典序 = 数值序）。

## 某政权名下城市列表（CityState 数组，按 settlement_id 升序）。
## 未注册政权 id 与"注册但 0 城"同语义，返回空数组
func get_faction_cities(state_id: String) -> Array:
	var ids: Array = []
	for settlement_id in cities:
		var city := cities[settlement_id] as CityState
		if city != null and city.owner_state_id == state_id:
			ids.append(str(settlement_id))
	ids.sort()
	var owned: Array = []
	for sid in ids:
		owned.append(cities[sid])
	return owned


## 某政权账面人口 = 名下城市 population 总和
func faction_population(state_id: String) -> int:
	var total := 0
	for city in get_faction_cities(state_id):
		total += int(city.population)
	return total


## 某政权军队账面总兵力 = 名下城市 garrison 数量总和（{profile_id: int} 值求和）
func faction_garrison_total(state_id: String) -> int:
	var total := 0
	for city in get_faction_cities(state_id):
		for profile_id in city.garrison:
			total += int(city.garrison[profile_id])
	return total


## 某政权名下 tile 数——M1 阶段 1 tile 1 聚落，= 名下城数（tile_key 即城的
## 染色口径 id）；tile 粒度细化（1 tile 多聚落/无聚落 tile）后本口径须同步改写
func faction_tile_count(state_id: String) -> int:
	return get_faction_cities(state_id).size()


# ─────────────────────────────── 通用查询 ────────────────────────────────

## 根据实体类型和 ID 查找实体。
## 支持的 entity_type：stickmen, organizations, regions, battles, projects,
## supply_chains, cities, factions
func get_entity(entity_type: String, entity_id: String) -> Variant:
	# Variant 接收：_get_container 未知类型返回 null，typed Dictionary 赋值会先崩
	var container: Variant = _get_container(entity_type)
	if container == null:
		push_warning("[WorldState] 未知实体类型: %s" % entity_type)
		return null
	return container.get(entity_id, null)


## 按条件过滤查询实体。
## filter 接收一个实体参数，返回 bool。返回匹配实体的数组。
func query_entities(entity_type: String, filter: Callable) -> Array:
	var container: Variant = _get_container(entity_type)
	if container == null:
		push_warning("[WorldState] 未知实体类型: %s" % entity_type)
		return []
	var result: Array = []
	for entity in container.values():
		if filter.call(entity):
			result.append(entity)
	return result


## 返回实体类型对应的容器字典引用，不存在则返回 null。
func _get_container(entity_type: String) -> Variant:
	match entity_type:
		"stickmen":
			return stickmen
		"organizations":
			return organizations
		"regions":
			return regions
		"battles":
			return battles
		"projects":
			return projects
		"supply_chains":
			return supply_chains
		"cities":
			return cities
		"factions":
			return factions
		_:
			return null


# ─────────────────────────────── 清理 ────────────────────────────────

## 清理已被销毁的实体引用。
## RefCounted 引用计数归零后自动释放，但 Dictionary 中仍残留 key，
## 此方法遍历所有容器，移除 null 或已失效的引用。
func clean_invalid_refs() -> void:
	_clean_container(stickmen)
	_clean_container(organizations)
	_clean_container(regions)
	_clean_container(battles)
	_clean_container(projects)
	_clean_container(supply_chains)
	_clean_container(cities)
	_clean_container(factions)


## 清理单个容器中无效的实体引用。
func _clean_container(container: Dictionary) -> void:
	var to_remove: Array[String] = []
	for key in container.keys():
		var obj = container[key]
		if obj == null or not (obj is RefCounted):
			to_remove.append(key)
	for key in to_remove:
		container.erase(key)


# ─────────────────────────────── SaveManager 对接 ────────────────────────

## 序列化所有实体状态为 Dictionary。（由 SaveManager 调用）
## 容器名 → 存档键的映射（格式权威）在本文件；字段级编解码在 WorldStateSerializer。
func get_save_data() -> Dictionary:
	return {
		"game_time": game_time,
		"run_seed": run_seed,
		"visited_settlements": visited_settlements.keys(),
		"unlocks": get_unlock_ids(),
		"stickmen": WorldStateSerializer.serialize_dict(stickmen, WorldStateSerializer.stickman_to_dict),
		"organizations": WorldStateSerializer.serialize_dict(organizations, WorldStateSerializer.organization_to_dict),
		"regions": WorldStateSerializer.serialize_dict(regions, WorldStateSerializer.region_to_dict),
		"battles": WorldStateSerializer.serialize_dict(battles, WorldStateSerializer.battle_to_dict),
		"projects": WorldStateSerializer.serialize_dict(projects, WorldStateSerializer.project_to_dict),
		"supply_chains": WorldStateSerializer.serialize_dict(supply_chains, WorldStateSerializer.supply_chain_to_dict),
		"cities": WorldStateSerializer.serialize_dict(cities, WorldStateSerializer.city_to_dict),
		"factions": WorldStateSerializer.serialize_dict(factions, WorldStateSerializer.faction_to_dict),
	}


## 反序列化恢复所有实体状态。（由 SaveManager 调用）
func load_save_data(data: Dictionary) -> void:
	game_time = data.get("game_time", 0.0)
	run_seed = int(data.get("run_seed", 0))
	visited_settlements = {}
	for sid in data.get("visited_settlements", []):
		visited_settlements[str(sid)] = true
	# 解锁池：旧档无 unlocks 字段时为空（基线经 has_unlock 恒生效，不靠存档补齐）
	unlocks = {}
	for uid in data.get("unlocks", []):
		var s := str(uid)
		if not s.is_empty():
			unlocks[s] = true
	reset_walk()  # 步行队列瞬态不进存档——读档恒从聚落出发
	stickmen = WorldStateSerializer.deserialize_dict(data.get("stickmen", {}), WorldStateSerializer.stickman_from_dict)
	organizations = WorldStateSerializer.deserialize_dict(data.get("organizations", {}), WorldStateSerializer.organization_from_dict)
	regions = WorldStateSerializer.deserialize_dict(data.get("regions", {}), WorldStateSerializer.region_from_dict)
	battles = WorldStateSerializer.deserialize_dict(data.get("battles", {}), WorldStateSerializer.battle_from_dict)
	projects = WorldStateSerializer.deserialize_dict(data.get("projects", {}), WorldStateSerializer.project_from_dict)
	supply_chains = WorldStateSerializer.deserialize_dict(data.get("supply_chains", {}), WorldStateSerializer.supply_chain_from_dict)
	# 统一契约两域：旧档缺键回退空域不崩（int/float 类型还原与坏值兜底在
	# city_from_dict/faction_from_dict 逐字段负责）
	cities = WorldStateSerializer.deserialize_dict(data.get("cities", {}), WorldStateSerializer.city_from_dict)
	factions = WorldStateSerializer.deserialize_dict(data.get("factions", {}), WorldStateSerializer.faction_from_dict)
