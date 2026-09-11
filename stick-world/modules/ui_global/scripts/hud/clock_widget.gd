class_name ClockWidget
extends Control
## 圆形时钟 widget -- 24 小时制表盘，单指针，彩色时间段。
##
## 0:00 在正上方，顺时针旋转一圈为 24 小时。
## 表盘由不同颜色的弧段表示：夜晚 / 黎明 / 白天 / 黄昏。
## 黎明和黄昏为窄条，白天和夜晚为宽条。
##
## 下半圆为 P 社式速度弧：四段 = ‖/1x/2x/4x（左→右），当前档琥珀高亮，
## 点击弧段直接调速——时间显示与时间控制收拢在同一块，不占独立按钮组。

# ─────────────────────────────────── 绘制参数 ────────────────────────────────

const CLOCK_RADIUS: float = 30.0
const ARC_WIDTH: float = 7.0
const HAND_LENGTH: float = 23.0
const HAND_WIDTH: float = 2.5

const BG_COLOR: Color = Color(0.08, 0.08, 0.12, 0.85)
const HAND_COLOR: Color = Color(1.0, 1.0, 0.92)
const CENTER_COLOR: Color = Color(1.0, 1.0, 0.92)

## 速度弧参数（P 社游戏同款：表盘外圈的下半圆弧段）
const SPEED_ARC_WIDTH: float = 6.0
const SPEED_ARC_GAP: float = 0.07
const SPEED_ARC_STEP_OUT: float = 7.0   # 弧半径 = CLOCK_RADIUS + 此值
const SPEED_LABEL_STEP_OUT: float = 18.0
const SPEED_LABELS: Array = ["‖", "1x", "2x", "4x"]

## 时间段：[起始小时, 结束小时, 颜色]
const TIME_SEGMENTS: Array = [
	[0.0,  5.0,  Color(0.15, 0.20, 0.35)],  # 深夜
	[5.0,  7.0,  Color(0.60, 0.40, 0.55)],  # 黎明（窄条）
	[7.0,  19.0, Color(0.95, 0.85, 0.45)],  # 白天
	[19.0, 21.0, Color(0.85, 0.45, 0.25)],  # 黄昏（窄条）
	[21.0, 24.0, Color(0.15, 0.20, 0.35)],  # 深夜
]

## 关闭速度弧（纯展示时钟的场合用）
@export var speed_arc := true


# ─────────────────────────────────── 生命周期 ────────────────────────────────

var _last_display_time: float = -1.0
var _last_speed: int = -1
var _hover_speed: int = -1


func _ready() -> void:
	var half: float = CLOCK_RADIUS + (SPEED_LABEL_STEP_OUT + 6.0 if speed_arc else 4.0)
	custom_minimum_size = Vector2(half * 2.0, half * 2.0)
	mouse_filter = Control.MOUSE_FILTER_STOP if speed_arc else Control.MOUSE_FILTER_IGNORE


func _process(_delta: float) -> void:
	var t: float = WorldState.game_time if WorldState else 0.0
	# 分钟刻度变化（≈0.1h）才重绘，避免每帧 queue_redraw
	var coarse: float = snappedf(t, 0.1)
	if not is_equal_approx(coarse, _last_display_time):
		_last_display_time = coarse
		queue_redraw()
	# 速度档变化也触发重绘（弧段高亮）
	var spd: int = TimeManager.current_speed if TimeManager else -1
	if spd != _last_speed:
		_last_speed = spd
		queue_redraw()


# ─────────────────────────────────── 绘制 ────────────────────────────────

