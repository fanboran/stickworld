extends Node
## 集成测试：战斗侧 C2/C3——victory 玩家阵营语义 + 敌将撤仗（出征与领地循环批次 2）。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_battle_retreat.tscn -- --fresh-start
##
## 退出码：0 全部通过，1 有失败
##
## 测试覆盖（架构文档 §四 验收门）：
##   1. C2 默认语义回归：player_faction 未传（=攻方），攻方胜 → victory=true
##   2. C2 守方语义：player_faction=2，守方胜 → victory=true（攻城战场景语义）
##   3. C3 撤仗：守军 TeamAi 注入撤退阈值，伤亡率超限 → ROUT → 全军撤离边缘
##      departed → battle_ended(victory=true)（据点攻陷）
##   4. C3 零回归：enable_team_ai 不注入撤退阈值 → 不撤仗，守军全灭判定照常

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptStickmanEntity := preload("res://modules/units/scripts/stickman_entity.gd")
const STICKMAN_SCENE: PackedScene = preload("res://modules/units/scenes/stickman_entity.tscn")

## 战斗单位 HP（低值加速战斗收敛）
const BATTLE_HP: float = 40.0
## 战斗单位士气（低值便于触发溃逃）
const BATTLE_MORALE: float = 25.0
## 溃逃阈值（低于此士气溃逃）
const ROUT_THRESHOLD: float = 10.0
## 守军撤仗阈值：伤亡率 0.3（3 人守军死 1 即 0.33 > 0.3 触发）
const RETREAT_CASUALTY_RATE: float = 0.3
## 单场战斗总超时（秒）
const BATTLE_TIMEOUT: float = 60.0

var _runner: TestRunner
var _game_root: Node
var _formation: Node = null
## battle_ended 捕获：[victory]
var _ended_victory: Array = []
## team_ai_stance_changed 捕获：faction 2 是否到过 ROUT(3)
var _saw_rout: bool = false


func _ready() -> void:
	_runner = TestRunner.new()
	_run_tests_async()


func _run_tests_async() -> void:
	var packed := load("res://modules/world/scenes/game_root.tscn") as PackedScene
	if packed == null:
		print("[FATAL] 无法加载 game_root.tscn")
		get_tree().quit(1)
		return
	_game_root = packed.instantiate()
	add_child(_game_root)
	for i in 8:
		await get_tree().process_frame
	_unpossess_player()
	_formation = _game_root.get_node_or_null("FormationSystem")
	if EventBus != null:
		if EventBus.has_signal("battle_ended"):
			EventBus.battle_ended.connect(_on_battle_ended)
		if EventBus.has_signal("team_ai_stance_changed"):
			EventBus.team_ai_stance_changed.connect(_on_stance_changed)

	# 场景 1：C2 默认语义（攻方视角胜 → victory=true）
	_runner.begin_test("C2 默认: 攻方胜 → victory=true")
	var u1: Dictionary = await _setup_battle(5, 2, 1, false)
	await _scenario_default_attacker_win(u1)
	_runner.end_test()

	# 场景 2：C2 守方语义（player_faction=2，守方胜 → victory=true）
	_runner.begin_test("C2 守方: player_faction=2 守方胜 → victory=true")
	var u2: Dictionary = await _setup_battle(1, 4, 2, false)
	await _scenario_defender_win_player_side(u2)
	_runner.end_test()

	# 场景 3：C3 撤仗（伤亡率超限 → ROUT 撤离 → 玩家胜）
	_runner.begin_test("C3 撤仗: 伤亡率超限 → 敌军撤离 → victory=true")
	var u3: Dictionary = await _setup_battle(5, 3, 1, true)
	await _scenario_retreat_on_casualty(u3)
	_runner.end_test()

	# 场景 4：C3 零回归（无撤退阈值 → 全灭判定照常）
	_runner.begin_test("C3 零回归: 无撤退阈值 → 全灭判定 → victory=true")
	var u4: Dictionary = await _setup_battle(5, 2, 1, false, true)
	await _scenario_no_retreat_annihilation(u4)
	_runner.end_test()

	var summary := _runner.summary()
	print(summary)
	var exit_code: int = 0 if _runner.all_passed() else 1
	get_tree().quit(exit_code)


# ─────────────────────────────── 事件捕获 ────────────────────────────────

func _on_battle_ended(_battle_id: String, victory: bool) -> void:
	_ended_victory.append(victory)


func _on_stance_changed(_battle_id: String, faction: int, _from: int, to: int, _reason: String) -> void:
	if faction == 2 and to == 3:
		_saw_rout = true


