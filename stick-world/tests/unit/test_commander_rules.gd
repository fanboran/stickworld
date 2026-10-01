extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：指挥官规则（斩首判负 + 留守守卫 + rank 数据层）。
##
## 钉死四条语义：
## ① 斩首判负——登记指挥官阵亡 = 该方立即战败（reason="decapitation"），哪怕
##    还有兵也是败；斩首分支先于全灭判定。
## ② 零回归——无指挥官登记的战斗（既有全部战斗/测试）胜负路径完全不受影响；
##    指挥官健在时全灭/超时照常。
## ③ 登记双道——add_unit 自动扫描 rank>=3 登记；register_commander 供测试桩
##    /后设 rank 场景手动补登。
## ④ 留守守卫——rank>=3 的 AIController 拒绝推进/撤离类号令（move/retreat/
##    seek_cover），idle 放行；普通士兵号令不受影响。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const BattleScript := preload("res://modules/combat/scripts/battle/battle_instance.gd")
const EntityScript := preload("res://modules/units/scripts/stickman_entity.gd")
const AIControllerScript := preload("res://modules/units/scripts/ai/ai_controller.gd")


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("rank: 数据层 set/get/is_commander（含越界钳制）", _test_rank_data)
	_runner.add_test("斩首: 攻方指挥官亡 → 守方胜（decapitation）", _test_decapitation_attacker_down)
	_runner.add_test("斩首: 守方指挥官亡 → 攻方胜（decapitation）", _test_decapitation_defender_down)
	_runner.add_test("斩首: 指挥官健在 → 全灭照常（annihilation）", _test_no_decapitation_when_alive)
	_runner.add_test("回归: 无指挥官 → 既有全灭/超时路径不变", _test_no_commander_regression)
	_runner.add_test("登记: add_unit 自动扫描 rank>=3", _test_add_unit_auto_register)
	_runner.add_test("留守: 指挥官拒推进/撤离类号令（idle 放行）", _test_commander_order_guard)
	_runner.add_test("留守: 普通士兵号令不受守卫影响", _test_soldier_order_unguarded)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


var _runner: TestRunner


## 测试桩：带 rank/is_dead 的最小单位（斩首登记/判定消费面；
## 真实 StickmanEntity 的 rank 语义在 _test_rank_data 用真类验证）
class FakeUnit extends Node:
	var dead: bool = false
	var rank_v: int = 0


	func is_dead() -> bool:
		return dead


	func get_rank() -> int:
		return rank_v


## 交战态战斗实例（假单位桩；模式同 test_battle_settlement）
func _make_battle(attackers: int, defenders: int, limit: float, elapsed: float) -> Node:
	var b := BattleScript.new()
	add_child(b)
	# 停物理帧：判定走直调 _check_victory，不经 _physics_process（未 setup 的
	# 实例进物理帧会在 _director.tick 空引用——既有测试基建缺口，本套件绕开）
	b.set_physics_process(false)
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


func _test_rank_data() -> void:
	var e = EntityScript.new()
	_runner.assert_equal(int(e.get_rank()), 0, "默认军衔 = 士兵（0）")
	e.set_rank(1)
	_runner.assert_equal(int(e.get_rank()), 1, "班长 = 1")
	_runner.assert_equal(e.is_commander(), false, "班长不是指挥官")
	e.set_rank(3)
	_runner.assert_equal(int(e.get_rank()), 3, "指挥官 = 3")
	_runner.assert_equal(e.is_commander(), true, "rank3 是指挥官")
	e.set_rank(9)
	_runner.assert_equal(int(e.get_rank()), 3, "越界上钳到 3")
	e.set_rank(-2)
	_runner.assert_equal(int(e.get_rank()), 0, "越界下钳到 0")
	e.free()


func _test_decapitation_attacker_down() -> void:
	var b := _make_battle(5, 3, 0.0, 0.0)
	var cmd := FakeUnit.new()
	cmd.rank_v = 3
	add_child(cmd)
	b.add_unit(cmd, 1)  # 自动扫描登记为攻方指挥官
	cmd.dead = true
	b._check_victory()
	var summary: Dictionary = b.get_summary()
	_runner.assert_equal(int(summary.get("result", -1)), BattleScript.State.DEFENDER_WIN,
			"攻方指挥官亡 → 守方胜（攻方还有兵也是败）")
	_runner.assert_equal(String(summary.get("reason", "")), "decapitation", "收束原因 = 斩首")
	_runner.assert_equal(int((summary.get("alive", {}) as Dictionary).get(1, -1)), 5,
			"存活快照齐备（斩首路径也有 alive）")


func _test_decapitation_defender_down() -> void:
	var b := _make_battle(3, 5, 0.0, 0.0)
	var cmd := FakeUnit.new()
	cmd.rank_v = 3
	add_child(cmd)
	b.add_unit(cmd, 2)
	cmd.dead = true
	b._check_victory()
	_runner.assert_equal(int(b.get_summary().get("result", -1)), BattleScript.State.ATTACKER_WIN,
			"守方指挥官亡 → 攻方胜")
	_runner.assert_equal(String(b.get_summary().get("reason", "")), "decapitation", "收束原因 = 斩首")


