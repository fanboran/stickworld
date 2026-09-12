extends Node
## 单元测试：火柴人身体染色防回归锁。
##
## 约束（不是"曾经怎么做"，而是本项目的设计口径）：
## 火柴人身体**不做身份染色**——身份识别走独立通道：
##   - 阵营：头顶血条（HealthBarIndicator 圆点/横条）
##   - 职业：手持武器变体（weapon_mount.weapon_type）
## 身体色唯一来源是 Skeleton.DEFAULT_BODY 常量，任何按阵营/职业改身体色的实现
## 都属于回归。本套件从接口面与源码面同时钉死这一点：
##   - StickmanRig 脚本不再暴露 body_color 属性（染色口子本身不存在）
##   - 三个曾经的落点（rig 组装 / 批量渲染 / 职业装具）源码无 body_color 引用
##   - Skeleton.DEFAULT_BODY 常量存在（身体色唯一来源）
##
## 注意：锁 2 是词面扫描（含注释），三个落点文件里连注释都不应再出现该属性名。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")

## batch_runner 收割退出码用（TestRunner.finish_process 依赖本信号）
signal test_done(code: int)

const RIG_PATH := "res://modules/units/scripts/rig/stickman_rig.gd"
const RENDERER_PATH := "res://modules/units/scripts/rig/crowd_renderer.gd"
const PROFESSION_PATH := "res://modules/town_life/scripts/profession_registry.gd"
const SKELETON_PATH := "res://modules/units/scripts/rig/stickman_skeleton.gd"

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("锁1: StickmanRig 不再暴露 body_color 属性", _test_rig_has_no_body_color)
	_runner.add_test("锁2: 三个染色落点源码无 body_color 引用", _test_sources_free_of_body_color)
	_runner.add_test("锁3: 身体色唯一来源 Skeleton.DEFAULT_BODY", _test_default_body_constant)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


## 锁 1：rig 属性表里不应再有身体色条目（口子拆了才算彻底；再加回来 = 测试红）
func _test_rig_has_no_body_color() -> void:
	var script: Script = load(RIG_PATH)
	_runner.assert_true(script != null, "StickmanRig 脚本应可加载")
	var names: Array[String] = []
	for p in script.get_script_property_list():
		names.append(String(p.get("name", "")))
	_runner.assert_false(names.has("body_color"), "StickmanRig 不应再暴露 body_color（身体不做身份染色）")
	_runner.assert_true(names.has("weapon_color"), "非身体色参数（weapon_color）应保留")


## 锁 2：源码面复查——三个落点任何一个重新出现引用都视为回归
func _test_sources_free_of_body_color() -> void:
	for path in [RIG_PATH, RENDERER_PATH, PROFESSION_PATH]:
		var src: String = _read_source(path)
		_runner.assert_false(src.is_empty(), "%s 应可读取" % path)
		_runner.assert_false(src.contains("body_color"), "%s 不应再引用 body_color" % path)


## 锁 3：身体色只能来自骨架默认常量（不存在则渲染退回无据可依）
func _test_default_body_constant() -> void:
	var skel: GDScript = load(SKELETON_PATH)
	_runner.assert_true(skel != null, "stickman_skeleton 脚本应可加载")
	var consts: Dictionary = skel.get_script_constant_map()
	_runner.assert_true(consts.has("DEFAULT_BODY"), "Skeleton.DEFAULT_BODY 应存在（身体色唯一来源）")


func _read_source(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()
