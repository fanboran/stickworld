extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：火力组（班内指挥分组，RL v3 编制地基）。
## create_fireteam 建组/查组/反查（组 = 班内成员子集，不占军衔不入组织树）+
## 校验（异班单位拒绝/无效成员滤除/重复成员去重）+ 重劈移组（旧组收缩/空组自动
## 消亡）+ TacticalOrders.issue 火力组寻址（组员收令/班号令不变/职责沿父班/
## 不触发班粒度相位计划）+ 组员变化（阵亡离组/组灭消亡/离班离组/解散班清组）。
## 不进场景树（formation._process 直调），确定性。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptFormationSystem := preload("res://modules/formation/scripts/formation_system.gd")
const ScriptTacticalOrders := preload("res://modules/tactics/scripts/tactical_orders.gd")


## 假组织 API：记录调用，模拟成功返回
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


## 号令链桩：只捕获 deliver 参数，不送达
class FakeCommandChain:
	extends Node
	var calls: Array = []

	func deliver(order_type: int, target_id: String, units: Array, behavior_name: String,
			params: Dictionary, source_tier: int = 0, squad_tier: int = 1, spread_mode: String = "") -> void:
		calls.append({
			"order_type": order_type, "id": target_id, "units": units,
			"behavior": behavior_name, "params": params, "tier": source_tier,
			"squad_tier": squad_tier, "spread": spread_mode,
		})


## 单位桩：位置 + 存活位（无 rank 字段 → formation 侧 set_meta 兜底口径）
class FakeUnit:
	extends Node2D
	var _dead: bool = false

	func is_dead() -> bool:
		return _dead

	func get_faction() -> int:
		return 1


var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("火力组: create_fireteam 建组/查组/反查（组=班内成员子集）", _test_create_and_lookup)
	_runner.add_test("火力组: 校验——异班单位拒绝/无效滤除/重复去重/空组拒绝", _test_validation)
	_runner.add_test("火力组: 重劈移组（旧组收缩/空组消亡）+ disband 成员留班", _test_rebuild_and_disband)
	_runner.add_test("火力组: TacticalOrders.issue 组员收令；班号令不变；职责沿父班", _test_order_addressing)
	_runner.add_test("火力组: 火力组号令不触发班粒度相位计划", _test_no_phase_plan_for_ft)
	_runner.add_test("火力组: 组员阵亡离组/组灭消亡/离班离组/解散班清组", _test_membership_changes)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


## 构造 n 个单位桩
func _make_units(n: int) -> Array:
	var units: Array = []
	for i in n:
		var u := FakeUnit.new()
		u.name = "U%d" % i
		u.position = Vector2(100 + i * 40, 500)
		units.append(u)
	return units


## 构造 FormationSystem + 一个 n 人战斗班，返回 [fs, squad_id, units]
func _make_fs_with_squad(n: int, preset: String = "fp_combat_squad") -> Array:
	var fs: Node = ScriptFormationSystem.new()
	fs.setup(FakeOrgApi.new())
	var units: Array = _make_units(n)
	var sid: String = fs.create_squad(units, "甲班", preset)
	return [fs, sid, units]


func _test_create_and_lookup() -> void:
	var r: Array = _make_fs_with_squad(8)
	var fs: Node = r[0]
	var sid: String = r[1]
	var units: Array = r[2]
	# 对半劈 4+4
	var ft1: String = fs.create_fireteam(sid, units.slice(0, 4), "一号火力组")
	var ft2: String = fs.create_fireteam(sid, units.slice(4), "二号火力组")
	_runner.assert_false(ft1.is_empty(), "建一号组应成功")
	_runner.assert_false(ft2.is_empty(), "建二号组应成功")
	_runner.assert_true(ft1 != ft2, "两组 id 应不同")
	_runner.assert_equal(fs.get_squad_fireteams(sid), [ft1, ft2], "班内组表应按编组序")
	_runner.assert_equal(fs.get_fireteam_units(ft1), units.slice(0, 4), "一号组成员应一致")
	_runner.assert_equal(fs.get_fireteam_units(ft2), units.slice(4), "二号组成员应一致")
	# 反查
	_runner.assert_equal(fs.get_unit_fireteam(units[0]), ft1, "成员反查组应命中一号")
	_runner.assert_equal(fs.get_unit_fireteam(units[6]), ft2, "成员反查组应命中二号")
	_runner.assert_equal(fs.get_fireteam_squad(ft1), sid, "组反查父班应命中")
	_runner.assert_true(fs.is_fireteam(ft1), "is_fireteam 应识别组 id")
	_runner.assert_false(fs.is_fireteam(sid), "班 id 不是火力组")
	# 组长 = 组内首员（无标记：军衔仍是兵 0）
	_runner.assert_true(fs.get_fireteam_leader(ft1) == units[0], "一号组组长应为首员")
	_runner.assert_equal(fs._get_unit_rank(units[0]), 0, "组长不占军衔（仍为兵 0）")
	# 未入组成员反查为空
	var outsider: Node = _make_units(1)[0]
	_runner.assert_equal(fs.get_unit_fireteam(outsider), "", "未入组单位反查应返回空")
	_runner.assert_equal(fs.get_fireteam_units("ghost_ft"), [], "不存在组查询应返回空")


