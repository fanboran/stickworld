extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：编队结构列阵（SWL Formation 类直译，批次 11b）。
## 槽位分配（UNITS_PER_COLUMN/ROW_GAP）+ formation 槽位落点 + 掉员自动补位
## （FilterDownARandomRow 等价）+ 贪心换位（ShouldSwitchUnitsInFormation）
## + 落点稳定（FormationPositionIsStable）/落定查询（IsInTheFormation）。
## 不进场景树（_process 不触发），确定性。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptFormationSystem := preload("res://modules/combat/scripts/command/formation_system.gd")

var _runner: TestRunner


## 假组织 API：记录调用，模拟成功返回（复刻 test_squad_dest 的 FakeOrgApi）
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
	_runner.add_test("列阵: 槽位分配 9 人 = 3 列 × 3（同点出生无换位动机）", _test_slot_grid)
	_runner.add_test("列阵: formation 落点（前列贴锚/后列退 ROW_GAP/同列横展）", _test_slot_world)
	_runner.add_test("列阵: 掉员自动补位（末槽滤除/槽位重算）", _test_reinforce_on_removal)
	_runner.add_test("列阵: 贪心换位（近者填前排）", _test_swap_closer_to_front)
	_runner.add_test("列阵: 落点稳定与落定查询", _test_stability_query)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


## 构造一个含 n 个单位的 FormationSystem（fake org api；单位不带 get_facing → 回退 +x）。
## same_point=true 时全员同点出生（贪心换位成本对称无改善 → 保持入队序，确定性）；
## false 时沿 y 向 200px 大间距散开（任意换位后成员距自身槽位仍超死区，确定性）。
func _make_formation(n: int, same_point: bool = true) -> Array:
	var fs: Node = ScriptFormationSystem.new()
	var org: Node = FakeOrgApi.new()
	fs.setup(org)
	var units: Array = []
	for i in n:
		var u := Node2D.new()
		u.name = "U%d" % i
		u.position = Vector2(100, 500) if same_point else Vector2(100, 500 + i * 200.0)
		var s := GDScript.new()
		s.source_code = "extends Node2D\nfunc is_dead(): return false\nfunc get_ai_controller(): return null\n"
		s.reload()
		u.set_script(s)
		units.append(u)
	var squad_id: String = fs.create_squad(units, "测试队")
	return [fs, units, squad_id]


func _test_slot_grid() -> void:
	var r: Array = _make_formation(9)
	var fs: Node = r[0]
	var sid: String = r[2]
	if sid.is_empty():
		_runner.assert_true(false, "小队创建失败")
		return
	var slots: Dictionary = fs._squads[sid]["slots"]
	_runner.assert_equal(slots.size(), 9, "9 人应有 9 个槽位")
	var rows_per_col: Dictionary = {}
	for iid in slots.keys():
		var s: Vector2i = slots[iid]
		rows_per_col[s.x] = int(rows_per_col.get(s.x, 0)) + 1
	_runner.assert_equal(rows_per_col.size(), 3, "UNITS_PER_COLUMN=3 时 9 人应占 3 列")
	for c in rows_per_col.keys():
		_runner.assert_equal(rows_per_col[c], 3, "每列应满 3 人")
	# 槽位双射：无重复槽位
	var seen: Dictionary = {}
	for iid in slots.keys():
		seen[slots[iid]] = true
	_runner.assert_equal(seen.size(), 9, "槽位应互不重复（成员↔槽位双射）")


func _test_slot_world() -> void:
	# 纵向两员（对称于中线）：u0→前列上槽、u1→前列中槽，换位对称无改善 → 索引序确定
	var fs: Node = ScriptFormationSystem.new()
	fs.setup(FakeOrgApi.new())
	var u0 := Node2D.new()
	u0.name = "Top"
	u0.position = Vector2(160, 436)
	var u1 := Node2D.new()
	u1.name = "Mid"
	u1.position = Vector2(160, 564)
	var units: Array = [u0, u1]
	for u in units:
		var s := GDScript.new()
		s.source_code = "extends Node2D\nfunc is_dead(): return false\nfunc get_ai_controller(): return null\n"
		s.reload()
		u.set_script(s)
	var sid: String = fs.create_squad(units, "落点队")
	if sid.is_empty():
		_runner.assert_true(false, "小队创建失败")
		return
	var base := Vector2(500, 500)
	# 无 get_facing → 回退 +x（向右推进）；前列贴 base_pos，横向以 base 为中心
	_runner.assert_approx(fs.get_squad_dest(sid, u0, base, "formation").x, base.x, 0.5,
			"前列槽位 x = 锚 x")
	_runner.assert_approx(fs.get_squad_dest(sid, u0, base, "formation").y, base.y - 32.0, 0.5,
			"前列 row0 横展 −SPREAD")
	_runner.assert_approx(fs.get_squad_dest(sid, u1, base, "formation").y, base.y, 0.5,
			"前列 row1 = 锚 y")
	# 槽位世界坐标纯函数：后列退 ROW_GAP，朝向镜像
	var d_rear: Vector2 = fs._slot_world(Vector2i(1, 0), base, Vector2.RIGHT)
	_runner.assert_approx(d_rear.x, base.x - 56.0, 0.5, "后列沿行进反方向退 ROW_GAP")
	_runner.assert_approx(d_rear.y, base.y - 32.0, 0.5, "后列 row0 横展 −SPREAD")
	var d_left: Vector2 = fs._slot_world(Vector2i(1, 0), base, Vector2.LEFT)
	_runner.assert_approx(d_left.x, base.x + 56.0, 0.5, "朝向左时后列镜像到 +x")


