extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：指挥链纯逻辑（CommandChain 送达执行 + TacticalOrders 号令映射）。
##
## 3-F2 职责重划（架构文档 §4.2.4）：旧 base_delay × tier_diff 抽象公式已退役，
## 延迟唯一来源 = 传输层物理传播（数值断言归 test_transport_layer）；
## 本文件断言 deliver 恒即时送达 + 签名兼容 + 防御守卫 + 号令映射。确定性，不进场景树。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptCommandChain := preload("res://modules/combat/scripts/command/command_chain.gd")
const ScriptTacticalOrders := preload("res://modules/combat/scripts/command/tactical_orders.gd")

var _runner: TestRunner


## 桩 AI 控制器（set_order 捕获；_execute_delivery 的 ai 形参类型注解为 Node，桩须同型）
class StubAI extends Node:
	var behavior: String = ""
	var params: Dictionary = {}

	func set_order(behavior_name: String, p: Dictionary) -> void:
		behavior = behavior_name
		params = p


## 桩单位（足够 _execute_delivery 消费）
class StubUnit:
	var ai: StubAI = StubAI.new()

	func is_dead() -> bool:
		return false

	func get_ai_controller() -> StubAI:
		return ai

	func free_ai() -> void:
		if ai != null:
			ai.free()


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("CommandChain: deliver 恒即时送达（撤抽象公式，签名兼容）", _test_deliver_instant)
	_runner.add_test("CommandChain: 死亡单位跳过、活体照常送达", _test_deliver_skips_dead)
	_runner.add_test("CommandChain: deliver_via_orgs 缺 org_api 安全返回", _test_relay_guard)
	_runner.add_test("TacticalOrders: 号令类型到行为名映射", _test_order_to_behavior)
	_runner.add_test("TacticalOrders: 号令类型到行为参数映射", _test_order_to_params)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _test_deliver_instant() -> void:
	var cc := ScriptCommandChain.new()
	var unit := StubUnit.new()
	var delivered: Array = []
	cc.order_delivered.connect(func(_t: int, sid: String, ids: Array) -> void: delivered.append([sid, ids]))
	# source_tier/squad_tier/spread_mode 照旧传参（签名兼容，不再参与任何延迟计算）
	cc.deliver(0, "squad_x", [unit], "move", {"target": Vector2(1, 2)}, 3, 1, "line")
	_runner.assert_equal(unit.ai.behavior, "move", "deliver 应即时送达（延迟由传输层承担）")
	_runner.assert_equal(unit.ai.params.get("target", Vector2.ZERO), Vector2(1, 2), "行为参数应透传")
	_runner.assert_equal(delivered.size(), 1, "order_delivered 应同步发射一次")
	unit.free_ai()


func _test_deliver_skips_dead() -> void:
	var cc := ScriptCommandChain.new()
	var alive := StubUnit.new()
	var dead_unit := DeadStubUnit.new()
	last_delivered_ids = []
	cc.order_delivered.connect(_capture_delivered)
	cc.deliver(1, "squad_y", [alive, dead_unit], "idle", {}, 0, 1, "")
	_runner.assert_equal(alive.ai.behavior, "idle", "活体单位应收到号令")
	_runner.assert_equal(dead_unit.ai.behavior, "", "死亡单位应跳过（不设置行为）")
	_runner.assert_equal(last_delivered_ids.size(), 1, "unit_ids 应只含送达的活体单位（死者跳过）")
	alive.free_ai()


func _test_relay_guard() -> void:
	var cc := ScriptCommandChain.new()
	var plan := {"hops": [{"from_org": "", "to_org": "org_a", "order": {}}]}
	# org_api 缺失 → push_warning + return（守卫在 await 之前，无场景树也安全）
	cc.deliver_via_orgs(plan, null, 0, "move", {}, "")
	_runner.assert_true(true, "缺 org_api 应安全返回不崩溃")


## 死亡桩单位
class DeadStubUnit:
	var ai: StubAI = StubAI.new()

	func is_dead() -> bool:
		return true

	func get_ai_controller() -> StubAI:
		return ai


## order_delivered 捕获（connect 成员方法形态，避免用例间闭包状态残留）
var last_delivered_ids: Array = []

func _capture_delivered(_t: int, _sid: String, ids: Array) -> void:
	last_delivered_ids = ids.duplicate()


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
