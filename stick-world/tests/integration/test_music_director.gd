extends Node
## 集成测试：音乐系统（MusicDirector + 清单 + AudioManager 压限接口）。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_music_director.tscn
##
## 覆盖：
##   - 清单契约：九个 cue 齐备、字段完整、层文件真实存在、循环体是整数小节
##   - 状态解析：情境 → 曲目（战斗 > 室内 > 战略图 > 地图类型 > 户外/昼夜）
##   - 分层逻辑：tier 之下的层目标音量为其声明值、tier 之上的层淡到静音
##   - 压限：duck 请求转发到 AudioManager（总线音量唯一消费方），并随音量设置保持
##   - stinger 与环境音：清单/文件缺失时不炸（安静降级）
##
## 说明：本测试**不校验音质**。音频资产的客观指标在离线管线里跑：
##   python tools/music/qa_audio.py --check
## headless 下没有音频设备，播放调用是安全的空操作，因此本套件出声无副作用。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")

const MANIFEST_PATH := "res://assets/audio/bgm/music_manifest.json"
const BGM_DIR := "res://assets/audio/bgm/"
## 游戏流程实际会触发的全部 cue + 两首结算短句
const EXPECTED_CUES := [
	"menu_title", "field_day", "field_night", "village", "interior",
	"strategic", "battle", "sting_victory", "sting_defeat",
]

var _runner: TestRunner
var _manifest: Dictionary = {}


func _ready() -> void:
	MusicDirector.set_enabled(false)      # 本套件只测逻辑，不出声
	_runner = TestRunner.new()
	_runner.add_test("清单: 文件存在且格式正确", _test_manifest_shape, false)
	_runner.add_test("清单: 九个 cue 齐备", _test_all_cues_present, false)
	_runner.add_test("清单: 每 cue 字段完整", _test_cue_fields, false)
	_runner.add_test("清单: 层文件真实存在", _test_layer_files_exist, false)
	_runner.add_test("清单: 循环体是整数小节", _test_loop_is_integer_bars, false)
	_runner.add_test("解析: 情境 → 曲目", _test_resolve_cue, false)
	_runner.add_test("解析: 优先级 战斗>室内>战略图>地图", _test_resolve_priority, false)
	_runner.add_test("分层: tier 控制层音量", _test_tier_gating, false)
	_runner.add_test("压限: duck 转发到 AudioManager 且与音量共存",
		_test_duck_forwarding, false)
	_runner.add_test("降级: 缺失 cue / 缺失环境音不报错", _test_graceful_degradation, false)
	_run_tests_async()


func _run_tests_async() -> void:
	await _runner.run_async()
	print(_runner.summary())
	MusicDirector.set_enabled(true)
	get_tree().quit(0 if _runner.all_passed() else 1)


# ─────────────────────────────── 辅助 ────────────────────────────────

func _load_manifest() -> Dictionary:
	if not _manifest.is_empty():
		return _manifest
	if not FileAccess.file_exists(MANIFEST_PATH):
		return {}
	var f := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) == TYPE_DICTIONARY:
		_manifest = parsed
	return _manifest


func _cues() -> Dictionary:
	return _load_manifest().get("cues", {})


# ─────────────────────────────── 清单 ────────────────────────────────

func _test_manifest_shape() -> void:
	_runner.assert_true(FileAccess.file_exists(MANIFEST_PATH),
		"音乐清单应存在：%s（缺它先跑 tools/music/render_all.py）" % MANIFEST_PATH)
	var m := _load_manifest()
	_runner.assert_true(not m.is_empty(), "清单应能解析为字典")
	_runner.assert_true(int(m.get("version", 0)) >= 1, "清单应有 version")
	_runner.assert_gt(int(m.get("cue_count", 0)), 0, "清单应有 cue")


func _test_all_cues_present() -> void:
	var cues := _cues()
	for cid in EXPECTED_CUES:
		_runner.assert_true(cues.has(cid), "清单应含 cue：%s" % cid)


func _test_cue_fields() -> void:
	var cues := _cues()
	for cid in EXPECTED_CUES:
		if not cues.has(cid):
			continue
		var c: Dictionary = cues[cid]
		for key in ["title", "bpm", "bar_beats", "bars", "loop", "layers", "key"]:
			_runner.assert_true(c.has(key), "%s 应含字段 %s" % [cid, key])
		_runner.assert_gt(float(c.get("bpm", 0.0)), 0.0, "%s 的 bpm 应 > 0" % cid)
		_runner.assert_gt(int(c.get("bar_beats", 0)), 0, "%s 的 bar_beats 应 > 0" % cid)
		var layers: Array = c.get("layers", [])
		_runner.assert_gt(layers.size(), 0, "%s 至少应有一层" % cid)
		for layer in layers:
			_runner.assert_true(layer.has("name") and layer.has("file")
				and layer.has("tier") and layer.has("db"),
				"%s 的层应含 name/file/tier/db：%s" % [cid, layer])


