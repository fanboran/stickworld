extends Node
## 集成测试：rig.animation_finished 动画结束信号（反编译参考实装 C）。
##
## 覆盖：
##   - attack（LOOP_NONE）播放完 → animation_finished("attack") 触发
##   - 攻击播完自动回切 walk/idle（VisualController 监听）
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

	_runner.begin_test("攻击动画: attack 播完发射 animation_finished")
	var rig: Node2D = entity.get("rig")
	if rig == null:
		_runner.assert_true(false, "实体无 rig")
		get_tree().quit(1)
		return
	var finished: Array = []
	rig.connect("animation_finished", func(anim_name): finished.append(anim_name))
	# 播放攻击动画（LOOP_NONE，解包 Spine 数据转换后约 1.33s），经 VisualController.play → rig 状态机
	entity.get("_visual").play("attack")
	_runner.assert_equal(entity.get("_current_anim"), "attack", "实体当前动画应为 attack")
	# 等 1.6s（attack 约 1.33s 播完 + 回切余量）
	await get_tree().create_timer(1.6).timeout
	_runner.assert_true(finished.size() >= 1, "attack 应触发 animation_finished，实际 %d 次" % finished.size())
	if not finished.is_empty():
		_runner.assert_equal(finished[0], "attack", "结束信号动画名应为 attack")
	_runner.end_test()
	print(_runner.summary())
	get_tree().quit(0 if _runner.all_passed() else 1)
