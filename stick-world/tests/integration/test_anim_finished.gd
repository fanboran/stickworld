extends Node
## 集成测试：rig.animation_finished 动画结束信号（反编译参考实装 C）。
##
## 覆盖：
##   - attack（LOOP_NONE）播放完 → animation_finished("attack") 触发 + 自动回切
##   - 连续第二刀（播放中重播同款一次性动画，rig.play 走 start() 分支）→
##     结束信号必须再次发射 + 回切（回归：曾因 start() 未清 _finished_sent_state，
##     第二刀播完不回切，攻击锁移动后表现为"按 F 卡死不能动"）
##
## 运行：godot --headless --path stick-world res://tests/integration/test_anim_finished.tscn
## 退出码：0 通过，1 失败

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const STICKMAN_SCENE: PackedScene = preload("res://modules/units/scenes/stickman_entity.tscn")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_run_tests_async()


func _run_tests_async() -> void:
	# 实例化火柴人实体（独立场景，自包含骨骼/动画/武器）
	var entity: Node2D = STICKMAN_SCENE.instantiate()
	add_child(entity)
	for i in 4:
		await get_tree().process_frame

	var rig: Node2D = entity.get("rig")
	if rig == null:
		_runner.begin_test("前置: 实体有 rig")
		_runner.assert_true(false, "实体无 rig")
		_runner.end_test()
		print(_runner.summary())
		get_tree().quit(1)
		return
	var finished: Array = []
	rig.connect("animation_finished", func(anim_name): finished.append(anim_name))
	var visual: Node = entity.get("_visual")

	# ── 用例 1：第一刀播完发射 + 回切 ──
	_runner.begin_test("攻击动画: attack 播完发射 animation_finished")
	visual.play("attack")
	_runner.assert_equal(entity.get("_current_anim"), "attack", "实体当前动画应为 attack")
	# 等 1.6s（attack 约 1.33s 播完 + 回切余量）
	await get_tree().create_timer(1.6).timeout
	_runner.assert_true(finished.size() >= 1, "attack 应触发 animation_finished，实际 %d 次" % finished.size())
	if not finished.is_empty():
		_runner.assert_equal(finished[0], "attack", "结束信号动画名应为 attack")
	_runner.assert_true(entity.get("_current_anim") != "attack", "第一刀播完应回切 walk/idle")
	_runner.end_test()

	# ── 用例 2：播放中重播（第二刀，走 rig.play 的 start() 强制重播分支）──
	_runner.begin_test("攻击动画: 播放中重播第二刀仍发射 animation_finished 并回切")
	visual.play("attack")
	await get_tree().create_timer(0.2).timeout
	# 0.2s < 动画 1.33s：此刻 state 仍是 attack → 再 play 走 start() 重播分支
	_runner.assert_equal(rig._state_machine.get_current_node(), "attack", "重播前应仍在 attack 状态")
	var count_before: int = finished.size()
	visual.play("attack")
	_runner.assert_equal(entity.get("_current_anim"), "attack", "第二刀应重新进入 attack")
	# 重播应把播放位置打回起点（结束信号重新武装的证据）
	_runner.assert_lt(rig._state_machine.get_current_play_position(), 0.5,
			"重播后播放位置应回到开头")
	await get_tree().create_timer(1.8).timeout
	_runner.assert_true(finished.size() > count_before,
			"第二刀播完应再次发射 animation_finished（重播前 %d 次 → 现 %d 次）"
					% [count_before, finished.size()])
	_runner.assert_true(entity.get("_current_anim") != "attack",
			"第二刀播完应回切 walk/idle（不卡在 attack）")
	_runner.end_test()

	print(_runner.summary())
	get_tree().quit(0 if _runner.all_passed() else 1)
