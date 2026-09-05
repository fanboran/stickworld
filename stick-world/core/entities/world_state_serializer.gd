class_name WorldStateSerializer
extends RefCounted
## 世界状态序列化器 —— world_state 六大实体容器的 JSON 友好编解码。
##
## 职责：纯静态无状态编解码（State ↔ Dictionary），存档格式权威仍在 world_state.gd
## （容器名 → 存档键的映射由其 get_save_data/load_save_data 掌握）。
##
## ⚠️ 冻结预留：对接的六容器与 core/entities 状态类均未接入生产数据流
## （见 world_state.gd 头注），technology 阶段 1 重建时再决策接入或归档。
##
## 兼容性约束：字段名/默认值/结构改动 = 存档格式变更，旧档会丢字段，
## 改动前须确认 round-trip 测试（tests/unit/test_entity_states.gd）同步更新。

# ─────────────────────────────── 通用编解码 ────────────────────────────────

## 将实体字典序列化为普通 Dictionary（JSON 友好）。
static func serialize_dict(dict: Dictionary, serializer: Callable) -> Dictionary:
	var result: Dictionary = {}
	for key in dict.keys():
		var entity = dict[key]
		if entity != null:
			result[str(key)] = serializer.call(entity)
	return result


## 将普通 Dictionary 反序列化为实体字典。
static func deserialize_dict(data: Dictionary, deserializer: Callable) -> Dictionary:
	var result: Dictionary = {}
	for key in data.keys():
		var entity = deserializer.call(data[key])
		if entity != null:
			result[key] = entity
	return result


# ── Stickman ──

static func stickman_to_dict(s: StickmanState) -> Dictionary:
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


static func stickman_from_dict(d: Dictionary) -> StickmanState:
	var s: StickmanState = StickmanState.new()
	s.id = d.get("id", "")
	s.name = d.get("name", "")
	s.race = int(d.get("race", 0))
	s.variant = int(d.get("variant", 0))
	s.age = int(d.get("age", 1))
	s.hp = d.get("hp", 0.0)
	s.max_hp = d.get("max_hp", 0.0)
	s.stamina = d.get("stamina", 0.0)
	s.max_stamina = d.get("max_stamina", 0.0)
	s.morale = d.get("morale", 0.0)
	s.attack = d.get("attack", 0.0)
	s.defense = d.get("defense", 0.0)
	s.speed = d.get("speed", 0.0)
	s.equipment = d.get("equipment", {}).duplicate()
	s.skills.assign(d.get("skills", []))
	s.traits.assign(d.get("traits", []))
	s.current_task = d.get("current_task", "")
	s.assigned_org = d.get("assigned_org", "")
	s.org_rank = int(d.get("org_rank", 0))
	s.org_role = d.get("org_role", "")
	var loc: Array = d.get("location", [0.0, 0.0])
	s.location = Vector2(loc[0], loc[1]) if loc.size() >= 2 else Vector2.ZERO
	s.state = int(d.get("state", 0))
	return s


# ── Organization ──

static func organization_to_dict(o: OrganizationState) -> Dictionary:
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


static func organization_from_dict(d: Dictionary) -> OrganizationState:
	var o: OrganizationState = OrganizationState.new()
	o.id = d.get("id", "")
	o.name = d.get("name", "")
	o.tag = int(d.get("tag", 0))
	o.tier = int(d.get("tier", 1))
	o.parent_org = d.get("parent_org", "")
	o.child_orgs.assign(d.get("child_orgs", []))
	o.commander_id = d.get("commander_id", "")
	o.personnel.assign(d.get("personnel", []))
	o.personnel_template = d.get("personnel_template", {}).duplicate()
	o.equipment_template = d.get("equipment_template", {}).duplicate()
	o.autonomy_level = int(d.get("autonomy_level", 1))
	o.default_behavior = d.get("default_behavior", {}).duplicate()
	o.supply_priority = int(d.get("supply_priority", 1))
	o.morale_threshold = d.get("morale_threshold", 0.0)
	o.current_project = d.get("current_project", "")
	o.location = d.get("location", "")
	o.state = int(d.get("state", 0))
	return o


