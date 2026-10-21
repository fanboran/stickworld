extends Node
## 游戏存档管理 -- SQLite 版。
##
## 多存档槽位（slot 0..N-1），保存为 SQLite 数据库文件 user://saves/save_<slot>.db。
## 数据统一走单一接口：模块订阅 EventBus.game_saving / game_loaded，
## 在回调中经 get_db() 直接读写各自的表（2026-08-22 移除 legacy_modules 双轨）。
##
## 详见 modules/README.md §8 存储分层

const SLOT_COUNT := 5
const SAVE_DIR := "user://saves"

# SQL 白名单：表名无法经 ? 参数化，统一定义为常量；运行时值一律走 ? 绑定
# （query_with_bindings），禁止字符串拼接进 SQL。
const _SQL_META_SELECT_ALL := "SELECT * FROM save_meta WHERE slot_id = ?"
const _SQL_META_SELECT_CREATED := "SELECT created_at FROM save_meta WHERE slot_id = ?"
# 列顺序对齐 _SCHEMA_SQLS 的 save_meta 建表定义（_upsert_save_meta 单语句写入）
const _SQL_META_UPSERT := "INSERT OR REPLACE INTO save_meta (slot_id, save_name, created_at, updated_at, playtime_seconds, version, current_map_id) VALUES (?, ?, ?, ?, ?, ?, ?)"

# ── schema 版本化（PRAGMA user_version）+ 迁移链 ──
## 当前支持的存档 schema 版本。读档门禁与迁移链的真相源；save_meta.version 列是展示
## 元数据，存档路径每次保存与本文同源写入（口径详见 docs/技术/架构/数据与契约/存储架构设计.md）。
## 版本语义：
##   v0 = 版本化机制启用前的旧档（user_version 未盖章，结构无保证——可能缺表/缺列）
##   v1 = 规范化结构 = v0 经迁移链补齐建表 SQL + construction_projects 补列后的形态
##   v2 = 现行建表 SQL 的表结构（与 v1 等价，仅作为链式迁移的版本对齐步保留）
## 引入不兼容表结构变更的三步动作：
##   1. 本常量增一；
##   2. _migration_steps 登记 `<旧版本>: _migrate_vN_to_vN1`（函数内完成结构变更与数据搬移）；
##   3. 重跑 tools/save/generate_save_fixtures.tscn 新增一份当前版 fixture 入 tests/fixtures/saves/
##      （纪律：每次存档格式变更必须新增一份 fixture，见存储架构设计.md §版本迁移链）。
const CURRENT_SCHEMA_VERSION := 2
const _SQL_PRAGMA_USER_VERSION_GET := "PRAGMA user_version"

## 迁移注册表：键 = 起始 schema 版本，值 = 升一档迁移函数（Callable，操作 _db，返回成败）。
## load_game 从档内版本起逐级查表执行到 CURRENT_SCHEMA_VERSION，全程单事务
## （任一步失败回滚拒绝读档——半迁移状态比读不出更危险）。_init 填充（方法引用需 self）。
var _migration_steps: Dictionary = {}

var _auto_save_timer: float = 0.0
var _auto_save_slot: int = 0
var _auto_save_enabled: bool = true
var _start_time: float = 0.0

# SQLite 连接（save/load 期间有效）
var _db = null
var _current_slot: int = -1

## 下次启动（GameRoot 装配后）要读取的存档槽位；-1 = 正常新游戏。
## 主菜单「继续游戏/读取存档」设置后切换场景，GameRoot 启动时消费并复位。
var boot_load_slot: int = -1

## 最近一次 load_game 失败的原因（用户可读文案；"" = 未失败/已成功）。
## load_game 返回 false 时调用方可读取此字段弹 ui_notification（无 UI 路径仍只有 push_error）。
var last_load_fail_reason: String = ""
# 读档兜底计时器：game_loaded 后若场景恢复失败/无当前地图，超时强制关闭 DB
var _load_guard: Timer = null

