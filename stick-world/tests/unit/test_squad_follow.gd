extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：编队动态跟队（SWL MoveInFormationBehindAnotherFormation 直译）。
## FormationSystem.set_squad_follow_squad 锚定校验（自跟/成环/前队不存在）+
## 落点 = 前队质心 − 行进方向 × gap + 死区防抖 + 玩家号令不覆盖 +
## 接战成员不打断 + 前队全灭/解散解除锚定并回收跟队号令。
## 不进场景树（formation._process 不触发，直接调 _decide_squad_targets），确定性。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptFormationSystem := preload("res://modules/combat/scripts/command/formation_system.gd")

var _runner: TestRunner


class FakeOrgApi:
	extends Node
	var _next_id: int = 1

	func create_organization(_org_name: String, _tag: String, _tier: int, _parent_id: String) -> Dictionary:
		var org_id := "org_%d" % _next_id
		_next_id += 1
		return {"ok": true, "data": {"org_id": org_id}}

	func assign_stickman(_org_id: String, _stickman_id: String, _role: String) -> void:
		pass

	func assign_commander(_org_id: String, _stickman_id: String) -> void:
		pass

	func remove_stickman(_org_id: String, _stickman_id: String) -> void:
		pass

	func disband_organization(_org_id: String) -> void:
		pass


class FakeEnemy:
	extends Node2D
	var _dead: bool = false

	func is_dead() -> bool:
		return _dead


## 战斗桩：get_enemies_of + is_active
class FakeBattle:
	extends Node
	var enemies: Array = []

	func get_enemies_of(_faction: int) -> Array:
		return enemies

	func is_active() -> bool:
		return true


## 武器桩：仅射程字段（接战范围判定用；生产 get_weapon 返回 Node2D，桩对齐 Node 系）
class FakeWeapon:
	extends Node2D
	var attack_range: float = 100.0


## AI 控制器桩：记录 set_order/clear_order（号令来源鉴别/计数用；
## 生产 AIController 是 Node，桩对齐避免类型化赋值冲突）
class FakeAI:
	extends Node
	var ordered_behavior: String = ""
	var ordered_params: Dictionary = {}
	var current_behavior: String = ""
	var order_count: int = 0

	func has_order() -> bool:
		return not ordered_behavior.is_empty()

	func get_ordered_behavior() -> String:
		return ordered_behavior

	func get_ordered_params() -> Dictionary:
		return ordered_params

	func get_current_behavior() -> String:
		return current_behavior

	func set_order(behavior_name: String, params: Dictionary = {}) -> void:
		ordered_behavior = behavior_name
		ordered_params = params
		order_count += 1

	func clear_order() -> void:
		ordered_behavior = ""
		ordered_params = {}


## 单位桩：faction + battle + formation + ai + weapon（可选）
class FakeUnit:
	extends Node2D
	var faction_id: int = 1
	var battle: Node = null
	var formation: Node = null
	var ai: Node = null
	var weapon: Node = null
	var _dead: bool = false

	func is_dead() -> bool:
		return _dead

	func get_faction() -> int:
		return faction_id

	func get_battle_instance() -> Node:
		return battle

	func get_formation_system() -> Node:
		return formation

	func get_ai_controller() -> Node:
		return ai

	func get_weapon() -> Node:
		return weapon


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("跟队: 锚定校验（前队不存在/自跟/成环）", _test_anchor_validation)
	_runner.add_test("跟队: 落点 = 前队质心 − 行进方向 × gap（设置即落位）", _test_anchor_point)
	_runner.add_test("跟队: 已持跟队号令时死区内不重复下发（防抖）", _test_deadzone_reissue)
	_runner.add_test("跟队: 前队推进后 tick 重新落位", _test_tick_reissue)
	_runner.add_test("跟队: 跟队号令落点未漂出死区不重复下发", _test_no_repeat_issue)
	_runner.add_test("跟队: 玩家号令不覆盖", _test_player_order_priority)
	_runner.add_test("跟队: 射程内接敌成员不打断", _test_engaged_skip)
	_runner.add_test("跟队: 前队全灭解除锚定并回收跟队号令", _test_front_wiped)
	_runner.add_test("跟队: 前队解散解除锚定", _test_front_disbanded)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _make_fs() -> Node:
	var fs: Node = ScriptFormationSystem.new()
	fs.setup(FakeOrgApi.new())
	return fs


## 造一支 n 人横排小队（y=500），返回 {"sid", "units", "ais"}
func _make_squad(fs: Node, base_x: float, n: int, squad_name: String) -> Dictionary:
	var units: Array = []
	var ais: Array = []
	for i in n:
		var u := FakeUnit.new()
		u.name = "%s%d" % [squad_name, i]
		u.position = Vector2(base_x + i * 40.0, 500)
		u.formation = fs
		var ai := FakeAI.new()
		u.ai = ai
		units.append(u)
		ais.append(ai)
	var sid: String = fs.create_squad(units, squad_name, "fp_combat_squad")
	return {"sid": sid, "units": units, "ais": ais}


