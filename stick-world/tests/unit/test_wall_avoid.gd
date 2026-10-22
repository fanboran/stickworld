extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：静态障碍局部避障（寻路方案A，调研 docs/技术/架构/寻路避障调研.md §三 P0）。
## 三面口径：
## ① 遇障绕行：斜碰切向滑动（意图投影墙面）/ 正对面墙织短时绕行意向（侧别帧间稳定）
## ② 不卡死：推墙停滞累计超限 → 显式判不可达（组件置位 + 行为 finish 上报），
##    卡住换侧重织；滑墙有进展不升级
## ③ 战斗语义不变：engage_in_range 推进令永不因不可达静默终止；
##    敌挡路接战（打通态）不受避障分量影响；wander 卡住三件套抽组件后回归

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptBehaviorMove := preload("res://modules/units/scripts/ai/behavior_move.gd")
const ScriptAIController := preload("res://modules/units/scripts/ai/ai_controller.gd")
const ScriptBehaviorWander := preload("res://modules/units/scripts/ai/behavior_wander.gd")
const ScriptWallAvoid := preload("res://modules/units/scripts/ai/steering_wall_avoid.gd")

var _runner: TestRunner


## 最小单位桩（同 test_behavior_breach：ai_move 记录方向；freeze=true 时不积分
## 位移——模拟被墙顶死的钉住单位；map/ground 字段供 wander 边界规避直读）
class FakeUnit:
	extends CharacterBody2D
	var faction_id: int = 1
	var battle: Node = null
	var weapon: Node = null
	var ai: Node = null
	var map_left: float = -2000.0
	var map_right: float = 2000.0
	var ground_y: float = -1000.0
	var ground_bottom: float = 1000.0
	var foot_offset: float = 0.0
	var _dead: bool = false
	var last_dir := Vector2.ZERO
	var move_calls: int = 0
	var stop_calls: int = 0
	var freeze: bool = false

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

	func is_user_controlled() -> bool:
		return false

	func ai_stop() -> void:
		stop_calls += 1

	func ai_move(dir: Vector2, _run: bool = false) -> void:
		last_dir = dir
		move_calls += 1
		if not freeze:
			global_position += dir * 10.0  # 测试步进：每拍 10px


## 战斗桩（同 test_behavior_breach）
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


## 武器桩（同 test_behavior_breach）
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


## 避障组件桩：注入虚拟墙面法线（KinematicCollision2D 无法从脚本构造，
## 覆写 fetch_wall_normals 是组件预留的测试注入口）
class StubAvoid:
	extends "res://modules/units/scripts/ai/steering_wall_avoid.gd"
	var wall_normals: Array = []

	func fetch_wall_normals() -> Array:
		return wall_normals


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("组件: 斜碰切向滑动（意图投影墙面不顶牛）", _test_tangent_slide)
	_runner.add_test("组件: 正对面墙织绕行意向（侧别帧间稳定）", _test_detour_intent)
	_runner.add_test("组件: 绕行到期自动失效（无墙不残留）", _test_detour_expiry)
	_runner.add_test("组件: 推墙停滞累计超限 → 判不可达", _test_give_up_unreachable)
	_runner.add_test("组件: 无墙占位绕圈（有速度无接近）→ 判不可达", _test_crowd_stall_unreachable)
	_runner.add_test("组件: 有实质接近不升级（无墙正常赶路）", _test_approach_no_escalation)
	_runner.add_test("组件: 换目标清零阻滞账本（换点重试）", _test_goal_change_resets_stall)
	_runner.add_test("组件: 滑墙有进展不升级（推墙账本衰减）", _test_slide_no_escalation)
	_runner.add_test("组件: 卡住换侧（同侧绕不动翻反侧重织）", _test_stuck_flip_side)
	_runner.add_test("组件: 持续推墙先背退脱困（沿法线退出后重试）", _test_escape_backoff)
	_runner.add_test("行为: move 遇墙织绕行保持移动（非战斗）", _test_move_detour)
	_runner.add_test("行为: move 不可达 finish 上报（非战斗不无限推墙）", _test_move_unreachable_finish)
	_runner.add_test("行为: engage 推进令永不因不可达静默终止", _test_engage_never_give_up)
	_runner.add_test("行为: 敌挡路接战不受避障影响（打通态照常）", _test_breach_with_wall)
	_runner.add_test("行为: wander 卡住三件套抽组件后回归", _test_wander_stuck_regression)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────── 夹具 ───────────────────────

