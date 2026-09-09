extends SceneTree
## 天际线全景对比图（批次 3）：多层宅邸与单层建筑同框，
## 验证多层建筑在小镇轮廓里的层叠感（《王国两位君主》标杆）。
## 运行（非 headless）：
##   godot --path stick-world --script res://tools/baking/render_skyline.gd
## 输出：user://skyline_render.png

func _initialize() -> void:
	_run()


func _place(world: Node2D, def_id: String, pos: Vector2, w: int = -1) -> void:
	var scene: PackedScene = load("res://modules/building_gen/buildings/%s.tscn" % def_id)
	if scene == null:
		push_error("[render_skyline] 场景加载失败: %s" % def_id)
		return
	var b: Node2D = scene.instantiate()
	world.add_child(b)
	b.position = pos
	if w > 0:
		b.set("width", w)
		if b.has_method("rebuild_exterior"):
			b.call("rebuild_exterior")
	if b.has_method("set_state"):
		b.call("set_state", 2)  # OPERATIONAL（落成态）


func _run() -> void:
	var sub := SubViewport.new()
	sub.size = Vector2i(1980, 640)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var world := Node2D.new()
	sub.add_child(world)
	root.add_child(sub)
	var bg := ColorRect.new()
	bg.color = Color(0.11, 0.12, 0.15)
	bg.size = Vector2(1980, 640)
	world.add_child(bg)
	# 地平线（地面色带）
	var ground := ColorRect.new()
	ground.color = Color(0.18, 0.20, 0.16)
	ground.position = Vector2(0, 600)
	ground.size = Vector2(1980, 40)
	world.add_child(ground)
	# 小镇轮廓：单层茅草棚 → 铁匠铺 → 多层宅邸 → 石造仓库（多层与单层同框对比）
	_place(world, "placeholder", Vector2(60, 600), 8)
	_place(world, "smithy_lv1", Vector2(400, 600), 14)
	_place(world, "manor", Vector2(930, 600), 14)
	_place(world, "stone_warehouse", Vector2(1460, 600), 14)
	for i in 8:
		await process_frame
	var img := sub.get_texture().get_image()
	var out := "user://skyline_render.png"
	img.save_png(out)
	print("[render_skyline] saved: ", ProjectSettings.globalize_path(out))
	quit(0)
