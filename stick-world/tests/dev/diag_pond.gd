extends Node
## 池塘诊断（dev 层）——打印 Pond 世界/屏幕坐标与相机状态，验证取景与 line_uv_y。
## 用法：godot --path . res://tests/dev/diag_pond.tscn --headless

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")

var _game_root: Node = null


func _ready() -> void:
	_game_root = GameRootScene.instantiate()
	add_child(_game_root)
	await get_tree().create_timer(2.0).timeout
	var map: Node = _game_root.get_current_map()
	var pond: Node2D = map.get_node_or_null("SeaLeft") if map != null else null
	if pond == null:
		print("[DIAG] FAIL: SeaLeft 未找到")
		get_tree().quit(1)
		return
	var cam: Camera2D = _game_root.get_node_or_null("CameraRig")
	var vp := get_viewport()
	var ct: Transform2D = vp.get_canvas_transform()
	var screen_pos: Vector2 = ct * pond.global_position
	var vp_size: Vector2 = vp.get_visible_rect().size
	print("[DIAG] pond world=%s size=%s" % [pond.global_position, Vector2(pond.pond_width, pond.pond_depth)])
	print("[DIAG] pond screen y=%.0f / vp_h=%.0f -> line_uv_y=%.3f" % [screen_pos.y, vp_size.y, screen_pos.y / vp_size.y])
	print("[DIAG] screen x range=%.0f..%.0f (vp_w=%.0f)" % [screen_pos.x, screen_pos.x + pond.pond_width, vp_size.x])
	if cam != null:
		print("[DIAG] cam center=%s zoom=%.2f" % [cam.get_screen_center_position(), cam.zoom.x])
	# 玩家位置（取景参考）
	var player: Node2D = _game_root.get_player_entity() if _game_root.has_method("get_player_entity") else null
	if player != null:
		print("[DIAG] player world=%s" % player.global_position)
	get_tree().quit(0)
