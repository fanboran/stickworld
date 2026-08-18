extends Node
## 视觉诊断：真实游戏内 ESC 暂停菜单渲染截图（跑 game_root → 等地图加载 → _handle_escape → 截图）。
## 输入链路回归由 tests/integration/test_esc_key_input.gd 覆盖，本文件只做视觉验收。
## 运行（弹窗 ~3s 自动截图退出）：
##   godot --path stick-world res://tests/dev/diag_in_game_escape.tscn -- --shot=F:/out.png

const _GameRootScene: PackedScene = preload("res://modules/world/scenes/game_root.tscn")

var _shot_path: String = ""
var _frames: int = 0
var _game_root: Node = null
var _done: bool = false


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			_shot_path = arg.trim_prefix("--shot=")
	get_window().grab_focus()
	_game_root = _GameRootScene.instantiate()
	add_child(_game_root)


func _process(_delta: float) -> void:
	_frames += 1
	# 等地图加载完（帧 90 时开暂停菜单，帧 120 截图）
	if _frames == 90:
		if _game_root != null and _game_root.has_method("_handle_escape"):
			_game_root._handle_escape()
			print("[diag] ESC 已触发")
	elif _frames == 120 and not _done:
		_done = true
		await _save_shot()
	elif _frames > 130:
		get_tree().quit(0)


func _save_shot() -> void:
	if _shot_path.is_empty():
		return
	await get_tree().process_frame
	await get_tree().process_frame
	var img: Image = get_viewport().get_texture().get_image()
	var err: int = img.save_png(_shot_path)
	print("[diag] 游戏内 ESC 暂停菜单截图: %s (err=%d)" % [_shot_path, err])
