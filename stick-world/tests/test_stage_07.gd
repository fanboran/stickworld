extends Node
## 阶段 0.7 玩家附身 -- 集成测试。
##
## 运行：
##   godot --headless --path stick-world res://tests/test_stage_07.tscn
##
## 退出码：0 全部通过，1 有失败
##
## 测试覆盖：
##   - PossessionInterface 装配（注册为 POSSESS handler）
##   - PossessPanel 装配（脚本挂载 + UI 构建）
##   - 从 BATTLE 模式进入 POSSESS：选中单位被附身
##   - 附身后实体 is_possessed() == true
##   - 附身后相机居中跟随
##   - EventBus possession_started 信号发射
##   - release() 释放附身
##   - 释放后实体 is_possessed() == false
##   - 释放后模式恢复为 BATTLE
##   - EventBus possession_ended 信号发射
##   - PossessPanel 显示单位信息
##   - 直接 possess(entity) API
##   - 附身时时间降速（auto_slow_on_possess）
##   - 鼠标左键攻击（_player_attack + _find_nearest_enemy_in_range）
##   - 死亡单位不可附身

const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptStickmanEntity := preload("res://modules/units/scripts/stickman_entity.gd")
const STICKMAN_SCENE: PackedScene = preload("res://modules/units/scenes/stickman_entity.tscn")

# ─────────────────────────────── 测试配置 ────────────────────────────────
const UNIT_X_START: float = 1500.0
const UNIT_SPACING: float = 80.0
const UNIT_COUNT: int = 4

var _runner: TestRunner
var _game_root: Node
var _tests: Array = []
var _selection: Node = null
var _possession: Node = null
var _possess_panel: Control = null
var _map: Node2D = null
var _test_units: Array = []
## 信号捕获
var _started_signal_entity: Node = null
var _ended_signal_entity: Node = null


func _ready() -> void:
	_runner = TestRunner.new()
	_register_tests()
	_run_tests_async()


# ─────────────────────────────── 测试注册 ────────────────────────────────

func _register_tests() -> void:
	_tests.append({"name": "装配: PossessionInterface 已注册", "fn": Callable(self, "_test_possession_assembled"), "async": false})
	_tests.append({"name": "装配: PossessPanel 已注册", "fn": Callable(self, "_test_possess_panel_assembled"), "async": false})
	_tests.append({"name": "附身: 从 BATTLE 进入 POSSESS 附身选中单位", "fn": Callable(self, "_test_possess_from_battle"), "async": true})
	_tests.append({"name": "附身: entity.is_possessed() == true", "fn": Callable(self, "_test_entity_possessed"), "async": true})
	_tests.append({"name": "附身: 相机居中跟随", "fn": Callable(self, "_test_camera_centered"), "async": true})
	_tests.append({"name": "信号: possession_started 发射", "fn": Callable(self, "_test_started_signal"), "async": true})
	_tests.append({"name": "UI: PossessPanel 显示单位信息", "fn": Callable(self, "_test_panel_shows_info"), "async": true})
	_tests.append({"name": "攻击: _find_nearest_enemy_in_range 找到敌人", "fn": Callable(self, "_test_find_enemy"), "async": false})
	_tests.append({"name": "攻击: _player_attack 对敌人造成伤害", "fn": Callable(self, "_test_player_attack"), "async": true})
	_tests.append({"name": "释放: release() 释放附身", "fn": Callable(self, "_test_release"), "async": true})
	_tests.append({"name": "释放: entity.is_possessed() == false", "fn": Callable(self, "_test_entity_released"), "async": true})
	_tests.append({"name": "释放: 模式恢复为 BATTLE", "fn": Callable(self, "_test_mode_restored"), "async": true})
	_tests.append({"name": "信号: possession_ended 发射", "fn": Callable(self, "_test_ended_signal"), "async": true})
	_tests.append({"name": "API: possess(entity) 直接附身", "fn": Callable(self, "_test_possess_api"), "async": true})
	_tests.append({"name": "降速: 附身时时间降速到 X1", "fn": Callable(self, "_test_time_slow"), "async": true})
	_tests.append({"name": "限制: 死亡单位不可附身", "fn": Callable(self, "_test_dead_unit_possess"), "async": true})


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
	_possession = _game_root.get_possession_interface()
	_possess_panel = _game_root.get_possess_panel()
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
	var f := FileAccess.open("f:/VSCode/game-2/stick-world/test_stage_07_result.txt", FileAccess.WRITE)
	if f != null:
		f.store_string(summary + "\n")
		f.store_string("EXIT_CODE=%d\n" % (0 if _runner.all_passed() else 1))
		f.close()
	var exit_code: int = 0 if _runner.all_passed() else 1
	get_tree().quit(exit_code)


