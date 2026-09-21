extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：结束判定与结算载荷（扩张循环 P2）。
##
## 钉死三条语义：
## ① 相持超时兜底——`duration_limit` 到期按剩余兵力判（多者胜，平局/攻方更少 = 守方胜），
##    防"溃逃—恢复—再战"长期相持永不收敛；
## ② 未到期不打断——相持中的战斗仍由全灭/撤离收敛，超时只在到期后生效；
## ③ 结算载荷 `battle_settled` 先于 `battle_ended` 到达，且字段齐备到监听方不必回查实例
##    （实例在 _end 末尾 queue_free）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const BattleScript := preload("res://modules/combat/scripts/battle/battle_instance.gd")

func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("超时: 攻方多者胜（timeout 收束）", _test_timeout_attacker_wins)
	_runner.add_test("超时: 平局判守方胜（未拿下）", _test_timeout_defender_wins)
	_runner.add_test("未到期: 相持不结束", _test_ongoing_before_limit)
	_runner.add_test("结算: battle_settled 先到且字段齐备", _test_settled_payload)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


var _runner: TestRunner
## 结算信号捕获（battle_settled 载荷）
var _settled: Dictionary = {}
## 事件到达顺序（"settled" / "ended"）
var _order: Array[String] = []


## 交战态战斗实例（假单位 = 裸 Node：无 is_dead 即计存活，专测判定分支）
func _make_battle(attackers: int, defenders: int, limit: float, elapsed: float) -> Node:
	var b := BattleScript.new()
	add_child(b)
	b._state = BattleScript.State.ENGAGED
	for i in attackers:
		var u := Node.new()
		b._units_attacker.append(u)
		add_child(u)
	for i in defenders:
		var u := Node.new()
		b._units_defender.append(u)
		add_child(u)
	b.duration_limit = limit
	b._duration = elapsed
	return b


func _test_timeout_attacker_wins() -> void:
	var b := _make_battle(2, 1, 10.0, 20.0)
	b._check_victory()
	var summary: Dictionary = b.get_summary()
	_runner.assert_equal(String(summary.get("reason", "")), "timeout", "收束原因=超时")
	_runner.assert_equal(int(summary.get("result", -1)), BattleScript.State.ATTACKER_WIN, "兵力多者胜（攻方）")
	_runner.assert_equal(int((summary.get("alive", {}) as Dictionary).get(1, -1)), 2, "摘要含攻方存活快照")


func _test_timeout_defender_wins() -> void:
	var b := _make_battle(1, 2, 10.0, 20.0)
	b._check_victory()
	_runner.assert_equal(int(b.get_summary().get("result", -1)), BattleScript.State.DEFENDER_WIN,
			"攻方未占优 → 守方胜")
	# 平局同判守方（攻方未能拿下）
	var b2 := _make_battle(1, 1, 10.0, 20.0)
	b2._check_victory()
	_runner.assert_equal(int(b2.get_summary().get("result", -1)), BattleScript.State.DEFENDER_WIN,
			"兵力相等 → 守方胜")


func _test_ongoing_before_limit() -> void:
	var b := _make_battle(2, 1, 30.0, 20.0)
	b._check_victory()
	_runner.assert_equal(int(b._state), BattleScript.State.ENGAGED, "未到期不结束（仍交战）")


func _test_settled_payload() -> void:
	_settled = {}
	_order = []
	var on_settled := func(_bid: String, summary: Dictionary) -> void:
		_settled = summary
		_order.append("settled")
	var on_ended := func(_bid: String, _v: bool) -> void:
		_order.append("ended")
	if not EventBus.battle_settled.is_connected(on_settled):
		EventBus.battle_settled.connect(on_settled)
	if not EventBus.battle_ended.is_connected(on_ended):
		EventBus.battle_ended.connect(on_ended)
	var b := _make_battle(1, 2, 10.0, 20.0)
	b._check_victory()
	EventBus.battle_settled.disconnect(on_settled)
	EventBus.battle_ended.disconnect(on_ended)
	for field in ["result", "reason", "duration", "player_wins", "player_faction", "casualties", "alive"]:
		_runner.assert_true(_settled.has(field), "摘要字段 %s 齐备" % field)
	_runner.assert_equal(_order.size(), 2, "两个信号都到达")
	if _order.size() == 2:
		_runner.assert_equal(_order[0], "settled", "结算载荷先于胜负信号（监听方需先拿数据）")
