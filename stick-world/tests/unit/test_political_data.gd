extends Node
## 单元测试：政权简化版数据一致性（P7/F1，总体设计 §5.11）。
##
## 覆盖：political_data.json 全量覆盖（1040 城无缺漏/无孤儿）/ 归属合法性
## / 出生 8 城邦沿用 l1_world.json 原样（state_id+色不变）/ l3_city 注入一致
## / L2 packs cities 注入一致 / 碎度硬指标（国数下限 + 单国城数上限软约束窗口）
## / L3WorldData.states 装载。

signal test_done(code: int)

const TestRunner := preload("res://tests/core/test_runner.gd")
const L3WorldData := preload("res://modules/world_map/data/l3_world_data.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("political_data: 城主表全量覆盖", _test_full_coverage)
	_runner.add_test("political_data: 归属全部合法", _test_owners_legal)
	_runner.add_test("出生 8 城邦原样沿用（id+色不变）", _test_birth_states_preserved)
	_runner.add_test("l3_city 注入与真相源一致", _test_l3_city_injection)
	_runner.add_test("L2 packs 注入一致（13 地区）", _test_l2_injection)
	_runner.add_test("碎度：国数下限 + 城邦国体", _test_fragmentation)
	_runner.add_test("L3WorldData.states 装载（bin 路径）", _test_l3_states_loaded)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _read_json(path: String) -> Dictionary:
	var txt := FileAccess.get_file_as_string(path)
	if txt.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(txt)
	return parsed if parsed is Dictionary else {}


func _test_full_coverage() -> void:
	var pd := _read_json("res://config/strategic_map/political_data.json")
	_runner.assert_true(not pd.is_empty(), "political_data.json 可读")
	var owners: Dictionary = pd.get("city_owners", {})
	var l3 := _read_json("res://config/strategic_map/l3_city.json")
	var expect := 0
	for t in (l3.get("tiles", []) as Array):
		expect += 1
	_runner.assert_equal(owners.size(), expect, "城主表 = l3_city 城总数")
	var empty := []
	for k in owners:
		if str(owners[k]).is_empty():
			empty.append(k)
	_runner.assert_true(empty.is_empty(), "无空归属（%d 个）" % empty.size())


func _test_owners_legal() -> void:
	var pd := _read_json("res://config/strategic_map/political_data.json")
	var states: Dictionary = pd.get("states", {})
	var bad := 0
	for k in pd.get("city_owners", {}):
		if not states.has(pd["city_owners"][k]):
			bad += 1
	_runner.assert_equal(bad, 0)
	# 每个 state 结构完整（完整版字段预留：alliance 可空但键在）
	var missing := 0
	for sid in states:
		var sd: Dictionary = states[sid]
		for f in ["name", "capital", "culture", "alliance", "color"]:
			if not sd.has(f):
				missing += 1
	_runner.assert_equal(missing, 0)


func _test_birth_states_preserved() -> void:
	var birth := _read_json("res://config/strategic_map/l1_world.json")
	var pd := _read_json("res://config/strategic_map/political_data.json")
	var states: Dictionary = pd.get("states", {})
	var owners: Dictionary = pd.get("city_owners", {})
	var ok := true
	for s in (birth.get("states", []) as Array):
		var sid: String = s["state_id"]
		if not states.has(sid):
			ok = false
			break
		if states[sid].get("color", []) != s.get("color", []):
			ok = false
			break
	_runner.assert_true(ok, "出生 states 的 id/色在 political_data 中原样")
	var n_city_state := 0
	for sid in states:
		if states[sid].get("is_city_state", false):
			n_city_state += 1
	_runner.assert_equal(n_city_state, 8)
	for tl in (birth.get("tiles", []) as Array):
		var s: Dictionary = tl.get("settlement", {})
		_runner.assert_equal(str(owners.get(s.get("settlement_id", ""), "")),
				str(tl.get("owner_state_id", "")), "出生城归属沿用 owner_state_id")


func _test_l3_city_injection() -> void:
	var pd := _read_json("res://config/strategic_map/political_data.json")
	var owners: Dictionary = pd.get("city_owners", {})
	var l3 := _read_json("res://config/strategic_map/l3_city.json")
	var mismatch := 0
	var missing := 0
	for t in (l3.get("tiles", []) as Array):
		var sid: String = "settlement_city_%03d" % int(t.get("label", 0))
		if not t.has("state_id"):
			missing += 1
		elif str(t["state_id"]) != str(owners.get(sid, "")):
			mismatch += 1
	_runner.assert_equal(missing, 0)
	_runner.assert_equal(mismatch, 0)
	var states: Dictionary = l3.get("states", {})
	_runner.assert_equal(states.size(), pd.get("states", {}).size(), "l3_city 顶层 states 与真相源同规模")


func _test_l2_injection() -> void:
	var pd := _read_json("res://config/strategic_map/political_data.json")
	var owners: Dictionary = pd.get("city_owners", {})
	var dir := "res://config/strategic_map/l2_packs"
	var regions := 0
	var bad := 0
	for i in range(1, 14):
		var p := "%s/region_%03d/l2_world.json" % [dir, i]
		if not FileAccess.file_exists(p):
			bad += 1
			continue
		regions += 1
		var w := _read_json(p)
		if w.get("states", {}).size() != pd.get("states", {}).size():
			bad += 1
			continue
		for c in (w.get("cities", []) as Array):
			if str(c.get("state_id", "")) != str(owners.get(c.get("id", ""), "")):
				bad += 1
	_runner.assert_equal(regions, 13)
	_runner.assert_equal(bad, 0)


func _test_fragmentation() -> void:
	var pd := _read_json("res://config/strategic_map/political_data.json")
	var states: Dictionary = pd.get("states", {})
	_runner.assert_true(states.size() >= 20,
			"国数 >= 20（碎国，实测 %d）" % states.size())
	_runner.assert_true(states.size() <= 60, "国数 <= 60（不至于过碎）")
	var counts := {}
	for k in pd.get("city_owners", {}):
		var sid: String = pd["city_owners"][k]
		counts[sid] = int(counts.get(sid, 0)) + 1
	var max_n := 0
	for sid in counts:
		max_n = maxi(max_n, int(counts[sid]))
	_runner.assert_true(max_n <= 120,
			"单国城数 <= 120（均衡系数软约束窗口，实测 %d）" % max_n)


func _test_l3_states_loaded() -> void:
	var data = L3WorldData.load_from(
			"res://config/strategic_map/l3_world.json", "res://config/strategic_map")
	_runner.assert_true(data != null, "L3 数据可加载")
	_runner.assert_true(data.states.size() >= 20,
			"states 经 bin 装载（实测 %d）" % data.states.size())
	var has_state_id := false
	for t in data.city_tiles:
		if str(t.get("state_id", "")).begins_with("state_"):
			has_state_id = true
			break
	_runner.assert_true(has_state_id, "city_tiles[].state_id 透传")
