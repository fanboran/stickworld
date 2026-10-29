extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：训练推进器（04 §三 训练=组织对组织；17 §二 内部进度制）。
##
## 钉死六条语义：
## ① 层级对齐——受训组织 tier ≤ 训练组织 tier + 1（班训排）；
## ② 教学来源——技能目标须槽上教官有人会（无人会无从施训，自明之理不立法）；
## ③ 内部进度制——满 100 落地（属性 +1 钳 0~10 / 技能习得记教学教官）；
## ④ 速率修正方向——属性当前值越高越难涨；
## ⑤ 隐形前提——职能运转（教官在槽 × 建筑在场）不满足=停摆不报错、进度保留；
## ⑥ 先满者留批 + 任一方组织解散 → 安排取消。
## TrainingPost 直改实例化（不进树、不触存档回调）；槽位走 OrgSlotSystem 进程板
## （org id 带本套前缀防跨套污染）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptTrainingPost := preload("res://modules/organization/scripts/slots/training_post.gd")
const ScriptOrgSlotSystem := preload("res://modules/organization/scripts/slots/org_slot_system.gd")
const ScriptSkillAPI := preload("res://modules/skill/api.gd")
const ScriptSkillRecord := preload("res://modules/skill/data/skill_record.gd")

func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("层级对齐: 训练组织+1以内可训/超出拒绝", _test_tier_alignment)
	_runner.add_test("教学来源: 无人会拒绝/会者记为教学教官", _test_teacher_source)
	_runner.add_test("进度制: 满100涨属性(钳0-10)且安排留续", _test_attribute_progress)
	_runner.add_test("速率方向: 属性值越高越难涨", _test_diminishing_rate)
	_runner.add_test("隐形前提: 缺建筑停摆不报错/进度保留续涨", _test_building_stall)
	_runner.add_test("技能获得: 满100习得记教官/先满者留批", _test_skill_gain)
	_runner.add_test("解散: 任一方组织消失安排取消", _test_org_disband_cancel)
	_runner.add_test("训练安排: round-trip 保真", _test_roundtrip)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


var _runner: TestRunner
var _post: ScriptTrainingPost
var _orgs := {}       # org_id -> {ok, tier, personnel}
var _attrs := {}      # holder_id -> {attr: float}
var _building_ok := true
var _cancelled: Array = []


## 造一台接好假 provider 的推进器 + 训练组织职能槽（教官 tp_a）
func _make_post(trainer_tier: int = 2) -> void:
	_orgs = {}
	_attrs = {}
	_building_ok = true
	_cancelled = []
	_post = ScriptTrainingPost.new()
	_post.setup(
		func(org_id: String) -> Dictionary:
			return _orgs.get(org_id, {"ok": false}),
		func(_function_name: String) -> bool:
			return _building_ok,
		func(holder_id: String, attr_key: String) -> float:
			return float(_attrs.get(holder_id, {}).get(attr_key, 0.0)),
		func(holder_id: String, attr_key: String, delta: int) -> float:
			var table: Dictionary = _attrs.get(holder_id, {})
			if not _attrs.has(holder_id):
				_attrs[holder_id] = table
			var v := clampf(float(table.get(attr_key, 0.0)) + float(delta), 0.0, 10.0)
			table[attr_key] = v
			return v,
	)
	_post.arrangement_cancelled.connect(func(_id: String, reason: String):
		_cancelled.append(reason))
	# 训练组织（tier 可调）+ 训练职能槽 + 教官
	_orgs["tp_trainer"] = {"ok": true, "tier": trainer_tier, "personnel": ["tp_teacher"]}
	ScriptOrgSlotSystem.add_slot("tp_trainer", "训练")
	ScriptOrgSlotSystem.assign_person("tp_trainer", "训练", "tp_teacher")
	_attrs["tp_teacher"] = {"cmd": 5.0}


func _add_army(org_id: String, tier: int, holders: Array) -> void:
	_orgs[org_id] = {"ok": true, "tier": tier, "personnel": holders}
	for holder in holders:
		if not _attrs.has(holder):
			_attrs[holder] = {"str": 2.0}


