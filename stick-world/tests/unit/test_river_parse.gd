extends Node
## 单元测试：河流矢量解析（B3，总体设计 §5.4）。
##
## 覆盖：L1WorldData.rivers 装配（bin 优先路径）/ world_origin 解析 / 折线坐标界内
## / L2WorldData.rivers 的 [y,x]→Vector2(x,y) 归一化 / 无 rivers 字段兜底不炸。

signal test_done(code: int)

const TestRunner := preload("res://tests/core/test_runner.gd")
const L1WorldData := preload("res://modules/world_map/data/l1_world_data.gd")
const L2WorldData := preload("res://modules/world_map/data/l2_world_data.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("L1: rivers 装配（bin 优先路径）", _test_l1_rivers)
	_runner.add_test("L1: world_origin 解析", _test_l1_world_origin)
	_runner.add_test("L1: 折线坐标界内 + 宽度下限", _test_l1_bounds)
	_runner.add_test("L2: rivers [y,x] 归一化", _test_l2_rivers)
	_runner.add_test("无 rivers 字段兜底", _test_missing_field)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _test_l1_rivers() -> void:
	var world = L1WorldData.load_from("res://config/strategic_map/l1_world.json", "res://config/strategic_map")
	_runner.assert_true(world != null, "出生 L1 可加载")
	_runner.assert_true(world.rivers.size() > 0, "出生 L1 rivers 非空（该地块有河穿过）")
	var all_lines := true
	for rv in world.rivers:
		if not (rv.get("pts") is PackedVector2Array) or rv["pts"].size() < 2:
			all_lines = false
			break
	_runner.assert_true(all_lines, "每条河流 pts 为 PackedVector2Array 且 ≥2 点")


func _test_l1_world_origin() -> void:
	var world = L1WorldData.load_from("res://config/strategic_map/l1_world.json", "res://config/strategic_map")
	_runner.assert_true(world != null and world.world_origin != Vector2i.ZERO,
			"world_origin 从 JSON 读出（出生 L1 在大陆内陆，原点非零）")


func _test_l1_bounds() -> void:
	var world = L1WorldData.load_from("res://config/strategic_map/l1_world.json", "res://config/strategic_map")
	if world == null or world.rivers.is_empty():
		_runner.assert_true(false, "前置失败：无 rivers 数据")
		return
	var ctx: Vector2i = world.context_size
	var in_bounds := true
	var width_ok := true
	for rv in world.rivers:
		var pts: PackedVector2Array = rv["pts"]
		for p in pts:
			if p.x < -1.0 or p.y < -1.0 or p.x > ctx.x + 1.0 or p.y > ctx.y + 1.0:
				in_bounds = false
		if float(rv.get("w", 0.0)) <= 0.0:
			width_ok = false
	_runner.assert_true(in_bounds, "全部折线点落在 context 界内（±1px 容差）")
	_runner.assert_true(width_ok, "全部河宽 > 0")


func _test_l2_rivers() -> void:
	var world = L2WorldData.load_from(
		"res://config/strategic_map/l2_packs/region_013/l2_world.json",
		"res://config/strategic_map/l2_packs/region_013")
	_runner.assert_true(world != null, "region_013 可加载")
	_runner.assert_true(world.rivers.size() > 0, "region_013 rivers 非空")
	# [y,x] → Vector2(x,y) 抽查：与 json 原始首点对照
	var raw_text := FileAccess.get_file_as_string(
		"res://config/strategic_map/l2_packs/region_013/l2_world.json")
	var parsed: Variant = JSON.parse_string(raw_text)
	if not (parsed is Dictionary):
		_runner.assert_true(false, "json 原文可解析")
		return
	var raw_rivers: Array = parsed["rivers"]
	var first_raw: Array = raw_rivers[0]["pts"][0]
	var first_rv: Dictionary = world.rivers[0]
	var first: Vector2 = first_rv["pts"][0]
	_runner.assert_equal(first, Vector2(float(first_raw[1]), float(first_raw[0])),
			"[y,x] 首点归一化为 Vector2(x,y)")


func _test_missing_field() -> void:
	# L1 bin/json 均无 rivers 字段的旧包：空数组兜底
	var v: Array = []
	var out = L1WorldData._rivers_from(v)
	_runner.assert_equal(out.size(), 0, "空输入 → 空数组")
	var junk: Array = ["not_a_dict", {}]
	var out2 = L1WorldData._rivers_from(junk)
	_runner.assert_equal(out2.size(), 0, "非 dict/无 pts 条目被安全跳过")
