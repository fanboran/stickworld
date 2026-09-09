extends SceneTree
## 渲染多层建筑（宅邸）外观验收图（批次 3：多层建筑 B3 图纸落地）。
## 两实例上下排布：14 格全宽（默认 def 宽度）+ 10 格窄版（验证拉伸模型）。
## 运行（非 headless，SubViewport 需要 GPU）：
##   godot --path stick-world --script res://tools/baking/render_manor.gd
## 输出：user://multi_story_render.png（勿覆盖其他验收图）。

func _initialize() -> void:
	_run()


func _run() -> void:
	var sub := SubViewport.new()
	sub.size = Vector2i(1000, 1320)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var world := Node2D.new()
	sub.add_child(world)
	root.add_child(sub)
	var bg := ColorRect.new()
	bg.color = Color(0.10, 0.10, 0.12)
	bg.size = Vector2(1000, 1320)
	world.add_child(bg)
	var scene: PackedScene = load("res://modules/building_gen/buildings/manor.tscn")
	if scene == null:
		push_error("[render_manor] 场景加载失败")
		quit(1)
		return
	# 14 格全宽
	var b14: Node2D = scene.instantiate()
	world.add_child(b14)
	b14.position = Vector2(245, 640)
	# 10 格窄版：改宽后重建外观（模拟建造时拉伸/收缩）
	var b10: Node2D = scene.instantiate()
	world.add_child(b10)
	b10.position = Vector2(200, 1270)
	b10.set("width", 10)
	if b10.has_method("rebuild_exterior"):
		b10.call("rebuild_exterior")
	# 默认 PLANNED 状态外观 0.3 半透明（蓝图态），验收图按落成态渲染。
	# --script 模式下全局类名解析不可靠，用 duck typing（Building.State.OPERATIONAL = 2）。
	for b in [b14, b10]:
		if b.has_method("set_state"):
			b.call("set_state", 2)
	for i in 8:
		await process_frame
	var img := sub.get_texture().get_image()
	var out := "user://multi_story_render.png"
	img.save_png(out)
	print("[render_manor] saved: ", ProjectSettings.globalize_path(out))
	quit(0)
