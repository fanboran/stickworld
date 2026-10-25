extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：blueprint 骨架（定名/退役/重启 CRUD/槽位上限/DAG 不变量/机制守卫）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptBlueprintManager := preload("res://modules/blueprint/manager.gd")
const ScriptBlueprintNode := preload("res://modules/blueprint/data/blueprint_node.gd")

func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("定名: 根/派生代数/多母本/校验错误", _test_create)
	_runner.add_test("槽位: 满 10 拒绝-退役腾位-重启用受阻", _test_slot_limit)
	_runner.add_test("退役: 不删除归档/重复退役拒绝", _test_retire)
	_runner.add_test("DAG: 环检测", _test_acyclic)
	_runner.add_test("机制守卫: 派生/融合待调优杆定稿", _test_guards)
	_runner.add_test("记录: round-trip 保真", _test_roundtrip)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


var _runner: TestRunner


func _test_create() -> void:
	var m := ScriptBlueprintManager.new()
	_runner.assert_false(bool(m.create_blueprint("", ScriptBlueprintNode.Kind.FORMATION_TEMPLATE).get("ok")),
			"空定名拒绝")
	_runner.assert_false(bool(m.create_blueprint("X", ScriptBlueprintNode.Kind.FORMATION_TEMPLATE,
			["bp_ghost"]).get("ok")), "母本不存在拒绝")
	var root: Dictionary = m.create_blueprint("占位编制", ScriptBlueprintNode.Kind.FORMATION_TEMPLATE)
	_runner.assert_true(bool(root.get("ok")), "根定名成功")
	var root_id := String(root.get("blueprint_id", ""))
	_runner.assert_equal(m.get_blueprint(root_id).generation, 0, "根代数 0")
	# 多母本 = 融合形状（代数取母本最大 +1）
	var root_b: Dictionary = m.create_blueprint("占位编制B", ScriptBlueprintNode.Kind.FORMATION_TEMPLATE)
	var child: Dictionary = m.create_blueprint("占位衍生", ScriptBlueprintNode.Kind.BUILDING_MODEL,
			[root_id, String(root_b.get("blueprint_id", ""))])
	_runner.assert_true(bool(child.get("ok")), "双母本定名成功")
	_runner.assert_equal(m.get_blueprint(String(child.get("blueprint_id", ""))).generation, 1,
			"子代代数 = 母本最大 +1")


func _test_slot_limit() -> void:
	var m := ScriptBlueprintManager.new()
	for i in range(ScriptBlueprintManager.SLOT_LIMIT_PLACEHOLDER):
		var r: Dictionary = m.create_blueprint("占位蓝图%02d" % i, ScriptBlueprintNode.Kind.DEPARTMENT_CHARTER)
		_runner.assert_true(bool(r.get("ok")), "第 %d 枚定名成功" % i)
	_runner.assert_false(bool(m.create_blueprint("超限", ScriptBlueprintNode.Kind.FORMATION_TEMPLATE).get("ok")),
			"槽位满拒绝")
	var retired: Dictionary = m.retire_blueprint("bp_001")
	_runner.assert_true(bool(retired.get("ok")), "退役一枚")
	var extra: Dictionary = m.create_blueprint("腾位后", ScriptBlueprintNode.Kind.FORMATION_TEMPLATE)
	_runner.assert_true(bool(extra.get("ok")), "退役腾位后可再定名")
	_runner.assert_false(bool(m.reactivate_blueprint("bp_001").get("ok")),
			"槽位再满时重启用受阻")


func _test_retire() -> void:
	var m := ScriptBlueprintManager.new()
	var r: Dictionary = m.create_blueprint("占位章程", ScriptBlueprintNode.Kind.DEPARTMENT_CHARTER)
	var bid := String(r.get("blueprint_id", ""))
	_runner.assert_true(bool(m.retire_blueprint(bid).get("ok")), "退役成功")
	_runner.assert_false(bool(m.retire_blueprint(bid).get("ok")), "重复退役拒绝")
	_runner.assert_not_null(m.get_blueprint(bid), "退役不删除（荣誉档案）")
	_runner.assert_equal(m.get_blueprints(false).size(), 0, "在役清单不含退役")
	_runner.assert_equal(m.get_blueprints(true).size(), 1, "全量清单含退役")
	_runner.assert_true(bool(m.reactivate_blueprint(bid).get("ok")), "重新启用成功")


func _test_acyclic() -> void:
	var m := ScriptBlueprintManager.new()
	var a: Dictionary = m.create_blueprint("A", ScriptBlueprintNode.Kind.FORMATION_TEMPLATE)
	m.create_blueprint("B", ScriptBlueprintNode.Kind.FORMATION_TEMPLATE,
			[String(a.get("blueprint_id", ""))])
	_runner.assert_true(m.is_acyclic(), "正常谱系无环")
	# 表结构外写入成环（读档数据防御）：from_dict 原样载入 → 环检测必须报环
	var m2 := ScriptBlueprintManager.new()
	m2.from_dict({"nodes": [
		{"id": "bp_x", "display_name": "X", "kind": 0, "parents": ["bp_y"], "generation": 1, "proficiency": 0, "state": 0},
		{"id": "bp_y", "display_name": "Y", "kind": 0, "parents": ["bp_x"], "generation": 1, "proficiency": 0, "state": 0},
	], "next_seq": 3})
	_runner.assert_false(m2.is_acyclic(), "互为母本的环被检出")


func _test_guards() -> void:
	var m := ScriptBlueprintManager.new()
	var r: Dictionary = m.create_blueprint("占位母本", ScriptBlueprintNode.Kind.FORMATION_TEMPLATE)
	var bid := String(r.get("blueprint_id", ""))
	for guard: Dictionary in [m.derive_blueprint(bid, "衍生"), m.fuse_blueprint(bid, bid, "融合")]:
		_runner.assert_false(bool(guard.get("ok")), "机制守卫拒绝")
		_runner.assert_true(String(guard.get("error", "")).contains("骨架占位"), "错误文案指明占位性质")


func _test_roundtrip() -> void:
	var m := ScriptBlueprintManager.new()
	var root: Dictionary = m.create_blueprint("占位母本", ScriptBlueprintNode.Kind.BUILDING_MODEL)
	var root_id := String(root.get("blueprint_id", ""))
	m.create_blueprint("占位子代", ScriptBlueprintNode.Kind.BUILDING_MODEL, [root_id])
	m.retire_blueprint(root_id)  # 母本退役：子代保留，源流线指向档案（11 边缘情况）
	var m2 := ScriptBlueprintManager.new()
	m2.from_dict(m.to_dict())
	_runner.assert_equal(m2.get_blueprints(true).size(), 2, "round-trip 节点数（含退役）")
	_runner.assert_equal(m2.get_blueprint(root_id).state, ScriptBlueprintNode.State.RETIRED,
			"round-trip 退役态")
	var child = m2.get_blueprints(false)[0]
	_runner.assert_equal(child.parents, [root_id], "round-trip 母本边（源流指向档案）")
