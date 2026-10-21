extends Node
## 单元测试：world_map.region_distance 跨图区域距离接口（组织系统架构 §4.2.2 收口）。
##
## 覆盖：两级区域标识解析（settlement_id 定居点级直查 / map_id 地图根级反查聚落锚点）、
## 同聚落两级标识等价（距离 0）、未命中（未知标识/战略图外场景/空串）→ -1、
## 传输层 delivery_time 接真 provider 的跨图真值与 fallback 回退。
##
## 真数据锚：config/strategic_map/l1_world.json（出生包 settlement.map_id 已回填
## l1_settlement_%02d，与 test_travel_planner 同源）。期望值动态取自
## SettlementRef.position（验证解析命中正确锚点，不写死随数据漂移的数值）。

signal test_done(code: int)

const TestRunner := preload("res://tests/core/test_runner.gd")
const L1WorldData := preload("res://modules/world_map/data/l1_world_data.gd")
const WorldMapApiScript := preload("res://modules/world_map/api.gd")
const ScriptTransport := preload("res://modules/organization/scripts/command/transport_layer.gd")

const BIRTH_JSON := "res://config/strategic_map/l1_world.json"
const BIRTH_DIR := "res://config/strategic_map"

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("RegionDist: settlement_id 直查真距离", _test_settlement_direct)
	_runner.add_test("RegionDist: map_id 反查锚点与 settlement_id 等价", _test_map_id_equivalence)
	_runner.add_test("RegionDist: 同聚落两级标识混用距离 0", _test_same_settlement_mixed)
	_runner.add_test("RegionDist: 未命中对返回 -1（未知/战略图外/空串）", _test_unknown_minus_one)
	_runner.add_test("Transport: region provider 真值 → 跨图延迟 = 真距离÷速度", _test_transport_true_value)
	_runner.add_test("Transport: provider -1 → fallback 常数回退", _test_transport_fallback)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


## 构造只喂了出生 L1 数据的 api 实例（不进树不碰 autoload；region_distance 纯数据路径）
func _make_api() -> Node:
	var api := Node.new()
	api.set_script(WorldMapApiScript)
	var world = L1WorldData.load_from(BIRTH_JSON, BIRTH_DIR)
	if world == null:
		return null
	api.set("_data", world)
	api.set("_birth_data", world)
	return api


## 取出生数据前两个聚落 {settlement_id, map_id, position}（真数据锚样本）
func _first_two_settlements() -> Array:
	var world = L1WorldData.load_from(BIRTH_JSON, BIRTH_DIR)
	var picked: Array = []
	for tile in world.tiles:
		if tile.settlement != null and not tile.settlement.map_id.is_empty():
			picked.append({
				"sid": tile.settlement.settlement_id,
				"map_id": tile.settlement.map_id,
				"pos": tile.settlement.position,
			})
			if picked.size() >= 2:
				break
	return picked


func _test_settlement_direct() -> void:
	var api := _make_api()
	if api == null:
		_runner.assert_true(false, "出生 L1 加载失败")
		return
	var pair := _first_two_settlements()
	var expect: float = (pair[0]["pos"] as Vector2).distance_to(pair[1]["pos"])
	var got: float = api.region_distance(pair[0]["sid"], pair[1]["sid"])
	_runner.assert_approx(got, expect, 0.01, "settlement 直查距离 = 两锚点直线距离")
	api.free()


func _test_map_id_equivalence() -> void:
	var api := _make_api()
	if api == null:
		_runner.assert_true(false, "出生 L1 加载失败")
		return
	var pair := _first_two_settlements()
	var by_sid: float = api.region_distance(pair[0]["sid"], pair[1]["sid"])
	var by_map: float = api.region_distance(pair[0]["map_id"], pair[1]["map_id"])
	_runner.assert_approx(by_map, by_sid, 0.01, "map_id 反查与 settlement_id 同锚点")
	# 混用（一级配另一级）同样成立
	var mixed: float = api.region_distance(pair[0]["sid"], pair[1]["map_id"])
	_runner.assert_approx(mixed, by_sid, 0.01, "两级标识混用同距")
	api.free()


func _test_same_settlement_mixed() -> void:
	var api := _make_api()
	if api == null:
		_runner.assert_true(false, "出生 L1 加载失败")
		return
	var pair := _first_two_settlements()
	_runner.assert_approx(api.region_distance(pair[0]["sid"], pair[0]["map_id"]), 0.0, 0.001,
			"同一聚落 settlement_id vs map_id = 0")
	_runner.assert_approx(api.region_distance(pair[0]["map_id"], pair[0]["map_id"]), 0.0, 0.001,
			"同 map_id 自身 = 0")
	api.free()


func _test_unknown_minus_one() -> void:
	var api := _make_api()
	if api == null:
		_runner.assert_true(false, "出生 L1 加载失败")
		return
	var pair := _first_two_settlements()
	_runner.assert_equal(api.region_distance("settlement_ghost_999", pair[0]["sid"]), -1.0,
			"未知 settlement_id → -1")
	_runner.assert_equal(api.region_distance(pair[0]["sid"], "l1_settlement_99"), -1.0,
			"未注册 map_id → -1")
	_runner.assert_equal(api.region_distance(pair[0]["sid"], "hd2d_street"), -1.0,
			"战略图外场景（无静态锚点）→ -1")
	_runner.assert_equal(api.region_distance("", pair[0]["sid"]), -1.0,
			"空串 → -1")
	api.free()


func _test_transport_true_value() -> void:
	var api := _make_api()
	if api == null:
		_runner.assert_true(false, "出生 L1 加载失败")
		return
	var pair := _first_two_settlements()
	# 传输层注入真 provider：两组织双 INF（跨图）+ location = 两 map_id
	var t: ScriptTransport = ScriptTransport.new()
	t.setup(
		func(_org_id: String) -> Variant: return Vector2.INF,
		func() -> Vector2: return Vector2.INF,
		func(from_loc: String, to_loc: String) -> float:
			return float(api.region_distance(from_loc, to_loc)))
	t.set_location_provider(func(org_id: String) -> String:
		return str(pair[0]["map_id"]) if org_id == "a" else str(pair[1]["map_id"]))
	t.set_courier_speed(100.0)
	var expect_dist: float = (pair[0]["pos"] as Vector2).distance_to(pair[1]["pos"])
	_runner.assert_approx(t.delivery_time("a", "b"), expect_dist / 100.0, 0.001,
			"跨图延迟 = 真距离 ÷ 速度（非 fallback）")
	api.free()


func _test_transport_fallback() -> void:
	var api := _make_api()
	if api == null:
		_runner.assert_true(false, "出生 L1 加载失败")
		return
	var pair := _first_two_settlements()
	var t: ScriptTransport = ScriptTransport.new()
	t.setup(
		func(_org_id: String) -> Variant: return Vector2.INF,
		func() -> Vector2: return Vector2.INF,
		func(from_loc: String, to_loc: String) -> float:
			return float(api.region_distance(from_loc, to_loc)))
	# 一方驻战略图外场景（hd2d_street 无锚点）→ provider -1 → fallback 2000 ÷ 100 = 20s
	t.set_location_provider(func(org_id: String) -> String:
		return str(pair[0]["map_id"]) if org_id == "a" else "hd2d_street")
	t.set_courier_speed(100.0)
	_runner.assert_approx(t.delivery_time("a", "b"), 20.0, 0.001,
			"无锚点对 → fallback 2000÷100=20s")
	api.free()
