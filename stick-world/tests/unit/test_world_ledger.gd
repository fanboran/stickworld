extends Node
## 单元测试：世界账本（世界模型整合 M2 迭代 1——离屏城账面日推进）。
##
## 覆盖：人口 logistic × 活力成长（兴旺村步进/薄土村停滞分化/容量收敛/单调不减）/
## 档位自然跨越（人口过阈值升档，只升不降）/ 财富趋饱和自限 /
## 守军每日补员至目标（只增不减）/ FOCUS 城跳过（模拟分档）/
## cap=0 旧档兼容（静止）/ 零随机确定性（同构世界同轨迹）/
## 真源集成（193 政权 1036 城推进 365 日：账面变化可查 + 全域不变量，
## = M2 迭代 1 验收门的测试化）/ 存档往返续算（推进→存→读→再推进等价）/
## 日脉冲桥生命周期（审计回归：装配幂等/宿主释放自动断连不叠连）。
## 纯数据层测试：preload 脚本 new() 即用，不依赖 autoload 单例——唯一例外
## 是桥生命周期用例（需真实 EventBus autoload 的连接表，批跑环境恒在）。

signal test_done(code: int)

const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptWS := preload("res://core/autoload/world_state.gd")
const ScriptInit := preload("res://core/entities/world_contract_initializer.gd")
const ScriptLedger := preload("res://core/entities/world_ledger.gd")
const ScriptCity := preload("res://core/entities/city_state.gd")
const ScriptLedgerSetup := preload("res://modules/world/scripts/setup/world_ledger_setup.gd")

const RUN_SEED := 20261118
const N_STATES := 193
const N_CITIES := 1036

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("world_ledger: 人口成长——最小步进 + 容量收敛 + 单调", _test_population_growth)
	_runner.add_test("world_ledger: 档位自然跨越（升档判定只升不降）", _test_level_progression)
	_runner.add_test("world_ledger: 财富趋饱和自限", _test_wealth_saturation)
	_runner.add_test("world_ledger: 守军每日补员至目标", _test_garrison_replenish)
	_runner.add_test("world_ledger: FOCUS 城跳过 + cap=0 旧档静止", _test_tier_and_legacy)
	_runner.add_test("world_ledger: 零随机确定性（同构同轨迹）", _test_determinism)
	_runner.add_test("world_ledger: 存档往返续算等价", _test_save_resume)
	_runner.add_test("world_ledger: 真源集成 365 日（M2 验收门测试化）", _test_real_world_365d)
	_runner.add_test("world_ledger: 日脉冲桥生命周期（审计回归）", _test_pulse_bridge_lifecycle, true)
	await _runner.run_async()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────────────── 测试世界构造 ────────────────────────────────

## 单城测试世界（不触真源，直驱字段）
func _make_world(cities: Array) -> Node:
	var ws := ScriptWS.new()
	ws.run_seed = RUN_SEED
	for c in cities:
		ws.cities[c.settlement_id] = c
	return ws


func _make_city(sid: String, pop: int, cap: int, level: int = 1) -> CityState:
	var c: CityState = ScriptCity.new()
	c.settlement_id = sid
	c.tile_key = "city_001"
	c.owner_state_id = "state_v2_001"
	c.level = level
	c.population = pop
	c.pop_capacity = cap
	c.garrison = {"stm_spear_001": 2}
	return c


func _free_worlds(worlds: Array) -> void:
	for ws in worlds:
		ws.free()


# ─────────────────────────────── 用例 ───────────────────────────────

func _test_population_growth() -> void:
	# 兴旺村（headroom 2.4 → 活力 1.28）：62 / 容量 150，首日 +1
	var village := _make_city("settlement_city_001", 62, 150, 1)
	var ws := _make_world([village])
	ScriptLedger.advance_day(ws)
	_runner.assert_equal(village.population, 63, "兴旺村首日 +1（活力 × logistic）")
	# 停滞村（headroom 1.29 → 活力 0.26）：取整后 0 增量——薄土村分化停滞（审计 F4）
	var stagnant := _make_city("settlement_city_008", 62, 80, 1)
	var ws3 := _make_world([stagnant])
	for i in range(50):
		ScriptLedger.advance_day(ws3)
	_runner.assert_equal(stagnant.population, 62, "薄土村长跑停滞（无全局保底，兴衰分化）")
	# 收敛：长跑后停滞——容量是渐近上限，停滞点由活力×取整涌现（村停在容量
	# 五至七成处），单调不减、停滞后不再动
	var monotone := true
	for i in range(600):
		var before := village.population
		ScriptLedger.advance_day(ws)
		if village.population < before:
			monotone = false
	_runner.assert_true(monotone, "人口单调不减")
	_runner.assert_gt(village.population, 62, "兴旺村确实成长")
	_runner.assert_true(village.population < 150, "停滞点在容量内（渐近上限不硬达）")
	var stall := village.population
	ScriptLedger.advance_day(ws)
	ScriptLedger.advance_day(ws)
	_runner.assert_equal(village.population, stall, "停滞后不再变动")
	# logistic × 活力速率可见：城 652 / 容量 3800（活力封顶 2.2），30 日快速增长
	var city := _make_city("settlement_city_002", 652, 3800, 3)
	var ws2 := _make_world([city])
	for i in range(30):
		ScriptLedger.advance_day(ws2)
	_runner.assert_gt(city.population, 652 + 300, "沃土城活力 × logistic 快速成长（30 日 +300 以上）")
	_free_worlds([ws, ws2, ws3])


