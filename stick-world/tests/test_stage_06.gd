extends Node
## 阶段 0.6 编队与指挥 -- 第一步：框选系统（SelectionSystem）集成测试。
##
## 运行：
##   godot --headless --path stick-world res://tests/test_stage_06.tscn
##
## 退出码：0 全部通过，1 有失败
##
## 测试覆盖：
##   - SelectionSystem 装配（挂在 UIRoot 下，注册为 BATTLE handler）
##   - BATTLE 模式激活后 SelectionSystem.is_active() == true
##   - box_select：世界矩形内的单位被选中
##   - 追加选择（additive=true）
##   - click_select：单击选中最近单位
##   - clear_selection：清空选择
##   - selection_changed 信号正确发射
##   - 阵营过滤（set_selectable_faction）
##   - 死亡单位自动移除

const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptStickmanEntity := preload("res://modules/units/scripts/stickman_entity.gd")
const STICKMAN_SCENE: PackedScene = preload("res://modules/units/scenes/stickman_entity.tscn")

# ─────────────────────────────── 测试配置 ────────────────────────────────
## 测试单位起始 X
const UNIT_X_START: float = 1500.0
## 测试单位间距
const UNIT_SPACING: float = 80.0
## 测试单位数量
const UNIT_COUNT: int = 6

var _runner: TestRunner
var _game_root: Node
var _tests: Array = []
var _selection: Node = null
var _map: Node2D = null
var _test_units: Array = []
## 信号捕获
var _signal_received: bool = false
var _signal_ids: Array = []


func _ready() -> void:
	_runner = TestRunner.new()
	_register_tests()
	_run_tests_async()


# ─────────────────────────────── 测试注册 ────────────────────────────────

func _register_tests() -> void:
	_tests.append({"name": "装配: SelectionSystem 已注册", "fn": Callable(self, "_test_selection_assembled"), "async": false})
	_tests.append({"name": "激活: BATTLE 模式后 is_active", "fn": Callable(self, "_test_selection_active"), "async": false})
	_tests.append({"name": "框选: 矩形内单位被选中", "fn": Callable(self, "_test_box_select"), "async": true})
	_tests.append({"name": "框选: 追加选择(additive)", "fn": Callable(self, "_test_additive_select"), "async": true})
	_tests.append({"name": "单击: 选中最近单位", "fn": Callable(self, "_test_click_select"), "async": true})
	_tests.append({"name": "清空: clear_selection", "fn": Callable(self, "_test_clear_selection"), "async": true})
	_tests.append({"name": "信号: selection_changed 发射", "fn": Callable(self, "_test_signal_emitted"), "async": true})
	_tests.append({"name": "过滤: 阵营过滤生效", "fn": Callable(self, "_test_faction_filter"), "async": true})
	_tests.append({"name": "清理: 死亡单位自动移除", "fn": Callable(self, "_test_dead_unit_removed"), "async": true})


# ─────────────────────────────── 异步执行 ────────────────────────────────

func _run_tests_async() -> void:
	var packed := load("res://modules/world/scenes/game_root.tscn") as PackedScene
	if packed == null:
		print("[FATAL] 无法加载 game_root.tscn")
		get_tree().quit(1)
		return
	_game_root = packed.instantiate()
	_game_root.set("auto_demo_building", false)
	add_child(_game_root)
	# 等待地图加载和实体生成
	for i in 8:
		await get_tree().process_frame
	# 取消玩家附身（避免干扰）
	_unpossess_player()
	# 切到 BATTLE 模式激活 SelectionSystem
	var dispatcher: Node = _game_root.input_dispatcher
	if dispatcher != null:
		dispatcher.set_mode(PlayerControlAPI.Mode.BATTLE)
	for i in 2:
		await get_tree().process_frame
	_selection = _game_root.get_selection_system()
	_map = _game_root.get_current_map()
	# 生成测试单位
	_spawn_test_units()
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
			_write_log("完成: %s" % t["name"])

	var summary := _runner.summary()
	print(summary)
	var f := FileAccess.open("f:/VSCode/game-2/stick-world/test_stage_06_result.txt", FileAccess.WRITE)
	if f != null:
		f.store_string(summary + "\n")
		f.store_string("EXIT_CODE=%d\n" % (0 if _runner.all_passed() else 1))
		f.close()
	var exit_code: int = 0 if _runner.all_passed() else 1
	get_tree().quit(exit_code)


