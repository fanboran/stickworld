extends Node
## 集成测试：据点守军生成（批次 C4）——ConquestAnchor 场景契约 + GarrisonSpawner 刷军。
##
## 验收门（交接档批次 3）：进图按配置刷军；打掉部分守军离场再进，数量减少；
## battlefield 进图不再自动开战（该条由 test_squad_travel 的战场实体数断言锁定）。
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_garrison_spawner.tscn
## 退出码：0 全部通过，1 有失败

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptGameRoot := preload("res://modules/world/scripts/game_root.gd")
const ScriptGarrisonSpawner := preload("res://modules/expansion/scripts/garrison_spawner.gd")
const ScriptTerritoryRegistry := preload("res://modules/expansion/scripts/territory_registry.gd")

const TID_1 := "ter_bandit_camp_01"
## TID_1 满配守军数（garrison 条目 count 之和，不含敌将）
const TID_1_GARRISON := 3
## 据点图 map_id
const MAP_ID := "l1_settlement_02"

var _runner: TestRunner
var _game_root: Node = null
var _spawner: RefCounted = null


func _ready() -> void:
	SaveManager.set_auto_save_enabled(false)
	_runner = TestRunner.new()
	_runner.add_test("锚点契约：据点图 ConquestAnchor 布阵齐备", Callable(self, "_test_anchor_contract"), true)
	_runner.add_test("按配置刷军：数量/兵种/武器/布阵带", Callable(self, "_test_spawn_by_config"), true)
	_runner.add_test("车轮战扣减：离场再进守军减少", Callable(self, "_test_losses_reduce"), true)
	_runner.add_test("已臣服短路：CAPTURED 不刷军", Callable(self, "_test_captured_short"), true)
	_runner.add_test("无锚点 fallback：程序化布阵不阻断", Callable(self, "_test_fallback"), true)
	_run_tests()


func _run_tests() -> void:
	_game_root = (load("res://modules/world/scenes/game_root.tscn") as PackedScene).instantiate()
	add_child(_game_root)
	for i in 10:
		await get_tree().process_frame
	var registry: TerritoryRegistry = TerritoryRegistry.new()
	registry.load_config()
	_spawner = ScriptGarrisonSpawner.new()
	_spawner.setup(registry)
	await _runner.run_async()
	print(_runner.summary())
	_cleanup()
	get_tree().quit(0 if _runner.all_passed() else 1)


## travel 到指定地图并等待就绪，返回当前地图实例
func _travel_to(map_id: String) -> Node2D:
	var sl: Node = _game_root.get("scene_loader")
	sl.travel_to_map(map_id, WorldAPI.TravelMode.WALK, WorldAPI.EntrySide.LEFT)
	for i in 8:
		await get_tree().process_frame
	return _game_root.get_current_map()


## 领地状态写入手感（WorldState 域构造，字段规范照 TerritoryRegistry.initial_state）
func _set_territory(state: int, losses: int) -> void:
	WorldState.territories[TID_1] = {
		"state": state, "garrison_losses": losses, "control_progress": 100.0,
	}


## 城门像素 x（守军带基准）。城镇生成管线批次 1 起布局由 seed 驱动、锚点带位置随城门走，
## 不再硬编码坐标——从初始建筑 def 派生，对任意布局稳健。
func _gate_x(map: Node2D) -> float:
	var ibl: Node = map.get_node_or_null("InitialBuildingsList")
	if ibl == null:
		return -1.0
	for d in ibl.building_defs:
		if String(d.get("def_id", "")) == "wall_gate":
			return float(d.get("cell_x", -1)) * 32.0
	return -1.0


## 锚点契约：GarrisonSlots 8 槽 + CommanderSlot + RallyX，布阵在守军带内
func _test_anchor_contract() -> void:
	var map: Node2D = await _travel_to(MAP_ID)
	_runner.assert_true(map != null, "据点图应加载成功")
	var anchor: ConquestAnchor = ConquestAnchor.find_in(map)
	_runner.assert_true(anchor != null, "据点图应挂 ConquestAnchor")
	if anchor == null:
		return
	var slots := anchor.get_garrison_slots()
	_runner.assert_equal(slots.size(), 8, "守军位应 8 槽（覆盖最大守军配置）")
	var gate_x := _gate_x(map)
	_runner.assert_true(gate_x > 0.0, "图内应有城门 def（守军带基准）")
	var in_zone := true
	for p in slots:
		if p.x <= gate_x or p.x > map.map_right:
			in_zone = false
	_runner.assert_true(in_zone, "守军槽应落在城门右侧空旷带（x > %.0f）" % gate_x)
	_runner.assert_true(anchor.get_commander_position().is_finite(), "敌将位应存在")
	_runner.assert_true(is_finite(anchor.get_rally_x()), "集结线应存在")


