extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：law 骨架（占位法律表/颁布-废除 CRUD/机制守卫/round-trip）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptLawManager := preload("res://modules/law/manager.gd")

func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("占位表: 装载且 id 为 placeholder 前缀", _test_defs_load)
	_runner.add_test("颁布: 状态迁移与重复拒绝", _test_enact)
	_runner.add_test("废除: 可逆状态/未颁布拒绝", _test_repeal)
	_runner.add_test("机制守卫: 废除代价待设计", _test_guard)
	_runner.add_test("颁布集: round-trip 保真", _test_roundtrip)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


var _runner: TestRunner


func _test_defs_load() -> void:
	var m := ScriptLawManager.new()
	var laws: Array = m.get_laws()
	_runner.assert_true(laws.size() >= 2, "占位行 ≥2（%d 行）" % laws.size())
	for row: Dictionary in laws:
		_runner.assert_true(String(row.get("id", "")).begins_with("placeholder_"),
				"id 占位前缀: %s" % String(row.get("id", "")))
	_runner.assert_true(m.get_law("no_such") == {}, "按 id 查未命中返回空行")


func _test_enact() -> void:
	var m := ScriptLawManager.new()
	_runner.assert_false(bool(m.enact_law("law_nope").get("ok")), "未知法律 id 拒绝")
	_runner.assert_true(bool(m.enact_law("placeholder_law_01").get("ok")), "颁布成功")
	_runner.assert_true(m.is_enacted("placeholder_law_01"), "is_enacted 命中")
	_runner.assert_false(bool(m.enact_law("placeholder_law_01").get("ok")), "重复颁布拒绝")


func _test_repeal() -> void:
	var m := ScriptLawManager.new()
	_runner.assert_false(bool(m.repeal_law("placeholder_law_01").get("ok")), "未颁布废除拒绝")
	m.enact_law("placeholder_law_02")
	_runner.assert_true(bool(m.repeal_law("placeholder_law_02").get("ok")), "废除成功")
	_runner.assert_false(m.is_enacted("placeholder_law_02"), "废除后不在颁布集")
	_runner.assert_true(bool(m.enact_law("placeholder_law_02").get("ok")), "废除后可再颁布（可逆）")


func _test_guard() -> void:
	var m := ScriptLawManager.new()
	var r: Dictionary = m.get_repeal_cost("placeholder_law_01")
	_runner.assert_false(bool(r.get("ok")), "废除代价守卫拒绝")
	_runner.assert_true(String(r.get("error", "")).contains("骨架占位"), "错误文案指明占位性质")


func _test_roundtrip() -> void:
	var m := ScriptLawManager.new()
	m.enact_law("placeholder_law_01")
	m.enact_law("placeholder_law_02")
	m.repeal_law("placeholder_law_02")
	var m2 := ScriptLawManager.new()
	m2.from_dict(m.to_dict())
	_runner.assert_true(m2.is_enacted("placeholder_law_01"), "round-trip 在颁布")
	_runner.assert_false(m2.is_enacted("placeholder_law_02"), "round-trip 已废除")
	_runner.assert_equal(m2.get_enacted_laws().size(), 1, "round-trip 颁布集大小")
