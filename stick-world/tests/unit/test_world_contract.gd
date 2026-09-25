extends Node
## 单元测试：世界契约初始化器（世界模型整合 M1——mapdata 真源 → CityState/FactionState
## 全量装载）。
##
## 覆盖：装载数量（176 政权 + 1036 城，V2 世界重生成）/ 零悬空（城→政权、政权→都城双向）/ 字段保真
## （全量含单城邦/最大国/中位国）/ 聚合对齐（faction_tile_count == n_cities、总和 == 1036）/
## 人口推导（同 seed 确定性、档位量级单调、出生城免疫精确值、自然数不整十扎堆）/
## tile_key 映射（含 3 位零填充）/ level 锚点（生成端档位口径守护）/ garrison 账面
## 形状（实存 profile id + 档位编成）/ l3_city.json 与 bin 装载一致（防 bin 陈旧）/
## 玩家政权共存（start_new_run 生产路径）/ 存档往返兼容 / 装载耗时观测。
## 纯数据层测试：preload 脚本 new() 即用，不依赖 autoload 单例（WorldState 用
## ScriptWS.new()，start_new_run 走生产同一路径）。

signal test_done(code: int)

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptWS := preload("res://core/autoload/world_state.gd")
const ScriptInit := preload("res://core/entities/world_contract_initializer.gd")

const N_STATES := 176
const N_CITIES := 1036
## 固定测试种子（确定性断言用；start_new_run 路径由其内部 randi() 定种子）
const RUN_SEED := 20260925

## level 锚点（WorldContractInitializer.level_from_score 反推阈值的守护：阈值/
## 口径漂移即红灯；期望值 = V2 生成端 settlement_build 同阈值口径的 level）
const LEVEL_ANCHORS := {
	"settlement_city_001": 1,   # ps 0.1441（村）
	"settlement_city_427": 2,   # ps 0.2882（镇；出生点）
	"settlement_city_056": 3,   # ps 0.3428（城；近阈值边界守护）
}

## 出生聚落（population 每局扰动免疫）→ 人口可精确断言（档内插值无抖动）
## V2 出生点 = 关洋湾都城 settlement_city_427（2 城小国，出生包 l1_049）
const SPAWN_ID := "settlement_city_427"
const SPAWN_EXPECT_POP := 415

var _runner: TestRunner
## 只读共享夹具：构建含大文件装载，逐用例重建会拖垮批量窗口；
## build_initial_contract 为纯函数，跨用例只读共享安全（变更型用例自建 ws）
var _contract: Dictionary
var _build_ms := 0


func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	_contract = ScriptInit.build_initial_contract(RUN_SEED)
	_build_ms = Time.get_ticks_msec() - t0
	print("[world_contract] 单次全量装载耗时: %d ms（political_data.json + l3_city bin 优先）" % _build_ms)
	_runner = TestRunner.new()
	_runner.add_test("world_contract: 全量装载 176 政权 + 1036 城", _test_load_counts)
	_runner.add_test("world_contract: 零悬空（城→政权 / 政权→都城）", _test_no_dangling)
	_runner.add_test("world_contract: 字段保真（最大国/单城邦/中位国抽样）", _test_field_fidelity)
	_runner.add_test("world_contract: 聚合对齐（tile 数 == n_cities，总和 1036）", _test_aggregates)
	_runner.add_test("world_contract: 人口推导（确定性/免疫精确值）", _test_population_determinism)
	_runner.add_test("world_contract: 人口档位量级单调 + 不整十扎堆", _test_population_bands)
	_runner.add_test("world_contract: tile_key 映射（同源 label 零填充）", _test_tile_key)
	_runner.add_test("world_contract: level 锚点 == 生成端口径", _test_level_anchors)
	_runner.add_test("world_contract: garrison 账面形状（实存 profile id/档位编成）", _test_garrison_shape)
	_runner.add_test("world_contract: l3_city.json 与 bin 装载一致（防 bin 陈旧）", _test_bin_json_consistency)
	_runner.add_test("world_contract: 玩家政权共存（start_new_run 生产路径）", _test_player_coexistence)
	_runner.add_test("world_contract: 存档往返兼容（save/load 后两域完好）", _test_save_roundtrip)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _read_json(path: String) -> Dictionary:
	var txt := FileAccess.get_file_as_string(path)
	if txt.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(txt)
	return parsed if parsed is Dictionary else {}


func _cities() -> Dictionary:
	return _contract["cities"]


