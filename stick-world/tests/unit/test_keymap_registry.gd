extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：输入绑定数据链 —— input_actions.json（单一真相源）装载 + InputMap 注册
## + 展示侧索引（KeyBindingRegistry）+ 冲突检测。
##
## 纯逻辑（batch_runner 准入：FileAccess + JSON + InputMap 引擎单例，不碰本仓
## autoload；注册的动作在收尾统一擦除，不污染同进程其他套件）。
## 键名解析的三条路径（单字符 ASCII / 覆盖表 / 引擎键名表）在这里全量兜底：
## 动作表里任何键名写错，前两个用例即红。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const Layout := preload("res://modules/ui_global/scripts/keymap/keymap_layout.gd")
const Registry := preload("res://modules/ui_global/scripts/keymap/key_binding_registry.gd")
const Bindings := preload("res://core/autoload/input_bindings.gd")
const Tokens := preload("res://modules/ui_global/scripts/theme/stick_tokens.gd")

var _runner: TestRunner
var _registered: Array[String] = []


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("动作表: 装载 ≥40 动作且结构自洽（域/绑定/键名全解析）", _test_registry_shape)
	_runner.add_test("resolve_key: 覆盖表/单字符/引擎名三路解析", _test_resolve_key)
	_runner.add_test("InputMap: 全量注册幂等 + 物理键位语义（AZERTY 按位置命中）", _test_inputmap_register)
	_runner.add_test("布局: ANSI104 装载 ≥100 键且键名全部可解析", _test_layout_loads)
	_runner.add_test("布局: 键矩形无重叠且外沿与声明尺寸一致", _test_layout_geometry)
	_runner.add_test("索引: 键标注反查（含域过滤与修饰键）", _test_key_index)
	_runner.add_test("索引: 鼠标标注反查", _test_mouse_index)
	_runner.add_test("冲突: 现网数据零冲突，注入冲突可检出", _test_conflicts)
	_runner.add_test("提示: 动作名 → 键名展示/中文标注", _test_action_hints)
	_runner.run()
	print(_runner.summary())
	_cleanup_inputmap()
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


## 擦除本套件注册进 InputMap 的动作（批量进程内不留全局副作用）
func _cleanup_inputmap() -> void:
	for action: String in _registered:
		if InputMap.has_action(action):
			InputMap.erase_action(action)
	_registered.clear()


# ─────────────────────────────── 动作表 ────────────────────────────────

func _test_registry_shape() -> void:
	var data: Dictionary = Registry.load_default()
	_runner.assert_false(data.is_empty(), "动作表应可装载")
	var domains: Array = data["domains"]
	_runner.assert_equal(domains.size(), 6, "六个操作域（附身/世界/通用/指挥/战略图/调试）")
	var domain_ids: Array = []
	for d: Dictionary in domains:
		domain_ids.append(String(d["id"]))
		_runner.assert_true(Tokens.CONTENT_PALETTE_NAMES.has(
				StringName(String(d["color"]))), "域色 id 应是内容色板已知名")
	var seen := {}
	for id: String in domain_ids:
		seen[id] = true
	_runner.assert_equal(seen.size(), domain_ids.size(), "域 id 应唯一")
	var actions: Array = data["actions"]
	_runner.assert_gt(actions.size(), 40, "动作应 ≥40（实测 %d）" % actions.size())
	for a: Dictionary in actions:
		var action := String(a["action"])
		_runner.assert_true(action.contains("/"), "动作名应带域前缀斜杠: %s" % action)
		_runner.assert_true(domain_ids.has(String(a["domain"])), "动作引用未知域: %s" % a["domain"])
		_runner.assert_equal(action.get_slice("/", 0), String(a["domain"]),
				"动作名前缀应与 domain 字段一致: %s" % action)
		_runner.assert_false(String(a["label"]).is_empty(), "动作 label 不应为空")
		var binds: Array = a.get("binds", [])
		_runner.assert_gt(binds.size(), 0, "动作至少一个绑定: %s" % action)
		for bind: Dictionary in binds:
			var kinds := 0
			for k: String in ["physical", "key", "mouse"]:
				if bind.has(k):
					kinds += 1
			_runner.assert_equal(kinds, 1, "绑定恰有 physical/key/mouse 其一: %s" % action)
			if bind.has("mouse"):
				_runner.assert_true(Bindings.MOUSE_IDS.has(String(bind["mouse"])),
						"鼠标名未知: %s" % bind["mouse"])
			else:
				_runner.assert_not_equal(Registry.resolve_key(
						String(bind.get("key", bind.get("physical", "")))), 0,
						"绑定键名解析失败: %s" % action)


# ─────────────────────────────── 键名解析 ────────────────────────────────

