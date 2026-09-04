extends Node
## 主菜单视觉快照（dev 层）——验证主菜单背景装饰（渐变/远山/云）渲染。
## 用法：godot --path stick-world res://tests/dev/snapshot_menu.tscn -- --out F:/tmp/menu.png

const MenuScene := preload("res://modules/ui_global/scenes/menus/main_menu.tscn")


func _ready() -> void:
	var out := "res://tests/dev/snapshot_menu_out.png"
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--out="):
			out = str(a).trim_prefix("--out=")
	var menu := MenuScene.instantiate()
	add_child(menu)
	await get_tree().create_timer(1.5).timeout
	var img := get_viewport().get_texture().get_image()
	img.save_png(out)
	print("[SNAPSHOT] menu saved: ", out)
	get_tree().quit(0)
