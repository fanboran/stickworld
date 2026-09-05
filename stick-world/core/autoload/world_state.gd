extends Node
## 运行时世界状态中心 —— 集中管理所有实体状态。
##
## ⚠️ 冻结状态（2026-08-22 审计决策）：
##   - 仅 game_time 为生产字段（EnvironmentSystem 推进/恢复）；
##   - 六大实体容器（stickmen/organizations/regions/battles/projects/supply_chains）
##     全部零调用，处于冻结预留态——不删除、不接线，technology 阶段 1 重建时
##     再决策接入或归档；core/entities/ 七个状态类同步冻结；
##   - 存档走 game_saving/game_loaded 信号直写 world_state 表（含旧档回退）。
##
## 所有游戏实体（stickmen、organizations、regions 等）的状态存储于此，
## 各模块通过 WorldState 读写实体数据，而非各自维护独立状态。

# ─────────────────────────────── 实体容器 ────────────────────────────────

var stickmen: Dictionary = {}          # {id: StickmanState}
var organizations: Dictionary = {}      # {id: OrganizationState}
var regions: Dictionary = {}            # {str(id): RegionState}
var battles: Dictionary = {}            # {id: BattleState}
var projects: Dictionary = {}           # {id: ProjectState}
var supply_chains: Dictionary = {}      # {id: SupplyChainState}

# ─────────────────────────────── 全局状态 ────────────────────────────────

## 当前游戏时刻（小时 0.0 ~ 24.0，由 EnvironmentSystem 推进与写入）
var game_time: float = 0.0

## 本局随机种子（新开局随机一次，随存档保存/恢复；读档后逐点复现本局扰动，
## 供 population_score ±15% 每局扰动等确定性随机使用，总体设计 §5.7）
var run_seed: int = 0


## 新开局：重置本局种子（GameRoot 新游戏分支调用；读档路径走 load_save_data 恢复）
func start_new_run() -> void:
	run_seed = randi()

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


# ─────────────────────────────── 通用查询 ────────────────────────────────

## 根据实体类型和 ID 查找实体。
## 支持的 entity_type：stickmen, organizations, regions, battles, projects, supply_chains
func get_entity(entity_type: String, entity_id: String) -> Variant:
	var container: Dictionary = _get_container(entity_type)
	if container == null:
		push_warning("[WorldState] 未知实体类型: %s" % entity_type)
		return null
	return container.get(entity_id, null)


## 按条件过滤查询实体。
## filter 接收一个实体参数，返回 bool。返回匹配实体的数组。
func query_entities(entity_type: String, filter: Callable) -> Array:
	var container: Dictionary = _get_container(entity_type)
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
		"stickmen": WorldStateSerializer.serialize_dict(stickmen, WorldStateSerializer.stickman_to_dict),
		"organizations": WorldStateSerializer.serialize_dict(organizations, WorldStateSerializer.organization_to_dict),
		"regions": WorldStateSerializer.serialize_dict(regions, WorldStateSerializer.region_to_dict),
		"battles": WorldStateSerializer.serialize_dict(battles, WorldStateSerializer.battle_to_dict),
		"projects": WorldStateSerializer.serialize_dict(projects, WorldStateSerializer.project_to_dict),
		"supply_chains": WorldStateSerializer.serialize_dict(supply_chains, WorldStateSerializer.supply_chain_to_dict),
	}


## 反序列化恢复所有实体状态。（由 SaveManager 调用）
func load_save_data(data: Dictionary) -> void:
	game_time = data.get("game_time", 0.0)
	run_seed = int(data.get("run_seed", 0))
	stickmen = WorldStateSerializer.deserialize_dict(data.get("stickmen", {}), WorldStateSerializer.stickman_from_dict)
	organizations = WorldStateSerializer.deserialize_dict(data.get("organizations", {}), WorldStateSerializer.organization_from_dict)
	regions = WorldStateSerializer.deserialize_dict(data.get("regions", {}), WorldStateSerializer.region_from_dict)
	battles = WorldStateSerializer.deserialize_dict(data.get("battles", {}), WorldStateSerializer.battle_from_dict)
	projects = WorldStateSerializer.deserialize_dict(data.get("projects", {}), WorldStateSerializer.project_from_dict)
	supply_chains = WorldStateSerializer.deserialize_dict(data.get("supply_chains", {}), WorldStateSerializer.supply_chain_from_dict)
