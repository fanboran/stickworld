extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：achievement 骨架（四档稀有度占位表/幂等解锁/快照隔离/round-trip）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptAchievementManager := preload("res://modules/achievement/manager.gd")

func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("占位表: 装载且四档稀有度各有一枚", _test_defs_load)
	_runner.add_test("解锁: 幂等+快照存副本", _test_unlock)
	_runner.add_test("解锁: 未知 id 拒绝", _test_unknown_reject)
	_runner.add_test("记录: round-trip 保真", _test_roundtrip)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


var _runner: TestRunner


func _test_defs_load() -> void:
	var m := ScriptAchievementManager.new()
	var defs: Array = m.get_achievement_defs()
	_runner.assert_true(defs.size() >= 4, "占位行 ≥4（%d 行）" % defs.size())
	var rarities: Dictionary = {}
	for row: Dictionary in defs:
		var rarity := String(row.get("rarity", ""))
		rarities[rarity] = true
	for tier in ScriptAchievementManager.RARITIES:
		_runner.assert_true(rarities.has(tier), "稀有度档 %s 有占位行" % tier)


func _test_unlock() -> void:
	var m := ScriptAchievementManager.new()
	var snapshot: Dictionary = {"population": 10, "cities": 10}
	var r: Dictionary = m.unlock("placeholder_ach_common_01", 10.0, snapshot)
	_runner.assert_true(bool(r.get("ok")), "解锁成功")
	_runner.assert_true(m.is_unlocked("placeholder_ach_common_01"), "is_unlocked 命中")
	# 幂等：重复解锁不新增记录（收藏不膨胀）
	var again: Dictionary = m.unlock("placeholder_ach_common_01", 20.0, snapshot)
	_runner.assert_true(bool(again.get("ok")) and bool(again.get("already")), "重复解锁=无操作")
	_runner.assert_equal(m.get_records().size(), 1, "记录不膨胀")
	# 快照存副本：解锁后改原字典不影响档内记录
	snapshot["population"] = 999
	var record = m.get_records()[0]
	_runner.assert_equal(int(record.empire_snapshot.get("population", 0)), 10, "快照隔离（存副本）")


func _test_unknown_reject() -> void:
	var m := ScriptAchievementManager.new()
	_runner.assert_false(bool(m.unlock("ach_nope", 0.0).get("ok")), "未知成就 id 拒绝")
	_runner.assert_equal(m.get_records().size(), 0, "拒绝不产生记录")


func _test_roundtrip() -> void:
	var m := ScriptAchievementManager.new()
	m.unlock("placeholder_ach_epic_01", 30.0, {"era": "占位纪元"})
	var m2 := ScriptAchievementManager.new()
	m2.from_dict(m.to_dict())
	_runner.assert_true(m2.is_unlocked("placeholder_ach_epic_01"), "round-trip 解锁态")
	_runner.assert_equal(m2.get_records().size(), 1, "round-trip 记录数")
	var record = m2.get_records()[0]
	_runner.assert_equal(record.rarity, "epic", "round-trip 稀有度")
	_runner.assert_equal(record.unlocked_at, 30.0, "round-trip 时刻")
	_runner.assert_equal(String(record.empire_snapshot.get("era", "")), "占位纪元", "round-trip 快照")
