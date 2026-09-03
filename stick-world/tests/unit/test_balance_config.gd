extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：BalanceConfig 装载时机 + 路径读取 + 空数据精确警告。
##
## 本套件【不进 batch_runner】（batch_runner.gd 冻结 + 准入标准"不碰 autoload"
## 天然不满足：套件依赖真实 autoload 装载时机与 EventBus.balance_changed）。
## 运行方式：独立场景进程跑
##   godot --headless --path <project> res://tests/unit/test_balance_config.tscn
##
## 回归背景：BalanceConfig 曾仅在 SystemSetup.setup() 显式 reload() 才有数据，
## GameRoot 装配前实例化的实体查询全部落空（警告"路径不存在"并静默回退默认值）。
## 修复后 _ready() 在 autoload 阶段即装载，本套件第 1 用例即该时机回归锚点。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptBalanceConfig := preload("res://core/autoload/balance_config.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("BalanceConfig: autoload 阶段即装载数据", _test_autoload_loaded)
	_runner.add_test("BalanceConfig: get_value 读取真实平衡值", _test_get_value_real)
	_runner.add_test("BalanceConfig: get_value 支持类型路径与行路径", _test_get_value_paths)
	_runner.add_test("BalanceConfig: get_all_of_type 返回行数组", _test_get_all_of_type)
	_runner.add_test("BalanceConfig: 空数据返回 null/空数组（精确警告）", _test_empty_data)
	_runner.add_test("BalanceConfig: reload 幂等（重复调用数据稳定）", _test_reload_idempotent)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _autoload() -> Node:
	return get_node("/root/BalanceConfig")


func _test_autoload_loaded() -> void:
	var bc: Node = _autoload()
	# 修复锚点：测试场景 _ready 时 autoload 早已完成 _ready → reload()，
	# 修复前此处 data 为空（只有 SystemSetup.setup() 才填充）
	_runner.assert_false(bc.data.is_empty(), "autoload 阶段 data 不应为空")
	_runner.assert_gt(bc._type_paths.size(), 0, "类型路径表不应为空")


func _test_get_value_real() -> void:
	var bc: Node = _autoload()
	# 数值锚点取自 config/units/stickmen.tres 的 stm_plain_001（诊断基线实测值）
	var attack: Variant = bc.get_value("units.stickmen.stm_plain_001.base_attack")
	var hp: Variant = bc.get_value("units.stickmen.stm_plain_001.base_hp")
	_runner.assert_not_null(attack, "base_attack 应命中（修复前为 null）")
	_runner.assert_not_null(hp, "base_hp 应命中（修复前为 null）")
	_runner.assert_equal(float(attack), 15.0, "stm_plain_001.base_attack == 15")
	_runner.assert_equal(float(hp), 100.0, "stm_plain_001.base_hp == 100")


func _test_get_value_paths() -> void:
	var bc: Node = _autoload()
	var rows: Variant = bc.get_value("units.stickmen")
	_runner.assert_true(rows is Array, "类型路径应返回行数组")
	_runner.assert_gt((rows as Array).size(), 0, "行数组非空")
	var row: Variant = bc.get_value("units.stickmen.stm_plain_001")
	_runner.assert_true(row is Dictionary, "行路径应返回行字典")
	_runner.assert_equal(str((row as Dictionary).get("id", "")), "stm_plain_001", "行 id 正确")


func _test_get_all_of_type() -> void:
	var bc: Node = _autoload()
	var rows: Array = bc.get_all_of_type("units.stickmen")
	_runner.assert_gt(rows.size(), 0, "get_all_of_type 应返回非空数组")


func _test_empty_data() -> void:
	# 不进场景树：new() 后 _ready 不触发，data 保持为空（模拟未装载状态）
	var fresh: Node = ScriptBalanceConfig.new()
	var v: Variant = fresh.get_value("units.stickmen.stm_plain_001.base_attack")
	_runner.assert_null(v, "空数据时 get_value 应返回 null")
	_runner.assert_true(fresh.get_all_of_type("units.stickmen").is_empty(), "空数据时 get_all_of_type 返回空数组")
	# 精确警告文本（"平衡数据为空"）无法在 GDScript 层捕获 push_warning，
	# 由运行输出人工核验；此处锁定行为契约：短路返回而非误报"路径不存在"
	fresh.free()


func _test_reload_idempotent() -> void:
	var bc: Node = _autoload()
	var keys_before: int = bc.data.size()
	bc.reload()
	_runner.assert_equal(bc.data.size(), keys_before, "重复 reload 后数据规模不变")
	_runner.assert_equal(float(bc.get_value("units.stickmen.stm_plain_001.base_attack")), 15.0, "重载后数值仍正确")
