extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：IncomingThreatLedger 在飞箭矢账本 + stickman_entity 属性委托协议。
## 纯数据层测试：不进场景树、不碰 autoload。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptLedger := preload("res://modules/units/scripts/entity/incoming_threat_ledger.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("Ledger: 初始无在飞伤害、无威胁", _test_init)
	_runner.add_test("Ledger: register 累加/settle 钳零", _test_register_settle)
	_runner.add_test("Ledger: 威胁时刻与窗口查询", _test_threat_window)
	_runner.add_test("委托: stickman_entity 属性读写穿透账本", _test_entity_delegate)
	_runner.add_test("委托: duck-typing 协议兼容（in/get/set）", _test_duck_typing)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _test_init() -> void:
	var l: IncomingThreatLedger = ScriptLedger.new()
	_runner.assert_equal(l.incoming_arrow_damage, 0.0, "初始在飞伤害应为 0")
	_runner.assert_equal(l.arrow_threat_time, -999.0, "初始威胁时刻应为 -999")
	_runner.assert_true(not l.is_threatened(100.0, 2.0), "无威胁标记时不应命中窗口")


func _test_register_settle() -> void:
	var l: IncomingThreatLedger = ScriptLedger.new()
	l.register_incoming(12.0)
	l.register_incoming(8.0)
	_runner.assert_equal(l.incoming_arrow_damage, 20.0, "两箭登记应累加 20")
	l.settle_incoming(12.0)
	_runner.assert_equal(l.incoming_arrow_damage, 8.0, "命中结算应扣减")
	l.settle_incoming(99.0)
	_runner.assert_equal(l.incoming_arrow_damage, 0.0, "超扣应钳 0")


func _test_threat_window() -> void:
	var l: IncomingThreatLedger = ScriptLedger.new()
	l.mark_threat(100.0)
	_runner.assert_true(l.is_threatened(101.0, 2.0), "1s 后仍在 2s 窗口内")
	_runner.assert_true(not l.is_threatened(102.5, 2.0), "2.5s 后应出窗")


func _test_entity_delegate() -> void:
	# 直接构造实体脚本实例（不进场景树，不触发 _ready）
	var entity_script: GDScript = load("res://modules/units/scripts/stickman_entity.gd")
	var e: CharacterBody2D = entity_script.new()
	e.incoming_arrow_damage = 15.0
	_runner.assert_equal(e._threat_ledger.incoming_arrow_damage, 15.0, "写属性应穿透到账本")
	e._threat_ledger.register_incoming(5.0)
	_runner.assert_equal(e.incoming_arrow_damage, 20.0, "读属性应从账本取值")
	e.arrow_threat_time = 50.0
	_runner.assert_equal(e._threat_ledger.arrow_threat_time, 50.0, "威胁时刻写应穿透")
	e.free()


func _test_duck_typing() -> void:
	# 复刻 WeaponMount/arrow_projectile/behavior 层的 duck-typing 访问模式
	var entity_script: GDScript = load("res://modules/units/scripts/stickman_entity.gd")
	var e: CharacterBody2D = entity_script.new()
	_runner.assert_true("incoming_arrow_damage" in e, "in 检查应命中属性委托")
	_runner.assert_true("arrow_threat_time" in e, "in 检查应命中威胁属性")
	e.set("incoming_arrow_damage", 7.0)
	_runner.assert_equal(float(e.get("incoming_arrow_damage")), 7.0, "get/set 应与直接访问等价")
	e.set("arrow_threat_time", 33.0)
	_runner.assert_equal(float(e.get("arrow_threat_time")), 33.0, "威胁时刻 get/set 应等价")
	e.free()
