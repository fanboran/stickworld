extends Node
## 集成测试：战术号令（TacticalOrders + CommandChain，原 test_stage_06 迁移）。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_tactical_orders.tscn
##
## 退出码：0 全部通过，1 有失败
##
## 测试覆盖：
##   - TacticalOrders / CommandChain 装配
##   - ADVANCE_ALL 下达后单位有命令
##   - 单位向目标移动
##   - HOLD_POSITION 清除移动
##   - order_issued 信号
##   - 对不存在小队下达失败
##
## 从 test_selection_formation.gd 拆分（原"号令系统测试"区块），
## 公共 setup 在 tests/helpers/combat_test_setup.gd。

const TestRunner := preload("res://tests/core/test_runner.gd")
const CombatTestSetup := preload("res://tests/helpers/combat_test_setup.gd")

## 测试单位数量
const UNIT_COUNT: int = 6

var _runner: TestRunner
var _helper: CombatTestSetup
var _tests: Array = []
var _formation: Node = null
var _tactical: Node = null
## 号令信号捕获
var _order_signal_type: int = -1
var _order_signal_squad: String = ""


func _ready() -> void:
	_runner = TestRunner.new()
	_register_tests()
	_run_tests_async()


# ─────────────────────────────── 测试注册 ────────────────────────────────

func _register_tests() -> void:
	_tests.append({"name": "装配: TacticalOrders 已注册", "fn": Callable(self, "_test_tactical_assembled"), "async": false})
	_tests.append({"name": "号令: ADVANCE_ALL 下达后单位有命令", "fn": Callable(self, "_test_order_advance"), "async": true})
	_tests.append({"name": "号令: 单位向目标移动", "fn": Callable(self, "_test_unit_moves_to_target"), "async": true})
	_tests.append({"name": "号令: HOLD_POSITION 清除移动", "fn": Callable(self, "_test_order_hold"), "async": true})
	_tests.append({"name": "号令: order_issued 信号", "fn": Callable(self, "_test_order_signal"), "async": true})
	_tests.append({"name": "号令: 对不存在小队下达失败", "fn": Callable(self, "_test_order_invalid_squad"), "async": true})


# ─────────────────────────────── 异步执行 ────────────────────────────────

func _run_tests_async() -> void:
	_helper = CombatTestSetup.new()
	await _helper.start(self)
	_formation = _helper.formation
	_tactical = _helper.tactical
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

func _test_tactical_assembled() -> void:
	_runner.assert_true(_tactical != null, "TacticalOrders 应已装配")
	if _tactical != null:
		_runner.assert_true(_tactical.get_parent() != null, "TacticalOrders 应在场景树中")
	var cc: Node = _helper.game_root.get_command_chain() if _helper.game_root != null else null
	_runner.assert_true(cc != null, "CommandChain 应已装配")


# ─────────────────────────────── 异步测试 ────────────────────────────────

## 为号令测试创建一个新小队，返回 squad_id
func _create_squad_for_orders() -> String:
	if _formation == null:
		return ""
	# 用存活单位创建新小队
	var alive_units: Array = []
	for i in [2, 3, 4]:
		if i < _helper.units.size() and is_instance_valid(_helper.units[i]):
			if not (_helper.units[i].has_method("is_dead") and _helper.units[i].is_dead()):
				alive_units.append(_helper.units[i])
	if alive_units.is_empty():
		return ""
	return _formation.create_squad(alive_units, "order_test_squad")


func _test_order_advance() -> void:
	if _tactical == null or _formation == null:
		_runner.assert_true(false, "系统未装配")
		return
	var squad_id: String = _create_squad_for_orders()
	_runner.assert_true(not squad_id.is_empty(), "应成功创建测试小队")
	if squad_id.is_empty():
		return
	# 下达前进号令（目标在右侧 500px）
	var target: Vector2 = _helper.units[2].global_position + Vector2(500, 0)
	var ok: bool = _tactical.issue(_tactical.OrderType.ADVANCE_ALL, squad_id, target)
	_runner.assert_true(ok, "ADVANCE_ALL 应成功下达")
	# 等待 command_chain 同步送达 + AI 决策周期
	await get_tree().process_frame
	await get_tree().process_frame
	# 验证单位 AIController 有命令
	var units: Array = _formation.get_squad_units(squad_id)
	for u in units:
		if not is_instance_valid(u):
			continue
		var ai: Node = u.get_ai_controller() if u.has_method("get_ai_controller") else null
		if ai != null:
			_runner.assert_true(ai.has_order(), "单位应有命令")
			_runner.assert_equal(ai.get_ordered_behavior(), "move", "命令行为应为 move")


