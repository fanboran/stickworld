extends Node
## 冒烟测试：跨图旅行链路（原 test_stage_08 迁移）。
##
## 运行：
##   godot --headless --path stick-world res://tests/smoke/test_cross_map_travel.tscn -- --fresh-start
##
## 退出码：0 全部通过，1 有失败
##
## 测试内容：
##   1. SceneLoader 多地图注册 + 出口配置
##   2. 初始主街（hd2d_street）加载
##   3. 旅行到村落 B（EventBus 信号转发）
##   4. HD-2D 村图结构与 API
##   5. 反向旅行回主街
##   6. ChunkTrigger 配置验证
## （2026-09-16 旧 2D 图清退：道路图 road_a_b 删除，跨图链改为主街↔村落B 直达）

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptSceneLoader := preload("res://modules/world/scripts/loading/scene_loader.gd")
const ScriptChunkTrigger := preload("res://modules/world/scripts/loading/chunk_trigger.gd")
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
	add_child(_game_root)
	# 等待初始地图加载（call_deferred + 多帧确保 spawn 完成）
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame

	# 监听 EventBus 旅行信号
	_connect_event_bus_signals()

	# ── Phase 1: 初始状态测试 ──
	_run_phase_1_tests()

	# ── Phase 2: 旅行到村落 B ──
	var sl := _get_scene_loader()
	sl.travel_to_map(ScriptGameRoot.VILLAGE_B_MAP_ID, WorldAPI.TravelMode.WALK, WorldAPI.EntrySide.RIGHT)
	await _await_current_map(ScriptGameRoot.VILLAGE_B_MAP_ID)
	_run_phase_2_tests()

	# ── Phase 3: 反向旅行回主街 ──
	sl.travel_to_map(ScriptGameRoot.HD2D_STREET_MAP_ID, WorldAPI.TravelMode.WALK, WorldAPI.EntrySide.LEFT)
	await _await_current_map(ScriptGameRoot.HD2D_STREET_MAP_ID)
	_run_phase_3_tests()

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
	_runner.begin_test("SceneLoader: 多地图注册")
	var sl := _get_scene_loader()
	_runner.assert_true(sl != null, "SceneLoader 应存在")
	if sl == null:
		_runner.end_test()
		return
	_runner.assert_true(sl.has_map(ScriptGameRoot.VILLAGE_B_MAP_ID), "应注册 village_b")
	_runner.assert_true(sl.has_map(ScriptGameRoot.BATTLEFIELD_MAP_ID), "应注册 battlefield")
	_runner.assert_true(sl.has_map(ScriptGameRoot.RESOURCE_W_MAP_ID), "应注册 hd2d_resource_w")
	_runner.end_test()

	_runner.begin_test("SceneLoader: 出口配置正确")
	# 2026-09-16 旧 2D 图清退：出口 = 战场左出回主街 + 主街东西门直达资源图
	var bf_left: Dictionary = sl.get_map_exit(ScriptGameRoot.BATTLEFIELD_MAP_ID, WorldAPI.EntrySide.LEFT)
	_runner.assert_equal(bf_left.get("target", ""), ScriptGameRoot.HD2D_STREET_MAP_ID, "战场左出应指向主街")
	var street_w: Dictionary = sl.get_map_exit(ScriptGameRoot.HD2D_STREET_MAP_ID, WorldAPI.EntrySide.LEFT)
	_runner.assert_equal(street_w.get("target", ""), ScriptGameRoot.RESOURCE_W_MAP_ID, "主街西出应指向城西资源区")
	var street_e: Dictionary = sl.get_map_exit(ScriptGameRoot.HD2D_STREET_MAP_ID, WorldAPI.EntrySide.RIGHT)
	_runner.assert_equal(street_e.get("target", ""), ScriptGameRoot.RESOURCE_E_MAP_ID, "主街东出应指向城东资源区")
	_runner.end_test()

	_runner.begin_test("初始地图: 主街（hd2d_street）已加载")
	_runner.assert_true(sl.is_map_loaded(), "应已加载地图")
	_runner.assert_equal(sl.get_current_map_id(), ScriptGameRoot.HD2D_STREET_MAP_ID, "当前应为 hd2d_street")
	_runner.assert_equal(sl.get_current_map_type(), WorldAPI.MapType.VILLAGE, "类型应为 VILLAGE")
	_runner.end_test()

	_runner.begin_test("初始地图: 主街子节点齐全")
	var map := _get_current_map()
	_runner.assert_true(map != null, "地图应存在")
	if map:
		_runner.assert_true(map.get_node_or_null(WorldAPI.PATH_MAP_ENTITY_HOST) != null, "EntityHost 应存在")
		_runner.assert_true(map.get_node_or_null(WorldAPI.PATH_MAP_CHUNK_TRIGGERS) != null, "ChunkTriggers 应存在")
	_runner.end_test()

	_runner.begin_test("初始地图: ChunkTrigger 存在（东出口）")
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


