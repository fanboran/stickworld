extends Node
## 单元测试：编队征用互斥（小镇生活批次 4）——在岗村民被征入伍自动离岗。
##
## 覆盖面（FormationSystem._requisition_unit 最小接线，duck 协议零 town_life 依赖）：
##   - create_squad：在岗村民编队 → 职业清空（回待业池）
##   - add_unit：追加在岗村民入队 → 职业清空
##   - 已待业/无职业协议单位编队 → 安全跳过不炸
##   - disband_squad：离岗不回岗（P0 决策：进待业池，不自动复职）
##
## batch 准入：FormationSystem 真类 + FakeOrgApi 桩（组织模块语义不在本套件
## 验收面）；实体桩 CharacterBody2D + 职业协议，进局部树供槽位计算取位置。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptFormationSystem := preload("res://modules/combat/scripts/command/formation_system.gd")

## batch_runner 收割退出码用（TestRunner.finish_process 依赖本信号）
signal test_done(code: int)

var _runner: TestRunner
## 当前用例的夹具容器（换用例即 free）
var _case_root: Node = null


# ─────────────────────────────── 测试桩 ────────────────────────────────

## 组织 API 桩：create_organization 恒成功（编队创建的组织面不在本套件验收范围）
class FakeOrgApi extends Node:
	func create_organization(_name: String, _tag: String, _tier: int, _parent: String) -> Dictionary:
		return {"ok": true, "data": {"org_id": "org_test_%d" % (randi() % 100000)}}

	func assign_stickman(_squad_id: String, _iid: String, _role: String) -> void:
		pass

	func remove_stickman(_squad_id: String, _iid: String) -> void:
		pass

	func disband_organization(_squad_id: String) -> void:
		pass


## 村民实体桩：职业协议（set_profession/get_profession），进树供槽位计算取位置
class VillagerStub extends CharacterBody2D:
	var _profession_id: String = ""

	func set_profession(id: String) -> void:
		_profession_id = id

	func get_profession() -> String:
		return _profession_id


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("征用: create_squad 在岗村民入伍即离岗", _test_create_squad_requisition)
	_runner.add_test("征用: add_unit 追加在岗村民即离岗", _test_add_unit_requisition)
	_runner.add_test("征用: 待业/无协议单位编队安全跳过", _test_non_profession_safe)
	_runner.add_test("征用: 解散不回岗（P0 进待业池）", _test_disband_no_rehire)
	_runner.run()
	print(_runner.summary())
	_cleanup()
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _cleanup() -> void:
	if _case_root != null and is_instance_valid(_case_root):
		remove_child(_case_root)
		_case_root.free()
	_case_root = null


func _new_case() -> void:
	_cleanup()
	_case_root = Node.new()
	_case_root.name = "CaseRoot"
	add_child(_case_root)


func _spawn(n: Node) -> Node:
	_case_root.add_child(n)
	return n


## 编队系统夹具：真 FormationSystem + 组织桩（不进树，_process 不跑——
## 本套件同步断言，无帧依赖；槽位计算取实体 global_position，实体进树即可）
func _make_formation() -> Node:
	var fs: Node = ScriptFormationSystem.new()
	fs.setup(FakeOrgApi.new())
	_spawn(fs)
	return fs


func _make_villager(job: String, pos: Vector2) -> VillagerStub:
	var e := VillagerStub.new()
	e._profession_id = job
	e.position = pos
	return e


# ─────────────────────────────── 用例 ────────────────────────────────

func _test_create_squad_requisition() -> void:
	_new_case()
	var fs: Node = _make_formation()
	var smith := _spawn(_make_villager("blacksmith", Vector2(0, 0)))
	var lumber := _spawn(_make_villager("lumberjack", Vector2(50, 0)))
	var squad_id: String = fs.create_squad([smith, lumber], "征用测试班")
	_runner.assert_false(String(squad_id).is_empty(), "编队创建成功")
	_runner.assert_true(String(smith.get_profession()).is_empty(), "在岗铁匠入伍后职业清空")
	_runner.assert_true(String(lumber.get_profession()).is_empty(), "在岗伐木工入伍后职业清空")
	_runner.assert_true(fs.is_in_squad(smith), "铁匠在编队中")


func _test_add_unit_requisition() -> void:
	_new_case()
	var fs: Node = _make_formation()
	var idle := _spawn(_make_villager("", Vector2(0, 0)))
	var squad_id: String = fs.create_squad([idle], "追加测试班")
	_runner.assert_false(String(squad_id).is_empty(), "编队创建成功")
	var miner := _spawn(_make_villager("miner", Vector2(80, 0)))
	_runner.assert_true(fs.add_unit(squad_id, miner), "追加矿工入队成功")
	_runner.assert_true(String(miner.get_profession()).is_empty(), "在岗矿工追加入队后职业清空")
	_runner.assert_true(String(idle.get_profession()).is_empty(), "待业单位编队保持待业")


func _test_non_profession_safe() -> void:
	_new_case()
	var fs: Node = _make_formation()
	var idle := _spawn(_make_villager("", Vector2(0, 0)))
	# 无职业协议的裸实体（战斗单位常态）混编不炸
	var bare := Node2D.new()
	_spawn(bare)
	var squad_id: String = fs.create_squad([idle, bare], "混编测试班")
	_runner.assert_false(String(squad_id).is_empty(), "混编创建成功（无协议单位安全跳过）")
	_runner.assert_true(String(idle.get_profession()).is_empty(), "待业单位保持待业")
	# 小队信息正确（2 名成员）
	_runner.assert_equal(fs.get_squad_size(squad_id), 2, "混编小队 2 名成员")


func _test_disband_no_rehire() -> void:
	_new_case()
	var fs: Node = _make_formation()
	var smith := _spawn(_make_villager("blacksmith", Vector2(0, 0)))
	var squad_id: String = fs.create_squad([smith], "解散测试班")
	_runner.assert_true(String(smith.get_profession()).is_empty(), "入伍离岗")
	fs.disband_squad(squad_id)
	_runner.assert_true(String(smith.get_profession()).is_empty(),
			"解散不回岗（P0：进待业池，不自动复职）")
	_runner.assert_false(fs.is_in_squad(smith), "解散后脱离编队（村民标志实体重新可闲逛）")
