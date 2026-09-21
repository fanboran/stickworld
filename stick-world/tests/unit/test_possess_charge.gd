extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：玩家蓄力操控（SWL ArcherControls 逆向实锤的 PC 翻译）。
##
## 覆盖四层：
## ① 力度→箭速映射（charge_launch_speed：SWL ArrowSpeedMinPower/MaxPower 区间语义）
## ② 手动放箭弹道（fire_arrow_manual：方向=鼠标指向、速度=力度映射、
##    draw_power 传播伤害公式、零散布——玩家拖拽即精确）
## ③ 蓄力投矛（throw_spear_manual：矛投射物生成与初速）
## ④ 蓄力状态机（entity_possession：press→拉弓态、release→出手+清态、
##    cancel→强制收口；begin_player_draw 不进冷却，出手时刻才进）

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const WeaponMountScript := preload("res://modules/units/scripts/entity/weapon_mount.gd")
const PossessionScript := preload("res://modules/units/scripts/entity/entity_possession.gd")
const BehaviorProfilesScript := preload("res://modules/units/scripts/ai/behavior_profiles.gd")

## 桩宿主实体：CharacterBody2D 外壳 + play_attack 计数（拉弓动画起播断言）
## + entity_possession 消费的接口面（is_carrying/weapon_mount/朝向族）
class StubOwner:
	extends CharacterBody2D

	var attack_plays: int = 0
	var weapon_mount: Node = null

	func play_attack() -> void:
		attack_plays += 1

	func is_carrying() -> bool:
		return false

	func get_facing() -> int:
		return 1

	func face_towards(_pos: Vector2) -> void:
		pass


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("力度映射: 区间两端与中点线性、越界钳制", _test_charge_launch_speed)
	_runner.add_test("手动放箭: 方向速度力度全链路+零散布", _test_fire_arrow_manual)
	_runner.add_test("蓄力投矛: 矛投射物生成与初速", _test_throw_spear_manual)
	_runner.add_test("拉弓起手: 播动画不进冷却", _test_begin_draw_no_cooldown)
	_runner.add_test("状态机: 按下进入拉弓态/松手放箭清态/重复松手幂等", _test_press_release_cycle)
	_runner.add_test("状态机: 冷却中按下不进入蓄力", _test_press_blocked_by_cooldown)
	_runner.add_test("强制收口: cancel 清态不出手", _test_cancel_charge)
	_runner.add_test("AI三档: 乘数表方向与档案默认档", _test_skill_multipliers)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


var _runner: TestRunner


## 组装"独立容器 + 宿主 + WeaponMount（指定武器类型）"夹具。
## 独立容器隔离投射物计数：fire/throw 的投射物挂 owner.get_parent()=
## 本容器，前序用例 queue_free 延迟残留不会污染断言。
func _make_mount(weapon_type: int) -> Dictionary:
	var box := Node2D.new()
	add_child(box)
	var owner := StubOwner.new()
	box.add_child(owner)
	var wm: Node = WeaponMountScript.new()
	wm.name = "WeaponMount"
	owner.add_child(wm)
	wm.set_physics_process(false)
	wm.weapon_type = weapon_type
	owner.weapon_mount = wm
	return {"box": box, "owner": owner, "wm": wm}


func _projectiles_of(kit: Dictionary) -> Array:
	var out: Array = []
	for c in (kit["box"] as Node).get_children():
		if c != kit["owner"] and c is Area2D:
			out.append(c)
	return out


# ─────────────────────────────── ① 力度映射 ────────────────────────────────

