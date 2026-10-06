extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：AI 完善项批次 1——目标选择增强。
## 1.1 防集火重叠：battle 攻击者计数（register/unregister/死亡清理）+ TargetFinder 过滤 + 兜底
## 1.2 追击范围 leash：target_acquire（P1 拆分自 behavior_attack）目标超攻击范围 × 追击倍数判"追丢"
## 不进场景树，确定性。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptBattleInstance := preload("res://modules/combat/scripts/battle/battle_instance.gd")
const ScriptTargetFinder := preload("res://modules/tactics/scripts/target_finder.gd")
const ScriptBehaviorAttack := preload("res://modules/units/scripts/ai/behavior_attack.gd")
const ScriptTargetAcquire := preload("res://modules/units/scripts/ai/target_acquire.gd")

var _runner: TestRunner


class FakeUnit:
	extends CharacterBody2D
	var faction_id: int = 0
	var battle: Node = null
	var formation: Node = null
	var _dead: bool = false
	var health: Node = null
	var stun: bool = false
	var stop_calls: int = 0

	func set_faction(fid: int) -> void:
		faction_id = fid

	func get_faction() -> int:
		return faction_id

	func set_battle_instance(bi: Node) -> void:
		battle = bi

	func get_battle_instance() -> Node:
		return battle

	func get_health() -> Node:
		return health

	func get_weapon() -> Node:
		return null

	func get_formation_system() -> Node:
		return formation

	func is_dead() -> bool:
		return _dead

	func is_in_hit_stun() -> bool:
		return stun

	func ai_stop() -> void:
		stop_calls += 1

	func ai_move(_dir: Vector2, _run: bool) -> void:
		pass


class FakeHealth:
	extends Node
	var _hp_ratio: float = 1.0

	func get_hp_ratio() -> float:
		return _hp_ratio


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("攻击者计数: register 去重 + count", _test_register)
	_runner.add_test("攻击者计数: 目标死亡清理", _test_died_cleanup)
	_runner.add_test("攻击者计数: unregister 递减", _test_unregister)
	_runner.add_test("TargetFinder: 防集火过滤超限目标", _test_finder_filter)
	_runner.add_test("TargetFinder: 全被围攻时兜底最近", _test_finder_fallback)
	_runner.add_test("TargetFinder: only_forward 背后之敌不可为目", _test_finder_forward_only)
	_runner.add_test("TargetFinder: only_forward 兜底不越半平面", _test_finder_forward_fallback)
	_runner.add_test("追击范围: 超 leash 判追丢", _test_leash_far)
	_runner.add_test("追击范围: 未超 leash 不追丢", _test_leash_near)
	_runner.add_test("受击硬直: 硬直中停止行动", _test_hit_stun)
	_runner.add_test("目标锁定: sticky 保留当前目标", _test_sticky_target)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


## 构造真实 battle_instance + 假单位（battle/map 进树，cover_system 需要 tree）
func _make_battle() -> Dictionary:
	var map := Node2D.new()
	map.name = "TestMap"
	add_child(map)
	var battle: Node = ScriptBattleInstance.new()
	battle.name = "TestBattle"
	add_child(battle)
	battle.setup(map)
	battle.start()  # PREPARING -> ENGAGED（behavior.update 需 is_active）
	var a := FakeUnit.new()
	a.name = "Attacker"
	a.position = Vector2(0, 0)
	var b1 := FakeUnit.new()
	b1.name = "Enemy1"
	b1.faction_id = 2
	b1.position = Vector2(100, 0)
	var b2 := FakeUnit.new()
	b2.name = "Enemy2"
	b2.faction_id = 2
	b2.position = Vector2(200, 0)
	battle.add_unit(a, 1)
	battle.add_unit(b1, 2)
	battle.add_unit(b2, 2)
	return {"battle": battle, "attacker": a, "e1": b1, "e2": b2}


func _test_register() -> void:
	var w: Dictionary = _make_battle()
	var battle: Node = w["battle"]
	var a: FakeUnit = w["attacker"]
	var e1: FakeUnit = w["e1"]
	var e2: FakeUnit = w["e2"]
	battle.register_attacker(e1, a)
	battle.register_attacker(e1, a)  # 重复登记去重
	battle.register_attacker(e1, e2)  # 不同攻击者
	_runner.assert_equal(battle.get_attacker_count(e1), 2, "两个不同攻击者应计 2")
	_runner.assert_equal(battle.get_attacker_count(e2), 0, "未被攻击的目标应计 0")