func _test_unit_moves_to_target() -> void:
	if _tactical == null or _formation == null:
		_runner.assert_true(false, "系统未装配")
		return
	var squads: Array = _formation.get_all_squads()
	if squads.is_empty():
		_runner.assert_true(false, "无小队可测试")
		return
	var squad_id: String = squads[0]
	var units: Array = _formation.get_squad_units(squad_id)
	if units.is_empty():
		_runner.assert_true(false, "小队无成员")
		return
	# 记录初始距离
	var target: Vector2 = units[0].global_position + Vector2(800, 0)
	# 重新下达前进号令到更远目标
	_tactical.issue(_tactical.OrderType.ADVANCE_ALL, squad_id, target)
	# 记录初始位置
	var initial_positions: Dictionary = {}
	for u in units:
		if is_instance_valid(u):
			initial_positions[u.get_instance_id()] = u.global_position.distance_to(target)
	# 等待足够时间让单位移动（AI 决策 0.3s + 移动 ~1s）
	var elapsed: float = 0.0
	while elapsed < 1.5:
		await get_tree().process_frame
		elapsed += get_process_delta_time()
	# 验证至少一个单位靠近了目标
	var moved_closer: bool = false
	for u in units:
		if not is_instance_valid(u):
			continue
		var current_dist: float = u.global_position.distance_to(target)
		var initial_dist: float = initial_positions.get(u.get_instance_id(), current_dist)
		if current_dist < initial_dist - 10.0:
			moved_closer = true
			break
	_runner.assert_true(moved_closer, "至少一个单位应向目标移动（距离缩短）")


func _test_order_hold() -> void:
	if _tactical == null or _formation == null:
		_runner.assert_true(false, "系统未装配")
		return
	var squads: Array = _formation.get_all_squads()
	if squads.is_empty():
		_runner.assert_true(false, "无小队可测试")
		return
	var squad_id: String = squads[0]
	# 下达坚守号令
	var ok: bool = _tactical.issue(_tactical.OrderType.HOLD_POSITION, squad_id)
	_runner.assert_true(ok, "HOLD_POSITION 应成功下达")
	await get_tree().process_frame
	await get_tree().process_frame
	# 验证命令变为 idle
	var units: Array = _formation.get_squad_units(squad_id)
	for u in units:
		if not is_instance_valid(u):
			continue
		var ai: Node = u.get_ai_controller() if u.has_method("get_ai_controller") else null
		if ai != null:
			_runner.assert_equal(ai.get_ordered_behavior(), "idle", "命令行为应为 idle")


func _test_order_signal() -> void:
	if _tactical == null or _formation == null:
		_runner.assert_true(false, "系统未装配")
		return
	_order_signal_type = -1
	_order_signal_squad = ""
	var conn: Callable = Callable(self, "_on_order_issued")
	_tactical.order_issued.connect(conn)
	var squads: Array = _formation.get_all_squads()
	if squads.is_empty():
		_runner.assert_true(false, "无小队可测试")
		_tactical.order_issued.disconnect(conn)
		return
	var squad_id: String = squads[0]
	_tactical.issue(_tactical.OrderType.RETREAT, squad_id)
	_runner.assert_true(_order_signal_type == _tactical.OrderType.RETREAT, "信号 order_type 应为 RETREAT")
	_runner.assert_equal(_order_signal_squad, squad_id, "信号 squad_id 应匹配")
	_tactical.order_issued.disconnect(conn)


func _on_order_issued(order_type: int, target_squad_id: String, _issuer_unit_id: int) -> void:
	_order_signal_type = order_type
	_order_signal_squad = target_squad_id


func _test_order_invalid_squad() -> void:
	if _tactical == null:
		_runner.assert_true(false, "TacticalOrders 为空")
		return
	var ok: bool = _tactical.issue(_tactical.OrderType.ADVANCE_ALL, "nonexistent_squad", Vector2(1000, 0))
	_runner.assert_true(not ok, "对不存在小队下达应失败")
