class_name TestRunner
extends RefCounted
## 测试运行器（加固版）。
##
## 使用：
##   var runner := TestRunner.new()
##   runner.add_test("my test", func():
##       runner.assert_equal(2 + 2, 4)
##   )
##   runner.run()
##   print(runner.summary())
##
## 加固点（相对旧版，见 docs/项目/P0重审与稳定化方案.md §3.2）：
##   - **零断言守卫**：用例跑完 0 次断言直接判失败（防 return 静默通过）
##   - **async 用例内建**：add_test(name, fn, true) + run_async()，免去手动 begin/end_test 配对
##   - 断言 API 扩充：assert_false / assert_lt / assert_gt / assert_approx / assert_null / assert_not_null
##   - 汇总输出断言总数
##   - fixture 生命周期：track_node/track_resource 登记 + 用例结束逆序释放，
##     消除测试进程退出时的 ObjectDB 泄漏噪音（见下方「fixture 生命周期」）
##
## 兼容旧用法：add_test(name, fn) + run()、begin_test/end_test 手动配对仍然有效。

var _tests: Array = []
var _results: Array = []
var _current_test_name: String = ""
var _current_failed: bool = false
var _current_messages: Array = []
var _current_assertions: int = 0

## 本用例登记的 fixture（用例结束逆序释放；跨用例不保留）
var _tracked_nodes: Array = []
var _tracked_resources: Array = []

## 批量模式观测出口（batch_runner 消费）：最近一次 run()/run_async() 的用例数与断言数。
## 经 Engine meta 发布的原因：TestRunner 实例活在套件脚本内部，批量运行器拿不到它，
## 而"用例一条没跑"正是历史盲区（空 _results 曾判通过，见 all_passed 零用例守卫）。
const META_LAST_CASES: String = "test_last_cases"
const META_LAST_ASSERTS: String = "test_last_asserts"


func add_test(name: String, fn: Callable, is_async: bool = false) -> void:
	_tests.append({"name": name, "fn": fn, "async": is_async})


# ─────────────────────────────── fixture 生命周期 ────────────────────────────────
##
## 为什么需要：用例常 new 出既不进场景树、也不 free 的桩节点（FormationSystem /
## FakeUnit / WorldState …）。这些孤儿 Node 在进程退出时被 ObjectDB 记为
## "Leaked instance"，其持有的 RefCounted 图（如 WorldState 的 1000+ CityState）
## 随之整片泄漏，把真实缺陷淹进退出噪音。
##
## 约定：用例自建、由用例负责销毁的节点/资源经 track_node / track_resource 登记；
## **每个用例结束**（_finish）逆序释放，套件内不跨用例累积。共享资源（preload
## 的 .tres、autoload 单例）不要登记——登记也只清 runner 的强引用，不会强拆
## 他人持有的引用，但会让共享对象的生命周期不明。
##
## 用法：
##   var fs: Node = _runner.track_node(ScriptFormationSystem.new())
##   var units: Array = []
##   for i in 3:
##       units.append(_runner.track_node(FakeUnit.new()))
##   _runner.track_resource(plan)

## 登记一个用例自建节点；原样返回，便于一行链式书写。
func track_node(node) -> Variant:
	if node is Node:
		_tracked_nodes.append(node)
	return node


## 批量登记节点（如一次构造的单位数组）。
func track_nodes(nodes: Array) -> void:
	for n in nodes:
		track_node(n)


## 登记一个用例自建的资源/RefCounted 实例；原样返回，便于链式书写。
## 释放口径 = 清掉 runner 的强引用（RefCounted 是否真正回收取决于是否还有他人引用）。
func track_resource(res) -> Variant:
	if res != null:
		_tracked_resources.append(res)
	return res


## 批量登记资源。
func track_resources(resources: Array) -> void:
	for r in resources:
		track_resource(r)