func _factions() -> Dictionary:
	return _contract["factions"]


func _test_load_counts() -> void:
	_runner.assert_equal(_factions().size(), N_STATES, "政权数 176（实测 %d）" % _factions().size())
	_runner.assert_equal(_cities().size(), N_CITIES, "城市数 1036（实测 %d）" % _cities().size())
	# 装载耗时观测（无硬阈值——CI 磁盘差异大，超常在汇总里人眼看）
	_runner.assert_true(_build_ms >= 0, "装载耗时可测（%d ms）" % _build_ms)


func _test_no_dangling() -> void:
	var factions: Dictionary = _factions()
	var cities: Dictionary = _cities()
	var bad_owner := 0
	for settlement_id in cities:
		var c: CityState = cities[settlement_id]
		if not factions.has(c.owner_state_id):
			bad_owner += 1
	_runner.assert_equal(bad_owner, 0, "每城 owner 必在政权表（悬空 %d）" % bad_owner)
	var bad_cap := 0
	for state_id in factions:
		var f: FactionState = factions[state_id]
		if f.capital_settlement_id.is_empty() or not cities.has(f.capital_settlement_id):
			bad_cap += 1
	_runner.assert_equal(bad_cap, 0, "每政权 capital 必在城表（悬空/空 %d）" % bad_cap)


func _test_field_fidelity() -> void:
	var pd := _read_json("res://config/strategic_map/political_data.json")
	var states: Dictionary = pd.get("states", {})
	var owners: Dictionary = pd.get("city_owners", {})
	var factions: Dictionary = _factions()
	# 抽样 3 行：最大国（18 城）/ 单城邦 / 中位国——name/capital/lut_index 与 json 一致
	for sid in ["state_v2_036", "state_v2_004", "state_v2_175"]:
		var f: FactionState = factions.get(sid)
		_runner.assert_not_null(f, "政权 %s 已装载" % sid)
		if f == null:
			continue
		var sd: Dictionary = states.get(sid, {})
		_runner.assert_equal(f.name, str(sd.get("name", "")), "%s name 保真" % sid)
		_runner.assert_equal(f.capital_settlement_id, str(sd.get("capital", "")), "%s capital 保真" % sid)
		_runner.assert_equal(f.lut_index, int(sd.get("lut_index", -1)), "%s lut_index 保真" % sid)
	var cities: Dictionary = _cities()
	for sid in ["settlement_city_001", "settlement_city_395", "settlement_city_714"]:
		var c: CityState = cities.get(sid)
		_runner.assert_not_null(c, "城 %s 已装载" % sid)
		if c == null:
			continue
		_runner.assert_equal(c.owner_state_id, str(owners.get(sid, "")), "%s 归属保真" % sid)


func _test_aggregates() -> void:
	var pd := _read_json("res://config/strategic_map/political_data.json")
	var states: Dictionary = pd.get("states", {})
	var ws := ScriptWS.new()
	ws.run_seed = RUN_SEED
	ScriptInit.apply_to_world_state(ws)
	# 抽 3 政权（最大国 18 城 / 单城邦 / 中位国）：faction_tile_count == n_cities
	for sid in ["state_v2_036", "state_v2_004", "state_v2_175"]:
		var want := int(states[sid].get("n_cities", -1))
		_runner.assert_equal(ws.faction_tile_count(sid), want,
				"%s tile 数 == n_cities（%d）" % [sid, want])
	# 全 176 政权城数总和 == 1036；玩家壳不占城
	var total := 0
	for sid in ws.factions:
		if sid == "player":
			continue
		total += ws.faction_tile_count(str(sid))
	_runner.assert_equal(total, N_CITIES, "176 政权城数总和 == 1036（实测 %d）" % total)
	_runner.assert_equal(ws.faction_tile_count("player"), 0, "玩家壳 0 城")
	ws.free()


