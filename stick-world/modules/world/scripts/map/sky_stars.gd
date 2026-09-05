class_name SkyStars
extends Node2D
## 天体层 —— 星野 + 日月运行 + 极光 + 流星（Terraria 逆向，程序绘制零贴图）。
##
## 挂在 SkyDecor 最底层（factor 0.08 近乎屏幕钉死 = 无限远）。
## 日月运行公式为 Terraria Main.DrawSunAndMoon 直译：**线性横穿 + 抛物线高度 +
## 地平线放大**（x = 进度×屏宽；y = 顶 + |2t-1|²×250；scale = 1.2 - 0.4p）。
## 夜晚星野/极光/流星淡入，与 PostProcessLayer 共用同一亮度→day_t 公式。
## 极光横跨全图宽度（用户明确要求背景跨全图；星星本就全图分布）。

## 视差因子（SkyDecor 注册用；越小越接近屏幕钉死=越远）
const FACTOR: float = 0.08
## 星星横向覆盖（factor 0.08 下相机走满全图，本地窗口仅平移 8%）
const STAR_SPAN_X: float = 9800.0
const STAR_TOP: float = 80.0
const STAR_BOTTOM: float = 640.0
const REDRAW_HZ: float = 12.0
## 极光：全图跨度、条带步进、条带定义 [基线y, 振幅, 频率, 色相档]
const AURORA_STEP: float = 24.0
const AURORA_RIBBONS: Array = [
	[150.0, 64.0, 0.0042, 0],
	[205.0, 88.0, 0.0031, 1],
	[258.0, 52.0, 0.0056, 2],
]
## 日月（Terraria 昼 54000 tick ≈ 我们 5..21 时；夜 19..5 时）
const SUN_HOUR_START: float = 5.0
const SUN_HOUR_END: float = 21.0
const CELESTIAL_SPAN: float = 1250.0   # 横穿全程（可见窗宽 + 两侧余量）
const CELESTIAL_TOP: float = 170.0     # 正午高度
const CELESTIAL_DROP: float = 250.0    # 晨昏下沉（Terraria ×250 直译）

## 星星表 [{x, y, r, phase, speed, big}]（固定种子，分布确定）
var _stars: Array = []
## 流星 {x, y, vx, vy, life}；空=无
var _shoot: Dictionary = {}
var _next_shoot: float = 8.0
var _env: Node = null
var _time: float = 0.0
## 夜间强度（0=白天 1=深夜，平滑过渡）
var _night: float = 0.0
var _redraw_acc: float = 99.0
## 游戏内天数（夜→昼跳变检测递增；Terraria Main.cs:20207 每晚 moonPhase++ 同构）
var _day_count: int = 0
var _last_hour: float = 12.0


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
	_advance_day_count()
	_update_shooting_star(delta)
	# 日月/星野/极光全程有内容（白昼太阳也在走），恒节流重绘
	_redraw_acc += delta
	if _redraw_acc >= 1.0 / REDRAW_HZ:
		_redraw_acc = 0.0
		queue_redraw()


## 天数推进：hour 从深夜（>21）跳回清晨（<8）= 新的一天（每夜月相 +1 的计数基础）
func _advance_day_count() -> void:
	var hour: float = _env_time()
	if _last_hour > 21.0 and hour < 8.0:
		_day_count += 1
	_last_hour = hour


func _draw() -> void:
	var center_x: float = _window_center_x()
	var hour: float = _env_time()
	_draw_aurora()
	if _night > 0.01:
		_draw_starfield()
		_draw_shooting_star()
	_draw_moon_path(center_x, hour)
	_draw_sun(center_x, hour)


# ─────────────────────────────── 星野 ────────────────────────────────

func _draw_starfield() -> void:
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


