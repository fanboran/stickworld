extends SceneTree
## 城墙四段并排验收渲染（批次 5：wall_tier 系列外壳化改造）。
## 改造前留底与改造后对比共用本脚本，用 --out=<文件名> 区分（user:// 全局共享，勿覆盖他图）：
##   godot --path stick-world --script res://tools/baking/render_walls.gd -- --out=wall_render_before.png
##   godot --path stick-world --script res://tools/baking/render_walls.gd -- --out=wall_render_after.png
## 注意：--script 模式下全局类名解析不可靠（duck typing），场景经 building_gen api 加载。

func _initialize() -> void:
	_run()


func _run() -> void:
	# 解析 user args：--out=<文件名>（默认 wall_render_out.png）
	var out_name := "wall_render_out.png"
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("--out="):
			out_name = s.trim_prefix("--out=")

	var sub := SubViewport.new()
	sub.size = Vector2i(860, 420)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var world := Node2D.new()
	sub.add_child(world)
	root.add_child(sub)
	var bg := ColorRect.new()
	bg.color = Color(0.10, 0.10, 0.12)
	bg.size = Vector2(860, 420)
	world.add_child(bg)
	# 地面带（草地色，纯色块安全路径）
	var ground := ColorRect.new()
	ground.color = Color(0.36, 0.44, 0.26)
	ground.position = Vector2(0, 330)
	ground.size = Vector2(860, 90)
	world.add_child(ground)

	# 四段城墙并排：tier1（土）/tier2（石）/tier3（大石）/gate（门）
	var ids := ["wall_tier1", "wall_tier2", "wall_tier3", "wall_gate"]
	var labels := ["tier1 土墙", "tier2 石墙", "tier3 大墙", "城门"]
	var api: GDScript = load("res://modules/building_gen/api.gd")
	var xs := [90, 280, 470, 680]
	for i in ids.size():
		var scene: PackedScene = api.load_building_scene(ids[i])
		if scene == null:
			push_error("[render_walls] 场景加载失败: %s" % ids[i])
			quit(1)
			return
		var b: Node2D = scene.instantiate()
		world.add_child(b)
		# 场景 Exterior position=(16,0)，墙身 x∈[-16,16] 局部；脚底落地面线
		b.position = Vector2(float(xs[i]) - 16.0, 330.0)
		# PLANNED 态外观 0.3 半透明，验收图切落成态（OPERATIONAL = 2）
		if b.has_method("set_state"):
			b.call("set_state", 2)
		# 标签
		var lb := Label.new()
		lb.text = labels[i]
		lb.position = Vector2(float(xs[i]) - 40.0, 380.0)
		world.add_child(lb)

	# @tool 程序化装配晚于 add_child（--script 模式 _ready 延迟到首帧），先等帧再截图
	for i in 8:
		await process_frame
	var img := sub.get_texture().get_image()
	var out := "user://" + out_name
	img.save_png(out)
	print("[render_walls] saved: ", ProjectSettings.globalize_path(out))
	quit(0)