func _test_charge_launch_speed() -> void:
	var kit: Dictionary = _make_mount(2)  # BOW
	var wm: Node = kit["wm"]
	_runner.assert_approx(wm.charge_launch_speed(0.0), wm.ARROW_VX_MIN, 0.001,
			"力度 0 = 最小箭速（ArrowSpeedMinPower）")
	_runner.assert_approx(wm.charge_launch_speed(1.0), wm.ARROW_VX_MAX, 0.001,
			"力度 1 = 最大箭速（ArrowSpeedMaxPower）")
	_runner.assert_approx(wm.charge_launch_speed(0.5),
			(wm.ARROW_VX_MIN + wm.ARROW_VX_MAX) * 0.5, 0.001, "力度 0.5 = 区间中点（线性）")
	_runner.assert_approx(wm.charge_launch_speed(1.5), wm.ARROW_VX_MAX, 0.001,
			"力度越界钳制到 1")
	kit["box"].queue_free()


# ─────────────────────── ② 手动放箭（零散布直射）───────────────────────────

func _test_fire_arrow_manual() -> void:
	var kit: Dictionary = _make_mount(2)  # BOW
	var wm: Node = kit["wm"]
	var owner: Node = kit["owner"]
	wm.damage = 17.0
	var aim := Vector2(0.6, -0.8).normalized()
	var power := 0.7
	wm.release_player_shot(aim, power)
	var arrows: Array = _projectiles_of(kit)
	_runner.assert_equal(arrows.size(), 1, "松手放箭应生成一支箭")
	if arrows.is_empty():
		kit["box"].queue_free()
		return
	var arrow: Node = arrows[0]
	var expected_speed: float = wm.charge_launch_speed(power)
	# 零散布断言：vel 与期望**精确相等**（AI 路径有高斯扰动，玩家路径没有）
	_runner.assert_approx(arrow._vel.x, aim.x * expected_speed, 0.001,
			"箭水平分速 = 瞄准方向 × 力度映射速度（零散布）")
	_runner.assert_approx(arrow._vel.y, aim.y * expected_speed, 0.001,
			"箭竖直分速 = 瞄准方向 × 力度映射速度（零散布）")
	_runner.assert_approx(float(arrow._draw_power), power, 0.001,
			"draw_power 传播到箭矢（伤害公式 0.6+0.4×p 消费）")
	_runner.assert_approx(float(arrow._gravity), wm.ARROW_GRAVITY, 0.001,
			"手动箭与 AI 箭同源重力场")
	_runner.assert_equal(arrow._target, null, "手动箭无锁定目标（物理碰撞路径）")
	_runner.assert_gt(wm.get_cooldown_remaining(), 0.0, "出手时刻进入冷却")
	for a in arrows:
		a.queue_free()
	kit["box"].queue_free()


# ─────────────────────── ③ 蓄力投矛 ────────────────────────────────────────

func _test_throw_spear_manual() -> void:
	var kit: Dictionary = _make_mount(1)  # SPEAR
	var wm: Node = kit["wm"]
	var owner: Node = kit["owner"]
	var aim := Vector2(1.0, 0.0)
	var power := 1.0
	wm.throw_spear_manual(aim, power)
	var spears: Array = _projectiles_of(kit)
	_runner.assert_equal(spears.size(), 1, "投矛应生成一个矛投射物")
	if spears.is_empty():
		kit["box"].queue_free()
		return
	var spear: Node = spears[0]
	_runner.assert_approx(spear._vel.x, 950.0, 0.001, "满力投矛水平初速 = SPEAR_SPEED_MAX")
	_runner.assert_approx(spear._vel.y, 0.0, 0.001, "瞄准方向直射（零散布）")
	_runner.assert_approx(float(spear._draw_power), 1.0, 0.001, "满蓄力度传播")
	for s in spears:
		s.queue_free()
	kit["box"].queue_free()


# ─────────────────────── ④ 蓄力状态机 ──────────────────────────────────────

func _test_begin_draw_no_cooldown() -> void:
	var kit: Dictionary = _make_mount(2)  # BOW
	var wm: Node = kit["wm"]
	var owner: StubOwner = kit["owner"]
	wm.begin_player_draw()
	_runner.assert_equal(owner.attack_plays, 1, "拉弓起手应播放攻击动画（DrawBow）")
	_runner.assert_approx(wm.get_cooldown_remaining(), 0.0, 0.001,
			"起手不进冷却（冷却在松手出手时刻判）")
	kit["box"].queue_free()


