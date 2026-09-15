extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：HD-2D 投影协议（视觉域坐标变换唯一出口）。
## 1. 压缩数学（Hd2dProjection）：k=sinθ 锚点值 + 正逆 round-trip 恒等
## 2. MapBase 恒等协议：2D 图三方法恒等、悬浮框=Range 原框（2D 行为不变线）
## 3. Hd2dStreetMap 覆写：mock 压缩率驱动真实地图方法（不入树、不装配 3D 世界），
##    验证 remap/unmap 互逆、悬浮框 billboard 几何（脚线锚定+深度缩放）、
##    _hd 未就绪回退 2D 恒等

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")

var _runner: TestRunner


class MockHd extends Node3D:
	## 替身 3D 世界：只暴露压缩率读数（k=0.5 便于心算断言）
	func get_ground_squash() -> float:
		return 0.5


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("压缩率: k=sinθ 锚点值", _test_squash_k)
	_runner.add_test("round-trip: 正逆互为精确逆", _test_round_trip)
	_runner.add_test("MapBase: 2D 恒等协议", _test_map_base_identity)
	_runner.add_test("Hd2dStreetMap: remap/unmap 互逆（mock k）", _test_street_remap_round_trip)
	_runner.add_test("Hd2dStreetMap: 悬浮框 billboard 几何", _test_street_hover_rect)
	_runner.add_test("Hd2dStreetMap: _hd 未就绪回退 2D 恒等", _test_street_fallback_identity)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _test_squash_k() -> void:
	_runner.assert_approx(Hd2dProjection.squash_k(), 0.4384, 0.001, "k=sin26°≈0.438（§4.2）")


func _test_round_trip() -> void:
	var k: float = Hd2dProjection.squash_k()
	var front: float = Hd2dStreetMap.WALK_FRONT_Y
	for y: float in [front, 1000.0, 800.0, 688.0, 472.6]:
		var v := Hd2dProjection.ground_to_visual_y(y, k, front)
		var back := Hd2dProjection.visual_to_ground_y(v, k, front)
		_runner.assert_approx(back, y, 0.0001, "y=%s 正逆恒等" % y)


func _test_map_base_identity() -> void:
	var map := MapBase.new()
	var p := Vector2(123.0, 800.0)
	_runner.assert_true(map.remap_fx_pos(p) == p, "2D remap 恒等")
	_runner.assert_true(map.unmap_fx_pos(p) == p, "2D unmap 恒等")
	var rect := map.entity_hover_rect(Vector2(8.5, 9.5), Vector2(90, 277), map)
	_runner.assert_true(rect == Rect2(Vector2(-36.5, -129.0), Vector2(90, 277)),
			"2D 悬浮框 = Range 原框（行为不变线）")
	map.free()


func _make_street_map() -> Hd2dStreetMap:
	var map := Hd2dStreetMap.new()
	map._hd = MockHd.new()
	return map


func _test_street_remap_round_trip() -> void:
	var map := _make_street_map()
	var front: float = Hd2dStreetMap.WALK_FRONT_Y
	for y: float in [front, 1100.0, 800.0, 700.0]:
		var v := map.remap_fx_pos(Vector2(50.0, y))
		_runner.assert_approx(v.x, 50.0, 0.0001, "x 恒等（俯角只压纵深）")
		_runner.assert_approx(v.y, front - (front - y) * 0.5, 0.0001, "k 压缩式 y=%s" % y)
		var back := map.unmap_fx_pos(v)
		_runner.assert_approx(back.y, y, 0.0001, "经图方法正逆恒等 y=%s" % y)
	map.free()


func _test_street_hover_rect() -> void:
	var map := _make_street_map()
	var ent := Node2D.new()
	map.add_child(ent)
	ent.position = Vector2(100.0, 800.0)
	var rect := map.entity_hover_rect(Vector2(108.5, 809.5), Vector2(90.0, 277.0), ent)
	var ds: float = map.depth_scale_at(800.0)
	var foot_v: float = map.remap_fx_pos(Vector2(0.0, 800.0)).y
	_runner.assert_approx(rect.end.y, foot_v, 0.0001, "底边贴视觉脚线（origin=脚）")
	_runner.assert_approx(rect.get_center().x, 100.0, 0.0001, "x 以 origin 居中（billboard 无朝向偏移）")
	_runner.assert_approx(rect.size.x, 90.0 * ds, 0.0001, "宽随深度缩放")
	_runner.assert_approx(rect.size.y, 277.0 * ds, 0.0001, "高随深度缩放")
	map.free()   # ent 为 map 子节点，随 map 一并释放（勿二次 free）


func _test_street_fallback_identity() -> void:
	var map := Hd2dStreetMap.new()   # 不入树/未 _ready：_hd 为 null
	var p := Vector2(50.0, 800.0)
	_runner.assert_true(map.remap_fx_pos(p) == p, "未就绪 remap 恒等")
	var rect := map.entity_hover_rect(Vector2(8.5, 9.5), Vector2(90, 277), map)
	_runner.assert_true(rect == Rect2(Vector2(-36.5, -129.0), Vector2(90, 277)),
			"未就绪悬浮框回退 2D 恒等")
	map.free()
