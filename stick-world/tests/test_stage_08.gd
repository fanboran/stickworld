extends Node
## 阶段 0.8 多场景衔接测试入口。
##
## 运行：
##   godot --headless --path stick-world res://tests/test_stage_08.tscn
##
## 退出码：0 全部通过，1 有失败
##
## 测试内容：
##   1. SceneLoader 多地图注册 + 出口配置
##   2. 初始村落 A 加载
##   3. 旅行到道路地图（EventBus 信号转发）
##   4. RoadMap 结构与 API
##   5. 旅行到村落 B
##   6. 完整链路：村落A -> 道路 -> 村落B
##   7. ChunkTrigger 配置验证

const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptSceneLoader := preload("res://modules/world/scripts/scene_loader.gd")
const ScriptVillageMap := preload("res://modules/world/scripts/village_map.gd")
const ScriptRoadMap := preload("res://modules/world/scripts/road_map.gd")
const ScriptChunkTrigger := preload("res://modules/world/scripts/chunk_trigger.gd")
const ScriptGameRoot := preload("res://modules/world/scripts/game_root.gd")
# WorldAPI / PlayerControlAPI 是全局 class_name

var _runner: TestRunner
var _game_root: Node
var _event_bus_signals: Dictionary = {}  # 记录 EventBus 信号触发


func _ready() -> void:
	_runner = TestRunner.new()
	_run_tests_async()


# ─────────────────────────────── 异步执行 ────────────────────────────────

func _run_tests_async() -> void:
	# 实例化 GameRoot
	var packed := load("res://modules/world/scenes/game_root.tscn") as PackedScene
	if packed == null:
		print("[FATAL] 无法加载 game_root.tscn")
		get_tree().quit(1)
		return
	_game_root = packed.instantiate()
	# 关闭自动演示建造（本测试不关注建造系统）
	_game_root.auto_demo_building = false
	add_child(_game_root)
	# 等待初始地图加载（call_deferred + 多帧确保 spawn 完成）
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame

	# 监听 EventBus 旅行信号
	_connect_event_bus_signals()

	# ── Phase 1: 初始状态测试 ──
	_run_phase_1_tests()

	# ── Phase 2: 旅行到道路 ──
	var sl := _get_scene_loader()
	sl.travel_to_map(ScriptGameRoot.ROAD_MAP_ID, WorldAPI.TravelMode.WALK, WorldAPI.EntrySide.LEFT)
	await get_tree().process_frame
	await get_tree().process_frame
	_run_phase_2_tests()

	# ── Phase 3: 旅行到村落 B ──
	sl.travel_to_map(ScriptGameRoot.VILLAGE_B_MAP_ID, WorldAPI.TravelMode.WALK, WorldAPI.EntrySide.LEFT)
	await get_tree().process_frame
	await get_tree().process_frame
	_run_phase_3_tests()

	# ── Phase 4: 反向旅行（村落B -> 道路 -> 村落A）──
	sl.travel_to_map(ScriptGameRoot.ROAD_MAP_ID, WorldAPI.TravelMode.WALK, WorldAPI.EntrySide.RIGHT)
	await get_tree().process_frame
	await get_tree().process_frame
	sl.travel_to_map(ScriptGameRoot.TEST_VILLAGE_MAP_ID, WorldAPI.TravelMode.WALK, WorldAPI.EntrySide.RIGHT)
	await get_tree().process_frame
	await get_tree().process_frame
	_run_phase_4_tests()

	# 汇总
	print(_runner.summary())
	var exit_code := 0 if _runner.all_passed() else 1
	get_tree().quit(exit_code)


# ─────────────────────────────── 辅助 ────────────────────────────────

func _get_game_root_child(path: String) -> Node:
	if _game_root == null:
		return null
	return _game_root.get_node_or_null(path)


func _get_scene_loader() -> ScriptSceneLoader:
	return _get_game_root_child(WorldAPI.PATH_SCENE_LOADER) as ScriptSceneLoader


func _get_current_map() -> Node2D:
	var sl := _get_scene_loader()
	if sl == null:
		return null
	return sl.get_current_map()


