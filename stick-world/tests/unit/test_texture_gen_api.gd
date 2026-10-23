extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：TextureGenAPI 程序化贴图与材质生成器。
## 纯静态函数测试：不进场景树、不碰 autoload；生成器 seed 确定性（hash 种子）可做像素级断言。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
# 依赖纯逻辑/纯数据一律显式 preload（tests/README 禁区：不依赖 class_name 全局注册）
const ScriptTextureGenAPI := preload("res://modules/texture_gen/api.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("TextureGenAPI: list_materials 非空且四材质齐备", _test_list_materials)
	_runner.add_test("TextureGenAPI: has_material 命中与未命中", _test_has_material)
	_runner.add_test("TextureGenAPI: make_solid 尺寸与颜色", _test_make_solid)
	_runner.add_test("TextureGenAPI: CPU 贴图生成器返回请求尺寸", _test_cpu_factories_dims)
	_runner.add_test("TextureGenAPI: 同 seed 生成逐字节一致（确定性）", _test_seed_determinism)
	_runner.add_test("TextureGenAPI: create_thatch_material 绑定 Shader", _test_thatch_material)
	_runner.add_test("TextureGenAPI: load_shader_material 已注册/未注册", _test_load_shader)
	_runner.add_test("TextureGenAPI: apply_material 替换目标材质", _test_apply_material)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _test_list_materials() -> void:
	var mats := ScriptTextureGenAPI.list_materials()
	_runner.assert_true(mats.size() >= 4, "至少注册 4 种材质")
	for expected: StringName in [&"thatch", &"stone_wall", &"stone_band", &"stone_window"]:
		_runner.assert_true(mats.has(expected), "缺材质 %s" % expected)


func _test_has_material() -> void:
	_runner.assert_true(ScriptTextureGenAPI.has_material(&"thatch"), "thatch 应已注册")
	_runner.assert_true(not ScriptTextureGenAPI.has_material(&"nonexistent_xyz"), "未注册 id 应返回 false")


func _test_make_solid() -> void:
	var tex := ScriptTextureGenAPI.make_solid(32, 16, Color.RED)
	_runner.assert_true(tex != null, "make_solid 应返回纹理")
	if tex != null:
		_runner.assert_equal(tex.get_width(), 32, "宽应为 32")
		_runner.assert_equal(tex.get_height(), 16, "高应为 16")
		var img := tex.get_image()
		_runner.assert_true(img != null, "应可取回源图像")
		if img != null:
			_runner.assert_equal(img.get_pixel(0, 0), Color.RED, "纯色贴图左上像素应为红")


func _test_cpu_factories_dims() -> void:
	var cases: Array = [
		["木柱", ScriptTextureGenAPI.make_wood_pillar(24, 48)],
		["木板", ScriptTextureGenAPI.make_wood_plank(24, 48)],
		["茅草", ScriptTextureGenAPI.make_straw_thatch(48, 24)],
		["层叠茅草", ScriptTextureGenAPI.make_thatch_layered(48, 32, 3)],
		["多边形茅草", ScriptTextureGenAPI.make_thatch_for_polygon(48, 32, 3)],
		["深石", ScriptTextureGenAPI.make_stone_dark(32, 32)],
		["铁", ScriptTextureGenAPI.make_metal_iron(16, 16)],
	]
	for case: Array in cases:
		var tex: ImageTexture = case[1]
		_runner.assert_true(tex != null, "%s 贴图应非空" % case[0])
		if tex != null:
			_runner.assert_true(tex.get_width() > 0 and tex.get_height() > 0, "%s 尺寸应为正" % case[0])


func _test_seed_determinism() -> void:
	var a := ScriptTextureGenAPI.make_thatch_layered(48, 32, 7)
	var b := ScriptTextureGenAPI.make_thatch_layered(48, 32, 7)
	var ia := a.get_image() if a != null else null
	var ib := b.get_image() if b != null else null
	_runner.assert_true(ia != null and ib != null, "两次生成均应可取回图像")
	if ia != null and ib != null:
		_runner.assert_equal(ia.get_data(), ib.get_data(), "同 seed 应逐字节一致")


func _test_thatch_material() -> void:
	var tex := ScriptTextureGenAPI.make_straw_thatch(32, 32)
	var mat := ScriptTextureGenAPI.create_thatch_material(tex)
	_runner.assert_true(mat != null, "应返回 ShaderMaterial")
	if mat != null:
		_runner.assert_true(mat.shader != null, "ShaderMaterial 应绑定 shader")


func _test_load_shader() -> void:
	var mat := ScriptTextureGenAPI.load_shader_material(&"stone_wall")
	_runner.assert_true(mat != null, "已注册材质应返回 ShaderMaterial")
	if mat != null:
		_runner.assert_true(mat.shader != null, "应绑定 stone_wall shader")
	_runner.assert_true(ScriptTextureGenAPI.load_shader_material(&"nonexistent_xyz") == null,
			"未注册材质应返回 null")


func _test_apply_material() -> void:
	var sprite := Sprite2D.new()
	var mat := ScriptTextureGenAPI.apply_material(sprite, &"stone_band")
	_runner.assert_true(mat != null, "apply_material 应返回新材质")
	_runner.assert_true(sprite.material == mat, "目标材质应被替换")
	sprite.free()
