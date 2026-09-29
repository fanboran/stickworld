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
## 游戏流程实际会触发的全部 cue（含变奏 B 组与三首标点）
const EXPECTED_CUES := [
	"menu_title", "field_day", "field_day_b", "field_night",
	"village", "village_b", "village_night",
	"interior", "interior_hall", "strategic",
	"battle", "battle_b", "battlefield",
	"sting_victory", "sting_defeat", "sting_conquest", "sting_arrival",
]

var _runner: TestRunner
var _manifest: Dictionary = {}


func _ready() -> void:
	MusicDirector.set_enabled(false)      # 本套件只测逻辑，不出声
	_runner = TestRunner.new()
	_runner.add_test("清单: 文件存在且格式正确", _test_manifest_shape, false)
	_runner.add_test("清单: 全部 cue 齐备（17 首）", _test_all_cues_present, false)
	_runner.add_test("清单: 每 cue 字段完整", _test_cue_fields, false)
	_runner.add_test("清单: 层文件真实存在", _test_layer_files_exist, false)
	_runner.add_test("清单: 循环体是整数小节", _test_loop_is_integer_bars, false)
	_runner.add_test("解析: 情境 → 曲目", _test_resolve_cue, false)
	_runner.add_test("解析: 优先级 战斗>室内>战略图>地图", _test_resolve_priority, false)
	_runner.add_test("变奏: 族成员同调同速同长同层名", _test_variation_family_contract, false)
	_runner.add_test("变奏: 再次进入同一场景换一版", _test_variation_rotation, false)
	_runner.add_test("标点: 抵达打点、战斗结算不打点", _test_arrival_stinger, false)
	_runner.add_test("标点: 压限按短句长度释放", _test_stinger_duck_hold, true)
	_runner.add_test("分层: tier 控制层音量", _test_tier_gating, false)
	_runner.add_test("曲目表: 与清单同源同序", _test_track_list, false)
	_runner.add_test("预览: 起播/满层/循环开关/暂停", _test_preview_playback, false)
	_runner.add_test("预览: 情境不抢曲、退场还原", _test_preview_isolation, false)
	_runner.add_test("预览: 退役层收尾不串台", _test_preview_retired_layer, false)
	_runner.add_test("压限: duck 转发到 AudioManager 且与音量共存",
		_test_duck_forwarding, false)
	_runner.add_test("降级: 缺失 cue / 缺失环境音不报错", _test_graceful_degradation, false)
	_run_tests_async()


func _run_tests_async() -> void:
	await _runner.run_async()
	# 收尾：停掉短句与曲目播放器，否则退出时报"资源仍在使用"（污染报错自检）
	MusicDirector.stop_stinger()
	MusicDirector.stop_all(0.0)
	await get_tree().process_frame
	await get_tree().process_frame
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
		[{"map_type": 0, "night": true}, "village_night", "村落 夜晚 → 夜镇"],
		[{"map_type": 3}, "interior", "室内地图 → 灯下"],
		[{"map_type": 4}, "interior_hall", "大建筑内部 → 厅堂"],
		[{"map_type": 2}, "field_day", "道路/户外 白天 → 原野·昼"],
		[{"map_type": 2, "night": true}, "field_night", "户外 夜晚 → 原野·夜"],
		[{"map_type": 1}, "battlefield", "战场地图（非交战）→ 余烬"],
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


# ─────────────────────────────── 变奏族 ────────────────────────────────

