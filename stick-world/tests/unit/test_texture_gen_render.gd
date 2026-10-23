extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：TextureGenAPI 渲染质量断言（与 test_texture_gen_api 互补分层）。
##
## api 套件管「接口契约」（材质注册 / 工厂非空 / 材质绑定）；本套件管「像素质量」——
## 生成纹理取回 Image 后逐像素断言：
##   1. 尺寸与格式（RGBA8）
##   2. 非平涂：噪声类贴图有明暗结构（亮度 min < max）且非黑内容
##   3. alpha 通道语义：不透明生成器全像素 a=1；make_solid 半透明色保 alpha
##   4. 真生成确定性：清缓存后同参两炉逐字节一致（比生成数学，非 memo 复用）
##   5. seed 敏感：换 seed 图必不同
##   6. 同参同图缓存：聚落同款建筑共享零开销的缓存契约
## 纯 CPU 逻辑：不进场景树、不碰 autoload、零数帧。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
# 依赖纯逻辑/纯数据一律显式 preload（tests/README 禁区：不依赖 class_name 全局注册）
const ScriptTextureGenAPI := preload("res://modules/texture_gen/api.gd")
const ScriptProceduralMaterials := preload("res://modules/texture_gen/scripts/procedural_materials.gd")

## RGBA8 量化步长（1/255 ≈ 0.0039）：像素级近似断言的容差
const PIXEL_EPS := 0.004

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("渲染: 全生成器尺寸与 RGBA8 格式", _test_dims_and_format)
	_runner.add_test("渲染: 噪声贴图非平涂（有明暗结构）", _test_not_flat)
	_runner.add_test("渲染: 不透明贴图 alpha 全 1 / solid 保 alpha", _test_alpha)
	_runner.add_test("渲染: 真生成确定性（清缓存两炉一致）", _test_generation_determinism)
	_runner.add_test("渲染: seed 敏感（换 seed 图必不同）", _test_seed_sensitivity)
	_runner.add_test("渲染: 同参同图缓存（聚落同款零开销）", _test_cache_identity)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ── 用例 ────────────────────────────────────────────────────

## 用例 1：每个 CPU 生成器都返回请求尺寸（行内声明期望宽高）+ 可取回 RGBA8 Image。
## 行格式：[名称, ImageTexture, 期望宽, 期望高]
func _test_dims_and_format() -> void:
	var cases: Array = [
		["木柱", ScriptTextureGenAPI.make_wood_pillar(24, 48, Color(0.4, 0.3, 0.2)), 24, 48],
		["木板", ScriptTextureGenAPI.make_wood_plank(24, 48, Color(0.5, 0.33, 0.18)), 24, 48],
		["稻草", ScriptTextureGenAPI.make_straw_thatch(32, 24, Color(0.72, 0.6, 0.3)), 32, 24],
		["层叠茅草", ScriptTextureGenAPI.make_thatch_layered(48, 32, 3), 48, 32],
		["多边形茅草", ScriptTextureGenAPI.make_thatch_for_polygon(40, 28, 5), 40, 28],
		["深石", ScriptTextureGenAPI.make_stone_dark(32, 32, Color(0.25, 0.22, 0.2)), 32, 32],
		["铁", ScriptTextureGenAPI.make_metal_iron(16, 16), 16, 16],
		["纯色", ScriptTextureGenAPI.make_solid(32, 16, Color.RED), 32, 16],
	]
	for case: Array in cases:
		var tex: ImageTexture = case[1]
		_runner.assert_true(tex != null, "%s 应返回纹理" % case[0])
		if tex == null:
			continue
		_runner.assert_equal(tex.get_width(), int(case[2]), "%s 宽应等于请求值" % case[0])
		_runner.assert_equal(tex.get_height(), int(case[3]), "%s 高应等于请求值" % case[0])
		var img := tex.get_image()
		_runner.assert_true(img != null, "%s 应可取回源图像" % case[0])
		if img != null:
			_runner.assert_true(img.get_format() == Image.FORMAT_RGBA8,
					"%s 应为 RGBA8 格式" % case[0])


