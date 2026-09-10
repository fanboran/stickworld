extends SceneTree
## 茅草笔触迭代对比图（批次 5）：v11 原版 vs v12 修长斜束两档强度。
## Sprite2D + CPU 纹理（本环境唯一可靠显示路径）。
## 运行：godot --path stick-world --script res://tools/baking/render_thatch_compare.gd
## 输出：user://thatch_compare_render.png
## --script 模式不引用全局类名，直接 load 脚本调静态方法（duck typing）。

func _initialize() -> void:
	_run()


func _run() -> void:
	var pm: GDScript = load("res://modules/texture_gen/scripts/procedural_materials.gd")

	var sub := SubViewport.new()
	sub.size = Vector2i(1000, 420)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var world := Node2D.new()
	sub.add_child(world)
	root.add_child(sub)
	var bg := ColorRect.new()
	bg.color = Color(0.10, 0.10, 0.12)
	bg.size = Vector2(1000, 420)
	world.add_child(bg)

	# 三列对比：v11 原版 / v12 推荐组合 / v12 强烈档
	var variants := [
		["v11 原版（默认）", {}],
		["v12 推荐 slant.42 str.1.9 sld.1.55 tp.45",
			{"slant": 0.42, "stretch": 1.9, "slender": 1.55, "taper_min": 0.45}],
		["v12 强烈 slant.55 str.2.4 sld.1.9 tp.38",
			{"slant": 0.55, "stretch": 2.4, "slender": 1.9, "taper_min": 0.38}],
	]
	for i in variants.size():
		var tex: ImageTexture = pm.make_thatch_layered(256, 160, 3, variants[i][1])
		var s := Sprite2D.new()
		s.centered = false
		s.texture = tex
		s.position = Vector2(50.0 + 320.0 * float(i), 90.0)
		s.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		world.add_child(s)
		var lb := Label.new()
		lb.text = variants[i][0]
		lb.position = Vector2(50.0 + 320.0 * float(i), 40.0)
		world.add_child(lb)
	# 下排：坡面裁剪法（_slope_thatch_tex 同款逐行裁剪）在 v11/v12 下的对比
	var slope_pairs := [
		["坡面 v11", {}],
		["坡面 v12 推荐", {"slant": 0.42, "stretch": 1.9, "slender": 1.55, "taper_min": 0.45}],
	]
	for i in slope_pairs.size():
		var src: ImageTexture = pm.make_thatch_layered(256, 160, 7, slope_pairs[i][1])
		var src_img: Image = src.get_image()
		var img := Image.create(256, 160, false, Image.FORMAT_RGBA8)
		# 梯形坡面裁剪（顶边收窄 0.3..0.7 → 底边全宽，同 _slope_thatch_tex 逻辑）
		for y in 160:
			var t := float(y) / 159.0
			var left := int(round(256.0 * lerpf(0.3, 0.0, t)))
			var right := int(round(256.0 * lerpf(0.7, 1.0, t)))
			for x in range(left, right):
				var c := src_img.get_pixel(x, y)
				c.a = 1.0
				img.set_pixel(x, y, c)
		var st := ImageTexture.create_from_image(img)
		var s2 := Sprite2D.new()
		s2.centered = false
		s2.texture = st
		s2.position = Vector2(210.0 + 320.0 * float(i), 265.0)
		s2.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		world.add_child(s2)
		var lb2 := Label.new()
		lb2.text = slope_pairs[i][0]
		lb2.position = Vector2(210.0 + 320.0 * float(i), 385.0)
		world.add_child(lb2)

	for i in 8:
		await process_frame
	var out_img := sub.get_texture().get_image()
	var out := "user://thatch_compare_render.png"
	out_img.save_png(out)
	print("[render_thatch_compare] saved: ", ProjectSettings.globalize_path(out))
	quit(0)
