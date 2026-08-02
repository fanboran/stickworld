extends Node
## 单元测试：FormationSystem 编队增删/任命（fake OrganizationApi 白盒）。
## FormationSystem 不进场景树（_process 不触发），确定性。

const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptFormationSystem := preload("res://modules/combat/scripts/command/formation_system.gd")

var _runner: TestRunner


## 假组织 API：记录调用，模拟成功返回（Node 类型以匹配 setup 强类型参数）
class FakeOrgApi:
	extends Node
	var created: Array = []
	var assigned: Array = []
	var commanders: Array = []
	var removed: Array = []
	var disbanded: Array = []
	var _next_id: int = 1

	func create_organization(name: String, _tag: String, _tier: int, _parent_id: String) -> Dictionary:
		var org_id := "org_%d" % _next_id
		_next_id += 1
		created.append({"id": org_id, "name": name})
		return {"ok": true, "data": {"org_id": org_id}}

	func assign_stickman(org_id: String, stickman_id: String, role: String) -> void:
		assigned.append({"org": org_id, "unit": stickman_id, "role": role})

	func assign_commander(org_id: String, stickman_id: String) -> void:
		commanders.append({"org": org_id, "unit": stickman_id})

	func remove_stickman(org_id: String, stickman_id: String) -> void:
		removed.append({"org": org_id, "unit": stickman_id})

	func disband_organization(org_id: String) -> void:
		disbanded.append(org_id)


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("FormationSystem: 未注入 org api 时创建失败", _test_no_org_api)
	_runner.add_test("FormationSystem: create_squad 成功并同步组织", _test_create)
	_runner.add_test("FormationSystem: 死亡单位被过滤", _test_dead_filter)
	_runner.add_test("FormationSystem: 已在其他小队的单位自动移出", _test_move_squad)
	_runner.add_test("FormationSystem: assign_leader 成员可任命/非成员拒绝", _test_leader)
	_runner.add_test("FormationSystem: add_unit/remove_unit 维护双向映射", _test_add_remove)
	_runner.add_test("FormationSystem: disband 清空并同步组织", _test_disband)
	_runner.run()
	print(_runner.summary())
	get_tree().quit(0 if _runner.all_passed() else 1)


func _make_fs() -> Array:
	var org := FakeOrgApi.new()
	var fs := ScriptFormationSystem.new()
	fs.setup(org)
	return [fs, org]


func _unit() -> Node:
	return Node.new()


func _test_no_org_api() -> void:
	var fs := ScriptFormationSystem.new()
	var squad_id: String = fs.create_squad([_unit()])
	_runner.assert_equal(squad_id, "", "未注入 api 应创建失败")
	_runner.assert_equal(fs.get_squad_count(), 0, "无小队")


func _test_create() -> void:
	var pair := _make_fs()
	var fs: Node = pair[0]
	var org: FakeOrgApi = pair[1]
	var u1 := _unit()
	var u2 := _unit()
	var squad_id: String = fs.create_squad([u1, u2])
	_runner.assert_not_equal(squad_id, "", "创建应成功")
	_runner.assert_equal(org.created.size(), 1, "组织应创建一次")
	_runner.assert_equal(fs.get_squad_units(squad_id).size(), 2, "小队应有 2 人")
	_runner.assert_equal(fs.get_squad_size(squad_id), 2, "squad_size 应为 2")
	_runner.assert_equal(org.assigned.size(), 2, "两单位应分配入组织")
	_runner.assert_equal(fs.get_unit_squad(u1), squad_id, "单位反查应指向小队")


func _test_dead_filter() -> void:
	var pair := _make_fs()
	var fs: Node = pair[0]
	var org: FakeOrgApi = pair[1]
	var dead := Node.new()
	dead.set_script(_make_dead_unit_script())
	dead.set("dead", true)
	var squad_id: String = fs.create_squad([dead])
	_runner.assert_equal(squad_id, "", "全为死亡单位应创建失败")
	_runner.assert_equal(org.created.size(), 0, "不应创建组织")


## 动态构造带 is_dead 的假脚本（避免 inner class 与 Node 冲突）
func _make_dead_unit_script() -> GDScript:
	var s := GDScript.new()
	s.source_code = "extends Node\nvar dead := false\nfunc is_dead() -> bool:\n\treturn dead\n"
	s.reload()
	return s


func _test_move_squad() -> void:
	var pair := _make_fs()
	var fs: Node = pair[0]
	var u := _unit()
	var s1: String = fs.create_squad([u])
	var s2: String = fs.create_squad([u])
	_runner.assert_not_equal(s2, "", "第二小队创建成功")
	_runner.assert_equal(fs.get_squad_size(s1), 0, "第一小队应无成员")
	_runner.assert_equal(fs.get_squad_size(s2), 1, "第二小队应有 1 人")
	_runner.assert_equal(fs.get_unit_squad(u), s2, "单位归属应迁移到第二小队")


func _test_leader() -> void:
	var pair := _make_fs()
	var fs: Node = pair[0]
	var org: FakeOrgApi = pair[1]
	var leader := _unit()
	var outsider := _unit()
	var squad_id: String = fs.create_squad([leader])
	_runner.assert_true(fs.assign_leader(squad_id, leader), "成员可任命")
	_runner.assert_equal(fs.get_squad_leader(squad_id), leader, "leader 引用正确")
	_runner.assert_equal(org.commanders.size(), 1, "组织应收到任命调用")
	_runner.assert_false(fs.assign_leader(squad_id, outsider), "非成员应拒绝任命")


func _test_add_remove() -> void:
	var pair := _make_fs()
	var fs: Node = pair[0]
	var u1 := _unit()
	var u2 := _unit()
	var squad_id: String = fs.create_squad([u1])
	_runner.assert_true(fs.add_unit(squad_id, u2), "add_unit 成功")
	_runner.assert_equal(fs.get_squad_size(squad_id), 2, "加入后 2 人")
	_runner.assert_equal(fs.get_unit_squad(u2), squad_id, "新单位映射正确")
	fs.remove_unit(u2)
	_runner.assert_equal(fs.get_squad_size(squad_id), 1, "移除后 1 人")
	_runner.assert_equal(fs.get_unit_squad(u2), "", "移除后反查为空")


func _test_disband() -> void:
	var pair := _make_fs()
	var fs: Node = pair[0]
	var org: FakeOrgApi = pair[1]
	var u := _unit()
	var squad_id: String = fs.create_squad([u])
	fs.disband_squad(squad_id)
	_runner.assert_equal(fs.get_squad_count(), 0, "解散后无小队")
	_runner.assert_equal(fs.get_unit_squad(u), "", "解散后单位反查为空")
	_runner.assert_equal(org.disbanded.size(), 1, "组织应同步解散")
