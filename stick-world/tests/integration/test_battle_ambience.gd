extends Node
## 集成测试：战斗氛围层（战场声场随接战规模分档）+ 接战规模信号契约。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_battle_ambience.tscn
##
## 覆盖：
##   - 信号契约：BattleInstance.start 广播 battle_engagement_changed（双方存活数），
##     随胜负清点同拍（0.5s）周期续播
##   - 生命周期：battle_started 激活声场 / battle_ended 退场
##   - 规模分档：存活数 → 音量档（BATTLE_AMBIENCE_TIERS），未激活时忽略推送
##   - 资产缺失静默：battle_crowd 资产未就位时激活态照常记账、不出声不报错
##
## headless 下没有音频设备，播放调用是安全空操作，出声无副作用。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
## 被测信号源（combat 内部路径——tests 仓级脚本不受模块审计约束）
const BattleInstanceScript := preload("res://modules/combat/scripts/battle/battle_instance.gd")

var _runner: TestRunner
var _captured: Array = []


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("信号契约: BattleInstance 广播接战规模（start + 周期）",
		_test_engagement_signal, true)
	_runner.add_test("氛围层: battle_started 激活 / ended 退场", _test_lifecycle, true)
	_runner.add_test("氛围层: 规模分档与未激活忽略", _test_tiering, true)
	_run_tests_async()


func _run_tests_async() -> void:
	await _runner.run_async()
	_cleanup()
	await get_tree().process_frame
	await get_tree().process_frame
	print(_runner.summary())
	get_tree().quit(0 if _runner.all_passed() else 1)


func _cleanup() -> void:
	# 无论用例走到哪一步，把氛围层与战斗情境收干净（不污染后续套件）
	AudioManager.reset_runtime_state()
	MusicDirector.set_enabled(false)
	MusicDirector.set_enabled(true)
	_reset_ambience_state()


## 用 EventBus 真实生产信号把氛围层关掉（battle_ended 退场路径）。
## battle_started 会触发 TimeManager「开战自动暂停」（默认开）——测试环境解除，
## 防暂停态泄漏到本套件后续用例。
func _reset_ambience_state() -> void:
	_resume_time()
	EventBus.battle_started.emit("amb_test_cleanup")
	EventBus.battle_ended.emit("amb_test_cleanup", true)
	_resume_time()
	AudioManager.reset_runtime_state()


## 解除「开战自动暂停」（同 test_sim_tree_order / test_battle_lifecycle 惯例）
func _resume_time() -> void:
	if TimeManager != null and TimeManager.is_paused():
		TimeManager.set_speed(TimeManager.Speed.X1)


func _wait_ms(ms: int) -> void:
	await get_tree().create_timer(float(ms) / 1000.0, true, false, true).timeout


func _on_engagement_captured(_battle_id: String, alive_units: int) -> void:
	_captured.append(alive_units)


# ─────────────────────────────── 信号契约 ────────────────────────────────

func _test_engagement_signal() -> void:
	_reset_ambience_state()
	var bi: Node = BattleInstanceScript.new()
	bi.name = "TestBattleInstance"
	add_child(bi)
	# 普通 Node 即可当花名册成员（add_unit 鸭子协议：无方法则跳过接线，只入列）
	for i in 3:
		bi.add_unit(Node.new(), 1)   # FACTION_ATTACKER
	for i in 2:
		bi.add_unit(Node.new(), 2)   # FACTION_DEFENDER
	_captured.clear()
	EventBus.battle_engagement_changed.connect(_on_engagement_captured)
	bi.start()
	# 开战自动暂停（TimeManager._on_battle_started）会拉起 SceneTree.paused，
	# BattleInstance 的 _physics_process 随之冻结——测试环境解除（回 X1 速度），
	# 清点节拍（0.5s 周期广播）才能继续跑
	_resume_time()
	_runner.assert_equal(int(_captured.size()), 1,
		"start() 应立即广播一次接战规模（实测 %d 次）" % _captured.size())
	if not _captured.is_empty():
		_runner.assert_equal(int(_captured[0]), 5,
			"规模初值应为双方存活总数 5（实测 %d）" % int(_captured[0]))
	# 周期续播：随胜负清点同拍（0.5s）。按物理帧等（30Hz × 40 帧 ≈ 1.33s 模拟时）
	# 而不是墙钟——headless 帧节流会让墙钟等待虚少
	for i in 40:
		await get_tree().physics_frame
	_runner.assert_gt(float(_captured.size()), 2.0,
		"40 个物理帧内应随清点节拍周期广播（实测 %d 次）" % _captured.size())
	EventBus.battle_engagement_changed.disconnect(_on_engagement_captured)
	# 收尾：退场信号让氛围层与战斗情境归位，实例即弃（测试不走完整结算）
	EventBus.battle_ended.emit(bi.get_battle_id(), true)
	bi.queue_free()


# ─────────────────────────────── 氛围层 ────────────────────────────────

func _test_lifecycle() -> void:
	_reset_ambience_state()
	_runner.assert_false(bool(MusicDirector.get_battle_ambience_report()["active"]),
		"开战前氛围层应未激活")
	EventBus.battle_started.emit("amb_test_lifecycle")
	var rep: Dictionary = MusicDirector.get_battle_ambience_report()
	_runner.assert_true(bool(rep["active"]), "battle_started 应激活氛围层")
	# 资产在位与出声一致（资产未就位：has_stream=false 且 playing=false，不报错；
	# 资产就位后此断言自动变为"应真出声"）
	_runner.assert_equal(bool(rep["playing"]), bool(rep["has_stream"]),
		"出声状态应与资产在位一致（资产缺失静默，不报错）")
	EventBus.battle_ended.emit("amb_test_lifecycle", true)
	var rep2: Dictionary = MusicDirector.get_battle_ambience_report()
	_runner.assert_false(bool(rep2["active"]), "battle_ended 应退场氛围层")
	_runner.assert_approx(float(rep2["level"]), 0.0, 0.001, "退场后目标音量应归零")


func _test_tiering() -> void:
	_reset_ambience_state()
	EventBus.battle_started.emit("amb_test_tier")
	# 大会战档（≥40）
	EventBus.battle_engagement_changed.emit("amb_test_tier", 60)
	_runner.assert_approx(float(MusicDirector.get_battle_ambience_report()["level"]),
		0.34, 0.001, "60 人应落大会战档 0.34")
	# 接战档（≥12）
	EventBus.battle_engagement_changed.emit("amb_test_tier", 20)
	_runner.assert_approx(float(MusicDirector.get_battle_ambience_report()["level"]),
		0.24, 0.001, "20 人应落接战档 0.24")
	# 小接触档（<12）
	EventBus.battle_engagement_changed.emit("amb_test_tier", 5)
	_runner.assert_approx(float(MusicDirector.get_battle_ambience_report()["level"]),
		0.15, 0.001, "5 人应落小接触档 0.15")
	# 未激活时推送应被忽略（多场战斗结束后散落的迟到信号不抬声场）
	EventBus.battle_ended.emit("amb_test_tier", true)
	EventBus.battle_engagement_changed.emit("amb_test_tier", 99)
	_runner.assert_false(bool(MusicDirector.get_battle_ambience_report()["active"]),
		"退场后推送不应重新激活")
	_runner.assert_approx(float(MusicDirector.get_battle_ambience_report()["level"]),
		0.0, 0.001, "退场后推送不应改档")
