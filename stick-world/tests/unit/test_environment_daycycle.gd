extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：EnvironmentAPI 昼夜采样纯函数（environment 模块）。
##
## 覆盖面：
##   - 关键帧表不变量：LIGHT/SKY_BG 两表 hour 严格升序、首尾同色闭环
##     （sample_keyframes 的文档前提，破表 = 全天采样错档）
##   - 关键帧精确命中：整点采样返回该帧原色
##   - 区间线性插值：段内 lerp 与手算一致（黄昏粉峰半程等）
##   - 超界回退：hour < 首帧 或 > 末帧 回落首帧（午夜）
##   - 零跨度守卫：重复 hour 帧返回先帧色（防除零）
##   - unmodulate 发光体补偿：逐通道除法、0.045 下限防除零、alpha 保持、
##     白光恒等
##   - 昼夜亮度档：正午 > 清晨 > 入夜 > 午夜（CanvasModulate 染地表的量级序）
##
## batch 准入：纯静态函数，零 fixture 零 autoload。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const EnvAPI := preload("res://modules/environment/api.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("表不变量: hour 升序 + 首尾闭环（双表）", _test_table_invariants)
	_runner.add_test("精确命中: 整点返回关键帧原色", _test_exact_keyframes)
	_runner.add_test("区间插值: 段内 lerp 手算一致", _test_segment_interpolation)
	_runner.add_test("超界回退: 越界回落首帧", _test_out_of_range_fallback)
	_runner.add_test("零跨度守卫: 重复 hour 帧不除零", _test_zero_span_guard)
	_runner.add_test("unmodulate: 逐通道补偿/下限/alpha/恒等", _test_unmodulate)
	_runner.add_test("亮度档: 正午>清晨>入夜>午夜", _test_luminance_order)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────────────── 用例 ────────────────────────────────

func _test_table_invariants() -> void:
	for table_name: String in ["LIGHT", "SKY_BG"]:
		var frames: Array = EnvAPI.LIGHT_KEYFRAMES if table_name == "LIGHT" else EnvAPI.SKY_BG_KEYFRAMES
		_runner.assert_true(frames.size() >= 2, "%s 表至少两帧" % table_name)
		for i in range(frames.size()):
			var f: Dictionary = frames[i]
			_runner.assert_true(f.has("hour") and f.has("color"), "%s 表第 %d 帧字段齐全" % [table_name, i])
			if i == 0:
				continue
			_runner.assert_true(float(f["hour"]) > float(frames[i - 1]["hour"]),
					"%s 表第 %d 帧 hour 严格升序" % [table_name, i])
		_runner.assert_true((frames[0]["color"] as Color).is_equal_approx(frames[frames.size() - 1]["color"]),
				"%s 表首尾同色闭环（0 点 == 24 点）" % table_name)
		_runner.assert_approx(float(frames[0]["hour"]), 0.0, 0.0001, "%s 表首帧 0 点" % table_name)
		_runner.assert_approx(float(frames[frames.size() - 1]["hour"]), 24.0, 0.0001, "%s 表末帧 24 点" % table_name)


func _test_exact_keyframes() -> void:
	# 环境光（CanvasModulate 轨道）：逐帧整点 == 原色
	for f: Dictionary in EnvAPI.LIGHT_KEYFRAMES:
		_runner.assert_true(EnvAPI.sample_light_color(float(f["hour"])).is_equal_approx(f["color"]),
				"光照 %.1f 点整返回原帧色" % float(f["hour"]))
	# 天空底色（清屏色轨道）：抽正午白与日落粉峰
	_runner.assert_true(EnvAPI.sample_sky_bg_color(12.0).is_equal_approx(Color(1, 1, 1)),
			"天空 12 点全白（Terraria 正午口径）")
	var pink: Color = EnvAPI.sample_sky_bg_color(19.0)
	_runner.assert_gt(pink.r, 0.85, "日落粉峰 R 高")
	_runner.assert_true(pink.g < pink.r and pink.b > pink.g, "日落粉峰 G 低 B 中（粉调）")