func _test_level_progression() -> void:
	# 人口跨 652（POP_BANDS 3 档下沿）→ level 2 升 3
	var c := _make_city("settlement_city_003", 640, 2000, 2)
	var ws := _make_world([c])
	while c.population < 652:
		ScriptLedger.advance_day(ws)
	_runner.assert_equal(c.level, 3, "人口跨档带下沿即升档")
	# 只升不降：容量 700 收敛后仍 3 档（670 < 652 不成立，无降档路径）
	# 确定性验证 4/5 档阈值来自 POP_BANDS 同源
	_runner.assert_equal(ScriptLedger.level_from_population(5002), 5, "5002 → 5 档（帝都涌现）")
	_runner.assert_equal(ScriptLedger.level_from_population(2002), 4, "2002 → 4 档")
	_runner.assert_equal(ScriptLedger.level_from_population(222), 2, "222 → 2 档")
	_runner.assert_equal(ScriptLedger.level_from_population(221), 1, "221 → 1 档")
	ws.free()


func _test_wealth_saturation() -> void:
	# 人口先停到停滞点（活力×取整涌现），饱和线随之定档——财富应恰收敛到终态 pop×10
	var c := _make_city("settlement_city_004", 200, 400, 2)
	var ws := _make_world([c])
	c.wealth = 0
	for i in range(400):
		ScriptLedger.advance_day(ws)
	var final_pop := c.population
	_runner.assert_true(final_pop > 200 and final_pop < 400, "人口停到停滞点（容量渐近）")
	_runner.assert_equal(c.wealth, final_pop * 10, "财富收敛至终态 pop×10 饱和（饱和线随人口定档）")
	ScriptLedger.advance_day(ws)
	ScriptLedger.advance_day(ws)
	_runner.assert_equal(c.wealth, final_pop * 10, "饱和后不再增长（自限不通胀）")
	ws.free()


func _test_garrison_replenish() -> void:
	# 目标 = clamp(round(652/130), 2, 12) = 5；从 2 每日 +1 补到 5 需 3 日
	var c := _make_city("settlement_city_005", 652, 700, 3)
	c.garrison = {"stm_spear_001": 2}
	var ws := _make_world([c])
	for i in range(10):
		ScriptLedger.advance_day(ws)
	_runner.assert_equal(int(c.garrison["stm_spear_001"]), 5, "守军补至目标 5")
	ScriptLedger.advance_day(ws)
	ScriptLedger.advance_day(ws)
	_runner.assert_equal(int(c.garrison["stm_spear_001"]), 5, "达标后不再补员（只增不减至目标）")
	ws.free()


func _test_tier_and_legacy() -> void:
	# FOCUS 城跳过（模拟分档：焦点城真实实体模拟，账本不碰）
	var focus := _make_city("settlement_city_006", 100, 200, 1)
	focus.sim_tier = CityState.SimTier.FOCUS
	# cap=0 旧档兼容：静止
	var legacy := _make_city("settlement_city_007", 100, 0, 1)
	var ws := _make_world([focus, legacy])
	for i in range(50):
		ScriptLedger.advance_day(ws)
	_runner.assert_equal(focus.population, 100, "FOCUS 城账本跳过")
	_runner.assert_equal(legacy.population, 100, "cap=0 旧档城市静止")
	ws.free()


func _test_determinism() -> void:
	# 同 seed 构造两个世界 → 100 日后逐城逐字段一致（零随机）
	var build := func() -> Node:
		var ws := ScriptWS.new()
		ws.run_seed = RUN_SEED
		var contract: Dictionary = ScriptInit.build_initial_contract(RUN_SEED)
		ws.cities = contract["cities"]
		ws.factions = contract["factions"]
		return ws
	var a: Node = build.call()
	var b: Node = build.call()
	for i in range(100):
		ScriptLedger.advance_day(a)
		ScriptLedger.advance_day(b)
	var mismatch := 0
	for sid in a.cities:
		var ca: CityState = a.cities[sid]
		var cb: CityState = b.cities[sid]
		if ca.population != cb.population or ca.wealth != cb.wealth \
				or ca.level != cb.level or ca.garrison != cb.garrison:
			mismatch += 1
	_runner.assert_equal(mismatch, 0, "同构世界 100 日轨迹逐城一致（零随机）")
	_free_worlds([a, b])