# ─────────────────────────────── Phase 2: 村落 B ────────────────────────────────

func _run_phase_2_tests() -> void:
	_runner.begin_test("旅行信号: EventBus 转发正确")
	_runner.assert_true(_event_bus_signals.has("travel_started"), "应收到 EventBus.travel_started")
	_runner.assert_true(_event_bus_signals.has("travel_completed"), "应收到 EventBus.travel_completed")
	_runner.assert_true(_event_bus_signals.has("map_loaded"), "应收到 EventBus.map_loaded")
	_runner.end_test()

	_runner.begin_test("村落B: 已加载")
	var sl := _get_scene_loader()
	_runner.assert_equal(sl.get_current_map_id(), ScriptGameRoot.VILLAGE_B_MAP_ID, "当前应为 village_b")
	_runner.assert_equal(sl.get_current_map_type(), WorldAPI.MapType.VILLAGE, "类型应为 VILLAGE")
	_runner.end_test()

	_runner.begin_test("村落B: HD-2D 村实例")
	var map := _get_current_map()
	_runner.assert_true(map != null, "地图应存在")
	if map:
		_runner.assert_true(map.has_method("get_spawn_point"), "村B 应为 HD-2D 布局村（get_spawn_point）")
	_runner.end_test()

	_runner.begin_test("村落B: 子节点齐全")
	if map:
		_runner.assert_true(map.get_node_or_null(WorldAPI.PATH_MAP_ENTITY_HOST) != null, "EntityHost 应存在")
		_runner.assert_true(map.get_node_or_null(WorldAPI.PATH_MAP_CHUNK_TRIGGERS) != null, "ChunkTriggers 应存在")
		_runner.assert_true(map.get_node_or_null(WorldAPI.PATH_MAP_BUILDING_HOST) != null, "BuildingHost 应存在")
	_runner.end_test()

	_runner.begin_test("村落B: 玩家已生成（出生点附近）")
	if map:
		var player: Node2D = map.get_possessed_entity()
		_runner.assert_true(player != null, "应有玩家附身实体")
		if player and map.has_method("get_spawn_point"):
			var sp: Vector2 = map.get_spawn_point()
			_runner.assert_true(absf(player.global_position.x - sp.x) < 10.0,
					"玩家应在出生点附近 (x≈%d)" % int(sp.x))
	_runner.end_test()

	_runner.begin_test("完整链路: EventBus 旅行信号累计")
	_runner.assert_true(_event_bus_signals.has("travel_started"), "travel_started 信号应已触发")
	_runner.assert_true(_event_bus_signals.has("map_loaded"), "map_loaded 信号应已触发")
	_runner.assert_true(_event_bus_signals.has("map_unloaded"), "map_unloaded 信号应已触发")
	_runner.end_test()


# ─────────────────────────────── Phase 3: 反向旅行 ────────────────────────────────

## 轮询等待 SceneLoader 当前地图实例与 id 一致（旧图 queue_free 延迟释放，
## get_current_map 短暂返回旧图——位置断言必须等新图实体就位再读）
func _await_current_map(map_id: String) -> void:
	var sl := _get_scene_loader()
	for i in 120:
		var map := _get_current_map()
		if map != null and String(map.get("map_id")) == map_id:
			return
		await get_tree().process_frame


func _run_phase_3_tests() -> void:
	_runner.begin_test("反向旅行: 回到主街")
	var sl := _get_scene_loader()
	_runner.assert_equal(sl.get_current_map_id(), ScriptGameRoot.HD2D_STREET_MAP_ID, "当前应回到主街")
	_runner.end_test()

	_runner.begin_test("反向旅行: 玩家在出生点")
	var map := _get_current_map()
	if map:
		var player: Node2D = map.get_possessed_entity()
		_runner.assert_true(player != null, "应有玩家附身实体")
		if player and map.has_method("get_spawn_point"):
			# HD-2D 图按设计用自定义出生点（get_spawn_point 覆盖边缘入口落点）
			var sp: Vector2 = map.get_spawn_point()
			_runner.assert_true(absf(player.global_position.x - sp.x) < 10.0,
					"玩家应在出生点附近 (期望 x≈%d，实得 %d)" % [int(sp.x), int(player.global_position.x)])
	_runner.end_test()

	_runner.begin_test("SceneLoader: last_entry_side 记录正确")
	var sl2 := _get_scene_loader()
	_runner.assert_equal(sl2.get_last_entry_side(), WorldAPI.EntrySide.LEFT, "最后进入方向应为 LEFT")
	_runner.assert_equal(sl2.get_last_travel_mode(), WorldAPI.TravelMode.WALK, "最后旅行方式应为 WALK")
	_runner.end_test()
