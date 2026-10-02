extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：遇阻接战（创始人口径：前往任务目标的路上被敌人拦住且无法简单绕过，
## 就像一般 RTS 一样攻击路径上的敌人；寻路 = 局部绕行 + 遇阻接战组合，不做 A*；
## 命令粘性：接战拦路者是号令的临时插叙，击杀/脱离后恢复原号令目标）。
## ① 被拦且可绕 → 局部绕行不断战斗（横分量偏航、行为不 finish）
## ② 被拦不可绕（贴身）→ 攻击拦路者（打通态）→ 击杀后恢复原号令目标
## ③ 无拦路 → 直走不节外生枝
## ④ 远程被拦（射程内）→ 边走边射不停车

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptBehaviorMove := preload("res://modules/units/scripts/ai/behavior_move.gd")
const ScriptAIController := preload("res://modules/units/scripts/ai/ai_controller.gd")

var _runner: TestRunner


## 最小单位桩：ai_move 记录方向并按固定步长积分位移（不进场景树，确定性步进）
class FakeUnit:
	extends CharacterBody2D
	var faction_id: int = 1
	var battle: Node = null
	var weapon: Node = null
	var ai: Node = null
	var _dead: bool = false
	var last_dir := Vector2.ZERO
	var move_calls: int = 0
	var stop_calls: int = 0

	func get_faction() -> int:
		return faction_id

	func get_battle_instance() -> Node:
		return battle

	func get_map() -> Node2D:
		return null

	func get_weapon() -> Node:
		return weapon

	func get_ai_controller() -> Node:
		return ai

	func get_formation_system() -> Node:
		return null

	func is_dead() -> bool:
		return _dead

	func is_possessed() -> bool:
		return false

	func ai_stop() -> void:
		stop_calls += 1

	func ai_move(dir: Vector2, _run: bool) -> void:
		last_dir = dir
		move_calls += 1
		global_position += dir * 10.0  # 测试步进：每拍 10px


## 战斗桩：is_active + 敌我名单（无地图 → 走 _enemy_candidates 的战斗名单回落路径）
class StubBattle:
	extends Node
	var enemies: Array = []
	var allies: Array = []

	func is_active() -> bool:
		return true

	func get_enemies_of(_faction: int) -> Array:
		return enemies

	func get_allies_of(_faction: int) -> Array:
		return allies


## 武器桩（默认剑；attack_calls/last_target 供"向谁出手"断言）
class StubWeapon:
	extends Node
	var weapon_type: int = 0  # SWORD
	var attack_range: float = 100.0
	var attack_calls: int = 0
	var last_target: Node = null

	func can_attack() -> bool:
		return true

	func perform_attack(target: Node) -> void:
		attack_calls += 1
		last_target = target


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("遇阻: 被拦且可绕 → 局部绕行不断战斗", _test_detour_when_gap)
	_runner.add_test("遇阻: 被拦不可绕 → 攻击拦路者 → 击杀后恢复原号令", _test_breach_and_resume)
	_runner.add_test("遇阻: 无拦路 → 直走不节外生枝", _test_no_blocker_straight)
	_runner.add_test("遇阻: 远程被拦 → 边走边射不停车", _test_ranged_walk_and_shoot)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


## move 行为夹具（无 AIController：只测行为层几何/流程，不通到打通态）
func _make_move_ctx(target: Vector2) -> Dictionary:
	var unit := FakeUnit.new()
	unit.position = Vector2(0, 0)
	var battle := StubBattle.new()
	unit.battle = battle
	var beh: Node = ScriptBehaviorMove.new()
	beh.entity = unit
	beh.enter("", {"target": target})
	return {"unit": unit, "battle": battle, "beh": beh}


## 打通态全链路夹具（AIController 手工装配，先例 test_ai_retreat_modulation._Ctx）
func _make_breach_ctx() -> Dictionary:
	var unit := FakeUnit.new()
	unit.position = Vector2(0, 0)
	var weapon := StubWeapon.new()
	unit.weapon = weapon
	var battle := StubBattle.new()
	unit.battle = battle
	var ai: Node = ScriptAIController.new()
	ai._entity = unit  # 不进树直接注入（_ready cast 等价物，batch 准入：不进场景树）
	ai._setup_state_machine()
	unit.ai = ai
	return {"unit": unit, "battle": battle, "weapon": weapon, "ai": ai}


func _teardown_ctx(ctx: Dictionary, extra: Array = []) -> void:
	for key in ["unit", "battle", "beh", "ai", "weapon"]:
		if ctx.get(key) != null:
			ctx[key].free()
	for n in extra:
		if n != null and is_instance_valid(n):
			n.free()


## ① 被拦且可绕：单敌在前进锥面内、侧向有净空 → 叠加绕行横分量（侧别帧间稳定），
## 行为不 finish（不转战斗不清号令），保持向目标推进
func _test_detour_when_gap() -> void:
	var ctx := _make_move_ctx(Vector2(400, 0))
	var unit: FakeUnit = ctx["unit"]
	var beh: Node = ctx["beh"]
	var blocker := FakeUnit.new()
	blocker.faction_id = 2
	blocker.position = Vector2(150, 0)
	ctx["battle"].enemies.append(blocker)
	var side_sign: float = 0.0
	for i in 6:
		beh.update(0.1)
		if i == 0:
			_runner.assert_true(absf(unit.last_dir.y) > 0.01, "被拦且有侧隙应叠加绕行横分量")
			side_sign = signf(unit.last_dir.y)
		else:
			_runner.assert_true(signf(unit.last_dir.y) == side_sign, "绕行侧应帧间稳定不抖")
		_runner.assert_false(beh.is_finished(), "绕行期不应 finish（不断战斗）")
		_runner.assert_true(unit.stop_calls == 0, "绕行期不应停车")
	_runner.assert_true(unit.move_calls > 0, "绕行期保持移动意图")
	_runner.assert_true(unit.global_position.x > 0.0, "绕行同时仍向目标推进")
	_teardown_ctx(ctx, [blocker])


