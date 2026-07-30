extends Node
## 游戏存档管理 -- SQLite 版。
##
## 多存档槽位（slot 0..N-1），保存为 SQLite 数据库文件 user://saves/save_<slot>.db。
## 数据来自两类提供者：
##   1. 旧接口模块（WorldState 等）：实现 get_save_data() / load_save_data()，数据存入 legacy_modules 表（JSON blob）
##   2. 新接口模块（GameRoot 等）：在 game_saving / game_loaded 信号回调中通过 get_db() 直接操作 DB 表
##
## 详见 docs/技术/架构/SQLite存档迁移方案.md

const SLOT_COUNT := 5
const SAVE_DIR := "user://saves"

# 模块注册表：module_name -> 对象
var _modules: Dictionary = {}

var _auto_save_timer: float = 0.0
var _auto_save_slot: int = 0
var _auto_save_enabled: bool = true
var _start_time: float = 0.0

# SQLite 连接（save/load 期间有效）
var _db = null
var _current_slot: int = -1

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
	"""CREATE TABLE IF NOT EXISTS legacy_modules (
		slot_id        INTEGER NOT NULL,
		module_name    TEXT    NOT NULL,
		data           TEXT    NOT NULL DEFAULT '{}',
		PRIMARY KEY (slot_id, module_name),
		FOREIGN KEY (slot_id) REFERENCES save_meta(slot_id) ON DELETE CASCADE
	);""",
]


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	if not DirAccess.dir_exists_absolute(SAVE_DIR):
		var err: int = DirAccess.make_dir_absolute(SAVE_DIR)
		if err != OK:
			push_warning("[SaveManager] 创建保存目录失败: %s" % SAVE_DIR)
	_start_time = Time.get_unix_time_from_system()


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
		_auto_save_timer = 0.0
		save_game(_auto_save_slot)


# ─────────────────────────────── 模块注册 ────────────────────────────────

func register_module(module_name: String, module_object: Object) -> void:
	if not module_object:
		push_warning("[SaveManager] 注册空对象: %s" % module_name)
		return
	_modules[module_name] = module_object


func unregister_module(module_name: String) -> void:
	if _modules.has(module_name):
		_modules.erase(module_name)


# ─────────────────────────────── DB 访问（供新接口模块使用）────────────────

## 获取当前操作的 DB 连接（save/load 期间有效，外部不应长期持有）
func get_db():
	return _db


## 获取当前槽位
func get_current_slot() -> int:
	return _current_slot


## 读档场景恢复完成后调用，关闭 DB
func end_load() -> void:
	if _db != null:
		_db.close_db()
		_db = null
	_current_slot = -1


# ─────────────────────────────── 存档操作 ────────────────────────────────

func save_game(slot_index: int) -> bool:
	if slot_index < 0 or slot_index >= SLOT_COUNT:
		push_warning("[SaveManager] 存档槽越界: %d" % slot_index)
		return false

	_db = _open_db_for_slot(slot_index)
	if _db == null:
		return false
	_current_slot = slot_index
	_ensure_schema()

	# 写元数据
	var now := Time.get_date_string_from_system() + " " + Time.get_time_string_from_system()
	_upsert_save_meta(slot_index, now, _accumulate_playtime(), 2)

	# 旧接口模块：调 get_save_data()，存入 legacy_modules 表
	_save_legacy_modules()

	# 新接口模块：emit game_saving 信号，模块在回调中用 get_db() 写表
	# 必须在 DB 打开后 emit，否则 get_db() 返回 null
	EventBus.game_saving.emit(slot_index)

	_db.close_db()
	_db = null
	_current_slot = -1

	EventBus.game_saved.emit(slot_index)
	return true


func load_game(slot_index: int) -> bool:
	if slot_index < 0 or slot_index >= SLOT_COUNT:
		push_warning("[SaveManager] 存档槽越界: %d" % slot_index)
		return false

	if not slot_exists(slot_index):
		push_warning("[SaveManager] 存档不存在: %s" % _slot_path(slot_index))
		return false

	_db = _open_db_for_slot(slot_index)
	if _db == null:
		return false
	_current_slot = slot_index

	# 旧接口模块：从 legacy_modules 读，调 load_save_data()
	_load_legacy_modules()

	# 新接口模块：发射 game_loaded 信号，模块自行读表
	# DB 保持打开，等 GameRoot 场景恢复后调 end_load() 关闭
	EventBus.game_loaded.emit(slot_index)
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
		var rows: Array = db.select_rows("save_meta", "slot_id = %d" % slot_index, ["*"])
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
func _new_db():
	if not ClassDB.class_exists("SQLite"):
		push_warning("[SaveManager] SQLite 类未注册（GDExtension 插件未加载？）")
		return null
	return ClassDB.instantiate("SQLite")


## 打开指定槽位的数据库
func _open_db_for_slot(slot_index: int):
	var db = _new_db()
	if db == null:
		push_warning("[SaveManager] 无法创建 SQLite 实例（插件未加载？）")
		return null
	db.path = _slot_path(slot_index)
	db.foreign_keys = true
	if not db.open_db():
		push_warning("[SaveManager] 无法打开数据库: %s" % db.path)
		return null
	return db


func _slot_path(slot_index: int) -> String:
	return "%s/save_%d.db" % [SAVE_DIR, slot_index]


## 确保所有表存在（幂等）
func _ensure_schema() -> void:
	if _db == null:
		return
	for stmt in _SCHEMA_SQLS:
		_db.query(stmt)


## 写入或更新 save_meta
func _upsert_save_meta(slot_id: int, datetime: String, playtime: float, version: int) -> void:
	# 先尝试删除旧记录（save_meta 主键是 slot_id）
	_db.delete_rows("save_meta", "slot_id = %d" % slot_id)
	_db.insert_row("save_meta", {
		"slot_id": slot_id,
		"save_name": "",
		"created_at": datetime,
		"updated_at": datetime,
		"playtime_seconds": playtime,
		"version": version,
		"current_map_id": "",
	})


## 旧接口模块：调 get_save_data()，结果存入 legacy_modules 表
func _save_legacy_modules() -> void:
	_db.delete_rows("legacy_modules", "slot_id = %d" % _current_slot)
	for module_name in _modules.keys():
		var obj: Object = _modules[module_name]
		if obj and obj.has_method("get_save_data"):
			var data: Dictionary = obj.call("get_save_data")
			_db.insert_row("legacy_modules", {
				"slot_id": _current_slot,
				"module_name": module_name,
				"data": JSON.stringify(data),
			})


## 旧接口模块：从 legacy_modules 读，调 load_save_data()
func _load_legacy_modules() -> void:
	for module_name in _modules.keys():
		var obj: Object = _modules[module_name]
		if obj and obj.has_method("load_save_data"):
			var rows: Array = _db.select_rows("legacy_modules",
				"slot_id = %d AND module_name = '%s'" % [_current_slot, module_name], ["data"])
			var data: Dictionary = {}
			if not rows.is_empty():
				var parsed = JSON.parse_string(str(rows[0]["data"]))
				if typeof(parsed) == TYPE_DICTIONARY:
					data = parsed
			obj.call("load_save_data", data)


func _accumulate_playtime() -> float:
	if _start_time == 0.0:
		_start_time = Time.get_unix_time_from_system()
		return 0.0
	return Time.get_unix_time_from_system() - _start_time
