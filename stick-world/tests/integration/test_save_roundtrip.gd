extends Node
## 集成测试：存档/读档 round-trip（真实 SaveManager + SQLite 全链路）。
## 回归背景（2026-08-15 审计）：construction_projects 建表 SQL 缺 material_progress 列，
## 写侧 insert 含该列 → 含未完工项目的存档写入静默失败、项目丢失。
## 覆盖两条路径：
##   1. 全新库：save_game 建表含新列，round-trip 不丢项目；
##   2. 旧库（缺列）：save_game 自动 ALTER 补列后 round-trip 成功。
## 存档走真实链路：SaveManager.save_game → EventBus.game_saving 回调写库 → COMMIT，
## 与 GameRoot 的 save_handler.gd 接线方式一致。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
@warning_ignore("shadowed_global_identifier")
const TestHelpers := preload("res://tests/core/test_helpers.gd")
const ScriptConstructionManager := preload("res://modules/construction/scripts/construction_manager.gd")
const ScriptConstructionProject := preload("res://modules/construction/scripts/construction_project.gd")
const MAP_SCENE: PackedScene = preload("res://modules/world/scenes/maps/village_a.tscn")

const TEST_SLOT := 4
const TEST_MAP_ID := "test_map"
const EXPECTED_MATERIAL := 0.4

## 旧版（缺 material_progress 列）的 construction_projects 建表 SQL —— 历史 bug 的精确复刻
const LEGACY_PROJECTS_SQL := """
	CREATE TABLE IF NOT EXISTS construction_projects (
		slot_id       INTEGER NOT NULL,
		project_id    TEXT    NOT NULL,
		map_id        TEXT    NOT NULL,
		def_id        TEXT    NOT NULL,
		cell_x        INTEGER NOT NULL,
		width         INTEGER NOT NULL DEFAULT 1,
		state         INTEGER NOT NULL DEFAULT 0,
		total_work    REAL    NOT NULL DEFAULT 10.0,
		current_work  REAL    NOT NULL DEFAULT 0.0,
		region_id     TEXT    NOT NULL DEFAULT '',
		PRIMARY KEY (slot_id, project_id),
		FOREIGN KEY (slot_id) REFERENCES save_meta(slot_id) ON DELETE CASCADE
	);
"""

var _runner: TestRunner
var _map: Node2D = null
var _cm: Node = null


func _ready() -> void:
	SaveManager.set_auto_save_enabled(false)
	_runner = TestRunner.new()
	_runner.add_test("存档: 未完工项目 round-trip 不丢失（全新库）", _test_roundtrip_fresh_db, true)
	_runner.add_test("存档: 旧库缺列自动迁移后可写（迁移回归）", _test_roundtrip_legacy_db, true)
	await _runner.run_async()
	print(_runner.summary())
	get_tree().quit(0 if _runner.all_passed() else 1)


## 惰性初始化：加载地图 + 装配 ConstructionManager（同 construction_cycle 的 fixture）
func _ensure_setup() -> void:
	if _map != null:
		return
	_map = MAP_SCENE.instantiate()
	add_child(_map)
	var ok: bool = await TestHelpers.await_condition(
		func(): return _map.get("placement_grid") != null and _map.get("building_host") != null,
		5.0, "村落地图就绪"
	)
	if not ok:
		_runner.assert_true(false, "村落地图未就绪")
		return
	_cm = ScriptConstructionManager.new()
	_cm.name = "TestConstructionManager"
	add_child(_cm)
	_cm.set_map(_map)
	await TestHelpers.await_condition(
		func(): return _cm.is_building_registered("placeholder"),
		3.0, "默认建筑场景注册"
	)