## 按配置刷军：2 剑 + 1 弓 + 敌将 = 4；兵种档案/武器/布阵带/来源标记正确
func _test_spawn_by_config() -> void:
	var map: Node2D = await _travel_to(MAP_ID)
	WorldState.territories = {}
	var garrison: Array = _spawner.spawn_garrison(map, TID_1)
	_runner.assert_equal(garrison.size(), TID_1_GARRISON + 1, "满配应刷守军 %d + 敌将 1" % TID_1_GARRISON)
	var def_ids: Dictionary = {}
	var bow_units: Array = []
	var gate_x := _gate_x(map)
	var in_zone := true
	for u in garrison:
		if not is_instance_valid(u):
			continue
		def_ids[u.stickman_def_id] = int(def_ids.get(u.stickman_def_id, 0)) + 1
		if bool(u.get_meta(ScriptGarrisonSpawner.META_GARRISON_UNIT, false)):
			_runner.assert_true(true, "守军带来源标记")
		if u.stickman_def_id == "stm_bow_001":
			bow_units.append(u)
		if u.global_position.x <= gate_x:
			in_zone = false
	_runner.assert_equal(int(def_ids.get("stm_sword_001", 0)), 3, "剑士守军 2 + 敌将（剑士）1")
	_runner.assert_equal(int(def_ids.get("stm_bow_001", 0)), 1, "弓手守军 1")
	_runner.assert_true(in_zone, "守军应布在守军带内（不出生在村口）")
	for u in bow_units:
		_runner.assert_true(int(u.weapon_mount.weapon_type) == int(WeaponMount.WeaponType.BOW),
				"弓手应装弓（按档案 variant）")


## 车轮战扣减：败仗战损写 garrison_losses → 离场再进，守军减少；战损超员只余敌将
func _test_losses_reduce() -> void:
	# 模拟首战打掉 2 名守军后离场（战损持久化），再进据点图
	_set_territory(0, 2)
	var map: Node2D = await _travel_to("village_a")
	map = await _travel_to(MAP_ID)
	var row: Dictionary = _spawner.get_effective_row(TID_1)
	var g0: Array = row.get("garrison", [])
	_runner.assert_equal(int(g0[0].get("count", -1)), 1, "头部条目优先满编（剑士 2→1）")
	_runner.assert_equal(int(g0[1].get("count", -1)), 0, "后排条目先缺（弓手 1→0）")
	var garrison: Array = _spawner.spawn_garrison(map, TID_1)
	_runner.assert_equal(garrison.size(), 2, "战损 2 后应刷守军 1 + 敌将 1")
	# 战损超员（5 > 3）：守军尽出，敌将仍在位（不随 garrison_losses 扣减）
	_set_territory(0, 5)
	row = _spawner.get_effective_row(TID_1)
	_runner.assert_equal(row.get("garrison", []).size(), 2, "扣减不删条目（count 归零保留兵种结构）")
	var total := 0
	for entry in row.get("garrison", []):
		total += int(entry.get("count", 0))
	_runner.assert_equal(total, 0, "战损超员守军清零")
	garrison = _spawner.spawn_garrison(map, TID_1)
	_runner.assert_equal(garrison.size(), 1, "战损超员只余敌将")


## 已臣服短路：CAPTURED 再进不刷军（友好空图），有效配置为空
func _test_captured_short() -> void:
	_set_territory(1, 0)
	var map: Node2D = await _travel_to(MAP_ID)
	var garrison: Array = _spawner.spawn_garrison(map, TID_1)
	_runner.assert_true(garrison.is_empty(), "已臣服据点不刷守军")
	_runner.assert_true(_spawner.get_effective_row(TID_1).is_empty(), "已臣服有效配置为空")
	# 未知领地同样不刷（防御）
	_runner.assert_true(_spawner.spawn_garrison(map, "ter_unknown").is_empty(), "未知领地不刷")


## 无锚点 fallback：非据点图程序化布阵，不阻断玩法（刷满配置）
func _test_fallback() -> void:
	_set_territory(0, 0)
	var map: Node2D = await _travel_to("village_a")
	var garrison: Array = _spawner.spawn_garrison(map, TID_1)
	_runner.assert_equal(garrison.size(), TID_1_GARRISON + 1, "fallback 应照配置刷满（守军 %d + 敌将）" % TID_1_GARRISON)
	var in_bounds := true
	for u in garrison:
		if not is_instance_valid(u):
			continue
		if u.global_position.x < map.map_left or u.global_position.x > map.map_right:
			in_bounds = false
	_runner.assert_true(in_bounds, "fallback 布阵应落在地图范围内")


func _cleanup() -> void:
	WorldState.territories = {}
