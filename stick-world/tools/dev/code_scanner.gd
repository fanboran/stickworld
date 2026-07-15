extends SceneTree

## 代码扫描器：检查项目中所有 .gd 文件的语法和基本质量问题
## 使用方式: godot --headless --path <project_dir> -s res://tools/dev/code_scanner.gd
## 退出码: 0 = 无问题, >0 = 有问题

const SCAN_DIRS := ["modules", "core", "tests", "tools"]
const EXCLUDE_DIRS := ["addons/"]

var issues_found: int = 0
var files_scanned: int = 0
var total_lines: int = 0

func _initialize() -> void:
	print("=".repeat(60))
	print("GDScript 代码扫描器")
	print("=".repeat(60))
	print("")

	var all_files: Array = collect_gd_files()
	print("发现 %d 个 .gd 文件" % all_files.size())
	print("")

	for file_path in all_files:
		scan_file(file_path)

	print("")
	print("=".repeat(60))
	print("扫描完成")
	print("  文件数: %d" % files_scanned)
	print("  代码行数: %d" % total_lines)
	print("  问题数: %d" % issues_found)
	print("=".repeat(60))

	if issues_found > 0:
		push_error("扫描发现 %d 个问题，CI 失败" % issues_found)
		quit(1)
	else:
		print("全部文件通过检查")
		quit(0)


func collect_gd_files() -> Array:
	var files: Array = []
	for dir_name in SCAN_DIRS:
		if not DirAccess.dir_exists_absolute("res://" + dir_name):
			continue
		scan_directory("res://" + dir_name, files)
	return files


func scan_directory(dir_path: String, out_files: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		var full_path: String = dir_path + "/" + file_name
		if file_name == "." or file_name == "..":
			file_name = dir.get_next()
			continue
		var is_excluded: bool = false
		for ex in EXCLUDE_DIRS:
			if full_path.find("res://" + ex) != -1:
				is_excluded = true
				break
		if is_excluded:
			file_name = dir.get_next()
			continue
		if dir.current_is_dir():
			scan_directory(full_path, out_files)
		elif file_name.ends_with(".gd"):
			out_files.append(full_path)
		file_name = dir.get_next()
	dir.list_dir_end()


func scan_file(file_path: String) -> void:
	files_scanned += 1

	var file := FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		print("无法打开: %s" % file_path)
		issues_found += 1
		return

	var source: String = file.get_as_text()
	file.close()

	var lines: PackedStringArray = source.split("\n")
	total_lines += lines.size()

	var parse_errors: int = check_syntax(file_path, source)
	issues_found += parse_errors

	var line_no: int = 0
	for line in lines:
		line_no += 1
		var trimmed: String = line.strip_edges()
		if trimmed.begins_with("print(") and not trimmed.begins_with("print_rich"):
			print("  ⚠️  %s:%d  调试残留 print()" % [file_path, line_no])
			issues_found += 1
		if trimmed.find("TODO") != -1 and trimmed.length() < 12:
			print("  ⚠️  %s:%d  TODO 没有说明文字" % [file_path, line_no])
			issues_found += 1
		if trimmed.find("FIXME") != -1 and trimmed.length() < 14:
			print("  ⚠️  %s:%d  FIXME 没有说明文字" % [file_path, line_no])
			issues_found += 1
		if line.length() > 160:
			print("  ℹ️  %s:%d  行过长 (%d 字符，建议 <160)" % [file_path, line_no, line.length()])

	if parse_errors == 0:
		print("  ✅ %s  (%d 行)" % [file_path, lines.size()])
	else:
		print("  ❌ %s  (%d 行, %d 个语法问题)" % [file_path, lines.size(), parse_errors])


func check_syntax(file_path: String, source: String) -> int:
	var script := GDScript.new()
	script.source_code = source
	script.resource_path = file_path
	var err: Error = script.reload()
	if err != OK:
		print("  ❌ %s  语法错误 (Error: %d)" % [file_path, err])
		return 1
	return 0
