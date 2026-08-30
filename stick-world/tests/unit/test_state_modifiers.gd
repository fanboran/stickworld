extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：状态调制（反编译参考实装 E）——低血狂暴 / 被围背墙背水一战。
## 决策层：AIController._compute_state_modifiers + _should_rage（士气分叉 + 被围背墙强制狂暴）
## 行为层：behavior_attack 狂暴时跳过"低血找掩体 finish"。
## 不进场景树（ai_controller 不调 _ready / behavior 不挂状态机），确定性。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptAIController := preload("res://modules/units/scripts/ai/ai_controller.gd")
const ScriptBehaviorAttack := preload("res://modules/units/scripts/ai/behavior_attack.gd")

var _runner: TestRunner


class FakeHealth:
	extends Node
	var _hp_ratio: float = 1.0
	var _morale_ratio: float = 1.0
	var _routed: bool = false

	func get_hp_ratio() -> float:
		return _hp_ratio

	func get_morale_ratio() -> float:
		return _morale_ratio

	func is_routed() -> bool:
		return _routed


class FakeEnemy:
	extends Node2D
	var _dead: bool = false

	func is_dead() -> bool:
		return _dead

	func get_faction() -> int:
		return 1


class FakeCover:
	extends Node
	var _in_cover_positions: Array = []

	func has_covers() -> bool:
		return true

	func is_in_cover(pos: Vector2) -> bool:
		for p in _in_cover_positions:
			if pos.distance_to(p) <= 40.0:
				return true
		return false

	func find_nearest_cover(_pos: Vector2) -> Vector2:
		return _in_cover_positions[0] if not _in_cover_positions.is_empty() else Vector2.ZERO


class FakeBattle:
	extends Node
	var enemies: Array = []
	var cover: FakeCover = null
	var _active: bool = true

	func get_enemies_of(_faction: int) -> Array:
		return enemies

	func get_cover() -> FakeCover:
		return cover

	func is_active() -> bool:
		return _active


class FakeEntity:
	extends CharacterBody2D
	var health: FakeHealth = FakeHealth.new()
	var battle: FakeBattle = null
	var faction_id: int = 0
	var _facing: int = 1

	func get_health() -> FakeHealth:
		return health

	func get_faction() -> int:
		return faction_id

	func get_facing() -> int:
		return _facing

	func is_dead() -> bool:
		return false

	func get_battle_instance() -> FakeBattle:
		return battle

	func get_formation_system() -> Node:
		return null

	func get_weapon() -> Node:
		return null

	func ai_stop() -> void:
		pass

	func ai_move(_dir: Vector2, _run: bool) -> void:
		pass


## 构造：ai_controller（不调 _ready）+ fake entity + battle + 敌人 + 掩体
func _make_world() -> Dictionary:
	var ai: Node = ScriptAIController.new()
	var entity := FakeEntity.new()
	entity.position = Vector2(0, 0)
	var battle := FakeBattle.new()
	entity.battle = battle
	var cover := FakeCover.new()
	battle.cover = cover
	ai._entity = entity
	return {"ai": ai, "entity": entity, "battle": battle, "cover": cover}


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("状态调制: 被围检测（2 敌在范围内）", _test_surrounded)
	_runner.add_test("状态调制: 背墙检测（身后有掩体）", _test_backed_to_wall)
	_runner.add_test("状态调制: 低血检测", _test_low_hp)
	_runner.add_test("狂暴判定: 被围+背墙强制狂暴", _test_rage_surrounded_wall)
	_runner.add_test("狂暴判定: 低血+士气高狂暴", _test_rage_low_hp_high_morale)
	_runner.add_test("狂暴判定: 低血+士气低不狂暴", _test_rage_low_hp_low_morale)
	_runner.add_test("狂暴判定: 溃逃不狂暴", _test_rage_routing)
	_runner.add_test("狂暴行为: 狂暴跳过低血找掩体 finish", _test_attack_rage_no_finish)
	_runner.add_test("狂暴行为: 非狂暴低血+掩体 finish", _test_attack_normal_finish)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _test_surrounded() -> void:
	var w: Dictionary = _make_world()
	var ai: Node = w["ai"]
	var battle: FakeBattle = w["battle"]
	for i in 2:
		var e := FakeEnemy.new()
		e.position = Vector2(50 + i * 30, 0)  # 120px 内
		battle.enemies.append(e)
	var mods: Dictionary = ai._compute_state_modifiers(battle, (w["entity"] as FakeEntity).health)
	_runner.assert_true(mods["surrounded"], "2 敌在范围内应判被围")


