extends Node
class_name MapCamera
## 世界地图摄像机 —— 处理2D地图的拖拽平移和滚轮缩放

## 目标节点（通常是 MapRenderer 所在的节点）
@export var target: Node2D

## 最小缩放比例
@export var min_zoom: float = 0.3

## 最大缩放比例
@export var max_zoom: float = 3.0

## 每次滚轮的缩放步长
@export var zoom_step: float = 0.1

## 缩放速度因子
@export var zoom_speed: float = 1.0

## 是否启用拖拽
@export var drag_enabled: bool = true

## 是否启用缩放
@export var zoom_enabled: bool = true

## 当前偏移（地图平移量）
var _offset: Vector2 = Vector2.ZERO

## 当前缩放级别（1.0 = 原始大小）
var _zoom_level: float = 1.0

## 拖拽状态
var _is_dragging: bool = false
var _drag_start: Vector2 = Vector2.ZERO
var _drag_offset_start: Vector2 = Vector2.ZERO

## 边界限制（地图四角在原始坐标系中的坐标）
var _bounds: Rect2


func _ready():
	if target == null:
		# 尝试在父节点中找第一个 Controls/Node2D 子节点
		var parent := get_parent()
		if parent:
			for child in parent.get_children():
				if child is Node2D:
					target = child
					break

func _process(_delta: float):
	if target == null:
		return
	_apply_transform()

func _input(event: InputEvent):
	if not drag_enabled and not zoom_enabled:
		return

	if zoom_enabled and event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at_point(mb.position, zoom_step * zoom_speed)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at_point(mb.position, -zoom_step * zoom_speed)

	if drag_enabled and event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			if mb.pressed:
				_is_dragging = true
				_drag_start = mb.position
				_drag_offset_start = _offset
			else:
				_is_dragging = false

	if drag_enabled and event is InputEventMouseMotion and _is_dragging:
		var mm: InputEventMouseMotion = event
		_offset = _drag_offset_start + (mm.position - _drag_start)

## 在以某点为锚点时缩放
func _zoom_at_point(screen_pos: Vector2, delta_zoom: float):
	var old_zoom: float = _zoom_level
	_zoom_level = clamp(_zoom_level + delta_zoom, min_zoom, max_zoom)

	if _zoom_level == old_zoom:
		return

	# 保持缩放锚点：鼠标指向的位置不动
	var ratio: float = _zoom_level / old_zoom
	_offset = screen_pos + ratio * (_offset - screen_pos)

## 应用变换到目标节点
func _apply_transform():
	if target == null:
		return
	target.position = _offset
	target.scale = Vector2(_zoom_level, _zoom_level)

## 移动镜头到指定坐标
func move_to(position: Vector2, animated: bool = false):
	if animated:
		# 简单线性插值（如果需要更流畅的动画可改用Tween）
		_offset = position
	else:
		_offset = position

## 设置缩放
func set_zoom(zoom: float):
	_zoom_level = clamp(zoom, min_zoom, max_zoom)

## 获取当前缩放
func get_zoom() -> float:
	return _zoom_level

## 屏幕坐标转地图坐标
func screen_to_map(screen_pos: Vector2) -> Vector2:
	if target == null:
		return screen_pos
	return (screen_pos - _offset) / _zoom_level

## 地图坐标转屏幕坐标
func map_to_screen(map_pos: Vector2) -> Vector2:
	if target == null:
		return map_pos
	return map_pos * _zoom_level + _offset
