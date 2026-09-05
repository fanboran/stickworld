extends Node
## 集成测试：伤害飘字（FxLibrary.spawn_damage_text）表现契约。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_fx_damage_text.tscn
##
## 退出码：0 全部通过，1 有失败
##
## 测试覆盖：
##   - 基准表现：zoom=1 普通伤 24 号/描边 6；文本取整；弹性起手放大
##   - 恒定屏上尺寸：拉远反向放大（zoom 0.5→48）+ 上下钳制（0.35→56 / 3.0→22）
##   - 暴击：34 号/描边 8 + 歪斜起手回正
##   - 生命周期：上浮淡出推进 + 0.7s 结束回池隐藏
##
## 飘字直挂 current_scene（与生产同路径）；本场景唯一 Camera2D 提供 zoom，
## FxLibrary 经 viewport.get_camera_2d() 读取。

const TestRunner := preload("res://tests/core/test_runner.gd")
const FxLibrary := preload("res://modules/fx/scripts/fx_library.gd")

var _runner: TestRunner
var _tests: Array = []
var _cam: Camera2D


func _ready() -> void:
	_runner = TestRunner.new()
	_cam = Camera2D.new()
	add_child(_cam)
	_cam.make_current()
	_register_tests()
	_run_tests_async()


func _register_tests() -> void:
	_tests.append({"name": "飘字: 基准表现（zoom=1 普通 24/描边6/弹性起手）", "fn": Callable(self, "_test_base"), "async": true})
	_tests.append({"name": "飘字: 拉远反向放大 zoom 0.5→48", "fn": Callable(self, "_test_zoom_out"), "async": true})
	_tests.append({"name": "飘字: 钳制上下限 0.35→56 / 3.0→22", "fn": Callable(self, "_test_clamp"), "async": true})
	_tests.append({"name": "飘字: 暴击 34/描边8 + 歪斜回正", "fn": Callable(self, "_test_crit"), "async": true})
	_tests.append({"name": "飘字: 上浮淡出 + 回池隐藏", "fn": Callable(self, "_test_lifecycle"), "async": true})


func _run_tests_async() -> void:
	for t in _tests:
		_runner.begin_test(t["name"])
		await t["fn"].call()
		_runner.end_test()
		print("完成: %s" % t["name"])
	print(_runner.summary())
	get_tree().quit(0 if _runner.all_passed() else 1)


## 等在场飘字全部结束回池（0.7s 总时长，留余量），保证逐用例只有一个可见 Label
func _settle() -> void:
	await get_tree().create_timer(0.9).timeout


## 生成一个飘字并返回其 Label（等 3 帧确保 deferred 挂载 + tween 启动）
func _spawn_one(amount: float, crit: bool) -> Label:
	FxLibrary.spawn_damage_text(get_tree(), Vector2(960.0, 540.0), amount, crit)
	for i in 3:
		await get_tree().process_frame
	var found: Array = []
	for c in get_tree().current_scene.get_children():
		if c is Label and c.visible:
			found.append(c)
	if found.size() != 1:
		push_error("可见飘字数量异常: %d（期望 1）" % found.size())
		return null
	return found[0]


func _test_base() -> void:
	await _settle()
	_cam.zoom = Vector2.ONE
	var lb := await _spawn_one(42.0, false)
	if lb == null:
		_runner.assert_true(false, "应恰好出现一个可见飘字 Label")
		return
	_runner.assert_equal(lb.text, "42", "文本应为取整后的伤害值")
	_runner.assert_equal(lb.get_theme_font_size("font_size"), 24, "zoom=1 普通伤害字号 24")
	_runner.assert_equal(lb.get_theme_constant("outline_size"), 6, "描边 = 字号/4 = 6")
	_runner.assert_true(lb.pivot_offset.x > 0.0 and lb.pivot_offset.y > 0.0,
		"弹性缩放支点应居中（reset_size 已生效）: %s" % str(lb.pivot_offset))
	_runner.assert_true(lb.scale.x > 1.1, "出生起手应为放大态（>1.1），实际 %f" % lb.scale.x)


func _test_zoom_out() -> void:
	await _settle()
	_cam.zoom = Vector2(0.5, 0.5)
	var lb := await _spawn_one(7.0, false)
	if lb == null:
		_runner.assert_true(false, "拉远场景下飘字未出现")
		return
	_runner.assert_equal(lb.get_theme_font_size("font_size"), 48, "zoom=0.5 应反向放大到 48")


func _test_clamp() -> void:
	await _settle()
	_cam.zoom = Vector2(0.35, 0.35)
	var lb := await _spawn_one(9.0, false)
	if lb == null:
		_runner.assert_true(false, "极限拉远场景下飘字未出现")
		return
	_runner.assert_equal(lb.get_theme_font_size("font_size"), 56, "zoom=0.35 应钳制在 56 上限")
	await _settle()
	_cam.zoom = Vector2(3.0, 3.0)
	lb = await _spawn_one(11.0, false)
	if lb == null:
		_runner.assert_true(false, "极限拉近场景下飘字未出现")
		return
	_runner.assert_equal(lb.get_theme_font_size("font_size"), 22, "zoom=3.0 应钳制在 22 下限")


func _test_crit() -> void:
	await _settle()
	_cam.zoom = Vector2.ONE
	var lb := await _spawn_one(99.0, true)
	if lb == null:
		_runner.assert_true(false, "暴击飘字未出现")
		return
	_runner.assert_equal(lb.get_theme_font_size("font_size"), 34, "暴击字号 34")
	_runner.assert_equal(lb.get_theme_constant("outline_size"), 8, "暴击描边 34/4=8")
	_runner.assert_true(absf(lb.rotation) > 0.001, "暴击起手应带歪斜，实际 %f" % lb.rotation)
	await get_tree().create_timer(0.35).timeout
	_runner.assert_true(absf(lb.rotation) < 0.02, "歪斜应在 0.22s 内回正，实际 %f" % lb.rotation)
	_runner.assert_true(lb.scale.x < 1.05, "弹性回落应接近 1，实际 %f" % lb.scale.x)


func _test_lifecycle() -> void:
	await _settle()
	_cam.zoom = Vector2.ONE
	var lb := await _spawn_one(13.0, false)
	if lb == null:
		_runner.assert_true(false, "生命周期用例飘字未出现")
		return
	var y0: float = lb.position.y
	await get_tree().create_timer(0.35).timeout
	_runner.assert_true(lb.position.y < y0 - 10.0,
		"0.35s 应上浮 >10px，实际 Δ=%f" % (y0 - lb.position.y))
	_runner.assert_true(lb.modulate.a < 1.0, "0.25s 后淡出应已开始，a=%f" % lb.modulate.a)
	await get_tree().create_timer(0.9).timeout
	_runner.assert_false(lb.visible, "0.7s 结束后应隐藏回池")
