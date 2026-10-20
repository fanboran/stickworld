extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：班级意图规划器的号令粘性（批4，02 一-A.5——最短保持期 + 事件触发
## 换令，周期重判退役）。覆盖：保持期内更优候选不换 / 要地威胁事件立即放行 /
## 保持期到后正常重判 / 翻转计数口径。夹具全桩（points/orders/provider 注入），
## 不进场景树、零 RNG。
## 夹具数值经打分公式推演标定（m1 远中立 vs m2 门口己占 + 威胁 urgency 能压过
## 惯性留任 30 分），改打分常量时同步校。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptPlanner := preload("res://modules/tactics/scripts/capture/squad_intent_planner.gd")
const ScriptCapturePoint := preload("res://modules/tactics/scripts/capture/capture_point.gd")

var _runner: TestRunner


## 桩号令节点（duck：记录 issue 调用）
class StubOrders extends Node:
	var issues: Array = []

	func issue(_order_type: int, _squad_id: String, _pos: Vector2,
			_source_tier: int = 0, _extra: Dictionary = {}) -> bool:
		issues.append({ "type": _order_type, "sid": _squad_id, "pos": _pos })
		return true


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("粘性: 保持期内更优候选不换令", _test_hold_gate)
	_runner.add_test("事件: 要地威胁立即放行重判", _test_threat_event)
	_runner.add_test("到期: 保持期过后正常重判", _test_hold_expire)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────────────── 夹具 ────────────────────────────────

## 红方（faction 2）视角：m1(600,0) 中立、m2(-480,0) 红占、m3(-600,0) 蓝占；
## 红班 R1 初始在 (300,0)（m1 最近，首拍 CAPTURE m1；且距 m2 780 ≤ 防区 900——
## 威胁事件可放行）；蓝班 B1 初始 (-1200,0)（距 m2=720 > EVENT_THREAT_DIST 无
## 威胁）。改 snap 元素 pos/faction 即改战场。
func _make_fixture() -> Dictionary:
	var m1: RefCounted = ScriptCapturePoint.new()
	m1.setup("m1", Vector2(600, 0), 120.0, 0)
	var m2: RefCounted = ScriptCapturePoint.new()
	m2.setup("m2", Vector2(-480, 0), 120.0, 2)
	var m3: RefCounted = ScriptCapturePoint.new()
	m3.setup("m3", Vector2(-600, 0), 120.0, 1)
	var snap: Array = [
		{ "pos": Vector2(300, 0), "faction": 2, "squad_id": "R1" },
		{ "pos": Vector2(320, 20), "faction": 2, "squad_id": "R1" },
		{ "pos": Vector2(-1200, 0), "faction": 1, "squad_id": "B1" },
	]
	var provider := Callable(func() -> Array: return snap)
	var orders := StubOrders.new()
	add_child(orders)
	var planner: RefCounted = ScriptPlanner.new()
	planner.setup(2, [m1, m2, m3], ["R1"], orders, provider, true)
	return { "planner": planner, "m1": m1, "m2": m2, "snap": snap, "orders": orders }


# ─────────────────────────────── 用例 ────────────────────────────────

## 保持期内出现更优候选（全班挪到己占 m2 门口驻防更近）：不换令、翻转不涨
func _test_hold_gate() -> void:
	var w := _make_fixture()
	var p: RefCounted = w["planner"]
	p.tick(0.5)   # 拍1：CAPTURE m1（170 分），hold_until = 0.5 + 4.0
	_runner.assert_equal(int(p.get_squad_intent("R1")), ScriptPlanner.Intent.CAPTURE, "首拍选攻点")
	_runner.assert_equal(str(p.get_squad_target("R1")), "m1", "首拍目标 m1")
	# 拍2：R1 全班挪到 m2 门口（无易主、B1 仍远——非事件拍）
	for u in w["snap"]:
		if u["squad_id"] == "R1":
			u["pos"] = Vector2(-460, 10)
	p.tick(0.5)
	_runner.assert_equal(int(p.get_squad_intent("R1")), ScriptPlanner.Intent.CAPTURE, "保持期内意图不变（CAPTURE）")
	_runner.assert_equal(str(p.get_squad_target("R1")), "m1", "保持期内目标不换（粘性门）")
	var stats: Dictionary = p.get_order_stats()
	_runner.assert_equal(int(stats["flips"]), 1, "翻转计数停在首拍 1 次（更优候选被粘性拦下）")


## 保持期内要地威胁（蓝班贴进己占 m2 威胁半径）：事件拍立即放行重判，
## INTERCEPT 的 urgency 放大（≈217 分）压过惯性留任（170+30）
func _test_threat_event() -> void:
	var w := _make_fixture()
	var p: RefCounted = w["planner"]
	p.tick(0.5)
	_runner.assert_equal(str(p.get_squad_target("R1")), "m1", "前置：首拍目标 m1")
	# 拍2（仍在保持期）：B1 贴进 m2 门口（距 20 < 600 = 威胁事件）
	for u in w["snap"]:
		if u["squad_id"] == "B1":
			u["pos"] = Vector2(-500, 0)
	p.tick(0.5)
	_runner.assert_equal(int(p.get_squad_intent("R1")), ScriptPlanner.Intent.INTERCEPT,
			"威胁事件拍立即放行重判（保持期例外 → 拦截）")


## 意图完成后转进（未完成续期语义）：CAPTURE m1 期间到期不换（续期承诺感）；
## m1 被占下（owner→红）后放行重判——全班已在蓝占 m3 门口，CAPTURE m3
##（170 分）压过惯性留任的远点 m1（103+30=133）
func _test_hold_expire() -> void:
	var w := _make_fixture()
	var p: RefCounted = w["planner"]
	p.tick(0.5)
	for u in w["snap"]:
		if u["squad_id"] == "R1":
			u["pos"] = Vector2(-580, 10)
	# 未完成续期：m1 尚未打下，到期也续期不换（承诺感——推进中不折腾）
	for i in 5:
		p.tick(0.5)
	_runner.assert_equal(str(p.get_squad_target("R1")), "m1", "目标未完成到期续期（不换令）")
	# m1 被占下（易主事件拍放行）→ 转进门口 m3
	(w["m1"] as RefCounted).owner_faction = 2
	for i in 2:
		p.tick(0.5)
	_runner.assert_equal(int(p.get_squad_intent("R1")), ScriptPlanner.Intent.CAPTURE,
			"完成后重判生效（仍攻点语义）")
	_runner.assert_equal(str(p.get_squad_target("R1")), "m3", "完成后转进门口 m3")
	var stats: Dictionary = p.get_order_stats()
	_runner.assert_equal(int(stats["flips"]), 2, "转进换令计一次翻转")
