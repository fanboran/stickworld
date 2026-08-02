extends Node
## 单元测试：ResourceManager 资源扣减/生产/转移逻辑。
## 纯数据层（RefCounted）测试：new 即用，不进场景树，确定性。

const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptResourceManager := preload("res://modules/resources/scripts/resource_manager.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("ResourceManager: 初始库存为 0", _test_empty)
	_runner.add_test("ResourceManager: produce 增加库存", _test_produce)
	_runner.add_test("ResourceManager: consume 成功扣减", _test_consume_ok)
	_runner.add_test("ResourceManager: consume 库存不足返回失败", _test_consume_insufficient)
	_runner.add_test("ResourceManager: get_stock 全局汇总与区域隔离", _test_stock_regions)
	_runner.add_test("ResourceManager: transfer 成功并扣运输损耗 5%", _test_transfer)
	_runner.add_test("ResourceManager: transfer 来源不足失败", _test_transfer_insufficient)
	_runner.add_test("ResourceManager: 市场参数设置", _test_market_params)
	_runner.run()
	print(_runner.summary())
	get_tree().quit(0 if _runner.all_passed() else 1)


func _test_empty() -> void:
	var m := ScriptResourceManager.new()
	_runner.assert_equal(m.get_stock("res_wood", "r1"), 0.0, "初始库存应为 0")
	_runner.assert_equal(m.get_stock("res_wood"), 0.0, "全局汇总应为 0")


func _test_produce() -> void:
	var m := ScriptResourceManager.new()
	var r: Dictionary = m.produce("res_wood", 100.0, "r1", "test")
	_runner.assert_true(r.get("ok", false), "produce 应成功")
	_runner.assert_equal(m.get_stock("res_wood", "r1"), 100.0, "区域库存应为 100")
	_runner.assert_equal(m.get_stock("res_wood"), 100.0, "全局应为 100")


func _test_consume_ok() -> void:
	var m := ScriptResourceManager.new()
	m.produce("res_wood", 100.0, "r1", "test")
	var r: Dictionary = m.consume("res_wood", 30.0, "r1", "build")
	_runner.assert_true(r.get("ok", false), "扣减应成功")
	_runner.assert_equal(r.get("remaining", -1.0), 70.0, "剩余应为 70")
	_runner.assert_equal(m.get_stock("res_wood", "r1"), 70.0, "区域库存应为 70")


func _test_consume_insufficient() -> void:
	var m := ScriptResourceManager.new()
	m.produce("res_wood", 10.0, "r1", "test")
	var r: Dictionary = m.consume("res_wood", 20.0, "r1", "build")
	_runner.assert_false(r.get("ok", true), "库存不足应失败")
	_runner.assert_equal(r.get("available", -1.0), 10.0, "应返回可用量 10")
	_runner.assert_equal(m.get_stock("res_wood", "r1"), 10.0, "库存不应变化")


func _test_stock_regions() -> void:
	var m := ScriptResourceManager.new()
	m.produce("res_wood", 50.0, "r1", "test")
	m.produce("res_wood", 30.0, "r2", "test")
	_runner.assert_equal(m.get_stock("res_wood", "r1"), 50.0, "r1 库存 50")
	_runner.assert_equal(m.get_stock("res_wood", "r2"), 30.0, "r2 库存 30")
	_runner.assert_equal(m.get_stock("res_wood"), 80.0, "全局汇总 80")
	_runner.assert_equal(m.get_stock("res_wood", "r3"), 0.0, "未生产区域为 0")


func _test_transfer() -> void:
	var m := ScriptResourceManager.new()
	m.produce("res_wood", 100.0, "r1", "test")
	var r: Dictionary = m.transfer("res_wood", 100.0, "r1", "r2")
	_runner.assert_true(r.get("ok", false), "转移应成功")
	_runner.assert_equal(r.get("actual_arrival", -1.0), 95.0, "默认 5% 损耗，到货 95")
	_runner.assert_equal(m.get_stock("res_wood", "r1"), 0.0, "来源应清空")
	_runner.assert_equal(m.get_stock("res_wood", "r2"), 95.0, "目的地 95")
	_runner.assert_equal(m.get_stock("res_wood"), 95.0, "全局总量扣损耗 95")


func _test_transfer_insufficient() -> void:
	var m := ScriptResourceManager.new()
	m.produce("res_wood", 10.0, "r1", "test")
	var r: Dictionary = m.transfer("res_wood", 20.0, "r1", "r2")
	_runner.assert_false(r.get("ok", true), "来源不足应失败")
	_runner.assert_equal(m.get_stock("res_wood", "r1"), 10.0, "来源库存不变")


func _test_market_params() -> void:
	var m := ScriptResourceManager.new()
	_runner.assert_true(m.set_price_ceiling("res_wood", 50.0).get("ok", false), "设置价格上限")
	_runner.assert_equal(m.price_ceilings["res_wood"], 50.0, "上限值正确")
	_runner.assert_true(m.set_price_floor("res_wood", 10.0).get("ok", false), "设置价格下限")
	_runner.assert_equal(m.price_floors["res_wood"], 10.0, "下限值正确")
	_runner.assert_true(m.set_tax_rate(0.1).get("ok", false), "设置税率")
	_runner.assert_equal(m.tax_rate, 0.1, "税率正确")
