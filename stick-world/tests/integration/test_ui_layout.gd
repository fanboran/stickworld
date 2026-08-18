extends Node
## 集成测试：UI 防重合布局规则（顶栏/材料条不重叠 + 弹窗安全矩形避让）。
##
## 行业惯例的"一劳永逸"防 UI 重合：常驻 HUD 占位（顶栏/底栏/材料条），
## 弹窗与浮动窗口定位一律夹进安全矩形（StickKit.safe_rect / clamp_to_safe_rect），
## 本测试把这两条不变式固化为回归断言——任何新面板/布局改动盖住常驻 HUD 即失败。
##
## 回归背景：材料条（ResourceBarHost）曾压在顶栏按钮底部（y=46 重叠按钮行 y=12~52），
## 见 docs/设计/UI/09-布局规则与AI自检.md「HUD 预留区」节。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_ui_layout.tscn -- --fresh-start
## 退出码：0 全部通过，1 有失败

const TestRunner := preload("res://tests/core/test_runner.gd")
const _FakeApiScript: GDScript = preload("res://tests/dev/fake_resources_api.gd")

var _runner: TestRunner
var _tests: Array = []


func _ready() -> void:
	# headless 视口默认 100×100，布局断言无意义；强制真实 1080p
	get_window().size = Vector2i(1920, 1080)
	_runner = TestRunner.new()
	_register_tests()
	_run_tests_async()


func _register_tests() -> void:
	_tests.append({"name": "顶栏: 材料条不重叠按钮行", "fn": Callable(self, "_test_hud_no_overlap"), "async": true})
	_tests.append({"name": "安全矩形: 排除 HUD 预留区", "fn": Callable(self, "_test_safe_rect_math"), "async": false})
	_tests.append({"name": "弹窗: FLOATING 夹进安全矩形（1080p）", "fn": Callable(self, "_test_window_clamp_1080p"), "async": true})
	_tests.append({"name": "弹窗: 小视口不盖顶栏（720p）", "fn": Callable(self, "_test_window_clamp_720p"), "async": true})


func _run_tests_async() -> void:
	for t in _tests:
		_runner.begin_test(t["name"])
		if t["async"]:
			await t["fn"].call()
		else:
			t["fn"].call()
		_runner.end_test()
		print("完成: %s" % t["name"])

	var summary := _runner.summary()
	print(summary)
	var exit_code: int = 0 if _runner.all_passed() else 1
	get_tree().quit(exit_code)


## 回归：材料条（ResourceBarHost）与顶栏按钮行不重叠，且位于顶栏（60px）下方
func _test_hud_no_overlap() -> void:
	var hud: Control = (load("res://modules/ui_global/scenes/hud/global_hud.tscn") as PackedScene).instantiate()
	add_child(hud)
	var fake := Node.new()
	fake.set_script(_FakeApiScript)
	fake.name = "FakeResourcesApi"
	add_child(fake)
	if hud.has_method("attach_resources"):
		hud.attach_resources(fake)
	await get_tree().process_frame
	await get_tree().process_frame
	var rbh: Control = hud.get_node_or_null("ResourceBarHost")
	_runner.assert_true(rbh != null, "ResourceBarHost 应存在")
	if rbh == null:
		return
	var strip_rect: Rect2 = rbh.get_global_rect()
	_runner.assert_true(strip_rect.position.y >= 60.0,
			"材料条应位于顶栏（60px）下方，实际 y=%.1f" % strip_rect.position.y)
	var hbox: Control = hud.get_node_or_null("MarginContainer/HBoxContainer")
	_runner.assert_true(hbox != null, "顶栏 HBox 应存在")
	if hbox == null:
		return
	for c in hbox.get_children():
		var brect: Rect2 = (c as Control).get_global_rect()
		_runner.assert_true(not brect.intersects(strip_rect),
				"材料条不应重叠按钮 %s（按钮 %s / 材料条 %s）" % [c.name, brect, strip_rect])
	hud.queue_free()


