extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：批5 远程槽位锚定（提前落地的远程部分）。
## 覆盖：班战斗锚（接战冻结/外生锚语义/脱战清除/危险重冻结）+ get_unit_combat_slot
## 槽位查询 + behavior_attack 射程内锚定驻防（走向槽位/死区站定/近身危险带不回槽/
## 无锚零回归/近战不锚定）。
## 确定性：掷骰路径全隔离（hesitate_prob 档案置 0 + strafe 计时器拨远）；
## 不进场景树（_process 不触发，tick 直调 + 足量 delta）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptFormationSystem := preload("res://modules/formation/scripts/formation_system.gd")
const ScriptBehaviorProfiles := preload("res://modules/units/scripts/ai/behavior_profiles.gd")
const ScriptBehaviorAttack := preload("res://modules/units/scripts/ai/behavior_attack.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("战斗锚: 接战冻结（班质心+平均面向）/ 槽位查询", _test_anchor_freeze_and_slot)
	_runner.add_test("战斗锚: 脱战清除（无槽位回落 INF）", _test_anchor_clear)
	_runner.add_test("战斗锚: 危险重冻结（敌压锚线 → 当前质心重冻结）", _test_anchor_danger_refreeze)
	_runner.add_test("行为: 远程射程内走向槽位（边走边射不站桩）", _test_behavior_walk_to_slot)
	_runner.add_test("行为: 槽位死区内站定", _test_behavior_hold_at_slot)
	_runner.add_test("行为: 近身危险带——敌近侧槽禁走 / 敌远侧槽放行", _test_behavior_danger_band)
	_runner.add_test("行为: 锚定期接敌改道（射程外走槽不压敌 / 到槽待敌 / 无锚恢复）", _test_behavior_approach_via_slot)
	_runner.add_test("行为: 无锚/近战零回归（站桩语义不变）", _test_behavior_regression)
	_runner.add_test("跟队: 战斗锚定期整班跳过（不与槽位收拢互拔）", _test_follow_skips_anchored)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────── 编队侧：战斗锚 ───────────────────────

func _test_anchor_freeze_and_slot() -> void:
	var fx := _make_fixture()
	# 4 人沿 y 散开（射程内有敌 → 接战）：质心 (100, 650)
	fs_tick(fx.fs, 1.0)
	var anchor: Dictionary = fx.fs._squads[fx.sid].get("combat_anchor", {})
	_runner.assert_false(anchor.is_empty(), "接战班应冻结战斗锚")
	if anchor.is_empty():
		fx.teardown()
		return
	_runner.assert_approx(float(anchor["pos"].x), 100.0, 0.5, "锚 x = 接战时班质心 x")
	_runner.assert_approx(float(anchor["pos"].y), 650.0, 0.5, "锚 y = 接战时班质心 y")
	_runner.assert_approx(float(anchor["facing"].x), 1.0, 0.01, "锚面向 = 成员平均面向（+x）")
	# 槽位查询：u0 槽 = 前列 row0（锚点横展 −1.5×SPREAD）
	var slot: Vector2 = fx.fs.get_unit_combat_slot(fx.units[0])
	_runner.assert_false(is_inf(slot.x), "锚定期槽位应有效")
	_runner.assert_approx(slot.x, 100.0, 0.5, "前列槽位贴锚线（x = 锚 x）")
	_runner.assert_approx(slot.y, 650.0 - 1.5 * fx.fs.SPREAD_SPACING, 0.5,
			"前列 row0 横展 −1.5×SPREAD")
	# 外班成员无锚可查（INF 回落）
	var stranger := Node2D.new()
	_runner.assert_true(is_inf(fx.fs.get_unit_combat_slot(stranger).x), "无班成员槽位 = INF")
	stranger.free()
	fx.teardown()


func _test_anchor_clear() -> void:
	var fx := _make_fixture()
	fs_tick(fx.fs, 1.0)
	_runner.assert_false(fx.fs._squads[fx.sid].get("combat_anchor", {}).is_empty(), "接战冻结")
	# 敌人撤出射程（全员脱战）→ 清锚
	fx.enemy.global_position = Vector2(5000.0, 650.0)
	fs_tick(fx.fs, 1.0)
	_runner.assert_true(fx.fs._squads[fx.sid].get("combat_anchor", {}).is_empty(),
			"脱战后战斗锚应清除")
	_runner.assert_true(is_inf(fx.fs.get_unit_combat_slot(fx.units[0]).x),
			"清锚后槽位查询回落 INF（消费方回原站桩语义）")
	fx.teardown()


func _test_anchor_danger_refreeze() -> void:
	var fx := _make_fixture()
	fs_tick(fx.fs, 1.0)
	var frozen_x: float = float(fx.fs._squads[fx.sid]["combat_anchor"]["pos"].x)
	# 敌压锚线（< 最短射程 650 × 0.4 = 260）+ 全班后撤 80px（模拟有序后撤中）
	fx.enemy.global_position = Vector2(frozen_x + 100.0, 650.0)
	for u in fx.units:
		u.global_position += Vector2(-80.0, 0.0)
	fs_tick(fx.fs, 1.0)
	var refrozen: Dictionary = fx.fs._squads[fx.sid].get("combat_anchor", {})
	_runner.assert_false(refrozen.is_empty(), "危险重冻结后锚仍在")
	_runner.assert_approx(float(refrozen["pos"].x), frozen_x - 80.0, 0.5,
			"危险重冻结 = 当前质心（锚随方阵后移，外生重置）")
	fx.teardown()


# ─────────────────────── 行为侧：锚定驻防 ───────────────────────

func _test_behavior_walk_to_slot() -> void:
	var ctx := _make_behavior_ctx(ScriptBehaviorProfiles.BOW)
	# 实体 (500,400)，锚 (500,300) → 槽 (500, 300−1.5×SPREAD)（距槽 > 死区 48）
	ctx.attack.update(0.016)
	var moved: bool = ctx.entity.last_move.length_squared() > 0.001
	_runner.assert_true(moved, "距槽位超死区应走向槽位（不站桩）")
	if moved:
		var want: Vector2 = (ctx.slot - ctx.entity.global_position).normalized()
		_runner.assert_approx(ctx.entity.last_move.normalized().dot(want), 1.0, 0.01,
				"走向方向 = 指向自身槽位")
		_runner.assert_false(ctx.entity.last_run, "百像素级距离走步归位（不奔跑）")
	ctx.teardown()


func _test_behavior_hold_at_slot() -> void:
	var ctx := _make_behavior_ctx(ScriptBehaviorProfiles.BOW)
	# 挪到槽位死区内（48px）→ 站定
	ctx.entity.global_position = ctx.slot + Vector2(10.0, 0.0)
	ctx.entity.stopped = false
	ctx.entity.last_move = Vector2.ZERO
	ctx.attack.update(0.016)
	_runner.assert_true(ctx.entity.stopped, "死区内应站定（ai_stop）")
	_runner.assert_true(ctx.entity.last_move.length_squared() < 0.001,
			"死区内不再发 ai_move（防槽位抖动）")
	ctx.teardown()


func _test_behavior_danger_band() -> void:
	# 敌近侧槽（锚注到实体与敌之间，槽落在敌近侧）：危险带内（250 <
	# kite 180×1.5=270，未到风筝线）禁走（迎着贴脸敌回槽），站定
	var ctx := _make_behavior_ctx(ScriptBehaviorProfiles.BOW)
	ctx.fs._squads[ctx.sid]["combat_anchor"] = {"pos": Vector2(700.0, 400.0), "facing": Vector2.RIGHT}
	ctx.slot = ctx.fs.get_unit_combat_slot(ctx.entity)
	ctx.enemy.global_position = ctx.entity.global_position + Vector2(250.0, 0.0)
	ctx.entity.stopped = false
	ctx.entity.last_move = Vector2.ZERO
	ctx.attack.update(0.016)
	_runner.assert_true(ctx.entity.stopped, "敌近侧槽：危险带内站定不回槽")
	_runner.assert_true(ctx.entity.last_move.length_squared() < 0.001, "敌近侧槽：不发 ai_move")
	ctx.teardown()
	# 敌远侧槽（槽背向敌）：后撤归位永远合法——危险重冻结后方阵整体后撤的
	# 走位来源（槽位到敌距离 > 自身到敌距离 + 20）
	var ctx2 := _make_behavior_ctx(ScriptBehaviorProfiles.BOW)
	ctx2.enemy.global_position = ctx2.entity.global_position + Vector2(250.0, 0.0)
	ctx2.entity.stopped = false
	ctx2.entity.last_move = Vector2.ZERO
	ctx2.attack.update(0.016)
	var moved2: bool = ctx2.entity.last_move.length_squared() > 0.001
	_runner.assert_true(moved2, "敌远侧槽：危险带内仍归位（后撤方向合法）")
	if moved2:
		var want2: Vector2 = (ctx2.slot - ctx2.entity.global_position).normalized()
		_runner.assert_approx(ctx2.entity.last_move.normalized().dot(want2), 1.0, 0.01,
				"归位方向 = 指向自身槽位")
	ctx2.teardown()


func _test_behavior_approach_via_slot() -> void:
	var ctx := _make_behavior_ctx(ScriptBehaviorProfiles.BOW)
	# 敌拉出射程（dist 900 > 650）：锚定期接敌改道 → 走向槽位而非敌阵
	ctx.enemy.global_position = Vector2(1400.0, 400.0)
	ctx.entity.stopped = false
	ctx.entity.last_move = Vector2.ZERO
	ctx.attack.update(0.016)
	var want: Vector2 = (ctx.slot - ctx.entity.global_position).normalized()
	_runner.assert_approx(ctx.entity.last_move.normalized().dot(want), 1.0, 0.01,
			"射程外锚定期走向槽位（不压向敌阵）")
	# 到槽死区内：站定待敌（不追敌不空走）
	ctx.entity.global_position = ctx.slot
	ctx.entity.stopped = false
	ctx.entity.last_move = Vector2.ONE
	ctx.attack.update(0.016)
	_runner.assert_true(ctx.entity.stopped, "到槽站定待敌")
	# 无锚：恢复常态接敌（压向目标攻击环）
	ctx.fs._squads[ctx.sid].erase("combat_anchor")
	ctx.entity.global_position = Vector2(500.0, 400.0)
	ctx.entity.stopped = false
	ctx.entity.last_move = Vector2.ZERO
	ctx.attack.update(0.016)
	var to_enemy: Vector2 = (ctx.enemy.global_position - ctx.entity.global_position).normalized()
	_runner.assert_approx(ctx.entity.last_move.normalized().dot(to_enemy), 1.0, 0.05,
			"无锚恢复常态接敌（压向目标）")
	ctx.teardown()


func _test_behavior_regression() -> void:
	# 无锚（清锚）→ 原站桩语义
	var ctx := _make_behavior_ctx(ScriptBehaviorProfiles.BOW)
	ctx.fs._squads[ctx.sid].erase("combat_anchor")
	ctx.entity.stopped = false
	ctx.attack.update(0.016)
	_runner.assert_true(ctx.entity.stopped, "无锚远程单位照旧站桩（零回归）")
	ctx.teardown()
	# 近战（SWORD）：有锚也不锚定（槽位锚定只属远程）
	var ctx2 := _make_behavior_ctx(ScriptBehaviorProfiles.SWORD)
	ctx2.entity.global_position = Vector2(500.0, 400.0)  # 距槽远（若锚定必发 move）
	ctx2.entity.stopped = false
	ctx2.entity.last_move = Vector2.ZERO
	ctx2.attack.update(0.016)
	_runner.assert_true(ctx2.entity.stopped, "近战不消费槽位（站桩语义）")
	_runner.assert_true(ctx2.entity.last_move.length_squared() < 0.001,
			"近战无槽位走位（攻击环接敌由既有逻辑负责）")
	ctx2.teardown()


func _test_follow_skips_anchored() -> void:
	# 前班 1 人（100,650，敌射程内=接战）+ 后班 1 人（0,650，挂跟队 + 记录 AI）：
	# 后班锚定期 → update_follows 不下号令（槽位收拢接管）；清锚 → 恢复跟队号令
	var fx := _make_fixture()
	var rear := FakeUnit.new()
	rear.global_position = Vector2(0.0, 650.0)
	var rw := FakeWeapon.new()
	rw.weapon_type = ScriptBehaviorProfiles.BOW
	rear.weapon = rw
	rear.add_child(rw)
	rear.battle = fx.battle
	var ai := FakeAI.new()
	rear.ai = ai
	rear.add_child(ai)
	var rear_sid: String = fx.fs.create_squad([rear], "后队")
	_runner.assert_true(fx.fs.set_squad_follow_squad(rear_sid, fx.sid, 200.0), "挂跟队")
	# 挂链即立即落一次位（set_squad_follow_squad 内联 update）——基线取挂链后
	var baseline: int = ai.orders.size()
	# 白盒注入战斗锚 → 跳过
	fx.fs._squads[rear_sid]["combat_anchor"] = {"pos": Vector2(0.0, 650.0), "facing": Vector2.RIGHT}
	fx.fs._update_squad_follows()
	_runner.assert_equal(ai.orders.size(), baseline, "锚定期跟队不下号令（不与槽位收拢互拔）")
	# 清锚 → 恢复：前队质心挪动让跟队落点漂出死区（否则去重正确地不重发）
	fx.fs._squads[rear_sid].erase("combat_anchor")
	fx.units[0].global_position += Vector2(400.0, 0.0)
	fx.fs._update_squad_follows()
	_runner.assert_true(ai.orders.size() > baseline, "清锚恢复跟队号令")
	rear.free()
	fx.teardown()


# ─────────────────────── 夹具 ───────────────────────

## 假组织 API（复刻 test_formation_slots 的 FakeOrgApi）
class FakeOrgApi extends Node:
	var _next_id: int = 1

	func create_organization(_org_name: String, _tag: String, _tier: int, _parent_id: String) -> Dictionary:
		var org_id := "org_%d" % _next_id
		_next_id += 1
		return {"ok": true, "data": {"org_id": org_id}}

	func assign_stickman(_org_id: String, _stickman_id: String, _role: String) -> void:
		pass

	func assign_commander(_org_id: String, _stickman_id: String) -> void:
		pass

	func remove_stickman(_org_id: String, _stickman_id: String) -> void:
		pass

	func disband_organization(_org_id: String) -> void:
		pass


## 假战斗实例（formation 侧 _member_enemy_in_range / _anchor_in_danger 取数面）
class FakeBattle extends Node:
	var enemies: Array = []

	func is_active() -> bool:
		return true

	func get_enemies_of(_faction: int) -> Array:
		return enemies

	func get_allies_of(_faction: int) -> Array:
		return []


## 敌人桩（阵营 2）
class FakeEnemy extends Node2D:
	func is_dead() -> bool:
		return false

	func get_faction() -> int:
		return 2


## 编队侧成员桩：位置 + 战斗/武器查询面（attack_range 650 = 弓）
class FakeUnit extends Node2D:
	var faction: int = 1
	var battle: FakeBattle = null
	var weapon: Node = null
	var ai: Node = null

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


## 记录 AI 桩（跟队号令记录面，test_squad_phase_plan FakeAI 精简版；
## get_ordered_* 供跟队去重路径识别 follow_order 标记）
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

	func get_current_behavior() -> String:
		return "idle"

	func get_ordered_behavior() -> String:
		return _ordered_behavior

	func get_ordered_params() -> Dictionary:
		return _ordered_params


## 假武器（weapon_type + attack_range）
class FakeWeapon extends Node:
	var weapon_type: int = 0
	var attack_range: float = 650.0


## 编队夹具：4 人班（100, 500..800）+ 敌 (700, 650)（射程 650 内 = 接战）
class _FormationFixture extends RefCounted:
	var fs: Node = null
	var org: Node = null
	var units: Array = []
	var sid: String = ""
	var enemy: FakeEnemy = null
	var battle: FakeBattle = null

	func _init() -> void:
		fs = ScriptFormationSystem.new()
		org = FakeOrgApi.new()
		fs.setup(org)
		battle = FakeBattle.new()
		enemy = FakeEnemy.new()
		enemy.global_position = Vector2(700.0, 650.0)
		battle.enemies.append(enemy)
		for i in 4:
			var u := FakeUnit.new()
			u.name = "U%d" % i
			u.global_position = Vector2(100.0, 500.0 + i * 100.0)
			var w := FakeWeapon.new()
			w.weapon_type = ScriptBehaviorProfiles.BOW
			u.weapon = w
			u.add_child(w)
			u.battle = battle
			units.append(u)
		sid = fs.create_squad(units, "槽位锚定队")

	func teardown() -> void:
		fs.free()
		org.free()
		battle.free()
		for u in units:
			u.free()


func _make_fixture() -> _FormationFixture:
	return _FormationFixture.new()


## 直调战斗锚 tick（绕过 _process；足量 delta 触发节流）
func fs_tick(fs: Node, delta: float) -> void:
	fs._tick_combat_anchors(delta)


## 行为侧夹具实体：duck 面齐（behavior_attack update 消费）+ 编队系统注入 +
## 移动记录（last_move/last_run/stopped）
class _AnchorEntity extends CharacterBody2D:
	var battle: Node = null
	var weapon: Node = null
	var health: Node = null
	var formation: Node = null
	var stopped: bool = false
	var last_move: Vector2 = Vector2.ZERO
	var last_run: bool = false
	var faction_id: int = 1

	func get_weapon() -> Node:
		return weapon

	func get_faction() -> int:
		return faction_id

	func get_battle_instance() -> Node:
		return battle

	func get_health() -> Node:
		return health

	func get_formation_system() -> Node:
		return formation

	func is_dead() -> bool:
		return false

	func ai_stop() -> void:
		stopped = true
		last_move = Vector2.ZERO

	func ai_move(dir: Vector2, run: bool) -> void:
		last_move = dir
		last_run = run
		stopped = false


## 行为侧夹具：1 员班（BOW/SWORD 档案按参）+ 白盒注入战斗锚 (500,300)
## 实体 (500,400)（距槽 >100px = 超死区），敌 (900,400)（射程 650 内/危险带外）
class _BehaviorCtx extends RefCounted:
	var fs: Node = null
	var org: Node = null
	var battle: FakeBattle = null
	var enemy: FakeEnemy = null
	var entity: _AnchorEntity = null
	var attack: Node = null
	var sid: String = ""
	var slot: Vector2 = Vector2.INF

	func _init(wtype: int) -> void:
		# 掷骰隔离：hesitate_prob 置 0 + strafe 计时器拨远（RNG 种子随实例 id，
		# 不隔离会有 3%/35% 概率在断言窗口内插入随机走位）
		ScriptBehaviorProfiles._cache.clear()
		var prof: Dictionary = ScriptBehaviorProfiles.get_profile(wtype)
		prof["hesitate_prob"] = 0.0
		fs = ScriptFormationSystem.new()
		org = FakeOrgApi.new()
		fs.setup(org)
		battle = FakeBattle.new()
		enemy = FakeEnemy.new()
		enemy.global_position = Vector2(900.0, 400.0)
		battle.enemies.append(enemy)
		entity = _AnchorEntity.new()
		entity.global_position = Vector2(500.0, 400.0)
		var w := FakeWeapon.new()
		w.weapon_type = wtype
		entity.weapon = w
		entity.battle = battle
		entity.formation = fs
		sid = fs.create_squad([entity], "行为槽位队")
		# 白盒注入战斗锚（tick 冻结语义另由编队侧用例覆盖）
		fs._squads[sid]["combat_anchor"] = {"pos": Vector2(500.0, 300.0), "facing": Vector2.RIGHT}
		slot = fs.get_unit_combat_slot(entity)
		attack = ScriptBehaviorAttack.new()
		attack.entity = entity
		attack.enter("", {"battle": battle, "forced_target": enemy})
		attack._strafe_timer = 10.0

	func teardown() -> void:
		attack.free()
		fs.free()
		org.free()
		battle.free()
		entity.free()
		ScriptBehaviorProfiles._cache.clear()


func _make_behavior_ctx(wtype: int) -> _BehaviorCtx:
	return _BehaviorCtx.new(wtype)
