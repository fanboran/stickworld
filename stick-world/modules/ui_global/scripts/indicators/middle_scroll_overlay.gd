extends Control
## 中键滚动图标 -- 红警风格圆圈+4方向箭头（游玩 UI）。
##
## 按住中键时在锚点位置显示，松开消失。
## 通过查询 CameraRig 状态决定显示，不处理输入。
##
## 依赖由 SystemSetup 装配时 setup() 注入，不自行查找。

const ICON_COLOR: Color = Color(1.0, 1.0, 1.0, 0.7)
const CIRCLE_RADIUS: float = 14.0
const ARROW_LEN: float = 10.0
const ARROW_GAP: float = 6.0

var _camera_rig: Node = null


func setup(camera_rig: Node) -> void:
	_camera_rig = camera_rig


func _ready() -> void:
	size = get_viewport_rect().size
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(_delta: float) -> void:
	size = get_viewport_rect().size
	queue_redraw()


func _draw() -> void:
	var camera: Camera2D = _camera_rig as Camera2D
	if camera == null or not camera.has_method("is_middle_scrolling"):
		return
	if not camera.is_middle_scrolling():
		return
	var anchor: Vector2 = camera.get_middle_anchor()
	# 圆圈
	draw_arc(anchor, CIRCLE_RADIUS, 0, TAU, 48, ICON_COLOR, 1.5, true)
	# 4 方向箭头
	_draw_arrow(anchor + Vector2(0, -CIRCLE_RADIUS - ARROW_GAP), Vector2(0, -1))  # 上
	_draw_arrow(anchor + Vector2(0, CIRCLE_RADIUS + ARROW_GAP), Vector2(0, 1))    # 下
	_draw_arrow(anchor + Vector2(-CIRCLE_RADIUS - ARROW_GAP, 0), Vector2(-1, 0))  # 左
	_draw_arrow(anchor + Vector2(CIRCLE_RADIUS + ARROW_GAP, 0), Vector2(1, 0))   # 右


func _draw_arrow(pos: Vector2, dir: Vector2) -> void:
	var tip: Vector2 = pos + dir * ARROW_LEN
	var perp: Vector2 = Vector2(-dir.y, dir.x) * 4.0
	draw_line(pos, tip, ICON_COLOR, 1.5)
	draw_line(tip, tip - dir * 4.0 + perp, ICON_COLOR, 1.5)
	draw_line(tip, tip - dir * 4.0 - perp, ICON_COLOR, 1.5)
