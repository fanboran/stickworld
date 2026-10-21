extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：AI 决策可视化观测面（纯可观测性，AI 决策零改动）。
## ① travel 唯一入口埋点：任意路径切换都发 EventBus.ai_behavior_switched，
##    载荷 =（entity, from, to, params）
## ② 原因推断（信号时点消费）：号令路径 / 打通态 / 行为语义表
## ③ 决策零变化回归：埋点后 travel 的状态迁移结果与行为执行照旧

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptAIController := preload("res://modules/units/scripts/ai/ai_controller.gd")

## 捕获到的切换载荷（[{entity, from, to, params}]）
var _captured: Array = []


## 最小单位桩（对齐 test_behavior_breach.FakeUnit：AIController 装配所需 duck 面）
class FakeUnit:
	extends CharacterBody2D
	var faction_id: int = 1
	var battle: Node = null
	var weapon: Node = null
	var ai: Node = null
	var _dead: bool = false

	func get_faction() -> int:
		return faction_id

	func get_battle_instance() -> Node:
		return battle

	func get_map() -> Node2D:
		return null

	func get_weapon() -> Node:
		return weapon

	func get_ai_controller() -> Node:
		return ai

	func get_formation_system() -> Node:
		return null

	func is_dead() -> bool:
		return _dead

	func is_possessed() -> bool:
		return false

	func ai_stop() -> void:
		pass

	func ai_move(_dir: Vector2, _run: bool) -> void:
		pass


## 战斗桩（is_active 真值打通态门禁用）
class StubBattle:
	extends Node
	func is_active() -> bool:
		return true

	func get_enemies_of(_faction: int) -> Array:
		return []

	func get_allies_of(_faction: int) -> Array:
		return []


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("埋点: travel 唯一入口发切换信号（载荷 entity/from/to）", _test_travel_emits_signal)
	_runner.add_test("推断: 号令路径原因（号令移动）", _test_reason_order)
	_runner.add_test("推断: 打通态原因（接战拦路者）", _test_reason_breach)
	_runner.add_test("推断: 行为语义表（attack=参战接敌 / idle=回收待命）", _test_reason_semantics)
	_runner.add_test("零回归: 埋点后 travel 状态迁移照旧", _test_travel_still_switches)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


var _runner: TestRunner


## 夹具：FakeUnit + AIController 手工装配（不进树，先例 test_behavior_breach）
func _make_ctx() -> Dictionary:
	var unit := FakeUnit.new()
	unit.position = Vector2(0, 0)
	var battle := StubBattle.new()
	unit.battle = battle
	var ai: Node = ScriptAIController.new()
	ai._entity = unit
	ai._setup_state_machine()
	unit.ai = ai
	return {"unit": unit, "battle": battle, "ai": ai}


func _teardown_ctx(ctx: Dictionary) -> void:
	for key in ["unit", "battle", "ai"]:
		if ctx.get(key) != null and is_instance_valid(ctx[key]):
			ctx[key].free()
	_captured.clear()


func _on_switched(entity, from_b: String, to_b: String, params: Dictionary) -> void:
	_captured.append({"entity": entity, "from": from_b, "to": to_b, "params": params})


# ── ① travel 埋点 ──

func _test_travel_emits_signal() -> void:
	var ctx := _make_ctx()
	EventBus.ai_behavior_switched.connect(_on_switched)
	# 装配期 _setup_state_machine 已 travel("idle") 一次（连接前，不入捕获）；
	# 此处显式切换触发一次可捕获的发射
	ctx.ai._state_machine.travel("move", {"target": Vector2(100, 0)})
	EventBus.ai_behavior_switched.disconnect(_on_switched)
	_runner.assert_gt(_captured.size(), 0, "travel 应发射切换信号")
	if _captured.is_empty():
		_teardown_ctx(ctx)
		return
	var last: Dictionary = _captured[-1]
	_runner.assert_equal(last["entity"], ctx.unit, "载荷 entity = 所属单位")
	_runner.assert_equal(last["from"], "idle", "载荷 from = 切换前行为")
	_runner.assert_equal(last["to"], "move", "载荷 to = 切换后行为")
	_runner.assert_true(last["params"].has("target"), "载荷 params 透传 travel 参数")
	_teardown_ctx(ctx)


# ── ② 原因推断 ──

## 号令路径：set_order 后 travel 同名行为 → "号令…"
func _test_reason_order() -> void:
	var ctx := _make_ctx()
	ctx.ai.set_order("move", {"target": Vector2(500, 300)})
	var reason: String = _Snapshot.describe_switch_reason(
			ctx.unit, ctx.ai, "move", {"target": Vector2(500, 300)})
	_runner.assert_true(reason.contains("号令"), "号令在身 → 原因含「号令」，实际: %s" % reason)
	_runner.assert_true(reason.contains("移动"), "原因带行为中文名，实际: %s" % reason)
	_teardown_ctx(ctx)


## 打通态：request_breach_engagement 后 → "打通"
func _test_reason_breach() -> void:
	var ctx := _make_ctx()
	var blocker := FakeUnit.new()
	blocker.position = Vector2(50, 0)
	var ok: bool = ctx.ai.request_breach_engagement(blocker)
	_runner.assert_true(ok, "打通态请求应成立（战斗激活+战斗职责）")
	var reason: String = _Snapshot.describe_switch_reason(
			ctx.unit, ctx.ai, "attack", {"forced_target": blocker})
	_runner.assert_true(reason.contains("打通"), "打通在身 → 原因含「打通」，实际: %s" % reason)
	blocker.free()
	_teardown_ctx(ctx)


## 行为语义表：无号令无打通时按目标行为给语义
func _test_reason_semantics() -> void:
	var ctx := _make_ctx()
	var r_attack: String = _Snapshot.describe_switch_reason(ctx.unit, ctx.ai, "attack", {})
	_runner.assert_true(r_attack.contains("参战接敌"), "attack → 参战接敌，实际: %s" % r_attack)
	var r_idle: String = _Snapshot.describe_switch_reason(ctx.unit, ctx.ai, "idle", {})
	_runner.assert_true(r_idle.contains("待命") or r_idle.contains("回收"),
			"idle → 回收待命，实际: %s" % r_idle)
	var r_work: String = _Snapshot.describe_switch_reason(ctx.unit, ctx.ai, "work", {})
	_runner.assert_true(r_work.contains("派工"), "work → 接建造派工，实际: %s" % r_work)
	_teardown_ctx(ctx)


# ── ③ 零回归 ──

func _test_travel_still_switches() -> void:
	var ctx := _make_ctx()
	var sm: Node = ctx.ai.get_state_machine()
	sm.travel("wander", {})
	_runner.assert_equal(sm.get_current_behavior_name(), "wander", "埋点后迁移结果不变")
	_runner.assert_true(sm.has_active_behavior(), "埋点后激活态不变")
	# 决策时钟观测面照常（既有导出，可视化窗口消费）
	var ts: Dictionary = ctx.ai.get_decision_timing_state()
	_runner.assert_true(ts.has("decision"), "决策时钟快照含 decision 段")
	_teardown_ctx(ctx)


## 观测快照层（debug_gui；被测面为纯静态查询库）
const _Snapshot := preload("res://modules/debug_gui/scripts/ai_viz_snapshot.gd")