func _progress_of(org_id: String, holder: String) -> float:
	for arr in _post.get_arrangements():
		if String(arr.get("trainee_org")) == org_id:
			return float((arr.get("progress") as Dictionary).get(holder, 0.0))
	return -1.0


func _test_tier_alignment() -> void:
	_make_post(2)
	_add_army("tp_army_far", 4, ["tp_s_far"])
	var r: Dictionary = _post.add_arrangement("tp_trainer", "训练", "tp_army_far", "attribute", "str")
	_runner.assert_false(bool(r.get("ok")), "受训 L4 > 训练 L2+1 → 拒绝（班训排、排训连）")
	_add_army("tp_army_near", 3, ["tp_s_near"])
	r = _post.add_arrangement("tp_trainer", "训练", "tp_army_near", "attribute", "str")
	_runner.assert_true(bool(r.get("ok")), "受训 L3 = 训练 L2+1 → 可训（高一级整建制）")


func _test_teacher_source() -> void:
	_make_post()
	_add_army("tp_army_a", 3, ["tp_s_a"])
	var r: Dictionary = _post.add_arrangement("tp_trainer", "训练", "tp_army_a",
			"skill", "placeholder_skill_use_01")
	_runner.assert_false(bool(r.get("ok")), "槽上教官无人会 → 无从施训")
	ScriptSkillAPI.learn_skill("placeholder_skill_use_01", "tp_teacher",
			ScriptSkillRecord.Source.BIRTH)
	r = _post.add_arrangement("tp_trainer", "训练", "tp_army_a",
			"skill", "placeholder_skill_use_01")
	_runner.assert_true(bool(r.get("ok")), "教官会后建立安排")
	_runner.assert_equal(String(r.get("arrangement", {}).get("teacher_holder_id")),
			"tp_teacher", "教学教官=会该技能的槽上人员")


func _test_attribute_progress() -> void:
	_make_post()
	_add_army("tp_army_b", 2, ["tp_s_b"])
	_attrs["tp_s_b"] = {"str": 2.0}
	_runner.assert_true(bool(_post.add_arrangement("tp_trainer", "训练", "tp_army_b",
			"attribute", "str").get("ok")), "安排建立")
	var done: Array = _post.advance(2.0)
	_runner.assert_equal(done.size(), 0, "2 游戏小时未满 100 不落地")
	var mid := _progress_of("tp_army_b", "tp_s_b")
	_runner.assert_true(mid > 0.0 and mid < 100.0, "进度在累积（%.1f/100）" % mid)
	# str=2 速率 8.4/时：3h 已积 25.2，再推 12h（+100.8）恰跨一档落地为 3
	done = _post.advance(12.0)
	_runner.assert_true(done.size() >= 1, "推进足够时长后落地涨点")
	_runner.assert_equal(_attrs["tp_s_b"]["str"], 3.0, "str 2 → 3（满 100 涨 1 点）")
	_runner.assert_equal(_post.get_arrangements().size(), 1, "安排留续（未散批）")
	# 域顶钳制：拉满后不再涨、该员退出推进（留批）
	_attrs["tp_s_b"] = {"str": 10.0}
	_post.advance(200.0)
	_runner.assert_equal(_attrs["tp_s_b"]["str"], 10.0, "域顶 10 不再涨")
	_runner.assert_equal(_post.get_arrangements().size(), 1, "到顶者留批、安排仍在")


func _test_diminishing_rate() -> void:
	_make_post()
	_add_army("tp_army_c", 2, ["tp_s_low", "tp_s_high"])
	_attrs["tp_s_low"] = {"str": 1.0}
	_attrs["tp_s_high"] = {"str": 9.0}
	_runner.assert_true(bool(_post.add_arrangement("tp_trainer", "训练", "tp_army_c",
			"attribute", "str").get("ok")), "安排建立")
	_post.advance(1.0)
	var low := _progress_of("tp_army_c", "tp_s_low")
	var high := _progress_of("tp_army_c", "tp_s_high")
	_runner.assert_true(low > high and high > 0.0,
			"同槽同拍：str1 进度 %.1f > str9 进度 %.1f（越高越难涨）" % [low, high])