func _connect_event_bus_signals() -> void:
	if EventBus == null:
		return
	EventBus.travel_started.connect(func(f, t, m): _event_bus_signals["travel_started"] = [f, t, m])
	EventBus.travel_completed.connect(func(t): _event_bus_signals["travel_completed"] = t)
	EventBus.map_loaded.connect(func(id, t): _event_bus_signals["map_loaded"] = [id, t])
	EventBus.map_unloaded.connect(func(id): _event_bus_signals["map_unloaded"] = id)


# ─────────────────────────────── Phase 1: 初始状态 ────────────────────────────────

func _run_phase_1_tests() -> void:
	_runner.begin_test("SceneLoader: 多地图注册（3张地图）")
	var sl := _get_scene_loader()
	_runner.assert_true(sl != null, "SceneLoader 应存在")
	if sl == null:
		_runner.end_test()
		return
	_runner.assert_true(sl.has_map(ScriptGameRoot.TEST_VILLAGE_MAP_ID), "应注册 test_village")
	_runner.assert_true(sl.has_map(ScriptGameRoot.ROAD_MAP_ID), "应注册 road_a_to_b")
	_runner.assert_true(sl.has_map(ScriptGameRoot.VILLAGE_B_MAP_ID), "应注册 test_village_b")
	_runner.end_test()

	_runner.begin_test("SceneLoader: 出口配置正确")
	var exit_right: Dictionary = sl.get_map_exit(ScriptGameRoot.TEST_VILLAGE_MAP_ID, WorldAPI.EntrySide.RIGHT)
	_runner.assert_equal(exit_right.get("target", ""), ScriptGameRoot.ROAD_MAP_ID, "村落A 右出应指向道路")
	_runner.assert_equal(exit_right.get("entry", -1), WorldAPI.EntrySide.LEFT, "村落A 右出应从左侧进入道路")
	var road_left: Dictionary = sl.get_map_exit(ScriptGameRoot.ROAD_MAP_ID, WorldAPI.EntrySide.LEFT)
	_runner.assert_equal(road_left.get("target", ""), ScriptGameRoot.TEST_VILLAGE_MAP_ID, "道路左出应指向村落A")
	var road_right: Dictionary = sl.get_map_exit(ScriptGameRoot.ROAD_MAP_ID, WorldAPI.EntrySide.RIGHT)
	_runner.assert_equal(road_right.get("target", ""), ScriptGameRoot.VILLAGE_B_MAP_ID, "道路右出应指向村落B")
	var vb_left: Dictionary = sl.get_map_exit(ScriptGameRoot.VILLAGE_B_MAP_ID, WorldAPI.EntrySide.LEFT)
	_runner.assert_equal(vb_left.get("target", ""), ScriptGameRoot.ROAD_MAP_ID, "村落B 左出应指向道路")
	_runner.end_test()

	_runner.begin_test("初始地图: 村落A 已加载")
	_runner.assert_true(sl.is_map_loaded(), "应已加载地图")
	_runner.assert_equal(sl.get_current_map_id(), ScriptGameRoot.TEST_VILLAGE_MAP_ID, "当前应为 test_village")
	_runner.assert_equal(sl.get_current_map_type(), WorldAPI.MapType.VILLAGE, "类型应为 VILLAGE")
	_runner.end_test()

	_runner.begin_test("初始地图: VillageMap 子节点齐全")
	var map := _get_current_map()
	_runner.assert_true(map != null, "地图应存在")
	if map:
		_runner.assert_true(map.get_node_or_null(WorldAPI.PATH_MAP_ENTITY_HOST) != null, "EntityHost 应存在")
		_runner.assert_true(map.get_node_or_null(WorldAPI.PATH_MAP_CHUNK_TRIGGERS) != null, "ChunkTriggers 应存在")
	_runner.end_test()

	_runner.begin_test("初始地图: ChunkTrigger 存在（村落A 右出口）")
	if map:
		var triggers: Node2D = map.get_node_or_null(WorldAPI.PATH_MAP_CHUNK_TRIGGERS)
		_runner.assert_true(triggers != null and triggers.get_child_count() > 0, "ChunkTriggers 应有子节点")
		if triggers and triggers.get_child_count() > 0:
			var trigger: Node = triggers.get_child(0)
			_runner.assert_true(trigger is Area2D, "触发器应为 Area2D")
			_runner.assert_true(trigger.get_script() == ScriptChunkTrigger, "触发器应挂 chunk_trigger.gd")
	_runner.end_test()

	_runner.begin_test("初始地图: 玩家已生成")
	if map:
		var player: Node2D = map.get_possessed_entity()
		_runner.assert_true(player != null, "应有玩家附身实体")
	_runner.end_test()


