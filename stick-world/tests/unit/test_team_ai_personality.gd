extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：TeamAi A1 节拍+参数档案化（设计文档12号 C1/C2，AI集大成）。
## 覆盖：personality 单一档案 BalanceConfig 装载（难度分档维度已裁决移除·开放
## 问题#3）/ 档案参数消费与显式 overrides 优先序 / 开局攻击时间 ±方差掷骰
## （界内+种子确定性）/ 节拍分帧双相位轮转 / 基础节拍下限钳制 /
## difficulty 遗留键宽容忽略。
## 不进场景树，确定性（FakeBattle 时钟与调用计数可控；只读 BalanceConfig autoload，
## 先例 test_balance_config；tick 依赖 TimeManager 非暂停——batch_runner 每套件前重置）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptTeamAi := preload("res://modules/combat/scripts/battle/team_ai.gd")
const ScriptTeamAiProfiles := preload("res://modules/combat/scripts/battle/team_ai_profiles.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("BalanceConfig 装载 personality 单一档案", _test_personality_config_loaded)
	_runner.add_test("单一档案覆盖进参数档案 + 显式 overrides 最高优先", _test_profile_overlay)
	_runner.add_test("开局攻击时间掷骰界内 + 种子确定性", _test_variance_roll)
	_runner.add_test("开局门禁消费档案时间", _test_gate_consumes_profile)
	_runner.add_test("节拍分帧：决策只在节拍边界、双相位轮转", _test_beat_phase_rotation)
	_runner.add_test("基础节拍下限钳制", _test_beat_min_clamp)
	_runner.add_test("difficulty 遗留键宽容忽略", _test_legacy_difficulty_key_ignored)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────────────── 测试用例 ────────────────────────────────

func _test_personality_config_loaded() -> void:
	# global 行：L4 基础节拍（C1，CoH 0.5s 真值）
	_runner.assert_approx(BalanceConfig.get_value("ai.personality.global.beat_interval"), 0.5, 0.001, "global.beat_interval = 0.5")
	# 机制参数上移单一 global 行（原 standard 档数值 = 代码默认镜像，零回归基线）
	_runner.assert_approx(BalanceConfig.get_value("ai.personality.global.seconds_before_attack"), 10.0, 0.001, "门禁基准 10s")
	_runner.assert_approx(BalanceConfig.get_value("ai.personality.global.start_attack_variance"), 2.0, 0.001, "方差半宽 2s")
	_runner.assert_approx(BalanceConfig.get_value("ai.personality.global.demand_variance"), 0.8, 0.001, "demand_variance 单旋钮 0.8")
	_runner.assert_approx(BalanceConfig.get_value("ai.personality.global.attack_pct_baseline"), 0.6, 0.001, "攻击百分比基调 0.6")
	_runner.assert_approx(BalanceConfig.get_value("ai.personality.global.max_attack_percentage"), 0.70, 0.001, "攻击百分比封顶 0.70")
	_runner.assert_approx(BalanceConfig.get_value("ai.personality.global.retreat_chance"), 0.30, 0.001, "撤退掷骰概率 0.30（CoH）")
	# 难度分档维度已裁决移除：仅余单一 global 行
	var rows: Variant = BalanceConfig.get("data").get("ai.personality", [])
	_runner.assert_true(rows is Array and (rows as Array).size() == 1, "personality 仅单一行（难度行已移除）")
	if rows is Array and (rows as Array).size() == 1:
		_runner.assert_equal(str((rows[0] as Dictionary).get("id", "")), "global", "唯一行 = global")
	# 装载器：无参 overlay 携带节拍与门禁参数
	var overlay: Dictionary = ScriptTeamAiProfiles.load_personality_overlay()
	_runner.assert_approx(float(overlay.get("beat_interval", -1.0)), 0.5, 0.001, "overlay 含 beat_interval")
	_runner.assert_approx(float(overlay.get("seconds_before_attack", -1.0)), 10.0, 0.001, "overlay 含 seconds_before_attack")


func _test_profile_overlay() -> void:
	# 档案携带 C5 攻击百分比参数（原难度行参数上移后仍可消费）
	var overlay: Dictionary = ScriptTeamAiProfiles.load_personality_overlay()
	_runner.assert_approx(float(overlay.get("attack_pct_baseline", -1.0)), 0.6, 0.001, "overlay 含基调 0.6")
	_runner.assert_approx(float(overlay.get("superiority_gain", -1.0)), 1.0, 0.001, "overlay 含优势增益 1.0")
	# 档案门禁参数消费：默认（10±2）门禁必落于 [8,12]
	var ctx := _make_ctx({})
	_runner.assert_true(ctx.ai.get_attack_deadline() >= 8.0 and ctx.ai.get_attack_deadline() <= 12.0,
			"档案门禁 = 10±2 界内（实测 %.2f）" % ctx.ai.get_attack_deadline())
	ctx.teardown()
	# 显式 overrides 最高优先（覆盖序：代码默认 < personality 档案 < 显式 overrides）
	var ctx2 := _make_ctx({"seconds_before_attack": 20.0, "start_attack_variance": 0.0})
	_runner.assert_approx(ctx2.ai.get_attack_deadline(), 20.0, 0.0001, "显式 overrides 覆盖档案门禁")
	ctx2.teardown()


func _test_variance_roll() -> void:
	# 默认（standard 10±2）：任意种子门禁必落于 [8,12]
	var ctx := _make_ctx({})
	_runner.assert_true(ctx.ai.get_attack_deadline() >= 8.0 and ctx.ai.get_attack_deadline() <= 12.0,
			"standard 门禁 = 10±2 界内（实测 %.2f）" % ctx.ai.get_attack_deadline())
	ctx.teardown()
	# 同种子确定性：同难度+同种子 → 掷骰产物逐位一致（单测可锁/battle_sim 可复现）
	var ctx_a := _make_ctx({"random_seed": 7})
	var ctx_b := _make_ctx({"random_seed": 7})
	_runner.assert_approx(ctx_a.ai.get_attack_deadline(), ctx_b.ai.get_attack_deadline(), 0.0001, "同种子门禁一致")
	# 默认种子固定：无显式种子两次装配同样一致
	var ctx_c := _make_ctx({})
	var ctx_d := _make_ctx({})
	_runner.assert_approx(ctx_c.ai.get_attack_deadline(), ctx_d.ai.get_attack_deadline(), 0.0001, "默认种子门禁一致")
	ctx_a.teardown()
	ctx_b.teardown()
	ctx_c.teardown()
	ctx_d.teardown()


func _test_gate_consumes_profile() -> void:
	# 默认档案（10±2，任意掷骰 ∈ [8,12]）：ratio=3.0 力量占优，唯一变量是门禁
	# duration 7 < 8 → 门禁必未过 → DEFEND
	var ctx := _make_ctx({})
	_add_ratio3_setup(ctx)
	ctx.battle.duration = 7.0
	ctx.ai.update()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_DEFEND, "档案门禁内维持 DEFEND")
	# duration 13 ≥ 12 → 门禁必过 → ATTACK
	ctx.battle.duration = 13.0
	ctx.ai.update()
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_ATTACK, "档案门禁过切 ATTACK")
	ctx.teardown()


