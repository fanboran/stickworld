extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：AI 完善批次 3——士气情绪系统。
## 3.1 伤亡恐慌（队友死亡 → 同阵营按距离掉士气）
## 3.2 指挥官光环（排长存活 → 队员士气恢复）
## 3.3 lose_morale/restore_morale 接口
## 使用真实 health_component / battle_instance / formation_system。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptBattleInstance := preload("res://modules/combat/scripts/battle/battle_instance.gd")
const ScriptFormationSystem := preload("res://modules/combat/scripts/command/formation_system.gd")
const ScriptHealthComponent := preload("res://modules/units/scripts/entity/health_component.gd")

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


class FakeUnit:
	extends CharacterBody2D
	var faction_id: int = 0
	var battle: Node = null
	var health: Node = null
	var _dead: bool = false

	func set_faction(fid: int) -> void:
		faction_id = fid

	func get_faction() -> int:
		return faction_id

	func set_battle_instance(bi: Node) -> void:
		battle = bi

	func get_battle_instance() -> Node:
		return battle

	func get_health() -> Node:
		return health

	func get_weapon() -> Node:
		return null

	func get_formation_system() -> Node:
		return null

	func is_dead() -> bool:
		return _dead

	func set_role(_r: String) -> void:
		pass


func _make_unit(faction: int, pos: Vector2, morale: float = 100.0) -> FakeUnit:
	var u := FakeUnit.new()
	u.faction_id = faction
	u.position = pos
	var h: Node = ScriptHealthComponent.new()
	h.max_morale = 100.0
	h.max_hp = 100.0
	h.hp = 100.0  # 未死（lose_morale/restore 内部判 is_dead）
	h.morale = morale
	u.health = h
	return u


func _make_battle() -> Node:
	var map := Node2D.new()
	map.name = "TestMap"
	add_child(map)
	var battle: Node = ScriptBattleInstance.new()
	battle.name = "TestBattle"
	add_child(battle)
	battle.setup(map)
	battle.start()
	return battle


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("伤亡恐慌: 近处友军掉士气", _test_casualty_near)
	_runner.add_test("伤亡恐慌: 远处友军不受影响", _test_casualty_far)
	_runner.add_test("指挥官光环: 排长存活队员回士气", _test_aura_alive)
	_runner.add_test("指挥官光环: 排长死亡无光环", _test_aura_dead)
	_runner.add_test("士气接口: lose_morale 到 0 不越界", _test_lose_floor)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _test_casualty_near() -> void:
	var battle: Node = _make_battle()
	var dead := _make_unit(1, Vector2(0, 0))
	var ally_near := _make_unit(1, Vector2(100, 0))  # 100px 内
	var ally_far := _make_unit(1, Vector2(1000, 0))  # 600px 外
	battle.add_unit(dead, 1)
	battle.add_unit(ally_near, 1)
	battle.add_unit(ally_far, 1)
	dead._dead = true
	battle.on_unit_died(dead)
	var h_near: Node = ally_near.health
	_runner.assert_true(h_near.morale < 100.0, "近处友军士气应下降，实际 %f" % h_near.morale)
	var h_far: Node = ally_far.health
	_runner.assert_true(h_far.morale == 100.0, "远处友军士气不应下降，实际 %f" % h_far.morale)


func _test_casualty_far() -> void:
	var battle: Node = _make_battle()
	var dead := _make_unit(2, Vector2(0, 0))
	var far := _make_unit(2, Vector2(2000, 0))
	battle.add_unit(dead, 2)
	battle.add_unit(far, 2)
	dead._dead = true
	battle.on_unit_died(dead)
	_runner.assert_true(far.health.morale == 100.0, "超影响半径不应掉士气")


func _test_aura_alive() -> void:
	var fs: Node = ScriptFormationSystem.new()
	fs.setup(FakeOrgApi.new())
	var leader := _make_unit(1, Vector2(0, 0), 100.0)
	var m1 := _make_unit(1, Vector2(50, 0), 40.0)
	var m2 := _make_unit(1, Vector2(-50, 0), 40.0)
	var sid: String = fs.create_squad([leader, m1, m2], "光环队", "fp_combat_squad")
	if sid.is_empty():
		_runner.assert_true(false, "小队创建失败")
		return
	fs.assign_leader(sid, leader)
	fs._apply_leader_morale_aura(1.0)
	_runner.assert_true(m1.health.morale > 40.0, "队员士气应因光环恢复，实际 %f" % m1.health.morale)
	_runner.assert_true(m2.health.morale > 40.0, "队员士气应因光环恢复")


func _test_aura_dead() -> void:
	var fs: Node = ScriptFormationSystem.new()
	fs.setup(FakeOrgApi.new())
	var leader := _make_unit(1, Vector2(0, 0), 100.0)
	var m1 := _make_unit(1, Vector2(50, 0), 40.0)
	var sid: String = fs.create_squad([leader, m1], "光环队2", "fp_combat_squad")
	if sid.is_empty():
		_runner.assert_true(false, "小队创建失败")
		return
	fs.assign_leader(sid, leader)
	leader._dead = true
	fs._apply_leader_morale_aura(1.0)
	_runner.assert_true(m1.health.morale == 40.0, "排长死亡不应有光环")


func _test_lose_floor() -> void:
	var h: Node = ScriptHealthComponent.new()
	h.max_morale = 100.0
	h.max_hp = 100.0
	h.hp = 100.0
	h.morale = 5.0
	h.lose_morale(50.0)
	_runner.assert_true(h.morale == 0.0, "士气应封底到 0，实际 %f" % h.morale)
