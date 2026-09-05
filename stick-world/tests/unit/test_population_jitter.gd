extends Node
## 单元测试：population_score 每局扰动（C3，总体设计 §5.7）。
##
## 覆盖：出生聚落免疫 / 基准值≤0 不扰动 / ±15% 边界 / run_seed 确定性
## / l1_world.json 装配接线（8 城非零 + 出生城等于基准）。

signal test_done(code: int)

const TestRunner := preload("res://tests/core/test_runner.gd")
const L1WorldData := preload("res://modules/world_map/data/l1_world_data.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("扰动: 出生聚落免疫", _test_spawn_immune)
	_runner.add_test("扰动: 基准值≤0 不扰动", _test_nonpositive)
	_runner.add_test("扰动: ±15% 边界", _test_bounds)
	_runner.add_test("扰动: run_seed 确定性", _test_determinism)
	_runner.add_test("扰动: WorldState 存档回传", _test_world_state_roundtrip)
	_runner.add_test("扰动: l1_world.json 装配接线", _test_l1_load_wiring)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _test_spawn_immune() -> void:
	_runner.assert_equal(SettlementRef.jitter_population_score(0.8, "settlement_city_1036", 12345, true), 0.8,
			"出生聚落免疫：扰动不生效")
	_runner.assert_equal(SettlementRef.jitter_population_score(0.8, "settlement_city_1036", 999, true), 0.8,
			"出生聚落免疫：换 run_seed 仍原样")


func _test_nonpositive() -> void:
	_runner.assert_equal(SettlementRef.jitter_population_score(0.0, "settlement_city_1000", 42, false), 0.0,
			"基准 0（未设）不扰动")
	_runner.assert_equal(SettlementRef.jitter_population_score(-0.3, "settlement_city_1000", 42, false), -0.3,
			"负基准不扰动")


func _test_bounds() -> void:
	var ok := true
	for i in range(64):
		var id := "settlement_city_%04d" % i
		var v := SettlementRef.jitter_population_score(0.6, id, 1000 + i, false)
		if v < 0.6 * 0.85 - 1e-6 or v > minf(0.6 * 1.15, 1.0) + 1e-6:
			ok = false
	_runner.assert_true(ok, "64 个样本全部落在 ±15% 区间内")


func _test_determinism() -> void:
	var a := SettlementRef.jitter_population_score(0.7, "settlement_city_1034", 777, false)
	var b := SettlementRef.jitter_population_score(0.7, "settlement_city_1034", 777, false)
	_runner.assert_true(absf(a - b) < 1e-9, "同 id 同 run_seed 逐点一致")
	var saw_diff := false
	for seed_offset in range(1, 32):
		if absf(SettlementRef.jitter_population_score(0.7, "settlement_city_1034", 777 + seed_offset, false) - a) > 1e-9:
			saw_diff = true
			break
	_runner.assert_true(saw_diff, "run_seed 变化会改变扰动结果")


func _test_world_state_roundtrip() -> void:
	if WorldState == null:
		_runner.assert_true(false, "WorldState 不可用")
		return
	var old: int = WorldState.run_seed
	WorldState.run_seed = 424242
	var data: Dictionary = WorldState.get_save_data()
	WorldState.run_seed = 0
	WorldState.load_save_data(data)
	_runner.assert_equal(WorldState.run_seed, 424242, "run_seed 随存档保存/恢复")
	WorldState.run_seed = old


func _test_l1_load_wiring() -> void:
	var world = L1WorldData.load_from("res://config/strategic_map/l1_world.json", "res://config/strategic_map")
	_runner.assert_true(world != null and world.tiles.size() == 8, "出生 L1 装配 8 地块")
	var with_score := 0
	var spawn_base_ok := false
	for t in world.tiles:
		var s = t.settlement
		if s == null:
			continue
		if s.population_score > 0.0:
			with_score += 1
		if s.settlement_id == world.spawn_settlement_id:
			# run_seed=0（headless 未开局）→ 出生城免疫，等于基准 0.8
			spawn_base_ok = absf(s.population_score - 0.8) < 1e-6
	_runner.assert_equal(with_score, 8, "8 城 population_score 均从 JSON 读出且非零")
	_runner.assert_true(spawn_base_ok, "出生聚落 population_score 等于基准 0.8（免疫）")