# 建表 SQL（§3.2）
const _SCHEMA_SQLS: Array[String] = [
	"""CREATE TABLE IF NOT EXISTS save_meta (
		slot_id           INTEGER PRIMARY KEY,
		save_name         TEXT    NOT NULL DEFAULT '',
		created_at        TEXT    NOT NULL,
		updated_at        TEXT    NOT NULL,
		playtime_seconds  REAL    NOT NULL DEFAULT 0.0,
		version           INTEGER NOT NULL DEFAULT 2,
		current_map_id    TEXT    NOT NULL DEFAULT ''
	);""",
	"""CREATE TABLE IF NOT EXISTS maps (
		slot_id              INTEGER NOT NULL,
		map_id               TEXT    NOT NULL,
		town_center_world_x  REAL    NOT NULL DEFAULT 0.0,
		map_left_cell        INTEGER NOT NULL DEFAULT 0,
		map_right_cell       INTEGER NOT NULL DEFAULT 0,
		city_left_x          REAL    NOT NULL DEFAULT -99999.0,
		city_right_x         REAL    NOT NULL DEFAULT -99999.0,
		ground_y             REAL    NOT NULL DEFAULT 810.0,
		ground_bottom        REAL    NOT NULL DEFAULT 1080.0,
		PRIMARY KEY (slot_id, map_id),
		FOREIGN KEY (slot_id) REFERENCES save_meta(slot_id) ON DELETE CASCADE
	);""",
	"""CREATE TABLE IF NOT EXISTS buildings (
		slot_id       INTEGER NOT NULL,
		building_id   TEXT    NOT NULL,
		map_id        TEXT    NOT NULL,
		def_id        TEXT    NOT NULL,
		cell_x        INTEGER NOT NULL,
		width         INTEGER NOT NULL DEFAULT 1,
		state         INTEGER NOT NULL DEFAULT 2,
		health        REAL    NOT NULL DEFAULT 100.0,
		max_health    REAL    NOT NULL DEFAULT 100.0,
		is_terrain    INTEGER NOT NULL DEFAULT 0,
		wall_tier     INTEGER NOT NULL DEFAULT 0,
		is_gate       INTEGER NOT NULL DEFAULT 0,
		region_id     TEXT    NOT NULL DEFAULT '',
		PRIMARY KEY (slot_id, building_id),
		FOREIGN KEY (slot_id) REFERENCES save_meta(slot_id) ON DELETE CASCADE
	);""",
	"""CREATE INDEX IF NOT EXISTS idx_buildings_map ON buildings(slot_id, map_id);""",
	"""CREATE TABLE IF NOT EXISTS construction_projects (
		slot_id       INTEGER NOT NULL,
		project_id    TEXT    NOT NULL,
		map_id        TEXT    NOT NULL,
		def_id        TEXT    NOT NULL,
		cell_x        INTEGER NOT NULL,
		width         INTEGER NOT NULL DEFAULT 1,
		state         INTEGER NOT NULL DEFAULT 0,
		total_work    REAL    NOT NULL DEFAULT 10.0,
		current_work  REAL    NOT NULL DEFAULT 0.0,
		material_progress REAL NOT NULL DEFAULT 1.0,
		region_id     TEXT    NOT NULL DEFAULT '',
		PRIMARY KEY (slot_id, project_id),
		FOREIGN KEY (slot_id) REFERENCES save_meta(slot_id) ON DELETE CASCADE
	);""",
	"""CREATE INDEX IF NOT EXISTS idx_projects_map ON construction_projects(slot_id, map_id);""",
	"""CREATE TABLE IF NOT EXISTS entities (
		slot_id       INTEGER NOT NULL,
		map_id        TEXT    NOT NULL,
		entity_id     TEXT    NOT NULL,
		entity_type   TEXT    NOT NULL DEFAULT 'stickman',
		def_id        TEXT    NOT NULL DEFAULT '',
		pos_x         REAL    NOT NULL,
		pos_y         REAL    NOT NULL,
		facing        INTEGER NOT NULL DEFAULT 1,
		is_player     INTEGER NOT NULL DEFAULT 0,
		extra_data    TEXT    NOT NULL DEFAULT '{}',
		PRIMARY KEY (slot_id, map_id, entity_id),
		FOREIGN KEY (slot_id) REFERENCES save_meta(slot_id) ON DELETE CASCADE
	);""",
	"""CREATE INDEX IF NOT EXISTS idx_entities_map ON entities(slot_id, map_id);""",
	"""CREATE TABLE IF NOT EXISTS resource_nodes (
		slot_id         INTEGER NOT NULL,
		map_id          TEXT    NOT NULL,
		node_id         TEXT    NOT NULL,
		pos_x           REAL    NOT NULL,
		pos_y           REAL    NOT NULL,
		resource_type   INTEGER NOT NULL DEFAULT 0,
		amount          INTEGER NOT NULL DEFAULT 100,
		PRIMARY KEY (slot_id, map_id, node_id),
		FOREIGN KEY (slot_id) REFERENCES save_meta(slot_id) ON DELETE CASCADE
	);""",
	"""CREATE TABLE IF NOT EXISTS world_state (
		slot_id        INTEGER NOT NULL,
		module_name    TEXT    NOT NULL DEFAULT 'world_state',
		data           TEXT    NOT NULL DEFAULT '{}',
		PRIMARY KEY (slot_id, module_name),
		FOREIGN KEY (slot_id) REFERENCES save_meta(slot_id) ON DELETE CASCADE
	);""",
]


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _init() -> void:
	# 迁移链注册：键 = 起始版本，值 = 升一档函数。未来 v2→v3 照此追加新键值对。
	_migration_steps = {
		0: _migrate_v0_to_v1,
		1: _migrate_v1_to_v2,
	}


