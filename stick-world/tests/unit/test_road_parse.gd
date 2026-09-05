extends Node
## 单元测试：道路数据解析与分级（F5/E2，总体设计 §5.9）。
##
## 覆盖：L1WorldData.roads 装配（bin 优先路径，P3.5 贴地形折线不丢）/ tier 分级合法性
## / polyline 与 json 原文同构 / 无 polyline 回退两端聚落直线（向后兼容口径）
## / 无效条目安全跳过。

signal test_done(code: int)

const TestRunner := preload("res://tests/core/test_runner.gd")
const L1WorldData := preload("res://modules/world_map/data/l1_world_data.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("L1: roads 装配（bin 优先路径）", _test_l1_roads)
	_runner.add_test("L1: tier 分级合法", _test_tier_legal)
	_runner.add_test("L1: polyline 与 json 同构", _test_polyline_matches_json)
	_runner.add_test("归一化: 无 polyline 回退聚落直线", _test_fallback_straight)
	_runner.add_test("归一化: 无效条目安全跳过", _test_invalid_skipped)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _test_l1_roads() -> void:
	var world = L1WorldData.load_from("res://config/strategic_map/l1_world.json", "res://config/strategic_map")
	_runner.assert_true(world != null, "出生 L1 可加载")
	_runner.assert_true(world.roads.size() >= world.tiles.size() - 1,
			"道路数 >= 城市数-1（MST 连通，实测 %d/%d）" % [world.roads.size(), world.tiles.size()])
	var all_ok := true
	for rd in world.roads:
		if not (rd.get("pts") is PackedVector2Array) or (rd["pts"] as PackedVector2Array).size() < 2:
			all_ok = false
			break
	_runner.assert_true(all_ok, "每条道路 pts 为 PackedVector2Array 且 ≥2 点")


func _test_tier_legal() -> void:
	var world = L1WorldData.load_from("res://config/strategic_map/l1_world.json", "res://config/strategic_map")
	if world == null or world.roads.is_empty():
		_runner.assert_true(false, "前置失败：无 roads 数据")
		return
	var legal := true
	var has_length := true
	for rd in world.roads:
		var tier := str(rd.get("tier", ""))
		if tier != "DIRT" and tier != "PAVED":
			legal = false
		if float(rd.get("length_px", 0.0)) <= 0.0:
			has_length = false
	_runner.assert_true(legal, "全部 tier ∈ {DIRT, PAVED}")
	_runner.assert_true(has_length, "全部 length_px > 0")


func _test_polyline_matches_json() -> void:
	var world = L1WorldData.load_from("res://config/strategic_map/l1_world.json", "res://config/strategic_map")
	if world == null or world.roads.is_empty():
		_runner.assert_true(false, "前置失败：无 roads 数据")
		return
	# bin 优先加载路径下 polyline 不得丢失（P3.5 贴地形折线）——与 json 原文首条首点对照
	var raw_text := FileAccess.get_file_as_string("res://config/strategic_map/l1_world.json")
	var parsed: Variant = JSON.parse_string(raw_text)
	if not (parsed is Dictionary):
		_runner.assert_true(false, "json 原文可解析")
		return
	var raw_roads: Array = parsed["roads"]
	var raw_firsts: Array[Vector2] = []
	for rd in raw_roads:
		var pl: Array = rd.get("polyline", [])
		if pl.size() >= 2:
			raw_firsts.append(Vector2(float(pl[0][0]), float(pl[0][1])))
	if raw_firsts.is_empty():
		_runner.assert_true(false, "json 无带 polyline 的道路（数据异常）")
		return
	# PackedVector2Array 是 float32，与 json float64 比较用容差（%f 字符串比较会踩精度差）
	var found_match := false
	for rd in world.roads:
		var first: Vector2 = (rd["pts"] as PackedVector2Array)[0]
		for rf in raw_firsts:
			if first.distance_to(rf) < 0.01:
				found_match = true
				break
		if found_match:
			break
	_runner.assert_true(found_match,
			"运行时道路首点与 json polyline 首点同构（bin 未丢 polyline）")


func _test_fallback_straight() -> void:
	# 无 polyline：回退 from/to 聚落直线（§5.9 向后兼容口径）
	var tiles: Array[L1TileDef] = []
	var t1 := L1TileDef.new()
	t1.tile_id = "city_a"
	var s1 := SettlementRef.new()
	s1.settlement_id = "settlement_a"
	s1.position = Vector2(10.0, 20.0)
	t1.settlement = s1
	tiles.append(t1)
	var t2 := L1TileDef.new()
	t2.tile_id = "city_b"
	var s2 := SettlementRef.new()
	s2.settlement_id = "settlement_b"
	s2.position = Vector2(30.0, 60.0)
	t2.settlement = s2
	tiles.append(t2)
	var arr: Array = [{"from": "settlement_a", "to": "settlement_b"}]
	var out: Array = L1WorldData._roads_from(arr, tiles)
	_runner.assert_equal(out.size(), 1, "无 polyline 条目正常装配")
	var pts: PackedVector2Array = out[0]["pts"]
	_runner.assert_equal(pts.size(), 2, "回退直线为 2 点")
	_runner.assert_equal(pts[0], Vector2(10.0, 20.0), "起点 = 聚落 A 坐标")
	_runner.assert_equal(pts[1], Vector2(30.0, 60.0), "终点 = 聚落 B 坐标")
	_runner.assert_equal(str(out[0]["tier"]), "DIRT", "tier 缺省回退 DIRT")


func _test_invalid_skipped() -> void:
	var tiles: Array[L1TileDef] = []
	var arr: Array = [
		"not_a_dict",
		{"from": "ghost_a", "to": "ghost_b"},   # 两端聚落未知 → 跳过
		{"from": "settlement_a"},                # 缺 to 且无 polyline → 跳过
	]
	var out: Array = L1WorldData._roads_from(arr, tiles)
	_runner.assert_equal(out.size(), 0, "非 dict / 聚落未知 / 端点缺失条目全部安全跳过")
	var out2: Array = L1WorldData._roads_from([], tiles)
	_runner.assert_equal(out2.size(), 0, "空输入 → 空数组")
