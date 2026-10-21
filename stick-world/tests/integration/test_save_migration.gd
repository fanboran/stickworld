extends Node
## 集成测试：存档 schema 迁移链 + fixture 库回归（真实 SaveManager，存储层专项——无 GameRoot boot）。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_save_migration.tscn -- --fresh-start
##
## 退出码：0 全部通过，1 有失败
##
## 覆盖：
##   1. v0 旧档：迁移链（v0→v1 规范化 → v1→v2 对齐）升到当前版 + material_progress 补列 + 数据幸存
##   2. v1 档：对齐步升到当前版
##   3. fixture 库：tests/fixtures/saves/ 全量加载不崩、版本到当前版、字段齐全
##      （新 fixture 随入库自动进本回归——纪律见存储架构设计.md §版本迁移链）
##   4. 高版本档：门禁拒绝读档（防降级写坏），拒读后文件原样

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
## 复用 save_manager 的建表 SQL 常量造样例库（单一真相源，防双份 schema 漂移）
const SaveManagerScript := preload("res://core/autoload/save_manager.gd")

## 测试存档槽（与 test_save_completeness 的槽 4 错开，防并行池同槽互踩；用后即删）
const SLOT := 3

var _runner: TestRunner


func _ready() -> void:
	SaveManager.set_auto_save_enabled(false)
	_runner = TestRunner.new()
	_runner.add_test("v0 旧档: 链式迁移升当前版 + 补列 + 数据幸存", _test_v0_migration, true)
	_runner.add_test("v1 档: 对齐步升当前版", _test_v1_migration, true)
	_runner.add_test("fixture 库: 全量加载不崩且字段齐全", _test_fixtures, true)
	_runner.add_test("高版本档: 门禁拒绝读档且文件原样", _test_future_version_gate, true)
	await _runner.run_async()
	print(_runner.summary())
	SaveManager.delete_game(SLOT)
	get_tree().quit(0 if _runner.all_passed() else 1)


# ─────────────────────────── 样例库构造 ───────────────────────────

func _slot_path() -> String:
	return "user://saves/save_%d.db" % SLOT


## 造指定 schema 版本的样例库。legacy=true 时 construction_projects 缺 material_progress 列
## （模拟 v0 旧建表），并放一个未完工项目行供"数据幸存"断言；
## 另建空 legacy_modules 表（v0 年代的 WorldState 旧档回退通道，防空表查询报错）。
## 非 legacy 时放 '{}' 容器行（WorldState 读档回调直接吃默认值，不触发 legacy 回退）。
## 建表 SQL 复用 save_manager 的 _SCHEMA_SQLS（v0 变体 = 删 material_progress 列定义行）。
func _build_db(version: int, legacy: bool) -> bool:
	SaveManager.delete_game(SLOT)
	var db: Object = ClassDB.instantiate("SQLite")
	if db == null:
		return false
	db.path = _slot_path()
	db.foreign_keys = true
	if not db.open_db():
		return false
	var ok := true
	for stmt_v in SaveManagerScript._SCHEMA_SQLS:
		var stmt := String(stmt_v)
		if legacy and stmt.contains("material_progress"):
			# 该行是列定义（含前导制表符与尾逗号）；删行后 current_work 行的尾逗号
			# 仍合法（SQLite 允许列定义间尾逗号，仅表尾非法）
			var patched := stmt.replace("\n\t\tmaterial_progress REAL NOT NULL DEFAULT 1.0,", "")
			if patched == stmt:
				ok = false  # 替换未命中 = schema 常量已变，v0 模拟失效，响亮失败
				break
			stmt = patched
		if not db.query(stmt):
			ok = false
			break
	if ok and legacy:
		ok = db.query(("CREATE TABLE IF NOT EXISTS legacy_modules ("
			+ "slot_id INTEGER NOT NULL, module_name TEXT NOT NULL DEFAULT '',"
			+ " data TEXT NOT NULL DEFAULT '{}', PRIMARY KEY (slot_id, module_name))"))
	if ok:
		ok = db.query_with_bindings(
			"INSERT INTO save_meta (slot_id, save_name, created_at, updated_at, playtime_seconds,"
			+ " version, current_map_id) VALUES (?, 'migration_test', '2026-01-01 00:00:00',"
			+ " '2026-01-01 00:00:00', 12.5, 2, 'battlefield')", [SLOT])
	if ok and legacy:
		# 未完工项目行（无 material_progress 值）——迁移补列后断言数据幸存 + 默认值兜底
		ok = db.query_with_bindings(
			"INSERT INTO construction_projects (slot_id, project_id, map_id, def_id, cell_x, width,"
			+ " state, total_work, current_work, region_id)"
			+ " VALUES (?, 'proj_legacy', 'battlefield', 'house_a', 3, 2, 1, 30.0, 10.0, 'region_legacy')", [SLOT])
	if ok and not legacy:
		ok = db.query_with_bindings(
			"INSERT INTO world_state (slot_id, module_name, data) VALUES (?, 'world_state', '{}')", [SLOT])
	if ok:
		# PRAGMA 赋值不支持参数绑定（值来自测试入参常量，格式化安全）
		ok = db.query("PRAGMA user_version = %d" % version)
	db.close_db()
	return ok


