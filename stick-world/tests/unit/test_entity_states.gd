extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：WorldState 状态类序列化 round-trip（存档完整性）。
## 2026-08 补充：core/entities 8 个状态类此前零测试触点。
## 2026-09 补充：CityState/FactionState 统一契约（世界模型整合 M1）往返与
## 聚合查询用例——JSON 往返 int→float 还原是存档管线真实口径。
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
const ScriptCityState := preload("res://core/entities/city_state.gd")
const ScriptFactionState := preload("res://core/entities/faction_state.gd")

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
	_runner.add_test("State: City round-trip 字段保真（统一契约）", _test_city)
	_runner.add_test("State: Faction round-trip 字段保真（统一契约）", _test_faction)
	_runner.add_test("State: City/Faction 坏类型值不崩、还原或取默认", _test_bad_types)
	_runner.add_test("State: 新开局玩家政权同构壳", _test_player_faction_shell)
	_runner.add_test("State: 政权聚合查询（population/garrison/tile）", _test_faction_aggregates)
	_runner.add_test("State: cities/factions JSON 往返 int 类型还原", _test_world_model_json_roundtrip)
	_runner.add_test("State: 旧档缺 cities/factions 键回退空域", _test_legacy_save_missing_domains)
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


# ─────────────────── 统一契约（世界模型整合 M1）───────────────────

func _test_city() -> void:
	var c = ScriptCityState.new()
	c.settlement_id = "settlement_city_001"
	c.tile_key = "city_1"
	c.owner_state_id = "state_003"
	c.level = 3
	c.population = 1200
	c.garrison = {"spear_1": 40, "bow_1": 25}
	c.sim_tier = ScriptCityState.SimTier.FOCUS
	var d: Dictionary = ScriptSerializer.city_to_dict(c)
	var c2 = ScriptSerializer.city_from_dict(d)
	_runner.assert_equal(c2.settlement_id, "settlement_city_001", "settlement_id 保真")
	_runner.assert_equal(c2.tile_key, "city_1", "tile_key 保真")
	_runner.assert_equal(c2.owner_state_id, "state_003", "owner_state_id 保真")
	_runner.assert_equal(c2.level, 3, "level 保真")
	_runner.assert_equal(c2.population, 1200, "population 保真")
	_runner.assert_equal(c2.garrison, {"spear_1": 40, "bow_1": 25}, "garrison 保真")
	_runner.assert_equal(c2.buildings, {}, "buildings M1 空容器保真")
	_runner.assert_equal(c2.sim_tier, ScriptCityState.SimTier.FOCUS, "sim_tier 保真")
	# int 字段类型还原（JSON 往返会把 int 变 float，from_dict 须逐字段还原）
	_runner.assert_equal(typeof(c2.level), TYPE_INT, "level int 类型还原")
	_runner.assert_equal(typeof(c2.population), TYPE_INT, "population int 类型还原")
	_runner.assert_equal(typeof(c2.sim_tier), TYPE_INT, "sim_tier int 类型还原")
	_runner.assert_equal(typeof(c2.garrison["spear_1"]), TYPE_INT, "garrison 计数 int 类型还原")


func _test_faction() -> void:
	var f = ScriptFactionState.new()
	f.state_id = "state_003"
	f.name = "东部联盟"
	f.capital_settlement_id = "settlement_city_005"
	f.lut_index = 7
	var d: Dictionary = ScriptSerializer.faction_to_dict(f)
	var f2 = ScriptSerializer.faction_from_dict(d)
	_runner.assert_equal(f2.state_id, "state_003", "state_id 保真")
	_runner.assert_equal(f2.name, "东部联盟", "name 保真")
	_runner.assert_equal(f2.capital_settlement_id, "settlement_city_005", "capital_settlement_id 保真")
	_runner.assert_equal(f2.lut_index, 7, "lut_index 保真")
	_runner.assert_equal(typeof(f2.lut_index), TYPE_INT, "lut_index int 类型还原")


