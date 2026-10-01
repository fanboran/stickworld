extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：班内聚拢弹簧 + 轻量对齐（Boids 式裁剪，squad_cohesion.gd）。
## 死区零施力（只拉掉队的不吸站好的）+ 超区线性回拉 + 上限封顶 + 接战减半
## + 避战让位（聚拢对齐全零）+ 班均速对齐 + 散布半径按班人数放宽。
## 不进场景树（formation._process 不触发），确定性。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptFormationSystem := preload("res://modules/formation/scripts/formation_system.gd")

var _runner: TestRunner


class FakeOrgApi:
	extends Node
	var _next_id: int = 1

	func create_organization(_org_name: String, _tag: String, _tier: int, _parent_id: String) -> Dictionary:
		var org_id := "org_%d" % _next_id
		_next_id += 1
		return {"ok": true, "data": {"org_id": org_id}}

	func assign_stickman(_org_id: String, _stickman_id: String, _role: String) -> void:
		pass

	func assign_commander(_org_id: String, _stickman_id: String) -> void:
		pass

	func remove_stickman(_org_id: String, _stickman_id: String) -> void:
		pass

	func remove_commander(_org_id: String) -> void:
		pass

	func disband_organization(_org_id: String) -> void:
		pass


## 单位桩：可设位置/速度/行为名（velocity 用脚本变量模拟 CharacterBody2D 属性）
class FakeUnit:
	extends Node2D
	var velocity: Vector2 = Vector2.ZERO
	var _behavior: String = "move"

	func is_dead() -> bool:
		return false

	func get_current_behavior() -> String:
		return _behavior


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("聚拢: 散布半径按班人数放宽（8 人基准/12 人放宽）", _test_spread_radius)
	_runner.add_test("聚拢: 死区内零施力（不吸站好的）", _test_dead_zone)
	_runner.add_test("聚拢: 超区线性回拉，方向指向班质心", _test_linear_pull)
	_runner.add_test("聚拢: 回拉上限封顶（防磁铁）", _test_pull_cap)
	_runner.add_test("聚拢: 接战回拉减半", _test_engaged_half)
	_runner.add_test("聚拢: 撤退/避战全零（避战优先）", _test_avoid_zero)
	_runner.add_test("对齐: 速度向班均值收敛，站桩不对齐", _test_alignment)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


## 构造 formation + 一个 n 人班；units_pos/units_vel 为各成员位置/速度
func _make_world(n: int, units_pos: Array, units_vel: Array = []) -> Array:
	var fs: Node = ScriptFormationSystem.new()
	fs.setup(FakeOrgApi.new())
	var units: Array = []
	for i in n:
		var u := FakeUnit.new()
		u.name = "U%d" % i
		u.position = units_pos[i]
		if i < units_vel.size():
			u.velocity = units_vel[i]
		units.append(u)
	var sid: String = fs.create_squad(units, "测试班", "fp_combat_squad")
	return [fs, units, sid]


func _test_spread_radius() -> void:
	var r: Array = _make_world(8, _ring(8, 100.0))
	var fs: Node = r[0]
	var sid: String = r[2]
	_runner.assert_approx(fs.get_squad_spread_radius(sid), 140.0, 0.5, "8 人班散布半径 = 基准 140")
	fs.free()
	var r2: Array = _make_world(12, _ring(12, 100.0))
	_runner.assert_approx(r2[0].get_squad_spread_radius(r2[2]), 164.0, 0.5, "12 人班散布半径 = 140+4×6")
	r2[0].free()


## 环形布点（质心 ≈ 原点，全员等距）
func _ring(n: int, radius: float) -> Array:
	var out: Array = []
	for i in n:
		var a: float = TAU * float(i) / float(n)
		out.append(Vector2(cos(a), sin(a)) * radius)
	return out


func _test_dead_zone() -> void:
	# 8 人班全员距质心 100 < 散布半径 140 → 死区内全零（速度同零不对齐）
	var r: Array = _make_world(8, _ring(8, 100.0))
	var fs: Node = r[0]
	var units: Array = r[1]
	for u in units:
		_runner.assert_true(fs.get_unit_cohesion_steer(u) == Vector2.ZERO,
				"死区内成员应零施力")
	fs.free()


