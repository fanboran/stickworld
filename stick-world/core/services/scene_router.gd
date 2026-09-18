class_name SceneRouter
extends RefCounted
## L0 场景路由表 —— 低层进高层场景的路径出口（依赖倒置）。
##
## 主菜单/载入屏（ui_global，L1）要把玩家送进组合根场景 game_root（world，L3），
## 但低层不允许硬编码高层模块路径（上行依赖，且属 audit_deps 的字符串扫描盲区）。
## 场景路径是装配数据：外置路由表 JSON，低层按 id 取用——代码依赖只剩
## ui_global→core（L1→L0，合法方向）；world 场景挪位只改 JSON，不动低层代码。
##
## 路由表：res://assets/config/scene_routes.json（条目与用途见该文件）。

const ROUTES_PATH := "res://assets/config/scene_routes.json"

static var _routes: Dictionary = {}


## 取单条路由（场景/资源路径）。id 未登记、或路径在包内不存在时报错并返回
## 空串——配置漂移显性化：宁可启动即红，不带病进切场景。
static func route(id: StringName) -> String:
	var table := _load_table()
	if not table.has(id):
		push_error("SceneRouter: 路由 %s 未登记于 %s" % [id, ROUTES_PATH])
		return ""
	var path := str(table[id])
	if not _path_valid(path):
		push_error("SceneRouter: 路由 %s -> %s 不存在（scene_routes.json 与目标文件是否同步挪动？）" % [id, path])
		return ""
	return path


## 取列表型路由（如启动预热的扫描起点清单），逐条校验、坏条目跳过并报错。
static func route_list(id: StringName) -> PackedStringArray:
	var out := PackedStringArray()
	var table := _load_table()
	if not table.has(id):
		push_error("SceneRouter: 路由 %s 未登记于 %s" % [id, ROUTES_PATH])
		return out
	if table[id] is not Array:
		push_error("SceneRouter: 路由 %s 应为列表（scene_routes.json）" % [id])
		return out
	for item in table[id]:
		var path := str(item)
		if not _path_valid(path):
			push_error("SceneRouter: 路由 %s 条目 %s 不存在" % [id, path])
			continue
		out.append(path)
	return out


## 清空路由表缓存（测试注入/热重载用；生产路径无调用方）。
static func clear_cache() -> void:
	_routes = {}


static func _path_valid(path: String) -> bool:
	return path.begins_with("res://") and ResourceLoader.exists(path)


static func _load_table() -> Dictionary:
	if not _routes.is_empty():
		return _routes
	if not FileAccess.file_exists(ROUTES_PATH):
		push_error("SceneRouter: 路由表缺失 %s" % ROUTES_PATH)
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(ROUTES_PATH))
	if parsed is Dictionary:
		_routes = parsed
	else:
		push_error("SceneRouter: 路由表 %s 解析失败（须为 JSON 对象）" % ROUTES_PATH)
	return _routes
