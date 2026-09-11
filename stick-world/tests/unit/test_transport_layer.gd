extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：TransportLayer v1 抽象传播（架构文档 §4.2，3-P 定稿）。
## 取距决策树全分支：同图直线 / 跨图 location 比较 / region provider / fallback / 快进短路。
## 纯逻辑（RefCounted + 注入 Callable），不进场景树，确定性。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptTransport := preload("res://modules/organization/scripts/command/transport_layer.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("Transport: 同图直线距离÷速度（玩家跳/组织跳两口径）", _test_same_map_direct)
	_runner.add_test("Transport: INF 走跨图分支，不同 location 查 region provider", _test_cross_map_region_provider)
	_runner.add_test("Transport: provider 未命中(-1)/未注入 → fallback 常数", _test_fallback_distance)
	_runner.add_test("Transport: location 相同（含同为空串）距离 0", _test_same_location_zero)
	_runner.add_test("Transport: speed=0 测试快进短路恒 0", _test_speed_zero_shortcircuit)
	_runner.add_test("Transport: 受控坐标除法断言（多层跳累加口径）", _test_controlled_division)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


## 默认接线：所有 org 坐标表 + 玩家坐标 + location 表 + 区域距离表（可按用例覆盖）
func _make_transport(positions: Dictionary, player_pos: Vector2, locations: Dictionary,
		region_distances: Dictionary) -> ScriptTransport:
	var t: ScriptTransport = ScriptTransport.new()
	t.setup(
		func(org_id: String) -> Variant:
			return positions.get(org_id, Vector2.INF),
		func() -> Vector2:
			return player_pos,
		func(from_loc: String, to_loc: String) -> float:
			return float(region_distances.get("%s>%s" % [from_loc, to_loc], -1.0))
	)
	t.set_location_provider(func(org_id: String) -> String:
		return str(locations.get(org_id, "")))
	return t


func _test_same_map_direct() -> void:
	# 组织跳：两指挥官实体坐标 (0,0)→(300,400)，直线 500px，速度 100 → 5s
	var t := _make_transport({"a": Vector2(0, 0), "b": Vector2(300, 400)}, Vector2.ZERO, {"a": "R1", "b": "R2"}, {})
	t.set_courier_speed(100.0)
	_runner.assert_approx(t.delivery_time("a", "b"), 5.0, 0.001, "同图直线 500px ÷ 100 = 5s")
	# 玩家跳：from_org="" 走 player_position_provider
	_runner.assert_approx(t.delivery_time("", "b"), 5.0, 0.001, "玩家跳 (0,0)→(300,400) 同为 5s")
	# 同一点距离 0
	var t2 := _make_transport({"a": Vector2(10, 10), "b": Vector2(10, 10)}, Vector2.ZERO, {}, {})
	t2.set_courier_speed(100.0)
	_runner.assert_approx(t2.delivery_time("a", "b"), 0.0, 0.001, "同坐标距离 0")


func _test_cross_map_region_provider() -> void:
	# a 有实体（同图），b 跨图（INF）→ location 不同 → 查 region provider（800px ÷ 100 = 8s）
	var t := _make_transport({"a": Vector2(0, 0), "b": Vector2.INF}, Vector2.ZERO,
		{"a": "settlement_a", "b": "settlement_b"}, {"settlement_a>settlement_b": 800.0})
	t.set_courier_speed(100.0)
	_runner.assert_approx(t.delivery_time("a", "b"), 8.0, 0.001, "跨图查 provider 800÷100=8s")
	# 双方都 INF（无实体）同样走跨图分支
	var t2 := _make_transport({"a": Vector2.INF, "b": Vector2.INF}, Vector2.ZERO,
		{"a": "settlement_a", "b": "settlement_b"}, {"settlement_a>settlement_b": 400.0})
	t2.set_courier_speed(100.0)
	_runner.assert_approx(t2.delivery_time("a", "b"), 4.0, 0.001, "双方 INF 也走跨图 400÷100=4s")


func _test_fallback_distance() -> void:
	# region provider 返回 -1（未知对）→ fallback 常数 2000 ÷ 100 = 20s
	var t := _make_transport({"a": Vector2.INF, "b": Vector2.INF}, Vector2.ZERO,
		{"a": "x", "b": "y"}, {})
	t.set_courier_speed(100.0)
	_runner.assert_approx(t.delivery_time("a", "b"), 20.0, 0.001, "未命中 fallback 2000÷100=20s")
	# set_fallback_distance 覆盖（balance 行覆盖入口）
	t.set_fallback_distance(600.0)
	_runner.assert_approx(t.delivery_time("a", "b"), 6.0, 0.001, "fallback 覆盖 600÷100=6s")
	# provider 未注入（未装配）→ 同样 fallback（location 须不同才会走 provider/fallback 分支）
	var t2: ScriptTransport = ScriptTransport.new()
	t2.set_courier_speed(100.0)
	t2.set_location_provider(func(org_id: String) -> String: return org_id)  # "a" vs "b" 不同驻地
	_runner.assert_approx(t2.delivery_time("a", "b"), 20.0, 0.001, "region provider 未注入也走 fallback")


func _test_same_location_zero() -> void:
	# location 相同 → 距离 0（同驻地内传令忽略不计），即使双方都无实体
	var t := _make_transport({"a": Vector2.INF, "b": Vector2.INF}, Vector2.ZERO,
		{"a": "R1", "b": "R1"}, {"R1>R1": 999.0})
	t.set_courier_speed(100.0)
	_runner.assert_approx(t.delivery_time("a", "b"), 0.0, 0.001, "同 location 距离 0")
	# 同为空串（location 未回填的 P0 默认态）→ 同驻地口径 0
	var t2 := _make_transport({"a": Vector2.INF, "b": Vector2.INF}, Vector2.ZERO, {}, {})
	t2.set_courier_speed(100.0)
	_runner.assert_approx(t2.delivery_time("a", "b"), 0.0, 0.001, "location 同空串距离 0")
	# 玩家跳 + 对方 location 空串 → 0（玩家无驻地 = ""）
	_runner.assert_approx(t2.delivery_time("", "b"), 0.0, 0.001, "玩家跳至空驻地 0")


func _test_speed_zero_shortcircuit() -> void:
	# speed=0（测试快进）恒 0——距离都不算（短路），provider 全不接线也应 0
	var t: ScriptTransport = ScriptTransport.new()
	t.set_courier_speed(0.0)
	_runner.assert_approx(t.delivery_time("any", "org"), 0.0, 0.001, "speed=0 短路恒 0")
	_runner.assert_approx(t.delivery_time("", "org"), 0.0, 0.001, "玩家跳同样短路 0")
	# 负速度防御同口径
	t.set_courier_speed(-5.0)
	_runner.assert_approx(t.delivery_time("any", "org"), 0.0, 0.001, "负速度按快进口径恒 0")


func _test_controlled_division() -> void:
	# 受控除法：不同速度线性反比（供集成层累加口径对照）
	var t := _make_transport({"a": Vector2(0, 0), "b": Vector2(600, 0)}, Vector2.ZERO, {}, {})
	t.set_courier_speed(300.0)
	_runner.assert_approx(t.delivery_time("a", "b"), 2.0, 0.001, "600÷300=2s")
	t.set_courier_speed(150.0)
	_runner.assert_approx(t.delivery_time("a", "b"), 4.0, 0.001, "600÷150=4s（速度减半时间翻倍）")
