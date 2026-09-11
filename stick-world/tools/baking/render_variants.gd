extends SceneTree
## 批次 5 新变体建筑渲染：木骨民居 timber_cottage（10 格）+ 议事厅 grand_hall（16 格），
## 另渲染 grand_hall 10 格窄版验证拉伸模型。输出：user://variant_render.png
## 运行（非 headless）：godot --path stick-world --script res://tools/baking/render_variants.gd

func _initialize() -> void:
	_run()


func _run() -> void:
	var sub := SubViewport.new()
	sub.size = Vector2i(1100, 1600)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var world := Node2D.new()
	sub.add_child(world)
	root.add_child(sub)
	var bg := ColorRect.new()
	bg.color = Color(0.10, 0.10, 0.12)
	bg.size = Vector2(1100, 1600)
	world.add_child(bg)
	# 地面带
	var ground := ColorRect.new()
	ground.color = Color(0.36, 0.44, 0.26)
	ground.position = Vector2(0, 1330)
	ground.size = Vector2(1100, 270)
	world.add_child(ground)

	var api: GDScript = load("res://modules/building_gen/api.gd")
	# 上：议事厅 16 格全宽（y 基线 850，钟楼顶约 -810 在画布内）；下排：民居 10 格与 6 格窄版（y 基线 1330）
	var plan := [
		["grand_hall", Vector2(560, 850), 16],
		["timber_cottage", Vector2(390, 1330), 10],
		["timber_cottage", Vector2(880, 1330), 6],
	]
	var instances: Array = []
	for p in plan:
		var scene: PackedScene = api.load_building_scene(p[0])
		if scene == null:
			push_error("[render_variants] 场景加载失败: %s" % p[0])
			quit(1)
			return
		var b: Node2D = scene.instantiate()
		world.add_child(b)
		b.position = p[1]
		b.set("width", p[2])
		if b.has_method("rebuild_exterior"):
			b.call("rebuild_exterior")
		instances.append(b)
	# 落成态渲染（duck typing，--script 模式不引用全局类名）
	for b in instances:
		if b.has_method("set_state"):
			b.call("set_state", 2)
	for i in 8:
		await process_frame
	var img := sub.get_texture().get_image()
	var out := "user://variant_render.png"
	img.save_png(out)
	print("[render_variants] saved: ", ProjectSettings.globalize_path(out))
	quit(0)