func _test_bad_types() -> void:
	# 坏类型值：float 混入 int 字段 / String 混入 int 字段——不崩、还原或取默认
	var d: Dictionary = {
		"settlement_id": "settlement_city_009",
		"tile_key": "city_9",
		"owner_state_id": "state_001",
		"level": 4.0,                                   # JSON 往返产物：int 变 float
		"population": "800",                            # 坏类型：String 混入 int 字段
		"garrison": {"spear_1": 12.0, "bow_1": "x"},    # float / 坏 String 混入计数
		"sim_tier": 1.0,
	}
	var c2 = ScriptSerializer.city_from_dict(d)
	_runner.assert_equal(c2.level, 4, "float 混入 level 还原 int")
	_runner.assert_equal(typeof(c2.level), TYPE_INT, "level 类型为 int")
	_runner.assert_equal(c2.population, 800, "数字 String 混入 population 可还原")
	_runner.assert_equal(typeof(c2.population), TYPE_INT, "population 类型为 int")
	_runner.assert_equal(c2.garrison, {"spear_1": 12, "bow_1": 0}, "garrison 值逐个还原/坏值取 0")
	_runner.assert_equal(c2.sim_tier, 1, "float 混入 sim_tier 还原")
	# 字段全缺：取默认不崩
	var c3 = ScriptSerializer.city_from_dict({})
	_runner.assert_equal(c3.settlement_id, "", "缺 settlement_id 取默认空串")
	_runner.assert_equal(c3.level, 1, "缺 level 取默认 1")
	_runner.assert_equal(c3.population, 0, "缺 population 取默认 0")
	_runner.assert_equal(c3.garrison, {}, "缺 garrison 取默认空容器")
	_runner.assert_equal(c3.sim_tier, ScriptCityState.SimTier.LEDGER, "缺 sim_tier 取默认账面档")
	# Faction 同口径
	var f2 = ScriptSerializer.faction_from_dict({"state_id": "state_002", "lut_index": -1.0})
	_runner.assert_equal(f2.state_id, "state_002", "faction 缺 name 不崩")
	_runner.assert_equal(f2.lut_index, -1, "float 混入 lut_index 还原 int")
	_runner.assert_equal(f2.capital_settlement_id, "", "缺 capital 取默认空串")


func _test_player_faction_shell() -> void:
	var ws := ScriptWS.new()
	ws.start_new_run()
	_runner.assert_not_null(ws.get_entity("factions", "player"), "新开局 factions 含玩家政权壳")
	_runner.assert_equal(ws.get_entity("factions", "player").state_id, "player", "玩家政权 id = player")
	_runner.assert_equal(ws.get_entity("factions", "player").name, "玩家政权", "玩家政权用通用描述性称谓")
	_runner.assert_equal(ws.get_entity("factions", "player").lut_index, -1, "玩家政权无 LUT 槽")
	_runner.assert_equal(ws.get_entity("factions", "player").capital_settlement_id, "", "M1 壳无都城")
	_runner.assert_equal(ws.get_faction_cities("player").size(), 0, "玩家政权 0 城")
	_runner.assert_equal(ws.faction_population("player"), 0, "玩家政权聚合人口 0")
	_runner.assert_equal(ws.faction_garrison_total("player"), 0, "玩家政权聚合兵力 0")
	_runner.assert_equal(ws.faction_tile_count("player"), 0, "玩家政权名下 tile 0")


func _test_faction_aggregates() -> void:
	var ws := ScriptWS.new()
	var f = ScriptFactionState.new()
	f.state_id = "state_003"
	f.name = "东部联盟"
	ws.register_faction(f)
	# 两城注册顺序故意倒置，验证 get_faction_cities 按 settlement_id 排序
	var c2 = ScriptCityState.new()
	c2.settlement_id = "settlement_city_002"
	c2.tile_key = "city_2"
	c2.owner_state_id = "state_003"
	c2.level = 2
	c2.population = 300
	c2.garrison = {"spear_1": 20}
	ws.register_city(c2)
	var c1 = ScriptCityState.new()
	c1.settlement_id = "settlement_city_001"
	c1.tile_key = "city_1"
	c1.owner_state_id = "state_003"
	c1.level = 3
	c1.population = 1200
	c1.garrison = {"spear_1": 40, "bow_1": 25}
	ws.register_city(c1)
	var owned: Array = ws.get_faction_cities("state_003")
	_runner.assert_equal(owned.size(), 2, "名下城 2 座")
	_runner.assert_equal(owned[0].settlement_id, "settlement_city_001", "聚合按 settlement_id 升序")
	_runner.assert_equal(owned[1].settlement_id, "settlement_city_002", "聚合排序第二位")
	_runner.assert_equal(ws.faction_population("state_003"), 1500, "人口聚合 = 名下城总和")
	_runner.assert_equal(ws.faction_garrison_total("state_003"), 85, "兵力聚合 = garrison 值总和")
	_runner.assert_equal(ws.faction_tile_count("state_003"), 2, "tile 数 = 名下城数（M1 口径）")
	# 他政权/未注册政权不受污染
	_runner.assert_equal(ws.faction_population("state_004"), 0, "他政权聚合为 0")
	_runner.assert_equal(ws.faction_population("state_none"), 0, "未注册政权聚合为 0")


