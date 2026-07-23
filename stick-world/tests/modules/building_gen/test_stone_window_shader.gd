extends Node
## building_gen / stone_window shader 基础结构测试
##
## 运行：
##   godot --headless --path stick-world res://tests/modules/building_gen/test_stone_window_shader.tscn

const TestRunner := preload("res://tests/core/test_runner.gd")

const SCENE_PATH := "res://modules/building_gen/materials/stone_window/scenes/stone_window_debug.tscn"
const SHADER_PATH := "res://modules/building_gen/materials/stone_window/shaders/stone_window.gdshader"
const CAPTURE_SCRIPT_PATH := "res://modules/building_gen/scripts/debug/capture_in_game.gd"

var _runner := TestRunner.new()


func _ready() -> void:
	_register_tests()
	_runner.run()
	print(_runner.summary())
	get_tree().quit(0 if _runner.all_passed() else 1)


func _register_tests() -> void:
	_runner.add_test("StoneWindowDebug 场景可实例化", _test_scene_instantiate)
	_runner.add_test("Sprite2D 使用石窗 ShaderMaterial", _test_material_and_shader)
	_runner.add_test("Shader 包含关键 uniform", _test_shader_uniforms)
	_runner.add_test("CaptureHelper 挂载截图脚本", _test_capture_helper)


func _test_scene_instantiate() -> void:
	var packed := load(SCENE_PATH) as PackedScene
	_runner.assert_true(packed != null, "应能加载 stone_window_debug.tscn")
	if packed == null:
		return

	var scene := packed.instantiate()
	_runner.assert_true(scene != null, "实例化后不应为 null")
	_runner.assert_true(scene.get_node_or_null("Sprite2D") != null, "应包含 Sprite2D 子节点")
	_runner.assert_true(scene.get_node_or_null("CaptureHelper") != null, "应包含 CaptureHelper 子节点")
	scene.free()


func _test_material_and_shader() -> void:
	var packed := load(SCENE_PATH) as PackedScene
	if packed == null:
		_runner.assert_true(false, "场景加载失败，跳过")
		return

	var scene := packed.instantiate()
	var sprite := scene.get_node_or_null("Sprite2D") as Sprite2D
	_runner.assert_true(sprite != null, "Sprite2D 应存在")

	var mat := sprite.material as ShaderMaterial
	_runner.assert_true(mat != null, "Sprite2D 应使用 ShaderMaterial")
	if mat != null:
		_runner.assert_true(mat.shader != null, "ShaderMaterial 应持有 shader")
		if mat.shader != null:
			_runner.assert_equal(mat.shader.resource_path, SHADER_PATH, "shader 路径应为 stone_window.gdshader")

	scene.free()


func _test_shader_uniforms() -> void:
	var shader := load(SHADER_PATH) as Shader
	_runner.assert_true(shader != null, "应能加载石窗 shader")
	if shader == null:
		return

	var list := shader.get_shader_uniform_list()
	_runner.assert_true(list.size() > 0, "shader uniform 列表不应为空")

	var names := []
	for item in list:
		names.append(item["name"])

	var required := [
		"resolution", "window_width", "window_height", "arch_height",
		"frame_thickness", "frame_depth", "arch_stones",
		"frame_color_light", "frame_color_mid", "frame_color_dark",
		"inner_shadow", "glass_color", "bar_color",
		"vertical_bars", "horizontal_bars", "bar_width",
		"sill_height", "sill_extension", "sill_color_light", "sill_color_mid", "sill_color_dark",
		"wall_brick_size", "wall_gap_size", "wall_corner_radius", "wall_edge_roughness", "wall_oil_scale",
		"wall_color_light", "wall_color_mid", "wall_color_dark", "wall_mortar",
		"light_dir"
	]
	for u in required:
		_runner.assert_true(u in names, "Shader 应包含 uniform: %s" % u)


func _test_capture_helper() -> void:
	var packed := load(SCENE_PATH) as PackedScene
	if packed == null:
		_runner.assert_true(false, "场景加载失败，跳过")
		return

	var scene := packed.instantiate()
	var helper := scene.get_node_or_null("CaptureHelper")
	_runner.assert_true(helper != null, "CaptureHelper 应存在")
	if helper != null:
		_runner.assert_equal(helper.get_script().resource_path, CAPTURE_SCRIPT_PATH, "脚本路径应为 capture_in_game.gd")
		_runner.assert_equal(helper.output_path, "res://modules/building_gen/materials/stone_window/reference/stone_window_debug_capture.png", "默认输出路径")

	scene.free()