## ② 被拦不可绕：敌贴身（≤ 接触距离，绕行无物理空隙）→ 请求打通接战；
## 号令粘性（原号令不清不降级）；出手对象 = 拦路者；击杀后恢复原号令目标直走
func _test_breach_and_resume() -> void:
	var ctx := _make_breach_ctx()
	var unit: FakeUnit = ctx["unit"]
	var ai: Node = ctx["ai"]
	var battle: StubBattle = ctx["battle"]
	var weapon: StubWeapon = ctx["weapon"]
	var blocker := FakeUnit.new()
	blocker.faction_id = 2
	blocker.position = Vector2(60, 0)  # 贴身（≤70 接触距离）：无法简单绕过
	battle.enemies.append(blocker)
	ai.set_order("move", {"target": Vector2(400, 0)})
	_runner.assert_true(ai.has_order(), "前置：move 号令已下达")
	# 行进拍：扫描判贴身拦路 → 转入攻击拦路者（打通态）
	ai.get_state_machine().physics_update(0.1)
	_runner.assert_equal(ai.get_current_behavior(), "attack", "贴身拦路应转入攻击拦路者")
	_runner.assert_true(ai.is_breach_engaged(), "打通态应置位")
	_runner.assert_true(ai.has_order(), "号令粘性：打通期原号令不清空")
	_runner.assert_equal(ai.get_ordered_params().get("target", Vector2.ZERO), Vector2(400, 0),
			"号令粘性：原目标参数不降级")
	_runner.assert_equal(ai.get_state_machine().get("_current_behavior").get("_forced_target"),
			blocker, "攻击行为应锁定拦路者（forced_target）")
	# 攻击拍：向拦路者出手（hesitate 掷骰有随机窗，循环推进到出手消抖）
	var attacked: bool = false
	for i in 40:
		ai.get_state_machine().physics_update(0.1)
		ai._make_decision()
		if weapon.attack_calls > 0:
			attacked = true
			break
	_runner.assert_true(attacked, "打通期应向拦路者出手")
	_runner.assert_equal(weapon.last_target, blocker, "出手对象应为拦路者")
	# 决策拍：拦路者仍活 → 维持打通攻击不翻令
	ai._make_decision()
	_runner.assert_equal(ai.get_current_behavior(), "attack", "拦路者未死应维持打通攻击")
	# 击杀 → 打通态清位，恢复原号令（目标不变）继续赶路
	blocker._dead = true
	ai._make_decision()
	_runner.assert_false(ai.is_breach_engaged(), "击杀后打通态应清位")
	_runner.assert_equal(ai.get_current_behavior(), "move", "击杀后应恢复原移动号令")
	_runner.assert_equal(ai.get_ordered_params().get("target", Vector2.ZERO), Vector2(400, 0),
			"恢复的目标点仍是原号令目标")
	ai.get_state_machine().physics_update(0.1)
	_runner.assert_true(unit.last_dir.x > 0.9 and absf(unit.last_dir.y) < 0.01,
			"恢复后直走原目标（无残存绕行分量）")
	_teardown_ctx(ctx, [blocker])


## ③ 无拦路：锥面外（身后）的敌人不构成拦路 → 直走，无绕行分量不接战
func _test_no_blocker_straight() -> void:
	var ctx := _make_move_ctx(Vector2(400, 0))
	var unit: FakeUnit = ctx["unit"]
	var beh: Node = ctx["beh"]
	var rear := FakeUnit.new()
	rear.faction_id = 2
	rear.position = Vector2(-100, 0)  # 身后：锥面外
	ctx["battle"].enemies.append(rear)
	for i in 5:
		beh.update(0.1)
		_runner.assert_true(absf(unit.last_dir.y) < 0.001, "无拦路应直走（无绕行分量）")
		_runner.assert_true(unit.last_dir.x > 0.9, "直走应朝目标推进")
		_runner.assert_false(beh.is_finished(), "途中不应 finish")
	_runner.assert_true(unit.global_position.x >= 40.0, "无拦路时净推进不被干扰")
	_teardown_ctx(ctx, [rear])


## ④ 远程被拦：弓射程内锥面有敌 → 边走边射（不停车出手 + 保持向目标推进 +
## 行为不 finish 清号令）
func _test_ranged_walk_and_shoot() -> void:
	var ctx := _make_move_ctx(Vector2(400, 0))
	var unit: FakeUnit = ctx["unit"]
	var beh: Node = ctx["beh"]
	var weapon := StubWeapon.new()
	weapon.weapon_type = 2  # BOW
	weapon.attack_range = 500.0
	unit.weapon = weapon
	var blocker := FakeUnit.new()
	blocker.faction_id = 2
	blocker.position = Vector2(150, 0)  # 锥面内、射程内
	ctx["battle"].enemies.append(blocker)
	var x0: float = unit.global_position.x
	var attacked: bool = false
	for i in 10:
		beh.update(0.1)
		if weapon.attack_calls > 0:
			attacked = true
		_runner.assert_false(beh.is_finished(), "走射期不应 finish 清号令")
		_runner.assert_true(unit.stop_calls == 0, "走射期不停车")
	_runner.assert_true(attacked, "远程被拦应边走边射（射程内出手）")
	_runner.assert_equal(weapon.last_target, blocker, "走射对象应为拦路者")
	_runner.assert_true(unit.global_position.x > x0, "走射期应保持向目标推进（不停车）")
	_teardown_ctx(ctx, [blocker])