func _test_validation() -> void:
	var r: Array = _make_fs_with_squad(6)
	var fs: Node = r[0]
	var sid: String = r[1]
	var units: Array = r[2]
	# 异班单位拒绝
	var outsider: Node = _make_units(1)[0]
	_runner.assert_true(fs.create_fireteam(sid, [units[0], outsider]).is_empty(), "异班单位应拒绝建组")
	# 班不存在拒绝
	_runner.assert_true(fs.create_fireteam("ghost_squad", [units[0]]).is_empty(), "班不存在应拒绝")
	# 无效（freed 语义用 null 桩）/阵亡成员滤除；全无效拒绝
	var dead: FakeUnit = units[5]
	dead._dead = true
	_runner.assert_true(fs.create_fireteam(sid, [dead]).is_empty(), "全阵亡成员应拒绝建组")
	var ft: String = fs.create_fireteam(sid, [null, dead, units[0], units[0]])
	_runner.assert_false(ft.is_empty(), "含无效成员但另有有效者应建组成功")
	_runner.assert_equal(fs.get_fireteam_units(ft), [units[0]], "无效成员应滤除且重复成员去重")


func _test_rebuild_and_disband() -> void:
	var r: Array = _make_fs_with_squad(6)
	var fs: Node = r[0]
	var sid: String = r[1]
	var units: Array = r[2]
	var ft1: String = fs.create_fireteam(sid, units.slice(0, 3), "一号")
	var ft2: String = fs.create_fireteam(sid, units.slice(3), "二号")
	_runner.assert_equal(fs.get_squad_fireteams(sid).size(), 2, "应有两个火力组")
	# 重劈：班长动作把 units[0..1] 编入新组 → 自动移出旧组
	var ft3: String = fs.create_fireteam(sid, units.slice(0, 2), "突击组")
	_runner.assert_false(ft3.is_empty(), "重劈建组应成功")
	_runner.assert_equal(fs.get_fireteam_units(ft1), [units[2]], "旧一号组应收缩（移人后剩 1）")
	_runner.assert_equal(fs.get_unit_fireteam(units[0]), ft3, "移入成员反查应指新组")
	# 旧二号组整组被移走 → 空组自动消亡
	var ft4: String = fs.create_fireteam(sid, units.slice(3), "补位组")
	_runner.assert_equal(fs.get_fireteam_units(ft2), [], "被整组移走的旧二号组应清空")
	_runner.assert_false(fs.get_squad_fireteams(sid).has(ft2), "空组应自动消亡")
	# disband_fireteam：成员留班不散
	fs.disband_fireteam(ft3)
	_runner.assert_equal(fs.get_unit_fireteam(units[0]), "", "解散后成员反查应为空")
	_runner.assert_true(fs.get_squad_units(sid).has(units[0]), "解散组不散班（成员留班）")
	_runner.assert_false(fs.is_fireteam(ft3), "解散组应从注册表移除")
	_runner.assert_true(fs.get_all_squads().has(sid), "班应不受组解散影响")


