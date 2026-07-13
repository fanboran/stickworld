extends Node
## 阶段 0.1 GameRoot 骨架测试入口。
##
## 运行：
##   godot --headless --path stick-world res://tests/test_stage_01.tscn
##
## 退出码：0 全部通过，1 有失败

const TestRunner := preload("res://tests/core/test_runner.gd")
# WorldAPI / PlayerControlAPI / UIAPI 是全局 class_name，无需 preload
# 显式 preload 各实现脚本，用于类型 cast（常量名加 Script 前缀避免遮蔽全局类名）
const ScriptGameRoot := preload("res://modules/world/scripts/game_root.gd")
const ScriptCameraRig := preload("res://modules/world/scripts/camera_rig.gd")
const ScriptSceneLoader := preload("res://modules/world/scripts/scene_loader.gd")
const ScriptInputDispatcher := preload("res://modules/player_control/scripts/input_dispatcher.gd")
const ScriptEnvironmentSystem := preload("res://modules/environment/scripts/environment_system.gd")
const ScriptUIRoot := preload("res://modules/ui/scripts/ui_root.gd")
const ScriptModePanel := preload("res://modules/ui/scripts/mode_panel.gd")

var _runner: TestRunner
var _game_root: Node
var _tests: Array = []


func _ready() -> void:
	_runner = TestRunner.new()
	_register_tests()
	_run_tests_async()


# ─────────────────────────────── 测试注册 ────────────────────────────────

func _register_tests() -> void:
	_tests.append({"name": "GameRoot: 实例化主场景", "fn": Callable(self, "_test_gameroot_instantiate")})
	_tests.append({"name": "GameRoot: 子节点齐全", "fn": Callable(self, "_test_gameroot_children")})
	_tests.append({"name": "InputDispatcher: 默认 EXPLORE 模式", "fn": Callable(self, "_test_input_default_mode")})
	_tests.append({"name": "InputDispatcher: 模式切换触发信号", "fn": Callable(self, "_test_input_mode_switch")})
	_tests.append({"name": "InputDispatcher: handler 注册激活", "fn": Callable(self, "_test_input_handler_register")})
	_tests.append({"name": "SceneLoader: 未注册地图报错", "fn": Callable(self, "_test_scene_loader_unknown")})
	_tests.append({"name": "SceneLoader: 注册+加载地图", "fn": Callable(self, "_test_scene_loader_load")})
	_tests.append({"name": "EnvironmentSystem: 默认时间", "fn": Callable(self, "_test_env_default_time")})
	_tests.append({"name": "EnvironmentSystem: 设置时间", "fn": Callable(self, "_test_env_set_time")})
	_tests.append({"name": "EnvironmentSystem: 光照颜色插值", "fn": Callable(self, "_test_env_lighting")})
	_tests.append({"name": "CameraRig: 默认参数", "fn": Callable(self, "_test_camera_default")})
	_tests.append({"name": "CameraRig: 震屏状态", "fn": Callable(self, "_test_camera_shake")})
	_tests.append({"name": "CameraRig: 缩放范围", "fn": Callable(self, "_test_camera_zoom")})
	_tests.append({"name": "UIRoot: 子节点齐全", "fn": Callable(self, "_test_ui_children")})
	_tests.append({"name": "ModePanel: 切换可见性", "fn": Callable(self, "_test_mode_panel_switch")})


# ─────────────────────────────── 异步执行 ────────────────────────────────

func _run_tests_async() -> void:
	# 先实例化 GameRoot
	var packed := load("res://modules/world/scripts/game_root.tscn") as PackedScene
	if packed == null:
		print("[FATAL] 无法加载 game_root.tscn")
		get_tree().quit(1)
		return
	_game_root = packed.instantiate()
	add_child(_game_root)
	# 等待一帧让 _ready 执行
	await get_tree().process_frame

	# 顺序执行所有测试
	for t in _tests:
		_runner.add_test(t["name"], t["fn"])
	_runner.run()
	print(_runner.summary())

	var exit_code := 0 if _runner.all_passed() else 1
	get_tree().quit(exit_code)