func _ready() -> void:
	# 服务方 autoload：暂停期照常服务——存读档可从暂停菜单发起（F5/F9/面板），
	# LoadGuard 看门狗须在引擎总闸（SceneTree.paused）下继续计时。
	# 自动加载不在 game_root/ui_root 两棵子树内，在各自 _ready 声明（分层声明表例外项）。
	process_mode = Node.PROCESS_MODE_ALWAYS
	if not DirAccess.dir_exists_absolute(SAVE_DIR):
		var err: int = DirAccess.make_dir_absolute(SAVE_DIR)
		if err != OK:
			push_warning("[SaveManager] 创建保存目录失败: %s" % SAVE_DIR)
	_start_time = Time.get_unix_time_from_system()
	_load_guard = Timer.new()
	_load_guard.name = "LoadGuard"
	_load_guard.one_shot = true
	_load_guard.wait_time = 30.0
	_load_guard.timeout.connect(_on_load_guard_timeout)
	add_child(_load_guard)


func _process(delta: float) -> void:
	if not _auto_save_enabled:
		return
	var interval: float = 60.0
	if ConfigManager and ConfigManager.has_key("game/auto_save_interval_sec"):
		var raw = ConfigManager.get_value("game/auto_save_interval_sec")
		if raw != null:
			interval = float(raw)
	if interval <= 0:
		return
	_auto_save_timer += delta
	if _auto_save_timer >= interval:
		# 读档恢复窗口/写档进行中 _db 仍打开：此刻自动存档会强关连接、
		# 把半恢复状态写进档——推迟，窗口关闭（end_load）后立即补存
		if _db != null:
			return
		_auto_save_timer = 0.0
		save_game(_auto_save_slot)


# ─────────────────────────────── DB 访问（供模块使用）────────────────

## 获取当前操作的 DB 连接（save/load 期间有效，外部不应长期持有）
func get_db() -> Object:
	return _db


## 获取当前槽位
func get_current_slot() -> int:
	return _current_slot


## 读档场景恢复完成后调用，关闭 DB
func end_load() -> void:
	if _load_guard != null:
		_load_guard.stop()
	if _db != null:
		_db.close_db()
		_db = null
	_current_slot = -1