func _test_order_addressing() -> void:
	var r: Array = _make_fs_with_squad(6)
	var fs: Node = r[0]
	var sid: String = r[1]
	var units: Array = r[2]
	var ft1: String = fs.create_fireteam(sid, units.slice(0, 3), "一号")
	var cc: Node = FakeCommandChain.new()
	add_child(cc)
	var to: Node = ScriptTacticalOrders.new()
	to.setup(fs, cc)
	add_child(to)
	var target := Vector2(900, 500)
	# 对火力组下令：只有组员收令，号令 id = ft_id
	_runner.assert_true(to.issue(ScriptTacticalOrders.OrderType.ADVANCE_ALL, ft1, target), "对火力组下令应成功")
	_runner.assert_equal(cc.calls.size(), 1, "应恰好送达一次")
	_runner.assert_equal(cc.calls[0]["id"], ft1, "号令目标 id 应为火力组 id")
	_runner.assert_equal(cc.calls[0]["units"], units.slice(0, 3), "收令单位应只有组员")
	_runner.assert_equal(cc.calls[0]["behavior"], "move", "ADVANCE_ALL 应映射 move 行为")
	# 对班下令（原语义）：全班收令
	_runner.assert_true(to.issue(ScriptTacticalOrders.OrderType.HOLD_POSITION, sid), "对班下令应成功")
	_runner.assert_equal(cc.calls.size(), 2, "班号令应再次送达")
	_runner.assert_equal(cc.calls[1]["units"], units, "班号令收令单位应为全班")
	# 非战斗职责班的火力组拒绝（职责沿父班判定）。注意组 id 只在各自系统内唯一
	#（同班 id 口径），fs2 的组须用绑定 fs2 的号令节点下发。
	var r2: Array = _make_fs_with_squad(4, "fp_builder_crew")
	var fs2: Node = r2[0]
	var sid2: String = r2[1]
	var ft2: String = fs2.create_fireteam(sid2, r2[2].slice(0, 2), "工程一组")
	_runner.assert_false(ft2.is_empty(), "工程班可建火力组")
	var to2: Node = ScriptTacticalOrders.new()
	to2.setup(fs2, cc)
	add_child(to2)
	_runner.assert_false(to2.issue(ScriptTacticalOrders.OrderType.ADVANCE_ALL, ft2, target), "非战斗职责班的火力组应拒绝号令")
	# 不存在的组拒绝
	_runner.assert_false(to.issue(ScriptTacticalOrders.OrderType.ADVANCE_ALL, "ghost_ft", target), "不存在的火力组应拒绝号令")
	cc.queue_free()
	to.queue_free()
	to2.queue_free()


func _test_no_phase_plan_for_ft() -> void:
	var r: Array = _make_fs_with_squad(6)
	var fs: Node = r[0]
	var sid: String = r[1]
	var units: Array = r[2]
	var ft1: String = fs.create_fireteam(sid, units.slice(0, 3), "一号")
	# 开相位计划（缺省关闭；本测试显式开）
	fs.set_phase_plan_params({"phase_plan_enabled": true})
	var cc: Node = FakeCommandChain.new()
	add_child(cc)
	var to: Node = ScriptTacticalOrders.new()
	to.setup(fs, cc)
	add_child(to)
	# 火力组推进号令：不激活班粒度相位计划（细分不得整班重置决策）
	_runner.assert_true(to.issue(ScriptTacticalOrders.OrderType.ADVANCE_ALL, ft1, Vector2(900, 500)), "火力组号令应成功")
	_runner.assert_equal(fs._squad_phase_plans.size(), 0, "火力组号令不应激活相位计划")
	# 班推进号令：激活（原语义）
	_runner.assert_true(to.issue(ScriptTacticalOrders.OrderType.ADVANCE_ALL, sid, Vector2(900, 500)), "班号令应成功")
	_runner.assert_true(fs._squad_phase_plans.has(sid), "班号令应激活相位计划")
	cc.queue_free()
	to.queue_free()


func _test_membership_changes() -> void:
	var r: Array = _make_fs_with_squad(6)
	var fs: Node = r[0]
	var sid: String = r[1]
	var units: Array = r[2]
	var ft1: String = fs.create_fireteam(sid, units.slice(0, 3), "一号")
	var ft2: String = fs.create_fireteam(sid, units.slice(3), "二号")
	# 组员阵亡 → _process 清理：离班 + 离组（组随成员阵亡收缩）
	units[0]._dead = true
	fs._process(0.6)
	_runner.assert_equal(fs.get_fireteam_units(ft1).size(), 2, "阵亡组员应被移出一号组")
	_runner.assert_equal(fs.get_unit_fireteam(units[0]), "", "阵亡组员反查应为空")
	_runner.assert_equal(fs.get_squad_fireteams(sid), [ft1, ft2], "未空组应保留")
	# 全组阵亡 → 组自动消亡
	units[1]._dead = true
	units[2]._dead = true
	fs._process(0.6)
	_runner.assert_false(fs.get_squad_fireteams(sid).has(ft1), "全组阵亡的一号组应自动消亡")
	_runner.assert_equal(fs.get_squad_fireteams(sid), [ft2], "班内组表应只剩二号组")
	# 离班即离组（remove_unit）
	fs.remove_unit(units[3])
	_runner.assert_equal(fs.get_unit_fireteam(units[3]), "", "离班成员应离组")
	_runner.assert_equal(fs.get_fireteam_units(ft2).size(), 2, "二号组应随离班收缩")
	# 解散班清组
	fs.disband_squad(sid)
	_runner.assert_equal(fs.get_squad_fireteams(sid), [], "解散班应清空其火力组")
	_runner.assert_equal(fs.get_fireteam_count(), 0, "火力组注册表应清空")