## 释放本用例登记的全部 fixture：节点按登记逆序 free（先摘出场景树，防树内 free
## 告警），随后清空资源强引用。重复登记/已手动 free 的节点由 is_instance_valid 跳过；
## 父节点先于子节点被释放时，子节点已随父消失，同样跳过。
## 公开供套件在 finish_process 前做兜底（正常路径由 _finish 自动调用）。
func cleanup_fixtures() -> void:
	for i in range(_tracked_nodes.size() - 1, -1, -1):
		var n = _tracked_nodes[i]
		if is_instance_valid(n):
			if n.is_inside_tree() and n.get_parent() != null:
				n.get_parent().remove_child(n)
			n.free()
	_tracked_nodes.clear()
	_tracked_resources.clear()



## 同步运行（仅适用于纯同步用例；async 用例请用 run_async）。
func run() -> void:
	_results.clear()
	for t in _tests:
		_start(t["name"])
		var fn: Callable = t["fn"]
		if fn.is_valid():
			fn.call()
		_finish()
	_publish_counts()


## 异步运行（推荐）：async 用例 await 等待完成；同步用例照常。
func run_async() -> void:
	_results.clear()
	for t in _tests:
		_start(t["name"])
		var fn: Callable = t["fn"]
		if fn.is_valid():
			if t["async"]:
				await fn.call()
			else:
				fn.call()
		_finish()
	_publish_counts()


# ─────────────────────────────── 断言（均计入断言计数）────────────────────────────────

func assert_true(cond: bool, msg: String = "") -> void:
	_count_assert()
	if not cond:
		_fail("assert_true 失败: %s" % msg)


func assert_false(cond: bool, msg: String = "") -> void:
	_count_assert()
	if cond:
		_fail("assert_false 失败: %s" % msg)


func assert_equal(a, b, msg: String = "") -> void:
	_count_assert()
	# 类型不同直接判不等（避免 int/String 直接比较触发 SCRIPT ERROR 污染日志）；
	# 例外：String 与 StringName 在 GDScript 中语义相等
	var mismatch: bool = false
	if typeof(a) != typeof(b):
		if (a is String and b is StringName) or (a is StringName and b is String):
			mismatch = a != b
		else:
			mismatch = true
	else:
		mismatch = a != b
	if mismatch:
		_fail("assert_equal 失败: %s vs %s (%s)" % [str(a), str(b), msg])


func assert_not_equal(a, b, msg: String = "") -> void:
	_count_assert()
	var same_value: bool = false
	if typeof(a) != typeof(b):
		if (a is String and b is StringName) or (a is StringName and b is String):
			same_value = a == b
	else:
		same_value = a == b
	if same_value:
		_fail("assert_not_equal 失败: %s == %s (%s)" % [str(a), str(b), msg])


func assert_lt(a: float, b: float, msg: String = "") -> void:
	_count_assert()
	if not a < b:
		_fail("assert_lt 失败: %s >= %s (%s)" % [str(a), str(b), msg])


func assert_gt(a: float, b: float, msg: String = "") -> void:
	_count_assert()
	if not a > b:
		_fail("assert_gt 失败: %s <= %s (%s)" % [str(a), str(b), msg])


func assert_approx(a: float, b: float, epsilon: float = 0.001, msg: String = "") -> void:
	_count_assert()
	if absf(a - b) > epsilon:
		_fail("assert_approx 失败: %s vs %s (ε=%s) (%s)" % [str(a), str(b), str(epsilon), msg])


func assert_null(v, msg: String = "") -> void:
	_count_assert()
	if v != null:
		_fail("assert_null 失败: 实际非空 (%s)" % msg)


func assert_not_null(v, msg: String = "") -> void:
	_count_assert()
	if v == null:
		_fail("assert_not_null 失败: 实际为空 (%s)" % msg)


# ─────────────────────────────── 结果汇总 ────────────────────────────────