func _test_no_decapitation_when_alive() -> void:
	# 攻方指挥官健在 + 守方全灭 → 既有全灭判定照常（斩首不误触、reason 不串）
	# （指挥官活着本身计存活兵力，"全灭 + 指挥官健在"在语义上不同时成立——
	#   自洽构造 = 对方全灭）
	var b := _make_battle(2, 0, 0.0, 0.0)
	var cmd := FakeUnit.new()
	cmd.rank_v = 3
	add_child(cmd)
	b.add_unit(cmd, 1)  # 攻方指挥官健在
	b._check_victory()
	_runner.assert_equal(int(b.get_summary().get("result", -1)), BattleScript.State.ATTACKER_WIN,
			"指挥官健在 → 全灭判定照常")
	_runner.assert_equal(String(b.get_summary().get("reason", "")), "annihilation", "原因 = 全灭（非斩首）")


func _test_no_commander_regression() -> void:
	# 无指挥官登记：一方全灭 → annihilation（斩首分支恒跳过，既有路径零回归）
	var b := _make_battle(3, 0, 0.0, 0.0)
	b._check_victory()
	_runner.assert_equal(int(b.get_summary().get("result", -1)), BattleScript.State.ATTACKER_WIN,
			"无指挥官: 守方全灭 → 攻方胜")
	_runner.assert_equal(String(b.get_summary().get("reason", "")), "annihilation", "无指挥官: 原因 = 全灭")
	# 无指挥官：双方全灭 → mutual
	var b2 := _make_battle(0, 0, 0.0, 0.0)
	b2._check_victory()
	_runner.assert_equal(String(b2.get_summary().get("reason", "")), "mutual", "无指挥官: 双灭 = mutual")
	# 无指挥官：超时路径照旧
	var b3 := _make_battle(2, 1, 10.0, 20.0)
	b3._check_victory()
	_runner.assert_equal(String(b3.get_summary().get("reason", "")), "timeout", "无指挥官: 超时照旧")


func _test_add_unit_auto_register() -> void:
	var b := _make_battle(2, 2, 0.0, 0.0)
	var cmd := FakeUnit.new()
	cmd.rank_v = 3
	add_child(cmd)
	b.add_unit(cmd, 1)
	_runner.assert_equal(b._is_commander_down(1), false, "登记后活着 → 未倒下")
	cmd.dead = true
	_runner.assert_equal(b._is_commander_down(1), true, "登记单位死亡 → 判倒下")
	# 手动登记口（后设 rank 场景）：覆盖同阵营旧登记
	var cmd2 := FakeUnit.new()
	cmd2.rank_v = 3
	add_child(cmd2)
	b.register_commander(cmd2, 1)
	_runner.assert_equal(b._is_commander_down(1), false, "后到指挥官覆盖登记（战场最高唯一）")
	# 无登记阵营恒 false（不触发斩首）
	_runner.assert_equal(b._is_commander_down(2), false, "无登记阵营不触发斩首")


func _test_commander_order_guard() -> void:
	var e = EntityScript.new()
	e.set_rank(3)
	var ai = AIControllerScript.new()
	ai._entity = e  # 不进树直接注入（_ready cast 等价物，batch 准入：不进场景树）
	ai.set_order("move", {"target": Vector2(100, 0)})
	_runner.assert_equal(ai.has_order(), false, "指挥官拒推进号令（move）")
	ai.set_order("retreat")
	_runner.assert_equal(ai.has_order(), false, "指挥官拒撤离号令（retreat）")
	ai.set_order("seek_cover")
	_runner.assert_equal(ai.has_order(), false, "指挥官拒找掩体号令（seek_cover）")
	ai.set_order("idle")
	_runner.assert_equal(ai.has_order(), true, "指挥官放行坚守号令（idle = HOLD_POSITION）")
	ai.clear_order()
	_runner.assert_equal(ai.has_order(), false, "清令恢复自主")
	e.free()


func _test_soldier_order_unguarded() -> void:
	var e = EntityScript.new()
	e.set_rank(0)
	var ai = AIControllerScript.new()
	ai._entity = e  # 不进树直接注入（_ready cast 等价物，batch 准入：不进场景树）
	ai.set_order("move", {"target": Vector2(100, 0)})
	_runner.assert_equal(ai.has_order(), true, "士兵推进号令照常受理")
	_runner.assert_equal(String(ai.get_ordered_behavior()), "move", "士兵命令行为 = move")
	e.set_rank(1)
	ai.clear_order()
	ai.set_order("move")
	_runner.assert_equal(ai.has_order(), true, "班长（rank1）号令不受指挥官守卫影响")
	e.free()
