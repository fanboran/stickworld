class_name KeyBindingRegistry
extends RefCounted
## 键鼠按键注册表（展示层索引）—— 数据源 = assets/config/input_actions.json
## （经 L0 的 InputBindings 装载，键鼠说明图/提示文案从这里取标注）。
##
## 该 JSON 同时是**按键绑定的单一真相源**：InputBindings 启动时把动作注册进引擎
## InputMap，代码侧 event.is_action_pressed(...) 查动作名；本类只做展示侧的
## 「键 → 功能标注」反查与域过滤/冲突检测，不改绑定。
##
## 数据形状：{domains:[{id,title,color}], actions:[{action,domain,label,note,binds}]}
## bind 三形态：{"physical": "W"}（位置语义）/ {"key": "S", "mods": ["CTRL"]}（标签
## 语义）/ {"mouse": "LEFT"}。color 取 StickTokens.CONTENT_PALETTE_NAMES 的内容色 id。

const InputBindingsScript := preload("res://core/autoload/input_bindings.gd")

## 鼠标名 → MouseButton（委托 L0 装载器的同一张表）
const MOUSE_IDS: Dictionary = InputBindingsScript.MOUSE_IDS


## 装载注册表（缓存共享，经 InputBindings 静态装载）。结构异常返回空字典。
static func load_default() -> Dictionary:
	return InputBindingsScript.data()


## 键名解析（委托 L0：单字符 ASCII + 覆盖表 + find_keycode_from_string）。
static func resolve_key(code: String) -> int:
	return InputBindingsScript.resolve_key(code)


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


## 键标注反查表：Key 枚举值 -> Array[{label,note,domain,mods?}]。
## domains 非空时只收该域集合的标注（域过滤）；鼠标绑定不进键表。
## 同一动作的多键绑定（如 1 与 KP_1）会各自落键。
static func key_index(data: Dictionary, domains: PackedStringArray = PackedStringArray()) -> Dictionary:
	return _build_index(data, domains, false)


## 鼠标标注反查表：MouseButton 枚举值 -> Array[{label,note,domain}]。
static func mouse_index(data: Dictionary, domains: PackedStringArray = PackedStringArray()) -> Dictionary:
	return _build_index(data, domains, true)


## 同域同键绑多个动作 = 冲突（跨域同键是本项目的模式态常态，不算冲突；
## 同一动作的多键绑定不算）。返回 [{"kind","code","domain","labels"}]；空 = 无冲突。
static func find_conflicts(data: Dictionary) -> Array[Dictionary]:
	var seen: Dictionary = {}
	var out: Array[Dictionary] = []
	for a: Dictionary in data.get("actions", []):
		var domain: String = String(a.get("domain", ""))
		for bind: Dictionary in a.get("binds", []):
			var is_mouse: bool = bind.has("mouse")
			var code: int = resolve_key(String(bind.get("key", bind.get("physical", "")))) if not is_mouse \
					else InputBindingsScript.mouse_id(String(bind.get("mouse", "")))
			if code == 0:
				continue
			var slot: String = "%s:%d:%s" % ["mouse" if is_mouse else "key", code, domain]
			if seen.has(slot):
				var entry: Dictionary = seen[slot]
				if not entry["labels"].has(a["label"]):
					entry["labels"].append(a["label"])
			else:
				seen[slot] = {
					"kind": "mouse" if is_mouse else "key",
					"code": code,
					"domain": domain,
					"labels": [a["label"]],
				}
	for slot: String in seen:
		var entry: Dictionary = seen[slot]
		if entry["labels"].size() > 1:
			out.append(entry)
	return out


## 动作名 → 中文标注（未知返回空串）。
static func action_label(action: String) -> String:
	return String(InputBindingsScript.action_meta(action).get("label", ""))


## 动作名 → 首个绑定的展示键名（"F" / "Ctrl+S" / "左键"；未知返回空串）。
static func action_key_hint(action: String) -> String:
	return InputBindingsScript.action_key_hint(action)


static func _build_index(data: Dictionary, domains: PackedStringArray, mouse: bool) -> Dictionary:
	var out: Dictionary = {}
	var want_domain: bool = not domains.is_empty()
	for a: Dictionary in data.get("actions", []):
		if want_domain and not domains.has(String(a.get("domain", ""))):
			continue
		for bind: Dictionary in a.get("binds", []):
			var code: int = 0
			if mouse:
				if not bind.has("mouse"):
					continue
				code = InputBindingsScript.mouse_id(String(bind["mouse"]))
			else:
				if bind.has("mouse"):
					continue
				code = resolve_key(String(bind.get("key", bind.get("physical", ""))))
			if code == 0:
				push_warning("[KeyBindingRegistry] 解析失败的绑定: %s / %s" % [a.get("action", ""), bind])
				continue
			var item: Dictionary = {
				"label": String(a.get("label", "")),
				"note": String(a.get("note", "")),
				"domain": String(a.get("domain", "")),
				"action": String(a.get("action", "")),
			}
			if bind.has("mods"):
				var mods: PackedStringArray = PackedStringArray()
				for m: String in bind["mods"]:
					mods.append(m)
				item["mods"] = mods
			if not out.has(code):
				out[code] = []
			(out[code] as Array).append(item)
	return out
