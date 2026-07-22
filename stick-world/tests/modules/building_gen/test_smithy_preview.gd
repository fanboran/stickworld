extends Node
## SmithyPreview 构建一致性测试。
##
## 运行：
##   godot --headless --path stick-world res://tests/modules/building_gen/test_smithy_preview.tscn
##
## 退出码：0 全部通过，1 有失败

const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptSmithyPreview := preload("res://modules/building_gen/scripts/preview/smithy_preview.gd")

var _runner: TestRunner
var _preview: Node2D
var _tests: Array = []


func _ready() -> void:
	_runner = TestRunner.new()
	_register_tests()
	_run_tests_async()


func _register_tests() -> void:
	_tests.append({"name": "SmithyPreview: force_build 生成期望的子节点", "fn": Callable(self, "_test_build_creates_nodes")})
	_tests.append({"name": "SmithyPreview: width_cells=7 时零件位置正确", "fn": Callable(self, "_test_default_width_positions")})
	_tests.append({"name": "SmithyPreview: 加宽后右堵头跟随 RoofMain", "fn": Callable(self, "_test_wider_shift")})


func _run_tests_async() -> void:
	var packed := load("res://modules/building_gen/scenes/smithy_preview.tscn") as PackedScene
	if packed == null:
		print("[FATAL] 无法加载 smithy_preview.tscn")
		get_tree().quit(1)
		return

	_preview = packed.instantiate() as Node2D
	add_child(_preview)
	await get_tree().process_frame

	if _preview.has_method("force_build"):
		_preview.force_build()
		await get_tree().process_frame

	for t in _tests:
		_runner.add_test(t["name"], t["fn"])
	_runner.run()
	print(_runner.summary())

	var exit_code := 0 if _runner.all_passed() else 1
	get_tree().quit(exit_code)


func _get_child(path: String) -> Node:
	if _preview == null:
		return null
	return _preview.get_node_or_null(path)


func _get_poly_bounds(poly: Polygon2D) -> Rect2:
	var r := Rect2(poly.polygon[0], Vector2.ZERO)
	for i in range(1, poly.polygon.size()):
		r = r.expand(poly.polygon[i])
	return r


func _test_build_creates_nodes() -> void:
	_runner.assert_true(_preview != null, "预览场景应被实例化")
	_runner.assert_true(_get_child("L1_BackWall/BackWall") != null, "BackWall 应存在")
	_runner.assert_true(_get_child("L1_BackWall/BackWallTop") != null, "BackWallTop 应存在")
	_runner.assert_true(_get_child("L1_BackWall/BackPillarL") != null, "BackPillarL 应存在")
	_runner.assert_true(_get_child("L4_FrontWall/FrontPillar") != null, "FrontPillar 应存在")
	_runner.assert_true(_get_child("L5_Roof/Beam") != null, "Beam 应存在")
	_runner.assert_true(_get_child("L5_Roof/MainRoofGroup/RoofMain") != null, "RoofMain 应存在")
	_runner.assert_true(_get_child("L5_Roof/MainRoofGroup/RoofRightEnd") != null, "RoofRightEnd 应存在")
	_runner.assert_true(_get_child("L5_Roof/RoofLeftGroup1") != null, "RoofLeftGroup1 应存在")


func _test_default_width_positions() -> void:
	# width_cells=7 时，关键节点应落在当前代码计算的位置附近
	var roof_main: Polygon2D = _get_child("L5_Roof/MainRoofGroup/RoofMain") as Polygon2D
	if roof_main:
		print("DEBUG RoofMain polygon: ", roof_main.polygon)
	var roof_right: Polygon2D = _get_child("L5_Roof/MainRoofGroup/RoofRightEnd") as Polygon2D
	if roof_right:
		print("DEBUG RoofRight polygon: ", roof_right.polygon)

	var back_wall: Sprite2D = _get_child("L1_BackWall/BackWall") as Sprite2D
	if back_wall:
		_runner.assert_true(abs(back_wall.position.x - 83.0) < 2.0, "BackWall x 应接近 83")
		_runner.assert_true(abs(back_wall.position.y - (-250.5)) < 1.0, "BackWall y 应接近 -250.5")

	var beam: Sprite2D = _get_child("L5_Roof/Beam") as Sprite2D
	if beam:
		_runner.assert_true(abs(beam.position.x - 81.0) < 2.0, "Beam x 应接近 81")
		_runner.assert_true(abs(beam.position.y - (-229.0)) < 1.0, "Beam y 应接近 -229")

	if roof_main:
		var bounds := _get_poly_bounds(roof_main)
		_runner.assert_true(abs(bounds.position.x - 39.0) < 1.0, "RoofMain 左边界应接近 39")
		# 注意：平行四边形右下角比右上角更靠右，bounds.end.x 取右下角
		_runner.assert_true(abs(bounds.end.x - 190.17) < 2.0, "RoofMain 右下角应接近 190")
		_runner.assert_true(abs(roof_main.polygon[1].x - 126.17) < 2.0, "RoofMain 右上角应接近 126")

	roof_right = _get_child("L5_Roof/MainRoofGroup/RoofRightEnd") as Polygon2D
	if roof_right:
		var bounds := _get_poly_bounds(roof_right)
		# RR 左端应贴合 RM 右端（world x ≈ 128.9）
		_runner.assert_true(abs(bounds.position.x - 128.9) < 2.0, "RoofRightEnd 左边界应贴合 RoofMain 右端")
		_runner.assert_true(abs(roof_right.polygon[1].x - 164.9) < 2.0, "RoofRightEnd 右上角应接近 165")
		_runner.assert_true(abs(bounds.end.x - 245.9) < 2.0, "RoofRightEnd 右下角应接近 246")


func _test_wider_shift() -> void:
	# 把 width_cells 改为 11，force_build 后右堵头应右移
	_preview.width_cells = 11
	_preview.force_build()
	await get_tree().process_frame

	var back_pillar_r: Sprite2D = _get_child("L1_BackWall/BackPillarR") as Sprite2D
	if back_pillar_r:
		_runner.assert_true(back_pillar_r.position.x > 166.0, "加宽后 BackPillarR 应右移")

	var roof_right: Polygon2D = _get_child("L5_Roof/MainRoofGroup/RoofRightEnd") as Polygon2D
	if roof_right:
		var bounds := _get_poly_bounds(roof_right)
		_runner.assert_true(bounds.position.x > 128.9, "加宽后 RoofRightEnd 应右移")
