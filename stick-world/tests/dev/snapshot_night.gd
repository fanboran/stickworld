extends Node
## 夜空视觉快照（dev 层）——真渲染跑游戏，切 23:00 截夜空（星野/月亮/后处理夜晚态）。
##
## 用法（不要 --headless，需要真渲染）：
##   godot --path stick-world res://tests/dev/snapshot_night.tscn -- --out F:/tmp/night.png

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")

var _game_root: Node = null


func _ready() -> void:
	var out := "res://tests/dev/snapshot_night_out.png"
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--out="):
			out = str(a).trim_prefix("--out=")
	_game_root = GameRootScene.instantiate()
	add_child(_game_root)
	await get_tree().create_timer(1.5).timeout
	# 切深夜：星野 lerp 2/s，等 2.5s 到满强度再截
	var env: Node = _game_root.get_node_or_null("EnvironmentSystem")
	if env != null and env.has_method("set_time_of_day"):
		env.set_time_of_day(23.0)
	await get_tree().create_timer(2.5).timeout
	var img := get_viewport().get_texture().get_image()
	img.save_png(out)
	print("[SNAPSHOT] saved: ", out)
	get_tree().quit(0)
