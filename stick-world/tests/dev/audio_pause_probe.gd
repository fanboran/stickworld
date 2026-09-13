extends Node2D
## 实测 A：SceneTree 暂停（get_tree().paused = true）时，AudioStreamPlayer /
## AudioStreamPlayer2D 的播放位置是否继续推进——即「树暂停时雨声循环还响不响」。
##
## 判据：暂停窗口内 get_playback_position() 的增量（playing 可能仍为 true）。
##   delta_pause ≈ 0           → 引擎随树暂停该播放器（位置冻结）
##   delta_pause ≈ 停顿时长    → 音频不受树暂停影响
##
## 测得对象（同一段 wav，同时 play）：
##   A1  AudioStreamPlayer   process_mode = INHERIT（默认，= AudioManager 下 _weather_player 的情形）
##   A2  AudioStreamPlayer   process_mode = ALWAYS（对照组）
##   A3  AudioStreamPlayer2D process_mode = INHERIT（默认）
##
## 运行（带窗口，推荐；headless 下 Dummy 音频驱动可能不推进混合）：
##   <godot> --path stick-world res://tests/dev/audio_pause_probe.tscn
## 只测量、不打扰：加 STICK_DEV_QUIET=1（静音 Master + 窗口不抢焦点）

const WAV := "res://assets/audio/sfx/rain_loop.wav"  # 4.00s，覆盖 ~1.1s 时间线

var _p_inherit: AudioStreamPlayer
var _p_always: AudioStreamPlayer
var _p_2d: AudioStreamPlayer2D


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # 探针自身在暂停中仍要跑（探针行为，不涉及被测对象）
	if DisplayServer.get_name() != "headless":
		# 带窗口时别抢焦点（不静音，保证音频线程正常混合）
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, false)
	var cam := Camera2D.new()
	cam.position = Vector2.ZERO
	add_child(cam)
	cam.make_current()

	var stream: AudioStream = load(WAV)
	_p_inherit = _mk_asp("ASP_INHERIT", Node.PROCESS_MODE_INHERIT, stream)
	_p_always = _mk_asp("ASP_ALWAYS", Node.PROCESS_MODE_ALWAYS, stream)
	_p_2d = _mk_asp2d("ASP2D_INHERIT", Node.PROCESS_MODE_INHERIT, stream)

	print("[A] driver=", AudioServer.get_driver_name(),
		" mix_rate=", AudioServer.get_mix_rate(),
		" bus_count=", AudioServer.bus_count,
		" display=", DisplayServer.get_name())
	_run()


func _mk_asp(n: String, pm: int, s: AudioStream) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.name = n
	p.stream = s
	p.process_mode = pm
	p.volume_db = 0.0
	add_child(p)
	return p


func _mk_asp2d(n: String, pm: int, s: AudioStream) -> AudioStreamPlayer2D:
	var p := AudioStreamPlayer2D.new()
	p.name = n
	p.stream = s
	p.process_mode = pm
	p.volume_db = 0.0
	p.max_distance = 1000.0
	p.position = Vector2(50, 0)
	add_child(p)
	return p


func _run() -> void:
	_p_inherit.play()
	_p_always.play()
	_p_2d.play()

	# 预热：让音频线程先把播放位置推进起来（否则首个采样点可能仍是 0，正控制会误判）
	await _wait(0.60)
	var w0 := _snap("w0 预热后 0.60s")
	await _wait(0.30)
	var s0 := _snap("t0 未暂停 +0.30s")

	var tree := get_tree()
	var p0 := _p_inherit.get_playback_position()
	tree.paused = true
	await _wait(0.60)
	var s1 := _snap("t1 已暂停 +0.60s")
	var mix_paused := AudioServer.get_time_since_last_mix()

	tree.paused = false
	await _wait(0.30)
	var s2 := _snap("t2 恢复后 +0.30s")

	_report("A1 AudioStreamPlayer   INHERIT", w0.inherit, s0.inherit, s1.inherit, s2.inherit)
	_report("A2 AudioStreamPlayer   ALWAYS ", w0.always, s0.always, s1.always, s2.always)
	_report("A3 AudioStreamPlayer2D INHERIT", w0.p2d, s0.p2d, s1.p2d, s2.p2d)
	print("[A] 暂停窗口内 AudioServer.get_time_since_last_mix()=%.4fs（<0.1 表示混合线程仍在跑）" % mix_paused)
	print("[A] 暂停窗口起点 pos=%.3f" % p0)

	get_tree().quit()


func _wait(sec: float) -> void:
	# process_always=true：即使树暂停，计时器也照常触发
	await get_tree().create_timer(sec, true).timeout


class Snap:
	var playing: bool
	var paused: bool
	var pos: float
	func _init(p: bool, pa: bool, po: float) -> void:
		playing = p
		paused = pa
		pos = po


class Snap3:
	var inherit: Snap
	var always: Snap
	var p2d: Snap


func _snap(tag: String) -> Snap3:
	var s := Snap3.new()
	s.inherit = Snap.new(_p_inherit.playing, _p_inherit.stream_paused, _p_inherit.get_playback_position())
	s.always = Snap.new(_p_always.playing, _p_always.stream_paused, _p_always.get_playback_position())
	s.p2d = Snap.new(_p_2d.playing, _p_2d.stream_paused, _p_2d.get_playback_position())
	print("[A] %-22s inherit(playing=%s stream_paused=%s pos=%.3f) | always(pos=%.3f) | 2d(pos=%.3f)" % [
		tag,
		str(s.inherit.playing), str(s.inherit.paused), s.inherit.pos,
		s.always.pos, s.p2d.pos,
	])
	return s


func _report(label: String, w0: Snap, s0: Snap, s1: Snap, s2: Snap) -> void:
	var d_ctrl := s0.pos - w0.pos  # 未暂停 0.3s 段的推进量（正控制）
	var d_pause := s1.pos - s0.pos
	var d_resume := s2.pos - s1.pos
	var ctrl_ok := d_ctrl > 0.15
	var moved_pause := d_pause > 0.30
	var frozen_pause := d_pause < 0.05
	print("--------------------------------------------------------------")
	print("[A] %s" % label)
	print("    正控制(未暂停0.30s) pos %.3f→%.3f  推进=+%.3fs   %s" % [
		w0.pos, s0.pos, d_ctrl, "PASS(音频在推进)" if ctrl_ok else "FAIL(测量无效: 音频根本没推进)"])
	print("    暂停段(0.60s)        pos %.3f→%.3f  推进=+%.3fs" % [s0.pos, s1.pos, d_pause])
	print("    恢复段(0.30s)        pos %.3f→%.3f  推进=+%.3fs" % [s1.pos, s2.pos, d_resume])
	var verdict := "位置推进(%.3fs/0.6s) → 不受树暂停影响（引擎未自动暂停该播放器）" % d_pause
	if frozen_pause:
		verdict = "位置冻结(%.3fs) → 引擎随树暂停自动暂停音频" % d_pause
	elif not moved_pause:
		verdict = "位置几乎不动(%.3fs) → 疑似部分暂停（数值见上）" % d_pause
	print("    判定: 暂停期间 %s" % verdict)
	print("    其他字段: playing(t1)=%s stream_paused(t1)=%s" % [
		str(s1.playing), str(s1.paused)])
