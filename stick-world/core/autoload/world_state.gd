extends Node
## 运行时世界状态中心 —— 集中管理所有实体状态。
##
## 所有游戏实体（stickmen、organizations、regions 等）的状态存储于此，
## 各模块通过 WorldState 读写实体数据，而非各自维护独立状态。
##
## 与 SaveManager 协作：在 _ready() 中通过 register_module 注册自身，
## SaveManager 存档时调用 get_save_data() / load_save_data()。

# ─────────────────────────────── 实体容器 ────────────────────────────────

var stickmen: Dictionary = {}          # {id: StickmanState}
var organizations: Dictionary = {}      # {id: OrganizationState}
var regions: Dictionary = {}            # {str(id): RegionState}
var battles: Dictionary = {}            # {id: BattleState}
var projects: Dictionary = {}           # {id: ProjectState}
var supply_chains: Dictionary = {}      # {id: SupplyChainState}

# ─────────────────────────────── 全局状态 ────────────────────────────────

var game_time: float = 0.0

# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	# 向 SaveManager 注册自身，启用存档功能
	if SaveManager and SaveManager.has_method("register_module"):
		SaveManager.register_module("world_state", self)
	else:
		push_warning("[WorldState] SaveManager 不可用，存档功能未注册")


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
func get_save_data() -> Dictionary:
	return {
		"game_time": game_time,
		"stickmen": _serialize_dict(stickmen, _stickman_to_dict),
		"organizations": _serialize_dict(organizations, _organization_to_dict),
		"regions": _serialize_dict(regions, _region_to_dict),
		"battles": _serialize_dict(battles, _battle_to_dict),
		"projects": _serialize_dict(projects, _project_to_dict),
		"supply_chains": _serialize_dict(supply_chains, _supply_chain_to_dict),
	}


## 反序列化恢复所有实体状态。（由 SaveManager 调用）
func load_save_data(data: Dictionary) -> void:
	game_time = data.get("game_time", 0.0)
	stickmen = _deserialize_dict(data.get("stickmen", {}), _stickman_from_dict)
	organizations = _deserialize_dict(data.get("organizations", {}), _organization_from_dict)
	regions = _deserialize_dict(data.get("regions", {}), _region_from_dict)
	battles = _deserialize_dict(data.get("battles", {}), _battle_from_dict)
	projects = _deserialize_dict(data.get("projects", {}), _project_from_dict)
	supply_chains = _deserialize_dict(data.get("supply_chains", {}), _supply_chain_from_dict)


# ─────────────────────────────── 序列化辅助 ──────────────────────────────

## 将实体字典序列化为普通 Dictionary（JSON 友好）。
static func _serialize_dict(dict: Dictionary, serializer: Callable) -> Dictionary:
	var result: Dictionary = {}
	for key in dict.keys():
		var entity = dict[key]
		if entity != null:
			result[str(key)] = serializer.call(entity)
	return result


## 将普通 Dictionary 反序列化为实体字典。
static func _deserialize_dict(data: Dictionary, deserializer: Callable) -> Dictionary:
	var result: Dictionary = {}
	for key in data.keys():
		var entity = deserializer.call(data[key])
		if entity != null:
			result[key] = entity
	return result


# ── Stickman ──

static func _stickman_to_dict(s: StickmanState) -> Dictionary:
	return {
		"id": s.id,
		"name": s.name,
		"race": s.race,
		"variant": s.variant,
		"age": s.age,
		"hp": s.hp,
		"max_hp": s.max_hp,
		"stamina": s.stamina,
		"max_stamina": s.max_stamina,
		"morale": s.morale,
		"attack": s.attack,
		"defense": s.defense,
		"speed": s.speed,
		"equipment": s.equipment.duplicate(),
		"skills": s.skills.duplicate(),
		"traits": s.traits.duplicate(),
		"current_task": s.current_task,
		"assigned_org": s.assigned_org,
		"org_rank": s.org_rank,
		"org_role": s.org_role,
		"location": [s.location.x, s.location.y],
		"state": s.state,
	}


