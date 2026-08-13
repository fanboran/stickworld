extends Node
class_name MapCamera
## 战略图相机 —— 三级粒度切换 + 拖拽/缩放
##
## 详见 docs/技术/架构/战略图架构.md §七 相机与缩放控制
##
## 关键设计：
##   - 滚轮缩放是连续的（当前粒度内视觉缩放，不触发粒度切换）
##   - 双击触发粒度切换（由 StrategicMapController 处理）
##   - 边界约束：视野不超出当前粒度的数据范围
##   - 与场景图相机隔离（不共享状态）

## 目标节点（MapRenderer 所在的 Node2D）
@export var target: Node2D

## 最小缩放（看全当前粒度）
@export var min_zoom: float = 0.02

## 最大缩放（看细节）
@export var max_zoom: float = 3.0

## 滚轮缩放步长
@export var zoom_step: float = 0.1

## 是否启用拖拽
@export var drag_enabled: bool = true

## 是否启用缩放
@export var zoom_enabled: bool = true

## 当前偏移（地图平移量）
var _offset: Vector2 = Vector2.ZERO

## 当前缩放级别
var _zoom_level: float = 1.0

## 拖拽状态
var _is_dragging: bool = false
var _drag_start: Vector2 = Vector2.ZERO
var _drag_offset_start: Vector2 = Vector2.ZERO

## 当前粒度的边界约束（世界坐标）
var _bounds: Rect2 = Rect2(-4096, -2048, 8192, 4096)

## 设置数据容器引用（L1 单层数据，用于聚焦/边界）
var _data: L1WorldData = null


func _ready() -> void:
	if target == null:
		var parent := get_parent()
		if parent:
			for child in parent.get_children():
				if child is Node2D:
					target = child
					break


func _process(_delta: float) -> void:
	if target == null:
		return
	_apply_transform()


func _input(event: InputEvent) -> void:
	var parent: Node = get_parent()
	if parent != null and parent is CanvasItem and not (parent as CanvasItem).is_visible_in_tree():
		return
	if not drag_enabled and not zoom_enabled:
		return

	# 滚轮缩放（连续，不触发粒度切换）
	if zoom_enabled and event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at_point(mb.position, zoom_step)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at_point(mb.position, -zoom_step)

	# 中键拖拽
	if drag_enabled and event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			if mb.pressed:
				_is_dragging = true
				_drag_start = mb.position
				_drag_offset_start = _offset
			else:
				_is_dragging = false

	if drag_enabled and event is InputEventMouseMotion and _is_dragging:
		var mm: InputEventMouseMotion = event as InputEventMouseMotion
		_offset = _drag_offset_start + (mm.position - _drag_start)


## 以某点为锚点时缩放（等比缩放：每步 ×(1±delta_zoom)，各缩放级别阶梯均匀）
func _zoom_at_point(screen_pos: Vector2, delta_zoom: float) -> void:
	var old_zoom: float = _zoom_level
	var factor: float = 1.0 + delta_zoom
	_zoom_level = clampf(_zoom_level * factor, min_zoom, max_zoom)
	if _zoom_level == old_zoom:
		return
	var ratio: float = _zoom_level / old_zoom
	_offset = screen_pos + ratio * (_offset - screen_pos)


## 应用变换到目标节点
func _apply_transform() -> void:
	if target == null:
		return
	target.position = _offset
	target.scale = Vector2(_zoom_level, _zoom_level)


## 聚焦到指定 ID 的中心
## id 为 "" 时重置到当前粒度的中心
func focus_on(id: String, animated: bool = true) -> void:
	# SM-1 阶段实现：
	# 1. 查询 id 对应的 world_bounds 中心
	# 2. 设置 _offset 使中心位于屏幕中央
	# 3. 调整 _zoom_level 使 world_bounds 完整可见
	if animated:
		# P1 用 Tween 实现动画
		pass
	if id.is_empty():
		_offset = Vector2.ZERO
		_zoom_level = 1.0


## 设置缩放
func set_zoom(zoom: float) -> void:
	_zoom_level = clampf(zoom, min_zoom, max_zoom)


## 设置偏移（地图在屏幕上的位置；offset 为地图原点对应屏幕坐标）
func set_offset(offset: Vector2) -> void:
	_offset = offset


## 获取当前偏移
func get_offset() -> Vector2:
	return _offset


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


## 设置当前粒度的边界约束（粒度切换时调用）
func set_bounds(bounds: Rect2) -> void:
	_bounds = bounds


## 设置数据容器引用（L1 单层数据，用于聚焦/边界）
func set_data(data: L1WorldData) -> void:
	_data = data
	if _data != null:
		var s := float(_data.size)
		set_bounds(Rect2(0, 0, s, s))
		_zoom_level = clampf(1.0, min_zoom, max_zoom)
		_offset = Vector2.ZERO
