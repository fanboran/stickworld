class_name SkyBirds
extends Node2D
## 远空飞鸟群 —— 天空生命感（程序绘制剪影小鸟，隔一阵成群横穿远空）。
##
## 挂在 SkyDecor 星空层之上、山层之下（factor 0.35，比山更远的扫动速率，
## 会被山脊短暂遮挡——纵深感的免费细节）。扑翼为两段折线的正弦摆动，
## 夜间淡出（鸟归巢）。spawn_flock() 供验证脚本确定性触发。

## 视差因子（SkyDecor 注册用）
const FACTOR: float = 0.35
const FLOCK_INTERVAL_MIN: float = 7.0
const FLOCK_INTERVAL_MAX: float = 16.0
const REDRAW_HZ: float = 15.0
## 可见半窗宽估计（含变焦冗余；越界判定用，无须精确）
const WINDOW_HALF: float = 700.0
const MARGIN: float = 260.0

## 当前鸟群 {dir, speed, y, x, birds:[{dx, dy, phase, flap, scale}]}；空=无鸟
var _flock: Dictionary = {}
var _next_flock: float = 4.0
var _env: Node = null
var _time: float = 0.0
var _day: float = 1.0
var _redraw_acc: float = 0.0


func _process(delta: float) -> void:
	_time += delta
	_day = lerpf(_day, _day_factor(), clampf(delta * 2.0, 0.0, 1.0))
	if _flock.is_empty():
		_next_flock -= delta
		if _next_flock <= 0.0 and _day > 0.25:
			spawn_flock()
	else:
		_flock["x"] += _flock["speed"] * _flock["dir"] * delta
		for b in _flock["birds"]:
			b["phase"] += b["flap"] * delta
		if _beyond_window():
			_flock = {}
			_next_flock = randf_range(FLOCK_INTERVAL_MIN, FLOCK_INTERVAL_MAX)
	_redraw_acc += delta
	if _redraw_acc >= 1.0 / REDRAW_HZ:
		_redraw_acc = 0.0
		queue_redraw()


## 生成一群鸟：从可见窗外一侧入场，斜纵队（前鸟高后鸟低），3-5 只
func spawn_flock() -> void:
	var dir: int = 1 if randf() < 0.5 else -1
	var count: int = randi_range(3, 5)
	var birds: Array = []
	for i in count:
		birds.append({
			"dx": -dir * float(i) * randf_range(24.0, 40.0),
			"dy": float(i) * randf_range(-4.0, 10.0) + randf_range(-8.0, 8.0),
			"phase": randf() * TAU,
			"flap": randf_range(7.0, 10.0),
			"scale": randf_range(0.8, 1.15),
		})
	_flock = {
		"dir": dir,
		"speed": randf_range(60.0, 85.0),
		"y": randf_range(120.0, 320.0),
		"x": _window_center_x() - dir * (WINDOW_HALF + MARGIN),
		"birds": birds,
	}
	_play_chirp()


## 远处一声啁啾（视听配对：鸟群入镜时鸣叫；三变体随机）
func _play_chirp() -> void:
	if AudioManager == null:
		return
	var pick: int = randi() % 3
	AudioManager.play_event("bird_chirp_%s" % ["a", "b", "c"][pick])


func _draw() -> void:
	if _flock.is_empty():
		return
	# 夜间淡出（鸟归巢），白天最深剪影
	var alpha: float = (0.35 + 0.65 * _day) * 0.9
	var col := Color(0.16, 0.18, 0.23, alpha)
	for b in _flock["birds"]:
		var s: float = b["scale"]
		var p := Vector2(_flock["x"] + b["dx"], _flock["y"] + b["dy"] + sin(_time * 1.7 + b["phase"]) * 3.0)
		var flap: float = sin(b["phase"])
		var wing := Vector2(8.0 * s, flap * 5.0 * s)
		var wing_col := Color(col, alpha)
		draw_line(p, p + wing, wing_col, 2.2 * s)
		draw_line(p, p + Vector2(-wing.x, wing.y), wing_col, 2.2 * s)
		draw_circle(p, 1.5 * s, wing_col)


## 鸟群是否已飞出可见窗另一侧
func _beyond_window() -> bool:
	var edge: float = _window_center_x() + _flock["dir"] * (WINDOW_HALF + MARGIN)
	return (_flock["dir"] > 0 and _flock["x"] > edge) \
			or (_flock["dir"] < 0 and _flock["x"] < edge)


## 可见窗口的本地中心（由视差驱动的自身 position 反推，见 SkyStars 同名方法）
func _window_center_x() -> float:
	return position.x * FACTOR / (1.0 - FACTOR)


## 昼夜因子（与 PostProcessLayer 同式）
func _day_factor() -> float:
	if _env == null or not is_instance_valid(_env):
		_env = _find_env()
		if _env == null:
			return 1.0
	if not _env.has_method("get_current_light_color"):
		return 1.0
	var lum: float = _env.get_current_light_color().get_luminance()
	return clampf((lum - 0.55) / 0.35, 0.0, 1.0)


## 找环境系统：先按生产主场景路径，再沿祖先链兜底（见 sky_stars.gd 同名方法）
func _find_env() -> Node:
	var env := get_tree().root.get_node_or_null("GameRoot/EnvironmentSystem")
	if env != null:
		return env
	var a := get_parent()
	while a != null:
		var e := a.get_node_or_null("EnvironmentSystem")
		if e != null:
			return e
		a = a.get_parent()
	return null


## 当前鸟数（验证脚本用）
func get_bird_count() -> int:
	return _flock.get("birds", []).size()