func _test_resolve_key() -> void:
	_runner.assert_equal(Bindings.resolve_key("A"), 65, "单字符字母直取 ASCII")
	_runner.assert_equal(Bindings.resolve_key("1"), 49, "单字符数字直取 ASCII")
	_runner.assert_equal(Bindings.resolve_key("ESCAPE"), KEY_ESCAPE, "引擎键名表解析")
	_runner.assert_equal(Bindings.resolve_key("TAB"), KEY_TAB, "引擎键名表解析")
	_runner.assert_equal(Bindings.resolve_key("META"), KEY_META, "覆盖表：META")
	_runner.assert_equal(Bindings.resolve_key("PRINTSCREEN"), KEY_PRINT, "覆盖表：PRINTSCREEN→KEY_PRINT")
	_runner.assert_equal(Bindings.resolve_key("KP_ADD"), KEY_KP_ADD, "覆盖表：KP_ADD")
	_runner.assert_equal(Bindings.resolve_key("KP_9"), KEY_KP_9, "覆盖表：KP_9")
	_runner.assert_true(Bindings.resolve_key("KP_DOT") != 0, "覆盖表：KP_DOT 非 0")
	_runner.assert_equal(Bindings.resolve_key("NOT_A_REAL_KEY"), 0, "未知键名应返回 KEY_NONE")


# ─────────────────────────────── InputMap 注册 ────────────────────────────────

func _test_inputmap_register() -> void:
	var data: Dictionary = Registry.load_default()
	var n: int = Bindings.register_all(data)
	_runner.assert_gt(n, 40, "注册绑定事件数应 ≥40（实测 %d）" % n)
	_runner.assert_true(InputMap.has_action("possess/move_up"), "possess/move_up 应已注册")
	# 幂等：重复注册不翻倍不报错
	var n2: int = Bindings.register_all(data)
	_runner.assert_equal(n2, n, "重复注册应幂等")
	for a: Dictionary in data["actions"]:
		_registered.append(String(a["action"]))
	# 物理键位语义：physical 绑定按位置命中，keycode-only 事件不命中（AZERTY 行为）
	var ev_phys := InputEventKey.new()
	ev_phys.physical_keycode = KEY_W
	ev_phys.pressed = true
	_runner.assert_true(ev_phys.is_action_pressed("possess/move_up"),
			"physical_keycode=W 应命中 possess/move_up")
	var ev_label := InputEventKey.new()
	ev_label.keycode = KEY_W
	ev_label.pressed = true
	_runner.assert_false(ev_label.is_action_pressed("possess/move_up"),
			"仅 keycode 的 W 不应命中 physical 绑定（位置语义）")
	# echo 默认过滤（切换型热键无按住连发）
	var ev_echo := InputEventKey.new()
	ev_echo.physical_keycode = KEY_Q
	ev_echo.pressed = true
	ev_echo.echo = true
	_runner.assert_false(ev_echo.is_action_pressed("possess/toggle_combat"),
			"echo 事件默认不命中（allow_echo=false）")
	# 组合键：Ctrl+S 命中 save_panel，裸 S 不命中
	var ev_ctrl_s := InputEventKey.new()
	ev_ctrl_s.keycode = KEY_S
	ev_ctrl_s.ctrl_pressed = true
	ev_ctrl_s.pressed = true
	_runner.assert_true(ev_ctrl_s.is_action_pressed("common/save_panel"), "Ctrl+S 应命中 save_panel")
	var ev_s := InputEventKey.new()
	ev_s.keycode = KEY_S
	ev_s.pressed = true
	_runner.assert_false(ev_s.is_action_pressed("common/save_panel"), "裸 S 不应命中 save_panel")
	# 鼠标绑定
	var ev_lmb := InputEventMouseButton.new()
	ev_lmb.button_index = MOUSE_BUTTON_LEFT
	ev_lmb.pressed = true
	_runner.assert_true(ev_lmb.is_action_pressed("possess/attack"), "左键应命中 possess/attack")


# ─────────────────────────────── 键盘布局 ────────────────────────────────

func _test_layout_loads() -> void:
	var keys: Array[Dictionary] = Layout.load_ansi104()
	_runner.assert_gt(keys.size(), 100, "ANSI 104 布局键数应 ≥100（实测 %d）" % keys.size())
	for k: Dictionary in keys:
		if int(k["code"]) == 0:
			_runner.assert_true(false, "键名解析失败: %s" % k.get("legend", k))
			return
		_runner.assert_false(String(k["legend"]).is_empty(), "键帽刻字不应为空")


func _test_layout_geometry() -> void:
	var keys: Array[Dictionary] = Layout.load_ansi104()
	var units := Layout.declared_units()
	var max_x := 0.0
	var max_y := 0.0
	for k: Dictionary in keys:
		max_x = maxf(max_x, float(k["x"]) + float(k["w"]))
		max_y = maxf(max_y, float(k["y"]) + float(k["h"]))
	_runner.assert_approx(max_x, units.x, 0.001, "布局总宽应与声明 units.x 一致")
	_runner.assert_approx(max_y, units.y, 0.001, "布局总高应与声明 units.y 一致")
	var eps := 0.0001
	for i in keys.size():
		for j in range(i + 1, keys.size()):
			var a: Dictionary = keys[i]
			var b: Dictionary = keys[j]
			var overlap: bool = float(a["x"]) < float(b["x"]) + float(b["w"]) - eps \
					and float(b["x"]) < float(a["x"]) + float(a["w"]) - eps \
					and float(a["y"]) < float(b["y"]) + float(b["h"]) - eps \
					and float(b["y"]) < float(a["y"]) + float(a["h"]) - eps
			if overlap:
				_runner.assert_true(false, "键矩形重叠: %s × %s" % [a["legend"], b["legend"]])
				return
	_runner.assert_true(true, "无重叠")


