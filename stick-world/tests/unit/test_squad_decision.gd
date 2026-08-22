extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：队伍级共享攻击目标（反编译参考实装 D-B）。
## FormationSystem 排长决策选目标 + get_squad_target 有效性 + 非战斗小队不选 + 无 battle 不选。
## 不进场景树（formation._process 不触发，直接调 _decide_squad_targets），确定性。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptFormationSystem := preload("res://modules/combat/scripts/command/formation_system.gd")

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

	func disband_organization(_org_id: String) -> void:
		pass


class FakeEnemy:
	extends Node2D
	var _faction: int = 0
	var _dead: bool = false

	func is_dead() -> bool:
		return _dead

	func get_faction() -> int:
		return _faction


## 战斗桩：get_enemies_of + is_active
class FakeBattle:
	extends Node
	var enemies: Array = []
	var _active: bool = true

	func get_enemies_of(_faction: int) -> Array:
		return enemies

	func is_active() -> bool:
		return _active


## 单位桩：faction + battle + formation + dead
class FakeUnit:
	extends Node2D
	var faction_id: int = 0
	var battle: Node = null
	var formation: Node = null
	var _dead: bool = false

	func is_dead() -> bool:
		return _dead

	func get_faction() -> int:
		return faction_id

	func get_battle_instance() -> Node:
		return battle

	func get_formation_system() -> Node:
		return formation


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("排长决策: 战斗小队选中共享目标", _test_select_target)
	_runner.add_test("排长决策: 目标死亡后 get_squad_target 返回 null", _test_target_dead)
	_runner.add_test("排长决策: 非战斗小队不选目标", _test_noncombat_skip)
	_runner.add_test("排长决策: 无 battle 不选目标", _test_no_battle)
	_runner.add_test("排长决策: 排长失效退化到首个存活队员", _test_leader_fallback)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


## 构造：formation + battle + 一队自己人 + 一队敌人；squad 用 fp_combat_squad（战斗）
func _make_world(combat: bool = true) -> Dictionary:
	var fs: Node = ScriptFormationSystem.new()
	var org: Node = FakeOrgApi.new()
	fs.setup(org)
	var battle: Node = FakeBattle.new()
	# 我方 2 人（faction 0），敌方 2 人（faction 1）
	var my_units: Array = []
	for i in 2:
		var u := FakeUnit.new()
		u.name = "My%d" % i
		u.position = Vector2(100 + i * 40, 500)
		u.battle = battle
		u.formation = fs
		my_units.append(u)
	var preset_id: String = "fp_combat_squad" if combat else "fp_builder_crew"
	var squad_id: String = fs.create_squad(my_units, "小队", preset_id)
	var enemies: Array = []
	for i in 2:
		var e := FakeEnemy.new()
		e.name = "Enemy%d" % i
		e.position = Vector2(600 + i * 40, 500)
		enemies.append(e)
	battle.enemies = enemies
	return {"fs": fs, "battle": battle, "units": my_units, "enemies": enemies, "squad_id": squad_id}


func _test_select_target() -> void:
	var w: Dictionary = _make_world(true)
	var fs: Node = w["fs"]
	var sid: String = w["squad_id"]
	if sid.is_empty():
		_runner.assert_true(false, "小队创建失败")
		return
	fs._decide_squad_targets(0.5)
	var t: Node = fs.get_squad_target(sid)
	_runner.assert_true(t != null, "战斗小队应选中共享目标")
	if t != null:
		_runner.assert_true(t in w["enemies"], "共享目标应为敌人")


func _test_target_dead() -> void:
	var w: Dictionary = _make_world(true)
	var fs: Node = w["fs"]
	var sid: String = w["squad_id"]
	if sid.is_empty():
		_runner.assert_true(false, "小队创建失败")
		return
	fs._decide_squad_targets(0.5)
	var t: Node = fs.get_squad_target(sid)
	if t != null:
		(t as FakeEnemy)._dead = true
		_runner.assert_true(fs.get_squad_target(sid) == null, "目标死亡后应返回 null")
	else:
		_runner.assert_true(false, "未选中目标，测试前提失败")


func _test_noncombat_skip() -> void:
	var w: Dictionary = _make_world(false)
	var fs: Node = w["fs"]
	var sid: String = w["squad_id"]
	if sid.is_empty():
		_runner.assert_true(false, "小队创建失败")
		return
	fs._decide_squad_targets(0.5)
	_runner.assert_true(fs.get_squad_target(sid) == null, "非战斗小队不应选目标")


func _test_no_battle() -> void:
	var fs: Node = ScriptFormationSystem.new()
	var org: Node = FakeOrgApi.new()
	fs.setup(org)
	var units: Array = []
	for i in 2:
		var u := FakeUnit.new()
		u.name = "NoBattle%d" % i
		u.battle = null
		u.formation = fs
		units.append(u)
	var sid: String = fs.create_squad(units, "无战", "fp_combat_squad")
	if sid.is_empty():
		_runner.assert_true(false, "小队创建失败")
		return
	fs._decide_squad_targets(0.5)
	_runner.assert_true(fs.get_squad_target(sid) == null, "无 battle 不应选目标")


func _test_leader_fallback() -> void:
	var w: Dictionary = _make_world(true)
	var fs: Node = w["fs"]
	var sid: String = w["squad_id"]
	if sid.is_empty():
		_runner.assert_true(false, "小队创建失败")
		return
	# 把 leader 设为一个死亡单位
	var leader: FakeUnit = w["units"][0]
	leader._dead = true
	fs.assign_leader(sid, leader)
	fs._decide_squad_targets(0.5)
	var t: Node = fs.get_squad_target(sid)
	_runner.assert_true(t != null, "排长失效时退化到存活队员，仍应选到目标")
	if t != null:
		_runner.assert_true(t in w["enemies"], "共享目标应为敌人")
