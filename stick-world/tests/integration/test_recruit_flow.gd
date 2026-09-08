extends Node
## 集成测试：招兵与人口（游戏循环深化批次 1）——兵源闭环锁死。
##
## 验收门（交接档批次 1）：
##   1. 招兵成功：兵营旁 recruit → 空闲村民变身士兵（META_SOLDIER + 退出劳工池
##      + 换剑）+ 资源扣减（-30木 -10石）；
##   2. 无空闲村民拒招（reason=no_villager）；
##   3. 人口再生：pop_growth_interval 加速后村民自动增长；
##   4. 人口上限：pop_cap 内再生封顶；
##   5. 资源不足拒招（reason=insufficient_resources）；
##   6. 士兵出征口径：无守军 meta、存活——ConquestManager 收集玩家侧可收录。
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_recruit_flow.tscn
## 退出码：0 全部通过，1 有失败

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
@warning_ignore("shadowed_global_identifier")
const TestHelpers := preload("res://tests/core/test_helpers.gd")

## 招兵成本（与 RecruitManager.RECRUIT_COST 对齐）
const COST_WOOD := 30.0
const COST_STONE := 10.0

var _runner: TestRunner
var _game_root: Node = null
var _org_api: Node = null
var _recruit: Node = null
var _resources: Node = null
var _construction: Node = null


func _ready() -> void:
	SaveManager.set_auto_save_enabled(false)
	_runner = TestRunner.new()
	_runner.add_test("兵营招兵：村民变身+资源扣减", Callable(self, "_test_recruit_success"), true)
	_runner.add_test("无空闲村民拒招", Callable(self, "_test_no_villager"), true)
	_runner.add_test("人口再生：间隔加速后村民增长", Callable(self, "_test_pop_growth"), true)
	_runner.add_test("人口上限封顶", Callable(self, "_test_pop_cap"), true)
	_runner.add_test("资源不足拒招+士兵出征口径", Callable(self, "_test_insufficient_and_soldier"), true)
	_run_tests()


func _run_tests() -> void:
	_game_root = (load("res://modules/world/scenes/game_root.tscn") as PackedScene).instantiate()
	add_child(_game_root)
	# boot：地图就绪 + deferred 装配（construction api 初始化）完成
	var ok: bool = await TestHelpers.await_condition(func():
		var map: Node2D = _game_root.get_current_map() if _game_root.has_method("get_current_map") else null
		return map != null and _game_root.get_node_or_null("RecruitManager") != null \
				and _game_root.get_node_or_null("DemoQuest") != null, 20.0, "boot")
	_runner.assert_true(ok, "GameRoot 应在 20s 内装配完成（地图+RecruitManager）")
	if not ok:
		print(_runner.summary())
		get_tree().quit(1)
		return
	_org_api = _game_root.get_organization_api()
	_recruit = _game_root.get_recruit_manager()
	_resources = _game_root.get_resources_api()
	_construction = _game_root.get_construction_api()
	_runner.assert_not_null(_org_api, "OrganizationApi 就绪")
	_runner.assert_not_null(_recruit, "RecruitManager 就绪")
	await _runner.run_async()
	print(_runner.summary())
	WorldState.territories = {}
	get_tree().quit(0 if _runner.all_passed() else 1)


# ─────────────────────────────── 测试用例 ────────────────────────────────

## 用例 1「兵营招兵」：手动落一座 OPERATIONAL 兵营 → 连招 2 名（开局村民 2）
## → 村民 0、士兵 2、资源扣减正确、hint 文案非空
func _test_recruit_success() -> void:
	var built: Dictionary = _construction.spawn_operational_building("barracks", 40, 16)
	_runner.assert_true(bool(built.get("ok", false)), "兵营应可直建（spawn_operational_building）")
	_runner.assert_not_null(_org_api.find_nearest_barracks(Vector2(1280, 810)), "兵营应可被探测到")
	var hint: String = _org_api.get_recruit_hint()
	_runner.assert_true(not hint.is_empty(), "招兵 hint 非空（实得 '%s'）" % hint)
	var wood0: float = _resources.get_stock("res_wood")
	var stone0: float = _resources.get_stock("res_stone")
	var v0: int = _villager_count()
	var r1: Dictionary = _org_api.recruit()
	_runner.assert_true(bool(r1.get("ok", false)), "第一次招兵应成功（%s）" % str(r1))
	var r2: Dictionary = _org_api.recruit()
	_runner.assert_true(bool(r2.get("ok", false)), "第二次招兵应成功（%s）" % str(r2))
	_runner.assert_equal(_villager_count(), v0 - 2, "空闲村民应 -2（%d → %d）" % [v0, v0 - 2])
	_runner.assert_equal(_soldier_count(), 2, "士兵应 +2")
	_runner.assert_approx(_resources.get_stock("res_wood") - wood0, -COST_WOOD * 2.0, 0.001, "木 -60")
	_runner.assert_approx(_resources.get_stock("res_stone") - stone0, -COST_STONE * 2.0, 0.001, "石 -20")


