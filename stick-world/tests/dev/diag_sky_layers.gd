extends Node
## [临时探针] 夜空遮挡关系诊断 —— 验证星/月/极光是否被背景贴图层盖住。
## 用法：godot --path stick-world res://tests/dev/diag_sky_layers.tscn
## 产出：F:/tmp/probe_base.png / probe_notiles.png / probe_z.png

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")


func _shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("[PROBE] saved: ", path)


func _ready() -> void:
	var gr: Node = GameRootScene.instantiate()
	add_child(gr)
	await get_tree().create_timer(1.5).timeout
	var env: Node = gr.get_node("EnvironmentSystem")
	env.set_time_of_day(23.5)
	env.set_seconds_per_day(1000000.0)  # 冻结时间，截图时刻精确
	await get_tree().create_timer(2.5).timeout

	var cam: Camera2D = gr.get_node_or_null("CameraRig")
	print("[PROBE] cam=", cam.global_position, " zoom=", cam.zoom)
	var vt: Transform2D = get_viewport().get_canvas_transform()
	print("[PROBE] canvas_transform=", vt, " view_rect=", Rect2(-vt.origin / vt.scale.x, Vector2(1920, 1080) / vt.scale.x))

	var sky: Node2D = gr.get_node_or_null("WorldChunkHost/VillageMap/SkyDecor")
	if sky == null:
		# 兜底：深度搜索
		var stack: Array = [gr]
		while not stack.is_empty():
			var n: Node = stack.pop_front()
			if n is SkyDecor:
				sky = n
				break
			stack.append_array(n.get_children())
	print("[PROBE] sky=", sky, " global_pos=", sky.global_position if sky else null)
	if sky == null:
		get_tree().quit(1)
		return
	for c in sky.get_children():
		var extra := ""
		if c is Sprite2D:
			extra = " tex=%s region=%s" % [c.texture.get_path().get_file() if c.texture else "null", c.region_rect]
		print("[PROBE]   child=", c.name, " class=", c.get_class(), " z=", c.z_index, " pos=", c.position, extra)

	var stars: Node2D = sky.get_node_or_null("Stars")
	if stars != null:
		print("[PROBE] stars global=", stars.global_position, " night=", stars.get_night_factor(),
				" env_time=", stars._env_time())
	# 水面
	var water: Node2D = sky.get_parent().get_node_or_null("WaterBelow")
	if water == null:
		for n in sky.get_parent().get_children():
			if n.name == "WaterBelow":
				water = n
	print("[PROBE] water=", water, " global=", water.global_position if water else null)

	await _shot("F:/tmp/probe_base.png")

	# 实验 B：隐藏全部平铺背景层（星/月/极光应显形）
	var tiles: Array = []
	for c in sky.get_children():
		if c is Sprite2D:
			c.visible = false
			tiles.append(c)
	await _shot("F:/tmp/probe_notiles.png")
	for c in tiles:
		c.visible = true

	# 实验 C：星野层 z_index 抬到背景层之上
	if stars != null:
		stars.z_index = 1
	await _shot("F:/tmp/probe_z.png")
	get_tree().quit(0)
