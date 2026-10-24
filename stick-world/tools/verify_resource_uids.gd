# verify_resource_uids.gd — 场景/资源 UID 补齐后的引擎侧自验收（backfill_resource_uids.py --verify-godot 调用）
# 用法: godot --headless --path <res://根> --script tools/verify_resource_uids.gd
# 校验（引擎视角，python 文本校验之外的地面真相）:
#   1. res:// 下全部 .tscn/.tres（排除第三方/submodule）头部均有 uid
#   2. uid 全局零重复（uid_cache 是 uid->path 唯一映射，重复会让先登记方 CACHE-MISMATCH）
#   3. 每个文件头 uid 与 ResourceLoader.get_resource_uid(path) 精确一致（缓存重建正确）
#   4. 所有 ext_resource 携带的 uid 都已登记且指向声明的 path（无悬空/无错位）
# 任一失败 printerr 并退出码 1。
extends SceneTree

const EXCLUDE_PREFIXES: PackedStringArray = ["res://addons/godot-sqlite", "res://config/strategic_map"]
const HEADER_RE := "uid=\"(uid://[0-9A-Za-z]+)\""
const EXT_RE := "\\[ext_resource[^\\]]*uid=\"(uid://[0-9A-Za-z]+)\"[^\\]]*path=\"([^\"]+)\""


func _init() -> void:
	var missing := 0
	var errors := 0
	var seen := {}  # uid_text -> path
	var header_re := RegEx.create_from_string(HEADER_RE)
	var ext_re := RegEx.create_from_string(EXT_RE)

	for path in _walk("res://"):
		if not (path.ends_with(".tscn") or path.ends_with(".tres")):
			continue
		if _excluded(path):
			continue
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			printerr("OPEN-FAIL: ", path)
			errors += 1
			continue
		var first := f.get_line()
		var body := f.get_as_text()
		f.close()

		var m := header_re.search(first)
		var uid_text := m.get_string(1) if m else ""
		if uid_text == "":
			printerr("MISSING-UID: ", path)
			missing += 1
			continue
		if seen.has(uid_text):
			printerr("DUPLICATE: ", uid_text, " -> ", path, " 与 ", seen[uid_text])
			errors += 1
		seen[uid_text] = path

		var id: int = ResourceUID.text_to_id(uid_text)
		var cache_id: int = ResourceLoader.get_resource_uid(path)
		if cache_id != id:
			var cache_text := ResourceUID.id_to_text(cache_id) if cache_id != ResourceUID.INVALID_ID else "INVALID"
			printerr("CACHE-MISMATCH: ", path, " header=", uid_text, " cache=", cache_text)
			errors += 1

		for em in ext_re.search_all(body):
			var euid := em.get_string(1)
			var epath := em.get_string(2)
			if not ResourceUID.has_id(ResourceUID.text_to_id(euid)):
				printerr("EXT-DANGLING: ", path, " 引用 ", euid, " 未登记")
				errors += 1
			else:
				var resolved := ResourceUID.get_id_path(ResourceUID.text_to_id(euid))
				if resolved != epath:
					printerr("EXT-MISMATCH: ", path, " 引用 ", euid, " 声明 ", epath, " 实际 ", resolved)
					errors += 1

	print("VERIFY-SUMMARY files=%d missing=%d errors=%d" % [seen.size() + missing, missing, errors])
	quit(1 if (errors > 0 or missing > 0) else 0)


func _excluded(path: String) -> bool:
	for p in EXCLUDE_PREFIXES:
		if path.begins_with(p + "/") or path == p:
			return true
	return false


func _walk(dir_path: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var p := dir_path.path_join(name)
		if dir.current_is_dir():
			if not _excluded(p):
				out.append_array(_walk(p))
		else:
			out.append(p)
		name = dir.get_next()
	return out
