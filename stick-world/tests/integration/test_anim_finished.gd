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
const TestHelpers := preload("res://tests/core/test_helpers.gd")
const STICKMAN_SCENE: PackedScene = preload("res://modules/units/scenes/stickman_entity.tscn")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_run_tests_async()


func _run_tests_async() -> void:
	# 实例化火柴人实体（独立场景，自包含骨骼/动画/武器）：
	# 就绪等待 = rig 装配完成（条件等待替代数帧，README 硬规矩）
	var entity: Node2D = STICKMAN_SCENE.instantiate()
	add_child(entity)
	var rig_ready: bool = await TestHelpers.await_condition(
			func() -> bool: return entity.get("rig") != null,
			5.0, "火柴人实体 rig 装配")
	_runner.assert_true(rig_ready, "实体应在 5s 内装配出 rig")

	var rig: Node2D = entity.get("rig")
	if rig == null:
		_runner.begin_test("前置: 实体有 rig")
		_runner.assert_true(false, "实体无 rig")
		_runner.end_test()
		print(_runner.summary())
		TestRunner.finish_process(self, 1)
		return
	var finished: Array = []
	rig.connect("animation_finished", func(anim_name): finished.append(anim_name))
	var visual: Node = entity.get("_visual")

	# ── 用例 1：第一刀播完发射 + 回切 ──
	_runner.begin_test("攻击动画: attack 播完发射 animation_finished")
	visual.play("attack")
	_runner.assert_equal(entity.get("_current_anim"), "attack", "实体当前动画应为 attack")
	# 动画约 1.33s 播完：等 animation_finished 信号面（finished 非空）而非固定等 1.6s
	var first_done: bool = await TestHelpers.await_condition(
			func() -> bool: return not finished.is_empty(),
			2.5, "attack 播完触发 animation_finished")
	_runner.assert_true(first_done, "attack 应触发 animation_finished，实际 %d 次" % finished.size())
	if not finished.is_empty():
		_runner.assert_equal(finished[0], "attack", "结束信号动画名应为 attack")
	_runner.assert_true(entity.get("_current_anim") != "attack", "第一刀播完应回切 walk/idle")
	_runner.end_test()

	# ── 用例 2：播放中重播（第二刀，走 rig.play 的 start() 强制重播分支）──
	_runner.begin_test("攻击动画: 播放中重播第二刀仍发射 animation_finished 并回切")
	visual.play("attack")
	# 固定 settle 语义：必须停在动画**未播完**的中段（0.2s < 1.33s）才能走进
	# start() 强制重播分支——这正是被测前提，条件化会改变测试对象，保留有界实等待
	await get_tree().create_timer(0.2).timeout
	# 0.2s < 动画 1.33s：此刻 state 仍是 attack → 再 play 走 start() 重播分支
	_runner.assert_equal(rig._state_machine.get_current_node(), "attack", "重播前应仍在 attack 状态")
	var count_before: int = finished.size()
	visual.play("attack")
	_runner.assert_equal(entity.get("_current_anim"), "attack", "第二刀应重新进入 attack")
	# 重播应把播放位置打回起点（结束信号重新武装的证据）
	_runner.assert_lt(rig._state_machine.get_current_play_position(), 0.5,
			"重播后播放位置应回到开头")
	# 等第二刀播完再发一次 animation_finished（信号面条件等待，预算 2.5s）
	var second_done: bool = await TestHelpers.await_condition(
			func() -> bool: return finished.size() > count_before,
			2.5, "第二刀播完再次发射 animation_finished")
	_runner.assert_true(second_done,
			"第二刀播完应再次发射 animation_finished（重播前 %d 次 → 现 %d 次）"
					% [count_before, finished.size()])
	_runner.assert_true(entity.get("_current_anim") != "attack",
			"第二刀播完应回切 walk/idle（不卡在 attack）")
	_runner.end_test()

	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)
