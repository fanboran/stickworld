extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：排聚合层（现实军衔体系重排）。
## create_platoon 聚合/反查 + 排长任命（rank 2，成员校验/跨排卸任）+ 排长阵亡
## 指挥链缺口（该排失去集火、无补位无继任）+ 班长轮转不受影响（组织侧补位回写）
## + 班解散离排/排空自动解散/排解散释放班。
## 不进场景树（formation._process 直调），确定性。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptFormationSystem := preload("res://modules/formation/scripts/formation_system.gd")

var _runner: TestRunner


## 假组织 API：记录调用，模拟成功返回；remove_commander 可触发继任回写（班长轮转）
class FakeOrgApi:
	extends Node
	var _next_id: int = 1
	var removed: Array = []          # [org_id, stickman_id]
	var commander_removed: Array = []  # org_id

	func create_organization(_org_name: String, _tag: String, _tier: int, _parent_id: String) -> Dictionary:
		var org_id := "org_%d" % _next_id
		_next_id += 1
		return {"ok": true, "data": {"org_id": org_id}}

	func assign_stickman(_org_id: String, _stickman_id: String, _role: String) -> void:
		pass

	func assign_commander(_org_id: String, _stickman_id: String) -> void:
		pass

	func remove_stickman(org_id: String, stickman_id: String) -> void:
		removed.append([org_id, stickman_id])

	func remove_commander(org_id: String) -> void:
		commander_removed.append(org_id)

	func disband_organization(_org_id: String) -> void:
		pass


class FakeEnemy:
	extends Node2D
	var _dead: bool = false

	func is_dead() -> bool:
		return _dead

	func get_faction() -> int:
		return 1


## 战斗桩：get_enemies_of + is_active
class FakeBattle:
	extends Node
	var enemies: Array = []

	func get_enemies_of(_faction: int) -> Array:
		return enemies

	func is_active() -> bool:
		return true


## 单位桩：faction + battle + dead（无 rank 字段 → formation 侧 set_meta 兜底口径）
class FakeUnit:
	extends Node2D
	var faction_id: int = 0
	var battle: Node = null
	var _dead: bool = false

	func is_dead() -> bool:
		return _dead

	func get_faction() -> int:
		return faction_id

	func get_battle_instance() -> Node:
		return battle


## 带原生 rank 字段的单位桩（实体侧字段已落的口径：属性写而非 meta）
class RankedUnit:
	extends FakeUnit
	var rank: int = 0


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("排层: create_platoon 聚合与反查/重复归属拒绝", _test_create_and_lookup)
	_runner.add_test("排层: 排长任命 rank=2（meta 兜底 + 原生字段两口径）", _test_platoon_leader_rank)
	_runner.add_test("排层: 排长阵亡 = 指挥链缺口，该排失去集火", _test_leader_death_gap)
	_runner.add_test("排层: 缺口不影响班长轮转（组织侧补位回写 rank 1）", _test_squad_rotation_unaffected)
	_runner.add_test("排层: 班解散离排/排空自动解散/排解散释放班", _test_disband_chaining)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


## 构造 n 个无 rank 字段的单位桩
func _make_units(n: int, battle: Node = null) -> Array:
	var units: Array = []
	for i in n:
		var u := FakeUnit.new()
		u.name = "U%d" % i
		u.position = Vector2(100 + i * 40, 500)
		u.battle = battle
		units.append(u)
	return units


## 构造 FormationSystem + 指定人数的班（fp_combat_squad 战斗预设）
func _make_fs_with_squads(sizes: Array, org: Node) -> Array:
	var fs: Node = ScriptFormationSystem.new()
	fs.setup(org)
	var sids: Array = []
	var all_units: Array = []
	for i in sizes.size():
		var units: Array = _make_units(int(sizes[i]))
		sids.append(fs.create_squad(units, "班%d" % i, "fp_combat_squad"))
		all_units.append(units)
	return [fs, sids, all_units]


