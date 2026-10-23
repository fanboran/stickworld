extends Node
## 单元测试：world_map L1 下钻可用性 gate（bin 优先探测，L1WorldData.probe_data_file）。
##
## 背景：导出 pck 排除 config/strategic_map 的 *.json（export_presets.cfg），
## 非出生 L1 只有 l1_world.bin——json-only 存在性 gate 在导出包恒 false，
## 切省箭头不列目标、open_l1 报"L1 数据缺失"（2026-10-23 审计 P1）。
##
## 覆盖：probe_data_file 探测口径（bin-only 可用 / bin 优先 / json 兜底 / 包不存在）、
## bin-only 端到端（load_from 传 json 路径而盘上只有 bin → 数据正常装配，不提前失败）、
## has_l1_data 接线（真 l1_packs 存在/缺失 + 出生分支 _birth_data 判定）。

signal test_done(code: int)

const TestRunner := preload("res://tests/core/test_runner.gd")
const L1WorldData := preload("res://modules/world_map/data/l1_world_data.gd")
const WorldMapApiScript := preload("res://modules/world_map/api.gd")

## user:// 假包根目录（每用例自建子目录，收尾统一清理）
const FAKE_ROOT := "user://l1_gate_test"
## 真实 l1_packs 样本（工作区同时有 json+bin，验 has_l1_data 接线走 probe）
const REAL_PACK_001 := "res://config/strategic_map/l1_packs/l1_001"

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("L1Gate: bin 在 json 无 → 探测可用且指向 bin", _test_bin_only_probe)
	_runner.add_test("L1Gate: bin+json 并存 → bin 优先", _test_bin_first)
	_runner.add_test("L1Gate: 仅 json（源码环境）→ 兜底可用", _test_json_fallback)
	_runner.add_test("L1Gate: 包不存在 → 空串不可用", _test_missing_pack)
	_runner.add_test("L1Gate: bin-only 端到端 load_from（json 缺失不提前失败）", _test_bin_only_load)
	_runner.add_test("L1Gate: has_l1_data 接线（真包存在/缺失/出生分支）", _test_has_l1_data_wiring)
	_cleanup_fake_root()  # 清掉上次异常残留，保证用例从干净状态开始
	_runner.run()
	print(_runner.summary())
	_cleanup_fake_root()
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


## 造一个假 L1 包目录，按需写入 l1_world.bin / l1_world.json，返回目录路径
func _make_fake_pack(dir_name: String, write_bin: bool, write_json: bool) -> String:
	var dir := "%s/%s" % [FAKE_ROOT, dir_name]
	var err := DirAccess.make_dir_recursive_absolute(dir)
	if err != OK:
		_runner.assert_true(false, "造假包目录失败: %s（err=%d）" % [dir, err])
		return dir
	if write_bin:
		# 与生成端同格式的最小 LWDB：magic + ver + var_to_bytes(整本 dict)
		var f := FileAccess.open("%s/l1_world.bin" % dir, FileAccess.WRITE)
		f.store_buffer("LWDB".to_ascii_buffer())
		f.store_16(1)  # ver（读端 get_16 后忽略具体值）
		f.store_buffer(var_to_bytes(_fake_world_dict()))
		f.close()
	if write_json:
		var jf := FileAccess.open("%s/l1_world.json" % dir, FileAccess.WRITE)
		jf.store_string(JSON.stringify(_fake_world_dict()))
		jf.close()
	return dir


## 最小可装配世界数据（1 地块即可让 tiles 非空；不写 settlement，纯形状装配）
func _fake_world_dict() -> Dictionary:
	return {
		"map_id": "l1_gate_fake",
		"name": "gate 测试包",
		"size": 64,
		"tiles": [{
			"tile_id": "t1",
			"polygon": [[0, 0], [64, 0], [64, 64]],
		}],
	}


## 删除 FAKE_ROOT 整棵临时目录（先清文件再删目录；不存在则静默跳过）
func _cleanup_fake_root() -> void:
	var root := DirAccess.open(FAKE_ROOT)
	if root == null:
		return
	for pack in root.get_directories():
		var pd := DirAccess.open("%s/%s" % [FAKE_ROOT, pack])
		if pd == null:
			continue
		for fname in pd.get_files():
			pd.remove(fname)
		root.remove(pack)
	var user_da := DirAccess.open("user://")
	if user_da != null:
		user_da.remove(FAKE_ROOT)


func _test_bin_only_probe() -> void:
	var dir := _make_fake_pack("bin_only", true, false)
	var got := L1WorldData.probe_data_file(dir)
	_runner.assert_equal(got, "%s/l1_world.bin" % dir,
			"bin-only（导出包形态）→ 探测返回 bin 路径，判可用")


func _test_bin_first() -> void:
	var dir := _make_fake_pack("bin_first", true, true)
	var got := L1WorldData.probe_data_file(dir)
	_runner.assert_equal(got, "%s/l1_world.bin" % dir, "bin+json 并存 → bin 优先")


func _test_json_fallback() -> void:
	var dir := _make_fake_pack("json_only", false, true)
	var got := L1WorldData.probe_data_file(dir)
	_runner.assert_equal(got, "%s/l1_world.json" % dir, "仅 json（源码环境兜底）→ 返回 json 路径")


func _test_missing_pack() -> void:
	var got := L1WorldData.probe_data_file("%s/no_such_pack" % FAKE_ROOT)
	_runner.assert_equal(got, "", "包不存在 → 空串（不可用）")


func _test_bin_only_load() -> void:
	# 端到端：调用方按 api 契约传同名 .json 路径，盘上只有 bin——
	# load_from 经 _read_data_dict bin 优先解析，json 缺失不得提前失败
	var dir := _make_fake_pack("bin_load", true, false)
	var data: L1WorldData = L1WorldData.load_from("%s/l1_world.json" % dir, dir)
	_runner.assert_true(data != null, "load_from 返回实例")
	_runner.assert_equal(data.map_id, "l1_gate_fake", "bin 数据读出 map_id")
	_runner.assert_true(data.tiles.size() == 1, "bin 数据装配出 1 地块")


func _test_has_l1_data_wiring() -> void:
	var api := Node.new()
	api.set_script(WorldMapApiScript)
	_runner.assert_true(api.has_l1_data(1), "真包 l1_001 存在 → 判可用")
	_runner.assert_true(not api.has_l1_data(999), "l1_999 不存在 → 判不可用")
	# 出生分支只看 _birth_data 是否已载（与文件系统无关）
	_runner.assert_true(not api.has_l1_data(WorldMapApiScript.BIRTH_L1_LABEL),
			"出生 L1 无 _birth_data → 不可用")
	api.set("_birth_data", L1WorldData.new())
	_runner.assert_true(api.has_l1_data(WorldMapApiScript.BIRTH_L1_LABEL),
			"出生 L1 已载 _birth_data → 可用")
	api.free()
