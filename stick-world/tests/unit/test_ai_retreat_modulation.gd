extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：A3 · C6 概率调制撤退（设计文档12号 §三C6 / §五批次表 A3，AI集大成）。
## 覆盖：档案新键默认值（开关默认关=零回归）/ personality 难度行 retreat_chance
## （CoH 真值）/ 候选判定因果性（概率是执行机制不是因果）/ 掷骰边界与种子确定性 /
## 后撤(fallback)/撤退(withdraw) 双档语义 / 掷骰节流 / 强制溃逃链优先 /
## behavior_retreat withdraw 档行为与降级路径。
## 不进场景树（fixture 用 new() + 直注入 _entity，不碰树；BalanceConfig 只读，
## behavior_profiles 档案缓存用后清理）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptBehaviorProfiles := preload("res://modules/units/scripts/ai/behavior_profiles.gd")
const ScriptAIController := preload("res://modules/units/scripts/ai/ai_controller.gd")
const ScriptBehaviorRetreat := preload("res://modules/units/scripts/ai/behavior_retreat.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("A3 档案新键默认值（开关默认关 = 零回归）", _test_profile_defaults)
	_runner.add_test("personality 难度行 retreat_chance（CoH 真值）+ 未知难度 NAN", _test_personality_rows)
	_runner.add_test("开关默认关：候选条件满足也不撤退（走 attack）", _test_mod_off_zero_regression)
	_runner.add_test("因果性：chance=1 但战况健康不撤退", _test_candidate_causality)
	_runner.add_test("掷骰边界：chance=0 永不撤 / chance=1 候选必撤", _test_dice_boundary)
	_runner.add_test("双档：战线崩坏→withdraw 回锚点 / 个人恶化→fallback 后撤", _test_dual_tier)
	_runner.add_test("掷骰节流：评估周期内只掷一次", _test_throttle)
	_runner.add_test("强制溃逃链优先：绕过开关与节流", _test_forced_chain_priority)
	_runner.add_test("种子确定性：同种子同决策序列", _test_seed_determinism)
	_runner.add_test("withdraw 档行为：朝锚点行军、抵达收束、士气恢复", _test_withdraw_behavior)
	_runner.add_test("withdraw 降级：锚点不可用回退 fallback / evacuate 优先", _test_withdraw_degrade)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────────────── 测试用例 ────────────────────────────────

func _test_profile_defaults() -> void:
	_runner.assert_false(bool(ScriptBehaviorProfiles.BASELINE.get("retreat_mod_enabled", true)),
			"retreat_mod_enabled 基线默认关")
	for wtype in [ScriptBehaviorProfiles.SWORD, ScriptBehaviorProfiles.SPEAR,
			ScriptBehaviorProfiles.BOW, ScriptBehaviorProfiles.STAFF,
			ScriptBehaviorProfiles.PICKAXE, ScriptBehaviorProfiles.MERIC]:
		var p: Dictionary = ScriptBehaviorProfiles.get_profile(wtype)
		_runner.assert_false(bool(p.get("retreat_mod_enabled", true)),
				"retreat_mod_enabled 默认关 (wtype=%d)" % wtype)
	var p2: Dictionary = ScriptBehaviorProfiles.get_profile(ScriptBehaviorProfiles.SWORD)
	_runner.assert_approx(float(p2.get("retreat_mod_hp_ratio", -1.0)), 0.49, 0.001,
			"hp 阈值 = 0.49（CoH retreat_capacity_percentage）")
	_runner.assert_approx(float(p2.get("retreat_mod_morale_ratio", -1.0)), 0.35, 0.001,
			"士气阈值 = 0.35（语义映射初值）")
	_runner.assert_approx(float(p2.get("retreat_mod_ally_break_ratio", -1.0)), 0.51, 0.001,
			"友军崩坏比例阈值 = 0.51（CoH retreat_suppressed_percentage）")
	_runner.assert_approx(float(p2.get("retreat_mod_ally_radius", -1.0)), 300.0, 0.001,
			"友军判定半径 = 300px")
	_runner.assert_approx(float(p2.get("retreat_mod_reevaluate", -1.0)), 2.5, 0.001,
			"掷骰评估周期 = 2.5s（CoH 20 tick）")
	_runner.assert_approx(float(p2.get("retreat_mod_chance", -1.0)), 0.30, 0.001,
			"基线掷骰概率 = 0.30（CoH standard）")
	_runner.assert_approx(float(p2.get("retreat_mod_withdraw_arrive", -1.0)), 80.0, 0.001,
			"withdraw 抵达半径 = 80px")
	_runner.assert_approx(float(p2.get("retreat_mod_withdraw_max_time", -1.0)), 12.0, 0.001,
			"withdraw 超时 = 12s")
	# 士气阈值须 ≥ 强制链低士气阈值 0.25（只补中间带，不越权强制链）
	_runner.assert_true(float(p2.get("retreat_mod_morale_ratio", 0.0)) >= 0.25,
			"士气阈值 ≥ 强制链 0.25（中间带约束）")


func _test_personality_rows() -> void:
	# CoH retreat_chance 真值：easy 0.30 / standard 0.30 / hard 0.45 / hardest 0.35
	_runner.assert_approx(ScriptBehaviorProfiles.get_difficulty_retreat_chance("easy"), 0.30, 0.001,
			"easy retreat_chance = 0.30")
	_runner.assert_approx(ScriptBehaviorProfiles.get_difficulty_retreat_chance("standard"), 0.30, 0.001,
			"standard retreat_chance = 0.30")
	_runner.assert_approx(ScriptBehaviorProfiles.get_difficulty_retreat_chance("hard"), 0.45, 0.001,
			"hard retreat_chance = 0.45")
	_runner.assert_approx(ScriptBehaviorProfiles.get_difficulty_retreat_chance("hardest"), 0.35, 0.001,
			"hardest retreat_chance = 0.35")
	_runner.assert_true(is_nan(ScriptBehaviorProfiles.get_difficulty_retreat_chance("nope")),
			"未知难度 = NAN（调用方档案基线兜底）")


func _test_mod_off_zero_regression() -> void:
	var ctx := _make_ctx({}, false)  # 开关保持默认关（零回归基线）
	# 候选条件全满足（血量 0.4 < 0.49、近身威胁），但开关关 → 不走调制，落 attack
	ctx.health.hp_ratio = 0.4
	ctx.health.morale_ratio = 0.5
	ctx.ai._try_combat()
	_runner.assert_equal(ctx.ai.get_current_behavior(), "attack", "开关关不撤退（零回归）")
	ctx.teardown()


func _test_candidate_causality() -> void:
	# chance=1（掷骰必过）但三因子全不成立（血量/士气健康、友军完好）→ 不撤退：
	# 概率是执行机制不是因果——候选判定仍是真实战况（设计原则 3）
	var ctx := _make_ctx({"retreat_mod_chance": 1.0})
	ctx.health.hp_ratio = 0.9
	ctx.health.morale_ratio = 0.9
	ctx.ai._try_combat()
	_runner.assert_not_equal(ctx.ai.get_current_behavior(), "retreat", "健康战况 chance=1 也不撤")
	ctx.teardown()


func _test_dice_boundary() -> void:
	# chance=0：候选成立（血量 0.4）也永不撤退
	var ctx0 := _make_ctx({"retreat_mod_chance": 0.0})
	ctx0.health.hp_ratio = 0.4
	for i in 6:
		ctx0.ai.get_state_machine().travel("idle")
		ctx0.battle.duration = i * 2.6  # 跨过每个评估周期
		ctx0.ai._try_combat()
		_runner.assert_not_equal(ctx0.ai.get_current_behavior(), "retreat",
				"chance=0 第 %d 拍不撤退" % (i + 1))
	ctx0.teardown()
	# chance=1：候选成立必撤退（fallback 档，个人恶化）
	var ctx1 := _make_ctx({"retreat_mod_chance": 1.0})
	ctx1.health.hp_ratio = 0.4
	ctx1.ai._try_combat()
	_runner.assert_equal(ctx1.ai.get_current_behavior(), "retreat", "chance=1 候选必撤")
	var rb: BehaviorRetreat = ctx1.ai.get_state_machine()._current_behavior
	_runner.assert_false(rb._withdraw, "个人恶化 → fallback 档")
	ctx1.teardown()


func _test_dual_tier() -> void:
	# 战线崩坏：判定半径内友军全部溃逃/阵亡（比例 1.0 ≥ 0.51）→ withdraw 撤退回锚点
	var ctxw := _make_ctx({"retreat_mod_chance": 1.0})
	ctxw.health.hp_ratio = 0.9  # 个人战况健康，只崩战线
	ctxw.health.morale_ratio = 0.9
	ctxw.add_ally(Vector2(800, 300), true, false)   # 溃逃友军
	ctxw.add_ally(Vector2(1000, 280), false, true)  # 阵亡友军
	ctxw.ai._try_combat()
	_runner.assert_equal(ctxw.ai.get_current_behavior(), "retreat", "战线崩坏触发撤退")
	var rw: BehaviorRetreat = ctxw.ai.get_state_machine()._current_behavior
	_runner.assert_true(rw._withdraw, "战线崩坏 → withdraw 档")
	_runner.assert_true(rw.get_retreat_dir().x < 0.0, "方向朝己方锚点（x=260 < 实体 900）")
	ctxw.teardown()
	# 孤军（判定半径内无友军）：崩坏比例 0，不构成战线信号 → 个人恶化走 fallback
	var ctxf := _make_ctx({"retreat_mod_chance": 1.0})
	ctxf.health.hp_ratio = 0.4
	ctxf.ai._try_combat()
	_runner.assert_equal(ctxf.ai.get_current_behavior(), "retreat", "孤军个人恶化触发后撤")
	var rf: BehaviorRetreat = ctxf.ai.get_state_machine()._current_behavior
	_runner.assert_false(rf._withdraw, "孤军 → fallback 档")
	ctxf.teardown()


func _test_throttle() -> void:
	# chance=1、周期 2.5s：t=0 掷骰撤退 → t=0.1 节流窗内不掷（落 attack）→ t=3.0 再掷撤退
	var ctx := _make_ctx({"retreat_mod_chance": 1.0, "retreat_mod_reevaluate": 2.5})
	ctx.health.hp_ratio = 0.4
	ctx.battle.duration = 0.0
	ctx.ai._try_combat()
	_runner.assert_equal(ctx.ai.get_current_behavior(), "retreat", "首拍掷骰撤退")
	_runner.assert_approx(ctx.ai._retreat_mod_next_roll_at, 2.5, 0.001, "下次掷骰时刻推进到 2.5")
	ctx.battle.duration = 0.1
	ctx.ai.get_state_machine().travel("idle")
	ctx.ai._try_combat()
	_runner.assert_equal(ctx.ai.get_current_behavior(), "attack", "节流窗内不重掷（落 attack）")
	ctx.battle.duration = 3.0
	ctx.ai.get_state_machine().travel("idle")
	ctx.ai._try_combat()
	_runner.assert_equal(ctx.ai.get_current_behavior(), "retreat", "周期过后再掷再撤")
	ctx.teardown()


func _test_forced_chain_priority() -> void:
	# is_routed 强制溃逃：调制关也撤；调制开且节流窗未到也撤（绕过掷骰）；
	# 强制链 params 不带 retreat_mode（BehaviorRetreat 缺省 fallback 语义）
	var ctx := _make_ctx({"retreat_mod_enabled": true, "retreat_mod_chance": 1.0})
	ctx.health.routed = true
	ctx.ai._retreat_mod_next_roll_at = 100.0  # 节流窗未到
	ctx.battle.duration = 0.0
	ctx.ai._try_combat()
	_runner.assert_equal(ctx.ai.get_current_behavior(), "retreat", "强制链绕过节流撤退")
	var rb: BehaviorRetreat = ctx.ai.get_state_machine()._current_behavior
	_runner.assert_false(rb._withdraw, "强制链缺省 fallback 语义")
	ctx.teardown()
	# 调制关 + is_routed：既有强制链原样（零回归）
	var ctx2 := _make_ctx({}, false)
	ctx2.health.routed = true
	ctx2.ai._try_combat()
	_runner.assert_equal(ctx2.ai.get_current_behavior(), "retreat", "调制关强制链仍生效")
	ctx2.teardown()


func _test_seed_determinism() -> void:
	# 同种子 → 撤退/不撤决策序列逐位一致（掷骰去同步但可复现：单测可锁/battle_sim 可复现）
	var seq_a: Array = _run_dice_sequence(7)
	var seq_b: Array = _run_dice_sequence(7)
	_runner.assert_equal(seq_a, seq_b, "同种子决策序列一致（%s…）" % str(seq_a.slice(0, 6)))
	# chance=0.5 下 24 拍应撤退/不撤混合（全同概率 ≈ 2^-23，视为确定性破缺）
	var has_true: bool = false
	var has_false: bool = false
	for v in seq_a:
		if v:
			has_true = true
		else:
			has_false = true
	_runner.assert_true(has_true and has_false, "概率行为有混合结果（非恒真/恒假）")


func _test_withdraw_behavior() -> void:
	var entity := _FakeEntity.new()
	entity.global_position = Vector2(900, 300)
	var health := _FakeHealth.new()
	entity.health = health
	var battle := _FakeBattle.new()
	battle.units.append(entity)
	var retreat: BehaviorRetreat = ScriptBehaviorRetreat.new()
	retreat.entity = entity
	retreat.enter("", {"battle": battle, "retreat_mode": "withdraw"})
	_runner.assert_true(retreat._withdraw, "withdraw 档激活")
	_runner.assert_true(retreat.get_retreat_dir().x < 0.0, "方向朝锚点")
	# 收束参数收紧（enter 已解析档案，直接改运行时档案模拟扫参）；
	# max_time 须宽于行军所需步数（640px→60px 带需 58 步×0.1s=5.8s），保证抵达先于超时
	retreat._profile["retreat_mod_withdraw_arrive"] = 60.0
	retreat._profile["retreat_mod_withdraw_max_time"] = 10.0
	# 逐步推进：ai_move 每次走 10px，直至抵达锚点带（640px 距离 → ≤64 步）
	var steps: int = 0
	while not retreat.is_finished() and steps < 100:
		retreat.update(0.1)
		steps += 1
	_runner.assert_true(retreat.is_finished(), "抵达锚点带收束（%d 步）" % steps)
	_runner.assert_true(entity.global_position.distance_to(battle.anchor) <= 60.0 + 0.1,
			"实体停在锚点带内（距 %.0f）" % entity.global_position.distance_to(battle.anchor))
	_runner.assert_true(entity.stopped, "收束时停步（ai_stop）")
	_runner.assert_gt(health.recovered_total, 0.0, "撤退途中士气恢复（重整分量）")
	retreat.free()
	health.free()
	entity.free()
	battle.free()


func _test_withdraw_degrade() -> void:
	var entity := _FakeEntity.new()
	entity.global_position = Vector2(900, 300)
	# 锚点查询不可用（无 get_faction_side_anchor）→ withdraw 降级 fallback
	var battle_plain := _FakeBattleNoAnchor.new()
	battle_plain.enemies.append(_make_left_enemy())
	var r1: BehaviorRetreat = ScriptBehaviorRetreat.new()
	r1.entity = entity
	r1.enter("", {"battle": battle_plain, "retreat_mode": "withdraw"})
	_runner.assert_false(r1._withdraw, "锚点不可用降级 fallback")
	_runner.assert_gt(r1.get_retreat_dir().x, 0.0, "降级后撤方向远离敌人")
	r1.free()
	# evacuate 优先于 withdraw（战役撤离通道不受影响，C3 语义原样）
	var r2: BehaviorRetreat = ScriptBehaviorRetreat.new()
	r2.entity = entity
	r2.enter("", {"battle": battle_plain, "evacuate": true, "retreat_mode": "withdraw"})
	_runner.assert_true(r2._evacuate, "evacuate 激活")
	_runner.assert_false(r2._withdraw, "evacuate 优先，withdraw 不生效")
	r2.free()
	# 缺省 params：fallback 原语义（零回归）
	var r3: BehaviorRetreat = ScriptBehaviorRetreat.new()
	r3.entity = entity
	r3.enter("", {"battle": battle_plain})
	_runner.assert_false(r3._withdraw, "缺省 fallback")
	_runner.assert_gt(r3.get_retreat_dir().x, 0.0, "既有方向语义：远离最近敌")
	r3.free()
	entity.free()
	battle_plain.free()


## 左侧假敌（降级后撤方向 = 远离敌 = 朝右）
func _make_left_enemy() -> _FakeAlly:
	var enemy := _FakeAlly.new()
	enemy.faction = 2
	enemy.global_position = Vector2(800, 300)
	return enemy


# ─────────────────────────────── 夹具 ────────────────────────────────

## 档案覆盖（直接改 SWORD 合并档案缓存引用，battle_sim 扫参先例 test_rout_enhance；
## 测试结束 _reset_profile_cache 清缓存重合并恢复原值）
func _mod_profile(overrides: Dictionary) -> void:
	var p: Dictionary = ScriptBehaviorProfiles.get_profile(ScriptBehaviorProfiles.SWORD)
	for k in overrides.keys():
		p[k] = overrides[k]


func _reset_profile_cache() -> void:
	ScriptBehaviorProfiles._cache.clear()


func _make_ctx(profile_overrides: Dictionary, enable_mod: bool = true) -> _Ctx:
	var ctx := _Ctx.new()
	ctx.setup(profile_overrides, enable_mod)
	return ctx


## 掷骰决策序列（同种子复现用）：24 拍、chance=0.5、评估周期 0.05s
func _run_dice_sequence(seed_v: int) -> Array:
	_reset_profile_cache()
	_mod_profile({
		"retreat_mod_enabled": true,
		"retreat_mod_chance": 0.5,
		"retreat_mod_reevaluate": 0.05,
	})
	var ctx := _make_ctx({})
	ctx.ai._retreat_mod_rng.seed = seed_v
	ctx.health.hp_ratio = 0.4  # 候选条件：血量低于阈值（因果=真实战况）
	var outcomes: Array = []
	for i in 24:
		ctx.battle.duration = i * 0.05
		ctx.ai.get_state_machine().travel("idle")
		ctx.ai._try_combat()
		outcomes.append(ctx.ai.get_current_behavior() == "retreat")
	ctx.teardown()
	_reset_profile_cache()
	return outcomes


class _Ctx:
	var entity: _FakeEntity
	var battle: _FakeBattle
	var ai: AIController
	var health: _FakeHealth

	func setup(profile_overrides: Dictionary = {}, enable_mod: bool = true) -> void:
		health = _FakeHealth.new()
		entity = _FakeEntity.new()
		entity.health = health
		entity.global_position = Vector2(900, 300)
		battle = _FakeBattle.new()
		battle.units.append(entity)
		entity.battle = battle
		# 默认 difficulty 指向配置未知的档名 → 掷骰概率走档案基线（可注入控制）；
		# 难度行消费由 _test_personality_rows 直测 BalanceConfig 真值
		battle.team_ai = _FakeTeamAi.new()
		var enemy := _FakeAlly.new()
		enemy.faction = 2
		enemy.global_position = Vector2(1000, 300)  # 近身威胁（100px < 140）
		battle.enemies.append(enemy)
		ai = AIController.new()
		ai._entity = entity  # 不进树直接注入（_ready cast 等价物，batch 准入：不进场景树）
		ai._setup_state_machine()
		if enable_mod:
			var p: Dictionary = ScriptBehaviorProfiles.get_profile(ScriptBehaviorProfiles.SWORD)
			p["retreat_mod_enabled"] = true
		for k in profile_overrides.keys():
			var p2: Dictionary = ScriptBehaviorProfiles.get_profile(ScriptBehaviorProfiles.SWORD)
			p2[k] = profile_overrides[k]

	func add_ally(pos: Vector2, routed: bool, dead: bool) -> void:
		var ally := _FakeAlly.new()
		ally.faction = 1
		ally.global_position = pos
		ally.routed = routed
		ally.dead = dead
		battle.allies.append(ally)

	func teardown() -> void:
		if ai != null:
			ai.free()
		if entity != null:
			entity.free()
		if battle != null:
			battle.free()
		if health != null:
			health.free()
		ScriptBehaviorProfiles._cache.clear()


class _FakeEntity extends CharacterBody2D:
	var health: Node = null
	var battle: Node = null
	var stopped: bool = false
	var last_dir := Vector2.ZERO

	func get_weapon() -> Node:
		return self

	func get_faction() -> int:
		return 1

	func get_battle_instance() -> Node:
		return battle

	func is_possessed() -> bool:
		return false

	func is_dead() -> bool:
		return false

	func get_health() -> Node:
		return health

	func ai_move(dir: Vector2, _run: bool) -> void:
		last_dir = dir
		global_position += dir * 10.0  # 测试步进：每拍 10px（withdraw 行军模拟）

	func ai_stop() -> void:
		stopped = true


class _FakeHealth extends Node:
	var hp_ratio: float = 1.0
	var morale_ratio: float = 1.0
	var routed: bool = false
	var recovered_total: float = 0.0

	func get_hp_ratio() -> float:
		return hp_ratio

	func get_morale_ratio() -> float:
		return morale_ratio

	func is_routed() -> bool:
		return routed

	func restore_morale(amount: float) -> void:
		recovered_total += amount


class _FakeAlly extends Node2D:
	var faction: int = 1
	var routed: bool = false
	var dead: bool = false

	func is_dead() -> bool:
		return dead

	func get_faction() -> int:
		return faction

	func get_health() -> Node:
		return self

	func is_routed() -> bool:
		return routed


class _FakeTeamAi extends RefCounted:
	var difficulty: String = "testdiff"  # 配置未知档名 → retreat_chance 走档案基线

	func get_difficulty() -> String:
		return difficulty


class _FakeBattle extends Node:
	var duration: float = 0.0
	var units: Array = []
	var enemies: Array = []
	var allies: Array = []
	var team_ai: Variant = null
	var anchor := Vector2(260, 300)  # 己方侧锚点（faction 1，anchor_margin 260 内收）

	func is_active() -> bool:
		return true

	func get_duration() -> float:
		return duration

	func get_nearest_enemy(_unit: Node) -> Node:
		return enemies[0] if not enemies.is_empty() else null

	func get_enemies_of(_faction: int) -> Array:
		return enemies

	func get_allies_of(_faction: int) -> Array:
		return allies

	func get_team_ai(_faction: int) -> Variant:
		return team_ai

	func get_faction_side_anchor(faction: int) -> Vector2:
		return anchor


## 最小假战斗（无 get_faction_side_anchor/get_team_ai/get_allies_of：
## 验证 withdraw 锚点解析降级路径）
class _FakeBattleNoAnchor extends Node:
	var enemies: Array = []

	func is_active() -> bool:
		return true

	func get_nearest_enemy(_unit: Node) -> Node:
		return enemies[0] if not enemies.is_empty() else null