func _test_linear_pull() -> void:
	# 7 人贴质心 + 1 人掉队（距质心 160 → 超出 20 → 回拉 20×6=120，指向质心）
	var pos: Array = _ring(7, 40.0)
	pos.append(Vector2(160, 0))
	var r: Array = _make_world(8, pos)
	var fs: Node = r[0]
	var units: Array = r[1]
	var steer: Vector2 = fs.get_unit_cohesion_steer(units[7])
	# 质心被掉队者自身偏移（7×40 人环 + 160）→ 精确期望按缓存实算：
	var cache: Dictionary = fs._squads[r[2]]["cohesion_cache"]
	var expected_dir: Vector2 = (cache["centroid"] - Vector2(160, 0)).normalized()
	var expected_pull: float = minf(
			(Vector2(160, 0) - cache["centroid"]).length() - fs.get_squad_spread_radius(r[2]),
			220.0) * 6.0
	if expected_pull > 0.0:
		_runner.assert_approx(steer.length(), expected_pull, 0.5,
				"超区回拉 = 超出距离×斜率（%.0f）" % expected_pull)
		_runner.assert_true(steer.normalized().dot(expected_dir) > 0.99,
				"回拉方向应指向班质心")
	else:
		_runner.assert_true(steer == Vector2.ZERO, "未超区应零施力")
	# 贴质心的成员仍在死区
	for i in 7:
		_runner.assert_true(fs.get_unit_cohesion_steer(units[i]) == Vector2.ZERO,
				"死区内成员不吸")


func _test_pull_cap() -> void:
	# 掉队者距质心极远 → 线性值远超上限 → 封顶 220
	var pos: Array = _ring(7, 40.0)
	pos.append(Vector2(1000, 0))
	var r: Array = _make_world(8, pos)
	var fs: Node = r[0]
	var units: Array = r[1]
	var steer: Vector2 = fs.get_unit_cohesion_steer(units[7])
	_runner.assert_true(steer.length() <= 220.5, "回拉应封顶 ≤ 220（实际 %.0f）" % steer.length())
	_runner.assert_true(steer.length() >= 219.5, "远掉队者应打满上限")


func _test_engaged_half() -> void:
	# 同 _test_pull_cap 布局，掉队者接战中 → 回拉减半
	var pos: Array = _ring(7, 40.0)
	pos.append(Vector2(1000, 0))
	var r: Array = _make_world(8, pos)
	var fs: Node = r[0]
	var units: Array = r[1]
	units[7]._behavior = "attack"
	var steer: Vector2 = fs.get_unit_cohesion_steer(units[7])
	_runner.assert_approx(steer.length(), 110.0, 0.5, "接战回拉应减半（110）")


func _test_avoid_zero() -> void:
	for b in ["retreat", "seek_cover"]:
		var pos: Array = _ring(7, 40.0)
		pos.append(Vector2(1000, 0))
		var r: Array = _make_world(8, pos)
		var fs: Node = r[0]
		var units: Array = r[1]
		units[7]._behavior = b
		_runner.assert_true(fs.get_unit_cohesion_steer(units[7]) == Vector2.ZERO,
				"%s 态应聚拢对齐全零" % b)
		fs.free()


func _test_alignment() -> void:
	# 全员死区内（距质心 100），两人行军 (120,0) 一人站住 → 站住者被建议向班均值加速，
	# 行军者向均值回拉；班均速 (80,0) > 死区 20 → 对齐生效
	var pos: Array = _ring(3, 100.0)
	var vel: Array = [Vector2(120, 0), Vector2(120, 0), Vector2.ZERO]
	var r: Array = _make_world(3, pos, vel)
	var fs: Node = r[0]
	var units: Array = r[1]
	var steer_slow: Vector2 = fs.get_unit_cohesion_steer(units[2])
	var steer_fast: Vector2 = fs.get_unit_cohesion_steer(units[0])
	_runner.assert_true(steer_slow.x > 100.0 and absf(steer_slow.y) < 1.0,
			"站住者应被建议沿行军方向加速（Δv×权重）")
	_runner.assert_true(steer_fast.x < -50.0 and absf(steer_fast.y) < 1.0,
			"超速者应被建议减速向均值")
	# 班均速低于死区（全员站桩）→ 不对齐
	var r2: Array = _make_world(3, pos)
	var steer_idle: Vector2 = r2[0].get_unit_cohesion_steer(r2[1][0])
	_runner.assert_true(steer_idle == Vector2.ZERO, "站桩班应不对齐（防抖）")
	# 无班单位零
	var lone := FakeUnit.new()
	lone.position = Vector2.ZERO
	_runner.assert_true(r2[0].get_unit_cohesion_steer(lone) == Vector2.ZERO,
			"无班单位应零施力")
