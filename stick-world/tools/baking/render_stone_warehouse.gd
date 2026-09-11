extends SceneTree
## 渲染石造仓库外观验收图（批次 2：石头结构件化）。
## 两实例上下排布：16 格全宽（默认 def 宽度）+ 8 格窄版（验证拉伸模型）。
## 运行（非 headless，SubViewport 需要 GPU）：
##   godot --path stick-world --script res://tools/baking/render_stone_warehouse.gd
## 输出：user://stone_render.png（日志打印全局路径；勿覆盖 smithy_render.png）。

func _initialize() -> void:
	_run()


func _run() -> void:
	var sub := SubViewport.new()
	sub.size = Vector2i(980, 900)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var world := Node2D.new()
	sub.add_child(world)
	root.add_child(sub)
	var bg := ColorRect.new()
	bg.color = Color(0.10, 0.10, 0.12)
	bg.size = Vector2(980, 900)
	world.add_child(bg)
	var scene: PackedScene = load("res://modules/building_gen/buildings/stone_warehouse.tscn")
	if scene == null:
		push_error("[render_stone_wh] 场景加载失败")
		quit(1)
		return
	# 16 格全宽
	var b16: Node2D = scene.instantiate()
	world.add_child(b16)
	b16.position = Vector2(245, 470)
	# 8 格窄版：改宽后重建外观（模拟建造时拉伸/收缩）
	var b8: Node2D = scene.instantiate()
	world.add_child(b8)
	b8.position = Vector2(200, 880)
	b8.set("width", 8)
	if b8.has_method("rebuild_exterior"):
		b8.call("rebuild_exterior")
	# 默认 PLANNED 状态外观 0.3 半透明（蓝图态），验收图按落成态渲染。
	# --script 模式下全局类名解析不可靠，用 duck typing（Building.State.OPERATIONAL = 2）。
	for b in [b16, b8]:
		if b.has_method("set_state"):
			b.call("set_state", 2)
	for i in 8:
		await process_frame
	var img := sub.get_texture().get_image()
	var out := "user://stone_render.png"
	img.save_png(out)
	print("[render_stone_wh] saved: ", ProjectSettings.globalize_path(out))
	quit(0)
