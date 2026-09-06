extends Node
## 单元测试：快速旅行路网规划器（P6/E3，总体设计 §5.10）。
##
## 覆盖：建图（端点装配/重复边取短/无效条目跳过）/ Dijkstra 最短距离
## / find_path 路径序列与途经道路 / 不可通过区阻断（目标阻断与中间切断）
## / 出生 L1 真数据（MST 全连通 + from/to 透传回归锚，防 _roads_from 改动丢端点）。

signal test_done(code: int)

const TestRunner := preload("res://tests/core/test_runner.gd")
const L1WorldData := preload("res://modules/world_map/data/l1_world_data.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("建图：节点/邻接/重复边取短", _test_setup_graph)
	_runner.add_test("建图：无效条目安全跳过", _test_invalid_skipped)
	_runner.add_test("Dijkstra：最短距离与全源可达", _test_dijkstra)
	_runner.add_test("find_path：路径序列/长度/途经道路", _test_find_path)
	_runner.add_test("阻断：目标在不可通过区", _test_blocked_target)
	_runner.add_test("阻断：中间节点切断连通", _test_blocked_midway)
	_runner.add_test("真数据：出生 L1 MST 全连通", _test_birth_data)
	_runner.add_test("真数据：roads from/to 透传（回归锚）", _test_endpoints_passthrough)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


## 构造一条 road 条目（polyline 给最小 2 点，满足归一化语义）
func _road(a: String, b: String, length: float) -> Dictionary:
	return {
		"from": a, "to": b, "tier": "DIRT", "length_px": length,
		"polyline": [[0.0, 0.0], [float(length), 0.0]],
	}


func _test_setup_graph() -> void:
	var p := TravelPlanner.new()
	p.setup([
		_road("a", "b", 10.0),
		_road("b", "a", 4.0),   # 重复边（反向）取更短
		_road("b", "c", 7.0),
	])
	_runner.assert_true(p.has_settlement("a") and p.has_settlement("b") and p.has_settlement("c"),
			"三节点全部入图")
	_runner.assert_equal(p.get_nodes().size(), 3, "节点数 = 3")
	var nb: Dictionary = p.neighbors("a")
	_runner.assert_true(nb.has("b"), "a 的邻居含 b")
	_runner.assert_equal(float(nb["b"]), 4.0, "重复边取更短（10 → 4）")
	_runner.assert_equal(TravelPlanner.edge_key("a", "b"), TravelPlanner.edge_key("b", "a"),
			"无向边键对称")


func _test_invalid_skipped() -> void:
	var p := TravelPlanner.new()
	p.setup([
		"not_a_dict",
		{"to": "b", "length_px": 5.0},          # 缺 from → 跳过
		{"from": "a", "to": ""},                 # 空 to → 跳过
		{"from": "x", "to": "x", "length_px": 3.0},  # 自环 → 跳过
	])
	_runner.assert_equal(p.get_nodes().size(), 0, "全部无效条目跳过，图为空")
	var computed := p.compute("a")
	_runner.assert_true(computed.is_empty(), "未知源点 compute → 空结果")


## 钻石图：a-b(1) a-c(5) b-c(1) b-d(10) c-d(1)——a→d 最短 = a-b-c-d(3)
func _diamond() -> TravelPlanner:
	var p := TravelPlanner.new()
	p.setup([
		_road("a", "b", 1.0),
		_road("a", "c", 5.0),
		_road("b", "c", 1.0),
		_road("b", "d", 10.0),
		_road("c", "d", 1.0),
	])
	return p


func _test_dijkstra() -> void:
	var p := _diamond()
	var computed := p.compute("a")
	_runner.assert_equal(float(computed["b"]["dist"]), 1.0, "a→b = 1")
	_runner.assert_equal(float(computed["c"]["dist"]), 2.0, "a→c 走 a-b-c = 2（非直连 5）")
	_runner.assert_equal(float(computed["d"]["dist"]), 3.0, "a→d 走 a-b-c-d = 3（非 a-b-d 11）")
	_runner.assert_equal(computed.size(), 4, "全源可达（连通图）")
	_runner.assert_equal(str(computed["d"]["prev"]), "c", "d 的前驱 = c")


func _test_find_path() -> void:
	var p := _diamond()
	var route := p.find_path("a", "d")
	var path: Array = route["path"]
	_runner.assert_equal(path.size(), 4, "路径 4 节点")
	_runner.assert_equal(str(path[0]), "a", "起点 = a")
	_runner.assert_equal(str(path[3]), "d", "终点 = d")
	_runner.assert_equal(float(route["length_px"]), 3.0, "路径总长 = 3")
	_runner.assert_equal(route["roads"].size(), 3, "途经 3 条道路（高亮层消费）")
	var empty := p.find_path("a", "ghost")
	_runner.assert_true(empty["path"].is_empty(), "未知终点 → 空路径")


func _test_blocked_target() -> void:
	var p := _diamond()
	var blocked := {"d": true}
	_runner.assert_true(not p.compute("a", blocked).has("d"), "目标被阻断 → 不在可达集")
	_runner.assert_true(p.find_path("a", "d", blocked)["path"].is_empty(),
			"目标被阻断 → 无路径")
	_runner.assert_true(p.compute("a", blocked).has("c"), "其余节点不受影响")


func _test_blocked_midway() -> void:
	# 链图 a-b-c：阻断 b → c 与源切断（「被不可通过区切断」语义）
	var p := TravelPlanner.new()
	p.setup([
		_road("a", "b", 2.0),
		_road("b", "c", 3.0),
	])
	var blocked := {"b": true}
	_runner.assert_true(p.find_path("a", "c", blocked)["path"].is_empty(),
			"中间节点阻断 → 源汇切断")
	# 钻石图阻断 c 仍可绕 a-b-d（绕行语义）
	var diamond := _diamond()
	var route := diamond.find_path("a", "d", {"c": true})
	_runner.assert_equal(route["path"].size(), 3, "阻断 c 后绕行 a-b-d")
	_runner.assert_equal(float(route["length_px"]), 11.0, "绕行总长 = 1+10")


func _test_birth_data() -> void:
	var world = L1WorldData.load_from("res://config/strategic_map/l1_world.json",
			"res://config/strategic_map")
	if world == null:
		_runner.assert_true(false, "出生 L1 加载失败")
		return
	var p := TravelPlanner.new()
	p.setup(world.roads)
	var n_settlements := 0
	for tile in world.tiles:
		if tile.settlement != null:
			n_settlements += 1
	_runner.assert_equal(p.get_nodes().size(), n_settlements,
			"路网节点数 = 聚落数（8 城 MST 全部入图）")
	var computed := p.compute(world.spawn_settlement_id)
	_runner.assert_equal(computed.size(), n_settlements,
			"出生聚落单源全可达（MST 连通，实测 %d/%d）" % [computed.size(), n_settlements])
	# 任取一个非出生聚落查最短路（端到端真数据锚）
	var target := ""
	for tile in world.tiles:
		if tile.settlement != null and tile.settlement.settlement_id != world.spawn_settlement_id:
			target = tile.settlement.settlement_id
			break
	var route := p.find_path(world.spawn_settlement_id, target)
	_runner.assert_true(not route["path"].is_empty(), "出生 → 邻城最短路存在")
	_runner.assert_equal(route["path"].size() - 1, route["roads"].size(),
			"途经道路数 = 跳数（path 与 roads 对齐）")


func _test_endpoints_passthrough() -> void:
	# P6 回归锚：_roads_from 透传 from/to（F5 时代曾只留 pts/tier/length_px，
	# 路网图依赖端点——丢字段会让 TravelPlanner 静默建出空图）
	var world = L1WorldData.load_from("res://config/strategic_map/l1_world.json",
			"res://config/strategic_map")
	if world == null:
		_runner.assert_true(false, "出生 L1 加载失败")
		return
	var all_have_endpoints := true
	for rd in world.roads:
		if str(rd.get("from", "")).is_empty() or str(rd.get("to", "")).is_empty():
			all_have_endpoints = false
			break
	_runner.assert_true(all_have_endpoints, "每条道路 from/to 非空（bin/json 同构透传）")
