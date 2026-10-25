extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：technology 骨架（三分类占位表装载/征服获得授予/round-trip）。
##
## Manager 直改实例化；解锁池用注入字典（生产入口在 api 层取 WorldState.unlocks，
## 单测不碰 autoload——unit 层准入）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptTechnologyManager := preload("res://modules/technology/manager.gd")
const ScriptTechGrant := preload("res://modules/technology/data/tech_grant.gd")

func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("占位表: 三表合并注册且盖来源分类", _test_tables_load)
	_runner.add_test("授予: 写解锁池+记获得来源", _test_grant)
	_runner.add_test("授予: 重复/未知 id 拒绝", _test_grant_rejects)
	_runner.add_test("记录: round-trip 保真", _test_roundtrip)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


var _runner: TestRunner


func _test_tables_load() -> void:
	var m := ScriptTechnologyManager.new()
	var techs: Array = m.get_techs()
	_runner.assert_true(techs.size() >= 6, "三表合并行数 ≥6（%d 行）" % techs.size())
	var categories: Dictionary = {}
	for row: Dictionary in techs:
		_runner.assert_true(String(row.get("id", "")).begins_with("placeholder_"),
				"id 占位前缀: %s" % String(row.get("id", "")))
		categories[String(row.get("category", ""))] = true
	_runner.assert_true(categories.has("manufacturing"), "制造分类已盖戳")
	_runner.assert_true(categories.has("spell"), "法术分类已盖戳")
	_runner.assert_true(categories.has("admin"), "管理分类已盖戳")
	_runner.assert_true(m.get_tech("no_such") == {}, "未知 id 返回空行")


func _test_grant() -> void:
	var m := ScriptTechnologyManager.new()
	var unlocks: Dictionary = {}
	var tech_id := _first_tech_id(m)
	var r: Dictionary = m.grant_tech(tech_id, ScriptTechGrant.Source.CONQUEST,
			"stickman_001", unlocks, 10.0)
	_runner.assert_true(bool(r.get("ok")), "授予成功")
	_runner.assert_true(unlocks.has(tech_id), "解锁池写入（获得即拥有）")
	_runner.assert_true(m.has_tech(tech_id, unlocks), "has_tech 命中")
	_runner.assert_false(m.has_tech("placeholder_none", unlocks), "has_tech 未命中")
	_runner.assert_equal(m.get_grants().size(), 1, "获得记录 1 条")
	var grant: ScriptTechGrant = m.get_grants()[0]
	_runner.assert_equal(grant.source, ScriptTechGrant.Source.CONQUEST, "来源=征服保真")
	_runner.assert_equal(grant.carrier_stickman_id, "stickman_001", "知识携带者保真")


func _test_grant_rejects() -> void:
	var m := ScriptTechnologyManager.new()
	var unlocks: Dictionary = {}
	var tech_id := _first_tech_id(m)
	_runner.assert_false(bool(m.grant_tech("tech_nope", ScriptTechGrant.Source.EVENT,
			"", unlocks, 0.0).get("ok")), "未知科技 id 拒绝")
	var r: Dictionary = m.grant_tech(tech_id, ScriptTechGrant.Source.TALENT, "", unlocks, 0.0)
	_runner.assert_true(bool(r.get("ok")), "首次授予成功")
	_runner.assert_false(bool(m.grant_tech(tech_id, ScriptTechGrant.Source.TALENT,
			"", unlocks, 0.0).get("ok")), "重复授予拒绝（已拥有）")
	_runner.assert_equal(m.get_grants().size(), 1, "重复授予不新增记录")


func _test_roundtrip() -> void:
	var m := ScriptTechnologyManager.new()
	var unlocks: Dictionary = {}
	var tech_id := _first_tech_id(m)
	m.grant_tech(tech_id, ScriptTechGrant.Source.CONQUEST, "stickman_009", unlocks, 20.0)
	var m2 := ScriptTechnologyManager.new()
	m2.from_dict(m.to_dict())
	_runner.assert_equal(m2.get_grants().size(), 1, "round-trip 记录数")
	var g2: ScriptTechGrant = m2.get_grants()[0]
	_runner.assert_equal(g2.tech_id, tech_id, "round-trip tech_id")
	_runner.assert_equal(g2.carrier_stickman_id, "stickman_009", "round-trip 携带者")
	_runner.assert_equal(g2.granted_at, 20.0, "round-trip 时刻")


func _first_tech_id(m) -> String:
	var techs: Array = m.get_techs()
	if techs.is_empty():
		return ""
	return String(techs[0].get("id", ""))
