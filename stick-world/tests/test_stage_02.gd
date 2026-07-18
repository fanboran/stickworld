extends Node
## 阶段 0.2 单张村落地图测试入口。
##
## 运行：
##   godot --headless --path stick-world res://tests/test_stage_02.tscn
##
## 退出码：0 全部通过，1 有失败

const TestRunner := preload("res://tests/core/test_runner.gd")
# WorldAPI / PlayerControlAPI 是全局 class_name，无需 preload
# 显式 preload 各实现脚本，用于类型 cast
const ScriptPlacementGrid := preload("res://modules/world/placement_grid/placement_grid.gd")
const ScriptPlacementValidator := preload("res://modules/world/placement_grid/placement_validator.gd")
const ScriptVillageMap := preload("res://modules/world/scripts/village_map.gd")
const ScriptSceneLoader := preload("res://modules/world/scripts/scene_loader.gd")
const ScriptGameRoot := preload("res://modules/world/scripts/game_root.gd")
const ScriptInputDispatcher := preload("res://modules/player_control/scripts/input_dispatcher.gd")
const ScriptCameraRig := preload("res://modules/world/scripts/camera_rig.gd")
const ScriptStickmanEntity := preload("res://modules/units/scripts/stickman_entity.gd")

var _runner: TestRunner
var _game_root: Node
var _tests: Array = []


func _ready() -> void:
	_runner = TestRunner.new()
	_register_tests()
	_run_tests_async()


# ─────────────────────────────── 测试注册 ────────────────────────────────

func _register_tests() -> void:
	_tests.append({"name": "PlacementGrid: 初始化格子数", "fn": Callable(self, "_test_grid_init")})
	_tests.append({"name": "PlacementGrid: 占用与释放", "fn": Callable(self, "_test_grid_occupy_release")})
	_tests.append({"name": "PlacementGrid: 冲突检测", "fn": Callable(self, "_test_grid_conflict")})
	_tests.append({"name": "PlacementGrid: 边界检查", "fn": Callable(self, "_test_grid_bounds")})
	_tests.append({"name": "PlacementGrid: 坐标转换", "fn": Callable(self, "_test_grid_coords")})
	_tests.append({"name": "PlacementGrid: BuildMask 标记与查询", "fn": Callable(self, "_test_grid_build_mask")})
	_tests.append({"name": "PlacementGrid: BuildMask 影响占用查询", "fn": Callable(self, "_test_grid_build_mask_occupied")})
	_tests.append({"name": "PlacementGrid: BuildMask 区域标记", "fn": Callable(self, "_test_grid_build_mask_area")})
	_tests.append({"name": "PlacementValidator: 校验通过", "fn": Callable(self, "_test_validator_pass")})
	_tests.append({"name": "PlacementValidator: 越界失败", "fn": Callable(self, "_test_validator_oob")})
	_tests.append({"name": "PlacementValidator: 冲突失败", "fn": Callable(self, "_test_validator_conflict")})
	_tests.append({"name": "GameRoot: 加载测试村落", "fn": Callable(self, "_test_gameroot_load_village")})
	_tests.append({"name": "VillageMap: 子节点齐全", "fn": Callable(self, "_test_village_children")})
	_tests.append({"name": "VillageMap: 地面字段配置", "fn": Callable(self, "_test_village_ground_fields")})
	_tests.append({"name": "VillageMap: spawn_entity", "fn": Callable(self, "_test_village_spawn")})
	_tests.append({"name": "GameRoot: 玩家 StickmanEntity 已生成", "fn": Callable(self, "_test_player_spawned")})
	_tests.append({"name": "StickmanEntity: ground_y 脚部锁定", "fn": Callable(self, "_test_player_ground_lock")})
	_tests.append({"name": "GameRoot: CameraRig 已配置", "fn": Callable(self, "_test_camera_config")})
	_tests.append({"name": "GameRoot: CameraRig 跟随玩家", "fn": Callable(self, "_test_camera_follows_player")})
	_tests.append({"name": "InputDispatcher: EXPLORE handler 已注册", "fn": Callable(self, "_test_explore_handler_registered")})
	_tests.append({"name": "StickmanEntity: 实例化与 API", "fn": Callable(self, "_test_stickman_entity_api")})
	_tests.append({"name": "VillageMap: 新增子节点齐全", "fn": Callable(self, "_test_village_new_children")})
	_tests.append({"name": "VillageMap: ground_bottom getter", "fn": Callable(self, "_test_village_ground_bottom")})
	_tests.append({"name": "VillageMap: WalkBarrier 查询接口", "fn": Callable(self, "_test_village_walk_barrier_query")})
	_tests.append({"name": "StickmanEntity: map_reference 已注入", "fn": Callable(self, "_test_stickman_map_ref")})
	_tests.append({"name": "DebugApi: 绘制器注册与注销", "fn": Callable(self, "_test_debug_api_drawers")})
	_tests.append({"name": "DebugApi: 可见性切换", "fn": Callable(self, "_test_debug_api_visibility")})
	_tests.append({"name": "DebugOverlay: GameRoot 子节点", "fn": Callable(self, "_test_debug_overlay_exists")})
	_tests.append({"name": "DebugOverlay: 绘制器已注册", "fn": Callable(self, "_test_debug_drawers_registered")})


