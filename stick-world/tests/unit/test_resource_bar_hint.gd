extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：ResourceBar 资源不足提示（resources api 信号 resource_not_enough
## 的 UI 订阅接线 + 2s 节流窗合并）。
##
## 真链路夹具：真 ResourcesApi/ResourceManager 走 consume 失败发射信号，
## 真 ResourceBar（挂进本套件子树，tween 可用）消费——不 stub 信号源。
## 节流时钟注入假时钟（bar.time_source），全部用例同步零帧等待，确定。
## 依赖用 const preload，不依赖 class_name 全局注册（headless 下不可靠）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptResourcesApi := preload("res://modules/resources/api.gd")
const ScriptResourceManager := preload("res://modules/resources/scripts/resource_manager.gd")
const ScriptResourceBar := preload("res://modules/ui_global/scripts/hud/resource_bar.gd")

## 假时钟当前时刻（msec）——bar.time_source 闭包读 self 成员，改这里即拨钟
var _fake_now: int = 1_000
## 夹具登记（套件收尾统一 free，防 ObjectDB 泄漏——本仓有逐套泄漏普查）
var _fixtures: Array[Dictionary] = []

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("不足提示: consume 失败浮出红字缺量", _test_hint_visible)
	_runner.add_test("不足提示: 节流窗内合并只刷新文案不顺延", _test_throttle_merge)
	_runner.add_test("不足提示: 窗外重试重新浮出并起窗", _test_refire_after_window)
	_runner.add_test("不足提示: 非展示资源无提示不崩", _test_unknown_resource_ignored)
	_runner.add_test("不足提示: 缺口向上取整且负数钳零", _test_deficit_math)
	_runner.run()
	var summary: String = _runner.summary()
	# 夹具清扫：api/bar 是 Node 需显式 free；manager 是 RefCounted 纯数据层，
	# 引用清空（api 释放 + 字典 clear）后自动回收，勿对它调 free
	for f in _fixtures:
		(f["bar"] as Node).free()
		(f["api"] as Node).free()
	_fixtures.clear()
	print(summary)
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────────────── 夹具 ────────────────────────────────

## 真 api+manager + 真资源条（挂本套件子树：tween 需在树内）。
## 资源条时钟拨到假时钟；用完随套件节点整体释放。
func _make_bar() -> Dictionary:
	var api := ScriptResourcesApi.new()
	var manager := ScriptResourceManager.new()
	api.setup(manager)
	var bar: ResourceBar = ScriptResourceBar.new()
	bar.name = "ResourceBarFixture"
	add_child(bar)
	bar.time_source = func() -> int: return _fake_now
	bar.setup(api)
	var f := {"api": api, "manager": manager, "bar": bar}
	_fixtures.append(f)
	return f


# ─────────────────────────────── 用例 ────────────────────────────────

## 扣减失败（库存 10 请 20）→ 条目提示可见且显示缺口"缺10"
func _test_hint_visible() -> void:
	var f := _make_bar()
	f.manager.produce("res_wood", 10.0, "r1", "test")
	var r: Dictionary = f.api.consume("res_wood", 20.0, "r1", "build")
	_runner.assert_false(r.get("ok", true), "库存不足应失败")
	_runner.assert_true(f.bar.not_enough_text("res_wood") != "", "不足后提示应可见")
	_runner.assert_equal(f.bar.not_enough_text("res_wood"), "缺10", "文案应显示缺口 10")
	_runner.assert_gt(f.bar.not_enough_deadline_msec("res_wood"), 0, "节流窗截止应已登记")


## 窗内重复失败：文案合并为最新缺口，截止时刻不变（不重弹不刷屏）
func _test_throttle_merge() -> void:
	var f := _make_bar()
	_fake_now = 10_000
	f.manager.produce("res_stone", 5.0, "r1", "test")
	f.api.consume("res_stone", 8.0, "r1", "build")  # 首次浮出：缺3
	var deadline: int = f.bar.not_enough_deadline_msec("res_stone")
	_runner.assert_gt(deadline, 0, "首次应登记截止时刻")
	f.api.consume("res_stone", 30.0, "r1", "build")  # 窗内再失败：缺25
	_runner.assert_equal(f.bar.not_enough_text("res_stone"), "缺25", "窗内合并应刷新为最新缺口")
	_runner.assert_equal(f.bar.not_enough_deadline_msec("res_stone"), deadline, "窗内不顺延截止（不重弹）")


## 窗外重试：重新浮出（截止时刻前移）并刷新文案
func _test_refire_after_window() -> void:
	var f := _make_bar()
	_fake_now = 20_000
	f.manager.produce("res_metal_ore", 1.0, "r1", "test")
	f.api.consume("res_metal_ore", 4.0, "r1", "build")  # 首次：缺3
	var deadline: int = f.bar.not_enough_deadline_msec("res_metal_ore")
	_runner.assert_gt(deadline, 0, "首次应登记截止时刻")
	_fake_now = deadline  # 拨钟到窗外
	f.api.consume("res_metal_ore", 9.0, "r1", "build")  # 重试：缺8
	_runner.assert_gt(f.bar.not_enough_deadline_msec("res_metal_ore"), deadline, "窗外重弹应重新起窗")
	_runner.assert_equal(f.bar.not_enough_text("res_metal_ore"), "缺8", "窗外重弹应刷新文案")


## 资源条不展示的资源（res_silk 不在 _DISPLAY_RESOURCES）→ 无提示不崩
func _test_unknown_resource_ignored() -> void:
	var f := _make_bar()
	f.api.resource_not_enough.emit("res_silk", 5.0, 0.0, "r1")
	_runner.assert_equal(f.bar.not_enough_text("res_silk"), "", "非展示资源应无提示")
	_runner.assert_equal(f.bar.not_enough_deadline_msec("res_silk"), 0, "非展示资源不应起窗")


## 缺口数学：需求-可用向上取整（float 台账），已足额钳 0
func _test_deficit_math() -> void:
	var f := _make_bar()
	# float 台账零头：10.2 可用请 12.5 → 缺 2.3 → 取整 3
	f.api.resource_not_enough.emit("res_gold", 12.5, 10.2, "r1")
	_runner.assert_equal(f.bar.not_enough_text("res_gold"), "缺3", "缺口应向上取整")
	f.api.resource_not_enough.emit("res_diamond", 5.0, 9.0, "r1")
	_runner.assert_equal(f.bar.not_enough_text("res_diamond"), "缺0", "已足额缺口钳 0")
