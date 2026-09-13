extends Node2D
## 实测 B：只有 Camera2D 的场景里，AudioStreamPlayer2D 的距离衰减是否生效
## （= Godot 4 是否自动把当前 Camera2D / 屏幕中心当作 2D 音频监听器）。
##
## 做法：同一段 rain_loop.wav、相同 volume_db=0、相同 max_distance=1000、
## attenuation 默认 1.0 的多路 2D 播放器，**每次只单独 play 一路**，在 0.6s 窗口内
## 逐帧采样 SFX 总线峰值（AudioServer.get_bus_peak_volume_left/right_db，取较大者，
## 再取窗口内最大值），比较不同位置的峰值差。
##
## 场景基准（viewport 1920x1080，stretch=canvas_items/expand）：
##   P_cam0    (0,0)      相机节点处
##   P_near100 (100,0)    相机正前方 100px
##   P_far2000 (2000,0)   2000px 外
##   P_scr     屏幕中心    有相机(DRAG_CENTER @0,0)时世界坐标=(0,0)；无相机(画布恒等)时=(960,540)
##
## 三种工况：
##   B1 相机 current（DRAG_CENTER @ 原点）
##   B2 相机 disabled（= 无任何 Camera2D / AudioListener2D）
##   B3 相机 current 且 anchor_mode=FIXED_TOP_LEFT @ 原点 → 屏幕中心世界坐标≠相机节点坐标，
##      用来判定监听点跟随「相机节点」还是「屏幕中心」
##
## 运行（带窗口，推荐）：
##   <godot> --path stick-world res://tests/dev/audio_2d_probe.tscn
## 注意：本探针**不静音**（需要真实混合出峰值），会连续播 ~7s 雨声。

const WAV := "res://assets/audio/sfx/rain_loop.wav"
const BUS_NAME := "SFX"
const MEASURE_SEC := 0.60
const FLOOR_WAIT := 0.25

var _idx: int = -1
var _cam: Camera2D
var _p_cam0: AudioStreamPlayer2D
var _p_near: AudioStreamPlayer2D
var _p_far: AudioStreamPlayer2D
var _p_scr: AudioStreamPlayer2D
var _players: Array[AudioStreamPlayer2D] = []
var _sweep: Dictionary = {}  # 距离(int) -> AudioStreamPlayer2D，用于 B1 的距离扫描
const SWEEP_DISTS := [0, 200, 500, 800, 990, 1001, 1200, 2000]
var _sample := false
var _peak := -INF
var _pre := -INF


func _ready() -> void:
	if DisplayServer.get_name() != "headless":
		# 带窗口时别抢焦点（本探针不静音，需要真实峰值）
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, false)
	_idx = _ensure_bus(BUS_NAME)
	var stream: AudioStream = load(WAV)
	var vp := get_viewport_rect().size

	_cam = Camera2D.new()
	_cam.position = Vector2.ZERO
	add_child(_cam)
	_cam.make_current()

	_p_cam0 = _mk("P_cam0", Vector2.ZERO, stream)
	_p_near = _mk("P_near100", Vector2(100, 0), stream)
	_p_far = _mk("P_far2000", Vector2(2000, 0), stream)
	_p_scr = _mk("P_screencenter", vp * 0.5, stream)
	for d in SWEEP_DISTS:
		_sweep[d] = _mk("P_sw%d" % d, Vector2(d, 0), stream)

	print("[B] driver=%s mix_rate=%.0f viewport=%s bus=%s(idx=%d)" % [
		AudioServer.get_driver_name(), AudioServer.get_mix_rate(),
		str(vp), BUS_NAME, _idx])
	print("[B] 播放器: cam0=(0,0) near=(100,0) far=(2000,0) scr=%s  均 max_distance=1000 vol=0dB" % str(vp * 0.5))
	_run()


func _ensure_bus(n: String) -> int:
	var i := AudioServer.get_bus_index(n)
	if i != -1:
		return i
	i = AudioServer.bus_count
	AudioServer.add_bus(i)
	AudioServer.set_bus_name(i, n)
	AudioServer.set_bus_send(i, "Master")
	return i


func _mk(n: String, pos: Vector2, s: AudioStream) -> AudioStreamPlayer2D:
	var p := AudioStreamPlayer2D.new()
	p.name = n
	p.stream = s
	p.bus = BUS_NAME
	p.volume_db = 0.0
	p.max_distance = 1000.0
	p.attenuation = 1.0
	p.position = pos
	add_child(p)
	_players.append(p)
	return p


func _bus_peak_db() -> float:
	return maxf(
		AudioServer.get_bus_peak_volume_left_db(_idx, 0),
		AudioServer.get_bus_peak_volume_right_db(_idx, 0))


