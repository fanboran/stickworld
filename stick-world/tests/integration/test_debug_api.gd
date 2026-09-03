extends Node
## 集成测试冒烟：DebugApi（debug_gui 模块 autoload）状态管理。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_debug_api.tscn
##
## 覆盖（对 new() 出的独立实例，不动全局 DebugApi 单例状态）：
##   - 绘制器注册/注销/独立开关 + drawer_enabled_changed 信号
##   - F3 可见性翻转：本地 visibility_changed + EventBus.debug_visibility_changed 转发
##   - 调试上下文附加数据注入/读取
##   - 持久化保护：测试前后还原 user://debug_settings.cfg（setter 会落盘）

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const DebugApiScript := preload("res://modules/debug_gui/api.gd")

const CFG_PATH := "user://debug_settings.cfg"

var _runner: TestRunner
var _api: Node
var _cfg_backup: PackedByteArray = []
var _cfg_existed := false


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("DebugApi: 绘制器注册/注销", _test_drawers, true)
	_runner.add_test("DebugApi: 独立开关 + 信号", _test_drawer_toggle, true)
	_runner.add_test("DebugApi: F3 可见性翻转 + EventBus 转发", _test_visibility, true)
	_runner.add_test("DebugApi: 上下文附加数据注入/读取", _test_ctx_extras, true)
	_backup_cfg()
	_run_tests_async()


func _backup_cfg() -> void:
	_cfg_existed = FileAccess.file_exists(CFG_PATH)
	if _cfg_existed:
		_cfg_backup = FileAccess.get_file_as_bytes(CFG_PATH)


func _restore_cfg() -> void:
	if _cfg_existed:
		var f := FileAccess.open(CFG_PATH, FileAccess.WRITE)
		if f != null:
			f.store_buffer(_cfg_backup)
			f.close()
	else:
		var global := ProjectSettings.globalize_path(CFG_PATH)
		if FileAccess.file_exists(CFG_PATH):
			DirAccess.remove_absolute(global)


func _run_tests_async() -> void:
	_api = DebugApiScript.new()
	add_child(_api)
	await get_tree().process_frame
	await _runner.run_async()
	print(_runner.summary())
	var exit_code: int = 0 if _runner.all_passed() else 1
	_restore_cfg()
	get_tree().quit(exit_code)


func _test_drawers() -> void:
	var calls: Array = []
	var drawer := func(control: Control, ctx: Dictionary) -> void: calls.append(ctx)
	_api.register_drawer("unit_test_drawer", drawer)
	_runner.assert_true(_api.get_drawers().has("unit_test_drawer"), "注册后应在绘制器表中")
	_runner.assert_true(_api.is_drawer_enabled("unit_test_drawer"), "新绘制器应默认启用")
	_api.unregister_drawer("unit_test_drawer")
	_runner.assert_true(not _api.get_drawers().has("unit_test_drawer"), "注销后应从表中移除")


func _test_drawer_toggle() -> void:
	_api.register_drawer("unit_test_toggle", func(_c: Control, _ctx: Dictionary) -> void: pass)
	var got := [false, ""]
	_api.drawer_enabled_changed.connect(func(name: String, enabled: bool) -> void:
		got[0] = true
		got[1] = "%s=%s" % [name, enabled])
	_api.set_drawer_enabled("unit_test_toggle", false)
	_runner.assert_true(got[0], "set_drawer_enabled 应发射 drawer_enabled_changed")
	_runner.assert_true(_api.is_drawer_enabled("unit_test_toggle") == false, "开关应为关")
	_api.toggle_drawer("unit_test_toggle")
	_runner.assert_true(_api.is_drawer_enabled("unit_test_toggle"), "toggle 后应重开")
	_api.unregister_drawer("unit_test_toggle")


func _test_visibility() -> void:
	var before: bool = _api.is_visible()
	var local_hits := [0]
	_api.visibility_changed.connect(func(_v: bool) -> void: local_hits[0] += 1)
	var bus_hits := [0]
	EventBus.debug_visibility_changed.connect(func(_v: bool) -> void: bus_hits[0] += 1)
	_api.toggle_visibility()
	_runner.assert_equal(_api.is_visible(), not before, "toggle 后可见性应翻转")
	_runner.assert_true(local_hits[0] >= 1, "本地 visibility_changed 应发射")
	_runner.assert_true(bus_hits[0] >= 1, "EventBus.debug_visibility_changed 应转发")
	_api.toggle_visibility()
	_runner.assert_equal(_api.is_visible(), before, "二次 toggle 应回到初值")


func _test_ctx_extras() -> void:
	_api.set_ctx_extra("test_key", Vector2(3, 4))
	_runner.assert_equal(_api.get_ctx_extra("test_key"), Vector2(3, 4), "应读回注入值")
	_runner.assert_equal(_api.get_ctx_extra("missing", "fallback"), "fallback", "缺键应返回默认值")
	_runner.assert_true(_api.ctx_extras().has("test_key"), "全量表应含注入键")
	_api.set_ctx_extra("test_key", null)
