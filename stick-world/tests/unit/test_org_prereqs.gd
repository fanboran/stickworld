extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：职能明面前提（01-组织系统 §2.5 明面/隐形两层中的「明面」层）。
##
## 占位表（config/organizations/function_prereqs.tres）：科研→在编有人会
## placeholder_skill_org_01；参谋→在编有人 cmd≥3。
## 静态注入面与 SkillAPI 台账均进程级——holder id 带本套前缀防跨套污染。
## 隐形前提（建筑/人手/支撑链）以运转状态表现，见 test_training_post 停摆用例。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptOrgPrereqs := preload("res://modules/organization/scripts/prereqs/org_prereqs.gd")
const ScriptOrgSlotSystem := preload("res://modules/organization/scripts/slots/org_slot_system.gd")
const ScriptSkillAPI := preload("res://modules/skill/api.gd")
const ScriptSkillRecord := preload("res://modules/skill/data/skill_record.gd")

func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("前提表: 占位行装载且未定义职能无门槛", _test_table_load)
	_runner.add_test("技能条件: 在编无人会拒/有人会过", _test_skill_condition)
	_runner.add_test("属性条件: 在编无人达标拒/有人达标过", _test_attribute_condition)
	_runner.add_test("接线: OrgSlotSystem.add_slot 过门槛", _test_slot_gate)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


var _runner: TestRunner

## 假注入面（单测不碰 autoload）
var _personnel := {}  # org_id -> Array[holder_id]
var _attrs := {}      # holder_id -> {attr_key: float}


func _inject() -> void:
	ScriptOrgPrereqs.set_providers(
		func(org_id: String) -> Array: return _personnel.get(org_id, []),
		func(holder_id: String, attr_key: String) -> float:
			return float(_attrs.get(holder_id, {}).get(attr_key, -1.0)),
	)


func _test_table_load() -> void:
	_inject()
	_runner.assert_true(ScriptOrgPrereqs.get_prereqs("自由职能").is_empty(),
			"未定义职能返回空条件")
	var r: Dictionary = ScriptOrgPrereqs.check("pr_free_org", "自由职能")
	_runner.assert_true(bool(r.get("ok")), "没标注的职能无明面前提（特例制）")
	_runner.assert_equal((r.get("results") as Array).size(), 0, "无门槛即无逐条结果")
	var research: Array = ScriptOrgPrereqs.get_prereqs("科研")
	_runner.assert_equal(research.size(), 1, "科研占位行 1 条条件")
	_runner.assert_equal(String(research[0].get("kind")), "skill", "科研条件类型=技能")
	var staff: Array = ScriptOrgPrereqs.get_prereqs("参谋")
	_runner.assert_equal(String(staff[0].get("attr")), "cmd", "参谋条件属性=cmd")


func _test_skill_condition() -> void:
	_inject()
	_personnel["pr_org_skill"] = ["pr_h_novice"]
	var r: Dictionary = ScriptOrgPrereqs.check("pr_org_skill", "科研")
	_runner.assert_false(bool(r.get("ok")), "在编无人会 placeholder_skill_org_01 → 拒绝")
	var results: Array = r.get("results")
	_runner.assert_false(bool(results[0].get("passed")), "逐条结果 ✓/✗ 可展示")
	# 有人会（出身自带）→ 通过
	ScriptSkillAPI.learn_skill("placeholder_skill_org_01", "pr_h_novice",
			ScriptSkillRecord.Source.BIRTH)
	r = ScriptOrgPrereqs.check("pr_org_skill", "科研")
	_runner.assert_true(bool(r.get("ok")), "在编有人会 → 通过")


func _test_attribute_condition() -> void:
	_inject()
	_personnel["pr_org_staff"] = ["pr_h_low"]
	_attrs["pr_h_low"] = {"cmd": 2.0}
	var r: Dictionary = ScriptOrgPrereqs.check("pr_org_staff", "参谋")
	_runner.assert_false(bool(r.get("ok")), "在编最高 cmd=2 < 3 → 拒绝")
	_personnel["pr_org_staff"] = ["pr_h_low", "pr_h_able"]
	_attrs["pr_h_able"] = {"cmd": 3.0}
	r = ScriptOrgPrereqs.check("pr_org_staff", "参谋")
	_runner.assert_true(bool(r.get("ok")), "在编有人 cmd≥3 → 通过（有人达标即可）")


func _test_slot_gate() -> void:
	_inject()
	_personnel["pr_org_gate"] = []
	var r: Dictionary = ScriptOrgSlotSystem.add_slot("pr_org_gate", "科研")
	_runner.assert_false(bool(r.get("ok")), "槽位系统加「科研」槽被明面前提拦截")
	_runner.assert_true(String(r.get("error", "")).contains("明面前提"), "拒绝理由可读")
	_personnel["pr_org_gate"] = ["pr_h_gate"]
	ScriptSkillAPI.learn_skill("placeholder_skill_org_01", "pr_h_gate",
			ScriptSkillRecord.Source.BIRTH)
	r = ScriptOrgSlotSystem.add_slot("pr_org_gate", "科研")
	_runner.assert_true(bool(r.get("ok")), "有人会后开槽通过")
	# 未定义职能不经门槛直达槽位板（纯机制层不设卡）
	r = ScriptOrgSlotSystem.add_slot("pr_org_gate", "后勤")
	_runner.assert_true(bool(r.get("ok")), "未定义职能开槽无门槛")