# ─────────────────────────────── 辅助 ────────────────────────────────

func _get_child(path: String) -> Node:
	if _game_root == null:
		return null
	return _game_root.get_node_or_null(path)


# ─────────────────────────────── GameRoot ────────────────────────────────

func _test_gameroot_instantiate() -> void:
	_runner.assert_true(_game_root != null, "GameRoot 应被实例化")
	_runner.assert_true(is_instance_valid(_game_root), "GameRoot 应有效")


func _test_gameroot_children() -> void:
	_runner.assert_true(_get_child(WorldAPI.PATH_ENVIRONMENT) != null, "EnvironmentSystem 应存在")
	_runner.assert_true(_get_child(WorldAPI.PATH_CAMERA_RIG) != null, "CameraRig 应存在")
	_runner.assert_true(_get_child(WorldAPI.PATH_SCENE_LOADER) != null, "SceneLoader 应存在")
	_runner.assert_true(_get_child(WorldAPI.PATH_INPUT_DISPATCHER) != null, "InputDispatcher 应存在")
	_runner.assert_true(_get_child(WorldAPI.PATH_WORLD_CHUNK_HOST) != null, "WorldChunkHost 应存在")
	_runner.assert_true(_get_child(WorldAPI.PATH_UI_ROOT) != null, "UIRoot 应存在")


# ─────────────────────────────── InputDispatcher ────────────────────────────────

func _test_input_default_mode() -> void:
	var d: ScriptInputDispatcher = _get_child(WorldAPI.PATH_INPUT_DISPATCHER) as ScriptInputDispatcher
	_runner.assert_true(d != null, "InputDispatcher 应存在")
	if d:
		# 初始为 NONE，地图加载完成后自动切到 EXPLORE（await 一帧后已加载）
		_runner.assert_equal(d.get_mode(), PlayerControlAPI.Mode.EXPLORE, "地图加载后应为 EXPLORE")


func _test_input_mode_switch() -> void:
	var d: ScriptInputDispatcher = _get_child(WorldAPI.PATH_INPUT_DISPATCHER) as ScriptInputDispatcher
	if d == null:
		_runner.assert_true(false, "InputDispatcher 不存在")
		return
	var counter := [0]
	var last_old := [-1]
	var last_new := [-1]
	d.mode_changed.connect(func(old, new):
		counter[0] += 1
		last_old[0] = old
		last_new[0] = new
	)
	d.set_mode(PlayerControlAPI.Mode.BATTLE)
	_runner.assert_equal(counter[0], 1, "切换一次应触发一次信号")
	_runner.assert_equal(last_old[0], PlayerControlAPI.Mode.EXPLORE, "旧模式应为 EXPLORE")
	_runner.assert_equal(last_new[0], PlayerControlAPI.Mode.BATTLE, "新模式应为 BATTLE")
	_runner.assert_equal(d.get_mode(), PlayerControlAPI.Mode.BATTLE, "当前模式应为 BATTLE")
	# 切换回 EXPLORE
	d.set_mode(PlayerControlAPI.Mode.EXPLORE)
	_runner.assert_equal(counter[0], 2, "再切换一次应触发第二次信号")
	# 相同模式不触发
	d.set_mode(PlayerControlAPI.Mode.EXPLORE)
	_runner.assert_equal(counter[0], 2, "相同模式不应触发信号")


