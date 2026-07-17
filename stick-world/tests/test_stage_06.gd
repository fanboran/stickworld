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
var _formation: Node = null
var _tactical: Node = null
var _map: Node2D = null
var _test_units: Array = []
## 信号捕获
var _signal_received: bool = false
var _signal_ids: Array = []
## 编队信号捕获
var _squad_signal_id: String = ""
var _squad_signal_ids: Array = []
## 号令信号捕获
var _order_signal_type: int = -1
var _order_signal_squad: String = ""
## BattlePanel / Minimap 引用
var _battle_panel: Control = null
var _minimap: Control = null


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
	# 编队系统测试（unit 0 在上面的测试中被杀死，编队测试使用 unit 1~5）
	_tests.append({"name": "装配: FormationSystem 已注册", "fn": Callable(self, "_test_formation_assembled"), "async": false})
	_tests.append({"name": "编队: create_squad 创建小队", "fn": Callable(self, "_test_create_squad"), "async": true})
	_tests.append({"name": "编队: get_squad_units 查询成员", "fn": Callable(self, "_test_get_squad_units"), "async": true})
	_tests.append({"name": "编队: get_unit_squad 反查", "fn": Callable(self, "_test_get_unit_squad"), "async": true})
	_tests.append({"name": "编队: assign_leader 任命排长", "fn": Callable(self, "_test_assign_leader"), "async": true})
	_tests.append({"name": "编队: squad_created 信号", "fn": Callable(self, "_test_squad_signal"), "async": true})
	_tests.append({"name": "编队: 单位换队", "fn": Callable(self, "_test_unit_reassign"), "async": true})
	_tests.append({"name": "编队: 死亡单位自动清理", "fn": Callable(self, "_test_squad_dead_cleanup"), "async": true})
	_tests.append({"name": "编队: disband_squad 解散", "fn": Callable(self, "_test_disband_squad"), "async": true})
	# 号令系统测试（unit 0/5 已死亡，使用 unit 2/3/4）
	_tests.append({"name": "装配: TacticalOrders 已注册", "fn": Callable(self, "_test_tactical_assembled"), "async": false})
	_tests.append({"name": "号令: ADVANCE_ALL 下达后单位有命令", "fn": Callable(self, "_test_order_advance"), "async": true})
	_tests.append({"name": "号令: 单位向目标移动", "fn": Callable(self, "_test_unit_moves_to_target"), "async": true})
	_tests.append({"name": "号令: HOLD_POSITION 清除移动", "fn": Callable(self, "_test_order_hold"), "async": true})
	_tests.append({"name": "号令: order_issued 信号", "fn": Callable(self, "_test_order_signal"), "async": true})
	_tests.append({"name": "号令: 对不存在小队下达失败", "fn": Callable(self, "_test_order_invalid_squad"), "async": true})
	# UI 系统测试（BattlePanel + Minimap）
	_tests.append({"name": "装配: BattlePanel 已注册", "fn": Callable(self, "_test_battle_panel_assembled"), "async": false})
	_tests.append({"name": "UI: BattlePanel 响应框选变化", "fn": Callable(self, "_test_battle_panel_selection"), "async": true})
	_tests.append({"name": "装配: Minimap 已注册", "fn": Callable(self, "_test_minimap_assembled"), "async": false})
	_tests.append({"name": "UI: Minimap 地图信息已设置", "fn": Callable(self, "_test_minimap_map_info"), "async": false})
	_tests.append({"name": "UI: Minimap 点击跳转相机", "fn": Callable(self, "_test_minimap_jump"), "async": true})


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
	_formation = _game_root.get_formation_system()
	_tactical = _game_root.get_tactical_orders()
	_map = _game_root.get_current_map()
	_battle_panel = _game_root.get_battle_panel()
	_minimap = _game_root.get_minimap()
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


# ═══════════════════════════════════════════════════════════════════════
# 编队系统测试（unit 0 已死亡，使用 unit 1~5）
# ═══════════════════════════════════════════════════════════════════════

func _test_formation_assembled() -> void:
	_runner.assert_true(_formation != null, "FormationSystem 应已装配")
	if _formation != null:
		_runner.assert_true(_formation.get_parent() != null, "FormationSystem 应在场景树中")
		_runner.assert_equal(_formation.get_squad_count(), 0, "初始应无小队")


func _test_create_squad() -> void:
	if _formation == null:
		_runner.assert_true(false, "FormationSystem 为空")
		return
	# 用 unit 1~3 创建小队
	var squad_id: String = _formation.create_squad([_test_units[1], _test_units[2], _test_units[3]])
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
	_runner.assert_true(_test_units[1] in units, "unit 1 应在小队中")
	_runner.assert_true(_test_units[2] in units, "unit 2 应在小队中")
	_runner.assert_true(_test_units[3] in units, "unit 3 应在小队中")


