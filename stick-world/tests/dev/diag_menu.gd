extends Node
## 主菜单视觉验收：确认「战斗演练」按钮存在，3 秒截图退出。
const _MenuScene: PackedScene = preload("res://modules/ui_global/scenes/menus/main_menu.tscn")
var _frames: int = 0

func _ready() -> void:
	add_child(_MenuScene.instantiate())

func _process(_d: float) -> void:
	_frames += 1
	if _frames == 60:
		var img: Image = get_viewport().get_texture().get_image()
		img.save_png("res://tools/baking/diag_menu.png")
		print("[menu-diag] saved")
		get_tree().quit(0)