# ─────────────────────────── 只读断言基建 ───────────────────────────

## 直开槽位库做只读查询（load 链已 end_load 关库，此处独立连接）
func _query_rows(sql: String) -> Array:
	var db: Object = ClassDB.instantiate("SQLite")
	if db == null:
		return []
	db.path = _slot_path()
	if not db.open_db():
		return []
	if not db.query(sql):
		db.close_db()
		return []
	var rows: Array = db.query_result
	db.close_db()
	return rows


func _read_user_version() -> int:
	var rows := _query_rows("PRAGMA user_version")
	return int(rows[0].get("user_version", -1)) if not rows.is_empty() else -1


func _has_column(table: String, column: String) -> bool:
	# 表名来自测试内常量，PRAGMA 不支持参数绑定，格式化安全
	for row_v in _query_rows("PRAGMA table_info(%s)" % table):
		if str((row_v as Dictionary).get("name", "")) == column:
			return true
	return false


func _count(table: String) -> int:
	var rows := _query_rows("SELECT COUNT(*) AS n FROM %s" % table)
	return int(rows[0].get("n", -1)) if not rows.is_empty() else -1


## 整库换槽：fixture 库内生成为生成槽（槽 4），拷入测试槽后把所有含 slot_id 列的表
## 统一改到测试槽——save_meta 元数据查询与各模块读表都按 slot_id 过滤，不换槽
## 内容等于"查不到的幽灵档"。legacy_modules 表仅旧档有，UPDATE 失败静默略过。
func _reslot_db(target_slot: int) -> void:
	var db: Object = ClassDB.instantiate("SQLite")
	if db == null:
		return
	db.path = _slot_path()
	if not db.open_db():
		return
	for table in ["save_meta", "maps", "buildings", "construction_projects",
			"entities", "resource_nodes", "world_state", "legacy_modules"]:
		db.query_with_bindings("UPDATE %s SET slot_id = ?" % table, [target_slot])
	db.close_db()


# ─────────────────────────── 用例 ───────────────────────────

## 用例 1：v0 旧档全链。缺列旧库 → load_game → 迁移链两步走完 →
## user_version 盖章当前版 + material_progress 补列 + 档内项目数据幸存。
func _test_v0_migration() -> void:
	_runner.assert_true(_build_db(0, true), "v0 样例库构造成功")
	_runner.assert_false(_has_column("construction_projects", "material_progress"), "v0 样例确认缺 material_progress 列")
	var ok: bool = SaveManager.load_game(SLOT)
	_runner.assert_true(ok, "v0 旧档读档受理成功: %s" % SaveManager.last_load_fail_reason)
	SaveManager.end_load()
	_runner.assert_equal(_read_user_version(), SaveManager.CURRENT_SCHEMA_VERSION, "迁移链走完 user_version 盖章到当前版")
	_runner.assert_true(_has_column("construction_projects", "material_progress"), "v0→v1 规范化补列 material_progress")
	var rows := _query_rows("SELECT current_work, material_progress FROM construction_projects WHERE project_id = 'proj_legacy'")
	_runner.assert_equal(rows.size(), 1, "迁移后项目行数据幸存")
	if not rows.is_empty():
		var row: Dictionary = rows[0]
		_runner.assert_approx(float(row.get("current_work", -1.0)), 10.0, 0.001, "项目数据无损")
		_runner.assert_approx(float(row.get("material_progress", -1.0)), 1.0, 0.001, "补列默认值 1.0 兜底")


