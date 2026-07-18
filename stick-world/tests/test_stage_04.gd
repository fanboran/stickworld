extends Node
## 阶段 0.4 定居点建设集成测试入口。
##
## 运行：
##   godot --headless --path stick-world res://tests/test_stage_04.tscn
##
## 退出码：0 全部通过，1 有失败
##
## 测试覆盖：
##   - ConstructionManager / api 装配
##   - map 注入到 manager
##   - NPC 已注册为可派工工人
##   - start_construction 创建项目（PLANNED）
##   - 自动派工：NPC 被分配到项目（PLANNED → UNDER_CONSTRUCTION）
##   - 项目进度推进
##   - 完工后建筑实例化到 BuildingHost
##   - 建筑 PlacementGrid 占用生效

const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptStickmanEntity := preload("res://modules/units/scripts/stickman_entity.gd")
const ScriptVillageMap := preload("res://modules/world/scripts/village_map.gd")
const ScriptConstructionProject := preload("res://modules/construction/scripts/construction_project.gd")
const ScriptConstructionManager := preload("res://modules/construction/scripts/construction_manager.gd")
const ScriptConstructionApi := preload("res://modules/construction/api.gd")
const ScriptBuilding := preload("res://modules/old_buildings/scripts/building.gd")

var _runner: TestRunner
var _game_root: Node
var _tests: Array = []


func _ready() -> void:
	_runner = TestRunner.new()
	_register_tests()
	_run_tests_async()


# ─────────────────────────────── 测试注册 ────────────────────────────────

func _register_tests() -> void:
	# 同步测试（在加载完成后立即运行）
	_tests.append({"name": "GameRoot: ConstructionManager 装配", "fn": Callable(self, "_test_manager_assembled"), "async": false})
	_tests.append({"name": "GameRoot: Construction api 装配", "fn": Callable(self, "_test_api_assembled"), "async": false})
	_tests.append({"name": "ConstructionManager: map 已注入", "fn": Callable(self, "_test_map_injected"), "async": false})
	_tests.append({"name": "ConstructionManager: bld_workshop 已注册", "fn": Callable(self, "_test_workshop_registered"), "async": false})
	_tests.append({"name": "NPC: 已注册为可派工工人", "fn": Callable(self, "_test_npcs_registered"), "async": false})

	# 异步测试
	_tests.append({"name": "集成: start_construction 创建项目", "fn": Callable(self, "_test_start_construction"), "async": true})
	_tests.append({"name": "集成: NPC 自动派工到项目", "fn": Callable(self, "_test_auto_assign"), "async": true})
	_tests.append({"name": "集成: 项目进度推进", "fn": Callable(self, "_test_progress_advances"), "async": true})
	_tests.append({"name": "集成: 完工后建筑实例化", "fn": Callable(self, "_test_building_instantiated"), "async": true})
	_tests.append({"name": "集成: PlacementGrid 占用生效", "fn": Callable(self, "_test_grid_occupied"), "async": true})


# ─────────────────────────────── 异步执行 ────────────────────────────────

func _run_tests_async() -> void:
	# 实例化 GameRoot
	var packed := load("res://modules/world/scenes/game_root.tscn") as PackedScene
	if packed == null:
		print("[FATAL] 无法加载 game_root.tscn")
		get_tree().quit(1)
		return
	_game_root = packed.instantiate()
	# 关闭自动演示建造（测试用例自己触发，避免重复）
	_game_root.set("auto_demo_building", false)
	add_child(_game_root)
	# 等待地图加载和实体生成
	for i in 6:
		await get_tree().process_frame

	# 取消玩家附身
	_unpossess_player()
	for i in 2:
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


func _get_construction_manager() -> Node:
	if _game_root == null:
		return null
	return _game_root.get_node_or_null("ConstructionManager")


func _get_construction_api() -> Node:
	if _game_root == null:
		return null
	return _game_root.get_node_or_null("ConstructionApi")


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


func _get_npc_entities() -> Array:
	var map_node := _get_current_map()
	if map_node == null:
		return []
	var map: ScriptVillageMap = map_node as ScriptVillageMap
	if map == null:
		return []
	var npcs: Array = []
	var first_seen := false
	for e in map.get_entities():
		if e is ScriptStickmanEntity:
			if first_seen:
				npcs.append(e as ScriptStickmanEntity)
			else:
				first_seen = true  # 跳过第一个（玩家）
	return npcs


