extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：战线（SWL Team.Attack + MoveInFormation 直译，批5 战线重构）。
## 覆盖：组级方阵槽位（全组一个格子，列高纵向铺满行动带：min(存活, 带宽容列)）/
## 二线驻位（纵深超 LINE_MAX_DEPTH 的排隔 RESERVE_GAP）/ 祭司归远程组 /
## 连续推进与接战停线（滞回复推）/ 远程组动态随行与接战冻结（末列贴射程线）/
## 随线号令（接战跳过、玩家号令不覆盖、line_order 标记）/ FormationSystem
## 战线优先级 / 个性 y 漂移（首漂前恒格点、有界、同种子确定）。
## 确定性：漂移走注入种子（同种子同序列）；不进场景树（tick 直调，节拍 0.5s 对齐）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptFormationSystem := preload("res://modules/formation/scripts/formation_system.gd")
const ScriptBehaviorMove := preload("res://modules/units/scripts/ai/behavior_move.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("组方阵: 12 近战 = 7 宽 × 2 深（带满扩列），槽位/非成员 INF", _test_lattice)
	_runner.add_test("二线驻位: 超 3 排隔 RESERVE_GAP / 动态远程层距 / 祭司归远程组", _test_reserve_and_meric)
	_runner.add_test("推进: ATTACK 连续平移 / 接战停线 / 脱战滞回复推", _test_advance_and_block)
	_runner.add_test("远程组: 随行近战线后 GAP / 接战冻结（末列贴射程线）", _test_ranged_follow_and_freeze)
	_runner.add_test("随线号令: 未接战收令（line_order）/ 接战跳过 / 玩家号令不覆盖", _test_march_orders)
	_runner.add_test("FormationSystem: get_unit_combat_slot 战线优先", _test_combat_slot_priority)
	_runner.add_test("朝向: 战线面向查询 + 到位驻留朝向收口（背对→面向敌阵）", _test_facing)
	_runner.add_test("个性 y 漂移: 首漂前恒格点 + 有界 + 同种子确定", _test_y_drift)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────── 用例 ───────────────────────

func _test_lattice() -> void:
	var w := _make_world(12, 0)
	var line: RefCounted = w["fs"].create_battle_line(1, 1, 1000.0, 0.0, 500.0, 360.0)
	for u in w["units"]:
		line.add_unit(u)
	line.tick(0.0)  # 只跑接战拍（重算槽位），零推进保几何断言确定性
	var upc: int = BattleLine.group_upc(12, 360.0, w["fs"].SPREAD_SPACING)
	_runner.assert_equal(upc, 7, "带宽 720 / 间距 110 → 容 7 列（6×110=660 ≤ 720）")
	var s0: Vector2 = line.get_unit_slot(w["units"][0])
	_runner.assert_approx(s0.x, 0.0, 0.5, "首员前列贴线（col0 → x = line_x）")
	_runner.assert_approx(s0.y, 500.0 - 3.0 * w["fs"].SPREAD_SPACING, 0.5,
			"前列 row0 横展 −3×SPREAD（7 列居中）")
	var s6: Vector2 = line.get_unit_slot(w["units"][6])
	_runner.assert_approx(s6.x, 0.0, 0.5, "第 7 员仍在前列（7 宽铺满带，未到后列）")
	var s7: Vector2 = line.get_unit_slot(w["units"][7])
	_runner.assert_approx(s7.x, -w["fs"].ROW_GAP, 0.5, "第 8 员 = col1（后列退 ROW_GAP）")
	var stranger := Node2D.new()
	_runner.assert_true(is_inf(line.get_unit_slot(stranger).x), "非成员槽位 = INF")
	stranger.free()
	_teardown_world(w)


func _test_reserve_and_meric() -> void:
	# 二线驻位：30 近战 = 7×3 块（21）+ 第 22 员起 col3 = 块尾 + RESERVE_GAP
	var w := _make_world(30, 0)
	var line: RefCounted = w["fs"].create_battle_line(1, 1, 1000.0, 0.0, 500.0, 360.0)
	for u in w["units"]:
		line.add_unit(u)
	line.tick(0.0)
	var s20: Vector2 = line.get_unit_slot(w["units"][20])
	_runner.assert_approx(s20.x, -2.0 * w["fs"].ROW_GAP, 0.5, "第 21 员 = col2（块末排）")
	var s21: Vector2 = line.get_unit_slot(w["units"][21])
	_runner.assert_approx(s21.x, -(2.0 * w["fs"].ROW_GAP + BattleLine.RESERVE_GAP), 0.5,
			"第 22 员 = col3 二线驻位（块尾 + RESERVE_GAP）")
	# 远程随行动态层距：近战全纵深（含二线）+ GROUP_GAP（30 人 = cols 0~4，
	# 二线两排：2×ROW_GAP + RESERVE_GAP + 1×ROW_GAP）
	var melee_depth: float = 3.0 * w["fs"].ROW_GAP + BattleLine.RESERVE_GAP
	_runner.assert_approx(line.ranged_line_x(), line.get_line_x() - melee_depth - BattleLine.GROUP_GAP,
			0.5, "远程线随行 = 近战全纵深 + GROUP_GAP（不叠进二线）")
	# 祭司（wt=5）归远程组：随 CASTERS/ARCHERS/HEALERS 后置层序
	var w2 := _make_world(2, 0)
	var line2: RefCounted = w2["fs"].create_battle_line(1, 1, 1000.0, 0.0, 500.0, 360.0)
	var meric := FakeUnit.new()
	var mw := FakeWeapon.new()
	mw.weapon_type = 5  # MERIC
	meric.weapon = mw
	meric.add_child(mw)
	line2.add_unit(w2["units"][0])  # 剑士 → 近战组
	line2.add_unit(meric)
	line2.tick(0.0)
	_runner.assert_equal(line2.melee_count(), 1, "剑士入近战组")
	_runner.assert_equal(line2.ranged_count(), 1, "祭司入远程组（SWL HEALERS 后置）")
	meric.free()
	_teardown_world(w)
	_teardown_world(w2)


func _test_advance_and_block() -> void:
	var w := _make_world(2, 0)
	var line: RefCounted = w["fs"].create_battle_line(1, 1, 500.0, 0.0, 500.0, 360.0)
	for u in w["units"]:
		line.add_unit(u)
	# 无敌：连续平移（每拍 0.5s × speed 110 = 55px）
	line.tick(0.5)
	var x1: float = line.get_line_x()
	_runner.assert_approx(x1, 55.0, 1.0, "ATTACK 连续推进（首拍 +55）")
	line.tick(0.5)
	_runner.assert_approx(line.get_line_x(), 110.0, 1.0, "持续推进")
	# 敌进首员射程 → 停线
	w["enemy"].global_position = w["units"][0].global_position + Vector2(300.0, 0.0)
	line.tick(0.5)
	var blocked_x: float = line.get_line_x()
	_runner.assert_true(line.is_melee_blocked(), "接战即停线")
	line.tick(0.5)
	line.tick(0.5)
	_runner.assert_approx(line.get_line_x(), blocked_x, 0.5, "停线期间不推进")
	# 敌撤出射程 → 滞回（2 拍）后复推
	w["enemy"].global_position = Vector2(9000.0, 500.0)
	line.tick(0.5)
	_runner.assert_true(line.is_melee_blocked(), "滞回第 1 拍仍停（防目标切换抖动）")
	line.tick(0.5)
	_runner.assert_false(line.is_melee_blocked(), "滞回满 2 拍复推")
	_runner.assert_true(line.get_line_x() > blocked_x, "复推后战线前移")
	_teardown_world(w)


func _test_ranged_follow_and_freeze() -> void:
	var w := _make_world(8, 0, true)  # 8 弓手（upc 7 → 2 列，纵深 1×ROW_GAP）
	var line: RefCounted = w["fs"].create_battle_line(1, 1, 1000.0, 0.0, 500.0, 360.0)
	for u in w["units"]:
		line.add_unit(u)
	line.tick(0.5)
	# 随行：远程前列线 = 近战线 − GROUP_GAP（无近战成员时近战线照常推进）
	_runner.assert_approx(line.ranged_line_x(), line.get_line_x() - 260.0, 1.0,
			"未接战远程组随行近战线后 GROUP_GAP")
	# 敌进远程射程 → 冻结：冻结线 = 最前成员 x + 方阵纵深（末列贴射程线）
	var front_x: float = 0.0
	for u in w["units"]:
		front_x = maxf(front_x, u.global_position.x)
	w["enemy"].global_position = Vector2(front_x + 600.0, 500.0)
	line.tick(0.5)
	var frozen: float = line.ranged_line_x()
	_runner.assert_false(is_nan(line.get("frozen_ranged_x")), "接战即冻结远程线")
	_runner.assert_approx(frozen, front_x + w["fs"].ROW_GAP, 0.5,
			"冻结线 = 最前成员 + 方阵纵深（末列贴射程线）")
	_teardown_world(w)


func _test_march_orders() -> void:
	var w := _make_world(3, -400.0)  # 成员远在线后 → 必收随线号令
	var line: RefCounted = w["fs"].create_battle_line(1, 1, 1000.0, 0.0, 500.0, 360.0)
	for u in w["units"]:
		line.add_unit(u)
	line.tick(0.0)  # 只跑接战拍（下号令），零推进保号令目标断言确定性
	var u0_ai = w["units"][0].ai
	_runner.assert_true(u0_ai.orders.size() > 0, "未接战成员收到随线号令")
	if u0_ai.orders.size() > 0:
		var last: Dictionary = u0_ai.orders[u0_ai.orders.size() - 1]
		_runner.assert_equal(last["behavior"], "move", "随线号令 = move")
		_runner.assert_true(last["params"].get("line_order", false), "带 line_order 标记")
		_runner.assert_true(last["params"].get("engage_in_range", false),
				"敌进射程即交还战斗（engage_in_range）")
		_runner.assert_approx((last["params"]["target"] as Vector2).x,
				line.get_unit_slot(w["units"][0]).x, 0.5, "号令目标 = 自身槽位")
	# 接战成员跳过（敌进射程）
	w["units"][1].ai.orders.clear()
	w["enemy"].global_position = w["units"][1].global_position + Vector2(300.0, 0.0)
	line.tick(0.5)
	_runner.assert_equal(w["units"][1].ai.orders.size(), 0, "接战成员不收随线号令（战斗行为接管）")
	# 玩家号令不覆盖（敌撤远 = 无人接战，仅玩家号令挡）
	w["enemy"].global_position = Vector2(9000.0, 500.0)
	var u2_ai = w["units"][2].ai
	u2_ai.set_order("idle", {"target": Vector2(7777.0, 0.0)})
	u2_ai.orders.clear()
	# 对照组清令（u0 旧线令目标恰=当前槽位会被去重正确跳过——非本断言对象）
	u0_ai.clear_order()
	u0_ai.orders.clear()
	line.tick(0.5)
	_runner.assert_true(u0_ai.orders.size() > 0, "对照：无令成员照常收随线号令")
	_runner.assert_equal(u2_ai.orders.size(), 0, "玩家号令不被战线覆盖")
	_teardown_world(w)


func _test_combat_slot_priority() -> void:
	var w := _make_world(2, 0)
	var fs: Node = w["fs"]
	var line: RefCounted = fs.create_battle_line(1, 1, 1000.0, 0.0, 500.0, 360.0)
	for u in w["units"]:
		line.add_unit(u)
	line.tick(0.5)
	# 战线优先：get_unit_combat_slot = 战线槽位（无班无锚时本应 INF）
	var combat: Vector2 = fs.get_unit_combat_slot(w["units"][0])
	_runner.assert_false(is_inf(combat.x), "有战线时 combat_slot 有效")
	_runner.assert_approx(combat.x, line.get_unit_slot(w["units"][0]).x, 0.5,
			"combat_slot = 战线槽位（组级优先于班锚）")
	_runner.assert_approx(fs.get_unit_line_slot(w["units"][0]).x, combat.x, 0.5,
			"get_unit_line_slot 同源")
	_teardown_world(w)


func _test_facing() -> void:
	var w := _make_world(1, 0)
	var line: RefCounted = w["fs"].create_battle_line(1, 1, 1000.0, 0.0, 500.0, 360.0)
	line.add_unit(w["units"][0])
	line.tick(0.0)
	_runner.assert_equal(w["fs"].get_unit_face_dir(w["units"][0]), 1,
			"战线成员面向 = 线面向（+1）")
	var stranger := Node2D.new()
	_runner.assert_equal(w["fs"].get_unit_face_dir(stranger), 0,
			"无查询面单位 = 0 不干预")
	stranger.free()
	# 到位驻留（hold_on_arrive）：背对敌阵到达 → 驻留分支收口面向敌阵
	#（倒退/横移归位的移动残影朝向是「有人不面对战线」的根因）
	var mover := _MoveStub.new()
	mover.fs = w["fs"]
	mover.facing = -1
	mover.global_position = Vector2(5.0, 500.0)
	var move = ScriptBehaviorMove.new()
	move.entity = mover
	move.enter("", {"target": Vector2(5.0, 500.0), "hold_on_arrive": true})
	move.update(0.016)  # 到达 → _arrived
	move.update(0.016)  # 驻留分支 → face_battle_dir
	_runner.assert_equal(mover.facing, 1, "驻留站定背对战线 → 收口面向敌阵")
	move.free()
	mover.free()
	_teardown_world(w)


func _test_y_drift() -> void:
	# 个性 y 漂移（SWL Ai.personalityControlledY / personalityNextYControlShift 直译，
	# 02 二-A.5）：短局（< 首漂间隔 3s）槽位 y 恒格点（既有几何断言稳定）；
	# 长局漂移有界（±spread×0.25，同列最坏间距不触分离半径）；同种子两条线
	# 漂移序列逐成员一致（确定性：字典按入线序迭代，掷骰序确定）。
	var w1 := _make_world(8, 0)
	var line_a: RefCounted = w1["fs"].create_battle_line(1, 1, 100000.0, 0.0, 500.0, 360.0)
	line_a.seed_drift(424242)
	for u in w1["units"]:
		line_a.add_unit(u)
	var w2 := _make_world(8, 0)
	var line_b: RefCounted = w2["fs"].create_battle_line(1, 1, 100000.0, 0.0, 500.0, 360.0)
	line_b.seed_drift(424242)
	for u in w2["units"]:
		line_b.add_unit(u)
	# 短局：3s 内（首漂最早 DRIFT_SHIFT_MIN=3s 后）漂移恒零（两线同拍推进，
	# 保持 RNG 消费序列一致——确定性断言的前提）
	for i in 5:
		line_a.tick(0.5)
		line_b.tick(0.5)
	var upc: int = BattleLine.group_upc(8, 360.0, w1["fs"].SPREAD_SPACING)
	var s0: Vector2 = line_a.get_unit_slot(w1["units"][0])
	_runner.assert_approx(s0.y, 500.0 - 3.0 * w1["fs"].SPREAD_SPACING, 0.5,
			"首漂前槽位 y = 格点（漂移零，7 列居中）")
	# 长局：20s 漂移激活——有界 + 同种子孪生线逐成员一致
	for i in 35:
		line_a.tick(0.5)
		line_b.tick(0.5)
	var limit: float = w1["fs"].SPREAD_SPACING * 0.25 + 0.01
	for i in w1["units"].size():
		var ya: float = line_a.get_unit_slot(w1["units"][i]).y
		var yb: float = line_b.get_unit_slot(w2["units"][i]).y
		var base: float = 500.0 + (float(i % upc) - float(upc - 1) * 0.5) * w1["fs"].SPREAD_SPACING
		_runner.assert_true(absf(ya - base) <= limit,
				"漂移有界：成员 %d 偏差 %.1f ≤ %.1f" % [i, ya - base, limit])
		_runner.assert_approx(ya, yb, 0.01, "同种子漂移确定：成员 %d 两条线一致" % i)
	_teardown_world(w1)
	_teardown_world(w2)


# ─────────────────────── 夹具 ───────────────────────

## 假组织 API（复刻 test_formation_slots 的 FakeOrgApi）
class FakeOrgApi extends Node:
	var _next_id: int = 1

	func create_organization(_n: String, _t: String, _ti: int, _p: String) -> Dictionary:
		_next_id += 1
		return {"ok": true, "data": {"org_id": "o%d" % _next_id}}

	func assign_stickman(_a: String, _b: String, _c: String) -> void: pass
	func assign_commander(_a: String, _b: String) -> void: pass
	func remove_stickman(_a: String, _b: String) -> void: pass
	func disband_organization(_a: String) -> void: pass


class FakeBattle extends Node:
	var enemies: Array = []

	func is_active() -> bool:
		return true

	func get_enemies_of(_faction: int) -> Array:
		return enemies


class FakeEnemy extends Node2D:
	func is_dead() -> bool:
		return false

	func get_faction() -> int:
		return 2


## 记录 AI 桩（随线号令记录面）
class FakeAI extends Node:
	var orders: Array = []
	var _ordered_behavior: String = ""
	var _ordered_params: Dictionary = {}

	func set_order(b: String, p: Dictionary = {}) -> void:
		orders.append({"behavior": b, "params": p.duplicate()})
		_ordered_behavior = b
		_ordered_params = p.duplicate()

	func has_order() -> bool:
		return not _ordered_behavior.is_empty()

	func clear_order() -> void:
		_ordered_behavior = ""
		_ordered_params = {}

	func get_current_behavior() -> String:
		return "idle"

	func get_ordered_behavior() -> String:
		return _ordered_behavior

	func get_ordered_params() -> Dictionary:
		return _ordered_params


## 成员桩：近战（剑）或远程（弓，ranged=true），带战斗/武器/AI 查询面
class FakeUnit extends Node2D:
	var faction: int = 1
	var battle: FakeBattle = null
	var weapon: Node = null
	var ai: FakeAI = null

	func is_dead() -> bool:
		return false

	func get_ai_controller() -> Node:
		return ai

	func get_faction() -> int:
		return faction

	func get_battle_instance() -> Node:
		return battle

	func get_weapon() -> Node:
		return weapon


class FakeWeapon extends Node:
	var weapon_type: int = 0
	var attack_range: float = 650.0


## move 行为桩：faction 1 + 编队系统引用 + 可读写 facing（驻留朝向收口用）
class _MoveStub extends CharacterBody2D:
	var fs: Node = null
	var facing: int = -1
	var faction: int = 1

	func get_formation_system() -> Node:
		return fs

	func get_faction() -> int:
		return faction

	func get_facing() -> int:
		return facing

	func try_set_facing(dir: int) -> bool:
		facing = dir
		return true

	func ai_stop() -> void:
		pass


## 世界夹具：fs + n 个成员（剑/弓按 ranged）+ 远敌（默认不在任何射程内）
class _World extends RefCounted:
	var fs: Node = null
	var org: Node = null
	var battle: FakeBattle = null
	var enemy: FakeEnemy = null
	var units: Array = []

	func _init(n: int, x0: float, ranged: bool) -> void:
		fs = ScriptFormationSystem.new()
		org = FakeOrgApi.new()
		fs.setup(org)
		battle = FakeBattle.new()
		enemy = FakeEnemy.new()
		enemy.global_position = Vector2(9000.0, 500.0)
		battle.enemies.append(enemy)
		for i in n:
			var u := FakeUnit.new()
			u.name = "U%d" % i
			u.global_position = Vector2(x0, 500.0 + (float(i) - float(n - 1) * 0.5) * 130.0)
			var w := FakeWeapon.new()
			w.weapon_type = 2 if ranged else 0  # BOW / SWORD
			u.weapon = w
			u.add_child(w)
			u.battle = battle
			var a := FakeAI.new()
			u.ai = a
			u.add_child(a)
			units.append(u)

	func teardown() -> void:
		fs.free()
		org.free()
		battle.free()
		for u in units:
			u.free()


func _make_world(n: int, x0: float = 0.0, ranged: bool = false) -> _World:
	return _World.new(n, x0, ranged)


func _teardown_world(w: _World) -> void:
	w.teardown()
