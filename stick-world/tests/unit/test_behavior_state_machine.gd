extends Node
## 单元测试：BehaviorStateMachine 注册/travel/调度纯逻辑（假行为白盒）。
## 不进场景树，确定性。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptBehaviorStateMachine := preload("res://modules/units/scripts/ai/behavior_state_machine.gd")
const ScriptBehaviorBase := preload("res://modules/units/scripts/ai/behavior_base.gd")

var _runner: TestRunner


## 假行为：记录 enter/exit/update 调用
class FakeBehavior:
	extends "res://modules/units/scripts/ai/behavior_base.gd"
	var enter_calls: Array = []
	var exit_calls: Array = []
	var update_calls: int = 0
	var finish_on_update: bool = false

	func enter(previous: String, params: Dictionary) -> void:
		super.enter(previous, params)
		enter_calls.append([previous, params])

	func update(_delta: float) -> void:
		update_calls += 1
		if finish_on_update:
			finish()

	func exit(next: String) -> void:
		super.exit(next)
		exit_calls.append(next)


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("StateMachine: 注册行为并 travel 切换", _test_register_travel)
	_runner.add_test("StateMachine: 未注册行为不切换且告警", _test_unknown_behavior)
	_runner.add_test("StateMachine: travel 传递 previous 与 params", _test_enter_params)
	_runner.add_test("StateMachine: 切换时旧行为 exit、新行为 enter", _test_exit_on_switch)
	_runner.add_test("StateMachine: physics_update 转发给当前行为", _test_physics_update)
	_runner.add_test("StateMachine: finished 行为不接收 update", _test_finished_stops)
	_runner.add_test("StateMachine: 空注册行为被拒绝", _test_empty_register)
	_runner.run()
	print(_runner.summary())
	get_tree().quit(0 if _runner.all_passed() else 1)


func _make_fake(fake_name: String) -> FakeBehavior:
	var b := FakeBehavior.new()
	b.behavior_name = fake_name
	return b


func _make_sm() -> ScriptBehaviorStateMachine:
	return ScriptBehaviorStateMachine.new()


func _test_register_travel() -> void:
	var sm := _make_sm()
	var idle := _make_fake("idle")
	var wander := _make_fake("wander")
	sm.register_behavior(idle)
	sm.register_behavior(wander)
	_runner.assert_equal(sm.get_current_behavior_name(), "", "初始无行为")
	sm.travel("wander")
	_runner.assert_equal(sm.get_current_behavior_name(), "wander", "应切到 wander")
	_runner.assert_true(sm.has_active_behavior(), "应有激活行为")
	sm.travel("idle")
	_runner.assert_equal(sm.get_current_behavior_name(), "idle", "应切回 idle")


func _test_unknown_behavior() -> void:
	var sm := _make_sm()
	sm.register_behavior(_make_fake("idle"))
	sm.travel("idle")
	sm.travel("nonexistent")
	_runner.assert_equal(sm.get_current_behavior_name(), "idle", "未注册行为不应切换")


func _test_enter_params() -> void:
	var sm := _make_sm()
	var idle := _make_fake("idle")
	var wander := _make_fake("wander")
	sm.register_behavior(idle)
	sm.register_behavior(wander)
	var params := {"duration": 5.0, "target": Vector2(10, 20)}
	sm.travel("idle", params)
	_runner.assert_equal(idle.enter_calls.size(), 1, "idle 应 enter 一次")
	_runner.assert_equal(idle.enter_calls[0][1], params, "params 应传递")
	_runner.assert_equal(idle.enter_calls[0][0], "", "首次 enter previous 为空")
	sm.travel("wander", {})
	_runner.assert_equal(wander.enter_calls[0][0], "idle", "previous 应为 idle")


func _test_exit_on_switch() -> void:
	var sm := _make_sm()
	var a := _make_fake("a")
	var b := _make_fake("b")
	sm.register_behavior(a)
	sm.register_behavior(b)
	sm.travel("a")
	_runner.assert_true(a.is_active(), "a 激活")
	sm.travel("b")
	_runner.assert_false(a.is_active(), "切换后 a 退出")
	_runner.assert_equal(a.exit_calls.size(), 1, "a exit 一次")
	_runner.assert_equal(a.exit_calls[0], "b", "exit 参数为下一个行为名")
	_runner.assert_true(b.is_active(), "b 激活")


func _test_physics_update() -> void:
	var sm := _make_sm()
	var a := _make_fake("a")
	sm.register_behavior(a)
	sm.travel("a")
	sm.physics_update(0.016)
	sm.physics_update(0.016)
	_runner.assert_equal(a.update_calls, 2, "update 应转发 2 次")
	_runner.assert_equal(sm.is_current_finished(), false, "未 finish")


func _test_finished_stops() -> void:
	var sm := _make_sm()
	var a := _make_fake("a")
	a.finish_on_update = true
	sm.register_behavior(a)
	sm.travel("a")
	sm.physics_update(0.016)
	_runner.assert_true(a.is_finished(), "行为应 finish")
	_runner.assert_equal(a.update_calls, 1, "finish 后不再 update")
	_runner.assert_true(sm.is_current_finished(), "状态机应感知 finished")
	_runner.assert_true(sm.has_active_behavior(), "行为仍 active（未 exit）")


func _test_empty_register() -> void:
	var sm := _make_sm()
	var empty := _make_fake("")
	sm.register_behavior(empty)
	sm.travel("")
	_runner.assert_equal(sm.get_current_behavior_name(), "", "空名行为不应可 travel")
