extends Node2D
class_name WorldMapController
## 世界地图模块主控制器
##
## 将所有组件串联：相机控制 + 渲染器 + 数据 + 地图模式。
## 处理输入事件，将地块点击转发给 api.gd 的信号。

## 公共API引用（同一场景内）
@export var api: Node  # 指向 api.gd 所在节点

## 组件引用
@export var map_renderer: MapRenderer
@export var map_camera: MapCamera
@export var map_mode_manager: MapModeManager

## 世界数据
@export var world_data: WorldMapData

## 输入控制
@export var left_click_selects: bool = true
@export var right_click_info: bool = true


func _ready():
	# 自动查找组件（如果未手动指定）
	if api == null:
		api = _find_child_of_type("api")
	if map_renderer == null:
		_find_components()

	# 初始化 API
	if api and api.has_method("setup"):
		api.setup(map_renderer, map_camera, map_mode_manager, world_data)

func _find_child_of_type(node_name: String) -> Node:
	var parent := get_parent()
	if parent:
		for child in parent.get_children():
			if child.name.to_lower() == node_name.to_lower():
				return child
	return null

func _find_components():
	for child in get_parent().get_children() if get_parent() else []:
		if child is MapRenderer and map_renderer == null:
			map_renderer = child
		if child is MapCamera and map_camera == null:
			map_camera = child
		if child is MapModeManager and map_mode_manager == null:
			map_mode_manager = child


func _input(event: InputEvent):
	if not is_visible_in_tree():
		return

	if left_click_selects and event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_handle_left_click(mb.position)

		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_handle_right_click(mb.position)

	if event is InputEventKey and event.pressed:
		_handle_key(event as InputEventKey)

func _handle_left_click(screen_pos: Vector2):
	if map_renderer == null:
		return
	var rid: int = map_renderer.get_region_id_at_screen_position(screen_pos)
	if rid != -1:
		map_renderer.select_region(rid)
		if api and api.has_signal("region_clicked"):
			api.region_clicked.emit(rid)

func _handle_right_click(screen_pos: Vector2):
	if map_renderer == null:
		return
	var rid: int = map_renderer.get_region_id_at_screen_position(screen_pos)
	if rid != -1:
		if api and api.has_signal("region_right_clicked"):
			api.region_right_clicked.emit(rid)

func _handle_key(key_event: InputEventKey):
	# Tab 键切换地图模式
	if key_event.keycode == KEY_TAB:
		if map_mode_manager:
			map_mode_manager.cycle_mode()
	# ESC 取消选中
	if key_event.keycode == KEY_ESCAPE:
		if map_renderer:
			map_renderer.deselect_region()
	# Home 重置相机
	if key_event.keycode == KEY_HOME:
		if map_camera:
			map_camera.move_to(Vector2.ZERO, true)
			map_camera.set_zoom(1.0)
	# F1 切换调试标签
	if key_event.keycode == KEY_F1:
		if map_renderer:
			map_renderer.debug_show_labels = not map_renderer.debug_show_labels
