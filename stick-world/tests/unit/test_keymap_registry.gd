extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：键鼠说明图数据链 —— ANSI 布局装载 + 按键注册表索引 + 冲突检测。
##
## 纯逻辑无场景树（batch_runner 准入：布局/注册表装载只 FileAccess + JSON，
## 不碰 autoload）。键名解析的三条路径（单字符 ASCII / 覆盖表 / 引擎键名表）
## 在这里全量兜底：布局 JSON 里任何键名写错，第 1 个用例即红。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const Layout := preload("res://modules/ui_global/scripts/keymap/keymap_layout.gd")
const Registry := preload("res://modules/ui_global/scripts/keymap/key_binding_registry.gd")
const Tokens := preload("res://modules/ui_global/scripts/theme/stick_tokens.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("布局: ANSI104 装载 ≥100 键且键名全部可解析", _test_layout_loads)
	_runner.add_test("布局: 键矩形无重叠且外沿与声明尺寸一致", _test_layout_geometry)
	_runner.add_test("resolve_key: 覆盖表/单字符/引擎名三路解析", _test_resolve_key)
	_runner.add_test("注册表: 域表与绑定条目结构自洽", _test_registry_shape)
	_runner.add_test("索引: 键标注反查（含域过滤与修饰键）", _test_key_index)
	_runner.add_test("索引: 鼠标标注反查", _test_mouse_index)
	_runner.add_test("冲突: 现网数据零冲突，注入冲突可检出", _test_conflicts)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────────────── 布局 ────────────────────────────────

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
	# 键矩形两两不重叠（共享边允许）：104² 组合量级可全量扫
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


# ─────────────────────────────── 键名解析 ────────────────────────────────

func _test_resolve_key() -> void:
	_runner.assert_equal(Layout.resolve_key("A"), 65, "单字符字母直取 ASCII")
	_runner.assert_equal(Layout.resolve_key("1"), 49, "单字符数字直取 ASCII")
	_runner.assert_equal(Layout.resolve_key("ESCAPE"), KEY_ESCAPE, "引擎键名表解析")
	_runner.assert_equal(Layout.resolve_key("TAB"), KEY_TAB, "引擎键名表解析")
	_runner.assert_equal(Layout.resolve_key("META"), KEY_META, "覆盖表：META")
	_runner.assert_equal(Layout.resolve_key("PRINTSCREEN"), KEY_PRINT, "覆盖表：PRINTSCREEN→KEY_PRINT")
	_runner.assert_equal(Layout.resolve_key("KP_ADD"), KEY_KP_ADD, "覆盖表：KP_ADD")
	_runner.assert_equal(Layout.resolve_key("KP_9"), KEY_KP_9, "覆盖表：KP_9")
	_runner.assert_true(Layout.resolve_key("KP_DOT") != 0, "覆盖表：KP_DOT 非 0")
	_runner.assert_equal(Layout.resolve_key("NOT_A_REAL_KEY"), 0, "未知键名应返回 KEY_NONE")


# ─────────────────────────────── 注册表 ────────────────────────────────

func _test_registry_shape() -> void:
	var data: Dictionary = Registry.load_default()
	_runner.assert_false(data.is_empty(), "注册表应可装载")
	var domains: Array = data["domains"]
	_runner.assert_equal(domains.size(), 6, "六个操作域（通用/世界/附身/指挥/战略图/调试）")
	var ids: Array = []
	for d: Dictionary in domains:
		ids.append(String(d["id"]))
	var seen := {}
	for id: String in ids:
		seen[id] = true
	_runner.assert_equal(seen.size(), ids.size(), "域 id 应唯一")
	_runner.assert_true(Tokens.CONTENT_PALETTE_NAMES.has(
			StringName(String(domains[0]["color"]))), "域色 id 应是内容色板已知名")
	var bindings: Array = data["bindings"]
	_runner.assert_gt(bindings.size(), 30, "绑定条目应 ≥30（实测 %d）" % bindings.size())
	for b: Dictionary in bindings:
		var has_key: bool = b.has("key")
		var has_mouse: bool = b.has("mouse")
		_runner.assert_true(has_key != has_mouse, "每条绑定恰有 key 或 mouse 其一")
		if not ids.has(String(b["domain"])):
			_runner.assert_true(false, "绑定引用未知域: %s" % b["domain"])
			return
		_runner.assert_false(String(b["label"]).is_empty(), "绑定 label 不应为空")
		if has_key and Layout.resolve_key(String(b["key"])) == 0:
			_runner.assert_true(false, "绑定键名解析失败: %s" % b["key"])
			return
		if has_mouse and not Registry.MOUSE_IDS.has(String(b["mouse"])):
			_runner.assert_true(false, "绑定鼠标名未知: %s" % b["mouse"])
			return


# ─────────────────────────────── 索引 ────────────────────────────────

func _test_key_index() -> void:
	var data: Dictionary = Registry.load_default()
	var idx: Dictionary = Registry.key_index(data)
	_runner.assert_true(idx.has(KEY_TAB), "TAB（战略图）应在键索引中")
	_runner.assert_true(idx.has(KEY_W), "W（移动）应在键索引中")
	var w_annots: Array = idx.get(KEY_W, [])
	_runner.assert_gt(w_annots.size(), 0, "W 标注非空")
	_runner.assert_equal(String(w_annots[0]["domain"]), "world", "W 标注域 = world")
	# 域过滤：只看战略图时 W 消失、小键盘 2 仍在
	var strat: Dictionary = Registry.key_index(data, PackedStringArray(["strategy"]))
	_runner.assert_false(strat.has(KEY_W), "过滤战略图后 W 不在索引")
	_runner.assert_true(strat.has(KEY_KP_2), "过滤战略图后 KP_2（政治模式）仍在")
	# 修饰键绑定：Ctrl+S 存档（common）与 S 移动（world）并存于同一键
	var s_annots: Array = idx.get(KEY_S, [])
	_runner.assert_equal(s_annots.size(), 2, "S 键应有 2 条标注（common Ctrl+S + world 移动）")
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
	_runner.assert_gt(left.size(), 1, "左键应有多域标注（附身攻击 + 指挥框选）")
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
			"现网注册表不应有同域同键冲突")
	var injected: Dictionary = data.duplicate(true)
	(injected["bindings"] as Array).append({"key": "X", "domain": "debug", "label": "甲功能"})
	(injected["bindings"] as Array).append({"key": "X", "domain": "debug", "label": "乙功能"})
	var conflicts: Array = Registry.find_conflicts(injected)
	_runner.assert_equal(conflicts.size(), 1, "注入同域同键两绑定应检出 1 组冲突")
	if conflicts.size() == 1:
		_runner.assert_equal((conflicts[0]["labels"] as Array).size(), 2, "冲突组应含 2 个 label")