static func _stickman_from_dict(d: Dictionary) -> StickmanState:
	var s: StickmanState = StickmanState.new()
	s.id = d.get("id", "")
	s.name = d.get("name", "")
	s.race = d.get("race", 0)
	s.variant = d.get("variant", 0)
	s.age = d.get("age", 1)
	s.hp = d.get("hp", 0.0)
	s.max_hp = d.get("max_hp", 0.0)
	s.stamina = d.get("stamina", 0.0)
	s.max_stamina = d.get("max_stamina", 0.0)
	s.morale = d.get("morale", 0.0)
	s.attack = d.get("attack", 0.0)
	s.defense = d.get("defense", 0.0)
	s.speed = d.get("speed", 0.0)
	s.equipment = d.get("equipment", {}).duplicate()
	s.skills = d.get("skills", []).duplicate()
	s.traits = d.get("traits", []).duplicate()
	s.current_task = d.get("current_task", "")
	s.assigned_org = d.get("assigned_org", "")
	s.org_rank = d.get("org_rank", 0)
	s.org_role = d.get("org_role", "")
	var loc: Array = d.get("location", [0.0, 0.0])
	s.location = Vector2(loc[0], loc[1]) if loc.size() >= 2 else Vector2.ZERO
	s.state = d.get("state", 0)
	return s


# ── Organization ──

static func _organization_to_dict(o: OrganizationState) -> Dictionary:
	return {
		"id": o.id,
		"name": o.name,
		"tag": o.tag,
		"tier": o.tier,
		"parent_org": o.parent_org,
		"child_orgs": o.child_orgs.duplicate(),
		"commander_id": o.commander_id,
		"personnel": o.personnel.duplicate(),
		"personnel_template": o.personnel_template.duplicate(),
		"equipment_template": o.equipment_template.duplicate(),
		"autonomy_level": o.autonomy_level,
		"default_behavior": o.default_behavior.duplicate(),
		"supply_priority": o.supply_priority,
		"morale_threshold": o.morale_threshold,
		"current_project": o.current_project,
		"location": o.location,
		"state": o.state,
	}


static func _organization_from_dict(d: Dictionary) -> OrganizationState:
	var o: OrganizationState = OrganizationState.new()
	o.id = d.get("id", "")
	o.name = d.get("name", "")
	o.tag = d.get("tag", 0)
	o.tier = d.get("tier", 1)
	o.parent_org = d.get("parent_org", "")
	o.child_orgs = d.get("child_orgs", []).duplicate()
	o.commander_id = d.get("commander_id", "")
	o.personnel = d.get("personnel", []).duplicate()
	o.personnel_template = d.get("personnel_template", {}).duplicate()
	o.equipment_template = d.get("equipment_template", {}).duplicate()
	o.autonomy_level = d.get("autonomy_level", 1)
	o.default_behavior = d.get("default_behavior", {}).duplicate()
	o.supply_priority = d.get("supply_priority", 1)
	o.morale_threshold = d.get("morale_threshold", 0.0)
	o.current_project = d.get("current_project", "")
	o.location = d.get("location", "")
	o.state = d.get("state", 0)
	return o


# ── Region ──

static func _region_to_dict(r: RegionState) -> Dictionary:
	return {
		"id": r.id,
		"name": r.name,
		"type": r.type,
		"is_coastal": r.is_coastal,
		"resource_types": r.resource_types.duplicate(),
		"stickman_types": r.stickman_types.duplicate(),
		"tech_unlocks": r.tech_unlocks.duplicate(),
		"initial_owner": r.initial_owner,
		"adjacent_region_ids": r.adjacent_region_ids.duplicate(),
		"center_position": [r.center_position.x, r.center_position.y],
		"outline_points": _serialize_vec2_array(r.outline_points),
		"control_percentage": r.control_percentage,
		"cultural_affinity": r.cultural_affinity.duplicate(),
		"infrastructure_level": r.infrastructure_level,
		"buildings": r.buildings.duplicate(),
		"organizations_present": r.organizations_present.duplicate(),
		"battles_active": r.battles_active.duplicate(),
	}


static func _region_from_dict(d: Dictionary) -> RegionState:
	var r: RegionState = RegionState.new()
	r.id = d.get("id", 0)
	r.name = d.get("name", "")
	r.type = d.get("type", 0)
	r.is_coastal = d.get("is_coastal", false)
	r.resource_types = d.get("resource_types", []).duplicate()
	r.stickman_types = d.get("stickman_types", []).duplicate()
	r.tech_unlocks = d.get("tech_unlocks", []).duplicate()
	r.initial_owner = d.get("initial_owner", -1)
	r.adjacent_region_ids = d.get("adjacent_region_ids", []).duplicate()
	var cp: Array = d.get("center_position", [0.0, 0.0])
	r.center_position = Vector2(cp[0], cp[1]) if cp.size() >= 2 else Vector2.ZERO
	r.outline_points = _deserialize_vec2_array(d.get("outline_points", []))
	r.control_percentage = d.get("control_percentage", 0.0)
	r.cultural_affinity = d.get("cultural_affinity", {}).duplicate()
	r.infrastructure_level = d.get("infrastructure_level", 0.0)
	r.buildings = d.get("buildings", []).duplicate()
	r.organizations_present = d.get("organizations_present", []).duplicate()
	r.battles_active = d.get("battles_active", []).duplicate()
	return r