## 读档兜底：恢复流程失败/无当前地图时，超时强制关闭 DB，避免半开连接
func _on_load_guard_timeout() -> void:
	if _db == null:
		return
	push_warning("[SaveManager] 读档恢复超时，强制关闭数据库")
	end_load()


## 读档完成后启动兜底计时器（由 load_game 调用）
func _arm_load_guard() -> void:
	if _load_guard != null and _db != null:
		_load_guard.start()


# ─────────────────────────────── 存档操作 ────────────────────────────────

func save_game(slot_index: int) -> bool:
	if slot_index < 0 or slot_index >= SLOT_COUNT:
		push_warning("[SaveManager] 存档槽越界: %d" % slot_index)
		return false
	# 防御：若上一个连接（读档残留/未走 end_load）仍打开，先关再开，避免双连接写锁
	if _db != null:
		push_warning("[SaveManager] save_game 时发现未关闭的连接，强制关闭（疑似跳过 end_load 的路径）")
		_db.close_db()
		_db = null

	_db = _open_db_for_slot(slot_index)
	if _db == null:
		return false
	_current_slot = slot_index
	_ensure_schema()

	# 注：不用外层 BEGIN/COMMIT 包裹整段写库 —— godot-sqlite 的每次写库调用
	# （query_with_bindings / insert_row 等）独立执行并提交（autocommit，2026-08-15 实测确认），
	# 外层事务会与其嵌套冲突（每次写库刷 2 条 ERROR 日志），且首个语句的隐式 COMMIT 会
	# 提前提交外层事务，最后的 COMMIT 必然失败。每条语句的原子性由 autocommit 保证。

	# 写元数据（version 列与 schema 版本同源，仍为 2，存档格式不变）
	var now := Time.get_date_string_from_system() + " " + Time.get_time_string_from_system()
	_upsert_save_meta(slot_index, now, _accumulate_playtime(), CURRENT_SCHEMA_VERSION)

	# 模块接口：emit game_saving 信号，模块在回调中用 get_db() 写表
	# 必须在 DB 打开后 emit，否则 get_db() 返回 null
	EventBus.game_saving.emit(slot_index)

	_db.close_db()
	_db = null
	_current_slot = -1

	EventBus.game_saved.emit(slot_index)
	return true


func load_game(slot_index: int) -> bool:
	last_load_fail_reason = ""
	if slot_index < 0 or slot_index >= SLOT_COUNT:
		push_warning("[SaveManager] 存档槽越界: %d" % slot_index)
		last_load_fail_reason = "存档槽位无效"
		return false

	if not slot_exists(slot_index):
		push_warning("[SaveManager] 存档不存在: %s" % _slot_path(slot_index))
		last_load_fail_reason = "存档不存在"
		return false
	# 防御：同上，读档入口先关残留连接
	if _db != null:
		push_warning("[SaveManager] load_game 时发现未关闭的连接，强制关闭")
		_db.close_db()
		_db = null

	_db = _open_db_for_slot(slot_index)
	if _db == null:
		last_load_fail_reason = "存档文件无法打开"
		return false
	_current_slot = slot_index

	# schema 版本门禁：存档版本高于当前支持 = 来自更新版本的游戏，
	# 贸然读取可能损坏数据（降级写坏），push_error 并拒绝读档。
	var schema_version: int = _read_schema_version(_db)
	if schema_version > CURRENT_SCHEMA_VERSION:
		push_error("[SaveManager] 拒绝读取存档槽位 %d：schema 版本 %d 高于当前支持 %d（存档可能来自更新版本的游戏）"
			% [slot_index, schema_version, CURRENT_SCHEMA_VERSION])
		last_load_fail_reason = "存档版本高于当前游戏（可能来自更新版本），拒绝读取"
		_db.close_db()
		_db = null
		_current_slot = -1
		return false
	# 版本低于当前支持：走迁移链逐级升档（任一步失败回滚并拒绝读档）
	if not _migrate_loaded_schema(schema_version):
		push_error("[SaveManager] 存档槽位 %d schema 迁移失败（v%d → v%d），拒绝读档"
			% [slot_index, schema_version, CURRENT_SCHEMA_VERSION])
		last_load_fail_reason = "存档格式迁移失败（存档可能已损坏）"
		_db.close_db()
		_db = null
		_current_slot = -1
		return false

	# 模块接口：发射 game_loaded 信号，模块自行读表
	# DB 保持打开，等 GameRoot 场景恢复后调 end_load() 关闭；
	# 若恢复流程失败/无当前地图，_load_guard 超时兜底关闭。
	EventBus.game_loaded.emit(slot_index)
	_arm_load_guard()
	return true