func _test_beat_phase_rotation() -> void:
	# 节拍 0.5s，双相位轮转：DECIDE（快照+决策）/ BUILD 交替——快照每 2 拍一次
	var ctx := _make_ctx({})
	_add_ratio3_setup(ctx)
	ctx.battle.duration = 15.0  # 门禁过（standard ≤12s）
	# 0.25s×2 累计 0.5s → 第 1 拍 DECIDE：快照 1 次 + 姿态决策切 ATTACK
	ctx.ai.tick(0.25)
	_runner.assert_equal(ctx.battle.count_allies_queries, 0, "半拍不决策")
	ctx.ai.tick(0.25)
	_runner.assert_equal(ctx.battle.count_allies_queries, 1, "满拍 DECIDE 快照 1 次")
	_runner.assert_equal(ctx.ai.get_stance(), ScriptTeamAi.STANCE_ATTACK, "首拍 DECIDE 完成姿态决策")
	# 0.25s×2 → 第 2 拍 BUILD：不刷快照
	ctx.ai.tick(0.25)
	ctx.ai.tick(0.25)
	_runner.assert_equal(ctx.battle.count_allies_queries, 1, "BUILD 拍不刷快照")
	# 0.25s×2 → 第 3 拍 DECIDE：快照第 2 次（决策周期 = 2×beat = 1.0s，与旧默认等价）
	ctx.ai.tick(0.25)
	ctx.ai.tick(0.25)
	_runner.assert_equal(ctx.battle.count_allies_queries, 2, "第 3 拍 DECIDE 快照第 2 次")
	ctx.teardown()


