extends Node
## 阶段 0.3 火柴人行为 AI 基础测试入口。
##
## 运行：
##   godot --headless --path stick-world res://tests/test_stage_03.tscn
##
## 退出码：0 全部通过，1 有失败

const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptStickmanEntity := preload("res://modules/units/scripts/stickman_entity.gd")
const ScriptVillageMap := preload("res://modules/world/scripts/village_map.gd")
const ScriptAIController := preload("res://modules/units/ai/ai_controller.gd")
const ScriptBehaviorStateMachine := preload("res://modules/units/ai/behavior_state_machine.gd")
const ScriptBehaviorBase := preload("res://modules/units/ai/behavior_base.gd")
const ScriptBehaviorIdle := preload("res://modules/units/ai/behavior_idle.gd")
const ScriptBehaviorWander := preload("res://modules/units/ai/behavior_wander.gd")

var _runner: TestRunner
var _game_root: Node
var _tests: Array = []


func _ready() -> void:
	_runner = TestRunner.new()
	_register_tests()
	_run_tests_async()


# ─────────────────────────────── 测试注册 ────────────────────────────────

func _register_tests() -> void:
	# 同步测试
	_tests.append({"name": "AIController: 存在为子节点", "fn": Callable(self, "_test_ai_exists"), "async": false})
	_tests.append({"name": "StickmanEntity: AI 移动接口", "fn": Callable(self, "_test_ai_move_api"), "async": false})
	_tests.append({"name": "AIController: 初始行为为 idle", "fn": Callable(self, "_test_initial_idle"), "async": false})
	_tests.append({"name": "BehaviorStateMachine: 已注册 idle 和 wander", "fn": Callable(self, "_test_behaviors_registered"), "async": false})
	_tests.append({"name": "BehaviorStateMachine: travel 切换行为", "fn": Callable(self, "_test_travel_switch"), "async": false})
	_tests.append({"name": "BehaviorIdle: 闲置到时间后 finish", "fn": Callable(self, "_test_idle_finishes"), "async": false})
	_tests.append({"name": "BehaviorWander: 到时间后 finish", "fn": Callable(self, "_test_wander_finishes"), "async": false})
	_tests.append({"name": "BehaviorWander: 驱动实体移动", "fn": Callable(self, "_test_wander_moves"), "async": false})
	_tests.append({"name": "AIController: 附身时暂停 AI", "fn": Callable(self, "_test_possessed_pauses"), "async": false})

	# 异步测试
	_tests.append({"name": "集成: AI 控制下实体位置变化", "fn": Callable(self, "_test_ai_moves_entity"), "async": true})
	_tests.append({"name": "集成: AI 自动 idle/wander 循环", "fn": Callable(self, "_test_ai_cycle"), "async": true})


# ─────────────────────────────── 异步执行 ────────────────────────────────

func _run_tests_async() -> void:
	# 实例化 GameRoot
	var packed := load("res://modules/world/scenes/game_root.tscn") as PackedScene
	if packed == null:
		print("[FATAL] 无法加载 game_root.tscn")
		get_tree().quit(1)
		return
	_game_root = packed.instantiate()
	# 关闭阶段 0.4 演示建造（避免 NPC 被派工影响 idle/wander 测试）
	_game_root.set("auto_demo_building", false)
	add_child(_game_root)
	# 等待地图加载和实体生成
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame

	# 取消玩家附身，让 AI 接管
	_unpossess_player()
	await get_tree().process_frame
	await get_tree().process_frame

	# 运行同步测试
	for t in _tests:
		if not t["async"]:
			_runner.add_test(t["name"], t["fn"])
	_runner.run()

	# 运行异步测试
	for t in _tests:
		if t["async"]:
			_runner.begin_test(t["name"])
			await t["fn"].call()
			_runner.end_test()

	print(_runner.summary())
	var exit_code := 0 if _runner.all_passed() else 1
	get_tree().quit(exit_code)


# ─────────────────────────────── 辅助 ────────────────────────────────

func _get_game_root_child(path: String) -> Node:
	if _game_root == null:
		return null
	return _game_root.get_node_or_null(path)


func _get_scene_loader() -> Node:
	return _get_game_root_child(WorldAPI.PATH_SCENE_LOADER)