func delete_game(slot_index: int) -> bool:
	if slot_index < 0 or slot_index >= SLOT_COUNT:
		return false
	var path: String = _slot_path(slot_index)
	if FileAccess.file_exists(path):
		var err: int = DirAccess.remove_absolute(path)
		return err == OK
	return true


func slot_exists(slot_index: int) -> bool:
	if slot_index < 0 or slot_index >= SLOT_COUNT:
		return false
	return FileAccess.file_exists(_slot_path(slot_index))


func get_slot_info(slot_index: int) -> Dictionary:
	var info: Dictionary = {
		"exists": false,
		"slot": slot_index,
		"datetime": "",
		"playtime_seconds": 0,
		"version": 0,
	}
	# 优先检查 SQLite DB
	var db_path := _slot_path(slot_index)
	if FileAccess.file_exists(db_path):
		var db = _new_db()
		if db == null:
			return info
		db.path = db_path
		if not db.open_db():
			return info
		# 与 _open_db_for_slot 对齐：SavePanel 列表查询遇写锁时不静默失败
		db.query("PRAGMA busy_timeout = 5000")
		var rows: Array = []
		if db.query_with_bindings(_SQL_META_SELECT_ALL, [slot_index]):
			rows = db.query_result
		db.close_db()
		if rows.is_empty():
			return info
		var row: Dictionary = rows[0]
		info["exists"] = true
		info["datetime"] = str(row.get("updated_at", ""))
		info["playtime_seconds"] = int(row.get("playtime_seconds", 0))
		info["version"] = int(row.get("version", 0))
		return info
	return info


func list_slots() -> Array:
	var result: Array = []
	for i in range(SLOT_COUNT):
		result.append(get_slot_info(i))
	return result


# ─────────────────────────────── 配置 ───────────────────────────────────

func set_auto_save_enabled(enabled: bool) -> void:
	_auto_save_enabled = enabled


func is_auto_save_enabled() -> bool:
	return _auto_save_enabled


func set_auto_save_slot(slot_index: int) -> void:
	if slot_index >= 0 and slot_index < SLOT_COUNT:
		_auto_save_slot = slot_index


# ─────────────────────────────── 内部方法 ─────────────────────────────

## 创建新的 SQLite 实例（安全封装，防止插件未加载时崩溃）
func _new_db() -> Object:
	if not ClassDB.class_exists("SQLite"):
		push_warning("[SaveManager] SQLite 类未注册（GDExtension 插件未加载？）")
		return null
	return ClassDB.instantiate("SQLite")


## 打开指定槽位的数据库
func _open_db_for_slot(slot_index: int) -> Object:
	var db = _new_db()
	if db == null:
		push_warning("[SaveManager] 无法创建 SQLite 实例（插件未加载？）")
		return null
	db.path = _slot_path(slot_index)
	db.foreign_keys = true
	if not db.open_db():
		push_warning("[SaveManager] 无法打开数据库: %s" % db.path)
		return null
	# 缓解"database is locked"：并发窗口（SavePanel 列表查询/读档残留连接）内
	# 写锁竞争改为重试 5 秒而非立刻报错（2026-08-22，SQLITE_BUSY 实测）
	if db.has_method("query"):
		db.query("PRAGMA busy_timeout = 5000")
	return db


