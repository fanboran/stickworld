extends Node
## 集成测试：玩家战斗模式（Q 切换）+ 小队跟随 + 攻击展开（防一字长蛇）。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_combat_control.tscn -- --fresh-start
##
## 退出码：0 全部通过，1 有失败
##
## 测试覆盖：
##   - Q 键切换建造/战斗模式（BATTLE 模式保持玩家附身）
##   - 小队跟随：开启跟随后成员进入 follow 行为并尾随玩家
##   - 攻击展开：保角环绕使各攻击者从不同方位接近目标（防 1 字长蛇）
##
## 公共 setup 在 tests/helpers/combat_test_setup.gd。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const CombatTestSetup := preload("res://tests/helpers/combat_test_setup.gd")
const ScriptBehaviorAttack := preload("res://modules/units/scripts/ai/behavior_attack.gd")

var _runner: TestRunner
var _helper: CombatTestSetup
var _tests: Array = []
var _formation: Node = null


func _ready() -> void:
	_runner = TestRunner.new()
	_register_tests()
	_run_tests_async()


func _register_tests() -> void:
	_tests.append({"name": "Q键: 切换战斗模式且保持附身", "fn": Callable(self, "_test_q_toggle_mode"), "async": true})
	_tests.append({"name": "跟随: 小队开启跟随进入 follow 行为", "fn": Callable(self, "_test_follow_behavior"), "async": true})
	_tests.append({"name": "跟随: 成员尾随玩家移动", "fn": Callable(self, "_test_follow_moves"), "async": true})
	_tests.append({"name": "展开: 保角环绕从不同方位接近", "fn": Callable(self, "_test_attack_spread"), "async": true})


func _run_tests_async() -> void:
	_helper = CombatTestSetup.new()
	await _helper.start(self)
	_formation = _helper.formation
	# 生成测试单位（跟随/展开用）
	_helper.spawn_test_units(4)
	for i in 2:
		await get_tree().process_frame
	for u in _helper.units:
		if u != null and u.has_method("set_formation_system"):
			u.set_formation_system(_formation)

	for t in _tests:
		_runner.begin_test(t["name"])
		await t["fn"].call()
		_runner.end_test()
		print("完成: %s" % t["name"])

	var summary := _runner.summary()
	print(summary)
	var exit_code: int = 0 if _runner.all_passed() else 1
	get_tree().quit(exit_code)


## Q 键：玩家附身时切换 EXPLORE<->BATTLE，BATTLE 模式保持附身
func _test_q_toggle_mode() -> void:
	var dispatcher: Node = _helper.game_root.input_dispatcher
	if dispatcher == null:
		_runner.assert_true(false, "InputDispatcher 为空")
		return
	# 让第一个单位成为"玩家"（附身）
	var player: Node = _helper.units[0]
	if player == null:
		_runner.assert_true(false, "单位缺失")
		return
	if player.has_method("set_possessed"):
		player.set_possessed(true)
	await get_tree().process_frame
	# 初始为 BATTLE（CombatTestSetup 已切）：第一次 Q 切回 EXPLORE
	# 白盒标注（2026-08 审计）：私有方法直接驱动，重构时同步
	if player.has_method("_toggle_combat_mode"):
		player._toggle_combat_mode()
	await get_tree().process_frame
	_runner.assert_equal(dispatcher.get_mode(), PlayerControlAPI.Mode.EXPLORE, "第一次 Q 应切回 EXPLORE 模式")
	_runner.assert_true(player.is_possessed(), "EXPLORE 模式下玩家应保持附身")
	# 第二次 Q 进入 BATTLE（战斗姿态）
	player._toggle_combat_mode()
	await get_tree().process_frame
	_runner.assert_equal(dispatcher.get_mode(), PlayerControlAPI.Mode.BATTLE, "第二次 Q 应切换到 BATTLE 模式")
	_runner.assert_true(player.is_possessed(), "BATTLE 模式下玩家应保持附身（可左键挥砍）")
	# 还原：切回 EXPLORE 并取消附身
	player._toggle_combat_mode()
	await get_tree().process_frame
	player.set_possessed(false)


