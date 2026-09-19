class_name KeymapLayout
extends RefCounted
## 键盘布局装载器 —— keyboard_layouts.json（unit 宽度行式布局，KLE 格式子集）→ 键矩形表。
##
## 纯逻辑无场景树依赖（unit 批准入）。行内自动前进：{"c":键名,"l":键帽刻字,"w":宽(默认1u),
## "h":高(默认1u)}，{"g":间距} 跳位；行自带 y（功能行与主键区留 0.5u 视觉分隔）。
## 键名解析见 resolve_key（单字符直取 ASCII + OS.find_keycode_from_string + 覆盖表）。

const LAYOUTS_PATH := "res://modules/ui_global/data/keymap/keyboard_layouts.json"

## 键名解析委托 L0 装载器（单字符 ASCII + 覆盖表 + find_keycode_from_string，
## 与输入绑定共用同一张解析表）。
const InputBindingsScript := preload("res://core/autoload/input_bindings.gd")

static var _cache: Array[Dictionary] = []


## 键名 → Godot Key 枚举值；解析失败返回 KEY_NONE（=0）。
static func resolve_key(code: String) -> int:
	return InputBindingsScript.resolve_key(code)


## 装载 ANSI 104 布局为键矩形表：[{code:int, legend:String, x:float, y:float, w:float, h:float}]。
## 坐标单位 = 1u（一个标准键距）。缓存共享（静态数据）。
static func load_ansi104() -> Array[Dictionary]:
	if not _cache.is_empty():
		return _cache
	var parsed: Dictionary = _parse_json(LAYOUTS_PATH)
	if parsed.is_empty() or not parsed.has("ansi104"):
		push_error("[KeymapLayout] 布局文件缺失或无 ansi104 段: %s" % LAYOUTS_PATH)
		return []
	var layout: Dictionary = parsed["ansi104"]
	var keys: Array[Dictionary] = []
	for row: Dictionary in layout.get("rows", []):
		var y: float = float(row.get("y", 0.0))
		var cursor: float = 0.0
		for entry: Dictionary in row.get("keys", []):
			if entry.has("g"):
				cursor += float(entry["g"])
				continue
			var code: int = resolve_key(String(entry.get("c", "")))
			keys.append({
				"code": code,
				"legend": String(entry.get("l", entry.get("c", ""))),
				"x": cursor, "y": y,
				"w": float(entry.get("w", 1.0)),
				"h": float(entry.get("h", 1.0)),
			})
			cursor += float(entry.get("w", 1.0))
	_cache = keys
	return keys


## 布局总尺寸（单位 u）：[23.0, 6.5]，取自数据文件的 units 段（与键矩形一致性的
## 校验由 unit 测试负责，这里只回读声明值）。
static func declared_units() -> Vector2:
	var parsed: Dictionary = _parse_json(LAYOUTS_PATH)
	var units: Array = parsed.get("ansi104", {}).get("units", [23.0, 6.5])
	return Vector2(float(units[0]), float(units[1]))


static func _parse_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[KeymapLayout] 打不开布局文件: %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed == null or not (parsed is Dictionary):
		push_error("[KeymapLayout] 布局 JSON 解析失败: %s" % path)
		return {}
	return parsed
