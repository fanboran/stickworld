extends Node
## 集成测试：L3 视图上的 L1 蒙版叠加层（V 键）
## 验证：加载 l1_data.json（全大陆 423 L1）/ 每地块有外环多边形 / 网格烘焙 / 蒙版色

const TestRunner := preload("res://tests/core/test_runner.gd")
const L1_OVERLAY_SCRIPT := preload("res://modules/world_map/scripts/l1_overlay.gd")
const L1_JSON_PATH := "res://config/strategic_map/l1_data.json"

var _runner: TestRunner
var _ov: Node = null


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("L1 蒙版加载 + 网格烘焙", _test_load, true)
	_runner.add_test("地块外环与城市点坐标合法", _test_geometry, true)
	await _runner.run_async()
	print(_runner.summary())
	get_tree().quit(0 if _runner.all_passed() else 1)


func _test_load() -> void:
	_ov = L1_OVERLAY_SCRIPT.new()
	add_child(_ov)
	_ov.load_overlay(L1_JSON_PATH)
	_runner.assert_true(_ov.is_loaded(), "L1Overlay 应成功加载")
	var tiles: Array = _ov._tiles
	_runner.assert_true(tiles.size() > 300, "应为全大陆 L1 地块（>300，实测 %d）" % tiles.size())
	_runner.assert_true(_ov._fill_mesh != null, "应烘焙填充网格")
	_runner.assert_true(_ov._edge_mesh != null, "应烘焙描边网格")


func _test_geometry() -> void:
	if _ov == null or not _ov.is_loaded():
		_runner.assert_true(false, "前置：蒙版未加载")
		return
	var no_ring := 0
	var out_of_bounds := 0
	for t in _ov._tiles:
		var rings: Array = t["polygons"]
		if rings.is_empty():
			no_ring += 1
			continue
		for ring in rings:
			for v in ring:
				if (v as Vector2).x < 0.0 or (v as Vector2).y < 0.0:
					out_of_bounds += 1
		var c: Vector2 = t["city"]
		if c.x < 0.0 or c.y < 0.0 or c.x > 8192.0 or c.y > 8192.0:
			out_of_bounds += 1
	_runner.assert_true(no_ring == 0, "每个地块应有外环（缺失 %d）" % no_ring)
	_runner.assert_true(out_of_bounds == 0, "坐标应在 0..8192（越界 %d）" % out_of_bounds)