class_name SkyStars
extends Node2D
## 天体层 —— 星野 + 日月运行 + 极光 + 流星（Terraria 逆向，程序绘制零贴图）。
##
## 挂在 SkyDecor 最底层（factor 0.08 近乎屏幕钉死 = 无限远）。
## - 日月运行：Main.DrawSunAndMoon 直译（线性横穿 + 抛物线高度 + 地平线放大）。
## - 星星：Star.cs 同构——twinkle 反弹式往返 [0.6,1.0] 同时驱动大小与透明度，
##   1/40 大星尺寸×2 且闪烁/自转减半，四芒 sparkle 随自转。
## - 极光：AuroraSky.cs 同构——HSL 色相随时间轮转（绿→青→蓝→紫），ADD 混合。
## 夜晚地表被 CanvasModulate 压至剪影，星/月/极光/流星经 EnvironmentAPI.
## unmodulate 除法补偿穿透压暗（泰拉瑞亚星星 alpha 独立于天色手算的同构）；
## 天空底色由 EnvironmentSystem 写入清屏色（不被 CanvasModulate 染）。

## 视差因子（SkyDecor 注册用；越小越接近屏幕钉死=越远）
const FACTOR: float = 0.08
## 星星横向覆盖（factor 0.08 下相机走满全图，本地窗口仅平移 8%）
const STAR_SPAN_X: float = 9800.0
const STAR_TOP: float = 80.0
const STAR_BOTTOM: float = 640.0
const REDRAW_HZ: float = 12.0
## 极光：条带步进、整体强度、色相缓慢漂移（漂移限幅在绿→青→紫区间内，
## 不再全色相轮转——轮转会扫过红/黄，夜空验收不似极光）、
## 条带定义 [基线y, 振幅, 频率, 色相偏移]——偏移使三带呈绿/青/紫主色
## （AuroraSky.cs：sat=1，lum 底0.5顶1.0）
const AURORA_STEP: float = 24.0
const AURORA_ALPHA: float = 0.26
const AURORA_HUE_SPEED: float = 0.004
const AURORA_RIBBONS: Array = [
	[150.0, 64.0, 0.0042, 0.40],
	[205.0, 88.0, 0.0031, 0.46],
	[258.0, 52.0, 0.0056, 0.72],
]
## 日月（Terraria 昼 54000 tick ≈ 我们 5..21 时；夜 19..5 时）
const SUN_HOUR_START: float = 5.0
const SUN_HOUR_END: float = 21.0
const CELESTIAL_SPAN: float = 1250.0   # 横穿全程（可见窗宽 + 两侧余量）
const CELESTIAL_TOP: float = 170.0     # 正午高度
const CELESTIAL_DROP: float = 250.0    # 晨昏下沉（Terraria ×250 直译）

## 星星表 [{x, y, r, tw, tw_v, big, rot, rot_v}]（固定种子，分布确定）
var _stars: Array = []
## 流星 {x, y, vx, vy, life}；空=无
var _shoot: Dictionary = {}
var _next_shoot: float = 8.0
var _env: Node = null
var _time: float = 0.0
## 夜间强度（0=白天 1=深夜，平滑过渡）
var _night: float = 0.0
## 天空亮度门控（天空越亮星/极光越淡；Terraria `255-skyR-25≤0 整片不画`的软版）
var _sky_gate: float = 0.0
var _redraw_acc: float = 99.0
## 极光专用 ADD 混合子层（混合模式是节点级材质，星/月/太阳仍走默认 mix）
var _aurora: Node2D = null
## 游戏内天数（夜→昼跳变检测递增；Terraria Main.cs:20207 每晚 moonPhase++ 同构）
var _day_count: int = 0
var _last_hour: float = 12.0