func _test_building_stall() -> void:
	_make_post()
	_add_army("tp_army_d", 2, ["tp_s_d"])
	_post.add_arrangement("tp_trainer", "训练", "tp_army_d", "attribute", "str")
	_post.advance(3.0)
	var kept := _progress_of("tp_army_d", "tp_s_d")
	_runner.assert_true(kept > 0.0, "建筑在场时进度累积")
	_building_ok = false  # 隐形前提：对应建筑不在场 → 空转
	_post.advance(50.0)
	_runner.assert_equal(_progress_of("tp_army_d", "tp_s_d"), kept,
			"缺建筑停摆：进度不涨不报错（空转不拒绝）")
	_building_ok = true
	_post.advance(3.0)
	_runner.assert_true(_progress_of("tp_army_d", "tp_s_d") > kept, "建筑回来从原进度续涨（不丢）")


func _test_skill_gain() -> void:
	_make_post()
	ScriptSkillAPI.learn_skill("placeholder_skill_use_01", "tp_teacher",
			ScriptSkillRecord.Source.BIRTH)
	_add_army("tp_army_e", 2, ["tp_s_e"])
	_runner.assert_false(ScriptSkillAPI.knows("tp_s_e", "placeholder_skill_use_01"),
			"受训者先不会")
	_post.add_arrangement("tp_trainer", "训练", "tp_army_e", "skill", "placeholder_skill_use_01")
	var done: Array = _post.advance(200.0)
	_runner.assert_true(done.size() >= 1, "满 100 落地")
	_runner.assert_true(ScriptSkillAPI.knows("tp_s_e", "placeholder_skill_use_01"),
			"受训者习得（TRAINING 来源）")
	var teacher := ""
	for record in ScriptSkillAPI.get_records():
		if record is ScriptSkillRecord and record.holder_id == "tp_s_e" \
				and record.skill_id == "placeholder_skill_use_01":
			teacher = record.teacher_holder_id
	_runner.assert_equal(teacher, "tp_teacher", "习得记录的教学教官=施训教官")
	_post.advance(200.0)  # 先满者留批：已会不再推进，安排不散
	_runner.assert_equal(_post.get_arrangements().size(), 1, "先满者留批、安排仍在")


func _test_org_disband_cancel() -> void:
	_make_post()
	_add_army("tp_army_f", 2, ["tp_s_f"])
	_post.add_arrangement("tp_trainer", "训练", "tp_army_f", "attribute", "str")
	_orgs.erase("tp_army_f")  # 受训组织解散
	_post.advance(1.0)
	_runner.assert_equal(_post.get_arrangements().size(), 0, "受训方消失 → 安排取消")
	_runner.assert_true(_cancelled.has("受训组织已不存在"), "取消原因可读")
	_add_army("tp_army_g", 2, ["tp_s_g"])
	_post.add_arrangement("tp_trainer", "训练", "tp_army_g", "attribute", "str")
	_orgs.erase("tp_trainer")  # 训练组织解散
	_post.advance(1.0)
	_runner.assert_equal(_post.get_arrangements().size(), 0, "训练方消失 → 安排取消")


func _test_roundtrip() -> void:
	_make_post()
	ScriptSkillAPI.learn_skill("placeholder_skill_use_01", "tp_teacher",
			ScriptSkillRecord.Source.BIRTH)
	_add_army("tp_army_h", 2, ["tp_s_h1", "tp_s_h2"])
	_post.add_arrangement("tp_trainer", "训练", "tp_army_h", "attribute", "str")
	_post.add_arrangement("tp_trainer", "训练", "tp_army_h", "skill", "placeholder_skill_use_01")
	_post.advance(3.0)
	var kept1 := _progress_of("tp_army_h", "tp_s_h1")
	_runner.assert_true(kept1 > 0.0, "roundtrip 前有进度")
	var p2 = ScriptTrainingPost.new()
	p2.setup(_post._org_info, _post._building, _post._attr_read, _post._attr_write)
	p2.from_dict(_post.to_dict())
	var arrangements: Array = p2.get_arrangements()
	_runner.assert_equal(arrangements.size(), 2, "round-trip 安排数")
	_post = p2  # 换台后从原进度续推：25.2 + 8.4×9 = 100.8 恰跨一档
	_post.advance(9.0)
	_runner.assert_equal(_attrs["tp_s_h1"]["str"], 3.0, "round-trip 后续推照常落地")
