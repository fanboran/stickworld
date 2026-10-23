extends Node
## 集成测试：sim↔单位 AI 树序契约（战斗架构审计 §三5 / 行动序条目6）。
## 契约：BattleInstance._physics_process 先 sim.tick，再由各单位节点读位置写
## 意图。原状是隐式树序契约（BattleAnchor 与单位节点的处理顺序由树序决定，
## 场景结构调整即静默改变时序语义）；现行契约 = BattleInstance.setup() 把
## 实例固化到负优先组（process_physics_priority = SIM_FIRST_PRIORITY，
## 先于一切默认 0 优先组节点，Godot 处理序：优先级升序 → 同级树序）。
## 断言两面：①优先级已固化；②行为面——战斗实例放在树序**最末**（最不利
## 布阵），默认优先级探针（单位侧替身）每物理帧仍读到"本刻已推进一拍"的
## 战斗时长（若 sim 后行，探针首帧起恒滞后一拍）。
## 进程级套件（需真物理帧推进），不进 batch_runner unit 批量。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_sim_tree_order.tscn
## 退出码：0 全部通过，1 有失败

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptBattleInstance := preload("res://modules/combat/scripts/battle/battle_instance.gd")

var _runner: TestRunner


## 单位侧探针（默认优先组 = 单位节点的处理组）：逐物理帧记录战斗时长快照
class ProbeNode:
	extends Node
	var battle: Node = null
	var durations: Array = []

	func _physics_process(_delta: float) -> void:
		if battle != null and is_instance_valid(battle):
			durations.append(float(battle.get_duration()))


## 参战假单位（防 _check_victory 首拍 0v0 判 DRAW 收场——战斗实例须存活全程）
class FakeCombatant:
	extends Node2D
	var faction_id: int = 0

	func set_faction(fid: int) -> void:
		faction_id = fid

	func set_battle_instance(_bi: Node) -> void:
		pass

	func is_dead() -> bool:
		return false


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("树序契约: setup 固化负优先组", _test_priority_pinned)
	_runner.add_test("树序契约: 树序最末仍 sim 先行", _test_sim_first, true)
	await _runner.run_async()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _test_priority_pinned() -> void:
	var map := Node2D.new()
	add_child(map)  # CoverSystem.setup 经 map.get_tree() 扫描掩体组，须在树
	var bi: Node = ScriptBattleInstance.new()
	bi.setup(map)
	_runner.assert_equal(bi.process_physics_priority, ScriptBattleInstance.SIM_FIRST_PRIORITY,
			"setup 应把实例固化到负优先组（SIM_FIRST_PRIORITY）")
	_runner.assert_true(ScriptBattleInstance.SIM_FIRST_PRIORITY < 0,
			"契约常量须为负（先于一切默认 0 优先组）")
	bi.free()
	map.free()


func _test_sim_first() -> void:
	var map := Node2D.new()
	add_child(map)
	# 最不利布阵：探针（单位侧，默认优先组）先进树，战斗实例最后进树——
	# 若契约仍靠树序（同级树序先到先跑），探针会先于 sim 推进读到滞后一拍的时长
	var probe := ProbeNode.new()
	probe.name = "UnitProbe"
	add_child(probe)
	var bi: Node = ScriptBattleInstance.new()
	bi.name = "BattleInstanceLastInTree"
	bi.setup(map)
	# 双方各一假单位：无指挥官、无伤亡 → 战斗全程存活（胜负清点不触发）
	bi.add_unit(FakeCombatant.new(), 1)
	bi.add_unit(FakeCombatant.new(), 2)
	add_child(bi)
	bi.start()
	# TimeManager「战斗自动暂停」（game/auto_pause_battle 默认开）会随
	# battle_started 把 SceneTree.paused 拉起——测试环境解除（回 X1 速度），
	# 物理帧恢复推进后探针才有采样
	var tm: Node = get_node_or_null("/root/TimeManager")
	if tm != null and "set_speed" in tm and "Speed" in tm:
		tm.set_speed(tm.Speed.X1)
	probe.battle = bi
	# 固定仿真采样窗（有界 12 物理帧）：断言的是"逐帧采样序列"本身（首帧读数、
	# 相邻帧恒定增量），窗口长度即采样样本数——不是就绪等待，无谓词可条件化
	for i in 12:
		await get_tree().physics_frame
	var durs: Array = probe.durations
	_runner.assert_true(durs.size() >= 10, "探针应逐帧采样（实际 %d 帧）" % durs.size())
	# 首帧读数 > 0：sim 已在本刻先推进一拍（sim 后行则首帧读数为 0）
	_runner.assert_true(float(durs[0]) > 0.0, "首帧即读到已推进的时长（sim 先行于单位侧）")
	# 每帧恰推进一拍：任意相邻两帧差恒定且 > 0（sim 每物理帧先于探针各跑一拍）
	var step: float = float(durs[1]) - float(durs[0])
	_runner.assert_true(step > 0.0, "相邻帧时长应有正增量")
	for i in range(1, durs.size()):
		var s: float = float(durs[i]) - float(durs[i - 1])
		_runner.assert_approx(s, step, 1.0e-4,
				"每物理帧恰推进一拍（帧 %d 增量 %.5f ≠ %.5f）" % [i, s, step])
	probe.free()
	bi.queue_free()
