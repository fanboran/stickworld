extends Node
func _ready() -> void:
	# 走真实链路：跳板挂常驻层 → 手动切 game_root → 观察者快速连拍 8/9 子阶段
	var loader: Control = load("res://modules/ui_global/scenes/menus/loading_screen.tscn").instantiate()
	add_child(loader)
	await get_tree().create_timer(0.35).timeout
	var script := GDScript.new()
	script.source_code = """
extends Node
func _ready() -> void:
	for i in 14:
		await get_tree().create_timer(0.25).timeout
		get_viewport().get_texture().get_image().save_png("F:/VSCode/game-2/temp/async_%02d.png" % i)
	get_tree().quit()
"""
	script.reload()
	var obs := Node.new()
	obs.set_script(script)
	get_tree().root.add_child(obs)
	loader.queue_free()
	await get_tree().create_timer(0.2).timeout
	get_tree().change_scene_to_file("res://modules/world/scenes/game_root.tscn")