# ─────────────────────────────── Phase 2: 道路地图 ────────────────────────────────

func _run_phase_2_tests() -> void:
	_runner.begin_test("旅行信号: EventBus 转发正确")
	_runner.assert_true(_event_bus_signals.has("travel_started"), "应收到 EventBus.travel_started")
	_runner.assert_true(_event_bus_signals.has("travel_completed"), "应收到 EventBus.travel_completed")
	_runner.assert_true(_event_bus_signals.has("map_loaded"), "应收到 EventBus.map_loaded")
	_runner.end_test()

	_runner.begin_test("道路地图: 已加载")
	var sl := _get_scene_loader()
	_runner.assert_equal(sl.get_current_map_id(), ScriptGameRoot.ROAD_MAP_ID, "当前应为 road_a_to_b")
	_runner.assert_equal(sl.get_current_map_type(), WorldAPI.MapType.ROAD, "类型应为 ROAD")
	_runner.end_test()

	_runner.begin_test("道路地图: RoadMap 实例")
	var map := _get_current_map()
	_runner.assert_true(map != null, "地图应存在")
	if map:
		_runner.assert_true(map is ScriptRoadMap, "地图应为 RoadMap")
	_runner.end_test()

	_runner.begin_test("道路地图: 子节点齐全")
	if map:
		_runner.assert_true(map.get_node_or_null(WorldAPI.PATH_MAP_TERRAIN_LAYER) != null, "TerrainLayer 应存在")
		_runner.assert_true(map.get_node_or_null(WorldAPI.PATH_MAP_ENTITY_HOST) != null, "EntityHost 应存在")
		_runner.assert_true(map.get_node_or_null(WorldAPI.PATH_MAP_CHUNK_TRIGGERS) != null, "ChunkTriggers 应存在")
		_runner.assert_true(map.get_node_or_null(WorldAPI.PATH_MAP_GROUND_LINE) != null, "GroundLine 应存在")
	_runner.end_test()

	_runner.begin_test("道路地图: 地面字段正确")
	if map:
		var rm: ScriptRoadMap = map as ScriptRoadMap
		_runner.assert_equal(rm.get_ground_y(), 810.0, "ground_y 应为 810")
		_runner.assert_equal(rm.get_ground_bottom(), 1080.0, "ground_bottom 应为 1080")
		var bounds: Vector2 = rm.get_camera_bounds()
		_runner.assert_equal(bounds, Vector2(0, 4096), "camera_bounds 应为 (0, 4096)")
	_runner.end_test()

	_runner.begin_test("道路地图: 双向出口触发器")
	if map:
		var triggers: Node2D = map.get_node_or_null(WorldAPI.PATH_MAP_CHUNK_TRIGGERS)
		_runner.assert_true(triggers != null, "ChunkTriggers 应存在")
		if triggers:
			_runner.assert_equal(triggers.get_child_count(), 2, "应有 2 个出口触发器（左右）")
			# 检查 ExitLeft 和 ExitRight
			var has_left: bool = triggers.get_node_or_null("ExitLeft") != null
			var has_right: bool = triggers.get_node_or_null("ExitRight") != null
			_runner.assert_true(has_left, "应有 ExitLeft 触发器")
			_runner.assert_true(has_right, "应有 ExitRight 触发器")
	_runner.end_test()

	_runner.begin_test("道路地图: 玩家已生成（左侧入口）")
	if map:
		var player: Node2D = map.get_possessed_entity()
		_runner.assert_true(player != null, "应有玩家附身实体")
		if player:
			# ENTRY_LEFT: spawn_x = map_left + 150 = 150
			_runner.assert_true(absf(player.global_position.x - 150.0) < 10.0, "玩家应在左侧入口附近 (x≈150)")
	_runner.end_test()

	_runner.begin_test("道路地图: 公共 API 可用")
	if map:
		var rm: ScriptRoadMap = map as ScriptRoadMap
		_runner.assert_true(rm.has_method("spawn_entity"), "应有 spawn_entity 方法")
		_runner.assert_true(rm.has_method("get_entities"), "应有 get_entities 方法")
		_runner.assert_true(rm.has_method("get_walk_barriers"), "应有 get_walk_barriers 方法")
		_runner.assert_equal(rm.get_map_width(), 4096.0, "地图宽度应为 4096")
	_runner.end_test()


