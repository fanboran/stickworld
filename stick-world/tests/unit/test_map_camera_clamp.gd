extends Node
## 单元测试：MapCamera 视口限位（A3 全屏 L3 相机 clamp）。
##
## 覆盖 _clamp_axis_strict / _clamp_axis_loose 纯数学（static，无需场景树/视口）
## + 限位状态默认关闭 / set_viewport_clamp / clear_viewport_clamp。
## 屏幕坐标约定：地图点 M 的屏幕位置 = offset + M × zoom，
## 地图轴起点屏幕坐标 = offset + bounds.pos × zoom（_apply_clamp 传入的就是该起点）。

signal test_done(code: int)

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptMapCamera := preload("res://modules/world_map/scripts/map_camera.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("Clamp: 默认无限位（L1/L2 行为不变）", _test_default_off)
	_runner.add_test("Clamp: set/clear_viewport_clamp 状态", _test_set_clear)
	_runner.add_test("Clamp: strict 恰好适配（区间单点，双侧贴边界）", _test_strict_exact_fit)
	_runner.add_test("Clamp: strict 地图大于视口（两侧拉回）", _test_strict_pull_back)
	_runner.add_test("Clamp: strict 区间空兜底居中（resize 后 zoom 偏小）", _test_strict_fallback_center)
	_runner.add_test("Clamp: loose 地图小于视口（屏内自由平移）", _test_loose_free_inside)
	_runner.add_test("Clamp: loose 完全移出屏幕被拉回（保留 keep 像素）", _test_loose_pull_back)
	_runner.add_test("Clamp: loose 区间空兜底居中（极端小视口）", _test_loose_fallback_center)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _test_default_off() -> void:
	var cam := ScriptMapCamera.new()
	cam.queue_free()
	_runner.assert_equal(cam._clamp_x, ScriptMapCamera.ClampMode.CLAMP_OFF, "X 轴默认应无限位")
	_runner.assert_equal(cam._clamp_y, ScriptMapCamera.ClampMode.CLAMP_OFF, "Y 轴默认应无限位")


func _test_set_clear() -> void:
	var cam := ScriptMapCamera.new()
	cam.queue_free()
	cam.set_viewport_clamp(ScriptMapCamera.ClampMode.CLAMP_LOOSE,
			ScriptMapCamera.ClampMode.CLAMP_STRICT, Rect2(0, 0, 8192, 8192), 64.0, 96.0)
	_runner.assert_equal(cam._clamp_x, ScriptMapCamera.ClampMode.CLAMP_LOOSE, "set 后 X=宽松")
	_runner.assert_equal(cam._clamp_y, ScriptMapCamera.ClampMode.CLAMP_STRICT, "set 后 Y=严格")
	_runner.assert_equal(cam._clamp_buffer, 64.0, "buffer 应记录")
	_runner.assert_equal(cam._clamp_keep, 96.0, "keep 应记录")
	cam.clear_viewport_clamp()
	_runner.assert_equal(cam._clamp_x, ScriptMapCamera.ClampMode.CLAMP_OFF, "clear 后 X 关")
	_runner.assert_equal(cam._clamp_y, ScriptMapCamera.ClampMode.CLAMP_OFF, "clear 后 Y 关")


## vlen=1080, buffer=64, len=1208=1080+128 → 区间 [lo,hi]=[-64,-64] 单点：
## 上边屏外 64px、下边屏外 64px（L3 全屏初始适配即此形态）
func _test_strict_exact_fit() -> void:
	var start := ScriptMapCamera._clamp_axis_strict(-64.0, 1208.0, 1080.0, 64.0)
	_runner.assert_approx(start, -64.0, 0.001, "单点区间应稳定在 -buffer")
	# 越界值都被拉回单点
	_runner.assert_approx(ScriptMapCamera._clamp_axis_strict(0.0, 1208.0, 1080.0, 64.0), -64.0, 0.001, "上边界进屏应拉回")
	_runner.assert_approx(ScriptMapCamera._clamp_axis_strict(-300.0, 1208.0, 1080.0, 64.0), -64.0, 0.001, "下边界进屏应拉回")


## len=1600 > 1208 → 区间 [-456, -64]，两端拉回、区间内自由
func _test_strict_pull_back() -> void:
	_runner.assert_approx(ScriptMapCamera._clamp_axis_strict(0.0, 1600.0, 1080.0, 64.0), -64.0, 0.001, "上边界越界拉回 -64")
	_runner.assert_approx(ScriptMapCamera._clamp_axis_strict(-1000.0, 1600.0, 1080.0, 64.0), -456.0, 0.001, "下边界越界拉回 -456")
	_runner.assert_approx(ScriptMapCamera._clamp_axis_strict(-200.0, 1600.0, 1080.0, 64.0), -200.0, 0.001, "区间内不动")
	# 不变量：clamp 后 上边=start ≤ -buffer 且 下边=start+len ≥ vlen+buffer
	var s := ScriptMapCamera._clamp_axis_strict(500.0, 1600.0, 1080.0, 64.0)
	_runner.assert_true(s <= -64.0 + 0.001, "上边应在屏外 ≥buffer")
	_runner.assert_true(s + 1600.0 >= 1080.0 + 64.0 - 0.001, "下边应在屏外 ≥buffer")


## len=1000 < vlen+2×buffer=1208 → 区间空，兜底居中 (vlen-len)/2
func _test_strict_fallback_center() -> void:
	var s := ScriptMapCamera._clamp_axis_strict(0.0, 1000.0, 1080.0, 64.0)
	_runner.assert_approx(s, 40.0, 0.001, "区间空应兜底居中 (1080-1000)/2")


## vlen=1920, keep=96, len=1000（地图窄于视口）：区间 [-904, 1824] 覆盖全屏+越界余量
func _test_loose_free_inside() -> void:
	_runner.assert_approx(ScriptMapCamera._clamp_axis_loose(460.0, 1000.0, 1920.0, 96.0), 460.0, 0.001, "屏内居中不动")
	_runner.assert_approx(ScriptMapCamera._clamp_axis_loose(0.0, 1000.0, 1920.0, 96.0), 0.0, 0.001, "贴左缘不动")


## 越界：起点 > 1824（左端将保留不足 keep）→ 拉回；起点 < -904 → 拉回
func _test_loose_pull_back() -> void:
	_runner.assert_approx(ScriptMapCamera._clamp_axis_loose(2000.0, 1000.0, 1920.0, 96.0), 1824.0, 0.001, "右移越界拉回 vlen-keep")
	_runner.assert_approx(ScriptMapCamera._clamp_axis_loose(-2000.0, 1000.0, 1920.0, 96.0), -904.0, 0.001, "左移越界拉回 keep-len")
	# 地图宽于视口（len=3000）：区间 [-2904, 1824]
	_runner.assert_approx(ScriptMapCamera._clamp_axis_loose(1900.0, 3000.0, 1920.0, 96.0), 1824.0, 0.001, "大地图左移越界拉回")


## vlen=100, keep=96, len=0 → lo=96 > hi=4 区间空，兜底居中 50
func _test_loose_fallback_center() -> void:
	var s := ScriptMapCamera._clamp_axis_loose(0.0, 0.0, 100.0, 96.0)
	_runner.assert_approx(s, 50.0, 0.001, "极端区间空应兜底居中 vlen/2")