# ─────────────────────────────── 异步执行 ────────────────────────────────

func _run_tests_async() -> void:
	# 先实例化 GameRoot
	var packed := load("res://modules/world/scripts/game_root.tscn") as PackedScene
	if packed == null:
		print("[FATAL] 无法加载 game_root.tscn")
		get_tree().quit(1)
		return
	_game_root = packed.instantiate()
	add_child(_game_root)
	# 等待 map_loaded 信号触发（call_deferred + 一帧）
	await get_tree().process_frame
	await get_tree().process_frame
	# 再等待一帧确保 spawn 完成
	await get_tree().process_frame

	# 顺序执行所有测试
	for t in _tests:
		_runner.add_test(t["name"], t["fn"])
	_runner.run()
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


# ─────────────────────────────── PlacementGrid 单元测试 ────────────────────────────────

func _make_grid() -> ScriptPlacementGrid:
	var g: ScriptPlacementGrid = ScriptPlacementGrid.new()
	g.grid_width = 8
	add_child(g)
	g._ready()
	return g


func _test_grid_init() -> void:
	var g := _make_grid()
	if g == null:
		_runner.assert_true(false, "grid 创建失败")
		return
	_runner.assert_equal(g.get_total_count(), 8, "8 条带")
	_runner.assert_equal(g.get_occupied_count(), 0, "初始应无占用")
	g.queue_free()


func _test_grid_occupy_release() -> void:
	var g := _make_grid()
	if g == null:
		_runner.assert_true(false, "grid 创建失败")
		return
	# 占用 2 条带宽
	var ok: bool = g.occupy(1, 2, "building_a")
	_runner.assert_true(ok, "占用 2 条带应成功")
	_runner.assert_true(g.is_occupied(1), "(1) 应占用")
	_runner.assert_true(g.is_occupied(2), "(2) 应占用")
	_runner.assert_true(not g.is_occupied(0), "(0) 应空闲")
	_runner.assert_equal(g.get_occupied_count(), 2, "应占用 2 条带")
	# 释放
	g.release("building_a")
	_runner.assert_true(not g.is_occupied(1), "释放后 (1) 应空闲")
	_runner.assert_equal(g.get_occupied_count(), 0, "释放后应无占用")
	g.queue_free()


func _test_grid_conflict() -> void:
	var g := _make_grid()
	if g == null:
		_runner.assert_true(false, "grid 创建失败")
		return
	g.occupy(0, 2, "a")
	# 重叠占用应失败
	var ok: bool = g.occupy(1, 2, "b")
	_runner.assert_true(not ok, "重叠占用应失败")
	# 不重叠应成功
	ok = g.occupy(3, 2, "c")
	_runner.assert_true(ok, "不重叠占用应成功")
	g.queue_free()


func _test_grid_bounds() -> void:
	var g := _make_grid()
	if g == null:
		_runner.assert_true(false, "grid 创建失败")
		return
	_runner.assert_true(g.is_in_bounds(0), "(0) 应在边界内")
	_runner.assert_true(g.is_in_bounds(7), "(7) 应在边界内")
	_runner.assert_true(not g.is_in_bounds(8), "(8) 应越界")
	_runner.assert_true(not g.is_in_bounds(-1), "(-1) 应越界")
	# 越界占用应失败
	var oob_ok: bool = g.occupy(7, 2, "x")
	_runner.assert_true(not oob_ok, "越界占用应失败")
	# 越界 is_occupied 返回 true
	_runner.assert_true(g.is_occupied(100), "越界 is_occupied 应返回 true")
	g.queue_free()