func _write_log(msg: String) -> void:
	var f := FileAccess.open("f:/VSCode/game-2/stick-world/test_stage_06_result.txt", FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open("f:/VSCode/game-2/stick-world/test_stage_06_result.txt", FileAccess.WRITE)
	if f != null:
		f.seek_end()
		f.store_string(msg + "\n")
		f.close()


# ─────────────────────────────── 辅助 ────────────────────────────────

func _unpossess_player() -> void:
	if _map == null:
		return
	for e in _map.get_entities():
		if e is ScriptStickmanEntity and e.has_method("is_possessed") and e.is_possessed():
			e.set_possessed(false)


func _spawn_test_units() -> void:
	var spawn_y: float = _map.ground_y + (_map.ground_bottom - _map.ground_y) * 0.5
	for i in UNIT_COUNT:
		var x: float = UNIT_X_START + i * UNIT_SPACING
		var e: Node2D = _map.spawn_entity(STICKMAN_SCENE, Vector2(x, spawn_y))
		if e == null:
			continue
		# 修正 Y：脚部对齐
		if e.get("foot_offset") != null:
			e.global_position.y = spawn_y - e.foot_offset
		if e.has_method("set_possessed"):
			e.set_possessed(false)
		_test_units.append(e)


## 包含指定下标单位的最小世界矩形（带 padding）
func _rect_for_units(indices: Array, padding: float = 25.0) -> Rect2:
	var min_x: float = INF
	var max_x: float = -INF
	var min_y: float = INF
	var max_y: float = -INF
	for i in indices:
		if i >= _test_units.size():
			continue
		var u: Node2D = _test_units[i]
		if not is_instance_valid(u):
			continue
		var p: Vector2 = u.global_position
		min_x = minf(min_x, p.x)
		max_x = maxf(max_x, p.x)
		min_y = minf(min_y, p.y)
		max_y = maxf(max_y, p.y)
	return Rect2(min_x - padding, min_y - padding, (max_x - min_x) + padding * 2.0, (max_y - min_y) + padding * 2.0)


# ─────────────────────────────── 同步测试 ────────────────────────────────

func _test_selection_assembled() -> void:
	_runner.assert_true(_selection != null, "SelectionSystem 应已装配")
	if _selection != null:
		_runner.assert_true(_selection.get_parent() != null, "SelectionSystem 应在场景树中")
		_runner.assert_equal(_selection.get_parent().name, "UIRoot", "应挂在 UIRoot 下")


func _test_selection_active() -> void:
	if _selection == null:
		_runner.assert_true(false, "SelectionSystem 为空")
		return
	_runner.assert_true(_selection.is_active(), "BATTLE 模式下应 is_active() == true")


# ─────────────────────────────── 异步测试 ────────────────────────────────

func _test_box_select() -> void:
	if _selection == null:
		_runner.assert_true(false, "SelectionSystem 为空")
		return
	_selection.clear_selection()
	# 框选 unit 1~3
	var rect := _rect_for_units([1, 2, 3])
	var selected: Array = _selection.box_select(rect, false)
	_runner.assert_true(selected.size() == 3, "应选中 3 个单位，实际 %d" % selected.size())
	_runner.assert_equal(_selection.get_selected_count(), 3, "get_selected_count 应为 3")
	# 验证选中的确实是 unit 1~3
	for i in [1, 2, 3]:
		_runner.assert_true(_selection.is_selected(_test_units[i]), "unit %d 应被选中" % i)
	# unit 0 和 4 不应被选中
	_runner.assert_true(not _selection.is_selected(_test_units[0]), "unit 0 不应被选中")
	_runner.assert_true(not _selection.is_selected(_test_units[4]), "unit 4 不应被选中")


func _test_additive_select() -> void:
	if _selection == null:
		_runner.assert_true(false, "SelectionSystem 为空")
		return
	_selection.clear_selection()
	# 先选 unit 0
	var rect0 := _rect_for_units([0], 15.0)
	_selection.box_select(rect0, false)
	_runner.assert_equal(_selection.get_selected_count(), 1, "先选 1 个")
	# 追加选 unit 5
	var rect5 := _rect_for_units([5], 15.0)
	_selection.box_select(rect5, true)  # additive
	_runner.assert_equal(_selection.get_selected_count(), 2, "追加后应为 2 个")
	_runner.assert_true(_selection.is_selected(_test_units[0]), "unit 0 应被选中")
	_runner.assert_true(_selection.is_selected(_test_units[5]), "unit 5 应被选中")


func _test_click_select() -> void:
	if _selection == null:
		_runner.assert_true(false, "SelectionSystem 为空")
		return
	_selection.clear_selection()
	# 点击 unit 2 的位置
	var pos: Vector2 = _test_units[2].global_position
	var ok: bool = _selection.click_select(pos, false)
	_runner.assert_true(ok, "应选中一个单位")
	_runner.assert_equal(_selection.get_selected_count(), 1, "应只有 1 个")
	_runner.assert_true(_selection.is_selected(_test_units[2]), "应选中 unit 2")
	# 点击空地
	var empty_pos := Vector2(pos.x, pos.y - 5000.0)  # 远离任何单位
	_selection.click_select(empty_pos, false)
	_runner.assert_equal(_selection.get_selected_count(), 0, "点击空地应清空")


func _test_clear_selection() -> void:
	if _selection == null:
		_runner.assert_true(false, "SelectionSystem 为空")
		return
	# 先选一些
	_selection.select_units([_test_units[0], _test_units[1]], false)
	_runner.assert_equal(_selection.get_selected_count(), 2, "先选 2 个")
	_selection.clear_selection()
	_runner.assert_equal(_selection.get_selected_count(), 0, "清空后应为 0")
	# 再次清空（空选择）不应报错
	_selection.clear_selection()
	_runner.assert_equal(_selection.get_selected_count(), 0, "二次清空仍为 0")


func _test_signal_emitted() -> void:
	if _selection == null:
		_runner.assert_true(false, "SelectionSystem 为空")
		return
	_selection.clear_selection()
	_signal_received = false
	_signal_ids = []
	# 连接信号
	var conn: Callable = Callable(self, "_on_selection_changed")
	_selection.selection_changed.connect(conn)
	# 选中 unit 0
	_selection.select_unit(_test_units[0], false)
	# 信号是同步发射的，应已收到
	_runner.assert_true(_signal_received, "应收到 selection_changed 信号")
	_runner.assert_equal(_signal_ids.size(), 1, "信号参数应有 1 个 id")
	_runner.assert_equal(_signal_ids[0], _test_units[0].get_instance_id(), "id 应匹配 unit 0")
	_selection.selection_changed.disconnect(conn)


func _on_selection_changed(unit_ids: Array) -> void:
	_signal_received = true
	_signal_ids = unit_ids.duplicate()


func _test_faction_filter() -> void:
	if _selection == null:
		_runner.assert_true(false, "SelectionSystem 为空")
		return
	_selection.clear_selection()
	# 设置 unit 0~2 为阵营 1，unit 3~5 为阵营 2
	for i in [0, 1, 2]:
		if _test_units[i].has_method("set_faction"):
			_test_units[i].set_faction(1)
	for i in [3, 4, 5]:
		if _test_units[i].has_method("set_faction"):
			_test_units[i].set_faction(2)
	# 限制只选阵营 1
	_selection.set_selectable_faction(1)
	# 框选所有单位
	var rect := _rect_for_units([0, 1, 2, 3, 4, 5], 30.0)
	var selected: Array = _selection.box_select(rect, false)
	_runner.assert_equal(selected.size(), 3, "阵营过滤后应只选 3 个（阵营1）")
	for i in [0, 1, 2]:
		_runner.assert_true(_selection.is_selected(_test_units[i]), "unit %d (阵营1) 应被选中" % i)
	for i in [3, 4, 5]:
		_runner.assert_true(not _selection.is_selected(_test_units[i]), "unit %d (阵营2) 不应被选中" % i)
	# 恢复
	_selection.set_selectable_faction(0)


func _test_dead_unit_removed() -> void:
	if _selection == null:
		_runner.assert_true(false, "SelectionSystem 为空")
		return
	_selection.clear_selection()
	# 选中 unit 0
	_selection.select_unit(_test_units[0], false)
	_runner.assert_equal(_selection.get_selected_count(), 1, "先选 1 个")
	# 杀死 unit 0
	var health: Node = _test_units[0].get_health() if _test_units[0].has_method("get_health") else null
	if health == null:
		_runner.assert_true(false, "unit 0 无 HealthComponent")
		return
	health.take_damage(99999.0)  # 一击必杀
	_runner.assert_true(_test_units[0].is_dead(), "unit 0 应已死亡")
	# 等待 _process 清理（SelectionSystem._process 每帧检查死亡单位）
	await get_tree().process_frame
	await get_tree().process_frame
	_runner.assert_equal(_selection.get_selected_count(), 0, "死亡单位应自动从选择中移除")