func _test_beat_min_clamp() -> void:
	# 覆盖注入 beat_interval=0.1 → 钳制到 MIN_BEAT_INTERVAL=0.5（防号令风暴）
	var ctx := _make_ctx({"beat_interval": 0.1})
	_add_ratio3_setup(ctx)
	ctx.battle.duration = 15.0
	ctx.ai.tick(0.3)
	_runner.assert_equal(ctx.battle.count_allies_queries, 0, "0.3s < 0.5s 下限不触发")
	ctx.ai.tick(0.2)
	_runner.assert_equal(ctx.battle.count_allies_queries, 1, "累计 0.5s 触发首拍")
	ctx.teardown()


func _test_legacy_difficulty_key_ignored() -> void:
	# 遗留键 overrides["difficulty"] 宽容忽略（难度分档已裁决移除·开放问题#3）：
	# 传入 "hard" 但门禁走单一档案（10±2 界内）而非 hard 档 5±1（[4,6]）——键未被消费
	var ctx := _make_ctx({"difficulty": "hard"})
	_runner.assert_true(ctx.ai.get_attack_deadline() >= 8.0 and ctx.ai.get_attack_deadline() <= 12.0,
			"difficulty 键被忽略、走单一档案门禁（实测 %.2f）" % ctx.ai.get_attack_deadline())
	ctx.teardown()
	# 决策链路正常（宽容忽略不破坏装配/决策）
	var ctx2 := _make_ctx({"difficulty": "hardest"})
	_add_ratio3_setup(ctx2)
	ctx2.battle.duration = 13.0
	ctx2.ai.update()
	_runner.assert_equal(ctx2.ai.get_stance(), ScriptTeamAi.STANCE_ATTACK, "遗留键传入后决策链路正常")
	ctx2.teardown()


# ─────────────────────────────── 夹具 ────────────────────────────────

## 力量占优局面（3 矛 vs 1 矛 → ratio=3.0 ≥ attack_enter 1.30）：门禁是唯一阻塞项
func _add_ratio3_setup(ctx: _Ctx) -> void:
	ctx.add_own_unit(Vector2(500, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(520, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_own_unit(Vector2(540, 300), ScriptTeamAiProfiles.SPEAR)
	ctx.add_enemy_unit(Vector2(1500, 300), ScriptTeamAiProfiles.SPEAR)


func _make_ctx(overrides: Dictionary) -> _Ctx:
	var ctx := _Ctx.new()
	ctx.setup(overrides)
	return ctx


class _Ctx:
	var battle: _FakeBattle
	var ai: TeamAi

	func setup(overrides: Dictionary = {}) -> void:
		battle = _FakeBattle.new()
		ai = ScriptTeamAi.new()
		ai.setup(battle, 1, null, null, overrides)

	func teardown() -> void:
		if ai != null:
			ai.dispose()
		if battle != null:
			battle.queue_free()

	func add_own_unit(pos: Vector2, wtype: int) -> void:
		battle.add_unit(pos, 1, wtype)

	func add_enemy_unit(pos: Vector2, wtype: int) -> void:
		battle.add_unit(pos, 2, wtype)


class _FakeBattle extends Node:
	var duration: float = 0.0
	var _units: Array = []
	var _anchor_faction1 := Vector2(500, 300)
	var _anchor_faction2 := Vector2(1500, 300)
	## get_allies_of 调用计数（_refresh_snapshot 每次调用一次 → 观测 DECIDE 拍）
	var count_allies_queries: int = 0

	func add_unit(pos: Vector2, faction: int, wtype: int) -> void:
		var u := _FakeUnit.new()
		u.global_position = pos
		u.faction = faction
		u.weapon_type = wtype
		u.dead = false
		_units.append(u)

	func get_allies_of(faction: int) -> Array:
		count_allies_queries += 1
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