func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260905
	# Terraria Star.SpawnStars 同构：200~400 颗；尺寸 0.42~0.78；1/40 大星
	# （尺寸×2、闪烁/自转速度减半）；twinkle 初值 0.6~1.0、速率 0.003~0.011/帧
	for i in 380:
		var big: bool = rng.randf() < 0.025
		var slow: float = 0.5 if big else 1.0
		_stars.append({
			"x": rng.randf_range(-STAR_SPAN_X * 0.5, STAR_SPAN_X * 0.5),
			"y": rng.randf_range(STAR_TOP, STAR_BOTTOM),
			"r": rng.randf_range(1.0, 2.0) * (2.0 if big else 1.0),
			"tw": rng.randf_range(0.6, 1.0),
			"tw_v": rng.randf_range(0.18, 0.66) * slow * (1.0 if rng.randf() < 0.5 else -1.0),
			"big": big,
			"rot": rng.randf_range(0.0, TAU),
			"rot_v": (rng.randf_range(0.05, 0.5) if big else 0.0)
					* (1.0 if rng.randf() < 0.5 else -1.0),
		})
	_aurora = Node2D.new()
	_aurora.name = "Aurora"
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_aurora.material = mat
	_aurora.draw.connect(_on_aurora_draw)
	add_child(_aurora)


func _process(delta: float) -> void:
	_time += delta
	_night = lerpf(_night, 1.0 - _day_factor(), clampf(delta * 2.0, 0.0, 1.0))
	_sky_gate = clampf((0.55 - EnvironmentAPI.sample_sky_bg_color(_env_time()).get_luminance()) * 4.0, 0.0, 1.0)
	_advance_day_count()
	_update_shooting_star(delta)
	for s in _stars:
		# 反弹式 twinkle：触界折返（Star.cs UpdateStar 同构）
		s["tw"] += s["tw_v"] * delta
		if s["tw"] > 1.0:
			s["tw"] = 1.0
			s["tw_v"] = -absf(s["tw_v"])
		elif s["tw"] < 0.6:
			s["tw"] = 0.6
			s["tw_v"] = absf(s["tw_v"])
		if s["big"]:
			s["rot"] += s["rot_v"] * delta
	# 日月/星野/极光全程有内容（白昼太阳也在走），恒节流重绘
	_redraw_acc += delta
	if _redraw_acc >= 1.0 / REDRAW_HZ:
		_redraw_acc = 0.0
		queue_redraw()
		if _aurora != null:
			_aurora.queue_redraw()


## 天数推进：hour 从深夜（>21）跳回清晨（<8）= 新的一天（每夜月相 +1 的计数基础）
func _advance_day_count() -> void:
	var hour: float = _env_time()
	if _last_hour > 21.0 and hour < 8.0:
		_day_count += 1
	_last_hour = hour


func _draw() -> void:
	var center_x: float = _window_center_x()
	var hour: float = _env_time()
	var cm: Color = _current_cm()
	_draw_moon_path(center_x, hour, cm)
	if _night > 0.01:
		_draw_starfield(cm)
		_draw_shooting_star(cm)
	_draw_sun(center_x, hour, cm)


# ─────────────────────────────── 星野 ────────────────────────────────

## 星野：Terraria DrawStar 同构——大小与透明度同由 twinkle 驱动，灰白冷色
func _draw_starfield(cm: Color) -> void:
	var gate: float = _night * _sky_gate
	if gate <= 0.01:
		return
	for s in _stars:
		var tw: float = s["tw"]
		var a: float = gate * 0.9 * tw
		var col := EnvironmentAPI.unmodulate(Color(0.92, 0.94, 1.0, a), cm)
		var p := Vector2(s["x"], s["y"])
		var r: float = s["r"] * (0.6 + 0.4 * tw)
		draw_circle(p, r, col)
		# 大星四芒 sparkle 随自转（Terraria Star 贴图星芒的程序绘制同构）
		if s["big"] and a > 0.35:
			var l: float = r * 6.0 * (a - 0.2)
			var dir := Vector2(cos(s["rot"]), sin(s["rot"]))
			var perp := Vector2(-dir.y, dir.x)
			var spark := EnvironmentAPI.unmodulate(Color(0.92, 0.94, 1.0, a * 0.5), cm)
			draw_line(p - dir * l, p + dir * l, spark, 1.0)
			draw_line(p - perp * l, p + perp * l, spark, 1.0)


## 流星（Terraria Star.falling 同构）：夜间随机一颗划过，尾迹渐隐
func _update_shooting_star(delta: float) -> void:
	if _night * _sky_gate < 0.5:
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


