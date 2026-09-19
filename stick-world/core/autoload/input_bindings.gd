extends Node
## InputBindings（L0 自动加载）—— 按键绑定的单一真相源装载器。
## 无 class_name（与 autoload 同名会 Parse Error；静态方法经 preload 调用，
## 运行时实例经单例名 InputBindings 访问）。
##
## 数据 = assets/config/input_actions.json（域/动作/标注/绑定）；启动时把全部动作
## 注册进引擎 InputMap，代码侧一律 event.is_action_pressed(...) / Input.is_action_pressed(...)
## 查询动作名，不再裸比较键码。展示层（键鼠说明图/提示文案）从同一份 JSON 取标注。
##
## 绑定语义（三种 bind 形态）：
##   {"physical": "W"}    位置语义（玩法键：WASD/QEZ/数字行/非字符键…）
##                         → InputEventKey.physical_keycode，非美式布局（AZERTY 等）按位置命中
##   {"key": "S", "mods": ["CTRL"]}  标签语义（带修饰键的快捷键）
##                         → InputEventKey.keycode + 修饰键状态
##   {"mouse": "LEFT"}     鼠标键 → InputEventMouseButton
##
## ESC 例外：模态栈逐层退栈语义分散在多个控制器，保持裸键码比较（各入口自带
## echo 过滤），不入动作表。
## echo：InputEvent.is_action_pressed 默认 allow_echo=false → 键盘重复自动过滤，
## 切换型热键无按住连发风险；轮询侧 Input.is_action_just_pressed 同理只响一次。

const ACTIONS_PATH := "res://assets/config/input_actions.json"

## find_keycode_from_string 解析不了的键名 → Key 枚举常量直取
## （实测 META/PRINTSCREEN/KP_* 无名可查，2026-09 无头验证）。
const _KEY_OVERRIDES: Dictionary = {
	"META": KEY_META,
	"PRINTSCREEN": KEY_PRINT,
	"KP_DIVIDE": KEY_KP_DIVIDE,
	"KP_MULTIPLY": KEY_KP_MULTIPLY,
	"KP_SUBTRACT": KEY_KP_SUBTRACT,
	"KP_ADD": KEY_KP_ADD,
	"KP_ENTER": KEY_KP_ENTER,
	"KP_0": KEY_KP_0, "KP_1": KEY_KP_1, "KP_2": KEY_KP_2, "KP_3": KEY_KP_3,
	"KP_4": KEY_KP_4, "KP_5": KEY_KP_5, "KP_6": KEY_KP_6, "KP_7": KEY_KP_7,
	"KP_8": KEY_KP_8, "KP_9": KEY_KP_9,
	"KP_DOT": KEY_KP_PERIOD,
}

## 鼠标按钮名 → Godot MouseButton 枚举值（展示层与绑定层共用）
const MOUSE_IDS: Dictionary = {
	"LEFT": MOUSE_BUTTON_LEFT,
	"RIGHT": MOUSE_BUTTON_RIGHT,
	"MIDDLE": MOUSE_BUTTON_MIDDLE,
	"WHEEL_UP": MOUSE_BUTTON_WHEEL_UP,
	"WHEEL_DOWN": MOUSE_BUTTON_WHEEL_DOWN,
	"XBUTTON1": MOUSE_BUTTON_XBUTTON1,
	"XBUTTON2": MOUSE_BUTTON_XBUTTON2,
}

## 鼠标按钮名 → 展示名（提示文案用）
const MOUSE_DISPLAY: Dictionary = {
	"LEFT": "左键", "RIGHT": "右键", "MIDDLE": "中键",
	"WHEEL_UP": "滚轮上", "WHEEL_DOWN": "滚轮下",
	"XBUTTON1": "侧键·后", "XBUTTON2": "侧键·前",
}

static var _data: Dictionary = {}


func _ready() -> void:
	reload()


## 重新装载 JSON 并全量重注册 InputMap（幂等：已存在的动作先擦除再注册）。
## 返回注册的绑定事件数；数据异常返回 -1 并 push_error（启动即红）。
func reload() -> int:
	_data = _parse(ACTIONS_PATH)
	if _data.is_empty():
		push_error("[InputBindings] 动作表装载失败: %s" % ACTIONS_PATH)
		return -1
	return register_all(_data)