func _test_backed_to_wall() -> void:
	var w: Dictionary = _make_world()
	var ai: Node = w["ai"]
	var entity: FakeEntity = w["entity"]
	var cover: FakeCover = w["cover"]
	# 朝向 1（右），身后 = 左 80px 处有掩体
	cover._in_cover_positions = [entity.position + Vector2(-80, 0)]
	var mods: Dictionary = ai._compute_state_modifiers(w["battle"], entity.health)
	_runner.assert_true(mods["backed_to_wall"], "身后有掩体应判背墙")


func _test_low_hp() -> void:
	var w: Dictionary = _make_world()
	var ai: Node = w["ai"]
	var entity: FakeEntity = w["entity"]
	entity.health._hp_ratio = 0.2
	var mods: Dictionary = ai._compute_state_modifiers(w["battle"], entity.health)
	_runner.assert_true(mods["low_hp"], "hp_ratio 0.2 应判低血")


func _test_rage_surrounded_wall() -> void:
	var w: Dictionary = _make_world()
	var ai: Node = w["ai"]
	var entity: FakeEntity = w["entity"]
	var battle: FakeBattle = w["battle"]
	var cover: FakeCover = w["cover"]
	for i in 2:
		var e := FakeEnemy.new()
		e.position = Vector2(50 + i * 30, 0)
		battle.enemies.append(e)
	cover._in_cover_positions = [entity.position + Vector2(-80, 0)]
	var mods: Dictionary = ai._compute_state_modifiers(battle, entity.health)
	_runner.assert_true(ai._should_rage(mods, entity.health), "被围+背墙应强制狂暴")


func _test_rage_low_hp_high_morale() -> void:
	var w: Dictionary = _make_world()
	var ai: Node = w["ai"]
	var entity: FakeEntity = w["entity"]
	entity.health._hp_ratio = 0.2
	entity.health._morale_ratio = 0.6
	var mods: Dictionary = ai._compute_state_modifiers(w["battle"], entity.health)
	_runner.assert_true(ai._should_rage(mods, entity.health), "低血+士气高应狂暴")


func _test_rage_low_hp_low_morale() -> void:
	var w: Dictionary = _make_world()
	var ai: Node = w["ai"]
	var entity: FakeEntity = w["entity"]
	entity.health._hp_ratio = 0.2
	entity.health._morale_ratio = 0.3
	var mods: Dictionary = ai._compute_state_modifiers(w["battle"], entity.health)
	_runner.assert_false(ai._should_rage(mods, entity.health), "低血+士气低不应狂暴（走溃逃）")


func _test_rage_routing() -> void:
	var w: Dictionary = _make_world()
	var ai: Node = w["ai"]
	var entity: FakeEntity = w["entity"]
	var battle: FakeBattle = w["battle"]
	var cover: FakeCover = w["cover"]
	for i in 2:
		var e := FakeEnemy.new()
		e.position = Vector2(50 + i * 30, 0)
		battle.enemies.append(e)
	cover._in_cover_positions = [entity.position + Vector2(-80, 0)]
	entity.health._routed = true
	var mods: Dictionary = ai._compute_state_modifiers(battle, entity.health)
	_runner.assert_false(ai._should_rage(mods, entity.health), "溃逃不应狂暴")


## 构造一个进入 update 的行为：battle 有 1 敌、battle active、entity 低血
func _make_attack_behavior(rage: bool) -> Dictionary:
	var w: Dictionary = _make_world()
	var entity: FakeEntity = w["entity"]
	var battle: FakeBattle = w["battle"]
	entity.health._hp_ratio = 0.2
	entity.health._morale_ratio = 0.5
	# 掩体在实体附近（触发 _has_cover_nearby）
	(w["cover"] as FakeCover)._in_cover_positions = [entity.position]
	var e := FakeEnemy.new()
	e.position = Vector2(100, 0)
	battle.enemies = [e]
	var beh: Node = ScriptBehaviorAttack.new()
	beh.entity = entity
	beh.enter("", {"battle": battle, "rage": rage})
	return {"beh": beh, "entity": entity}


func _test_attack_rage_no_finish() -> void:
	var r: Dictionary = _make_attack_behavior(true)
	var beh: Node = r["beh"]
	beh.update(0.1)
	_runner.assert_false(beh.is_finished(), "狂暴时低血+掩体不应 finish")


func _test_attack_normal_finish() -> void:
	var r: Dictionary = _make_attack_behavior(false)
	var beh: Node = r["beh"]
	beh.update(0.1)
	_runner.assert_true(beh.is_finished(), "非狂暴低血+掩体应 finish（找掩体）")
