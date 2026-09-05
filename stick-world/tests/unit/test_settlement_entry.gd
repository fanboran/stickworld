extends Node
## 单元测试：聚落进城数据闭环（P5/D1，总体设计 §5.8）。
##
## 覆盖：l1_world 8 聚落 map_id 回填（bin 优先路径）/ 8 张场景 .tscn 存在且关键结构
## 完整（defs_json_path 指向对应建筑 JSON、无 ChunkTrigger 出口——城内边界回图走
## MapBoundaryDetector）/ 初始建筑 def_id 全部合法（对照 building_gen 注册表）/
## 建筑布局与聚落级别匹配（T3 兵营+tier2 城墙，T2 tier1 城墙无兵营）/
## game_root 预载 8 张聚落场景（进城注册的静态侧）。

signal test_done(code: int)

const TestRunner := preload("res://tests/core/test_runner.gd")
const L1WorldData := preload("res://modules/world_map/data/l1_world_data.gd")
const BuildingGenApi := preload("res://modules/building_gen/api.gd")
const ScriptGameRoot := preload("res://modules/world/scripts/game_root.gd")

const MAPS_DIR := "res://modules/world/scenes/maps"
const DEFS_DIR := "res://config/strategic_map/buildings"

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("map_id: 8 聚落回填且唯一", _test_map_ids)
	_runner.add_test("tscn: 8 场景存在 + 结构与出口语义", _test_scenes)
	_runner.add_test("JSON: 初始建筑存在且 def_id 合法", _test_building_defs)
	_runner.add_test("布局: 建筑与聚落级别匹配", _test_level_layout)
	_runner.add_test("注册: game_root 预载 8 张聚落场景", _test_game_root_scenes)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _load_world():
	return L1WorldData.load_from("res://config/strategic_map/l1_world.json", "res://config/strategic_map")


func _test_map_ids() -> void:
	var world = _load_world()
	_runner.assert_true(world != null, "出生 L1 可加载")
	var ids: Array = []
	for tile in world.tiles:
		if tile.settlement != null:
			ids.append(tile.settlement.map_id)
	_runner.assert_true(ids.size() == 8, "8 个聚落带 map_id（实测 %d）" % ids.size())
	var unique := {}
	for m in ids:
		unique[m] = true
	_runner.assert_true(unique.size() == ids.size(), "map_id 无重复")
	var all_prefixed := true
	for m in ids:
		if not String(m).begins_with("l1_settlement_"):
			all_prefixed = false
	_runner.assert_true(all_prefixed, "map_id 全部为 l1_settlement_ 前缀")


func _test_scenes() -> void:
	for i in 8:
		var p := "%s/l1_settlement_%02d.tscn" % [MAPS_DIR, i]
		if not FileAccess.file_exists(p):
			_runner.assert_true(false, "场景缺失: %s" % p)
			return
		var text := FileAccess.get_file_as_string(p)
		if not text.contains("defs_json_path = \"%s/l1_settlement_%02d.json\"" % [DEFS_DIR, i]):
			_runner.assert_true(false, "%02d 缺 defs_json_path 指向自身建筑 JSON" % i)
			return
		if text.contains("ExitRight"):
			_runner.assert_true(false, "%02d 不应含 ChunkTrigger 出口（边界回图走 MapBoundaryDetector）" % i)
			return
		if not text.contains("res://modules/world/scripts/map/village_map.gd"):
			_runner.assert_true(false, "%02d 根节点未挂 village_map.gd" % i)
			return
	_runner.assert_true(true, "8 张 tscn 存在 + defs_json_path + 无出口触发器 + VillageMap 脚本")


func _test_building_defs() -> void:
	var legal: Array = BuildingGenApi.get_default_building_def_ids()
	for i in 8:
		var p := "%s/l1_settlement_%02d.json" % [DEFS_DIR, i]
		if not FileAccess.file_exists(p):
			_runner.assert_true(false, "建筑 JSON 缺失: %s" % p)
			return
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
		if not (data is Dictionary) or not ((data as Dictionary).get("buildings") is Array) \
				or (data as Dictionary)["buildings"].is_empty():
			_runner.assert_true(false, "%02d buildings 缺失或为空" % i)
			return
		for b: Variant in (data as Dictionary)["buildings"]:
			if not legal.has((b as Dictionary).get("def_id")):
				_runner.assert_true(false, "%02d 非法 def_id: %s" % [i, (b as Dictionary).get("def_id")])
				return
	_runner.assert_true(true, "8 份 JSON 存在、非空、def_id 全部合法")


func _test_level_layout() -> void:
	var world = _load_world()
	if world == null:
		_runner.assert_true(false, "出生 L1 加载失败")
		return
	var width_by_level := {3: "6144", 2: "4096", 1: "2560"}
	var checked := 0
	for tile in world.tiles:
		var s = tile.settlement
		if s == null or s.map_id.is_empty():
			continue
		var idx := int(s.map_id.substr("l1_settlement_".length()))
		var scene_text := FileAccess.get_file_as_string("%s/l1_settlement_%02d.tscn" % [MAPS_DIR, idx])
		var expect_w: String = width_by_level.get(s.level, "")
		_runner.assert_true(expect_w != "" and scene_text.contains(expect_w),
				"%s T%d 场景宽度应为 %s" % [s.name, s.level, expect_w])
		var defs: Variant = JSON.parse_string(FileAccess.get_file_as_string(
				"%s/l1_settlement_%02d.json" % [DEFS_DIR, idx]))["buildings"]
		var ids: PackedStringArray = []
		for b: Variant in defs:
			ids.append((b as Dictionary).get("def_id"))
		if s.level == 3:
			_runner.assert_true(ids.has("barracks") and ids.has("wall_tier2"),
					"%s T3 城市应含兵营 + tier2 城墙" % s.name)
		elif s.level == 2:
			_runner.assert_true(ids.has("wall_tier1") and not ids.has("barracks"),
					"%s T2 镇应含 tier1 城墙且无兵营" % s.name)
		checked += 1
	_runner.assert_true(checked == 8, "布局核对 8 聚落（实测 %d）" % checked)


func _test_game_root_scenes() -> void:
	var scenes: Array = ScriptGameRoot._L1_SETTLEMENT_SCENES
	_runner.assert_true(scenes.size() == 8, "game_root 预载 8 张聚落场景（实测 %d）" % scenes.size())
	var all_valid := true
	for s: Variant in scenes:
		if not (s is PackedScene):
			all_valid = false
	_runner.assert_true(all_valid, "8 张场景全部为有效 PackedScene")