func _process(_d: float) -> void:
	if not _sample:
		return
	var v := _bus_peak_db()
	if v > _peak:
		_peak = v


func _run() -> void:
	var floor_db := await _measure(null, "静音底噪(全停)")
	print("[B] ---- B1: 相机 current（DRAG_CENTER @ 原点）----")
	var b1_near := await _measure(_p_near, "B1 near(100,0)")
	var b1_far := await _measure(_p_far, "B1 far(2000,0)")
	var b1_cam0 := await _measure(_p_cam0, "B1 cam0(0,0)")
	var b1_scr := await _measure(_p_scr, "B1 scr(960,540)")
	print("[B] B1 差值 near-far = %.2f dB （max_distance=1000 生效时远端应显著更轻，预期>=10dB）" % (b1_near - b1_far))

	print("[B] ---- B1 距离扫描（监听点=(0,0)，max_distance=1000，attenuation=1.0）----")
	for d in SWEEP_DISTS:
		var db := await _measure(_sweep[d], "B1 距离%4d px" % d)
		print("[B]   dist=%4d  peak=%7.2f dB" % [d, db])

	print("[B] ---- B2: 相机 disabled（无 Camera2D/无 AudioListener2D）----")
	_cam.enabled = false
	await _wait(0.20)
	var b2_near := await _measure(_p_near, "B2 near(100,0)")
	var b2_far := await _measure(_p_far, "B2 far(2000,0)")
	var b2_cam0 := await _measure(_p_cam0, "B2 cam0(0,0)")
	var b2_scr := await _measure(_p_scr, "B2 scr(960,540)")
	print("[B] B2 差值 near-far = %.2f dB" % (b2_near - b2_far))

	print("[B] ---- B3: 相机 current + anchor=FIXED_TOP_LEFT @ 原点（解耦 相机节点 vs 屏幕中心）----")
	_cam.anchor_mode = Camera2D.ANCHOR_MODE_FIXED_TOP_LEFT
	_cam.enabled = true
	_cam.make_current()
	_cam.force_update_scroll()
	await _wait(0.20)
	var center := _cam.get_screen_center_position()
	_p_scr.position = center
	print("[B] B3 相机节点=%s  屏幕中心世界坐标=%s" % [str(_cam.global_position), str(center)])
	var b3_cam0 := await _measure(_p_cam0, "B3 相机节点(0,0)")
	var b3_scr := await _measure(_p_scr, "B3 屏幕中心")
	print("[B] B3 差值 屏幕中心-相机节点 = %.2f dB" % (b3_scr - b3_cam0))

	print("==================== B 结论 ====================")
	print("[B] B1 near=%.2f far=%.2f cam0=%.2f scr=%.2f  |差 near-far|=%.2f  → %s" % [
		b1_near, b1_far, b1_cam0, b1_scr, b1_near - b1_far,
		"距离衰减生效(仅有 Camera2D 即可定位)" if b1_near - b1_far >= 10.0 else "未见显著衰减"])
	print("[B] B2(无相机) near=%.2f far=%.2f cam0=%.2f scr=%.2f  → %s" % [
		b2_near, b2_far, b2_cam0, b2_scr,
		("屏幕中心(%.2f)亮而原点(%.2f)轻 → 监听点=屏幕中心" % [b2_scr, b2_cam0])
			if b2_scr - b2_cam0 >= 6.0 else
			("原点(%.2f)亮 → 监听点=世界原点/相机默认位" % b2_cam0)])
	print("[B] B3(解耦) 相机节点=%.2f 屏幕中心=%.2f 差值=%.2f → %s" % [
		b3_cam0, b3_scr, b3_scr - b3_cam0,
		("监听点跟随相机节点坐标" if b3_cam0 - b3_scr >= 6.0 else
		("监听点跟随屏幕中心" if b3_scr - b3_cam0 >= 6.0 else "两者相近(无法区分)"))])
	print("[B] 静音底噪=%.2f dB（作为读数下限参考）" % floor_db)

	get_tree().quit()


func _measure(p: AudioStreamPlayer2D, label: String) -> float:
	for q in _players:
		q.stop()
	await _wait(FLOOR_WAIT)
	_pre = _bus_peak_db()
	_peak = -INF
	_sample = true
	if p != null:
		p.play()
	await _wait(MEASURE_SEC)
	_sample = false
	if p != null:
		p.stop()
	print("[B] %-24s pre=%7.2f dB  peak=%7.2f dB" % [label, _pre, _peak])
	return _peak


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec, true).timeout