func _test_create_and_lookup() -> void:
	var org: Node = FakeOrgApi.new()
	var r: Array = _make_fs_with_squads([3, 3, 3], org)
	var fs: Node = r[0]
	var sids: Array = r[1]
	var pid: String = fs.create_platoon([sids[0], sids[1]], "一排")
	_runner.assert_false(pid.is_empty(), "建排应成功")
	_runner.assert_equal(fs.get_platoon_squads(pid), [sids[0], sids[1]], "排内班表应一致")
	_runner.assert_equal(fs.get_platoon_of_squad(sids[0]), pid, "班反查排应命中")
	_runner.assert_equal(fs.get_platoon_of_squad(sids[1]), pid, "班反查排应命中")
	_runner.assert_equal(fs.get_platoon_of_squad(sids[2]), "", "未编排班应返回空")
	_runner.assert_equal(fs.get_platoon_count(), 1, "排计数 = 1")
	# 已属排的班再入他排 → 拒绝；不存在的班 → 拒绝
	_runner.assert_true(fs.create_platoon([sids[2], sids[0]]).is_empty(), "重复归属应拒绝")
	_runner.assert_true(fs.create_platoon(["ghost_squad"]).is_empty(), "班不存在应拒绝")
	# 单位级反查
	var u0: Node = fs.get_squad_units(sids[0])[0]
	_runner.assert_equal(fs.get_unit_platoon(u0), pid, "单位反查排应命中")


func _test_platoon_leader_rank() -> void:
	var org: Node = FakeOrgApi.new()
	var r: Array = _make_fs_with_squads([4, 4], org)
	var fs: Node = r[0]
	var sids: Array = r[1]
	var units: Array = r[2]
	var pid: String = fs.create_platoon([sids[0], sids[1]])
	# 排内第一班成员可任命；无 rank 字段 → set_meta 兜底
	var leader: Node = units[0][0]
	_runner.assert_true(fs.assign_platoon_leader(pid, leader), "排内成员可任命排长")
	_runner.assert_true(fs.get_platoon_leader(pid) == leader, "排长查询应命中")
	_runner.assert_equal(fs._get_unit_rank(leader), 2, "排长军衔应为 2（meta 兜底）")
	_runner.assert_equal(int(leader.get_meta("rank")), 2, "无字段桩应走 set_meta 兜底")
	# 非本排成员拒绝
	var outsider: Node = _make_units(1)[0]
	_runner.assert_false(fs.assign_platoon_leader(pid, outsider), "排外单位应拒绝")
	# 带原生 rank 字段的桩：属性口径（set_rank 方法缺省走 "rank" in u 分支）
	var ranked_fs: Node = ScriptFormationSystem.new()
	ranked_fs.setup(FakeOrgApi.new())
	var ru: RankedUnit = RankedUnit.new()
	ru.position = Vector2.ZERO
	var rsid: String = ranked_fs.create_squad([ru], "带衔班", "fp_combat_squad")
	var rpid: String = ranked_fs.create_platoon([rsid])
	_runner.assert_true(ranked_fs.assign_platoon_leader(rpid, ru), "带字段桩任命应成功")
	_runner.assert_equal(ru.rank, 2, "原生 rank 字段应直写属性")


func _test_leader_death_gap() -> void:
	var org: Node = FakeOrgApi.new()
	var fs: Node = ScriptFormationSystem.new()
	fs.setup(org)
	var battle: Node = FakeBattle.new()
	var enemies: Array = []
	for i in 2:
		var e := FakeEnemy.new()
		e.name = "Enemy%d" % i
		e.position = Vector2(600 + i * 40, 500)
		enemies.append(e)
	battle.enemies = enemies
	var s1_units: Array = _make_units(3, battle)
	var s2_units: Array = _make_units(3, battle)
	var s1: String = fs.create_squad(s1_units, "甲班", "fp_combat_squad")
	var s2: String = fs.create_squad(s2_units, "乙班", "fp_combat_squad")
	var pid: String = fs.create_platoon([s1, s2])
	# 排长 = 甲班队首；班长 = 各班中位（轮转对照口）
	var platoon_leader: Node = s1_units[0]
	fs.assign_platoon_leader(pid, platoon_leader)
	fs.assign_leader(s1, s1_units[1])
	fs.assign_leader(s2, s2_units[1])
	# 决策一轮 → 排内两班共享目标（排长决策）
	fs._decide_squad_targets(0.6)
	_runner.assert_true(fs.get_squad_target(s1) != null, "排长在 → 甲班应选中集火目标")
	_runner.assert_true(fs.get_squad_target(s2) != null, "排长在 → 乙班应选中集火目标")
	# 缺口信号挂计数
	var lost_count: Array = [0]
	fs.platoon_leader_lost.connect(func(_pid: String) -> void: lost_count[0] += 1)
	# 排长阵亡 → 下一拍清理：缺口置位 + 该排集火清空
	platoon_leader._dead = true
	fs._process(0.6)
	_runner.assert_true(fs.get_platoon_leader(pid) == null, "排长阵亡后应置缺口（null）")
	_runner.assert_equal(lost_count[0], 1, "应发一次 platoon_leader_lost")
	_runner.assert_false(fs.has_squad_command_chain(s1), "缺口后甲班指挥链应断")
	_runner.assert_false(fs.has_squad_command_chain(s2), "缺口后乙班指挥链应断")
	# 再决策 → 该排不再获得集火目标（无退化、到战斗结束）
	fs._decide_squad_targets(0.6)
	_runner.assert_true(fs.get_squad_target(s1) == null, "缺口后甲班应失去集火号令")
	_runner.assert_true(fs.get_squad_target(s2) == null, "缺口后乙班应失去集火号令")


