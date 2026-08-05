extends Node
## 单元测试：ResourcesApi 信号转发层（resource_changed / resource_not_enough）。
## 2026-08 补充：此前仅测 ResourceManager 纯数据层，信号层零覆盖。
## 纯逻辑测试：api Node 实例化后不进场景树，确定性。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptResourcesApi := preload("res://modules/resources/api.gd")
const ScriptResourceManager := preload("res://modules/resources/scripts/resource_manager.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("ResourcesApi: 未初始化时操作返回错误", _test_uninitialized)
	_runner.add_test("ResourcesApi: consume 成功发射 resource_changed", _test_consume_signal)
	_runner.add_test("ResourcesApi: consume 不足发射 resource_not_enough", _test_consume_not_enough_signal)
	_runner.add_test("ResourcesApi: produce 发射 resource_changed 且 delta 为正", _test_produce_signal)
	_runner.add_test("ResourcesApi: 查询接口转发 manager", _test_query_forward)
	_runner.add_test("ResourcesApi: transfer/市场参数转发", _test_forward_rest)
	_runner.run()
	print(_runner.summary())
	get_tree().quit(0 if _runner.all_passed() else 1)


## 构造 api + manager fixture，返回 {"api": ..., "manager": ..., "events": [...]}
func _make_api() -> Dictionary:
	var api := ScriptResourcesApi.new()
	var manager := ScriptResourceManager.new()
	api.setup(manager)
	var events: Array = []  # {sig: String, args: Array}
	api.resource_changed.connect(func(a, b, c, d): events.append({"sig": "changed", "args": [a, b, c, d]}))
	api.resource_not_enough.connect(func(a, b, c, d): events.append({"sig": "not_enough", "args": [a, b, c, d]}))
	return {"api": api, "manager": manager, "events": events}


func _test_uninitialized() -> void:
	var api := ScriptResourcesApi.new()
	var r: Dictionary = api.consume("res_wood", 10.0, "r1", "test")
	_runner.assert_false(r.get("ok", true), "未初始化 consume 应失败")
	_runner.assert_false(api.produce("res_wood", 10.0, "r1", "test").get("ok", true), "未初始化 produce 应失败")
	_runner.assert_equal(api.get_stock("res_wood", "r1"), 0.0, "未初始化 get_stock 返回 0")


func _test_consume_signal() -> void:
	var f := _make_api()
	f.manager.produce("res_wood", 100.0, "r1", "test")
	f.events.clear()
	var r: Dictionary = f.api.consume("res_wood", 30.0, "r1", "build")
	_runner.assert_true(r.get("ok", false), "扣减应成功")
	_runner.assert_equal(f.events.size(), 1, "应发射 1 次信号")
	var e: Dictionary = f.events[0]
	_runner.assert_equal(e.sig, "changed", "应为 resource_changed")
	_runner.assert_equal(e.args[0], "res_wood", "信号参数 resource_id")
	_runner.assert_equal(e.args[1], 100.0, "amount 应为操作前总量（100）")
	_runner.assert_equal(e.args[2], -30.0, "delta 应为 -30")
	_runner.assert_equal(e.args[3], "r1", "信号参数 region_id")


func _test_consume_not_enough_signal() -> void:
	var f := _make_api()
	f.manager.produce("res_wood", 10.0, "r1", "test")
	f.events.clear()
	var r: Dictionary = f.api.consume("res_wood", 20.0, "r1", "build")
	_runner.assert_false(r.get("ok", true), "库存不足应失败")
	_runner.assert_equal(f.events.size(), 1, "应发射 1 次信号")
	var e: Dictionary = f.events[0]
	_runner.assert_equal(e.sig, "not_enough", "应为 resource_not_enough")
	_runner.assert_equal(e.args[1], 20.0, "required 应为请求量")
	_runner.assert_equal(e.args[2], 10.0, "available 应为可用量")


func _test_produce_signal() -> void:
	var f := _make_api()
	f.events.clear()
	var r: Dictionary = f.api.produce("res_wood", 50.0, "r1", "mine")
	_runner.assert_true(r.get("ok", false), "生产应成功")
	_runner.assert_equal(f.events.size(), 1, "应发射 1 次信号")
	var e: Dictionary = f.events[0]
	_runner.assert_equal(e.sig, "changed", "应为 resource_changed")
	_runner.assert_equal(e.args[1], 50.0, "amount 应为操作后总量")
	_runner.assert_equal(e.args[2], 50.0, "delta 应为 +50")
	# 连续生产：总量叠加
	f.events.clear()
	f.api.produce("res_wood", 25.0, "r1", "mine")
	_runner.assert_equal(f.events[0].args[1], 75.0, "第二次生产 amount 应为 75")
	_runner.assert_equal(f.events[0].args[2], 25.0, "第二次 delta 应为 25")


func _test_query_forward() -> void:
	var f := _make_api()
	f.manager.produce("res_wood", 40.0, "r1", "test")
	_runner.assert_equal(f.api.get_stock("res_wood", "r1"), 40.0, "get_stock 转发")
	_runner.assert_equal(f.api.get_all_stocks().size(), 1, "get_all_stocks 转发")
	f.manager.set_price_ceiling("res_wood", 50.0)
	_runner.assert_equal(f.api.get_price("res_wood", "r1"), 0.0, "get_price 转发（未定价为 0）")


func _test_forward_rest() -> void:
	var f := _make_api()
	f.manager.produce("res_wood", 100.0, "r1", "test")
	var r: Dictionary = f.api.transfer("res_wood", 100.0, "r1", "r2")
	_runner.assert_true(r.get("ok", false), "transfer 转发成功")
	_runner.assert_equal(f.api.get_stock("res_wood", "r2"), 95.0, "transfer 5% 损耗到货 95")
	_runner.assert_true(f.api.set_price_ceiling("res_wood", 50.0).get("ok", false), "set_price_ceiling 转发")
	_runner.assert_true(f.api.set_price_floor("res_wood", 10.0).get("ok", false), "set_price_floor 转发")
	_runner.assert_true(f.api.set_tax_rate(0.1).get("ok", false), "set_tax_rate 转发")