# ── Region ──

static func region_to_dict(r: RegionState) -> Dictionary:
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


static func region_from_dict(d: Dictionary) -> RegionState:
	var r: RegionState = RegionState.new()
	r.id = int(d.get("id", 0))
	r.name = d.get("name", "")
	r.type = int(d.get("type", 0))
	r.is_coastal = d.get("is_coastal", false)
	r.resource_types.assign(d.get("resource_types", []))
	r.stickman_types.assign(d.get("stickman_types", []))
	r.tech_unlocks.assign(d.get("tech_unlocks", []))
	r.initial_owner = int(d.get("initial_owner", -1))
	r.adjacent_region_ids.assign(d.get("adjacent_region_ids", []))
	var cp: Array = d.get("center_position", [0.0, 0.0])
	r.center_position = Vector2(cp[0], cp[1]) if cp.size() >= 2 else Vector2.ZERO
	r.outline_points.assign(_deserialize_vec2_array(d.get("outline_points", [])))
	r.control_percentage = d.get("control_percentage", 0.0)
	r.cultural_affinity = d.get("cultural_affinity", {}).duplicate()
	r.infrastructure_level = d.get("infrastructure_level", 0.0)
	r.buildings.assign(d.get("buildings", []))
	r.organizations_present.assign(d.get("organizations_present", []))
	r.battles_active.assign(d.get("battles_active", []))
	return r


# ── Battle ──

static func battle_to_dict(b: BattleState) -> Dictionary:
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


static func battle_from_dict(d: Dictionary) -> BattleState:
	var b: BattleState = BattleState.new()
	b.id = d.get("id", "")
	b.region_id = d.get("region_id", "")
	b.attacker_orgs.assign(d.get("attacker_orgs", []))
	b.defender_orgs.assign(d.get("defender_orgs", []))
	b.state = int(d.get("state", 0))
	b.casualties_attacker = int(d.get("casualties_attacker", 0))
	b.casualties_defender = int(d.get("casualties_defender", 0))
	b.duration = d.get("duration", 0.0)
	b.tactical_data = d.get("tactical_data", {}).duplicate()
	return b


# ── Project ──

static func project_to_dict(p: ProjectState) -> Dictionary:
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


static func project_from_dict(d: Dictionary) -> ProjectState:
	var p: ProjectState = ProjectState.new()
	p.id = d.get("id", "")
	p.type = int(d.get("type", 0))
	p.owner_org_id = d.get("owner_org_id", "")
	p.name = d.get("name", "")
	p.description = d.get("description", "")
	p.state = int(d.get("state", 0))
	p.progress = d.get("progress", 0.0)
	p.assigned_orgs.assign(d.get("assigned_orgs", []))
	p.assigned_resources = d.get("assigned_resources", {}).duplicate()
	p.sub_projects.assign(d.get("sub_projects", []))
	p.parent_project = d.get("parent_project", "")
	p.start_time = d.get("start_time", 0.0)
	p.deadline = d.get("deadline", 0.0)
	p.result = d.get("result", {}).duplicate()
	return p


# ── SupplyChain ──

static func supply_chain_to_dict(sc: SupplyChainState) -> Dictionary:
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


static func supply_chain_from_dict(d: Dictionary) -> SupplyChainState:
	var sc: SupplyChainState = SupplyChainState.new()
	sc.id = d.get("id", "")
	sc.origin_region = d.get("origin_region", "")
	sc.destination_region = d.get("destination_region", "")
	sc.resource_type = d.get("resource_type", "")
	sc.quantity = d.get("quantity", 0.0)
	sc.frequency = d.get("frequency", 0.0)
	sc.carrier_org_id = d.get("carrier_org_id", "")
	sc.route.assign(_deserialize_vec2_array(d.get("route", [])))
	sc.state = int(d.get("state", 0))
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
