extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：关节图集 mip 白化（治「面片边缘还有更深色的描边」）。
##
## 机制：图集是「RGB 恒白 + 形状在 alpha」，但视口回读出来的形状外是**透明黑垫**
## （PAD 区、圆角外一律 (0,0,0,0)）。`char3d_body_opaque` 是 `ALBEDO = t.rgb ×
## 实例色`，所以 mip 逐级平均把黑 RGB 混进形状边缘时，部件外缘 albedo 被压暗——
## 叠在自身深色部件上就是一圈比本体更深的镶边。修法见 char_joint_atlas._whiten_rgb：
## 生成 mip 前先把 RGB 全刷白（alpha 仍承运形状）。
##
## 本测试直接量**真实 mip 链**（get_mipmap_offset 逐级读 RGBA8 原始字节，与
## char_joint_atlas._bake 的回读→generate_mipmaps 同一路径）：
##   ① 不白化 → 形状边缘在最暗 mip 里 RGB 明显被拉黑（对照组，复现缺陷）；
##   ② 白化后 → 任何 mip 级别里 alpha>0 的像素 RGB 恒为白；
##   ③ 白化不动 alpha（形状仍由 alpha 承运）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const JointAtlas := preload("res://modules/hd2d/scripts/char_joint_atlas.gd")

const SHAPE := Rect2i(10, 8, 44, 16)   # 合成图集里的「胶囊」格位内容


var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("mip 混黑：不白化时形状边缘 RGB 被拉黑（对照组）", _test_control_darkens)
	_runner.add_test("mip 白化：任何 mip 级别下 alpha>0 的 RGB 恒为白", _test_whiten_keeps_white)
	_runner.add_test("mip 白化：alpha 通道原样保留（形状不被改写）", _test_whiten_keeps_alpha)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


## 合成一张"烘焙原始回读"图：白形状 + 四周透明黑垫（RGB 与 alpha 均 0）
func _make_raw() -> Image:
	var img := Image.create(64, 32, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	img.fill_rect(SHAPE, Color(1, 1, 1, 1))
	return img


## 逐 mip 级别读原始 RGBA8 字节，返回"有 alpha 像素"的最暗 RGB（0~1）
func _min_rgb_in_mips(img: Image) -> float:
	var data := img.get_data()
	var lo := 1.0
	for level in img.get_mipmap_count():
		var w := maxi(1, img.get_width() >> level)
		var h := maxi(1, img.get_height() >> level)
		var off := img.get_mipmap_offset(level)
		for i in w * h:
			var p := off + i * 4
			if data[p + 3] / 255.0 > 0.02:
				var mn := mini(data[p], mini(data[p + 1], data[p + 2]))
				lo = minf(lo, mn / 255.0)
	return lo


func _test_control_darkens() -> void:
	# 对照组：原始回读（形状外透明黑）直接生成 mip → 形状边缘被黑拉低
	var img := _make_raw()
	img.generate_mipmaps()
	_runner.assert_true(img.has_mipmaps(), "回读图应能生成 mip 链")
	var lo := _min_rgb_in_mips(img)
	print("    [数据] 对照组（不白化）最暗有 alpha 像素 RGB=%.3f" % lo)
	_runner.assert_lt(lo, 0.9, "不白化时 mip 里的形状边缘 RGB 应明显发暗（实测最暗 RGB=%.3f）" % lo)


func _test_whiten_keeps_white() -> void:
	var img := _make_raw()
	JointAtlas._whiten_rgb(img)
	img.generate_mipmaps()
	var lo := _min_rgb_in_mips(img)
	print("    [数据] 白化后最暗有 alpha 像素 RGB=%.3f" % lo)
	_runner.assert_gt(lo, 0.99, "白化后任何 mip 级别的有 alpha 像素 RGB 应为白（实测=%.3f）" % lo)


func _test_whiten_keeps_alpha() -> void:
	var img := _make_raw()
	var before: Image = img.duplicate()
	JointAtlas._whiten_rgb(img)
	var diff := 0
	for y in img.get_height():
		for x in img.get_width():
			if not is_equal_approx(img.get_pixel(x, y).a, before.get_pixel(x, y).a):
				diff += 1
	_runner.assert_equal(diff, 0, "白化不得改动任何像素的 alpha（实测改动 %d 个）" % diff)