func summary() -> String:
	var passed: int = 0
	var total: int = _results.size()
	var total_asserts: int = 0
	for r in _results:
		if r["passed"]:
			passed += 1
		total_asserts += r["asserts"]
	var lines: Array = ["", "=== 测试汇总: %d / %d 通过（断言 %d 次）===" % [passed, total, total_asserts]]
	for r in _results:
		var prefix: String = "[OK]" if r["passed"] else "[FAIL]"
		lines.append("%s  %s" % [prefix, r["name"]])
		if not r["passed"]:
			for m in r["messages"]:
				lines.append("        %s" % m)
	return "\n".join(lines)


func all_passed() -> bool:
	# 零用例守卫：一个用例都没跑（_results 空）说明套件根本没执行（add_test 未被调用/
	# 中途抛错早退）——空跑不算通过，否则批量运行器会把"什么都没测"记成绿灯。
	if _results.is_empty():
		return false
	for r in _results:
		if not r["passed"]:
			return false
	return true


func get_results() -> Array:
	return _results


## 发布本套件执行计数（run/run_async 收尾调用；batch_runner 读 meta 判零用例）
func _publish_counts() -> void:
	var asserts: int = 0
	for r in _results:
		asserts += int(r["asserts"])
	Engine.set_meta(META_LAST_CASES, _results.size())
	Engine.set_meta(META_LAST_ASSERTS, asserts)


# ─────────────────────────────── 内部 ────────────────────────────────

func _start(name: String) -> void:
	_current_test_name = name
	_current_failed = false
	_current_messages = []
	_current_assertions = 0


func _finish() -> void:
	# 零断言守卫：用例跑完 0 次断言，判失败（防静默通过）
	if _current_assertions == 0:
		_current_failed = true
		_current_messages.append("零断言：用例未执行任何断言（疑似静默通过）")
	_results.append({
		"name": _current_test_name,
		"passed": not _current_failed,
		"messages": _current_messages.duplicate(),
		"asserts": _current_assertions,
	})
	# 用例结束即释放本用例登记 fixture（逆序），进程退出前不留孤儿节点噪音
	cleanup_fixtures()


func _count_assert() -> void:
	_current_assertions += 1


func _fail(msg: String) -> void:
	_current_failed = true
	_current_messages.append(msg)


# ─────────────────────────────── 异步测试支持（旧接口，保留兼容）────────────────────────────────

## 标记一个测试开始（手动管理异步用例生命周期）。
func begin_test(name: String) -> void:
	_start(name)


## 标记当前测试结束，记录结果。需与 begin_test 配对使用。
func end_test() -> void:
	_finish()


# ─────────────────────────────── 进程结束出口 ────────────────────────────────

## 测试进程结束统一出口：
## - 先停掉在播 SFX 声部（见 stop_audio_voices）；
## - 批量模式（batch_runner 设置了 Engine meta "test_batch"）：经 test_done 信号
##   通知批量运行器（deferred 发射，保证运行器先完成连接），不退出进程；
## - 独立运行：直接 get_tree().quit(exit_code)。
## 要求使用方脚本声明 `signal test_done(code: int)`。
static func finish_process(emitter: Node, exit_code: int) -> void:
	stop_audio_voices()
	reset_ui_static_caches()
	if Engine.has_meta("test_batch"):
		emitter.call_deferred("emit_signal", "test_done", exit_code)
	else:
		emitter.get_tree().quit(exit_code)


## 退出前复位 ui_global 的进程级静态缓存（手绘 StyleBox / 沸腾贴图帧集 / 字体 /
## 图标 / 空纹理）。这些缓存懒构建后常驻静态变量，进程退出时会被 ObjectDB 记成
## 泄漏（尤其只 preload 到 SketchStyle/SketchTextures 的套件）。复位只清缓存，
## 下次按原懒加载路径重建——运行时行为不变，仅供测试 teardown 使用。
static func reset_ui_static_caches() -> void:
	SketchTextures.reset_static_caches()
	SketchStyle.reset_static_caches()
	SketchButton.reset_static_caches()
	SketchPanel.reset_static_caches()
	SketchFonts.reset_static_caches()
	SketchDraw.reset_static_caches()
	StickIcons.reset_static_caches()
	SketchIcons.reset_static_caches()
	SketchHSlider.reset_static_caches()
	SketchOptionButton.reset_static_caches()