# ─────────────────────────────── 展示索引 ────────────────────────────────

func _test_key_index() -> void:
	var data: Dictionary = Registry.load_default()
	var idx: Dictionary = Registry.key_index(data)
	_runner.assert_true(idx.has(KEY_TAB), "TAB（战略图）应在键索引中")
	_runner.assert_true(idx.has(KEY_W), "W（移动）应在键索引中")
	var w_annots: Array = idx.get(KEY_W, [])
	_runner.assert_gt(w_annots.size(), 0, "W 标注非空")
	_runner.assert_equal(String(w_annots[0]["domain"]), "possess", "W 标注域 = possess")
	# 同一动作的多键绑定各自落键：1 与 KP_1 都索引到 strategy/layer_political
	var one_annots: Array = idx.get(KEY_1, [])
	var has_strategy := false
	for a: Dictionary in one_annots:
		if String(a["action"]) == "strategy/layer_political":
			has_strategy = true
	_runner.assert_true(has_strategy, "主键盘 1 应索引到 strategy/layer_political")
	_runner.assert_true(idx.has(KEY_KP_1), "KP_1 也应入索引（同动作第二绑定）")
	# 域过滤：只看战略图时 W 消失、小键盘 2 仍在
	var strat: Dictionary = Registry.key_index(data, PackedStringArray(["strategy"]))
	_runner.assert_false(strat.has(KEY_W), "过滤战略图后 W 不在索引")
	_runner.assert_true(strat.has(KEY_KP_2), "过滤战略图后 KP_2（城市层）仍在")
	# 修饰键绑定：Ctrl+S 存档（common）与 S 移动（possess）并存于同一键
	var s_annots: Array = idx.get(KEY_S, [])
	_runner.assert_equal(s_annots.size(), 2, "S 键应有 2 条标注（possess 移动 + common Ctrl+S）")
	var has_ctrl_mods := false
	for a: Dictionary in s_annots:
		if String(a["domain"]) == "common":
			var mods: PackedStringArray = a.get("mods", PackedStringArray())
			has_ctrl_mods = mods.has("CTRL")
	_runner.assert_true(has_ctrl_mods, "common 域 S 标注应带 CTRL 修饰")


func _test_mouse_index() -> void:
	var data: Dictionary = Registry.load_default()
	var idx: Dictionary = Registry.mouse_index(data)
	var left: Array = idx.get(MOUSE_BUTTON_LEFT, [])
	_runner.assert_gt(left.size(), 2, "左键应有多域标注（攻击/框选/下钻/拖移）")
	var domains: Array = []
	for a: Dictionary in left:
		domains.append(String(a["domain"]))
	_runner.assert_true(domains.has("possess") and domains.has("command"),
			"左键标注应含 possess 与 command 域")
	var wheel: Array = idx.get(MOUSE_BUTTON_WHEEL_UP, [])
	_runner.assert_equal(wheel.size(), 2, "滚轮上应有 2 条标注（世界缩放 + 战略图缩放）")


# ─────────────────────────────── 冲突检测 ────────────────────────────────

func _test_conflicts() -> void:
	var data: Dictionary = Registry.load_default()
	_runner.assert_true(Registry.find_conflicts(data).is_empty(),
			"现网动作表不应有同域同键冲突")
	var injected: Dictionary = data.duplicate(true)
	(injected["actions"] as Array).append(
			{"action": "debug/boom_a", "domain": "debug", "label": "甲功能",
					"binds": [{"physical": "X"}]})
	(injected["actions"] as Array).append(
			{"action": "debug/boom_b", "domain": "debug", "label": "乙功能",
					"binds": [{"physical": "X"}]})
	var conflicts: Array = Registry.find_conflicts(injected)
	_runner.assert_equal(conflicts.size(), 1, "注入同域同键两动作应检出 1 组冲突")
	if conflicts.size() == 1:
		_runner.assert_equal((conflicts[0]["labels"] as Array).size(), 2, "冲突组应含 2 个 label")


# ─────────────────────────────── 提示文案 ────────────────────────────────

func _test_action_hints() -> void:
	_runner.assert_equal(Registry.action_key_hint("possess/interact"), "F",
			"interact 首绑展示 = F")
	_runner.assert_equal(Registry.action_key_hint("common/save_panel"), "Ctrl+S",
			"save_panel 展示 = Ctrl+S")
	_runner.assert_equal(Registry.action_key_hint("possess/attack"), "左键",
			"attack 展示 = 左键")
	_runner.assert_equal(Registry.action_label("common/toggle_world_map"), "战略图",
			"toggle_world_map 标注 = 战略图")
	_runner.assert_true(Registry.action_key_hint("common/quick_save").contains("F5"),
			"quick_save 展示含 F5")
	_runner.assert_equal(Registry.action_key_hint("no/such_action"), "", "未知动作返回空串")