## 用例 2：v1 档。对齐步（无结构变更）走到当前版并盖章。
func _test_v1_migration() -> void:
	_runner.assert_true(_build_db(1, false), "v1 样例库构造成功")
	var ok: bool = SaveManager.load_game(SLOT)
	_runner.assert_true(ok, "v1 档读档受理成功: %s" % SaveManager.last_load_fail_reason)
	SaveManager.end_load()
	_runner.assert_equal(_read_user_version(), SaveManager.CURRENT_SCHEMA_VERSION, "v1→v2 对齐步后盖章到当前版")


## 用例 3：fixture 库全量回归。每份 fixture：拷测试槽 → 元数据可读 → 读档受理 →
## 版本到当前版（旧版 fixture 经迁移链自动升档）→ 按档类断字段齐全。
func _test_fixtures() -> void:
	var dir := DirAccess.open("res://tests/fixtures/saves")
	_runner.assert_not_null(dir, "fixture 目录存在")
	if dir == null:
		return
	var files: Array[String] = []
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if f.ends_with(".db"):
			files.append(f)
		f = dir.get_next()
	files.sort()
	_runner.assert_true(files.size() >= 3, "fixture 至少三份（实测 %d 份）" % files.size())
	var saw_current := false
	for fname in files:
		if fname.begins_with("v%d_" % SaveManager.CURRENT_SCHEMA_VERSION):
			saw_current = true
		_load_fixture_and_assert(fname)
	_runner.assert_true(saw_current, "存在当前版 v%d fixture" % SaveManager.CURRENT_SCHEMA_VERSION)


## 单份 fixture 的通用断言链 + 分档类字段断言
func _load_fixture_and_assert(fname: String) -> void:
	var src := "res://tests/fixtures/saves/%s" % fname
	SaveManager.delete_game(SLOT)
	_runner.assert_true(DirAccess.copy_absolute(src, _slot_path()) == OK, "%s 拷贝到测试槽" % fname)
	_reslot_db(SLOT)
	var info: Dictionary = SaveManager.get_slot_info(SLOT)
	_runner.assert_true(bool(info.get("exists", false)), "%s 元数据可读" % fname)
	_runner.assert_gt(int(info.get("version", -1)), 0, "%s save_meta.version 展示元数据在档" % fname)
	var ok: bool = SaveManager.load_game(SLOT)
	_runner.assert_true(ok, "%s 读档受理成功: %s" % [fname, SaveManager.last_load_fail_reason])
	SaveManager.end_load()
	_runner.assert_equal(_read_user_version(), SaveManager.CURRENT_SCHEMA_VERSION, "%s 加载后版本=当前版" % fname)
	if fname.contains("minimal_empty"):
		_assert_minimal_fields(fname)
	elif fname.contains("full_fields"):
		_assert_full_fields(fname)
	elif fname.contains("formation_org"):
		_assert_formation_fields(fname)


## 最小空档：save_meta 单行、数据表全空、WorldState 容器行在且形状完整（真实新档形态）
func _assert_minimal_fields(fname: String) -> void:
	_runner.assert_equal(_count("save_meta"), 1, "%s save_meta 单行" % fname)
	for table in ["maps", "buildings", "construction_projects", "entities", "resource_nodes"]:
		_runner.assert_equal(_count(table), 0, "%s %s 空表" % [fname, table])
	_runner.assert_equal(_count("world_state"), 1, "%s world_state 容器行在" % fname)
	var ws_rows := _query_rows("SELECT data FROM world_state WHERE module_name = 'world_state'")
	if not ws_rows.is_empty():
		var data_v: Variant = JSON.parse_string(str((ws_rows[0] as Dictionary).get("data", "")))
		var complete: bool = data_v is Dictionary \
				and (data_v as Dictionary).has("game_time") \
				and (data_v as Dictionary).has("organizations")
		_runner.assert_true(complete, "%s 容器行形状完整（game_time/organizations 键在）" % fname)