## 流星（Terraria Star.falling 同构）：夜间随机一颗划过，尾迹渐隐
func _update_shooting_star(delta: float) -> void:
	if _night < 0.5:
		_shoot = {}
		return
	if _shoot.is_empty():
		_next_shoot -= delta
		if _next_shoot <= 0.0:
			_next_shoot = randf_range(6.0, 18.0)
			var dir: float = 1.0 if randf() < 0.5 else -1.0
			_shoot = {
				"x": _window_center_x() - dir * randf_range(700.0, 1100.0),
				"y": randf_range(60.0, 260.0),
				"vx": dir * randf_range(220.0, 330.0),
				"vy": randf_range(120.0, 180.0),
				"life": 0.9,
			}
	else:
		_shoot["x"] += _shoot["vx"] * delta
		_shoot["y"] += _shoot["vy"] * delta
		_shoot["life"] -= delta
		if float(_shoot["life"]) <= 0.0:
			_shoot = {}


func _draw_shooting_star() -> void:
	if _shoot.is_empty():
		return
	var head := Vector2(_shoot["x"], _shoot["y"])
	var tail: Vector2 = head - Vector2(_shoot["vx"], _shoot["vy"]) * 0.22
	var a: float = clampf(float(_shoot["life"]) / 0.9, 0.0, 1.0) * _night
	# 三段尾迹渐隐
	var mid: Vector2 = head.lerp(tail, 0.5)
	draw_line(head, mid, Color(1, 1, 1, a * 0.95), 2.0)
	draw_line(mid, tail, Color(0.85, 0.9, 1.0, a * 0.45), 1.5)
	draw_line(tail, tail.lerp(head, -0.35), Color(0.8, 0.85, 1.0, a * 0.2), 1.0)
	draw_circle(head, 1.8, Color(1, 1, 1, a))


# ─────────────────────────────── 极光 ────────────────────────────────

## 极光波带：竖条序列沿正弦起伏成"帷幕"，绿为主、一条紫罗兰点缀；
## 每列两段（下亮上淡）近似垂直渐变，整体缓慢漂移。**横跨全图**（非窗口）。
func _draw_aurora() -> void:
	if _night <= 0.01:
		return
	var base_a: float = 0.16 * _night
	var drift: float = sin(_time * 0.05) * 90.0
	for rb in AURORA_RIBBONS:
		var y0: float = rb[0]
		var amp: float = rb[1]
		var freq: float = rb[2]
		var hue_i: int = rb[3]
		# 色档：绿 / 青绿 / 紫罗兰（点缀）
		var core := Color(0.35, 0.95, 0.55) if hue_i == 0 \
				else (Color(0.30, 0.85, 0.75) if hue_i == 1 else Color(0.62, 0.45, 0.95))
		var x: float = -STAR_SPAN_X * 0.5 + drift
		while x < STAR_SPAN_X * 0.5 + drift:
			var h: float = amp * (0.6 + 0.4 * sin(x * freq + _time * 0.35)) \
					+ amp * 0.35 * sin(x * freq * 2.7 - _time * 0.6)
			if h > 8.0:
				# 列强度沿帷幕走向起伏（涟漪感）
				var band: float = 0.55 + 0.45 * sin(x * freq * 0.5 + _time * 0.22 + y0)
				var a_lo: float = base_a * band
				var a_hi: float = base_a * band * 0.35
				var mid_y: float = y0 - h * 0.45
				draw_rect(Rect2(x, mid_y, AURORA_STEP * 0.9, h * 0.45), Color(core, a_lo))
				draw_rect(Rect2(x, y0 - h, AURORA_STEP * 0.9, h * 0.55), Color(core.r * 0.8, core.g, core.b, a_hi))
			x += AURORA_STEP


# ─────────────────────────────── 日月（Terraria 公式） ────────────────────────────────

## 天体横穿进度（0..1；不在时段返回 -1）
static func _traverse(hour: float, start_h: float, end_h: float) -> float:
	if hour >= start_h and hour <= end_h:
		return (hour - start_h) / (end_h - start_h)
	# 跨午夜时段（月亮 19..29 = 次日 5 点）
	if end_h > 24.0 and hour < end_h - 24.0:
		return (hour + 24.0 - start_h) / (end_h - start_h)
	return -1.0