## 族成员必须**同调、同速、同长、层名一一对应**——运行时轮换的无缝前提。
## 这条守的是"作曲侧改了变奏却忘了对齐基础曲"（改完听着会发现，但没人天天听）。
func _test_variation_family_contract() -> void:
	var man := _load_manifest()
	var sets: Dictionary = man.get("variation_sets", {})
	_runner.assert_gt(sets.size(), 0,
		"清单应带 variation_sets（作曲侧声明，运行时据此轮换）")
	var cues := _cues()
	for base in sets.keys():
		var members: Array = sets[base]
		_runner.assert_gt(members.size(), 1, "%s 的变奏族应至少两个成员" % base)
		_runner.assert_true(cues.has(base), "族基准 %s 应在清单里" % base)
		var ref: Dictionary = cues.get(base, {})
		var ref_layers := _layer_names(ref)
		for m in members:
			_runner.assert_true(cues.has(m), "族成员 %s 应在清单里" % m)
			if not cues.has(m):
				continue
			var c: Dictionary = cues[m]
			_runner.assert_equal(int(c.get("bpm", 0)), int(ref.get("bpm", -1)),
				"%s 与 %s 的 BPM 必须一致（轮换不能变速）" % [m, base])
			_runner.assert_equal(int(c.get("beat_count", 0)), int(ref.get("beat_count", -1)),
				"%s 与 %s 的循环拍数必须一致（轮换要对齐小节）" % [m, base])
			_runner.assert_equal(int(c.get("bar_beats", 0)), int(ref.get("bar_beats", -1)),
				"%s 与 %s 的拍号必须一致" % [m, base])
			_runner.assert_equal(str(c.get("key", "")), str(ref.get("key", "")),
				"%s 与 %s 的调性必须一致" % [m, base])
			_runner.assert_equal(str(c.get("loop", "")), str(ref.get("loop", "")),
				"%s 与 %s 的循环属性必须一致" % [m, base])
			_runner.assert_true(_layer_names(c) == ref_layers,
				"%s 与 %s 的层名集合必须一致（运行时按层名整体替换）" % [m, base])


func _layer_names(entry: Dictionary) -> Array:
	var out: Array = []
	for l in entry.get("layers", []):
		out.append(str(l["name"]))
	out.sort()
	return out


## 再次进入同一场景 → 换同族另一版（抗疲劳轮换的对外行为）。
func _test_variation_rotation() -> void:
	MusicDirector.set_context("started", true)
	MusicDirector.set_context("battle", false)
	MusicDirector.set_context("interior", false)
	MusicDirector.set_context("strategic", false)
	MusicDirector.set_context("night", false)
	MusicDirector.set_context("map_type", 2)        # 先离开（去户外）
	MusicDirector.set_context("map_type", 0)        # 第 1 次进村落
	var first := MusicDirector.get_cue()
	_runner.assert_true(first in ["village", "village_b"],
		"村落应解析到小镇或它的变奏（实际 %s）" % first)
	MusicDirector.set_context("map_type", 2)        # 离开
	MusicDirector.set_context("map_type", 0)        # 第 2 次进村落
	var second := MusicDirector.get_cue()
	_runner.assert_true(second in ["village", "village_b"],
		"第 2 次进村落应仍解析到同族（实际 %s）" % second)
	_runner.assert_not_equal(second, first,
		"连续两次进入同一场景应换一版（实测 %s → %s）" % [first, second])
	# 收尾：回到户外，避免影响后续用例
	MusicDirector.set_context("map_type", 2)


# ─────────────────────────────── 标点（stinger）────────────────────────────

## 跨图抵达打点、首发加载不打点；战斗结算用结算短句（不是抵达短句）。
func _test_arrival_stinger() -> void:
	_runner.assert_true(MusicDirector.has_cue("sting_arrival"),
		"清单里应有抵达标点 sting_arrival")
	_runner.assert_true(MusicDirector.has_cue("sting_conquest"),
		"清单里应有入主标点 sting_conquest")
	MusicDirector.set_enabled(true)
	MusicDirector.set_context("started", true)
	# 首发加载（没有 travel_started）→ 不打点
	EventBus.map_loaded.emit("map_a", 2)
	_runner.assert_equal(MusicDirector.get_stinger_cue(), "",
		"首发加载不该打抵达标点")
	# 跨图：travel_started → 下一次 map_loaded 打点
	EventBus.travel_started.emit("map_a", "map_b", 0)
	EventBus.map_loaded.emit("map_b", 2)
	_runner.assert_equal(MusicDirector.get_stinger_cue(), "sting_arrival",
		"跨图抵达应打 sting_arrival（实际 %s）" % MusicDirector.get_stinger_cue())
	MusicDirector.stop_stinger()
	MusicDirector.set_enabled(false)


