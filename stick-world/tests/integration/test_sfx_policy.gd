extends Node
## 集成测试：音效播放策略（SFX_EVENTS / SFX_POLICY / play_event / 压限请求集）。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_sfx_policy.tscn
##
## 覆盖：
##   - 表契约：每个事件都有策略；策略字段合法；变体池形态正确
##   - 资产对账：把"全部变体都缺失"的事件打出来（它们当前不会发声）
##   - 节流：min_ms 内的重复请求被丢弃
##   - 同帧合并：N 次同帧请求并成 1~2 路，增益随 N 变轻
##   - 声部预算：占满后按优先级让位（同为最低优先级则丢弃新请求）
##   - 定位：有宿主 + 世界坐标 → AudioStreamPlayer2D；无宿主 → 退回非定位
##   - 暂停：世界音效与天气 loop 被 stream_paused 静音，恢复后接回
##   - 压限请求集：多来源并存取最深者，撤销后回落
##
## 说明：本测试**不校验音质**（离线管线负责：python tools/sfx/qa_sfx.py --check）。
## headless 下没有音频设备，播放调用是安全空操作，因此本套件出声无副作用。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")

## 行为用例只用"自研合成、不参与提取件替换"的事件，避免测试依赖资产批次进度
const EV_MERGE := "weapon_swoosh"      # prio 4 / min_ms 50 / merge_slots 2 / spatial
const EV_INSTANT := "bird_chirp"       # prio 1 / min_ms 1200 / instant
## 占位声部用得上的长文件（自研合成，不随提取件替换变动）
const LONG_WAV := "res://assets/audio/sfx/rain_loop.wav"

var _runner: TestRunner
var _host: Node2D = null


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("表契约: 每个事件都有策略", _test_policy_covers_events, false)
	_runner.add_test("表契约: 策略字段合法", _test_policy_fields_valid, false)
	_runner.add_test("表契约: 变体池形态正确", _test_variant_pools, false)
	_runner.add_test("资产: 关键事件至少有一个可用变体", _test_asset_accounting, false)
	_runner.add_test("节流: min_ms 内重复请求被丢弃", _test_throttle, true)
	_runner.add_test("合并: 同帧 N 次请求并成 ≤2 路且增益变轻", _test_merge, true)
	_runner.add_test("预算: 占满后按优先级让位", _test_voice_budget, false)
	_runner.add_test("定位: 有宿主走 2D，无宿主退回非定位", _test_spatial_routing, true)
	_runner.add_test("暂停: 世界音效与雨声静音、恢复接回", _test_pause_handling, true)
	_runner.add_test("压限: 多来源取最深者", _test_duck_request_set, false)
	_run_tests_async()


func _run_tests_async() -> void:
	await _runner.run_async()
	_cleanup()
	# 给 queue_free 两帧落地：否则退出时报"资源仍在使用"，会污染报错自检
	await get_tree().process_frame
	await get_tree().process_frame
	print(_runner.summary())
	get_tree().quit(0 if _runner.all_passed() else 1)


func _cleanup() -> void:
	AudioManager.reset_runtime_state()
	AudioManager.stop_weather()
	# 释放天气播放器持有的 WAV 引用：否则退出时 AudioServer 报"资源仍在使用"
	var w := AudioManager.get("_weather_player") as AudioStreamPlayer
	if w != null:
		w.stream = null
	AudioManager.set_sfx_host(null)
	AudioManager.set_spatial_max_distance(AudioManager.SPATIAL_MAX_DISTANCE)
	AudioManager.release_music_duck(&"battle", 0.0)
	AudioManager.release_music_duck(&"pause", 0.0)
	if _host != null and is_instance_valid(_host):
		for c in _host.get_children():
			c.queue_free()
		_host.queue_free()
	_host = null


## 每个用例前把声部与全部记账清空（用例之间不互相污染；节流记忆尤其重要——
## 上一个用例刚起播过的同一事件会因 min_ms 把下一个用例整批丢掉）
func _reset_sfx() -> void:
	AudioManager.reset_runtime_state()


