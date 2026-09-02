extends Node
## 集成测试：通知流堆叠 feed（docs/设计/UI/04-游戏内HUD.md §六）。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_notification_feed.tscn
##
## 覆盖：
##   - UIRoot 装配 feed 到 HudOverlay 槽（EventBus ui_notification 唯一入口）
##   - 多条同时可见；三级着色 info/warn/error
##   - 超上限（5 条）移除最旧
##   - 自动过期：停留 toast_seconds 后淡出销毁
##   - GlobalHUD 内部通知（战斗开始）经 EventBus 进 feed（单条 Label 退役回归钉）

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const UiRootScene := preload("res://modules/ui_global/scenes/ui_root.tscn")

var _runner: TestRunner
var _ui: CanvasLayer
var _feed: Control


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("feed: UIRoot 装配到 HudOverlay 槽", _test_feed_assembly, true)
	_runner.add_test("feed: ui_notification 进 feed + 三级着色", _test_colors, true)
	_runner.add_test("feed: 超上限移除最旧", _test_cap_removes_oldest, true)
	_runner.add_test("feed: GlobalHUD 战斗通知经 EventBus 进 feed", _test_global_hud_route, true)
	_runner.add_test("feed: 自动过期淡出销毁", _test_auto_expire, true)
	_run_tests_async()


func _run_tests_async() -> void:
	_ui = UiRootScene.instantiate()
	add_child(_ui)
	await get_tree().process_frame
	_feed = _ui.get_notification_feed()
	await _runner.run_async()
	print(_runner.summary())
	var exit_code: int = 0 if _runner.all_passed() else 1
	get_tree().quit(exit_code)


## feed 条目面板里的文本标签
func _label_of(index: int) -> Label:
	var panel: Control = _feed.get_child(index)
	return panel.get_child(0) as Label


# ─────────────────────────────── 用例 ────────────────────────────────

func _test_feed_assembly() -> void:
	_runner.assert_not_null(_feed, "UIRoot 应装配通知 feed")
	if _feed == null:
		return
	_runner.assert_true(_feed.get_parent().name == "HudOverlay",
			"feed 应挂在 HudOverlay 槽（布局单一真相源）")
	_runner.assert_equal(_feed.visible_count(), 0, "初始应为空")


func _test_colors() -> void:
	EventBus.ui_notification.emit("测试", "信息条", "info")
	EventBus.ui_notification.emit("测试", "警告条", "warn")
	EventBus.ui_notification.emit("测试", "错误条", "error")
	await get_tree().process_frame
	_runner.assert_equal(_feed.visible_count(), 3, "三条通知应同时可见")
	var l_info: Label = _label_of(0)
	var l_warn: Label = _label_of(1)
	var l_error: Label = _label_of(2)
	_runner.assert_true(String(l_info.text).contains("信息条"), "第一条应为信息条")
	_runner.assert_equal(l_info.modulate, StickTokens.INFO, "info 应着信息蓝")
	_runner.assert_equal(l_warn.modulate, StickTokens.WARN, "warn 应着警告黄")
	_runner.assert_equal(l_error.modulate, StickTokens.DANGER, "error 应着危险红")


func _test_cap_removes_oldest() -> void:
	for i in 7:
		EventBus.ui_notification.emit("压测", "第%d条" % i, "info")
	await get_tree().process_frame
	_runner.assert_equal(_feed.visible_count(), 5, "最多保留 5 条")
	var oldest: Label = _label_of(0)
	_runner.assert_true(String(oldest.text).contains("第2条"),
			"最旧两条应被移除（保留第2~6条）")
	var newest: Label = _label_of(4)
	_runner.assert_true(String(newest.text).contains("第6条"), "最新一条应在底部")


func _test_global_hud_route() -> void:
	var before: int = _feed.visible_count()
	EventBus.battle_started.emit("feed_test_battle")
	await get_tree().process_frame
	# 承接上用例的满容量状态：压入挤掉最旧一条，条数不变；未满则 +1
	var expected: int = min(before + 1, _feed.MAX_VISIBLE)
	_runner.assert_equal(_feed.visible_count(), expected,
			"GlobalHUD 战斗开始通知应经 EventBus 进入 feed（满容量时挤掉最旧）")
	var l: Label = _label_of(_feed.visible_count() - 1)
	_runner.assert_true(String(l.text).contains("一场战斗开始了"),
			"通知内容应为战斗开始文案")


func _test_auto_expire() -> void:
	# 清空存量条目（前面用例的 3s 停留条目），保证过期断言确定性
	for c in _feed.get_children():
		_feed.remove_child(c)
		c.queue_free()
	await get_tree().process_frame
	_runner.assert_equal(_feed.visible_count(), 0, "清空后应为空")
	# 注入短时长验证过期路径（不改 StickTokens）
	_feed.toast_seconds = 0.05
	_feed.fade_seconds = 0.05
	EventBus.ui_notification.emit("过期", "会消失", "info")
	await get_tree().process_frame
	_runner.assert_equal(_feed.visible_count(), 1, "压入后应可见 1 条")
	await get_tree().create_timer(0.4).timeout
	_runner.assert_equal(_feed.visible_count(), 0, "停留+淡出后应自动销毁")
