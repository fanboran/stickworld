extends Node
## 单元测试：MapModeManager（B4 地图层开关系统，总体设计 §5.5）。
##
## 覆盖：默认开关态四项 / toggle_layer 返回值与状态翻转 / static 广播多实例 /
## 数字键 1/2/3/4 切层（含视图关闭门控）/ api.gd 委托读写 / 层中文名。
## 层开关是静态全局状态：每个用例前后重置为默认态，防污染同批后续套件。

signal test_done(code: int)

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptApi := preload("res://modules/world_map/api.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("层: 默认开关态四项 + 中文名", _test_default)
	_runner.add_test("层: toggle_layer 返回值与状态翻转 + 重复设置静默", _test_toggle)
	_runner.add_test("层: static 广播——多实例同收", _test_broadcast)
	_runner.add_test("层: 数字键 1/2/3/4 切层 + 视图关闭门控", _test_key_input)
	_runner.add_test("层: api.gd 委托读写", _test_api)
	_reset()
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _reset() -> void:
	MapModeManager.set_layer_on(MapModeManager.Layer.POLITICAL, true)
	MapModeManager.set_layer_on(MapModeManager.Layer.CITY, true)
	MapModeManager.set_layer_on(MapModeManager.Layer.TRAFFIC, false)
	MapModeManager.set_layer_on(MapModeManager.Layer.RESOURCE, false)


func _test_default() -> void:
	_reset()
	_runner.assert_true(MapModeManager.is_layer_on(MapModeManager.Layer.POLITICAL),
			"政治层默认开")
	_runner.assert_true(MapModeManager.is_layer_on(MapModeManager.Layer.CITY),
			"城市层默认开")
	_runner.assert_false(MapModeManager.is_layer_on(MapModeManager.Layer.TRAFFIC),
			"交通层默认关")
	_runner.assert_false(MapModeManager.is_layer_on(MapModeManager.Layer.RESOURCE),
			"资源层默认关")
	_runner.assert_equal(MapModeManager.layer_name(MapModeManager.Layer.POLITICAL), "政治",
			"政治层中文名")
	_runner.assert_equal(MapModeManager.layer_name(MapModeManager.Layer.CITY), "城市",
			"城市层中文名")
	_runner.assert_equal(MapModeManager.layer_name(MapModeManager.Layer.TRAFFIC), "交通",
			"交通层中文名")
	_runner.assert_equal(MapModeManager.layer_name(MapModeManager.Layer.RESOURCE), "资源",
			"资源层中文名")
	_runner.assert_equal(MapModeManager.layer_name(999), "", "未知层名返回空串")
	_runner.assert_false(MapModeManager.is_layer_on(999), "未知层视为关（不报错）")


func _test_toggle() -> void:
	_reset()
	var mgr := MapModeManager.new()
	add_child(mgr)
	var got: Array = []
	@warning_ignore("confusable_local_declaration")
	mgr.layer_toggled.connect(func(layer: int, on: bool) -> void: got.append([layer, on]))
	# 交通层：默认关 → 开（返回值 = 新状态），信号带 (层, 新状态)
	var on: bool = MapModeManager.toggle_layer(MapModeManager.Layer.TRAFFIC)
	_runner.assert_true(on, "toggle 关→开返回新状态 true")
	_runner.assert_true(MapModeManager.is_layer_on(MapModeManager.Layer.TRAFFIC),
			"toggle 后静态开关表已翻转")
	_runner.assert_equal(got.size(), 1, "toggle 应发一次 layer_toggled")
	_runner.assert_equal(got[0][0], MapModeManager.Layer.TRAFFIC, "信号携带层号")
	_runner.assert_equal(got[0][1], true, "信号携带新状态")
	# 再 toggle：开 → 关，返回值 false
	on = MapModeManager.toggle_layer(MapModeManager.Layer.TRAFFIC)
	_runner.assert_false(on, "toggle 开→关返回新状态 false")
	_runner.assert_false(MapModeManager.is_layer_on(MapModeManager.Layer.TRAFFIC), "层已关闭")
	_runner.assert_equal(got.size(), 2, "第二次 toggle 再发一次信号")
	# 重复设置同状态静默（幂等不发信号）
	MapModeManager.set_layer_on(MapModeManager.Layer.TRAFFIC, false)
	_runner.assert_equal(got.size(), 2, "重复设置同状态应静默不发信号")
	# 未知层：不改状态、返回 false、不发信号
	_runner.assert_false(MapModeManager.toggle_layer(999), "未知层 toggle 返回 false")
	_runner.assert_equal(got.size(), 2, "未知层 toggle 不发信号")
	mgr.queue_free()
	_reset()


func _test_broadcast() -> void:
	_reset()
	var a := MapModeManager.new()
	var b := MapModeManager.new()
	add_child(a)
	add_child(b)
	var got: Array = []
	a.layer_toggled.connect(func(layer: int, on: bool) -> void: got.append("a:%d=%s" % [layer, on]))
	b.layer_toggled.connect(func(layer: int, on: bool) -> void: got.append("b:%d=%s" % [layer, on]))
	MapModeManager.set_layer_on(MapModeManager.Layer.RESOURCE, true)
	_runner.assert_equal(got.size(), 2, "两个存活实例都应收到广播（实测 %s）" % str(got))
	_runner.assert_true(got.has("a:%d=true" % MapModeManager.Layer.RESOURCE)
			and got.has("b:%d=true" % MapModeManager.Layer.RESOURCE), "广播携带层号与新状态")
	a.queue_free()
	b.queue_free()
	_reset()


func _test_key_input() -> void:
	_reset()
	var view := Node2D.new()
	add_child(view)
	var mgr := MapModeManager.new()
	view.add_child(mgr)
	# 层键走 InputMap 动作（physical 绑定）：注入事件须同时设 keycode 与
	# physical_keycode，动作匹配才命中（注册侧只读 physical_keycode）
	# 视图打开（Content visible=true）：KEY_1 翻政治层（默认开 → 关）
	view.visible = true
	_press(mgr, KEY_1)
	_runner.assert_false(MapModeManager.is_layer_on(MapModeManager.Layer.POLITICAL),
			"视图打开时 KEY_1 应翻转政治层")
	# KEY_2 翻城市层（默认开 → 关）
	_press(mgr, KEY_2)
	_runner.assert_false(MapModeManager.is_layer_on(MapModeManager.Layer.CITY),
			"视图打开时 KEY_2 应翻转城市层")
	# KEY_3 翻交通层（默认关 → 开）
	_press(mgr, KEY_3)
	_runner.assert_true(MapModeManager.is_layer_on(MapModeManager.Layer.TRAFFIC),
			"视图打开时 KEY_3 应翻转交通层")
	# KEY_KP_4 翻资源层（小键盘同义；默认关 → 开）
	_press(mgr, KEY_KP_4)
	_runner.assert_true(MapModeManager.is_layer_on(MapModeManager.Layer.RESOURCE),
			"视图打开时 KP_4 应翻转资源层")
	# 视图关闭（Content visible=false）：按键不响应（1/2/3 归场景图玩法）
	view.visible = false
	_press(mgr, KEY_1)
	_runner.assert_false(MapModeManager.is_layer_on(MapModeManager.Layer.POLITICAL),
			"视图关闭时按键不应响应")
	mgr.queue_free()
	view.queue_free()
	_reset()


## 注入一次物理键按下事件（keycode + physical_keycode 双设才能命中 physical 绑定）
func _press(mgr: MapModeManager, key: int) -> void:
	var ev := InputEventKey.new()
	ev.keycode = key as Key
	ev.physical_keycode = key as Key
	ev.pressed = true
	mgr._unhandled_input(ev)


func _test_api() -> void:
	_reset()
	var api: Node = ScriptApi.new()
	api.set_layer_on(MapModeManager.Layer.TRAFFIC, true)
	_runner.assert_true(api.is_layer_on(MapModeManager.Layer.TRAFFIC),
			"api.set_layer_on 应写全局开关表")
	api.set_layer_on(MapModeManager.Layer.RESOURCE, true)
	_runner.assert_true(api.is_layer_on(MapModeManager.Layer.RESOURCE),
			"api.set_layer_on 应支持资源层")
	api.set_layer_on(MapModeManager.Layer.POLITICAL, false)
	_runner.assert_false(api.is_layer_on(MapModeManager.Layer.POLITICAL),
			"api.set_layer_on 应支持关层")
	api.queue_free()
	_reset()