func _test_input_handler_register() -> void:
	var d: ScriptInputDispatcher = _get_child(WorldAPI.PATH_INPUT_DISPATCHER) as ScriptInputDispatcher
	if d == null:
		_runner.assert_true(false, "InputDispatcher 不存在")
		return
	# 创建一个简易 handler
	var handler := Node.new()
	handler.set_script(load("res://tests/helpers/mode_handler_helper.gd"))
	add_child(handler)
	# 当前模式为 EXPLORE（地图已加载），注册 EXPLORE handler 应立即激活
	d.register_handler(PlayerControlAPI.Mode.EXPLORE, handler)
	var activated_count: int = handler.get_meta("activated_count", 0)
	_runner.assert_equal(activated_count, 1, "注册当前模式应立即激活")
	# 切换到 BATTLE，EXPLORE handler 应被停用
	d.set_mode(PlayerControlAPI.Mode.BATTLE)
	var deactivated_count: int = handler.get_meta("deactivated_count", 0)
	_runner.assert_equal(deactivated_count, 1, "切换离开应触发停用")
	# 切回 EXPLORE，应再次激活
	d.set_mode(PlayerControlAPI.Mode.EXPLORE)
	activated_count = handler.get_meta("activated_count", 0)
	_runner.assert_equal(activated_count, 2, "切回应再次激活")
	handler.queue_free()


# ─────────────────────────────── SceneLoader ────────────────────────────────

func _test_scene_loader_unknown() -> void:
	var sl: ScriptSceneLoader = _get_child(WorldAPI.PATH_SCENE_LOADER) as ScriptSceneLoader
	if sl == null:
		_runner.assert_true(false, "SceneLoader 不存在")
		return
	_runner.assert_true(not sl.has_map("nonexistent_map"), "未注册地图应返回 false")
	var result: Node2D = sl.load_map("nonexistent_map")
	_runner.assert_true(result == null, "加载未注册地图应返回 null")


func _test_scene_loader_load() -> void:
	var sl: ScriptSceneLoader = _get_child(WorldAPI.PATH_SCENE_LOADER) as ScriptSceneLoader
	if sl == null:
		_runner.assert_true(false, "SceneLoader 不存在")
		return
	# 创建一个最小测试地图场景
	var test_map := PackedScene.new()
	var map_node := Node2D.new()
	map_node.name = "TestMap"
	test_map.pack(map_node)
	map_node.free()

	sl.register_map("test_map", test_map, WorldAPI.MapType.VILLAGE)
	_runner.assert_true(sl.has_map("test_map"), "注册后应存在")

	var loaded: Node2D = sl.load_map("test_map")
	_runner.assert_true(loaded != null, "加载应返回非空")
	_runner.assert_true(is_instance_valid(loaded), "加载的实例应有效")
	_runner.assert_equal(sl.get_current_map_id(), "test_map", "当前地图 id 应为 test_map")
	_runner.assert_true(sl.is_map_loaded(), "is_map_loaded 应为 true")

	# 卸载
	sl.unload_current_map()
	_runner.assert_true(not sl.is_map_loaded(), "卸载后应无地图")


# ─────────────────────────────── EnvironmentSystem ────────────────────────────────

func _test_env_default_time() -> void:
	var env: ScriptEnvironmentSystem = _get_child(WorldAPI.PATH_ENVIRONMENT) as ScriptEnvironmentSystem
	if env == null:
		_runner.assert_true(false, "EnvironmentSystem 不存在")
		return
	_runner.assert_equal(env.get_time_of_day(), 8.0, "默认时间应为 8.0")


func _test_env_set_time() -> void:
	var env: ScriptEnvironmentSystem = _get_child(WorldAPI.PATH_ENVIRONMENT) as ScriptEnvironmentSystem
	if env == null:
		_runner.assert_true(false, "EnvironmentSystem 不存在")
		return
	env.set_time_of_day(14.5)
	_runner.assert_equal(env.get_time_of_day(), 14.5, "设置后时间应为 14.5")
	# 测试 wrap
	env.set_time_of_day(26.0)
	_runner.assert_equal(env.get_time_of_day(), 2.0, "26.0 应 wrap 为 2.0")