## 用例 2「无空闲村民拒招」
func _test_no_villager() -> void:
	var r: Dictionary = _org_api.recruit()
	_runner.assert_false(bool(r.get("ok", true)), "无村民应拒招")
	_runner.assert_equal(String(r.get("reason", "")), "no_villager", "原因 = no_villager")


## 用例 3「人口再生」：注入短间隔 → 村民自动增长（TimeManager 保持 X1）
func _test_pop_growth() -> void:
	TimeManager.set_speed(TimeManager.Speed.X1)
	_recruit.pop_growth_interval = 0.1
	var v0: int = _villager_count()
	await get_tree().create_timer(0.8).timeout
	_runner.assert_true(_villager_count() > v0,
			"再生应使村民增长（%d → %d）" % [v0, _villager_count()])


## 用例 4「人口上限封顶」：pop_cap 注入为当前值+1 → 再生到 cap 停
func _test_pop_cap() -> void:
	var v_now: int = _villager_count()
	_recruit.pop_cap = v_now + 1
	await get_tree().create_timer(0.6).timeout
	_runner.assert_true(_villager_count() <= _recruit.pop_cap,
			"村民不应超上限（%d > cap %d？）" % [_villager_count(), _recruit.pop_cap])
	# 稳定性：继续等待不再增长
	var v_capped: int = _villager_count()
	await get_tree().create_timer(0.4).timeout
	_runner.assert_equal(_villager_count(), v_capped, "到顶后村民数应稳定")


## 用例 5「资源不足拒招 + 士兵出征口径」：清空木材 → 拒招；
## 士兵无守军 meta、存活（ConquestManager._collect_player_units 口径可收录）
func _test_insufficient_and_soldier() -> void:
	var wood_stock: float = _resources.get_stock("res_wood")
	_resources.consume("res_wood", wood_stock, "test_region", "测试清库")
	var r: Dictionary = _org_api.recruit()
	_runner.assert_false(bool(r.get("ok", true)), "资源不足应拒招")
	_runner.assert_equal(String(r.get("reason", "")), "insufficient_resources", "原因 = insufficient_resources")
	# 士兵出征口径（照 ConquestManager._collect_player_units 过滤条件）
	var map: Node2D = _game_root.get_current_map()
	var host: Node = map.get_node_or_null("EntityHost")
	_runner.assert_not_null(host, "EntityHost 存在")
	if host == null:
		return
	var soldiers: int = 0
	for u in host.get_children():
		if not (u is Node2D) or not is_instance_valid(u):
			continue
		if not bool(u.get_meta("recruit_soldier", false)):
			continue
		soldiers += 1
		_runner.assert_false(bool(u.get_meta("garrison_unit", false)), "士兵不应带守军 meta")
		_runner.assert_true(not u.is_dead(), "士兵应存活")
		_runner.assert_false(u.is_possessed(), "士兵不应是附身态")
	_runner.assert_true(soldiers >= 2, "应有 >= 2 名可出征士兵（实得 %d）" % soldiers)


# ─────────────────────────────── 工具 ────────────────────────────────

## 村民计数（照 RecruitManager._scan_villagers 口径：非士兵/非守军/非附身/存活）
func _villager_count() -> int:
	var n := 0
	for u in _host_units():
		if bool(u.get_meta("recruit_soldier", false)):
			continue
		if bool(u.get_meta("garrison_unit", false)):
			continue
		if u.is_possessed():
			continue
		if u.is_dead():
			continue
		n += 1
	return n


## 士兵计数
func _soldier_count() -> int:
	var n := 0
	for u in _host_units():
		if bool(u.get_meta("recruit_soldier", false)):
			n += 1
	return n


## EntityHost 全部实体（防御空图）
func _host_units() -> Array:
	var result: Array = []
	var map: Node2D = _game_root.get_current_map() if _game_root.has_method("get_current_map") else null
	var host: Node = map.get_node_or_null("EntityHost") if map != null else null
	if host == null:
		return result
	for u in host.get_children():
		if u is Node2D and is_instance_valid(u) and u.has_method("is_dead"):
			result.append(u)
	return result