func _test_segment_interpolation() -> void:
	# 光照：5 点黎明前(0.10,0.135,0.135) → 7 点早晨(0.95,0.92,0.85)，6 点取半程
	var f5: Color = EnvAPI.LIGHT_KEYFRAMES[1]["color"]
	var f7: Color = EnvAPI.LIGHT_KEYFRAMES[2]["color"]
	var expect: Color = f5.lerp(f7, 0.5)
	var got: Color = EnvAPI.sample_light_color(6.0)
	_runner.assert_true(got.is_equal_approx(expect), "光照 6 点 = 黎明前↔早晨半程")
	# 天空：17 点全白 → 19 点粉峰，18 点半程（粉峰爬坡）
	var w: Color = EnvAPI.SKY_BG_KEYFRAMES[3]["color"]
	var p: Color = EnvAPI.SKY_BG_KEYFRAMES[4]["color"]
	var expect_sky: Color = w.lerp(p, 0.5)
	_runner.assert_true(EnvAPI.sample_sky_bg_color(18.0).is_equal_approx(expect_sky),
			"天空 18 点 = 白↔粉峰半程")
	# 段内非中点：光照 20 点 = 19 点黄昏→21 点入夜 t=0.5（同款再验一段）
	var dusk: Color = EnvAPI.LIGHT_KEYFRAMES[5]["color"]
	var night: Color = EnvAPI.LIGHT_KEYFRAMES[6]["color"]
	_runner.assert_true(EnvAPI.sample_light_color(20.0).is_equal_approx(dusk.lerp(night, 0.5)),
			"光照 20 点 = 黄昏↔入夜半程")


func _test_out_of_range_fallback() -> void:
	var midnight: Color = EnvAPI.LIGHT_KEYFRAMES[0]["color"]
	_runner.assert_true(EnvAPI.sample_light_color(-5.0).is_equal_approx(midnight),
			"hour<0 回落首帧（午夜）")
	_runner.assert_true(EnvAPI.sample_light_color(30.0).is_equal_approx(midnight),
			"hour>24 回落首帧（系统侧 fposmod 包 0..24，超界属防御路径）")
	var sky_mid: Color = EnvAPI.SKY_BG_KEYFRAMES[0]["color"]
	_runner.assert_true(EnvAPI.sample_sky_bg_color(99.0).is_equal_approx(sky_mid),
			"天空表同口径回落首帧")


func _test_zero_span_guard() -> void:
	# 首帧即重复 hour：span<=0 守卫返回先帧色（不除零不取后帧）
	var green := Color(0.1, 0.8, 0.2)
	var blue := Color(0.2, 0.2, 0.9)
	var frames: Array = [
		{"hour": 5.0, "color": green},
		{"hour": 5.0, "color": blue},
		{"hour": 10.0, "color": blue},
	]
	_runner.assert_true(EnvAPI.sample_keyframes(frames, 5.0).is_equal_approx(green),
			"零跨度段返回先帧色")


func _test_unmodulate() -> void:
	# 白光 CanvasModulate：恒等
	var c := Color(0.6, 0.7, 0.8, 0.5)
	_runner.assert_true(EnvAPI.unmodulate(c, Color.WHITE).is_equal_approx(c), "白光补偿恒等")
	# 夜色 CanvasModulate：逐通道除法还原屏显目标色
	var night := Color(0.5, 0.25, 0.1, 1.0)
	var got := EnvAPI.unmodulate(Color(0.5, 0.25, 0.1, 0.9), night)
	_runner.assert_approx(got.r, 1.0, 0.0001, "R 通道除夜色还原")
	_runner.assert_approx(got.g, 1.0, 0.0001, "G 通道除夜色还原")
	_runner.assert_approx(got.b, 1.0, 0.0001, "B 通道除夜色还原")
	_runner.assert_approx(got.a, 0.9, 0.0001, "alpha 不参与补偿")
	# 下限 0.045：通道暗过阈值时按 0.045 除（防除零爆炸）
	var black := Color(0.0, 0.02, 0.04, 1.0)
	var got2 := EnvAPI.unmodulate(Color(0.09, 0.09, 0.09, 1.0), black)
	_runner.assert_approx(got2.r, 2.0, 0.0001, "0 通道按下限 0.045 除")
	_runner.assert_approx(got2.g, 2.0, 0.0001, "0.02<0.045 同按下限除")
	_runner.assert_approx(got2.b, 2.0, 0.0001, "0.04<0.045 同按下限除")


func _test_luminance_order() -> void:
	var noon: float = EnvAPI.sample_light_color(12.0).get_luminance()
	var morning: float = EnvAPI.sample_light_color(8.0).get_luminance()
	var dusk: float = EnvAPI.sample_light_color(19.0).get_luminance()
	var nightfall: float = EnvAPI.sample_light_color(21.0).get_luminance()
	var midnight: float = EnvAPI.sample_light_color(0.0).get_luminance()
	_runner.assert_gt(noon, 0.9, "正午环境光接近全亮")
	_runner.assert_gt(morning, 0.8, "清晨 8 点开局是亮档（新游戏晨 8 点约定）")
	_runner.assert_gt(morning, dusk, "清晨亮于黄昏")
	_runner.assert_gt(dusk, nightfall, "黄昏亮于入夜")
	_runner.assert_gt(nightfall, midnight, "入夜亮于午夜")
	_runner.assert_lt(midnight, 0.1, "午夜压至剪影量级（<0.1）")
	# 开局档与深夜档拉开量级：灯火/剪影体验的下限
	_runner.assert_gt(morning / maxf(midnight, 0.001), 5.0, "昼夜亮度比 >5 倍")