## 短句压限**按短句自身长度**释放：长标点不能被短保持提前放开。
func _test_stinger_duck_hold() -> void:
	MusicDirector.set_enabled(true)
	AudioManager.release_music_duck(&"sting", 0.0)
	_runner.assert_approx(AudioManager.get_music_duck_db(), 0.0, 0.001,
		"起测前不应有残留压限")
	MusicDirector.play_stinger("sting_arrival")
	_runner.assert_approx(AudioManager.get_music_duck_db(),
		MusicDirector.DUCK_STINGER, 0.001,
		"短句播放期间应请求浅压限")
	var dur := float(_cues().get("sting_arrival", {}).get("duration_s", 4.0))
	# 等短句播完 + 释放时间；若实现用的是固定 2.5s 保持，这里会提前放开
	await _wait_s(dur + 1.2)
	_runner.assert_approx(AudioManager.get_music_duck_db(), 0.0, 0.001,
		"短句结束后压限应自行释放（实测 %.2f）" % AudioManager.get_music_duck_db())
	MusicDirector.stop_stinger()
	MusicDirector.set_enabled(false)


func _wait_s(sec: float) -> void:
	await get_tree().create_timer(sec, true, false, true).timeout


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


# ─────────────────────────── 曲目表与原声带预览 ───────────────────────────

## 曲目表 = 清单的投影（原声带页的数据源）：条数、顺序、字段都要与清单一致，
## 否则界面会与"实际会放出来的东西"脱钩（加曲子只该改清单）
func _test_track_list() -> void:
	var cues := _cues()
	var tracks: Array[Dictionary] = MusicDirector.get_track_list()
	_runner.assert_equal(tracks.size(), cues.size(),
		"曲目表条数应等于清单 cue 数")
	var cue_ids: Array = cues.keys()
	for i in tracks.size():
		var t: Dictionary = tracks[i]
		_runner.assert_equal(str(t["id"]), str(cue_ids[i]),
			"第 %d 首应是清单第 %d 项（唱片序 = 清单声明序）" % [i + 1, i + 1])
		for key in ["title", "key", "bpm", "duration_s", "loop", "layer_count", "lineup"]:
			_runner.assert_true(t.has(key), "曲目项应含 %s" % key)
		var entry: Dictionary = cues[t["id"]]
		_runner.assert_equal(str(t["title"]), str(entry["title"]), "曲名应与清单一致")
		_runner.assert_equal(int(t["layer_count"]), (entry["layers"] as Array).size(),
			"层数应与清单一致")
		var lineup: Array = t["lineup"]
		_runner.assert_equal(lineup.size(), int(t["layer_count"]),
			"编制明细条数应等于层数")
		for layer: Dictionary in lineup:
			_runner.assert_true(layer.has("name") and layer.has("tier"),
				"编制明细应含 name/tier")


## 预览播放（原声带页点曲目走这条路径）：绕过情境解析、固定满层、
## 循环开关改的是流自身的 loop 属性
func _test_preview_playback() -> void:
	MusicDirector.set_enabled(true)      # 这条用例要走真实播放路径（headless 无声）
	MusicDirector.set_context("battle", false)
	MusicDirector.set_context("interior", false)
	MusicDirector.set_context("strategic", false)
	MusicDirector.set_context("map_type", -1)
	_runner.assert_false(MusicDirector.is_previewing(), "初始不在预览态")
	_runner.assert_false(MusicDirector.start_preview("no_such_cue_exists"),
		"不存在的 cue 应拒绝预览")
	_runner.assert_true(MusicDirector.start_preview("village", true), "已知 cue 应能预览")
	_runner.assert_true(MusicDirector.is_previewing(), "应进入预览态")
	_runner.assert_equal(MusicDirector.get_preview_track(), "village", "预览曲目应记下")
	_runner.assert_equal(MusicDirector.get_tier(), 2,
		"预览应固定满层（tier=2：听的是完整编制）")
	var dur := float(_cues()["village"]["duration_s"])
	_runner.assert_approx(MusicDirector.preview_duration(), dur, 0.01, "预览时长应取清单值")
	# 循环开关落到流上（village 在清单里是循环体；这里反向验证"能强制不循环"）
	_runner.assert_true(_layer_stream_loops("piano"), "默认预览应循环")
	MusicDirector.start_preview("village", false)
	_runner.assert_false(_layer_stream_loops("piano"), "循环关时应写 loop=false")
	# 暂停走 stream_paused（继续播放要从原位置接上，不释放层）
	MusicDirector.set_preview_paused(true)
	_runner.assert_true(MusicDirector.is_preview_paused(), "暂停态应记下")
	var p: AudioStreamPlayer = _find_layer_player("piano")
	_runner.assert_true(p != null and p.stream_paused, "层的播放应真的挂起")
	MusicDirector.set_preview_paused(false)
	_runner.assert_false(p.stream_paused, "继续后层应恢复")
	# 收尾：退出预览（下面的用例还要用系统）
	MusicDirector.stop_preview(0.0)
	MusicDirector.set_enabled(false)
	_runner.assert_false(MusicDirector.is_previewing(), "stop_preview 应退出预览态")


