extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：HealthComponent 生命/士气数值逻辑。
## 纯数据层测试：不进场景树（不触发 _ready），手动设值，确定性。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptHealthComponent := preload("res://modules/units/scripts/entity/health_component.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("HealthComponent: 初始化后满血满士气", _test_init)
	_runner.add_test("HealthComponent: take_damage 扣血并按比例扣士气", _test_damage_morale)
	_runner.add_test("HealthComponent: 士气伤害系数 0.6（12 伤扣 7.2）", _test_morale_ratio_value)
	_runner.add_test("HealthComponent: 士气不降到 0 以下", _test_morale_floor)
	_runner.add_test("HealthComponent: is_dead 边界", _test_dead_boundary)
	_runner.add_test("HealthComponent: 死亡后 take_damage 无效果", _test_no_damage_after_death)
	_runner.add_test("HealthComponent: heal/restore_morale 不超过上限", _test_heal_caps)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _new_health(max_hp: float, max_morale: float) -> Node:
	var h := ScriptHealthComponent.new()
	h.max_hp = max_hp
	h.max_morale = max_morale
	h.hp = max_hp
	h.morale = max_morale
	return h


func _test_init() -> void:
	var h := _new_health(40.0, 100.0)
	_runner.assert_true(not h.is_dead(), "初始不应死亡")
	_runner.assert_equal(h.get_hp_ratio(), 1.0, "HP 比例应为 1")


func _test_damage_morale() -> void:
	var h := _new_health(40.0, 100.0)
	h.take_damage(10.0, null)
	_runner.assert_equal(h.hp, 30.0, "HP 应扣 10")
	_runner.assert_equal(h.morale, 94.0, "士气应扣 10*0.6=6")


func _test_morale_ratio_value() -> void:
	# 士气纯数值语义（裁决【删溃逃、立避战】：阈值布尔态退役，士气只做打分输入）
	var h := _new_health(40.0, 25.0)
	h.take_damage(12.0, null)   # 士气 25 - 7.2 = 17.8
	h.take_damage(12.0, null)   # 17.8 - 7.2 = 10.6
	_runner.assert_approx(h.morale, 10.6, 0.001, "两次 12 伤后士气 10.6")
	h.take_damage(12.0, null)   # 10.6 - 7.2 = 3.4
	_runner.assert_approx(h.morale, 3.4, 0.001, "三次 12 伤（36 伤）后士气 3.4")
	_runner.assert_true(not h.is_dead(), "36 伤 < 40 HP 不应死亡")


func _test_morale_floor() -> void:
	var h := _new_health(40.0, 25.0)
	h.take_damage(30.0, null)   # hp=10, 士气 25-18=7
	h.take_damage(30.0, null)   # hp=0（死亡判定在扣士气之后）, 士气 maxf(0, 7-18)=0
	_runner.assert_equal(h.morale, 0.0, "士气不应低于 0")
	_runner.assert_true(h.is_dead(), "累计伤害后应死亡")



func _test_dead_boundary() -> void:
	var h := _new_health(40.0, 100.0)
	h.take_damage(40.0, null)
	_runner.assert_true(h.is_dead(), "40 伤恰好归零应死亡")
	_runner.assert_equal(h.hp, 0.0, "HP 不应为负")


func _test_no_damage_after_death() -> void:
	var h := _new_health(40.0, 100.0)
	h.take_damage(50.0, null)
	h.take_damage(10.0, null)
	_runner.assert_equal(h.hp, 0.0, "死亡后伤害无效")


func _test_heal_caps() -> void:
	var h := _new_health(40.0, 100.0)
	h.take_damage(10.0, null)
	h.heal(99.0)
	_runner.assert_equal(h.hp, 40.0, "heal 不超过 max_hp")
	h.restore_morale(99.0)
	_runner.assert_equal(h.morale, 100.0, "restore_morale 不超过 max_morale")
