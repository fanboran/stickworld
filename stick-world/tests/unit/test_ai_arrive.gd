extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：AI 完善批次 4——列阵到位动画 + 队友死亡补位。
## 4.1 behavior_move 编队成员到达播 arrive + 滞留；非成员直接 finish
## 4.2 队友死亡（从 squad 移除）后 get_squad_dest 点位变化 = 自动补位

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptBehaviorMove := preload("res://modules/units/scripts/ai/behavior_move.gd")
const ScriptFormationSystem := preload("res://modules/combat/scripts/command/formation_system.gd")

var _runner: TestRunner


class FakeOrgApi:
	extends Node
	var _next_id: int = 1

	func create_organization(_org_name: String, _tag: String, _tier: int, _parent_id: String) -> Dictionary:
		var org_id := "org_%d" % _next_id
		_next_id += 1
		return {"ok": true, "data": {"org_id": org_id}}

	func assign_stickman(_org_id: String, _stickman_id: String, _role: String) -> void:
		pass

	func assign_commander(_org_id: String, _stickman_id: String) -> void:
		pass

	func remove_stickman(_org_id: String, _stickman_id: String) -> void:
		pass

	func disband_organization(_org_id: String) -> void:
		pass


class FakeUnit:
	extends CharacterBody2D
	var formation: Node = null
	var arrive_calls: int = 0
	var stop_calls: int = 0

	func get_formation_system() -> Node:
		return formation

	func get_weapon() -> Node:
		return null

	func is_dead() -> bool:
		return false

	func play_arrive() -> void:
		arrive_calls += 1

	func ai_stop() -> void:
		stop_calls += 1

	func ai_move(_dir: Vector2, _run: bool) -> void:
		pass

	func set_role(_r: String) -> void:
		pass


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("列阵: 编队成员到达播 arrive + 滞留", _test_arrive_member)
	_runner.add_test("列阵: 非编队成员到达直接 finish", _test_arrive_nonmember)
	_runner.add_test("补位: 队友死亡后点位变化", _test_reposition)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _make_move_behavior(member: bool) -> Array:
	var beh: Node = ScriptBehaviorMove.new()
	var unit := FakeUnit.new()
	unit.position = Vector2(0, 0)
	if member:
		var fs: Node = ScriptFormationSystem.new()
		fs.setup(FakeOrgApi.new())
		var other := FakeUnit.new()
		fs.create_squad([unit, other], "列阵队", "fp_combat_squad")
		unit.formation = fs
	# 目标设在单位附近（确保 dist <= ARRIVAL_THRESHOLD 触发到达）
	beh.entity = unit
	beh.enter("", {"target": Vector2(10, 0)})
	return [beh, unit]


func _test_arrive_member() -> void:
	var r: Array = _make_move_behavior(true)
	var beh: Node = r[0]
	var unit: FakeUnit = r[1]
	beh.update(0.1)  # 到达 → 播 arrive + 滞留
	_runner.assert_true(unit.arrive_calls > 0, "编队成员到达应播 arrive")
	_runner.assert_false(beh.is_finished(), "播 arrive 期间不应立即 finish")
	beh.update(0.5)  # 滞留结束 → finish
	_runner.assert_true(beh.is_finished(), "滞留结束后应 finish")


func _test_arrive_nonmember() -> void:
	var r: Array = _make_move_behavior(false)
	var beh: Node = r[0]
	var unit: FakeUnit = r[1]
	beh.update(0.1)
	_runner.assert_true(unit.arrive_calls == 0, "非编队成员不应播 arrive")
	_runner.assert_true(beh.is_finished(), "非编队成员到达应直接 finish")


func _test_reposition() -> void:
	var fs: Node = ScriptFormationSystem.new()
	fs.setup(FakeOrgApi.new())
	var u0 := FakeUnit.new()
	var u1 := FakeUnit.new()
	var u2 := FakeUnit.new()
	u0.position = Vector2(0, 0)
	u1.position = Vector2(50, 0)
	u2.position = Vector2(100, 0)
	var sid: String = fs.create_squad([u0, u1, u2], "补位队", "fp_combat_squad")
	if sid.is_empty():
		_runner.assert_true(false, "小队创建失败")
		return
	var base := Vector2(500, 500)
	var before: Vector2 = fs.get_squad_dest(sid, u2, base, "line")
	# 模拟 u0 死亡：从 squad 移除（formation._process 的死亡移除路径）
	var squad: Dictionary = fs._squads[sid]
	squad["units"].remove_at(0)
	var after: Vector2 = fs.get_squad_dest(sid, u2, base, "line")
	_runner.assert_true(after != before, "队友移除后 u2 点位应变化（自动补位）")
