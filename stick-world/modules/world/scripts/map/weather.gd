class_name Weather
extends Node2D
## 天气系统 —— Terraria 式降雨（Rain.cs 机制移植）。
##
## 状态机：晴（90-180s）↔ 雨（45-90s，强度 ramp 0→1→0 即 cloudAlpha 同构）。
## 雨粒子：屏幕跟随带内斜线（速度含风分量，rotation 沿速度——Rain 粒子带
## 旋转的同构），密度随强度。雨声循环（gen_sfx rain_loop 分层雨声）经
## AudioManager 天气通道播放。开局 90s 保护期（Demo 第一分钟要好看）。
## 雨天云层加浓：通知兄弟 SkyDecor 提高云 alpha 上限。

const DRY_MIN: float = 90.0
const DRY_MAX: float = 180.0
const RAIN_MIN: float = 45.0
const RAIN_MAX: float = 90.0
## 开局无雨保护（秒）
const START_GRACE: float = 90.0
## 雨滴池上限（Terraria maxRain=750；我们屏幅小取 140）
const RAIN_MAX_DROPS: int = 140
const DROP_SPEED_Y: float = 980.0
const REDRAW_HZ: float = 30.0

var _rain_t: float = 0.0        # 雨强度 0..1
var _raining: bool = false
var _next_change: float = START_GRACE + randf_range(DRY_MIN, DRY_MAX)
var _drops: Array = []          # [{x, y, vx, vy, len}]
var _cam: Camera2D = null
var _wind_dir: float = 1.0
var _time: float = 0.0
var _redraw_acc: float = 99.0
var _sky: Node = null


func _ready() -> void:
	z_index = WorldZ.OVERLAY_HINT
	call_deferred("_find_refs")


func _find_refs() -> void:
	_cam = get_viewport().get_camera_2d()
	_sky = get_parent().get_node_or_null("SkyDecor") if get_parent() != null else null


func _process(delta: float) -> void:
	_time += delta
	# 状态机
	_next_change -= delta
	if _next_change <= 0.0:
		_raining = not _raining
		_next_change = randf_range(RAIN_MIN, RAIN_MAX) if _raining \
				else randf_range(DRY_MIN, DRY_MAX)
		if not _raining and AudioManager != null:
			AudioManager.stop_weather()
	# 强度 ramp
	_rain_t = clampf(_rain_t + (delta / 6.0 if _raining else -delta / 6.0), 0.0, 1.0)
	if _raining and _rain_t > 0.15 and AudioManager != null:
		AudioManager.play_weather("res://assets/audio/sfx/rain_loop.wav", 0.55 * _rain_t)
	# 通知云层加浓
	if _sky != null and is_instance_valid(_sky) and _sky.has_method("set_rainy"):
		_sky.set_rainy(_rain_t)
	_update_drops(delta)
	_redraw_acc += delta
	if _redraw_acc >= 1.0 / REDRAW_HZ:
		_redraw_acc = 0.0
		queue_redraw()


## 雨滴池：按强度决定活跃数（MakeRain 密度∝cloudAlpha 同构），出屏回绕
func _update_drops(delta: float) -> void:
	if _cam == null:
		_cam = get_viewport().get_camera_2d()
		if _cam == null:
			return
	var center: Vector2 = _cam.get_screen_center_position()
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var half: Vector2 = vp * 0.5 + Vector2(80.0, 0.0)
	var active: int = int(float(RAIN_MAX_DROPS) * _rain_t)
	_wind_dir = signf(sin(_time * 0.05) * 1.1)
	var vx: float = _wind_dir * 240.0
	# 池按需扩
	while _drops.size() < active:
		_drops.append({
			"x": center.x + randf_range(-half.x, half.x),
			"y": center.y - half.y - randf_range(0.0, 400.0),
			"vx": vx, "vy": DROP_SPEED_Y * randf_range(0.9, 1.1),
			"len": randf_range(14.0, 26.0),
		})
	# 多余的立即回收（强度下降时）
	if _drops.size() > active:
		_drops.resize(active)
	for d in _drops:
		d["x"] += d["vx"] * delta
		d["y"] += d["vy"] * delta
		d["vx"] = vx  # 风统一（Terraria 雨滴速度全场一致的同构）
		if d["y"] > center.y + half.y:
			d["y"] = center.y - half.y - randf_range(0.0, 60.0)
			d["x"] = center.x + randf_range(-half.x, half.x)
		if d["x"] < center.x - half.x - 60.0 or d["x"] > center.x + half.x + 60.0:
			d["x"] = center.x + randf_range(-half.x, half.x)


func _draw() -> void:
	if _drops.is_empty():
		return
	var col := Color(0.62, 0.72, 0.85, 0.42 * _rain_t)
	var col_soft := Color(0.62, 0.72, 0.85, 0.22 * _rain_t)
	for d in _drops:
		var dir := Vector2(d["vx"], d["vy"]).normalized()
		var p := Vector2(d["x"], d["y"])
		draw_line(p, p - dir * float(d["len"]), col_soft, 1.2)
		draw_line(p, p - dir * float(d["len"]) * 0.45, col, 1.4)


## 当前雨强度（验证脚本用）
func get_rain_intensity() -> float:
	return _rain_t


## 强制切换天气（验证/演示用）
func force_rain(on: bool) -> void:
	_raining = on
	_next_change = randf_range(RAIN_MIN, RAIN_MAX) if on else randf_range(DRY_MIN, DRY_MAX)
	if not on:
		AudioManager.stop_weather()
