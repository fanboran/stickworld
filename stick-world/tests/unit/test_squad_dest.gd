extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：队伍级目标点分配（反编译参考实装 D）。
## FormationSystem.get_squad_dest（横排/围圈/不散开）+ CommandChain 个性化 target 注入。
## 不进场景树（_process 不触发），确定性。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptFormationSystem := preload("res://modules/combat/scripts/command/formation_system.gd")
const ScriptCommandChain := preload("res://modules/combat/scripts/command/command_chain.gd")

var _runner: TestRunner


## 假组织 API：记录调用，模拟成功返回（复刻 test_formation_system 的 FakeOrgApi）
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

	func disband_organization(_org_id: String) -> void:
		pass


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("目标点: 横排散开不同 index 不同点位", _test_line_spread)
	_runner.add_test("目标点: 横排散开垂直移动方向", _test_line_perpendicular)
	_runner.add_test("目标点: 单人不散开", _test_single_no_spread)
	_runner.add_test("目标点: rally 围圈集合", _test_rally_circle)
	_runner.add_test("目标点: 未知 mode 返回 base_pos", _test_unknown_mode)
	_runner.add_test("指挥链: 个性化 target 注入不污染共享 params", _test_chain_personalize)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


## 构造一个含 n 个单位的 FormationSystem（fake org api）
func _make_formation(n: int) -> Array:
	var fs: Node = ScriptFormationSystem.new()
	var org: Node = FakeOrgApi.new()
	fs.setup(org)
	var units: Array = []
	for i in n:
		var u := Node2D.new()
		u.name = "U%d" % i
		u.position = Vector2(100 + i * 40, 500)
		var s := GDScript.new()
		s.source_code = "extends Node2D\nfunc is_dead(): return false\nfunc get_ai_controller(): return null\n"
		s.reload()
		u.set_script(s)
		units.append(u)
	var squad_id: String = fs.create_squad(units, "测试队")
	return [fs, units, squad_id]


func _test_line_spread() -> void:
	var r: Array = _make_formation(4)
	var fs: Node = r[0]
	var units: Array = r[1]
	var sid: String = r[2]
	if sid.is_empty():
		_runner.assert_true(false, "小队创建失败")
		return
	var base := Vector2(500, 500)
	var d0: Vector2 = fs.get_squad_dest(sid, units[0], base, "line")
	var d1: Vector2 = fs.get_squad_dest(sid, units[1], base, "line")
	var d2: Vector2 = fs.get_squad_dest(sid, units[2], base, "line")
	var d3: Vector2 = fs.get_squad_dest(sid, units[3], base, "line")
	_runner.assert_true(d0 != d1 and d1 != d2 and d2 != d3, "4 人横排应各自不同点位")
	# 对称：首尾关于 base 对称
	_runner.assert_true(d0.is_equal_approx((base + base - d3)), "首尾应关于 base_pos 对称")


func _test_line_perpendicular() -> void:
	var r: Array = _make_formation(3)
	var fs: Node = r[0]
	var units: Array = r[1]
	var sid: String = r[2]
	if sid.is_empty():
		_runner.assert_true(false, "小队创建失败")
		return
	# 目标在正右 → 移动方向水平 → 散开应沿竖直方向（x 相同，y 不同）
	var base := Vector2(units[0].global_position.x + 100, units[0].global_position.y)
	var d0: Vector2 = fs.get_squad_dest(sid, units[0], base, "line")
	var d1: Vector2 = fs.get_squad_dest(sid, units[1], base, "line")
	_runner.assert_true(absf(d0.y - d1.y) > 10.0, "水平推进应沿竖直散开，d0.y=%f d1.y=%f" % [d0.y, d1.y])


func _test_single_no_spread() -> void:
	var r: Array = _make_formation(1)
	var fs: Node = r[0]
	var units: Array = r[1]
	var sid: String = r[2]
	if sid.is_empty():
		_runner.assert_true(false, "小队创建失败")
		return
	var base := Vector2(300, 300)
	var d: Vector2 = fs.get_squad_dest(sid, units[0], base, "line")
	_runner.assert_true(d == base, "单人不散开，应返回 base_pos")


func _test_rally_circle() -> void:
	var r: Array = _make_formation(4)
	var fs: Node = r[0]
	var units: Array = r[1]
	var sid: String = r[2]
	if sid.is_empty():
		_runner.assert_true(false, "小队创建失败")
		return
	var base := Vector2(200, 200)
	var seen: Dictionary = {}
	var all_close := true
	for u in units:
		var d: Vector2 = fs.get_squad_dest(sid, u, base, "rally")
		seen[d] = true
		if d.distance_to(base) > 40.0:
			all_close = false
	_runner.assert_true(seen.size() == units.size(), "4 人围圈应各自不同位置，实际 %d" % seen.size())
	_runner.assert_true(all_close, "围圈点应在 base 附近")


func _test_unknown_mode() -> void:
	var r: Array = _make_formation(2)
	var fs: Node = r[0]
	var units: Array = r[1]
	var sid: String = r[2]
	if sid.is_empty():
		_runner.assert_true(false, "小队创建失败")
		return
	var base := Vector2(400, 400)
	var d: Vector2 = fs.get_squad_dest(sid, units[0], base, "bogus")
	_runner.assert_true(d == base, "未知 mode 应返回 base_pos")


func _test_chain_personalize() -> void:
	# 验证 CommandChain._execute_delivery：spread_mode 时每个单位收到不同 target，且原 params 不被污染
	var r: Array = _make_formation(3)
	var fs: Node = r[0]
	var units: Array = r[1]
	var sid: String = r[2]
	if sid.is_empty():
		_runner.assert_true(false, "小队创建失败")
		return
	# 记录各单位收到的 order target
	for i in units.size():
		var u: Node = units[i]
		var s := GDScript.new()
		s.source_code = "extends Node2D\nvar got: Dictionary = {}\nfunc is_dead(): return false\nfunc get_ai_controller() -> Node:\n\treturn self\nfunc set_order(n: String, p: Dictionary) -> void:\n\tgot = p.duplicate()\n"
		s.reload()
		u.set_script(s)
	# 构造 CommandChain + 注入 formation，手动触发 _execute_delivery
	var cc: Node = ScriptCommandChain.new()
	cc.setup_formation(fs)
	var base := Vector2(500, 500)
	var params := {"target": base}
	cc._execute_delivery(0, sid, units, "move", params, "line")
	var t0: Vector2 = units[0].got["target"]
	var t1: Vector2 = units[1].got["target"]
	_runner.assert_true(t0 != t1, "两个单位应收到不同目标点")
	_runner.assert_equal(params["target"], base, "原始 params 不应被污染")
