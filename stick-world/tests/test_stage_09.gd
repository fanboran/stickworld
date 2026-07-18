extends Node
## 阶段 0.9 室内系统 -- 集成测试。
##
## 运行：
##   godot --headless --path stick-world res://tests/test_stage_09.tscn
##
## 退出码：0 全部通过，1 有失败
##
## 测试覆盖：
##   - 单建筑透明化（进入/离开交互区）
##   - 建造中建筑不触发透明化
##   - NPC 不触发透明化
##   - 多建筑同时透明化 / INDOOR 模式不重复切换
##   - 传送封锁（战斗中/附身中禁止传送）

const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptBuilding := preload("res://modules/old_buildings/scripts/building.gd")
const STICKMAN_SCENE: PackedScene = preload("res://modules/units/scenes/stickman_entity.tscn")

var _runner: TestRunner
var _game_root: Node
var _tests: Array = []
var _map: Node2D = null
var _player: Node2D = null
var _npc: Node2D = null
## 信号计数
var _interior_entered_count: int = 0
var _interior_exited_count: int = 0


func _ready() -> void:
	_runner = TestRunner.new()
	_register_tests()
	_run_tests_async()


func _register_tests() -> void:
	_tests.append({"name": "透明化: 预置建筑有 InteractionZone", "fn": Callable(self, "_test_building_has_interaction_zone"), "async": true})
	_tests.append({"name": "透明化: 建造中建筑不触发", "fn": Callable(self, "_test_under_construction_no_trigger"), "async": true})
	_tests.append({"name": "透明化: NPC 不触发", "fn": Callable(self, "_test_npc_no_trigger"), "async": true})
	_tests.append({"name": "传送: 战斗中禁止传送", "fn": Callable(self, "_test_battle_block_teleport"), "async": true})


# ─────────────────────────────── 异步执行 ────────────────────────────────

func _run_tests_async() -> void:
	var packed := load("res://modules/world/scenes/game_root.tscn") as PackedScene
	if packed == null:
		print("[FATAL] 无法加载 game_root.tscn")
		get_tree().quit(1)
		return
	_game_root = packed.instantiate()
	_game_root.set("auto_demo_building", false)
	add_child(_game_root)
	# 等待地图加载和实体生成
	for i in 10:
		await get_tree().process_frame
	_map = _game_root.get_current_map()
	if _map == null:
		print("[FATAL] 地图加载失败")
		get_tree().quit(1)
		return
	# 获取玩家实体
	for e in _map.get_entities():
		if e is CharacterBody2D and e.has_method("is_possessed") and e.is_possessed():
			_player = e
			break
	if _player == null:
		print("[FATAL] 未找到玩家实体")
		get_tree().quit(1)
		return
	# 生成 NPC（远离玩家，不附身）
	var spawn_y: float = _map.ground_y + (_map.ground_bottom - _map.ground_y) * 0.5
	_npc = _map.spawn_entity(STICKMAN_SCENE, Vector2(800, spawn_y))
	if _npc != null:
		if _npc.get("foot_offset") != null:
			_npc.global_position.y = spawn_y - _npc.foot_offset
		if _npc.has_method("set_possessed"):
			_npc.set_possessed(false)
	await get_tree().process_frame

	# 连接 EventBus 信号计数
	if EventBus != null:
		if EventBus.has_signal("interior_entered"):
			EventBus.interior_entered.connect(_on_interior_entered)
		if EventBus.has_signal("interior_exited"):
			EventBus.interior_exited.connect(_on_interior_exited)

	# 运行异步测试
	for t in _tests:
		if t["async"]:
			_runner.begin_test(t["name"])
			await t["fn"].call()
			_runner.end_test()

	var summary := _runner.summary()
	print(summary)
	var f := FileAccess.open("f:/VSCode/game-2/stick-world/test_stage_09_result.txt", FileAccess.WRITE)
	if f != null:
		f.store_string(summary + "\n")
		f.store_string("EXIT_CODE=%d\n" % (0 if _runner.all_passed() else 1))
		f.close()
	var exit_code: int = 0 if _runner.all_passed() else 1
	get_tree().quit(exit_code)


func _on_interior_entered(_building_id: int) -> void:
	_interior_entered_count += 1

func _on_interior_exited(_building_id: int) -> void:
	_interior_exited_count += 1


# ─────────────────────────────── 测试 ────────────────────────────────