func _draw_shooting_star(cm: Color) -> void:
	if _shoot.is_empty():
		return
	var head := Vector2(_shoot["x"], _shoot["y"])
	var tail: Vector2 = head - Vector2(_shoot["vx"], _shoot["vy"]) * 0.22
	var a: float = clampf(float(_shoot["life"]) / 0.9, 0.0, 1.0) * _night
	# 三段尾迹渐隐
	var mid: Vector2 = head.lerp(tail, 0.5)
	draw_line(head, mid, EnvironmentAPI.unmodulate(Color(1, 1, 1, a * 0.95), cm), 2.0)
	draw_line(mid, tail, EnvironmentAPI.unmodulate(Color(0.85, 0.9, 1.0, a * 0.45), cm), 1.5)
	draw_line(tail, tail.lerp(head, -0.35), EnvironmentAPI.unmodulate(Color(0.8, 0.85, 1.0, a * 0.2), cm), 1.0)
	draw_circle(head, 1.8, EnvironmentAPI.unmodulate(Color(1, 1, 1, a), cm))


# ─────────────────────────────── 极光 ────────────────────────────────

## 极光（AuroraSky.cs 同构）：色相随游戏时间轮转 + 带内 cos 微调制，竖条帷幕
## 沿正弦起伏、列强度沿走向起伏；亮度沿带向上渐亮（lum 0.5→1.0 的两段近似）。
## 画在 ADD 混合子层上——黑天上呈自发光。**横跨全图**（非窗口）。
func _on_aurora_draw() -> void:
	var gate: float = _night * _sky_gate
	if _aurora == null or gate <= 0.01:
		return
	var cm: Color = _current_cm()
	var base_a: float = AURORA_ALPHA * gate
	var drift: float = sin(_time * 0.05) * 90.0
	var x_left: float = -STAR_SPAN_X * 0.5 + drift
	for rb in AURORA_RIBBONS:
		var y0: float = rb[0]
		var amp: float = rb[1]
		var freq: float = rb[2]
		var hue_off: float = rb[3]
		var x: float = x_left
		while x < STAR_SPAN_X * 0.5 + drift:
			var h: float = amp * (0.6 + 0.4 * sin(x * freq + _time * 0.35)) \
					+ amp * 0.35 * sin(x * freq * 2.7 - _time * 0.6)
			if h > 8.0:
				var t: float = (x - x_left) / STAR_SPAN_X  # 带内参数 0..1
				# 带内色相微调制限幅 ±0.04：可见窗内不再扫过红/黄色区
				var hue: float = fmod(_time * AURORA_HUE_SPEED + hue_off
						+ cos(t * TAU * 2.5) * 0.04, 1.0)
				var core := Color.from_hsv(hue, 0.95, 0.85)
				# 列强度沿帷幕走向起伏（涟漪感）
				var band: float = 0.55 + 0.45 * sin(x * freq * 0.5 + _time * 0.22 + y0)
				var mid_y: float = y0 - h * 0.45
				_aurora.draw_rect(Rect2(x, mid_y, AURORA_STEP * 0.9, h * 0.45),
						EnvironmentAPI.unmodulate(Color(core.r, core.g, core.b, base_a * band), cm))
				_aurora.draw_rect(Rect2(x, y0 - h, AURORA_STEP * 0.9, h * 0.55),
						EnvironmentAPI.unmodulate(Color(core.r * 0.8, core.g, core.b, base_a * band * 0.35), cm))
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


