extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：读档完整性批次——存档链路新增代码的纯逻辑层。
##
## 覆盖三件（真实 SaveManager 全链路见 tests/integration/test_save_completeness.gd）：
##   1. 阵营回填前置：entities.extra_data 字段解析的旧档安全回退（缺字段/坏 JSON → null）
##   2. 编队存档键换算：iid → entity_id 重映射 + 失效成员剔空（save_handler._remap_formation_keys）
##   3. 编队/编制重建：squad_snapshot.export_for_save / restore_from_save
##      （真 FormationSystem 宿主 + 桩组织 api——班/排/班长/跟队链/人员账重建、
##      组织缺失跳过、计数器推进）
##
## 纯逻辑层：不进场景树（FormationSystem 实例 new 不挂树，_process 不跑）、
## 不碰 SaveManager/WorldState（EventBus 仅 FormationSystem 信号转发触达，autoload 已在）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptSaveHandler := preload("res://modules/world/scripts/setup/save_handler.gd")
const ScriptFormationSystem := preload("res://modules/formation/scripts/formation_system.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("extra_data: 缺字段/空串/坏 JSON/非字典 → null（旧档安全回退）", _test_parse_extra_field_guards)
	_runner.add_test("extra_data: 正常字典取值 + 缺键 null", _test_parse_extra_field_hit)
	_runner.add_test("remap: iid→ent 换算 + 失效成员剔除/剔空丢弃/班长缺失落空", _test_remap_keys)
	_runner.add_test("remap: 排随存活班过滤 + 全剔空排丢弃", _test_remap_platoons)
	_runner.add_test("snapshot: 导出班+排全字段（含跟队链/排长）", _test_export_for_save)
	_runner.add_test("snapshot: 重建班/排原位还原（组织 id 不变 + 人员账重写 + 跟队链）", _test_restore_from_save)
	_runner.add_test("snapshot: 组织缺失/无成员班跳过不硬造", _test_restore_skip_guards)
	_runner.add_test("snapshot: 计数器推进（读档后新建排/班默认名不撞车）", _test_counter_advance)
	await _runner.run_async()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────────── 桩件 ───────────────────────────

## 桩组织 api（duck 契约：create/get/disband/assign/set_personnel/assign_commander）。
## extends Node：FormationSystem.setup 形参强类型 Node，RefCounted 桩会被类型系统拒绝。
class FakeOrgApi:
	extends Node
	var orgs: Dictionary = {}
	var personnel_log: Dictionary = {}   # org_id -> 最近一次 set_personnel 入参
	var commanders: Dictionary = {}      # org_id -> 最近一次 assign_commander 的 sid
	var next_id: int = 1

	func create_organization(_name: String, _tag: String, _tier: int, _parent: String) -> Dictionary:
		var id := "org_%d" % next_id
		next_id += 1
		orgs[id] = true
		return {"ok": true, "data": {"org_id": id}}

	func get_organization(org_id: String) -> Dictionary:
		return {"ok": orgs.has(org_id)}

	func disband_organization(org_id: String) -> Dictionary:
		orgs.erase(org_id)
		return {"ok": true}

	func assign_stickman(_org_id: String, _sid: String, _role: String) -> Dictionary:
		return {"ok": true}

	func remove_stickman(_org_id: String, _sid: String) -> Dictionary:
		return {"ok": true}

	func set_personnel(org_id: String, ids: Array) -> Dictionary:
		personnel_log[org_id] = ids
		return {"ok": true}

	func assign_commander(org_id: String, sid: String) -> Dictionary:
		commanders[org_id] = sid
		return {"ok": true}


## 桩单位（Node2D + 无脚本；formation 内部读 global_position 等空间属性，
## 裸 Node 会报脚本错；各内部函数对无脚本桩有 has_method/in 守卫）
func _make_stub(name_str: String) -> Node2D:
	var u := Node2D.new()
	u.name = name_str
	return u


## 建一套已编班的 FormationSystem：班1（u0 班长 + u1）+ 班2（u2）跟队班1 + 排1（含两班、u2 任排长）
func _build_world(fs: Node, org_api: FakeOrgApi) -> Dictionary:
	var u0 := _make_stub("u0")
	var u1 := _make_stub("u1")
	var u2 := _make_stub("u2")
	add_child(u0)
	add_child(u1)
	add_child(u2)
	var s1: String = fs.create_squad([u0, u1], "squad_alpha")
	var s2: String = fs.create_squad([u2], "squad_bravo")
	if s1.is_empty() or s2.is_empty():
		return {}
	fs.assign_leader(s1, u0)
	fs.set_squad_follow_squad(s2, s1, 150.0)
	var pid: String = fs.create_platoon([s1, s2], "platoon_x")
	fs.assign_platoon_leader(pid, u2)
	return {"u0": u0, "u1": u1, "u2": u2, "s1": s1, "s2": s2, "pid": pid}


# ─────────────────────────── 用例 ───────────────────────────

## save_handler._parse_extra_field：旧档安全回退守卫（阵营/编队回填的共同前置）
func _test_parse_extra_field_guards() -> void:
	var sh: Node = ScriptSaveHandler.new()  # 不挂树：仅调纯方法，不触 _root
	_runner.assert_null(sh._parse_extra_field({"extra_data": ""}, "faction_id"), "空串 → null")
	_runner.assert_null(sh._parse_extra_field({"extra_data": "{bad json"}, "faction_id"), "坏 JSON → null")
	_runner.assert_null(sh._parse_extra_field({"extra_data": "[1,2]"}, "faction_id"), "非字典 JSON → null")
	_runner.assert_null(sh._parse_extra_field({}, "faction_id"), "列缺失 → null")
	_runner.assert_null(sh._parse_extra_field({"extra_data": "{\"hp\":10}"}, "faction_id"), "字典无该键 → null")
	sh.free()


func _test_parse_extra_field_hit() -> void:
	var sh: Node = ScriptSaveHandler.new()
	# JSON 数字解码恒为 float：先断非 null（防 null 被 int() 吞成 0 假绿），再 int 化比较
	var fid: Variant = sh._parse_extra_field({"extra_data": "{\"faction_id\":2}"}, "faction_id")
	_runner.assert_not_null(fid, "正常字典取到值")
	_runner.assert_equal(int(fid), 2, "正常字典取值（JSON float 2.0 → int 2，读侧 int(fid) 同式）")
	var fz: Variant = sh._parse_extra_field({"extra_data": "{\"faction_id\":0}"}, "faction_id")
	_runner.assert_not_null(fz, "零值字段存在（非 null，读侧照常回填）")
	_runner.assert_equal(int(fz), 0, "零值字段取到 0")
	sh.free()


## _remap_formation_keys：iid→entity_id 换算与剔除规则
func _test_remap_keys() -> void:
	var sh: Node = ScriptSaveHandler.new()
	var raw: Dictionary = {
		"squads": [
			{"org_id": "org_1", "name": "a", "preset_id": "fp", "work_types": ["WORK_COMBAT"],
				"leader_iid": 111, "members": [111, 222, 999],  # 999 = 不在映射（已释放）
				"follow_player": true, "follow_front": "", "follow_gap": 0.0},
			{"org_id": "org_2", "name": "b", "preset_id": "fp", "work_types": [],
				"leader_iid": 0, "members": [888]},  # 888 不在映射 → 剔空整班丢弃
		],
		"platoons": [],
	}
	var row: Dictionary = sh._remap_formation_keys(raw, {111: "ent_0000", 222: "ent_0001"})
	var squads: Array = row["squads"]
	_runner.assert_equal(squads.size(), 1, "成员剔空的班整体丢弃")
	_runner.assert_equal(squads[0]["members"], ["ent_0000", "ent_0001"], "存活成员换算为 ent 键")
	_runner.assert_equal(squads[0]["leader_ent"], "ent_0000", "班长换算为 ent 键")
	_runner.assert_true(squads[0]["follow_player"], "跟随标志透传")
	# 班长 iid 不在映射 → leader_ent 空串（读侧按无班长恢复）
	raw["squads"] = [{"org_id": "org_1", "name": "a", "preset_id": "fp", "work_types": [],
		"leader_iid": 555, "members": [111], "follow_player": false, "follow_front": "", "follow_gap": 0.0}]
	row = sh._remap_formation_keys(raw, {111: "ent_0000"})
	_runner.assert_equal(row["squads"][0]["leader_ent"], "", "班长不在映射 → 空串")
	sh.free()


func _test_remap_platoons() -> void:
	var sh: Node = ScriptSaveHandler.new()
	var raw: Dictionary = {
		"squads": [
			{"org_id": "org_1", "name": "a", "preset_id": "fp", "work_types": [],
				"leader_iid": 0, "members": [111], "follow_player": false, "follow_front": "", "follow_gap": 0.0},
			{"org_id": "org_9", "name": "dead", "preset_id": "fp", "work_types": [],
				"leader_iid": 0, "members": [999], "follow_player": false, "follow_front": "", "follow_gap": 0.0},
		],
		"platoons": [
			{"platoon_id": "platoon_1", "name": "p1", "squads": ["org_1", "org_9", "org_ghost"],
				"leader_iid": 111, "company_id": ""},
			{"platoon_id": "platoon_2", "name": "p2", "squads": ["org_ghost"],
				"leader_iid": 0, "company_id": ""},
		],
	}
	var row: Dictionary = sh._remap_formation_keys(raw, {111: "ent_0000", 999: "ent_0009"})
	# org_9 成员 999 在映射内（ent_0009）→ 班存活；org_ghost 不是班 → 剔除
	var platoons: Array = row["platoons"]
	_runner.assert_equal(platoons.size(), 1, "全剔空排丢弃")
	_runner.assert_equal(platoons[0]["squads"], ["org_1", "org_9"], "排 squads 过滤到存活班")
	_runner.assert_equal(platoons[0]["leader_ent"], "ent_0000", "排长换算为 ent 键")
	sh.free()


## export_for_save：班 + 排全字段导出（跨图快照不带排，存档导出必须带）
func _test_export_for_save() -> void:
	var org_api := FakeOrgApi.new()
	var fs: Node = ScriptFormationSystem.new()
	fs.setup(org_api)
	var w: Dictionary = _build_world(fs, org_api)
	_runner.assert_false(w.is_empty(), "fixture 编班成功")
	var data: Dictionary = fs.export_for_save()
	var squads: Array = data["squads"]
	_runner.assert_equal(squads.size(), 2, "两班导出")
	var by_org: Dictionary = {}
	for s_v in squads:
		by_org[String(s_v["org_id"])] = s_v
	var s1: Dictionary = by_org[w["s1"]]
	_runner.assert_equal(s1["members"].size(), 2, "班1 两成员")
	_runner.assert_equal(int(s1["leader_iid"]), w["u0"].get_instance_id(), "班长 iid 导出")
	_runner.assert_equal(String(s1["name"]), "squad_alpha", "班名导出")
	var s2: Dictionary = by_org[w["s2"]]
	_runner.assert_equal(String(s2["follow_front"]), w["s1"], "跟队前队导出")
	_runner.assert_approx(float(s2["follow_gap"]), 150.0, 0.01, "跟队间距导出")
	var platoons: Array = data["platoons"]
	_runner.assert_equal(platoons.size(), 1, "排导出（存档带排，区别于跨图快照）")
	_runner.assert_equal(platoons[0]["squads"], [w["s1"], w["s2"]], "排所属班导出")
	_runner.assert_equal(int(platoons[0]["leader_iid"]), w["u2"].get_instance_id(), "排长 iid 导出")
	fs.free()
	org_api.free()


## restore_from_save：换算落档 → 模拟重启动（新宿主 + 桩组织收编档内组织）→ 重建
func _test_restore_from_save() -> void:
	var org_api := FakeOrgApi.new()
	var fs: Node = ScriptFormationSystem.new()
	fs.setup(org_api)
	var w: Dictionary = _build_world(fs, org_api)
	_runner.assert_false(w.is_empty(), "fixture 编班成功")
	# 存档换算（save_handler 同逻辑）：iid → ent 键
	var sh: Node = ScriptSaveHandler.new()
	var exported: Dictionary = fs.export_for_save()
	var iid_map: Dictionary = {
		int(w["u0"].get_instance_id()): "ent_0000",
		int(w["u1"].get_instance_id()): "ent_0001",
		int(w["u2"].get_instance_id()): "ent_0002",
	}
	var row: Dictionary = sh._remap_formation_keys(exported, iid_map)
	var s1 := String(w["s1"])
	var s2 := String(w["s2"])
	# 模拟重启动：旧宿主销毁、组织侧收编了档内组织（id 不变）
	var org_api2 := FakeOrgApi.new()
	org_api2.orgs = {s1: true, s2: true}
	var fs2: Node = ScriptFormationSystem.new()
	fs2.setup(org_api2)
	# 新实体（新 iid = 跨会话语义）
	var n0 := _make_stub("n0")
	var n1 := _make_stub("n1")
	var n2 := _make_stub("n2")
	add_child(n0)
	add_child(n1)
	add_child(n2)
	var ent_map: Dictionary = {"ent_0000": n0, "ent_0001": n1, "ent_0002": n2}
	var restored: int = fs2.restore_from_save(row, ent_map)
	_runner.assert_equal(restored, 2, "两班恢复")
	# 组织 id 原位还原（班 id = 组织 id，跨存档稳定）
	_runner.assert_true(fs2.get_all_squads().has(s1), "班1 组织 id 不变")
	_runner.assert_true(fs2.get_all_squads().has(s2), "班2 组织 id 不变")
	# 成员/班长换绑到新实体
	_runner.assert_equal(fs2.get_squad_units(s1), [n0, n1], "班1 成员换绑新实体")
	_runner.assert_equal(fs2.get_unit_squad(n2), s2, "班2 成员反查")
	_runner.assert_equal(fs2.get_squad_leader(s1), n0, "班长恢复")
	_runner.assert_equal(int(org_api2.commanders.get(s1, 0)), n0.get_instance_id(),
		"组织指挥官按新实体重写")
	# 人员账重写：旧 iid 不残留，全为新实体 iid
	var personnel: Array = org_api2.personnel_log.get(s1, [])
	_runner.assert_equal(personnel.size(), 2, "人员账按活实体重写")
	_runner.assert_true(str(n0.get_instance_id()) in personnel, "人员账含新 iid")
	# 跟队链/排
	_runner.assert_equal(String(fs2.get_squad_follow(s2).get("front", "")), s1, "跟队链恢复")
	_runner.assert_equal(fs2.get_platoon_of_squad(s1), "platoon_1", "排 id 原位还原")
	_runner.assert_equal(fs2.get_platoon_leader("platoon_1"), n2, "排长恢复")
	_runner.assert_equal(fs2.get_squad_name(s1), "squad_alpha", "班名还原")
	fs2.free()
	org_api.free()
	org_api2.free()


func _test_restore_skip_guards() -> void:
	var org_api2 := FakeOrgApi.new()
	org_api2.orgs = {"org_1": true}  # 组织侧只有 org_1
	var fs2: Node = ScriptFormationSystem.new()
	fs2.setup(org_api2)
	var n0 := _make_stub("n0")
	add_child(n0)
	var row: Dictionary = {
		"squads": [
			{"org_id": "org_404", "name": "ghost", "preset_id": "fp", "work_types": [],
				"leader_ent": "", "members": ["ent_0000"], "follow_player": false,
				"follow_front": "", "follow_gap": 0.0},  # 组织缺失 → 跳过
			{"org_id": "org_1", "name": "empty", "preset_id": "fp", "work_types": [],
				"leader_ent": "", "members": ["ent_dead"], "follow_player": false,
				"follow_front": "", "follow_gap": 0.0},  # 成员全失效 → 跳过
		],
		"platoons": [],
	}
	var restored: int = fs2.restore_from_save(row, {"ent_0000": n0})
	_runner.assert_equal(restored, 0, "两条皆跳过，恢复数为 0")
	_runner.assert_equal(fs2.get_squad_count(), 0, "不硬造班（组织链断 ≠ 新建组织）")
	# 空行/缺键 → 零恢复不崩
	_runner.assert_equal(fs2.restore_from_save({}, {}), 0, "空行零恢复")
	fs2.free()
	org_api2.free()


func _test_counter_advance() -> void:
	var org_api2 := FakeOrgApi.new()
	org_api2.orgs = {"org_1": true}
	var fs2: Node = ScriptFormationSystem.new()
	fs2.setup(org_api2)
	var n0 := _make_stub("n0")
	add_child(n0)
	var row: Dictionary = {
		"squads": [
			{"org_id": "org_1", "name": "squad_7", "preset_id": "fp", "work_types": [],
				"leader_ent": "", "members": ["ent_0000"], "follow_player": false,
				"follow_front": "", "follow_gap": 0.0},
		],
		"platoons": [
			{"platoon_id": "platoon_4", "name": "p", "squads": ["org_1"],
				"leader_ent": "ent_0000", "company_id": ""},
		],
	}
	_runner.assert_equal(fs2.restore_from_save(row, {"ent_0000": n0}), 1, "重建一班")
	_runner.assert_equal(int(fs2.get("_platoon_counter")), 4, "排号计数器推进到档内最大后缀")
	_runner.assert_equal(int(fs2.get("_squad_counter")), 7, "班号计数器推进到档内默认名后缀")
	# 计数器推进后新建不撞车：组织侧计数器已收编续算（真链路由
	# restore_from_world_container 保证），此处桩按 org_1 之后续发
	org_api2.next_id = 2
	var other := _make_stub("other")
	add_child(other)
	var fs_new_squad: String = fs2.create_squad([other], "")
	_runner.assert_false(fs_new_squad.is_empty(), "读档后可新建班")
	_runner.assert_false(String(fs2.create_platoon([fs_new_squad], "")).is_empty(), "读档后可新建排")
	fs2.free()
	org_api2.free()
