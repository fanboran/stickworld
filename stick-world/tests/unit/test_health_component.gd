extends Node
## 单元测试：HealthComponent 生命/士气数值逻辑。
## 纯数据层测试：不进场景树（不触发 _ready），手动设值，确定性。

const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptHealthComponent := preload("res://modules/units/scripts/entity/health_component.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("HealthComponent: 初始化后满血满士气", _test_init)
	_runner.add_test("HealthComponent: take_damage 扣血并按比例扣士气", _test_damage_morale)
	_runner.add_test("HealthComponent: 士气伤害系数 0.6（12 伤扣 7.2）", _test_morale_ratio_value)
	_runner.add_test("HealthComponent: 士气不降到 0 以下", _test_morale_floor)
	_runner.add_test("HealthComponent: is_routed 边界（士气<=阈值）", _test_rout_boundary)
	_runner.add_test("HealthComponent: is_dead 边界", _test_dead_boundary)
	_runner.add_test("HealthComponent: 死亡后 take_damage 无效果", _test_no_damage_after_death)
	_runner.add_test("HealthComponent: heal/restore_morale 不超过上限", _test_heal_caps)
	_runner.run()
	print(_runner.summary())
	get_tree().quit(0 if _runner.all_passed() else 1)


func _new_health(max_hp: float, max_morale: float, rout_threshold: float) -> Node:
	var h := ScriptHealthComponent.new()
	h.max_hp = max_hp
	h.max_morale = max_morale
	h.rout_threshold = rout_threshold
	h.hp = max_hp
	h.morale = max_morale
	return h


func _test_init() -> void:
	var h := _new_health(40.0, 100.0, 20.0)
	_runner.assert_true(not h.is_dead(), "初始不应死亡")
	_runner.assert_true(not h.is_routed(), "初始不应溃逃")
	_runner.assert_equal(h.get_hp_ratio(), 1.0, "HP 比例应为 1")


func _test_damage_morale() -> void:
	var h := _new_health(40.0, 100.0, 20.0)
	h.take_damage(10.0, null)
	_runner.assert_equal(h.hp, 30.0, "HP 应扣 10")
	_runner.assert_equal(h.morale, 94.0, "士气应扣 10*0.6=6")
	_runner.assert_false(h.is_routed(), "94 士气不应溃逃")


func _test_morale_ratio_value() -> void:
	var h := _new_health(40.0, 25.0, 10.0)
	h.take_damage(12.0, null)   # 士气 25 - 7.2 = 17.8
	h.take_damage(12.0, null)   # 17.8 - 7.2 = 10.6
	_runner.assert_true(h.morale > 10.0, "两次 12 伤后士气 10.6，不应溃逃")
	h.take_damage(12.0, null)   # 10.6 - 7.2 = 3.4
	_runner.assert_true(h.is_routed(), "三次 12 伤（36 伤）后士气 3.4 <= 10 应溃逃")
	_runner.assert_true(not h.is_dead(), "36 伤 < 40 HP 不应死亡")


func _test_morale_floor() -> void:
	var h := _new_health(40.0, 25.0, 10.0)
	h.take_damage(30.0, null)   # hp=10, 士气 25-18=7
	h.take_damage(30.0, null)   # hp=0（死亡判定在扣士气之后）, 士气 maxf(0, 7-18)=0
	_runner.assert_equal(h.morale, 0.0, "士气不应低于 0")
	_runner.assert_true(h.is_dead(), "累计伤害后应死亡")


func _test_rout_boundary() -> void:
	var h := _new_health(40.0, 100.0, 20.0)
	h.take_damage(66.0, null)   # 士气 100 - 39.6 = 60.4，HP 40-66 <0 → 死亡
	_runner.assert_true(h.is_dead(), "66 伤应死亡")
	_runner.assert_true(not h.is_routed(), "死亡不算溃逃（is_routed 排除死亡）")


func _test_dead_boundary() -> void:
	var h := _new_health(40.0, 100.0, 20.0)
	h.take_damage(40.0, null)
	_runner.assert_true(h.is_dead(), "40 伤恰好归零应死亡")
	_runner.assert_equal(h.hp, 0.0, "HP 不应为负")


func _test_no_damage_after_death() -> void:
	var h := _new_health(40.0, 100.0, 20.0)
	h.take_damage(50.0, null)
	h.take_damage(10.0, null)
	_runner.assert_equal(h.hp, 0.0, "死亡后伤害无效")


func _test_heal_caps() -> void:
	var h := _new_health(40.0, 100.0, 20.0)
	h.take_damage(10.0, null)
	h.heal(99.0)
	_runner.assert_equal(h.hp, 40.0, "heal 不超过 max_hp")
	h.restore_morale(99.0)
	_runner.assert_equal(h.morale, 100.0, "restore_morale 不超过 max_morale")
