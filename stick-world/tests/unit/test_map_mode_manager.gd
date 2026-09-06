extends Node
## 单元测试：MapModeManager（B4 地图模式系统，总体设计 §5.5）。
##
## 覆盖：默认 TERRAIN / set_mode 切换与信号 / static 广播多实例 / 数字键切换
## （含视图关闭门控）/ api.gd 委托读写。
## 模式是静态全局状态：每个用例前后重置为 TERRAIN，防污染同批后续套件。

signal test_done(code: int)

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptApi := preload("res://modules/world_map/api.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("模式: 默认 TERRAIN + 中文名", _test_default)
	_runner.add_test("模式: set_mode 切换发信号 + 重复设置静默", _test_set_mode_signal)
	_runner.add_test("模式: static 广播——多实例同收", _test_broadcast)
	_runner.add_test("模式: 数字键 1/2 切换 + 视图关闭门控", _test_key_input)
	_runner.add_test("模式: api.gd 委托读写", _test_api)
	MapModeManager.current_mode = MapModeManager.Mode.TERRAIN
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _reset() -> void:
	MapModeManager.current_mode = MapModeManager.Mode.TERRAIN


func _test_default() -> void:
	_reset()
	_runner.assert_equal(MapModeManager.get_mode(), MapModeManager.Mode.TERRAIN,
			"默认模式应为 TERRAIN（创始人要求默认地形图）")
	_runner.assert_equal(MapModeManager.get_mode_name(), "地形", "当前模式中文名")
	_runner.assert_equal(MapModeManager.get_mode_name(MapModeManager.Mode.POLITICAL),
			"政治", "指定模式中文名")
	_runner.assert_equal(MapModeManager.get_mode_name(999), "", "未知模式名返回空串")


func _test_set_mode_signal() -> void:
	_reset()
	var mgr := MapModeManager.new()
	add_child(mgr)
	var got: Array = []
	mgr.mode_changed.connect(func(m: int) -> void: got.append(m))
	MapModeManager.set_mode(MapModeManager.Mode.POLITICAL)
	_runner.assert_equal(MapModeManager.current_mode, MapModeManager.Mode.POLITICAL,
			"set_mode 应更新全局静态模式")
	_runner.assert_equal(got.size(), 1, "切换应发一次 mode_changed")
	_runner.assert_equal(got[0], MapModeManager.Mode.POLITICAL, "信号应携带新模式")
	MapModeManager.set_mode(MapModeManager.Mode.POLITICAL)
	_runner.assert_equal(got.size(), 1, "重复设置同模式应静默不发信号")
	mgr.queue_free()
	_reset()


func _test_broadcast() -> void:
	_reset()
	var a := MapModeManager.new()
	var b := MapModeManager.new()
	add_child(a)
	add_child(b)
	var got: Array = []
	a.mode_changed.connect(func(m: int) -> void: got.append("a:%d" % m))
	b.mode_changed.connect(func(m: int) -> void: got.append("b:%d" % m))
	MapModeManager.set_mode(MapModeManager.Mode.POLITICAL)
	_runner.assert_equal(got.size(), 2, "两个存活实例都应收到广播（实测 %s）" % str(got))
	_runner.assert_true(got.has("a:%d" % MapModeManager.Mode.POLITICAL)
			and got.has("b:%d" % MapModeManager.Mode.POLITICAL), "广播携带新模式")
	a.queue_free()
	b.queue_free()
	_reset()


func _test_key_input() -> void:
	_reset()
	var view := Node2D.new()
	add_child(view)
	var mgr := MapModeManager.new()
	view.add_child(mgr)
	# 视图打开（Content visible=true）：KEY_2 → POLITICAL
	view.visible = true
	var ev2 := InputEventKey.new()
	ev2.keycode = KEY_2
	ev2.pressed = true
	mgr._unhandled_input(ev2)
	_runner.assert_equal(MapModeManager.current_mode, MapModeManager.Mode.POLITICAL,
			"视图打开时 KEY_2 应切政治")
	# KEY_1 → TERRAIN（数字小键盘同义）
	var ev1 := InputEventKey.new()
	ev1.keycode = KEY_KP_1
	ev1.pressed = true
	mgr._unhandled_input(ev1)
	_runner.assert_equal(MapModeManager.current_mode, MapModeManager.Mode.TERRAIN,
			"视图打开时 KP_1 应切地形")
	# 视图关闭（Content visible=false）：按键不响应（1/2 归场景图玩法）
	view.visible = false
	var ev3 := InputEventKey.new()
	ev3.keycode = KEY_2
	ev3.pressed = true
	mgr._unhandled_input(ev3)
	_runner.assert_equal(MapModeManager.current_mode, MapModeManager.Mode.TERRAIN,
			"视图关闭时按键不应响应")
	mgr.queue_free()
	view.queue_free()
	_reset()


func _test_api() -> void:
	_reset()
	var api: Node = ScriptApi.new()
	api.set_map_mode(MapModeManager.Mode.POLITICAL)
	_runner.assert_equal(api.get_map_mode(), MapModeManager.Mode.POLITICAL,
			"api.set_map_mode 应写全局模式")
	api.queue_free()
	_reset()
