extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：TeamAi 姿态机决策（P6 · 6.1）。
## 覆盖：三态迁移/滞回带/切换冷却/开局门禁/驻守触发集/力量比值口径/桩函数/比较器。
## 不进场景树，确定性（FakeBattle 时钟可控；EventBus 被动订阅不触发）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptTeamAi := preload("res://modules/combat/scripts/battle/team_ai.gd")
const ScriptTeamAiProfiles := preload("res://modules/combat/scripts/battle/team_ai_profiles.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("初始姿态 = DEFEND", _test_initial_stance)
	_runner.add_test("力量占优 + 门禁过 → ATTACK", _test_ratio_attack_enter)
	_runner.add_test("ATTACK 回落 → DEFEND（滞回带）", _test_ratio_attack_exit)
	_runner.add_test("力量劣势 → DEFEND", _test_ratio_defend_enter)
	_runner.add_test("敌近 + 无防守者 → GARRISON", _test_garrison_no_defenders)
	_runner.add_test("敌军近 → GARRISON（enemy_army_is_close）", _test_garrison_enemy_close)
	_runner.add_test("姿态切换冷却内不切换", _test_stance_cooldown)
	_runner.add_test("开局门禁内不切 ATTACK", _test_attack_gate)
	_runner.add_test("桩函数恒假（barricade/statue/desperation）", _test_stubs_false)
	_runner.add_test("compare_unit_types 优先序", _test_compare_unit_types)
	_runner.add_test("balance_of_powers / ratio 计算", _test_balance_calc)
	_runner.add_test("enemy_has_no_military_units", _test_enemy_no_military)
	_runner.add_test("we_recently_decided_to_garrison 防抖", _test_garrison_recent)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────────────── 测试用例 ────────────────────────────────

func _test_initial_stance() -> void:
	var ctx := _Ctx.new()
	ctx.setup()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_DEFEND, "初始 DEFEND")
	ctx.teardown()


