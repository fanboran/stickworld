extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：镜像通道语义（战场观感重构批1，治理 02-战斗系统.md 二-B #8/#9 部分）——
## - StickmanAnims 无 rig 访问器（.tres 直读：时长/事件帧/单次判定）
## - visual_controller billboard 软件回切：无 rig 链攻击播完回切、同名重播
##   序号（连续第二刀可见）、受击插播观测口、速率缓存
## 物理帧手动快进驱动（_physics_process 直调），确定性无等待。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const Anims := preload("res://modules/stick_rig/api.gd").ANIMS_SCRIPT
const VisualControllerScript := preload("res://modules/units/scripts/entity/visual_controller.gd")

var _runner: TestRunner


## billboard 桩实体：rig==null（HD-2D 图形态），只暴露 visual_controller 消费的属性
class StubEntity:
	extends Node2D
	var rig: Node2D = null
	var _current_anim := "idle"
	var _current_speed := 0.0
	var _action_locked := false
	var _carrying := false

	func is_dead() -> bool:
		return false


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("镜像: 无rig访问器 attack 时长/Hit帧/单次", _test_accessor_attack)
	_runner.add_test("镜像: 无rig访问器 walk 循环/缺资源 -1", _test_accessor_walk_missing)
	_runner.add_test("镜像: 攻击播完软件回切 idle", _test_attack_return)
	_runner.add_test("镜像: 同名重播 seq 递增", _test_seq_repeat)
	_runner.add_test("镜像: 受击插播变体", _test_hit_pulse)
	_runner.add_test("镜像: 速率缓存供 feed 轮询", _test_speed_cache)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _make_pair() -> Array:
	var e := StubEntity.new()
	var vc := Node.new()
	vc.set_script(VisualControllerScript)
	e.add_child(vc)
	vc.call("setup", e)
	return [e, vc]


func _test_accessor_attack() -> void:
	var len: float = Anims.rigless_anim_length("attack")
	_runner.assert_true(absf(len - 1.3333) < 0.02, "attack 时长应 ≈1.333s，实际 %.4f" % len)
	var hit: float = Anims.rigless_anim_event_time("attack", "Hit")
	_runner.assert_true(absf(hit - 1.0) < 0.001, "attack Hit 帧应 = 1.0s，实际 %.4f" % hit)
	_runner.assert_true(Anims.rigless_is_oneshot("attack"), "attack 应为单次动画")


func _test_accessor_walk_missing() -> void:
	_runner.assert_false(Anims.rigless_is_oneshot("walk"), "walk 应为循环动画")
	_runner.assert_equal(Anims.rigless_anim_length("nonexistent_anim_xyz"), -1.0,
			"缺资源时长应返回 -1")
	_runner.assert_equal(Anims.rigless_anim_event_time("nonexistent_anim_xyz", "Hit"), -1.0,
			"缺资源事件帧应返回 -1")


func _test_attack_return() -> void:
	var pair := _make_pair()
	var e: StubEntity = pair[0]
	var vc: Node = pair[1]
	vc.call("play_attack", "attack", false)
	_runner.assert_equal(e._current_anim, "attack", "起挥后实体动画应为 attack")
	var ms: Dictionary = vc.call("get_mirror_anim_state")
	_runner.assert_true(str(ms["anim"]).begins_with("attack"),
			"镜像观测口应显示攻击动画，实际 %s" % ms["anim"])
	# 快进物理帧（attack 1.333s；分两拍喂防边界）
	vc.call("_physics_process", 0.7)
	_runner.assert_equal(e._current_anim, "attack", "播完前不应回切")
	vc.call("_physics_process", 0.7)
	_runner.assert_equal(e._current_anim, "idle", "播完应软件回切 idle（速度 0）")
	ms = vc.call("get_mirror_anim_state")
	_runner.assert_equal(str(ms["anim"]), "idle", "回切后镜像观测口应回落 idle")


func _test_seq_repeat() -> void:
	var pair := _make_pair()
	var vc: Node = pair[1]
	vc.call("play_attack", "attack", false)
	var s1: int = int(vc.call("get_mirror_anim_state")["seq"])
	vc.call("play_attack", "attack", false)
	var s2: int = int(vc.call("get_mirror_anim_state")["seq"])
	_runner.assert_true(s2 > s1, "同名重播 seq 必须递增（连续第二刀可见），%d → %d" % [s1, s2])


func _test_hit_pulse() -> void:
	var pair := _make_pair()
	var vc: Node = pair[1]
	# 基础受击：状态名直出，无变体换装
	vc.call("play_hit", true, false, false, false)
	var ms: Dictionary = vc.call("get_mirror_anim_state")
	_runner.assert_equal(str(ms["anim"]), "hit_front", "正面基础受击应显示 hit_front 状态")
	_runner.assert_equal(str(ms["swap"]), "", "基础受击无变体换装")
	# 强击受击：变体池换装（状态仍是 hit_front，变体动画资源另出）
	vc.call("play_hit", true, true, false, false)
	ms = vc.call("get_mirror_anim_state")
	_runner.assert_equal(str(ms["anim"]), "hit_front", "强击受击状态仍为 hit_front（变体换装不换状态）")
	_runner.assert_true(not str(ms["swap"]).is_empty() and str(ms["swap"]) != "hit_front",
			"强击受击应带变体资源名，实际 %s" % ms["swap"])
	# 攻击变体：override=状态名 attack、swap=编号变体（状态机无变体节点，
	# 旧实现把变体名当状态播 = rig.play 报错且换装丢失）
	vc.call("play_attack", "attack", false)
	ms = vc.call("get_mirror_anim_state")
	_runner.assert_equal(str(ms["anim"]), "attack", "攻击 override 应为状态名 attack")
	var swap_name := str(ms["swap"])
	_runner.assert_true(swap_name.is_empty() or not swap_name.begins_with("hit"),
			"攻击 swap 应为攻击变体或空，实际 %s" % swap_name)
	# 插播播完回落 _current_anim（受击未改它，仍 idle）
	vc.call("_physics_process", 2.0)
	ms = vc.call("get_mirror_anim_state")
	_runner.assert_equal(str(ms["anim"]), "idle", "受击插播播完应回落原状态")


func _test_speed_cache() -> void:
	var pair := _make_pair()
	var vc: Node = pair[1]
	vc.call("set_anim_speed", 1.4)
	var ms: Dictionary = vc.call("get_mirror_anim_state")
	_runner.assert_true(absf(float(ms["speed"]) - 1.4) < 0.001,
			"速率缓存应=输入×速度档(1.0)，实际 %.3f" % float(ms["speed"]))