func _test_squad_rotation_unaffected() -> void:
	var org: Node = FakeOrgApi.new()
	var fs: Node = ScriptFormationSystem.new()
	fs.setup(org)
	var s1_units: Array = _make_units(3)
	var s1: String = fs.create_squad(s1_units, "甲班", "fp_combat_squad")
	var pid: String = fs.create_platoon([s1])
	fs.assign_platoon_leader(pid, s1_units[0])
	fs.assign_leader(s1, s1_units[1])
	# 班长阵亡 → _process 清理走组织侧 remove_stickman/remove_commander；
	# 继任补位由组织模块发 commander_assigned，此处直调回写口模拟
	s1_units[1]._dead = true
	fs._process(0.6)
	_runner.assert_true(org.commander_removed.has(s1), "班长阵亡应触发组织侧 remove_commander")
	var successor: Node = s1_units[2]
	fs._on_commander_assigned(s1, successor.get_instance_id())
	_runner.assert_true(fs.get_squad_leader(s1) == successor, "班长轮转：继任者应回写为班长")
	_runner.assert_equal(fs._get_unit_rank(successor), 1, "继任班长军衔应为 1")
	# 排长（未阵亡）与班长轮转互不干扰
	_runner.assert_true(fs.get_platoon_leader(pid) == s1_units[0], "排长不应受班长轮转影响")
	_runner.assert_equal(fs._get_unit_rank(s1_units[0]), 2, "排长军衔应保持 2")


func _test_disband_chaining() -> void:
	var org: Node = FakeOrgApi.new()
	var r: Array = _make_fs_with_squads([3, 3, 3], org)
	var fs: Node = r[0]
	var sids: Array = r[1]
	var units: Array = r[2]
	var pid: String = fs.create_platoon([sids[0], sids[1]])
	var leader: Node = units[0][0]
	fs.assign_platoon_leader(pid, leader)
	# 班解散 → 离排，排保留余班
	fs.disband_squad(sids[0])
	_runner.assert_equal(fs.get_platoon_count(), 1, "排内还有班，排应保留")
	_runner.assert_equal(fs.get_platoon_squads(pid), [sids[1]], "排内班表应收缩")
	# 末班解散 → 排空自动解散
	fs.disband_squad(sids[1])
	_runner.assert_equal(fs.get_platoon_count(), 0, "排空应自动解散")
	# disband_platoon：班保留转独立、排长削秩
	var pid2: String = fs.create_platoon([sids[2]])
	fs.assign_platoon_leader(pid2, units[2][0])
	fs.disband_platoon(pid2)
	_runner.assert_equal(fs.get_platoon_of_squad(sids[2]), "", "释放后班应为独立班")
	_runner.assert_true(fs.get_all_squads().has(sids[2]), "班应保留不随排散")
	_runner.assert_equal(fs._get_unit_rank(units[2][0]), 0, "卸任排长应削秩为兵")
	# 全清（跨图携带口径）：排层一并清空
	var pid3: String = fs.create_platoon([sids[2]])
	_runner.assert_false(pid3.is_empty(), "独立班可再入新排")
	fs.disband_all_squads()
	_runner.assert_equal(fs.get_platoon_count(), 0, "全清后排层应清空")