func _test_get_unit_squad() -> void:
	if _formation == null:
		_runner.assert_true(false, "FormationSystem 为空")
		return
	var squad_id: String = _formation.get_unit_squad(_test_units[2])
	_runner.assert_true(not squad_id.is_empty(), "unit 2 应属于某小队")
	_runner.assert_true(_formation.is_in_squad(_test_units[2]), "is_in_squad 应为 true")
	# unit 4 不在任何小队
	var no_squad: String = _formation.get_unit_squad(_test_units[4])
	_runner.assert_true(no_squad.is_empty(), "unit 4 不应属于任何小队")
	_runner.assert_true(not _formation.is_in_squad(_test_units[4]), "unit 4 is_in_squad 应为 false")


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
	var ok: bool = _formation.assign_leader(squad_id, _test_units[2])
	_runner.assert_true(ok, "任命排长应成功")
	var leader: Node = _formation.get_squad_leader(squad_id)
	_runner.assert_true(leader == _test_units[2], "排长应为 unit 2")
	# 任命非小队成员应失败
	var fail: bool = _formation.assign_leader(squad_id, _test_units[4])
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
	var squad_id: String = _formation.create_squad([_test_units[4], _test_units[5]])
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
	var old_squad: String = _formation.get_unit_squad(_test_units[1])
	_runner.assert_true(not old_squad.is_empty(), "unit 1 应在原小队中")
	var squads: Array = _formation.get_all_squads()
	# 找到另一个小队（非 unit 1 当前所在的）
	var new_squad: String = ""
	for sid in squads:
		if sid != old_squad:
			new_squad = sid
			break
	_runner.assert_true(not new_squad.is_empty(), "应找到另一个小队")
	var ok: bool = _formation.add_unit(new_squad, _test_units[1])
	_runner.assert_true(ok, "加入新小队应成功")
	# unit 1 应在新小队，不在旧小队
	_runner.assert_equal(_formation.get_unit_squad(_test_units[1]), new_squad, "unit 1 应已换到新小队")
	var old_units: Array = _formation.get_squad_units(old_squad)
	_runner.assert_true(_test_units[1] not in old_units, "unit 1 不应在旧小队中")


func _test_squad_dead_cleanup() -> void:
	if _formation == null:
		_runner.assert_true(false, "FormationSystem 为空")
		return
	# 找到包含 unit 5 的小队，杀死 unit 5
	var squad_id: String = _formation.get_unit_squad(_test_units[5])
	_runner.assert_true(not squad_id.is_empty(), "unit 5 应在小队中")
	var before_size: int = _formation.get_squad_size(squad_id)
	# 杀死 unit 5
	var health: Node = _test_units[5].get_health() if _test_units[5].has_method("get_health") else null
	if health == null:
		_runner.assert_true(false, "unit 5 无 HealthComponent")
		return
	health.take_damage(99999.0)
	_runner.assert_true(_test_units[5].is_dead(), "unit 5 应已死亡")
	# 等待 _process 清理
	await get_tree().process_frame
	await get_tree().process_frame
	# unit 5 应从所有小队中移除
	_runner.assert_true(_formation.get_unit_squad(_test_units[5]).is_empty(), "死亡单位应从 squad 映射中移除")


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


# ═══════════════════════════════════════════════════════════════════════
# 号令系统测试（unit 0/5 已死亡，使用 unit 2/3/4）
# ═══════════════════════════════════════════════════════════════════════

## 为号令测试创建一个新小队，返回 squad_id
func _create_squad_for_orders() -> String:
	if _formation == null:
		return ""
	# 用存活单位创建新小队
	var alive_units: Array = []
	for i in [2, 3, 4]:
		if i < _test_units.size() and is_instance_valid(_test_units[i]):
			if not (_test_units[i].has_method("is_dead") and _test_units[i].is_dead()):
				alive_units.append(_test_units[i])
	if alive_units.is_empty():
		return ""
	return _formation.create_squad(alive_units, "order_test_squad")


func _test_tactical_assembled() -> void:
	_runner.assert_true(_tactical != null, "TacticalOrders 应已装配")
	if _tactical != null:
		_runner.assert_true(_tactical.get_parent() != null, "TacticalOrders 应在场景树中")
	var cc: Node = _game_root.get_command_chain() if _game_root != null else null
	_runner.assert_true(cc != null, "CommandChain 应已装配")