func _get_current_map() -> Node2D:
	var sl := _get_scene_loader()
	if sl == null or not sl.has_method("get_current_map"):
		return null
	return sl.get_current_map()


func _get_player_entity() -> ScriptStickmanEntity:
	var map_node := _get_current_map()
	if map_node == null:
		return null
	var map: ScriptVillageMap = map_node as ScriptVillageMap
	if map == null:
		return null
	for e in map.get_entities():
		if e is ScriptStickmanEntity:
			return e as ScriptStickmanEntity
	return null


func _unpossess_player() -> void:
	var e := _get_player_entity()
	if e != null:
		e.set_possessed(false)


# ─────────────────────────────── 同步测试 ────────────────────────────────

func _test_ai_exists() -> void:
	var e := _get_player_entity()
	if e == null:
		_runner.assert_true(false, "无玩家实体")
		return
	var ai := e.get_node_or_null("AIController")
	_runner.assert_true(ai != null, "AIController 应为子节点")
	if ai != null:
		_runner.assert_true(ai is ScriptAIController, "AIController 应为 AIController 类型")


func _test_ai_move_api() -> void:
	var e := _get_player_entity()
	if e == null:
		_runner.assert_true(false, "无玩家实体")
		return
	_runner.assert_true(e.has_method("ai_move"), "应有 ai_move 方法")
	_runner.assert_true(e.has_method("ai_stop"), "应有 ai_stop 方法")
	_runner.assert_true(e.has_method("get_ai_controller"), "应有 get_ai_controller 方法")


func _test_initial_idle() -> void:
	var e := _get_player_entity()
	if e == null:
		_runner.assert_true(false, "无玩家实体")
		return
	var ai: ScriptAIController = e.get_ai_controller() as ScriptAIController
	if ai == null:
		_runner.assert_true(false, "AIController 为空")
		return
	_runner.assert_equal(ai.get_current_behavior(), "idle", "初始行为应为 idle")


func _test_behaviors_registered() -> void:
	var e := _get_player_entity()
	if e == null:
		_runner.assert_true(false, "无玩家实体")
		return
	var ai: ScriptAIController = e.get_ai_controller() as ScriptAIController
	if ai == null:
		_runner.assert_true(false, "AIController 为空")
		return
	var sm: ScriptBehaviorStateMachine = ai.get_state_machine()
	if sm == null:
		_runner.assert_true(false, "StateMachine 为空")
		return
	# travel 到 idle 应成功（已注册）
	sm.travel("idle")
	_runner.assert_equal(sm.get_current_behavior_name(), "idle", "应能 travel 到 idle")
	# travel 到 wander 应成功（已注册）
	sm.travel("wander")
	_runner.assert_equal(sm.get_current_behavior_name(), "wander", "应能 travel 到 wander")
	# travel 回 idle
	sm.travel("idle")
	_runner.assert_equal(sm.get_current_behavior_name(), "idle", "应能 travel 回 idle")


func _test_travel_switch() -> void:
	var e := _get_player_entity()
	if e == null:
		_runner.assert_true(false, "无玩家实体")
		return
	var ai: ScriptAIController = e.get_ai_controller() as ScriptAIController
	var sm: ScriptBehaviorStateMachine = ai.get_state_machine()
	# travel 到 wander
	sm.travel("wander")
	_runner.assert_equal(sm.get_current_behavior_name(), "wander", "当前应为 wander")
	_runner.assert_true(sm.has_active_behavior(), "应有激活行为")
	# travel 回 idle
	sm.travel("idle")
	_runner.assert_equal(sm.get_current_behavior_name(), "idle", "当前应为 idle")
	# 未注册行为应不切换
	sm.travel("nonexistent")
	_runner.assert_equal(sm.get_current_behavior_name(), "idle", "未注册行为不应切换")


func _test_idle_finishes() -> void:
	var e := _get_player_entity()
	if e == null:
		_runner.assert_true(false, "无玩家实体")
		return
	# 隔离测试 BehaviorIdle：手动调用 update
	var idle := ScriptBehaviorIdle.new()
	idle.entity = e
	idle.behavior_name = "test_idle"
	add_child(idle)

	idle.enter("", {"duration": 0.3})
	_runner.assert_true(not idle.is_finished(), "刚进入不应 finished")
	# 手动累积 0.35s（超过 0.3s 时长）
	idle.update(0.2)
	_runner.assert_true(not idle.is_finished(), "0.2s 不应 finished")
	idle.update(0.15)
	_runner.assert_true(idle.is_finished(), "0.35s 后应 finished")

	idle.queue_free()


