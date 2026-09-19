class_name KeyBindingRegistry
extends RefCounted
## 键鼠按键注册表 —— key_bindings.json 的装载与索引（纯逻辑无场景树依赖，unit 批准入）。
##
## 本项目无 InputMap（按键硬编码散布在 _input/_unhandled_input 的 keycode 比较里），
## 本表是按键→功能标注的集中登记：键鼠说明图、开局提示等展示层都从这里取数。
## **改按键时须同步本表**（漂移防护：把新增 keycode 比较登记进来，测试只保数据自洽）。
##
## 数据形状：{"domains":[{id,title,color}], "bindings":[{key|mouse, mods?, domain, label, note}]}
## color 取 StickTokens.CONTENT_PALETTE_NAMES 的内容色 id（展示层换算，本层只存字符串）。

const BINDINGS_PATH := "res://modules/ui_global/data/keymap/key_bindings.json"

## 鼠标按钮名 → Godot MouseButton 枚举值
const MOUSE_IDS: Dictionary = {
	"LEFT": MOUSE_BUTTON_LEFT,
	"RIGHT": MOUSE_BUTTON_RIGHT,
	"MIDDLE": MOUSE_BUTTON_MIDDLE,
	"WHEEL_UP": MOUSE_BUTTON_WHEEL_UP,
	"WHEEL_DOWN": MOUSE_BUTTON_WHEEL_DOWN,
	"XBUTTON1": MOUSE_BUTTON_XBUTTON1,
	"XBUTTON2": MOUSE_BUTTON_XBUTTON2,
}

static var _cache: Dictionary = {}


## 装载注册表（缓存共享）。结构异常返回空字典。
static func load_default() -> Dictionary:
	if not _cache.is_empty():
		return _cache
	var f := FileAccess.open(BINDINGS_PATH, FileAccess.READ)
	if f == null:
		push_error("[KeyBindingRegistry] 打不开注册表: %s" % BINDINGS_PATH)
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed == null or not (parsed is Dictionary) \
			or not (parsed as Dictionary).has("domains") \
			or not (parsed as Dictionary).has("bindings"):
		push_error("[KeyBindingRegistry] 注册表 JSON 结构不符: %s" % BINDINGS_PATH)
		return {}
	_cache = parsed
	return _cache


## 键名解析（委托 KeymapLayout.resolve_key：单字符 ASCII + 覆盖表 + find_keycode_from_string）。
static func resolve_key(code: String) -> int:
	return KeymapLayout.resolve_key(code)


## 域表 [{id,title,color}]；数据缺域返回空数组。
static func domains(data: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for d: Dictionary in data.get("domains", []):
		out.append(d)
	return out


## 域 id → title（未知域回退原始 id）。
static func domain_title(data: Dictionary, domain_id: String) -> String:
	for d: Dictionary in data.get("domains", []):
		if String(d.get("id", "")) == domain_id:
			return String(d.get("title", domain_id))
	return domain_id


## 域 id → 内容色 id（未知域回退 "amber"）。
static func domain_color_id(data: Dictionary, domain_id: String) -> StringName:
	for d: Dictionary in data.get("domains", []):
		if String(d.get("id", "")) == domain_id:
			return StringName(String(d.get("color", "amber")))
	return &"amber"


## 键标注反查表：Key 枚举值 -> Array[{label,note,domain,mods}]。
## domains 非空时只收该域集合的标注（域过滤）；鼠标绑定不进键表。
static func key_index(data: Dictionary, domains: PackedStringArray = PackedStringArray()) -> Dictionary:
	return _build_index(data, domains, "key", func(b: Dictionary) -> int:
		return resolve_key(String(b.get("key", ""))))


## 鼠标标注反查表：MouseButton 枚举值 -> Array[{label,note,domain}]。
static func mouse_index(data: Dictionary, domains: PackedStringArray = PackedStringArray()) -> Dictionary:
	return _build_index(data, domains, "mouse", func(b: Dictionary) -> int:
		return int(MOUSE_IDS.get(String(b.get("mouse", "")), 0)))


## 同域同键绑多个不同功能 = 冲突（跨域同键是本项目的模式态常态，不算冲突）。
## 返回 [{"key"|"mouse", "domain", "labels":[]}]；空 = 无冲突。
static func find_conflicts(data: Dictionary) -> Array[Dictionary]:
	var seen: Dictionary = {}
	var out: Array[Dictionary] = []
	for b: Dictionary in data.get("bindings", []):
		var is_key: bool = b.has("key")
		var code: int = resolve_key(String(b.get("key", ""))) if is_key \
				else int(MOUSE_IDS.get(String(b.get("mouse", "")), 0))
		if code == 0:
			continue
		var domain: String = String(b.get("domain", ""))
		var slot: String = "%s:%d:%s" % ["key" if is_key else "mouse", code, domain]
		if seen.has(slot):
			var entry: Dictionary = seen[slot]
			if not entry["labels"].has(b["label"]):
				entry["labels"].append(b["label"])
		else:
			seen[slot] = {
				"kind": "key" if is_key else "mouse",
				"code": code,
				"domain": domain,
				"labels": [b["label"]],
			}
	for slot: String in seen:
		var entry: Dictionary = seen[slot]
		if entry["labels"].size() > 1:
			out.append(entry)
	return out


static func _build_index(data: Dictionary, domains: PackedStringArray, field: String,
		resolver: Callable) -> Dictionary:
	var out: Dictionary = {}
	var want_domain: bool = not domains.is_empty()
	for b: Dictionary in data.get("bindings", []):
		if not b.has(field):
			continue
		if want_domain and not domains.has(String(b.get("domain", ""))):
			continue
		var code: int = int(resolver.call(b))
		if code == 0:
			push_warning("[KeyBindingRegistry] 解析失败的%s名: %s" % [field, b.get(field)])
			continue
		var item: Dictionary = {
			"label": String(b.get("label", "")),
			"note": String(b.get("note", "")),
			"domain": String(b.get("domain", "")),
		}
		if b.has("mods"):
			var mods: PackedStringArray = PackedStringArray()
			for m: String in b["mods"]:
				mods.append(m)
			item["mods"] = mods
		if not out.has(code):
			out[code] = []
		(out[code] as Array).append(item)
	return out