## 满字段档：各数据表 ≥1 行 + 抽查生成器写入的非默认值（_enrich_full_fields 的镜像断言）
func _assert_full_fields(fname: String) -> void:
	for table in ["maps", "buildings", "construction_projects", "entities", "resource_nodes"]:
		_runner.assert_true(_count(table) >= 1, "%s %s 有数据行" % [fname, table])
	var maps := _query_rows("SELECT town_center_world_x FROM maps WHERE map_id = 'battlefield'")
	_runner.assert_true(not maps.is_empty() and absf(float((maps[0] as Dictionary).get("town_center_world_x", 0.0)) - 1234.5) < 0.01,
		"%s maps 行字段在档" % fname)
	var bld := _query_rows("SELECT health, wall_tier, is_gate, region_id FROM buildings WHERE building_id = 'bld_fixture_0001'")
	_runner.assert_true(not bld.is_empty() and absf(float((bld[0] as Dictionary).get("health", 0.0)) - 66.5) < 0.01
		and int((bld[0] as Dictionary).get("wall_tier", 0)) == 2 and int((bld[0] as Dictionary).get("is_gate", 0)) == 1
		and str((bld[0] as Dictionary).get("region_id", "")) == "region_fixture",
		"%s buildings 行字段在档" % fname)
	var proj := _query_rows("SELECT material_progress, current_work FROM construction_projects WHERE project_id = 'proj_fixture_0001'")
	_runner.assert_true(not proj.is_empty() and absf(float((proj[0] as Dictionary).get("material_progress", 0.0)) - 0.5) < 0.01,
		"%s 未完工项目行（含 material_progress）在档" % fname)
	var ents := _query_rows("SELECT entity_id, is_player, extra_data FROM entities WHERE is_player = 1")
	_runner.assert_equal(ents.size(), 1, "%s 玩家实体行唯一" % fname)
	if not ents.is_empty():
		var extra_v: Variant = JSON.parse_string(str((ents[0] as Dictionary).get("extra_data", "")))
		_runner.assert_true(extra_v is Dictionary and (extra_v as Dictionary).has("faction_id"),
			"%s extra_data 扩展字段可解析" % fname)
	var nodes := _query_rows("SELECT amount FROM resource_nodes WHERE node_id = 'node_fixture_0001'")
	_runner.assert_true(not nodes.is_empty() and int((nodes[0] as Dictionary).get("amount", 0)) == 87,
		"%s 资源点行字段在档" % fname)


## 编队组织档：4 实体 + formation 行（两班一排、ent_* 稳定键）+ 容器行组织账
func _assert_formation_fields(fname: String) -> void:
	_runner.assert_equal(_count("entities"), 4, "%s 四实体在档" % fname)
	var form_rows := _query_rows("SELECT data FROM world_state WHERE module_name = 'formation'")
	_runner.assert_equal(form_rows.size(), 1, "%s formation 行在" % fname)
	if not form_rows.is_empty():
		var formation_v: Variant = JSON.parse_string(str((form_rows[0] as Dictionary).get("data", "")))
		if formation_v is Dictionary:
			var formation: Dictionary = formation_v
			var squads: Array = formation.get("squads", [])
			var platoons: Array = formation.get("platoons", [])
			_runner.assert_equal(squads.size(), 2, "%s 两班在档" % fname)
			_runner.assert_equal(platoons.size(), 1, "%s 一排在档" % fname)
			var all_ent_keys: bool = not squads.is_empty()
			for s_v in squads:
				for m_v in (s_v as Dictionary).get("members", []):
					if not str(m_v).begins_with("ent_"):
						all_ent_keys = false
			_runner.assert_true(all_ent_keys, "%s 班成员为存档稳定键 ent_*" % fname)
	var ws_rows := _query_rows("SELECT data FROM world_state WHERE module_name = 'world_state'")
	if not ws_rows.is_empty():
		var container_v: Variant = JSON.parse_string(str((ws_rows[0] as Dictionary).get("data", "")))
		if container_v is Dictionary:
			var orgs: Dictionary = (container_v as Dictionary).get("organizations", {})
			_runner.assert_true(orgs.has("org_1") and orgs.has("org_2"), "%s 组织账入容器行" % fname)
			if orgs.has("org_1"):
				_runner.assert_true(not (orgs["org_1"] as Dictionary).get("personnel", []).is_empty(),
					"%s 组织人员账非空" % fname)


## 用例 4：高版本门禁。版本高于当前支持 → 拒绝读档 + 失败原因指向版本 + 文件原样（版本戳未被降级写坏）。
func _test_future_version_gate() -> void:
	var future: int = SaveManager.CURRENT_SCHEMA_VERSION + 1
	_runner.assert_true(_build_db(future, false), "高版本样例库构造成功")
	_runner.assert_false(SaveManager.load_game(SLOT), "高版本档拒绝读档")
	_runner.assert_true(SaveManager.last_load_fail_reason.contains("版本"),
		"失败原因指向版本口径: %s" % SaveManager.last_load_fail_reason)
	_runner.assert_equal(_read_user_version(), future, "拒读未降级写坏版本戳")
