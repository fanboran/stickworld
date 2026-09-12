extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：WB2 决策时钟族读档序列化（设计文档12号 §2.4 W2）。
## 覆盖：导出字段齐全（决策剩余量/间隔/种子/域级剩余量）/ 导出→导入往返后相位
## （下次到期相对量）一致 / 导入不重掷错峰（同一快照两次导入结果一致，且覆盖
## spawn 时各自的假偏移）/ 导入后按剩余量到点触发 / 域级通道剩余量回填且独立 /
## 老存档缺字段与坏类型安全回退到装配语义不崩。
## 不进场景树（裸 new + clock_override/jitter_seed_override 注入，先例
## test_ai_spawn_jitter）；BalanceConfig 行注入后必须还原。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptBehaviorProfiles := preload("res://modules/units/scripts/ai/behavior_profiles.gd")
const ScriptAIController := preload("res://modules/units/scripts/ai/ai_controller.gd")

## 基准间隔（代码默认 decision_interval）
const BASE_INTERVAL: float = 0.3

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("导出：剩余量/间隔/种子/域级剩余量字段齐全", _test_export_fields)
	_runner.add_test("往返：导入后下次到期相对量与原相位一致", _test_round_trip)
	_runner.add_test("导入不重掷：同快照两次导入收敛（覆盖 spawn 假偏移）", _test_no_reroll)
	_runner.add_test("导入后按剩余量到点触发（相位真实生效）", _test_import_then_fire)
	_runner.add_test("域级通道：剩余量回填且独立于主节拍", _test_domain_restore)
	_runner.add_test("老存档回退：空/缺字段/坏类型不崩且保持装配", _test_old_save_fallback)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────────────── 测试桩 ────────────────────────────────

## 可拨针假时钟（注入 ai.clock_override = Callable(clock, "get_now")）
class _FakeClock extends RefCounted:
	var now: float = 0.0

	func get_now() -> float:
		return now


func _make_ai(clock: _FakeClock, jitter_seed: int) -> AIController:
	var ai: AIController = ScriptAIController.new()
	ai.clock_override = Callable(clock, "get_now")
	ai.jitter_seed_override = jitter_seed
	return ai


# ─────────────────────────────── 档案注入 ────────────────────────────────

## 注入错峰档案行（错峰开、方差 0 保确定性；先例 test_ai_spawn_jitter）
func _inject_jitter(interval: float, ratio: float) -> void:
	BalanceConfig.data["ai.behavior_profiles"] = [{
		"id": "baseline",
		"decision_interval": interval,
		"decision_variance": 0.0,
		"spawn_jitter_enabled": true,
		"spawn_jitter_ratio": ratio,
		"acquire_interval": 0.4,
		"job_scan_interval": 0.5,
	}]
	ScriptBehaviorProfiles._cache.clear()


func _restore_rows() -> void:
	# 走装载器同款清理后按 .tres 原样回装（防污染后续套件，test_ai_spawn_jitter 同款）
	BalanceConfig._remove_type_data("ai.behavior_profiles")
	BalanceConfig._load_tres("res://config/ai/behavior_profiles.tres", "ai.behavior_profiles")
	ScriptBehaviorProfiles._cache.clear()


# ─────────────────────────────── 用例 ────────────────────────────────

func _test_export_fields() -> void:
	_inject_jitter(BASE_INTERVAL, 0.5)
	var clock := _FakeClock.new()
	clock.now = 5.0
	var ai: AIController = _make_ai(clock, 777)
	ai.apply_spawn_jitter()
	var snap: Dictionary = ai.export_timing_state()
	_runner.assert_equal(int(snap.get("version", -1)), 1, "格式版本 = 1")
	_runner.assert_true(bool(snap.get("armed", false)), "已装配标记随档带出")
	var remain: float = float(snap.get("decision_remaining", -1.0))
	_runner.assert_true(remain > 0.0 and remain <= BASE_INTERVAL + 0.000001,
			"决策剩余量落在装配界内（实测 %.4f）" % remain)
	_runner.assert_approx(float(snap.get("decision_interval", -1.0)), ai._decision_interval, 0.0,
			"当前决策间隔随档带出")
	_runner.assert_equal(str(snap.get("jitter_seed", "")), "777", "错峰种子随档带出（字符串保精度）")
	var dom: Dictionary = snap.get("domain_remaining", {})
	_runner.assert_true(dom.has("combat") and dom.has("job"), "域级通道剩余量齐全")
	_runner.assert_true(float(dom.get("combat", -1.0)) > 0.0, "选敌通道剩余量为正（错峰开）")
	ai.free()
	_restore_rows()


