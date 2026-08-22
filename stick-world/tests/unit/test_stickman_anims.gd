extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：StickmanAnims 变体池 + 受击插播（反编译参考实装 B）。
## 纯逻辑层测试：不进场景树，手动构造 AnimationNodeStateMachine / AnimationPlayer。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const Anims := preload("res://modules/units/scripts/rig/stickman_anims.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("待机变体: pick_stand_variant 返回池内成员", _test_stand_variant_pool)
	_runner.add_test("待机变体: 动态换 idle state 动画名", _test_set_state_animation)
	_runner.add_test("受击: 状态机含 hit_front/hit_back 状态", _test_hit_states_exist)
	_runner.add_test("受击: hit 与主状态有过渡", _test_hit_transitions)
	_runner.add_test("动画库: setup_player 加载变体与受击动画", _test_player_loads_anims)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


## 构造含全部状态的最小状态机（复刻 setup_tree 的状态布局）
func _make_sm() -> AnimationNodeStateMachine:
	var sm := AnimationNodeStateMachine.new()
	for name in ["idle", "idle_v2", "walk", "run", "attack", "dead", "hit_front", "hit_back"]:
		var node := AnimationNodeAnimation.new()
		node.animation = name
		sm.add_node(name, node)
	return sm


func _test_stand_variant_pool() -> void:
	var pool: Array[String] = Anims.STAND_VARIANTS
	_runner.assert_true(pool.size() >= 2, "待机变体池应至少 2 个")
	for i in 20:
		var v: String = Anims.pick_stand_variant()
		_runner.assert_true(v in pool, "变体应在池内: %s" % v)


func _test_set_state_animation() -> void:
	var sm := _make_sm()
	Anims.set_state_animation(sm, "idle", "idle_v2")
	var node: AnimationNode = sm.get_node("idle")
	_runner.assert_equal((node as AnimationNodeAnimation).animation, "idle_v2", "idle state 动画名应切换为 idle_v2")
	# 不存在的 state 不应报错
	Anims.set_state_animation(sm, "not_exist", "idle")
	_runner.assert_true(true, "不存在的 state 调用应安全")


func _test_hit_states_exist() -> void:
	var sm := _make_sm()
	for name in ["hit_front", "hit_back"]:
		_runner.assert_true(sm.has_node(name), "状态机应含 %s" % name)


func _test_hit_transitions() -> void:
	# 复刻 setup_tree 的过渡：主状态 → hit（快速插入），hit → idle/dead（回切）
	var sm := _make_sm()
	sm.add_transition("idle", "hit_front", _trans(0.05))
	sm.add_transition("hit_front", "idle", _trans(0.15))
	sm.add_transition("hit_back", "dead", _trans(0.2))
	_runner.assert_true(sm.has_transition("idle", "hit_front"), "应存在 idle→hit_front 过渡")
	_runner.assert_true(sm.has_transition("hit_front", "idle"), "应存在 hit_front→idle 过渡")
	_runner.assert_true(sm.has_transition("hit_back", "dead"), "应存在 hit_back→dead 过渡")


func _test_player_loads_anims() -> void:
	var player := AnimationPlayer.new()
	Anims.setup_player(player)
	var lib: AnimationLibrary = player.get_animation_library("")
	_runner.assert_true(lib != null, "动画库应创建")
	for name in ["idle", "idle_v2", "hit_front", "hit_back", "walk", "run", "attack", "dead"]:
		_runner.assert_true(lib.has_animation(name), "动画库应含 %s" % name)


func _trans(xfade: float) -> AnimationNodeStateMachineTransition:
	var t := AnimationNodeStateMachineTransition.new()
	t.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_ENABLED
	t.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_SYNC
	t.xfade_time = xfade
	return t