func _test_population_determinism() -> void:
	var cities: Dictionary = _cities()
	# 出生聚落免疫每局扰动 → 人口与 seed 无关，可精确断言（档内插值基准值）
	var spawn: CityState = cities.get(SPAWN_ID)
	_runner.assert_not_null(spawn, "出生城已装载")
	if spawn != null:
		_runner.assert_equal(spawn.population, SPAWN_EXPECT_POP,
				"出生城人口精确（免疫扰动，期望 %d）" % SPAWN_EXPECT_POP)
	# 同 seed 两次构建逐城相等（population + garrison）
	var again: Dictionary = ScriptInit.build_initial_contract(RUN_SEED)["cities"]
	_runner.assert_equal(again.size(), cities.size(), "复建规模一致")
	var diff_pop := 0
	var diff_gar := 0
	for settlement_id in cities:
		var a: CityState = cities[settlement_id]
		var b: CityState = again.get(settlement_id)
		if b == null:
			diff_pop += 1
			continue
		if a.population != b.population:
			diff_pop += 1
		if a.garrison != b.garrison:
			diff_gar += 1
	_runner.assert_equal(diff_pop, 0, "同 seed 人口逐城相等（差异 %d）" % diff_pop)
	_runner.assert_equal(diff_gar, 0, "同 seed 守军逐城相等（差异 %d）" % diff_gar)
	# 自然数正值
	var bad := 0
	for settlement_id in cities:
		var c: CityState = cities[settlement_id]
		if c.population < 1:
			bad += 1
	_runner.assert_equal(bad, 0, "人口为自然数正值（异常 %d）" % bad)


func _test_population_bands() -> void:
	var cities: Dictionary = _cities()
	# 按档收集实际人口（全量 1036，非抽样）
	var pops := {1: [], 2: [], 3: []}
	var n_mod10 := 0
	for settlement_id in cities:
		var c: CityState = cities[settlement_id]
		pops[c.level].append(c.population)
		if c.population % 10 == 0:
			n_mod10 += 1
	for lv in pops:
		(pops[lv] as Array).sort()
	# 档位量级单调（档间自然断层）：max(低档) < min(高档)
	_runner.assert_true(pops[1].size() > 0 and pops[2].size() > 0 and pops[3].size() > 0,
			"三档城均有出现（%d/%d/%d）" % [pops[1].size(), pops[2].size(), pops[3].size()])
	if pops[1].is_empty() or pops[2].is_empty() or pops[3].is_empty():
		return
	var max1: int = pops[1][pops[1].size() - 1]
	var min2: int = pops[2][0]
	var max2: int = pops[2][pops[2].size() - 1]
	var min3: int = pops[3][0]
	_runner.assert_true(max1 < min2, "村上限 %d < 镇下限 %d（量级单调）" % [max1, min2])
	_runner.assert_true(max2 < min3, "镇上限 %d < 城下限 %d（量级单调）" % [max2, min3])
	# 量级口径：村几十~一两百、城数百（命名与数值口径.md §二）
	_runner.assert_true(max1 <= 200, "村档 ≤ 200 量级（实测 max %d）" % max1)
	_runner.assert_true(min3 >= 600, "城档 ≥ 600 量级（实测 min %d）" % min3)
	# 不整十扎堆：连续映射 + 抖动下整十占比应远低于扎堆水平（≈1/10 均匀）
	var ratio := float(n_mod10) / float(cities.size())
	_runner.assert_true(ratio < 0.2,
			"整十占比 %.1f%%（%d/%d）不扎堆" % [ratio * 100.0, n_mod10, cities.size()])


func _test_tile_key() -> void:
	var cities: Dictionary = _cities()
	# 抽样含 2 位数（零填充）与 4 位数（自然位数）：%03d 为最小 3 位零填充
	for check in [["settlement_city_001", "city_001"], ["settlement_city_050", "city_050"],
			["settlement_city_641", "city_641"], ["settlement_city_1036", "city_1036"]]:
		var c: CityState = cities.get(str(check[0]))
		_runner.assert_not_null(c, "城 %s 已装载" % check[0])
		if c == null:
			continue
		_runner.assert_equal(c.tile_key, str(check[1]), "%s tile_key 同源映射" % check[0])


func _test_level_anchors() -> void:
	var cities: Dictionary = _cities()
	for settlement_id in LEVEL_ANCHORS:
		var c: CityState = cities.get(str(settlement_id))
		_runner.assert_not_null(c, "锚点城 %s 已装载" % settlement_id)
		if c == null:
			continue
		_runner.assert_equal(c.level, int(LEVEL_ANCHORS[settlement_id]),
				"%s level == 生成端口径 %d（阈值守护）" % [settlement_id, int(LEVEL_ANCHORS[settlement_id])])