func _test_round_trip() -> void:
	_inject_jitter(BASE_INTERVAL, 0.5)
	# 源实体：装配后推进一拍，相位不再等于装配初值
	var clock := _FakeClock.new()
	clock.now = 7.0
	var a: AIController = _make_ai(clock, 1234)
	a.apply_spawn_jitter()
	clock.now = float(a.get_decision_timing_state()["decision"]["next_at"])
	a._advance_decision_clock(clock.now)
	var remain: float = a._next_decision_at - clock.now
	var snap: Dictionary = a.export_timing_state()
	_runner.assert_approx(float(snap["decision_remaining"]), remain, 0.000001,
			"导出剩余量 = 内部下次到期 - 当前世界时刻")

	# 新实体（读档重建：时钟归零 + spawn 装配）→ 导入快照
	var clock2 := _FakeClock.new()
	var b: AIController = _make_ai(clock2, 9999)
	b.apply_spawn_jitter()
	b.import_timing_state(snap)
	_runner.assert_approx(b._next_decision_at, remain, 0.000001,
			"导入后下次到期 = 存储剩余量（读档时钟 0 基准）")
	_runner.assert_approx(b._next_decision_at - clock2.now, a._next_decision_at - clock.now, 0.000001,
			"往返后相位（剩余量）逐位一致")
	_runner.assert_approx(float(b.export_timing_state()["decision_remaining"]),
			float(snap["decision_remaining"]), 0.000001, "二次导出剩余量一致（可反复存取）")
	_runner.assert_equal(int(b.get_decision_timing_state()["jitter_seed"]), 1234,
			"导入回填错峰种子（后续重新装配可复现）")
	a.free()
	b.free()
	_restore_rows()


func _test_no_reroll() -> void:
	_inject_jitter(BASE_INTERVAL, 0.5)
	var clock := _FakeClock.new()
	clock.now = 3.3
	var src: AIController = _make_ai(clock, 4242)
	src.apply_spawn_jitter()
	var snap: Dictionary = src.export_timing_state()
	var stored: float = float(snap["decision_remaining"])

	# 两个不同种子的新实体各自装配（假偏移不同），导入同一快照后必须收敛
	var c1 := _FakeClock.new()
	var b1: AIController = _make_ai(c1, 111)
	b1.apply_spawn_jitter()
	var c2 := _FakeClock.new()
	var b2: AIController = _make_ai(c2, 222)
	b2.apply_spawn_jitter()
	_runner.assert_true(absf(b1._next_decision_at - b2._next_decision_at) > 0.000001,
			"前置：两种子装配各得不同假偏移（%.6f vs %.6f）" % [b1._next_decision_at, b2._next_decision_at])
	b1.import_timing_state(snap)
	b2.import_timing_state(snap)
	_runner.assert_approx(b1._next_decision_at, b2._next_decision_at, 0.0,
			"同快照两次导入结果逐位一致（导入不掷骰）")
	_runner.assert_approx(b1._next_decision_at, stored, 0.000001,
			"导入结果 = 存储剩余量（覆盖 spawn 假偏移，不叠加）")
	_runner.assert_equal(int(b1.get_decision_timing_state()["jitter_seed"]), 4242,
			"导入回填源种子（非本实例 spawn 种子）")
	src.free()
	b1.free()
	b2.free()
	_restore_rows()