## TestRunner 只有比较断言，区间断言在这里包一层（消息里带实测值便于定位）
func _assert_between(v: float, lo: float, hi: float, msg: String) -> void:
	_runner.assert_true(v >= lo and v <= hi,
		"%s（实测 %.3f，期望 %.3f~%.3f）" % [msg, v, lo, hi])


# ─────────────────────────────── 表契约 ────────────────────────────────

func _test_policy_covers_events() -> void:
	var events: Dictionary = AudioManager.SFX_EVENTS
	var policy: Dictionary = AudioManager.SFX_POLICY
	_runner.assert_gt(float(events.size()), 0.0, "SFX_EVENTS 不应为空")
	for key in events.keys():
		_runner.assert_true(policy.has(key),
			"事件 %s 缺 SFX_POLICY 条目（漏写会静默套用兜底策略）" % key)


func _test_policy_fields_valid() -> void:
	for key in AudioManager.SFX_POLICY.keys():
		var p: Dictionary = AudioManager.SFX_POLICY[key]
		for f in ["prio", "min_ms", "merge_slots", "jitter"]:
			_runner.assert_true(p.has(f), "策略 %s 应含字段 %s" % [key, f])
		_assert_between(float(p["prio"]), 1.0, 10.0, "%s 的 prio 应在 1~10" % key)
		_assert_between(float(p["min_ms"]), 0.0, 5000.0, "%s 的 min_ms 应为 0~5000ms" % key)
		_assert_between(float(p["merge_slots"]), 1.0, 2.0,
			"%s 的 merge_slots 应为 1~2（超过 2 路就是音墙）" % key)
		_assert_between(float(p["jitter"]), 0.0, 0.15,
			"%s 的 jitter 应 ≤0.15（超过会明显卡通化）" % key)
	# UI 手感必须稳定：抖动 ≤2% 且不带定位
	for ui_key in ["ui_hover", "ui_click", "ui_confirm", "ui_denied"]:
		if not AudioManager.SFX_POLICY.has(ui_key):
			continue
		var up: Dictionary = AudioManager.SFX_POLICY[ui_key]
		_assert_between(float(up["jitter"]), 0.0, 0.02, "%s 的抖动应 ≤2%%" % ui_key)
		_runner.assert_false(bool(up.get("spatial", false)),
			"%s 不该做世界定位（UI 不属于任何位置）" % ui_key)


func _test_variant_pools() -> void:
	for key in AudioManager.SFX_EVENTS.keys():
		var entry: Variant = AudioManager.SFX_EVENTS[key]
		if entry is Array:
			_runner.assert_gt(float((entry as Array).size()), 0.0,
				"%s 的变体池不应为空数组（空池 = 静默丢音）" % key)
		else:
			_runner.assert_true(entry is String and not String(entry).is_empty(),
				"%s 的资产项应是路径或非空数组" % key)


## 资产记账：把"全部变体都缺"的事件打出来——那正是 unit_hurt 曾踩的坑
## （表里有、文件没有 → play_event 静默返回，事件永不发声且零报错）。
func _test_asset_accounting() -> void:
	var missing: Array = []
	for key in AudioManager.SFX_EVENTS.keys():
		if _variant_count(key) == 0:
			missing.append(key)
	if not missing.is_empty():
		print("[SfxPolicyTest] 全部变体缺失（当前不会发声）：%s" % str(missing))
	# 少量关键事件必须在册（行为用例也依赖它们）
	for key in [EV_MERGE, EV_INSTANT, "build_hit"]:
		_runner.assert_gt(float(_variant_count(key)), 0.0,
			"关键事件 %s 至少应有一个可用变体" % key)


func _variant_count(event_name: String) -> int:
	var entry: Variant = AudioManager.SFX_EVENTS[event_name]
	var paths: Array = entry if entry is Array else [entry]
	var found: int = 0
	for p in paths:
		if ResourceLoader.exists(p):
			found += 1
	return found


# ─────────────────────────────── 节流与合并 ────────────────────────────────