func _test_anchor_validation() -> void:
	var fs: Node = _make_fs()
	var front: Dictionary = _make_squad(fs, 600.0, 2, "F")
	var rear: Dictionary = _make_squad(fs, 100.0, 1, "R")
	# 前队不存在
	_runner.assert_false(fs.set_squad_follow_squad(rear["sid"], "ghost_squad", 150.0),
			"前队不存在应失败")
	# 自己跟自己
	_runner.assert_false(fs.set_squad_follow_squad(rear["sid"], rear["sid"], 150.0),
			"自跟应失败")
	# 正常锚定
	_runner.assert_true(fs.set_squad_follow_squad(rear["sid"], front["sid"], 150.0),
			"正常锚定应成功")
	# 成环：A 锚 B（B 已锚 A 的前向链……B 锚的是 front）——rear 已锚 front，
	# 此时让 front 锚 rear 会成环
	_runner.assert_false(fs.set_squad_follow_squad(front["sid"], rear["sid"], 150.0),
			"成环锚定应被拒绝")
	_runner.assert_equal(fs.get_squad_follow(rear["sid"]).get("front", ""), front["sid"],
			"拒绝成环不影响既有锚定")


func _test_anchor_point() -> void:
	var fs: Node = _make_fs()
	var front: Dictionary = _make_squad(fs, 600.0, 2, "F")  # 质心 x=620
	var rear: Dictionary = _make_squad(fs, 100.0, 1, "R")   # x=100
	var ok: bool = fs.set_squad_follow_squad(rear["sid"], front["sid"], 150.0)
	_runner.assert_true(ok, "锚定应成功")
	var ai: FakeAI = rear["ais"][0]
	_runner.assert_true(ai.has_order(), "设置锚定后应立即下发布置号令（不等 tick）")
	if not ai.has_order():
		return
	_runner.assert_equal(ai.ordered_behavior, "move", "落位号令为 move")
	# 前队质心 (620,500)，行进方向 +x，落点 = (620-150, 500) = (470,500)
	var tgt: Vector2 = ai.ordered_params.get("target", Vector2.ZERO)
	_runner.assert_approx(tgt.x, 470.0, 0.5, "落点 x = 前队质心 x − gap")
	_runner.assert_approx(tgt.y, 500.0, 0.5, "落点 y 与前队质心齐平")
	_runner.assert_true(bool(ai.ordered_params.get("engage_in_range", false)),
			"落位号令带接敌即战")
	_runner.assert_true(bool(ai.ordered_params.get("hold_on_arrive", false)),
			"落位号令带到位驻留")
	_runner.assert_true(bool(ai.ordered_params.get("follow_order", false)),
			"落位号令带跟队来源标记")
	var info: Dictionary = fs.get_squad_follow(rear["sid"])
	_runner.assert_equal(info.get("front", ""), front["sid"], "查询锚定前队")
	_runner.assert_approx(float(info.get("gap", 0.0)), 150.0, 0.01, "查询锚定间距")


func _test_deadzone_reissue() -> void:
	var fs: Node = _make_fs()
	var front: Dictionary = _make_squad(fs, 600.0, 2, "F")  # 质心 x=620
	var rear: Dictionary = _make_squad(fs, 100.0, 1, "R")
	fs.set_squad_follow_squad(rear["sid"], front["sid"], 150.0)
	var ai: FakeAI = rear["ais"][0]
	_runner.assert_equal(ai.order_count, 1, "前提：布置号令已下发（落点 x=470）")
	# 前队微移 20（锚点 x=490，距已发落点 20 ≤ 死区 40）→ 不重复下发
	for u in front["units"]:
		u.position.x += 20.0
	fs._decide_squad_targets(0.5)
	_runner.assert_equal(ai.order_count, 1, "落点漂移未出死区不应重复下发")
	# 前队再移 60（锚点 x=550，距已发落点 80 > 死区）→ 重新下发
	for u in front["units"]:
		u.position.x += 60.0
	fs._decide_squad_targets(0.5)
	_runner.assert_equal(ai.order_count, 2, "落点漂移出死区应重新下发")
	if ai.order_count >= 2:
		var tgt: Vector2 = ai.ordered_params.get("target", Vector2.ZERO)
		_runner.assert_approx(tgt.x, 550.0, 0.5, "重下发落点跟随新锚点")


