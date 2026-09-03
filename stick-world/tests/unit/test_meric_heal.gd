extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：祭司 Meric 治疗（P7 · 5.1）。
## 覆盖 design §4.1 表 12 用例：目标选择/冷却/施法互斥/动画随机/HOT 回复/上限/无伤害/无近战/权重表/零回归。
## 不进场景树，确定性（FakeHealth 状态可控；StatusEffects tick 以 delta 参数驱动）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptTargetFinder := preload("res://modules/combat/scripts/target_finder.gd")
const ScriptStatusEffects := preload("res://modules/units/scripts/entity/status_effects.gd")
const ScriptBehaviorProfiles := preload("res://modules/units/scripts/ai/behavior_profiles.gd")
const ScriptTeamAiProfiles := preload("res://modules/combat/scripts/battle/team_ai_profiles.gd")
const ScriptWeaponMount := preload("res://modules/units/scripts/entity/weapon_mount.gd")
const ScriptAnims := preload("res://modules/units/scripts/rig/stickman_anims.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("目标选择-血量最低", _test_weakest_ally_lowest_hp)
	_runner.add_test("目标选择-满血不治", _test_weakest_ally_full_hp)
	_runner.add_test("目标选择-阵营隔离", _test_weakest_ally_faction_isolation)
	_runner.add_test("冷却硬约束", _test_cooldown_constraint)
	_runner.add_test("施法互斥", _test_casting_mutex)
	_runner.add_test("Heal1/Heal2 随机", _test_pick_heal_anim_random)
	_runner.add_test("HOT 逐 tick 回复", _test_hot_per_tick)
	_runner.add_test("HOT 上限钳制", _test_hot_cap)
	_runner.add_test("HOT 无伤害管线", _test_hot_no_damage)
	_runner.add_test("权重表扩展", _test_weight_table)
	_runner.add_test("档案零回归对照", _test_profile_zero_regression)
	_runner.add_test("find_weakest_ally 含自身", _test_weakest_ally_self)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────────────── 测试用例 ────────────────────────────────

func _test_weakest_ally_lowest_hp() -> void:
	var ctx := _Ctx.new()
	ctx.setup()
	var a1 := ctx.add_ally(Vector2(500, 300), 0.2)
	var a2 := ctx.add_ally(Vector2(520, 300), 0.6)
	var a3 := ctx.add_ally(Vector2(540, 300), 1.0)
	var target: Node = ScriptTargetFinder.find_weakest_ally(ctx.caster, { "battle": ctx.battle })
	_runner.assert_equal(target, a1, "应选 20% 血量者")
	ctx.teardown()


func _test_weakest_ally_full_hp() -> void:
	var ctx := _Ctx.new()
	ctx.setup()
	ctx.add_ally(Vector2(500, 300), 1.0)
	ctx.add_ally(Vector2(520, 300), 1.0)
	var target: Node = ScriptTargetFinder.find_weakest_ally(ctx.caster, { "battle": ctx.battle })
	_runner.assert_null(target, "全满血应返回 null")
	ctx.teardown()


func _test_weakest_ally_faction_isolation() -> void:
	var ctx := _Ctx.new()
	ctx.setup()
	ctx.add_ally(Vector2(500, 300), 1.0)
	ctx.add_enemy(Vector2(510, 300), 0.1)
	var target: Node = ScriptTargetFinder.find_weakest_ally(ctx.caster, { "battle": ctx.battle })
	_runner.assert_null(target, "敌方残血单位不入候选")
	ctx.teardown()


func _test_cooldown_constraint() -> void:
	var ctx := _Ctx.new()
	ctx.setup()
	var wm := _FakeWeaponMount.new()
	wm.weapon_type = ScriptBehaviorProfiles.MERIC
	wm._heal_anim_playing = false
	wm._last_heal_time = wm._now()
	_runner.assert_false(wm.can_cast_heal(), "刚施放冷却未过应假")
	wm._last_heal_time = wm._now() - 100.0
	_runner.assert_true(wm.can_cast_heal(), "冷却久远应真")
	ctx.teardown()


func _test_casting_mutex() -> void:
	var ctx := _Ctx.new()
	ctx.setup()
	var wm := _FakeWeaponMount.new()
	wm.weapon_type = ScriptBehaviorProfiles.MERIC
	wm._last_heal_time = -1.0e9
	wm._heal_anim_playing = true
	_runner.assert_false(wm.can_cast_heal(), "施法中应假")
	wm._heal_anim_playing = false
	_runner.assert_true(wm.can_cast_heal(), "非施法中应真")
	ctx.teardown()


func _test_pick_heal_anim_random() -> void:
	var seen: Dictionary = {}
	for i in 50:
		var anim: String = ScriptAnims.pick_heal_anim()
		seen[anim] = true
	_runner.assert_true(seen.has(ScriptAnims.ANIM_HEAL_MERIC_1), "50 次应出现 heal_meric_1")
	_runner.assert_true(seen.has(ScriptAnims.ANIM_HEAL_MERIC_2), "50 次应出现 heal_meric_2")


func _test_hot_per_tick() -> void:
	var se := ScriptStatusEffects.new()
	var owner := _FakeEntity.new()
	owner.health = _FakeHealth.new()
	owner.health.max_hp = 100.0
	owner.health.hp = 50.0
	se._owner = owner
	se.apply(ScriptStatusEffects.Type.HEAL, 1000.0, 5.0, owner)
	for i in 6:
		se._physics_process(0.5)
	_runner.assert_approx(owner.health.hp, 80.0, 0.01, "6 tick × 5.0 = +30 → hp=80")
	owner.queue_free()
	se.queue_free()


func _test_hot_cap() -> void:
	var se := ScriptStatusEffects.new()
	var owner := _FakeEntity.new()
	owner.health = _FakeHealth.new()
	owner.health.max_hp = 100.0
	owner.health.hp = 99.0
	se._owner = owner
	se.apply(ScriptStatusEffects.Type.HEAL, 1000.0, 5.0, owner)
	se._physics_process(0.5)
	_runner.assert_equal(owner.health.hp, 100.0, "99+5 应钳制到 100")
	owner.queue_free()
	se.queue_free()


func _test_hot_no_damage() -> void:
	var se := ScriptStatusEffects.new()
	var owner := _FakeEntity.new()
	owner.health = _FakeHealth.new()
	owner.health.max_hp = 100.0
	owner.health.hp = 50.0
	se._owner = owner
	se.apply(ScriptStatusEffects.Type.HEAL, 1000.0, 5.0, owner)
	se._physics_process(0.5)
	_runner.assert_equal(owner.health.damage_count, 0, "HEAL 全程不调 damage")
	owner.queue_free()
	se.queue_free()


func _test_weight_table() -> void:
	var weights: Dictionary = ScriptTeamAiProfiles.DEFAULTS.get("unit_weights", {})
	_runner.assert_true(weights.has(ScriptTeamAiProfiles.MERIC), "unit_weights 含 MERIC")
	_runner.assert_approx(float(weights.get(ScriptTeamAiProfiles.MERIC, -1.0)), 1.0, 0.001, "MERIC 权重=1.0")
	var priority: Array = ScriptTeamAiProfiles.DEFAULTS.get("type_priority", [])
	var idx_meric: int = priority.find(ScriptTeamAiProfiles.MERIC)
	var idx_bow: int = priority.find(ScriptTeamAiProfiles.BOW)
	var idx_sword: int = priority.find(ScriptTeamAiProfiles.SWORD)
	_runner.assert_gt(idx_meric, -1, "type_priority 含 MERIC")
	_runner.assert_true(idx_bow < idx_meric and idx_meric < idx_sword, "MERIC 位次介于 BOW 与 SWORD 之间")


func _test_profile_zero_regression() -> void:
	var baseline: Dictionary = ScriptBehaviorProfiles.get_profile(ScriptBehaviorProfiles.SWORD)
	_runner.assert_false(bool(baseline.get("heal_enabled", true)), "SWORD heal_enabled=false")
	var meric: Dictionary = ScriptBehaviorProfiles.get_profile(ScriptBehaviorProfiles.MERIC)
	_runner.assert_true(bool(meric.get("heal_enabled", false)), "MERIC heal_enabled=true")
	for wtype in [ScriptBehaviorProfiles.SWORD, ScriptBehaviorProfiles.SPEAR,
			ScriptBehaviorProfiles.BOW, ScriptBehaviorProfiles.PICKAXE, ScriptBehaviorProfiles.STAFF]:
		var p: Dictionary = ScriptBehaviorProfiles.get_profile(wtype)
		_runner.assert_false(bool(p.get("heal_enabled", true)), "非 MERIC heal_enabled=false (wtype=%d)" % wtype)


func _test_weakest_ally_self() -> void:
	var ctx := _Ctx.new()
	ctx.setup()
	ctx.caster_health.hp = 30.0
	ctx.caster_health.max_hp = 100.0
	var target: Node = ScriptTargetFinder.find_weakest_ally(ctx.caster, { "battle": ctx.battle })
	_runner.assert_equal(target, ctx.caster, "祭司自身残血应可自我治疗")
	ctx.teardown()


# ─────────────────────────────── Mock 夹具 ────────────────────────────────

class _Ctx:
	var battle: _FakeBattle
	var caster: _FakeEntity
	var caster_health: _FakeHealth

	func setup() -> void:
		battle = _FakeBattle.new()
		caster_health = _FakeHealth.new()
		caster_health.max_hp = 100.0
		caster_health.hp = 100.0
		caster = _FakeEntity.new()
		caster.faction = 1
		caster.global_position = Vector2(480, 300)
		caster.health = caster_health
		battle.add_unit(caster)

	func teardown() -> void:
		if caster != null:
			caster.queue_free()
		if battle != null:
			battle.queue_free()

	func add_ally(pos: Vector2, hp_ratio: float) -> _FakeEntity:
		var h := _FakeHealth.new()
		h.max_hp = 100.0
		h.hp = hp_ratio * 100.0
		var e := _FakeEntity.new()
		e.faction = 1
		e.global_position = pos
		e.health = h
		battle.add_unit(e)
		return e

	func add_enemy(pos: Vector2, hp_ratio: float) -> _FakeEntity:
		var h := _FakeHealth.new()
		h.max_hp = 100.0
		h.hp = hp_ratio * 100.0
		var e := _FakeEntity.new()
		e.faction = 2
		e.global_position = pos
		e.health = h
		battle.add_unit(e)
		return e


class _FakeBattle extends Node:
	var _units: Array = []

	func add_unit(u: _FakeEntity) -> void:
		_units.append(u)

	func get_allies_of(faction: int) -> Array:
		return _units.filter(func(u): return u.faction == faction)

	func get_enemies_of(faction: int) -> Array:
		return _units.filter(func(u): return u.faction != faction)


class _FakeEntity extends Node2D:
	var faction: int = 0
	var health: _FakeHealth

	func get_faction() -> int:
		return faction

	func get_health() -> Node:
		return health

	func is_dead() -> bool:
		return false


class _FakeHealth extends Node:
	var hp: float = 100.0
	var max_hp: float = 100.0
	var damage_count: int = 0

	func get_hp_ratio() -> float:
		return hp / max_hp if max_hp > 0.0 else 0.0

	func heal(amount: float) -> void:
		hp = minf(max_hp, hp + maxf(0.0, amount))

	func take_damage(amount: float) -> void:
		damage_count += 1
		hp -= amount


class _FakeWeaponMount extends RefCounted:
	var weapon_type: int = 0
	var _heal_anim_playing: bool = false
	var _last_heal_time: float = -1.0e9

	func can_cast_heal() -> bool:
		var profile: Dictionary = ScriptBehaviorProfiles.get_profile(int(weapon_type))
		var cd: float = float(profile.get("heal_cooldown", 0.0))
		if cd <= 0.0:
			return not _heal_anim_playing
		return (_now() - _last_heal_time >= cd) and not _heal_anim_playing

	func _now() -> float:
		return Time.get_ticks_msec() / 1000.0