func _test_throttle() -> void:
	_reset_sfx()
	# instant 路径：min_ms=1200 内第二次请求必须被丢弃（bird_chirp）
	AudioManager.play_event(EV_INSTANT)
	AudioManager.play_event(EV_INSTANT)
	AudioManager.play_event(EV_INSTANT)
	_runner.assert_equal(AudioManager.get_play_count(EV_INSTANT), 1,
		"instant 事件在 min_ms 内的重复请求应只响 1 次")
	# 合并路径：窗口收尾前不起播，收尾后最多 2 路
	for i in 50:
		AudioManager.play_event(EV_MERGE)
	_runner.assert_equal(AudioManager.get_play_count(EV_MERGE), 0,
		"非 instant 事件在合并窗口收尾前不应起播")
	await _wait_ms(90)
	var after_burst: int = AudioManager.get_play_count(EV_MERGE)
	_assert_between(float(after_burst), 1.0, 2.0,
		"50 次同帧请求应收敛成 1~2 路声部")
	# min_ms=50 已过 → 再触发应能发声（证明节流是"丢弃当次"而不是"永久封杀"）
	AudioManager.play_event(EV_MERGE)
	await _wait_ms(90)
	_runner.assert_gt(float(AudioManager.get_play_count(EV_MERGE)),
		float(after_burst), "min_ms 过后应恢复发声")
	# 同一帧里再来一轮（距上次起播 <50ms）→ 整批被丢弃、不排队
	var before_reburst: int = AudioManager.get_play_count(EV_MERGE)
	for i in 5:
		AudioManager.play_event(EV_MERGE)
	# 立刻检查：窗口还没收尾，计数不应变化（丢弃是即时的，不是延迟排队）
	_runner.assert_equal(AudioManager.get_play_count(EV_MERGE), before_reburst,
		"节流丢弃是即时的：窗口未收尾时计数不应变化")


func _test_merge() -> void:
	_reset_sfx()
	# N=3 → 2 路各 -3dB（"变多了"但不到炸）
	for i in 3:
		AudioManager.play_event(EV_MERGE)
	await _wait_ms(90)
	var rep: Array = AudioManager.get_voice_report()
	_assert_between(float(rep.size()), 1.0, 2.0, "3 次请求应并成 1~2 路")
	for v in rep:
		_runner.assert_approx(float(v["db"]), -3.0, 0.01,
			"N=3 时每路应为 -3dB（实测 %.2f）" % float(v["db"]))
	# N=20 → 每路压到下限 -8dB（-10log10(20/2) = -10dB，下限截断）
	_reset_sfx()
	for i in 20:
		AudioManager.play_event(EV_MERGE)
	await _wait_ms(90)
	var rep2: Array = AudioManager.get_voice_report()
	_assert_between(float(rep2.size()), 1.0, 2.0, "20 次请求应并成 1~2 路")
	for v2 in rep2:
		_runner.assert_approx(float(v2["db"]), -8.0, 0.01,
			"N=20 时每路应压到下限 -8dB（实测 %.2f）" % float(v2["db"]))
	# N=6 → 1 路？不：merge_slots=2 且 n>1 → 2 路各 -3dB（n≤4 档不适用，n=6 走公式）
	_reset_sfx()
	for i in 6:
		AudioManager.play_event(EV_MERGE)
	await _wait_ms(90)
	for v3 in AudioManager.get_voice_report():
		_runner.assert_approx(float(v3["db"]), -4.77, 0.02,
			"N=6 时每路应为 -10log10(3)≈-4.77dB（实测 %.2f）" % float(v3["db"]))


# ─────────────────────────────── 声部预算 ────────────────────────────────