# ─────────────────────────────── 场景 ────────────────────────────────

## 场景 1：攻强守弱 5v2，player_faction 默认 1（攻方）。攻方全歼守军 → victory=true。
func _scenario_default_attacker_win(units: Dictionary) -> void:
	if not units.has("battle"):
		_runner.assert_true(false, "战斗未启动")
		return
	var defenders: Array = units["defenders"]
	var ok: bool = await _await_battle_end()
	_runner.assert_true(ok, "战斗应在 %.0fs 内结束" % BATTLE_TIMEOUT)
	_runner.assert_true(_pop_victory() == true, "默认语义（攻方=玩家）：攻方胜 → victory=true")
	_runner.assert_true(_all_dead(defenders), "守军应全灭（无撤仗配置走全灭判定）")
	await _clear_units(units)


## 场景 2：攻弱守强 1v4，player_faction=2（守方=玩家）。守方全歼攻方 → victory=true。
func _scenario_defender_win_player_side(units: Dictionary) -> void:
	if not units.has("battle"):
		_runner.assert_true(false, "战斗未启动")
		return
	var attackers: Array = units["attackers"]
	var ok: bool = await _await_battle_end()
	_runner.assert_true(ok, "战斗应在 %.0fs 内结束" % BATTLE_TIMEOUT)
	_runner.assert_true(_pop_victory() == true, "守方语义（player_faction=2）：守方胜 → victory=true")
	_runner.assert_true(_all_dead(attackers), "攻方应全灭")
	await _clear_units(units)


## 场景 3：5v3 守军注入撤仗阈值（伤亡率 0.3）+ 守军编战斗小队（TeamAi 号令通道）。
## 守军伤亡 1/3 → ROUT → RETREAT(evacuate) 撤至右缘 departed → 攻方胜（据点攻陷）。
func _scenario_retreat_on_casualty(units: Dictionary) -> void:
	if not units.has("battle"):
		_runner.assert_true(false, "战斗未启动")
		return
	var defenders: Array = units["defenders"]
	var ok: bool = await _await_battle_end()
	_runner.assert_true(ok, "战斗应在 %.0fs 内结束" % BATTLE_TIMEOUT)
	_runner.assert_true(_saw_rout, "守军 TeamAi 应切换到 ROUT 姿态（stance=3）")
	_runner.assert_true(_pop_victory() == true, "守军撤离/全灭 → 玩家（攻方）胜 → victory=true")
	# 撤仗路径验证：至少 1 名守军以 departed 离场（非死亡）
	var departed_count: int = 0
	for e in defenders:
		if is_instance_valid(e) and not (e.has_method("is_dead") and e.is_dead()) \
				and "departed" in e and bool(e.get("departed")):
			departed_count += 1
	_runner.assert_true(departed_count > 0, "应有守军以 departed 离场（战役撤离路径，非全灭）")
	print("[test] 撤仗场景：departed=%d/%d, stance_rout=%s" % [departed_count, defenders.size(), str(_saw_rout)])
	await _clear_units(units)


## 场景 4：enable_team_ai(2) 不注入撤退阈值（默认全负）→ 撤仗评估关闭，
## 守军打光走全灭判定（注册制零回归闸门）。
func _scenario_no_retreat_annihilation(units: Dictionary) -> void:
	if not units.has("battle"):
		_runner.assert_true(false, "战斗未启动")
		return
	var defenders: Array = units["defenders"]
	var ok: bool = await _await_battle_end()
	_runner.assert_true(ok, "战斗应在 %.0fs 内结束" % BATTLE_TIMEOUT)
	_runner.assert_true(not _saw_rout, "无撤退阈值时 TeamAi 不应切 ROUT")
	_runner.assert_true(_pop_victory() == true, "守军全灭 → 玩家胜 → victory=true")
	_runner.assert_true(_all_dead(defenders), "守军应全灭（全灭判定照常）")
	await _clear_units(units)


# ─────────────────────────────── 基建 ────────────────────────────────

