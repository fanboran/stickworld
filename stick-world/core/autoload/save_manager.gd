extends Node
## 游戏存档管理。
##
## 多存档槽位（slot 0..N-1），保存为 JSON 文件 user://saves/save_<slot>.json。
## 数据来自注册的"数据提供者"对象——它们实现 get_save_data() -> Dictionary
## 和 load_save_data(data: Dictionary) -> void。

const SLOT_COUNT := 5
const SAVE_DIR := "user://saves"

# 模块注册表：module_name -> 对象
var _modules: Dictionary = {}

var _auto_save_timer: float = 0.0
var _auto_save_slot: int = 0
var _auto_save_enabled: bool = true
var _start_time: float = 0.0


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	# 确保保存目录存在
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


# ─────────────────────────────── 存档操作 ────────────────────────────────

func save_game(slot_index: int) -> bool:
	if slot_index < 0 or slot_index >= SLOT_COUNT:
		push_warning("[SaveManager] 存档槽越界: %d" % slot_index)
		return false

	EventBus.game_saving.emit(slot_index)

	var modules_data: Dictionary = {}
	for module_name in _modules.keys():
		var obj: Object = _modules[module_name]
		if obj and obj.has_method("get_save_data"):
			modules_data[module_name] = obj.call("get_save_data")

	var payload: Dictionary = {
		"version": 1,
		"timestamp": Time.get_unix_time_from_system(),
		"datetime": Time.get_date_string_from_system() + " " + Time.get_time_string_from_system(),
		"playtime_seconds": _accumulate_playtime(),
		"modules": modules_data,
	}

	var path: String = _slot_path(slot_index)
	var file = FileAccess.open(path, FileAccess.WRITE)
	if not file:
		push_warning("[SaveManager] 无法写入存档: %s" % path)
		return false
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()

	EventBus.game_saved.emit(slot_index)
	return true


func load_game(slot_index: int) -> bool:
	if slot_index < 0 or slot_index >= SLOT_COUNT:
		push_warning("[SaveManager] 存档槽越界: %d" % slot_index)
		return false

	var path: String = _slot_path(slot_index)
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		push_warning("[SaveManager] 存档不存在: %s" % path)
		return false

	var text: String = file.get_as_text()
	file.close()

	var parsed = JSON.parse_string(text)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[SaveManager] 存档解析失败: %s" % path)
		return false

	var payload: Dictionary = parsed

	# 分发给各模块
	var modules_data: Dictionary = payload.get("modules", {})
	if typeof(modules_data) != TYPE_DICTIONARY:
		modules_data = {}
	for module_name in _modules.keys():
		var obj: Object = _modules[module_name]
		if obj and obj.has_method("load_save_data"):
			if modules_data.has(module_name):
				obj.call("load_save_data", modules_data[module_name])
			else:
				obj.call("load_save_data", {})

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
	if not slot_exists(slot_index):
		return info
	var path: String = _slot_path(slot_index)
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		return info
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		return info
	var d: Dictionary = parsed
	info["exists"] = true
	info["datetime"] = str(d.get("datetime", ""))
	info["playtime_seconds"] = int(d.get("playtime_seconds", 0))
	info["version"] = int(d.get("version", 0))
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


# ─────────────────────────────── 内部方法 ───────────────────────────────

func _slot_path(slot_index: int) -> String:
	return "%s/save_%d.json" % [SAVE_DIR, slot_index]


func _accumulate_playtime() -> float:
	if _start_time == 0.0:
		_start_time = Time.get_unix_time_from_system()
		return 0.0
	return Time.get_unix_time_from_system() - _start_time
