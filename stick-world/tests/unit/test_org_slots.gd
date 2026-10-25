extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：组织槽位板（01-组织系统 §2.4 纯机制：槽位增删/人员激活/机构嵌套/环校验）。
##
## Board 直改实例化（不碰 autoload、不进场景树、确定性——unit 层准入）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptOrgSlotBoard := preload("res://modules/organization/scripts/slots/org_slot_board.gd")

func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("槽位: 增删与重复拒绝", _test_slot_crud)
	_runner.add_test("人员激活: 空槽不运转/多人合法/重复拒绝", _test_person_activation)
	_runner.add_test("机构激活: 组织嵌套运转职能", _test_institution_activation)
	_runner.add_test("嵌套环: 机构互塞拒绝", _test_institution_cycle)
	_runner.add_test("查询: active_functions 与槽位全貌", _test_queries)
	_runner.add_test("槽位板: round-trip 保真", _test_roundtrip)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


var _runner: TestRunner


func _test_slot_crud() -> void:
	var b := ScriptOrgSlotBoard.new()
	_runner.assert_false(bool(b.add_slot("", "指挥").get("ok")), "空组织 id 拒绝")
	_runner.assert_false(bool(b.add_slot("org_a", "").get("ok")), "空职能名拒绝")
	_runner.assert_true(bool(b.add_slot("org_a", "指挥").get("ok")), "开槽成功")
	_runner.assert_false(bool(b.add_slot("org_a", "指挥").get("ok")), "重复开槽拒绝")
	_runner.assert_equal(b.get_slots("org_a").size(), 1, "槽位表 1 条")
	_runner.assert_true(bool(b.add_slot("org_a", "后勤").get("ok")), "第二职能开槽成功")
	_runner.assert_true(bool(b.remove_slot("org_a", "后勤").get("ok")), "拆槽成功")
	_runner.assert_false(bool(b.remove_slot("org_a", "后勤").get("ok")), "重复拆槽拒绝")


func _test_person_activation() -> void:
	var b := ScriptOrgSlotBoard.new()
	b.add_slot("org_a", "传令")
	_runner.assert_false(b.is_slot_active("org_a", "传令"), "空槽 = 职能不运转")
	_runner.assert_false(bool(b.assign_person("org_a", "参谋", "p1").get("ok")), "不存在的槽拒绝")
	_runner.assert_true(bool(b.assign_person("org_a", "传令", "p1").get("ok")), "派人入槽成功")
	_runner.assert_true(b.is_slot_active("org_a", "传令"), "一人即激活")
	_runner.assert_true(bool(b.assign_person("org_a", "传令", "p2").get("ok")), "多人同槽合法")
	_runner.assert_false(bool(b.assign_person("org_a", "传令", "p1").get("ok")), "重复派同一人拒绝")
	_runner.assert_true(bool(b.unassign_person("org_a", "传令", "p1").get("ok")), "撤人成功")
	_runner.assert_true(b.is_slot_active("org_a", "传令"), "仍有 p2 在槽，职能继续运转")
	_runner.assert_true(bool(b.unassign_person("org_a", "传令", "p2").get("ok")), "撤走最后一人")
	_runner.assert_false(b.is_slot_active("org_a", "传令"), "槽空回到不运转")


func _test_institution_activation() -> void:
	var b := ScriptOrgSlotBoard.new()
	b.add_slot("org_group", "物流")
	b.add_slot("org_transport_office", "调度")
	_runner.assert_false(bool(b.assign_institution("org_group", "物流", "org_group").get("ok")),
			"机构不能塞自己的槽位")
	_runner.assert_true(bool(b.assign_institution("org_group", "物流", "org_transport_office").get("ok")),
			"机构入槽成功（运输处以组织形态运转物流职能）")
	_runner.assert_true(b.is_slot_active("org_group", "物流"), "机构激活 = 槽位运转")
	_runner.assert_false(bool(b.assign_institution("org_group", "物流", "org_other").get("ok")),
			"一槽至多一机构")
	_runner.assert_true(bool(b.unassign_institution("org_group", "物流").get("ok")), "撤机构成功")
	_runner.assert_false(b.is_slot_active("org_group", "物流"), "撤后空槽不运转")


func _test_institution_cycle() -> void:
	var b := ScriptOrgSlotBoard.new()
	b.add_slot("org_a", "职能X")
	b.add_slot("org_b", "职能Y")
	b.add_slot("org_c", "职能Z")
	# a←b（a 的职能X由 b 承担）→ b←c → 再 c←a 成环拒绝
	_runner.assert_true(bool(b.assign_institution("org_a", "职能X", "org_b").get("ok")), "a 的职能由 b 承担")
	_runner.assert_true(bool(b.assign_institution("org_b", "职能Y", "org_c").get("ok")), "b 的职能由 c 承担")
	_runner.assert_false(bool(b.assign_institution("org_c", "职能Z", "org_a").get("ok")),
			"机构嵌套成环拒绝（c 的职能再由 a 承担 = 环）")


func _test_queries() -> void:
	var b := ScriptOrgSlotBoard.new()
	b.add_slot("org_a", "指挥")
	b.add_slot("org_a", "后勤")
	b.add_slot("org_a", "征兵")
	b.assign_person("org_a", "指挥", "p1")
	_runner.assert_equal(b.active_functions("org_a"), ["指挥"], "仅运转中的职能入列")
	var slots: Array = b.get_slots("org_a")
	_runner.assert_equal(slots.size(), 3, "槽位全貌含未激活槽")
	for slot: Dictionary in slots:
		if String(slot["function"]) == "指挥":
			_runner.assert_true(bool(slot["active"]), "指挥槽运转标记")
			_runner.assert_equal(slot["persons"], ["p1"], "槽内人员可见（结构与人即评估依据）")


func _test_roundtrip() -> void:
	var b := ScriptOrgSlotBoard.new()
	b.add_slot("org_a", "指挥")
	b.add_slot("org_b", "物流")
	b.assign_person("org_a", "指挥", "p1")
	b.assign_person("org_a", "指挥", "p2")
	b.assign_institution("org_b", "物流", "org_a")
	var b2 := ScriptOrgSlotBoard.new()
	b2.from_dict(b.to_dict())
	_runner.assert_true(b2.is_slot_active("org_a", "指挥"), "round-trip 人员激活态")
	_runner.assert_true(b2.is_slot_active("org_b", "物流"), "round-trip 机构激活态")
	_runner.assert_equal(b2.active_functions("org_a"), ["指挥"], "round-trip 职能清单")
	# 恢复后的板仍守环约束
	_runner.assert_false(bool(b2.assign_institution("org_a", "指挥", "org_b").get("ok")),
			"round-trip 后嵌套环仍被拒绝")
