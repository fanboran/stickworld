extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：命中帧按动画内嵌 Hit 事件时间结算（翻译保真度审计走样 #1）。
##
## 为什么用桩 rig 而不是真场景：
##   真场景里两个 AI 单位会互相打断（受击插播 play_hit 会切走攻击动画）、
##   还有地图上的第三方单位乱入，端到端测"伤害落在 1.0s"极易抖动。
##   这里把 rig 换成可控桩，用手动 _physics_process 推进时间，结论确定。
##
## 覆盖三条分支：
##   ① 有 Hit 事件：动画时间 < 事件时间不结算，≥ 事件时间才结算
##   ② 无 Hit 事件（动画缺元数据）：回退到进度比例 STRIKE_FRAME_RATIO_FALLBACK
##   ③ 动画未起播：宽限期内不结算，超时才兜底结算（防 headless 卡死）

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
## 显式 preload：确保 headless 批量模式下 DamagePipeline/TargetFinder 的
## class_name 已注册（weapon_mount.gd 内部按全局类名引用它们）。
const _DamagePipeline := preload("res://modules/combat/scripts/battle/damage_pipeline.gd")
const _TargetFinder := preload("res://modules/combat/scripts/target_finder.gd")
const WeaponMountScript := preload("res://modules/units/scripts/entity/weapon_mount.gd")
const HealthComponentScript := preload("res://modules/units/scripts/entity/health_component.gd")

const ANIM_LEN: float = 1.3333   # Swordwrath-Attack1 时长
const HIT_TIME: float = 1.0      # 该动画内嵌 Hit 事件时间

var _runner: TestRunner


## 桩 rig：只暴露 WeaponMount 查询命中帧用的三个接口，时间由测试完全控制
class StubRig:
	extends Node

	## 各动画的 Hit 事件时间；-1 = 该动画没有事件数据
	var hit_times: Dictionary = {}
	## 当前动画播放位置（秒）；-1 = 该动画当前没在播
	var anim_time: float = -1.0

	func get_anim_event_time(anim_name: String, event_name: String) -> float:
		if event_name != "Hit":
			return -1.0
		return float(hit_times.get(anim_name, -1.0))

	func get_anim_time(_anim_name: String) -> float:
		return anim_time

	func get_anim_progress(_anim_name: String) -> float:
		if anim_time < 0.0:
			return 1.0
		return clampf(anim_time / ANIM_LEN, 0.0, 1.0)


## 桩宿主实体：只需 CharacterBody2D 外壳 + rig 属性 + play_attack 钩子
class StubOwner:
	extends CharacterBody2D

	var rig: Node = null

	func play_attack() -> void:
		pass


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("命中帧: 动画未到 Hit 事件时间不结算", _test_no_early_strike)
	_runner.add_test("命中帧: 越过 Hit 事件时间才结算", _test_strike_at_event)
	_runner.add_test("命中帧: 无事件数据时回退进度比例", _test_ratio_fallback)
	_runner.add_test("命中帧: 动画未起播时宽限后兜底结算", _test_grace_fallback)
	_runner.add_test("空挥: 无目标出动作无结算", _test_swing_no_target)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


## 组装一套"宿主 + 桩 rig + WeaponMount + 靶子"
func _make_pair(hit_time: float) -> Dictionary:
	var owner := StubOwner.new()
	add_child(owner)
	var rig := StubRig.new()
	rig.name = "Rig"
	owner.add_child(rig)
	owner.rig = rig
	rig.hit_times["attack"] = hit_time
	var wm: Node = WeaponMountScript.new()
	wm.name = "WeaponMount"
	owner.add_child(wm)
	# 关掉自动物理帧：本测试用手动 _physics_process 推进时间，保证确定性
	wm.set_physics_process(false)
	wm.damage = 20.0
	wm.base_hit_chance = 1.0

	var target := Node2D.new()
	add_child(target)
	target.position = Vector2(50, 0)
	var hc := HealthComponentScript.new()
	hc.name = "HealthComponent"
	hc.max_hp = 1000.0
	target.add_child(hc)
	hc.hp = 1000.0
	return {"owner": owner, "rig": rig, "wm": wm, "target": target, "health": hc}