func _test_tick_reissue() -> void:
	var fs: Node = _make_fs()
	var front: Dictionary = _make_squad(fs, 600.0, 2, "F")  # 质心 x=620
	var rear: Dictionary = _make_squad(fs, 480.0, 1, "R")   # 死区内待命
	fs.set_squad_follow_squad(rear["sid"], front["sid"], 150.0)
	# 前队推进 200：质心 x=820 → 锚点 x=670，漂出死区
	for u in front["units"]:
		u.position.x += 200.0
	fs._decide_squad_targets(0.5)
	var ai: FakeAI = rear["ais"][0]
	_runner.assert_true(ai.has_order(), "前队推进漂出死区后 tick 应下发号令")
	if ai.has_order():
		var tgt: Vector2 = ai.ordered_params.get("target", Vector2.ZERO)
		_runner.assert_approx(tgt.x, 670.0, 0.5, "tick 落点跟随前队质心")


func _test_no_repeat_issue() -> void:
	var fs: Node = _make_fs()
	var front: Dictionary = _make_squad(fs, 600.0, 2, "F")
	var rear: Dictionary = _make_squad(fs, 100.0, 1, "R")
	fs.set_squad_follow_squad(rear["sid"], front["sid"], 150.0)
	var ai: FakeAI = rear["ais"][0]
	_runner.assert_equal(ai.order_count, 1, "首次下发布置号令")
	# 原地 tick：锚点未动，落点未漂出死区 → 不重复下发（防 travel 重入重播 arrive）
	fs._decide_squad_targets(0.5)
	fs._decide_squad_targets(0.5)
	_runner.assert_equal(ai.order_count, 1, "锚点未动不应重复下发号令")


func _test_player_order_priority() -> void:
	var fs: Node = _make_fs()
	var front: Dictionary = _make_squad(fs, 600.0, 2, "F")
	var rear: Dictionary = _make_squad(fs, 100.0, 1, "R")
	var ai: FakeAI = rear["ais"][0]
	# 玩家号令（无 follow_order 标记）
	ai.set_order("move", {"target": Vector2(9999, 0)})
	fs.set_squad_follow_squad(rear["sid"], front["sid"], 150.0)
	_runner.assert_equal(ai.ordered_params.get("target", Vector2.ZERO), Vector2(9999, 0),
			"玩家号令不应被锚定落位覆盖")
	_runner.assert_equal(ai.order_count, 1, "玩家号令后不应有新号令")


func _test_engaged_skip() -> void:
	var fs: Node = _make_fs()
	var front: Dictionary = _make_squad(fs, 600.0, 2, "F")
	var rear: Dictionary = _make_squad(fs, 100.0, 1, "R")
	# 后队成员接战中：射程 100 内有敌
	var battle: Node = FakeBattle.new()
	var enemy := FakeEnemy.new()
	enemy.name = "E"
	enemy.position = Vector2(150, 500)  # 距后队成员 50 < 100
	battle.enemies = [enemy]
	var u: FakeUnit = rear["units"][0]
	u.battle = battle
	u.weapon = FakeWeapon.new()
	fs.set_squad_follow_squad(rear["sid"], front["sid"], 150.0)
	var ai: FakeAI = rear["ais"][0]
	_runner.assert_false(ai.has_order(), "接战成员不应被跟队号令打断")


func _test_front_wiped() -> void:
	var fs: Node = _make_fs()
	var front: Dictionary = _make_squad(fs, 600.0, 2, "F")
	var rear: Dictionary = _make_squad(fs, 100.0, 1, "R")
	fs.set_squad_follow_squad(rear["sid"], front["sid"], 150.0)
	var ai: FakeAI = rear["ais"][0]
	_runner.assert_true(ai.has_order(), "前提：跟队号令已下发")
	# 前队全灭
	for u in front["units"]:
		u._dead = true
	fs._decide_squad_targets(0.5)
	_runner.assert_true(fs.get_squad_follow(rear["sid"]).is_empty(), "前队全灭应解除锚定")
	_runner.assert_false(ai.has_order(), "跟队号令应被回收（转自主决策）")


func _test_front_disbanded() -> void:
	var fs: Node = _make_fs()
	var front: Dictionary = _make_squad(fs, 600.0, 2, "F")
	var rear: Dictionary = _make_squad(fs, 100.0, 1, "R")
	fs.set_squad_follow_squad(rear["sid"], front["sid"], 150.0)
	var ai: FakeAI = rear["ais"][0]
	_runner.assert_true(ai.has_order(), "前提：跟队号令已下发")
	fs.disband_squad(front["sid"])
	fs._decide_squad_targets(0.5)
	_runner.assert_true(fs.get_squad_follow(rear["sid"]).is_empty(), "前队解散应解除锚定")
	_runner.assert_false(ai.has_order(), "跟队号令应被回收")