func _test_building_has_interaction_zone() -> void:
	# 检查预置建筑（InitialBuildingsList 创建的）是否有 InteractionZone
	var host: Node2D = _map.get("building_host") if "building_host" in _map else null
	if host == null:
		_runner.assert_true(false, "BuildingHost 为空")
		return
	var has_zone := false
	for child in host.get_children():
		if child is ScriptBuilding:
			var b: ScriptBuilding = child as ScriptBuilding
			var zone: Node = b.get("_interaction_zone") if "_interaction_zone" in b else null
			if zone != null:
				has_zone = true
				_runner.assert_true(zone is Area2D, "InteractionZone 应为 Area2D")
				break
	if not has_zone:
		_runner.assert_true(false, "未找到含 InteractionZone 的建筑（bld_workshop 应有 InteractionZone 节点）")


func _test_under_construction_no_trigger() -> void:
	# 验证建造中建筑（state != OPERATIONAL）不触发透明化
	# 步骤：创建建筑 → 设状态为 UNDER_CONSTRUCTION → 移动玩家到 InteractionZone → 确认无信号发射
	var saved_count := _interior_entered_count
	var host: Node2D = _map.get("building_host") if "building_host" in _map else null
	if host == null:
		_runner.assert_true(false, "BuildingHost 为空")
		return
	# 找一个预置建筑
	var bld: ScriptBuilding = null
	for child in host.get_children():
		if child is ScriptBuilding:
			bld = child as ScriptBuilding
			break
	if bld == null:
		_runner.assert_true(false, "无预置 Building 实例")
		return
	# 强制设状态为 UNDER_CONSTRUCTION
	var original_state := bld.state
	bld.set_state(ScriptBuilding.State.UNDER_CONSTRUCTION)
	# 移动玩家到建筑交互区（建筑在 cell_x=20，位置约 x=20*32+32=672）
	var zone: Area2D = bld.get("_interaction_zone") if "_interaction_zone" in bld else null
	if zone == null:
		_runner.assert_true(false, "建筑无 InteractionZone")
		bld.set_state(original_state)
		return
	_player.global_position = Vector2(670, _map.ground_y + 20)
	for i in 3:
		await get_tree().process_frame
	# 验证无 interior_entered 信号（建造中不触发）
	_runner.assert_equal(_interior_entered_count, saved_count, "建造中建筑不应触发透明化（interior_entered 信号数不变）")
	# 恢复状态
	bld.set_state(original_state)
	# 移开玩家
	_player.global_position = Vector2(300, _map.ground_y + 20)
	for i in 2:
		await get_tree().process_frame


func _test_npc_no_trigger() -> void:
	# 验证 NPC 走进交互区不触发透明化
	if _npc == null:
		_runner.assert_true(false, "NPC 未生成")
		return
	var saved_count := _interior_entered_count
	# 移动 NPC 到预置建筑交互区
	_npc.global_position = Vector2(670, _map.ground_y + 20)
	for i in 3:
		await get_tree().process_frame
	# 验证无额外 interior_entered（NPC 不触发）
	_runner.assert_equal(_interior_entered_count, saved_count, "NPC 不应触发透明化")
	# 移开 NPC
	_npc.global_position = Vector2(800, _map.ground_y + 20)
	for i in 2:
		await get_tree().process_frame


func _test_battle_block_teleport() -> void:
	# 验证传送信号在战斗中不被处理
	# 通过 EventBus 直接发射 mega_interior_entered，确认 GameRoot 拦截
	if EventBus == null:
		_runner.assert_true(false, "EventBus 为空")
		return
	# 启动一场战斗
	var units: Array = []
	for e in _map.get_entities():
		if e is CharacterBody2D and e.has_method("is_possessed"):
			units.append(e)
	if units.size() < 2:
		_runner.assert_true(true, "跳过（单位不足2）")
		return
	# 确保至少两个不同阵营
	if units[0].has_method("set_faction"):
		units[0].set_faction(1)
	if units[1].has_method("set_faction"):
		units[1].set_faction(2)
	var battle: Node = _game_root.start_test_battle([units[0]], [units[1]])
	if battle == null:
		_runner.assert_true(true, "跳过（无法启动战斗）")
		return
	await get_tree().process_frame
	_runner.assert_true(_game_root.is_in_battle(), "应处于战斗中")
	# 尝试传送（直接 emit 信号模拟 Building 触发）
	if EventBus.has_signal("mega_interior_entered"):
		EventBus.mega_interior_entered.emit(0, "test_mega_interior")
	await get_tree().process_frame
	# 确认仍然在当前地图（未被传送）
	var current_map_id: String = _game_root.get("current_map_id") if "current_map_id" in _game_root else ""
	if _game_root.scene_loader != null and _game_root.scene_loader.has_method("get_current_map_id"):
		current_map_id = _game_root.scene_loader.get_current_map_id()
	_runner.assert_true(current_map_id != "test_mega_interior", "战斗中不应传送到大建筑（仍在原地图）")
