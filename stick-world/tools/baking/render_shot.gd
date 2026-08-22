extends Node
## 渲染截图 v5：验证 SWL 剑挂载 + 洗稿后走路姿态。
## 运行：GODOT --path stick-world res://tools/baking/render_shot.tscn（非 headless）

const STICKMAN_SCENE: PackedScene = preload("res://modules/units/scenes/stickman_entity.tscn")


func _ready() -> void:
	var sub := SubViewport.new()
	sub.size = Vector2i(500, 1000)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var world := Node2D.new()
	sub.add_child(world)
	add_child(sub)
	var bg := ColorRect.new()
	bg.color = Color(0.12, 0.12, 0.14, 1.0)
	bg.size = Vector2(500, 1000)
	bg.position = Vector2.ZERO
	world.add_child(bg)
	var entity: Node2D = STICKMAN_SCENE.instantiate()
	world.add_child(entity)
	entity.position = Vector2(250, 990)
	var overlay_script: GDScript = preload("res://modules/units/scripts/rig/procedural_overlay.gd")
	# 测试：禁用描边 shader 看颜色是否正常
	var rig: Node = entity.get("rig")
	if rig != null:
		rig.scale = Vector2(4.0, 4.0)
	for i in 12:
		await get_tree().process_frame
	_shoot(sub, "idle")
	if rig != null and rig.has_method("play"):
		rig.play("walk")
		for i in 10:
			await get_tree().process_frame
		_shoot(sub, "walk")
		rig.play("attack")
		for i in 8:
			await get_tree().process_frame
		_shoot(sub, "attack")
	print("截图完成")
	get_tree().quit(0)


func _shoot(sub: SubViewport, name: String) -> void:
	await get_tree().process_frame
	var img := sub.get_texture().get_image()
	img.save_png("user://shot5_" + name + ".png")
	print("saved shot5_", name)