func _unpossess_player() -> void:
	var e := _get_player_entity()
	if e != null:
		e.set_possessed(false)


# ─────────────────────────────── 同步测试 ────────────────────────────────

func _test_manager_assembled() -> void:
	var mgr := _get_construction_manager()
	_runner.assert_true(mgr != null, "ConstructionManager 应为子节点")
	if mgr != null:
		_runner.assert_true(mgr is ScriptConstructionManager, "ConstructionManager 应为 ConstructionManager 类型")


func _test_api_assembled() -> void:
	var api := _get_construction_api()
	_runner.assert_true(api != null, "ConstructionApi 应为子节点")
	if api != null:
		_runner.assert_true(api.get_script() == ScriptConstructionApi, "ConstructionApi 脚本应匹配")


func _test_map_injected() -> void:
	var mgr := _get_construction_manager()
	if mgr == null:
		_runner.assert_true(false, "ConstructionManager 为空")
		return
	var map: Node2D = mgr.get_map()
	_runner.assert_true(map != null, "map 应已注入到 manager")


func _test_workshop_registered() -> void:
	var mgr := _get_construction_manager()
	if mgr == null:
		_runner.assert_true(false, "ConstructionManager 为空")
		return
	# bld_workshop 应在 _register_default_building_scenes 中注册
	# 通过查询 scene_registry（私有字段）— 用 get 检查
	var has_scene: bool = false
	if "_building_scene_registry" in mgr:
		var registry: Dictionary = mgr.get("_building_scene_registry") as Dictionary
		has_scene = registry.has("bld_workshop")
	_runner.assert_true(has_scene, "bld_workshop 场景应已注册")


func _test_npcs_registered() -> void:
	var mgr := _get_construction_manager()
	if mgr == null:
		_runner.assert_true(false, "ConstructionManager 为空")
		return
	var npcs := _get_npc_entities()
	if npcs.is_empty():
		_runner.assert_true(false, "无 NPC 实体")
		return
	# 检查每个 NPC 是否已注入 ConstructionManager
	for npc in npcs:
		var e: ScriptStickmanEntity = npc as ScriptStickmanEntity
		_runner.assert_true(e.get_construction_manager() == mgr, "NPC 应注入 ConstructionManager")


# ─────────────────────────────── 异步测试 ────────────────────────────────

var _test_project_id: String = ""


func _test_start_construction() -> void:
	var game_root: Node = _game_root
	if game_root == null:
		_runner.assert_true(false, "GameRoot 为空")
		return
	# 通过 start_demo_building_at 触发建造（cell_x=60，远离 NPC spawn）
	var result: Dictionary = game_root.start_demo_building_at(60)
	_runner.assert_true(result.get("ok", false), "start_construction 应成功: %s" % result.get("error", ""))
	if result.get("ok", false):
		_test_project_id = result.get("project_id", "")
		_runner.assert_true(not _test_project_id.is_empty(), "应返回 project_id")
		# 验证项目状态为 PLANNED（暂无派工）
		var mgr := _get_construction_manager()
		var state: Dictionary = mgr.get_project_state(_test_project_id)
		_runner.assert_true(state.get("ok", false), "应能查询项目状态")
		if state.get("ok", false):
			_runner.assert_equal(state.get("state", -1), ScriptConstructionProject.State.PLANNED, "初始状态应为 PLANNED")
	# 等待一帧让 ConstructionManager._physics_process 运行
	await get_tree().process_frame


func _test_auto_assign() -> void:
	if _test_project_id.is_empty():
		_runner.assert_true(false, "项目未创建")
		return
	var mgr := _get_construction_manager()
	if mgr == null:
		_runner.assert_true(false, "ConstructionManager 为空")
		return
	# 触发派工：手动给一个空闲 NPC 调用 try_assign_worker
	var npcs := _get_npc_entities()
	if npcs.is_empty():
		_runner.assert_true(false, "无 NPC 实体")
		return
	var worker: Node = npcs[0] as Node
	# 等待 AIController 自动调用 _try_work，最多 2 秒
	var assigned := false
	for i in 20:
		# 主动触发一次派工（保证测试不依赖 AI 决策时序）
		if not assigned:
			assigned = mgr.try_assign_worker(worker)
		await get_tree().process_frame
		if mgr.get_worker_project(worker) != null:
			assigned = true
			break
	_runner.assert_true(assigned, "NPC 应被派工到项目")
	if assigned:
		var project: ScriptConstructionProject = mgr.get_worker_project(worker)
		_runner.assert_true(project != null, "派工项目应非空")
		if project != null:
			_runner.assert_equal(project.project_id, _test_project_id, "派工到正确项目")
			# 第一个工人派工后应自动从 PLANNED 切到 UNDER_CONSTRUCTION
			_runner.assert_equal(project.state, ScriptConstructionProject.State.UNDER_CONSTRUCTION, "应切到 UNDER_CONSTRUCTION")


