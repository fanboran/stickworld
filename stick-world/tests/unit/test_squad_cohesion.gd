extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：班内一次性归队状态机（squad_cohesion.gd，SWL 滞回+节流直译）。
## 行为契约已从「Boids 持续弹簧」改为「一次性归队」（创始人裁决：掉队超距
## 才生效一次，归队后回原任务；非归队态零施力）——断言随契约重写：
## JOIN>SETTLE 滞回 + 0.4s 触发节流 + 接战/避战战斗优先 + 班长/质心锚点。
## 不进场景树（formation._process 不触发），确定性。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptFormationSystem := preload("res://modules/formation/scripts/formation_system.gd")

## 与 api.gd 同步的判定距离（测试口径，改 api 常量须同步此处）
const JOIN_DIST: float = 260.0
const SETTLE_DIST: float = 140.0

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


## 单位桩：可设位置/行为名（velocity 用脚本变量模拟 CharacterBody2D 属性）
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
	_runner.add_test("归队: 滞回带内不触发（零施力，非归队态不打扰任务）", _test_hysteresis_band_idle)
	_runner.add_test("归队: 超 JOIN_DIST 触发，方向指向班长，近处同伴不触发", _test_join_trigger)
	_runner.add_test("归队: 滞回——触发后穿越滞回带不退出，落定即退出", _test_hysteresis_settle)
	_runner.add_test("归队: 触发判定 0.4s 节流（窗内不重估）", _test_recheck_throttle)
	_runner.add_test("归队: 接战不触发（战斗优先）", _test_engaged_no_trigger)
	_runner.add_test("归队: 撤退/避战不触发（豁免保留）", _test_avoid_no_trigger)
	_runner.add_test("归队: 归队中接战挂起施力但状态保留", _test_engaged_suspend)
	_runner.add_test("归队: 无班长 = 质心锚点兜底", _test_centroid_anchor)
	_runner.add_test("归队: 无班单位零施力", _test_no_squad_zero)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


## 构造 formation + 一个 n 人班；units_pos 为各成员位置；
## leader_idx >= 0 时任命该成员为班长（锚点 = 班长位置，否则质心兜底）
func _make_world(n: int, units_pos: Array, leader_idx: int = -1) -> Array:
	var fs: Node = ScriptFormationSystem.new()
	fs.setup(FakeOrgApi.new())
	var units: Array = []
	for i in n:
		var u := FakeUnit.new()
		u.name = "U%d" % i
		u.position = units_pos[i]
		units.append(u)
	var sid: String = fs.create_squad(units, "测试班", "fp_combat_squad")
	if leader_idx >= 0:
		fs.assign_leader(sid, units[leader_idx])
	return [fs, units, sid]


func _rearm_judgement(fs: Node, sid: String, unit: Node) -> void:
	## 把单位归队判定时戳拨旧（越过 0.4s 节流窗），模拟时间流逝
	var st: Dictionary = fs._squads[sid].get("catchup_state", {})
	var e: Variant = st.get(unit.get_instance_id())
	if e != null:
		e["at"] = Time.get_ticks_msec() - 10000


func _test_hysteresis_band_idle() -> void:
	# 班长原点，成员距班长 200（SETTLE 140 < 200 < JOIN 260）→ 滞回带内未触发过
	# → 零施力（正在带内执行任务的单位不被打扰）
	var r: Array = _make_world(3, [Vector2.ZERO, Vector2(200, 0), Vector2(-200, 0)], 0)
	var fs: Node = r[0]
	var units: Array = r[1]
	for i in [1, 2]:
		_runner.assert_true(fs.get_unit_cohesion_steer(units[i]) == Vector2.ZERO,
				"滞回带内成员应零施力")
		_runner.assert_false(fs.is_unit_catching_up(units[i]), "滞回带内不应处于归队态")
	fs.free()