func _make_stub_avoid(unit: FakeUnit) -> StubAvoid:
	var av := StubAvoid.new(unit)
	av.arm()
	return av


func _make_move_ctx(target: Vector2, engage: bool = false) -> Dictionary:
	var unit := FakeUnit.new()
	unit.position = Vector2(0, 0)
	var beh: Node = ScriptBehaviorMove.new()
	beh.entity = unit
	beh.enter("", {"target": target, "engage_in_range": engage})
	return {"unit": unit, "beh": beh}


## 给行为注入墙法线桩（enter 已建组件，替换为可注入版）
func _inject_wall_stub(beh: Node, normals: Array) -> StubAvoid:
	var unit: FakeUnit = beh.entity
	var av := StubAvoid.new(unit)
	av.arm()
	av.wall_normals = normals
	beh.set("_wall_avoid", av)
	return av


func _teardown(nodes: Array) -> void:
	for n in nodes:
		if n != null and is_instance_valid(n):
			n.free()


# ─────────────────────── ① 遇障绕行 ───────────────────────

## 斜碰：意图 (0.8,-0.6) 撞水平地面墙（法线 (0,1)）→ 投影切向 = 纯横向沿墙滑，
## 不再往墙上怼（方向与法线点积归零）
func _test_tangent_slide() -> void:
	var unit := FakeUnit.new()
	unit.position = Vector2(0, 0)
	var av := _make_stub_avoid(unit)
	av.wall_normals = [Vector2(0, 1)]
	var dir := Vector2(0.8, -0.6).normalized()
	av.update(0.2, dir, unit.global_position + dir * 300.0)
	var out: Vector2 = av.steer(0.033, dir)
	_runner.assert_approx(absf(out.dot(Vector2(0, 1))), 0.0, 0.01, "切向方向不应再有法向分量")
	_runner.assert_true(absf(out.x) > 0.9, "斜碰应沿墙横向滑（切向主导）")
	_runner.assert_false(av.is_detouring(), "斜碰不需要绕行意向（滑动即可）")
	_teardown([unit])


## 正对面墙：意图直上撞墙 → 切向归零 → 织绕行意向（纯横向），侧别帧间稳定不抖
func _test_detour_intent() -> void:
	var unit := FakeUnit.new()
	unit.position = Vector2(0, 0)
	var av := _make_stub_avoid(unit)
	av.wall_normals = [Vector2(0, 1)]
	var dir := Vector2(0, -1)
	av.update(0.2, dir, Vector2(0, -400))
	_runner.assert_true(av.is_detouring(), "正对面墙应织绕行意向")
	var side: float = 0.0
	var out0: Vector2 = av.steer(0.033, dir)
	_runner.assert_true(absf(out0.x) > 0.9 and absf(out0.y) < 0.1, "绕行意向应为纯横向沿墙")
	side = signf(out0.x)
	unit.global_position += out0 * 10.0  # 首拍即动（对应真实 30Hz 驱动，防误触卡住换侧）
	for i in 3:
		av.update(0.2, dir, Vector2(0, -400))
		var out: Vector2 = av.steer(0.033, dir)
		unit.global_position += out * 10.0  # 单位真在动：卡住检测不触发（否则换侧合法）
		_runner.assert_equal(signf(out.x), side, "绕行侧别应帧间稳定（不左右抽搐）")
	_runner.assert_false(av.is_unreachable(), "短暂绕行不应升级不可达")
	_teardown([unit])


## 绕行到期：无墙接触后续织失效，方向回归目标直指
func _test_detour_expiry() -> void:
	var unit := FakeUnit.new()
	unit.position = Vector2(0, 0)
	var av := _make_stub_avoid(unit)
	av.wall_normals = [Vector2(0, 1)]
	var dir := Vector2(0, -1)
	av.update(0.2, dir, Vector2(0, -400))
	_runner.assert_true(av.is_detouring(), "前置：绕行意向已织起")
	av.wall_normals = []  # 墙没了（绕出墙沿/拐角）
	for i in 6:  # 1.2s > DETOUR_DURATION(0.8s)
		av.update(0.2, dir, Vector2(0, -400))
		av.steer(0.2, dir)
	_runner.assert_false(av.is_detouring(), "无墙后续织应到期失效")
	_teardown([unit])


