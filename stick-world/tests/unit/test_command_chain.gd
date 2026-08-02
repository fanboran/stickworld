extends Node
## 单元测试：指挥链延迟公式 + 战术号令映射（纯逻辑）。
## CommandChain._calculate_delay / TacticalOrders._order_to_behavior / _order_to_params。
## 不进场景树，确定性。

const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptCommandChain := preload("res://modules/combat/scripts/command/command_chain.gd")
const ScriptTacticalOrders := preload("res://modules/combat/scripts/command/tactical_orders.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("CommandChain: 玩家直接指挥（tier 0）零延迟", _test_player_direct)
	_runner.add_test("CommandChain: 跨一层延迟 = base_delay ×1", _test_one_tier)
	_runner.add_test("CommandChain: 同级零延迟", _test_same_tier)
	_runner.add_test("CommandChain: 发令层级高于接收层级零延迟", _test_higher_tier)
	_runner.add_test("TacticalOrders: 号令类型到行为名映射", _test_order_to_behavior)
	_runner.add_test("TacticalOrders: 号令类型到行为参数映射", _test_order_to_params)
	_runner.run()
	print(_runner.summary())
	get_tree().quit(0 if _runner.all_passed() else 1)


func _test_player_direct() -> void:
	var cc := ScriptCommandChain.new()
	_runner.assert_equal(cc._calculate_delay(0, 1), 0.0, "玩家直接指挥应零延迟")
	_runner.assert_equal(cc._calculate_delay(0, 3), 0.0, "玩家跨多层也应零延迟（P0 单层级零延迟）")


func _test_one_tier() -> void:
	var cc := ScriptCommandChain.new()
	_runner.assert_equal(cc._calculate_delay(1, 2), cc.BASE_DELAY, "跨一层 = base_delay（2s）")
	_runner.assert_equal(cc._calculate_delay(2, 3), cc.BASE_DELAY, "任意相邻层差 = base_delay")


func _test_same_tier() -> void:
	var cc := ScriptCommandChain.new()
	_runner.assert_equal(cc._calculate_delay(2, 2), 0.0, "同级指挥零延迟")
	_runner.assert_equal(cc._calculate_delay(1, 1), 0.0, "L1 排长指挥零延迟")


func _test_higher_tier() -> void:
	var cc := ScriptCommandChain.new()
	_runner.assert_equal(cc._calculate_delay(3, 1), 0.0, "高级别向下发令零延迟（tier_diff 取 max(0)）")


func _test_order_to_behavior() -> void:
	var to := ScriptTacticalOrders.new()
	_runner.assert_equal(to._order_to_behavior(ScriptTacticalOrders.OrderType.ADVANCE_ALL), "move", "ADVANCE_ALL -> move")
	_runner.assert_equal(to._order_to_behavior(ScriptTacticalOrders.OrderType.SPRINT), "move", "SPRINT -> move")
	_runner.assert_equal(to._order_to_behavior(ScriptTacticalOrders.OrderType.HOLD_POSITION), "idle", "HOLD_POSITION -> idle")
	_runner.assert_equal(to._order_to_behavior(ScriptTacticalOrders.OrderType.RETREAT), "retreat", "RETREAT -> retreat")
	_runner.assert_equal(to._order_to_behavior(ScriptTacticalOrders.OrderType.TAKE_COVER), "seek_cover", "TAKE_COVER -> seek_cover")
	_runner.assert_equal(to._order_to_behavior(ScriptTacticalOrders.OrderType.RALLY), "move", "RALLY -> move")


func _test_order_to_params() -> void:
	var to := ScriptTacticalOrders.new()
	var target := Vector2(100, 200)
	var adv: Dictionary = to._order_to_params(ScriptTacticalOrders.OrderType.ADVANCE_ALL, target)
	_runner.assert_equal(adv.get("target", Vector2.ZERO), target, "ADVANCE_ALL 携带目标点")
	var sprint: Dictionary = to._order_to_params(ScriptTacticalOrders.OrderType.SPRINT, target)
	_runner.assert_equal(sprint.get("run", false), true, "SPRINT 应跑步")
	_runner.assert_equal(sprint.get("target", Vector2.ZERO), target, "SPRINT 携带目标点")
	var hold: Dictionary = to._order_to_params(ScriptTacticalOrders.OrderType.HOLD_POSITION, target)
	_runner.assert_true(hold.is_empty(), "HOLD_POSITION 无参数")
	var retreat: Dictionary = to._order_to_params(ScriptTacticalOrders.OrderType.RETREAT, target)
	_runner.assert_true(retreat.is_empty(), "RETREAT 无参数（battle 由 behavior 自取）")