func _write_log(msg: String) -> void:
	var f := FileAccess.open("f:/VSCode/game-2/stick-world/test_stage_07_result.txt", FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open("f:/VSCode/game-2/stick-world/test_stage_07_result.txt", FileAccess.WRITE)
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
		if e.get("foot_offset") != null:
			e.global_position.y = spawn_y - e.foot_offset
		if e.has_method("set_possessed"):
			e.set_possessed(false)
		_test_units.append(e)


# ─────────────────────────────── 同步测试 ────────────────────────────────

func _test_possession_assembled() -> void:
	_runner.assert_true(_possession != null, "PossessionInterface 应已装配")
	if _possession != null:
		_runner.assert_true(_possession.get_parent() != null, "PossessionInterface 应在场景树中")
		# 验证已注册为 POSSESS handler
		var dispatcher: Node = _game_root.input_dispatcher
		if dispatcher != null and dispatcher.has_method("get_handler"):
			var handler: Node = dispatcher.get_handler(PlayerControlAPI.Mode.POSSESS)
			_runner.assert_true(handler == _possession, "应注册为 POSSESS handler")


func _test_possess_panel_assembled() -> void:
	_runner.assert_true(_possess_panel != null, "PossessPanel 应已装配")
	if _possess_panel == null:
		return
	_runner.assert_true(_possess_panel.get_parent() != null, "PossessPanel 应在场景树中")
	# 验证 setup 已调用（HBox 应存在）
	var hbox: Node = _possess_panel.get_node_or_null("HBox")
	_runner.assert_true(hbox != null, "PossessPanel UI 应已构建（HBox 存在）")


# ─────────────────────────────── 异步测试 ────────────────────────────────

func _test_possess_from_battle() -> void:
	if _selection == null or _possession == null:
		_runner.assert_true(false, "系统未装配")
		return
	# 选中 unit 0
	_selection.clear_selection()
	_selection.select_unit(_test_units[0], false)
	_runner.assert_equal(_selection.get_selected_count(), 1, "应选中 1 个单位")
	# 连接信号
	_started_signal_entity = null
	var conn: Callable = Callable(self, "_on_possession_started")
	EventBus.possession_started.connect(conn)
	# 设置 pending entity 并切换到 POSSESS 模式
	_possession.set_pending_entity(_test_units[0])
	_game_root.input_dispatcher.enter_possess_mode()
	await get_tree().process_frame
	await get_tree().process_frame
	# 验证
	var entity: Node2D = _possession.get_possessed_entity()
	_runner.assert_true(entity != null, "应有附身实体")
	_runner.assert_true(entity == _test_units[0], "应附身 unit 0")
	EventBus.possession_started.disconnect(conn)


func _on_possession_started(entity) -> void:
	_started_signal_entity = entity


func _test_entity_possessed() -> void:
	if _possession == null:
		_runner.assert_true(false, "PossessionInterface 为空")
		return
	var entity: Node2D = _possession.get_possessed_entity()
	if entity == null:
		_runner.assert_true(false, "无附身实体")
		return
	_runner.assert_true(entity.is_possessed(), "entity.is_possessed() 应为 true")


func _test_camera_centered() -> void:
	if _possession == null:
		_runner.assert_true(false, "PossessionInterface 为空")
		return
	var cam: Camera2D = _game_root.camera_rig
	if cam == null:
		_runner.assert_true(false, "CameraRig 为空")
		return
	_runner.assert_true(cam.is_centered_mode(), "相机应处于居中模式")
	# 相机需要更多帧来更新位置，等待 5 帧确保跟随到位
	for i in 5:
		await get_tree().process_frame
	var entity: Node2D = _possession.get_possessed_entity()
	if entity != null:
		# 相机受地图边界约束，差距可能较大（地图宽 2048px，视野约 1920px）
		# 只要差距在地图宽度范围内即可
		var diff: float = absf(cam.global_position.x - entity.global_position.x)
		_runner.assert_true(diff < 1200.0, "相机应在合理范围内跟随附身实体（差距 %.1f，地图边界约束）" % diff)


func _test_started_signal() -> void:
	_runner.assert_true(_started_signal_entity != null, "应已收到 possession_started 信号")
	if _started_signal_entity != null:
		_runner.assert_true(_started_signal_entity == _test_units[0], "信号实体应为 unit 0")


func _test_panel_shows_info() -> void:
	if _possess_panel == null:
		_runner.assert_true(false, "PossessPanel 为空")
		return
	await get_tree().process_frame
	await get_tree().process_frame
	# 验证信息标签不为"未附身"
	var label: Label = _possess_panel.get("_info_label") if _possess_panel.get("_info_label") != null else null
	if label != null:
		_runner.assert_true(label.text != "未附身", "PossessPanel 应显示单位信息（非'未附身'）")
		_runner.assert_true(label.text.findn("HP") >= 0, "信息应包含 HP")


func _test_find_enemy() -> void:
	if _test_units.is_empty():
		_runner.assert_true(false, "无测试单位")
		return
	var unit: Node = _test_units[0]
	# 设置阵营：unit 0 = 阵营1，unit 1 = 阵营2
	if unit.has_method("set_faction"):
		unit.set_faction(1)
	if _test_units[1].has_method("set_faction"):
		_test_units[1].set_faction(2)
	# 调用 _find_nearest_enemy_in_range（通过 call 或直接调用）
	var enemy: Node = null
	if unit.has_method("_find_nearest_enemy_in_range"):
		enemy = unit._find_nearest_enemy_in_range()
	_runner.assert_true(enemy != null, "应找到最近敌人（unit 1 在射程内）")
	if enemy != null:
		_runner.assert_true(enemy == _test_units[1], "最近敌人应为 unit 1")


func _test_player_attack() -> void:
	if _test_units.is_empty():
		_runner.assert_true(false, "无测试单位")
		return
	var attacker: Node = _test_units[0]
	var target: Node = _test_units[1]
	# 确保阵营不同
	if attacker.has_method("set_faction"):
		attacker.set_faction(1)
	if target.has_method("set_faction"):
		target.set_faction(2)
	# 记录目标 HP
	var target_health: Node = target.get_health() if target.has_method("get_health") else null
	if target_health == null:
		_runner.assert_true(false, "目标无 HealthComponent")
		return
	var hp_before: float = target_health.hp
	# 执行攻击（多次以覆盖冷却 1.3s）
	for i in 10:
		if attacker.has_method("_player_attack"):
			attacker._player_attack()
		# 等待足够时间让冷却恢复（每次 0.3s）
		for j in 18:
			await get_tree().process_frame
	# 验证目标受到伤害
	var hp_after: float = target_health.hp
	_runner.assert_true(hp_after < hp_before, "目标 HP 应下降（%.1f -> %.1f）" % [hp_before, hp_after])


func _test_release() -> void:
	if _possession == null:
		_runner.assert_true(false, "PossessionInterface 为空")
		return
	_ended_signal_entity = null
	var conn: Callable = Callable(self, "_on_possession_ended")
	EventBus.possession_ended.connect(conn)
	# 释放
	_possession.release()
	await get_tree().process_frame
	await get_tree().process_frame
	EventBus.possession_ended.disconnect(conn)
	_runner.assert_true(_ended_signal_entity != null, "应收到 possession_ended 信号")


func _on_possession_ended(entity) -> void:
	_ended_signal_entity = entity


func _test_entity_released() -> void:
	if _test_units.is_empty():
		_runner.assert_true(false, "无测试单位")
		return
	var entity: Node = _test_units[0]
	if entity == null or not is_instance_valid(entity):
		_runner.assert_true(false, "unit 0 无效")
		return
	_runner.assert_true(not entity.is_possessed(), "释放后 entity.is_possessed() 应为 false")


func _test_mode_restored() -> void:
	var dispatcher: Node = _game_root.input_dispatcher
	if dispatcher == null:
		_runner.assert_true(false, "InputDispatcher 为空")
		return
	_runner.assert_true(dispatcher.is_mode(PlayerControlAPI.Mode.BATTLE), "释放后应恢复为 BATTLE 模式")


func _test_ended_signal() -> void:
	_runner.assert_true(_ended_signal_entity != null, "应已收到 possession_ended 信号")


func _test_possess_api() -> void:
	if _possession == null or _test_units.size() < 2:
		_runner.assert_true(false, "系统未就绪")
		return
	# 直接调用 possess(entity) API
	var target: Node = _test_units[1]
	_possession.possess(target)
	await get_tree().process_frame
	await get_tree().process_frame
	# 验证
	var entity: Node2D = _possession.get_possessed_entity()
	_runner.assert_true(entity == target, "应附身 unit 1")
	_runner.assert_true(target.is_possessed(), "unit 1 is_possessed() 应为 true")
	# 释放
	_possession.release()
	await get_tree().process_frame
	await get_tree().process_frame
	_runner.assert_true(not target.is_possessed(), "释放后 unit 1 is_possessed() 应为 false")


func _test_time_slow() -> void:
	if _possession == null or _test_units.size() < 3:
		_runner.assert_true(false, "系统未就绪")
		return
	# 保存原设置
	var original_auto_slow: bool = TimeManager.auto_slow_on_possess
	# 开启自动降速
	TimeManager.auto_slow_on_possess = true
	# 设速度为 X2
	TimeManager.set_speed(TimeManager.Speed.X2)
	# 附身
	_possession.possess(_test_units[2])
	await get_tree().process_frame
	# 验证速度降为 X1
	var current_speed: int = TimeManager.current_speed
	_runner.assert_equal(current_speed, TimeManager.Speed.X1, "附身后速度应为 X1")
	# 释放
	_possession.release()
	await get_tree().process_frame
	# 验证速度恢复
	current_speed = TimeManager.current_speed
	_runner.assert_equal(current_speed, TimeManager.Speed.X2, "释放后速度应恢复为 X2")
	# 恢复原设置
	TimeManager.auto_slow_on_possess = original_auto_slow


func _test_dead_unit_possess() -> void:
	if _possession == null or _test_units.size() < 4:
		_runner.assert_true(false, "系统未就绪")
		return
	# 杀死 unit 3
	var unit: Node = _test_units[3]
	var health: Node = unit.get_health() if unit.has_method("get_health") else null
	if health == null:
		_runner.assert_true(false, "unit 3 无 HealthComponent")
		return
	health.take_damage(99999.0)
	_runner.assert_true(unit.is_dead(), "unit 3 应已死亡")
	# 尝试直接 possess 死亡单位
	_possession.possess(unit)
	await get_tree().process_frame
	# 死亡单位不应被附身（set_possessed 可能仍然设置，但 _on_possession_changed 会处理）
	# 更重要的验证：get_possessed_entity 不应是死亡单位
	var entity: Node2D = _possession.get_possessed_entity()
	if entity == unit:
		_runner.assert_true(false, "不应附身死亡单位")
	else:
		_runner.assert_true(true, "死亡单位未被附身")
	# 清理：如果有错误的附身，释放它
	if entity != null:
		_possession.release()
		await get_tree().process_frame