# ─────────────────────────────── Phase 3: 村落 B ────────────────────────────────

func _run_phase_3_tests() -> void:
	_runner.begin_test("村落B: 已加载")
	var sl := _get_scene_loader()
	_runner.assert_equal(sl.get_current_map_id(), ScriptGameRoot.VILLAGE_B_MAP_ID, "当前应为 test_village_b")
	_runner.assert_equal(sl.get_current_map_type(), WorldAPI.MapType.VILLAGE, "类型应为 VILLAGE")
	_runner.end_test()

	_runner.begin_test("村落B: VillageMap 实例")
	var map := _get_current_map()
	_runner.assert_true(map != null, "地图应存在")
	if map:
		_runner.assert_true(map is ScriptVillageMap, "地图应为 VillageMap")
	_runner.end_test()

	_runner.begin_test("村落B: 子节点齐全")
	if map:
		_runner.assert_true(map.get_node_or_null(WorldAPI.PATH_MAP_ENTITY_HOST) != null, "EntityHost 应存在")
		_runner.assert_true(map.get_node_or_null(WorldAPI.PATH_MAP_CHUNK_TRIGGERS) != null, "ChunkTriggers 应存在")
		_runner.assert_true(map.get_node_or_null(WorldAPI.PATH_MAP_BUILDING_HOST) != null, "BuildingHost 应存在")
	_runner.end_test()

	_runner.begin_test("村落B: 左出口触发器")
	if map:
		var triggers: Node2D = map.get_node_or_null(WorldAPI.PATH_MAP_CHUNK_TRIGGERS)
		_runner.assert_true(triggers != null, "ChunkTriggers 应存在")
		if triggers:
			_runner.assert_true(triggers.get_child_count() >= 1, "应至少有 1 个触发器")
			var has_left: bool = triggers.get_node_or_null("ExitLeft") != null
			_runner.assert_true(has_left, "应有 ExitLeft 触发器")
	_runner.end_test()

	_runner.begin_test("村落B: 玩家已生成（左侧入口）")
	if map:
		var player: Node2D = map.get_possessed_entity()
		_runner.assert_true(player != null, "应有玩家附身实体")
		if player:
			_runner.assert_true(absf(player.global_position.x - 150.0) < 10.0, "玩家应在左侧入口附近 (x≈150)")
	_runner.end_test()

	_runner.begin_test("完整链路: EventBus 旅行信号累计")
	_runner.assert_true(_event_bus_signals.has("travel_started"), "travel_started 信号应已触发")
	_runner.assert_true(_event_bus_signals.has("map_loaded"), "map_loaded 信号应已触发")
	_runner.assert_true(_event_bus_signals.has("map_unloaded"), "map_unloaded 信号应已触发")
	_runner.end_test()


# ─────────────────────────────── Phase 4: 反向旅行 ────────────────────────────────

func _run_phase_4_tests() -> void:
	_runner.begin_test("反向旅行: 回到村落A")
	var sl := _get_scene_loader()
	_runner.assert_equal(sl.get_current_map_id(), ScriptGameRoot.TEST_VILLAGE_MAP_ID, "当前应回到 test_village")
	_runner.end_test()

	_runner.begin_test("反向旅行: 玩家在右侧入口")
	var map := _get_current_map()
	if map:
		var player: Node2D = map.get_possessed_entity()
		_runner.assert_true(player != null, "应有玩家附身实体")
		if player:
			# ENTRY_RIGHT: spawn_x = map_right - 150 = 8192 - 150 = 8042
			_runner.assert_true(absf(player.global_position.x - 8042.0) < 10.0, "玩家应在右侧入口附近 (x≈8042)")
	_runner.end_test()

	_runner.begin_test("SceneLoader: last_entry_side 记录正确")
	var sl2 := _get_scene_loader()
	_runner.assert_equal(sl2.get_last_entry_side(), WorldAPI.EntrySide.RIGHT, "最后进入方向应为 RIGHT")
	_runner.assert_equal(sl2.get_last_travel_mode(), WorldAPI.TravelMode.WALK, "最后旅行方式应为 WALK")
	_runner.end_test()
