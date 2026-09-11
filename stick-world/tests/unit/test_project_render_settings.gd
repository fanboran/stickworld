extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：project.godot 关键渲染/物理配置看门狗。
##
## 回归背景：Godot 4.7.2 配置解析器有"段头附近中文注释被吞、后续键行并入乱码键"
## 的事故前科（两次），[rendering] 段曾整段消失导致 msaa_2d 静默失效——
## 全项目零抗锯齿且无任何运行时报错。本套件锁定配置文件中关键键的实际解析值，
## 段头/键再丢失时此处立刻变红，不再静默。
##
## 注意：编辑 project.godot 时段头附近禁放注释（解析器吞行前科），说明写进交接档。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("渲染配置: msaa_2d = 2（4x，抗锯齿生命线）", _test_msaa_2d)
	_runner.add_test("渲染配置: msaa_3d = 2（同段锚点）", _test_msaa_3d)
	_runner.add_test("渲染配置: rendering_device/driver.windows = d3d12", _test_rendering_driver)
	_runner.add_test("物理配置: physics_ticks_per_second = 30", _test_physics_ticks)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _setting_int(key: String) -> int:
	return int(ProjectSettings.get_setting(key, 0))


func _test_msaa_2d() -> void:
	# 段被吞时键路径不存在，get_setting 落回默认 0 → 此处必红
	_runner.assert_equal(_setting_int("rendering/anti_aliasing/quality/msaa_2d"), 2,
			"msaa_2d 应为 2（4x）；为 0 说明 [rendering] 段头或键被解析器吞掉")


func _test_msaa_3d() -> void:
	_runner.assert_equal(_setting_int("rendering/anti_aliasing/quality/msaa_3d"), 2,
			"msaa_3d 应为 2（4x）")


func _test_rendering_driver() -> void:
	var driver: String = str(ProjectSettings.get_setting(
			"rendering/rendering_device/driver.windows", ""))
	_runner.assert_equal(driver, "d3d12", "Windows 渲染驱动应为 d3d12")


func _test_physics_ticks() -> void:
	_runner.assert_equal(_setting_int("physics/common/physics_ticks_per_second"), 30,
			"物理 tick 应为 30Hz（百人级混战标准）")
