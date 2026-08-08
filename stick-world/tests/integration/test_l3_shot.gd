extends SceneTree
func _init() -> void:
	var scene: PackedScene = load("res://modules/world_map/scenes/strategic_map_l3.tscn")
	var l3: Node = scene.instantiate()
	root.add_child(l3)
	var content: Node = l3.get_node_or_null("Content")
	var renderer: Node = content.get_node_or_null("L3MapRenderer")
	var data = (load("res://modules/world_map/data/l3_world_data.gd") as Script).new()
	data = data.load_from("res://config/strategic_map/l3_world.json", "res://config/strategic_map")
	renderer.set_data(data)
	content.open()
	for i in range(5):
		await process_frame
	var cam: Node = content.get_node_or_null("MapCamera")
	print("[dbg] zoom = ", cam.get_zoom(), " offset = ", cam.get_offset())
	var img: Image = root.get_viewport().get_texture().get_image()
	img.save_png("user://l3_shot.png")
	print("[dbg] 截图已保存: user://l3_shot.png")
	quit(0)
