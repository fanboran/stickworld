extends Node
## 阶段 0.5 小队级战斗集成测试入口。
##
## 运行：
##   godot --headless --path stick-world res://tests/test_stage_05.tscn
##
## 退出码：0 全部通过，1 有失败
##
## 测试覆盖：
##   - GameRoot 战斗系统装配（BattleDirector 脚本 + CombatApi）
##   - 5v5 战斗启动（battle_instance 创建并激活）
##   - 单位 faction_id 分配
##   - 掩体系统扫描到 CoverMarker
##   - 战斗推进：伤亡发生、行为切换（attack/seek_cover/retreat）
##   - 战斗结束判定（一方胜利或超时）

const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptStickmanEntity := preload("res://modules/units/scripts/stickman_entity.gd")
const ScriptVillageMap := preload("res://modules/world/scripts/village_map.gd")
const ScriptBattleInstance := preload("res://modules/combat/scripts/battle_instance.gd")
const STICKMAN_SCENE: PackedScene = preload("res://modules/units/scenes/stickman_entity.tscn")

# ─────────────────────────────── 战斗单位配置 ────────────────────────────────
## 战斗单位 HP（低值加速战斗）
const BATTLE_HP: float = 40.0
## 战斗单位士气（低值便于触发溃逃）
const BATTLE_MORALE: float = 25.0
## 溃逃阈值（低于此士气溃逃）
const ROUT_THRESHOLD: float = 10.0
## 进攻方起始 X
const ATTACKER_X: float = 1500.0
## 防守方起始 X
const DEFENDER_X: float = 2500.0
## 伤亡检测超时（秒）
const CASUALTY_TIMEOUT: float = 25.0
## 行为收集额外时长（秒）
const BEHAVIOR_EXTRA_TIME: float = 5.0
## 战斗结束总超时（秒）
const BATTLE_TIMEOUT: float = 60.0

var _runner: TestRunner
var _game_root: Node
var _tests: Array = []
var _battle: Node = null
var _attackers: Array = []
var _defenders: Array = []
## 观察到的行为集合（behavior_name -> true）
var _observed_behaviors: Dictionary = {}


func _ready() -> void:
	_runner = TestRunner.new()
	_register_tests()
	_run_tests_async()


# ─────────────────────────────── 测试注册 ────────────────────────────────

func _register_tests() -> void:
	# 同步测试（战斗启动前，装配验证）
	_tests.append({"name": "装配: BattleDirector 已挂脚本", "fn": Callable(self, "_test_battle_director_scripted"), "async": false})
	_tests.append({"name": "装配: CombatApi 已装配", "fn": Callable(self, "_test_combat_api_assembled"), "async": false})

	# 异步测试（需战斗启动后）
	_tests.append({"name": "战斗: 启动 5v5 战斗", "fn": Callable(self, "_test_start_battle"), "async": true})
	_tests.append({"name": "战斗: 单位 faction 分配", "fn": Callable(self, "_test_faction_assigned"), "async": true})
	_tests.append({"name": "战斗: 掩体系统扫描到 CoverMarker", "fn": Callable(self, "_test_cover_scanned"), "async": true})
	_tests.append({"name": "战斗: 推进后有伤亡", "fn": Callable(self, "_test_casualties_occur"), "async": true})
	_tests.append({"name": "战斗: 行为切换（attack 等）", "fn": Callable(self, "_test_behavior_switch"), "async": true})
	_tests.append({"name": "战斗: 最终结束判定", "fn": Callable(self, "_test_battle_ends"), "async": true})


# ─────────────────────────────── 异步执行 ────────────────────────────────