## Terraria Main.DrawSunAndMoon 直译：
## x = t × 跨度（线性）；y = 顶 + |2t-1|² × 250（抛物线）；scale = 1.2 - 0.4p
static func _celestial_pos(t: float, center_x: float) -> Dictionary:
	var p: float = pow(absf(t * 2.0 - 1.0), 2.0)
	return {
		"pos": Vector2(center_x - CELESTIAL_SPAN * 0.5 + t * CELESTIAL_SPAN,
				CELESTIAL_TOP + p * CELESTIAL_DROP),
		"p": p,
		"scale": 1.2 - 0.4 * p,
	}


## 太阳：暖金圆盘 + 双层光晕，晨昏放大贴地（白昼可见，夜间淡出）
func _draw_sun(center_x: float, hour: float) -> void:
	var day_t: float = 1.0 - _night
	if day_t <= 0.01:
		return
	var t: float = _traverse(hour, SUN_HOUR_START, SUN_HOUR_END)
	if t < 0.0:
		return
	var c: Dictionary = _celestial_pos(t, center_x)
	var p: Vector2 = c["pos"]
	var s: float = c["scale"]
	var r: float = 34.0 * s
	var a: float = day_t
	# 晨昏偏橙（SetBackColor 午后→日落暖红 ramp 的简化连续版）
	var warm: float = clampf(c["p"] * 1.4, 0.0, 1.0)
	var disc := Color(1.0, 0.92 - 0.18 * warm, 0.62 - 0.12 * warm, a)
	draw_circle(p, r * 2.1, Color(1.0, 0.85, 0.5, 0.06 * a))
	draw_circle(p, r * 1.45, Color(1.0, 0.88, 0.55, 0.14 * a))
	draw_circle(p, r, disc)


## 月亮：奶油圆盘 + 光晕 + 环形山 + **月相**（8 相随天数，Terraria 每晚
## moonPhase++ 同构）——阴影圆从一侧扫过月面近似盈亏
func _draw_moon_path(center_x: float, hour: float) -> void:
	if _night <= 0.01:
		return
	var t: float = _traverse(hour, 19.0, 29.0)
	if t < 0.0:
		return
	var c: Dictionary = _celestial_pos(t, center_x)
	var p: Vector2 = c["pos"]
	var s: float = c["scale"]
	var r: float = 26.0 * s
	draw_circle(p, r * 2.2, Color(0.95, 0.95, 0.9, 0.05 * _night))
	draw_circle(p, r * 1.5, Color(0.95, 0.95, 0.9, 0.10 * _night))
	draw_circle(p, r, Color(0.96, 0.95, 0.88, 0.95 * _night))
	var crater := Color(0.80, 0.80, 0.74, 0.35 * _night)
	draw_circle(p + Vector2(-8, -5) * s, 5.5 * s, crater)
	draw_circle(p + Vector2(7, 6) * s, 4.0 * s, crater)
	draw_circle(p + Vector2(9, -9) * s, 2.6 * s, crater)
	# 月相：phase 0..7（0=满月 4=新月），阴影圆横向偏移扫过月面；
	# off = 1.5r×(1-p/4)：p0=+1.5r(全露/满) → p4=0(全遮/新) → p7=-1.125r(反向娥眉)
	var phase: int = _day_count % 8
	var shadow_r: float = r * 1.04
	var off: float = (1.0 - float(phase) / 4.0) * shadow_r * 1.5
	draw_circle(p + Vector2(off, 0.0), shadow_r, Color(0.10, 0.12, 0.20, 0.96 * _night))


# ─────────────────────────────── 工具 ────────────────────────────────

## 可见窗口的本地中心：由自身被视差驱动的 position 反推（factor<1 时
## position.x = cam_x*(1-factor) → cam_x = pos.x/(1-factor) → 窗口中心 = cam_x*factor）
func _window_center_x() -> float:
	return position.x * FACTOR / (1.0 - FACTOR)


## 当前时刻（env 缺失按正午）
func _env_time() -> float:
	if _env == null or not is_instance_valid(_env):
		_env = _find_env()
		if _env == null:
			return 12.0
	if _env.has_method("get_time_of_day"):
		return float(_env.get_time_of_day())
	return 12.0


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
