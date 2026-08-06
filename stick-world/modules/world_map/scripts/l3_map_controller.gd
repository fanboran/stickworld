extends Node2D
class_name L3MapController
## L3 大世界战略图控制器（M 键）—— 与 L1（Tab）独立
##
## 交互：
##   - M 键打开/关闭（由 SystemSetup 接线）
##   - ESC 关闭
##   - 拖拽/滚轮缩放（MapCamera）
##   - hover 高亮地区（渲染器处理）

@export var map_renderer: L3MapRenderer
@export var map_camera: MapCamera


func _ready() -> void:
	_auto_find_components()
	# 渲染器悬停检测需要相机做屏幕->地图坐标换算
	if map_renderer != null and map_renderer.has_method("set_camera"):
		map_renderer.set_camera(map_camera)


func _auto_find_components() -> void:
	for child in get_children():
		if child is L3MapRenderer and map_renderer == null:
			map_renderer = child
		elif child is MapCamera and map_camera == null:
			map_camera = child


func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if event is InputEventKey and event.pressed:
		var key: InputEventKey = event as InputEventKey
		if key.keycode == KEY_ESCAPE:
			close()
			get_viewport().set_input_as_handled()


## 打开 L3 地图（M 键触发）
func open() -> void:
	visible = true
	# 初始视角：整图适配屏幕
	if map_camera != null and map_camera.has_method("set_zoom"):
		var vp := get_viewport()
		if vp != null:
			var vp_size: Vector2 = vp.get_visible_rect().size
			var target_h: float = vp_size.y * 0.72
			var fit_zoom: float = target_h / 2048.0
			map_camera.set_zoom(fit_zoom)
			if map_camera.has_method("set_offset"):
				map_camera.set_offset(vp_size * 0.5 - Vector2(2048.0 * fit_zoom * 0.5, 2048.0 * fit_zoom * 0.5))


## 关闭 L3 地图（ESC）
func close() -> void:
	visible = false
	# 通知 system_setup 恢复场景图输入
	if EventBus != null:
		EventBus.emit_signal("strategic_map_closed")
