extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：skill 技能台账骨架（三类定义表/习得记录/派生查询/round-trip）。
##
## Manager 直改实例化（不碰 autoload、不进场景树、确定性——unit 层准入）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptSkillManager := preload("res://modules/skill/manager.gd")
const ScriptSkillRecord := preload("res://modules/skill/data/skill_record.gd")

func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("定义表: 装载三类且 id 为 placeholder 前缀", _test_defs_load)
	_runner.add_test("习得: 台账写入+谁教的记录", _test_learn)
	_runner.add_test("习得: 重复/未知/空持有者拒绝", _test_learn_rejects)
	_runner.add_test("派生: knows/holders_of/faction_knows/skills_of", _test_derived)
	_runner.add_test("台账: round-trip 保真", _test_roundtrip)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


var _runner: TestRunner


func _test_defs_load() -> void:
	var m := ScriptSkillManager.new()
	var defs: Array = m.get_skills()
	_runner.assert_true(defs.size() >= 5, "三类合计行数 ≥5（%d 行）" % defs.size())
	for row: Dictionary in defs:
		_runner.assert_true(String(row.get("id", "")).begins_with("placeholder_"),
				"id 占位前缀: %s" % String(row.get("id", "")))
	for category in ["制造", "使用", "组织"]:
		_runner.assert_true(not m.get_skills_of_category(category).is_empty(),
				"%s 类有占位行" % category)
	_runner.assert_true(m.get_skill("no_such") == {}, "未知 id 返回空行")


func _test_learn() -> void:
	var m := ScriptSkillManager.new()
	var skill_id := _first_skill_id(m)
	var r: Dictionary = m.learn_skill(skill_id, "占位角色01", ScriptSkillRecord.Source.TRAINING,
			"占位教官", 10.0)
	_runner.assert_true(bool(r.get("ok")), "习得成功")
	_runner.assert_true(m.knows("占位角色01", skill_id), "knows 命中")
	_runner.assert_equal(m.get_records().size(), 1, "台账 1 条")
	var record: ScriptSkillRecord = m.get_records()[0]
	_runner.assert_equal(record.source, ScriptSkillRecord.Source.TRAINING, "来源=训练保真")
	_runner.assert_equal(record.teacher_holder_id, "占位教官", "谁教的记录保真（技能源流原料）")


func _test_learn_rejects() -> void:
	var m := ScriptSkillManager.new()
	var skill_id := _first_skill_id(m)
	_runner.assert_false(bool(m.learn_skill("skill_nope", "a", ScriptSkillRecord.Source.BIRTH).get("ok")),
			"未知技能 id 拒绝")
	_runner.assert_false(bool(m.learn_skill(skill_id, "", ScriptSkillRecord.Source.BIRTH).get("ok")),
			"空持有者拒绝")
	var r: Dictionary = m.learn_skill(skill_id, "a", ScriptSkillRecord.Source.CONQUEST)
	_runner.assert_true(bool(r.get("ok")), "首次习得成功")
	_runner.assert_false(bool(m.learn_skill(skill_id, "a", ScriptSkillRecord.Source.EVENT).get("ok")),
			"重复习得拒绝（会/不会二元，无层次）")
	_runner.assert_equal(m.get_records().size(), 1, "重复习得不新增记录")
	# 另一人习得同技能：合法（多持有者）
	_runner.assert_true(bool(m.learn_skill(skill_id, "b", ScriptSkillRecord.Source.BIRTH).get("ok")),
			"第二人习得同技能成功")


func _test_derived() -> void:
	var m := ScriptSkillManager.new()
	var skill_a := _first_skill_id(m)
	var skill_b := _nth_skill_id(m, 1)
	m.learn_skill(skill_a, "p1", ScriptSkillRecord.Source.BIRTH)
	m.learn_skill(skill_a, "p2", ScriptSkillRecord.Source.TALENT)
	m.learn_skill(skill_b, "p1", ScriptSkillRecord.Source.RESEARCH)
	_runner.assert_equal(m.holders_of(skill_a), ["p1", "p2"], "holders_of 谁会")
	_runner.assert_equal(m.skills_of("p1").size(), 2, "skills_of 某人会什么")
	_runner.assert_true(m.faction_knows(skill_a), "存在持有者=阵营会")
	_runner.assert_false(m.faction_knows("skill_nope"), "无持有者=阵营不会")


func _test_roundtrip() -> void:
	var m := ScriptSkillManager.new()
	var skill_id := _first_skill_id(m)
	m.learn_skill(skill_id, "占位角色09", ScriptSkillRecord.Source.TRAINING, "占位教官乙", 20.0)
	var m2 := ScriptSkillManager.new()
	m2.from_dict(m.to_dict())
	_runner.assert_true(m2.knows("占位角色09", skill_id), "round-trip 习得态")
	_runner.assert_equal(m2.get_records().size(), 1, "round-trip 记录数")
	var g2: ScriptSkillRecord = m2.get_records()[0]
	_runner.assert_equal(g2.teacher_holder_id, "占位教官乙", "round-trip 谁教的")
	_runner.assert_equal(g2.learned_at, 20.0, "round-trip 时刻")


func _first_skill_id(m) -> String:
	return _nth_skill_id(m, 0)


func _nth_skill_id(m, n: int) -> String:
	var defs: Array = m.get_skills()
	if defs.size() <= n:
		return ""
	return String(defs[n].get("id", ""))