func _test_press_release_cycle() -> void:
	var kit: Dictionary = _make_mount(2)  # BOW
	var owner: Node = kit["owner"]
	var possession: RefCounted = PossessionScript.new(owner)
	possession._player_attack_press()
	_runner.assert_true(possession.is_aim_charging(), "按下（弓）应进入拉弓态")
	possession._player_attack_release()
	_runner.assert_false(possession.is_aim_charging(), "松手应清拉弓态")
	var arrows: Array = _projectiles_of(kit)
	_runner.assert_equal(arrows.size(), 1, "松手应放出一支箭（立即松 = 最小力度软箭）")
	if not arrows.is_empty():
		# 立即松手：held_ms ≈ 0 → power = CHARGE_MIN_POWER（轻点不是哑火）
		var expected_speed: float = (owner.weapon_mount as Node).charge_launch_speed(possession.CHARGE_MIN_POWER)
		_runner.assert_approx((arrows[0] as Node)._vel.length(), expected_speed, 1.0,
				"轻点 = 最小力度快速平射（ArrowSpeedMinPower 语义）")
	possession._player_attack_release()
	_runner.assert_equal(_projectiles_of(kit).size(), 1,
			"非蓄力态重复松手应静默（不补射）——上一支箭仍在树内计数不变")
	for a in _projectiles_of(kit):
		a.queue_free()
	kit["box"].queue_free()


func _test_press_blocked_by_cooldown() -> void:
	var kit: Dictionary = _make_mount(2)  # BOW
	var owner: Node = kit["owner"]
	var wm: Node = kit["wm"]
	var possession: RefCounted = PossessionScript.new(owner)
	# 先放一箭进入冷却
	var aim := Vector2(1.0, 0.0)
	wm.release_player_shot(aim, 1.0)
	for a in _projectiles_of(kit):
		a.queue_free()
	possession._player_attack_press()
	_runner.assert_false(possession.is_aim_charging(),
			"冷却中按下不应进入蓄力态（冷却门在按下时刻判）")
	kit["box"].queue_free()


func _test_cancel_charge() -> void:
	var kit: Dictionary = _make_mount(2)  # BOW
	var owner: Node = kit["owner"]
	var possession: RefCounted = PossessionScript.new(owner)
	possession._player_attack_press()
	_runner.assert_true(possession.is_aim_charging(), "前置：按下进入拉弓态")
	possession.cancel_charge()
	_runner.assert_false(possession.is_aim_charging(), "强制收口应清拉弓态")
	_runner.assert_equal(_projectiles_of(kit).size(), 0, "收口不出手（退出附身防误射）")
	_runner.assert_approx(Engine.time_scale, 1.0, 0.001,
			"收口后 time_scale 恢复常速（headless 慢放短路，断言无害）")
	kit["box"].queue_free()


# ─────────────────────── AI 三档乘数表 ─────────────────────────────────────

func _test_skill_multipliers() -> void:
	_runner.assert_gt(float(BehaviorProfilesScript.SKILL_AIM_SCATTER_MULT[0]), 1.0,
			"LIMITED 档散布更差（×>1）")
	_runner.assert_approx(float(BehaviorProfilesScript.SKILL_AIM_SCATTER_MULT[1]), 1.0, 0.001,
			"中位档 = 零回归")
	_runner.assert_lt(float(BehaviorProfilesScript.SKILL_AIM_SCATTER_MULT[2]), 1.0,
			"PRO 档散布更准（×<1）")
	_runner.assert_lt(float(BehaviorProfilesScript.SKILL_AIM_HOLD_MULT[2]), 1.0,
			"PRO 档持瞄更果断")
	var profile: Dictionary = BehaviorProfilesScript.get_profile(2)  # BOW
	_runner.assert_equal(int(profile.get("user_control_skill", -1)), 1,
			"档案默认中位档（USES_IT_BUT_NOT_WELL，零回归）")