## 创建一个派工中的未完工项目（材料进度 0.4），返回 project_id
func _create_unfinished_project(cell_x: int) -> String:
	var start: Dictionary = _cm.start_construction_at("r1", "placeholder", cell_x)
	_runner.assert_true(start.get("ok", false), "开工应成功: %s" % start.get("error", ""))
	var project_id: String = start.get("project_id", "")
	var projects: Dictionary = _cm.get("_projects")
	var project: RefCounted = projects[project_id]
	_runner.assert_not_null(project, "项目应在注册表中")
	# 直接对目标项目派工（绕过 assigner 的全局路由——路由会把工人分给更早的未完工项目，
	# 那是合法游戏行为，但会破坏本测试的 fixture 确定性）
	_runner.assert_true(project.assign_worker(_make_worker()), "直接派工应成功")
	project.deliver_material(EXPECTED_MATERIAL)
	# fixture 自检：保存前必须处于建造中，否则存档断言无从谈起
	var st: Dictionary = _cm.get_project_state(project_id)
	_runner.assert_equal(st.get("state", -1), ScriptConstructionProject.State.UNDER_CONSTRUCTION,
		"保存前应处于建造中（fixture 自检）")
	return project_id


func _make_worker() -> Node:
	var worker := Node.new()
	worker.name = "TestWorker"
	return worker


## 模拟 GameRoot save_handler 的接线：在 game_saving / game_loaded 回调中写/读建造数据
func _connect_save_bridge() -> void:
	if not EventBus.game_saving.is_connected(_on_game_saving):
		EventBus.game_saving.connect(_on_game_saving)
	if not EventBus.game_loaded.is_connected(_on_game_loaded):
		EventBus.game_loaded.connect(_on_game_loaded)


func _disconnect_save_bridge() -> void:
	if EventBus.game_saving.is_connected(_on_game_saving):
		EventBus.game_saving.disconnect(_on_game_saving)
	if EventBus.game_loaded.is_connected(_on_game_loaded):
		EventBus.game_loaded.disconnect(_on_game_loaded)


func _on_game_saving(slot_index: int) -> void:
	_cm.save_to_db(SaveManager.get_db(), slot_index, TEST_MAP_ID)


func _on_game_loaded(slot_index: int) -> void:
	_cm.load_from_db(SaveManager.get_db(), slot_index, TEST_MAP_ID)
	SaveManager.end_load()


## 存档 → 读档 → 断言未完工项目不丢失、材料进度精确恢复
func _save_and_verify(project_id: String) -> void:
	_runner.assert_true(SaveManager.save_game(TEST_SLOT), "存档应成功")
	_runner.assert_true(SaveManager.load_game(TEST_SLOT), "读档应成功")
	var st: Dictionary = _cm.get_project_state(project_id)
	_runner.assert_true(st.get("ok", false),
		"读档后项目应存在（未完工项目不得丢失）: %s" % st.get("error", ""))
	_runner.assert_equal(st.get("state", -1), ScriptConstructionProject.State.UNDER_CONSTRUCTION,
		"读档后应保持 UNDER_CONSTRUCTION")
	var projects: Dictionary = _cm.get("_projects")
	_runner.assert_true(projects.has(project_id), "项目注册表应包含该项目")
	var p: RefCounted = projects[project_id]
	_runner.assert_approx(float(p.get("material_progress")), EXPECTED_MATERIAL, 0.001,
		"材料进度应精确恢复为 %.1f" % EXPECTED_MATERIAL)


func _test_roundtrip_fresh_db() -> void:
	await _ensure_setup()
	SaveManager.delete_game(TEST_SLOT)
	_connect_save_bridge()
	var project_id: String = _create_unfinished_project(90)
	_save_and_verify(project_id)
	_disconnect_save_bridge()
	SaveManager.delete_game(TEST_SLOT)


func _test_roundtrip_legacy_db() -> void:
	await _ensure_setup()
	SaveManager.delete_game(TEST_SLOT)
	_create_legacy_db()
	_connect_save_bridge()
	var project_id: String = _create_unfinished_project(140)
	_save_and_verify(project_id)
	_disconnect_save_bridge()
	SaveManager.delete_game(TEST_SLOT)


## 手工构造旧版库：construction_projects 无 material_progress 列（其余表由 save_game 建全）
func _create_legacy_db() -> void:
	if not ClassDB.class_exists("SQLite"):
		_runner.assert_true(false, "SQLite 插件未加载，无法构造旧库")
		return
	var db: Object = ClassDB.instantiate("SQLite")
	db.path = "user://saves/save_%d.db" % TEST_SLOT
	if not db.open_db():
		_runner.assert_true(false, "旧库创建失败")
		return
	db.query(LEGACY_PROJECTS_SQL)
	db.close_db()