func _test_no_early_strike() -> void:
	var kit: Dictionary = _make_pair(HIT_TIME)
	var wm: Node = kit["wm"]
	var rig: Node = kit["rig"]
	var health: Node = kit["health"]
	var hp0: float = health.hp
	rig.anim_time = 0.0
	var result: Dictionary = wm.perform_attack(kit["target"])
	_runner.assert_equal(result.get("reason", ""), "striking", "近距离应发起攻击")
	# 推进到命中帧之前（0.9s < 1.0s）不应结算
	for i in range(10):
		rig.anim_time = 0.9
		wm._physics_process(0.05)
	_runner.assert_approx(health.hp, hp0, 0.001,
		"动画未到 Hit 事件时间（%.1fs）不应结算伤害" % HIT_TIME)
	kit["owner"].queue_free()
	kit["target"].queue_free()


## 空挥（perform_swing，复刻原版 User Control 无目标挥击）：
## 动画照播（_strike_fired 置位）、冷却进入，但无登记目标 → 不结算任何伤害
func _test_swing_no_target() -> void:
	var kit: Dictionary = _make_pair(HIT_TIME)
	var wm: Node = kit["wm"]
	var rig: Node = kit["rig"]
	var health: Node = kit["health"]
	var hp0: float = health.hp
	rig.anim_time = 0.0
	var swung: bool = wm.perform_swing()
	_runner.assert_true(swung, "空挥应成功起挥（冷却外）")
	# 推进越过命中帧（1.2s < 冷却 1.35s，保住冷却断言）：无目标不得结算、不得报错
	for i in range(24):
		rig.anim_time = HIT_TIME + 0.1
		wm._physics_process(0.05)
	_runner.assert_approx(health.hp, hp0, 0.001, "空挥不得结算伤害")
	_runner.assert_gt(wm.get_cooldown_remaining(), 0.0, "空挥应进入冷却")
	# 冷却中再挥应被拒
	_runner.assert_false(wm.perform_swing(), "冷却中空挥应被拒")
	kit["owner"].queue_free()
	kit["target"].queue_free()


func _test_strike_at_event() -> void:
	var kit: Dictionary = _make_pair(HIT_TIME)
	var wm: Node = kit["wm"]
	var rig: Node = kit["rig"]
	var health: Node = kit["health"]
	var hp0: float = health.hp
	rig.anim_time = 0.0
	wm.perform_attack(kit["target"])
	rig.anim_time = 0.99
	wm._physics_process(0.05)
	_runner.assert_approx(health.hp, hp0, 0.001, "0.99s 仍未到命中帧，不应结算")
	rig.anim_time = HIT_TIME
	wm._physics_process(0.05)
	_runner.assert_approx(health.hp, hp0 - 20.0, 0.001,
		"越过 Hit 事件时间（%.1fs）应结算 20 点伤害，实际扣 %.1f" % [HIT_TIME, hp0 - health.hp])
	kit["owner"].queue_free()
	kit["target"].queue_free()


func _test_ratio_fallback() -> void:
	# 动画没有 Hit 事件元数据（-1）：回退到进度比例 0.45（1.3333s × 0.45 ≈ 0.6s）
	var kit: Dictionary = _make_pair(-1.0)
	var wm: Node = kit["wm"]
	var rig: Node = kit["rig"]
	var health: Node = kit["health"]
	var hp0: float = health.hp
	rig.anim_time = 0.0
	wm.perform_attack(kit["target"])
	rig.anim_time = 0.5   # 比例 0.375 < 0.45
	wm._physics_process(0.05)
	_runner.assert_approx(health.hp, hp0, 0.001, "无事件数据时 0.5s 仍未到兜底比例")
	rig.anim_time = 0.65  # 比例 0.4875 ≥ 0.45
	wm._physics_process(0.05)
	_runner.assert_true(health.hp < hp0, "无事件数据时应按进度比例兜底结算")
	kit["owner"].queue_free()
	kit["target"].queue_free()


func _test_grace_fallback() -> void:
	# 动画压根没起播（anim_time = -1）：宽限 0.3s 内不结算，超时兜底结算，
	# 保证无 rig / 无动画的环境（headless、测试桩）不会让攻击蒸发。
	var kit: Dictionary = _make_pair(HIT_TIME)
	var wm: Node = kit["wm"]
	var rig: Node = kit["rig"]
	var health: Node = kit["health"]
	var hp0: float = health.hp
	rig.anim_time = -1.0
	wm.perform_attack(kit["target"])
	for i in range(5):
		wm._physics_process(0.05)   # 累计 0.25s < 宽限 0.3s
	_runner.assert_approx(health.hp, hp0, 0.001, "宽限期内（0.25s）不应结算，等动画起播")
	wm._physics_process(0.1)        # 累计 0.35s > 宽限
	_runner.assert_true(health.hp < hp0, "宽限期过后应兜底结算，避免攻击蒸发")
	kit["owner"].queue_free()
	kit["target"].queue_free()