## 预览与情境解析的边界：预览期间任何状态变化都不换曲；退场还原入场前的曲目
func _test_preview_isolation() -> void:
	MusicDirector.set_enabled(true)
	MusicDirector.set_context("started", true)
	MusicDirector.set_context("battle", false)
	MusicDirector.set_context("interior", false)
	MusicDirector.set_context("strategic", false)
	MusicDirector.set_context("map_type", 2)     # 户外 → field_day（或它的变奏，见变奏族）
	var before := MusicDirector.get_cue()
	_runner.assert_true(before in ["field_day", "field_day_b"],
		"先落到户外昼曲（或其变奏）")
	MusicDirector.set_tier(1, 0.0)
	# 预览一首：随后的情境变化不许把它换掉
	MusicDirector.start_preview("battle", true)
	MusicDirector.set_context("map_type", 0)     # 走进村落
	_runner.assert_equal(MusicDirector.get_cue(), "battle",
		"预览期间情境变化不应抢走曲目（实际：%s）" % MusicDirector.get_cue())
	_runner.assert_equal(MusicDirector.get_preview_track(), "battle", "预览曲目仍在")
	# 退场：回到入场前那首与原强度
	MusicDirector.stop_preview(0.0)
	_runner.assert_false(MusicDirector.is_previewing(), "退场后不再是预览态")
	_runner.assert_equal(MusicDirector.get_cue(), before,
		"退场应还原入场前的曲目（实测 %s，入场前 %s）"
		% [MusicDirector.get_cue(), before])
	_runner.assert_equal(MusicDirector.get_tier(), 1, "退场应还原入场前的强度档")
	MusicDirector.set_context("map_type", -1)
	MusicDirector.set_enabled(false)


## 退役层（Fading_ 前缀）拖尾播到 EOF 也会发 finished：回调若不甄别发送者，
## 会把上一曲的收尾算到新预览头上（页面凭空自动跳下一曲）。
## 对退役层引用直接发信号来模拟这条时序。
func _test_preview_retired_layer() -> void:
	MusicDirector.set_enabled(true)
	MusicDirector.start_preview("village", false)
	var retired: AudioStreamPlayer = _find_layer_player("piano")
	MusicDirector.start_preview("field_day", false)   # village 的层全部退役淡出
	_runner.assert_true(MusicDirector.is_previewing(), "换曲后仍在预览态")
	var finished_cue := [""]
	var spy := func(cue_id: String) -> void: finished_cue[0] = cue_id
	MusicDirector.preview_finished.connect(spy)
	# 退役层拖尾到 EOF：不该触发 preview_finished
	retired.finished.emit()
	_runner.assert_true(finished_cue[0].is_empty(),
		"退役层的 finished 不应触发 preview_finished（实际：%s）" % finished_cue[0])
	# 当前层的收尾：正常通知
	var current: AudioStreamPlayer = _find_layer_player("piano")
	_runner.assert_true(current != null and current != retired, "换曲后 piano 指向新层")
	current.finished.emit()
	_runner.assert_equal(finished_cue[0], "field_day", "当前层收尾正常通知")
	MusicDirector.preview_finished.disconnect(spy)
	MusicDirector.stop_preview(0.0)
	MusicDirector.set_enabled(false)
	_runner.assert_false(MusicDirector.is_previewing(), "收尾退出预览态")


## 取某层流的循环开关（预览的循环开关落在 AudioStreamOggVorbis.loop 上）。
## 按名取层是可靠的：退役层在淡出时会被改名成 Fading_L_<层名>（play_cue 腾位），
## L_<层名> 恒指当前在放的那一层。
func _layer_stream_loops(layer_name: String) -> bool:
	var p: AudioStreamPlayer = _find_layer_player(layer_name)
	if p == null or p.stream == null:
		return false
	return (p.stream as AudioStreamOggVorbis).loop


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