func _test_garrison_shape() -> void:
	var legal := {"stm_spear_001": true, "stm_sword_001": true, "stm_bow_001": true}
	var cities: Dictionary = _cities()
	var bad_key := 0
	var bad_val := 0
	var bad_range := 0
	var bad_comp := 0
	for settlement_id in cities:
		var c: CityState = cities[settlement_id]
		var total := 0
		for profile_id in c.garrison:
			if not legal.has(str(profile_id)):
				bad_key += 1
			var n := int(c.garrison[profile_id])
			if n < 1:
				bad_val += 1
			total += n
		if total < 2 or total > 12:
			bad_range += 1
		# 档位编成：1 档单一长枪；3 档三兵种齐备
		if c.level == 1 and c.garrison.size() != 1:
			bad_comp += 1
		if c.level >= 3 and c.garrison.size() != 3:
			bad_comp += 1
	_runner.assert_equal(bad_key, 0, "garrison 键全为实存 profile id（异常 %d）" % bad_key)
	_runner.assert_equal(bad_val, 0, "garrison 计数全 ≥ 1（异常 %d）" % bad_val)
	_runner.assert_equal(bad_range, 0, "garrison 总兵力在 [2,12]（越界 %d）" % bad_range)
	_runner.assert_equal(bad_comp, 0, "档位编成形状（异常 %d）" % bad_comp)


func _test_bin_json_consistency() -> void:
	# 初始化器走 bin 优先装载；此处直读 json 真源全量比对——bin 陈旧（json 重生成
	# 而未重烘 bin）时阈值级 level 比对必红灯
	var l3 := _read_json("res://config/strategic_map/l3_city.json")
	_runner.assert_true(not l3.is_empty(), "l3_city.json 可读")
	if l3.is_empty():
		return
	var cities: Dictionary = _cities()
	var mismatch := 0
	for t in (l3.get("tiles", []) as Array):
		var td: Dictionary = t
		var sid := "settlement_city_%03d" % int(td.get("label", 0))
		var c: CityState = cities.get(sid)
		if c == null:
			mismatch += 1
			continue
		if ScriptInit.level_from_score(float(td.get("population_score", 0.0))) != c.level:
			mismatch += 1
	_runner.assert_equal(mismatch, 0, "bin 装载与 json 真源逐城一致（%d 城，差异 %d）"
			% [cities.size(), mismatch])


func _test_player_coexistence() -> void:
	var ws := ScriptWS.new()
	ws.start_new_run()
	_runner.assert_equal(ws.factions.size(), N_STATES + 1, "开局 176 AI 政权 + 玩家壳（实测 %d）" % ws.factions.size())
	_runner.assert_equal(ws.cities.size(), N_CITIES, "开局 1036 城（实测 %d）" % ws.cities.size())
	# 玩家壳不被灌入冲掉（merge 非覆盖）
	var player: FactionState = ws.get_entity("factions", "player")
	_runner.assert_not_null(player, "玩家政权壳保留")
	if player != null:
		_runner.assert_equal(player.name, "玩家政权", "玩家壳 name 保留")
	# 真源无 "player" id（防御断言：灌入域与玩家 id 无冲突）
	_runner.assert_false(_factions().has("player"), "真源 176 表不含玩家保留 id")
	# 幂等：重复 start_new_run 全量重置不翻倍
	ws.start_new_run()
	_runner.assert_equal(ws.factions.size(), N_STATES + 1, "重复开局政权数不翻倍")
	_runner.assert_equal(ws.cities.size(), N_CITIES, "重复开局城市数不翻倍")
	ws.free()


func _test_save_roundtrip() -> void:
	var ws := ScriptWS.new()
	ws.start_new_run()
	var pop_before := ws.faction_population("state_v2_036")
	var gar_before := ws.faction_garrison_total("state_v2_175")
	var save: Dictionary = ws.get_save_data()
	# JSON 往返（int→float 是存档管线真实口径）
	var parsed: Variant = JSON.parse_string(JSON.stringify(save))
	_runner.assert_true(parsed is Dictionary, "存档 JSON 可解析")
	if not (parsed is Dictionary):
		ws.free()
		return
	var ws2 := ScriptWS.new()
	ws2.load_save_data(parsed)
	_runner.assert_equal(ws2.factions.size(), N_STATES + 1, "读档政权域完好（含玩家壳）")
	_runner.assert_equal(ws2.cities.size(), N_CITIES, "读档城市域完好")
	_runner.assert_equal(ws2.faction_population("state_v2_036"), pop_before, "政权聚合人口往返保真")
	_runner.assert_equal(ws2.faction_garrison_total("state_v2_175"), gar_before, "政权聚合兵力往返保真")
	ws.free()
	ws2.free()