func _test_voice_budget() -> void:
	_reset_sfx()
	# 用底层直放占满预算（play_sfx 是文档化的逃生口，不受预算约束——
	# 这里正是要构造"预算已满"的现场，再验证策略路径的抢占/丢弃规则）
	for i in AudioManager.MAX_VOICES + 4:
		AudioManager.play_sfx(LONG_WAV)
	var active: int = AudioManager.get_active_sfx_count()
	_runner.assert_gt(float(active), float(AudioManager.MAX_VOICES) - 1.0,
		"占位声部应至少达到预算上限（实测 %d）" % active)
	# 同为最低优先级（占位声部无策略记账 = prio 0）→ 新请求应被丢弃
	var accepted_low: bool = AudioManager._try_reserve_voice(0)
	_runner.assert_false(accepted_low,
		"预算用尽且新请求优先级不高于最低者时应丢弃（实测接受了）")
	_runner.assert_equal(AudioManager.get_active_sfx_count(), active,
		"丢弃后声部数不应变化")
	# 更高优先级 → 抢占最低者：_try_reserve_voice 只负责"腾位置"，起播方随后补上，
	# 因此那一刻声部数应比抢占前少 1（净数由起播方恢复到预算值）
	var accepted_high: bool = AudioManager._try_reserve_voice(7)
	_runner.assert_true(accepted_high, "更高优先级的请求应抢占最低优先级的声部")
	_runner.assert_equal(AudioManager.get_active_sfx_count(), active - 1,
		"抢占应腾出一个位置（实测 %d，抢占前 %d）"
		% [AudioManager.get_active_sfx_count(), active])
	_reset_sfx()


# ─────────────────────────────── 定位 ────────────────────────────────

func _test_spatial_routing() -> void:
	_reset_sfx()
	AudioManager.set_sfx_host(null)
	# 无宿主：即使事件 spatial 且给了坐标，也必须退回非定位播放器（不能崩、不能静音）
	AudioManager.play_event(EV_MERGE, Vector2(100.0, 200.0))
	await _wait_ms(90)
	var no_host: Array = AudioManager.get_voice_report()
	_runner.assert_gt(float(no_host.size()), 0.0, "无宿主时仍应发声（退回非定位）")
	for v in no_host:
		_runner.assert_false(bool(v["spatial"]), "无宿主时不应创建 2D 播放器")
	# 有宿主 + 世界坐标 → 2D 播放器，且落在传入坐标上
	_reset_sfx()
	_host = Node2D.new()
	_host.name = "SfxProbeHost"
	add_child(_host)
	AudioManager.set_sfx_host(_host)
	AudioManager.play_event(EV_MERGE, Vector2(123.0, 456.0))
	await _wait_ms(90)
	var with_host: Array = AudioManager.get_voice_report()
	_runner.assert_gt(float(with_host.size()), 0.0, "有宿主且给坐标时应发声")
	if with_host.size() > 0:
		_runner.assert_true(bool(with_host[0]["spatial"]),
			"spatial 事件在有宿主且给坐标时应走 AudioStreamPlayer2D")
	var p2: AudioStreamPlayer2D = null
	for child in _host.get_children():
		if child is AudioStreamPlayer2D:
			p2 = child
			break
	_runner.assert_not_null(p2, "宿主下应挂有 AudioStreamPlayer2D")
	if p2 != null:
		_runner.assert_approx(p2.max_distance, AudioManager.get_spatial_max_distance(),
			0.01, "2D 播放器应使用当前听觉半径")
		_runner.assert_approx(p2.global_position.x, 123.0, 0.01,
			"2D 播放器应落在传入的世界坐标上")
	# 听觉半径可被相机推送（缩放自适应）：推送后新起的 2D 声部要用新半径
	AudioManager.set_spatial_max_distance(2300.0)
	_runner.assert_approx(AudioManager.get_spatial_max_distance(), 2300.0, 0.01,
		"听觉半径应随相机缩放更新（实测 %.1f）" % AudioManager.get_spatial_max_distance())
	_reset_sfx()
	AudioManager.play_event(EV_MERGE, Vector2(50.0, 0.0))
	await _wait_ms(90)
	var p3: AudioStreamPlayer2D = null
	for child in _host.get_children():
		if child is AudioStreamPlayer2D:
			p3 = child
			break
	_runner.assert_not_null(p3, "推送半径后新声部仍应是 2D")
	if p3 != null:
		_runner.assert_approx(p3.max_distance, 2300.0, 0.01,
			"新声部应使用推送后的半径（实测 %.1f）" % p3.max_distance)
	# 半径下限/上限应被夹住（防上游传 0 或 ∞）
	AudioManager.set_spatial_max_distance(0.0)
	_runner.assert_approx(AudioManager.get_spatial_max_distance(),
		AudioManager.SPATIAL_DISTANCE_MIN, 0.01, "半径应被下限夹住")
	AudioManager.set_spatial_max_distance(999999.0)
	_runner.assert_approx(AudioManager.get_spatial_max_distance(),
		AudioManager.SPATIAL_DISTANCE_MAX, 0.01, "半径应被上限夹住")
	AudioManager.set_spatial_max_distance(AudioManager.SPATIAL_MAX_DISTANCE)
	# 不给坐标 → 仍然非定位（Vector2.ZERO = 没有位置信息，不当成世界原点）
	_reset_sfx()
	AudioManager.play_event(EV_MERGE)
	await _wait_ms(90)
	var no_pos: Array = AudioManager.get_voice_report()
	_runner.assert_gt(float(no_pos.size()), 0.0, "不给坐标也应发声")
	for v2 in no_pos:
		_runner.assert_false(bool(v2["spatial"]), "未给世界坐标时不应走 2D")
	AudioManager.set_sfx_host(null)