func _test_died_cleanup() -> void:
	var w: Dictionary = _make_battle()
	var battle: Node = w["battle"]
	var a: FakeUnit = w["attacker"]
	var e1: FakeUnit = w["e1"]
	battle.register_attacker(e1, a)
	battle.on_unit_died(e1)
	_runner.assert_equal(battle.get_attacker_count(e1), 0, "目标死亡后计数应清零")


func _test_unregister() -> void:
	var w: Dictionary = _make_battle()
	var battle: Node = w["battle"]
	var a: FakeUnit = w["attacker"]
	var e1: FakeUnit = w["e1"]
	var e2: FakeUnit = w["e2"]
	battle.register_attacker(e1, a)
	battle.register_attacker(e1, e2)
	battle.unregister_attacker(e1, a)
	_runner.assert_equal(battle.get_attacker_count(e1), 1, "撤销一个攻击者后应计 1")


func _test_finder_filter() -> void:
	var w: Dictionary = _make_battle()
	var battle: Node = w["battle"]
	var a: FakeUnit = w["attacker"]
	var e1: FakeUnit = w["e1"]
	var e2: FakeUnit = w["e2"]
	# e1 被 3 个不同攻击者围攻（≥ max_attackers 3）→ 应被过滤，选 e2
	var extra1 := FakeUnit.new()
	var extra2 := FakeUnit.new()
	battle.register_attacker(e1, a)
	battle.register_attacker(e1, extra1)
	battle.register_attacker(e1, extra2)
	_runner.assert_equal(battle.get_attacker_count(e1), 3, "前置：e1 应有 3 个攻击者")
	var t: Node = ScriptTargetFinder.find_target(a, { "battle": battle, "ignore_current_attackers": true })
	_runner.assert_equal(t, e2, "被围攻目标应被过滤，选 e2")


func _test_finder_fallback() -> void:
	var w: Dictionary = _make_battle()
	var battle: Node = w["battle"]
	var a: FakeUnit = w["attacker"]
	var e1: FakeUnit = w["e1"]
	# 唯一目标被围攻 → 兜底仍选它（避免无人攻击）
	battle.register_attacker(e1, a)
	battle.register_attacker(e1, a)
	battle.register_attacker(e1, a)
	var t: Node = ScriptTargetFinder.find_target(a, { "battle": battle, "ignore_current_attackers": true })
	_runner.assert_equal(t, e1, "唯一目标即使被围攻也应兜底选中")


## 前向过滤（SWL OnlyTargetsUnitsForward/IsValidForForwardOnlyTarget 直译）：
## 背后之敌不可为目——混战线互穿后"全图最近"落在背后 = 掉头对穿（左右横跑主因）
func _test_finder_forward_only() -> void:
	var w: Dictionary = _make_battle()
	var battle: Node = w["battle"]
	var a: FakeUnit = w["attacker"]
	var e1: FakeUnit = w["e1"]      # (100,0) 身前（facing 默认 1）
	var e2: FakeUnit = w["e2"]      # (200,0) 身前
	var behind := FakeUnit.new()    # (-150,0) 背后且更近
	behind.name = "EnemyBehind"
	behind.faction_id = 2
	behind.position = Vector2(-150, 0)
	battle.add_unit(behind, 2)
	# 只开前向过滤：背后虽最近（150px vs e1 100px——把 e1 挪远加大反差）也不可选
	e1.position = Vector2(400, 0)
	e2.position = Vector2(500, 0)
	var t: Node = ScriptTargetFinder.find_target(a, {
		"battle": battle, "ignore_current_attackers": true, "only_forward": true })
	_runner.assert_equal(t, e1, "背后之敌更近也不可选，应选身前的 e1")
	# 全部敌人在背后 → 返回 null（不兜底回头）
	e1.position = Vector2(-200, 0)
	e2.position = Vector2(-300, 0)
	t = ScriptTargetFinder.find_target(a, {
		"battle": battle, "ignore_current_attackers": true, "only_forward": true })
	_runner.assert_true(t == null, "全部候选在背后应返回 null，不可掉头选背后敌")