func _test_grid_coords() -> void:
	var g := _make_grid()
	if g == null:
		_runner.assert_true(false, "grid 创建失败")
		return
	# 条带 0 中心 = 16.0
	var w: float = g.cell_to_world(0)
	_runner.assert_equal(w, 16.0, "条带 0 中心应为 16.0")
	# world_to_cell
	var c: int = g.world_to_cell(Vector2(16, 16))
	_runner.assert_equal(c, 0, "(16,16) 应映射到 0")
	c = g.world_to_cell(Vector2(33, 33))
	_runner.assert_equal(c, 1, "(33,33) 应映射到 1")
	g.queue_free()


# ─────────────────────────────── PlacementValidator 测试 ────────────────────────────────

func _test_validator_pass() -> void:
	var g := _make_grid()
	if g == null:
		_runner.assert_true(false, "grid 创建失败")
		return
	var v := ScriptPlacementValidator.new()
	var r = ScriptPlacementSystem.validate(g, 0, 2)
	_runner.assert_true(r.ok, "空闲区域应校验通过")
	g.queue_free()


func _test_validator_oob() -> void:
	var g := _make_grid()
	if g == null:
		_runner.assert_true(false, "grid 创建失败")
		return
	var v := ScriptPlacementValidator.new()
	var r = v.validate_placement(g, 7, 2)
	_runner.assert_true(not r.ok, "越界应校验失败")
	_runner.assert_true(r.reason.length() > 0, "失败应有原因")
	g.queue_free()


func _test_validator_conflict() -> void:
	var g := _make_grid()
	if g == null:
		_runner.assert_true(false, "grid 创建失败")
		return
	g.occupy(0, 2, "a")
	var v := ScriptPlacementValidator.new()
	var r = v.validate_placement(g, 1, 2)
	_runner.assert_true(not r.ok, "冲突应校验失败")
	g.queue_free()


# ─────────────────────────────── GameRoot + VillageMap 集成测试 ────────────────────────────────

func _test_gameroot_load_village() -> void:
	var sl := _get_scene_loader()
	if sl == null:
		_runner.assert_true(false, "SceneLoader 不存在")
		return
	_runner.assert_true(sl.is_map_loaded(), "应已加载地图")
	_runner.assert_equal(sl.get_current_map_id(), ScriptGameRoot.TEST_VILLAGE_MAP_ID, "地图 id 应为 test_village")


func _test_village_children() -> void:
	var map := _get_current_map()
	if map == null:
		_runner.assert_true(false, "地图未加载")
		return
	_runner.assert_true(map.get_node_or_null(WorldAPI.PATH_MAP_PLACEMENT_GRID) != null, "PlacementGrid 应存在")
	_runner.assert_true(map.get_node_or_null(WorldAPI.PATH_MAP_TERRAIN_LAYER) != null, "TerrainLayer 应存在")
	_runner.assert_true(map.get_node_or_null(WorldAPI.PATH_MAP_BUILDING_HOST) != null, "BuildingHost 应存在")
	_runner.assert_true(map.get_node_or_null(WorldAPI.PATH_MAP_ENTITY_HOST) != null, "EntityHost 应存在")
	_runner.assert_true(map.get_node_or_null(WorldAPI.PATH_MAP_BATTLE_ANCHOR) != null, "BattleAnchor 应存在")
	_runner.assert_true(map.get_node_or_null("GroundLine") != null, "GroundLine 应存在")