## 生成双方、（按需）守军编队、启动战斗并（按需）启用守军 TeamAi。
## with_retreat: 注入撤仗阈值（场景 3）；team_ai_no_retreat: 启用 TeamAi 但不注入阈值（场景 4）。
## 返回 {"battle": Node, "attackers": Array, "defenders": Array}
func _setup_battle(n_attackers: int, n_defenders: int, player_faction: int,
		with_retreat: bool, team_ai_no_retreat: bool = false) -> Dictionary:
	_ended_victory.clear()
	_saw_rout = false
	var map: Node2D = _get_current_map()
	if map == null:
		_runner.assert_true(false, "map 为空")
		return {}
	var mr: float = float(map.get("map_right")) if "map_right" in map else 8192.0
	var spawn_y: float = map.ground_y + (map.ground_bottom - map.ground_y) * 0.5
	# 守军靠右缘布阵（撤离距离短，加速场景收敛）；攻方贴守方左侧快速接敌
	var attackers: Array = []
	for i in n_attackers:
		var e: Node = _spawn_battle_unit(map, Vector2(mr - 1100.0 + i * 40.0, spawn_y))
		if e != null:
			attackers.append(e)
	var defenders: Array = []
	for i in n_defenders:
		var e: Node = _spawn_battle_unit(map, Vector2(mr - 500.0 + i * 40.0, spawn_y))
		if e != null:
			defenders.append(e)
	await get_tree().process_frame
	await get_tree().process_frame
	# 撤仗场景的守军需要编战斗小队（TeamAi 号令按小队下发，散兵收不到号令）
	if with_retreat and _formation != null and _formation.has_method("create_squad"):
		var sid: String = _formation.create_squad(defenders, "守军测试队")
		if _formation.has_method("is_combat_squad"):
			_runner.assert_true(_formation.is_combat_squad(sid), "守军小队应为战斗职责")
	var battle: Node = _game_root.start_test_battle(attackers, defenders, player_faction)
	if battle == null:
		_runner.assert_true(false, "battle 创建失败")
		return {}
	# TeamAi 启用（场景 3 带撤仗阈值；场景 4 裸启用验证默认不撤）
	if (with_retreat or team_ai_no_retreat) and battle.has_method("enable_team_ai"):
		if with_retreat:
			battle.enable_team_ai(2, {"retreat_casualty_rate": RETREAT_CASUALTY_RATE})
		else:
			battle.enable_team_ai(2)
	# 开战自动暂停（玩家观察窗口），测试模拟玩家立即恢复
	if TimeManager != null and TimeManager.is_paused():
		TimeManager.set_speed(TimeManager.Speed.X1)
	await get_tree().process_frame
	return {"battle": battle, "attackers": attackers, "defenders": defenders}


## 等待战斗结束（battle_ended 事件到达）。返回是否在超时内结束。
func _await_battle_end() -> bool:
	var elapsed: float = 0.0
	while elapsed < BATTLE_TIMEOUT:
		await get_tree().create_timer(0.25).timeout
		elapsed += 0.25
		if not _ended_victory.is_empty():
			return true
	return not _ended_victory.is_empty()


## 场景清场：spawn 的单位全部释放（防残留单位污染下一场景的目标选择/战斗判定）
func _clear_units(units: Dictionary) -> void:
	for key in ["attackers", "defenders"]:
		for e in units.get(key, []):
			if e != null and is_instance_valid(e):
				e.queue_free()
	for i in 3:
		await get_tree().process_frame


## 取走捕获的 victory（FIFO；一场一报）
func _pop_victory() -> bool:
	if _ended_victory.is_empty():
		return false
	return bool(_ended_victory.pop_front())


func _all_dead(units: Array) -> bool:
	for e in units:
		if is_instance_valid(e):
			if not (e.has_method("is_dead") and e.is_dead()) \
					and not ("departed" in e and bool(e.get("departed"))):
				return false
	return true


func _get_current_map() -> Node2D:
	if _game_root == null:
		return null
	if _game_root.has_method("get_current_map"):
		return _game_root.get_current_map()
	return null


func _unpossess_player() -> void:
	var map := _get_current_map()
	if map == null:
		return
	for e in map.get_entities():
		if e is ScriptStickmanEntity and e.has_method("is_possessed") and e.is_possessed():
			e.set_possessed(false)


## 生成一个战斗单位，设置低 HP/士气加速战斗
func _spawn_battle_unit(map: Node2D, pos: Vector2) -> Node:
	var e: Node2D = map.spawn_entity(STICKMAN_SCENE, pos)
	if e == null:
		return null
	# 修正 Y：让脚部对齐
	if e.get("foot_offset") != null:
		e.global_position.y = pos.y - e.foot_offset
	# 取消附身（AI 接管）
	if e.has_method("set_possessed"):
		e.set_possessed(false)
	# 设置低 HP/士气加速战斗
	if e.has_method("get_health"):
		var h: Node = e.get_health()
		if h != null:
			h.max_hp = BATTLE_HP
			h.hp = BATTLE_HP
			h.max_morale = BATTLE_MORALE
			h.morale = BATTLE_MORALE
			h.rout_threshold = ROUT_THRESHOLD
	return e
