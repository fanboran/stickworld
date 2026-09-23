extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：建筑解锁门禁（奖励闭环消费端，expansion unlock_granted → construction）。
##
## 钉死四条语义：
## ① 开局基线：现役可建建筑要的门槛 id 在 WorldState.STARTING_UNLOCKS 里，
##    门禁引入前后开局可建集不变（兵营仍然可建）；
## ② 未获解锁则拒建——数据侧拦在 start_construction_at（不靠 UI 自觉），
##    报错文案含 def_id 便于排查；
## ③ 授予解锁（WorldState.grant_unlock）后当场放行；重复授予幂等返回 false
##    （授予方据此只广播新获项，防重复提示）；
## ④ 无要求（unlocked_by_tech 为空/缺字段）的建筑恒可建——旧 def 不受影响。
##
## fixture：真 buildings.tres 经 ConstructionManager._ready 装载（无地图、无资源注入，
## 只验门禁判定与拒建路径；完整建造循环见 tests/integration/test_construction_cycle）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptConstructionManager := preload("res://modules/construction/scripts/construction_manager.gd")

## 受门禁的现役建筑（buildings.tres：赤岭寨的解锁项）
const LOCKED_DEF := "stone_warehouse"
const LOCKED_UNLOCK := "unlock_stone_warehouse"
## 现役受门禁且开局已获建筑（基线内）
const BASELINE_DEF := "barracks"
const BASELINE_UNLOCK := "tech_military_1"

var _runner: TestRunner
var _cm: Node = null


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("基线: 开局已获清单覆盖兵营所需门槛", _test_starting_baseline)
	_runner.add_test("门禁: 未解锁建筑拒建（数据侧）", _test_locked_rejected)
	_runner.add_test("门禁: 授予解锁后放行 + 重复授予幂等", _test_grant_opens)
	_runner.add_test("门禁: 无要求建筑恒可建", _test_unrestricted_def)
	_runner.run()
	print(_runner.summary())
	_cleanup()
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _make_manager() -> Node:
	var cm: Node = ScriptConstructionManager.new()
	cm.name = "TestConstructionManager"
	add_child(cm)  # _ready 装载 catalog + buildings.tres 定义
	return cm


func _test_starting_baseline() -> void:
	_cm = _make_manager()
	_runner.assert_true(WorldState.STARTING_UNLOCKS.has(BASELINE_UNLOCK),
			"开局基线含 %s" % BASELINE_UNLOCK)
	_runner.assert_true(WorldState.has_unlock(BASELINE_UNLOCK), "基线 id 恒判已获")
	_runner.assert_true(_cm.is_def_unlocked(BASELINE_DEF),
			"开局可建集不变：%s 不受门禁影响" % BASELINE_DEF)
	_runner.assert_equal(_cm.get_def_unlock_requirement(BASELINE_DEF), BASELINE_UNLOCK,
			"%s 的门槛 id 读自 def" % BASELINE_DEF)


func _test_locked_rejected() -> void:
	WorldState.unlocks = {}
	_runner.assert_equal(_cm.get_def_unlock_requirement(LOCKED_DEF), LOCKED_UNLOCK,
			"%s 声明门槛 %s" % [LOCKED_DEF, LOCKED_UNLOCK])
	_runner.assert_false(_cm.is_def_unlocked(LOCKED_DEF), "未获解锁 → 判定未解锁")
	var result: Dictionary = _cm.start_construction_at("test_region", LOCKED_DEF, 10)
	_runner.assert_false(bool(result.get("ok", true)), "未解锁建筑拒建")
	_runner.assert_true(String(result.get("error", "")).contains(LOCKED_DEF),
			"拒建原因点名 def_id（实得 %s）" % result.get("error", ""))


func _test_grant_opens() -> void:
	WorldState.unlocks = {}
	_runner.assert_true(WorldState.grant_unlock(LOCKED_UNLOCK), "首次授予返回 true（新获）")
	_runner.assert_true(_cm.is_def_unlocked(LOCKED_DEF), "授予后门禁放行")
	var again: Dictionary = _cm.start_construction_at("test_region", LOCKED_DEF, 10)
	_runner.assert_false(String(again.get("error", "")).contains("未解锁"),
			"放行后不再因解锁被拒（实得 %s）" % again.get("error", ""))
	_runner.assert_false(WorldState.grant_unlock(LOCKED_UNLOCK), "重复授予返回 false（已获）")
	_runner.assert_false(WorldState.grant_unlock(BASELINE_UNLOCK), "基线 id 视为已获")


func _test_unrestricted_def() -> void:
	_runner.assert_equal(_cm.get_def_unlock_requirement("house"), "", "民居无门槛声明")
	_runner.assert_true(_cm.is_def_unlocked("house"), "无要求建筑恒可建")
	_runner.assert_true(_cm.is_def_unlocked("unknown_def_xx"), "未知 def 不误判为锁（交由注册校验兜底）")


func _cleanup() -> void:
	if _cm != null and is_instance_valid(_cm):
		_cm.queue_free()
	WorldState.unlocks = {}