# ─────────────────────── ② 不卡死 ───────────────────────

## 推墙停滞（钉死不动 + 目标无进展）累计超 GIVE_UP_TIME → 判不可达（有限尝试
## 后上报，不再无限推墙）；终态清绕行分量
func _test_give_up_unreachable() -> void:
	var unit := FakeUnit.new()
	unit.freeze = true  # 钉住：位移恒零（被墙顶死）
	unit.position = Vector2(0, 0)
	var av := _make_stub_avoid(unit)
	av.wall_normals = [Vector2(0, 1)]
	var dir := Vector2(0, -1)
	var gave_up: bool = false
	for i in 30:  # 6s > GIVE_UP_TIME(5s)
		av.update(0.2, dir, Vector2(0, -400))
		av.steer(0.033, dir)
		if av.is_unreachable():
			gave_up = true
			break
	_runner.assert_true(gave_up, "推墙停滞累计超限应判不可达")
	_runner.assert_false(av.is_detouring(), "终态应清绕行分量")
	_runner.assert_true(av.push_time() >= 5.0, "推墙账本应累计到放弃时限")
	_teardown([unit])


## 动态阻滞（无墙接触）：目的地被友军占位时，后来者被分离/让路横向分量推着
## 绕圈——有速度、但目标距离长期无实质接近（每拍只抖动 ±1~2px）。组件须按同一
## GIVE_UP 时限升级不可达，交消费方换点（主街两个伐木工同抢一棵树的实锤情形）。
func _test_crowd_stall_unreachable() -> void:
	var unit := FakeUnit.new()
	unit.position = Vector2(0, -30.0)  # 站在目标 30px 外（ARRIVE 阈值边缘绕圈）
	var av := _make_stub_avoid(unit)
	var goal := Vector2.ZERO
	var angle: float = -PI * 0.5
	var gave_up: bool = false
	for i in 40:  # 8s > GIVE_UP_TIME(5s)
		# 半径恒 30px 绕圈：净接近 ≈ 0，径向速度分量只有抖动级
		angle += 0.14
		unit.global_position = Vector2(cos(angle), sin(angle)) * 30.0
		unit.velocity = Vector2(-sin(angle), cos(angle)) * 100.0
		av.update(0.2, (goal - unit.global_position).normalized(), goal)
		if av.is_unreachable():
			gave_up = true
			break
	_runner.assert_true(gave_up, "无墙占位绕圈（有速度无接近）应判不可达")
	_runner.assert_true(av.push_time() >= 5.0, "阻滞账本应累计到放弃时限")
	_teardown([unit])


## 无墙正常赶路（每拍实质接近 > PROGRESS_EPS）：阻滞账本不累计、不升级
func _test_approach_no_escalation() -> void:
	var unit := FakeUnit.new()
	unit.position = Vector2(0, 400.0)
	var av := _make_stub_avoid(unit)
	var goal := Vector2.ZERO
	var gave_up: bool = false
	for i in 15:  # 3s：每拍接近 20px（160px/s）
		var dir: Vector2 = (goal - unit.global_position).normalized()
		unit.velocity = dir * 160.0
		unit.global_position += dir * 20.0
		av.update(0.2, dir, goal)
		if av.is_unreachable():
			gave_up = true
			break
	_runner.assert_false(gave_up, "正常赶路有实质接近不应升级不可达")
	_runner.assert_true(av.push_time() <= 0.01, "有进展时阻滞账本应保持清零")
	_teardown([unit])


## 换点重试：绕圈累计接近时限时目标变更（harvest 拉黑换点）→ 账本清零、
## 不把新目标误判不可达
func _test_goal_change_resets_stall() -> void:
	var unit := FakeUnit.new()
	unit.position = Vector2(0, -30.0)
	var av := _make_stub_avoid(unit)
	var angle: float = -PI * 0.5
	for i in 15:  # 3s < GIVE_UP_TIME：累计中但未升级
		angle += 0.14
		unit.global_position = Vector2(cos(angle), sin(angle)) * 30.0
		unit.velocity = Vector2(-sin(angle), cos(angle)) * 100.0
		av.update(0.2, (Vector2.ZERO - unit.global_position).normalized(), Vector2.ZERO)
	_runner.assert_true(av.push_time() > 1.0, "前置：阻滞账本已在累计")
	var new_goal := Vector2(500.0, 0.0)
	av.update(0.2, Vector2.RIGHT, new_goal)
	_runner.assert_false(av.is_unreachable(), "换目标后不应沿用旧账本判不可达")
	_runner.assert_equal(av.push_time(), 0.0, "换目标应清零阻滞账本")
	_teardown([unit])


