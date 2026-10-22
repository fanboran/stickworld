extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：找目标系统（米拉奇锁定到死口径，裁决#35；选举/过滤 SWL 直译）。
## 覆盖：最近敌选举 / 锁定到死（更近者出现不换靶）/ 目标死亡即换 /
## 无距离门（远敌也锁）/ 强制目标（打通态）生命周期。
## （守位者守卫用例随摆场指挥官/护卫根除一并退役，2026-10-14）
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

	func get_weapon() -> FakeWeapon:
		return weapon

	func get_faction() -> int:
		return faction_id

	func is_dead() -> bool:
		return false


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
	_runner.add_test("选举: 最近敌当选", _test_nearest)
	_runner.add_test("无距离门: 远敌也锁（追击最近敌）", _test_far_target_chase)
	_runner.add_test("死亡: 目标死亡即时重选", _test_dead_re_elect)
	_runner.add_test("锁定到死: 更近者出现不换靶", _test_lock_keeps_on_nearer)
	_runner.add_test("锁定到死: 目标走远仍追（无距离门）", _test_lock_keeps_on_far)
	_runner.add_test("强制目标: 注入即锁 失效回落", _test_forced_target)
	_runner.add_test("强制目标: 存活即锁（距离由打通态脱离距离管）", _test_forced_beyond_keeps)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────── 夹具 ────────────────────────

## 构造 helper：实体在原点（射程 100 / 仇恨半径 ×4 = 400），profile 全基线回退
func _make_acq(enemies_at: Array = []) -> Dictionary:
	var entity: FakeUnit = _runner.track_node(FakeUnit.new())
	_runner.track_node(entity.weapon)  # 桩内初始化的武器节点无父节点，单独登记
	entity.position = Vector2(0, 0)
	var battle: FakeBattle = _runner.track_node(FakeBattle.new())
	for x in enemies_at:
		var e: FakeEnemy = _runner.track_node(FakeEnemy.new())
		e.position = Vector2(float(x), 0)
		battle.enemies.append(e)
	var acq: ScriptTargetAcquire = ScriptTargetAcquire.new()
	acq.setup(entity, battle, {})
	return {"acq": acq, "entity": entity, "battle": battle}


func _add_enemy(battle: FakeBattle, x: float) -> FakeEnemy:
	var e: FakeEnemy = _runner.track_node(FakeEnemy.new())
	e.position = Vector2(x, 0)
	battle.enemies.append(e)
	return e


# ─────────────────────── 用例 ────────────────────────

func _test_nearest() -> void:
	var w := _make_acq([300.0, 150.0])
	var acq: ScriptTargetAcquire = w["acq"]
	var t: Node = acq.advance(0.1)
	_runner.assert_equal(t, w["battle"].enemies[1], "首拍选最近敌（150px）")


func _test_far_target_chase() -> void:
	# 裁决#31：无距离门——远敌也锁（创始人「优先追击最近的敌人」）
	var w := _make_acq([500.0])
	var acq: ScriptTargetAcquire = w["acq"]
	var t: Node = acq.advance(0.1)
	_runner.assert_equal(t, w["battle"].enemies[0], "唯一候选即使 500px 也锁（追击）")
	_runner.assert_false(acq.is_beyond_leash(), "无距离门口径下恒不追丢")


func _test_dead_re_elect() -> void:
	var w := _make_acq([150.0, 300.0])
	var acq: ScriptTargetAcquire = w["acq"]
	var t: Node = acq.advance(0.1)
	_runner.assert_equal(t, w["battle"].enemies[0], "前置：最近敌当选")
	(w["battle"].enemies[0] as FakeEnemy)._dead = true
	t = acq.advance(0.1)
	_runner.assert_equal(t, w["battle"].enemies[1], "目标死亡立即重选（锁定到死，死亡是唯一换靶边）")


func _test_lock_keeps_on_nearer() -> void:
	# 裁决#35 米拉奇口径：目标活着，更近者出现也不换——0.5s 例行「最近者得」
	# 刷新已退役（换靶抖动 = 出手半途掉头/两等距敌间横跳的根源）
	var w := _make_acq([150.0])
	var acq: ScriptTargetAcquire = w["acq"]
	var first: Node = acq.advance(0.1)
	_runner.assert_equal(first, w["battle"].enemies[0], "前置：150px 敌当选")
	var nearer := _add_enemy(w["battle"], 90.0)
	for i in 5:
		acq.advance(0.1)
	_runner.assert_equal(acq.get_target(), first, "更近者出现不换靶（锁定到死）")
	# 目标死亡才让位
	(first as FakeEnemy)._dead = true
	acq.advance(0.1)
	_runner.assert_equal(acq.get_target(), nearer, "原目标死亡 → 重选更近者上位")


func _test_lock_keeps_on_far() -> void:
	# 目标走远不弃追（无距离门）：锁定到死 + 无距离门 = 走到哪追到哪
	var w := _make_acq([150.0])
	var acq: ScriptTargetAcquire = w["acq"]
	var first: Node = acq.advance(0.1)
	(first as FakeEnemy).position = Vector2(450.0, 0)
	for i in 5:
		acq.advance(0.1)
	_runner.assert_equal(acq.get_target(), first, "目标走远仍锁（追击语义，不受距离门）")


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
	t = acq.advance(0.1)
	_runner.assert_equal(t, near, "强制目标失效后回落自主寻敌")


func _test_forced_beyond_keeps() -> void:
	# 裁决#31 无距离门：强制目标存活即锁（跑远的拦路者由 ai_controller 的
	# 打通态脱离距离 BREACH_DROP_DIST 清态，不在锁定层管）
	var w := _make_acq([150.0])
	var acq: ScriptTargetAcquire = w["acq"]
	var forced := _add_enemy(w["battle"], 320.0)
	acq.set_forced_target(forced)
	forced.position = Vector2(450.0, 0)
	var t: Node = acq.advance(0.1)
	_runner.assert_equal(t, forced, "强制目标走远仍锁（脱离交给打通态距离门）")