func _test_env_lighting() -> void:
	# 测试静态方法 _sample_light_color（通过 class_name 直接访问）
	# 深夜颜色应较暗
	var night_color: Color = ScriptEnvironmentSystem._sample_light_color(0.0)
	_runner.assert_true(night_color.r < 0.5, "深夜红色通道应较低")
	_runner.assert_true(night_color.g < 0.5, "深夜绿色通道应较低")
	# 正午颜色应较亮
	var noon_color: Color = ScriptEnvironmentSystem._sample_light_color(12.0)
	_runner.assert_true(noon_color.r > 0.9, "正午红色通道应较高")
	_runner.assert_true(noon_color.g > 0.9, "正午绿色通道应较高")


# ─────────────────────────────── CameraRig ────────────────────────────────

func _test_camera_default() -> void:
	var cam: ScriptCameraRig = _get_child(WorldAPI.PATH_CAMERA_RIG) as ScriptCameraRig
	if cam == null:
		_runner.assert_true(false, "CameraRig 不存在")
		return
	_runner.assert_equal(cam.user_zoom, 1.0, "默认 user_zoom 应为 1.0")
	_runner.assert_true(not cam.is_shaking(), "初始应未在震屏")


func _test_camera_shake() -> void:
	var cam: ScriptCameraRig = _get_child(WorldAPI.PATH_CAMERA_RIG) as ScriptCameraRig
	if cam == null:
		_runner.assert_true(false, "CameraRig 不存在")
		return
	cam.shake(0.8)
	_runner.assert_true(cam.is_shaking(), "shake 后应在震屏")


func _test_camera_zoom() -> void:
	var cam: ScriptCameraRig = _get_child(WorldAPI.PATH_CAMERA_RIG) as ScriptCameraRig
	if cam == null:
		_runner.assert_true(false, "CameraRig 不存在")
		return
	# 设置超出范围的值应被 clamp（user_zoom 范围 [1.0, 2.0]）
	cam.set_user_zoom(10.0)
	_runner.assert_true(cam.user_zoom <= ScriptCameraRig.ZOOM_MAX, "user_zoom 不应超过 ZOOM_MAX")
	cam.set_user_zoom(0.1)
	_runner.assert_true(cam.user_zoom >= ScriptCameraRig.ZOOM_MIN, "user_zoom 不应低于 ZOOM_MIN")


# ─────────────────────────────── UIRoot ────────────────────────────────

func _test_ui_children() -> void:
	var ui: ScriptUIRoot = _get_child(WorldAPI.PATH_UI_ROOT) as ScriptUIRoot
	if ui == null:
		_runner.assert_true(false, "UIRoot 不存在")
		return
	_runner.assert_true(ui.get_node_or_null(UIAPI.PATH_GLOBAL_HUD) != null, "GlobalHUD 应存在")
	_runner.assert_true(ui.get_node_or_null(UIAPI.PATH_MODE_PANEL) != null, "ModePanel 应存在")
	_runner.assert_true(ui.get_node_or_null(UIAPI.PATH_CONTEXT_PANEL) != null, "ContextPanel 应存在")


func _test_mode_panel_switch() -> void:
	var ui: ScriptUIRoot = _get_child(WorldAPI.PATH_UI_ROOT) as ScriptUIRoot
	if ui == null:
		_runner.assert_true(false, "UIRoot 不存在")
		return
	var mp: ScriptModePanel = ui.get_node_or_null(UIAPI.PATH_MODE_PANEL) as ScriptModePanel
	if mp == null:
		_runner.assert_true(false, "ModePanel 不存在")
		return
	# 默认显示村落面板
	mp.switch_to(UIAPI.PanelType.VILLAGE)
	_runner.assert_equal(mp.get_active_panel_type(), UIAPI.PanelType.VILLAGE, "应显示村落面板")
	# 切换到战斗
	mp.switch_to(UIAPI.PanelType.BATTLE)
	_runner.assert_equal(mp.get_active_panel_type(), UIAPI.PanelType.BATTLE, "应显示战斗面板")
	# 切换到附身
	mp.switch_to(UIAPI.PanelType.POSSESS)
	_runner.assert_equal(mp.get_active_panel_type(), UIAPI.PanelType.POSSESS, "应显示附身面板")
