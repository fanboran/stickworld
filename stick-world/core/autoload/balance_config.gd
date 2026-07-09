extends Node
## 热加载平衡变量 —— 从 config/ 目录加载 .tres 资源。
##
## 数据来源：Excel 导出管线（config/excel/*.xlsx → config/**/*.tres）。
## 每个 .tres 对应一张 Excel Sheet，由 BalanceResource 承载。
## 提供平衡变量的统一读取入口 get_value(path)。
## 支持热加载：编辑 .tres 后调用 reload() 无需重启游戏。
## 变量变更时通过 EventBus 发射 balance_changed 信号。

# ─────────────────────────────── 数据 ───────────────────────────────────

## 所有平衡变量缓存。
## key 格式：
##   - 类型路径 → 行数组（如 "units.stickmen" → Array[Dictionary]）
##   - 类型路径.行ID → 行字典（如 "units.stickmen.stm_plain_001" → Dictionary）
var data: Dictionary = {}

## 所有已知的类型路径，用于 get_value() 解析点号路径。
var _type_paths: Array[String] = []


# ─────────────────────────────── 读取 ───────────────────────────────────

## 根据路径读取平衡变量值。
## path 格式：点号分隔，如 "units.stickmen.stm_plain_001.base_hp"。
## 也支持 "units.stickmen"（返回行数组）或 "units.stickmen.stm_plain_001"（返回行字典）。
## 路径不存在时返回 null 并打印警告。
func get_value(path: String) -> Variant:
	# 直接命中（类型路径或行路径）
	if data.has(path):
		return data[path]

	# 解析 type_path.row_id.field 格式
	var parts := path.split(".")
	# 从长到短尝试类型路径匹配
	for i in range(parts.size() - 1, 0, -1):
		var candidate_type := ".".join(parts.slice(0, i))
		if _type_paths.has(candidate_type):
			var row_id := parts[i]
			var row_key := candidate_type + "." + row_id
			if not data.has(row_key):
				push_warning("[BalanceConfig] 行 '%s' 在类型 '%s' 中不存在" % [row_id, candidate_type])
				return null

			var row_dict: Dictionary = data[row_key]
			if i + 1 >= parts.size():
				return row_dict

			# 嵌套字段访问：如 base_hp 或 nested.field.path
			var field_path := ".".join(parts.slice(i + 1))
			var result = _navigate_dict(row_dict, field_path)
			if result == null and not _dict_has_path(row_dict, field_path):
				push_warning("[BalanceConfig] 字段 '%s' 在行 '%s' 中不存在" % [field_path, row_key])
			return result

	push_warning("[BalanceConfig] 路径 '%s' 不存在" % path)
	return null


## 返回指定类型的所有行数据数组。
## 如 get_all_of_type("units.stickmen") 返回所有火柴人数据。
func get_all_of_type(type_path: String) -> Array:
	if data.has(type_path):
		return data[type_path]
	push_warning("[BalanceConfig] 类型路径 '%s' 不存在" % type_path)
	return []


# ─────────────────────────────── 热加载 ────────────────────────────────

## 扫描 config/ 目录下所有 .tres 文件（包括子目录），加载并合并到 data。
## 路径规则：config/units/stickmen.tres → 类型路径 "units.stickmen"。
## 加载完成后通过 EventBus 发射 balance_changed 信号。
func reload() -> void:
	data.clear()
	_type_paths.clear()

	_scan_and_load_dir("res://config", "")

	EventBus.safe_emit("balance_changed")


## 热重载单个 .tres 文件。
## file_path: 相对于 config/ 的路径，如 "units/stickmen.tres"。
## 适用于仅修改了某张 Excel 后重新导出对应 .tres 的场景。
func reload_single(file_path: String) -> void:
	var full_path := "res://config/" + file_path
	if not ResourceLoader.exists(full_path):
		push_error("[BalanceConfig] 文件不存在: %s" % full_path)
		return

	var type_path := _file_path_to_type_path(file_path)

	# 移除旧数据
	_remove_type_data(type_path)

	# 加载新数据
	_load_tres(full_path, type_path)

	EventBus.safe_emit("balance_changed")


# ─────────────────────────────── 内部方法 ────────────────────────────────

## 递归扫描目录并加载所有 .tres 文件。
func _scan_and_load_dir(dir_path: String, relative_prefix: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_error("[BalanceConfig] 无法打开目录: %s" % dir_path)
		return

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name.begins_with("."):
			file_name = dir.get_next()
			continue

		var full_path := dir_path + "/" + file_name
		if dir.current_is_dir():
			_scan_and_load_dir(full_path, relative_prefix + file_name + ".")
		elif file_name.ends_with(".tres"):
			var type_path := relative_prefix + file_name.trim_suffix(".tres")
			_load_tres(full_path, type_path)

		file_name = dir.get_next()
	dir.list_dir_end()


## 加载单个 .tres 文件并合并到 data。
func _load_tres(full_path: String, type_path: String) -> void:
	var res: Resource = load(full_path)
	if res == null:
		push_error("[BalanceConfig] 加载失败: %s" % full_path)
		return

	if not res is BalanceResource:
		push_warning("[BalanceConfig] 资源不是 BalanceResource 类型: %s" % full_path)
		return

	var balance_res: BalanceResource = res as BalanceResource
	var rows: Array = balance_res.variables.get("data", [])

	# 存储类型路径 → 行数组
	data[type_path] = rows
	_type_paths.append(type_path)

	# 存储每行数据：类型路径.行ID → 行字典
	for row in rows:
		if row is Dictionary and row.has("id"):
			var row_key := type_path + "." + str(row["id"])
			data[row_key] = row


## 从 data 中移除指定类型路径的所有数据（用于重载前清理）。
func _remove_type_data(type_path: String) -> void:
	data.erase(type_path)
	_type_paths.erase(type_path)

	var keys_to_remove: Array[String] = []
	for key in data:
		if key.begins_with(type_path + "."):
			keys_to_remove.append(key)
	for key in keys_to_remove:
		data.erase(key)


## 将文件路径转换为类型路径。
## "units/stickmen.tres" → "units.stickmen"
func _file_path_to_type_path(file_path: String) -> String:
	var path := file_path.trim_suffix(".tres")
	path = path.replace("/", ".")
	return path


## 在 Dictionary 中按点号路径导航，返回最终值。
## 如 _navigate_dict({"a": {"b": 1}}, "a.b") → 1
func _navigate_dict(dict: Dictionary, path: String) -> Variant:
	var parts := path.split(".")
	var current: Variant = dict
	for part in parts:
		if current is Dictionary and (current as Dictionary).has(part):
			current = (current as Dictionary)[part]
		else:
			return null
	return current


## 检查 Dictionary 中是否存在点号路径。
func _dict_has_path(dict: Dictionary, path: String) -> bool:
	var parts := path.split(".")
	var current: Variant = dict
	for part in parts:
		if current is Dictionary and (current as Dictionary).has(part):
			current = (current as Dictionary)[part]
		else:
			return false
	return true