## 用例 2：噪声类贴图非平涂——亮度有跨度（min < max）且有非黑内容；
## solid 是唯一「应平涂」的例外，抽样像素精确等于请求色。
func _test_not_flat() -> void:
	var noisy: Array = [
		["木柱", ScriptTextureGenAPI.make_wood_pillar(24, 48, Color(0.4, 0.3, 0.2))],
		["木板", ScriptTextureGenAPI.make_wood_plank(24, 48, Color(0.5, 0.33, 0.18))],
		["稻草", ScriptTextureGenAPI.make_straw_thatch(32, 24, Color(0.72, 0.6, 0.3))],
		["层叠茅草", ScriptTextureGenAPI.make_thatch_layered(48, 32, 3)],
		["深石", ScriptTextureGenAPI.make_stone_dark(32, 32, Color(0.25, 0.22, 0.2))],
	]
	for case: Array in noisy:
		var span: Vector2 = _luminance_span((case[1] as ImageTexture).get_image())
		_runner.assert_gt(span.y, span.x, "%s 应有明暗结构（亮度跨度 > 0）" % case[0])
		_runner.assert_gt(span.y, 0.05, "%s 应有非黑内容（最亮 > 0.05）" % case[0])
	# solid 例外：抽样像素（四角 + 内点）精确等于请求色
	var img := ScriptTextureGenAPI.make_solid(32, 16, Color(0.3, 0.6, 0.9)).get_image()
	for p: Vector2i in [Vector2i(0, 0), Vector2i(31, 15), Vector2i(17, 7), Vector2i(5, 12)]:
		var c := img.get_pixel(p.x, p.y)
		_runner.assert_approx(c.r, 0.3, PIXEL_EPS, "solid(%d,%d) R" % [p.x, p.y])
		_runner.assert_approx(c.g, 0.6, PIXEL_EPS, "solid(%d,%d) G" % [p.x, p.y])
		_runner.assert_approx(c.b, 0.9, PIXEL_EPS, "solid(%d,%d) B" % [p.x, p.y])


## 用例 3：不透明生成器全像素 alpha=1（纹理做画面内容，不做形状蒙版）；
## make_solid 是唯一透传调用方 alpha 的出口（0.5 经 RGBA8 量化误差 ≤ 1/255）。
func _test_alpha() -> void:
	var opaque: Array = [
		["木柱", ScriptTextureGenAPI.make_wood_pillar(20, 20, Color(0.4, 0.3, 0.2))],
		["稻草", ScriptTextureGenAPI.make_straw_thatch(20, 20, Color(0.72, 0.6, 0.3))],
		["层叠茅草", ScriptTextureGenAPI.make_thatch_layered(32, 32, 9)],
		["深石", ScriptTextureGenAPI.make_stone_dark(20, 20, Color(0.25, 0.22, 0.2))],
	]
	for case: Array in opaque:
		var img: Image = (case[1] as ImageTexture).get_image()
		_runner.assert_equal(_count_transparent(img), 0, "%s 不应含透明像素" % case[0])
	var semi: Image = ScriptTextureGenAPI.make_solid(8, 8, Color(1, 0, 0, 0.5)).get_image()
	for y in 8:
		for x in 8:
			_runner.assert_approx(semi.get_pixel(x, y).a, 0.5, PIXEL_EPS,
					"solid(%d,%d) alpha 透传" % [x, y])


