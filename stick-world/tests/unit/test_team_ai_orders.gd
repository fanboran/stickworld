extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：TeamAi 号令映射与手动号令保护期（P6 · 6.2）。
## 覆盖：三姿态→号令类型映射/目标点/预过滤/保护期/tier 语义。
## 不进场景树，确定性（FakeOrders/FakeFormation 记录调用；EventBus 被动订阅）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptTeamAi := preload("res://modules/combat/scripts/battle/team_ai.gd")
const ScriptTeamAiProfiles := preload("res://modules/combat/scripts/battle/team_ai_profiles.gd")
const ScriptTacticalOrders := preload("res://modules/combat/scripts/command/tactical_orders.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("ATTACK → ADVANCE_ALL 敌质心", _test_order_attack)
	_runner.add_test("DEFEND → ADVANCE_ALL 本方质心", _test_order_defend)
	_runner.add_test("GARRISON → RALLY 锚点", _test_order_garrison)
	_runner.add_test("非本阵营小队不发号令", _test_order_filter_faction)
	_runner.add_test("非战斗小队不发号令", _test_order_filter_noncombat)
	_runner.add_test("空队不发号令", _test_order_filter_empty)
	_runner.add_test("手动号令保护期避让", _test_order_manual_guard)
	_runner.add_test("保护期过期后恢复发令", _test_order_manual_expire)
	_runner.add_test("tier=1 AI 号令语义", _test_order_tier)
	_runner.add_test("orders=null 不崩", _test_order_null_orders)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────────────── 测试用例 ────────────────────────────────

func _test_order_attack() -> void:
	var ctx := _Ctx.new()
	ctx.setup()
	ctx.add_own_unit(Vector2(500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(520, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(540, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(1500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_squad("s1", 1)  # 本阵营战斗小队
	ctx.battle.duration = 15.0  # 门禁过
	ctx.ai.update()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_ATTACK, "应切 ATTACK")
	var calls := ctx.orders.calls
	_runner.assert_true(calls.size() > 0, "应下发号令")
	if calls.size() > 0:
		_runner.assert_equal(calls[0]["order_type"], ScriptTacticalOrders.OrderType.ADVANCE_ALL, "ADVANCE_ALL")
		_runner.assert_equal(calls[0]["squad_id"], "s1", "目标小队 s1")
		_runner.assert_equal(calls[0]["source_tier"], 1, "AI tier=1")
		# 目标点 = 敌方质心 (1500, 300)
		_runner.assert_approx(calls[0]["target"].x, 1500.0, 1.0, "目标 x=敌质心 1500")
		_runner.assert_approx(calls[0]["target"].y, 300.0, 1.0, "目标 y=敌质心 300")
	ctx.teardown()


func _test_order_defend() -> void:
	var ctx := _Ctx.new()
	ctx.setup()
	# 力量劣势维持 DEFEND：本方 1 vs 敌方 3
	ctx.add_own_unit(Vector2(500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(1500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(1520, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(1540, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_squad("s1", 1)
	ctx.battle.duration = 15.0
	ctx.ai.update()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_DEFEND, "维持 DEFEND")
	# 加本方力量切 ATTACK：本方 4 SPEAR(str=8) vs 敌方 3 SPEAR(str=6) → ratio=1.33 >= 1.30
	ctx.add_own_unit(Vector2(560, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(580, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(600, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.battle.duration = 20.0  # 冷却过
	ctx.ai.update()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_ATTACK, "切 ATTACK")
	ctx.orders.calls.clear()
	# 回落 DEFEND：杀 3 本方 → 剩 1 SPEAR(str=2) vs 3 SPEAR(str=6) → ratio=0.33 <= 1.10
	ctx.kill_own_units(3)
	ctx.battle.duration = 25.0
	ctx.ai.update()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_DEFEND, "回落 DEFEND")
	var calls := ctx.orders.calls
	_runner.assert_true(calls.size() > 0, "DEFEND 切换应下发号令")
	if calls.size() > 0:
		_runner.assert_equal(calls[0]["order_type"], ScriptTacticalOrders.OrderType.ADVANCE_ALL, "ADVANCE_ALL")
		# 目标点 = 本方质心 (600, 300)（kill 前 3 个后剩第 4 个在 600）
		_runner.assert_approx(calls[0]["target"].x, 600.0, 1.0, "目标 x=本方质心 600")
	ctx.teardown()


func _test_order_garrison() -> void:
	var ctx := _Ctx.new()
	ctx.setup()
	ctx.add_own_unit(Vector2(500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(800, 300), ScriptTeamAiProfiles.SPEAR)  # 敌近
	ctx.add_squad("s1", 1)
	ctx.battle.duration = 15.0
	ctx.ai.update()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_GARRISON, "应 GARRISON")
	var calls := ctx.orders.calls
	_runner.assert_true(calls.size() > 0, "应下发号令")
	if calls.size() > 0:
		_runner.assert_equal(calls[0]["order_type"], ScriptTacticalOrders.OrderType.RALLY, "RALLY")
		# 目标点 = 本方锚点 (500, 300)
		_runner.assert_approx(calls[0]["target"].x, 500.0, 1.0, "目标 x=锚点 500")
		_runner.assert_approx(calls[0]["target"].y, 300.0, 1.0, "目标 y=锚点 300")
	ctx.teardown()


func _test_order_filter_faction() -> void:
	var ctx := _Ctx.new()
	ctx.setup()
	ctx.add_own_unit(Vector2(500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(520, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(540, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(1500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_squad("s_own", 1)  # 本阵营
	ctx.add_squad("s_enemy", 2)  # 敌阵营
	ctx.battle.duration = 15.0
	ctx.ai.update()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_ATTACK, "应切 ATTACK")
	var issued_squads: Array = []
	for c in ctx.orders.calls:
		issued_squads.append(c["squad_id"])
	_runner.assert_true(issued_squads.has("s_own"), "本阵营小队应收号令")
	_runner.assert_false(issued_squads.has("s_enemy"), "敌阵营小队不应收号令")
	ctx.teardown()


func _test_order_filter_noncombat() -> void:
	var ctx := _Ctx.new()
	ctx.setup()
	ctx.add_own_unit(Vector2(500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(520, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(540, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(1500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_squad("s_combat", 1, true)
	ctx.add_squad("s_noncombat", 1, false)  # 非战斗小队
	ctx.battle.duration = 15.0
	ctx.ai.update()
	var issued_squads: Array = []
	for c in ctx.orders.calls:
		issued_squads.append(c["squad_id"])
	_runner.assert_true(issued_squads.has("s_combat"), "战斗小队应收号令")
	_runner.assert_false(issued_squads.has("s_noncombat"), "非战斗小队不应收号令")
	ctx.teardown()


func _test_order_filter_empty() -> void:
	var ctx := _Ctx.new()
	ctx.setup()
	ctx.add_own_unit(Vector2(500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(520, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(540, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(1500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_squad("s_with_units", 1, true, 3)  # 有 3 个本阵营成员
	ctx.add_squad("s_empty", 1, true, 0)  # 空队
	ctx.battle.duration = 15.0
	ctx.ai.update()
	var issued_squads: Array = []
	for c in ctx.orders.calls:
		issued_squads.append(c["squad_id"])
	_runner.assert_true(issued_squads.has("s_with_units"), "有成员小队应收号令")
	_runner.assert_false(issued_squads.has("s_empty"), "空队不应收号令")
	ctx.teardown()


func _test_order_manual_guard() -> void:
	var ctx := _Ctx.new()
	ctx.setup()
	ctx.add_own_unit(Vector2(500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(520, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(540, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(1500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_squad("s1", 1)
	ctx.battle.duration = 15.0
	ctx.ai.update()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_ATTACK, "先切 ATTACK")
	# 玩家手动号令（tier=0）触发保护期
	EventBus.order_issued.emit(ScriptTacticalOrders.OrderType.HOLD_POSITION, "s1", 0)
	ctx.orders.calls.clear()
	# 力量反转触发姿态切换，但 s1 在保护期内应避让
	ctx.kill_own_units(2)
	ctx.add_enemy_unit(Vector2(1520, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(1540, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.battle.duration = 20.0  # 冷却过
	ctx.ai.update()
	var issued_squads: Array = []
	for c in ctx.orders.calls:
		issued_squads.append(c["squad_id"])
	_runner.assert_false(issued_squads.has("s1"), "保护期内 s1 不应收姿态号令")
	ctx.teardown()


func _test_order_manual_expire() -> void:
	var ctx := _Ctx.new()
	ctx.setup()
	ctx.add_own_unit(Vector2(500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(520, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(540, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(1500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_squad("s1", 1)
	ctx.battle.duration = 15.0
	ctx.ai.update()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_ATTACK, "先切 ATTACK")
	# 手动号令保护期 8s
	EventBus.order_issued.emit(ScriptTacticalOrders.OrderType.HOLD_POSITION, "s1", 0)
	# 保护期过期后（duration 推进 > 8s）
	ctx.kill_own_units(2)
	ctx.add_enemy_unit(Vector2(1520, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(1540, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.orders.calls.clear()
	ctx.battle.duration = 30.0  # 距手动号令 15s > 8s 保护期；距姿态切换 15s > 5s 冷却
	ctx.ai.update()
	var issued_squads: Array = []
	for c in ctx.orders.calls:
		issued_squads.append(c["squad_id"])
	_runner.assert_true(issued_squads.has("s1"), "保护期过期后 s1 应收姿态号令")
	ctx.teardown()


func _test_order_tier() -> void:
	var ctx := _Ctx.new()
	ctx.setup()
	ctx.add_own_unit(Vector2(500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(520, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(540, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(1500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_squad("s1", 1)
	ctx.battle.duration = 15.0
	ctx.ai.update()
	var has_ai_tier: bool = false
	for c in ctx.orders.calls:
		if c["source_tier"] == 1:
			has_ai_tier = true
	_runner.assert_true(has_ai_tier, "AI 号令 source_tier 应为 1")
	ctx.teardown()


func _test_order_null_orders() -> void:
	var ctx := _Ctx.new()
	ctx.setup_with_orders(null)
	ctx.add_own_unit(Vector2(500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(520, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(540, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(1500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.battle.duration = 15.0
	# 不应崩溃（orders=null 时号令跳过，姿态决策照跑）
	ctx.ai.update()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_ATTACK, "orders=null 姿态决策照跑")
	ctx.teardown()


# ─────────────────────────────── Mock 夹具 ────────────────────────────────

class _Ctx:
	var battle: _FakeBattle
	var orders: _FakeOrders
	var formation: _FakeFormation
	var ai: TeamAi

	func setup() -> void:
		battle = _FakeBattle.new()
		orders = _FakeOrders.new()
		formation = _FakeFormation.new()
		ai = ScriptTeamAi.new()
		ai.setup(battle, 1, orders, formation, {})

	func setup_with_orders(o: Node) -> void:
		battle = _FakeBattle.new()
		orders = _FakeOrders.new()
		formation = _FakeFormation.new()
		ai = ScriptTeamAi.new()
		ai.setup(battle, 1, o, formation, {})

	func teardown() -> void:
		if ai != null:
			ai.dispose()
		if battle != null:
			battle.queue_free()
		if orders != null:
			orders.queue_free()
		if formation != null:
			formation.queue_free()

	func add_own_unit(pos: Vector2, wtype: int) -> void:
		battle.add_unit(pos, 1, wtype)

	func add_enemy_unit(pos: Vector2, wtype: int) -> void:
		battle.add_unit(pos, 2, wtype)

	func kill_own_units(n: int) -> void:
		battle.kill_units(1, n)

	func add_squad(squad_id: String, faction: int, is_combat: bool = true, unit_count: int = 3) -> void:
		formation.add_squad(squad_id, faction, is_combat, unit_count)


class _FakeBattle extends Node:
	var duration: float = 0.0
	var _units: Array = []
	var _anchor_faction1 := Vector2(500, 300)
	var _anchor_faction2 := Vector2(1500, 300)

	func add_unit(pos: Vector2, faction: int, wtype: int) -> void:
		var u := _FakeUnit.new()
		u.global_position = pos
		u.faction = faction
		u.weapon_type = wtype
		u.dead = false
		_units.append(u)

	func kill_units(faction: int, n: int) -> void:
		var killed: int = 0
		for u in _units:
			if u.faction == faction and not u.dead:
				u.dead = true
				killed += 1
				if killed >= n:
					break

	func get_allies_of(faction: int) -> Array:
		return _units.filter(func(u) -> bool: return u.faction == faction)

	func get_enemies_of(faction: int) -> Array:
		return _units.filter(func(u) -> bool: return u.faction != faction)

	func get_duration() -> float:
		return duration

	func is_active() -> bool:
		return true

	func get_battle_id() -> String:
		return "test_battle"

	func get_faction_side_anchor(faction: int) -> Vector2:
		return _anchor_faction1 if faction == 1 else _anchor_faction2


class _FakeOrders extends Node:
	var calls: Array = []

	func issue(order_type: int, squad_id: String, target_pos: Vector2, source_tier: int) -> bool:
		calls.append({
			"order_type": order_type,
			"squad_id": squad_id,
			"target": target_pos,
			"source_tier": source_tier,
		})
		return true


class _FakeFormation extends Node:
	var _squads: Dictionary = {}  # squad_id -> {faction, is_combat, units}

	func add_squad(squad_id: String, faction: int, is_combat: bool, unit_count: int) -> void:
		var units: Array = []
		for i in unit_count:
			var u := _FakeUnit.new()
			u.faction = faction
			u.weapon_type = ScriptTeamAiProfiles.SPEAR
			u.dead = false
			units.append(u)
		_squads[squad_id] = {
			"faction": faction,
			"is_combat": is_combat,
			"units": units,
		}

	func get_all_squads() -> Array:
		return _squads.keys()

	func get_squad_units(squad_id: String) -> Array:
		if not _squads.has(squad_id):
			return []
		return _squads[squad_id]["units"]

	func is_combat_squad(squad_id: String) -> bool:
		if not _squads.has(squad_id):
			return false
		return _squads[squad_id]["is_combat"]


class _FakeUnit extends Node2D:
	var faction: int = 0
	var weapon_type: int = 0
	var dead: bool = false

	func is_dead() -> bool:
		return dead

	func get_faction() -> int:
		return faction

	func get_weapon() -> Node:
		return self