func _draw() -> void:
	var center: Vector2 = size / 2.0
	var time: float = 0.0
	if WorldState:
		time = WorldState.game_time

	# 背景圆
	draw_circle(center, CLOCK_RADIUS + 2.0, BG_COLOR)

	# 时间段弧
	for seg in TIME_SEGMENTS:
		var start_angle: float = _hour_to_angle(seg[0])
		var end_angle: float = _hour_to_angle(seg[1])
		draw_arc(center, CLOCK_RADIUS, start_angle, end_angle, 48, seg[2], ARC_WIDTH, true)

	# 指针
	var hand_angle: float = _hour_to_angle(time)
	var hand_end: Vector2 = center + Vector2(cos(hand_angle), sin(hand_angle)) * HAND_LENGTH
	draw_line(center, hand_end, HAND_COLOR, HAND_WIDTH, true)

	# 中心圆点
	draw_circle(center, 3.0, CENTER_COLOR)

	if speed_arc:
		_draw_speed_arc(center)


## 速度弧：下半圆四段（左→右 = ‖/1x/2x/4x，索引对齐 TimeManager.Speed）
func _draw_speed_arc(center: Vector2) -> void:
	var n := SPEED_LABELS.size()
	var arc_r: float = CLOCK_RADIUS + SPEED_ARC_STEP_OUT
	for i in n:
		# 画布角度：下半圆 = 0..PI；段 i 从 PI-i*step 到 PI-(i+1)*step（左→右）
		var step: float = PI / n
		var a0: float = PI - (i + 1) * step + SPEED_ARC_GAP * 0.5
		var a1: float = PI - i * step - SPEED_ARC_GAP * 0.5
		var col := Color(1, 1, 1, 0.20)
		if TimeManager and i == TimeManager.current_speed:
			col = Color(1.0, 0.55, 0.35) if TimeManager.is_paused() else StickTokens.ACCENT
		elif i == _hover_speed:
			col = Color(1, 1, 1, 0.55)
		draw_arc(center, arc_r, a0, a1, 12, col, SPEED_ARC_WIDTH, true)
		# 段位小标签（弧外圈）
		var am: float = PI - (i + 0.5) * step
		var lp: Vector2 = center + Vector2(cos(am), sin(am)) * (arc_r + SPEED_LABEL_STEP_OUT - SPEED_ARC_STEP_OUT)
		var label_col := Color(1, 1, 1, 0.85) if (TimeManager and i == TimeManager.current_speed) else Color(1, 1, 1, 0.45)
		var font := get_theme_default_font()
		var fs := font.get_string_size(SPEED_LABELS[i], HORIZONTAL_ALIGNMENT_CENTER, -1, 9)
		draw_string(font, lp - fs * 0.5 + Vector2(0, fs.y * 0.5), SPEED_LABELS[i],
				HORIZONTAL_ALIGNMENT_CENTER, -1, 9, label_col)


# ─────────────────────────────────── 交互（点击/悬停弧段调速）────────────────────────────

func _gui_input(event: InputEvent) -> void:
	if not speed_arc or TimeManager == null:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var idx := _speed_at(event.position)
		if idx >= 0:
			TimeManager.set_speed(idx)
			accept_event()
	elif event is InputEventMouseMotion:
		var idx := _speed_at(event.position)
		if idx != _hover_speed:
			_hover_speed = idx
			queue_redraw()


## 命中检测：返回点击位置对应的速度档（下半圆弧带内），无效 -1
func _speed_at(p: Vector2) -> int:
	var v: Vector2 = p - size / 2.0
	var ang: float = atan2(v.y, v.x)
	if ang < 0.0 or ang > PI:
		return -1
	var r: float = v.length()
	if r < CLOCK_RADIUS - 2.0 or r > CLOCK_RADIUS + SPEED_ARC_STEP_OUT + 6.0:
		return -1
	return clampi(int((PI - ang) / (PI / SPEED_LABELS.size())), 0, SPEED_LABELS.size() - 1)


## 将小时（0~24）转换为弧度。
## 0:00 在正上方（-PI/2），顺时针增加。
static func _hour_to_angle(hour: float) -> float:
	return (hour / 24.0) * TAU - PI / 2.0