## 用例 4：真生成确定性——每炉生成前清缓存，同参两炉逐字节一致。
## （不清缓存的话第二炉命中 memo，比的是缓存而非生成数学。）
func _test_generation_determinism() -> void:
	var recipes: Array = [
		["层叠茅草", func() -> ImageTexture: return ScriptTextureGenAPI.make_thatch_layered(48, 32, 7)],
		["木柱", func() -> ImageTexture: return ScriptTextureGenAPI.make_wood_pillar(24, 40, Color(0.4, 0.3, 0.2))],
		["木板", func() -> ImageTexture: return ScriptTextureGenAPI.make_wood_plank(24, 40, Color(0.5, 0.33, 0.18))],
		["稻草", func() -> ImageTexture: return ScriptTextureGenAPI.make_straw_thatch(32, 24, Color(0.72, 0.6, 0.3))],
		["深石", func() -> ImageTexture: return ScriptTextureGenAPI.make_stone_dark(24, 24, Color(0.25, 0.22, 0.2))],
	]
	for recipe: Array in recipes:
		ScriptProceduralMaterials.reset_static_caches()
		var a: ImageTexture = (recipe[1] as Callable).call()
		ScriptProceduralMaterials.reset_static_caches()
		var b: ImageTexture = (recipe[1] as Callable).call()
		_runner.assert_true(a != null and b != null, "%s 两炉均应非空" % recipe[0])
		if a != null and b != null:
			_runner.assert_equal(a.get_image().get_data(), b.get_image().get_data(),
					"%s 同参两炉应逐字节一致" % recipe[0])
	# 收尾清缓存：不把本套件产物留给后续套件（缓存重建是纯 memo，语义无影响）
	ScriptProceduralMaterials.reset_static_caches()


## 用例 5：seed 敏感——同尺寸换 seed 生成不同图（seed 失效 = 聚落建筑同脸）。
func _test_seed_sensitivity() -> void:
	var a := ScriptTextureGenAPI.make_thatch_layered(48, 32, 7)
	var b := ScriptTextureGenAPI.make_thatch_layered(48, 32, 8)
	_runner.assert_true(a != null and b != null, "两个 seed 均应生成成功")
	if a != null and b != null:
		_runner.assert_not_equal(a.get_image().get_data(), b.get_image().get_data(),
				"seed 7 与 8 应生成不同图")
	# 多边形茅草是 layered 的转发口，seed 同样要透传
	var c := ScriptTextureGenAPI.make_thatch_for_polygon(48, 32, 7)
	var d := ScriptTextureGenAPI.make_thatch_for_polygon(48, 32, 8)
	_runner.assert_true(c != null and d != null, "多边形茅草两 seed 均应生成成功")
	if c != null and d != null:
		_runner.assert_not_equal(c.get_image().get_data(), d.get_image().get_data(),
				"多边形茅草 seed 透传应有效")


## 用例 6：同参同图缓存契约——第二次调用返回同一 ImageTexture 实例
## （ImageTexture 不可变，多 Sprite2D 共享安全；这是聚落零开销承诺的实现面）。
func _test_cache_identity() -> void:
	var color := Color(0.42, 0.40, 0.42)
	var a := ScriptTextureGenAPI.make_stone_dark(20, 20, color)
	var b := ScriptTextureGenAPI.make_stone_dark(20, 20, color)
	_runner.assert_true(a == b, "同参应返回同一缓存实例")
	var c := ScriptTextureGenAPI.make_solid(8, 8, Color(0.1, 0.2, 0.3))
	var d := ScriptTextureGenAPI.make_solid(8, 8, Color(0.1, 0.2, 0.3))
	_runner.assert_true(c == d, "solid 同样走同参缓存")


# ── helpers ─────────────────────────────────────────────────

## 全图像亮度跨度（min, max）：平涂贴图跨度为 0
func _luminance_span(img: Image) -> Vector2:
	var lo := 1.0
	var hi := 0.0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			var lum: float = c.r + c.g + c.b
			lo = minf(lo, lum)
			hi = maxf(hi, lum)
	return Vector2(lo, hi)


## 全图透明像素计数（alpha < 1；RGBA8 下 a=1.0 精确）
func _count_transparent(img: Image) -> int:
	var n := 0
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).a < 1.0:
				n += 1
	return n