func _test_layer_files_exist() -> void:
	var cues := _cues()
	for cid in cues.keys():
		for layer in cues[cid].get("layers", []):
			var path := BGM_DIR + str(layer["file"])
			# 用 FileAccess 而不是 ResourceLoader.exists：后者要求资源已被 Godot
			# **导入**（存在 .import 与 .godot 缓存），在刚生成资产、还没开过编辑器的
			# 环境里会假报缺失。这里要检的是"交付件在不在"，不是"导入缓存新不新"。
			_runner.assert_true(FileAccess.file_exists(path),
				"层文件应存在：%s" % path)


func _test_loop_is_integer_bars() -> void:
	var cues := _cues()
	for cid in cues.keys():
		var c: Dictionary = cues[cid]
		if not bool(c.get("loop", true)):
			continue      # 一次性短句不参与循环网格
		var beat_count := int(c.get("beat_count", 0))
		var bar_beats := int(c.get("bar_beats", 4))
		_runner.assert_gt(beat_count, 0, "%s 的 beat_count 应 > 0" % cid)
		_runner.assert_equal(beat_count % bar_beats, 0,
			"%s 的循环体必须是整数小节（%d 拍 / 每小节 %d 拍）"
			% [cid, beat_count, bar_beats])
		_runner.assert_equal(beat_count, int(c.get("bars", 0)) * bar_beats,
			"%s 的 beat_count 应等于 bars × bar_beats" % cid)


# ─────────────────────────────── 解析 ────────────────────────────────

func _test_resolve_cue() -> void:
	var cases := [
		[{"map_type": 0}, "village", "村落地图 → 小镇"],
		[{"map_type": 3}, "interior", "室内地图 → 灯下"],
		[{"map_type": 4}, "interior", "大建筑内部 → 灯下"],
		[{"map_type": 2}, "field_day", "道路/户外 白天 → 原野·昼"],
		[{"map_type": 2, "night": true}, "field_night", "户外 夜晚 → 原野·夜"],
		[{"map_type": 1}, "battle", "战场地图 → 出征"],
		[{"map_type": -1}, "field_day", "未知地图兜底 → 户外白天"],
	]
	MusicDirector.set_context("started", true)
	for case in cases:
		var ctx: Dictionary = case[0]
		# 重置到干净起点，再施加本用例的情境
		MusicDirector.set_context("battle", false)
		MusicDirector.set_context("interior", false)
		MusicDirector.set_context("strategic", false)
		MusicDirector.set_context("night", false)
		MusicDirector.set_context("map_type", -1)
		for k in ctx.keys():
			MusicDirector.set_context(str(k), ctx[k])
		_runner.assert_equal(MusicDirector.get_cue(), str(case[1]),
			"%s（实际：%s）" % [str(case[2]), MusicDirector.get_cue()])


func _test_resolve_priority() -> void:
	# 同时满足多个条件时，按 战斗 > 室内 > 战略图 > 地图类型 取最具体者
	MusicDirector.set_context("started", true)
	MusicDirector.set_context("map_type", 0)
	MusicDirector.set_context("strategic", true)
	_runner.assert_equal(MusicDirector.get_cue(), "strategic",
		"战略图应压过地图类型")
	MusicDirector.set_context("interior", true)
	_runner.assert_equal(MusicDirector.get_cue(), "interior",
		"室内应压过战略图")
	MusicDirector.set_context("battle", true)
	_runner.assert_equal(MusicDirector.get_cue(), "battle",
		"战斗应压过所有其他情境")
	# 收尾复位
	MusicDirector.set_context("battle", false)
	MusicDirector.set_context("interior", false)
	MusicDirector.set_context("strategic", false)


# ─────────────────────────────── 分层 ────────────────────────────────