## 退出前停止在播音频声部：AudioStreamPlayback 由 AudioServer 持有，进程秒退时
## 仍在播的声部会被 ObjectDB 记为泄漏（战斗/采集类用例触发音效后必现）。停声部
## 是 autoload 侧的正常退出清理，不是掩盖测试引用。无 AudioManager/MusicDirector
## （纯逻辑工程）时静默跳过。
##
## 三个细节（headless 无帧退出场景）：
## - stop_all_sfx / stop_all 都靠 queue_free 回收播放器，而进程秒退不跑延迟删除
##   队列，故先快照声部、停播后直接 free；
## - instant 音效重触发与音乐换曲会先把旧播放器移出登记表再 queue_free，
##   这些节点同样残留，按 AudioManager/MusicDirector 的子节点一并收；
## - 播放中的 AudioStreamPlayback 由音频线程持有，必须让它按真实时间跑完混音
##   才会释放；本次进程若起过音则等几次混音，否则退出时播放实例与流仍记泄漏。
static func stop_audio_voices() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return
	var audio := tree.root.get_node_or_null("AudioManager")
	var music := tree.root.get_node_or_null("MusicDirector")
	if audio == null and music == null:
		return
	var players: Array = []
	var had_sound: bool = false
	if audio != null and audio.has_method("stop_all_sfx"):
		var tracked: Variant = audio.get("_sfx_players")
		if tracked is Array:
			players.append_array(tracked as Array)
		var play_counts: Variant = audio.get("_play_counts")
		had_sound = play_counts is Dictionary and not (play_counts as Dictionary).is_empty()
		audio.stop_all_sfx()
	if music != null and music.has_method("stop_all"):
		# 音乐层（含战场声场/短句）：stop_all(0) 只静音 + 排延迟释放，无帧不会执行
		var layers: Variant = music.get("_players")
		if layers is Dictionary:
			players.append_array((layers as Dictionary).values())
		var stingers: Variant = music.get("_stinger_players")
		if stingers is Array:
			players.append_array(stingers as Array)
		for key in ["_ambience", "_battle_ambience"]:
			var p: Variant = music.get(key)
			if p != null:
				players.append(p)
		# 不走 stop_all(0)：它会建 0.3s 后 queue_free 的 tween，播放器已由本函数
		# 直接 free，批跑后续帧里回调会打到已释放实例。这里只清状态表。
		music.set("_players", {})
		music.set("_layer_db", {})
		music.set("_cue", "")
		music.set("_preview", "")
		music.set("_battle_ambience_active", false)
		music.set("_ambience_name", "")
	# 换曲/重触发退役的播放器已不在登记表里，按子节点兜底收齐
	for host in [audio, music]:
		if host == null:
			continue
		for child in host.get_children():
			if child is AudioStreamPlayer or child is AudioStreamPlayer2D:
				if not players.has(child):
					players.append(child)
	for p in players:
		if is_instance_valid(p) and (p as Node).is_inside_tree():
			had_sound = had_sound or bool(p.get("playing"))
	if had_sound:
		# 先停播，再让音频线程跑几次混音（时间增量回落 = 新一次混音完成）
		for p in players:
			if is_instance_valid(p) and (p as Node).has_method("stop"):
				(p as Node).call("stop")
		var last_mix: float = AudioServer.get_time_since_last_mix()
		var mixes: int = 0
		var deadline: int = Time.get_ticks_msec() + 1000
		while mixes < 4 and Time.get_ticks_msec() < deadline:
			OS.delay_msec(2)
			var now_mix: float = AudioServer.get_time_since_last_mix()
			if now_mix < last_mix:
				mixes += 1
			last_mix = now_mix
	# 无帧退出时 queue_free 不会执行：混音释放后直接 free 声部节点
	for p in players:
		if is_instance_valid(p):
			p.free()