func _run_tests_async() -> void:
	var packed := load("res://modules/world/scenes/game_root.tscn") as PackedScene
	if packed == null:
		print("[FATAL] 无法加载 game_root.tscn")
		get_tree().quit(1)
		return
	_game_root = packed.instantiate()
	_game_root.set("auto_demo_building", false)
	add_child(_game_root)
	# 等待地图加载和实体生成
	for i in 8:
		await get_tree().process_frame
	_unpossess_player()
	for i in 2:
		await get_tree().process_frame

	# 运行同步测试
	for t in _tests:
		if not t["async"]:
			_runner.add_test(t["name"], t["fn"])
	_runner.run()

	# 运行异步测试
	for t in _tests:
		if t["async"]:
			_runner.begin_test(t["name"])
			await t["fn"].call()
			_runner.end_test()
			_write_log("完成: %s | behaviors=%s" % [t["name"], str(_observed_behaviors.keys())])

	var summary := _runner.summary()
	print(summary)
	# 写入文件确保结果可读（stdout 可能被 IK 日志淹没）
	var f := FileAccess.open("f:/VSCode/game-2/stick-world/test_stage_05_result.txt", FileAccess.WRITE)
	if f != null:
		f.store_string(summary + "\n")
		f.store_string("EXIT_CODE=%d\n" % (0 if _runner.all_passed() else 1))
		f.store_string("OBSERVED_BEHAVIORS=%s\n" % str(_observed_behaviors.keys()))
		f.close()
	var exit_code: int = 0 if _runner.all_passed() else 1
	get_tree().quit(exit_code)