## 安全矩形数学：排除顶栏+材料条（104px）与底部面板（88px），clamp 幂等
func _test_safe_rect_math() -> void:
	var c := Control.new()
	add_child(c)
	var safe := StickKit.safe_rect(c, 8.0)
	_runner.assert_true(absf(safe.position.y - StickKit.HUD_TOP_RESERVED) < 0.01,
			"安全矩形顶部应避开顶栏+材料条（%.0fpx），实际 y=%.1f" % [StickKit.HUD_TOP_RESERVED, safe.position.y])
	_runner.assert_true(absf(safe.size.y - (1080.0 - StickKit.HUD_TOP_RESERVED - StickKit.HUD_BOTTOM_RESERVED)) < 0.01,
			"安全矩形高度应减去顶/底预留，实际 %.1f" % safe.size.y)
	_runner.assert_true(absf(safe.size.x - (1920.0 - 16.0)) < 0.01, "安全矩形宽度应减左右边距")
	# 超大矩形应被夹进安全矩形
	var big := Rect2(0, 0, 2000, 2000)
	var clamped := StickKit.clamp_to_safe_rect(c, big, 8.0)
	_runner.assert_true(safe.encloses(clamped), "超大矩形应被夹进安全矩形（%s）" % clamped)
	# 已在安全矩形内的矩形不应移动
	var inside := Rect2(300, 300, 200, 100)
	var kept := StickKit.clamp_to_safe_rect(c, inside, 8.0)
	_runner.assert_true(kept == inside, "已在安全矩形内的矩形不应被移动（%s → %s）" % [inside, kept])
	c.queue_free()


## 1080p：FLOATING 窗口（1400×850，能放进安全矩形）初始定位必须整体落在安全矩形内
func _test_window_clamp_1080p() -> void:
	get_window().size = Vector2i(1920, 1080)
	await get_tree().process_frame
	var w := StickWindow.new()
	w.window_size = Vector2(1400, 850)
	w.behavior = StickWindow.Behavior.FLOATING
	add_child(w)
	w._build_window()
	await get_tree().process_frame
	await get_tree().process_frame
	var panel: Control = w.get_child(0) as Control
	var safe := StickKit.safe_rect(w, 8.0)
	# 居中定位会落在 y=90（盖住顶栏），夹紧后必须整体入安全区
	_runner.assert_true(safe.encloses(panel.get_global_rect()),
			"FLOATING 窗口应完全落在安全矩形内（窗口 %s / 安全 %s）" % [panel.get_global_rect(), safe])
	_runner.assert_true(panel.get_global_rect().position.y >= StickKit.HUD_TOP_RESERVED - 0.5,
			"窗口顶部不得盖住顶栏（y 应 ≥ %.0f），实际 y=%.1f" % [StickKit.HUD_TOP_RESERVED, panel.get_global_rect().position.y])
	w.queue_free()


## 720p：小视口下窗口不得盖住顶栏（顶部 y ≥ HUD_TOP_RESERVED）
func _test_window_clamp_720p() -> void:
	get_window().size = Vector2i(1280, 720)
	await get_tree().process_frame
	var w := StickWindow.new()
	w.window_size = Vector2(1264, 528)
	w.behavior = StickWindow.Behavior.FLOATING
	add_child(w)
	w._build_window()
	await get_tree().process_frame
	await get_tree().process_frame
	var panel: Control = w.get_child(0) as Control
	var rect: Rect2 = panel.get_global_rect()
	var safe := StickKit.safe_rect(w, 8.0)
	_runner.assert_true(safe.encloses(rect), "小视口下窗口应夹进安全矩形（%s）" % rect)
	_runner.assert_true(rect.position.y >= StickKit.HUD_TOP_RESERVED - 0.5,
			"窗口顶部不得盖住顶栏（y 应 ≥ %.0f），实际 y=%.1f" % [StickKit.HUD_TOP_RESERVED, rect.position.y])
	w.queue_free()
	get_window().size = Vector2i(1920, 1080)
