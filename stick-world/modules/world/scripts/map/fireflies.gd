class_name Fireflies
extends Node2D
## 夜间萤火虫 —— 昼夜视觉语言的地面层（星月在天、萤火在野）。
##
## 夜晚（环境亮度低）淡入：暖黄绿光点在近地处游弋、周期性明灭闪烁
## （闪烁为短脉冲不是平滑呼吸——真萤火虫是 flash 不是 glow）。
## 白天零重绘省性能；昼夜判定与 SkyStars/PostProcessLayer 同式。

const COUNT: int = 22
## 游弋范围（相机中心周围；y 偏下半——萤火虫贴地飞）
const AREA_HALF: Vector2 = Vector2(1300.0, 200.0)
const AREA_Y_BIAS: float = 190.0
const REDRAW_HZ: float = 30.0

var _cam: Camera2D = null
var _env: Node = null
var _seeds: Array = []
var _t: float = 0.0
var _night: float = 0.0
var _drawn: bool = false
var _redraw_acc: float = 99.0


func _ready() -> void:
	z_index = 40  # 世界之上、UI 之下（同 AmbientMotes 层）
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260905
	for i in COUNT:
		_seeds.append({
			"ox": rng.randf_range(-AREA_HALF.x, AREA_HALF.x),
			"oy": rng.randf_range(-AREA_HALF.y, AREA_HALF.y) + AREA_Y_BIAS,
			"phase": rng.randf() * TAU,
			"speed": rng.randf_range(0.15, 0.45),
			"drift": rng.randf_range(8.0, 22.0),
			"blink": rng.randf_range(1.6, 3.2),  # 闪烁周期（秒）
			"size": rng.randf_range(1.6, 2.8),
		})
	call_deferred("_find_camera")


func _find_camera() -> void:
	_cam = get_viewport().get_camera_2d()


func _process(delta: float) -> void:
	_t += delta
	_night = lerpf(_night, 1.0 - _day_factor(), clampf(delta * 1.5, 0.0, 1.0))
	if _cam == null:
		_cam = get_viewport().get_camera_2d()
	_redraw_acc += delta
	if _night > 0.01:
		if _redraw_acc >= 1.0 / REDRAW_HZ:
			_redraw_acc = 0.0
			queue_redraw()
	elif _drawn:
		queue_redraw()  # 补一次重绘清屏


func _draw() -> void:
	if _night <= 0.01 or _cam == null:
		_drawn = false
		return
	_drawn = true
	# 发光体除法补偿：穿透 CanvasModulate 夜间压暗（星月同款，见 EnvironmentAPI）
	var cm: Color = _current_cm()
	var center: Vector2 = _cam.get_screen_center_position()
	for sd in _seeds:
		var p := Vector2(
			center.x + sd["ox"] + sin(_t * sd["speed"] + sd["phase"]) * sd["drift"],
			center.y + sd["oy"] + sin(_t * sd["speed"] * 1.3 + sd["phase"] * 2.1) * sd["drift"] * 0.35)
		# 短脉冲闪烁：sin^4 → 亮窗窄、熄灭长（真萤火虫是 flash 不是 glow）
		var flash: float = pow(maxf(0.0, sin(_t * TAU / sd["blink"] + sd["phase"])), 4.0)
		var a: float = _night * flash
		if a < 0.02:
			continue
		# 柔光晕 + 亮核
		draw_circle(p, sd["size"] * 3.2, EnvironmentAPI.unmodulate(Color(0.78, 1.0, 0.45, 0.10 * a), cm))
		draw_circle(p, sd["size"], EnvironmentAPI.unmodulate(Color(0.85, 1.0, 0.55, 0.9 * a), cm))


## 当前 CanvasModulate 色（补偿除法用；env 缺失按白 = 不补偿）
func _current_cm() -> Color:
	if _env == null or not is_instance_valid(_env):
		_env = _find_env()
	if _env != null and _env.has_method("get_current_light_color"):
		return _env.get_current_light_color()
	return Color.WHITE


## 昼夜因子（与 SkyStars 同式：生产路径 → 祖先链兜底）
func _day_factor() -> float:
	if _env == null or not is_instance_valid(_env):
		_env = _find_env()
		if _env == null:
			return 1.0
	if not _env.has_method("get_current_light_color"):
		return 1.0
	var lum: float = _env.get_current_light_color().get_luminance()
	return clampf((lum - 0.55) / 0.35, 0.0, 1.0)


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


## 夜间强度（验证脚本用）
func get_night_factor() -> float:
	return _night
