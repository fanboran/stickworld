extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：logistics 骨架（载体/道路占位表/计划挂组织 CRUD/round-trip/机制守卫）。
##
## Manager 直改实例化（不碰 autoload、不进场景树、确定性——unit 层准入）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptLogisticsManager := preload("res://modules/logistics/manager.gd")
const ScriptTransportPlan := preload("res://modules/logistics/data/transport_plan.gd")

func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("占位表: 载体（并一）与道路装载且 id 占位前缀", _test_tables_load)
	_runner.add_test("计划: 挂组织增删与校验错误", _test_plan_crud)
	_runner.add_test("计划: round-trip 保真（含组织归属）", _test_plan_roundtrip)
	_runner.add_test("机制守卫: 承运人派工待设计", _test_assign_guard)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


var _runner: TestRunner


func _test_tables_load() -> void:
	var m := ScriptLogisticsManager.new()
	for rows: Array in [m.get_carriers(), m.get_roads()]:
		_runner.assert_true(rows.size() >= 2, "占位行 ≥2（%d 行）" % rows.size())
		for row: Dictionary in rows:
			_runner.assert_true(String(row.get("id", "")).begins_with("placeholder_"),
					"id 占位前缀: %s" % String(row.get("id", "")))
	_runner.assert_equal(m.get_carrier("no_such"), {}, "按 id 查未命中返回空行")


func _test_plan_crud() -> void:
	var m := ScriptLogisticsManager.new()
	var r: Dictionary = m.add_transport_plan("占位运输队01", "占位矿山", "占位仓库", "mat_stone",
			ScriptTransportPlan.CargoKind.ITEM, 10, 10, ScriptTransportPlan.Priority.HIGH)
	_runner.assert_true(bool(r.get("ok")), "计划创建成功（挂组织）")
	_runner.assert_true(String(r.get("plan_id", "")).begins_with("tp_"), "计划 id 前缀")
	_runner.assert_equal(m.get_transport_plans().size(), 1, "计划表 1 条")
	_runner.assert_equal(m.get_transport_plans()[0].owner_org_id, "占位运输队01", "计划归属组织保真")
	_runner.assert_false(bool(m.add_transport_plan("", "a", "b", "x",
			ScriptTransportPlan.CargoKind.ITEM, 10, 10, ScriptTransportPlan.Priority.MEDIUM).get("ok")),
			"无组织归属拒绝（计划必须挂在组织节点上）")
	_runner.assert_false(bool(m.add_transport_plan("org", "", "b", "x",
			ScriptTransportPlan.CargoKind.ITEM, 10, 10, ScriptTransportPlan.Priority.MEDIUM).get("ok")),
			"空起点拒绝")
	_runner.assert_false(bool(m.add_transport_plan("org", "a", "a", "x",
			ScriptTransportPlan.CargoKind.ITEM, 10, 10, ScriptTransportPlan.Priority.MEDIUM).get("ok")),
			"同起终点拒绝")
	_runner.assert_false(bool(m.add_transport_plan("org", "a", "b", "",
			ScriptTransportPlan.CargoKind.ITEM, 10, 10, ScriptTransportPlan.Priority.MEDIUM).get("ok")),
			"空货物拒绝")
	var pid := String(r.get("plan_id", ""))
	_runner.assert_true(bool(m.remove_transport_plan(pid).get("ok")), "删除成功")
	_runner.assert_false(bool(m.remove_transport_plan(pid).get("ok")), "重复删除拒绝")
	_runner.assert_equal(m.get_transport_plans().size(), 0, "删后计划表空")


func _test_plan_roundtrip() -> void:
	var m := ScriptLogisticsManager.new()
	m.add_transport_plan("占位运输队02", "占位矿山", "王都占位仓库", "res_iron",
			ScriptTransportPlan.CargoKind.RESOURCE, 10, 10, ScriptTransportPlan.Priority.LOW)
	var m2 := ScriptLogisticsManager.new()
	m2.from_dict(m.to_dict())
	_runner.assert_equal(m2.get_transport_plans().size(), 1, "round-trip 计划数")
	var p2: ScriptTransportPlan = m2.get_transport_plans()[0]
	_runner.assert_equal(p2.owner_org_id, "占位运输队02", "round-trip 组织归属")
	_runner.assert_equal(p2.cargo_kind, ScriptTransportPlan.CargoKind.RESOURCE, "cargo_kind 保真")
	_runner.assert_equal(p2.priority, ScriptTransportPlan.Priority.LOW, "priority 保真")
	_runner.assert_equal(p2.cargo_id, "res_iron", "货物 id 保真")


func _test_assign_guard() -> void:
	var m := ScriptLogisticsManager.new()
	var r: Dictionary = m.assign_carrier("tp_001", 12345)
	_runner.assert_false(bool(r.get("ok")), "派工守卫拒绝")
	_runner.assert_true(String(r.get("error", "")).contains("骨架占位"), "错误文案指明占位性质")