func _test_ratio_attack_enter() -> void:
	var ctx := _Ctx.new()
	ctx.setup()
	# 本方 3 SPEAR(str=6) vs 敌方 1 SPEAR(str=2) → ratio=3.0 >= 1.30
	ctx.add_own_unit(Vector2(500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(520, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(540, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(1500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.battle.duration = 15.0  # 门禁过（seconds_before_attack=10）；冷却初始 -1e9 已过
	ctx.ai.update()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_ATTACK, "ratio=3.0 应切 ATTACK")
	ctx.teardown()


func _test_ratio_attack_exit() -> void:
	var ctx := _Ctx.new()
	ctx.setup()
	# 先切 ATTACK：本方 3 SPEAR vs 敌方 1 SPEAR → ratio=3.0
	ctx.add_own_unit(Vector2(500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(520, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(540, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(1500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.battle.duration = 15.0
	ctx.ai.update()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_ATTACK, "先切 ATTACK")
	# 回落：本方死剩 1 SPEAR(str=2) vs 敌方 2 SPEAR(str=4) → ratio=0.5 <= 1.10
	ctx.kill_own_units(2)
	ctx.add_enemy_unit(Vector2(1520, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.battle.duration = 20.0  # 距上次切换 5s，冷却过
	ctx.ai.update()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_DEFEND, "ratio=0.5 应回落 DEFEND")
	ctx.teardown()


func _test_ratio_defend_enter() -> void:
	var ctx := _Ctx.new()
	ctx.setup()
	# 本方 1 SPEAR(str=2) vs 敌方 3 SPEAR(str=6) → ratio=0.33 <= 0.85
	ctx.add_own_unit(Vector2(500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(1500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(1520, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(1540, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.battle.duration = 15.0
	ctx.ai.update()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_DEFEND, "ratio=0.33 维持 DEFEND")
	ctx.teardown()


func _test_garrison_no_defenders() -> void:
	var ctx := _Ctx.new()
	ctx.setup()
	# 先建立初始力量基线：本方 3 SPEAR(str=6)
	ctx.add_own_unit(Vector2(500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(520, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(540, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(1500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.battle.duration = 15.0
	ctx.ai.update()  # 登记初始基线 6.0；ratio=3.0 切 ATTACK
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_ATTACK, "先切 ATTACK")
	# 本方死剩 1 SPEAR(str=2)，比例 2/6=0.33 < 0.35(no_defender_floor) ∧ 敌近(<900)
	ctx.kill_own_units(2)
	ctx.clear_enemy_units()
	ctx.add_enemy_unit(Vector2(700, 300), ScriptTeamAiProfiles.SPEAR)  # 距锚点 200 < 900
	ctx.battle.duration = 20.0  # 距上次切换 5s，冷却过
	ctx.ai.update()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_GARRISON, "无防守者+敌近应 GARRISON")
	ctx.teardown()


func _test_garrison_enemy_close() -> void:
	var ctx := _Ctx.new()
	ctx.setup()
	# 敌军质心距本方锚点 < enemy_close_dist(900) → enemy_army_is_close_to_us 真
	ctx.add_own_unit(Vector2(500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(800, 300), ScriptTeamAiProfiles.SPEAR)  # 距锚点 300 < 900
	ctx.battle.duration = 15.0
	ctx.ai.update()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_GARRISON, "敌近应 GARRISON")
	ctx.teardown()


func _test_stance_cooldown() -> void:
	var ctx := _Ctx.new()
	ctx.setup()
	ctx.add_own_unit(Vector2(500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(520, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(540, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(1500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.battle.duration = 15.0
	ctx.ai.update()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_ATTACK, "先切 ATTACK")
	# 冷却内（duration 仅 +1，cooldown=5）：力量反转也不切换
	ctx.kill_own_units(2)
	ctx.add_enemy_unit(Vector2(1520, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(1540, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.battle.duration = 16.0  # 距上次切换 1s < 5s 冷却
	ctx.ai.update()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_ATTACK, "冷却内维持 ATTACK")
	ctx.teardown()


func _test_attack_gate() -> void:
	var ctx := _Ctx.new()
	ctx.setup()
	# 力量占优但门禁未过（duration=5 < seconds_before_attack=10）
	ctx.add_own_unit(Vector2(500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(520, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(540, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(1500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.battle.duration = 5.0  # 门禁未过
	ctx.ai.update()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_DEFEND, "门禁内维持 DEFEND")
	ctx.teardown()


func _test_stubs_false() -> void:
	var ctx := _Ctx.new()
	ctx.setup()
	_runner.assert_false(ctx.ai.barricade_exists(), "barricade_exists 桩恒假")
	_runner.assert_false(ctx.ai.statue_is_low_health(), "statue_is_low_health 桩恒假")
	_runner.assert_false(ctx.ai.has_desperation_group_that_spawned(), "desperation 桩恒假")
	_runner.assert_false(ctx.ai.team_has_a_giant(), "P8 前无巨人恒假")
	ctx.teardown()


func _test_compare_unit_types() -> void:
	var ctx := _Ctx.new()
	ctx.setup()
	var p := ScriptTeamAiProfiles
	# 优先序 [GIANT, STAFF, SPEAR, BOW, SWORD]
	_runner.assert_equal(ctx.ai.compare_unit_types(p.GIANT, p.SWORD), -1, "GIANT 优先于 SWORD")
	_runner.assert_equal(ctx.ai.compare_unit_types(p.SWORD, p.GIANT), 1, "SWORD 劣于 GIANT")
	_runner.assert_equal(ctx.ai.compare_unit_types(p.SPEAR, p.SPEAR), 0, "同级 0")
	_runner.assert_equal(ctx.ai.compare_unit_types(p.STAFF, p.SPEAR), -1, "STAFF 优先于 SPEAR")
	_runner.assert_equal(ctx.ai.compare_unit_types(p.BOW, p.SWORD), -1, "BOW 优先于 SWORD")
	ctx.teardown()


func _test_balance_calc() -> void:
	var ctx := _Ctx.new()
	ctx.setup()
	# 本方 1 SPEAR(str=2) + 1 SWORD(str=1) = 3；敌方 1 BOW(str=1.5) = 1.5
	ctx.add_own_unit(Vector2(500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(520, 300), ScriptTeamAiProfiles.SWORD)
	ctx.add_enemy_unit(Vector2(1500, 300), ScriptTeamAiProfiles.BOW)
	ctx.ai.update()
	_runner.assert_approx(ctx.ai.balance_of_powers(), 1.5, 0.001, "BoP = 3 - 1.5 = 1.5")
	_runner.assert_approx(ctx.ai.balance_of_powers_ratio(), 2.0, 0.001, "ratio = 3 / 1.5 = 2.0")
	ctx.teardown()


func _test_enemy_no_military() -> void:
	var ctx := _Ctx.new()
	ctx.setup()
	ctx.add_own_unit(Vector2(500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(1500, 300), ScriptTeamAiProfiles.PICKAXE)  # 非军事
	ctx.ai.update()
	_runner.assert_true(ctx.ai.enemy_has_no_military_units(), "PICKAXE 非军事，敌方无军事单位")
	_runner.assert_approx(ctx.ai.balance_of_powers_ratio(), 10.0, 0.001, "敌全灭哨兵值 10.0")
	ctx.teardown()


func _test_garrison_recent() -> void:
	var ctx := _Ctx.new()
	ctx.setup()
	ctx.add_own_unit(Vector2(500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(800, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.battle.duration = 15.0
	ctx.ai.update()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_GARRISON, "先驻守")
	# garrison_cool=8 内 we_recently_decided_to_garrison 真
	ctx.battle.duration = 20.0  # 距驻守 5s < 8s
	ctx.ai.update()
	_runner.assert_true(ctx.ai.we_recently_decided_to_garrison(), "5s < 8s cool 仍近期驻守")
	# cool 外
	ctx.battle.duration = 100.0  # 距驻守 85s > 8s
	ctx.ai.update()
	_runner.assert_false(ctx.ai.we_recently_decided_to_garrison(), "85s > 8s cool 非近期")
	ctx.teardown()


# ─────────────────────────────── Mock 夹具 ────────────────────────────────

class _Ctx:
	var battle: _FakeBattle
	var ai: TeamAi

	func setup() -> void:
		battle = _FakeBattle.new()
		ai = ScriptTeamAi.new()
		ai.setup(battle, 1, null, null, {})

	func teardown() -> void:
		if ai != null:
			ai.dispose()
		if battle != null:
			battle.queue_free()

	func add_own_unit(pos: Vector2, wtype: int) -> void:
		battle.add_unit(pos, 1, wtype, false)

	func add_enemy_unit(pos: Vector2, wtype: int) -> void:
		battle.add_unit(pos, 2, wtype, true)

	func kill_own_units(n: int) -> void:
		battle.kill_units(1, n)

	func clear_enemy_units() -> void:
		battle.clear_faction(2)


class _FakeBattle extends Node:
	var duration: float = 0.0
	var _units: Array = []
	var _anchor_faction1 := Vector2(500, 300)
	var _anchor_faction2 := Vector2(1500, 300)

	func add_unit(pos: Vector2, faction: int, wtype: int, is_enemy: bool) -> void:
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

	func clear_faction(faction: int) -> void:
		_units = _units.filter(func(u) -> bool: return u.faction != faction)

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