func _test_join_trigger() -> void:
	# 班长原点 + 6 人近环（距班长 100）+ 1 人掉队 300（> JOIN 260）
	var pos: Array = [Vector2.ZERO]
	pos.append_array(_ring(6, 100.0))
	pos.append(Vector2(300, 0))
	var r: Array = _make_world(8, pos, 0)
	var fs: Node = r[0]
	var units: Array = r[1]
	var dropped: FakeUnit = units[7]
	var steer: Vector2 = fs.get_unit_cohesion_steer(dropped)
	_runner.assert_true(steer.x < -0.99 and absf(steer.y) < 0.01,
			"掉队者应收到指向班长的单位方向向量（-X）")
	_runner.assert_approx(steer.length(), 1.0, 0.01, "归队建议 = 单位方向向量")
	_runner.assert_true(fs.is_unit_catching_up(dropped), "超距触发后应处于归队态")
	for i in range(1, 7):
		_runner.assert_true(fs.get_unit_cohesion_steer(units[i]) == Vector2.ZERO,
				"近处同伴不应触发（零施力）")
		_runner.assert_false(fs.is_unit_catching_up(units[i]), "近处同伴不在归队态")
	fs.free()


## 环形布点（圆心 ≈ 原点）
func _ring(n: int, radius: float) -> Array:
	var out: Array = []
	for i in n:
		var a: float = TAU * float(i) / float(n)
		out.append(Vector2(cos(a), sin(a)) * radius)
	return out


func _test_hysteresis_settle() -> void:
	# 触发后从 300 走回 200（滞回带内）→ 仍归队不退出（防边界振荡）；
	# 走到 100（< SETTLE 140）→ 落定退出零施力，状态清零
	var r: Array = _make_world(2, [Vector2.ZERO, Vector2(300, 0)], 0)
	var fs: Node = r[0]
	var units: Array = r[1]
	var dropped: FakeUnit = units[1]
	_runner.assert_true(fs.get_unit_cohesion_steer(dropped) != Vector2.ZERO,
			"300 超距应触发归队")
	dropped.position = Vector2(200, 0)  # 归队途中进滞回带
	var mid: Vector2 = fs.get_unit_cohesion_steer(dropped)
	_runner.assert_true(mid != Vector2.ZERO and mid.x < 0,
			"滞回带内应继续归队（JOIN>SETTLE 滞回防振荡）")
	_runner.assert_true(fs.is_unit_catching_up(dropped), "滞回带内应保持归队态")
	dropped.position = Vector2(100, 0)  # 落定
	_runner.assert_true(fs.get_unit_cohesion_steer(dropped) == Vector2.ZERO,
			"落定（< SETTLE_DIST）应零施力")
	_runner.assert_false(fs.is_unit_catching_up(dropped), "落定应退出归队态")
	fs.free()


func _test_recheck_throttle() -> void:
	# 非归队态判定受 0.4s 节流（SWL lastFollowUpdate）：首次查询刷新时戳后，
	# 节流窗内即使已超 JOIN 也不重估；拨旧时戳（模拟时间流逝）才触发
	var r: Array = _make_world(2, [Vector2.ZERO, Vector2(200, 0)], 0)
	var fs: Node = r[0]
	var units: Array = r[1]
	var dropped: FakeUnit = units[1]
	_runner.assert_true(fs.get_unit_cohesion_steer(dropped) == Vector2.ZERO,
			"带内首次查询应零施力（并刷新判定时戳）")
	dropped.position = Vector2(400, 0)  # 节流窗内变成超距
	_runner.assert_true(fs.get_unit_cohesion_steer(dropped) == Vector2.ZERO,
			"节流窗内不应重估触发")
	_rearm_judgement(fs, r[2], dropped)
	_runner.assert_true(fs.get_unit_cohesion_steer(dropped) != Vector2.ZERO,
			"节流窗过后超距应触发归队")
	_runner.assert_true(fs.is_unit_catching_up(dropped), "触发后应处于归队态")
	fs.free()