## 滑墙有进展（沿墙横移接近目标）：推墙账本衰减，不升级不可达
func _test_slide_no_escalation() -> void:
	var unit := FakeUnit.new()
	unit.position = Vector2(0, 0)
	var av := _make_stub_avoid(unit)
	av.wall_normals = [Vector2(0, 1)]
	var goal := Vector2(400, -30.0)  # 斜上目标：沿墙右滑持续接近
	var gave_up: bool = false
	for i in 30:  # 6s 持续滑墙有进展
		var dir: Vector2 = (goal - unit.global_position).normalized()
		av.update(0.2, dir, goal)
		var out: Vector2 = av.steer(0.2, dir)
		unit.global_position += out * 10.0  # 每拍 10px 沿墙推进
		if av.is_unreachable():
			gave_up = true
			break
	_runner.assert_false(gave_up, "滑墙有进展不应升级不可达")
	_runner.assert_true(unit.global_position.x > 200.0, "滑墙应保持沿墙推进（不钉死）")
	_teardown([unit])


## 卡住换侧：绕行中完全没动 → 卡住检测触发 → 绕行方向翻面（同侧绕不动换反侧）
func _test_stuck_flip_side() -> void:
	var unit := FakeUnit.new()
	unit.freeze = true  # 钉住：绕行横移也没生效（撞墙沿死角）
	unit.position = Vector2(0, 0)
	var av := _make_stub_avoid(unit)
	av.wall_normals = [Vector2(0, 1)]
	var dir := Vector2(0, -1)
	av.update(0.2, dir, Vector2(0, -400))
	var side0: float = signf(av.steer(0.033, dir).x)
	_runner.assert_true(av.is_detouring(), "前置：绕行意向已织起")
	var flipped: bool = false
	for i in 10:  # 2s：卡住窗口(0.2s)+冷却(0.5s) 内必触发一次换侧
		av.update(0.2, dir, Vector2(0, -400))
		var out: Vector2 = av.steer(0.033, dir)
		if signf(out.x) == -side0:
			flipped = true
			break
	_runner.assert_true(flipped, "绕行中卡住应换侧（方向翻面重织）")
	_teardown([unit])


## 背退脱困：推墙停滞超过 ESCAPE_AFTER 后，先沿墙法线（远离墙）后退一段，
## 给"嵌进碰撞体只靠切线滑永远出不来"的姿态一个出口；退完仍无进展才放弃
func _test_escape_backoff() -> void:
	var unit := FakeUnit.new()
	unit.freeze = true  # 钉住：模拟嵌入物理体后 move_and_slide 不排出
	unit.position = Vector2(0, 0)
	var av := _make_stub_avoid(unit)
	av.wall_normals = [Vector2(0, 1)]
	var dir := Vector2(0, -1)
	var escaped: bool = false
	for i in 20:  # 4s
		av.update(0.2, dir, Vector2(0, -400))
		var out: Vector2 = av.steer(0.2, dir)
		if out.distance_to(Vector2(0, 1)) < 0.01:
			escaped = true
			break
	_runner.assert_true(escaped, "持续推墙停滞应沿法线背退脱困")
	_runner.assert_false(av.is_unreachable(), "背退阶段尚未到放弃时限")
	_teardown([unit])


# ─────────────────────── ③ 战斗语义不变 ───────────────────────

## 行为层遇墙：非战斗 move 保持移动意图（横向绕行分量驱动），不 finish 清令
func _test_move_detour() -> void:
	var ctx := _make_move_ctx(Vector2(0, -400))
	var unit: FakeUnit = ctx["unit"]
	var beh: Node = ctx["beh"]
	_inject_wall_stub(beh, [Vector2(0, 1)])  # 头顶水平墙
	var lateral_seen: bool = false
	for i in 8:
		beh.update(0.2)
		if absf(unit.last_dir.x) > 0.9:
			lateral_seen = true
		_runner.assert_false(beh.is_finished(), "绕行期不应 finish")
	_runner.assert_true(lateral_seen, "正对面墙应织横向绕行分量驱动")
	_runner.assert_true(unit.move_calls > 0, "绕行期保持移动意图（不停车）")
	_teardown([unit, beh])