func _test_import_then_fire() -> void:
	_inject_jitter(BASE_INTERVAL, 0.5)
	var clock := _FakeClock.new()
	clock.now = 2.0
	var a: AIController = _make_ai(clock, 555)
	a.apply_spawn_jitter()
	clock.now = 2.05
	var snap: Dictionary = a.export_timing_state()
	var remain: float = float(snap["decision_remaining"])
	_runner.assert_true(remain > 0.0, "前置：剩余量仍为正（%.4f）" % remain)

	var clock2 := _FakeClock.new()
	var b: AIController = _make_ai(clock2, 888)
	b.apply_spawn_jitter()
	b.import_timing_state(snap)
	_runner.assert_true(not b._advance_decision_clock(remain - 0.000001), "剩余量未到不触发")
	_runner.assert_true(b._advance_decision_clock(remain), "剩余量到点触发一拍")
	_runner.assert_approx(b._next_decision_at, remain + BASE_INTERVAL, 0.000001,
			"触发后下次到期 = 触发时刻 + 当前间隔")
	a.free()
	b.free()
	_restore_rows()


func _test_domain_restore() -> void:
	_inject_jitter(BASE_INTERVAL, 0.5)
	var clock := _FakeClock.new()
	var a: AIController = _make_ai(clock, 606)
	a.apply_spawn_jitter()
	var snap: Dictionary = a.export_timing_state()
	var dom: Dictionary = snap["domain_remaining"]
	_runner.assert_true(float(dom["combat"]) > 0.0 and float(dom["job"]) > 0.0,
			"域级剩余量为正（错峰开）")

	var clock2 := _FakeClock.new()
	var b: AIController = _make_ai(clock2, 707)
	b.apply_spawn_jitter()
	b.import_timing_state(snap)
	_runner.assert_approx(float(b._domain_next_at["combat"]), float(dom["combat"]), 0.0,
			"选敌通道剩余量回填（读档时钟 0 基准）")
	_runner.assert_approx(float(b._domain_next_at["job"]), float(dom["job"]), 0.0,
			"派工通道剩余量回填")
	_runner.assert_true(absf(b._next_decision_at - float(b._domain_next_at["combat"])) > 0.000001,
			"主节拍与选敌通道各自相位（非同一数值复制）")
	# 回填剩余量驱动门控：未到点被门控、到点恢复探测
	_runner.assert_true(not b._probe_domain_due("combat"), "回填后通道未到点前被门控")
	clock2.now = float(dom["combat"])
	_runner.assert_true(b._probe_domain_due("combat"), "到点恢复探测")
	a.free()
	b.free()
	_restore_rows()


func _test_old_save_fallback() -> void:
	_inject_jitter(BASE_INTERVAL, 0.5)
	var clock := _FakeClock.new()
	var ai: AIController = _make_ai(clock, 321)
	ai.apply_spawn_jitter()
	var assembled: float = ai._next_decision_at

	# 空字典（老档 extra_data 无 ai_timing 字段）
	ai.import_timing_state({})
	_runner.assert_approx(ai._next_decision_at, assembled, 0.0, "空字典：保持装配语义")
	# 只有版本号（缺决策字段）
	ai.import_timing_state({"version": 1})
	_runner.assert_approx(ai._next_decision_at, assembled, 0.0, "缺决策字段：保持装配语义")
	# 坏类型（字符串/数组/非法种子）全部跳过，不崩不改
	ai.import_timing_state({
		"version": 1, "armed": true, "decision_remaining": "oops",
		"decision_interval": [], "jitter_seed": "not_a_number", "domain_remaining": 5,
	})
	_runner.assert_approx(ai._next_decision_at, assembled, 0.0, "坏类型：不崩且不改动到期时刻")
	_runner.assert_equal(int(ai.get_decision_timing_state()["jitter_seed"]), 321,
			"非法种子不注入（保持原种子）")
	# 未装配快照（armed=false）不改动已装配状态
	ai.import_timing_state({"version": 1, "armed": false, "decision_remaining": 9.0})
	_runner.assert_approx(ai._next_decision_at, assembled, 0.0, "未装配快照不改动已装配状态")
	ai.free()
	_restore_rows()