## 太阳：暖金圆盘 + 双层光晕，晨昏放大贴地（白昼可见，夜间淡出）。
## 淡出跟天空底色亮度而非 CanvasModulate——黄昏 19:00 粉峰时 CM 亮度已跌到
## ~0.55（day_t≈0.014），按 day_t 淡出太阳会提前消失，与"日落粉峰+橙红太阳
## 贴地平线"的画面不同步；天空底色此时仍亮（粉 lum≈0.58），20:30 前后才暗灭。
func _draw_sun(center_x: float, hour: float, cm: Color) -> void:
	var t: float = _traverse(hour, SUN_HOUR_START, SUN_HOUR_END)
	if t < 0.0:
		return
	var a: float = clampf((EnvironmentAPI.sample_sky_bg_color(hour).get_luminance() - 0.25) / 0.30, 0.0, 1.0)
	if a <= 0.01:
		return
	var c: Dictionary = _celestial_pos(t, center_x)
	var p: Vector2 = c["pos"]
	var s: float = c["scale"]
	var r: float = 34.0 * s
	# 晨昏偏橙（SetBackColor 午后→日落暖红 ramp 的简化连续版）
	var warm: float = clampf(c["p"] * 1.4, 0.0, 1.0)
	var disc := Color(1.0, 0.92 - 0.18 * warm, 0.62 - 0.12 * warm, a)
	draw_circle(p, r * 2.1, EnvironmentAPI.unmodulate(Color(1.0, 0.85, 0.5, 0.06 * a), cm))
	draw_circle(p, r * 1.45, EnvironmentAPI.unmodulate(Color(1.0, 0.88, 0.55, 0.14 * a), cm))
	draw_circle(p, r, EnvironmentAPI.unmodulate(disc, cm))


## 月亮：纯白圆盘 + 冷色光晕 + 环形山 + **月相**（8 相随天数，Terraria 每晚
## moonPhase++ 同构；普通夜月面纯白为 SetBackColor 尾部强制）。
## 月相阴影圆颜色 = 当前天空底色（unmod 后屏显清屏色原值，新月不露馅）。
func _draw_moon_path(center_x: float, hour: float, cm: Color) -> void:
	var gate: float = _night * _sky_gate
	if gate <= 0.01:
		return
	var t: float = _traverse(hour, 19.0, 29.0)
	if t < 0.0:
		return
	var c: Dictionary = _celestial_pos(t, center_x)
	var p: Vector2 = c["pos"]
	var s: float = c["scale"]
	var r: float = 26.0 * s
	draw_circle(p, r * 2.2, EnvironmentAPI.unmodulate(Color(0.80, 0.85, 1.0, 0.05 * gate), cm))
	draw_circle(p, r * 1.5, EnvironmentAPI.unmodulate(Color(0.85, 0.90, 1.0, 0.10 * gate), cm))
	draw_circle(p, r, EnvironmentAPI.unmodulate(Color(1.0, 1.0, 1.0, 0.95 * gate), cm))
	var crater := EnvironmentAPI.unmodulate(Color(0.86, 0.86, 0.84, 0.35 * gate), cm)
	draw_circle(p + Vector2(-8, -5) * s, 5.5 * s, crater)
	draw_circle(p + Vector2(7, 6) * s, 4.0 * s, crater)
	draw_circle(p + Vector2(9, -9) * s, 2.6 * s, crater)
	# 月相：phase 0..7（0=满月 4=新月），阴影圆横向偏移扫过月面；
	# off = 1.5r×(1-p/4)：p0=+1.5r(全露/满) → p4=0(全遮/新) → p7=-1.125r(反向娥眉)
	var phase: int = _day_count % 8
	var shadow_r: float = r * 1.04
	var off: float = (1.0 - float(phase) / 4.0) * shadow_r * 1.5
	draw_circle(p + Vector2(off, 0.0), shadow_r,
			EnvironmentAPI.unmodulate(EnvironmentAPI.sample_sky_bg_color(hour), cm))


# ─────────────────────────────── 工具 ────────────────────────────────

## 可见窗口的本地中心：由自身被视差驱动的 position 反推（factor<1 时
## position.x = cam_x*(1-factor) → cam_x = pos.x/(1-factor) → 窗口中心 = cam_x*factor）
func _window_center_x() -> float:
	return position.x * FACTOR / (1.0 - FACTOR)


## 当前 CanvasModulate 色（补偿除法用；env 缺失按白 = 不补偿）
func _current_cm() -> Color:
	if _env == null or not is_instance_valid(_env):
		_env = _find_env()
	if _env != null and _env.has_method("get_current_light_color"):
		return _env.get_current_light_color()
	return Color.WHITE


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
