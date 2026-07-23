extends Node
## building_gen / smithy 茅草适配器测试
##
## 验证 smithy_preview.tscn 中的 ThatchApplier：
## 1. 场景可实例化，节点结构完整
## 2. ThatchApplier 脚本与 roof_paths 配置正确
## 3. 运行时（非 editor）applier 把茅草 ShaderMaterial 应用到两个屋顶 Polygon2D
##
## 运行：
##   godot --headless --path stick-world res://tests/modules/building_gen/test_smithy_thatch_applier.tscn

const TestRunner := preload("res://tests/core/test_runner.gd")

const SMITHY_PREVIEW_PATH := "res://modules/building_gen/scenes/smithy_preview.tscn"
const THATCH_SHADER_PATH := "res://modules/building_gen/materials/thatch/shaders/thatch.gdshader"
const APPLIER_SCRIPT_PATH := "res://modules/building_gen/materials/thatch/scripts/preview/smithy_thatch_applier.gd"

var _runner := TestRunner.new()


func _ready() -> void:
	_register_tests()
	await _run_tests_async()
	print(_runner.summary())
	get_tree().quit(0 if _runner.all_passed() else 1)


func _run_tests_async() -> void:
	# 同步测试先跑
	_runner.run()
	# 异步测试：实例化场景后等一帧，让 applier._ready 应用材质
	await _test_applier_applies_material_async()


func _register_tests() -> void:
	_runner.add_test("smithy_preview 场景可实例化且节点结构完整", _test_scene_instantiate)
	_runner.add_test("ThatchApplier 脚本与 roof_paths 配置正确", _test_applier_config)


func _test_scene_instantiate() -> void:
	var packed := load(SMITHY_PREVIEW_PATH) as PackedScene
	_runner.assert_true(packed != null, "应能加载 smithy_preview.tscn")
	if packed == null:
		return

	var scene := packed.instantiate()
	_runner.assert_true(scene != null, "实例化后不应为 null")
	_runner.assert_true(scene.get_node_or_null("ThatchApplier") != null, "应包含 ThatchApplier 节点")
	_runner.assert_true(scene.get_node_or_null("L5_Roof") != null, "应包含 L5_Roof")
	_runner.assert_true(scene.get_node_or_null("L5_Roof/RoofMain") != null, "应包含 L5_Roof/RoofMain")
	_runner.assert_true(scene.get_node_or_null("L5_Roof/RoofLeftGroup1") != null, "应包含 L5_Roof/RoofLeftGroup1")
	scene.free()


func _test_applier_config() -> void:
	var packed := load(SMITHY_PREVIEW_PATH) as PackedScene
	if packed == null:
		_runner.assert_true(false, "场景加载失败，跳过")
		return

	var scene := packed.instantiate()
	var applier := scene.get_node_or_null("ThatchApplier")
	_runner.assert_true(applier != null, "ThatchApplier 应存在")
	if applier == null:
		scene.free()
		return

	_runner.assert_equal(
		applier.get_script().resource_path, APPLIER_SCRIPT_PATH,
		"脚本路径应为 smithy_thatch_applier.gd"
	)
	# roof_paths 应配置两个屋顶（运行时通过 ../ 找兄弟节点）
	_runner.assert_true(applier.roof_paths.size() == 2, "roof_paths 应有 2 个 NodePath")
	if applier.roof_paths.size() == 2:
		_runner.assert_true(
			str(applier.roof_paths[0]).find("RoofMain") >= 0,
			"roof_paths[0] 应指向 RoofMain"
		)
		_runner.assert_true(
			str(applier.roof_paths[1]).find("RoofLeftGroup1") >= 0,
			"roof_paths[1] 应指向 RoofLeftGroup1"
		)
	scene.free()


func _test_applier_applies_material_async() -> void:
	_runner.begin_test("ThatchApplier 运行时应用茅草材质到两个屋顶")
	var packed := load(SMITHY_PREVIEW_PATH) as PackedScene
	if packed == null:
		_runner.assert_true(false, "场景加载失败")
		_runner.end_test()
		return

	var scene := packed.instantiate()
	add_child(scene)
	# applier._ready 在非 editor 模式同步运行；等一帧确保材质应用与节点树就绪
	await get_tree().process_frame

	var roof_main := scene.get_node_or_null("L5_Roof/RoofMain") as Polygon2D
	var roof_left := scene.get_node_or_null("L5_Roof/RoofLeftGroup1") as Polygon2D
	_runner.assert_true(roof_main != null, "RoofMain 应存在")
	_runner.assert_true(roof_left != null, "RoofLeftGroup1 应存在")

	if roof_main != null:
		_assert_thatch_material(roof_main, "RoofMain")
	if roof_left != null:
		_assert_thatch_material(roof_left, "RoofLeftGroup1")

	scene.queue_free()
	_runner.end_test()


func _assert_thatch_material(poly: Polygon2D, label: String) -> void:
	var mat := poly.material as ShaderMaterial
	_runner.assert_true(mat != null, "%s 应被应用 ShaderMaterial" % label)
	if mat != null:
		_runner.assert_true(mat.shader != null, "%s 的 ShaderMaterial 应持有 shader" % label)
		if mat.shader != null:
			_runner.assert_equal(
				mat.shader.resource_path, THATCH_SHADER_PATH,
				"%s 的 shader 应为 thatch.gdshader" % label
			)
		# applier 应设置几何 uniform（非默认值），证明参数已注入
		var bounds := mat.get_shader_parameter("bounds") as Vector4
		_runner.assert_true(bounds != null, "%s 应设置 bounds uniform" % label)
		if bounds != null:
			_runner.assert_true(bounds.z > 0.0 and bounds.w > 0.0, "%s bounds 尺寸应 > 0" % label)
