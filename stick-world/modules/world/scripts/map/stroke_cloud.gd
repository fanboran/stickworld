class_name StrokeCloud
extends Node2D
## 实时笔触云 —— mona-3 油画算法的运行时移植（无贴图、无边界）。
##
## 每朵云 = 等粗细软边笔触群（约 50 笔）：旧笔触持续淡化死亡，新笔触从云的
## 形状包络持续重生（风向侧偏置——云在"被吹散又补充"地流动重组）。
## 形状由运行时种子生成（中心厚两端薄的抛物线包络），完全不依赖预生成资产，
## 因此不存在"绘制范围框死"问题——画布无限，笔触是过程量。
## 明暗继承天空光照色（夜里自动变暗），由 sky_decor 调 set_sky_light 注入。

## 笔触数（密度恒定：死一笔补一笔）
const BRUSH_COUNT: int = 64
## 笔刷尺寸（横椭圆；云内等粗细——体积靠数量堆不靠大小变）
const BRUSH_W: float = 26.0
const BRUSH_H: float = 11.0
## 重绘节流（笔触生灭的呼吸感在 20Hz 下足够顺）
const REDRAW_HZ: float = 20.0
## 单笔生命期（秒；离散大 → 换血节奏明显但不闪）
const STROKE_LIFE_MIN: float = 5.0
const STROKE_LIFE_MAX: float = 11.0

## 软边笔刷纹理（程序生成一次，类级缓存）
static var _brush_tex: ImageTexture = null

## 云形包络（世界半宽；sky_decor 按 scale 缩放整朵）
var cloud_width: float = 380.0
## 天空光照（云色继承）
var _sky_light: Color = Color.WHITE
## 云级 alpha（软生灭由 sky_decor 驱动）
var _cloud_alpha: float = 1.0
## 风向（重生偏置用；>0 向右吹）
var _wind_dir: float = 1.0

var _strokes: Array = []
var _rng := RandomNumberGenerator.new()
var _t: float = 0.0
var _redraw_acc: float = 99.0


func _ready() -> void:
	_rng.seed = randi()
	for i in BRUSH_COUNT:
		_strokes.append(_new_stroke(true))


## 每帧驱动（风 px/s 由外部运动学算好传入；内部只管笔触生灭与微漂）
func update_cloud(delta: float, wind_dir: float) -> void:
	_t += delta
	_wind_dir = wind_dir
	for s in _strokes:
		s["life"] -= delta
		# 笔触微漂（沿风向缓移——整朵云的位移由外部 node 移动，此处是内部絮流）
		s["x"] += _wind_dir * 6.0 * delta
		s["y"] += sin(_t * 0.7 + s["flut"]) * 1.2 * delta
		if float(s["life"]) <= 0.0:
			_replace_stroke(s)
	_redraw_acc += delta
	if _redraw_acc >= 1.0 / REDRAW_HZ:
		_redraw_acc = 0.0
		queue_redraw()


## 注入天空光照（夜里变暗/黄昏染暖——云色=光照色×笔触明暗）
func set_sky_light(light: Color) -> void:
	_sky_light = light


## 云级透明度（软生灭：出带渐隐由 sky_decor 调用）
func set_cloud_alpha(a: float) -> void:
	_cloud_alpha = a


func _draw() -> void:
	var tex := _get_brush()
	var half := Vector2(BRUSH_W, BRUSH_H) * 0.5
	for s in _strokes:
		var t: float = 1.0 - float(s["life"]) / float(s["max"])  # 0 出生 → 1 死亡
		# 生命包络：快速显形 → 长存活 → 尾段淡化
		var env: float = smoothstep(0.0, 0.18, t) * (1.0 - smoothstep(0.60, 1.0, t))
		if env <= 0.01:
			continue
		# 明暗：按笔触 y（低处灰蓝暗、上部亮白——体积感）
		var shade: float = float(s["shade"])
		var col := Color(_sky_light.r * (1.0 - 0.18 * shade),
				_sky_light.g * (1.0 - 0.13 * shade),
				_sky_light.b * (1.0 - 0.02 * shade),
				env * _cloud_alpha * 0.95)
		draw_texture(tex, Vector2(s["x"], s["y"]) - half, col)


## 新笔触：从云形包络采样（风向侧 30% 偏置——重组有方向感）
func _new_stroke(initial: bool) -> Dictionary:
	# 抛物线包络：|x| 越大云越薄
	var u: float = _rng.randf_range(-1.0, 1.0)
	if not initial and _rng.randf() < 0.3:
		u = -_wind_dir * _rng.randf_range(0.55, 1.0)  # 风上游侧偏置
	var x: float = u * cloud_width * 0.5
	var thick: float = 1.0 - u * u  # 中央 1 → 两端 0
	var y: float = _rng.randf_range(-1.0, 1.0) * 26.0 * thick \
			+ (1.0 - thick) * 8.0
	var max_life: float = _rng.randf_range(STROKE_LIFE_MIN, STROKE_LIFE_MAX)
	return {
		"x": x,
		"y": y,
		"life": _rng.randf_range(0.5, 1.0) * max_life if initial else max_life,
		"max": max_life,
		"shade": clampf((y + 34.0) / 68.0, 0.0, 1.0),
		"flut": _rng.randf() * TAU,
	}


## 笔触死亡 → 原位换新（密度恒定）
func _replace_stroke(s: Dictionary) -> void:
	var fresh := _new_stroke(false)
	s["x"] = fresh["x"]
	s["y"] = fresh["y"]
	s["life"] = fresh["max"]
	s["max"] = fresh["max"]
	s["shade"] = fresh["shade"]
	s["flut"] = fresh["flut"]


## 软边横椭圆笔刷（径向 alpha 衰减），类级缓存一次生成
static func _get_brush() -> ImageTexture:
	if _brush_tex != null:
		return _brush_tex
	var w: int = int(BRUSH_W)
	var h: int = int(BRUSH_H)
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var cx: float = w * 0.5 - 0.5
	var cy: float = h * 0.5 - 0.5
	for yy in h:
		for xx in w:
			var dx: float = (xx - cx) / cx
			var dy: float = (yy - cy) / cy
			var d: float = sqrt(dx * dx + dy * dy)
			var a: float = clampf(1.0 - d, 0.0, 1.0)
			a = a * a * (3.0 - 2.0 * a)  # smoothstep 软边
			img.set_pixel(xx, yy, Color(1, 1, 1, a))
	_brush_tex = ImageTexture.create_from_image(img)
	return _brush_tex
