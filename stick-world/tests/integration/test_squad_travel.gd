extends Node
## 集成测试：带队出征（跨图携带编队 + 战场重建 + 遭遇战启动）。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_squad_travel.tscn -- --fresh-start
##
## 退出码：0 全部通过，1 有失败
##
## 测试覆盖：
##   - 村庄编成战斗班（preset/排长/职责）
##   - 跨图到战场：编队快照（export_squads）-> 跟随者 spawn -> 重建（restore_squads）
##   - 战场地图实体数（玩家 + 随行 + 敌方）
##   - 重建后编队完整（成员数/preset/排长）
##   - 遭遇战已启动且双方人数正确（玩家+随行 vs 敌方）
##
## 公共 setup 在 tests/helpers/combat_test_setup.gd。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const CombatTestSetup := preload("res://tests/helpers/combat_test_setup.gd")
const ScriptGameRoot := preload("res://modules/world/scripts/game_root.gd")

## 随行队伍人数（不含玩家）
const PARTY_SIZE: int = 3
## 敌方人数（spawn_battlefield_enemies 固定 4）
const ENEMY_COUNT: int = 4

var _runner: TestRunner
var _helper: CombatTestSetup
var _tests: Array = []
var _formation: Node = null
var _battle_director: Node = null


func _ready() -> void:
	_runner = TestRunner.new()
	_register_tests()
	_run_tests_async()


func _register_tests() -> void:
	_tests.append({"name": "编队: 村庄编成战斗班", "fn": Callable(self, "_test_create_party"), "async": true})
	_tests.append({"name": "跨图: 携带队伍到战场", "fn": Callable(self, "_test_travel_with_squad"), "async": true})
	_tests.append({"name": "重建: 编队信息完整恢复", "fn": Callable(self, "_test_squad_restored"), "async": true})
	_tests.append({"name": "战斗: 遭遇战双方人数正确", "fn": Callable(self, "_test_battle_started"), "async": true})


func _run_tests_async() -> void:
	_helper = CombatTestSetup.new()
	await _helper.start(self)
	_formation = _helper.formation
	_battle_director = _helper.game_root.get_battle_director_node() if _helper.game_root != null and _helper.game_root.has_method("get_battle_director_node") else null
	# 生成队伍成员并注入 FormationSystem
	_helper.spawn_test_units(PARTY_SIZE)
	for i in 1:
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


## 在村庄编成战斗班（3 人 + 排长 + 跟随）
func _test_create_party() -> void:
	if _formation == null:
		_runner.assert_true(false, "FormationSystem 为空")
		return
	var squad_id: String = _formation.create_squad(_helper.units, "先锋班", "fp_combat_squad")
	_runner.assert_true(not squad_id.is_empty(), "战斗班应创建成功")
	_runner.assert_true(_formation.assign_leader(squad_id, _helper.units[0]), "任命排长应成功")
	_runner.assert_equal(_formation.get_squad_size(squad_id), PARTY_SIZE, "战斗班应有 %d 人" % PARTY_SIZE)
	_runner.assert_true(_formation.is_combat_squad(squad_id), "战斗班应有战斗职责")
	# 开启跟随（跨图后应保留）
	_runner.assert_true(_formation.set_squad_follow(squad_id, true), "开启跟随应成功")


## 跨图到战场：携带队伍
func _test_travel_with_squad() -> void:
	if _helper.game_root == null:
		_runner.assert_true(false, "GameRoot 为空")
		return
	var sl: Node = _helper.game_root.scene_loader
	if sl == null or not sl.has_method("travel_to_map"):
		_runner.assert_true(false, "SceneLoader 为空")
		return
	sl.travel_to_map(ScriptGameRoot.BATTLEFIELD_MAP_ID, WorldAPI.TravelMode.WALK, WorldAPI.EntrySide.LEFT)
	# 等待新地图加载与跟随者 spawn（map_loaded 同步执行，多等几帧稳妥）
	for i in 4:
		await get_tree().process_frame
	# 战场实体数 = 玩家(1) + 随行(PARTY_SIZE) + 敌方(ENEMY_COUNT)
	var map: Node2D = _helper.game_root.scene_loader.get_current_map()
	_runner.assert_true(map != null, "战场地图应已加载")
	if map == null or not map.has_method("get_entities"):
		return
	var entities: Array = map.get_entities()
	var alive: int = 0
	for e in entities:
		if is_instance_valid(e) and e is CharacterBody2D and not (e.has_method("is_dead") and e.is_dead()):
			alive += 1
	_runner.assert_equal(alive, 1 + PARTY_SIZE + ENEMY_COUNT, "战场实体数应为 %d（玩家+%d 随行+%d 敌）" % [1 + PARTY_SIZE + ENEMY_COUNT, PARTY_SIZE, ENEMY_COUNT])


## 重建后编队信息完整恢复
func _test_squad_restored() -> void:
	if _formation == null:
		_runner.assert_true(false, "FormationSystem 为空")
		return
	var squads: Array = _formation.get_all_squads()
	_runner.assert_equal(squads.size(), 1, "战场应恢复 1 个编队")
	if squads.is_empty():
		return
	var squad_id: String = squads[0]
	_runner.assert_equal(_formation.get_squad_size(squad_id), PARTY_SIZE, "恢复后编队应有 %d 人" % PARTY_SIZE)
	_runner.assert_equal(_formation.get_squad_preset(squad_id), "fp_combat_squad", "preset 应恢复为战斗班")
	_runner.assert_true(_formation.is_combat_squad(squad_id), "战斗职责应恢复")
	# 排长恢复：leader 应在地图上且是编队成员
	var leader: Node = _formation.get_squad_leader(squad_id)
	_runner.assert_true(leader != null and is_instance_valid(leader), "排长应恢复")
	if leader != null and is_instance_valid(leader):
		_runner.assert_true(_formation.is_in_squad(leader), "排长应在编队中")
	# 跟随标志恢复（跨图传送后跟随不丢）
	_runner.assert_true(_formation.is_squad_following(squad_id), "跟随玩家标志应跨图保留")
	# 成员角色恢复
	for u in _formation.get_squad_units(squad_id):
		if is_instance_valid(u):
			_runner.assert_equal(u.get_role(), "fighter", "成员角色应恢复为 fighter")


## 遭遇战已启动，双方人数正确
func _test_battle_started() -> void:
	if _battle_director == null or not _battle_director.has_method("has_active_battle"):
		_runner.assert_true(false, "BattleDirector 为空")
		return
	_runner.assert_true(_battle_director.has_active_battle(), "战场应有活跃战斗")
	if not _battle_director.has_active_battle() or not _battle_director.has_method("get_active_battles"):
		return
	var battles: Array = _battle_director.get_active_battles()
	_runner.assert_true(not battles.is_empty(), "应有战斗实例")
	if battles.is_empty():
		return
	var bi: Node = battles[0]
	# 进攻方 = 玩家 + 随行
	var attacker_alive: int = bi.get_alive_count(1) if bi.has_method("get_alive_count") else -1
	var defender_alive: int = bi.get_alive_count(2) if bi.has_method("get_alive_count") else -1
	_runner.assert_equal(attacker_alive, 1 + PARTY_SIZE, "进攻方人数应为 %d（玩家+随行）" % (1 + PARTY_SIZE))
	_runner.assert_equal(defender_alive, ENEMY_COUNT, "防守方人数应为 %d" % ENEMY_COUNT)