func _slot_path(slot_index: int) -> String:
	return "%s/save_%d.db" % [SAVE_DIR, slot_index]


## 确保所有表存在（幂等）
## DDL 段包显式事务：godot-sqlite 每条 query 独立 autocommit 提交（Windows 每次提交
## 一次 fsync，12 条建表语句在存档路径上白付 ~11 次磁盘提交，基准 bench_infra_save
## 实测占全链存档大头）。DDL 均为 IF NOT EXISTS/幂等 PRAGMA，事务内执行行为等价。
## 注意：此事务只包本方法的 DDL——game_saving 回调中的 insert_rows 自带事务，
## 混在外层事务里会嵌套冲突（其内部 BEGIN/COMMIT 会提前结束外层事务）。
func _ensure_schema() -> void:
	if _db == null:
		return
	if not _db.query("BEGIN IMMEDIATE"):
		push_error("[SaveManager] schema 事务开启失败: %s" % str(_db.error_message))
	for stmt in _SCHEMA_SQLS:
		if not _db.query(stmt):
			push_error("[SaveManager] 建表语句执行失败: %s…（%s）" % [stmt.left(48), str(_db.error_message)])
	_migrate_schema()
	# 表结构就绪后盖章 schema 版本：旧档（user_version=0）在下次存档时自动升级标记
	_stamp_schema_version()
	if not _db.query("COMMIT"):
		push_error("[SaveManager] schema 事务提交失败: %s" % str(_db.error_message))


## 旧库补列（存档路径兜底）：construction_projects 补 material_progress 列，幂等。
## 迁移链（读档路径 _migrate_v0_to_v1）与本入口共用 _patch_material_progress_column。
func _migrate_schema() -> void:
	_patch_material_progress_column("存档路径")


## construction_projects 补 material_progress 列（幂等，按列检查后 ALTER）。
## 修复背景：写侧 insert 含该列而旧建表 SQL 缺列，导致含未完工项目的存档写入静默失败、项目丢失。
## CREATE TABLE IF NOT EXISTS 对已存在的旧表无效，须按列检查后 ALTER 补列。
## context 仅用于日志定位（"存档路径" / 迁移步名）。返回 false = 补列失败。
func _patch_material_progress_column(context: String) -> bool:
	if _db == null:
		return false
	if _db.query("PRAGMA table_info(construction_projects)") == false:
		return false
	for raw_row in _db.query_result:
		var row: Dictionary = raw_row
		if str(row.get("name", "")) == "material_progress":
			return true
	var migrated: Variant = _db.query(
		"ALTER TABLE construction_projects ADD COLUMN material_progress REAL NOT NULL DEFAULT 1.0")
	if migrated == false:
		push_warning("[SaveManager] construction_projects 补列 material_progress 失败（%s），未完工项目存档将丢失" % context)
		return false
	return true


## 读取存档 schema 版本（PRAGMA user_version）。
## 读取失败/无版本标记返回 0（视为版本化启用前的旧档，不据此拒绝读档）。
func _read_schema_version(db) -> int:
	if db == null:
		return 0
	if not db.query(_SQL_PRAGMA_USER_VERSION_GET):
		push_warning("[SaveManager] 读取 schema 版本失败: %s" % str(db.error_message))
		return 0
	var rows: Array = db.query_result
	if rows.is_empty():
		return 0
	return int(rows[0].get("user_version", 0))


## 存档路径：把 schema 版本戳升到当前支持值（幂等）。
## 仅在 _ensure_schema（建表/补列完成）后调用；旧档下次存档即自动盖章升级。
func _stamp_schema_version() -> void:
	if _db == null:
		return
	# PRAGMA 赋值不支持参数绑定，值来自内部常量（非运行时输入），格式化安全
	if not _db.query("PRAGMA user_version = %d" % CURRENT_SCHEMA_VERSION):
		push_error("[SaveManager] schema 版本戳写入失败（user_version=%d）: %s"
			% [CURRENT_SCHEMA_VERSION, str(_db.error_message)])