func _test_village_ground_fields() -> void:
	var map_node := _get_current_map()
	if map_node == null:
		_runner.assert_true(false, "地图未加载")
		return
	var map: ScriptVillageMap = map_node as ScriptVillageMap
	if map == null:
		_runner.assert_true(false, "地图非 VillageMap")
		return
	_runner.assert_equal(map.ground_y, 450.0, "ground_y 应为 450")
	_runner.assert_equal(map.ground_ratio, 0.4, "ground_ratio 应为 0.4")
	_runner.assert_equal(map.map_left, 0.0, "map_left 应为 0")
	_runner.assert_equal(map.map_right, 8192.0, "map_right 应为 8192")
	_runner.assert_equal(map.ground_bottom, 882.0, "ground_bottom 应为 882")
	_runner.assert_equal(map.get_ground_y(), 450.0, "get_ground_y 应为 450")
	var bounds: Vector2 = map.get_camera_bounds()
	_runner.assert_equal(bounds, Vector2(0, 8192), "camera_bounds 应为 (0, 8192)")


func _test_village_spawn() -> void:
	var map_node := _get_current_map()
	if map_node == null:
		_runner.assert_true(false, "地图未加载")
		return
	var map: ScriptVillageMap = map_node as ScriptVillageMap
	if map == null:
		_runner.assert_true(false, "地图非 VillageMap")
		return
	# 已经应有玩家实体（GameRoot spawn 的）
	var entities: Array = map.get_entities()
	_runner.assert_true(entities.size() >= 1, "应至少有 1 个实体")


func _test_player_spawned() -> void:
	var map_node := _get_current_map()
	if map_node == null:
		_runner.assert_true(false, "地图未加载")
		return
	var map: ScriptVillageMap = map_node as ScriptVillageMap
	if map == null:
		_runner.assert_true(false, "地图非 VillageMap")
		return
	var player: Node2D = map.get_possessed_entity()
	_runner.assert_true(player != null, "应有玩家附身实体")
	if player == null:
		return
	_runner.assert_true(player is CharacterBody2D, "玩家应为 CharacterBody2D")
	# 位置应接近生成点
	var pos: Vector2 = player.global_position
	_runner.assert_true(absf(pos.x - 300.0) < 5.0, "玩家 x 应接近 300")
	# Y 应在地面偏中心位置 (450 + (882-450)*0.5 = 666)
	var expected_spawn_y: float = 450.0 + (882.0 - 450.0) * 0.5
	_runner.assert_true(absf(pos.y - expected_spawn_y) < 5.0, "玩家 y 应在地面偏中心 = %f" % expected_spawn_y)


func _test_camera_follows_player() -> void:
	var cam: ScriptCameraRig = _get_game_root_child(WorldAPI.PATH_CAMERA_RIG) as ScriptCameraRig
	if cam == null:
		_runner.assert_true(false, "CameraRig 不存在")
		return
	_runner.assert_true(cam.follow_target != null, "CameraRig 应有跟随目标")
	if cam.follow_target != null:
		_runner.assert_true(cam.follow_target is CharacterBody2D, "跟随目标应为 CharacterBody2D")


func _test_player_ground_lock() -> void:
	var map_node := _get_current_map()
	if map_node == null:
		_runner.assert_true(false, "地图未加载")
		return
	var map: ScriptVillageMap = map_node as ScriptVillageMap
	if map == null:
		_runner.assert_true(false, "地图非 VillageMap")
		return
	var player: Node2D = map.get_possessed_entity()
	if player == null:
		_runner.assert_true(false, "无玩家实体")
		return
	var e: ScriptStickmanEntity = player as ScriptStickmanEntity
	if e == null:
		_runner.assert_true(false, "玩家非 StickmanEntity")
		return
	# ground_y / ground_bottom 应被注入
	_runner.assert_equal(e.ground_y, 450.0, "玩家 ground_y 应为 450")
	_runner.assert_equal(e.ground_bottom, 882.0, "玩家 ground_bottom 应为 882")
	_runner.assert_equal(e.map_left, 0.0, "玩家 map_left 应为 0")
	_runner.assert_equal(e.map_right, 8192.0, "玩家 map_right 应为 8192")
	# Y 应在 [ground_y - foot_offset, ground_bottom - foot_offset] 范围内
	var y_min: float = e.ground_y - e.foot_offset
	var y_max: float = e.ground_bottom - e.foot_offset
	_runner.assert_true(e.global_position.y >= y_min - 1.0, "玩家 y 不应低于 ground_y - foot_offset")
	_runner.assert_true(e.global_position.y <= y_max + 1.0, "玩家 y 不应高于 ground_bottom - foot_offset")


