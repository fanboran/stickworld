extends Node
## building_gen / thatch shader 基础结构测试
##
## 运行：
##   godot --headless --path stick-world res://tests/modules/building_gen/test_thatch_shader.tscn

const TestRunner := preload("res://tests/core/test_runner.gd")

const SCENE_PATH := "res://modules/building_gen/materials/thatch/scenes/thatch_debug.tscn"
const BUILDING_DEMO_PATH := "res://modules/building_gen/materials/thatch/scenes/thatch_building_demo.tscn"
const SHADER_PATH := "res://modules/building_gen/materials/thatch/shaders/thatch.gdshader"
const CAPTURE_SCRIPT_PATH := "res://modules/building_gen/scripts/debug/capture_in_game.gd"

var _runner := TestRunner.new()


func _ready() -> void:
	_register_tests()
	await _run_tests_async()
	print(_runner.summary())
	get_tree().quit(0 if _runner.all_passed() else 1)


func _run_tests_async() -> void:
	# 先运行同步测试
	_runner.run()
	# 再运行需要等待一帧的建筑演示场景测试
	await _test_building_demo_instantiate_async()


func _register_tests() -> void:
	_runner.add_test("ThatchDebug 场景可实例化", _test_scene_instantiate)
	_runner.add_test("Sprite2D 使用茅草 ShaderMaterial", _test_material_and_shader)
	_runner.add_test("Shader 包含关键 uniform", _test_shader_uniforms)
	_runner.add_test("CaptureHelper 挂载截图脚本", _test_capture_helper)


func _test_scene_instantiate() -> void:
	var packed := load(SCENE_PATH) as PackedScene
	_runner.assert_true(packed != null, "应能加载 thatch_debug.tscn")
	if packed == null:
		return

	var scene := packed.instantiate()
	_runner.assert_true(scene != null, "实例化后不应为 null")
	_runner.assert_true(scene.get_node_or_null("Sprite2D") != null, "应包含 Sprite2D 子节点")
	_runner.assert_true(scene.get_node_or_null("CaptureHelper") != null, "应包含 CaptureHelper 子节点")
	scene.free()


func _test_building_demo_instantiate_async() -> void:
	_runner.begin_test("ThatchBuildingDemo 场景可实例化")
	var packed := load(BUILDING_DEMO_PATH) as PackedScene
	_runner.assert_true(packed != null, "应能加载 thatch_building_demo.tscn")
	if packed == null:
		_runner.end_test()
		return

	var scene := packed.instantiate()
	add_child(scene)
	_runner.assert_true(scene != null, "实例化后不应为 null")
	_runner.assert_true(scene.get_node_or_null("Camera2D") != null, "应包含 Camera2D 子节点")
	_runner.assert_true(scene.get_node_or_null("CaptureHelper") != null, "应包含 CaptureHelper 子节点")

	# 脚本运行 _ready 后会动态创建 RoofLeft 和 RoofRight
	await get_tree().process_frame
	var roof_left := scene.get_node_or_null("RoofLeft") as Sprite2D
	var roof_right := scene.get_node_or_null("RoofRight") as Sprite2D
	_runner.assert_true(roof_left != null, "应动态创建 RoofLeft")
	_runner.assert_true(roof_right != null, "应动态创建 RoofRight")
	if roof_left != null and roof_right != null:
		_runner.assert_true(roof_left.material != null, "RoofLeft 应使用材质")
		_runner.assert_true(roof_right.material != null, "RoofRight 应使用材质")

	scene.queue_free()
	_runner.end_test()


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
			_runner.assert_equal(mat.shader.resource_path, SHADER_PATH, "shader 路径应为 thatch.gdshader")

	scene.free()


func _test_shader_uniforms() -> void:
	var shader := load(SHADER_PATH) as Shader
	_runner.assert_true(shader != null, "应能加载茅草 shader")
	if shader == null:
		return

	var list := shader.get_shader_uniform_list()
	_runner.assert_true(list.size() > 0, "shader uniform 列表不应为空")

	var names := []
	for item in list:
		names.append(item["name"])

	var required := [
		"resolution", "bounds", "blade_angle", "angle_var", "curve_amount",
		"rows", "blades_per_row", "row_spacing", "blade_spacing",
		"blade_length_base", "blade_length_var", "blade_width_base", "blade_width_var",
		"root_width_mul", "tip_width_mul", "width_noise", "oil_roughness",
		"margin_bottom", "edge_noise", "root_jitter", "row_jitter",
		"seed", "color1", "color2", "color3", "color4", "color5", "show_bounds"
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
		_runner.assert_equal(helper.output_path, "res://modules/building_gen/materials/thatch/reference/thatch_debug_capture.png", "默认输出路径")

	scene.free()