## 读档路径：schema 版本迁移链——从档内版本起查 _migration_steps 逐级升档到当前版。
## 全程单事务：任一步失败 ROLLBACK 并返回 false，调用方拒绝读档（半迁移状态比读不出更危险）。
## 链走完就地盖章 user_version = CURRENT（迁移结果持久化，下次读档零迁移直通）。
## 档内版本在注册表中缺分支 = 未处理的旧版本（程序缺陷或断代档案），拒绝读档。
func _migrate_loaded_schema(from_version: int) -> bool:
	if from_version >= CURRENT_SCHEMA_VERSION:
		return true
	if not _migration_steps.has(from_version):
		push_error("[SaveManager] 存档 schema v%d 无迁移分支（当前支持 v%d），拒绝读档"
			% [from_version, CURRENT_SCHEMA_VERSION])
		return false
	if not _db.query("BEGIN IMMEDIATE"):
		push_error("[SaveManager] 迁移事务开启失败: %s" % str(_db.error_message))
		return false
	var v: int = from_version
	while v < CURRENT_SCHEMA_VERSION:
		var step: Variant = _migration_steps.get(v)
		if step == null or not step.call():
			push_error("[SaveManager] 存档 schema 迁移失败 v%d→v%d，回滚拒绝读档" % [v, v + 1])
			_db.query("ROLLBACK")
			return false
		v += 1
	_stamp_schema_version()
	if not _db.query("COMMIT"):
		push_error("[SaveManager] 迁移事务提交失败（已回滚）: %s" % str(_db.error_message))
		_db.query("ROLLBACK")
		return false
	print("[SaveManager] 存档 schema v%d → v%d 迁移完成" % [from_version, CURRENT_SCHEMA_VERSION])
	return true


## 迁移步 v0→v1 规范化：版本化机制启用前的旧档结构无保证——建表 SQL 全量补齐
## （IF NOT EXISTS 幂等）+ construction_projects 补 material_progress 列，
## 把库规范化到 v1 结构（与 v2 表结构完全等价）。
func _migrate_v0_to_v1() -> bool:
	for stmt in _SCHEMA_SQLS:
		if not _db.query(stmt):
			push_error("[SaveManager] v0→v1 建表规范化失败: %s…（%s）" % [stmt.left(48), str(_db.error_message)])
			return false
	return _patch_material_progress_column("迁移 v0→v1")


## 迁移步 v1→v2 版本对齐：v1 与 v2 表结构完全等价，无结构变更，仅作为链式骨架的对齐步
## （每引入一个新版本即新增一个迁移函数并登记 _migration_steps，无论该步是否有实际结构变更）。
func _migrate_v1_to_v2() -> bool:
	return true


## 写入或更新 save_meta（保留首次创建时间，只更新 updated_at）
## INSERT OR REPLACE 单语句：语义与原 DELETE+INSERT 完全一致（REPLACE 冲突即
## 删旧行插新行，save_meta 主键 slot_id；FK 级联行为同原 DELETE——子表行清除后
## 由各模块 game_saving 回调重写，全链行为不变），少一次 autocommit 磁盘提交。
func _upsert_save_meta(slot_id: int, datetime: String, playtime: float, version: int) -> void:
	var rows: Array = []
	if _db.query_with_bindings(_SQL_META_SELECT_CREATED, [slot_id]):
		rows = _db.query_result
	var created_at: String = datetime
	if not rows.is_empty():
		created_at = str(rows[0].get("created_at", datetime))
	if not _db.query_with_bindings(_SQL_META_UPSERT,
			[slot_id, "", created_at, datetime, playtime, version, ""]):
		push_error("[SaveManager] save_meta 元数据写入失败 slot=%d: %s" % [slot_id, str(_db.error_message)])


func _accumulate_playtime() -> float:
	if _start_time == 0.0:
		_start_time = Time.get_unix_time_from_system()
		return 0.0
	return Time.get_unix_time_from_system() - _start_time