func _test_camera_config() -> void:
	var cam: ScriptCameraRig = _get_game_root_child(WorldAPI.PATH_CAMERA_RIG) as ScriptCameraRig
	if cam == null:
		_runner.assert_true(false, "CameraRig 不存在")
		return
	_runner.assert_equal(cam.ground_y, 450.0, "相机 ground_y 应为 450")
	_runner.assert_equal(cam.ground_ratio, 0.4, "相机 ground_ratio 应为 0.4")
	_runner.assert_equal(cam.map_left, 0.0, "相机 map_left 应为 0")
	_runner.assert_equal(cam.map_right, 8192.0, "相机 map_right 应为 8192")
	_runner.assert_true(cam._configured, "相机应已配置")
	# 缩放系统：base_zoom（分辨率适配）+ user_zoom（1.0~2.0）= effective_zoom
	_runner.assert_true(cam.user_zoom >= ScriptCameraRig.ZOOM_MIN, "user_zoom 不应低于 ZOOM_MIN")
	_runner.assert_true(cam.user_zoom <= ScriptCameraRig.ZOOM_MAX, "user_zoom 不应高于 ZOOM_MAX")
	_runner.assert_true(cam.effective_zoom >= cam.base_zoom * ScriptCameraRig.ZOOM_MIN - 0.001, "effective_zoom 应 >= base_zoom * ZOOM_MIN")
	# 测试 user_zoom setter 自动 clamp
	cam.user_zoom = 10.0
	_runner.assert_true(cam.user_zoom <= ScriptCameraRig.ZOOM_MAX, "user_zoom 10.0 应被 clamp 到 2.0")
	cam.user_zoom = 0.1
	_runner.assert_true(cam.user_zoom >= ScriptCameraRig.ZOOM_MIN, "user_zoom 0.1 应被 clamp 到 1.0")
	cam.user_zoom = 1.0
	# base_zoom 应 = viewport_height / DESIGN_HEIGHT
	var vp_h: float = cam.get_viewport_rect().size.y
	var expected_base: float = vp_h / ScriptCameraRig.DESIGN_HEIGHT
	_runner.assert_true(absf(cam.base_zoom - expected_base) < 0.01, "base_zoom 应 = vp_h / DESIGN_HEIGHT")


func _test_explore_handler_registered() -> void:
	var d: ScriptInputDispatcher = _get_game_root_child(WorldAPI.PATH_INPUT_DISPATCHER) as ScriptInputDispatcher
	if d == null:
		_runner.assert_true(false, "InputDispatcher 不存在")
		return
	var handler: Node = d.get_handler(PlayerControlAPI.Mode.EXPLORE)
	_runner.assert_true(handler != null, "EXPLORE handler 应已注册")
	_runner.assert_equal(d.get_mode(), PlayerControlAPI.Mode.EXPLORE, "当前应为 EXPLORE 模式")


func _test_stickman_entity_api() -> void:
	var map_node := _get_current_map()
	if map_node == null:
		_runner.assert_true(false, "地图未加载")
		return
	var map: ScriptVillageMap = map_node as ScriptVillageMap
	if map == null:
		_runner.assert_true(false, "地图非 VillageMap")
		return
	var player: Node2D = map.get_possessed_entity()
	if player == null:
		_runner.assert_true(false, "无玩家实体")
		return
	var e: ScriptStickmanEntity = player as ScriptStickmanEntity
	if e == null:
		_runner.assert_true(false, "玩家非 StickmanEntity")
		return
	_runner.assert_true(e.is_possessed(), "玩家应已被附身")
	_runner.assert_true(e.has_method("set_possessed"), "应有 set_possessed 方法")
	_runner.assert_true(e.has_method("get_facing"), "应有 get_facing 方法")
	_runner.assert_true(e.rig != null, "rig 引用应非空")


# ─────────────────────────────── BuildMask 测试 ────────────────────────────────