## 写日志到文件（stdout 可能被 IK 日志淹没）
func _write_log(msg: String) -> void:
	var f := FileAccess.open("f:/VSCode/game-2/stick-world/test_stage_05_result.txt", FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open("f:/VSCode/game-2/stick-world/test_stage_05_result.txt", FileAccess.WRITE)
	if f != null:
		f.seek_end()
		f.store_string(msg + "\n")
		f.close()


# ─────────────────────────────── 辅助 ────────────────────────────────

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


## 在战场中间放置掩体标记
func _place_cover_markers(map: Node2D) -> void:
	var positions: Array = [
		Vector2(1900, 900),
		Vector2(2000, 960),
		Vector2(2100, 900),
		Vector2(2200, 960),
	]
	for p in positions:
		var cover := Node2D.new()
		cover.add_to_group("cover_marker")
		cover.global_position = p
		map.add_child(cover)


## 追踪所有参战单位的当前行为，记录到 _observed_behaviors
func _track_behaviors() -> void:
	for e in _attackers + _defenders:
		if not is_instance_valid(e):
			continue
		var ai: Node = e.get_ai_controller() if e.has_method("get_ai_controller") else null
		if ai == null or not ai.has_method("get_current_behavior"):
			continue
		var beh: String = ai.get_current_behavior()
		if not beh.is_empty():
			_observed_behaviors[beh] = true


## 统计已死亡单位数
func _count_dead() -> int:
	var n: int = 0
	for e in _attackers + _defenders:
		if is_instance_valid(e) and e.has_method("is_dead") and e.is_dead():
			n += 1
	return n


# ─────────────────────────────── 同步测试（装配）────────────────────────────────

func _test_battle_director_scripted() -> void:
	var bd: Node = _game_root.get_node_or_null("BattleDirector")
	_runner.assert_true(bd != null, "BattleDirector 节点应存在")
	if bd != null:
		_runner.assert_true(bd.has_method("start_battle_at"), "BattleDirector 应有 start_battle_at 方法")
		_runner.assert_true(bd.has_method("has_active_battle"), "BattleDirector 应有 has_active_battle 方法")


func _test_combat_api_assembled() -> void:
	var api: Node = _game_root.get_node_or_null("CombatApi")
	_runner.assert_true(api != null, "CombatApi 应为子节点")
	if api != null:
		_runner.assert_true(api.has_method("start_battle"), "CombatApi 应有 start_battle 方法")


# ─────────────────────────────── 异步测试 ────────────────────────────────

func _test_start_battle() -> void:
	var map: Node2D = _get_current_map()
	if map == null:
		_runner.assert_true(false, "map 为空")
		return
	var spawn_y: float = map.ground_y + (map.ground_bottom - map.ground_y) * 0.5
	# 生成 5 个进攻方
	for i in 5:
		var x: float = ATTACKER_X + i * 40.0
		var e: Node = _spawn_battle_unit(map, Vector2(x, spawn_y))
		if e != null:
			_attackers.append(e)
	# 生成 5 个防守方
	for i in 5:
		var x: float = DEFENDER_X + i * 40.0
		var e: Node = _spawn_battle_unit(map, Vector2(x, spawn_y))
		if e != null:
			_defenders.append(e)
	_runner.assert_true(_attackers.size() == 5, "进攻方应有 5 人")
	_runner.assert_true(_defenders.size() == 5, "防守方应有 5 人")
	# 放置掩体（必须在 start_test_battle 之前，cover_system 在 setup 时扫描）
	_place_cover_markers(map)
	# 启动战斗
	_battle = _game_root.start_test_battle(_attackers, _defenders)
	_runner.assert_true(_battle != null, "battle_instance 应创建")
	if _battle != null:
		_runner.assert_true(_battle.is_active(), "battle_instance 应激活")
	await get_tree().process_frame


func _test_faction_assigned() -> void:
	for e in _attackers:
		if is_instance_valid(e):
			_runner.assert_equal(e.faction_id, 1, "进攻方 faction 应为 1")
	for e in _defenders:
		if is_instance_valid(e):
			_runner.assert_equal(e.faction_id, 2, "防守方 faction 应为 2")


func _test_cover_scanned() -> void:
	if _battle == null or not is_instance_valid(_battle):
		_runner.assert_true(false, "battle 为空")
		return
	var cover = _battle.get_cover()
	_runner.assert_true(cover != null, "cover_system 应存在")
	if cover != null:
		_runner.assert_true(cover.has_covers(), "应扫描到掩体")
		_runner.assert_true(cover.get_cover_points().size() >= 4, "至少应有 4 个掩体")


func _test_casualties_occur() -> void:
	if _battle == null:
		_runner.assert_true(false, "battle 为空")
		return
	var elapsed: float = 0.0
	var had_casualty: bool = false
	while elapsed < CASUALTY_TIMEOUT and _battle.is_active():
		await get_tree().process_frame
		elapsed += get_process_delta_time()
		_track_behaviors()
		if _count_dead() > 0:
			had_casualty = true
			break
	_runner.assert_true(had_casualty, "战斗应产生伤亡（%ds 内）" % int(CASUALTY_TIMEOUT))
	print("[test] 伤亡检测完成，elapsed=%.1f, dead=%d" % [elapsed, _count_dead()])


func _test_behavior_switch() -> void:
	# 继续收集行为一段时间
	var elapsed: float = 0.0
	while elapsed < BEHAVIOR_EXTRA_TIME and _battle != null and is_instance_valid(_battle) and _battle.is_active():
		await get_tree().process_frame
		elapsed += get_process_delta_time()
		_track_behaviors()
	_runner.assert_true(_observed_behaviors.has("attack"), "应观察到 attack 行为")
	print("[test] 观察到的行为: %s" % str(_observed_behaviors.keys()))


func _test_battle_ends() -> void:
	if _battle == null:
		_runner.assert_true(false, "battle 为空")
		return
	var elapsed: float = 0.0
	while elapsed < BATTLE_TIMEOUT and _battle != null and is_instance_valid(_battle) and _battle.is_active():
		await get_tree().process_frame
		elapsed += get_process_delta_time()
		_track_behaviors()
	var ended: bool = _battle == null or not is_instance_valid(_battle) or not _battle.is_active()
	_runner.assert_true(ended, "战斗应在 %ds 内结束" % int(BATTLE_TIMEOUT))
	if ended and _battle != null and is_instance_valid(_battle):
		var winner: int = _battle.get_winner()
		print("[test] 战斗结束，胜方=%d，耗时=%.1fs，进攻方伤亡=%d，防守方伤亡=%d" % [
			winner, _battle.get_duration(),
			_battle.get_casualties(1), _battle.get_casualties(2)
		])
	if not ended:
		print("[test] 战斗未结束，进攻方存活=%d，防守方存活=%d" % [
			_battle.get_alive_count(1), _battle.get_alive_count(2)
		])
