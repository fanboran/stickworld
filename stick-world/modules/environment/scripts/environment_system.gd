class_name EnvironmentSystem
extends Node
## 环境系统 —— 跨场景保持的环境效果。
##
## P0 阶段实现：
##   - 时间推进（接 WorldState.game_time）
##   - 时间映射到 CanvasModulate.color（按关键帧插值）
##
## 后续阶段扩展：天空、天气、地面震动、生物群落。
## 详见 docs/技术/架构/场景与战斗架构.md §十一。

const EnvironmentAPI := preload("res://modules/environment/api.gd")

# ─────────────────────────────── Inspector 参数 ────────────────────────────────
## 时间推进速度（现实秒 : 游戏小时）。默认 60 秒 = 24 小时。
@export var seconds_per_day: float = 60.0

## 当前时间（0.0 ~ 24.0）
@export var time_of_day: float = 8.0:
	set(v):
		time_of_day = fposmod(v, 24.0)

# ─────────────────────────────── 内部状态 ────────────────────────────────
var _canvas_modulate: CanvasModulate = null


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	_ensure_canvas_modulate()
	# 同步给 WorldState
	if WorldState:
		WorldState.game_time = time_of_day


func _process(delta: float) -> void:
	if TimeManager and not TimeManager.is_paused():
		# 推进时间
		var hours_per_second: float = 24.0 / seconds_per_day
		time_of_day += hours_per_second * delta
		if WorldState:
			WorldState.game_time = time_of_day
	# 更新光照
	_update_lighting()


# ─────────────────────────────── 内部 ────────────────────────────────

func _ensure_canvas_modulate() -> void:
	_canvas_modulate = get_node_or_null("CanvasModulate") as CanvasModulate
	if _canvas_modulate == null:
		_canvas_modulate = CanvasModulate.new()
		_canvas_modulate.name = "CanvasModulate"
		add_child(_canvas_modulate)


func _update_lighting() -> void:
	if _canvas_modulate == null:
		return
	_canvas_modulate.color = _sample_light_color(time_of_day)


## 按关键帧插值采样光照颜色
static func _sample_light_color(hour: float) -> Color:
	var frames: Array = EnvironmentAPI.LIGHT_KEYFRAMES
	# 找到 hour 落在哪两个关键帧之间
	for i in range(frames.size() - 1):
		var a: Dictionary = frames[i]
		var b: Dictionary = frames[i + 1]
		if hour >= a["hour"] and hour <= b["hour"]:
			var span: float = b["hour"] - a["hour"]
			if span <= 0.0:
				return a["color"]
			var t: float = (hour - a["hour"]) / span
			return a["color"].lerp(b["color"], t)
	# 兜底
	return frames[0]["color"]


# ─────────────────────────────── 公共 API ────────────────────────────────

## 设置一天的现实秒数
func set_seconds_per_day(seconds: float) -> void:
	seconds_per_day = maxf(1.0, seconds)


## 直接设置时间（0~24）
func set_time_of_day(hour: float) -> void:
	time_of_day = hour


## 获取当前时间
func get_time_of_day() -> float:
	return time_of_day


## 获取当前 CanvasModulate 颜色（供测试验证）
func get_current_light_color() -> Color:
	if _canvas_modulate == null:
		return Color.WHITE
	return _canvas_modulate.color