func _test_save_resume() -> void:
	# 推进 50 日 → 存档 JSON 往返 → 读档续推 10 日 == 不间断续推 10 日
	var contract: Dictionary = ScriptInit.build_initial_contract(RUN_SEED)
	var ws := ScriptWS.new()
	ws.run_seed = RUN_SEED
	ws.cities = contract["cities"].duplicate()
	ws.factions = contract["factions"].duplicate()
	for i in range(50):
		ScriptLedger.advance_day(ws)
	var half: Dictionary = ws.get_save_data()
	var parsed: Variant = JSON.parse_string(JSON.stringify(half))
	_runner.assert_true(parsed is Dictionary, "中途存档 JSON 可解析")
	var ws2 := ScriptWS.new()
	ws2.load_save_data(parsed)
	for i in range(10):
		ScriptLedger.advance_day(ws)
		ScriptLedger.advance_day(ws2)
	var mismatch := 0
	for sid in ws.cities:
		if (ws.cities[sid] as CityState).population != (ws2.cities[sid] as CityState).population:
			mismatch += 1
	_runner.assert_equal(mismatch, 0, "读档续算与不间断推进逐城等价（无 tick 计数器依赖）")
	_free_worlds([ws, ws2])


func _test_real_world_365d() -> void:
	# 真源集成（M2 迭代 1 验收门测试化）：全量 193/1036 推进 365 日——
	# 账面变化可查 + 全域不变量（人口∈(0, cap]、财富≤pop×10、档位与人口一致）
	var t0 := Time.get_ticks_msec()
	var contract: Dictionary = ScriptInit.build_initial_contract(RUN_SEED)
	var ws := ScriptWS.new()
	ws.run_seed = RUN_SEED
	ws.cities = contract["cities"]
	ws.factions = contract["factions"]
	_runner.assert_equal(ws.cities.size(), N_CITIES, "真源装载城数")
	_runner.assert_equal(ws.factions.size(), N_STATES, "真源装载政权数")
	var pop_before := 0
	var wealth_before := 0
	var caps: Dictionary = {}
	var pop0: Dictionary = {}
	for sid in ws.cities:
		var c0: CityState = ws.cities[sid]
		pop_before += c0.population
		wealth_before += c0.wealth
		caps[sid] = c0.pop_capacity
		pop0[sid] = c0.population
	for i in range(365):
		ScriptLedger.advance_day(ws)
	var pop_after := 0
	var wealth_after := 0
	var grew := 0
	var level4_plus := 0
	var invariant_ok := true
	for sid in ws.cities:
		var c: CityState = ws.cities[sid]
		pop_after += c.population
		wealth_after += c.wealth
		if c.population > int(caps[sid]) or c.population <= 0 \
				or c.wealth > roundi(float(c.population) * 10.0):
			invariant_ok = false
		if c.level != maxi(int(c.level), ScriptLedger.level_from_population(c.population)):
			invariant_ok = false
		if c.population > int(pop0[sid]):
			grew += 1
		if c.level >= 4:
			level4_plus += 1
	_runner.assert_true(invariant_ok, "365 日全域不变量（人口∈(0,cap]/财富饱和界/档位一致）")
	_runner.assert_gt(pop_after, pop_before, "世界总人口增长（账面变化可查）")
	_runner.assert_gt(wealth_after, wealth_before, "世界总财富增长")
	_runner.assert_gt(grew, N_CITIES / 2, "过半城市人口可见增长（最小步进保底）")
	print("[world_ledger] 365 日推进: 总人口 %d → %d（+%d），增长城 %d/%d，4/5 档 %d，耗时 %d ms" % [
		pop_before, pop_after, pop_after - pop_before, grew, N_CITIES, level4_plus,
		Time.get_ticks_msec() - t0])
	ws.free()


# ─────────────────────── 日脉冲桥生命周期（审计回归，异步）────────────────────────

## 统计 EventBus 日脉冲上绑定到桥节点的连接数（按桥节点名识别）
func _count_pulse_bridges() -> int:
	var n := 0
	for c in EventBus.world_day_advanced.get_connections():
		var obj: Variant = c["callable"].get_object()
		if obj is Node and (obj as Node).name == &"WorldDayPulseBridge":
			n += 1
	return n


func _test_pulse_bridge_lifecycle() -> void:
	# 审计回归（F1）：连接必须绑定桥节点——菜单往返重建 GameRoot（change_scene_to_file）
	# 后重跑装配，旧 lambda/静态连接残留会叠连多倍日 tick；节点绑定随宿主释放自动断开
	var root1 := Node.new()
	root1.name = "PulseHost1"
	add_child(root1)
	ScriptLedgerSetup.assemble(root1)
	ScriptLedgerSetup.assemble(root1)
	_runner.assert_equal(_count_pulse_bridges(), 1, "同 root 重复装配幂等（恰一条连接）")
	root1.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	_runner.assert_equal(_count_pulse_bridges(), 0, "宿主释放后连接自动断开（无残留）")
	var root2 := Node.new()
	root2.name = "PulseHost2"
	add_child(root2)
	ScriptLedgerSetup.assemble(root2)
	_runner.assert_equal(_count_pulse_bridges(), 1, "重建装配后恰一条新连接（模拟菜单往返再开局）")
	root2.queue_free()
	await get_tree().process_frame