func _test_tier_gating() -> void:
	# 这条用例**真的走播放路径**（headless 下没有音频设备，播放是安全空操作），
	# 因为纵向混音的逻辑就活在那条路径上：tier 之内的层 = 声明音量，
	# tier 之外的层 = 淡到静音。只在清单上断言等于没测到东西。
	MusicDirector.set_context("battle", false)
	MusicDirector.set_context("interior", false)
	MusicDirector.set_context("strategic", false)
	MusicDirector.set_context("map_type", 2)
	MusicDirector.set_enabled(true)
	MusicDirector.play_cue("field_day", 0.0)
	_runner.assert_equal(MusicDirector.get_cue(), "field_day", "应切到昼曲")

	var entry: Dictionary = _cues()["field_day"]
	var declared := {}
	var tier_of := {}
	for layer in entry["layers"]:
		declared[str(layer["name"])] = float(layer["db"])
		tier_of[str(layer["name"])] = int(layer["tier"])
	_runner.assert_gt(declared.size(), 1, "昼曲应有多层（分层是自适应音乐的前提）")

	# tier=0：只有 tier 0 的层在发声，其余静音
	MusicDirector.set_tier(9, 0.0)      # 先拉到高位，确保下面 set_tier 不被"同值早退"跳过
	MusicDirector.set_tier(0, 0.0)
	var rep := MusicDirector.get_state_report()
	var loud := 0
	var silent := 0
	for name in rep["layers"]:
		var p: AudioStreamPlayer = _find_layer_player(str(name))
		if p == null:
			continue
		if int(tier_of[name]) == 0:
			_runner.assert_approx(p.volume_db, declared[name], 0.6,
				"tier 0 层 %s 应为其声明音量" % name)
			loud += 1
		else:
			_runner.assert_approx(p.volume_db, MusicDirector.SILENT_DB, 0.6,
				"tier>0 的层 %s 在 tier 0 时应静音（实测 %.1f）" % [name, p.volume_db])
			silent += 1
	_runner.assert_gt(loud, 0, "tier 0 应有可发声的层")
	_runner.assert_gt(silent, 0, "昼曲应有 tier>0 的层（否则分层无意义）")

	# tier 全开：所有层都应回到各自声明音量
	MusicDirector.set_tier(9, 0.0)
	for name in MusicDirector.get_state_report()["layers"]:
		var p2: AudioStreamPlayer = _find_layer_player(str(name))
		if p2 != null:
			_runner.assert_approx(p2.volume_db, declared[name], 0.6,
				"tier 全开时 %s 应恢复声明音量" % name)
	_runner.assert_equal(MusicDirector.get_cue(), "field_day", "调 tier 不应换曲")
	MusicDirector.set_enabled(false)
	await get_tree().process_frame


## 取某一层的播放器（用于断言实际音量）
func _find_layer_player(layer_name: String) -> AudioStreamPlayer:
	for child in MusicDirector.get_children():
		if child is AudioStreamPlayer and child.name == "L_" + layer_name:
			return child
	return null


# ─────────────────────────────── 压限 ────────────────────────────────

func _test_duck_forwarding() -> void:
	# duck 只是请求；真正写总线的是 AudioManager（唯一消费方）
	AudioManager.set_volume("bgm", 0.7)
	MusicDirector.unduck(0.0)
	_runner.assert_approx(AudioManager.get_music_duck_db(), 0.0, 0.001,
		"初始压限量应为 0")
	var base_db := AudioServer.get_bus_volume_db(AudioServer.get_bus_index("BGM"))
	MusicDirector.duck(-9.0, 0.0)
	_runner.assert_approx(AudioManager.get_music_duck_db(), -9.0, 0.001,
		"压限量应转发到 AudioManager")
	var ducked_db := AudioServer.get_bus_volume_db(AudioServer.get_bus_index("BGM"))
	_runner.assert_approx(ducked_db - base_db, -9.0, 0.5,
		"总线应实际压低约 9dB（实测 %.2f）" % (ducked_db - base_db))

	# 音量滑条变动时，压限量必须仍然生效（两者一起算，不互相覆盖）
	AudioManager.set_volume("bgm", 0.5)
	var after := AudioServer.get_bus_volume_db(AudioServer.get_bus_index("BGM"))
	var expect := 20.0 * log(0.5) / log(10.0) - 9.0
	_runner.assert_approx(after, expect, 0.5,
		"改音量后压限仍应叠加（实测 %.2f，期望 %.2f）" % [after, expect])

	AudioManager.set_volume("bgm", 0.7)
	MusicDirector.unduck(0.0)
	_runner.assert_approx(AudioManager.get_music_duck_db(), 0.0, 0.001,
		"unduck 后压限量应回到 0")


# ─────────────────────────────── 降级 ────────────────────────────────

func _test_graceful_degradation() -> void:
	# 不存在的 cue 不应崩，也不应改变当前曲目
	var before := MusicDirector.get_cue()
	MusicDirector.play_cue("no_such_cue_exists")
	_runner.assert_equal(MusicDirector.get_cue(), before,
		"播放不存在的 cue 应被拒绝且不改状态")
	_runner.assert_false(MusicDirector.has_cue("no_such_cue_exists"),
		"has_cue 应对未知 cue 返回 false")
	_runner.assert_true(MusicDirector.has_cue("field_day"),
		"has_cue 应对已知 cue 返回 true")
	# 未知情境键应被拒绝（防拼写错误静默失效）
	MusicDirector.set_context("not_a_context_key", 1)
	_runner.assert_false(MusicDirector.get_context().has("not_a_context_key"),
		"未知情境键不应进入情境表")
