extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：HealthComponent 生命数值逻辑。
## 纯数据层测试：不进场景树（不触发 _ready），手动设值，确定性。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptHealthComponent := preload("res://modules/units/scripts/entity/health_component.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("HealthComponent: 初始化后满血", _test_init)
	_runner.add_test("HealthComponent: take_damage 扣血", _test_damage)
	_runner.add_test("HealthComponent: is_dead 边界", _test_dead_boundary)
	_runner.add_test("HealthComponent: 死亡后 take_damage 无效果", _test_no_damage_after_death)
	_runner.add_test("HealthComponent: heal 不超过上限", _test_heal_caps)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _new_health(max_hp: float) -> Node:
	var h = _runner.track_node(ScriptHealthComponent.new())
	h.max_hp = max_hp
	h.hp = max_hp
	return h


func _test_init() -> void:
	var h := _new_health(40.0)
	_runner.assert_true(not h.is_dead(), "初始不应死亡")
	_runner.assert_equal(h.get_hp_ratio(), 1.0, "HP 比例应为 1")


func _test_damage() -> void:
	var h := _new_health(40.0)
	h.take_damage(10.0, null)
	_runner.assert_equal(h.hp, 30.0, "HP 应扣 10")
	_runner.assert_true(not h.is_dead(), "10 伤不致死")


func _test_dead_boundary() -> void:
	var h := _new_health(40.0)
	h.take_damage(40.0, null)
	_runner.assert_true(h.is_dead(), "40 伤恰好归零应死亡")
	_runner.assert_equal(h.hp, 0.0, "HP 不应为负")


func _test_no_damage_after_death() -> void:
	var h := _new_health(40.0)
	h.take_damage(50.0, null)
	h.take_damage(10.0, null)
	_runner.assert_equal(h.hp, 0.0, "死亡后伤害无效")


func _test_heal_caps() -> void:
	var h := _new_health(40.0)
	h.take_damage(10.0, null)
	h.heal(99.0)
	_runner.assert_equal(h.hp, 40.0, "heal 不超过 max_hp")
