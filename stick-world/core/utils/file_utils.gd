class_name FileUtils

## 安全读取文本文件内容（文件不存在或读取失败时返回空字符串）
static func read_text_file(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		push_error("[FileUtils] 无法读取: ", path)
		return ""
	var text := file.get_as_text()
	file.close()
	return text

## 原子化写入文本文件（先写 .tmp 临时文件再重命名，防止写入中断导致文件损坏）
static func atomic_write_text(path: String, text: String) -> bool:
	var dir_path := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)
	var temp := path + ".tmp"
	var file := FileAccess.open(temp, FileAccess.WRITE)
	if not file:
		push_error("[FileUtils] 无法写入: ", temp)
		return false
	file.store_string(text)
	file.close()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	DirAccess.rename_absolute(temp, path)
	return true

## 多级回退查找文件路径（user:// → 编辑器全局路径 → EXE同目录）
## 用于导出后资源定位：先查缓存，再查编辑器路径，最后查EXE旁
static func resolve_file_path(res_path: String) -> String:
	var file_name := res_path.get_file()
	var user_path := "user://" + file_name
	if FileAccess.file_exists(user_path):
		return ProjectSettings.globalize_path(user_path)
	if OS.has_feature("editor"):
		var global_path := ProjectSettings.globalize_path(res_path)
		if FileAccess.file_exists(global_path):
			return global_path
	var exe_dir := OS.get_executable_path().get_base_dir()
	var local_path := exe_dir.path_join(file_name)
	if FileAccess.file_exists(local_path):
		return local_path
	return ""

## 从 res:// 提取资源并缓存到 user:// 目录（用于导出后需要文件路径的场景，如托盘图标）
static func extract_resource_to_user(res_path: String) -> String:
	var file_name := res_path.get_file()
	var user_path := "user://" + file_name
	var file := FileAccess.open(res_path, FileAccess.READ)
	if not file:
		push_error("[FileUtils] 无法读取资源: ", res_path)
		return ""
	var data := file.get_buffer(file.get_length())
	file.close()
	DirAccess.make_dir_recursive_absolute(OS.get_user_data_dir())
	var out := FileAccess.open(user_path, FileAccess.WRITE)
	if not out:
		push_error("[FileUtils] 无法写入临时文件: ", user_path)
		return ""
	out.store_buffer(data)
	out.close()
	return ProjectSettings.globalize_path(user_path)

## 安全加载并解析 JSON 文件（解析失败时返回空字典）
static func load_json(path: String) -> Dictionary:
	var text := read_text_file(path)
	if text.is_empty():
		return {}
	var parsed := JSON.new()
	var err := parsed.parse(text)
	if err != OK:
		push_error("[FileUtils] JSON解析错误: ", err)
		return {}
	return parsed.data as Dictionary

## 将字典序列化并以原子写入方式保存为 JSON 文件
static func save_json(path: String, data: Dictionary, indent: String = "\t") -> bool:
	return atomic_write_text(path, JSON.stringify(data, indent))
