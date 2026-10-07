extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：找目标系统（SW3 FindTargetAiSystem 直译，确定性模拟核心 P1）。
## 覆盖：分层阈值边界 / 增量换靶滞回 / 驻留时长门槛 / 层提升立即换 /
## 追丢即换 / 强制目标生命周期 / 集火号令不落穿自主寻敌 / 守位者守卫（指挥官
## 与阵地护卫共口）。
## 不进场景树，确定性（无 RNG 依赖路径——掷骰不在本系统）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptTargetAcquire := preload("res://modules/units/scripts/ai/target_acquire.gd")

var _runner: TestRunner


class FakeWeapon:
	extends Node
	var attack_range: float = 100.0


class FakeUnit:
	extends Node2D
	var faction_id: int = 1
	var weapon: FakeWeapon = FakeWeapon.new()
	var _commander: bool = false
	var _guard_post: bool = false

	func get_weapon() -> FakeWeapon:
		return weapon

	func get_faction() -> int:
		return faction_id

	func is_dead() -> bool:
		return false

	func is_commander() -> bool:
		return _commander

	## 守位判定口（真身 StickmanEntity.holds_post：rank>=3 or guard_post）
	func holds_post() -> bool:
		return _commander or _guard_post


class FakeEnemy:
	extends Node2D
	var _dead: bool = false

	func is_dead() -> bool:
		return _dead


class FakeBattle:
	extends Node
	var enemies: Array = []

	func get_enemies_of(_faction: int) -> Array:
		return enemies


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("分层阈值: 距离带三档边界", _test_tier_bounds)
	_runner.add_test("寻敌: 首拍选最近敌", _test_first_elect)
	_runner.add_test("驻留门槛: 未满不换 满后经滞回换", _test_dwell_gate)
	_runner.add_test("滞回: 显著更近才换 略近不换", _test_hysteresis_margin)
	_runner.add_test("分层: 层提升立即换（不等驻留）", _test_tier_promotion)
	_runner.add_test("追丢: 超追击带即换（不等节拍）", _test_leash_re_elect)
	_runner.add_test("强制目标: 注入即锁 失效回落", _test_forced_target)
	_runner.add_test("集火号令: 存在时不落穿自主寻敌", _test_squad_no_fallthrough)
	_runner.add_test("守位者守卫: 超追击带自主目标拒选", _test_post_guard)
	_runner.add_test("阵地护卫: 非指挥官守位同享追击带门", _test_guard_post_unit)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────────────── 夹具 ────────────────────────────────

## 构造 helper：实体在原点（射程 100 / 追击带 ×4 = 400），profile 全基线回退
func _make_acq(enemies_at: Array = []) -> Dictionary:
	var entity := FakeUnit.new()
	entity.position = Vector2(0, 0)
	var battle := FakeBattle.new()
	for x in enemies_at:
		var e := FakeEnemy.new()
		e.position = Vector2(float(x), 0)
		battle.enemies.append(e)
	var acq: ScriptTargetAcquire = ScriptTargetAcquire.new()
	acq.setup(entity, battle, {})
	return {"acq": acq, "entity": entity, "battle": battle}


func _add_enemy(battle: FakeBattle, x: float) -> FakeEnemy:
	var e := FakeEnemy.new()
	e.position = Vector2(x, 0)
	battle.enemies.append(e)
	return e


# ─────────────────────────────── 用例 ────────────────────────────────

func _test_tier_bounds() -> void:
	var w := _make_acq([80.0, 150.0, 500.0])
	var acq: ScriptTargetAcquire = w["acq"]
	var e80: FakeEnemy = w["battle"].enemies[0]
	var e150: FakeEnemy = w["battle"].enemies[1]
	var e500: FakeEnemy = w["battle"].enemies[2]
	_runner.assert_equal(acq._tier_of(e80), ScriptTargetAcquire.TargetTier.IN_FIRE_RANGE,
			"80px ≤ 射程 100 → 射程内层")
	_runner.assert_equal(acq._tier_of(e150), ScriptTargetAcquire.TargetTier.OUT_OF_FIRE_RANGE,
			"150px 射程外追击带内 → 追击层")
	_runner.assert_equal(acq._tier_of(e500), ScriptTargetAcquire.TargetTier.UNREACHABLE,
			"500px > 400（射程×4）→ 追丢层")
	e80._dead = true
	_runner.assert_equal(acq._tier_of(e80), ScriptTargetAcquire.TargetTier.LOST,
			"死亡目标 → LOST")


func _test_first_elect() -> void:
	var w := _make_acq([150.0, 300.0])
	var acq: ScriptTargetAcquire = w["acq"]
	var t: Node = acq.advance(0.1)
	_runner.assert_equal(t, w["battle"].enemies[0], "首拍应选最近敌（150px）")
	_runner.assert_approx(acq.get_dwell(), 0.0, 0.001, "接受目标即清零驻留时钟（本拍起算）")


func _test_dwell_gate() -> void:
	# 当前目标 A@300（追击层）；候选 B@140（同层，140 < 300×0.6=180 过滞回线）
	var w := _make_acq([300.0])
	var acq: ScriptTargetAcquire = w["acq"]
	var a: FakeEnemy = w["battle"].enemies[0]
	acq.advance(0.1)
	_runner.assert_equal(acq.get_target(), a, "前置：唯一敌当选")
	var b := _add_enemy(w["battle"], 140.0)
	# 驻留未满：同层换靶被驻留门拦下
	acq._dwell = 0.5
	acq._acquire_timer = -1.0
	acq.advance(0.1)
	_runner.assert_equal(acq.get_target(), a, "驻留未满（0.5s < 2.0s）不换靶（决斗承诺）")
	# 驻留满 + 滞回线内（140 < 180）→ 换
	acq._dwell = 2.5
	acq._acquire_timer = -1.0
	acq.advance(0.1)
	_runner.assert_equal(acq.get_target(), b, "驻留满且显著更近 → 换靶")
	_runner.assert_approx(acq.get_dwell(), 0.0, 0.001, "换靶清零驻留时钟重计")