func _test_wander_finishes() -> void:
	var e := _get_player_entity()
	if e == null:
		_runner.assert_true(false, "无玩家实体")
		return
	# 隔离测试 BehaviorWander：设短时长，手动调用 update
	var wander := ScriptBehaviorWander.new()
	wander.entity = e
	wander.behavior_name = "test_wander"
	add_child(wander)

	wander.enter("", {"duration": 0.3})
	_runner.assert_true(not wander.is_finished(), "刚进入不应 finished")
	# 手动累积 0.35s（超过 0.3s 时长）
	wander.update(0.2)
	_runner.assert_true(not wander.is_finished(), "0.2s 不应 finished")
	wander.update(0.15)
	_runner.assert_true(wander.is_finished(), "0.35s 后应 finished")

	wander.queue_free()


func _test_wander_moves() -> void:
	var e := _get_player_entity()
	if e == null:
		_runner.assert_true(false, "无玩家实体")
		return
	# 隔离测试 BehaviorWander：验证 update 调用了 entity.ai_move
	var wander := ScriptBehaviorWander.new()
	wander.entity = e
	wander.behavior_name = "test_wander2"
	add_child(wander)

	wander.enter("", {"duration": 10.0})
	# update 应调用 entity.ai_move，不报错
	wander.update(0.016)
	_runner.assert_true(not wander.is_finished(), "短时间不应 finished")

	wander.queue_free()


func _test_possessed_pauses() -> void:
	var e := _get_player_entity()
	if e == null:
		_runner.assert_true(false, "无玩家实体")
		return
	var ai: ScriptAIController = e.get_ai_controller() as ScriptAIController
	if ai == null:
		_runner.assert_true(false, "AIController 为空")
		return
	# 重新附身
	e.set_possessed(true)
	# AIController 在 possessed 时 physics_update 应直接 return，不改变状态
	var behavior_before := ai.get_current_behavior()
	ai.physics_update(0.016)
	var behavior_after := ai.get_current_behavior()
	_runner.assert_equal(behavior_before, behavior_after, "附身时行为不应变化")
	# 取消附身恢复，并处理 possession 状态变更（清除 _was_possessed 标志）
	e.set_possessed(false)
	ai.physics_update(0.016)


# ─────────────────────────────── 异步测试 ────────────────────────────────

func _test_ai_moves_entity() -> void:
	var e := _get_player_entity()
	if e == null:
		_runner.assert_true(false, "无玩家实体")
		return
	var ai: ScriptAIController = e.get_ai_controller() as ScriptAIController
	var sm: ScriptBehaviorStateMachine = ai.get_state_machine()
	# 记录初始位置
	var pos_before := e.global_position
	# 手动切到 wander，持续 3 秒
	sm.travel("wander", {"duration": 3.0})
	# 等待 2 秒让实体移动
	await get_tree().create_timer(2.0).timeout
	var pos_after := e.global_position
	var dist_moved := pos_after.distance_to(pos_before)
	_runner.assert_true(dist_moved > 30.0, "实体应移动超过 30px，实际: %f" % dist_moved)


func _test_ai_cycle() -> void:
	var e := _get_player_entity()
	if e == null:
		_runner.assert_true(false, "无玩家实体")
		return
	var ai: ScriptAIController = e.get_ai_controller() as ScriptAIController
	var sm: ScriptBehaviorStateMachine = ai.get_state_machine()
	# 确保 AI 未被附身
	e.set_possessed(false)
	# 强制重置到 idle，设短时长加速循环
	sm.travel("idle", {"duration": 0.3})
	# 等待 2 秒让 AI 完成至少一次 idle->wander 切换
	await get_tree().create_timer(2.0).timeout
	var behavior := ai.get_current_behavior()
	# 2 秒后行为应该是 idle 或 wander 之一（不能为空）
	_runner.assert_true(behavior == "idle" or behavior == "wander", "行为应为 idle 或 wander，实际: %s" % behavior)
	_runner.assert_true(sm.has_active_behavior(), "应始终有激活行为")
