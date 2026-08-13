extends Node
## 集成测试：编队系统（FormationSystem，原 test_stage_06 迁移）。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_formation_system.tscn
##
## 退出码：0 全部通过，1 有失败
##
## 测试覆盖：
##   - FormationSystem 装配（FormationSystem 节点挂载）
##   - create_squad 创建小队
##   - get_squad_units 查询成员 / get_unit_squad 反查
##   - assign_leader 任命排长
##   - squad_created 信号
##   - 单位换队 / 死亡单位自动清理 / disband_squad 解散
##
## 从 test_selection_formation.gd 拆分（原"编队系统测试"区块），
## 公共 setup 在 tests/helpers/combat_test_setup.gd。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const CombatTestSetup := preload("res://tests/helpers/combat_test_setup.gd")

## 测试单位数量
const UNIT_COUNT: int = 6

var _runner: TestRunner
var _helper: CombatTestSetup
var _tests: Array = []
var _formation: Node = null
## 编队信号捕获
var _squad_signal_id: String = ""
var _squad_signal_ids: Array = []


func _ready() -> void:
	_runner = TestRunner.new()
	_register_tests()
	_run_tests_async()


# ─────────────────────────────── 测试注册 ────────────────────────────────

func _register_tests() -> void:
	_tests.append({"name": "装配: FormationSystem 已注册", "fn": Callable(self, "_test_formation_assembled"), "async": false})
	_tests.append({"name": "编队: create_squad 创建小队", "fn": Callable(self, "_test_create_squad"), "async": true})
	_tests.append({"name": "编队: get_squad_units 查询成员", "fn": Callable(self, "_test_get_squad_units"), "async": true})
	_tests.append({"name": "编队: get_unit_squad 反查", "fn": Callable(self, "_test_get_unit_squad"), "async": true})
	_tests.append({"name": "编队: assign_leader 任命排长", "fn": Callable(self, "_test_assign_leader"), "async": true})
	_tests.append({"name": "编队: squad_created 信号", "fn": Callable(self, "_test_squad_signal"), "async": true})
	_tests.append({"name": "编队: 单位换队", "fn": Callable(self, "_test_unit_reassign"), "async": true})
	_tests.append({"name": "编队: 死亡单位自动清理", "fn": Callable(self, "_test_squad_dead_cleanup"), "async": true})
	_tests.append({"name": "编队: disband_squad 解散", "fn": Callable(self, "_test_disband_squad"), "async": true})


# ─────────────────────────────── 异步执行 ────────────────────────────────

func _run_tests_async() -> void:
	_helper = CombatTestSetup.new()
	await _helper.start(self)
	_formation = _helper.formation
	# 生成测试单位
	_helper.spawn_test_units(UNIT_COUNT)
	for i in 1:
		await get_tree().process_frame

	# 运行同步测试
	for t in _tests:
		if not t["async"]:
			_runner.add_test(t["name"], t["fn"])
	_runner.run()

	# 运行异步测试
	for t in _tests:
		if t["async"]:
			_runner.begin_test(t["name"])
			await t["fn"].call()
			_runner.end_test()
			print("完成: %s" % t["name"])

	var summary := _runner.summary()
	print(summary)
	var exit_code: int = 0 if _runner.all_passed() else 1
	get_tree().quit(exit_code)


# ─────────────────────────────── 同步测试 ────────────────────────────────

func _test_formation_assembled() -> void:
	_runner.assert_true(_formation != null, "FormationSystem 应已装配")
	if _formation != null:
		_runner.assert_true(_formation.get_parent() != null, "FormationSystem 应在场景树中")
		_runner.assert_equal(_formation.get_squad_count(), 0, "初始应无小队")


# ─────────────────────────────── 异步测试 ────────────────────────────────

func _test_create_squad() -> void:
	if _formation == null:
		_runner.assert_true(false, "FormationSystem 为空")
		return
	# 用 unit 1~3 创建小队
	var squad_id: String = _formation.create_squad([_helper.units[1], _helper.units[2], _helper.units[3]])
	_runner.assert_true(not squad_id.is_empty(), "应返回非空 squad_id")
	_runner.assert_equal(_formation.get_squad_count(), 1, "应有 1 个小队")
	_runner.assert_equal(_formation.get_squad_size(squad_id), 3, "小队应有 3 人")


func _test_get_squad_units() -> void:
	if _formation == null:
		_runner.assert_true(false, "FormationSystem 为空")
		return
	var squads: Array = _formation.get_all_squads()
	_runner.assert_true(not squads.is_empty(), "应至少有 1 个小队")
	if squads.is_empty():
		return
	var squad_id: String = squads[0]
	var units: Array = _formation.get_squad_units(squad_id)
	_runner.assert_equal(units.size(), 3, "小队应有 3 个成员")
	_runner.assert_true(_helper.units[1] in units, "unit 1 应在小队中")
	_runner.assert_true(_helper.units[2] in units, "unit 2 应在小队中")
	_runner.assert_true(_helper.units[3] in units, "unit 3 应在小队中")


func _test_get_unit_squad() -> void:
	if _formation == null:
		_runner.assert_true(false, "FormationSystem 为空")
		return
	var squad_id: String = _formation.get_unit_squad(_helper.units[2])
	_runner.assert_true(not squad_id.is_empty(), "unit 2 应属于某小队")
	_runner.assert_true(_formation.is_in_squad(_helper.units[2]), "is_in_squad 应为 true")
	# unit 4 不在任何小队
	var no_squad: String = _formation.get_unit_squad(_helper.units[4])
	_runner.assert_true(no_squad.is_empty(), "unit 4 不应属于任何小队")
	_runner.assert_true(not _formation.is_in_squad(_helper.units[4]), "unit 4 is_in_squad 应为 false")