func _test_grid_build_mask() -> void:
	var g := _make_grid()
	if g == null:
		_runner.assert_true(false, "grid 创建失败")
		return
	# 初始无 blockage
	_runner.assert_true(not g.is_blocked(0), "(0) 初始应未 blocked")
	_runner.assert_equal(g.get_blocked_count(), 0, "初始 blocked 数应为 0")
	# 标记单格
	g.set_blocked(1)
	_runner.assert_true(g.is_blocked(1), "(1) 标记后应 blocked")
	_runner.assert_true(not g.is_blocked(0), "(0) 应仍未 blocked")
	_runner.assert_equal(g.get_blocked_count(), 1, "blocked 数应为 1")
	# 取消标记
	g.set_blocked(1, false)
	_runner.assert_true(not g.is_blocked(1), "(1) 取消后应未 blocked")
	_runner.assert_equal(g.get_blocked_count(), 0, "取消后 blocked 数应为 0")
	g.queue_free()


func _test_grid_build_mask_occupied() -> void:
	var g := _make_grid()
	if g == null:
		_runner.assert_true(false, "grid 创建失败")
		return
	# BuildMask 标记的格应视为 occupied
	g.set_blocked(2)
	_runner.assert_true(g.is_occupied(2), "blocked 格应视为 occupied")
	# can_place 应返回 false
	_runner.assert_true(not g.can_place(2, 1), "blocked 格 can_place 应失败")
	# occupy 应失败（因 is_occupied 返回 true -> can_place false）
	var ok: bool = g.occupy(2, 1, "test")
	_runner.assert_true(not ok, "blocked 格 occupy 应失败")
	# 未标记的格应正常
	_runner.assert_true(not g.is_occupied(3), "(3) 应未 occupied")
	_runner.assert_true(g.can_place(3, 1), "(3) can_place 应成功")
	g.queue_free()


func _test_grid_build_mask_area() -> void:
	var g := _make_grid()
	if g == null:
		_runner.assert_true(false, "grid 创建失败")
		return
	# 标记 2 条带
	g.set_blocked_area(0, 2)
	_runner.assert_true(g.is_blocked(0), "(0) 应 blocked")
	_runner.assert_true(g.is_blocked(1), "(1) 应 blocked")
	_runner.assert_true(not g.is_blocked(2), "(2) 应未 blocked")
	_runner.assert_equal(g.get_blocked_count(), 2, "2 条带应有 2 blocked")
	# clear_blockage
	g.clear_blockage()
	_runner.assert_equal(g.get_blocked_count(), 0, "clear 后应无 blocked")
	g.queue_free()


# ─────────────────────────────── 新增节点与接口测试 ────────────────────────────────

func _test_village_new_children() -> void:
	var map := _get_current_map()
	if map == null:
		_runner.assert_true(false, "地图未加载")
		return
	_runner.assert_true(map.get_node_or_null(WorldAPI.PATH_MAP_TERRAIN_BUILDINGS) != null, "TerrainBuildings 应存在")
	_runner.assert_true(map.get_node_or_null(WorldAPI.PATH_MAP_INITIAL_BUILDINGS_LIST) != null, "InitialBuildingsList 应存在")
	_runner.assert_true(map.get_node_or_null(WorldAPI.PATH_MAP_WALK_BARRIER) != null, "WalkBarrier 应存在")
	_runner.assert_true(map.get_node_or_null(WorldAPI.PATH_MAP_BUILD_MASK_LAYER) != null, "BuildMaskLayer 应存在")
	_runner.assert_true(map.get_node_or_null(WorldAPI.PATH_MAP_FOREGROUND_LAYER) != null, "ForegroundLayer 应存在")
	# ForegroundLayer z_index 应为 10
	var fg: Node2D = map.get_node_or_null(WorldAPI.PATH_MAP_FOREGROUND_LAYER) as Node2D
	if fg != null:
		_runner.assert_equal(fg.z_index, 10, "ForegroundLayer z_index 应为 10")


func _test_village_ground_bottom() -> void:
	var map_node := _get_current_map()
	if map_node == null:
		_runner.assert_true(false, "地图未加载")
		return
	var map: ScriptVillageMap = map_node as ScriptVillageMap
	if map == null:
		_runner.assert_true(false, "地图非 VillageMap")
		return
	_runner.assert_equal(map.get_ground_bottom(), 882.0, "get_ground_bottom 应为 882")