func _test_reinforce_on_removal() -> void:
	var r: Array = _make_formation(9)
	var fs: Node = r[0]
	var units: Array = r[1]
	var sid: String = r[2]
	if sid.is_empty():
		_runner.assert_true(false, "小队创建失败")
		return
	# 移除 1 人 → 8 人槽位重算：9 宫格恰空 1 格（末员原槽滤除），3 列保持
	fs.remove_unit(units[8])
	var slots: Dictionary = fs._squads[sid]["slots"]
	_runner.assert_equal(slots.size(), 8, "掉员后槽位数随成员数收缩")
	var seen: Dictionary = {}
	var cols: Dictionary = {}
	for iid in slots.keys():
		seen[slots[iid]] = true
		cols[slots[iid].x] = true
	_runner.assert_equal(seen.size(), 8, "剩余成员槽位互不重复")
	_runner.assert_equal(cols.size(), 3, "8 人应仍占 3 列（FilterDownARandomRow 等价）")
	_runner.assert_false(seen.has(Vector2i(2, 2)), "末员原槽应被滤除（后列补位）")


func _test_swap_closer_to_front() -> void:
	# u0 远离锚（后方）、u3 贴近前排锚侧——贪心换位应让近者填前排
	var fs: Node = ScriptFormationSystem.new()
	fs.setup(FakeOrgApi.new())
	var xs: Array = [0.0, 40.0, 80.0, 480.0]
	var units: Array = []
	for i in xs.size():
		var u := Node2D.new()
		u.name = "U%d" % i
		u.position = Vector2(xs[i], 500)
		var s := GDScript.new()
		s.source_code = "extends Node2D\nfunc is_dead(): return false\nfunc get_ai_controller(): return null\n"
		s.reload()
		u.set_script(s)
		units.append(u)
	var sid: String = fs.create_squad(units, "换位队")
	if sid.is_empty():
		_runner.assert_true(false, "小队创建失败")
		return
	var base := Vector2(600, 500)
	var dest_far: Vector2 = fs.get_squad_dest(sid, units[0], base, "formation")
	var dest_near: Vector2 = fs.get_squad_dest(sid, units[3], base, "formation")
	_runner.assert_approx(dest_near.x, base.x, 0.5, "近者应换到前列（x = 锚 x）")
	_runner.assert_approx(dest_near.y, base.y - 32.0, 0.5, "近者占前列 row0")
	_runner.assert_approx(dest_far.x, base.x - 56.0, 0.5, "远者应被换到后列（退 ROW_GAP）")


func _test_stability_query() -> void:
	var r: Array = _make_formation(4, false)
	var fs: Node = r[0]
	var units: Array = r[1]
	var sid: String = r[2]
	if sid.is_empty():
		_runner.assert_true(false, "小队创建失败")
		return
	# 散开出生（无 get_facing → +x）：质心锚参考系下各成员距自身槽位均超死区 → 未落定
	for u in units:
		_runner.assert_false(fs.is_unit_in_formation(u), "散开单位应判定未落定")
	# 把成员挪到各自槽位落点（质心锚 + 平均面向 +x）→ 全部落定（锚随质心微移仍在死区内）
	var anch: Dictionary = fs._squad_anchor(sid)
	for u in units:
		var slot: Vector2i = fs._squads[sid]["slots"][u.get_instance_id()]
		u.global_position = fs._slot_world(slot, anch["centroid"], anch["facing"])
	for u in units:
		_runner.assert_true(fs.is_unit_in_formation(u), "移到槽位落点应判定已落定")
	# 落点稳定检测（FormationPositionIsStable）：死区内稳定
	_runner.assert_true(fs._formation_position_is_stable(units[0], units[0].global_position + Vector2(10, 0)),
			"死区内应判定稳定")
	_runner.assert_false(fs._formation_position_is_stable(units[0], units[0].global_position + Vector2(100, 0)),
			"死区外应判定不稳定")