func _test_assign_leader() -> void:
	if _formation == null:
		_runner.assert_true(false, "FormationSystem 为空")
		return
	var squads: Array = _formation.get_all_squads()
	if squads.is_empty():
		_runner.assert_true(false, "无小队可任命")
		return
	var squad_id: String = squads[0]
	# 任命 unit 2 为排长
	var ok: bool = _formation.assign_leader(squad_id, _helper.units[2])
	_runner.assert_true(ok, "任命排长应成功")
	var leader: Node = _formation.get_squad_leader(squad_id)
	_runner.assert_true(leader == _helper.units[2], "排长应为 unit 2")
	# 任命非小队成员应失败
	var fail: bool = _formation.assign_leader(squad_id, _helper.units[4])
	_runner.assert_true(not fail, "任命非成员应失败")


func _test_squad_signal() -> void:
	if _formation == null:
		_runner.assert_true(false, "FormationSystem 为空")
		return
	_squad_signal_id = ""
	_squad_signal_ids = []
	var conn: Callable = Callable(self, "_on_squad_created")
	_formation.squad_created.connect(conn)
	# 创建新小队
	var squad_id: String = _formation.create_squad([_helper.units[4], _helper.units[5]])
	_runner.assert_true(not squad_id.is_empty(), "应创建小队")
	_runner.assert_true(not _squad_signal_id.is_empty(), "应收到 squad_created 信号")
	_runner.assert_equal(_squad_signal_id, squad_id, "信号 squad_id 应匹配")
	_runner.assert_equal(_squad_signal_ids.size(), 2, "信号应有 2 个 unit_ids")
	_formation.squad_created.disconnect(conn)


func _on_squad_created(squad_id: String, unit_ids: Array) -> void:
	_squad_signal_id = squad_id
	_squad_signal_ids = unit_ids.duplicate()


func _test_unit_reassign() -> void:
	if _formation == null:
		_runner.assert_true(false, "FormationSystem 为空")
		return
	# 此时应有 2 个小队：squad0(unit1-3), squad1(unit4-5)
	_runner.assert_equal(_formation.get_squad_count(), 2, "应有 2 个小队")
	# 将 unit 1 从 squad0 移到 squad1
	var old_squad: String = _formation.get_unit_squad(_helper.units[1])
	_runner.assert_true(not old_squad.is_empty(), "unit 1 应在原小队中")
	var squads: Array = _formation.get_all_squads()
	# 找到另一个小队（非 unit 1 当前所在的）
	var new_squad: String = ""
	for sid in squads:
		if sid != old_squad:
			new_squad = sid
			break
	_runner.assert_true(not new_squad.is_empty(), "应找到另一个小队")
	var ok: bool = _formation.add_unit(new_squad, _helper.units[1])
	_runner.assert_true(ok, "加入新小队应成功")
	# unit 1 应在新小队，不在旧小队
	_runner.assert_equal(_formation.get_unit_squad(_helper.units[1]), new_squad, "unit 1 应已换到新小队")
	var old_units: Array = _formation.get_squad_units(old_squad)
	_runner.assert_true(_helper.units[1] not in old_units, "unit 1 不应在旧小队中")


func _test_squad_dead_cleanup() -> void:
	if _formation == null:
		_runner.assert_true(false, "FormationSystem 为空")
		return
	# 找到包含 unit 5 的小队，杀死 unit 5
	var squad_id: String = _formation.get_unit_squad(_helper.units[5])
	_runner.assert_true(not squad_id.is_empty(), "unit 5 应在小队中")
	# 杀死 unit 5
	var health: Node = _helper.units[5].get_health() if _helper.units[5].has_method("get_health") else null
	if health == null:
		_runner.assert_true(false, "unit 5 无 HealthComponent")
		return
	health.take_damage(99999.0)
	_runner.assert_true(_helper.units[5].is_dead(), "unit 5 应已死亡")
	# 等待 _process 清理
	await get_tree().process_frame
	await get_tree().process_frame
	# unit 5 应从所有小队中移除
	_runner.assert_true(_formation.get_unit_squad(_helper.units[5]).is_empty(), "死亡单位应从 squad 映射中移除")


func _test_disband_squad() -> void:
	if _formation == null:
		_runner.assert_true(false, "FormationSystem 为空")
		return
	var before_count: int = _formation.get_squad_count()
	_runner.assert_true(before_count > 0, "应有小队可解散")
	if before_count == 0:
		return
	# 解散第一个小队
	var squads: Array = _formation.get_all_squads()
	var squad_id: String = squads[0]
	# 记录成员
	var members: Array = _formation.get_squad_units(squad_id)
	_formation.disband_squad(squad_id)
	_runner.assert_equal(_formation.get_squad_count(), before_count - 1, "小队数应减 1")
	_runner.assert_true(not _formation.get_all_squads().has(squad_id), "已解散的小队不应在列表中")
	# 成员应不再属于该小队
	for u in members:
		if is_instance_valid(u) and not (u.has_method("is_dead") and u.is_dead()):
			_runner.assert_true(_formation.get_unit_squad(u).is_empty(), "解散后成员不应再属于小队")
