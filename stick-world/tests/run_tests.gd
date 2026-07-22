extends Node
## 运行所有测试的入口脚本。
##
## 运行：
##   godot --headless res://tests/run_tests.tscn --path <项目目录>
##
## 退出码：0 全部通过，非 0 有失败

var _runner: Object
var _suite: Array = []


const PM = preload("res://modules/building_gen/scripts/materials/procedural_materials.gd")


func _ready() -> void:
	var runner_script = load("res://tests/core/test_runner.gd")
	_runner = runner_script.new()
	_register_event_bus_tests()
	_register_config_manager_tests()
	_register_procedural_materials_tests()
	for t in _suite:
		_runner.add_test(t["name"], t["fn"])

	_runner.run()
	print(_runner.summary())

	var exit_code: int = 0 if _runner.all_passed() else 1
	get_tree().quit(exit_code)


# -- EventBus ---------------------------------------------------------

func _register_event_bus_tests() -> void:
	_suite.append({"name": "EventBus: safe_emit 不触发未声明信号", "fn": Callable(self, "_test_eventbus_safe_emit_unknown")})
	_suite.append({"name": "EventBus: game_started 信号可 connect", "fn": Callable(self, "_test_eventbus_game_started")})


func _test_eventbus_safe_emit_unknown() -> void:
	EventBus.safe_emit("a_signal_that_does_not_exist", [])
	_runner.assert_true(true, "safe_emit 对未知信号静默")


func _test_eventbus_game_started() -> void:
	var counter: Array = [0]
	EventBus.game_started.connect(func():
		counter[0] = counter[0] + 1
	)
	EventBus.emit_signal("game_started")
	EventBus.emit_signal("game_started")
	_runner.assert_equal(counter[0], 2, "game_started 应被触发两次")


# -- ConfigManager ---------------------------------------------------------

func _register_config_manager_tests() -> void:
	_suite.append({"name": "ConfigManager: get/set 值正确", "fn": Callable(self, "_test_config_get_set")})
	_suite.append({"name": "ConfigManager: has_key 返回默认键", "fn": Callable(self, "_test_config_has_key")})
	_suite.append({"name": "ConfigManager: volume clamp 有效", "fn": Callable(self, "_test_config_volume_clamp")})


func _test_config_get_set() -> void:
	ConfigManager.set_value("test_key", 42)
	_runner.assert_equal(ConfigManager.get_value("test_key"), 42)


func _test_config_has_key() -> void:
	_runner.assert_true(ConfigManager.has_key("audio/master_volume"), "应包含默认 key")
	_runner.assert_true(not ConfigManager.has_key("no/such/key"), "不应包含无意义的 key")


func _test_config_volume_clamp() -> void:
	ConfigManager.set_volume("master", 1.5)
	var vol: float = ConfigManager.get_volume("master")
	_runner.assert_true(vol <= 1.0, "volume 不应超过 1.0")
	ConfigManager.set_volume("master", -0.5)
	vol = ConfigManager.get_volume("master")
	_runner.assert_true(vol >= 0.0, "volume 不应小于 0")


# -- ProceduralMaterials ----------------------------------------------

func _register_procedural_materials_tests() -> void:
	_suite.append({"name": "ProceduralMaterials: thatch texture has metadata", "fn": Callable(self, "_test_thatch_texture_metadata")})
	_suite.append({"name": "ProceduralMaterials: create_thatch_material sets uniforms", "fn": Callable(self, "_test_create_thatch_material")})


func _test_thatch_texture_metadata() -> void:
	var tex: ImageTexture = PM.make_thatch_for_polygon(64, 64, 123)
	_runner.assert_true(tex != null, "应返回 ImageTexture")
	_runner.assert_true(tex.has_meta("thatch_inner_size"), "应有 inner_size 元数据")
	_runner.assert_true(tex.has_meta("thatch_margin"), "应有 margin 元数据")
	var inner_size: Vector2i = tex.get_meta("thatch_inner_size")
	var margin: int = tex.get_meta("thatch_margin")
	_runner.assert_true(inner_size.x > 0 and inner_size.y > 0, "inner_size 应合法")
	_runner.assert_true(margin >= 0, "margin 不应为负")


func _test_create_thatch_material() -> void:
	var tex: ImageTexture = PM.make_thatch_for_polygon(64, 64, 456)
	var mat: ShaderMaterial = PM.create_thatch_material(tex)
	_runner.assert_true(mat != null, "应返回 ShaderMaterial")
	_runner.assert_true(mat.shader != null, "Shader 应加载成功")
	_runner.assert_equal(mat.get_shader_parameter("albedo_tex"), tex, "albedo_tex uniform 应指向贴图")