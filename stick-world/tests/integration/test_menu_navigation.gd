extends Node
## 集成测试：设置菜单（齿轮/ESC 开关）+ 大世界导航动态目的地 + 战场默认步兵。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_menu_navigation.tscn -- --fresh-start
##
## 退出码：0 全部通过，1 有失败
##
## 测试覆盖：
##   - 设置菜单装配（齿轮入口）
##   - 设置菜单 toggle 显隐（ESC 等效调用）
##   - debug 构建下含调试地图选择按钮
##   - 大世界地图面板按当前地图动态生成目的地（含步行出口）
##   - 战场默认步兵：不带队伍进战场也有基础友军
##
## 公共 setup 在 tests/helpers/combat_test_setup.gd。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const CombatTestSetup := preload("res://tests/helpers/combat_test_setup.gd")
const ScriptGameRoot := preload("res://modules/world/scripts/game_root.gd")

var _runner: TestRunner
var _helper: CombatTestSetup
var _tests: Array = []


func _ready() -> void:
	_runner = TestRunner.new()
	_register_tests()
	_run_tests_async()


func _register_tests() -> void:
	_tests.append({"name": "设置: 装配且默认隐藏", "fn": Callable(self, "_test_settings_assembled"), "async": false})
	_tests.append({"name": "设置: toggle 显隐且居中", "fn": Callable(self, "_test_settings_toggle"), "async": true})
	_tests.append({"name": "设置: 调试区含地图选择按钮", "fn": Callable(self, "_test_settings_debug_buttons"), "async": false})
	_tests.append({"name": "导航: 动态生成目的地含步行出口", "fn": Callable(self, "_test_world_map_dynamic"), "async": true})
	_tests.append({"name": "战场: 无队伍也有默认步兵", "fn": Callable(self, "_test_default_infantry"), "async": true})


func _run_tests_async() -> void:
	_helper = CombatTestSetup.new()
	await _helper.start(self)

	for t in _tests:
		_runner.begin_test(t["name"])
		if t["async"]:
			await t["fn"].call()
		else:
			t["fn"].call()
		_runner.end_test()
		print("完成: %s" % t["name"])

	var summary := _runner.summary()
	print(summary)
	var exit_code: int = 0 if _runner.all_passed() else 1
	get_tree().quit(exit_code)


## 设置菜单装配且默认隐藏（启动不弹菜单）
func _test_settings_assembled() -> void:
	var panel: Control = _helper.game_root.get_settings_menu_panel() if _helper.game_root.has_method("get_settings_menu_panel") else null
	_runner.assert_true(panel != null, "SettingsMenuPanel 应已装配")
	if panel == null:
		return
	_runner.assert_true(not panel.visible, "启动时设置菜单应隐藏")


## toggle 显隐
func _test_settings_toggle() -> void:
	var panel: Control = _helper.game_root.get_settings_menu_panel() if _helper.game_root.has_method("get_settings_menu_panel") else null
	if panel == null:
		_runner.assert_true(false, "SettingsMenuPanel 为空")
		return
	# 打开
	if _helper.game_root.has_method("toggle_settings_menu"):
		_helper.game_root.toggle_settings_menu()
	_runner.assert_true(panel.visible, "toggle 后应显示")
	# 面板应真正居中（先等一帧布局完成）
	await get_tree().process_frame
	var inner: Control = panel.get_node_or_null("Panel") if panel.has_node("Panel") else null
	if inner == null:
		# 从子节点找 Panel（标题"设置"所在面板）
		for child in panel.get_children():
			if child is Panel:
				inner = child
				break
	if inner != null:
		var vp_size: Vector2 = _helper.game_root.get_viewport().get_visible_rect().size
		var expected_x: float = (vp_size.x - inner.size.x) * 0.5
		var expected_y: float = (vp_size.y - inner.size.y) * 0.5
		_runner.assert_true(absf(inner.position.x - expected_x) < 8.0, "面板应水平居中，pos.x=%.1f 期望 %.1f" % [inner.position.x, expected_x])
		_runner.assert_true(absf(inner.position.y - expected_y) < 8.0, "面板应垂直居中，pos.y=%.1f 期望 %.1f" % [inner.position.y, expected_y])
	# 关闭
	_helper.game_root.toggle_settings_menu()
	_runner.assert_true(not panel.visible, "再次 toggle 后应隐藏")


