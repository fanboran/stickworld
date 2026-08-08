extends Node2D
class_name L3MapController
## L3 大世界战略图控制器（M 键）—— 与 L1（Tab）独立
##
## 交互：
##   - M 键打开/关闭（由 SystemSetup 接线）
##   - ESC 关闭
##   - 单击地区 -> 下钻 L2 详细地图（打开 L2 视图并隐藏自身）
##   - 拖拽/滚轮缩放（MapCamera）
##   - hover 高亮地区（渲染器处理）

## L2 下钻视图（由 SystemSetup 装配时注入）
@export var l2_view: L2MapController = null

@export var map_renderer: L3MapRenderer
@export var map_camera: MapCamera


func _ready() -> void:
	_auto_find_components()
	# 渲染器悬停检测需要相机做屏幕->地图坐标换算
	if map_renderer != null and map_renderer.has_method("set_camera"):
		map_renderer.set_camera(map_camera)


## 注入 L2 下钻视图（由 SystemSetup 装配时调用，晚于 _ready）
func set_l2_view(view: L2MapController) -> void:
	l2_view = view
	if l2_view != null and not l2_view.back_requested.is_connected(_on_l2_back):
		l2_view.back_requested.connect(_on_l2_back)


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
		return
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		if _try_open_l2_at_screen(event.position):
			get_viewport().set_input_as_handled()


## 单击：屏幕坐标 -> 地图坐标 -> 命中地区 -> 下钻 L2
func _try_open_l2_at_screen(screen_pos: Vector2) -> bool:
	if map_camera == null or not map_camera.has_method("screen_to_map") \
			or map_renderer == null or map_renderer.get_data() == null:
		return false
	var map_pos: Vector2 = map_camera.screen_to_map(screen_pos)
	var data: L3WorldData = map_renderer.get_data()
	# 渲染坐标（8192 级网格）-> 索引图坐标（2048 级查询）
	if data.mask_image != null and data.size > 0:
		map_pos *= float(data.mask_image.get_width()) / float(data.size)
	var query: Dictionary = data.query_at_map_pos(map_pos)
	var region: Dictionary = query.get("region", {})
	var label: int = int(region.get("label", 0))
	if label <= 0:
		return false
	_open_l2(label)
	return true


## 下钻 L2：隐藏自身（状态保留），打开 L2 视图
func _open_l2(label: int) -> void:
	if l2_view == null:
		return
	visible = false
	l2_view.open("region_%03d" % label)


## L2 返回（ESC）：恢复 L3 显示
func _on_l2_back() -> void:
	visible = true


## 打开 L3 地图（M 键触发）
func open() -> void:
	visible = true
	# 初始视角：无缩放（zoom 1.0，1:1 像素完美，无放大无马赛克），屏幕中心 = 地图中心
	var map_size := 2048.0
	if map_renderer != null and map_renderer.get_data() != null:
		map_size = float(map_renderer.get_data().size)
	if map_camera != null and map_camera.has_method("set_zoom"):
		var vp := get_viewport()
		if vp != null:
			var vp_size: Vector2 = vp.get_visible_rect().size
			map_camera.set_zoom(1.0)
			if map_camera.has_method("set_offset"):
				map_camera.set_offset(vp_size * 0.5 - Vector2(map_size * 0.5, map_size * 0.5))


## 关闭 L3 地图（ESC）
func close() -> void:
	visible = false
	# 通知 system_setup 恢复场景图输入
	if EventBus != null:
		EventBus.emit_signal("strategic_map_closed")