# ── Battle ──

static func _battle_to_dict(b: BattleState) -> Dictionary:
	return {
		"id": b.id,
		"region_id": b.region_id,
		"attacker_orgs": b.attacker_orgs.duplicate(),
		"defender_orgs": b.defender_orgs.duplicate(),
		"state": b.state,
		"casualties_attacker": b.casualties_attacker,
		"casualties_defender": b.casualties_defender,
		"duration": b.duration,
		"tactical_data": b.tactical_data.duplicate(),
	}


static func _battle_from_dict(d: Dictionary) -> BattleState:
	var b: BattleState = BattleState.new()
	b.id = d.get("id", "")
	b.region_id = d.get("region_id", "")
	b.attacker_orgs = d.get("attacker_orgs", []).duplicate()
	b.defender_orgs = d.get("defender_orgs", []).duplicate()
	b.state = d.get("state", 0)
	b.casualties_attacker = d.get("casualties_attacker", 0)
	b.casualties_defender = d.get("casualties_defender", 0)
	b.duration = d.get("duration", 0.0)
	b.tactical_data = d.get("tactical_data", {}).duplicate()
	return b


# ── Project ──

static func _project_to_dict(p: ProjectState) -> Dictionary:
	return {
		"id": p.id,
		"type": p.type,
		"owner_org_id": p.owner_org_id,
		"name": p.name,
		"description": p.description,
		"state": p.state,
		"progress": p.progress,
		"assigned_orgs": p.assigned_orgs.duplicate(),
		"assigned_resources": p.assigned_resources.duplicate(),
		"sub_projects": p.sub_projects.duplicate(),
		"parent_project": p.parent_project,
		"start_time": p.start_time,
		"deadline": p.deadline,
		"result": p.result.duplicate(),
	}


static func _project_from_dict(d: Dictionary) -> ProjectState:
	var p: ProjectState = ProjectState.new()
	p.id = d.get("id", "")
	p.type = d.get("type", 0)
	p.owner_org_id = d.get("owner_org_id", "")
	p.name = d.get("name", "")
	p.description = d.get("description", "")
	p.state = d.get("state", 0)
	p.progress = d.get("progress", 0.0)
	p.assigned_orgs = d.get("assigned_orgs", []).duplicate()
	p.assigned_resources = d.get("assigned_resources", {}).duplicate()
	p.sub_projects = d.get("sub_projects", []).duplicate()
	p.parent_project = d.get("parent_project", "")
	p.start_time = d.get("start_time", 0.0)
	p.deadline = d.get("deadline", 0.0)
	p.result = d.get("result", {}).duplicate()
	return p


# ── SupplyChain ──

static func _supply_chain_to_dict(sc: SupplyChainState) -> Dictionary:
	return {
		"id": sc.id,
		"origin_region": sc.origin_region,
		"destination_region": sc.destination_region,
		"resource_type": sc.resource_type,
		"quantity": sc.quantity,
		"frequency": sc.frequency,
		"carrier_org_id": sc.carrier_org_id,
		"route": _serialize_vec2_array(sc.route),
		"state": sc.state,
		"efficiency": sc.efficiency,
	}


static func _supply_chain_from_dict(d: Dictionary) -> SupplyChainState:
	var sc: SupplyChainState = SupplyChainState.new()
	sc.id = d.get("id", "")
	sc.origin_region = d.get("origin_region", "")
	sc.destination_region = d.get("destination_region", "")
	sc.resource_type = d.get("resource_type", "")
	sc.quantity = d.get("quantity", 0.0)
	sc.frequency = d.get("frequency", 0.0)
	sc.carrier_org_id = d.get("carrier_org_id", "")
	sc.route = _deserialize_vec2_array(d.get("route", []))
	sc.state = d.get("state", 0)
	sc.efficiency = d.get("efficiency", 0.0)
	return sc


# ── Vector2 序列化辅助 ──

## 将 Array[Vector2] 序列化为 Array[Array]（JSON 友好）。
static func _serialize_vec2_array(vecs: Array) -> Array:
	var result: Array = []
	for v in vecs:
		result.append([v.x, v.y])
	return result


## 将 Array[Array] 反序列化为 Array[Vector2]。
static func _deserialize_vec2_array(data: Array) -> Array:
	var result: Array = []
	for item in data:
		if item is Array and item.size() >= 2:
			result.append(Vector2(item[0], item[1]))
	return result