## 解析后的完整数据 {domains, actions}（首次访问自动装载；静态可测）。
static func data() -> Dictionary:
	if _data.is_empty():
		_data = _parse(ACTIONS_PATH)
	return _data


## 键名 → Godot Key 枚举值；解析失败返回 KEY_NONE(0)。
## 单字符字母/数字直取字符码（KEY_A=65 起，与 find_keycode_from_string 同值）。
static func resolve_key(code: String) -> int:
	if code.length() == 1:
		var c: String = code[0]
		if (c >= "0" and c <= "9") or (c >= "A" and c <= "Z") or (c >= "a" and c <= "z"):
			return c.unicode_at(0)
	if _KEY_OVERRIDES.has(code):
		return int(_KEY_OVERRIDES[code])
	return OS.find_keycode_from_string(code)


## 鼠标按钮名 → MouseButton 枚举值（未知返回 0）。
static func mouse_id(id: String) -> int:
	return int(MOUSE_IDS.get(id, 0))


## bind 字典 → InputEvent（keycode / physical_keycode / mouse + 修饰键）。
## 形态非法返回 null。
static func build_bind_event(bind: Dictionary) -> InputEvent:
	if bind.has("mouse"):
		var mb := InputEventMouseButton.new()
		mb.button_index = mouse_id(String(bind["mouse"]))
		if mb.button_index == 0:
			return null
		return mb
	var ev := InputEventKey.new()
	var code: int = 0
	if bind.has("physical"):
		code = resolve_key(String(bind["physical"]))
		if code != 0:
			ev.physical_keycode = code
	elif bind.has("key"):
		code = resolve_key(String(bind["key"]))
		if code != 0:
			ev.keycode = code
	else:
		return null
	if code == 0:
		push_warning("[InputBindings] 绑定键名解析失败: %s" % bind)
		return null
	for m: String in bind.get("mods", []):
		match m:
			"CTRL": ev.ctrl_pressed = true
			"META": ev.meta_pressed = true
			"ALT": ev.alt_pressed = true
			"SHIFT": ev.shift_pressed = true
	return ev


## 全量注册进 InputMap（幂等）。返回注册的绑定事件数。
static func register_all(d: Dictionary) -> int:
	var n: int = 0
	for a: Dictionary in d.get("actions", []):
		var action := String(a.get("action", ""))
		if action.is_empty():
			continue
		if InputMap.has_action(action):
			InputMap.erase_action(action)
		InputMap.add_action(action)
		for bind: Dictionary in a.get("binds", []):
			var ev := build_bind_event(bind)
			if ev != null:
				InputMap.action_add_event(action, ev)
				n += 1
	return n


## 动作名 → 动作元数据（label/note/domain/binds；未知返回空字典）。
static func action_meta(action: String) -> Dictionary:
	for a: Dictionary in data().get("actions", []):
		if String(a.get("action", "")) == action:
			return a
	return {}


## 动作名 → 首个绑定的展示键名（"F" / "Ctrl+S" / "左键" / "滚轮上"；未知返回 ""）。
static func action_key_hint(action: String) -> String:
	var a := action_meta(action)
	if a.is_empty():
		return ""
	var bind: Dictionary = (a.get("binds", []) as Array)[0] if not (a.get("binds", []) as Array).is_empty() else {}
	if bind.is_empty():
		return ""
	if bind.has("mouse"):
		return String(MOUSE_DISPLAY.get(String(bind["mouse"]), String(bind["mouse"])))
	var key: String = String(bind.get("physical", bind.get("key", "")))
	var mods: Array = bind.get("mods", [])
	var prefix := ""
	for m: String in mods:
		prefix += m.to_lower().capitalize() + "+"
	return prefix + _key_display(key)


## 键名 → 展示形式（单字符原样；枚举名取引擎展示串；解析失败原样返回）。
static func _key_display(code: String) -> String:
	if code.length() == 1:
		return code
	var resolved := resolve_key(code)
	if resolved == 0:
		return code
	var s := OS.get_keycode_string(resolved)
	return s if not s.is_empty() else code


static func _parse(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[InputBindings] 打不开动作表: %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed == null or not (parsed is Dictionary) \
			or not (parsed as Dictionary).has("domains") \
			or not (parsed as Dictionary).has("actions"):
		push_error("[InputBindings] 动作表 JSON 结构不符: %s" % path)
		return {}
	return parsed
