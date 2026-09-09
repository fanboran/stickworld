extends SceneTree
## 渲染铁匠铺外观验收图（对照 reference/smithy_lv1.png）。
## 运行（非 headless，SubViewport 需要 GPU）：
##   godot --path stick-world --script res://tools/baking/render_smithy.gd
## 输出：user://smithy_render.png（日志会打印全局路径）

func _initialize() -> void:
	_run()


func _run() -> void:
	var sub := SubViewport.new()
	sub.size = Vector2i(900, 560)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var world := Node2D.new()
	sub.add_child(world)
	root.add_child(sub)
	var bg := ColorRect.new()
	bg.color = Color(0.10, 0.10, 0.12)
	bg.size = Vector2(900, 560)
	world.add_child(bg)
	var scene: PackedScene = load("res://modules/building_gen/buildings/smithy_lv1.tscn")
	if scene == null:
		push_error("[render_smithy] 场景加载失败")
		quit(1)
		return
	var b: Node2D = scene.instantiate()
	world.add_child(b)
	b.position = Vector2(300, 470)
	# 默认 PLANNED 状态外观是 0.3 半透明（蓝图态），验收图按落成态渲染。
	# 注意：--script 模式下全局类名（class_name）解析不可靠，用 duck typing + 枚举字面量
	# （Building.State.OPERATIONAL = 2），不引用 Building 类名。
	if b.has_method("set_state"):
		b.call("set_state", 2)
	# 等 @tool 装配 + 纹理就绪若干帧
	for i in 8:
		await process_frame
	var img := sub.get_texture().get_image()
	var out := "user://smithy_render.png"
	img.save_png(out)
	print("[render_smithy] saved: ", ProjectSettings.globalize_path(out))
	quit(0)
