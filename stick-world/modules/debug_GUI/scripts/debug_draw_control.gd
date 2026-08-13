extends Control
## DebugDrawControl -- 调试绘制控件，在 _draw() 中调用所有注册的绘制器。
##
## 由 DebugOverlay 创建并管理。不独立使用。


func _draw() -> void:
	if DebugApi == null or not DebugApi.is_visible():
		return
	# 通过场景树查找 CameraRig（不依赖 get_viewport().get_camera_2d()，在 CanvasLayer 下更可靠）
	var camera: Camera2D = _get_camera()
	if camera == null:
		return
	var ctx: Dictionary = {
		"camera": camera,
		"camera_pos": camera.global_position,
		"viewport_size": get_viewport_rect().size,
		"effective_zoom": camera.zoom.x if camera.zoom != Vector2.ZERO else 1.0,
	}
	# 获取当前地图实例（通过 GameRoot.get_current_map）
	var map: Node2D = _get_current_map()
	ctx["map"] = map
	# 调用所有已启用的绘制器
	for drawer_name in DebugApi.get_drawers().keys():
		if not DebugApi.is_drawer_enabled(drawer_name):
			continue
		var drawer: Callable = DebugApi.get_drawers()[drawer_name]
		if drawer.is_valid():
			drawer.call(self, ctx)


## 通过场景树查找 CameraRig（Camera2D）
## （调试可视化职责豁免：本模块职责即全局可视化，2026-08 审计标注）
func _get_camera() -> Camera2D:
	var root: Node = get_tree().root
	for i in root.get_child_count():
		var child: Node = root.get_child(i)
		var cam: Node = child.get_node_or_null("CameraRig")
		if cam != null and cam is Camera2D:
			return cam as Camera2D
	return null


## 通过 GameRoot.get_current_map 获取当前地图
func _get_current_map() -> Node2D:
	var root: Node = get_tree().root
	for i in root.get_child_count():
		var child: Node = root.get_child(i)
		if child.has_method("get_current_map"):
			var map: Node2D = child.get_current_map() as Node2D
			if map != null and is_instance_valid(map):
				return map
	return null
