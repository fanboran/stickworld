extends Control
## DebugDrawControl -- 调试绘制控件，在 _draw() 中调用所有注册的绘制器。
##
## 由 DebugOverlay 创建并管理。不独立使用。


func _draw() -> void:
	if DebugApi == null or not DebugApi.is_visible():
		return
	# 构建绘制上下文
	var camera: Camera2D = get_viewport().get_camera_2d()
	if camera == null:
		return
	var ctx: Dictionary = {
		"camera": camera,
		"camera_pos": camera.global_position,
		"viewport_size": get_viewport_rect().size,
		"effective_zoom": camera.zoom.x if camera.zoom != Vector2.ZERO else 1.0,
	}
	# 获取当前地图实例
	var map: Node2D = null
	if "follow_target" in camera and camera.follow_target != null and is_instance_valid(camera.follow_target):
		# follow_target 是 StickmanEntity，其父节点是 EntityHost，再上是 VillageMap
		var parent: Node = camera.follow_target.get_parent()
		if parent != null:
			var grandparent: Node = parent.get_parent()
			if grandparent != null and grandparent is Node2D:
				map = grandparent as Node2D
	ctx["map"] = map
	# 调用所有注册的绘制器
	for drawer_name in DebugApi.get_drawers().keys():
		var drawer: Callable = DebugApi.get_drawers()[drawer_name]
		if drawer.is_valid():
			drawer.call(self, ctx)
	# FPS / 实体数（左下角，避开 ModePanel 底部 80px 区域）
	var font: Font = get_theme_default_font()
	var fps_text: String = "FPS: %d" % Engine.get_frames_per_second()
	var entity_count: int = 0
	if map != null and is_instance_valid(map):
		var entity_host: Node2D = map.get_node_or_null(WorldAPI.PATH_MAP_ENTITY_HOST)
		if entity_host != null:
			entity_count = entity_host.get_child_count()
	fps_text += "  实体: %d" % entity_count
	var vp_size: Vector2 = get_viewport_rect().size
	# 半透明背景
	var fps_pos := Vector2(12, vp_size.y - 96)
	var fps_size := font.get_string_size(fps_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12)
	draw_rect(Rect2(fps_pos - Vector2(4, 2), fps_size + Vector2(8, 6)), Color(0.0, 0.0, 0.0, 0.5), true)
	draw_string(font, fps_pos, fps_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1.0, 1.0, 1.0, 0.85))