## 跟随：小队开启跟随后，成员 AI 决策进入 follow 行为
func _test_follow_behavior() -> void:
	if _formation == null:
		_runner.assert_true(false, "FormationSystem 为空")
		return
	# 用 units[1..2] 建小队（无战斗职责的工人队即可）
	var squad_id: String = _formation.create_squad([_helper.units[1], _helper.units[2]], "随行队", "fp_worker_crew")
	_runner.assert_true(not squad_id.is_empty(), "小队应创建成功")
	# 开启跟随
	_runner.assert_true(_formation.set_squad_follow(squad_id, true), "开启跟随应成功")
	_runner.assert_true(_formation.is_squad_following(squad_id), "跟随状态应生效")
	# 有玩家（possessed 实体）时成员应进入 follow
	var player: Node = _helper.units[0]
	if player.has_method("set_possessed"):
		player.set_possessed(true)
	await get_tree().process_frame
	# 等待 AI 决策周期（0.3s）
	await get_tree().create_timer(0.8).timeout
	var ai: Node = _helper.units[1].get_ai_controller() if _helper.units[1].has_method("get_ai_controller") else null
	if ai == null:
		_runner.assert_true(false, "成员无 AIController")
		return
	var behavior: String = ai.get_current_behavior()
	_runner.assert_equal(behavior, "follow", "成员行为应为 follow，实际: %s" % behavior)
	# 清理：关闭跟随
	_formation.set_squad_follow(squad_id, false)


## 跟随：成员向玩家位置靠近
func _test_follow_moves() -> void:
	if _formation == null:
		_runner.assert_true(false, "FormationSystem 为空")
		return
	var squad_id: String = _formation.get_unit_squad(_helper.units[1])
	if squad_id.is_empty():
		_runner.assert_true(false, "找不到随行队")
		return
	var player: Node = _helper.units[0]
	# 玩家在 (1200, 500)，成员远在 (3000, 500)
	player.global_position = Vector2(1200, 500)
	_helper.units[1].global_position = Vector2(3000, 500)
	_formation.set_squad_follow(squad_id, true)
	await get_tree().process_frame
	var dist_before: float = _helper.units[1].global_position.distance_to(player.global_position)
	# 等 2.5s（成员 160px/s，1800px 需 11s——只验证"向玩家靠近"）
	await get_tree().create_timer(2.5).timeout
	var dist_after: float = _helper.units[1].global_position.distance_to(player.global_position)
	_runner.assert_true(dist_after < dist_before, "成员应向玩家靠近，before=%.0f after=%.0f" % [dist_before, dist_after])
	_formation.set_squad_follow(squad_id, false)


## 攻击展开：保角环绕使同线攻击者从不同方位接近目标（防 1 字长蛇）
func _test_attack_spread() -> void:
	# 构造：两个攻击者与目标几乎同线（A 正右、B 右上方 26°），
	# 保角逻辑应让 B 保持其方位角（目标点=敌人+自身方向*半径），而非与 A 同点。
	var attacker_a: Node = _helper.units[2]
	var attacker_b: Node = _helper.units[3]
	var target: Node = _helper.units[0]
	if attacker_a == null or attacker_b == null or target == null:
		_runner.assert_true(false, "单位缺失")
		return
	attacker_a.global_position = Vector2(1000, 500)
	attacker_b.global_position = Vector2(1000, 400)  # 相对目标 (1200,500) 方位约 26.5°
	target.global_position = Vector2(1200, 500)
	# battle stub：提供 is_active + get_nearest_enemy
	var stub := Node.new()
	stub.name = "BattleStub"
	add_child(stub)
	stub.set_script(load("res://tests/integration/battle_stub.gd"))
	stub.setup([], [target])
	# 手动驱动 attack 行为（不依赖完整战斗）
	var atk_a: Node = ScriptBehaviorAttack.new()
	atk_a.name = "AtkA"
	atk_a.behavior_name = "attack"
	atk_a.entity = attacker_a
	add_child(atk_a)
	atk_a.enter("", {"battle": stub})
	atk_a.update(0.1)
	# A 的移动方向（ai_move 设置到实体 _ai_move_dir）
	var dir_a: Vector2 = attacker_a.get("_ai_move_dir")
	var dir_b: Vector2 = attacker_b.get("_ai_move_dir")
	# 直接算期望：A 应朝正右（0°），B 应保持其方位角（>0°）
	var ang_a: float = atan2(dir_a.y, dir_a.x)
	_runner.assert_true(absf(ang_a) < 0.05, "A 应朝正右接近，角度: %f" % ang_a)
	# B 尚未驱动——手动驱动
	var atk_b: Node = ScriptBehaviorAttack.new()
	atk_b.name = "AtkB"
	atk_b.behavior_name = "attack"
	atk_b.entity = attacker_b
	add_child(atk_b)
	atk_b.enter("", {"battle": stub})
	atk_b.update(0.1)
	dir_b = attacker_b.get("_ai_move_dir")
	var ang_b: float = atan2(dir_b.y, dir_b.x)
	_runner.assert_true(ang_b > 0.1, "B 应保持其方位角接近（防一字长蛇），角度: %f" % ang_b)
	_runner.assert_true(ang_b != ang_a, "两攻击者移动方向应不同（展开）")
	atk_a.queue_free()
	atk_b.queue_free()
	stub.queue_free()