func _test_order_advance() -> void:
	if _tactical == null or _formation == null:
		_runner.assert_true(false, "系统未装配")
		return
	var squad_id: String = _create_squad_for_orders()
	_runner.assert_true(not squad_id.is_empty(), "应成功创建测试小队")
	if squad_id.is_empty():
		return
	# 下达前进号令（目标在右侧 500px）
	var target: Vector2 = _test_units[2].global_position + Vector2(500, 0)
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


# ═══════════════════════════════════════════════════════════════════════
# UI 系统测试（BattlePanel + Minimap）
# ═══════════════════════════════════════════════════════════════════════

func _test_battle_panel_assembled() -> void:
	_runner.assert_true(_battle_panel != null, "BattlePanel 应已装配")
	if _battle_panel == null:
		return
	_runner.assert_true(_battle_panel.get_parent() != null, "BattlePanel 应在场景树中")
	# 验证 setup 已调用（_selection_label 应存在）
	var label: Label = _battle_panel.get_node_or_null("HBox")
	_runner.assert_true(label != null, "BattlePanel UI 应已构建（HBox 存在）")


func _test_battle_panel_selection() -> void:
	if _battle_panel == null or _selection == null:
		_runner.assert_true(false, "BattlePanel 或 SelectionSystem 为空")
		return
	# 清空选择
	_selection.clear_selection()
	await get_tree().process_frame
	# 验证初始状态：选中 0 人
	var sel_label: Label = _battle_panel.get("_selection_label") if _battle_panel.get("_selection_label") != null else null
	if sel_label != null:
		_runner.assert_true(sel_label.text.findn("0") >= 0, "初始应显示 0 人")
	# 选中 3 个单位
	var rect := _rect_for_units([2, 3, 4], 25.0)
	_selection.box_select(rect, false)
	await get_tree().process_frame
	# 验证 BattlePanel 更新了选中数量
	if sel_label != null:
		_runner.assert_true(sel_label.text.findn("3") >= 0, "框选 3 人后应显示 3 人")
	# 清空
	_selection.clear_selection()


func _test_minimap_assembled() -> void:
	_runner.assert_true(_minimap != null, "Minimap 应已装配")
	if _minimap == null:
		return
	_runner.assert_true(_minimap.get_parent() != null, "Minimap 应在场景树中")
	_runner.assert_equal(_minimap.get_parent().name, "UIRoot", "Minimap 应挂在 UIRoot 下")


func _test_minimap_map_info() -> void:
	if _minimap == null:
		_runner.assert_true(false, "Minimap 为空")
		return
	# 验证地图信息已设置（_has_map_info 应为 true）
	var has_info: bool = _minimap.get("_has_map_info") if _minimap.get("_has_map_info") != null else false
	_runner.assert_true(has_info, "Minimap 地图信息应已设置")
	# 验证坐标映射：小地图中点应对应地图中点
	var map_left: float = _minimap.get("_map_left")
	var map_right: float = _minimap.get("_map_right")
	var map_w: float = map_right - map_left
	var minimap_w: float = _minimap.get("MAP_WIDTH")
	# 小地图 X = MAP_WIDTH/2 对应世界 X = map_left + map_w/2
	var world_x: float = _minimap._minimap_to_world_x(minimap_w * 0.5)
	var expected_x: float = map_left + map_w * 0.5
	_runner.assert_true(absf(world_x - expected_x) < 1.0, "小地图中点应映射到地图中点")


func _test_minimap_jump() -> void:
	if _minimap == null or _game_root == null:
		_runner.assert_true(false, "Minimap 或 GameRoot 为空")
		return
	var cam: Node = _game_root.camera_rig
	if cam == null:
		_runner.assert_true(false, "CameraRig 为空")
		return
	# 记录当前相机 X
	var cam_x_before: float = cam.global_position.x
	# 通过小地图跳转到地图右侧（小地图 X = 80% 处）
	var minimap_w: float = _minimap.get("MAP_WIDTH")
	_minimap._jump_to_mouse(Vector2(minimap_w * 0.8, 10.0))
	await get_tree().process_frame
	# 验证相机 X 已变化
	var cam_x_after: float = cam.global_position.x
	_runner.assert_true(absf(cam_x_after - cam_x_before) > 10.0, "小地图跳转后相机 X 应变化")
	# 验证相机进入了手动控制模式（jump_to_x 会设置 _manual_active）
	var manual: bool = cam.get("_manual_active") if cam.get("_manual_active") != null else false
	_runner.assert_true(manual, "跳转后相机应进入手动控制模式")
