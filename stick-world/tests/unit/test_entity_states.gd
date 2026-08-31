extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：WorldState 状态类序列化 round-trip（存档完整性）。
## 2026-08 补充：core/entities 8 个状态类此前零测试触点。
## 纯数据层测试：new 即用，不进场景树，确定性。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptWS := preload("res://core/autoload/world_state.gd")
const ScriptSerializer := preload("res://core/entities/world_state_serializer.gd")
const ScriptStickmanState := preload("res://core/entities/stickman_state.gd")
const ScriptOrgState := preload("res://core/entities/organization_state.gd")
const ScriptRegionState := preload("res://core/entities/region_state.gd")
const ScriptBattleState := preload("res://core/entities/battle_state.gd")
const ScriptProjectState := preload("res://core/entities/project_state.gd")
const ScriptSupplyChainState := preload("res://core/entities/supply_chain_state.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("State: Stickman round-trip 字段保真", _test_stickman)
	_runner.add_test("State: Organization round-trip 字段保真", _test_organization)
	_runner.add_test("State: Region round-trip（含 Vector2 数组）", _test_region)
	_runner.add_test("State: Battle round-trip 字段保真", _test_battle)
	_runner.add_test("State: Project round-trip 字段保真", _test_project)
	_runner.add_test("State: SupplyChain round-trip（含路线）", _test_supply_chain)
	_runner.add_test("State: WorldState 整体 save/load 全实体恢复", _test_world_state_roundtrip)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _test_stickman() -> void:
	var s = ScriptStickmanState.new()
	s.id = "sm_1"
	s.name = "阿强"
	s.race = 3
	s.variant = 1
	s.age = 25
	s.hp = 80.0
	s.max_hp = 100.0
	s.morale = 0.9
	s.equipment = {"rifle": 1}
	s.skills.assign(["shoot"])
	s.traits.assign(["brave"])
	s.location = Vector2(12.5, -8.0)
	s.state = 2
	var d: Dictionary = ScriptSerializer.stickman_to_dict(s)
	var s2 = ScriptSerializer.stickman_from_dict(d)
	_runner.assert_equal(s2.id, "sm_1", "id 保真")
	_runner.assert_equal(s2.name, "阿强", "name 保真")
	_runner.assert_equal(s2.race, 3, "race 保真")
	_runner.assert_equal(s2.hp, 80.0, "hp 保真")
	_runner.assert_equal(s2.equipment, {"rifle": 1}, "equipment 保真")
	_runner.assert_equal(s2.location, Vector2(12.5, -8.0), "location Vector2 保真")
	_runner.assert_equal(s2.state, 2, "state 保真")


func _test_organization() -> void:
	var o = ScriptOrgState.new()
	o.id = "org_1"
	o.name = "师部"
	o.tag = 0
	o.tier = 4
	o.parent_org = "org_0"
	o.child_orgs.assign(["org_2"])
	o.commander_id = "sm_1"
	o.personnel.assign(["sm_1", "sm_2"])
	o.personnel_template = {"rifleman": 4}
	o.equipment_template = {"rifle": 4}
	o.autonomy_level = 1
	o.default_behavior = {"aggro": 0.5}
	o.supply_priority = 2
	o.morale_threshold = 0.3
	o.current_project = "proj_1"
	o.location = "r1"
	o.state = 1
	var d: Dictionary = ScriptSerializer.organization_to_dict(o)
	var o2 = ScriptSerializer.organization_from_dict(d)
	_runner.assert_equal(o2.id, "org_1", "id 保真")
	_runner.assert_equal(o2.tier, 4, "tier 保真")
	_runner.assert_equal(o2.child_orgs, ["org_2"], "child_orgs 保真")
	_runner.assert_equal(o2.personnel, ["sm_1", "sm_2"], "personnel 保真")
	_runner.assert_equal(o2.personnel_template, {"rifleman": 4}, "人员编制保真")
	_runner.assert_equal(o2.autonomy_level, 1, "autonomy_level 保真")
	_runner.assert_equal(o2.state, 1, "state 保真")


func _test_region() -> void:
	var r = ScriptRegionState.new()
	r.id = 5
	r.name = "平原一"
	r.type = 1
	r.is_coastal = true
	r.resource_types.assign(["wood"])
	r.tech_unlocks.assign(["t1"])
	r.initial_owner = 2
	r.adjacent_region_ids.assign([4, 6])
	r.center_position = Vector2(100.0, 200.0)
	r.outline_points.assign([Vector2(0, 0), Vector2(10, 10), Vector2(20, 0)])
	r.control_percentage = 0.75
	r.cultural_affinity = {"plain": 0.5}
	r.infrastructure_level = 0.3
	r.buildings.assign(["b1"])
	r.organizations_present.assign(["org_1"])
	r.battles_active.assign(["bt_1"])
	var d: Dictionary = ScriptSerializer.region_to_dict(r)
	var r2 = ScriptSerializer.region_from_dict(d)
	_runner.assert_equal(r2.id, 5, "id 保真")
	_runner.assert_equal(r2.is_coastal, true, "is_coastal 保真")
	_runner.assert_equal(r2.center_position, Vector2(100.0, 200.0), "center_position 保真")
	_runner.assert_equal(r2.outline_points, [Vector2(0, 0), Vector2(10, 10), Vector2(20, 0)], "outline_points Vector2 数组保真")
	_runner.assert_equal(r2.control_percentage, 0.75, "control_percentage 保真")
	_runner.assert_equal(r2.cultural_affinity, {"plain": 0.5}, "cultural_affinity 保真")


func _test_battle() -> void:
	var b = ScriptBattleState.new()
	b.id = "bt_1"
	b.region_id = "r1"
	b.attacker_orgs.assign(["org_1"])
	b.defender_orgs.assign(["org_2"])
	b.state = 1
	b.casualties_attacker = 3
	b.casualties_defender = 5
	b.duration = 12.5
	b.tactical_data = {"flank": true}
	var d: Dictionary = ScriptSerializer.battle_to_dict(b)
	var b2 = ScriptSerializer.battle_from_dict(d)
	_runner.assert_equal(b2.region_id, "r1", "region_id 保真")
	_runner.assert_equal(b2.state, 1, "state 保真")
	_runner.assert_equal(b2.casualties_attacker, 3, "attacker 伤亡保真")
	_runner.assert_equal(b2.casualties_defender, 5, "defender 伤亡保真")
	_runner.assert_equal(b2.duration, 12.5, "duration 保真")
	_runner.assert_equal(b2.tactical_data, {"flank": true}, "tactical_data 保真")


func _test_project() -> void:
	var p = ScriptProjectState.new()
	p.id = "proj_1"
	p.type = 1
	p.owner_org_id = "org_1"
	p.name = "修路"
	p.description = "r1-r2 道路"
	p.state = 2
	p.progress = 0.6
	p.assigned_orgs.assign(["org_1"])
	p.assigned_resources = {"res_wood": 10.0}
	p.sub_projects.assign(["proj_2"])
	p.parent_project = "proj_0"
	p.start_time = 10.0
	p.deadline = 20.0
	p.result = {"done": true}
	var d: Dictionary = ScriptSerializer.project_to_dict(p)
	var p2 = ScriptSerializer.project_from_dict(d)
	_runner.assert_equal(p2.owner_org_id, "org_1", "owner_org_id 保真")
	_runner.assert_equal(p2.progress, 0.6, "progress 保真")
	_runner.assert_equal(p2.assigned_resources, {"res_wood": 10.0}, "assigned_resources 保真")
	_runner.assert_equal(p2.sub_projects, ["proj_2"], "sub_projects 保真")
	_runner.assert_equal(p2.result, {"done": true}, "result 保真")


func _test_supply_chain() -> void:
	var sc = ScriptSupplyChainState.new()
	sc.id = "chain_1"
	sc.origin_region = "r1"
	sc.destination_region = "r2"
	sc.resource_type = "res_wood"
	sc.quantity = 50.0
	sc.frequency = 2.0
	sc.carrier_org_id = "org_3"
	sc.route.assign([Vector2(0, 0), Vector2(30, 40)])
	sc.state = 1
	sc.efficiency = 0.9
	var d: Dictionary = ScriptSerializer.supply_chain_to_dict(sc)
	var sc2 = ScriptSerializer.supply_chain_from_dict(d)
	_runner.assert_equal(sc2.origin_region, "r1", "origin 保真")
	_runner.assert_equal(sc2.resource_type, "res_wood", "resource_type 保真")
	_runner.assert_equal(sc2.quantity, 50.0, "quantity 保真")
	_runner.assert_equal(sc2.route, [Vector2(0, 0), Vector2(30, 40)], "route Vector2 数组保真")
	_runner.assert_equal(sc2.efficiency, 0.9, "efficiency 保真")


func _test_world_state_roundtrip() -> void:
	# WorldState 实例级 save/load：注册 3 类实体后整体恢复
	var ws := ScriptWS.new()
	ws.game_time = 14.5
	var s = ScriptStickmanState.new()
	s.id = "sm_1"
	s.name = "阿强"
	s.location = Vector2(5.0, 6.0)
	ws.register_stickman(s)
	var o = ScriptOrgState.new()
	o.id = "org_1"
	o.name = "师部"
	o.tier = 4
	ws.register_organization(o)
	var r = ScriptRegionState.new()
	r.id = 3
	r.name = "平原"
	ws.register_region(r)

	var save: Dictionary = ws.get_save_data()
	_runner.assert_equal(save.stickmen.size(), 1, "存档含 1 个 stickman")
	_runner.assert_equal(save.organizations.size(), 1, "存档含 1 个组织")
	_runner.assert_equal(save.regions.size(), 1, "存档含 1 个地块")

	var ws2 := ScriptWS.new()
	ws2.load_save_data(save)
	_runner.assert_equal(ws2.game_time, 14.5, "game_time 保真")
	var s2 = ws2.get_entity("stickmen", "sm_1")
	_runner.assert_not_null(s2, "stickman 恢复存在")
	_runner.assert_equal(s2.name, "阿强", "stickman name 保真")
	_runner.assert_equal(s2.location, Vector2(5.0, 6.0), "stickman location 保真")
	var o2 = ws2.get_entity("organizations", "org_1")
	_runner.assert_not_null(o2, "组织恢复存在")
	_runner.assert_equal(o2.tier, 4, "组织 tier 保真")
	var r2 = ws2.get_entity("regions", "3")
	_runner.assert_not_null(r2, "地块恢复存在（key 字符串化）")
	_runner.assert_equal(r2.name, "平原", "地块 name 保真")
