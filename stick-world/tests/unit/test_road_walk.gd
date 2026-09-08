extends Node
## 单元测试：步行旅行（F6/E5，总体设计 §5.10）—— 道路场景生成器 + 步行队列。
##
## 覆盖：场景宽度公式（tier 系数 + clamp）/ 生成场景结构（RoadMap/出口触发器 target 空）
## / seed 确定性 / biomes 色带分段与兜底 / L1WorldData biomes 透传回归锚
## / api.walk_to 组装队列（真数据）与拒绝分支。

signal test_done(code: int)

const TestRunner := preload("res://tests/core/test_runner.gd")
const L1WorldData := preload("res://modules/world_map/data/l1_world_data.gd")
const WorldMapApi := preload("res://modules/world_map/api.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("生成器：场景宽度公式（tier 系数 + clamp）", _test_scene_width)
	_runner.add_test("生成器：场景结构与出口触发器", _test_scene_structure)
	_runner.add_test("生成器：seed 确定性（同输入同场景）", _test_determinism)
	_runner.add_test("生成器：biomes 色带分段与兜底", _test_biome_bands)
	_runner.add_test("数据：roads biomes 透传（回归锚）", _test_biomes_passthrough)
	_runner.add_test("api.walk_to：队列组装与 travel_requested", _test_walk_to)
	_runner.add_test("api.walk_to：拒绝分支（不连通/未知聚落）", _test_walk_reject)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


## 构造一段步行队列 leg
func _leg(tier: String, length: float, biomes := PackedInt32Array()) -> Dictionary:
	return {
		"road_id": "road_test_a_b",
		"road": {
			"pts": PackedVector2Array([Vector2(0, 0), Vector2(length, 0)]),
			"from": "settlement_a", "to": "settlement_b",
			"tier": tier, "length_px": length, "biomes": biomes,
		},
		"from_map_id": "l1_settlement_00", "to_map_id": "l1_settlement_01",
	}


func _test_scene_width() -> void:
	_runner.assert_equal(RoadMapGenerator.scene_width(100.0, "DIRT"), 2400.0, "土路 ×24")
	_runner.assert_equal(RoadMapGenerator.scene_width(100.0, "PAVED"), 1600.0, "官道 ×16（大路好走更短）")
	_runner.assert_equal(RoadMapGenerator.scene_width(1.0, "DIRT"), RoadMapGenerator.MIN_WIDTH, "极短路 clamp 下限")
	_runner.assert_equal(RoadMapGenerator.scene_width(99999.0, "PAVED"), RoadMapGenerator.MAX_WIDTH, "超长路 clamp 上限")
	_runner.assert_true(RoadMapGenerator.scene_width(1000.0, "PAVED") < RoadMapGenerator.scene_width(1000.0, "DIRT"),
			"同长度官道场景短于土路")


func _test_scene_structure() -> void:
	var packed := RoadMapGenerator.build(_leg("DIRT", 100.0))
	_runner.assert_true(packed != null, "build 产出 PackedScene")
	var inst: Node2D = packed.instantiate()
	add_child(inst)
	_runner.assert_true(inst is RoadMap, "根节点为 RoadMap（MapBase 子类，spawn_entity 可用）")
	_runner.assert_true(inst.get_node_or_null("EntityHost") != null, "EntityHost 存在")
	_runner.assert_true(inst.get_node_or_null("TerrainLayer/RoadStrip") != null, "道路本体带存在")
	_runner.assert_true(inst.get_node_or_null("ChunkTriggers/ExitLeft") != null
			and inst.get_node_or_null("ChunkTriggers/ExitRight") != null, "左右出口触发器存在")
	var left: Area2D = inst.get_node("ChunkTriggers/ExitLeft")
	var right: Area2D = inst.get_node("ChunkTriggers/ExitRight")
	_runner.assert_true(str(left.target_map_id).is_empty() and str(right.target_map_id).is_empty(),
			"出口 target 留空（GameRoot 按队列状态刷 register_map_exit）")
	_runner.assert_true(inst.map_right > 0.0 and inst.map_left == 0.0, "宽度写入 map_right")
	inst.queue_free()


func _test_determinism() -> void:
	var a := RoadMapGenerator.build(_leg("DIRT", 500.0)).instantiate()
	var b := RoadMapGenerator.build(_leg("DIRT", 500.0)).instantiate()
	add_child(a)
	add_child(b)
	var da: Node2D = a.get_node("DecorationLayer")
	var db: Node2D = b.get_node("DecorationLayer")
	_runner.assert_equal(da.get_child_count(), db.get_child_count(), "装饰数量一致（seed 确定）")
	var same := true
	for i in da.get_child_count():
		var pa: PackedVector2Array = (da.get_child(i) as Polygon2D).polygon
		var pb: PackedVector2Array = (db.get_child(i) as Polygon2D).polygon
		# PackedVector2Array 无 is_equal_approx（4.7 静态分析报 parse error）：
		# 确定性 seed 下应逐点相等，直接 == 比较
		if pa != pb:
			same = false
			break
	_runner.assert_true(same, "装饰形状逐点一致")
	a.queue_free()
	b.queue_free()


func _test_biome_bands() -> void:
	var with_biomes := RoadMapGenerator.build(_leg("DIRT", 300.0, PackedInt32Array([1, 2, 1]))).instantiate()
	add_child(with_biomes)
	var terrain: Node2D = with_biomes.get_node("TerrainLayer")
	var band_count := 0
	for c in terrain.get_children():
		if str(c.name).begins_with("BiomeBand"):
			band_count += 1
	_runner.assert_equal(band_count, 3, "色带分段数 = biomes 采样数")
	with_biomes.queue_free()
	var no_biomes := RoadMapGenerator.build(_leg("PAVED", 300.0)).instantiate()
	add_child(no_biomes)
	var terrain2: Node2D = no_biomes.get_node("TerrainLayer")
	var band_count2 := 0
	for c in terrain2.get_children():
		if str(c.name).begins_with("BiomeBand"):
			band_count2 += 1
	_runner.assert_equal(band_count2, 1, "无 biomes 兜底单色带（旧包兼容）")
	no_biomes.queue_free()


func _test_biomes_passthrough() -> void:
	# F6 回归锚：_roads_from 透传 biomes（丢字段会让道路场景全体单色兜底）
	var world = L1WorldData.load_from("res://config/strategic_map/l1_world.json",
			"res://config/strategic_map")
	if world == null:
		_runner.assert_true(false, "出生 L1 加载失败")
		return
	var with_biomes := 0
	for rd in world.roads:
		var b: PackedInt32Array = rd.get("biomes", PackedInt32Array())
		if b.size() >= 2:
			with_biomes += 1
	_runner.assert_true(with_biomes >= world.roads.size() - 1,
			"出生包道路 biomes 已注入（%d/%d，直线回退段除外）" % [with_biomes, world.roads.size()])
	var in_range := true
	for rd in world.roads:
		for v in rd.get("biomes", PackedInt32Array()):
			if v < 0 or v > 6:
				in_range = false
	_runner.assert_true(in_range, "群系标签值域 [0,6]")


func _make_api() -> Node:
	var world = L1WorldData.load_from("res://config/strategic_map/l1_world.json",
			"res://config/strategic_map")
	var api: Node = WorldMapApi.new()
	api._data = world
	api._birth_data = world
	api._is_initialized = world != null and world.base_texture != null
	api._player_settlement_id = world.spawn_settlement_id
	api._travel_planner = TravelPlanner.new()
	api._travel_planner.setup(world.roads)
	add_child(api)
	return api


func _test_walk_to() -> void:
	var api := _make_api()
	# 目标：任取非出生聚落（出生 8 城 MST 全连通，必有可达路径）
	var target: SettlementRef = null
	for tile in api._data.tiles:
		if tile.settlement != null and tile.settlement.settlement_id != api._player_settlement_id:
			target = tile.settlement
			break
	var requested := []
	EventBus.travel_requested.connect(func(m: String, mode: int) -> void:
		requested.append([m, mode]))
	var origin_map: String = api.get_settlement_ref(api._player_settlement_id).map_id
	var ok: bool = api.walk_to(target.settlement_id)
	_runner.assert_true(ok, "walk_to 成功")
	_runner.assert_equal(requested.size(), 1, "发射一次 travel_requested")
	_runner.assert_true(str(requested[0][0]).begins_with("road_"), "目标为道路场景 id（非聚落 id）")
	_runner.assert_equal(int(requested[0][1]), WorldAPI.TravelMode.WALK, "travel_mode = WALK")
	_runner.assert_true(WorldState.is_walking(), "步行队列建立")
	_runner.assert_true(WorldState.walk_legs.size() >= 1, "至少一段道路")
	_runner.assert_equal(str(WorldState.walk_legs[0]["road_id"]), str(requested[0][0]),
			"第一段 road_id 与发射一致")
	_runner.assert_equal(str(WorldState.walk_target_map_id), target.map_id, "终点 = 目标聚落")
	_runner.assert_equal(str(WorldState.walk_origin_map_id), origin_map, "出发 = 当前聚落")
	# 每段 leg 自包含（road 数据 + 两端 map_id，生成器消费）
	var legs_complete := true
	for leg in WorldState.walk_legs:
		if leg.get("road") == null or str(leg.get("from_map_id", "")).is_empty() \
				or str(leg.get("to_map_id", "")).is_empty():
			legs_complete = false
	_runner.assert_true(legs_complete, "leg 结构完整（road/from_map_id/to_map_id）")
	WorldState.reset_walk()
	api.queue_free()


func _test_walk_reject() -> void:
	var api := _make_api()
	WorldState.reset_walk()
	_runner.assert_true(not api.walk_to("settlement_ghost"), "未知聚落拒绝")
	_runner.assert_true(not WorldState.is_walking(), "拒绝后无队列")
	# 目标=当前聚落：已在此处
	_runner.assert_true(not api.walk_to(api._player_settlement_id), "当前聚落拒绝")
	# 阻断目标：block_filter 拉黑全部其他聚落
	api._block_filter = func(_sid: String) -> bool: return true
	var target: SettlementRef = null
	for tile in api._data.tiles:
		if tile.settlement != null and tile.settlement.settlement_id != api._player_settlement_id:
			target = tile.settlement
			break
	_runner.assert_true(not api.walk_to(target.settlement_id), "不可通过区目标拒绝")
	_runner.assert_true(not WorldState.is_walking(), "拒绝后无队列")
	api.queue_free()