func _test_progress_advances() -> void:
	if _test_project_id.is_empty():
		_runner.assert_true(false, "项目未创建")
		return
	var mgr := _get_construction_manager()
	if mgr == null:
		_runner.assert_true(false, "ConstructionManager 为空")
		return
	# 等待 1.5 秒，进度应推进（一个工人贡献 1.0/秒，应累计 ~1.5 工作）
	var state_before: Dictionary = mgr.get_project_state(_test_project_id)
	var progress_before: float = float(state_before.get("progress", 0.0))
	# 让游戏跑 1 秒
	for i in 60:
		await get_tree().process_frame
	var state_after: Dictionary = mgr.get_project_state(_test_project_id)
	var progress_after: float = float(state_after.get("progress", 0.0))
	_runner.assert_true(progress_after > progress_before or progress_after >= 1.0, "进度应推进: before=%f after=%f" % [progress_before, progress_after])


func _test_building_instantiated() -> void:
	if _test_project_id.is_empty():
		_runner.assert_true(false, "项目未创建")
		return
	var mgr := _get_construction_manager()
	if mgr == null:
		_runner.assert_true(false, "ConstructionManager 为空")
		return
	# total_work=10.0，一个工人 1.0/秒，最多等 15 秒（含移动时间）
	var project: ScriptConstructionProject = null
	var building: Node = null
	for i in 900:  # 最多等 15 秒（60帧 × 15秒）
		await get_tree().process_frame
		var state: Dictionary = mgr.get_project_state(_test_project_id)
		if state.get("ok", false):
			if state.get("state", -1) == ScriptConstructionProject.State.OPERATIONAL:
				# 项目完工
				break
	# 取项目对象
	if "_projects" in mgr:
		var projects: Dictionary = mgr.get("_projects") as Dictionary
		if projects.has(_test_project_id):
			project = projects[_test_project_id] as ScriptConstructionProject
			building = project.building
	_runner.assert_true(building != null, "完工后建筑应已实例化")
	if building != null:
		_runner.assert_true(building is ScriptBuilding, "建筑应为 Building 类型")
		_runner.assert_true((building as ScriptBuilding).is_operational(), "建筑应为 OPERATIONAL 状态")
		# 应挂到 BuildingHost
		var map := _get_current_map()
		if map != null:
			var host: Node2D = map.get_node_or_null("BuildingHost")
			_runner.assert_true(host != null, "BuildingHost 应存在")
			if host != null:
				_runner.assert_true(building.get_parent() == host, "建筑应挂到 BuildingHost")


func _test_grid_occupied() -> void:
	if _test_project_id.is_empty():
		_runner.assert_true(false, "项目未创建")
		return
	var mgr := _get_construction_manager()
	if mgr == null:
		_runner.assert_true(false, "ConstructionManager 为空")
		return
	# 取项目对象
	var project: ScriptConstructionProject = null
	if "_projects" in mgr:
		var projects: Dictionary = mgr.get("_projects") as Dictionary
		if projects.has(_test_project_id):
			project = projects[_test_project_id] as ScriptConstructionProject
	if project == null:
		_runner.assert_true(false, "项目不存在")
		return
	var cell_x: int = project.cell_x
	var width: int = project.width
	# 查询 PlacementGrid，验证 cell_x ~ cell_x+width-1 被占用
	var map := _get_current_map()
	if map == null:
		_runner.assert_true(false, "map 为空")
		return
	var grid: Node = map.get_node_or_null("PlacementGrid")
	if grid == null:
		_runner.assert_true(false, "PlacementGrid 为空")
		return
	# PlacementGrid.has_cell_occupant / is_cell_occupied
	for cx in range(cell_x, cell_x + width):
		var occupied: bool = false
		if grid.has_method("is_occupied"):
			occupied = grid.is_occupied(cx)
		elif grid.has_method("get_cell"):
			var cell: Variant = grid.get_cell(cx)
			if cell != null and "occupied" in cell:
				occupied = bool(cell.occupied)
		_runner.assert_true(occupied, "条带 %d 应被占用" % cx)