## 行为层不可达：钉死 + 持续推墙 → move finish（显式上报，AI 层换目标/回 idle）
func _test_move_unreachable_finish() -> void:
	var ctx := _make_move_ctx(Vector2(0, -400))
	var unit: FakeUnit = ctx["unit"]
	var beh: Node = ctx["beh"]
	unit.freeze = true  # 钉死：意图在跑、实际零位移
	_inject_wall_stub(beh, [Vector2(0, 1)])
	var finished: bool = false
	for i in 40:  # 8s > 5s 放弃时限
		beh.update(0.2)
		if beh.is_finished():
			finished = true
			break
	_runner.assert_true(finished, "推墙超限应 finish 上报不可达（非战斗）")
	_runner.assert_true(unit.stop_calls > 0, "放弃时应停车")
	_teardown([unit, beh])


## engage_in_range 推进令：即使推墙超限也绝不因"不可达"静默终止——
## 接战语义归遇阻接战/看门狗，推进令不因地形放弃
func _test_engage_never_give_up() -> void:
	var ctx := _make_move_ctx(Vector2(0, -400), true)
	var unit: FakeUnit = ctx["unit"]
	var beh: Node = ctx["beh"]
	unit.freeze = true
	var av := _inject_wall_stub(beh, [Vector2(0, 1)])
	for i in 40:  # 8s：远超 5s 放弃时限
		beh.update(0.2)
		_runner.assert_false(beh.is_finished(), "engage 推进令永不因不可达静默终止")
	_runner.assert_true(unit.move_calls > 0, "推进令保持移动意图")
	_runner.assert_true(av.is_unreachable(), "前置对照：组件层确已判不可达（行为层不吃）")
	_teardown([unit, beh])


## 敌挡路接战（打通态）不受避障影响：墙法线在场时，贴身敌拦路照常转攻击
##（接敌语义 = 刚修过的 _handle_path_block，避障只管墙不管人）
func _test_breach_with_wall() -> void:
	var unit := FakeUnit.new()
	unit.position = Vector2(0, 0)
	var weapon := StubWeapon.new()
	unit.weapon = weapon
	var battle := StubBattle.new()
	unit.battle = battle
	var ai: Node = ScriptAIController.new()
	ai._entity = unit
	ai._setup_state_machine()
	unit.ai = ai
	var blocker := FakeUnit.new()
	blocker.faction_id = 2
	blocker.position = Vector2(60, 0)  # 贴身（≤70px 接触距离）
	battle.enemies.append(blocker)
	ai.set_order("move", {"target": Vector2(400, 0)})
	# 注入墙法线桩：墙与敌同时在场，敌优先走接战、墙分量不得干扰
	var move_beh: Node = ai.get_state_machine().get("_current_behavior")
	_runner.assert_true(move_beh != null and move_beh.behavior_name == "move", "前置：move 行为在跑")
	_inject_wall_stub(move_beh, [Vector2(0, 1)])
	ai.get_state_machine().physics_update(0.2)
	_runner.assert_equal(ai.get_current_behavior(), "attack", "贴身敌拦路应转入攻击（避障在场不变）")
	_runner.assert_true(ai.is_breach_engaged(), "打通态应置位（墙分量不抢戏）")
	_teardown([unit, weapon, battle, ai, blocker])


## wander 卡住三件套抽公共组件后的回归：钉住触发掉头（方向大变），冷却期内
## 不重复触发
func _test_wander_stuck_regression() -> void:
	var unit := FakeUnit.new()
	unit.freeze = true  # 钉住：wander 意图在跑、零位移
	unit.position = Vector2(0, 0)
	var wander := ScriptBehaviorWander.new()
	wander.entity = unit
	wander.behavior_name = "test_wander"
	add_child(wander)
	wander.enter("", {"duration": 5.0})
	var dir0: Vector2 = wander.get("_wander_dir")
	var turned: bool = false
	for i in 20:  # 4s：卡住窗口+冷却多轮
		wander.update(0.1)
		var d: Vector2 = wander.get("_wander_dir")
		if d.dot(dir0) < 0.5:  # 夹角 >60° = 掉头生效
			turned = true
			break
	_runner.assert_true(turned, "钉住应触发掉头（三件套回归）")
	_runner.assert_false(wander.is_finished(), "时长未到不应 finish")
	_teardown([unit, wander])