## 前向过滤的兜底边界：前向候选存在但全被围攻 → 兜底只在前向池内挑，
## 不得扫到背后
func _test_finder_forward_fallback() -> void:
	var w: Dictionary = _make_battle()
	var battle: Node = w["battle"]
	var a: FakeUnit = w["attacker"]
	var e1: FakeUnit = w["e1"]      # 身前，被围攻超限
	var e2: FakeUnit = w["e2"]      # 身前，无围攻
	var behind := FakeUnit.new()    # 背后最近
	behind.name = "EnemyBehind2"
	behind.faction_id = 2
	behind.position = Vector2(-50, 0)
	battle.add_unit(behind, 2)
	# e1 围攻超限需 3 个**不同**攻击者（register_attacker 同者去重，见 _test_register）
	var extra1 := FakeUnit.new()
	var extra2 := FakeUnit.new()
	battle.register_attacker(e1, a)
	battle.register_attacker(e1, extra1)
	battle.register_attacker(e1, extra2)
	var t: Node = ScriptTargetFinder.find_target(a, {
		"battle": battle, "ignore_current_attackers": true, "only_forward": true })
	_runner.assert_equal(t, e2, "前向候选被围攻滤空后兜底应选前向的 e2，不得回头选背后敌")


func _test_leash_far() -> void:
	var w: Dictionary = _make_battle()
	# P1 拆分：追击判定本体在 target_acquire（tier_of 分层），直测 helper
	var acq: ScriptTargetAcquire = ScriptTargetAcquire.new()
	acq.setup(w["attacker"], w["battle"], {})
	# 目标在 500px 外（attack_range 默认 100 × 4 = 400）→ 超 leash
	var far := FakeUnit.new()
	far.position = Vector2(500, 0)
	acq._target = far
	_runner.assert_true(acq.is_beyond_leash(), "目标超攻击范围×4 应判追丢")


func _test_leash_near() -> void:
	var w: Dictionary = _make_battle()
	var acq: ScriptTargetAcquire = ScriptTargetAcquire.new()
	acq.setup(w["attacker"], w["battle"], {})
	# 目标在 150px 内 → 不超 leash
	var near := FakeUnit.new()
	near.position = Vector2(150, 0)
	acq._target = near
	_runner.assert_false(acq.is_beyond_leash(), "目标在攻击范围×4 内不应判追丢")


## 受击硬直：behavior_attack 在 entity 硬直时停止行动（ai_stop 被调、不推进攻击）
func _test_hit_stun() -> void:
	var w: Dictionary = _make_battle()
	var attacker: FakeUnit = w["attacker"]
	var e1: FakeUnit = w["e1"]
	e1.position = Vector2(100, 0)  # 攻击范围内
	var beh: Node = ScriptBehaviorAttack.new()
	beh.entity = attacker
	beh.enter("", {"battle": w["battle"]})
	attacker.stun = true
	beh.update(0.01)
	_runner.assert_true(attacker.stop_calls > 0, "硬直中应调 ai_stop 停止")
	_runner.assert_true(beh._target == null, "硬直中不应推进目标获取")
	attacker.stun = false
	# 硬直瞬间 30% 概率触发规避小跳（_evade_hold 0.35s，期间不获取目标）——
	# 推进到规避窗口耗尽再断言，消除随机路径的偶发红
	for i in 40:
		beh.update(0.01)
		if beh._target != null:
			break
	_runner.assert_true(beh._target != null, "硬直结束后应恢复目标获取")


## sticky target：当前目标有效未超 leash，刷新周期保留不重选
func _test_sticky_target() -> void:
	var w: Dictionary = _make_battle()
	var attacker: FakeUnit = w["attacker"]
	var e1: FakeUnit = w["e1"]
	var e2: FakeUnit = w["e2"]
	var beh: Node = ScriptBehaviorAttack.new()
	beh.entity = attacker
	beh.enter("", {"battle": w["battle"]})
	beh.update(0.01)  # 首次刷新选目标（最近 = e1，100px）
	var first: Node = beh._target
	_runner.assert_true(first != null, "首次应选到目标")
	# 强制刷新周期到期，目标仍有效 → 驻留+滞回保留（P1 后判定本体在 _acq）
	beh._acq._acquire_timer = -1.0
	beh.update(0.01)
	_runner.assert_equal(beh._target, first, "目标有效时应 sticky 保留不换")
