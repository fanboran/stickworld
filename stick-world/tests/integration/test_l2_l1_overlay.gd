extends Node
## 集成测试：L2 地区视图的 L1 细分叠加层（点开 L2 看到 L2 细分）
## 验证：open(region) 默认开启细分视图 / l1_split.json 加载 / 网格烘焙 / 坐标在 context 内 / V 键切换

const TestRunner := preload("res://tests/core/test_runner.gd")
const L2_SCENE: PackedScene = preload("res://modules/world_map/scenes/strategic_map_l2.tscn")

var _runner: TestRunner
var _scene: Node = null
var _content: Node = null
var _renderer: Node = null
var _overlay: Node = null
var _controller: Node = null


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("open 地区：默认开启 L1 细分视图 + 数据加载", _test_open_split, true)
	_runner.add_test("L1 细胞几何与坐标合法", _test_geometry, true)
	_runner.add_test("V 键切换细分视图", _test_toggle, true)
	await _runner.run_async()
	print(_runner.summary())
	get_tree().quit(0 if _runner.all_passed() else 1)


func _test_open_split() -> void:
	_scene = L2_SCENE.instantiate()
	add_child(_scene)
	_content = _scene.get_node_or_null("Content")
	_controller = _content
	_renderer = _content.get_node_or_null("L2MapRenderer") if _content != null else null
	_overlay = _renderer.get_node_or_null("L2L1Overlay") if _renderer != null else null
	_runner.assert_true(_overlay != null, "L2 场景应含 L2L1Overlay")
	if _overlay == null:
		return
	_controller.open("region_001")
	_runner.assert_true(_overlay.is_loaded(), "L1 细分数据应加载")
	_runner.assert_true(_overlay._cells.size() > 0, "region_001 应有 L1 细胞（>0，实测 %d）" % _overlay._cells.size())
	_runner.assert_true(_renderer.l1_split_visible, "细分视图应默认开启")
	_runner.assert_true(_overlay.visible, "叠加层应可见")


func _test_geometry() -> void:
	if _overlay == null or not _overlay.is_loaded():
		_runner.assert_true(false, "前置：细分未加载")
		return
	var no_ring := 0
	var neg := 0
	for c in _overlay._cells:
		var rings: Array = c["polygons"]
		if rings.is_empty():
			no_ring += 1
		for ring in rings:
			for v in ring:
				if (v as Vector2).x < 0.0 or (v as Vector2).y < 0.0:
					neg += 1
		var city: Vector2 = c["city"]
		if city.x < 0.0 or city.y < 0.0:
			neg += 1
	_runner.assert_true(no_ring == 0, "每个细胞应有外环（缺失 %d）" % no_ring)
	_runner.assert_true(neg == 0, "坐标不应为负（越界 %d）" % neg)


func _test_toggle() -> void:
	if _renderer == null or _overlay == null:
		_runner.assert_true(false, "前置：场景未装载")
		return
	var before: bool = _renderer.l1_split_visible
	_controller._toggle_l1_split()
	_runner.assert_true(_renderer.l1_split_visible == not before, "V 键应切换细分视图开关")
	_runner.assert_true(_overlay.visible == not before, "叠加层可见性应同步")
	_controller._toggle_l1_split()
	_runner.assert_true(_renderer.l1_split_visible == before, "再次切换应还原")