func _test_hysteresis_margin() -> void:
	# 当前 A@300；候选 C@200 同层但 200 ≥ 300×0.6=180 → 滞回拦下
	var w := _make_acq([300.0])
	var acq: ScriptTargetAcquire = w["acq"]
	var a: FakeEnemy = w["battle"].enemies[0]
	acq.advance(0.1)
	_add_enemy(w["battle"], 200.0)
	acq._dwell = 5.0
	acq._acquire_timer = -1.0
	acq.advance(0.1)
	_runner.assert_equal(acq.get_target(), a, "略近不换（200 ≥ 300×0.6）：换靶须显著更优")


func _test_tier_promotion() -> void:
	# 当前 A@150（追击层）；候选 B@90（射程内层）→ 层提升立即换，不等驻留
	var w := _make_acq([150.0])
	var acq: ScriptTargetAcquire = w["acq"]
	acq.advance(0.1)
	var b := _add_enemy(w["battle"], 90.0)
	acq._dwell = 0.05
	acq._acquire_timer = -1.0
	acq.advance(0.1)
	_runner.assert_equal(acq.get_target(), b, "射程内候选立即接管追击带目标（质变不走滞回）")


func _test_leash_re_elect() -> void:
	# 当前 A@500 超追击带（400）→ 不等扫视节拍立即选举，有效候选接管
	var w := _make_acq([500.0])
	var acq: ScriptTargetAcquire = w["acq"]
	acq.advance(0.1)
	_runner.assert_equal(acq.get_target(), w["battle"].enemies[0], "前置：唯一敌当选")
	var b := _add_enemy(w["battle"], 150.0)
	acq._acquire_timer = 5.0  # 节拍未到——追丢是事件触发边，不等周期
	acq.advance(0.1)
	_runner.assert_equal(acq.get_target(), b, "当前目标追丢：节拍外也立即重选")


func _test_forced_target() -> void:
	var w := _make_acq([150.0])
	var acq: ScriptTargetAcquire = w["acq"]
	var near: FakeEnemy = w["battle"].enemies[0]
	var forced := _add_enemy(w["battle"], 320.0)
	acq.set_forced_target(forced)
	var t: Node = acq.advance(0.1)
	_runner.assert_equal(t, forced, "强制目标（打通态）最高优先锁定")
	# 强制目标死亡 → 清除回落正常选敌
	forced._dead = true
	acq._acquire_timer = -1.0
	t = acq.advance(0.1)
	_runner.assert_equal(t, near, "强制目标失效后回落自主寻敌")


func _test_squad_no_fallthrough() -> void:
	# 集火号令存在时在小队层消化，不落穿自主寻敌：
	# ①当前无目标 → 排长目标直接接管（不选更近的自主候选）
	var w := _make_acq([90.0])
	var acq: ScriptTargetAcquire = w["acq"]
	var squad_target := _add_enemy(w["battle"], 150.0)
	acq.squad_target_fn = func() -> Node: return squad_target
	var t: Node = acq.advance(0.1)
	_runner.assert_equal(t, squad_target, "集火号令接管选敌（优先于自主最近）")
	# ②号令期间滞回拒绝更远号令目标 → 不落穿：新出现的更近自主敌不被自选
	var late_near := _add_enemy(w["battle"], 50.0)
	var far_squad := _add_enemy(w["battle"], 320.0)
	acq.squad_target_fn = func() -> Node: return far_squad
	acq._dwell = 0.1
	acq._acquire_timer = -1.0
	t = acq.advance(0.1)
	_runner.assert_equal(t, squad_target, "滞回拒绝号令目标后维持当前目标（号令粘性）")
	_runner.assert_true(acq.get_target() != late_near, "集火期间不落穿自主寻敌（不偷选 50px 新敌）")
	_runner.assert_true(acq.get_target() != far_squad, "更远号令目标被滞回拦下")


func _test_post_guard() -> void:
	# 指挥官自主目标必须在追击带内：唯一候选超带 → 拒选（finish 待命自卫）
	var w := _make_acq([500.0])
	var acq: ScriptTargetAcquire = w["acq"]
	(w["entity"] as FakeUnit)._commander = true
	var t: Node = acq.advance(0.1)
	_runner.assert_true(t == null, "指挥官对超追击带候选拒选（留守不冲锋）")
	# 带内候选正常接敌（被近身自卫语义）
	var near := _add_enemy(w["battle"], 150.0)
	acq._acquire_timer = -1.0
	t = acq.advance(0.1)
	_runner.assert_equal(t, near, "指挥官对追击带内目标正常自卫接敌")


func _test_guard_post_unit() -> void:
	# 阵地护卫（02 一-A.4）：非指挥官守位者（guard_post）同享追击带门——
	# 留守阵地不冲锋，敌近身才自卫；且不触发斩首语义（is_commander 恒 false）
	var w := _make_acq([500.0])
	var acq: ScriptTargetAcquire = w["acq"]
	var unit := w["entity"] as FakeUnit
	unit._guard_post = true
	_runner.assert_false(unit.is_commander(), "护卫非指挥官（斩首登记不收）")
	var t: Node = acq.advance(0.1)
	_runner.assert_true(t == null, "护卫对超追击带候选拒选（守阵地不冲锋）")
	var near := _add_enemy(w["battle"], 150.0)
	acq._acquire_timer = -1.0
	t = acq.advance(0.1)
	_runner.assert_equal(t, near, "护卫对追击带内目标正常自卫接敌")
