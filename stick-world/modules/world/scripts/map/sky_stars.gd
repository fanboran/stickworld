class_name SkyStars
extends Node2D
## 夜空层 —— 星野 + 月亮（Terraria 式天空生命感，程序绘制零贴图）。
##
## 挂在 SkyDecor 最底层（factor 0.08 近乎屏幕钉死 = 无限远）：白天天空干净，
## 夜晚（环境亮度低）星野淡入 + 月亮升起，与 PostProcessLayer 共用同一
## 亮度→day_t 公式，淡入节奏与后处理夜晚转冷完全同步。
## 星星在山脊后面升起（绘制序在山层之下），月亮带双层光晕与环形山。

## 视差因子（SkyDecor 注册用；越小越接近屏幕钉死=越远）
const FACTOR: float = 0.08
## 星星横向覆盖（factor 0.08 下相机走满全图，本地窗口仅平移 8%）
const STAR_SPAN_X: float = 9800.0
const STAR_TOP: float = 80.0
const STAR_BOTTOM: float = 640.0
const REDRAW_HZ: float = 12.0

## 星星表 [{x, y, r, phase, speed, big}]（固定种子，分布确定）
var _stars: Array = []
var _env: Node = null
var _time: float = 0.0
## 夜间强度（0=白天 1=深夜，平滑过渡）
var _night: float = 0.0
var _drawn: bool = false
var _redraw_acc: float = 99.0


func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260905
	for i in 380:
		_stars.append({
			"x": rng.randf_range(-STAR_SPAN_X * 0.5, STAR_SPAN_X * 0.5),
			"y": rng.randf_range(STAR_TOP, STAR_BOTTOM),
			"r": rng.randf_range(0.8, 1.8),
			"phase": rng.randf_range(0.0, TAU),
			"speed": rng.randf_range(0.6, 2.2),
			"big": rng.randf() < 0.08,
		})


func _process(delta: float) -> void:
	_time += delta
	_night = lerpf(_night, 1.0 - _day_factor(), clampf(delta * 2.0, 0.0, 1.0))
	_redraw_acc += delta
	# 夜间按节流频率重绘（闪烁）；白天零重绘省性能——但从夜间切入白天
	# 需补一次重绘清屏（_drawn 标记）
	if _night > 0.01:
		if _redraw_acc >= 1.0 / REDRAW_HZ:
			_redraw_acc = 0.0
			queue_redraw()
	elif _drawn:
		queue_redraw()


func _draw() -> void:
	if _night <= 0.01:
		_drawn = false
		return
	_drawn = true
	var center_x: float = _window_center_x()
	for s in _stars:
		var tw: float = 0.55 + 0.45 * sin(_time * s["speed"] + s["phase"])
		var a: float = _night * tw
		var col := Color(0.92, 0.94, 1.0, a)
		draw_circle(Vector2(s["x"], s["y"]), s["r"], col)
		# 少数大星带十字 sparkle
		if s["big"] and a > 0.5:
			var l: float = s["r"] * 10.0 * (a - 0.5)
			var spark := Color(0.92, 0.94, 1.0, a * 0.6)
			draw_line(Vector2(s["x"] - l, s["y"]), Vector2(s["x"] + l, s["y"]), spark, 1.0)
			draw_line(Vector2(s["x"], s["y"] - l), Vector2(s["x"], s["y"] + l), spark, 1.0)
	_draw_moon(center_x)


## 月亮：双层光晕 + 月面 + 三处环形山，微幅升沉
func _draw_moon(center_x: float) -> void:
	var p := Vector2(center_x + 380.0, 205.0 + sin(_time * 0.12) * 5.0)
	draw_circle(p, 58.0, Color(0.95, 0.95, 0.9, 0.05 * _night))
	draw_circle(p, 40.0, Color(0.95, 0.95, 0.9, 0.10 * _night))
	draw_circle(p, 26.0, Color(0.96, 0.95, 0.88, 0.95 * _night))
	var crater := Color(0.80, 0.80, 0.74, 0.35 * _night)
	draw_circle(p + Vector2(-8, -5), 5.5, crater)
	draw_circle(p + Vector2(7, 6), 4.0, crater)
	draw_circle(p + Vector2(9, -9), 2.6, crater)


## 可见窗口的本地中心：由自身被视差驱动的 position 反推（factor<1 时
## position.x = cam_x*(1-factor) → cam_x = pos.x/(1-factor) → 窗口中心 = cam_x*factor）
func _window_center_x() -> float:
	return position.x * FACTOR / (1.0 - FACTOR)


## 昼夜因子（与 PostProcessLayer 同式）：亮度→day_t，env 缺失按白天处理
func _day_factor() -> float:
	if _env == null or not is_instance_valid(_env):
		_env = _find_env()
		if _env == null:
			return 1.0
	if not _env.has_method("get_current_light_color"):
		return 1.0
	var lum: float = _env.get_current_light_color().get_luminance()
	return clampf((lum - 0.55) / 0.35, 0.0, 1.0)


## 找环境系统：先按生产主场景路径（root/GameRoot/EnvironmentSystem），
## 再沿祖先链找（测试装载时 GameRoot 嵌在非根层级，路径不通）
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


## 星星总数（验证脚本用）
func get_star_count() -> int:
	return _stars.size()