func _test_village_walk_barrier_query() -> void:
	var map_node := _get_current_map()
	if map_node == null:
		_runner.assert_true(false, "地图未加载")
		return
	var map: ScriptVillageMap = map_node as ScriptVillageMap
	if map == null:
		_runner.assert_true(false, "地图非 VillageMap")
		return
	# get_walk_barriers 应返回 Array（即使为空）
	var barriers: Array = map.get_walk_barriers()
	_runner.assert_true(barriers != null, "get_walk_barriers 应返回数组")
	# get_passage_barriers 应返回 Array
	var pbarriers: Array = map.get_passage_barriers()
	_runner.assert_true(pbarriers != null, "get_passage_barriers 应返回数组")


func _test_stickman_map_ref() -> void:
	var map_node := _get_current_map()
	if map_node == null:
		_runner.assert_true(false, "地图未加载")
		return
	var map: ScriptVillageMap = map_node as ScriptVillageMap
	if map == null:
		_runner.assert_true(false, "地图非 VillageMap")
		return
	var player: Node2D = map.get_possessed_entity()
	if player == null:
		_runner.assert_true(false, "无玩家实体")
		return
	var e: ScriptStickmanEntity = player as ScriptStickmanEntity
	if e == null:
		_runner.assert_true(false, "玩家非 StickmanEntity")
		return
	_runner.assert_true(e.has_method("set_map_reference"), "应有 set_map_reference 方法")
	_runner.assert_true(e.has_method("_is_in_passage_barrier"), "应有 _is_in_passage_barrier 方法")
	# _is_in_passage_barrier 应返回 false（无障碍物）
	_runner.assert_true(not e._is_in_passage_barrier(), "无障碍物时应返回 false")


# ─────────────────────────────── DebugApi / DebugOverlay 测试 ────────────────────────────────

func _test_debug_api_drawers() -> void:
	if DebugApi == null:
		_runner.assert_true(false, "DebugApi autoload 不存在")
		return
	# 注册一个测试绘制器
	var test_called: Array = []
	var test_drawer: Callable = func(_control: Control, _ctx: Dictionary) -> void:
		test_called.append(1)
	DebugApi.register_drawer("test_drawer", test_drawer)
	_runner.assert_true(DebugApi.get_drawers().has("test_drawer"), "注册后应存在")
	# 注销
	DebugApi.unregister_drawer("test_drawer")
	_runner.assert_true(not DebugApi.get_drawers().has("test_drawer"), "注销后应不存在")


func _test_debug_api_visibility() -> void:
	if DebugApi == null:
		_runner.assert_true(false, "DebugApi autoload 不存在")
		return
	var old_visible: bool = DebugApi.is_visible()
	# 切换
	DebugApi.toggle_visibility()
	_runner.assert_true(DebugApi.is_visible() != old_visible, "toggle 后应变化")
	# 切换回
	DebugApi.toggle_visibility()
	_runner.assert_true(DebugApi.is_visible() == old_visible, "再 toggle 应回原值")
	# 图例
	DebugApi.hide_legend()
	_runner.assert_true(not DebugApi.is_legend_visible(), "hide_legend 后应不可见")
	DebugApi.show_legend()
	_runner.assert_true(DebugApi.is_legend_visible(), "show_legend 后应可见")


func _test_debug_overlay_exists() -> void:
	if _game_root == null:
		_runner.assert_true(false, "GameRoot 不存在")
		return
	var overlay: Node = _game_root.get_node_or_null("DebugOverlay")
	_runner.assert_true(overlay != null, "DebugOverlay 应为 GameRoot 子节点")
	if overlay != null:
		_runner.assert_true(overlay is CanvasLayer, "DebugOverlay 应为 CanvasLayer")


func _test_debug_drawers_registered() -> void:
	if DebugApi == null:
		_runner.assert_true(false, "DebugApi autoload 不存在")
		return
	# 地图加载后应已注册 6 个绘制器
	var drawers: Dictionary = DebugApi.get_drawers()
	_runner.assert_true(drawers.has("grid_drawer"), "grid_drawer 应已注册")
	_runner.assert_true(drawers.has("barrier_drawer"), "barrier_drawer 应已注册")
	_runner.assert_true(drawers.has("building_drawer"), "building_drawer 应已注册")
	_runner.assert_true(drawers.has("ground_line_drawer"), "ground_line_drawer 应已注册")
	_runner.assert_true(drawers.has("chunk_trigger_drawer"), "chunk_trigger_drawer 应已注册")
	_runner.assert_true(drawers.has("entity_state_drawer"), "entity_state_drawer 应已注册")