# ─────────────────────────────── 暂停 ────────────────────────────────

func _test_pause_handling() -> void:
	_reset_sfx()
	AudioManager.play_event(EV_MERGE)
	await _wait_ms(90)
	var before: Array = AudioManager.get_voice_report()
	_runner.assert_gt(float(before.size()), 0.0, "暂停用例需要至少一路在播声部")
	AudioManager._on_game_paused()
	for v in AudioManager.get_voice_report():
		_runner.assert_true(bool(v["paused"]),
			"暂停时世界音效应 stream_paused（不是 stop：恢复要能接着响）")
	AudioManager._on_game_resumed()
	for v2 in AudioManager.get_voice_report():
		_runner.assert_false(bool(v2["paused"]), "恢复后声部应解暂停")
	# 天气 loop 与之一致（暂停不该有雨声）
	_reset_sfx()
	AudioManager.play_weather(LONG_WAV, 0.4)
	var w := AudioManager.get("_weather_player") as AudioStreamPlayer
	_runner.assert_not_null(w, "天气播放器应存在")
	if w != null and w.playing:
		AudioManager._on_game_paused()
		_runner.assert_true(w.stream_paused, "暂停时雨声 loop 应被静音")
		AudioManager._on_game_resumed()
		_runner.assert_false(w.stream_paused, "恢复后雨声应接回")
	AudioManager.stop_weather()


# ─────────────────────────────── 压限请求集 ────────────────────────────────

func _test_duck_request_set() -> void:
	# 修"战斗中暂停只压 6dB"：多来源并存取最深者，而不是后写者覆盖
	AudioManager.release_music_duck(&"battle", 0.0)
	AudioManager.release_music_duck(&"pause", 0.0)
	_runner.assert_approx(AudioManager.get_music_duck_db(), 0.0, 0.001,
		"无请求时压限量应为 0")
	AudioManager.request_music_duck(&"battle", -6.0, 0.0)
	_runner.assert_approx(AudioManager.get_music_duck_db(), -6.0, 0.001,
		"单请求应直接生效")
	AudioManager.request_music_duck(&"pause", -9.0, 0.0)
	_runner.assert_approx(AudioManager.get_music_duck_db(), -9.0, 0.001,
		"战斗 + 暂停并存时应取暂停档 -9（旧实现被覆盖成 -6）")
	var bus_db := AudioServer.get_bus_volume_db(AudioServer.get_bus_index("BGM"))
	var base_db := 20.0 * log(AudioManager.get_volume("bgm")) / log(10.0)
	_runner.assert_approx(bus_db - base_db, -9.0, 0.5,
		"总线应实际压低 9dB（实测 %.2f）" % (bus_db - base_db))
	AudioManager.release_music_duck(&"pause", 0.0)
	_runner.assert_approx(AudioManager.get_music_duck_db(), -6.0, 0.001,
		"撤销暂停后应回落到战斗档 -6（请求集而非单标量）")
	AudioManager.release_music_duck(&"battle", 0.0)
	_runner.assert_approx(AudioManager.get_music_duck_db(), 0.0, 0.001,
		"全部撤销后应回到 0")


# ─────────────────────────────── 工具 ────────────────────────────────

func _wait_ms(ms: int) -> void:
	await get_tree().create_timer(float(ms) / 1000.0, true, false, true).timeout
