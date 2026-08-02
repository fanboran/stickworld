class_name ClockWidget
extends Control
## 圆形时钟 widget -- 24 小时制表盘，单指针，彩色时间段。
##
## 0:00 在正上方，顺时针旋转一圈为 24 小时。
## 表盘由不同颜色的弧段表示：夜晚 / 黎明 / 白天 / 黄昏。
## 黎明和黄昏为窄条，白天和夜晚为宽条。

# ─────────────────────────────── 绘制参数 ────────────────────────────────

const CLOCK_RADIUS: float = 30.0
const ARC_WIDTH: float = 7.0
const HAND_LENGTH: float = 23.0
const HAND_WIDTH: float = 2.5

const BG_COLOR: Color = Color(0.08, 0.08, 0.12, 0.85)
const HAND_COLOR: Color = Color(1.0, 1.0, 0.92)
const CENTER_COLOR: Color = Color(1.0, 1.0, 0.92)

## 时间段：[起始小时, 结束小时, 颜色]
const TIME_SEGMENTS: Array = [
	[0.0,  5.0,  Color(0.15, 0.20, 0.35)],  # 深夜
	[5.0,  7.0,  Color(0.60, 0.40, 0.55)],  # 黎明（窄条）
	[7.0,  19.0, Color(0.95, 0.85, 0.45)],  # 白天
	[19.0, 21.0, Color(0.85, 0.45, 0.25)],  # 黄昏（窄条）
	[21.0, 24.0, Color(0.15, 0.20, 0.35)],  # 深夜
]


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	custom_minimum_size = Vector2(CLOCK_RADIUS * 2.0 + 8.0, CLOCK_RADIUS * 2.0 + 8.0)


func _process(_delta: float) -> void:
	queue_redraw()


# ─────────────────────────────── 绘制 ────────────────────────────────

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


## 将小时（0~24）转换为弧度。
## 0:00 在正上方（-PI/2），顺时针增加。
static func _hour_to_angle(hour: float) -> float:
	return (hour / 24.0) * TAU - PI / 2.0