func _test_engaged_no_trigger() -> void:
	# 掉队 300 但接战中 → 不触发自动归队（战斗优先：生效前持续完成手头任务）
	var pos: Array = [Vector2.ZERO, Vector2(300, 0)]
	var r: Array = _make_world(2, pos, 0)
	var fs: Node = r[0]
	var units: Array = r[1]
	units[1]._behavior = "attack"
	_runner.assert_true(fs.get_unit_cohesion_steer(units[1]) == Vector2.ZERO,
			"接战中超距不应触发归队")
	_runner.assert_false(fs.is_unit_catching_up(units[1]), "接战中不应进入归队态")
	fs.free()


func _test_avoid_no_trigger() -> void:
	for b in ["retreat", "seek_cover"]:
		var r: Array = _make_world(2, [Vector2.ZERO, Vector2(300, 0)], 0)
		var fs: Node = r[0]
		var units: Array = r[1]
		units[1]._behavior = b
		_runner.assert_true(fs.get_unit_cohesion_steer(units[1]) == Vector2.ZERO,
				"%s 态不应触发归队（避战豁免保留）" % b)
		_runner.assert_false(fs.is_unit_catching_up(units[1]), "%s 态不应进入归队态" % b)
		fs.free()


func _test_engaged_suspend() -> void:
	# 归队途中接战：施力挂起（战斗优先）但状态保留——战毕若仍超距继续归队
	var r: Array = _make_world(2, [Vector2.ZERO, Vector2(300, 0)], 0)
	var fs: Node = r[0]
	var units: Array = r[1]
	var dropped: FakeUnit = units[1]
	_runner.assert_true(fs.get_unit_cohesion_steer(dropped) != Vector2.ZERO, "先触发归队")
	dropped._behavior = "attack"
	_runner.assert_true(fs.get_unit_cohesion_steer(dropped) == Vector2.ZERO,
			"归队中接战应挂起施力")
	_runner.assert_true(fs.is_unit_catching_up(dropped), "挂起期间归队态应保留")
	dropped._behavior = "move"
	_runner.assert_true(fs.get_unit_cohesion_steer(dropped) != Vector2.ZERO,
			"战斗结束后若仍超距应继续归队")
	fs.free()


func _test_centroid_anchor() -> void:
	# 无班长（leader=null）→ 质心兜底：8 人近环 + 1 人掉队 1000，
	# 掉队者距质心 ≈ 889 > JOIN 触发；环上成员距质心 ≤ 151 < JOIN 不触发
	var pos: Array = _ring(8, 40.0)
	pos.append(Vector2(1000, 0))
	var r: Array = _make_world(9, pos)
	var fs: Node = r[0]
	var units: Array = r[1]
	var steer: Vector2 = fs.get_unit_cohesion_steer(units[8])
	# 先调 steer（触发质心缓存建立），再读缓存当方向基准
	var cache: Dictionary = fs._squads[r[2]].get("cohesion_cache", {})
	var expected_dir: Vector2 = (cache["centroid"] - Vector2(1000, 0)).normalized()
	_runner.assert_true(steer != Vector2.ZERO, "质心口径掉队者应触发归队")
	_runner.assert_true(steer.dot(expected_dir) > 0.99, "归队方向应指向班质心")
	for i in 8:
		_runner.assert_true(fs.get_unit_cohesion_steer(units[i]) == Vector2.ZERO,
				"质心口径近处成员不应触发")
	fs.free()


func _test_no_squad_zero() -> void:
	var r: Array = _make_world(1, [Vector2.ZERO])
	var fs: Node = r[0]
	var lone := FakeUnit.new()
	lone.position = Vector2(5000, 0)
	_runner.assert_true(fs.get_unit_cohesion_steer(lone) == Vector2.ZERO, "无班单位应零施力")
	_runner.assert_false(fs.is_unit_catching_up(lone), "无班单位不在归队态")
	fs.free()
