extends Node
## 集成测试：小镇生活采集经济闭环（批次 2）——三职业村民无人干预自主劳作，
## res_wood / res_metal_ore / res_iron_ingot 库存增长。
##
## 验收门（交接档批次 2）：
##   1. 村庄加载后，铁匠（真实 NPC index0）走到占位工位打铁：consume 矿 produce 锭；
##   2. 伐木工（真实 NPC index1）寻树砍木入库；
##   3. 补 spawn 矿工（轮转 index2，照 snapshot_professions 先例）寻矿挖矿入库；
##   4. 无人干预等待后三类库存均增长，且至少一名村民处于 harvest 行为。
##
## 稳定性设计：树/矿摆在 NPC 出生点旁（净空带内无天然资源点，寻位必命中摆点）；
## 铁匠原料预置 300 矿（矿工供给速率 4/s > 铁匠消耗 2.5/s，净增恒正）。
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_town_life_harvest.tscn -- --fresh-start
## 退出码：0 全部通过，1 有失败

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")
const ScriptResourceNode := preload("res://modules/world/scripts/map/resource_node.gd")

## 等待节奏与预算（真实秒；产出拍 4~5s，走路 <10s，40s 内应全部达标）
const POLL_INTERVAL := 0.5
const GROW_TIMEOUT := 90.0
## 库存增长阈值（每职业至少 2 拍产出量，防单拍偶然）
const THRESH_WOOD := 40.0
const THRESH_ORE := 20.0
const THRESH_INGOT := 10.0
## 铁匠原料预置量
const ORE_SEED_STOCK := 300.0
## 摆点 X（村民出生区 1050/1250 之右，净空带内，天然资源点必在更远处）
const TREE_X := 1500.0
const ORE_X := 1700.0

var _runner: TestRunner
var _game_root: Node = null


func _ready() -> void:
	SaveManager.set_auto_save_enabled(false)
	_runner = TestRunner.new()
	_runner.add_test("采集经济闭环: 三职业库存增长 + harvest 行为", Callable(self, "_test_harvest_economy"), true)
	await _setup_world()
	await _runner.run_async()
	print(_runner.summary())
	get_tree().quit(0 if _runner.all_passed() else 1)


## 世界搭建：村庄加载 + 补矿工 + 摆树/矿 + 预置铁匠原料
func _setup_world() -> void:
	_game_root = GameRootScene.instantiate()
	add_child(_game_root)
	for i in 10:
		await get_tree().process_frame


func _test_harvest_economy() -> void:
	var map: Node2D = _game_root.get_current_map()
	_runner.assert_true(map != null, "村庄地图加载")
	if map == null:
		return
	var api: Node = _game_root.get_resources_api()
	_runner.assert_true(api != null, "ResourcesApi 就绪")
	if api == null:
		return
	var spawn_y: float = map.ground_y + (map.ground_bottom - map.ground_y) * 0.5

	# 补 spawn 矿工（真实 NPC_COUNT=2 只分到铁匠+伐木工；轮转 index=2 = 矿工）
	var layer: Node = map.get("decoration_layer") if "decoration_layer" in map else null
	_runner.assert_true(layer != null, "decoration_layer 存在")
	var miner: Node2D = map.spawn_entity(UnitsAPI.STICKMAN_ENTITY_SCENE, Vector2(1250.0, spawn_y))
	_runner.assert_true(miner != null, "矿工 spawn")
	if miner != null:
		miner.global_position.y = spawn_y - miner.foot_offset
		miner.set_possessed(false)
		var got: String = TownLifeAPI.assign_village_job(miner, 2)
		_runner.assert_equal(got, "miner", "轮转 index2 应得矿工")

	# 摆树与矿（净空带内无天然资源点，寻位必命中摆点；大储量防测试中途采空）
	_spawn_node(layer, ScriptResourceNode.ResourceType.WOOD, TREE_X, spawn_y, 500)
	_spawn_node(layer, ScriptResourceNode.ResourceType.METAL, ORE_X, spawn_y, 500)

	# 预置铁匠原料 + 记录基线库存
	api.produce("res_metal_ore", ORE_SEED_STOCK, "test_region", "测试预置")
	var wood0: float = api.get_stock("res_wood")
	var ore0: float = api.get_stock("res_metal_ore")
	var ingot0: float = api.get_stock("res_iron_ingot")

	# 无人干预轮询：三类库存全部增长（村民 AI 自主寻位→劳作→入库）
	var elapsed := 0.0
	var ok_wood := false
	var ok_ore := false
	var ok_ingot := false
	while elapsed < GROW_TIMEOUT:
		await get_tree().create_timer(POLL_INTERVAL).timeout
		elapsed += POLL_INTERVAL
		ok_wood = api.get_stock("res_wood") >= wood0 + THRESH_WOOD
		ok_ore = api.get_stock("res_metal_ore") >= ore0 + THRESH_ORE
		ok_ingot = api.get_stock("res_iron_ingot") >= ingot0 + THRESH_INGOT
		if ok_wood and ok_ore and ok_ingot:
			break
	_runner.assert_true(ok_wood, "res_wood 增长 ≥%d（%.0fs 实增 %.1f，村民伐木入库）"
			% [int(THRESH_WOOD), elapsed, api.get_stock("res_wood") - wood0])
	_runner.assert_true(ok_ore, "res_metal_ore 增长 ≥%d（%.0fs 实增 %.1f，矿工净增）"
			% [int(THRESH_ORE), elapsed, api.get_stock("res_metal_ore") - ore0])
	_runner.assert_true(ok_ingot, "res_iron_ingot 增长 ≥%d（%.0fs 实增 %.1f，铁匠矿→锭）"
			% [int(THRESH_INGOT), elapsed, api.get_stock("res_iron_ingot") - ingot0])

	# 行为证据：至少一名村民当前处于 harvest
	var harvesting := false
	for npc in _villagers(map):
		var ctl: Node = npc.get_ai_controller() if npc.has_method("get_ai_controller") else null
		if ctl != null and ctl.get_current_behavior() == "harvest":
			harvesting = true
			break
	_runner.assert_true(harvesting, "至少一名村民处于 harvest 行为")


## 摆一个资源点（真类进 decoration_layer，_ready 自动入 resource_node 组）
func _spawn_node(layer: Node, type: int, x: float, y: float, amount: int) -> void:
	if layer == null:
		return
	var node: Node2D = ScriptResourceNode.new()
	node.resource_type = type
	node.amount = amount
	node.position = Vector2(x, y)
	layer.add_child(node)


## 村民列表（EntityHost 内非附身、非守军、有职业的实体）
func _villagers(map: Node2D) -> Array:
	var result: Array = []
	var host: Node = map.get_node_or_null("EntityHost") if map != null else null
	if host == null:
		return result
	for u in host.get_children():
		if u is Node2D and is_instance_valid(u) \
				and u.has_method("get_profession") and not String(u.get_profession()).is_empty() \
				and u.has_method("is_possessed") and not u.is_possessed():
			result.append(u)
	return result
