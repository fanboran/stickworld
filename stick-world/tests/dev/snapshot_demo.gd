extends Node
## Demo 视觉快照（dev 层）——带渲染跑游戏并截图，验证后处理 shader 实际渲染。
##
## 用法（不要 --headless，需要真渲染）：
##   godot --path stick-world res://tests/dev/snapshot_demo.tscn -- --out F:/tmp/demo_shot.png
##
## 截两个时刻：T+2s（开局村庄，白天后处理满强度）。

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")

var _game_root: Node = null


func _ready() -> void:
	var out := "res://tests/dev/snapshot_out.png"
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--out="):
			out = str(a).trim_prefix("--out=")
	_game_root = GameRootScene.instantiate()
	add_child(_game_root)
	await get_tree().create_timer(2.5).timeout
	var img := get_viewport().get_texture().get_image()
	img.save_png(out)
	print("[SNAPSHOT] saved: ", out)
	get_tree().quit(0)
