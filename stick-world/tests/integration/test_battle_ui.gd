extends Node
## 集成测试：战斗 UI（BattlePanel + Minimap，原 test_stage_06 迁移）。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_battle_ui.tscn
##
## 退出码：0 全部通过，1 有失败
##
## 测试覆盖：
##   - BattlePanel 装配与框选响应
##   - Minimap 装配 / 地图信息设置 / 点击跳转相机
##
## 从 test_selection_formation.gd 拆分（原"UI 系统测试"区块），
## 公共 setup 在 tests/helpers/combat_test_setup.gd。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const CombatTestSetup := preload("res://tests/helpers/combat_test_setup.gd")

## 测试单位数量
const UNIT_COUNT: int = 6

var _runner: TestRunner
var _helper: CombatTestSetup
var _tests: Array = []
var _selection: Node = null
var _battle_panel: Control = null
var _minimap: Control = null


func _ready() -> void:
	_runner = TestRunner.new()
	_register_tests()
	_run_tests_async()


# ─────────────────────────────── 测试注册 ────────────────────────────────

func _register_tests() -> void:
	_tests.append({"name": "装配: BattlePanel 已注册", "fn": Callable(self, "_test_battle_panel_assembled"), "async": false})
	_tests.append({"name": "UI: BattlePanel 响应框选变化", "fn": Callable(self, "_test_battle_panel_selection"), "async": true})
	_tests.append({"name": "装配: Minimap 已注册", "fn": Callable(self, "_test_minimap_assembled"), "async": false})
	_tests.append({"name": "UI: Minimap 地图信息已设置", "fn": Callable(self, "_test_minimap_map_info"), "async": false})
	_tests.append({"name": "UI: Minimap 点击跳转相机", "fn": Callable(self, "_test_minimap_jump"), "async": true})


# ─────────────────────────────── 异步执行 ────────────────────────────────

func _run_tests_async() -> void:
	_helper = CombatTestSetup.new()
	await _helper.start(self)
	_selection = _helper.selection
	_battle_panel = _helper.battle_panel
	_minimap = _helper.minimap
	# 生成测试单位（框选响应测试需要）
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

func _test_battle_panel_assembled() -> void:
	_runner.assert_true(_battle_panel != null, "BattlePanel 应已装配")
	if _battle_panel == null:
		return
	_runner.assert_true(_battle_panel.get_parent() != null, "BattlePanel 应在场景树中")
	# 验证 setup 已调用（HBox 应存在）
	var hbox: Node = _battle_panel.get_node_or_null("HBox")
	_runner.assert_true(hbox != null, "BattlePanel UI 应已构建（HBox 存在）")


func _test_minimap_assembled() -> void:
	_runner.assert_true(_minimap != null, "Minimap 应已装配")
	if _minimap == null:
		return
	_runner.assert_true(_minimap.get_parent() != null, "Minimap 应在场景树中")
	_runner.assert_equal(_minimap.get_parent().name, "HudOverlay", "Minimap 应挂在 HudOverlay 槽下")


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


# ─────────────────────────────── 异步测试 ────────────────────────────────

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
	var rect := _helper.rect_for_units([2, 3, 4], 25.0)
	_selection.box_select(rect, false)
	await get_tree().process_frame
	# 验证 BattlePanel 更新了选中数量
	if sel_label != null:
		_runner.assert_true(sel_label.text.findn("3") >= 0, "框选 3 人后应显示 3 人")
	# 清空
	_selection.clear_selection()


func _test_minimap_jump() -> void:
	if _minimap == null or _helper.game_root == null:
		_runner.assert_true(false, "Minimap 或 GameRoot 为空")
		return
	var cam: Node = _helper.game_root.camera_rig
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