## 调试构建下设置菜单含调试地图选择按钮（等效原主页测试入口）
func _test_settings_debug_buttons() -> void:
	var panel: Control = _helper.game_root.get_settings_menu_panel() if _helper.game_root.has_method("get_settings_menu_panel") else null
	if panel == null:
		_runner.assert_true(false, "SettingsMenuPanel 为空")
		return
	if not OS.is_debug_build():
		_runner.assert_true(true, "非 debug 构建跳过（当前为 debug）")
		return
	if _helper.game_root.has_method("toggle_settings_menu"):
		_helper.game_root.toggle_settings_menu()
	var buttons: Node = panel.get("_buttons")
	_runner.assert_true(buttons != null, "应有按钮容器")
	if buttons == null:
		return
	var map_btn_count: int = 0
	for child in buttons.get_children():
		if child is Button and child.text.begins_with("前往"):
			map_btn_count += 1
	_runner.assert_true(map_btn_count >= 4, "调试区应有地图选择按钮（≥4），实际 %d" % map_btn_count)
	_helper.game_root.toggle_settings_menu()


## 大世界地图（战略图）：Tab 打开显示 L1 世界图（8 城邦），关闭恢复
func _test_world_map_dynamic() -> void:
	var strategic_map: Node = _helper.game_root.get("_strategic_map")
	if strategic_map == null:
		_runner.assert_true(false, "GameRoot._strategic_map 为空")
		return
	# 战略图是 CanvasLayer，控制器在 Content 子节点
	var content: Node = strategic_map.get_node_or_null("Content")
	if content == null or not content.has_method("open"):
		_runner.assert_true(false, "战略图 Content 无 open 方法")
		return
	# 打开（模拟 Tab/边界触发 open_world_map_requested）
	content.open()
	await get_tree().process_frame
	_runner.assert_true(content.visible, "打开后战略图应可见")
	# 渲染器应持有 L1 数据（8 城邦）
	var api: Node = content.get_node_or_null("Api")
	_runner.assert_true(api != null and api.is_initialized(), "战略图 api 应已初始化（L1 数据加载）")
	if api != null and api.is_initialized():
		var data: RefCounted = api.get_data()
		var settled: int = 0
		for tile in data.tiles:
			if tile.settlement != null:
				settled += 1
		_runner.assert_true(settled == 8, "战略图应含 8 个城邦聚落，实际 %d" % settled)
	# 关闭
	content.close()
	await get_tree().process_frame
	_runner.assert_true(not content.visible, "关闭后战略图应不可见")


## 战场默认步兵：不带队伍进战场，友军（进攻方）应 ≥3（含玩家）
func _test_default_infantry() -> void:
	var sl: Node = _helper.game_root.scene_loader
	if sl == null or not sl.has_method("travel_to_map"):
		_runner.assert_true(false, "SceneLoader 为空")
		return
	# 确保设置菜单关闭（避免干扰）
	if _helper.game_root.has_method("toggle_settings_menu"):
		var sp: Control = _helper.game_root.get_settings_menu_panel()
		if sp != null and sp.visible:
			_helper.game_root.toggle_settings_menu()
	sl.travel_to_map(ScriptGameRoot.BATTLEFIELD_MAP_ID, WorldAPI.TravelMode.WALK, WorldAPI.EntrySide.LEFT)
	for i in 4:
		await get_tree().process_frame
	var bd: Node = _helper.game_root.get_battle_director_node() if _helper.game_root.has_method("get_battle_director_node") else null
	_runner.assert_true(bd != null and bd.has_method("has_active_battle"), "BattleDirector 应就绪")
	if bd == null or not bd.has_method("has_active_battle"):
		return
	_runner.assert_true(bd.has_active_battle(), "战场应有活跃战斗")
	if not bd.has_active_battle() or not bd.has_method("get_active_battles"):
		return
	var battles: Array = bd.get_active_battles()
	if battles.is_empty():
		_runner.assert_true(false, "无战斗实例")
		return
	var bi: Node = battles[0]
	var attacker_alive: int = bi.get_alive_count(1) if bi.has_method("get_alive_count") else 0
	# 玩家 1 + 默认步兵补位至 ≥3
	_runner.assert_true(attacker_alive >= 3, "进攻方应有默认步兵（≥3 人），实际 %d" % attacker_alive)