func _test_world_model_json_roundtrip() -> void:
	# 存档管线真实口径：world_state 表 data 为 JSON.stringify 快照，读档
	# JSON.parse_string——int 全变 float，载入侧逐字段还原（本用例验证类型还原）
	var ws := ScriptWS.new()
	var f = ScriptFactionState.new()
	f.state_id = "state_003"
	f.name = "东部联盟"
	f.capital_settlement_id = "settlement_city_001"
	f.lut_index = 7
	ws.register_faction(f)
	var c = ScriptCityState.new()
	c.settlement_id = "settlement_city_001"
	c.tile_key = "city_1"
	c.owner_state_id = "state_003"
	c.level = 3
	c.population = 1200
	c.garrison = {"spear_1": 40, "bow_1": 25}
	c.sim_tier = ScriptCityState.SimTier.FOCUS
	ws.register_city(c)

	var parsed: Variant = JSON.parse_string(JSON.stringify(ws.get_save_data()))
	_runner.assert_true(parsed is Dictionary, "存档 JSON 解析回 Dictionary")
	# JSON 层前提验证：int 确实变成了 float（证明还原逻辑真的被走到）
	_runner.assert_equal(typeof(parsed["cities"]["settlement_city_001"]["level"]), TYPE_FLOAT, "JSON 层 int 确变 float（还原前提成立）")
	var ws2 := ScriptWS.new()
	ws2.load_save_data(parsed)

	var f2 = ws2.get_entity("factions", "state_003")
	_runner.assert_not_null(f2, "faction 恢复存在")
	_runner.assert_equal(f2.state_id, "state_003", "faction state_id 保真")
	_runner.assert_equal(f2.name, "东部联盟", "faction name 保真")
	_runner.assert_equal(f2.capital_settlement_id, "settlement_city_001", "faction capital 保真")
	_runner.assert_equal(f2.lut_index, 7, "faction lut_index 保真")
	_runner.assert_equal(typeof(f2.lut_index), TYPE_INT, "lut_index int 类型还原")
	var c2 = ws2.get_entity("cities", "settlement_city_001")
	_runner.assert_not_null(c2, "city 恢复存在")
	_runner.assert_equal(c2.tile_key, "city_1", "city tile_key 保真")
	_runner.assert_equal(c2.owner_state_id, "state_003", "city owner_state_id 保真")
	_runner.assert_equal(c2.level, 3, "city level 保真")
	_runner.assert_equal(c2.population, 1200, "city population 保真")
	_runner.assert_equal(c2.garrison, {"spear_1": 40, "bow_1": 25}, "city garrison 保真")
	_runner.assert_equal(c2.sim_tier, ScriptCityState.SimTier.FOCUS, "city sim_tier 保真")
	_runner.assert_equal(typeof(c2.level), TYPE_INT, "level int 类型还原")
	_runner.assert_equal(typeof(c2.population), TYPE_INT, "population int 类型还原")
	_runner.assert_equal(typeof(c2.sim_tier), TYPE_INT, "sim_tier int 类型还原")
	_runner.assert_equal(typeof(c2.garrison["spear_1"]), TYPE_INT, "garrison 计数 int 类型还原")


func _test_legacy_save_missing_domains() -> void:
	# 旧档（M1 前存档）无 cities/factions 键：回退空域不崩，其余字段照常恢复
	var ws := ScriptWS.new()
	ws.load_save_data({"game_time": 6.5, "run_seed": 42, "visited_settlements": ["settlement_city_001"]})
	_runner.assert_equal(ws.cities.size(), 0, "旧档缺 cities 键回退空域")
	_runner.assert_equal(ws.factions.size(), 0, "旧档缺 factions 键回退空域")
	_runner.assert_equal(ws.game_time, 6.5, "旧档其余字段照常恢复")
	# 完全空存档同样不崩
	var ws2 := ScriptWS.new()
	ws2.load_save_data({})
	_runner.assert_equal(ws2.cities.size(), 0, "空存档 cities 空域")
	_runner.assert_equal(ws2.factions.size(), 0, "空存档 factions 空域")
