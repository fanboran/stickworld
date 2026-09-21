extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：HD-2D 随身特效锚点（箭矢视觉域偏移）。
##
## 契约（MapBase 视觉域协议铁律 2）：画布域物理位置 ≠ 视觉位置——箭的 Area2D
## 判定留在画布域，绘制子节点整体按"弹道地面线的投影压缩量"偏移；**弹道高度
## 按原值保留**（身体纵向不压缩）。2D 图 remap 恒等 → 偏移 0（零回归）。
##
## 不进场景树：本节点由 batch_runner 挂进树，fixture 局部 add_child 用完即弃。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ArrowScene := preload("res://modules/units/scenes/components/arrow.tscn")

var _runner: TestRunner


## 替身地图：只暴露箭矢链消费的协议方法（k=0.5 便于心算）
class StubRemapMap extends Node2D:
	func remap_fx_pos(pos: Vector2) -> Vector2:
		return Vector2(pos.x, pos.y * 0.5)


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("箭矢: 2D 图偏移恒 0（零回归）", _test_identity_2d)
	_runner.add_test("箭矢: HD-2D 偏移=地面线压缩量、弧高不压", _test_hd2d_offset)
	_runner.add_test("箭矢: 碰撞形状留在根上（判定域不变）", _test_collision_kept)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _make_arrow(y: float) -> Node2D:
	var arrow: Node2D = ArrowScene.instantiate()
	add_child(arrow)
	arrow.global_position = Vector2(100.0, y)
	return arrow


func _test_identity_2d() -> void:
	# 无 fx_pos_remapper 组节点 = 2D 图：remap 恒等 → 不产生任何偏移
	var arrow := _make_arrow(400.0)
	arrow.call("_apply_visual_offset")
	var vr: Node2D = arrow.get_node_or_null("VisualRoot")
	_runner.assert_true(vr != null, "绘制子节点应已收进 VisualRoot 容器")
	_runner.assert_approx(vr.position.y, 0.0, 0.0001, "2D 图偏移恒 0")
	remove_child(arrow)
	arrow.free()


func _test_hd2d_offset() -> void:
	var map := StubRemapMap.new()
	add_child(map)
	map.add_to_group("fx_pos_remapper")
	var arrow := _make_arrow(400.0)
	arrow.call("_apply_visual_offset")
	var vr: Node2D = arrow.get_node_or_null("VisualRoot")
	# 出弓点脚线（首帧位置 + 70，weapon_ranged 的 from 抬升量回推）= 470
	var ground: float = 470.0
	_runner.assert_approx(vr.position.y, ground * 0.5 - ground, 0.0001,
			"偏移 = 地面线的投影压缩量（k=0.5 → -470/2）")
	# 视觉落点 = 视觉地面线 − 原值弧高（箭在出弓位，弧高 = 70）
	var drawn: float = arrow.global_position.y + vr.position.y
	_runner.assert_approx(drawn, ground * 0.5 - 70.0, 0.0001,
			"落点 = 视觉地面线 − 原值 70（弧高不参与压缩）")
	remove_child(arrow)
	arrow.free()
	map.remove_from_group("fx_pos_remapper")
	remove_child(map)
	map.free()


func _test_collision_kept() -> void:
	# 碰撞形状必须是 Area2D 直接子级：换容器不能把判定一起搬走
	var arrow := _make_arrow(400.0)
	arrow.call("_apply_visual_offset")
	var shape: Node = arrow.get_node_or_null("CollisionShape2D")
	if shape == null:
		# 场景里碰撞体可能被改名，按类型兜底查找
		for c in arrow.get_children():
			if c is CollisionShape2D:
				shape = c
	_runner.assert_true(shape != null, "根上应保留 CollisionShape2D")
	_runner.assert_true(shape != null and shape.get_parent() == arrow,
			"碰撞形状应挂在箭根（判定域 = 画布域，不动）")
	var vr: Node2D = arrow.get_node_or_null("VisualRoot")
	_runner.assert_true(vr != null and not vr.get_children().is_empty(),
			"绘制子节点（Sprite）应在 VisualRoot 内")
	remove_child(arrow)
	arrow.free()
