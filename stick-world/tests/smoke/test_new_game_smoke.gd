extends Node
## 冒烟测试：新游戏启动后运行 60s，验证不崩溃、关键里程碑达成。
## 场景：完整 GameRoot（含全部子系统装配）。
## 验收：map 就绪 + 玩家/NPC 生成 + 60s 持续运行无异常退出。

const TestRunner := preload("res://tests/core/test_runner.gd")
const TestHelpers := preload("res://tests/core/test_helpers.gd")
const GAME_ROOT_SCENE: PackedScene = preload("res://modules/world/scenes/game_root.tscn")

const SMOKE_DURATION: float = 60.0

var _runner: TestRunner
var _game_root: Node = null


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("冒烟: GameRoot 启动装配", _test_boot, true)
	_runner.add_test("冒烟: 60s 持续运行不崩溃", _test_run_60s, true)
	await _runner.run_async()
	print(_runner.summary())
	get_tree().quit(0 if _runner.all_passed() else 1)


func _test_boot() -> void:
	_game_root = GAME_ROOT_SCENE.instantiate()
	add_child(_game_root)
	var ok: bool = await TestHelpers.await_condition(
		func(): return _game_root != null and is_instance_valid(_game_root) and _game_root.has_method("get_current_map") and _game_root.get_current_map() != null,
		15.0, "GameRoot 地图就绪"
	)
	_runner.assert_true(ok, "GameRoot 应在 15s 内装配出地图")
	if not ok:
		return
	var map: Node2D = _game_root.get_current_map()
	_runner.assert_true(map != null, "当前地图非空")
	# 玩家与 NPC 生成
	var ok2: bool = await TestHelpers.await_condition(
		func(): return map != null and is_instance_valid(map) and map.has_method("get_entities") and map.get_entities().size() >= 2,
		10.0, "实体生成（玩家+至少 1 NPC）"
	)
	_runner.assert_true(ok2, "应生成玩家与 NPC（实体数 >= 2）")


func _test_run_60s() -> void:
	if _game_root == null or not is_instance_valid(_game_root):
		_runner.assert_true(false, "前置启动失败，跳过 60s 运行")
		return
	var elapsed: float = 0.0
	var last_check: float = 0.0
	var tree_ok: bool = true
	while elapsed < SMOKE_DURATION:
		await get_tree().process_frame
		elapsed += get_process_delta_time()
		# 每 10s 检查一次场景树健康
		if elapsed - last_check >= 10.0:
			last_check = elapsed
			var map: Node2D = _game_root.get_current_map() if _game_root.has_method("get_current_map") else null
			if map == null or not is_instance_valid(map):
				tree_ok = false
				break
			var entities: Array = map.get_entities() if map.has_method("get_entities") else []
			if entities.is_empty():
				tree_ok = false
				break
	_runner.assert_true(tree_ok, "60s 运行期间地图与实体持续健康（已运行 %.0fs）" % elapsed)
	print("[smoke] 60s 冒烟完成，实体数=%d" % (
		_game_root.get_current_map().get_entities().size() if _game_root.has_method("get_current_map") and _game_root.get_current_map() != null else -1
	))
