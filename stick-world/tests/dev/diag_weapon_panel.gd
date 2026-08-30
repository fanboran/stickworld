extends Node
## 视觉诊断：武器调控面板 + 武器渲染层级（不被地面盖住）。
## 跑 game_root → 等地图/玩家 → 截全景（面板+持武器单位）→ 截单位特写。
## 运行（弹窗 ~4s 自动截图退出）：
##   godot --path stick-world res://tests/dev/diag_weapon_panel.tscn -- --shot=F:/out.png

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
	if _frames == 100 and not _done:
		_done = true
		await _verify()
	elif _frames > 130:
		get_tree().quit(0)


func _verify() -> void:
	var player: Node2D = _game_root.get_player_entity()
	print("[diag] player=", player)
	var wm: Node = player.get_node_or_null("WeaponMount") if player != null else null
	print("[diag] weapon_mount=", wm, " type=", wm.weapon_type if wm != null else -1,
			" shield=", wm.shield_enabled if wm != null else false)
	var panel: Control = _game_root._weapon_panel
	print("[diag] weapon_panel=", panel, " visible=", panel.visible if panel != null else false,
			" buttons=", panel.get_child_count() if panel != null else 0)
	# 模拟面板点击：切到矛（index 1）
	if wm != null:
		wm.weapon_type = 1
	if panel != null and panel.has_method("refresh"):
		panel.refresh()
	await get_tree().process_frame
	await get_tree().process_frame
	# 相机对准玩家，保证单位在画面中央
	var cam: Camera2D = get_viewport().get_camera_2d()
	if cam != null and player != null:
		cam.global_position = player.global_position
	await get_tree().process_frame
	await get_tree().process_frame
	if not _shot_path.is_empty():
		var img: Image = get_viewport().get_texture().get_image()
		var err: int = img.save_png(_shot_path)
		print("[diag] 截图: %s (err=%d)" % [_shot_path, err])
		# 附加：单位脚下地面像素 vs 武器像素的层级无法直接断言，人工看图
	get_tree().quit(0)
